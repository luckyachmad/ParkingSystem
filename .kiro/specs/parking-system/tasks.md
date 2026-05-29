# Implementation Plan: Parking System

## Overview

Implement a Flutter/Dart mobile parking operations app backed by a local SQLite database. The build follows the layered architecture defined in the design: DatabaseHelper → Repositories → Services → Providers → UI. Each task builds on the previous, ending with full integration. All monetary values are stored as integer cents; all timestamps as UTC epoch milliseconds.

## Tasks

- [x] 1. Project setup and database foundation
  - Add `sqflite`, `path`, `flutter_riverpod`, `intl`, and `dart_bcrypt` (or equivalent) to `pubspec.yaml`
  - Create the folder structure: `lib/core/`, `lib/database/`, `lib/models/`, `lib/repositories/`, `lib/services/`, `lib/features/auth/`, `lib/features/vehicle_entry/`, `lib/features/vehicle_exit/`, `lib/features/pricing/`, `lib/features/dashboard/`, `lib/features/transactions/`
  - Create `lib/core/result.dart` — define `Result<T>`, `Success<T>`, `Failure<T>`, `AppError`, `ValidationError`, `BusinessError`, `DatabaseError`, `SessionError` sealed classes
  - Create `lib/core/money.dart` — define `Money` value type wrapping integer cents with `toDisplay()` helper
  - _Requirements: 10.6, 10.7_

  - [x] 1.1 Implement DatabaseHelper singleton with schema creation
    - Create `lib/database/database_helper.dart` with singleton pattern, `_dbName`, `_dbVersion = 1`
    - Implement `get database` lazy initializer, `_initDatabase()`, `_onCreate()` running all five `CREATE TABLE` statements (users, pricing_rules, tickets, transactions, audit_log) and the three `CREATE INDEX` statements from the design schema
    - Implement `_onUpgrade()` stub for future migrations
    - _Requirements: 10.7_

  - [x] 1.2 Write unit tests for DatabaseHelper schema creation
    - Verify all five tables exist after `_onCreate`
    - Verify all three indexes exist
    - Verify `_onUpgrade` is callable without error
    - _Requirements: 10.7_


- [x] 2. Data models
  - [x] 2.1 Implement core Dart model classes
    - Create `lib/models/user.dart` — `User` class with all fields from design; `Role` enum (`owner`, `attendant`); `toMap()`/`fromMap()` for SQLite serialization (epoch ms for `createdAt`, 0/1 for booleans)
    - Create `lib/models/pricing_rule.dart` — `PricingRule` class; `RateType` enum (`hourly`, `flat`); `toMap()`/`fromMap()` converting cents ↔ double
    - Create `lib/models/ticket.dart` — `Ticket` class with all snapshot fields; `toMap()`/`fromMap()`
    - Create `lib/models/parking_transaction.dart` — `ParkingTransaction` class; `PaymentStatus` enum; `toMap()`/`fromMap()`
    - Create `lib/models/audit_event.dart` — `AuditEvent` class; `AuditEventType` enum; `toMap()`/`fromMap()`
    - Create `lib/models/dashboard_metrics.dart` — `DashboardMetrics` class
    - Create `lib/models/transaction_filter.dart` — `TransactionFilter` class with all optional filter fields
    - _Requirements: 3.4, 4.7, 5.1, 6.1, 7.1, 8.1_

  - [x] 2.2 Write property test for ParkingTransaction round-trip serialization
    - **Property 24: Transaction record is identical after round-trip write and read**
    - **Validates: Requirements 8.4, 10.1**
    - Use `fast_check` generator to produce arbitrary `ParkingTransaction` values; assert `fromMap(toMap(tx))` equals original
    - _Test file: `test/unit/repositories/transaction_repository_test.dart`_


