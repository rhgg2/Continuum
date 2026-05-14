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
  'util_edit_primitives_spec',
  'util_bucket_spec',
  'util_install_hooks_spec',
  'aliases_helpers_spec',
  'aliases_walker_spec',
  'aliases_route_spec',
  'aliases_create_spec',
  'aliases_lane_clip_spec',
  'aliases_step_pitch_spec',
  'aliases_sever_spec',
  'aliases_struct_delete_spec',
  'aliases_quantize_spec',
  'aliases_scale_spec',
  'aliases_repitch_spec',
  'aliases_noteoff_spec',
  'aliases_interpolate_spec',
  'mm_signal_flow_spec',
  'mm_cc_metadata_spec',
  'mm_ppql_roundtrip_spec',
  'mm_cc_reconcile_spec',
  'mm_cc_dedup_spec',
  'mm_deletecc_sidecar_spec',
  'mm_token_spec',
  'mm_unified_spec',
  'sidecar_reconcile_spec',
  'tm_rebuild_spec',
  'tm_rebuild_rule_spec',
  'tm_authoring_forward_spec',
  'tm_absorber_reseat_spec',
  'tm_tuning_spec',
  'tm_swing_spec',
  'tm_clear_same_key_spec',
  'tm_lane_overlap_warn_spec',
  'tm_pc_synthesis_spec',
  'timing_period_spec',
  'timing_atoms_spec',
  'timing_composite_spec',
  'vm_grid_spec',
  'vm_alias_nav_spec',
  'vm_editing_spec',
  'view_context_spec',
  'parts_spec',
  'regions_helpers_spec',
  'ec_regions_spec',
  'vm_tracker_mode_spec',
  'sample_view_spec',
  'slot_store_spec',
  'fs_spec',
  'edit_cursor_spec',
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
  'vm_take_properties_spec',
  'tracker_page_spec',
  'sample_page_spec',
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
