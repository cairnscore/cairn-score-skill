# trustgraph — reputation tooling for Claude Code + Claude Desktop

Pick the install path that matches how you use Claude. Both back the same TrustGraph reputation API and coordinate on the same `~/.trustgraph/` state via `fcntl.flock`, so ratings accumulate under one reviewer identity no matter which surface produced them.

| Path | For | Behavior | Install |
|---|---|---|---|
| **Claude Code skill** | CLI / agent users who want **continuous, invisible rating** of every tool call | `PostToolUse` hooks rate every WebFetch / WebSearch / MCP / curl call without the model seeing anything in chat. Highest signal density. | `bash skill/install.sh` |
| **Claude Desktop MCP** (`.mcpb`) | Desktop users who want **visible tool calls** for trust checks | Ten MCP tools + one selectable prompt. Model decides when to call; tool invocations show in chat. Auto-firing requires the pinned prompt or a custom instruction. | Drag `dist/trustgraph.mcpb` onto Claude Desktop — one click |
| **claude.ai web skill** | Users on the web client only | The same procedural framing + references, loaded by the claude.ai skill router. No local install. | Upload `dist/trustgraph-skill.zip` at `claude.ai → Settings → Capabilities → Skills` |

The Code skill is the densest signal path; the MCP is the most discoverable; the web skill is the broadest reach. Pick by need; they coexist cleanly.

---

## Install path 1 — Claude Code skill

```bash
git clone https://github.com/GusEllerm/trustgraph-skill.git ~/code/trustgraph-skill && \
  bash ~/code/trustgraph-skill/skill/install.sh
```

Clone the repo anywhere convenient (the example uses `~/code/`); the installer copies the skill content to `~/.claude/skills/trustgraph/` and registers the hooks.

The installer prompts for a rater backend:
- **`api`** — direct Anthropic API. Needs a key from `console.anthropic.com`. Cheap, fast.
- **`claude-cli`** — uses Claude Code's existing auth (claude.ai subscription). No API key needed. Slower, more subscription-quota.

Then start a fresh Claude Code session. Hooks fire automatically.

To update later: `bash ~/code/trustgraph-skill/skill/update-skill.sh`.

---

## Install path 2 — Claude Desktop (`.mcpb` bundle)

