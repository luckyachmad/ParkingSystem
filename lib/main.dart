import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'features/auth/auth_provider.dart';
import 'features/dashboard/dashboard_provider.dart';
import 'features/vehicle_entry/vehicle_entry_provider.dart';
import 'features/vehicle_exit/vehicle_exit_provider.dart';

// ---------------------------------------------------------------------------
// App entry point
// ---------------------------------------------------------------------------

void main() {
  runApp(
    ProviderScope(
      // Wire all placeholder providers to their concrete implementations.
      //
      // Each feature file declares a placeholder provider that throws
      // UnimplementedError when accessed without an override. Here we
      // override each placeholder with the real implementation defined in
      // lib/core/providers.dart, passing DatabaseHelper.instance through
      // the provider graph.
      //
      // Requirements: all (Task 15.1)
      overrides: [
        // Auth service
        authServiceProvider.overrideWith(
          (ref) => ref.watch(concreteAuthServiceProvider),
        ),

        // Repositories used by vehicle entry / pricing
        pricingRepositoryProvider.overrideWith(
          (ref) => ref.watch(concretePricingRepositoryProvider),
        ),
        ticketRepositoryProvider.overrideWith(
          (ref) => ref.watch(concreteTicketRepositoryProvider),
        ),

        // Repository used by vehicle exit / transactions
        transactionRepositoryProvider.overrideWith(
          (ref) => ref.watch(concreteTransactionRepositoryProvider),
        ),

        // Dashboard service
        dashboardServiceProvider.overrideWith(
          (ref) => ref.watch(concreteDashboardServiceProvider),
        ),
      ],
      child: const ParkingApp(),
    ),
  );
}

// ---------------------------------------------------------------------------
// ParkingApp
// ---------------------------------------------------------------------------

/// Root application widget.
///
/// Wraps [MaterialApp.router] with a [GestureDetector] that calls
/// [AuthNotifier.resetTimer] on any tap or scroll event, implementing the
/// 30-minute inactivity session timeout (Requirement 2.5).
///
/// The [GestureDetector] uses [HitTestBehavior.translucent] so that it does
/// not intercept events from child widgets — it only observes them.
class ParkingApp extends ConsumerWidget {
  const ParkingApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => ref.read(authProvider.notifier).resetTimer(),
      onPanDown: (_) => ref.read(authProvider.notifier).resetTimer(),
      child: MaterialApp.router(
        title: 'Parking System',
        // Apply the centralised theme from lib/core/theme.dart.
        // Both light and dark variants are provided; the system theme mode
        // determines which is active (ThemeMode.system is the default).
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        routerConfig: router,
      ),
    );
  }
}
