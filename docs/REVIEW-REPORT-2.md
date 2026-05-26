# trustgraph-skill — review round 2

**Date:** 2026-05-26
**Scope:** post-action-plan regression review across 6 specialties (Python/MCP, bash hygiene, security, API schema, skill prompt design, operational robustness)
**Method:** same 6 reviewers as round 1, each scoped to verify the Phase 1-9 fixes landed AND identify new issues the changes introduced

---

## TL;DR

The 9-phase action plan landed almost entirely correctly. Most fixes work as claimed; the snapshot/spec-check tooling is correct; security helpers are uniformly applied; queue lock + URL-scoping + 0o600 debug log all work. The reviewers confirmed ~30 distinct fixes-as-claimed.

**However** there are **two correctness blockers** that would have been discovered the moment you ran the MCP from Claude Desktop:

1. **Phase 3b's `Field(alias="type")` pattern breaks every live MCP dispatch.** Verified end-to-end via `mcp.call_tool()`: `score`, `profile`, `retrieve`, `score_history`, `rate` all raise `TypeError: <fn>() got an unexpected keyword argument 'type'`. FastMCP's `model_dump_one_level` dumps using the alias name, then `**`-unpacks into the function which expects `entity_type`. My Phase 3b smoke tested by calling the Python functions directly with `entity_type=...`, bypassing the dispatch path.

2. **The Phase 4 401 retry in `rate` is a no-op.** Clearing `app_ctx.api_key = None` forces a re-call to `_load_api_key`, but `_load_api_key` shells out to `mint-key.sh` which double-checks the file at `~/.trustgraph/keys/<host>.key` — finds the still-existing (revoked) key, and returns it without contacting `/v1/keys`. Every retry burns one extra HTTP round-trip then raises the "fresh mint also rejected" error.

Plus **two operational regressions** that didn't break correctness but did make things worse:

3. **`tg-hook-postool` `( ) & disown` doesn't survive `SIGHUP`.** macOS sends SIGHUP to the whole hook process group on parent exit; the disowned subshell stays in the same pgrp. The fix needs `setsid` or `nohup`.

4. **`tg-flush` holds the queue lock across every chunk POST.** Up to 30s × N chunks of blocking for any `tg-rate` append. The lock should be released after the read+rewrite, re-acquired only for the final unlink.

Beyond those, the review surfaced 7 medium and 11 low-severity findings, plus 3 new attack-surface notes from the security side.

---

## Blockers (must fix before testing)

### B1 — `Field(alias="type")` breaks every aliased tool's MCP dispatch

