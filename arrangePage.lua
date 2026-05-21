-- See docs/arrangePage.md for the model.
-- @noindex

--invariant: render-only — cursor + scroll live in av (module-locals); track list + slot palette come from am, which reads cm/REAPER fresh each query. Page holds no persistent state of its own.
--invariant: arrange page is project-wide — bind() takes no take and never re-keys cm; the tracker take and the sampler track are unaffected by switching to / from arrange.
--invariant: cursor-nav commands live in cmgr:scope('arrange'); coord pushes the scope on activation. Names overlap with the tracker scope's arrow commands but scopes don't stack — only one is active at a time.
--invariant: body splits horizontally into a grid pane (variable width) and a fixed-width palette pane (PALETTE_W). The palette shows slots for the focused track, i.e. the track under av:cursorCol() — no separate "focused track" pointer.

local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

--contract: owns the arrange substack: builds am and av internally; coord passes only primitives (cm, cmgr, chrome, gui).
local cm, cmgr, chrome, gui = (...).cm, (...).cmgr, (...).chrome, (...).gui

local ctx = gui and gui.ctx or nil
-- gui.font is monospace (Source Code Pro) attached at context create;
-- we push it for the slot-key cell so 62 base62 keys align in a column.
local monoFont = gui and gui.font or nil
local uiSize   = gui and gui.fontSize and gui.fontSize.ui or 12

local am = util.instantiate('arrangeManager', { cm = cm })
local av = util.instantiate('arrangeView',    { cm = cm })

local ap = {}

local PALETTE_W = 200
-- Gap between grid and palette panes; the 1px vrule sits in the
-- middle of the gap so neither pane edge touches the line.
local PANE_GAP  = 11
local QN_W, TRACK_W = 32, 72
-- Palette row column widths: monospace key, kind glyph, name fills.
local SLOT_KEY_W, SLOT_KIND_W = 18, 16

-- Unified modal state. `modal` is nil when no modal is open, or
-- { kind = 'rename'|'create'|'delete', ... } when one is. Pinning the
-- (track, slot) into modal at open-time means the cursor moving
-- mid-edit can't retarget the action.
--
-- modalFocus is consumed on the first frame each modal draws to seat
-- keyboard focus in its InputText. modalOpenAtFrameStart is captured
-- at the top of renderBody so focusState can deny acceptCmds for the
-- entire frame on which a modal closes — Enter would otherwise reach
-- the root-scope quit binding because CloseCurrentPopup deactivates
-- the InputText same-frame, flipping IsAnyItemActive to false before
-- dispatch runs.
local MODAL_TITLE             = 'arrange modal'
local modal                   = nil   -- { kind, ... } | nil
local modalFocus              = false
local modalOpenAtFrameStart   = false

----- Style + draw helpers

