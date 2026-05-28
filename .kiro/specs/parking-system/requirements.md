# Requirements Document

## Introduction

This document defines the requirements for a simple digital parking operations system targeting small parking operators. The system enables parking attendants to record vehicle arrivals and departures, calculates fees automatically based on configurable pricing rules, and provides parking owners with real-time visibility into daily income and lot activity. The system runs as a Flutter mobile application backed by a local SQLite database.

## Glossary

- **System**: The parking operations mobile application as a whole.
- **Attendant**: A parking staff member who records vehicle entry and exit events.
- **Owner**: The parking lot business owner who has full administrative access.
- **Admin**: A user with elevated permissions equivalent to Owner; may manage pricing, view reports, and configure the system.
- **Driver**: A vehicle owner who parks in the lot and pays the parking fee.
- **Ticket**: A record created at vehicle entry that tracks the plate number, entry time, and assigned pricing rule; closed upon vehicle exit.
- **Plate_Number**: The alphanumeric vehicle registration plate used as the primary identifier for linking entry and exit events.
- **Pricing_Rule**: A configurable fee structure (e.g., hourly rate, flat rate, grace period) applied to calculate the parking fee for a ticket.
- **Fee**: The monetary amount owed by a Driver, calculated from the Ticket duration and the applicable Pricing_Rule.
- **Transaction**: An immutable record of a completed parking session, including entry time, exit time, duration, fee charged, and payment status.
- **Dashboard**: The real-time summary screen showing active vehicles, active admins, and daily income.
- **Auth_Service**: The component responsible for user registration, login, session management, and route protection.
- **Fee_Calculator**: The centralized service responsible for computing parking fees from ticket duration and pricing rules.
- **Ticket_Repository**: The data access component responsible for creating, reading, and closing parking tickets.
- **Transaction_Repository**: The data access component responsible for writing and reading immutable transaction records.
- **Pricing_Repository**: The data access component responsible for CRUD operations on pricing rules.
- **User_Repository**: The data access component responsible for managing user accounts.
- **Dashboard_Service**: The service responsible for aggregating live metrics for the Dashboard.

---

## Requirements

### Requirement 1: User Registration

**User Story:** As a parking Owner, I want to register a new admin or attendant account, so that staff members can access the system with appropriate permissions.

#### Acceptance Criteria

1. THE Auth_Service SHALL support two roles: `owner` and `attendant`.
2. WHEN an Owner submits a registration form with a username between 3 and 50 characters containing only alphanumeric characters and underscores, a password between 8 and 128 characters, and a role, THE Auth_Service SHALL create a new user account with the credentials stored securely.
3. IF a registration is submitted with a username that already exists, THEN THE Auth_Service SHALL reject the registration and return an error message indicating that the username is already taken.
4. IF a registration is submitted with a password shorter than 8 characters or longer than 128 characters, THEN THE Auth_Service SHALL reject the registration and return an error message indicating the password length requirement.
5. IF a registration is submitted with a role value other than `owner` or `attendant`, THEN THE Auth_Service SHALL reject the registration and return an error message indicating the accepted role values.
6. WHEN a new user account is successfully created, THE Auth_Service SHALL log the creation event with a timestamp and the username of the acting Owner.

---

### Requirement 2: User Authentication

**User Story:** As an Attendant or Admin, I want to log in with my credentials, so that I can access the features permitted by my role.

#### Acceptance Criteria

1. WHEN a user submits a username between 1 and 50 characters and a password between 8 and 100 characters, THE Auth_Service SHALL authenticate the user and establish a session if the credentials are valid.
2. IF a user submits an incorrect username or password, THEN THE Auth_Service SHALL return a generic invalid-credentials error that does not reveal which field was incorrect, and reject the login.
3. IF a user submits incorrect credentials 5 consecutive times, THEN THE Auth_Service SHALL lock the account and require an Admin to unlock it before further login attempts are permitted.
4. WHILE a user session is active, THE System SHALL restrict navigation to screens permitted by the authenticated user's role: Attendants may access vehicle entry, vehicle exit, and transaction history screens; Admins and Owners may access all screens including pricing management and dashboard.
5. WHEN a user session has been idle for 30 consecutive minutes without interaction, THE Auth_Service SHALL automatically invalidate the session and redirect the user to the login screen.
6. WHEN a user logs out, THE Auth_Service SHALL invalidate the current session and redirect the user to the login screen.
7. IF an unauthenticated request is made to any protected route, THEN THE System SHALL redirect the user to the login screen.

---

### Requirement 3: Vehicle Entry

**User Story:** As an Attendant, I want to record a vehicle's arrival by entering its plate number, so that a parking ticket is created and the session is tracked from entry time.

#### Acceptance Criteria

