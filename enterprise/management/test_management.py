from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from uuid import UUID, uuid4

from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
import jwt
import psycopg

from app import create_app, role_for
from ad_sync import update as sync_directory
from local_auth import hash_password, token_hash, totp_code
from enrollment_broker import register
from migrate import migrate
from provision import apply_directory, issue_test_code
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
                headers = {"Authorization": "Bearer " + client.post("/v2/auth/login", json=user).json()["token"]}
                self.assertEqual(client.post("/v2/accounts/local-user/revoke-sessions", headers=adm).status_code, 200)
                self.assertEqual(client.get("/v2/auth/me", headers=headers).status_code, 401)
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
        self.assertEqual(client.post(path + "/connection", headers=authorization).status_code, 501)
        self.assertEqual(client.post(path + "/connection?mode=unattended", headers=authorization).status_code, 403)
        options = client.get(path + "/connection-options", headers=authorization).json()
        self.assertEqual(options["attended"], {"eligible": True, "available": False})
        self.assertEqual(options["unattended"], {"eligible": False, "available": False})
        policy = client.put(path + "/corporate-policy", headers=authorization, json={
            "attended": False, "unattended_until": (datetime.now(timezone.utc) + timedelta(minutes=10)).isoformat(),
        })
        self.assertEqual(policy.status_code, 200, policy.text)
        options = client.get(path + "/connection-options", headers=authorization).json()
        self.assertEqual(options["attended"], {"eligible": False, "available": False})
        self.assertEqual(options["unattended"], {"eligible": True, "available": False})
        self.assertEqual(client.post(path + "/connection", headers=authorization).status_code, 403)
        self.assertEqual(client.post(path + "/connection?mode=unattended", headers=authorization).status_code, 501)
        with psycopg.connect(database_url()) as db:
            db.execute("UPDATE corporate_access_policy SET unattended_until=now()-interval '1 minute' WHERE device_id=%s",
                       (machine,))
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
            db.execute("TRUNCATE ad_organizational_units")
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
            (matched, "workstation.example.test", "MATCH", ["Workstations", "North"]),
            (ad_only, "directory-only.example.test", "DIRECTORY", ["Workstations", "South"]),
        ]
        with patch("ad_sync.read_directory", return_value=(snapshot, [("Workstations", "Empty")])):
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
        self.assertEqual(client.post(f"/v2/devices/{self.device}/revoke-agent", headers=headers).status_code, 200)
        with psycopg.connect(database_url()) as db:
            self.assertFalse(register(db, "a"*64, UUID(self.device), "f"*64))


if __name__ == "__main__":
    unittest.main()
