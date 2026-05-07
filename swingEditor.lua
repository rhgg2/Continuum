-- See docs/swingEditor.md for the model.
-- @noindex

--@map:invariant editor owns no swing data; composite lives in cm:get('swings')[name] and is read fresh each frame via swingRead
--@map:invariant all writes route through swingWrite, which short-circuits on equality and then fires vm:setSwingComposite + vm:reswingPreset
--@map:invariant state == nil iff editor is closed; open() is a no-op when already open; Esc / Begin-close clears state
--@map:invariant snapshot is captured at open() and never mutated; Reset writes a deepClone of it
--@map:invariant shift is in QN and atom-independent — preserved across atom swap, only re-clamped to the new atom's cap
--@map:invariant soft cap = min(SWING_SOFT_QN, hard); Wild unlocks hard = T_tile · atomMeta.range; cap == 0 freezes the slider
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

function newSwingEditor(vm, cm, chrome, ctx)
  local state = nil

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

  local function shiftCap(factor, wild)
    local hard = timing.atomTilePeriod(factor) * timing.atomMeta[factor.atom].range
    return wild and hard or math.min(SWING_SOFT_QN, hard)
  end

  --@map:contract Factor[] -> ResolvedFactor[] in QN units (T = atomTilePeriod, not PPQ); local to the editor's QN-space preview
  local function materialise(composite)
    local out = {}
    for i, f in ipairs(composite) do
      local T = timing.atomTilePeriod(f)
      out[i] = { S = timing.atoms[f.atom](f.shift / T), T = T }
    end
    return out
  end

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

  --@map:contract compares period via periodQN, so {1,2} and {2,4} count as equal — equality is on the QN value, not the literal table
  local function compositesEqual(a, b)
    a, b = a or {}, b or {}
    if #a ~= #b then return false end
    for i, fa in ipairs(a) do
      local fb = b[i]
      if fa.atom ~= fb.atom or fa.shift ~= fb.shift
         or math.abs(timing.periodQN(fa.period) - timing.periodQN(fb.period)) > 1e-12 then
        return false
      end
    end
    return true
  end

  --@map:contract sole write path; idempotent on equal composites; reswing is paired with the composite write so old→new delta is consistent
  local function swingWrite(composite)
    if compositesEqual(swingRead() or {}, composite) then return end
    vm:setSwingComposite(state.name, composite)
    vm:reswingPreset(state.name)
  end

  local function patchFactor(i, patch)
    local new = util.deepClone(swingRead()) or {}
    if not new[i] then return end
    util.assign(new[i], patch)
    swingWrite(new)
  end

  --@map:contract default new factor is identity (atom='id', shift=0, period=1) — visually inert until edited
  local function addFactor()
    local new = util.deepClone(swingRead()) or {}
    new[#new+1] = { atom = 'id', shift = 0, period = 1 }
    swingWrite(new)
  end

  local function removeFactor(i)
    local new = util.deepClone(swingRead()) or {}
    table.remove(new, i)
    swingWrite(new)
  end

  local function moveFactor(i, dir)
    local src = swingRead() or {}
    local j = i + dir
    if j < 1 or j > #src then return end
    local new = util.deepClone(src)
    new[i], new[j] = new[j], new[i]
    swingWrite(new)
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
      local newAtom = SWING_ATOMS[newIdx + 1]
      local cap     = shiftCap({ atom = newAtom, period = f.period }, state.wild)
      local shift   = f.shift or 0
      if math.abs(shift) > cap then shift = (shift < 0 and -1 or 1) * cap * 0.999 end
      patchFactor(i, { atom = newAtom, shift = shift })
    end

    ImGui.SameLine(ctx)
    local cap    = shiftCap(f, state.wild)
    local frozen = cap == 0
    chrome.disabledIf(frozen, function()
      ImGui.SetNextItemWidth(ctx, 150)
      local lo, hi = -cap * 0.999, cap * 0.999
      local rvA, newShift = ImGui.SliderDouble(ctx, '##shift', f.shift or 0, lo, hi, '%.3f qn')
      -- Continuous reswing: swingWrite reads the stored composite as the
      -- "old" side of the delta, so per-frame calls chain into the right
      -- old→now transformation as the slider drags.
      if rvA then
        local new = util.deepClone(swingRead()) or {}
        if new[i] then new[i].shift = newShift; swingWrite(new) end
      end
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
      patchFactor(i, { period = periodOverPPC(PERIOD_PRESETS[newPIdx + 1].period, ppC) })
    end

    ImGui.SameLine(ctx)
    if ImGui.ArrowButton(ctx, '##up', ImGui.Dir_Up)   then moveFactor(i, -1) end
    ImGui.SameLine(ctx)
    if ImGui.ArrowButton(ctx, '##dn', ImGui.Dir_Down) then moveFactor(i,  1) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'x')                         then removeFactor(i)  end

    local _, qpb  = meterQN()
    local nBars   = math.max(1, math.ceil(timing.atomTilePeriod(f) / qpb - 1e-9))
    drawSwingGrid({ f }, nBars * qpb, state.rpb, availW, 28, true)

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
    local n = #composite

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
          if ImGui.Button(ctx, 'Reset') then swingWrite(util.deepClone(state.snapshot) or {}) end
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

        ImGui.PopStyleVar(ctx, 1)
        ImGui.Separator(ctx)
        local availW       = ImGui.GetContentRegionAvail(ctx)
        local _, qpb       = meterQN()
        local lcmQN        = timing.compositePeriodQN(composite)
        local nBars        = math.max(1, math.ceil(lcmQN / qpb - 1e-9))
        drawSwingGrid(composite, nBars * qpb,
                      state.rpb, availW, 32, true)
        ImGui.Separator(ctx)

        for i, f in ipairs(composite) do
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
