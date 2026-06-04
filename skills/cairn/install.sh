#!/usr/bin/env bash
# Install the cairn skill into ~/.claude/skills/cairn/ and register
# Claude Code hooks (PostToolUse, PostToolUseFailure, Stop) in
# ~/.claude/settings.json.
#
# Two rater backends, picked at install (or per-session via CAIRN_RATER_BACKEND):
#   "api"        — direct POST to api.anthropic.com (needs ANTHROPIC_API_KEY).
#                  Cheap (~$0.0003/rating cached), fast (~2s). Best for heavy use.
#   "claude-cli" — shell out to `claude -p`. Uses Claude Code's own auth (works
#                  with claude.ai subscription). No API key needed.
#                  More expensive (~$0.02-0.07/rating, subscription-billed), slower (~20s).
#                  Best when you don't want to set up a separate API key.
#
# Idempotent: safe to re-run. Existing settings are preserved.
#
# Usage:
#   bash install.sh                       # interactive: pick backend
#   bash install.sh /custom/path          # custom install dir
#   bash install.sh --desktop             # also register the MCP in Claude
#                                         #   Desktop's config (uses absolute
#                                         #   uv path + clone-local paths;
#                                         #   for one-click install instead,
#                                         #   build the .mcpb — see README)
#   CAIRN_RATER_BACKEND=api bash install.sh  # skip backend prompt
#
# Honors:
#   ANTHROPIC_API_KEY    — used if set in env; otherwise install may prompt for it
#   CAIRN_RATER_BACKEND     — "api" | "claude-cli" (if unset, install asks)
#   SETTINGS             — override settings.json path (for testing)
#   DESKTOP_CONFIG       — override Claude Desktop config path (for testing)

set -euo pipefail

for cmd in python3 curl bash; do
  command -v "$cmd" >/dev/null || { echo "install.sh: required tool '$cmd' not found in PATH" >&2; exit 1; }
done

# Flag parsing — accept --desktop in any position, plus one positional DEST.
DESKTOP=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --desktop) DESKTOP=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --*)
      echo "install.sh: unknown flag '$1' (try --help)" >&2
      exit 1
      ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

DEST="${1:-$HOME/.claude/skills/cairn}"
SRC="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="${SETTINGS:-$HOME/.claude/settings.json}"

echo "cairn installer"
echo "  source:   $SRC"
echo "  dest:     $DEST"
echo "  settings: $SETTINGS"
echo

# Detect an existing cairn plugin install — the plugin and install.sh both
# register hooks, and Claude Code does NOT dedupe by command path. Running both
# means every tool call gets rated twice (~2x rater cost + duplicate queue
# events). Warn loudly, but proceed if the user insists (some testing flows
# want both side-by-side).
PLUGIN_DIRS=("$HOME/.claude/plugins" "$HOME/.config/claude/plugins")
for pdir in "${PLUGIN_DIRS[@]}"; do
  if [[ -d "$pdir" ]] && grep -rl '"name"[[:space:]]*:[[:space:]]*"cairn"' "$pdir" --include='plugin.json' 2>/dev/null | grep -q .; then
    echo "install.sh: ⚠  detected a Claude Code plugin install of cairn under $pdir"
    echo "  Running install.sh in addition to the plugin will register the"
    echo "  hooks TWICE — every tool call will be rated twice, doubling rater"
    echo "  cost and queueing duplicate ratings."
    echo
    echo "  Recommended: uninstall the plugin OR don't run this installer."
    echo "    /plugin uninstall cairn       # in Claude Code"
    echo
    if [[ -z "${CAIRN_INSTALL_FORCE:-}" ]]; then
      printf "  Continue anyway? [y/N]: "
      read -r ANSWER
      case "$ANSWER" in
        y|Y|yes) echo "  proceeding (you asked for it)…"; echo ;;
        *)       echo "  aborting. Run with CAIRN_INSTALL_FORCE=1 to skip this prompt." >&2; exit 1 ;;
      esac
    else
      echo "  CAIRN_INSTALL_FORCE=1 set — proceeding."
      echo
    fi
    break
  fi
done

# Copy skill files into place (unless source == dest, e.g. re-running in place).
# Skill content (SKILL.md, references/, scripts/, installer scripts) lives
# alongside this script in skills/cairn/. README.md and LICENSE live two levels
# up at the repo root; copy them in too if present so the installed dir is browsable.
if [[ "$SRC" != "$DEST" ]]; then
  mkdir -p "$DEST"
  for item in SKILL.md references scripts install.sh uninstall.sh update-skill.sh; do
    if [[ -e "$SRC/$item" ]]; then
      cp -R "$SRC/$item" "$DEST/"
    fi
  done
  for item in README.md LICENSE; do
    if [[ -e "$SRC/../../$item" ]]; then
      cp "$SRC/../../$item" "$DEST/"
    fi
  done
  echo "  copied skill files → $DEST"
fi

chmod +x "$DEST/scripts/"* "$DEST/install.sh" "$DEST/uninstall.sh" "$DEST/update-skill.sh" 2>/dev/null || true
echo "  scripts marked executable"
echo

