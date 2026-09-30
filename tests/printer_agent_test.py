import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

from printer_agent_storage import begin_rotation, finish_rotation, install_key, read_key

spec = importlib.util.spec_from_file_location("agent", "printer-agent.py")
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


class PrinterAgentTests(unittest.TestCase):
    def test_atomic_write_preserves_other_secrets_permissions_and_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            path = base / "app-secrets.json"
            document = {"JwtSettings": {"Secret": "fixture"}, "PrinterSettings": {"ApiKey": "before"}, "Other": [1, 2]}  # pragma: allowlist secret (synthetic test fixture)
            path.write_text(json.dumps(document))
            path.chmod(0o600)
            install_key(base, "after")
            self.assertEqual(read_key(base), "after")
            document["PrinterSettings"]["ApiKey"] = "after"  # pragma: allowlist secret (synthetic test fixture)
            self.assertEqual(json.loads(path.read_text()), document)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(base.glob(".printer-secret-*")), [])
            target = base / "original.json"
            path.rename(target)
            path.symlink_to(target)
            with self.assertRaises(ValueError):
                install_key(base, "bad")
            self.assertEqual(json.loads(target.read_text()), document)

    def test_crashed_rotation_retains_original_for_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "app-secrets.json").write_text(json.dumps({"PrinterSettings": {"ApiKey": "original"}}))  # pragma: allowlist secret (synthetic test fixture)
            self.assertEqual(begin_rotation(base, "replacement"), "original")
            self.assertEqual((base / ".printer-renewal.json").stat().st_mode & 0o777, 0o600)
            install_key(base, "replacement")
            # A new process's only state is the disk; the original MUST remain recoverable.
            self.assertEqual(begin_rotation(base, "replacement"), "original")
            with self.assertRaises(ValueError):
                begin_rotation(base, "different-replacement")
            install_key(base, begin_rotation(base, "replacement"))
            finish_rotation(base)
            self.assertEqual(read_key(base), "original")
            self.assertFalse((base / ".printer-renewal.json").exists())

    def test_registry_scope_excludes_foreign_retired_nonprinting_and_unselected_tenants(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "deploy"
            (root / "tenants").mkdir(parents=True)
            registry = {}
            for slug, box, status, modules in [("demo", "staging", "active", ["printing"]),
                ("prod", "prod", "active", ["printing"]), ("retired", "staging", "retired", ["printing"]),
                ("plain", "staging", "active", []), ("other", "staging", "active", ["printing"])]:
                registry[slug] = {"box": box, "status": status, "modules": modules, "managed": "scripts", "domain": slug + ".example.test"}
                (root.parent / "tenants" / slug).mkdir(parents=True)
            (root / "tenants/registry.yml").write_text(agent.yaml.safe_dump({"tenants": registry}))
            env = {"BOX_ROLE": "staging", "PRINTER_AGENT_TENANTS": "demo"}
            self.assertEqual(list(agent.targets(root, env)), ["demo"])
            del env["PRINTER_AGENT_TENANTS"]
            self.assertEqual(set(agent.targets(root, env)), {"demo", "other"})
            self.assertEqual(agent.targets(root, env)["demo"]["slug"], "demo")


if __name__ == "__main__":
    unittest.main()
