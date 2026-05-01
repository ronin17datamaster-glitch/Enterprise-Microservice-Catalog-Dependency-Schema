-- ============================================================
--  ENTERPRISE MICROSERVICE CATALOG & DEPENDENCY SCHEMA
--  Database: SQLite 3.x (PostgreSQL-compatible syntax used)
--  Author:   Project 1 — Data Ops Dominance
--  Version:  1.0
-- ============================================================

PRAGMA foreign_keys = ON;

-- ============================================================
-- LAYER 1 — ACCOUNTABILITY LAYER
-- Table: owners
-- Purpose: Single source of truth for every human/team that
--          can be paged during an incident.
-- ============================================================
CREATE TABLE IF NOT EXISTS owners (
    owner_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    owner_name      TEXT    NOT NULL,                        -- Full name or team label
    department      TEXT    NOT NULL,                        -- Finance | Ops | IT | Platform | Security
    email           TEXT    NOT NULL UNIQUE,                 -- Escalation email (enforced unique)
    phone           TEXT,                                    -- On-call phone (nullable)
    slack_handle    TEXT,                                    -- e.g. @john.doe
    created_at      TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- ============================================================
-- LAYER 2 — ASSET LAYER
-- Table: services
-- Purpose: Canonical registry of every microservice/app in
--          the ecosystem, with SLA tier and ownership.
-- ============================================================
CREATE TABLE IF NOT EXISTS services (
    service_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    service_name    TEXT    NOT NULL UNIQUE,                 -- Human-readable unique identifier
    description     TEXT,                                    -- What the service does
    owner_id        INTEGER NOT NULL,                        -- FK → owners
    sla_tier        TEXT    NOT NULL DEFAULT 'Silver'
                    CHECK(sla_tier IN ('Gold','Silver','Bronze')),
                    -- Gold   = Zero-downtime, PagerDuty P1 (revenue-critical)
                    -- Silver = < 4h RTO, business-hours escalation
                    -- Bronze = < 24h RTO, best-effort
    language        TEXT,                                    -- Primary tech stack (Python, Go, Java …)
    repo_url        TEXT,                                    -- Source control link
    created_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (owner_id) REFERENCES owners(owner_id)
        ON DELETE RESTRICT                                   -- Cannot delete owner with active services
        ON UPDATE CASCADE
);

-- ============================================================
-- LAYER 3 — ENVIRONMENT LAYER
-- Table: environments
-- Purpose: Tracks WHERE each service lives so an outage in
--          Production is never confused with one in Dev.
-- ============================================================
CREATE TABLE IF NOT EXISTS environments (
    env_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    env_name        TEXT    NOT NULL
                    CHECK(env_name IN ('Production','Staging','UAT','Development','DR')),
                    -- DR = Disaster Recovery warm-standby
    service_id      INTEGER NOT NULL,                        -- FK → services
    host_url        TEXT,                                    -- Base URL / internal DNS
    is_active       INTEGER NOT NULL DEFAULT 1              -- 1 = live, 0 = decommissioned
                    CHECK(is_active IN (0,1)),
    deployed_version TEXT,                                   -- Semantic version e.g. v2.4.1
    last_deployed   TEXT,                                    -- ISO-8601 timestamp of last deploy
    FOREIGN KEY (service_id) REFERENCES services(service_id)
        ON DELETE CASCADE                                    -- Decommission service → purge envs
        ON UPDATE CASCADE,
    UNIQUE(env_name, service_id)                            -- One record per env per service
);

-- ============================================================
-- LAYER 4 — CONNECTIVITY LAYER
-- Table: dependencies
-- Purpose: Directed graph of which service CALLS which.
--          upstream_id → downstream_id means "upstream NEEDS downstream".
--          Reading the reverse gives the blast radius on failure.
-- ============================================================
CREATE TABLE IF NOT EXISTS dependencies (
    dep_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    upstream_id     INTEGER NOT NULL,   -- The calling service (the one that will BREAK)
    downstream_id   INTEGER NOT NULL,   -- The service being called (the one that FAILS)
    dep_type        TEXT    NOT NULL DEFAULT 'sync'
                    CHECK(dep_type IN ('sync','async','batch')),
                    -- sync  = real-time blocking call (HTTP/gRPC)
                    -- async = event-driven, message queue
                    -- batch = scheduled job dependency
    is_critical     INTEGER NOT NULL DEFAULT 1
                    CHECK(is_critical IN (0,1)),
                    -- 1 = downstream failure WILL break upstream
                    -- 0 = graceful degradation possible
    notes           TEXT,
    created_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (upstream_id)   REFERENCES services(service_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (downstream_id) REFERENCES services(service_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    CHECK (upstream_id != downstream_id),                   -- No self-loops
    UNIQUE (upstream_id, downstream_id)                     -- No duplicate edges
);

-- ============================================================
-- LAYER 5 — AUDIT / GOVERNANCE LAYER (Differentiator)
-- Table: incident_log
-- Purpose: Records every service disruption for post-mortems
--          and MTTI / MTTR trend analysis.
-- ============================================================
CREATE TABLE IF NOT EXISTS incident_log (
    incident_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id      INTEGER NOT NULL,
    env_id          INTEGER NOT NULL,
    severity        TEXT    NOT NULL
                    CHECK(severity IN ('P1','P2','P3','P4')),
    detected_at     TEXT    NOT NULL DEFAULT (datetime('now')),
    resolved_at     TEXT,                                   -- NULL if still open
    root_cause      TEXT,
    FOREIGN KEY (service_id) REFERENCES services(service_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    FOREIGN KEY (env_id)     REFERENCES environments(env_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- ============================================================
-- INDEXES — Performance at scale (10,000 services)
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_services_owner    ON services(owner_id);
CREATE INDEX IF NOT EXISTS idx_services_sla      ON services(sla_tier);
CREATE INDEX IF NOT EXISTS idx_envs_service      ON environments(service_id);
CREATE INDEX IF NOT EXISTS idx_dep_upstream      ON dependencies(upstream_id);
CREATE INDEX IF NOT EXISTS idx_dep_downstream    ON dependencies(downstream_id);
CREATE INDEX IF NOT EXISTS idx_incident_service  ON incident_log(service_id);
CREATE INDEX IF NOT EXISTS idx_incident_severity ON incident_log(severity);

-- ============================================================
-- SEED DATA — Realistic 10-service enterprise ecosystem
-- ============================================================

-- OWNERS (cross-department)
INSERT INTO owners (owner_name, department, email, phone, slack_handle) VALUES
    ('Arun Sharma',     'Platform',  'arun.sharma@corp.io',    '+91-9876543210', '@arun.s'),
    ('Divya Nair',      'Finance',   'divya.nair@corp.io',     '+91-9845012345', '@divya.n'),
    ('Rahul Menon',     'IT',        'rahul.menon@corp.io',    '+91-9123456789', '@rahul.m'),
    ('Sneha Pillai',    'Security',  'sneha.pillai@corp.io',   '+91-9900112233', '@sneha.p'),
    ('Kiran Thomas',    'Ops',       'kiran.thomas@corp.io',   '+91-9988776655', '@kiran.t');

-- SERVICES (across SLA tiers)
INSERT INTO services (service_name, description, owner_id, sla_tier, language, repo_url) VALUES
    ('auth-service',        'JWT authentication & token management',         1, 'Gold',   'Go',     'git/auth-service'),
    ('payment-gateway',     'PCI-DSS payment processing engine',             2, 'Gold',   'Java',   'git/payment-gateway'),
    ('api-gateway',         'Edge router, rate limiting, SSL termination',   1, 'Gold',   'Go',     'git/api-gateway'),
    ('user-profile-svc',    'User CRUD and preferences',                     3, 'Silver', 'Python', 'git/user-profile'),
    ('notification-svc',    'Email/SMS/Push dispatcher',                     5, 'Silver', 'Python', 'git/notification'),
    ('reporting-engine',    'Async BI report generation',                    2, 'Bronze', 'Python', 'git/reporting'),
    ('audit-logger',        'Immutable compliance event stream',             4, 'Gold',   'Java',   'git/audit-logger'),
    ('inventory-svc',       'Product stock and warehouse sync',              5, 'Silver', 'Node',   'git/inventory'),
    ('recommendation-svc',  'ML-based product recommendations',              3, 'Bronze', 'Python', 'git/reco-svc'),
    ('config-service',      'Centralised runtime config & feature flags',    1, 'Gold',   'Go',     'git/config-svc');

-- ENVIRONMENTS
INSERT INTO environments (env_name, service_id, host_url, is_active, deployed_version, last_deployed) VALUES
    ('Production',   1, 'https://auth.prod.corp.io',       1, 'v3.1.0',  '2026-04-28T08:00:00'),
    ('Production',   2, 'https://pay.prod.corp.io',        1, 'v2.7.4',  '2026-04-25T14:30:00'),
    ('Production',   3, 'https://gateway.prod.corp.io',    1, 'v5.0.1',  '2026-04-30T09:00:00'),
    ('Production',   4, 'https://user.prod.corp.io',       1, 'v1.9.2',  '2026-04-27T11:00:00'),
    ('Production',   5, 'https://notify.prod.corp.io',     1, 'v2.1.0',  '2026-04-20T10:00:00'),
    ('Production',   6, 'https://report.prod.corp.io',     1, 'v1.3.5',  '2026-04-15T07:00:00'),
    ('Production',   7, 'https://audit.prod.corp.io',      1, 'v4.0.0',  '2026-04-10T06:00:00'),
    ('Production',   8, 'https://inventory.prod.corp.io',  1, 'v3.3.1',  '2026-04-22T13:00:00'),
    ('Production',   9, 'https://reco.prod.corp.io',       1, 'v0.9.7',  '2026-04-18T15:00:00'),
    ('Production',  10, 'https://config.prod.corp.io',     1, 'v6.2.0',  '2026-05-01T00:00:00'),
    ('Staging',      1, 'https://auth.stg.corp.io',        1, 'v3.2.0-rc','2026-05-01T06:00:00'),
    ('Staging',      2, 'https://pay.stg.corp.io',         1, 'v2.8.0-rc','2026-04-30T12:00:00'),
    ('UAT',          4, 'https://user.uat.corp.io',        1, 'v2.0.0-beta','2026-04-29T09:00:00'),
    ('Development',  9, 'https://reco.dev.corp.io',        1, 'v1.0.0-dev','2026-04-28T16:00:00'),
    ('DR',           1, 'https://auth.dr.corp.io',         1, 'v3.1.0',  '2026-04-28T08:00:00'),
    ('DR',           2, 'https://pay.dr.corp.io',          1, 'v2.7.4',  '2026-04-25T14:30:00');

-- DEPENDENCIES (directed graph: upstream CALLS downstream)
INSERT INTO dependencies (upstream_id, downstream_id, dep_type, is_critical, notes) VALUES
    -- api-gateway is the central hub
    (3, 1, 'sync',  1, 'Every request validated through auth'),
    (3,10, 'sync',  1, 'Feature flags loaded at startup'),
    -- payment-gateway chain
    (2, 1, 'sync',  1, 'Auth token validation before charge'),
    (2, 7, 'async', 1, 'Every transaction logged to audit'),
    (2, 5, 'async', 0, 'Payment confirmation email (non-blocking)'),
    -- user-profile dependencies
    (4, 1, 'sync',  1, 'Session check on every profile read'),
    (4,10, 'sync',  1, 'Feature flags for new UI experiments'),
    -- notification-svc
    (5, 7, 'async', 0, 'Audit trail for sent notifications'),
    -- reporting-engine pulls from multiple sources
    (6, 4, 'batch', 0, 'Nightly user stats batch pull'),
    (6, 8, 'batch', 1, 'Inventory snapshot for daily reports'),
    (6, 2, 'batch', 1, 'Revenue data for finance reports'),
    -- recommendation-svc
    (9, 4, 'sync',  0, 'User preference read for personalisation'),
    (9, 8, 'sync',  1, 'Live inventory check before recommending'),
    -- inventory-svc
    (8,10, 'sync',  1, 'Config flags for warehouse routing rules');

-- INCIDENT LOG (sample historical data)
INSERT INTO incident_log (service_id, env_id, severity, detected_at, resolved_at, root_cause) VALUES
    (1, 1, 'P1', '2026-03-15T02:10:00', '2026-03-15T02:55:00', 'JWT signing key rotation failure'),
    (2, 2, 'P1', '2026-04-02T14:00:00', '2026-04-02T14:45:00', 'DB connection pool exhaustion'),
    (5, 5, 'P3', '2026-04-10T09:30:00', '2026-04-10T11:00:00', 'SMTP relay timeout'),
    (9, 4, 'P4', '2026-04-20T16:00:00', '2026-04-21T08:00:00', 'Model serving OOM in dev');

-- ============================================================
-- VIEWS — Operational Intelligence Queries
-- ============================================================

-- VIEW 1: Full Service Manifest
-- "Give me everything about every service in one shot."
CREATE VIEW IF NOT EXISTS v_service_manifest AS
SELECT
    s.service_id,
    s.service_name,
    s.sla_tier,
    s.language,
    o.owner_name,
    o.department,
    o.email        AS escalation_email,
    o.slack_handle,
    COUNT(DISTINCT e.env_id) AS env_count
FROM services s
JOIN owners       o ON s.owner_id  = o.owner_id
LEFT JOIN environments e ON s.service_id = e.service_id AND e.is_active = 1
GROUP BY s.service_id;

-- VIEW 2: Blast Radius — Impact Analysis
-- "If service X goes down, what services immediately break?"
CREATE VIEW IF NOT EXISTS v_blast_radius AS
SELECT
    d.downstream_id                AS failed_service_id,
    failed_svc.service_name        AS failed_service,
    failed_svc.sla_tier            AS failed_sla_tier,
    d.upstream_id                  AS impacted_service_id,
    impacted_svc.service_name      AS impacted_service,
    impacted_svc.sla_tier          AS impacted_sla_tier,
    d.dep_type,
    d.is_critical,
    imp_owner.owner_name           AS impacted_owner,
    imp_owner.email                AS impacted_escalation_email
FROM dependencies d
JOIN services failed_svc   ON d.downstream_id = failed_svc.service_id
JOIN services impacted_svc ON d.upstream_id   = impacted_svc.service_id
JOIN owners   imp_owner    ON impacted_svc.owner_id = imp_owner.owner_id;

-- VIEW 3: Production Deployment Status
-- "What is running in Prod right now and when was it last deployed?"
CREATE VIEW IF NOT EXISTS v_prod_status AS
SELECT
    s.service_name,
    s.sla_tier,
    e.deployed_version,
    e.last_deployed,
    e.is_active,
    o.owner_name,
    o.email
FROM environments e
JOIN services s ON e.service_id = s.service_id
JOIN owners   o ON s.owner_id   = o.owner_id
WHERE e.env_name = 'Production'
ORDER BY s.sla_tier, s.service_name;

-- VIEW 4: Open Incidents Dashboard
-- "What is on fire right now?"
CREATE VIEW IF NOT EXISTS v_open_incidents AS
SELECT
    il.incident_id,
    s.service_name,
    s.sla_tier,
    env.env_name,
    il.severity,
    il.detected_at,
    ROUND(
        (julianday('now') - julianday(il.detected_at)) * 1440
    , 1) AS minutes_open,
    o.owner_name,
    o.phone           AS on_call_phone,
    o.slack_handle
FROM incident_log il
JOIN services      s   ON il.service_id = s.service_id
JOIN environments  env ON il.env_id     = env.env_id
JOIN owners        o   ON s.owner_id    = o.owner_id
WHERE il.resolved_at IS NULL
ORDER BY il.severity, il.detected_at;

-- VIEW 5: Gold-Tier Dependency Chain
-- "Show every hard dependency of our most critical services."
CREATE VIEW IF NOT EXISTS v_gold_critical_deps AS
SELECT
    s.service_name          AS gold_service,
    dep_svc.service_name    AS depends_on,
    dep_svc.sla_tier        AS dependency_tier,
    d.dep_type,
    d.is_critical,
    o.owner_name            AS dependency_owner,
    o.email                 AS dependency_email
FROM services s
JOIN dependencies d  ON s.service_id     = d.upstream_id
JOIN services dep_svc ON d.downstream_id = dep_svc.service_id
JOIN owners   o       ON dep_svc.owner_id= o.owner_id
WHERE s.sla_tier = 'Gold' AND d.is_critical = 1
ORDER BY s.service_name, dep_svc.sla_tier;
