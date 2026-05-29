import 'package:bcrypt/bcrypt.dart';

import '../core/result.dart';
import '../models/audit_event.dart';
import '../models/user.dart';
import '../repositories/audit_log_repository.dart';
import '../repositories/user_repository.dart';

// ---------------------------------------------------------------------------
// Request / response types
// ---------------------------------------------------------------------------

class RegisterRequest {
  final String username;
  final String password;
  final Role role;

  const RegisterRequest({
    required this.username,
    required this.password,
    required this.role,
  });
}

class LoginRequest {
  final String username;
  final String password;

  const LoginRequest({
    required this.username,
    required this.password,
  });
}

class AuthSession {
  final int userId;
  final String username;
  final Role role;
  final DateTime sessionStart;

  const AuthSession({
    required this.userId,
    required this.username,
    required this.role,
    required this.sessionStart,
  });
}

// ---------------------------------------------------------------------------
// AuthService
// ---------------------------------------------------------------------------

/// Handles user registration, login, logout, and account management.
///
/// All methods return [Result<T>] — exceptions are never thrown across layer
/// boundaries. Audit log failures are swallowed internally by
/// [AuditLogRepository] and never surface to callers.
class AuthService {
  final UserRepository _userRepository;
  final AuditLogRepository _auditLogRepository;

  // Regex: 3–50 chars, alphanumeric + underscore only.
  static final RegExp _usernameRegex = RegExp(r'^[a-zA-Z0-9_]{3,50}$');

  AuthService({
    required UserRepository userRepository,
    required AuditLogRepository auditLogRepository,
  })  : _userRepository = userRepository,  // ignore: prefer_initializing_formals
        _auditLogRepository = auditLogRepository; // ignore: prefer_initializing_formals

  // ---------------------------------------------------------------------------
  // register
  // ---------------------------------------------------------------------------

  /// Registers a new user.
  ///
  /// Validates [request.username] (3–50 alphanumeric + underscore chars) and
  /// [request.password] (8–128 chars), checks username uniqueness, hashes the
  /// password with bcrypt, inserts the user, and logs a [AuditEventType.userCreated]
  /// event.
  ///
  /// Returns [Success<User>] with the persisted user (including its new id) on
  /// success, or a typed [Failure] on any validation, business, or database error.
  Future<Result<User>> register(RegisterRequest request) async {
    // 1. Validate username.
    if (!_usernameRegex.hasMatch(request.username)) {
      return const Failure(
        ValidationError(
          field: 'username',
          message:
              'Username must be 3–50 characters and contain only letters, digits, or underscores.',
        ),
      );
    }

    // 2. Validate password length.
    if (request.password.length < 8 || request.password.length > 128) {
      return const Failure(
        ValidationError(
          field: 'password',
          message: 'Password must be between 8 and 128 characters.',
        ),
      );
    }

    // 3. Check username uniqueness.
    final existing = await _userRepository.findByUsername(request.username);
    if (existing != null) {
      return const Failure(BusinessError('Username already taken'));
    }

    // 4. Hash password.
    final passwordHash = BCrypt.hashpw(request.password, BCrypt.gensalt());

    // 5. Build user object.
    final user = User(
      username: request.username,
      passwordHash: passwordHash,
      role: request.role,
      isLocked: false,
      failedAttempts: 0,
      createdAt: DateTime.now().toUtc(),
    );

    // 6. Insert user.
    final insertResult = await _userRepository.insert(user);
    if (insertResult is Failure<int>) {
      return Failure<User>(insertResult.error);
    }
    final insertedId = (insertResult as Success<int>).value;

    // 7. Log audit event (fire-and-forget — never throws).
    await _auditLogRepository.log(
      AuditEvent(
        eventType: AuditEventType.userCreated,
        username: request.username,
        timestamp: DateTime.now().toUtc(),
      ),
    );

    // 8. Return the persisted user with its new id.
    return Success(user.copyWith(id: insertedId));
  }

