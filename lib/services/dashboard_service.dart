import '../core/result.dart';
import '../models/dashboard_metrics.dart';
import '../repositories/ticket_repository.dart';
import '../repositories/transaction_repository.dart';
import '../repositories/user_repository.dart';

/// Aggregates live database metrics for the dashboard screen.
///
/// All three repository calls are made on every invocation — no caching is
/// performed, satisfying Requirement 7.5 (metrics derived from live queries).
///
/// Exceptions thrown by repositories propagate to the caller (typically
/// [DashboardProvider]), which is responsible for surfacing a [DatabaseError]
/// state to the UI.
class DashboardService {
  final TicketRepository _ticketRepository;
  final TransactionRepository _transactionRepository;
  final UserRepository _userRepository;

  const DashboardService({
    required TicketRepository ticketRepository,
    required TransactionRepository transactionRepository,
    required UserRepository userRepository,
  })  : _ticketRepository = ticketRepository,
        _transactionRepository = transactionRepository,
        _userRepository = userRepository;

  // ---------------------------------------------------------------------------
  // computeMetrics
  // ---------------------------------------------------------------------------

  /// Queries live data and returns a [DashboardMetrics] snapshot.
  ///
  /// - [DashboardMetrics.activeVehicles] — count of open tickets
  ///   (Requirement 7.1).
  /// - [DashboardMetrics.activeUsers] — count of currently logged-in sessions
  ///   (Requirement 7.2).
  /// - [DashboardMetrics.dailyIncome] — sum of fees for transactions closed
  ///   since midnight of the current calendar day in device local time,
  ///   expressed in dollars (Requirement 7.3).
  /// - [DashboardMetrics.computedAt] — local timestamp of this computation.
  ///
  /// Throws a [DatabaseError] (wrapped in a [Failure]) if any repository call
  /// fails; the provider layer is responsible for catching and surfacing it.
  Future<DashboardMetrics> computeMetrics() async {
    final activeVehicles = await _ticketRepository.countOpen();
    final activeUsers = await _userRepository.countActiveSessions();
    final midnight = _todayMidnightLocal();
    final sumResult = await _transactionRepository.sumFeesSince(midnight);

    // Unwrap the Result — propagate DatabaseError as an exception so the
    // provider layer can set its error state.
    if (sumResult is Failure<int>) {
      throw sumResult.error;
    }
    final feeCents = (sumResult as Success<int>).value;

    // Convert integer cents to dollars for the model field.
    final dailyIncome = feeCents / 100.0;

    return DashboardMetrics(
      activeVehicles: activeVehicles,
      activeUsers: activeUsers,
      dailyIncome: dailyIncome,
      computedAt: DateTime.now(),
    );
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Returns a [DateTime] representing midnight (00:00:00.000) of the current
  /// calendar day in device local time.
  ///
  /// Using `DateTime(year, month, day)` without a time component produces a
  /// local-time midnight, which is the correct anchor for "today's income"
  /// (Requirement 7.3).
  DateTime _todayMidnightLocal() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }
}
