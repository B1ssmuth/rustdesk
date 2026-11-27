import argparse
from datetime import datetime, timezone
import json
import os
import re
from pathlib import Path
import secrets
import sys
from uuid import UUID

import psycopg

from app import digest
from local_auth import SESSION_LOCK
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
    db.execute("INSERT INTO directory_snapshot VALUES (true, clock_timestamp()) "
               "ON CONFLICT (singleton) DO UPDATE SET imported_at=excluded.imported_at")
    db.execute(
        "INSERT INTO audit (actor,action,target,outcome) VALUES "
        "(session_user,'replace_directory','employees','allowed')",
    )


def issue_test_code(db, device, windows=False):
    if not windows and os.environ.get("YESDESK_ENV") != "test":
        raise ValueError("Test enrollment is available only in the test environment")
    code = secrets.token_urlsafe(32)
    db.execute(
        "INSERT INTO devices (id,computer_sid,hostname,dns_name,yesdesk_id,enrollment_hash,enrollment_until,windows_enrollment) "
        "VALUES (%s,%s,%s,%s,%s,%s,now()+interval '10 minutes',%s) "
        "ON CONFLICT (id) DO UPDATE SET enrollment_hash=excluded.enrollment_hash,"
        "enrollment_until=excluded.enrollment_until WHERE devices.enabled "
        "AND devices.computer_sid=excluded.computer_sid AND devices.hostname=excluded.hostname "
        "AND devices.dns_name=excluded.dns_name AND devices.yesdesk_id=excluded.yesdesk_id "
        "AND devices.windows_enrollment=excluded.windows_enrollment "
        "RETURNING id",
        (UUID(device["id"]), device["computer_sid"], device["hostname"],
         device["dns_name"], device["yesdesk_id"], digest(code), windows),
    ).fetchone() or _identity_conflict()
    db.execute(
        "INSERT INTO audit (actor,action,target,outcome) VALUES "
        "(session_user,%s,%s,'allowed')",
        ("issue_windows_enrollment" if windows else "issue_test_enrollment", device["id"]),
    )
    return code


def pin_transport(db, device):
    public_key = device["endpoint_key"]
    if not re.fullmatch(r"[0-9a-fA-F]{64}", public_key):
        raise ValueError("A public Ed25519 key in hex is required")
    valid_until = datetime.fromisoformat(device["valid_until"])
    if valid_until.tzinfo is None or valid_until <= datetime.now(timezone.utc):
        raise ValueError("An explicit future expiry with a time zone is required")
    db.execute("SELECT pg_advisory_xact_lock(%s)", (SESSION_LOCK,))
    row = db.execute(
        """INSERT INTO corporate_transport_keys (device_id,agent_hash,public_key,valid_until)
           SELECT id,agent_hash,%s,%s FROM devices
           WHERE id=%s AND lower(rtrim(dns_name,'.'))=%s AND yesdesk_id=%s
             AND enabled AND windows_enrollment AND agent_hash IS NOT NULL
           ON CONFLICT (device_id) DO UPDATE SET agent_hash=excluded.agent_hash,
               public_key=excluded.public_key,valid_until=excluded.valid_until RETURNING device_id""",
        (bytes.fromhex(public_key), valid_until, UUID(device["id"]),
         device["dns_name"].lower().rstrip("."), device["yesdesk_id"]),
    ).fetchone()
    if not row:
        raise ValueError("No matching registered Windows device")
    db.execute("INSERT INTO audit (actor,action,target,outcome) VALUES "
               "(session_user,'pin_transport',%s,'allowed')", (device["id"],))


def _identity_conflict():
    raise ValueError("Existing device identity differs or the device is disabled")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=["import-directory", "enroll-test-device", "enroll-windows-device", "pin-transport"])
    parser.add_argument("input", type=Path)
    args = parser.parse_args()
    if args.operation == "enroll-windows-device" and (not sys.stdin.isatty() or not sys.stdout.isatty()):
        parser.error("Windows enrollment requires a private interactive terminal")
    data = json.loads(args.input.read_text(encoding="utf-8"))
    code = None
    with psycopg.connect(database_url()) as db:
        if args.operation == "import-directory":
            apply_directory(db, data)
        elif args.operation == "pin-transport":
            pin_transport(db, data)
        else:
            code = issue_test_code(db, data, windows=args.operation == "enroll-windows-device")
    if code:
        print(code)
