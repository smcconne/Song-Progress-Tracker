-- fcp_tracker_ui_track_utils.lua
-- Track, MIDI editor, and FX helper functions for Song Progress UI

local reaper = reaper

-- Ensure MIDI editor command 40818 is toggled off
function ensure_midi_editor_cmd_off(cmd_id)
  local me = reaper.MIDIEditor_GetActive()
  if me then
    -- Check toggle state and turn off if on
    local state = reaper.GetToggleCommandStateEx(32060, cmd_id)  -- 32060 = MIDI editor section
    if state == 1 then
      reaper.MIDIEditor_OnCommand(me, cmd_id)
    end
  end
end

-- Close the active MIDI editor if it's not an inline editor
function close_midi_editor_if_not_inline()
  local me = reaper.MIDIEditor_GetActive()
  if me then
    -- MIDIEditor_GetMode returns: -1 = no editor, 0 = piano roll, 1 = inline
    local mode = reaper.MIDIEditor_GetMode(me)
    if mode == 0 then
      -- Close the MIDI editor window (action ID 2 = File: Close window)
      reaper.MIDIEditor_OnCommand(me, 2)
    end
  end
end

-- Select first MIDI item on track and open in MIDI editor
-- Also sets time selection to the region at the current cursor/play position
-- Returns true if a MIDI item was found and opened
function select_first_midi_item_on_track(tr)
  if not tr then return false end

  -- Unselect all items in the project
  reaper.Main_OnCommand(40289, 0) -- Item: Unselect all items

  local item_count = reaper.CountTrackMediaItems(tr)
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(tr, i)
    local take = reaper.GetActiveTake(item)
    if take then
      local src = reaper.GetMediaItemTake_Source(take)
      local src_type = src and reaper.GetMediaSourceType(src, "") or ""
      if src_type == "MIDI" then
        reaper.SetMediaItemSelected(item, true)
        
        -- Get cursor position (use play cursor if playing, otherwise edit cursor)
        local play_state = reaper.GetPlayState()
        local cursor_pos
        if play_state & 1 == 1 then  -- Playing
          cursor_pos = reaper.GetPlayPosition()
        else
          cursor_pos = reaper.GetCursorPosition()
        end
        
        -- Find the region at cursor position and set time selection
        local num_markers, num_regions = reaper.CountProjectMarkers(0)
        for m = 0, num_markers + num_regions - 1 do
          local ok, isrgn, pos, r_end, name, markidx = reaper.EnumProjectMarkers(m)
          if ok and isrgn then
            if cursor_pos >= pos and cursor_pos < r_end then
              -- Set time selection to this region
              reaper.GetSet_LoopTimeRange(true, false, pos, r_end, false)
              break
            end
          end
        end
        
        reaper.Main_OnCommand(40153, 0) -- Open in built-in MIDI editor
        
        -- Run MIDI editor command 40726 (Zoom to time selection)
        local hwnd = reaper.MIDIEditor_GetActive()
        if hwnd then
          reaper.MIDIEditor_OnCommand(hwnd, 40726)
        end
        
        return true
      end
    end
  end
  return false
end

-- Select first MIDI item on track WITHOUT opening MIDI editor
-- Returns true if a MIDI item was found and selected
function select_first_midi_item_on_track_no_editor(tr)
  if not tr then return false end

  -- Unselect all items in the project
  reaper.Main_OnCommand(40289, 0) -- Item: Unselect all items

  local item_count = reaper.CountTrackMediaItems(tr)
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(tr, i)
    local take = reaper.GetActiveTake(item)
    if take then
      local src = reaper.GetMediaItemTake_Source(take)
      local src_type = src and reaper.GetMediaSourceType(src, "") or ""
      if src_type == "MIDI" then
        reaper.SetMediaItemSelected(item, true)
        return true
      end
    end
  end
  return false
end

-- Select track by name, scroll into view, and open MIDI editor
-- Optionally disable a MIDI editor toggle command and run another command after opening
function select_and_scroll_track_by_name(name, disable_midi_cmd, run_midi_cmd)
  local n = reaper.CountTracks(0)
  for i = 0, n-1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok and tname == name then
      reaper.SetOnlyTrackSelected(tr)
      reaper.Main_OnCommand(40913, 0) -- vertical scroll selected tracks into view
      select_first_midi_item_on_track(tr)
      -- Disable specified MIDI editor toggle command if provided
      if disable_midi_cmd then
        ensure_midi_editor_cmd_off(disable_midi_cmd)
      end
      -- Run additional MIDI editor command if provided
      if run_midi_cmd then
        local me = reaper.MIDIEditor_GetActive()
        if me then
          reaper.MIDIEditor_OnCommand(me, run_midi_cmd)
        end
      end
      return true
    end
  end
  return false
