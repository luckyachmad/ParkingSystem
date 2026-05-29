import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../core/router.dart';
import '../../models/parking_transaction.dart';
import 'vehicle_exit_provider.dart';

// ---------------------------------------------------------------------------
// ReceiptScreen
// ---------------------------------------------------------------------------

/// Displays the parking receipt after a successful vehicle exit.
///
/// Reads [completedTransaction] from [vehicleExitProvider] state. If the user
/// navigates directly to this route without a confirmed exit, a fallback
/// "No receipt available" message is shown.
///
/// Requirements: 4.8, 8.5
class ReceiptScreen extends ConsumerWidget {
  const ReceiptScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exitState = ref.watch(vehicleExitProvider);
    final transaction = exitState.completedTransaction;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Receipt'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: transaction == null
            ? _NoReceiptView(onGoToExit: () => _goToVehicleExit(context, ref))
            : _ReceiptView(
                transaction: transaction,
                onNewExit: () => _goToVehicleExit(context, ref),
              ),
      ),
    );
  }

  void _goToVehicleExit(BuildContext context, WidgetRef ref) {
    ref.read(vehicleExitProvider.notifier).cancelExit();
    context.go(AppRoutes.vehicleExit);
  }
}

// ---------------------------------------------------------------------------
// _ReceiptView
// ---------------------------------------------------------------------------

/// The main receipt content shown after a confirmed exit.
class _ReceiptView extends StatelessWidget {
  final ParkingTransaction transaction;
  final VoidCallback onNewExit;

  const _ReceiptView({
    required this.transaction,
    required this.onNewExit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formatter = DateFormat('MMM d, yyyy  h:mm a');

    final String formattedEntry =
        formatter.format(transaction.entryTime.toLocal());
    final String formattedExit =
        formatter.format(transaction.exitTime.toLocal());

    final int totalMinutes = transaction.durationMinutes;
    final String duration = '${totalMinutes ~/ 60}h ${totalMinutes % 60}m';

    // Convert fee (stored as double dollars) back to cents for Money display.
    final String feeDisplay =
        Money((transaction.fee * 100).round()).toDisplay();

    final String paymentStatusLabel = _formatPaymentStatus(transaction.paymentStatus);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Receipt card ─────────────────────────────────────────────────
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.4),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Header ───────────────────────────────────────────────
                  Row(
                    children: [
                      Icon(
                        Icons.receipt_long_outlined,
                        color: theme.colorScheme.primary,
                        size: 28,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Parking Receipt',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 12),

                  // ── Plate number ─────────────────────────────────────────
                  _InfoRow(
                    icon: Icons.directions_car_outlined,
                    label: 'Plate Number',
                    value: transaction.plateNumber,
                    valueStyle: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── Entry time ───────────────────────────────────────────
                  _InfoRow(
                    icon: Icons.login_outlined,
                    label: 'Entry Time',
                    value: formattedEntry,
                  ),
                  const SizedBox(height: 12),

                  // ── Exit time ────────────────────────────────────────────
                  _InfoRow(
                    icon: Icons.logout_outlined,
                    label: 'Exit Time',
                    value: formattedExit,
                  ),
                  const SizedBox(height: 12),

                  // ── Duration ─────────────────────────────────────────────
                  _InfoRow(
                    icon: Icons.timer_outlined,
                    label: 'Duration',
                    value: duration,
                  ),
                  const SizedBox(height: 12),

                  const Divider(),
                  const SizedBox(height: 12),

                  // ── Fee ──────────────────────────────────────────────────
                  _InfoRow(
                    icon: Icons.attach_money_outlined,
                    label: 'Fee',
                    value: feeDisplay,
                    valueStyle: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── Payment status ───────────────────────────────────────
                  _InfoRow(
                    icon: Icons.payment_outlined,
                    label: 'Payment Status',
                    value: paymentStatusLabel,
                    valueStyle: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: _paymentStatusColor(
                        context,
                        transaction.paymentStatus,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 32),

          // ── New Exit button ───────────────────────────────────────────────
          FilledButton.icon(
            onPressed: onNewExit,
            icon: const Icon(Icons.add_circle_outline),
            label: const Text('New Exit'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ],
      ),
    );
  }

  /// Converts a [PaymentStatus] enum value to a human-readable label.
  String _formatPaymentStatus(PaymentStatus status) {
    switch (status) {
      case PaymentStatus.paid:
        return 'Paid';
      case PaymentStatus.unpaid:
        return 'Unpaid';
      case PaymentStatus.cancelled:
        return 'Cancelled';
    }
  }

  /// Returns a colour appropriate for the given [PaymentStatus].
  Color _paymentStatusColor(BuildContext context, PaymentStatus status) {
    final colorScheme = Theme.of(context).colorScheme;
    switch (status) {
      case PaymentStatus.paid:
        return Colors.green.shade700;
      case PaymentStatus.unpaid:
        return colorScheme.error;
      case PaymentStatus.cancelled:
        return colorScheme.onSurfaceVariant;
    }
  }
}

// ---------------------------------------------------------------------------
// _NoReceiptView
// ---------------------------------------------------------------------------

/// Fallback shown when the user navigates directly to the receipt route
/// without a completed exit transaction in state.
class _NoReceiptView extends StatelessWidget {
  final VoidCallback onGoToExit;

  const _NoReceiptView({required this.onGoToExit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 72,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No receipt available',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Complete a vehicle exit to generate a receipt.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: onGoToExit,
              child: const Text('Go to Vehicle Exit'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _InfoRow
// ---------------------------------------------------------------------------

/// A labelled row with an icon, label text, and value text.
class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final TextStyle? valueStyle;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueStyle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: valueStyle ?? theme.textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
