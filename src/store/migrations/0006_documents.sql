-- Document layer: knowledge cards, project notes, plans, reviews and the other
-- Markdown-shaped records live in one scope-owned table. Projects gain the
-- repository metadata the skills need.
CREATE TABLE documents (
    id          TEXT PRIMARY KEY,
    scope_id    TEXT NOT NULL REFERENCES scopes(id),
    kind        TEXT NOT NULL CHECK (kind IN (
        'knowledge','knowledge_index','project_note','plan_daily','plan_weekly',
        'review','journal','calendar','adoption','passion','routine'
    )),
    slug        TEXT NOT NULL,
    title       TEXT NOT NULL,
    body        TEXT NOT NULL,
    status      TEXT NOT NULL CHECK (status IN ('draft','verified','superseded')),
    revision    INTEGER NOT NULL CHECK (revision > 0),
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL,
    UNIQUE (scope_id, kind, slug)
);
CREATE INDEX documents_scope_kind ON documents(scope_id, kind);

ALTER TABLE projects ADD COLUMN repo_url TEXT NOT NULL DEFAULT '';
ALTER TABLE projects ADD COLUMN clone_path TEXT NOT NULL DEFAULT '';
