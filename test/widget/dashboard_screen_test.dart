// Feature: parking-system
//
// Widget test for Dashboard stale data indicator
//   Validates: Requirements 7.4, 7.6
//
// Scenario:
//   1. DashboardService.computeMetrics() succeeds on the first call → metrics
//      are displayed.
//   2. A manual refresh triggers a second call that throws DatabaseError.
//   3. The stale-data banner appears AND the last known metric values are
//      still visible (provider retains them per Requirement 7.6).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parking_system/core/result.dart';
import 'package:parking_system/features/auth/auth_provider.dart';
import 'package:parking_system/features/dashboard/dashboard_provider.dart';
import 'package:parking_system/features/dashboard/dashboard_screen.dart';
import 'package:parking_system/models/audit_event.dart';
import 'package:parking_system/models/dashboard_metrics.dart';
import 'package:parking_system/models/parking_transaction.dart';
import 'package:parking_system/models/ticket.dart';
import 'package:parking_system/models/transaction_filter.dart';
import 'package:parking_system/models/user.dart';
import 'package:parking_system/repositories/audit_log_repository.dart';
import 'package:parking_system/repositories/ticket_repository.dart';
import 'package:parking_system/repositories/transaction_repository.dart';
import 'package:parking_system/repositories/user_repository.dart';
import 'package:parking_system/services/auth_service.dart';
import 'package:parking_system/services/dashboard_service.dart';

// ---------------------------------------------------------------------------
// Stub repositories — satisfy constructor signatures; never actually called
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

class _StubTicketRepository implements TicketRepository {
  @override
  Future<Result<int>> insert(Ticket ticket) => throw UnimplementedError();

  @override
  Future<Ticket?> findOpenByPlate(String plateNumber) =>
      throw UnimplementedError();

  @override
  Future<List<Ticket>> findAllOpen() => throw UnimplementedError();

  @override
  Future<Result<void>> closeTicket(
          int ticketId, DateTime exitTime, String closedBy) =>
      throw UnimplementedError();

  @override
  Future<int> countOpen() => throw UnimplementedError();
}

class _StubTransactionRepository implements TransactionRepository {
  @override
  Future<Result<int>> insert(ParkingTransaction transaction) =>
      throw UnimplementedError();

  @override
  Future<ParkingTransaction?> findById(int id) => throw UnimplementedError();

  @override
  Future<Result<List<ParkingTransaction>>> query(TransactionFilter filter) =>
      throw UnimplementedError();

  @override
  Future<Result<int>> sumFeesSince(DateTime since) =>
      throw UnimplementedError();
}

// ---------------------------------------------------------------------------
// Stub AuthService — never touches SQLite
// ---------------------------------------------------------------------------

final _stubAuthService = AuthService(
  userRepository: _StubUserRepository(),
  auditLogRepository: _StubAuditLogRepository(),
);

// ---------------------------------------------------------------------------
// _FixedStateAuthNotifier — injects a pre-set AuthState without real login
// ---------------------------------------------------------------------------

class _FixedStateAuthNotifier extends AuthNotifier {
  _FixedStateAuthNotifier(AuthState initialState) : super(_stubAuthService) {
    state = initialState;
  }
}

// ---------------------------------------------------------------------------
// _FakeDashboardService
//
// Returns valid metrics on the first call to computeMetrics().
// Throws DatabaseError on every subsequent call.
// The stub repositories passed to super() are never invoked because
// computeMetrics() is fully overridden.
// ---------------------------------------------------------------------------

class _FakeDashboardService extends DashboardService {
  int _callCount = 0;
  final DashboardMetrics _initialMetrics;

  /// When true, the first call introduces a small async delay so the loading
  /// indicator is visible before the future resolves.
  final bool delayFirstCall;

  _FakeDashboardService(this._initialMetrics, {this.delayFirstCall = false})
      : super(
          ticketRepository: _StubTicketRepository(),
          transactionRepository: _StubTransactionRepository(),
          userRepository: _StubUserRepository(),
        );

