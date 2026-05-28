import 'result.dart';

/// Validates vehicle plate numbers.
///
/// Accepted format: 1–10 characters, letters (A-Z, a-z), digits (0-9),
/// and hyphens (-) only. Spaces and all other special characters are rejected.
///
/// Regex: ^[A-Za-z0-9\-]{1,10}$
class PlateValidator {
  PlateValidator._();

  static final RegExp _plateRegex = RegExp(r'^[A-Za-z0-9\-]{1,10}$');

  /// Validates [input] as a plate number.
  ///
  /// Returns [Success<String>] with the original input when valid.
  /// Returns [Failure<ValidationError>] when the input does not match the
  /// accepted format (wrong length, disallowed characters, etc.).
  static Result<String> validate(String input) {
    if (_plateRegex.hasMatch(input)) {
      return Success(input);
    }
    return Failure(
      const ValidationError(
        field: 'plateNumber',
        message:
            'Plate number must be 1–10 characters and contain only letters, '
            'digits, and hyphens.',
      ),
    );
  }
}
