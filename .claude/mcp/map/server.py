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


# `^function tm:(channels|columns)` and `local function dirtyChan` are how a
# declaration is searched for in Lua *source*; the map indexes the bare name.
# A quarter of the grep fallbacks in the transcript corpus were spelled this
# way, so reduce the pattern to the name rather than answering nothing.
# Anchored at the head of an alternative so prose that merely contains the
# word ("the function that clips") is left alone.
_DECL_SYNTAX = re.compile(r'(?:^|\|)\s*\^?\s*(?:local\s+)?function\b')
_DECL_WORDS = re.compile(r'\b(?:local\s+)?function\b')


# Where a name's words begin and end: `_`/`.`/`:` separators and camel humps.
# `chan` spans a whole word in `dirtyChan` and a fragment of one in
# `changedSwingNames`, which is the difference between a hit and a false
# positive — and a stronger signal than prefix-vs-substring, which ranks
# those two the wrong way round.
def _word_edges(name: str) -> tuple:
    starts, ends = {0}, {len(name)}
    for i in range(1, len(name)):
        prev, cur = name[i - 1], name[i]
        if prev in '_.:':
            starts.add(i)
        if cur in '_.:':
            ends.add(i)
        elif cur.isupper() and (prev.islower() or prev.isdigit()):
            starts.add(i)
            ends.add(i)
    return starts, ends


def _match_rank(hit, name: str) -> tuple:
    """Sort key for a query's hit on a declaration name, best first: the whole
    name, then a whole word inside it, then a word-initial fragment, then
    anything. Ties break on how much of the name the query claimed."""
    text = hit.group(0)
    if text == name:
        return (0, 0.0)
    starts, ends = _word_edges(name)
    at_start = hit.start() in starts
    at_end = hit.end() in ends
    tier = 1 if at_start and at_end else 2 if at_start else 3
    return (tier, -len(text) / len(name))


def _strip_decl_syntax(query):
    """A Lua declaration pattern reduced to the names the map indexes.
    Returns (rewritten, original) when it fired, else (query, None). The name
    is the last identifier of each alternative, since a qualifier (`tm:`,
    `M.`) precedes it."""
    if not query or not _DECL_SYNTAX.search(query):
        return query, None
    names = []
    for alt in query.split('|'):
        # Escapes first: `function mm:add\b` otherwise yields the `b` of `\b`
        # as the last identifier, and the name searched for is the escape.
        alt = re.sub(r'\\.', ' ', _DECL_WORDS.sub(' ', alt))
        ids = re.findall(r'[A-Za-z_][A-Za-z0-9_]*', alt)
        if ids and ids[-1] not in ('local', 'function') and ids[-1] not in names:
            names.append(ids[-1])
    return ('|'.join(names), query) if names else (query, None)


# `^tracks` finds nothing where the map spells the name `arrange.tracks`. A held
# or handler carries its qualifier into the indexed name, unlike an api, whose
# receiver is stripped — so the same anchor means two different things and the
# caller cannot tell which without knowing the kind of the thing not yet found.
# Retried rather than documented: the discrepancy only ever surfaces as an empty
# answer, and an empty answer is the moment grep wins.
_ANCHORED = re.compile(r'(?:^|\|)\^(?=[\w])')


def _widen_anchors(query):
    """Every `^` in the query allowed to skip one `table.`/`recv:` qualifier.
    None when there is no anchor to widen."""
    if not query or not _ANCHORED.search(query):
        return None
    widened = _ANCHORED.sub(lambda m: m.group(0)[:-1] + r'^(?:\w+[.:])?', query)
    return widened if widened != query else None


def _widen_module(module):
    """A plain-word `module` allowed to match a stem it is only part of — `query`
    substring-matches and the habit that types one types the other. None where
    it is already a regex, whose author meant the anchoring."""
    if not module or re.escape(module) != module:
        return None
    return f".*{module}.*"


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
        "decls": "decl", "declaration": "decl", "declarations": "decl",
        "name": "decl", "names": "decl",
        "anns": "ann", "annotation": "ann", "annotations": "ann",
        "prose": "ann", "body": "ann", "bodies": "ann",
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
_DECL_KINDS = frozenset({
    'fn', 'api', 'held', 'handler', 'state', 'const', 'require', 'construct', 'case',
})

