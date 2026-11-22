CREATE TABLE goals (
    id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL REFERENCES profiles(id),
    kind TEXT NOT NULL CHECK (kind IN ('primary', 'subgoal')),
    start_on TEXT NOT NULL,
    end_on TEXT,
    statement TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('active', 'completed', 'cancelled')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX goals_one_active_primary
    ON goals(profile_id) WHERE kind = 'primary' AND status = 'active';
CREATE INDEX goals_profile ON goals(profile_id, status);
