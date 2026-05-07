-- See docs/sampleView.md for the model and API reference.
--
-- Take-independent view-model for sample mode. Slot list + browser key
-- against a REAPER track, not a take; the track is chosen explicitly via
-- samplePage's toolbar picker (listSamplerTracks supplies the candidate
-- list). Browser root comes from cm (`sampleBrowserRoot`); $HOME is the
-- lazy fallback. assignSlot routes through slotStore (cm-first);
-- previewSlot / previewPath are the gmem preview writers in
-- continuum.lua. Injection keeps sv free of REAPER and ImGui vocabulary
-- and testable without either.

function newSampleView(cm, assignSlot, previewSlot, previewPath, listSamplerTracks, clearSlot, stopPreview)
  local sv = {}
  local track         = nil
  local currentFolder = nil  -- folder whose files fill the middle pane
  local selectedFile  = nil  -- full path of the audio file queued for loading
  local browserPath     = nil   -- highlighted item in middle pane (file or folder)
  local browserIsFolder = false
  local previewSource   = nil   -- 'file' or 'slot': which column was last focused

  listSamplerTracks = listSamplerTracks or function() return {} end

  -- Switching tracks rekeys cm to the new track and clears any
  -- transient currentSample so the merged read falls back to the new
  -- track's stored slot (or schema default). Test seams pass cm=nil
  -- and exercise just the local field.
  function sv:setTrack(t)
    if t == track then return end
    track = t
    if cm then
      cm:setTrack(t)
      cm:remove('transient', 'currentSample')
    end
  end
  function sv:getTrack()              return track          end
  function sv:listTracks()            return listSamplerTracks() end
  function sv:browseRoot()
    return (cm and cm:get('sampleBrowserRoot')) or os.getenv('HOME') or '/'
  end
  function sv:getCurrentFolder()      return currentFolder  end
  function sv:setCurrentFolder(p)     currentFolder = p     end
  function sv:setBrowseRoot(path)
    if cm then cm:set('global', 'sampleBrowserRoot', path) end
    currentFolder = nil
  end
  function sv:getBrowserPath()        return browserPath     end
  function sv:isBrowserFolder()       return browserIsFolder end
  function sv:setBrowserItem(path, isFolder)
    browserPath     = path
    browserIsFolder = isFolder
    selectedFile    = isFolder and nil or path
    if not isFolder then previewSource = 'file' end
  end

  function sv:setSlotFocus()  previewSource = 'slot' end

  function sv:canAuditionCurrent()
    if previewSource == 'slot' then return track ~= nil end
    return selectedFile ~= nil
  end

  function sv:auditionCurrent()
    if previewSource == 'slot' then
      return self:auditionSlot(cm and cm:get('currentSample') or 0)
    end
    return self:auditionPath(selectedFile)
  end
  function sv:setSelectedFile(p)      selectedFile  = p     end
  function sv:getSelectedFile()       return selectedFile   end

  function sv:loadSelectedIntoCurrent()
    if not selectedFile then return false end
    local slot = cm and cm:get('currentSample')
    if not assignSlot(slot, selectedFile) then return false end
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

  function sv:auditionPath(path)
    if not path or not track then return false end
    previewPath(path)
    return true
  end

  function sv:auditionSlot(idx)
    if not track then return end
    previewSlot(idx, 1)
  end

  function sv:clearCurrentSlot()
    if not (clearSlot and cm) then return end
    clearSlot(cm:get('currentSample'))
  end

  function sv:stopAudition()
    if stopPreview then stopPreview() end
  end

  return sv
end
