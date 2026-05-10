-- See docs/swingEditor.md for the model.
-- @noindex

--@map:invariant editor owns no swing data; composite lives in cm:get('swings')[name] and is read fresh each frame via swingRead
--@map:invariant all writes route through swingWrite (idempotent → vm:setSwingComposite); commit() drives cross-take reswing on widget release
--@map:invariant state == nil iff editor is closed; open() is a no-op when already open; Esc / Begin-close clears state
--@map:invariant snapshot is captured at open() and never mutated; Reset writes a deepClone of it
--@map:invariant shift is in QN and atom-independent — preserved across atom swap, only re-clamped to the new atom's cap
--@map:invariant on period change shift scales by newPeriod/oldPeriod, holding resolved s = shift/tileQN (and thus slope) constant; then re-clamped
--@map:invariant slider lo/hi = T_tile · {-negRange, +posRange} (asymmetric for shuffle/tilt); Wild unlocks hard, otherwise clamped to ±SWING_SOFT_QN; hi <= 0 freezes the slider
--@map:invariant atom-combo speaks tile-QN (user-period × pulsesPerCycle); writes divide back via periodOverPPC so storage stays user-period
--@map:shape state = { name, snapshot, createBuf, createError, rpb, wild, lastCount, lastW }  -- composite is NOT cached here
--@map:shape PeriodPreset = { label = string, period = number|{num,den} }  -- period in user-facing QN

loadModule('util')
loadModule('timing')

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local SWING_ATOMS   = { 'id',
                        'classic', 'pocket', 'lilt', 'shuffle', 'tilt' }
local SWING_ATOMS_Z = table.concat(SWING_ATOMS, '\0') .. '\0\0'

local RPB_CHOICES   = { 1, 2, 3, 4, 6, 8, 12, 16 }

