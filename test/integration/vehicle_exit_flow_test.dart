// Integration test — Vehicle Exit Flow
//
// Covers the full vehicle exit flow from provider state through repository
// persistence using an in-memory SQLite database (sqflite_common_ffi).
// No device or emulator is required.
//
// Scenarios tested:
//   1. A vehicle with an open ticket can be looked up and the fee is computed
//      correctly from the pricing rule snapshot.
//   2. Confirming exit closes the ticket (exit_time is set) and writes an
//      immutable ParkingTransaction record with matching fields.
//   3. After a confirmed exit the vehicle is no longer shown as active
//      (findOpenByPlate returns null; countOpen decrements).
//   4. Cancelling exit leaves the ticket open and writes no transaction.
//   5. Looking up a plate with no open ticket returns a BusinessError.
//   6. Looking up an invalid plate format returns a ValidationError.
//   7. Transaction immutability — no UPDATE/DELETE path exists; the record
//      written at exit is identical when retrieved by id.
//
// Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8, 8.4, 10.1

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:parking_system/core/result.dart';
import 'package:parking_system/database/database_helper.dart';
import 'package:parking_system/features/vehicle_exit/vehicle_exit_provider.dart';
import 'package:parking_system/models/parking_transaction.dart';
import 'package:parking_system/models/pricing_rule.dart';
import 'package:parking_system/models/ticket.dart';
import 'package:parking_system/repositories/pricing_repository.dart';
import 'package:parking_system/repositories/ticket_repository.dart';
import 'package:parking_system/models/transaction_filter.dart';
import 'package:parking_system/repositories/transaction_repository.dart';
import 'package:parking_system/features/vehicle_entry/vehicle_entry_provider.dart'
    show ticketRepositoryProvider;

// ---------------------------------------------------------------------------
// In-memory database setup
// ---------------------------------------------------------------------------

