-- Preserve knowledge metadata verbatim while giving every record a searchable page.
INSERT INTO documents (id, scope_id, kind, slug, title, body, status, revision,
 created_at, updated_at, sources_json, metadata_json)
SELECT 'legacy-knowledge:' || hex(id), scope_id, 'knowledge', 'legacy/knowledge/' || hex(id),
 substr(text, 1, 120), text,
 CASE WHEN state = 'superseded' THEN 'superseded' ELSE review_state END,
 revision, created_at, created_at, source_refs,
 json_object('legacy_id', id, 'kind', kind, 'valid_from', valid_from,
 'reviewed_at', reviewed_at, 'supersedes_id', supersedes_id, 'state', state)
FROM knowledge_records;
INSERT INTO history_events (entity_type, entity_id, scope_id, event, revision, payload_json, created_at)
SELECT 'document', 'legacy-knowledge:' || hex(id), scope_id, 'migrated', revision,
 json_object('legacy_id',id), created_at FROM knowledge_records;
DROP TABLE knowledge_records;

-- A profile-wide review has no unambiguous scope when it spans multiple scopes.
-- Keep the original restricted in legacy storage rather than guessing ownership.
INSERT INTO legacy_records (source,entity_type,entity_id,payload_json,disposition,reason)
SELECT 'schema-9','review',id,
 json_object('id',id,'profile_id',profile_id,'kind',kind,'period',period,
 'outcomes',outcomes,'coverage',coverage,'completion_state',completion_state,
 'created_at',created_at,'revision',revision),
 'quarantined','profile-wide review requires an explicit destination scope'
FROM reviews WHERE (SELECT count(*) FROM profile_scopes WHERE profile_id = reviews.profile_id) <> 1;
INSERT INTO documents (id,scope_id,kind,slug,title,body,status,revision,created_at,updated_at,metadata_json)
SELECT 'legacy-review:' || hex(r.id), ps.scope_id,'review','legacy/review/' || hex(r.id),
 r.kind || ' review ' || r.period,
 r.outcomes || char(10) || char(10) || 'Coverage: ' || r.coverage,
 'verified',r.revision,r.created_at,r.created_at,
 json_object('review',json_object('id',r.id,'profile',r.profile_id,'kind',r.kind,
 'period',r.period,'outcomes',r.outcomes,'coverage',r.coverage,
 'completion_state',r.completion_state,'created_at',r.created_at))
FROM reviews r JOIN profile_scopes ps ON ps.profile_id = r.profile_id
WHERE (SELECT count(*) FROM profile_scopes WHERE profile_id = r.profile_id) = 1;
INSERT INTO history_events(entity_type,entity_id,scope_id,event,revision,payload_json,created_at)
SELECT 'document',id,scope_id,'migrated',revision,metadata_json,created_at
FROM documents WHERE id LIKE 'legacy-review:%';
DROP TABLE reviews;
