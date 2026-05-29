// Feature: parking-system, Property 21, Property 22
//
// Property 21: Dashboard active vehicle count matches open ticket count
//   Validates: Requirements 7.1, 7.5
//
// Property 22: Dashboard daily income equals sum of today's transaction fees
//   Validates: Requirements 7.3, 7.5
//
// Uses in-memory SQLite via sqflite_common_ffi. No device or emulator needed.
// Property tests are implemented manually using dart:math Random with multiple
// iterations (fast_check is a JavaScript library with no Dart pub package).

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:parking_system/database/database_helper.dart';
import 'package:parking_system/repositories/ticket_repository.dart';
import 'package:parking_system/repositories/transaction_repository.dart';
import 'package:parking_system/repositories/user_repository.dart';
import 'package:parking_system/services/dashboard_service.dart';

// ---------------------------------------------------------------------------
// In-memory database setup — full schema (all 5 tables + indexes)
// ---------------------------------------------------------------------------

/// Opens a fresh in-memory SQLite database with the full production schema.
///
/// Mirrors [DatabaseHelper._onCreate] exactly so that foreign-key references
/// (tickets → pricing_rules, transactions → tickets) are satisfied.
Future<Database> _openInMemoryDb() async {
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
        // users
        await db.execute('''
          CREATE TABLE users (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            username        TEXT    NOT NULL UNIQUE,
            password_hash   TEXT    NOT NULL,
            role            TEXT    NOT NULL CHECK(role IN ('owner', 'attendant')),
            is_locked       INTEGER NOT NULL DEFAULT 0,
            failed_attempts INTEGER NOT NULL DEFAULT 0,
            created_at      INTEGER NOT NULL
          )
        ''');

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

        // transactions
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

        // audit_log
        await db.execute('''
          CREATE TABLE audit_log (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            event_type TEXT    NOT NULL,
            username   TEXT    NOT NULL,
            timestamp  INTEGER NOT NULL,
            details    TEXT
          )
        ''');
      },
    ),
  );
}

/// Wraps [db] in a [DatabaseHelper] suitable for testing.
DatabaseHelper _testHelper(Database db) => DatabaseHelper.forTesting(db);

// ---------------------------------------------------------------------------
// Seed helpers
// ---------------------------------------------------------------------------

/// Inserts a single pricing rule row and returns its auto-generated id.
///
/// Required because tickets have a NOT NULL REFERENCES pricing_rules(id).
Future<int> _insertPricingRule(Database db) async {
  return db.insert('pricing_rules', {
    'name': 'test_rule',
    'rate_type': 'hourly',
    'rate_amount_cents': 500,
    'grace_period_minutes': 0,
    'is_active': 1,
    'is_default': 1,
  });
}

/// Inserts [openCount] open tickets (exit_time IS NULL) and [closedCount]
/// closed tickets (exit_time IS NOT NULL) into the database.
///
/// All tickets reference [pricingRuleId]. Plate numbers are unique per ticket
/// to avoid the duplicate-open-ticket guard in [TicketRepositoryImpl.insert].
Future<void> _seedTickets(
  Database db, {
  required int pricingRuleId,
  required int openCount,
  required int closedCount,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final oneHourMs = const Duration(hours: 1).inMilliseconds;

  for (var i = 0; i < openCount; i++) {
    await db.insert('tickets', {
      'plate_number': 'OPEN$i',
      'entry_time': now - oneHourMs,
      'exit_time': null, // open ticket
      'pricing_rule_id': pricingRuleId,
      'pricing_rule_name': 'test_rule',
      'rate_type': 'hourly',
      'rate_amount_cents': 500,
      'grace_period_minutes': 0,
      'created_by': 'attendant',
    });
  }

  for (var i = 0; i < closedCount; i++) {
    await db.insert('tickets', {
      'plate_number': 'CLOSED$i',
      'entry_time': now - oneHourMs * 2,
      'exit_time': now - oneHourMs, // closed ticket
      'pricing_rule_id': pricingRuleId,
      'pricing_rule_name': 'test_rule',
      'rate_type': 'hourly',
      'rate_amount_cents': 500,
      'grace_period_minutes': 0,
      'created_by': 'attendant',
      'closed_by': 'attendant',
    });
  }
}

/// Returns today's local midnight as epoch milliseconds — mirrors
/// [DashboardService._todayMidnightLocal].
int _todayMidnightMs() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
}

