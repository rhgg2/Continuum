# library model — plan

> source: `design/library-model.md` — synthesis (`/plan-next`) compiles
> from there; don't design here.

## Phases

1. **library.lua** (§ 1 + `defaultFor` from § 2) — shared tier module over a cm
   handle; new `library_spec`, no production caller yet — landed
2. **cm: kill seeding** (§ 2) — delete `seedGlobalFromDefault` + its
   `config_schema_spec` cases and its three dead callers — landed
   (the one-off factory-equal purge was dropped: pre-beta, we don't migrate
   previous config — [[project_no_legacy_data]])
3. **Pickers** (§ 3) — `libPicker` drops the seed call, gains the modified
   badge; `pickTemper`'s inline localize → `lib.localize`, moved to trackerView
   for swing/temper symmetry ← in-flight
4. **Editors write to project** (§ 4) — `setSwingComposite`/`setTemper` lose
   `tier`; `swingWrite`/`temperWrite` fork-on-write; `promote`→`publish`,
   `demote`→`revert`; New/Import modals create at project
5. **editorRender tree + action bar** (§ 5) — Active/Project/Library/Factory
   sections; `publish`/`revert`/`tidy` verbs; modified badge on project rows
6. **Docs** (§ 6) — `swingEditor.md` + `configManager.md` rewrites; new
   `docs/library.md`; archive the design doc

## Landed (newest first; prune below ~4)

- 2026-07-23 library: thread lib into production, unify localize (§ 3)
- 2026-07-23 cm: drop library seeding from the factory catalogue (§ 2)
- 2026-07-23 library: add shared project/library/factory tier module (§ 1)

## Now

(empty — phase 3's localize half landed; the libPicker modified badge is the next Queued commit. Run /plan-next to promote it.)

## Queued (current phase; one-liners)

- **`libPicker` modified badge** (§ 3) — thread `lib` into `chrome`
  (`coordinator.lua:21-22`); in `chrome.libPicker` (`:424-449`) mark project
  rows where `lib.modified(key, name)` is true with a dirty marker. Grouping
  stays Off / project / `+`others (splitting others into Library/Factory is
  optional polish, design open-Q 3, not required).
