from pathlib import Path
import os
import unittest
from unittest.mock import Mock, call, patch

from ldap3 import Connection, SUBTREE
from ldap3.core.exceptions import LDAPSocketOpenError, LDAPSocketReceiveError
import psycopg

from ad_sync import dn_parts, organizational_path, read_directory, search, update
from migrate import migrate
from settings import database_url


class DirectoryParsingTests(unittest.TestCase):
    def test_escaped_ou_names_are_decoded_in_root_to_leaf_order(self):
        path = dn_parts(r"CN=PC,OU=Support\2C East,OU=Hotels,DC=example,DC=test")
        self.assertEqual(organizational_path(path), ["Hotels", "Support, East"])


class DirectorySearchTests(unittest.TestCase):
    base = "dc=example,dc=test"
    ldap_filter = "(objectClass=computer)"
    attributes = ["name"]

    def setUp(self):
        self.client = Mock(spec=Connection)

    def page(self, entries, cookie=b"", code=0):
        self.client.response = entries
        self.client.result = {"type": "searchResDone", "result": code}
        if cookie is not None:
            self.client.result["controls"] = {
                "1.2.840.113556.1.4.319": {"value": {"cookie": cookie}},
            }
        return bool(entries)

    def entries(self):
        return search(self.client, self.base, self.ldap_filter, self.attributes)

    def test_success_with_383_entries_and_three_referrals(self):
        entries = [{"type": "searchResEntry", "dn": f"cn=pc-{i},{self.base}"}
                   for i in range(383)]
        referrals = [{"type": "searchResRef", "uri": [f"ldap://ref-{i}.example.test/"]}
                     for i in range(3)]
        self.client.search.side_effect = lambda *args, **kwargs: self.page(
            entries[:1] + referrals + entries[1:])

        self.assertEqual(list(self.entries()), entries)
        self.client.search.assert_called_once_with(
            self.base, self.ldap_filter, SUBTREE, attributes=self.attributes,
            paged_size=500, paged_criticality=True, paged_cookie=None)

    def test_follows_paging_cookie_until_successful_empty_page(self):
        entry = {"type": "searchResEntry", "dn": f"cn=pc,{self.base}"}

        def fetch_page(*args, paged_cookie, **kwargs):
            return self.page([], b"") if paged_cookie else self.page([entry], b"next")

        self.client.search.side_effect = fetch_page

        self.assertEqual(list(self.entries()), [entry])
        self.assertEqual(self.client.search.call_args_list, [
            call(self.base, self.ldap_filter, SUBTREE, attributes=self.attributes,
                 paged_size=500, paged_criticality=True, paged_cookie=cookie)
            for cookie in (None, b"next")
        ])

    def test_nonzero_result_rejects_entries_and_referrals(self):
        entries = [{"type": "searchResEntry"}, {"type": "searchResRef"}]
        for code in (4, 10):
            with self.subTest(code=code):
                self.client.search.side_effect = lambda *args, **kwargs: self.page(entries, code=code)
                with self.assertRaisesRegex(ValueError, "Incomplete directory search"):
                    next(self.entries())

    def test_unexpected_response_type_fails(self):
        self.client.search.side_effect = lambda *args, **kwargs: self.page([
            {"type": "intermediateResponse"},
        ])
        with self.assertRaisesRegex(ValueError, "Incomplete directory search"):
            list(self.entries())

    def test_missing_or_invalid_paging_cookie_fails(self):
        for cookie in (None, ""):
            with self.subTest(cookie=cookie):
                self.client.search.side_effect = lambda *args, **kwargs: self.page([], cookie)
                with self.assertRaisesRegex(ValueError, "Incomplete directory search"):
                    list(self.entries())

    def test_error_on_second_page_propagates(self):
        entry = {"type": "searchResEntry", "dn": f"cn=pc,{self.base}"}

        def fetch_page(*args, paged_cookie, **kwargs):
            if paged_cookie == b"next":
                raise LDAPSocketReceiveError("synthetic connection interruption")
            return self.page([entry], b"next")

        self.client.search.side_effect = fetch_page

        with self.assertRaises(LDAPSocketReceiveError):
            list(self.entries())
        self.assertEqual(self.client.search.call_count, 2)


@unittest.skipUnless(os.environ.get("YESDESK_LDAPS_INTEGRATION") == "1",
                     "Requires the synthetic LDAPS catalog and disposable PostgreSQL database")
class LdapsTests(unittest.TestCase):
    def setUp(self):
        if psycopg.conninfo.conninfo_to_dict(database_url()).get("dbname") != "yesdesk_enterprise_test":
            self.fail("Use the disposable yesdesk_enterprise_test database for this suite")
        migrate()
        rules = Path(__file__).parent / "testdata" / "ldap-hotels.json"
        self.enterContext(patch.dict(os.environ, {"YESDESK_AD_HOTEL_RULES_FILE": str(rules)}))

    def test_verified_bind_import_and_failed_refresh(self):
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

    def stored_snapshot(self):
        with psycopg.connect(database_url()) as db:
            return (
                db.execute("SELECT * FROM ad_workstations ORDER BY object_id").fetchall(),
                db.execute("SELECT * FROM ad_organizational_units ORDER BY ou_path").fetchall(),
                db.execute("SELECT * FROM ad_catalog_users ORDER BY sid").fetchall(),
                db.execute("SELECT successful_at,computer_count FROM ad_sync_status").fetchone(),
            )

    def assert_snapshot_retained(self, previous):
        self.assertEqual(self.stored_snapshot(), previous)
        with psycopg.connect(database_url()) as db:
            self.assertEqual(db.execute("SELECT result FROM ad_sync_status").fetchone(), ("failed",))

    def test_late_search_failure_preserves_previous_snapshot(self):
        self.assertEqual(update(), 0)
        previous = self.stored_snapshot()
        original_search = Connection.search

        def fail_user_search(client, base, ldap_filter, *args, **kwargs):
            if ldap_filter == "(&(objectCategory=person)(objectClass=user))":
                raise LDAPSocketReceiveError("synthetic connection interruption")
            return original_search(client, base, ldap_filter, *args, **kwargs)

        with patch.object(Connection, "search", fail_user_search):
            self.assertEqual(update(), 1)
        self.assert_snapshot_retained(previous)

    def test_insert_failure_rolls_back_snapshot_replacement(self):
        self.assertEqual(update(), 0)
        previous = self.stored_snapshot()
        rows, units, users = read_directory()

        with patch("ad_sync.read_directory", return_value=(rows, units, users + users)):
            self.assertEqual(update(), 1)
        self.assert_snapshot_retained(previous)
