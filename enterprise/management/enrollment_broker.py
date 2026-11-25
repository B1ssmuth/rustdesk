"""Dedicated HTTPS/mTLS listener for certificate-bound, one-time device bootstrap."""
import argparse
import csv
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import re
import ssl
from uuid import UUID

import psycopg

from settings import database_url


def register(db, fingerprint, machine, token_hash):
    cert = db.execute(
        """SELECT used_at FROM device_enrollment_certificates
           WHERE fingerprint=%s AND device_id=%s AND enabled AND enrollment_until>now()
           FOR UPDATE""", (fingerprint, machine),
    ).fetchone()
    if not cert:
        return False
    target = db.execute(
        "SELECT agent_hash FROM devices WHERE id=%s AND enabled AND windows_enrollment FOR UPDATE",
        (machine,),
    ).fetchone()
    if not target:
        return False
    if cert[0] is not None:
        return target[0] == token_hash
    if target[0] is not None:
        return False
    db.execute("UPDATE devices SET agent_hash=%s,enrollment_hash=NULL,enrollment_until=NULL WHERE id=%s",
               (token_hash, machine))
    db.execute("UPDATE device_enrollment_certificates SET used_at=now() WHERE fingerprint=%s",
               (fingerprint,))
    db.execute("INSERT INTO audit(actor,action,target,outcome) VALUES (%s,'certificate_enrollment',%s,'allowed')",
               (str(machine), str(machine)))
    return True


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(8)
        super().setup()

    def log_message(self, *_):
        # Avoid logging untrusted requests, including headers and URL components.
        pass

    def do_POST(self):
        status = 400
        try:
            if self.path != "/enroll":
                self.send_error(404)
                return
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 512:
                raise ValueError()
            data = json.loads(self.rfile.read(size))
            if set(data) != {"machine_guid", "token_hash"} or not re.fullmatch("[a-f0-9]{64}", data["token_hash"]):
                raise ValueError()
            machine = UUID(data["machine_guid"])
            fingerprint = hashlib.sha256(self.connection.getpeercert(binary_form=True)).hexdigest()
            with psycopg.connect(database_url(), connect_timeout=5) as db:
                status = 200 if register(db, fingerprint, machine, data["token_hash"]) else 403
                if status == 403:
                    db.execute("INSERT INTO audit(actor,action,target,outcome) "
                               "VALUES ('enrollment-broker','certificate_enrollment',%s,'denied')",
                               (str(machine),))
        except (ValueError, TypeError, AttributeError):
            pass
        except (psycopg.Error, TimeoutError):
            status = 503
        response = json.dumps({"registered": status == 200}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)


class Broker(HTTPServer):
    def get_request(self):
        socket, address = super().get_request()
        try:
            socket.settimeout(8)
            return self.tls.wrap_socket(socket, server_side=True), address
        except OSError:
            socket.close()
            raise


def load_approvals(path):
    with open(path, encoding="utf-8-sig", newline="") as source, psycopg.connect(database_url()) as db:
        for row in csv.DictReader(source):
            fingerprint = row["certificate_sha256"].lower()
            if not re.fullmatch("[a-f0-9]{64}", fingerprint):
                raise ValueError("A certificate fingerprint must be a SHA-256 digest")
            machine = UUID(row["machine_guid"])
            db.execute(
                "INSERT INTO devices(id,computer_sid,hostname,dns_name,yesdesk_id,windows_enrollment) "
                "VALUES (%s,%s,%s,%s,%s,true) ON CONFLICT(id) DO NOTHING",
                (machine, row["computer_sid"], row["hostname"], row["dns_name"], row["yesdesk_id"]),
            )
            device = db.execute(
                "SELECT 1 FROM devices WHERE id=%s AND computer_sid=%s AND yesdesk_id=%s AND enabled "
                "AND windows_enrollment AND agent_hash IS NULL", (machine, row["computer_sid"], row["yesdesk_id"]),
            ).fetchone()
            if not device:
                raise ValueError("Approved identity conflicts with an existing device")
            db.execute("INSERT INTO device_enrollment_certificates(fingerprint,device_id,enrollment_until) "
                       "VALUES (%s,%s,now()+interval '1 day')", (fingerprint, machine))
            db.execute("INSERT INTO audit(actor,action,target,outcome) "
                       "VALUES(session_user,'approve_device_certificate',%s,'allowed')", (str(machine),))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--approve-csv")
    args = parser.parse_args()
    if args.approve_csv:
        load_approvals(args.approve_csv)
        return
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.load_cert_chain(os.environ["YESDESK_BROKER_CERT"], os.environ["YESDESK_BROKER_KEY"])
    tls.load_verify_locations(os.environ["YESDESK_BROKER_CLIENT_CA"])
    tls.verify_mode = ssl.CERT_REQUIRED
    with Broker((os.environ.get("YESDESK_BROKER_BIND", "127.0.0.1"), 18443), Handler) as server:
        server.tls = tls
        server.serve_forever()


if __name__ == "__main__":
    main()