# Resolve CAIRN_RATER_BACKEND: env → existing key file inference → interactive prompt.
KEY_FILE="${CAIRN_ANTHROPIC_KEY_FILE:-$HOME/.cairn/anthropic-key}"
BACKEND="${CAIRN_RATER_BACKEND:-}"

if [[ -z "$BACKEND" ]]; then
  echo "Pick a rater backend:"
  echo "  1) api        — direct Anthropic API, needs an API key from console.anthropic.com"
  echo "                  ~\$0.0003/rating (cached), fast (~2s). Best for heavy use."
  echo "  2) claude-cli — uses Claude Code's own auth (claude.ai subscription)."
  echo "                  ~\$0.02–0.07/rating (subscription-billed), slower (~20s)."
  echo "                  No API key needed; recommended if you don't have one."
  if ! command -v claude >/dev/null; then
    echo
    echo "  (note: 'claude' CLI is not on PATH; option 2 will not work in this environment)"
  fi
  printf "Choice [1/2]: "
  read -r CHOICE
  case "$CHOICE" in
    1|api)        BACKEND="api" ;;
    2|claude-cli) BACKEND="claude-cli" ;;
    *)            echo "install.sh: invalid choice '$CHOICE'; aborting" >&2; exit 1 ;;
  esac
fi

echo "  backend: $BACKEND"
echo

# Backend-specific setup.
case "$BACKEND" in
  api)
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
    if [[ -z "$ANTHROPIC_API_KEY" ]]; then
      if [[ -s "$KEY_FILE" ]]; then
        echo "  ANTHROPIC_API_KEY already saved at $KEY_FILE"
        ANTHROPIC_API_KEY=$(<"$KEY_FILE")
      else
        printf "Anthropic API key (input hidden; saved to %s, mode 600): " "$KEY_FILE" >&2
        IFS= read -rs ANTHROPIC_API_KEY
        echo
        if [[ -z "$ANTHROPIC_API_KEY" ]]; then
          echo "install.sh: no key entered; aborting (you can re-run later)" >&2
          exit 1
        fi
      fi
    fi
    mkdir -p "$(dirname "$KEY_FILE")"
    chmod 700 "$(dirname "$KEY_FILE")"
    # Atomic write: never observable at default umask perms, never partial
    # under a concurrent reader. Same pattern as mint-key.sh.
    umask 077
    tmp=$(mktemp "${KEY_FILE}.XXXXXX")
    chmod 600 "$tmp"
    printf '%s\n' "$ANTHROPIC_API_KEY" > "$tmp"
    mv -f "$tmp" "$KEY_FILE"
    echo "  key persisted to $KEY_FILE"
    ;;
  claude-cli)
    if ! command -v claude >/dev/null; then
      echo "install.sh: 'claude' CLI not on PATH but claude-cli backend selected. Install Claude Code first." >&2
      exit 1
    fi
    echo "  using Claude Code's own auth — no API key needed"
    echo "  (make sure you're logged in: 'claude /login' if not already)"
    ;;
  *)
    echo "install.sh: unknown backend '$BACKEND' (want api|claude-cli)" >&2
    exit 1
    ;;
esac
echo

# Merge hooks into settings.json. Also persist the backend choice as an env var
# in settings.json so it propagates to hook invocations.
SETTINGS="$SETTINGS" DEST="$DEST" BACKEND="$BACKEND" python3 <<'PY'
import json, os, sys

settings_path = os.environ["SETTINGS"]
dest = os.environ["DEST"]
backend = os.environ["BACKEND"]

os.makedirs(os.path.dirname(settings_path) or ".", exist_ok=True)
data = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        data = json.load(f)

# Persist the backend choice via settings.json env (this is safe to put in env
# — only the cairn scripts read CAIRN_RATER_BACKEND). The Anthropic key
# itself does NOT live here (would cause Claude Code auth conflict).
env = data.setdefault("env", {})
if env.get("CAIRN_RATER_BACKEND") != backend:
    env["CAIRN_RATER_BACKEND"] = backend
    print(f"  CAIRN_RATER_BACKEND={backend} → settings.json env")
else:
    print(f"  CAIRN_RATER_BACKEND already {backend} in settings.json env")

hooks = data.setdefault("hooks", {})
hook_cmd = os.path.join(dest, "scripts", "cs-hook-postool")
flush_cmd = os.path.join(dest, "scripts", "cs-flush")

def already_has(entries, cmd):
    return any(
        any(h.get("command") == cmd for h in entry.get("hooks", []))
        for entry in entries
    )

def add_postool(event):
    entries = hooks.setdefault(event, [])
    if not already_has(entries, hook_cmd):
        entries.append({
            "matcher": "WebFetch|WebSearch|Bash|mcp__.*",
            "hooks": [{
                "type": "command",
                "command": hook_cmd,
                "async": True,
                "timeout": 60,
            }],
        })
        print(f"  registered {event} hook → {hook_cmd}")
    else:
        print(f"  {event} hook already registered (skipping)")

add_postool("PostToolUse")
add_postool("PostToolUseFailure")