-- Period presets in qn (the model's native unit), so the whole editor
-- row is qn-consistent: shift in qn → period in qn → annotation in qn.
local PERIOD_PRESETS = {
  { label = '1/4 qn', period = {1, 4} },  -- 16th
  { label = '1/3 qn', period = {1, 3} },  -- 8th triplet
  { label = '1/2 qn', period = {1, 2} },  -- 8th
  { label = '1 qn',   period = 1       }, -- quarter
  { label = '2 qn',   period = 2       }, -- half
  { label = '4 qn',   period = 4       }, -- whole
}

local SWING_ERR     = 0xff6060ff
local SWING_MARK    = 0x000000b0
local SWING_SOFT_QN = 0.15

function newSwingEditor(vm, cm, chrome, ctx, seqMgr)
  local state = nil

  -- Fired on widget release so the project-wide pass runs once per gesture, not per frame.
  local function commit()
    if state and state.name then seqMgr:reswingAll(state.name) end
  end

  local function meterQN()
    local num, denom = vm:timeSig()
    local beat = 4 / denom
    return beat, num * beat
  end

  --@map:contract returns 0 (not nil) when tileQN matches no preset; callers append a synthetic label in that case
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

  local function drawSwingGrid(composite, periodQN, rpb, w, h, shadeMeter)
    local x0, y0    = ImGui.GetCursorScreenPos(ctx)
    local dl        = ImGui.GetWindowDrawList(ctx)
    local beat, qpb = meterQN()
    local N         = math.max(2, util.round(periodQN * rpb))
    local cellW     = w / N

    -- Half-pad top and bottom so bar/beat shading and dividers sit in an
    -- inner band; dots can extend past the band edge for emphasis. Same
    -- structural idea as drawLaneStrip (height-2 lane preview look).
    local pad  = math.max(2, h * 0.15)
    local yTop = y0 + pad
    local yBot = y0 + h - pad

    -- Classify a tick at qn position p into 'bar' (downbeat),
    -- 'midBar' (the bar's midpoint when it lands on a beat — true in
    -- 4/4, 6/8; false in 3/4, 2/2), 'beat' (any other beat), or nil
    -- (offbeat). Shading treats midBar as a beat; dot sizing promotes
    -- it to bar tier.
    local function isInt(x)   return math.abs(x - util.round(x)) < 1e-9 end
    local midIsBeat           = shadeMeter and isInt((qpb/2) / beat)
    local function classify(p)
      if not isInt(p / beat) then return nil end
      if isInt(p / qpb) then return 'bar' end
      if midIsBeat and isInt((p - qpb/2) / qpb) then return 'midBar' end
      return 'beat'
    end

    if shadeMeter then
      local SHADE = { bar = 'rowBarStart', midBar = 'rowBeat', beat = 'rowBeat' }
      for i = 0, N - 1 do
        local key = SHADE[classify((i / N) * periodQN)]
        if key then
          local cx = x0 + i * cellW
          ImGui.DrawList_AddRectFilled(dl, cx, yTop, cx + cellW, yBot, chrome.colour(key))
        end
      end
    end

    -- 1px vertical dividers at every cell boundary, palette pale enough to
    -- sit behind the dots — same role the main lane strip uses.
    local divider = chrome.colour('laneRowDivider')
    for i = 0, N do
      local gx = x0 + (i / N) * w
      ImGui.DrawList_AddLine(dl, gx, yTop, gx, yBot, divider, 1)
    end

    -- Filled dots at the swung image of each unswung tick. Three sizes
    -- so the meter reads at a glance: bar/mid-bar > beat > offbeat.
    -- Atom preview (no shadeMeter) takes the middle size throughout.
    local factors = materialise(composite)
    local rBig    = math.max(2, h * 0.18)
    local rMid    = math.max(2, h * 0.14)
    local rSmall  = math.max(2, h * 0.10)
    local cy      = y0 + h / 2
    for i = 0, N - 1 do
      local p  = (i / N) * periodQN
      local pS = timing.applyFactors(factors, p)
      local sx = x0 + (pS / periodQN) * w
      local tier = shadeMeter and classify(p) or 'beat'
      local r    = (tier == 'bar' or tier == 'midBar') and rBig
                or  tier == 'beat'                     and rMid
                or  rSmall
      ImGui.DrawList_AddCircleFilled(dl, sx, cy, r, SWING_MARK)
    end

    ImGui.Dummy(ctx, w, h)
  end

  local function swingRead()
    return cm:get('swings')[state.name]
  end

  -- Tolerant accessor: bare {} and {factors={}} both mean identity. Read-only;
  -- write paths deepClone, then mutate factors[].
  local function readFactors(composite)
    return (composite or {}).factors or {}
  end

  -- QN value of an optional period-shaped slot (scalar, {n,d}, or nil).
  local function phaseQN(p) return p and timing.periodQN(p) or 0 end

  --@map:contract compares composite phase, per-factor phase, period, atom and shift — phase fields normalise to QN before comparing, so {1,2} and {2,4} count equal
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

  --@map:contract sole write path; idempotent on equal composites; the active-take refresh happens via vm:setSwingComposite's configChanged broadcast (granular per-channel stale-mark + tm:rebuild)
  local function swingWrite(composite)
    if compositesEqual(swingRead() or {}, composite) then return end
    vm:setSwingComposite(state.name, composite)
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

  --@map:contract default new factor is identity (atom='id', shift=0, period=1) — visually inert until edited
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

  local function drawFactorRow(i, f, availW)
    ImGui.PushID(ctx, i)

    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, string.format('%d.', i))
    ImGui.SameLine(ctx)

    local atomIdx = 0
    for k, a in ipairs(SWING_ATOMS) do if a == f.atom then atomIdx = k - 1; break end end
    ImGui.SetNextItemWidth(ctx, 90)
    local rv, newIdx = ImGui.Combo(ctx, '##atom', atomIdx, SWING_ATOMS_Z)
    if rv then
      local newAtom  = SWING_ATOMS[newIdx + 1]
      local lo, hi   = shiftCap({ atom = newAtom, period = f.period }, state.wild)
      local shift    = f.shift or 0
      if     shift < lo then shift = lo * 0.999
      elseif shift > hi then shift = hi * 0.999 end
      patchFactor(i, { atom = newAtom, shift = shift })
    end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then commit() end

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
    ImGui.SetNextItemWidth(ctx, 90)
    local ppC    = timing.atomMeta[f.atom].pulsesPerCycle
    local tileQN = timing.atomTilePeriod(f)
    local pIdx   = periodPresetIndex(tileQN)
    local items = {}
    for _, p in ipairs(PERIOD_PRESETS) do items[#items+1] = p.label end
    if pIdx == 0 then items[#items+1] = periodLabel(tileQN) end
    local itemsZ = table.concat(items, '\0') .. '\0\0'
    local curIdx = pIdx > 0 and (pIdx - 1) or #PERIOD_PRESETS
    local rvP, newPIdx = ImGui.Combo(ctx, '##per', curIdx, itemsZ)
    if rvP and newPIdx + 1 <= #PERIOD_PRESETS then
      -- Scale shift in QN by the period ratio so the resolved s = shift/tileQN
      -- is invariant — slope and feel survive the period change.
      local newPeriod = periodOverPPC(PERIOD_PRESETS[newPIdx + 1].period, ppC)
      local scale     = timing.periodQN(newPeriod) / timing.periodQN(f.period)
      local shift     = (f.shift or 0) * scale
      local lo, hi    = shiftCap({ atom = f.atom, period = newPeriod }, state.wild)
      if     shift < lo then shift = lo * 0.999
      elseif shift > hi then shift = hi * 0.999 end
      patchFactor(i, { period = newPeriod, shift = shift })
    end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then commit() end

    -- Per-factor phase: slides this factor's fixed-point lattice. Range is
    -- [0, T); writes wrap on overflow so dragging never lands outside the
    -- canonical interval.
    ImGui.SameLine(ctx)
    ImGui.AlignTextToFramePadding(ctx)
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
    if ImGui.ArrowButton(ctx, '##up', ImGui.Dir_Up)   then moveFactor(i, -1) end
    ImGui.SameLine(ctx)
    if ImGui.ArrowButton(ctx, '##dn', ImGui.Dir_Down) then moveFactor(i,  1) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'x')                         then removeFactor(i)  end

    local _, qpb  = meterQN()
    local nBars   = math.max(1, math.ceil(timing.atomTilePeriod(f) / qpb - 1e-9))
    drawSwingGrid({ factors = { f } }, nBars * qpb, state.rpb, availW, 28, true)

    ImGui.PopID(ctx)
  end

  -- Generous estimate — better to show a few px of empty space than to
  -- clip the add-factor button at the bottom.
  local function idealSwingHeight(nFactors)
    return 130         -- chrome: padding + title row + 2 separators + composite preview + add button
         + nFactors * 72  -- controls row + factor preview + separator + spacing
  end

  local function idealSwingWidth() return 560 end

  local function draw()
    if not state then return end

    local composite = (state.name and swingRead()) or {}
    local n = #readFactors(composite)

    -- First-time default; then max height = viewport so auto-grow
    -- stays on-screen. Width is user-resizable thereafter.
    local _, vpH = ImGui.Viewport_GetSize(ImGui.GetMainViewport(ctx))
    ImGui.SetNextWindowSizeConstraints(ctx, 400, 120, 9999, vpH)
    ImGui.SetNextWindowSize(ctx, 560, 420, ImGui.Cond_FirstUseEver)

    local idealW = idealSwingWidth()
    if state.lastCount ~= n or (state.lastW or 560) < idealW then
      local w = math.max(state.lastW or 560, idealW)
      local h = math.min(idealSwingHeight(n), vpH)
      ImGui.SetNextWindowSize(ctx, w, h, ImGui.Cond_Always)
      state.lastCount = n
    end

    chrome.pushChromeWindow()
    local visible, open = ImGui.Begin(ctx, 'Swing', true,
      ImGui.WindowFlags_NoDecoration | ImGui.WindowFlags_NoDocking)
    if not open then state = nil end

    if visible and state then
      state.lastW = ImGui.GetWindowWidth(ctx)

      if ImGui.IsWindowFocused(ctx) and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
        state = nil
      end

      if state and not state.name then
        -- CREATE MODE
        ImGui.Text(ctx, 'No swing slot is set.')
        ImGui.Text(ctx, 'Name:')
        ImGui.SameLine(ctx)
        ImGui.SetNextItemWidth(ctx, 240)
        local rv, buf = ImGui.InputText(ctx, '##newname', state.createBuf,
          ImGui.InputTextFlags_EnterReturnsTrue)
        state.createBuf = buf
        ImGui.SameLine(ctx)
        local confirm = rv or ImGui.Button(ctx, 'Create new swing')
        if confirm then
          local name = buf and buf:match('^%s*(.-)%s*$')
          local lib  = cm:get('swings')
          if not name or name == '' then
            state.createError = 'Name required.'
          elseif lib[name] then
            state.createError = 'Name already in use.'
          else
            vm:setSwingComposite(name, {})
            vm:setSwingSlot(name)
            state.name        = name
            state.snapshot    = {}
            state.createBuf   = ''
            state.createError = nil
          end
        end
        if state and state.createError then
          ImGui.TextColored(ctx, SWING_ERR, state.createError)
        end
      elseif state then
        -- EDIT MODE — toolbar row mirrors the main toolbar's chrome:
        -- (10, 3) FramePadding, vertical separators between groups,
        -- compact checkbox, manual ▾ on the rpb picker (smaller than
        -- ImGui.Combo's auto-arrow). Padding push is scoped to the row;
        -- the factor strip below uses the inherited padding.
        ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 10, 3)

        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, 'Editing: ' .. state.name)
        ImGui.SameLine(ctx, 0, 12)
        local dirty = not compositesEqual(composite, state.snapshot)
        chrome.disabledIf(not dirty, function()
          if ImGui.Button(ctx, 'Reset') then
            swingWrite(util.deepClone(state.snapshot) or {})
            commit()
          end
        end)

        ImGui.SameLine(ctx, 0, 12)
        chrome.verticalSeparator()
        ImGui.SameLine(ctx, 0, 12)

        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, 'Rows/qn:')
        ImGui.SameLine(ctx, 0, 6)
        -- Button + popup, mirroring chrome.drawPicker (manual ▾ glyph at
        -- font size, smaller than ImGui.Combo's frame-tall arrow).
        local rpbBtn = tostring(state.rpb) .. ' \xe2\x96\xbe##rpb'
        if ImGui.Button(ctx, rpbBtn) then ImGui.OpenPopup(ctx, '##rpb_popup') end
        local btnX = ImGui.GetItemRectMin(ctx)
        local _, btnY = ImGui.GetItemRectMax(ctx)
        ImGui.SetNextWindowPos(ctx, btnX, btnY, ImGui.Cond_Appearing)
        if ImGui.BeginPopup(ctx, '##rpb_popup', ImGui.WindowFlags_NoNav) then
          for _, v in ipairs(RPB_CHOICES) do
            if ImGui.Selectable(ctx, tostring(v), v == state.rpb) then
              state.rpb = v
            end
          end
          ImGui.EndPopup(ctx)
        end

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

        ImGui.PopStyleVar(ctx, 1)
        ImGui.Separator(ctx)
        local availW       = ImGui.GetContentRegionAvail(ctx)
        local _, qpb       = meterQN()
        local lcmQN        = timing.compositePeriodQN(composite)
        local nBars        = math.max(1, math.ceil(lcmQN / qpb - 1e-9))
        drawSwingGrid(composite, nBars * qpb,
                      state.rpb, availW, 32, true)
        ImGui.Separator(ctx)

        for i, f in ipairs(readFactors(composite)) do
          drawFactorRow(i, f, availW)
        end

        if ImGui.Button(ctx, '+ add factor') then addFactor() end
      end
    end
    ImGui.End(ctx)
    chrome.popChromeWindow()
  end

  ----- Public

  local self = {}

  --@map:contract no-op when already open; snapshot is current cm composite at open time, used for Reset and dirty-check
  function self:open()
    if state then return end
    local name = cm:get('swing')
    local lib  = cm:get('swings')
    state = {
      name      = name,
      snapshot  = name and lib[name] or nil,
      createBuf = '',
      rpb       = 4,
    }
  end

  function self:render() draw() end

  function self:isOpen() return state ~= nil end

  return self
end
