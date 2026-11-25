import base64
from getpass import getpass
import hashlib
import hmac
import json
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import secrets
import sys
import threading
import time
from typing import Annotated, Literal
from uuid import UUID

from argon2 import PasswordHasher
from argon2.exceptions import VerificationError
from cryptography.fernet import Fernet
from fastapi import Depends, HTTPException, Query
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, SecretStr
import psycopg

from settings import database_url


PASSWORDS = PasswordHasher()
DUMMY_HASH = PASSWORDS.hash(secrets.token_urlsafe(32))
HASH_SLOTS = threading.BoundedSemaphore(4)
USERNAME = r"^[a-z0-9._-]{3,64}$"


class Login(BaseModel):
    model_config = ConfigDict(extra="forbid")
    username: str = Field(pattern=USERNAME)
    password: SecretStr = Field(min_length=1, max_length=256)
    code: SecretStr | None = Field(default=None, min_length=6, max_length=6)


class Account(Login):
    display_name: str = Field(min_length=1, max_length=128)
    role: Literal["admin", "support", "user"]


class AccountState(BaseModel):
    enabled: bool


class AccountEdit(BaseModel):
    display_name: str = Field(min_length=1, max_length=128)
    role: Literal["admin", "support", "user"]


class AdminProof(BaseModel):
    password: SecretStr = Field(min_length=1, max_length=256)
    code: SecretStr = Field(min_length=6, max_length=6)


class PasswordChange(BaseModel):
    current: SecretStr = Field(min_length=1, max_length=256)
    replacement: SecretStr = Field(min_length=14, max_length=256)


class Preference(BaseModel):
    favorite: bool
    group_name: str = Field(max_length=80)


class CorporatePolicy(BaseModel):
    model_config = ConfigDict(extra="forbid")
    attended: bool
    unattended_until: AwareDatetime | None = None


def key():
    return Fernet(Path(os.environ["YESDESK_MFA_KEY_FILE"]).read_bytes().strip())


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def hash_password(password):
    if not 14 <= len(password) <= 256:
        raise ValueError("Password must contain 14 to 256 characters")
    with HASH_SLOTS:
        return PASSWORDS.hash(password)


def check_password(encoded, password):
    if not HASH_SLOTS.acquire(blocking=False):
        raise HTTPException(429, "Please retry later")
    try:
        return PASSWORDS.verify(encoded, password)
    except VerificationError:
        return False
    finally:
        HASH_SLOTS.release()


def totp_code(secret, step):
    digest = hmac.digest(secret, step.to_bytes(8, "big"), "sha1")
    offset = digest[-1] & 15
    value = int.from_bytes(digest[offset:offset+4], "big") & 0x7fffffff
    return f"{value % 1_000_000:06}"


def consume_totp(db, user, code):
    if not user["totp_secret"] or not code or not code.isascii() or not code.isdigit():
        return False
    now = int(time.time()) // 30
    secret = key().decrypt(bytes(user["totp_secret"]))
    for step in (now-1, now, now+1):
        if step > user["totp_step"] and hmac.compare_digest(totp_code(secret, step), code):
            db.execute("UPDATE local_accounts SET totp_step=%s WHERE username=%s",
                       (step, user["username"]))
            return True
    return False


def write_audit(db, username, action, target, outcome):
    db.execute("INSERT INTO audit(actor,action,target,outcome) VALUES (%s,%s,%s,%s)",
               (f"local:{username}", action, str(target), outcome))


def current_local(db, token):
    if not token.startswith("ls_") or len(token) != 46:
        raise HTTPException(401, "Invalid session")
    user = db.execute(
        """SELECT a.username,a.display_name,a.role,
                  floor(extract(epoch FROM s.expires_at))::bigint AS expires_at
           FROM local_accounts a JOIN local_sessions s USING(username)
           WHERE s.token_hash=%s AND a.enabled AND s.expires_at > clock_timestamp()""",
        (token_hash(token),),
    ).fetchone()
    if user is None:
        raise HTTPException(401, "Invalid session")
    return {**user, "organization": "YES Desk"}


