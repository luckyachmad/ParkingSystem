import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/auth_provider.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/registration_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/pricing/pricing_screen.dart';
import '../features/transactions/transaction_history_screen.dart';
import '../features/vehicle_entry/vehicle_entry_screen.dart';
import '../features/vehicle_exit/receipt_screen.dart';
import '../features/vehicle_exit/vehicle_exit_screen.dart';
import '../models/user.dart';

// ---------------------------------------------------------------------------
// Route path constants
// ---------------------------------------------------------------------------

/// Centralised route path constants — use these instead of raw strings.
abstract final class AppRoutes {
  static const String login = '/login';
  static const String register = '/register';
  static const String vehicleEntry = '/vehicle-entry';
  static const String vehicleExit = '/vehicle-exit';
  static const String vehicleExitReceipt = '/vehicle-exit/receipt';
  static const String transactions = '/transactions';
  static const String pricing = '/pricing';
  static const String dashboard = '/dashboard';
}

// ---------------------------------------------------------------------------
// Admin-only routes (owner role required)
// ---------------------------------------------------------------------------

/// Routes that require the [Role.owner] role.
const _adminOnlyRoutes = {
  AppRoutes.register,
  AppRoutes.pricing,
  AppRoutes.dashboard,
};

// ---------------------------------------------------------------------------
// accessDeniedProvider
// ---------------------------------------------------------------------------

/// Signals to the UI that an access-denied redirect has just occurred.
///
/// Set to `true` by the route guard when an attendant attempts to navigate to
/// an owner-only route. The UI (e.g. [VehicleEntryScreen]) should watch this
/// provider and show a snackbar when it becomes `true`, then reset it to
/// `false` after displaying the message.
///
/// Requirements: 9.3
final accessDeniedProvider = StateProvider<bool>((ref) => false);

// ---------------------------------------------------------------------------
// RouterNotifier
// ---------------------------------------------------------------------------

/// A [ChangeNotifier] that listens to [authProvider] and notifies [GoRouter]
/// to re-evaluate the redirect callback whenever the authentication state
/// changes.
///
/// This is the standard go_router + Riverpod integration pattern:
/// [GoRouter.refreshListenable] is wired to this notifier so that every
/// login, logout, or session timeout triggers a fresh route guard evaluation.
///
/// Requirements: 9.1, 9.4, 9.5
class RouterNotifier extends ChangeNotifier {
  final Ref _ref;

  RouterNotifier(this._ref) {
    // Listen to authProvider; any state change triggers notifyListeners(),
    // which causes GoRouter to re-run the redirect callback.
    _ref.listen<AuthState>(authProvider, (prev, next) => notifyListeners());
  }

  /// Route guard — evaluated on every navigation event and on every auth
  /// state change.
  ///
  /// Guard logic (Requirements 2.4, 2.7, 9.2, 9.3):
  /// - Public route (`/login`): always allow.
  /// - [Unauthenticated]: redirect to `/login` for any protected route.
  /// - [Authenticated] with [Role.attendant] targeting an admin-only route:
  ///   set [accessDeniedProvider] and redirect to `/vehicle-entry`.
  /// - [Authenticated] with an unrecognised role: invalidate session and
  ///   redirect to `/login`.
  /// - Otherwise: allow navigation (return `null`).
  String? redirect(BuildContext context, GoRouterState state) {
    final location = state.matchedLocation;
    final authState = _ref.read(authProvider);

    // Public route — always allow regardless of auth state.
    if (location == AppRoutes.login) return null;

    // Unauthenticated — redirect to login for any protected route.
    if (authState is Unauthenticated) return AppRoutes.login;

    // From here the user is authenticated.
    final authenticated = authState as Authenticated;

    // Unrecognised role — invalidate session and redirect to login.
    // Role.values only contains owner and attendant; any other value is
    // impossible with the current enum, but guard against future changes.
    if (authenticated.role != Role.owner &&
        authenticated.role != Role.attendant) {
      // Invalidate session asynchronously — fire-and-forget is acceptable
      // here because the redirect happens immediately.
      _ref.read(authProvider.notifier).logout();
      return AppRoutes.login;
    }

    // Attendant attempting to reach an admin-only route.
    if (authenticated.role == Role.attendant &&
        _adminOnlyRoutes.contains(location)) {
      // Signal the UI to show an access-denied snackbar.
      _ref.read(accessDeniedProvider.notifier).state = true;
      return AppRoutes.vehicleEntry;
    }

    // All checks passed — allow navigation.
    return null;
  }
}

// ---------------------------------------------------------------------------
// routerNotifierProvider
// ---------------------------------------------------------------------------

/// Provides the singleton [RouterNotifier] instance.
///
/// Kept as a separate provider so that [routerProvider] can watch it and
/// [GoRouter.refreshListenable] is wired correctly.
final routerNotifierProvider = Provider<RouterNotifier>((ref) {
  return RouterNotifier(ref);
});

// ---------------------------------------------------------------------------
// routerProvider
// ---------------------------------------------------------------------------

/// Provides the application [GoRouter] instance.
///
/// Consumers (e.g. [MaterialApp.router]) should watch this provider:
/// ```dart
/// final router = ref.watch(routerProvider);
/// return MaterialApp.router(routerConfig: router);
/// ```
///
/// Requirements: 9.1
final routerProvider = Provider<GoRouter>((ref) {
  final notifier = ref.watch(routerNotifierProvider);

  return GoRouter(
    initialLocation: AppRoutes.login,
    refreshListenable: notifier,
    redirect: notifier.redirect,
    routes: _buildRoutes(),
  );
});

// ---------------------------------------------------------------------------
// Route definitions
// ---------------------------------------------------------------------------

/// Builds the full list of [GoRoute] entries.
///
/// Placeholder [Scaffold] builders are used until the real screens are wired
/// in Tasks 11–13 and 15.1.
List<RouteBase> _buildRoutes() {
  return [
    GoRoute(
      path: AppRoutes.login,
      builder: (context, state) => const LoginScreen(),
    ),
    GoRoute(
      path: AppRoutes.register,
      builder: (context, state) => const RegistrationScreen(),
    ),
    GoRoute(
      path: AppRoutes.vehicleEntry,
      builder: (context, state) => const VehicleEntryScreen(),
    ),
    GoRoute(
      path: AppRoutes.vehicleExit,
      builder: (context, state) => const VehicleExitScreen(),
      routes: [
        GoRoute(
          path: 'receipt',
          builder: (context, state) => const ReceiptScreen(),
        ),
      ],
    ),
    GoRoute(
      path: AppRoutes.transactions,
      builder: (context, state) => const TransactionHistoryScreen(),
    ),
    GoRoute(
      path: AppRoutes.pricing,
      builder: (context, state) => const PricingScreen(),
    ),
    GoRoute(
      path: AppRoutes.dashboard,
      builder: (context, state) => const DashboardScreen(),
    ),
  ];
}


