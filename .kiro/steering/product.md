---
inclusion: always
---

# Parking System — Product Steering

## Product Purpose

A simple digital parking operations system for small parking operators. It enables attendants to record vehicle entry/exit, calculates fees automatically, and gives owners real-time visibility into daily income.

## Users

| Role | Key Needs |
|---|---|
| **Parking Attendant** | Fast check-in/check-out, simple interface, quick payment processing |
| **Parking Owner / Admin** | Revenue reports, real-time dashboard, fraud reduction |
| **Driver** | Quick process, receipt on exit, simple payment |

## Core Features

1. **Authentication** — Registration and login for business owners/admins.
2. **Vehicle Entry** — Plate recognition to create a parking ticket on arrival.
3. **Vehicle Exit** — Plate recognition to calculate duration and fee on departure.
4. **Pricing Rules** — CRUD management of pricing tiers applied to drivers.
5. **Dashboard** — Real-time view of active vehicles, active admins, and daily income.
6. **Transaction History** — Searchable, auditable log of all parking transactions.

## Product Objective

Help small parking operators digitize their operations, reduce revenue leakage, and improve transaction transparency through a straightforward, subscription-based parking management system.

## Architecture & Design Principles

- **Simplicity first** — Interfaces and workflows must be operable by non-technical attendants with minimal training.
- **Real-time data** — Dashboard and income figures must reflect live state, not batched/delayed data.
- **Auditability** — Every transaction (entry, exit, payment) must be logged and traceable.
- **Role-based access** — Owners/admins have elevated permissions; attendants have scoped access to operational tasks only.
- **Plate recognition as primary identifier** — Vehicle plate number is the key used to link entry and exit events.

## Code & Implementation Conventions

- Validate plate numbers on both entry and exit before creating or closing a ticket.
- Fee calculation logic must be centralized and driven by the active pricing rules — never hardcoded.
- Pricing rule changes must not retroactively affect in-progress (open) tickets.
- Authentication must guard all routes; unauthenticated requests must be rejected.
- Transaction history records must be immutable once written.
- Dashboard metrics (active vehicles, daily income) must be derived from live transaction data.
