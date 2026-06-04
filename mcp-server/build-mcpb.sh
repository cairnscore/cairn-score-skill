#!/usr/bin/env bash
# Build the cairn MCP as a .mcpb bundle for one-click Desktop install.
#
# Usage:
#   cd mcp-server && bash build-mcpb.sh
#
# Output: ../dist/cairn.mcpb (gitignored — built per release).
#
# Prereqs:
#   - npm + npx on PATH (Node ≥ 18). Either `mcpb` already installed
#     globally (`npm i -g @anthropic-ai/mcpb`) OR npx, which will fetch
#     the package transiently — no global install needed.
#   - A sibling skills/cairn/ directory containing scripts/mint-key.sh
#
# What it does:
#   1. Sanity-checks the bundled mint-key.sh source (since the MCP shells out
#      to it for the read-or-mint-and-persist critical section).
#   2. Copies skills/cairn/scripts/mint-key.sh into mcp-server/bundled/ so the
#      manifest's CAIRN_MINT_SCRIPT can point at the bundle-local
#      path (${__dirname}/bundled/mint-key.sh) — no external dep at runtime.
#   3. Runs `mcpb pack .` which zips per .mcpbignore and writes the artifact.
#
# Distribution: ship dist/cairn.mcpb via GitHub Releases (or the
# cairn project's own download page). Users double-click in Claude
# Desktop → auto-install → the cairn MCP appears with all 10 tools and
# the proactive prompt registered.

set -euo pipefail
cd "$(dirname "$0")"

# Pick the cheapest available mcpb invocation: global if present, else npx.
if command -v mcpb >/dev/null; then
  MCPB=(mcpb)
elif command -v npx >/dev/null; then
  echo "  (using npx; install globally with 'npm i -g @anthropic-ai/mcpb' to skip the cold-cache fetch)"
  MCPB=(npx -y --package @anthropic-ai/mcpb mcpb)
else
  echo "build-mcpb.sh: neither 'mcpb' nor 'npx' on PATH" >&2
  echo "  install Node ≥ 18 (https://nodejs.org), then either:" >&2
  echo "    npm i -g @anthropic-ai/mcpb     # global install" >&2
  echo "    # or just rely on the npx route once Node is installed" >&2
  exit 127
fi

# 1. Validate the sibling skill checkout
MINT_SRC="../skills/cairn/scripts/mint-key.sh"
if [[ ! -f "$MINT_SRC" ]]; then
  echo "build-mcpb.sh: $MINT_SRC missing — can't bundle the mint script" >&2
  echo "  is the sibling skills/cairn/ directory present? (this script assumes a" >&2
  echo "  same-repo layout; if you've split repos, adjust MINT_SRC)" >&2
  exit 1
fi

# 2. Stage bundled assets
mkdir -p bundled
cp "$MINT_SRC" bundled/mint-key.sh
chmod +x bundled/mint-key.sh
echo "  ✓ bundled mint-key.sh (from $MINT_SRC)"

# 3. Pack
OUT_DIR="../dist"
OUT_FILE="$OUT_DIR/cairn.mcpb"
mkdir -p "$OUT_DIR"
rm -f "$OUT_FILE"
"${MCPB[@]}" pack . "$OUT_FILE"

# 4. Report
size=$(du -h "$OUT_FILE" | cut -f1)
echo
echo "  ✓ built $OUT_FILE ($size)"
echo
echo "  Install: drag $OUT_FILE onto Claude Desktop, or open it from Finder."
echo "  Inspect manifest: ${MCPB[*]} info $OUT_FILE"
