# library model — plan

> source: `design/library-model.md` — synthesis (`/plan-next`) compiles
> from there; don't design here.

## Phases

1. **library.lua** (§ 1 + `defaultFor` from § 2) — shared tier module over a cm
   handle; new `library_spec`, no production caller yet ← in-flight
2. **cm: kill seeding** (§ 2) — delete `seedGlobalFromDefault` + its
   `config_schema_spec` cases; one-off purge of factory-equal global entries on
   first library read
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

- 2026-07-23 library: add shared project/library/factory tier module (§ 1)

## Now

(empty -- phase 1 landed; run /plan-next to promote phase 2: delete seedGlobalFromDefault + its config_schema_spec cases, add the one-off purge of factory-equal global entries on first library read.)

## Queued (current phase; one-liners)

(empty — phase 1 is a single commit, now in Now. Landing it opens phase 2:
delete `seedGlobalFromDefault` + its `config_schema_spec` cases, add the
one-off purge of factory-equal global entries on first library read.)