- [x] 3. Plate number validation utility
  - [x] 3.1 Implement plate number validator
    - Create `lib/core/plate_validator.dart` — `PlateValidator.validate(String input)` returning `Result<String>` using regex `^[A-Za-z0-9\-]{1,10}$`; return `ValidationError` for any non-matching input
    - _Requirements: 3.1, 3.2, 4.1, 4.2_

  - [x] 3.2 Write property test for plate number validation
    - **Property 1: Valid plate numbers are accepted; invalid ones are rejected**
    - **Validates: Requirements 3.1, 3.2, 4.1, 4.2**
    - Use `validPlateGen` (charset A-Za-z0-9-, length 1–10) — assert all accepted
    - Use `invalidPlateGen` (empty, length > 10, spaces/special chars) — assert all rejected with `ValidationError`
    - _Test file: `test/unit/validation/plate_validator_test.dart`_

- [x] 4. Repository layer
  - [x] 4.1 Implement UserRepository
    - Create `lib/repositories/user_repository.dart` — abstract interface + `UserRepositoryImpl` accepting `DatabaseHelper`
    - Implement `findByUsername(String username)` — parameterized SELECT
    - Implement `insert(User user)` — parameterized INSERT; return inserted id
    - Implement `updateLockStatus(int userId, bool locked)` — parameterized UPDATE
    - Implement `updateFailedAttempts(int userId, int count)` — parameterized UPDATE
    - Add `countActiveSessions()` stub returning 0 (session tracking added in Task 6)
    - Wrap all writes in try/catch; return `Failure<DatabaseError>` on exception
    - _Requirements: 1.2, 2.3, 10.7_


  - [x] 4.2 Implement PricingRepository
    - Create `lib/repositories/pricing_repository.dart` — abstract interface + `PricingRepositoryImpl`
    - Implement `insert(PricingRule rule)` — validate name uniqueness among active rules before INSERT; return `Failure<BusinessError>` on duplicate name or invalid rate
    - Implement `findDefault()` — SELECT WHERE `is_default = 1 AND is_active = 1`
    - Implement `findAllActive()` — SELECT WHERE `is_active = 1`
    - Implement `update(PricingRule rule)` — parameterized UPDATE; validate name uniqueness excluding self
    - Implement `setDefault(int ruleId)` — UPDATE all active rules to `is_default = 0`, then UPDATE target rule to `is_default = 1` in a single SQLite transaction
    - Implement `deactivate(int ruleId)` — UPDATE `is_active = 0`; if rule was default, clear default flag
    - _Requirements: 6.1, 6.2, 6.3, 6.5, 6.7_

  - [x] 4.3 Write property tests for PricingRepository
    - **Property 17: Deactivated pricing rule is excluded from active rule list** — **Validates: Requirements 6.5**
    - **Property 18: Exactly one pricing rule is the default at all times** — **Validates: Requirements 6.7**
    - **Property 19: Pricing rule creation and retrieval round-trip** — **Validates: Requirements 6.1**
    - **Property 20: Invalid pricing rule fields are rejected** — **Validates: Requirements 6.2, 6.3**
    - Use in-memory SQLite database for each test run
    - _Test file: `test/unit/repositories/pricing_repository_test.dart`_

  - [x] 4.4 Implement TicketRepository
    - Create `lib/repositories/ticket_repository.dart` — abstract interface + `TicketRepositoryImpl`
    - Implement `insert(Ticket ticket)` — check `findOpenByPlate` first; return `Failure<BusinessError>` if open ticket exists; otherwise INSERT with all snapshot fields
    - Implement `findOpenByPlate(String plateNumber)` — SELECT WHERE `plate_number = ? AND exit_time IS NULL` using `idx_tickets_plate_open`
    - Implement `findAllOpen()` — SELECT WHERE `exit_time IS NULL`
    - Implement `closeTicket(int ticketId, DateTime exitTime, String closedBy)` — UPDATE `exit_time` and `closed_by`
    - Implement `countOpen()` — SELECT COUNT WHERE `exit_time IS NULL`
    - _Requirements: 3.3, 3.4, 4.7, 10.2_


  - [x] 4.5 Write property tests for TicketRepository
    - **Property 10: Duplicate open ticket is prevented** — **Validates: Requirements 3.3**
    - **Property 11: Ticket creation preserves the pricing rule snapshot** — **Validates: Requirements 3.4, 6.4**
    - **Property 16: Pricing rule snapshot on open ticket is immutable after rule update** — **Validates: Requirements 6.4**
    - **Property 28: Exit confirmation creates a closed ticket and a matching transaction** — **Validates: Requirements 4.7**
    - Use in-memory SQLite database for each test run
    - _Test file: `test/unit/repositories/ticket_repository_test.dart`_

  - [x] 4.6 Implement TransactionRepository
    - Create `lib/repositories/transaction_repository.dart` — abstract interface + `TransactionRepositoryImpl`
    - Implement `insert(ParkingTransaction transaction)` — INSERT only; no UPDATE/DELETE paths exist
    - Implement `findById(int id)` — SELECT by primary key
    - Implement `query(TransactionFilter filter)` — build parameterized WHERE clause from optional filter fields (date range as epoch ms, plate LIKE `%substring%`, payment_status); ORDER BY `exit_time DESC NULLS LAST`
    - Implement `sumFeesSince(DateTime since)` — SELECT SUM(fee_cents) WHERE `exit_time >= ?`
    - _Requirements: 4.7, 8.1, 8.2, 8.3, 8.4, 10.1_

  - [x] 4.7 Write property tests for TransactionRepository
    - **Property 23: Transaction query returns only matching records, ordered correctly** — **Validates: Requirements 8.1, 8.2, 8.3**
    - **Property 24: Transaction record is identical after round-trip write and read** — **Validates: Requirements 8.4, 10.1**
    - Use in-memory SQLite database; generate arbitrary `ParkingTransaction` sets with `fast_check`
    - _Test file: `test/unit/repositories/transaction_repository_test.dart`_

  - [x] 4.8 Implement AuditLogRepository
    - Create `lib/repositories/audit_log_repository.dart` — abstract interface + `AuditLogRepositoryImpl`
    - Implement `log(AuditEvent event)` — INSERT into `audit_log`; wrap in try/catch; log failure to console if write fails (never throw from audit log)
    - _Requirements: 1.6, 10.3, 10.4, 10.5_


