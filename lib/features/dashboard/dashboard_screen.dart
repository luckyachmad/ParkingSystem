import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../core/router.dart';
import '../../models/dashboard_metrics.dart';
import '../auth/auth_provider.dart';
import 'dashboard_provider.dart';

// ---------------------------------------------------------------------------
// DashboardScreen
// ---------------------------------------------------------------------------

/// Dashboard screen — displays three live metric cards (active vehicles,
/// active users, daily income), a last-updated timestamp, and a stale-data
/// indicator banner when the most recent refresh failed.
///
/// Watches [dashboardProvider] for metric data and [dashboardIsStaleProvider]
/// for the stale flag. Shows a [CircularProgressIndicator] on initial load.
/// On [DatabaseError] the provider retains the last known values and sets the
/// stale flag; this screen surfaces that via a warning banner.
///
/// Also starts a supplementary [Timer.periodic] (30 s) that calls
/// [DashboardNotifier.refresh] while the screen is mounted. The timer is
/// cancelled via [ref.onDispose] when the screen is removed from the tree.
///
/// Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  /// Screen-level supplementary refresh timer.
  ///
  /// The provider already manages its own 30-second timer; this one ensures
  /// the screen triggers a refresh even if the provider was already alive
  /// before the screen was mounted (e.g. hot-reload scenarios).
  Timer? _refreshTimer;

  // ---------------------------------------------------------------------------
  // initState / dispose
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();

    // Start the supplementary timer after the first frame so the widget tree
    // is fully built and ref is available.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) {
          ref.read(dashboardProvider.notifier).refresh();
        }
      });
    });
  }

  @override
  void dispose() {
    // Cancel the screen-level timer so it does not fire after unmount.
    _refreshTimer?.cancel();
    _refreshTimer = null;
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // _logout
  // ---------------------------------------------------------------------------

  Future<void> _logout() async {
    await ref.read(authProvider.notifier).logout();
  }

  // ---------------------------------------------------------------------------
  // _navigateTo
  // ---------------------------------------------------------------------------

  void _navigateTo(String route) {
    context.go(route);
  }

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final metricsAsync = ref.watch(dashboardProvider);
    final isStale = ref.watch(dashboardIsStaleProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          // Manual refresh button.
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => ref.read(dashboardProvider.notifier).refresh(),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Stale data banner ────────────────────────────────────────────
          if (isStale) const _StaleBanner(),

          // ── Main content ─────────────────────────────────────────────────
          Expanded(
            child: metricsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _ErrorBody(
                message: error.toString(),
                onRetry: () => ref.read(dashboardProvider.notifier).refresh(),
              ),
              data: (metrics) => _MetricsBody(
                metrics: metrics,
                onRefresh: () => ref.read(dashboardProvider.notifier).refresh(),
              ),
            ),
          ),

          // ── Navigation shortcuts ─────────────────────────────────────────
          _NavigationBar(onNavigate: _navigateTo),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _StaleBanner
// ---------------------------------------------------------------------------

/// Warning banner shown when the last dashboard refresh failed with a
/// [DatabaseError] and the displayed values may be out of date.
///
/// Requirement 7.6
class _StaleBanner extends StatelessWidget {
  const _StaleBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: theme.colorScheme.onErrorContainer,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Data may be stale — last refresh failed. '
                'Pull down or tap refresh to retry.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _MetricsBody
// ---------------------------------------------------------------------------

/// Scrollable body showing the three metric cards and the last-updated
/// timestamp.
class _MetricsBody extends StatelessWidget {
  final DashboardMetrics metrics;
  final Future<void> Function() onRefresh;

  const _MetricsBody({
    required this.metrics,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    // Format daily income: dailyIncome is stored as a double (dollars).
    // Convert to cents for Money.toDisplay() to get the currency symbol and
    // 2 decimal places.
    final incomeCents = (metrics.dailyIncome * 100).round();
    final incomeDisplay = Money(incomeCents).toDisplay();

    // Format last-updated timestamp in local time.
    final localComputedAt = metrics.computedAt.toLocal();
    final formattedAt =
        DateFormat('MMM d, yyyy  h:mm:ss a').format(localComputedAt);

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Metric cards ───────────────────────────────────────────────
            _MetricCard(
              icon: Icons.directions_car_outlined,
              label: 'Active Vehicles',
              value: metrics.activeVehicles.toString(),
              color: Colors.blue,
            ),
            const SizedBox(height: 12),
            _MetricCard(
              icon: Icons.people_outline,
              label: 'Active Users',
              value: metrics.activeUsers.toString(),
              color: Colors.green,
            ),
            const SizedBox(height: 12),
            _MetricCard(
              icon: Icons.attach_money,
              label: "Today's Income",
              value: incomeDisplay,
              color: Colors.orange,
            ),
            const SizedBox(height: 24),

            // ── Last updated timestamp ─────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.update,
                  size: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  'Last updated: $formattedAt',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _MetricCard
// ---------------------------------------------------------------------------

/// A card displaying a single dashboard metric with an icon, label, and value.
class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            // ── Icon container ─────────────────────────────────────────────
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(width: 16),

            // ── Label + value ──────────────────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ErrorBody
// ---------------------------------------------------------------------------

/// Shown when [dashboardProvider] transitions to [AsyncError] (i.e. an
/// unexpected error that is not a [DatabaseError]).
class _ErrorBody extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorBody({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 56,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              'Failed to load dashboard',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _NavigationBar
// ---------------------------------------------------------------------------

/// Bottom navigation shortcuts for the owner to reach other screens from the
/// dashboard without going back to the app bar.
class _NavigationBar extends StatelessWidget {
  final void Function(String route) onNavigate;

  const _NavigationBar({required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _NavButton(
                icon: Icons.login,
                label: 'Entry',
                onTap: () => onNavigate(AppRoutes.vehicleEntry),
              ),
              _NavButton(
                icon: Icons.logout,
                label: 'Exit',
                onTap: () => onNavigate(AppRoutes.vehicleExit),
              ),
              _NavButton(
                icon: Icons.receipt_long_outlined,
                label: 'Transactions',
                onTap: () => onNavigate(AppRoutes.transactions),
              ),
              _NavButton(
                icon: Icons.price_change_outlined,
                label: 'Pricing',
                onTap: () => onNavigate(AppRoutes.pricing),
              ),
              _NavButton(
                icon: Icons.person_add_outlined,
                label: 'Register',
                onTap: () => onNavigate(AppRoutes.register),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _NavButton
// ---------------------------------------------------------------------------

/// A compact icon + label button used in [_NavigationBar].
class _NavButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _NavButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: theme.colorScheme.primary),
            const SizedBox(height: 2),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
