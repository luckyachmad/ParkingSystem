import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/plate_validator.dart';
import '../../core/money.dart';
import '../../core/result.dart';
import '../../models/parking_transaction.dart';
import '../../models/pricing_rule.dart';
import '../../models/ticket.dart';
import '../../repositories/ticket_repository.dart';
import '../../repositories/transaction_repository.dart';
import '../../services/fee_calculator.dart';
import '../vehicle_entry/vehicle_entry_provider.dart'
    show ticketRepositoryProvider;

// ---------------------------------------------------------------------------
// VehicleExitState
// ---------------------------------------------------------------------------

/// Immutable state for the vehicle exit screen.
///
/// - [plateInput]            — current value of the plate number text field.
/// - [isLoading]             — true while an async operation is in progress.
/// - [error]                 — typed error from the last failed operation; null on success.
/// - [openTicket]            — the open ticket found by [VehicleExitNotifier.lookupPlate].
/// - [computedFee]           — the fee calculated by [FeeCalculator].
/// - [durationMinutes]       — ceiling of raw seconds / 60.
/// - [confirmed]             — true after [VehicleExitNotifier.confirmExit] succeeds.
/// - [completedTransaction]  — the transaction record created after a successful exit.
class VehicleExitState {
  final String plateInput;
  final bool isLoading;
  final AppError? error;
  final Ticket? openTicket;
  final Money? computedFee;
  final int? durationMinutes;
  final bool confirmed;
  final ParkingTransaction? completedTransaction;

  const VehicleExitState({
    required this.plateInput,
    required this.isLoading,
    this.error,
    this.openTicket,
    this.computedFee,
    this.durationMinutes,
    this.confirmed = false,
    this.completedTransaction,
  });

  /// Returns a copy of this state with the supplied fields replaced.
  ///
  /// Nullable fields ([error], [openTicket], [computedFee], [durationMinutes],
  /// [completedTransaction]) use the sentinel pattern so that callers can
  /// explicitly set them to null.
  VehicleExitState copyWith({
    String? plateInput,
    bool? isLoading,
    bool? confirmed,
    Object? error = _sentinel,
    Object? openTicket = _sentinel,
    Object? computedFee = _sentinel,
    Object? durationMinutes = _sentinel,
    Object? completedTransaction = _sentinel,
  }) {
    return VehicleExitState(
      plateInput: plateInput ?? this.plateInput,
      isLoading: isLoading ?? this.isLoading,
      confirmed: confirmed ?? this.confirmed,
      error: identical(error, _sentinel) ? this.error : error as AppError?,
      openTicket:
          identical(openTicket, _sentinel) ? this.openTicket : openTicket as Ticket?,
      computedFee:
          identical(computedFee, _sentinel) ? this.computedFee : computedFee as Money?,
      durationMinutes: identical(durationMinutes, _sentinel)
          ? this.durationMinutes
          : durationMinutes as int?,
      completedTransaction: identical(completedTransaction, _sentinel)
          ? this.completedTransaction
          : completedTransaction as ParkingTransaction?,
    );
  }
}

// Sentinel object used to distinguish "not provided" from explicit null in copyWith.
const Object _sentinel = Object();

// ---------------------------------------------------------------------------
// Dependency injection placeholder providers
// ---------------------------------------------------------------------------

/// Placeholder provider for [TransactionRepository].
///
/// Overridden in the app's [ProviderScope] (Task 15.1) with a real
/// [TransactionRepositoryImpl] instance. Accessing this provider without an
/// override will throw [UnimplementedError].
final transactionRepositoryProvider = Provider<TransactionRepository>((ref) {
  throw UnimplementedError(
    'transactionRepositoryProvider must be overridden in ProviderScope before use.',
  );
});

/// Placeholder provider for [FeeCalculator].
///
/// [FeeCalculator] is stateless and has no dependencies, so this provider
/// simply constructs a const instance. It can be overridden in tests if needed.
final feeCalculatorProvider = Provider<FeeCalculator>((ref) {
  return const FeeCalculator();
});

// ---------------------------------------------------------------------------
// VehicleExitNotifier
// ---------------------------------------------------------------------------

/// Manages state for the vehicle exit screen.
///
/// Delegates plate validation to [PlateValidator], open-ticket lookup to
/// [TicketRepository], fee calculation to [FeeCalculator], ticket closure to
/// [TicketRepository], and transaction persistence to [TransactionRepository].
///
/// Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8
class VehicleExitNotifier extends StateNotifier<VehicleExitState> {
  final TicketRepository _ticketRepository;
  final TransactionRepository _transactionRepository;
  final FeeCalculator _feeCalculator;

  VehicleExitNotifier(
    this._ticketRepository,
    this._transactionRepository,
    this._feeCalculator,
  ) : super(const VehicleExitState(plateInput: '', isLoading: false));

  // ---------------------------------------------------------------------------
  // lookupPlate
  // ---------------------------------------------------------------------------

