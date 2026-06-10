# Canonical external_ids Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The auto-rating pipeline must never mint a fragmented entity identity again. Canonicalize URLs in `cs-hook-postool` before the briefing is built (unexpanded shell variables and UUID path segments → a literal `{id}`, volatile query params dropped, fragments stripped, params sorted), skip ratings whose target URL can't be resolved to a concrete identity, collapse Claude Code plugin MCP names (`mcp://plugin_cairn_cairn` → `mcp://cairn`), enforce the same grammar in `cs-sanitize-rating` so judge-invented variants are repaired too, document the convention in SKILL.md, and remove the remaining `trustgraph` reference.

**Architecture:** One shared pure-Python module, `skills/cairn/scripts/cs_canonical.py`, implements the rules. The hook's embedded Python imports it via `sys.path` (it already receives `SKILL_DIR`), and `cs-sanitize-rating` imports it relative to its own location — the hook fixes the briefing *input*, the sanitizer guards the judge's *output*, so a canonical id reaches `cs-rate` even if the model rewrites it. Rules are deliberately identical to the server's `normalize_external_id` v2 (cairn-service PR, plan `docs/superpowers/plans/2026-06-10-canonical-entity-identity.md` in that repo): client-side canonicalization is defense-in-depth and pre-LLM hygiene; the server remains the authority.

**Tech Stack:** bash + embedded python3 (no third-party deps in hook scripts), standalone-runnable test scripts under `skills/cairn/tests/` (pattern: `test_cs_sanitize_rating.py`), Claude Code plugin packaging (`.claude-plugin/plugin.json`, `hooks/hooks.json`).

**Sequencing:** Safe to release before or after the service PR deploys — `{id}` is exactly the form the server's v2 normalizer produces, and today's v1 server stores it verbatim, so client-canonical ids converge with the post-healing canonical rows either way. Preferred order is still service-first (it also heals history).

---

## Background the implementer needs

### Why (measured 2026-06-10 on api.cairnscore.ai + this machine's `~/.cairn/hook.log`)

- The Bash branch of `skills/cairn/scripts/cs-hook-postool` (line ~190) regex-extracts the first URL from the **literal command text**. `curl …/posts/$PID/comments` therefore mints `external_id = https://…/posts/$PID/comments` — the unexpanded variable. Confirmed locally: `hook.log` contains briefings for `…/posts/$ID/…`, `$P`, `$PID`. Production holds one entity per variable-spelling whim: `$PID`, `$ID`, `$id`, `$pid`, `$P`, `$POST`, `$full`, `$1`, `{p}`.
- The WebFetch branch has the mirror problem: always-concrete URLs, one entity per UUID — `…/posts/<uuid>/comments` × 44.
- The MCP branch derives the server token from the tool-name prefix: `mcp__plugin_cairn_cairn__score` → `mcp://plugin_cairn_cairn`, violating SKILL.md's own `mcp://<server-name>` convention (`plugin.json` declares the plugin `cairn` with MCP server `cairn`, hence the doubled token).
- Net effect: one conceptual endpoint = 111 entities / 408 events; evidence never pools, confidence never accrues.

### Pipeline map (what calls what)

`hooks/hooks.json` (PostToolUse/PostToolUseFailure, async) → `hooks/cs-hook-postool` (plugin wrapper: translates `CLAUDE_PLUGIN_OPTION_*` → env, **execs the real script**) → `skills/cairn/scripts/cs-hook-postool` (builds briefing JSON, detaches rater) → `cs-judge-and-rate` (haiku judge, structured output) → `cs-sanitize-rating` (salvage/validate guard) → `cs-rate` (queue) → `cs-flush` (batch submit). **All edits in this plan target `skills/cairn/scripts/`** — the `hooks/` wrapper needs no change.

### The canonical rules (mirror of the server's v2; http/https URLs only)

1. strip fragment; strip default port (`:80`/`:443`)
2. drop volatile query params: `limit, offset, page, per_page, page_size, cursor, sort, order`; sort the survivors by `(key, value)`
3. whole path segment matching `$name`, `${name}`, `{name}`, `:name`, `<name>` (or their `%24`/`%7B…%7D`/`%3C…%3E` encodings) → literal `{id}`
4. whole path segment that is a UUID (8-4-4-4-12 hex, any case) → `{id}`; same for whole query-param values
5. **not** rules: bare numeric segments (a PubMed id is a specific paper); non-volatile params (`?id_list=…` stays); no arxiv-specific collapsing (that lives server-side as curated migration logic only)
6. fixed point: `canonicalize(canonicalize(x)) == x'` — `{id}` maps to itself
7. non-http(s) ids (`mcp://`, `tool://`, `agent://`) pass through untouched here (the mcp prefix fix is a separate, name-level rule in the hook/sanitizer, not part of URL canonicalization)

