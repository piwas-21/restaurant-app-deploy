#!/usr/bin/env bash
# Shared helpers for the backup family (backup-tenant.sh, backup-archive-tenant.sh,
# restore-tenant.sh, backup-erase-tenant.sh, backup-agent.sh, and the per-tenant loop
# in backup-dump.sh). SOURCED, never executed — it defines functions and defaults and
# does nothing else, so sourcing it from a test is safe.
#
# Layout it owns, all under $BACKUP_ROOT (700 — these files contain customer data):
#
#   dumps/                       backup-dump.sh, unchanged: whole-cluster + volume tars
#   dumps/tenants/<slug>/        NEW per-tenant dumps, <slug>-<kind>-<ts>.sql.gz (+ .sha256)
#                                DELIBERATELY under dumps/ so backup-offsite.sh ships them
#                                off-box with zero extra wiring — restic already backs up
#                                that whole tree.
#   archive/<slug>/<ts>/         NEW long-retention archive of a DEPARTED tenant:
#                                db.sql.gz + uploads.tar.gz + manifest.json
#   erasures.log                 append-only tombstones (slug + ref + when, never PII)
#
# Two retention regimes, on purpose, because they answer different questions:
#   operational (dumps/)  — "the box burned down last night"     — days/weeks
#   archive/              — "the trial tenant is back, 8 months on" — ARCHIVE_KEEP_MONTHS
# See DEPLOYMENT.md §Backups & restore for the horizon and its GDPR justification.

# Defaults are overridable from the environment so tests can point the whole family at
# a temp dir. Never `set -u`-unsafe: every read below has a default.
BACKUP_ROOT="${BACKUP_ROOT:-/opt/rumi/backups}"
DUMP_DIR="${DUMP_DIR:-${BACKUP_ROOT}/dumps}"
TENANT_DUMP_DIR="${TENANT_DUMP_DIR:-${DUMP_DIR}/tenants}"
ARCHIVE_DIR="${ARCHIVE_DIR:-${BACKUP_ROOT}/archive}"
ERASURE_LOG="${ERASURE_LOG:-${BACKUP_ROOT}/erasures.log}"
# 24 months. Justified in DEPLOYMENT.md: long enough that a lapsed trial coming back a
# year later still has its data, short enough to stay INSIDE the longest window the
# privacy pack already commits to (reservation-PII anonymisation, 24 months), so the
# archive can never outlive the policy that governs what is in it.
ARCHIVE_KEEP_MONTHS="${ARCHIVE_KEEP_MONTHS:-24}"
BK_COMPOSE="${BK_COMPOSE:-docker compose -f docker-compose.prod.yml}"
BK_REGISTRY="${BK_REGISTRY:-tenants/registry.yml}"

bk_ts()  { date -u +%Y%m%dT%H%M%SZ; return $?; }
bk_now() { date -u +%FT%TZ; return $?; }
bk_log() { printf '==> [%s] %s\n' "$(bk_now)" "$*"; return $?; }
# No `return` here on purpose: this function's job is to END the script. A `return 1`
# would only unwind one frame, and every caller writes `… || bk_die "…"` expecting the
# process to stop.
bk_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Same slug shape provision-tenant.sh / deprovision-tenant.sh enforce. Every path this
# family builds interpolates a slug, so this is also the path-traversal guard.
bk_slug_ok() { [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]]; return $?; }

