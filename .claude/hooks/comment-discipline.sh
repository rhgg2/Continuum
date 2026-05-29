#!/bin/bash
# PostToolUse hook (Edit | Write | mcp__patches__apply_patches):
# surface newly-added full-line Lua comments back to Claude with a
# "carry a WHY or cut it" nudge.
#
# Scope: .lua files only. Only whole-line comments (first non-space
# chars are --); trailing inline comments are left alone — they can't
# be told from -- inside a string without a real lexer. Section banners
# (----- Name, ----------- PUBLIC), bare-dash dividers, and --KIND:
# annotations are exempt: the doc conventions require them, they are
# not WHAT-restating cruft.
#
# All three tool shapes normalize to a stream of {path, added, old}:
#   Edit   -> {file_path, new_string, old_string}
#   Write  -> {file_path, content}            (old empty)
#   patches-> edits[].{path,new,old} + creates[].{path,content}
# A whole jq program does the normalize + filter + report, so there is
# no per-item bash loop and no base64 round-trip.
#
# Mechanism: emits additionalContext, injected into Claude's next turn.
# Never blocks the edit — purely advisory.

set -u

jq '
  def flag:
    test("^\\s*--")
    and (test("^\\s*-----") | not)
    and (test("^\\s*--+\\s*$") | not)
    and (test("^\\s*--\\??(invariant|contract|shape|emits|reaper):") | not);

  def comments: split("\n") | map(select(flag) | sub("^\\s+";"")) | unique;

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

  if (.tool_input.dry_run // false) then empty
  else
    items
    | map(select(.path | endswith(".lua")))
    | map({ path, new: ((.added | comments) - (.old | comments)) })
    | map(select(.new | length > 0))
    | if length == 0 then empty
      else
        ( "Comment-discipline check — these full-line comments were added:\n\n"
          + ( map(.path + ":\n" + (.new | join("\n"))) | join("\n\n") )
          + "\n\nFor each: does it carry force the code cannot — a hidden constraint, a non-obvious invariant, a bug-specific workaround? Keep those. Cut any that only restate WHAT the code already says, and edit the file to remove them."
        ) as $msg
        | { hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: $msg } }
      end
  end
'
