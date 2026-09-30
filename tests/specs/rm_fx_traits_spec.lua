-- routingManager stamps every fx record it reads with its plugin's resolved
-- traits (docs/fxCatalogue.md § Traits). An instance keys by the installed row
-- its ident matches, so a trait authored under that key reaches it whatever
-- '<id{hex' the instance's ident carries, a shell file's member included; the instrument mark reads from the
-- instance's reported fx_type; a JSFX resolves through its source's parse.
local t       = require('support')
local harness = require('harness')
local util    = require('util')

local VST3DIR = '/Library/Audio/Plug-Ins/VST3/'

-- Real (installed ident, instance ident) pairs, probed 2026-09-30.
local EQ = { name = 'VST3: 8K (Canvas Audio)', installed = VST3DIR .. 'Effects/EQ/Canvas Audio - 8K.vst3',
             fxType = 'VST3',
             instance = VST3DIR .. 'Effects/EQ/Canvas Audio - 8K.vst3<1886275761{ABCDEF019182FAEB436E764F4B636444',
             key = 'Canvas_Audio___8K.vst3' }
-- A shell file's member: its installed key keeps the '<id', so only the installed walk finds it.
local ELASTIKA = { name = 'VST3: Elastika (Sapphire)', installed = VST3DIR .. 'Effects/Filter/Sapphire.vst3<739473316',
                   fxType = 'VST3',
                   instance = VST3DIR .. 'Effects/Filter/Sapphire.vst3<739473316{8135F27069395E078A8B52BA702088D7',
                   key = 'Sapphire.vst3<739473316' }
local AEOLUS = { name = 'VST3i: Aeolus (Arthur Benilov)', installed = VST3DIR .. 'Generators/Keys/Aeolus.vst3',
                 fxType = 'VST3i',
                 instance = VST3DIR .. 'Generators/Keys/Aeolus.vst3<1667713279{ABCDEF019182FAEB4172626545366865',
                 key = 'Aeolus.vst3' }

-- One track 'T' carrying the given plugins, each installed; returns rm, the track and its guid.
local function seedChain(plugins, entries)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local installed, chain = {}, {}
  for i, p in ipairs(plugins) do
    if p.installed then util.add(installed, { name = p.name, ident = p.installed }) end
    chain[i] = { ident = p.instance, fxType = p.fxType, name = p.name }
  end
  h.reaper:setInstalledFx(installed)
  h.ds:assign('fxCatalogue', { n = 0, entries = entries or {} })
  h.reaper.InsertTrackAtIndex(0, false)
  local track = h.reaper.GetTrack(0, 0)
  h.reaper:setTrackFX(track, chain)
  for i = 1, #plugins do h.reaper:setFxGuid(track, i - 1, '{FX-' .. i .. '}') end
  return rm, h.reaper, track
end

local function chainOf(rm)
  for _, tr in ipairs(rm:tracks()) do if not tr.isMaster then return tr.fx end end
end

return {
  {
    name = 'tracks() stamps a VST3 instance with the traits authored under its installed key',
    run = function()
      local rm = seedChain({ ELASTIKA }, { [ELASTIKA.key] = { traits = { midiIn = false } } })
      local fx = chainOf(rm)
      t.eq(#fx, 1, 'precondition: the instance is read')
      t.truthy(fx[1].ident:find('{', 1, true), 'precondition: the instance ident carries its class id')
      t.deepEq(fx[1].traits, { midiIn = false, midiOut = true, instrument = false, busAware = false })
    end,
  },
  {
    name = 'an instance reporting VST3i is an instrument; one reporting VST3 is not',
    run = function()
      local fx = chainOf((seedChain({ AEOLUS, EQ })))
      t.eq(fx[1].traits.instrument, true)
      t.eq(fx[2].traits.instrument, false)
    end,
  },
  {
    name = 'a JSFX record resolves through its source\'s parse',
    run = function()
      local rm, reaper = seedChain({ { instance = 'JS:midi/recv', fxType = 'JS', name = 'JS: Recv' } })
      reaper:setJsfx('midi/recv', 'desc:r\n@block\nwhile (midirecv(o,a,b)) ( x = a; );\n')
      local fx = chainOf(rm)
      t.eq(fx[1].ident, 'JS:midi/recv', 'precondition: the record carries the JS: form')
      t.eq(fx[1].traits.midiIn,  true)
      t.eq(fx[1].traits.midiOut, false)
    end,
  },
  {
    name = 'track() and fx() records carry the same traits as tracks()',
    run = function()
      local rm, reaper, track = seedChain({ ELASTIKA }, { [ELASTIKA.key] = { traits = { midiIn = false } } })
      local fromTracks = chainOf(rm)[1].traits
      t.eq(fromTracks.midiIn, false, 'precondition: the authored trait resolves')
      t.deepEq(rm:track(reaper.GetTrackGUID(track)).fx[1].traits, fromTracks, 'track()')
      t.deepEq(rm:fx('{FX-1}').traits, fromTracks, 'fx()')
    end,
  },
}
