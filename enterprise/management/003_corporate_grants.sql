CREATE TABLE corporate_grants (
    id uuid PRIMARY KEY,
    employee_sid text NOT NULL REFERENCES employees(sid),
    device_id uuid NOT NULL REFERENCES devices(id),
    agent_hash text NOT NULL,
    token_hash text NOT NULL UNIQUE,
    binding text NOT NULL,
    capability text NOT NULL CHECK (capability = 'view'),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    revoked_at timestamptz
);
CREATE INDEX corporate_grants_expiry ON corporate_grants(expires_at);
