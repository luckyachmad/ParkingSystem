import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// Singleton responsible for opening the SQLite database, running schema
/// creation via [_onCreate], and exposing the [Database] instance to
/// repository classes.
///
/// Repositories are the only consumers of this class — widgets and services
/// must never call sqflite directly.
class DatabaseHelper {
  static const String _dbName = 'parking_system.db';
  static const int _dbVersion = 1;

  /// The single shared instance of [DatabaseHelper].
  static final DatabaseHelper instance = DatabaseHelper._internal();

  DatabaseHelper._internal();

  /// Creates a [DatabaseHelper] pre-loaded with [db].
  ///
  /// Intended for use in unit tests only — pass an in-memory SQLite database
  /// so that repository tests run without a device or emulator.
  @visibleForTesting
  DatabaseHelper.forTesting(Database db) : _database = db;

  Database? _database;

  /// Returns the open [Database], initializing it on first access (lazy init).
  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  /// Opens (or creates) the database file and wires [_onCreate] / [_onUpgrade].
  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// Runs all DDL statements when the database is first created.
  ///
  /// Creates five tables (users, pricing_rules, tickets, transactions,
  /// audit_log) and three indexes as defined in the design schema.
  Future<void> _onCreate(Database db, int version) async {
    // ------------------------------------------------------------------ users
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

    // ---------------------------------------------------------- pricing_rules
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

    // --------------------------------------------------------------- tickets
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

    // ---------------------------------------------------------- transactions
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

    // --------------------------------------------------------------- audit_log
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

  /// Stub for future schema migrations.
  ///
  /// When [_dbVersion] is incremented, add migration logic here using
  /// [oldVersion] and [newVersion] to apply incremental ALTER TABLE / CREATE
  /// TABLE statements. Never drop and recreate tables in production.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // No migrations required for version 1.
    // Future migrations should follow the pattern:
    //   if (oldVersion < 2) { await db.execute('ALTER TABLE ...'); }
    //   if (oldVersion < 3) { ... }
  }
}
