#!/usr/bin/env python3
"""Check Lua comment-hygiene rules — on the git diff (vs HEAD) by default,
on whole files named as arguments (cleanup mode), or on candidate lines fed
to `--measure` on stdin (drafting mode).

Rules (docs/CONVENTIONS.md § Length discipline for annotations):
- `--invariant:` / `--contract:` / `--emits:` / `--reaper:` cap at 100 chars.
- `--shape:` is exempt from the 100-char rule but soft-capped at 400 chars
  per line — a single shape line that long is almost certainly either
  prose stuffed in alongside the fields, or a dense shape that should be
  decomposed into named sub-shapes. Both fixes have the same form: split.
- Contiguous WHY-comment runs (consecutive `--` lines that are not KIND
  annotations) cap at 2 lines. Section dividers (`-----`, `----- Name`,
  `---------- PUBLIC`) are structure, not WHY, so they neither count toward
  a run nor join two runs into one.
- A comment citing `design/`, other than a live plan's design doc: a pointer
  names `docs/`, the layer that persists. Those are exempt because their model
  has nowhere else to be yet; /plan-next repoints them as a phase lands.
- Specs are exempt from the run cap: a spec's header and per-case preambles
  ARE its documentation (map/specs/*.map is derived from them). The KIND
  length caps still apply there.

A violation is only flagged when a participating line is in scope: the
added/modified lines in diff mode, every line in cleanup mode. In diff mode
pre-existing offences in untouched code are left alone.

`--measure` reads candidate replacement lines on stdin and reports
each against its cap. You can batch a bunch in one call.

Exit code: 0 = clean, 1 = violations.
"""
import re
import subprocess
import sys
from pathlib import Path

KIND_CAPPED = re.compile(r'^\s*--\??(invariant|contract|emits|reaper):')
SHAPE       = re.compile(r'^\s*--\??shape:')
ANY_KIND    = re.compile(r'^\s*--\??(invariant|contract|shape|emits|reaper):')
COMMENT     = re.compile(r'^\s*--')
DESIGN_REF  = re.compile(r'^\s*--.*\bdesign/')
DIVIDER     = re.compile(r'^\s*-{3,}')
HUNK_HEAD   = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@')
MAX_KIND_LEN  = 100
MAX_SHAPE_LEN = 400
MAX_RUN       = 2
# Below this overage a trim is the likelier fix, so don't raise the split.
MIN_SPLIT_OVERAGE = 15


def diff_added_lines():
    """Return {file: set(post-image line numbers added/modified)}."""
    proc = subprocess.run(
        ['git', 'diff', '--no-color', '-U0', 'HEAD', '--', '*.lua'],
        capture_output=True, text=True, check=True,
    )
    added, cur_file, cur_line = {}, None, 0
    for raw in proc.stdout.splitlines():
        if raw.startswith('+++ b/'):
            cur_file = raw[6:]
            added.setdefault(cur_file, set())
        elif raw.startswith('+++ '):
            cur_file = None
        elif raw.startswith('@@'):
            m = HUNK_HEAD.match(raw)
            if m:
                cur_line = int(m.group(1))
        elif cur_file and raw.startswith('+') and not raw.startswith('+++'):
            added[cur_file].add(cur_line)
            cur_line += 1
        elif raw.startswith(' '):
            cur_line += 1
    return added


def is_spec(path):
    return 'tests' in Path(path).parts


def live_design_docs():
    """The live plans' design docs — the `design/` paths a comment may cite.
    `plan/CURRENT` names a plan per line, and each plan names its own source."""
    docs = set()
    try:
        names = Path('plan/CURRENT').read_text().split()
    except FileNotFoundError:
        return docs
    for name in names:
        try:
            plan = (Path('plan') / name).read_text()
        except FileNotFoundError:
            continue
        match = re.search(r'^> source:.*`(design/[^`]*)`', plan, re.M)
        if match:
            docs.add(match.group(1))
    return docs


