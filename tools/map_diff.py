#!/usr/bin/env python3
"""
map_diff: the corpus's `@call` edges against the bytecode.

`map_extract.py` derives `# Calls (intra-file)` from a regex pass over Lua
source; `map_oracle.py` derives the same fact off `luac -p -l -l`. This joins
the two and classifies every disagreement, which is what answers "how often
does the cheap pass name the wrong binding?".

The unit is the call site, and the join key is the enclosing declaration's
source span rather than its name -- a caller the extractor never captured then
stays visible as its own class instead of confounding the callee diff. Only
intra-file edges are in scope: luac certifies that a call happened and how it
was spelled, never a target module, so `@use` rows cannot be diffed this way.

Agreement on a spelling is not agreement on identity, which is the thing the
corpus can get wrong -- `midiManager` declares `idOf` at file scope and again
inside `mm:load`, and an edge to the inner one would be spelled exactly like
an edge to the outer. So each luac record is walked back through the upvalue
chain to the prototype its callee is a local of: only a binding in the main
chunk is the file-scope declaration a `@call` row claims.

Hand-run, never wired into a hook -- `map_oracle`'s dependence on an
undocumented listing format is inherited whole.

  map_diff.py                  the whole corpus, per-class summary
  map_diff.py <module> ...     restrict to named modules, itemised
  map_diff.py --control        the hand-derived positive control
"""

from __future__ import annotations

import argparse
import re
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

import map_oracle
import map_regen
from map_oracle import Proto, reg

Span = tuple[int, int]              # (lo, hi) -- a declaration's source span


def span_text(span: Span) -> str:
    return f"{span[0]}-{span[1]}"


@dataclass(frozen=True)
class Site:
    """One reduced call site, from either corpus."""
    caller: Span                    # the enclosing map-declared function
    callee: str                     # the spelling, normalised
    line: int


# ----- The map side

# Both rows are emitted by map_extract.emit; `@ n` is a one-liner, so its span
# is (n, n). `@fn`, `@api`, `@held` and `@handler` together are every function
# the map gives a span to, and so every caller a site row can name.
DECL_ROW = re.compile(r'^  @(?:fn|api|held|handler) (\S+?)\((.*)\)  @ (\d+)(?:-(\d+))?$')
CALL_ROW = re.compile(r'^  @call (\S+)  @ (.+)$')
SELF_MARK = re.compile(r'\bself=(\S+)')     # the @module header's marker


@dataclass
class MapSide:
    self_name: str | None = None
    spans: set[Span] = field(default_factory=set)
    heads: set[str] = field(default_factory=set)        # `groups.laneId`, `cloneOut`
    bare_heads: set[str] = field(default_factory=set)   # the same, after bare()
    by_name: dict[str, list[Span]] = field(default_factory=lambda: defaultdict(list))
    sites: set[Site] = field(default_factory=set)
    unattributed: list[tuple[str, int]] = field(default_factory=list)
    n_decls: int = 0


def bare(head: str) -> str:
    """`groups.laneId` -> `laneId`. Callers in `@call` sites are bare for a
    declaration (caller_at returns blk.name) and qualified for a held literal,
    so the index and the lookup both go through here; a bare name is its own
    bare()."""
    return re.split(r'[.:]', head)[-1]


def enclosing(spans, line: int) -> Span | None:
    """The innermost span containing `line` -- map_extract's `innermost`. 20
    bare names across 7 files are ambiguous, so containment decides."""
    hits = [span for span in spans if span[0] <= line <= span[1]]
    return max(hits) if hits else None


# The chunk body's own span. `map_extract` writes `<load>` for a call made
# there; luac gives the main chunk no line range, so both sides spell it 0-0.
MAIN_CHUNK = (0, 0)


