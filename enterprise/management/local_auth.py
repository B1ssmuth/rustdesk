import base64
from getpass import getpass
import hashlib
import hmac
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
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import BaseModel, ConfigDict, Field, SecretStr
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


class PasswordChange(BaseModel):
    current: SecretStr = Field(min_length=1, max_length=256)
    replacement: SecretStr = Field(min_length=14, max_length=256)


class Preference(BaseModel):
    favorite: bool
    group_name: str = Field(max_length=80)


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

    @app.post("/v2/auth/login")
    def login(payload: Login, db: Db):
        limit_attempt(db, payload.username)
        user = db.execute("SELECT * FROM local_accounts WHERE username=%s FOR UPDATE",
                          (payload.username,)).fetchone()
        valid = check_password(user["password_hash"] if user else DUMMY_HASH,
                               payload.password.get_secret_value())
        if valid and user and user["enabled"]:
            if user["role"] in ("admin", "support"):
                valid = False
                if user["totp_secret"] and payload.code:
                    code = payload.code.get_secret_value()
                    if code.isascii() and code.isdigit():
                        now = int(time.time()) // 30
                        secret = key().decrypt(bytes(user["totp_secret"]))
                        for step in (now-1, now, now+1):
                            if step > user["totp_step"] and hmac.compare_digest(totp_code(secret, step), code):
                                db.execute("UPDATE local_accounts SET totp_step=%s WHERE username=%s",
                                           (step, payload.username))
                                valid = True
                                break
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
    def create(payload: Account, db: Db, user: Annotated[dict, Depends(admin)]):
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
                    user: Annotated[dict, Depends(admin)]):
        if username == user["username"]:
            raise HTTPException(409, "Cannot block your own account")
        row = db.execute("UPDATE local_accounts SET enabled=%s WHERE username=%s RETURNING username",
                         (payload.enabled, username)).fetchone()
        if not row:
            raise HTTPException(404, "Account unavailable")
        db.execute("DELETE FROM local_sessions WHERE username=%s", (username,))
        write_audit(db, user["username"], "set_account_enabled", username, str(payload.enabled))
        return row

    @app.get("/v2/devices")
    def devices(db: Db, user: Annotated[dict, Depends(directory)], q: str = ""):
        if len(q) > 100:
            raise HTTPException(422, "Search term too long")
        return db.execute(
            """SELECT d.id,d.hostname,d.dns_name,d.yesdesk_id,d.metadata,d.last_heartbeat,
                      COALESCE(d.last_heartbeat > now()-interval '2 minutes',false) AS online,
                      COALESCE(p.favorite,false) AS favorite, COALESCE(p.group_name,'') AS group_name,
                      g.device_id IS NOT NULL AS can_request_consent
               FROM devices d LEFT JOIN local_device_preferences p
                 ON p.device_id=d.id AND p.username=%(username)s
               LEFT JOIN local_device_grants g ON g.device_id=d.id AND g.username=%(username)s
               WHERE d.enabled AND d.agent_hash IS NOT NULL AND
                 (%(q)s='' OR strpos(lower(d.hostname), lower(%(q)s))>0
                   OR strpos(lower(d.yesdesk_id), lower(%(q)s))>0
                   OR EXISTS (SELECT 1 FROM windows_sessions w
                     WHERE w.device_id=d.id AND strpos(lower(w.username),lower(%(q)s))>0)
                   OR EXISTS (SELECT 1 FROM session_events s JOIN employees e ON e.sid=s.employee_sid
                     WHERE s.device_id=d.id AND strpos(lower(e.username), lower(%(q)s))>0))
               ORDER BY favorite DESC,d.hostname,d.id LIMIT 100""",
            {"username": user["username"], "q": q},
        ).fetchall()

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

    @app.post("/v2/devices/{device_id}/connection", status_code=501)
    def connect(device_id: UUID, db: Db, user: Annotated[dict, Depends(directory)]):
        grant = db.execute(
            """SELECT 1 FROM local_device_grants g JOIN devices d ON d.id=g.device_id
               WHERE g.username=%s AND d.id=%s AND d.enabled AND d.agent_hash IS NOT NULL
                 AND d.last_heartbeat > now()-interval '2 minutes'""",
            (user["username"], device_id),
        ).fetchone()
        write_audit(db, user["username"], "connection_consent", device_id,
                    "endpoint_integration_required" if grant else "denied")
        db.commit()
        if not grant:
            raise HTTPException(403, "Device connection denied")
        raise HTTPException(501, "Endpoint enforcement is not configured")


def cli():
    import argparse
    import re

    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=["bootstrap", "reset-mfa"])
    parser.add_argument("username")
    args = parser.parse_args()
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        parser.error("An interactive private terminal is required")
    if not re.fullmatch(USERNAME, args.username):
        parser.error("Invalid username")
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
            db.execute("INSERT INTO local_accounts VALUES (%s,%s,'admin',%s,%s,-1,true)",
                       (args.username, args.username, encoded, encrypted))
        else:
            updated = db.execute(
                "UPDATE local_accounts SET password_hash=%s,totp_secret=%s,totp_step=-1 "
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
