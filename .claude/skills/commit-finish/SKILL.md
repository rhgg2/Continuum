---
name: commit-finish
description: The mechanical half of a commit — a comment-hygiene pass, then the commit. Invoked by /commit; not for general use.
user-invocable: false
context: fork
agent: commit-finisher
allowed-tools: Bash(bash ${CLAUDE_PROJECT_DIR}/.claude/context/gather.sh *)
---

!`bash ${CLAUDE_PROJECT_DIR}/.claude/context/gather.sh tree-state hygiene`

You are finishing a commit. `$ARGUMENTS` names the headline, and may
name a narrower set of paths to stage. Do these in order, then stop.

## 1. Comment hygiene

The report above names every violation you have to fix. It flags:

- `--invariant:`/`--contract:`/`--emits:`/`--reaper:` lines >100 chars;
- `--shape:` lines >400 chars; 
- any other comment blocks >2 lines (ignoring blank lines);
- comments citing `design/`. 

For a flagged `design/` citation, find out where the content being
pointed at lives:

- Already described in the comment? Delete the pointer.
- In a `docs/` file? Repoint at `docs/<file>.md § <section>`.
- Only in the design doc? Leave the pointer and report it.

For length violations: trim to load-bearing content, split a
multi-clause annotation into one per line, or move a longer WHY to
`docs/<file>.md` with a one-line pointer at the site. Don't revert the
comment or delete the WHY wholesale; the content must survive in
compliant form. 

To trim comments, draft two or three candidates per over-length line
and measure the batch in one call:

   ```
   python3 tools/comment_hygiene.py --measure <<'EOF'
     --contract: <candidate, leading indentation included>
     --contract: <a shorter one>
   EOF
   ```

Touch only comments the script flags. Note that these may be
pre-existing comments that got pulled in an over-long comment block;
fix these all the same.

Apply the fixes with `mcp__patches__apply_patches`. Stage every fix
from one hygiene run in a single call; re-run the checker, and call
again only for what it turns up.

## 2. Commit

Run `git add -A && git commit -m "<the headline>"`, no commit body. If
your task named a narrower scope, commit just the named files.

## 3. Report

Wrap up and report the hygiene fixes (one line each) and the commit
hash. Don't push, don't offer to.
