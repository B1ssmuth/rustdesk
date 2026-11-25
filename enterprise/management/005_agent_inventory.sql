ALTER TABLE devices ADD COLUMN windows_enrollment boolean NOT NULL DEFAULT false;
CREATE TABLE windows_sessions (
    device_id uuid NOT NULL REFERENCES devices(id),
    session_id integer NOT NULL,
    user_sid text NOT NULL,
    username text NOT NULL,
    logon_at timestamptz NOT NULL,
    transport text NOT NULL,
    state text NOT NULL,
    current boolean NOT NULL,
    last_seen timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (device_id,session_id,user_sid,logon_at)
);
CREATE INDEX windows_sessions_device_time ON windows_sessions(device_id,logon_at DESC);
