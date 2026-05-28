// Feature: parking-system, Property 1
//
// **Validates: Requirements 3.1, 3.2, 4.1, 4.2**
//
// Property 1: Valid plate numbers are accepted; invalid ones are rejected.
// For any string input submitted as a plate number, the system SHALL accept it
// if and only if it matches ^[A-Za-z0-9\-]{1,10}$ — containing only letters,
// digits, and hyphens, with length between 1 and 10 characters inclusive.
// Any string outside this pattern SHALL be rejected with a ValidationError.

import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:parking_system/core/plate_validator.dart';
import 'package:parking_system/core/result.dart';

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

const String _validChars =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-';

/// Generates a random valid plate string: 1–10 chars from [_validChars].
String validPlateGen(Random rng) {
  final length = rng.nextInt(10) + 1; // 1..10
  return List.generate(
    length,
    (_) => _validChars[rng.nextInt(_validChars.length)],
  ).join();
}

/// Generates a random invalid plate string from one of five categories:
///   1. Empty string
///   2. Length > 10 (11–20 chars from valid charset)
///   3. String containing at least one space
///   4. String containing at least one special character (@, #, !, $, %, etc.)
///   5. String consisting entirely of special characters
String invalidPlateGen(Random rng) {
  final category = rng.nextInt(5); // 0..4
  switch (category) {
    case 0:
      // Category 1: empty string
      return '';

    case 1:
      // Category 2: length > 10 (11–20 chars from valid charset)
      final length = rng.nextInt(10) + 11; // 11..20
      return List.generate(
        length,
        (_) => _validChars[rng.nextInt(_validChars.length)],
      ).join();

    case 2:
      // Category 3: contains at least one space
      final length = rng.nextInt(8) + 2; // 2..9 total chars
      final spacePos = rng.nextInt(length);
      return List.generate(length, (i) {
        if (i == spacePos) return ' ';
        return _validChars[rng.nextInt(_validChars.length)];
      }).join();

    case 3:
      // Category 4: contains at least one special character
      const specialChars = r'@#!$%^&*()+=[]{}|;:,.<>?/\~`"' "'";
      final length = rng.nextInt(8) + 2; // 2..9 total chars
      final specialPos = rng.nextInt(length);
      return List.generate(length, (i) {
        if (i == specialPos) {
          return specialChars[rng.nextInt(specialChars.length)];
        }
        return _validChars[rng.nextInt(_validChars.length)];
      }).join();

    case 4:
    default:
      // Category 5: entirely special characters
      const specialChars = r'@#!$%^&*()+=[]{}|;:,.<>?/\~`"' "'";
      final length = rng.nextInt(5) + 1; // 1..5 chars
      return List.generate(
        length,
        (_) => specialChars[rng.nextInt(specialChars.length)],
      ).join();
  }
}

// ---------------------------------------------------------------------------
// Helper: assert a result is Failure<ValidationError>
// ---------------------------------------------------------------------------

void _expectValidationFailure(Result<String> result, String plate) {
  expect(
    result,
    isA<Failure<String>>(),
    reason: 'Expected Failure for plate "$plate"',
  );
  final failure = result as Failure<String>;
  expect(
    failure.error,
    isA<ValidationError>(),
    reason: 'Expected ValidationError for plate "$plate"',
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  const int iterations = 100;

  group('PlateValidator — Property 1: valid plates are accepted', () {
    test('validPlateGen: all generated plates return Success', () {
      final rng = Random(42); // fixed seed for reproducibility
      final failures = <String>[];

      for (var i = 0; i < iterations; i++) {
        final plate = validPlateGen(rng);
        final result = PlateValidator.validate(plate);
        if (result is! Success<String>) {
          failures.add(plate);
        }
      }

      expect(
        failures,
        isEmpty,
        reason:
            'Expected all valid plates to return Success, '
            'but these were rejected: $failures',
      );
    });

    test('validPlateGen: Success value equals the original input', () {
      final rng = Random(99);

      for (var i = 0; i < iterations; i++) {
        final plate = validPlateGen(rng);
        final result = PlateValidator.validate(plate);
        expect(
          result,
          isA<Success<String>>(),
          reason: 'Expected Success for plate "$plate"',
        );
        final success = result as Success<String>;
        expect(
          success.value,
          equals(plate),
          reason: 'Success value should equal the original input',
        );
      }
    });
  });

  group('PlateValidator — Property 1: invalid plates are rejected', () {
    test(
        'invalidPlateGen: all generated plates return Failure<ValidationError>',
        () {
      final rng = Random(7);
      final unexpectedPasses = <String>[];

      for (var i = 0; i < iterations; i++) {
        final plate = invalidPlateGen(rng);
        final result = PlateValidator.validate(plate);
        if (result is Failure<String>) {
          if (result.error is! ValidationError) {
            unexpectedPasses.add(plate);
          }
        } else {
          unexpectedPasses.add(plate);
        }
      }

      expect(
        unexpectedPasses,
        isEmpty,
        reason:
            'Expected all invalid plates to return Failure<ValidationError>, '
            'but these were accepted or returned wrong error: $unexpectedPasses',
      );
    });

    // --- Explicit edge-case coverage for each invalid category ---

    test('Category 1 — empty string is rejected', () {
      _expectValidationFailure(PlateValidator.validate(''), '');
    });

    test('Category 2 — length 11 (one over maximum) is rejected', () {
      _expectValidationFailure(
          PlateValidator.validate('ABCDEFGHIJK'), 'ABCDEFGHIJK');
    });

    test('Category 2 — length 20 is rejected', () {
      final plate = 'A' * 20;
      _expectValidationFailure(PlateValidator.validate(plate), plate);
    });

    test('Category 3 — plates with spaces are rejected', () {
      for (final plate in ['AB CD', 'A B', ' ABC', 'ABC ']) {
        _expectValidationFailure(PlateValidator.validate(plate), plate);
      }
    });

    test('Category 4 — plates with special characters are rejected', () {
      for (final plate in ['AB@CD', 'PL#TE', 'ABC!', 'A\$B', 'A%B']) {
        _expectValidationFailure(PlateValidator.validate(plate), plate);
      }
    });

    test('Category 5 — plates of only special characters are rejected', () {
      for (final plate in ['@@@', '###', '!!!', '@#!']) {
        _expectValidationFailure(PlateValidator.validate(plate), plate);
      }
    });
  });

  group('PlateValidator — boundary values', () {
    test('length 1 (minimum) is accepted', () {
      for (final plate in ['A', 'z', '0', '-']) {
        expect(
          PlateValidator.validate(plate),
          isA<Success<String>>(),
          reason: '"$plate" should be accepted',
        );
      }
    });

    test('length 10 (maximum) is accepted', () {
      expect(
        PlateValidator.validate('ABCDEFGHIJ'),
        isA<Success<String>>(),
      );
    });

    test('length 11 (one over maximum) is rejected', () {
      _expectValidationFailure(
          PlateValidator.validate('ABCDEFGHIJK'), 'ABCDEFGHIJK');
    });

    test('mixed case and hyphens are accepted', () {
      for (final plate in ['ABC-123', 'a-b-c', 'A1-B2', '-A-']) {
        expect(
          PlateValidator.validate(plate),
          isA<Success<String>>(),
          reason: '"$plate" should be accepted',
        );
      }
    });
  });
}
