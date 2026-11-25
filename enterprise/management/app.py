from datetime import datetime, timedelta, timezone
import hashlib
import os
import secrets
from typing import Annotated, Literal
from uuid import UUID, uuid4

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
import jwt
import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, StrictBool

from settings import database_url, https_url
from local_auth import install_routes, key


class Payload(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class Enrollment(Payload):
    device_id: UUID
    enrollment_code: str = Field(min_length=43, max_length=100)


class Disk(Payload):
    name: str = Field(max_length=32)
    bytes: int = Field(ge=0, le=2**63 - 1)


class Hardware(Payload):
    os: str = Field(max_length=128)
    model: str = Field(max_length=128)
    cpu: str = Field(max_length=128)
    ram_bytes: int = Field(ge=0, le=2**63 - 1)
    disks: list[Disk] = Field(max_length=32)


class WindowsSession(Payload):
    session_id: int = Field(ge=1, le=2**31-1)
    sid: str = Field(pattern=r"^S-1-[0-9]+(-[0-9]+){1,15}$", max_length=184)
    username: str = Field(min_length=1, max_length=256)
    logon_at: AwareDatetime
    transport: Literal["console", "rdp", "unknown"]
    state: Literal["active", "connected", "disconnected", "other"]


class WindowsInventory(Hardware):
    machine_guid: UUID
    hostname: str = Field(min_length=1, max_length=255)
    domain: str = Field(max_length=255)
    sessions: list[WindowsSession] | None = Field(max_length=128)


class SessionEvent(Payload):
    event_id: UUID
    employee_sid: str = Field(pattern=r"^S-1-[0-9]+(-[0-9]+){1,15}$", max_length=184)
    session_instance: UUID
    windows_session_id: int = Field(ge=0, le=2**31 - 1)
    kind: Literal["logon", "active", "locked", "disconnected", "logoff"]
    transport: Literal["console", "rdp"]
    observed_at: AwareDatetime


class EmployeeCard(BaseModel):
    sid: str
    username: str
    display_name: str
    department: str


class Profile(EmployeeCard):
    role: Literal["admin", "support", "user"]
    expires_at: int
    organization: str


class DeviceCard(BaseModel):
    id: UUID
    hostname: str
    dns_name: str
    yesdesk_id: str
    metadata: dict
    last_heartbeat: AwareDatetime | None


class Workplace(DeviceCard):
    is_primary: bool
    can_request_consent: bool
    active_confirmed: bool
    last_logon: AwareDatetime | None
    last_active: AwareDatetime | None
    last_logoff: AwareDatetime | None
    last_observed: AwareDatetime | None
    last_received: AwareDatetime | None
    source: Literal["test_agent"] | None


class Workplaces(BaseModel):
    employee: EmployeeCard
    devices: list[Workplace]
    last_workplace_id: UUID | None


class AgentCredential(BaseModel):
    agent_token: str


class LabConnection(Payload):
    protocol: Literal["lab-v1"]
    binding: str = Field(pattern=r"^[0-9a-f]{64}$")


class LabRedemption(LabConnection):
    token: str = Field(pattern=r"^[A-Za-z0-9_-]{43}$")
    local_consent: StrictBool


class LabGrant(BaseModel):
    id: UUID
    token: str
    expires_at: AwareDatetime
    capability: Literal["view"]


def digest(secret):
    return hashlib.sha256(secret.encode("ascii")).hexdigest()


def get_db():
    try:
        db = psycopg.connect(database_url(), row_factory=dict_row, connect_timeout=5)
    except psycopg.OperationalError:
        raise HTTPException(503, "Management database unavailable") from None
    with db:
        yield db


def role_for(groups, dns):
    for role in ("admin", "support", "user"):
        if dns.get(role) in groups:
            return role
    return None


def create_app(issuer, audience, jwks_url, groups, test_agents=False, directory_max_age=1800,
               enrolled_agents=False):
    if issuer and (not all(groups.values()) or len(set(groups.values())) != 3):
        raise ValueError("Configure three distinct AD group DNs")
    if not 60 <= directory_max_age <= 3600:
        raise ValueError("Directory snapshot lifetime must be between 60 and 3600 seconds")
    app = FastAPI(title="YES Desk Management", version="3.0.0")
    jwks = jwt.PyJWKClient(jwks_url, timeout=5, lifespan=120) if issuer else None
    bearer = HTTPBearer()
    Db = Annotated[psycopg.Connection, Depends(get_db)]
    Credential = Annotated[HTTPAuthorizationCredentials, Depends(bearer)]
    install_routes(app, get_db, bearer)

    @app.middleware("http")
    async def private_response(request: Request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.exception_handler(RequestValidationError)
    async def invalid_request(_request, _error):
        return JSONResponse({"detail": "Invalid request"}, status_code=422)

    def employee(db: Db, credential: Credential):
        if jwks is None:
            raise HTTPException(401, "Legacy corporate identity is disabled")
        try:
            token = credential.credentials
            if len(token) > 8192:
                raise jwt.InvalidTokenError()
            key = jwks.get_signing_key_from_jwt(token)
            claims = jwt.decode(
                token, key.key, algorithms=["RS256"], audience=audience, issuer=issuer,
                options={"require": ["exp", "iat", "sub", "aud", "iss"], "strict_aud": True},
            )
        except jwt.PyJWTError:
            raise HTTPException(401, "Invalid corporate access token") from None
        if (type(claims["exp"]) is not int or type(claims["iat"]) is not int
                or not 0 < claims["exp"] - claims["iat"] <= 900):
            raise HTTPException(401, "Invalid access token lifetime")
        sid = db.execute(
            "SELECT sid, username, display_name, department FROM employees "
            "WHERE subject = %s AND enabled AND EXISTS (SELECT 1 FROM directory_snapshot "
            "WHERE imported_at > now() - make_interval(secs => %s))",
            (claims["sub"], directory_max_age),
        ).fetchone()
        if sid is None:
            raise HTTPException(403, "Corporate identity is not provisioned")
        memberships = db.execute(
            "SELECT group_dn FROM employee_groups WHERE employee_sid = %s", (sid["sid"],),
        )
        role = role_for({row["group_dn"] for row in memberships}, groups)
        if role is None:
            raise HTTPException(403, "Corporate access revoked")
        return {**sid, "role": role, "expires_at": claims["exp"], "organization": issuer}

    def operator(user: Annotated[dict, Depends(employee)]):
        if user["role"] not in ("admin", "support"):
            raise HTTPException(403, "Directory access required")
        return user

    def agent(db: Db, credential: Credential):
        if not test_agents:
            raise HTTPException(503, "Agent identity verifier unavailable")
        token = credential.credentials
        if not token.isascii() or len(token) != 43:
            raise HTTPException(401, "Invalid agent identity")
        row = db.execute(
            "SELECT id FROM devices WHERE agent_hash = %s AND enabled FOR UPDATE", (digest(token),),
        ).fetchone()
        if row is None:
            raise HTTPException(401, "Invalid agent identity")
        return row["id"]

    def audit(db, actor, action, target, outcome):
        db.execute(
            "INSERT INTO audit (actor, action, target, outcome) VALUES (%s,%s,%s,%s)",
            (str(actor), action, str(target), outcome),
        )

    @app.get("/health/live")
    def live():
        return {"status": "ok"}

    @app.get("/health/ready")
    def ready(db: Db):
        if not db.execute(
            "SELECT 1 FROM schema_migrations WHERE name = '005_agent_inventory.sql'"
        ).fetchone():
            raise HTTPException(503, "Database migration required")
        return {"status": "ok"}

    @app.get("/v1/me", response_model=Profile)
    def me(user: Annotated[dict, Depends(employee)]):
        return user

    @app.get("/v1/employees", response_model=list[EmployeeCard])
    def employees(db: Db, user: Annotated[dict, Depends(operator)],
                  q: Annotated[str, Query(max_length=100)] = ""):
        result = db.execute(
            "SELECT sid, username, display_name, department FROM employees WHERE enabled "
            "AND (strpos(lower(display_name), lower(%s)) > 0 "
            "OR strpos(lower(username), lower(%s)) > 0 OR %s = '') "
            "ORDER BY display_name, sid LIMIT 100", (q, q, q),
        ).fetchall()
        audit(db, user["sid"], "list_employees", "directory", "allowed")
        return result

    @app.get("/v1/devices", response_model=list[DeviceCard])
    def devices(db: Db, user: Annotated[dict, Depends(operator)],
                q: Annotated[str, Query(max_length=100)] = ""):
        result = db.execute(
            "SELECT id, hostname, dns_name, metadata, last_heartbeat, yesdesk_id FROM devices "
            "WHERE enabled AND agent_hash IS NOT NULL AND (strpos(lower(dns_name), lower(%s)) > 0 "
            "OR strpos(lower(hostname), lower(%s)) > 0 OR %s = '') ORDER BY hostname LIMIT 100",
            (q, q, q),
        ).fetchall()
        audit(db, user["sid"], "list_devices", "directory", "allowed")
        return result

    @app.get("/v1/employees/{sid}/workplaces", response_model=Workplaces)
    def workplaces(sid: str, db: Db, user: Annotated[dict, Depends(operator)]):
        staff = db.execute(
            "SELECT sid, username, display_name, department FROM employees WHERE sid = %s AND enabled",
            (sid,),
        ).fetchone()
        if staff is None:
            raise HTTPException(404, "Employee not found")
        history = db.execute(
            """WITH history AS (
                SELECT device_id, max(observed_at) FILTER (WHERE kind='logon') AS last_logon,
                    max(observed_at) FILTER (WHERE kind='active') AS last_active,
                    max(observed_at) FILTER (WHERE kind='logoff') AS last_logoff,
                    max(observed_at) AS last_observed, max(received_at) AS last_received
                FROM session_events WHERE employee_sid=%(sid)s GROUP BY device_id
            ), current_state AS (
                SELECT DISTINCT ON (device_id, session_instance)
                    device_id, kind, observed_at FROM session_events
                WHERE employee_sid=%(sid)s
                ORDER BY device_id, session_instance, observed_at DESC, received_at DESC, event_id
            )
            SELECT d.id, d.hostname, d.dns_name, d.yesdesk_id, d.metadata, d.last_heartbeat,
                h.last_logon, h.last_active, h.last_logoff, h.last_observed, h.last_received,
                CASE WHEN h.device_id IS NOT NULL THEN 'test_agent' END AS source,
                p.device_id IS NOT NULL AS is_primary,
                COALESCE(g.allow_consent, false) AS can_request_consent,
                EXISTS (SELECT 1 FROM current_state s WHERE s.device_id=d.id AND s.kind='active'
                    AND s.observed_at > now() - interval '2 minutes'
                    AND d.last_heartbeat > now() - interval '2 minutes') AS active_confirmed
            FROM devices d LEFT JOIN history h ON h.device_id=d.id
            LEFT JOIN primary_workplaces p ON p.device_id=d.id AND p.employee_sid=%(sid)s
            LEFT JOIN device_grants g ON g.device_id=d.id AND g.employee_sid=%(operator)s
            WHERE d.enabled AND d.agent_hash IS NOT NULL AND (h.device_id IS NOT NULL OR p.device_id IS NOT NULL)
            ORDER BY h.last_observed DESC NULLS LAST LIMIT 100""",
            {"sid": sid, "operator": user["sid"]},
        ).fetchall()
        audit(db, user["sid"], "read_workplaces", sid, "allowed")
        return {"employee": staff, "devices": history,
                "last_workplace_id": next((item["id"] for item in history if item["last_observed"]), None)}

    @app.post("/v1/agents/enroll", response_model=AgentCredential)
    def enroll(payload: Enrollment, db: Db):
        if not test_agents:
            raise HTTPException(503, "Agent identity verifier unavailable")
        if not payload.enrollment_code.isascii():
            raise HTTPException(401, "Invalid enrollment")
        token = secrets.token_urlsafe(32)
        row = db.execute(
            "UPDATE devices SET agent_hash=%s, enrollment_hash=NULL, enrollment_until=NULL "
            "WHERE id=%s AND enabled AND NOT windows_enrollment AND enrollment_hash=%s AND enrollment_until > now() RETURNING id",
            (digest(token), payload.device_id, digest(payload.enrollment_code)),
        ).fetchone()
        if row is None:
            raise HTTPException(401, "Invalid enrollment")
        audit(db, payload.device_id, "enroll_agent", payload.device_id, "allowed")
        return {"agent_token": token}

    @app.post("/v2/agents/enroll", response_model=AgentCredential)
    def enroll_windows(payload: Enrollment, db: Db):
        token = secrets.token_urlsafe(32)
        if not enrolled_agents or not payload.enrollment_code.isascii():
            raise HTTPException(403, "Device enrollment unavailable")
        row = db.execute(
            """UPDATE devices SET agent_hash=%s,enrollment_hash=NULL,enrollment_until=NULL
               WHERE id=%s AND enabled AND enrollment_hash=%s AND enrollment_until>now()
                 AND windows_enrollment RETURNING id""",
            (digest(token), payload.device_id, digest(payload.enrollment_code)),
        ).fetchone()
        if not row:
            raise HTTPException(401, "Invalid enrollment")
        audit(db, payload.device_id, "enroll_windows", payload.device_id, "allowed")
        return {"agent_token": token}

    @app.post("/v2/agents/inventory")
    def inventory(payload: WindowsInventory, db: Db, cred: Credential):
        token = cred.credentials
        if not enrolled_agents or not token.isascii() or len(token) != 43:
            raise HTTPException(401, "Invalid agent identity")
        device = db.execute(
            "SELECT id FROM devices WHERE agent_hash=%s AND enabled AND windows_enrollment FOR UPDATE",
            (digest(token),),
        ).fetchone()
        if not device or device["id"] != payload.machine_guid:
            raise HTTPException(403, "Device identity mismatch")
        data = payload.model_dump(mode="json", exclude={"machine_guid", "sessions"})
        db.execute(
            "UPDATE devices SET last_heartbeat=clock_timestamp(),metadata=%s WHERE id=%s",
            (Jsonb(data), device["id"]),
        )
        if payload.sessions is not None:
            db.execute("UPDATE windows_sessions SET current=false WHERE device_id=%s AND current", (device["id"],))
            for session in payload.sessions:
                db.execute(
                    """INSERT INTO windows_sessions
                       (device_id,session_id,user_sid,username,logon_at,transport,state,current)
                       VALUES (%s,%s,%s,%s,%s,%s,%s,true)
                       ON CONFLICT (device_id,session_id,user_sid,logon_at) DO UPDATE SET
                           username=excluded.username, state=excluded.state,
                           transport=excluded.transport,current=true,last_seen=clock_timestamp()""",
                    (device["id"], session.session_id, session.sid, session.username,
                     session.logon_at, session.transport, session.state),
                )
        else:
            db.execute("UPDATE windows_sessions SET current=false WHERE device_id=%s AND current", (device["id"],))
        return {"status": "ok"}

    @app.post("/v1/agents/heartbeat")
    def heartbeat(payload: Hardware, db: Db, device: Annotated[UUID, Depends(agent)]):
        db.execute("UPDATE devices SET last_heartbeat=clock_timestamp(), metadata=%s WHERE id=%s",
                   (Jsonb(payload.model_dump()), device))
        return {"status": "ok"}

    @app.post("/v1/agents/session")
    def session_event(payload: SessionEvent, db: Db, device: Annotated[UUID, Depends(agent)]):
        now = datetime.now(timezone.utc)
        if not now - timedelta(days=7) <= payload.observed_at <= now + timedelta(seconds=30):
            raise HTTPException(422, "Event clock is outside the permitted window")
        if not db.execute("SELECT 1 FROM employees WHERE sid=%s AND enabled",
                          (payload.employee_sid,)).fetchone():
            raise HTTPException(422, "Unknown directory SID")
        binding = db.execute(
            "INSERT INTO session_instances VALUES (%s,%s,%s,%s,%s) "
            "ON CONFLICT (device_id,session_instance) DO UPDATE SET transport=excluded.transport "
            "WHERE session_instances.employee_sid=excluded.employee_sid "
            "AND session_instances.windows_session_id=excluded.windows_session_id "
            "AND session_instances.transport=excluded.transport RETURNING session_instance",
            (device, payload.session_instance, payload.employee_sid,
             payload.windows_session_id, payload.transport),
        ).fetchone()
        if not binding:
            raise HTTPException(409, "Session identity differs")
        db.execute(
            "INSERT INTO session_events (device_id,event_id,employee_sid,session_instance,"
            "windows_session_id,kind,transport,observed_at) VALUES (%s,%s,%s,%s,%s,%s,%s,%s) "
            "ON CONFLICT (device_id,event_id) DO NOTHING",
            (device, payload.event_id, payload.employee_sid, payload.session_instance,
             payload.windows_session_id, payload.kind, payload.transport, payload.observed_at),
        )
        return {"status": "ok"}

    @app.post("/v1/devices/{device_id}/connection", status_code=501, responses={
        403: {"description": "Role, grant or device verification failed"},
        501: {"description": "Endpoint enforcement is unavailable"},
    })
    def connection(device_id: UUID, db: Db, user: Annotated[dict, Depends(operator)],
                   mode: Literal["consent", "unattended"] = "consent"):
        grant = db.execute(
            "SELECT g.allow_consent, g.allow_unattended FROM device_grants g JOIN devices d "
            "ON (d.id=g.device_id) WHERE g.employee_sid=%s AND d.id=%s AND d.enabled "
            "AND d.agent_hash IS NOT NULL AND d.last_heartbeat > now() - interval '2 minutes'",
            (user["sid"], device_id),
        ).fetchone()
        allowed = mode == "consent" and grant is not None and grant["allow_consent"]
        audit(db, user["sid"], f"connection_{mode}", device_id,
              "endpoint_integration_required" if allowed else "denied")
        db.commit()
        if not allowed:
            raise HTTPException(403, "Device connection denied")
        raise HTTPException(501, "Endpoint enforcement is not configured")

    # Lab requests exercise server-side redemption without creating a RustDesk session.
    if test_agents:
        @app.post("/v1/lab/devices/{device_id}/grants", response_model=LabGrant, status_code=201)
        def issue_lab_grant(device_id: UUID, payload: LabConnection, db: Db,
                            user: Annotated[dict, Depends(employee)]):
            grant_id = uuid4()
            token = secrets.token_urlsafe(32)
            row = db.execute(
                """INSERT INTO corporate_grants
                    (id,employee_sid,device_id,agent_hash,token_hash,binding,capability,expires_at)
                SELECT %(id)s,e.sid,d.id,d.agent_hash,%(token)s,%(binding)s,'view',
                    LEAST(now() + interval '30 seconds', to_timestamp(%(expires)s))
                FROM devices d JOIN device_grants g ON g.device_id=d.id
                JOIN employees e ON e.sid=g.employee_sid
                JOIN employee_groups eg ON eg.employee_sid=e.sid
                WHERE e.sid=%(sid)s AND e.enabled AND eg.group_dn=%(admin)s AND g.allow_consent
                    AND d.id=%(device)s AND d.enabled AND d.agent_hash IS NOT NULL
                    AND d.last_heartbeat > now() - interval '2 minutes'
                    AND to_timestamp(%(expires)s) > now()
                    AND EXISTS (SELECT 1 FROM directory_snapshot
                        WHERE imported_at > now() - make_interval(secs => %(fresh)s))
                RETURNING id, expires_at, capability""",
                dict(id=grant_id, sid=user["sid"], device=device_id, admin=groups["admin"],
                     token=digest(token), binding=payload.binding, expires=user["expires_at"],
                     fresh=directory_max_age),
            ).fetchone()
            audit(db, user["sid"], "lab_grant_issue", device_id, "issued" if row else "denied")
            if not row:
                db.commit()
                raise HTTPException(403, "Device connection denied")
            return {**row, "token": token}

        @app.post("/v1/lab/agents/grants/{grant_id}/redeem")
        def redeem_lab_grant(grant_id: UUID, payload: LabRedemption, db: Db,
                             device: Annotated[UUID, Depends(agent)]):
            if not payload.local_consent:
                audit(db, device, "lab_grant_redeem", grant_id, "consent_missing")
                db.commit()
                raise HTTPException(403, "Local consent required")
            row = db.execute(
                """UPDATE corporate_grants c SET consumed_at=clock_timestamp()
                FROM devices d, device_grants g, employees e, employee_groups eg
                WHERE c.id=%(id)s AND c.device_id=%(device)s AND d.id=c.device_id
                    AND c.agent_hash=d.agent_hash AND c.employee_sid=e.sid AND e.enabled
                    AND d.last_heartbeat > now() - interval '2 minutes'
                    AND g.device_id=d.id AND g.employee_sid=e.sid AND g.allow_consent
                    AND eg.employee_sid=e.sid AND eg.group_dn=%(admin)s
                    AND c.token_hash=%(token)s AND c.binding=%(binding)s
                    AND c.expires_at > clock_timestamp() AND c.revoked_at IS NULL
                    AND c.consumed_at IS NULL AND EXISTS (SELECT 1 FROM directory_snapshot
                        WHERE imported_at > now() - make_interval(secs => %(fresh)s))
                RETURNING c.capability""",
                dict(id=grant_id, device=device, admin=groups["admin"],
                     token=digest(payload.token), binding=payload.binding, fresh=directory_max_age),
            ).fetchone()
            audit(db, device, "lab_grant_redeem", grant_id, "consumed" if row else "denied")
            if not row:
                db.commit()
                raise HTTPException(403, "Grant rejected")
            return {"validated": True, "capability": row["capability"], "session_started": False}

        @app.delete("/v1/lab/grants/{grant_id}")
        def revoke_lab_grant(grant_id: UUID, db: Db, user: Annotated[dict, Depends(employee)]):
            row = db.execute(
                "UPDATE corporate_grants SET revoked_at=clock_timestamp() "
                "WHERE id=%s AND employee_sid=%s AND revoked_at IS NULL RETURNING id",
                (grant_id, user["sid"]),
            ).fetchone()
            audit(db, user["sid"], "lab_grant_revoke", grant_id, "revoked" if row else "denied")
            if not row:
                db.commit()
                raise HTTPException(404, "Grant unavailable")
            return {"revoked": True}

    return app


def production_app():
    legacy = os.environ.get("YESDESK_LEGACY_OIDC") == "1"
    groups = {role: os.environ[f"YESDESK_{role.upper()}_DN"]
              for role in ("admin", "support", "user")} if legacy else {}
    key()
    return create_app(https_url("YESDESK_ISSUER") if legacy else None, os.environ.get("YESDESK_AUDIENCE"),
                      https_url("YESDESK_JWKS_URL") if legacy else None, groups,
                      test_agents=os.environ.get("YESDESK_ENV") == "test",
                      enrolled_agents=os.environ.get("YESDESK_WINDOWS_AGENTS") == "1",
                      directory_max_age=int(os.environ.get("YESDESK_DIRECTORY_MAX_AGE", "1800")))
