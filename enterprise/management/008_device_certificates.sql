CREATE TABLE device_enrollment_certificates (
    fingerprint text PRIMARY KEY CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
    device_id uuid NOT NULL REFERENCES devices(id),
    enrollment_until timestamptz NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    used_at timestamptz
);
CREATE UNIQUE INDEX device_enrollment_certificate_enabled ON device_enrollment_certificates(device_id)
    WHERE enabled;
