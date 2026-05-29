import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../models/parking_transaction.dart';
import '../../models/transaction_filter.dart';
import '../auth/auth_provider.dart';
import 'transaction_provider.dart';

// ---------------------------------------------------------------------------
// TransactionHistoryScreen
// ---------------------------------------------------------------------------

/// Transaction History screen — allows owners/admins to search and review all
/// past parking transactions.
///
/// Provides:
/// - A search bar for plate number substring filtering.
/// - Date range pickers for from/to date filtering.
/// - A payment status dropdown filter (paid / unpaid / cancelled / all).
/// - A scrollable list of transaction rows ordered by exit time descending.
/// - A detail bottom sheet on row tap showing all fields from Requirement 8.5.
/// - An empty-state message "No transactions found" when no results match.
///
/// Watches [transactionProvider] and calls [loadTransactions] on every filter
/// change.
///
/// Requirements: 8.1, 8.2, 8.3, 8.5, 8.6
class TransactionHistoryScreen extends ConsumerStatefulWidget {
  const TransactionHistoryScreen({super.key});

  @override
  ConsumerState<TransactionHistoryScreen> createState() =>
      _TransactionHistoryScreenState();
}

class _TransactionHistoryScreenState
    extends ConsumerState<TransactionHistoryScreen> {
  // ── Filter state ──────────────────────────────────────────────────────────

  final TextEditingController _searchController = TextEditingController();

  /// Selected from-date (inclusive, start of day in local time).
  DateTime? _fromDate;

  /// Selected to-date (inclusive, end of day in local time).
  DateTime? _toDate;

  /// Selected payment status filter; null means "all statuses".
  PaymentStatus? _selectedStatus;

  // ── Debounce ──────────────────────────────────────────────────────────────

  /// Tracks the last search text to avoid redundant loads on rebuild.
  String _lastSearchText = '';

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    // Load all transactions with no filter on first mount.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyFilter();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // _applyFilter
  // ---------------------------------------------------------------------------

  /// Builds a [TransactionFilter] from the current UI state and calls
  /// [TransactionNotifier.loadTransactions].
  void _applyFilter() {
    final plateText = _searchController.text.trim();
    final filter = TransactionFilter(
      plateSubstring: plateText.isEmpty ? null : plateText,
      fromDate: _fromDate,
      toDate: _toDate,
      paymentStatus: _selectedStatus,
    );
    ref.read(transactionProvider.notifier).loadTransactions(filter);
  }

  // ---------------------------------------------------------------------------
  // _pickFromDate
  // ---------------------------------------------------------------------------

  Future<void> _pickFromDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _fromDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: _toDate ?? DateTime.now(),
      helpText: 'Select start date',
    );
    if (picked != null) {
      setState(() {
        // Start of the selected day in local time.
        _fromDate = DateTime(picked.year, picked.month, picked.day);
      });
      _applyFilter();
    }
  }

  // ---------------------------------------------------------------------------
  // _pickToDate
  // ---------------------------------------------------------------------------

  Future<void> _pickToDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _toDate ?? DateTime.now(),
      firstDate: _fromDate ?? DateTime(2000),
      lastDate: DateTime.now(),
      helpText: 'Select end date',
    );
    if (picked != null) {
      setState(() {
        // End of the selected day in local time (23:59:59.999).
        _toDate = DateTime(
          picked.year,
          picked.month,
          picked.day,
          23,
          59,
          59,
          999,
        );
      });
      _applyFilter();
    }
  }

  // ---------------------------------------------------------------------------
  // _clearFilters
  // ---------------------------------------------------------------------------

  void _clearFilters() {
    setState(() {
      _searchController.clear();
      _lastSearchText = '';
      _fromDate = null;
      _toDate = null;
      _selectedStatus = null;
    });
    ref.read(transactionProvider.notifier).clearFilter();
  }

  // ---------------------------------------------------------------------------
  // _hasActiveFilters
  // ---------------------------------------------------------------------------

  bool get _hasActiveFilters =>
      _searchController.text.trim().isNotEmpty ||
      _fromDate != null ||
      _toDate != null ||
      _selectedStatus != null;

  // ---------------------------------------------------------------------------
  // _logout
  // ---------------------------------------------------------------------------

  Future<void> _logout() async {
    await ref.read(authProvider.notifier).logout();
  }

  // ---------------------------------------------------------------------------
  // _openDetailSheet
  // ---------------------------------------------------------------------------

  void _openDetailSheet(ParkingTransaction tx) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _TransactionDetailSheet(transaction: tx),
    );
  }

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final txState = ref.watch(transactionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transaction History'),
        actions: [
          if (_hasActiveFilters)
            IconButton(
              icon: const Icon(Icons.filter_alt_off_outlined),
              tooltip: 'Clear filters',
              onPressed: _clearFilters,
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
          // ── Filter panel ─────────────────────────────────────────────────
          _FilterPanel(
            searchController: _searchController,
            fromDate: _fromDate,
            toDate: _toDate,
            selectedStatus: _selectedStatus,
            onSearchChanged: (text) {
              // Only reload when the text actually changed.
              if (text.trim() != _lastSearchText) {
                _lastSearchText = text.trim();
                _applyFilter();
              }
            },
            onPickFromDate: _pickFromDate,
            onPickToDate: _pickToDate,
            onStatusChanged: (status) {
              setState(() => _selectedStatus = status);
              _applyFilter();
            },
          ),

          // ── Transaction list ─────────────────────────────────────────────
          Expanded(
            child: _buildBody(txState),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // _buildBody
  // ---------------------------------------------------------------------------

  Widget _buildBody(TransactionState state) {
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.transactions.isEmpty) {
      return const Center(
        child: Text(
          'No transactions found',
          style: TextStyle(fontSize: 16),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: state.transactions.length,
      itemBuilder: (context, index) {
        final tx = state.transactions[index];
        return _TransactionRow(
          transaction: tx,
          onTap: () => _openDetailSheet(tx),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// _FilterPanel
// ---------------------------------------------------------------------------

/// The filter controls: search bar, date range chips, and payment status
/// dropdown.
class _FilterPanel extends StatelessWidget {
  final TextEditingController searchController;
  final DateTime? fromDate;
  final DateTime? toDate;
  final PaymentStatus? selectedStatus;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onPickFromDate;
  final VoidCallback onPickToDate;
  final ValueChanged<PaymentStatus?> onStatusChanged;

  const _FilterPanel({
    required this.searchController,
    required this.fromDate,
    required this.toDate,
    required this.selectedStatus,
    required this.onSearchChanged,
    required this.onPickFromDate,
    required this.onPickToDate,
    required this.onStatusChanged,
  });

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('MMM d, yyyy');

    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Search bar ────────────────────────────────────────────────
          TextField(
            controller: searchController,
            decoration: InputDecoration(
              hintText: 'Search by plate number…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        searchController.clear();
                        onSearchChanged('');
                      },
                    )
                  : null,
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            ),
            textCapitalization: TextCapitalization.characters,
            onChanged: onSearchChanged,
          ),
          const SizedBox(height: 10),

          // ── Date range + status row ───────────────────────────────────
          Row(
            children: [
              // From date chip
              Expanded(
                child: _DateChip(
                  label: fromDate != null
                      ? 'From: ${dateFormat.format(fromDate!)}'
                      : 'From date',
                  isActive: fromDate != null,
                  onTap: onPickFromDate,
                ),
              ),
              const SizedBox(width: 8),

              // To date chip
              Expanded(
                child: _DateChip(
                  label: toDate != null
                      ? 'To: ${dateFormat.format(toDate!)}'
                      : 'To date',
                  isActive: toDate != null,
                  onTap: onPickToDate,
                ),
              ),
              const SizedBox(width: 8),

              // Payment status dropdown
              _StatusDropdown(
                selectedStatus: selectedStatus,
                onChanged: onStatusChanged,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _DateChip
// ---------------------------------------------------------------------------

/// A tappable chip used to display and select a date filter value.
class _DateChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _DateChip({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: isActive
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
          ),
          borderRadius: BorderRadius.circular(8),
          color: isActive
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surface,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.calendar_today_outlined,
              size: 14,
              color: isActive
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isActive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _StatusDropdown
// ---------------------------------------------------------------------------

/// Compact dropdown for selecting a [PaymentStatus] filter.
/// Selecting null means "all statuses".
class _StatusDropdown extends StatelessWidget {
  final PaymentStatus? selectedStatus;
  final ValueChanged<PaymentStatus?> onChanged;

  const _StatusDropdown({
    required this.selectedStatus,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isActive = selectedStatus != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(
          color: isActive
              ? theme.colorScheme.primary
              : theme.colorScheme.outline,
        ),
        borderRadius: BorderRadius.circular(8),
        color: isActive
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surface,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<PaymentStatus?>(
          value: selectedStatus,
          isDense: true,
          hint: Text(
            'Status',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          style: theme.textTheme.bodySmall?.copyWith(
            color: isActive
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface,
          ),
          items: [
            DropdownMenuItem<PaymentStatus?>(
              value: null,
              child: Text(
                'All',
                style: theme.textTheme.bodySmall,
              ),
            ),
            ...PaymentStatus.values.map(
              (s) => DropdownMenuItem<PaymentStatus?>(
                value: s,
                child: Text(
                  _statusLabel(s),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  String _statusLabel(PaymentStatus status) {
    return switch (status) {
      PaymentStatus.paid => 'Paid',
      PaymentStatus.unpaid => 'Unpaid',
      PaymentStatus.cancelled => 'Cancelled',
    };
  }
}

// ---------------------------------------------------------------------------
// _TransactionRow
// ---------------------------------------------------------------------------

/// A single row in the transaction list showing plate, exit time, duration,
/// fee, and payment status. Tapping opens the detail bottom sheet.
class _TransactionRow extends StatelessWidget {
  final ParkingTransaction transaction;
  final VoidCallback onTap;

  const _TransactionRow({
    required this.transaction,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tx = transaction;

    // Convert UTC timestamps to local time for display.
    final exitLocal = tx.exitTime.toLocal();
    final exitFormatted = DateFormat('MMM d, yyyy  h:mm a').format(exitLocal);

    // Format duration as Xh Ym.
    final durationText = _formatDuration(tx.durationMinutes);

    // Format fee: tx.fee is stored as double dollars.
    final feeCents = (tx.fee * 100).round();
    final feeDisplay = Money(feeCents).toDisplay();

    // Status chip colour.
    final (statusLabel, statusColor) = _statusStyle(tx.paymentStatus, theme);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // ── Left: plate + exit time ──────────────────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tx.plateNumber,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      exitFormatted,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),

              // ── Right: duration + fee + status ───────────────────────
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    feeDisplay,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    durationText,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  _StatusBadge(label: statusLabel, color: statusColor),
                ],
              ),

              // ── Chevron ──────────────────────────────────────────────
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Returns a human-readable label and colour for the given [PaymentStatus].
  (String, Color) _statusStyle(PaymentStatus status, ThemeData theme) {
    return switch (status) {
      PaymentStatus.paid => ('Paid', Colors.green),
      PaymentStatus.unpaid => ('Unpaid', Colors.orange),
      PaymentStatus.cancelled => ('Cancelled', theme.colorScheme.error),
    };
  }
}

// ---------------------------------------------------------------------------
// _StatusBadge
// ---------------------------------------------------------------------------

/// A small coloured badge displaying a payment status label.
class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _TransactionDetailSheet
// ---------------------------------------------------------------------------

/// Modal bottom sheet showing the full detail of a [ParkingTransaction].
///
/// Displays all fields required by Requirement 8.5:
/// - Plate number
/// - Entry time (local)
/// - Exit time (local)
/// - Duration (formatted as Xh Ym)
/// - Pricing rule name
/// - Fee (formatted to 2 decimal places with currency symbol)
/// - Payment status
class _TransactionDetailSheet extends StatelessWidget {
  final ParkingTransaction transaction;

  const _TransactionDetailSheet({required this.transaction});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tx = transaction;

    final dtFormat = DateFormat('MMM d, yyyy  h:mm:ss a');
    final entryLocal = tx.entryTime.toLocal();
    final exitLocal = tx.exitTime.toLocal();

    final feeCents = (tx.fee * 100).round();
    final feeDisplay = Money(feeCents).toDisplay();
    final durationText = _formatDuration(tx.durationMinutes);

    final (statusLabel, statusColor) = switch (tx.paymentStatus) {
      PaymentStatus.paid => ('Paid', Colors.green),
      PaymentStatus.unpaid => ('Unpaid', Colors.orange),
      PaymentStatus.cancelled => (
          'Cancelled',
          theme.colorScheme.error,
        ),
    };

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Handle bar ──────────────────────────────────────────────
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Title row ───────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: Text(
                    tx.plateNumber,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                _StatusBadge(label: statusLabel, color: statusColor),
              ],
            ),
            const SizedBox(height: 20),

            // ── Detail rows ─────────────────────────────────────────────
            _DetailRow(
              icon: Icons.login_outlined,
              label: 'Entry Time',
              value: dtFormat.format(entryLocal),
            ),
            _DetailRow(
              icon: Icons.logout_outlined,
              label: 'Exit Time',
              value: dtFormat.format(exitLocal),
            ),
            _DetailRow(
              icon: Icons.timer_outlined,
              label: 'Duration',
              value: durationText,
            ),
            _DetailRow(
              icon: Icons.price_change_outlined,
              label: 'Pricing Rule',
              value: tx.pricingRuleName,
            ),
            _DetailRow(
              icon: Icons.attach_money,
              label: 'Fee',
              value: feeDisplay,
              valueStyle: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            _DetailRow(
              icon: Icons.payment_outlined,
              label: 'Payment Status',
              value: statusLabel,
              valueStyle: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: statusColor,
              ),
            ),

            // ── Transaction ID (for audit reference) ────────────────────
            if (tx.id != null)
              _DetailRow(
                icon: Icons.tag,
                label: 'Transaction ID',
                value: '#${tx.id}',
              ),

            const SizedBox(height: 8),

            // ── Close button ────────────────────────────────────────────
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _DetailRow
// ---------------------------------------------------------------------------

/// A single labelled row in the detail sheet.
class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final TextStyle? valueStyle;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueStyle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
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
                  style: valueStyle ?? theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Formats a duration in minutes as "Xh Ym" (e.g. "1h 30m", "45m", "2h 0m").
String _formatDuration(int totalMinutes) {
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours == 0) return '${minutes}m';
  return '${hours}h ${minutes}m';
}
