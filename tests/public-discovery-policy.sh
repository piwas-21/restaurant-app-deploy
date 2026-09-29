#!/usr/bin/env bash
# Exercise the real emitted plan policy and both reader integrations, including wrong inputs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
python3 <<'PY'
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import unittest
import yaml
from public_discovery_policy import public_discovery_policy


class PublicDiscoveryPolicyTests(unittest.TestCase):
    def test_unreviewed_is_not_indexable(self):
        self.assertEqual(public_discovery_policy({}), {
            "public_default_locale": "en", "public_home_locales": "en",
            "public_menu_locales": "en", "public_indexing": "false"})

    def test_audited_policy_keeps_language_separate_from_prices(self):
        result = public_discovery_policy({"locale": "de-CH", "public_indexing": True,
            "public_default_locale": "fr", "public_home_locales": ["fr", "en"],
            "public_menu_locales": ["fr"]})
        self.assertEqual(result["public_default_locale"], "fr")
        self.assertEqual(result["public_home_locales"], "fr,en")
        self.assertEqual(result["public_menu_locales"], "fr")
        self.assertEqual(result["public_indexing"], "true")

    def test_enable_requires_explicit_audit(self):
        with self.assertRaisesRegex(ValueError, "explicit audited"):
            public_discovery_policy({"public_indexing": True})

    def test_wrong_inputs_are_rejected(self):
        for tenant in ({"public_indexing": "false"}, {"public_default_locale": "fr-FR"},
                       {"public_home_locales": "en"}, {"public_menu_locales": []},
                       {"public_menu_locales": ["en", "en"]},
                       {"public_home_locales": ["en\n"]}, {"public_home_locales": ["fr"]}):
            with self.subTest(tenant=tenant), self.assertRaises(ValueError):
                public_discovery_policy(tenant)

    def test_both_readers_emit_the_audited_policy(self):
        root = Path.cwd()
        workflow = yaml.safe_load(Path(".github/workflows/provision-on-registry-merge.yml").read_text())
        scripts = [step.get("run", "") for job in workflow["jobs"].values() for step in job.get("steps", [])]
        readers = [script.split("<<'PY'\n", 1)[1].split("\nPY", 1)[0]
                   for script in scripts if "candidates.append" in script]
        self.assertEqual(len(readers), 1, "Must exercise the actual provisioning reader")
        with tempfile.TemporaryDirectory() as temp:
            fixture = Path(temp) / "tenants/registry.yml"
            fixture.parent.mkdir()
            for enabled in (True, "true"):
                fixture.write_text(yaml.safe_dump({"tenants": {"venue": {
                    "managed": "scripts", "status": "provisioning", "box": "staging",
                    "domain": "venue.example", "name": "Venue", "frontend_tag": "tenant-venue",
                    "backend_tag": "latest", "public_default_locale": "fr",
                    "public_home_locales": ["fr", "en"], "public_menu_locales": ["fr"],
                    "public_indexing": enabled}}}))
                subprocess.run([sys.executable, "-", "candidates.json"], input=readers[0], text=True,
                    cwd=temp, env={**os.environ, "PYTHONPATH": str(root)}, check=True, capture_output=True)
                provision = json.loads((Path(temp) / "candidates.json").read_text())
                tenant = yaml.safe_load(fixture.read_text())
                tenant["tenants"]["venue"]["status"] = "active"
                fixture.write_text(yaml.safe_dump(tenant))
                release = json.loads(subprocess.run(["bash", str(root / "list-release-tenants.sh"), str(fixture)],
                    env={**os.environ, "LIST_RELEASE_TENANTS_FAKE_DNS": "venue.example"},
                    text=True, capture_output=True, check=True).stdout)
                if enabled is True:
                    self.assertEqual(provision["candidates"][0]["public_home_locales"], "fr,en")
                    self.assertEqual(release["eligible"][0]["public_menu_locales"], "fr")
                    self.assertEqual(release["eligible"][0]["public_indexing"], "true")
                else:
                    self.assertEqual(provision["candidates"], [])
                    self.assertEqual(release["eligible"], [])
                    self.assertIn("public_indexing", release["refused_unacknowledged"][0]["reason"])


unittest.main()
PY