local function pushBodyStyles()
  ImGui.PushStyleColor(ctx, ImGui.Col_Text,             chrome.colour('text'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TableHeaderBg,    chrome.colour('bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBg,       chrome.colour('bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBgAlt,    chrome.colour('bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderLight, chrome.colour('separator'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderStrong,chrome.colour('separator'))
end
local function popBodyStyles() ImGui.PopStyleColor(ctx, 6) end

-- Shift text within the current table cell. 'r' right-aligns; 'c'
-- centres. ImGui has no built-in alignment for Text — measure the
-- live cell width via GetContentRegionAvail and offset the cursor.
local function alignedText(text, align)
  local cellW = ImGui.GetContentRegionAvail(ctx)
  local textW = ImGui.CalcTextSize(ctx, text)
  local pad   = align == 'r' and (cellW - textW)
                               or math.floor((cellW - textW) / 2)
  if pad > 0 then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + pad) end
  ImGui.Text(ctx, text)
end

-- Row label = QN at the row's top edge. beatPerRow is integer-valued
-- in normal use (1, 4, 8, 16); show the QN as an integer.
local function rowLabel(row)
  return string.format('%4d', math.floor(av:rowToQN(row) + 0.5))
end

----- Grid pane

local function renderGrid(tracks, nTracks)
  local cols = nTracks + 1
  -- Clamp the table to the column sum so the last column doesn't
  -- absorb slack; clamp to pane width when nTracks is large
  -- (horizontal scroll arrives with palette navigation in a later phase).
  local paneW   = select(1, ImGui.GetContentRegionAvail(ctx))
  local tableW  = math.min(paneW, QN_W + TRACK_W * nTracks)
  local _, paneH = ImGui.GetContentRegionAvail(ctx)
  local flags  = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg
               | ImGui.TableFlags_ScrollY | ImGui.TableFlags_NoHostExtendX
  if not ImGui.BeginTable(ctx, 'arrange', cols, flags, tableW, paneH) then
    return
  end

  ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthFixed, QN_W)
  for i, tr in ipairs(tracks) do
    ImGui.TableSetupColumn(ctx, tr.name or string.format('Track %d', i),
                           ImGui.TableColumnFlags_WidthFixed, TRACK_W)
  end

  -- Manual header row, not TableHeadersRow: headers are decorative,
  -- and TableHeadersRow makes them selectable, which steals ImGui's
  -- keyboard nav focus and cycles a blue highlight between them.
  ImGui.TableNextRow(ctx, ImGui.TableRowFlags_Headers)
  ImGui.TableSetColumnIndex(ctx, 0)  -- blank gutter header
  for i, tr in ipairs(tracks) do
    ImGui.TableSetColumnIndex(ctx, i)
    alignedText(tr.name or string.format('Track %d', i), 'c')
  end

  local _, regionH = ImGui.GetContentRegionAvail(ctx)
  local rowH       = math.max(1, ImGui.GetTextLineHeightWithSpacing(ctx))
  local visRows    = math.max(1, math.floor(regionH / rowH))
  av:setGridSize(visRows, nTracks)
  av:setMaxCol(nTracks)

  local sr, sc      = av:scroll()
  local curRow, curCol = av:cursorRow(), av:cursorCol()

  -- Phrase tint reuses the bar tint's hue at full opacity (rowBeat is
  -- palette.highlight at alpha 0.4) so phrases read stronger than the
  -- bars they contain.
  local rb            = chrome.colour('rowBeat')
  local r, g, b       = ImGui.ColorConvertU32ToDouble4(rb)
  local barRowTint    = rb
  local phraseRowTint = ImGui.ColorConvertDouble4ToU32(r, g, b, 1.0)

  for r = 0, visRows - 1 do
    local row = sr + r
    ImGui.TableNextRow(ctx)

    local qn = math.floor(av:rowToQN(row) + 0.5)
    if qn > 0 and qn % 64 == 0 then
      ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg0, phraseRowTint)
    elseif qn > 0 and qn % 16 == 0 then
      ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg0, barRowTint)
    end

    ImGui.TableSetColumnIndex(ctx, 0)
    alignedText(rowLabel(row), 'r')

    for c = 0, nTracks - 1 do
      local col = sc + c
      if col < nTracks then
        ImGui.TableSetColumnIndex(ctx, c + 1)
        if row == curRow and col == curCol then
          ImGui.Text(ctx, '>')
        elseif col == curCol then
          ImGui.Text(ctx, '|')
        else
          ImGui.Text(ctx, '')
        end
      end
    end
  end

  ImGui.EndTable(ctx)
end

----- Palette pane

-- Locate the slot entry in trackSlots() output (a packed array, not
-- indexed by slotIdx). Returns nil when no slot is focused or the
-- focused slot index isn't currently populated.
local function focusedSlotEntry(slots, slotIdx)
  if slotIdx == nil then return nil end
  for _, s in ipairs(slots) do
    if s.idx == slotIdx then return s end
  end
  return nil
end

