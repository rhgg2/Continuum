#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2,<2"]
# ///
"""Continuum spec-perturbation MCP server.

One tool: spec_perturb. Tooth-tests a spec by breaking the thing the spec
claims to be about and checking that the verdict moves. A test's name and
assertions describe the run its author intended; what the run actually
reached is set by the fixture's state, the wiring, and stop-at-first-failure.
Reading the test cannot tell you which — perturbing the mechanism can.

Each perturbation lands in its own throwaway copy of the working tree, so the
live tree is never edited and so never needs restoring.

Sister servers: continuum_tests (lua_test_run), continuum_map (map_query),
reaper_docs (reaper_doc_lookup), reaper (reaper_eval).
"""

from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Optional

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.utilities.func_metadata import ArgModelBase
from pydantic import BaseModel, ConfigDict, Field

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

# One fixed workspace, cleared per batch: at most one batch's trees ever exist, so
# surviving copies stay poke-able until the next call without accumulating litter.
WORKSPACE = Path(tempfile.gettempdir()) / "continuum-perturb"

# `.claude` is excluded so a perturbed tree has no test-baseline.json to write: a
# baseline recorded from a broken tree would tell the next session a verdict about a
# tree that never existed. `.git` and `map` are excluded as dead weight.
EXCLUDES = ("--exclude=.git", "--exclude=map", "--exclude=.claude")

mcp = FastMCP("continuum_perturb")

_SUMMARY = re.compile(r"^(\d+) passed, (\d+) failed", re.MULTILINE)
_FAIL_LINE = re.compile(r"^  FAIL  (.+)$", re.MULTILINE)


class Edit(BaseModel):
    model_config = ConfigDict(extra='forbid')

    path: str = Field(description="Repo-relative path of the file to break.")
    old: str = Field(description="Text to replace. Must occur exactly once, or the perturbation reports did-not-apply.")
    new: str = Field(description="Replacement text.")


class Perturbation(BaseModel):
    model_config = ConfigDict(extra='forbid')

    label: str = Field(description="One line naming the hypothesis, e.g. 'swing applied twice to the same note'.")
    edits: list[Edit] = Field(description="Edits applied together as one perturbation, all-or-nothing.")


def _copy(src: Path, dest: Path, excludes: tuple[str, ...] = ()) -> None:
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True, exist_ok=True)
    subprocess.run(["rsync", "-a", *excludes, f"{src}/", f"{dest}/"], check=True,
                   capture_output=True)


def _apply(root: Path, pert: Perturbation) -> Optional[str]:
    """Apply every edit or none, returning a reason string on refusal.

    Staged in memory and written at the end so a two-edit perturbation with one bad
    `old` leaves the copy pristine rather than half-broken — a half-applied
    perturbation would be a verdict about nothing in particular.
    """
    staged: dict[str, str] = {}
    for edit in pert.edits:
        target = (root / edit.path).resolve()
        if not target.is_relative_to(root.resolve()):
            return f"{edit.path}: path escapes the copied tree"
        if not target.is_file():
            return f"{edit.path}: no such file in the copied tree"
        source = staged.get(edit.path, target.read_text(encoding="utf-8"))
        hits = source.count(edit.old)
        if hits != 1:
            excerpt = edit.old if len(edit.old) <= 70 else edit.old[:67] + "..."
            return f"{edit.path}: {hits} matches for {excerpt!r} (need exactly 1)"
        staged[edit.path] = source.replace(edit.old, edit.new, 1)
    for path, text in staged.items():
        (root / path).write_text(text, encoding="utf-8")
    return None


def _run_suite(root: Path, filt: Optional[str], timeout: int) -> dict:
    """Run `lua tests/run.lua [filt]` in `root`.

    `ran` is False when the run produced no summary line at all: run.lua requires
    its specs outside the per-test xpcall, so a perturbation that breaks loading
    aborts the runner entirely. That must not be read as a kill.
    """
    cmd = ["lua", "tests/run.lua"] + ([filt] if filt else [])
    try:
        proc = subprocess.run(cmd, cwd=str(root), capture_output=True, text=True,
                              timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"ran": False, "raw": f"timed out after {timeout}s"}
    summary = _SUMMARY.search(proc.stdout)
    if not summary:
        head = (proc.stdout + "\n" + proc.stderr).strip()
        return {"ran": False, "raw": head[:1200]}
    return {
        "ran": True,
        "passed": int(summary.group(1)),
        "failed": int(summary.group(2)),
        "killers": _FAIL_LINE.findall(proc.stdout),
    }


def _name_list(names: list[str], cap: int = 4) -> str:
    shown = ["      " + n.strip() for n in names[:cap]]
    if len(names) > cap:
        shown.append(f"      (+{len(names) - cap} more)")
    return "\n".join(shown)


