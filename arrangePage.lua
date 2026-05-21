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

-- Row label = QN at the row's top edge. Cheap because rowToQN is a multiply.
local function rowLabel(row)
  return string.format('%6.2f', av:rowToQN(row))
end

----------- PUBLIC

--contract: bind takes no take — arrange is project-wide. coord may call with no args (or a take, ignored).
function ap:bind() end
function ap:unbind() end

function ap:renderToolbarBits(_) end

--contract: read-only skeleton render — track-name header row, row-number gutter, empty body cells. Cursor cell + focused column are tinted. Take rectangles come in a later phase.
function ap:renderBody(_, w, h, _dispatch)
  if not ctx then return end

  local tracks  = am:projectTracks()
  local nTracks = #tracks
  if nTracks == 0 then
    ImGui.TextUnformatted(ctx, '(no tracks in project)')
    av:setGridSize(0, 0)
    return
  end

  -- Single ImGui.Table — first column is the QN gutter, the rest are tracks.
  local cols = nTracks + 1
  local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg
               | ImGui.TableFlags_ScrollY | ImGui.TableFlags_SizingFixedFit
  if not ImGui.BeginTable(ctx, 'arrange', cols, flags, w, h) then return end

  ImGui.TableSetupColumn(ctx, 'qn', ImGui.TableColumnFlags_WidthFixed, 64)
  for i, tr in ipairs(tracks) do
    ImGui.TableSetupColumn(ctx, tr.name or string.format('Track %d', i),
                           ImGui.TableColumnFlags_WidthStretch)
  end
  ImGui.TableHeadersRow(ctx)

  -- Capacity: how many body rows fit in the remaining region right now.
  local _, regionH = ImGui.GetContentRegionAvail(ctx)
  local rowH       = math.max(1, ImGui.GetTextLineHeightWithSpacing(ctx))
  local visRows    = math.max(1, math.floor(regionH / rowH))
  av:setGridSize(visRows, nTracks)

  local sr, sc      = av:scroll()
  local curRow, curCol = av:cursorRow(), av:cursorCol()

  for r = 0, visRows - 1 do
    local row = sr + r
    ImGui.TableNextRow(ctx)

    ImGui.TableSetColumnIndex(ctx, 0)
    ImGui.TextUnformatted(ctx, rowLabel(row))

    for c = 0, nTracks - 1 do
      local col = sc + c
      if col < nTracks then
        ImGui.TableSetColumnIndex(ctx, c + 1)
        if row == curRow and col == curCol then
          ImGui.TextUnformatted(ctx, '>')
        elseif col == curCol then
          ImGui.TextUnformatted(ctx, '|')
        else
          ImGui.TextUnformatted(ctx, '')
        end
      end
    end
  end

  ImGui.EndTable(ctx)
end

function ap:renderStatusBar(_)
  if not ctx then return end
  ImGui.TextUnformatted(ctx, string.format(
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
