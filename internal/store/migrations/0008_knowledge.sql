-- Knowledge pages reuse documents. No second writable knowledge store.
ALTER TABLE documents ADD COLUMN sources_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(sources_json) AND json_type(sources_json) = 'array');
ALTER TABLE documents ADD COLUMN project_id TEXT REFERENCES projects(id);
ALTER TABLE documents ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(metadata_json));
ALTER TABLE captures ADD COLUMN outcome_json TEXT CHECK(outcome_json IS NULL OR json_valid(outcome_json));
ALTER TABLE captures ADD COLUMN document_id TEXT REFERENCES documents(id);
ALTER TABLE plans ADD COLUMN exception_reason TEXT NOT NULL DEFAULT '';
-- Recover full decisions from the last matching event, when available.
UPDATE captures SET outcome_json = (
 SELECT json_extract(h.payload_json, '$.processing_outcome') FROM history_events h
 WHERE h.entity_type = 'capture' AND h.entity_id = captures.id AND h.event = 'processed'
 AND json_valid(h.payload_json) ORDER BY h.seq DESC LIMIT 1
) WHERE processing_outcome IS NOT NULL;
