-- Rebuild sources to widen the connector enum. source_reviews references
-- sources(id), so the drop needs deferred FKs, and the rows must be staged
-- before the drop or they are gone.
PRAGMA defer_foreign_keys = ON;
CREATE TEMP TABLE sources_stage AS SELECT * FROM sources;
DROP TABLE sources;
CREATE TABLE sources (
    id               TEXT PRIMARY KEY,
    name             TEXT NOT NULL,
    scope_id         TEXT NOT NULL REFERENCES scopes(id),
    kind             TEXT NOT NULL CHECK (kind IN ('capture','calendar')),
    connector        TEXT NOT NULL CHECK (connector IN ('manual','directory','host_mcp','host_cli')),
    provider         TEXT NOT NULL,
    connection_ref   TEXT NOT NULL,
    non_secret_query TEXT NOT NULL,
    cadence          TEXT NOT NULL,
    auth_state       TEXT NOT NULL,
    coverage_state   TEXT NOT NULL CHECK (coverage_state IN ('unknown','unverified','partial','complete','failed')),
    cursor           TEXT NOT NULL,
    reported_cursor  TEXT NOT NULL DEFAULT '',
    last_reported_at TEXT,
    last_attempt_at  TEXT,
    last_success_at  TEXT,
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL
);
INSERT INTO sources (
    id, name, scope_id, kind, connector, provider, connection_ref, non_secret_query,
    cadence, auth_state, coverage_state, cursor, reported_cursor, last_reported_at,
    last_attempt_at, last_success_at, created_at, updated_at
)
SELECT
    id, name, scope_id, kind, connector, provider, connection_ref, non_secret_query,
    cadence, auth_state, coverage_state, cursor, reported_cursor, last_reported_at,
    last_attempt_at, last_success_at, created_at, updated_at
FROM sources_stage;
DROP TABLE sources_stage;
CREATE INDEX sources_scope ON sources(scope_id);
