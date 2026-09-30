"""Box -> Sofra printer credential sync. Never prints keys or remote response bodies."""
import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

import yaml
from printer_agent_storage import begin_rotation, finish_rotation, install_key, read_key

HTTPS = "https://"
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{0,79}$")
KEY = re.compile(r"^[a-f0-9]{64}$")


def env_file(path):
    values = {}
    for line in path.read_text().splitlines():
        name, sep, value = line.partition("=")
        if sep and not name.startswith("#"):
            values[name.strip()] = value.strip().strip("\"'")
    return values


def tenant_selected(slug, tenant, box, selected):
    return (bool(SLUG.fullmatch(slug)) and (not selected or slug in selected)
        and tenant.get("status") == "active" and tenant.get("box") == box
        and ("printing" in tenant.get("modules", []) or tenant.get("managed") == "legacy"))


def targets(root, env):
    registry = yaml.safe_load((root / "tenants/registry.yml").read_text())["tenants"]
    selected = set(filter(None, env.get("PRINTER_AGENT_TENANTS", "").split(",")))
    found = {}
    for slug, tenant in registry.items():
        if not tenant_selected(slug, tenant, env["BOX_ROLE"], selected):
            continue
        legacy = tenant.get("managed") == "legacy"
        base = root if legacy else root.parent / "tenants" / slug
        if base.is_symlink() or not base.is_dir():
            continue
        domain = tenant["domain"]
        if not re.fullmatch(r"[a-zA-Z0-9.-]+", domain):
            raise ValueError("Invalid registry domain")
        found[slug] = {"base": base, "domain": domain, "legacy": legacy, "slug": slug}
    return found


def verified(domain, key):
    if not key:
        return False
    request = urllib.request.Request(HTTPS + domain + "/api/orders/printer-feed",
                                     headers={"X-Api-Key": key})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status == 200
    except (OSError, ValueError):
        return False


def rejected(domain, key):
    if not key:
        return True
    request = urllib.request.Request(HTTPS + domain + "/api/orders/printer-feed",
                                     headers={"X-Api-Key": key})
    try:
        with urllib.request.urlopen(request, timeout=15):
            return False
    except urllib.error.HTTPError as error:
        return error.code == 401
    except (OSError, ValueError):
        return False


def sync(url, secret, box, inventory):
    request = urllib.request.Request(url + "/api/printers/sync",
        data=json.dumps({"box": box, "credentials": inventory}).encode(),
        headers={"Authorization": "Bearer " + secret, "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read(64001))


def restart(target):
    base = target["base"]
    compose = "docker-compose.prod.yml" if target["legacy"] else "docker-compose.yml"
    subprocess.run(["docker", "compose", "-f", str(base / compose), "up", "-d",
                    "--no-deps", "--force-recreate", "--pull", "never", "backend" if target["legacy"] else "backend-" + target["slug"]],
                   cwd=base, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)


def rotate(target, key):
    old = begin_rotation(target["base"], key)
    # A lost acknowledgement is retried without changing the key again.
    if read_key(target["base"]) == key and verified(target["domain"], key) and (old == key or rejected(target["domain"], old)):
        finish_rotation(target["base"])
        return True
    try:
        install_key(target["base"], key)
        restart(target)
        # Backend starts and runs its normal migrations before it can answer.
        import time
        for _ in range(20):
            if verified(target["domain"], key) and (old == key or rejected(target["domain"], old)):
                finish_rotation(target["base"])
                return True
            time.sleep(2)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    # Restore the entire existing secret document's other fields; only the key changes.
    install_key(target["base"], old)
    restart(target)
    # Keep the journal if rollback cannot be proven; the next pass retries safely.
    if old and not verified(target["domain"], old):
        raise ValueError("Rollback not yet verified")
    finish_rotation(target["base"])
    return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--config", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    env = env_file(root / ".env")
    if args.config:
        env.update(env_file(args.config))
    secret = env.get("PRINTER_AGENT_SECRET", "")
    if not secret:
        return
    url = env.get("PRINTER_AGENT_URL", "").rstrip("/")
    if not url.startswith(HTTPS):
        raise ValueError("PRINTER_AGENT_URL must use HTTPS")
    current = targets(root, env)
    if args.dry_run:
        print("Printer agent: eligible tenants:", ", ".join(current))
        return
    inventory = []
    for slug, target in current.items():
        key = read_key(target["base"])
        inventory.append({"tenantSlug": slug, "key": key, "verified": verified(target["domain"], key),
            "renewable": not target["legacy"] or env.get("PRINTER_AGENT_ALLOW_LEGACY_RENEW") == "true"})
    jobs = sync(url, secret, env["BOX_ROLE"], inventory).get("jobs", [])
    if not isinstance(jobs, list) or len(jobs) > 100:
        raise ValueError("Invalid job response")
    run_jobs(current, env, url, secret, jobs)


def run_jobs(current, env, url, secret, jobs):
    for job in jobs:
        if not isinstance(job, dict):
            raise ValueError("Invalid job")
        slug, key = job.get("tenantSlug"), job.get("key")
        if slug not in current or not isinstance(key, str) or not KEY.fullmatch(key):
            raise ValueError("Job outside local registry")
        target = current[slug]
        # Legacy RUMI remains read-only unless explicitly opted in on its own box.
        if target["legacy"] and env.get("PRINTER_AGENT_ALLOW_LEGACY_RENEW") != "true":
            continue
        ok = rotate(target, key)
        print("Printer renewal", slug, "verified" if ok else "failed; previous configuration restored")
        value = read_key(target["base"])
        sync(url, secret, env["BOX_ROLE"], [{"tenantSlug": slug, "key": value,
            "verified": ok and verified(target["domain"], value), "renewable": True, "renewalFailed": not ok}])


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Exception strings can include a response body or headers. Never log them.
        print("Printer agent failed; check connectivity, registry and configuration", file=sys.stderr)
        sys.exit(1)
