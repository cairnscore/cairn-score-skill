#!/usr/bin/env python3
"""Tests for scripts/cs_canonical.py.

Run: python3 skills/cairn/tests/test_cs_canonical.py

The rules must stay byte-identical to cairn-service's normalize_external_id
v2 for http(s) — several cases below are real external_ids observed in
production and in ~/.cairn/hook.log.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from cs_canonical import (  # noqa: E402
    canonical_mcp_server,
    canonicalize_url,
    has_shell_syntax,
    is_resolved,
)

FAILURES = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: {detail}")
        FAILURES.append(name)


URL_CASES = [
    # placeholder spellings -> {id} (real hook.log shapes)
    (
        "https://www.moltbook.com/api/v1/posts/$PID/comments",
        "https://www.moltbook.com/api/v1/posts/{id}/comments",
    ),
    (
        "https://www.moltbook.com/api/v1/posts/${POST_ID}/comments",
        "https://www.moltbook.com/api/v1/posts/{id}/comments",
    ),
    ("https://www.moltbook.com/api/v1/{p}", "https://www.moltbook.com/api/v1/{id}"),
    ("https://api.x.com/posts/:postId", "https://api.x.com/posts/{id}"),
    ("https://api.x.com/posts/<post_id>", "https://api.x.com/posts/{id}"),
    # UUID segments and query values -> {id}
    (
        "https://www.moltbook.com/api/v1/posts/7d21ede7-909e-4718-9c9a-a039970f08fd/comments",
        "https://www.moltbook.com/api/v1/posts/{id}/comments",
    ),
    (
        "https://x.com/c?post_id=7D21EDE7-909E-4718-9C9A-A039970F08FD",
        "https://x.com/c?post_id={id}",
    ),
    # volatile params dropped, rest sorted, fragment / default port stripped
    (
        "https://www.moltbook.com/api/v1/posts/$PID/comments?sort=new&limit=80",
        "https://www.moltbook.com/api/v1/posts/{id}/comments",
    ),
    ("https://example.com/search?q=x&b=2&a=1#frag", "https://example.com/search?a=1&b=2&q=x"),
    ("HTTPS://X.COM:443/Path/", "https://x.com/Path"),
    # deliberate non-rules
    ("https://pubmed.ncbi.nlm.nih.gov/24160679", "https://pubmed.ncbi.nlm.nih.gov/24160679"),
    (
        "https://export.arxiv.org/api/query?id_list=2304.05332",
        "https://export.arxiv.org/api/query?id_list=2304.05332",
    ),
    ("https://arxiv.org/abs/2604.03173", "https://arxiv.org/abs/2604.03173"),
    ("https://x.com/abc$def/y", "https://x.com/abc$def/y"),
    # non-http(s) untouched
    ("mcp://cairn", "mcp://cairn"),
    ("tool://web-search", "tool://web-search"),
]


def test_canonicalize_url():
    for raw, expected in URL_CASES:
        check(f"url: {raw[:70]}", canonicalize_url(raw) == expected, canonicalize_url(raw))


def test_fixed_point():
    for raw, expected in URL_CASES:
        for value in (raw, expected):
            once = canonicalize_url(value)
            check(f"fixed-point: {value[:60]}", canonicalize_url(once) == once)


def test_is_resolved():
    check("resolved: plain url", is_resolved("https://x.com/a/b"))
    check("resolved: whole-segment var collapses", is_resolved("https://x.com/$PID/c"))
    check(
        "resolved: whole query value collapses",
        is_resolved("https://x.com/api?post_id=$PID"),
    )
    check(
        "unresolved: command substitution",
        not is_resolved("https://x.com/$(cat f)/y"),
    )
    check(
        "unresolved: partial interpolation",
        not is_resolved("https://x.com/abc$def/y"),
    )
    check(
        "unresolved: backtick",
        not is_resolved("https://x.com/`hostname`/y"),
    )
    # In shell command text, "$filter"/"$5" may be expansions — quoting context
    # is unrecoverable, so Bash-extracted URLs stay conservative.
    check(
        "unresolved (bash-strict): OData query key",
        not is_resolved("https://api.x.com/odata?$filter=Price gt 20"),
    )
    check(
        "unresolved (bash-strict): literal-dollar path",
        not is_resolved("https://shop.example/deals/$5-meals"),
    )


def test_has_shell_syntax():
    check("shell: command substitution", has_shell_syntax("https://x.com/$(boom)/y"))
    check("shell: backtick", has_shell_syntax("https://x.com/`id`/y"))
    check("literal: OData key allowed", not has_shell_syntax("https://api.x.com/odata?$filter=x"))
    check("literal: dollar path allowed", not has_shell_syntax("https://shop.example/deals/$5-meals"))
    check(
        "literal: placeholder grammar allowed",
        not has_shell_syntax("https://x.com/posts/${POST_ID}/comments"),
    )


def test_canonical_mcp_server():
    check("mcp: plugin doubled", canonical_mcp_server("plugin_cairn_cairn") == "cairn")
    check(
        "mcp: plugin doubled with hyphens",
        canonical_mcp_server("plugin_hpc-bridge_hpc-bridge") == "hpc-bridge",
    )
    check("mcp: plain server untouched", canonical_mcp_server("weather") == "weather")
    check(
        "mcp: ambiguous plugin form untouched",
        canonical_mcp_server("plugin_foo_bar") == "plugin_foo_bar",
    )


if __name__ == "__main__":
    for fn in [
        test_canonicalize_url,
        test_fixed_point,
        test_is_resolved,
        test_has_shell_syntax,
        test_canonical_mcp_server,
    ]:
        print(fn.__name__)
        fn()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed")
        sys.exit(1)
    print("all checks passed")
