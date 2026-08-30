# spec audit tracker

282 specs, 2948 tests, 8690 assertions, 69150 lines. The audit reads
specs and checks them against the standard of the coding skill:
`.claude/skills/coding/SKILL.md`

## method

Per spec, in order:

1. **Read the header against the docs.** Specs should pin a model and
   the header should describe what is pinned, not a plan phase, a
   commit, or a "not yet". Check what `docs/` and the module's
   `--contract:`/`--invariant:` annotations say now (`map_query` with
   `kind='ann'`). Non model-based framings usually reach the case
   names too.

1. **Give every case its sentence** — the doc line or annotation it
   pins. A case with no sentence is either under-documented model or a
   pinned implementation; decide which before touching it.

1. **Look for the three shapes.** Vacuous assertions: a loop with no
   precondition, a comparison whose sides can both be nil, an assertion
   over a batch that can be empty. Restated constants: a literal copied
   from the code rather than derived. Names that claim more than the
   scenario can exercise.

1. **Turn suspicion into evidence with `spec_perturb` before editing.**
   Break the mechanism each doubtful case names. A case that survives
   the breakage of its own mechanism is the finding; one that dies is
   vindicated and left alone. A batch of six on a filtered spec costs
   about two seconds.

1. **Edit, then re-run the same batch.** The rewrite has to kill
   everything the original killed, plus whatever it was written to
   close.

1. Move the row to `## done` with a line saying what changed.

## done

**vm_tracker_mode_spec** (354 → 372, 15 → 14 tests). Header pinned
"commit 2a of the sampler-integration plan" and claimed synthesis had
not landed; it has. The pc-col pair was two tests where the second was
vacuous alone — perturbing the pc col out of existence entirely left it
green — so they became one case asserting the difference between the
modes. `t.eq(col.width, 9)` became a relation against the mode-off
width. Two case names promised "even into empty slots", which no
scenario here can exercise. All five original perturbation kills held.

