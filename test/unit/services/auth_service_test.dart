// Feature: parking-system, Properties 2–9
//
// Property 2: Successful registration creates a retrievable user
//   Validates: Requirements 1.2
//
// Property 3: Duplicate username registration is rejected
//   Validates: Requirements 1.3
//
// Property 4: Out-of-range passwords are rejected at registration
//   Validates: Requirements 1.4
//
// Property 5: Successful registration produces an audit log entry
//   Validates: Requirements 1.6
//
// Property 6: Valid credentials produce an authenticated session
//   Validates: Requirements 2.1
//
// Property 7: Invalid credentials return a generic error
//   Validates: Requirements 2.2
//
// Property 8: Five consecutive failed logins lock the account
//   Validates: Requirements 2.3
//
// Property 9: Logout invalidates the session
//   Validates: Requirements 2.6
//
// Uses in-memory SQLite via sqflite_common_ffi. No device or emulator needed.
// Property tests are implemented manually using dart:math Random with multiple
// iterations (fast_check is a JavaScript library with no Dart pub package).
// bcrypt uses logRounds: 4 (minimum) to keep tests fast.

import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:parking_system/core/result.dart';
import 'package:parking_system/database/database_helper.dart';
import 'package:parking_system/models/audit_event.dart';
import 'package:parking_system/models/user.dart';
import 'package:parking_system/repositories/audit_log_repository.dart';
import 'package:parking_system/repositories/user_repository.dart';
import 'package:parking_system/services/auth_service.dart';

// ---------------------------------------------------------------------------
// In-memory database setup
// ---------------------------------------------------------------------------

/// Opens a fresh in-memory SQLite database with the full application schema.
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
/// Capped at 72 chars because bcrypt silently truncates (or throws) beyond
/// 72 bytes. The AuthService validates 8–128 chars, but bcrypt itself
/// enforces a 72-byte limit. Tests that exercise bcrypt hashing must stay
/// within this bound.
String _validPassword(Random rng) {
  const chars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
      r'!@#$%^&*()-_=+[]{}|;:,.<>?';
  final length = 8 + rng.nextInt(65); // [8, 72]
  return List.generate(length, (_) => chars[rng.nextInt(chars.length)]).join();
}

/// Generates a valid password for login: 8–72 printable ASCII chars.
/// Login validates 8–100 chars, but we cap at 72 to stay within bcrypt's limit.
// ignore: unused_element
String _validLoginPassword(Random rng) => _validPassword(rng);

/// Generates a wrong password for login tests: always 8–20 chars, alphanumeric
/// only, prefixed with 'W_' to ensure it differs from any real password.
String _wrongPassword(Random rng) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final length = 6 + rng.nextInt(15); // [6, 20] — total with prefix: [8, 22]
  final body =
      List.generate(length, (_) => chars[rng.nextInt(chars.length)]).join();
  return 'W_$body'; // guaranteed 8+ chars, well within login's 100-char limit
}

/// Generates a password that is too short (< 8 chars).
String _tooShortPassword(Random rng) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final length = rng.nextInt(8); // [0, 7]
  return List.generate(length, (_) => chars[rng.nextInt(chars.length)]).join();
}

/// Generates a password that is too long (> 128 chars).
///
/// These are rejected by AuthService before reaching bcrypt, so the 72-byte
/// bcrypt limit is not a concern here.
String _tooLongPassword(Random rng) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final length = 129 + rng.nextInt(50); // [129, 178]
  return List.generate(length, (_) => chars[rng.nextInt(chars.length)]).join();
}

