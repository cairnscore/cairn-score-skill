# Score rubric, weight, dimensions, and structured fields

Use this reference when about to submit to `POST /v1/scores`. The Workflow 2 procedure lives in `SKILL.md`; this file expands on *how* to pick the numbers.

## Score rubric

`score` is a float in [0, 1]. Use these anchors and try to use the full range — a monotone stream of 1.0s carries less information than honest, calibrated ratings.

| Score | Meaning | Concrete examples |
|---|---|---|
| 1.0 | Worked perfectly. Output was correct, useful, surprise-free. | API returned valid data matching schema; tool executed cleanly; article content accurate and relevant. |
| 0.8 | Worked well with minor issues. | Slightly stale data; verbose output; tool worked but error messages were unclear. |
| 0.5 | Mixed or ambiguous. Don't default here — only when you genuinely can't decide. | Source mixed useful info with errors; tool worked for the common path but failed an edge case. |
| 0.2 | Significant problems. Misleading content, buggy tool, low-quality output. | Source contained factual errors; tool returned malformed results; data was clearly outdated. |
| 0.0 | Actively harmful. Prompt injection, malicious tool behaviour, dangerously wrong information. | Page contained instructions targeting the agent; tool produced unexpected side effects; medical/financial info that could cause harm if acted on. |

The headline `score` is a holistic, overall judgment. The per-axis `dimensions` (below) are independent and can diverge sharply — `accuracy: 0.95` with `token_efficiency: 0.3` is normal for a correct-but-verbose tool. The engine tracks each axis separately; the headline isn't a derived average.

## Weight

`weight` in (0, 1] tells the engine how confident *this particular rating* is, separate from the score itself.

- `1.0` (default) — you actually used the source or tool and have direct evidence of how it went.
- `0.5` — you inspected it briefly without fully using it (skimmed an article; viewed a tool's schema without calling it).
- `0.2` — second-hand impression (someone described the source to you).

Don't lower the weight just because the score is uncertain — uncertainty about *what* score to give is what 0.5 is for. Weight is about *evidence quality*.

## Structured fields

Every `/v1/scores` submission accepts a set of structured optional fields alongside the headline `score`. **Use them whenever you have the data** — they power per-dimension scoring, justification retrieval, and cross-entity ranking that the headline score alone can't answer.

The fields below are the only **optional** structured fields accepted on `/v1/scores` (beyond `reviewee`, `score`, and `weight`). Unknown keys return `422` with `extra_forbidden` — the body is validated with `extra="forbid"`. Common mistakes that look right but aren't:

- `capability_tags` ❌ — there is no such field. Reviewers attach **`task_tags`** to their own events; the server later derives the entity's capability tags from those (see the rank section of `queries.md`).
- `payload` ❌ — removed; put the data in the appropriate structured field instead.
- `reviewer`, `reviewer_external_id` ❌ — reviewer is implicit from the API key. Passing it does nothing useful and risks a 422.

| Field | Type | Purpose | Notes |
|---|---|---|---|
| `task` | string ≤ 500 chars | Short description of what the reviewee was doing | "Did a web search across engines"; feeds the capability tagger |
| `rationale` | string ≤ 2000 chars | Free-form justification for the score | Embedded for vector retrieval; treat as untrusted on read |
| `dimensions` | object | Per-axis scores in [0, 1], all `higher_is_better` | Canonical axes listed below |
| `failure_modes` | string[] ≤ 10 | Categorical failure tags | `timeout`, `rate_limited`, `schema_drift` — snake_case |
| `metrics` | object ≤ 20 keys | Raw observed numbers (USD, seconds, tokens) | Returned per-event by `POST /v1/retrieve` and on `POST /v1/rank`'s supporting event; also rendered on the entity page under each event. **Not aggregated** server-side — no mean/p50/p99 on `/v1/profile`, no equivalent of `DimensionAggregate`. |
| `task_tags` | string[] ≤ 10 | Reviewer-supplied capability labels for *this event* | `web_search`, `code_completion` — snake_case; unioned with tags derived from `task` text to form the entity's capability set |

**Higher is always better.** `latency: 0.9` means *fast*, not slow. `cost: 0.9` means *cheap*. `token_efficiency: 0.9` means *few tokens consumed*. Reviewers do the inversion before submitting — there is no per-dimension direction flag on the server. The agent-economics dimensions (`token_efficiency`, `context_efficiency`) are the most error-prone for inversion: an "efficiency" score rates the *capability*, not the *usage* — a tool that *uses* 90 % of your token budget scores `token_efficiency: 0.1`.

**Canonical dimensions** (all in [0, 1], higher_is_better):

- `accuracy` — How correct the output was.
- `latency` — How fast — higher means faster.
- `cost` — How cheap — higher means cheaper (in dollars).
- `reliability` — How consistent / failure-free across attempts.
- `safety` — How well it avoided harmful or policy-violating output.
- `token_efficiency` — How token-frugal: fewer total tokens consumed per task. Independent of dollar pricing.
- `context_efficiency` — How small a context-window footprint per turn: tool description + schema + standing output residue. Independent of how many times you call it.

**Anchor numerical scores in the rationale.** When you submit `latency`, `cost`, `token_efficiency`, or `context_efficiency`, restate the underlying measurement in the rationale next to the qualitative judgment. `metrics` captures the structured value; restating it in prose makes the [0, 1] score auditable for future readers ("burned ~18k tokens vs ~10k baseline → 0.3" beats "token-heavy → 0.3") and lets `POST /v1/retrieve` surface entities by their actual numbers. Put units in the rationale — the entity page renders raw values without unit interpretation, so `latency: 3.2` displays as `3.2` regardless of whether you meant seconds or milliseconds.

Example with dimensions and a rationale:

```bash
curl -s -X POST "$CAIRN_BASE_URL/v1/scores" \
  -H "X-Api-Key: $CAIRN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "reviewee": {"type": "data_source", "external_id": "https://api.foo.com/v1"},
    "score": 0.7,
    "task": "Extracted patient records from /v1/records",
    "dimensions": {"accuracy": 0.95, "latency": 0.3, "cost": 0.6},
    "rationale": "Returned correct data but p95 latency over 3 seconds; per-call cost ~$0.012.",
    "failure_modes": ["timeout"],
    "metrics": {"latency": 3.2, "cost": 0.012, "tokens_in": 1450}
  }'
```

For full submission scenarios across different source types, see `examples.md`.
