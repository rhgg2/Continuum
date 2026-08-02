#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2,<2"]
# ///
"""Continuum map-query MCP server.

One tool: map_query — structured search over the project's .map semantic
outlines.

Split from the former readium_docs so the always-loaded navigation tool
ships alone. Sister servers: reaper_docs (reaper_doc_lookup),
continuum_tests (lua_test_run). Batched writes are handled by the global
`patches` server (mcp__patches__apply_patches).
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import NamedTuple, Optional

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.utilities.func_metadata import ArgModelBase
from pydantic import ConfigDict

# Strict input validation: reject unknown kwargs so silent param-name slips fail loudly.
ArgModelBase.model_config = ConfigDict(arbitrary_types_allowed=True, extra='forbid')

PROJECT_ROOT = Path(__file__).resolve().parents[3]
MAP_DIR = PROJECT_ROOT / "map"

mcp = FastMCP("continuum_map")


# Old glob habits produce valid-but-narrower regex: 'same*pitch' quantifies
# the literal 'e'. Advise rather than block.
_LITERAL_QUANT = re.compile(r'(?<!\\)\w\*')


def _glob_smell(pat: Optional[str]) -> Optional[str]:
    m = _LITERAL_QUANT.search(pat) if pat else None
    if m:
        return (f"--- note: regex reads {m.group(0)!r} as a quantified "
                "literal; for a glob-style wildcard use '.*' ---")
    return None


# ----- map_query ------------------------------------------------------------

_MAP_HEADER = re.compile(r'^@(?:module|spec)\s+(\S+)\s+src=(\S+)\s+loc=(\d+)')
_DECL = re.compile(
    r'^(?P<indent>\s*)@(?P<kind>fn|api|state|const|require|construct|case)\s+'
    r'(?P<head>.+?)\s*@\s*(?P<line>\d+)(?:-(?P<end>\d+))?\s*'
    r'(?P<doc>(?:--|·).*)?$'
)
# Annotations: `@invariant`, `@contract`, `@shape`, `@emits`, `@reaper`,
# any of which may carry a leading `?` (`@?invariant …`) for inferred-rather-
# than-doc-grounded variants. `@deps` is rendered on its own line in the header.
_ANN = re.compile(
    r'^(?P<indent>\s*)@(?P<kind>\??(?:invariant|contract|shape|emits|reaper|deps|exercises|surface|harness))\s+'
    r'(?P<body>.*?)(?:\s+@\s+(?P<line>\d+))?\s*$'
)
# `@use <kind> <target>  @ <caller>:<line>[,<line>] [<caller>:<line>...]`
# Top-level edges (e.g. requires) appear as bare line numbers, no caller.
_USE = re.compile(
    r'^\s*@use\s+(?P<ukind>\w+)\s+(?P<target>\S+)\s+@\s+(?P<sites>.+?)\s*$'
)
# `@field r|w <name>  @ <sites>` — hot fields repeat the head across chunked
# rows; sites accumulate across rows.
_FIELD = re.compile(
    r'^\s*@field\s+(?P<fkind>[rw])\s+(?P<name>\w+)\s+@\s+(?P<sites>.+?)\s*$'
)
# `@call <callee>  @ <sites>` — the intra-file reverse index. Sites carry the
# same grammar as @use, so _iter_use_sites parses them unchanged.
_CALL = re.compile(
    r'^\s*@call\s+(?P<callee>\S+)\s+@\s+(?P<sites>.+?)\s*$'
)
# `@bind <name>  @ <sites>` — the by-name reference index. Same site grammar
# as @use and @call, so _iter_use_sites parses it unchanged.
_BIND = re.compile(
    r'^\s*@bind\s+(?P<name>\S+)\s+@\s+(?P<sites>.+?)\s*$'
)
# `@drop <target>  @ <sites>` — qualified call sites whose receiver the
# extractor could not resolve. Same site grammar again.
_DROP = re.compile(r'^\s*@drop\s+(?P<target>\S+)\s+@\s+(?P<sites>.+?)\s*$')


def _iter_use_sites(sites: str):
    """Yield (caller|None, line) from a @use sites field."""
    for seg in sites.split():
        if ':' in seg:
            caller, _, nums = seg.partition(':')
        else:
            caller, nums = None, seg
        for n in nums.split(','):
            n = n.strip()
            if n.isdigit():
                yield caller, n


def _src_of(mp: Path, text: str) -> str:
    h = _MAP_HEADER.match(text.split("\n", 1)[0])
    return h.group(2) if h else mp.stem + ".lua"


def _bare_name(kind: str, head: str) -> str:
    if kind == "fn":
        m = re.match(r"^(\w+)\(", head)
        return m.group(1) if m else head
    if kind == "api":
        m = re.match(r"^[\w]+[:.](\w+)\(", head)
        return m.group(1) if m else head
    if kind in ("state", "const", "require", "construct"):
        m = re.match(r"^(\w+)", head)
        return m.group(1) if m else head
    if kind == "case":
        m = re.match(r"^'(.*)'", head)
        return m.group(1) if m else head
    return head


def _normalize_kind(k: str) -> str:
    k = k.lower().lstrip("?")
    aliases = {
        "signal": "emits", "signals": "emits",
        "invariants": "invariant", "contracts": "contract", "shapes": "shape",
        "fns": "fn", "functions": "fn",
        "apis": "api",
        "states": "state", "consts": "const", "constants": "const",
        "requires": "require", "import": "require", "imports": "require",
        "constructs": "construct",
        "cases": "case",
        "use": "uses", "calls": "uses",
        "usedby": "usedby", "used-by": "usedby", "used_by": "usedby",
        "calledby": "usedby", "called-by": "usedby", "called_by": "usedby",
        "read": "reads", "write": "writes", "field": "fields",
    }
    return aliases.get(k, k)


# Every kind `_map_query` dispatches on. An unknown one used to fall through
# to the generic scan and return "(no matches …)", which reads as absence of
# the thing rather than absence of the filter.
_KINDS = frozenset({
    'fn', 'api', 'state', 'const', 'require', 'construct', 'case',
    'invariant', 'contract', 'shape', 'emits', 'reaper', 'deps',
    'exercises', 'surface', 'harness',
    'uses', 'usedby', 'flow', 'reads', 'writes', 'fields',
})


def _entry_kind(raw_kind: str) -> str:
    return raw_kind.lstrip("?")


# usedby is a reverse index over @use targets; resolving a target's short
# receiver (`cm`) to its module (`configManager`) needs the self-name registry.
_SELF_RX = re.compile(r'^@module\s+(?P<mod>\S+)\b.*\bself=(?P<self>\S+)')
_TARGET_RX = re.compile(r'^(\w+)[.:](\w+)$')


def _selfname_registry() -> dict:
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
        m = _SELF_RX.match(head)
        if m:
            name, mod = m.group("self"), m.group("mod")
            if reg.get(name, mod) != mod:
                ambiguous.add(name)
            reg[name] = mod
    for name in ambiguous:
        del reg[name]
    return reg


def _canon_target(target: str, reg: dict):
    """(module, method|None) for a @use target, resolving the receiver's short
    name to its module. A bare target (a require edge) carries no method."""
    m = _TARGET_RX.match(target)
    if m:
        return reg.get(m.group(1), m.group(1)), m.group(2)
    return reg.get(target, target), None


def _usedby_selectors(query, module, reg):
    """Selectors for a usedby scan, collapsing short names and `:`/`.` spellings.
    Returns (module_pred | None, method | None, raw_regex | None): a @use target
    matches when its canonical module satisfies module_pred, its method equals
    `method`, and its raw text matches raw_regex — each constraint optional."""
    mod_preds = []

    def want_module(tok):
        if re.escape(tok) != tok:
            rx = re.compile(tok, re.IGNORECASE)
            mod_preds.append(lambda mod, rx=rx: bool(rx.fullmatch(mod)))
        else:
            canon = reg.get(tok, tok)
            mod_preds.append(lambda mod, canon=canon: mod == canon)

    if module:
        want_module(module)

    method = None
    raw_rx = None
    if query:
        m = _TARGET_RX.match(query)
        if m:                                       # `cm:get`, `configManager.get`
            want_module(m.group(1))
            method = m.group(2)
        else:                                       # regex over raw target text
            raw_rx = re.compile(query, re.IGNORECASE)

    module_pred = (lambda mod: all(p(mod) for p in mod_preds)) if mod_preds else None
    return module_pred, method, raw_rx


# Both halves of usedby gather without capping: the budget can't be split
# until both totals are known, so neither may break out early.
def _usedby_cross(module_pred, q_fn, raw_rx, reg, dirs) -> list[str]:
    """Cross-module half: every map's @use edges aimed at the selected target."""
    rows: list[str] = []
    for d in dirs:
        for mp in sorted(d.glob("*.map")):
            text = mp.read_text(encoding="utf-8", errors="replace")
            src = _src_of(mp, text)
            site_rows: list[str] = []
            targets: set[str] = set()
            for raw in text.splitlines():
                mu = _USE.match(raw)
                if not mu:
                    continue
                target = mu.group("target")
                t_module, t_fn = _canon_target(target, reg)
                if module_pred and not module_pred(t_module):
                    continue
                if q_fn is not None and t_fn != q_fn:
                    continue
                if raw_rx and not raw_rx.search(target):
                    continue
                ukind = mu.group("ukind")
                targets.add(f"{ukind} {target}")
                for caller, n in _iter_use_sites(mu.group("sites")):
                    where = f"  (in {caller})" if caller else ""
                    site_rows.append(f"{src}:{n}  @use {ukind} {target}{where}")
            # Spec callers collapse to one row per spec file — the file list
            # answers "which specs exercise X"; per-site rows drown production.
            if site_rows and mp.parent.name == "specs":
                plural = "s" if len(site_rows) != 1 else ""
                site_rows = [f"{src}: {len(site_rows)} site{plural}"
                             f"  @use {', '.join(sorted(targets))}"]
            rows.extend(site_rows)
    return rows