1. WHEN an Attendant submits a Plate_Number on the entry screen, THE System SHALL validate that the Plate_Number is between 1 and 10 characters, contains only letters, digits, and hyphens, and has no spaces before creating a Ticket.
2. IF a Plate_Number submitted at entry does not match the accepted format, THEN THE System SHALL display an error message indicating the format requirement and prevent Ticket creation.
3. IF a Plate_Number submitted at entry already has an open Ticket, THEN THE System SHALL display a warning message and prevent creation of a duplicate Ticket.
4. WHEN a valid Plate_Number is submitted and no open Ticket exists for it, THE Ticket_Repository SHALL create a new Ticket recording the Plate_Number, entry timestamp (UTC), and the currently active Pricing_Rule snapshot.
5. WHEN a Ticket is successfully created, THE System SHALL display a confirmation to the Attendant showing the Plate_Number and entry time.
6. WHEN an Attendant submits a valid Plate_Number and no active Pricing_Rule exists, THEN THE System SHALL display an error message indicating that no active pricing rule is configured and prevent Ticket creation.

---

### Requirement 4: Vehicle Exit and Fee Calculation

**User Story:** As an Attendant, I want to record a vehicle's departure by entering its plate number, so that the parking fee is calculated automatically and the session is closed.

#### Acceptance Criteria

1. WHEN an Attendant submits a Plate_Number on the exit screen, THE System SHALL validate that the Plate_Number is between 1 and 10 characters, contains only letters, digits, and hyphens, and has no spaces before processing the exit.
2. IF a Plate_Number submitted at exit does not match the accepted format, THEN THE System SHALL display an error message indicating the format requirement and prevent exit processing.
3. IF a Plate_Number submitted at exit has no open Ticket, THEN THE System SHALL display an error message stating that no active parking session was found for the given plate number and prevent further processing.
4. WHEN a valid Plate_Number with an open Ticket is submitted, THE Fee_Calculator SHALL compute the Fee using the Pricing_Rule snapshotted on the Ticket and the duration in whole minutes (rounded up) from entry time to the current exit time.
5. WHEN the Fee is calculated, THE System SHALL display the Plate_Number, entry time, exit time, duration (in hours and minutes), and Fee (formatted to 2 decimal places with currency symbol) to the Attendant for confirmation before closing the Ticket.
6. IF the Attendant cancels the exit confirmation, THEN THE System SHALL discard the computed Fee and return to the exit entry screen without modifying the Ticket.
7. WHEN the Attendant confirms the exit, THE Ticket_Repository SHALL close the Ticket and THE Transaction_Repository SHALL write an immutable Transaction record containing the Plate_Number, entry time, exit time, duration, Fee, and payment status.
8. WHEN a Transaction is successfully written, THE System SHALL display a receipt summary showing the Plate_Number, entry time, exit time, duration, Fee, and payment status.

---

### Requirement 5: Fee Calculation Rules

**User Story:** As a parking Owner, I want fees to be calculated consistently from configurable pricing rules, so that revenue is accurate and no hardcoded rates exist in the system.

#### Acceptance Criteria

1. THE Fee_Calculator SHALL derive all fees exclusively from the Pricing_Rule values recorded on the Ticket at the time of vehicle entry; no fee values SHALL be hardcoded in the application.
2. WHEN a Pricing_Rule defines an hourly rate, THE Fee_Calculator SHALL compute the Fee by multiplying the rate by the number of hours parked, rounding up to the next full hour.
3. WHERE a Pricing_Rule includes a grace period expressed in whole minutes, THE Fee_Calculator SHALL charge zero fee for parking sessions whose duration is less than or equal to the grace period.
4. WHERE a Pricing_Rule includes a daily maximum cap, THE Fee_Calculator SHALL apply the cap to any session not exceeding 24 hours, capping the Fee at the daily maximum after all other calculations are applied.
5. THE Fee_Calculator SHALL produce a Fee that is greater than or equal to zero for all Tickets where entry time is less than or equal to exit time.
6. IF the Pricing_Rule snapshot on a Ticket is missing or contains invalid values, THEN THE Fee_Calculator SHALL return an error and THE System SHALL surface a descriptive error to the Attendant without closing the Ticket.

---

### Requirement 6: Pricing Rule Management

**User Story:** As a parking Owner or Admin, I want to create, view, update, and deactivate pricing rules, so that I can adjust rates without modifying application code.

#### Acceptance Criteria

1. THE Pricing_Repository SHALL support creating a new Pricing_Rule with a unique name between 1 and 100 characters, a rate type (hourly or flat), a rate amount between 0.01 and 999,999.99 with up to 2 decimal places, an optional grace period between 0 and 60 minutes, and an optional daily maximum cap between 0.01 and 999,999.99.
2. WHEN an Owner or Admin saves a new or updated Pricing_Rule, THE System SHALL validate that the rate amount is within the accepted range and that the name is unique among active rules before persisting the rule.
3. IF a Pricing_Rule save is submitted with a rate amount outside the accepted range, a duplicate name, or a name that is empty, THEN THE Pricing_Repository SHALL reject the save and return an error message indicating which field failed and why.
4. WHEN a Pricing_Rule is updated or deactivated, THE System SHALL NOT retroactively modify any open Ticket that has already snapshotted the previous rule's name, rate type, rate amount, grace period, and daily cap values.
5. THE Pricing_Repository SHALL support marking a Pricing_Rule as inactive; inactive rules SHALL NOT appear in the active rule selection list when creating a new Ticket.
6. WHEN an Owner or Admin views the pricing rules list, THE System SHALL display all active rules and indicate which rule is currently the default.
7. THE System SHALL enforce that exactly one active Pricing_Rule is designated as the default at any time; designating a new default SHALL automatically remove the default designation from the previously designated rule.
8. WHEN an Attendant initiates vehicle entry and no active Pricing_Rule exists, THEN THE System SHALL display an error message indicating that no active pricing rule is configured and prevent Ticket creation.

