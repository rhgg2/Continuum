#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2,<2"]
# ///
"""Continuum test-runner MCP server.

lua_test_run wraps `lua tests/run.lua` and returns a focused failures-only
report with file:line jumps. 

lua_probe runs a snippet of code against the working tree, the session's
spike worktree, or both. It takes the source as a string because the shell is
the wrong pipe for Lua: a heredoc body has to survive quoting and a permission
scan that cannot tell `..` the concat operator from `..` the climb out of the
scratchpad. Passed as data, it needs neither.

Sister servers: continuum_map (map_query), reaper_docs (reaper_doc_lookup),
reaper (reaper_eval). Batched writes are handled by the global `patches`
server (mcp__patches__apply_patches).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Optional

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.utilities.func_metadata import ArgModelBase
from pydantic import ConfigDict

# Strict input validation: reject unknown kwargs so silent param-name slips fail loudly.
ArgModelBase.model_config = ConfigDict(arbitrary_types_allowed=True, extra='forbid')

# pydantic titles every field and model after the name it was derived from
# ('Kind' for kind, '<tool>Arguments' for the model), which tool schemas then
# carry into always-loaded context. Drop them at the one point every tool's
# arg model shares.
_base_json_schema = ArgModelBase.model_json_schema.__func__


def _untitled(node):
    if isinstance(node, dict):
        return {k: _untitled(v) for k, v in node.items() if k != 'title'}
    if isinstance(node, list):
        return [_untitled(v) for v in node]
    return node


ArgModelBase.model_json_schema = classmethod(
    lambda cls, *a, **kw: _untitled(_base_json_schema(cls, *a, **kw)))

PROJECT_ROOT = Path(__file__).resolve().parents[3]
BASELINE_PATH = PROJECT_ROOT / ".claude" / "test-baseline.json"

mcp = FastMCP("continuum_tests")


_SUMMARY = re.compile(r"^(\d+) passed, (\d+) failed", re.MULTILINE)
_FAIL_LINE = re.compile(r"^  FAIL  (.+)$", re.MULTILINE)
_TRACE_FRAME = re.compile(r"(tests/specs/[^:\s]+\.lua):(\d+)")


def _read_window(path: Path, line: int, context: int) -> str:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as e:
        return f"(could not read {path}: {e})"
    n = len(lines)
    s = max(1, line - context)
    e = min(n, line + context)
    width = len(str(e))
    out = []
    for i in range(s, e + 1):
        marker = ">" if i == line else " "
        out.append(f"{marker} {i:>{width}}\t{lines[i - 1]}")
    return "\n".join(out)


def _parse_failures(stdout: str) -> list[dict]:
    head, _, tail = stdout.partition("=== failures ===")
    if not tail:
        return []
    chunks = re.split(r"\n-- (?=\S)", tail)
    failures = []
    for chunk in chunks[1:]:
        nl = chunk.find("\n")
        if nl < 0:
            continue
        name = chunk[:nl].strip()
        body = chunk[nl + 1 :].strip()
        body = re.split(r"\n\d+ passed, \d+ failed", body)[0].rstrip()
        failures.append({"name": name, "body": body})
    return failures


def _write_baseline(started: float, n_pass: int, n_fail: int, failures: list[str]) -> None:
    """Record an unfiltered run for the SessionStart hook to read.

    Stamped with the run's *start* time, not its end: a file edited during the
    ~20s the suite takes must read as newer than the baseline, or the next
    session would be told a green result covers an edit it never saw.
    """
    try:
        head = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(PROJECT_ROOT),
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        head = ""

    payload = {
        "ts": int(started),
        "commit": head,
        "passed": n_pass,
        "failed": n_fail,
        "failures": failures,
        "seconds": round(time.time() - started, 1),
    }
    try:
        BASELINE_PATH.write_text(json.dumps(payload) + "\n", encoding="utf-8")
    except OSError:
        pass


def _spike_root() -> Optional[Path]:
    """This session's spike worktree, or None if it hasn't got one.

    Read out of `git worktree list` rather than by rebuilding the scratchpad
    layout session-env.sh builds: git already knows where every worktree is, so
    the only thing this borrows from that layout is that the session id appears
    in the path. Which matters because stale spikes from dead sessions stay
    registered until something prunes them, so "the one spike" is not a
    question with an answer.
    """
    session = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not session:
        return None
    try:
        listing = subprocess.run(
            ["git", "worktree", "list", "--porcelain"],
            cwd=str(PROJECT_ROOT),
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in listing.splitlines():
        path = line.partition("worktree ")[2]
        if path and f"/{session}/" in path:
            return Path(path)
    return None


def _source_dir(spike: Path) -> Path:
    """Where to write the probe, preferring the short alias for the scratchpad.

    Lua elides a source name longer than LUA_IDSIZE in tracebacks, and the real
    scratchpad path carries a full session id, so an error in a probe written
    there reports `...c13f14e5-29da/probe.lua:2` — a line number with no path to
    click. session-env.sh keeps a short symlink beside it for this class of
    reason; take it when one resolves to the same directory, which is a check
    rather than a guess about how it was named.
    """
    scratchpad = spike.parent
    try:
        for entry in spike.parents[3].iterdir():
            if entry.is_symlink() and entry.resolve() == scratchpad.resolve():
                return entry
    except (OSError, IndexError):
        pass
    return scratchpad


def _head(root: Path) -> str:
    try:
        return subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(root),
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip() or "?"
    except (OSError, subprocess.SubprocessError):
        return "?"


def _lua_run(root: Path, source: Path, timeout: int) -> tuple[str, str, Optional[int]]:
    """Run source in root; (stdout, stderr, exit status), status None on timeout.

    LUA_PATH names the three roots tests/run.lua names, so a probe can require
    production modules and `harness` alike, and gets them from the tree it is
    running in rather than from wherever the file happens to sit.
    """
    env = dict(os.environ)
    env["LUA_PATH"] = f"{root}/?.lua;{root}/tests/?.lua;{root}/tests/specs/?.lua;;"
    try:
        proc = subprocess.run(
            ["lua", str(source)],
            cwd=str(root),
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return "", "", None
    return proc.stdout, proc.stderr, proc.returncode


@mcp.tool(structured_output=False)
def lua_probe(
    code: str,
    tree: str = "both",
    keep: Optional[str] = None,
    timeout: int = 30,
) -> str:
    """Run a Lua snippet against the working tree, the session's spike, or both.

    package.path covers the tree root, tests/ and tests/specs/, so
    `require('util')` and `require('harness')` work with no preamble.
    Nothing is printed implicitly: use print or io.write.

    Args:
      code: Lua source.
      tree: 'main' (the working tree), 'spike' (this session's worktree,
            detached at HEAD), or 'both' (default).
      keep: filename to write the source under for a re-run or an edit.
            Bare name; it lands in the scratchpad beside the spike.
            Default overwrites <scratchpad>/probe.lua.
      timeout: kill each run after this many seconds (default 30).

    """
    if shutil.which("lua") is None:
        return "--- ERROR: `lua` not on PATH ---"
    if tree not in ("main", "spike", "both"):
        return f"--- ERROR: tree must be 'main', 'spike' or 'both', not {tree!r} ---"
    if keep and Path(keep).name != keep:
        return f"--- ERROR: keep must be a bare filename, not {keep!r} ---"

    spike = _spike_root()
    if spike is None and tree == "spike":
        return "--- ERROR: this session has no spike worktree ---"

    source = (_source_dir(spike) if spike else Path(tempfile.gettempdir())) / (keep or "probe.lua")
    try:
        source.write_text(code, encoding="utf-8")
    except OSError as e:
        return f"--- ERROR: could not write {source}: {e} ---"

    runs = []
    if tree in ("main", "both"):
        runs.append(("main", PROJECT_ROOT))
    if spike is not None and tree in ("spike", "both"):
        runs.append(("spike", spike))

    sections: list[str] = []
    if tree == "both" and spike is None:
        sections.append("(no spike worktree for this session — main only)")

    results: dict[str, tuple] = {}
    for label, root in runs:
        stdout, stderr, status = _lua_run(root, source, timeout)
        results[label] = (stdout, stderr, status)
        if label == "spike" and results.get("main") == results[label]:
            sections.append(f"=== spike ({_head(root)}) === identical to main")
            continue
        block = [f"=== {label} ({_head(root)}) ==="]
        if stdout.strip():
            block.append(stdout.rstrip())
        if stderr.strip():
            block.append("--- stderr ---\n" + stderr.rstrip())
        if status is None:
            block.append(f"--- timed out after {timeout}s ---")
        elif status != 0:
            block.append(f"--- exit {status} ---")
        if len(block) == 1:
            block.append("(no output)")
        sections.append("\n".join(block))

    sections.append(f"source: {source}")
    return "\n\n".join(sections)


@mcp.tool(structured_output=False)
def lua_test_run(
    filter: Optional[str] = None,
    tree: str = "main",
    context: int = 0,
    show_passing: bool = False,
    timeout: int = 60,
) -> str:
    """Run the Lua test suite (`lua tests/run.lua`). Default output is
    failures-only with `path:line` of each failing assertion plus the
    condensed traceback.

    Args:
      filter: optional literal substring matched against `<spec> :: <test>`.
              Examples: "tm_rebuild_spec"; "absorber" (any spec or test
              name containing "absorber"). No regex.
      tree: 'main' (default) or 'spike'. 
      context: lines of source around each failing line (default 0).
      show_passing: include the names of passing tests (default false).
      timeout: kill the run after this many seconds (default 60).

    """
    if shutil.which("lua") is None:
        return "--- ERROR: `lua` not on PATH ---"
    if tree not in ("main", "spike"):
        return f"--- ERROR: tree must be 'main' or 'spike', not {tree!r} ---"

    root = PROJECT_ROOT
    if tree == "spike":
        root = _spike_root()
        if root is None:
            return "--- ERROR: this session has no spike worktree ---"

    cmd = ["lua", "tests/run.lua"]
    if filter:
        cmd.append(filter)

    started = time.time()
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(root),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return f"--- ERROR: `lua tests/run.lua{(' ' + filter) if filter else ''}` timed out after {timeout}s ---"

    out = proc.stdout
    err = proc.stderr.strip()

    summary_m = _SUMMARY.search(out)
    if not summary_m:
        head = (out + "\n" + err).strip()
        return f"--- ERROR: runner produced no summary (exit {proc.returncode}) ---\n{head[:4000]}"

    n_pass = int(summary_m.group(1))
    n_fail = int(summary_m.group(2))

    # Never from a spike: green about a tree the next session won't have.
    if filter is None and tree == "main":
        _write_baseline(started, n_pass, n_fail, _FAIL_LINE.findall(out))

    if filter and n_pass + n_fail == 0:
        return f"(filter {filter!r} matched no tests)"

    sections: list[str] = [
        f"{n_pass} passed, {n_fail} failed"
        + (f"  filter={filter!r}" if filter else "")
        + (f"  tree=spike ({_head(root)})" if tree == "spike" else "")
    ]

    if show_passing:
        passing = [m.group(1) for m in re.finditer(r"^  ok    (.+)$", out, re.MULTILINE)]
        if passing:
            sections.append("passing:\n  " + "\n  ".join(passing))

    if n_fail == 0:
        if err:
            sections.append(f"stderr:\n{err}")
        return "\n\n".join(sections)

    failures = _parse_failures(out)
    if not failures:
        names = _FAIL_LINE.findall(out)
        sections.append("failures (names only — could not parse bodies):\n  " + "\n  ".join(names))
        return "\n\n".join(sections)

    for f in failures:
        frame = _TRACE_FRAME.search(f["body"])
        block = [f"--- FAIL: {f['name']}"]
        if frame:
            spec_path = root / frame.group(1)
            line_no = int(frame.group(2))
            block.append(f"{spec_path if tree == 'spike' else frame.group(1)}:{line_no}")
            if context > 0:
                block.append(_read_window(spec_path, line_no, context))
        body_lines = f["body"].splitlines()
        kept: list[str] = []
        for ln in body_lines:
            if "tests/run.lua" in ln or ln.strip().startswith("[C]:"):
                continue
            kept.append(ln)
        block.append("error:\n" + "\n".join(kept).rstrip())
        sections.append("\n".join(block))

    if err:
        sections.append(f"stderr:\n{err}")

    return "\n\n".join(sections)


if __name__ == "__main__":
    mcp.run()
