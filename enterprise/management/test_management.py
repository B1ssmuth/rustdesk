from datetime import datetime, timedelta, timezone
import os
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from uuid import uuid4

from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
import jwt
import psycopg

from app import create_app, role_for
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


if __name__ == "__main__":
    unittest.main()
