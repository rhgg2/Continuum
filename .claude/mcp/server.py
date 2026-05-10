#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2"]
# ///
"""Readium project MCP server.

Tools:
  - reaper_doc_lookup: parse the bundled REAPER + ReaImGui HTML docs and
    return clean prose entries by function/constant name. Avoids the
    922 KB / 1.2 MB raw-HTML grep dance for API verification.

The HTML files are read fresh on each call (fast: regex over ~10 MB total
in <50 ms) so updates to docs/ are picked up without a server restart.
"""

from __future__ import annotations

import html
import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import Optional

from mcp.server.fastmcp import FastMCP

PROJECT_ROOT = Path(__file__).resolve().parents[2]
REASCRIPT_HTML = PROJECT_ROOT / "docs" / "REAPER API functions.html"
IMGUI_HTML = PROJECT_ROOT / "docs" / "reaper_imgui_doc.html"

mcp = FastMCP("readium")


# ----- HTML helpers ---------------------------------------------------------

_TAG = re.compile(r"<[^>]+>")
_WS = re.compile(r"[ \t]+")


def _strip_tags(s: str) -> str:
    s = _TAG.sub("", s)
    s = html.unescape(s)
    s = _WS.sub(" ", s)
    return s.strip()


# ----- ReaScript HTML parser ------------------------------------------------
# Anchor: <a name="FuncName"><hr></a><br>
# Followed by <div class="c_func">..</div>, e_func, l_func, p_func divs,
# then optional prose lines, until the next <a name=...>.

_RS_ANCHOR = re.compile(r'<a name="([^"]+)"><hr></a><br>')
_RS_LUA_SIG = re.compile(
    r'<div class="l_func">.*?<code>(.*?)</code>', re.DOTALL
)
_RS_FUNC_DIV_END = re.compile(
    r'<div class="p_func">.*?</div>', re.DOTALL
)


def _load_reascript() -> list[tuple[str, int, int]]:
    """Return [(name, start_offset, end_offset)] sorted by name."""
    text = REASCRIPT_HTML.read_text(encoding="utf-8", errors="replace")
    matches = list(_RS_ANCHOR.finditer(text))
    out: list[tuple[str, int, int]] = []
    for i, m in enumerate(matches):
        start = m.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        # Skip non-function anchors (function_list, eel_*, etc.)
        name = m.group(1)
        if name in {"function_list"} or "_" not in name and name == name.lower():
            # heuristic: real REAPER API fns are CamelCase or have prefix; skip
            # all-lowercase no-underscore names like "eel_list" never reached here
            # but be lenient — only filter the known index anchor.
            pass
        if name == "function_list":
            continue
        out.append((name, start, end))
    return out, text


def _format_reascript_entry(name: str, body: str) -> str:
    lua_sig_m = _RS_LUA_SIG.search(body)
    lua_sig = _strip_tags(lua_sig_m.group(1)) if lua_sig_m else "(no Lua signature)"
    # Prose: everything after the last _func div
    end_m = list(_RS_FUNC_DIV_END.finditer(body))
    if end_m:
        prose_html = body[end_m[-1].end():]
    else:
        prose_html = ""
    prose_html = re.sub(r'<br\s*/?>', '\n', prose_html)
    prose = _strip_tags(prose_html).strip()
    return f"=== reascript: {name} ===\n{lua_sig}\n\n{prose}".rstrip()


# ----- ImGui HTML parser ----------------------------------------------------
# <details id="Name"><summary>Function: Name</summary>
#   <table>...<tr><th>Lua</th><td><code>SIG</code></td></tr>...</table>
#   <p>DESCRIPTION</p>
#   [<p class="meta">version/source</p>]
# </details>

_IM_ENTRY = re.compile(
    r'<details id="([^"]+)"><summary>([^<]+)</summary>(.*?)</details>',
    re.DOTALL,
)
_IM_LUA_ROW = re.compile(
    r'<tr><th>Lua</th><td><code>(.*?)</code></td></tr>', re.DOTALL
)
_IM_DESC = re.compile(r'<p(?: class="(?!meta)[^"]*")?>(.*?)</p>', re.DOTALL)
_IM_META = re.compile(r'<p class="meta">(.*?)</p>', re.DOTALL)


def _load_imgui() -> dict[str, tuple[str, str]]:
    """Return {name: (kind_label, raw_body)}."""
    text = IMGUI_HTML.read_text(encoding="utf-8", errors="replace")
    out: dict[str, tuple[str, str]] = {}
    for m in _IM_ENTRY.finditer(text):
        name = m.group(1)
        summary = m.group(2)  # e.g. "Function: ArrowButton" or "Constant: ButtonFlags_..."
        out[name] = (summary, m.group(3))
    return out


