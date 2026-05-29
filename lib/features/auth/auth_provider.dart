import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/result.dart';
import '../../models/user.dart';
import '../../services/auth_service.dart';

// ---------------------------------------------------------------------------
// AuthState — sealed class
// ---------------------------------------------------------------------------

/// Represents the current authentication state of the application.
sealed class AuthState {}

/// The user is not authenticated (initial state, after logout, or after timeout).
class Unauthenticated extends AuthState {}

/// The user is authenticated with a valid session.
class Authenticated extends AuthState {
  final int userId;
  final String username;
  final Role role;
  final DateTime sessionStart;

  Authenticated({
    required this.userId,
    required this.username,
    required this.role,
    required this.sessionStart,
  });
}

// ---------------------------------------------------------------------------
// Dependency injection placeholder
// ---------------------------------------------------------------------------

/// Placeholder provider for [AuthService].
///
/// This is overridden in the app's [ProviderScope] (Task 15.1) with a real
/// [AuthService] instance backed by the SQLite repositories. Accessing this
/// provider without an override will throw [UnimplementedError].
final authServiceProvider = Provider<AuthService>((ref) {
  throw UnimplementedError(
    'authServiceProvider must be overridden in ProviderScope before use.',
  );
});

// ---------------------------------------------------------------------------
// AuthNotifier
// ---------------------------------------------------------------------------

/// Manages authentication state and the 30-minute inactivity session timeout.
///
/// Delegates all credential operations to [AuthService]. On successful login
/// the inactivity timer is started; any call to [resetTimer] restarts it.
/// After 30 minutes of inactivity [logout] is called automatically.
///
/// Requirements: 2.1, 2.5, 2.6, 9.4
class AuthNotifier extends StateNotifier<AuthState> {
  final AuthService _authService;

  static const Duration _sessionTimeout = Duration(minutes: 30);

  Timer? _inactivityTimer;

  AuthNotifier(this._authService) : super(Unauthenticated());

  // ---------------------------------------------------------------------------
  // login
  // ---------------------------------------------------------------------------

  /// Authenticates the user with [username] and [password].
  ///
  /// On success, transitions state to [Authenticated] and starts the inactivity
  /// timer. On failure, state remains [Unauthenticated] and the [Failure] is
  /// returned so the UI can display the appropriate error.
  Future<Result<void>> login(String username, String password) async {
    final result = await _authService.login(
      LoginRequest(username: username, password: password),
    );

    switch (result) {
      case Success<AuthSession>(:final value):
        state = Authenticated(
          userId: value.userId,
          username: value.username,
          role: value.role,
          sessionStart: value.sessionStart,
        );
        _startTimer();
        return const Success(null);

      case Failure<AuthSession>(:final error):
        return Failure(error);
    }
  }

  // ---------------------------------------------------------------------------
  // register
  // ---------------------------------------------------------------------------

  /// Registers a new user with [username], [password], and [role].
  ///
  /// Registration does not change the authentication state — the user must
  /// call [login] after registering. Returns [Success<void>] on success or a
  /// typed [Failure] on validation/business errors.
  Future<Result<void>> register(
    String username,
    String password,
    Role role,
  ) async {
    final result = await _authService.register(
      RegisterRequest(username: username, password: password, role: role),
    );

    switch (result) {
      case Success<dynamic>():
        return const Success(null);
      case Failure<dynamic>(:final error):
        return Failure(error);
    }
  }

  // ---------------------------------------------------------------------------
  // logout
  // ---------------------------------------------------------------------------

  /// Logs out the current user.
  ///
  /// Cancels the inactivity timer, calls [AuthService.logout] if a session is
  /// active, and transitions state to [Unauthenticated].
  Future<void> logout() async {
    _cancelTimer();

    final currentState = state;
    if (currentState is Authenticated) {
      await _authService.logout(currentState.userId, currentState.username);
    }

    state = Unauthenticated();
  }

  // ---------------------------------------------------------------------------
  // resetTimer
  // ---------------------------------------------------------------------------

  /// Resets the 30-minute inactivity timer.
  ///
  /// Should be called on every user interaction (tap, scroll, text input) via
  /// a [GestureDetector] wrapper at the root navigator level. No-op when the
  /// current state is [Unauthenticated].
  void resetTimer() {
    if (state is Unauthenticated) return;
    _startTimer();
  }

  // ---------------------------------------------------------------------------
  // dispose
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _cancelTimer();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  void _startTimer() {
    _cancelTimer();
    _inactivityTimer = Timer(_sessionTimeout, () async {
      await logout();
    });
  }

  void _cancelTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
  }
}

// ---------------------------------------------------------------------------
// authProvider
// ---------------------------------------------------------------------------

/// Global provider for [AuthNotifier] / [AuthState].
///
/// Reads [authServiceProvider] for its [AuthService] dependency. Override
/// [authServiceProvider] in the root [ProviderScope] to inject the real
/// service implementation.
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final authService = ref.watch(authServiceProvider);
  return AuthNotifier(authService);
});