# Kinds whose payload is a prose body rather than a name. Mirrors the
# alternation in `_ANN`; keep the two in step.
_ANN_KINDS = frozenset({'invariant', 'contract', 'shape', 'emits', 'reaper',
                        'deps', 'exercises', 'surface', 'harness'})

# Whether a declaration got written `api` or `held` is a fact about the row, and
# the row says which — so asking for one means guessing an answer the map is
# about to give. The groups are the two questions actually being asked: is this
# thing declared somewhere, or is something asserted about it. Their union is
# what a kindless scan covers, which is why that needs no group of its own.
_KIND_GROUPS = {'decl': _DECL_KINDS, 'ann': _ANN_KINDS}

_KINDS = (_DECL_KINDS | _ANN_KINDS | frozenset(_KIND_GROUPS)
          | frozenset({'uses', 'usedby', 'flow', 'reads', 'writes', 'fields'}))


def _wanted_kinds(kind_filter):
    """The row kinds a `kind` argument selects: a group expands, anything else
    matches only itself."""
    if not kind_filter:
        return None
    return _KIND_GROUPS.get(kind_filter, frozenset({kind_filter}))


def _entry_kind(raw_kind: str) -> str:
    return raw_kind.lstrip("?")


# Scope selects the search domain by directory, which is what a spec map
# actually is; the `_spec` stem is a convention that happens to agree today.
# 'prod' is the default because the corpus runs 64 module maps to 254 spec
# maps: an unscoped answer is mostly specs and the cap lands on them first,
# so the majority of the index is not what the majority of questions want.
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


# One file selection for every kind, so `module` narrows where the answer comes
# from and never what the answer is about. Under usedby that is where the
# callers live; the target itself is named by `query`.
def _scoped_maps(dirs, module) -> list:
    files = [p for d in dirs for p in sorted(d.glob("*.map"))]
    if not module:
        return files
    module_rx = re.compile(module, re.IGNORECASE)
    return [p for p in files if module_rx.fullmatch(p.stem)]


def _usedby_selectors(query, reg):
    """Selectors for a usedby scan, collapsing short names and `:`/`.` spellings.
    Returns (module_pred | None, method | None, raw_regex | None): a @use target
    matches when its canonical module satisfies module_pred, its method equals
    `method`, and its raw text matches raw_regex — each constraint optional.
    The target is named by `query` alone."""
    mod_preds = []

    def want_module(tok):
        if re.escape(tok) != tok:
            rx = re.compile(tok, re.IGNORECASE)
            mod_preds.append(lambda mod, rx=rx: bool(rx.fullmatch(mod)))
        else:
            canon = reg.get(tok, tok)
            mod_preds.append(lambda mod, canon=canon: mod == canon)

    method = None
    raw_rx = None
    if query:
        m = _TARGET_RX.match(query)
        if m:                                       # `cm:get`, `configManager.get`
            want_module(m.group(1))
            method = m.group(2)
        elif query in reg or query in set(reg.values()):
            want_module(query)                      # a module: all of its edges
        else:                                       # regex over raw target text
            raw_rx = re.compile(query, re.IGNORECASE)

    module_pred = (lambda mod: all(p(mod) for p in mod_preds)) if mod_preds else None
    return module_pred, method, raw_rx


# Both halves of usedby gather without capping: the budget can't be split
# until both totals are known, so neither may break out early.
def _usedby_cross(module_pred, q_fn, raw_rx, reg, files) -> list[str]:
    """Cross-module half: @use edges aimed at the target, from each given map."""
    rows: list[str] = []
    for mp in files:
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


def _usedby_intra(module_pred, q_fn, raw_rx, reg, files) -> list[str]:
    """Intra-module half: each map's own @call and @bind rows — a helper nothing
    calls is still reached, by the table that binds it. Module maps only — spec
    maps carry neither row kind, and a spec's private helpers are out of scope
    for "who calls this" anyway."""
    rows: list[str] = []
    for mp in files:
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


