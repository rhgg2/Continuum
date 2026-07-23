# interval-dirt v2 — plan

> source: `design/interval-dirt-v2.md` — synthesis (`/plan-next`) compiles
> from there; don't design here.

## Phases

1. **Raw record set** (§ 1) — rawIndex covers every event type; the five
   read-sites converted; `ccsRawBetween` retired — landed 2026-07-21
2. **Ungated passes** (§ 2) — `computeFxWindows` and `realiseParked` bounds
   both cached + dirt-gated — landed 2026-07-22
3. **rebuildPbs skeleton** (§ 3) — span-bounded gather/clone/project;
   kept-range carry extended to the whole out-of-scope remainder — landed 2026-07-23
4. **Scan-to-filter passes** (§ 4) — rebuildPA seed-gating, rebuildPCs
   seeks, stampSamples gated on add/import seeds — landed 2026-07-23
5. **rebuildFx soft spots** (§ 5) — keptById built lazily; bases over
   running producers' windows only ← in-flight

## Landed (newest first; prune below ~4)

- 2026-07-23 tm: narrow rebuildFx bases to the running producers (§ 5)
- 2026-07-23 tm: build rebuildFx's keptById lazily on first keep (§ 5)
- 2026-07-23 tm: seed-gate rebuildPA's PA re-projection (§ 4)
- 2026-07-23 tm: gate stampSamples' sample scan on seed-dirty channels (§ 4)

## Now

(empty — interval-dirt-v2 complete: phases 1-5 all landed, the rebuildFx base narrowing was the last item. Run /plan-next to promote the next programme's first brief.)

## Queued (current phase; one-liners)

(empty — phase 5's last item is in Now; landing it closes phases 1–5 and the
interval-dirt-v2 programme.)

(§ 6 lists the by-design non-targets: `rebuildCCs`' seed/wholesale
split, the tail walk's 16-seed linear fallback, the
`coverOnsets`/`coverInto` binary seeks.)
