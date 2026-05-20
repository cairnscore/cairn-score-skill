# trustgraph-mcp: design plan

**Status:** Working draft, rev 5 (post-third-round synthesis — touched-set deleted, identity reverted to shared, query split). Disposable scratch — delete after implementation starts.

## Context

The existing trustgraph skill runs invisibly in Claude Code via PostToolUse hooks. Claude Desktop has no hook equivalent and no cross-MCP visibility, so the same skill cannot be ported as-is. The closest functional port is an MCP server exposing the trustgraph capabilities as tools the model can call deliberately. Lives in the same repo at `mcp-server/` so the two surfaces share the same `~/.trustgraph/` state.

## Goals

1. Bring trustgraph capability to Claude Desktop (and any MCP-capable host: Cursor, Zed, Continue, the API directly).
2. Reuse `~/.trustgraph/api-key` shared with the Code skill — first surface to mint owns the reviewer identity encoded in the key. Both surfaces accumulate ratings under one identity; the reviewer prefix on first mint is purely cosmetic (`agent://anon/<uuid>` if Code minted first, `agent://desktop/<uuid>` if MCP minted first). Backend has no per-event `reviewer_external_id` field today; per-surface attribution would require backend work and is deferred.
3. Ship a paired claude.ai skill alongside the MCP so proactive `score` use is primed at conversation start (description-text-only is brittle for unprompted firing).
4. First-time-author-friendly: small surface, official `mcp` Python SDK, no DIY transport code.

## Non-goals

- **Invisibility.** Desktop tool calls appear in chat. The model chooses when to invoke; not background, not silent.
- **Persistent durability.** Single in-memory retry on 5xx with 500ms backoff; then `ToolError` with verbatim-relay phrasing. No queue, no on-disk retry.
- **Calibration parity with the Haiku rater.** Different model + different context = different rating distribution. Accept it; revisit if backend reputation weighting ever lands and exposes the divergence.
- **Client-side forge-protection.** Rev 3 had a session-touched-entity gate that refused untouched rates; rev 4 softened to a warning; rev 5 deletes it. The two-call bypass (model calls `score(X)` then `rate(X)` under prompt injection) defeats the gate, and the warning was decorative (no backend consumer for the signal). Honest posture: defense is server-side rate limits + future reputation weighting.
- **Backwards compat with the bash wrappers.** Parallel surface, not replacement. Code skill keeps its wrappers.
- **Cross-MCP observation.** MCP servers are sandboxed from each other by spec.

## Types

Defined here so tool signatures below can reference them cleanly.

```python
@dataclass
class AppContext:
    """Shared lifespan context for all tools."""
    client: httpx.AsyncClient
    api_key: str | None = None      # Lazy-loaded on first rate call (reads
                                    # are unauthenticated). Avoids failing
                                    # boot if mint is unreachable.
```

## Architecture

```
Claude Desktop (host)
        │  spawns via JSON-RPC over stdio
        ▼
trustgraph-mcp (this server)
  • FastMCP, ~250 lines
  • async tools; httpx.AsyncClient via lifespan with AppContext
  • Explicit timeouts: Timeout(connect=3, read=10, write=5, pool=5)
  • Reads ~/.trustgraph/api-key on first rate via mint-key.sh under
    fcntl.flock (lazy; reads don't need it)
  • Stdout → stderr redirect BEFORE any third-party import; restored once
  • ctx.info()/ctx.warning()/ctx.error() (async, awaited) → Desktop log
  • Optional TRUSTGRAPH_DEBUG_LOG → side JSONL log (mode 0600)
        │
        ▼  immediate POST per rate call (1× retry on 5xx; no retry on timeout)
TrustGraph API
```

`rate` calls submit immediately. 5xx → one retry; persistent 5xx → ToolError. Timeout → no retry; ToolError says "maybe-submitted, do not assume failure". 429 → no retry; ToolError quotes `Retry-After` so the model can relay the wait. The "Idempotency-Key" header is **not** sent today (server doesn't support it; sending it would imply mitigation we don't have — revisit if backend adds support).

## Tool surface

**Six tools.** Names are terse; Desktop prefixes them with the server name (`mcp__trustgraph__score` etc.).

