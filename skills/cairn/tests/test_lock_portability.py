#!/usr/bin/env python3
"""Tests for cross-platform file-lock portability (issue #10).

The cairn lock idiom shells out to python3 to take fcntl.flock on fd 9.
fcntl is POSIX-only; on native-Windows CPython `import fcntl` raises
ImportError, which — under `set -euo pipefail` — aborted every cs-* script
and silently turned the whole rate -> queue -> flush pipeline into a no-op
(no key minted, no rating queued, nothing flushed).

These tests verify the shipped idiom now degrades to a best-effort no-lock
when fcntl is unavailable, instead of crashing, and that the buggy
unguarded form can't quietly reappear.

Run: python3 skills/cairn/tests/test_lock_portability.py
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
REPO_ROOT = SCRIPTS_DIR.parent.parent.parent
BUNDLED_MINT = REPO_ROOT / "mcp-server" / "bundled" / "mint-key.sh"

# Shell scripts that take the lock via a `python3 -c '...' <&9` one-liner.
SHELL_LOCK_SCRIPTS = ["mint-key.sh", "cs-rate", "cs-flush"]

# The exact buggy form that aborted on Windows. Must never reappear.
BUGGY = "import fcntl,sys"

# Captures the program passed to the lock idiom `python3 -c '...' <&9`.
# Anchored on `import sys\ntry:` so it can't latch onto an unrelated
# `python3 -c '...'` earlier in the script (e.g. hostname parsing in
# mint-key.sh / cs-flush). The lock idiom is the only one shaped this way.
PROGRAM_RE = re.compile(r"python3 -c '(import sys\ntry:.*?)' <&9", re.DOTALL)

FAILURES = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: {detail}")
        FAILURES.append(name)


def extract_program(script_path: Path) -> str | None:
    m = PROGRAM_RE.search(script_path.read_text())
    return m.group(1) if m else None


def run_program(program: str, block_fcntl: bool) -> subprocess.CompletedProcess:
    """Run the *actual extracted* lock program with a real lock fd as stdin.

    block_fcntl=True simulates native-Windows CPython by poisoning
    sys.modules['fcntl'] so `import fcntl` raises ImportError — exactly the
    failure mode from issue #10.
    """
    driver = program
    if block_fcntl:
        driver = "import sys\nsys.modules['fcntl'] = None\n" + program
    with tempfile.NamedTemporaryFile(suffix=".lock") as tmp:
        with open(tmp.name, "a") as fd:  # writable fd, mirrors `exec 9>"$LOCK"`
            return subprocess.run(
                [sys.executable, "-c", driver],
                stdin=fd,
                capture_output=True,
                text=True,
            )


def test_each_shell_script_lock_degrades():
    for name in SHELL_LOCK_SCRIPTS:
        prog = extract_program(SCRIPTS_DIR / name)
        check(f"{name}: lock idiom found", prog is not None, "no `python3 -c '...' <&9` match")
        if not prog:
            continue
        present = run_program(prog, block_fcntl=False)
        check(f"{name}: exit 0 with fcntl present", present.returncode == 0, present.stderr)
        absent = run_program(prog, block_fcntl=True)
        check(f"{name}: exit 0 with fcntl ABSENT (Windows)", absent.returncode == 0, absent.stderr)


def test_no_unguarded_import_remains():
    targets = [p for p in SCRIPTS_DIR.iterdir() if p.is_file()]
    if BUNDLED_MINT.exists():  # gitignored build artifact — only present post-build
        targets.append(BUNDLED_MINT)
    for p in targets:
        check(f"{p.name}: no unguarded `{BUGGY}`", BUGGY not in p.read_text(errors="ignore"))


def test_cs_hook_postool_guards_import():
    # cs-hook-postool's counter critical section is a Python block in a heredoc;
    # it must guard the import and skip flock when fcntl is None.
    text = (SCRIPTS_DIR / "cs-hook-postool").read_text()
    check("cs-hook-postool: import guarded", "fcntl = None" in text)
    check("cs-hook-postool: flock skipped when absent", "if fcntl is not None:" in text)


def test_bundled_mint_key_matches_source():
    # build-mcpb.sh copies skills/cairn/scripts/mint-key.sh into bundled/ at
    # build time; bundled/ is gitignored, so it only exists in a dev tree or
    # right after a build. When present, it must match source — a stale copy
    # would ship a buggy mint in the .mcpb. When absent, nothing to check.
    if not BUNDLED_MINT.exists():
        print("  ok   bundled mint-key.sh check skipped (not built; gitignored artifact)")
        return
    src = (SCRIPTS_DIR / "mint-key.sh").read_text()
    check(
        "bundled mint-key.sh byte-identical to source",
        src == BUNDLED_MINT.read_text(),
        "bundled copy drifted — re-run mcp-server/build-mcpb.sh",
    )


if __name__ == "__main__":
    for fn in [
        test_each_shell_script_lock_degrades,
        test_no_unguarded_import_remains,
        test_cs_hook_postool_guards_import,
        test_bundled_mint_key_matches_source,
    ]:
        print(fn.__name__)
        fn()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed")
        sys.exit(1)
    print("all checks passed")
