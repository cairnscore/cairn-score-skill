#!/usr/bin/env bash
# Coordinate a cairn-score-skill release: bump versions, build artifacts,
# tag, push, create a GitHub Release with the artifacts attached, then print
# the commit SHA so the cairn-marketplace repo can be updated to pin it.
#
# Usage:
#   bash scripts/release.sh <version>          # e.g. 0.2.0
#   bash scripts/release.sh <version> --dry-run
#
# Prereqs:
#   - On `main` branch, working tree clean, up-to-date with origin
#   - `gh` CLI authenticated (repo scope)
#   - `mcpb` (or `npx`) on PATH for the .mcpb build
#   - `zip` on PATH for the cairn-skill.zip build
#
# Honors:
#   DRY_RUN=1 — also enabled by --dry-run flag. Prints commands without
#               mutating anything. Safe for previewing what a release will do.
#
# What it does (in order):
#   1. Sanity: branch=main, tree clean, no uncommitted/staged changes
#   2. Bump `version` in .claude-plugin/plugin.json + mcp-server/manifest.json
#   3. Commit the bump
#   4. Build dist/cairn.mcpb (mcp-server/build-mcpb.sh)
#   5. Build dist/cairn-skill.zip
#   6. Tag v<version>, push commit + tag
#   7. gh release create v<version> --notes-from-tag dist/cairn.mcpb dist/cairn-skill.zip
#   8. Print the commit SHA + the marketplace.json fragment to update

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: bash scripts/release.sh <version> [--dry-run]" >&2
  echo "  e.g. bash scripts/release.sh 0.2.0" >&2
  exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
  echo "release.sh: version '$VERSION' isn't semver-shaped (X.Y.Z or X.Y.Z-tag)" >&2
  exit 1
fi

# --dry-run flag is positional after version.
if [[ "${2:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi
DRY_RUN="${DRY_RUN:-0}"

run() {
  echo "  + $*"
  if [[ "$DRY_RUN" != "1" ]]; then
    "$@"
  fi
}

echo "cairn release v$VERSION (dry-run=$DRY_RUN)"
echo

# 1. Sanity checks.
echo "==> sanity checks"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" ]]; then
  echo "release.sh: must be on main (currently on '$BRANCH'). Merge first." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "release.sh: working tree not clean. Commit or stash first." >&2
  git status --short >&2
  exit 1
fi
git fetch origin --quiet
BEHIND=$(git rev-list --count HEAD..origin/main)
if [[ "$BEHIND" -gt 0 ]]; then
  echo "release.sh: local main is $BEHIND commits behind origin. Pull first." >&2
  exit 1
fi

for cmd in python3 zip gh git; do
  command -v "$cmd" >/dev/null || { echo "release.sh: '$cmd' not on PATH" >&2; exit 1; }
done
if ! command -v mcpb >/dev/null && ! command -v npx >/dev/null; then
  echo "release.sh: need 'mcpb' or 'npx' on PATH for .mcpb build" >&2
  exit 1
fi

# Tag-already-exists check.
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "release.sh: tag v$VERSION already exists. Pick a different version." >&2
  exit 1
fi

echo "  ✓ on main, clean tree, up-to-date with origin"
echo

# 2. Bump versions.
echo "==> bumping version → $VERSION"
for f in .claude-plugin/plugin.json mcp-server/manifest.json; do
  if [[ ! -f "$f" ]]; then
    echo "release.sh: missing $f" >&2
    exit 1
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  + would update version in $f"
  else
    python3 -c "
import json
with open('$f') as fh: data = json.load(fh)
old = data.get('version')
data['version'] = '$VERSION'
with open('$f', 'w') as fh: json.dump(data, fh, indent=2); fh.write('\n')
print(f'  ✓ $f: {old} → $VERSION')
"
  fi
done
echo

# 3. Commit the bump.
echo "==> committing version bump"
run git add .claude-plugin/plugin.json mcp-server/manifest.json
run git commit -m "Release v$VERSION"
echo

# 4. Build .mcpb.
echo "==> building dist/cairn.mcpb"
run bash mcp-server/build-mcpb.sh
echo

# 5. Build cairn-skill.zip.
echo "==> building dist/cairn-skill.zip"
if [[ "$DRY_RUN" != "1" ]]; then
  rm -f dist/cairn-skill.zip
  ( cd skills/cairn && \
    zip -r ../../dist/cairn-skill.zip \
      SKILL.md \
      references/rubric.md \
      references/examples.md \
      references/queries.md \
      references/scoring-model.md )
  size=$(du -h dist/cairn-skill.zip | cut -f1)
  echo "  ✓ built dist/cairn-skill.zip ($size)"
else
  echo "  + would build dist/cairn-skill.zip"
fi
echo

# 6. Tag + push.
echo "==> tagging v$VERSION and pushing"
run git tag -a "v$VERSION" -m "Release v$VERSION"
run git push origin main
run git push origin "v$VERSION"
echo

# 7. GitHub Release.
echo "==> creating GitHub Release"
RELEASE_NOTES="Release v$VERSION

Artifacts:
- \`cairn.mcpb\` — Claude Desktop one-click install
- \`cairn-skill.zip\` — claude.ai web skill upload

To install the Claude Code plugin at this version, add the cairn
marketplace and pin to the commit below."
run gh release create "v$VERSION" \
  dist/cairn.mcpb \
  dist/cairn-skill.zip \
  --title "v$VERSION" \
  --notes "$RELEASE_NOTES"
echo

# 8. Print the marketplace pin fragment.
SHA=$(git rev-parse HEAD)
echo "==> done"
echo
echo "Update cairnscore/cairn-marketplace with this SHA pin:"
echo
cat <<EOF
    "source": {
      "source": "url",
      "url": "https://github.com/cairnscore/cairn-score-skill.git",
      "sha": "$SHA"
    }
EOF
echo
echo "Or run from a cairn-marketplace clone:"
echo "  python3 -c \"import json; p='.claude-plugin/marketplace.json'; d=json.load(open(p)); d['plugins'][0]['source']['sha']='$SHA'; json.dump(d, open(p,'w'), indent=2); open(p,'a').write('\\n')\""
echo "  git commit -am 'Bump cairn to v$VERSION ($SHA)' && git push"
