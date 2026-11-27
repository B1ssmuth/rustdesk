ALTER TABLE ad_workstations ADD COLUMN hotel text NOT NULL DEFAULT '';
CREATE TABLE ad_catalog_users (
    sid text PRIMARY KEY,
    display_name text NOT NULL CHECK (display_name <> '')
);

-- Overrides are independent of the replaceable AD snapshot.
CREATE TABLE catalog_hotel_overrides (
    source text NOT NULL CHECK (source IN ('ad', 'device')),
    computer_id uuid NOT NULL,
    hotel text NOT NULL CHECK (length(hotel) BETWEEN 1 AND 128),
    PRIMARY KEY (source, computer_id)
);

-- Pin the existing transport key against the current token registration.
CREATE TABLE corporate_transport_keys (
    device_id uuid PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
    agent_hash text NOT NULL CHECK (agent_hash ~ '^[0-9a-f]{64}$'),
    public_key bytea NOT NULL UNIQUE CHECK (octet_length(public_key) = 32),
    valid_until timestamptz NOT NULL
);
ALTER TABLE corporate_session_grants ALTER COLUMN certificate_fingerprint DROP NOT NULL;
