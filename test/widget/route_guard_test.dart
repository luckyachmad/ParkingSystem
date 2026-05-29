// Feature: parking-system, Property 25
// Feature: parking-system, Property 26
//
// Property 25: Attendant session cannot reach admin-only routes
//   Validates: Requirements 9.1, 9.3
//
// Property 26: Owner/Admin session can reach all routes
//   Validates: Requirements 9.2
//
// These are widget tests that pump a MaterialApp.router backed by the real
// GoRouter (via routerProvider) with authProvider overridden to inject a
// fixed AuthState. No real database or AuthService is needed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parking_system/core/result.dart';
import 'package:parking_system/features/auth/auth_provider.dart';
import 'package:parking_system/features/dashboard/dashboard_provider.dart';
import 'package:parking_system/features/vehicle_entry/vehicle_entry_provider.dart';
import 'package:parking_system/features/vehicle_exit/vehicle_exit_provider.dart';
import 'package:parking_system/models/audit_event.dart';
import 'package:parking_system/models/dashboard_metrics.dart';
import 'package:parking_system/models/parking_transaction.dart';
import 'package:parking_system/models/pricing_rule.dart';
import 'package:parking_system/models/ticket.dart';
import 'package:parking_system/models/transaction_filter.dart';
import 'package:parking_system/models/user.dart';
import 'package:parking_system/repositories/audit_log_repository.dart';
import 'package:parking_system/repositories/pricing_repository.dart';
import 'package:parking_system/repositories/ticket_repository.dart';
import 'package:parking_system/repositories/transaction_repository.dart';
import 'package:parking_system/repositories/user_repository.dart';
import 'package:parking_system/services/auth_service.dart';
import 'package:parking_system/services/dashboard_service.dart';
import 'package:parking_system/core/router.dart';

// ---------------------------------------------------------------------------
// Stub repositories — no database access
// ---------------------------------------------------------------------------

class _StubUserRepository implements UserRepository {
  @override
  Future<User?> findByUsername(String username) async => null;

  @override
  Future<Result<int>> insert(User user) async => const Success(1);

  @override
  Future<Result<void>> updateLockStatus(int userId, bool locked) async =>
      const Success(null);

  @override
  Future<Result<void>> updateFailedAttempts(int userId, int count) async =>
      const Success(null);

  @override
  Future<int> countActiveSessions() async => 0;
}

class _StubAuditLogRepository implements AuditLogRepository {
  @override
  Future<void> log(AuditEvent event) async {}
}

class _StubPricingRepository implements PricingRepository {
  @override
  Future<Result<int>> insert(PricingRule rule) async => const Success(1);

  @override
  Future<PricingRule?> findDefault() async => null;

  @override
  Future<List<PricingRule>> findAllActive() async => [];

  @override
  Future<Result<void>> update(PricingRule rule) async => const Success(null);

  @override
  Future<Result<void>> setDefault(int ruleId) async => const Success(null);

  @override
  Future<Result<void>> deactivate(int ruleId) async => const Success(null);
}

class _StubTicketRepository implements TicketRepository {
  @override
  Future<Result<int>> insert(Ticket ticket) async => const Success(1);

  @override
  Future<Ticket?> findOpenByPlate(String plateNumber) async => null;

  @override
  Future<List<Ticket>> findAllOpen() async => [];

  @override
  Future<Result<void>> closeTicket(
    int ticketId,
    DateTime exitTime,
    String closedBy,
  ) async =>
      const Success(null);

  @override
  Future<int> countOpen() async => 0;
}

class _StubTransactionRepository implements TransactionRepository {
  @override
  Future<Result<int>> insert(ParkingTransaction transaction) async =>
      const Success(1);

  @override
  Future<ParkingTransaction?> findById(int id) async => null;

  @override
  Future<Result<List<ParkingTransaction>>> query(
    TransactionFilter filter,
  ) async =>
      const Success([]);

  @override
  Future<Result<int>> sumFeesSince(DateTime since) async => const Success(0);
}

class _StubDashboardService extends DashboardService {
  _StubDashboardService()
      : super(
          ticketRepository: _StubTicketRepository(),
          transactionRepository: _StubTransactionRepository(),
          userRepository: _StubUserRepository(),
        );

  @override
  Future<DashboardMetrics> computeMetrics() async => DashboardMetrics(
        activeVehicles: 0,
        activeUsers: 0,
        dailyIncome: 0.0,
        computedAt: DateTime.now(),
      );
}

// ---------------------------------------------------------------------------
// Stub AuthService — delegates to stub repositories, never touches SQLite
// ---------------------------------------------------------------------------

final _stubAuthService = AuthService(
  userRepository: _StubUserRepository(),
  auditLogRepository: _StubAuditLogRepository(),
);