- [x] 5. Checkpoint — Repository layer complete
  - Ensure all tests pass, ask the user if questions arise.

- [x] 6. Service layer
  - [x] 6.1 Implement FeeCalculator
    - Create `lib/services/fee_calculator.dart` — stateless class with `Money calculate(PricingRule rule, int durationMinutes)`
    - Implement the four-step algorithm from the design: grace period check → base fee (flat or hourly with `ceil`) → daily cap (only when `durationMinutes <= 1440`) → floor at zero
    - All arithmetic in integer cents; return `Money` wrapping cents
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5_

  - [x] 6.2 Write property tests for FeeCalculator
    - **Property 12: Fee is non-negative for all valid inputs** — **Validates: Requirements 5.5**
    - **Property 13: Hourly fee equals ceiling-hours times rate** — **Validates: Requirements 5.2**
    - **Property 14: Grace period produces zero fee** — **Validates: Requirements 5.3**
    - **Property 15: Daily cap is never exceeded for sessions ≤ 24 hours** — **Validates: Requirements 5.4**
    - Use `validPricingRuleGen` and `durationMinutesGen` generators; minimum 100 iterations each
    - _Test file: `test/unit/services/fee_calculator_test.dart`_

  - [x] 6.3 Implement AuthService
    - Create `lib/services/auth_service.dart` — `AuthService` accepting `UserRepository` and `AuditLogRepository`
    - Implement `register(RegisterRequest request)` — validate username (3–50 alphanumeric+underscore) and password (8–128 chars); check uniqueness; hash password with `dart_bcrypt`; insert user; log `userCreated` audit event; return `Result<User>`
    - Implement `login(LoginRequest request)` — validate input lengths; fetch user; check `isLocked`; verify hash; on failure increment `failedAttempts` (lock at 5); on success reset `failedAttempts`; log `login` or `loginFailed`; return `Result<AuthSession>`
    - Implement `logout(int userId)` — log `logout` audit event; return void
    - Implement `unlockAccount(int userId)` — reset `isLocked = false` and `failedAttempts = 0`
    - _Requirements: 1.2, 1.3, 1.4, 1.5, 1.6, 2.1, 2.2, 2.3, 2.6, 10.3, 10.4, 10.5_


  - [x] 6.4 Write property tests for AuthService
    - **Property 2: Successful registration creates a retrievable user** — **Validates: Requirements 1.2**
    - **Property 3: Duplicate username registration is rejected** — **Validates: Requirements 1.3**
    - **Property 4: Out-of-range passwords are rejected at registration** — **Validates: Requirements 1.4**
    - **Property 5: Successful registration produces an audit log entry** — **Validates: Requirements 1.6**
    - **Property 6: Valid credentials produce an authenticated session** — **Validates: Requirements 2.1**
    - **Property 7: Invalid credentials return a generic error** — **Validates: Requirements 2.2**
    - **Property 8: Five consecutive failed logins lock the account** — **Validates: Requirements 2.3**
    - **Property 9: Logout invalidates the session** — **Validates: Requirements 2.6**
    - Use in-memory SQLite database; generate valid/invalid username and password strings with `fast_check`
    - _Test file: `test/unit/services/auth_service_test.dart`_

  - [x] 6.5 Implement DashboardService
    - Create `lib/services/dashboard_service.dart` — `DashboardService` accepting `TicketRepository`, `TransactionRepository`, `UserRepository`
    - Implement `computeMetrics()` — call `ticketRepository.countOpen()`, `userRepository.countActiveSessions()`, compute today's midnight in local time, call `transactionRepository.sumFeesSince(midnight)`, return `DashboardMetrics`
    - _Requirements: 7.1, 7.2, 7.3, 7.5_

  - [x]* 6.6 Write property tests for DashboardService
    - **Property 21: Dashboard active vehicle count matches open ticket count** — **Validates: Requirements 7.1, 7.5**
    - **Property 22: Dashboard daily income equals sum of today's transaction fees** — **Validates: Requirements 7.3, 7.5**
    - Seed in-memory database with known ticket/transaction sets; assert metrics match expected values
    - _Test file: `test/unit/services/dashboard_service_test.dart`_


  - [x]* 6.7 Write property test for audit log events
    - **Property 27: Authentication events are logged to the audit trail** — **Validates: Requirements 10.3, 10.4, 10.5**
    - For each of login, loginFailed, logout: assert `AuditLog` contains exactly one entry with correct `eventType`, username, and UTC timestamp ≥ event start time
    - _Test file: `test/unit/repositories/audit_log_repository_test.dart`_

