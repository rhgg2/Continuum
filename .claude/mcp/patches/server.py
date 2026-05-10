#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2"]
# ///
"""Readium apply_patches MCP server.

Atomic batch of search/replace edits, file creates, and deletes across
many paths. Either every operation validates and is flushed, or nothing
is written.

**Project policy:** restricted to `tests/**` and `docs/**` only. Any
other path (top-level Lua, tools/, CLAUDE.md, etc.) must use the
built-in Edit tool so each file gets a per-file diff approval prompt.
The check happens before staging — off-policy paths abort the whole
batch with no filesystem touch.

Sister servers: readium_docs, readium_tests.
"""

from __future__ import annotations

import difflib
import os
import time
from pathlib import Path
from typing import Optional

from mcp.server.fastmcp import FastMCP

PROJECT_ROOT = Path(__file__).resolve().parents[3]

mcp = FastMCP("readium_patches")

PERF_LOG = "/tmp/apply_patches_perf.log"
PREVIEW_PATH = "/tmp/apply_patches_preview.diff"
MAX_BYTES_PER_FILE = 4_000_000

# Project policy: only these top-level dirs may be touched via apply_patches.
ALLOWED_PREFIXES = ("tests", "docs")

_ANSI_BOLD = "\033[1m"
_ANSI_RED = "\033[31m"
_ANSI_GREEN = "\033[32m"
_ANSI_CYAN = "\033[36m"
_ANSI_RESET = "\033[0m"


