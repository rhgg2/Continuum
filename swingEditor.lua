-- See docs/swingEditor.md for the model.
-- @noindex

--invariant: editor stores no swing data; swingRead = tier copy of state.name, else merged floor
--invariant: all writes go through swingWrite (idempotent); commit() triggers cross-take reswing
--invariant: state == nil iff closed; open(name?) re-selects when open; close() is page-driven
--invariant: snapshot captured at open() and palette-switch; never mutated; Reset writes a deepClone
--invariant: shift is in QN and atom-independent — preserved across atom swap, only re-clamped to the new atom's cap
--invariant: on period change shift scales by newPeriod/oldPeriod, holding resolved s = shift/tileQN (and thus slope) constant; then re-clamped
--invariant: slider lo/hi = T_tile · {-negRange, +posRange} (asymmetric for shuffle/tilt); Wild unlocks hard, otherwise clamped to ±SWING_SOFT_QN; hi <= 0 freezes the slider
--invariant: atom-combo speaks tile-QN (user-period × pulsesPerCycle); writes divide back via periodOverPPC so storage stays user-period
--shape: state = { name, tier, snapshot, rpb, wild }  -- composite is NOT cached here
--shape: PeriodPreset = { label = string, period = number|{num,den} }  -- period in user-facing QN
local util    = require 'util'
local timing  = require 'timing'
local painter = require 'painter'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local SWING_ATOMS   = { 'id',
                        'classic', 'pocket', 'lilt', 'shuffle', 'tilt' }

local RPB_CHOICES   = { 1, 2, 3, 4, 6, 8, 12, 16 }

