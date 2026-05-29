import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/plate_validator.dart';
import '../../core/result.dart';
import '../../models/ticket.dart';
import '../../repositories/pricing_repository.dart';
import '../../repositories/ticket_repository.dart';

// ---------------------------------------------------------------------------
// VehicleEntryState
// ---------------------------------------------------------------------------

/// Immutable state for the vehicle entry screen.
///
/// - [plateInput]        — current value of the plate number text field.
/// - [isLoading]         — true while [VehicleEntryNotifier.submitEntry] is running.
/// - [error]             — typed error from the last failed submission; null on success.
/// - [lastCreatedTicket] — the ticket produced by the most recent successful submission.
class VehicleEntryState {
  final String plateInput;
  final bool isLoading;
  final AppError? error;
  final Ticket? lastCreatedTicket;

  const VehicleEntryState({
    required this.plateInput,
    required this.isLoading,
    this.error,
    this.lastCreatedTicket,
  });

  /// Returns a copy of this state with the supplied fields replaced.
  VehicleEntryState copyWith({
    String? plateInput,
    bool? isLoading,
    Object? error = _sentinel,
    Object? lastCreatedTicket = _sentinel,
  }) {
    return VehicleEntryState(
      plateInput: plateInput ?? this.plateInput,
      isLoading: isLoading ?? this.isLoading,
      error: identical(error, _sentinel) ? this.error : error as AppError?,
      lastCreatedTicket: identical(lastCreatedTicket, _sentinel)
          ? this.lastCreatedTicket
          : lastCreatedTicket as Ticket?,
    );
  }
}

// Sentinel object used to distinguish "not provided" from explicit null in copyWith.
const Object _sentinel = Object();

// ---------------------------------------------------------------------------
// Dependency injection placeholder providers
// ---------------------------------------------------------------------------

/// Placeholder provider for [PricingRepository].
///
/// Overridden in the app's [ProviderScope] (Task 15.1) with a real
/// [PricingRepositoryImpl] instance. Accessing this provider without an
/// override will throw [UnimplementedError].
final pricingRepositoryProvider = Provider<PricingRepository>((ref) {
  throw UnimplementedError(
    'pricingRepositoryProvider must be overridden in ProviderScope before use.',
  );
});

/// Placeholder provider for [TicketRepository].
///
/// Overridden in the app's [ProviderScope] (Task 15.1) with a real
/// [TicketRepositoryImpl] instance. Accessing this provider without an
/// override will throw [UnimplementedError].
final ticketRepositoryProvider = Provider<TicketRepository>((ref) {
  throw UnimplementedError(
    'ticketRepositoryProvider must be overridden in ProviderScope before use.',
  );
});

// ---------------------------------------------------------------------------
// VehicleEntryNotifier
// ---------------------------------------------------------------------------

/// Manages state for the vehicle entry screen.
///
/// Delegates plate validation to [PlateValidator], pricing rule lookup to
/// [PricingRepository], and ticket persistence to [TicketRepository].
///
/// Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6
class VehicleEntryNotifier extends StateNotifier<VehicleEntryState> {
  final PricingRepository _pricingRepository;
  final TicketRepository _ticketRepository;

  VehicleEntryNotifier(this._pricingRepository, this._ticketRepository)
      : super(const VehicleEntryState(plateInput: '', isLoading: false));

  // ---------------------------------------------------------------------------
  // submitEntry
  // ---------------------------------------------------------------------------

  /// Validates [plate], looks up the default pricing rule, and creates a ticket.
  ///
  /// Flow:
  /// 1. Set [isLoading] = true, clear any previous error.
  /// 2. Validate [plate] via [PlateValidator.validate]; on [Failure], set error
  ///    state and return.
  /// 3. Fetch the default pricing rule via [PricingRepository.findDefault]; if
  ///    null, set a [BusinessError] and return.
  /// 4. Build a [Ticket] with a UTC entry time and a full snapshot of the
  ///    pricing rule fields.
  /// 5. Insert the ticket via [TicketRepository.insert]; on [Failure], set error
  ///    state; on [Success], set [lastCreatedTicket].
  /// 6. Set [isLoading] = false.
  Future<void> submitEntry(String plate, String createdBy) async {
    // Step 1 — start loading, clear previous error and last ticket.
    state = state.copyWith(
      isLoading: true,
      error: null,
      lastCreatedTicket: null,
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

    // Step 3 — fetch the default pricing rule.
    final pricingRule = await _pricingRepository.findDefault();
    if (pricingRule == null) {
      state = state.copyWith(
        isLoading: false,
        error: const BusinessError('No active pricing rule configured'),
      );
      return;
    }

    // Step 4 — build the ticket with a pricing rule snapshot.
    final ticket = Ticket(
      plateNumber: plate,
      entryTime: DateTime.now().toUtc(),
      pricingRuleId: pricingRule.id!,
      pricingRuleName: pricingRule.name,
      rateType: pricingRule.rateType,
      rateAmount: pricingRule.rateAmount,
      gracePeriodMinutes: pricingRule.gracePeriodMinutes,
      dailyMaxCap: pricingRule.dailyMaxCap,
      createdBy: createdBy,
    );

    // Step 5 — persist the ticket.
    final insertResult = await _ticketRepository.insert(ticket);
    switch (insertResult) {
      case Success<int>(:final value):
        // Attach the generated id to the ticket so callers can reference it.
        final createdTicket = ticket.copyWith(id: value);
        state = state.copyWith(
          isLoading: false,
          lastCreatedTicket: createdTicket,
        );

      case Failure<int>(:final error):
        state = state.copyWith(
          isLoading: false,
          error: error,
        );
    }
  }

  // ---------------------------------------------------------------------------
  // clearError
  // ---------------------------------------------------------------------------

  /// Clears the current error without changing any other state.
  void clearError() {
    state = state.copyWith(error: null);
  }

  // ---------------------------------------------------------------------------
  // reset
  // ---------------------------------------------------------------------------

  /// Resets the state to its initial value.
  ///
  /// Useful when navigating away from the entry screen so that stale data
  /// does not appear on the next visit.
  void reset() {
    state = const VehicleEntryState(plateInput: '', isLoading: false);
  }
}

// ---------------------------------------------------------------------------
// vehicleEntryProvider
// ---------------------------------------------------------------------------

/// Global provider for [VehicleEntryNotifier] / [VehicleEntryState].
///
/// Reads [pricingRepositoryProvider] and [ticketRepositoryProvider] for its
/// dependencies. Override both placeholder providers in the root [ProviderScope]
/// to inject the real repository implementations.
final vehicleEntryProvider =
    StateNotifierProvider<VehicleEntryNotifier, VehicleEntryState>((ref) {
  final pricingRepository = ref.watch(pricingRepositoryProvider);
  final ticketRepository = ref.watch(ticketRepositoryProvider);
  return VehicleEntryNotifier(pricingRepository, ticketRepository);
});
