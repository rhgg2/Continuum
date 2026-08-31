"""Shared map-index primitives: the join from a call site to its callee's
declaration.

Split out of `.claude/mcp/map/server.py` so a plain script can use the same
resolution the MCP server does. The server is a PEP 723 `uv run --script` with
an `mcp` dependency, and importing it from an ordinary tool would drag that in
for the sake of a dozen pure functions. Both consumers now share one owner for
the self-name registry, the receiver alias resolution and the api-beats-fn
candidate rule, so a fix to the join lands in both rather than in one.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import NamedTuple

PROJECT_ROOT = Path(__file__).resolve().parents[1]
MAP_DIR = PROJECT_ROOT / "map"


# ----- Map-file grammar

MAP_HEADER_RE = re.compile(r'^@(?:module|spec)\s+(\S+)\s+src=(\S+)\s+loc=(\d+)')
DECL_RE = re.compile(
    r'^(?P<indent>\s*)@(?P<kind>fn|api|held|handler|state|const|require|construct|case)\s+'
    r'(?P<head>.+?)\s*@\s*(?P<line>\d+)(?:-(?P<end>\d+))?\s*'
    r'(?P<doc>(?:--|·).*)?$'
)
# A @use target names its receiver by the short instance name the calling file
# binds it to (`cm`), not by module, so resolving one needs the registry below.
SELF_RX = re.compile(r'^@module\s+(?P<mod>\S+)\b.*\bself=(?P<self>\S+)')
TARGET_RX = re.compile(r'^(\w+)[.:](\w+)$')


def src_of(mp: Path, text: str) -> str:
    h = MAP_HEADER_RE.match(text.split("\n", 1)[0])
    return h.group(2) if h else mp.stem + ".lua"


def bare_name(kind: str, head: str) -> str:
    if kind == "fn":
        # A door-table member is spelled for its table at the declaration and at
        # every call site, as a held function is, so the qualifier is its name.
        m = re.match(r"^([\w.]+)\(", head)
        return m.group(1) if m else head
    if kind == "api":
        m = re.match(r"^[\w]+[:.](\w+)\(", head)
        return m.group(1) if m else head
    # A held function is spelled table-qualified wherever it appears --
    # declaration and call site alike -- and a handler is spelled for the
    # receiver holding it, so the qualifier is part of the name in both.
    if kind in ("held", "handler"):
        m = re.match(r"^[\w.:]+", head)
        return m.group(0) if m else head
    if kind in ("state", "const", "require", "construct"):
        m = re.match(r"^(\w+)", head)
        return m.group(1) if m else head
    if kind == "case":
        m = re.match(r"^'(.*)'", head)
        return m.group(1) if m else head
    return head


# ----- Receiver resolution

def selfname_registry() -> dict:
    """Short instance name -> module, from each module map's `self=` header.
    Namespace modules map their name to itself; wiring files without `self=`
    are absent (they are never receivers, so never usedby targets). Names
    claimed by more than one module (e.g. two files returning a local `M`)
    are ambiguous and dropped."""
    reg: dict = {}
    ambiguous: set = set()
    for mp in sorted(MAP_DIR.glob("*.map")):
        try:
            head = mp.read_text(encoding="utf-8", errors="replace").split("\n", 1)[0]
        except OSError:
            continue
        m = SELF_RX.match(head)
        if m:
            name, mod = m.group("self"), m.group("mod")
            if reg.get(name, mod) != mod:
                ambiguous.add(name)
            reg[name] = mod
    for name in ambiguous:
        del reg[name]
    return reg


def canon_target(target: str, reg: dict):
    """(module, method|None) for a @use target, resolving the receiver's short
    name to its module. A bare target (a require edge) carries no method."""
    m = TARGET_RX.match(target)
    if m:
        return reg.get(m.group(1), m.group(1)), m.group(2)
    return reg.get(target, target), None


# ----- Declaration index and the callee join

class Decl(NamedTuple):
    kind: str    # 'fn' | 'api' | 'held' | 'handler'
    head: str    # as written: `rebuildPbs(fxOut, extraColumns)`
    key: str     # head minus the arg list -- the spelling @call rows use
    bare: str    # the spelling call sites use for their caller
    start: int
    end: int
    src: str


def decl_index(mp: Path) -> list[Decl]:
    """Every fn/api/held/handler declaration in one map. A single-line
    declaration ends where it starts, so the span test still places its call
    sites. Held and handler rows enter wholesale: no @call row spells either as
    its callee today, so the callee join simply never lands on one -- and
    resolves for free if the extractor ever closes that gap."""
    text = mp.read_text(encoding="utf-8", errors="replace")
    src = src_of(mp, text)
    index: list[Decl] = []
    for raw in text.splitlines():
        md = DECL_RE.match(raw)
        if not md or md.group("kind") not in ("fn", "api", "held", "handler"):
            continue
        kind, head = md.group("kind"), md.group("head").strip()
        start = int(md.group("line"))
        index.append(Decl(kind, head, head.split("(", 1)[0].strip(),
                          bare_name(kind, head), start,
                          int(md.group("end") or start), src))
    return index


def decl_indexer():
    """stem -> declaration index, cached for one query only: the maps
    regenerate on every source edit, so a cache outliving the query goes
    stale."""
    cache: dict = {}

    def get(stem):
        if stem not in cache:
            hit = next((p for p in (d / f"{stem}.map"
                                    for d in (MAP_DIR, MAP_DIR / "specs"))
                        if p.exists()), None)
            cache[stem] = decl_index(hit) if hit else []
        return cache[stem]
    return get


def decl_row(e: Decl):
    span = f"{e.start}-{e.end}" if e.end != e.start else f"{e.start}"
    return f"{e.src}:{span}", f"@{e.kind} {e.head}"


def callee_intra_decl(callee, index) -> Decl | None:
    """@call keys its callee by declaration head, so the join is exact."""
    return next((e for e in index if e.key == callee), None)


def callee_cross_decl(target, decls, reg) -> Decl | None:
    """A cross-module callee resolved in the target's own map. Targets with no
    map at all (ImGui and friends) resolve to None -- a true answer, not a
    failure. Call edges only: a non-call edge names a signal or a module."""
    t_module, t_fn = canon_target(target, reg)
    # A cross-module call cannot reach a module-private @fn, so an @api
    # candidate wins by construction rather than as a tiebreak.
    cands = sorted((e for e in decls(t_module) if e.bare == t_fn),
                   key=lambda e: e.kind != "api") if t_fn else []
    return cands[0] if cands else None


# The row-rendering pair the map server reports through. `(external)` and
# `(<ukind>)` are the two ways a target names no declaration, and they stay
# distinct: one is a call that resolved nowhere, the other is not a call.
def callee_intra(callee, index):
    hit = callee_intra_decl(callee, index)
    return decl_row(hit) if hit else ("(external)", callee)


def callee_cross(ukind, target, decls, reg):
    if ukind != "call":
        return f"({ukind})", target
    hit = callee_cross_decl(target, decls, reg)
    return decl_row(hit) if hit else ("(external)", target)