**Reviewer:** Python/MCP. **Verified by:** end-to-end `mcp.call_tool()` smoke (this report's writer).

**Symptom:**
```
ToolError: Error executing tool score: score() got an unexpected keyword argument 'type'
```
fires from `mcp.call_tool("score", {"type": "data_source", ...})`. Same for profile, retrieve, score_history, rate. Anything with the `type` param.

**Root cause:** FastMCP wraps function parameters in a Pydantic model. On call, it validates input against the model, then dumps the validated model and `**`-unpacks the result into the function. Pydantic's dump uses the alias name (`type`), so the function receives `type=...` as a kwarg — but the parameter is named `entity_type`. TypeError.

**Why the smoke missed it:** Phase 3b's tests called `score(fake_ctx, entity_type="data_source", ...)` directly. That works fine — the Python signature accepts the kwarg by its name. But the FastMCP dispatch path goes through the model and uses the alias on output, which is a different call path.

**Fix options:**

- **Option A — drop the alias, accept the rename.** Schema field becomes `entity_type`; the host (Claude Desktop, etc.) learns the new name. Requires updating skill examples that say `type=...` (SKILL.md, references/) to say `entity_type=...`. Also the JSON-RPC schema would diverge from the upstream server's own wire shape, which is `type`. Cleaner code but more downstream documentation churn.
- **Option B — revert to `type` parameter, accept Pylance warning.** Add `# noqa: A002` (builtin shadowing) on each line. The original concern was theoretical — there's no actual `isinstance(x, type)` use inside any tool body. Minimal churn; the only cost is the warning in IDE.
- **Option C — keep alias, intercept dispatch.** Add `**kwargs` to each tool, remap `kwargs["type"] → entity_type`. Code smell; defeats the type-annotation purpose.

**Recommended:** Option B — revert to `type`. Pure machinery removal. The shadowing concern was advisory; the alias was the wrong tool for the job because FastMCP doesn't honor `populate_by_name` semantics for function-param aliases.

### B2 — 401 retry in `rate` re-uses the revoked key

**Reviewer:** Python/MCP + Operational, independently. **Code path verified by reading server.py:1255-1275 + mint-key.sh:64-67.**

**Symptom:** A `rate` call against a revoked key receives 401, enters the retry branch, clears `app_ctx.api_key = None`, calls `_load_api_key(app_ctx)` again, which shells out to `mint-key.sh`. `mint-key.sh` finds the file at `~/.trustgraph/keys/<host>.key` is non-empty and returns the same revoked key. The second POST hits 401 again, raises:

> "rate failed: fresh mint also rejected with 401 — likely an API-side problem..."

This message is now misleading because the mint was *not* fresh.

**Fix options:**

- **Option A — delete the persisted key file before the second `_load_api_key`.** `os.unlink(_resolve_key_file())` in the `_UnauthorizedError` branch. Server.py needs to know the key-file path, which currently lives only in mint-key.sh.
- **Option B — add a `--force` (or `--remint`) flag to `mint-key.sh`.** Skip the double-check inside the lock; always POST `/v1/keys` and overwrite. Server.py calls `mint-key.sh --remint` on retry.

**Recommended:** Option B. Keeps the key-file path encapsulated in mint-key.sh and matches the existing `--write` flag pattern.

---

## High — perf/correctness regressions worth fixing this round

### H1 — `tg-flush` holds queue lock across every chunk POST

**Reviewer:** Operational. **Location:** `tg-flush:48`.

The flock is acquired before the heredoc and released only on EXIT. The python heredoc reads, parses, then POSTs each chunk (`urllib.request.urlopen(req, timeout=30)`). For a 500-event queue at 100/chunk that's up to 5 × 30s = 150s of blocking on `tg-rate` appends. Hook hot path blocks.

**Fix:** read + parse + (optionally) write `events.snapshot.jsonl` under the lock, release it, do the POST loop without the lock, take the lock briefly again to unlink the queue file.

### H2 — `( ) & disown` doesn't survive SIGHUP

**Reviewer:** Operational. **Location:** `tg-hook-postool:128-133`.

`disown` removes the job from the parent's jobtable but doesn't change process-group membership. On macOS, Claude Code terminates hooks via SIGHUP to the whole pgrp; the grandchild rater dies mid-flight. User-visible: hooks claim to dispatch but ratings never land.

**Fix:** wrap the subshell in `setsid` (Linux) / `nohup` (cross-platform): `( nohup ... ) >> "$LOG" 2>&1 &`. Or `setsid sh -c '...' &` if `setsid` is available. macOS: `setsid` ships in some toolchains; `nohup` is in `/usr/bin/nohup` natively.

### H3 — `rank.supporting_event` not truncated

**Reviewer:** Python/MCP. **Location:** `server.py:873` (the rank tool body).

Phase 2 added `_truncate_event` calls on retrieve, discover, profile.pooled_events. Rank's response includes `RankResult.results[].supporting_event` which is an EventSnippet — same shape, same rationale/task fields. Currently passes through ungated. Same prompt-injection / context-bloat surface.

**Fix:** add `_truncate_event(r.supporting_event)` after `RankResult.model_validate(data)` for each result that has a supporting event.

---

## Medium

| # | Where | Issue | Fix |
|---|---|---|---|
| M1 | `server.py:944-972` | discover bypass skips the Phase 3c connection-error retry as side-effect | mirror the retry inside discover's body |
| M2 | `server.py:413` | TRUSTGRAPH_DEBUG_LOG path is arbitrary file creation — env-var-controlled | constrain to `~/.trustgraph/` prefix or refuse paths with `..` |
| M3 | `server.py:546` | debug log emits `params` verbatim; for score/profile/score_history, `params["external_id"]` can be a URL containing credentials (`https://user:pass@host/`) | log only param keys, or scrub credentials from URL values |
| M4 | `server.py:539-551` + `tg-flush:71` | concurrent debug-log writers are atomic only up to `PIPE_BUF` (4096B on macOS) for regular files | wrap in asyncio.Lock for server.py side; cap entry size, or document the budget |
| M5 | `server.py:467, 499` | `_load_api_key` has no asyncio.Lock; cold-start bursts spawn N mint-key.sh subprocesses (the script's own flock serializes them, but extra round-trips) | add `asyncio.Lock` in AppContext, acquire in `_load_api_key` |
| M6 | `mint-key.sh:91-92` | `code = err.get("code")` from a hostile server response is interpolated into stderr; multi-line content would leak | further sanitize the value (regex `[a-z0-9_]{1,32}` or fall back to `"unknown"`) |
| M7 | `tg-doctor:155` | `2>&1 \|\| echo "000 0"` swallows DNS/SSL cause; user sees "unreachable" with no underlying error | emit one stderr hint line on non-200 |

---

## Low

| # | Where | Issue |
|---|---|---|
| L1 | `server.py:619` | `_truncate_text` slices `s[:max_chars-3]`; if `max_chars<3`, negative slice. Latent — no caller hits it. |
| L2 | `mint-key.sh:62` | `urlparse('https://[::1]/').hostname` returns `'::1'` — key file becomes `keys/::1.key`. Legal on APFS, broken on FAT/SMB. |
| L3 | `tg-flush queue.dead` | No GC / cap; can grow unbounded if a bad-line storm hits. |
| L4 | `tg-flush:231` | Sentinel path: `os.path.dirname(queue_path) or "."` — bare-filename QUEUE lands sentinel in cwd. |
| L5 | `spec-check.sh:115` | `RankIn.rank_by` has no enum in the spec — the enum-sync pair is a no-op. |
| L6 | `spec-check.sh:128` | `os.path.basename(__file__)` in a heredoc — `__file__` is unset; conditional is dead. |
| L7 | `tg-doctor:80, 90` | `wc -l < file` undercounts by one if last line lacks trailing newline. |
| L8 | `mint-key.sh:67` | `trap 'exec 9>&-' EXIT` runs even if `exec 9>"$LOCK"` failed (e.g. unwritable dir). Harmless. |
| L9 | `mint-key.sh:101` | comment about `umask 077` is slightly misleading; `mktemp` itself creates 0o600. |
| L10 | `_load_api_key` cache | uses truthiness; an empty-string `api_key` would not be re-minted. Currently fine (only `None` path resets). |
| L11 | `server.py:1255-1275` | `_UnauthorizedError` doubles mint-quota burn under credential probing. Server-side rate-limit bounds impact. |

---

## New attack surface (security)

| # | Where | Risk |
|---|---|---|
| N1 | `server.py:413` | TRUSTGRAPH_DEBUG_LOG creates arbitrary directories. Env-var-controlled write primitive. |
| N2 | `tg-flush:170, 231-234` | `queue.dead` and `last-flush` inherit user umask — could land at 0644 on permissive umask, exposing event JSON (with rationales). |
| N3 | `mcp-server/spec-check.sh:43-46` | `--update` write target depends on script location; symlinked install could redirect. |

---

## Confirmed-working (validated this round)

These are the Phase 1-9 fixes that the reviewers independently verified are correct as-claimed:

- score/profile split renders cleanly with distinct schemas
- `_scrub_secrets` correctly handles Bearer tokens, case variants, multi-line bodies, applied in `_request` and mint-key error path
- `_truncate_event` / `_truncate_summary` applied uniformly across retrieve/discover/profile (gap on rank.supporting_event flagged separately as H3)
- TRUSTGRAPH_DEBUG_LOG mode 0o600 enforced at both server.py and tg-flush sides
- `EntityRef` `model_dump(by_alias=True)` correctly emits `{"type": ...}` for server-bound payloads
- `_request` `(resp, err)` tuple pattern is sound
- Queue lock OFD-dup-on-fd-9 pattern correct, kernel-on-SIGKILL reaped
- install.sh atomic write (mktemp + chmod 600 + mv -f)
- mint-key.sh URL-scoped key file (`~/.trustgraph/keys/<host>.key`)
- mint-key.sh response sanitize (whitelist `api_key: str`)
- anthropic key newline strip via `IFS= read -r`
- queue.dead corrupted-line capture
- discover 503 bypass correctly raises tailored ToolError without retry
- mint-key.sh exit-code classification (127 / network / mint-rejection / fallback)
- spec-check.sh detects rename-shaped drift correctly (REMOVED + ADDED on different field names)
- Snapshot at `openapi.snapshot.json` matches live API byte-for-byte
- All Phase 1 numeric caps (k≤50, top_*≤20) match the live server

---

## Skill / docstring regressions noticed

- `skill/references/queries.md:3` — "five endpoints" contradicts SKILL.md's "Six". Regression introduced in Phase 5; Phase 7 fixed SKILL.md but missed queries.md.
- `server.py:679` (score docstring) — garbled phrase: "(use `get_rubric()` won't help — scorers are server-side config; omit unless you know what you're picking)." — looks like an editing error.
- `skill/SKILL.md:28` — `tg-doctor` is in the wrapper list but has no "run this when something breaks" trigger anywhere else. An LLM (or user) debugging a failure won't reach for it.
- `server.py` score docstring offers "follow up with `retrieve` for rationales or `profile`" — both are suggested with no tiebreak rule. Model picks arbitrarily.

---

## Recommended action plan

### Pre-test (must do)

1. **B1**: revert `type → entity_type` rename; keep `type` parameter with `# noqa` for the shadowing warning. Remove all `Field(alias="type")` and `model_config = ConfigDict(populate_by_name=True)` on EntityRef. Drop the `by_alias=True` from `EntityRef.model_dump`. Run `mcp.call_tool("score", {"type": ...})` to verify dispatch.
2. **B2**: add `--remint` flag to `mint-key.sh` that skips the double-check + always POSTs `/v1/keys`. Update `_load_api_key` to call `mint-key.sh --remint` from the 401 retry path. Verify by revoking out-of-band.

### Quick wins (small + high-value, also pre-test if you want them in)

3. **H3**: truncate `rank.supporting_event` (3-line fix).
4. **Skill regressions**: queries.md "five→six", score docstring "use get_rubric() won't help" typo, add tg-doctor trigger phrase. Trivial edits.

### Operational (this round or next)

5. **H1**: refactor `tg-flush` to release lock around POST loop.
6. **H2**: `setsid` / `nohup` wrap the disowned hook subshell.
7. **M3**: log only `params` keys (or scrub credentials from URL values) in TRUSTGRAPH_DEBUG_LOG.
8. **M2**: constrain TRUSTGRAPH_DEBUG_LOG path under `~/.trustgraph/`.

### Defer (low-impact, polish)

The L-series + N-series. None are likely to affect testing or correctness.

---

## Open question

Once B1 + B2 are fixed, do you want me to also pull in H1-H3 and the skill regressions before testing, or fix only the blockers and test the rest empirically?