def _usedby_intra(module_pred, q_fn, raw_rx, reg) -> list[str]:
    """Intra-module half: each module map's own @call and @bind rows — a helper
    nothing calls is still reached, by the table that binds it. MAP_DIR only —
    spec maps carry neither row kind, and a spec's private helpers are out of
    scope for "who calls this" anyway."""
    rows: list[str] = []
    for mp in sorted(MAP_DIR.glob("*.map")):
        text = mp.read_text(encoding="utf-8", errors="replace")
        src = _src_of(mp, text)
        for raw in text.splitlines():
            mc = _CALL.match(raw)
            mb = None if mc else _BIND.match(raw)
            if mc:
                token, callee, sites = "@call", mc.group("callee"), mc.group("sites")
            elif mb:
                token, callee, sites = "@bind", mb.group("name"), mb.group("sites")
            else:
                continue
            t_module, t_fn = _canon_target(callee, reg)
            # A bare callee needs no resolution: the extractor spells methods
            # qualified, so a bare row is a call on a function of this very
            # file. See design/map-navigation.md § Intra-file call edges.
            if t_fn is None:
                t_module = mp.stem
            if module_pred and not module_pred(t_module):
                continue
            if q_fn is not None and t_fn != q_fn:
                continue
            if raw_rx and not raw_rx.search(callee):
                continue
            for caller, n in _iter_use_sites(sites):
                where = f"  (in {caller})" if caller else ""
                rows.append(f"{src}:{n}  {token} {callee}{where}")
    return rows