| Tool | Purpose | When the model should call it |
|---|---|---|
| `score` | Check one entity. `detail="summary"` (default) returns composite/confidence/last_updated via `GET /v1/score`; `detail="full"` returns combined profile (dimensions + top failure modes + top capability tags) via `GET /v1/profile`. | **Before** consuming a non-trivial URL or unfamiliar MCP capability. Bump to `"full"` when the user asks "tell me about X". |
| `retrieve` | Past events for one entity, optionally ranked by similarity to a query. Rationales truncated to 200 chars to bound context + exfil surface (matches bash `tg-retrieve`). | When `score` is ambiguous (0.4–0.7), the user asks "why?", or you need rationales not just numbers. |
| `rank` | Cross-entity: best entities for a capability tag on a chosen dimension. | When the user asks "who's the cheapest/fastest/safest at Y?" |
| `capabilities` | List capability tags with event counts. | Discovery / "what's been rated?" |
| `get_rubric` | Returns the full scoring rubric. | When the model wants depth before a tricky `rate` — escape hatch from the inline condensate. Hooked from `rate`'s description by named failure mode. |
| `rate` | Submit one rating. `type="data_source"` for URLs/REST endpoints, `type="capability"` for MCP servers/tools. | **After** consuming/invoking — the model formed an impression. |

(Tool-count history: rev 1 = 8, rev 3 = 6 by merging `score`+`profile` and the two `rate_*`, rev 4 = 5 by also merging `retrieve`+`capabilities` into `query(op)`. Rev 5 splits `query` back: `retrieve` and `capabilities` take disjoint args, so the merge forced the model to pick op AND params — strictly harder than two focused tools. The `score`+`profile` merger stays because those *share* args.)

### Tool description template

Four parts, applied to every tool:

1. **What it does** (one clause).
2. **Trigger** — "Use BEFORE..." for `score`, "Use AFTER..." for `rate`, specific user-utterance triggers for the others. Push hard on **proactive, unprompted** firing for `score` and `rate`.
3. **Carve-outs** — "Skip for routine reads, well-known docs (docs.python.org, en.wikipedia.org), pages already discussed, plainly low-stakes single-turn replies."
4. **Concrete example** — one sentence describing a canonical trigger.

`rate` additionally embeds the **18-line rubric condensate** at the end of its description.

#### Drafts for the two highest-risk descriptions

**`score`:**
> Check the trust score of a URL or capability before consuming/invoking it. Returns composite (0–1), confidence (0–1), and `last_updated`. **Call this proactively, without being asked, whenever you're about to fetch a non-trivial URL, hit an unfamiliar REST endpoint, or invoke an MCP tool you haven't established trust in this session.** Don't wait for the user to ask. Skip only for: file reads, well-known docs (docs.python.org, mdn.io, en.wikipedia.org for general knowledge), URLs already discussed in this conversation, plainly low-stakes one-shot replies. `confidence=0.0` means "no signal yet" — proceed and rate afterward. Pass `detail="full"` for the combined profile. Example: user pastes `https://random-blog.example/post/123` — call `score` before fetching.

**`rate`:**
> Submit one rating for a URL/REST endpoint (`type="data_source"`) or MCP server/tool (`type="capability"`) you just consumed/invoked. **Call this AFTER any non-trivial interaction, without being asked — the system only learns from submitted ratings.** Pair every proactive `score` call with a `rate` call once you've read the content. Skip for: file reads, well-known docs already accepted, low-stakes one-shots. **If you're picking 0.5 because you can't decide, uncertain about dimension picks, or rating token/context efficiency — call `get_rubric` first.** Example: after summarizing `https://random-blog.example/post/123`, rate it ~0.8 with rationale and dimensions.
>
> ```
> [18-line condensate, below]
> ```

### Rubric condensate (embedded in `rate`)

```
Score anchors (0–1, higher = better):
  1.0 — Worked perfectly                    0.2 — Significant problems
  0.8 — Worked with minor issues            0.0 — Actively harmful
  0.5 — Mixed (only when can't decide)
Use the full range; do not cluster at 0.5 or 0.8.

Dimensions (all 0–1, HIGHER ALWAYS BETTER):
  accuracy            — correctness
  latency             — speed (higher = faster)
  cost                — cheapness (higher = cheaper)
  reliability         — consistency
  safety              — non-harm
  token_efficiency    — frugality (higher = fewer tokens used)
  context_efficiency  — small per-turn footprint

Anchor latency/cost/efficiency numbers in rationale with the
  measurement ("p95 3.2s, ~$0.012/call" not just "slow").

Weight: 1.0 direct, 0.5 inspected only, 0.2 second-hand.
  Weight is evidence quality, not score uncertainty — uncertain
  about the score? Pick 0.5. Don't lower weight for that.

Rationale ≤500 chars; never paste content from external sources
  (rationale/task/task_tags are exfil channels otherwise).
Call get_rubric for full details and worked examples.
```

