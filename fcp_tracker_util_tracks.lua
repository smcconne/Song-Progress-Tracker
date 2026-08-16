-- fcp_tracker_util_tracks.lua
-- Track, MIDI editor, and FX helper functions for Song Progress UI

local reaper = reaper
local ImGui  = reaper

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
-- Sets time selection to the region at cursor; returns true if item found
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

-- Look up a track by exact name (shared copy for model, overdrive, focus/layout)
function find_track_by_name(want)
  local n = reaper.CountTracks(0)
  for i = 0, n-1 do
    local tr = reaper.GetTrack(0, i)
    local ok, name = reaper.GetTrackName(tr)
    if ok and name == want then return tr end
  end
end

-- Walk all project markers/regions and populate REGIONS + REG_COL_U32
-- (colors go through the shared native_color_to_u32 helper).
function collect_regions()
  local _, n_mark, n_rgn = reaper.CountProjectMarkers(0)
  local total = (n_mark or 0) + (n_rgn or 0)
  local regs = {}
  for i = 0, total-1 do
    local ok, isrgn, pos, r_end, name, markidx, color = reaper.EnumProjectMarkers3(0, i)
    if ok and isrgn then
      regs[#regs+1] = {
        id    = markidx,
        name  = (name and name ~= "") and name or ("Region "..tostring(markidx)),
        pos   = pos or 0,
        r_end = r_end or pos or 0,
        color = color or 0
      }
    end
  end
  table.sort(regs, function(a,b) return a.pos < b.pos end)

  REG_COL_U32 = {}
  for i = 1, #regs do
    REG_COL_U32[i] = {
      header = native_color_to_u32(regs[i].color, 0.65),
      cell   = native_color_to_u32(regs[i].color, 0.25)
    }
  end
  return regs
end

-- Get the measure containing the [end] event from EVENTS track
function get_end_event_measure()
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, name = reaper.GetTrackName(tr)
    if ok and name == "EVENTS" then
      local item_count = reaper.CountTrackMediaItems(tr)
      for j = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(tr, j)
        local take = reaper.GetActiveTake(item)
        if take and reaper.TakeIsMIDI(take) then
          local _, _, _, textsyx_cnt = reaper.MIDI_CountEvts(take)
          for ev = 0, textsyx_cnt - 1 do
            local ok2, sel, muted, ppq, typ, msg = reaper.MIDI_GetTextSysexEvt(take, ev, false, false, 0, 0, "")
            if ok2 and typ >= 1 and msg == "[end]" then
              local proj_time = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)
              local _, measures = reaper.TimeMap2_timeToBeats(0, proj_time)
              return math.floor(measures) + 1  -- 1-indexed measure
            end
          end
        end
      end
      break
    end
  end
  return nil  -- No [end] event found
end

function get_first_midi_item_end_measure()
  -- Find PART DRUMS track and get the start of the first MIDI item
  -- Use [end] event measure as the last measure if available
  local first_m = 1
  local last_m = 100  -- fallback
  
  local n = reaper.CountTracks(0)
  for i = 0, n-1 do
    local tr = reaper.GetTrack(0, i)
    local ok, name = reaper.GetTrackName(tr)
    if ok and name == "PART DRUMS" then
      local item_count = reaper.CountTrackMediaItems(tr)
      if item_count > 0 then
        local item = reaper.GetTrackMediaItem(tr, 0)
        local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local item_end = item_start + item_len
        
        -- Convert to measure
        local _, end_measure = reaper.TimeMap2_timeToBeats(0, item_end)
        local _, start_measure = reaper.TimeMap2_timeToBeats(0, item_start)
        
        first_m = math.floor(start_measure) + 1
        last_m = math.floor(end_measure) + 1
        break
      end
    end
  end
  
  -- Override last_m with [end] event measure if available
  local end_event_m = get_end_event_measure()
  if end_event_m then
    last_m = end_event_m
  end
  
  return first_m, last_m
end