  /// Validates [plate], finds the open ticket, and computes the fee.
  ///
  /// Flow:
  /// 1. Set [isLoading] = true, clear error and previous lookup results.
  /// 2. Validate [plate] via [PlateValidator.validate]; on [Failure], set
  ///    [ValidationError] and return.
  /// 3. Call [TicketRepository.findOpenByPlate]; if null, set [BusinessError]
  ///    and return.
  /// 4. Compute [exitTime], [rawSeconds], and [durationMinutes] using the
  ///    ceiling formula.
  /// 5. Reconstruct a [PricingRule] from the ticket's snapshot fields.
  /// 6. Call [FeeCalculator.calculate] to get the [Money] fee.
  /// 7. Update state with [openTicket], [computedFee], [durationMinutes],
  ///    [isLoading] = false.
  Future<void> lookupPlate(String plate) async {
    // Step 1 — start loading, clear previous results.
    state = state.copyWith(
      isLoading: true,
      error: null,
      openTicket: null,
      computedFee: null,
      durationMinutes: null,
    );

    // Step 2 — validate plate number.
    final validationResult = PlateValidator.validate(plate);
    if (validationResult is Failure<String>) {
      state = state.copyWith(
        isLoading: false,
        error: validationResult.error,
      );
      return;
    }

    // Step 3 — find the open ticket.
    final ticket = await _ticketRepository.findOpenByPlate(plate);
    if (ticket == null) {
      state = state.copyWith(
        isLoading: false,
        error: BusinessError('No active parking session found for plate: $plate'),
      );
      return;
    }

    // Step 4 — compute duration using ceiling formula.
    final exitTime = DateTime.now().toUtc();
    final rawSeconds = exitTime.difference(ticket.entryTime).inSeconds;
    final durationMinutes = (rawSeconds / 60).ceil();

    // Step 5 — reconstruct PricingRule from ticket snapshot fields.
    final rule = PricingRule(
      name: ticket.pricingRuleName,
      rateType: ticket.rateType,
      rateAmount: ticket.rateAmount,
      gracePeriodMinutes: ticket.gracePeriodMinutes,
      dailyMaxCap: ticket.dailyMaxCap,
      isActive: true,
      isDefault: false,
    );

    // Step 6 — calculate fee.
    final fee = _feeCalculator.calculate(rule, durationMinutes);

    // Step 7 — update state.
    state = state.copyWith(
      isLoading: false,
      openTicket: ticket,
      computedFee: fee,
      durationMinutes: durationMinutes,
    );
  }

  // ---------------------------------------------------------------------------
  // confirmExit
  // ---------------------------------------------------------------------------

  /// Closes the open ticket and records the transaction.
  ///
  /// Flow:
  /// 1. Guard: if [openTicket] or [computedFee] is null, return early (no-op).
  /// 2. Set [isLoading] = true.
  /// 3. Re-compute [exitTime], [rawSeconds], [durationMinutes] for accuracy.
  /// 4. Call [TicketRepository.closeTicket]; on [Failure], set error and return.
  /// 5. Build a [ParkingTransaction] with all required fields.
  /// 6. Call [TransactionRepository.insert]; on [Failure], set error and return.
  /// 7. Set [confirmed] = true, [completedTransaction], [isLoading] = false.
  Future<void> confirmExit(String closedBy) async {
    final ticket = state.openTicket;
    final fee = state.computedFee;

    // Step 1 — guard: nothing to confirm without a looked-up ticket and fee.
    if (ticket == null || fee == null) return;

    // Step 2 — start loading.
    state = state.copyWith(isLoading: true, error: null);

    // Step 3 — re-compute exit time and duration at confirm time for accuracy.
    final exitTime = DateTime.now().toUtc();
    final rawSeconds = exitTime.difference(ticket.entryTime).inSeconds;
    final durationMinutes = (rawSeconds / 60).ceil();

    // Step 4 — close the ticket in the database.
    final closeResult = await _ticketRepository.closeTicket(
      ticket.id!,
      exitTime,
      closedBy,
    );
    if (closeResult is Failure<void>) {
      state = state.copyWith(
        isLoading: false,
        error: closeResult.error,
      );
      return;
    }

    // Step 5 — build the transaction record.
    final transaction = ParkingTransaction(
      ticketId: ticket.id!,
      plateNumber: ticket.plateNumber,
      entryTime: ticket.entryTime,
      exitTime: exitTime,
      durationMinutes: durationMinutes,
      fee: fee.cents / 100.0,
      paymentStatus: PaymentStatus.paid,
      pricingRuleName: ticket.pricingRuleName,
    );

    // Step 6 — persist the transaction.
    final insertResult = await _transactionRepository.insert(transaction);
    if (insertResult is Failure<int>) {
      state = state.copyWith(
        isLoading: false,
        error: insertResult.error,
      );
      return;
    }

    // Step 7 — mark as confirmed with the completed transaction.
    final completedTransaction = transaction.copyWith(
      id: (insertResult as Success<int>).value,
    );
    state = state.copyWith(
      isLoading: false,
      confirmed: true,
      completedTransaction: completedTransaction,
    );
  }

  // ---------------------------------------------------------------------------
  // cancelExit
  // ---------------------------------------------------------------------------

  /// Resets the exit state without modifying the ticket in the database.
  ///
  /// Clears [openTicket], [computedFee], [durationMinutes], [error], and
  /// [confirmed]. The ticket remains open and the vehicle remains parked.
  void cancelExit() {
    state = const VehicleExitState(plateInput: '', isLoading: false);
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
// vehicleExitProvider
// ---------------------------------------------------------------------------

/// Global provider for [VehicleExitNotifier] / [VehicleExitState].
///
/// Reads [ticketRepositoryProvider], [transactionRepositoryProvider], and
/// [feeCalculatorProvider] for its dependencies. Override the repository
/// placeholder providers in the root [ProviderScope] to inject real
/// implementations.
final vehicleExitProvider =
    StateNotifierProvider<VehicleExitNotifier, VehicleExitState>((ref) {
  final ticketRepository = ref.watch(ticketRepositoryProvider);
  final transactionRepository = ref.watch(transactionRepositoryProvider);
  final feeCalculator = ref.watch(feeCalculatorProvider);
  return VehicleExitNotifier(ticketRepository, transactionRepository, feeCalculator);
});
