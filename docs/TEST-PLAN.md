# cairn install test plan

Six install paths to exercise end-to-end. Tick boxes as you go. Each test is self-contained — the **Reset** step at the start of each clears any prior install state so tests don't bleed into each other.

**Repo clone path used in examples:** `/Users/gusellerm/Projects/cairn-score-skill`. Substitute your own if different.

---

## AI-run pre-pass (2026-05-26)

Sandbox-runnable steps were exercised end-to-end before this checklist landed in the user's hands. Three real bugs surfaced and were fixed in the same session — without those fixes, several of the steps below would have failed:

| Bug | Where | Fix |
|---|---|---|
| `uninstall.sh` left `CAIRN_RATER_BACKEND` env entry in `~/.claude/settings.json` | `skills/cairn/uninstall.sh` | Now strips the env entry along with the hooks |
| `mcpb pack` rejected our `manifest.json` (`prompts.0.text: Required` — static prompts need inline text, can't just point at the runtime `@mcp.prompt`) | `mcp-server/manifest.json` | Switched to `prompts_generated: true` — runtime registration via the MCP protocol still serves the `cairn-proactive` prompt; the install UI just won't show it statically. Future-work: extract prompt text into a shared source-of-truth file and embed in both `server.py` + the manifest. |
| `build-mcpb.sh` required `mcpb` to be globally installed (`npm i -g`) | `mcp-server/build-mcpb.sh` | Now falls back to `npx -y --package @anthropic-ai/mcpb mcpb …` so no global install needed |

**What the AI pass actually verified (so you don't need to repeat):**

| Test | Install | Verify | Smoke | Teardown |
|---|---|---|---|---|
| A — `install.sh` | ✓ | ✓ files + hooks + cs-doctor | ⊘ needs Code session | ✓ (after env-fix) |
| B — `install.sh --desktop` | ✓ | ✓ Code + Desktop entry + cs-doctor + spawn pre-flight | ⊘ needs Code + Desktop sessions | ✓ (after env-fix) |
| C — `.mcpb` build | ✓ via npx | ✓ bundle layout + manifest content | ⊘ needs Desktop UI to drag/install | n/a (build artifact only) |
| D — hand-edit JSON | ✓ | ✓ JSON validates + spawn command pre-flight succeeds | ⊘ needs Desktop session | ✓ |
| E — claude.ai zip | ✓ rebuild | ✓ contents (5 files, 39KB) | ⊘ needs claude.ai upload UI | n/a |
| F — coexistence (file-level) | ✓ via B | ✓ URL-scoped key path, `mint-key.sh` cache + `--remint`, debug log mode 0o600 + JSONL format, spec-check clean | ⊘ cross-surface rate test needs both Code + Desktop sessions | ✓ |

**What's left for you to do** (the ⊘ items above): the actual model-driven smoke prompts in Tests A, B, C, D, F. Each of those needs a real Claude session — opening Claude Code or Desktop, typing the test prompt, observing the model's tool-call behavior. Those are the only steps that can't be done from a script.

Everything else (install / verify state / teardown commands) is now known to work, on this machine, on this commit.

---

## Pre-flight (once, before starting)

- [ ] Repo cloned and current
  ```bash
  cd /Users/gusellerm/Projects/cairn-score-skill && git pull --ff-only && git log -1 --oneline
  ```
- [ ] `uv` on PATH
  ```bash
  which uv && uv --version
  ```
- [ ] `python3` ≥ 3.11 on PATH
  ```bash
  python3 --version
  ```
- [ ] Claude Code (`claude` CLI) installed and logged in **(only required for Tests A, B, F)**
  ```bash
  command -v claude && claude --version
  ```
- [ ] Claude Desktop installed (foreground app) **(only required for Tests B, C, D, F)**
- [ ] `npm` + `@anthropic-ai/mcpb` installed **(only required for Test C — .mcpb build)**
  ```bash
  command -v npm && command -v mcpb
  # if mcpb is missing:  npm i -g @anthropic-ai/mcpb
  ```
- [ ] Clean slate: no prior install state
  ```bash
  bash docs/_reset-cairn-state.sh
  # → prints `clean` on success. Idempotent — safe to re-run between tests.
  # Removes: ~/.claude/skills/cairn/, ~/.cairn/, cairn hooks
  # and CAIRN_* env from settings.json, mcpServers.cairn from
  # Claude Desktop config.
  ```

---

## Test A — Code skill via `install.sh` (interactive)

**Goal:** verify the Code-only install path works with the interactive backend prompt.

### Install

- [X] **Reset** (re-run the clean-slate block above if needed)
- [X] Run installer
  ```bash
  bash /Users/gusellerm/Projects/cairn-score-skill/skills/cairn/install.sh
  ```
- [X] When prompted, pick `2` for `claude-cli` backend (or `1` + provide an Anthropic API key if you prefer the API backend)
- [X] Installer prints `Installed (Claude Code skill).`

### Verify install state

- [X] Skill files in place
  ```bash
  ls ~/.claude/skills/cairn/  # expect: SKILL.md  references/  scripts/  install.sh  uninstall.sh  update-skill.sh  README.md  LICENSE
  ```
- [X] Hooks registered
  ```bash
  python3 -c "import json; c=json.load(open('$HOME/.claude/settings.json')); print(sorted(c.get('hooks',{}).keys()))"
  # expect: ['PostToolUse', 'PostToolUseFailure', 'Stop']
  ```
- [X] `cs-doctor` all green (last-flush will warn — that's expected before first flush)
  ```bash
  bash ~/.claude/skills/cairn/scripts/cs-doctor
  ```

### Smoke test (Code skill)

- [X] Quit and reopen Claude Code (or run `/hooks` in the current session)
- [X] Ask Claude: **"Fetch https://news.ycombinator.com and summarise the front page."**
- [X] After completion, check the hook log
  ```bash
  tail -50 ~/.cairn/hook.log
  # expect: "dispatching briefing (async)" + "rater exited 0"
  ```
- [X] End that session (close the terminal or run `/exit`); the `Stop` hook should flush. Re-run `cs-doctor` and look for `last flush: Xs ago`.

### Teardown

- [X] Uninstall
  ```bash
  bash ~/.claude/skills/cairn/uninstall.sh
  rm -rf ~/.claude/skills/cairn ~/.cairn
  ```

---

## Test B — `install.sh --desktop` (unified Code + Desktop)

**Goal:** verify one command installs both surfaces and they coexist.

### Install

- [X] **Reset** (from pre-flight block)
- [X] Run unified installer
  ```bash
  bash /Users/gusellerm/Projects/cairn-score-skill/skills/cairn/install.sh --desktop
  ```
- [X] Pick backend as before
- [X] Installer prints `registered → mcpServers.cairn` with absolute `uv` path

### Verify install state

- [X] Code skill present at `~/.claude/skills/cairn/`
- [X] Desktop config has the cairn entry
  ```bash
  python3 -c "import json; c=json.load(open('$HOME/Library/Application Support/Claude/claude_desktop_config.json')); print(json.dumps(c.get('mcpServers',{}).get('cairn'), indent=2))"
  ```
- [X] Backup file created with `bak.install-` prefix in the Claude Desktop config directory
  ```bash
  ls -1t "$HOME/Library/Application Support/Claude/" | grep "claude_desktop_config.json.bak.install-" | head -3
  # expect: one entry per --desktop run, newest first, timestamp matches the install
  ```

### Smoke test (Desktop side)

- [X] **Fully quit** Claude Desktop (Cmd+Q on macOS) and reopen
- [X] **Settings → Connectors** (newer Desktop builds) or **Settings → Developer → MCP** (older) — `cairn` should appear with an active/green status and the 10 tools listed under it. If you don't see it, check `~/Library/Logs/Claude/mcp.log` for `[cairn] Server started and connected successfully` — a successful spawn means it's loaded; just look harder in the UI (some versions group MCPs under "Connectors → Custom" or similar).
- [X] Tool picker in compose — start a new conversation, look for the 🛠/tools icon. The cairn tools should be reachable from there (grouped by source).
- [X] Type `/` in compose — **`cairn-proactive`** should appear in the slash-command picker
- [X] Test prompt: **"Tell me about the trust profile of `data_source / canary://known-good`."** — expect `profile` to be called, summary returned

### Smoke test (Code side, parallel)

- [X] In a Claude Code session, ask: **"Fetch https://example.com"** — hooks should fire silently
- [X] `cs-doctor` reports green for both key file (URL-scoped path) and queue

### Coexistence check

- [X] Both surfaces share `~/.cairn/keys/api.cairnscore.ai.key` — i.e. one reviewer identity for ratings from both
  ```bash
  # The key file is LAZY-MINTED — it only appears the first time something
  # calls a write endpoint (Code-side: trigger a rate via the smoke above
  # + end the session so Stop hook flushes; Desktop-side: any `rate` call).
  # If you just want to force-test the path without waiting, mint manually:
  bash ~/.claude/skills/cairn/scripts/mint-key.sh > /dev/null
  ls ~/.cairn/keys/
  # → expect: api.cairnscore.ai.key (47 bytes, mode 0600)
  # Calling mint-key.sh a second time returns the cached key — same identity
  # for whichever surface mints next.
  ```

### Teardown

- [X] Code-side uninstall
  ```bash
  bash ~/.claude/skills/cairn/uninstall.sh
  rm -rf ~/.claude/skills/cairn
  ```
- [X] Desktop-side: remove the MCP entry
  ```bash
  python3 -c "
  import json, os
  p = os.path.expanduser('~/Library/Application Support/Claude/claude_desktop_config.json')
  c = json.load(open(p))
  c.get('mcpServers', {}).pop('cairn', None)
  if 'mcpServers' in c and not c['mcpServers']: del c['mcpServers']
  json.dump(c, open(p,'w'), indent=2); open(p,'a').write('\n')
  print('cleaned')"
  ```
- [X] Wipe runtime state
  ```bash
  rm -rf ~/.cairn
  ```
- [X] Restart Claude Desktop so it forgets the now-removed MCP

---

## Test C — Desktop MCP via `.mcpb` (one-click production path)

**Goal:** verify the production install path the cairn project will eventually ship.

### Build

- [X] **Reset** (from pre-flight block)
- [X] Build the bundle
  ```bash
  cd /Users/gusellerm/Projects/cairn-score-skill/mcp-server && bash build-mcpb.sh
  ```
- [X] Expect output ending with `built ../dist/cairn.mcpb (<size>)`
- [X] Inspect what's inside (sanity)
  ```bash
  unzip -l /Users/gusellerm/Projects/cairn-score-skill/dist/cairn.mcpb
  # expect: manifest.json, pyproject.toml, uv.lock, server.py, bundled/mint-key.sh
  ```

### Install

- [X] Open the `.mcpb` in Claude Desktop
  ```bash
  open /Users/gusellerm/Projects/cairn-score-skill/dist/cairn.mcpb
  ```
- [X] Desktop's installer UI opens — review the tool list (10 tools), the prompt (1), and the user_config fields (deployment URL with the DNS-takeover note, debug log path)
- [X] Accept defaults and install
- [X] Desktop confirms install + may prompt to restart

### Verify

- [X] In compose, MCP indicator shows `cairn` with **10 tools**
- [X] `/` picker shows `cairn-proactive`
- [X] Settings → Developer (or Extensions) shows `Cairn` as installed

### Smoke

- [X] Pin the proactive prompt + test prompt: **"Tell me about the trust profile of `data_source / canary://known-good`."**
- [X] Verify it called `profile` and surfaced the LLM summary

### Teardown

- [X] Uninstall via Desktop's Extensions UI (look for a remove/uninstall control on the Cairn entry)
- [X] Wipe runtime state
  ```bash
  rm -rf ~/.cairn
  ```
- [X] Restart Desktop

---

## Test D — Desktop MCP via hand-edit JSON (fallback)

**Goal:** verify the fallback path still works for users without npm.

### Install

- [X] **Reset** (from pre-flight block)
- [X] Hand-edit `~/Library/Application Support/Claude/claude_desktop_config.json` and merge the block from `README.md` "Fallback: hand-edit JSON" section
- [X] Make sure to use the absolute `uv` path (`which uv` value)
- [X] Validate JSON
  ```bash
  python3 -c "import json; json.load(open('$HOME/Library/Application Support/Claude/claude_desktop_config.json')); print('valid')"
  ```

### Verify + smoke + teardown

- [X] Fully quit and reopen Claude Desktop
- [X] Verify same as Test C (10 tools, prompt selectable)
- [X] Smoke: canary profile test
- [X] Teardown: remove the JSON entry (same as Test B teardown) + wipe `~/.cairn`

---

## Test E — claude.ai web skill upload

**Goal:** verify the web-only install path works.

### Build the skill zip (if not already current)

- [X] Rebuild from current source
  ```bash
  cd /Users/gusellerm/Projects/cairn-score-skill/skills/cairn && \
    rm -f ../../dist/cairn-skill.zip && \
    zip -r ../../dist/cairn-skill.zip SKILL.md references/rubric.md references/examples.md references/queries.md references/scoring-model.md
  ```

### Install

- [X] Open `claude.ai` in browser → Settings → Capabilities → Skills (UI path may vary)
- [X] Upload `dist/cairn-skill.zip`
- [X] Skill appears in the list, with the description from `SKILL.md` frontmatter

### Smoke

- [X] In a new claude.ai conversation, ask a cairn-related question (e.g. **"Check the trust score of https://example.com using cairn"**)
- [X] Verify the skill loads (the description is the router signal) and Claude attempts the curl-based path documented in `references/queries.md`

### Teardown

- [X] Remove the uploaded skill from claude.ai → Settings → Capabilities → Skills

---

## Test F — Coexistence across all surfaces

**Goal:** verify that with Code skill + Desktop MCP both installed, ratings from each surface accrue under the same reviewer identity (URL-scoped key file is shared via `fcntl.flock`).

### Setup

- [X] **Reset** (from pre-flight block)
- [X] Install both via the unified command
  ```bash
  bash /Users/gusellerm/Projects/cairn-score-skill/skills/cairn/install.sh --desktop
  ```
- [X] Pick backend, restart Desktop, restart Code session

### Coexistence check

- [X] Submit a rating from Code-side first
  - In a Claude Code session, fetch any URL — hooks fire, rate gets queued
  - End session → Stop hook flushes
  - Note the API key path: `cat ~/.cairn/keys/api.cairnscore.ai.key` (47-char `tg_...` value)
- [X] Submit a rating from Desktop-side
  - In a Desktop conversation, ask Claude to rate something via `mcp__cairn__rate`
  - Verify it succeeds (no second mint happens)
- [ ] Confirm key file unchanged
  - Re-run `cat ~/.cairn/keys/...` — same 47-char value as before
- [ ] `cs-doctor` reports both queue activity AND a recent `last flush`

### Failure-mode probes (optional but worthwhile)

- [X] Concurrent rate: open two Code sessions, both hitting different URLs — verify both ratings accumulate (queue lock + fcntl ordering working)
- [X] Stale key: `chmod 000` the key file, attempt a `rate` from Desktop, verify the 401-retry kicks in (mints fresh key, retries, succeeds). Restore: `chmod 600`.
- [X] Debug log: set `CAIRN_DEBUG_LOG=/tmp/tg.log` in either install, drive one rate, verify `/tmp/tg.log` exists at mode 600 with one JSONL line per request

### Teardown

- [ ] Both uninstalls (Code via `uninstall.sh`, Desktop via JSON delete)
- [ ] Wipe `~/.cairn`
- [ ] Restart Desktop

---

## Tracking summary

| Test | Path | Done | Notes |
|---|---|---|---|
| A | Code skill via `install.sh` | Yes | |
| B | `install.sh --desktop` unified | Yes | |
| C | `.mcpb` one-click Desktop install | Yes | |
| D | Hand-edit JSON Desktop fallback | Yes | |
| E | claude.ai web skill upload | Yes | |
| F | Coexistence (Code + Desktop) | Yes | |

**Production-readiness gate:** A, C, and F all green = ready for the cairn site integration.

**Stretch checks** if you have appetite:
- Run the `mcp-server/spec-check.sh` after each MCP install to confirm no spec drift
- Try installing on a fresh user account (or in a clean VM) to catch hardcoded-path assumptions
- Try with a `CAIRN_BASE_URL` override to verify URL-scoped key isolation
