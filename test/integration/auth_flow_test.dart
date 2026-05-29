// Integration test — Auth Flow
//
// Covers the full authentication flow from provider state through repository
// persistence using an in-memory SQLite database (sqflite_common_ffi).
// No device or emulator is required.
//
// Scenarios tested:
//   1. Register a new user — user is retrievable; userCreated audit event exists.
//   2. Login with correct credentials — state transitions to Authenticated;
//      login audit event exists.
//   3. Submit wrong password 5 times — account is locked; loginFailed audit
//      events exist (one per failed attempt).
//   4. Logout — state transitions to Unauthenticated; logout audit event exists.
//
// Requirements: 1.2, 1.3, 1.4, 1.5, 1.6, 2.1, 2.2, 2.3, 2.6, 10.3, 10.4, 10.5

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:parking_system/core/result.dart';
import 'package:parking_system/database/database_helper.dart';
import 'package:parking_system/features/auth/auth_provider.dart';
import 'package:parking_system/models/audit_event.dart';
import 'package:parking_system/models/user.dart';
import 'package:parking_system/repositories/audit_log_repository.dart';
import 'package:parking_system/repositories/user_repository.dart';
import 'package:parking_system/services/auth_service.dart';

// ---------------------------------------------------------------------------
// In-memory database setup
// ---------------------------------------------------------------------------

/// Opens a fresh in-memory SQLite database with the users and audit_log tables.
///
/// Mirrors [DatabaseHelper._onCreate] for the tables required by the auth flow.
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

// ---------------------------------------------------------------------------
// Audit log query helper
// ---------------------------------------------------------------------------

/// Reads all rows from the audit_log table ordered by insertion id.
Future<List<AuditEvent>> _queryAuditLog(Database db) async {
  final rows = await db.query('audit_log', orderBy: 'id ASC');
  return rows.map(AuditEvent.fromMap).toList();
}

/// Filters [events] to those matching [type] and optionally [username].
List<AuditEvent> _eventsOfType(
  List<AuditEvent> events,
  AuditEventType type, {
  String? username,
}) {
  return events.where((e) {
    if (e.eventType != type) return false;
    if (username != null && e.username != username) return false;
    return true;
  }).toList();
}

// ---------------------------------------------------------------------------
// ProviderContainer factory
// ---------------------------------------------------------------------------

