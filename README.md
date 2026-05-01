# Enterprise Microservice Catalog & Dependency Schema

> **"Who do we call when a service fails — and what else will break?"**
> This project answers that question in under a second.

---

## What This Is

A SQL-based "Source of Truth" for every microservice in a company's ecosystem. It tells you:

- **Who owns** each service (name, email, Slack handle)
- **Where it runs** (Production, Staging, UAT, DR)
- **What it depends on** (and what depends on it)
- **What tier of criticality** it carries (Gold, Silver, Bronze)
- **What's broken right now** and for how long

Built for operational teams who need instant clarity during outages — not dashboards to click through, but a single SQL query that returns crisis intelligence.

---

## The Business Case

During a service outage, every minute of confusion costs money. The two most expensive questions are:

1. *Who is responsible for this service?*
2. *What else is going to break because of this?*

Most engineering teams answer these by searching Confluence, pinging Slack, or waiting for someone who "just knows." This schema makes both answers instantaneous.

> **Design goal:** Reduce Mean Time to Identify (MTTI) to the time it takes to run one SQL query.

---

## Architecture Overview

The schema is built in four functional layers, each solving a distinct part of the problem.

```
┌─────────────────────────────────────────────────┐
│  LAYER 1 — ACCOUNTABILITY    owners             │
│  Who is responsible?                             │
├─────────────────────────────────────────────────┤
│  LAYER 2 — ASSET             services           │
│  What is the service? What's its SLA tier?      │
├─────────────────────────────────────────────────┤
│  LAYER 3 — ENVIRONMENT       environments       │
│  Where does it run? What version is deployed?   │
├─────────────────────────────────────────────────┤
│  LAYER 4 — CONNECTIVITY      dependencies       │
│  What calls what? What breaks if X goes down?   │
├─────────────────────────────────────────────────┤
│  LAYER 5 — GOVERNANCE        incident_log       │
│  What broke, when, and why?                     │
└─────────────────────────────────────────────────┘
```

---

## Database Setup

**Engine:** SQLite 3.x (syntax is PostgreSQL-compatible — swap the connection string to migrate)

**Run the schema:**

```bash
# SQLite
sqlite3 catalog.db < schema.sql

# PostgreSQL
psql -U postgres -d catalog -f schema.sql

# Python (as used in this project)
python3 run.py
```

That's it. The script creates all tables, indexes, views, and loads 10 realistic seed services.

---

## Table Reference

### `owners` — Accountability Layer

The on-call directory. Every service must have an owner. You cannot delete an owner who still has active services (`ON DELETE RESTRICT`).

| Column | Type | Notes |
|---|---|---|
| `owner_id` | INTEGER PK | Auto-assigned. Never reuse. |
| `owner_name` | TEXT | Full name or team label |
| `department` | TEXT | Finance, Ops, IT, Platform, Security |
| `email` | TEXT UNIQUE | Primary escalation contact |
| `phone` | TEXT | On-call mobile (nullable) |
| `slack_handle` | TEXT | e.g. `@arun.s` (nullable) |
| `created_at` | TEXT | ISO-8601, auto-set on insert |

---

### `services` — Asset Layer

One row per deployable microservice. This is the catalog. Every other table references this one.

| Column | Type | Notes |
|---|---|---|
| `service_id` | INTEGER PK | Auto-assigned |
| `service_name` | TEXT UNIQUE | Slug format: `auth-service`, `payment-gateway` |
| `description` | TEXT | One-line plain English description |
| `owner_id` | FK → owners | Cascades on update, restricted on delete |
| `sla_tier` | TEXT | `Gold`, `Silver`, or `Bronze` (enforced by CHECK) |
| `language` | TEXT | Go, Java, Python, Node, etc. |
| `repo_url` | TEXT | Link to source control |
| `created_at` | TEXT | ISO-8601, auto-set on insert |

#### SLA Tier Definitions

| Tier | Recovery Target | Escalation | Example |
|---|---|---|---|
| **Gold** | Zero downtime | Immediate P1 page | `auth-service`, `payment-gateway` |
| **Silver** | RTO < 4 hours | Business hours | `user-profile-svc`, `inventory-svc` |
| **Bronze** | RTO < 24 hours | Best effort | `reporting-engine`, `recommendation-svc` |

> **Decision rule:** Does failure stop revenue or lock out users? → Gold. Does it degrade a feature? → Silver. Is it internal tooling or analytics? → Bronze.

---

### `environments` — Environment Layer

Tracks every deployment instance of every service. A Production outage is not the same as a Dev outage — this table makes that distinction explicit.