### Skip-don't-guess rule

After canonicalization, if the URL still contains `$`, `` ` ``, or `${` (e.g. `https://host/$(cat f)/x`, partial interpolations like `abc$def`), the hook **skips the rating** (`exit 0`): the actual target of the call is unknowable from the command text, and a rating attached to a garbage identity is worse than no rating. The sanitizer applies the same test to the judge's output and rejects (non-zero exit, nothing queued).

### Conventions

- Tests are standalone: `python3 skills/cairn/tests/test_<name>.py` (assert + exit; see `test_cs_sanitize_rating.py` which invokes the script via `subprocess` with JSON on stdin).
- Commit style: short imperative subject, explanatory body (see `git log`); include the `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.
- Release: bump `.claude-plugin/plugin.json` `version` (0.2.1 → 0.3.0 — behavior change), then follow the repo's release flow (`skills/cairn/scripts/release.sh` — read it before running; it maintains `dist/`).

---

## File Structure

- **Create** `skills/cairn/scripts/cs_canonical.py` — shared rules module (pure stdlib).
- **Create** `skills/cairn/tests/test_cs_canonical.py` — table-driven rule tests.
- **Modify** `skills/cairn/scripts/cs-hook-postool` — canonicalize in WebFetch/Bash branches, skip-don't-guess, mcp plugin-prefix collapse, `CAIRN_HOOK_DRY_RUN`.
- **Create** `skills/cairn/tests/test_cs_hook_postool.py` — full-hook tests via dry-run mode.
- **Modify** `skills/cairn/scripts/cs-sanitize-rating` + extend `skills/cairn/tests/test_cs_sanitize_rating.py`.
- **Modify** `skills/cairn/SKILL.md`, `skills/cairn/references/rubric.md`, `skills/cairn/references/examples.md` — document the convention.
- **Modify** `mcp-server/server.py` — drop the `agent://trustgraph-` reserved prefix (line ~76).
- **Modify** `.claude-plugin/plugin.json` — version bump.

---

## Task 1: `cs_canonical.py` + tests

- [ ] **Step 1:** Create `skills/cairn/scripts/cs_canonical.py` exposing:
  - `canonicalize_url(url: str) -> str` — rules 1–6 above; returns non-http(s) input unchanged.
  - `is_resolved(url: str) -> bool` — False when `$`, backtick, or `${` survives canonicalization.
  - `canonical_mcp_server(token: str) -> str` — `plugin_X_X` (exact halves) → `X`; anything else unchanged. Cases: `plugin_cairn_cairn` → `cairn`, `plugin_hpc-bridge_hpc-bridge` → `hpc-bridge`, `weather` → `weather`.

  Pure stdlib (`re`, `urllib.parse`), no I/O, importable on python3.9+ (hook environments vary — avoid 3.12-only syntax here).

- [ ] **Step 2:** Create `skills/cairn/tests/test_cs_canonical.py`, table-driven, including the real prod/hook.log shapes: every placeholder spelling above, the UUID instance, `?sort=new&limit=80` dropping, `?id_list=2304.05332` surviving, `pubmed…/24160679` untouched, fragment/port stripping, fixed-point over all cases, `is_resolved` negatives (`$(cmd)`, `abc$def`), and the three mcp cases.

- [ ] **Step 3:** Run: `python3 skills/cairn/tests/test_cs_canonical.py` → exits 0, prints PASS count.

- [ ] **Step 4:** Commit: `Add cs_canonical: shared external_id canonicalization rules` (body: mirrors cairn-service normalize v2; why client-side too; trailer).

---

## Task 2: Canonicalize in the hook + dry-run mode

- [ ] **Step 1:** In `skills/cairn/scripts/cs-hook-postool`'s embedded Python (the heredoc already has `SKILL_DIR` exported):
  - top: `sys.path.insert(0, os.path.join(os.environ["SKILL_DIR"], "scripts"))` + `import cs_canonical`.
  - **WebFetch branch:** `external_id = cs_canonical.canonicalize_url(url)`; keep the **raw** url in the `task` line (evidence stays honest, identity is canonical).
  - **Bash branch:** same; additionally `if not cs_canonical.is_resolved(canon): sys.exit(0)`.
  - **mcp branch:** `server = cs_canonical.canonical_mcp_server(server)` before building `mcp://<server>`.
  - Denylist: keep the existing raw-URL check, and also test the canonical form (one extra `_denied()` call).
- [ ] **Step 2:** Add `CAIRN_HOOK_DRY_RUN`: when set to `1`, the bash script prints `$BRIEFING` to stdout and exits 0 **before** the detached rater dispatch. Document it in the script's header comment block alongside the other env knobs. This is what makes the hook deterministic to test (no `claude`, no network, no log writes).
- [ ] **Step 3:** Create `skills/cairn/tests/test_cs_hook_postool.py`: build PostToolUse JSON fixtures (`tool_name: Bash` with `curl …/posts/$PID/comments?sort=new&limit=80`; `WebFetch` with a UUID URL; `mcp__plugin_cairn_cairn__score`; a Bash `curl …/$(cat x)/y` that must produce **no** output), run the script with `CAIRN_HOOK_DRY_RUN=1` via subprocess, parse the briefing, assert `entity.external_id` is canonical (`…/posts/{id}/comments`, `mcp://cairn`) and that the unresolvable case emits nothing.
- [ ] **Step 4:** Run: `python3 skills/cairn/tests/test_cs_hook_postool.py` → PASS. Also re-run `test_cs_canonical.py`.
- [ ] **Step 5:** Commit: `Canonicalize external_ids in cs-hook-postool; skip unresolvable URLs` (body: the `$PID` leak with a hook.log example, the plugin-prefix collapse, dry-run knob; trailer).

---

## Task 3: Enforce in `cs-sanitize-rating`

- [ ] **Step 1:** Import `cs_canonical` (sys.path relative to `__file__`). After the existing structural validation: canonicalize `rating["reviewee"]["external_id"]` (http/https) and apply `canonical_mcp_server` to `mcp://…` ids; reject (stderr diagnostic, exit non-zero) when `is_resolved` fails. This catches judge-invented variants the briefing never contained.
- [ ] **Step 2:** Extend `skills/cairn/tests/test_cs_sanitize_rating.py`: a rating with `external_id: https://…/posts/$ID/comments?limit=80` comes out `…/posts/{id}/comments`; `mcp://plugin_cairn_cairn` → `mcp://cairn`; `https://x.com/$(boom)` → rejected, nothing on stdout.
- [ ] **Step 3:** Run: `python3 skills/cairn/tests/test_cs_sanitize_rating.py` → PASS.
- [ ] **Step 4:** Commit: `Enforce canonical external_ids in cs-sanitize-rating` (trailer).

---

## Task 4: Document the convention

- [ ] **Step 1:** `SKILL.md` *Entity types and external_id conventions*: add a row/paragraph — parameterized REST resources use the literal `{id}` placeholder (`https://…/posts/{id}/comments`), volatile pagination/sort params are dropped, and the hook does this automatically; contrast with content pages (a specific article/paper keeps its full path — numeric ids are *not* collapsed).
- [ ] **Step 2:** `references/rubric.md`: one short "Canonical reviewee ids" rule so the judge stops inventing spellings; `references/examples.md`: make one example an endpoint-family id with `{id}` and keep one instance-id content page, labeling which is which.
- [ ] **Step 3:** Commit: `Document canonical external_id convention` (trailer).

---

## Task 5: Remove the trustgraph reference

- [ ] **Step 1:** Delete `"agent://trustgraph-"` from the reserved-prefix list in `mcp-server/server.py` (~line 76). The service is the authority on reserved prefixes and has never reserved the deprecated name; client-side pre-validation should match.
- [ ] **Step 2:** `grep -ri trustgraph . --exclude-dir={.git,.venv,dist,.pytest_cache,docs}` → no hits. (`docs/plans/` is excluded — this plan legitimately documents the legacy names it removes. Renaming the repo itself `trustgraph-skill` → `cairn-skill` is out of scope: remotes, installs, and the marketplace pointer move with it — owner's call.)
- [ ] **Step 3:** Commit: `Drop deprecated trustgraph reserved prefix` (trailer).

---

## Task 6: Release + live verification on a dev machine

- [ ] **Step 1:** Bump `.claude-plugin/plugin.json` to `0.3.0`. Read `skills/cairn/scripts/release.sh` and follow the repo's release flow (dist refresh, tag).
- [ ] **Step 2:** Live check (any machine with the plugin active, e.g. this one): in a scratch Claude Code session, run a `curl` with a shell-variable URL against a denylisted-safe host, then inspect `~/.cairn/queue.jsonl` — the queued rating's `external_id` must show `{id}`, not `$VAR`. `scripts/cs-doctor` stays all-✓.
- [ ] **Step 3:** Release commit per repo convention (`Release v0.3.0`).

---

## Done criteria

- Hook briefings and queued ratings never contain `$var`/backtick URLs, raw UUID path segments, volatile query params, or `mcp://plugin_*_*` ids; unresolvable URLs produce no rating at all.
- All three test scripts pass standalone: `test_cs_canonical.py`, `test_cs_hook_postool.py`, `test_cs_sanitize_rating.py`.
- SKILL.md/rubric/examples state the `{id}` convention and the endpoint-family vs content-page distinction.
- `grep -ri trustgraph` (excluding .git/.venv/dist) is clean; plugin version 0.3.0 released.
