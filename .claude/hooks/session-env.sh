#!/bin/sh
# SessionStart hook: rebuild this session's scratchpad path and inject it as
# context, because a replacement system prompt (see ../system-prompt.md) is
# static and can't carry per-session values. The layout —
# /private/tmp/claude-$UID/<cwd with / as ->/<session-id>/scratchpad — is
# undocumented; if scratchpad writes start hitting permission prompts, check
# it hasn't moved.
input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id')
cwd=$(printf '%s' "$input" | jq -r '.cwd')
scratchpad="/private/tmp/claude-$(id -u)/$(printf '%s' "$cwd" | tr '/' '-')/${session_id}/scratchpad"
jq -n --arg ctx "Scratchpad directory for this session — use it for all temporary files instead of /tmp: $scratchpad" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
