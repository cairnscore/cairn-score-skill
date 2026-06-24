#!/usr/bin/env python3
"""Tests for scripts/cs-hook-postool briefing construction.

Run: python3 skills/cairn/tests/test_cs_hook_postool.py

Drives the real hook script with CAIRN_HOOK_DRY_RUN=1, which prints the
briefing JSON to stdout and exits before dispatching the rater — no model
call, no queue write, no hook.log churn (beyond the rotation check).
"""

import json
import os
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "cs-hook-postool"

FAILURES = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: {detail}")
        FAILURES.append(name)


def run_hook(hook_input: dict, extra_env: dict | None = None) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["CAIRN_HOOK_DRY_RUN"] = "1"
    env.pop("CAIRN_NESTED", None)
    env.pop("CAIRN_HOOK_ENABLED", None)
    env.pop("CAIRN_HOOK_CADENCE", None)  # rate every call in tests
    env.pop("CAIRN_HOOK_HOSTS_DENYLIST", None)
    # The plugin wrapper injects CAIRN_HARNESS; tests invoke the real script
    # directly, so default to unset (the fail-closed baseline) and let cases
    # opt in via extra_env.
    env.pop("CAIRN_HARNESS", None)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", str(SCRIPT)],
        input=json.dumps(hook_input),
        capture_output=True,
        text=True,
        env=env,
    )


def briefing_or_none(proc: subprocess.CompletedProcess):
    out = proc.stdout.strip()
    return json.loads(out) if out else None


def test_bash_shell_var_url_canonicalized():
    proc = run_hook({
        "tool_name": "Bash",
        "session_id": "test-hook-a",
        "tool_input": {
            "command": 'curl -s "https://www.moltbook.com/api/v1/posts/$PID/comments?sort=new&limit=80"'
        },
        "tool_response": {"stdout": "{}"},
    })
    b = briefing_or_none(proc)
    check("bash-var: briefing emitted", b is not None, proc.stderr)
    if not b:
        return
    check(
        "bash-var: external_id canonical",
        b["entity"]["external_id"] == "https://www.moltbook.com/api/v1/posts/{id}/comments",
        b["entity"]["external_id"],
    )
    check(
        "bash-var: task keeps the raw url",
        "$PID" in b["task"],
        b["task"],
    )


def test_webfetch_uuid_url_canonicalized():
    proc = run_hook({
        "tool_name": "WebFetch",
        "session_id": "test-hook-b",
        "tool_input": {
            "url": "https://www.moltbook.com/api/v1/posts/7d21ede7-909e-4718-9c9a-a039970f08fd/comments",
            "prompt": "read the comments",
        },
        "tool_response": {"result": "ok"},
    })
    b = briefing_or_none(proc)
    check("webfetch-uuid: briefing emitted", b is not None, proc.stderr)
    if not b:
        return
    check(
        "webfetch-uuid: external_id canonical",
        b["entity"]["external_id"] == "https://www.moltbook.com/api/v1/posts/{id}/comments",
        b["entity"]["external_id"],
    )


def test_mcp_plugin_prefix_collapsed():
    proc = run_hook({
        "tool_name": "mcp__plugin_cairn_cairn__score",
        "session_id": "test-hook-c",
        "tool_input": {"type": "data_source", "external_id": "https://x.com"},
        "tool_response": {"composite_score": 0.5},
    })
    b = briefing_or_none(proc)
    check("mcp-prefix: briefing emitted", b is not None, proc.stderr)
    if not b:
        return
    check(
        "mcp-prefix: external_id is mcp://cairn",
        b["entity"]["external_id"] == "mcp://cairn",
        b["entity"]["external_id"],
    )
    check("mcp-prefix: task names server.tool", "cairn.score" in b["task"], b["task"])


def test_unresolvable_url_skipped():
    proc = run_hook({
        "tool_name": "Bash",
        "session_id": "test-hook-d",
        "tool_input": {"command": 'curl "https://x.com/$(cat secret)/y"'},
        "tool_response": {"stdout": ""},
    })
    check("unresolvable: exit 0", proc.returncode == 0, str(proc.returncode))
    check("unresolvable: no briefing", proc.stdout.strip() == "", proc.stdout[:120])


def test_credentials_redacted_in_task_line():
    proc = run_hook({
        "tool_name": "WebFetch",
        "session_id": "test-hook-f",
        "tool_input": {"url": "https://api.foo.example/data?api_key=SECRET123&q=x"},
        "tool_response": {"result": "ok"},
    })
    b = briefing_or_none(proc)
    check("redact-task: briefing emitted", b is not None, proc.stderr)
    if not b:
        return
    check("redact-task: secret absent from task", "SECRET123" not in b["task"], b["task"])
    check("redact-task: redaction marker present", "[REDACTED]" in b["task"], b["task"])


