// Feature: parking-system, Property 10, 11, 16, 28
//
// Property 10: Duplicate open ticket is prevented
//   Validates: Requirements 3.3
//
// Property 11: Ticket creation preserves the pricing rule snapshot
//   Validates: Requirements 3.4, 6.4
//
// Property 16: Pricing rule snapshot on open ticket is immutable after rule update
//   Validates: Requirements 6.4
//
// Property 28: Exit confirmation creates a closed ticket and a matching transaction
//   Validates: Requirements 4.7
//
// Uses in-memory SQLite via sqflite_common_ffi. No device or emulator needed.
// Property tests are implemented manually using dart:math Random with 10–20+
// iterations (fast_check is a JavaScript library with no Dart pub package).

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:parking_system/core/result.dart';
import 'package:parking_system/database/database_helper.dart';
import 'package:parking_system/models/pricing_rule.dart';
import 'package:parking_system/models/ticket.dart';
import 'package:parking_system/repositories/ticket_repository.dart';

// ---------------------------------------------------------------------------
// In-memory DatabaseHelper for tests
// ---------------------------------------------------------------------------

DatabaseHelper _testHelper(Database db) => DatabaseHelper.forTesting(db);

// ---------------------------------------------------------------------------
// DDL helper — mirrors DatabaseHelper._onCreate (pricing_rules + tickets +
// transactions tables, plus the plate/open index)
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

        // tickets table
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

        // transactions table (needed for Property 28 schema completeness)
        await db.execute('''
          CREATE TABLE transactions (
            id                INTEGER PRIMARY KEY AUTOINCREMENT,
            ticket_id         INTEGER NOT NULL REFERENCES tickets(id),
            plate_number      TEXT    NOT NULL,
            entry_time        INTEGER NOT NULL,
            exit_time         INTEGER NOT NULL,
            duration_minutes  INTEGER NOT NULL,
            fee_cents         INTEGER NOT NULL,
            payment_status    TEXT    NOT NULL,
            pricing_rule_name TEXT    NOT NULL
          )
        ''');
      },
    ),
  );
}

// ---------------------------------------------------------------------------
// Random ticket generator
// ---------------------------------------------------------------------------

Ticket _randomTicket(Random rng, String plateNumber, int pricingRuleId) {
  final rateType = rng.nextBool() ? RateType.hourly : RateType.flat;
  final rateAmountCents = rng.nextInt(9999) + 1; // 1–9999 cents
  final gracePeriod = rng.nextInt(61); // 0–60 minutes
  final hasCap = rng.nextBool();
  final capCents = hasCap ? rng.nextInt(99999) + 1 : null;
  final entryTime = DateTime.utc(2024, 1, 1, 8, 0)
      .add(Duration(minutes: rng.nextInt(10000)));

  return Ticket(
    plateNumber: plateNumber,
    entryTime: entryTime,
    pricingRuleId: pricingRuleId,
    pricingRuleName: 'Rule_$pricingRuleId',
    rateType: rateType,
    rateAmount: rateAmountCents / 100.0,
    gracePeriodMinutes: gracePeriod,
    dailyMaxCap: capCents != null ? capCents / 100.0 : null,
    createdBy: 'attendant_test',
  );
}

// ---------------------------------------------------------------------------
// Helper: insert a stub pricing_rule row so FK constraint is satisfied
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Helper: assert ticket snapshot fields match expected values
// ---------------------------------------------------------------------------