function collect_overdrive_data()
  local first_m, last_m = get_first_midi_item_end_measure()
  OVERDRIVE_MEASURES.first = first_m
  OVERDRIVE_MEASURES.last = last_m
  
  -- Clear and rebuild
  for _, row in ipairs(OVERDRIVE_ROWS) do
    OVERDRIVE_DATA[row] = {}
    OVERDRIVE_NOTES[row] = {}
    OVERDRIVE_NOTE_POSITIONS[row] = {}
    OVERDRIVE_POSITIONS[row] = {}
    OVERDRIVE_PHRASES[row] = {}  -- List of {start_m, start_pos, end_m, end_pos} for each OV note
    for m = first_m, last_m do
      OVERDRIVE_DATA[row][m] = false
      OVERDRIVE_NOTES[row][m] = 0  -- Count of playable notes
      OVERDRIVE_NOTE_POSITIONS[row][m] = {}  -- List of {start, end} positions (0-1)
      OVERDRIVE_POSITIONS[row][m] = {}  -- List of {start, fin} positions (0-1) for OV phrases
    end
  end
  
  -- Clear FILL data for drums
  OVERDRIVE_FILL["Drums"] = {}
  for m = first_m, last_m do
    OVERDRIVE_FILL["Drums"][m] = false
  end
  
  -- Scan each track for overdrive notes (pitch 116) and playable notes
  for idx, trackname in ipairs(OVERDRIVE_TRACKS) do
    local row = OVERDRIVE_ROWS[idx]
    local n = reaper.CountTracks(0)
    for i = 0, n-1 do
      local tr = reaper.GetTrack(0, i)
      local ok, name = reaper.GetTrackName(tr)
      if ok and name == trackname then
        local tk = first_midi_take_on_track(tr)
        if tk then
          local _, note_cnt = reaper.MIDI_CountEvts(tk)
          local m5_notes = {}
          for ni = 0, note_cnt - 1 do
            local ok2, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
            if ok2 then
              local t_s = reaper.MIDI_GetProjTimeFromPPQPos(tk, ppq_s)
              local t_e = reaper.MIDI_GetProjTimeFromPPQPos(tk, ppq_e)
              
              -- Get measures this note spans
              local _, m_start_idx = reaper.TimeMap2_timeToBeats(0, t_s)
              local _, m_end_idx = reaper.TimeMap2_timeToBeats(0, t_e)
              local m_start = m_start_idx + 1  -- Convert to 1-indexed
              
              -- Check if note ends at or before the start of the end measure
              -- Get the time at the start of m_end_idx measure
              local m_end_start_time = reaper.TimeMap2_beatsToTime(0, 0, m_end_idx)
              
              local m_end
              if t_e <= m_end_start_time + 0.0001 then
                -- Note ends at or before this measure's start, don't include it
                m_end = m_end_idx  -- Previous measure in 1-indexed terms
              else
                m_end = m_end_idx + 1  -- Note extends into this measure, include it
              end
              
              -- Ensure m_end is at least m_start (for short notes within a single measure)
              if m_end < m_start then
                m_end = m_start
              end
              
              if pitch == OVERDRIVE_PITCH then
                -- Mark overdrive and store positions
                local note_qn_start = reaper.MIDI_GetProjQNFromPPQPos(tk, ppq_s)
                local note_qn_end = reaper.MIDI_GetProjQNFromPPQPos(tk, ppq_e)
                
                -- Store phrase data (start/end measure and relative positions)
                local clamped_start_m = math.max(m_start, first_m)
                local clamped_end_m = math.min(m_end, last_m)
                if clamped_end_m >= clamped_start_m then
                  local _, start_m_qn_start, start_m_qn_end = reaper.TimeMap_GetMeasureInfo(0, clamped_start_m - 1)
                  local _, end_m_qn_start, end_m_qn_end = reaper.TimeMap_GetMeasureInfo(0, clamped_end_m - 1)
                  local start_measure_len = start_m_qn_end - start_m_qn_start
                  local end_measure_len = end_m_qn_end - end_m_qn_start
                  local start_pos = math.max(0, (note_qn_start - start_m_qn_start) / start_measure_len)
                  local end_pos = math.min(1, (note_qn_end - end_m_qn_start) / end_measure_len)
                  table.insert(OVERDRIVE_PHRASES[row], {
                    start_m = clamped_start_m,
                    start_pos = start_pos,
                    end_m = clamped_end_m,
                    end_pos = end_pos
                  })
                end
                
                for m = m_start, m_end do
                  if m >= first_m and m <= last_m then
                    OVERDRIVE_DATA[row][m] = true
                    -- Store OV position within this measure
                    local _, m_qn_start, m_qn_end = reaper.TimeMap_GetMeasureInfo(0, m - 1)
                    local measure_len = m_qn_end - m_qn_start
                    -- Clamp to measure bounds
                    local rel_start = math.max(0, (note_qn_start - m_qn_start) / measure_len)
                    local rel_end = math.min(1, (note_qn_end - m_qn_start) / measure_len)
                    if rel_end > rel_start then
                      table.insert(OVERDRIVE_POSITIONS[row][m], {start = rel_start, fin = rel_end})
                    end
                  end
                end
              elseif pitch >= 120 and pitch <= 124 and row == "Drums" then
                -- FILL notes (drums only)
                for m = m_start, m_end do
                  if m >= first_m and m <= last_m then
                    OVERDRIVE_FILL["Drums"][m] = true
                  end
                end
              elseif pitch >= 96 and pitch <= 100 then
                -- Expert-range notes (gems) for counting
                -- Only count the note-on (m_start), not sustain measures
                local pitch_row = pitch - 96  -- 0-4 for pitch 96-100
                if m_start >= first_m and m_start <= last_m then
                  OVERDRIVE_NOTES[row][m_start] = (OVERDRIVE_NOTES[row][m_start] or 0) + 1
                end
                -- Store note position within each measure it spans (for visual display)
                for m = m_start, m_end do
                  if m >= first_m and m <= last_m then
                    local _, m_qn_start, m_qn_end = reaper.TimeMap_GetMeasureInfo(0, m - 1)
                    local measure_len = m_qn_end - m_qn_start
                    local note_qn_start = reaper.MIDI_GetProjQNFromPPQPos(tk, ppq_s)
                    local note_qn_end = reaper.MIDI_GetProjQNFromPPQPos(tk, ppq_e)
                    -- Clamp to measure bounds
                    local rel_start = math.max(0, (note_qn_start - m_qn_start) / measure_len)
                    local rel_end = math.min(1, (note_qn_end - m_qn_start) / measure_len)
                    if rel_end > rel_start then
                      table.insert(OVERDRIVE_NOTE_POSITIONS[row][m], {start = rel_start, fin = rel_end, row = pitch_row})
                    end
                  end
                end
              end
            end
          end
        end
        break
      end
    end
  end
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