def _usedby_drops(module_pred, q_fn, raw_rx, reg) -> list[str]:
    """Dropped-receiver half: sites the extractor could not attribute. The
    receiver is resolved here through the self-name registry — the guess the
    extractor refuses to make, because a wrong alias in the corpus does not
    drop, it lies. Under a heading that says the receiver is unproven it is
    the recall the other two halves cannot give."""
    rows: list[str] = []
    for mp in sorted(MAP_DIR.glob("*.map")):
        text = mp.read_text(encoding="utf-8", errors="replace")
        src = _src_of(mp, text)
        for raw in text.splitlines():
            md = _DROP.match(raw)
            if not md:
                continue
            target = md.group("target")
            m = _TARGET_RX.match(target)
            recv, fn = (m.group(1), m.group(2)) if m else (None, None)
            # A module filter can only select a receiver the registry knows;
            # an unknown one is not a silent pass, it is not this module.
            if module_pred and not (recv in reg and module_pred(reg[recv])):
                continue
            if q_fn is not None and fn != q_fn:
                continue
            if raw_rx and not raw_rx.search(target):
                continue
            for caller, n in _iter_use_sites(md.group("sites")):
                where = f"  (in {caller})" if caller else ""
                rows.append(f"{src}:{n}  @drop {target}{where}")
    return rows


# `uses` reads the *caller* field of the @call and @use rows, which nothing else
# does: what a named function reaches, with each callee resolved to its
# declaration — the jump target the call site itself cannot give you.
# See design/map-navigation.md § Intra-file call edges.
_USES_NOTE = ("--- note: sites inside anonymous closures or unparsed declarations "
              "carry no caller and are absent here; calls on runtime receivers "
              "are dropped ---")


class _Decl(NamedTuple):
    kind: str    # 'fn' | 'api'
    head: str    # as written: `rebuildPbs(fxOut, extraColumns)`
    key: str     # head minus the arg list — the spelling @call rows use
    bare: str    # the spelling call sites use for their caller
    start: int
    end: int
    src: str


