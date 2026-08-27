#!/usr/bin/env bash
# Behaviour tests for repair-order-ingredients.sh, run for real against a throwaway
# postgres. They exist because every way this script can be wrong is invisible to a linter
# and expensive in production: it writes into a LIVE table that holds one restaurant's
# receipts, and the two failures that would matter — running twice, or landing on a line
# the checkout path had already frozen — both look like success from the outside.
#
# It uses docker rather than a mock, and FAILS rather than skips when docker is missing:
# a green run that proved nothing is the exact shape this repo's CI header complains about.
# The same runner already runs `docker compose config`, so docker is present in CI.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SCRIPT="$ROOT/repair-order-ingredients.sh"
[[ -x "$SCRIPT" ]] || { echo "cannot find an executable $SCRIPT"; exit 1; }
command -v docker >/dev/null || { echo "docker is required by this test and is not installed"; exit 1; }

CN="repair-oi-test-$$"
TMP="$(mktemp -d)"
cleanup() { docker rm -f "$CN" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT
fail=0
pass() { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }

docker run --rm -d --name "$CN" -e POSTGRES_PASSWORD=test --network none postgres:16 >/dev/null
for _ in $(seq 1 60); do docker exec "$CN" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
docker exec "$CN" pg_isready -U postgres >/dev/null 2>&1 || { echo "scratch postgres never became ready"; exit 1; }

P() { docker exec -i "$CN" psql -U postgres -d repairtest -v ON_ERROR_STOP=1 -tAq "$@"; }
export PSQL_CMD="docker exec -i $CN psql -U postgres -d repairtest"
run() { ( cd "$ROOT" && REPAIR_DB=repairtest "$SCRIPT" "$@" ); }

# Ids are fixed rather than generated so a failure message names the same row every time.
OI_A=11111111-1111-4111-8111-111111111111   # a fully repairable historic line
OI_B=22222222-2222-4222-8222-222222222222   # a PARTLY repairable line: 3 ids, 2 recovered
OI_C=33333333-3333-4333-8333-333333333333   # a line the checkout path ALREADY froze
OI_GONE=99999999-9999-4999-8999-999999999999 # in the payload, not in the database
OI_NEW=44444444-4444-4444-8444-444444444444  # a MODERN line: placed after the snapshot
                                             # table existed, by a guest who customised
                                             # nothing, so it has no snapshot rows either
O_OLD=aaaa0000-0000-4000-8000-000000000001
O_NEW=aaaa0000-0000-4000-8000-000000000002

seed_schema() {
  docker exec -i "$CN" psql -U postgres -v ON_ERROR_STOP=1 -q -c 'DROP DATABASE IF EXISTS repairtest' >/dev/null
  docker exec -i "$CN" psql -U postgres -v ON_ERROR_STOP=1 -q -c 'CREATE DATABASE repairtest' >/dev/null
  # The two columns of the real schema this script depends on, and nothing else. Copied
  # from migration 20260827202652_AddOrderItemIngredientSnapshot.
  P -q <<'SQL' >/dev/null
CREATE TABLE orders (id uuid PRIMARY KEY, created_at timestamptz NOT NULL);
CREATE TABLE "OrderItems" (id uuid PRIMARY KEY, order_id uuid NOT NULL REFERENCES orders(id), product_name text NOT NULL);
CREATE TABLE "OrderItemIngredients" (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_item_id uuid NOT NULL REFERENCES "OrderItems"(id) ON DELETE CASCADE,
  ingredient_id uuid NOT NULL,
  ingredient_name varchar(200) NOT NULL,
  quantity int NOT NULL,
  is_removed boolean NOT NULL,
  sort_order int NOT NULL,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz,
  created_by text NOT NULL,
  updated_by text);
SQL
  P -q -c "INSERT INTO orders VALUES
    ('$O_OLD', TIMESTAMPTZ '2026-07-19 10:10:52+00'),
    ('$O_NEW', TIMESTAMPTZ '2026-09-01 12:00:00+00')" >/dev/null
  P -q -c "INSERT INTO \"OrderItems\" VALUES
    ('$OI_A','$O_OLD','Chicken Salad'),('$OI_B','$O_OLD','Etli Ekmek'),
    ('$OI_C','$O_OLD','Adana Grill'),('$OI_NEW','$O_NEW','Crème Brûlée')" >/dev/null
  # OI_C is what a line frozen by the live checkout path looks like. It must come out of
  # every run of this script byte for byte unchanged.
  P -q -c "INSERT INTO \"OrderItemIngredients\"
      (order_item_id, ingredient_id, ingredient_name, quantity, is_removed, sort_order, created_by)
    VALUES ('$OI_C','aaaaaaaa-0000-4000-8000-000000000001','Lamb',1,false,0,'checkout')" >/dev/null
}

write_payload() {
  cat > "$TMP/payload.tsv" <<EOF
# a comment line, and a blank one below, both of which COPY would choke on

$OI_A	aaaaaaaa-0000-4000-8000-00000000000a	Chicken	1	false	0
$OI_A	aaaaaaaa-0000-4000-8000-00000000000b	Tomatoes	0	true	1
$OI_B	bbbbbbbb-0000-4000-8000-00000000000a	Ground beef	1	false	0
$OI_B	bbbbbbbb-0000-4000-8000-00000000000b	Crème fraîche	1	false	1
$OI_B	bbbbbbbb-0000-4000-8000-00000000000c	Kırmızı biber	1	false	2
$OI_C	cccccccc-0000-4000-8000-00000000000a	Lamb	1	false	0
$OI_GONE	dddddddd-0000-4000-8000-00000000000a	Rice	1	false	0
$OI_NEW	eeeeeeee-0000-4000-8000-00000000000a	Vanilla	1	false	0
EOF
}

count()      { P -c "SELECT count(*) FROM \"OrderItemIngredients\""; }
count_repair(){ P -c "SELECT count(*) FROM \"OrderItemIngredients\" WHERE created_by='order-ingredient-text-repair'"; }
snap_c()     { P -c "SELECT ingredient_name||'|'||quantity||'|'||is_removed||'|'||sort_order||'|'||created_by
                     FROM \"OrderItemIngredients\" WHERE order_item_id='$OI_C' ORDER BY sort_order"; }

# ── 1. the table has to exist first ─────────────────────────────────────────────────
echo "refuses to run before the backend migration:"
seed_schema
P -q -c 'DROP TABLE "OrderItemIngredients"' >/dev/null
write_payload
if out="$(run --data "$TMP/payload.tsv" --apply --confirm 2>&1)"; then
  bad "ran against a database with no OrderItemIngredients table"
else
  grep -q '20260827202652_AddOrderItemIngredientSnapshot' <<<"$out" \
    && pass "names the migration that must ship first" \
    || bad "refused, but did not say which migration is missing: $out"
fi

# ── 2. dry run ──────────────────────────────────────────────────────────────────────
echo
echo "dry run:"
seed_schema
write_payload
before="$(count)"
out="$(run --data "$TMP/payload.tsv")" || bad "dry run exited non-zero"
[[ "$(count)" == "$before" ]] && pass "writes nothing" || bad "the dry run wrote to the table"
grep -q 'ROLLED BACK' <<<"$out" && pass "says it rolled back" || bad "did not report the rollback"
grep -q "$OI_GONE" <<<"$out" && pass "names the payload line whose order item is gone" \
  || bad "did not report the missing order item"
grep -q "$OI_C" <<<"$out" && pass "names the line it skips for already having a snapshot" \
  || bad "did not report the already-frozen line"
grep -q "$OI_NEW" <<<"$out" && pass "names the line it skips as too new" \
  || bad "did not report the too-new line"

# ── 3. apply ────────────────────────────────────────────────────────────────────────
echo
echo "apply:"
C_BEFORE="$(snap_c)"
run --data "$TMP/payload.tsv" --apply --confirm >/dev/null || bad "apply exited non-zero"
[[ "$(count_repair)" == "5" ]] && pass "inserts exactly the 5 rows of the 2 repairable lines" \
  || bad "expected 5 repair rows, got $(count_repair)"
got="$(P -c "SELECT ingredient_name||'|'||quantity||'|'||is_removed||'|'||sort_order
             FROM \"OrderItemIngredients\" WHERE order_item_id='$OI_A' ORDER BY sort_order")"
