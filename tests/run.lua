-- Test runner. Usage: lua tests/run.lua [filter]

local info = debug.getinfo(1, 'S').source:match('^@?(.*)')
local testDir = info:match('^(.*)/[^/]+$') or '.'
local projectRoot = testDir:match('^(.*)/tests$') or testDir .. '/..'

package.path = projectRoot .. '/?.lua;'
            .. testDir     .. '/?.lua;'
            .. testDir     .. '/specs/?.lua;'
            .. package.path

local harness = require('harness')

local filter = arg[1]

local specs = {
  'harness_sanity_spec',
  'command_manager_spec',
  'cmgr_stack_spec',
  'config_schema_spec',
  'cm_poll_undo_spec',
  'util_edit_primitives_spec',
  'util_bucket_spec',
  'util_install_hooks_spec',
  'util_serialise_spec',
  'mm_signal_flow_spec',
  'mm_cc_metadata_spec',
  'mm_ppql_roundtrip_spec',
  'mm_cc_reconcile_spec',
  'mm_cc_dedup_spec',
  'mm_deletecc_sidecar_spec',
  'mm_multi_note_delete_spec',
  'mm_note_cascade_sidecar_spec',
  'mm_token_spec',
  'mm_unified_spec',
  'sidecar_reconcile_spec',
  'tm_rebuild_spec',
  'tm_proj_symmetry_spec',
  'tm_rebuild_rule_spec',
  'tm_authoring_forward_spec',
  'tm_absorber_reseat_spec',
  'tm_tuning_spec',
  'tm_swing_spec',
  'tm_clear_same_key_spec',
  'tm_conform_tail_spec',
  'tm_unified_projection_spec',
  'tm_rescale_conform_spec',
  'tm_pc_synthesis_spec',
  'legato_spec',
  'groups_core_spec',
  'gm_propagate_spec',
  'gm_realisation_spec',
  'tv_selection_rect_spec',
  'tv_event_shift_spec',
  'tv_adjust_position_tail_spec',
  'gm_active_spec',
  'gm_origin_conform_spec',
  'gm_wiring_spec',
  'gm_dup_cascade_spec',
  'gm_metadata_propagate_spec',
  'gm_delete_sibling_spec',
  'gm_delete_conform_integration_spec',
  'gm_render_spec',
  'gm_bridge_spec',
  'gm_pitch_dupe_spec',
  'gm_stamp_commit_spec',
  'gm_persist_reload_spec',
  'gm_revive_delete_spec',
  'gm_overlap_spec',
  'gm_lifecycle_spec',
  'gm_override_transition_spec',
  'gm_two_channel_spec',
  'gm_swing_spec',
  'gm_delay_propagate_spec',
  'timing_period_spec',
  'timing_atoms_spec',
  'timing_composite_spec',
  'vm_grid_spec',
  'vm_editing_spec',
  'view_context_spec',
  'parts_spec',
  'vm_tracker_mode_spec',
  'sample_view_spec',
  'slot_store_spec',
  'fs_spec',
  'edit_cursor_spec',
  'ec_regions_spec',
  'tv_region_paint_spec',
  'group_clear_zone_spec',
  'tv_cascade_cancel_spec',
  'tv_dup_cascade_spec',
  'clipboard_spec',
  'vm_transient_frame_spec',
  'vm_reswing_cc_spec',
  'vm_logical_ppq_spec',
  'vm_delay_entry_spec',
  'vm_lane_drag_spec',
  'vm_slot_writers_spec',
  'vm_extra_cols_spec',
  'vm_reswing_lane_stability_spec',
  'vm_quantize_lane_stability_spec',
  'vm_quantize_keep_realised_lane_spec',
  'vm_insert_delete_row_lane_spec',
  'vm_row_shift_same_pitch_spec',
  'vm_conform_overlap_spec',
  'vm_take_properties_spec',
  'vm_scale_spec',
  'tracker_page_spec',
  'sample_page_spec',
  'am_spec',
  'arrange_view_spec',
  'arrange_page_spec',
  'coordinator_spec',
  'dag_validate_spec',
  'dag_lower_spec',
  'dag_srcset_spec',
  'dag_classes_spec',
  'dag_quotient_spec',
  'dag_absorption_spec',
  'dag_capacity_spec',
  'dag_ancestors_spec',
  'wm_persistence_spec',
  'wm_installed_fx_spec',
  'wm_probe_fx_io_spec',
  'wv_authoring_spec',
  'wp_smoke_spec',
}

local pass, fail, failures = 0, 0, {}

for _, name in ipairs(specs) do
  local spec = require(name)
  for _, test in ipairs(spec) do
    local fullName = name .. ' :: ' .. test.name
    if not filter or fullName:find(filter, 1, true) then
      local ok, err = xpcall(function() test.run(harness) end, debug.traceback)
      if ok then
        pass = pass + 1
        io.write(string.format('  ok    %s\n', fullName))
      else
        fail = fail + 1
        failures[#failures + 1] = { name = fullName, err = err }
        io.write(string.format('  FAIL  %s\n', fullName))
      end
    end
  end
end

if #failures > 0 then
  io.write('\n=== failures ===\n')
  for _, f in ipairs(failures) do
    io.write('\n-- ' .. f.name .. '\n')
    io.write(tostring(f.err) .. '\n')
  end
end

io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail > 0 and 1 or 0)
