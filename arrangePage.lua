-- See docs/arrangePage.md for the model.
-- @noindex

--invariant: render-only — cursor + scroll live in av (module-locals); track list + slot palette come from am, which reads cm/REAPER fresh each query. Page holds no persistent state of its own.
--invariant: arrange page is project-wide — bind() takes no take and never re-keys cm; the tracker take and the sampler track are unaffected by switching to / from arrange.
--invariant: cursor-nav commands live in cmgr:scope('arrange'); coord pushes the scope on activation. Names overlap with the tracker scope's arrow commands but scopes don't stack — only one is active at a time.

local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

--contract: owns the arrange substack: builds am and av internally; coord passes only primitives (cm, cmgr, chrome, gui).
local cm, cmgr, chrome, gui = (...).cm, (...).cmgr, (...).chrome, (...).gui

local ctx = gui and gui.ctx or nil

local am = util.instantiate('arrangeManager', { cm = cm })
local av = util.instantiate('arrangeView',    { cm = cm })

local ap = {}

----- Render helpers

-- Row label = QN at the row's top edge. beatPerRow is integer-valued in
-- normal use (1, 4, 8, 16); show the QN as an integer.
local function rowLabel(row)
  return string.format('%4d', math.floor(av:rowToQN(row) + 0.5))
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

  local function pushBodyStyles()
    ImGui.PushStyleColor(ctx, ImGui.Col_Text,             chrome.colour('text'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TableHeaderBg,    chrome.colour('bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBg,       chrome.colour('bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBgAlt,    chrome.colour('bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderLight, chrome.colour('separator'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderStrong,chrome.colour('separator'))
  end
  local function popBodyStyles() ImGui.PopStyleColor(ctx, 6) end

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

  -- Single ImGui.Table — first column is the QN gutter, the rest are tracks.
  local cols = nTracks + 1
  -- Compute the table width from the column sum (gutter + N tracks).
  -- ImGui sizing policy otherwise lets the last column absorb slack;
  -- passing an explicit outer width that matches the columns sidesteps
  -- the policy entirely. Clamp to the body width so the host doesn't
  -- over-extend when there are many tracks (horizontal scroll arrives
  -- with the palette in a later phase).
  local QN_W, TRACK_W = 32, 72
  local tableW = math.min(w, QN_W + TRACK_W * nTracks)
  local flags  = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg
               | ImGui.TableFlags_ScrollY | ImGui.TableFlags_NoHostExtendX
  if not ImGui.BeginTable(ctx, 'arrange', cols, flags, tableW, h) then
    popBodyStyles()
    if dispatch then dispatch(self:focusState()) end
    return
  end

  ImGui.TableSetupColumn(ctx, '',   ImGui.TableColumnFlags_WidthFixed, QN_W)
  for i, tr in ipairs(tracks) do
    -- Fixed track width — zoom comes in a later phase via a cm-persisted px-per-track.
    -- Stretch would interact badly with the cursor's column addressing and ImGui's table nav.
    ImGui.TableSetupColumn(ctx, tr.name or string.format('Track %d', i),
                           ImGui.TableColumnFlags_WidthFixed, TRACK_W)
  end
  -- Shift text within the current table cell. align: 'r' right-aligns,
  -- 'c' centres. ImGui has no built-in alignment for Text — measure
  -- the live cell width (GetContentRegionAvail) and offset the cursor.
  -- TRACK_W is the column width including cell padding; the actual
  -- usable area is narrower, so we don't pass it in.
  local function alignedText(text, align)
    local cellW = ImGui.GetContentRegionAvail(ctx)
    local textW = ImGui.CalcTextSize(ctx, text)
    local pad   = align == 'r' and (cellW - textW)
                                 or math.floor((cellW - textW) / 2)
    if pad > 0 then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + pad) end
    ImGui.Text(ctx, text)
  end

  -- Manual header row, not TableHeadersRow: the headers are decorative,
  -- and TableHeadersRow makes them selectable, which steals ImGui's
  -- keyboard nav focus and renders a blue highlight that cycles between
  -- the cells as the user presses arrow keys.
  ImGui.TableNextRow(ctx, ImGui.TableRowFlags_Headers)
  ImGui.TableSetColumnIndex(ctx, 0)  -- gutter header is intentionally blank
  for i, tr in ipairs(tracks) do
    ImGui.TableSetColumnIndex(ctx, i)
    alignedText(tr.name or string.format('Track %d', i), 'c')
  end

  -- Capacity: how many body rows fit in the remaining region right now.
  local _, regionH = ImGui.GetContentRegionAvail(ctx)
  local rowH       = math.max(1, ImGui.GetTextLineHeightWithSpacing(ctx))
  local visRows    = math.max(1, math.floor(regionH / rowH))
  av:setGridSize(visRows, nTracks)
  av:setMaxCol(nTracks)

  local sr, sc      = av:scroll()
  local curRow, curCol = av:cursorRow(), av:cursorCol()

  -- Bar / phrase highlight tints. 16 QN per bar (4/4), 64 QN per 4-bar
  -- phrase. rowBeat is defined as palette.highlight at alpha 0.4; the
  -- phrase tint reuses the same hue at full opacity so phrases read
  -- stronger than the bars they contain.
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
  popBodyStyles()

  if dispatch then dispatch(self:focusState()) end
end

function ap:renderStatusBar(_)
  if not ctx then return end
  ImGui.Text(ctx, string.format(
    'arrange | row %d  col %d  | %g beats/row',
    av:cursorRow(), av:cursorCol(), av:beatPerRow()))
end

--contract: focusState mirrors samplePage — picker or any active ImGui item suppresses commands.
function ap:focusState()
  if not ctx then return { suppressKbd = false, acceptCmds = false } end
  local pa = chrome and chrome.pickerIsActive() or false
  return {
    suppressKbd = pa,
    acceptCmds  = (not pa) and not ImGui.IsAnyItemActive(ctx),
  }
end

function ap:handleInput() end
function ap:save()        end
function ap:load()        end

--invariant: arrange-scope cursor-nav: arrow keys move cursor by 1 row / 1 col. Negative coords clamp in av; upper-bound clamping belongs to the page once it knows project size (deferred — phase 4+ adds Home/End/PgUp/PgDn that need real bounds).
local arrange = cmgr:scope('arrange')
arrange:registerAll {
  cursorUp    = function() av:setCursor(av:cursorRow() - 1, av:cursorCol()) end,
  cursorDown  = function() av:setCursor(av:cursorRow() + 1, av:cursorCol()) end,
  cursorLeft  = function() av:setCursor(av:cursorRow(),     av:cursorCol() - 1) end,
  cursorRight = function() av:setCursor(av:cursorRow(),     av:cursorCol() + 1) end,
}
arrange:bindAll {
  cursorUp    = { { ImGui.Key_UpArrow    } },
  cursorDown  = { { ImGui.Key_DownArrow  } },
  cursorLeft  = { { ImGui.Key_LeftArrow  } },
  cursorRight = { { ImGui.Key_RightArrow } },
}

return ap