def limit_attempt(db, username):
    window = int(time.time()) // 300
    db.execute("DELETE FROM local_login_limits WHERE window_start < %s", (window-1,))
    for bucket, maximum in (("global", 100), ("account:" + username, 8)):
        row = db.execute(
            """INSERT INTO local_login_limits VALUES (%s,%s,1)
               ON CONFLICT (bucket,window_start) DO UPDATE
               SET attempts=local_login_limits.attempts+1
               WHERE local_login_limits.attempts < %s RETURNING attempts""",
            (bucket, window, maximum),
        ).fetchone()
        if not row:
            db.commit()
            raise HTTPException(429, "Please retry later", headers={"Retry-After": "300"})
    # Release the shared limiter row before performing the expensive hash.
    db.commit()


def install_routes(app, get_db, bearer):
    Db = Annotated[psycopg.Connection, Depends(get_db)]
    Cred = Annotated[HTTPAuthorizationCredentials, Depends(bearer)]

    def account(db: Db, cred: Cred):
        return current_local(db, cred.credentials)

    def directory(user: Annotated[dict, Depends(account)]):
        if user["role"] not in ("admin", "support"):
            raise HTTPException(403, "Directory access required")
        return user

    def admin(user: Annotated[dict, Depends(account)]):
        if user["role"] != "admin":
            raise HTTPException(403, "Administrator required")
        return user

    def mutation_admin(db: Db, cred: Cred):
        # Serialize mutations and revalidate the session after acquiring the lock.
        db.execute("SELECT pg_advisory_xact_lock(8143025)")
        return admin(current_local(db, cred.credentials))

    def target_account(db, username):
        row = db.execute(
            "SELECT * FROM local_accounts WHERE username=%s FOR UPDATE", (username,),
        ).fetchone()
        if not row:
            raise HTTPException(404, "Account unavailable")
        return row

    def require_other_admin(db, actor, row, action):
        if row["role"] != "admin" or not row["enabled"]:
            return
        if not db.execute(
            "SELECT 1 FROM local_accounts WHERE username<>%s AND enabled AND role='admin' "
            "AND totp_secret IS NOT NULL LIMIT 1", (row["username"],),
        ).fetchone():
            write_audit(db, actor, action, row["username"], "last_admin_denied")
            db.commit()
            raise HTTPException(409, "At least one enabled administrator with MFA is required")

    @app.post("/v2/auth/login")
    def login(payload: Login, db: Db):
        limit_attempt(db, payload.username)
        user = db.execute("SELECT * FROM local_accounts WHERE username=%s FOR UPDATE",
                          (payload.username,)).fetchone()
        valid = check_password(user["password_hash"] if user else DUMMY_HASH,
                               payload.password.get_secret_value())
        if valid and user and user["enabled"]:
            if user["role"] in ("admin", "support"):
                valid = consume_totp(db, user, payload.code.get_secret_value() if payload.code else None)
            if valid:
                token = "ls_" + secrets.token_urlsafe(32)
                db.execute("DELETE FROM local_sessions WHERE expires_at <= now()")
                db.execute("INSERT INTO local_sessions VALUES (%s,%s,now()+interval '30 minutes')",
                           (token_hash(token), payload.username))
                write_audit(db, payload.username, "login", payload.username, "allowed")
                return {"token": token, "profile": current_local(db, token)}
        write_audit(db, payload.username, "login", payload.username, "denied")
        db.commit()
        raise HTTPException(401, "Invalid credentials")

    @app.get("/v2/auth/me")
    def me(user: Annotated[dict, Depends(account)]):
        return user

    @app.post("/v2/auth/logout")
    def logout(db: Db, cred: Cred):
        row = db.execute("DELETE FROM local_sessions WHERE token_hash=%s RETURNING username",
                         (token_hash(cred.credentials),)).fetchone()
        if row:
            write_audit(db, row["username"], "logout", row["username"], "allowed")
        return {"status": "ok"}

    @app.put("/v2/auth/password")
    def change_password(payload: PasswordChange, db: Db, cred: Cred,
                        user: Annotated[dict, Depends(account)]):
        limit_attempt(db, user["username"])
        row = db.execute("SELECT password_hash FROM local_accounts WHERE username=%s AND enabled FOR UPDATE",
                         (user["username"],)).fetchone()
        current_local(db, cred.credentials)
        if not row or not check_password(row["password_hash"], payload.current.get_secret_value()):
            raise HTTPException(401, "Invalid credentials")
        db.execute("UPDATE local_accounts SET password_hash=%s WHERE username=%s",
                   (hash_password(payload.replacement.get_secret_value()), user["username"]))
        db.execute("DELETE FROM local_sessions WHERE username=%s", (user["username"],))
        write_audit(db, user["username"], "change_password", user["username"], "allowed")
        return {"status": "ok"}

    @app.post("/v2/accounts", status_code=201)
    def create(payload: Account, db: Db, user: Annotated[dict, Depends(mutation_admin)]):
        try:
            encoded = hash_password(payload.password.get_secret_value())
        except ValueError as error:
            raise HTTPException(422, str(error)) from None
        row = db.execute(
            "INSERT INTO local_accounts(username,display_name,role,password_hash) VALUES (%s,%s,%s,%s) "
            "ON CONFLICT DO NOTHING RETURNING username",
            (payload.username, payload.display_name, payload.role, encoded),
        ).fetchone()
        if not row:
            raise HTTPException(409, "Account already exists")
        write_audit(db, user["username"], "create_account", payload.username, "allowed")
        return row

    @app.put("/v2/accounts/{username}")
    def set_enabled(username: str, payload: AccountState, db: Db,
                    user: Annotated[dict, Depends(mutation_admin)]):
        target = target_account(db, username)
        if not payload.enabled:
            require_other_admin(db, user["username"], target, "set_account_enabled")
        db.execute("UPDATE local_accounts SET enabled=%s WHERE username=%s", (payload.enabled, username))
        db.execute("DELETE FROM local_sessions WHERE username=%s", (username,))
        write_audit(db, user["username"], "set_account_enabled", username, str(payload.enabled))
        return {"username": username}

    @app.get("/v2/accounts")
    def accounts(db: Db, user: Annotated[dict, Depends(admin)],
                 q: Annotated[str, Query(max_length=100)] = "",
                 offset: Annotated[int, Query(ge=0)] = 0):
        return db.execute(
            """SELECT username,display_name,role,enabled,
                      CASE WHEN mfa_reset_requested_at IS NOT NULL THEN 'reset_pending'
                           WHEN totp_secret IS NOT NULL THEN 'configured'
                           WHEN role IN ('admin','support') THEN 'setup_required'
                           ELSE 'not_required' END AS mfa_state
               FROM local_accounts WHERE %s='' OR strpos(username,lower(%s))>0
                 OR strpos(lower(display_name),lower(%s))>0
               ORDER BY username LIMIT 100 OFFSET %s""", (q, q, q, offset),
        ).fetchall()

    @app.patch("/v2/accounts/{username}")
    def edit(username: str, payload: AccountEdit, db: Db,
             user: Annotated[dict, Depends(mutation_admin)]):
        row = target_account(db, username)
        if row["role"] != payload.role:
            require_other_admin(db, user["username"], row, "change_role")
            db.execute("DELETE FROM local_sessions WHERE username=%s", (username,))
        db.execute("UPDATE local_accounts SET display_name=%s,role=%s WHERE username=%s",
                   (payload.display_name, payload.role, username))
        write_audit(db, user["username"], "edit_account", username, f"role:{payload.role}")
        return {"username": username}

    @app.post("/v2/accounts/{username}/revoke-sessions")
    def revoke_sessions(username: str, db: Db, user: Annotated[dict, Depends(mutation_admin)]):
        target_account(db, username)
        db.execute("DELETE FROM local_sessions WHERE username=%s", (username,))
        write_audit(db, user["username"], "revoke_sessions", username, "allowed")
        return {"username": username}

    @app.post("/v2/accounts/{username}/request-mfa-reset")
    def request_mfa_reset(username: str, payload: AdminProof, db: Db, cred: Cred,
                          user: Annotated[dict, Depends(admin)]):
        limit_attempt(db, user["username"])
        user = mutation_admin(db, cred)
        actor = target_account(db, user["username"])
        if (not check_password(actor["password_hash"], payload.password.get_secret_value()) or
                not consume_totp(db, actor, payload.code.get_secret_value())):
            write_audit(db, user["username"], "request_mfa_reset", username, "proof_denied")
            db.commit()
            raise HTTPException(401, "Administrator verification failed")
        target = target_account(db, username)
        if target["role"] not in ("admin", "support"):
            raise HTTPException(409, "Privileged account required")
        require_other_admin(db, user["username"], target, "request_mfa_reset")
        db.execute("UPDATE local_accounts SET totp_secret=NULL,totp_step=-1,"
                   "mfa_reset_requested_at=clock_timestamp() WHERE username=%s", (username,))
        db.execute("DELETE FROM local_sessions WHERE username=%s", (username,))
        write_audit(db, user["username"], "request_mfa_reset", username, "pending_operator")
        return {"mfa_state": "reset_pending"}

    @app.post("/v2/devices/{device_id}/revoke-agent")
    def revoke_agent(device_id: UUID, db: Db, user: Annotated[dict, Depends(mutation_admin)]):
        db.execute("UPDATE device_enrollment_certificates SET enabled=false WHERE device_id=%s", (device_id,))
        row = db.execute(
            "UPDATE devices SET agent_hash=NULL,enrollment_hash=NULL,enrollment_until=NULL,last_heartbeat=NULL "
            "WHERE id=%s RETURNING id", (device_id,),
        ).fetchone()
        if not row:
            raise HTTPException(404, "Device unavailable")
        db.execute("DELETE FROM corporate_access_policy WHERE device_id=%s", (device_id,))
        db.execute("UPDATE windows_sessions SET current=false WHERE device_id=%s AND current", (device_id,))
        write_audit(db, user["username"], "revoke_agent", device_id, "allowed")
        return {"id": device_id}

    @app.get("/v2/devices")
    def devices(db: Db, user: Annotated[dict, Depends(directory)], q: str = "",
                offset: Annotated[int, Query(ge=0)] = 0):
        if len(q) > 100:
            raise HTTPException(422, "Search term too long")
        return db.execute(
            """SELECT d.id,d.hostname,d.dns_name,d.yesdesk_id,d.metadata,d.last_heartbeat,
                      d.agent_hash IS NOT NULL AS agent_registered,
                      (SELECT w.username FROM windows_sessions w WHERE w.device_id=d.id
                       ORDER BY w.current DESC,w.logon_at DESC,w.session_id LIMIT 1) AS windows_user,
                      COALESCE(d.last_heartbeat > now()-interval '2 minutes',false) AS online,
                      COALESCE(p.favorite,false) AS favorite, COALESCE(p.group_name,'') AS group_name,
                      g.device_id IS NOT NULL AS can_request_consent
               FROM devices d LEFT JOIN local_device_preferences p
                 ON p.device_id=d.id AND p.username=%(username)s
               LEFT JOIN local_device_grants g ON g.device_id=d.id AND g.username=%(username)s
               WHERE d.enabled AND
                 (%(q)s='' OR strpos(lower(d.hostname), lower(%(q)s))>0
                   OR strpos(lower(d.yesdesk_id), lower(%(q)s))>0
                   OR EXISTS (SELECT 1 FROM windows_sessions w
                     WHERE w.device_id=d.id AND strpos(lower(w.username),lower(%(q)s))>0)
                   OR EXISTS (SELECT 1 FROM session_events s JOIN employees e ON e.sid=s.employee_sid
                     WHERE s.device_id=d.id AND strpos(lower(e.username), lower(%(q)s))>0))
               ORDER BY favorite DESC,d.hostname,d.id LIMIT 100 OFFSET %(offset)s""",
            {"username": user["username"], "q": q, "offset": offset},
        ).fetchall()

    @app.get("/v2/workspace")
    def workspace(db: Db, user: Annotated[dict, Depends(directory)],
                  q: Annotated[str, Query(max_length=100)] = "",
                  ou: Annotated[str, Query(max_length=4096)] = "[]",
                  favorites: bool = False,
                  sort: Literal["hostname", "heartbeat"] = "hostname",
                  offset: Annotated[int, Query(ge=0)] = 0):
        try:
            units = json.loads(ou)
            if not isinstance(units, list) or not all(isinstance(unit, str) for unit in units):
                raise ValueError()
        except ValueError:
            raise HTTPException(422, "Invalid OU path") from None
        rows = db.execute(
            """WITH a AS (SELECT *,count(*) OVER (PARTITION BY lower(dns_name)) AS candidates
                          FROM ad_workstations),
               d AS (SELECT *,count(*) OVER (PARTITION BY lower(rtrim(dns_name,'.'))) AS candidates
                     FROM devices WHERE enabled),
               projected AS (
                  SELECT a.object_id AS ad_id,d.id AS device_id,
                     COALESCE(d.hostname,a.hostname) AS hostname,
                     COALESCE(d.dns_name,a.dns_name) AS dns_name,
                     COALESCE(a.ou_path,'{}') AS ou_path,d.yesdesk_id,d.last_heartbeat,
                     d.agent_hash IS NOT NULL AS agent_registered,COALESCE(d.metadata,'{}') AS metadata,
                     COALESCE(p.favorite,false) AS favorite,COALESCE(p.group_name,'') AS group_name,
                     (SELECT w.username FROM windows_sessions w WHERE w.device_id=d.id
                      ORDER BY w.current DESC,w.logon_at DESC LIMIT 1) AS windows_user
                  FROM a FULL OUTER JOIN d
                    ON (CASE WHEN a.candidates=1 AND a.dns_name<>'' THEN lower(a.dns_name) END)
                       = (CASE WHEN d.candidates=1 THEN lower(rtrim(d.dns_name,'.')) END)
                  LEFT JOIN local_device_preferences p ON p.device_id=d.id AND p.username=%(username)s
               )
               SELECT * FROM projected
               WHERE (NOT %(favorites)s OR favorite)
                 AND (%(depth)s=0 OR ou_path[1:%(depth)s]=%(units)s::text[])
                 AND (%(q)s='' OR strpos(lower(concat_ws(' ',hostname,dns_name,windows_user,
                      yesdesk_id,metadata->'addresses',array_to_string(ou_path,' '))),lower(%(q)s))>0)
               ORDER BY CASE WHEN %(sort)s='heartbeat' THEN last_heartbeat END DESC NULLS LAST,
                        lower(hostname),device_id,ad_id LIMIT 101 OFFSET %(offset)s""",
            dict(username=user["username"], q=q, favorites=favorites, units=units,
                 depth=len(units), sort=sort, offset=offset),
        ).fetchall()
        paths = db.execute(
            "SELECT ou_path FROM ad_organizational_units UNION SELECT ou_path FROM ad_workstations ORDER BY ou_path",
        ).fetchall()
        sync = db.execute("SELECT attempted_at,successful_at,result,computer_count FROM ad_sync_status").fetchone()
        return {"rows": rows[:100], "has_next": len(rows) > 100,
                "ou_paths": [row["ou_path"] for row in paths], "sync": sync}

    @app.get("/v2/devices/{device_id}/history")
    def history(device_id: UUID, db: Db, user: Annotated[dict, Depends(directory)]):
        write_audit(db, user["username"], "read_device_history", device_id, "allowed")
        native = db.execute(
            """SELECT w.user_sid AS employee_sid,w.username,w.state AS kind,w.transport,
                      w.logon_at AS observed_at,w.last_seen AS received_at,
                      w.current AND d.last_heartbeat > now()-interval '2 minutes' AS current
               FROM windows_sessions w JOIN devices d ON d.id=w.device_id
               WHERE d.id=%s AND d.enabled AND d.agent_hash IS NOT NULL
               ORDER BY w.logon_at DESC,w.session_id LIMIT 100""", (device_id,),
        ).fetchall()
        if native:
            return native
        return db.execute(
            """SELECT s.employee_sid,e.username,s.kind,s.transport,s.observed_at,s.received_at
               FROM session_events s JOIN employees e ON e.sid=s.employee_sid
                 JOIN devices d ON d.id=s.device_id
               WHERE d.id=%s AND d.enabled AND d.agent_hash IS NOT NULL
               ORDER BY s.observed_at DESC,s.event_id LIMIT 100""", (device_id,),
        ).fetchall()

    @app.put("/v2/devices/{device_id}/preferences")
    def preferences(device_id: UUID, payload: Preference, db: Db, user: Annotated[dict, Depends(directory)]):
        row = db.execute(
            """INSERT INTO local_device_preferences
               SELECT %s,id,%s,%s FROM devices WHERE id=%s AND enabled AND agent_hash IS NOT NULL
               ON CONFLICT (username,device_id) DO UPDATE SET favorite=excluded.favorite,
                 group_name=excluded.group_name RETURNING device_id""",
            (user["username"], payload.favorite, payload.group_name, device_id),
        ).fetchone()
        if not row:
            raise HTTPException(404, "Device unavailable")
        return row

    def connection_policy(db, user, device_id):
        return db.execute(
            """SELECT COALESCE(p.attended, true) AS attended,
                      COALESCE(d.windows_enrollment AND p.unattended_until>now()
                               AND %(admin)s,false) AS unattended
               FROM local_device_grants g JOIN devices d ON d.id=g.device_id
               LEFT JOIN corporate_access_policy p ON p.device_id=d.id
               WHERE g.username=%(username)s AND d.id=%(device)s AND d.enabled
                 AND d.agent_hash IS NOT NULL AND d.last_heartbeat > now()-interval '2 minutes'""",
            {"username": user["username"], "device": device_id, "admin": user["role"] == "admin"},
        ).fetchone() or {"attended": False, "unattended": False}

    @app.get("/v2/devices/{device_id}/connection-options")
    def options(device_id: UUID, db: Db, user: Annotated[dict, Depends(directory)]):
        policy = connection_policy(db, user, device_id)
        return {
            "attended": {"eligible": policy["attended"], "available": False},
            "unattended": {"eligible": policy["unattended"], "available": False},
            "reason": "endpoint_verification_unavailable",
        }

    @app.put("/v2/devices/{device_id}/corporate-policy")
    def configure_policy(device_id: UUID, payload: CorporatePolicy, db: Db,
                         user: Annotated[dict, Depends(mutation_admin)]):
        until = payload.unattended_until
        now = datetime.now(timezone.utc)
        if until and not now < until <= now + timedelta(days=30):
            raise HTTPException(422, "Unattended approval must expire within 30 days")
        device = db.execute(
            "SELECT 1 FROM devices WHERE id=%s AND enabled AND windows_enrollment FOR UPDATE",
            (device_id,),
        ).fetchone()
        if not device:
            write_audit(db, user["username"], "set_corporate_policy", device_id, "unmanaged_denied")
            db.commit()
            raise HTTPException(403, "Managed device required")
        db.execute(
            """INSERT INTO corporate_access_policy (device_id,attended,unattended_until) VALUES (%s,%s,%s)
               ON CONFLICT(device_id) DO UPDATE SET attended=excluded.attended,
                   unattended_until=excluded.unattended_until,updated_at=clock_timestamp()""",
            (device_id, payload.attended, until),
        )
        write_audit(db, user["username"], "set_corporate_policy", device_id,
                    f"attended:{payload.attended},unattended_until:{until.isoformat() if until else 'disabled'}")
        return {"policy_stored": True, "endpoint_ready": False}

    @app.post("/v2/devices/{device_id}/connection", status_code=501)
    def connect(device_id: UUID, db: Db, user: Annotated[dict, Depends(directory)],
                mode: Literal["consent", "unattended"] = "consent"):
        policy = connection_policy(db, user, device_id)
        eligible = policy["attended"] if mode == "consent" else policy["unattended"]
        write_audit(db, user["username"], f"connection_{mode}", device_id,
                    "endpoint_integration_required" if eligible else "denied")
        db.commit()
        if not eligible:
            raise HTTPException(403, "Device connection denied")
        raise HTTPException(501, "Endpoint enforcement is not configured")


