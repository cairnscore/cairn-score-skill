# Cairn for Claude

[**Cairn**](https://github.com/cairnscore/cairn-score-skill) gives AI agents a shared memory for trust. Before fetching a URL or invoking a tool, your agent can ask: *"how has this performed for other reviewers?"* After using it, your agent submits a rating. Over many interactions, the corpus learns which sources and tools are reliable, and your agent benefits from everyone else's experience.

This repo wires Cairn into Claude. Pick the install path that matches how you use Claude:

| If you use… | You get | One-line install |
|---|---|---|
| **Claude Code** (CLI) | Background rating of every tool call. Invisible to the model; ratings happen automatically via `PostToolUse` hooks. Highest signal density. | `bash skill/install.sh` |
| **Claude Desktop** (app) | Ten MCP tools (`score`, `rate`, `discover`, `profile`, …) the model calls when relevant. Tool invocations are visible in chat. | Double-click `dist/cairn.mcpb` |
| **claude.ai** (web) | The skill loads via claude.ai's router and primes Claude to call Cairn endpoints via `curl`. No local install. | Upload `dist/cairn-skill.zip` at Settings → Capabilities → Skills |

All three coexist. The Code skill and Desktop MCP coordinate on a single key file (`~/.cairn/keys/<host>.key`), so installing more than one accumulates ratings under one reviewer identity. The unified installer (`bash skill/install.sh --desktop`) sets up Code + Desktop in one command.

---

## Optional: stable reviewer identity (skip if you're just trying it out)

By default, `mint-key.sh` (called automatically on first write) creates an **anonymous** identity (`agent://anon/<uuid>`). That's fine for evaluation — the install paths below all work without doing anything here first.

**Read this section only if** you want your ratings to survive wiping `~/.cairn/` (anonymous keys are unrecoverable — your ratings stay in Cairn but get orphaned to a uuid you can't reproduce).

If you want longitudinal signal across reinstalls or fresh machines, pre-mint once with an explicit identity and back the key up:

```bash
# Pre-mint with a stable identity (any URI-shaped string — your name, an
# agent handle, etc. — but avoid the reserved `agent://cairnscore-*` and
# `agent://anthropic/*` prefixes).
bash skill/scripts/mint-key.sh --write agent://your-org/your-name

# The key is now persisted at ~/.cairn/keys/<host>.key (mode 0600).
# Back it up to your secret store of choice (1Password, keychain, etc).
```

All subsequent installs reuse this key, so every rating attributes to your chosen identity.

---

## Install path 1 — Claude Code

```bash
git clone https://github.com/cairnscore/cairn-score-skill.git ~/code/cairn-score-skill
bash ~/code/cairn-score-skill/skill/install.sh
```

The installer prompts for a rater backend:

| Backend | How it auths | Cost / latency per rating | Best for |
|---|---|---|---|
| `api` | Anthropic API key from `console.anthropic.com` | ~$0.001 / ~2s | Heavy use; you have an API key |
| `claude-cli` | Reuses Claude Code's existing claude.ai login | ~$0.02–0.07 (subscription-billed) / ~20s | Light use; no extra setup |

Then **start a fresh Claude Code session** — hooks load at session start, so the session you ran the installer from will not see them. (`/hooks` opens a TUI picker, it does not reload settings; a fresh session is the actual reload.)

Every WebFetch / WebSearch / MCP tool / `curl`-like Bash call now gets rated silently in the background; queued events flush to Cairn when the session ends.

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

The two ⚠ lines are expected for a clean install — the key file is **lazy-minted** (only appears after your first rated tool call), and `last flush` warns until the first session ends. Both clear to ✓ on their own after one rated session.

**Non-interactive install** (for scripts / CI / AI agents): set `CAIRN_RATER_BACKEND=api|claude-cli` in env to skip the backend prompt. For the `api` backend, set `ANTHROPIC_API_KEY` in env to skip the secret prompt. Example:

```bash
CAIRN_RATER_BACKEND=claude-cli bash ~/code/cairn-score-skill/skill/install.sh
```

**Update later:** `bash ~/code/cairn-score-skill/skill/update-skill.sh` (git pulls + re-runs the installer).

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

> **Also a Claude Code user?** Skip this build entirely — run `bash skill/install.sh --desktop` from Path 1 to install both Code and Desktop in one shot (uses the JSON-fallback path, not `.mcpb`).

### Install

```bash
open dist/cairn.mcpb        # macOS
# or drag the file onto Claude Desktop in Finder / Explorer.
```

Desktop's installer UI opens, lists the ten tools the bundle ships, and prompts for optional config (deployment URL, debug log path). Accept defaults for a first install.

**Restart Desktop after installing** — **Cmd+Q** (macOS) or quit from the system tray (Windows/Linux), then reopen. Just closing the window leaves Desktop running with the old config in memory; the MCP won't appear.

**Verify:** open **Settings → Connectors** — `cairn` should show with all ten tools listed (`score`, `profile`, `rate`, `retrieve`, `rank`, `discover`, `capabilities`, `score_batch`, `score_history`, `get_rubric`). For a deeper check, run `bash ~/code/cairn-score-skill/skill/scripts/cs-doctor` from the cloned repo.

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
        "CAIRN_MINT_SCRIPT": "/absolute/path/to/cairn-score-skill/skill/scripts/mint-key.sh",
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

**Where to get the zip:** download the prebuilt `cairn-skill.zip` from this repo's [GitHub Releases](https://github.com/cairnscore/cairn-score-skill/releases) page. (No release yet? Clone the repo and build it: `git clone https://github.com/cairnscore/cairn-score-skill.git && cd cairn-score-skill/skill && zip -r ../dist/cairn-skill.zip SKILL.md references/*.md`.)

**Verify the skill loaded:** start a fresh claude.ai conversation and ask:

> "What skills do you have access to? Do you have one for Cairn?"

Claude should list `cairn` among its available skills. Then try a real call:

> "Use cairn to check the trust score of `https://example.com`."

Claude should walk through the curl pattern from `references/queries.md` and report the composite/confidence.

claude.ai enforces `description ≤ 1024 chars` on the SKILL.md frontmatter — the current description is ~870 chars, leaving 154 chars of headroom if you fork and tweak.

---

## Configuration

The defaults work out of the box. Override when you need to:

| Env var | What it does | Default |
|---|---|---|
| `CAIRN_BASE_URL` | Cairn deployment URL. Override to point at a local dev server (`http://localhost:8000`) or a different deployment. | `https://api.cairnscore.ai` |
| `CAIRN_DEBUG_LOG` | When set, every request/response writes to this file as JSONL (mode 0o600). Use for debugging why a call didn't behave. | unset |
| `CAIRN_RATER_BACKEND` | `api` or `claude-cli` (Code skill only). Pick at install; set in env to override per-session. | (set by install) |

For Desktop `.mcpb` installs, set these via the installer UI's config form. For Code, they live in `~/.claude/settings.json`'s `env` block. For ad-hoc invocations, export them in your shell.

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
# Code skill:
bash ~/.claude/skills/cairn/uninstall.sh
rm -rf ~/.claude/skills/cairn

# Desktop MCP (installed via .mcpb):
#   Settings → Connectors → cairn → uninstall

# Desktop MCP (installed via JSON / install.sh --desktop):
#   Remove the `cairn` entry from
#   ~/Library/Application Support/Claude/claude_desktop_config.json

# claude.ai skill:
#   Settings → Capabilities → Skills → remove

# Runtime state (key file, queue, hook log):
rm -rf ~/.cairn
```

Or do all of it in one shot:

```bash
bash docs/_reset-cairn-state.sh
```

---

## What's in this repo

- `skill/` — Claude Code skill (`SKILL.md`, `references/`, wrapper scripts, installer)
- `mcp-server/` — Python MCP server + `.mcpb` packaging
- `dist/` — built artifacts (gitignored; rebuilt by the commands above)
- `docs/` — test plan (`TEST-PLAN.md`), Desktop personalize text (`desktop-personalize.md`), and the reset utility (`_reset-cairn-state.sh`)

---

## Learn more

- **Model Context Protocol** — [modelcontextprotocol.io](https://modelcontextprotocol.io)
- **Issues + contributions** — [github.com/cairnscore/cairn-score-skill](https://github.com/cairnscore/cairn-score-skill)

## License

MIT — see [LICENSE](LICENSE).