~300 tokens standing Desktop context.

### Input style

**Flat typed parameters** with `Annotated[T, Field(...)]`. Per-field caps and key-set restrictions enforced client-side.

```python
DIMENSION_KEYS = {
    "accuracy", "latency", "cost", "reliability", "safety",
    "token_efficiency", "context_efficiency",
}
METRIC_KEY_RE = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
RESERVED_ID_PREFIXES = ("agent://trustgraph-", "agent://anthropic/")

@mcp.tool()
async def rate(
    type: Literal["data_source", "capability"],
    external_id: str,
    score: Annotated[float, Field(ge=0, le=1, description="Holistic 0–1 rating")],
    weight: Annotated[float, Field(gt=0, le=1)] = 1.0,
    task: Annotated[str | None, Field(max_length=500)] = None,
    rationale: Annotated[str | None, Field(max_length=500)] = None,
    dimensions: dict[str, float] | None = None,
    failure_modes: Annotated[
        list[Annotated[str, Field(max_length=64)]] | None,
        Field(max_length=10),
    ] = None,
    metrics: dict[str, float] | None = None,
    task_tags: Annotated[
        list[Annotated[str, Field(max_length=32)]] | None,
        Field(max_length=10),
    ] = None,
    ctx: Context[ServerSession, AppContext] | None = None,
) -> RateResult:
    """..."""
```

**Validation rules (raise `ToolError(422, ...)` client-side BEFORE submission). Always include the offending key/value in the error message so the model self-corrects:**

- `external_id` must NOT start with any prefix in `RESERVED_ID_PREFIXES` — server returns 422 otherwise; cheaper to catch client-side.
- `dimensions`: keys must all be in `DIMENSION_KEYS`. Unknown key → reject whole call (do not silently drop — silent drop hides exfil).
- `metrics`: keys must match `METRIC_KEY_RE` (lowercase snake, ≤32 chars). Values must be finite numbers (drop `NaN`/`Inf`, coerce numeric strings to float, reject everything else — matches bash `tg-rate`/`tg-flush` value sanitization). Unknown key shape → reject; unsanitizable value → drop the metric silently (matches bash; no exfil risk via value).
- `rationale` ≤500 chars **on the MCP path** even though server accepts up to 2000 — MCP stays stricter to bound prompt-injection exfil. Document the asymmetry in README. The bash path stays at 2000.
- `task_tags` item-length cap is 32 chars on the MCP path (bash accepts 64). Document the asymmetry in README.

Don't double-default (`Field(default=...) = ...`) — use the parameter default only.

### Output style

Pydantic `BaseModel` per tool. SDK auto-generates `outputSchema` and back-fills `TextContent` for legacy clients. **Datetime fields in responses use `str | None`, not `datetime`**, until live-API verification confirms strict-ISO format on every endpoint (the bash wrappers treat them as opaque). Response models use `model_config = ConfigDict(extra="allow")` to tolerate server-side additions.

Full response shape sketches in the **Appendix** at the bottom (one per endpoint).

`retrieve` truncates each event's `rationale` to 200 chars in its response (matches bash `tg-retrieve`) — bounds Desktop context budget and limits the prompt-injection surface of attacker-controlled rationale text.

### Errors

`ToolError("api 422: ...")` from `mcp.server.fastmcp.exceptions` for user-visible failures (passes through verbatim). Plain `Exception` only for genuinely-internal bugs (gets masked by SDK).

| Outcome | Behavior |
|---|---|
| 2xx | Return value. |
| 4xx (incl. 422) | `ToolError` quoting the server error envelope (`{"error": {"code", "message"}}`) verbatim. No retry. Include offending field/key when the cause is identifiable client-side. |
| 429 | `ToolError` quoting `Retry-After` header so the model can relay the wait. No retry. |
| 5xx | One retry with 500ms backoff. Then `ToolError` with verbatim-relay phrasing: `"TrustGraph 5xx — rating not recorded; retry the rate call if it matters"`. |
| Timeout | No retry. `ToolError("TrustGraph timed out — your rating may or may not have been recorded; don't retry blindly")`. |

