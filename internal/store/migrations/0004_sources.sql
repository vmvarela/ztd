-- Source registry and recorded retrieval batches. Sources own the retrieval
-- cursor; a review records one batch and its coverage without moving the
-- cursor for reported results.
CREATE TABLE sources (
    id               TEXT PRIMARY KEY,
    name             TEXT NOT NULL,
    scope_id         TEXT NOT NULL REFERENCES scopes(id),
    kind             TEXT NOT NULL CHECK (kind IN ('capture','calendar')),
    connector        TEXT NOT NULL CHECK (connector IN ('manual','directory','host_mcp')),
    provider         TEXT NOT NULL,
    connection_ref   TEXT NOT NULL,
    non_secret_query TEXT NOT NULL,
    cadence          TEXT NOT NULL,
    auth_state       TEXT NOT NULL,
    coverage_state   TEXT NOT NULL CHECK (coverage_state IN ('unknown','unverified','partial','complete','failed')),
    cursor           TEXT NOT NULL,
    last_attempt_at  TEXT,
    last_success_at  TEXT,
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL
);
CREATE INDEX sources_scope ON sources(scope_id);

CREATE TABLE source_reviews (
    id              TEXT PRIMARY KEY,
    source_id       TEXT NOT NULL REFERENCES sources(id),
    batch_id        TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    request_hash    TEXT NOT NULL,
    result_kind     TEXT NOT NULL CHECK (result_kind IN ('observed','reported')),
    coverage_state  TEXT NOT NULL CHECK (coverage_state IN ('unknown','unverified','partial','complete','failed')),
    retrieval_json  TEXT NOT NULL,
    created_at      TEXT NOT NULL,
    UNIQUE (source_id, batch_id),
    UNIQUE (source_id, idempotency_key)
);
CREATE INDEX source_reviews_source ON source_reviews(source_id);
