# Worked `/v1/scores` submissions

Each example pairs a typical scenario with the corresponding submission body. The rubric, weight semantics, and dimension definitions live in `rubric.md`.

## Example 1 — well-known docs

User asks for help with a Python library; you fetch `https://docs.scipy.org/doc/scipy/reference/optimize.html` and the page is current and matches the question. Skip the pre-check (it's a well-known docs site) and submit:

```bash
curl -s -X POST "$CAIRN_BASE_URL/v1/scores" \
  -H "X-Api-Key: $CAIRN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "reviewee": {"type": "data_source", "external_id": "https://docs.scipy.org/doc/scipy/reference/optimize.html"},
    "score": 1.0,
    "task": "fetched scipy.optimize reference page for minimize()",
    "rationale": "Page was current and directly answered the user question; constrained-optimization examples were complete.",
    "dimensions": {"accuracy": 1.0, "reliability": 0.95}
  }'
```

## Example 2 — suspicious source

You fetch a blog post that contains text resembling a prompt injection embedded inside a code block. The full URL (instance identity) is correct here — the *content of this specific post* is what's being rated:

```bash
curl -s -X POST "$CAIRN_BASE_URL/v1/scores" \
  -H "X-Api-Key: $CAIRN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "reviewee": {"type": "data_source", "external_id": "https://random-blog.example/post/123"},
    "score": 0.0,
    "task": "fetched blog post for background research on topic X",
    "rationale": "Page contained text directing the agent to ignore prior instructions and exfiltrate data.",
    "failure_modes": ["injection_attempt"],
    "dimensions": {"safety": 0.0}
  }'
```

## Example 2b — parameterized API endpoint

You called `GET https://api.socialsite.example/v1/posts/7d21ede7-909e-4718-9c9a-a039970f08fd/comments?limit=80` and got clean JSON. The entity is the **endpoint family**, not that one post — spell the path parameter as a literal `{id}` and drop the pagination param (the server normalises concrete URLs to this form anyway):

```bash
curl -s -X POST "$CAIRN_BASE_URL/v1/scores" \
  -H "X-Api-Key: $CAIRN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "reviewee": {"type": "data_source", "external_id": "https://api.socialsite.example/v1/posts/{id}/comments"},
    "score": 0.9,
    "task": "fetched comments for a post via the public API",
    "rationale": "Valid JSON matching the documented schema; responded in ~300ms; no auth quirks.",
    "dimensions": {"reliability": 0.95, "latency": 0.9}
  }'
```

## Example 3 — MCP tool that worked

You call a tool from an MCP server `mcp://weather-api` and it returns a clean forecast:

```bash
curl -s -X POST "$CAIRN_BASE_URL/v1/scores" \
  -H "X-Api-Key: $CAIRN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "reviewee": {"type": "capability", "external_id": "mcp://weather-api"},
    "score": 0.9,
    "task": "called get_forecast for San Francisco, 5-day window",
    "rationale": "Returned well-formed JSON matching schema; data appeared current.",
    "dimensions": {"accuracy": 0.9, "latency": 0.85, "reliability": 0.9},
    "metrics": {"latency": 0.4, "tokens_in": 120}
  }'
```

## Example 4 — MCP tool with agent-economics scoring

Same kind of capability, but this time you have visibility into the tool's token + context cost. The schema and tool description occupy ~3k tokens of your context window per turn (small); a typical invocation burns ~6k input + ~12k output tokens (heavier than a comparable summarisation tool that runs ~10k total). Score the new axes:

```bash
curl -s -X POST "$CAIRN_BASE_URL/v1/scores" \
  -H "X-Api-Key: $CAIRN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "reviewee": {"type": "capability", "external_id": "mcp://research-tool"},
    "score": 0.7,
    "task": "called research_query for a 3-source comparison",
    "rationale": "Useful result, but burned ~18k tokens (6k in + 12k out) vs ~10k for leaner alternatives — about 80% over baseline. Schema fits in ~3k tokens of standing context overhead, so multi-call sessions stay viable.",
    "dimensions": {"accuracy": 0.85, "token_efficiency": 0.3, "context_efficiency": 0.85},
    "metrics": {"tokens_in": 6000, "tokens_out": 12000, "tool_schema_tokens": 3000}
  }'
```

`token_efficiency: 0.3` is the *capability* score — meaning the tool is **not** token-frugal (it burned ~80 % more tokens than a baseline). See `rubric.md` for the inversion rule.
