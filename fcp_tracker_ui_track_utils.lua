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

--- Apply a CUSTOM_NOTE_ORDER to the VENUE track, select it, and zoom.
function apply_venue_note_order_and_select(noteLine)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok and tname == "VENUE" then
      local ok2, chunk = reaper.GetTrackStateChunk(tr, "", true)
      if ok2 and chunk and chunk ~= "" then
        chunk = apply_custom_note_order(chunk, noteLine)
        reaper.SetTrackStateChunk(tr, chunk, false)
      end
      break
    end
  end
  select_and_scroll_track_by_name("VENUE", 40818, 40726)
  local me = reaper.MIDIEditor_GetActive()
  if me then
    reaper.MIDIEditor_OnCommand(me, 40452)
    reaper.MIDIEditor_OnCommand(me, 40143)
  end
end

function apply_camera_note_order_and_select(noteLine)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok and tname == "CAMERA" then
      local ok2, chunk = reaper.GetTrackStateChunk(tr, "", true)
      if ok2 and chunk and chunk ~= "" then
        chunk = apply_custom_note_order(chunk, noteLine)
        reaper.SetTrackStateChunk(tr, chunk, false)
      end
      break
    end
  end
  select_and_scroll_track_by_name("CAMERA", 40818, 40726)
  local me = reaper.MIDIEditor_GetActive()
  if me then
    reaper.MIDIEditor_OnCommand(me, 40452)
    reaper.MIDIEditor_OnCommand(me, 40143)
  end
end

function apply_lighting_note_order_and_select(noteLine)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok and tname == "LIGHTING" then
      local ok2, chunk = reaper.GetTrackStateChunk(tr, "", true)
      if ok2 and chunk and chunk ~= "" then
        chunk = apply_custom_note_order(chunk, noteLine)
        reaper.SetTrackStateChunk(tr, chunk, false)
      end
      break
    end
  end
  select_and_scroll_track_by_name("LIGHTING", 40818, 40726)
  local me = reaper.MIDIEditor_GetActive()
  if me then
    reaper.MIDIEditor_OnCommand(me, 40452)
    reaper.MIDIEditor_OnCommand(me, 40143)
  end
end

-- Get script command ID from ExtState-stored lookup string
local function get_script_cmd(ext_key)
  local lookup_str = reaper.GetExtState(EXT_NS, ext_key)
  if lookup_str and lookup_str ~= "" then
    return reaper.NamedCommandLookup(lookup_str)
  end
  return 0
end

-- Start/toggle Encore Vox Preview only
function start_encore_vox_preview_only()
  local cmd_encore = get_script_cmd(EXT_CMD_ENCORE_VOX)
  if cmd_encore ~= 0 then
    reaper.Main_OnCommand(cmd_encore, 0)
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

-- Start/toggle Spectracular script
function start_spectracular()
  local cmd_spectracular = get_script_cmd(EXT_CMD_SPECTRACULAR)
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

-- Start/toggle Lyrics Clipboard script
function start_lyrics_clipboard()
  local cmd_lyrics = get_script_cmd(EXT_CMD_LYRICS_CLIP)
  if cmd_lyrics ~= 0 then
    reaper.Main_OnCommand(cmd_lyrics, 0)
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

-- Ensure track FX chain is not bypassed (I_FXEN = 1)
function ensure_track_fx_chain_enabled(trackname)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok and tname == trackname then
      if reaper.GetMediaTrackInfo_Value(tr, "I_FXEN") == 0 then
        reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", 1)
      end
      return
    end
  end
end

-- Disable ReaSynth on all Listen-capable tracks that do NOT belong to the given tab
function disable_reasynth_except_for_tab(tab)
  -- Build set of track names that belong to the destination tab
  local keep = {}
  if tab == "Keys" and PRO_KEYS_ACTIVE then
    for _, tname in pairs(PRO_KEYS_TRACKS) do keep[tname] = true end
  elseif tab == "Keys" then
    keep[TRACKS.KEYS] = true
    for _, tname in pairs(PRO_KEYS_TRACKS) do keep[tname] = true end
  elseif tab == "Vocals" then
    for _, tname in pairs(VOCALS_TRACKS) do keep[tname] = true end
  elseif tab == "Drums" then
    keep[TRACKS.DRUMS] = true
  elseif tab == "Bass" then
    keep[TRACKS.BASS] = true
  elseif tab == "Guitar" then
    keep[TRACKS.GUITAR] = true
  end

  -- All Listen-capable track names
  local all_listen = {
    TRACKS.DRUMS, TRACKS.BASS, TRACKS.GUITAR, TRACKS.KEYS,
    VOCALS_TRACKS["H1"], VOCALS_TRACKS["H2"], VOCALS_TRACKS["H3"], VOCALS_TRACKS["V"],
    PRO_KEYS_TRACKS["X"], PRO_KEYS_TRACKS["H"], PRO_KEYS_TRACKS["M"], PRO_KEYS_TRACKS["E"],
  }
  for _, tname in ipairs(all_listen) do
    if not keep[tname] then
      set_reasynth_enabled(tname, false)
    end
  end