**tm_fx_region_spec** (3117 → 3162, 116 tests unchanged). The header and six
banners framed the spec by plan phase — "Note macros v2", "4.6 producer
split", G2, G4, Phase A, A3, A4, C2 — all of which resolve to archived design
docs; each became the model sentence it pins, cited to a `docs/generators.md`
§. Restated constants: `ccDefaultRest[10]`'s 64 was copied into nine expected
values across four cc-augment cases, so a change of the controller's rest
broke four cases about the *fold* — they now read the rest and add the
fixture's own deltas, and the config default is left to `generators_spec`,
which holds the teeth for it. The `fxp-1` uuid pinned the mint's counter seed
as well as its prefix (perturbing the seed to 40 killed it) and became a
prefix match. Two `freezeRect` cases spelled `'note:1'` / `'pb:0'` as
literals; they now route through `groups.streamId`. The captured `1244` at
the detune onset was a two-tick geometry artifact rationalised in a comment
— replaced by the relation it was really after (the pair differ by detune
alone), which still kills a cent of drift in the dual point and a widened
dual-point gap. Non-triviality guards went onto seven assertions whose two
sides could both go empty or nil (the freeze-gate snapshots, explode's
before/after, the widened-window cc sweep, the cc round-trip fingerprint,
freeze-to-group's cents); `#curve == 3` became a count derived from the
live column. `arp over a silent span` had no positive control and gained
one that is itself a model sentence: the chain registers its note window
regardless (§ Emission is ownership ¶3). Two whole-record `deepEq`s over
input-stream records became field reads, so adding a field to `host.pas`
no longer breaks a case about the PA riding in. One case went the other
way: its preamble claimed an emptied cc column shell "stands rather than
vanishing", which nothing in `docs/` states and nothing in the suite
catches — the assertion was right to hedge and the comment was corrected
instead.

## still to do

Sorted by size descending (lines). `asserts` counts t.eq / t.deepEq /
t.bagEq / t.truthy / t.falsy / t.eventsMatch; a low ratio against `tests`
is a hint, not a verdict.

|  lines | tests | asserts | spec |
|-------:|------:|--------:|------|
|   2172 |    69 |     257 | tracker_page_spec |
|   2078 |    72 |     185 | sonority_spec |
|   1977 |   117 |     365 | am_spec |
|   1551 |    77 |     212 | tv_fx_region_spec |
|   1364 |    77 |     230 | arrange_view_spec |
|   1364 |    56 |     121 | arrange_page_spec |
|   1269 |    77 |     303 | tuning_spec |
|   1055 |    38 |     130 | edit_cursor_spec |
|    967 |    69 |     178 | generators_spec |
|    906 |    39 |     168 | dag_target_tracks_spec |
|    883 |    24 |     109 | tm_tuning_spec |
|    701 |    31 |     121 | slot_store_spec |
|    640 |    39 |     101 | view_context_spec |
|    639 |    31 |     105 | dag_allocate_spec |
|    633 |    16 |      82 | clipboard_spec |
|    567 |    16 |      54 | vm_editing_spec |
|    559 |    23 |      71 | vm_grid_spec |
|    556 |    35 |      84 | wm_diff_spec |
|    551 |    23 |      78 | sidecar_reconcile_spec |
|    526 |    18 |      51 | vm_lane_drag_spec |
|    520 |    20 |      53 | tm_rebuild_rule_spec |
|    519 |    18 |      65 | wm_apply_ops_spec |
|    517 |    34 |      72 | config_schema_spec |
|    516 |    20 |      36 | wm_read_spec |
|    514 |    23 |      33 | vm_retune_spec |
|    492 |    20 |      76 | tv_master_channel_spec |
|    476 |    20 |      57 | keyDispatch_spec |
|    472 |    17 |      74 | vm_temper_entry_spec |
|    470 |    20 |      54 | tm_rebuild_spec |
|    460 |    18 |      82 | menu_spec |
|    450 |    21 |      71 | ec_regions_spec |
|    439 |    23 |       3 | wm_roundtrip_spec |
|    425 |     6 |      35 | tm_gate_parity_spec |
|    423 |    32 |      56 | dag_validate_spec |
|    414 |    13 |      50 | help_input_spec |
|    411 |    15 |      50 | tm_macro_spec |
|    405 |    16 |      26 | tm_pc_synthesis_spec |
|    403 |    20 |      45 | mm_blob_serialise_spec |
|    383 |    12 |      37 | vm_logical_ppq_spec |
|    374 |    12 |      50 | mm_cc_dedup_spec |
|    368 |    19 |      47 | vm_fx_ui_spec |
|    363 |    19 |      31 | timing_atoms_spec |
|    359 |    23 |      86 | wv_authoring_spec |
|    351 |    26 |      75 | groups_core_spec |
|    349 |    11 |      55 | group_clear_zone_spec |
|    345 |    16 |      65 | vm_chord_entry_spec |
|    332 |     8 |      38 | tv_freeze_group_spec |
|    325 |    22 |      44 | command_manager_spec |
|    325 |    10 |      52 | dag_bus_spec |
|    323 |    13 |      33 | tv_event_shift_spec |
|    323 |     8 |      26 | patternEditor_shelf_spec |
|    322 |     7 |      43 | menu_render_spec |
|    316 |    13 |      43 | editor_verbs_spec |
|    316 |    11 |      31 | patternEditor_writethrough_spec |
|    311 |    10 |      64 | vm_take_properties_spec |
|    308 |    11 |      16 | wm_folders_read_spec |
|    307 |    17 |      48 | cmgr_stack_spec |
|    306 |     9 |      25 | vm_delay_entry_spec |
|    302 |    15 |      43 | wm_snapshot_spec |
|    295 |    18 |      48 | library_spec |
|    293 |    13 |      29 | tm_slide_spec |
|    292 |    22 |      55 | painter_spec |
|    290 |    18 |      38 | vm_signed_entry_spec |
|    283 |     8 |      36 | mm_cc_reconcile_spec |
|    274 |    12 |      41 | keyQueue_spec |
|    270 |    13 |      24 | dag_split_spec |
|    270 |    10 |      60 | wm_bus_node_spec |
|    267 |    16 |      55 | gm_lifecycle_spec |
|    262 |    10 |      26 | ps_mirror_spec |
|    261 |    11 |      30 | status_edit_spec |
|    257 |     7 |      12 | gm_override_transition_spec |
|    251 |     8 |      18 | vm_reswing_cc_spec |
|    248 |     6 |      19 | gm_swing_spec |
|    245 |    16 |      33 | bridge_spec |
|    239 |    13 |      28 | cmgr_manifest_spec |
|    238 |    10 |      35 | dag_allocate_midi_bracket_spec |
|    236 |    10 |      19 | mm_chan_index_spec |
|    232 |     6 |      22 | tm_absorber_reseat_spec |
|    230 |    10 |      27 | tm_sine_spec |
|    228 |    17 |      40 | wm_jsfx_bus_aware_spec |
|    223 |     8 |      28 | gm_propagate_spec |
|    223 |     8 |      19 | picker_tiers_spec |
|    221 |    10 |      38 | cmgr_menu_spec |
|    218 |    12 |      25 | mm_signal_flow_spec |
|    217 |    10 |      33 | cmgr_overrides_spec |
|    217 |     6 |      23 | curveEditor_spec |
|    215 |     6 |      23 | gm_pb_member_spec |
|    213 |    11 |      21 | timing_composite_spec |
|    213 |     6 |      19 | arrange_tidy_modal_spec |
|    211 |     5 |      11 | mm_sidecar_state_spec |
|    209 |    15 |      30 | sample_view_spec |
|    208 |     6 |      21 | tm_trill_spec |
|    207 |    18 |      34 | vm_slot_writers_spec |
|    206 |    13 |      23 | pext_store_spec |
|    206 |     6 |      13 | patternEditor_modal_spec |
|    205 |    10 |      12 | dag_absorption_spec |
|    201 |     3 |      11 | mm_wire_splice_spec |
|    199 |    18 |      39 | util_edit_primitives_spec |
|    199 |     6 |      13 | dag_folder_midi_spec |
|    195 |    13 |      41 | parts_spec |
|    195 |     7 |      20 | modal_input_spec |
|    195 |     5 |      16 | wm_fx_routing_apply_spec |
|    193 |     9 |      18 | picker_create_spec |
|    192 |    10 |      30 | harness_sanity_spec |
|    189 |    14 |      20 | tv_fx_patch_spec |
|    187 |     6 |      12 | gm_row_atomic_spec |
|    185 |     8 |      15 | editor_new_modal_spec |
|    182 |     8 |      18 | tm_authoring_forward_spec |
|    182 |     8 |      15 | dag_allocate_midi_spec |
|    180 |     3 |      15 | wm_apply_midi_merge_spec |
|    176 |     7 |      25 | vm_digit_entry_spec |
|    173 |     9 |      25 | mm_unified_spec |
|    172 |     6 |      15 | wm_live_spec |
|    171 |     7 |      11 | mm_sort_order_spec |
|    170 |     9 |      26 | rm_sends_spec |
|    169 |     7 |      14 | tm_conform_tail_spec |
|    168 |     5 |      32 | dag_absorb_alloc_spec |
|    166 |     9 |      19 | tm_swing_spec |
|    166 |     5 |      14 | wm_bus_read_spec |
|    165 |     5 |       9 | mm_flush_spec |
|    164 |     7 |       9 | tm_flush_collision_scan_spec |
|    164 |     5 |      10 | tm_column_order_spec |
|    163 |    12 |      21 | dataStore_spec |
|    162 |     5 |      16 | gm_realisation_spec |
|    159 |     6 |      13 | coordinator_spec |
|    159 |     4 |      15 | tm_regionpark_gating_spec |
|    159 |     4 |      10 | tm_raw_index_order_spec |
|    157 |     8 |      17 | rm_fx_write_spec |
|    157 |     6 |      11 | wp_smoke_spec |
|    156 |     9 |      19 | rm_midi_routing_spec |
|    155 |     4 |      19 | tm_cc_gating_spec |
|    153 |     9 |      18 | mm_cc_metadata_spec |
|    153 |     2 |      14 | gm_origin_conform_spec |
|    151 |     5 |      36 | tm_pb_interp_spec |
|    150 |     3 |       8 | cmgr_fluent_spec |
|    148 |     8 |      10 | tv_dup_cascade_spec |
|    148 |     4 |      10 | picker_groups_spec |
|    148 |     4 |       9 | wm_diff_midi_bus_spec |
|    146 |     4 |      13 | gridPane_note_entry_spec |
|    144 |     7 |      24 | mm_addressing_spec |
|    143 |     7 |      10 | sample_page_spec |
|    143 |     6 |      23 | mm_wide_cc_spec |
|    141 |     7 |      23 | spans_spec |
|    141 |     7 |       9 | wm_reconcile_cache_spec |
|    139 |    13 |      40 | period_ladder_spec |
|    139 |     3 |      18 | wm_target_alloc_spec |
|    139 |     3 |      17 | patternEditor_lifecycle_spec |
|    138 |    10 |      21 | eventMeta_spec |
|    137 |     6 |      16 | dag_classes_spec |
|    137 |     3 |      12 | gm_persist_reload_spec |
|    136 |     6 |      16 | rm_mute_spec |
|    136 |     3 |      15 | gm_shift_in_spec |
|    135 |     4 |      16 | temperEditor_tree_spec |
|    135 |     4 |       9 | picker_delete_spec |
|    133 |     8 |       8 | dag_srcset_spec |
|    132 |     9 |      21 | wv_bus_spec |
|    131 |     4 |      15 | tm_fx_gating_spec |
|    131 |     4 |      14 | gm_wiring_spec |
|    130 |    11 |      28 | fake_reaper_sends_spec |
|    130 |     8 |      22 | rm_fx_ports_spec |
|    129 |     5 |      16 | mm_plain_cc_spec |
|    129 |     4 |      17 | tm_clear_same_key_spec |
|    126 |     4 |       8 | tm_seek_walk_spec |
|    125 |     5 |      24 | mm_ppql_roundtrip_spec |
|    123 |     3 |       7 | vm_undo_label_spec |
|    123 |     1 |       4 | mm_deletecc_sidecar_spec |
|    122 |     4 |       8 | tm_rebind_gate_spec |
|    121 |     6 |      19 | wm_splice_spec |
|    120 |     4 |      31 | pa_apply_spec |
|    120 |     3 |      14 | vm_extra_cols_spec |
|    119 |     5 |      16 | wm_delete_source_spec |
|    119 |     4 |      16 | tv_param_bind_spec |
|    119 |     4 |      15 | tm_tail_gating_spec |
|    117 |     7 |      13 | util_install_hooks_spec |
|    117 |     5 |      17 | tv_param_learn_spec |
|    117 |     2 |       6 | tm_zero_write_spec |
|    116 |     5 |       9 | gm_paste_facade_spec |
|    116 |     3 |      18 | mm_load_dedup_spec |
|    115 |     3 |      14 | libpicker_badge_spec |
|    114 |     3 |       3 | tm_deferred_hole_spec |
|    112 |     5 |      22 | rm_tracks_spec |
|    111 |     8 |      19 | wm_probe_fx_io_spec |
|    111 |     3 |       4 | dag_folder_capacity_spec |
|    110 |     6 |      11 | pa_frecency_spec |
|    110 |     2 |      20 | tm_park_restore_end_spec |
|    109 |     3 |       9 | tm_curve_density_spec |
|    109 |     3 |       6 | gm_dup_cascade_spec |
|    108 |     5 |      10 | cm_poll_undo_spec |
|    108 |     3 |       8 | gm_delete_sibling_spec |
|    107 |     6 |      21 | util_seeks_spec |
|    107 |     6 |      10 | wv_reachability_spec |
|    107 |     4 |      16 | mm_collision_backstop_spec |
|    107 |     2 |      12 | gm_shift_out_spec |
|    106 |     5 |      13 | vm_transient_frame_spec |
|    106 |     4 |       4 | wm_pin_grow_reassert_spec |
|    106 |     3 |       9 | vm_insert_delete_row_lane_spec |
|    105 |     5 |      16 | rm_metadata_spec |
|    105 |     2 |      13 | gm_revive_delete_spec |
|    102 |     3 |       9 | wm_track_move_spec |
|    101 |     6 |      22 | mm_blob_wide_spec |
|    101 |     3 |       9 | dag_allocate_midi_native_spec |
|    101 |     2 |       8 | tm_fx_tension_spec |
|    100 |     6 |      18 | wm_persistence_spec |
|     99 |     4 |      12 | tv_region_paint_spec |
|     98 |     4 |      12 | tm_note_lane_carry_spec |
|     98 |     3 |      14 | mm_hole_iter_spec |
|     98 |     2 |       5 | gm_delay_propagate_spec |
|     96 |     3 |       6 | tm_pa_attachment_spec |
|     95 |     2 |       8 | tm_proj_symmetry_spec |
|     94 |     3 |      16 | mm_stable_slot_spec |
|     94 |     2 |      12 | tm_unified_projection_spec |
|     93 |     7 |       7 | dag_classify_spec |
|     92 |     3 |       5 | wm_fx_locations_spec |
|     92 |     3 |       4 | wm_undo_spec |
|     90 |     4 |      14 | tv_selection_rect_spec |
|     90 |     4 |       4 | wm_sampler_reachable_spec |
|     89 |     4 |      13 | rm_fx_read_spec |
|     89 |     3 |      10 | pa_track_scope_spec |
|     89 |     3 |       8 | vm_conform_overlap_spec |
|     89 |     1 |       7 | gm_stamp_commit_spec |
|     88 |     2 |       7 | gm_block_shift_alias_spec |
|     87 |     3 |       4 | tm_reseat_collision_spec |
|     86 |     9 |      22 | util_pretty_serialise_spec |
|     86 |     8 |      22 | fs_spec |
|     86 |     5 |       6 | tv_wide_cc_entry_spec |
|     86 |     2 |       8 | wm_param_targets_spec |
|     84 |     6 |       9 | wv_edge_gain_spec |
|     84 |     2 |       3 | tm_interval_walk_spec |
|     83 |     3 |       4 | tm_fx_window_cache_spec |
|     82 |     8 |       9 | timing_period_spec |
|     82 |     4 |      13 | gm_overlap_spec |
|     82 |     2 |       6 | tv_cascade_cancel_spec |
|     82 |     1 |       6 | gm_delete_conform_integration_spec |
|     81 |     4 |       7 | rm_pinmaps_spec |
|     81 |     2 |       6 | gm_take_clip_spec |
|     80 |     3 |       9 | tm_pb_gating_spec |
|     80 |     1 |       4 | mm_note_cascade_sidecar_spec |
|     79 |     3 |      10 | mm_take_window_spec |
|     78 |     4 |      12 | rm_installed_fx_spec |
|     78 |     3 |       5 | gm_create_delete_facade_spec |
|     78 |     2 |       3 | tm_pa_swung_translation_spec |
|     77 |     4 |      17 | gm_active_spec |
|     77 |     2 |       2 | gm_local_guard_spec |
|     76 |     1 |       4 | wm_repartition_move_spec |
|     72 |     2 |       8 | vm_row_shift_same_pitch_spec |
|     67 |     4 |      15 | gm_render_spec |
|     67 |     1 |       6 | vm_quantize_lane_stability_spec |
|     66 |     5 |      19 | util_serialise_spec |
|     66 |     3 |       4 | dag_capacity_split_spec |
|     64 |     3 |       5 | tm_dormant_config_spec |
|     64 |     2 |       4 | gm_value_facade_spec |
|     63 |     3 |       9 | wm_installed_fx_spec |
|     61 |     2 |       5 | gm_bridge_spec |
|     61 |     2 |       3 | tv_adjust_position_tail_spec |
|     61 |     1 |       5 | mm_delete_then_sidecar_write_spec |
|     61 |     1 |       4 | gm_pitch_dupe_spec |
|     60 |     2 |       7 | rm_folders_spec |
|     60 |     1 |       2 | gm_two_channel_spec |
|     59 |     3 |      12 | pa_compute_desired_spec |
|     57 |     5 |      17 | util_bucket_spec |
|     57 |     2 |       8 | gm_at_member_spec |
|     56 |     4 |      10 | tv_palette_tab_spec |
|     56 |     2 |       8 | tm_bind_skipguard_spec |
|     56 |     1 |       5 | mm_multi_note_delete_spec |
|     54 |     2 |       9 | wv_fx_mute_spec |
|     54 |     1 |       3 | gm_revive_delay_remove_spec |
|     54 |     1 |       2 | vm_quantize_keep_realised_lane_spec |
|     50 |     1 |       4 | mm_pa_assign_spec |
|     49 |     3 |       7 | wv_activate_spec |
|     49 |     1 |       4 | wv_folder_spec |
|     48 |     2 |       6 | vm_scale_spec |
|     46 |     4 |       6 | mm_blob_parse_spec |
|     46 |     1 |       5 | mm_take_validity_spec |
|     45 |     2 |       2 | pa_crosstrack_spec |
|     43 |     1 |       6 | gm_metadata_propagate_spec |
|     40 |     3 |       9 | scratch_spec |
|     39 |     1 |       5 | tm_rescale_conform_spec |
|     26 |     1 |       2 | masterMix_spec |
|     23 |     1 |       1 | util_instantiate_spec |
|     18 |     1 |       1 | tm_fx_patterns_spec |
