// Feature: parking-system, Property 23, Property 24
//
// Property 23: Transaction query returns only matching records, ordered correctly
//   Validates: Requirements 8.1, 8.2, 8.3
//
// Property 24: Transaction record is identical after round-trip write and read
//   Validates: Requirements 8.4, 10.1
//
// Uses in-memory SQLite via sqflite_common_ffi. No device or emulator needed.
// Property tests are implemented manually using dart:math Random with 100+
// iterations (fast_check is a JavaScript library with no Dart pub package).

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:parking_system/core/result.dart';
import 'package:parking_system/database/database_helper.dart';
import 'package:parking_system/models/parking_transaction.dart';
import 'package:parking_system/models/transaction_filter.dart';
import 'package:parking_system/repositories/transaction_repository.dart';

// ---------------------------------------------------------------------------
// In-memory DatabaseHelper for tests
// ---------------------------------------------------------------------------

DatabaseHelper _testHelper(Database db) => DatabaseHelper.forTesting(db);

// ---------------------------------------------------------------------------
// DDL helper — creates the full schema needed for TransactionRepository
// ---------------------------------------------------------------------------

Future<Database> _openInMemoryDb() async {
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
        // pricing_rules table (needed for FK reference in tickets)
        await db.execute('''
          CREATE TABLE pricing_rules (
            id                   INTEGER PRIMARY KEY AUTOINCREMENT,
            name                 TEXT    NOT NULL UNIQUE,
            rate_type            TEXT    NOT NULL,
            rate_amount_cents    INTEGER NOT NULL,
            grace_period_minutes INTEGER NOT NULL DEFAULT 0,
            daily_max_cap_cents  INTEGER,
            is_active            INTEGER NOT NULL DEFAULT 1,
            is_default           INTEGER NOT NULL DEFAULT 0
          )
        ''');

        // tickets table (needed for FK reference in transactions)
        await db.execute('''
          CREATE TABLE tickets (
            id                   INTEGER PRIMARY KEY AUTOINCREMENT,
            plate_number         TEXT    NOT NULL,
            entry_time           INTEGER NOT NULL,
            exit_time            INTEGER,
            pricing_rule_id      INTEGER NOT NULL REFERENCES pricing_rules(id),
            pricing_rule_name    TEXT    NOT NULL,
            rate_type            TEXT    NOT NULL,
            rate_amount_cents    INTEGER NOT NULL,
            grace_period_minutes INTEGER NOT NULL DEFAULT 0,
            daily_max_cap_cents  INTEGER,
            created_by           TEXT    NOT NULL,
            closed_by            TEXT
          )
        ''');

        await db.execute(
          'CREATE INDEX idx_tickets_plate_open ON tickets(plate_number, exit_time)',
        );

        // transactions table (immutable — INSERT only)
        await db.execute('''
          CREATE TABLE transactions (
            id                INTEGER PRIMARY KEY AUTOINCREMENT,
            ticket_id         INTEGER NOT NULL REFERENCES tickets(id),
            plate_number      TEXT    NOT NULL,
            entry_time        INTEGER NOT NULL,
            exit_time         INTEGER NOT NULL,
            duration_minutes  INTEGER NOT NULL,
            fee_cents         INTEGER NOT NULL,
            payment_status    TEXT    NOT NULL CHECK(payment_status IN ('paid', 'unpaid', 'cancelled')),
            pricing_rule_name TEXT    NOT NULL
          )
        ''');

        await db.execute(
          'CREATE INDEX idx_transactions_exit_time ON transactions(exit_time DESC)',
        );
        await db.execute(
          'CREATE INDEX idx_transactions_plate ON transactions(plate_number)',
        );
      },
    ),
  );
}

// ---------------------------------------------------------------------------
// Helpers: insert a stub ticket row so FK constraint on transactions is met
// ---------------------------------------------------------------------------