def _decl_index(mp: Path) -> list[_Decl]:
    """Every fn/api declaration in one map. A single-line declaration ends where
    it starts, so the span test still places its call sites."""
    text = mp.read_text(encoding="utf-8", errors="replace")
    src = _src_of(mp, text)
    index: list[_Decl] = []
    for raw in text.splitlines():
        md = _DECL.match(raw)
        if not md or md.group("kind") not in ("fn", "api"):
            continue
        kind, head = md.group("kind"), md.group("head").strip()
        start = int(md.group("line"))
        index.append(_Decl(kind, head, head.split("(", 1)[0].strip(),
                           _bare_name(kind, head), start,
                           int(md.group("end") or start), src))
    return index


def _decl_indexer():
    """stem -> declaration index, cached for one _map_query call only: the maps
    regenerate on every source edit, so a cache outliving the call goes stale."""
    cache: dict = {}

    def get(stem):
        if stem not in cache:
            hit = next((p for p in (d / f"{stem}.map"
                                    for d in (MAP_DIR, MAP_DIR / "specs"))
                        if p.exists()), None)
            cache[stem] = _decl_index(hit) if hit else []
        return cache[stem]
    return get


def _decl_row(e: _Decl):
    span = f"{e.start}-{e.end}" if e.end != e.start else f"{e.start}"
    return f"{e.src}:{span}", f"@{e.kind} {e.head}"


def _callee_intra(callee, index):
    """@call keys its callee by declaration head, so the join is exact."""
    hit = next((e for e in index if e.key == callee), None)
    return _decl_row(hit) if hit else ("(external)", callee)


def _callee_cross(ukind, target, decls, reg):
    """A cross-module callee resolved in the target's own map. Targets with no
    map at all (ImGui and friends) are `(external)` — a true answer, not a
    failure. Non-call edges name a signal or a module, not a declaration."""
    if ukind != "call":
        return f"({ukind})", target
    t_module, t_fn = _canon_target(target, reg)
    # A cross-module call cannot reach a module-private @fn, so an @api
    # candidate wins by construction rather than as a tiebreak.
    cands = sorted((e for e in decls(t_module) if e.bare == t_fn),
                   key=lambda e: e.kind != "api") if t_fn else []
    return _decl_row(cands[0]) if cands else ("(external)", target)


def _uses_groups(mp: Path, query_rx, decls, reg) -> list:
    """[(subject, rows)] for each matching declaration in one map, rows being
    (location, head, sites) per callee. The span test is load-bearing: sites
    spell their caller bare, and a bare name can be claimed by two declarations
    in one map (`addEvent` and `tm:addEvent`)."""
    index = decls(mp.stem)
    subjects = [e for e in index if query_rx.search(e.bare)]
    if not subjects:
        return []
    edges: list[dict] = [{} for _ in subjects]

    def owner(caller, line):
        return next((i for i, e in enumerate(subjects)
                     if e.bare == caller and e.start <= line <= e.end), None)

    for raw in mp.read_text(encoding="utf-8", errors="replace").splitlines():
        mc = _CALL.match(raw)
        mb = None if mc else _BIND.match(raw)
        mu = None if (mc or mb) else _USE.match(raw)
        if mc:
            scope, ukind, target = "intra", "call", mc.group("callee")
            sites = mc.group("sites")
        elif mb:
            scope, ukind, target = "intra", "bind", mb.group("name")
            sites = mb.group("sites")
        elif mu:
            scope, ukind, target = "cross", mu.group("ukind"), mu.group("target")
            sites = mu.group("sites")
        else:
            continue
        for caller, n in _iter_use_sites(sites):
            if caller is None:
                continue
            line = int(n)
            i = owner(caller, line)
            if i is None:
                continue
            group = edges[i]
            key = (scope, ukind, target)
            if key not in group:
                loc, head = (_callee_intra(target, index) if scope == "intra"
                             else _callee_cross(ukind, target, decls, reg))
                if ukind == "bind":
                    head += "  (by name)"    # bound, not called
                group[key] = (loc, head, [])
            group[key][2].append(line)

    # Callees ordered by first call site, so the list reads in the order the
    # body executes.
    return [(e, sorted(((loc, head, sorted(lines))
                        for loc, head, lines in g.values()),
                       key=lambda r: r[2][0]))
            for e, g in zip(subjects, edges)]


def _uses_render(groups, max_results) -> str:
    out: list[str] = []
    budget = max_results
    truncated = False
    for subject, rows in groups:
        if rows and budget <= 0:
            truncated = True
            break
        if out:
            out.append("")
        loc, head = _decl_row(subject)
        out.append(f"{loc}  {head}  "
                   + (f"reaches {len(rows)}:" if rows else "reaches nothing"))
        shown = rows[:budget]
        wide_loc = max((len(r[0]) for r in shown), default=0)
        wide_head = max((len(r[1]) for r in shown), default=0)
        for r_loc, r_head, lines in shown:
            out.append(f"  {r_loc:<{wide_loc}}  {r_head:<{wide_head}}  <- "
                       + ",".join(str(n) for n in lines))
        budget -= len(shown)
        truncated = truncated or len(shown) < len(rows)
    if truncated:
        out.append(f"--- truncated at {max_results}; narrow the query ---")
    out.append(_USES_NOTE)
    return "\n".join(out)


