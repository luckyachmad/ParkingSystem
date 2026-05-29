import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/result.dart';
import '../../models/parking_transaction.dart';
import '../../models/transaction_filter.dart';
import '../../repositories/transaction_repository.dart';
import '../vehicle_exit/vehicle_exit_provider.dart' show transactionRepositoryProvider;

// ---------------------------------------------------------------------------
// TransactionState
// ---------------------------------------------------------------------------

/// Immutable state for the transaction history screen.
///
/// - [transactions] — the list of transactions matching the current [filter].
/// - [filter]       — the active filter applied to the last query.
/// - [isLoading]    — true while an async operation is in progress.
/// - [error]        — typed error from the last failed operation; null on success.
class TransactionState {
  final List<ParkingTransaction> transactions;
  final TransactionFilter filter;
  final bool isLoading;
  final AppError? error;

  const TransactionState({
    required this.transactions,
    required this.filter,
    required this.isLoading,
    this.error,
  });

  /// Returns a copy of this state with the supplied fields replaced.
  ///
  /// The nullable [error] field uses the sentinel pattern so callers can
  /// explicitly set it to null.
  TransactionState copyWith({
    List<ParkingTransaction>? transactions,
    TransactionFilter? filter,
    bool? isLoading,
    Object? error = _sentinel,
  }) {
    return TransactionState(
      transactions: transactions ?? this.transactions,
      filter: filter ?? this.filter,
      isLoading: isLoading ?? this.isLoading,
      error: identical(error, _sentinel) ? this.error : error as AppError?,
    );
  }
}

// Sentinel object used to distinguish "not provided" from explicit null in copyWith.
const Object _sentinel = Object();

// ---------------------------------------------------------------------------
// TransactionNotifier
// ---------------------------------------------------------------------------

/// Manages state for the transaction history screen.
///
/// Delegates all data access to [TransactionRepository]. Supports filtering
/// by date range, plate substring, and payment status via [TransactionFilter].
///
/// Requirements: 8.1, 8.2, 8.3
class TransactionNotifier extends StateNotifier<TransactionState> {
  final TransactionRepository _repository;

  TransactionNotifier(this._repository)
      : super(const TransactionState(
          transactions: [],
          filter: TransactionFilter(),
          isLoading: false,
        ));

  // ---------------------------------------------------------------------------
  // loadTransactions
  // ---------------------------------------------------------------------------

  /// Loads transactions matching [filter] from the repository.
  ///
  /// Flow:
  /// 1. Set [isLoading] = true, clear error, store the new [filter].
  /// 2. Call [TransactionRepository.query] with the given [filter].
  /// 3. On success: set [transactions], [isLoading] = false.
  /// 4. On failure: set [DatabaseError], [isLoading] = false.
  Future<void> loadTransactions(TransactionFilter filter) async {
    // Step 1 — start loading, clear previous error, store new filter.
    state = state.copyWith(
      isLoading: true,
      error: null,
      filter: filter,
    );

    // Step 2 — query the repository.
    try {
      final result = await _repository.query(filter);

      switch (result) {
        case Success<List<ParkingTransaction>>(:final value):
          // Step 3 — success: update transactions and stop loading.
          state = state.copyWith(
            transactions: value,
            isLoading: false,
          );

        case Failure<List<ParkingTransaction>>(:final error):
          // Step 4 — failure: store error and stop loading.
          state = state.copyWith(
            isLoading: false,
            error: error,
          );
      }
    } catch (e) {
      // Step 4 — unexpected exception: wrap in DatabaseError and stop loading.
      state = state.copyWith(
        isLoading: false,
        error: DatabaseError(
          operation: 'query transactions',
          message: e.toString(),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // clearFilter
  // ---------------------------------------------------------------------------

  /// Resets the filter to an empty [TransactionFilter] and reloads all
  /// transactions.
  Future<void> clearFilter() async {
    await loadTransactions(const TransactionFilter());
  }

  // ---------------------------------------------------------------------------
  // clearError
  // ---------------------------------------------------------------------------

  /// Clears the current error without changing any other state.
  void clearError() {
    state = state.copyWith(error: null);
  }
}

// ---------------------------------------------------------------------------
// transactionProvider
// ---------------------------------------------------------------------------

/// Global provider for [TransactionNotifier] / [TransactionState].
///
/// Reads [transactionRepositoryProvider] (defined in vehicle_exit_provider.dart)
/// for its [TransactionRepository] dependency. Override
/// [transactionRepositoryProvider] in the root [ProviderScope] to inject the
/// real implementation.
final transactionProvider =
    StateNotifierProvider<TransactionNotifier, TransactionState>((ref) {
  final repository = ref.watch(transactionRepositoryProvider);
  return TransactionNotifier(repository);
});