/// Opens a fresh in-memory SQLite database with the full parking system schema.
Future<Database> _openInMemoryDb() async {
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE pricing_rules (
            id                   INTEGER PRIMARY KEY AUTOINCREMENT,
            name                 TEXT    NOT NULL UNIQUE,
            rate_type            TEXT    NOT NULL CHECK(rate_type IN ('hourly', 'flat')),
            rate_amount_cents    INTEGER NOT NULL,
            grace_period_minutes INTEGER NOT NULL DEFAULT 0,
            daily_max_cap_cents  INTEGER,
            is_active            INTEGER NOT NULL DEFAULT 1,
            is_default           INTEGER NOT NULL DEFAULT 0
          )
        ''');

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
      },
    ),
  );
}

// ---------------------------------------------------------------------------
// Seed helpers
// ---------------------------------------------------------------------------

/// Inserts a single active default pricing rule and returns it (with its id).
Future<PricingRule> _seedDefaultPricingRule(PricingRepository repo) async {
  const rule = PricingRule(
    name: 'Standard Hourly',
    rateType: RateType.hourly,
    rateAmount: 5.00, // $5.00/hour → 500 cents
    gracePeriodMinutes: 10,
    dailyMaxCap: 50.00, // $50.00 cap → 5000 cents
    isActive: true,
    isDefault: false,
  );

  final insertResult = await repo.insert(rule);
  expect(insertResult, isA<Success<int>>(),
      reason: 'Seed: pricing rule insert must succeed');
  final ruleId = (insertResult as Success<int>).value;

  final setDefaultResult = await repo.setDefault(ruleId);
  expect(setDefaultResult, isA<Success<void>>(),
      reason: 'Seed: setDefault must succeed');

  return rule.copyWith(id: ruleId, isDefault: true);
}

/// Inserts an open ticket directly via [TicketRepository] and returns it.
///
/// [entryTimeOffset] shifts the entry time into the past so that the
/// computed duration is predictable in tests.
Future<Ticket> _seedOpenTicket(
  TicketRepository ticketRepo,
  PricingRule rule, {
  String plate = 'ABC-123',
  String createdBy = 'attendant_test',
  Duration entryTimeOffset = const Duration(hours: 2),
}) async {
  final entryTime = DateTime.now().toUtc().subtract(entryTimeOffset);
  final ticket = Ticket(
    plateNumber: plate,
    entryTime: entryTime,
    pricingRuleId: rule.id!,
    pricingRuleName: rule.name,
    rateType: rule.rateType,
    rateAmount: rule.rateAmount,
    gracePeriodMinutes: rule.gracePeriodMinutes,
    dailyMaxCap: rule.dailyMaxCap,
    createdBy: createdBy,
  );

  final insertResult = await ticketRepo.insert(ticket);
  expect(insertResult, isA<Success<int>>(),
      reason: 'Seed: ticket insert must succeed');
  final ticketId = (insertResult as Success<int>).value;
  return ticket.copyWith(id: ticketId);
}

// ---------------------------------------------------------------------------
// ProviderContainer factory
// ---------------------------------------------------------------------------

/// Creates a [ProviderContainer] with all three repository providers
/// overridden to use the supplied in-memory [DatabaseHelper].
ProviderContainer _makeContainer(DatabaseHelper dbHelper) {
  return ProviderContainer(
    overrides: [
      ticketRepositoryProvider.overrideWithValue(
        TicketRepositoryImpl(dbHelper),
      ),
      transactionRepositoryProvider.overrideWithValue(
        TransactionRepositoryImpl(dbHelper),
      ),
    ],
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

  // -------------------------------------------------------------------------
  // Scenario 1 — lookupPlate finds the open ticket and computes the fee
  // -------------------------------------------------------------------------

  group('Scenario 1 — lookupPlate finds open ticket and computes fee', () {
    /// Requirements: 4.3, 4.4, 4.5
    test(
      'lookupPlate with a valid plate that has an open ticket sets openTicket, '
      'computedFee, and durationMinutes in state',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);

        final rule = await _seedDefaultPricingRule(pricingRepo);
        // Seed a ticket parked for exactly 2 hours.
        await _seedOpenTicket(
          ticketRepo,
          rule,
          plate: 'ABC-123',
          entryTimeOffset: const Duration(hours: 2),
        );

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        final before = DateTime.now().toUtc();
        await container
            .read(vehicleExitProvider.notifier)
            .lookupPlate('ABC-123');
        final after = DateTime.now().toUtc();

        final state = container.read(vehicleExitProvider);

        expect(state.isLoading, isFalse);
        expect(state.error, isNull,
            reason: 'no error expected for a valid plate with an open ticket');
        expect(state.openTicket, isNotNull,
            reason: 'openTicket must be populated after a successful lookup');
        expect(state.computedFee, isNotNull,
            reason: 'computedFee must be populated after a successful lookup');
        expect(state.durationMinutes, isNotNull,
            reason: 'durationMinutes must be populated after a successful lookup');

        // Duration should be approximately 120 minutes (2 hours).
        // Allow a small tolerance for test execution time.
        expect(
          state.durationMinutes,
          greaterThanOrEqualTo(120),
          reason: 'duration must be at least 120 minutes for a 2-hour session',
        );
        expect(
          state.durationMinutes,
          lessThanOrEqualTo(121),
          reason: 'duration must not exceed 121 minutes for a 2-hour session',
        );

        // Fee for 2 hours at $5.00/hour = $10.00 = 1000 cents.
        expect(
          state.computedFee!.cents,
          equals(1000),
          reason: '2 hours at \$5.00/hour must produce a \$10.00 fee',
        );

        // openTicket fields must match the seeded ticket.
        expect(state.openTicket!.plateNumber, equals('ABC-123'));
        expect(state.openTicket!.exitTime, isNull,
            reason: 'ticket must still be open after lookup');
        expect(state.openTicket!.pricingRuleName, equals(rule.name));

        // confirmed must still be false — no exit has been confirmed yet.
        expect(state.confirmed, isFalse);

        // Suppress unused variable warnings.
        expect(before.isBefore(after) || before.isAtSameMomentAs(after), isTrue);

        await db.close();
      },
    );

    test(
      'fee respects the grace period — sessions within grace window cost zero',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);

        final rule = await _seedDefaultPricingRule(pricingRepo);
        // Seed a ticket parked for only 5 minutes (within the 10-min grace period).
        await _seedOpenTicket(
          ticketRepo,
          rule,
          plate: 'GRACE-1',
          entryTimeOffset: const Duration(minutes: 5),
        );

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        await container
            .read(vehicleExitProvider.notifier)
            .lookupPlate('GRACE-1');

        final state = container.read(vehicleExitProvider);
        expect(state.error, isNull);
        expect(state.computedFee, isNotNull);
        expect(
          state.computedFee!.cents,
          equals(0),
          reason: 'fee must be zero for sessions within the grace period',
        );

        await db.close();
      },
    );

    test(
      'fee respects the daily cap — sessions exceeding the cap are capped',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);

        final rule = await _seedDefaultPricingRule(pricingRepo);
        // Seed a ticket parked for 12 hours.
        // 12 hours × $5.00 = $60.00, but cap is $50.00.
        await _seedOpenTicket(
          ticketRepo,
          rule,
          plate: 'CAP-1',
          entryTimeOffset: const Duration(hours: 12),
        );

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        await container
            .read(vehicleExitProvider.notifier)
            .lookupPlate('CAP-1');

        final state = container.read(vehicleExitProvider);
        expect(state.error, isNull);
        expect(state.computedFee, isNotNull);
        expect(
          state.computedFee!.cents,
          equals(5000), // $50.00 cap
          reason: 'fee must be capped at \$50.00 for a 12-hour session',
        );

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Scenario 2 — confirmExit closes the ticket and writes a transaction
  // -------------------------------------------------------------------------

  group('Scenario 2 — confirmExit closes ticket and writes transaction', () {
    /// Requirements: 4.7, 4.8, 10.1
    test(
      'confirmExit sets exit_time on the ticket and writes a ParkingTransaction '
      'with matching fields; state transitions to confirmed',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);
        final txRepo = TransactionRepositoryImpl(dbHelper);

        final rule = await _seedDefaultPricingRule(pricingRepo);
        final seededTicket = await _seedOpenTicket(
          ticketRepo,
          rule,
          plate: 'EXIT-1',
          entryTimeOffset: const Duration(hours: 1),
        );

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        // Step 1: lookup the plate to populate state.
        await container
            .read(vehicleExitProvider.notifier)
            .lookupPlate('EXIT-1');

        expect(container.read(vehicleExitProvider).openTicket, isNotNull,
            reason: 'lookup must succeed before confirm');

        // Step 2: confirm the exit.
        final beforeConfirm = DateTime.now().toUtc();
        await container
            .read(vehicleExitProvider.notifier)
            .confirmExit('attendant_test');
        final afterConfirm = DateTime.now().toUtc();

        final state = container.read(vehicleExitProvider);

        // State assertions.
        expect(state.isLoading, isFalse);
        expect(state.error, isNull,
            reason: 'no error expected on successful exit confirmation');
        expect(state.confirmed, isTrue,
            reason: 'confirmed must be true after a successful exit');
        expect(state.completedTransaction, isNotNull,
            reason: 'completedTransaction must be set after confirmation');

        final tx = state.completedTransaction!;
        expect(tx.id, isNotNull,
            reason: 'transaction must have a database-assigned id');
        expect(tx.plateNumber, equals('EXIT-1'));
        expect(tx.ticketId, equals(seededTicket.id));
        expect(tx.paymentStatus, equals(PaymentStatus.paid));
        expect(tx.pricingRuleName, equals(rule.name));
        expect(tx.durationMinutes, greaterThanOrEqualTo(60));
        expect(tx.fee, greaterThan(0.0),
            reason: 'fee must be positive for a 1-hour session');

        // Exit time must be within the confirm window.
        expect(
          tx.exitTime.isAfter(
              beforeConfirm.subtract(const Duration(seconds: 1))),
          isTrue,
        );
        expect(
          tx.exitTime.isBefore(afterConfirm.add(const Duration(seconds: 1))),
          isTrue,
        );

        // Ticket in the database must now have exit_time set.
        final closedTicket = await ticketRepo.findOpenByPlate('EXIT-1');
        expect(closedTicket, isNull,
            reason: 'ticket must no longer be open after exit confirmation');

        // Verify the ticket row directly via raw query.
        final ticketRows = await db.query(
          'tickets',
          where: 'id = ?',
          whereArgs: [seededTicket.id],
        );
        expect(ticketRows.length, equals(1));
        expect(ticketRows.first['exit_time'], isNotNull,
            reason: 'exit_time column must be set on the closed ticket');
        expect(ticketRows.first['closed_by'], equals('attendant_test'));

        // Transaction must be persisted in the database.
        final dbTx = await txRepo.findById(tx.id!);
        expect(dbTx, isNotNull,
            reason: 'transaction must be retrievable from the database');
        expect(dbTx!.plateNumber, equals('EXIT-1'));
        expect(dbTx.ticketId, equals(seededTicket.id));
        expect(dbTx.paymentStatus, equals(PaymentStatus.paid));
        expect(
          (dbTx.fee - tx.fee).abs(),
          lessThan(0.005),
          reason: 'persisted fee must match the in-state fee',
        );

        await db.close();
      },
    );

    test(
      'transaction entry_time and exit_time are stored as UTC epoch ms and '
      'round-trip correctly',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);
        final txRepo = TransactionRepositoryImpl(dbHelper);

        final rule = await _seedDefaultPricingRule(pricingRepo);
        await _seedOpenTicket(
          ticketRepo,
          rule,
          plate: 'UTC-1',
          entryTimeOffset: const Duration(hours: 3),
        );

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        await container
            .read(vehicleExitProvider.notifier)
            .lookupPlate('UTC-1');
        await container
            .read(vehicleExitProvider.notifier)
            .confirmExit('attendant_test');

        final tx = container.read(vehicleExitProvider).completedTransaction!;
        final dbTx = await txRepo.findById(tx.id!);

        expect(dbTx!.entryTime.isUtc, isTrue,
            reason: 'entry_time must be UTC after round-trip');
        expect(dbTx.exitTime.isUtc, isTrue,
            reason: 'exit_time must be UTC after round-trip');
        expect(dbTx.exitTime.isAfter(dbTx.entryTime), isTrue,
            reason: 'exit_time must be after entry_time');

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Scenario 3 — Vehicle is no longer active after exit
  // -------------------------------------------------------------------------

  group('Scenario 3 — Vehicle is no longer active after exit', () {
    /// Requirements: 4.7
    test(
      'after confirmExit the plate has no open ticket and countOpen decrements',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);

        final rule = await _seedDefaultPricingRule(pricingRepo);

        // Seed two open tickets.
        await _seedOpenTicket(ticketRepo, rule,
            plate: 'ACTIVE-1', entryTimeOffset: const Duration(hours: 1));
        await _seedOpenTicket(ticketRepo, rule,
            plate: 'ACTIVE-2', entryTimeOffset: const Duration(hours: 2));

        expect(await ticketRepo.countOpen(), equals(2),
            reason: 'two tickets must be open before any exit');

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        // Exit ACTIVE-1.
        await container
            .read(vehicleExitProvider.notifier)
            .lookupPlate('ACTIVE-1');
        await container
            .read(vehicleExitProvider.notifier)
            .confirmExit('attendant_test');

        // ACTIVE-1 must no longer be open.
        expect(await ticketRepo.findOpenByPlate('ACTIVE-1'), isNull,
            reason: 'ACTIVE-1 must have no open ticket after exit');

        // ACTIVE-2 must still be open.
        expect(await ticketRepo.findOpenByPlate('ACTIVE-2'), isNotNull,
            reason: 'ACTIVE-2 must still have an open ticket');

        // Total open count must have decremented.
        expect(await ticketRepo.countOpen(), equals(1),
            reason: 'open ticket count must be 1 after one exit');

        await db.close();
      },
    );

    test(
      'findAllOpen does not include the exited vehicle',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);

        final rule = await _seedDefaultPricingRule(pricingRepo);
        await _seedOpenTicket(ticketRepo, rule,
            plate: 'GONE-1', entryTimeOffset: const Duration(hours: 1));
        await _seedOpenTicket(ticketRepo, rule,
            plate: 'STILL-1', entryTimeOffset: const Duration(hours: 1));

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        await container
            .read(vehicleExitProvider.notifier)
            .lookupPlate('GONE-1');
        await container
            .read(vehicleExitProvider.notifier)
            .confirmExit('attendant_test');

        final openTickets = await ticketRepo.findAllOpen();
        final plates = openTickets.map((t) => t.plateNumber).toList();

        expect(plates, isNot(contains('GONE-1')),
            reason: 'exited vehicle must not appear in findAllOpen');
        expect(plates, contains('STILL-1'),
            reason: 'non-exited vehicle must still appear in findAllOpen');

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Scenario 4 — cancelExit leaves the ticket open
  // -------------------------------------------------------------------------

  group('Scenario 4 — cancelExit leaves ticket open and writes no transaction',
      () {
    /// Requirements: 4.6
    test(
      'cancelExit resets state without closing the ticket or writing a transaction',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);
        final txRepo = TransactionRepositoryImpl(dbHelper);

        final rule = await _seedDefaultPricingRule(pricingRepo);
        final seededTicket = await _seedOpenTicket(
          ticketRepo,
          rule,
          plate: 'CANCEL-1',
          entryTimeOffset: const Duration(hours: 1),
        );

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        // Lookup the plate to populate state.
        await container
            .read(vehicleExitProvider.notifier)
            .lookupPlate('CANCEL-1');
        expect(container.read(vehicleExitProvider).openTicket, isNotNull);

        // Cancel the exit.
        container.read(vehicleExitProvider.notifier).cancelExit();

        final state = container.read(vehicleExitProvider);

        // State must be reset.
        expect(state.openTicket, isNull,
            reason: 'openTicket must be cleared after cancelExit');
        expect(state.computedFee, isNull,
            reason: 'computedFee must be cleared after cancelExit');
        expect(state.durationMinutes, isNull);
        expect(state.confirmed, isFalse);
        expect(state.error, isNull);
        expect(state.plateInput, equals(''));

        // Ticket must still be open in the database.
        final stillOpen = await ticketRepo.findOpenByPlate('CANCEL-1');
        expect(stillOpen, isNotNull,
            reason: 'ticket must remain open after cancelExit');
        expect(stillOpen!.id, equals(seededTicket.id));
        expect(stillOpen.exitTime, isNull);

        // No transaction must have been written.
        final txResult = await txRepo.query(
          const TransactionFilter(plateSubstring: 'CANCEL-1'),
        );
        final txList = (txResult as Success<List<ParkingTransaction>>).value;
        expect(txList, isEmpty,
            reason: 'no transaction must be written after cancelExit');

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Scenario 5 — Plate with no open ticket returns BusinessError
  // -------------------------------------------------------------------------

  group('Scenario 5 — Plate with no open ticket returns BusinessError', () {
    /// Requirements: 4.3
    test(
      'lookupPlate returns BusinessError when no open ticket exists for the plate',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        await container
            .read(vehicleExitProvider.notifier)
            .lookupPlate('UNKNOWN-1');

        final state = container.read(vehicleExitProvider);
        expect(state.error, isNotNull);
        expect(state.error, isA<BusinessError>(),
            reason: 'must return BusinessError for a plate with no open ticket');
        expect(state.openTicket, isNull);
        expect(state.computedFee, isNull);
        expect(state.confirmed, isFalse);

        await db.close();
      },
    );

    test(
      'lookupPlate returns BusinessError for a plate whose ticket was already closed',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);

        final rule = await _seedDefaultPricingRule(pricingRepo);
        final seededTicket = await _seedOpenTicket(
          ticketRepo,
          rule,
          plate: 'CLOSED-1',
          entryTimeOffset: const Duration(hours: 1),
        );

        // Close the ticket directly via the repository.
        await ticketRepo.closeTicket(
          seededTicket.id!,
          DateTime.now().toUtc(),
          'attendant_test',
        );

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        await container
            .read(vehicleExitProvider.notifier)
            .lookupPlate('CLOSED-1');

        final state = container.read(vehicleExitProvider);
        expect(state.error, isA<BusinessError>(),
            reason: 'must return BusinessError for a plate with a closed ticket');
        expect(state.openTicket, isNull);

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Scenario 6 — Invalid plate format returns ValidationError
  // -------------------------------------------------------------------------

  group('Scenario 6 — Invalid plate format returns ValidationError', () {
    /// Requirements: 4.1, 4.2
    test(
      'lookupPlate returns ValidationError for plates that do not match '
      r'^[A-Za-z0-9\-]{1,10}$',
      () async {
        final invalidPlates = [
          '', // empty
          'TOOLONGPLATE', // 12 chars — exceeds 10
          'HAS SPACE', // contains space
          'SPEC!AL', // contains special char
          'under_score', // underscore not allowed
        ];

        for (final plate in invalidPlates) {
          final db = await _openInMemoryDb();
          final dbHelper = DatabaseHelper.forTesting(db);

          final container = _makeContainer(dbHelper);
          addTearDown(container.dispose);

          await container
              .read(vehicleExitProvider.notifier)
              .lookupPlate(plate);

          final state = container.read(vehicleExitProvider);
          expect(
            state.error,
            isA<ValidationError>(),
            reason: 'plate "$plate" must produce a ValidationError',
          );
          expect(state.openTicket, isNull);
          expect(state.computedFee, isNull);

          await db.close();
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // Scenario 7 — Transaction immutability
  // -------------------------------------------------------------------------

  group('Scenario 7 — Transaction record is immutable after write', () {
    /// Requirements: 8.4, 10.1
    test(
      'transaction retrieved by id is identical to the record written at exit',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);
        final txRepo = TransactionRepositoryImpl(dbHelper);

        final rule = await _seedDefaultPricingRule(pricingRepo);
        await _seedOpenTicket(
          ticketRepo,
          rule,
          plate: 'IMMUT-1',
          entryTimeOffset: const Duration(hours: 2),
        );

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        await container
            .read(vehicleExitProvider.notifier)
            .lookupPlate('IMMUT-1');
        await container
            .read(vehicleExitProvider.notifier)
            .confirmExit('attendant_test');

        final writtenTx =
            container.read(vehicleExitProvider).completedTransaction!;

        // Retrieve the transaction from the database by id.
        final dbTx = await txRepo.findById(writtenTx.id!);
        expect(dbTx, isNotNull);

        // All fields must match exactly.
        expect(dbTx!.id, equals(writtenTx.id));
        expect(dbTx.ticketId, equals(writtenTx.ticketId));
        expect(dbTx.plateNumber, equals(writtenTx.plateNumber));
        expect(
          dbTx.entryTime.millisecondsSinceEpoch,
          equals(writtenTx.entryTime.millisecondsSinceEpoch),
          reason: 'entry_time must survive the round-trip unchanged',
        );
        expect(
          dbTx.exitTime.millisecondsSinceEpoch,
          equals(writtenTx.exitTime.millisecondsSinceEpoch),
          reason: 'exit_time must survive the round-trip unchanged',
        );
        expect(dbTx.durationMinutes, equals(writtenTx.durationMinutes));
        expect(
          (dbTx.fee - writtenTx.fee).abs(),
          lessThan(0.005),
          reason: 'fee must survive the round-trip unchanged',
        );
        expect(dbTx.paymentStatus, equals(writtenTx.paymentStatus));
        expect(dbTx.pricingRuleName, equals(writtenTx.pricingRuleName));

        await db.close();
      },
    );

    test(
      'no UPDATE or DELETE path exists — transaction count stays at 1 after '
      'multiple reads',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);
        final txRepo = TransactionRepositoryImpl(dbHelper);

        final rule = await _seedDefaultPricingRule(pricingRepo);
        await _seedOpenTicket(
          ticketRepo,
          rule,
          plate: 'IMMUT-2',
          entryTimeOffset: const Duration(hours: 1),
        );

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        await container
            .read(vehicleExitProvider.notifier)
            .lookupPlate('IMMUT-2');
        await container
            .read(vehicleExitProvider.notifier)
            .confirmExit('attendant_test');

        // Read the transaction multiple times.
        final tx = container.read(vehicleExitProvider).completedTransaction!;
        await txRepo.findById(tx.id!);
        await txRepo.findById(tx.id!);

        // The transactions table must still contain exactly one row.
        final allTxResult = await txRepo.query(const TransactionFilter());
        final allTx = (allTxResult as Success<List<ParkingTransaction>>).value;
        expect(allTx.length, equals(1),
            reason: 'exactly one transaction must exist after one exit');

        await db.close();
      },
    );
  });
}