/// Generates a username that fails the regex (contains a space or special char).
String _invalidUsername(Random rng) {
  // Prepend a space to guarantee the regex fails.
  return ' ${_validUsername(rng)}';
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
  // Property 2 — Successful registration creates a retrievable user
  // Feature: parking-system, Property 2
  // -------------------------------------------------------------------------
  group('Property 2 — Successful registration creates a retrievable user', () {
    /// **Validates: Requirements 1.2**
    test(
      'register() with valid username and password returns Success<User> '
      'and the user can be found by username (20 random iterations)',
      () async {
        final rng = Random(2);
        const iterations = 20;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final service = _buildService(db);
          final helper = _testHelper(db);
          final userRepo = UserRepositoryImpl(helper);

          final username = _validUsername(rng);
          final password = _validPassword(rng);
          final role = rng.nextBool() ? Role.owner : Role.attendant;

          final result = await service.register(
            RegisterRequest(username: username, password: password, role: role),
          );

          expect(
            result,
            isA<Success<User>>(),
            reason: 'iter $i: register should succeed for '
                'username="$username", password.length=${password.length}',
          );

          final user = (result as Success<User>).value;
          expect(user.id, isNotNull, reason: 'iter $i: user.id must be set');
          expect(user.username, equals(username),
              reason: 'iter $i: username mismatch');
          expect(user.role, equals(role), reason: 'iter $i: role mismatch');
          expect(user.isLocked, isFalse,
              reason: 'iter $i: new user must not be locked');
          expect(user.failedAttempts, equals(0),
              reason: 'iter $i: failedAttempts must be 0');

          // Verify the user is retrievable from the repository.
          final found = await userRepo.findByUsername(username);
          expect(found, isNotNull,
              reason: 'iter $i: user must be findable by username');
          expect(found!.username, equals(username),
              reason: 'iter $i: retrieved username mismatch');
          expect(found.id, equals(user.id),
              reason: 'iter $i: retrieved id mismatch');

          await db.close();
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // Property 3 — Duplicate username registration is rejected
  // Feature: parking-system, Property 3
  // -------------------------------------------------------------------------
  group('Property 3 — Duplicate username registration is rejected', () {
    /// **Validates: Requirements 1.3**
    test(
      'registering the same username twice returns Failure<BusinessError> '
      'on the second attempt (20 random iterations)',
      () async {
        final rng = Random(3);
        const iterations = 20;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final service = _buildService(db);

          final username = _validUsername(rng);
          final password1 = _validPassword(rng);
          final password2 = _validPassword(rng);

          // First registration must succeed.
          final first = await service.register(
            RegisterRequest(
                username: username, password: password1, role: Role.attendant),
          );
          expect(
            first,
            isA<Success<User>>(),
            reason: 'iter $i: first register should succeed',
          );

          // Second registration with the same username must fail.
          final second = await service.register(
            RegisterRequest(
                username: username, password: password2, role: Role.owner),
          );
          expect(
            second,
            isA<Failure<User>>(),
            reason: 'iter $i: duplicate register should fail',
          );
          expect(
            (second as Failure<User>).error,
            isA<BusinessError>(),
            reason: 'iter $i: error must be BusinessError for duplicate',
          );

          await db.close();
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // Property 4 — Out-of-range passwords are rejected at registration
  // Feature: parking-system, Property 4
  // -------------------------------------------------------------------------
  group('Property 4 — Out-of-range passwords are rejected at registration', () {
    /// **Validates: Requirements 1.4**
    test(
      'register() with a password shorter than 8 chars returns '
      'Failure<ValidationError> (20 random iterations)',
      () async {
        final rng = Random(41);
        const iterations = 20;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final service = _buildService(db);

          final username = _validUsername(rng);
          final shortPassword = _tooShortPassword(rng);

          final result = await service.register(
            RegisterRequest(
                username: username,
                password: shortPassword,
                role: Role.attendant),
          );

          expect(
            result,
            isA<Failure<User>>(),
            reason: 'iter $i: short password (len=${shortPassword.length}) '
                'should be rejected',
          );
          expect(
            (result as Failure<User>).error,
            isA<ValidationError>(),
            reason: 'iter $i: error must be ValidationError',
          );

          await db.close();
        }
      },
    );

    test(
      'register() with a password longer than 128 chars returns '
      'Failure<ValidationError> (20 random iterations)',
      () async {
        final rng = Random(42);
        const iterations = 20;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final service = _buildService(db);

          final username = _validUsername(rng);
          final longPassword = _tooLongPassword(rng);

          final result = await service.register(
            RegisterRequest(
                username: username,
                password: longPassword,
                role: Role.attendant),
          );

          expect(
            result,
            isA<Failure<User>>(),
            reason: 'iter $i: long password (len=${longPassword.length}) '
                'should be rejected',
          );
          expect(
            (result as Failure<User>).error,
            isA<ValidationError>(),
            reason: 'iter $i: error must be ValidationError',
          );

          await db.close();
        }
      },
    );

    test(
      'register() with an invalid username format returns '
      'Failure<ValidationError> (20 random iterations)',
      () async {
        final rng = Random(43);
        const iterations = 20;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final service = _buildService(db);

          final badUsername = _invalidUsername(rng);
          final password = _validPassword(rng);

          final result = await service.register(
            RegisterRequest(
                username: badUsername,
                password: password,
                role: Role.attendant),
          );

          expect(
            result,
            isA<Failure<User>>(),
            reason: 'iter $i: invalid username "$badUsername" should be rejected',
          );
          expect(
            (result as Failure<User>).error,
            isA<ValidationError>(),
            reason: 'iter $i: error must be ValidationError',
          );

          await db.close();
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // Property 5 — Successful registration produces an audit log entry
  // Feature: parking-system, Property 5
  // -------------------------------------------------------------------------
  group('Property 5 — Successful registration produces an audit log entry', () {
    /// **Validates: Requirements 1.6**
    test(
      'register() success writes exactly one userCreated audit event '
      'with the correct username (20 random iterations)',
      () async {
        final rng = Random(5);
        const iterations = 20;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final service = _buildService(db);

          final username = _validUsername(rng);
          final password = _validPassword(rng);

          final result = await service.register(
            RegisterRequest(
                username: username, password: password, role: Role.attendant),
          );
          expect(result, isA<Success<User>>(),
              reason: 'iter $i: register must succeed');

          final events = await _queryAuditLog(db);
          final userCreatedEvents = events
              .where((e) => e.eventType == AuditEventType.userCreated)
              .toList();

          expect(
            userCreatedEvents.length,
            equals(1),
            reason: 'iter $i: exactly one userCreated event must be logged',
          );
          expect(
            userCreatedEvents.first.username,
            equals(username),
            reason: 'iter $i: audit event username must match registered username',
          );

          await db.close();
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // Property 6 — Valid credentials produce an authenticated session
  // Feature: parking-system, Property 6
  // -------------------------------------------------------------------------
  group('Property 6 — Valid credentials produce an authenticated session', () {
    /// **Validates: Requirements 2.1**
    test(
      'login() with correct username and password returns Success<AuthSession> '
      'with matching userId, username, and role (15 random iterations)',
      () async {
        final rng = Random(6);
        const iterations = 15;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final helper = _testHelper(db);
          final userRepo = UserRepositoryImpl(helper);

          // Insert a user directly with a known password hash (fast cost=4).
          final username = _validUsername(rng);
          final password = _validPassword(rng);
          final role = rng.nextBool() ? Role.owner : Role.attendant;
          final hash = _fastHash(password);

          final insertResult = await userRepo.insert(User(
            username: username,
            passwordHash: hash,
            role: role,
            isLocked: false,
            failedAttempts: 0,
            createdAt: DateTime.now().toUtc(),
          ));
          expect(insertResult, isA<Success<int>>(),
              reason: 'iter $i: user insert must succeed');
          final userId = (insertResult as Success<int>).value;

          final service = AuthService(
            userRepository: userRepo,
            auditLogRepository: AuditLogRepositoryImpl(helper),
          );

          final result = await service.login(
            LoginRequest(username: username, password: password),
          );

          expect(
            result,
            isA<Success<AuthSession>>(),
            reason: 'iter $i: login with correct credentials must succeed',
          );

          final session = (result as Success<AuthSession>).value;
          expect(session.userId, equals(userId),
              reason: 'iter $i: session.userId mismatch');
          expect(session.username, equals(username),
              reason: 'iter $i: session.username mismatch');
          expect(session.role, equals(role),
              reason: 'iter $i: session.role mismatch');

          await db.close();
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // Property 7 — Invalid credentials return a generic error
  // Feature: parking-system, Property 7
  // -------------------------------------------------------------------------
  group('Property 7 — Invalid credentials return a generic error', () {
    /// **Validates: Requirements 2.2**
    test(
      'login() with a non-existent username returns Failure<BusinessError> '
      'with a generic message (15 random iterations)',
      () async {
        final rng = Random(71);
        const iterations = 15;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final service = _buildService(db);

          // Use a username that was never registered (short, valid format, but absent from DB).
          final baseLen = 3 + rng.nextInt(10); // [3, 12] chars
          const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
          final username = List.generate(
            baseLen,
            (_) => chars[rng.nextInt(chars.length)],
          ).join();
          final password = _validPassword(rng);

          final result = await service.login(
            LoginRequest(username: username, password: password),
          );

          expect(
            result,
            isA<Failure<AuthSession>>(),
            reason: 'iter $i: login with unknown user must fail',
          );
          final error = (result as Failure<AuthSession>).error;
          expect(error, isA<BusinessError>(),
              reason: 'iter $i: error must be BusinessError');
          // Message must be generic — must not disclose "user not found".
          expect(
            (error as BusinessError).message,
            equals('Invalid credentials'),
            reason: 'iter $i: error message must be generic',
          );

          await db.close();
        }
      },
    );

    test(
      'login() with correct username but wrong password returns '
      'Failure<BusinessError> with a generic message (15 random iterations)',
      () async {
        final rng = Random(72);
        const iterations = 15;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final helper = _testHelper(db);
          final userRepo = UserRepositoryImpl(helper);

          final username = _validUsername(rng);
          final correctPassword = _validPassword(rng);
          // Ensure wrong password differs from correct one.
          final wrongPassword = _wrongPassword(rng);

          await userRepo.insert(User(
            username: username,
            passwordHash: _fastHash(correctPassword),
            role: Role.attendant,
            isLocked: false,
            failedAttempts: 0,
            createdAt: DateTime.now().toUtc(),
          ));

          final service = AuthService(
            userRepository: userRepo,
            auditLogRepository: AuditLogRepositoryImpl(helper),
          );

          final result = await service.login(
            LoginRequest(username: username, password: wrongPassword),
          );

          expect(
            result,
            isA<Failure<AuthSession>>(),
            reason: 'iter $i: login with wrong password must fail',
          );
          final error = (result as Failure<AuthSession>).error;
          expect(error, isA<BusinessError>(),
              reason: 'iter $i: error must be BusinessError');
          expect(
            (error as BusinessError).message,
            equals('Invalid credentials'),
            reason: 'iter $i: error message must be generic (no field disclosure)',
          );

          await db.close();
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // Property 8 — Five consecutive failed logins lock the account
  // Feature: parking-system, Property 8
  // -------------------------------------------------------------------------
  group('Property 8 — Five consecutive failed logins lock the account', () {
    /// **Validates: Requirements 2.3**
    test(
      'exactly 5 consecutive failed login attempts lock the account; '
      'subsequent login returns Failure<BusinessError> with lock message '
      '(10 random iterations)',
      () async {
        final rng = Random(8);
        const iterations = 10;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final helper = _testHelper(db);
          final userRepo = UserRepositoryImpl(helper);

          final username = _validUsername(rng);
          final correctPassword = _validPassword(rng);
          final wrongPassword = _wrongPassword(rng);

          await userRepo.insert(User(
            username: username,
            passwordHash: _fastHash(correctPassword),
            role: Role.attendant,
            isLocked: false,
            failedAttempts: 0,
            createdAt: DateTime.now().toUtc(),
          ));

          final service = AuthService(
            userRepository: userRepo,
            auditLogRepository: AuditLogRepositoryImpl(helper),
          );

          // Attempts 1–4: must fail with 'Invalid credentials', not locked yet.
          for (var attempt = 1; attempt <= 4; attempt++) {
            final r = await service.login(
              LoginRequest(username: username, password: wrongPassword),
            );
            expect(r, isA<Failure<AuthSession>>(),
                reason: 'iter $i attempt $attempt: must fail');
            final err = (r as Failure<AuthSession>).error;
            expect(err, isA<BusinessError>(),
                reason: 'iter $i attempt $attempt: must be BusinessError');
            expect(
              (err as BusinessError).message,
              equals('Invalid credentials'),
              reason: 'iter $i attempt $attempt: must not be locked yet',
            );
          }

          // Attempt 5: triggers the lock.
          final lockingAttempt = await service.login(
            LoginRequest(username: username, password: wrongPassword),
          );
          expect(lockingAttempt, isA<Failure<AuthSession>>(),
              reason: 'iter $i attempt 5: must fail');

          // Attempt 6: account is now locked — must return lock message.
          final afterLock = await service.login(
            LoginRequest(username: username, password: correctPassword),
          );
          expect(
            afterLock,
            isA<Failure<AuthSession>>(),
            reason: 'iter $i: login after lock must fail',
          );
          final lockError = (afterLock as Failure<AuthSession>).error;
          expect(lockError, isA<BusinessError>(),
              reason: 'iter $i: locked error must be BusinessError');
          expect(
            (lockError as BusinessError).message,
            contains('locked'),
            reason: 'iter $i: locked error message must mention "locked"',
          );

          // Verify the user record is actually locked in the DB.
          final lockedUser = await userRepo.findByUsername(username);
          expect(lockedUser, isNotNull,
              reason: 'iter $i: user must still exist');
          expect(lockedUser!.isLocked, isTrue,
              reason: 'iter $i: user.isLocked must be true after 5 failures');

          await db.close();
        }
      },
    );

    test(
      'fewer than 5 consecutive failures do not lock the account '
      '(10 random iterations with 1–4 failures)',
      () async {
        final rng = Random(81);
        const iterations = 10;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final helper = _testHelper(db);
          final userRepo = UserRepositoryImpl(helper);

          final username = _validUsername(rng);
          final correctPassword = _validPassword(rng);
          final wrongPassword = _wrongPassword(rng);

          await userRepo.insert(User(
            username: username,
            passwordHash: _fastHash(correctPassword),
            role: Role.attendant,
            isLocked: false,
            failedAttempts: 0,
            createdAt: DateTime.now().toUtc(),
          ));

          final service = AuthService(
            userRepository: userRepo,
            auditLogRepository: AuditLogRepositoryImpl(helper),
          );

          final failCount = 1 + rng.nextInt(4); // [1, 4]
          for (var attempt = 0; attempt < failCount; attempt++) {
            await service.login(
              LoginRequest(username: username, password: wrongPassword),
            );
          }

          // Account must NOT be locked — correct credentials should succeed.
          final result = await service.login(
            LoginRequest(username: username, password: correctPassword),
          );
          expect(
            result,
            isA<Success<AuthSession>>(),
            reason: 'iter $i: after $failCount failures account must not be locked',
          );

          await db.close();
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // Property 9 — Logout invalidates the session
  // Feature: parking-system, Property 9
  // -------------------------------------------------------------------------
  group('Property 9 — Logout invalidates the session', () {
    /// **Validates: Requirements 2.6**
    ///
    /// AuthService.logout() is fire-and-forget (returns void) and logs an
    /// audit event. Session token invalidation is managed at the provider
    /// layer. This test verifies:
    ///   (a) logout() completes without error for any valid userId/username.
    ///   (b) a logout audit event is written with the correct username.
    test(
      'logout() completes without error and writes a logout audit event '
      'with the correct username (20 random iterations)',
      () async {
        final rng = Random(9);
        const iterations = 20;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final helper = _testHelper(db);
          final userRepo = UserRepositoryImpl(helper);

          final username = _validUsername(rng);
          final password = _validPassword(rng);

          final insertResult = await userRepo.insert(User(
            username: username,
            passwordHash: _fastHash(password),
            role: Role.attendant,
            isLocked: false,
            failedAttempts: 0,
            createdAt: DateTime.now().toUtc(),
          ));
          final userId = (insertResult as Success<int>).value;

          final service = AuthService(
            userRepository: userRepo,
            auditLogRepository: AuditLogRepositoryImpl(helper),
          );

          // logout() must complete without throwing.
          await expectLater(
            service.logout(userId, username),
            completes,
            reason: 'iter $i: logout must complete without error',
          );

          // Verify a logout audit event was written.
          final events = await _queryAuditLog(db);
          final logoutEvents = events
              .where((e) => e.eventType == AuditEventType.logout)
              .toList();

          expect(
            logoutEvents.length,
            equals(1),
            reason: 'iter $i: exactly one logout event must be logged',
          );
          expect(
            logoutEvents.first.username,
            equals(username),
            reason: 'iter $i: logout event username must match',
          );

          await db.close();
        }
      },
    );
  });
}
