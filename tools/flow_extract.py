#!/usr/bin/env python3
"""flow_extract: the payload behind the flow viewer.

For every mapped module: its source, its declarations, the typed block tree
inside each declaration, and each call site resolved to the declaration it
reaches. The viewer expands a callee inline at its call site, so the payload's
whole job is to answer, for any line, "what does this call and where does that
live".

A named nested `local function` becomes a declaration in its own right, so a
helper reads as a callee expanded where it is called rather than as inline text
between its caller's statements -- `chrome.makeToolbar` is 71 of its 77 lines
such definitions. These are the one edge the maps cannot supply: the extractor
records no @call for a target it has no declaration for, so a call to a nested
helper is not an unresolved edge but no edge at all, and the call sites are
found here by name. See docs/flow-viewer.md § Nested locals for what that
costs.

Block typing is a second walk over `map_extract.strip_code`'s masked lines
rather than a change to `walk_block_tokens`. Masking is where the subtle bugs
live and stays single-owner; the two walks want different things -- the
extractor counts function depth at a column, this wants typed spans -- and the
extractor's walk runs on the post-edit hook path, which is a bad place to take
risk for a viewer's benefit.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from functools import lru_cache
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from map_extract import strip_code
from map_index import (MAP_DIR, PROJECT_ROOT, callee_cross_decl,
                       callee_intra_decl, decl_index, decl_indexer,
                       selfname_registry, src_of)

# `for`/`while` do not open a block -- their `do` does -- so they arm the next
# `do` rather than pushing. `elseif` reuses its `if`'s block, so it spends one
# upcoming `then`. Everything else opens or closes on its own token.
_TOK = re.compile(r'\b(function|for|while|do|then|repeat|elseif|else|end|until|return|break|goto)\b')
_OPENS_ON_DO = ('for', 'while')
_MARKERS = ('else', 'elseif', 'return', 'break', 'goto')


def block_frames(code_lines: list[str], raw_lines: list[str],
                 start: int, end: int) -> tuple[list[dict], list[dict], int]:
    """Typed frames and branch markers within the declaration at 1-based
    [start, end]. Returns (frames, markers, close_line): close_line is where
    the declaration's own `function` frame closed, which the caller checks
    against the map's independently-computed span."""
    frames: list[dict] = []
    markers: list[dict] = []
    stack: list[dict] = []
    pending: str | None = None      # a `for`/`while` awaiting its `do`
    skip_then = 0
    close_line = end

    for n in range(start, min(end, len(code_lines)) + 1):
        for m in _TOK.finditer(code_lines[n - 1]):
            tok = m.group(1)
            if tok in _OPENS_ON_DO:
                pending = tok
            elif tok in ('function', 'do', 'repeat', 'then'):
                if tok == 'then' and skip_then:
                    skip_then -= 1
                    continue
                kind = ('fn' if tok == 'function'
                        else 'if' if tok == 'then'
                        else pending or tok)
                pending = None
                stack.append({'kind': kind, 'line': n, 'depth': len(stack),
                              'head': raw_lines[n - 1].strip()})
            elif tok in _MARKERS:
                if tok == 'elseif':
                    skip_then += 1
                markers.append({'kind': tok, 'line': n,
                                'depth': max(len(stack) - 1, 0)})
            else:                                   # end | until
                if not stack:
                    continue
                frame = stack.pop()
                frame['end'] = n
                if not stack:                       # the declaration itself
                    close_line = n
                    return frames, markers, close_line
                frames.append(frame)

    # An unclosed stack means the walk ran past the map's span; the frames
    # gathered so far still describe the part it did cover.
    for frame in stack[1:]:
        frame.setdefault('end', close_line)
        frames.append(frame)
    return frames, markers, close_line


_LOCAL_FN = (re.compile(r'^\s*local\s+function\s+([A-Za-z_]\w*)\s*\('),
             re.compile(r'^\s*local\s+([A-Za-z_]\w*)\s*=\s*function\b'))
# Lua's three call spellings: `f(...)`, `f{...}`, `f"..."`. The lookbehind keeps
# `t.f(` and `t:f(` out -- those reach a field, and the local is not it.
_CALL_OF = r'(?<![\w.:])%s\s*[({\'"]'