def _format_imgui_entry(name: str, summary: str, body: str) -> str:
    lua_m = _IM_LUA_ROW.search(body)
    lua_sig = _strip_tags(lua_m.group(1)) if lua_m else "(no Lua signature)"
    desc_parts = [_strip_tags(d.group(1)) for d in _IM_DESC.finditer(body)]
    desc = "\n".join(p for p in desc_parts if p)
    meta_m = _IM_META.search(body)
    meta = _strip_tags(meta_m.group(1)) if meta_m else ""
    out = [f"=== imgui {summary.strip()} ===", lua_sig]
    if desc:
        out += ["", desc]
    if meta:
        out += ["", f"({meta})"]
    return "\n".join(out)


# ----- Tool -----------------------------------------------------------------


def _glob_to_regex(pat: str) -> re.Pattern:
    # Translate * and ? into regex; everything else literal. Case-insensitive.
    parts = []
    for ch in pat:
        if ch == "*":
            parts.append(".*")
        elif ch == "?":
            parts.append(".")
        else:
            parts.append(re.escape(ch))
    return re.compile("^" + "".join(parts) + "$", re.IGNORECASE)


@mcp.tool(structured_output=False)
def reaper_doc_lookup(
    name: str,
    kind: str = "auto",
    max_matches: int = 30,
) -> str:
    """Look up a REAPER ReaScript or ReaImGui API entry by name.

    Returns the Lua signature plus the prose description, parsed from the
    bundled docs/ HTML. Replaces grepping the raw 922 KB / 1.2 MB HTML
    files (which return ~50 lines of markup per hit).

    Args:
      name: function or constant name. Case-insensitive. Wildcards `*` and
            `?` are supported — wildcard queries return a one-line index
            (name + Lua signature) instead of full prose, capped at
            `max_matches`.
      kind: "auto" (default) searches both ReaScript and ReaImGui;
            "reascript" or "imgui" restrict to one. ReaScript names are
            CamelCase like `GetMediaItemTrack`. ReaImGui names omit the
            `ImGui_` prefix in the docs (e.g. `Begin`, `Button`).
      max_matches: cap on wildcard match results (default 30).

    Returns:
      Cleanly-formatted entries (one per match) or an "(no match)" line.
    """
    is_pattern = "*" in name or "?" in name
    rx = _glob_to_regex(name) if is_pattern else None

    blocks: list[str] = []
    truncated = False

    # ReaScript
    if kind in ("auto", "reascript"):
        try:
            entries, text = _load_reascript()
        except FileNotFoundError:
            blocks.append(f"--- ERROR: missing {REASCRIPT_HTML} ---")
        else:
            if is_pattern:
                hits = [(n, s, e) for (n, s, e) in entries if rx.match(n)]
                for n, s, e in hits[:max_matches]:
                    body = text[s:e]
                    sig_m = _RS_LUA_SIG.search(body)
                    sig = _strip_tags(sig_m.group(1)) if sig_m else ""
                    blocks.append(f"reascript {n}: {sig}")
                if len(hits) > max_matches:
                    truncated = True
            else:
                exact = [(n, s, e) for (n, s, e) in entries if n.lower() == name.lower()]
                for n, s, e in exact:
                    blocks.append(_format_reascript_entry(n, text[s:e]))

    # ImGui
    if kind in ("auto", "imgui"):
        try:
            im = _load_imgui()
        except FileNotFoundError:
            blocks.append(f"--- ERROR: missing {IMGUI_HTML} ---")
        else:
            names = list(im.keys())
            if is_pattern:
                hits = [n for n in names if rx.match(n)]
                for n in hits[:max_matches]:
                    summary, body = im[n]
                    sig_m = _IM_LUA_ROW.search(body)
                    sig = _strip_tags(sig_m.group(1)) if sig_m else ""
                    blocks.append(f"imgui {summary.strip()}: {sig}")
                if len(hits) > max_matches:
                    truncated = True
            else:
                for n in names:
                    if n.lower() == name.lower():
                        summary, body = im[n]
                        blocks.append(_format_imgui_entry(n, summary, body))

    if not blocks:
        suffix = "" if kind == "auto" else f" (kind={kind})"
        return f"(no match for {name!r}{suffix})"
    if truncated:
        blocks.append(f"--- truncated at {max_matches} matches; narrow the pattern ---")
    return "\n\n".join(blocks)