def _module_pointer(query, reg, kind_label):
    """A query naming a module is a module-subject question, and both directions
    take that subject through `module=`. usedby needs this guard before its
    search rather than after: require-edge targets are bare module names, so a
    module name falling through to the raw-target regex returns the require rows
    only — a partial answer wearing a complete one's clothes."""
    if not query or not (query in reg or query in set(reg.values())):
        return None
    return (f"({query!r} names a module, not a function; kind={kind_label!r} "
            f"takes a module as module={reg.get(query, query)!r}, no query)")


def _section(name, shown, total, na=None) -> str:
    if na:
        return f"{name}  {na}"
    if total == 0:
        return f"{name}  (none)"
    return (f"{name}  ({total})" if shown == total
            else f"{name}  (showing {shown} of {total})")


def _split_budget(sizes: list[int], budget: int) -> list[int]:
    """Even share of `budget` across sections, each donating what it cannot
    use to the others. Reproduces the two-section split it replaces."""
    if sum(sizes) <= budget:
        return list(sizes)
    share = budget // len(sizes)
    keep = [min(n, share) for n in sizes]
    left = budget - sum(keep)
    for i, n in enumerate(sizes):
        take = min(n - keep[i], left)
        keep[i] += take
        left -= take
    return keep


# `flow` walks the signal rows already in the maps: `@emits` (owner = the
# map's module, fire-sites in the tail), `@use sub owner:signal`, and
# `@use forward source:signal` (the forwarder re-fires under its own name).
_EMITS_ROW = re.compile(r'^\s*@\??emits\s+(?P<name>\S+)\s*(?P<rest>.*?)\s*$')


def _signal_graph(reg):
    """One scan over every map. Returns (emits, subs, forwards): emits maps
    (module, signal) -> (payload, fire-sites, src); subs and forwards map
    (owner module, signal) -> site lists. Owner short names resolve through
    the registry; a literal `self` owner is the map's own module."""
    emits, subs, forwards = {}, {}, {}
    for d in (MAP_DIR, MAP_DIR / "specs"):
        for mp in sorted(d.glob("*.map")):
            try:
                text = mp.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            src = _src_of(mp, text)
            for raw in text.splitlines():
                me = _EMITS_ROW.match(raw)
                if me:
                    rest = me.group("rest")
                    if " @ " in rest:
                        payload, sites = rest.rsplit(" @ ", 1)
                    elif rest.startswith("@ "):
                        payload, sites = "", rest[2:]
                    else:
                        payload, sites = rest, ""
                    payload = payload.strip().removeprefix("--").strip()
                    emits[(mp.stem, me.group("name"))] = (payload, sites, src)
                    continue
                mu = _USE.match(raw)
                if not mu or mu.group("ukind") not in ("sub", "forward"):
                    continue
                owner, signal = _canon_target(mu.group("target"), reg)
                if signal is None:
                    continue
                if owner == "self":
                    owner = mp.stem
                for caller, n in _iter_use_sites(mu.group("sites")):
                    if mu.group("ukind") == "sub":
                        subs.setdefault((owner, signal), []).append((src, n, caller))
                    else:
                        forwards.setdefault((owner, signal), []).append((mp.stem, src, n))
    return emits, subs, forwards


