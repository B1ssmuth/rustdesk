CREATE TABLE ad_workstations (
    object_id uuid PRIMARY KEY,
    dns_name text NOT NULL,
    hostname text NOT NULL,
    ou_path text[] NOT NULL
);
CREATE INDEX ad_workstations_dns ON ad_workstations(lower(dns_name));
CREATE TABLE ad_organizational_units (
    ou_path text[] PRIMARY KEY
);
CREATE TABLE ad_sync_status (
    singleton boolean PRIMARY KEY CHECK (singleton),
    attempted_at timestamptz NOT NULL,
    successful_at timestamptz,
    result text NOT NULL CHECK (result IN ('ok','failed')),
    computer_count integer NOT NULL DEFAULT 0
);
