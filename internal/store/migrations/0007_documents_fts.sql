-- Retrieval layer: one FTS5 index over the documents already stored by 0006.
-- The table is standalone (not external-content): documents_fts is a derived
-- index, never exported or restored — canonicalTables omits it and the
-- triggers below rebuild it from the documents rows restore inserts.
CREATE VIRTUAL TABLE documents_fts USING fts5(
    doc_id UNINDEXED,
    scope_id UNINDEXED,
    kind UNINDEXED,
    slug,
    title,
    body,
    tokenize='unicode61'
);

INSERT INTO documents_fts (doc_id, scope_id, kind, slug, title, body)
     SELECT id, scope_id, kind, slug, title, body FROM documents;

CREATE TRIGGER documents_fts_insert AFTER INSERT ON documents BEGIN
    INSERT INTO documents_fts (doc_id, scope_id, kind, slug, title, body)
         VALUES (new.id, new.scope_id, new.kind, new.slug, new.title, new.body);
END;

CREATE TRIGGER documents_fts_update AFTER UPDATE ON documents BEGIN
    DELETE FROM documents_fts WHERE doc_id = old.id;
    INSERT INTO documents_fts (doc_id, scope_id, kind, slug, title, body)
         VALUES (new.id, new.scope_id, new.kind, new.slug, new.title, new.body);
END;

CREATE TRIGGER documents_fts_delete AFTER DELETE ON documents BEGIN
    DELETE FROM documents_fts WHERE doc_id = old.id;
END;
