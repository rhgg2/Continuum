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
import sys
from collections import Counter
from pathlib import Path
from typing import Optional

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.utilities.func_metadata import ArgModelBase
from pydantic import ConfigDict

# Strict input validation: reject unknown kwargs so silent param-name slips fail loudly.
ArgModelBase.model_config = ConfigDict(arbitrary_types_allowed=True, extra='forbid')

# The declaration index and the call-site join live in tools/map_index.py so the
# flow viewer can share them without taking on this server's `mcp` dependency.
# The path insert is what lets a PEP 723 script reach a plain one; the imported
# names keep their leading underscore so the call sites below read unchanged.
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tools"))
from map_index import (  # noqa: E402
    MAP_DIR,
    DECL_RE as _DECL,
    TARGET_RX as _TARGET_RX,
    bare_name as _bare_name,
    callee_cross as _callee_cross,
    callee_intra as _callee_intra,
    canon_target as _canon_target,
    decl_indexer as _decl_indexer,
    decl_row as _decl_row,
    selfname_registry as _selfname_registry,
    src_of as _src_of,
)

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

# Annotations: `@invariant`, `@contract`, `@shape`, `@emits`, `@reaper`,
# any of which may carry a leading `?` (`@?invariant …`) for inferred-rather-
# than-doc-grounded variants. `@deps` is rendered on its own line in the header.
_ANN = re.compile(
    r'^(?P<indent>\s*)@(?P<kind>\??(?:invariant|contract|shape|emits|reaper|deps|exercises|surface|harness))\s+'
    r'(?P<body>.*?)(?:\s+@\s+(?P<line>\d+))?\s*$'
)
# `@use <kind> <target>  @ <caller>:<line>[,<line>] [<caller>:<line>...]`
# The caller is `<load>` where the edge is made in the module's chunk body at
# load time; a bare line number is one the extractor could not attribute.
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


def _where(caller: str | None) -> str:
    """The `(in …)` suffix on a site row. `<load>` names no declaration, so it
    renders as the fact it stands for rather than as something to look up."""
    if caller is None:
        return ""
    return "  (at file scope)" if caller == "<load>" else f"  (in {caller})"


def _iter_use_sites(sites: str):
    """Yield (caller|None, line) from a @use sites field."""
    for seg in sites.split():
        if ':' in seg:
            # rpartition: a caller is itself qualified (`edit.assign`,
            # `tm:rebuild`), so only the last colon separates it from the lines.
            caller, _, nums = seg.rpartition(':')
        else:
            caller, nums = None, seg
        for n in nums.split(','):
            n = n.strip()
            if n.isdigit():
                yield caller, n


def _normalize_kind(k: str) -> str:
    k = k.lower().lstrip("?")
    aliases = {
        "signal": "emits", "signals": "emits",
        "invariants": "invariant", "contracts": "contract", "shapes": "shape",
        "fns": "fn", "functions": "fn",
        "apis": "api",
        "helds": "held",
        "handlers": "handler",
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
    'fn', 'api', 'held', 'handler', 'state', 'const', 'require', 'construct', 'case',
    'invariant', 'contract', 'shape', 'emits', 'reaper', 'deps',
    'exercises', 'surface', 'harness',
    'uses', 'usedby', 'flow', 'reads', 'writes', 'fields',
})


def _entry_kind(raw_kind: str) -> str:
    return raw_kind.lstrip("?")


# Scope selects the search domain by directory, which is what a spec map
# actually is; the `_spec` stem is a convention that happens to agree today.
# The corpus runs 64 module maps to 254 spec maps, so an unscoped answer is
# mostly specs and the cap lands on them first.
_SCOPES = {
    'all': 'all', 'any': 'all', 'both': 'all',
    'prod': 'prod', 'production': 'prod', 'src': 'prod', 'source': 'prod',
    'module': 'prod', 'modules': 'prod',
    'spec': 'spec', 'specs': 'spec', 'test': 'spec', 'tests': 'spec',
}