def read_map(path: Path) -> MapSide:
    """Every declaration and every `@call` site in one map. Rows that fail to
    parse raise: a dropped row is a defect that cannot be counted, and its
    symptom would be fewer disagreements."""
    ms = MapSide()
    rows: list[tuple[str, str]] = []
    for raw in path.read_text().splitlines():
        if raw.startswith('@module '):
            m = SELF_MARK.search(raw)
            ms.self_name = m[1] if m else None
        elif raw.startswith(('  @fn ', '  @api ', '  @held ', '  @handler ')):
            m = DECL_ROW.match(raw)
            if not m:
                raise ValueError(f"{path.name}: unparsed declaration row {raw!r}")
            span = (int(m[3]), int(m[4] or m[3]))
            ms.n_decls += 1
            ms.spans.add(span)
            ms.by_name[bare(m[1])].append(span)
            # `heads` is the map's *callee* vocabulary, and the `@call` pass
            # spells neither a held literal nor a registered handler as a
            # callee. Admitting the name here would report every
            # `edit.assign(...)` as an edge the map missed, when the map has
            # never claimed to carry it -- those rows buy attribution (a caller
            # with a span), not a new edge.
            if not raw.startswith(('  @held ', '  @handler ')):
                ms.heads.add(m[1])
                ms.bare_heads.add(bare(m[1]))
        elif raw.startswith('  @call '):
            m = CALL_ROW.match(raw)
            if not m:
                raise ValueError(f"{path.name}: unparsed call row {raw!r}")
            # A hot callee splits across several rows under the same head
            # (SITE_ROW_CHUNK), so sites accumulate rather than replace.
            rows.append((m[1], m[2]))

    # Two passes: the Calls section follows the declarations it names, but
    # only by emit order, and a resolution that depended on that is brittle.
    for callee, sites in rows:
        for seg in sites.split():
            caller, sep, nums = seg.rpartition(':')
            for num in nums.split(','):
                line = int(num)
                if not sep:
                    ms.unattributed.append((callee, line))
                    continue
                # Not a declaration, and deliberately unspellable as one, so it
                # resolves against the chunk rather than through by_name.
                if caller == '<load>':
                    ms.sites.add(Site(MAIN_CHUNK, callee, line))
                    ms.spans.add(MAIN_CHUNK)
                    continue
                span = enclosing(ms.by_name.get(bare(caller), ()), line)
                if span is None:
                    raise ValueError(f"{path.name}: `@call {callee}` names caller "
                                     f"{caller!r} at {line}, which no declaration contains")
                ms.sites.add(Site(span, callee, line))
    return ms


# ----- The luac side

# The kinds a `@call` row can be about: a module-private helper, a namespace
# module's own function, a method on this module's own table. Everything else
# is a global, a cross-module call or a local, none of which the corpus claims.
IN_SCOPE_KINDS = ('upvalue', 'upvalue.field', 'method')


def lift(proto: Proto, spans: set[Span]) -> Span | None:
    """The innermost enclosing map-declared span. luac attributes a call inside
    an anonymous closure to that closure's own prototype where the map
    attributes it to the innermost captured declaration -- `mm:notes` returns
    an iterator, and the map row is `@call cloneOut  @ notes:1092`. Without
    this every closure body reads as a disagreement in both directions."""
    while proto is not None:
        if (proto.lo, proto.hi) in spans:
            return (proto.lo, proto.hi)
        proto = proto.parent
    return None


def binder(proto: Proto, upidx: int) -> Proto:
    """The prototype in which upvalue `upidx` of `proto` is a local."""
    while True:
        _, instack, idx = proto.upvals[upidx]
        if proto.parent is None:            # _ENV at the main chunk
            return proto
        if instack:
            return proto.parent
        proto, upidx = proto.parent, idx


def scope(proto: Proto) -> str:
    """A binding in the main chunk is the file-scope declaration a `@call` row
    claims; any other is a nested declaration wearing the same name."""
    return 'file-scope' if proto.parent is None else 'nested binding'


def identity_of(call) -> str:
    """Where the callee this record names was actually bound. `via` is the
    instruction that loaded the callee register, so its opcode says which
    chain to walk."""
    via, proto = call.via, call.proto
    if via is None:
        return 'unresolved: no loader'
    if via.op == 'GETUPVAL':
        return scope(binder(proto, reg(via.args[1])))
    if via.op == 'GETTABUP':
        # B is an upvalue index, not a register -- reg() would be a category
        # error here even though it happens to parse.
        return scope(binder(proto, int(via.args[1])))
    if via.op == 'SELF':
        r = reg(via.args[1])
        writer = map_oracle.writer_of(proto, r, via.pc)
        if writer is None:
            # No loader means a parameter or a plain local; the enclosing
            # declaration's own `self` is identity by construction, because
            # its `@api <recv>:<name>` row names that receiver.
            name = map_oracle.local_name(proto, r, via.pc)
            return 'self-receiver' if name == 'self' else f'unresolved: receiver {name!r}'
        if writer.op == 'GETUPVAL':
            # `self` captured into a nested closure is still the method's own.
            if writer.comment == 'self':
                return 'self-receiver'
            return scope(binder(proto, reg(writer.args[1])))
        # A receiver the loader does not name may still be a live local, and in
        # the main chunk that settles identity: nothing encloses the chunk, so
        # a local of it is the file-scope declaration the `@call` row claims.
        if proto.parent is None and map_oracle.local_name(proto, r, via.pc):
            return 'file-scope'
        return f'unresolved: receiver via {writer.op}'
    # The same argument one register along: a callee MOVEd out of a main-chunk
    # local cannot have come from an enclosing scope, there being none.
    if via.op == 'MOVE' and proto.parent is None:
        if map_oracle.local_name(proto, reg(via.args[1]), via.pc):
            return 'file-scope'
    return f'unresolved: via {via.op}'