function apply_vocals_note_order(start_note)
  local tab_obj = current_tab_obj and current_tab_obj() or nil
  local trackname = tab_obj and tab_obj:current_mode() and tab_obj:current_mode().trackname or nil
  if not trackname then return end
  local tr = find_track_by_name(trackname)
  if not tr then return end
  local nums = {}
  for n = start_note, start_note + 18 do nums[#nums+1] = tostring(n) end
  local noteLine = "  CUSTOM_NOTE_ORDER " .. table.concat(nums, " ")
  local ok, chunk = reaper.GetTrackStateChunk(tr, "", true)
  if ok and chunk and chunk ~= "" then
    chunk = apply_custom_note_order(chunk, noteLine)
    reaper.SetTrackStateChunk(tr, chunk, false)
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

-- Get ExtState-stored lookup string (e.g. "_RS..." or "_<32hex>") or nil
local function get_script_lookup(ext_key)
  local lookup_str = reaper.GetExtState(EXT_NS, ext_key)
  if lookup_str and lookup_str ~= "" then return lookup_str end
  return nil
end

-- Missing-script preflight (reaper-kb.ini): REAPER's native "Can't load file:"
-- dialog aborts the calling script, so verify script files before dispatch.
local kb_path_cache, kb_path_cache_ts = nil, 0
local function get_reaper_kb_path()
  if kb_path_cache and (reaper.time_precise() - kb_path_cache_ts) < 5.0 then
    return kb_path_cache
  end
  local rp = reaper.GetResourcePath()
  if not rp or rp == "" then return nil end
  local sep = package.config:sub(1, 1)
  local p = rp .. sep .. "reaper-kb.ini"
  if not reaper.file_exists(p) then
    local other = (sep == "/") and "\\" or "/"
    p = rp .. other .. "reaper-kb.ini"
    if not reaper.file_exists(p) then return nil end
  end
  kb_path_cache, kb_path_cache_ts = p, reaper.time_precise()
  return p
end

-- Resolve an RS action ID to its script path: path = exists,
-- false = registered but missing, nil = unknown.
local function resolve_rs_script_path(needle)
  local kb = get_reaper_kb_path()
  if not kb then return nil end
  local data = slurp(kb)
  if not data then return nil end
  local sep = package.config:sub(1, 1)
  local rp = reaper.GetResourcePath() or ""
  for line in data:gmatch("[^\r\n]+") do
    if line:sub(1, 3) == "SCR" then
      local _, _, id, raw_path =
        line:match('^SCR%s+(%d+)%s+(%d+)%s+(%S+)%s+"[^"]*"%s*(.*)$')
      if id == needle and raw_path and raw_path ~= "" then
        local path = raw_path:match('^"(.*)"$') or raw_path
        -- Tolerate Windows extended-length path prefix "\\?\"
        path = path:gsub("^\\\\%?\\", "")
        -- Resolve relative paths against <ResourcePath>/Scripts/
        if not (path:match("^[A-Za-z]:[\\/]") or path:match("^[\\/]") or path:sub(1, 1) == "~") then
          path = rp .. sep .. "Scripts" .. sep .. path
        end
        if reaper.file_exists(path) then return path end
        return false
      end
    end
  end
  return nil
end

-- Look up a custom action's step list by its bare 32-hex ID (no leading _).
local function get_custom_action_steps(needle)
  local kb = get_reaper_kb_path()
  if not kb then return nil end
  local data = slurp(kb)
  if not data then return nil end
  for line in data:gmatch("[^\r\n]+") do
    if line:sub(1, 3) == "ACT" then
      local id, steps = line:match('^ACT%s+%d+%s+%d+%s+"(%x+)"%s+"[^"]*"%s*(.-)%s*$')
      if id == needle then return steps end
    end
  end
  return nil
end

-- True if any ReaScript in the action's chain is missing (recurses into
-- custom actions; built-ins/extension actions ignored; cycles guarded).
local function chain_has_missing_script(lookup_str, visited)
  if not lookup_str or lookup_str == "" then return false end
  if visited[lookup_str] then return false end
  visited[lookup_str] = true
  if lookup_str:sub(1, 3) == "_RS" then
    return resolve_rs_script_path(lookup_str:sub(2)) == false
  end
  if lookup_str:match("^_[0-9a-f]+$") then
    local steps = get_custom_action_steps(lookup_str:sub(2))
    if not steps then return false end
    for step in steps:gmatch("%S+") do
      if step:sub(1, 1) == "_" and chain_has_missing_script(step, visited) then
        return true
      end
    end
  end
  return false
