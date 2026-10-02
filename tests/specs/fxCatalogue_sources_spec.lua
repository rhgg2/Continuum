-- fxCatalogue.sources and import: REAPER's five classification sources, each resolved to
-- catalogue keys against the installed set, with the names per key, the
-- installed keys covered, the distinct names and the references dropped.
--
-- The install tree reads the ident: a VST's directories below the deepest
-- reaper.ini vstpath root holding it (a root matches whole, so .../VST is no
-- root of .../VST3/...), a JSFX's directories below Effects. A plugin directly
-- at a root, a VST under none, an AU or a CLAP has no tree name.
--
-- A category or developer key resolves to the installed key equal to it, else
-- to every JSFX whose file name it is, else to either ignoring case; nothing
-- matching is one dropped reference. A folder item keys by its section's Type
-- and resolves exactly or ignoring case; Type 1048576 is a smart folder's
-- filter and counts nothing, and folder id 0 is the favourites. A section with
-- a line that does not parse is skipped whole. Category values split on '|',
-- and a name with an empty '/'-segment (the empty one after a trailing '|') is
-- not kept, nor counted as a drop. A missing ini reads as empty.
--
-- Import files each chosen path source's names on its keys, flags folder id 0's
-- members favourite, makes [categories] standing, and names a developer only
-- on an entry holding none. Replace first clears every entry's paths, favourite
-- and developer, and the standing paths, whichever sources are chosen; ports,
-- usage and traits stand, as does an entry under an unresolved key.
--
-- The fixtures under tests/fixtures/fxSources are trimmed from a real install.
-- Fabricated: the vstpath64 key (the x64 key name is unverified), the
-- old/volume and TDR Kotelnikov plugins, and every extra row a case adds.
-- The fixture's VST3 idents all sit under the VST3 root too, so the deepest
-- root hides a prefix match on VST; the whole-root case needs its own row.
local t       = require('support')
local harness = require('harness')
local util    = require('util')

local specDir  = debug.getinfo(1, 'S').source:match('^@?(.*)/[^/]+$')
local FIXTURES = specDir .. '/../fixtures/fxSources'
local HOME     = os.getenv('HOME')
local VST3DIR  = '/Library/Audio/Plug-Ins/VST3/'

-- EnumInstalledFX (name, ident) pairs, with REAPER's key for each.
local ROWS = {
  { name = 'VST3: 8K (Canvas Audio)', ident = VST3DIR .. 'Effects/EQ/Canvas Audio - 8K.vst3',
    key = 'Canvas_Audio___8K.vst3' },
  { name = 'VST3: Elastika (Sapphire)', ident = VST3DIR .. 'Effects/Filter/Sapphire.vst3<739473316',
    key = 'Sapphire.vst3<739473316' },
  { name = 'VST3i: TRINITY (KORG)', ident = VST3DIR .. 'TRINITY.vst3', key = 'TRINITY.vst3' },
  { name = 'VST: ReaComp (Cockos)', ident = '/Applications/REAPER.app/Contents/Plugins/FX/reacomp.vst.dylib',
    key = 'reacomp.vst.dylib' },
  { name = 'VST3: Bucket-500 (Caelum)', ident = HOME .. '/Library/Audio/Plug-Ins/VST3/Effects/Delay/Bucket-500.vst3',
    key = 'Bucket_500.vst3' },
  { name = 'VST3: Kotelnikov (TDR)', ident = '/Volumes/Plugins/VST3/Dynamics/TDR Kotelnikov.vst3',
    key = 'TDR_Kotelnikov.vst3' },
  { name = 'JS: 4-Band Splitter', ident = 'loser/4BandSplitter', key = 'loser/4BandSplitter' },
  { name = 'JS: Phaser', ident = 'guitar/phaser', key = 'guitar/phaser' },
  { name = 'JS: Volume Adjustment', ident = 'utility/volume', key = 'utility/volume' },
  { name = 'JS: Volume (old)', ident = 'old/volume', key = 'old/volume' },
  { name = 'JS: Garns Oscillator', ident = 'oscillator.jsfx', key = 'oscillator.jsfx' },
  { name = 'AU: AUDelay (Apple)', ident = 'Apple: AUDelay', key = 'Apple: AUDelay' },
  { name = 'CLAPi: Aeolus (Arthur Benilov)', ident = 'com.ArthurBenilov.Aeolus',
    key = 'com.ArthurBenilov.Aeolus' },
  { name = 'VST3i: Model 80 Five Voice Synthesizer (Softube)',
    ident = VST3DIR .. 'Generators/Analogue/Model 80 Five Voice Synthesizer.vst3',
    key = 'Model_80_Five_Voice_Synthesizer.vst3' },
}

