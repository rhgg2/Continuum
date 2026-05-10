#!/usr/bin/env python3
"""
map_extract: Lua source → .map semantic-outline.

The .map file is a derived view, not a source of truth. Regenerate after
every change to the .lua. Read .map for orientation; open .lua before editing.

Heuristics target this codebase's idioms:
  - factory-closure pattern: `function newXxxManager(args) ... return mgr end`
  - method assignment: `function tbl:method(args)`
  - section banners: `----- Name` / `---------- Name`
  - signal emission: `fire('signalName', ...)`
  - REAPER calls: `reaper.X(...)`
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from dataclasses import dataclass, field


COMMENT_RE = re.compile(r"^\s*--\s?(.*)$")
LOAD_MODULE_RE = re.compile(r"""loadModule\(\s*['"]([^'"]+)['"]\s*\)""")
SECTION_RE = re.compile(r"^(\s*)-{5,}\s+(\S.*?)\s*$")
FACTORY_RE = re.compile(r"^function\s+(new[A-Z]\w*)\s*\(([^)]*)\)")
LOCAL_FN_RE = re.compile(r"^(\s*)local\s+function\s+(\w+)\s*\(([^)]*)\)")
METHOD_RE = re.compile(r"^(\s*)function\s+(\w+):(\w+)\s*\(([^)]*)\)")
DOT_FN_RE = re.compile(r"^(\s*)function\s+(\w+)\.(\w+)\s*\(([^)]*)\)")
# Bare `function name(args)` indented inside a factory: assignment to a
# forward-declared upvalue (idiom: `local moveCol do function moveCol(n) ... end end`).
NESTED_FN_RE = re.compile(r"^(\s+)function\s+([a-z]\w*)\s*\(([^)]*)\)")
LOCAL_DECL_RE = re.compile(r"^(\s*)local\s+(\w+)(?:\s*=\s*(.+?))?\s*(?:--.*)?$")
FIRE_RE = re.compile(r"""\bfire\(\s*['"]([^'"]+)['"]""")
REAPER_RE = re.compile(r"\breaper\.(\w+)")
RETURN_TBL_RE = re.compile(r"^\s*return\s+(\w+)\s*$")
INVERSE_RE = re.compile(
    r"for\s+\w+\s*,\s*\w+\s+in\s+pairs\(\s*(\w+)\s*\)\s+do\s+(\w+)\[\w+\]\s*=\s*\w+\s+end"
)
# --@map:KIND BODY  or  --@map?:KIND BODY
MAP_ANN_RE = re.compile(r"^\s*--@map(\??):(\w+)\s+(.*?)\s*$")
EMITS_BODY_RE = re.compile(r"^(\w+)\s*(?:--\s*(.*))?$")

ATTACH_GAP = 3   # max line gap between an annotation and the element it attaches to


Annotation = tuple[str, str, bool]   # (kind, body, has_question)


@dataclass
class Block:
    indent: int
    kind: str               # 'fn', 'method', 'factory'
    name: str
    owner: str = ''         # for methods: the table (e.g. 'mm')
    args: str = ''
    line: int = 0
    end_line: int = 0       # factories: line of closing top-level `end`
    factory_idx: int = -1   # for items inside a factory; -1 if module-level
    doc: list[str] = field(default_factory=list)
    annotations: list[Annotation] = field(default_factory=list)


@dataclass
class Decl:
    name: str
    init: str = ''
    line: int = 0
    factory_idx: int = -1
    inline_doc: str = ''
    annotations: list[Annotation] = field(default_factory=list)


@dataclass
class MapFile:
    module: str
    src: Path
    loc: int
    sha: str
    deps: list[str] = field(default_factory=list)
    factories: list[Block] = field(default_factory=list)
    module_fns: list[Block] = field(default_factory=list)
    module_api: list[Block] = field(default_factory=list)   # function TBL.X(...)
    module_consts: list[Decl] = field(default_factory=list)
    private_fns: list[Block] = field(default_factory=list)   # inside factory
    private_state: list[Decl] = field(default_factory=list)
    methods: list[Block] = field(default_factory=list)       # mm:foo
    method_owner: str = ''
    sections: list[tuple[int, int, str]] = field(default_factory=list)  # (line, indent, label)
    signals: list[str] = field(default_factory=list)
    reaper_calls: list[str] = field(default_factory=list)
    signal_lines: dict[str, list[int]] = field(default_factory=dict)   # name -> source lines
    reaper_lines: dict[str, list[int]] = field(default_factory=dict)
    module_annotations: list[Annotation] = field(default_factory=list)
    factory_annotations: dict[int, list[Annotation]] = field(default_factory=dict)
    shape_annotations: list[tuple[str, str, bool, int]] = field(default_factory=list)  # +ann_line
    signal_payloads: dict[str, str] = field(default_factory=dict)
    pending_annotations: list[tuple[int, str, str, bool]] = field(default_factory=list)


def collect_doc(lines: list[str], i: int) -> list[str]:
    """Walk backwards from line i collecting contiguous comment lines.
    Skips --@map: annotation lines (they're collected separately and rendered
    as structured entries; including them here would duplicate the content)."""
    out: list[str] = []
    j = i - 1
    while j >= 0:
        if MAP_ANN_RE.match(lines[j]):
            j -= 1
            continue
        m = COMMENT_RE.match(lines[j])
        if not m:
            break
        text = m.group(1).rstrip()
        if not text or text.startswith('-'):  # skip banner residue / empty
            break
        out.append(text)
        j -= 1
    return list(reversed(out))


def short_sha(path: Path) -> str:
    try:
        r = subprocess.run(
            ['git', 'log', '-1', '--format=%h', '--', str(path)],
            capture_output=True, text=True, cwd=path.parent,
        )
        return r.stdout.strip() or 'untracked'
    except Exception:
        return 'unknown'


def parse(path: Path) -> MapFile:
    text = path.read_text()
    lines = text.splitlines()

    cm = MapFile(
        module=path.stem,
        src=path,
        loc=len(lines),
        sha=short_sha(path),
    )

    in_factory = False
    current_fac_idx = -1
    factory_body_indent: int | None = None    # the indent of factory's direct children

    for i, raw in enumerate(lines):
        if not raw.strip():
            continue

        # Top-level `end` closes the current factory.
        if in_factory and raw.rstrip() == 'end':
            cm.factories[current_fac_idx].end_line = i + 1
            in_factory = False
            current_fac_idx = -1
            factory_body_indent = None
            continue

        # --@map[?]?:KIND BODY  — accumulate; attached after parse by line proximity
        ma = MAP_ANN_RE.match(raw)
        if ma:
            has_q = ma.group(1) == '?'
            kind, body = ma.group(2), ma.group(3)
            cm.pending_annotations.append((i + 1, kind, body, has_q))
            if kind == 'emits':
                em = EMITS_BODY_RE.match(body)
                if em:
                    cm.signal_payloads[em.group(1)] = (em.group(2) or '').strip()
            continue

        # loadModule deps
        for m in LOAD_MODULE_RE.finditer(raw):
            if m.group(1) not in cm.deps:
                cm.deps.append(m.group(1))

        # section banners: line is exactly "----- Name" (5+ dashes, then label, EOL)
        ms = SECTION_RE.match(raw)
        if ms:
            cm.sections.append((i + 1, len(ms.group(1)), ms.group(2)))

        # factory definition
        mf = FACTORY_RE.match(raw)
        if mf:
            blk = Block(indent=0, kind='factory', name=mf.group(1),
                        args=mf.group(2).strip(), line=i + 1,
                        doc=collect_doc(lines, i))
            cm.factories.append(blk)
            in_factory = True
            current_fac_idx = len(cm.factories) - 1
            factory_body_indent = None
            continue

        # First indented non-blank line inside the factory sets the body indent.
        # Subsequent @state filters use exact equality with this indent.
        if in_factory and factory_body_indent is None:
            stripped = raw.lstrip()
            if stripped and not stripped.startswith('--'):
                indent = len(raw) - len(stripped)
                if indent > 0:
                    factory_body_indent = indent

        # method on table (colon = self-receiver)
        mm = METHOD_RE.match(raw)
        if mm:
            indent = len(mm.group(1))
            blk = Block(indent=indent, kind='method',
                        owner=mm.group(2), name=mm.group(3),
                        args=mm.group(4).strip(), line=i + 1,
                        factory_idx=current_fac_idx,
                        doc=collect_doc(lines, i))
            cm.methods.append(blk)
            if not cm.method_owner:
                cm.method_owner = blk.owner
            continue

        # module-table function (dot = no self): function util.assign(...)
        md_fn = DOT_FN_RE.match(raw)
        if md_fn and not in_factory:
            blk = Block(indent=0, kind='method',
                        owner=md_fn.group(2), name=md_fn.group(3),
                        args=md_fn.group(4).strip(), line=i + 1,
                        doc=collect_doc(lines, i))
            cm.module_api.append(blk)
            continue

        # local function
        ml = LOCAL_FN_RE.match(raw)
        if ml:
            indent = len(ml.group(1))
            blk = Block(indent=indent, kind='fn', name=ml.group(2),
                        args=ml.group(3).strip(), line=i + 1,
                        factory_idx=current_fac_idx if indent > 0 else -1,
                        doc=collect_doc(lines, i))
            if indent == 0:
                cm.module_fns.append(blk)
            else:
                cm.private_fns.append(blk)
            continue

        # bare nested `function name(args)` inside factory: assignment to
        # a forward-declared upvalue (local moveCol; function moveCol(n) ... end).
        if in_factory:
            mn = NESTED_FN_RE.match(raw)
            if mn:
                indent = len(mn.group(1))
                blk = Block(indent=indent, kind='fn', name=mn.group(2),
                            args=mn.group(3).strip(), line=i + 1,
                            factory_idx=current_fac_idx,
                            doc=collect_doc(lines, i))
                cm.private_fns.append(blk)
                continue

        # signals
        for m in FIRE_RE.finditer(raw):
            name = m.group(1)
            cm.signal_lines.setdefault(name, []).append(i + 1)
            if name not in cm.signals:
                cm.signals.append(name)

        # reaper.X
        for m in REAPER_RE.finditer(raw):
            name = m.group(1)
            cm.reaper_lines.setdefault(name, []).append(i + 1)
            if name not in cm.reaper_calls:
                cm.reaper_calls.append(name)

        # private state: `local foo` at exactly the factory body indent,
        # before the first method *of the current factory*. Excludes loop-locals
        # nested in helpers.
        if in_factory and factory_body_indent is not None:
            has_method_in_fac = any(
                m.factory_idx == current_fac_idx for m in cm.methods
            )
            if not has_method_in_fac:
                md = LOCAL_DECL_RE.match(raw)
                if md and not LOCAL_FN_RE.match(raw):
                    indent = len(md.group(1))
                    if indent == factory_body_indent:
                        init = (md.group(3) or '').strip()
                        inline_doc = ''
                        if '--' in raw and not init.startswith("'"):
                            # take inline doc that follows declaration
                            tail = raw.split('--', 1)[1].strip()
                            if tail and not init.endswith(tail):
                                inline_doc = tail
                        if len(init) > 60:
                            init = init[:57] + '...'
                        cm.private_state.append(Decl(name=md.group(2), init=init,
                                                      line=i + 1,
                                                      factory_idx=current_fac_idx,
                                                      inline_doc=inline_doc))

        # module-level constants (indent 0, before factory)
        if not in_factory:
            md = LOCAL_DECL_RE.match(raw)
            if md and md.group(1) == '' and md.group(3):
                init = md.group(3).strip()
                if len(init) > 80:
                    init = init[:77] + '...'
                cm.module_consts.append(Decl(name=md.group(2), init=init, line=i + 1))

        # Loop-built inverse: `for k,v in pairs(Y) do X[v]=k end`
        # Rewrites a prior @const X = {} entry to "inverse of Y" (module or private).
        mi = INVERSE_RE.search(raw)
        if mi:
            src_tbl, dst_tbl = mi.group(1), mi.group(2)
            for d in cm.module_consts:
                if d.name == dst_tbl and d.init == '{}':
                    d.init = f'-- inverse of {src_tbl}'
                    break
            for d in cm.private_state:
                if d.name == dst_tbl and d.init == '{}':
                    d.init = f'-- inverse of {src_tbl}'
                    break

    if in_factory:
        cm.factories[current_fac_idx].end_line = len(lines)

    attach_annotations(cm)
    return cm


def factory_for_line(cm: MapFile, line: int) -> int:
    """Index of the factory whose body contains `line`. Lines that fall in the
    gap between two factories belong to the *next* factory (an annotation between
    factories introduces the section it precedes). Returns -1 if past all factories
    or there are none."""
    for idx, fac in enumerate(cm.factories):
        end = fac.end_line if fac.end_line else 10**9
        if line <= end:
            return idx
    return -1


def attach_annotations(cm: MapFile) -> None:
    """Attach pending annotations to nearest following structural element.

    Rules:
      - shape  → always rendered standalone (under # Shapes), never attached.
      - emits  → consumed into cm.signal_payloads during parse; not attached.
      - other (contract, invariant) → attach to next element with line ≥ ann_line
        and (target.line - ann_line) ≤ ATTACH_GAP. Otherwise route to
        module_annotations (before any factory) or to the enclosing factory's
        annotations bucket. Annotations between two factories (no nearby struct)
        attach to the *next* factory's bucket via factory_for_line.
    """
    targets: list = []
    targets.extend(cm.module_consts)
    targets.extend(cm.private_state)
    targets.extend(cm.factories)
    targets.extend(cm.methods)
    targets.extend(cm.module_fns)
    targets.extend(cm.module_api)
    targets.extend(cm.private_fns)
    targets.sort(key=lambda t: t.line)

    for ann_line, kind, body, has_q in cm.pending_annotations:
        if kind == 'emits':
            continue
        if kind == 'shape':
            cm.shape_annotations.append((kind, body, has_q, ann_line))
            continue
        target = None
        for t in targets:
            if t.line >= ann_line:
                target = t
                break
        if target is not None and target.line - ann_line <= ATTACH_GAP:
            target.annotations.append((kind, body, has_q))
            continue
        # Fallback: route to enclosing factory by line range; module-level
        # otherwise (i.e. before any factory).
        before_first_factory = (
            cm.factories and ann_line < cm.factories[0].line
        ) or not cm.factories
        if before_first_factory:
            cm.module_annotations.append((kind, body, has_q))
            continue
        fac_idx = factory_for_line(cm, ann_line)
        if fac_idx < 0:
            cm.module_annotations.append((kind, body, has_q))
        else:
            cm.factory_annotations.setdefault(fac_idx, []).append((kind, body, has_q))


def fmt_args(args: str) -> str:
    return f"({args})" if args else "()"


def fmt_ann(ann: Annotation) -> str:
    kind, body, q = ann
    mark = '?' if q else ''
    return f"@map{mark}:{kind}  {body}"


def emit_annotations(out: list[str], anns: list[Annotation], indent: str) -> None:
    for ann in anns:
        out.append(f"{indent}{fmt_ann(ann)}")


def emit(cm: MapFile) -> str:
    out: list[str] = []
    add = out.append

    add(f"@module {cm.module}  src={cm.src.name}  loc={cm.loc}  sha={cm.sha}")
    if cm.deps:
        add(f"@deps {', '.join(cm.deps)}")
    add('')

    if cm.module_annotations:
        add("# Invariants & contracts (module)")
        emit_annotations(out, cm.module_annotations, '  ')
        add('')

    fac0_line = cm.factories[0].line if cm.factories else 10**9
    module_shapes = [(k, b, q) for (k, b, q, L) in cm.shape_annotations if L < fac0_line]
    if module_shapes:
        add("# Shapes")
        for _, body, q in module_shapes:
            mark = '?' if q else ''
            add(f"  @shape{mark}  {body}")
        add('')

    if cm.module_consts:
        add("# Module-level constants")
        for d in cm.module_consts:
            if d.init.startswith('--'):
                add(f"  @const {d.name}  @ {d.line}   {d.init}")
            else:
                add(f"  @const {d.name} = {d.init}  @ {d.line}")
            emit_annotations(out, d.annotations, '      ')
        add('')

    if cm.module_fns:
        add("# Module-level functions (private)")
        for f in cm.module_fns:
            line = f"  @fn {f.name}{fmt_args(f.args)}  @ {f.line}"
            if f.doc:
                line += f"   -- {' '.join(f.doc)[:80]}"
            add(line)
            emit_annotations(out, f.annotations, '      ')
        add('')

    if cm.module_api:
        # Resolve `local M = <alias>` to <alias>.X for legibility.
        alias_target: str | None = None
        for d in cm.module_consts:
            if d.init and d.init.isidentifier():
                alias_target = d.init
                break
        owners = sorted({(alias_target if a.owner == 'M' and alias_target else a.owner)
                         for a in cm.module_api})
        owner_label = ' / '.join(owners)
        add(f"# Public API ({owner_label}.*)")
        for f in cm.module_api:
            owner = alias_target if (f.owner == 'M' and alias_target) else f.owner
            line = f"  @api {owner}.{f.name}{fmt_args(f.args)}  @ {f.line}"
            add(line)
            if f.doc:
                for d in f.doc:
                    add(f"      -- {d}")
            emit_annotations(out, f.annotations, '      ')
        add('')

    for fac_idx, fac in enumerate(cm.factories):
        fac_end = fac.end_line if fac.end_line else 10**9
        in_fac = lambda L, _s=fac.line, _e=fac_end: _s <= L <= _e
        fac_methods = [m for m in cm.methods if in_fac(m.line)]
        fac_pfns    = [f for f in cm.private_fns if in_fac(f.line)]
        fac_state   = [d for d in cm.private_state if in_fac(d.line)]
        fac_shapes  = [(k, b, q) for (k, b, q, L) in cm.shape_annotations
                       if L >= fac0_line and factory_for_line(cm, L) == fac_idx]
        fac_signals = [n for n in cm.signals
                       if any(in_fac(L) for L in cm.signal_lines.get(n, []))]
        fac_reaper  = [n for n in cm.reaper_calls
                       if any(in_fac(L) for L in cm.reaper_lines.get(n, []))]

        add(f"@factory {fac.name}{fmt_args(fac.args)}  @ {fac.line}")
        if fac.doc:
            for d in fac.doc:
                add(f"  -- {d}")
        emit_annotations(out, fac.annotations, '  ')
        emit_annotations(out, cm.factory_annotations.get(fac_idx, []), '  ')

        if fac_shapes:
            add("")
            add("  # Shapes")
            for kind, body, q in fac_shapes:
                mark = '?' if q else ''
                add(f"    @shape{mark}  {body}")

        if fac_state:
            add("")
            add("  # Private state")
            for d in fac_state:
                head = f"    @state {d.name}"
                if d.init:
                    head += f" = {d.init}"
                head += f"  @ {d.line}"
                if d.inline_doc:
                    head += f"   -- {d.inline_doc}"
                add(head)
                emit_annotations(out, d.annotations, '        ')

        if fac_pfns:
            add("")
            add("  # Private functions")
            for f in fac_pfns:
                line = f"    @fn {f.name}{fmt_args(f.args)}  @ {f.line}"
                if f.doc:
                    line += f"   -- {' '.join(f.doc)[:90]}"
                add(line)
                emit_annotations(out, f.annotations, '        ')

        if fac_methods:
            add("")
            add(f"  # Public API")
            sections = list(cm.sections)
            for idx, m in enumerate(fac_methods):
                next_line = fac_methods[idx + 1].line if idx + 1 < len(fac_methods) else 10**9
                # Banner classification by indent:
                #   indent <= method indent → sibling divider (emit before @api)
                #   indent  > method indent → sub-section inside this method's body
                pre, inside = [], []
                rest = []
                for sec in sections:
                    line, sec_indent, label = sec
                    if line >= next_line:
                        rest.append(sec); continue
                    if sec_indent <= m.indent:
                        if line < m.line:
                            pre.append(sec)
                        else:
                            # banner at same level but after method start: belongs to next
                            rest.append(sec)
                    else:
                        if line >= m.line:
                            inside.append(sec)
                        else:
                            pre.append(sec)
                sections = rest
                for sec in pre:
                    if sec[2] not in ('PRIVATE', 'PUBLIC', 'Utils'):
                        add(f"    -- {sec[2]}")
                add(f"    @api {m.owner}:{m.name}{fmt_args(m.args)}  @ {m.line}")
                if m.doc:
                    for d in m.doc:
                        add(f"        -- {d}")
                emit_annotations(out, m.annotations, '        ')
                for sec in inside:
                    add(f"        · {sec[2]}")

        if fac_signals:
            add("")
            add("  # Signals emitted (via util.installHooks)")
            for s in fac_signals:
                payload = cm.signal_payloads.get(s)
                if payload:
                    add(f"    @emits {s}   -- {payload}")
                else:
                    add(f"    @emits {s}")

        if fac_reaper:
            add("")
            add("  # REAPER API surface")
            # group reaper calls by prefix
            groups: dict[str, list[str]] = {}
            for r in fac_reaper:
                key = r.split('_', 1)[0] if '_' in r else r
                groups.setdefault(key, []).append(r)
            for key, names in groups.items():
                add(f"    @reaper {', '.join(names)}")

    return '\n'.join(out) + '\n'


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: map_extract.py <lua-file> [<out-dir>]", file=sys.stderr)
        return 2
    src = Path(argv[1]).resolve()
    out_dir = Path(argv[2]).resolve() if len(argv) > 2 else src.parent / 'map'
    out_dir.mkdir(parents=True, exist_ok=True)
    cm = parse(src)
    out_path = out_dir / (src.stem + '.map')
    out_path.write_text(emit(cm))
    print(out_path)
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
