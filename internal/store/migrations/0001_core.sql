-- ZTD schema 1: identity, captures, work, plans, migration staging.
PRAGMA foreign_keys = ON;

CREATE TABLE scopes (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    kind        TEXT NOT NULL CHECK (kind IN ('personal','work','client','opensource')),
    created_at  TEXT NOT NULL
);

CREATE TABLE profiles (
    id             TEXT PRIMARY KEY,
    name           TEXT NOT NULL,
    kind           TEXT NOT NULL CHECK (kind IN ('personal','work_client')),
    owner_actor_id TEXT NOT NULL,
    timezone       TEXT NOT NULL,
    status         TEXT NOT NULL CHECK (status IN ('active','inactive'))
);
CREATE TABLE profile_scopes (
    profile_id TEXT NOT NULL REFERENCES profiles(id),
    scope_id   TEXT NOT NULL REFERENCES scopes(id),
    PRIMARY KEY (profile_id, scope_id)
);
CREATE INDEX profile_scopes_scope ON profile_scopes(scope_id);

CREATE TABLE contexts (
    id        TEXT PRIMARY KEY,
    scope_id  TEXT NOT NULL REFERENCES scopes(id),
    name      TEXT NOT NULL,
    revision  INTEGER NOT NULL CHECK (revision > 0),
    UNIQUE (scope_id, name)
);
CREATE INDEX contexts_scope ON contexts(scope_id);

CREATE TABLE areas (
    id        TEXT PRIMARY KEY,
    scope_id  TEXT NOT NULL REFERENCES scopes(id),
    name      TEXT NOT NULL,
    revision  INTEGER NOT NULL CHECK (revision > 0),
    UNIQUE (scope_id, name)
);
CREATE INDEX areas_scope ON areas(scope_id);

CREATE TABLE projects (
    id              TEXT PRIMARY KEY,
    scope_id        TEXT NOT NULL REFERENCES scopes(id),
    area_id         TEXT REFERENCES areas(id),
    desired_outcome TEXT NOT NULL,
    status          TEXT NOT NULL CHECK (status IN ('active','paused','completed','cancelled')),
    revision        INTEGER NOT NULL CHECK (revision > 0)
);
CREATE INDEX projects_scope ON projects(scope_id);

CREATE TABLE captures (
    id                  TEXT PRIMARY KEY,
    scope_id            TEXT NOT NULL REFERENCES scopes(id),
    source_id           TEXT NOT NULL,
    external_id         TEXT,
    external_revision   TEXT,
    original_text       TEXT NOT NULL,
    content_hash        TEXT NOT NULL,
    source_uri          TEXT,
    occurred_at         TEXT,
    captured_at         TEXT NOT NULL,
    processing_state    TEXT NOT NULL CHECK (processing_state IN ('pending','processed','discarded','deferred')),
    processing_outcome  TEXT,
    review_after        TEXT,
    revision            INTEGER NOT NULL CHECK (revision > 0),
    CHECK ((processing_state = 'deferred') = (review_after IS NOT NULL))
);
CREATE UNIQUE INDEX captures_external ON captures(scope_id, source_id, external_id, external_revision)
    WHERE external_id IS NOT NULL AND external_revision IS NOT NULL;
CREATE INDEX captures_pending ON captures(scope_id, processing_state, captured_at);

CREATE TABLE work_items (
    id                TEXT PRIMARY KEY,
    scope_id          TEXT NOT NULL REFERENCES scopes(id),
    area_id           TEXT REFERENCES areas(id),
    project_id        TEXT REFERENCES projects(id),
    context_id        TEXT REFERENCES contexts(id),
    title             TEXT NOT NULL,
    origin_capture_id TEXT REFERENCES captures(id),
    lifecycle         TEXT NOT NULL CHECK (lifecycle IN ('next','waiting','someday','archived')),
    waiting_on        TEXT,
    due_at            TEXT,
    closure_kind      TEXT CHECK (closure_kind IS NULL OR closure_kind IN ('completed','cancelled','unspecified')),
    closed_at         TEXT,
    resolution        TEXT,
    revision          INTEGER NOT NULL CHECK (revision > 0),
    created_at        TEXT NOT NULL,
    updated_at        TEXT NOT NULL,
    CHECK (lifecycle <> 'waiting' OR (waiting_on IS NOT NULL AND waiting_on <> '')),
    CHECK (lifecycle <> 'archived' OR (closed_at IS NOT NULL AND resolution IS NOT NULL AND resolution <> ''))
);
CREATE INDEX work_items_scope_lifecycle ON work_items(scope_id, lifecycle);
CREATE INDEX work_items_project ON work_items(project_id);

