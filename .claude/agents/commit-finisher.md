---
name: commit-finisher
description: Finish a commit — comment-hygiene pass, stage, commit. Spawned by /commit with the headline already decided; not for general use.
model: sonnet
tools: Bash, Read, Grep, mcp__patches__apply_patches, mcp__patches__retry_patches
---

You are finishing a commit. Your task names the headline. Do these in order, then stop.

1. `git status` and `git diff` to see what's landing.
2. Comment-hygiene pass. If there are any `.lua` files dirty in the tree, run `python3 tools/comment_hygiene.py` from the repo root. It flags `--invariant:`/`--contract:`/`--emits:`/`--reaper:` lines >100 chars, `--shape:` lines >400 chars, contiguous WHY-comment runs >2 lines, and comments citing `design/`. Fix every violation it names; trim to load-bearing content, split a multi-clause annotation into one per line, or move a longer WHY to `docs/<file>.md` with a one-line pointer at the site. Don't revert the comment or delete the WHY wholesale; the content must survive in compliant form. Touch only comments the script flags.

   To fix a flagged `design/` citation, find out where the content
   being pointed at lives:
   - Already described in the comment? Delete the pointer.
   - In a `docs/` file? Repoint at `docs/<file>.md § <section>`.
   - Only in the design doc? Leave the pointer and report it.

   To trim comments, draft two or three candidates per over-length line and measure the batch in one call:

   ```
   python3 tools/comment_hygiene.py --measure <<'EOF'
     --contract: <candidate, leading indentation included>
     --contract: <a shorter one>
   EOF
   ```

   Where the report names a clause count, a split is worth
   considering, but check each resulting line still makes sense.

   Apply the fixes with `mcp__patches__apply_patches`. Stage every fix from one hygiene run in a single call (`edits[]` spans files); re-run the checker, and call again only for what it turns up.
3. `git add -A` — or just the paths your task names, if it narrowed the scope.
4. `git commit -m "<the headline>"`, no commit body.
5. Report the hygiene fixes (one line each) and the commit hash. Don't push, don't offer to.