// ---------------------------------------------------------------------------
// _FixedStateAuthNotifier
//
// Subclass of AuthNotifier that sets a fixed initial state in the constructor.
// The 'state' setter is protected in StateNotifier but accessible from
// subclasses, so this is the cleanest way to inject a pre-set AuthState
// without touching the real AuthService.
// ---------------------------------------------------------------------------

class _FixedStateAuthNotifier extends AuthNotifier {
  _FixedStateAuthNotifier(AuthState initialState) : super(_stubAuthService) {
    state = initialState;
  }
}

// ---------------------------------------------------------------------------
// Helper — build the widget tree with a fixed auth state
// ---------------------------------------------------------------------------

/// Pumps a [MaterialApp.router] backed by [routerProvider] with [authProvider]
/// overridden to hold [authState]. Returns the [GoRouter] so the test can
/// call [router.go()] to trigger navigation.
final _stubPricingRepo = _StubPricingRepository();
final _stubTicketRepo = _StubTicketRepository();
final _stubTransactionRepo = _StubTransactionRepository();
final _stubDashboardSvc = _StubDashboardService();

Future<GoRouter> _pumpApp(
  WidgetTester tester,
  AuthState authState,
) async {
  late GoRouter router;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(
          (ref) => _FixedStateAuthNotifier(authState),
        ),
        // Override all repository/service placeholder providers so screens
        // can build without hitting UnimplementedError.
        pricingRepositoryProvider.overrideWithValue(_stubPricingRepo),
        ticketRepositoryProvider.overrideWithValue(_stubTicketRepo),
        transactionRepositoryProvider.overrideWithValue(_stubTransactionRepo),
        dashboardServiceProvider.overrideWithValue(_stubDashboardSvc),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          router = ref.watch(routerProvider);
          return MaterialApp.router(routerConfig: router);
        },
      ),
    ),
  );

  // Let the initial route settle.
  await tester.pumpAndSettle();
  return router;
}

// ---------------------------------------------------------------------------
// Shared auth state fixtures
// ---------------------------------------------------------------------------

AuthState _attendantState() => Authenticated(
      userId: 1,
      username: 'attendant_user',
      role: Role.attendant,
      sessionStart: DateTime.utc(2024, 1, 1),
    );

AuthState _ownerState() => Authenticated(
      userId: 2,
      username: 'owner_user',
      role: Role.owner,
      sessionStart: DateTime.utc(2024, 1, 1),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // Property 25 — Attendant session cannot reach admin-only routes
  // Validates: Requirements 9.1, 9.3
  // -------------------------------------------------------------------------
  group('Property 25 — Attendant session cannot reach admin-only routes', () {
    // Admin-only routes and the placeholder text they would show if allowed.
    const adminRoutes = {
      AppRoutes.pricing: 'Pricing Management',
      AppRoutes.dashboard: 'Dashboard',
      AppRoutes.register: 'User Registration',
    };

    for (final entry in adminRoutes.entries) {
      final route = entry.key;
      final routeTitle = entry.value;

      testWidgets(
        'navigating to $route redirects attendant to vehicle-entry',
        (tester) async {
          final router = await _pumpApp(tester, _attendantState());

          // Navigate to the admin-only route.
          router.go(route);
          await tester.pumpAndSettle();

          // The admin screen must NOT be visible.
          expect(
            find.text(routeTitle),
            findsNothing,
            reason: 'Admin screen "$routeTitle" must not be shown to attendant',
          );

          // The vehicle-entry placeholder must be visible instead.
          expect(
            find.text('Vehicle Entry'),
            findsWidgets,
            reason: 'Attendant must be redirected to Vehicle Entry screen',
          );
        },
      );
    }
  });

  // -------------------------------------------------------------------------
  // Property 26 — Owner/Admin session can reach all routes
  // Validates: Requirements 9.2
  // -------------------------------------------------------------------------
  group('Property 26 — Owner/Admin session can reach all routes', () {
    // All navigable routes and the placeholder text each one displays.
    const allRoutes = {
      AppRoutes.vehicleEntry: 'Vehicle Entry',
      AppRoutes.vehicleExit: 'Vehicle Exit',
      AppRoutes.transactions: 'Transaction History',
      AppRoutes.pricing: 'Pricing Management',
      AppRoutes.dashboard: 'Dashboard',
      AppRoutes.register: 'User Registration',
    };

    for (final entry in allRoutes.entries) {
      final route = entry.key;
      final routeTitle = entry.value;

      testWidgets(
        'owner can navigate to $route and sees "$routeTitle"',
        (tester) async {
          final router = await _pumpApp(tester, _ownerState());

          // Navigate to the target route.
          router.go(route);
          await tester.pumpAndSettle();

          // The target placeholder screen must be visible.
          expect(
            find.text(routeTitle),
            findsWidgets,
            reason: 'Owner must be able to reach "$routeTitle"',
          );
        },
      );
    }
  });
}
