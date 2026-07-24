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
   for swing/temper symmetry — landed
4. **Editors write to project** (§ 4) — `setSwingComposite`/`setTemper` lose
   `tier`; `swingWrite`/`temperWrite` fork-on-write; `promote`→`publish`,
   `demote`→`revert`; New/Import modals create at project — landed
5. **editorRender tree + action bar** (§ 5) — Active/Project/Library/Factory
   sections; `publish`/`revert`/`tidy` verbs; modified badge on project rows;
   the publish-overwrite confirm modal lands here (QO1, deferred 2026-07-24) ← in-flight
6. **Docs** (§ 6) — `swingEditor.md` + `configManager.md` rewrites; new
   `docs/library.md`; archive the design doc

## Landed (newest first; prune below ~4)

- 2026-07-24 editors: Factory tree section over lib.names (§ 5, first bullet)
- 2026-07-24 editors: delegate promote/demote to lib.publish/revert (§ 4)
- 2026-07-24 temperEditor: fork writes to the project tier (§ 4)
- 2026-07-23 swingEditor: fork writes to the project tier (§ 4)

## Now

(Factory tree sections landed in both editors, sourced from lib.names. Next queued: action bar publish/revert/tidy verbs wired to the selected row's tier — run /plan-next to promote it.)

## Queued (current phase; one-liners)

- action bar: `publish`/`revert`/`tidy` verbs wired to the selected row's tier
- modified badge on project rows in the editor tree (mirrors the picker badge)
- publish-overwrite confirm modal (QO1, deferred from Phase 4) — build modalHost wiring here