CREATE TABLE plans (
    id          TEXT PRIMARY KEY,
    profile_id  TEXT NOT NULL REFERENCES profiles(id),
    kind        TEXT NOT NULL CHECK (kind IN ('daily','weekly')),
    period      TEXT NOT NULL,
    status      TEXT NOT NULL CHECK (status IN ('open','committed')),
    revision    INTEGER NOT NULL CHECK (revision > 0),
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL,
    UNIQUE (profile_id, kind, period)
);
CREATE TABLE plan_items (
    plan_id      TEXT NOT NULL REFERENCES plans(id),
    work_item_id TEXT NOT NULL REFERENCES work_items(id),
    role         TEXT NOT NULL CHECK (role IN ('mit','big_rock','batch')),
    position     INTEGER NOT NULL CHECK (position >= 0),
    PRIMARY KEY (plan_id, work_item_id)
);
CREATE INDEX plan_items_work ON plan_items(work_item_id);

CREATE TABLE routines (
    id                TEXT PRIMARY KEY,
    scope_id          TEXT NOT NULL REFERENCES scopes(id),
    kind              TEXT NOT NULL,
    cadence           TEXT NOT NULL,
    last_completed_at TEXT,
    active            INTEGER NOT NULL CHECK (active IN (0,1)),
    revision          INTEGER NOT NULL CHECK (revision > 0)
);
CREATE INDEX routines_scope ON routines(scope_id);

CREATE TABLE knowledge_records (
    id            TEXT PRIMARY KEY,
    scope_id      TEXT NOT NULL REFERENCES scopes(id),
    kind          TEXT NOT NULL CHECK (kind IN ('fact','decision','constraint','procedure','reference')),
    text          TEXT NOT NULL,
    state         TEXT NOT NULL CHECK (state IN ('current','superseded')),
    review_state  TEXT NOT NULL CHECK (review_state IN ('draft','verified')),
    source_refs   TEXT NOT NULL DEFAULT '[]',
    valid_from    TEXT,
    reviewed_at   TEXT,
    supersedes_id TEXT REFERENCES knowledge_records(id),
    revision      INTEGER NOT NULL CHECK (revision > 0),
    created_at    TEXT NOT NULL
);
CREATE INDEX knowledge_scope ON knowledge_records(scope_id);

CREATE TABLE daily_limit_overrides (
    id         TEXT PRIMARY KEY,
    actor_id   TEXT NOT NULL,
    local_date TEXT NOT NULL,
    rule       TEXT NOT NULL CHECK (rule IN ('mit','focus')),
    reason     TEXT NOT NULL,
    created_by TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE calendar_review_assertions (
    id         TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL REFERENCES profiles(id),
    actor_id   TEXT NOT NULL,
    local_date TEXT NOT NULL,
    statement  TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE (profile_id, actor_id, local_date)
);

CREATE TABLE history_events (
    seq          INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type  TEXT NOT NULL,
    entity_id    TEXT NOT NULL,
    scope_id     TEXT,
    profile_id   TEXT,
    event        TEXT NOT NULL,
    revision     INTEGER NOT NULL,
    payload_json TEXT NOT NULL,
    created_at   TEXT NOT NULL
);
CREATE INDEX history_entity ON history_events(entity_type, entity_id, seq);

CREATE TABLE idempotency_records (
    command         TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    request_hash    TEXT NOT NULL,
    result_json     TEXT NOT NULL,
    created_at      TEXT NOT NULL,
    PRIMARY KEY (command, idempotency_key)
);

CREATE TABLE import_runs (
    id            TEXT PRIMARY KEY,
    source_hash   TEXT NOT NULL,
    source_version TEXT NOT NULL,
    check_result  TEXT NOT NULL,
    status        TEXT NOT NULL CHECK (status IN ('running','completed','failed')),
    report_json   TEXT NOT NULL DEFAULT '{}',
    created_at    TEXT NOT NULL,
    completed_at  TEXT
);

-- Legacy entities with no current equivalent stay recoverable as opaque originals.
CREATE TABLE legacy_records (
    source      TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id   TEXT NOT NULL,
    scope_id    TEXT,
    payload_json TEXT NOT NULL,
    disposition TEXT NOT NULL CHECK (disposition IN ('imported','quarantined')),
    reason      TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (source, entity_type, entity_id)
);