`.mcpb` (Anthropic's MCP Bundle format) ships the server as a single double-clickable file. Desktop's installer reads the bundled `manifest.json`, prompts for any optional config (deployment URL, debug log path), stores secrets in the OS keychain, and registers all ten tools + the proactive-trust-check prompt.

### Building the bundle

```bash
# Prereq: npm i -g @anthropic-ai/mcpb
cd mcp-server && bash build-mcpb.sh
# → ../dist/trustgraph.mcpb
```

The build script bundles `skill/scripts/mint-key.sh` into the package so the MCP is self-contained (no separate skill checkout required at runtime).

### Installing

Drag `dist/trustgraph.mcpb` onto Claude Desktop, or open it from Finder / Explorer. Desktop's UI prompts for the optional config; defaults are fine for a first install. Restart Desktop after install completes (it should prompt). Verify the MCP loaded by checking the `🔌` indicator in the compose window — `trustgraph` should appear with all ten tools listed, plus the `/trustgraph-proactive` prompt in the slash-command picker.

For a deeper health check, run `bash skill/scripts/tg-doctor` from the cloned repo (works for any install path).

### Getting proactive auto-firing

The MCP tools alone are advisory — the model uses them when relevant but doesn't auto-fire on every fetch the way the Code skill does. Two ways to enable the auto-fire behavior in Desktop:

1. **Per-conversation**: type `/` in compose, pick **trustgraph-proactive**. The protocol becomes part of the conversation context.
2. **Always-on**: paste the block from `docs/desktop-personalize.md` into **Settings → Profile → preferences**. Every conversation gets the rule.

### Fallback: hand-edit JSON

If you can't build `.mcpb` (no Node, no `npm`), hand-edit `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS path; adjust on other OSes) and merge:

```jsonc
{
  "mcpServers": {
    "trustgraph": {
      "command": "uv",
      "args": ["--directory", "/absolute/path/to/trustgraph-skill/mcp-server", "run", "--locked", "python", "server.py"],
      "env": {
        "TRUSTGRAPH_MINT_SCRIPT": "/absolute/path/to/trustgraph-skill/skill/scripts/mint-key.sh",
        "PYTHONWARNINGS": "ignore"
        // Optional: "TRUSTGRAPH_BASE_URL", "TRUSTGRAPH_DEBUG_LOG" — see env table below
      }
    }
  }
}
```

Replace both absolute paths with your clone location. If `uv` doesn't resolve in Desktop's launchd-spawned environment (spawn error in the server log), replace `"command": "uv"` with the absolute path — find via `which uv`, e.g. `/Users/you/.local/bin/uv`.

---

## Install path 3 — claude.ai web skill

The paired skill at `dist/trustgraph-skill.zip` (rebuilt from `skill/SKILL.md` + `skill/references/`) loads on claude.ai via the skill router. Upload at **Settings → Capabilities → Skills**. No local install. Best when you primarily use claude.ai in the browser.

**Length constraint to know about if you fork:** claude.ai enforces `description ≤ 1024 chars` on the SKILL.md frontmatter. The current description is ~870 chars (154 chars of headroom). If you edit it and the upload errors with `field 'description' in SKILL.md must be at most 1024 characters`, that's the cause — trim and rebuild the zip (`cd skill && zip -r ../dist/trustgraph-skill.zip SKILL.md references/*.md`).

The MCP shares the URL-scoped key file (`~/.trustgraph/keys/<host>.key`, default `<host>` = `mep39camvm.us-east-1.awsapprunner.com`) with the Code skill via `mint-key.sh`, which owns read-or-mint-and-persist under `fcntl.flock`. First surface to mint owns the reviewer identity baked into the key; both surfaces accumulate ratings under that identity.

### Tools

| Tool | Purpose |
|---|---|
| `score(type, external_id, context?, scorer?)` | Reputation check before consuming a URL or MCP capability — single composite/confidence/diagnostics in one call. The proactive pre-check. |
| `profile(type, external_id, context?, top_failure_modes?, top_capability_tags?)` | Combined snapshot of one entity (dimensions + top failure modes + top capability tags + event counts + LLM-generated `summary` when the entity has enough events — **relay `summary.synthesis` verbatim instead of re-synthesizing**). |
| `score_batch(refs)` | Batch trust lookup for up to 100 entity refs in one round trip. Use before fanning out across multiple sources/tools. |
| `score_history(type, external_id, window, bucket)` | Time-bucketed score trend — the "is X getting worse?" lens. Pair with `retrieve(since=...)` to inspect the events behind a drop. |
| `retrieve(type, external_id, query?, k, ...)` | Past events for one entity, optionally ranked by similarity to a query. Rationales + task truncated to 200 chars. |
| `rank(capability_tag, rank_by, k, ...)` | Cross-entity ranking on a chosen dimension within a known capability tag. The "who's the [adj]?" lens. |
| `discover(query, k, ...)` | Free-text task → ranked entities. The "which tool fits this task?" lens. Distinct from `rank` (which needs the tag upfront). 503 → embeddings disabled (no fallback). |
| `capabilities(limit)` | List rated capability tags with event and entity counts. Cold-start fallback when `discover` returns nothing. |
| `get_rubric()` | Full scoring rubric: anchors, dimensions with inversion notes, weight semantics, examples. |
| `rate(type, external_id, score, weight, ...)` | Submit a rating after consuming/invoking. Per-field validation: dimension keys snake-case-regex'd (any are accepted; canonical seven aggregate cross-reviewer), metric keys regex'd, snake_case tag normalization, reserved-prefix check. On 401: invalidates cached key, re-mints, retries once. |

### Shortcut alternative

`uv run --locked mcp install server.py --name "TrustGraph"` writes the Desktop config entry automatically. Convenient for local-dev iteration, but behavior has shifted across `mcp[cli]` SDK versions and the entry still bakes in your clone's absolute path. The hand-edit above is the durable path.

### ⚠️ DNS-takeover warning

The default `TRUSTGRAPH_BASE_URL` is an experimental AWS App Runner subdomain (`mep39camvm.us-east-1.awsapprunner.com`). **If the subdomain is ever reclaimed, plaintext API keys would leak to the new owner on next call.** Override `TRUSTGRAPH_BASE_URL` to your own TrustGraph deployment for anything beyond local experimentation.

## What it does

- **Pre-check** (`scripts/tg-score`) — one-line reputation lookup before the agent commits to a marginal source.
- **Auto-rate** — a Claude Code `PostToolUse` hook builds a briefing from every WebFetch/WebSearch/MCP/curl call and feeds it to a Claude-Haiku-backed rater, which produces a calibrated `/v1/scores` body and queues it locally.
- **Auto-flush** — a `Stop` hook submits the queue as one batch when the session ends.
- **Manual queries** — `scripts/tg-retrieve` and `scripts/tg-rate` for ad-hoc use.

All of this happens outside the agent's conversation. The user sees nothing trustgraph-related in chat. The skill's content lives in `SKILL.md` + `references/` and is portable; only the hook registration is Claude Code-specific.

## Rater backends

The rater (`scripts/tg-judge-and-rate`) has two backends. Pick one at install time, or override per-session via `TG_RATER_BACKEND`.

| Backend | Auth | Cost per rating | Latency | Best for |
|---|---|---|---|---|
| `api`        | Anthropic API key | ~$0.0003 cached, ~$0.001 cold | ~2s | Heavy use; you have an API key |
| `claude-cli` | Claude Code subscription (claude.ai login) | ~$0.02–0.07 (subscription-billed) | ~20s | Light use; no API-key setup wanted |

The `api` backend hits `api.anthropic.com` directly with a tight tool-use prompt — fast, cheap, requires a key from `console.anthropic.com`. The `claude-cli` backend shells out to `claude -p` and uses whatever auth Claude Code is logged in with — no separate key, but ~60–200× more expensive per call and ~10× slower due to Claude Code's process+context overhead.

## Requirements

- Claude Code (the CLI; the hook system is Claude Code-specific)
- `python3`, `curl`, `bash` on `PATH`
- For the **api** backend: an Anthropic API key (Haiku 4.5 is the default rater model)
- For the **claude-cli** backend: a Claude Code login (`claude /login` — works with claude.ai subscription)
- Network access to the TrustGraph deployment (default `https://mep39camvm.us-east-1.awsapprunner.com`; override via `TRUSTGRAPH_BASE_URL`)

## Install

```bash
bash skill/install.sh
```

The installer:

1. Copies the skill content from `skill/` to `~/.claude/skills/trustgraph/` (or wherever you pass as the first arg). The installed layout is flat — `SKILL.md`, `references/`, `scripts/` all at the top level of the destination.
2. Marks the wrapper scripts executable.
3. **Prompts for the backend** (or use `TG_RATER_BACKEND=api|claude-cli` to skip).
4. For `api`: prompts for `ANTHROPIC_API_KEY` (hidden input) and saves to `~/.trustgraph/anthropic-key`, mode 600. **Not** put in `settings.json` env — that would clash with Claude Code's own auth.
5. Persists the backend choice to `~/.claude/settings.json` env as `TG_RATER_BACKEND`.
6. Merges three hook entries into `~/.claude/settings.json` (`PostToolUse`, `PostToolUseFailure`, `Stop`).

After installing, **start a fresh Claude Code session** (or run `/hooks` in the current one) to register the hooks. Verify with:

```bash
~/.claude/skills/trustgraph/scripts/tg-score data_source https://example.com
# → 0.50 0.00 null    (uninformed prior — entity unknown)
```

Then ask Claude to use any MCP tool or fetch a URL. The hook will fire silently; check `~/.trustgraph/hook.log` for evidence.

## How it works

```
Claude Code tool call (WebFetch/MCP/curl)
        │
        ▼
PostToolUse hook fires (async)
        │
        ▼
scripts/tg-hook-postool
  • parses tool_input/response
  • extracts entity (URL or mcp://server)
  • builds briefing JSON
        │
        ▼
scripts/tg-judge-and-rate
  • dispatches to api or claude-cli backend
  • passes skill content as system prompt
  • gets back a structured /v1/scores body
        │
        ▼
scripts/tg-rate   →   ~/.trustgraph/queue.jsonl
        │
        ▼  (at session end)
Stop hook → scripts/tg-flush
        │
        ▼
POST /v1/scores/batch   →   TrustGraph deployment
```

Repo layout:

- `skill/SKILL.md` — procedural skeleton
- `skill/references/rubric.md` — score anchors, weight, dimensions, inversion rule
- `skill/references/examples.md` — four worked submissions
- `skill/references/queries.md` — `/v1/profile`, `/v1/retrieve`, `/v1/rank`, `/v1/capabilities`
- `skill/references/scoring-model.md` — decay + confidence accrual
- `skill/scripts/tg-score` `tg-rate` `tg-flush` `tg-retrieve` `tg-score-batch` `tg-discover` `tg-history` — manual wrappers
- `skill/scripts/tg-doctor` — one-shot install/runtime health check (key file, queue, rater backend, API reachability)
- `skill/scripts/tg-judge-and-rate` — rater (both backends)
- `skill/scripts/tg-hook-postool` — PostToolUse hook entry point
- `skill/scripts/mint-key.sh` — mint a TrustGraph API key (shared with the MCP server)
- `skill/install.sh`, `skill/uninstall.sh`, `skill/update-skill.sh` — setup / removal / update
- `mcp-server/` — TrustGraph MCP server (10 tools)
- `mcp-server/openapi.snapshot.json` + `mcp-server/spec-check.sh` — drift guard against silent upstream API renames
- `docs/MCP-PLAN.md`, `docs/MIGRATION-PLAN.md`, `docs/REVIEW-REPORT.md`, `docs/REVIEW-ACTION-PLAN.md` — historical design, migration, review, and action records

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `TG_RATER_BACKEND` | (set by install to `api` or `claude-cli`) | `api` \| `claude-cli` \| `auto` |
| `ANTHROPIC_API_KEY` | (read from `~/.trustgraph/anthropic-key`) | For the api backend. NOT in `settings.json` env — keeps it out of Claude Code's auth path. |
| `TG_ANTHROPIC_KEY_FILE` | `~/.trustgraph/anthropic-key` | Override the key-file path |
| `TG_RATER_MODEL` | `claude-haiku-4-5-20251001` | Override the rater model |
| `TRUSTGRAPH_BASE_URL` | `https://mep39camvm.us-east-1.awsapprunner.com` | Override if you run your own TrustGraph deployment |
| `TRUSTGRAPH_API_KEY` | (auto-minted on first flush) | Persists at `~/.trustgraph/keys/<host>.key` by default (URL-scoped so a key minted against one host isn't reused against another) |
| `TRUSTGRAPH_MINT_SCRIPT` | (clone-relative `<server.py-dir>/../skill/scripts/mint-key.sh`) | Path to the read-or-mint-and-persist script the MCP shells out to |
| `TRUSTGRAPH_DEBUG_LOG` | (unset → no log) | When set, append-only JSONL side log (mode 0o600) with one line per HTTP call from server.py + per chunk POST from tg-flush. Use when debugging "why isn't this working". |
| `TRUSTGRAPH_QUEUE` | `~/.trustgraph/queue.jsonl` | Override the queue file location |
| `TRUSTGRAPH_KEY_FILE` | (derived: `~/.trustgraph/keys/<host>.key` per the deployment URL) | Override the persisted key location |
| `TRUSTGRAPH_NESTED` | (unset) | Recursion guard. If `=1`, hooks bail out silently. Set automatically by `claude-cli` backend on its child process. |

## Disable / uninstall

Temporary disable (one session):

```jsonc
// in ~/.claude/settings.json
"disableAllHooks": true
```

Full uninstall:

```bash
bash ~/.claude/skills/trustgraph/uninstall.sh
# Optional: rm -rf ~/.claude/skills/trustgraph  ~/.trustgraph
```

## Known limitations

- Hooks fire on every Bash tool call. The script filters by network-verb (curl/wget/gh api/etc.) and exits silently for non-network commands. Adds ~10–20 ms per Bash call.
- The rater can occasionally produce mildly hallucinated rationale text (anchored to the briefing, with confabulation around it). The structural fields — score, weight, dimensions, failure_modes — are reliable; the prose rationale is best-effort.
- `/v1/scores` has no delete endpoint, so a misfire becomes a stale event in TrustGraph.
- The Claude Code skill is invisible (hooks); the Claude Desktop MCP is visible in chat (tool calls). MCP-side ratings depend on the model voluntarily calling `score` / `rate` — even with proactive description text, expect a lower fire rate than the deterministic hook path. Watch first-use sessions for under-firing and consider pairing the MCP with a claude.ai skill that primes proactive use at conversation start.

## License / authorship

Built collaboratively in a Claude Code session. Adapt freely.
