#!/usr/bin/env bash
# Which artifact `restore-tenant.sh --from latest` actually picks.
#
# This exists because the answer was wrong for as long as the script has existed, and wrong in the
# direction that costs the most: a dump is named `<slug>-<kind>-<stamp>.sql.gz`, so a plain
# `sort -r` orders by KIND before the timestamp and every `scheduled-…` outranks every `manual-…`.
# Measured on the staging box 2026-09-02 — a manual dump taken at 13:15 sorted BELOW a scheduled
# one from six days earlier, and the rehearsal restored the older file while truthfully printing
# the ref it used. A manual dump is precisely what an operator takes immediately before a risky
# change, so "restore the latest backup" quietly restored something else.
#
# The functions are EXTRACTED from restore-tenant.sh between its markers rather than copied here,
# for the reason tests/admin-password.sh gives: a copy is a second source of truth that passes
# forever after the original changes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../restore-tenant.sh"
[[ -f "$SCRIPT" ]] || { echo "cannot find restore-tenant.sh next to $HERE"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
pass() { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }

FNS="$TMP/fns.sh"
sed -n '/^# --- BEGIN artifact ordering/,/^# --- END artifact ordering/p' "$SCRIPT" > "$FNS"
grep -q 'list_artifacts()' "$FNS" || { echo "extraction failed — did the markers move?"; exit 1; }
grep -q 'artifact_stamp()' "$FNS" || { echo "extraction failed — did the markers move?"; exit 1; }

export TENANT_DUMP_DIR="$TMP/backups/dumps/tenants"
export ARCHIVE_DIR="$TMP/backups/archive"
SLUG=acme
mkdir -p "$TENANT_DUMP_DIR/$SLUG" "$ARCHIVE_DIR/$SLUG/20260801T120000Z"

# Stamps computed from NOW, not written down: a hardcoded 2026 date would keep passing while
# quietly testing nothing once the wall clock moved past it.
stamp_days_ago() { python3 -c '
from datetime import datetime, timedelta, timezone
import sys
print((datetime.now(timezone.utc) - timedelta(days=int(sys.argv[1]))).strftime("%Y%m%dT%H%M%SZ"))' "$1"; }

TODAY="$(stamp_days_ago 0)"
D2="$(stamp_days_ago 2)"
D6="$(stamp_days_ago 6)"

# The exact shape the box produces: scheduled nightlies, plus one manual dump taken just now.
# `manual` sorts BEFORE `scheduled` alphabetically, which is what made the old order look
# plausible while being upside down.
: > "$TENANT_DUMP_DIR/$SLUG/${SLUG}-scheduled-${D6}.sql.gz"
: > "$TENANT_DUMP_DIR/$SLUG/${SLUG}-scheduled-${D2}.sql.gz"
: > "$TENANT_DUMP_DIR/$SLUG/${SLUG}-manual-${TODAY}.sql.gz"
: > "$ARCHIVE_DIR/$SLUG/20260801T120000Z/db.sql.gz"

# shellcheck source=/dev/null
. "$FNS"

# `while read` rather than `mapfile`, and no negative array indices: both are bash 4+, and macOS
# ships bash 3.2 — the same constraint tests/tenant-palette.sh records.
read_order() { ORDER=(); while IFS= read -r line; do ORDER+=("$line"); done < <(list_artifacts); }

read_order
newest="$(basename "${ORDER[0]:-}")"

echo "restore-tenant.sh --from latest picks the NEWEST artifact:"
if [[ "$newest" == "${SLUG}-manual-${TODAY}.sql.gz" ]]; then
  pass "a manual dump taken today outranks a scheduled one from 6 days ago"
else
  bad  "expected ${SLUG}-manual-${TODAY}.sql.gz first, got '$newest'"
fi

# …and the rest are in descending time order, so `--list` is honest too, not just `head -1`.
expected=("${SLUG}-manual-${TODAY}.sql.gz" "${SLUG}-scheduled-${D2}.sql.gz" "${SLUG}-scheduled-${D6}.sql.gz")
actual=()
for p in "${ORDER[@]}"; do [[ -f "$p" ]] && actual+=("$(basename "$p")"); done
if [[ "${actual[*]}" == "${expected[*]}" ]]; then
  pass "every dump is listed newest-first"
else
  bad  "dump order was '${actual[*]}', expected '${expected[*]}'"
fi

# Archives are named by the stamp ALONE, so their own sort was never broken — and they stay
# GROUPED AFTER the dumps, which is what makes `--from latest` mean "the newest dump" and
# `--from archive:latest` the separate question it is.
last="${ORDER[$(( ${#ORDER[@]} - 1 ))]}"
if [[ "$(basename "${last%/}")" == "20260801T120000Z" ]]; then
  pass "archives still sort after the dumps"
else
  bad  "expected the archive last, got '$(basename "${last%/}")'"
fi

# A name carrying no stamp must not become "latest" by accident, and must not vanish either.
: > "$TENANT_DUMP_DIR/$SLUG/weird-no-stamp.sql.gz"
read_order
if [[ "$(basename "${ORDER[0]}")" == "${SLUG}-manual-${TODAY}.sql.gz" ]] \
   && printf '%s\n' "${ORDER[@]}" | grep -q 'weird-no-stamp'; then
  pass "an unrecognised filename sorts last but is still listed"
else
  bad  "unrecognised filename mishandled: first='$(basename "${ORDER[0]}")'"
fi

echo "the age it reports is read from the STAMP, so a copy that lost mtime still reads true:"
age_new="$(artifact_age "$TENANT_DUMP_DIR/$SLUG/${SLUG}-manual-${TODAY}.sql.gz")"
age_old="$(artifact_age "$TENANT_DUMP_DIR/$SLUG/${SLUG}-scheduled-${D6}.sql.gz")"
if [[ "$age_old" == "6d ago" ]]; then
  pass "a 6-day-old dump reports '6d ago' (files were created just now, so mtime would say 0m)"
else
  bad  "expected '6d ago' for the 6-day-old dump, got '$age_old'"
fi
if [[ "$age_new" =~ ^[0-9]+m\ ago$ ]]; then
  pass "a dump taken today reports minutes ($age_new)"
else
  bad  "expected minutes for today's dump, got '$age_new'"
fi

# An ARCHIVE carries its stamp on the DIRECTORY — `archive/<slug>/<stamp>/db.sql.gz` — so reading
# the basename alone silently falls through to mtime. That is worst exactly where it matters most:
# a departed tenant's archive rsynced back from cold storage has a copy-time mtime, and the age
# line exists to make a stale pick visible.
ARCH_STAMP="$(stamp_days_ago 32)"
mkdir -p "$ARCHIVE_DIR/$SLUG/$ARCH_STAMP"
: > "$ARCHIVE_DIR/$SLUG/$ARCH_STAMP/db.sql.gz"
age_arch="$(artifact_age "$ARCHIVE_DIR/$SLUG/$ARCH_STAMP/db.sql.gz")"
if [[ "$age_arch" == "32d ago" ]]; then
  pass "an archive's db.sql.gz reports 32d from its directory stamp, not 0m from mtime"
else
  bad  "expected '32d ago' from the archive directory stamp, got '$age_arch'"
fi

exit "$fail"
