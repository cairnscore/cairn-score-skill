#!/usr/bin/env bash
# Remove the cairn hook entries AND the CAIRN_RATER_BACKEND env entry
# from ~/.claude/settings.json — the two pieces install.sh puts there.
#
# Leaves alone:
#   - The skill files in ~/.claude/skills/cairn/ (rm -rf yourself if you also want them gone)
#   - ANTHROPIC_API_KEY in settings.json env (you may use it elsewhere)
#   - ~/.cairn/ (queue, key, log — rm -rf if you want a clean wipe)
#
# Usage:
#   bash uninstall.sh
#
# Honors:
#   SETTINGS  — override settings.json path (for testing); default ~/.claude/settings.json
#   DEST      — override skill location (used to identify which hooks belong to us);
#               default ~/.claude/skills/cairn

set -euo pipefail

command -v python3 >/dev/null || { echo "uninstall.sh: python3 required" >&2; exit 1; }

DEST="${DEST:-$HOME/.claude/skills/cairn}"
SETTINGS="${SETTINGS:-$HOME/.claude/settings.json}"

if [[ ! -f "$SETTINGS" ]]; then
  echo "uninstall.sh: no settings file at $SETTINGS; nothing to remove"
  exit 0
fi

SETTINGS="$SETTINGS" DEST="$DEST" python3 <<'PY'
import json, os

settings_path = os.environ["SETTINGS"]
dest = os.environ["DEST"]

with open(settings_path) as f:
    data = json.load(f)

hook_cmd = os.path.join(dest, "scripts", "cs-hook-postool")
flush_cmd = os.path.join(dest, "scripts", "cs-flush")
ours = {hook_cmd, flush_cmd}

hooks = data.get("hooks", {})

def strip(event):
    if event not in hooks:
        return 0
    removed = 0
    new_entries = []
    for entry in hooks[event]:
        kept_hooks = [h for h in entry.get("hooks", []) if h.get("command") not in ours]
        if len(kept_hooks) < len(entry.get("hooks", [])):
            removed += len(entry.get("hooks", [])) - len(kept_hooks)
        if kept_hooks:
            entry["hooks"] = kept_hooks
            new_entries.append(entry)
    if new_entries:
        hooks[event] = new_entries
    else:
        del hooks[event]
    return removed

total = 0
for event in list(hooks.keys()):
    total += strip(event)

if not hooks:
    data.pop("hooks", None)

# Also strip the CAIRN_RATER_BACKEND env entry install.sh added (it's
# cairn-specific; safe to remove unconditionally). ANTHROPIC_API_KEY
# is NOT in settings.json env per the install design (lives in a separate
# file) so there's nothing to do for it here.
env = data.get("env", {})
env_removed = env.pop("CAIRN_RATER_BACKEND", None)
if not env:
    data.pop("env", None)

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(f"  removed {total} cairn hook entr{'y' if total == 1 else 'ies'} from {settings_path}")
if env_removed is not None:
    print(f"  removed env CAIRN_RATER_BACKEND={env_removed!r}")
PY

echo
echo "Uninstalled hooks. The skill files at $DEST are untouched."
echo "To wipe everything cairn-related:"
echo "  rm -rf $DEST"
echo "  rm -rf \$HOME/.cairn"
echo "  # and remove ANTHROPIC_API_KEY from $SETTINGS env block if you don't use it elsewhere"