# ----- lua_test_run ---------------------------------------------------------
# Wraps `lua tests/run.lua [filter]`. The runner emits one `  ok    NAME` or
# `  FAIL  NAME` line per test, then on failure a `=== failures ===` block
# with `-- NAME` headers and Lua tracebacks. We parse that, locate the spec
# file:line at the top of the traceback, and surface a source window.

_SUMMARY = re.compile(r"^(\d+) passed, (\d+) failed", re.MULTILINE)
_FAIL_LINE = re.compile(r"^  FAIL  (.+)$", re.MULTILINE)
_TRACE_FRAME = re.compile(r"(tests/specs/[^:\s]+\.lua):(\d+)")


def _read_window(path: Path, line: int, context: int) -> str:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as e:
        return f"(could not read {path}: {e})"
    n = len(lines)
    s = max(1, line - context)
    e = min(n, line + context)
    width = len(str(e))
    out = []
    for i in range(s, e + 1):
        marker = ">" if i == line else " "
        out.append(f"{marker} {i:>{width}}\t{lines[i - 1]}")
    return "\n".join(out)


def _parse_failures(stdout: str) -> list[dict]:
    """Split the `=== failures ===` block into per-failure dicts."""
    head, _, tail = stdout.partition("=== failures ===")
    if not tail:
        return []
    # Each failure begins with `\n-- NAME\n`; split on that anchor.
    chunks = re.split(r"\n-- (?=\S)", tail)
    failures = []
    # First chunk after the header is empty / whitespace; skip if so.
    for chunk in chunks[1:]:
        # name is first line; rest is err+traceback
        nl = chunk.find("\n")
        if nl < 0:
            continue
        name = chunk[:nl].strip()
        body = chunk[nl + 1 :].strip()
        # Stop at the trailing summary if it leaks in
        body = re.split(r"\n\d+ passed, \d+ failed", body)[0].rstrip()
        failures.append({"name": name, "body": body})
    return failures


