PRAGMA defer_foreign_keys=ON;
CREATE TABLE work_items_new (
    id                TEXT PRIMARY KEY,
    scope_id          TEXT NOT NULL REFERENCES scopes(id),
    area_id           TEXT REFERENCES contexts(id),
    project_id        TEXT REFERENCES projects(id),
    context_id        TEXT REFERENCES contexts(id),
    title             TEXT NOT NULL,
    origin_capture_id TEXT REFERENCES captures(id),
    status TEXT NOT NULL CHECK(status IN ('next','waiting','someday','completed','cancelled','closed_unknown')),
    lifecycle TEXT GENERATED ALWAYS AS (CASE WHEN status IN ('completed','cancelled','closed_unknown') THEN 'archived' ELSE status END) VIRTUAL,
    waiting_on        TEXT,
    due_at            TEXT,
    closure_kind TEXT GENERATED ALWAYS AS (CASE WHEN status IN ('completed','cancelled') THEN status WHEN status='closed_unknown' THEN 'unspecified' ELSE NULL END) VIRTUAL,
    closed_at         TEXT,
    resolution        TEXT,
    revision          INTEGER NOT NULL CHECK (revision > 0),
    created_at        TEXT NOT NULL,
    updated_at        TEXT NOT NULL,
    custom_fields TEXT NOT NULL DEFAULT '{}',
    CHECK (lifecycle <> 'waiting' OR (waiting_on IS NOT NULL AND waiting_on <> '')),
    CHECK (lifecycle <> 'archived' OR (closed_at IS NOT NULL AND resolution IS NOT NULL AND resolution <> ''))
);
INSERT INTO work_items_new (id, scope_id, area_id, project_id, context_id, title, origin_capture_id, status, waiting_on, due_at, closed_at, resolution, revision, created_at, updated_at, custom_fields) SELECT id, scope_id, area_id, project_id, context_id, title, origin_capture_id, CASE WHEN lifecycle='archived' THEN CASE WHEN closure_kind IN ('completed','cancelled') THEN closure_kind ELSE 'closed_unknown' END ELSE lifecycle END, waiting_on, due_at, closed_at, resolution, revision, created_at, updated_at, custom_fields FROM work_items;
DROP TABLE work_items;
ALTER TABLE work_items_new RENAME TO work_items;
CREATE INDEX work_items_scope_lifecycle ON work_items(scope_id,status);
CREATE INDEX work_items_project ON work_items(project_id);
PRAGMA defer_foreign_keys=OFF;
