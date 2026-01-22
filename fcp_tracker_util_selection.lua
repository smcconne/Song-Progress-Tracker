-- fcp_tracker_util_selection.lua
-- Track selection helper functions

function deselect_all_tracks()
  local n = reaper.CountTracks(0)
  for i=0, n-1 do reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, i), "I_SELECTED", 0) end
end

function snapshot_selection()
  local t, n = {}, reaper.CountSelectedTracks(0)
  for i=0, n-1 do t[#t+1] = reaper.GetSelectedTrack(0, i) end
  return t
end

function restore_selection(saved)
  deselect_all_tracks()
  for i=1, #saved do
    if reaper.ValidatePtr2(0, saved[i], "MediaTrack*") then
      reaper.SetMediaTrackInfo_Value(saved[i], "I_SELECTED", 1)
    end
  end
end

function find_track_by_name(name)
  local n = reaper.CountTracks(0)
  for i=0, n-1 do
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetTrackName(tr, "")
    if nm == name then return tr end
  end
  return nil
end

function select_track_for_tab(tab)
  if not TAB_TRACK then return end
  local want = TAB_TRACK[tab]; if not want then return end
  local tr = find_track_by_name(want); if not tr then return end
  reaper.SetOnlyTrackSelected(tr)
  reaper.Main_OnCommand(40913, 0)  -- vertical scroll selected tracks into view
  -- Select first MIDI item on the track without opening editor
  if select_first_midi_item_on_track_no_editor then
    select_first_midi_item_on_track_no_editor(tr)
  end
end
