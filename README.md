# trustgraph — reputation tooling for Claude Code + Claude Desktop

Two surfaces over the same TrustGraph reputation API:

- **`skill/`** — a Claude Code skill that rates every external resource your agent touches (WebFetch, WebSearch, MCP tools, curl invocations) **invisibly in the background** via `PostToolUse` hooks. The model never sees TrustGraph in chat.
- **`mcp-server/`** — an MCP server that exposes the same trust capabilities to **Claude Desktop** (and any MCP-capable host: Cursor, Zed, Continue, the API directly) as six callable tools. The model chooses when to invoke; tool calls are visible in chat.

Both surfaces share `~/.trustgraph/` state — same key file, same reviewer identity (first-mint-wins), so ratings accumulate under one signal regardless of which surface produced them.

## Quick install — Claude Code skill

```bash
git clone https://github.com/GusEllerm/trustgraph-skill.git ~/code/trustgraph-skill && \
  bash ~/code/trustgraph-skill/skill/install.sh
```

Clone the repo anywhere convenient (the example uses `~/code/`); the installer copies the skill content from `skill/` to `~/.claude/skills/trustgraph/` and registers the hooks.

The installer prompts for a rater backend:
- **`api`** — direct Anthropic API. Needs an API key from `console.anthropic.com`. Cheap, fast.
- **`claude-cli`** — uses Claude Code's existing auth (claude.ai subscription). No API key needed. Slower, more subscription-quota.

Then start a fresh Claude Code session. Hooks fire automatically.

To update later: `bash ~/code/trustgraph-skill/skill/update-skill.sh` (the script does `git pull` in the clone and re-runs `install.sh`).

## Claude Desktop (MCP server)

The same TrustGraph capabilities are exposed under `mcp-server/` as a six-tool MCP server: `score`, `retrieve`, `rank`, `capabilities`, `get_rubric`, `rate`.

Unlike the skill — which hooks in invisibly on every tool call — MCP tool calls are visible in chat. The model decides when to invoke; the agent's standing context carries the tool descriptions (~1500 tokens for the six, ~500 of which is the rubric condensate embedded in `rate`).

### Install (hand-edit JSON — recommended)

Hand-edit `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS; adjust path on other OSes) and merge the `trustgraph` entry into `mcpServers`:

```jsonc
{
  "mcpServers": {
    "trustgraph": {
      "command": "uv",
      "args": [
        "--directory", "/absolute/path/to/trustgraph-skill/mcp-server",
        "run", "--locked",
        "python", "server.py"
      ],
      "env": {
        // Required: path to the shared mint-key.sh script.
        "TRUSTGRAPH_MINT_SCRIPT": "/absolute/path/to/trustgraph-skill/skill/scripts/mint-key.sh",

        // Recommended: silence third-party deprecation noise on stdout.
        "PYTHONWARNINGS": "ignore"

        // Optional: override the TrustGraph deployment URL.
        // See the DNS-takeover warning below — strongly recommended for any
        // non-throwaway use.
        // "TRUSTGRAPH_BASE_URL": "https://your-trustgraph-deployment.example",

        // Optional: enable side log of every request/response (mode 0600).
        // "TRUSTGRAPH_DEBUG_LOG": "/Users/you/.trustgraph/mcp-debug.log",

        // Not set here: TRUSTGRAPH_API_KEY (auto-minted on first `rate` call
        // via TRUSTGRAPH_MINT_SCRIPT; provide it only for stable identity).
      }
    }
  }
}
```

Replace both absolute paths with your clone location. Restart Claude Desktop after editing. Verify by opening the Desktop server-log panel — the `trustgraph` MCP should appear with all six tools listed.

The MCP shares `~/.trustgraph/api-key` with the Code skill via the refactored `mint-key.sh`, which owns read-or-mint-and-persist under `fcntl.flock`. First surface to mint owns the reviewer identity baked into the key; both surfaces accumulate ratings under that identity.

### Tools

| Tool | Purpose |
|---|---|
| `score(type, external_id, detail="summary"|"full")` | Reputation check before consuming a URL or MCP capability. `detail="full"` returns the combined profile (dimensions + top failure modes + top capability tags). |
| `retrieve(type, external_id, query?, k, ...)` | Past events for one entity, optionally ranked by similarity to a query. Rationales truncated to 200 chars. |
| `rank(capability_tag, rank_by, k, ...)` | Cross-entity ranking on a chosen dimension. The "who's the [adj]?" lens. |
| `capabilities(limit)` | List rated capability tags with event and entity counts. |
| `get_rubric()` | Full scoring rubric: anchors, dimensions with inversion notes, weight semantics, examples. |
| `rate(type, external_id, score, weight, ...)` | Submit a rating after consuming/invoking. Per-field validation: dimension key whitelist, metric key regex, snake_case tag normalization, reserved-prefix check. |

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
- `skill/scripts/tg-score` `tg-rate` `tg-flush` `tg-retrieve` — manual wrappers
- `skill/scripts/tg-judge-and-rate` — rater (both backends)
- `skill/scripts/tg-hook-postool` — PostToolUse hook entry point
- `skill/scripts/mint-key.sh` — mint a TrustGraph API key (shared with the MCP server)
- `skill/install.sh`, `skill/uninstall.sh`, `skill/update-skill.sh` — setup / removal / update
- `mcp-server/` — TrustGraph MCP server (in progress; see `MCP-PLAN.md`)
- `MCP-PLAN.md` — design plan for the MCP port (disposable scratch; removed once implementation lands)

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `TG_RATER_BACKEND` | (set by install to `api` or `claude-cli`) | `api` \| `claude-cli` \| `auto` |
| `ANTHROPIC_API_KEY` | (read from `~/.trustgraph/anthropic-key`) | For the api backend. NOT in `settings.json` env — keeps it out of Claude Code's auth path. |
| `TG_ANTHROPIC_KEY_FILE` | `~/.trustgraph/anthropic-key` | Override the key-file path |
| `TG_RATER_MODEL` | `claude-haiku-4-5-20251001` | Override the rater model |
| `TRUSTGRAPH_BASE_URL` | `https://mep39camvm.us-east-1.awsapprunner.com` | Override if you run your own TrustGraph deployment |
| `TRUSTGRAPH_API_KEY` | (auto-minted on first flush) | Persists at `~/.trustgraph/api-key` |
| `TRUSTGRAPH_QUEUE` | `~/.trustgraph/queue.jsonl` | Override the queue file location |
| `TRUSTGRAPH_KEY_FILE` | `~/.trustgraph/api-key` | Override the persisted key location |
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