-- Render the header inside a 1-col table with TableRowFlags_Headers so
-- the vertical text offset (cell padding) matches the grid's first
-- header row exactly — the two "Track N" labels line up across the
-- gap without manual Y tweaking.
local function renderPaletteHeader(focusedTrack)
  local trackLabel = focusedTrack
    and (focusedTrack.name ~= '' and focusedTrack.name
         or string.format('Track %d', focusedTrack.idx + 1))
    or '(no track)'
  if ImGui.BeginTable(ctx, '##paletteHdr', 1) then
    ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthStretch)
    ImGui.TableNextRow(ctx, ImGui.TableRowFlags_Headers)
    ImGui.TableSetColumnIndex(ctx, 0)
    alignedText(trackLabel, 'c')
    ImGui.EndTable(ctx)
  end
end

local function openModal(state)
  modal      = state
  modalFocus = true
  ImGui.OpenPopup(ctx, MODAL_TITLE)
end

local function openRenameModal(trackIdx, slotIdx, currentName)
  openModal{ kind = 'rename', trackIdx = trackIdx, slotIdx = slotIdx,
             buf = currentName or '' }
end

local function openDeleteModal(trackIdx, slot)
  openModal{ kind = 'delete', trackIdx = trackIdx, slotIdx = slot.idx,
             slotKey = am:keyForSlot(slot.idx),
             slotName = slot.name ~= '' and slot.name
                                       or string.format('(slot %d)', slot.idx) }
end

-- Default length 4 rows — matches the design's default phrase length
-- ("create something musical-sized, not a one-row stub"). User can
-- override in the modal.
local CREATE_DEFAULT_ROWS = 4
local function openCreateModal(trackIdx, qnPos)
  openModal{ kind = 'create', trackIdx = trackIdx, qnPos = qnPos,
             nameBuf = '', rowsBuf = tostring(CREATE_DEFAULT_ROWS) }
end

local function renderPaletteActions(focusedTrack, focusedSlot)
  local trackIdx = focusedTrack and focusedTrack.idx
  local canActOnSlot = focusedSlot ~= nil

  chrome.disabledIf(not canActOnSlot, function()
    if ImGui.Button(ctx, 'rename##slot') then
      openRenameModal(trackIdx, focusedSlot.idx, focusedSlot.name)
    end
  end)
  ImGui.SameLine(ctx, 0, 4)
  chrome.disabledIf(not canActOnSlot, function()
    if ImGui.Button(ctx, 'del##slot') then
      openDeleteModal(trackIdx, focusedSlot)
    end
  end)
end

-- Three columns so the key/kind/name align vertically across rows
-- without depending on a monospace font for the whole line. The key
-- cell uses the monospace font (it's a hotkey to press); kind and
-- name use the default UI font. Selectable lives in col 0 with
-- SpanAllColumns so the entire row is the click target; we paint the
-- key text on top with SameLine.
local function renderPaletteList(slots)
  if #slots == 0 then
    ImGui.TextDisabled(ctx, '(no slots)')
    return
  end
  local sel = av:paletteSlot()
  if not ImGui.BeginTable(ctx, '##paletteList', 3) then return end
  ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthFixed,   SLOT_KEY_W)
  ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthFixed,   SLOT_KIND_W)
  ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthStretch)

  for _, slot in ipairs(slots) do
    ImGui.TableNextRow(ctx)
    ImGui.TableSetColumnIndex(ctx, 0)
    if ImGui.Selectable(ctx, '##slot' .. slot.idx, sel == slot.idx,
                        ImGui.SelectableFlags_SpanAllColumns) then
      av:setPaletteSlot(slot.idx)
    end
    ImGui.SameLine(ctx, 0, 0)
    if monoFont then ImGui.PushFont(ctx, monoFont, uiSize) end
    ImGui.Text(ctx, am:keyForSlot(slot.idx))
    if monoFont then ImGui.PopFont(ctx) end

    ImGui.TableSetColumnIndex(ctx, 1)
    ImGui.Text(ctx, slot.kind == 'midi' and 'M' or 'A')

    ImGui.TableSetColumnIndex(ctx, 2)
    ImGui.Text(ctx, slot.name ~= '' and slot.name
                    or string.format('(slot %d)', slot.idx))
  end
  ImGui.EndTable(ctx)
