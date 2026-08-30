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

One REAPER serves however many worktrees have sessions open, and the symlink it
loads Continuum through decides which one is live. reaper_reload claims it; eval
never does. See docs/bridge.md § Claiming REAPER.

Sister servers: continuum_map, reaper_docs, continuum_tests. Same uv-script idiom.
"""

from __future__ import annotations

import os
import subprocess
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

# REAPER loads Continuum through this symlink, so it names the tree that is live.
# Hardcoded rather than asked for: GetResourcePath() needs a running instance, and
# the one moment this path matters most is when nothing is running to be asked.
LINK = Path.home() / "Library/Application Support/REAPER/Scripts/Continuum"

# Where the link should point when no session holds it, recorded beside the link
# because that is the one place readable when the link itself is broken. See _claim.
HOME = LINK.with_name(LINK.name + ".home")

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


def _holder() -> Optional[Path]:
    """The tree REAPER currently loads Continuum from, or None if the link is gone.

    The link names a tree's src/, since that is what REAPER installs; every caller
    here compares against trees, so the parent is what they mean."""
    try:
        return Path(os.readlink(LINK)).parent
    except OSError:
        return None


def _main_tree() -> Optional[Path]:
    """The repo's main worktree, or None if this tree is not in a repo.

    PROJECT_ROOT is whichever tree this server started in, and that one can be
    deleted with the session that made it. Only the main tree outlives every
    session, so it is the only safe thing to send REAPER back to."""
    try:
        done = subprocess.run(
            ["git", "-C", str(PROJECT_ROOT), "rev-parse",
             "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    common = done.stdout.strip()
    return Path(common).parent if done.returncode == 0 and common else None


def _claim() -> None:
    """Point REAPER at this tree.

    bridge.lua and the launcher both derive their spool dir from the path they were
    loaded from and never resolve it, so the string they re-stat every tick is the
    link itself. A repoint therefore moves the code the next launch reads and the
    spool the running instance polls, together, on its next frame. rename over the
    link makes that one step: there is no moment when the link is nowhere.

    Only reload calls this. A claim on eval would mean any session could pull REAPER
    out from under whoever is watching it, which is precisely the confusion separate
    worktrees exist to end.

    action.id is seeded from the outgoing tree when this one has none. It names an
    action registered against a script path that never changes, so it is a fact about
    the REAPER install rather than about a tree -- but the launcher only ever reads it
    through the link, and without it a fresh worktree can restart a live Continuum and
    never start a dead one.

    The fallback is recorded before anything moves. SessionEnd hands the link back
    when it runs, and there are ordinary ends where it does not: a `claude --worktree`
    session deletes the worktree hosting that hook before SessionEnd can fire it. The
    link is then left naming a tree that no longer exists, which stops Continuum
    starting at all, with no session left running to notice. __startup.lua repairs it
    from this file at the next REAPER launch.
    """
    home = _main_tree()
    if home is not None:
        # The link target, not the tree: __startup.lua relinks to this string
        # verbatim, and REAPER loads Continuum from a tree's src/.
        HOME.write_text(f"{home}/src\n", encoding="utf-8")
    held = _holder()
    if held == PROJECT_ROOT:
        return
    mine = SPOOL / "action.id"
    if held is not None and not mine.exists():
        theirs = held / ".claude" / "mcp" / "reaper" / "spool" / "action.id"
        if theirs.exists():
            mine.write_text(theirs.read_text(encoding="utf-8"), encoding="utf-8")
    staging = LINK.with_name(LINK.name + ".claim")
    staging.unlink(missing_ok=True)
    staging.symlink_to(PROJECT_ROOT / "src")
    os.replace(staging, LINK)


def _why_silent() -> str:
    """Why nothing answered, as far as the link can say without asking REAPER.

    Under one worktree per session the commonest cause is that another tree holds
    REAPER, which from here looks exactly like a dead instance: the requests land in
    a spool nobody polls. Distinguishing the two is the whole reason this reads the
    link rather than naming one cause and hoping."""
    held = _holder()
    if held is None:
        return (f"{LINK} is missing, so REAPER has no Continuum to load at all. "
                "See docs/bridge.md § Claiming REAPER.")
    if held != PROJECT_ROOT:
        return (f"REAPER is loaded from {held}, not this tree. Its bridge polls that "
                "tree's spool and never sees these requests; reaper_reload claims it.")
    return ("is Continuum running in REAPER? The bridge ticks from Continuum's defer "
            "loop; if REAPER is open but Continuum isn't running, nothing polls the "
            "spool dir.")


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
        return f"no response after {timeout_s:g}s — {_why_silent()}"
    return out


@mcp.tool(structured_output=False)
def reaper_reload(timeout_s: float = 20) -> str:
    """Restart Continuum so edited source takes effect — or start it if it isn't running.

    Claims REAPER for this tree: repoints the symlink it loads Continuum through, so
    the instance that comes back is running this session's code. Any other session's
    eval goes silent until it claims REAPER in turn. See docs/bridge.md § Claiming
    REAPER.

    Returns when Continuum is up and its bridge answering, not merely when the restart
    was asked for. Live UI state is lost; the new instance re-reads the project.

    A syntax or load error in edited source kills the new instance at startup: nothing
    answers, and this returns a timeout naming that cause. Check REAPER's console.
    """
    started = time.monotonic()
    _claim()
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