@mcp.tool(structured_output=False)
def spec_perturb(
    perturbations: list[Perturbation],
    filter: str,
    escalate: bool = True,
    timeout: int = 60,
) -> str:
    """Tooth-test a spec: break what it claims to pin, check that it notices.

    Each perturbation is applied to its own throwaway copy of the *working tree*
    (uncommitted changes included) and the filtered suite is run there. The live
    tree is never touched. Perturbations run sequentially in the order given —
    a targeted run costs ~0.2s including the copy, so a batch of six is ~1.5s.

    Verdicts are inverted: a perturbation that leaves the spec green is a finding
    about the spec, not a pass.

      killed          the spec noticed — the named tests failed
      SURVIVED        the spec did not notice; the mechanism is unpinned
      did-not-apply   `old` was not found exactly once, so NOTHING was perturbed
      broken          the perturbed tree does not load; the run never reached the
                      tests, so this is not a kill either

    The last two exist so a green run can never be misread as a survival. The
    batch also pre-flights `filter` against an unperturbed copy and aborts if it
    matches no tests or is already red, since kills can't be attributed in either
    case.

    Author perturbations as hypotheses, one per claim the code makes — the
    annotations at the site are usually the menu ('--contract: > tol keeps,
    == tol collapses' names its own mutation). This tool deliberately does not
    generate mutants or emit a score.

    Args:
      filter: literal substring matched against `<spec> :: <test>`, as for
              lua_test_run. Applies to every perturbation in the batch.
      escalate: on SURVIVED, also run the whole suite to separate "nothing
                anywhere catches this" from "the teeth are in another spec".
                Costs ~21s per survivor (default True).
      timeout: seconds per suite run (default 60).

    Returns:
      A summary line of verdict counts, then one block per perturbation in the
      order given, naming the tests that killed it or the reason it lived.
    """
    if shutil.which("lua") is None:
        return "--- ERROR: `lua` not on PATH ---"
    if shutil.which("rsync") is None:
        return "--- ERROR: `rsync` not on PATH ---"
    if not perturbations:
        return "--- ERROR: no perturbations given ---"

    shutil.rmtree(WORKSPACE, ignore_errors=True)

    # One snapshot for the whole batch: every perturbation is then a verdict about
    # the same tree, even if the working tree is edited while the batch runs.
    pristine = WORKSPACE / "pristine"
    _copy(PROJECT_ROOT, pristine, EXCLUDES)

    preflight = _run_suite(pristine, filter, timeout)
    if not preflight["ran"]:
        return "--- ABORT: the unperturbed tree does not run ---\n" + preflight["raw"]
    baseline = preflight["passed"]
    if baseline + preflight["failed"] == 0:
        return f"--- ABORT: filter {filter!r} matched no tests — nothing would have been perturbed ---"
    if preflight["failed"]:
        return (f"--- ABORT: filter {filter!r} is already red before any perturbation ---\n"
                "kills could not be attributed. Failing now:\n" + _name_list(preflight["killers"], 8))

    counts = {"killed": 0, "SURVIVED": 0, "did-not-apply": 0, "broken": 0}
    blocks: list[str] = []

    for index, pert in enumerate(perturbations):
        tree = WORKSPACE / f"p{index}"
        _copy(pristine, tree)

        refusal = _apply(tree, pert)
        if refusal:
            counts["did-not-apply"] += 1
            blocks.append(f"DID-NOT-APPLY   {pert.label}\n      {refusal}\n"
                          "      nothing was perturbed — this is not a survival")
            shutil.rmtree(tree, ignore_errors=True)
            continue

        result = _run_suite(tree, filter, timeout)
        if not result["ran"]:
            counts["broken"] += 1
            blocks.append(f"BROKEN   {pert.label}\n"
                          "      the perturbed tree never reached the tests, so nothing was tested:\n"
                          + "\n".join("      " + ln for ln in result["raw"].splitlines()[:12]))
            continue

        if result["failed"]:
            counts["killed"] += 1
            blocks.append(f"killed by {result['failed']}   {pert.label}\n"
                          + _name_list(result["killers"]))
            shutil.rmtree(tree, ignore_errors=True)
            continue

        counts["SURVIVED"] += 1
        lines = [f"** SURVIVED **   {pert.label}",
                 f"      {result['passed']} targeted tests ran, none noticed"]
        if escalate:
            whole = _run_suite(tree, None, max(timeout, 120))
            if not whole["ran"]:
                lines.append("      whole suite: did not run — " + whole["raw"].splitlines()[0][:120])
            elif whole["failed"]:
                lines.append(f"      whole suite: killed by {whole['failed']} elsewhere — the teeth are in another spec")
                lines.append(_name_list(whole["killers"]))
            else:
                lines.append(f"      whole suite: {whole['passed']} passed — nothing anywhere catches this")
        lines.append(f"      tree kept: {tree}")
        blocks.append("\n".join(lines))

    shutil.rmtree(pristine, ignore_errors=True)

    tally = ", ".join(f"{n} {verdict}" for verdict, n in counts.items() if n)
    header = f"{tally}   filter={filter!r} ({baseline} tests green before perturbing)"
    return header + "\n\n" + "\n\n".join(blocks)


if __name__ == "__main__":
    mcp.run()