end

-- Modal lives inside the palette child window. NoNav prevents ImGui's
-- popup nav from stealing keys from the InputText; AlwaysAutoResize
-- because all three modals are small. chrome.pushChromeWindow wraps
-- Begin/End so the popup inherits parchment/chrome styles instead of
-- ImGui's dark defaults.
--
-- Single popup id (MODAL_TITLE) drives all three kinds — the popup
-- can't be open in two configurations simultaneously, and one id keeps
-- the open/close bookkeeping symmetrical. Self-heal: if the modal
-- state was set but ImGui's popup queue lost it (e.g. command opened
-- the popup from outside any window), re-open here.
local function renderModal()
  if not modal then return end
  if not ImGui.IsPopupOpen(ctx, MODAL_TITLE) then
    ImGui.OpenPopup(ctx, MODAL_TITLE)
  end
  local flags = ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoNav
  chrome.pushChromeWindow()
  if ImGui.BeginPopupModal(ctx, MODAL_TITLE, nil, flags) then
    local function close() modal = nil; ImGui.CloseCurrentPopup(ctx) end

    if modal.kind == 'rename' then
      if modalFocus then ImGui.SetKeyboardFocusHere(ctx); modalFocus = false end
      local commit, buf = ImGui.InputText(ctx, '##rename', modal.buf,
                                          ImGui.InputTextFlags_EnterReturnsTrue)
      if commit then
        am:renameSlot(modal.trackIdx, modal.slotIdx, buf)
        close()
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Cancel') or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
        close()
      end

    elseif modal.kind == 'create' then
      ImGui.Text(ctx, 'Name')
      if modalFocus then ImGui.SetKeyboardFocusHere(ctx); modalFocus = false end
      local _, nb = ImGui.InputText(ctx, '##createName', modal.nameBuf)
      modal.nameBuf = nb
      ImGui.Text(ctx, 'Length (rows)')
      local commitR, rb = ImGui.InputText(ctx, '##createRows', modal.rowsBuf,
                                          ImGui.InputTextFlags_EnterReturnsTrue)
      modal.rowsBuf = rb
      local ok     = commitR or ImGui.Button(ctx, 'OK')
      ImGui.SameLine(ctx)
      local cancel = ImGui.Button(ctx, 'Cancel') or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape)
      if ok then
        local rows = tonumber(modal.rowsBuf) or CREATE_DEFAULT_ROWS
        rows = math.max(1, math.floor(rows))
        local lengthQN = rows * av:beatPerRow()
        local slotIdx = am:createAndDropMidi(modal.trackIdx, modal.qnPos,
                                             lengthQN, modal.nameBuf)
        if slotIdx then av:setPaletteSlot(slotIdx) end
        close()
      elseif cancel then
        close()
      end

    elseif modal.kind == 'delete' then
      ImGui.Text(ctx, string.format('Delete slot %s "%s"?',
                                    modal.slotKey, modal.slotName))
      ImGui.Text(ctx, 'Removes every instance on the track. (y/n)')
      local yes = ImGui.Button(ctx, 'Delete')
                  or ImGui.IsKeyPressed(ctx, ImGui.Key_Y)
                  or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
      ImGui.SameLine(ctx)
      local no  = ImGui.Button(ctx, 'Cancel')
                  or ImGui.IsKeyPressed(ctx, ImGui.Key_N)
                  or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape)
      if yes then
        am:deleteSlot(modal.trackIdx, modal.slotIdx)
        av:setPaletteSlot(nil)
        close()
      elseif no then
        close()
      end
    end
    ImGui.EndPopup(ctx)
  end
  chrome.popChromeWindow()
