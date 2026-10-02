-- fxCatalogue.pickerList: the picker's list as a function of its text. The
-- text splits at its last '/': before it the current place, after it the
-- stem; no '/' (or nothing before it) is the root. The current place resolves
-- to the category path spelled the same, else to the one path spelled the same
-- ignoring case; none, or several ignoring case, lists nothing. The resolved
-- path's own spelling stands thereafter.
--
-- The list holds the place's child places whose last name begins with the
-- stem, in the category list's order; at the root only, the caller's leading
-- rows whose names contain the stem, in the order given; then the plugins
-- below the place whose names contain the stem. All matching ignores case and
-- reads the stem plainly. A plugin is below a place where an entry path of its
-- equals the place or lies beneath it; every installed plugin is below the
-- root, filed or not, and one below by several paths is listed once. An entry
-- no installed row carries is never listed, though its paths are places.
--
-- Plugins rank in-project first, then by usage score decayed to the
-- catalogue's current count, then by name ignoring case. A place item is
-- { place, name }; a plugin or leading item is the caller's row itself. The
-- catalogue arrives as ds holds it: absent, or persisted without standing
-- paths, and is read, never written.
local t           = require('support')
local harness     = require('harness')
local fxCatalogue = require('fxCatalogue')
local util        = require('util')

local VST3DIR = '/Library/Audio/Plug-Ins/VST3/'

-- Mixed-case names, so ignoring case reorders them: raw, 'Echo' sorts before 'brisk'.
local ROWS = {
  { name = 'JS: Amber Hall',          ident = 'demo/amber' },
  { name = 'JS: brisk Comp',          ident = 'demo/brisk' },
  { name = 'JS: drift Synth',         ident = 'demo/drift' },
  { name = 'JS: Echo Chamber',        ident = 'demo/echo' },
  { name = 'JS: zesty Gate',          ident = 'demo/zesty' },
  { name = 'VST3: Cold Plate (Acme)', ident = VST3DIR .. 'Cold Plate.vst3' },
}
local BY_NAME = { 'JS: Amber Hall', 'JS: brisk Comp', 'JS: drift Synth', 'JS: Echo Chamber',
                  'JS: zesty Gate', 'VST3: Cold Plate (Acme)' }

-- The installed set, a catalogue built by setup, and a lister over both.
local function picker(setup)
  local h = harness.mk()
  h.reaper:setInstalledFx(ROWS)
  if setup then setup(h.ds) end
  local rows = fxCatalogue.installed()
  local function list(text, inProject, leading)
    return fxCatalogue.pickerList(h.ds:get('fxCatalogue'), rows, inProject or {}, text, leading or {})
  end
  return list, rows, h.ds
end

local function labels(list)
  local out = {}
  for i, item in ipairs(list) do out[i] = item.place and ('place:' .. item.place) or item.name end
  return out
end

local function concat(...)
  local out = {}
  for _, part in ipairs({ ... }) do
    for _, v in ipairs(part) do util.add(out, v) end
  end
  return out
end

-- Effects filed directly and by children; instruments only a prefix; Tools
-- standing; Effects Rack shares Effects' spelling up to a space; Cold Plate unfiled.
local function taxonomy(ds)
  fxCatalogue.file(ds, 'demo/amber', 'Effects/Reverb')
  fxCatalogue.file(ds, 'demo/brisk', 'Effects')
  fxCatalogue.file(ds, 'demo/echo', 'Effects')
  fxCatalogue.file(ds, 'demo/echo', 'Effects/Reverb')
  fxCatalogue.file(ds, 'demo/drift', 'instruments/Synth')
  fxCatalogue.file(ds, 'demo/zesty', 'Effects Rack')
  fxCatalogue.makePath(ds, 'Tools')
  fxCatalogue.makePath(ds, 'Effects/Dynamics')
  fxCatalogue.makePath(ds, 'Effects/Reverb/Plate')
end

local TOP = { 'place:Effects', 'place:Effects Rack', 'place:instruments', 'place:Tools' }

