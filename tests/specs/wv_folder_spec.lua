-- The read→view seam (uncovered before this): readGraph mints a folder parent as a source node
-- with audio.ins>=1; the view must project it as a bodied 'folder' node, not a bodiless source
-- tag, so its children's parent-send wires have a rect to land on. See docs/wiringView.md § source bodies.
local t    = require('support')
local util = require('util')

local function mkWv(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  local wv = util.instantiate('wiringView', { cm = h.cm, wm = wm })
  return h, wv, wm
end

local function seedTrack(h, guid)
  local tr = { __label = guid }
  table.insert(h.reaper._state.projectTracks, tr)
  h.reaper._state.trackGuids[tr] = guid
  return tr
end

local function byId(views)
  local m = {}
  for _, v in ipairs(views) do m[v.id] = v end
  return m
end

return {
  {
    name = 'folder parent projects as a bodied folder node; leaf source stays a tag',
    run = function(harness)
      local h, wv, wm = mkWv(harness)
      local P = seedTrack(h, '{P}')   -- folder parent
      local C = seedTrack(h, '{C}')   -- leaf child, parent-sends into P
      h.reaper.SetMediaTrackInfo_Value(P, 'I_FOLDERDEPTH', 1)
      h.reaper.SetMediaTrackInfo_Value(C, 'I_FOLDERDEPTH', -1)
      wm:load()

      local nodes = byId(wv:nodeViews())
      t.eq(nodes['{P}'].category, 'folder', 'folder parent is bodied (category folder)')
      t.eq(nodes['{C}'].category, 'source', 'leaf source stays bodiless (category source)')

      local fromKind = {}
      for _, w in ipairs(wv:wireViews()) do fromKind[w.from] = w.fromKind end
      t.eq(fromKind['{P}'], 'folder', "folder parent's out-wire is a normal wire, not a tag")
      t.eq(fromKind['{C}'], 'source', 'leaf child stays tag-rendered')
    end,
  },
}
