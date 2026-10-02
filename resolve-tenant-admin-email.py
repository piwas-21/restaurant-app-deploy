#!/usr/bin/env python3
"""Resolve a registry bootstrap-email selector from box-local dotenv data."""
import re
import sys
from pathlib import Path

SELECTOR = re.compile(r"TENANT_BOOTSTRAP_[A-Z][A-Z0-9_]{0,80}")
LABEL = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@(?:" + LABEL + r"\.)+" + LABEL)


def resolve(selector: str, dotenv: Path) -> str:
    """Reject ambiguity and shell syntax; never evaluate dotenv content."""
    if not SELECTOR.fullmatch(selector):
        raise ValueError("Invalid tenant bootstrap email selector.")
    values = []
    for line in dotenv.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.partition("=")
        if separator and key.strip() == selector:
            values.append(value.strip())
    if len(values) != 1:
        raise ValueError("Tenant bootstrap email requires exactly one box-local setting.")
    value = values[0]
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    if len(value) > 254 or not EMAIL.fullmatch(value):
        raise ValueError("Tenant bootstrap email setting must be a bare valid address.")
    return value


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("Provide one tenant bootstrap email selector.")
        print(resolve(sys.argv[1], Path(".env")))
    except (ValueError, OSError) as error:
        # Validation errors contain no setting value; filesystem errors expose paths only.
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