### Stdio hygiene

```python
# server.py — first lines, before any third-party import
import sys
_real_stdout = sys.stdout
sys.stdout = sys.stderr          # third-party imports' print() goes to stderr
# ... third-party imports here (including from mcp.server.fastmcp ...) ...
sys.stdout = _real_stdout        # SDK's stdio_server manages from here
import logging
logging.basicConfig(stream=sys.stderr, level=logging.WARNING, force=True)
```

Drop `warnings.simplefilter("error")` (would crash on the first `DeprecationWarning` during import). Use `PYTHONWARNINGS=ignore` in the Desktop config for noise suppression.

## State

| Path | Purpose |
|---|---|
| `~/.trustgraph/api-key` | Reviewer key (shared with Code skill). Mode 600. Atomic-written via `mktemp + mv -f` under `umask 077`. First surface to mint owns the identity baked into it. |
| `~/.trustgraph/api-key.lock` | `fcntl.flock(LOCK_EX)` taken during read-or-mint-and-persist. Honored by `mint-key.sh`; the Python MCP shells out to that script. |

One source of truth: refactored `scripts/mint-key.sh` owns read-or-mint-and-persist under the lock. The Python MCP invokes it via `TRUSTGRAPH_MINT_SCRIPT` (default: `<mcp-server-package>/../scripts/mint-key.sh` — clone-relative; this MCP is designed to run from the git clone, not as a pip-installed package).

```bash
# scripts/mint-key.sh — sketch of the Phase 3 refactor
#
# Usage:
#   mint-key.sh                                 # reads/mints, prints key on stdout
#   mint-key.sh agent://your-org/your-agent     # same, with stable identity
#   mint-key.sh --write [identity]              # persist silently, don't print
set -euo pipefail
trap 'exec 9>&-' EXIT                           # release lock explicitly

KEY_FILE="${TRUSTGRAPH_KEY_FILE:-$HOME/.trustgraph/api-key}"
LOCK="${KEY_FILE}.lock"
mkdir -p "$(dirname "$KEY_FILE")"
chmod 700 "$(dirname "$KEY_FILE")"              # fail loud if perms can't tighten

# Arg parsing: --write may appear in any position; remaining arg is identity.
WRITE_ONLY=0
IDENTITY=""
for arg in "$@"; do
  case "$arg" in
    --write) WRITE_ONLY=1 ;;
    *) IDENTITY="$arg" ;;                       # last positional wins
  esac
done
# Default identity uses agent://anon/ to match existing Code-skill convention.
# MCP overrides to agent://desktop/<uuid> when it mints first. If the key file
# already exists, the existing identity wins (first-mint-wins, by design).
: "${IDENTITY:=agent://anon/$(python3 -c 'import uuid; print(uuid.uuid4())')}"

exec 9>"$LOCK"
python3 -c 'import fcntl,sys; fcntl.flock(sys.stdin.fileno(), fcntl.LOCK_EX)' <&9
# Lock attaches to the open file description for $LOCK. fd 9 is held by THIS
# shell; <&9 dups it to the child Python's stdin so it takes the lock on the
# same OFD. When Python exits its fd 0 closes but the OFD remains referenced
# by parent fd 9 — lock stays held until `exec 9>&-` or shell exit.

# Double-check after lock acquire: another process may have minted.
if [[ -s "$KEY_FILE" ]]; then
  [[ "$WRITE_ONLY" -eq 1 ]] || cat "$KEY_FILE"
  exit 0
fi

# Mint.
PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"reviewer_external_id": sys.argv[1]}))' "$IDENTITY")
RESP=$(curl -sS --fail -X POST "${TRUSTGRAPH_BASE_URL:-https://mep39camvm.us-east-1.awsapprunner.com}/v1/keys" \
  -H "Content-Type: application/json" -d "$PAYLOAD")
KEY=$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["api_key"]) if "api_key" in d else sys.exit("mint failed: "+sys.stdin.read())' <<< "$RESP")

# Atomic write under umask 077: tempfile in same dir, mv -f.
umask 077
tmp=$(mktemp "${KEY_FILE}.XXXXXX")
chmod 600 "$tmp"                                # belt-and-suspenders vs umask race
printf '%s\n' "$KEY" > "$tmp"
mv -f "$tmp" "$KEY_FILE"                        # atomic rename, mode preserved

[[ "$WRITE_ONLY" -eq 1 ]] || echo "$KEY"
```

