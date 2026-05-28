// Feature: parking-system, Property 17, 18, 19, 20
//
// Property 17: Deactivated pricing rule is excluded from active rule list
//   Validates: Requirements 6.5
//
// Property 18: Exactly one pricing rule is the default at all times
//   Validates: Requirements 6.7
//
// Property 19: Pricing rule creation and retrieval round-trip
//   Validates: Requirements 6.1
//
// Property 20: Invalid pricing rule fields are rejected
//   Validates: Requirements 6.2, 6.3
//
// Uses in-memory SQLite via sqflite_common_ffi. No device or emulator needed.
// Property tests are implemented manually using dart:math Random with 10–50+
// iterations (fast_check is a JavaScript library with no Dart pub package).

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:parking_system/core/result.dart';
import 'package:parking_system/database/database_helper.dart';
import 'package:parking_system/models/pricing_rule.dart';
import 'package:parking_system/repositories/pricing_repository.dart';

// ---------------------------------------------------------------------------
// In-memory DatabaseHelper for tests
// ---------------------------------------------------------------------------

/// Creates a [DatabaseHelper] pre-loaded with an in-memory [Database].
///
/// Uses the [DatabaseHelper.forTesting] constructor added for test support.
DatabaseHelper _testHelper(Database db) => DatabaseHelper.forTesting(db);

// ---------------------------------------------------------------------------
// DDL helper — mirrors DatabaseHelper._onCreate (pricing_rules table only)
// ---------------------------------------------------------------------------

Future<Database> _openInMemoryDb() async {
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
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
      },
    ),
  );
}

// ---------------------------------------------------------------------------
// Random valid PricingRule generator
// ---------------------------------------------------------------------------

PricingRule _randomValidRule(Random rng, String name) {
  final rateType = rng.nextBool() ? RateType.hourly : RateType.flat;
  final rateAmountCents = rng.nextInt(99999) + 1; // 1–99999 cents
  final gracePeriod = rng.nextInt(61); // 0–60 minutes
  final hasCap = rng.nextBool();
  final capCents = hasCap ? rng.nextInt(999999) + 1 : null;
  return PricingRule(
    name: name,
    rateType: rateType,
    rateAmount: rateAmountCents / 100.0,
    gracePeriodMinutes: gracePeriod,
    dailyMaxCap: capCents != null ? capCents / 100.0 : null,
    isActive: true,
    isDefault: false,
  );
}

// ---------------------------------------------------------------------------
// Field-by-field equality helper for PricingRule
// ---------------------------------------------------------------------------

