"""Check split installer authoring without requiring WiX or Windows."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

MSI = Path(__file__).resolve().parent
AGENT = MSI.parents[1] / "enterprise" / "agent" / "msi"
WIX = {"w": "http://wixtoolset.org/schemas/v4/wxs"}


def names_in(sources, element):
    return [
        entry.attrib["Name"]
        for source in sources for entry in ET.parse(source).findall(f".//w:{element}", WIX)
    ]


class SplitPackageTests(unittest.TestCase):
    def test_service_ownership_is_split(self):
        client_sources = sorted((MSI / "Package").rglob("*.wxs"))
        agent_sources = [AGENT / "Agent.wxs"]
        for element in ("ServiceInstall", "ServiceControl"):
            self.assertEqual(names_in(client_sources, element), ["YES Desk"])
            self.assertEqual(names_in(agent_sources, element), ["YESDeskAgent"])
        for source in client_sources:
            self.assertNotIn("YesDeskAgent.exe", source.read_text(encoding="utf-8-sig"))
            self.assertNotIn("CorporateAgentSource", source.read_text(encoding="utf-8-sig"))

    def test_only_legacy_unified_agent_blocks_client(self):
        package = ET.parse(MSI / "Package" / "Package.wxs")
        guard = package.find(".//w:Launch[@Condition='Installed OR NOT YESDESK_UNIFIED_AGENT']", WIX)
        self.assertIsNotNone(guard)
        search = package.find(".//w:Property[@Id='YESDESK_UNIFIED_AGENT']/w:RegistrySearch", WIX)
        self.assertEqual(search.attrib["Name"], "CorporateAgentIncluded")

    def test_client_build_rejects_accidentally_staged_agent(self):
        for name in ("YESDESKAGENT.EXE", "YESDesk-Agent-x64.msi"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                dist = Path(directory)
                (dist / "YES_Desk.exe").touch()
                (dist / "nested").mkdir()
                (dist / "nested" / name).touch()
                result = subprocess.run(
                    [sys.executable, str(MSI / "preprocess.py"), "--yesdesk", "-d", str(dist)],
                    capture_output=True, text=True, cwd=MSI,
                )
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn("inventory agent or another MSI", result.stderr)


if __name__ == "__main__":
    unittest.main()
