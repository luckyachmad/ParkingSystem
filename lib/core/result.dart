// Result type pattern used throughout services and repositories.
// Avoids exception-driven control flow across layer boundaries.

sealed class Result<T> {
  const Result();
}

class Success<T> extends Result<T> {
  final T value;
  const Success(this.value);
}

class Failure<T> extends Result<T> {
  final AppError error;
  const Failure(this.error);
}

// ---------------------------------------------------------------------------
// Error hierarchy
// ---------------------------------------------------------------------------

sealed class AppError {
  const AppError();
}

class ValidationError extends AppError {
  final String field;
  final String message;
  const ValidationError({required this.field, required this.message});
}

class BusinessError extends AppError {
  final String message;
  const BusinessError(this.message);
}

class DatabaseError extends AppError {
  final String operation;
  final String message;
  const DatabaseError({required this.operation, required this.message});
}

class SessionError extends AppError {
  final String message;
  const SessionError(this.message);
}