@mcp.tool(structured_output=False)
def map_query(
    query: Optional[str] = None,
    kind: Optional[str] = None,
    module: Optional[str] = None,
    max_results: int = 60,
) -> str:
    """Structured query over the project's .map semantic outlines.

    Replaces `grep '@fn' map/*.map` and the follow-up read-the-source dance.
    Results carry the originating .lua file:line so you can jump straight
    to the declaration with Read offset/limit.

    Args:
      query: regex — case-insensitive, substring-matched (anchor with
             ^$ for exact; alternation works: 'ppqL|endppqL'). NOT
             glob: plain text already substring-matches, so no
             wrapping stars. Matches bare symbol names for structural
             entries (`@fn`, `@api`, `@state`, `@const`, `@require`,
             `@construct`), full body text for annotations
             (`@invariant`, `@contract`, `@shape`, `@emits`, `@reaper`),
             and field names for reads/writes/fields.
             Omit to return everything matching the other filters.
      kind: filter by entry kind. Accepted (case-insensitive, plurals
            ok): fn, api, state, const, require/import, construct,
            case (spec test cases), invariant, contract, shape,
            emits/signal, reaper, deps, uses/calls, usedby/calledby,
            flow, reads/writes/fields. `uses` and `usedby` are the two
            directions of one relation and `query` names the subject in
            both: `uses` is what the subject reaches, `usedby` what
            reaches it. `uses` groups by matching declaration and
            resolves each callee to *its own declaration*, so the answer
            is jump-ready; what it reaches includes what it binds by
            name (marked `(by name)`), not just what it calls; with
            `module` and no `query` it falls back to
            that module's flat outbound edge list (calls / subs /
            forwards / requires).
            `usedby` answers in three labelled sections:
            cross-module `@use` edges, scanning every map (specs
            included, so it also answers "which specs exercise X";
            spec callers collapse to one summary row per spec file),
            the declaring file's own intra-module `@call` and
            `@bind` rows, so a private helper's callers come back from
            the same query — and so does the command or export table
            that binds a helper nothing calls — and `@drop` sites,
            whose receiver the extractor could not resolve and which
            are matched here by name: candidates, not confirmed edges.
            `(none)` under that heading is a real answer, that nothing
            matching was dropped.
            Both halves resolve short instance names and `:`/`.`
            spellings so `cm:get`, `configManager.get`, and
            module='configManager' all match; a module-level target has
            no intra half, since `@call` keys on functions.
            `flow` traces a signal
            end-to-end — emitters (`@emits` payload + fire-sites),
            subscribers, and forward hops followed transitively;
            query names the signal, `module` optionally pins the
            origin emitter. `reads`/`writes` walk
            the @field rows — every `.name` read or write site
            (table-constructor keys count as writes); `fields`
            returns both. query substring-matches the field name
            (anchor `^name$` for one exact field); omit `module`
            to sweep every module and spec for the blast radius.
            Omit for any.
      module: restrict to a module by stem — regex, anchored (it names
              .map files): `trackerManager`, `tm_.*`, `.*Manager`.
              Spec maps (map/specs/, one per
              tests/specs/*_spec.lua) join every query; their stems end
              `_spec`, so module='.*_spec' restricts to specs.
              Under kind='uses' and kind='usedby' it says which module
              the subject named by `query` lives in, resolved via the
              self-name registry (`cm` and `configManager` are one
              module); with no `query` the module is itself the subject,
              so usedby+module='eventMeta' answers "who uses eventMeta"
              and uses+module='eventMeta' its own outbound edges.
              Under kind='flow' it pins the origin emitter, same
              resolution.
      max_results: cap (default 60).

    Returns:
      Lines of `<source>.lua:<line>  @kind <head>` for structural entries,
      and `<source>.lua  @kind  <body>` for annotations.
    """
    for pat in (query, module):
        if pat:
            try:
                re.compile(pat)
            except re.error as exc:
                return (f"--- ERROR: {pat!r} is not valid regex ({exc}). Queries "
                        "are regex, not glob: plain text substring-matches; use "
                        "'.*' where glob habits reach for '*' ---")
    out = _map_query(query, kind, module, max_results)
    notes = [n for n in (_glob_smell(query), _glob_smell(module)) if n]
    return "\n".join([out, *notes]) if notes else out


