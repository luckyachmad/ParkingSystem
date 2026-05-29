// lib/core/providers.dart
//
// Central dependency injection wiring for the Parking System app.
//
// This file defines Riverpod providers for:
//   - DatabaseHelper (singleton)
//   - All repository implementations
//   - All service implementations
//
// Feature-level placeholder providers (authServiceProvider,
// pricingRepositoryProvider, ticketRepositoryProvider,
// transactionRepositoryProvider, dashboardServiceProvider) are defined in
// their respective feature files and are overridden in main.dart's
// ProviderScope using the concrete providers defined here.
//
// Requirements: all

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database_helper.dart';
import '../repositories/audit_log_repository.dart';
import '../repositories/pricing_repository.dart';
import '../repositories/ticket_repository.dart';
import '../repositories/transaction_repository.dart';
import '../repositories/user_repository.dart';
import '../services/auth_service.dart';
import '../services/dashboard_service.dart';
import '../services/fee_calculator.dart';

// ---------------------------------------------------------------------------
// DatabaseHelper
// ---------------------------------------------------------------------------

/// Provides the [DatabaseHelper] singleton.
///
/// All repository providers read this provider so that every repository
/// shares the same underlying database connection.
final databaseHelperProvider = Provider<DatabaseHelper>((ref) {
  return DatabaseHelper.instance;
});

// ---------------------------------------------------------------------------
// Repository providers
// ---------------------------------------------------------------------------

/// Provides the [UserRepository] implementation backed by SQLite.
final userRepositoryProvider = Provider<UserRepository>((ref) {
  final dbHelper = ref.watch(databaseHelperProvider);
  return UserRepositoryImpl(dbHelper);
});

/// Provides the [PricingRepository] implementation backed by SQLite.
///
/// This is the concrete provider that overrides the placeholder
/// [pricingRepositoryProvider] defined in vehicle_entry_provider.dart.
final concretePricingRepositoryProvider = Provider<PricingRepository>((ref) {
  final dbHelper = ref.watch(databaseHelperProvider);
  return PricingRepositoryImpl(dbHelper);
});

/// Provides the [TicketRepository] implementation backed by SQLite.
///
/// This is the concrete provider that overrides the placeholder
/// [ticketRepositoryProvider] defined in vehicle_entry_provider.dart.
final concreteTicketRepositoryProvider = Provider<TicketRepository>((ref) {
  final dbHelper = ref.watch(databaseHelperProvider);
  return TicketRepositoryImpl(dbHelper);
});

/// Provides the [TransactionRepository] implementation backed by SQLite.
///
/// This is the concrete provider that overrides the placeholder
/// [transactionRepositoryProvider] defined in vehicle_exit_provider.dart.
final concreteTransactionRepositoryProvider =
    Provider<TransactionRepository>((ref) {
  final dbHelper = ref.watch(databaseHelperProvider);
  return TransactionRepositoryImpl(dbHelper);
});

/// Provides the [AuditLogRepository] implementation backed by SQLite.
final auditLogRepositoryProvider = Provider<AuditLogRepository>((ref) {
  final dbHelper = ref.watch(databaseHelperProvider);
  return AuditLogRepositoryImpl(dbHelper);
});

// ---------------------------------------------------------------------------
// Service providers
// ---------------------------------------------------------------------------

/// Provides the [FeeCalculator] instance.
///
/// [FeeCalculator] is stateless so a single const instance is sufficient.
final concreteFeeCalculatorProvider = Provider<FeeCalculator>((ref) {
  return const FeeCalculator();
});

/// Provides the [AuthService] implementation.
///
/// This is the concrete provider that overrides the placeholder
/// [authServiceProvider] defined in auth_provider.dart.
final concreteAuthServiceProvider = Provider<AuthService>((ref) {
  final userRepository = ref.watch(userRepositoryProvider);
  final auditLogRepository = ref.watch(auditLogRepositoryProvider);
  return AuthService(
    userRepository: userRepository,
    auditLogRepository: auditLogRepository,
  );
});

/// Provides the [DashboardService] implementation.
///
/// This is the concrete provider that overrides the placeholder
/// [dashboardServiceProvider] defined in dashboard_provider.dart.
final concreteDashboardServiceProvider = Provider<DashboardService>((ref) {
  final ticketRepository = ref.watch(concreteTicketRepositoryProvider);
  final transactionRepository =
      ref.watch(concreteTransactionRepositoryProvider);
  final userRepository = ref.watch(userRepositoryProvider);
  return DashboardService(
    ticketRepository: ticketRepository,
    transactionRepository: transactionRepository,
    userRepository: userRepository,
  );
});
