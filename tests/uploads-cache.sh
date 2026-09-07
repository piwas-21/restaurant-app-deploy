#!/usr/bin/env bash
# Mutable uploads must revalidate: ImageBackfillService replaces both originals and
# _resize-preview files at the same URL. Unique upload names do not imply immutable bytes.
# Run by CI's tests/*.sh glob. Structural policy test; no Docker/network dependency.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$HERE/.." <<'PY'
from pathlib import Path
import re
import sys

ROOT = Path(sys.argv[1])
FILES = ("Caddyfile", "Caddyfile.staging", "tenants/templates/site.caddy.tpl")
POLICY = 'header Cache-Control "public, max-age=0, must-revalidate"'


def check(text):
    # Ignore comments, but require the exact upload matcher, one file server and one
    # cache policy INSIDE that block. A policy on the app/API is not a substitute.
    active = re.sub(r"(?m)^\s*#.*$", "", text)
    matches = list(re.finditer(r"handle_path\s+/uploads/\*\s*\{", active))
    assert len(matches) == 1, "expected exactly one /uploads/* handler"
    start = matches[0].end()
    depth = 1
    end = start
    while depth and end < len(active):
        depth += (active[end] == "{") - (active[end] == "}")
        end += 1
    assert depth == 0, "unclosed uploads handler"
    block = active[start:end - 1]
    assert re.search(r"(?m)^\s*file_server\s*$", block), "missing file_server validators"
    cache_lines = re.findall(r"(?mi)^\s*header\s+Cache-Control\b[^\n]*", active)
    assert len(cache_lines) == 1, "expected one scoped cache header"
    assert cache_lines[0].strip() == POLICY, "uploads must always revalidate"
    assert POLICY in block, "cache policy escaped the uploads handler"


def rejected(text, label):
    try:
        check(text)
    except AssertionError:
        print(f"  ok   rejects {label}")
        return
    raise AssertionError(f"accepted negative control: {label}")


for filename in FILES:
    text = (ROOT / filename).read_text()
    check(text)
    print(f"  ok   {filename}: scoped revalidation policy + file_server")
    rejected(text.replace(POLICY, 'header Cache-Control "public, max-age=31536000, immutable"'),
             f"{filename}: original immutable regression")
    rejected(text.replace(POLICY, 'header Cache-Control "public, max-age=3600"'),
             f"{filename}: fresh but mutable cache")
    rejected(text.replace(POLICY, "# " + POLICY), f"{filename}: commented-out policy")
    rejected(text.replace(POLICY, "") + "\n" + POLICY, f"{filename}: unscoped policy")
    rejected(text.replace("handle_path /uploads/*", "handle_path /api/*"),
             f"{filename}: wrong route")
    rejected(text.replace("file_server", "# file_server"), f"{filename}: missing file server")

print("uploads-cache: all 3 configurations and 18 negative controls passed")
PY
