#!/usr/bin/env bash
# Is PROVISION_GITHUB_TOKEN still able to open a tenant provisioning PR?
#
#   ./check-provision-token.sh          # validity + expiry horizon + Contents:write
#   ./check-provision-token.sh --full   # + the real POST /pulls (opens and closes one PR)
#
# WHY THIS EXISTS. The control plane's `/admin/provision` degrades to a "not configured"
# banner when this token is unset, expired or revoked — it does not error. So the token
# dying takes the funnel down SILENTLY: a customer pays, no proposal is ever opened, and
# nothing anywhere says why. Runbook §0 answered that with "calendar the expiry", and a
# calendar reminder is not a check. This is the check.
#
# It runs ON THE BOX on purpose, and reads the token from the RUNNING sofra container
# first. The question worth answering is not "is the value in git-land still good" but
# "is the value the control plane is actually holding still good" — a `.env` edited
# without recreating the container answers those two differently, and it is the container
# that opens PRs.
#
# WHAT IT CAN AND CANNOT PROVE — read this before trusting a green run:
#
#   PROVEN: the token authenticates (a dead or revoked token gets 401 even on a public
#           repo), the exact date it expires, and — via a real ref create — that it holds
#           `Contents: write` on THIS repo. With --full, also `Pull requests: write`,
#           by walking the same three API calls the control plane walks
#           (POST /git/refs -> PUT /contents -> POST /pulls, see sofra lib/provisioning.ts).
#
#   NOT PROVEN, and not provable this way: that the token is RESTRICTED to this repo.
#           `piwas-21/restaurant-app-deploy` and `piwas-21/restaurant-app-frontend` are
#           both PUBLIC, so any valid token reads either one — measured 2026-08-01, the
#           deploy token answers 200 for the frontend repo and that means nothing.
#           Scope minimisation is enforced when the token is minted; it is not observable
#           afterwards. Do not read a green run as "correctly scoped".
#
#   ALSO NOT PROVEN by the read alone: any write grant at all. For a fine-grained PAT the
#           `permissions` block the API returns describes YOUR role on the repo, not the
#           token's grant. That is exactly why this script performs a write instead of
#           reading one.
#
# Exit codes: 0 every check passed · 1 anything else, including "the check could not run".
# There is deliberately no third state: an unrunnable check must never read as green.
set -uo pipefail

REPO="piwas-21/restaurant-app-deploy"
BASE_BRANCH="develop"
API="https://api.github.com"
# Branch namespace deliberately NOT `provision/<slug>`: a leftover branch there makes the
# next real proposal for that slug fail as "already open" (runbook §0).
BRANCH="token-check/probe-$(date -u +%Y%m%dT%H%M%SZ)-$$"
PROBE_PATH=".token-check-probe"
EXPIRY_FAIL_DAYS=21   # below this, the funnel is one forgotten week from stopping
EXPIRY_WARN_DAYS=60

FULL=0
[ "${1:-}" = "--full" ] && FULL=1

FAILED=0
fail() { printf 'FAIL   %s\n' "$*" >&2; FAILED=1; }
warn() { printf 'WARN   %s\n' "$*"; }
ok()   { printf 'OK     %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }

# ---------------------------------------------------------------- read the token
COMPOSE_DIR="/opt/rumi/deploy"
TOKEN=""
SOURCE=""
if [ -d "$COMPOSE_DIR" ] && command -v docker >/dev/null 2>&1; then
  # `</dev/null` is load-bearing, not tidiness: `exec -T` reads stdin, and this script is
  # normally delivered to the box as `ssh … 'bash -s' < check-provision-token.sh`. Without
  # it, docker swallows the REST OF THIS FILE and the run ends here — silently, exit 0.
  TOKEN="$(cd "$COMPOSE_DIR" && docker compose -f docker-compose.prod.yml exec -T sofra \
             sh -c 'printenv PROVISION_GITHUB_TOKEN' </dev/null 2>/dev/null | tr -d '\r\n')"
  [ -n "$TOKEN" ] && SOURCE="the running sofra container"
fi
if [ -z "$TOKEN" ] && [ -f "$COMPOSE_DIR/.env" ]; then
  TOKEN="$(grep -m1 '^PROVISION_GITHUB_TOKEN=' "$COMPOSE_DIR/.env" 2>/dev/null \
             | cut -d= -f2- | tr -d "\"'" | tr -d '\r\n')"
  [ -n "$TOKEN" ] && SOURCE="$COMPOSE_DIR/.env"