/// Creates a [ProviderContainer] with [authServiceProvider] overridden to use
/// the supplied in-memory [DatabaseHelper].
ProviderContainer _makeContainer(DatabaseHelper dbHelper) {
  final authService = AuthService(
    userRepository: UserRepositoryImpl(dbHelper),
    auditLogRepository: AuditLogRepositoryImpl(dbHelper),
  );

  return ProviderContainer(
    overrides: [
      authServiceProvider.overrideWithValue(authService),
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
  // Scenario 1 — Register a new user
  // -------------------------------------------------------------------------

  group('Scenario 1 — Register a new user', () {
    /// Requirements: 1.2, 1.6
    test(
      'register() creates a retrievable user and writes a userCreated audit event',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final userRepo = UserRepositoryImpl(dbHelper);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        const username = 'new_owner';
        const password = 'SecurePass1';
        const role = Role.owner;

        // Act: register via the provider.
        final result = await container
            .read(authProvider.notifier)
            .register(username, password, role);

        // Assert: registration succeeded.
        expect(result, isA<Success<void>>(),
            reason: 'register() must succeed for valid credentials');

        // Assert: state remains Unauthenticated (register does not log in).
        expect(container.read(authProvider), isA<Unauthenticated>(),
            reason: 'auth state must remain Unauthenticated after registration');

        // Assert: user is retrievable from the repository.
        final found = await userRepo.findByUsername(username);
        expect(found, isNotNull,
            reason: 'registered user must be findable by username');
        expect(found!.username, equals(username));
        expect(found.role, equals(role));
        expect(found.isLocked, isFalse,
            reason: 'new user must not be locked');
        expect(found.failedAttempts, equals(0),
            reason: 'new user must have zero failed attempts');

        // Assert: userCreated audit event exists.
        final events = await _queryAuditLog(db);
        final userCreatedEvents =
            _eventsOfType(events, AuditEventType.userCreated, username: username);

        expect(userCreatedEvents.length, equals(1),
            reason: 'exactly one userCreated audit event must be written');
        expect(userCreatedEvents.first.username, equals(username));
        expect(userCreatedEvents.first.timestamp.isUtc, isTrue,
            reason: 'audit event timestamp must be UTC');

        await db.close();
      },
    );

    test(
      'register() with a duplicate username returns Failure<BusinessError> '
      'and does not write a second userCreated event',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        const username = 'duplicate_user';
        const password = 'SecurePass1';

        // First registration must succeed.
        final first = await container
            .read(authProvider.notifier)
            .register(username, password, Role.attendant);
        expect(first, isA<Success<void>>(),
            reason: 'first registration must succeed');

        // Second registration with the same username must fail.
        final second = await container
            .read(authProvider.notifier)
            .register(username, 'AnotherPass2', Role.owner);
        expect(second, isA<Failure<void>>(),
            reason: 'duplicate registration must fail');
        expect((second as Failure<void>).error, isA<BusinessError>(),
            reason: 'error must be BusinessError for duplicate username');

        // Only one userCreated event must exist.
        final events = await _queryAuditLog(db);
        final userCreatedEvents =
            _eventsOfType(events, AuditEventType.userCreated, username: username);
        expect(userCreatedEvents.length, equals(1),
            reason: 'only one userCreated event must exist after duplicate attempt');

        await db.close();
      },
    );

    test(
      'register() with an invalid password returns Failure<ValidationError>',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        // Too short (< 8 chars).
        final shortResult = await container
            .read(authProvider.notifier)
            .register('valid_user', 'short', Role.attendant);
        expect(shortResult, isA<Failure<void>>());
        expect((shortResult as Failure<void>).error, isA<ValidationError>(),
            reason: 'short password must return ValidationError');

        // No audit event must be written for a failed registration.
        final events = await _queryAuditLog(db);
        expect(events, isEmpty,
            reason: 'no audit events must be written for a failed registration');

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Scenario 2 — Login with correct credentials
  // -------------------------------------------------------------------------

  group('Scenario 2 — Login with correct credentials', () {
    /// Requirements: 2.1, 10.3
    test(
      'login() with correct credentials transitions state to Authenticated '
      'and writes a login audit event',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        const username = 'login_owner';
        const password = 'SecurePass1';
        const role = Role.owner;

        // Register the user first.
        final regResult = await container
            .read(authProvider.notifier)
            .register(username, password, role);
        expect(regResult, isA<Success<void>>(),
            reason: 'registration must succeed before login test');

        // Act: login via the provider.
        final before = DateTime.now().toUtc();
        final loginResult = await container
            .read(authProvider.notifier)
            .login(username, password);
        final after = DateTime.now().toUtc();

        // Assert: login succeeded.
        expect(loginResult, isA<Success<void>>(),
            reason: 'login() must succeed with correct credentials');

        // Assert: state is now Authenticated.
        final authState = container.read(authProvider);
        expect(authState, isA<Authenticated>(),
            reason: 'auth state must be Authenticated after successful login');

        final authenticated = authState as Authenticated;
        expect(authenticated.username, equals(username));
        expect(authenticated.role, equals(role));
        expect(authenticated.userId, isNotNull,
            reason: 'Authenticated state must carry a valid userId');
        expect(authenticated.sessionStart.isUtc, isTrue,
            reason: 'sessionStart must be UTC');
        expect(
          authenticated.sessionStart
              .isAfter(before.subtract(const Duration(seconds: 1))),
          isTrue,
          reason: 'sessionStart must be at or after the test start time',
        );
        expect(
          authenticated.sessionStart
              .isBefore(after.add(const Duration(seconds: 1))),
          isTrue,
          reason: 'sessionStart must be at or before the test end time',
        );

        // Assert: login audit event exists.
        final events = await _queryAuditLog(db);
        final loginEvents =
            _eventsOfType(events, AuditEventType.login, username: username);

        expect(loginEvents.length, equals(1),
            reason: 'exactly one login audit event must be written');
        expect(loginEvents.first.username, equals(username));
        expect(loginEvents.first.timestamp.isUtc, isTrue);

        await db.close();
      },
    );

    test(
      'login() with wrong password returns Failure<BusinessError> and state '
      'remains Unauthenticated',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        const username = 'wrong_pass_user';
        const password = 'CorrectPass1';

        await container
            .read(authProvider.notifier)
            .register(username, password, Role.attendant);

        final result = await container
            .read(authProvider.notifier)
            .login(username, 'WrongPass99');

        expect(result, isA<Failure<void>>());
        expect((result as Failure<void>).error, isA<BusinessError>(),
            reason: 'wrong password must return BusinessError');
        expect(container.read(authProvider), isA<Unauthenticated>(),
            reason: 'state must remain Unauthenticated after failed login');

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Scenario 3 — Five wrong passwords lock the account
  // -------------------------------------------------------------------------

  group('Scenario 3 — Five consecutive wrong passwords lock the account', () {
    /// Requirements: 2.3, 10.4
    test(
      'submitting wrong password 5 times locks the account; '
      'exactly 5 loginFailed audit events are written; '
      'subsequent login with correct password returns locked error',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final userRepo = UserRepositoryImpl(dbHelper);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        const username = 'lockout_user';
        const correctPassword = 'CorrectPass1';
        const wrongPassword = 'WrongPass99';

        // Register the user.
        await container
            .read(authProvider.notifier)
            .register(username, correctPassword, Role.attendant);

        // Submit wrong password 5 times.
        for (var attempt = 1; attempt <= 5; attempt++) {
          final result = await container
              .read(authProvider.notifier)
              .login(username, wrongPassword);

          expect(result, isA<Failure<void>>(),
              reason: 'attempt $attempt: login with wrong password must fail');
          expect((result as Failure<void>).error, isA<BusinessError>(),
              reason: 'attempt $attempt: error must be BusinessError');

          // State must remain Unauthenticated throughout.
          expect(container.read(authProvider), isA<Unauthenticated>(),
              reason: 'attempt $attempt: state must remain Unauthenticated');
        }

        // Assert: account is locked in the database.
        final lockedUser = await userRepo.findByUsername(username);
        expect(lockedUser, isNotNull,
            reason: 'user must still exist after lockout');
        expect(lockedUser!.isLocked, isTrue,
            reason: 'user.isLocked must be true after 5 failed attempts');
        expect(lockedUser.failedAttempts, greaterThanOrEqualTo(5),
            reason: 'failedAttempts must be >= 5 after lockout');

        // Assert: exactly 5 loginFailed audit events exist for this user.
        final events = await _queryAuditLog(db);
        final loginFailedEvents =
            _eventsOfType(events, AuditEventType.loginFailed, username: username);

        expect(loginFailedEvents.length, equals(5),
            reason: 'exactly 5 loginFailed audit events must be written');

        for (final event in loginFailedEvents) {
          expect(event.username, equals(username));
          expect(event.timestamp.isUtc, isTrue,
              reason: 'loginFailed event timestamp must be UTC');
        }

        // Assert: subsequent login with correct password returns locked error.
        final afterLockResult = await container
            .read(authProvider.notifier)
            .login(username, correctPassword);

        expect(afterLockResult, isA<Failure<void>>(),
            reason: 'login after lockout must fail even with correct password');
        final lockError = (afterLockResult as Failure<void>).error;
        expect(lockError, isA<BusinessError>(),
            reason: 'locked error must be BusinessError');
        expect(
          (lockError as BusinessError).message,
          contains('locked'),
          reason: 'locked error message must mention "locked"',
        );

        // State must still be Unauthenticated.
        expect(container.read(authProvider), isA<Unauthenticated>(),
            reason: 'state must remain Unauthenticated after locked login attempt');

        await db.close();
      },
    );

    test(
      'fewer than 5 consecutive failures do not lock the account; '
      'correct credentials succeed after partial failures',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final userRepo = UserRepositoryImpl(dbHelper);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        const username = 'partial_fail_user';
        const correctPassword = 'CorrectPass1';
        const wrongPassword = 'WrongPass99';

        await container
            .read(authProvider.notifier)
            .register(username, correctPassword, Role.attendant);

        // Submit wrong password 4 times (one short of lockout).
        for (var attempt = 1; attempt <= 4; attempt++) {
          await container
              .read(authProvider.notifier)
              .login(username, wrongPassword);
        }

        // Account must NOT be locked.
        final user = await userRepo.findByUsername(username);
        expect(user!.isLocked, isFalse,
            reason: 'account must not be locked after only 4 failures');

        // Correct credentials must still succeed.
        final result = await container
            .read(authProvider.notifier)
            .login(username, correctPassword);

        expect(result, isA<Success<void>>(),
            reason: 'login must succeed after fewer than 5 failures');
        expect(container.read(authProvider), isA<Authenticated>(),
            reason: 'state must be Authenticated after successful login');

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Scenario 4 — Logout
  // -------------------------------------------------------------------------

  group('Scenario 4 — Logout', () {
    /// Requirements: 2.6, 10.5
    test(
      'logout() transitions state to Unauthenticated and writes a logout '
      'audit event with the correct username',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        const username = 'logout_user';
        const password = 'SecurePass1';

        // Register and login.
        await container
            .read(authProvider.notifier)
            .register(username, password, Role.owner);
        final loginResult = await container
            .read(authProvider.notifier)
            .login(username, password);
        expect(loginResult, isA<Success<void>>(),
            reason: 'login must succeed before logout test');
        expect(container.read(authProvider), isA<Authenticated>(),
            reason: 'state must be Authenticated before logout');

        // Act: logout via the provider.
        await container.read(authProvider.notifier).logout();

        // Assert: state is now Unauthenticated.
        expect(container.read(authProvider), isA<Unauthenticated>(),
            reason: 'auth state must be Unauthenticated after logout');

        // Assert: logout audit event exists.
        final events = await _queryAuditLog(db);
        final logoutEvents =
            _eventsOfType(events, AuditEventType.logout, username: username);

        expect(logoutEvents.length, equals(1),
            reason: 'exactly one logout audit event must be written');
        expect(logoutEvents.first.username, equals(username));
        expect(logoutEvents.first.timestamp.isUtc, isTrue,
            reason: 'logout event timestamp must be UTC');

        await db.close();
      },
    );

    test(
      'logout() when already Unauthenticated is a no-op and writes no audit event',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        // Initial state is Unauthenticated — logout should be a no-op.
        expect(container.read(authProvider), isA<Unauthenticated>());

        await container.read(authProvider.notifier).logout();

        // State must still be Unauthenticated.
        expect(container.read(authProvider), isA<Unauthenticated>(),
            reason: 'state must remain Unauthenticated after no-op logout');

        // No audit events must be written.
        final events = await _queryAuditLog(db);
        final logoutEvents = _eventsOfType(events, AuditEventType.logout);
        expect(logoutEvents, isEmpty,
            reason: 'no logout event must be written when already logged out');

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Scenario 5 — Full end-to-end auth flow
  // -------------------------------------------------------------------------

  group('Scenario 5 — Full end-to-end auth flow', () {
    /// Requirements: 1.2, 1.6, 2.1, 2.3, 2.6, 10.3, 10.4, 10.5
    test(
      'register → login → 5 wrong passwords (lock) → logout produces the '
      'correct sequence of audit events and state transitions',
      () async {
        final db = await _openInMemoryDb();
        final dbHelper = DatabaseHelper.forTesting(db);
        final userRepo = UserRepositoryImpl(dbHelper);

        final container = _makeContainer(dbHelper);
        addTearDown(container.dispose);

        const username = 'e2e_user';
        const correctPassword = 'CorrectPass1';
        const wrongPassword = 'WrongPass99';

        // ── Step 1: Register ──────────────────────────────────────────────
        final regResult = await container
            .read(authProvider.notifier)
            .register(username, correctPassword, Role.owner);
        expect(regResult, isA<Success<void>>(),
            reason: 'e2e: registration must succeed');
        expect(container.read(authProvider), isA<Unauthenticated>(),
            reason: 'e2e: state must be Unauthenticated after registration');

        // User is retrievable.
        final registeredUser = await userRepo.findByUsername(username);
        expect(registeredUser, isNotNull,
            reason: 'e2e: registered user must be findable');

        // userCreated event exists.
        var events = await _queryAuditLog(db);
        expect(
          _eventsOfType(events, AuditEventType.userCreated, username: username)
              .length,
          equals(1),
          reason: 'e2e: one userCreated event must exist after registration',
        );

        // ── Step 2: Login with correct credentials ────────────────────────
        final loginResult = await container
            .read(authProvider.notifier)
            .login(username, correctPassword);
        expect(loginResult, isA<Success<void>>(),
            reason: 'e2e: login must succeed');
        expect(container.read(authProvider), isA<Authenticated>(),
            reason: 'e2e: state must be Authenticated after login');

        // login event exists.
        events = await _queryAuditLog(db);
        expect(
          _eventsOfType(events, AuditEventType.login, username: username)
              .length,
          equals(1),
          reason: 'e2e: one login event must exist after successful login',
        );

        // ── Step 3: Logout ────────────────────────────────────────────────
        await container.read(authProvider.notifier).logout();
        expect(container.read(authProvider), isA<Unauthenticated>(),
            reason: 'e2e: state must be Unauthenticated after logout');

        // logout event exists.
        events = await _queryAuditLog(db);
        expect(
          _eventsOfType(events, AuditEventType.logout, username: username)
              .length,
          equals(1),
          reason: 'e2e: one logout event must exist after logout',
        );

        // ── Step 4: Login again, then submit 5 wrong passwords ────────────
        final reloginResult = await container
            .read(authProvider.notifier)
            .login(username, correctPassword);
        expect(reloginResult, isA<Success<void>>(),
            reason: 'e2e: re-login must succeed');

        // Logout first so we can test lockout from Unauthenticated state.
        await container.read(authProvider.notifier).logout();

        for (var attempt = 1; attempt <= 5; attempt++) {
          await container
              .read(authProvider.notifier)
              .login(username, wrongPassword);
        }

        // Account is locked.
        final lockedUser = await userRepo.findByUsername(username);
        expect(lockedUser!.isLocked, isTrue,
            reason: 'e2e: account must be locked after 5 wrong passwords');

        // 5 loginFailed events exist (from the lockout sequence).
        events = await _queryAuditLog(db);
        final loginFailedEvents =
            _eventsOfType(events, AuditEventType.loginFailed, username: username);
        expect(loginFailedEvents.length, equals(5),
            reason: 'e2e: exactly 5 loginFailed events must exist');

        // State is still Unauthenticated.
        expect(container.read(authProvider), isA<Unauthenticated>(),
            reason: 'e2e: state must be Unauthenticated after lockout');

        // ── Step 5: Verify full audit trail ──────────────────────────────
        events = await _queryAuditLog(db);
        final allEventTypes = events.map((e) => e.eventType).toList();

        // Must contain: userCreated, login (×2), logout (×2), loginFailed (×5).
        expect(
          allEventTypes.where((t) => t == AuditEventType.userCreated).length,
          equals(1),
          reason: 'e2e: exactly 1 userCreated event in full trail',
        );
        expect(
          allEventTypes.where((t) => t == AuditEventType.login).length,
          equals(2),
          reason: 'e2e: exactly 2 login events in full trail',
        );
        expect(
          allEventTypes.where((t) => t == AuditEventType.logout).length,
          equals(2),
          reason: 'e2e: exactly 2 logout events in full trail',
        );
        expect(
          allEventTypes.where((t) => t == AuditEventType.loginFailed).length,
          equals(5),
          reason: 'e2e: exactly 5 loginFailed events in full trail',
        );

        await db.close();
      },
    );
  });
}
