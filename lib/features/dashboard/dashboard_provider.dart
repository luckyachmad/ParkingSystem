import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/result.dart';
import '../../models/dashboard_metrics.dart';
import '../../services/dashboard_service.dart';

// ---------------------------------------------------------------------------
// Dependency injection placeholder
// ---------------------------------------------------------------------------

/// Placeholder provider for [DashboardService].
///
/// Must be overridden in the app's [ProviderScope] with a real [DashboardService]
/// instance backed by the SQLite repositories. Accessing this provider without
/// an override will throw [UnimplementedError].
final dashboardServiceProvider = Provider<DashboardService>((ref) {
  throw UnimplementedError(
    'dashboardServiceProvider must be overridden in ProviderScope before use.',
  );
});

// ---------------------------------------------------------------------------
// dashboardIsStaleProvider
// ---------------------------------------------------------------------------

/// Exposes whether the currently displayed dashboard metrics are stale.
///
/// Set to `true` when [DashboardNotifier.refresh] fails with a [DatabaseError]
/// and the last successfully computed metrics are retained. Reset to `false`
/// on every successful refresh.
///
/// The UI reads this provider to conditionally show a stale-data banner
/// (Requirement 7.6).
final dashboardIsStaleProvider = StateProvider<bool>((ref) => false);

// ---------------------------------------------------------------------------
// DashboardNotifier
// ---------------------------------------------------------------------------

/// Manages async state for the dashboard screen.
///
/// - [build] fetches live metrics via [DashboardService.computeMetrics] and
///   starts a 30-second auto-refresh timer (Requirements 7.1–7.5).
/// - [refresh] re-invokes [computeMetrics]; on [DatabaseError] the last
///   successfully computed metrics are retained and [dashboardIsStaleProvider]
///   is set to `true` (Requirement 7.6).
/// - The timer is cancelled automatically when the provider is disposed via
///   [Ref.onDispose].
///
/// Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6
class DashboardNotifier extends AsyncNotifier<DashboardMetrics> {
  Timer? _refreshTimer;

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------

  /// Fetches initial metrics and starts the 30-second periodic refresh timer.
  ///
  /// The timer is cancelled when the provider is disposed so it does not fire
  /// after the dashboard screen is unmounted.
  @override
  Future<DashboardMetrics> build() async {
    // Cancel any existing timer before starting a new one (handles hot-reload
    // and provider re-creation scenarios).
    _refreshTimer?.cancel();

    // Register disposal callback — cancels the timer when the provider is
    // removed from the widget tree.
    ref.onDispose(() {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    });

    // Start the 30-second auto-refresh timer.
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      refresh();
    });

    final dashboardService = ref.read(dashboardServiceProvider);
    return dashboardService.computeMetrics();
  }

  // ---------------------------------------------------------------------------
  // refresh
  // ---------------------------------------------------------------------------

  /// Re-fetches dashboard metrics from [DashboardService.computeMetrics].
  ///
  /// On success:
  /// - Updates [state] with the new [DashboardMetrics].
  /// - Clears the stale flag via [dashboardIsStaleProvider].
  ///
  /// On [DatabaseError]:
  /// - Retains the last successfully computed metrics in [state] (does NOT
  ///   transition to [AsyncError]).
  /// - Sets [dashboardIsStaleProvider] to `true` so the UI can show a
  ///   stale-data banner (Requirement 7.6).
  ///
  /// Any other exception is re-thrown and transitions [state] to [AsyncError].
  Future<void> refresh() async {
    final dashboardService = ref.read(dashboardServiceProvider);

    // Capture the last known good value before attempting the refresh.
    final previousValue = state.valueOrNull;

    try {
      final metrics = await dashboardService.computeMetrics();

      // Success — update state and clear the stale flag.
      state = AsyncData(metrics);
      ref.read(dashboardIsStaleProvider.notifier).state = false;
    } on DatabaseError {
      // DatabaseError — retain last value and mark as stale (Requirement 7.6).
      if (previousValue != null) {
        state = AsyncData(previousValue);
      }
      ref.read(dashboardIsStaleProvider.notifier).state = true;
    } catch (e, st) {
      // Unexpected error — surface it as AsyncError.
      state = AsyncError(e, st);
    }
  }
}

// ---------------------------------------------------------------------------
// dashboardProvider
// ---------------------------------------------------------------------------

/// Global provider for [DashboardNotifier] / [DashboardMetrics].
///
/// Reads [dashboardServiceProvider] for its [DashboardService] dependency.
/// Override [dashboardServiceProvider] in the root [ProviderScope] to inject
/// the real service implementation.
///
/// The UI reads this provider for the current metrics:
/// ```dart
/// final metricsAsync = ref.watch(dashboardProvider);
/// ```
/// And reads [dashboardIsStaleProvider] for the stale flag:
/// ```dart
/// final isStale = ref.watch(dashboardIsStaleProvider);
/// ```
final dashboardProvider =
    AsyncNotifierProvider<DashboardNotifier, DashboardMetrics>(
  DashboardNotifier.new,
);