fi

if [ -z "$TOKEN" ]; then
  echo "FAIL   PROVISION_GITHUB_TOKEN not found in the sofra container or $COMPOSE_DIR/.env." >&2
  echo "       Provisioning is down right now, silently. See runbook §0." >&2
  exit 1
fi
ok "token found (${#TOKEN} chars) — read from $SOURCE"
# A token present in .env but absent from the container is its own defect: the control
# plane is running without it, so provisioning is already dead however valid the value is.
if [ "$SOURCE" = "$COMPOSE_DIR/.env" ]; then
  fail "the sofra container is NOT holding PROVISION_GITHUB_TOKEN (it is only in .env) — recreate it: docker compose -f docker-compose.prod.yml up -d sofra"
fi

gh_code() { # method path [body] -> "<http_code>" ; body of response on fd 3 file $RESP
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -o "$RESP" -D "$HDRS" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" --max-time 30 -d "$body" "$API$path" 2>/dev/null || echo "000"
  else
    curl -sS -o "$RESP" -D "$HDRS" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
      --max-time 30 "$API$path" 2>/dev/null || echo "000"
  fi
}

RESP="$(mktemp)"; HDRS="$(mktemp)"
cleanup() { rm -f "$RESP" "$HDRS"; }
trap cleanup EXIT

# ---------------------------------------------------------- 1. does it authenticate
echo "==> 1. authentication"
code="$(gh_code GET "/repos/$REPO")"
case "$code" in
  200) ok "GET /repos/$REPO -> 200: the token authenticates" ;;
  401) fail "GET /repos/$REPO -> 401: the token is expired or revoked. Provisioning is DOWN. Mint a new one — runbook §0."; echo; exit 1 ;;
  404) fail "GET /repos/$REPO -> 404: the token cannot see this repository at all."; echo; exit 1 ;;
  *)   fail "GET /repos/$REPO -> $code (unexpected). Treating as a failure rather than guessing."; echo; exit 1 ;;
esac

# ------------------------------------------------------------- 2. when does it die
echo "==> 2. expiry horizon"
EXP="$(grep -i '^github-authentication-token-expiration:' "$HDRS" \
        | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')"
if [ -z "$EXP" ]; then
  # Silence here is NOT good news. A classic PAT with "no expiration" and a GitHub App
  # token both omit this header, and so would a change of token type nobody announced.
  warn "GitHub returned no expiry header, so this run CANNOT tell you when the token dies."
  info "That means it is not a fine-grained PAT with an expiry — which is itself contrary"
  info "to runbook §0. Re-mint as a fine-grained PAT (Contents + Pull requests, RW, this repo)."
else
  exp_epoch="$(date -u -d "$EXP" +%s 2>/dev/null || echo "")"
  if [ -z "$exp_epoch" ]; then
    warn "could not parse the expiry header ('$EXP') — reporting it raw rather than assuming it is far away"
  else
    days=$(( (exp_epoch - $(date -u +%s)) / 86400 ))
    if   [ "$days" -lt 0 ];                   then fail "the token expired on $EXP"
    elif [ "$days" -lt "$EXPIRY_FAIL_DAYS" ]; then fail "the token expires in $days day(s), on $EXP — re-mint now (runbook §0)"
    elif [ "$days" -lt "$EXPIRY_WARN_DAYS" ]; then warn "the token expires in $days day(s), on $EXP — schedule the re-mint"
    else ok "expires in $days day(s), on $EXP"
    fi
  fi
fi

