-- Slug identifies a document within a scope; purpose is optional metadata.
PRAGMA defer_foreign_keys=ON;
CREATE TEMP TABLE saved_document_aliases AS SELECT scope_id,kind,slug,id FROM documents;
CREATE TABLE documents_new (
 id TEXT PRIMARY KEY,scope_id TEXT NOT NULL REFERENCES scopes(id),
 kind TEXT NOT NULL DEFAULT 'knowledge',slug TEXT NOT NULL,title TEXT NOT NULL,body TEXT NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('draft','verified','superseded')),
 revision INTEGER NOT NULL CHECK(revision>0),created_at TEXT NOT NULL,updated_at TEXT NOT NULL,
 sources_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(sources_json) AND json_type(sources_json)='array'),
 project_id TEXT REFERENCES projects(id),metadata_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(metadata_json)),
 UNIQUE(scope_id,slug)
);
-- Rename only colliding identities. Keep old kind/slug keys in aliases.
INSERT INTO documents_new
 SELECT d.id,d.scope_id,d.kind,
 CASE WHEN EXISTS(SELECT 1 FROM documents o WHERE o.scope_id=d.scope_id AND o.slug=d.slug AND o.id<d.id)
 THEN 'legacy/collision/' || hex(d.id) ELSE d.slug END,
 d.title,d.body,d.status,d.revision,d.created_at,d.updated_at,d.sources_json,d.project_id,d.metadata_json
 FROM documents d;
DROP TABLE documents;
ALTER TABLE documents_new RENAME TO documents;
CREATE TABLE document_aliases (
 scope_id TEXT NOT NULL REFERENCES scopes(id), kind TEXT NOT NULL, slug TEXT NOT NULL,
 document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE, PRIMARY KEY(scope_id,kind,slug)
);
INSERT INTO document_aliases SELECT * FROM saved_document_aliases;
DROP TABLE saved_document_aliases;
CREATE INDEX documents_scope_kind ON documents(scope_id,kind);
DELETE FROM documents_fts;
INSERT INTO documents_fts(doc_id,scope_id,kind,slug,title,body) SELECT id,scope_id,kind,slug,title,body FROM documents;
CREATE TRIGGER documents_fts_insert AFTER INSERT ON documents BEGIN
 INSERT INTO documents_fts(doc_id,scope_id,kind,slug,title,body) VALUES(new.id,new.scope_id,new.kind,new.slug,new.title,new.body);
END;
CREATE TRIGGER documents_fts_update AFTER UPDATE ON documents BEGIN
 DELETE FROM documents_fts WHERE doc_id=old.id;
 INSERT INTO documents_fts(doc_id,scope_id,kind,slug,title,body) VALUES(new.id,new.scope_id,new.kind,new.slug,new.title,new.body);
END;
CREATE TRIGGER documents_fts_delete AFTER DELETE ON documents BEGIN
 DELETE FROM documents_fts WHERE doc_id=old.id;
END;
PRAGMA defer_foreign_keys=OFF;