def test_userinfo_redacted_in_task_and_dropped_from_identity():
    proc = run_hook({
        "tool_name": "WebFetch",
        "session_id": "test-hook-g",
        "tool_input": {"url": "https://user:hunter2@api.example.com/v1/feed"},
        "tool_response": {"result": "ok"},
    })
    b = briefing_or_none(proc)
    check("userinfo: briefing emitted", b is not None, proc.stderr)
    if not b:
        return
    check("userinfo: password absent from task", "hunter2" not in b["task"], b["task"])
    check(
        "userinfo: identity has no userinfo",
        b["entity"]["external_id"] == "https://api.example.com/v1/feed",
        b["entity"]["external_id"],
    )


def test_non_string_url_skipped_not_crashed():
    proc = run_hook({
        "tool_name": "WebFetch",
        "session_id": "test-hook-h",
        "tool_input": {"url": {"nested": "object"}},
        "tool_response": {},
    })
    check("non-string-url: exit 0", proc.returncode == 0, proc.stderr[:200])
    check("non-string-url: no briefing", proc.stdout.strip() == "", proc.stdout[:120])


def test_websearch_harness_qualified():
    proc = run_hook(
        {
            "tool_name": "WebSearch",
            "session_id": "test-hook-ws",
            "tool_input": {"query": "wellington weather"},
            "tool_response": {"results": []},
        },
        extra_env={"CAIRN_HARNESS": "claude-code"},
    )
    b = briefing_or_none(proc)
    check("websearch: briefing emitted", b is not None, proc.stderr)
    if not b:
        return
    check(
        "websearch: harness-qualified id",
        b["entity"]["external_id"] == "tool://claude-code/web-search",
        b["entity"]["external_id"],
    )


def test_websearch_harness_constant_is_folded():
    # A messy CAIRN_HARNESS still normalizes (defense; the real constant is clean).
    proc = run_hook(
        {
            "tool_name": "WebSearch",
            "session_id": "test-hook-ws2",
            "tool_input": {"query": "x"},
            "tool_response": {"results": []},
        },
        extra_env={"CAIRN_HARNESS": "Claude_Code"},
    )
    b = briefing_or_none(proc)
    check("websearch-fold: briefing emitted", b is not None, proc.stderr)
    if not b:
        return
    check(
        "websearch-fold: id folded to canonical",
        b["entity"]["external_id"] == "tool://claude-code/web-search",
        b["entity"]["external_id"],
    )


def test_websearch_fail_closed_without_harness():
    # No CAIRN_HARNESS (a reused hook outside the first-party plugin): skip the
    # built-in rating rather than mislabel it.
    proc = run_hook({
        "tool_name": "WebSearch",
        "session_id": "test-hook-ws3",
        "tool_input": {"query": "x"},
        "tool_response": {"results": []},
    })
    check("websearch-failclosed: exit 0", proc.returncode == 0, proc.stderr[:200])
    check("websearch-failclosed: no briefing", proc.stdout.strip() == "", proc.stdout[:120])


def test_denylist_checks_canonical_form():
    env_extra = {"CAIRN_HOOK_HOSTS_DENYLIST": "moltbook.com"}
    env = dict(os.environ)
    env["CAIRN_HOOK_DRY_RUN"] = "1"
    env.update(env_extra)
    env.pop("CAIRN_NESTED", None)
    env.pop("CAIRN_HOOK_CADENCE", None)
    proc = subprocess.run(
        ["bash", str(SCRIPT)],
        input=json.dumps({
            "tool_name": "WebFetch",
            "session_id": "test-hook-e",
            "tool_input": {"url": "https://www.moltbook.com/api/v1/verify"},
            "tool_response": {},
        }),
        capture_output=True,
        text=True,
        env=env,
    )
    check("denylist: no briefing for denied host", proc.stdout.strip() == "", proc.stdout[:120])


if __name__ == "__main__":
    for fn in [
        test_bash_shell_var_url_canonicalized,
        test_webfetch_uuid_url_canonicalized,
        test_mcp_plugin_prefix_collapsed,
        test_unresolvable_url_skipped,
        test_credentials_redacted_in_task_line,
        test_userinfo_redacted_in_task_and_dropped_from_identity,
        test_non_string_url_skipped_not_crashed,
        test_websearch_harness_qualified,
        test_websearch_harness_constant_is_folded,
        test_websearch_fail_closed_without_harness,
        test_denylist_checks_canonical_form,
    ]:
        print(fn.__name__)
        fn()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed")
        sys.exit(1)
    print("all checks passed")