def cli():
    import argparse
    import re

    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=["bootstrap", "reset-mfa", "grant-device", "revoke-device"])
    parser.add_argument("username")
    parser.add_argument("--device-id", type=UUID)
    args = parser.parse_args()
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        parser.error("An interactive private terminal is required")
    if not re.fullmatch(USERNAME, args.username):
        parser.error("Invalid username")
    if args.operation in ("grant-device", "revoke-device"):
        if not args.device_id:
            parser.error("--device-id is required")
        with psycopg.connect(database_url()) as db:
            if args.operation == "grant-device":
                row = db.execute(
                    """INSERT INTO local_device_grants
                       SELECT a.username,d.id FROM local_accounts a CROSS JOIN devices d
                       WHERE a.username=%s AND a.enabled AND a.role IN ('admin','support')
                         AND d.id=%s AND d.enabled
                       ON CONFLICT (username,device_id) DO UPDATE SET device_id=excluded.device_id
                       RETURNING device_id""", (args.username, args.device_id),
                ).fetchone()
                if not row:
                    parser.error("Enabled operator and registered device required")
            else:
                db.execute("DELETE FROM local_device_grants WHERE username=%s AND device_id=%s",
                           (args.username, args.device_id))
            write_audit(db, "server-cli", args.operation, args.device_id, f"account:{args.username}")
        return
    password = getpass("New password: ")
    if password != getpass("Repeat password: "):
        parser.error("Passwords differ")
    encoded = hash_password(password)
    secret = secrets.token_bytes(20)
    encrypted = key().encrypt(secret)
    with psycopg.connect(database_url()) as db:
        db.execute("SELECT pg_advisory_xact_lock(8143025)")
        if args.operation == "bootstrap":
            if db.execute("SELECT 1 FROM local_accounts WHERE role='admin'").fetchone():
                parser.error("Administrator already provisioned")
            db.execute("INSERT INTO local_accounts(username,display_name,role,password_hash,totp_secret) "
                       "VALUES (%s,%s,'admin',%s,%s)",
                       (args.username, args.username, encoded, encrypted))
        else:
            updated = db.execute(
                "UPDATE local_accounts SET password_hash=%s,totp_secret=%s,totp_step=-1,mfa_reset_requested_at=NULL "
                "WHERE username=%s AND enabled AND role IN ('admin','support') RETURNING username",
                (encoded, encrypted, args.username),
            ).fetchone()
            if not updated:
                parser.error("Enabled privileged account required")
            db.execute("DELETE FROM local_sessions WHERE username=%s", (args.username,))
        write_audit(db, "server-cli", args.operation, args.username, "allowed")
    print(f"Authenticator setup key for {args.username} (30 s, 6 digits, SHA-1):")
    print(base64.b32encode(secret).decode())


if __name__ == "__main__":
    cli()