void _assertRulesEqual(
  PricingRule original,
  PricingRule retrieved, {
  required String context,
}) {
  expect(
    retrieved.name,
    equals(original.name),
    reason: '$context: name mismatch',
  );
  expect(
    retrieved.rateType,
    equals(original.rateType),
    reason: '$context: rateType mismatch',
  );
  expect(
    (retrieved.rateAmount - original.rateAmount).abs(),
    lessThan(0.005),
    reason: '$context: rateAmount mismatch '
        '(original=${original.rateAmount}, retrieved=${retrieved.rateAmount})',
  );
  expect(
    retrieved.gracePeriodMinutes,
    equals(original.gracePeriodMinutes),
    reason: '$context: gracePeriodMinutes mismatch',
  );
  if (original.dailyMaxCap == null) {
    expect(
      retrieved.dailyMaxCap,
      isNull,
      reason: '$context: dailyMaxCap should be null',
    );
  } else {
    expect(
      retrieved.dailyMaxCap,
      isNotNull,
      reason: '$context: dailyMaxCap should not be null',
    );
    expect(
      (retrieved.dailyMaxCap! - original.dailyMaxCap!).abs(),
      lessThan(0.005),
      reason: '$context: dailyMaxCap mismatch '
          '(original=${original.dailyMaxCap}, retrieved=${retrieved.dailyMaxCap})',
    );
  }
  expect(
    retrieved.isActive,
    equals(original.isActive),
    reason: '$context: isActive mismatch',
  );
  expect(
    retrieved.isDefault,
    equals(original.isDefault),
    reason: '$context: isDefault mismatch',
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
  // Property 17 — Deactivated rule is excluded from active list
  // -------------------------------------------------------------------------

  group('Property 17 — Deactivated pricing rule is excluded from active list',
      () {
    /// **Validates: Requirements 6.5**
    test(
      'deactivated rule does not appear in findAllActive() '
      '(10 random iterations with 3+ rules each)',
      () async {
        final rng = Random(17);
        const iterations = 10;

        for (var iter = 0; iter < iterations; iter++) {
          final db = await _openInMemoryDb();
          final repo =
              PricingRepositoryImpl(_testHelper(db));

          // Insert 3–6 rules with unique names.
          final ruleCount = 3 + rng.nextInt(4);
          final insertedIds = <int>[];
          final insertedNames = <String>[];

          for (var i = 0; i < ruleCount; i++) {
            final name = 'Rule_P17_iter${iter}_$i';
            final rule = _randomValidRule(rng, name);
            final result = await repo.insert(rule);
            expect(
              result,
              isA<Success<int>>(),
              reason: 'iter $iter rule $i: insert should succeed',
            );
            insertedIds.add((result as Success<int>).value);
            insertedNames.add(name);
          }

          // Pick one rule to deactivate (not the first, to keep variety).
          final deactivateIndex = 1 + rng.nextInt(ruleCount - 1);
          final deactivateId = insertedIds[deactivateIndex];
          final deactivateName = insertedNames[deactivateIndex];

          final deactivateResult = await repo.deactivate(deactivateId);
          expect(
            deactivateResult,
            isA<Success<void>>(),
            reason: 'iter $iter: deactivate should succeed',
          );

          // Verify the deactivated rule is NOT in findAllActive().
          final activeRules = await repo.findAllActive();
          final activeNames = activeRules.map((r) => r.name).toList();

          expect(
            activeNames,
            isNot(contains(deactivateName)),
            reason: 'iter $iter: deactivated rule "$deactivateName" '
                'must not appear in findAllActive()',
          );

          // Verify all other rules ARE still active.
          for (var i = 0; i < ruleCount; i++) {
            if (i == deactivateIndex) continue;
            expect(
              activeNames,
              contains(insertedNames[i]),
              reason: 'iter $iter: active rule "${insertedNames[i]}" '
                  'must still appear in findAllActive()',
            );
          }

          await db.close();
        }
      },
    );

    test(
      'deactivated rule has isActive=false when retrieved directly from DB',
      () async {
        final db = await _openInMemoryDb();
        final repo = PricingRepositoryImpl(_testHelper(db));

        final rule = _randomValidRule(Random(171), 'DeactivateCheck');
        final insertResult = await repo.insert(rule);
        final id = (insertResult as Success<int>).value;

        await repo.deactivate(id);

        // findAllActive should not include it.
        final active = await repo.findAllActive();
        expect(active.any((r) => r.name == 'DeactivateCheck'), isFalse);

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Property 18 — Exactly one default at all times
  // -------------------------------------------------------------------------

  group('Property 18 — Exactly one pricing rule is the default at all times',
      () {
    /// **Validates: Requirements 6.7**
    test(
      'after setDefault(id), exactly one active rule has isDefault=true '
      'and it matches the given id (10 random iterations with 3+ rules)',
      () async {
        final rng = Random(18);
        const iterations = 10;

        for (var iter = 0; iter < iterations; iter++) {
          final db = await _openInMemoryDb();
          final repo =
              PricingRepositoryImpl(_testHelper(db));

          // Insert 3–5 rules.
          final ruleCount = 3 + rng.nextInt(3);
          final insertedIds = <int>[];

          for (var i = 0; i < ruleCount; i++) {
            final rule = _randomValidRule(rng, 'Rule_P18_iter${iter}_$i');
            final result = await repo.insert(rule);
            expect(result, isA<Success<int>>());
            insertedIds.add((result as Success<int>).value);
          }

          // Call setDefault for each rule in turn and verify invariant.
          for (final targetId in insertedIds) {
            final setResult = await repo.setDefault(targetId);
            expect(
              setResult,
              isA<Success<void>>(),
              reason: 'iter $iter: setDefault($targetId) should succeed',
            );

            final activeRules = await repo.findAllActive();
            final defaultRules =
                activeRules.where((r) => r.isDefault).toList();

            expect(
              defaultRules.length,
              equals(1),
              reason: 'iter $iter after setDefault($targetId): '
                  'exactly one rule must be default, '
                  'found ${defaultRules.length}',
            );
            expect(
              defaultRules.first.id,
              equals(targetId),
              reason: 'iter $iter: default rule id must be $targetId, '
                  'got ${defaultRules.first.id}',
            );
          }

          await db.close();
        }
      },
    );

    test(
      'findDefault() returns the same rule as the one marked isDefault=true',
      () async {
        final rng = Random(182);
        final db = await _openInMemoryDb();
        final repo = PricingRepositoryImpl(_testHelper(db));

        final ids = <int>[];
        for (var i = 0; i < 4; i++) {
          final rule = _randomValidRule(rng, 'DefaultCheck_$i');
          final result = await repo.insert(rule);
          ids.add((result as Success<int>).value);
        }

        for (final targetId in ids) {
          await repo.setDefault(targetId);

          final defaultRule = await repo.findDefault();
          expect(defaultRule, isNotNull);
          expect(
            defaultRule!.id,
            equals(targetId),
            reason: 'findDefault() must return the rule set via setDefault()',
          );
          expect(
            defaultRule.isDefault,
            isTrue,
            reason: 'findDefault() result must have isDefault=true',
          );
        }

        await db.close();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Property 19 — Creation and retrieval round-trip
  // -------------------------------------------------------------------------

  group('Property 19 — Pricing rule creation and retrieval round-trip', () {
    /// **Validates: Requirements 6.1**
    test(
      'insert then findAllActive() returns a rule with identical fields '
      '(50 random valid rules)',
      () async {
        final rng = Random(19);
        const iterations = 50;

        final db = await _openInMemoryDb();
        final repo = PricingRepositoryImpl(_testHelper(db));

        for (var i = 0; i < iterations; i++) {
          // Use a fresh DB for each iteration to avoid name collisions.
          final iterDb = await _openInMemoryDb();
          final iterRepo =
              PricingRepositoryImpl(_testHelper(iterDb));

          final name = 'RoundTrip_$i';
          final original = _randomValidRule(rng, name);

          final insertResult = await iterRepo.insert(original);
          expect(
            insertResult,
            isA<Success<int>>(),
            reason: 'iter $i: insert should succeed',
          );

          final activeRules = await iterRepo.findAllActive();
          expect(
            activeRules.length,
            equals(1),
            reason: 'iter $i: findAllActive() should return exactly 1 rule',
          );

          _assertRulesEqual(
            original,
            activeRules.first,
            context: 'iter $i',
          );

          await iterDb.close();
        }

        await db.close();
      },
    );

    test(
      'insert with isDefault=false then setDefault then findDefault() '
      'returns rule with all original fields intact (20 random rules)',
      () async {
        final rng = Random(191);
        const iterations = 20;

        for (var i = 0; i < iterations; i++) {
          final db = await _openInMemoryDb();
          final repo = PricingRepositoryImpl(_testHelper(db));

          final name = 'DefaultRoundTrip_$i';
          final original = _randomValidRule(rng, name);

          final insertResult = await repo.insert(original);
          final id = (insertResult as Success<int>).value;

          await repo.setDefault(id);

          final defaultRule = await repo.findDefault();
          expect(defaultRule, isNotNull, reason: 'iter $i: findDefault() must not be null');

          // Check all fields except isDefault (which is now true).
          _assertRulesEqual(
            original.copyWith(isDefault: true),
            defaultRule!,
            context: 'iter $i (via findDefault)',
          );

          await db.close();
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // Property 20 — Invalid pricing rule fields are rejected
  // -------------------------------------------------------------------------

  group('Property 20 — Invalid pricing rule fields are rejected', () {
    /// **Validates: Requirements 6.2, 6.3**
    test(
      'insert with rateAmount <= 0 returns Failure<BusinessError> '
      '(10 random invalid amounts)',
      () async {
        final rng = Random(20);
        const iterations = 10;

        for (var iter = 0; iter < iterations; iter++) {
          final db = await _openInMemoryDb();
          final repo = PricingRepositoryImpl(_testHelper(db));

          // Generate a non-positive rateAmount: 0, negative, or very small
          // positive that rounds to 0 cents.
          final invalidAmount = switch (rng.nextInt(3)) {
            0 => 0.0,
            1 => -(rng.nextInt(10000) + 1) / 100.0, // negative
            _ => 0.001, // rounds to 0 cents
          };

          final rule = PricingRule(
            name: 'InvalidRate_iter$iter',
            rateType: RateType.hourly,
            rateAmount: invalidAmount,
            gracePeriodMinutes: 0,
            isActive: true,
            isDefault: false,
          );

          final result = await repo.insert(rule);

          expect(
            result,
            isA<Failure<int>>(),
            reason: 'iter $iter: rateAmount=$invalidAmount should be rejected',
          );
          expect(
            (result as Failure<int>).error,
            isA<BusinessError>(),
            reason: 'iter $iter: error must be BusinessError',
          );

          await db.close();
        }
      },
    );

    test(
      'insert with duplicate name among active rules returns Failure<BusinessError>',
      () async {
        final rng = Random(201);
        const iterations = 10;

        for (var iter = 0; iter < iterations; iter++) {
          final db = await _openInMemoryDb();
          final repo = PricingRepositoryImpl(_testHelper(db));

          final name = 'DuplicateName_iter$iter';
          final first = _randomValidRule(rng, name);
          final second = _randomValidRule(rng, name); // same name

          final firstResult = await repo.insert(first);
          expect(
            firstResult,
            isA<Success<int>>(),
            reason: 'iter $iter: first insert should succeed',
          );

          final secondResult = await repo.insert(second);
          expect(
            secondResult,
            isA<Failure<int>>(),
            reason: 'iter $iter: duplicate name insert should fail',
          );
          expect(
            (secondResult as Failure<int>).error,
            isA<BusinessError>(),
            reason: 'iter $iter: error must be BusinessError for duplicate name',
          );

          await db.close();
        }
      },
    );

    test(
      'update with name conflicting with another active rule returns Failure<BusinessError>',
      () async {
        final rng = Random(202);
        const iterations = 10;

        for (var iter = 0; iter < iterations; iter++) {
          final db = await _openInMemoryDb();
          final repo = PricingRepositoryImpl(_testHelper(db));

          // Insert two rules with distinct names.
          final nameA = 'UpdateConflict_A_iter$iter';
          final nameB = 'UpdateConflict_B_iter$iter';

          final ruleA = _randomValidRule(rng, nameA);
          final ruleB = _randomValidRule(rng, nameB);

          final resultA = await repo.insert(ruleA);
          final resultB = await repo.insert(ruleB);

          expect(resultA, isA<Success<int>>());
          expect(resultB, isA<Success<int>>());

          final idB = (resultB as Success<int>).value;

          // Try to rename rule B to rule A's name — should conflict.
          final conflictingRule = ruleB.copyWith(id: idB, name: nameA);
          final updateResult = await repo.update(conflictingRule);

          expect(
            updateResult,
            isA<Failure<void>>(),
            reason: 'iter $iter: update with conflicting name should fail',
          );
          expect(
            (updateResult as Failure<void>).error,
            isA<BusinessError>(),
            reason: 'iter $iter: error must be BusinessError for name conflict',
          );

          await db.close();
        }
      },
    );

    test(
      'zero rateAmount (exactly 0.0) is rejected',
      () async {
        final db = await _openInMemoryDb();
        final repo = PricingRepositoryImpl(_testHelper(db));

        final rule = PricingRule(
          name: 'ZeroRate',
          rateType: RateType.flat,
          rateAmount: 0.0,
          gracePeriodMinutes: 0,
          isActive: true,
          isDefault: false,
        );

        final result = await repo.insert(rule);
        expect(result, isA<Failure<int>>());
        expect((result as Failure<int>).error, isA<BusinessError>());

        await db.close();
      },
    );

    test(
      'negative rateAmount is rejected',
      () async {
        final db = await _openInMemoryDb();
        final repo = PricingRepositoryImpl(_testHelper(db));

        final rule = PricingRule(
          name: 'NegativeRate',
          rateType: RateType.hourly,
          rateAmount: -5.00,
          gracePeriodMinutes: 0,
          isActive: true,
          isDefault: false,
        );

        final result = await repo.insert(rule);
        expect(result, isA<Failure<int>>());
        expect((result as Failure<int>).error, isA<BusinessError>());

        await db.close();
      },
    );
  });
}
