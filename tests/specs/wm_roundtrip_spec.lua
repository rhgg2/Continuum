-- read ∘ compile = id (invariant 1, design/wiring-implicit-graph.md § The algebra): for each authored graph g,
-- read(compile(g)) = g (rm-id rename). Both former non-injectivities fixed; quarantine is off image(compile) — invariant 2.
local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
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

local function source(guid, opts)
  opts = opts or {}
  return { kind='source', trackId=guid, parent=opts.parent, pos={x=0,y=0},
           ports={audio={ins=opts.ins or 0, outs=1}, midi={ins=0, outs=1}} }
end

local function fx(ident, opts)
  opts = opts or {}
  return { kind='fx', fxIdent=ident, fxId=opts.fxId, pos={x=0,y=0},
           ports={audio={ins=opts.ins or 1, outs=opts.outs or 1},
                  midi={ins=1, outs=1}} }
end

----- normal form — the witnessing bijection

-- node key -> rm id: the vertex map read realises (source=trackId, fx=fxId, sink='master').
local function rmId(id, n) return n.fxId or n.trackId or id end

-- Audio-semantic normal form: rm-id-keyed, bus/track/position dropped, ports defaulted to
-- read's conventions (audio fromPort 1, toPort 1 except into master, midi edges portless).
-- { kinds = {rmid->kind}, edges = sorted string[] }.
local function normalForm(g)
  local key, kinds = { master = 'master' }, { master = 'master' }
  for id, n in pairs(g.nodes) do
    key[id] = rmId(id, n)
    if n.kind ~= 'master' then kinds[key[id]] = n.kind end
  end
  local edges = {}
  for _, e in ipairs(g.edges) do
    local from, to = key[e.from] or e.from, key[e.to] or e.to
    if e.type == 'audio' then
      local toPort = (to == 'master') and '-' or (e.toPort or 1)
      local gain   = e.ops and e.ops.gain
      edges[#edges+1] = ('audio %s.%d->%s.%s%s'):format(
        from, e.fromPort or 1, to, toPort, gain and (' @' .. gain) or '')
    else
      edges[#edges+1] = ('midi %s->%s'):format(from, to)
    end
  end
  table.sort(edges)
  return { kinds = kinds, edges = edges }
end

-- Symmetric edge difference as two lists: read-only (phantoms compile adds), g-only (drops).
local function edgeDiff(readEdges, gEdges)
  local inG = {}
  for _, e in ipairs(gEdges)    do inG[e]    = (inG[e]    or 0) + 1 end
  local onlyRead = {}
  for _, e in ipairs(readEdges) do
    if (inG[e] or 0) > 0 then inG[e] = inG[e] - 1 else onlyRead[#onlyRead+1] = e end
  end
  local onlyG = {}
  for e, n in pairs(inG) do for _ = 1, n do onlyG[#onlyG+1] = e end end
  table.sort(onlyRead); table.sort(onlyG)
  return onlyRead, onlyG
end

-- Run one fixture through compile then read; assert the bijection up to declared diffs.
local function roundtrip(harness, fixture)
  local h, wm = mkWm(harness)
  if fixture.seed then fixture.seed(h) end
  local authored = { nodes = {}, edges = {} }
  fixture.build(authored)           -- a private copy for normalForm...
  wm:mutate(fixture.build)          -- ...the same structure loaded into wm to compile

  local nfG = normalForm(authored)
  local target = wm:targetState()
  -- The folder tree is REAPER-resident context (I_FOLDERDEPTH), not compile output; overlay it
  -- onto the target so read interprets each child's B_MAINSEND as a parent send.
  for childKey, parentGuid in pairs(fixture.tree or {}) do target[childKey].parent = parentGuid end
  -- A source's midi take is REAPER-resident too: in these graphs a source has a take iff its midi
  -- is consumed, so overlay hasMidiTake wherever the authored graph emits source midi.
  local emitsMidi = {}
  for _, e in ipairs(authored.edges) do if e.type == 'midi' then emitsMidi[e.from] = true end end
  for id, n in pairs(authored.nodes) do
    if n.kind == 'source' and emitsMidi[id] and target[rmId(id, n)] then
      target[rmId(id, n)].hasMidiTake = true
    end
  end
  local nfR = normalForm(wm.readGraph(target))
  t.deepEq(nfR.kinds, nfG.kinds, fixture.name .. ': node identity')
  local onlyRead, onlyG = edgeDiff(nfR.edges, nfG.edges)
  t.deepEq(onlyRead, fixture.expectExtra   or {}, fixture.name .. ': phantom edges')
  t.deepEq(onlyG,    fixture.expectMissing or {}, fixture.name .. ': dropped edges')
end

----- corpus — compile-driven, in-image graphs only

local corpus = {
  {
    name = 'generator chain s -midi-> syn -audio-> f2 -> master',
    seed = function(h) seedSource(h, 'guid-A') end,
    build = function(g)
      g.nodes.s   = source('guid-A')
      g.nodes.syn = fx('VST:Syn', { fxId='g-syn', ins=0, outs=1 })
      g.nodes.f2  = fx('VST:F2',  { fxId='g-f2' })
      util.add(g.edges, { type='midi',  from='s',   to='syn' })
      util.add(g.edges, { type='audio', from='syn', to='f2' })
      util.add(g.edges, { type='audio', from='f2',  to='master' })
    end,
  },
  {
    name = 'two sources -> fx -> master (parent-send merge)',
    seed = function(h) seedSource(h, 'guid-A'); seedSource(h, 'guid-B') end,
    build = function(g)
      g.nodes.sa = source('guid-A')
      g.nodes.sb = source('guid-B')
      g.nodes.f  = fx('VST:Mix', { fxId='g-f', ins=2, outs=1 })
      util.add(g.edges, { type='audio', from='sa', to='f' })
      util.add(g.edges, { type='audio', from='sb', to='f' })
      util.add(g.edges, { type='audio', from='f',  to='master' })
    end,
  },
  {
    name = 'audio source -> fx -> master',
    seed = function(h) seedSource(h, 'guid-A') end,
    build = function(g)
      g.nodes.s = source('guid-A')
      g.nodes.f = fx('VST:Lin', { fxId='g-f' })
      util.add(g.edges, { type='audio', from='s', to='f' })
      util.add(g.edges, { type='audio', from='f', to='master' })
    end,
  },
  {
    name = 'gained source -> fx, CU collapsed',
    seed = function(h) seedSource(h, 'guid-A') end,
    build = function(g)
      g.nodes.s = source('guid-A')
      g.nodes.f = fx('VST:F', { fxId='g-f' })
      util.add(g.edges, { type='audio', from='s', to='f', ops={gain=0.5} })
      util.add(g.edges, { type='audio', from='f', to='master' })
    end,
  },
  {
    name = 'sum-tree master fan-in, leaf gain',
    seed = function(h) seedSource(h, 'guid-A') end,
    build = function(g)
      g.nodes.s  = source('guid-A')
      g.nodes.f1 = fx('VST:F1', { fxId='g-f1' })
      g.nodes.f2 = fx('VST:F2', { fxId='g-f2' })
      util.add(g.edges, { type='audio', from='s',  to='f1' })
      util.add(g.edges, { type='audio', from='s',  to='f2' })
      util.add(g.edges, { type='audio', from='f1', to='master', ops={gain=0.7} })
      util.add(g.edges, { type='audio', from='f2', to='master' })
    end,
  },
  {
    name = 'same-track midi fan-in: s -> {A,B} -> C -> master',
    seed = function(h) seedSource(h, 'guid-A') end,
    build = function(g)
      g.nodes.s = source('guid-A')
      g.nodes.a = fx('VST:A', { fxId='g-A' })
      g.nodes.b = fx('VST:B', { fxId='g-B' })
      g.nodes.c = fx('VST:C', { fxId='g-C' })
      util.add(g.edges, { type='midi',  from='s', to='a' })
      util.add(g.edges, { type='midi',  from='s', to='b' })
      util.add(g.edges, { type='midi',  from='a', to='c' })
      util.add(g.edges, { type='midi',  from='b', to='c' })
      util.add(g.edges, { type='audio', from='c', to='master' })
    end,
  },
  {
    -- Audio+midi from one source into one fx: parallel stream edges round-trip clean. A single
    -- source keeps everything on its own track (inline + parent-send to master), so the midi
    -- survives — the master-resident drop does NOT fire on a single-source topology.
    name = 'audio+midi source -> fx -> master (parallel stream edges)',
    seed = function(h) seedSource(h, 'guid-A') end,
    build = function(g)
      g.nodes.s = source('guid-A')
      g.nodes.f = fx('VST:F', { fxId='g-f' })
      util.add(g.edges, { type='audio', from='s', to='f' })
      util.add(g.edges, { type='midi',  from='s', to='f' })
      util.add(g.edges, { type='audio', from='f', to='master' })
    end,
  },
  {
    -- Master-resident drop fixed ([[project_wiring_master_resident_midi_drop]]): receivesCrossConeMidi
    -- evicts C to its own newTrack so source→C midi survives; round-trip is now an exact bijection.
    name = 'master-resident: two midi sources -> shared C -> master',
    seed = function(h) seedSource(h, 'guid-A'); seedSource(h, 'guid-B') end,
    build = function(g)
      g.nodes.sa = source('guid-A')
      g.nodes.sb = source('guid-B')
      g.nodes.c  = fx('VST:C', { fxId='g-C', ins=0, outs=1 })
      util.add(g.edges, { type='midi',  from='sa', to='c' })
      util.add(g.edges, { type='midi',  from='sb', to='c' })
      util.add(g.edges, { type='audio', from='c',  to='master' })
    end,
  },
  {
    -- 65 producers fi each feed a distinct di: 65 pairs live at once, past the 64-pair ceiling.
    -- s2 anchors each di into its own class; compile bisects into emergent newTracks (read-invisible).
    name = 'capacity: 65-wide audio fan forces a bisection (read-invisible)',
    seed = function(h) seedSource(h, 'guid-A'); seedSource(h, 'guid-B') end,
    build = function(g)
      g.nodes.s  = source('guid-A')
      g.nodes.s2 = source('guid-B')
      for i = 1, 65 do
        local fi, di = 'f' .. i, 'd' .. i
        g.nodes[fi] = fx('VST:F' .. i, { fxId = 'g-f' .. i })
        g.nodes[di] = fx('VST:D' .. i, { fxId = 'g-d' .. i, ins = 2 })
        util.add(g.edges, { type='audio', from='s',  to=fi })
        util.add(g.edges, { type='audio', from=fi,  to=di, toPort=1 })
        util.add(g.edges, { type='audio', from='s2', to=di, toPort=2 })
        util.add(g.edges, { type='audio', from=di,  to='master' })
      end
    end,
  },
  {
    -- Floating island (option 3): srcSet-empty, lands on scratch; compile realises the intra edge
    -- there and read walks scratch as a bin (no source rule), so the island round-trips exactly.
    name = 'floating island: fa -audio-> fb (scratch-resident, sourceless)',
    build = function(g)
      g.nodes.fa = fx('VST:A', { fxId='g-A' })
      g.nodes.fb = fx('VST:B', { fxId='g-B' })
      util.add(g.edges, { type='audio', from='fa', to='fb' })
    end,
  },
  {
    -- Two disjoint islands co-resident on scratch must not cross-wire: lone fc stays edge-free
    -- even though it shares the scratch chain with the fa->fb island.
    name = 'two scratch islands: fa->fb and lone fc (isolation)',
    build = function(g)
      g.nodes.fa = fx('VST:A', { fxId='g-A' })
      g.nodes.fb = fx('VST:B', { fxId='g-B' })
      g.nodes.fc = fx('VST:C', { fxId='g-C' })
      util.add(g.edges, { type='audio', from='fa', to='fb' })
    end,
  },
  {
    -- MIDI floating island: read recovers the intra midi edge. The head (no midi-in) must have
    -- its input bus cleared so it never picks up a co-resident island's bus.
    name = 'floating midi island: fa -midi-> fb (scratch-resident)',
    build = function(g)
      g.nodes.fa = fx('VST:A', { fxId='g-A' })
      g.nodes.fb = fx('VST:B', { fxId='g-B' })
      util.add(g.edges, { type='midi', from='fa', to='fb' })
    end,
  },
  {
    -- Two midi islands co-resident on scratch must not cross-wire down the shared chain's buses.
    name = 'two scratch midi islands: fa->fb and fc->fd (bus isolation)',
    build = function(g)
      g.nodes.fa = fx('VST:A', { fxId='g-A' })
      g.nodes.fb = fx('VST:B', { fxId='g-B' })
      g.nodes.fc = fx('VST:C', { fxId='g-C' })
      g.nodes.fd = fx('VST:D', { fxId='g-D' })
      util.add(g.edges, { type='midi', from='fa', to='fb' })
      util.add(g.edges, { type='midi', from='fc', to='fd' })
    end,
  },

  ----- folder track parents (step 3a): conduit edge rides B_MAINSEND onto the parent.
  {
    name = 'folder: two children sum into parent -> master',
    seed = function(h) seedSource(h,'guid-A'); seedSource(h,'guid-B'); seedSource(h,'guid-P') end,
    tree = { ['guid-A']='guid-P', ['guid-B']='guid-P' },
    build = function(g)
      g.nodes.sa = source('guid-A', { parent='p' })
      g.nodes.sb = source('guid-B', { parent='p' })
      g.nodes.p  = source('guid-P', { ins=1 })
      util.add(g.edges, { type='audio', from='sa', to='p' })
      util.add(g.edges, { type='audio', from='sb', to='p' })
      util.add(g.edges, { type='audio', from='p',  to='master' })
    end,
  },
  {
    name = 'folder: gained conduit edge rides the parent-send volume',
    seed = function(h) seedSource(h,'guid-A'); seedSource(h,'guid-P') end,
    tree = { ['guid-A']='guid-P' },
    build = function(g)
      g.nodes.sa = source('guid-A', { parent='p' })
      g.nodes.p  = source('guid-P', { ins=1 })
      util.add(g.edges, { type='audio', from='sa', to='p', ops={gain=0.5} })
      util.add(g.edges, { type='audio', from='p',  to='master' })
    end,
  },
  {
    name = 'folder: parent hosting fx (source -> fx -> master)',
    seed = function(h) seedSource(h,'guid-A'); seedSource(h,'guid-P') end,
    tree = { ['guid-A']='guid-P' },
    build = function(g)
      g.nodes.sa = source('guid-A', { parent='p' })
      g.nodes.p  = source('guid-P', { ins=1 })
      g.nodes.eq = fx('VST:EQ', { fxId='g-eq' })
      util.add(g.edges, { type='audio', from='sa', to='p' })
      util.add(g.edges, { type='audio', from='p',  to='eq' })
      util.add(g.edges, { type='audio', from='eq', to='master' })
    end,
  },
  {
    name = 'folder: conduit + explicit send to a sibling fx coexist',
    seed = function(h) seedSource(h,'guid-A'); seedSource(h,'guid-B'); seedSource(h,'guid-P') end,
    tree = { ['guid-A']='guid-P' },
    build = function(g)
      g.nodes.sa  = source('guid-A', { parent='p' })
      g.nodes.sb  = source('guid-B')
      g.nodes.p   = source('guid-P', { ins=1 })
      g.nodes.mix = fx('VST:Mix', { fxId='g-mix', ins=2 })
      util.add(g.edges, { type='audio', from='sa',  to='p' })
      util.add(g.edges, { type='audio', from='sa',  to='mix', toPort=1 })
      util.add(g.edges, { type='audio', from='sb',  to='mix', toPort=2 })
      util.add(g.edges, { type='audio', from='mix', to='master' })
      util.add(g.edges, { type='audio', from='p',   to='master' })
    end,
  },
  {
    name = 'folder: nested parents chain leaf -> inner -> outer -> master',
    seed = function(h) seedSource(h,'guid-L'); seedSource(h,'guid-I'); seedSource(h,'guid-O') end,
    tree = { ['guid-L']='guid-I', ['guid-I']='guid-O' },
    build = function(g)
      g.nodes.leaf  = source('guid-L', { parent='inner' })
      g.nodes.inner = source('guid-I', { ins=1, parent='outer' })
      g.nodes.outer = source('guid-O', { ins=1 })
      util.add(g.edges, { type='audio', from='leaf',  to='inner' })
      util.add(g.edges, { type='audio', from='inner', to='outer' })
      util.add(g.edges, { type='audio', from='outer', to='master' })
    end,
  },
  {
    name = 'folder: child with mainSend off routes explicitly, not to its parent',
    seed = function(h) seedSource(h,'guid-A'); seedSource(h,'guid-B'); seedSource(h,'guid-C'); seedSource(h,'guid-P') end,
    tree = { ['guid-A']='guid-P', ['guid-B']='guid-P' },
    build = function(g)
      g.nodes.sa  = source('guid-A', { parent='p' })
      g.nodes.sb  = source('guid-B', { parent='p' })
      g.nodes.sc  = source('guid-C')
      g.nodes.p   = source('guid-P', { ins=1 })
      g.nodes.mix = fx('VST:Mix', { fxId='g-mix', ins=2 })
      util.add(g.edges, { type='audio', from='sa',  to='p' })
      util.add(g.edges, { type='audio', from='sb',  to='mix', toPort=1 })
      util.add(g.edges, { type='audio', from='sc',  to='mix', toPort=2 })
      util.add(g.edges, { type='audio', from='mix', to='master' })
      util.add(g.edges, { type='audio', from='p',   to='master' })
    end,
  },
}

local tests = {}
for _, fixture in ipairs(corpus) do
  tests[#tests+1] = { name = 'roundtrip: ' .. fixture.name,
                      run = function(harness) roundtrip(harness, fixture) end }
end
return tests
