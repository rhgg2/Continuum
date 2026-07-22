---
description: Write the commit headline here, then a subagent runs hygiene + add + commit mechanically.
---

One pass. No iterative refinement.

1. `git status --porcelain`. Empty → clean tree; say so and stop. Don't spawn.
2. Decide the headline yourself — you have the change's intent from this conversation, a cold subagent wouldn't. `<scope>: <headline>`, imperative, ≤70 chars, scoped to the affected area (eg `tm: fix off-by-one in selection rect`). Glance at `git diff --stat` if you need to confirm scope; don't read the full diff.

Steps 3–5 decide *what* bookkeeping this commit carries — the judgment is yours, and a cold subagent can't make it (it never touched the map tools, can't see the session's decisions). Step 6 applies it: you assemble one manifest and `tools/bookkeep.py` does the mechanical part — JSON escaping, the decision-log wrap, the Landed move + prune, the Now swap. Author here; apply there.

3. Map-tooling satisfaction survey — the `feedback` key. Rate the tooling **this session**, honestly; it is a defect log, not a compliment. If you bypassed the maps entirely, say so and say why.

   - `score` — 1-5, how helpful the map tooling was this session. Rate the tooling, not the session's outcome. Use `null` when the session never exercised it (a config or docs task with no Lua in it) — a neutral 3 would be a lie that poisons the average.
   - `used` — array of what you actually reached for: `"map_query"`, `"map"` (read a `.map` directly), `"grep"` / `"read"` (you went around the map tooling), `[]` (never needed it).
   - `comment` — optional, and the point of the exercise. What would have made the tooling more useful *on this task*: a query you couldn't express, an edge the index missed, a lookup that took three calls and should have taken one. Omit rather than pad; a bare score is a fine entry when nothing stood out.
4. Decision log — the `decision` key. If the change embodies a non-trivial design decision (a chosen trade-off, a rejected alternative, a new convention), write the one/two-line entry as plain prose; the script dates it, wraps it, and prepends it to `docs/decisions.md`. Most commits don't — omit the key.
5. Landing bookkeeping — the `land` key. If `plan/CURRENT` exists and this commit completes the live plan's Now entry (wholly, or its final piece), include `land: {headline, ref, now}`: the script prepends `- <date> <headline> (<ref>)` to Landed, prunes it below ~4, and replaces the Now body with your `now` note. The design-doc revision is **not** the script's job — if the landing settled something design-relevant, revise the design doc by hand in this same pass (dated note, WHY only; don't write "Landed 2026/07/10"). Commits unrelated to the plan: omit the key.
6. Apply the bookkeeping. Assemble the manifest from whichever of 3-5 produced a key (all keys optional; `date` defaults to today), write it to your scratchpad, and run `python3 tools/bookkeep.py <path>`. It writes the files directly — no review gate, so eyeball them in the subagent's `git diff`. Skip this step when none of 3-5 fired.

   ```json
   {"date":"2026-07-22",
    "feedback":{"score":3,"used":["map_query","map"],"comment":"usedby missed trackerPage's call — runtime receiver, not in the alias table; had to grep"},
    "decision":"one or two lines of prose; the script formats it",
    "land":{"headline":"tm: …","ref":"§ 3","now":"(empty — … ; run /plan-next to promote the next commit)"}}
   ```
7. Spawn one subagent — Agent tool, `subagent_type: general-purpose`, `model: sonnet` — and hand it the headline. It owns everything else and does **not** spawn further subagents. Prompt it with:

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

8. When it returns, eyeball its summary — don't re-audit.
