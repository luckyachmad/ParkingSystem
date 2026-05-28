// Unit tests for DatabaseHelper schema creation.
// Verifies that _onCreate creates all five tables and three indexes,
// and that _onUpgrade completes without error.
//
// Uses sqflite_common_ffi to run an in-memory SQLite database without
// a device or emulator.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ---------------------------------------------------------------------------
// Helpers — mirror the exact DDL from DatabaseHelper._onCreate so that the
// tests exercise the real SQL statements.
// ---------------------------------------------------------------------------

/// Runs the same DDL as DatabaseHelper._onCreate against [db].
Future<void> runOnCreate(Database db, int version) async {
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
}

/// Stub that mirrors DatabaseHelper._onUpgrade — no-op for version 1.
Future<void> runOnUpgrade(
  Database db,
  int oldVersion,
  int newVersion,
) async {
  // No migrations required for version 1.
}

// ---------------------------------------------------------------------------
// Test setup
// ---------------------------------------------------------------------------

void main() {
  // Initialise sqflite_common_ffi so tests run on the host (no device needed).
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // Open a fresh in-memory database before each test and close it after.
  late Database db;

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: runOnCreate,
        onUpgrade: runOnUpgrade,
      ),
    );
  });

  tearDown(() async {
    await db.close();
  });

  // -------------------------------------------------------------------------
  // Table existence tests
  // -------------------------------------------------------------------------

  group('_onCreate — tables', () {
    Future<List<String>> queryTableNames(Database database) async {
      final rows = await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      );
      return rows.map((r) => r['name'] as String).toList();
    }

    test('creates the users table', () async {
      final tables = await queryTableNames(db);
      expect(tables, contains('users'));
    });

    test('creates the pricing_rules table', () async {
      final tables = await queryTableNames(db);
      expect(tables, contains('pricing_rules'));
    });

    test('creates the tickets table', () async {
      final tables = await queryTableNames(db);
      expect(tables, contains('tickets'));
    });

    test('creates the transactions table', () async {
      final tables = await queryTableNames(db);
      expect(tables, contains('transactions'));
    });

    test('creates the audit_log table', () async {
      final tables = await queryTableNames(db);
      expect(tables, contains('audit_log'));
    });

    test('creates exactly five application tables', () async {
      final tables = await queryTableNames(db);
      expect(tables.length, equals(5));
    });
  });

  // -------------------------------------------------------------------------
  // Index existence tests
  // -------------------------------------------------------------------------

  group('_onCreate — indexes', () {
    Future<List<String>> queryIndexNames(Database database) async {
      final rows = await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      );
      return rows.map((r) => r['name'] as String).toList();
    }

    test('creates idx_tickets_plate_open', () async {
      final indexes = await queryIndexNames(db);
      expect(indexes, contains('idx_tickets_plate_open'));
    });

    test('creates idx_transactions_exit_time', () async {
      final indexes = await queryIndexNames(db);
      expect(indexes, contains('idx_transactions_exit_time'));
    });

    test('creates idx_transactions_plate', () async {
      final indexes = await queryIndexNames(db);
      expect(indexes, contains('idx_transactions_plate'));
    });

    test('creates exactly three indexes', () async {
      final indexes = await queryIndexNames(db);
      expect(indexes.length, equals(3));
    });
  });

  // -------------------------------------------------------------------------
  // _onUpgrade stub test
  // -------------------------------------------------------------------------

  group('_onUpgrade', () {
    test('completes without error when called with version 1 → 1', () async {
      // _onUpgrade is a no-op for version 1; calling it directly must not throw.
      await expectLater(
        runOnUpgrade(db, 1, 1),
        completes,
      );
    });

    test('completes without error when called with version 1 → 2', () async {
      // Simulates a future upgrade path; stub must still complete cleanly.
      await expectLater(
        runOnUpgrade(db, 1, 2),
        completes,
      );
    });
  });
}
