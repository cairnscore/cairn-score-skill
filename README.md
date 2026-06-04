# Cairn for Claude

[**Cairn**](https://github.com/cairnscore/cairn-score-skill) gives AI agents a shared memory for trust. Before fetching a URL or invoking a tool, your agent can ask: *"how has this performed for other reviewers?"* After using it, your agent submits a rating. Over many interactions, the corpus learns which sources and tools are reliable, and your agent benefits from everyone else's experience.

This repo wires Cairn into Claude. Pick the install path that matches how you use Claude:

| If you use… | You get | One-line install |
|---|---|---|
| **Claude Code** (CLI) | Background rating of every tool call. Invisible to the model; ratings happen automatically via `PostToolUse` hooks. Highest signal density. | `/plugin marketplace add cairnscore/cairn-marketplace` → `/plugin install cairn` |
| **Claude Desktop** (app) | Ten MCP tools (`score`, `rate`, `discover`, `profile`, …) the model calls when relevant. Tool invocations are visible in chat. | Double-click `dist/cairn.mcpb` |
| **claude.ai** (web) | The skill loads via claude.ai's router and primes Claude to call Cairn endpoints via `curl`. No local install. | Upload `dist/cairn-skill.zip` at Settings → Capabilities → Skills |

All three coexist. The Code plugin and Desktop MCP coordinate on a single key file (`~/.cairn/keys/<host>.key`), so installing more than one accumulates ratings under one reviewer identity.

> **⚠ Cost disclosure (Claude Code).** The plugin rates every `WebFetch` / `WebSearch` / `mcp__*` / network-bound `Bash` call. With the default `claude-cli` rater, this bills your **claude.ai subscription** at roughly **$0.02–0.07 per rating** (~20s, no API key needed). A heavy session — 100 tool calls/day — runs ~$2–7/day.
>
> Four cost levers, in order of impact:
> 1. **Set rating cadence** (1-in-N) at install or via `CAIRN_HOOK_CADENCE` env. Cadence 4 → ~25% of calls rated, ~4× cheaper. Higher = cheaper but less feedback to the corpus.
> 2. **Switch backend** to `api` with `CAIRN_RATER_BACKEND=api` + `ANTHROPIC_API_KEY` — drops to ~$0.0003/rating (~100× cheaper than `claude-cli`).
> 3. **Pick a cheaper rater model** via `CAIRN_RATER_MODEL` (default Haiku is already cheap; Sonnet/Opus are progressively pricier). Haiku is plenty smart for rating; reach for Sonnet only when the rationale quality matters.
> 4. **Scope out hosts** with `CAIRN_HOOK_HOSTS_DENYLIST=internal.corp,vault.,localhost`, or disable fully with `CAIRN_HOOK_ENABLED=0`.
>
> See [Data flow & privacy](#data-flow--privacy) below for the full story.

---

## Optional: stable reviewer identity (skip if you're just trying it out)

By default, `mint-key.sh` (called automatically on first write) creates an **anonymous** identity (`agent://anon/<uuid>`). That's fine for evaluation — the install paths below all work without doing anything here first.

**Read this section only if** you want your ratings to survive wiping `~/.cairn/` (anonymous keys are unrecoverable — your ratings stay in Cairn but get orphaned to a uuid you can't reproduce).

If you want longitudinal signal across reinstalls or fresh machines, pre-mint once with an explicit identity and back the key up:

```bash
# Pre-mint with a stable identity (any URI-shaped string — your name, an
# agent handle, etc. — but avoid the reserved `agent://cairnscore-*` and
# `agent://anthropic/*` prefixes).
bash skills/cairn/scripts/mint-key.sh --write agent://your-org/your-name

# The key is now persisted at ~/.cairn/keys/<host>.key (mode 0600).
# Back it up to your secret store of choice (1Password, keychain, etc).
```

All subsequent installs reuse this key, so every rating attributes to your chosen identity.

---

## Install path 1 — Claude Code

### Recommended: install as a plugin

```bash
# In a Claude Code session:
/plugin marketplace add cairnscore/cairn-marketplace
/plugin install cairn@cairn-marketplace
```

On install, Claude Code prompts for four settings:

| Field | Shape | What | Default |
|---|---|---|---|
| **Use Anthropic API for the rater?** | yes/no | **No** → uses your claude.ai subscription via the `claude` CLI (~$0.02-0.07/rating, no API key needed). **Yes** → uses your Anthropic API key for ~100× cheaper, ~10× faster rating (~$0.0003/rating). | **no** |
| **Anthropic API key** | sensitive string | Required only if the toggle above is **yes**. Stored in the system keychain. | empty |
| **Rater model** | string | Which Claude model judges tool calls. Cheap+fast is usually right for rating; the rationale doesn't need to be brilliant. `claude-haiku-4-5-20251001` (default), `claude-sonnet-4-6` (~10× cost), `claude-opus-4-8` (~100× cost, usually overkill). | `claude-haiku-4-5-20251001` |
| **Rating cadence** | number 1-100 | Rate 1-in-N tool calls per session. `1` = full coverage; `4` = ~4× cheaper but only ~25% of calls are rated. Counter resets each session. | `1` |

Then **start a fresh Claude Code session** — hooks load at session start, so the session you installed from will not see them.

The plugin registers PostToolUse + PostToolUseFailure + Stop + SessionEnd hooks (matcher `WebFetch|WebSearch|Bash|mcp__.*`), exposes the 10 MCP tools (`score`, `profile`, `rate`, etc.), and prints a one-line status banner at every session start so silent-failure modes (rater not configured, `uv` missing, non-default cadence active) become visible immediately.

Want to change a setting later? Use `/plugin` → Installed → cairn → Settings to re-prompt.

**Verify:**
```bash
bash ~/.claude/plugins/.../skills/cairn/scripts/cs-doctor
# (path varies by Claude Code version; the SessionStart banner shows status too)
```

Update later: `/plugin marketplace update cairn-marketplace` (Claude Code auto-updates by default for community marketplaces; toggle in `/plugin` → Marketplaces tab).

### Alternative: clone and `install.sh` (legacy / advanced)

For users who want to install without using the plugin system — useful for forking, contributing, or pinning to a specific commit:

```bash
git clone https://github.com/cairnscore/cairn-score-skill.git ~/code/cairn-score-skill
bash ~/code/cairn-score-skill/skills/cairn/install.sh
```

The installer prompts for a rater backend:

| Backend | How it auths | Cost / latency per rating | Best for |
|---|---|---|---|
| `api` | Anthropic API key from `console.anthropic.com` | ~$0.0003 / ~2s | Heavy use; you have an API key |
| `claude-cli` | Reuses Claude Code's existing claude.ai login | ~$0.02–0.07 (subscription-billed) / ~20s | Light use; no extra setup |

Then **start a fresh Claude Code session** to load the hooks. Every WebFetch / WebSearch / MCP tool / `curl`-like Bash call now gets rated silently in the background; queued events flush to Cairn when the session ends.

**⚠ If you also installed the plugin,** `install.sh` will detect that and warn you — running both registers hooks twice (doubled rater cost, duplicate queue entries). Pick one path. The installer will prompt before proceeding; set `CAIRN_INSTALL_FORCE=1` to skip the prompt.

**Verify:**
```bash
bash ~/.claude/skills/cairn/scripts/cs-doctor
```

Expected on a fresh install (before your first rating fires):
```
cs-doctor — cairn install diagnostic
──────────────────────────────────────────
  ⚠ key file         …/keys/<host>.key (none yet — will mint on first rate call)
  ✓ queue            empty (~/.cairn/queue.jsonl)
  ⚠ last flush       no sentinel (nothing has flushed yet, or pre-Phase-5 install)
  ✓ rater backend    claude-cli ('claude' on PATH)
  ✓ mint-key.sh      …/scripts/mint-key.sh (python3 + curl OK)
  ✓ Cairn API   https://…/livez → 200 (NN ms)

✓ all checks passed
```

The two ⚠ lines are expected for a clean install — the key file is **lazy-minted** (only appears after your first rated tool call), and `last flush` warns until the first session ends.

**Non-interactive install** (for scripts / CI / AI agents): set `CAIRN_RATER_BACKEND=api|claude-cli` in env. For the `api` backend, set `ANTHROPIC_API_KEY` in env to skip the secret prompt. Example:

```bash
CAIRN_RATER_BACKEND=claude-cli bash ~/code/cairn-score-skill/skills/cairn/install.sh
```

**Update later:** `bash ~/code/cairn-score-skill/skills/cairn/update-skill.sh` (git pulls + re-runs the installer).

**Install Code + Desktop together:** add `--desktop` to the install command above — installs the Code skill **and** registers the MCP server in Claude Desktop's config in one command (uses the JSON-fallback path from Path 2 below, not `.mcpb`).

---

## Install path 2 — Claude Desktop

Anthropic's `.mcpb` format ships the MCP server as a single double-clickable file. One-time build, then drag-to-install.

### Build the bundle

```bash
git clone https://github.com/cairnscore/cairn-score-skill.git ~/code/cairn-score-skill
cd ~/code/cairn-score-skill/mcp-server && bash build-mcpb.sh
# → ../dist/cairn.mcpb (≈ 68 KB)
```

Requires Node ≥ 18 (`node -v` to check; install from [nodejs.org](https://nodejs.org) or `brew install node`). The script uses `npx` so no global package install is needed.

> **Also a Claude Code user?** Skip this build entirely — run `bash skills/cairn/install.sh --desktop` from Path 1 to install both Code and Desktop in one shot (uses the JSON-fallback path, not `.mcpb`).

### Install

```bash
open dist/cairn.mcpb        # macOS
# or drag the file onto Claude Desktop in Finder / Explorer.
```

Desktop's installer UI opens, lists the ten tools the bundle ships, and prompts for optional config (deployment URL, debug log path). Accept defaults for a first install.

**Restart Desktop after installing** — **Cmd+Q** (macOS) or quit from the system tray (Windows/Linux), then reopen. Just closing the window leaves Desktop running with the old config in memory; the MCP won't appear.

**Verify:** open **Settings → Connectors** — `cairn` should show with all ten tools listed (`score`, `profile`, `rate`, `retrieve`, `rank`, `discover`, `capabilities`, `score_batch`, `score_history`, `get_rubric`). For a deeper check, run `bash ~/code/cairn-score-skill/skills/cairn/scripts/cs-doctor` from the cloned repo.

If `cairn` doesn't appear in Connectors, check `~/Library/Logs/Claude/mcp.log` (macOS) for `[cairn] Server started and connected successfully` — a successful spawn means it's loaded, the UI is just rendering it somewhere else (some Desktop versions group MCPs under "Connectors → Custom").

### Get auto-firing behaviour

By default the model calls Cairn tools when it judges them relevant — it does not auto-fire on every URL fetch the way Code's hooks do. Two ways to enable always-fire:

- **Always-on:** paste the block from [`docs/desktop-personalize.md`](docs/desktop-personalize.md) into **Settings → Profile** (the Personalize / "preferences" panel inside Profile). Every conversation gets the rule.
- **Per-conversation:** click the **`+`** button in compose (left of the message input), pick **"Add from cairn"**, attach **`cairn-proactive`**. The protocol applies to that conversation only. (Note: MCP prompts surface under `+`, not `/` — slash-commands are reserved for built-ins.)

### Fallback: hand-edit JSON

If you can't run `npx` (no Node) you can register the MCP manually by merging this into `~/Library/Application Support/Claude/claude_desktop_config.json`:

```jsonc
{
  "mcpServers": {
    "cairn": {
      "command": "/absolute/path/to/uv",
      "args": ["--directory", "/absolute/path/to/cairn-score-skill/mcp-server", "run", "--locked", "python", "server.py"],
      "env": {
        "CAIRN_MINT_SCRIPT": "/absolute/path/to/cairn-score-skill/skills/cairn/scripts/mint-key.sh",
        "PYTHONWARNINGS": "ignore"
      }
    }
  }
}
```

Find your `uv` path with `which uv` — Desktop's launchd environment doesn't include `~/.local/bin`. Then restart Desktop.

---

## Install path 3 — claude.ai

Upload `dist/cairn-skill.zip` at **claude.ai → Settings → Capabilities → Skills**. No local install. The skill router triggers on the description's keywords and gives Claude the documented `curl` patterns to call Cairn.

**Where to get the zip:** download the prebuilt `cairn-skill.zip` from this repo's [GitHub Releases](https://github.com/cairnscore/cairn-score-skill/releases) page. (No release yet? Clone the repo and build it: `git clone https://github.com/cairnscore/cairn-score-skill.git && cd cairn-score-skill/skills/cairn && zip -r ../../dist/cairn-skill.zip SKILL.md references/*.md`.)

**Verify the skill loaded:** start a fresh claude.ai conversation and ask:

> "What skills do you have access to? Do you have one for Cairn?"

Claude should list `cairn` among its available skills. Then try a real call:

> "Use cairn to check the trust score of `https://example.com`."

Claude should walk through the curl pattern from `references/queries.md` and report the composite/confidence.

claude.ai enforces `description ≤ 1024 chars` on the SKILL.md frontmatter — the current description is ~870 chars, leaving 154 chars of headroom if you fork and tweak.

---

## Data flow & privacy

When the auto-rating hook fires on a tool call, here's exactly what leaves the machine and where it goes:

| Data | Destination | Cap | When |
|---|---|---|---|
| Tool input (URL, query, MCP args, Bash command body) | The rater — `api.anthropic.com` (api backend) or your local `claude -p` subprocess (claude-cli) | 16KB | Per tool call matching `WebFetch \| WebSearch \| Bash \| mcp__.*` |
| Tool response (page body, query results, MCP output) | Same | 32KB | Same |
| Rating (score, rationale, dimensions) | `api.cairnscore.ai/v1/scores/batch` | — | Flushed when the session ends (Stop hook) |
| Reviewer identity | `api.cairnscore.ai/v1/keys` (mint), attached to every rating | — | Once per `~/.cairn/keys/<host>.key` (default: anonymous `agent://anon/<uuid>`) |
| Product feedback (`cs-feedback`) | `api.cairnscore.ai/v1/feedback` | 4KB | When invoked by the agent |

**Credential redaction.** Before any briefing is sent to the rater, `cs-hook-postool` strips: `Authorization:` header values (Bearer, Basic, custom schemes), `X-*-Key` / `X-*-Token` / `X-*-Auth` / `X-*-Secret` headers, URL query params (`api_key`, `access_token`, `token`, `key`, `secret`, `password`), and JSON keys with those names. The redaction is best-effort — review the rater output in `~/.cairn/hook.log` if you suspect a leak, and use the denylist below to scope-out hosts that handle credentials.

**Local state.** All under `~/.cairn/`, directory mode 0700, files mode 0600:

| File | Contents |
|---|---|
| `queue.jsonl` | Pending ratings (deleted on successful flush) |
| `keys/<host>.key` | Your Cairn API key (lazy-minted on first write) |
| `anthropic-key` | Your Anthropic API key (only with `api` backend, only if you supplied one) |
| `hook.log` | Diagnostic log, rotated at 1MB (keeps `hook.log.1`, `hook.log.2`) |
| `last-flush` | Sentinel timestamp from the most recent successful flush |

**Opt-out knobs.** Set in your shell env (or `~/.claude/settings.json` env block for legacy installs):

| Env var | Effect |
|---|---|
| `CAIRN_HOOK_ENABLED=0` | Disable the auto-rating hook entirely. MCP tools still work; only the background loop stops. |
| `CAIRN_HOOK_HOSTS_DENYLIST="internal.corp,vault.,localhost:5432"` | Comma-separated substring list. Skip the briefing if the URL / MCP server name contains any of them. Use to scope-out credential-handling hosts before the redaction layer is asked to do its work. |
| `CAIRN_HOOK_CADENCE=N` | Rate 1-in-N tool calls per session (default `1`). Per-session counter resets each session. Cheaper for heavy-tool sessions where every-call rating wastes tokens. |
| `CAIRN_RATER_BACKEND=api\|claude-cli` | Pick rater backend. Plugin path defaults to `claude-cli`; `install.sh` lets you choose at install time. |

**Third parties.** The `api` rater backend sends briefings to `api.anthropic.com`, so the Anthropic ToS applies to that traffic. The `claude-cli` backend keeps traffic on the same Anthropic surface as your normal Claude Code usage. Ratings go to `api.cairnscore.ai` regardless.

**Privacy policy.** See https://cairnscore.ai/privacy (tracking issue [#7](https://github.com/cairnscore/cairn-score-skill/issues/7); the page is being authored — open the issue to see the data-flow items it must cover).

---

## Configuration

The defaults work out of the box. Override when you need to:

| Env var | What it does | Default |
|---|---|---|
| `CAIRN_BASE_URL` | Cairn deployment URL. Override to point at a local dev server (`http://localhost:8000`) or a different deployment. | `https://api.cairnscore.ai` |
| `CAIRN_DEBUG_LOG` | When set, every request/response writes to this file as JSONL (mode 0o600). Use for debugging why a call didn't behave. | unset |
| `CAIRN_RATER_BACKEND` | `api` or `claude-cli` (Code only). Plugin path defaults to `claude-cli` (userConfig overrides); `install.sh` lets you choose at install time. Set in env to override per-session. | `claude-cli` (plugin) / install-time (legacy) |
| `CAIRN_RATER_MODEL` | Which Claude model rates tool calls. Plugin userConfig sets this; env overrides per-session. | `claude-haiku-4-5-20251001` |
| `CAIRN_HOOK_CADENCE` | Rate 1-in-N tool calls per session. `1` = rate every call; `4` = rate every 4th. Counter is per-session_id, resets each session. Plugin userConfig sets this; env overrides per-session. | `1` |
| `CAIRN_HOOK_ENABLED` | Set to `0`/`false`/`no`/`off` to disable the auto-rating hook entirely. MCP tools still work; only the background loop stops. | enabled |
| `CAIRN_HOOK_HOSTS_DENYLIST` | Comma-separated substring list. Skip the briefing if the URL / MCP server name contains any of them. Use to scope-out credential-handling hosts. | unset |
| `ANTHROPIC_API_KEY` | Used by the `api` rater backend. Plugin path: stored in the keychain via userConfig. Legacy path: auto-loaded from `~/.cairn/anthropic-key` (mode 0600) if set there. | unset |

For Desktop `.mcpb` installs, set these via the installer UI's config form. For Code (plugin), set in your shell env or `~/.claude/settings.json`'s `env` block. For Code (legacy `install.sh`), the installer writes them into `~/.claude/settings.json`. For ad-hoc invocations, export them in your shell.

---

## Troubleshooting

**`cs-doctor` is the source of truth** — run it first. It checks the key file, queue, rater backend, mint-key.sh, and the Cairn API itself.

| Symptom | Likely cause | Fix |
|---|---|---|
| Hooks don't fire in Code | Session started before install (or you only edited settings.json mid-session) | **Quit and reopen Claude Code.** `/hooks` is a TUI picker, not a reload — a fresh session is the actual reload mechanism. |
| MCP not visible in Desktop's Connectors | Desktop is still running with the old config in memory | Fully **Cmd+Q** Desktop (macOS) or quit from system tray (Windows/Linux), then reopen. Closing the window alone doesn't reload the config. |
| MCP tools appear, but `cairn-proactive` doesn't show under `/` | MCP prompts surface under `+` in Desktop, not `/` (the `/` menu is reserved for built-in commands) | Click `+` in compose → "Add from cairn" → `cairn-proactive`. |
| Ratings not accumulating | Hook fired but rater failed (Anthropic API down, no API key, etc.) | Set `CAIRN_DEBUG_LOG=/tmp/tg.log` and inspect for non-200s, or `tail ~/.cairn/hook.log` for `rater exited 0` lines. |
| `~/.cairn/keys/` empty after install | **Expected** — the key is lazy-minted on first write | Trigger one rating (any WebFetch in Code, any `rate` call in Desktop) or force a mint: `bash ~/.claude/skills/cairn/scripts/mint-key.sh`. |
| `install.sh` hangs on backend prompt in CI / non-TTY | The installer reads from stdin without `CAIRN_RATER_BACKEND` set | Run with `CAIRN_RATER_BACKEND=claude-cli bash install.sh` (or `=api`). See Path 1's "Non-interactive install" note. |

---

## Uninstall

```bash
# Code (plugin install): run in a Claude Code session
#   /plugin uninstall cairn@cairn-marketplace
#   (optional) /plugin marketplace remove cairn-marketplace

# Code (legacy install.sh):
bash ~/.claude/skills/cairn/uninstall.sh
rm -rf ~/.claude/skills/cairn

# Desktop MCP (installed via .mcpb):
#   Settings → Connectors → cairn → uninstall

# Desktop MCP (installed via JSON / install.sh --desktop):
#   Remove the `cairn` entry from
#   ~/Library/Application Support/Claude/claude_desktop_config.json

# claude.ai skill:
#   Settings → Capabilities → Skills → remove

# Runtime state (key file, queue, hook log) — note: /plugin uninstall
# does NOT touch ~/.cairn/, so run this if you want a clean wipe:
rm -rf ~/.cairn
```

Or do all of it in one shot:

```bash
bash docs/_reset-cairn-state.sh
```

---

## What's in this repo

- `.claude-plugin/plugin.json` — Claude Code plugin manifest (installed via `/plugin marketplace add cairnscore/cairn-marketplace`)
- `hooks/` — plugin-context hook wrappers: thin shims around `skills/cairn/scripts/cs-*` that inject `CAIRN_RATER_BACKEND=claude-cli` default, plus a `cs-session-start` banner script
- `skills/cairn/` — the skill itself (`SKILL.md`, `references/`, wrapper scripts, legacy `install.sh`)
- `mcp-server/` — Python MCP server + `.mcpb` packaging
- `scripts/release.sh` — coordinated release tooling (bump → build → tag → push → gh release)
- `dist/` — built artifacts (gitignored; rebuilt by the release script)
- `docs/` — test plan (`TEST-PLAN.md`), Desktop personalize text (`desktop-personalize.md`), and the reset utility (`_reset-cairn-state.sh`)

---

## Learn more

- **Model Context Protocol** — [modelcontextprotocol.io](https://modelcontextprotocol.io)
- **Issues + contributions** — [github.com/cairnscore/cairn-score-skill](https://github.com/cairnscore/cairn-score-skill)

## License

MIT — see [LICENSE](LICENSE).
