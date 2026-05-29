import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/result.dart';
import '../../core/router.dart';
import '../../models/ticket.dart';
import '../auth/auth_provider.dart';
import 'vehicle_entry_provider.dart';

// ---------------------------------------------------------------------------
// VehicleEntryScreen
// ---------------------------------------------------------------------------

/// Vehicle entry screen — allows an attendant to record a vehicle's arrival.
///
/// Presents a plate number field and a submit button. On success, a
/// confirmation card is shown with the plate number and entry time. On
/// [ValidationError] an inline field error is displayed. On [BusinessError]
/// (duplicate plate, no pricing rule) a floating snackbar is shown.
///
/// Also watches [accessDeniedProvider] and shows an "Access denied" snackbar
/// when an attendant is redirected from an owner-only route.
///
/// Requirements: 3.1, 3.2, 3.3, 3.5, 3.6
class VehicleEntryScreen extends ConsumerStatefulWidget {
  const VehicleEntryScreen({super.key});

  @override
  ConsumerState<VehicleEntryScreen> createState() => _VehicleEntryScreenState();
}

class _VehicleEntryScreenState extends ConsumerState<VehicleEntryScreen> {
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
  // _submit
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final plate = _plateController.text.trim();
    final authState = ref.read(authProvider);

    // createdBy comes from the authenticated user's username.
    final createdBy = authState is Authenticated ? authState.username : '';

    await ref.read(vehicleEntryProvider.notifier).submitEntry(plate, createdBy);
  }

  // ---------------------------------------------------------------------------
  // _resetForm
  // ---------------------------------------------------------------------------

  void _resetForm() {
    _plateController.clear();
    _formKey.currentState?.reset();
    ref.read(vehicleEntryProvider.notifier).reset();
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
    final entryState = ref.watch(vehicleEntryProvider);
    final accessDenied = ref.watch(accessDeniedProvider);

    // Show "Access denied" snackbar when redirected from an owner-only route.
    if (accessDenied) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showSnackbar(
          'Access denied. You do not have permission to view that page.',
        );
        ref.read(accessDeniedProvider.notifier).state = false;
      });
    }

    // Show BusinessError as a floating snackbar (only once per error instance).
    final error = entryState.error;
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vehicle Entry'),
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
                // ── Plate number field ─────────────────────────────────────
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
                            // Clear any inline error when the field is cleared.
                            ref
                                .read(vehicleEntryProvider.notifier)
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
                    if (entryState.error is ValidationError) {
                      ref.read(vehicleEntryProvider.notifier).clearError();
                    }
                  },
                  onFieldSubmitted: (_) =>
                      entryState.isLoading ? null : _submit(),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Plate number is required';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 24),

                // ── Submit button ──────────────────────────────────────────
                FilledButton(
                  onPressed: entryState.isLoading ? null : _submit,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: entryState.isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Record Entry'),
                ),
                const SizedBox(height: 32),

                // ── Confirmation card ──────────────────────────────────────
                if (entryState.lastCreatedTicket != null)
                  _ConfirmationCard(
                    ticket: entryState.lastCreatedTicket!,
                    onNewEntry: _resetForm,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ConfirmationCard
// ---------------------------------------------------------------------------

/// Displays a confirmation card after a successful vehicle entry.
///
/// Shows the plate number, formatted entry time, and a "New Entry" button
/// to reset the form for the next vehicle.
class _ConfirmationCard extends StatelessWidget {
  final Ticket ticket;
  final VoidCallback onNewEntry;

  const _ConfirmationCard({
    required this.ticket,
    required this.onNewEntry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Format entry time as local date/time using intl.
    final localEntryTime = ticket.entryTime.toLocal();
    final formattedTime =
        DateFormat('MMM d, yyyy  h:mm a').format(localEntryTime);

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
                  Icons.check_circle_outline,
                  color: theme.colorScheme.primary,
                  size: 28,
                ),
                const SizedBox(width: 8),
                Text(
                  'Entry Recorded',
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
              icon: Icons.access_time_outlined,
              label: 'Entry Time',
              value: formattedTime,
            ),
            const SizedBox(height: 20),

            // ── New Entry button ───────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onNewEntry,
                icon: const Icon(Icons.add),
                label: const Text('New Entry'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
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
