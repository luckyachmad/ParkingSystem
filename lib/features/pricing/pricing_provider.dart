import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/result.dart';
import '../../models/pricing_rule.dart';
import '../../repositories/pricing_repository.dart';
import '../vehicle_entry/vehicle_entry_provider.dart' show pricingRepositoryProvider;

// ---------------------------------------------------------------------------
// PricingState
// ---------------------------------------------------------------------------

/// Immutable state for the pricing management feature.
///
/// - [rules]     — the current list of active pricing rules.
/// - [isLoading] — true while any async operation is in progress.
/// - [error]     — typed error from the last failed operation; null on success.
class PricingState {
  final List<PricingRule> rules;
  final bool isLoading;
  final AppError? error;

  const PricingState({
    required this.rules,
    required this.isLoading,
    this.error,
  });

  /// Returns a copy of this state with the supplied fields replaced.
  ///
  /// The [rules] field is non-nullable with a default of `const []`, so no
  /// sentinel pattern is needed for it. The nullable [error] field uses the
  /// sentinel pattern so callers can explicitly pass `null` to clear it.
  PricingState copyWith({
    List<PricingRule>? rules,
    bool? isLoading,
    Object? error = _sentinel,
  }) {
    return PricingState(
      rules: rules ?? this.rules,
      isLoading: isLoading ?? this.isLoading,
      error: identical(error, _sentinel) ? this.error : error as AppError?,
    );
  }
}

// Sentinel object used to distinguish "not provided" from explicit null in copyWith.
const Object _sentinel = Object();

// ---------------------------------------------------------------------------
// PricingNotifier
// ---------------------------------------------------------------------------

/// Manages state for the pricing rules management feature.
///
/// Delegates all persistence operations to [PricingRepository]. Each mutating
/// operation follows the pattern:
/// 1. Set [isLoading] = true, clear any previous error.
/// 2. Call the relevant repository method.
/// 3. On [Failure]: set error, [isLoading] = false, return.
/// 4. On [Success]: call [loadRules] to refresh the list.
///
/// Requirements: 6.1, 6.2, 6.3, 6.5, 6.6, 6.7
class PricingNotifier extends StateNotifier<PricingState> {
  final PricingRepository _pricingRepository;

  PricingNotifier(this._pricingRepository)
      : super(const PricingState(rules: [], isLoading: false));

  // ---------------------------------------------------------------------------
  // loadRules
  // ---------------------------------------------------------------------------

  /// Loads all active pricing rules from the repository.
  ///
  /// Sets [isLoading] = true while the query is in flight. On success, updates
  /// [rules] and clears [isLoading]. On exception, sets a [DatabaseError] and
  /// clears [isLoading].
  Future<void> loadRules() async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final rules = await _pricingRepository.findAllActive();
      state = state.copyWith(rules: rules, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: DatabaseError(
          operation: 'load pricing rules',
          message: e.toString(),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // addRule
  // ---------------------------------------------------------------------------

  /// Inserts [rule] into the repository and reloads the rule list on success.
  ///
  /// On [Failure], sets the error state and stops loading without reloading.
  Future<void> addRule(PricingRule rule) async {
    state = state.copyWith(isLoading: true, error: null);

    final result = await _pricingRepository.insert(rule);
    switch (result) {
      case Failure<int>(:final error):
        state = state.copyWith(isLoading: false, error: error);
        return;
      case Success<int>():
        await loadRules();
    }
  }

  // ---------------------------------------------------------------------------
  // updateRule
  // ---------------------------------------------------------------------------

  /// Updates [rule] in the repository and reloads the rule list on success.
  ///
  /// On [Failure], sets the error state and stops loading without reloading.
  Future<void> updateRule(PricingRule rule) async {
    state = state.copyWith(isLoading: true, error: null);

    final result = await _pricingRepository.update(rule);
    switch (result) {
      case Failure<void>(:final error):
        state = state.copyWith(isLoading: false, error: error);
        return;
      case Success<void>():
        await loadRules();
    }
  }

  // ---------------------------------------------------------------------------
  // deactivateRule
  // ---------------------------------------------------------------------------

  /// Soft-deletes the rule identified by [ruleId] and reloads the list on success.
  ///
  /// On [Failure], sets the error state and stops loading without reloading.
  Future<void> deactivateRule(int ruleId) async {
    state = state.copyWith(isLoading: true, error: null);

    final result = await _pricingRepository.deactivate(ruleId);
    switch (result) {
      case Failure<void>(:final error):
        state = state.copyWith(isLoading: false, error: error);
        return;
      case Success<void>():
        await loadRules();
    }
  }

  // ---------------------------------------------------------------------------
  // setDefault
  // ---------------------------------------------------------------------------

  /// Sets [ruleId] as the sole default pricing rule and reloads the list on success.
  ///
  /// On [Failure], sets the error state and stops loading without reloading.
  Future<void> setDefault(int ruleId) async {
    state = state.copyWith(isLoading: true, error: null);

    final result = await _pricingRepository.setDefault(ruleId);
    switch (result) {
      case Failure<void>(:final error):
        state = state.copyWith(isLoading: false, error: error);
        return;
      case Success<void>():
        await loadRules();
    }
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
// pricingProvider
// ---------------------------------------------------------------------------

/// Global provider for [PricingNotifier] / [PricingState].
///
/// Reads [pricingRepositoryProvider] (defined in vehicle_entry_provider.dart)
/// for its [PricingRepository] dependency. Override [pricingRepositoryProvider]
/// in the root [ProviderScope] to inject the real repository implementation.
final pricingProvider =
    StateNotifierProvider<PricingNotifier, PricingState>((ref) {
  final pricingRepository = ref.watch(pricingRepositoryProvider);
  return PricingNotifier(pricingRepository);
});