# ----- The diff

# (caller span, callee, line, luac kind or '-', class, detail). The span is
# rendered rather than carried: rows are sorted and diffed as whole tuples, and
# a None caller among tuple callers is not orderable against them.
Row = tuple[str, str, int, str, str, str]

CERTIFIED = ('file-scope', 'self-receiver')


def luac_detail(call, callee: str, ms: MapSide) -> str:
    """Why a luac record the map does not carry is, or is not, a miss."""
    if call.kind not in IN_SCOPE_KINDS:
        return 'out of scope'
    if callee not in ms.heads:
        # A file-scope alias (`local resolve = groups.resolve`) reaches a
        # declared function under an undeclared spelling; the map spells
        # callees by declaration head, so the site carries no edge at all.
        if bare(callee) == callee and callee in ms.bare_heads:
            if identity_of(call) == 'file-scope':
                return 'alias'
        return 'out of scope'
    identity = identity_of(call)
    return 'in scope' if identity in CERTIFIED else identity


def verdicts(map_path: Path, src: Path) -> tuple[list[Row], Counter]:
    """Every call site in one module, classified. Out-of-scope records are
    itemised alongside the rest: the summary aggregates, and a control that
    pins a whole source line needs them present to pin it."""
    ms = read_map(map_path)
    protos, found = map_oracle.calls(src)

    by_site: dict[Site, list] = defaultdict(list)
    loose = []
    for call in found:
        callee = call.name
        # map_extract rewrites an intra-module `self:foo()` to the callee's
        # declaration head via `members`; match it.
        if ms.self_name and callee.startswith('self:'):
            callee = ms.self_name + callee[len('self'):]
        # Keyed by span, not prototype: 5 spans in the corpus are shared by a
        # one-liner and an inline closure, so span -> prototype is not
        # injective and identity would otherwise be arbitrary between them.
        span = lift(call.proto, ms.spans)
        if span is None:
            loose.append(call)
        else:
            by_site[Site(span, callee, call.line)].append(call)

    rows: list[Row] = []
    for site in ms.sites & by_site.keys():
        records = by_site[site]
        identities = sorted({identity_of(c) for c in records})
        kinds = sorted({c.kind for c in records})
        rows.append((span_text(site.caller), site.callee, site.line, '/'.join(kinds), 'agreed',
                     identities[0] if len(identities) == 1 else 'mixed: ' + '/'.join(identities)))
    for site in ms.sites - by_site.keys():
        rows.append((span_text(site.caller), site.callee, site.line, '-', 'map-only', ''))
    for site in by_site.keys() - ms.sites:
        for call in by_site[site]:
            rows.append((span_text(site.caller), site.callee, site.line, call.kind, 'luac-only',
                         luac_detail(call, site.callee, ms)))

    for callee, line in ms.unattributed:
        owner = enclosing([(p.lo, p.hi) for p in protos], line) or (0, 0)
        rows.append(('-', callee, line, '-', 'unattributed', f'map, in {span_text(owner)}'))
    for call in loose:
        rows.append(('-', call.name, call.line, call.kind, 'unattributed', 'luac'))

    spans = Counter((p.lo, p.hi) for p in protos)
    stats = Counter(maps=1, decls=ms.n_decls, sites=len(ms.sites) + len(ms.unattributed),
                    protos=len(protos), records=len(found),
                    shared=sum(1 for n in spans.values() if n > 1))
    return sorted(rows, key=lambda r: (r[2], r[1], r[4])), stats


def corpus() -> dict[Path, Path]:
    """The 64 maps under map/. Driven off map_regen, which owns the source-set
    definition: a glob over `*.lua` silently drops the five tests/ harness
    maps, which is the exact failure this is meant to be able to see."""
    return {mp: sp for mp, sp in map_regen.corpus().items() if mp.parent.name == 'map'}


# ----- The report