end

-- Get script command ID from ExtState-stored lookup string
local function get_script_cmd(ext_key)
  local lookup_str = reaper.GetExtState(EXT_NS, ext_key)
  if lookup_str and lookup_str ~= "" then
    return reaper.NamedCommandLookup(lookup_str)
  end
  return 0
end

-- Start/toggle Encore Vox Preview, Lyrics Clipboard, and Spectracular scripts
function start_encore_vox_preview()
  local cmd_encore = get_script_cmd(EXT_CMD_ENCORE_VOX)
  local cmd_lyrics = get_script_cmd(EXT_CMD_LYRICS_CLIP)
  local cmd_spectracular = get_script_cmd(EXT_CMD_SPECTRACULAR)
  
  if cmd_encore ~= 0 then
    reaper.Main_OnCommand(cmd_encore, 0)
  end
  if cmd_lyrics ~= 0 then
    reaper.Main_OnCommand(cmd_lyrics, 0)
  end
  if cmd_spectracular ~= 0 then
    -- Select first MIDI item on PART VOCALS before running Spectracular
    local n = reaper.CountTracks(0)
    for i = 0, n - 1 do
      local tr = reaper.GetTrack(0, i)
      local ok, tname = reaper.GetTrackName(tr)
      if ok and tname == "PART VOCALS" then
        select_first_midi_item_on_track_no_editor(tr)
        break
      end
    end
    reaper.Main_OnCommand(cmd_spectracular, 0)
  end
end

-- Start/toggle Venue Preview script
function start_venue_preview()
  local cmd_venue = get_script_cmd(EXT_CMD_VENUE_PREVIEW)
  if cmd_venue ~= 0 then
    reaper.Main_OnCommand(cmd_venue, 0)
  end
end

-- Start/toggle Pro Keys Preview script
function start_pro_keys_preview()
  local cmd_pro_keys = get_script_cmd(EXT_CMD_PRO_KEYS_PREVIEW)
  if cmd_pro_keys ~= 0 then
    reaper.Main_OnCommand(cmd_pro_keys, 0)
  end
end

-- Get track FX enabled state by track name
function get_track_fx_enabled(trackname)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok and tname == trackname then
      -- I_FXEN: 0=FX bypassed, nonzero=FX enabled
      local fx_en = reaper.GetMediaTrackInfo_Value(tr, "I_FXEN")
      return fx_en ~= 0
    end
  end
  return false
end

-- Toggle track FX enabled state by track name
function toggle_track_fx_enabled(trackname)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok and tname == trackname then
      local fx_en = reaper.GetMediaTrackInfo_Value(tr, "I_FXEN")
      local new_state = (fx_en ~= 0) and 0 or 1
      reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", new_state)
      return
    end
  end
end

-- Check if a track has MIDI content (returns true if any item is MIDI)
function track_has_midi(tr)
  if not tr then return false end
  local item_count = reaper.CountTrackMediaItems(tr)
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(tr, i)
    local take = reaper.GetActiveTake(item)
    if take then
      local src = reaper.GetMediaItemTake_Source(take)
      local src_type = src and reaper.GetMediaSourceType(src, "") or ""
      if src_type == "MIDI" then
        return true
      end
    end
  end
  return false
end

-- Check if a track has audio content (returns true if any item is audio)
function track_has_audio(tr)
  if not tr then return false end
  local item_count = reaper.CountTrackMediaItems(tr)
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(tr, i)
    local take = reaper.GetActiveTake(item)
    if take then
      local src = reaper.GetMediaItemTake_Source(take)
      local src_type = src and reaper.GetMediaSourceType(src, "") or ""
      if src_type ~= "MIDI" and src_type ~= "" then
        return true
      end
    end
  end
  return false
end

-- Show/hide tracks based on content type for Setup mode
-- Setup: show audio tracks, hide MIDI tracks
-- Non-Setup: show MIDI tracks, hide audio tracks
function set_tcp_visibility_for_setup(is_setup)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local has_midi = track_has_midi(tr)
    local has_audio = track_has_audio(tr)
    
    if is_setup then
      -- Setup tab: show audio, hide MIDI
      if has_audio and not has_midi then
        reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", 1)
      elseif has_midi and not has_audio then
        reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", 0)
      end
      -- Mixed tracks or empty tracks: leave as-is
    else
      -- Non-Setup tabs: show MIDI, hide audio
      if has_midi and not has_audio then
        reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", 1)
      elseif has_audio and not has_midi then
        reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", 0)
      end
      -- Mixed tracks or empty tracks: leave as-is
    end
  end
  reaper.TrackList_AdjustWindows(false)
end