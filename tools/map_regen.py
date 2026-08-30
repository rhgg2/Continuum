#!/usr/bin/env python3
"""
map_regen: check or regenerate the whole .map corpus in one process.

`map_extract.py` maps one file per call. This drives it over every source the
corpus covers, in-process, in about two seconds -- which is what makes
byte-identity with a fresh regen assertable at all. A .map that has drifted
from its .lua is worse than no .map, because it still reads as current.

This module owns the source-set definition -- which .lua files have maps, and
where those maps live. Nothing else should re-derive it, which is why the
post-edit hooks drive this rather than map_extract directly.

  map_regen.py           check: regenerate into memory, diff against disk,
                         report every difference, exit non-zero if any
  map_regen.py --write   write the maps whose content has changed
  ... --write --stale-only
                         the same, skipping sources no newer than their map:
                         what the post-edit hooks run, ~45ms against 7s

The maps are generated, not tracked -- `.gitignore` carries `/map/`, and the
SessionStart hook builds them in a tree that hasn't got them. So there is no
`git diff` to review a --write with: before changing the generator, copy the
corpus aside (`cp -R map map.before`) and diff against that.

An orphan is a .map whose source no longer exists. It is reported in both
modes and deleted in neither: a delete is not a regeneration.
"""

import argparse
from pathlib import Path

import map_extract

ROOT = Path(__file__).resolve().parent.parent

# (source glob, output directory), both relative to ROOT.
SOURCE_SETS = (
    ('src/*.lua',         'map'),
    ('src/*/*.lua',       'map'),
    ('tests/*.lua',       'map'),
    ('tests/specs/*.lua', 'map/specs'),
)


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def corpus() -> dict[Path, Path]:
    """Every map the corpus covers: map path -> the source it derives from."""
    sources: dict[Path, Path] = {}
    for pattern, out_dir in SOURCE_SETS:
        for src in sorted(ROOT.glob(pattern)):
            dest = ROOT / out_dir / (src.stem + '.map')
            # map/ is flat over src/, its subdirectories and tests/, so two
            # sources can claim one .map -- and one would silently overwrite the
            # other. This is also what enforces the globally unique module names
            # continuum.lua's flat package.path depends on.
            if dest in sources:
                raise SystemExit(f"map collision: {rel(sources[dest])} and "
                                 f"{rel(src)} both map to {rel(dest)}")
            sources[dest] = src
    return sources


def maps_on_disk() -> set[Path]:
    return {path
            for out_dir in {d for _, d in SOURCE_SETS}
            for path in (ROOT / out_dir).glob('*.map')}


def render(src: Path) -> str:
    is_spec = src.parent.name == 'specs'      # dispatch matches map_extract.main
    return (map_extract.emit_spec(map_extract.parse_spec(src)) if is_spec
            else map_extract.emit(map_extract.parse(src)))


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Check or regenerate every .map in the corpus.")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument('--check', action='store_true',
                      help="report drift without writing anything (the default)")
    mode.add_argument('--write', action='store_true',
                      help="rewrite the maps whose content has changed")
    ap.add_argument('--stale-only', action='store_true',
                    help="with --write: skip sources no newer than their map")
    args = ap.parse_args()

    # Refused rather than supported: an mtime-filtered check would report
    # "all current" having declined to look at the files likeliest to drift.
    if args.stale_only and not args.write:
        ap.error("--stale-only is a --write filter; a check that skipped by "
                 "mtime would pass without reading what it was asked about")

    sources = corpus()
    on_disk = maps_on_disk()

    errors: list[tuple[str, str]] = []
    stale: list[tuple[str, str]] = []
    written = 0

    for dest, src in sorted(sources.items()):
        # mtime, not content: skipping the parse is the entire point. An edit
        # that leaves the map byte-identical still leaves its source newer, so
        # a --write marks the map current below rather than re-rendering it
        # unchanged on every run thereafter.
        if (args.stale_only and dest in on_disk
                and src.stat().st_mtime <= dest.stat().st_mtime):
            continue
        try:
            fresh = render(src)
        except Exception as exc:
            # One unmappable source must not blind the gate to all the others.
            errors.append(('error', f"{rel(src)}  {type(exc).__name__}: {exc}"))
            continue
        current = dest.read_text() if dest in on_disk else None
        if fresh == current:
            if args.write:
                dest.touch()   # the render proved it current; say so in mtime
            continue
        if args.write:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(fresh)
            written += 1
        else:
            stale.append(('missing' if current is None else 'differs', rel(dest)))

    orphans = [('orphan', rel(path)) for path in sorted(on_disk - set(sources))]
    problems = errors + stale + orphans

    headline = f"{len(sources)} sources, {len(on_disk)} maps on disk"
    if args.stale_only:
        headline += ", mtime-filtered"
    if args.write:
        headline += f" -- {written} written" if written else " -- all current"
    elif not problems:
        headline += " -- all current"
    print(headline)
    for kind, detail in problems:
        print(f"  {kind:<8} {detail}")

    # An orphan is a fact about the tree, not a failed write, so it fails the
    # gate but not a regeneration -- otherwise every post-edit hook run trips
    # on a stale map nobody is touching.
    return 1 if (errors if args.write else problems) else 0


if __name__ == '__main__':
    raise SystemExit(main())
