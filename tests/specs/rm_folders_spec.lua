-- routingManager folder structure: positional parent stamping + emergent-track
-- top-level pin. See design/archive/wiring-folders.md § read delta / § plan step 1.
local t       = require('support')
local harness = require('harness')
local util    = require('util')

local function mkRm()
  local h  = harness.mk()
  return h.reaper, util.instantiate('routingManager')
end

local function seedTrack(reaper, name, opts)
  opts = opts or {}
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', name, true)
  if opts.folderDepth then
    reaper.SetMediaTrackInfo_Value(track, 'I_FOLDERDEPTH', opts.folderDepth)
  end
  return track, reaper.GetTrackGUID(track)
end

local function byId(rm, id)
  for _, tr in ipairs(rm:tracks()) do if tr.id == id then return tr end end
end

return {
  {
    name = 'tracks() stamps each foldered track its parent guid (nested)',
    run = function()
      local reaper, rm = mkRm()
      -- Outer > (Inner > Leaf), then a top-level sibling. Leaf closes both folders.
      local _, outer = seedTrack(reaper, 'Outer', { folderDepth = 1 })
      local _, inner = seedTrack(reaper, 'Inner', { folderDepth = 1 })
      local _, leaf  = seedTrack(reaper, 'Leaf',  { folderDepth = -2 })
      local _, sib   = seedTrack(reaper, 'Sib')

      t.falsy(byId(rm, outer).parent, 'top-level folder parent has no parent')
      t.eq(byId(rm, inner).parent, outer, 'inner folder nested under outer')
      t.eq(byId(rm, leaf).parent,  inner, 'leaf is child of inner')
      t.falsy(byId(rm, sib).parent, 'sibling after the closed folder is top-level')
    end,
  },
  {
    name = 'addTrack pins emergent tracks top-level when the project ends in an open folder',
    run = function()
      local reaper, rm = mkRm()
      -- Parent opens a folder; Child leaves it open at project end (openDepth = 1).
      local _, parent = seedTrack(reaper, 'Parent', { folderDepth = 1 })
      local _, child  = seedTrack(reaper, 'Child')

      local newId = rm:addTrack({ name = 'Emergent' })

      t.falsy(byId(rm, newId).parent, 'emergent track lands top-level, not inside the folder')
      t.eq(byId(rm, child).parent, parent, 'the real child stays under its parent')
      t.eq(byId(rm, child).folderDepth, -1, 'the open folder was closed on the last real track')
    end,
  },
}