def _scope_dirs(canon: str) -> tuple:
    if canon == 'prod':
        return (MAP_DIR,)
    if canon == 'spec':
        return (MAP_DIR / "specs",)
    return (MAP_DIR, MAP_DIR / "specs")


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
                    site_rows.append(f"{src}:{n}  @use {ukind} {target}{_where(caller)}")
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
                rows.append(f"{src}:{n}  {token} {callee}{_where(caller)}")
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
                rows.append(f"{src}:{n}  @drop {target}{_where(caller)}")
    return rows


# `uses` reads the *caller* field of the @call and @use rows, which nothing else
# does: what a named function reaches, with each callee resolved to its
# declaration — the jump target the call site itself cannot give you.
# See design/map-navigation.md § Intra-file call edges.
_USES_NOTE = ("--- note: a subject here is a named declaration "
              "(@fn/@api/@held/@handler), so sites whose caller is `<load>` — the "
              "module's chunk body, which includes the head of a construct "
              "holding a literal, the wrapper call and the registrar call — have "
              "no subject to group under and are absent; calls on runtime "
              "receivers are dropped ---")


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


# Kinds whose payload is a prose body rather than a name. Mirrors the
# alternation in `_ANN`; keep the two in step.
_ANN_KINDS = frozenset({'invariant', 'contract', 'shape', 'emits', 'reaper',
                        'deps', 'exercises', 'surface', 'harness'})

# Chosen so every module map's listing survives whole: the largest is under
# 2,600 chars, while spec `case` heads are sentences rather than identifiers
# and run to 4,840 (am_spec, 68 cases). The cut lands on prose, not on names.
_INVENTORY_CHARS = 2500


def _domain_note(seen_kinds, seen_names, label, module, domain) -> str:
    """What the scan walked, for an answer that found nothing. Its whole job
    is to separate 'absent from the code' from 'absent from the corpus', so
    it reports the domain rather than guessing at near misses."""
    kind_counts = ' '.join(f"{k}:{v}" for k, v in seen_kinds.most_common())

    if label in _ANN_KINDS:
        n = seen_kinds.get(label, 0)
        if module and n:
            return (f"{module} holds {n} {label} rows — bodies are prose, not "
                    f"names; drop query= to read them.")
        return f"searched {domain} — {n} {label} rows, none matching."

    if module and label:
        names = sorted(set(seen_names))
        if not names:
            return f"{module} holds no {label}. It holds: {kind_counts}"
        shown, chars = [], 0
        for nm in names:
            if chars + len(nm) + 2 > _INVENTORY_CHARS:
                break
            shown.append(nm)
            chars += len(nm) + 2
        rest = len(names) - len(shown)
        tail = f"\n  … and {rest} more; narrow with query=" if rest else ""
        return (f"{module} holds {len(names)} {label}:\n"
                f"  {', '.join(shown)}{tail}")

    if module:
        return f"{module} holds: {kind_counts}\n  — re-query with kind= to list one"

    if label:
        return (f"searched {domain} — {seen_kinds.get(label, 0)} {label} "
                f"heads, none matching.")
    return (f"searched {domain} — {sum(seen_kinds.values())} entries across "
            f"{len(seen_kinds)} kinds, none matching.")


# `flow` walks the signal rows already in the maps: `@emits` (owner = the
# map's module, fire-sites in the tail), `@use sub owner:signal`, and
# `@use forward source:signal` (the forwarder re-fires under its own name).
_EMITS_ROW = re.compile(r'^\s*@\??emits\s+(?P<name>\S+)\s*(?P<rest>.*?)\s*$')