/// Inserts a stub pricing_rule row and returns its id.
Future<int> _insertStubPricingRule(Database db, {String? name}) async {
  return db.insert('pricing_rules', {
    'name': name ?? 'StubRule_${DateTime.now().microsecondsSinceEpoch}',
    'rate_type': 'hourly',
    'rate_amount_cents': 500,
    'grace_period_minutes': 0,
    'is_active': 1,
    'is_default': 0,
  });
}

/// Inserts a stub ticket row and returns its id.
Future<int> _insertStubTicket(
  Database db, {
  required int pricingRuleId,
  String? plate,
}) async {
  return db.insert('tickets', {
    'plate_number': plate ?? 'STUB',
    'entry_time': DateTime.utc(2024, 1, 1).millisecondsSinceEpoch,
    'pricing_rule_id': pricingRuleId,
    'pricing_rule_name': 'StubRule',
    'rate_type': 'hourly',
    'rate_amount_cents': 500,
    'grace_period_minutes': 0,
    'created_by': 'test',
  });
}

// ---------------------------------------------------------------------------
// Random data generators
// ---------------------------------------------------------------------------

const _alphaNum =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

String _randomString(Random rng, int minLen, int maxLen) {
  final len = minLen + rng.nextInt(maxLen - minLen + 1);
  return List.generate(len, (_) => _alphaNum[rng.nextInt(_alphaNum.length)])
      .join();
}