-- The sources over the ROWS installed set and any extra rows, read from the inis in dir,
-- with the same fake's ds.
local function sourcesAt(dir, extra)
  local h = harness.mk()
  local reaper = h.reaper
  local list = {}
  for i, row in ipairs(ROWS) do list[i] = { name = row.name, ident = row.ident } end
  for _, row in ipairs(extra or {}) do list[#list + 1] = { name = row.name, ident = row.ident } end
  reaper:setInstalledFx(list)
  reaper._state.resourcePath = dir
  return require('fxCatalogue').sources(), h.ds
end

local function set(list)
  local result = {}
  for _, v in ipairs(list) do result[v] = true end
  return result
end

-- { [row] = { name, ... } } as { [catalogueKey] = { [name] = true } }.
local function named(byRow)
  local names = {}
  for row, list in pairs(byRow) do names[ROWS[row].key] = set(list) end
  return names
end

local function entriesOf(ds) return ds:get('fxCatalogue').entries end

local function raises(fn, msg)
  local ok = pcall(fn)
  t.falsy(ok, msg)
end

local function counts(source, covered, distinct, dropped, label)
  t.eq(source.covered,  covered,  label .. ' covered')
  t.eq(source.distinct, distinct, label .. ' distinct')
  t.eq(source.dropped,  dropped,  label .. ' dropped')
end

return {
  {
    name = 'the install tree names a VST below its deepest whole root, and a JSFX below Effects',
    run = function()
      local sources = sourcesAt(FIXTURES)
      t.eq(sources.installed, #ROWS, 'installed is the installed-set size')
      t.deepEq(sources.tree.names, named{
        [1] = { 'Effects/EQ' }, [2] = { 'Effects/Filter' }, [5] = { 'Effects/Delay' },
        [6] = { 'Dynamics' }, [7] = { 'loser' }, [8] = { 'guitar' }, [9] = { 'utility' },
        [10] = { 'old' }, [14] = { 'Generators/Analogue' },
      }, 'one directory path per plugin under a root; none at a root, under none, or AU/CLAP')
      counts(sources.tree, 9, 9, 0, 'tree')
    end,
  },
  {
    name = 'the install tree keeps every directory, and a root matches only as a whole directory',
    run = function()
      local nested  = { name = 'JS: Mixer 8', ident = 'IX/Mixer/mix8', key = 'IX/Mixer/mix8' }
      local outside = { name = 'VST3: Old (Archive)', ident = '/Volumes/PluginsArchive/Dynamics/Old.vst3',
                        key = 'Old.vst3' }
      local tree = sourcesAt(FIXTURES, { nested, outside }).tree
      t.deepEq(tree.names[nested.key], set{ 'IX/Mixer' }, 'a nested JSFX keeps both directories')
      t.truthy(tree.names[ROWS[6].key], 'the /Volumes/Plugins roots are read')
      t.eq(tree.names[outside.key], nil, '/Volumes/PluginsArchive is under no root')
    end,
  },
  {
    name = 'an exact match, then a JSFX file name, wins over a match ignoring case',
    run = function()
      local volume = { name = 'JS: Volume (misc)', ident = 'misc/Volume', key = 'misc/Volume' }
      local canvas = { name = 'VST3: 8k (canvas)', ident = VST3DIR .. 'canvas audio - 8k.vst3',
                       key = 'canvas_audio___8k.vst3' }
      local sources = sourcesAt(FIXTURES, { volume, canvas })
      t.deepEq(sources.user.names[ROWS[9].key], set{ 'Mad' }, 'volume=Mad resolves by file name')
      t.eq(sources.user.names[volume.key], nil, 'Volume differs in case from volume=Mad')
      t.deepEq(sources.derived.names[ROWS[1].key], set{ 'EQ' }, 'Canvas_Audio___8K.vst3 resolves exactly')
      t.eq(sources.derived.names[canvas.key], nil, 'its lower-case twin differs in case')
    end,
  },
  {
    name = 'user categories resolve exactly, by JSFX file name, and drop what is not installed',
    run = function()
      local user = sourcesAt(FIXTURES).user
      t.deepEq(user.names, named{
        [1] = { 'Mad' }, [2] = { 'Filter', 'Mad' }, [7] = { 'FSU/Lofi' },
        [9] = { 'Mad' }, [10] = { 'Mad' }, [12] = { 'FSU/Lofi' },
      }, 'a shared JSFX file name names both; a trailing | yields no empty name')
      counts(user, 6, 3, 2, 'user')
      t.deepEq(user.standing, set{ 'Clipper', 'FSU/Lofi', 'Mad' }, 'standing from [categories]')
    end,
  },
  {
    name = 'user folders key their items by Type, by id, with id 0 the favourites',
    run = function()
      local folders = sourcesAt(FIXTURES).folders
      t.deepEq(folders.favourites, set{ ROWS[13].key }, 'folder id 0 holds the favourites')
      t.deepEq(folders.names, named{
        [1] = { 'Alpha' }, [8] = { 'Alpha' }, [5] = { 'Alpha' }, [14] = { 'Beta' }, [11] = { 'Beta' },
      }, 'a moved VST keys by file name; the smart folder and the unparseable section name nothing')
      counts(folders, 6, 2, 1, 'folders')
    end,
  },
  {
    name = 'derived categories resolve and split like the user\'s',
    run = function()
      local derived = sourcesAt(FIXTURES).derived
      t.deepEq(derived.names, named{
        [1] = { 'EQ' }, [3] = { 'Synth' }, [2] = { 'Filter' }, [5] = { 'Delay' },
        [7] = { 'Tools' }, [13] = { 'Synth', 'Organ' },
      }, 'derived names per key')
      counts(derived, 6, 6, 1, 'derived')
    end,
  },
  {
    name = 'developers resolve ignoring case where nothing matches exactly',
    run = function()
      local developers = sourcesAt(FIXTURES).developers
      t.deepEq(developers.names, named{
        [1] = { 'Canvas Audio' }, [3] = { 'KORG' }, [12] = { 'Apple' },
      }, 'Trinity.vst3 resolves to TRINITY.vst3')
      counts(developers, 3, 3, 1, 'developers')
    end,
  },
  {
    name = 'missing inis read as empty sources, and the tree still reads JSFX directories',
    run = function()
      local sources = sourcesAt(specDir)
      for _, label in ipairs{ 'user', 'folders', 'derived', 'developers' } do
        t.deepEq(sources[label].names, {}, label .. ' names')
        counts(sources[label], 0, 0, 0, label)
      end
      t.deepEq(sources.user.standing, {}, 'no standing paths')
      t.deepEq(sources.folders.favourites, {}, 'no favourites')
      t.deepEq(sources.tree.names, named{
        [7] = { 'loser' }, [8] = { 'guitar' }, [9] = { 'utility' }, [10] = { 'old' },
      }, 'JSFX directories need no file')
      counts(sources.tree, 4, 4, 0, 'tree')
    end,
  },
  {
    name = 'augment files the chosen sources\' names beside held paths, and touches no other fact',
    run = function()
      local sources, ds = sourcesAt(FIXTURES)
      local fxCatalogue = require('fxCatalogue')
      local usage = { s = 2, n0 = 3 }
      ds:assign('fxCatalogue', { n = 3, entries = {
        [ROWS[1].key] = { paths = { Held = true }, usage = usage, ports = { ins = 1, outs = 1 } },
      }, standing = { Kept = true } })
      fxCatalogue.import(ds, sources, { tree = true, derived = true }, 'augment')
      local entries = entriesOf(ds)
      t.deepEq(entries[ROWS[1].key], { paths = set{ 'Held', 'Effects/EQ', 'EQ' }, usage = usage,
        ports = { ins = 1, outs = 1 } }, 'tree and derived union with the held path')
      t.deepEq(entries[ROWS[13].key], { paths = set{ 'Synth', 'Organ' } }, 'a derived-only key gains an entry')
      t.eq(entries[ROWS[12].key], nil, 'user categories were declined')
      t.deepEq(ds:get('fxCatalogue').standing, set{ 'Kept' }, 'standing untouched')
    end,
  },
  {
    name = 'folders file by name and flag id 0 favourite; user categories make [categories] standing',
    run = function()
      local sources, ds = sourcesAt(FIXTURES)
      local fxCatalogue = require('fxCatalogue')
      fxCatalogue.import(ds, sources, { user = true, folders = true }, 'augment')
      local entries = entriesOf(ds)
      t.deepEq(entries[ROWS[13].key], { favourite = true }, 'a favourite files nothing')
      t.deepEq(entries[ROWS[2].key].paths, set{ 'Filter', 'Mad' }, 'user names filed')
      t.deepEq(entries[ROWS[14].key].paths, set{ 'Beta' }, 'folder names filed')
      t.deepEq(ds:get('fxCatalogue').standing, set{ 'Clipper', 'FSU/Lofi', 'Mad' }, '[categories] stand')
      local listed = set(fxCatalogue.categories(ds))
      t.truthy(listed.Clipper and listed.FSU and listed.Alpha, 'standing, prefix and folder paths listed')
    end,
  },
  {
    name = 'developers name an entry and file nothing; augment keeps a held name, replace overwrites it',
    run = function()
      local sources, ds = sourcesAt(FIXTURES)
      local fxCatalogue = require('fxCatalogue')
      ds:assign('fxCatalogue', { n = 0, entries = { [ROWS[3].key] = { developer = 'Korg Inc' } } })
      fxCatalogue.import(ds, sources, { developers = true }, 'augment')
      local entries = entriesOf(ds)
      t.deepEq(entries[ROWS[1].key], { developer = 'Canvas Audio' }, 'named, unfiled')
      t.eq(entries[ROWS[3].key].developer, 'Korg Inc', 'augment keeps a held developer')
      fxCatalogue.import(ds, sources, { developers = true }, 'replace')
      t.eq(entriesOf(ds)[ROWS[3].key].developer, 'KORG', 'replace overwrites it')
    end,
  },
  {
    name = 'a key with several developer names takes the lowest-sorting',
    run = function()
      local sources, ds = sourcesAt(FIXTURES)
      sources.developers.names = { [ROWS[3].key] = set{ 'Korg', 'KORG' } }
      require('fxCatalogue').import(ds, sources, { developers = true }, 'augment')
      t.eq(entriesOf(ds)[ROWS[3].key].developer, 'KORG', 'byte order picks KORG')
    end,
  },
  {
    name = 'replace clears all classification and standing, chosen or not, leaving ports, usage and traits',
    run = function()
      local sources, ds = sourcesAt(FIXTURES)
      local fxCatalogue = require('fxCatalogue')
      local kept = { ports = { ins = 1, outs = 2 }, usage = { s = 1, n0 = 1 }, traits = { midiOut = false } }
      ds:assign('fxCatalogue', { n = 1, entries = {
        [ROWS[1].key] = util.assign({ paths = { Held = true }, favourite = true, developer = 'X' }, kept),
        ['gone.vst3'] = { paths = { Held = true }, favourite = true, usage = { s = 1, n0 = 1 } },
      }, standing = { Kept = true } })
      fxCatalogue.import(ds, sources, { tree = true }, 'replace')
      local entries = entriesOf(ds)
      t.deepEq(entries[ROWS[1].key], util.assign({ paths = set{ 'Effects/EQ' } }, kept),
        'only the chosen tree path, the other facts kept')
      t.deepEq(entries['gone.vst3'], { usage = { s = 1, n0 = 1 } }, 'the unresolved entry stands, cleared')
      t.deepEq(ds:get('fxCatalogue').standing, {}, 'standing cleared')
      t.eq(entries[ROWS[13].key], nil, 'the declined favourite is not re-flagged')
    end,
  },
  {
    name = 'an unknown mode or source raises, and writes nothing',
    run = function()
      local sources, ds = sourcesAt(FIXTURES)
      local fxCatalogue = require('fxCatalogue')
      raises(function() fxCatalogue.import(ds, sources, { tree = true }, 'merge') end, 'unknown mode')
      raises(function() fxCatalogue.import(ds, sources, { cache = true }, 'augment') end, 'unknown source')
      t.eq(ds:get('fxCatalogue'), nil, 'nothing written')
    end,
  },
}
