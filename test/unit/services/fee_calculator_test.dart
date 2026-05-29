// ignore_for_file: avoid_print

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:parking_system/core/money.dart';
import 'package:parking_system/models/pricing_rule.dart';
import 'package:parking_system/services/fee_calculator.dart';

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Rounds a double to 2 decimal places (mirrors how rateAmount / dailyMaxCap
/// are stored: whole-cent values).
double _round2(double v) => (v * 100).roundToDouble() / 100;

/// Produces a [PricingRule] with randomised but valid fields.
///
/// - rateType: randomly hourly or flat
/// - rateAmount: random double in [0.01, 9999.99] (2 dp)
/// - gracePeriodMinutes: random int in [0, 60]
/// - dailyMaxCap: 50 % chance null, otherwise random double in [0.01, 9999.99]
/// - isActive: true, isDefault: false, name: 'test_rule', id: null
PricingRule validPricingRuleGen(Random rng) {
  final rateType = rng.nextBool() ? RateType.hourly : RateType.flat;
  final rateAmount = _round2(0.01 + rng.nextDouble() * 9999.98);
  final gracePeriodMinutes = rng.nextInt(61); // [0, 60]
  final double? dailyMaxCap =
      rng.nextBool() ? null : _round2(0.01 + rng.nextDouble() * 9999.98);

  return PricingRule(
    id: null,
    name: 'test_rule',
    rateType: rateType,
    rateAmount: rateAmount,
    gracePeriodMinutes: gracePeriodMinutes,
    dailyMaxCap: dailyMaxCap,
    isActive: true,
    isDefault: false,
  );
}

/// Produces a random duration in [0, 2880] minutes (0 to 48 hours).
int durationMinutesGen(Random rng) => rng.nextInt(2881); // [0, 2880]

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  const calculator = FeeCalculator();
  // Fixed seed for reproducibility; varied inputs come from iteration index.
  final rng = Random(42);
  const iterations = 100;

  // -------------------------------------------------------------------------
  // Property 12 — Fee is non-negative for all valid inputs
  // Validates: Requirements 5.5
  // -------------------------------------------------------------------------
  group('Property 12 — Fee is non-negative for all valid inputs', () {
    test(
        '**Validates: Requirements 5.5** '
        'FeeCalculator.calculate never returns a negative amount', () {
      for (var i = 0; i < iterations; i++) {
        final rule = validPricingRuleGen(rng);
        final duration = durationMinutesGen(rng);

        final Money fee = calculator.calculate(rule, duration);

        expect(
          fee.cents,
          greaterThanOrEqualTo(0),
          reason: 'Iteration $i: fee.cents=${fee.cents} is negative '
              '(rule=${rule.rateType}, rateAmount=${rule.rateAmount}, '
              'grace=${rule.gracePeriodMinutes}, cap=${rule.dailyMaxCap}, '
              'duration=$duration)',
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // Property 13 — Hourly fee equals ceiling-hours times rate
  // Validates: Requirements 5.2
  // -------------------------------------------------------------------------
  group('Property 13 — Hourly fee equals ceiling-hours times rate', () {
    test(
        '**Validates: Requirements 5.2** '
        'For hourly rules outside the grace period the fee matches '
        'ceil(duration/60) * rateCents (capped when applicable)', () {
      var checked = 0;
      // Keep generating until we have 100 qualifying samples.
      final localRng = Random(42);
      while (checked < iterations) {
        final rule = validPricingRuleGen(localRng);
        final duration = durationMinutesGen(localRng);

        // Property only applies to hourly rules outside the grace period.
        if (rule.rateType != RateType.hourly) continue;
        if (duration <= rule.gracePeriodMinutes) continue;

        final Money fee = calculator.calculate(rule, duration);

        final int rateCents = (rule.rateAmount * 100).round();
        final int hoursUp = (duration / 60).ceil();
        final int expectedCents = hoursUp * rateCents;

        // Apply cap when duration ≤ 1440 and cap is set.
        final int capCents =
            (rule.dailyMaxCap != null && duration <= 1440)
                ? (rule.dailyMaxCap! * 100).round()
                : expectedCents;

        final int expectedFinal = min(expectedCents, capCents);

        expect(
          fee.cents,
          equals(expectedFinal),
          reason: 'Iteration $checked: fee.cents=${fee.cents} != '
              'expected=$expectedFinal '
              '(hoursUp=$hoursUp, rateCents=$rateCents, '
              'cap=${rule.dailyMaxCap}, duration=$duration)',
        );

        checked++;
      }
    });
  });

  // -------------------------------------------------------------------------
  // Property 14 — Grace period produces zero fee
  // Validates: Requirements 5.3
  // -------------------------------------------------------------------------
  group('Property 14 — Grace period produces zero fee', () {
    test(
        '**Validates: Requirements 5.3** '
        'Any duration within the grace window results in a zero fee', () {
      var checked = 0;
      final localRng = Random(42);
      while (checked < iterations) {
        final rule = validPricingRuleGen(localRng);

        // Property only applies when there is a positive grace period.
        if (rule.gracePeriodMinutes <= 0) continue;

        // Pick a duration in [0, gracePeriodMinutes].
        final duration = localRng.nextInt(rule.gracePeriodMinutes + 1);

        final Money fee = calculator.calculate(rule, duration);

        expect(
          fee.cents,
          equals(0),
          reason: 'Iteration $checked: fee.cents=${fee.cents} != 0 '
              '(grace=${rule.gracePeriodMinutes}, duration=$duration)',
        );

        checked++;
      }
    });
  });

  // -------------------------------------------------------------------------
  // Property 15 — Daily cap is never exceeded for sessions ≤ 24 hours
  // Validates: Requirements 5.4
  // -------------------------------------------------------------------------
  group('Property 15 — Daily cap is never exceeded for sessions ≤ 24 hours',
      () {
    test(
        '**Validates: Requirements 5.4** '
        'Fee never exceeds dailyMaxCap for durations in [0, 1440]', () {
      var checked = 0;
      final localRng = Random(42);
      while (checked < iterations) {
        final rule = validPricingRuleGen(localRng);

        // Property only applies when a daily cap is set.
        if (rule.dailyMaxCap == null) continue;

        // Duration must be within 24 hours for the cap to apply.
        final duration = localRng.nextInt(1441); // [0, 1440]

        final Money fee = calculator.calculate(rule, duration);
        final int capCents = (rule.dailyMaxCap! * 100).round();

        expect(
          fee.cents,
          lessThanOrEqualTo(capCents),
          reason: 'Iteration $checked: fee.cents=${fee.cents} > '
              'capCents=$capCents '
              '(cap=${rule.dailyMaxCap}, duration=$duration)',
        );

        checked++;
      }
    });
  });
}