def _map_query(query, kind, module, max_results) -> str:
    if not MAP_DIR.exists():
        return f"--- ERROR: {MAP_DIR} not found ---"

    query_rx = re.compile(query, re.IGNORECASE) if query else None
    kind_filter = _normalize_kind(kind) if kind else None
    if kind_filter and kind_filter not in _KINDS:
        return (f"--- ERROR: kind={kind!r} is not a kind. Valid: "
                f"{', '.join(sorted(_KINDS))} ---")

    dirs = (MAP_DIR, MAP_DIR / "specs")

    # `usedby` is a reverse index: it scans EVERY map (a caller can live
    # anywhere) and matches the target through the self-name registry, so
    # `module` here names the used target, not a file to read. Handled up
    # front — it needs neither `module` as a filename nor `query_rx`.
    if kind_filter == 'usedby':
        reg = _selfname_registry()
        pointer = _module_pointer(query, reg, 'usedby')
        if pointer:
            return pointer
        module_pred, q_fn, raw_rx = _usedby_selectors(query, module, reg)
        if module_pred is None and q_fn is None and raw_rx is None:
            return ("(usedby needs a target: pass query= or module= naming "
                    "the used symbol or module, e.g. query='cm:get' or "
                    "module='configManager')")
        cross = _usedby_cross(module_pred, q_fn, raw_rx, reg, dirs)
        # @call keys on functions, so a module-level target has no intra half:
        # trackerManager calling itself is not an answer to "who uses it".
        intra = (None if q_fn is None and raw_rx is None
                 else _usedby_intra(module_pred, q_fn, raw_rx, reg))
        drops = _usedby_drops(module_pred, q_fn, raw_rx, reg)
        if not cross and not drops and intra is not None and not intra:
            return (f"(no callers found for query={query!r}, module={module!r}; "
                    "the cross-module, intra-module and dropped-receiver "
                    "indexes were all searched)")

        sizes = [len(cross), 0 if intra is None else len(intra), len(drops)]
        keep_cross, keep_intra, keep_drops = _split_budget(sizes, max_results)

        # Rows keep their @use/@call/@drop token under the header, so a row
        # copied out of context still says which index it came from.
        results = [_section("Cross-module", keep_cross, sizes[0])]
        results += [f"  {r}" for r in cross[:keep_cross]]
        results.append(_section(
            "Intra-module", keep_intra, sizes[1],
            na=("(n/a — module-level target; the intra index keys on functions)"
                if intra is None else None)))
        results += [f"  {r}" for r in (intra or [])[:keep_intra]]
        results.append(_section("Dropped receivers", keep_drops, sizes[2]))
        if keep_drops:
            results.append("  (receiver unresolved by the extractor, matched "
                           "here by name — candidates, not confirmed edges)")
        results += [f"  {r}" for r in drops[:keep_drops]]
        return "\n".join(results)

    # `flow` also scans every map (subscribers live anywhere): emitters first,
    # then subscribers and forward hops followed transitively, then any
    # sub/forward rows on a matching signal no emitter reaches (doc gaps).
    if kind_filter == 'flow':
        if not query_rx:
            return ("(flow needs query= naming the signal, e.g. "
                    "query='takeSwapped')")
        reg = _selfname_registry()
        emits, subs, forwards = _signal_graph(reg)
        selfof = {mod: name for name, mod in reg.items()}

        def owner_ok(mod):
            if not module:
                return True
            return mod == reg.get(module, module) or bool(
                re.fullmatch(module, mod, re.IGNORECASE))

        def short(mod):
            return selfof.get(mod, mod)

        lines_out: list = []
        visited: set = set()

        def walk(mod, sig, depth):
            visited.add((mod, sig))
            pad = '  ' * depth
            for src, n, caller in subs.get((mod, sig), ()):
                where = f"  (in {caller})" if caller else ""
                lines_out.append(f"{pad}  sub      {src}:{n}{where}")
            for fmod, fsrc, fn in forwards.get((mod, sig), ()):
                lines_out.append(f"{pad}  forward  {fsrc}:{fn}  → {short(fmod)}:{sig}")
                if (fmod, sig) not in visited:
                    walk(fmod, sig, depth + 1)

        for mod, sig in sorted(k for k in emits
                               if query_rx.search(k[1]) and owner_ok(k[0])):
            payload, sites, src = emits[(mod, sig)]
            if lines_out:
                lines_out.append("")
            head = f"{short(mod)} emits {sig}"
            lines_out.append(head + (f"  -- {payload}" if payload else ""))
            for caller, n in _iter_use_sites(sites):
                where = f"  (in {caller})" if caller else ""
                lines_out.append(f"  fires    {src}:{n}{where}")
            walk(mod, sig, 0)

        def unreached():
            return sorted(k for k in {*subs, *forwards}
                          if query_rx.search(k[1]) and k not in visited
                          and owner_ok(k[0]))

        pending = unreached()
        while pending:
            mod, sig = pending[0]
            if lines_out:
                lines_out.append("")
            lines_out.append(f"{short(mod)}:{sig}  (no @emits row)")
            walk(mod, sig, 0)
            pending = unreached()

        if not lines_out:
            return f"(no signal matching query={query!r}, module={module!r})"
        if len(lines_out) > max_results:
            lines_out = lines_out[:max_results]
            lines_out.append(f"--- truncated at {max_results}; narrow the query ---")
        return "\n".join(lines_out)

    if module:
        module_rx = re.compile(module, re.IGNORECASE)
        module_files = [p for d in dirs for p in sorted(d.glob("*.map"))
                        if module_rx.fullmatch(p.stem)]
    else:
        module_files = [p for d in dirs for p in sorted(d.glob("*.map"))]

    if not module_files:
        hint = ("; spec maps are stems ending _spec — try module='.*_spec'"
                if module and re.match(r"(tests/)?specs?(/|$)", module) else "")
        return f"(no .map files matched module={module!r}{hint})"

    results: list[str] = []
    truncated = False

    # `uses` names a function subject and answers what it reaches. Without a
    # subject there is nothing to group by, so a bare module keeps the flat
    # outbound listing of its own @use lines. (`usedby` handled above.)
    if kind_filter == 'uses':
        if query_rx:
            reg = _selfname_registry()
            decls = _decl_indexer()
            groups = [g for mp in module_files
                      for g in _uses_groups(mp, query_rx, decls, reg)]
            if groups:
                return _uses_render(groups, max_results)
            surface = (f"module={module!r} with no query" if module
                       else "module='<stem>' with no query")
            return _module_pointer(query, reg, 'uses') or (
                f"(no declaration matching query={query!r}"
                + (f" in module={module!r}" if module else "")
                + f"; uses names a function — for a module's whole outbound "
                f"surface use {surface})")

        for mp in module_files:
            text = mp.read_text(encoding="utf-8", errors="replace")
            src = _src_of(mp, text)
            for raw in text.splitlines():
                mu = _USE.match(raw)
                if not mu:
                    continue
                ukind = mu.group("ukind")
                target = mu.group("target")
                for caller, n in _iter_use_sites(mu.group("sites")):
                    if len(results) >= max_results:
                        truncated = True
                        break
                    where = f"  (in {caller})" if caller else ""
                    results.append(f"{src}:{n}  @use {ukind} {target}{where}")
                if truncated:
                    break
            if truncated:
                break

        if not results:
            return f"(no matches for kind={kind!r}, query={query!r}, module={module!r})"
        if truncated:
            results.append(f"--- truncated at {max_results}; narrow the query ---")
        return "\n".join(results)

    # `reads`/`writes`/`fields` walk @field rows. No module filter means every
    # map, specs included — field queries are blast-radius questions.
    if kind_filter in ('reads', 'writes', 'fields'):
        want = {'reads': 'r', 'writes': 'w', 'fields': None}[kind_filter]
        for mp in module_files:
            text = mp.read_text(encoding="utf-8", errors="replace")
            src = _src_of(mp, text)
            for raw in text.splitlines():
                mf = _FIELD.match(raw)
                if not mf:
                    continue
                if want and mf.group("fkind") != want:
                    continue
                if query_rx and not query_rx.search(mf.group("name")):
                    continue
                for caller, n in _iter_use_sites(mf.group("sites")):
                    if len(results) >= max_results:
                        truncated = True
                        break
                    where = f"  (in {caller})" if caller else ""
                    results.append(f"{src}:{n}  @field {mf.group('fkind')} {mf.group('name')}{where}")
                if truncated:
                    break
            if truncated:
                break

        if not results:
            return f"(no field matches for kind={kind!r}, query={query!r}, module={module!r})"
        if truncated:
            results.append(f"--- truncated at {max_results}; narrow the query ---")
        return "\n".join(results)

    for mp in module_files:
        text = mp.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()
        src = _src_of(mp, text)

        for raw in lines:
            if not raw.strip():
                continue

            md = _DECL.match(raw)
            if md:
                if len(results) >= max_results:
                    truncated = True
                    break
                k = md.group("kind")
                head = md.group("head").strip()
                src_line = int(md.group("line"))
                end_line = md.group("end")
                doc = (md.group("doc") or "").strip()

                if kind_filter and kind_filter != k:
                    continue
                if query_rx:
                    bare = _bare_name(k, head)
                    if not query_rx.search(bare):
                        continue

                loc = f"{src}:{src_line}-{end_line}" if end_line else f"{src}:{src_line}"
                tail = f"  {doc}" if doc else ""
                results.append(f"{loc}  @{k} {head}{tail}")
                continue

            ma = _ANN.match(raw)
            if ma:
                raw_kind = ma.group("kind")
                ek = _entry_kind(raw_kind)
                body = ma.group("body").strip()

                if kind_filter and kind_filter != ek:
                    continue
                if query_rx and not query_rx.search(body):
                    continue
                if not kind_filter and not query_rx:
                    continue

                if len(results) >= max_results:
                    truncated = True
                    break
                ann_line = ma.group("line")
                loc = f"{src}:{ann_line}" if ann_line else src
                results.append(f"{loc}  @{raw_kind}  {body}")
                continue

        if truncated:
            break

    if not results:
        bits = []
        if query: bits.append(f"query={query!r}")
        if kind: bits.append(f"kind={kind!r}")
        if module: bits.append(f"module={module!r}")
        q = ", ".join(bits) if bits else "<no filters>"
        return f"(no matches for {q})"

    if truncated:
        results.append(f"--- truncated at {max_results}; narrow the query ---")
    return "\n".join(results)


if __name__ == "__main__":
    mcp.run()
