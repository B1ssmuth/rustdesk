CREATE TABLE local_accounts (
    username text PRIMARY KEY CHECK (username ~ '^[a-z0-9._-]{3,64}$'),
    display_name text NOT NULL,
    role text NOT NULL CHECK (role IN ('admin','support','user')),
    password_hash text NOT NULL,
    totp_secret bytea,
    totp_step bigint NOT NULL DEFAULT -1,
    enabled boolean NOT NULL DEFAULT true
);
CREATE TABLE local_sessions (
    token_hash text PRIMARY KEY,
    username text NOT NULL REFERENCES local_accounts(username) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL
);
CREATE INDEX local_session_user ON local_sessions(username);
CREATE INDEX local_session_expiry ON local_sessions(expires_at);
CREATE TABLE local_login_limits (
    bucket text NOT NULL,
    window_start bigint NOT NULL,
    attempts integer NOT NULL,
    PRIMARY KEY (bucket, window_start)
);
CREATE TABLE local_device_grants (
    username text NOT NULL REFERENCES local_accounts(username) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES devices(id),
    PRIMARY KEY (username, device_id)
);
CREATE TABLE local_device_preferences (
    username text NOT NULL REFERENCES local_accounts(username) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES devices(id),
    favorite boolean NOT NULL DEFAULT false,
    group_name text NOT NULL DEFAULT '',
    PRIMARY KEY (username, device_id)
);
