"""Drive the Rust redemption HTTP client against an isolated HTTPS fixture."""
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from ipaddress import ip_address
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
from threading import Thread
from time import sleep

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


def build_tls(root):
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "YES Desk transport test CA")])
    leaf_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "YES Desk loopback API")])
    now = datetime.now(timezone.utc)

    def certificate(subject, public_key, is_ca):
        builder = (x509.CertificateBuilder().subject_name(subject).issuer_name(ca_name)
                   .public_key(public_key).serial_number(x509.random_serial_number())
                   .not_valid_before(now - timedelta(minutes=5)).not_valid_after(now + timedelta(hours=1))
                   .add_extension(x509.BasicConstraints(ca=is_ca, path_length=None), critical=True))
        if not is_ca:
            builder = (builder.add_extension(x509.SubjectAlternativeName([x509.IPAddress(ip_address("127.0.0.1"))]),
                                             critical=False)
                       .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False))
        return builder.sign(ca_key, hashes.SHA256()).public_bytes(serialization.Encoding.PEM)

    ca_file, cert_file, key_file = (root / name for name in ("ca.pem", "api.pem", "api.key"))
    ca_file.write_bytes(certificate(ca_name, ca_key.public_key(), True))
    cert_file.write_bytes(certificate(leaf_name, leaf_key.public_key(), False))
    key_file.write_bytes(leaf_key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption(),
    ))
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert_file, key_file)
    return tls, ca_file


class Endpoint(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        if self.path == "/timeout":
            sleep(6)
            return
        status = int(self.path.removeprefix("/"))
        self.send_response(status)
        if status == 302:
            self.send_header("Location", "/204")
        self.end_headers()


def run(test_exe):
    with tempfile.TemporaryDirectory() as directory, socket.socket() as unavailable:
        tls, ca_file = build_tls(Path(directory))
        unavailable.bind(("127.0.0.1", 0))
        with ThreadingHTTPServer(("127.0.0.1", 0), Endpoint) as server:
            server.socket = tls.wrap_socket(server.socket, server_side=True)
            worker = Thread(target=server.serve_forever)
            worker.start()
            try:
                tests = "server::corporate_grant::tests::redemption_uses_verified_https_and_requires_204"
                env = {
                    **os.environ, "YESDESK_TEST_REDEMPTION_CA": str(ca_file),
                    "YESDESK_TEST_REDEMPTION_URL": f"https://127.0.0.1:{server.server_port}",
                    "YESDESK_TEST_REDEMPTION_UNAVAILABLE": f"https://127.0.0.1:{unavailable.getsockname()[1]}",
                }
                subprocess.run([str(test_exe.resolve()), "--ignored", "--exact", tests], env=env,
                               check=True, timeout=25)
            finally:
                server.shutdown()
                worker.join()


if __name__ == "__main__":
    run(Path(sys.argv[1]))
