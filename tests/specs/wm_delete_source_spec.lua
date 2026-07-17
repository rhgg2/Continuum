-- Source-track deletion is explicit and guarded: reconcile treats sourceTracks as
-- undeletable (drains FX, never deletes), so wm:deleteSource must remove the node +
-- incident edges AND delete the REAPER track itself — refusing when the track holds
-- takes unless forced.
local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  wm:load()
  return h, wm
end

local function seedSource(h, guid)
  local track = { __label = 'src-' .. guid }
  table.insert(h.reaper._state.projectTracks, track)
  h.reaper._state.trackGuids[track] = guid
  return track
end

-- Source 'src' (track guid) --midi--> fx 'n1', built by hand so validate sees a
-- well-formed graph. JS:plain has ins=2, so addFxNode spawns no auto-source.
local function seedGraph(wm, guid)
  reaper:setFxIO('JS:plain', { ins = 2, outs = 2 })
  local fxId = wm:addFxNode(0, 0, { name = 'Plain', ident = 'JS:plain' })
  wm:mutate(function(g)
    g.nodes.src = { kind = 'source', trackId = guid, pos = { x = 0, y = 0 },
                    ports = { audio = { ins = 0, outs = 1 },
                              midi  = { ins = 0, outs = 1 } } }
    util.add(g.edges, { type = 'midi', from = 'src', to = fxId })
  end)
end

local function trackPresent(h, track)
  for _, tr in ipairs(h.reaper._state.projectTracks) do
    if tr == track then return true end
  end
  return false
end

return {
  {
    name = 'deleteSource drops the node, its incident edges, and the REAPER track',
    run = function(harness)
      local h, wm  = mkWm(harness)
      local track  = seedSource(h, 'guid-A')
      seedGraph(wm, 'guid-A')

      local ok = wm:deleteSource('src')
      t.eq(ok, true, 'returns true on a clean delete')
      t.eq(wm:graph().nodes.src, nil, 'source node gone')
      for _, e in ipairs(wm:graph().edges) do
        t.eq(e.from ~= 'src' and e.to ~= 'src', true, 'no edge still references src')
      end
      t.eq(trackPresent(h, track), false, 'REAPER source track deleted')
    end,
  },
  {
    name = 'deleteSource refuses a track holding takes, returning the count; nothing changes',
    run = function(harness)
      local h, wm  = mkWm(harness)
      local track  = seedSource(h, 'guid-A')
      seedGraph(wm, 'guid-A')
      h.reaper._state.itemsByTrack[track] = { {}, {} }  -- two takes

      local ok, takes = wm:deleteSource('src')
      t.eq(ok, false, 'refuses without force')
      t.eq(takes, 2, 'reports the take count for the page to confirm against')
      t.eq(wm:graph().nodes.src ~= nil, true, 'source node still present')
      t.eq(trackPresent(h, track), true, 'REAPER track untouched')
    end,
  },
  {
    name = 'deleteSource(force) deletes a take-bearing track anyway',
    run = function(harness)
      local h, wm  = mkWm(harness)
      local track  = seedSource(h, 'guid-A')
      seedGraph(wm, 'guid-A')
      h.reaper._state.itemsByTrack[track] = { {}, {} }

      local ok = wm:deleteSource('src', true)
      t.eq(ok, true, 'force overrides the takes guard')
      t.eq(wm:graph().nodes.src, nil, 'source node gone')
      t.eq(trackPresent(h, track), false, 'REAPER track deleted despite takes')
    end,
  },
  {
    name = 'addSourceNode mints a standalone source node backed by a real source track',
    run = function(harness)
      local h, wm = mkWm(harness)
      local id    = wm:addSourceNode{ name = 'Bass', pos = { x = 7, y = 9 } }
      local node  = wm:graph().nodes[id]
      t.eq(node.kind, 'source', 'node is a source')
      t.eq(node.displayName, 'Bass')
      local track
      for i = 0, h.reaper.CountTracks(0) - 1 do
        local tr = h.reaper.GetTrack(0, i)
        if h.reaper.GetTrackGUID(tr) == node.trackId then track = tr end
      end
      t.truthy(track, 'source track exists for the node id')
      t.eq(wm:isScratchTrack(track), false, 'and it is not the scratch track')
    end,
  },
  {
    name = 'addFxNode with autoSource=false skips the auto source for a 0-in generator',
    run = function(harness)
      local _, wm = mkWm(harness)
      reaper:setFxIO('JS:gen', { ins = 0, outs = 2 })  -- generator: no audio in
      wm:addFxNode(0, 0, { name = 'Gen', ident = 'JS:gen' }, { autoSource = false })
      local sources = 0
      for _, n in pairs(wm:graph().nodes) do
        if n.kind == 'source' then sources = sources + 1 end
      end
      t.eq(sources, 0, 'no source node auto-spawned when autoSource=false')
    end,
  },
}
