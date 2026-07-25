# library model — plan

> source: `design/archive/library-model.md` (archived; programme complete)
> — synthesis compiled from there; don't design here.

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
   the publish-overwrite confirm modal lands here (QO1, deferred 2026-07-24) — landed
6. **Docs** (§ 6) — `swingEditor.md` + `configManager.md` rewrites; new
   `docs/library.md`; archive the design doc — landed

## Landed (newest first; prune below ~4)

- 2026-07-24 docs: land library-model prose; archive the design doc (§ 6)
- 2026-07-24 editors: tier-scoped action-bar sets with up/down verb labels (§ 5)
- 2026-07-24 editors: confirm before publishing over a divergent library copy (§ Open questions 1)
- 2026-07-24 editors: modified badge on editor tree project rows (§ 5)

## Now

(empty — library-model programme complete: all six phases landed. Run /plan-next to pick the next programme.)

## Queued (current phase; one-liners)

(none — all six phases landed)
