#!/bin/bash
# PostToolUse hook (Edit | Write | mcp__patches__apply_patches):
# surface newly-added Lua comments and length-cap concerns back to Claude.
# See docs/CONVENTIONS.md § Length discipline.
#
# Two flags raised, per-file, additionalContext only (never blocks):
#   1. new --KIND: annotations ≥100 chars (non-shape) — "split or relocate"
#   2. new contiguous WHY-comment runs ≥3 lines       — "over 2-line cap"
#
# Within-cap comments are intentionally NOT surfaced — flagging every new
# comment makes Claude loop on refining wording instead of moving on.
#
# Scope: .lua files only. Only whole-line comments (first non-space chars
# are --); trailing inline comments are left alone — they can't be told from
# -- inside a string without a real lexer. Section banners (----- Name,
# ----------- PUBLIC), bare-dash dividers, and --KIND: annotations are not
# counted as WHY comments. --shape: is exempt from (1) — shapes are allowed
# the length needed to state the shape.
#
# All three tool shapes normalize to a stream of {path, added, old}:
#   Edit   -> {file_path, new_string, old_string}
#   Write  -> {file_path, content}            (old empty)
#   patches-> edits[].{path,new,old} + creates[].{path,content}

set -u

jq '
  def is_why_comment:
    test("^\\s*--")
    and (test("^\\s*-----") | not)
    and (test("^\\s*--+\\s*$") | not)
    and (test("^\\s*--\\??(invariant|contract|shape|emits|reaper):") | not);

  def is_long_annot:
    test("^\\s*--\\??(invariant|contract|emits|reaper):")
    and (length >= 100);

  def long_annots:
    split("\n") | map(select(is_long_annot) | sub("^\\s+";"")) | unique;

  def why_runs:
    split("\n")
    | reduce .[] as $ln (
        {done: [], cur: []};
        if ($ln | is_why_comment) then
          {done: .done, cur: (.cur + [$ln])}
        elif (.cur | length) >= 3 then
          {done: (.done + [.cur | join("\n")]), cur: []}
        else
          {done: .done, cur: []}
        end)
    | (if (.cur | length) >= 3 then .done + [.cur | join("\n")] else .done end)
    | unique;

  def items:
    if (.tool_input.file_path? // null) != null then
      [ { path: .tool_input.file_path,
          added: ((if .tool_name == "Write" then .tool_input.content
                   else .tool_input.new_string end) // ""),
          old: (.tool_input.old_string // "") } ]
    else
      ((.tool_input.edits   // []) | map({ path, added: .new,     old: .old }))
      + ((.tool_input.creates // []) | map({ path, added: .content, old: "" }))
    end;

  def render:
    .path + ":"
    + (if .longAnnots | length > 0
       then "\n  annotations ≥ 100 chars (split, or move model concern to docs/<file>.md):\n    "
            + (.longAnnots | join("\n    "))
       else "" end)
    + (if .longRuns | length > 0
       then "\n  comment runs over the 2-line cap (relocate to docs/<file>.md with a pointer):\n    "
            + (.longRuns | map(gsub("\n"; "\n    ")) | join("\n    ---\n    "))
       else "" end);

  if (.tool_input.dry_run // false) then empty
  else
    items
    | map(select(.path | endswith(".lua")))
    | map({
        path,
        longAnnots: ((.added | long_annots) - (.old | long_annots)),
        longRuns:   ((.added | why_runs)    - (.old | why_runs))
      })
    | map(select((.longAnnots + .longRuns) | length > 0))
    | if length == 0 then empty
      else
        ( "Comment-discipline check (docs/CONVENTIONS.md § Length discipline).\n"
          + "Hard rules: --invariant:/--contract:/--emits:/--reaper: cap at 100 chars (--shape: exempt). Inline WHY comments cap at 2 lines; longer justifications move to docs/<file>.md and leave a one-line pointer at the site.\n\n"
          + ( map(render) | join("\n\n") )
        ) as $msg
        | { hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: $msg } }
      end
  end
'
