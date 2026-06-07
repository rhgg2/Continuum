-- See docs/sampleView.md for the model.
-- @noindex

--invariant: sv keys against a REAPER track (not a take); cm is rebound only via sv:setTrack
--invariant: sv emits no signals — it is a passive state holder polled by samplePage each frame
--invariant: sv never speaks REAPER, gmem, or ImGui directly; all side-effects route through sm
--invariant: browserPath/selectedFile/previewSource are transient locals; nothing in sv is persisted (cm owns persistence)
--invariant: selectedFile mirrors browserPath only when the highlighted item is a file (folders null it)
--invariant: previewSource gates auditionCurrent dispatch: 'file' → path branch, 'slot' → currentSample branch
--invariant: slot index space is 0..63 (advanceOnLoad scan upper bound)
--shape: browserState = { track, currentFolder, browserPath, browserIsFolder, selectedFile, previewSource = 'file'|'slot'|nil }
--shape: trackEntry = { track, name }   -- sm:listTracks() element
local cm, sm = (...).cm, (...).sm

local sv = {}
local track           = nil
local currentFolder   = nil
local selectedFile    = nil
local browserPath     = nil
local browserIsFolder = false
local previewSource   = nil

--contract: idempotent rebind: always re-primes cm.track tier so cache survives a prior cm:setContext(nil) (e.g. tm:bindTake(nil) on page switch)
function sv:setTrack(t)
  track = t
  if cm then
    cm:setTrack(t)
    cm:remove('transient', 'currentSample')
  end
end
function sv:getTrack()              return track          end
function sv:listTracks()            return sm:listTracks() end
--contract: resolution order: cm:sampleBrowserRoot → $HOME → '/'; never returns nil
function sv:browseRoot()
  return (cm and cm:get('sampleBrowserRoot')) or os.getenv('HOME') or '/'
end
function sv:getCurrentFolder()      return currentFolder  end
function sv:setCurrentFolder(p)     currentFolder = p     end
--contract: persists at the global tier; resets currentFolder so the new root takes effect immediately
function sv:setBrowseRoot(path)
  if cm then cm:set('global', 'sampleBrowserRoot', path) end
  currentFolder = nil
end
function sv:getBrowserPath()        return browserPath     end
function sv:isBrowserFolder()       return browserIsFolder end
--contract: folder selection clears selectedFile and leaves previewSource untouched; file selection sets both selectedFile and previewSource='file'
function sv:setBrowserItem(path, isFolder)
  browserPath     = path
  browserIsFolder = isFolder
  selectedFile    = isFolder and nil or path
  if not isFolder then previewSource = 'file' end
end

function sv:setSlotFocus()  previewSource = 'slot' end

--contract: slot branch needs a track; file branch needs a selected file (track is checked downstream by auditionPath)
function sv:canAuditionCurrent()
  if previewSource == 'slot' then return track ~= nil end
  return selectedFile ~= nil
end

--contract: dispatches to slot/path branch by previewSource; defaults to slot 0 if cm is absent
function sv:auditionCurrent()
  if previewSource == 'slot' then
    return self:auditionSlot(cm and cm:get('currentSample') or 0)
  end
  return self:auditionPath(selectedFile)
end
function sv:setSelectedFile(p)      selectedFile  = p     end
function sv:getSelectedFile()       return selectedFile   end

--contract: returns false on no selection or sm:assign failure; on success may advance currentSample
--contract: advance is a no-op when no empty slot exists in range (currentSample left unchanged)
function sv:loadSelectedIntoCurrent()
  if not selectedFile then return false end
  local slot = cm and cm:get('currentSample')
  if not sm:assign(track, slot, selectedFile, cm) then return false end
  if cm and cm:get('advanceOnLoad') then
    local entries = cm:get('slotEntries')
    for idx = slot + 1, 63 do
      if not entries[idx] then
        cm:set('transient', 'currentSample', idx)
        break
      end
    end
  end
  return true
end

--contract: requires both path and track; returns false otherwise without invoking sm:previewPath
function sv:auditionPath(path)
  if not path or not track then return false end
  sm:previewPath(track, path)
  return true
end

--contract: requires track; bounds=1 (honours SH_START/SH_END trim)
function sv:auditionSlot(idx)
  if not track then return end
  sm:previewSlot(track, idx, 1)
end

--contract: no-op when cm is unbound
function sv:clearCurrentSlot()
  if not cm then return end
  sm:clearSlot(track, cm:get('currentSample'), cm)
end

function sv:stopAudition()
  sm:stopPreview(track)
end

return sv

