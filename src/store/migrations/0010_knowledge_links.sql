-- One knowledge layer: structured records live in documents, and links carry
-- the n:m provenance edges the loop needs. Rows migrate in a store step.
ALTER TABLE documents ADD COLUMN record_kind TEXT
    CHECK (record_kind IS NULL OR record_kind IN ('fact','decision','constraint','procedure','reference'));
ALTER TABLE documents ADD COLUMN rationale TEXT;
ALTER TABLE documents ADD COLUMN options_json TEXT;
ALTER TABLE documents ADD COLUMN approved_by TEXT;
ALTER TABLE documents ADD COLUMN approved_at TEXT;
ALTER TABLE documents ADD COLUMN valid_from TEXT;
ALTER TABLE documents ADD COLUMN source_refs TEXT NOT NULL DEFAULT '[]';
ALTER TABLE documents ADD COLUMN supersedes_id TEXT REFERENCES documents(id);

CREATE TABLE links (
    from_type TEXT NOT NULL,
    from_id   TEXT NOT NULL,
    to_type   TEXT NOT NULL,
    to_id     TEXT NOT NULL,
    relation  TEXT NOT NULL CHECK (relation IN ('evidence','decided','produced','reviewed','learned','supersedes','measured')),
    scope_id  TEXT NOT NULL REFERENCES scopes(id),
    created_at TEXT NOT NULL,
    PRIMARY KEY (from_type, from_id, to_type, to_id, relation)
);
CREATE INDEX links_to ON links(to_type, to_id);
