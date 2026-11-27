"""Production grant issuer and redeemer for a pinned RustDesk endpoint identity."""
import hmac
import os
from pathlib import Path
import time
from typing import Annotated, Literal
from uuid import UUID, uuid4

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from fastapi import Depends, HTTPException, Response
from fastapi.security import HTTPAuthorizationCredentials
import jwt
from pydantic import BaseModel, ConfigDict, Field
import psycopg

from local_auth import SESSION_LOCK, USERNAME, current_local, local_session_hash, token_hash, write_audit


ISSUER = "yesdesk-management"
AUDIENCE = "yesdesk-corporate-endpoint"
TOKEN_TYPE = "yesdesk-session-grant+jwt"
LIFETIME = 30
HEX_32 = r"^[0-9a-f]{64}$"
Mode = Literal["consent", "unattended"]


class EndpointProof(BaseModel):
    model_config = ConfigDict(extra="forbid")
    operator: str = Field(pattern=USERNAME)
    mode: Mode
    connection_id: UUID
    handshake: str = Field(pattern=HEX_32)
    timestamp: int = Field(strict=True, ge=0, le=253402300799)
    signature: str = Field(pattern=r"^[0-9a-f]{128}$")


class Redemption(EndpointProof):
    grant: str = Field(max_length=2048, pattern=r"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$")


