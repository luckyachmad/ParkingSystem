import '../core/result.dart';
import '../database/database_helper.dart';
import '../models/user.dart';

/// Abstract interface for all user-related database operations.
///
/// All write operations return a [Result] so callers can handle
/// [DatabaseError] without catching exceptions.
abstract class UserRepository {
  /// Returns the [User] with the given [username], or `null` if not found.
  Future<User?> findByUsername(String username);

  /// Inserts [user] into the database and returns the new row id on success,
  /// or a [Failure<DatabaseError>] if the write fails.
  Future<Result<int>> insert(User user);

  /// Updates the `is_locked` flag for the user identified by [userId].
  /// Returns [Failure<DatabaseError>] if the write fails.
  Future<Result<void>> updateLockStatus(int userId, bool locked);

  /// Updates the `failed_attempts` counter for the user identified by [userId].
  /// Returns [Failure<DatabaseError>] if the write fails.
  Future<Result<void>> updateFailedAttempts(int userId, int count);

  /// Returns the number of currently active (logged-in) sessions.
  ///
  /// Stub — always returns 0 until session tracking is implemented in Task 6.
  Future<int> countActiveSessions();
}

/// SQLite-backed implementation of [UserRepository].
///
/// All database access is performed through [DatabaseHelper]; sqflite is
/// never called directly from outside this class.
class UserRepositoryImpl implements UserRepository {
  final DatabaseHelper _dbHelper;

  const UserRepositoryImpl(this._dbHelper);

  static const String _table = 'users';

  // ---------------------------------------------------------------------------
  // Read operations
  // ---------------------------------------------------------------------------

  /// Queries the `users` table for a row matching [username].
  ///
  /// Returns `null` when no matching row exists.
  @override
  Future<User?> findByUsername(String username) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      _table,
      where: 'username = ?',
      whereArgs: [username],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return User.fromMap(rows.first);
  }

  // ---------------------------------------------------------------------------
  // Write operations — all wrapped in try/catch
  // ---------------------------------------------------------------------------

  /// Inserts [user] using a parameterized query via [User.toMap].
  ///
  /// Returns [Success] with the new row id, or [Failure<DatabaseError>] if
  /// the insert throws (e.g. UNIQUE constraint violation on username).
  @override
  Future<Result<int>> insert(User user) async {
    try {
      final db = await _dbHelper.database;
      final id = await db.insert(_table, user.toMap());
      return Success(id);
    } catch (e) {
      return Failure(
        DatabaseError(
          operation: 'insert user',
          message: e.toString(),
        ),
      );
    }
  }

  /// Updates the `is_locked` column for the row identified by [userId].
  ///
  /// Stores `1` for `true` and `0` for `false` to match the SQLite schema.
  @override
  Future<Result<void>> updateLockStatus(int userId, bool locked) async {
    try {
      final db = await _dbHelper.database;
      await db.update(
        _table,
        {'is_locked': locked ? 1 : 0},
        where: 'id = ?',
        whereArgs: [userId],
      );
      return const Success(null);
    } catch (e) {
      return Failure(
        DatabaseError(
          operation: 'updateLockStatus',
          message: e.toString(),
        ),
      );
    }
  }

  /// Updates the `failed_attempts` column for the row identified by [userId].
  @override
  Future<Result<void>> updateFailedAttempts(int userId, int count) async {
    try {
      final db = await _dbHelper.database;
      await db.update(
        _table,
        {'failed_attempts': count},
        where: 'id = ?',
        whereArgs: [userId],
      );
      return const Success(null);
    } catch (e) {
      return Failure(
        DatabaseError(
          operation: 'updateFailedAttempts',
          message: e.toString(),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Session tracking (stub — implemented in Task 6)
  // ---------------------------------------------------------------------------

  /// Returns 0 until active-session tracking is added in Task 6.
  @override
  Future<int> countActiveSessions() async => 0;
}