def _usedby_drops(module_pred, q_fn, raw_rx, reg, files) -> list[str]:
    """Dropped-receiver half: sites the extractor could not attribute. The
    receiver is resolved here through the self-name registry — the guess the
    extractor refuses to make, because a wrong alias in the corpus does not
    drop, it lies. Under a heading that says the receiver is unproven it is
    the recall the other two halves cannot give."""
    rows: list[str] = []
    for mp in files:
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
# See design/archive/map-navigation.md § Intra-file call edges.
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


def _module_pointer(query, reg):
    """`uses` groups by declaration, so a query naming a module has no subject to
    group under. Its outbound surface is the whole file's edge list instead."""
    if not query or not (query in reg or query in set(reg.values())):
        return None
    return (f"({query!r} names a module, not a function; for its whole outbound "
            f"surface use module={reg.get(query, query)!r} with no query)")


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


# Chosen so every module map's listing survives whole: the largest is under
# 2,600 chars, while spec `case` heads are sentences rather than identifiers
# and run to 4,840 (am_spec, 68 cases). The cut lands on prose, not on names.
_INVENTORY_CHARS = 2500


def _domain_note(seen_kinds, seen_names, label, wanted, module, domain,
                 relational=None) -> str:
    """What the scan walked, for an answer that found nothing. Its whole job
    is to separate 'absent from the code' from 'absent from the corpus', so
    it reports the domain rather than guessing at near misses."""
    kind_counts = ' '.join(f"{k}:{v}" for k, v in seen_kinds.most_common())
    # Summed over the wanted set, not looked up by label: the histogram keys
    # concrete kinds, so a group label finds nothing under its own name.
    n = sum(seen_kinds.get(k, 0) for k in wanted) if wanted else 0

    if wanted and wanted <= _ANN_KINDS:
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
        return (f"{module} holds: {kind_counts}"
                f"\n  — re-query with kind= to list one"
                + ("\n" + _unsearched_note(relational) if relational else ""))

    if label:
        return f"searched {domain} — {n} {label} heads, none matching."
    return (f"searched {domain} — {sum(seen_kinds.values())} entries across "
            f"{len(seen_kinds)} kinds, none matching.")


# The histogram above counts what the bare scan walks, and it used to stop
# there — so a module's `holds:` line inventoried declarations and annotations
# while silently omitting its field and edge rows, naming a domain narrower
# than the reader assumes in the very note whose job is to name the domain.
def _unsearched_note(relational) -> str:
    bits = []
    if relational.get('field'):
        bits.append(f"{relational['field']} @field rows (kind='fields')")
    if relational.get('use'):
        bits.append(f"{relational['use']} @use edges (kind='uses'/'usedby')")
    return f"  — not walked by this scan: {', '.join(bits)}" if bits else ""


# One row per field NAME, not per access site: per (module, field) a hot name
# like `chan` still runs to 315 rows, per name it is 20. The site listing is
# what kind='fields' is for, and each row carries the call that gets there.
_FIELD_SUMMARY_ROWS = 10


