import '../core/result.dart';
import '../database/database_helper.dart';
import '../models/pricing_rule.dart';

/// Abstract interface for all pricing-rule database operations.
///
/// Read operations return plain values; write operations return [Result] so
/// callers can handle [BusinessError] and [DatabaseError] without catching
/// exceptions.
abstract class PricingRepository {
  /// Inserts [rule] and returns the new row id on success.
  ///
  /// Returns [Failure<BusinessError>] when the name already exists among
  /// active rules, or when [PricingRule.rateAmount] is not positive.
  /// Returns [Failure<DatabaseError>] on unexpected database errors.
  Future<Result<int>> insert(PricingRule rule);

  /// Returns the single active default rule, or `null` if none is set.
  Future<PricingRule?> findDefault();

  /// Returns all active pricing rules.
  Future<List<PricingRule>> findAllActive();

  /// Updates [rule] in place.
  ///
  /// Returns [Failure<BusinessError>] when the new name conflicts with another
  /// active rule. Returns [Failure<DatabaseError>] on unexpected database errors.
  Future<Result<void>> update(PricingRule rule);

  /// Sets [ruleId] as the sole default rule.
  ///
  /// Clears `is_default` on all active rules, then sets it on [ruleId], both
  /// inside a single SQLite transaction.
  /// Returns [Failure<DatabaseError>] on unexpected database errors.
  Future<Result<void>> setDefault(int ruleId);

  /// Soft-deletes the rule identified by [ruleId] by setting `is_active = 0`.
  ///
  /// If the rule was the default, its `is_default` flag is also cleared.
  /// Returns [Failure<DatabaseError>] on unexpected database errors.
  Future<Result<void>> deactivate(int ruleId);
}

/// SQLite-backed implementation of [PricingRepository].
///
/// All database access is performed through [DatabaseHelper]; sqflite is
/// never called directly from outside this class.
class PricingRepositoryImpl implements PricingRepository {
  final DatabaseHelper _dbHelper;

  const PricingRepositoryImpl(this._dbHelper);

  static const String _table = 'pricing_rules';

  // ---------------------------------------------------------------------------
  // Write operations
  // ---------------------------------------------------------------------------

  /// Validates [rule] and inserts it into the database.
  ///
  /// Validation order:
  /// 1. [PricingRule.rateAmount] must be > 0 (stored as cents, so
  ///    `rateAmount * 100 > 0`).
  /// 2. No active rule may share the same [PricingRule.name].
  @override
  Future<Result<int>> insert(PricingRule rule) async {
    // Validate rate amount.
    final rateAmountCents = (rule.rateAmount * 100).round();
    if (rateAmountCents <= 0) {
      return Failure(
        const BusinessError('Rate amount must be greater than zero.'),
      );
    }

    try {
      final db = await _dbHelper.database;

      // Check name uniqueness among active rules.
      final duplicates = await db.query(
        _table,
        columns: ['id'],
        where: 'name = ? AND is_active = 1',
        whereArgs: [rule.name],
        limit: 1,
      );
      if (duplicates.isNotEmpty) {
        return Failure(
          const BusinessError(
            'A pricing rule with this name already exists.',
          ),
        );
      }

      final id = await db.insert(_table, rule.toMap());
      return Success(id);
    } catch (e) {
      return Failure(
        DatabaseError(operation: 'insert pricing rule', message: e.toString()),
      );
    }
  }

  /// Updates [rule] using a parameterized query.
  ///
  /// Checks that no *other* active rule shares the same name before writing.
  @override
  Future<Result<void>> update(PricingRule rule) async {
    try {
      final db = await _dbHelper.database;

      // Check name uniqueness among active rules, excluding this rule's own id.
      final duplicates = await db.query(
        _table,
        columns: ['id'],
        where: 'name = ? AND is_active = 1 AND id != ?',
        whereArgs: [rule.name, rule.id],
        limit: 1,
      );
      if (duplicates.isNotEmpty) {
        return Failure(
          const BusinessError(
            'A pricing rule with this name already exists.',
          ),
        );
      }

      await db.update(
        _table,
        rule.toMap(),
        where: 'id = ?',
        whereArgs: [rule.id],
      );
      return const Success(null);
    } catch (e) {
      return Failure(
        DatabaseError(operation: 'update pricing rule', message: e.toString()),
      );
    }
  }

  /// Atomically clears `is_default` on all active rules, then sets it on
  /// [ruleId], using a sqflite `transaction()`.
  @override
  Future<Result<void>> setDefault(int ruleId) async {
    try {
      final db = await _dbHelper.database;

      await db.transaction((txn) async {
        // Clear default flag on all active rules.
        await txn.update(
          _table,
          {'is_default': 0},
          where: 'is_active = 1',
        );
        // Set default flag on the target rule.
        await txn.update(
          _table,
          {'is_default': 1},
          where: 'id = ?',
          whereArgs: [ruleId],
        );
      });

      return const Success(null);
    } catch (e) {
      return Failure(
        DatabaseError(operation: 'setDefault pricing rule', message: e.toString()),
      );
    }
  }

  /// Sets `is_active = 0` for [ruleId].
  ///
  /// Also clears `is_default` if the rule was the default, so no inactive
  /// rule can remain marked as default.
  @override
  Future<Result<void>> deactivate(int ruleId) async {
    try {
      final db = await _dbHelper.database;

      await db.update(
        _table,
        {'is_active': 0, 'is_default': 0},
        where: 'id = ?',
        whereArgs: [ruleId],
      );

      return const Success(null);
    } catch (e) {
      return Failure(
        DatabaseError(
          operation: 'deactivate pricing rule',
          message: e.toString(),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Read operations
  // ---------------------------------------------------------------------------

  /// Queries for the single active rule where `is_default = 1`.
  ///
  /// Returns `null` when no default has been set.
  @override
  Future<PricingRule?> findDefault() async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      _table,
      where: 'is_default = 1 AND is_active = 1',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PricingRule.fromMap(rows.first);
  }

  /// Returns all rows where `is_active = 1`, ordered by name for stable display.
  @override
  Future<List<PricingRule>> findAllActive() async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      _table,
      where: 'is_active = 1',
      orderBy: 'name ASC',
    );
    return rows.map(PricingRule.fromMap).toList();
  }
}