end

local function renderPalette(tracks)
  -- tracks is 1-based; cursorCol is 0-based track index.
  local focusedTrack = tracks[av:cursorCol() + 1]
  local slots        = focusedTrack and am:trackSlots(focusedTrack.idx) or {}
  local focusedSlot  = focusedSlotEntry(slots, av:paletteSlot())

  -- Push chrome styles inside the palette child so buttons get
  -- toolbar colours, FrameBorderSize, etc. Body styles (parchment
  -- text + tables) already in effect from the renderBody-level push.
  chrome.pushChromeStyles()
  renderPaletteHeader(focusedTrack)
  renderPaletteActions(focusedTrack, focusedSlot)
  ImGui.Separator(ctx)
  renderPaletteList(slots)
  chrome.popChromeStyles()
  renderModal()
end

----------- PUBLIC

--contract: bind takes no take — arrange is project-wide. coord may call with no args (or a take, ignored).
function ap:bind() end
function ap:unbind() end

function ap:renderToolbarBits(_) end

--contract: read-only skeleton render — track-name header row, row-number gutter, empty body cells. Cursor cell + focused column are tinted. Take rectangles come in a later phase.
--contract: pushes parchment palette across the body (Col_Text, Col_TableHeaderBg, Col_TableRowBg, Col_TableBorder*) because coord pops chrome styles before body draw; without these the table inherits ImGui's dark defaults.
--contract: invokes the dispatch callback at end of body so arrange-scope arrow keys reach the dispatcher; samplePage and trackerPage follow the same pattern.
function ap:renderBody(_, w, h, dispatch)
  if not ctx then return end

  -- Capture at top of frame, not after the modal might have closed
  -- itself mid-frame. See modalOpenAtFrameStart comment.
  modalOpenAtFrameStart = (modal ~= nil)

  pushBodyStyles()

  local tracks  = am:projectTracks()
  local nTracks = #tracks
  if nTracks == 0 then
    ImGui.Text(ctx, '(no tracks in project)')
    av:setGridSize(0, 0)
    popBodyStyles()
    if dispatch then dispatch(self:focusState()) end
    return
  end

  local gridW = math.max(120, w - PALETTE_W - PANE_GAP)
  -- WindowFlags_NoNav suppresses the blue nav rect that Tab/arrow
  -- focus would otherwise draw around the whole grid child.
  if ImGui.BeginChild(ctx, '##arrangeGrid', gridW, h,
                      ImGui.ChildFlags_None,
                      ImGui.WindowFlags_NoNav) then
    renderGrid(tracks, nTracks)
  end
  ImGui.EndChild(ctx)

  -- 1 px vertical rule centred in PANE_GAP so neither pane edge
  -- touches the line. Darkest parchment shade (colour.text =
  -- palette.shade) ties it to the body palette instead of pure black.
  ImGui.SameLine(ctx, 0, 0)
  local sx, sy = ImGui.GetCursorScreenPos(ctx)
  local lineX  = sx + math.floor(PANE_GAP / 2)
  ImGui.DrawList_AddLine(ImGui.GetWindowDrawList(ctx),
    lineX, sy, lineX, sy + h, chrome.colour('text'), 1)
  ImGui.Dummy(ctx, PANE_GAP, h)
  ImGui.SameLine(ctx, 0, 0)

  if ImGui.BeginChild(ctx, '##arrangePalette', PALETTE_W, h,
                      ImGui.ChildFlags_None,
                      ImGui.WindowFlags_NoNav) then
    renderPalette(tracks)
  end
  ImGui.EndChild(ctx)

  popBodyStyles()
  if dispatch then dispatch(self:focusState()) end
end

function ap:renderStatusBar(_)
  if not ctx then return end
  ImGui.Text(ctx, string.format(
    'arrange | row %d  col %d  | %g beats/row',
    av:cursorRow(), av:cursorCol(), av:beatPerRow()))