-- Period presets in qn (the model's native unit), so the whole editor
-- row is qn-consistent: shift in qn → period in qn → annotation in qn.
local PERIOD_PRESETS = {
  { label = '1/4', period = {1, 4} },  -- 16th
  { label = '1/3', period = {1, 3} },  -- 8th triplet
  { label = '1/2', period = {1, 2} },  -- 8th
  { label = '1',   period = 1       }, -- quarter
  { label = '2',   period = 2       }, -- half
  { label = '4',   period = 4       }, -- whole
}

local SWING_ERR     = 0xff6060ff
local SWING_SOFT_QN = 0.15

local cm, ds, chrome, ctx, gui, facade, modalHost =
  (...).cm, (...).ds, (...).chrome, (...).ctx, (...).gui, (...).facade, (...).modalHost

local function arrange() return facade.get('arrange') end
local function tracker() return facade.get('tracker') end

local state = nil

-- Fired on widget release so the project-wide pass runs once per gesture, not per frame.
local function commit()
  if state and state.name then arrange().reswingAll(state.name) end
end

local function meterQN()
  local num, denom = tracker().timeSig()
  num, denom = num or 4, denom or 4
  local beat = 4 / denom
  return beat, num * beat
end

--contract: returns 0 (not nil) when tileQN matches no preset; callers append a synthetic label in that case
local function periodPresetIndex(tileQN)
  for i, p in ipairs(PERIOD_PRESETS) do
    if math.abs(tileQN - timing.periodQN(p.period)) < 1e-9 then return i end
  end
  return 0
end

local function periodLabel(tileQN)
  local i = periodPresetIndex(tileQN)
  if i > 0 then return PERIOD_PRESETS[i].label end
  return string.format(tileQN == math.floor(tileQN) and '%d qn' or '%.3g qn', tileQN)
end

-- Preset .period is already a tidy rational; halving it for ppC=2 keeps
-- it tidy ({n,d} → {n,2d}; integer → {n,2}).
local function periodOverPPC(period, ppC)
  if ppC == 1 then return period end
  if type(period) == 'table' then return { period[1], period[2] * ppC } end
  return { period, ppC }
end

-- id has range = ∞ (slope is always 1; the K-bound never bites). Cap at
-- one tile per side so Wild gives a finite slider; the boundary clip
-- absorbs any overhang at the take edges. shuffle and tilt are
-- asymmetric (positive and negative shifts hit different K-bound walls).
local function shiftCap(factor, wild)
  local tile = timing.atomTilePeriod(factor)
  local hardLo, hardHi
  if factor.atom == 'id' then
    hardLo, hardHi = -tile, tile
  else
    local meta = timing.atomMeta[factor.atom]
    hardLo, hardHi = -tile * meta.negRange, tile * meta.posRange
  end
  if wild then return hardLo, hardHi end
  return math.max(-SWING_SOFT_QN, hardLo), math.min(SWING_SOFT_QN, hardHi)
end

-- QN-space preview uses ppqPerQN=1 so the editor draws against
-- normalised QN units rather than the take's PPQ resolution.
local function materialise(composite) return timing.resolveFactors(composite, 1) end

local STRIP_COLS = 6    -- strip width in tracker char-columns
local GLYPH_BOX  = 36   -- px reserved for each =/∘ separator between strips
local DIVIDER_GRAB    = 7    -- px hit-height of the draggable preview/factor splitter
local MIN_FACTOR_AREA = 80   -- px kept below the splitter for the factor list

-- Char-cell metrics matching the tracker grid (odd = crisp 1px lines).
-- Caller must have the grid font pushed so 'W' measures the mono cell.
local function gridMetrics()
  local charW, charH = ImGui.CalcTextSize(ctx, 'W')
  return 2 * math.ceil(charW / 2) - 1, 2 * math.ceil(charH / 2) - 1
end

-- Meter classifier: returns classify(qn) → 'bar'|'midBar'|'beat'|nil, plus beat and qpb.
-- midBar = bar midpoint landing on a beat (4/4, 6/8 yes; 3/4 no); shades as beat, sizes as bar.
local function meterClassifier()
  local beat, qpb = meterQN()
  local function isInt(x) return math.abs(x - util.round(x)) < 1e-9 end
  local midIsBeat = isInt((qpb / 2) / beat)
  local function classify(p)
    if not isInt(p / beat) then return nil end
    if isInt(p / qpb) then return 'bar' end
    if midIsBeat and isInt((p - qpb / 2) / qpb) then return 'midBar' end
    return 'beat'
  end
  return classify, beat, qpb
end

-- Vertical strip: tracker-grid rows (bar/beat fills, offbeat 1px dividers), blobs at realised time.
-- Blobs past ownPeriodQN draw in ghost colour; geom is shared so all strips align row-for-row.
local function drawSwingStrip(p, factors, ownPeriodQN, geom)
  local x0, y0, gx, gy = geom.x, geom.y, geom.gx, geom.gy
  local w = STRIP_COLS * gx

  for i = 0, geom.rows - 1 do
    local yT   = y0 + i * gy
    local tier = geom.classify(i * geom.dQN)
    if tier == 'bar' then
      p.fill({ x0 = x0, y0 = yT, x1 = x0 + w, y1 = yT + gy }, 'rowBarStart')
    elseif tier then
      p.fill({ x0 = x0, y0 = yT, x1 = x0 + w, y1 = yT + gy }, 'rowBeat')
    else
      p.segment(x0, yT, x0 + w, yT, 'laneRowDivider')
    end
  end

  local cx     = x0 + w / 2
  local rBig   = math.max(2, gy * 0.20)
  local rMid   = math.max(2, gy * 0.18)
  local rSmall = math.max(2, gy * 0.16)
  for i = 0, geom.rows - 1 do
    local p0   = i * geom.dQN
    local y    = y0 + (timing.applyFactors(factors, p0) / geom.heightQN) * geom.H
    local tier = geom.classify(p0)
    local r    = (tier == 'bar' or tier == 'midBar') and rBig
              or  tier == 'beat' and rMid or rSmall
    p.circle(cx, y, r, (p0 >= ownPeriodQN - 1e-9) and 'ghost' or 'text')
  end

  p.border({ x0 = x0, y0 = y0, x1 = x0 + w, y1 = y0 + geom.H }, 'swing.previewBorder')
end

-- Grid-font metrics + total band width for the preview strips. Pure measure;
-- pushes the grid font only to size the mono cell, then derives the layout.
local function bandLayout(composite, factors)
  ImGui.PushFont(ctx, gui.font, gui.fontSize.grid)
  local gx, gy              = gridMetrics()
  local classify, beat, qpb = meterClassifier()
  local periodQN            = timing.compositePeriodQN(composite)
  local nBars               = math.max(1, math.ceil(periodQN / qpb - 1e-9))
  local heightQN            = nBars * qpb
  local dQN                 = beat / state.rpb
  local rows                = math.max(1, util.round(heightQN / dQN))
  local stripW              = STRIP_COLS * gx
  ImGui.PopFont(ctx)

  local n     = #factors
  local bandW = stripW
  if n > 1 then bandW = bandW + GLYPH_BOX + n * stripW + (n - 1) * GLYPH_BOX end

  return { gx = gx, gy = gy, classify = classify, periodQN = periodQN,
           heightQN = heightQN, dQN = dQN, rows = rows, stripW = stripW,
           bandW = bandW, H = rows * gy, contentH = rows * gy + 2 * gy }
end

-- Preview band: composite strip left, then (when compound) '=' + factor strips fn∘…∘f1 right.
-- f1 applied first so sits rightmost; strips centred horizontally, top-aligned, clipped to region.
local function drawBandInto(layout, composite, factors, region)
  ImGui.PushFont(ctx, gui.font, gui.fontSize.grid)
  local p     = painter.new(ctx, chrome, {})
  local bandX = region.x + math.floor((region.w - layout.bandW) / 2)
  p.pushClip({ x0 = region.x, y0 = region.y,
               x1 = region.x + region.w, y1 = region.y + region.h })

  -- One grid row of blank padding above the strip content.
  local geom = { gx = layout.gx, gy = layout.gy, y = region.y + layout.gy,
                 rows = layout.rows, dQN = layout.dQN, heightQN = layout.heightQN,
                 H = layout.H, classify = layout.classify }

  -- Separators draw in the ui font: the grid font (Source Code Pro) lacks the
  -- ∘ ring operator, so it would render blank in the grid register.
  local function glyph(x, s)
    ImGui.PushFont(ctx, gui.uiFont, gui.fontSize.ui)
    local tw, th = ImGui.CalcTextSize(ctx, s)
    ImGui.PopFont(ctx)
    p.text(x + (GLYPH_BOX - tw) / 2, geom.y + (geom.H - th) / 2, 'text', s,
           gui.uiFont, gui.fontSize.ui)
    return x + GLYPH_BOX
  end

  local x = bandX
  geom.x = x
  drawSwingStrip(p, materialise(composite), layout.periodQN, geom)
  x = x + layout.stripW

  if #factors > 1 then
    x = glyph(x, '=')
    for i = #factors, 1, -1 do
      geom.x = x
      local one = { factors = { factors[i] } }
      drawSwingStrip(p, materialise(one), timing.compositePeriodQN(one), geom)
      x = x + layout.stripW
      if i > 1 then x = glyph(x, '\xe2\x88\x98') end
    end
  end

  p.popClip()
  ImGui.PopFont(ctx)
end

local function swingRead()
  local tierLib = state.tier and cm:getAt(state.tier, 'swings') or {}
  if tierLib[state.name] ~= nil then return tierLib[state.name] end
  return cm:get('swings', { mergeTiers = true })[state.name]   -- synthetic / default floor
end

-- Tolerant accessor: bare {} and {factors={}} both mean identity. Read-only;
-- write paths deepClone, then mutate factors[].
local function readFactors(composite)
  return (composite or {}).factors or {}
end

-- QN value of an optional period-shaped slot (scalar, {n,d}, or nil).
local function phaseQN(p) return p and timing.periodQN(p) or 0 end

--contract: compares composite phase, per-factor phase, period, atom and shift — phase fields normalise to QN before comparing, so {1,2} and {2,4} count equal
local function compositesEqual(a, b)
  a, b = a or {}, b or {}
  if math.abs(phaseQN(a.phase) - phaseQN(b.phase)) > 1e-12 then return false end
  local fa, fb = readFactors(a), readFactors(b)
  if #fa ~= #fb then return false end
  for i, x in ipairs(fa) do
    local y = fb[i]
    if x.atom ~= y.atom or x.shift ~= y.shift
       or math.abs(timing.periodQN(x.period) - timing.periodQN(y.period)) > 1e-12
       or math.abs(phaseQN(x.phase) - phaseQN(y.phase)) > 1e-12 then
      return false
    end
  end
  return true
end

--contract: sole write path; idempotent on equal composites; refresh via setSwingComposite
local function swingWrite(composite)
  if compositesEqual(swingRead() or {}, composite) then return end
  tracker().setSwingComposite(state.name, composite, state.tier)
end

-- Editable clone with a guaranteed factors[] array, so write paths can
-- index it without re-checking. Phase is preserved as-is.
local function cloneForEdit()
  local c = util.deepClone(swingRead()) or {}
  c.factors = c.factors or {}
  return c
end

local function patchFactor(i, patch)
  local c = cloneForEdit()
  if not c.factors[i] then return end
  util.assign(c.factors[i], patch)
  swingWrite(c)
end

--contract: default new factor is identity (atom='id', shift=0, period=1) — visually inert until edited
local function addFactor()
  local c = cloneForEdit()
  c.factors[#c.factors + 1] = { atom = 'id', shift = 0, period = 1 }
  swingWrite(c)
end

local function removeFactor(i)
  local c = cloneForEdit()
  table.remove(c.factors, i)
  swingWrite(c)
end

local function moveFactor(i, dir)
  local src = swingRead() or {}
  local fs  = readFactors(src)
  local j   = i + dir
  if j < 1 or j > #fs then return end
  local c = cloneForEdit()
  c.factors[i], c.factors[j] = c.factors[j], c.factors[i]
  swingWrite(c)
end

local function drawFactorRow(i, f, numColW, n)
  ImGui.PushID(ctx, i)

  -- Right-align the index in a fixed-width column so the dropdowns line up
  -- whether the factor count is single- or double-digit.
  ImGui.AlignTextToFramePadding(ctx)
  local label  = string.format('%d.', i)
  local startX = ImGui.GetCursorPosX(ctx)
  ImGui.SetCursorPosX(ctx, startX + numColW - ImGui.CalcTextSize(ctx, label))
  ImGui.Text(ctx, label)
  ImGui.SameLine(ctx)

  local pickedAtom = chrome.dropdown('atom', f.atom, SWING_ATOMS)
  if pickedAtom then
    local newAtom = SWING_ATOMS[pickedAtom]
    local lo, hi  = shiftCap({ atom = newAtom, period = f.period }, state.wild)
    local shift   = f.shift or 0
    if     shift < lo then shift = lo * 0.999
    elseif shift > hi then shift = hi * 0.999 end
    patchFactor(i, { atom = newAtom, shift = shift })
    commit()
  end

  ImGui.SameLine(ctx)
  local lo, hi = shiftCap(f, state.wild)
  local frozen = hi <= 0
  chrome.disabledIf(frozen, function()
    ImGui.SetNextItemWidth(ctx, 150)
    local sliderLo, sliderHi = lo * 0.999, hi * 0.999
    local rvA, newShift = ImGui.SliderDouble(ctx, '##shift', f.shift or 0, sliderLo, sliderHi, '%.3f qn')
    -- Continuous reswing: swingWrite reads the stored composite as the
    -- "old" side of the delta, so per-frame calls chain into the right
    -- old→now transformation as the slider drags.
    if rvA then
      local c = cloneForEdit()
      if c.factors[i] then c.factors[i].shift = newShift; swingWrite(c) end
    end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then commit() end
  end)

  ImGui.SameLine(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'per')
  ImGui.SameLine(ctx)
  local ppC    = timing.atomMeta[f.atom].pulsesPerCycle
  local tileQN = timing.atomTilePeriod(f)
  local pIdx   = periodPresetIndex(tileQN)
  local items = {}
  for _, p in ipairs(PERIOD_PRESETS) do items[#items+1] = p.label end
  if pIdx == 0 then items[#items+1] = periodLabel(tileQN) end
  local pickedPer = chrome.dropdown('per', periodLabel(tileQN), items)
  if pickedPer and pickedPer <= #PERIOD_PRESETS then
    -- Scale shift in QN by the period ratio so the resolved s = shift/tileQN
    -- is invariant — slope and feel survive the period change.
    local newPeriod = periodOverPPC(PERIOD_PRESETS[pickedPer].period, ppC)
    local scale     = timing.periodQN(newPeriod) / timing.periodQN(f.period)
    local shift     = (f.shift or 0) * scale
    local lo, hi    = shiftCap({ atom = f.atom, period = newPeriod }, state.wild)
    if     shift < lo then shift = lo * 0.999
    elseif shift > hi then shift = hi * 0.999 end
    patchFactor(i, { period = newPeriod, shift = shift })
    commit()
  end

  -- Per-factor phase: slides this factor's fixed-point lattice. Range is
  -- [0, T); writes wrap on overflow so dragging never lands outside the
  -- canonical interval.
  ImGui.SameLine(ctx, 0, 6)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'qn')
  ImGui.SameLine(ctx, 0, 12)
  ImGui.Text(ctx, '\xcf\x86')                       -- φ
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 100)
  local pHi    = tileQN
  local pCur   = (f.phase and timing.periodQN(f.phase) or 0) % pHi
  local rvPh, newPh = ImGui.SliderDouble(ctx, '##phase', pCur, 0, pHi, '%.3f qn')
  if rvPh then
    local wrapped = newPh % pHi
    local c = cloneForEdit()
    if c.factors[i] then
      c.factors[i].phase = (wrapped == 0) and nil or wrapped
      swingWrite(c)
    end
  end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then commit() end

  ImGui.SameLine(ctx)
  chrome.disabledIf(i == 1, function()
    if ImGui.Button(ctx, '\xe2\x86\x91##up') then moveFactor(i, -1) end   -- ↑ raise
  end)
  ImGui.SameLine(ctx)
  chrome.disabledIf(i == n, function()
    if ImGui.Button(ctx, '\xe2\x86\x93##dn') then moveFactor(i,  1) end   -- ↓ lower
  end)
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'del')                       then removeFactor(i)  end

  ImGui.PopID(ctx)
end

----- Tier-aware library writes

local SYNTHETIC = { identity = true }

local function projectSwings() return cm:getAt('project', 'swings') or {} end
-- Reading the global library lazily seeds it from the catalogue (minus the
-- synthetic floor) the first time. See docs/swingEditor.md § Library tiers.
local function globalSwings()
  cm:seedGlobalFromDefault('swings', SYNTHETIC)
  return cm:getAt('global', 'swings') or {}
end

-- A name's editable home: the project copy if one exists, else global (which
-- also covers the synthetic 'identity' floor and unseeded default presets).
local function homeTier(name)
  if name and projectSwings()[name] ~= nil then return 'project' end
  return 'global'