  @override
  Future<DashboardMetrics> computeMetrics() async {
    _callCount++;
    if (_callCount == 1) {
      if (delayFirstCall) {
        // Yield to the event loop so the loading state is rendered first.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return _initialMetrics;
    }
    throw const DatabaseError(
      operation: 'computeMetrics',
      message: 'Simulated database failure',
    );
  }
}

// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------

/// Fixed metrics used as the "initial good load".
final _testMetrics = DashboardMetrics(
  activeVehicles: 7,
  activeUsers: 3,
  dailyIncome: 42.50,
  computedAt: DateTime.utc(2024, 6, 1, 12, 0, 0),
);

// ---------------------------------------------------------------------------
// _pumpDashboard
//
// Pumps DashboardScreen inside a minimal GoRouter + ProviderScope.
// dashboardServiceProvider is overridden with fakeService.
// authProvider is overridden with a fixed owner session so the route guard
// does not redirect away from /dashboard.
// ---------------------------------------------------------------------------

Future<void> _pumpDashboard(
  WidgetTester tester,
  _FakeDashboardService fakeService,
) async {
  final ownerState = Authenticated(
    userId: 1,
    username: 'owner',
    role: Role.owner,
    sessionStart: DateTime.utc(2024, 1, 1),
  );

  // Minimal router: /dashboard is the entry point; stub routes prevent
  // context.go() calls from the nav bar from throwing.
  final router = GoRouter(
    initialLocation: '/dashboard',
    routes: [
      GoRoute(
        path: '/dashboard',
        builder: (_, __) => const DashboardScreen(), // ignore: unnecessary_underscores
      ),
      GoRoute(
        path: '/vehicle-entry',
        builder: (_, __) => const Scaffold(body: Text('Vehicle Entry')), // ignore: unnecessary_underscores
      ),
      GoRoute(
        path: '/vehicle-exit',
        builder: (_, __) => const Scaffold(body: Text('Vehicle Exit')), // ignore: unnecessary_underscores
      ),
      GoRoute(
        path: '/transactions',
        builder: (_, __) => const Scaffold(body: Text('Transactions')), // ignore: unnecessary_underscores
      ),
      GoRoute(
        path: '/pricing',
        builder: (_, __) => const Scaffold(body: Text('Pricing')), // ignore: unnecessary_underscores
      ),
      GoRoute(
        path: '/register',
        builder: (_, __) => const Scaffold(body: Text('Register')), // ignore: unnecessary_underscores
      ),
      GoRoute(
        path: '/login',
        builder: (_, __) => const Scaffold(body: Text('Login')), // ignore: unnecessary_underscores
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dashboardServiceProvider.overrideWithValue(fakeService),
        authProvider.overrideWith(
          (ref) => _FixedStateAuthNotifier(ownerState),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('DashboardScreen — stale data indicator', () {
    // -----------------------------------------------------------------------
    // Test 1: Loading indicator is shown before data arrives
    // -----------------------------------------------------------------------
    testWidgets(
      'shows loading indicator while initial metrics are being fetched',
      (tester) async {
        // Use delayFirstCall so the loading state is visible before the
        // future resolves.
        final fakeService =
            _FakeDashboardService(_testMetrics, delayFirstCall: true);
        await _pumpDashboard(tester, fakeService);

        // pump() without settle — the async build() has not completed yet.
        await tester.pump();

        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        // Let the delayed future resolve so the widget tree is clean.
        await tester.pumpAndSettle();
      },
    );

    // -----------------------------------------------------------------------
    // Test 2: Initial load shows metric values, no stale banner
    // -----------------------------------------------------------------------
    testWidgets(
      'shows metric values after initial successful load without stale banner',
      (tester) async {
        final fakeService = _FakeDashboardService(_testMetrics);
        await _pumpDashboard(tester, fakeService);

        // Wait for the async build() to complete.
        await tester.pumpAndSettle();

        // All three metric card labels must be visible.
        expect(find.text('Active Vehicles'), findsOneWidget);
        expect(find.text('Active Users'), findsOneWidget);
        expect(find.text("Today's Income"), findsOneWidget);

        // The actual metric values must be displayed.
        expect(find.text('7'), findsOneWidget); // activeVehicles
        expect(find.text('3'), findsOneWidget); // activeUsers
        expect(find.text(r'$42.50'), findsOneWidget); // dailyIncome

        // No stale banner on a clean load.
        expect(
          find.textContaining('Data may be stale'),
          findsNothing,
          reason: 'Stale banner must not appear after a successful load',
        );
      },
    );

    // -----------------------------------------------------------------------
    // Test 3: After a DatabaseError refresh, stale banner appears and last
    //         metric values are still visible (Requirement 7.6).
    // -----------------------------------------------------------------------
    testWidgets(
      'shows stale banner and retains last metric values after DatabaseError on refresh',
      (tester) async {
        final fakeService = _FakeDashboardService(_testMetrics);
        await _pumpDashboard(tester, fakeService);

        // Wait for the initial load to complete.
        await tester.pumpAndSettle();

        // Confirm initial metrics are shown.
        expect(find.text('7'), findsOneWidget);
        expect(find.text('3'), findsOneWidget);
        expect(find.text(r'$42.50'), findsOneWidget);

        // No stale banner yet.
        expect(find.textContaining('Data may be stale'), findsNothing);

        // Tap the refresh button — triggers the second computeMetrics() call
        // which throws DatabaseError.
        await tester.tap(find.byIcon(Icons.refresh));
        await tester.pumpAndSettle();

        // ── Stale banner must be visible ────────────────────────────────────
        expect(
          find.textContaining('Data may be stale'),
          findsOneWidget,
          reason: 'Stale banner must appear after a DatabaseError refresh',
        );

        // ── Last metric values must still be displayed ──────────────────────
        expect(
          find.text('7'),
          findsOneWidget,
          reason: 'activeVehicles must be retained after stale refresh',
        );
        expect(
          find.text('3'),
          findsOneWidget,
          reason: 'activeUsers must be retained after stale refresh',
        );
        expect(
          find.text(r'$42.50'),
          findsOneWidget,
          reason: 'dailyIncome must be retained after stale refresh',
        );

        // Metric card labels must still be present.
        expect(find.text('Active Vehicles'), findsOneWidget);
        expect(find.text('Active Users'), findsOneWidget);
        expect(find.text("Today's Income"), findsOneWidget);
      },
    );
  });
}
