# Parking System

A Flutter mobile application that digitizes parking lot operations for small parking operators. It runs entirely on-device with a local SQLite database — no backend server or internet connection required.

---

## Overview

The app covers the full vehicle lifecycle: attendants record arrivals and departures, fees are calculated automatically from configurable pricing rules, and owners get a real-time dashboard showing active vehicles and daily income. Every transaction is permanently logged for auditability.

---

## Features

| Feature | Description |
|---|---|
| **Authentication** | Registration and login for owners and attendants, with account lockout after 5 failed attempts and a 30-minute inactivity timeout |
| **Vehicle Entry** | Record a vehicle's arrival by plate number; creates a timestamped parking ticket with a snapshot of the active pricing rule |
| **Vehicle Exit** | Record a vehicle's departure; calculates the fee automatically and writes an immutable transaction record |
| **Pricing Rules** | Create, update, and deactivate pricing tiers (hourly or flat rate, optional grace period, optional daily cap) |
| **Dashboard** | Real-time view of active vehicles, logged-in users, and daily income — refreshes every 30 seconds |
| **Transaction History** | Searchable, filterable log of all completed parking sessions |

---

## User Roles

| Role | Access |
|---|---|
| **Owner / Admin** | All screens: dashboard, pricing management, transaction history, vehicle entry/exit, user registration |
| **Attendant** | Operational screens only: vehicle entry, vehicle exit, transaction history |

---

## Tech Stack

| Layer | Technology |
|---|---|
| UI & App Framework | Flutter (Dart) |
| State Management | Riverpod |
| Local Database | SQLite via `sqflite` |
| Navigation | `go_router` |
| Password Hashing | `bcrypt` |
| Date/Currency Formatting | `intl` |

---

## Architecture

The app follows a strict layered architecture:

```
Widgets  →  Providers (Riverpod)  →  Services  →  Repositories  →  DatabaseHelper  →  SQLite
```

- **Widgets** — UI only, no business logic
- **Providers** — screen-level state, call services and repositories
- **Services** — stateless business logic (`AuthService`, `FeeCalculator`, `DashboardService`)
- **Repositories** — all SQLite access via parameterized queries (`UserRepository`, `TicketRepository`, `TransactionRepository`, `PricingRepository`, `AuditLogRepository`)
- **DatabaseHelper** — singleton that owns schema creation, versioning, and migrations

---

## Project Structure

```
lib/
  core/           # Theme, router, shared utilities, DI providers
  database/       # DatabaseHelper (schema + migrations)
  features/
    auth/         # Login and registration screens & providers
    vehicle_entry/
    vehicle_exit/
    pricing/
    dashboard/
    transactions/
  models/         # Plain Dart data classes (User, Ticket, PricingRule, …)
  repositories/   # Data access layer (wraps sqflite)
  services/       # Business logic (AuthService, FeeCalculator, DashboardService)
test/
  unit/           # Repository and service unit tests (128 tests)
```

---

## Database Schema

Five tables, all monetary values stored as **integer cents** and all timestamps as **UTC epoch milliseconds**:

| Table | Purpose |
|---|---|
| `users` | User accounts with hashed passwords, roles, and lock status |
| `pricing_rules` | Configurable fee structures (hourly/flat, grace period, daily cap) |
| `tickets` | Open and closed parking sessions with a pricing rule snapshot |
| `transactions` | Immutable completed-session records (INSERT only — no UPDATE/DELETE) |
| `audit_log` | Timestamped log of logins, logouts, failed attempts, and user creation events |

---

## Fee Calculation

Fees are computed by the stateless `FeeCalculator` service from the pricing rule snapshot stored on the ticket at entry time. Rule changes never affect open sessions.

```
1. If duration ≤ grace period → fee = 0
2. Hourly rate: fee = ⌈duration_minutes / 60⌉ × rate
   Flat rate:   fee = rate
3. If daily cap set and duration ≤ 24 h → fee = min(fee, daily_cap)
4. fee = max(0, fee)
```

---

## Getting Started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart SDK `^3.12.0`)
- Android Studio or Xcode for a device/emulator

### Run the app

```bash
flutter pub get
flutter run
```

### Run tests

```bash
flutter test
```

### Analyze

```bash
flutter analyze
```

---

## Registration Notes

- **Username**: 3–50 characters, letters/digits/underscores only (no spaces or special characters)
- **Password**: 8–128 characters
- **Role**: `owner` or `attendant`

---

## Security

- Passwords are hashed with bcrypt before storage — plain-text passwords are never persisted
- All database queries use parameterized statements to prevent SQL injection
- Login errors return a generic "invalid credentials" message — the system never reveals which field was wrong
- Accounts are locked after 5 consecutive failed login attempts and require an admin to unlock
- Sessions expire after 30 minutes of inactivity
- All authentication events (login, logout, failed attempts, account creation) are written to the audit log
