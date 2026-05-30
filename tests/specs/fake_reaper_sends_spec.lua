local t   = require('support')
local FR  = require('fakeReaper')

local function mk()
  local r = FR.new()
  local a, b, c = { 'A' }, { 'B' }, { 'C' }
  r:setProjectTracks({ a, b, c })
  return r, a, b, c
end

return {
  {
    name = 'B_MAINSEND defaults to 1 (REAPER parity)',
    run = function()
      local r, a = mk()
      t.eq(r.GetMediaTrackInfo_Value(a, 'B_MAINSEND'), 1)
      r.SetMediaTrackInfo_Value(a, 'B_MAINSEND', 0)
      t.eq(r.GetMediaTrackInfo_Value(a, 'B_MAINSEND'), 0)
    end,
  },
  {
    name = 'TrackFX_GetFXGUID is per-(track,fxIdx), stable across reads',
    run = function()
      local r, a = mk()
      r.TrackFX_AddByName(a, 'JS:foo')
      r.TrackFX_AddByName(a, 'JS:bar')
      local g0a = r.TrackFX_GetFXGUID(a, 0)
      local g0b = r.TrackFX_GetFXGUID(a, 0)
      local g1  = r.TrackFX_GetFXGUID(a, 1)
      t.eq(g0a, g0b)
      t.truthy(g0a ~= g1, 'fx guid distinct per fxIdx')
    end,
  },
  {
    name = 'setFxGuid two-arg legacy form pins fxIdx 0',
    run = function()
      local r, a = mk()
      r:setFxGuid(a, '{pinned}')
      t.eq(r.TrackFX_GetFXGUID(a, 0), '{pinned}')
    end,
  },
  {
    name = 'setFxGuid three-arg pins a specific fxIdx',
    run = function()
      local r, a = mk()
      r:setFxGuid(a, 2, '{at-two}')
      t.eq(r.TrackFX_GetFXGUID(a, 2), '{at-two}')
      t.truthy(r.TrackFX_GetFXGUID(a, 0) ~= '{at-two}', 'idx 0 not pinned')
    end,
  },
  {
    name = 'no sends: counts and reads return 0',
    run = function()
      local r, a = mk()
      t.eq(r.GetTrackNumSends(a, 0),  0)
      t.eq(r.GetTrackNumSends(a, -1), 0)
      t.eq(r.GetTrackSendInfo_Value(a, 0, 0, 'P_DESTTRACK'), 0)
    end,
  },
  {
    name = 'addSend default (both): srcChan=0, midiFlags=0; P_DESTTRACK reads back',
    run = function()
      local r, a, b = mk()
      r:addSend(a, b)
      t.eq(r.GetTrackNumSends(a, 0), 1)
      t.eq(r.GetTrackSendInfo_Value(a, 0, 0, 'P_DESTTRACK'), b)
      t.eq(r.GetTrackSendInfo_Value(a, 0, 0, 'I_SRCCHAN'),   0)
      t.eq(r.GetTrackSendInfo_Value(a, 0, 0, 'I_MIDIFLAGS'), 0)
    end,
  },
  {
    name = "addSend type='audio': midiFlags=31 (MIDI disabled), srcChan=0",
    run = function()
      local r, a, b = mk()
      r:addSend(a, b, { type = 'audio' })
      t.eq(r.GetTrackSendInfo_Value(a, 0, 0, 'I_SRCCHAN'),   0)
      t.eq(r.GetTrackSendInfo_Value(a, 0, 0, 'I_MIDIFLAGS'), 31)
    end,
  },
  {
    name = "addSend type='midi': srcChan=-1 (audio disabled), midiFlags=0",
    run = function()
      local r, a, b = mk()
      r:addSend(a, b, { type = 'midi' })
      t.eq(r.GetTrackSendInfo_Value(a, 0, 0, 'I_SRCCHAN'),   -1)
      t.eq(r.GetTrackSendInfo_Value(a, 0, 0, 'I_MIDIFLAGS'),  0)
    end,
  },
  {
    name = 'receives (category=-1) are derived: count and reads',
    run = function()
      local r, a, b, c = mk()
      r:addSend(a, c, { type = 'audio' })
      r:addSend(b, c, { type = 'midi'  })
      t.eq(r.GetTrackNumSends(c, -1), 2)
      -- Receives are walked in send-list iteration order; the spec only pins
      -- that both src tracks appear and the parm decoding is symmetric.
      local srcs = {}
      for i = 0, 1 do
        srcs[r.GetTrackSendInfo_Value(c, -1, i, 'P_SRCTRACK')] = true
      end
      t.eq(srcs[a], true)
      t.eq(srcs[b], true)
    end,
  },
  {
    name = 'multiple sends on one track preserve insertion order',
    run = function()
      local r, a, b, c = mk()
      r:addSend(a, b)
      r:addSend(a, c)
      t.eq(r.GetTrackNumSends(a, 0), 2)
      t.eq(r.GetTrackSendInfo_Value(a, 0, 0, 'P_DESTTRACK'), b)
      t.eq(r.GetTrackSendInfo_Value(a, 0, 1, 'P_DESTTRACK'), c)
    end,
  },
  {
    name = 'send D_VOL defaults to 1.0 and round-trips; I_SENDMODE defaults 0',
    run = function()
      local r, a, b = mk()
      r:addSend(a, b, { type = 'audio' })
      t.eq(r.GetTrackSendInfo_Value(a, 0, 0, 'D_VOL'), 1.0, 'REAPER-parity unity default')
      t.eq(r.GetTrackSendInfo_Value(a, 0, 0, 'I_SENDMODE'), 0)
      r.SetTrackSendInfo_Value(a, 0, 0, 'D_VOL', 0.5)
      r.SetTrackSendInfo_Value(a, 0, 0, 'I_SENDMODE', 3)
      t.eq(r.GetTrackSendInfo_Value(a, 0, 0, 'D_VOL'), 0.5)
      t.eq(r.GetTrackSendInfo_Value(a, 0, 0, 'I_SENDMODE'), 3)
    end,
  },
}