end

-- Run a script/custom action with preflight so a missing file shows a message
-- instead of REAPER's native dialog terminating the tracker. Returns true if invoked.
function run_script_action_guarded(lookup_str, action_label, pre_fn)
  if not lookup_str or lookup_str == "" then return false end
  local cmd_id = reaper.NamedCommandLookup(lookup_str)
  if cmd_id == 0 then return false end
  if chain_has_missing_script(lookup_str, {}) then
    mb("The action '" .. tostring(action_label or lookup_str) ..
       "' could not be found, please reassign it on the Preferences tab.",
       "Action Not Found")
    return false
  end
  if pre_fn then pre_fn() end
  local ok = pcall(reaper.Main_OnCommand, cmd_id, 0)
  if not ok then
    mb("The action '" .. tostring(action_label or lookup_str) ..
       "' could not be found, please reassign it on the Preferences tab.",
       "Action Not Found")
    return false
  end
  return true
end

-- Start/toggle Encore Vox Preview only
function start_encore_vox_preview_only()
  local ran = run_script_action_guarded(get_script_lookup(EXT_CMD_ENCORE_VOX), "Encore Vox Preview")
  if not ran and mark_prefs_action_missing then mark_prefs_action_missing(EXT_CMD_ENCORE_VOX) end
end

-- Start/toggle Venue Preview script
function start_venue_preview()
  local ran = run_script_action_guarded(get_script_lookup(EXT_CMD_VENUE_PREVIEW), "Venue Preview")
  if not ran and mark_prefs_action_missing then mark_prefs_action_missing(EXT_CMD_VENUE_PREVIEW) end
end