void _assertSnapshotEquals({
  required Ticket ticket,
  required String expectedName,
  required RateType expectedRateType,
  required double expectedRateAmount,
  required int expectedGracePeriod,
  required double? expectedDailyCap,
  required String context,
}) {
  expect(
    ticket.pricingRuleName,
    equals(expectedName),
    reason: '$context: pricingRuleName mismatch',
  );
  expect(
    ticket.rateType,
    equals(expectedRateType),
    reason: '$context: rateType mismatch',
  );
  expect(
    (ticket.rateAmount - expectedRateAmount).abs(),
    lessThan(0.005),
    reason: '$context: rateAmount mismatch '
        '(expected=$expectedRateAmount, got=${ticket.rateAmount})',
  );
  expect(
    ticket.gracePeriodMinutes,
    equals(expectedGracePeriod),
    reason: '$context: gracePeriodMinutes mismatch',
  );
  if (expectedDailyCap == null) {
    expect(
      ticket.dailyMaxCap,
      isNull,
      reason: '$context: dailyMaxCap should be null',
    );
  } else {
    expect(
      ticket.dailyMaxCap,
      isNotNull,
      reason: '$context: dailyMaxCap should not be null',
    );
    expect(
      (ticket.dailyMaxCap! - expectedDailyCap).abs(),
      lessThan(0.005),
      reason: '$context: dailyMaxCap mismatch '
          '(expected=$expectedDailyCap, got=${ticket.dailyMaxCap})',
    );
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // -------------------------------------------------------------------------
  // Property 10 — Duplicate open ticket is prevented
  // -------------------------------------------------------------------------

  group('Property 10 — Duplicate open ticket is prevented', () {
    /// **Validates: Requirements 3.3**
    test(
      'second insert for same plate returns Failure<BusinessError> '
      'and findAllOpen() still has exactly 1 ticket for that plate '
      '(10 random plate numbers)',
      () async {
        final rng = Random(10);
        const iterations = 10;

        for (var iter = 0; iter < iterations; iter++) {
          final db = await _openInMemoryDb();
          final repo = TicketRepositoryImpl(_testHelper(db));

          // Insert a stub pricing rule to satisfy FK.
          final ruleId = await _insertStubPricingRule(
            db,
            name: 'Rule_P10_iter$iter',
          );

          // Generate a random plate number.
          final plate = 'P10${iter.toString().padLeft(3, '0')}${rng.nextInt(9000) + 1000}';

          // First insert — should succeed.
          final firstTicket = _randomTicket(rng, plate, ruleId);
          final firstResult = await repo.insert(firstTicket);
          expect(
            firstResult,
            isA<Success<int>>(),
            reason: 'iter $iter: first insert for plate $plate should succeed',
          );

          // Second insert for the same plate — should be rejected.
          final secondTicket = _randomTicket(rng, plate, ruleId);
          final secondResult = await repo.insert(secondTicket);
          expect(
            secondResult,
            isA<Failure<int>>(),
            reason: 'iter $iter: second insert for plate $plate should fail',
          );
          expect(
            (secondResult as Failure<int>).error,
            isA<BusinessError>(),
            reason: 'iter $iter: error must be BusinessError (duplicate open ticket)',
          );

          // findAllOpen() must still contain exactly 1 ticket for this plate.
          final openTickets = await repo.findAllOpen();
          final plateTickets =
              openTickets.where((t) => t.plateNumber == plate).toList();
          expect(
            plateTickets.length,
            equals(1),
            reason: 'iter $iter: findAllOpen() must contain exactly 1 ticket '
                'for plate $plate, found ${plateTickets.length}',
          );

          await db.close();
        }
      },
    );

    test(
      'duplicate is rejected even when other plates have open tickets',
      () async {
        final db = await _openInMemoryDb();
        final repo = TicketRepositoryImpl(_testHelper(db));

        final ruleId = await _insertStubPricingRule(db, name: 'Rule_P10_multi');
        final rng = Random(101);

        // Insert tickets for 3 different plates.
        for (var i = 0; i < 3; i++) {
          final t = _randomTicket(rng, 'MULTI_$i', ruleId);
          final r = await repo.insert(t);
          expect(r, isA<Success<int>>());
        }

        // Try to insert a duplicate for plate MULTI_1.
        final dup = _randomTicket(rng, 'MULTI_1', ruleId);
        final dupResult = await repo.insert(dup);
        expect(dupResult, isA<Failure<int>>());
        expect((dupResult as Failure<int>).error, isA<BusinessError>());

        // Total open count must still be 3.
        final count = await repo.countOpen();
        expect(count, equals(3));

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Property 11 — Ticket creation preserves the pricing rule snapshot
  // -------------------------------------------------------------------------

  group(
      'Property 11 — Ticket creation preserves the pricing rule snapshot', () {
    /// **Validates: Requirements 3.4, 6.4**
    test(
      'retrieved ticket has snapshot fields identical to those set at insert '
      '(20 random pricing rule configurations)',
      () async {
        final rng = Random(11);
        const iterations = 20;

        for (var iter = 0; iter < iterations; iter++) {
          final db = await _openInMemoryDb();
          final repo = TicketRepositoryImpl(_testHelper(db));

          // Insert a stub pricing rule row.
          final ruleId = await _insertStubPricingRule(
            db,
            name: 'Rule_P11_iter$iter',
          );

          // Generate random snapshot values (independent of the stub row).
          final rateType = rng.nextBool() ? RateType.hourly : RateType.flat;
          final rateAmountCents = rng.nextInt(9999) + 1;
          final gracePeriod = rng.nextInt(61);
          final hasCap = rng.nextBool();
          final capCents = hasCap ? rng.nextInt(99999) + 1 : null;
          final snapshotName = 'Snapshot_iter$iter';

          final plate = 'P11_$iter';
          final ticket = Ticket(
            plateNumber: plate,
            entryTime: DateTime.utc(2024, 6, 1, 9, 0),
            pricingRuleId: ruleId,
            pricingRuleName: snapshotName,
            rateType: rateType,
            rateAmount: rateAmountCents / 100.0,
            gracePeriodMinutes: gracePeriod,
            dailyMaxCap: capCents != null ? capCents / 100.0 : null,
            createdBy: 'attendant_test',
          );

          final insertResult = await repo.insert(ticket);
          expect(
            insertResult,
            isA<Success<int>>(),
            reason: 'iter $iter: insert should succeed',
          );

          // Retrieve via findOpenByPlate.
          final retrieved = await repo.findOpenByPlate(plate);
          expect(
            retrieved,
            isNotNull,
            reason: 'iter $iter: findOpenByPlate should return the ticket',
          );

          _assertSnapshotEquals(
            ticket: retrieved!,
            expectedName: snapshotName,
            expectedRateType: rateType,
            expectedRateAmount: rateAmountCents / 100.0,
            expectedGracePeriod: gracePeriod,
            expectedDailyCap: capCents != null ? capCents / 100.0 : null,
            context: 'iter $iter',
          );

          await db.close();
        }
      },
    );

    test(
      'snapshot fields survive a round-trip through toMap/fromMap',
      () async {
        final db = await _openInMemoryDb();
        final repo = TicketRepositoryImpl(_testHelper(db));

        final ruleId = await _insertStubPricingRule(db, name: 'Rule_P11_rt');

        final ticket = Ticket(
          plateNumber: 'RT_PLATE',
          entryTime: DateTime.utc(2024, 3, 15, 10, 30),
          pricingRuleId: ruleId,
          pricingRuleName: 'Premium Hourly',
          rateType: RateType.hourly,
          rateAmount: 25.50,
          gracePeriodMinutes: 15,
          dailyMaxCap: 200.00,
          createdBy: 'attendant_rt',
        );

        await repo.insert(ticket);
        final retrieved = await repo.findOpenByPlate('RT_PLATE');

        expect(retrieved, isNotNull);
        _assertSnapshotEquals(
          ticket: retrieved!,
          expectedName: 'Premium Hourly',
          expectedRateType: RateType.hourly,
          expectedRateAmount: 25.50,
          expectedGracePeriod: 15,
          expectedDailyCap: 200.00,
          context: 'round-trip',
        );

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Property 16 — Snapshot immutable after rule update
  // -------------------------------------------------------------------------

  group(
      'Property 16 — Pricing rule snapshot on open ticket is immutable after rule update',
      () {
    /// **Validates: Requirements 6.4**
    test(
      'original ticket snapshot is unchanged after a new ticket is inserted '
      'with different snapshot values for the same pricingRuleId '
      '(10 random iterations)',
      () async {
        final rng = Random(16);
        const iterations = 10;

        for (var iter = 0; iter < iterations; iter++) {
          final db = await _openInMemoryDb();
          final repo = TicketRepositoryImpl(_testHelper(db));

          // Insert a stub pricing rule.
          final ruleId = await _insertStubPricingRule(
            db,
            name: 'Rule_P16_iter$iter',
          );

          // --- Original ticket with snapshot A ---
          final origRateType = rng.nextBool() ? RateType.hourly : RateType.flat;
          final origRateCents = rng.nextInt(5000) + 100; // 1.00–51.00
          final origGrace = rng.nextInt(31);
          final origCapCents = rng.nextBool() ? rng.nextInt(50000) + 1000 : null;
          final origName = 'OrigSnapshot_iter$iter';
          final origPlate = 'P16_ORIG_$iter';

          final originalTicket = Ticket(
            plateNumber: origPlate,
            entryTime: DateTime.utc(2024, 7, 1, 8, 0),
            pricingRuleId: ruleId,
            pricingRuleName: origName,
            rateType: origRateType,
            rateAmount: origRateCents / 100.0,
            gracePeriodMinutes: origGrace,
            dailyMaxCap: origCapCents != null ? origCapCents / 100.0 : null,
            createdBy: 'attendant_test',
          );

          final origInsert = await repo.insert(originalTicket);
          expect(
            origInsert,
            isA<Success<int>>(),
            reason: 'iter $iter: original ticket insert should succeed',
          );

          // --- Simulate rule update: insert a second ticket for a DIFFERENT
          //     plate but with the same pricingRuleId and different snapshot
          //     values. This mimics what would happen if the rule were updated
          //     and a new ticket were created — the snapshot is baked in at
          //     insert time, so the original ticket must be unaffected. ---
          final updatedRateType =
              origRateType == RateType.hourly ? RateType.flat : RateType.hourly;
          final updatedRateCents = origRateCents + 1000; // clearly different
          final updatedGrace = (origGrace + 10) % 61;
          final updatedName = 'UpdatedSnapshot_iter$iter';
          final updatedPlate = 'P16_UPD_$iter';

          final updatedTicket = Ticket(
            plateNumber: updatedPlate,
            entryTime: DateTime.utc(2024, 7, 1, 9, 0),
            pricingRuleId: ruleId,
            pricingRuleName: updatedName,
            rateType: updatedRateType,
            rateAmount: updatedRateCents / 100.0,
            gracePeriodMinutes: updatedGrace,
            dailyMaxCap: null, // deliberately different
            createdBy: 'attendant_test',
          );

          final updInsert = await repo.insert(updatedTicket);
          expect(
            updInsert,
            isA<Success<int>>(),
            reason: 'iter $iter: updated ticket insert should succeed',
          );

          // --- Retrieve the ORIGINAL ticket and verify its snapshot is intact ---
          final retrieved = await repo.findOpenByPlate(origPlate);
          expect(
            retrieved,
            isNotNull,
            reason: 'iter $iter: original ticket must still be findable',
          );

          _assertSnapshotEquals(
            ticket: retrieved!,
            expectedName: origName,
            expectedRateType: origRateType,
            expectedRateAmount: origRateCents / 100.0,
            expectedGracePeriod: origGrace,
            expectedDailyCap:
                origCapCents != null ? origCapCents / 100.0 : null,
            context: 'iter $iter (original ticket after rule update)',
          );

          await db.close();
        }
      },
    );

    test(
      'snapshot fields are stored as independent columns, not as a reference',
      () async {
        final db = await _openInMemoryDb();
        final repo = TicketRepositoryImpl(_testHelper(db));

        final ruleId = await _insertStubPricingRule(db, name: 'Rule_P16_ref');

        // Insert ticket with specific snapshot.
        final ticket = Ticket(
          plateNumber: 'REF_PLATE',
          entryTime: DateTime.utc(2024, 8, 1, 7, 0),
          pricingRuleId: ruleId,
          pricingRuleName: 'Original Name',
          rateType: RateType.hourly,
          rateAmount: 10.00,
          gracePeriodMinutes: 5,
          dailyMaxCap: 80.00,
          createdBy: 'attendant_ref',
        );

        await repo.insert(ticket);

        // Directly update the pricing_rules row to simulate a rule change.
        await db.update(
          'pricing_rules',
          {
            'name': 'Changed Name',
            'rate_amount_cents': 99999,
            'grace_period_minutes': 60,
            'daily_max_cap_cents': null,
          },
          where: 'id = ?',
          whereArgs: [ruleId],
        );

        // The ticket snapshot must be unchanged.
        final retrieved = await repo.findOpenByPlate('REF_PLATE');
        expect(retrieved, isNotNull);
        _assertSnapshotEquals(
          ticket: retrieved!,
          expectedName: 'Original Name',
          expectedRateType: RateType.hourly,
          expectedRateAmount: 10.00,
          expectedGracePeriod: 5,
          expectedDailyCap: 80.00,
          context: 'after direct pricing_rules update',
        );

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Property 28 — Exit confirmation creates a closed ticket
  // -------------------------------------------------------------------------

  group('Property 28 — Exit confirmation creates a closed ticket', () {
    /// **Validates: Requirements 4.7**
    ///
    /// Note: The transaction creation side of Property 28 is tested in the
    /// integration tests (task 15.4). This test focuses on the ticket side:
    /// closeTicket succeeds, the ticket is no longer open, and countOpen
    /// reflects the change.
    test(
      'closeTicket returns Success, findOpenByPlate returns null, '
      'and countOpen decreases by 1 (10 random tickets)',
      () async {
        final rng = Random(28);
        const iterations = 10;

        for (var iter = 0; iter < iterations; iter++) {
          final db = await _openInMemoryDb();
          final repo = TicketRepositoryImpl(_testHelper(db));

          final ruleId = await _insertStubPricingRule(
            db,
            name: 'Rule_P28_iter$iter',
          );

          final plate = 'P28_$iter';
          final ticket = _randomTicket(rng, plate, ruleId);

          // Insert the open ticket.
          final insertResult = await repo.insert(ticket);
          expect(
            insertResult,
            isA<Success<int>>(),
            reason: 'iter $iter: insert should succeed',
          );
          final ticketId = (insertResult as Success<int>).value;

          // Capture open count before closing.
          final countBefore = await repo.countOpen();

          // Close the ticket.
          final exitTime = ticket.entryTime.add(
            Duration(minutes: 30 + rng.nextInt(120)),
          );
          final closeResult = await repo.closeTicket(
            ticketId,
            exitTime,
            'attendant_exit',
          );
          expect(
            closeResult,
            isA<Success<void>>(),
            reason: 'iter $iter: closeTicket should return Success',
          );

          // Ticket must no longer appear as open.
          final openTicket = await repo.findOpenByPlate(plate);
          expect(
            openTicket,
            isNull,
            reason: 'iter $iter: findOpenByPlate must return null after close',
          );

          // countOpen must have decreased by exactly 1.
          final countAfter = await repo.countOpen();
          expect(
            countAfter,
            equals(countBefore - 1),
            reason: 'iter $iter: countOpen must decrease by 1 after close '
                '(before=$countBefore, after=$countAfter)',
          );

          await db.close();
        }
      },
    );

    test(
      'closing one ticket does not affect other open tickets',
      () async {
        final db = await _openInMemoryDb();
        final repo = TicketRepositoryImpl(_testHelper(db));

        final ruleId = await _insertStubPricingRule(db, name: 'Rule_P28_multi');
        final rng = Random(281);

        // Insert 3 open tickets.
        final plates = ['P28_A', 'P28_B', 'P28_C'];
        final ids = <int>[];
        for (final plate in plates) {
          final t = _randomTicket(rng, plate, ruleId);
          final r = await repo.insert(t);
          ids.add((r as Success<int>).value);
        }

        expect(await repo.countOpen(), equals(3));

        // Close only the second ticket.
        final exitTime = DateTime.utc(2024, 1, 2, 12, 0);
        await repo.closeTicket(ids[1], exitTime, 'attendant_exit');

        // P28_B must be closed.
        expect(await repo.findOpenByPlate('P28_B'), isNull);

        // P28_A and P28_C must still be open.
        expect(await repo.findOpenByPlate('P28_A'), isNotNull);
        expect(await repo.findOpenByPlate('P28_C'), isNotNull);

        // countOpen must be 2.
        expect(await repo.countOpen(), equals(2));

        await db.close();
      },
    );

    test(
      'closed ticket is excluded from findAllOpen()',
      () async {
        final db = await _openInMemoryDb();
        final repo = TicketRepositoryImpl(_testHelper(db));

        final ruleId = await _insertStubPricingRule(db, name: 'Rule_P28_excl');
        final rng = Random(282);

        final plate = 'P28_EXCL';
        final ticket = _randomTicket(rng, plate, ruleId);
        final insertResult = await repo.insert(ticket);
        final ticketId = (insertResult as Success<int>).value;

        // Verify it appears in findAllOpen before closing.
        final openBefore = await repo.findAllOpen();
        expect(openBefore.any((t) => t.plateNumber == plate), isTrue);

        // Close it.
        await repo.closeTicket(
          ticketId,
          ticket.entryTime.add(const Duration(hours: 2)),
          'attendant_exit',
        );

        // Must not appear in findAllOpen after closing.
        final openAfter = await repo.findAllOpen();
        expect(openAfter.any((t) => t.plateNumber == plate), isFalse);

        await db.close();
      },
    );
  });
}