@mcp.tool(structured_output=False)
def lua_test_run(
    filter: Optional[str] = None,
    context: int = 0,
    show_passing: bool = False,
    timeout: int = 60,
) -> str:
    """Run the Lua test suite (`lua tests/run.lua`) and return a focused report.

    Default output is failures-only with `path:line` of each failing
    assertion plus the condensed traceback — no source window. Pass
    `context=N` to opt in to ±N lines of source around each failure.

    Args:
      filter: optional literal substring matched against `<spec> :: <test>`.
              Examples: "tm_rebuild_spec" runs only tests in tm_rebuild_spec;
              "absorber" matches any spec or test name containing "absorber".
              The runner uses literal `string.find`, not regex.
      context: lines of source around each failing line (default 0 — omit
               the source window entirely; jump via path:line if needed).
      show_passing: include the names of passing tests (default false).
      timeout: kill the run after this many seconds (default 60).

    Returns:
      Header `N passed, M failed` plus per-failure blocks containing:
        - test name
        - `path:line` of the failing assertion (highest spec frame)
        - source window with the failing line marked `>`
        - the assertion's error message + condensed traceback
    """
    if shutil.which("lua") is None:
        return "--- ERROR: `lua` not on PATH ---"

    cmd = ["lua", "tests/run.lua"]
    if filter:
        cmd.append(filter)

    try:
        proc = subprocess.run(
            cmd,
            cwd=str(PROJECT_ROOT),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return f"--- ERROR: `lua tests/run.lua{(' ' + filter) if filter else ''}` timed out after {timeout}s ---"

    out = proc.stdout
    err = proc.stderr.strip()

    summary_m = _SUMMARY.search(out)
    if not summary_m:
        # Catastrophic — runner crashed before producing summary
        head = (out + "\n" + err).strip()
        return f"--- ERROR: runner produced no summary (exit {proc.returncode}) ---\n{head[:4000]}"

    n_pass = int(summary_m.group(1))
    n_fail = int(summary_m.group(2))

    if filter and n_pass + n_fail == 0:
        return f"(filter {filter!r} matched no tests)"

    sections: list[str] = [f"{n_pass} passed, {n_fail} failed" + (f"  filter={filter!r}" if filter else "")]

    if show_passing:
        passing = [m.group(1) for m in re.finditer(r"^  ok    (.+)$", out, re.MULTILINE)]
        if passing:
            sections.append("passing:\n  " + "\n  ".join(passing))

    if n_fail == 0:
        if err:
            sections.append(f"stderr:\n{err}")
        return "\n\n".join(sections)

    failures = _parse_failures(out)
    if not failures:
        # Names only (parser missed the body)
        names = _FAIL_LINE.findall(out)
        sections.append("failures (names only — could not parse bodies):\n  " + "\n  ".join(names))
        return "\n\n".join(sections)

    for f in failures:
        # Highest spec frame: first occurrence in traceback wins (top of stack
        # is the assertion site in the spec).
        frame = _TRACE_FRAME.search(f["body"])
        block = [f"--- FAIL: {f['name']}"]
        if frame:
            spec_path = PROJECT_ROOT / frame.group(1)
            line_no = int(frame.group(2))
            block.append(f"{frame.group(1)}:{line_no}")
            if context > 0:
                block.append(_read_window(spec_path, line_no, context))
        # Condense: keep the err message and just the spec/support frames in the trace
        body_lines = f["body"].splitlines()
        kept: list[str] = []
        for ln in body_lines:
            if "tests/run.lua" in ln or ln.strip().startswith("[C]:"):
                continue
            kept.append(ln)
        block.append("error:\n" + "\n".join(kept).rstrip())
        sections.append("\n".join(block))

    if err:
        sections.append(f"stderr:\n{err}")

    return "\n\n".join(sections)


# ----- map_query ------------------------------------------------------------
# Structured search over the project's .map semantic outlines. Replaces
# `grep '@fn' map/*.map` and read-the-surrounding-context dance with a typed
# query that returns matches with src file:line and parent context.

MAP_DIR = PROJECT_ROOT / "map"

_MAP_HEADER = re.compile(
    r'^@module\s+(\S+)\s+src=(\S+)\s+loc=(\d+)\s+sha=(\S+)'
)
_DECL = re.compile(
    r'^(?P<indent>\s*)@(?P<kind>fn|api|factory|state|const)\s+'
    r'(?P<head>.+?)\s*@\s*(?P<line>\d+)\s*'
    r'(?P<doc>(?:--|·).*)?$'
)
_ANN = re.compile(
    r'^(?P<indent>\s*)@(?P<kind>map\??:\w+|shape\??|emits|reaper|deps)\s+'
    r'(?P<body>.*)$'
)
_FACTORY_HDR = re.compile(r'^@factory\s+(\w+)')


def _bare_name(kind: str, head: str) -> str:
    if kind in ("fn", "factory"):
        m = re.match(r"^(\w+)\(", head)
        return m.group(1) if m else head
    if kind == "api":
        m = re.match(r"^[\w]+[:.](\w+)\(", head)
        return m.group(1) if m else head
    if kind in ("state", "const"):
        m = re.match(r"^(\w+)", head)
        return m.group(1) if m else head
    return head


def _normalize_kind(k: str) -> str:
    """Normalize user-facing kind names. `map:contract` → `contract`,
    `signal` → `emits`, etc."""
    k = k.lower()
    if k.startswith("map:"):
        k = k[4:]
    if k.startswith("map?:"):
        k = k[5:]
    aliases = {
        "signal": "emits",
        "signals": "emits",
        "invariants": "invariant",
        "contracts": "contract",
        "shapes": "shape",
        "fns": "fn",
        "functions": "fn",
        "apis": "api",
        "factories": "factory",
        "states": "state",
        "consts": "const",
        "constants": "const",
    }
    return aliases.get(k, k)


def _entry_kind(raw_kind: str) -> str:
    """Strip @map:/@map?: prefix and trailing `?` from a parsed kind."""
    k = raw_kind
    if k.startswith("map?:"):
        k = k[5:]
    elif k.startswith("map:"):
        k = k[4:]
    return k.rstrip("?")


@mcp.tool(structured_output=False)
def map_query(
    name: Optional[str] = None,
    kind: Optional[str] = None,
    module: Optional[str] = None,
    max_results: int = 60,
) -> str:
    """Structured query over the project's .map semantic outlines.

    Replaces `grep '@fn' map/*.map` and the follow-up read-the-source dance.
    Results carry the originating .lua file:line so you can jump straight
    to the declaration with Read offset/limit.

    Args:
      name: name pattern. Supports `*` and `?` glob wildcards;
            case-insensitive. Matches bare symbol names for structural
            entries (`@fn`, `@api`, `@factory`, `@state`, `@const`) and
            full body text for annotations (`@map:invariant`,
            `@map:contract`, `@shape`, `@emits`, `@reaper`). Omit to
            return everything matching the other filters.
      kind: filter by entry kind. Accepted (case-insensitive, plurals
            ok): fn, api, factory, state, const, invariant, contract,
            shape, emits/signal, reaper, deps. Omit for any.
      module: restrict to a module by stem (e.g. `trackerManager`) or
              glob (e.g. `tm_*`, `*Manager`). Matches the .map filename
              (without extension).
      max_results: cap (default 60).

    Returns:
      Lines of `<source>.lua:<line>  @kind <head>  [in factory X]` for
      structural entries, and `<source>.lua  @map:invariant  <body>`
      for annotations (annotations attach to a parent that itself has
      a line number — query for the parent if you need to jump).
    """
    if not MAP_DIR.exists():
        return f"--- ERROR: {MAP_DIR} not found ---"

    name_rx: Optional[re.Pattern] = None
    if name:
        # Glob to regex; substring match (no anchoring) so partial works.
        if "*" in name or "?" in name:
            parts = []
            for ch in name:
                if ch == "*": parts.append(".*")
                elif ch == "?": parts.append(".")
                else: parts.append(re.escape(ch))
            name_rx = re.compile("^" + "".join(parts) + "$", re.IGNORECASE)
        else:
            name_rx = re.compile(re.escape(name), re.IGNORECASE)

    kind_filter = _normalize_kind(kind) if kind else None

    module_files: list[Path]
    if module:
        if "*" in module or "?" in module:
            module_files = sorted(MAP_DIR.glob(f"{module}.map"))
        else:
            mp = MAP_DIR / f"{module}.map"
            module_files = [mp] if mp.exists() else []
    else:
        module_files = sorted(MAP_DIR.glob("*.map"))

    if not module_files:
        return f"(no .map files matched module={module!r})"

    results: list[str] = []
    truncated = False

    for mp in module_files:
        text = mp.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()
        # Header: src=...
        src = mp.stem + ".lua"
        if lines:
            h = _MAP_HEADER.match(lines[0])
            if h:
                src = h.group(2)

        current_factory: Optional[str] = None

        for raw in lines:
            if not raw.strip():
                continue
            # Track factory context (top-level `@factory` line)
            mf = _FACTORY_HDR.match(raw)
            if mf:
                current_factory = mf.group(1)

            # Try structural decl first
            md = _DECL.match(raw)
            if md:
                if len(results) >= max_results:
                    truncated = True
                    break
                k = md.group("kind")
                head = md.group("head").strip()
                src_line = int(md.group("line"))
                doc = (md.group("doc") or "").strip()

                if kind_filter and kind_filter != k:
                    continue
                if name_rx:
                    bare = _bare_name(k, head)
                    if not name_rx.search(bare):
                        continue

                ctx = ""
                # @fn at module level (indent==0 in map) has no factory ctx;
                # @api with `:` lives inside a factory; @factory itself is its own context.
                if k != "factory" and current_factory and md.group("indent"):
                    ctx = f"  [in {current_factory}]"
                tail = f"  {doc}" if doc else ""
                results.append(f"{src}:{src_line}  @{k} {head}{ctx}{tail}")
                continue

            # Annotation
            ma = _ANN.match(raw)
            if ma:
                raw_kind = ma.group("kind")
                ek = _entry_kind(raw_kind)
                body = ma.group("body").strip()

                # `deps` is the @deps line; treat as kind=deps. Skip module/api/etc that
                # we already matched via _DECL.
                if kind_filter and kind_filter != ek:
                    continue
                if name_rx and not name_rx.search(body):
                    # For emits, the body starts with the signal name; for shape, the body
                    # starts with the shape name. The substring match above handles those.
                    continue
                if not kind_filter and not name_rx:
                    # Don't dump every annotation when no filter given.
                    continue

                if len(results) >= max_results:
                    truncated = True
                    break
                ctx = f"  [in {current_factory}]" if current_factory and ek not in ("invariant",) else ""
                results.append(f"{src}  @{raw_kind}  {body}{ctx}")
                continue

        if truncated:
            break

    if not results:
        bits = []
        if name: bits.append(f"name={name!r}")
        if kind: bits.append(f"kind={kind!r}")
        if module: bits.append(f"module={module!r}")
        q = ", ".join(bits) if bits else "<no filters>"
        return f"(no matches for {q})"

    if truncated:
        results.append(f"--- truncated at {max_results}; narrow the query ---")
    return "\n".join(results)


if __name__ == "__main__":
    mcp.run()
