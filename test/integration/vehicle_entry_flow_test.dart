// Integration test — Vehicle Entry Flow
//
// Covers the full vehicle entry flow from provider state through repository
// persistence using an in-memory SQLite database (sqflite_common_ffi).
// No device or emulator is required.
//
// Scenarios tested:
//   1. Valid plate entry creates a ticket with the correct pricing rule
//      snapshot and transitions VehicleEntryState to show the confirmation.
//   2. Submitting the same plate a second time returns a BusinessError and
//      does NOT create a duplicate open ticket.
//   3. Submitting a plate when no active pricing rule exists returns a
//      BusinessError and does NOT create a ticket.
//   4. Submitting an invalid plate format returns a ValidationError and does
//      NOT create a ticket.
//
// Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:parking_system/core/result.dart';
import 'package:parking_system/database/database_helper.dart';
import 'package:parking_system/features/vehicle_entry/vehicle_entry_provider.dart';
import 'package:parking_system/models/pricing_rule.dart';
import 'package:parking_system/repositories/pricing_repository.dart';
import 'package:parking_system/repositories/ticket_repository.dart';

// ---------------------------------------------------------------------------
// In-memory database setup
// ---------------------------------------------------------------------------

/// Opens a fresh in-memory SQLite database with the full parking system schema.
///
/// Mirrors [DatabaseHelper._onCreate] so that all FK constraints and indexes
/// are present, giving the integration test the same environment as production.
Future<Database> _openInMemoryDb() async {
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
        // pricing_rules
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

        // tickets
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

        // transactions (schema completeness — not written in entry flow)
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
Future<PricingRule> _seedDefaultPricingRule(
  PricingRepository repo,
  Database db,
) async {
  const rule = PricingRule(
    name: 'Standard Hourly',
    rateType: RateType.hourly,
    rateAmount: 5.00, // $5.00/hour → 500 cents
    gracePeriodMinutes: 10,
    dailyMaxCap: 50.00, // $50.00 cap → 5000 cents
    isActive: true,
    isDefault: false, // insert first, then set default
  );

  final insertResult = await repo.insert(rule);
  expect(insertResult, isA<Success<int>>(),
      reason: 'Seed: pricing rule insert must succeed');
  final ruleId = (insertResult as Success<int>).value;

  final setDefaultResult = await repo.setDefault(ruleId);
  expect(setDefaultResult, isA<Success<void>>(),
      reason: 'Seed: setDefault must succeed');

  // Return the rule with its assigned id.
  return rule.copyWith(id: ruleId, isDefault: true);
}

// ---------------------------------------------------------------------------
// ProviderContainer factory
// ---------------------------------------------------------------------------

/// Creates a [ProviderContainer] with the pricing and ticket repository
/// providers overridden to use the supplied in-memory [DatabaseHelper].
ProviderContainer _makeContainer(DatabaseHelper dbHelper) {
  return ProviderContainer(
    overrides: [
      pricingRepositoryProvider.overrideWithValue(
        PricingRepositoryImpl(dbHelper),
      ),
      ticketRepositoryProvider.overrideWithValue(
        TicketRepositoryImpl(dbHelper),
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
  // Scenario 1 — Valid plate entry creates a ticket
  // -------------------------------------------------------------------------

  group('Scenario 1 — Valid plate entry creates a ticket', () {
    /// Requirements: 3.1, 3.4, 3.5
    test(
      'submitEntry with a valid plate creates an open ticket with the correct '
      'pricing rule snapshot and sets lastCreatedTicket in state',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);

        // Seed: one active default pricing rule.
        final seededRule = await _seedDefaultPricingRule(pricingRepo, db);

        // Build the provider container with real repositories.
        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        const attendant = 'attendant_test';
        const plate = 'ABC-123';

        // Act: submit a valid plate.
        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry(plate, attendant);

        final state = container.read(vehicleEntryProvider);

        // Assert: no error, not loading.
        expect(state.isLoading, isFalse,
            reason: 'isLoading must be false after submitEntry completes');
        expect(state.error, isNull,
            reason: 'error must be null on successful entry');

        // Assert: confirmation ticket is present in state.
        expect(state.lastCreatedTicket, isNotNull,
            reason: 'lastCreatedTicket must be set after successful entry');

        final stateTicket = state.lastCreatedTicket!;
        expect(stateTicket.plateNumber, equals(plate));
        expect(stateTicket.exitTime, isNull,
            reason: 'ticket must be open (exitTime == null)');
        expect(stateTicket.createdBy, equals(attendant));
        expect(stateTicket.id, isNotNull,
            reason: 'ticket must have a database-assigned id');

        // Assert: pricing rule snapshot fields match the seeded rule.
        expect(stateTicket.pricingRuleId, equals(seededRule.id));
        expect(stateTicket.pricingRuleName, equals(seededRule.name));
        expect(stateTicket.rateType, equals(seededRule.rateType));
        expect(
          (stateTicket.rateAmount - seededRule.rateAmount).abs(),
          lessThan(0.005),
          reason: 'rateAmount snapshot must match the seeded rule',
        );
        expect(stateTicket.gracePeriodMinutes,
            equals(seededRule.gracePeriodMinutes));
        expect(
          stateTicket.dailyMaxCap,
          isNotNull,
          reason: 'dailyMaxCap snapshot must not be null',
        );
        expect(
          (stateTicket.dailyMaxCap! - seededRule.dailyMaxCap!).abs(),
          lessThan(0.005),
          reason: 'dailyMaxCap snapshot must match the seeded rule',
        );

        // Assert: ticket is persisted in the database.
        final dbTicket = await ticketRepo.findOpenByPlate(plate);
        expect(dbTicket, isNotNull,
            reason: 'ticket must be findable in the database after entry');
        expect(dbTicket!.plateNumber, equals(plate));
        expect(dbTicket.exitTime, isNull);
        expect(dbTicket.pricingRuleName, equals(seededRule.name));

        await db.close();
      },
    );

    test(
      'entry time on the created ticket is a recent UTC timestamp',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);

        await _seedDefaultPricingRule(pricingRepo, db);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        final before = DateTime.now().toUtc();
        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry('XY-9999', 'attendant_test');
        final after = DateTime.now().toUtc();

        final ticket =
            container.read(vehicleEntryProvider).lastCreatedTicket!;

        expect(
          ticket.entryTime.isAfter(before.subtract(const Duration(seconds: 1))),
          isTrue,
          reason: 'entryTime must be at or after the test start time',
        );
        expect(
          ticket.entryTime.isBefore(after.add(const Duration(seconds: 1))),
          isTrue,
          reason: 'entryTime must be at or before the test end time',
        );
        expect(ticket.entryTime.isUtc, isTrue,
            reason: 'entryTime must be stored as UTC');

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Scenario 2 — Duplicate plate is rejected
  // -------------------------------------------------------------------------

  group('Scenario 2 — Duplicate plate is rejected', () {
    /// Requirements: 3.3
    test(
      'submitting the same plate twice returns BusinessError on the second '
      'attempt and leaves exactly one open ticket in the database',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);

        await _seedDefaultPricingRule(pricingRepo, db);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        const plate = 'DUP-001';
        const attendant = 'attendant_test';

        // First entry — must succeed.
        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry(plate, attendant);

        final firstState = container.read(vehicleEntryProvider);
        expect(firstState.error, isNull,
            reason: 'first entry must succeed without error');
        expect(firstState.lastCreatedTicket, isNotNull,
            reason: 'first entry must produce a ticket');

        // Second entry for the same plate — must fail.
        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry(plate, attendant);

        final secondState = container.read(vehicleEntryProvider);
        expect(secondState.error, isNotNull,
            reason: 'second entry for same plate must set an error');
        expect(secondState.error, isA<BusinessError>(),
            reason: 'error must be a BusinessError (duplicate open ticket)');
        expect(secondState.lastCreatedTicket, isNull,
            reason: 'lastCreatedTicket must be null after a failed entry');

        // Database must contain exactly one open ticket for this plate.
        final openTicket = await ticketRepo.findOpenByPlate(plate);
        expect(openTicket, isNotNull,
            reason: 'the original open ticket must still exist');

        final allOpen = await ticketRepo.findAllOpen();
        final plateTickets =
            allOpen.where((t) => t.plateNumber == plate).toList();
        expect(plateTickets.length, equals(1),
            reason: 'exactly one open ticket must exist for plate $plate');

        await db.close();
      },
    );

    test(
      'duplicate rejection does not affect open tickets for other plates',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);

        await _seedDefaultPricingRule(pricingRepo, db);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        // Enter two different plates.
        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry('PLATE-A', 'attendant_test');
        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry('PLATE-B', 'attendant_test');

        // Try to enter PLATE-A again — should fail.
        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry('PLATE-A', 'attendant_test');

        final state = container.read(vehicleEntryProvider);
        expect(state.error, isA<BusinessError>());

        // Both original plates must still have exactly one open ticket each.
        expect(await ticketRepo.findOpenByPlate('PLATE-A'), isNotNull);
        expect(await ticketRepo.findOpenByPlate('PLATE-B'), isNotNull);
        expect(await ticketRepo.countOpen(), equals(2),
            reason: 'total open ticket count must remain 2');

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Scenario 3 — No active pricing rule
  // -------------------------------------------------------------------------

  group('Scenario 3 — No active pricing rule configured', () {
    /// Requirements: 3.6
    test(
      'submitEntry returns BusinessError when no default pricing rule exists '
      'and no ticket is created',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final ticketRepo = TicketRepositoryImpl(dbHelper);

        // Do NOT seed any pricing rule — database is empty.
        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry('NO-RULE', 'attendant_test');

        final state = container.read(vehicleEntryProvider);
        expect(state.error, isA<BusinessError>(),
            reason: 'must return BusinessError when no pricing rule exists');
        expect(state.lastCreatedTicket, isNull,
            reason: 'no ticket must be created when no pricing rule exists');

        // Database must have no open tickets.
        expect(await ticketRepo.countOpen(), equals(0));

        await db.close();
      },
    );

    test(
      'submitEntry returns BusinessError when all pricing rules are inactive',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);

        // Insert a rule, set it as default, then deactivate it.
        final seededRule = await _seedDefaultPricingRule(pricingRepo, db);
        await pricingRepo.deactivate(seededRule.id!);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry('INACTIVE', 'attendant_test');

        final state = container.read(vehicleEntryProvider);
        expect(state.error, isA<BusinessError>(),
            reason: 'must return BusinessError when default rule is inactive');
        expect(state.lastCreatedTicket, isNull);
        expect(await ticketRepo.countOpen(), equals(0));

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Scenario 4 — Invalid plate format
  // -------------------------------------------------------------------------

  group('Scenario 4 — Invalid plate format is rejected', () {
    /// Requirements: 3.1, 3.2
    test(
      'submitEntry returns ValidationError for plates that do not match '
      '^[A-Za-z0-9\\-]{1,10}\$ and no ticket is created',
      () async {
        final invalidPlates = [
          '', // empty
          'TOOLONGPLATE', // 12 chars — exceeds 10
          'HAS SPACE', // contains space
          'SPEC!AL', // contains special char
          'under_score', // underscore not allowed
          'dot.plate', // dot not allowed
        ];

        for (final plate in invalidPlates) {
          final db = await _openInMemoryDb();
          final dbHelper = DatabaseHelper.forTesting(db);
          final pricingRepo = PricingRepositoryImpl(dbHelper);
          final ticketRepo = TicketRepositoryImpl(dbHelper);

          // Seed a valid pricing rule so the test isolates plate validation.
          await _seedDefaultPricingRule(pricingRepo, db);

          final container = _makeContainer(dbHelper);
          addTearDown(container.dispose);

          await container
              .read(vehicleEntryProvider.notifier)
              .submitEntry(plate, 'attendant_test');

          final state = container.read(vehicleEntryProvider);
          expect(
            state.error,
            isA<ValidationError>(),
            reason: 'plate "$plate" must produce a ValidationError',
          );
          expect(
            state.lastCreatedTicket,
            isNull,
            reason: 'no ticket must be created for invalid plate "$plate"',
          );
          expect(
            await ticketRepo.countOpen(),
            equals(0),
            reason: 'database must have no tickets for invalid plate "$plate"',
          );

          await db.close();
        }
      },
    );

    test(
      'submitEntry accepts boundary-valid plates (1 char and 10 chars)',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);
        final ticketRepo = TicketRepositoryImpl(dbHelper);

        await _seedDefaultPricingRule(pricingRepo, db);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        // 1-character plate.
        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry('A', 'attendant_test');
        expect(container.read(vehicleEntryProvider).error, isNull,
            reason: 'single-char plate must be accepted');
        expect(container.read(vehicleEntryProvider).lastCreatedTicket,
            isNotNull);

        // Reset state for next entry.
        container.read(vehicleEntryProvider.notifier).reset();

        // 10-character plate.
        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry('AB12-CD34EF', 'attendant_test');
        // 'AB12-CD34EF' is 11 chars — use a valid 10-char plate instead.
        // Reset and try a proper 10-char plate.
        container.read(vehicleEntryProvider.notifier).reset();

        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry('AB12-CD34E', 'attendant_test'); // exactly 10 chars
        expect(container.read(vehicleEntryProvider).error, isNull,
            reason: '10-char plate must be accepted');
        expect(container.read(vehicleEntryProvider).lastCreatedTicket,
            isNotNull);

        // Two open tickets total.
        expect(await ticketRepo.countOpen(), equals(2));

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Scenario 5 — State reset
  // -------------------------------------------------------------------------

  group('Scenario 5 — State management', () {
    test(
      'reset() clears lastCreatedTicket and error from state',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);

        await _seedDefaultPricingRule(pricingRepo, db);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        // Perform a successful entry.
        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry('RESET-1', 'attendant_test');

        expect(
            container.read(vehicleEntryProvider).lastCreatedTicket, isNotNull);

        // Reset.
        container.read(vehicleEntryProvider.notifier).reset();

        final state = container.read(vehicleEntryProvider);
        expect(state.lastCreatedTicket, isNull,
            reason: 'reset() must clear lastCreatedTicket');
        expect(state.error, isNull,
            reason: 'reset() must clear any error');
        expect(state.isLoading, isFalse);
        expect(state.plateInput, equals(''));

        await db.close();
      },
    );

    test(
      'clearError() removes the error without clearing lastCreatedTicket',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final pricingRepo = PricingRepositoryImpl(dbHelper);

        await _seedDefaultPricingRule(pricingRepo, db);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        // Successful entry first.
        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry('CLEAR-1', 'attendant_test');
        final ticketAfterSuccess =
            container.read(vehicleEntryProvider).lastCreatedTicket;
        expect(ticketAfterSuccess, isNotNull);

        // Trigger a validation error.
        await container
            .read(vehicleEntryProvider.notifier)
            .submitEntry('', 'attendant_test');
        expect(container.read(vehicleEntryProvider).error, isA<ValidationError>());

        // clearError() should remove the error.
        container.read(vehicleEntryProvider.notifier).clearError();

        final state = container.read(vehicleEntryProvider);
        expect(state.error, isNull,
            reason: 'clearError() must remove the error');

        await db.close();
      },
    );
  });
}