# ------------------------------------------------------- 3. can it actually WRITE
echo "==> 3. write capability (a real write, not a permissions read)"
code="$(gh_code GET "/repos/$REPO/git/ref/heads/$BASE_BRANCH")"
BASE_SHA="$(sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' "$RESP" | head -1)"
if [ "$code" != "200" ] || [ -z "$BASE_SHA" ]; then
  fail "could not read $BASE_BRANCH's tip (HTTP $code) — cannot attempt the write probe"
  exit 1
fi

created=0
code="$(gh_code POST "/repos/$REPO/git/refs" "{\"ref\":\"refs/heads/$BRANCH\",\"sha\":\"$BASE_SHA\"}")"
case "$code" in
  201) created=1; ok "POST /git/refs -> 201: Contents: write is granted (branch $BRANCH)" ;;
  403) fail "POST /git/refs -> 403: the token does NOT hold Contents: write. It can read but cannot propose. Runbook §0." ;;
  *)   fail "POST /git/refs -> $code (unexpected)" ;;
esac

pr_number=""
if [ "$created" = "1" ] && [ "$FULL" = "1" ]; then
  # The remaining two calls of the control plane's own sequence. Only --full does this,
  # because each run burns a PR number in a repo whose PR numbers are cited all over the
  # runbooks; the weekly run stops at the ref and says so.
  content="$(printf 'token-check probe %s — safe to delete\n' "$BRANCH" | base64 | tr -d '\n')"
  code="$(gh_code PUT "/repos/$REPO/contents/$PROBE_PATH" \
    "{\"message\":\"chore(token-check): write probe\",\"content\":\"$content\",\"branch\":\"$BRANCH\"}")"
  if [ "$code" = "201" ]; then
    ok "PUT /contents -> 201: it can commit"
    code="$(gh_code POST "/repos/$REPO/pulls" \
      "{\"title\":\"[token-check] write probe — close me\",\"head\":\"$BRANCH\",\"base\":\"$BASE_BRANCH\",\"body\":\"Automated probe from check-provision-token.sh --full. Closing itself. Not for merge.\",\"draft\":true}")"
    pr_number="$(sed -n 's/.*"number"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$RESP" | head -1)"
    if [ "$code" = "201" ] && [ -n "$pr_number" ]; then
      ok "POST /pulls -> 201: Pull requests: write is granted (PR #$pr_number) — the full funnel sequence works"
    else
      fail "POST /pulls -> $code: the token can commit but canNOT open a pull request, which is the step /admin/provision ends on"
    fi
  else
    fail "PUT /contents -> $code: the token can create a branch but not commit to it"
  fi
fi

# ------------------------------------------------------------------- 4. clean up
echo "==> 4. cleanup"
if [ -n "$pr_number" ]; then
  code="$(gh_code PATCH "/repos/$REPO/pulls/$pr_number" '{"state":"closed"}')"
  [ "$code" = "200" ] && ok "closed PR #$pr_number" || fail "could not close PR #$pr_number (HTTP $code) — close it by hand"
fi
if [ "$created" = "1" ]; then
  code="$(gh_code DELETE "/repos/$REPO/git/refs/heads/$BRANCH")"
  # Litter is not cosmetic here: an abandoned branch is a diff nobody reviews sitting in a
  # repo whose branches are provisioning proposals.
  [ "$code" = "204" ] && ok "deleted branch $BRANCH" || fail "could NOT delete branch $BRANCH (HTTP $code) — delete it by hand"
fi

# ----------------------------------------------------------- 5. say what this proved
echo
echo "==> what this run did and did not prove"
info "PROVEN: the token authenticates; its expiry date (above); Contents: write on $REPO."
if [ "$FULL" = "1" ]; then
  info "PROVEN: Pull requests: write — the same three calls /admin/provision makes."
else
  info "NOT PROVEN: Pull requests: write. That grant is separate from Contents, and the"
  info "  only proof is opening a PR. Run with --full to prove it (it opens and closes one)."
fi
info "NEVER PROVABLE HERE: that the token is restricted to this repo. Both repos are"
info "  public, so a valid token reads either regardless of its repository selection."

echo
[ "$FAILED" = "0" ] && { echo "==> OK"; exit 0; }
echo "==> FAILED" >&2; exit 1