  // ---------------------------------------------------------------------------
  // login
  // ---------------------------------------------------------------------------

  /// Authenticates a user and returns an [AuthSession] on success.
  ///
  /// Validates input lengths, fetches the user, checks the lock status,
  /// verifies the password hash, and manages the [failedAttempts] counter
  /// (locking the account after 5 consecutive failures).
  ///
  /// Returns [Success<AuthSession>] on success, or a typed [Failure] on any
  /// validation, business, or database error. Error messages never disclose
  /// which specific field was incorrect.
  Future<Result<AuthSession>> login(LoginRequest request) async {
    // 1. Validate username length.
    if (request.username.isEmpty || request.username.length > 50) {
      return const Failure(
        ValidationError(
          field: 'username',
          message: 'Username must be between 1 and 50 characters.',
        ),
      );
    }

    // 2. Validate password length.
    if (request.password.length < 8 || request.password.length > 100) {
      return const Failure(
        ValidationError(
          field: 'password',
          message: 'Password must be between 8 and 100 characters.',
        ),
      );
    }

    // 3. Fetch user — generic error if not found (no field disclosure).
    final user = await _userRepository.findByUsername(request.username);
    if (user == null) {
      await _auditLogRepository.log(
        AuditEvent(
          eventType: AuditEventType.loginFailed,
          username: request.username,
          timestamp: DateTime.now().toUtc(),
          details: 'User not found',
        ),
      );
      return const Failure(BusinessError('Invalid credentials'));
    }

    // 4. Check lock status.
    if (user.isLocked) {
      return const Failure(
        BusinessError('Account is locked. Contact an administrator.'),
      );
    }

    // 5. Verify password hash.
    final passwordMatches = BCrypt.checkpw(request.password, user.passwordHash);
    if (!passwordMatches) {
      final newCount = user.failedAttempts + 1;

      // Update failed attempts counter.
      await _userRepository.updateFailedAttempts(user.id!, newCount);

      // Lock account if threshold reached.
      if (newCount >= 5) {
        await _userRepository.updateLockStatus(user.id!, true);
      }

      await _auditLogRepository.log(
        AuditEvent(
          eventType: AuditEventType.loginFailed,
          username: request.username,
          timestamp: DateTime.now().toUtc(),
          details: 'Invalid password (attempt $newCount)',
        ),
      );

      return const Failure(BusinessError('Invalid credentials'));
    }

    // 6. Successful login — reset failed attempts counter.
    await _userRepository.updateFailedAttempts(user.id!, 0);

    await _auditLogRepository.log(
      AuditEvent(
        eventType: AuditEventType.login,
        username: request.username,
        timestamp: DateTime.now().toUtc(),
      ),
    );

    return Success(
      AuthSession(
        userId: user.id!,
        username: user.username,
        role: user.role,
        sessionStart: DateTime.now().toUtc(),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // logout
  // ---------------------------------------------------------------------------

  /// Logs out the user identified by [userId] / [username].
  ///
  /// Logs a [AuditEventType.logout] event. Returns void — no [Result] needed
  /// because logout is always considered successful from the caller's perspective.
  Future<void> logout(int userId, String username) async {
    await _auditLogRepository.log(
      AuditEvent(
        eventType: AuditEventType.logout,
        username: username,
        timestamp: DateTime.now().toUtc(),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // unlockAccount
  // ---------------------------------------------------------------------------

  /// Unlocks the account identified by [userId] and resets its failed-attempts
  /// counter to zero.
  ///
  /// Returns [Success<void>] on success, or a [Failure<DatabaseError>] if
  /// either repository call fails.
  Future<Result<void>> unlockAccount(int userId) async {
    final lockResult = await _userRepository.updateLockStatus(userId, false);
    if (lockResult is Failure<void>) {
      return lockResult;
    }

    final attemptsResult =
        await _userRepository.updateFailedAttempts(userId, 0);
    if (attemptsResult is Failure<void>) {
      return attemptsResult;
    }

    return const Success(null);
  }
}
