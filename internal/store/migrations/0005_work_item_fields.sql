-- Work item custom fields: legacy task fields without a dedicated column
-- survive as a JSON object keyed by field name instead of being dropped.
ALTER TABLE work_items ADD COLUMN custom_fields TEXT NOT NULL DEFAULT '{}';
