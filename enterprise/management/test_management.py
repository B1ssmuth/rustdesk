from concurrent.futures import ThreadPoolExecutor
from base64 import urlsafe_b64decode, urlsafe_b64encode
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import tempfile
from threading import Barrier
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from uuid import UUID, uuid4

from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
import jwt
import psycopg
from psycopg.rows import dict_row

from app import create_app, production_app, role_for
from ad_sync import update as sync_directory
from local_auth import hash_password, local_session_hash, start_local_session, token_hash, totp_code
from enrollment_broker import register
from migrate import migrate
from provision import apply_directory, issue_test_code, pin_transport
from settings import database_url


GROUPS = dict(admin="CN=YESDesk-Admins,DC=test", support="CN=YESDesk-Support,DC=test",
              user="CN=YESDesk-Users,DC=test")
ISSUER = "https://idp.example.test"
AUDIENCE = "yesdesk-management-test"
ADMIN = "S-1-5-21-12-13-14-101"
USER = "S-1-5-21-12-13-14-102"


class ContractTests(unittest.TestCase):
    def test_role_mapping_precedence_and_no_implicit_role(self):
        self.assertEqual(role_for({GROUPS["admin"], GROUPS["user"]}, GROUPS), "admin")
        self.assertEqual(role_for({GROUPS["support"]}, GROUPS), "support")
        self.assertIsNone(role_for({"CN=Domain Admins,DC=test"}, GROUPS))

    def test_openapi_exposes_agent_and_employee_authorization(self):
        app = create_app(ISSUER, AUDIENCE, ISSUER + "/keys", GROUPS)
        contract = app.openapi()["paths"]
        self.assertEqual(contract["/v1/me"]["get"]["security"], [{"HTTPBearer": []}])
        self.assertEqual(contract["/v1/agents/session"]["post"]["security"], [{"HTTPBearer": []}])
        self.assertNotIn("/v2/devices/{device_id}/session-grants", contract)


@unittest.skipUnless(os.environ.get("YESDESK_INTEGRATION") == "1",
                     "Requires a fresh disposable PostgreSQL database")
class PostgresTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if psycopg.conninfo.conninfo_to_dict(database_url()).get("dbname") != "yesdesk_enterprise_test":
            raise ValueError("Use the disposable yesdesk_enterprise_test database for this suite")
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        migrate()
        migrate()

    def setUp(self):
        self.app = create_app(ISSUER, AUDIENCE, ISSUER + "/keys", GROUPS, test_agents=True)
        self.client = TestClient(self.app)
        fixture_key = SimpleNamespace(key=self.key.public_key())
        patcher = patch("jwt.PyJWKClient.get_signing_key_from_jwt", return_value=fixture_key)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.device = str(uuid4())
        self.snapshot = {"employees": [
            dict(sid=ADMIN, username="supporter", display_name="Lab Admin",
                 subject="operator", group_dns=[GROUPS["admin"]]),
            dict(sid=USER, username="worker", display_name="Lab Employee",
                 subject="staff", group_dns=[GROUPS["user"]]),
        ]}
        with psycopg.connect(database_url()) as db:
            db.execute("TRUNCATE audit, employees, devices CASCADE")
            apply_directory(db, self.snapshot)
            with patch.dict(os.environ, {"YESDESK_ENV": "test"}):
                self.code = issue_test_code(
                    db, dict(id=self.device, computer_sid="S-1-5-21-12-13-14-201",
                             dns_name="workstation.example.test", hostname="WORKSTATION",
                             yesdesk_id="12345678"),
                )

    def headers(self, subject="operator", **changes):
        now = int(datetime.now(timezone.utc).timestamp())
        claims = dict(iss=ISSUER, aud=AUDIENCE, sub=subject, iat=now, exp=now + 300)
        claims.update(changes)
        token = jwt.encode(claims, self.key, algorithm="RS256", headers={"kid": "fixture"})
        return {"Authorization": f"Bearer {token}"}

    def test_corporate_grant_lifecycle_through_production_routes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            signer = Ed25519PrivateKey.generate()
            key_file = root / "grant.pem"
            key_file.write_bytes(signer.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()))
            mfa_file = root / "mfa"
            mfa_file.write_bytes(Fernet.generate_key())
            with patch.dict(os.environ, {
                "YESDESK_CORPORATE_SIGNING_KEY_FILE": str(key_file), "YESDESK_WINDOWS_AGENTS": "1",
                "YESDESK_CORPORATE_PILOT_DEVICE": self.device,
                "YESDESK_LEGACY_OIDC": "0", "YESDESK_MFA_KEY_FILE": str(mfa_file),
            }):
                client = TestClient(production_app())

            host = Ed25519PrivateKey.generate()
            device = UUID(self.device)
            operator = "grant-test-admin"
            agent_client = TestClient(create_app(None, None, None, {}, enrolled_agents=True))
            with psycopg.connect(database_url()) as db:
                db.execute("DELETE FROM local_accounts WHERE username=%s", (operator,))
                db.execute("INSERT INTO local_accounts (username,display_name,role,password_hash) "
                           "VALUES (%s,'Grant Test','admin','unusable')", (operator,))
                db.execute("INSERT INTO local_device_grants VALUES (%s,%s)", (operator, device))
                db.execute("UPDATE devices SET windows_enrollment=true WHERE id=%s", (device,))
            enrolled = agent_client.post("/v2/agents/enroll", json={
                "device_id": self.device, "enrollment_code": self.code,
            })
            self.assertEqual(enrolled.status_code, 200, enrolled.text)
            agent = token_hash(enrolled.json()["agent_token"])
            with psycopg.connect(database_url()) as db:
                db.execute("UPDATE devices SET last_heartbeat=now() WHERE id=%s", (device,))
                config = {"id": self.device, "dns_name": "WORKSTATION.EXAMPLE.TEST.",
                          "yesdesk_id": "12345678", "endpoint_key": host.public_key().public_bytes_raw().hex(),
                          "valid_until": (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()}
                with self.assertRaisesRegex(ValueError, "matching registered"):
                    pin_transport(db, {**config, "yesdesk_id": "87654321"})
                pin_transport(db, config)
                self.assertEqual(db.execute("SELECT agent_hash FROM corporate_transport_keys WHERE device_id=%s",
                                            (device,)).fetchone(), (agent,))

            with psycopg.connect(database_url(), row_factory=dict_row) as db:
                session = start_local_session(db, operator, renewable=True)

            path = f"/v2/devices/{device}/session-grants"
            auth = {"Authorization": "Bearer " + session["token"]}
            refresh = {"Authorization": "Bearer " + session["refresh_token"]}

            def make_proof(purpose, bound_device, context, grant=""):
                timestamp = int(time.time())
                data = "\n".join((
                    "YES Desk endpoint proof v1", purpose, str(bound_device), context["operator"], context["mode"],
                    context["connection_id"], context["handshake"], str(timestamp), token_hash(grant) if grant else "",
                )).encode("ascii")
                return {**context, "timestamp": timestamp, "signature": host.sign(data).hex()}

            def issue():
                connection = uuid4()
                context = {"operator": operator, "mode": "consent", "connection_id": str(connection),
                           "handshake": connection.hex + uuid4().hex}
                response = client.post(path, headers=auth, json=make_proof("issue", device, context))
                self.assertEqual(response.status_code, 201, response.text)
                return context, response.json()["grant"]

            def redeem(context, grant, target=device, cli=client):
                proof = make_proof("redeem", target, context, grant)
                return cli.post(f"/v2/devices/{target}/session-grants/redeem", json={**proof, "grant": grant})

            def unpack(grant):
                segment = grant.split(".")[1]
                return json.loads(urlsafe_b64decode(segment + "=" * (-len(segment) % 4)))

            self.assertEqual(client.get("/health/ready").status_code, 200)
            self.assertEqual(client.post(f"/v2/devices/{device}/connection", headers=auth).status_code, 501)
            options = client.get(f"/v2/devices/{device}/connection-options", headers=auth).json()
            self.assertTrue(options["attended"]["available"])
            self.assertFalse(options["unattended"]["available"])
            self.assertEqual(options["launch"]["endpoint_key"], host.public_key().public_bytes_raw().hex())
            self.assertNotIn("launch", client.get(f"/v2/devices/{uuid4()}/connection-options", headers=auth).json())
            context, grant = issue()
            with self.subTest("tampered grant signature"):
                head, payload, signature = grant.split(".")
                corrupted = urlsafe_b64decode(signature + "=" * (-len(signature) % 4))
                bad_sig = urlsafe_b64encode(bytes([corrupted[0] ^ 1]) + corrupted[1:]).rstrip(b"=").decode()
                self.assertEqual(redeem(context, ".".join((head, payload, bad_sig))).status_code, 403)
            for field, value in (
                ("operator", "other-operator"), ("mode", "unattended"), ("connection_id", str(uuid4())),
                ("handshake", "f" * 64),
            ):
                with self.subTest(field=field):
                    expected = 422 if field == "mode" else 403
                    self.assertEqual(redeem({**context, field: value}, grant).status_code, expected)
            self.assertEqual(client.post(path, headers=auth, json=make_proof(
                "issue", device, {**context, "mode": "unattended"})).status_code, 422)
            self.assertEqual(redeem(context, grant, uuid4()).status_code, 403)
            wrong_proof = {**make_proof("redeem", device, context, grant), "signature": "0" * 128, "grant": grant}
            self.assertEqual(client.post(path + "/redeem", json=wrong_proof).status_code, 403)
            with patch("local_auth.ACCESS_WINDOW", 800):
                renewed = client.post("/v2/auth/refresh", headers=refresh).json()["token"]
            self.assertNotEqual(renewed, session["token"])
            self.assertEqual(redeem(context, grant).status_code, 204)
            self.assertEqual(redeem(context, grant).status_code, 403)
            auth["Authorization"] = "Bearer " + renewed
            self.assertEqual(client.post(path, headers=auth, json=make_proof("issue", device, context)).status_code, 409)

            context, grant = issue()
            gate = Barrier(2, timeout=10)

            def competitor():
                with TestClient(client.app) as parallel_client:
                    gate.wait()
                    return redeem(context, grant, cli=parallel_client).status_code

            with ThreadPoolExecutor(max_workers=2) as pool:
                jobs = [pool.submit(competitor) for _ in range(2)]
                self.assertEqual(sorted(job.result(timeout=20) for job in jobs), [204, 403])

            context, grant = issue()
            self.assertEqual(client.delete(f"/v2/session-grants/{unpack(grant)['jti']}", headers=auth).status_code, 204)
            self.assertEqual(redeem(context, grant).status_code, 403)

            context, grant = issue()
            with psycopg.connect(database_url()) as db:
                db.execute("UPDATE corporate_session_grants SET expires_at=1 WHERE id=%s", (unpack(grant)["jti"],))
            self.assertEqual(redeem(context, grant).status_code, 403)
            past = {**unpack(grant), "iat": int(time.time()) - 60, "exp": int(time.time()) - 30}
            expired_grant = jwt.encode(past, signer, algorithm="EdDSA", headers={"typ": "yesdesk-session-grant+jwt"})
            self.assertEqual(redeem(context, expired_grant).status_code, 403)

            context, grant = issue()
            disabled_database = root / "offline-dsn"
            disabled_database.write_text("host=127.0.0.1 port=1 dbname=yesdesk_enterprise_test connect_timeout=1")
            with patch.dict(os.environ, {"YESDESK_DATABASE_URL_FILE": str(disabled_database)}):
                self.assertEqual(redeem(context, grant).status_code, 503)
            with psycopg.connect(database_url()) as db:
                db.execute("DELETE FROM local_device_grants WHERE username=%s AND device_id=%s", (operator, device))
            self.assertEqual(redeem(context, grant).status_code, 403)

            with psycopg.connect(database_url()) as db:
                db.execute("INSERT INTO local_device_grants VALUES (%s,%s)", (operator, device))
            context, grant = issue()
            with psycopg.connect(database_url()) as db:
                db.execute("UPDATE devices SET enabled=false WHERE id=%s", (device,))
            self.assertEqual(redeem(context, grant).status_code, 403)
            with psycopg.connect(database_url()) as db:
                count = db.execute("SELECT count(*) FROM audit WHERE action='session_grant_redeem' AND outcome='consumed'")
                self.assertEqual(count.fetchone(), (2,))
                db.execute("UPDATE devices SET enabled=true WHERE id=%s", (device,))
            context, grant = issue()
            with psycopg.connect(database_url()) as db:
                db.execute("UPDATE devices SET agent_hash=%s WHERE id=%s", ("b" * 64, device))
            self.assertNotIn("launch", client.get(path.replace("session-grants", "connection-options"),
                                                  headers=auth).json())
            self.assertEqual(redeem(context, grant).status_code, 403)
            with psycopg.connect(database_url()) as db:
                db.execute("UPDATE devices SET agent_hash=%s WHERE id=%s", (agent, device))
            context, grant = issue()
            self.assertEqual(client.post("/v2/auth/logout", headers=refresh).status_code, 200)
            self.assertEqual(redeem(context, grant).status_code, 403)

    def test_rbac_rechecks_groups_and_rejects_wrong_token(self):
        self.assertEqual(self.client.get("/health/ready").status_code, 200)
        self.assertEqual(self.client.get("/v1/me", headers=self.headers()).json()["role"], "admin")
        self.assertEqual(self.client.get("/v1/me", headers=self.headers(aud="other")).status_code, 401)
        self.assertEqual(self.client.get("/v1/me", headers=self.headers(iss="other")).status_code, 401)
        self.assertEqual(self.client.get("/v1/employees", headers=self.headers("staff")).status_code, 403)
        with psycopg.connect(database_url()) as db:
            self.snapshot["employees"][0]["group_dns"] = [GROUPS["user"]]
            apply_directory(db, self.snapshot)
        self.assertEqual(self.client.get("/v1/employees", headers=self.headers()).status_code, 403)
        with psycopg.connect(database_url()) as db:
            db.execute("UPDATE directory_snapshot SET imported_at=now() - interval '2 hours'")
        self.assertEqual(self.client.get("/v1/me", headers=self.headers("staff")).status_code, 403)

    def test_employee_device_session_and_fail_closed_connection(self):
        enrollment = {"device_id": self.device, "enrollment_code": self.code}
        response = self.client.post("/v1/agents/enroll", json=enrollment)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.client.post("/v1/agents/enroll", json=enrollment).status_code, 401)
        agent = {"Authorization": "Bearer " + response.json()["agent_token"]}
        hardware = dict(os="Windows", model="Lab", cpu="x64", ram_bytes=1024, disks=[])
        self.assertEqual(self.client.post("/v1/agents/heartbeat", headers=agent, json=hardware).status_code, 200)
        now = datetime.now(timezone.utc)
        instance = str(uuid4())
        for index, kind in enumerate(("logon", "active", "logoff")):
            payload = dict(event_id=str(uuid4()), employee_sid=USER, session_instance=instance,
                           windows_session_id=2, kind=kind, transport="rdp",
                           observed_at=(now - timedelta(seconds=3-index)).isoformat())
            for _ in range(2):
                response = self.client.post("/v1/agents/session", headers=agent, json=payload)
                self.assertEqual(response.status_code, 200, response.text)
        conflict = self.client.post("/v1/agents/session", headers=agent, json={
            **payload, "employee_sid": ADMIN, "event_id": str(uuid4()),
        })
        self.assertEqual(conflict.status_code, 409)
        path = f"/v1/employees/{USER}/workplaces"
        card = self.client.get(path, headers=self.headers()).json()
        self.assertEqual(card["last_workplace_id"], self.device)
        device = card["devices"][0]
        self.assertEqual(device["yesdesk_id"], "12345678")
        self.assertFalse(device["active_confirmed"])
        self.assertTrue(device["last_logon"] and device["last_active"] and device["last_logoff"])
        path = f"/v1/devices/{self.device}/connection"
        self.assertEqual(self.client.post(path, headers=self.headers()).status_code, 403)
        with psycopg.connect(database_url()) as db:
            db.execute("INSERT INTO device_grants VALUES (%s,%s,true,false)", (ADMIN, self.device))
            self.assertEqual(db.execute("SELECT count(*) FROM session_events").fetchone()[0], 3)
        self.assertEqual(self.client.post(path, headers=self.headers()).status_code, 501)
        self.assertEqual(self.client.post(path + "?mode=unattended", headers=self.headers()).status_code, 403)
        with psycopg.connect(database_url()) as db:
            self.assertEqual(db.execute(
                "SELECT count(*) FROM audit WHERE action LIKE 'connection_%'"
            ).fetchone()[0], 3)

    def test_production_rejects_lab_agent_enrollment(self):
        production = TestClient(create_app(ISSUER, AUDIENCE, ISSUER + "/keys", GROUPS))
        response = production.post("/v1/agents/enroll",
                                   json=dict(device_id=self.device, enrollment_code=self.code))
        self.assertEqual(response.status_code, 503)
        self.assertNotIn("/v1/lab/devices/{device_id}/grants",
                         production.get("/openapi.json").json()["paths"])

    def test_local_mfa_revocation_and_rate_limit(self):
        client = TestClient(create_app(None, None, None, {}))
        secret = b"isolated-test-totp-secret"
        key = Fernet.generate_key()
        cipher = Fernet(key)
        with tempfile.TemporaryDirectory() as directory:
            key_path = Path(directory) / "key"
            key_path.write_bytes(key)
            with patch.dict(os.environ, {"YESDESK_MFA_KEY_FILE": str(key_path)}):
                with psycopg.connect(database_url()) as db:
                    db.execute("TRUNCATE local_accounts,local_login_limits CASCADE")
                    db.execute("INSERT INTO local_accounts(username,display_name,role,password_hash,totp_secret) "
                               "VALUES ('local-admin','Lab Admin','admin',%s,%s)",
                               (hash_password("local test admin password"), cipher.encrypt(secret)))
                base = {"username": "local-admin", "password": "local test admin password"}
                self.assertEqual(client.post("/v2/auth/login", json=base).status_code, 401)
                step = int(time.time()) // 30
                invalid = next(f"{value:06}" for value in range(5)
                               if f"{value:06}" not in {totp_code(secret, s) for s in (step-1,step,step+1)})
                login = {**base, "code": totp_code(secret, step)}
                self.assertEqual(client.post("/v2/auth/login", json={**login, "password": "wrong"}).status_code, 401)
                self.assertEqual(client.post("/v2/auth/login", json={**login, "code": invalid}).status_code, 401)
                result = client.post("/v2/auth/login", json=login)
                self.assertEqual(result.status_code, 200, result.text)
                adm = {"Authorization": "Bearer " + result.json()["token"]}
                self.assertEqual(client.post("/v2/auth/login", json=login).status_code, 401)
                listed = client.get("/v2/accounts?q=lab", headers=adm).json()
                self.assertEqual(listed, [dict(username="local-admin", display_name="Lab Admin",
                                               role="admin", enabled=True, mfa_state="configured")])
                self.assertEqual(client.delete("/v2/accounts/local-admin", headers=adm).status_code, 405)
                self.assertEqual(client.put("/v2/accounts/local-admin", headers=adm,
                                            json={"enabled": False}).status_code, 409)
                self.assertEqual(client.patch("/v2/accounts/local-admin", headers=adm,
                                              json={"display_name": "Admin", "role": "user"}).status_code, 409)
                user = {"username": "local-user", "password": "local test user password"}
                self.assertEqual(client.post("/v2/accounts", headers=adm,
                                             json={**user, "display_name": "User", "role": "user"}).status_code, 201)
                user_token = client.post("/v2/auth/login", json=user).json()["token"]
                headers = {"Authorization": "Bearer " + user_token}
                self.assertEqual(client.get("/v2/devices", headers=headers).status_code, 403)
                self.assertEqual(client.put("/v2/accounts/local-user", headers=adm,
                                            json={"enabled": False}).status_code, 200)
                self.assertEqual(client.get("/v2/auth/me", headers=headers).status_code, 401)
                self.assertEqual(client.put("/v2/accounts/local-user", headers=adm,
                                            json={"enabled": True}).status_code, 200)
                renewable = client.post("/v2/auth/session", json=user).json()
                headers = {"Authorization": "Bearer " + renewable["token"]}
                saved = {"Authorization": "Bearer " + renewable["refresh_token"]}
                self.assertEqual(client.post("/v2/accounts/local-user/revoke-sessions", headers=adm).status_code, 200)
                self.assertEqual(client.get("/v2/auth/me", headers=headers).status_code, 401)
                self.assertEqual(client.post("/v2/auth/refresh", headers=saved).status_code, 401)
                headers = {"Authorization": "Bearer " + client.post("/v2/auth/login", json=user).json()["token"]}
                self.assertEqual(client.patch("/v2/accounts/local-user", headers=adm,
                                              json={"display_name": "Help Desk", "role": "support"}).status_code, 200)
                self.assertEqual(client.get("/v2/auth/me", headers=headers).status_code, 401)
                with psycopg.connect(database_url()) as db:
                    db.execute("UPDATE local_accounts SET totp_secret=%s WHERE username='local-user'",
                              (cipher.encrypt(b"support-fixture-secret"),))
                    # Simulate reaching the next unused TOTP interval without sleeping.
                    db.execute("UPDATE local_accounts SET totp_step=%s WHERE username='local-admin'", (step-1,))
                support = client.post("/v2/auth/login", json={**user, "code": totp_code(b"support-fixture-secret",
                                                                                     int(time.time()) // 30)})
                self.assertEqual(support.status_code, 200, support.text)
                sup = {"Authorization": "Bearer " + support.json()["token"]}
                self.assertEqual(client.get("/v2/accounts", headers=sup).status_code, 403)
                self.assertEqual(client.patch("/v2/accounts/local-admin", headers=sup,
                                              json={"display_name": "Changed", "role": "user"}).status_code, 403)
                reset = client.post("/v2/accounts/local-user/request-mfa-reset", headers=adm,
                                    json={"password": base["password"], "code": login["code"]})
                self.assertEqual(reset.status_code, 200, reset.text)
                self.assertEqual(reset.json(), {"mfa_state": "reset_pending"})
                self.assertEqual(client.get("/v2/auth/me", headers=sup).status_code, 401)
                self.assertEqual(client.post("/v2/auth/logout", headers=adm).status_code, 200)
                self.assertEqual(client.get("/v2/auth/me", headers=adm).status_code, 401)
                for _ in range(8):
                    self.assertEqual(client.post("/v2/auth/login", json={"username": "missing",
                                                 "password": "bad"}).status_code, 401)
                self.assertEqual(client.post("/v2/auth/login", json={"username": "missing",
                                             "password": "bad"}).status_code, 429)

    def test_renewable_session_mfa_lifetimes_and_revocation(self):
        client = TestClient(create_app(None, None, None, {}))
        secret = b"renewable-test-totp"
        key = Fernet.generate_key()
        username = "renewable-admin"
        credentials = dict(username=username, password="renewable test password")

        def bearer(token):
            return {"Authorization": f"Bearer {token}"}

        with tempfile.TemporaryDirectory() as directory:
            key_file = Path(directory) / "mfa"
            key_file.write_bytes(key)
            with patch.dict(os.environ, {"YESDESK_MFA_KEY_FILE": str(key_file)}):
                with psycopg.connect(database_url()) as db:
                    db.execute("DELETE FROM local_accounts WHERE username=%s", (username,))
                    db.execute("INSERT INTO local_accounts(username,display_name,role,password_hash,totp_secret) "
                               "VALUES (%s,'Renewable Admin','admin',%s,%s)",
                               (username, hash_password(credentials["password"]), Fernet(key).encrypt(secret)))
                self.assertEqual(client.post("/v2/auth/session", json=credentials).status_code, 401)
                now = int(time.time())
                login = {**credentials, "code": totp_code(secret, now // 30)}
                with patch("local_auth.time.time", return_value=now):
                    result = client.post("/v2/auth/session", json=login)
                    self.assertEqual(result.status_code, 200, result.text)
                    self.assertEqual(client.post("/v2/auth/session", json=login).status_code, 401)
                initial = result.json()

        access, refresh = initial["token"], initial["refresh_token"]
        profile = initial["profile"]
        self.assertGreater(profile["session_expires_at"] - now, 43190)
        self.assertLessEqual(profile["session_expires_at"] - now, 43210)
        self.assertLessEqual(profile["expires_at"] - now, 1800)
        self.assertEqual(local_session_hash(access), token_hash(refresh))
        self.assertEqual(client.get("/v2/accounts", headers=bearer(access)).status_code, 200)
        self.assertEqual(client.get("/v2/accounts", headers=bearer(refresh)).status_code, 401)
        self.assertEqual(client.post("/v2/auth/refresh", headers=bearer(access)).status_code, 401)
        forged = access[:-43] + "a" * 43
        self.assertEqual(client.post("/v2/auth/logout", headers=bearer(forged)).status_code, 200)
        self.assertEqual(client.get("/v2/auth/me", headers=bearer(access)).status_code, 200)

        with psycopg.connect(database_url()) as db:
            db.execute("UPDATE local_sessions SET expires_at=now()-interval '1 second' WHERE token_hash=%s",
                       (token_hash(access),))
        self.assertEqual(client.get("/v2/auth/me", headers=bearer(access)).status_code, 401)
        gate = Barrier(2, timeout=10)

        def refresh_in_parallel():
            with TestClient(client.app) as parallel_client:
                gate.wait()
                return parallel_client.post("/v2/auth/refresh", headers=bearer(refresh))

        with patch("local_auth.ACCESS_WINDOW", 800), ThreadPoolExecutor(max_workers=2) as pool:
            jobs = [pool.submit(refresh_in_parallel) for _ in range(2)]
            replies = [job.result(timeout=20) for job in jobs]
        for reply in replies:
            self.assertEqual(reply.status_code, 200, reply.text)
            self.assertEqual(reply.json()["profile"]["session_expires_at"], profile["session_expires_at"])
        renewed = replies[0].json()["token"]
        self.assertEqual(renewed, replies[1].json()["token"])
        self.assertNotEqual(renewed, access)

        with psycopg.connect(database_url()) as db:
            db.execute("UPDATE local_sessions SET expires_at=now()-interval '1 second' WHERE token_hash=%s",
                       (token_hash(refresh),))
        self.assertEqual(client.post("/v2/auth/refresh", headers=bearer(refresh)).status_code, 401)
        self.assertEqual(client.get("/v2/auth/me", headers=bearer(renewed)).status_code, 401)

        with psycopg.connect(database_url(), row_factory=dict_row) as db:
            second = start_local_session(db, username, renewable=True)
        self.assertEqual(client.post("/v2/auth/logout", headers=bearer(second["token"])).status_code, 200)
        self.assertEqual(client.post("/v2/auth/refresh", headers=bearer(second["refresh_token"])).status_code, 401)
        self.assertEqual(client.get("/v2/auth/me", headers=bearer(second["token"])).status_code, 401)

    def test_windows_enrollment_inventory_and_device_binding(self):
        client = TestClient(create_app(None, None, None, {}, enrolled_agents=True))
        machine = str(uuid4())
        with psycopg.connect(database_url()) as db:
            code = issue_test_code(db, dict(id=machine, computer_sid="S-1-5-21-12-13-14-701",
                                            dns_name="windows.example.test", hostname="WINTEST",
                                            yesdesk_id="123456700"), windows=True)
        enrollment = dict(device_id=machine, enrollment_code=code)
        token = client.post("/v2/agents/enroll", json=enrollment).json()["agent_token"]
        self.assertEqual(client.post("/v2/agents/enroll", json=enrollment).status_code, 401)
        headers = {"Authorization": "Bearer " + token}
        data = dict(machine_guid=machine, hostname="WINTEST", domain="WORKGROUP",
                    os="Windows", model="Lab", cpu="x64", ram_bytes=1024, disks=[],
                    sessions=[dict(session_id=2, sid=USER, username="WINTEST\\user",
                                   logon_at=datetime.now(timezone.utc).isoformat(),
                                   transport="rdp", state="active")])
        self.assertEqual(client.post("/v2/agents/inventory", headers=headers,
                                     json={**data, "machine_guid": self.device}).status_code, 403)
        self.assertEqual(client.post("/v2/agents/inventory", headers=headers, json=data).status_code, 200)
        operator = "ls_" + "F" * 43
        with psycopg.connect(database_url()) as db:
            db.execute("INSERT INTO local_accounts(username,display_name,role,password_hash) "
                       "VALUES ('catalog-admin','Catalog Admin','admin','fixture')")
            db.execute("INSERT INTO local_sessions VALUES (%s,'catalog-admin',now()+interval '1 minute')",
                       (token_hash(operator),))
        authorization = {"Authorization": "Bearer " + operator}
        directory = client.get("/v2/devices?q=WINTEST", headers=authorization)
        self.assertEqual(directory.status_code, 200, directory.text)
        self.assertEqual([row["id"] for row in directory.json()], [machine])
        self.assertEqual(client.get("/v2/devices?q=WINTEST&offset=1", headers=authorization).json(), [])
        rows = client.get("/v2/devices", headers=authorization).json()
        self.assertTrue(any(row["id"] == self.device and not row["agent_registered"] for row in rows))
        path = f"/v2/devices/{machine}"
        self.assertEqual(client.get(path + "/history", headers=authorization).json()[0]["current"], True)
        self.assertEqual(client.put(path + "/preferences", headers=authorization,
                                    json={"favorite": True, "group_name": "Lab"}).status_code, 200)
        self.assertEqual(client.get("/v2/devices", headers=authorization).json()[0]["group_name"], "Lab")
        self.assertEqual(client.post(path + "/connection", headers=authorization).status_code, 403)
        with psycopg.connect(database_url()) as db:
            db.execute("INSERT INTO local_device_grants VALUES ('catalog-admin',%s)", (machine,))
            db.execute("INSERT INTO local_device_grants VALUES ('catalog-admin',%s)", (self.device,))
            db.execute("UPDATE devices SET agent_hash=%s,last_heartbeat=now() WHERE id=%s",
                       ("f" * 64, self.device))
        unmanaged = f"/v2/devices/{self.device}"
        self.assertEqual(client.post(unmanaged + "/connection", headers=authorization).status_code, 403)
        self.assertEqual(client.get(unmanaged + "/connection-options", headers=authorization).json()["attended"],
                         {"eligible": False, "available": False})
        self.assertEqual(client.post(path + "/connection", headers=authorization).status_code, 501)
        self.assertEqual(client.post(path + "/connection?mode=unattended", headers=authorization).status_code, 403)
        options = client.get(path + "/connection-options", headers=authorization).json()
        self.assertEqual(options["attended"], {"eligible": True, "available": False})
        self.assertEqual(options["unattended"], {"eligible": False, "available": False})
        policy = client.put(path + "/corporate-policy", headers=authorization, json={
            "attended": False, "unattended_until": (datetime.now(timezone.utc) + timedelta(minutes=10)).isoformat(),
        })
        self.assertEqual(policy.status_code, 422, policy.text)
        policy = client.put(path + "/corporate-policy", headers=authorization, json={"attended": False})
        self.assertEqual(policy.status_code, 200, policy.text)
        with psycopg.connect(database_url()) as db:
            db.execute("UPDATE corporate_access_policy SET unattended_until=now()+interval '1 minute' WHERE device_id=%s",
                       (machine,))
        options = client.get(path + "/connection-options", headers=authorization).json()
        self.assertEqual(options["attended"], {"eligible": False, "available": False})
        self.assertEqual(options["unattended"], {"eligible": False, "available": False})
        self.assertEqual(client.post(path + "/connection", headers=authorization).status_code, 403)
        self.assertEqual(client.post(path + "/connection?mode=unattended", headers=authorization).status_code, 403)
        self.assertEqual(client.post("/v2/agents/inventory", headers=headers,
                                     json={**data, "sessions": None}).status_code, 200)
        with psycopg.connect(database_url()) as db:
            self.assertEqual(db.execute("SELECT current FROM windows_sessions WHERE device_id=%s",
                                        (machine,)).fetchone(), (False,))
        self.assertEqual(client.post(path + "/revoke-agent", headers=authorization).status_code, 200)
        self.assertEqual(client.post(path + "/connection", headers=authorization).status_code, 403)
        self.assertEqual(client.put(path + "/corporate-policy", headers=authorization,
                                    json={"attended": True}).status_code, 403)
        with psycopg.connect(database_url()) as db:
            self.assertIsNone(db.execute("SELECT 1 FROM corporate_access_policy WHERE device_id=%s",
                                         (machine,)).fetchone())
        self.assertEqual(client.post("/v2/agents/inventory", headers=headers, json=data).status_code, 403)
        self.assertEqual(client.post("/v2/agents/enroll", json=enrollment).status_code, 401)

    def test_lab_grants_are_bound_single_use_expiring_and_revocable(self):
        enrollment = self.client.post("/v1/agents/enroll", json={
            "device_id": self.device, "enrollment_code": self.code,
        })
        agent = {"Authorization": "Bearer " + enrollment.json()["agent_token"]}
        hardware = dict(os="Windows", model="Lab", cpu="x64", ram_bytes=1024, disks=[])
        self.assertEqual(self.client.post("/v1/agents/heartbeat", headers=agent, json=hardware).status_code, 200)
        issue = f"/v1/lab/devices/{self.device}/grants"
        context = dict(protocol="lab-v1", binding="ab" * 32)
        self.assertEqual(self.client.post(issue, headers=self.headers(), json=context).status_code, 403)
        with psycopg.connect(database_url()) as db:
            db.execute("INSERT INTO device_grants VALUES (%s,%s,true,true)", (ADMIN, self.device))
        self.assertEqual(self.client.post(issue, headers=self.headers("staff"), json=context).status_code, 403)
        self.assertEqual(self.client.post(issue, headers=self.headers(),
                                          json={**context, "protocol": "legacy"}).status_code, 422)
        self.assertEqual(self.client.post(f"/v1/devices/{self.device}/connection?mode=unattended",
                                          headers=self.headers()).status_code, 403)

        def mint():
            response = self.client.post(issue, headers=self.headers(), json=context)
            self.assertEqual(response.status_code, 201, response.text)
            grant = response.json()
            self.assertEqual(grant["capability"], "view")
            return grant

        def redeem(grant, headers=agent, **overrides):
            return self.client.post(f"/v1/lab/agents/grants/{grant['id']}/redeem", headers=headers,
                                    json={**context, "token": grant["token"],
                                          "local_consent": True, **overrides})

        grant = mint()
        self.assertEqual(redeem(grant, local_consent=False).status_code, 403)
        self.assertEqual(redeem(grant, binding="cd" * 32).status_code, 403)
        other = str(uuid4())
        with psycopg.connect(database_url()) as db, patch.dict(os.environ, {"YESDESK_ENV": "test"}):
            code = issue_test_code(db, dict(id=other, computer_sid="S-1-5-21-12-13-14-202",
                                            dns_name="other.example.test", hostname="OTHER",
                                            yesdesk_id="12345679"))
        response = self.client.post("/v1/agents/enroll", json={"device_id": other, "enrollment_code": code})
        self.assertEqual(redeem(grant, {"Authorization": "Bearer " + response.json()["agent_token"]}).status_code, 403)
        self.assertEqual(redeem(grant).json(),
                         {"validated": True, "capability": "view", "session_started": False})
        self.assertEqual(redeem(grant).status_code, 403)
        expired = mint()
        with psycopg.connect(database_url()) as db:
            db.execute("UPDATE corporate_grants SET expires_at=now()-interval '1 second' WHERE id=%s",
                       (expired["id"],))
        self.assertEqual(redeem(expired).status_code, 403)
        revoked = mint()
        self.assertEqual(self.client.delete(f"/v1/lab/grants/{revoked['id']}",
                                            headers=self.headers()).status_code, 200)
        self.assertEqual(redeem(revoked).status_code, 403)
        demoted = mint()
        self.snapshot["employees"][0]["group_dns"] = [GROUPS["user"]]
        with psycopg.connect(database_url()) as db:
            apply_directory(db, self.snapshot)
        self.assertEqual(redeem(demoted).status_code, 403)


    def test_workspace_sources_and_certificate_bootstrap(self):
        client = TestClient(create_app(None, None, None, {}, enrolled_agents=True))
        operator = "ls_" + "Y" * 43
        matched, ad_only = uuid4(), uuid4()
        with psycopg.connect(database_url()) as db:
            db.execute("TRUNCATE ad_workstations")
            db.execute("TRUNCATE ad_sync_status")
            db.execute("TRUNCATE ad_organizational_units, ad_catalog_users, catalog_hotel_overrides")
            db.execute("INSERT INTO local_accounts(username,display_name,role,password_hash) "
                       "VALUES ('workspace-test','Workspace','admin','fixture')")
            db.execute("INSERT INTO local_sessions VALUES (%s,'workspace-test',now()+interval '1 minute')",
                       (token_hash(operator),))
        headers = {"Authorization": "Bearer " + operator}
        response = client.get("/v2/workspace", headers=headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertIsNone(response.json()["sync"])
        self.assertEqual([row["device_id"] for row in response.json()["rows"]], [self.device])
        snapshot = [
            (matched, "workstation.example.test", "MATCH", ["Workstations", "North", "Front Desk"], "North Hotel"),
            (ad_only, "directory-only.example.test", "DIRECTORY", ["Workstations", "South"], "South Hotel"),
        ]
        with patch("ad_sync.read_directory", return_value=(snapshot, [("Workstations", "Empty")],
                                                           [(USER, "Ирина Тестова")])):
            self.assertEqual(sync_directory(), 0)
        with patch("ad_sync.read_directory", side_effect=ConnectionError):
            self.assertEqual(sync_directory(), 1)
        with psycopg.connect(database_url()) as db:
            db.execute("UPDATE devices SET windows_enrollment=true,metadata='{\"addresses\":[\"192.0.2.41\"]}' "
                       "WHERE id=%s", (self.device,))
            db.execute("INSERT INTO device_enrollment_certificates(fingerprint,device_id,enrollment_until) "
                       "VALUES (%s,%s,now()+interval '1 hour')", ("a"*64, self.device))
            self.assertFalse(register(db, "b"*64, UUID(self.device), "f"*64))
            self.assertFalse(register(db, "a"*64, uuid4(), "f"*64))
            self.assertTrue(register(db, "a"*64, UUID(self.device), "f"*64))
            self.assertTrue(register(db, "a"*64, UUID(self.device), "f"*64))
            self.assertFalse(register(db, "a"*64, UUID(self.device), "e"*64))
        self.assertEqual(client.get("/v2/workspace").status_code, 401)
        with psycopg.connect(database_url()) as db:
            db.execute("UPDATE devices SET last_heartbeat=now(),dns_name='WORKSTATION.example.test.' WHERE id=%s",
                       (self.device,))
            for number, sid, name, state in (
                (1, USER, "TEST\\worker", "active"),
                (2, ADMIN, "TEST\\support", "active"),
                (3, "S-1-5-21-12-13-14-1000", "no-longer-current", "disconnected"),
            ):
                db.execute(
                    """INSERT INTO windows_sessions (device_id,session_id,user_sid,username,logon_at,transport,state,current)
                       VALUES (%s,%s,%s,%s,now(),'console',%s,true)""",
                    (self.device, number, sid, name, state),
                )
        merged = client.get("/v2/workspace", headers=headers).json()
        self.assertEqual(merged["sync"]["result"], "failed")
        self.assertIn(["Workstations", "Empty"], merged["ou_paths"])
        self.assertEqual(len(merged["rows"]), 2)
        self.assertTrue(any(row["device_id"] == self.device and row["ad_id"] == str(matched)
                            for row in merged["rows"]))
        self.assertTrue(any(row["device_id"] is None and row["ad_id"] == str(ad_only)
                            for row in merged["rows"]))
        self.assertEqual(len(client.get("/v2/workspace?q=192.0.2.41", headers=headers).json()["rows"]), 1)
        self.assertEqual(len(client.get("/v2/workspace", headers=headers,
                              params={"ou": '["Workstations","South"]'}).json()["rows"]), 1)
        self.assertEqual(merged["hotels"], ["North Hotel", "South Hotel"])
        user_rows = client.get("/v2/workspace", headers=headers, params={"q": "ирина", "status": "online"}).json()["rows"]
        self.assertEqual([row["device_id"] for row in user_rows], [self.device])
        self.assertEqual(set(user_rows[0]["windows_users"]), {"Ирина Тестова", "TEST\\support"})
        self.assertEqual(client.get("/v2/workspace?q=no-longer-current", headers=headers).json()["rows"], [])
        no_agent = client.get("/v2/workspace", headers=headers, params={"hotel": "South Hotel", "status": "no_agent"})
        self.assertEqual([row["ad_id"] for row in no_agent.json()["rows"]], [str(ad_only)])
        assignment = f"/v2/catalog/ad/{ad_only}/hotel"
        self.assertEqual(client.put(assignment, json={"hotel": "Manual Hotel"}).status_code, 401)
        self.assertEqual(client.put(assignment, headers=headers, json={"hotel": "Manual Hotel"}).status_code, 200)
        with patch("ad_sync.read_directory", return_value=(snapshot, [], [(USER, "Ирина Тестова")])):
            self.assertEqual(sync_directory(), 0)
        rows = client.get("/v2/workspace?q=Manual Hotel", headers=headers).json()["rows"]
        self.assertEqual([(row["ad_id"], row["manual_hotel"]) for row in rows], [(str(ad_only), "Manual Hotel")])
        self.assertEqual(client.put(assignment, headers=headers, json={"hotel": None}).status_code, 200)
        self.assertEqual(client.get("/v2/workspace?q=South Hotel", headers=headers).json()["rows"][0]["ad_id"],
                         str(ad_only))
        # Conflicting DNS registrations must never attach AD identity to either row.
        with psycopg.connect(database_url()) as db:
            duplicate = uuid4()
            db.execute("""INSERT INTO devices(id,computer_sid,hostname,dns_name,yesdesk_id)
                          VALUES (%s, 'S-1-5-21-12-13-14-777','Other','workstation.example.test','87654321')""",
                       (duplicate,))
        rows = client.get("/v2/workspace?q=workstation", headers=headers).json()["rows"]
        self.assertFalse(any(row["ad_id"] and row["device_id"] for row in rows))
        self.assertIn(str(matched), {row["ad_id"] for row in rows})
        self.assertEqual(client.post(f"/v2/devices/{self.device}/revoke-agent", headers=headers).status_code, 200)
        with psycopg.connect(database_url()) as db:
            self.assertFalse(register(db, "a"*64, UUID(self.device), "f"*64))


if __name__ == "__main__":
    unittest.main()
