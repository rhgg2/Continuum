#!/usr/bin/env python3
"""Check Lua comment-hygiene rules — on the git diff (vs HEAD) by default,
or on whole files named as arguments (cleanup mode).

Rules (docs/CONVENTIONS.md § Length discipline):
- `--invariant:` / `--contract:` / `--emits:` / `--reaper:` cap at 100 chars.
- `--shape:` is exempt from the 100-char rule but soft-capped at 400 chars
  per line — a single shape line that long is almost certainly either
  prose stuffed in alongside the fields, or a dense shape that should be
  decomposed into named sub-shapes. Both fixes have the same form: split.
- Contiguous WHY-comment runs (consecutive `--` lines that are not KIND
  annotations) cap at 2 lines. Section dividers (`-----`, `----- Name`,
  `---------- PUBLIC`) are structure, not WHY, so they neither count toward
  a run nor join two runs into one.
- Specs are exempt from the run cap: a spec's header and per-case preambles
  ARE its documentation (map/specs/*.map is derived from them). The KIND
  length caps still apply there.

A violation is only flagged when a participating line is in scope: the
added/modified lines in diff mode, every line in cleanup mode. In diff mode
pre-existing offences in untouched code are left alone.

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
DIVIDER     = re.compile(r'^\s*-{3,}')
HUNK_HEAD   = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@')
MAX_KIND_LEN  = 100
MAX_SHAPE_LEN = 400
MAX_RUN       = 2


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


def check_file(path, added):
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
                            f'KIND too long ({len(line)} > {MAX_KIND_LEN})',
                            line.strip()))
            elif SHAPE.match(line) and len(line) > MAX_SHAPE_LEN:
                out.append((path, str(ln),
                            f'shape line too long ({len(line)} > {MAX_SHAPE_LEN}) '
                            f'— split prose to docs/<file>.md or factor sub-shapes',
                            line.strip()[:120] + '...'))
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


def main():
    paths = sys.argv[1:]
    targets = whole_file_lines(paths) if paths else diff_added_lines()
    violations = []
    for path, added in sorted(targets.items()):
        violations.extend(check_file(path, added))
    if not violations:
        print('clean')
        return 0
    for path, loc, msg, preview in violations:
        print(f'{path}:{loc}  {msg}: {preview}')
    return 1


if __name__ == '__main__':
    sys.exit(main())