| Column | Type | Notes |
|---|---|---|
| `env_id` | INTEGER PK | Auto-assigned |
| `env_name` | TEXT | `Production`, `Staging`, `UAT`, `Development`, `DR` |
| `service_id` | FK → services | Cascades on delete (retire a service → purge its envs) |
| `host_url` | TEXT | Base URL or internal DNS |
| `is_active` | INTEGER | `1` = live, `0` = decommissioned (retained for audit) |
| `deployed_version` | TEXT | Semantic version: `v3.1.0`, `v2.0.0-beta` |
| `last_deployed` | TEXT | ISO-8601 timestamp of last successful deploy |

**Composite unique constraint:** `(env_name, service_id)` — one row per environment per service. For blue/green or canary, use a naming convention like `Production-blue`.

#### Environment Types

| Env | Purpose |
|---|---|
| `Production` | Live traffic, real users |
| `Staging` | Pre-production mirror for final validation |
| `UAT` | User acceptance testing with stakeholders |
| `Development` | Local dev and CI pipelines |
| `DR` | Disaster Recovery warm standby |

---

### `dependencies` — Connectivity Layer

A directed graph. Each row is one service calling another.

```
upstream_id  →  downstream_id
(caller)         (the one that fails)
```

If `downstream_id` goes down and `is_critical = 1`, then `upstream_id` is broken too. Query this table in reverse to get the **Blast Radius**.

| Column | Type | Notes |
|---|---|---|
| `dep_id` | INTEGER PK | Auto-assigned |
| `upstream_id` | FK → services | The calling service — the one that BREAKS |
| `downstream_id` | FK → services | The called service — the one that FAILS first |
| `dep_type` | TEXT | `sync`, `async`, or `batch` |
| `is_critical` | INTEGER | `1` = hard dependency, `0` = graceful degradation possible |
| `notes` | TEXT | Context: "Auth token validated on every request" |
| `created_at` | TEXT | ISO-8601, auto-set on insert |

#### Dependency Types

| Type | Meaning | Example |
|---|---|---|
| `sync` | Real-time blocking call | HTTP/gRPC — caller waits for response |
| `async` | Event-driven, non-blocking | Message queue — caller continues without waiting |
| `batch` | Scheduled job | Nightly data pull, daily report generation |

**Integrity guards:**
- `CHECK (upstream_id != downstream_id)` — no self-loops
- `UNIQUE (upstream_id, downstream_id)` — no duplicate edges

---

### `incident_log` — Governance Layer

Every service disruption gets a row. Open incidents have `resolved_at = NULL`. This table is the raw material for MTTI/MTTR trend analysis and post-mortems.

| Column | Type | Notes |
|---|---|---|
| `incident_id` | INTEGER PK | Auto-assigned |
| `service_id` | FK → services | The affected service (restricted on delete) |
| `env_id` | FK → environments | The affected environment |
| `severity` | TEXT | `P1`, `P2`, `P3`, or `P4` |
| `detected_at` | TEXT | When the alert fired |
| `resolved_at` | TEXT | NULL = still open |
| `root_cause` | TEXT | Post-mortem finding |

#### Severity Levels

| Severity | Meaning | Action |
|---|---|---|
| P1 | Critical — revenue impact or total outage | Page immediately, all hands |
| P2 | High — major feature degraded | Page on-call, begin war room |
| P3 | Medium — partial impact, workaround exists | Ticket + next sprint |
| P4 | Low — cosmetic or internal only | Backlog |

---

## Views — Operational Intelligence

Five pre-built views that answer the most critical questions instantly.

### `v_service_manifest` — Full Catalog

> "Give me every service, who owns it, and how many environments it has."

```sql
SELECT * FROM v_service_manifest ORDER BY sla_tier, service_name;
```

Returns: `service_name`, `sla_tier`, `language`, `owner_name`, `department`, `escalation_email`, `slack_handle`, `env_count`

---

### `v_blast_radius` — Impact Analysis ⚡

> "If `auth-service` goes down right now, what breaks and who do I call?"

```sql
SELECT * FROM v_blast_radius WHERE failed_service = 'auth-service';
```

**Sample output for `auth-service` failure:**

| impacted_service | impacted_sla_tier | dep_type | is_critical | impacted_owner |
|---|---|---|---|---|
| api-gateway | Gold | sync | 1 | Arun Sharma |
| payment-gateway | Gold | sync | 1 | Divya Nair |
| user-profile-svc | Silver | sync | 1 | Rahul Menon |