Semantics worth highlighting:
- `flock` is advisory but released on process death (SIGKILL included) on both macOS and Linux. The Phase 3 test must SIGKILL a mid-mint script explicitly to verify.
- `flock(1)` is NOT installed on macOS — hence the `python3 -c fcntl.flock` idiom from bash. Cross-language interop works because both sides hit the same kernel syscall on the same OFD.
- `mktemp "${KEY_FILE}.XXXXXX"` puts the temp in the same directory as the target → same filesystem → `mv -f` is `rename(2)` → atomic.
- Same-UID processes (other MCPs, pip-installed CLIs, Time Machine, iCloud Desktop sync) can read the key file. Mode 600 only protects against *other UIDs*. Document this; recommend stable-identity-only with a secret store for serious deployments.

`tg-flush` (in the Code skill's scripts) also picks up the refactored script — one source of truth.

## Logs and observability

- `ctx.info()` / `ctx.warning()` / `ctx.error()` (async, awaited) → Desktop server-log panel (`notifications/message`). By default log only entity ID, type, score, status code, latency. **Never** log `task`, `rationale`, `dimensions` keys, `metrics` keys — these persist in `~/Library/Logs/Claude/` and are user-readable forever.
- Opt-in: `TRUSTGRAPH_DEBUG_LOG=~/.trustgraph/mcp-debug.log` enables append-only JSONL with full request/response per call. **Opened with `os.open(path, O_WRONLY|O_CREAT|O_APPEND, 0o600)` explicitly** — Python's `open()` defaults to 0644 under typical umask, which would land sensitive payloads in any Time Machine / iCloud-synced backup as world-readable.

## Implementation phases

| Phase | Output | Done when |
|---|---|---|
| 0 | `mcp-server/server.py` (flat, single file, ≤400 lines target); `mcp-server/pyproject.toml` with `requires-python = ">=3.11"`, `mcp[cli]>=1.12,<2`, `httpx>=0.27,<1`; `[project.scripts]` entry `trustgraph-mcp = "server:main"` with `def main(): mcp.run()`; `uv.lock` committed; stdio-hygiene shim in place; minimal `hello` tool scaffolding | `cd mcp-server && uv run --locked mcp dev server.py` lists the `hello` tool |
| 1 | Read-only tools: `score` (with `detail` enum), `retrieve` (rationale truncation in response), `rank`, `capabilities`; AppContext lifespan with httpx; response Pydantic models per the Appendix (datetime → `str \| None`) | Manual `mcp dev` exercises each tool against the live API; rationale truncation verified in `retrieve` |
| 2 | `get_rubric` tool — returns a Pydantic `Rubric` model (anchors, dimensions, weight semantics, examples). Source: hardcoded constant in `server.py` extracted from `references/rubric.md` (no build-time extraction; simpler) | `mcp dev` inspector renders the structured rubric |
| 3 | Auth refactor: rewrite `mint-key.sh` per the State section sketch (own read-or-mint-and-persist under `fcntl.flock`; atomic mktemp+mv; `--write` mode; first-mint-wins identity); MCP shells out via `TRUSTGRAPH_MINT_SCRIPT`; `tg-flush` also picks up the refactored script | Concurrent mint test (race two processes against empty key file) yields ONE key; **SIGKILL of mint script mid-execution releases the lock** (kernel reaps fds); key file never observed at mode 644 |
| 4 | `rate` tool with `type` discriminator; per-field caps (task_tags items ≤32 + count ≤10; failure_modes items ≤64 + count ≤10; rationale ≤500; dimension key whitelist with reject-on-unknown; metric key regex with reject-on-unknown; metric value sanitization drops non-numeric); reserved-prefix client-side check; single in-memory retry on 5xx; no retry on timeout or 429 (with `Retry-After` quoted); ToolError messages include offending key/value; submission via `POST /v1/scores` (singular, immediate-submit endpoint) with `X-Api-Key` header; AppContext.api_key lazy-loaded via `mint-key.sh` on first `rate` call | A rating lands; all validation rules + retry behavior verified |
| 5 | Tool description tuning per the 4-part template; rubric condensate (18 lines) embedded in `rate`; "proactive, unprompted" language in `score`/`rate` | Smoke-test in Desktop: paste an unfamiliar URL → model calls `score` first proactively, then `rate` at the end |
| 6 | Paired claude.ai skill: manual upload via the claude.ai Customize panel (Settings → Capabilities → Skills → upload zip). Bundle layout: flat zip with `SKILL.md` at root + `references/{rubric,queries,examples,scoring-model}.md`. Web UI flow only; no CLI exists today | Skill appears in Customize panel; conversation prologue includes the skill content; model fires proactive `score` in a fresh Desktop session |
| 7 | README install section: **primary path is hand-edited `~/Library/Application Support/Claude/claude_desktop_config.json` with the JSON block in the Appendix**; `uv run --locked mcp install server.py --name "TrustGraph"` documented as a shortcut but caveated (bakes the clone's absolute path; `-v`/`-f` flag behavior has shifted across SDK versions — verify against current SDK at impl time); loud DNS-takeover warning recommending `TRUSTGRAPH_BASE_URL` override of the PoC URL | Recipient can install from a fresh clone in <10 minutes via the hand-edit path |
| 8 (later) | If/when backend adds idempotency-key support: client sends `Idempotency-Key: <uuid>` on `rate`; remove the "may have been recorded" timeout phrasing | Mid-call crash test produces no duplicate |

## Test plan

- **Unit (pytest, new `tests/` dir)**: each tool function is callable as a plain Python function; mock `httpx.AsyncClient.get` and `.post` (not `.request` — the call sites use the method shortcuts). Tag/metric normalization round-trip tests reused from Code skill.
- **Protocol**: `mcp dev server.py` — list tools, exercise each with valid + invalid input. Check `ToolError` messages reach the inspector with offending key info.
- **Concurrency** (shell script + pytest hybrid):
  - Spawn two Python processes + one bash `mint-key.sh` simultaneously against an empty key file; confirm exactly one mint occurs and all three end up with the same key string.
  - SIGKILL one mid-mint; confirm the lock releases and the next process can mint.
- **Validation**: oversized `task_tags`/`failure_modes`/`dimensions`/`metrics` payloads — each field is truncated/rejected client-side before submission; the `ToolError` names the offending key. Reserved `external_id` prefixes (`agent://trustgraph-`, `agent://anthropic/`) caught client-side.
- **Integration**: configure Desktop, ask the model to:
  - "Check the reputation of https://example.com" → `score` fires.
  - "Rate the page we just looked at, around 0.9" → `rate` fires.
  - "What's the best MCP for X?" → `rank` fires.
- **Outage**: with TrustGraph unreachable, confirm `rate` returns a meaningful `ToolError` (not a stack trace); 1× retry was attempted on 5xx. 429 path also verified.
- **Briefing fixture format** (if rater-comparison work is wanted later): the `tg-judge-and-rate` stdin schema documented in lines 9–19 of that script. Run `tg-judge-and-rate` with `TG_RATER_BACKEND=api` on each briefing to capture Haiku-rater output; MCP integration tests can use the same briefings.

## Risks

- **Discoverability** — paired claude.ai skill (Phase 6) is the primary mitigation; tool descriptions are the secondary lever. Watch first-use sessions for under-fire of `score`.
- **Rationale + adjacent-field exfil via prompt injection** — capped (rationale ≤500, task ≤500, task_tags items ≤32 / count ≤10, failure_modes items ≤64 / count ≤10); dimension keys whitelisted with reject-on-unknown; metric keys regex-restricted with reject-on-unknown; metric values sanitized (numeric-only). `retrieve` truncates each rationale to 200 chars in the response.
- **Forged ratings for unseen entities** — **no client-side defense in v1**. The rev-3 session-touched gate was tried (refuse) and softened (warn) in rev 4 and deleted in rev 5 because two-call bypass (model scores then rates under prompt injection) defeats it and the warning had no backend consumer. Real defense: server-side per-key rate limit + (planned) reputation weighting. Per-IP mint at 50/hour bounds adversarial key rotation but does not prevent it.
- **Shared reviewer identity** — Desktop + Code accumulate under one identity (first-mint-wins). Calibration differences between Haiku (Code's rater) and Desktop's model average together in the corpus. Accepted tradeoff (operationally simple); revisit if drift causes visible problems and backend gains per-event reviewer attribution.
- **PoC DNS-takeover** — `mep39camvm.us-east-1.awsapprunner.com` is non-production. README warns loudly; recommend `TRUSTGRAPH_BASE_URL` override for any "real" use. Cert-pinning remains deferred (deployment is explicitly experimental).
- **Mid-call crash → duplicate submission** — accepted: server has no idempotency support today; one event averages in. We do not send a client header (would imply mitigation we don't have). Timeout policy is no-retry to bound blast radius.
- **API key exposure on shared / backed-up hosts** — mode 600 only protects against other UIDs. Same-UID processes, Time Machine, iCloud Desktop sync read freely. Atomic write under `umask 077` + explicit `chmod 600` closes the mid-write mode-644 window; parent dir is 0700. **Debug log opened with explicit mode 0600.**
- **Stdio pollution from third-party imports** — stdout→stderr redirect *before* third-party imports; `logging.basicConfig(stream=sys.stderr, force=True)`; `PYTHONWARNINGS=ignore` in Desktop config. `warnings.simplefilter("error")` is **not** used (would crash on first `DeprecationWarning`).
- **Outage = lost ratings** — single 5xx retry buys connect-jitter robustness for free. Persistent failure → `ToolError` with verbatim-relay phrasing.
- **Supply-chain via transitive deps** — `uv run --locked` everywhere (Phase 0, README, dev workflow). `uv.lock` committed.
- **Long-term log leakage via `ctx.info()`** — by default log only entity ID + type + score + status; never task/rationale/keys. Opt-in `TRUSTGRAPH_DEBUG_LOG` for full request/response when debugging.
- **`ToolError` storms in early use** — bash scripts silently normalize sloppy tags / drop non-numeric metrics; the MCP rejects unknown keys and surfaces ToolErrors. The model may emit unfamiliar dimension/metric keys on first attempts. Mitigation: ToolError messages include the offending key, so the model can self-correct on retry. Watch first-use traces and add to the whitelist if the model converges on legitimate-but-missing names.

## What's NOT in this plan (deferred)

- pip / PyPI distribution (use `uv run --locked` from git clone for v1).
- A persistent queue and `flush_pending` tool.
- Schema-drift detection (`tg-mcp-doctor` subcommand).
- TypeScript port.
- Hot-reload of `~/.trustgraph/` state.
- Cowork-mode integration.
- Cert-pinning for the PoC URL.
- Server-side idempotency support (backend roadmap; Phase 8 client work if/when it lands).
- Reviewer-reputation-weighted aggregation (backend); per-event reviewer attribution (backend) — these would unlock per-surface tagging.
- `get_rubric` as an MCP resource (`trustgraph://rubric`) — resource discoverability is host-dependent; kept as a tool.
- Session-touched-entity gate (tried in rev 3, softened in rev 4, deleted in rev 5).
- Per-surface key files / per-surface reviewer identity (tried in rev 4, reverted in rev 5).

## Open questions

None. All decisions made.

(Phase 7's `mcp install` SDK-version caveat and the Appendix's "verify response shapes against live API at Phase 1" are implementation-time validations, not open design questions.)

---

## Appendix A: response shapes

Sketches based on `references/queries.md` + `SKILL.md` + the bash wrappers. Pydantic models use `model_config = ConfigDict(extra="allow")` to tolerate server-side additions. **Datetime fields are `str | None` until live-API verification confirms strict-ISO at Phase 1 implementation time.**

### `GET /v1/score` (used by `score(detail="summary")`)

```python
class ScoreSummary(BaseModel):
    composite_score: float            # [0, 1]; 0.5 for unknown
    confidence: float                 # [0, 1]; 0.0 for unknown
    last_updated: str | None          # ISO timestamp string; null if never rated
```

### `GET /v1/profile` (used by `score(detail="full")`)

```python
class DimensionAggregate(BaseModel):
    value: float                      # decayed dimension reading, [0, 1]
    confidence: float
    last_updated: str | None          # null = no measurement, came from prior

class FailureMode(BaseModel):
    tag: str
    n_events: int

class CapabilityTagRow(BaseModel):
    tag: str
    n_events: int

class Profile(BaseModel):
    composite_score: float
    confidence: float
    dimensions: dict[str, DimensionAggregate]
    top_failure_modes: list[FailureMode]
    top_capability_tags: list[CapabilityTagRow]
    n_events: int
    known: bool                       # false → fields came from scorer's prior
```

### `POST /v1/retrieve` (used by `retrieve`)

```python
class Event(BaseModel):
    score: float
    weight: float
    task: str | None
    rationale: str | None             # MCP truncates to 200 chars in response;
                                      # treat as user-supplied text on read.
    dimensions: dict[str, float] | None
    failure_modes: list[str] | None
    metrics: dict[str, float] | None
    task_tags: list[str] | None
    observed_at: str                  # ISO timestamp string
    similarity: float | None          # present when query was provided

class CompositeAggregate(BaseModel):
    composite_score: float
    confidence: float
    # may include last_updated; tolerated via extra="allow"

class Aggregates(BaseModel):
    composite_score: CompositeAggregate
    dimensions: dict[str, DimensionAggregate]
    failure_modes: dict[str, int]

class RetrieveResult(BaseModel):
    events: list[Event]
    aggregates: Aggregates | None     # present when include_aggregates=True
    n_events_total: int
```

### `POST /v1/rank` (used by `rank`)

```python
class RankedEntity(BaseModel):
    entity: dict[str, str]            # {"type": ..., "external_id": ...}
    decayed_score: float
    confidence: float
    n_events: int
    supporting_event: Event | None    # present when include_supporting_event=True

class RankResult(BaseModel):
    results: list[RankedEntity]
    candidates_capped: bool
```

### `GET /v1/capabilities` (used by `capabilities`)

```python
class CapabilityRow(BaseModel):
    tag: str
    n_events: int
    n_entities: int
    last_seen: str                    # ISO timestamp string

class CapabilitiesResult(BaseModel):
    capabilities: list[CapabilityRow]
```

### `POST /v1/scores` (used by `rate` — submission body, not response)

```json
{
  "reviewee": {"type": "data_source" | "capability", "external_id": "..."},
  "score": 0.0–1.0,
  "weight": 0.0–1.0,
  "task": "≤500 chars",
  "rationale": "≤500 chars (MCP); server accepts ≤2000",
  "dimensions": {"<dim_key>": 0.0–1.0, ...},
  "failure_modes": ["snake_case", ...],
  "metrics": {"<metric_key>": <finite number>, ...},
  "task_tags": ["snake_case", ...]
}
```

Headers: `X-Api-Key: <key from AppContext.api_key>`, `Content-Type: application/json`.

**Explicitly NOT included on the wire:**
- `Idempotency-Key` header (server doesn't support today; revisit Phase 8).
- `reviewer` / `reviewer_external_id` fields (reviewer is implicit from API key; setting them risks 422).
- `capability_tags` field (does not exist; use `task_tags`).
- `payload` field (removed from the API).

## Appendix B: Claude Desktop config block (Phase 7)

Hand-edit `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or the platform equivalent. Add or merge the `trustgraph` entry under `mcpServers`:

```jsonc
{
  "mcpServers": {
    "trustgraph": {
      "command": "uv",
      "args": [
        "--directory", "/absolute/path/to/trustgraph-skill/mcp-server",
        "run", "--locked",
        "trustgraph-mcp"
      ],
      "env": {
        // Required: where the MCP can find the shared mint-key.sh script.
        "TRUSTGRAPH_MINT_SCRIPT": "/absolute/path/to/trustgraph-skill/scripts/mint-key.sh",

        // Optional: override the TrustGraph deployment URL. The PoC URL is
        // experimental — recommend setting this for any non-throwaway use.
        // "TRUSTGRAPH_BASE_URL": "https://your-trustgraph-deployment.example",

        // Optional: enable side log of every request/response (mode 0600).
        // "TRUSTGRAPH_DEBUG_LOG": "/Users/you/.trustgraph/mcp-debug.log",

        // Optional: silence third-party deprecation noise on stdout.
        "PYTHONWARNINGS": "ignore"

        // Not set here: TRUSTGRAPH_API_KEY (auto-minted on first `rate` call
        // via TRUSTGRAPH_MINT_SCRIPT; provide it only for stable identity).
      }
    }
  }
}
```

Restart Claude Desktop after editing. Verify the MCP loaded by checking the Desktop server-log panel for `trustgraph` startup.

Both absolute paths point at the cloned `trustgraph-skill` repo on disk. The `mcp install` shortcut bakes paths automatically but has tracked SDK-version variance — the hand-edit is the durable path.