- [x] 7. Checkpoint — Service layer complete
  - Ensure all tests pass, ask the user if questions arise.

- [x] 8. State management — Providers
  - [x] 8.1 Implement AuthProvider and session timeout
    - Create `lib/features/auth/auth_provider.dart` — `AuthNotifier extends StateNotifier<AuthState>` with `AuthState` sealed class (`Unauthenticated`, `Authenticated`)
    - Implement `login()`, `logout()`, `register()` methods delegating to `AuthService`; update state on success/failure
    - Implement inactivity timer: `Timer` reset on `resetTimer()` call; after 30 minutes call `logout()` automatically
    - Expose `authProvider = StateNotifierProvider<AuthNotifier, AuthState>`
    - _Requirements: 2.1, 2.5, 2.6, 9.4_

  - [x] 8.2 Implement VehicleEntryProvider
    - Create `lib/features/vehicle_entry/vehicle_entry_provider.dart` — `VehicleEntryNotifier extends StateNotifier<VehicleEntryState>`
    - `VehicleEntryState` holds: `plateInput`, `isLoading`, `error`, `lastCreatedTicket`
    - Implement `submitEntry(String plate, String createdBy)` — call `PlateValidator`, call `PricingRepository.findDefault()`, call `TicketRepository.insert()`; update state with success or typed error
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6_

  - [x] 8.3 Implement VehicleExitProvider
    - Create `lib/features/vehicle_exit/vehicle_exit_provider.dart` — `VehicleExitNotifier extends StateNotifier<VehicleExitState>`
    - `VehicleExitState` holds: `plateInput`, `openTicket`, `computedFee`, `durationMinutes`, `isLoading`, `error`, `confirmed`
    - Implement `lookupPlate(String plate)` — validate plate, call `TicketRepository.findOpenByPlate()`; compute `durationMinutes = (rawSeconds / 60).ceil()`; call `FeeCalculator.calculate()`; update state
    - Implement `confirmExit(String closedBy)` — call `TicketRepository.closeTicket()`, call `TransactionRepository.insert()`; update state with receipt data
    - Implement `cancelExit()` — reset state without modifying ticket
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8_


  - [x] 8.4 Implement PricingProvider
    - Create `lib/features/pricing/pricing_provider.dart` — `PricingNotifier extends StateNotifier<PricingState>`
    - `PricingState` holds: `rules` (list), `isLoading`, `error`
    - Implement `loadRules()` — call `PricingRepository.findAllActive()`
    - Implement `addRule(PricingRule rule)` — call `PricingRepository.insert()`; reload on success
    - Implement `updateRule(PricingRule rule)` — call `PricingRepository.update()`; reload on success
    - Implement `deactivateRule(int ruleId)` — call `PricingRepository.deactivate()`; reload on success
    - Implement `setDefault(int ruleId)` — call `PricingRepository.setDefault()`; reload on success
    - _Requirements: 6.1, 6.2, 6.3, 6.5, 6.6, 6.7_

  - [x] 8.5 Implement TransactionProvider
    - Create `lib/features/transactions/transaction_provider.dart` — `TransactionNotifier extends StateNotifier<TransactionState>`
    - `TransactionState` holds: `transactions` (list), `filter`, `isLoading`, `error`
    - Implement `loadTransactions(TransactionFilter filter)` — call `TransactionRepository.query(filter)`; update state
    - Implement `clearFilter()` — reset filter and reload
    - _Requirements: 8.1, 8.2, 8.3_

  - [x] 8.6 Implement DashboardProvider
    - Create `lib/features/dashboard/dashboard_provider.dart` — `DashboardNotifier extends AsyncNotifier<DashboardMetrics>`
    - Implement `build()` — call `DashboardService.computeMetrics()`
    - Implement `refresh()` — re-invoke `computeMetrics()`; on `DatabaseError` retain last value and set stale flag
    - Wire `Timer.periodic(Duration(seconds: 30), ...)` to call `refresh()` while screen is mounted
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6_

