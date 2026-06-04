#!/usr/bin/env bash
# Resolve a Cairn API key, minting if absent. Holds the per-key-file lock
# across the critical section so concurrent callers see exactly one mint.
#
# Usage:
#   mint-key.sh                                 # ephemeral default identity,
#                                               #   prints the key on stdout
#   mint-key.sh agent://your-org/your-agent     # same, with stable identity
#   mint-key.sh --write                         # persist silently, no stdout
#   mint-key.sh --write agent://your-org/...    # --write + identity (any order)
#   mint-key.sh --remint                        # skip the cached-key check;
#                                               #   always POST /v1/keys and
#                                               #   overwrite. For 401-recovery
#                                               #   when the persisted key is
#                                               #   known revoked.
#
# Env:
#   CAIRN_KEY_FILE   default: $HOME/.cairn/keys/<host>.key
#                         (URL-scoped — derived from CAIRN_BASE_URL's host)
#   CAIRN_BASE_URL   default: https://api.cairnscore.ai
#
# What it does:
#   1. Take fcntl.flock(LOCK_EX) on ${CAIRN_KEY_FILE}.lock (via
#      python3 -c since flock(1) isn't on macOS).
#   2. Double-check: if the key file already exists and is non-empty, print
#      it (unless --write) and exit. This makes concurrent callers a no-op.
#   3. Otherwise POST /v1/keys with reviewer_external_id, parse the key, and
#      atomically write it: umask 077 + mktemp in the same dir + chmod 600 +
#      mv -f. The dest file is never observed at any mode looser than 600.
#   4. Print the key on stdout (unless --write).
#
# Concurrency: the lock attaches to the open file description for $LOCK. fd 9
# is held by this shell across the critical section; <&9 dups it to the
# child python3 so it can take the lock on the same OFD. On normal exit the
# `trap 'exec 9>&-' EXIT` closes fd 9 and releases the lock; on SIGKILL the
# kernel closes fd 9 when the process dies, releasing the lock automatically.

set -euo pipefail
trap 'exec 9>&-' EXIT

command -v python3 >/dev/null || { echo "mint-key.sh: python3 required" >&2; exit 127; }
command -v curl >/dev/null || { echo "mint-key.sh: curl required" >&2; exit 127; }

: "${CAIRN_BASE_URL:=https://api.cairnscore.ai}"

# Key file default is URL-scoped so a key minted against one host is never
# silently reused against another (DNS-takeover / env-override safety).
# Explicit CAIRN_KEY_FILE override bypasses the scheme entirely.
if [[ -z "${CAIRN_KEY_FILE:-}" ]]; then
  HOST=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.urlparse(sys.argv[1]).hostname or "default")' "$CAIRN_BASE_URL")
  CAIRN_KEY_FILE="$HOME/.cairn/keys/${HOST}.key"
fi
LOCK="${CAIRN_KEY_FILE}.lock"

mkdir -p "$(dirname "$CAIRN_KEY_FILE")"
chmod 700 "$(dirname "$CAIRN_KEY_FILE")"

# Arg parsing: --write / --remint may appear in any position; the remaining
# arg (if any) is the reviewer identity. Last positional wins if multiple.
WRITE_ONLY=0
FORCE_REMINT=0
IDENTITY=""
for arg in "$@"; do
  case "$arg" in
    --write)  WRITE_ONLY=1 ;;
    --remint) FORCE_REMINT=1 ;;
    *)        IDENTITY="$arg" ;;
  esac
done
: "${IDENTITY:=agent://anon/$(python3 -c 'import uuid; print(uuid.uuid4())')}"

# Take the lock. fd 9 is held by THIS shell; the python3 invocation takes
# LOCK_EX on the same OFD via <&9. fd 9 stays open until EXIT trap fires.
exec 9>"$LOCK"
python3 -c 'import fcntl,sys; fcntl.flock(sys.stdin.fileno(), fcntl.LOCK_EX)' <&9

# Double-check after lock acquire: another process may have minted while we
# were waiting for the lock. --remint bypasses the cache (overwrites the
# stored key) so the 401-recovery path in server.py actually gets a fresh
# key — without --remint, a revoked key would just be re-emitted from the
# file and we'd loop on 401.
if [[ "$FORCE_REMINT" -ne 1 ]] && [[ -s "$CAIRN_KEY_FILE" ]]; then
  [[ "$WRITE_ONLY" -eq 1 ]] || cat "$CAIRN_KEY_FILE"
  exit 0
fi

# Mint.
PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"reviewer_external_id": sys.argv[1]}))' "$IDENTITY")
RESP=$(curl -sS --fail -X POST "$CAIRN_BASE_URL/v1/keys" \
  -H "Content-Type: application/json" -d "$PAYLOAD")
KEY=$(python3 -c '
import sys, json
try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    sys.exit("mint-key.sh: server response was not valid JSON")
if not isinstance(data, dict):
    sys.exit("mint-key.sh: unexpected mint response (non-object)")
key = data.get("api_key")
if not isinstance(key, str) or not key:
    err = data.get("error") if isinstance(data, dict) else None
    code = err.get("code") if isinstance(err, dict) else "unknown"
    sys.exit(f"mint-key.sh: mint failed (code={code})")
print(key)
' <<< "$RESP")

# Atomic persist: tempfile in the same dir (same filesystem → mv is rename),
# chmod 600 before write so it's never observed at default umask perms,
# then mv -f preserves the mode.
umask 077
tmp=$(mktemp "${CAIRN_KEY_FILE}.XXXXXX")
chmod 600 "$tmp"
printf '%s\n' "$KEY" > "$tmp"
mv -f "$tmp" "$CAIRN_KEY_FILE"

[[ "$WRITE_ONLY" -eq 1 ]] || echo "$KEY"