# A backup ref as the control-plane contract carries it: a path RELATIVE to $BACKUP_ROOT,
# under dumps/tenants/<slug>/ or archive/<slug>/. Anything else — absolute, traversing,
# or belonging to another tenant — is refused. The control plane is PUBLIC-facing and
# hands us these strings, so this function is a trust boundary, not a formality.
bk_ref_ok() { # <ref> <slug>
  local ref="${1:-}" slug="${2:-}"
  bk_slug_ok "$slug" || return 1
  [[ -n "$ref" ]] || return 1
  [[ "$ref" != /* ]] || return 1
  [[ "$ref" != *".."* ]] || return 1
  [[ "$ref" != *$'\n'* ]] || return 1
  [[ "$ref" == "dumps/tenants/${slug}/"* || "$ref" == "archive/${slug}/"* ]] || return 1
  # No shell metacharacters, no spaces: refs are machine-generated names.
  [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]]
  return $?
}

# --- BEGIN pure helpers (extracted by tests/backup-lib.sh) --------------------------
# python3 rather than `date -d` / `date -v`: GNU and BSD date disagree on every form of
# arithmetic, python3 is already a hard dependency of provision-tenant.sh, and this has
# to give the same answer on a box (GNU) and on a laptop (BSD).

# Is a <ts> (the YYYYMMDDTHHMMSSZ stamp in every artifact name) older than N months?
# rc 0 = older (i.e. expired), rc 1 = still within the window, rc 2 = unparseable.
bk_ts_older_than_months() { # <ts> <months> [now-ts]
  BK_TS="${1:-}" BK_MONTHS="${2:-}" BK_NOW="${3:-}" python3 - <<'PY'
import os, sys
from datetime import datetime, timezone

def parse(ts):
    return datetime.strptime(ts, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)

try:
    ts = parse(os.environ["BK_TS"])
    months = int(os.environ["BK_MONTHS"])
    now_raw = os.environ.get("BK_NOW") or ""
    now = parse(now_raw) if now_raw else datetime.now(timezone.utc)
except Exception:
    sys.exit(2)
if months < 0:
    sys.exit(2)
# Calendar months, not 30-day approximations: "24 months" in a retention policy means
# the same day-of-month two years on, and a clamp for the 31st of a short month.
y, m = ts.year, ts.month + months
y += (m - 1) // 12
m = (m - 1) % 12 + 1
day = min(ts.day, [31, 29 if (y % 4 == 0 and (y % 100 or y % 400 == 0)) else 28,
                   31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1])
expiry = ts.replace(year=y, month=m, day=day)
sys.exit(0 if now >= expiry else 1)
PY
  return $?
}

# The <ts> out of an artifact name or an archive dir, '' if there is none.
bk_ts_of() { # <path-or-name>
  local base="${1##*/}"
  if [[ "$base" =~ ([0-9]{8}T[0-9]{6}Z) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf ''
  fi
  return 0
}
# --- END pure helpers ---------------------------------------------------------------

# Read one tenant's registry entry into REG_* variables:  eval "$(bk_registry_eval slug)"
# REG_FOUND is 0/1 — the caller decides whether a missing entry is fatal, because it is
# for a backup (nothing to name) and it is NOT for an erasure (a departed tenant may
# already have been struck from the registry, and its archive still has to be reachable).
bk_registry_eval() { # <slug> [registry]
  BK_SLUG="$1" BK_REG="${2:-$BK_REGISTRY}" python3 - <<'PY'
import os, shlex, sys
import yaml

slug = os.environ["BK_SLUG"]
with open(os.environ["BK_REG"]) as fh:
    reg = yaml.safe_load(fh) or {}
t = (reg.get("tenants") or {}).get(slug)
if not t:
    print("REG_FOUND=0")
    sys.exit(0)
print("REG_FOUND=1")
for k in ("name", "status", "managed", "box", "domain", "db", "db_role",
          "compose_project", "admin_email"):
    v = t.get(k, "")
    print("REG_%s=%s" % (k.upper(), shlex.quote(str(v))))
PY
  return $?
}

# Every managed:scripts tenant on THIS box, one slug per line. `managed: legacy` (RUMI,
# ADR-006) is filtered out here and nowhere else — every caller loops over this, so the
# refusal to touch tenant 1 lives in exactly one place.
#
# Status is deliberately NOT filtered: it is descriptive and drifts, and "does this
# tenant have a database right now" is the question that actually matters. Callers skip
# a tenant whose DB does not exist (the `smoke` fixture, between runs).
bk_registry_tenants() { # <box_role> [registry]
  BK_BOX="$1" BK_REG="${2:-$BK_REGISTRY}" python3 - <<'PY'
import os
import yaml

box = os.environ["BK_BOX"]
with open(os.environ["BK_REG"]) as fh:
    reg = yaml.safe_load(fh) or {}
for slug, t in sorted((reg.get("tenants") or {}).items()):
    if not isinstance(t, dict):
        continue
    if str(t.get("managed", "")) != "scripts":
        continue
    if str(t.get("box", "")) != box:
        continue
    print(slug)
PY
  return $?
}

# --- postgres access (shared guards) ------------------------------------------------
# The box .env is the only source of the superuser name; every script here runs from
# /opt/rumi/deploy where it lives.
bk_pg_user() {
  local u
  u="$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2- | tr -d '"'"'"'' || true)"
  [[ -n "$u" ]] || bk_die "POSTGRES_USER not set in the box .env"
  printf '%s' "$u"
  return 0
}

# Fail loudly if postgres is down. THE guard of this whole family: a stopped container
# must never be indistinguishable from "the tenant has no data", which would write a
# valid-looking empty backup over a good retention slot. Copied from backup-dump.sh /
# deprovision-tenant.sh, which have carried it since 2026-07-09.
bk_pg_up() { # <pguser>
  local pguser="$1"
  $BK_COMPOSE exec -T postgres psql -U "$pguser" -d postgres -c 'SELECT 1' >/dev/null
  return $?
}

bk_db_exists() { # <pguser> <db>
  local pguser="$1" db="$2"
  $BK_COMPOSE exec -T postgres psql -U "$pguser" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1
  return $?
}

# --- artifact plumbing ---------------------------------------------------------------
bk_sha256() { # <file> -> hex, or '' if no tool is available
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | cut -d' ' -f1
  else
    printf ''
  fi
  return 0
}

bk_size() { # <file> -> bytes
  local file="$1"
  python3 -c 'import os,sys; print(os.path.getsize(sys.argv[1]))' "$file"
  return $?
}

# Tar a live, root-owned directory through a throwaway container — tenant uploads belong
# to the backend uid, so the deploy user cannot read them directly. Tolerates tar rc=1
# ("file changed as we read it" on a live dir; the archive is still written); rc>=2 is
# real. Same helper backup-dump.sh uses, kept identical on purpose.
bk_tar_dir() { # <host-dir> <out.tar.gz>
  local src="$1" out="$2" rc=0
  docker run --rm -v "${src}:/src:ro" alpine:3 tar -czf - -C /src . > "${out}.tmp" || rc=$?
  if [[ $rc -ge 2 ]]; then
    rm -f "${out}.tmp"
    printf 'ERROR: tar %s failed (rc=%s)\n' "$src" "$rc" >&2
    return "$rc"
  fi
  [[ $rc -eq 1 ]] && printf '   warn: tar rc=1 (file changed while reading) — archive kept\n'
  mv "${out}.tmp" "$out"
}

# ── OFF-BOX artifacts, read from a restic repository this box can actually open ──────
#
# WHY THIS EXISTS. `bk_inventory_json` above walks the box FILESYSTEM, so everything it
# finds is by definition on the box, and it says so: `location: "local"`, hard-coded.
# Meanwhile backup-offsite.sh ships that whole dump directory into an encrypted restic
# repository every night. The control plane therefore had no way to learn that an
# off-box copy exists, and its "every copy sits on the box that runs this tenant"
# signal was permanently true for every tenant while the off-box copies demonstrably
# existed (ADR-014 D5 removed it from the alarm for exactly that reason). This function
# is the missing half: it reads what the repository actually holds.
#
# MEASURED, and it decides the shape (2026-08-21): only the PROD box has restic and the
# repository key at all — staging has neither binary nor password, and the repo dir it
# hosts is prod's, encrypted and opaque to it. Prod holds `restic-staging`, which is
# where the per-tenant dumps of the STAGING box's tenants land. So the box that reports
# a tenant's off-box copy is NOT the box that runs the tenant, and that is fine: the
# ingest's natural key is (box, location, ref) and the page groups by slug.
#
# Only the LATEST snapshot per tag is read. An older snapshot holds older copies of the
# same files; enumerating all eleven would multiply every row by eleven and answer a
# question nobody asked — "is there an off-box copy of this tenant's dump" is answered
# by the newest one.
#
# FAILS LOUDLY AND EMITS NOTHING on any error. A partial listing is the one output that
# must never reach the control plane: the push PRUNES what it stops listing, so half an
# answer would delete the other half's rows. Callers must treat a non-zero return as
# "do not push at all" rather than "push what we have".
bk_restic_artifacts_json() { # <repo> <tag> [tag...]
  local repo="${1:?usage: bk_restic_artifacts_json <repo> <tag> [tag...]}"
  shift
  [[ $# -gt 0 ]] || bk_die "bk_restic_artifacts_json needs at least one tag"
  command -v restic >/dev/null || bk_die "restic not installed — cannot enumerate $repo"
  : "${RESTIC_PASSWORD:?RESTIC_PASSWORD not set (see /root/.rumi-backup-env)}"

  local tag listing="" chunk
  for tag in "$@"; do
    # `latest` + --tag is one snapshot per tag. A tag with no snapshot is an ERROR here,
    # not an empty list: a repository that has stopped receiving a series is precisely
    # the thing this feature exists to make visible, and silently reporting "no off-box
    # copies" would prune the rows that say otherwise.
    chunk="$(restic -r "$repo" ls --json --tag "$tag" latest 2>&1)" \
      || bk_die "restic ls failed for tag '$tag' in $repo: $(printf '%s' "$chunk" | tail -1)"
    listing+="$chunk"$'\n'
  done

  BK_REPO_LABEL="$(basename "$repo")" python3 -c '
import json, os, re, sys

# The snapshot header line carries short_id; every following node line belongs to it.
TS = re.compile(r"(\d{8}T\d{6}Z)")
DUMP = re.compile(r"/tenants/([a-z0-9][a-z0-9-]*)/\1-(scheduled|manual)-(\d{8}T\d{6}Z)\.sql\.gz$")
ARCHIVE = re.compile(r"/archive/([a-z0-9][a-z0-9-]*)/(\d{8}T\d{6}Z)/[^/]+$")
label = os.environ["BK_REPO_LABEL"]


def iso(ts):
    return "%s-%s-%sT%s:%s:%sZ" % (ts[0:4], ts[4:6], ts[6:8], ts[9:11], ts[11:13], ts[13:15])


snap = None
artifacts = {}
archives = {}
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    node = json.loads(line)
    if node.get("struct_type") == "snapshot" or node.get("message_type") == "snapshot":
        snap = node.get("short_id") or node.get("id", "")[:8]
        continue
    if node.get("type") != "file" or not snap:
        continue
    path = node.get("path", "")

    m = DUMP.search(path)
    if m:
        slug, kind, ts = m.group(1), m.group(2), m.group(3)
        ref = "%s@%s:%s" % (label, snap, path)
        artifacts[ref] = {
            "tenantSlug": slug, "kind": kind, "takenAt": iso(ts),
            "sizeBytes": node.get("size", 0), "location": "restic",
            # No sha256: restic checksums its own contents, and the sidecar file is a
            # separate node in this listing rather than a property of this one.
            "ref": ref, "sha256": None,
        }
        continue

    m = ARCHIVE.search(path)
    if m:
        # ONE artifact per archive directory, as the local walk does — the manifest is
        # what makes it a restorable unit, so its parts must not be listed separately.
        # `kind` is `archive` rather than `deprovision`: the reason lives inside
        # manifest.json, and reading a file out of a snapshot to learn it would cost a
        # `restic dump` per archive per tick for a distinction the LOCAL row already
        # carries.
        slug, ts = m.group(1), m.group(2)
        ref = "%s@%s:%s" % (label, snap, path.rsplit("/", 1)[0])
        a = archives.setdefault(ref, {
            "tenantSlug": slug, "kind": "archive", "takenAt": iso(ts),
            "sizeBytes": 0, "location": "restic", "ref": ref, "sha256": None,
        })
        a["sizeBytes"] += node.get("size", 0)

artifacts.update(archives)
json.dump([artifacts[r] for r in sorted(artifacts)], sys.stdout, separators=(",", ":"))
' <<< "$listing"
}

# The whole-box inventory, as the control-plane contract defines it. Walks the two
# artifact trees; emits nothing that is not on disk right now, so a deleted artifact
# disappears from the next push (the endpoint is an idempotent whole-box upsert).
bk_inventory_json() { # <box> [reportedAt]
  BK_BOX="$1" BK_REPORTED="${2:-$(bk_now)}" \
  BK_TENANT_DUMPS="$TENANT_DUMP_DIR" BK_ARCHIVES="$ARCHIVE_DIR" BK_ROOT="$BACKUP_ROOT" \
  python3 - <<'PY'
import json, os, re

root = os.environ["BK_ROOT"]
TS = re.compile(r"(\d{8}T\d{6}Z)")


def iso(ts):
    return "%s-%s-%sT%s:%s:%sZ" % (ts[0:4], ts[4:6], ts[6:8], ts[9:11], ts[11:13], ts[13:15])


def ref_of(path):
    return os.path.relpath(path, root)


def sidecar_sha(path):
    try:
        with open(path + ".sha256") as fh:
            return (fh.read().split() or [None])[0]
    except OSError:
        return None


artifacts = []

# 1. per-tenant nightly / on-demand dumps: dumps/tenants/<slug>/<slug>-<kind>-<ts>.sql.gz
tdir = os.environ["BK_TENANT_DUMPS"]
for slug in sorted(os.listdir(tdir)) if os.path.isdir(tdir) else []:
    d = os.path.join(tdir, slug)
    if not os.path.isdir(d):
        continue
    for name in sorted(os.listdir(d)):
        if not name.endswith(".sql.gz"):
            continue
        m = TS.search(name)
        if not m:
            continue
        kind = "manual" if "-manual-" in name else "scheduled"
        p = os.path.join(d, name)
        artifacts.append({
            "tenantSlug": slug, "kind": kind, "takenAt": iso(m.group(1)),
            "sizeBytes": os.path.getsize(p), "location": "local",
            "ref": ref_of(p), "sha256": sidecar_sha(p),
        })

# 2. long-retention archives: archive/<slug>/<ts>/{db.sql.gz,uploads.tar.gz,manifest.json}
#    ONE artifact per archive — the manifest is what makes it a unit.
adir = os.environ["BK_ARCHIVES"]
for slug in sorted(os.listdir(adir)) if os.path.isdir(adir) else []:
    d = os.path.join(adir, slug)
    if not os.path.isdir(d):
        continue
    for stamp in sorted(os.listdir(d)):
        box = os.path.join(d, stamp)
        if not (os.path.isdir(box) and TS.match(stamp)):
            continue
        size = 0
        for f in os.listdir(box):
            fp = os.path.join(box, f)
            if os.path.isfile(fp):
                size += os.path.getsize(fp)
        reason, sha = "archive", None
        try:
            with open(os.path.join(box, "manifest.json")) as fh:
                man = json.load(fh)
            reason = man.get("reason") or "archive"
            sha = (man.get("db") or {}).get("sha256")
        except (OSError, ValueError):
            pass
        artifacts.append({
            "tenantSlug": slug,
            # The contract's vocabulary: an archive taken BY a teardown reports as
            # `deprovision` so the control plane can say "this is what we kept when
            # they left" rather than "someone pressed archive".
            "kind": "deprovision" if reason == "deprovision" else "archive",
            "takenAt": iso(stamp), "sizeBytes": size, "location": "local",
            "ref": ref_of(box), "sha256": sha,
        })

print(json.dumps({
    "box": os.environ["BK_BOX"],
    "reportedAt": os.environ["BK_REPORTED"],
    "artifacts": artifacts,
}, separators=(",", ":")))
PY
  return $?
}
