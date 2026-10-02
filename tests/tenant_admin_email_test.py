"""Bootstrap identity must fail before provisioning on ambiguous or unsafe dotenv."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("resolver", Path(__file__).parents[1] / "resolve-tenant-admin-email.py")
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


class BootstrapEmailTests(unittest.TestCase):
    def check(self, text, selector="TENANT_BOOTSTRAP_TEST_EMAIL"):
        with tempfile.TemporaryDirectory() as directory:
            dotenv = Path(directory) / ".env"
            dotenv.write_text(text)
            return resolver.resolve(selector, dotenv)

    def test_bare_single_and_double_quoted_addresses(self):
        for value in ("owner+test@example.test", "'owner+test@example.test'", '"owner+test@example.test"'):
            with self.subTest(value=value):
                self.assertEqual("owner+test@example.test", self.check("TENANT_BOOTSTRAP_TEST_EMAIL=" + value))

    def test_comments_and_unrelated_values_are_not_evaluated(self):
        self.assertEqual("owner@example.test", self.check(
            "# TENANT_BOOTSTRAP_TEST_EMAIL=ignored\nOTHER=$(touch sentinel)\nTENANT_BOOTSTRAP_TEST_EMAIL=owner@example.test\n"))

    def test_invalid_missing_empty_duplicate_or_shell_values_are_rejected(self):
        for text in ("", "TENANT_BOOTSTRAP_TEST_EMAIL=", "TENANT_BOOTSTRAP_TEST_EMAIL=owner@example.test\nTENANT_BOOTSTRAP_TEST_EMAIL=second@example.test",
                     "TENANT_BOOTSTRAP_TEST_EMAIL=$(touch sentinel)", "TENANT_BOOTSTRAP_TEST_EMAIL=`touch sentinel`",
                     "TENANT_BOOTSTRAP_TEST_EMAIL=Name <owner@example.test>", "TENANT_BOOTSTRAP_TEST_EMAIL=bad@..test",
                     "TENANT_BOOTSTRAP_TEST_EMAIL=owner@example.test # comment", "TENANT_BOOTSTRAP_TEST_EMAIL=owner&x@example.test",
                     "TENANT_BOOTSTRAP_TEST_EMAIL=" + "x" * 255 + "@example.test"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.check(text)

    def test_selector_cannot_read_an_unrelated_secret_or_inject_syntax(self):
        for selector in ("POSTGRES_PASSWORD", "TENANT_BOOTSTRAP_", "TENANT_BOOTSTRAP_BAD;touch sentinel", "TENANT_BOOTSTRAP_lowercase"):
            with self.subTest(selector=selector), self.assertRaises(ValueError):
                self.check("POSTGRES_PASSWORD=owner@example.test", selector)

    def test_provisioner_resolves_before_required_field_checks_and_mutations(self):
        script = (Path(__file__).parents[1] / "provision-tenant.sh").read_text()
        self.assertLess(script.index('REG_ADMIN_EMAIL="$(python3 resolve-tenant-admin-email.py'),
                        script.index('for f in name domain db db_role compose_project frontend_tag admin_email'))
        self.assertIn('[[ -z "$REG_ADMIN_EMAIL" ]]', script)


if __name__ == "__main__":
    unittest.main()
