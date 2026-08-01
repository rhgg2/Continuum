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
from typing import Optional

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
    modules = set(reg.values())

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
        elif query in reg or query in modules:      # bare module / self name
            want_module(query)
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
    """Intra-module half: each module map's own @call rows. MAP_DIR only —
    spec maps carry no @call rows, and a spec's private helpers are out of
    scope for "who calls this" anyway."""
    rows: list[str] = []
    for mp in sorted(MAP_DIR.glob("*.map")):
        text = mp.read_text(encoding="utf-8", errors="replace")
        src = _src_of(mp, text)
        for raw in text.splitlines():
            mc = _CALL.match(raw)
            if not mc:
                continue
            callee = mc.group("callee")
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
            for caller, n in _iter_use_sites(mc.group("sites")):
                where = f"  (in {caller})" if caller else ""
                rows.append(f"{src}:{n}  @call {callee}{where}")
    return rows


def _section(name, shown, total, na=None) -> str:
    if na:
        return f"{name}  {na}"
    if total == 0:
        return f"{name}  (none)"
    return (f"{name}  ({total})" if shown == total
            else f"{name}  (showing {shown} of {total})")


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
            flow, reads/writes/fields. `uses` lists a module's own
            outbound edges (calls / subs / forwards / requires).
            `usedby` reverses it, answering in two labelled sections:
            cross-module `@use` edges, scanning every map (specs
            included, so it also answers "which specs exercise X";
            spec callers collapse to one summary row per spec file),
            and the declaring file's own intra-module `@call` rows, so
            a private helper's callers come back from the same query.
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
              Exception: under kind='usedby' `module` names the *used*
              target (the module whose callers you want), resolved via
              the self-name registry — so usedby+module='eventMeta'
              answers "who uses eventMeta", not eventMeta's own edges.
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

    dirs = (MAP_DIR, MAP_DIR / "specs")

    # `usedby` is a reverse index: it scans EVERY map (a caller can live
    # anywhere) and matches the target through the self-name registry, so
    # `module` here names the used target, not a file to read. Handled up
    # front — it needs neither `module` as a filename nor `query_rx`.
    if kind_filter == 'usedby':
        reg = _selfname_registry()
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
        if not cross and intra is not None and not intra:
            return (f"(no callers found for query={query!r}, module={module!r}; "
                    "both the cross-module and intra-module indexes were searched)")

        n_intra = 0 if intra is None else len(intra)
        if len(cross) + n_intra <= max_results:
            keep_cross, keep_intra = len(cross), n_intra
        else:                # even split, each half donating what it can't use
            keep_cross = min(len(cross), max_results // 2)
            keep_intra = min(n_intra, max_results // 2)
            keep_cross += min(len(cross) - keep_cross,
                              max_results - keep_cross - keep_intra)
            keep_intra += min(n_intra - keep_intra,
                              max_results - keep_cross - keep_intra)

        # Rows keep their @use/@call token under the header, so a row copied
        # out of context still says which index it came from.
        results = [_section("Cross-module", keep_cross, len(cross))]
        results += [f"  {r}" for r in cross[:keep_cross]]
        results.append(_section(
            "Intra-module", keep_intra, n_intra,
            na=("(n/a — module-level target; the intra index keys on functions)"
                if intra is None else None)))
        results += [f"  {r}" for r in (intra or [])[:keep_intra]]
        results.append("--- note: calls on runtime receivers (not import/construct/dep aliases) are dropped — recall is incomplete for those ---")
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

    # `uses` walks a module's own outbound @use lines. (`usedby` handled above.)
    # It does not read the @call index: that index's *caller* side would answer
    # "what does this function call", which is a different field of the same
    # rows and a different query — see design/map-navigation.md.
    if kind_filter == 'uses':
        for mp in module_files:
            text = mp.read_text(encoding="utf-8", errors="replace")
            src = _src_of(mp, text)
            for raw in text.splitlines():
                mu = _USE.match(raw)
                if not mu:
                    continue
                ukind = mu.group("ukind")
                target = mu.group("target")
                if query_rx and not query_rx.search(target):
                    continue
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
