---
inclusion: always
---

# Parking System — Tech Stack & Conventions

## Technology Stack

| Layer | Technology |
|---|---|
| **UI / App Framework** | Flutter (Dart) |
| **Language** | Dart |
| **Local Database** | SQLite (via `sqflite` package) |

## Flutter & Dart Conventions

- Use **Flutter** for all UI screens and navigation. Target mobile (Android/iOS) as the primary platform.
- Write all application logic in **Dart**; avoid platform-specific native code unless strictly necessary.
- Follow the **feature-first folder structure**: group files by feature (e.g., `lib/features/auth/`, `lib/features/vehicle_entry/`) rather than by type.
- Use `StatelessWidget` by default; only use `StatefulWidget` or a state management solution when local mutable state is genuinely needed.
- Prefer a lightweight state management approach (e.g., `Provider` or `Riverpod`) for shared/global state such as the current user session and dashboard metrics.
- Keep business logic out of widgets — use dedicated service or repository classes.
- Name files and directories in `snake_case`. Name classes in `PascalCase`. Name variables and functions in `camelCase`.
- All `async` operations must use `async/await`; avoid raw `Future.then()` chains.
- Handle errors explicitly — never silently swallow exceptions.

## SQLite Conventions

- Use the `sqflite` package for all local database access.
- Define the database schema in a single `DatabaseHelper` class responsible for creation, versioning, and migrations.
- Use **integer primary keys** (`id INTEGER PRIMARY KEY AUTOINCREMENT`) on all tables.
- Access the database only through repository classes — widgets and services must never call `sqflite` directly.
- Use **parameterized queries** for all inserts, updates, and selects to prevent SQL injection.
- Transaction history records must be inserted as immutable rows — no `UPDATE` or `DELETE` on the transactions table.
- Apply database migrations via `onUpgrade` in `DatabaseHelper`; never drop and recreate tables in production.

## Key Packages

| Package | Purpose |
|---|---|
| `sqflite` | SQLite database access |
| `path` | Resolve database file path |
| `provider` or `riverpod` | State management |
| `intl` | Date/time and currency formatting |

## Project Structure (Reference)

```
lib/
  core/           # Shared utilities, constants, theme
  database/       # DatabaseHelper, migrations
  features/
    auth/         # Login, registration screens & logic
    vehicle_entry/
    vehicle_exit/
    pricing/
    dashboard/
    transactions/
  models/         # Dart data classes (plain objects, no UI)
  repositories/   # Data access layer (wraps sqflite)
  services/       # Business logic (fee calculation, etc.)
```
