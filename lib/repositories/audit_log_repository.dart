import 'package:flutter/foundation.dart' show debugPrint;

import '../database/database_helper.dart';
import '../models/audit_event.dart';

/// Abstract interface for writing audit log entries.
///
/// The [log] method is fire-and-forget: it returns [Future<void>] and must
/// never throw or propagate errors to the caller.
abstract class AuditLogRepository {
  /// Persists [event] to the audit log.
  ///
  /// Implementations must swallow all errors internally — callers are not
  /// expected to handle failures from audit logging.
  Future<void> log(AuditEvent event);
}

/// SQLite-backed implementation of [AuditLogRepository].
///
/// All database access is performed through [DatabaseHelper]; sqflite is
/// never called directly from outside this class.
class AuditLogRepositoryImpl implements AuditLogRepository {
  final DatabaseHelper _dbHelper;

  const AuditLogRepositoryImpl(this._dbHelper);

  static const String _table = 'audit_log';

  /// Inserts [event] into the [_table] using a parameterized query via
  /// [AuditEvent.toMap].
  ///
  /// If the INSERT fails for any reason (e.g. database not available, schema
  /// mismatch), the error is printed via [debugPrint] and the method returns
  /// normally. Audit log failures must never surface to the caller.
  @override
  Future<void> log(AuditEvent event) async {
    try {
      final db = await _dbHelper.database;
      await db.insert(_table, event.toMap());
    } catch (e) {
      debugPrint('AuditLogRepository: failed to log event: $e');
    }
  }
}