Three Gold/Silver services go down simultaneously. Two different department owners need to be paged. You know this in one query.

---

### `v_prod_status` — Production Snapshot

> "What version of everything is running in Production right now?"

```sql
SELECT * FROM v_prod_status;
```

Returns: every Production deployment sorted by SLA tier — Gold services first.

---

### `v_open_incidents` — Live Dashboard

> "What is on fire right now, how long has it been burning, and who is responsible?"

```sql
SELECT * FROM v_open_incidents;
```

Returns: `service_name`, `severity`, `minutes_open`, `on_call_phone`, `slack_handle` — everything you need to start a war room.

---

### `v_gold_critical_deps` — Gold-Tier Risk Map

> "What are the hard dependencies of our most critical services?"

```sql
SELECT * FROM v_gold_critical_deps;
```

Use this during change freeze windows or before major deployments. If a Gold service has a Silver or Bronze dependency, that dependency is a risk.

---

## Key Queries for Incident Response

**Find the blast radius of any failing service:**
```sql
SELECT impacted_service, impacted_sla_tier, dep_type, impacted_owner, impacted_escalation_email
FROM v_blast_radius
WHERE failed_service = 'config-service' AND is_critical = 1;
```

**Check if a specific service has open P1 incidents:**
```sql
SELECT * FROM v_open_incidents WHERE severity = 'P1';
```

**Calculate average MTTI across all resolved incidents:**
```sql
SELECT ROUND(AVG((julianday(resolved_at) - julianday(detected_at)) * 1440), 1) AS avg_mtti_minutes
FROM incident_log WHERE resolved_at IS NOT NULL;
```

**List everything a given service depends on:**
```sql
SELECT s2.service_name AS depends_on, d.dep_type, d.is_critical
FROM dependencies d
JOIN services s1 ON d.upstream_id = s1.service_id
JOIN services s2 ON d.downstream_id = s2.service_id
WHERE s1.service_name = 'payment-gateway';
```

**Find all services with no owner assigned (data integrity check):**
```sql
SELECT s.service_name FROM services s
LEFT JOIN owners o ON s.owner_id = o.owner_id
WHERE o.owner_id IS NULL;
```

---

## Seed Data

The schema ships with a realistic 10-service ecosystem across 5 departments:

| Service | SLA | Owner | Department |
|---|---|---|---|
| `api-gateway` | Gold | Arun Sharma | Platform |
| `auth-service` | Gold | Arun Sharma | Platform |
| `config-service` | Gold | Arun Sharma | Platform |
| `audit-logger` | Gold | Sneha Pillai | Security |
| `payment-gateway` | Gold | Divya Nair | Finance |
| `user-profile-svc` | Silver | Rahul Menon | IT |
| `inventory-svc` | Silver | Kiran Thomas | Ops |
| `notification-svc` | Silver | Kiran Thomas | Ops |
| `reporting-engine` | Bronze | Divya Nair | Finance |
| `recommendation-svc` | Bronze | Rahul Menon | IT |

14 dependency edges are pre-loaded, creating a realistic dependency graph with `api-gateway` as the central hub — everything flows through it.

---

## Index Strategy

Every foreign key has a covering index. Blast radius queries traverse the graph in O(log n) in both directions.

| Index | Column(s) | Purpose |
|---|---|---|
| `idx_services_owner` | `services.owner_id` | "All services owned by team X" |
| `idx_services_sla` | `services.sla_tier` | "All Gold-tier services" |
| `idx_envs_service` | `environments.service_id` | "All environments for service X" |
| `idx_dep_upstream` | `dependencies.upstream_id` | "What does service X call?" |
| `idx_dep_downstream` | `dependencies.downstream_id` | "What calls service X?" (blast radius) |
| `idx_incident_service` | `incident_log.service_id` | "All incidents for service X" |
| `idx_incident_severity` | `incident_log.severity` | "All open P1s" |

---

## Scalability Design

The schema handles 10 services or 10,000 services without structural changes:

- **Surrogate keys** on every table — no natural key assumptions
- **Composite unique constraints** prevent duplicates at the database level, not the application level
- **Cascading rules** are explicit — no orphaned rows possible
- **`is_active` flags** on environments mean decommissioned services are retained for audit without polluting live queries
- **All indexes are idempotent** (`CREATE INDEX IF NOT EXISTS`) — safe to re-run migrations

---

## Project Structure

```
project/
├── schema.sql          # Full schema: tables, indexes, views, seed data
├── run.py              # Python executor and validation harness
├── DATA_DICTIONARY.md  # Column-level documentation for every field
└── README.md           # This file
```

---