def _signal_graph(reg, dirs):
    """One scan over the scoped maps. Returns (emits, subs, forwards): emits maps
    (module, signal) -> (payload, fire-sites, src); subs and forwards map
    (owner module, signal) -> site lists. Owner short names resolve through
    the registry; a literal `self` owner is the map's own module."""
    emits, subs, forwards = {}, {}, {}
    for d in dirs:
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
    scope: str = "all",
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
             entries (`@fn`, `@api`, `@held`, `@handler`, `@state`,
             `@const`, `@require`, `@construct`) — a held name is qualified,
             so it is matched as `table.field`, a handler as `recv:signal` —
             full body text for annotations
             (`@invariant`, `@contract`, `@shape`, `@emits`, `@reaper`),
             and field names for reads/writes/fields.
             Omit to return everything matching the other filters.
      kind: filter by entry kind. Accepted (case-insensitive, plurals
            ok): fn, api, held (a function literal held in a table
            field, named and queried `table.field`), handler (a literal
            handed to a registrar, queried `recv:signal`), state, const,
            require/import, construct,
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
      scope: which maps to search: 'all' (default), 'prod' for module
             maps only, 'spec' for spec maps only. Selected by
             directory (map/ vs map/specs/) rather than by stem, and
             it composes with `module`. Spec maps outnumber module
             maps four to one, so scope='prod' is how you ask a
             question about the production code without spec sites
             taking the cap; scope='spec' is the same question of the
             suite. Under kind='usedby' it scopes the cross-module
             half — the intra-module and dropped-receiver indexes
             cover module maps only, so scope='spec' reports them n/a
             rather than empty.
      max_results: cap (default 60).

    Returns:
      Lines of `<source>.lua:<line>  @kind <head>` for structural entries,
      and `<source>.lua  @kind  <body>` for annotations. An answer with no
      matches names the domain it searched: a module's heads for that kind
      where `module` and `kind` were both given, the kind histogram where
      only `module` was, and the scope scanned otherwise.
    """
    for pat in (query, module):
        if pat:
            try:
                re.compile(pat)
            except re.error as exc:
                return (f"--- ERROR: {pat!r} is not valid regex ({exc}). Queries "
                        "are regex, not glob: plain text substring-matches; use "
                        "'.*' where glob habits reach for '*' ---")
    out = _map_query(query, kind, module, scope, max_results)
    notes = [n for n in (_glob_smell(query), _glob_smell(module)) if n]
    return "\n".join([out, *notes]) if notes else out


def _map_query(query, kind, module, scope, max_results) -> str:
    if not MAP_DIR.exists():
        return f"--- ERROR: {MAP_DIR} not found ---"

    query_rx = re.compile(query, re.IGNORECASE) if query else None
    kind_filter = _normalize_kind(kind) if kind else None
    if kind_filter and kind_filter not in _KINDS:
        return (f"--- ERROR: kind={kind!r} is not a kind. Valid: "
                f"{', '.join(sorted(_KINDS))} ---")

    scoped = _SCOPES.get((scope or "all").strip().lower())
    if scoped is None:
        return (f"--- ERROR: scope={scope!r} is not a scope. Valid: "
                f"{', '.join(sorted(set(_SCOPES.values())))} "
                "(aliases: production/src/source/module(s), specs/test(s)) ---")
    dirs = _scope_dirs(scoped)
    scope_bit = f", scope={scoped!r}" if scoped != 'all' else ""

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
        # Both remaining halves read module maps only, so under scope='spec'
        # they were not searched at all — a distinction `(none)` cannot draw.
        spec_only = "(n/a — scope='spec'; this index covers module maps only)"
        # @call keys on functions, so a module-level target has no intra half:
        # trackerManager calling itself is not an answer to "who uses it".
        intra_na = (spec_only if scoped == 'spec' else
                    "(n/a — module-level target; the intra index keys on functions)"
                    if q_fn is None and raw_rx is None else None)
        intra = None if intra_na else _usedby_intra(module_pred, q_fn, raw_rx, reg)
        drops_na = spec_only if scoped == 'spec' else None
        drops = [] if drops_na else _usedby_drops(module_pred, q_fn, raw_rx, reg)
        if not cross and not drops and not intra:
            searched = ["cross-module"] + ([] if intra_na else ["intra-module"]) \
                + ([] if drops_na else ["dropped-receiver"])
            return (f"(no callers found for query={query!r}, module={module!r}"
                    f"{scope_bit}; the "
                    + ", ".join(searched) + " index"
                    + ("es were" if len(searched) > 1 else " was")
                    + " searched)")

        sizes = [len(cross), 0 if intra is None else len(intra), len(drops)]
        keep_cross, keep_intra, keep_drops = _split_budget(sizes, max_results)

        # Rows keep their @use/@call/@drop token under the header, so a row
        # copied out of context still says which index it came from.
        results = [_section("Cross-module", keep_cross, sizes[0])]
        results += [f"  {r}" for r in cross[:keep_cross]]
        results.append(_section("Intra-module", keep_intra, sizes[1], na=intra_na))
        results += [f"  {r}" for r in (intra or [])[:keep_intra]]
        results.append(_section("Dropped receivers", keep_drops, sizes[2],
                                na=drops_na))
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
        emits, subs, forwards = _signal_graph(reg, dirs)
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
                lines_out.append(f"{pad}  sub      {src}:{n}{_where(caller)}")
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
            return (f"(no signal matching query={query!r}, "
                    f"module={module!r}{scope_bit})")
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
        return f"(no .map files matched module={module!r}{scope_bit}{hint})"

    # Describes the list the scan is about to walk, not a fresh glob, so an
    # empty answer's stated domain cannot disagree with the pass that ran.
    n_mod = sum(1 for p in module_files if p.parent == MAP_DIR)
    n_spec = len(module_files) - n_mod
    domain = (f"{n_mod} module maps"
              + (f" and {n_spec} spec maps" if n_spec else ""))

    results: list[str] = []
    truncated = False
    seen_kinds: Counter = Counter()
    seen_names: list[str] = []
    # Names are only printable under a module: the un-narrowed corpus is
    # 6,003 structural entries, so counts are all an unfiltered scan can use.
    want_names = bool(module and kind_filter)

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
            return (f"(no matches for kind={kind!r}, query={query!r}, "
                    f"module={module!r}{scope_bit})")
        if truncated:
            results.append(f"--- truncated at {max_results}; narrow the query ---")
        return "\n".join(results)

    # `reads`/`writes`/`fields` walk @field rows. No module filter means every
    # map, specs included — field queries are blast-radius questions.
    if kind_filter in ('reads', 'writes', 'fields'):
        want = {'reads': 'r', 'writes': 'w', 'fields': None}[kind_filter]
        seen_fields: list[str] = []
        for mp in module_files:
            text = mp.read_text(encoding="utf-8", errors="replace")
            src = _src_of(mp, text)
            for raw in text.splitlines():
                mf = _FIELD.match(raw)
                if not mf:
                    continue
                if want and mf.group("fkind") != want:
                    continue
                seen_fields.append(mf.group("name"))
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
            note = _domain_note(Counter({kind_filter: len(seen_fields)}),
                                seen_fields, kind_filter, module, domain)
            return (f"(no field matches for kind={kind!r}, query={query!r}, "
                    f"module={module!r}{scope_bit})") + (f"\n{note}" if note else "")
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

                seen_kinds[k] += 1
                if want_names and kind_filter == k:
                    seen_names.append(_bare_name(k, head))

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

                # Counted ahead of the filters: the bare-scan skip below is a
                # display rule and must not hide the kind from the inventory.
                seen_kinds[ek] += 1

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
        if scoped != 'all': bits.append(f"scope={scoped!r}")
        q = ", ".join(bits) if bits else "<no filters>"
        note = _domain_note(seen_kinds, seen_names, kind_filter, module, domain)
        return f"(no matches for {q})" + (f"\n{note}" if note else "")

    if truncated:
        results.append(f"--- truncated at {max_results}; narrow the query ---")
    return "\n".join(results)


if __name__ == "__main__":
    mcp.run()
