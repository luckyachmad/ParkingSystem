import 'package:sqflite/sqflite.dart';

import '../core/result.dart';
import '../database/database_helper.dart';
import '../models/parking_transaction.dart';
import '../models/transaction_filter.dart';

/// Abstract interface for all transaction database operations.
///
/// Transactions are immutable once written — no UPDATE or DELETE paths exist.
/// Read operations return plain values; write operations return [Result] so
/// callers can handle [DatabaseError] without catching exceptions.
abstract class TransactionRepository {
  /// Inserts [transaction] and returns the new row id on success.
  ///
  /// Returns [Failure<DatabaseError>] on unexpected database errors.
  Future<Result<int>> insert(ParkingTransaction transaction);

  /// Returns the [ParkingTransaction] with the given [id], or `null` if not
  /// found.
  Future<ParkingTransaction?> findById(int id);

  /// Returns all transactions matching [filter].
  ///
  /// All filter fields are optional — omitting a field applies no constraint
  /// for that dimension. Results are ordered by `exit_time DESC NULLS LAST`.
  ///
  /// Returns [Failure<DatabaseError>] on unexpected database errors.
  Future<Result<List<ParkingTransaction>>> query(TransactionFilter filter);

  /// Returns the sum of all `fee_cents` for transactions whose `exit_time` is
  /// on or after [since].
  ///
  /// Returns 0 when no matching rows exist.
  /// Returns [Failure<DatabaseError>] on unexpected database errors.
  Future<Result<int>> sumFeesSince(DateTime since);
}

/// SQLite-backed implementation of [TransactionRepository].
///
/// All database access is performed through [DatabaseHelper]; sqflite is
/// never called directly from outside this class.
class TransactionRepositoryImpl implements TransactionRepository {
  final DatabaseHelper _dbHelper;

  const TransactionRepositoryImpl(this._dbHelper);

  static const String _table = 'transactions';

  // ---------------------------------------------------------------------------
  // Write operations
  // ---------------------------------------------------------------------------

  /// Inserts [transaction] using a parameterized query via
  /// [ParkingTransaction.toMap].
  ///
  /// Returns [Success] with the new row id, or [Failure<DatabaseError>] if
  /// the insert throws (e.g. a REFERENCES constraint violation on ticket_id).
  @override
  Future<Result<int>> insert(ParkingTransaction transaction) async {
    try {
      final db = await _dbHelper.database;
      final id = await db.insert(_table, transaction.toMap());
      return Success(id);
    } catch (e) {
      return Failure(
        DatabaseError(
          operation: 'insert transaction',
          message: e.toString(),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Read operations
  // ---------------------------------------------------------------------------

  /// Queries the `transactions` table for the row with the given primary key.
  ///
  /// Returns `null` when no matching row exists.
  @override
  Future<ParkingTransaction?> findById(int id) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ParkingTransaction.fromMap(rows.first);
  }

  /// Builds a parameterized WHERE clause from the optional fields in [filter]
  /// and returns matching transactions ordered by `exit_time DESC NULLS LAST`.
  ///
  /// Filter semantics:
  /// - [TransactionFilter.fromDate] — `exit_time >= fromDate` (epoch ms)
  /// - [TransactionFilter.toDate]   — `exit_time <= toDate` (epoch ms)
  /// - [TransactionFilter.plateSubstring] — `plate_number LIKE %substring%`
  /// - [TransactionFilter.paymentStatus] — exact match on `payment_status`
  ///
  /// Returns [Failure<DatabaseError>] on unexpected database errors.
  @override
  Future<Result<List<ParkingTransaction>>> query(
    TransactionFilter filter,
  ) async {
    try {
      final db = await _dbHelper.database;

      final whereClauses = <String>[];
      final whereArgs = <dynamic>[];

      if (filter.fromDate != null) {
        whereClauses.add('exit_time >= ?');
        whereArgs.add(filter.fromDate!.millisecondsSinceEpoch);
      }

      if (filter.toDate != null) {
        whereClauses.add('exit_time <= ?');
        whereArgs.add(filter.toDate!.millisecondsSinceEpoch);
      }

      if (filter.plateSubstring != null &&
          filter.plateSubstring!.isNotEmpty) {
        whereClauses.add('plate_number LIKE ?');
        whereArgs.add('%${filter.plateSubstring!}%');
      }

      if (filter.paymentStatus != null) {
        whereClauses.add('payment_status = ?');
        whereArgs.add(filter.paymentStatus!.name);
      }

      final rows = await db.query(
        _table,
        where: whereClauses.isEmpty ? null : whereClauses.join(' AND '),
        whereArgs: whereArgs.isEmpty ? null : whereArgs,
        orderBy: 'exit_time DESC NULLS LAST',
      );

      return Success(rows.map(ParkingTransaction.fromMap).toList());
    } catch (e) {
      return Failure(
        DatabaseError(
          operation: 'query transactions',
          message: e.toString(),
        ),
      );
    }
  }

  /// Executes `SELECT SUM(fee_cents) FROM transactions WHERE exit_time >= ?`
  /// with [since] converted to epoch milliseconds.
  ///
  /// Returns 0 when no rows match (i.e. [Sqflite.firstIntValue] returns null).
  /// Returns [Failure<DatabaseError>] on unexpected database errors.
  @override
  Future<Result<int>> sumFeesSince(DateTime since) async {
    try {
      final db = await _dbHelper.database;
      final result = await db.rawQuery(
        'SELECT SUM(fee_cents) FROM $_table WHERE exit_time >= ?',
        [since.millisecondsSinceEpoch],
      );
      final sum = Sqflite.firstIntValue(result) ?? 0;
      return Success(sum);
    } catch (e) {
      return Failure(
        DatabaseError(
          operation: 'sumFeesSince',
          message: e.toString(),
        ),
      );
    }
  }
}
