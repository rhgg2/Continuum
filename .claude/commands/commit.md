---
description: Write the commit headline here, then a subagent runs hygiene + add + commit mechanically.
---

One pass. No iterative refinement.

1. `git status --porcelain`. Empty → clean tree; say so and stop. Don't spawn.
2. Decide the headline yourself — you have the change's intent from this conversation, a cold subagent wouldn't. `<scope>: <headline>`, imperative, ≤70 chars, scoped to the affected area (eg `tm: fix off-by-one in selection rect`). Glance at `git diff --stat` if you need to confirm scope; don't read the full diff.
3. Map-tooling satisfaction survey. Append one JSON object, one line, to `map/feedback.jsonl` — **you** write it, not the subagent; the subagent never touched the map tools and would invent an answer. You can batch this and the next item via an apply_patches call. Fields:

   - `date` — today, `YYYY-MM-DD`.
   - `score` — 1-5, how helpful the map tooling was **this session**. Rate the tooling, not the session's outcome. Use `null` when the session never exercised it (a config or docs task with no Lua in it) — a neutral 3 would be a lie that poisons the average.
   - `used` — array of what you actually reached for: `"map_query"`, `"map"` (read a `.map` directly), `"grep"` / `"read"` (you went around the map tooling), `[]` (never needed it).
   - `comment` — optional, and the point of the exercise. What would have made the tooling more useful *on this task*: a query you couldn't express, an edge the index missed, a lookup that took three calls and should have taken one. Omit rather than pad. A bare score with no comment is a fine entry when nothing stood out.

   Be honest and specific — this is a defect log for the tooling, not a compliment. If you bypassed the maps entirely, say so and say why.

   ```json
   {"date":"2026-07-14","score":3,"used":["map_query","map"],"comment":"usedby missed trackerPage's call — runtime receiver, not in the alias table; had to grep"}
   ```
4. Decision log: if the change embodies a non-trivial design decision — a chosen trade-off, a rejected alternative, a new convention — append a dated one/two-line entry at the top of `docs/decisions.md` now, so it rides the same commit. Most commits don't; skip silently.
5. Landing bookkeeping: if `plan/CURRENT` exists and this commit completes the live plan's Now entry (wholly, or its final piece), update `plan/<name>` now so it rides the commit — move the entry to Landed as one line (`- <date> <headline> (§ ref)`), prune Landed below ~4, clear Now, and if the landing settled something design-relevant add the dated note to the design doc. Commits unrelated to the plan: skip silently.
6. Spawn one subagent — Agent tool, `subagent_type: general-purpose`, `model: sonnet` — and hand it the headline. It owns everything else and does **not** spawn further subagents. Prompt it with:

> You are finishing a commit. Do these in order, then stop — do not spawn any subagent:
> 1. `git status` and `git diff` to see what's landing.
> 2. Comment-hygiene pass (diff mode): run `tools/comment_hygiene.py` from the repo root. It flags `--invariant:`/`--contract:`/`--emits:`/`--reaper:` lines >100 chars, `--shape:` lines >400 chars, and contiguous WHY-comment runs >2 lines. Fix every violation it names — trim to load-bearing content, or move a longer WHY to `docs/<file>.md` with a one-line pointer at the site. NEVER revert the comment to a prior state or delete the WHY wholesale; the content must survive in compliant form. Touch only comments the script flags. Re-run until clean.
>
>    Apply the fixes with `mcp__patches__apply_patches` — the user is at the keyboard and reviews each hunk. Run `ToolSearch select:mcp__patches__apply_patches` first to load the schema; never call it from memory. Stage every fix from one hygiene run in a single call (`edits[]` spans files); call again only for what the next re-run turns up. A lone one-hunk fix may use the built-in `Edit`.
> 3. `git add -A`.
> 4. `git commit -m "<HEADLINE>"` — exactly the headline given, no body, no `Co-Authored-By`, no Claude tagline.
> 5. Report the hygiene fixes (one line each) and the commit hash. Don't push, don't offer to.
>
>    If the user sent you instructions directly while you were working (a message mid-run, or hunk `feedback:` returned by `apply_patches`), say so explicitly in the report (call them "the user", not "you"): quote or paraphrase what they asked and what you did about it. The parent agent cannot see your conversation and will otherwise read the change as yours.

7. When it returns, eyeball its summary — don't re-audit.
