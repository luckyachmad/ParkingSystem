// Feature: parking-system, Property 24
//
// Property 24: Transaction record is identical after round-trip write and read
// Validates: Requirements 8.4, 10.1
//
// fast_check is a JavaScript library and does not exist as a Dart pub package.
// Per task instructions, the property test is implemented manually using
// dart:math Random with 100+ iterations.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:parking_system/models/parking_transaction.dart';

// ---------------------------------------------------------------------------
// Arbitrary ParkingTransaction generator
// ---------------------------------------------------------------------------

/// Printable ASCII characters safe for use as plate numbers / rule names.
const _alphaNum =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

String _randomString(Random rng, int minLen, int maxLen) {
  final len = minLen + rng.nextInt(maxLen - minLen + 1);
  return List.generate(len, (_) => _alphaNum[rng.nextInt(_alphaNum.length)])
      .join();
}

/// Generates a random UTC DateTime within a reasonable range
/// (year 2000 – 2099) stored as epoch milliseconds so that the
/// round-trip through millisecondsSinceEpoch is lossless.
DateTime _randomUtcDateTime(Random rng) {
  // 2000-01-01 00:00:00 UTC in ms
  const epochBase = 946684800000;
  // ~100 years in ms
  const rangeMs = 3153600000000;
  final ms = epochBase + (rng.nextDouble() * rangeMs).toInt();
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// Generates a fee value that survives the cents round-trip:
///   fee → (fee * 100).round() → / 100.0
/// To guarantee round-trip equality we generate the fee as an integer
/// number of cents (0–999999) and convert to double.
double _randomFee(Random rng) {
  final cents = rng.nextInt(1000000); // 0 – $9999.99
  return cents / 100.0;
}

ParkingTransaction _randomTransaction(Random rng, {int? id}) {
  final entryTime = _randomUtcDateTime(rng);
  // exitTime must be after entryTime; add 1–10080 minutes (up to 1 week)
  final exitTime = entryTime.add(Duration(minutes: 1 + rng.nextInt(10080)));

  return ParkingTransaction(
    id: id,
    ticketId: rng.nextInt(100000) + 1,
    plateNumber: _randomString(rng, 1, 10),
    entryTime: entryTime,
    exitTime: exitTime,
    durationMinutes: 1 + rng.nextInt(10080),
    fee: _randomFee(rng),
    paymentStatus: PaymentStatus.values[rng.nextInt(PaymentStatus.values.length)],
    pricingRuleName: _randomString(rng, 1, 50),
  );
}

// ---------------------------------------------------------------------------
// Field-by-field equality helper (ParkingTransaction has no == override)
// ---------------------------------------------------------------------------

void _assertTransactionsEqual(
  ParkingTransaction original,
  ParkingTransaction roundTripped, {
  required String context,
}) {
  expect(
    roundTripped.id,
    equals(original.id),
    reason: '$context: id mismatch',
  );
  expect(
    roundTripped.ticketId,
    equals(original.ticketId),
    reason: '$context: ticketId mismatch',
  );
  expect(
    roundTripped.plateNumber,
    equals(original.plateNumber),
    reason: '$context: plateNumber mismatch',
  );
  expect(
    roundTripped.entryTime.millisecondsSinceEpoch,
    equals(original.entryTime.millisecondsSinceEpoch),
    reason: '$context: entryTime mismatch',
  );
  expect(
    roundTripped.exitTime.millisecondsSinceEpoch,
    equals(original.exitTime.millisecondsSinceEpoch),
    reason: '$context: exitTime mismatch',
  );
  expect(
    roundTripped.durationMinutes,
    equals(original.durationMinutes),
    reason: '$context: durationMinutes mismatch',
  );
  // fee goes through cents conversion: compare with epsilon < 0.005
  expect(
    (roundTripped.fee - original.fee).abs(),
    lessThan(0.005),
    reason: '$context: fee mismatch (original=${original.fee}, '
        'roundTripped=${roundTripped.fee})',
  );
  expect(
    roundTripped.paymentStatus,
    equals(original.paymentStatus),
    reason: '$context: paymentStatus mismatch',
  );
  expect(
    roundTripped.pricingRuleName,
    equals(original.pricingRuleName),
    reason: '$context: pricingRuleName mismatch',
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Property 24 — ParkingTransaction round-trip serialization', () {
    // -----------------------------------------------------------------------
    // Property test: 100 random transactions
    // -----------------------------------------------------------------------
    test(
      'fromMap(toMap(tx)) is field-for-field identical to original '
      '(100 random iterations)',
      () {
        // Fixed seed for reproducibility; change seed to explore new cases.
        final rng = Random(42);
        const iterations = 100;

        for (var i = 0; i < iterations; i++) {
          final original = _randomTransaction(rng);
          final map = original.toMap();
          final roundTripped = ParkingTransaction.fromMap(map);

          _assertTransactionsEqual(
            original,
            roundTripped,
            context: 'iteration $i',
          );
        }
      },
    );

    // -----------------------------------------------------------------------
    // Property test: id field is preserved when present
    // -----------------------------------------------------------------------
    test(
      'id field is preserved through round-trip when non-null '
      '(100 random iterations)',
      () {
        final rng = Random(99);
        const iterations = 100;

        for (var i = 0; i < iterations; i++) {
          final id = rng.nextInt(1000000) + 1;
          final original = _randomTransaction(rng, id: id);
          final roundTripped = ParkingTransaction.fromMap(original.toMap());

          expect(
            roundTripped.id,
            equals(id),
            reason: 'iteration $i: id should survive round-trip',
          );
        }
      },
    );

    // -----------------------------------------------------------------------
    // Property test: null id is preserved
    // -----------------------------------------------------------------------
    test(
      'null id is preserved through round-trip '
      '(100 random iterations)',
      () {
        final rng = Random(7);
        const iterations = 100;

        for (var i = 0; i < iterations; i++) {
          // id is null (not included in toMap output)
          final original = _randomTransaction(rng, id: null);
          final roundTripped = ParkingTransaction.fromMap(original.toMap());

          expect(
            roundTripped.id,
            isNull,
            reason: 'iteration $i: null id should survive round-trip',
          );
        }
      },
    );

    // -----------------------------------------------------------------------
    // Property test: all PaymentStatus enum values survive round-trip
    // -----------------------------------------------------------------------
    test('all PaymentStatus values survive round-trip', () {
      final rng = Random(13);

      for (final status in PaymentStatus.values) {
        final original = ParkingTransaction(
          ticketId: 1,
          plateNumber: 'ABC123',
          entryTime: DateTime.utc(2024, 1, 1, 8, 0),
          exitTime: DateTime.utc(2024, 1, 1, 10, 0),
          durationMinutes: 120,
          fee: 5.00,
          paymentStatus: status,
          pricingRuleName: 'Standard',
        );

        final roundTripped = ParkingTransaction.fromMap(original.toMap());

        expect(
          roundTripped.paymentStatus,
          equals(status),
          reason: 'PaymentStatus.$status should survive round-trip',
        );
      }
    });

    // -----------------------------------------------------------------------
    // Property test: fee cents conversion is exact for integer-cent values
    // -----------------------------------------------------------------------
    test(
      'fee stored as integer cents is recovered exactly '
      '(boundary values: 0, 0.01, 0.10, 1.00, 99.99, 9999.99)',
      () {
        const feesToTest = [0.0, 0.01, 0.10, 1.00, 99.99, 9999.99];

        for (final fee in feesToTest) {
          final original = ParkingTransaction(
            ticketId: 1,
            plateNumber: 'TEST',
            entryTime: DateTime.utc(2024, 6, 1),
            exitTime: DateTime.utc(2024, 6, 1, 1),
            durationMinutes: 60,
            fee: fee,
            paymentStatus: PaymentStatus.paid,
            pricingRuleName: 'Rule',
          );

          final roundTripped = ParkingTransaction.fromMap(original.toMap());

          expect(
            (roundTripped.fee - fee).abs(),
            lessThan(0.005),
            reason: 'fee $fee should survive cents round-trip',
          );
        }
      },
    );

    // -----------------------------------------------------------------------
    // Property test: DateTime UTC flag is preserved
    // -----------------------------------------------------------------------
    test(
      'entryTime and exitTime are UTC after round-trip '
      '(100 random iterations)',
      () {
        final rng = Random(55);
        const iterations = 100;

        for (var i = 0; i < iterations; i++) {
          final original = _randomTransaction(rng);
          final roundTripped = ParkingTransaction.fromMap(original.toMap());

          expect(
            roundTripped.entryTime.isUtc,
            isTrue,
            reason: 'iteration $i: entryTime must be UTC',
          );
          expect(
            roundTripped.exitTime.isUtc,
            isTrue,
            reason: 'iteration $i: exitTime must be UTC',
          );
        }
      },
    );
  });
}
