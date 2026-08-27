#!/usr/bin/env bash
# One-shot repair of the ingredient TEXT on order lines placed before the snapshot table
# existed (backend #423 / SHARED-MODIFIERS-AND-SAUCES-PLAN slice S0r).
#
#   ./repair-order-ingredients.sh --data <file>                        # DRY RUN (default)
#   ./repair-order-ingredients.sh --data <file> --apply --confirm
#   ./repair-order-ingredients.sh --rollback --confirm                 # exact undo
#   ./repair-order-ingredients.sh --data <file> --before 2026-08-28    # the age bound
#
# WHY THIS EXISTS. Until backend #422, every product save deleted and re-created every
# `ProductIngredients` row with a fresh id, while `OrderItems.ingredient_quantities_json`
# holds those ids. So a past order line points at ids that no longer exist and renders no
# ingredient detail at all. Measured on prod 2026-08-27: 80 of 98 lines, 34 orders,
# 2026-07-19 -> 2026-08-22. #423 froze the text for NEW orders in `OrderItemIngredients`
# and deliberately backfilled nothing; this script is that backfill, for the historic rows
# only, from names recovered out of the restic `prod-dumps` cluster dumps.
#
# WHAT IT WILL AND WILL NOT DO — the safety contract, and the reason it is worth reading:
#   * INSERT ONLY. There is no UPDATE and no DELETE in the apply path. It cannot rewrite a
#     receipt; it can only give one that says nothing something to say.
#   * It never touches an order line that ALREADY has snapshot rows. The gate is per order
#     line, not per row, so a line written by the live checkout path is out of reach by
#     construction — which is also what makes a second run insert nothing.
#   * It is a NO-OP on the second run, and the dry run proves that by executing the real
#     statement inside a transaction it then rolls back. A dry run that only counts rows
#     is a different query from the one that writes, and the two can disagree.
#   * Every row it writes is stamped `created_by = order-ingredient-text-repair`, which is
#     what makes --rollback exact rather than a guess.
#
# THE DATA FILE IS NOT IN THIS REPO, on purpose. This repository is PUBLIC and the payload
# is one restaurant's order contents. It lives with the dry-run report in the private
# workspace repo (docs/plans/_research/) and is copied to the box for the run.
#
# Run ON THE BOX from /opt/rumi/deploy. See DEPLOYMENT.md, "Reading a backup to repair
# data, not to restore a box".
set -euo pipefail
# Both are captured BEFORE the cd: --help re-reads this file by name, and a relative --data
# belongs to the operator's directory, not to /opt/rumi/deploy. Resolving it after the cd
# silently picks up a same-named file sitting next to the script.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ORIG_PWD="$PWD"
cd "$(dirname "$0")"

MARKER="order-ingredient-text-repair"
DATA=""
DB="${REPAIR_DB:-restaurantdb}"
APPLY=false
ROLLBACK=false
CONFIRM=false
COMPOSE="${REPAIR_COMPOSE:-docker compose -f docker-compose.prod.yml}"
# An AGE BOUND, because "has no snapshot rows" does not mean "is a damaged historic line".
# A line placed AFTER #423 by a guest who customised nothing also has none, so a stray
# modern order id in the payload would fabricate ingredients on a live receipt rather than
# give a dead one its words back. The cutoff must be at or before the moment #423 reached
# prod; too early only skips rows, and the dry run shows exactly which.
CUTOFF="${REPAIR_CUTOFF:-2026-08-28}"

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data) DATA="${2:?--data needs a file}"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --rollback) ROLLBACK=true; shift ;;
    --confirm) CONFIRM=true; shift ;;
    --db) DB="${2:?--db needs a database name}"; shift 2 ;;
    --before) CUTOFF="${2:?--before needs a date}"; shift 2 ;;
    --dry-run|-n) shift ;;   # the default; accepted so the safe intent can be explicit
    -h|--help) sed -n '2,34p' "$SELF"; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