- [x] 9. Route guard and navigation
  - [x] 9.1 Implement route configuration and navigation guard
    - Add `go_router` package to `pubspec.yaml`
    - Create `lib/core/router.dart` — define all routes from the route table (`/login`, `/register`, `/vehicle-entry`, `/vehicle-exit`, `/vehicle-exit/receipt`, `/transactions`, `/pricing`, `/dashboard`)
    - Implement `_redirect` callback: if `Unauthenticated` → `/login`; if `role == attendant` and target is admin-only route → `/vehicle-entry` + set access-denied flag; if unrecognized role → invalidate session + `/login`
    - Wire `authProvider` into the router notifier so route guard re-evaluates on every auth state change
    - _Requirements: 2.4, 2.7, 9.1, 9.2, 9.3, 9.4, 9.5_

  - [x]* 9.2 Write widget tests for route guard
    - **Property 25: Attendant session cannot reach admin-only routes** — **Validates: Requirements 9.1, 9.3**
    - **Property 26: Owner/Admin session can reach all routes** — **Validates: Requirements 9.2**
    - For each admin-only route (`/pricing`, `/dashboard`, `/register`): pump widget tree with attendant session; assert redirect to `/vehicle-entry`
    - For each route: pump with owner session; assert target screen is rendered
    - _Test file: `test/widget/route_guard_test.dart`_


- [x] 10. Checkpoint — Providers and routing complete
  - Ensure all tests pass, ask the user if questions arise.