def configured_signer():
    path = os.environ.get("YESDESK_CORPORATE_SIGNING_KEY_FILE")
    if not path:
        return None
    key = load_pem_private_key(Path(path).read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("Corporate grant signing requires an Ed25519 private key")
    return key


def claims_context(device_id, proof):
    return {
        "sub": proof.operator,
        "device": str(device_id),
        "mode": proof.mode,
        "connection": str(proof.connection_id),
        "handshake": proof.handshake,
    }


def proof_bytes(purpose, device_id, proof, grant_hash=""):
    ctx = claims_context(device_id, proof)
    return "\n".join((
        "YES Desk endpoint proof v1", purpose, ctx["device"], ctx["sub"], ctx["mode"],
        ctx["connection"], ctx["handshake"], str(proof.timestamp), grant_hash,
    )).encode("ascii")


def endpoint_key(db, device_id, fingerprint=None):
    # The enrollment broker locks certificate rows before the device. Keep that order.
    return db.execute(
        """SELECT k.public_key,k.certificate_fingerprint,k.agent_hash FROM corporate_endpoint_keys k
           JOIN device_enrollment_certificates e ON e.fingerprint=k.certificate_fingerprint
           WHERE e.device_id=%s AND e.enabled AND e.used_at IS NOT NULL
             AND k.valid_until>clock_timestamp()
             AND (%s::text IS NULL OR k.certificate_fingerprint=%s)
           FOR SHARE OF e,k""",
        (device_id, fingerprint, fingerprint),
    ).fetchone()


def verify_proof(key, purpose, device_id, proof, grant_hash=""):
    now = int(time.time())
    if (not key or not now - LIFETIME < proof.timestamp <= now or
            proof.connection_id != UUID(hex=proof.handshake[:32])):
        return False
    try:
        Ed25519PublicKey.from_public_bytes(bytes(key["public_key"])).verify(
            bytes.fromhex(proof.signature), proof_bytes(purpose, device_id, proof, grant_hash),
        )
    except InvalidSignature:
        return False
    return True


def session_entitlement(db, username, device_id, mode, session_hash, agent_hash):
    # Device lock protects the policy from concurrent edits. Other joined locks
    # serialize revocation of the account, session, or individual grant.
    return db.execute(
        """SELECT floor(extract(epoch FROM s.expires_at))::bigint AS session_end,
                  floor(extract(epoch FROM p.unattended_until))::bigint AS policy_end
           FROM local_accounts a JOIN local_sessions s USING(username)
           JOIN local_device_grants g USING(username) JOIN devices d ON d.id=g.device_id
           LEFT JOIN corporate_access_policy p ON p.device_id=d.id
           WHERE a.username=%s AND d.id=%s AND s.token_hash=%s AND a.enabled
             AND s.expires_at>clock_timestamp() AND a.role IN ('admin','support')
             AND d.enabled AND d.windows_enrollment AND d.agent_hash=%s
             AND d.last_heartbeat>clock_timestamp()-interval '2 minutes'
             AND CASE WHEN %s='unattended'
                 THEN a.role='admin' AND p.unattended_until>clock_timestamp()
                 ELSE COALESCE(p.attended,true) END
           FOR SHARE OF a,s,g,d""",
        (username, device_id, session_hash, agent_hash, mode),
    ).fetchone()


def install_grant_routes(app, get_db, bearer, signer):
    Db = Annotated[psycopg.Connection, Depends(get_db)]
    Cred = Annotated[HTTPAuthorizationCredentials, Depends(bearer)]
    verifier = signer.public_key()

    def deny(db, operator, action, target, reason, status=403):
        write_audit(db, operator, action, target, reason)
        db.commit()
        raise HTTPException(status, "Corporate session denied")

    @app.post("/v2/devices/{device_id}/session-grants", status_code=201)
    def issue(device_id: UUID, proof: EndpointProof, db: Db, cred: Cred):
        db.execute("SELECT pg_advisory_xact_lock(%s)", (SESSION_LOCK,))
        user = current_local(db, cred.credentials)
        operator = user["username"]
        action = "session_grant_issue"
        if operator != proof.operator:
            deny(db, operator, action, device_id, "operator_mismatch")
        enrolled = endpoint_key(db, device_id)
        if not verify_proof(enrolled, "issue", device_id, proof):
            deny(db, operator, action, device_id, "endpoint_proof_denied")
        session_hash = local_session_hash(cred.credentials)
        rights = session_entitlement(db, operator, device_id, proof.mode, session_hash, enrolled["agent_hash"])
        if not rights:
            deny(db, operator, action, device_id, "entitlement_denied")
        now = int(time.time())
        expiry = min(now + LIFETIME, proof.timestamp + LIFETIME, rights["session_end"], user["expires_at"])
        if proof.mode == "unattended":
            expiry = min(expiry, rights["policy_end"])
        if expiry <= now:
            deny(db, operator, action, device_id, "expired_context")
        grant_id = uuid4()
        fingerprint = enrolled["certificate_fingerprint"]
        claims = {
            **claims_context(device_id, proof), "endpoint": fingerprint,
            "endpoint_key": bytes(enrolled["public_key"]).hex(),
            "iss": ISSUER, "aud": AUDIENCE, "jti": str(grant_id), "iat": now, "exp": expiry,
        }
        grant = jwt.encode(claims, signer, algorithm="EdDSA", headers={"typ": TOKEN_TYPE})
        row = db.execute(
            """INSERT INTO corporate_session_grants
                 (id,username,device_id,session_hash,certificate_fingerprint,connection_id,handshake,token_hash,expires_at)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING RETURNING id""",
            (grant_id, operator, device_id, session_hash, fingerprint, proof.connection_id,
             proof.handshake, token_hash(grant), expiry),
        ).fetchone()
        if not row:
            deny(db, operator, action, device_id, "connection_already_issued", 409)
        write_audit(db, operator, action, grant_id, "issued")
        db.commit()
        return {"grant": grant}

    @app.post("/v2/devices/{device_id}/session-grants/redeem", status_code=204, response_class=Response)
    def redeem(device_id: UUID, proof: Redemption, db: Db):
        action = "session_grant_redeem"
        context = claims_context(device_id, proof)
        try:
            decoded = jwt.decode_complete(
                proof.grant, verifier, algorithms=["EdDSA"], issuer=ISSUER, audience=AUDIENCE,
                options={"require": [*context, "endpoint", "endpoint_key", "iss", "aud", "jti", "iat", "exp"]},
            )
            claims = decoded["payload"]
            grant_id = UUID(claims["jti"])
            if decoded["header"] != {"alg": "EdDSA", "typ": TOKEN_TYPE}:
                raise ValueError("Unexpected header")
        except jwt.ExpiredSignatureError:
            deny(db, "unverified", action, device_id, "expired")
        except (jwt.InvalidTokenError, ValueError, TypeError):
            deny(db, "unverified", action, device_id, "invalid_signature_or_format")
        if any(claims[field] != expected for field, expected in context.items()):
            deny(db, claims["sub"], action, grant_id, "context_mismatch")
        db.execute("SELECT pg_advisory_xact_lock(%s)", (SESSION_LOCK,))
        row = db.execute("SELECT * FROM corporate_session_grants WHERE id=%s FOR UPDATE", (grant_id,)).fetchone()
        digest = token_hash(proof.grant)
        if (not row or row["revoked_at"] or row["consumed_at"] or
                not hmac.compare_digest(row["token_hash"], digest)):
            deny(db, claims["sub"], action, grant_id, "grant_unavailable")
        enrolled = endpoint_key(db, device_id, row["certificate_fingerprint"])
        if (not verify_proof(enrolled, "redeem", device_id, proof, digest) or
                not hmac.compare_digest(bytes(enrolled["public_key"]).hex(), claims["endpoint_key"]) or
                claims["endpoint"] != enrolled["certificate_fingerprint"]):
            deny(db, claims["sub"], action, grant_id, "endpoint_proof_denied")
        if not session_entitlement(db, row["username"], device_id, proof.mode,
                                   row["session_hash"], enrolled["agent_hash"]):
            deny(db, claims["sub"], action, grant_id, "entitlement_revoked")
        consumed = db.execute(
            """UPDATE corporate_session_grants SET consumed_at=clock_timestamp()
               WHERE id=%s AND consumed_at IS NULL AND revoked_at IS NULL
                 AND expires_at>extract(epoch FROM clock_timestamp())
               RETURNING id""", (grant_id,),
        ).fetchone()
        if not consumed:
            deny(db, claims["sub"], action, grant_id, "expired_or_unavailable")
        write_audit(db, claims["sub"], action, grant_id, "consumed")
        db.commit()
        return Response(status_code=204)

    @app.delete("/v2/session-grants/{grant_id}", status_code=204, response_class=Response)
    def revoke(grant_id: UUID, db: Db, cred: Cred):
        db.execute("SELECT pg_advisory_xact_lock(%s)", (SESSION_LOCK,))
        operator = current_local(db, cred.credentials)["username"]
        row = db.execute(
            """UPDATE corporate_session_grants SET revoked_at=clock_timestamp()
               WHERE id=%s AND username=%s AND revoked_at IS NULL AND consumed_at IS NULL RETURNING id""",
            (grant_id, operator),
        ).fetchone()
        if not row:
            deny(db, operator, "session_grant_revoke", grant_id, "grant_unavailable", 404)
        write_audit(db, operator, "session_grant_revoke", grant_id, "revoked")
        db.commit()
        return Response(status_code=204)
