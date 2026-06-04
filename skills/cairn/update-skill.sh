#!/usr/bin/env bash
# Pull the latest cairn-score-skill from GitHub and re-run install.sh.
# Idempotent — picks up any new scripts, hook entries, or env vars.
#
# Usage:
#   bash skills/cairn/update-skill.sh                # from the cloned source repo
#   bash /path/to/clone/skills/cairn/update-skill.sh # if installed via clone-elsewhere
#
# Honors:
#   CAIRN_RATER_BACKEND — pass-through to install.sh (skips backend prompt)

set -euo pipefail

# This script lives at <repo>/skills/cairn/update-skill.sh. The git root is two
# levels up. REPO_DIR can be overridden if the layout changes.
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "update-skill.sh: $REPO_DIR is not a git checkout." >&2
  echo "  Clone the repo first (anywhere; not necessarily ~/.claude/skills/):" >&2
  echo "    git clone https://github.com/cairnscore/cairn-score-skill.git ~/code/cairn-score-skill" >&2
  echo "  Then re-run: bash ~/code/cairn-score-skill/skills/cairn/update-skill.sh" >&2
  exit 1
fi

cd "$REPO_DIR"

echo "cairn update — pulling latest from origin..."
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
# install.sh defaults DEST to ~/.claude/skills/cairn; don't override here.
bash "$REPO_DIR/skills/cairn/install.sh"
