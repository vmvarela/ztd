-- Journey state that Stage 1 deliberately deferred: focus, checkpoints and
-- reviews. Scope is enforced through the referenced WorkItem; the open-focus
-- invariant is global per actor, not per Profile.
CREATE TABLE focus_sessions (
    id           TEXT PRIMARY KEY,
    profile_id   TEXT NOT NULL REFERENCES profiles(id),
    actor_id     TEXT NOT NULL,
    work_item_id TEXT NOT NULL REFERENCES work_items(id),
    started_at   TEXT NOT NULL,
    ended_at     TEXT,
    outcome      TEXT,
    revision     INTEGER NOT NULL CHECK (revision > 0)
);
CREATE UNIQUE INDEX focus_one_open ON focus_sessions(actor_id) WHERE ended_at IS NULL;
CREATE INDEX focus_profile ON focus_sessions(profile_id);

CREATE TABLE checkpoints (
    id             TEXT PRIMARY KEY,
    scope_id       TEXT NOT NULL REFERENCES scopes(id),
    work_item_id   TEXT NOT NULL REFERENCES work_items(id),
    focus_id       TEXT REFERENCES focus_sessions(id),
    result         TEXT NOT NULL,
    evidence_json  TEXT NOT NULL DEFAULT '[]',
    uncertainties  TEXT,
    next_action    TEXT,
    revision       INTEGER NOT NULL CHECK (revision > 0),
    created_at     TEXT NOT NULL,
    UNIQUE (work_item_id, revision)
);
CREATE INDEX checkpoints_item ON checkpoints(work_item_id, revision);

CREATE TABLE reviews (
    id               TEXT PRIMARY KEY,
    profile_id       TEXT NOT NULL REFERENCES profiles(id),
    kind             TEXT NOT NULL CHECK (kind IN ('daily','weekly','monthly','yearly')),
    period           TEXT NOT NULL,
    outcomes         TEXT NOT NULL,
    coverage         TEXT NOT NULL,
    completion_state TEXT NOT NULL CHECK (completion_state IN ('complete','partial')),
    created_at       TEXT NOT NULL,
    revision         INTEGER NOT NULL CHECK (revision > 0),
    UNIQUE (profile_id, kind, period)
);