-- Start/toggle Pro Keys Preview script
function start_pro_keys_preview()
  local ran = run_script_action_guarded(get_script_lookup(EXT_CMD_PRO_KEYS_PREVIEW), "Pro Keys Preview")
  if not ran and mark_prefs_action_missing then mark_prefs_action_missing(EXT_CMD_PRO_KEYS_PREVIEW) end
end

-- Start/toggle Spectracular script (selects first MIDI item on PART VOCALS first)
function start_spectracular()
  local ran = run_script_action_guarded(get_script_lookup(EXT_CMD_SPECTRACULAR), "Spectracular Stereo", function()
    local n = reaper.CountTracks(0)
    for i = 0, n - 1 do
      local tr = reaper.GetTrack(0, i)
      local ok, tname = reaper.GetTrackName(tr)
      if ok and tname == "PART VOCALS" then
        select_first_midi_item_on_track_no_editor(tr)
        break
      end
    end
  end)
  if not ran and mark_prefs_action_missing then mark_prefs_action_missing(EXT_CMD_SPECTRACULAR) end
end

-- Start/toggle Lyrics Clipboard script
function start_lyrics_clipboard()
  local ran = run_script_action_guarded(get_script_lookup(EXT_CMD_LYRICS_CLIP), "Lyrics Clipboard")
  if not ran and mark_prefs_action_missing then mark_prefs_action_missing(EXT_CMD_LYRICS_CLIP) end
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

-- Disable ReaSynth on Listen-capable tracks outside the tab's set
-- (accepts a Tab object or a string resolved via current_tab_obj()).
function disable_reasynth_except_for_tab(tab)
  -- Build set of track names that belong to the destination tab
  local keep = {}
  local tab_obj = (type(tab) == "table" and tab.listen_tracknames) and tab
                  or (current_tab_obj and current_tab_obj())
                  or nil
  if tab_obj then
    for _, tname in ipairs(tab_obj:listen_tracknames()) do keep[tname] = true end
  end

  -- All Listen-capable track names (derived from the registry)
  local all_listen = (all_listen_tracks and all_listen_tracks()) or {
    TRACKS.DRUMS, TRACKS.BASS, TRACKS.GUITAR, TRACKS.KEYS,
    VOCALS_TRACKS["H1"], VOCALS_TRACKS["H2"], VOCALS_TRACKS["H3"], VOCALS_TRACKS["V"],
    PRO_KEYS_TRACKS["Expert"], PRO_KEYS_TRACKS["Hard"], PRO_KEYS_TRACKS["Medium"], PRO_KEYS_TRACKS["Easy"],
  }
  for _, tname in ipairs(all_listen) do
    if not keep[tname] then
      set_reasynth_enabled(tname, false)
    end
  end
end

-- Unblock FX chains on all Listen-capable tracks in the tab's set
-- (accepts a Tab object or a string resolved via current_tab_obj()).
function ensure_listen_fx_for_tab(tab)
  local tab_obj = (type(tab) == "table" and tab.listen_tracknames) and tab
                  or (current_tab_obj and current_tab_obj())
                  or nil
  if tab_obj then
    for _, tname in ipairs(tab_obj:listen_tracknames()) do
      ensure_track_fx_chain_enabled(tname)
    end
    return
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

-- Show all tracks in Setup; otherwise show MIDI-only, hide audio-only tracks
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

-- Show audio tracks in MCP; hide MIDI-only and empty tracks
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

-- Track color as 32-bit ImGui U32 (grey fallback when uncoloured or missing;
-- moved from fcp_tracker_ui_table_overdrive.lua so other modules can call it).

function get_track_color_u32(trackname, alpha)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, name = reaper.GetTrackName(tr)
    if ok and name == trackname then
      local native_color = reaper.GetTrackColor(tr)
      if native_color == 0 then
        -- Track has no custom color, return a default gray
        return ImGui.ImGui_ColorConvertDouble4ToU32(0.3, 0.3, 0.3, alpha or 1)
      end
      -- Convert native color to RGB
      local r, g, b = reaper.ColorFromNative(native_color)
      return ImGui.ImGui_ColorConvertDouble4ToU32((r or 0)/255, (g or 0)/255, (b or 0)/255, alpha or 1)
    end
  end
  -- Track not found, return default
  return ImGui.ImGui_ColorConvertDouble4ToU32(0.3, 0.3, 0.3, alpha or 1)
end