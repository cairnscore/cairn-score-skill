#!/usr/bin/env bash
# Resolve a TrustGraph API key, minting if absent. Holds the per-key-file lock
# across the critical section so concurrent callers see exactly one mint.
#
# Usage:
#   mint-key.sh                                 # ephemeral default identity,
#                                               #   prints the key on stdout
#   mint-key.sh agent://your-org/your-agent     # same, with stable identity
#   mint-key.sh --write                         # persist silently, no stdout
#   mint-key.sh --write agent://your-org/...    # --write + identity (any order)
#
# Env:
#   TRUSTGRAPH_KEY_FILE   default: $HOME/.trustgraph/api-key
#   TRUSTGRAPH_BASE_URL   default: https://mep39camvm.us-east-1.awsapprunner.com
#
# What it does:
#   1. Take fcntl.flock(LOCK_EX) on ${TRUSTGRAPH_KEY_FILE}.lock (via
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

: "${TRUSTGRAPH_KEY_FILE:=$HOME/.trustgraph/api-key}"
: "${TRUSTGRAPH_BASE_URL:=https://mep39camvm.us-east-1.awsapprunner.com}"
LOCK="${TRUSTGRAPH_KEY_FILE}.lock"

mkdir -p "$(dirname "$TRUSTGRAPH_KEY_FILE")"
chmod 700 "$(dirname "$TRUSTGRAPH_KEY_FILE")"

# Arg parsing: --write may appear in any position; the remaining arg (if any)
# is the reviewer identity. Last positional wins if multiple are given.
WRITE_ONLY=0
IDENTITY=""
for arg in "$@"; do
  case "$arg" in
    --write) WRITE_ONLY=1 ;;
    *) IDENTITY="$arg" ;;
  esac
done
: "${IDENTITY:=agent://anon/$(python3 -c 'import uuid; print(uuid.uuid4())')}"

# Take the lock. fd 9 is held by THIS shell; the python3 invocation takes
# LOCK_EX on the same OFD via <&9. fd 9 stays open until EXIT trap fires.
exec 9>"$LOCK"
python3 -c 'import fcntl,sys; fcntl.flock(sys.stdin.fileno(), fcntl.LOCK_EX)' <&9

# Double-check after lock acquire: another process may have minted while we
# were waiting for the lock.
if [[ -s "$TRUSTGRAPH_KEY_FILE" ]]; then
  [[ "$WRITE_ONLY" -eq 1 ]] || cat "$TRUSTGRAPH_KEY_FILE"
  exit 0
fi

# Mint.
PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"reviewer_external_id": sys.argv[1]}))' "$IDENTITY")
RESP=$(curl -sS --fail -X POST "$TRUSTGRAPH_BASE_URL/v1/keys" \
  -H "Content-Type: application/json" -d "$PAYLOAD")
KEY=$(python3 -c '
import sys, json
data = json.loads(sys.stdin.read())
if "api_key" not in data:
    sys.exit("mint-key.sh: " + json.dumps(data))
print(data["api_key"])
' <<< "$RESP")

# Atomic persist: tempfile in the same dir (same filesystem → mv is rename),
# chmod 600 before write so it's never observed at default umask perms,
# then mv -f preserves the mode.
umask 077
tmp=$(mktemp "${TRUSTGRAPH_KEY_FILE}.XXXXXX")
chmod 600 "$tmp"
printf '%s\n' "$KEY" > "$tmp"
mv -f "$tmp" "$TRUSTGRAPH_KEY_FILE"

[[ "$WRITE_ONLY" -eq 1 ]] || echo "$KEY"
