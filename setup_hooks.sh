#!/usr/bin/env bash
# Install the deploy repo's git hooks.
#
#   - pre-commit (commit stage): no-commit-to-branch + safety checks
#     (.pre-commit-config.yaml). Blocks a direct commit to `main`.
#   - pre-push: the workspace REVIEW GATE symlink. It is installed + healed by
#     the workspace `scripts/review-gate/install.sh`, NOT here. We deliberately
#     do NOT run `pre-commit install --hook-type pre-push`, because that
#     overwrites the review-gate pre-push symlink (memory:
#     review-gate-precommit-clobber). Commit-stage install leaves pre-push alone.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v pre-commit >/dev/null 2>&1; then
  echo "ERROR: pre-commit not installed. Install it (e.g. 'pipx install pre-commit' or 'brew install pre-commit'), then re-run." >&2
  exit 1
fi

pre-commit install # commit-stage hooks only — does not touch .git/hooks/pre-push

echo "✓ pre-commit (commit-stage) installed — direct commits to main/master are now blocked."
echo "  (the pre-push review gate is managed by the workspace review-gate installer, untouched here.)"
