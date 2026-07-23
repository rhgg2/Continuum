# library model — plan

> source: `design/library-model.md` — synthesis (`/plan-next`) compiles
> from there; don't design here.

## Phases

1. **library.lua** (§ 1 + `defaultFor` from § 2) — shared tier module over a cm
   handle; new `library_spec`, no production caller yet — landed
2. **cm: kill seeding** (§ 2) — delete `seedGlobalFromDefault` + its
   `config_schema_spec` cases and its three dead callers ← in-flight
   (the one-off factory-equal purge was dropped: pre-beta, we don't migrate
   previous config — [[project_no_legacy_data]])
3. **Pickers** (§ 3) — `libPicker` drops the seed call, gains the modified
   badge; `pickTemper`'s inline localize → `lib.localize`, moved to trackerView
   for swing/temper symmetry
4. **Editors write to project** (§ 4) — `setSwingComposite`/`setTemper` lose
   `tier`; `swingWrite`/`temperWrite` fork-on-write; `promote`→`publish`,
   `demote`→`revert`; New/Import modals create at project
5. **editorRender tree + action bar** (§ 5) — Active/Project/Library/Factory
   sections; `publish`/`revert`/`tidy` verbs; modified badge on project rows
6. **Docs** (§ 6) — `swingEditor.md` + `configManager.md` rewrites; new
   `docs/library.md`; archive the design doc

## Landed (newest first; prune below ~4)

- 2026-07-23 cm: drop library seeding from the factory catalogue (§ 2)
- 2026-07-23 library: add shared project/library/factory tier module (§ 1)

## Now

(empty — phase 2 landed. The seed-call drop from libPicker also landed here, so phase 3 narrows to: libPicker's modified badge on project rows, and pickTemper's inline localize → lib.localize moved to trackerView for swing/temper symmetry. Run /plan-next to promote it.)

## Queued (current phase; one-liners)

(empty — § 2 is a single cohesive commit, now in Now. Landing it opens phase 3:
`libPicker` gains the modified badge; `pickTemper`'s inline localize becomes
`lib.localize`, moved to trackerView for swing/temper symmetry.)