# CUTOFF is interpolated into the SQL below, so it is validated rather than trusted. It comes
# from an operator, not a request, but a stray quote here would be a syntax error inside a
# transaction that is about to write to a live database — an ugly place to learn about it.
[[ "$CUTOFF" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([\ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?([+-][0-9]{2}(:?[0-9]{2})?|Z)?)?$ ]] \
  || die "--before must be a plain date or timestamp, e.g. 2026-08-28 or '2026-08-28 00:00:00+00'"

# --rollback is handled before --apply below, so the pair would silently DELETE when the
# operator asked to write. Refuse instead of picking one.
if $ROLLBACK && $APPLY; then
  die "--apply and --rollback are opposites; pass one"
fi

# The dangerous mode is the one you have to ask for by name, and BOTH directions are
# dangerous: --apply writes into a live client database, --rollback deletes out of one. The
# asymmetry of gating only the second would be an accident waiting for a tired operator.
if $APPLY && ! $CONFIRM; then
  die "--apply writes to a live database; add --confirm.
  Run it without --apply first: that is the dry run, and it executes the real INSERT
  inside a transaction it then rolls back."
fi

# psql, either through the box's compose project or through whatever PSQL_CMD names.
# PSQL_CMD carries its own -d, so --db / REPAIR_DB apply to the compose path only; the
# preconditions below still run through whatever is in force, so a wrong database is caught
# by the table check rather than assumed away.
# The override is what lets tests/repair-order-ingredients.sh run this very file against a
# throwaway postgres, instead of asserting on its source text — the failure this repair can
# have is behavioural (it writes twice, it overwrites a real snapshot) and no linter sees it.
if [[ -n "${PSQL_CMD:-}" ]]; then
  psql_run() { $PSQL_CMD -v ON_ERROR_STOP=1 "$@"; }
else
  [[ -f .env ]] || die "box .env missing (run this from /opt/rumi/deploy, or set PSQL_CMD)"
  PGUSER_BOX="$(grep -E '^POSTGRES_USER=' .env | head -1 | cut -d= -f2- | tr -d "\"'")"
  [[ -n "$PGUSER_BOX" ]] || die "POSTGRES_USER not set in the box .env"
  psql_run() { $COMPOSE exec -T postgres psql -U "$PGUSER_BOX" -d "$DB" -v ON_ERROR_STOP=1 "$@"; }
fi

q() { psql_run -tAq -c "$1"; }

# ── preconditions ───────────────────────────────────────────────────────────────────
have_table="$(q "SELECT to_regclass('public.\"OrderItemIngredients\"') IS NOT NULL")" \
  || die "cannot reach database '$DB'"
if [[ "$have_table" != "t" ]]; then
  die "table \"OrderItemIngredients\" does not exist in '$DB'. It is created by backend
  migration 20260827202652_AddOrderItemIngredientSnapshot (#423). Release that first —
  this script repairs history, it does not create the place history is kept."
fi

# ── rollback ────────────────────────────────────────────────────────────────────────
if $ROLLBACK; then
  n="$(q "SELECT count(*) FROM \"OrderItemIngredients\" WHERE created_by = '$MARKER'")"
  echo "rows written by this repair: $n"
  if ! $CONFIRM; then
    echo "add --confirm to delete them. Nothing was changed."
    exit 0
  fi
  psql_run -q -c "DELETE FROM \"OrderItemIngredients\" WHERE created_by = '$MARKER'"
  left="$(q "SELECT count(*) FROM \"OrderItemIngredients\" WHERE created_by = '$MARKER'")"
  # $n is what was counted a moment ago, not what the DELETE reported, so it is phrased as
  # the before/after pair it actually is. $left is the number that matters.
  echo "was $n row(s); $left remain"
  [[ "$left" == "0" ]] || die "rollback left rows behind"
  exit 0
fi