def summarise(stats: Counter, classes: Counter, kinds: Counter,
              owners: Counter) -> None:
    n_maps = stats['maps']
    print(f"{n_maps} map{'' if n_maps == 1 else 's'}, {stats['decls']} declarations, "
          f"{stats['sites']} @call sites; {stats['protos']} prototypes "
          f"({stats['shared']} spans shared), {stats['records']} luac call records\n")

    unattributed = sum(v for (cls, _), v in classes.items() if cls == 'unattributed')
    lines = [
        ('agreed', sum(v for (cls, _), v in classes.items() if cls == 'agreed'), ''),
        ('    file-scope',     classes[('agreed', 'file-scope')],     ''),
        ('    self-receiver',  classes[('agreed', 'self-receiver')],  'identity by construction'),
        ('    nested binding', classes[('agreed', 'nested binding')], 'FALSE EDGES'),
        ('map-only',            classes[('map-only', '')],            'edges with no bytecode call'),
        ('luac-only, in scope', classes[('luac-only', 'in scope')],   'calls the map should have caught'),
        ('luac-only, alias',    classes[('luac-only', 'alias')],      'declared callee, undeclared spelling'),
        ('', 0, None),
        ('Not disagreements', 0, None),
        ('luac-only, nested binding', classes[('luac-only', 'nested binding')],
         'shadows the map correctly suppressed'),
        ('luac-only, out of scope', classes[('luac-only', 'out of scope')],
         '  '.join(f"{kind} {n}" for kind, n in sorted(kinds.items(), key=lambda kv: -kv[1]))),
        ('unattributed', unattributed,
         f"map {unattributed - classes[('unattributed', 'luac')]}, "
         f"luac {classes[('unattributed', 'luac')]}"),
    ]
    # Tagged, not dropped: a binding the walk could not resolve is neither an
    # agreement nor a miss, and folding it into either would be a guess.
    lines += [(f"luac-only, {detail}", n, 'binding not resolved')
              for (cls, detail), n in sorted(classes.items())
              if cls == 'luac-only' and detail.startswith('unresolved')]
    for label, n, note in lines:
        if note is None:
            print(f"  {label}" if label else "")
            continue
        print(f"  {label:<28}{n:>6}" + (f"   <- {note}" if note else ""))

    if owners:
        print("\n  Prototypes owning the map's unattributed sites -- the declarations "
              "the extractor never captured")
        for (module, owner), n in sorted(owners.items(), key=lambda kv: (kv[0][0], -kv[1])):
            print(f"    {module:<22} {owner:<12} {n}")


# ----- Positive control
#
# Hand-derived from the .lua and the .map. A table written from the tool's own
# output tests nothing but the tool's agreement with itself; where hand-count
# and output disagree the source is the arbiter.

# Pinned whole: every row for groups.lua that is not an out-of-scope record or
# an unattributed one -- so zero map-only and zero luac-only-in-scope are
# certified by the pin being exact, not asserted separately. The four agreed
# sites cross-check map_oracle's own control records at :419 and :431-433.
CONTROL_MODULE = 'groups'
CONTROL_MODULE_ROWS = (
    ('28-69',   'groups.laneId',    58, 'upvalue.field', 'agreed', 'file-scope'),
    ('109-111', 'groups.streamId', 110, 'upvalue.field', 'agreed', 'file-scope'),
    ('114-118', 'groups.streamId', 117, 'upvalue.field', 'agreed', 'file-scope'),
    ('130-133', 'groups.regionKey', 132, 'upvalue.field', 'agreed', 'file-scope'),
    # `local resolve = groups.resolve` at 25, called at 38: a real intra-file
    # edge the corpus does not carry, because it spells callees by head.
    ('28-69',   'resolve',           38, 'upvalue',       'luac-only', 'alias'),
)

