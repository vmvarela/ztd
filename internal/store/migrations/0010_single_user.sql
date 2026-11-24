-- One person, one planning view. Compatibility views are read-only.
PRAGMA defer_foreign_keys = ON;
CREATE TABLE settings (id INTEGER PRIMARY KEY CHECK(id=1), owner_actor_id TEXT NOT NULL, timezone TEXT NOT NULL);
INSERT INTO settings SELECT 1,owner_actor_id,timezone FROM profiles ORDER BY id='personal' DESC,id LIMIT 1;
CREATE TEMP TABLE chosen_profile AS SELECT id FROM profiles ORDER BY id='personal' DESC,id LIMIT 1;
INSERT INTO legacy_records(source,entity_type,entity_id,payload_json,disposition,reason)
SELECT 'schema-10','profile',id,json_object('id',id,'name',name,'kind',kind,'owner',owner_actor_id,'timezone',timezone,
'scopes',json((SELECT json_group_array(scope_id) FROM profile_scopes WHERE profile_id=profiles.id))),
'imported','profile graph replaced by singleton settings' FROM profiles;
INSERT INTO legacy_records(source,entity_type,entity_id,payload_json,disposition,reason)
SELECT 'schema-10','plan',id,json_object('id',id,'profile',profile_id,'kind',kind,'period',period,'status',status,
'revision',revision,'created_at',created_at,'updated_at',updated_at,
'items',json((SELECT json_group_array(json_object('task_id',work_item_id,'role',role,'position',position)) FROM plan_items WHERE plan_id=plans.id))),
'quarantined','secondary profile plan requires explicit reconciliation'
FROM plans WHERE profile_id NOT IN (SELECT id FROM chosen_profile);
DELETE FROM plan_items WHERE plan_id IN (SELECT id FROM plans WHERE profile_id NOT IN (SELECT id FROM chosen_profile));
DELETE FROM plans WHERE profile_id NOT IN (SELECT id FROM chosen_profile);
CREATE TABLE plans_new (
    id          TEXT PRIMARY KEY,
    profile_id  TEXT NOT NULL ,
    kind        TEXT NOT NULL CHECK (kind IN ('daily','weekly')),
    period      TEXT NOT NULL,
    status      TEXT NOT NULL CHECK (status IN ('open','committed')),
    revision    INTEGER NOT NULL CHECK (revision > 0),
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL,
    exception_reason TEXT NOT NULL DEFAULT '',
    UNIQUE (profile_id, kind, period)
);
INSERT INTO plans_new SELECT * FROM plans;
UPDATE plans_new SET profile_id='personal';
DROP TABLE plans;
ALTER TABLE plans_new RENAME TO plans;
CREATE TABLE focus_sessions_new (
    id           TEXT PRIMARY KEY,
    profile_id   TEXT NOT NULL ,
    actor_id     TEXT NOT NULL,
    work_item_id TEXT NOT NULL REFERENCES work_items(id),
    started_at   TEXT NOT NULL,
    ended_at     TEXT,
    outcome      TEXT,
    revision     INTEGER NOT NULL CHECK (revision > 0)
);
INSERT INTO focus_sessions_new SELECT * FROM focus_sessions;
UPDATE focus_sessions_new SET profile_id='personal';
DROP TABLE focus_sessions;
ALTER TABLE focus_sessions_new RENAME TO focus_sessions;
CREATE TABLE goals_new (
    id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL ,
    kind TEXT NOT NULL CHECK (kind IN ('primary', 'subgoal')),
    start_on TEXT NOT NULL,
    end_on TEXT,
    statement TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('active', 'completed', 'cancelled')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    scope_id TEXT REFERENCES scopes(id)
);
INSERT INTO legacy_records(source,entity_type,entity_id,payload_json,disposition,reason)
SELECT 'schema-10','goal',id,json_object('id',id,'profile_id',profile_id,'kind',kind,'start_on',start_on,'end_on',end_on,'statement',statement,'status',status,'created_at',created_at,'updated_at',updated_at),
'imported','original goal ownership before singleton migration' FROM goals;
INSERT INTO goals_new SELECT g.*, (SELECT min(scope_id) FROM profile_scopes WHERE profile_id=g.profile_id HAVING count(*)=1) FROM goals g;
UPDATE goals_new SET profile_id='personal';
-- Multiple old active goals need a human choice, never pick one by ID.
UPDATE goals_new SET scope_id=NULL WHERE kind='primary' AND status='active'
AND (SELECT count(*) FROM goals_new WHERE kind='primary' AND status='active')>1;
DROP TABLE goals;
ALTER TABLE goals_new RENAME TO goals;
CREATE UNIQUE INDEX focus_one_open ON focus_sessions((1)) WHERE ended_at IS NULL;
CREATE INDEX focus_profile ON focus_sessions(profile_id);
-- Historical goals without a clear owner stay hidden, with their original scope
-- graph retained in legacy_records. New goals always have a concrete scope.
CREATE UNIQUE INDEX goals_one_active_primary ON goals((1)) WHERE kind='primary' AND status='active' AND scope_id IS NOT NULL;
CREATE INDEX goals_profile ON goals(profile_id,status);
INSERT INTO legacy_records(source,entity_type,entity_id,payload_json,disposition,reason)
SELECT 'schema-10','calendar_assertion',id,json_object('id',id,'profile_id',profile_id,'actor_id',actor_id,'local_date',local_date,'statement',statement,'created_at',created_at),'imported','calendar coverage belongs to review documents' FROM calendar_review_assertions;
DROP TABLE calendar_review_assertions;
DROP TABLE profile_scopes;
DROP TABLE profiles;
CREATE VIEW profiles AS SELECT 'personal' AS id,'Personal' AS name,'personal' AS kind,owner_actor_id,timezone,'active' AS status FROM settings;
CREATE VIEW profile_scopes AS SELECT 'personal' AS profile_id,scopes.id AS scope_id,scopes.rowid AS rowid FROM scopes JOIN settings ON settings.id=1;
DROP TABLE chosen_profile;
INSERT INTO legacy_records(source,entity_type,entity_id,scope_id,payload_json,disposition,reason)
SELECT 'schema-10','area',id,scope_id,json_object('id',id,'name',name,'revision',revision),'imported','area represented as an optional context' FROM areas;
INSERT INTO contexts(id,scope_id,name,revision)
SELECT a.id,a.scope_id,'legacy-area/' || hex(a.id),a.revision FROM areas a;
CREATE TABLE projects_new (
    id              TEXT PRIMARY KEY,
    scope_id        TEXT NOT NULL REFERENCES scopes(id),
    area_id         TEXT REFERENCES contexts(id),
    desired_outcome TEXT NOT NULL,
    status          TEXT NOT NULL CHECK (status IN ('active','paused','completed','cancelled')),
    revision        INTEGER NOT NULL CHECK (revision > 0),
    repo_url TEXT NOT NULL DEFAULT '', clone_path TEXT NOT NULL DEFAULT ''
);
INSERT INTO projects_new SELECT * FROM projects;
DROP TABLE projects;
ALTER TABLE projects_new RENAME TO projects;
CREATE TABLE work_items_new (
    id                TEXT PRIMARY KEY,
    scope_id          TEXT NOT NULL REFERENCES scopes(id),
    area_id           TEXT REFERENCES contexts(id),
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
    custom_fields TEXT NOT NULL DEFAULT '{}',
    CHECK (lifecycle <> 'waiting' OR (waiting_on IS NOT NULL AND waiting_on <> '')),
    CHECK (lifecycle <> 'archived' OR (closed_at IS NOT NULL AND resolution IS NOT NULL AND resolution <> ''))
);
INSERT INTO work_items_new SELECT * FROM work_items;
DROP TABLE work_items;
ALTER TABLE work_items_new RENAME TO work_items;
CREATE INDEX projects_scope ON projects(scope_id);
CREATE INDEX work_items_scope_lifecycle ON work_items(scope_id,lifecycle);
CREATE INDEX work_items_project ON work_items(project_id);
DROP TABLE areas;
CREATE VIEW areas AS SELECT id,scope_id,name,revision FROM contexts WHERE id LIKE 'area:%';
-- Foreign keys are explicitly checked by applyMigration before commit.
PRAGMA defer_foreign_keys = OFF;