def add_flush_hook(event):
    entries = hooks.setdefault(event, [])
    if not already_has(entries, flush_cmd):
        entries.append({
            "hooks": [{
                "type": "command",
                "command": flush_cmd,
                "timeout": 30,
            }],
        })
        print(f"  registered {event} hook → {flush_cmd}")
    else:
        print(f"  {event} hook already registered (skipping)")

# Stop fires per-turn (when Claude finishes responding) — bounds queue size
# in long sessions. SessionEnd fires on /exit, /clear, logout, etc. — catches
# events queued by the async rater AFTER the last per-turn Stop. Both are
# needed: a single rater dispatch can finish AFTER Stop has already fired,
# leaving the event stranded until SessionEnd drains it on session teardown.
add_flush_hook("Stop")
add_flush_hook("SessionEnd")

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

echo
echo "Installed (Claude Code skill)."

# Optional Desktop MCP registration (--desktop flag).
# Writes the cairn entry into Claude Desktop's mcpServers config, using
# the absolute uv path (Desktop's launchd env lacks ~/.local/bin) and the
# installed mint-key.sh location (stable, lives at DEST). Doesn't install the
# Code skill twice — that already ran above.
if [[ "$DESKTOP" -eq 1 ]]; then
  echo
  echo "--- Desktop MCP registration (--desktop) ---"

  MCP_DIR="$SRC/../../mcp-server"
  if [[ ! -f "$MCP_DIR/server.py" ]]; then
    echo "install.sh: --desktop requires running from the cloned repo where" >&2
    echo "  $MCP_DIR/server.py exists. Re-runs from the installed location" >&2
    echo "  can't find the mcp-server tree; clone the repo and re-run." >&2
    exit 1
  fi
  MCP_DIR="$(cd "$MCP_DIR" && pwd)"

  UV_PATH=$(command -v uv || echo "")
  if [[ -z "$UV_PATH" ]]; then
    echo "install.sh: 'uv' not on PATH. Install with:" >&2
    echo "  curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
    exit 1
  fi

  if [[ -z "${DESKTOP_CONFIG:-}" ]]; then
    case "$OSTYPE" in
      darwin*) DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
      linux*)  DESKTOP_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude_desktop_config.json" ;;
      *)
        echo "install.sh: --desktop auto-detect doesn't handle OSTYPE='$OSTYPE'." >&2
        echo "  Set DESKTOP_CONFIG=/path/to/claude_desktop_config.json explicitly." >&2
        exit 1
        ;;
    esac
  fi

  mkdir -p "$(dirname "$DESKTOP_CONFIG")"
  [[ -f "$DESKTOP_CONFIG" ]] || echo '{}' > "$DESKTOP_CONFIG"

  BAK="$DESKTOP_CONFIG.bak.install-$(date +%Y%m%d-%H%M%S)"
  cp "$DESKTOP_CONFIG" "$BAK"
  echo "  backup → $BAK"

  MCP_DIR="$MCP_DIR" UV_PATH="$UV_PATH" DEST="$DEST" DESKTOP_CONFIG="$DESKTOP_CONFIG" python3 <<'PY'
import json, os
path = os.environ["DESKTOP_CONFIG"]
with open(path) as f:
    cfg = json.load(f)
mint_script = os.path.join(os.environ["DEST"], "scripts", "mint-key.sh")
cfg.setdefault("mcpServers", {})["cairn"] = {
    "command": os.environ["UV_PATH"],
    "args": [
        "--directory", os.environ["MCP_DIR"],
        "run", "--locked",
        "python", "server.py",
    ],
    "env": {
        "CAIRN_MINT_SCRIPT": mint_script,
        "PYTHONWARNINGS": "ignore",
    },
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"  registered → mcpServers.cairn")
print(f"    command:     {os.environ['UV_PATH']}")
print(f"    mcp-server:  {os.environ['MCP_DIR']}")
print(f"    mint-script: {mint_script}")
PY

  echo
  echo "  ⚠  Restart Claude Desktop (Cmd+Q on macOS, not just close-window) to load the MCP."
  echo "  Verify in Desktop's compose UI — 'cairn' should appear with 10 tools."
  echo
  echo "  One-click alternative: drop the .mcpb instead of editing JSON:"
  echo "    cd '$MCP_DIR' && bash build-mcpb.sh   # builds dist/cairn.mcpb"
  echo "    open ../dist/cairn.mcpb           # Desktop installs from one file"
fi

echo
echo "Verify (Code skill):"
echo "  $DEST/scripts/cs-score data_source https://example.com"
echo "  ↳ should print one line like '0.50 0.00 null' (uninformed prior for an untouched entity)"
echo
echo "Hooks fire on NEW Claude Code sessions. To enable in the current session, run /hooks"
echo "in Claude Code (or just start a fresh session). Test by asking Claude to use any MCP"
echo "tool or fetch a URL — the rating happens silently in the background."
echo
echo "Diagnostics: bash $DEST/scripts/cs-doctor"
echo "Uninstall:   bash $DEST/uninstall.sh"
