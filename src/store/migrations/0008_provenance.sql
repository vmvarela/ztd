-- Provenance edges and advisory watermarks. provider_metadata is a bounded
-- JSON summary, never a raw payload; reported_cursor is a hint, not coverage.
ALTER TABLE captures ADD COLUMN source_review_id TEXT REFERENCES source_reviews(id);
ALTER TABLE captures ADD COLUMN batch_id TEXT;
ALTER TABLE captures ADD COLUMN provider_metadata TEXT NOT NULL DEFAULT '{}';
ALTER TABLE sources ADD COLUMN reported_cursor TEXT NOT NULL DEFAULT '';
ALTER TABLE sources ADD COLUMN last_reported_at TEXT;