def _field_summaries(module_files, query_rx, limit) -> tuple:
    """Matching field names, widest first: r/w, site total, declaring modules.
    Returns (rows, names_dropped)."""
    agg: dict = {}
    for mp in module_files:
        text = mp.read_text(encoding="utf-8", errors="replace")
        src = _src_of(mp, text)
        for raw in text.splitlines():
            mf = _FIELD.match(raw)
            if not mf or not query_rx.search(mf.group("name")):
                continue
            rec = agg.setdefault(mf.group("name"),
                                 {'rw': set(), 'sites': 0, 'mods': Counter()})
            rec['rw'].add(mf.group("fkind"))
            n = sum(1 for _ in _iter_use_sites(mf.group("sites")))
            rec['sites'] += n
            rec['mods'][src] += n

    rows = []
    for name, rec in sorted(agg.items(), key=lambda kv: -kv[1]['sites'])[:limit]:
        mods = [m for m, _ in rec['mods'].most_common()]
        more = f" +{len(mods) - 3}" if len(mods) > 3 else ""
        rows.append(f"  @field {''.join(sorted(rec['rw']))} {name}  "
                    f"{rec['sites']} site{'' if rec['sites'] == 1 else 's'} in "
                    f"{', '.join(mods[:3])}{more}  "
                    f"[kind='fields', query='^{name}$']")
    return rows, len(agg) - len(rows)


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
    scope: str = "prod",
    max_results: int = 60,
) -> str:
    """Structured query over the project's .map semantic outlines — a generated
    index of every declaration, annotation, field access and call edge in the
    repo, each row carrying the .lua file:line to jump to.

    What it answers, commonest question first, with the call that does it:

      where is field .f read or written?  query='^f$', kind='fields'
      where is X declared (in module M)?  query='X' [, module='M']
      what does module M hold?            module='M'   (no query → histogram)
      the invariant or contract about Y?  query='Y', kind='invariant'
      who calls X / what does X reach?    query='X', kind='usedby' | 'uses'
                                          (X may name a module for usedby)
      which specs exercise X?             query='X', kind='usedby', scope='all'
      trace signal S end to end?          query='S', kind='flow'

    A bare `query` with no `kind` searches declarations and annotations, and
    summarises the field names it matched — kind='fields' for the access sites
    themselves. Lua declaration syntax in a query (`^function tm:foo`) reduces
    to the bare name the map indexes.

    Args:
      query: regex — case-insensitive, substring-matched, anchor with ^$ for
             exact. NOT glob: plain text already substring-matches, so no
             wrapping stars. What it matches depends on kind: the symbol name
             for a declaration or spec kind, the body prose for an annotation,
             the field name for fields/reads/writes, the subject named for
             uses/usedby/flow. Omit it to return everything.
      kind: any one kind, or 'decl' / 'ann' for a whole group.
              decl   'fn' (local function) / 'api' (module method) / 'held'
                     (literal in a table field) / 'handler' (literal given
                     to a registrar) / 'state' (mutable local) / 'const' /
                     'require' / 'construct' (table literal) / 'case' (a spec's
                     test)
              ann    'invariant' / 'contract' / 'shape' / 'emits' / 'deps'
                     (the modules a file uses) / 'reaper' (the REAPER API
                     functions a call site names); 'exercises' / 'surface' /
                     'harness' on specs
              index  'fields' / 'reads' / 'writes' (field access sites) |
                     'uses' / 'usedby' (call edges, either direction) |
                     'flow' (one signal from its emitter through the
                     subscribers and forwards that carry it)
            Omitted: decl + ann, and no index.
      module: where the answer comes from — a regex matched whole
              against .map stems: `trackerManager`, `tm_.*`,
              `.*Manager`. For usedby, where the callers live; for
              flow, which module's emitters root the trace. The
              subject is always named by `query`.
      scope: 'prod' (default) module maps only, 'spec' spec maps, 'all' both.
             Specs outnumber modules four to one.
      max_results: cap (default 60).

    Returns:
      Lines of `<source>.lua:<line>  @kind <head>` for structural entries,
      `<source>.lua  @kind  <body>` for annotations. An answer with no matches
      names the domain it searched rather than only reporting none.
    """
    # Annotation bodies are prose and may legitimately contain the word
    # 'function', so the declaration-syntax rewrite is confined to the kinds
    # that index names. Ahead of the regex check: the rewrite is what runs.
    rewrite_note = None
    if not kind or _normalize_kind(kind) not in _ANN_KINDS:
        query, original = _strip_decl_syntax(query)
        if original:
            rewrite_note = (f"--- note: {original!r} is Lua declaration syntax; "
                            f"searched the bare name(s) {query!r} that the map "
                            "indexes ---")
    for pat in (query, module):
        if pat:
            try:
                re.compile(pat)
            except re.error as exc:
                return (f"--- ERROR: {pat!r} is not valid regex ({exc}). Queries "
                        "are regex, not glob: plain text substring-matches; use "
                        "'.*' where glob habits reach for '*' ---")
    out = _map_query(query, kind, module, scope, max_results)
    # Every empty answer opens with `(`, every hit with a source path or a
    # section header, so this distinguishes the two without a second channel.
    widen_note = None
    if out.startswith("("):
        args = dict(query=query, kind=kind, module=module, scope=scope,
                    max_results=max_results)
        # Both widenings are one trade: an argument written tighter than the
        # index spells things. First that lands wins, and the note says which.
        want = _wanted_kinds(_normalize_kind(kind)) if kind else None
        anchorable = not want or not want <= _ANN_KINDS
        for name, widened, why in (
            ("query", _widen_anchors(query) if anchorable else None,
             "a @held or @handler name carries its qualifier"),
            ("module", _widen_module(module),
             "module is matched whole against .map stems"),
        ):
            if not widened:
                continue
            retry = _map_query(**{**args, name: widened})
            if not retry.startswith("("):
                widen_note = (f"--- note: nothing matched {name}={args[name]!r}; "
                              f"{why}, so it was widened to {widened} ---")
                out = retry
                break
    notes = [n for n in (rewrite_note, widen_note,
                         _glob_smell(query), _glob_smell(module)) if n]
    return "\n".join([out, *notes]) if notes else out


