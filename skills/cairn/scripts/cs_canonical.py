"""Canonical external_id rules, shared by cs-hook-postool and cs-sanitize-rating.

Mirrors the server's `normalize_external_id` v2 (cairn-service,
src/cairn/api/normalize.py) for http(s) URLs so the ids this pipeline emits
are byte-identical to what the server stores. If a rule changes server-side,
change it here in the same release.

The same conceptual source must always get the same external_id, or ratings
split across duplicate entities and confidence never accumulates. The rules:
lowercase scheme/host; strip trailing slash, fragment, default port, and URL
userinfo; drop volatile (pagination/ordering) and credential-bearing query
params (ids are public — secrets must never become identity) and sort the
rest; collapse a whole path segment or query value that is a UUID or a
placeholder spelling ($var, ${var}, {var}, :var, <var>) to a literal `{id}`.
Bare numeric segments survive — a PubMed id names a paper, not a parameter.

Pure stdlib, importable on python3.9+ (hook environments vary).
"""

import re
from urllib.parse import parse_qsl, quote, urlencode, urlparse, urlunparse

_VOLATILE_QUERY_PARAMS = frozenset(
    {"limit", "offset", "page", "per_page", "page_size", "cursor", "sort", "order"}
)

# Credential-bearing params say who is calling, never what the source is —
# and external_ids are public and effectively permanent. Dropped like
# volatile params; `x-amz-*` is a prefix rule so presigned URLs reduce to
# the bare object path.
_CREDENTIAL_QUERY_PARAMS = frozenset(
    {
        "api_key", "api-key", "apikey",
        "access_token", "access-token",
        "auth_token", "auth-token",
        "token", "key", "secret", "client_secret",
        "password", "passwd",
        "sig", "signature",
    }
)


def _dropped_param(key: str) -> bool:
    lowered = key.lower()
    return (
        lowered in _VOLATILE_QUERY_PARAMS
        or lowered in _CREDENTIAL_QUERY_PARAMS
        or lowered.startswith("x-amz-")
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
        if not _dropped_param(k)
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
    if "@" in netloc:
        # Userinfo (user:password@) is a credential, never identity.
        netloc = netloc.rsplit("@", 1)[1]
    default_port = ":80" if scheme == "http" else ":443"
    if netloc.endswith(default_port):
        netloc = netloc[: -len(default_port)]
    path = "/".join(_canonical_segment(s) for s in p.path.split("/")).rstrip("/")
    return urlunparse((scheme, netloc, path, "", _canonical_query(p.query), ""))


def canonicalize_capability(external_id: str) -> str:
    """Canonical form of a `tool://<harness>/<slug>` capability id, byte-identical
    to the server's normalize_external_id `tool://` branch: lowercase the whole
    id and fold `_`→`-` (slug charset is [a-z0-9-]), dropping empty/double/
    trailing path segments. Without this, tool://claude-code/Web-Search and
    .../web-search would be distinct entities. Non-`tool://` input is returned
    unchanged."""
    p = urlparse(external_id)
    if p.scheme.lower() != "tool":
        return external_id
    netloc = p.netloc.lower().replace("_", "-")
    segments = [s.replace("_", "-").lower() for s in p.path.rstrip("/").split("/") if s]
    path = "/" + "/".join(segments) if segments else ""
    return urlunparse(p._replace(scheme="tool", netloc=netloc, path=path))


def is_resolved(url: str) -> bool:
    """For URLs extracted from *shell command text* (the hook's Bash branch).

    False when a `$` or backtick survives placeholder collapse — `$(cmd)`,
    backticks, partial interpolations (`abc$def`), or `$`-prefixed query keys
    (`?$filter=`). In command text those may have been expanded by the shell
    before execution, so the actually-fetched URL is unknowable; a rating on a
    garbage identity is worse than none. Whole-segment / whole-value `$var`
    forms are fine: they collapse to `{id}`, and any expansion was a concrete
    id in the same family. Deliberately conservative: a single-quoted OData
    `?$filter=` is also skipped — quoting context isn't recoverable here.
    Don't use this for literal-context URLs (WebFetch, judge output), where a
    raw `$` is just a character; use `has_shell_syntax` there."""
    p = urlparse(url)
    if p.scheme.lower() not in ("http", "https"):
        return "$" not in url and "`" not in url
    residual = [p.netloc]
    residual.extend(_canonical_segment(s) for s in p.path.split("/"))
    for k, v in parse_qsl(p.query, keep_blank_values=True):
        residual.append(k)
        residual.append("{id}" if _PLACEHOLDER_RE.match(v) or _UUID_RE.match(v) else v)
    rest = "/".join(residual)
    return "$" not in rest and "`" not in rest


def has_shell_syntax(url: str) -> bool:
    """True only for unambiguous shell machinery — `$(…)` command substitution
    or backticks — which is never legitimate in an identity. For literal-context
    ids (judge output, WebFetch URLs): a bare `$` is allowed (`?$filter=`,
    `/deals/$5-meals` are real URLs) and `${var}` belongs to the placeholder
    grammar, collapsed by canonicalization."""
    return "$(" in url or "`" in url


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