# `-----`, `----- Name`, `---------- PUBLIC`: structure rather than any one
# declaration's prose, so a divider bounds a comment block instead of joining
# it. See docs/CONVENTIONS.md for the divider grammar.
_DIVIDER = re.compile(r'^\s*---')


def comment_head(raw: list[str], n: int, floor: int = 1) -> int:
    """Where the comment block written for the declaration at `n` begins. It is
    the declaration's own documentation -- often its `--contract:` and
    `--shape:` lines -- so it travels with the body wherever that is shown."""
    while n - 1 >= floor:
        line = raw[n - 2]
        if not line.lstrip().startswith('--') or _DIVIDER.match(line):
            break
        n -= 1
    return n


def local_name(head: str) -> str | None:
    """The name a nested function frame binds, or None for the anonymous
    majority -- a callback passed inline has no call site to point a chip at."""
    for rx in _LOCAL_FN:
        m = rx.match(head)
        if m:
            return m.group(1)
    return None


@lru_cache(maxsize=None)
def call_rx(name: str) -> re.Pattern:
    return re.compile(_CALL_OF % re.escape(name))


# Instrumentation reads as flow and is not any: a perf pair brackets the work
# rather than doing it. Only a call standing as a whole statement can be elided
# -- `local n = perf.count(...)` consumes the value, and perf.lua's own
# `function perf.start(name)` is a declaration, so both fail the test and stay.
_PERF = re.compile(r'\bperf\.\w+\s*\(')
_STMT_START = re.compile(r'(^|;|\b(?:then|do|else|repeat))\s*$')


def perf_spans(code: str) -> list[list[int]]:
    """[lo, hi) of each instrumentation statement on a masked line, its trailing
    `;` and spacing included so eliding it leaves no orphaned separator."""
    out = []
    for m in _PERF.finditer(code):
        if not _STMT_START.search(code[:m.start()]):
            continue
        depth, i = 0, m.end() - 1
        while i < len(code):
            if code[i] == '(':
                depth += 1
            elif code[i] == ')':
                depth -= 1
                if not depth:
                    break
            i += 1
        else:
            continue                      # unbalanced: the call spans lines
        hi = i + 1
        while hi < len(code) and code[hi] == ' ':
            hi += 1
        if hi < len(code) and code[hi] == ';':
            hi += 1
            while hi < len(code) and code[hi] == ' ':
                hi += 1
        out.append([m.start(), hi])
    return out


def call_sites(map_text: str) -> dict[int, list[tuple[str, str]]]:
    """line -> [(scope, name)] for every call the map records, scope being
    'intra' (@call, keyed by declaration head) or 'cross' (@use call)."""
    sites: dict[int, list[tuple[str, str]]] = {}
    patterns = ((re.compile(r'^\s*@call\s+(?P<name>\S+)\s+@\s+(?P<sites>.+?)\s*$'), 'intra'),
                (re.compile(r'^\s*@use\s+call\s+(?P<name>\S+)\s+@\s+(?P<sites>.+?)\s*$'), 'cross'))
    for raw in map_text.splitlines():
        for rx, scope in patterns:
            m = rx.match(raw)
            if not m:
                continue
            for seg in m.group('sites').split():
                _, _, nums = seg.rpartition(':')
                for num in nums.split(','):
                    if num.strip().isdigit():
                        sites.setdefault(int(num), []).append((scope, m.group('name')))
    return sites


def decl_id(e) -> str:
    """The join key, and it has to be unique: two held functions can share a
    line (`local nullPa = { binding = function() end, apply = function() end }`),
    so src:line alone collides and one silently displaces the other."""
    return f"{e.src}:{e.start}:{e.bare}"


def resolve_root(payload: dict, spec: str) -> str | None:
    """A root spec may be a full id or the `file.lua:line` a reader would paste
    from an editor; the latter takes the first declaration on that line."""
    if spec in payload['decls']:
        return spec
    prefix = spec if spec.endswith(':') else spec + ':'
    return next((k for k in payload['decls'] if k.startswith(prefix)), None)


