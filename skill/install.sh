#!/usr/bin/env bash
# Install the trustgraph skill into ~/.claude/skills/trustgraph/ and register
# Claude Code hooks (PostToolUse, PostToolUseFailure, Stop) in
# ~/.claude/settings.json.
#
# Two rater backends, picked at install (or per-session via TG_RATER_BACKEND):
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
#   TG_RATER_BACKEND=api bash install.sh  # skip backend prompt
#
# Honors:
#   ANTHROPIC_API_KEY    — used if set in env; otherwise install may prompt for it
#   TG_RATER_BACKEND     — "api" | "claude-cli" (if unset, install asks)
#   SETTINGS             — override settings.json path (for testing)

set -euo pipefail

for cmd in python3 curl bash; do
  command -v "$cmd" >/dev/null || { echo "install.sh: required tool '$cmd' not found in PATH" >&2; exit 1; }
done

DEST="${1:-$HOME/.claude/skills/trustgraph}"
SRC="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="${SETTINGS:-$HOME/.claude/settings.json}"

echo "trustgraph installer"
echo "  source:   $SRC"
echo "  dest:     $DEST"
echo "  settings: $SETTINGS"
echo

# Copy skill files into place (unless source == dest, e.g. re-running in place).
# Skill content (SKILL.md, references/, scripts/, installer scripts) lives
# alongside this script in skill/. README.md and LICENSE live one level up at
# the repo root; copy them in too if present so the installed dir is browsable.
if [[ "$SRC" != "$DEST" ]]; then
  mkdir -p "$DEST"
  for item in SKILL.md references scripts install.sh uninstall.sh update-skill.sh; do
    if [[ -e "$SRC/$item" ]]; then
      cp -R "$SRC/$item" "$DEST/"
    fi
  done
  for item in README.md LICENSE; do
    if [[ -e "$SRC/../$item" ]]; then
      cp "$SRC/../$item" "$DEST/"
    fi
  done
  echo "  copied skill files → $DEST"
fi

chmod +x "$DEST/scripts/"* "$DEST/install.sh" "$DEST/uninstall.sh" "$DEST/update-skill.sh" 2>/dev/null || true
echo "  scripts marked executable"
echo

# Resolve TG_RATER_BACKEND: env → existing key file inference → interactive prompt.
KEY_FILE="${TG_ANTHROPIC_KEY_FILE:-$HOME/.trustgraph/anthropic-key}"
BACKEND="${TG_RATER_BACKEND:-}"

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
# — only the trustgraph scripts read TG_RATER_BACKEND). The Anthropic key
# itself does NOT live here (would cause Claude Code auth conflict).
env = data.setdefault("env", {})
if env.get("TG_RATER_BACKEND") != backend:
    env["TG_RATER_BACKEND"] = backend
    print(f"  TG_RATER_BACKEND={backend} → settings.json env")
else:
    print(f"  TG_RATER_BACKEND already {backend} in settings.json env")

hooks = data.setdefault("hooks", {})
hook_cmd = os.path.join(dest, "scripts", "tg-hook-postool")
flush_cmd = os.path.join(dest, "scripts", "tg-flush")

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

stop_entries = hooks.setdefault("Stop", [])
if not already_has(stop_entries, flush_cmd):
    stop_entries.append({
        "hooks": [{
            "type": "command",
            "command": flush_cmd,
            "timeout": 30,
        }],
    })
    print(f"  registered Stop hook → {flush_cmd}")
else:
    print("  Stop hook already registered (skipping)")

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

echo
echo "Installed."
echo
echo "Verify:"
echo "  $DEST/scripts/tg-score data_source https://example.com"
echo "  ↳ should print one line like '0.50 0.00 null' (uninformed prior for an untouched entity)"
echo
echo "Hooks fire on NEW Claude Code sessions. To enable in the current session, run /hooks"
echo "in Claude Code (or just start a fresh session). Test by asking Claude to use any MCP"
echo "tool or fetch a URL — the rating happens silently in the background."
echo
echo "Uninstall: bash $DEST/uninstall.sh"