end

-- Ensure the FX chain is unblocked for all Listen-capable tracks on the given tab
function ensure_listen_fx_for_tab(tab)
  if tab == "Keys" and PRO_KEYS_ACTIVE then
    local diff_map = { Expert="X", Hard="H", Medium="M", Easy="E" }
    local diff_key = diff_map[ACTIVE_DIFF] or "X"
    ensure_track_fx_chain_enabled(PRO_KEYS_TRACKS[diff_key])
  elseif tab == "Vocals" then
    for _, tname in pairs(VOCALS_TRACKS) do
      ensure_track_fx_chain_enabled(tname)
    end
  elseif tab == "Drums" then
    ensure_track_fx_chain_enabled(TRACKS.DRUMS)
  elseif tab == "Bass" then
    ensure_track_fx_chain_enabled(TRACKS.BASS)
  elseif tab == "Guitar" then
    ensure_track_fx_chain_enabled(TRACKS.GUITAR)
  elseif tab == "Keys" then
    ensure_track_fx_chain_enabled(TRACKS.KEYS)
    ensure_track_fx_chain_enabled(PRO_KEYS_TRACKS["X"])
  end
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

-- Get track volume by track name (returns 0.0-1.0 normalized, or nil if not found)
-- Note: REAPER volume is 0.0 to ~4.0 (where 1.0 = 0dB), we normalize to 0.0-1.0 for UI
function get_track_volume(trackname)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok and tname == trackname then
      local vol = reaper.GetMediaTrackInfo_Value(tr, "D_VOL")
      -- Normalize: REAPER volume range is 0 to ~4 (1.0 = 0dB)
      -- We use 0-1 range for UI display, where 1.0 = 0dB (full volume)
      return math.min(1.0, vol)
    end
  end
  return nil
end

