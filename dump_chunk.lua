-- Run this after manually setting a JSFX to "Show embedded UI in TCP"
-- It will dump the track chunk to the console so we can see the format
local track = reaper.GetSelectedTrack(0, 0)
if not track then reaper.ShowMessageBox("Select a track first", "Dump", 0) return end
local _, chunk = reaper.GetTrackStateChunk(track, "", false)
reaper.ShowConsoleMsg(chunk)
