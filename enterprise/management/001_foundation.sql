CREATE TABLE employees (
    sid text PRIMARY KEY CHECK (sid ~ '^S-1-[0-9]+(-[0-9]+){1,15}$'),
    username text NOT NULL,
    display_name text NOT NULL,
    department text NOT NULL DEFAULT '',
    subject text UNIQUE,
    enabled boolean NOT NULL DEFAULT true
);

CREATE TABLE employee_groups (
    employee_sid text NOT NULL REFERENCES employees(sid) ON DELETE CASCADE,
    group_dn text NOT NULL,
    PRIMARY KEY (employee_sid, group_dn)
);

CREATE TABLE devices (
    id uuid PRIMARY KEY,
    computer_sid text UNIQUE NOT NULL CHECK (computer_sid ~ '^S-1-[0-9]+(-[0-9]+){1,15}$'),
    hostname text NOT NULL,
    dns_name text NOT NULL,
    yesdesk_id text UNIQUE NOT NULL CHECK (yesdesk_id ~ '^[A-Za-z0-9_-]{4,32}$'),
    enabled boolean NOT NULL DEFAULT true,
    metadata jsonb NOT NULL DEFAULT '{}',
    last_heartbeat timestamptz,
    enrollment_hash text UNIQUE,
    enrollment_until timestamptz,
    agent_hash text UNIQUE
);

CREATE TABLE device_grants (
    employee_sid text NOT NULL REFERENCES employees(sid) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES devices(id),
    allow_consent boolean NOT NULL DEFAULT false,
    allow_unattended boolean NOT NULL DEFAULT false,
    PRIMARY KEY (employee_sid, device_id)
);

CREATE TABLE primary_workplaces (
    employee_sid text PRIMARY KEY REFERENCES employees(sid) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES devices(id)
);

CREATE TABLE session_instances (
    device_id uuid NOT NULL REFERENCES devices(id),
    session_instance uuid NOT NULL,
    employee_sid text NOT NULL REFERENCES employees(sid),
    windows_session_id integer NOT NULL CHECK (windows_session_id >= 0),
    transport text NOT NULL CHECK (transport IN ('console','rdp')),
    PRIMARY KEY (device_id, session_instance)
);

CREATE TABLE session_events (
    device_id uuid NOT NULL REFERENCES devices(id),
    event_id uuid NOT NULL,
    employee_sid text NOT NULL REFERENCES employees(sid),
    session_instance uuid NOT NULL,
    windows_session_id integer NOT NULL CHECK (windows_session_id >= 0),
    kind text NOT NULL CHECK (kind IN ('logon','active','locked','disconnected','logoff')),
    transport text NOT NULL CHECK (transport IN ('console','rdp')),
    observed_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (device_id, event_id),
    FOREIGN KEY (device_id, session_instance) REFERENCES session_instances(device_id, session_instance)
);
CREATE INDEX session_employee_time ON session_events (employee_sid, observed_at DESC);
CREATE INDEX session_instance_time ON session_events (device_id, session_instance, observed_at DESC);

CREATE TABLE audit (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    actor text NOT NULL,
    action text NOT NULL,
    target text NOT NULL,
    outcome text NOT NULL
);
