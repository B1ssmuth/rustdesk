"""Server-side, read-only LDAPS snapshot importer."""
import argparse
import json
import os
from pathlib import Path
import re
import ssl
from uuid import UUID

from ldap3 import Connection, NONE, Server, SUBTREE, Tls
from ldap3.utils.dn import parse_dn
import psycopg

from settings import database_url


PAGED_RESULTS_OID = "1.2.840.113556.1.4.319"


def dn_parts(dn):
    rdns = []
    components = []
    for attribute, value, separator in parse_dn(dn, strip=True):
        # DN escapes represent either UTF-8 octets or literal punctuation.
        octets = re.sub(rb"\\(?:([0-9a-fA-F]{2})|(.))",
                        lambda match: bytes.fromhex(match[1].decode()) if match[1] else match[2],
                        value.encode("utf-8"))
        components.append((attribute.casefold(), octets.decode("utf-8")))
        if separator != "+":
            rdns.append(tuple(sorted(components)))
            components = []
    return tuple(reversed(rdns))


def normalized(parts):
    return tuple(tuple(sorted((attribute, value.casefold()) for attribute, value in rdn))
                 for rdn in parts)


def organizational_path(parts):
    return [value for rdn in parts for attribute, value in rdn if attribute == "ou"]


def hotel_rules(path, base):
    if not path:
        return []
    config = json.loads(Path(path).read_text(encoding="utf-8"))
    rules = {}
    for rule in config["hotels"]:
        root = normalized(dn_parts(rule["ou_dn"]))
        label = rule["hotel"].strip()
        if (root[:len(base)] != base or not any(attribute == "ou" for attribute, _ in root[-1])
                or not 1 <= len(label) <= 128 or root in rules):
            raise ValueError("Invalid hotel mapping")
        rules[root] = label
    return sorted(rules.items(), key=lambda rule: len(rule[0]), reverse=True)


def search(client, base, ldap_filter, attributes):
    cookie = None
    while True:
        # ldap3 returns False for a successful search with no entries.
        client.search(base, ldap_filter, SUBTREE, attributes=attributes,
                      paged_size=500, paged_criticality=True, paged_cookie=cookie)
        result = client.result or {}
        if result.get("type") != "searchResDone" or result.get("result") != 0:
            raise ValueError("Incomplete directory search")
        try:
            cookie = result["controls"][PAGED_RESULTS_OID]["value"]["cookie"]
        except (KeyError, TypeError):
            raise ValueError("Incomplete directory search") from None
        if not isinstance(cookie, bytes):
            raise ValueError("Incomplete directory search")
        for entry in client.response:
            if entry.get("type") == "searchResRef":
                # Continuation references are outside this server's snapshot scope.
                continue
            if entry.get("type") != "searchResEntry":
                raise ValueError("Incomplete directory search")
            yield entry
        if not cookie:
            return


def sid_string(raw):
    if len(raw) < 12 or raw[0] != 1 or not 1 <= raw[1] <= 15 or len(raw) != 8 + 4 * raw[1]:
        raise ValueError("Invalid AD SID")
    authority = int.from_bytes(raw[2:8], "big")
    subauthorities = [int.from_bytes(raw[i:i+4], "little") for i in range(8, len(raw), 4)]
    return "-".join(map(str, ["S", 1, authority, *subauthorities]))


def snapshot(client, base, rules):
    rows = []
    for entry in search(client, base, "(&(objectCategory=computer)(objectClass=computer))",
                        ["objectGUID", "dNSHostName", "name"]):
        raw = entry["raw_attributes"]
        path = dn_parts(entry["dn"])
        canonical = normalized(path)
        hotel = next((label for root, label in rules if canonical[:len(root)] == root), "")
        dns = raw.get("dNSHostName", [])
        rows.append((UUID(bytes_le=raw["objectGUID"][0]), dns[0].decode().lower().rstrip(".") if dns else "",
                     raw["name"][0].decode(), organizational_path(path), hotel))
    if not rows:
        raise ValueError("Empty or incomplete computer snapshot")
    units = {tuple(organizational_path(dn_parts(entry["dn"]))) for entry in
             search(client, base, "(objectClass=organizationalUnit)", ["distinguishedName"])}
    users = []
    for entry in search(client, base, "(&(objectCategory=person)(objectClass=user))",
                        ["objectSid", "displayName"]):
        raw = entry["raw_attributes"]
        names = raw.get("displayName", [])
        if names and (name := names[0].decode().strip()):
            users.append((sid_string(raw["objectSid"][0]), name))
    return rows, sorted(units), users


def read_directory():
    host = os.environ["YESDESK_AD_HOST"]
    base = os.environ["YESDESK_AD_BASE"]
    password = Path(os.environ["YESDESK_AD_PASSWORD_FILE"]).read_text(encoding="utf-8").rstrip("\r\n")
    if not password or not base:
        raise ValueError("Configure a read-only bind account and a scoped DN")
    rules = hotel_rules(os.environ.get("YESDESK_AD_HOTEL_RULES_FILE"), normalized(dn_parts(base)))
    tls = Tls(validate=ssl.CERT_REQUIRED, ca_certs_file=os.environ["YESDESK_AD_CA_FILE"])
    port = int(os.environ.get("YESDESK_AD_PORT", "636"))
    server = Server(host, port=port, use_ssl=True, tls=tls, get_info=NONE, connect_timeout=10)
    client = Connection(server, user=os.environ["YESDESK_AD_BIND"], password=password,
                        read_only=True, auto_referrals=False, receive_timeout=20,
                        raise_exceptions=True)
    try:
        if not client.bind():
            raise ValueError("Directory bind failed")
        return snapshot(client, base, rules)
    finally:
        if not client.closed:
            client.unbind()
        elif client.socket is not None:
            client.socket.close()


def update():
    with psycopg.connect(database_url()) as db:
        if not db.execute("SELECT pg_try_advisory_xact_lock(8143027)").fetchone()[0]:
            print("A directory synchronization is already running")
            return 0
        try:
            rows, units, users = read_directory()
            with db.transaction():
                db.execute("DELETE FROM ad_workstations")
                db.execute("DELETE FROM ad_organizational_units")
                db.execute("DELETE FROM ad_catalog_users")
                with db.cursor() as cursor:
                    cursor.executemany(
                        "INSERT INTO ad_workstations (object_id,dns_name,hostname,ou_path,hotel) VALUES (%s,%s,%s,%s,%s)",
                        rows)
                    cursor.executemany("INSERT INTO ad_organizational_units VALUES (%s)",
                                       [(list(path),) for path in units if path])
                    cursor.executemany("INSERT INTO ad_catalog_users VALUES (%s,%s)", users)
        except Exception as failure:
            db.execute(
                "INSERT INTO ad_sync_status VALUES (true,now(),NULL,'failed',0) "
                "ON CONFLICT(singleton) DO UPDATE SET attempted_at=now(),result='failed'"
            )
            print(f"Directory synchronization failed ({type(failure).__name__}); previous snapshot retained")
            return 1
        db.execute(
            "INSERT INTO ad_sync_status VALUES (true,now(),now(),'ok',%s) "
            "ON CONFLICT(singleton) DO UPDATE SET attempted_at=now(),successful_at=now(),"
            "result='ok',computer_count=excluded.computer_count", (len(rows),),
        )
        print(f"Synchronized {len(rows)} directory computers and {len(users)} named users")
        return 0


if __name__ == "__main__":
    argparse.ArgumentParser(description=__doc__).parse_args()
    raise SystemExit(update())
