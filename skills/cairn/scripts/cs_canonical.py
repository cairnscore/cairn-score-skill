"""Canonical external_id rules, shared by cs-hook-postool and cs-sanitize-rating.

Mirrors the server's `normalize_external_id` v2 (cairn-service,
src/cairn/api/normalize.py) for http(s) URLs so the ids this pipeline emits
are byte-identical to what the server stores. If a rule changes server-side,
change it here in the same release.

The same conceptual source must always get the same external_id, or ratings
split across duplicate entities and confidence never accumulates. The rules:
lowercase scheme/host; strip trailing slash, fragment, and default port; drop
volatile query params (pagination/ordering) and sort the rest; collapse a
whole path segment or query value that is a UUID or a placeholder spelling
($var, ${var}, {var}, :var, <var>) to a literal `{id}`. Bare numeric segments
survive — a PubMed id names a paper, not a parameter.

Pure stdlib, importable on python3.9+ (hook environments vary).
"""

import re
from urllib.parse import parse_qsl, quote, urlencode, urlparse, urlunparse

_VOLATILE_QUERY_PARAMS = frozenset(
    {"limit", "offset", "page", "per_page", "page_size", "cursor", "sort", "order"}
)

_UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)

_PLACEHOLDER_RE = re.compile(
    r"^(?:"
    r"\$\w+|\$\{\w+\}|\{\w+\}|:\w+|<\w+>"
    r"|%24\w+|%24%7B\w+%7D|%7B\w+%7D|%3C\w+%3E"
    r")$",
    re.IGNORECASE,
)


def _canonical_segment(segment: str) -> str:
    if _PLACEHOLDER_RE.match(segment) or _UUID_RE.match(segment):
        return "{id}"
    return segment


def _canonical_query(query: str) -> str:
    if not query:
        return ""
    pairs = [
        (k, "{id}" if _PLACEHOLDER_RE.match(v) or _UUID_RE.match(v) else v)
        for k, v in parse_qsl(query, keep_blank_values=True)
        if k.lower() not in _VOLATILE_QUERY_PARAMS
    ]
    pairs.sort()
    return urlencode(pairs, quote_via=quote, safe="{}")


def canonicalize_url(url: str) -> str:
    """Canonical form of an http(s) URL; non-http(s) input is returned unchanged
    (mcp:// and tool:// ids have their own conventions, agents aren't rated here)."""
    p = urlparse(url)
    scheme = p.scheme.lower()
    if scheme not in ("http", "https"):
        return url
    netloc = p.netloc.lower()
    default_port = ":80" if scheme == "http" else ":443"
    if netloc.endswith(default_port):
        netloc = netloc[: -len(default_port)]
    path = "/".join(_canonical_segment(s) for s in p.path.split("/")).rstrip("/")
    return urlunparse((scheme, netloc, path, "", _canonical_query(p.query), ""))


def is_resolved(url: str) -> bool:
    """False when shell syntax survives canonicalization — `$(cmd)` substitutions,
    backticks, or partial interpolations like `abc$def`. The actual target of
    such a call is unknowable from command text; a rating attached to a garbage
    identity is worse than no rating."""
    return "$" not in url and "`" not in url


def canonical_mcp_server(token: str) -> str:
    """Collapse Claude Code's plugin tool-name prefix: `plugin_<name>_<server>`
    as seen in `mcp__plugin_cairn_cairn__score` should yield `cairn`, matching
    the SKILL.md `mcp://<server-name>` convention. Only the unambiguous doubled
    form (name == server) is collapsed; anything else passes through."""
    if not token.startswith("plugin_"):
        return token
    body = token[len("plugin_"):]
    mid = len(body) // 2
    if len(body) % 2 == 1 and body[mid] == "_" and body[:mid] == body[mid + 1:]:
        return body[:mid]
    return token
