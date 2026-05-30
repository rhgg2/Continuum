#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2"]
# ///
"""Readium test-runner MCP server.

One tool: lua_test_run. Wraps `lua tests/run.lua` and returns a focused
failures-only report with file:line jumps.

Split off from the original single-server `readium`. Sister server:
readium_docs (reaper_doc_lookup, map_query). Batched writes are
handled by the global `patches` server (mcp__patches__apply_patches).
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path
from typing import Optional

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.utilities.func_metadata import ArgModelBase
from pydantic import ConfigDict

# Strict input validation: reject unknown kwargs so silent param-name slips fail loudly.
ArgModelBase.model_config = ConfigDict(arbitrary_types_allowed=True, extra='forbid')

PROJECT_ROOT = Path(__file__).resolve().parents[3]

mcp = FastMCP("readium_tests")


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


@mcp.tool(structured_output=False)
def lua_test_run(
    filter: Optional[str] = None,
    context: int = 0,
    show_passing: bool = False,
    timeout: int = 60,
) -> str:
    """Run the Lua test suite (`lua tests/run.lua`) and return a focused report.

    Default output is failures-only with `path:line` of each failing
    assertion plus the condensed traceback — no source window. Pass
    `context=N` to opt in to ±N lines of source around each failure.

    Args:
      filter: optional literal substring matched against `<spec> :: <test>`.
              Examples: "tm_rebuild_spec" runs only tests in tm_rebuild_spec;
              "absorber" matches any spec or test name containing "absorber".
              The runner uses literal `string.find`, not regex.
      context: lines of source around each failing line (default 0 — omit
               the source window entirely; jump via path:line if needed).
      show_passing: include the names of passing tests (default false).
      timeout: kill the run after this many seconds (default 60).

    Returns:
      Header `N passed, M failed` plus per-failure blocks containing:
        - test name
        - `path:line` of the failing assertion (highest spec frame)
        - source window with the failing line marked `>` (if context > 0)
        - the assertion's error message + condensed traceback
    """
    if shutil.which("lua") is None:
        return "--- ERROR: `lua` not on PATH ---"

    cmd = ["lua", "tests/run.lua"]
    if filter:
        cmd.append(filter)

    try:
        proc = subprocess.run(
            cmd,
            cwd=str(PROJECT_ROOT),
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

    if filter and n_pass + n_fail == 0:
        return f"(filter {filter!r} matched no tests)"

    sections: list[str] = [f"{n_pass} passed, {n_fail} failed" + (f"  filter={filter!r}" if filter else "")]

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
            spec_path = PROJECT_ROOT / frame.group(1)
            line_no = int(frame.group(2))
            block.append(f"{frame.group(1)}:{line_no}")
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