# Whole source lines, each reaching a trap the others do not.
CONTROL_SITES = {
    # The lift: the call is in the anonymous iterator `mm:notes` returns, and
    # `@call cloneOut  @ notes:1092` attributes it to the method.
    ('midiManager', 1092): (
        ('1088-1094', 'cloneOut', 'upvalue', 'agreed', 'file-scope'),
    ),
    # A shadow the map correctly suppressed: `local function idOf(cc)` at 624
    # inside mm:load, against the file-scope `@fn idOf(cc)  @ 164`. Spelling
    # alone would score this the same as a genuine edge.
    ('midiManager', 625): (
        ('593-916', 'idOf',     'upvalue',       'luac-only', 'nested binding'),
        ('593-916', 'util.key', 'upvalue.field', 'luac-only', 'out of scope'),
    ),
    # A one-liner declaration span: `@api am:projectTracks()  @ 330` -> (330, 330).
    ('arrangeManager', 330): (
        ('330-330', 'ensureState', 'upvalue', 'agreed', 'file-scope'),
    ),
    # The `self:` rewrite: source spells `self:setEditCursorQN(qn)`, the map
    # row is `@call am:setEditCursorQN  @ playFromQN:536`.
    ('arrangeManager', 536): (
        ('535-538', 'am:setEditCursorQN', 'method', 'agreed', 'self-receiver'),
    ),
    # A shared span: `@api coord:run(handler)  @ 358` and the inline
    # `function(e) error(e) end` both compile to <coordinator.lua:358,358>.
    # `frame` must agree exactly once -- not zero, and not twice.
    ('coordinator', 358): (
        ('358-358', 'frame', 'upvalue', 'agreed', 'file-scope'),
        ('358-358', 'error', 'global', 'luac-only', 'out of scope'),
    ),
    # The same shadow via a `local` rather than an upvalue: `local function
    # snapshot(iter)` at 2000 inside tm:tileLength, against the file-scope
    # `@fn snapshot(evt, verb)  @ 1174-1178`.
    ('trackerManager', 2010): (
        ('1995-2035', 'mm:events', 'method', 'luac-only', 'out of scope'),
        ('1995-2035', 'snapshot',  'local',  'luac-only', 'out of scope'),
    ),
    # A chunk-body call: `edo(12, {…})` inside the `tuning.presets` table
    # constructor, outside every declared span, carried by `<load>`.
    ('tuning', 98): (
        ('0-0', 'edo', 'local', 'agreed', 'file-scope'),
    ),
    # What survives the chunk-body naming: `dropAt` sits inside a one-line
    # `function() … end` under a computed key, so it is neither enclosed by a
    # captured declaration nor at depth 0, and stays honestly unattributed.
    ('arrangeView', 658): (
        ('-', '<call result>.am:keyForSlot', 'method',  'unattributed', 'luac'),
        ('-', 'dropAt',                      '-',       'unattributed', 'map, in 658-658'),
        ('-', 'dropAt',                      'upvalue', 'unattributed', 'luac'),
    ),
}


def module_paths(name: str) -> tuple[Path, Path]:
    for map_path, src in corpus().items():
        if map_path.stem == name:
            return map_path, src
    raise SystemExit(f"no map for module {name!r}")


def control() -> int:
    problems: list[str] = []

    rows, _ = verdicts(*module_paths(CONTROL_MODULE))
    interesting = [r for r in rows
                   if r[4] != 'unattributed' and r[5] != 'out of scope']
    problems += map_oracle.differences(CONTROL_MODULE, CONTROL_MODULE_ROWS, interesting)

    for (module, line), expected in sorted(CONTROL_SITES.items()):
        rows, _ = verdicts(*module_paths(module))
        at_line = [(r[0], r[1], r[3], r[4], r[5]) for r in rows if r[2] == line]
        problems += map_oracle.differences(f"{module}:{line}", expected, at_line)

    pinned = len(CONTROL_MODULE_ROWS) + sum(len(r) for r in CONTROL_SITES.values())
    print(f"control: {pinned} hand-derived rows over "
          f"{len({m for m, _ in CONTROL_SITES} | {CONTROL_MODULE})} modules"
          + (f" -- {len(problems)} disagreements" if problems else " -- all agree"))
    for problem in problems:
        print(problem)
    return 1 if problems else 0


# ----- CLI

def main() -> int:
    ap = argparse.ArgumentParser(
        description="Diff the corpus's @call edges against luac's bytecode.")
    ap.add_argument('modules', nargs='*',
                    help="restrict to these modules and itemise every row")
    ap.add_argument('--control', action='store_true',
                    help="run the hand-derived positive control instead")
    args = ap.parse_args()

    if args.control:
        if args.modules:
            ap.error("--control reads its own fixed module set; drop the names")
        return control()

    stats, classes, kinds, owners = Counter(), Counter(), Counter(), Counter()
    for map_path, src in sorted(corpus().items()):
        if args.modules and map_path.stem not in args.modules:
            continue
        rows, module_stats = verdicts(map_path, src)
        stats.update(module_stats)
        for caller, callee, line, kind, cls, detail in rows:
            classes[(cls, detail)] += 1
            if (cls, detail) == ('luac-only', 'out of scope'):
                kinds[kind] += 1
            if cls == 'unattributed' and detail != 'luac':
                owners[(map_path.stem, detail[len('map, in '):])] += 1
            if args.modules:
                print(f"{map_path.stem}:{line}\t{caller}\t{kind}\t{callee}\t{cls}"
                      + (f"\t{detail}" if detail else ""))
    if args.modules:
        print()
    summarise(stats, classes, kinds, owners)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
