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

seed_schema() {
  docker exec -i "$CN" psql -U postgres -v ON_ERROR_STOP=1 -q -c 'DROP DATABASE IF EXISTS repairtest' >/dev/null
  docker exec -i "$CN" psql -U postgres -v ON_ERROR_STOP=1 -q -c 'CREATE DATABASE repairtest' >/dev/null
  # The two columns of the real schema this script depends on, and nothing else. Copied
  # from migration 20260827202652_AddOrderItemIngredientSnapshot.
  P -q <<'SQL' >/dev/null
CREATE TABLE "OrderItems" (id uuid PRIMARY KEY, product_name text NOT NULL);
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
  P -q -c "INSERT INTO \"OrderItems\" VALUES
    ('$OI_A','Chicken Salad'),('$OI_B','Etli Ekmek'),('$OI_C','Adana Grill')" >/dev/null
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
$OI_B	bbbbbbbb-0000-4000-8000-00000000000b	Onions	1	false	1
$OI_C	cccccccc-0000-4000-8000-00000000000a	Lamb	1	false	0
$OI_GONE	dddddddd-0000-4000-8000-00000000000a	Rice	1	false	0
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
if out="$(run --data "$TMP/payload.tsv" --apply 2>&1)"; then
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

# ── 3. apply ────────────────────────────────────────────────────────────────────────
echo
echo "apply:"
C_BEFORE="$(snap_c)"
run --data "$TMP/payload.tsv" --apply >/dev/null || bad "apply exited non-zero"
[[ "$(count_repair)" == "4" ]] && pass "inserts exactly the 4 rows of the 2 repairable lines" \
  || bad "expected 4 repair rows, got $(count_repair)"
got="$(P -c "SELECT ingredient_name||'|'||quantity||'|'||is_removed||'|'||sort_order
             FROM \"OrderItemIngredients\" WHERE order_item_id='$OI_A' ORDER BY sort_order")"
[[ "$got" == "Chicken|1|false|0
Tomatoes|0|true|1" ]] && pass "name, quantity, removal flag and order survive the round trip" \
  || bad "row content is wrong: $got"
[[ "$(P -c "SELECT count(*) FROM \"OrderItemIngredients\" WHERE order_item_id='$OI_B'")" == "2" ]] \
  && pass "a PARTLY repairable line gets exactly the rows that were recovered" \
  || bad "the partly repairable line did not get its 2 rows"
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
run --data "$TMP/payload.tsv" --apply >/dev/null || bad "second apply exited non-zero"
[[ "$(count)" == "$total" ]] && pass "inserts nothing the second time" \
  || bad "a second apply wrote more rows ($total -> $(count))"
run --data "$TMP/payload.tsv" >/dev/null || bad "dry run after apply exited non-zero"
[[ "$(count)" == "$total" ]] && pass "and the dry run after it is still a no-op" || bad "the dry run wrote"

# ── 6. rollback ─────────────────────────────────────────────────────────────────────
echo
echo "rollback:"
out="$(run --rollback)" || bad "rollback without --confirm exited non-zero"
[[ "$(count_repair)" == "4" ]] && pass "does nothing without --confirm" || bad "deleted without --confirm"
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
run --data "$TMP/bad.tsv" --apply >/dev/null 2>&1 && bad "accepted a 5-field row" \
  || pass "a row with the wrong field count is refused"
printf '%s\t%s\tCre\\Nme\t1\tfalse\t0\n' "$OI_A" 'aaaaaaaa-0000-4000-8000-00000000000a' > "$TMP/bad2.tsv"
run --data "$TMP/bad2.tsv" --apply >/dev/null 2>&1 && bad "accepted a backslash in a name" \
  || pass "a backslash — which COPY would read as an escape — is refused"
printf '%s\tnot-a-uuid\tCheese\t1\tfalse\t0\n' "$OI_A" > "$TMP/bad3.tsv"
run --data "$TMP/bad3.tsv" --apply >/dev/null 2>&1 && bad "accepted a non-uuid ingredient id" \
  || pass "a non-uuid id is refused"
# A duplicate is the one malformed payload that would NOT fail loudly: the NOT EXISTS is
# evaluated against the table as it stood before the statement, so two identical rows do not
# see each other, and there is no unique constraint to catch them.
ID_D=aaaaaaaa-0000-4000-8000-00000000000a
printf '%s\t%s\tCheese\t1\tfalse\t0\n%s\t%s\tCheese\t1\tfalse\t0\n' "$OI_A" "$ID_D" "$OI_A" "$ID_D" > "$TMP/dup.tsv"
run --data "$TMP/dup.tsv" --apply >/dev/null 2>&1 && bad "accepted a duplicated row" \
  || pass "a duplicated row — which would be inserted twice — is refused"
printf '%s\t%s\tCheese\t1\tfalse\t0\n%s\t%s\tOnions\t1\tfalse\t0\n' \
  "$OI_A" "$ID_D" "$OI_A" 'aaaaaaaa-0000-4000-8000-00000000000b' > "$TMP/dupsort.tsv"
run --data "$TMP/dupsort.tsv" --apply >/dev/null 2>&1 && bad "accepted two rows at one sort_order" \
  || pass "two rows of one line sharing a sort_order are refused"
printf '%s\t%s\t%s\t1\tfalse\t0\n' "$OI_A" "$ID_D" "$(printf 'x%.0s' $(seq 1 201))" > "$TMP/long.tsv"
run --data "$TMP/long.tsv" --apply >/dev/null 2>&1 && bad "accepted a name longer than the column" \
  || pass "a name too long for varchar(200) is refused on the desk, not mid-transaction"
printf '%s\t%s\tCheese\t1\tfalse\t0\r\n' "$OI_A" "$ID_D" > "$TMP/crlf.tsv"
run --data "$TMP/crlf.tsv" --apply >/dev/null 2>&1 && bad "accepted DOS line endings" \
  || pass "a CRLF payload is refused (the CR would land inside sort_order)"
[[ "$(count)" == "$before" ]] && pass "and none of them wrote a row" || bad "a refused payload still wrote"

# ── 8. contradictory flags ──────────────────────────────────────────────────────────
echo
echo "flags:"
run --data "$TMP/payload.tsv" --apply --rollback --confirm >/dev/null 2>&1 \
  && bad "--apply --rollback ran instead of refusing" \
  || pass "--apply and --rollback together are refused, not silently resolved to a DELETE"

echo
[[ $fail -eq 0 ]] && echo "all good" || echo "FAILURES above"
exit $fail