def emit(ctx: dict, kind: str, head: str, name: str, start: int, end: int,
         scope: list[dict], floor: int = 1) -> int:
    """Add the declaration spanning [start, end] to the payload and recurse into
    each named nested local. Returns where our walk closed the declaration's own
    frame, which the caller checks against the map's span.

    `scope` is the named locals visible here, outermost first; a call to one is
    what the map cannot tell us, so it is matched by name against the masked
    source. Lua binds a local from its declaration onwards, which is why a site
    must sit below its target's line -- that alone excludes the later sibling a
    bare name search would otherwise reach."""
    code, raw, report = ctx['code'], ctx['raw'], ctx['report']
    frames, marks, close = block_frames(code, raw, start, end)

    kids = [dict(f, name=local_name(f['head'])) for f in frames if f['kind'] == 'fn']
    kids = [k for k in kids if k['name']]
    # Two locals of one name under one parent give a call site no unambiguous
    # target, so neither is lifted out and both stay inline where they are.
    twice = {n for n, c in Counter(k['name'] for k in kids).items() if c > 1}
    report['ambiguous'] += sum(1 for k in kids if k['name'] in twice)
    kids = [k for k in kids if k['name'] not in twice]
    # Only this level: a local inside a local is found again when we recurse.
    direct = [k for k in kids
              if not any(o['line'] < k['line'] and k['end'] <= o['end'] for o in kids)]
    for k in direct:
        k['to'] = f"{ctx['src']}:{k['line']}:{k['name']}"

    def owned(n: int) -> bool:
        """Belongs to a lifted child. Its head line counts as the child's: the
        parent still renders that line, as the stub the reader expands from, but
        anything on it is the child's first line and would otherwise be
        attributed -- and chipped -- in both places."""
        return any(k['line'] <= n <= k['end'] for k in direct)

    visible = scope + direct
    calls: list[dict] = []
    for n in range(start, min(end, len(code)) + 1):
        if owned(n):
            continue
        local_here = set()
        for s in visible:
            if n <= s['line'] or not call_rx(s['name']).search(code[n - 1]):
                continue
            calls.append({'line': n, 'text': s['name'], 'to': s['to'], 'why': None})
            local_here.add(s['name'])
            report['local_calls'] += 1
        for scope_kind, cname in ctx['sites'].get(n, ()):
            # A local shadows a module function of the same name, so the map's
            # edge for this line points past the binding actually in force.
            if cname.split('.')[-1].split(':')[-1] in local_here:
                report['shadowed'] += 1
                continue
            hit = (callee_intra_decl(cname, ctx['index']) if scope_kind == 'intra'
                   else callee_cross_decl(cname, ctx['decls'], ctx['reg']))
            calls.append({'line': n, 'text': cname,
                          'to': decl_id(hit) if hit else None,
                          'why': None if hit else 'external'})
            report['resolved' if hit else 'unresolved'] += 1
    calls.sort(key=lambda c: c['line'])

    did = f"{ctx['src']}:{start}:{name}"
    if did in ctx['payload']['decls']:
        report['collision'] += 1
    ctx['payload']['decls'][did] = {
        'module': ctx['stem'], 'src': ctx['src'], 'kind': kind, 'head': head,
        'name': name, 'start': start, 'end': end,
        'from': comment_head(raw, start, floor),
        'blocks': [f for f in frames if not owned(f['line'])],
        'marks': [m for m in marks if not owned(m['line'])],
        'calls': calls,
        'locals': [{'line': k['line'], 'end': k['end'], 'name': k['name'],
                    'to': k['to'], 'from': comment_head(raw, k['line'], start)}
                   for k in direct]}
    report['decls'] += 1
    report['locals'] += len(direct)

    for k in direct:
        # `local function f` binds f inside its own body, so a child sees itself
        # and everything declared above it -- but not a later sibling.
        emit(ctx, 'local', k['head'], k['name'], k['line'], k['end'],
             [s for s in visible if s['line'] < k['line']] + [k], start)
    return close


