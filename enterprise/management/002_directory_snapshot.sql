CREATE TABLE directory_snapshot (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    imported_at timestamptz NOT NULL
);
