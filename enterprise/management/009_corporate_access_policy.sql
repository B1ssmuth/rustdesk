CREATE TABLE corporate_access_policy (
    device_id uuid PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
    attended boolean NOT NULL,
    unattended_until timestamptz,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