# ── the payload ─────────────────────────────────────────────────────────────────────
[[ -n "$DATA" ]] || die "usage: $0 --data <file> [--apply] | $0 --rollback --confirm"
# A relative path belongs to where the operator typed it, not to /opt/rumi/deploy.
[[ "$DATA" == /* ]] || DATA="$ORIG_PWD/$DATA"
[[ -f "$DATA" ]] || die "data file '$DATA' not found"

# Comments and blank lines are stripped HERE rather than by postgres, because COPY has no
# notion of either and would import '# ...' as an order id.
CLEAN="$(mktemp)"; trap 'rm -f "$CLEAN"' EXIT
grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$DATA" > "$CLEAN" || true
rows="$(wc -l < "$CLEAN" | tr -d ' ')"
[[ "$rows" -gt 0 ]] || die "data file '$DATA' has no rows"

# Shape check before anything reaches postgres: 6 tab-separated fields, sane quantity and
# sort_order, no CR, a name that fits the column, and NO BACKSLASH anywhere — COPY ... FORMAT text reads a backslash as an
# escape, so an ingredient name containing one would arrive as a different word, or as
# NULL if it happened to be '\N'. A malformed payload should fail on the desk, not
# half-way through a transaction.
#
# The length test counts characters under gawk in a UTF-8 locale and bytes under mawk, so
# it is either exactly the column's own rule or stricter than it — never more permissive,
# which is the only direction that cannot surprise the transaction.
# It exists so an over-long name is refused before the transaction opens; postgres would
# also reject it, but mid-COPY and with a far less useful message.
awk -F'\t' '
  NF!=6                  { printf("line %d has %d fields, expected 6\n", NR, NF); bad=1 }
  $1 !~ /^[0-9a-fA-F-]{36}$/ { printf("line %d: %s is not a uuid\n", NR, $1); bad=1 }
  $2 !~ /^[0-9a-fA-F-]{36}$/ { printf("line %d: %s is not a uuid\n", NR, $2); bad=1 }
  $3 ~ /^[[:space:]]*$/  { printf("line %d: blank ingredient name\n", NR); bad=1 }
  $3 ~ /^[[:space:]]|[[:space:]]$/ { printf("line %d: ingredient name has leading or trailing space\n", NR); bad=1 }
  $4 !~ /^[0-9]+$/       { printf("line %d: quantity %s is not a number\n", NR, $4); bad=1 }
  $5 !~ /^(true|false)$/ { printf("line %d: is_removed %s is not true/false\n", NR, $5); bad=1 }
  $6 !~ /^[0-9]+$/       { printf("line %d: sort_order %s is not a number\n", NR, $6); bad=1 }
  /\\/                   { printf("line %d contains a backslash\n", NR); bad=1 }
  /\r/                   { printf("line %d has a CR — the file has DOS line endings\n", NR); bad=1 }
  length($3) > 200       { printf("line %d: ingredient name is %d bytes; the column is varchar(200)\n", NR, length($3)); bad=1 }
  END { exit bad?1:0 }' "$CLEAN" || die "malformed data file"

# A duplicate would be inserted TWICE. The NOT EXISTS below is evaluated against the table
# as it stood before the statement, so two identical payload rows do not see each other,
# and the table has no unique constraint to catch them (it cannot: a recipe may legitimately
# list the same ingredient id twice). The payload is generated, so a duplicate means the
# generator ran twice — refuse it rather than write it.
# No `head` in these pipelines: it would exit early on the fourth duplicate, SIGPIPE the
# `uniq` before it, and — under `set -o pipefail` — abort the whole script through the
# assignment with NO message at all. Failing silently is worse than printing four lines.
dupes="$(sort "$CLEAN" | uniq -d)"
[[ -z "$dupes" ]] || die "data file has duplicate rows, which would be inserted twice:
$dupes"
dupes="$(cut -f1,6 "$CLEAN" | sort | uniq -d)"
[[ -z "$dupes" ]] || die "data file gives one order line two rows at the same sort_order:
$dupes"

lines="$(cut -f1 "$CLEAN" | sort -u | wc -l | tr -d ' ')"
echo "payload: $rows row(s) across $lines order line(s), from $DATA"
echo "age bound: only lines whose ORDER was placed before $CUTOFF are eligible"

# ── the one statement, run identically in both modes ────────────────────────────────
# Staged into a TEMP table so the insert is one set-based statement rather than a loop, and
# so the report below can name what was skipped and why.
#
# The NOT EXISTS is keyed on order_item_id, NOT on the row: a line either has a frozen
# snapshot or it does not, and half-filling one would invent a receipt that never existed.
# The JOIN on "OrderItems" drops a payload row whose line has since been deleted — the FK
# would reject it anyway, and aborting the whole repair over one departed order would be
# the wrong trade.
emit_stream() {
  cat <<'EOSQL'
BEGIN;
CREATE TEMP TABLE repair_payload (
  order_item_id uuid, ingredient_id uuid, ingredient_name text,
  quantity int, is_removed boolean, sort_order int
) ON COMMIT DROP;
COPY repair_payload FROM STDIN WITH (FORMAT text, DELIMITER E'\t');
EOSQL
  cat "$CLEAN"
  echo '\.'
  cat <<EOSQL
\echo '-- payload lines whose order item no longer exists:'
SELECT DISTINCT p.order_item_id FROM repair_payload p
  LEFT JOIN "OrderItems" oi ON oi.id = p.order_item_id WHERE oi.id IS NULL;

\echo '-- payload lines skipped because they ALREADY carry a snapshot:'
SELECT DISTINCT p.order_item_id FROM repair_payload p
 WHERE EXISTS (SELECT 1 FROM "OrderItemIngredients" x WHERE x.order_item_id = p.order_item_id);

\echo '-- payload lines skipped as TOO NEW (order placed on or after the cutoff):'
SELECT DISTINCT p.order_item_id FROM repair_payload p
  JOIN "OrderItems" oi ON oi.id = p.order_item_id
  JOIN orders o ON o.id = oi.order_id
 WHERE o.created_at >= TIMESTAMPTZ '$CUTOFF';

INSERT INTO "OrderItemIngredients"
  (order_item_id, ingredient_id, ingredient_name, quantity, is_removed, sort_order,
   created_at, created_by)
SELECT p.order_item_id, p.ingredient_id, p.ingredient_name, p.quantity, p.is_removed,
       p.sort_order, CURRENT_TIMESTAMP, '$MARKER'
  FROM repair_payload p
  JOIN "OrderItems" oi ON oi.id = p.order_item_id
  JOIN orders o ON o.id = oi.order_id
 WHERE o.created_at < TIMESTAMPTZ '$CUTOFF'
   AND NOT EXISTS (
         SELECT 1 FROM "OrderItemIngredients" x WHERE x.order_item_id = p.order_item_id);

\echo '-- rows written by this repair in total, INSIDE this transaction:'
SELECT count(*) FROM "OrderItemIngredients" WHERE created_by = '$MARKER';
$1
EOSQL
}

if $APPLY; then
  echo "MODE: APPLY — inserting"
  emit_stream "COMMIT;" | psql_run
  echo "done."
else
  echo "MODE: DRY RUN — the real INSERT runs inside a transaction that is then ROLLED BACK"
  emit_stream "ROLLBACK;" | psql_run
  echo "nothing was committed. Re-run with --apply to write."
fi
