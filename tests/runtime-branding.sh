#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$HERE/.." <<'PY'
from pathlib import Path
import importlib.util
import subprocess
import sys
import tempfile
import yaml

root = Path(sys.argv[1]).resolve()
base = yaml.safe_load((root / 'docker-compose.prod.yml').read_text())
for service in ['sofra', 'sofra-staging']:
    settings = base['services'][service]['environment']
    for key in ['SOFRA_BRAND_NAME', 'SOFRA_BRAND_URL', 'SOFRA_BRAND_EMAIL']:
        assert settings[key] == '${' + key + ':-}', 'missing platform config carriage'
spec = importlib.util.spec_from_file_location('runtime_branding', root / 'tenants/render-runtime-branding.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as tmp:
    box = Path(tmp)
    tenants = box / 'instances'
    tenant = tenants / 'demo'
    tenant.mkdir(parents=True)
    (box / 'tenants/templates').mkdir(parents=True)
    template = (root / 'tenants/templates/docker-compose.tenant.yml.tpl').read_text()
    (box / 'tenants/templates/docker-compose.tenant.yml.tpl').write_text(template)
    (box / 'tenants/templates/tenant.env.tpl').write_text((root / 'tenants/templates/tenant.env.tpl').read_text())
    registry = {'tenants': {'demo': {'managed': 'scripts', 'status': 'active', 'box': 'staging'}}}
    registry_file = box / 'tenants/registry.yml'
    registry_file.write_text(yaml.safe_dump(registry))
    (box / '.env').write_text('BOX_ROLE=staging\nPOSTGRES_PASSWORD=must-stay-private\n')  # pragma: allowlist secret -- synthetic fixture
    compose = tenant / 'docker-compose.yml'
    env = tenant / '.env'
    original = '''name: tenant-demo
services:
  backend-demo:
    image: image:old-sha
    environment:
      Modules__Enabled: "core,server"
      Partner__Name: "Old partner"
      Partner__Url: "https://old.example"
      ConnectionStrings__restaurantdb: "do-not-change"
  frontend-demo:
    image: image:tenant-demo-sha
'''
    compose.write_text(original)
    env.write_text('BACKEND_TAG=old-sha\nTENANT_PARTNER_NAME=Old partner\nSECRET=not-to-be-printed\n')
    env.chmod(0o600)
    command = ['bash', str(root / 'provision-tenant.sh'), 'demo', '--runtime-branding-only',
               '--deploy-dir', str(box), '--tenants-dir', str(tenants)]
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert 'private' not in result.stdout + result.stderr and 'SECRET=' not in result.stdout + result.stderr
    patched = yaml.safe_load(compose.read_text())
    runtime = patched['services']['backend-demo']['environment']
    assert runtime['Partner__TenantSlug'] == 'demo'
    assert runtime['Partner__RuntimeUrl'] == '${TENANT_PARTNER_RUNTIME_URL:-}'
    for key in module.RUNTIME_KEYS:
        runtime.pop('Partner__' + key)
    assert patched == yaml.safe_load(original), 'unrelated compose values changed'
    assert env.stat().st_mode & 0o777 == 0o600
    assert len(list(tenant.glob('*.bak.runtime-branding-*'))) == 2
    second = subprocess.run(command, capture_output=True)
    assert second.returncode == 0
    assert len(list(tenant.glob('*.bak.runtime-branding-*'))) == 2, 'idempotent patch made new backups'
    for field, bad_value in [('managed', 'legacy'), ('status', 'retired'), ('box', 'prod')]:
        registry['tenants']['demo'][field] = bad_value
        registry_file.write_text(yaml.safe_dump(registry))
        before = compose.read_text(), env.read_text()
        assert subprocess.run(command, capture_output=True).returncode != 0
        assert before == (compose.read_text(), env.read_text())
        registry['tenants']['demo'][field] = {'managed':'scripts', 'status':'active', 'box':'staging'}[field]
    registry_file.write_text(yaml.safe_dump(registry))
    for bad_url in ['http://example.com/api/public/tenant-branding',
                    'https://user:pass@example.com/api/public/tenant-branding',  # pragma: allowlist secret -- invalid URL fixture
                    'https://example.com/api/public/tenant-branding?token=secret']:
        assert subprocess.run(command + ['--runtime-url', bad_url], capture_output=True).returncode != 0
    assert subprocess.run(command + ['--runtime-url', 'https://staging.sofrapiwas.com/api/public/tenant-branding'], capture_output=True).returncode == 0
    assert 'TENANT_PARTNER_RUNTIME_URL=https://staging.sofrapiwas.com/api/public/tenant-branding\n' in env.read_text()
    composed = module.prepare_compose(template.replace('__SLUG__', 'demo'), template, 'demo')
    assert yaml.safe_load(composed) == yaml.safe_load(template.replace('__SLUG__', 'demo'))
    try:
        module.prepare_compose(original.replace('Partner__Url:', 'Missing__Url:'), template, 'demo')
    except ValueError:
        pass
    else:
        raise AssertionError('missing anchor accepted')
print('ok: narrow runtime patch, existing runtime template, idempotency, backups, permissions, environment isolation and refusals')
PY
