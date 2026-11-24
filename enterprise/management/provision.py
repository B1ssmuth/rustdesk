import argparse
import json
import os
from pathlib import Path
import secrets
from uuid import UUID

import psycopg

from app import digest
from settings import database_url


def apply_directory(db, snapshot):
    # The caller must provide an authoritative full snapshot for this deployment.
    db.execute("SELECT pg_advisory_xact_lock(8143021)")
    db.execute("UPDATE employees SET enabled=false")
    db.execute("DELETE FROM employee_groups")
    for employee in snapshot["employees"]:
        db.execute(
            "INSERT INTO employees (sid,username,display_name,department,subject,enabled) "
            "VALUES (%s,%s,%s,%s,%s,true) ON CONFLICT (sid) DO UPDATE SET "
            "username=excluded.username,display_name=excluded.display_name,"
            "department=excluded.department,subject=excluded.subject,enabled=true",
            (employee["sid"], employee["username"], employee["display_name"],
             employee.get("department", ""), employee.get("subject")),
        )
        for group_dn in set(employee["group_dns"]):
            db.execute("INSERT INTO employee_groups (employee_sid, group_dn) VALUES (%s,%s)",
                       (employee["sid"], group_dn))
    db.execute(
        "INSERT INTO audit (actor,action,target,outcome) VALUES "
        "(session_user,'replace_directory','employees','allowed')",
    )


def issue_test_code(db, device):
    if os.environ.get("YESDESK_ENV") != "test":
        raise ValueError("Test enrollment is available only in the test environment")
    code = secrets.token_urlsafe(32)
    db.execute(
        "INSERT INTO devices (id,computer_sid,hostname,dns_name,yesdesk_id,enrollment_hash,enrollment_until) "
        "VALUES (%s,%s,%s,%s,%s,%s,now()+interval '10 minutes') "
        "ON CONFLICT (id) DO UPDATE SET enrollment_hash=excluded.enrollment_hash,"
        "enrollment_until=excluded.enrollment_until WHERE devices.enabled "
        "AND devices.computer_sid=excluded.computer_sid AND devices.hostname=excluded.hostname "
        "AND devices.dns_name=excluded.dns_name AND devices.yesdesk_id=excluded.yesdesk_id "
        "RETURNING id",
        (UUID(device["id"]), device["computer_sid"], device["hostname"],
         device["dns_name"], device["yesdesk_id"], digest(code)),
    ).fetchone() or _identity_conflict()
    db.execute(
        "INSERT INTO audit (actor,action,target,outcome) VALUES "
        "(session_user,'issue_test_enrollment',%s,'allowed')", (device["id"],),
    )
    return code


def _identity_conflict():
    raise ValueError("Existing device identity differs or the device is disabled")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=["import-directory", "enroll-test-device"])
    parser.add_argument("input", type=Path)
    args = parser.parse_args()
    data = json.loads(args.input.read_text(encoding="utf-8"))
    with psycopg.connect(database_url()) as db:
        if args.operation == "import-directory":
            apply_directory(db, data)
            code = None
        else:
            code = issue_test_code(db, data)
    if code:
        print(code)
