class DashboardMetrics {
  final int activeVehicles;
  final int activeUsers;
  final double dailyIncome;
  final DateTime computedAt;

  const DashboardMetrics({
    required this.activeVehicles,
    required this.activeUsers,
    required this.dailyIncome,
    required this.computedAt,
  });
}
