"""Optional read-only LDAPS snapshot importer. Run outside the API process."""
import argparse
import os
from pathlib import Path
import ssl
from uuid import UUID

from ldap3 import AUTO_BIND_NO_TLS, Connection, NONE, Server, SUBTREE, Tls
from ldap3.utils.dn import parse_dn
import psycopg

from settings import database_url


def read_directory():
    host = os.environ["YESDESK_AD_HOST"]
    base = os.environ["YESDESK_AD_BASE"]
    password = Path(os.environ["YESDESK_AD_PASSWORD_FILE"]).read_text(encoding="utf-8").strip()
    if not password or not base:
        raise ValueError("Configure a read-only bind account and a scoped DN")
    tls = Tls(validate=ssl.CERT_REQUIRED, ca_certs_file=os.environ["YESDESK_AD_CA_FILE"],
              valid_names=[host])
    server = Server(host, port=636, use_ssl=True, tls=tls, get_info=NONE, connect_timeout=10)
    rows = []
    with Connection(server, user=os.environ["YESDESK_AD_BIND"], password=password,
                    read_only=True, auto_bind=AUTO_BIND_NO_TLS, auto_referrals=False,
                    receive_timeout=20, raise_exceptions=True) as client:
        entries = client.extend.standard.paged_search(
            base, "(&(objectCategory=computer)(objectClass=computer))", SUBTREE,
            attributes=["objectGUID", "dNSHostName", "name"],
            paged_size=500, paged_criticality=True, generator=True,
        )
        for entry in entries:
            if entry["type"] != "searchResEntry":
                raise ValueError("Incomplete directory search")
            raw = entry["raw_attributes"]
            hostname = raw["name"][0].decode("utf-8")
            dns = raw.get("dNSHostName", [])
            units = [value for name, value, _ in parse_dn(entry["dn"]) if name.casefold() == "ou"]
            rows.append((UUID(bytes_le=raw["objectGUID"][0]), dns[0].decode().lower().rstrip(".") if dns else "",
                         hostname, list(reversed(units))))
        if client.result["result"] != 0 or not rows:
            raise ValueError("Empty or incomplete snapshot")
    return rows


def update():
    with psycopg.connect(database_url()) as db:
        if not db.execute("SELECT pg_try_advisory_xact_lock(8143027)").fetchone()[0]:
            print("A directory synchronization is already running")
            return 0
        try:
            rows = read_directory()
        except Exception as failure:
            db.execute(
                "INSERT INTO ad_sync_status VALUES (true,now(),NULL,'failed',0) "
                "ON CONFLICT(singleton) DO UPDATE SET attempted_at=now(),result='failed'"
            )
            print(f"Directory synchronization failed ({type(failure).__name__}); previous snapshot retained")
            return 1
        db.execute("DELETE FROM ad_workstations")
        with db.cursor() as cursor:
            cursor.executemany("INSERT INTO ad_workstations VALUES (%s,%s,%s,%s)", rows)
        db.execute(
            "INSERT INTO ad_sync_status VALUES (true,now(),now(),'ok',%s) "
            "ON CONFLICT(singleton) DO UPDATE SET attempted_at=now(),successful_at=now(),"
            "result='ok',computer_count=excluded.computer_count", (len(rows),),
        )
        print(f"Synchronized {len(rows)} directory computers")
        return 0


if __name__ == "__main__":
    argparse.ArgumentParser(description=__doc__).parse_args()
    raise SystemExit(update())
