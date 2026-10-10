#!/usr/bin/env python3
"""Generate runtime branding from the tenant template without a full re-provision."""
import argparse
import os
from pathlib import Path
import re
import shutil
import tempfile
from urllib.parse import urlsplit
import uuid

import yaml

RUNTIME_KEYS = (
    "RuntimeUrl", "TenantSlug", "RefreshSeconds", "MaxStaleSeconds", "RequestTimeoutSeconds"
)


def read_box_role(path: Path) -> str:
    values = re.findall(r"^BOX_ROLE=([^\r\n]*)$", path.read_text(), re.MULTILINE)
    if len(values) != 1 or values[0] not in ("prod", "staging"):
        raise ValueError("box .env must contain one BOX_ROLE=prod|staging")
    return values[0]


def prepare_compose(text: str, template: str, slug: str) -> str:
    source = yaml.safe_load(text)
    environment = source["services"][f"backend-{slug}"]["environment"]
    if not isinstance(environment, dict):
        raise ValueError("backend environment must use mapping syntax")
    anchor = list(re.finditer(r'^([ ]+)Partner__Url:.*$', text, re.MULTILINE))
    if len(anchor) != 1:
        raise ValueError("expected exactly one legacy Partner__Url mapping")
    indent = anchor[0].group(1)
    for key in RUNTIME_KEYS:
        matches = re.findall(rf'^\s*Partner__{key}:', text, re.MULTILINE)
        if len(matches) > 1:
            raise ValueError(f"duplicate Partner__{key} mapping")
        text = re.sub(rf'^{indent}Partner__{key}:.*\n?', '', text, flags=re.MULTILINE)
    text = re.sub(r'^\s*# (?:BEGIN|END) runtime-branding.*\n', '', text, flags=re.MULTILINE)
    generated = yaml.safe_load(template.replace("__SLUG__", slug))
    generated_environment = generated["services"][f"backend-{slug}"]["environment"]
    expected = {f"Partner__{key}": generated_environment[f"Partner__{key}"] for key in RUNTIME_KEYS}
    # Preserve the checked-in template spelling and environment interpolation exactly.
    block = template.split("# BEGIN runtime-branding", 1)[1].split("# END runtime-branding", 1)[0]
    lines = [line for line in block.splitlines() if "Partner__" in line]
    block = "\n".join(indent + line.strip().replace("__SLUG__", slug) for line in lines) + "\n"
    text = re.sub(rf'^{indent}Partner__Url:.*\n', lambda m: m.group(0) + block,
                  text, count=1, flags=re.MULTILINE)
    target = yaml.safe_load(text)
    original = dict(environment)
    target_environment = target["services"][f"backend-{slug}"]["environment"]
    if any(target_environment.get(key) != value for key, value in expected.items()):
        raise ValueError("runtime mappings could not be inserted")
    for key in RUNTIME_KEYS:
        target_environment.pop(f"Partner__{key}", None)
        original.pop(f"Partner__{key}", None)
    source["services"][f"backend-{slug}"]["environment"] = original
    if source != target:
        raise ValueError("patch would change configuration outside runtime branding")
    return text


def write_with_backup(path: Path, content: str, suffix: str) -> None:
    if path.read_text() == content:
        return
    shutil.copy2(path, path.with_name(path.name + suffix))
    descriptor, temp_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(content)
        shutil.copystat(path, temp_name)
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("slug")
    parser.add_argument("--runtime-url")
    parser.add_argument("--deploy-dir", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--tenants-dir", type=Path, default=Path("/opt/rumi/tenants"))
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.slug):
        raise ValueError("invalid tenant slug")
    if args.runtime_url is None:
        template_env = (args.deploy_dir / "tenants/templates/tenant.env.tpl").read_text()
        defaults = re.findall(r"^TENANT_PARTNER_RUNTIME_URL=([^\r\n]+)$", template_env, re.MULTILINE)
        if len(defaults) != 1:
            raise ValueError("tenant template must configure one runtime branding URL")
        args.runtime_url = defaults[0]
    url = urlsplit(args.runtime_url)
    if (url.scheme != "https" or not url.hostname or url.username or url.password
            or url.query or url.fragment or url.port or url.path != "/api/public/tenant-branding"):
        raise ValueError("runtime URL must be an HTTPS public tenant-branding API prefix")
    if any(char.isspace() for char in args.runtime_url) or any(char in args.runtime_url for char in '$"\\'):
        raise ValueError("runtime URL contains invalid characters")
    registry = yaml.safe_load((args.deploy_dir / "tenants/registry.yml").read_text())["tenants"]
    tenant = registry.get(args.slug)
    if not tenant or tenant.get("managed") != "scripts" or tenant.get("status") != "active":
        raise ValueError("tenant must be active and script-managed")
    if tenant.get("box") != read_box_role(args.deploy_dir / ".env"):
        raise ValueError("tenant belongs to a different box")
    directory = args.tenants_dir / args.slug
    compose, env = directory / "docker-compose.yml", directory / ".env"
    if directory.is_symlink() or any(p.is_symlink() or not p.is_file() for p in (compose, env)):
        raise ValueError("tenant Compose/.env must be existing regular files")
    template = (args.deploy_dir / "tenants/templates/docker-compose.tenant.yml.tpl").read_text()
    compose_text = prepare_compose(compose.read_text(), template, args.slug)
    env_text = env.read_text()
    setting = "TENANT_PARTNER_RUNTIME_URL=" + args.runtime_url
    if len(re.findall(r'^TENANT_PARTNER_RUNTIME_URL=', env_text, re.MULTILINE)) > 1:
        raise ValueError("duplicate tenant runtime URL in .env")
    if re.search(r'^TENANT_PARTNER_RUNTIME_URL=', env_text, re.MULTILINE):
        env_text = re.sub(r'^TENANT_PARTNER_RUNTIME_URL=.*$', setting, env_text, flags=re.MULTILINE)
    else:
        env_text = env_text.rstrip("\n") + "\n" + setting + "\n"
    suffix = ".bak.runtime-branding-" + uuid.uuid4().hex
    write_with_backup(compose, compose_text, suffix)
    write_with_backup(env, env_text, suffix)
    print(f"Configured runtime branding for {args.slug}; no services restarted. Backup suffix: {suffix}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, yaml.YAMLError) as error:
        # Explicit errors are safe; parsed-file exceptions can contain secret source text.
        detail = str(error) if isinstance(error, ValueError) else type(error).__name__
        raise SystemExit(f"Runtime branding configuration failed: {detail}") from error