[[ "$got" == "Chicken|1|false|0
Tomatoes|0|true|1" ]] && pass "name, quantity, removal flag and order survive the round trip" \
  || bad "row content is wrong: $got"
[[ "$(P -c "SELECT count(*) FROM \"OrderItemIngredients\" WHERE order_item_id='$OI_B'")" == "3" ]] \
  && pass "a PARTLY repairable line gets exactly the rows that were recovered" \
  || bad "the partly repairable line did not get its 3 rows"
got="$(P -c "SELECT string_agg(ingredient_name, '|' ORDER BY sort_order)
             FROM \"OrderItemIngredients\" WHERE order_item_id='$OI_B'")"
[[ "$got" == "Ground beef|Crème fraîche|Kırmızı biber" ]] \
  && pass "accented and Turkish names survive the COPY round trip unchanged" \
  || bad "a non-ASCII name was mangled: $got"
[[ "$(P -c "SELECT count(*) FROM \"OrderItemIngredients\"
            WHERE created_by='order-ingredient-text-repair'
              AND (updated_at IS NOT NULL OR updated_by IS NOT NULL)")" == "0" ]] \
  && pass "leaves updated_at / updated_by NULL — these rows are written once, never touched" \
  || bad "the repair set an updated_* column"
[[ "$(P -c "SELECT count(*) FROM \"OrderItemIngredients\" WHERE order_item_id='$OI_NEW'")" == "0" ]] \
  && pass "a MODERN line with no snapshot is skipped by the age bound, not fabricated onto" \
  || bad "the repair wrote onto an order placed after the snapshot table existed"
[[ "$(P -c "SELECT count(*) FROM \"OrderItemIngredients\" WHERE order_item_id='$OI_GONE'")" == "0" ]] \
  && pass "a payload line with no order item is skipped, and does not abort the rest" \
  || bad "wrote a row for a non-existent order item"

# ── 4. the line the checkout path already froze ─────────────────────────────────────
echo
echo "a line that already has a snapshot:"
[[ "$(snap_c)" == "$C_BEFORE" ]] && pass "is byte-identical after the repair ran" \
  || bad "the already-frozen line changed: $(snap_c)"
[[ "$(P -c "SELECT count(*) FROM \"OrderItemIngredients\" WHERE order_item_id='$OI_C'")" == "1" ]] \
  && pass "gains no extra row from the payload" || bad "the payload added a row to a frozen line"

# ── 5. idempotence ──────────────────────────────────────────────────────────────────
echo
echo "second run:"
total="$(count)"
run --data "$TMP/payload.tsv" --apply --confirm >/dev/null || bad "second apply exited non-zero"
[[ "$(count)" == "$total" ]] && pass "inserts nothing the second time" \
  || bad "a second apply wrote more rows ($total -> $(count))"
run --data "$TMP/payload.tsv" >/dev/null || bad "dry run after apply exited non-zero"
[[ "$(count)" == "$total" ]] && pass "and the dry run after it is still a no-op" || bad "the dry run wrote"

# ── 6. rollback ─────────────────────────────────────────────────────────────────────
echo
echo "rollback:"
out="$(run --rollback)" || bad "rollback without --confirm exited non-zero"
[[ "$(count_repair)" == "5" ]] && pass "does nothing without --confirm" || bad "deleted without --confirm"
run --rollback --confirm >/dev/null || bad "rollback --confirm exited non-zero"
[[ "$(count_repair)" == "0" ]] && pass "removes every row this repair wrote" \
  || bad "rollback left $(count_repair) repair rows"
[[ "$(snap_c)" == "$C_BEFORE" ]] && pass "and leaves the checkout-written snapshot alone" \
  || bad "rollback touched a row it did not write"

# ── 7. a payload it must refuse ─────────────────────────────────────────────────────
echo
echo "malformed payloads are refused before postgres sees them:"
seed_schema
before="$(count)"
printf '%s\t%s\tCheese\t1\tfalse\n' "$OI_A" 'aaaaaaaa-0000-4000-8000-00000000000a' > "$TMP/bad.tsv"
run --data "$TMP/bad.tsv" --apply --confirm >/dev/null 2>&1 && bad "accepted a 5-field row" \
  || pass "a row with the wrong field count is refused"
printf '%s\t%s\tCre\\Nme\t1\tfalse\t0\n' "$OI_A" 'aaaaaaaa-0000-4000-8000-00000000000a' > "$TMP/bad2.tsv"
run --data "$TMP/bad2.tsv" --apply --confirm >/dev/null 2>&1 && bad "accepted a backslash in a name" \
  || pass "a backslash — which COPY would read as an escape — is refused"
printf '%s\tnot-a-uuid\tCheese\t1\tfalse\t0\n' "$OI_A" > "$TMP/bad3.tsv"
run --data "$TMP/bad3.tsv" --apply --confirm >/dev/null 2>&1 && bad "accepted a non-uuid ingredient id" \
  || pass "a non-uuid id is refused"
# A duplicate is the one malformed payload that would NOT fail loudly: the NOT EXISTS is
# evaluated against the table as it stood before the statement, so two identical rows do not
# see each other, and there is no unique constraint to catch them.
ID_D=aaaaaaaa-0000-4000-8000-00000000000a
printf '%s\t%s\tCheese\t1\tfalse\t0\n%s\t%s\tCheese\t1\tfalse\t0\n' "$OI_A" "$ID_D" "$OI_A" "$ID_D" > "$TMP/dup.tsv"
run --data "$TMP/dup.tsv" --apply --confirm >/dev/null 2>&1 && bad "accepted a duplicated row" \
  || pass "a duplicated row — which would be inserted twice — is refused"
printf '%s\t%s\tCheese\t1\tfalse\t0\n%s\t%s\tOnions\t1\tfalse\t0\n' \
  "$OI_A" "$ID_D" "$OI_A" 'aaaaaaaa-0000-4000-8000-00000000000b' > "$TMP/dupsort.tsv"
run --data "$TMP/dupsort.tsv" --apply --confirm >/dev/null 2>&1 && bad "accepted two rows at one sort_order" \
  || pass "two rows of one line sharing a sort_order are refused"
printf '%s\t%s\t%s\t1\tfalse\t0\n' "$OI_A" "$ID_D" "$(printf 'x%.0s' $(seq 1 201))" > "$TMP/long.tsv"
run --data "$TMP/long.tsv" --apply --confirm >/dev/null 2>&1 && bad "accepted a name longer than the column" \
  || pass "a name too long for varchar(200) is refused on the desk, not mid-transaction"
printf '%s\t%s\tCheese\t1\tfalse\t0\r\n' "$OI_A" "$ID_D" > "$TMP/crlf.tsv"
run --data "$TMP/crlf.tsv" --apply --confirm >/dev/null 2>&1 && bad "accepted DOS line endings" \
  || pass "a CRLF payload is refused (the CR would land inside sort_order)"
printf '%s\t%s\t   \t1\tfalse\t0\n' "$OI_A" "$ID_D" > "$TMP/blank.tsv"
run --data "$TMP/blank.tsv" --apply --confirm >/dev/null 2>&1 && bad "accepted a whitespace-only name" \
  || pass "a whitespace-only name is refused (it would render as an empty line on a ticket)"
printf '%s\t%s\tCheese \t1\tfalse\t0\n' "$OI_A" "$ID_D" > "$TMP/pad.tsv"
run --data "$TMP/pad.tsv" --apply --confirm >/dev/null 2>&1 && bad "accepted a padded name" \
  || pass "a name with a trailing space is refused, not silently frozen with the padding"
# Four duplicate groups: with a `head -3` in the check this exits through pipefail with no
# message at all, which is the failure mode that teaches an operator nothing.
: > "$TMP/dup4.tsv"
for n in a b c d; do
  printf '%s\taaaaaaaa-0000-4000-8000-00000000000%s\tX\t1\tfalse\t0\n' "$OI_A" "$n" >> "$TMP/dup4.tsv"
  printf '%s\taaaaaaaa-0000-4000-8000-00000000000%s\tX\t1\tfalse\t0\n' "$OI_A" "$n" >> "$TMP/dup4.tsv"
done
out="$(run --data "$TMP/dup4.tsv" --apply --confirm 2>&1)" && bad "accepted 4 duplicate groups" || true
grep -q 'duplicate rows' <<<"$out" \
  && pass "four duplicate groups still SAY they are duplicates, instead of exiting silently" \
  || bad "a 4-group duplicate payload failed without a message: $out"
[[ "$(count)" == "$before" ]] && pass "and none of them wrote a row" || bad "a refused payload still wrote"

# ── 8. contradictory flags ──────────────────────────────────────────────────────────
echo
echo "flags:"
run --data "$TMP/payload.tsv" --apply --rollback --confirm >/dev/null 2>&1 \
  && bad "--apply --rollback ran instead of refusing" \
  || pass "--apply and --rollback together are refused, not silently resolved to a DELETE"

# ── 9. --apply is gated too, and the dry run really is the writing statement ─────────
echo
echo "the two gates:"
seed_schema
write_payload
before="$(count)"
run --data "$TMP/payload.tsv" --apply >/dev/null 2>&1 && bad "--apply ran without --confirm" \
  || pass "--apply refuses without --confirm, exactly as --rollback does"
[[ "$(count)" == "$before" ]] && pass "and wrote nothing" || bad "an ungated --apply wrote"

# The claim "the dry run IS the real INSERT" is only worth making if a payload that fails at
# the DATABASE fails the same way in both modes. A quantity past int range gets through the
# awk gate (it is all digits) and dies inside COPY, which is exactly the probe needed.
printf '%s\t%s\tCheese\t99999999999\tfalse\t0\n' "$OI_A" 'aaaaaaaa-0000-4000-8000-00000000000a' \
  > "$TMP/overflow.tsv"
run --data "$TMP/overflow.tsv" >/dev/null 2>&1                 && dry_rc=0 || dry_rc=$?
run --data "$TMP/overflow.tsv" --apply --confirm >/dev/null 2>&1 && app_rc=0 || app_rc=$?
[[ "$dry_rc" -ne 0 && "$app_rc" -ne 0 ]] \
  && pass "a payload postgres rejects fails in BOTH modes — the dry run is the real statement" \
  || bad "dry run and apply disagreed on a database-level failure (dry=$dry_rc apply=$app_rc)"
[[ "$(count)" == "$before" ]] && pass "and the aborted transaction committed nothing" \
  || bad "a failed apply left rows behind"

# ── 10. paths ───────────────────────────────────────────────────────────────────────
echo
echo "paths:"
cp "$TMP/payload.tsv" "$TMP/relative.tsv"
out="$( cd "$TMP" && REPAIR_DB=repairtest "$SCRIPT" --data relative.tsv 2>&1 )" \
  && pass "a RELATIVE --data resolves against the operator's directory, not the script's" \
  || bad "a relative --data was not found: $out"
out="$( cd "$TMP" && "$SCRIPT" --help 2>&1 )"
grep -q 'DRY RUN (default)' <<<"$out" && pass "--help works from any directory" \
  || bad "--help broke outside the script's own directory: $out"

echo
[[ $fail -eq 0 ]] && echo "all good" || echo "FAILURES above"
exit $fail