- [x] 11. UI screens — Authentication
  - [x] 11.1 Implement Login screen
    - Create `lib/features/auth/login_screen.dart` — `StatelessWidget` with username and password `TextField`s, login button, and "Register" navigation link
    - On submit: call `authProvider.notifier.login()`; on `Authenticated` navigate per role (owner → `/dashboard`, attendant → `/vehicle-entry`); on error display inline snackbar with generic message
    - Wrap root navigator with `GestureDetector` that calls `authProvider.notifier.resetTimer()` on any tap/scroll
    - _Requirements: 2.1, 2.2, 2.5_

  - [x] 11.2 Implement Registration screen
    - Create `lib/features/auth/registration_screen.dart` — `StatelessWidget` with username, password, role dropdown (`owner`/`attendant`), and submit button
    - On submit: call `authProvider.notifier.register()`; on success navigate to `/login` with success snackbar; on `ValidationError` display inline field error; on `BusinessError` display snackbar
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5_

- [x] 12. UI screens — Vehicle operations
  - [x] 12.1 Implement Vehicle Entry screen
    - Create `lib/features/vehicle_entry/vehicle_entry_screen.dart` — plate number `TextField`, submit button, confirmation display area
    - On submit: call `vehicleEntryProvider.notifier.submitEntry()`; on success show confirmation card with plate and entry time; on `ValidationError` show inline field error; on `BusinessError` (duplicate plate, no pricing rule) show snackbar
    - _Requirements: 3.1, 3.2, 3.3, 3.5, 3.6_

  - [x] 12.2 Implement Vehicle Exit screen
    - Create `lib/features/vehicle_exit/vehicle_exit_screen.dart` — plate number `TextField`, lookup button, fee summary card (plate, entry time, exit time, duration, fee), confirm/cancel buttons
    - On lookup: call `vehicleExitProvider.notifier.lookupPlate()`; display fee summary on success
    - On confirm: call `vehicleExitProvider.notifier.confirmExit()`; navigate to `/vehicle-exit/receipt`
    - On cancel: call `vehicleExitProvider.notifier.cancelExit()`; reset form
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6_

  - [x] 12.3 Implement Receipt screen
    - Create `lib/features/vehicle_exit/receipt_screen.dart` — display plate, entry time, exit time, duration (formatted as `Xh Ym`), fee (formatted to 2 decimal places with currency symbol), payment status
    - Provide "New Exit" button navigating back to `/vehicle-exit`
    - _Requirements: 4.8, 8.5_


- [x] 13. UI screens — Admin features
  - [x] 13.1 Implement Pricing Management screen
    - Create `lib/features/pricing/pricing_screen.dart` — list of active pricing rules showing name, rate type, rate amount, grace period, daily cap, default indicator; FAB to add new rule; tap rule to edit/deactivate
    - Implement add/edit form as a modal bottom sheet or dialog: fields for name, rate type, rate amount, grace period (optional), daily cap (optional); validate on submit via `pricingProvider`
    - On deactivate: show confirmation dialog; call `pricingProvider.notifier.deactivateRule()`
    - On set default: call `pricingProvider.notifier.setDefault()`
    - _Requirements: 6.1, 6.2, 6.3, 6.5, 6.6, 6.7_

  - [x] 13.2 Implement Dashboard screen
    - Create `lib/features/dashboard/dashboard_screen.dart` — three metric cards: active vehicles, active users, daily income (formatted with currency symbol and 2 decimal places); last-updated timestamp; stale data indicator banner
    - Watch `dashboardProvider`; show loading indicator on initial load; on error retain last values and show stale banner
    - Start `Timer.periodic` in `initState` equivalent (use `ref.onDispose` to cancel timer)
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6_

  - [x]* 13.3 Write widget test for Dashboard stale data indicator
    - Simulate a `DatabaseError` on `DashboardService.computeMetrics()` after initial load
    - Assert last metric values remain visible and stale data banner is shown
    - _Test file: `test/widget/dashboard_screen_test.dart`_

  - [x] 13.4 Implement Transaction History screen
    - Create `lib/features/transactions/transaction_history_screen.dart` — search bar (plate substring), date range pickers, payment status dropdown filter; scrollable list of transaction rows
    - Each row shows plate, exit time, duration, fee, payment status; tap to open detail bottom sheet with all fields from Requirement 8.5
    - On empty results: display "No transactions found" message (no error indicator)
    - Watch `transactionProvider`; call `loadTransactions()` on filter change
    - _Requirements: 8.1, 8.2, 8.3, 8.5, 8.6_