def why_runs(lines):
    """Yield (start, end) 1-based inclusive for contiguous WHY-comment runs."""
    start = None
    for i, line in enumerate(lines, 1):
        is_why = (COMMENT.match(line)
                  and not ANY_KIND.match(line)
                  and not DIVIDER.match(line))
        if is_why:
            if start is None:
                start = i
        elif start is not None:
            yield (start, i - 1)
            start = None
    if start is not None:
        yield (start, len(lines))


def cap_for(line):
    """The per-line cap this line answers to, or None where none applies."""
    if KIND_CAPPED.match(line):
        return MAX_KIND_LEN
    if SHAPE.match(line):
        return MAX_SHAPE_LEN
    return None


def split_hint(line, cap):
    """Name a clause count when the line is over by more than a trim's worth."""
    if len(line) - cap < MIN_SPLIT_OVERAGE:
        return ''
    clauses = [c for c in line.split(':', 1)[1].split(';') if c.strip()]
    if len(clauses) < 2:
        return ''
    return f", {len(clauses)} clauses at ';'"


def check_file(path, added, live_docs):
    out = []
    try:
        lines = Path(path).read_text().splitlines()
    except FileNotFoundError:
        return out
    for ln in sorted(added):
        if 1 <= ln <= len(lines):
            line = lines[ln - 1]
            if KIND_CAPPED.match(line) and len(line) > MAX_KIND_LEN:
                out.append((path, str(ln),
                            f'KIND too long ({len(line)} > {MAX_KIND_LEN}, '
                            f'trim {len(line) - MAX_KIND_LEN})'
                            + split_hint(line, MAX_KIND_LEN),
                            line.strip()))
            elif SHAPE.match(line) and len(line) > MAX_SHAPE_LEN:
                out.append((path, str(ln),
                            f'shape line too long ({len(line)} > {MAX_SHAPE_LEN}) '
                            f'— split prose to docs/<file>.md or factor sub-shapes',
                            line.strip()[:120] + '...'))
            if DESIGN_REF.match(line) and not any(d in line for d in live_docs):
                out.append((path, str(ln),
                            'comment cites design/ — a pointer names docs/',
                            line.strip()))
    if is_spec(path):
        return out
    for start, end in why_runs(lines):
        n = end - start + 1
        if n <= MAX_RUN:
            continue
        if not added.intersection(range(start, end + 1)):
            continue
        out.append((path, f'{start}-{end}',
                    f'WHY run > {MAX_RUN} lines ({n})',
                    lines[start - 1].strip()))
    return out


def whole_file_lines(paths):
    """{file: every line number} — cleanup mode over explicit paths."""
    targets = {}
    for path in paths:
        try:
            n = len(Path(path).read_text().splitlines())
        except FileNotFoundError:
            print(f'{path}: not found', file=sys.stderr)
            continue
        targets[path] = set(range(1, n + 1))
    return targets


def measure(candidates):
    """Report drafted lines against their caps — one call for a whole batch."""
    over = False
    for raw in candidates:
        line = raw.rstrip('\n')
        cap = cap_for(line)
        if cap is None:
            status, budget, delta = '  --', f'{len(line)}', ''
        elif len(line) > cap:
            over, status = True, 'OVER'
            budget, delta = f'{len(line)}/{cap}', f'+{len(line) - cap}'
        else:
            status = 'ok'
            budget, delta = f'{len(line)}/{cap}', ''
        print(f'{status:<4} {budget:>8} {delta:<4} {line}')
    return 1 if over else 0


def main():
    paths = sys.argv[1:]
    if paths and paths[0] == '--measure':
        return measure(sys.stdin.readlines())
    targets = whole_file_lines(paths) if paths else diff_added_lines()
    live_docs = live_design_docs()
    violations = []
    for path, added in sorted(targets.items()):
        violations.extend(check_file(path, added, live_docs))
    if not violations:
        print('clean')
        return 0
    for path, loc, msg, preview in violations:
        print(f'{path}:{loc}  {msg}: {preview}')
    return 1


if __name__ == '__main__':
    sys.exit(main())
