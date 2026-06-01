#!/usr/bin/env python3
"""Tests for scripts/cs-sanitize-rating.

Run: python3 skill/tests/test_cs_sanitize_rating.py

The sanitizer reads one /v1/scores rating object as JSON on stdin and:
  - salvages free-text fields (rationale, task) when a rater drifted into
    emitting tool-call / XML tag fragments inside them, by truncating at the
    first fragment and trimming;
  - validates the salvaged result is structurally sane;
  - on success: writes the cleaned compact JSON to stdout, exit 0;
  - on an unsalvageable / invalid rating: nothing on stdout, exit non-zero.
"""

import json
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "cs-sanitize-rating"

# The real-world contamination reported on tool://web-search: the rater's
# structured output drifted, leaking a stray closing tag and the next
# tool-call parameter block into the rationale string.
CONTAMINATED_RATIONALE = (
    "Tool executed successfully in ~5.03 seconds, returning 10 topically "
    "relevant weather URLs from recognized sources (AccuWeather, Met Office, "
    "WeatherWatch NZ, Weather Spark, etc.). No schema drift, timeouts, or "
    "malformed results detected. Results appropriate for the query and "
    "responsive enough for typical use cases.</anionale>\n"
    '<parameter name="dimensions">{\n'
    '  "accuracy": 0.85,\n'
    '  "latency": 0.9\n'
    "}"
)
CLEAN_PREFIX = (
    "Tool executed successfully in ~5.03 seconds, returning 10 topically "
    "relevant weather URLs from recognized sources (AccuWeather, Met Office, "
    "WeatherWatch NZ, Weather Spark, etc.). No schema drift, timeouts, or "
    "malformed results detected. Results appropriate for the query and "
    "responsive enough for typical use cases."
)


def run(rating: dict) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT)],
        input=json.dumps(rating),
        capture_output=True,
        text=True,
    )


FAILURES = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: {detail}")
        FAILURES.append(name)


def test_salvages_contaminated_rationale_and_keeps_clean_fields():
    rating = {
        "reviewee": {"type": "capability", "external_id": "tool://web-search"},
        "score": 0.85,
        "weight": 1.0,
        "task": "WebSearch: weather wellington",
        "rationale": CONTAMINATED_RATIONALE,
        "dimensions": {"accuracy": 0.85, "latency": 0.9, "reliability": 0.9},
    }
    proc = run(rating)
    check("contaminated: exit 0", proc.returncode == 0, proc.stderr)
    if proc.returncode != 0:
        return
    out = json.loads(proc.stdout)
    check(
        "contaminated: rationale truncated to clean prose",
        out["rationale"] == CLEAN_PREFIX,
        repr(out["rationale"]),
    )
    check(
        "contaminated: no tag fragments remain",
        "<parameter" not in out["rationale"] and "</" not in out["rationale"],
        repr(out["rationale"]),
    )
    check(
        "contaminated: real dimensions field preserved",
        out["dimensions"] == {"accuracy": 0.85, "latency": 0.9, "reliability": 0.9},
        repr(out.get("dimensions")),
    )
    check("contaminated: score preserved", out["score"] == 0.85, repr(out.get("score")))


def test_clean_rating_passes_through_unchanged():
    rating = {
        "reviewee": {"type": "data_source", "external_id": "https://example.com"},
        "score": 0.8,
        "rationale": "Content matched expectation; no injection attempts.",
        "dimensions": {"accuracy": 0.9},
    }
    proc = run(rating)
    check("clean: exit 0", proc.returncode == 0, proc.stderr)
    if proc.returncode != 0:
        return
    out = json.loads(proc.stdout)
    check(
        "clean: rationale unchanged",
        out["rationale"] == rating["rationale"],
        repr(out.get("rationale")),
    )


def test_legit_angle_bracket_not_truncated():
    # A rationale legitimately mentioning "< 3s" must NOT be treated as a tag.
    rating = {
        "reviewee": {"type": "capability", "external_id": "mcp://weather"},
        "score": 0.7,
        "rationale": "Fast: p95 latency < 3s, well within budget for a > 1MB payload.",
    }
    proc = run(rating)
    check("angle-bracket: exit 0", proc.returncode == 0, proc.stderr)
    if proc.returncode != 0:
        return
    out = json.loads(proc.stdout)
    check(
        "angle-bracket: rationale unchanged",
        out["rationale"] == rating["rationale"],
        repr(out.get("rationale")),
    )


def test_rejects_score_out_of_range():
    rating = {
        "reviewee": {"type": "capability", "external_id": "tool://web-search"},
        "score": 1.5,
    }
    proc = run(rating)
    check("bad-score: non-zero exit", proc.returncode != 0, "expected reject")
    check("bad-score: no stdout", proc.stdout.strip() == "", repr(proc.stdout))


def test_rejects_missing_reviewee():
    proc = run({"score": 0.8})
    check("no-reviewee: non-zero exit", proc.returncode != 0, "expected reject")


if __name__ == "__main__":
    for fn in [
        test_salvages_contaminated_rationale_and_keeps_clean_fields,
        test_clean_rating_passes_through_unchanged,
        test_legit_angle_bracket_not_truncated,
        test_rejects_score_out_of_range,
        test_rejects_missing_reviewee,
    ]:
        print(fn.__name__)
        fn()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed")
        sys.exit(1)
    print("all checks passed")