return {
  {
    name = 'a fresh ds lists every installed plugin by name ignoring case, and no places',
    run = function()
      local list, _, ds = picker()
      t.eq(ds:get('fxCatalogue'), nil, 'precondition: no catalogue')
      t.deepEq(labels(list('')), BY_NAME)
    end,
  },
  {
    name = 'the root with no text: top-level places in category order, leading, then every plugin',
    run = function()
      local list, rows = picker(taxonomy)
      local bus = { name = 'Bus: new' }
      local got = list('', {}, { bus })
      t.deepEq(labels(got), concat(TOP, { 'Bus: new' }, BY_NAME))
      t.eq(got[5], bus, 'the leading row is the caller\'s table')
      local row = got[6]
      local found = false
      for _, r in ipairs(rows) do found = found or r == row end
      t.truthy(found, 'a plugin item is the caller\'s row table')
      t.eq(got[1].name, 'Effects', 'a place carries its last name')
    end,
  },
  {
    name = 'a place matches by its name\'s start, a plugin by containing the stem, both ignoring case',
    run = function()
      local list = picker(taxonomy)
      local expected = { 'place:Effects', 'place:Effects Rack',
                         'JS: Amber Hall', 'JS: Echo Chamber', 'JS: zesty Gate', 'VST3: Cold Plate (Acme)' }
      t.deepEq(labels(list('e')), expected, 'instruments contains e but does not begin with it')
      t.deepEq(labels(list('E')), expected, 'the stem\'s case is ignored')
      t.deepEq(labels(list('/e')), expected, 'an empty place spelling is the root')
      t.deepEq(labels(list('Effects/Rev')), { 'place:Effects/Reverb' })
      t.deepEq(labels(list('Effects/verb')), {}, 'Reverb contains verb but does not begin with it')
      t.deepEq(labels(list('(')), { 'VST3: Cold Plate (Acme)' }, 'the stem is plain, not a pattern')
    end,
  },
  {
    name = 'a place lists its direct children and the plugins filed at or beneath it, once each',
    run = function()
      local list = picker(taxonomy)
      t.deepEq(labels(list('Effects/', {}, { { name = 'Bus: new' } })),
        { 'place:Effects/Dynamics', 'place:Effects/Reverb',
          'JS: Amber Hall', 'JS: brisk Comp', 'JS: Echo Chamber' },
        'no grandchild, no Effects Rack plugin, no unfiled plugin, no leading row')
      t.deepEq(labels(list('Effects/Reverb/')),
        { 'place:Effects/Reverb/Plate', 'JS: Amber Hall', 'JS: Echo Chamber' })
      t.deepEq(labels(list('instruments/')), { 'place:instruments/Synth', 'JS: drift Synth' },
        'a place listed only as a prefix holds what is filed beneath it')
    end,
  },
  {
    name = 'the place resolves exactly, else uniquely ignoring case, and lists in its own spelling',
    run = function()
      local list = picker(taxonomy)
      t.deepEq(labels(list('effects/')),
        { 'place:Effects/Dynamics', 'place:Effects/Reverb',
          'JS: Amber Hall', 'JS: brisk Comp', 'JS: Echo Chamber' },
        'children carry the real spelling')

      local cased = picker(function(ds)
        fxCatalogue.file(ds, 'demo/brisk', 'FX')
        fxCatalogue.file(ds, 'demo/echo', 'fx')
      end)
      t.deepEq(labels(cased('FX/')), { 'JS: brisk Comp' }, 'FX matches exactly')
      t.deepEq(labels(cased('fx/')), { 'JS: Echo Chamber' }, 'fx matches exactly')
      t.deepEq(labels(cased('Fx/')), {}, 'Fx matches two ignoring case, so none')
    end,
  },
  {
    name = 'a place spelling that is no path lists nothing',
    run = function()
      local list = picker(taxonomy)
      t.truthy(#list('Effects/') > 0, 'precondition: Effects lists')
      t.deepEq(labels(list('Nope/x')), {})
      t.deepEq(labels(list('Nope/')), {})
      t.deepEq(labels(list('Effects//')), {}, 'Effects/ is no path')
    end,
  },
  {
    name = 'plugins rank in-project first, then by decayed usage, then by name ignoring case',
    run = function()
      local ports = { ins = 2, outs = 2 }
      local list, _, ds = picker(function(ds)
        for _ = 1, 2 do fxCatalogue.recordUse(ds, 'demo/amber', ports) end
        for _ = 1, 40 do fxCatalogue.recordUse(ds, 'demo/zesty', ports) end
        fxCatalogue.recordUse(ds, 'demo/brisk', ports)
      end)
      local entries = ds:get('fxCatalogue').entries
      t.truthy(entries['demo/amber'].usage.s > entries['demo/brisk'].usage.s,
        'precondition: Amber\'s raw score exceeds brisk\'s')
      -- At n = 43, Amber decays to 1.98 * 0.98^41, about 0.86, under brisk's 1.
      t.deepEq(labels(list('')),
        { 'JS: zesty Gate', 'JS: brisk Comp', 'JS: Amber Hall',
          'JS: drift Synth', 'JS: Echo Chamber', 'VST3: Cold Plate (Acme)' })
      t.deepEq(labels(list('', { ['demo/drift'] = true })),
        { 'JS: drift Synth', 'JS: zesty Gate', 'JS: brisk Comp', 'JS: Amber Hall',
          'JS: Echo Chamber', 'VST3: Cold Plate (Acme)' },
        'an unused plugin in the project leads the most used')
      t.deepEq(labels(list('', { ['demo/drift'] = true, ['demo/brisk'] = true })),
        { 'JS: brisk Comp', 'JS: drift Synth', 'JS: zesty Gate', 'JS: Amber Hall',
          'JS: Echo Chamber', 'VST3: Cold Plate (Acme)' },
        'within the project, usage ranks')
    end,
  },
  {
    name = 'leading rows sit at the root after places, in the order given, narrowed by the stem',
    run = function()
      local list = picker(taxonomy)
      local zeta, alpha = { name = 'Bus: zeta' }, { name = 'Bus: Alpha' }
      t.deepEq(labels(list('', {}, { zeta, alpha })),
        concat(TOP, { 'Bus: zeta', 'Bus: Alpha' }, BY_NAME), 'not reranked by name')
      t.deepEq(labels(list('ALPHA', {}, { zeta, alpha })), { 'Bus: Alpha' })
      t.deepEq(labels(list('t', {}, { zeta, alpha })),
        { 'place:Tools', 'Bus: zeta', 'JS: drift Synth', 'JS: zesty Gate', 'VST3: Cold Plate (Acme)' },
        'zeta contains t, Alpha does not')
      t.deepEq(labels(list('Tools/', {}, { zeta, alpha })), {}, 'no leading row away from the root')
    end,
  },
  {
    name = 'a catalogue persisted without standing paths lists its entries\' places, unwritten',
    run = function()
      local list, rows, ds = picker(function(ds)
        ds:assign('fxCatalogue', { n = 0, entries = { ['demo/amber'] = { paths = { ['Effects/Reverb'] = true } } } })
      end)
      local catalogue = ds:get('fxCatalogue')
      t.eq(catalogue.standing, nil, 'precondition: no standing paths')
      local got = fxCatalogue.pickerList(catalogue, rows, {}, 'Effects/', {})
      t.deepEq(labels(got), { 'place:Effects/Reverb', 'JS: Amber Hall' })
      t.eq(catalogue.standing, nil, 'the catalogue passed in is not written')
      t.deepEq(labels(list('')), concat({ 'place:Effects' }, BY_NAME))
    end,
  },
  {
    name = 'an entry no installed row carries makes places but is never listed as a plugin',
    run = function()
      local list = picker(function(ds) fxCatalogue.file(ds, 'gone.vst3', 'Lost/Found') end)
      local inProject = { ['gone.vst3'] = true }
      t.deepEq(labels(list('', inProject)), concat({ 'place:Lost' }, BY_NAME))
      t.deepEq(labels(list('Lost/', inProject)), { 'place:Lost/Found' })
      t.deepEq(labels(list('Lost/Found/', inProject)), {})
    end,
  },
}