end

--contract: focusState mirrors samplePage — picker or any active ImGui item suppresses commands. Also gated by modalOpenAtFrameStart so the Enter that commits any modal's InputText can't leak to root-scope bindings (notably quit) on the same frame.
function ap:focusState()
  if not ctx then return { suppressKbd = false, acceptCmds = false } end
  local pa = chrome and chrome.pickerIsActive() or false
  return {
    suppressKbd = pa,
    acceptCmds  = (not pa)
                  and not ImGui.IsAnyItemActive(ctx)
                  and not modalOpenAtFrameStart,
  }
end

function ap:handleInput() end
function ap:save()        end
function ap:load()        end

--invariant: arrange-scope cursor-nav: arrow keys move cursor by 1 row / 1 col. Negative coords clamp in av; upper-bound clamping belongs to the page once it knows project size (deferred — phase 4+ adds Home/End/PgUp/PgDn that need real bounds).
--invariant: 62 place commands (drop0..dropZ) sit in cmgr:scope('arrange'), one per base62 slot. Pressing a key with no slot defined at that index is a silent no-op (am:dropInstance returns nil). Length defaults to one row (beatPerRow) — a real snap selector lands with the toolbar.
--invariant: createSlot (Ctrl+Enter) opens the create modal — the *only* slot-minting gesture. Slots have no existence apart from items on the grid; rename/delete buttons in the palette act on existing slots.
local arrange = cmgr:scope('arrange')
-- Distinct names from tracker's cursorUp/Down/Left/Right: cmgr.commands
-- is flat, so re-registering the same name overwrites the gate and
-- silently breaks the other scope's binding. Reuse the keys, not the
-- name (see reference_commandmanager_limits).
arrange:registerAll {
  arrangeCursorUp    = function() av:setCursor(av:cursorRow() - 1, av:cursorCol()) end,
  arrangeCursorDown  = function() av:setCursor(av:cursorRow() + 1, av:cursorCol()) end,
  arrangeCursorLeft  = function() av:setCursor(av:cursorRow(),     av:cursorCol() - 1) end,
  arrangeCursorRight = function() av:setCursor(av:cursorRow(),     av:cursorCol() + 1) end,
  createSlot         = function() openCreateModal(av:cursorCol(), av:rowToQN(av:cursorRow())) end,
}
arrange:bindAll {
  arrangeCursorUp    = { { ImGui.Key_UpArrow    } },
  arrangeCursorDown  = { { ImGui.Key_DownArrow  } },
  arrangeCursorLeft  = { { ImGui.Key_LeftArrow  } },
  arrangeCursorRight = { { ImGui.Key_RightArrow } },
  createSlot         = { { ImGui.Key_Enter, ImGui.Mod_Ctrl } },
}

-- Place commands (drop0..dropZ). 0..9 → digit keys, 10..35 → letter
-- keys, 36..61 → Shift+letter. ImGui.Key_0 + n and Key_A + n are
-- contiguous (already exploited at coordinator.lua:53).
local function dropAt(slotIdx)
  return function()
    am:dropInstance(av:cursorCol(), slotIdx,
                    av:rowToQN(av:cursorRow()), av:beatPerRow())
  end
end
local function placeKey(slotIdx)
  if slotIdx < 10 then return { ImGui.Key_0 + slotIdx } end
  if slotIdx < 36 then return { ImGui.Key_A + (slotIdx - 10) } end
  return { ImGui.Key_A + (slotIdx - 36), ImGui.Mod_Shift }
end
local placeCmds, placeBinds = {}, {}
for i = 0, 61 do
  local name = 'drop' .. am:keyForSlot(i)
  placeCmds[name]  = dropAt(i)
  placeBinds[name] = { placeKey(i) }
end
arrange:registerAll(placeCmds)
arrange:bindAll(placeBinds)

return ap