def build(stems: list[str]) -> tuple[dict, dict]:
    """(payload, report). The report counts spans where our block walk and the
    map's span logic disagree -- two independent derivations of the same fact,
    so a mismatch is a real defect in one of them and not a formatting note."""
    reg = selfname_registry()
    decls = decl_indexer()
    payload: dict = {'modules': {}, 'decls': {}}
    report = {'span_mismatch': [], 'unresolved': 0, 'resolved': 0, 'outside': 0,
              'decls': 0, 'locals': 0, 'local_calls': 0, 'ambiguous': 0,
              'shadowed': 0, 'collision': 0, 'perf': 0}

    for stem in stems:
        mp = MAP_DIR / f"{stem}.map"
        map_text = mp.read_text(encoding='utf-8', errors='replace')
        src = src_of(mp, map_text)
        source_path = PROJECT_ROOT / src
        if not source_path.exists():
            continue
        text = source_path.read_text(encoding='utf-8', errors='replace')
        raw_lines = text.splitlines()
        code_lines = strip_code(text)
        index = decl_index(mp)
        sites = call_sites(map_text)
        # Lines the masker blanked entirely are the interior of a long comment or
        # string. The viewer highlights per line, so without this it would tokenise
        # prose as code; `strip_code` already knows, so it need not guess.
        masked = [n for n, (code, raw) in enumerate(zip(code_lines, raw_lines), 1)
                  if raw.strip() and not code.strip()]
        # perf.lua's own calls are the mechanism rather than instrumentation of
        # anything, so eliding `perf.dump()` from `perf.toggle` would delete the
        # body of the function the reader came for.
        perf = {} if src == 'perf.lua' else {
            n: sp for n, code in enumerate(code_lines, 1) if (sp := perf_spans(code))}

        def bare_of(n, sp):
            s = code_lines[n - 1]
            for lo, hi in reversed(sp):
                s = s[:lo] + s[hi:]
            return s

        payload['modules'][stem] = {
            'src': src, 'lines': raw_lines, 'masked': masked, 'perf': perf,
            'perfOnly': [n for n, sp in perf.items() if not bare_of(n, sp).strip()]}
        report['perf'] += sum(len(sp) for sp in perf.values())

        ctx = {'stem': stem, 'src': src, 'code': code_lines, 'raw': raw_lines,
               'sites': sites, 'index': index, 'decls': decls, 'reg': reg,
               'payload': payload, 'report': report}
        for e in index:
            close = emit(ctx, e.kind, e.head, e.bare, e.start, e.end, [])
            if close != e.end:
                report['span_mismatch'].append(
                    {'decl': f"{src}:{e.start}", 'head': e.head,
                     'map_end': e.end, 'walk_end': close})

    # A call can resolve to a declaration in a module this build left out. That
    # is a different fact from `(external)` -- the target exists and is simply
    # absent here -- and the viewer must not render the two the same way, or a
    # narrowed build reads as a corpus full of foreign calls.
    for d in payload['decls'].values():
        for c in d['calls']:
            if c['to'] and c['to'] not in payload['decls']:
                c['to'], c['why'] = None, 'outside'
                report['resolved'] -= 1
                report['outside'] += 1
    return payload, report


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('modules', nargs='*', help='map stems; default every module map')
    ap.add_argument('--out', type=Path, help='write the payload as JSON here')
    ap.add_argument('--report', action='store_true', help='print the consistency report')
    args = ap.parse_args(argv)

    stems = args.modules or sorted(p.stem for p in MAP_DIR.glob('*.map'))
    payload, report = build(stems)
    if args.out:
        args.out.write_text(json.dumps(payload), encoding='utf-8')
    if args.report or not args.out:
        print(f"{len(payload['modules'])} modules, {report['decls']} declarations "
              f"({report['locals']} of them nested locals), "
              f"{report['resolved']} calls resolved, {report['unresolved']} external, "
              f"{report['outside']} outside this build")
        print(f"perf statements elidable: {report['perf']}")
        print(f"local calls matched: {report['local_calls']}, "
              f"shadowing the map at {report['shadowed']} sites; "
              f"{report['ambiguous']} locals left inline as ambiguous, "
              f"{report['collision']} id collisions")
        print(f"span mismatches: {len(report['span_mismatch'])}")
        for row in report['span_mismatch'][:15]:
            print(f"  {row['decl']}  {row['head']}  map={row['map_end']} walk={row['walk_end']}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