end

-- Switch the edited swing without closing the editor. Re-captures the
-- snapshot so Reset/dirty-check stay coherent; tier defaults to the home tier.
local function switchTo(name, tier)
  state.name     = name
  state.tier     = tier or (name and homeTier(name)) or nil
  state.snapshot = name and swingRead() or nil
end

local function deleteFromTier(level, name)
  local key = level == 'global' and globalSwings() or projectSwings()
  if key[name] == nil then return end
  key[name] = nil
  cm:set(level, 'swings', key)
end

--contract: promote copies the composite to global; the project copy survives, still shadowing it
local function promote(name)
  if not name then return end
  local g = globalSwings()
  g[name] = util.deepClone(swingRead())
  cm:set('global', 'swings', g)
end

-- Fork a global entry down into the project tier and edit that copy.
local function demote(name)
  if not name then return end
  local p = projectSwings()
  p[name] = util.deepClone(globalSwings()[name])
  cm:set('project', 'swings', p)
  switchTo(name, 'project')
end

-- Delete from the row's tier; fall back to a surviving shadow in the other
-- tier if any, else clear the selection.
local function deleteSel(tier, name)
  deleteFromTier(tier, name)
  if projectSwings()[name] or globalSwings()[name] then switchTo(name)
  else switchTo(nil) end
