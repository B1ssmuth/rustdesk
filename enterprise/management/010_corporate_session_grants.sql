CREATE TABLE corporate_endpoint_keys (
    certificate_fingerprint text PRIMARY KEY REFERENCES device_enrollment_certificates(fingerprint),
    agent_hash text NOT NULL CHECK (agent_hash ~ '^[0-9a-f]{64}$'),
    public_key bytea NOT NULL UNIQUE CHECK (octet_length(public_key) = 32),
    valid_until timestamptz NOT NULL
);

CREATE TABLE corporate_session_grants (
    id uuid PRIMARY KEY,
    username text NOT NULL,
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    session_hash text NOT NULL CHECK (session_hash ~ '^[0-9a-f]{64}$'),
    certificate_fingerprint text NOT NULL REFERENCES corporate_endpoint_keys(certificate_fingerprint),
    connection_id uuid NOT NULL,
    handshake text NOT NULL CHECK (handshake ~ '^[0-9a-f]{64}$'),
    token_hash text NOT NULL CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    expires_at bigint NOT NULL CHECK (expires_at > 0),
    consumed_at timestamptz,
    revoked_at timestamptz,
    CHECK (consumed_at IS NULL OR revoked_at IS NULL),
    UNIQUE (device_id, connection_id),
    UNIQUE (device_id, handshake)
);
