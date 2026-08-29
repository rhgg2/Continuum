#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2,<2"]
# ///
"""Reaper eval bridge MCP server.

Two tools: reaper_eval and reaper_reload. Eval writes a Lua chunk to a spool dir that bridge.lua —
running inside the live Continuum instance's defer loop — executes, then
returns the rendered result. This closes the fake/real gap for REAPER-specific
behaviour (playback stranding, take round-trips, API layout quirks) that
harness tests can't observe. See docs/bridge.md for the model.

Sister servers: continuum_map, reaper_docs, continuum_tests. Same uv-script idiom.
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
SPOOL = PROJECT_ROOT / ".claude" / "mcp" / "reaper" / "spool"

mcp = FastMCP("reaper")


def _sweep() -> None:
    """Delete every spool file. Startup only — clears orphans from a prior server
    run or timed-out calls. Never mid-request: a global delete would race the
    uuid-keyed files of concurrent calls (the client dispatches parallel tool
    uses), which is the exact bug uuid keying exists to prevent.

    action.id is spared: it is durable state (the bridge records Continuum's named
    command id there), and it is needed precisely when no instance is running to
    write it again."""
    for p in SPOOL.glob("*"):
        if p.name == "action.id":
            continue
        try:
            p.unlink()
        except OSError:
            pass


def _spool(code: str, timeout_s: float) -> Optional[str]:
    """Write one request, wait for its response, return it verbatim. None on timeout.

    uuid-keyed files: each call touches only its own req/res, so concurrent calls
    (the client dispatches parallel tool uses) never collide. The bridge serialises
    execution one req per frame; each res-<id> matches its req-<id>."""
    req_id = uuid.uuid4().hex[:8]
    req = SPOOL / f"req-{req_id}.lua"
    res = SPOOL / f"res-{req_id}.txt"
    tmp = SPOOL / f"req-{req_id}.lua.tmp"

    tmp.write_text(code, encoding="utf-8")
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
    return None


def _spawn() -> None:
    """Ask the startup launcher to start Continuum. The marker carries the request time;
    the launcher ignores stale ones, so a marker left behind by a closed REAPER is not
    an instruction days later."""
    tmp = SPOOL / "spawn.marker.tmp"
    tmp.write_text(str(int(time.time())), encoding="utf-8")
    tmp.replace(SPOOL / "spawn.marker")


def _value(response: str) -> str:
    """The response's rendered value section."""
    return response.partition("--- value ---\n")[2].partition("\n--- print ---")[0]


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
    back; it is rendered cycle-safe, userdata via tostring, capped, to `depth`
    levels (default 4).

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
        coord:reloadAfterExternalMutation() or tm/vm drift from the take — and
        that reload finalises the pending undo capture empty, so undo_label is
        only honoured for mm/tm mutations. Route anything undoable through mm/tm.
      - The chunk MUST terminate: it runs on REAPER's UI thread, so a hang or
        infinite loop freezes REAPER with no remedy from outside.
      - No ImGui calls — the chunk runs outside the draw pass.

    Returns:
      The bridge's response verbatim: `status: ok|error`, `ms:`, a `--- value ---`
      section (rendered return value, or error message + traceback), and a
      `--- print ---` section. Or a timeout message if nothing answered.
    """
    out = _spool(_build_request(code, undo_label, depth), timeout_s)
    if out is None:
        return (
            f"no response after {timeout_s:g}s — is Continuum running in REAPER? "
            "The bridge ticks from Continuum's defer loop; if REAPER is open but "
            "Continuum isn't running, nothing polls the spool dir."
        )
    return out


@mcp.tool(structured_output=False)
def reaper_reload(timeout_s: float = 20) -> str:
    """Restart Continuum so edited source takes effect — or start it if it isn't running.

    Returns when Continuum is up and its bridge answering, not merely when the restart
    was asked for. Live UI state is lost; the new instance re-reads the project.

    A syntax or load error in edited source kills the new instance at startup: nothing
    answers, and this returns a timeout naming that cause. Check REAPER's console.
    """
    started = time.monotonic()
    ack = _spool("return reload()", 5)
    if ack is None:
        # Nothing is running to reload, so ask REAPER's startup launcher to start one.
        _spawn()
        pong = _spool("return bootTime", max(1.0, timeout_s - (time.monotonic() - started)))
        if pong is None:
            return (f"nothing answered within {timeout_s:g}s, before or after asking the "
                    "launcher to start Continuum. Is REAPER running, and is __startup.lua "
                    "installed? See docs/bridge.md § Spawning.")
        return (f"nothing was running — started Continuum, up after "
                f"{time.monotonic() - started:.1f}s")
    if not ack.startswith("status: ok"):
        return "the bridge refused the reload:\n" + ack

    # One ping, not a poll: the old instance relaunches on its next tick without
    # scanning again, so this request survives the restart and the new instance's
    # first tick answers it. bootTime differs per instance, so an unchanged one means
    # the old instance is still running and the relaunch silently failed.
    remaining = max(1.0, timeout_s - (time.monotonic() - started))
    pong = _spool("return bootTime", remaining)
    if pong is None:
        return (f"reload requested, but nothing answered within {timeout_s:g}s — the new "
                "instance likely died at load. Check REAPER's console for the error.")
    if _value(pong) == _value(ack):
        return ("reload requested, but the same instance answered — the relaunch did not "
                "happen. Restart Continuum by hand.\n" + pong)
    return f"reloaded — Continuum back up after {time.monotonic() - started:.1f}s"


if __name__ == "__main__":
    mcp.run()