---

### Requirement 7: Dashboard

**User Story:** As a parking Owner or Admin, I want a real-time dashboard, so that I can see how many vehicles are currently parked, how many admins are active, and how much income has been collected today.

#### Acceptance Criteria

1. WHEN an Owner or Admin opens the Dashboard, THE Dashboard_Service SHALL query live transaction and ticket data to compute the current count of open Tickets (active vehicles).
2. WHEN an Owner or Admin opens the Dashboard, THE Dashboard_Service SHALL query live user session data to compute the count of currently logged-in Admins and Attendants.
3. WHEN an Owner or Admin opens the Dashboard, THE Dashboard_Service SHALL sum the fees of all Transactions whose associated Ticket was closed since midnight of the current calendar day in device local time to produce the daily income figure.
4. WHILE the Dashboard screen is open, THE System SHALL refresh the active vehicle count, active admin count, and daily income at an interval not exceeding 30 seconds.
5. THE Dashboard_Service SHALL derive all metrics by querying live database records at the time of each computation; no pre-aggregated or cached values SHALL be used as the source of truth.
6. IF a Dashboard refresh fails due to a database error, THEN THE System SHALL retain the last successfully computed metric values on screen and display an error indicator informing the user that the data may be stale.

---

### Requirement 8: Transaction History

**User Story:** As a parking Owner or Admin, I want to search and review all past parking transactions, so that I can audit revenue, resolve disputes, and detect anomalies.

#### Acceptance Criteria

1. THE Transaction_Repository SHALL expose a query interface that accepts optional filters for date range, Plate_Number substring, and payment status (one of: `paid`, `unpaid`, or `cancelled`).
2. WHEN an Owner or Admin applies search filters, THE System SHALL return only Transactions matching all supplied filter criteria, ordered by exit time descending with open Tickets (null exit time) listed last.
3. WHEN no filters are applied, THE System SHALL return all Transactions ordered by exit time descending, with open Tickets (null exit time) listed last.
4. THE Transaction_Repository SHALL enforce immutability: no UPDATE or DELETE operations SHALL be permitted on Transaction records after they are written.
5. WHEN an Owner or Admin selects a Transaction from the list, THE System SHALL display the full detail: Plate_Number, entry time, exit time, duration (formatted as hours and minutes, e.g., 1h 30m), Pricing_Rule name, Fee, and payment status.
6. IF a search query returns no results, THEN THE System SHALL display a message containing the text "No transactions found" and no error indicator.

---

### Requirement 9: Role-Based Access Control

**User Story:** As a parking Owner, I want role-based access control enforced throughout the app, so that Attendants can only perform operational tasks and cannot access administrative functions.

#### Acceptance Criteria

1. WHILE an Attendant session is active, THE System SHALL ensure that pricing management, dashboard, and transaction history screens are not rendered or reachable via any navigation path.
2. WHILE an Owner or Admin session is active, THE System SHALL grant access to all screens: vehicle entry, vehicle exit, transaction history, pricing management, and dashboard.
3. IF an Attendant attempts to navigate to a restricted screen, THEN THE System SHALL redirect the user to the vehicle entry screen and display an access-denied message indicating the role-based denial reason.
4. THE Auth_Service SHALL embed the user's role in the session state and THE System SHALL evaluate role permissions on every navigation event.
5. IF the session state contains an absent or unrecognized role value, THEN THE System SHALL invalidate the session, redirect the user to the login screen, and display an error message indicating that the session is invalid.

---

### Requirement 10: Data Integrity and Auditability

**User Story:** As a parking Owner, I want all transactions and system events to be permanently logged, so that I have a complete, tamper-evident audit trail.

#### Acceptance Criteria

1. WHEN a Transaction record is written, THE System SHALL ensure that the record's fields (Plate_Number, entry time, exit time, duration, Fee, payment status) remain unchanged for the lifetime of the record; no application code path SHALL issue UPDATE or DELETE statements against the transactions table.
2. WHEN a Ticket is created or closed, THE System SHALL record the username of the acting Attendant and a UTC timestamp in the Ticket record.
3. WHEN a user successfully logs in, THE System SHALL log the event with a UTC timestamp and the username involved.
4. WHEN a user logs out, THE System SHALL log the event with a UTC timestamp and the username involved.
5. WHEN a login attempt fails, THE System SHALL log the event with a UTC timestamp and the username involved.
6. IF a database write operation fails, THEN THE System SHALL surface an error to the user that includes the operation that failed and SHALL NOT silently discard the failure or leave the application in an inconsistent state.
7. THE System SHALL use parameterized queries for all database operations to prevent SQL injection.
