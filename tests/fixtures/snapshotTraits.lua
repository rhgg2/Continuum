-- rm stamps every fx record it reads with the plugin's resolved traits, and wm's snapshot
-- carries them into read. A spec that hands wm.readGraph a built or target snapshot stands in
-- for rm: an fx entry stating no traits takes those of a plugin nothing is known about, which
-- is what rm resolves for an unauthored native plugin or an unreadable JSFX.
local snapshotTraits = {}

snapshotTraits.UNKNOWN = { midiIn = true, midiOut = true, instrument = false, busAware = false }

-- wm.readGraph over snap, its traitless fx entries first given UNKNOWN (in place).
function snapshotTraits.readGraph(wm, snap, busMeta)
  for _, entry in pairs(snap) do
    for _, fxe in ipairs(entry.fx or {}) do fxe.traits = fxe.traits or snapshotTraits.UNKNOWN end
  end
  return wm.readGraph(snap, busMeta)
end

return snapshotTraits
