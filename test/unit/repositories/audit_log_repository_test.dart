// Feature: parking-system, Property 27
//
// Property 27: Authentication events are logged to the audit trail
//   Validates: Requirements 10.3, 10.4, 10.5
//
// For each of login, loginFailed, logout: assert AuditLog contains exactly
// one entry with correct eventType, username, and UTC timestamp >= event
// start time.
//
// Uses in-memory SQLite via sqflite_common_ffi. No device or emulator needed.
// Property tests are implemented manually using dart:math Random with multiple
// iterations (fast_check is a JavaScript library with no Dart pub package).
// bcrypt uses logRounds: 4 (minimum) to keep tests fast.

import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:parking_system/database/database_helper.dart';
import 'package:parking_system/models/audit_event.dart';
import 'package:parking_system/models/user.dart';
import 'package:parking_system/repositories/audit_log_repository.dart';
import 'package:parking_system/repositories/user_repository.dart';
import 'package:parking_system/services/auth_service.dart';

// ---------------------------------------------------------------------------
// In-memory database setup
// ---------------------------------------------------------------------------

/// Opens a fresh in-memory SQLite database with the users and audit_log tables.
Future<Database> _openInMemoryDb() async {
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
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

/// Creates a [DatabaseHelper] pre-loaded with [db] for testing.
DatabaseHelper _testHelper(Database db) => DatabaseHelper.forTesting(db);

/// Builds a fully wired [AuthService] backed by [db].
// ignore: unused_element
AuthService _buildService(Database db) {
  final helper = _testHelper(db);
  return AuthService(
    userRepository: UserRepositoryImpl(helper),
    auditLogRepository: AuditLogRepositoryImpl(helper),
  );
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Characters allowed in a valid username: letters, digits, underscore.
const String _usernameChars =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_';

/// Generates a valid username: 3–50 chars, alphanumeric + underscore.
String _validUsername(Random rng) {
  final length = 3 + rng.nextInt(48); // [3, 50]
  return List.generate(
    length,
    (_) => _usernameChars[rng.nextInt(_usernameChars.length)],
  ).join();
}

/// Generates a valid password: 8–72 printable ASCII chars.
///
/// Capped at 72 chars because bcrypt silently truncates beyond 72 bytes.
/// AuthService validates 8–128 chars for registration, but bcrypt enforces
/// a 72-byte limit. Tests that exercise bcrypt hashing must stay within this.
String _validPassword(Random rng) {
  const chars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
      r'!@#$%^&*()-_=+[]{}|;:,.<>?';
  final length = 8 + rng.nextInt(65); // [8, 72]
  return List.generate(length, (_) => chars[rng.nextInt(chars.length)]).join();
}

/// Generates a wrong password: always 8–22 chars, alphanumeric only,
/// prefixed with 'W_' to ensure it differs from any real password.
String _wrongPassword(Random rng) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final length = 6 + rng.nextInt(15); // [6, 20] — total with prefix: [8, 22]
  final body =
      List.generate(length, (_) => chars[rng.nextInt(chars.length)]).join();
  return 'W_$body'; // guaranteed 8+ chars, well within login's 100-char limit
}

/// Hashes a password with the minimum bcrypt cost factor (4) for test speed.
String _fastHash(String password) =>
    BCrypt.hashpw(password, BCrypt.gensalt(logRounds: 4));

// ---------------------------------------------------------------------------
// Audit log query helper
// ---------------------------------------------------------------------------

/// Reads all rows from the audit_log table and returns them as [AuditEvent]s.
Future<List<AuditEvent>> _queryAuditLog(Database db) async {
  final rows = await db.query('audit_log', orderBy: 'id ASC');
  return rows.map(AuditEvent.fromMap).toList();
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
  // Property 27 — Authentication events are logged to the audit trail
  // Feature: parking-system, Property 27
  // -------------------------------------------------------------------------
  group('Property 27 — Authentication events are logged to the audit trail',
      () {
    // -----------------------------------------------------------------------
    // Sub-property: login success → exactly one AuditEventType.login event
    // -----------------------------------------------------------------------

    /// **Validates: Requirements 10.3, 10.4, 10.5**
    test(
      'login() success writes exactly one login audit event with correct '
      'username and UTC timestamp >= event start time (15 random iterations)',
      () async {
        final rng = Random(271);
        const iterations = 15;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final helper = _testHelper(db);
          final userRepo = UserRepositoryImpl(helper);

          final username = _validUsername(rng);
          final password = _validPassword(rng);
          final hash = _fastHash(password);

          // Seed the user directly with a known hash (avoids full register flow).
          await userRepo.insert(User(
            username: username,
            passwordHash: hash,
            role: Role.attendant,
            isLocked: false,
            failedAttempts: 0,
            createdAt: DateTime.now().toUtc(),
          ));

          final service = AuthService(
            userRepository: userRepo,
            auditLogRepository: AuditLogRepositoryImpl(helper),
          );

          // Truncate to milliseconds to match the DB storage precision.
          final startTime = DateTime.fromMillisecondsSinceEpoch(
            DateTime.now().toUtc().millisecondsSinceEpoch,
            isUtc: true,
          );
          await service.login(LoginRequest(username: username, password: password));

          final events = await _queryAuditLog(db);
          final loginEvents = events
              .where((e) => e.eventType == AuditEventType.login)
              .toList();

          expect(
            loginEvents.length,
            equals(1),
            reason: 'iter $i: exactly one login event must be logged',
          );

          final event = loginEvents.first;
          expect(
            event.username,
            equals(username),
            reason: 'iter $i: audit event username must match login username',
          );
          expect(
            event.timestamp.isAfter(startTime) ||
                event.timestamp.isAtSameMomentAs(startTime),
            isTrue,
            reason: 'iter $i: audit event timestamp must be >= event start time '
                '(event=${event.timestamp.toIso8601String()}, '
                'start=${startTime.toIso8601String()})',
          );

          await db.close();
        }
      },
    );

    // -----------------------------------------------------------------------
    // Sub-property: loginFailed (wrong password) → exactly one
    //               AuditEventType.loginFailed event
    // -----------------------------------------------------------------------

    /// **Validates: Requirements 10.3, 10.4, 10.5**
    test(
      'login() with wrong password writes exactly one loginFailed audit event '
      'with correct username and UTC timestamp >= event start time '
      '(15 random iterations)',
      () async {
        final rng = Random(272);
        const iterations = 15;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final helper = _testHelper(db);
          final userRepo = UserRepositoryImpl(helper);

          final username = _validUsername(rng);
          final correctPassword = _validPassword(rng);
          final wrongPassword = _wrongPassword(rng);
          final hash = _fastHash(correctPassword);

          // Seed the user directly.
          await userRepo.insert(User(
            username: username,
            passwordHash: hash,
            role: Role.attendant,
            isLocked: false,
            failedAttempts: 0,
            createdAt: DateTime.now().toUtc(),
          ));

          final service = AuthService(
            userRepository: userRepo,
            auditLogRepository: AuditLogRepositoryImpl(helper),
          );

          // Truncate to milliseconds to match the DB storage precision.
          final startTime = DateTime.fromMillisecondsSinceEpoch(
            DateTime.now().toUtc().millisecondsSinceEpoch,
            isUtc: true,
          );
          // Use wrong password to trigger the loginFailed path.
          await service.login(LoginRequest(username: username, password: wrongPassword));

          final events = await _queryAuditLog(db);
          final failedEvents = events
              .where((e) => e.eventType == AuditEventType.loginFailed)
              .toList();

          expect(
            failedEvents.length,
            equals(1),
            reason: 'iter $i: exactly one loginFailed event must be logged',
          );

          final event = failedEvents.first;
          expect(
            event.username,
            equals(username),
            reason: 'iter $i: audit event username must match login username',
          );
          expect(
            event.timestamp.isAfter(startTime) ||
                event.timestamp.isAtSameMomentAs(startTime),
            isTrue,
            reason: 'iter $i: audit event timestamp must be >= event start time '
                '(event=${event.timestamp.toIso8601String()}, '
                'start=${startTime.toIso8601String()})',
          );

          await db.close();
        }
      },
    );

    // -----------------------------------------------------------------------
    // Sub-property: logout → exactly one AuditEventType.logout event
    // -----------------------------------------------------------------------

    /// **Validates: Requirements 10.3, 10.4, 10.5**
    test(
      'logout() writes exactly one logout audit event with correct username '
      'and UTC timestamp >= event start time (15 random iterations)',
      () async {
        final rng = Random(273);
        const iterations = 15;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final helper = _testHelper(db);
          final userRepo = UserRepositoryImpl(helper);

          final username = _validUsername(rng);
          // userId can be any positive integer for logout — seed a user to
          // get a real id, but the logout call only needs userId + username.
          final insertResult = await userRepo.insert(User(
            username: username,
            passwordHash: _fastHash('SomePass1!'),
            role: Role.attendant,
            isLocked: false,
            failedAttempts: 0,
            createdAt: DateTime.now().toUtc(),
          ));
          // Extract the inserted id (Success<int>).
          final userId = (insertResult as dynamic).value as int;

          final service = AuthService(
            userRepository: userRepo,
            auditLogRepository: AuditLogRepositoryImpl(helper),
          );

          // Truncate to milliseconds to match the DB storage precision.
          final startTime = DateTime.fromMillisecondsSinceEpoch(
            DateTime.now().toUtc().millisecondsSinceEpoch,
            isUtc: true,
          );
          // Call logout directly — no prior login required.
          await service.logout(userId, username);

          final events = await _queryAuditLog(db);
          final logoutEvents = events
              .where((e) => e.eventType == AuditEventType.logout)
              .toList();

          expect(
            logoutEvents.length,
            equals(1),
            reason: 'iter $i: exactly one logout event must be logged',
          );

          final event = logoutEvents.first;
          expect(
            event.username,
            equals(username),
            reason: 'iter $i: audit event username must match logout username',
          );
          expect(
            event.timestamp.isAfter(startTime) ||
                event.timestamp.isAtSameMomentAs(startTime),
            isTrue,
            reason: 'iter $i: audit event timestamp must be >= event start time '
                '(event=${event.timestamp.toIso8601String()}, '
                'start=${startTime.toIso8601String()})',
          );

          await db.close();
        }
      },
    );
  });
}