def _perf_log(line: str) -> None:
    try:
        with open(PERF_LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def _ansi_unified_diff(old: str, new: str, path: str) -> str:
    lines = list(
        difflib.unified_diff(
            old.splitlines(keepends=False),
            new.splitlines(keepends=False),
            fromfile=f"a/{path}",
            tofile=f"b/{path}",
            n=3,
            lineterm="",
        )
    )
    if not lines:
        return ""
    out: list[str] = []
    for line in lines:
        if line.startswith("--- ") or line.startswith("+++ "):
            out.append(f"{_ANSI_BOLD}{line}{_ANSI_RESET}")
        elif line.startswith("@@"):
            out.append(f"{_ANSI_CYAN}{line}{_ANSI_RESET}")
        elif line.startswith("+"):
            out.append(f"{_ANSI_GREEN}{line}{_ANSI_RESET}")
        elif line.startswith("-"):
            out.append(f"{_ANSI_RED}{line}{_ANSI_RESET}")
        else:
            out.append(line)
    return "\n".join(out) + "\n"


def _resolve(raw: str, base: Path) -> str:
    return raw if os.path.isabs(raw) else str(base / raw)


def _is_allowed(abs_path: str) -> Optional[str]:
    """Return None if `abs_path` is under tests/** or docs/** of PROJECT_ROOT.
    Otherwise return a short reason string for the abort message."""
    try:
        rel = Path(abs_path).resolve().relative_to(PROJECT_ROOT)
    except ValueError:
        return "outside project root"
    parts = rel.parts
    if not parts:
        return "is the project root"
    if parts[0] not in ALLOWED_PREFIXES:
        return f"top-level dir {parts[0]!r} not in {ALLOWED_PREFIXES}"
    return None


def _read(path: str) -> tuple[Optional[str], Optional[str]]:
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return None, "file not found"
    except PermissionError:
        return None, "permission denied"
    if not os.path.isfile(path):
        return None, "not a regular file"
    if st.st_size > MAX_BYTES_PER_FILE:
        return None, f"file too large ({st.st_size} bytes)"
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        return None, f"read error: {e}"
    try:
        return data.decode("utf-8"), None
    except UnicodeDecodeError:
        return None, "not utf-8 (binary?)"


@mcp.tool(structured_output=False)
def apply_patches(
    edits: Optional[list[dict]] = None,
    creates: Optional[list[dict]] = None,
    deletes: Optional[list[str]] = None,
    dry_run: bool = False,
    cwd: Optional[str] = None,
) -> str:
    """Apply a batch of edits, file creations, and deletions atomically.

    **Restricted to `tests/**` and `docs/**`.** Any path outside those
    top-level dirs aborts the whole batch — use the built-in Edit tool
    for production code so each file gets a per-file diff approval.

    Same search/replace semantics as the built-in Edit tool: each edit's
    `old` must appear in the (current, post-prior-edits) file content
    exactly once unless `replace_all` is true. All operations are validated
    and staged in memory first; if anything fails the call ABORTs and the
    filesystem is untouched.

    Args:
      edits: list of {path: str, old: str, new: str, replace_all?: bool}.
             Multiple edits to the same path are applied in given order.
      creates: list of {path: str, content: str, overwrite?: bool}. Errors
               if path exists unless overwrite=true. Parent dirs auto-mkdir.
      deletes: list of paths to delete. Errors if path missing.
      dry_run: if true, validate everything and report planned changes
               without writing.
      cwd: working directory for relative paths (default: process CWD).

    Returns:
      Multi-line report. On success: per-file summary of operations.
      On failure: `ABORT` header followed by every validation error
      collected (no partial writes).
    """
    edits = edits or []
    creates = creates or []
    deletes = deletes or []
    if not (edits or creates or deletes):
        return "(no operations requested)"

    t0 = time.perf_counter()
    perf: dict[str, float] = {}

    base = Path(cwd) if cwd else Path.cwd()
    errors: list[str] = []

    edit_paths = {_resolve(e["path"], base) for e in edits if isinstance(e, dict) and "path" in e}
    create_paths = {_resolve(c["path"], base) for c in creates if isinstance(c, dict) and "path" in c}
    delete_paths = {_resolve(p, base) for p in deletes if isinstance(p, str)}

    # Project policy: tests/** and docs/** only. Reject early so we don't
    # waste time staging edits we'll abort on.
    for p in edit_paths | create_paths | delete_paths:
        reason = _is_allowed(p)
        if reason:
            errors.append(f"policy: {p}: {reason} (apply_patches restricted to tests/** and docs/**)")

    for p in edit_paths & create_paths:
        errors.append(f"collision: {p} appears in both edits and creates")
    for p in edit_paths & delete_paths:
        errors.append(f"collision: {p} appears in both edits and deletes")
    for p in create_paths & delete_paths:
        errors.append(f"collision: {p} appears in both creates and deletes")

    # If policy or collision check failed, bail before any staging work —
    # there's no point reading file contents we'll never write.
    if errors:
        return "ABORT — filesystem untouched\n" + "\n".join(f"  • {e}" for e in errors)

    by_path: dict[str, list[dict]] = {}
    for i, e in enumerate(edits):
        if not isinstance(e, dict) or not all(k in e for k in ("path", "old", "new")):
            errors.append(f"edits[{i}]: missing path/old/new")
            continue
        by_path.setdefault(_resolve(e["path"], base), []).append(e)

    staged_edits: dict[str, str] = {}
    edit_originals: dict[str, str] = {}
    edit_summaries: list[str] = []
    _t = time.perf_counter()
    for path, group in by_path.items():
        content, err = _read(path)
        if err:
            errors.append(f"{path}: {err}")
            continue
        edit_originals[path] = content
        cur = content
        ops_done: list[str] = []
        for j, e in enumerate(group):
            old = e["old"]
            new = e["new"]
            replace_all = bool(e.get("replace_all", False))
            if old == new:
                errors.append(f"{path}: edit #{j+1} old == new (no-op)")
                continue
            if replace_all:
                if old not in cur:
                    errors.append(f"{path}: edit #{j+1} old not found")
                    continue
                count = cur.count(old)
                cur = cur.replace(old, new)
                ops_done.append(f"replaced {count}× edit#{j+1}")
            else:
                count = cur.count(old)
                if count == 0:
                    errors.append(f"{path}: edit #{j+1} old not found")
                    continue
                if count > 1:
                    errors.append(f"{path}: edit #{j+1} old not unique ({count} occurrences) — use replace_all or expand context")
                    continue
                cur = cur.replace(old, new, 1)
                ops_done.append(f"edit#{j+1}")
        staged_edits[path] = cur
        if ops_done:
            edit_summaries.append(f"  {path}: {', '.join(ops_done)}")

    perf["stage_edits"] = time.perf_counter() - _t

    staged_creates: dict[str, str] = {}
    create_summaries: list[str] = []
    for i, c in enumerate(creates):
        if not isinstance(c, dict) or "path" not in c or "content" not in c:
            errors.append(f"creates[{i}]: missing path/content")
            continue
        path = _resolve(c["path"], base)
        overwrite = bool(c.get("overwrite", False))
        if os.path.exists(path) and not overwrite:
            errors.append(f"{path}: already exists (set overwrite=true to replace)")
            continue
        staged_creates[path] = c["content"]
        create_summaries.append(f"  {path}: create ({len(c['content'])} bytes)")

    valid_deletes: list[str] = []
    delete_originals: dict[str, str] = {}
    delete_summaries: list[str] = []
    for p in deletes:
        if not isinstance(p, str):
            errors.append(f"deletes: non-string entry {p!r}")
            continue
        path = _resolve(p, base)
        if not os.path.exists(path):
            errors.append(f"{path}: cannot delete, does not exist")
            continue
        if not os.path.isfile(path):
            errors.append(f"{path}: cannot delete, not a regular file")
            continue
        valid_deletes.append(path)
        body, _err = _read(path)
        delete_originals[path] = body or ""
        delete_summaries.append(f"  {path}: delete")

    if errors:
        return "ABORT — filesystem untouched\n" + "\n".join(f"  • {e}" for e in errors)

    summary_lines: list[str] = []
    if edit_summaries:
        summary_lines.append(f"edits ({len(by_path)} file(s)):")
        summary_lines.extend(edit_summaries)
    if create_summaries:
        summary_lines.append(f"creates ({len(staged_creates)}):")
        summary_lines.extend(create_summaries)
    if delete_summaries:
        summary_lines.append(f"deletes ({len(valid_deletes)}):")
        summary_lines.extend(delete_summaries)
    summary = "\n".join(summary_lines) if summary_lines else "(no-op)"

    if dry_run:
        _t = time.perf_counter()
        chunks: list[str] = []
        n_hunks = 0
        for path, new_content in staged_edits.items():
            d = _ansi_unified_diff(edit_originals[path], new_content, path)
            if d:
                chunks.append(d)
                n_hunks += d.count("@@ -")
        for path, content in staged_creates.items():
            d = _ansi_unified_diff("", content, path)
            if d:
                chunks.append(d)
                n_hunks += d.count("@@ -")
        for path in valid_deletes:
            d = _ansi_unified_diff(delete_originals.get(path, ""), "", path)
            if d:
                chunks.append(d)
                n_hunks += d.count("@@ -")

        n_files = len(staged_edits) + len(staged_creates) + len(valid_deletes)
        header = (
            f"{_ANSI_BOLD}# apply_patches dry-run preview — "
            f"{n_files} file(s){_ANSI_RESET}\n\n"
        )
        try:
            with open(PREVIEW_PATH, "w", encoding="utf-8") as f:
                f.write(header + "".join(chunks) if chunks else header + "(no textual changes)\n")
        except OSError as e:
            return f"DRY RUN — would apply:\n{summary}\n(preview write failed: {e})"

        perf["diff"] = time.perf_counter() - _t
        perf["total"] = time.perf_counter() - t0
        _perf_log(
            f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] dry_run "
            f"edits={len(edits)} files={n_files} hunks={n_hunks} "
            f"stage_edits={perf['stage_edits']:.3f}s "
            f"diff={perf['diff']:.3f}s "
            f"total={perf['total']:.3f}s"
        )

        return (
            f"DRY RUN — preview: {PREVIEW_PATH} "
            f"({n_files} file(s), ~{n_hunks} hunk(s)) — review with "
            f"`cat {PREVIEW_PATH}` or `less -R {PREVIEW_PATH}`\n{summary}"
        )

    _t = time.perf_counter()
    written: list[str] = []
    try:
        for path, content in staged_edits.items():
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
            written.append(path)
        for path, content in staged_creates.items():
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
            written.append(path)
        for path in valid_deletes:
            os.remove(path)
    except OSError as e:
        return (
            f"PARTIAL FAILURE during flush: {e}\n"
            f"wrote {len(written)} file(s) before failure:\n"
            + "\n".join(f"  • {p}" for p in written)
            + "\nfilesystem is in an intermediate state — inspect manually."
        )

    perf["flush"] = time.perf_counter() - _t
    perf["total"] = time.perf_counter() - t0
    _perf_log(
        f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] real "
        f"edits={len(edits)} files={len(staged_edits) + len(staged_creates) + len(valid_deletes)} "
        f"stage_edits={perf['stage_edits']:.3f}s "
        f"flush={perf['flush']:.3f}s "
        f"total={perf['total']:.3f}s"
    )

    return f"applied:\n{summary}"


if __name__ == "__main__":
    mcp.run()
