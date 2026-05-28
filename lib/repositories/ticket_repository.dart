import 'package:sqflite/sqflite.dart';

import '../core/result.dart';
import '../database/database_helper.dart';
import '../models/ticket.dart';

/// Abstract interface for all ticket database operations.
///
/// Read operations return plain values; write operations return [Result] so
/// callers can handle [BusinessError] and [DatabaseError] without catching
/// exceptions.
abstract class TicketRepository {
  /// Inserts [ticket] and returns the new row id on success.
  ///
  /// Returns [Failure<BusinessError>] when an open ticket already exists for
  /// the same plate number. Returns [Failure<DatabaseError>] on unexpected
  /// database errors.
  Future<Result<int>> insert(Ticket ticket);

  /// Returns the open ticket for [plateNumber], or `null` if none exists.
  ///
  /// Uses the `idx_tickets_plate_open` index for efficient lookup.
  Future<Ticket?> findOpenByPlate(String plateNumber);

  /// Returns all currently open tickets (i.e. vehicles still parked).
  Future<List<Ticket>> findAllOpen();

  /// Closes the ticket identified by [ticketId] by recording [exitTime] and
  /// [closedBy].
  ///
  /// Returns [Failure<DatabaseError>] on unexpected database errors.
  Future<Result<void>> closeTicket(
    int ticketId,
    DateTime exitTime,
    String closedBy,
  );

  /// Returns the count of currently open tickets.
  Future<int> countOpen();
}

/// SQLite-backed implementation of [TicketRepository].
///
/// All database access is performed through [DatabaseHelper]; sqflite is
/// never called directly from outside this class.
class TicketRepositoryImpl implements TicketRepository {
  final DatabaseHelper _dbHelper;

  const TicketRepositoryImpl(this._dbHelper);

  static const String _table = 'tickets';

  // ---------------------------------------------------------------------------
  // Write operations
  // ---------------------------------------------------------------------------

  /// Checks for a duplicate open ticket, then inserts [ticket].
  ///
  /// If [findOpenByPlate] returns a non-null result, the insert is rejected
  /// with a [BusinessError] to prevent double-parking the same plate.
  @override
  Future<Result<int>> insert(Ticket ticket) async {
    // Guard: reject if an open ticket already exists for this plate.
    final existing = await findOpenByPlate(ticket.plateNumber);
    if (existing != null) {
      return Failure(
        BusinessError(
          'A parking session is already active for plate ${ticket.plateNumber}.',
        ),
      );
    }

    try {
      final db = await _dbHelper.database;
      final id = await db.insert(_table, ticket.toMap());
      return Success(id);
    } catch (e) {
      return Failure(
        DatabaseError(operation: 'insert ticket', message: e.toString()),
      );
    }
  }

  /// Closes the ticket by writing [exitTime] (as epoch ms) and [closedBy].
  @override
  Future<Result<void>> closeTicket(
    int ticketId,
    DateTime exitTime,
    String closedBy,
  ) async {
    try {
      final db = await _dbHelper.database;
      await db.update(
        _table,
        {
          'exit_time': exitTime.millisecondsSinceEpoch,
          'closed_by': closedBy,
        },
        where: 'id = ?',
        whereArgs: [ticketId],
      );
      return const Success(null);
    } catch (e) {
      return Failure(
        DatabaseError(operation: 'closeTicket', message: e.toString()),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Read operations
  // ---------------------------------------------------------------------------

  /// Queries for an open ticket matching [plateNumber].
  ///
  /// The `WHERE plate_number = ? AND exit_time IS NULL` predicate is served
  /// by the `idx_tickets_plate_open` composite index.
  @override
  Future<Ticket?> findOpenByPlate(String plateNumber) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      _table,
      where: 'plate_number = ? AND exit_time IS NULL',
      whereArgs: [plateNumber],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Ticket.fromMap(rows.first);
  }

  /// Returns all rows where `exit_time IS NULL`, i.e. vehicles still parked.
  @override
  Future<List<Ticket>> findAllOpen() async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      _table,
      where: 'exit_time IS NULL',
    );
    return rows.map(Ticket.fromMap).toList();
  }

  /// Returns the number of open tickets via a `COUNT(*)` aggregate query.
  @override
  Future<int> countOpen() async {
    final db = await _dbHelper.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) FROM $_table WHERE exit_time IS NULL',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
