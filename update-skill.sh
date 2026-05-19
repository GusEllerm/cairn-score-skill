#!/usr/bin/env bash
# Pull the latest trustgraph-skill from GitHub and re-run install.sh.
# Idempotent — picks up any new scripts, hook entries, or env vars.
#
# Usage:
#   bash update-skill.sh
#
# Honors:
#   TG_RATER_BACKEND — pass-through to install.sh (skips backend prompt)

set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "update-skill.sh: $REPO_DIR is not a git checkout." >&2
  echo "  Either clone the repo (recommended):" >&2
  echo "    git clone https://github.com/GusEllerm/trustgraph-skill.git ~/.claude/skills/trustgraph" >&2
  echo "  Or re-run install.sh manually after downloading new sources." >&2
  exit 1
fi

cd "$REPO_DIR"

echo "trustgraph update — pulling latest from origin..."
BEFORE=$(git rev-parse --short HEAD)
git pull --ff-only origin main 2>&1 | sed 's/^/  /'
AFTER=$(git rev-parse --short HEAD)

if [[ "$BEFORE" == "$AFTER" ]]; then
  echo
  echo "  already at latest ($AFTER). Re-running install for idempotent settings sync..."
else
  echo
  echo "  updated $BEFORE → $AFTER. Re-running install to sync scripts + hooks..."
fi

echo
bash "$REPO_DIR/install.sh" "$REPO_DIR"
