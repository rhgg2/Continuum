-- Bindings are track-scoped, not take-scoped: the param a column drives belongs
-- to the track, so a second take on the same track opens with the column already
-- there and driving the same plink. And since a target carries one plink,
-- re-automating a bound param reuses its lane rather than minting a rival.

local t = require('support')

local NOTE = { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
               detune = 0, delay = 0, lane = 1 }

local TARGET = { trackGuid = '{DST}', fxGuid = '{FX-synth}', param = 2, label = 'Cutoff' }

-- The bound take's track plus a target track hosting a synth; projectItems
-- carries the takes pa's project-wide lane scan walks.
local function mkScenario(harness)
  local h = harness.mk{ seed = { notes = { NOTE } } }
  local r = h.reaper
  local src, dst = 'take1/track', 'dst/track'
  r._state.projectTracks = { src, dst }
  r._state.trackGuids[src] = '{SRC}'
  r._state.trackGuids[dst] = '{DST}'
  r._state.projectItems = { { takes = { 'take1' } } }
  r:setTrackFX(dst, { { ident = 'VST3:Synth' } })
  r:setFxGuid(dst, 0, '{FX-synth}')
  h.vm:setGridSize(80, 40)
  h.ec:setPos(0, 1, 1)
  return h, r, src, dst
 end

local function ccColIndex(h, cc)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'cc' and col.cc == cc then return i end
  end
end

local function namedParm(r, track, fxIdx, parm)
  local _, v = r.TrackFX_GetNamedConfigParm(track, fxIdx, parm)
  return v
end

return {

  {
    name = 'a bound lane carries its column into a second take on the track',
    run = function(harness)
      local h, r, src = mkScenario(harness)
      h.vm:setPaletteParam(TARGET)
      h.vm:automateParam()
      t.truthy(ccColIndex(h, 119), 'column in the take it was bound from')

      -- A second take on the same track, bound as the tracker would bind it.
      r:bindTake('take2', 'take2/item', src, 16)
      r._state.projectItems[2] = { takes = { 'take2' } }
      h.tm:bindTake('take2')
      h.vm:rebuild()

      t.truthy(h.vm:paramBinding(1, 119), 'binding resolves from the second take')
      t.truthy(ccColIndex(h, 119),        'and its column is there unasked')
      t.falsy(h.ds:get('extraColumns'),   'the column is derived, not written per take')
    end,
  },

  {
    name = 're-automating a bound param returns its lane, mints no rival',
    run = function(harness)
      local h, r, _, dst = mkScenario(harness)
      h.vm:setPaletteParam(TARGET)
      h.vm:automateParam()
      h.vm:automateParam()

      t.truthy(h.pa:binding(1, 119), 'the original binding stands')
      t.falsy(h.pa:binding(1, 118),  'no second lane for the same param')
      t.eq(namedParm(r, dst, 1, 'param.2.plink.param'), '0',
        'the plink still reads the first binding value slot')
    end,
  },

  {
    name = 'a param bound on one channel is refused on another',
    run = function(harness)
      local h = mkScenario(harness)
      t.eq(h.pa:automate(1, TARGET), 119, 'bound on channel 1')
      local lane, why = h.pa:automate(2, TARGET)
      t.falsy(lane, 'refused on channel 2')
      t.truthy(why and why:find('channel 1'), 'and says where it already lives')
    end,
  },

}