/// Inserts a transaction with [feeCents] whose exit_time is [exitTimeMs].
///
/// Requires a valid [ticketId] (foreign key). Uses a fixed plate/entry_time
/// for simplicity — only fee_cents and exit_time vary between calls.
Future<void> _insertTransaction(
  Database db, {
  required int ticketId,
  required int feeCents,
  required int exitTimeMs,
}) async {
  final entryTimeMs = exitTimeMs - const Duration(hours: 1).inMilliseconds;
  await db.insert('transactions', {
    'ticket_id': ticketId,
    'plate_number': 'TX${ticketId}_$exitTimeMs',
    'entry_time': entryTimeMs,
    'exit_time': exitTimeMs,
    'duration_minutes': 60,
    'fee_cents': feeCents,
    'payment_status': 'paid',
    'pricing_rule_name': 'test_rule',
  });
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
  // Property 21 — Dashboard active vehicle count matches open ticket count
  // Feature: parking-system, Property 21
  // -------------------------------------------------------------------------

  group(
    'Property 21 — Dashboard active vehicle count matches open ticket count',
    () {
      /// **Validates: Requirements 7.1, 7.5**
      test(
        '**Validates: Requirements 7.1, 7.5** '
        'computeMetrics().activeVehicles equals the number of open tickets '
        'for any combination of open and closed tickets (30 random iterations)',
        () async {
          final rng = Random(21);
          const iterations = 30;

          for (var iter = 0; iter < iterations; iter++) {
            final db = await _openInMemoryDb();
            final helper = _testHelper(db);

            final pricingRuleId = await _insertPricingRule(db);

            // Random open count [0, 10], closed count [0, 10].
            final openCount = rng.nextInt(11); // [0, 10]
            final closedCount = rng.nextInt(11); // [0, 10]

            await _seedTickets(
              db,
              pricingRuleId: pricingRuleId,
              openCount: openCount,
              closedCount: closedCount,
            );

            final service = DashboardService(
              ticketRepository: TicketRepositoryImpl(helper),
              transactionRepository: TransactionRepositoryImpl(helper),
              userRepository: UserRepositoryImpl(helper),
            );

            final metrics = await service.computeMetrics();

            expect(
              metrics.activeVehicles,
              equals(openCount),
              reason: 'iter $iter: activeVehicles=${metrics.activeVehicles} '
                  '!= openCount=$openCount '
                  '(closedCount=$closedCount)',
            );

            await db.close();
          }
        },
      );

      test(
        'activeVehicles is 0 when all tickets are closed',
        () async {
          final db = await _openInMemoryDb();
          final helper = _testHelper(db);

          final pricingRuleId = await _insertPricingRule(db);
          await _seedTickets(
            db,
            pricingRuleId: pricingRuleId,
            openCount: 0,
            closedCount: 5,
          );

          final service = DashboardService(
            ticketRepository: TicketRepositoryImpl(helper),
            transactionRepository: TransactionRepositoryImpl(helper),
            userRepository: UserRepositoryImpl(helper),
          );

          final metrics = await service.computeMetrics();
          expect(metrics.activeVehicles, equals(0));

          await db.close();
        },
      );

      test(
        'activeVehicles equals total ticket count when all tickets are open',
        () async {
          final db = await _openInMemoryDb();
          final helper = _testHelper(db);

          final pricingRuleId = await _insertPricingRule(db);
          await _seedTickets(
            db,
            pricingRuleId: pricingRuleId,
            openCount: 7,
            closedCount: 0,
          );

          final service = DashboardService(
            ticketRepository: TicketRepositoryImpl(helper),
            transactionRepository: TransactionRepositoryImpl(helper),
            userRepository: UserRepositoryImpl(helper),
          );

          final metrics = await service.computeMetrics();
          expect(metrics.activeVehicles, equals(7));

          await db.close();
        },
      );
    },
  );

  // -------------------------------------------------------------------------
  // Property 22 — Dashboard daily income equals sum of today's transaction fees
  // Feature: parking-system, Property 22
  // -------------------------------------------------------------------------

  group(
    'Property 22 — Dashboard daily income equals sum of today\'s transaction fees',
    () {
      /// **Validates: Requirements 7.3, 7.5**
      test(
        '**Validates: Requirements 7.3, 7.5** '
        'computeMetrics().dailyIncome equals sum of fee_cents/100.0 for '
        'transactions with exit_time >= today\'s local midnight '
        '(30 random iterations with today and yesterday transactions)',
        () async {
          final rng = Random(22);
          const iterations = 30;

          final midnightMs = _todayMidnightMs();
          // "Yesterday" anchor: 1 ms before midnight.
          final yesterdayMs = midnightMs - 1;
          // "Today" anchor: 1 ms after midnight (safely within today).
          final todayMs = midnightMs + 1;

          for (var iter = 0; iter < iterations; iter++) {
            final db = await _openInMemoryDb();
            final helper = _testHelper(db);

            final pricingRuleId = await _insertPricingRule(db);

            // Insert a single closed ticket to satisfy the FK constraint on
            // all transactions in this iteration.
            final ticketId = await db.insert('tickets', {
              'plate_number': 'TXPLATE$iter',
              'entry_time': midnightMs - const Duration(hours: 2).inMilliseconds,
              'exit_time': midnightMs - const Duration(hours: 1).inMilliseconds,
              'pricing_rule_id': pricingRuleId,
              'pricing_rule_name': 'test_rule',
              'rate_type': 'hourly',
              'rate_amount_cents': 500,
              'grace_period_minutes': 0,
              'created_by': 'attendant',
              'closed_by': 'attendant',
            });

            // Random number of today's transactions [1, 8].
            final todayCount = 1 + rng.nextInt(8);
            // Random number of yesterday's transactions [0, 5].
            final yesterdayCount = rng.nextInt(6);

            // Random fee amounts in cents [100, 5000] (i.e. $1.00–$50.00).
            var expectedTodayCents = 0;

            for (var t = 0; t < todayCount; t++) {
              final feeCents = 100 + rng.nextInt(4901); // [100, 5000]
              expectedTodayCents += feeCents;
              await _insertTransaction(
                db,
                ticketId: ticketId,
                feeCents: feeCents,
                exitTimeMs: todayMs + t * 60000, // spread by 1 min each
              );
            }

            for (var y = 0; y < yesterdayCount; y++) {
              final feeCents = 100 + rng.nextInt(4901);
              await _insertTransaction(
                db,
                ticketId: ticketId,
                feeCents: feeCents,
                exitTimeMs: yesterdayMs - y * 60000, // spread into yesterday
              );
            }

            final service = DashboardService(
              ticketRepository: TicketRepositoryImpl(helper),
              transactionRepository: TransactionRepositoryImpl(helper),
              userRepository: UserRepositoryImpl(helper),
            );

            final metrics = await service.computeMetrics();

            final expectedIncome = expectedTodayCents / 100.0;

            expect(
              metrics.dailyIncome,
              closeTo(expectedIncome, 0.001),
              reason: 'iter $iter: dailyIncome=${metrics.dailyIncome} '
                  '!= expectedIncome=$expectedIncome '
                  '(todayCount=$todayCount, yesterdayCount=$yesterdayCount, '
                  'expectedTodayCents=$expectedTodayCents)',
            );

            await db.close();
          }
        },
      );

      test(
        'dailyIncome is 0.0 when all transactions are from yesterday',
        () async {
          final db = await _openInMemoryDb();
          final helper = _testHelper(db);

          final pricingRuleId = await _insertPricingRule(db);
          final midnightMs = _todayMidnightMs();

          final ticketId = await db.insert('tickets', {
            'plate_number': 'YESTPLATE',
            'entry_time': midnightMs - const Duration(hours: 3).inMilliseconds,
            'exit_time': midnightMs - const Duration(hours: 1).inMilliseconds,
            'pricing_rule_id': pricingRuleId,
            'pricing_rule_name': 'test_rule',
            'rate_type': 'hourly',
            'rate_amount_cents': 500,
            'grace_period_minutes': 0,
            'created_by': 'attendant',
            'closed_by': 'attendant',
          });

          // Insert 3 transactions all before midnight.
          for (var i = 1; i <= 3; i++) {
            await _insertTransaction(
              db,
              ticketId: ticketId,
              feeCents: 1000,
              exitTimeMs: midnightMs - i * 60000,
            );
          }

          final service = DashboardService(
            ticketRepository: TicketRepositoryImpl(helper),
            transactionRepository: TransactionRepositoryImpl(helper),
            userRepository: UserRepositoryImpl(helper),
          );

          final metrics = await service.computeMetrics();
          expect(metrics.dailyIncome, closeTo(0.0, 0.001));

          await db.close();
        },
      );

      test(
        'dailyIncome is 0.0 when there are no transactions at all',
        () async {
          final db = await _openInMemoryDb();
          final helper = _testHelper(db);

          final service = DashboardService(
            ticketRepository: TicketRepositoryImpl(helper),
            transactionRepository: TransactionRepositoryImpl(helper),
            userRepository: UserRepositoryImpl(helper),
          );

          final metrics = await service.computeMetrics();
          expect(metrics.dailyIncome, closeTo(0.0, 0.001));

          await db.close();
        },
      );

      test(
        'transaction exactly at midnight (exit_time == midnight) is counted',
        () async {
          final db = await _openInMemoryDb();
          final helper = _testHelper(db);

          final pricingRuleId = await _insertPricingRule(db);
          final midnightMs = _todayMidnightMs();

          final ticketId = await db.insert('tickets', {
            'plate_number': 'MIDNIGHTPLATE',
            'entry_time': midnightMs - const Duration(hours: 1).inMilliseconds,
            'exit_time': midnightMs,
            'pricing_rule_id': pricingRuleId,
            'pricing_rule_name': 'test_rule',
            'rate_type': 'hourly',
            'rate_amount_cents': 500,
            'grace_period_minutes': 0,
            'created_by': 'attendant',
            'closed_by': 'attendant',
          });

          // Insert one transaction exactly at midnight.
          await _insertTransaction(
            db,
            ticketId: ticketId,
            feeCents: 2500, // $25.00
            exitTimeMs: midnightMs,
          );

          final service = DashboardService(
            ticketRepository: TicketRepositoryImpl(helper),
            transactionRepository: TransactionRepositoryImpl(helper),
            userRepository: UserRepositoryImpl(helper),
          );

          final metrics = await service.computeMetrics();
          // exit_time >= midnight, so this transaction must be counted.
          expect(metrics.dailyIncome, closeTo(25.0, 0.001));

          await db.close();
        },
      );
    },
  );
}