- [x] 14. Checkpoint — All screens complete
  - Ensure all tests pass, ask the user if questions arise.

- [x] 15. Integration wiring and end-to-end flows
  - [x] 15.1 Wire dependency injection — connect all layers via ProviderScope
    - Create `lib/core/providers.dart` — define Riverpod providers for `DatabaseHelper`, all repositories, all services
    - Override repository and service providers in `ProviderScope` at `main.dart`; ensure `DatabaseHelper.instance` is passed to all repository constructors
    - Wrap `MaterialApp.router` with `ProviderScope`; pass `router` from `lib/core/router.dart`
    - _Requirements: all_

  - [x] 15.2 Implement app entry point and theme
    - Create/update `lib/main.dart` — `ProviderScope` wrapping `MaterialApp.router`; apply `ThemeData` from `lib/core/theme.dart`
    - Create `lib/core/theme.dart` — define `AppTheme` with color scheme, text styles, and input decoration theme consistent across all screens
    - _Requirements: all_

  - [x]* 15.3 Write integration test for vehicle entry flow
    - Seed database with one active pricing rule and an authenticated attendant session
    - Submit a valid plate number; assert ticket is created with correct snapshot fields; assert confirmation is displayed
    - Submit the same plate again; assert `BusinessError` is returned and no duplicate ticket is created
    - _Test file: `test/integration/vehicle_entry_flow_test.dart`_

  - [x]* 15.4 Write integration test for vehicle exit flow
    - Seed database with an open ticket; simulate exit confirmation
    - Assert ticket `exit_time` is set; assert `ParkingTransaction` record is written with matching fields; assert receipt screen displays correct fee
    - _Test file: `test/integration/vehicle_exit_flow_test.dart`_

  - [x]* 15.5 Write integration test for auth flow
    - Register a new user; assert user is retrievable; assert `userCreated` audit event exists
    - Login with correct credentials; assert `Authenticated` state; assert `login` audit event exists
    - Submit wrong password 5 times; assert account is locked; assert `loginFailed` audit events exist
    - Logout; assert `Unauthenticated` state; assert `logout` audit event exists
    - _Test file: `test/integration/auth_flow_test.dart`_

- [ ] 16. Final checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.


## Notes

- Tasks marked with `*` are optional and can be skipped for a faster MVP build
- All monetary values are stored as integer cents in SQLite; convert to/from `double` only at the display layer using `intl`
- All timestamps are stored as UTC epoch milliseconds; convert to local time only in UI formatting
- Property tests use `fast_check` (or `dart_quickcheck`) with a minimum of 100 iterations each
- Each property test file includes a comment referencing the design property number (e.g., `// Feature: parking-system, Property 13`)
- Checkpoints at Tasks 5, 7, 10, 14, and 16 ensure incremental validation before proceeding
- The `Result<T>` pattern is used throughout services and repositories — never throw across layer boundaries
- `go_router` is the recommended navigation package; add it to `pubspec.yaml` in Task 9.1

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["1.2", "2.1"] },
    { "id": 2, "tasks": ["2.2", "3.1"] },
    { "id": 3, "tasks": ["3.2", "4.1", "4.2", "4.4", "4.6", "4.8"] },
    { "id": 4, "tasks": ["4.3", "4.5", "4.7", "6.1"] },
    { "id": 5, "tasks": ["6.2", "6.3"] },
    { "id": 6, "tasks": ["6.4", "6.5"] },
    { "id": 7, "tasks": ["6.6", "6.7", "8.1"] },
    { "id": 8, "tasks": ["8.2", "8.3", "8.4", "8.5", "8.6"] },
    { "id": 9, "tasks": ["9.1"] },
    { "id": 10, "tasks": ["9.2", "11.1", "11.2"] },
    { "id": 11, "tasks": ["12.1", "12.2", "12.3"] },
    { "id": 12, "tasks": ["13.1", "13.2", "13.4"] },
    { "id": 13, "tasks": ["13.3", "15.1"] },
    { "id": 14, "tasks": ["15.2"] },
    { "id": 15, "tasks": ["15.3", "15.4", "15.5"] }
  ]
}
```
