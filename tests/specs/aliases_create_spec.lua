-- Phase 4: alias-mode creation. copy/duplicate in alias mode tag the
-- clip; pasteAlias creates spec nodes via tm:createAlias rather than
-- writing fresh events. Successive duplicates re-paste the cached clip
-- so the source stays anchored.

local t = require('support')

local function rootNote(extras)
  local n = { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, uuid = 1, ppqL = 0, endppqL = 240 }
  for k, v in pairs(extras) do n[k] = v end
  return n
end

local function rootByUuid(notes, uuid)
  for _, n in ipairs(notes) do if n.uuid == uuid then return n end end
end

local function logPerRow(h)
  -- rowPerBeat=1, resolution=240 → one row per beat = 240 PPQ.
  return h.tm:resolution() / h.cm:get('rowPerBeat')
end

return {
  --------------------------------------------------------------------
  -- copy + paste at +N rows: one top-level spec under source root
  --------------------------------------------------------------------
  {
    name = 'alias-mode copy + paste creates a top-level spec under source',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{} } },
      }
      h.vm:setGridSize(80, 40)
      local lpr = logPerRow(h)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')
      h.ec:setPos(4, 1, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.truthy(root, 'root present')
      t.eq(#root.aliases, 1, 'one spec node added')
      local node = root.aliases[1]
      t.deepEq(node.xform.ppqL, {{'add', 4 * lpr}}, '+4 logical rows')
      t.eq(#node.children, 0)
      t.eq(root.pitch, 60, 'root pitch unchanged')
    end,
  },

  --------------------------------------------------------------------
  -- alias-mode duplicate down on a plain note → top-level spec
  --------------------------------------------------------------------
  {
    name = 'alias-mode duplicateDown on plain note creates top-level spec',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{} } },
      }
      h.vm:setGridSize(80, 40)
      local lpr = logPerRow(h)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('duplicateDown')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(#root.aliases, 1)
      t.deepEq(root.aliases[1].xform.ppqL, {{'add', lpr}}, '+1 row')
    end,
  },

  --------------------------------------------------------------------
  -- alias-mode duplicate of an already-aliased event creates a CHILD
  -- of the source's spec node, not a top-level sibling.
  --------------------------------------------------------------------
  {
    name = 'alias-mode duplicateDown on aliased child creates child spec',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      local lpr = logPerRow(h)
      h.ec:setPos(1, 1, 1)                       -- on materialised alias '1' at row 1
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('duplicateDown')             -- collects alias source, pastes at row 2

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(#root.aliases, 1, 'top-level still 1')
      local one = root.aliases[1]
      t.eq(#one.children, 1, 'child created under source spec')
      t.deepEq(one.children[1].xform.ppqL,
               {{'add', lpr}}, '+1 row relative to source ppqL')
    end,
  },

  --------------------------------------------------------------------
  -- Successive immediate duplicates from a plain source: cache-anchored;
  -- all pastes write top-level siblings under the original root, with
  -- progressive offsets relative to source ppqL=0.
  --------------------------------------------------------------------
  {
    name = 'three immediate duplicates create three top-level siblings',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{} } },
      }
      h.vm:setGridSize(80, 40)
      local lpr = logPerRow(h)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('duplicateDown')
      h.cmgr:invoke('duplicateDown')
      h.cmgr:invoke('duplicateDown')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(#root.aliases, 3, 'three top-level specs')
      t.deepEq(root.aliases[1].xform.ppqL, {{'add', 1 * lpr}})
      t.deepEq(root.aliases[2].xform.ppqL, {{'add', 2 * lpr}})
      t.deepEq(root.aliases[3].xform.ppqL, {{'add', 3 * lpr}})
      for _, n in ipairs(root.aliases) do
        t.eq(#n.children, 0, 'no child specs (cache-anchored, top-level only)')
      end
    end,
  },

  --------------------------------------------------------------------
  -- Any non-duplicate command between duplicates clears dupeClip,
  -- forcing the next duplicate to re-collect from current selection.
  -- selectClear is chosen because it doesn't move the cursor — the
  -- second duplicate stays on the materialised alias from the first.
  --------------------------------------------------------------------
  {
    name = 'intervening command clears dupeClip; next duplicate re-collects',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{} } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('duplicateDown')             -- spec '1' at +1 row; cursor → row 1
      h.cmgr:invoke('selectClear')               -- intervening: clears cache, no cursor move
      h.cmgr:invoke('duplicateDown')             -- re-collects from row 1 (materialised '1')

      local root = rootByUuid(h.fm:dump().notes, 1)
      -- After re-collect, source carries specPath='1' → child of '1'.
      t.eq(#root.aliases, 1, 'still one top-level spec')
      t.eq(#root.aliases[1].children, 1, 'child created under "1" after re-collect')
    end,
  },

  --------------------------------------------------------------------
  -- Tail-fit at the paste site: when a spanning source's tail would
  -- overlap a same-column successor, the spec carries no corrective
  -- durL — only ppqL for the row offset and `fit = true` so rebuild
  -- shortens the materialised alias's endppq to the successor's ppq.
  -- Duration stays structural (follows the parent); changing the
  -- parent's durL re-derives the alias's full span on next rebuild.
  --------------------------------------------------------------------
  {
    name = 'alias paste of spanning note: spec is fit, not a durL delta',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = {
          length = 240 * 16,
          notes = {
            rootNote{ ppq = 0, endppq = 240*4, ppqL = 0, endppqL = 240*4 },
            { ppq = 240*7, endppq = 240*8, ppqL = 240*7, endppqL = 240*8,
              chan = 1, pitch = 60, vel = 100, uuid = 2, lane = 1 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      local lpr = logPerRow(h)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')
      h.ec:setPos(5, 1, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(#root.aliases, 1)
      local node = root.aliases[1]
      t.deepEq(node.xform.ppqL, {{'add', 5 * lpr}}, '+5 rows')
      t.falsy(node.xform.durL, 'no corrective durL on the spec')
      t.eq(node.fit, true, 'fit set; rebuild handles the visual clip')
    end,
  },

  --------------------------------------------------------------------
  -- Region clear: alias paste wipes pre-existing events in the
  -- destination column the same way plain paste does.
  --------------------------------------------------------------------
  {
    name = 'alias paste clears pre-existing events in destination region',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = {
          rootNote{},                                                          -- uuid=1, row 0
          { ppq = 240*4, endppq = 240*5, ppqL = 240*4, endppqL = 240*5,
            chan = 1, pitch = 60, vel = 100, uuid = 2, lane = 1 },             -- victim @ row 4
        } },
      }
      h.vm:setGridSize(80, 40)
      local lpr = logPerRow(h)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')
      h.ec:setPos(4, 1, 1)
      h.cmgr:invoke('paste')

      -- Victim deleted; alias spec node added under root 1.
      local notes = h.fm:dump().notes
      local stillVictim
      for _, n in ipairs(notes) do if n.uuid == 2 then stillVictim = n end end
      t.falsy(stillVictim, 'pre-existing note in destination range deleted')
      local root = rootByUuid(notes, 1)
      t.eq(#root.aliases, 1, 'one spec node added')
      t.deepEq(root.aliases[1].xform.ppqL, {{'add', 4 * lpr}})
    end,
  },

  --------------------------------------------------------------------
  -- chan delta: paste across channels encodes chan = +N. The source's
  -- chan/lane come from the column at copy time, not the surfaced event
  -- (tm projection strips both); this regression pins that wiring.
  --------------------------------------------------------------------
  {
    name = 'alias paste cross-channel encodes chan delta',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = {
          rootNote{},                                                   -- chan 1
          { ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
            chan = 3, pitch = 60, vel = 100, uuid = 2, lane = 1 },      -- placeholder so chan 3 cols exist
        } },
      }
      h.vm:setGridSize(80, 40)
      local lpr = logPerRow(h)

      local dstCol
      for i, col in ipairs(h.vm.grid.cols) do
        if col.type == 'note' and col.midiChan == 3 and col.lane == 1 then
          dstCol = i; break
        end
      end
      t.truthy(dstCol, 'chan 3 lane 1 note col exists')

      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')
      h.ec:setPos(4, dstCol, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(#root.aliases, 1)
      local node = root.aliases[1]
      t.deepEq(node.xform.ppqL, {{'add', 4 * lpr}}, '+4 rows')
      t.deepEq(node.xform.chan, {{'add', 2}}, '+2 channels')
    end,
  },

  --------------------------------------------------------------------
  -- lane delta: paste across lanes within the same channel encodes
  -- lane = +N. Two simultaneous same-pitch notes force two lanes.
  --------------------------------------------------------------------
  {
    name = 'alias paste cross-lane encodes lane delta',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = {
          rootNote{},                                                   -- chan 1 lane 1
          { ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
            chan = 1, pitch = 60, vel = 100, uuid = 2, lane = 2 },      -- forces lane 2
        } },
      }
      h.vm:setGridSize(80, 40)
      local lpr = logPerRow(h)

      local dstCol
      for i, col in ipairs(h.vm.grid.cols) do
        if col.type == 'note' and col.midiChan == 1 and col.lane == 2 then
          dstCol = i; break
        end
      end
      t.truthy(dstCol, 'chan 1 lane 2 note col exists')

      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')
      h.ec:setPos(4, dstCol, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(#root.aliases, 1)
      local node = root.aliases[1]
      t.deepEq(node.xform.ppqL, {{'add', 4 * lpr}}, '+4 rows')
      t.eq(node.xform.chan, nil, 'no chan delta')
      t.deepEq(node.xform.lane, {{'add', 1}}, '+1 lane')
    end,
  },

  --------------------------------------------------------------------
  -- Default alias paste is leaf-only: pasting a root that already has
  -- children produces a new spec node with no descendants of its own.
  -- The existing subtree is left in place untouched.
  --------------------------------------------------------------------
  {
    name = 'alias paste of a root with children: default paste is leaf-only',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      local lpr = logPerRow(h)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')
      h.ec:setPos(8, 1, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(#root.aliases, 2, 'two top-level: original + new')
      local existing, fresh = root.aliases[1], root.aliases[2]
      t.deepEq(existing.xform.ppqL, {{'add', 240}}, 'existing untouched')
      t.eq(#existing.children, 0)
      t.deepEq(fresh.xform.ppqL, {{'add', 8 * lpr}}, 'new node anchored at paste row')
      t.eq(#fresh.children, 0, 'new node is a leaf')
    end,
  },

  --------------------------------------------------------------------
  -- Default leaf-only paste of a materialised child: a new spec node
  -- is created as a sibling of the source, with no descendants. The
  -- source's own descendants stay where they are.
  --------------------------------------------------------------------
  {
    name = 'alias paste of a materialised child: default paste is leaf-only',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{
          aliasCtr = 4,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {
              { id = '2', xform = { ppqL = {{'add', 240}} }, children = {
                { id = '3', xform = { ppqL = {{'add', 240}} }, children = {} },
              } },
            } },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      local lpr = logPerRow(h)
      h.ec:setPos(2, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')
      h.ec:setPos(6, 1, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      local twelve = root.aliases[1].children[1]
      t.eq(#twelve.children, 2, 'original "1.2.3" plus the new sibling')
      local fresh
      for _, c in ipairs(twelve.children) do if c.id == '4' then fresh = c end end
      t.truthy(fresh, 'new spec node "1.2.4" allocated')
      t.deepEq(fresh.xform.ppqL, {{'add', 4 * lpr}},
               '+4 rows relative to source ppqL=2*lpr')
      t.eq(#fresh.children, 0, 'new sibling is a leaf — descendants of the source not carried')
    end,
  },


  --------------------------------------------------------------------
  -- (2) Root field drift: root's pitch was edited between copy and
  -- paste. The paste resolves liveSrc through the (now-mutated) root
  -- and emits a corrective xform.pitch that makes the alias materialise
  -- at the captured pitch. Silent — the user just dragged the root.
  --------------------------------------------------------------------
  {
    name = 'alias paste after root pitch drift: corrective xform lands the captured pitch',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{ pitch = 60 } } },
      }
      h.vm:setGridSize(80, 40)
      local lpr = logPerRow(h)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')

      local rootLoc
      for loc, n in h.fm:notes() do if n.uuid == 1 then rootLoc = loc end end
      h.fm:modify(function() h.fm:assignNote(rootLoc, { pitch = 64 }) end)

      h.ec:setPos(4, 1, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(root.pitch, 64, 'root keeps its mutated pitch')
      t.eq(#root.aliases, 1, 'spec written')
      t.deepEq(root.aliases[1].xform.ppqL,  {{'add', 4 * lpr}}, 'row delta')
      t.deepEq(root.aliases[1].xform.pitch, {{'add', -4}},
               'corrective: 60 (captured) − 64 (live) = −4')
      t.eq(#h.reaper._state.messages, 0, 'silent — root drift is corrected')
    end,
  },

  --------------------------------------------------------------------
  -- (2) Leaf xform edited between copy and paste: the leaf is the
  -- source itself, so editing it is supported. Live resolution sees
  -- the new xform; the paste's delta is computed against that, so
  -- the new sibling lands at the captured paste-row. No warning.
  --------------------------------------------------------------------
  {
    name = 'alias paste after leaf xform edit: delta tracks live leaf, no warning',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      local lpr = logPerRow(h)
      h.ec:setPos(1, 1, 1)                       -- on materialised '1' at row 1
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')

      -- Edit the leaf: '1' now resolves at row 2 instead of row 1.
      local rootLoc
      for loc, n in h.fm:notes() do if n.uuid == 1 then rootLoc = loc end end
      h.fm:modify(function()
        h.fm:assignNote(rootLoc, { aliases = {
          { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
        } })
      end)

      h.ec:setPos(5, 1, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(#root.aliases, 1, 'still one top-level')
      t.eq(#root.aliases[1].children, 1, 'new child under leaf')
      t.deepEq(root.aliases[1].children[1].xform.ppqL, {{'add', 3 * lpr}},
               'delta against liveSrc (row 2) → paste lands at row 5')
      t.eq(#h.reaper._state.messages, 0, 'silent — leaf edit is supported')
    end,
  },

  --------------------------------------------------------------------
  -- (2) Ancestor xform edited between copy and paste: the user
  -- changed structure above the source. We can't safely encode that
  -- as an opaque correction, so demote to plain and surface a warning.
  --------------------------------------------------------------------
  {
    name = 'alias paste after ancestor xform edit: loud demote with warning',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{
          aliasCtr = 3,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {
              { id = '2', xform = { ppqL = {{'add', 240}} }, children = {} },
            } },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(2, 1, 1)                       -- on materialised '1.2'
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')

      local rootLoc
      for loc, n in h.fm:notes() do if n.uuid == 1 then rootLoc = loc end end
      h.fm:modify(function()
        h.fm:assignNote(rootLoc, { aliases = {
          { id = '1', xform = { ppqL = {{'add', 480}} }, children = {
            { id = '2', xform = { ppqL = {{'add', 240}} }, children = {} },
          } },
        } })
      end)

      h.ec:setPos(8, 1, 1)
      h.cmgr:invoke('paste')

      local notes = h.fm:dump().notes
      local plain
      for _, n in ipairs(notes) do
        if not n.aliases and not n.parentUuid then plain = n end
      end
      t.truthy(plain, 'plain paste landed')

      local msgs = h.reaper._state.messages
      t.eq(#msgs, 1, 'one warning surfaced')
      t.truthy(msgs[1].msg:find('1 event'),  'count present')
      t.truthy(msgs[1].msg:find('spec tree'), 'message names the cause')
    end,
  },

  --------------------------------------------------------------------
  -- cut in alias mode: the clip is tagged aliased, but the source is
  -- gone by paste time, so byUuid fails and aliasWriter falls back to
  -- a plain write — the deletion-fallback covers cut without a
  -- copy-time special-case.
  --------------------------------------------------------------------
  {
    name = 'cut in alias mode: source deleted, paste demotes to plain',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{} } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('cut')
      h.ec:setPos(4, 1, 1)
      h.cmgr:invoke('paste')

      local notes = h.fm:dump().notes
      t.eq(#notes, 1, 'source deleted; one fresh paste')
      t.falsy(rootByUuid(notes, 1), 'original root gone')
      t.falsy(notes[1].aliases, 'no spec tree on the pasted note')
      t.falsy(notes[1].parentUuid, 'paste is a plain note, not an alias child')
    end,
  },

  --------------------------------------------------------------------
  -- Source root deleted between copy and paste: same fallback path,
  -- just reached by direct deletion rather than by cut.
  --------------------------------------------------------------------
  {
    name = 'alias copy then root deleted: paste falls back to plain',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{} } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')

      local rootLoc
      for loc, n in h.fm:notes() do
        if n.uuid == 1 then rootLoc = loc end
      end
      h.fm:modify(function() h.fm:deleteNote(rootLoc) end)

      h.ec:setPos(4, 1, 1)
      h.cmgr:invoke('paste')

      local notes = h.fm:dump().notes
      t.eq(#notes, 1, 'only the pasted note survives')
      t.falsy(notes[1].aliases, 'no spec tree')
      t.falsy(notes[1].parentUuid, 'plain note')
      t.eq(#h.reaper._state.messages, 0, '(A)-class demotion is silent')
    end,
  },

  --------------------------------------------------------------------
  -- Source spec node deleted between copy and paste: byUuid finds the
  -- root but aliases.find misses, so createAlias returns nil and the
  -- writer demotes to plain.
  --------------------------------------------------------------------
  {
    name = 'alias copy of child then spec deleted: paste falls back to plain',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(1, 1, 1)                       -- on materialised '1'
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')

      local rootLoc
      for loc, n in h.fm:notes() do
        if n.uuid == 1 then rootLoc = loc end
      end
      h.fm:modify(function() h.fm:assignNote(rootLoc, { aliases = {} }) end)

      h.ec:setPos(6, 1, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(#root.aliases, 0, 'spec tree still empty')
      local plain
      for _, n in ipairs(h.fm:dump().notes) do
        if not n.aliases and not n.parentUuid then plain = n end
      end
      t.truthy(plain, 'plain paste landed')
      t.eq(plain.pitch, 60, 'pasted note carries source pitch')
    end,
  },

  --------------------------------------------------------------------
  -- Plain copy of a root with alias children: the pasted event is a
  -- fresh, independent plain note. The source's spec tree does not ride
  -- through — aliased propagation is alias-mode-only.
  --------------------------------------------------------------------
  {
    name = 'plain copy of a root with aliases: paste is plain, no spec inherited',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('copy')                      -- alias mode OFF
      h.ec:setPos(8, 1, 1)
      h.cmgr:invoke('paste')

      local roots, plains = {}, {}
      for _, n in ipairs(h.fm:dump().notes) do
        if n.aliases       then roots[#roots+1]   = n
        elseif not n.parentUuid then plains[#plains+1] = n end
      end
      t.eq(#roots, 1, 'only the source carries a spec tree')
      t.eq(roots[1].uuid, 1, 'source root unchanged')
      t.eq(#plains, 1, 'one fresh plain paste')
      t.falsy(plains[1].aliases,    'paste has no aliases')
      t.falsy(plains[1].aliasCtr,   'paste has no aliasCtr')
      t.falsy(plains[1].parentUuid, 'paste is a top-level note')
    end,
  },

  --------------------------------------------------------------------
  -- alias-mode off: copy/paste behaves identically to today; no aliases.
  --------------------------------------------------------------------
  {
    name = 'alias mode off: copy/paste writes plain events; no spec written',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{} } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('copy')                      -- alias mode is OFF
      h.ec:setPos(4, 1, 1)
      h.cmgr:invoke('paste')

      local notes = h.fm:dump().notes
      t.eq(#notes, 2, 'one source + one fresh paste')
      local root = rootByUuid(notes, 1)
      t.falsy(root.aliases, 'no spec tree on root')
    end,
  },

  --------------------------------------------------------------------
  -- Family copy: A (root) + B (materialised child of A) selected
  -- together. At paste, C (top-level alias of A) is created and D is
  -- attached *under C*, not as a sibling of B. D's xform is the captured
  -- pathXform from A's specPath to B's — preserved verbatim, including
  -- producing-ops along the live spec tree at copy.
  --------------------------------------------------------------------
  {
    name = 'family alias-paste: A + child B → C top-level + D attached under C',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      local lpr = logPerRow(h)
      h.ec:setSelection{ row1=0, row2=1, col1=1, col2=1, part1='pitch', part2='pitch' }
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')
      h.ec:setPos(8, 1, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(#root.aliases, 2, 'two top-level: original + new C')
      local C = root.aliases[2]
      t.deepEq(C.xform.ppqL, {{'add', 8 * lpr}}, 'C anchored at paste row')
      t.eq(#C.children, 1, 'D attached under C, not as sibling of B')
      t.deepEq(C.children[1].xform.ppqL, {{'add', 240}},
               'D xform = captured pathXform from A to B')
      t.eq(#h.reaper._state.messages, 0, 'silent — structural family paste')
    end,
  },

  --------------------------------------------------------------------
  -- Three-level family: A + B + B's child Z. Each child attaches under
  -- its in-clip parent's freshly-pasted spec node, with the captured
  -- single-segment xform.
  --------------------------------------------------------------------
  {
    name = 'family alias-paste 3-level: A + B + grandchild attach under each pasted parent',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{
          aliasCtr = 3,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {
              { id = '2', xform = { ppqL = {{'add', 240}} }, children = {} },
            } },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      local lpr = logPerRow(h)
      h.ec:setSelection{ row1=0, row2=2, col1=1, col2=1, part1='pitch', part2='pitch' }
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')
      h.ec:setPos(10, 1, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(#root.aliases, 2, 'two top-level: original + new C')
      local C = root.aliases[2]
      t.deepEq(C.xform.ppqL, {{'add', 10 * lpr}}, 'C anchored at paste row')
      t.eq(#C.children, 1, 'D under C')
      local D = C.children[1]
      t.deepEq(D.xform.ppqL, {{'add', 240}}, "D xform = captured '1' segment")
      t.eq(#D.children, 1, 'Z under D')
      t.deepEq(D.children[1].xform.ppqL, {{'add', 240}}, "Z xform = captured '1.2' segment")
    end,
  },

  --------------------------------------------------------------------
  -- Family + root deletion: A demotes to plain C; D still attaches as
  -- a top-level alias of C (post-flush, once mm has assigned C's uuid
  -- and written it back into the caller's evt). Silent — A-class demote.
  --------------------------------------------------------------------
  {
    name = 'family alias-paste: root deleted between copy and paste → C plain, D top-level alias of C',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setSelection{ row1=0, row2=1, col1=1, col2=1, part1='pitch', part2='pitch' }
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')

      local rootLoc
      for loc, n in h.fm:notes() do if n.uuid == 1 then rootLoc = loc end end
      h.fm:modify(function() h.fm:deleteNote(rootLoc) end)

      h.ec:setPos(8, 1, 1)
      h.cmgr:invoke('paste')

      -- After paste, the rebuild walker materialises D from C's aliases as
      -- a plain note with parentUuid=C.uuid; dump shows both C (the demoted
      -- root, carrying the aliases list) and the materialised D.
      local notes = h.fm:dump().notes
      local C, D
      for _, n in ipairs(notes) do
        if not n.parentUuid then C = n else D = n end
      end
      t.truthy(C, 'C exists as a plain root')
      t.truthy(D, 'D materialised under C')
      t.truthy(C.aliases, 'C carries an aliases list')
      t.eq(#C.aliases, 1, 'one top-level alias under C')
      t.deepEq(C.aliases[1].xform.ppqL, {{'add', 240}},
               'alias under C = captured pathXform from A to B')
      t.eq(D.parentUuid, C.uuid, 'D parented at C')
      t.eq(#h.reaper._state.messages, 0, 'silent — A-class demote')
    end,
  },

  --------------------------------------------------------------------
  -- Capture-at-copy is structural: editing the leaf xform between copy
  -- and paste does not leak into the family child's xform (which was
  -- snapshotted at copy).
  --------------------------------------------------------------------
  {
    name = 'family alias-paste: leaf xform edited after copy — paste uses captured xform',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setSelection{ row1=0, row2=1, col1=1, col2=1, part1='pitch', part2='pitch' }
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')

      local rootLoc
      for loc, n in h.fm:notes() do if n.uuid == 1 then rootLoc = loc end end
      h.fm:modify(function()
        h.fm:assignNote(rootLoc, {
          aliases = {
            { id = '1', xform = { ppqL = {{'add', 480}} }, children = {} },
          },
        })
      end)

      h.ec:setPos(8, 1, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      local C = root.aliases[2]
      t.eq(#C.children, 1, 'D under C')
      t.deepEq(C.children[1].xform.ppqL, {{'add', 240}},
               "D xform pinned to copy-time '1'.xform (240), not the live edit (480)")
      t.eq(#h.reaper._state.messages, 0, 'silent — capture-at-copy bypasses drift detection')
    end,
  },

  --------------------------------------------------------------------
  -- fit flag: paste-created spec nodes carry fit=true so rebuild
  -- clips them at the next same-column event. Manual createAlias
  -- callers (anything outside the paste path) leave fit unset.
  --------------------------------------------------------------------
  {
    name = 'alias-mode paste sets fit=true on the new spec node',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{} } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')
      h.ec:setPos(4, 1, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(root.aliases[1].fit, true, 'paste-created spec node carries fit')
    end,
  },

  {
    name = 'family alias-paste sets fit=true on every newly-created node',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{
          aliasCtr = 2,
          aliases  = {
            { id = '1', xform = { ppqL = {{'add', 240}} }, children = {} },
          },
        } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setSelection{ row1=0, row2=1, col1=1, col2=1, part1='pitch', part2='pitch' }
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')
      h.ec:setPos(8, 1, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      local C = root.aliases[2]
      t.eq(C.fit, true, 'pasted root C has fit')
      t.eq(C.children[1].fit, true, 'pasted child D has fit')
    end,
  },

  {
    name = 'alias-mode paste no longer encodes a corrective durL op when destination triggers tail clamp',
    run = function(harness)
      -- Source root spans rows 0..3 (durL = 3*240). Destination row 4 has
      -- a plain at row 6, so under today's tail-clamp the paste would
      -- shorten the alias's endppqL to row 6 and writeAsRoot would emit a
      -- durL `add` op. Under fit semantics the spec carries no durL op;
      -- rebuild handles the visual clip.
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = {
          length = 6000,
          notes  = {
            { uuid = 1, ppq = 0, endppq = 3*240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, ppqL = 0, endppqL = 3*240, lane = 1 },
            { uuid = 2, ppq = 6*240, endppq = 7*240, chan = 1, pitch = 64, vel = 100,
              detune = 0, delay = 0, ppqL = 6*240, endppqL = 7*240, lane = 1 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('toggleAliasMode')
      h.cmgr:invoke('copy')
      h.ec:setPos(4, 1, 1)
      h.cmgr:invoke('paste')

      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(#root.aliases, 1, 'one spec node added')
      local node = root.aliases[1]
      t.eq(node.fit, true, 'fit set on the new spec node')
      t.falsy(node.xform.durL, 'no corrective durL op')
      t.deepEq(node.xform.ppqL, {{'add', 4 * 240}}, 'ppqL row offset preserved')
    end,
  },

  {
    name = 'manual tm:createAlias does not set fit',
    run = function(harness)
      local h = harness.mk{
        config = { track = { rowPerBeat = 1 } },
        seed   = { notes = { rootNote{} } },
      }
      h.tm:createAlias(1, nil, { ppqL = {{'add', 240}} })
      h.tm:flush()
      local root = rootByUuid(h.fm:dump().notes, 1)
      t.eq(#root.aliases, 1)
      t.falsy(root.aliases[1].fit, 'no fit on manually-created spec node')
    end,
  },
}
