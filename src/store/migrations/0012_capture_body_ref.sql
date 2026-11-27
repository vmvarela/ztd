-- original_text may be a bounded excerpt; body_ref points at the origin.
ALTER TABLE captures ADD COLUMN body_ref TEXT;
