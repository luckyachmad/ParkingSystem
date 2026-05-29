import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/result.dart';
import '../../core/router.dart';
import '../../models/ticket.dart';
import '../auth/auth_provider.dart';
import 'vehicle_exit_provider.dart';

// ---------------------------------------------------------------------------
// VehicleExitScreen
// ---------------------------------------------------------------------------

/// Vehicle exit screen — allows an attendant to look up a vehicle by plate,
/// review the computed fee, and confirm or cancel the exit.
///
/// Two-phase UI:
/// 1. **Lookup phase** (openTicket == null): plate number field + "Look Up" button.
/// 2. **Fee summary phase** (openTicket != null): fee summary card + confirm/cancel buttons.
///
/// Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6
class VehicleExitScreen extends ConsumerStatefulWidget {
  const VehicleExitScreen({super.key});

  @override
  ConsumerState<VehicleExitScreen> createState() => _VehicleExitScreenState();
}

class _VehicleExitScreenState extends ConsumerState<VehicleExitScreen> {
  final _formKey = GlobalKey<FormState>();
  final _plateController = TextEditingController();

  // Tracks the last error shown as a snackbar so we don't re-show it.
  AppError? _lastSnackbarError;

  @override
  void dispose() {
    _plateController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // _lookUp
  // ---------------------------------------------------------------------------

  Future<void> _lookUp() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final plate = _plateController.text.trim();
    await ref.read(vehicleExitProvider.notifier).lookupPlate(plate);
  }

  // ---------------------------------------------------------------------------
  // _confirmExit
  // ---------------------------------------------------------------------------

  Future<void> _confirmExit() async {
    final authState = ref.read(authProvider);
    final closedBy = authState is Authenticated ? authState.username : '';

    await ref.read(vehicleExitProvider.notifier).confirmExit(closedBy);

    // Navigate to receipt on success — checked after await.
    if (!mounted) return;
    final exitState = ref.read(vehicleExitProvider);
    if (exitState.confirmed) {
      context.go(AppRoutes.vehicleExitReceipt);
    }
  }

  // ---------------------------------------------------------------------------
  // _cancelExit
  // ---------------------------------------------------------------------------

  void _cancelExit() {
    _plateController.clear();
    _formKey.currentState?.reset();
    ref.read(vehicleExitProvider.notifier).cancelExit();
    setState(() {
      _lastSnackbarError = null;
    });
  }

  // ---------------------------------------------------------------------------
  // _logout
  // ---------------------------------------------------------------------------

  Future<void> _logout() async {
    await ref.read(authProvider.notifier).logout();
  }

  // ---------------------------------------------------------------------------
  // _showSnackbar
  // ---------------------------------------------------------------------------

  void _showSnackbar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final exitState = ref.watch(vehicleExitProvider);

    // Show BusinessError as a floating snackbar (only once per error instance).
    final error = exitState.error;
    if (error is BusinessError && !identical(error, _lastSnackbarError)) {
      _lastSnackbarError = error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showSnackbar(error.message);
      });
    }

    // Derive inline validation error text for the plate field.
    final String? plateErrorText =
        error is ValidationError ? error.message : null;

    final bool inFeeSummaryPhase = exitState.openTicket != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vehicle Exit'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Phase 1: Lookup ────────────────────────────────────────
                if (!inFeeSummaryPhase) ...[
                  // Plate number field
                  TextFormField(
                    controller: _plateController,
                    decoration: InputDecoration(
                      labelText: 'Plate Number',
                      prefixIcon: const Icon(Icons.directions_car_outlined),
                      border: const OutlineInputBorder(),
                      errorText: plateErrorText,
                      suffixIcon: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _plateController,
                        builder: (context, value, child) {
                          if (value.text.isEmpty) return const SizedBox.shrink();
                          return IconButton(
                            icon: const Icon(Icons.clear),
                            tooltip: 'Clear',
                            onPressed: () {
                              _plateController.clear();
                              ref
                                  .read(vehicleExitProvider.notifier)
                                  .clearError();
                            },
                          );
                        },
                      ),
                    ),
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: (_) {
                      // Clear inline error as the user types.
                      if (exitState.error is ValidationError) {
                        ref.read(vehicleExitProvider.notifier).clearError();
                      }
                    },
                    onFieldSubmitted: (_) =>
                        exitState.isLoading ? null : _lookUp(),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Plate number is required';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),

                  // Look Up button
                  FilledButton(
                    onPressed: exitState.isLoading ? null : _lookUp,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: exitState.isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Look Up'),
                  ),
                ],

                // ── Phase 2: Fee summary ───────────────────────────────────
                if (inFeeSummaryPhase) ...[
                  _FeeSummaryCard(
                    ticket: exitState.openTicket!,
                    fee: exitState.computedFee!.toDisplay(),
                    durationMinutes: exitState.durationMinutes ?? 0,
                  ),
                  const SizedBox(height: 24),

                  // Confirm Exit button (filled)
                  FilledButton(
                    onPressed: exitState.isLoading ? null : _confirmExit,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: exitState.isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Confirm Exit'),
                  ),
                  const SizedBox(height: 12),

                  // Cancel button (outlined)
                  OutlinedButton(
                    onPressed: exitState.isLoading ? null : _cancelExit,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: const Text('Cancel'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _FeeSummaryCard
// ---------------------------------------------------------------------------

/// Displays a fee summary card with plate, entry time, exit time (now),
/// duration, and computed fee.
class _FeeSummaryCard extends StatelessWidget {
  final Ticket ticket;
  final String fee;
  final int durationMinutes;

  const _FeeSummaryCard({
    required this.ticket,
    required this.fee,
    required this.durationMinutes,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formatter = DateFormat('MMM d, yyyy  h:mm a');

    final String formattedEntry =
        formatter.format(ticket.entryTime.toLocal());
    final String formattedExit = formatter.format(DateTime.now().toLocal());
    final String duration =
        '${durationMinutes ~/ 60}h ${durationMinutes % 60}m';

    return Card(
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
            // ── Header ─────────────────────────────────────────────────────
            Row(
              children: [
                Icon(
                  Icons.receipt_long_outlined,
                  color: theme.colorScheme.primary,
                  size: 28,
                ),
                const SizedBox(width: 8),
                Text(
                  'Fee Summary',
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

            // ── Plate number ───────────────────────────────────────────────
            _InfoRow(
              icon: Icons.directions_car_outlined,
              label: 'Plate Number',
              value: ticket.plateNumber,
              valueStyle: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 12),

            // ── Entry time ─────────────────────────────────────────────────
            _InfoRow(
              icon: Icons.login_outlined,
              label: 'Entry Time',
              value: formattedEntry,
            ),
            const SizedBox(height: 12),

            // ── Exit time ──────────────────────────────────────────────────
            _InfoRow(
              icon: Icons.logout_outlined,
              label: 'Exit Time',
              value: formattedExit,
            ),
            const SizedBox(height: 12),

            // ── Duration ───────────────────────────────────────────────────
            _InfoRow(
              icon: Icons.timer_outlined,
              label: 'Duration',
              value: duration,
            ),
            const SizedBox(height: 12),

            const Divider(),
            const SizedBox(height: 12),

            // ── Fee ────────────────────────────────────────────────────────
            _InfoRow(
              icon: Icons.attach_money_outlined,
              label: 'Fee',
              value: fee,
              valueStyle: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
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