/// Generates a random UTC DateTime in year 2020–2029 stored as epoch ms
/// so that the round-trip through millisecondsSinceEpoch is lossless.
DateTime _randomUtcDateTime(Random rng) {
  const epochBase = 1577836800000; // 2020-01-01 00:00:00 UTC
  const rangeMs = 315360000000; // ~10 years in ms
  final ms = epochBase + (rng.nextDouble() * rangeMs).toInt();
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// Generates a fee that survives the cents round-trip.
double _randomFee(Random rng) {
  final cents = rng.nextInt(1000000); // 0 – $9999.99
  return cents / 100.0;
}

ParkingTransaction _randomTransaction(
  Random rng, {
  required int ticketId,
  String? plateNumber,
  DateTime? exitTime,
  PaymentStatus? paymentStatus,
}) {
  final entryTime = _randomUtcDateTime(rng);
  final exit = exitTime ??
      entryTime.add(Duration(minutes: 1 + rng.nextInt(10080)));

  return ParkingTransaction(
    ticketId: ticketId,
    plateNumber: plateNumber ?? _randomString(rng, 1, 10),
    entryTime: entryTime,
    exitTime: exit,
    durationMinutes: 1 + rng.nextInt(10080),
    fee: _randomFee(rng),
    paymentStatus:
        paymentStatus ?? PaymentStatus.values[rng.nextInt(PaymentStatus.values.length)],
    pricingRuleName: _randomString(rng, 1, 50),
  );
}

// ---------------------------------------------------------------------------
// Field-by-field equality helper
// ---------------------------------------------------------------------------

void _assertTransactionsEqual(
  ParkingTransaction original,
  ParkingTransaction retrieved, {
  required String context,
}) {
  expect(
    retrieved.ticketId,
    equals(original.ticketId),
    reason: '$context: ticketId mismatch',
  );
  expect(
    retrieved.plateNumber,
    equals(original.plateNumber),
    reason: '$context: plateNumber mismatch',
  );
  expect(
    retrieved.entryTime.millisecondsSinceEpoch,
    equals(original.entryTime.millisecondsSinceEpoch),
    reason: '$context: entryTime mismatch',
  );
  expect(
    retrieved.exitTime.millisecondsSinceEpoch,
    equals(original.exitTime.millisecondsSinceEpoch),
    reason: '$context: exitTime mismatch',
  );
  expect(
    retrieved.durationMinutes,
    equals(original.durationMinutes),
    reason: '$context: durationMinutes mismatch',
  );
  expect(
    (retrieved.fee - original.fee).abs(),
    lessThan(0.005),
    reason: '$context: fee mismatch '
        '(original=${original.fee}, retrieved=${retrieved.fee})',
  );
  expect(
    retrieved.paymentStatus,
    equals(original.paymentStatus),
    reason: '$context: paymentStatus mismatch',
  );
  expect(
    retrieved.pricingRuleName,
    equals(original.pricingRuleName),
    reason: '$context: pricingRuleName mismatch',
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // =========================================================================
  // Property 24 — Transaction record is identical after round-trip write/read
  // =========================================================================

  group(
    'Property 24 — Transaction record is identical after round-trip '
    'write and read',
    () {
      /// **Validates: Requirements 8.4, 10.1**
      ///
      /// Inserts a ParkingTransaction via TransactionRepository.insert() and
      /// retrieves it via TransactionRepository.findById(). All fields must
      /// be identical after the round-trip through SQLite.
      test(
        'insert then findById returns identical record (100 random iterations)',
        () async {
          final rng = Random(24);
          const iterations = 100;

          for (var i = 0; i < iterations; i++) {
            final db = await _openInMemoryDb();
            final repo = TransactionRepositoryImpl(_testHelper(db));

            // Insert FK prerequisites.
            final ruleId = await _insertStubPricingRule(
              db,
              name: 'Rule_P24_$i',
            );
            final ticketId = await _insertStubTicket(
              db,
              pricingRuleId: ruleId,
              plate: 'P24_$i',
            );

            final original = _randomTransaction(rng, ticketId: ticketId);

            final insertResult = await repo.insert(original);
            expect(
              insertResult,
              isA<Success<int>>(),
              reason: 'iter $i: insert should succeed',
            );
            final newId = (insertResult as Success<int>).value;

            final retrieved = await repo.findById(newId);
            expect(
              retrieved,
              isNotNull,
              reason: 'iter $i: findById($newId) must return a record',
            );

            _assertTransactionsEqual(
              original,
              retrieved!,
              context: 'iter $i',
            );

            await db.close();
          }
        },
      );

      test(
        'assigned id is returned by insert and matches findById result',
        () async {
          final rng = Random(241);
          const iterations = 20;

          for (var i = 0; i < iterations; i++) {
            final db = await _openInMemoryDb();
            final repo = TransactionRepositoryImpl(_testHelper(db));

            final ruleId = await _insertStubPricingRule(
              db,
              name: 'Rule_P24id_$i',
            );
            final ticketId = await _insertStubTicket(
              db,
              pricingRuleId: ruleId,
              plate: 'P24id_$i',
            );

            final tx = _randomTransaction(rng, ticketId: ticketId);
            final result = await repo.insert(tx);
            final id = (result as Success<int>).value;

            final retrieved = await repo.findById(id);
            expect(retrieved, isNotNull, reason: 'iter $i: record must exist');
            expect(
              retrieved!.id,
              equals(id),
              reason: 'iter $i: retrieved id must match inserted id',
            );

            await db.close();
          }
        },
      );

      test(
        'all PaymentStatus values survive DB round-trip',
        () async {
          final db = await _openInMemoryDb();
          final repo = TransactionRepositoryImpl(_testHelper(db));

          final ruleId = await _insertStubPricingRule(db, name: 'Rule_P24_status');

          for (final status in PaymentStatus.values) {
            final ticketId = await _insertStubTicket(
              db,
              pricingRuleId: ruleId,
              plate: 'STATUS_${status.name}',
            );

            final tx = ParkingTransaction(
              ticketId: ticketId,
              plateNumber: 'STATUS_${status.name}',
              entryTime: DateTime.utc(2024, 1, 1, 8, 0),
              exitTime: DateTime.utc(2024, 1, 1, 10, 0),
              durationMinutes: 120,
              fee: 5.00,
              paymentStatus: status,
              pricingRuleName: 'Standard',
            );

            final result = await repo.insert(tx);
            final id = (result as Success<int>).value;
            final retrieved = await repo.findById(id);

            expect(retrieved, isNotNull);
            expect(
              retrieved!.paymentStatus,
              equals(status),
              reason: 'PaymentStatus.$status must survive DB round-trip',
            );
          }

          await db.close();
        },
      );

      test(
        'entryTime and exitTime are UTC after DB round-trip',
        () async {
          final rng = Random(242);
          const iterations = 20;

          for (var i = 0; i < iterations; i++) {
            final db = await _openInMemoryDb();
            final repo = TransactionRepositoryImpl(_testHelper(db));

            final ruleId = await _insertStubPricingRule(
              db,
              name: 'Rule_P24utc_$i',
            );
            final ticketId = await _insertStubTicket(
              db,
              pricingRuleId: ruleId,
              plate: 'P24utc_$i',
            );

            final tx = _randomTransaction(rng, ticketId: ticketId);
            final result = await repo.insert(tx);
            final id = (result as Success<int>).value;
            final retrieved = await repo.findById(id);

            expect(retrieved, isNotNull);
            expect(
              retrieved!.entryTime.isUtc,
              isTrue,
              reason: 'iter $i: entryTime must be UTC after DB round-trip',
            );
            expect(
              retrieved.exitTime.isUtc,
              isTrue,
              reason: 'iter $i: exitTime must be UTC after DB round-trip',
            );

            await db.close();
          }
        },
      );

      test(
        'findById returns null for non-existent id',
        () async {
          final db = await _openInMemoryDb();
          final repo = TransactionRepositoryImpl(_testHelper(db));

          final result = await repo.findById(999999);
          expect(result, isNull);

          await db.close();
        },
      );
    },
  );

  // =========================================================================
  // Property 23 — Transaction query returns only matching records, ordered
  // =========================================================================

  group(
    'Property 23 — Transaction query returns only matching records, '
    'ordered correctly',
    () {
      /// **Validates: Requirements 8.1, 8.2, 8.3**

      // -----------------------------------------------------------------------
      // Helper: insert N transactions into a fresh DB and return the repo + db
      // -----------------------------------------------------------------------

      // -----------------------------------------------------------------------
      // Sub-test: date range filter
      // -----------------------------------------------------------------------
      test(
        'date range filter returns only transactions within [fromDate, toDate] '
        '(100 random iterations)',
        () async {
          final rng = Random(2301);
          const iterations = 100;

          for (var iter = 0; iter < iterations; iter++) {
            final db = await _openInMemoryDb();
            final repo = TransactionRepositoryImpl(_testHelper(db));

            final ruleId = await _insertStubPricingRule(
              db,
              name: 'Rule_P23dr_$iter',
            );

            // Anchor: a base time; transactions spread over 10 days.
            final base = DateTime.utc(2024, 6, 1);
            const totalDays = 10;

            // Insert 5–10 transactions with exit times spread across 10 days.
            final txCount = 5 + rng.nextInt(6);
            final insertedExitTimes = <DateTime>[];

            for (var t = 0; t < txCount; t++) {
              final ticketId = await _insertStubTicket(
                db,
                pricingRuleId: ruleId,
                plate: 'P23dr_${iter}_$t',
              );
              final dayOffset = rng.nextInt(totalDays);
              final exitTime = base.add(Duration(days: dayOffset, hours: rng.nextInt(24)));
              insertedExitTimes.add(exitTime);

              final tx = ParkingTransaction(
                ticketId: ticketId,
                plateNumber: 'P23dr_${iter}_$t',
                entryTime: exitTime.subtract(const Duration(hours: 1)),
                exitTime: exitTime,
                durationMinutes: 60,
                fee: 5.00,
                paymentStatus: PaymentStatus.paid,
                pricingRuleName: 'Rule',
              );
              await repo.insert(tx);
            }

            // Pick a random sub-range within the 10 days.
            final fromDay = rng.nextInt(totalDays - 1);
            final toDay = fromDay + 1 + rng.nextInt(totalDays - fromDay - 1);
            final fromDate = base.add(Duration(days: fromDay));
            final toDate = base.add(Duration(days: toDay, hours: 23, minutes: 59, seconds: 59));

            final filter = TransactionFilter(fromDate: fromDate, toDate: toDate);
            final queryResult = await repo.query(filter);
            expect(
              queryResult,
              isA<Success<List<ParkingTransaction>>>(),
              reason: 'iter $iter: query should succeed',
            );
            final results = (queryResult as Success<List<ParkingTransaction>>).value;

            // Every returned record must have exitTime within [fromDate, toDate].
            for (final tx in results) {
              expect(
                tx.exitTime.millisecondsSinceEpoch,
                greaterThanOrEqualTo(fromDate.millisecondsSinceEpoch),
                reason: 'iter $iter: exitTime ${tx.exitTime} must be >= fromDate $fromDate',
              );
              expect(
                tx.exitTime.millisecondsSinceEpoch,
                lessThanOrEqualTo(toDate.millisecondsSinceEpoch),
                reason: 'iter $iter: exitTime ${tx.exitTime} must be <= toDate $toDate',
              );
            }

            // Every inserted transaction within range must appear in results.
            for (var t = 0; t < txCount; t++) {
              final exitMs = insertedExitTimes[t].millisecondsSinceEpoch;
              final inRange = exitMs >= fromDate.millisecondsSinceEpoch &&
                  exitMs <= toDate.millisecondsSinceEpoch;
              if (inRange) {
                final plate = 'P23dr_${iter}_$t';
                expect(
                  results.any((r) => r.plateNumber == plate),
                  isTrue,
                  reason: 'iter $iter: transaction for plate $plate '
                      '(exitTime=${insertedExitTimes[t]}) must appear in results '
                      'for range [$fromDate, $toDate]',
                );
              }
            }

            await db.close();
          }
        },
      );

      // -----------------------------------------------------------------------
      // Sub-test: plate substring filter
      // -----------------------------------------------------------------------
      test(
        'plate substring filter returns only transactions whose plate contains '
        'the substring (100 random iterations)',
        () async {
          const iterations = 100;

          for (var iter = 0; iter < iterations; iter++) {
            final db = await _openInMemoryDb();
            final repo = TransactionRepositoryImpl(_testHelper(db));

            final ruleId = await _insertStubPricingRule(
              db,
              name: 'Rule_P23ps_$iter',
            );

            // Insert transactions with two distinct plate prefixes.
            const matchPrefix = 'MATCH';
            const noMatchPrefix = 'OTHER';
            const matchCount = 3;
            const noMatchCount = 4;

            for (var t = 0; t < matchCount; t++) {
              final plate = '$matchPrefix${iter}_$t';
              final ticketId = await _insertStubTicket(
                db,
                pricingRuleId: ruleId,
                plate: plate,
              );
              final exitTime = DateTime.utc(2024, 1, 1, 10 + t);
              final tx = ParkingTransaction(
                ticketId: ticketId,
                plateNumber: plate,
                entryTime: exitTime.subtract(const Duration(hours: 1)),
                exitTime: exitTime,
                durationMinutes: 60,
                fee: 3.00,
                paymentStatus: PaymentStatus.paid,
                pricingRuleName: 'Rule',
              );
              await repo.insert(tx);
            }

            for (var t = 0; t < noMatchCount; t++) {
              final plate = '$noMatchPrefix${iter}_$t';
              final ticketId = await _insertStubTicket(
                db,
                pricingRuleId: ruleId,
                plate: plate,
              );
              final exitTime = DateTime.utc(2024, 1, 2, 10 + t);
              final tx = ParkingTransaction(
                ticketId: ticketId,
                plateNumber: plate,
                entryTime: exitTime.subtract(const Duration(hours: 1)),
                exitTime: exitTime,
                durationMinutes: 60,
                fee: 3.00,
                paymentStatus: PaymentStatus.paid,
                pricingRuleName: 'Rule',
              );
              await repo.insert(tx);
            }

            // Query with the match prefix as substring.
            final filter = TransactionFilter(plateSubstring: matchPrefix);
            final queryResult = await repo.query(filter);
            expect(queryResult, isA<Success<List<ParkingTransaction>>>());
            final results = (queryResult as Success<List<ParkingTransaction>>).value;

            // All results must contain the substring.
            for (final tx in results) {
              expect(
                tx.plateNumber.contains(matchPrefix),
                isTrue,
                reason: 'iter $iter: plate "${tx.plateNumber}" must contain "$matchPrefix"',
              );
            }

            // All matching plates must appear.
            for (var t = 0; t < matchCount; t++) {
              final plate = '$matchPrefix${iter}_$t';
              expect(
                results.any((r) => r.plateNumber == plate),
                isTrue,
                reason: 'iter $iter: plate $plate must appear in results',
              );
            }

            // No non-matching plates must appear.
            for (var t = 0; t < noMatchCount; t++) {
              final plate = '$noMatchPrefix${iter}_$t';
              expect(
                results.any((r) => r.plateNumber == plate),
                isFalse,
                reason: 'iter $iter: plate $plate must NOT appear in results',
              );
            }

            await db.close();
          }
        },
      );

      // -----------------------------------------------------------------------
      // Sub-test: payment status filter
      // -----------------------------------------------------------------------
      test(
        'payment status filter returns only transactions with matching status '
        '(100 random iterations)',
        () async {
          const iterations = 100;

          for (var iter = 0; iter < iterations; iter++) {
            final db = await _openInMemoryDb();
            final repo = TransactionRepositoryImpl(_testHelper(db));

            final ruleId = await _insertStubPricingRule(
              db,
              name: 'Rule_P23st_$iter',
            );

            // Insert 2 transactions per status (6 total).
            var txIndex = 0;
            for (final status in PaymentStatus.values) {
              for (var t = 0; t < 2; t++) {
                final plate = 'P23st_${iter}_${status.name}_$t';
                final ticketId = await _insertStubTicket(
                  db,
                  pricingRuleId: ruleId,
                  plate: plate,
                );
                final exitTime = DateTime.utc(2024, 3, 1).add(
                  Duration(hours: txIndex),
                );
                txIndex++;
                final tx = ParkingTransaction(
                  ticketId: ticketId,
                  plateNumber: plate,
                  entryTime: exitTime.subtract(const Duration(hours: 1)),
                  exitTime: exitTime,
                  durationMinutes: 60,
                  fee: 4.00,
                  paymentStatus: status,
                  pricingRuleName: 'Rule',
                );
                await repo.insert(tx);
              }
            }

            // Query for each status and verify.
            for (final targetStatus in PaymentStatus.values) {
              final filter = TransactionFilter(paymentStatus: targetStatus);
              final queryResult = await repo.query(filter);
              expect(queryResult, isA<Success<List<ParkingTransaction>>>());
              final results =
                  (queryResult as Success<List<ParkingTransaction>>).value;

              // All results must have the target status.
              for (final tx in results) {
                expect(
                  tx.paymentStatus,
                  equals(targetStatus),
                  reason: 'iter $iter: all results must have status $targetStatus, '
                      'got ${tx.paymentStatus}',
                );
              }

              // Exactly 2 results expected for each status.
              expect(
                results.length,
                equals(2),
                reason: 'iter $iter: expected 2 results for status $targetStatus, '
                    'got ${results.length}',
              );
            }

            await db.close();
          }
        },
      );

      // -----------------------------------------------------------------------
      // Sub-test: ordering — exit_time DESC, nulls last
      // -----------------------------------------------------------------------
      test(
        'results are ordered by exit_time DESC with no null exit_times '
        '(100 random iterations)',
        () async {
          final rng = Random(2304);
          const iterations = 100;

          for (var iter = 0; iter < iterations; iter++) {
            final db = await _openInMemoryDb();
            final repo = TransactionRepositoryImpl(_testHelper(db));

            final ruleId = await _insertStubPricingRule(
              db,
              name: 'Rule_P23ord_$iter',
            );

            // Insert 5–10 transactions with random exit times.
            final txCount = 5 + rng.nextInt(6);
            for (var t = 0; t < txCount; t++) {
              final plate = 'P23ord_${iter}_$t';
              final ticketId = await _insertStubTicket(
                db,
                pricingRuleId: ruleId,
                plate: plate,
              );
              final exitTime = _randomUtcDateTime(rng);
              final tx = ParkingTransaction(
                ticketId: ticketId,
                plateNumber: plate,
                entryTime: exitTime.subtract(const Duration(hours: 1)),
                exitTime: exitTime,
                durationMinutes: 60,
                fee: _randomFee(rng),
                paymentStatus: PaymentStatus.values[rng.nextInt(3)],
                pricingRuleName: 'Rule',
              );
              await repo.insert(tx);
            }

            final queryResult = await repo.query(const TransactionFilter());
            expect(queryResult, isA<Success<List<ParkingTransaction>>>());
            final results =
                (queryResult as Success<List<ParkingTransaction>>).value;

            expect(
              results.length,
              equals(txCount),
              reason: 'iter $iter: all $txCount transactions must be returned',
            );

            // Verify descending order by exitTime.
            for (var i = 0; i < results.length - 1; i++) {
              expect(
                results[i].exitTime.millisecondsSinceEpoch,
                greaterThanOrEqualTo(
                  results[i + 1].exitTime.millisecondsSinceEpoch,
                ),
                reason: 'iter $iter: results[$i].exitTime '
                    '(${results[i].exitTime}) must be >= '
                    'results[${i + 1}].exitTime (${results[i + 1].exitTime})',
              );
            }

            await db.close();
          }
        },
      );

      // -----------------------------------------------------------------------
      // Sub-test: combined filters
      // -----------------------------------------------------------------------
      test(
        'combined date range + plate substring + payment status filters '
        'return only records matching all criteria (100 random iterations)',
        () async {
          final rng = Random(2305);
          const iterations = 100;

          for (var iter = 0; iter < iterations; iter++) {
            final db = await _openInMemoryDb();
            final repo = TransactionRepositoryImpl(_testHelper(db));

            final ruleId = await _insertStubPricingRule(
              db,
              name: 'Rule_P23comb_$iter',
            );

            final base = DateTime.utc(2024, 9, 1);
            const totalDays = 6;

            // Insert 12 transactions with varied attributes.
            final plates = ['ALPHA', 'BETA', 'GAMMA'];
            final statuses = PaymentStatus.values;
            var txIndex = 0;

            for (final plate in plates) {
              for (final status in statuses) {
                for (var d = 0; d < 2; d++) {
                  final fullPlate = '${plate}_${iter}_$txIndex';
                  final ticketId = await _insertStubTicket(
                    db,
                    pricingRuleId: ruleId,
                    plate: fullPlate,
                  );
                  final dayOffset = rng.nextInt(totalDays);
                  final exitTime = base.add(Duration(days: dayOffset, hours: rng.nextInt(24)));
                  final tx = ParkingTransaction(
                    ticketId: ticketId,
                    plateNumber: fullPlate,
                    entryTime: exitTime.subtract(const Duration(hours: 1)),
                    exitTime: exitTime,
                    durationMinutes: 60,
                    fee: 2.00,
                    paymentStatus: status,
                    pricingRuleName: 'Rule',
                  );
                  await repo.insert(tx);
                  txIndex++;
                }
              }
            }

            // Apply combined filter: date range + plate substring + status.
            final fromDate = base.add(const Duration(days: 1));
            final toDate = base.add(const Duration(days: 4, hours: 23, minutes: 59));
            const plateSubstring = 'ALPHA';
            const targetStatus = PaymentStatus.paid;

            final filter = TransactionFilter(
              fromDate: fromDate,
              toDate: toDate,
              plateSubstring: plateSubstring,
              paymentStatus: targetStatus,
            );

            final queryResult = await repo.query(filter);
            expect(queryResult, isA<Success<List<ParkingTransaction>>>());
            final results =
                (queryResult as Success<List<ParkingTransaction>>).value;

            // Every result must satisfy ALL three criteria simultaneously.
            for (final tx in results) {
              expect(
                tx.exitTime.millisecondsSinceEpoch,
                greaterThanOrEqualTo(fromDate.millisecondsSinceEpoch),
                reason: 'iter $iter: exitTime must be >= fromDate',
              );
              expect(
                tx.exitTime.millisecondsSinceEpoch,
                lessThanOrEqualTo(toDate.millisecondsSinceEpoch),
                reason: 'iter $iter: exitTime must be <= toDate',
              );
              expect(
                tx.plateNumber.contains(plateSubstring),
                isTrue,
                reason: 'iter $iter: plate "${tx.plateNumber}" must contain "$plateSubstring"',
              );
              expect(
                tx.paymentStatus,
                equals(targetStatus),
                reason: 'iter $iter: paymentStatus must be $targetStatus',
              );
            }

            await db.close();
          }
        },
      );

      // -----------------------------------------------------------------------
      // Sub-test: empty filter returns all records
      // -----------------------------------------------------------------------
      test(
        'empty filter returns all inserted transactions',
        () async {
          final rng = Random(2306);
          final db = await _openInMemoryDb();
          final repo = TransactionRepositoryImpl(_testHelper(db));

          final ruleId = await _insertStubPricingRule(db, name: 'Rule_P23all');
          const txCount = 15;

          for (var t = 0; t < txCount; t++) {
            final plate = 'P23all_$t';
            final ticketId = await _insertStubTicket(
              db,
              pricingRuleId: ruleId,
              plate: plate,
            );
            final tx = _randomTransaction(rng, ticketId: ticketId, plateNumber: plate);
            await repo.insert(tx);
          }

          final queryResult = await repo.query(const TransactionFilter());
          expect(queryResult, isA<Success<List<ParkingTransaction>>>());
          final results = (queryResult as Success<List<ParkingTransaction>>).value;

          expect(
            results.length,
            equals(txCount),
            reason: 'empty filter must return all $txCount transactions',
          );

          await db.close();
        },
      );

      // -----------------------------------------------------------------------
      // Sub-test: no matching records returns empty list (not an error)
      // -----------------------------------------------------------------------
      test(
        'filter with no matching records returns empty list, not an error',
        () async {
          final db = await _openInMemoryDb();
          final repo = TransactionRepositoryImpl(_testHelper(db));

          final ruleId = await _insertStubPricingRule(db, name: 'Rule_P23empty');
          final ticketId = await _insertStubTicket(
            db,
            pricingRuleId: ruleId,
            plate: 'P23empty',
          );

          final tx = ParkingTransaction(
            ticketId: ticketId,
            plateNumber: 'P23empty',
            entryTime: DateTime.utc(2024, 1, 1, 8),
            exitTime: DateTime.utc(2024, 1, 1, 10),
            durationMinutes: 120,
            fee: 5.00,
            paymentStatus: PaymentStatus.paid,
            pricingRuleName: 'Rule',
          );
          await repo.insert(tx);

          // Filter for a plate that doesn't exist.
          final filter = TransactionFilter(plateSubstring: 'ZZZNOMATCH');
          final queryResult = await repo.query(filter);
          expect(queryResult, isA<Success<List<ParkingTransaction>>>());
          final results = (queryResult as Success<List<ParkingTransaction>>).value;

          expect(results, isEmpty, reason: 'no matching records must return empty list');

          await db.close();
        },
      );
    },
  );
}
