#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2"]
# ///
"""Reaper eval bridge MCP server.

One tool: reaper_eval. Writes a Lua chunk to a spool dir that bridge.lua —
running inside the live Continuum instance's defer loop — executes, then
returns the rendered result. This closes the fake/real gap for REAPER-specific
behaviour (playback stranding, take round-trips, API layout quirks) that
harness tests can't observe. See design/reaper-bridge.md.

Sister servers: readium_docs, readium_tests. Same uv-script idiom.
"""

from __future__ import annotations

import time
import uuid
from pathlib import Path
from typing import Optional

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.utilities.func_metadata import ArgModelBase
from pydantic import ConfigDict

# Strict input validation: reject unknown kwargs so silent param-name slips fail loudly.
ArgModelBase.model_config = ConfigDict(arbitrary_types_allowed=True, extra='forbid')

PROJECT_ROOT = Path(__file__).resolve().parents[3]
SPOOL = PROJECT_ROOT / ".claude" / "mcp" / "reaper" / "spool"

mcp = FastMCP("reaper")


def _sweep() -> None:
    """Delete every spool file. Startup only — clears orphans from a prior server
    run or timed-out calls. Never mid-request: a global delete would race the
    uuid-keyed files of concurrent calls (the client dispatches parallel tool
    uses), which is the exact bug uuid keying exists to prevent."""
    for p in SPOOL.glob("*"):
        try:
            p.unlink()
        except OSError:
            pass


def _build_request(code: str, undo_label: Optional[str], depth: Optional[int]) -> str:
    lines = []
    if undo_label:
        lines.append("--#undo " + undo_label.replace("\n", " "))
    if depth is not None:
        lines.append("--#depth " + str(depth))
    lines.append(code)
    return "\n".join(lines)


# Creating the spool dir is what switches the bridge on (its enable-gate stats for
# this dir). Sweep leftovers from any prior server run.
SPOOL.mkdir(parents=True, exist_ok=True)
_sweep()


@mcp.tool(structured_output=False)
def reaper_eval(
    code: str,
    timeout_s: float = 5,
    undo_label: Optional[str] = None,
    depth: Optional[int] = None,
) -> str:
    """Execute a Lua chunk inside the running Continuum instance and return the result.

    The chunk runs at the coordinator's per-frame tick — before the page draws,
    REAPER API legal, manager stack quiescent. `return <expr>` to get a value
    back; it is rendered (cycle-safe, userdata via tostring, capped).

    Environment (curated — Continuum modules are locals, not globals):
      reaper, util                   — REAPER API + shared helpers
      cm, ds, eventMeta, cmgr, coord — configManager, dataStore, eventMeta,
                                       commandManager, coordinator
      facade(name)                   — curated production facade for a page
      page(name)                     — raw page stack for diagnostics;
                                       page('tracker') = { mm, tm, gm, ccm, pa, tv, tr }
      print(...)                     — buffered into the response's print section

    Safety contract:
      - Confirm with the user before any destructive chunk. Pass undo_label for
        ANY mutation so it lands as one named REAPER undo step.
      - Mutations through mm/tm fire hooks and need nothing further. After a raw
        reaper.* edit to the bound take, the chunk must call
        coord:reloadAfterExternalMutation() or tm/vm drift from the take.
      - The chunk MUST terminate: it runs on REAPER's UI thread, so a hang or
        infinite loop freezes REAPER with no remedy from outside.
      - No ImGui calls — the chunk runs outside the draw pass.

    Args:
      code: the Lua chunk. `return` a value to render it.
      timeout_s: give up waiting for the response after this long (default 5).
      undo_label: wrap the chunk in an undo block with this label (mutations only).
      depth: override the render depth (default 4).

    Returns:
      The bridge's response verbatim: `status: ok|error`, `ms:`, a `--- value ---`
      section (rendered return value, or error message + traceback), and a
      `--- print ---` section. Or a timeout message if nothing answered.
    """
    # uuid-keyed files: each call touches only its own req/res, so concurrent calls
    # (the client dispatches parallel tool uses) never collide. The bridge serialises
    # execution one req per frame; each res-<id> matches its req-<id>.
    req_id = uuid.uuid4().hex[:8]
    req = SPOOL / f"req-{req_id}.lua"
    res = SPOOL / f"res-{req_id}.txt"
    tmp = SPOOL / f"req-{req_id}.lua.tmp"

    tmp.write_text(_build_request(code, undo_label, depth), encoding="utf-8")
    tmp.replace(req)  # atomic; the .tmp name can't match the bridge's req glob

    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if res.exists():
            out = res.read_text(encoding="utf-8", errors="replace")
            res.unlink(missing_ok=True)
            req.unlink(missing_ok=True)  # bridge already removed it pre-execute
            return out
        time.sleep(0.05)

    req.unlink(missing_ok=True)
    return (
        f"no response after {timeout_s:g}s — is Continuum running in REAPER? "
        "The bridge ticks from Continuum's defer loop; if REAPER is open but "
        "Continuum isn't running, nothing polls the spool dir."
    )


if __name__ == "__main__":
    mcp.run()
