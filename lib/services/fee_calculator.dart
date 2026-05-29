import 'dart:math';

import '../core/money.dart';
import '../models/pricing_rule.dart';

/// Stateless service that computes a parking fee from a [PricingRule] snapshot
/// and a duration expressed in whole minutes.
///
/// All arithmetic is performed in integer cents to avoid floating-point errors.
/// The [PricingRule.rateAmount] and [PricingRule.dailyMaxCap] fields are stored
/// as `double` dollars in the Dart model; they are converted to cents by
/// multiplying by 100 and rounding before any calculation.
///
/// Algorithm (four steps):
///   1. Grace period check  — return zero if duration ≤ gracePeriodMinutes.
///   2. Base fee            — flat rate OR ceiling-hours × hourly rate (cents).
///   3. Daily cap           — clamp to dailyMaxCap when duration ≤ 1440 min.
///   4. Floor               — ensure fee is never negative.
class FeeCalculator {
  const FeeCalculator();

  /// Calculates the parking fee.
  ///
  /// [rule] is the pricing rule snapshot attached to the ticket.
  /// [durationMinutes] is the session length in whole minutes (≥ 0), already
  /// rounded up by the caller.
  ///
  /// Returns a [Money] value wrapping the fee in integer cents.
  Money calculate(PricingRule rule, int durationMinutes) {
    // Step 1 — Grace period: sessions within the grace window are free.
    if (durationMinutes <= rule.gracePeriodMinutes) {
      return const Money(0);
    }

    // Convert dollar amounts to integer cents for all subsequent arithmetic.
    final rateAmountCents = (rule.rateAmount * 100).round();

    // Step 2 — Base fee.
    int feeCents;
    if (rule.rateType == RateType.flat) {
      feeCents = rateAmountCents;
    } else {
      // RateType.hourly — round up to the next full hour.
      final hoursRoundedUp = (durationMinutes / 60).ceil();
      feeCents = hoursRoundedUp * rateAmountCents;
    }

    // Step 3 — Daily cap: only applied when the session is ≤ 24 hours.
    if (rule.dailyMaxCap != null && durationMinutes <= 1440) {
      final capCents = (rule.dailyMaxCap! * 100).round();
      feeCents = min(feeCents, capCents);
    }

    // Step 4 — Floor: fee must never be negative.
    return Money(max(0, feeCents));
  }
}
