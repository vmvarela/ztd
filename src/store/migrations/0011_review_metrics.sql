-- Derived metrics are computed, not asserted: the human outcomes and coverage
-- text stays required and this column carries the SQL aggregate.
ALTER TABLE reviews ADD COLUMN metrics_json TEXT NOT NULL DEFAULT '{}';
