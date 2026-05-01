# Data Dictionary
## Enterprise Microservice Catalog & Dependency Schema
**Version:** 1.0 | **Engine:** SQLite 3.x (PostgreSQL-compatible)

---

## Table: `owners` — Accountability Layer

The single source of truth for every human or team responsible for a service.
During an incident, this is the first table queried.

| Column | Type | Nullable | Constraint | Description |
|---|---|---|---|---|
| `owner_id` | INTEGER | No | PRIMARY KEY, AUTOINCREMENT | Surrogate key. Auto-assigned on insert. Never reuse. |
| `owner_name` | TEXT | No | NOT NULL | Full name or team label. E.g. "Arun Sharma" or "Platform SRE Team". |
| `department` | TEXT | No | NOT NULL | Business unit. Free-text but standardised to: Finance, Ops, IT, Platform, Security. |
| `email` | TEXT | No | NOT NULL, UNIQUE | Primary escalation contact. Enforced unique — prevents two owners sharing one inbox. |
| `phone` | TEXT | Yes | — | On-call mobile. Nullable: some teams use Slack-only escalation. |
| `slack_handle` | TEXT | Yes | — | e.g. `@arun.s`. Nullable for teams without Slack. |
| `created_at` | TEXT | No | DEFAULT datetime('now') | ISO-8601 timestamp. Set automatically on insert. |

**Referential note:** `owner_id` is referenced by `services.owner_id` with `ON DELETE RESTRICT` — you cannot delete an owner who still owns active services.

---

## Table: `services` — Asset Layer

The canonical registry of every microservice or application in the ecosystem.
Every deployable unit of software gets one row here.

| Column | Type | Nullable | Constraint | Description |
|---|---|---|---|---|
| `service_id` | INTEGER | No | PRIMARY KEY, AUTOINCREMENT | Surrogate key. |
| `service_name` | TEXT | No | NOT NULL, UNIQUE | Human-readable identifier. Slug format preferred: `auth-service`, `payment-gateway`. Enforced unique. |
| `description` | TEXT | Yes | — | One-line plain-English description of what the service does. |
| `owner_id` | INTEGER | No | FK → owners | The accountable team or person. Cascades on owner_id update. Restricted on delete. |
| `sla_tier` | TEXT | No | CHECK IN ('Gold','Silver','Bronze'), DEFAULT 'Silver' | **Gold** = Zero-downtime, revenue-critical, P1 pager. **Silver** = RTO < 4h, business-hours escalation. **Bronze** = RTO < 24h, best-effort. |
| `language` | TEXT | Yes | — | Primary runtime/language. E.g. Go, Java, Python, Node. |
| `repo_url` | TEXT | Yes | — | Full URL to source control repository. |
| `created_at` | TEXT | No | DEFAULT datetime('now') | ISO-8601 timestamp. Set on insert. |

**SLA Tier Decision Guide:**
- Gold: Does this service process money, authenticate users, or route all traffic? → Gold.
- Silver: Does a failure degrade a user-facing feature but not halt the business? → Silver.
- Bronze: Is this internal tooling, reporting, or ML experimentation? → Bronze.

---

## Table: `environments` — Environment Layer

Tracks every deployment instance of every service across all environments.
Prevents a Production incident from being confused with a Dev issue.

| Column | Type | Nullable | Constraint | Description |
|---|---|---|---|---|
| `env_id` | INTEGER | No | PRIMARY KEY, AUTOINCREMENT | Surrogate key. |
| `env_name` | TEXT | No | CHECK IN ('Production','Staging','UAT','Development','DR') | **Production** = live traffic. **Staging** = pre-prod mirror. **UAT** = user acceptance testing. **Development** = local dev/CI. **DR** = Disaster Recovery warm standby. |
| `service_id` | INTEGER | No | FK → services, ON DELETE CASCADE | The parent service. If a service is retired, all its environment rows are also purged. |
| `host_url` | TEXT | Yes | — | Base URL or internal DNS name for this deployment. E.g. `https://auth.prod.corp.io`. |
| `is_active` | INTEGER | No | CHECK IN (0,1), DEFAULT 1 | Boolean flag. 1 = live and receiving traffic. 0 = decommissioned (retained for audit history). |
| `deployed_version` | TEXT | Yes | — | Semantic version tag of the currently running build. E.g. `v3.1.0`, `v2.0.0-beta`. |
| `last_deployed` | TEXT | Yes | — | ISO-8601 timestamp of the most recent successful deployment. |

**Composite Unique:** `(env_name, service_id)` — a service can only have one row per environment type. If you need blue/green or canary, use a naming convention like `Production-blue`.

---

## Table: `dependencies` — Connectivity Layer