def _map_query(query, kind, module, scope, max_results) -> str:
    if not MAP_DIR.exists():
        return f"--- ERROR: {MAP_DIR} not found ---"

    query_rx = re.compile(query, re.IGNORECASE) if query else None
    kind_filter = _normalize_kind(kind) if kind else None
    wanted = _wanted_kinds(kind_filter)
    if kind_filter and kind_filter not in _KINDS:
        return (f"--- ERROR: kind={kind!r} is not a kind. Valid: "
                f"{', '.join(sorted(_KINDS))} ---")

    scoped = _SCOPES.get((scope or "prod").strip().lower())
    if scoped is None:
        return (f"--- ERROR: scope={scope!r} is not a scope. Valid: "
                f"{', '.join(sorted(set(_SCOPES.values())))} "
                "(aliases: production/src/source/module(s), specs/test(s)) ---")
    dirs = _scope_dirs(scoped)
    scope_bit = f", scope={scoped!r}" if scoped != 'all' else ""

    # `usedby` is a reverse index: a caller can live in any map, so it matches
    # the target through the self-name registry rather than by reading one file.
    # Handled up front — it needs no `query_rx`.
    if kind_filter == 'usedby':
        reg = _selfname_registry()
        module_pred, q_fn, raw_rx = _usedby_selectors(query, reg)
        if module_pred is None and q_fn is None and raw_rx is None:
            return ("(usedby needs a target: pass query= naming the used symbol "
                    "or module, e.g. query='cm:get' or query='configManager'. "
                    "module= narrows where the callers live.)")
        files = _scoped_maps(dirs, module)
        if not files:
            return f"(no .map files matched module={module!r}{scope_bit})"
        prod = [p for p in files if p.parent == MAP_DIR]
        cross = _usedby_cross(module_pred, q_fn, raw_rx, reg, files)
        # Both remaining halves read module maps only, so under scope='spec'
        # they were not searched at all — a distinction `(none)` cannot draw.
        spec_only = "(n/a — scope='spec'; this index covers module maps only)"
        # @call keys on functions, so a module-level target has no intra half:
        # trackerManager calling itself is not an answer to "who uses it".
        intra_na = (spec_only if scoped == 'spec' else
                    "(n/a — module-level target; the intra index keys on functions)"
                    if q_fn is None and raw_rx is None else None)
        intra = None if intra_na else _usedby_intra(module_pred, q_fn, raw_rx,
                                                    reg, prod)
        drops_na = spec_only if scoped == 'spec' else None
        drops = [] if drops_na else _usedby_drops(module_pred, q_fn, raw_rx,
                                                  reg, prod)
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

    module_files = _scoped_maps(dirs, module)

    if not module_files:
        hint = ("; specs are selected by scope='spec', not by module="
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
    relational: Counter = Counter()
    seen_names: list[str] = []
    # The bare scan's two row types are gathered apart so the budget can be
    # split by usefulness at the end rather than by whichever came first.
    decl_rows: list = []          # (rank, row) until sorted below
    ann_rows: list[str] = []
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
            return _module_pointer(query, reg) or (
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
                                seen_fields, kind_filter, wanted, module, domain)
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
                k = md.group("kind")
                head = md.group("head").strip()
                src_line = int(md.group("line"))
                end_line = md.group("end")
                doc = (md.group("doc") or "").strip()

                seen_kinds[k] += 1
                if want_names and k in wanted:
                    seen_names.append(_bare_name(k, head))

                if wanted and k not in wanted:
                    continue
                # Ranked so query='chan' leads with `chan`, then `dirtyChan`,
                # and not with `changedSwingNames`. Equal ranks keep file
                # order, the sort being stable.
                rank = (0, 0.0)
                if query_rx:
                    bare = _bare_name(k, head)
                    hit = query_rx.search(bare)
                    if not hit:
                        continue
                    rank = _match_rank(hit, bare)

                loc = f"{src}:{src_line}-{end_line}" if end_line else f"{src}:{src_line}"
                tail = f"  {doc}" if doc else ""
                decl_rows.append((rank, f"{loc}  @{k} {head}{tail}"))
                continue

            ma = _ANN.match(raw)
            if ma:
                raw_kind = ma.group("kind")
                ek = _entry_kind(raw_kind)
                body = ma.group("body").strip()

                # Counted ahead of the filters: the bare-scan skip below is a
                # display rule and must not hide the kind from the inventory.
                seen_kinds[ek] += 1

                if wanted and ek not in wanted:
                    continue
                if query_rx and not query_rx.search(body):
                    continue
                if not kind_filter and not query_rx:
                    continue

                ann_line = ma.group("line")
                loc = f"{src}:{ann_line}" if ann_line else src
                ann_rows.append(f"{loc}  @{raw_kind}  {body}")
                continue

            # Counted, not searched: these rows answer to the kind= indexes,
            # and the empty-answer note reports them rather than leaving the
            # reader to read absence-from-the-scan as absence-from-the-repo.
            if _FIELD.match(raw):
                relational['field'] += 1
                continue
            if _USE.match(raw):
                relational['use'] += 1
                continue

    # Ordered by usefulness, not by file position. A module's header
    # @invariants sit at line 3 and its declarations run to line 3000, so a
    # scan that capped in file order spent the whole budget on prose and
    # truncated away the @api head the query was after. Gathering uncapped
    # then splitting is what `usedby` does with its three sections, and for
    # the same reason: no share can be sized until every total is known.
    #
    # A bare query is a "where is this" question, and a field name was the
    # commonest one this scan could not answer — a quarter of the grep
    # fallbacks in the corpus. Summaries take a share; the access sites stay
    # behind kind='fields', which is what the rows point at.
    decl_rows = [row for _, row in sorted(decl_rows, key=lambda r: r[0])]
    field_rows, dropped = [], 0
    if query_rx and not kind_filter:
        field_rows, dropped = _field_summaries(module_files, query_rx,
                                              _FIELD_SUMMARY_ROWS)
    # Fields ahead of prose, in the split as well as the display: the order of
    # `sizes` is the order surplus is handed back, and a field name was six
    # times likelier than annotation prose to be what the query was after.
    keep_d, keep_f, keep_a = _split_budget(
        [len(decl_rows), len(field_rows), len(ann_rows)], max_results)
    truncated = (len(decl_rows) > keep_d or len(ann_rows) > keep_a
                 or len(field_rows) > keep_f)
    results = decl_rows[:keep_d]
    if keep_f:
        results.append("--- field names matching "
                       "(access sites behind kind='fields') ---")
        results.extend(field_rows[:keep_f])
        unshown = dropped + len(field_rows) - keep_f
        if unshown:
            results.append(f"  … and {unshown} more field "
                           f"name{'' if unshown == 1 else 's'}; narrow the query")
    results += ann_rows[:keep_a]

    if not results:
        bits = []
        if query: bits.append(f"query={query!r}")
        if kind: bits.append(f"kind={kind!r}")
        if module: bits.append(f"module={module!r}")
        if scoped != 'all': bits.append(f"scope={scoped!r}")
        q = ", ".join(bits) if bits else "<no filters>"
        note = _domain_note(seen_kinds, seen_names, kind_filter, wanted, module,
                            domain, relational=relational)
        return f"(no matches for {q})" + (f"\n{note}" if note else "")

    if truncated:
        results.append(f"--- truncated at {max_results}; narrow the query ---")
    return "\n".join(results)


if __name__ == "__main__":
    mcp.run()
