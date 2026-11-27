from pathlib import Path
import os
import unittest
from unittest.mock import patch

from ldap3.core.exceptions import LDAPSocketOpenError
import psycopg

from ad_sync import dn_parts, organizational_path, read_directory, update
from migrate import migrate
from settings import database_url


class DirectoryParsingTests(unittest.TestCase):
    def test_escaped_ou_names_are_decoded_in_root_to_leaf_order(self):
        path = dn_parts(r"CN=PC,OU=Support\2C East,OU=Hotels,DC=example,DC=test")
        self.assertEqual(organizational_path(path), ["Hotels", "Support, East"])


@unittest.skipUnless(os.environ.get("YESDESK_LDAPS_INTEGRATION") == "1",
                     "Requires the synthetic LDAPS catalog and disposable PostgreSQL database")
class LdapsTests(unittest.TestCase):
    def test_verified_bind_import_and_failed_refresh(self):
        if psycopg.conninfo.conninfo_to_dict(database_url()).get("dbname") != "yesdesk_enterprise_test":
            self.fail("Use the disposable yesdesk_enterprise_test database for this suite")
        migrate()
        rules = Path(__file__).parent / "testdata" / "ldap-hotels.json"
        with patch.dict(os.environ, {"YESDESK_AD_HOTEL_RULES_FILE": str(rules)}):
            self.assertEqual(update(), 0)
            # The synthetic certificate has DNS:localhost and no IP SAN.
            with patch.dict(os.environ, {"YESDESK_AD_HOST": "127.0.0.1"}):
                with self.assertRaises(LDAPSocketOpenError):
                    read_directory()
                self.assertEqual(update(), 1)
        with psycopg.connect(database_url()) as db:
            rows = db.execute(
                "SELECT hostname,dns_name,ou_path,hotel FROM ad_workstations ORDER BY hostname"
            ).fetchall()
            self.assertEqual(rows, [
                ("ANNEX01", "annex01.example.test", ["Workstations", "North, Campus", "Annex"], "Annex Hotel"),
                ("NORTH01", "north01.example.test", ["Workstations", "North, Campus", "Reception"], "North Hotel"),
                ("SPARE01", "", ["Workstations"], ""),
            ])
            self.assertEqual(db.execute("SELECT * FROM ad_catalog_users").fetchall(),
                             [("S-1-5-21-12-13-14-102", "Fixture Worker")])
            self.assertEqual(db.execute("SELECT result,computer_count FROM ad_sync_status").fetchone(),
                             ("failed", 3))