A directed graph where each row represents one service calling another.
`upstream_id → downstream_id` means "upstream NEEDS downstream to function."
Reading this table in reverse (group by `downstream_id`) reveals the **Blast Radius**.

| Column | Type | Nullable | Constraint | Description |
|---|---|---|---|---|
| `dep_id` | INTEGER | No | PRIMARY KEY, AUTOINCREMENT | Surrogate key. |
| `upstream_id` | INTEGER | No | FK → services, ON DELETE CASCADE | The **calling** service — the one that will BREAK if the downstream fails. |
| `downstream_id` | INTEGER | No | FK → services, ON DELETE CASCADE | The **called** service — the one that FAILS first. |
| `dep_type` | TEXT | No | CHECK IN ('sync','async','batch'), DEFAULT 'sync' | **sync** = real-time blocking call (HTTP/gRPC). **async** = event-driven via queue. **batch** = scheduled job that reads downstream. |
| `is_critical` | INTEGER | No | CHECK IN (0,1), DEFAULT 1 | **1** = downstream failure WILL break upstream (hard dependency). **0** = graceful degradation possible (soft/optional dependency). |
| `notes` | TEXT | Yes | — | Free-text context for the dependency. E.g. "Auth token validated on every request". |
| `created_at` | TEXT | No | DEFAULT datetime('now') | ISO-8601 timestamp. Set on insert. |

**Integrity Constraints:**
- `CHECK (upstream_id != downstream_id)` — prevents self-loops.
- `UNIQUE (upstream_id, downstream_id)` — prevents duplicate edges in the graph.

**How to read for incident response:**
> "Which services call `auth-service` and will break if it goes down?"
> → `SELECT upstream_id FROM dependencies WHERE downstream_id = 1 AND is_critical = 1`

---

## Table: `incident_log` — Audit / Governance Layer

Records every service disruption. Enables post-mortem analysis and MTTI/MTTR trending.
An open incident has `resolved_at = NULL`.

| Column | Type | Nullable | Constraint | Description |
|---|---|---|---|---|
| `incident_id` | INTEGER | No | PRIMARY KEY, AUTOINCREMENT | Surrogate key. |
| `service_id` | INTEGER | No | FK → services, ON DELETE RESTRICT | The service that experienced the outage. Restricted on delete — incidents are permanent records. |
| `env_id` | INTEGER | No | FK → environments, ON DELETE RESTRICT | The specific environment affected. Critical: a Production P1 is not the same as a Dev P4. |
| `severity` | TEXT | No | CHECK IN ('P1','P2','P3','P4') | **P1** = Critical, revenue/user impact, page immediately. **P2** = High, major degradation. **P3** = Medium, partial impact. **P4** = Low, cosmetic/internal only. |
| `detected_at` | TEXT | No | DEFAULT datetime('now') | When the alert fired or the issue was first noticed. |
| `resolved_at` | TEXT | Yes | — | NULL = incident is still open. Set this when service is confirmed restored. |
| `root_cause` | TEXT | Yes | — | Post-mortem finding. E.g. "JWT signing key rotation failure". |

**MTTI Formula (Mean Time to Identify):**
```sql
SELECT AVG((julianday(resolved_at) - julianday(detected_at)) * 1440) AS avg_mtti_minutes
FROM incident_log WHERE resolved_at IS NOT NULL;
```

---

## Views

| View | Purpose | Key Use Case |
|---|---|---|
| `v_service_manifest` | Full catalog with owner and env count | "Give me every service and who owns it" |
| `v_blast_radius` | Directed impact map | "If X fails, who else breaks and who do I call?" |
| `v_prod_status` | Production deployment snapshot | "What version is in Prod right now?" |
| `v_open_incidents` | Live incident dashboard with age in minutes | "What is on fire right now?" |
| `v_gold_critical_deps` | Hard dependencies of Gold-tier services only | "What can bring down our most critical systems?" |

---

## Index Strategy

| Index | Table | Column(s) | Reason |
|---|---|---|---|
| `idx_services_owner` | services | owner_id | Fast lookup: "all services owned by team X" |
| `idx_services_sla` | services | sla_tier | Fast filter: "all Gold-tier services" for alerting |
| `idx_envs_service` | environments | service_id | Fast join: service → all its environments |
| `idx_dep_upstream` | dependencies | upstream_id | Fast graph traversal: "what does service X call?" |
| `idx_dep_downstream` | dependencies | downstream_id | Fast blast radius: "what calls service X?" |
| `idx_incident_service` | incident_log | service_id | Fast history: "all incidents for service X" |
| `idx_incident_severity` | incident_log | severity | Fast filter: "all open P1s" |

All indexes are `CREATE INDEX IF NOT EXISTS` — safe to run repeatedly (idempotent).