end

-- Resolved take and channel slots for the open-default and the
-- library-row shortcut buttons. 'identity' at the take tier is treated
-- as no-slot (matches open()'s bail); at the channel tier nil means
-- 'no override, fall through to take'.
local function resolvedSlots()
  local sw       = ds:get('swing') or {}
  local takeName = sw.global
  if takeName == 'identity' then takeName = nil end
  local anchor   = tracker().cursorAnchor()
  local chanName = anchor and sw[anchor.chan] or nil
  return takeName, chanName
end

local function sortedNames(tbl)
  local out = {}
  for k in pairs(tbl) do out[#out + 1] = k end
  table.sort(out)
  return out
end

-- In-force entries for the Active folder: take swing + every channel
-- override, read straight from ds (no cursor) so all columns show.
local function activeEntries()
  local sw  = ds:get('swing') or {}
  local out = {}
  local takeName = sw.global
  if takeName == 'identity' then takeName = nil end
  if takeName then out[#out + 1] = { col = 'take', name = takeName } end
  local chans = {}
  for chan in pairs(sw) do if chan ~= 'global' then chans[#chans + 1] = chan end end
  table.sort(chans)
  for _, chan in ipairs(chans) do
    out[#out + 1] = { col = 'ch' .. chan, name = sw[chan] }
  end
  return out
end

-- Project entries a take references can't be deleted (it would orphan the
-- reference); the shell greys Delete for these.
local function inUseNames()
  local used = {}
  for name in pairs(projectSwings()) do
    if #arrange().takesUsing(name) > 0 then used[name] = true end
  end
  return used
end

-- Revert the edited composite to the open()/switch snapshot, then reswing.
local function resetToSnapshot()
  swingWrite(util.deepClone(state.snapshot) or {})
  commit()
end

local openNewModal   -- forward decl; defined with its modalHost kind below

local function buildDescriptor()
  local globalNames = sortedNames(globalSwings())
  if not globalSwings().identity then table.insert(globalNames, 1, 'identity') end
  return {
    label       = 'swing',
    active      = activeEntries(),
    project     = sortedNames(projectSwings()),
    global      = globalNames,
    synthetic   = SYNTHETIC,
    undeletable = inUseNames(),
    sel         = { tier = state.tier, name = state.name },
    onSelect    = function(tier, name) switchTo(name, tier) end,
    onNew       = openNewModal,
    onPromote   = promote,
    onDemote    = demote,
    onDelete    = deleteSel,
    dirty       = state.name ~= nil and not compositesEqual(swingRead() or {}, state.snapshot),
    onReset     = resetToSnapshot,
  }
end

-- New-swing modal, hosted by modalHost (kind registered below). Opener captures
-- the target tier; the render keeps the popup open on a name clash.
openNewModal = function()
  local tier = state.tier or 'project'
  modalHost:open{
    kind = 'swingNew', title = 'New swing', buf = '',
    callback = function(name)
      tracker().setSwingComposite(name, {}, tier)
      switchTo(name, tier)
    end,
  }
end

modalHost:registerKind('swingNew', function(s, close)
  if ImGui.IsWindowAppearing(ctx) or s.refocus then
    ImGui.SetKeyboardFocusHere(ctx); s.refocus = nil
  end
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Name:')
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 240)
  s.gen = s.gen or 0
  ImGui.PushID(ctx, s.gen)
  local rv, buf = ImGui.InputText(ctx, '##newname', s.buf, ImGui.InputTextFlags_EnterReturnsTrue)
  ImGui.PopID(ctx)
  s.buf = buf
  ImGui.SameLine(ctx)
  local confirm = rv or ImGui.Button(ctx, 'Create')
  ImGui.SameLine(ctx)
  local cancel  = ImGui.Button(ctx, 'Cancel') or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape)
  if confirm then
    local name = (buf or ''):match('^%s*(.-)%s*$')
    if name == '' then
      s.err = 'Name required.'
    elseif cm:get('swings', { mergeTiers = true })[name] then
      s.err = 'Name already in use.'; s.buf = ''; s.gen = s.gen + 1; s.refocus = true
    else
      close(true, name)
    end
  elseif cancel then close(false) end
  if s.err then ImGui.TextColored(ctx, SWING_ERR, s.err) end
end)

-- Toolbar tools: Rows-per-qn / Wild / Composite-phase, drawn in the page toolbar
-- band (ui font + FramePadding already set). Vertical separators per group.
local function drawToolsRow(composite, n)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Rows/qn:')
  ImGui.SameLine(ctx, 0, 6)
  local rpbItems = {}
  for _, v in ipairs(RPB_CHOICES) do rpbItems[#rpbItems+1] = tostring(v) end
  local pickedRpb = chrome.dropdown('rpb', tostring(state.rpb), rpbItems)
  if pickedRpb then state.rpb = RPB_CHOICES[pickedRpb] end

  ImGui.SameLine(ctx, 0, 12)
  chrome.verticalSeparator()
  ImGui.SameLine(ctx, 0, 12)

  local rvW, newWild = chrome.checkbox('  Wild', state.wild or false)
  if rvW then state.wild = newWild end

  -- Composite phase: bounded by the LCM tile of all factors. Greyed
  -- when there are no factors (no lattice to slide).
  ImGui.SameLine(ctx, 0, 12)
  chrome.verticalSeparator()
  ImGui.SameLine(ctx, 0, 12)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Phase \xcf\x86:')
  ImGui.SameLine(ctx, 0, 6)
  chrome.disabledIf(n == 0, function()
    local lcmQN  = timing.compositePeriodQN(composite)
    local pCur   = (composite.phase and timing.periodQN(composite.phase) or 0) % lcmQN
    ImGui.SetNextItemWidth(ctx, 140)
    local rvCp, newCp = ImGui.SliderDouble(ctx, '##cphase', pCur, 0, lcmQN, '%.3f qn')
    if rvCp then
      local wrapped = newCp % lcmQN
      local c = cloneForEdit()
      c.phase = (wrapped == 0) and nil or wrapped
      swingWrite(c)
    end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then commit() end
  end)
end

local function drawEditBody(composite)
  local factors = readFactors(composite)

  -- Header, band and splitter stay live regardless of selection; factor editor greys out when
  -- no swing is selected. Header runs in plain chrome state so divider aligns across pane gap.
  chrome.paletteHeader('preview')

  local layout = bandLayout(composite, factors)
  local availW, bodyAvailH = ImGui.GetContentRegionAvail(ctx)
  local minH   = layout.gy * 3
  local maxH   = math.max(minH, bodyAvailH - MIN_FACTOR_AREA)

  -- Fit preview to content on open and on rows/qn change (capped to keep MIN_FACTOR_AREA);
  -- a manual splitter drag overrides until rows/qn changes again.
  if state.previewRpb ~= state.rpb then
    state.previewRpb = state.rpb
    state.previewH   = math.min(maxH, math.max(minH, layout.contentH))
  end

  local px, py = ImGui.GetCursorScreenPos(ctx)
  local region = { x = px, y = py, w = availW, h = state.previewH }

  drawBandInto(layout, composite, factors, region)
  ImGui.Dummy(ctx, region.w, region.h)

  -- 'factors' header; divider doubles as splitter. Drag is relative (anchored at grab)
  -- so the rule stays under the cursor rather than jumping by the header height.
  local ruleY = chrome.paletteHeader('factors')
  local afterX, afterY = ImGui.GetCursorScreenPos(ctx)
  ImGui.SetCursorScreenPos(ctx, afterX, ruleY - math.floor(DIVIDER_GRAB / 2))
  ImGui.InvisibleButton(ctx, '##previewSplit', availW, DIVIDER_GRAB)
  local hovered, active = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)
  if active then
    local _, my = ImGui.GetMousePos(ctx)
    state.splitDrag = state.splitDrag or { y0 = my, h0 = state.previewH }
    state.previewH  = math.max(minH, math.min(maxH, state.splitDrag.h0 + (my - state.splitDrag.y0)))
  else
    state.splitDrag = nil
  end
  if hovered or active then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeNS) end
  ImGui.SetCursorScreenPos(ctx, afterX, afterY)

  if not state.name then ImGui.BeginDisabled(ctx) end
  local numColW = ImGui.CalcTextSize(ctx, string.format('%d.', #factors))
  for i, f in ipairs(factors) do
    drawFactorRow(i, f, numColW, #factors)
  end
  if ImGui.Button(ctx, '+ add factor') then addFactor() end
  if not state.name then ImGui.EndDisabled(ctx) end
end

-- Body-region draw inside a child window; chrome palette (editor.bg + toolbar colours)
-- takes the tracker grid's place (Col_ChildBg instead of Col_WindowBg).
local function draw(w, h)
  if not state then return end

  local composite = (state.name and swingRead()) or {}

  chrome.pushChromeStyles()
  if ImGui.BeginChild(ctx, '##swingEditor', w, h) then
    drawEditBody(composite)
  end
  ImGui.EndChild(ctx)
  chrome.popChromeStyles()
end

----- Public

local self = {}

--contract: open(name?) selects entry; default prefers chan override → take swing → nil.
--contract: when already open, re-selects resolved target; snapshot captured at selection time.
function self:open(name)
  local takeName, chanName = resolvedSlots()
  local target = name or chanName or takeName
  if state then
    if target then switchTo(target) end
    return
  end
  local lib = cm:get('swings', { mergeTiers = true })
  state = { rpb = 4 }
  switchTo(target)
end

function self:render(w, h) draw(w, h) end

-- Tools row (Reset / Rows-per-qn / Wild / Composite-phase) drawn into the page
-- toolbar band by editorRender. Greys out with no slot selected, like the body.
function self:renderToolbar()
  if not state then return end
  local composite = (state.name and swingRead()) or {}
  local n = #readFactors(composite)
  if not state.name then ImGui.BeginDisabled(ctx) end
  drawToolsRow(composite, n)
  if not state.name then ImGui.EndDisabled(ctx) end
end

function self:libraryDescriptor() return buildDescriptor() end

function self:close() state = nil end

function self:isOpen() return state ~= nil end

return self