-- Set track volume by track name (accepts 0.0-1.0 normalized)
function set_track_volume(trackname, vol_normalized)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok and tname == trackname then
      -- Clamp to 0.0-1.0 range (we don't go above unity gain)
      local vol = math.max(0.0, math.min(1.0, vol_normalized))
      reaper.SetMediaTrackInfo_Value(tr, "D_VOL", vol)
      return
    end
  end
end

-- ReaSynth FX helpers ---------------------------------------------------------

-- Find ReaSynth FX index on a track (searches by name)
function get_reasynth_fx_index(tr)
  if not tr then return nil end
  local cnt = reaper.TrackFX_GetCount(tr)
  for i = 0, cnt - 1 do
    local rv, fxname = reaper.TrackFX_GetFXName(tr, i, "")
    if rv and fxname and fxname:find("ReaSynth", 1, true) then
      return i
    end
  end
  return nil
end

-- Find the volume parameter index in ReaSynth (cached per track+fx)
local reasynth_vol_param_cache = {}
local function find_reasynth_volume_param(tr, fx)
  local guid = reaper.GetTrackGUID(tr)
  local key = guid .. ":" .. tostring(fx)
  if reasynth_vol_param_cache[key] then
    return reasynth_vol_param_cache[key]
  end
  local count = reaper.TrackFX_GetNumParams(tr, fx)
  for i = 0, count - 1 do
    local rv, name = reaper.TrackFX_GetParamName(tr, fx, i, "")
    if rv and name and name:lower():find("volume") then
      reasynth_vol_param_cache[key] = i
      return i
    end
  end
  return nil
end

-- Get ReaSynth FX enabled state by track name
function get_reasynth_enabled(trackname)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok and tname == trackname then
      local fx = get_reasynth_fx_index(tr)
      if fx then
        return reaper.TrackFX_GetEnabled(tr, fx)
      end
      return false
    end
  end
  return false
end

-- Set ReaSynth FX enabled state by track name
function set_reasynth_enabled(trackname, enabled)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok and tname == trackname then
      local fx = get_reasynth_fx_index(tr)
      if fx then
        reaper.TrackFX_SetEnabled(tr, fx, enabled)
      end
      return
    end
  end
end

-- Toggle ReaSynth FX enabled state by track name
function toggle_reasynth_enabled(trackname)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok and tname == trackname then
      local fx = get_reasynth_fx_index(tr)
      if fx then
        local enabled = reaper.TrackFX_GetEnabled(tr, fx)
        reaper.TrackFX_SetEnabled(tr, fx, not enabled)
      end
      return
    end
  end
end

-- Get ReaSynth volume parameter value (linear, 0 to ~0.25)
function get_reasynth_volume(trackname)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok and tname == trackname then
      local fx = get_reasynth_fx_index(tr)
      if not fx then return nil end
      local param = find_reasynth_volume_param(tr, fx)
      if not param then return nil end
      local val = reaper.TrackFX_GetParam(tr, fx, param)
      return val
    end
  end
  return nil
end

-- Set ReaSynth volume parameter value (linear, 0 to ~0.25)
function set_reasynth_volume(trackname, vol)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok and tname == trackname then
      local fx = get_reasynth_fx_index(tr)
      if not fx then return end
      local param = find_reasynth_volume_param(tr, fx)
      if not param then return end
      reaper.TrackFX_SetParam(tr, fx, param, vol)
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
-- Setup: show all tracks
-- Non-Setup: show MIDI tracks, hide audio tracks
function set_tcp_visibility_for_setup(is_setup)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local has_midi = track_has_midi(tr)
    local has_audio = track_has_audio(tr)
    
    if is_setup then
      -- Setup tab: show all tracks
      reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", 1)
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

-- Solo button helpers --------------------------------------------------------

-- All parent tracks that can have audio stem children
local AUDIO_PARENTS = { "PART DRUMS", "PART BASS", "PART GUITAR", "PART KEYS", "PART VOCALS" }

-- Get all immediate child tracks of a folder parent track
function get_child_audio_tracks(parent_trackname)
  local children = {}
  local n = reaper.CountTracks(0)
  local found_parent = false
  local depth = 0

  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tname = reaper.GetTrackName(tr)
    if ok then
      if not found_parent then
        if tname == parent_trackname then
          local fd = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
          if fd >= 1 then
            found_parent = true
            depth = 0
          end
        end
      else
        children[#children + 1] = tr
        local fd = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
        depth = depth + fd
        if depth < 0 then
          break
        end
      end
    end
  end
  return children
end

-- Solo: unmute children of target parent, mute all other audio tracks
function solo_tab_audio(parent_trackname)
  -- Collect all child track pointers for the 5 parent folders
  local child_set = {}
  for _, parent in ipairs(AUDIO_PARENTS) do
    local children = get_child_audio_tracks(parent)
    local should_unmute = (parent == parent_trackname)
    for _, tr in ipairs(children) do
      child_set[tostring(tr)] = true
      reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", should_unmute and 0 or 1)
    end
  end

  -- Mute any other audio tracks not under a parent folder
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    if not child_set[tostring(tr)] and track_has_audio(tr) then
      reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1)
    end
  end
end

-- Vocal-related parent tracks for special unsolo handling
local VOCAL_PARENTS = {
  "PART VOCALS", "HARM1", "HARM2", "HARM3",
  "PART HARM1", "PART HARM2", "PART HARM3",
}
local VOCAL_PARENTS_SET = {}
for _, v in ipairs(VOCAL_PARENTS) do VOCAL_PARENTS_SET[v] = true end

-- Unsolo: unmute all audio children of parent tracks (except dryvox),
-- with special vocal handling: only unmute "Vocals" child if it exists
function unsolo_tab_audio()
  local child_set = {}

  -- Handle non-vocal parents: unmute children (except dryvox)
  for _, parent in ipairs(AUDIO_PARENTS) do
    if not VOCAL_PARENTS_SET[parent] then
      local children = get_child_audio_tracks(parent)
      for _, tr in ipairs(children) do
        child_set[tostring(tr)] = true
        local ok, tname = reaper.GetTrackName(tr)
        if ok and tname:lower():find("dryvox") then
          -- Leave dryvox tracks muted
        else
          reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 0)
        end
      end
    end
  end

  -- Handle vocal parents: gather all children, unmute only "Vocals" track
  local vocal_children = {}
  local found_vocals_track = nil
  for _, parent in ipairs(VOCAL_PARENTS) do
    local children = get_child_audio_tracks(parent)
    for _, tr in ipairs(children) do
      child_set[tostring(tr)] = true
      vocal_children[#vocal_children + 1] = tr
      local ok, tname = reaper.GetTrackName(tr)
      if ok and tname == "Vocals" then
        found_vocals_track = tr
      end
    end
  end

  if found_vocals_track then
    -- Unmute only the "Vocals" track, mute all other vocal children
    for _, tr in ipairs(vocal_children) do
      reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", tr == found_vocals_track and 0 or 1)
    end
  else
    -- No "Vocals" child found: unmute all vocal children (except dryvox)
    for _, tr in ipairs(vocal_children) do
      local ok, tname = reaper.GetTrackName(tr)
      if ok and tname:lower():find("dryvox") then
        -- Leave dryvox tracks muted
      else
        reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 0)
      end
    end
  end

  -- Mute any other audio tracks not under a parent folder
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    if not child_set[tostring(tr)] and track_has_audio(tr) then
      reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1)
    end
  end
end

-- Show/hide tracks in MCP based on whether they have audio content
-- Audio tracks: show in MCP
-- Non-audio tracks (MIDI only, empty): hide from MCP
function set_mcp_visibility_for_audio_tracks()
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local has_audio = track_has_audio(tr)
    if has_audio then
      reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 1)
    else
      reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 0)
    end
  end
  reaper.TrackList_AdjustWindows(false)
end