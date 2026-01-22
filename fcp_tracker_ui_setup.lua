-- fcp_tracker_ui_setup.lua
-- Setup tab for Practice Section Events (PRC) insertion
-- Integrated into Song Progress Tracker as a tab module

local reaper = reaper
local ImGui  = reaper

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------
local function split_lines(s)
  local t = {}
  for line in s:gmatch("[^\r\n]+") do t[#t+1] = line end
  return t
end

local function set_insert(set, key)
  local b = set[key] == true
  set[key] = true
  return not b
end

local function keys_sorted(tset)
  local t = {}
  for k in pairs(tset) do t[#t+1] = k end
  table.sort(t)
  return t
end

local function script_path()
  local src = debug.getinfo(1, 'S').source
  if src:sub(1,1) == '@' then src = src:sub(2) end
  return src
end

local function set_next_narrow_combo_width(ctx, val)
  local s = (val == "" or val == nil) and "(none)" or tostring(val)
  local w = ({ImGui.ImGui_CalcTextSize(ctx, s)})[1]
  ImGui.ImGui_SetNextItemWidth(ctx, math.floor(w + 26)) -- text + arrow/padding
end

--------------------------------------------------------------------------------
-- Load allowed tokens from embedded block
--------------------------------------------------------------------------------
local function load_embedded_whitelist()
  local path = script_path()
  local f = io.open(path, 'r')
  if not f then return "" end
  local s = f:read("*a"); f:close()
  local a,b = s:find("__PRC_ALLOWED_START__%s*%-%-%[%[")
  local c,d = s:find("%]%]%s*__PRC_ALLOWED_END__")
  if not (a and b and c and d and d>b) then return "" end
  return s:sub(b+1, c-1)
end

--------------------------------------------------------------------------------
-- Build indices
--------------------------------------------------------------------------------
local PRC_ALLOWED_RAW = load_embedded_whitelist()

-- Check if whitelist loaded (don't show error, just set empty - will be populated below)
local PRC_WHITELIST_LOADED = (PRC_ALLOWED_RAW ~= "")

-- allowed_set["prc_..."]=true
local PRC_allowed_set = {}
-- bases for first combo (non-blank case)
local PRC_base_any      = {}   -- set
-- base-only present
local PRC_base_has_base = {}   -- set
-- per-base number options (exist alone or with letters)
local PRC_base_nums     = {}   -- map base -> set of '1'..'9'
-- per-base letters when no number
local PRC_base_letters  = {}   -- map base -> set of letters
-- per-base per-number letters
local PRC_base_num_letters = {}-- map base -> map num -> set letters

-- blank-first case
local PRC_blank_letters = {}   -- set of letters that exist as [prc_<letter>] or [prc_<letter><num>]
local PRC_blank_letter_nums = {} -- map letter -> set of nums

if PRC_WHITELIST_LOADED then
  for _,line in ipairs(split_lines(PRC_ALLOWED_RAW)) do
    local tok = line:match("^%s*%[([^%[%]]+)%]%s*$")
    if tok and tok:sub(1,4) == "prc_" then
      PRC_allowed_set[tok] = true

      local body = tok:sub(5)

      -- blank-first tokens: a..z then optional digit
      local L,N = body:match("^([a-z])([1-9]?)$")
      if L then
        set_insert(PRC_blank_letters, L)
        PRC_blank_letter_nums[L] = PRC_blank_letter_nums[L] or {}
        if N ~= "" then set_insert(PRC_blank_letter_nums[L], N) end
      else
        -- number+letter: base_numletter
        local B, n, l = body:match("^([%w_!]+)_([1-9])([a-z])$")
        if B then
          set_insert(PRC_base_any, B)
          PRC_base_nums[B] = PRC_base_nums[B] or {}
          set_insert(PRC_base_nums[B], n)
          PRC_base_num_letters[B] = PRC_base_num_letters[B] or {}
          PRC_base_num_letters[B][n] = PRC_base_num_letters[B][n] or {}
          set_insert(PRC_base_num_letters[B][n], l)
        else
          -- number only: base_num
          local B2, n2 = body:match("^([%w_!]+)_([1-9])$")
          if B2 then
            set_insert(PRC_base_any, B2)
            PRC_base_nums[B2] = PRC_base_nums[B2] or {}
            set_insert(PRC_base_nums[B2], n2)
          else
            -- letter only: base_letter
            local B3, l3 = body:match("^([%w_!]+)_([a-z])$")
            if B3 then
              set_insert(PRC_base_any, B3)
              PRC_base_letters[B3] = PRC_base_letters[B3] or {}
              set_insert(PRC_base_letters[B3], l3)
            else
              -- base only
              local B4 = body:match("^([%w_!]+)$")
              if B4 then
                set_insert(PRC_base_any, B4)
                set_insert(PRC_base_has_base, B4)
              end
            end
          end
        end
      end
    end
  end
end

PRC_base_list = keys_sorted(PRC_base_any)

--------------------------------------------------------------------------------
-- UI state (global so draw_setup_tab can access them)
--------------------------------------------------------------------------------
PRC_sel_base   = ""     -- first combo; "" triggers blank-first rule
PRC_sel_num    = ""     -- second or third depending on rule
PRC_sel_letter = ""     -- third or second depending on rule

-- helpers to get options based on selection
function PRC_options_for_numbers_when_base(b)
  local set = {}
  if PRC_base_nums[b] then for n in pairs(PRC_base_nums[b]) do set[n]=true end end
  local v = keys_sorted(set)
  table.insert(v, 1, "") -- allow empty
  return v
end

function PRC_options_for_letters_when_base(b, n) -- n may be ""
  local set = {}
  if n == "" then
    if PRC_base_letters[b] then for l in pairs(PRC_base_letters[b]) do set[l]=true end end
  else
    if PRC_base_num_letters[b] and PRC_base_num_letters[b][n] then
      for l in pairs(PRC_base_num_letters[b][n]) do set[l]=true end
    end
  end
  local v = keys_sorted(set)
  table.insert(v, 1, "") -- allow empty
  return v
end

function PRC_options_letters_when_blank()
  local v = keys_sorted(PRC_blank_letters)
  table.insert(v, 1, "") -- allow empty
  return v
end

function PRC_options_numbers_for_blank_letter(L)
  local set = {}
  if PRC_blank_letter_nums[L] then for n in pairs(PRC_blank_letter_nums[L]) do set[n]=true end end
  local v = keys_sorted(set)
  table.insert(v, 1, "") -- allow empty
  return v
end

local function PRC_compose_token(b, n, l)
  if b == "" then
    if l == "" then return nil end
    return "prc_" .. l .. (n or "")
  else
    local s = "prc_" .. b
    if n ~= "" then 
      s = s .. "_" .. n 
      if l ~= "" then s = s .. l end
    elseif l ~= "" then
      s = s .. "_" .. l
    end
    return s
  end
end

function PRC_valid_current_token()
  local tok = PRC_compose_token(PRC_sel_base, PRC_sel_num, PRC_sel_letter)
  return tok and PRC_allowed_set[tok] == true, tok
end

-- Utilities (place near other helpers)
function PRC_region_label_from_token(tok)
  if not tok then return nil end
  local body = tok:sub(1,4) == "prc_" and tok:sub(5) or tok
  local s = body:gsub("_", " ")
  -- Title-case words that start with a letter; leave things like "1a" as-is
  s = s:gsub("%S+", function(w)
    if w:match("^[A-Za-z]") then return w:sub(1,1):upper() .. w:sub(2) end
    return w
  end)
  return s
end

-- Forward declarations for functions defined later
local set_time_selection_around
local open_events_in_midi_editor
local insert_essential_event

--------------------------------------------------------------------------------
-- Insert at edit cursor on track "EVENTS"
--------------------------------------------------------------------------------
local function PRC_find_track_by_name(name)
  local n = reaper.CountTracks(0)
  for i = 0, n-1 do
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetTrackName(tr)
    if nm == name then return tr end
  end
  return nil
end

local function PRC_find_item_at_time(tr, t)
  local c = reaper.CountTrackMediaItems(tr)
  for i = 0, c-1 do
    local it = reaper.GetTrackMediaItem(tr, i)
    local s  = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local d  = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    if t >= s and t < s + d then return it end
  end
  return nil
end

local function PRC_ensure_item_with_midi_take(tr, t)
  local it = PRC_find_item_at_time(tr, t)
  if not it then
    it = reaper.CreateNewMIDIItemInProj(tr, t, t + 0.001, false) -- tiny empty item
  end
  local tk = reaper.GetActiveTake(it)
  if not tk or not reaper.TakeIsMIDI(tk) then
    -- convert by creating a new MIDI item exactly over this item span
    local s  = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local d  = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    it = reaper.CreateNewMIDIItemInProj(tr, s, s + d, false)
    tk = reaper.GetActiveTake(it)
  end
  return tk
end

--------------------------------------------------------------------------------
-- Helper: Insert essential event at edit cursor on EVENTS track
--------------------------------------------------------------------------------
insert_essential_event = function(event_name)
  local tr = PRC_find_track_by_name("EVENTS")
  if not tr then return false end
  local t = reaper.GetCursorPosition()
  local take = PRC_ensure_item_with_midi_take(tr, t)
  if not take then return false end
  
  local ppq = reaper.MIDI_GetPPQPosFromProjTime(take, t)
  reaper.Undo_BeginBlock2(0)
  reaper.MIDI_InsertTextSysexEvt(take, false, false, ppq, 1, event_name)
  reaper.MIDI_Sort(take)
  reaper.Undo_EndBlock2(0, 'Insert '..event_name..' on EVENTS', -1)
  reaper.UpdateArrange()
  reaper.UpdateTimeline()
  return true
end

function PRC_insert_event(msg_bracketed)
  local tr = PRC_find_track_by_name("EVENTS")
  if not tr then
    reaper.ShowMessageBox('Track "EVENTS" not found.', 'PRC Events Tool', 0)
    return
  end
  local t = reaper.GetCursorPosition()
  local take = PRC_ensure_item_with_midi_take(tr, t)
  if not take then
    reaper.ShowMessageBox('Failed to get/create a MIDI take on "EVENTS".', 'PRC Events Tool', 0)
    return
  end

  local ppq = reaper.MIDI_GetPPQPosFromProjTime(take, t)
  reaper.Undo_BeginBlock2(0)
  reaper.MIDI_InsertTextSysexEvt(take, false, false, ppq, 1, msg_bracketed) -- type 1 = Text
  reaper.MIDI_Sort(take)
  reaper.Undo_EndBlock2(0, 'Insert '..msg_bracketed..' on EVENTS', -1)
  reaper.UpdateArrange()
  reaper.UpdateTimeline()
  
  -- Store the insert position for this project
  reaper.SetProjExtState(0, "FCP_PROGRESS", "LAST_PRC_INSERT_TIME", tostring(t))
  
  -- Set time selection around cursor and open MIDI editor
  set_time_selection_around(t)
  open_events_in_midi_editor()
end

--------------------------------------------------------------------------------
-- Region color mapping based on section keywords
--------------------------------------------------------------------------------
local PRC_REGION_COLORS = {
  -- {keywords (lowercase), color}
  -- Order matters: first match wins
  {{"intro", "fade in"}, 0x8080ff},
  {{"crescendo", "speed", "build", "enters"}, 0x80ff80},
  {{"melody", "riff", "lick", "lead", "fill", "hook", "roll", "line"}, 0xff00f2},
  {{"preverse", "postverse"}, 0x884400},
  {{"verse"}, 0xff8000},
  {{"prechorus", "postchorus"}, 0x004080},
  {{"chorus"}, 0x0080ff},
  {{"bridge"}, 0xff80c0},
  {{"solo"}, 0xff0000},
  {{"break", "release"}, 0x8000ff},
  {{"outro", "bre", "ending", "fade out"}, 0x0000ff},
  {{"jam", "vamp", "part", "soundscape", "tension", "space"}, 0x800080},
  {{"ah", "yeah", "ooh", "prayer", "chant", "spoken word", "kick it"}, 0xcccccc},
}

-- Get region color based on section name keywords (case-insensitive)
local function PRC_get_region_color(name)
  local lower_name = name:lower()
  for _, entry in ipairs(PRC_REGION_COLORS) do
    local keywords, color = entry[1], entry[2]
    for _, kw in ipairs(keywords) do
      if lower_name:find(kw, 1, true) then  -- plain text search
        -- Convert RGB to native format (BGR on Windows) and add enable bit
        local r = (color >> 16) & 0xFF
        local g = (color >> 8) & 0xFF
        local b = color & 0xFF
        local native_color = reaper.ColorToNative(r, g, b)
        return native_color | 0x1000000
      end
    end
  end
  return 0  -- No color (use default)
end

--------------------------------------------------------------------------------
-- Convert PRC events to regions
--------------------------------------------------------------------------------
function PRC_convert_to_regions()
  local tr = PRC_find_track_by_name("EVENTS")
  if not tr then
    reaper.ShowMessageBox('Track "EVENTS" not found.', 'PRC Events Tool', 0)
    return
  end
  
  -- Collect all PRC events and [end] event from EVENTS track
  local prc_events = {} -- {time, name} sorted by time
  local end_time = nil
  
  local item_count = reaper.CountTrackMediaItems(tr)
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(tr, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local _, _, _, textsyx_cnt = reaper.MIDI_CountEvts(take)
      for ev = 0, textsyx_cnt - 1 do
        local ok, sel, muted, ppq, typ, msg = reaper.MIDI_GetTextSysexEvt(take, ev, false, false, 0, 0, "")
        if ok and typ >= 1 then
          local proj_time = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)
          -- Check if it's a PRC event (matches whitelist)
          if msg:sub(1,5) == "[prc_" and msg:sub(-1) == "]" then
            local tok = msg:sub(2, -2) -- strip brackets
            if PRC_allowed_set[tok] then
              local region_name = PRC_region_label_from_token(tok)
              prc_events[#prc_events + 1] = {time = proj_time, name = region_name}
            end
          elseif msg == "[end]" then
            end_time = proj_time
          end
        end
      end
    end
  end
  
  if #prc_events == 0 then
    reaper.ShowMessageBox('No PRC events found on EVENTS track.', 'PRC Events Tool', 0)
    return
  end
  
  -- Sort PRC events by time
  table.sort(prc_events, function(a, b) return a.time < b.time end)
  
  -- Calculate fallback end time: measure following [end] event
  local fallback_end = nil
  if end_time then
    -- Get the measure after [end]
    local _, measures, _, _, _ = reaper.TimeMap2_timeToBeats(0, end_time)
    local next_measure = math.floor(measures) + 2 -- +1 for 0-index, +1 for next measure
    fallback_end = reaper.TimeMap2_beatsToTime(0, 0, next_measure)
  else
    -- No [end] event, use project end
    fallback_end = reaper.GetProjectLength(0)
  end
  
  reaper.Undo_BeginBlock2(0)
  
  -- Delete all existing regions first
  local _, n_mark, n_rgn = reaper.CountProjectMarkers(0)
  local total = (n_mark or 0) + (n_rgn or 0)
  -- Collect region marker IDs to delete
  local regions_to_delete = {}
  for i = 0, total - 1 do
    local ok, isrgn, pos, r_end, name, markidx, color = reaper.EnumProjectMarkers3(0, i)
    if ok and isrgn then
      regions_to_delete[#regions_to_delete + 1] = markidx
    end
  end
  -- Delete regions by marker ID (isrgn=true means it's a region)
  for i = #regions_to_delete, 1, -1 do
    reaper.DeleteProjectMarker(0, regions_to_delete[i], true)
  end
  
  -- Create regions
  for i, prc in ipairs(prc_events) do
    local region_start = prc.time
    local region_end
    
    -- End is whichever is closer: next PRC event or fallback_end
    if prc_events[i + 1] then
      region_end = math.min(prc_events[i + 1].time, fallback_end)
    else
      region_end = fallback_end
    end
    
    -- Get color based on section name keywords
    local region_color = PRC_get_region_color(prc.name)
    
    -- Create region (isrgn=true for region)
    reaper.AddProjectMarker2(0, true, region_start, region_end, prc.name, -1, region_color)
  end
  
  reaper.Undo_EndBlock2(0, 'Convert PRC events to regions', -1)
  reaper.UpdateArrange()
  reaper.UpdateTimeline()
  
  -- Schedule refresh after 2 seconds to allow regions to auto-color
  PENDING_REGION_REFRESH_TIME = reaper.time_precise() + 2.0
end

-- Check for pending region refresh (called from main loop)
function check_pending_region_refresh()
  if PENDING_REGION_REFRESH_TIME and reaper.time_precise() >= PENDING_REGION_REFRESH_TIME then
    PENDING_REGION_REFRESH_TIME = nil
    if Progress_Init then
      Progress_Init(true) -- skip FX alignment
    end
  end
end

--------------------------------------------------------------------------------
-- ImGui helpers
--------------------------------------------------------------------------------
local function combo_from_list(ctx, label, cur, items)
  local changed = false
  if ImGui.ImGui_BeginCombo(ctx, label, cur == "" and "(none)" or cur, ImGui.ImGui_ComboFlags_HeightLargest()) then
    for _,opt in ipairs(items) do
      local sel = (opt == cur)
      if ImGui.ImGui_Selectable(ctx, opt == "" and "(none)" or opt, sel) then
        cur = opt
        changed = true
      end
    end
    ImGui.ImGui_EndCombo(ctx)
  end
  return changed, cur
end

--------------------------------------------------------------------------------
-- Helper: Set time selection 1 measure before and after a position
--------------------------------------------------------------------------------
set_time_selection_around = function(pos)
  if not pos then return end
  -- Get measure info for this position
  local _, measures, _, _, _ = reaper.TimeMap2_timeToBeats(0, pos)
  local current_measure = math.floor(measures)
  
  -- Get start of previous measure and end of next measure
  local prev_measure = math.max(0, current_measure - 1)
  local next_measure = current_measure + 2  -- +2 because we want end of measure after
  
  local time_start = reaper.TimeMap2_beatsToTime(0, 0, prev_measure)
  local time_end = reaper.TimeMap2_beatsToTime(0, 0, next_measure)
  
  reaper.GetSet_LoopTimeRange(true, false, time_start, time_end, false)
end

--------------------------------------------------------------------------------
-- Helper: Select EVENTS track and open floating MIDI editor
--------------------------------------------------------------------------------
open_events_in_midi_editor = function()
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, name = reaper.GetTrackName(tr)
    if ok and name == "EVENTS" then
      -- Make track visible in TCP
      reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", 1)
      -- Unselect all tracks, then select EVENTS
      reaper.SetOnlyTrackSelected(tr)
      -- Find first MIDI item on the track
      local item_count = reaper.CountTrackMediaItems(tr)
      for j = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(tr, j)
        local take = reaper.GetActiveTake(item)
        if take and reaper.TakeIsMIDI(take) then
          -- Open in floating MIDI editor (action 40153)
          reaper.SetMediaItemSelected(item, true)
          reaper.Main_OnCommand(40153, 0) -- Item: Open in built-in MIDI editor (set default behavior in preferences)
          -- Get the active MIDI editor for additional commands
          local me = reaper.MIDIEditor_GetActive()
          if me then
            -- Ensure 40818 (Options: Toggle MIDI editor removing overlapping MIDI notes) is off
            if reaper.GetToggleCommandStateEx(32060, 40818) == 1 then
              reaper.MIDIEditor_OnCommand(me, 40818)
            end
            -- Run 40726 (Zoom to time selection)
            reaper.MIDIEditor_OnCommand(me, 40726)
          end
          return
        end
      end
      break
    end
  end
end

--------------------------------------------------------------------------------
-- Helper: Find the latest (furthest-right) event with [prc_ prefix
--------------------------------------------------------------------------------
local function get_latest_prc_event_time()
  local n = reaper.CountTracks(0)
  local events_track = nil
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, name = reaper.GetTrackName(tr)
    if ok and name == "EVENTS" then
      events_track = tr
      break
    end
  end
  if not events_track then return nil end
  
  local latest_time = nil
  local item_count = reaper.CountTrackMediaItems(events_track)
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(events_track, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local _, _, _, textsyx_cnt = reaper.MIDI_CountEvts(take)
      for ev = 0, textsyx_cnt - 1 do
        local ok, sel, muted, ppq, typ, msg = reaper.MIDI_GetTextSysexEvt(take, ev, false, false, 0, 0, "")
        if ok and typ >= 1 and msg:sub(1,5) == "[prc_" then
          local proj_time = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)
          if not latest_time or proj_time > latest_time then
            latest_time = proj_time
          end
        end
      end
    end
  end
  return latest_time
end

--------------------------------------------------------------------------------
-- Helper: Find EVENTS track and get project time of a specific event
--------------------------------------------------------------------------------
local function get_event_time(event_name)
  local n = reaper.CountTracks(0)
  local events_track = nil
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, name = reaper.GetTrackName(tr)
    if ok and name == "EVENTS" then
      events_track = tr
      break
    end
  end
  if not events_track then return nil end
  
  local item_count = reaper.CountTrackMediaItems(events_track)
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(events_track, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local _, _, _, textsyx_cnt = reaper.MIDI_CountEvts(take)
      for ev = 0, textsyx_cnt - 1 do
        local ok, sel, muted, ppq, typ, msg = reaper.MIDI_GetTextSysexEvt(take, ev, false, false, 0, 0, "")
        if ok and typ >= 1 and msg == event_name then
          return reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)
        end
      end
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Helper: Find EVENTS track and get MBT location of a specific event
--------------------------------------------------------------------------------
local function get_event_mbt(event_name)
  -- Find EVENTS track
  local n = reaper.CountTracks(0)
  local events_track = nil
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, name = reaper.GetTrackName(tr)
    if ok and name == "EVENTS" then
      events_track = tr
      break
    end
  end
  if not events_track then 
    return nil 
  end
  
  -- Find first MIDI item on track
  local item_count = reaper.CountTrackMediaItems(events_track)
  
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(events_track, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      -- MIDI_CountEvts returns: retval, notecnt, ccevtcnt, textsyxevtcnt
      local _, _, _, textsyx_cnt = reaper.MIDI_CountEvts(take)
      
      for ev = 0, textsyx_cnt - 1 do
        local ok, sel, muted, ppq, typ, msg = reaper.MIDI_GetTextSysexEvt(take, ev, false, false, 0, 0, "")
        if ok and typ >= 1 and msg == event_name then
          local proj_time = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)
          -- Use format_timestr_pos with mode 2 for measures.beats.time format
          -- Returns format like "133.5.50" which is exactly what we want
          return reaper.format_timestr_pos(proj_time, "", 2)
        end
      end
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Draw Setup Tab Content (public function called from fcp_tracker_ui.lua)
--------------------------------------------------------------------------------
function draw_setup_tab(ctx)
  -- Get available size for the child regions (returns width, height)
  local _, avail_h = ImGui.ImGui_GetContentRegionAvail(ctx)
  
  -- LEFT COLUMN: Use a Child region to fill available height
  if ImGui.ImGui_BeginChild(ctx, "LeftColumn", 136, avail_h, 0, ImGui.ImGui_WindowFlags_NoScrollbar()) then
    ImGui.ImGui_Text(ctx, "Essential Events:")
    ImGui.ImGui_Spacing(ctx)
    ImGui.ImGui_Spacing(ctx)
    
    local music_start_mbt = get_event_mbt("[music_start]") or "—"
    local music_end_mbt = get_event_mbt("[music_end]") or "—"
    local end_mbt = get_event_mbt("[end]") or "—"
    
    -- Event table with 2 columns: name and mbt
    if ImGui.ImGui_BeginTable(ctx, "Events_Table", 2, ImGui.ImGui_TableFlags_None()) then
      ImGui.ImGui_TableSetupColumn(ctx, "EventName", ImGui.ImGui_TableColumnFlags_WidthFixed(), 75)
      ImGui.ImGui_TableSetupColumn(ctx, "EventMBT", ImGui.ImGui_TableColumnFlags_WidthFixed(), 61)
      
      -- [music_start] row
      ImGui.ImGui_TableNextRow(ctx)
      ImGui.ImGui_TableNextColumn(ctx)
      if ImGui.ImGui_Selectable(ctx, "[music_start]##sel1", false, ImGui.ImGui_SelectableFlags_SpanAllColumns(), 0, 0) then
        local t = get_event_time("[music_start]")
        local me = reaper.MIDIEditor_GetActive()
        if t then
          -- Event exists: jump to it
          reaper.SetEditCurPos(t, true, false)
          set_time_selection_around(t)
          open_events_in_midi_editor()
        elseif me then
          -- MIDI editor open, event doesn't exist: create at cursor
          insert_essential_event("[music_start]")
          set_time_selection_around(reaper.GetCursorPosition())
        else
          -- MIDI editor not open, event doesn't exist: move to 3.1.00
          local measure3_time = reaper.TimeMap2_beatsToTime(0, 0, 2)  -- measure 3 = index 2 (0-based)
          reaper.SetEditCurPos(measure3_time, true, false)
          set_time_selection_around(measure3_time)
          open_events_in_midi_editor()
        end
      end
      if ImGui.ImGui_IsItemHovered(ctx) then
        local t = get_event_time("[music_start]")
        local me = reaper.MIDIEditor_GetActive()
        if t then
          ImGui.ImGui_SetTooltip(ctx, "Go to [music_start] event")
        elseif me then
          ImGui.ImGui_SetTooltip(ctx, "Insert [music_start] event at cursor")
        else
          ImGui.ImGui_SetTooltip(ctx, "Open EVENTS track")
        end
      end
      ImGui.ImGui_TableNextColumn(ctx)
      ImGui.ImGui_Text(ctx, music_start_mbt)
      
      -- [music_end] row
      ImGui.ImGui_TableNextRow(ctx)
      ImGui.ImGui_TableNextColumn(ctx)
      if ImGui.ImGui_Selectable(ctx, "[music_end]##sel2", false, ImGui.ImGui_SelectableFlags_SpanAllColumns(), 0, 0) then
        local t = get_event_time("[music_end]")
        local me = reaper.MIDIEditor_GetActive()
        if t then
          -- Event exists: jump to it
          reaper.SetEditCurPos(t, true, false)
          set_time_selection_around(t)
          open_events_in_midi_editor()
        elseif me then
          -- MIDI editor open, event doesn't exist: create at cursor
          insert_essential_event("[music_end]")
          set_time_selection_around(reaper.GetCursorPosition())
        else
          -- MIDI editor not open, event doesn't exist: just open editor
          open_events_in_midi_editor()
        end
      end
      if ImGui.ImGui_IsItemHovered(ctx) then
        local t = get_event_time("[music_end]")
        local me = reaper.MIDIEditor_GetActive()
        if t then
          ImGui.ImGui_SetTooltip(ctx, "Go to [music_end] event")
        elseif me then
          ImGui.ImGui_SetTooltip(ctx, "Insert [music_end] event at cursor")
        else
          ImGui.ImGui_SetTooltip(ctx, "Open EVENTS track")
        end
      end
      ImGui.ImGui_TableNextColumn(ctx)
      ImGui.ImGui_Text(ctx, music_end_mbt)
      
      -- [end] row
      ImGui.ImGui_TableNextRow(ctx)
      ImGui.ImGui_TableNextColumn(ctx)
      if ImGui.ImGui_Selectable(ctx, "[end]##sel3", false, ImGui.ImGui_SelectableFlags_SpanAllColumns(), 0, 0) then
        local t = get_event_time("[end]")
        local me = reaper.MIDIEditor_GetActive()
        if t then
          -- Event exists: jump to it
          reaper.SetEditCurPos(t, true, false)
          set_time_selection_around(t)
          open_events_in_midi_editor()
        elseif me then
          -- MIDI editor open, event doesn't exist: create at cursor
          insert_essential_event("[end]")
          set_time_selection_around(reaper.GetCursorPosition())
        else
          -- MIDI editor not open, event doesn't exist: just open editor
          open_events_in_midi_editor()
        end
      end
      if ImGui.ImGui_IsItemHovered(ctx) then
        local t = get_event_time("[end]")
        local me = reaper.MIDIEditor_GetActive()
        if t then
          ImGui.ImGui_SetTooltip(ctx, "Go to [end] event")
        elseif me then
          ImGui.ImGui_SetTooltip(ctx, "Insert [end] event at cursor")
        else
          ImGui.ImGui_SetTooltip(ctx, "Open EVENTS track")
        end
      end
      ImGui.ImGui_TableNextColumn(ctx)
      ImGui.ImGui_Text(ctx, end_mbt)
      
      ImGui.ImGui_EndTable(ctx)
    end
    
    -- Calculate space needed for version info (separator + 2 text lines + spacing)
    local line_height = ImGui.ImGui_GetTextLineHeightWithSpacing(ctx)
    local version_height = line_height * 2 + 10  -- 2 lines + separator/spacing
    
    -- Get the child window's content height and set cursor to bottom
    local child_h = ImGui.ImGui_GetWindowHeight(ctx)
    local target_y = child_h - version_height
    local current_y = ImGui.ImGui_GetCursorPosY(ctx)
    
    -- Only move down if there's room (version info stays at bottom)
    if target_y > current_y then
      ImGui.ImGui_SetCursorPosY(ctx, target_y)
    end
    
    -- Version info at bottom of left column (no separator)
    ImGui.ImGui_Spacing(ctx)
    local version_text = "v" .. (SCRIPT_VERSION or "?.?.?")
    ImGui.ImGui_Text(ctx, "Version: " .. version_text)
    ImGui.ImGui_Text(ctx, "(Updates via ReaPack)")
    
    ImGui.ImGui_EndChild(ctx)
  end
  
  -- Vertical separator after left column
  ImGui.ImGui_SameLine(ctx)
  local sep_x1, sep_y1 = ImGui.ImGui_GetCursorScreenPos(ctx)
  local draw_list = ImGui.ImGui_GetWindowDrawList(ctx)
  -- Use a semi-transparent gray for separator (AABBGGRR format)
  local sep_color = 0x80808080
  ImGui.ImGui_DrawList_AddLine(draw_list, sep_x1, sep_y1 + 4, sep_x1, sep_y1 + avail_h, sep_color, 1.0)
  ImGui.ImGui_Dummy(ctx, 8, 0)  -- spacing for separator
  
  -- MIDDLE COLUMN: PRC Tools
  ImGui.ImGui_SameLine(ctx)
  
  -- Fixed width for middle column (PRC tools)
  local middle_w = 360
  
  if ImGui.ImGui_BeginChild(ctx, "MiddleColumn", middle_w, avail_h, 0, ImGui.ImGui_WindowFlags_NoScrollbar()) then
    ImGui.ImGui_Text(ctx, "Create practice section events:")
    ImGui.ImGui_Spacing(ctx)
    ImGui.ImGui_Spacing(ctx)
    -- PRC Table: 3 columns x 2 rows (labels on top, combos on bottom)
    if ImGui.ImGui_BeginTable(ctx, "PRC_Table", 3, ImGui.ImGui_TableFlags_None()) then
      ImGui.ImGui_TableSetupColumn(ctx, "Section", ImGui.ImGui_TableColumnFlags_WidthFixed(), 120)
      ImGui.ImGui_TableSetupColumn(ctx, "LetterNum", ImGui.ImGui_TableColumnFlags_WidthFixed(), 65)
      ImGui.ImGui_TableSetupColumn(ctx, "NumLetter", ImGui.ImGui_TableColumnFlags_WidthFixed(), 65)
      -- header row
      ImGui.ImGui_TableNextRow(ctx)
      ImGui.ImGui_TableNextColumn(ctx); ImGui.ImGui_Text(ctx, "Section")
      ImGui.ImGui_TableNextColumn(ctx); ImGui.ImGui_Text(ctx, (PRC_sel_base == "" and "Letter" or "Number"))
      ImGui.ImGui_TableNextColumn(ctx); ImGui.ImGui_Text(ctx, (PRC_sel_base == "" and "Number" or "Letter"))
    
      -- controls row
      ImGui.ImGui_TableNextRow(ctx)
    
      -- col 1: base
      ImGui.ImGui_TableNextColumn(ctx)
      do
        local items = (function()
          local v = {""}
          for i=1,#PRC_base_list do v[#v+1] = PRC_base_list[i] end
          return v
        end)()
        local avail = ({ImGui.ImGui_GetContentRegionAvail(ctx)})[1]
        ImGui.ImGui_SetNextItemWidth(ctx, avail)
        local changed_base; changed_base, PRC_sel_base = combo_from_list(ctx, "##base", PRC_sel_base, items)
        if changed_base then PRC_sel_num, PRC_sel_letter = "", "" end
      end
    
      -- col 2: letter or number
      ImGui.ImGui_TableNextColumn(ctx)
      local avail2 = ({ImGui.ImGui_GetContentRegionAvail(ctx)})[1]
      if PRC_sel_base == "" then
        local letters = PRC_options_letters_when_blank()
        ImGui.ImGui_SetNextItemWidth(ctx, avail2)
        local chL; chL, PRC_sel_letter = combo_from_list(ctx, "##letter", PRC_sel_letter, letters)
        if chL then PRC_sel_num = "" end
      else
        local nums = PRC_options_for_numbers_when_base(PRC_sel_base)
        ImGui.ImGui_SetNextItemWidth(ctx, avail2)
        local chN; chN, PRC_sel_num = combo_from_list(ctx, "##num", PRC_sel_num, nums)
        if chN then PRC_sel_letter = "" end
      end
    
      -- col 3: number or letter
      ImGui.ImGui_TableNextColumn(ctx)
      local avail3 = ({ImGui.ImGui_GetContentRegionAvail(ctx)})[1]
      if PRC_sel_base == "" then
        local nums = PRC_options_numbers_for_blank_letter(PRC_sel_letter ~= "" and PRC_sel_letter or "\0")
        ImGui.ImGui_SetNextItemWidth(ctx, avail3)
        local chN; chN, PRC_sel_num = combo_from_list(ctx, "##num_blank", PRC_sel_num, nums)
      else
        local letters = PRC_options_for_letters_when_base(PRC_sel_base, PRC_sel_num)
        ImGui.ImGui_SetNextItemWidth(ctx, avail3)
        local chL; chL, PRC_sel_letter = combo_from_list(ctx, "##letter_base", PRC_sel_letter, letters)
      end
    
      ImGui.ImGui_EndTable(ctx)
    end
    
    -- Preview + insert
    local ok, tok2 = PRC_valid_current_token()
    local preview = ok and ('['..tok2..']') or '—'
    ImGui.ImGui_NewLine(ctx)
    -- Make the Practice Section Event line clickable
    local prc_label = "Practice Section Event: "..preview
    local prc_label_w = ({ImGui.ImGui_CalcTextSize(ctx, prc_label)})[1]
    if ImGui.ImGui_Selectable(ctx, prc_label.."##prc_selectable", false, 0, prc_label_w, 0) then
      -- Get stored last insert position for this project
      local _, stored_time_str = reaper.GetProjExtState(0, "FCP_PROGRESS", "LAST_PRC_INSERT_TIME")
      local t = nil
      if stored_time_str and stored_time_str ~= "" then
        t = tonumber(stored_time_str)
      end
      if not t then
        -- Fallback to latest prc event
        t = get_latest_prc_event_time()
      end
      if t then
        reaper.SetEditCurPos(t, true, false)
        set_time_selection_around(t)
      end
      open_events_in_midi_editor()
    end
    if ImGui.ImGui_IsItemHovered(ctx) then
      ImGui.ImGui_SetTooltip(ctx, "Go to latest-added Practice Section event")
    end
    ImGui.ImGui_Spacing(ctx)
    if ok then
      if ImGui.ImGui_Button(ctx, "Insert", 100, 0) then PRC_insert_event('['..tok2..']') end
      if ImGui.ImGui_IsKeyPressed(ctx, ImGui.ImGui_Key_Enter()) then PRC_insert_event('['..tok2..']') end
    else
      ImGui.ImGui_BeginDisabled(ctx)
      ImGui.ImGui_Button(ctx, "Insert", 100, 0)
      ImGui.ImGui_EndDisabled(ctx)
    end
    
    ImGui.ImGui_Spacing(ctx)
    ImGui.ImGui_Spacing(ctx)
    ImGui.ImGui_Spacing(ctx)
    ImGui.ImGui_Spacing(ctx)
    ImGui.ImGui_Spacing(ctx)
    ImGui.ImGui_Text(ctx, "Convert to Regions:")
    ImGui.ImGui_Spacing(ctx)
    if ImGui.ImGui_Button(ctx, "Convert All Practice Sections to Regions", 240, 0) then PRC_convert_to_regions() end
    
    ImGui.ImGui_EndChild(ctx)
  end
  
  -- Vertical separator after middle column
  ImGui.ImGui_SameLine(ctx)
  local sep_x2, sep_y2 = ImGui.ImGui_GetCursorScreenPos(ctx)
  ImGui.ImGui_DrawList_AddLine(draw_list, sep_x2, sep_y2 + 4, sep_x2, sep_y2 + avail_h, sep_color, 1.0)
  ImGui.ImGui_Dummy(ctx, 8, 0)  -- spacing for separator
  
  -- RIGHT COLUMN: Action Command IDs
  ImGui.ImGui_SameLine(ctx)
  
  -- Get remaining width for right column
  local right_avail_w = ImGui.ImGui_GetContentRegionAvail(ctx)
  
  if ImGui.ImGui_BeginChild(ctx, "RightColumn", right_avail_w, avail_h, 0, ImGui.ImGui_WindowFlags_NoScrollbar()) then
    ImGui.ImGui_Text(ctx, "Paste Action Command IDs here:")
    ImGui.ImGui_Spacing(ctx)
    ImGui.ImGui_Spacing(ctx)
    
    -- Initialize buffers from ExtState if not already done
    if not SETUP_CMD_BUFFERS then
      SETUP_CMD_BUFFERS = {
        encore_vox    = reaper.GetExtState(EXT_NS, EXT_CMD_ENCORE_VOX) or "",
        lyrics_clip   = reaper.GetExtState(EXT_NS, EXT_CMD_LYRICS_CLIP) or "",
        spectracular  = reaper.GetExtState(EXT_NS, EXT_CMD_SPECTRACULAR) or "",
        venue_preview = reaper.GetExtState(EXT_NS, EXT_CMD_VENUE_PREVIEW) or "",
        pro_keys_preview = reaper.GetExtState(EXT_NS, EXT_CMD_PRO_KEYS_PREVIEW) or "",
      }
    end
    
    local label_w = 120
    
    -- Encore Vox Preview
    ImGui.ImGui_Text(ctx, "Encore Vox Preview:")
    ImGui.ImGui_SameLine(ctx, label_w)
    ImGui.ImGui_SetNextItemWidth(ctx, -1)  -- Fill remaining width
    local changed1, new_val1 = ImGui.ImGui_InputText(ctx, "##encore_vox", SETUP_CMD_BUFFERS.encore_vox)
    if changed1 and new_val1 ~= SETUP_CMD_BUFFERS.encore_vox then
      SETUP_CMD_BUFFERS.encore_vox = new_val1
      reaper.SetExtState(EXT_NS, EXT_CMD_ENCORE_VOX, new_val1, true)
    end
    
    -- Lyrics Clipboard
    ImGui.ImGui_Text(ctx, "Lyrics Clipboard:")
    ImGui.ImGui_SameLine(ctx, label_w)
    ImGui.ImGui_SetNextItemWidth(ctx, -1)  -- Fill remaining width
    local changed2, new_val2 = ImGui.ImGui_InputText(ctx, "##lyrics_clip", SETUP_CMD_BUFFERS.lyrics_clip)
    if changed2 and new_val2 ~= SETUP_CMD_BUFFERS.lyrics_clip then
      SETUP_CMD_BUFFERS.lyrics_clip = new_val2
      reaper.SetExtState(EXT_NS, EXT_CMD_LYRICS_CLIP, new_val2, true)
    end
    
    -- Spectracular (runs with Vocals tab)
    ImGui.ImGui_Text(ctx, "Spectracular Stereo:")
    ImGui.ImGui_SameLine(ctx, label_w)
    ImGui.ImGui_SetNextItemWidth(ctx, -1)  -- Fill remaining width
    local changed3, new_val3 = ImGui.ImGui_InputText(ctx, "##spectracular", SETUP_CMD_BUFFERS.spectracular)
    if changed3 and new_val3 ~= SETUP_CMD_BUFFERS.spectracular then
      SETUP_CMD_BUFFERS.spectracular = new_val3
      reaper.SetExtState(EXT_NS, EXT_CMD_SPECTRACULAR, new_val3, true)
    end
    
    -- Venue Preview (runs with Venue tab)
    ImGui.ImGui_Text(ctx, "Venue Preview:")
    ImGui.ImGui_SameLine(ctx, label_w)
    ImGui.ImGui_SetNextItemWidth(ctx, -1)  -- Fill remaining width
    local changed4, new_val4 = ImGui.ImGui_InputText(ctx, "##venue_preview", SETUP_CMD_BUFFERS.venue_preview)
    if changed4 and new_val4 ~= SETUP_CMD_BUFFERS.venue_preview then
      SETUP_CMD_BUFFERS.venue_preview = new_val4
      reaper.SetExtState(EXT_NS, EXT_CMD_VENUE_PREVIEW, new_val4, true)
    end
    
    -- Pro Keys Preview (runs with Pro Keys tab)
    ImGui.ImGui_Text(ctx, "Pro Keys Preview:")
    ImGui.ImGui_SameLine(ctx, label_w)
    ImGui.ImGui_SetNextItemWidth(ctx, -1)  -- Fill remaining width
    local changed5, new_val5 = ImGui.ImGui_InputText(ctx, "##pro_keys_preview", SETUP_CMD_BUFFERS.pro_keys_preview)
    if changed5 and new_val5 ~= SETUP_CMD_BUFFERS.pro_keys_preview then
      SETUP_CMD_BUFFERS.pro_keys_preview = new_val5
      reaper.SetExtState(EXT_NS, EXT_CMD_PRO_KEYS_PREVIEW, new_val5, true)
    end
    
    ImGui.ImGui_EndChild(ctx)
  end
end

--------------------------------------------------------------------------------
-- PASTE THE COMPLETE WHITELIST BETWEEN THE MARKERS BELOW, UNCHANGED.
-- The format must be exactly one token per line, like: [prc_intro]
--------------------------------------------------------------------------------
--__PRC_ALLOWED_START__
--[[
[prc_intro]
[prc_intro_a]
[prc_intro_b]
[prc_intro_c]
[prc_intro_d]
[prc_intro_e]
[prc_intro_slow]
[prc_intro_slow_a]
[prc_intro_slow_b]
[prc_intro_slow_c]
[prc_intro_slow_d]
[prc_intro_slow_1]
[prc_intro_fast]
[prc_intro_fast_a]
[prc_intro_fast_b]
[prc_intro_fast_c]
[prc_intro_fast_d]
[prc_intro_heavy]
[prc_intro_heavy_a]
[prc_intro_heavy_b]
[prc_intro_heavy_c]
[prc_intro_heavy_d]
[prc_quiet_intro]
[prc_quiet_intro_a]
[prc_quiet_intro_b]
[prc_quiet_intro_c]
[prc_quiet_intro_d]
[prc_noise_intro]
[prc_noise_intro_a]
[prc_noise_intro_b]
[prc_noise_intro_c]
[prc_noise_intro_d]
[prc_drum_intro]
[prc_drum_intro_a]
[prc_drum_intro_b]
[prc_drum_intro_c]
[prc_drum_intro_d]
[prc_bass_intro]
[prc_bass_intro_a]
[prc_bass_intro_b]
[prc_bass_intro_c]
[prc_bass_intro_d]
[prc_vocal_intro]
[prc_vocal_intro_a]
[prc_vocal_intro_b]
[prc_vocal_intro_c]
[prc_vocal_intro_d]
[prc_gtr_intro]
[prc_gtr_intro_a]
[prc_gtr_intro_b]
[prc_gtr_intro_c]
[prc_gtr_intro_d]
[prc_gtr_intro_e]
[prc_violin_intro]
[prc_violin_intro_a]
[prc_violin_intro_b]
[prc_violin_intro_c]
[prc_violin_intro_d]
[prc_strings_intro]
[prc_strings_intro_a]
[prc_strings_intro_b]
[prc_strings_intro_c]
[prc_strings_intro_d]
[prc_orch_intro]
[prc_orch_intro_a]
[prc_orch_intro_b]
[prc_orch_intro_c]
[prc_orch_intro_d]
[prc_horn_intro]
[prc_horn_intro_a]
[prc_horn_intro_b]
[prc_horn_intro_c]
[prc_horn_intro_d]
[prc_harmonica_intro]
[prc_harmonica_intro_a]
[prc_harmonica_intro_b]
[prc_harmonica_intro_c]
[prc_harmonica_intro_d]
[prc_organ_intro]
[prc_organ_intro_a]
[prc_organ_intro_b]
[prc_organ_intro_c]
[prc_organ_intro_d]
[prc_piano_intro]
[prc_piano_intro_a]
[prc_piano_intro_b]
[prc_piano_intro_c]
[prc_piano_intro_d]
[prc_keyboard_intro]
[prc_keyboard_intro_a]
[prc_keyboard_intro_b]
[prc_keyboard_intro_c]
[prc_keyboard_intro_d]
[prc_dj_intro]
[prc_dj_intro_b]
[prc_dj_intro_c]
[prc_dj_intro_d]
[prc_intro_hook]
[prc_intro_hook_a]
[prc_intro_hook_b]
[prc_intro_hook_c]
[prc_intro_hook_d]
[prc_intro_riff]
[prc_intro_riff_a]
[prc_intro_riff_b]
[prc_intro_riff_c]
[prc_intro_riff_d]
[prc_fade_in]
[prc_fade_in_a]
[prc_fade_in_b]
[prc_fade_in_c]
[prc_fade_in_d]
[prc_drums_enter]
[prc_bass_enters]
[prc_gtr_enters]
[prc_rhy_enters]
[prc_band_enters]
[prc_syth_enters]
[prc_keyb_enters]
[prc_organ_enters]
[prc_piano_enters]
[prc_kick_it]
[prc_intro_verse]
[prc_intro_verse_a]
[prc_intro_verse_b]
[prc_intro_verse_c]
[prc_intro_verse_d]
[prc_intro_chorus]
[prc_intro_chorus_a]
[prc_intro_chorus_b]
[prc_intro_chorus_c]
[prc_intro_chorus_d]
[prc_verse]
[prc_verse_a]
[prc_verse_b]
[prc_verse_c]
[prc_verse_d]
[prc_verse_e]
[prc_verse_f]
[prc_verse_1]
[prc_verse_1a]
[prc_verse_1b]
[prc_verse_1c]
[prc_verse_1d]
[prc_verse_1e]
[prc_verse_1f]
[prc_verse_2]
[prc_verse_2a]
[prc_verse_2b]
[prc_verse_2c]
[prc_verse_2d]
[prc_verse_2e]
[prc_verse_2f]
[prc_verse_3]
[prc_verse_3a]
[prc_verse_3b]
[prc_verse_3c]
[prc_verse_3d]
[prc_verse_3e]
[prc_verse_3f]
[prc_verse_4]
[prc_verse_4a]
[prc_verse_4b]
[prc_verse_4c]
[prc_verse_4d]
[prc_verse_5]
[prc_verse_5a]
[prc_verse_5b]
[prc_verse_5c]
[prc_verse_5d]
[prc_verse_6]
[prc_verse_6a]
[prc_verse_6b]
[prc_verse_6c]
[prc_verse_6d]
[prc_verse_7]
[prc_verse_7a]
[prc_verse_7b]
[prc_verse_7c]
[prc_verse_7d]
[prc_verse_8]
[prc_verse_8a]
[prc_verse_8b]
[prc_verse_8c]
[prc_verse_8d]
[prc_verse_9]
[prc_verse_9a]
[prc_verse_9b]
[prc_verse_9c]
[prc_verse_9d]
[prc_alt_verse]
[prc_alt_verse_a]
[prc_alt_verse_b]
[prc_alt_verse_c]
[prc_alt_verse_d]
[prc_quiet_verse]
[prc_quiet_verse_a]
[prc_quiet_verse_b]
[prc_quiet_verse_c]
[prc_quiet_verse_d]
[prc_preverse]
[prc_preverse_a]
[prc_preverse_b]
[prc_preverse_c]
[prc_preverse_d]
[prc_preverse_1]
[prc_preverse_1a]
[prc_preverse_1b]
[prc_preverse_1c]
[prc_preverse_1d]
[prc_preverse_2]
[prc_preverse_2a]
[prc_preverse_2b]
[prc_preverse_2c]
[prc_preverse_2d]
[prc_preverse_3]
[prc_preverse_3a]
[prc_preverse_3b]
[prc_preverse_3c]
[prc_preverse_3d]
[prc_preverse_4]
[prc_preverse_4a]
[prc_preverse_4b]
[prc_preverse_4c]
[prc_preverse_4d]
[prc_preverse_5]
[prc_preverse_5a]
[prc_preverse_5b]
[prc_preverse_5c]
[prc_preverse_5d]
[prc_postverse]
[prc_postverse_a]
[prc_postverse_b]
[prc_postverse_c]
[prc_postverse_d]
[prc_postverse_1]
[prc_postverse_1a]
[prc_postverse_1b]
[prc_postverse_1c]
[prc_postverse_1d]
[prc_postverse_2]
[prc_postverse_2a]
[prc_postverse_2b]
[prc_postverse_2c]
[prc_postverse_2d]
[prc_postverse_3]
[prc_postverse_3a]
[prc_postverse_3b]
[prc_postverse_3c]
[prc_postverse_3d]
[prc_postverse_4]
[prc_postverse_4a]
[prc_postverse_4b]
[prc_postverse_4c]
[prc_postverse_4d]
[prc_postverse_5]
[prc_postverse_5a]
[prc_postverse_5b]
[prc_postverse_5c]
[prc_postverse_5d]
[prc_chorus]
[prc_chorus_a]
[prc_chorus_b]
[prc_chorus_c]
[prc_chorus_d]
[prc_chorus_1]
[prc_chorus_1a]
[prc_chorus_1b]
[prc_chorus_1c]
[prc_chorus_1d]
[prc_chorus_2]
[prc_chorus_2a]
[prc_chorus_2b]
[prc_chorus_2c]
[prc_chorus_2d]
[prc_chorus_3]
[prc_chorus_3a]
[prc_chorus_3b]
[prc_chorus_3c]
[prc_chorus_3d]
[prc_chorus_4]
[prc_chorus_4a]
[prc_chorus_4b]
[prc_chorus_4c]
[prc_chorus_4d]
[prc_chorus_5]
[prc_chorus_5a]
[prc_chorus_5b]
[prc_chorus_5c]
[prc_chorus_5d]
[prc_chorus_6]
[prc_chorus_6a]
[prc_chorus_6b]
[prc_chorus_6c]
[prc_chorus_6d]
[prc_chorus_7]
[prc_chorus_7a]
[prc_chorus_7b]
[prc_chorus_7c]
[prc_chorus_7d]
[prc_chorus_8]
[prc_chorus_8a]
[prc_chorus_8b]
[prc_chorus_8c]
[prc_chorus_8d]
[prc_chorus_9]
[prc_chorus_9a]
[prc_chorus_9b]
[prc_chorus_9c]
[prc_chorus_9d]
[prc_chorus_break]
[prc_chorus_break_a]
[prc_chorus_break_b]
[prc_chorus_break_c]
[prc_chorus_break_d]
[prc_breakdown_chorus]
[prc_breakdown_chorus_a]
[prc_breakdown_chorus_b]
[prc_breakdown_chorus_c]
[prc_breakdown_chorus_d]
[prc_alt_chorus]
[prc_alt_chorus_a]
[prc_alt_chorus_b]
[prc_alt_chorus_c]
[prc_alt_chorus_d]
[prc_prechorus]
[prc_prechorus_a]
[prc_prechorus_b]
[prc_prechorus_c]
[prc_prechorus_d]
[prc_prechorus_1]
[prc_prechorus_1a]
[prc_prechorus_1b]
[prc_prechorus_1c]
[prc_prechorus_1d]
[prc_prechorus_2]
[prc_prechorus_2a]
[prc_prechorus_2b]
[prc_prechorus_2c]
[prc_prechorus_2d]
[prc_prechorus_3]
[prc_prechorus_3a]
[prc_prechorus_3b]
[prc_prechorus_3c]
[prc_prechorus_3d]
[prc_prechorus_4]
[prc_prechorus_4a]
[prc_prechorus_4b]
[prc_prechorus_4c]
[prc_prechorus_4d]
[prc_prechorus_5]
[prc_prechorus_5a]
[prc_prechorus_5b]
[prc_prechorus_5c]
[prc_prechorus_5d]
[prc_postchorus]
[prc_postchorus_a]
[prc_postchorus_b]
[prc_postchorus_c]
[prc_postchorus_d]
[prc_postchorus_1]
[prc_postchorus_1a]
[prc_postchorus_1b]
[prc_postchorus_1c]
[prc_postchorus_1d]
[prc_postchorus_2]
[prc_postchorus_2a]
[prc_postchorus_2b]
[prc_postchorus_2c]
[prc_postchorus_2d]
[prc_postchorus_3]
[prc_postchorus_3a]
[prc_postchorus_3b]
[prc_postchorus_3c]
[prc_postchorus_3d]
[prc_postchorus_4]
[prc_postchorus_4a]
[prc_postchorus_4b]
[prc_postchorus_4c]
[prc_postchorus_4d]
[prc_postchorus_5]
[prc_postchorus_5a]
[prc_postchorus_5b]
[prc_postchorus_5c]
[prc_postchorus_5d]
[prc_bridge]
[prc_bridge_a]
[prc_bridge_b]
[prc_bridge_c]
[prc_bridge_d]
[prc_bridge_1]
[prc_bridge_1a]
[prc_bridge_1b]
[prc_bridge_1c]
[prc_bridge_1d]
[prc_bridge_2]
[prc_bridge_2a]
[prc_bridge_2b]
[prc_bridge_2c]
[prc_bridge_2d]
[prc_bridge_3]
[prc_bridge_3a]
[prc_bridge_3b]
[prc_bridge_3c]
[prc_bridge_3d]
[prc_bridge_4]
[prc_bridge_4a]
[prc_bridge_4b]
[prc_bridge_4c]
[prc_bridge_4d]
[prc_bridge_5]
[prc_bridge_5a]
[prc_bridge_5b]
[prc_bridge_5c]
[prc_bridge_5d]
[prc_bridge_6]
[prc_bridge_6a]
[prc_bridge_6b]
[prc_bridge_6c]
[prc_bridge_6d]
[prc_bridge_7]
[prc_bridge_7a]
[prc_bridge_7b]
[prc_bridge_7c]
[prc_bridge_7d]
[prc_bridge_8]
[prc_bridge_8a]
[prc_bridge_8b]
[prc_bridge_8c]
[prc_bridge_8d]
[prc_bridge_9]
[prc_bridge_9a]
[prc_bridge_9b]
[prc_bridge_9c]
[prc_bridge_9d]
[prc_gtr_solo]
[prc_gtr_solo_a]
[prc_gtr_solo_b]
[prc_gtr_solo_c]
[prc_gtr_solo_d]
[prc_gtr_solo_e]
[prc_gtr_solo_f]
[prc_gtr_solo_g]
[prc_gtr_solo_h]
[prc_gtr_solo_i]
[prc_gtr_solo_j]
[prc_gtr_solo_k]
[prc_gtr_solo_l]
[prc_gtr_solo_m]
[prc_gtr_solo_n]
[prc_gtr_solo_o]
[prc_gtr_solo_p]
[prc_gtr_solo_q]
[prc_gtr_solo_r]
[prc_gtr_solo_s]
[prc_gtr_solo_1]
[prc_gtr_solo_1a]
[prc_gtr_solo_1b]
[prc_gtr_solo_1c]
[prc_gtr_solo_1d]
[prc_gtr_solo_1e]
[prc_gtr_solo_1f]
[prc_gtr_solo_1g]
[prc_gtr_solo_1h]
[prc_gtr_solo_1i]
[prc_gtr_solo_1j]
[prc_gtr_solo_1k]
[prc_gtr_solo_1l]
[prc_gtr_solo_1m]
[prc_gtr_solo_1n]
[prc_gtr_solo_2]
[prc_gtr_solo_2a]
[prc_gtr_solo_2b]
[prc_gtr_solo_2c]
[prc_gtr_solo_2d]
[prc_gtr_solo_2e]
[prc_gtr_solo_2f]
[prc_gtr_solo_2g]
[prc_gtr_solo_2h]
[prc_gtr_solo_2i]
[prc_gtr_solo_2j]
[prc_gtr_solo_2k]
[prc_gtr_solo_2l]
[prc_gtr_solo_2m]
[prc_gtr_solo_2n]
[prc_gtr_solo_3]
[prc_gtr_solo_3a]
[prc_gtr_solo_3b]
[prc_gtr_solo_3c]
[prc_gtr_solo_3d]
[prc_gtr_solo_3e]
[prc_gtr_solo_3f]
[prc_gtr_solo_3g]
[prc_gtr_solo_3h]
[prc_gtr_solo_3i]
[prc_gtr_solo_3j]
[prc_gtr_solo_3k]
[prc_gtr_solo_3l]
[prc_gtr_solo_3m]
[prc_gtr_solo_3n]
[prc_gtr_solo_4]
[prc_gtr_solo_4a]
[prc_gtr_solo_4b]
[prc_gtr_solo_4c]
[prc_gtr_solo_4d]
[prc_gtr_solo_4e]
[prc_gtr_solo_4f]
[prc_gtr_solo_4g]
[prc_gtr_solo_4h]
[prc_gtr_solo_4i]
[prc_gtr_solo_4j]
[prc_gtr_solo_4k]
[prc_gtr_solo_4l]
[prc_gtr_solo_4m]
[prc_gtr_solo_4n]
[prc_gtr_solo_5]
[prc_gtr_solo_5a]
[prc_gtr_solo_5b]
[prc_gtr_solo_5c]
[prc_gtr_solo_5d]
[prc_gtr_solo_5e]
[prc_gtr_solo_5f]
[prc_gtr_solo_5g]
[prc_gtr_solo_5h]
[prc_gtr_solo_5i]
[prc_gtr_solo_5j]
[prc_gtr_solo_5k]
[prc_gtr_solo_5l]
[prc_gtr_solo_5m]
[prc_gtr_solo_5n]
[prc_gtr_solo_6]
[prc_gtr_solo_6a]
[prc_gtr_solo_6b]
[prc_gtr_solo_6c]
[prc_gtr_solo_6d]
[prc_gtr_solo_6e]
[prc_gtr_solo_6f]
[prc_gtr_solo_6g]
[prc_gtr_solo_6h]
[prc_gtr_solo_6i]
[prc_gtr_solo_6j]
[prc_gtr_solo_6k]
[prc_gtr_solo_6l]
[prc_gtr_solo_6m]
[prc_gtr_solo_6n]
[prc_gtr_solo_7]
[prc_gtr_solo_7a]
[prc_gtr_solo_7b]
[prc_gtr_solo_7c]
[prc_gtr_solo_7d]
[prc_gtr_solo_7e]
[prc_gtr_solo_7f]
[prc_gtr_solo_7g]
[prc_gtr_solo_7h]
[prc_gtr_solo_7i]
[prc_gtr_solo_7j]
[prc_gtr_solo_7k]
[prc_gtr_solo_7l]
[prc_gtr_solo_7m]
[prc_gtr_solo_7n]
[prc_gtr_solo_8]
[prc_gtr_solo_8a]
[prc_gtr_solo_8b]
[prc_gtr_solo_8c]
[prc_gtr_solo_8d]
[prc_gtr_solo_8e]
[prc_gtr_solo_8f]
[prc_gtr_solo_8g]
[prc_gtr_solo_8h]
[prc_gtr_solo_8i]
[prc_gtr_solo_8j]
[prc_gtr_solo_8k]
[prc_gtr_solo_8l]
[prc_gtr_solo_8m]
[prc_gtr_solo_8n]
[prc_gtr_solo_9]
[prc_gtr_solo_9a]
[prc_gtr_solo_9b]
[prc_gtr_solo_9c]
[prc_gtr_solo_9d]
[prc_gtr_solo_9e]
[prc_gtr_solo_9f]
[prc_gtr_solo_9g]
[prc_gtr_solo_9h]
[prc_gtr_solo_9i]
[prc_gtr_solo_9j]
[prc_gtr_solo_9k]
[prc_gtr_solo_9l]
[prc_gtr_solo_9m]
[prc_gtr_solo_9n]
[prc_slide_solo]
[prc_slide_solo_a]
[prc_slide_solo_b]
[prc_slide_solo_c]
[prc_slide_solo_d]
[prc_slide_solo_1]
[prc_slide_solo_1a]
[prc_slide_solo_1b]
[prc_slide_solo_1c]
[prc_slide_solo_1d]
[prc_slide_solo_2]
[prc_slide_solo_2a]
[prc_slide_solo_2b]
[prc_slide_solo_2c]
[prc_slide_solo_2d]
[prc_slide_solo_3]
[prc_slide_solo_3a]
[prc_slide_solo_3b]
[prc_slide_solo_3c]
[prc_slide_solo_3d]
[prc_slide_solo_4]
[prc_slide_solo_4a]
[prc_slide_solo_4b]
[prc_slide_solo_4c]
[prc_slide_solo_4d]
[prc_drum_solo]
[prc_drum_solo_a]
[prc_drum_solo_b]
[prc_drum_solo_c]
[prc_drum_solo_d]
[prc_drum_solo_1]
[prc_drum_solo_1a]
[prc_drum_solo_1b]
[prc_drum_solo_1c]
[prc_drum_solo_1d]
[prc_drum_solo_2]
[prc_drum_solo_2a]
[prc_drum_solo_2b]
[prc_drum_solo_2c]
[prc_drum_solo_2d]
[prc_drum_solo_3]
[prc_drum_solo_3a]
[prc_drum_solo_3b]
[prc_drum_solo_3c]
[prc_drum_solo_3d]
[prc_drum_solo_4]
[prc_drum_solo_4a]
[prc_drum_solo_4b]
[prc_drum_solo_4c]
[prc_drum_solo_4d]
[prc_perc_solo]
[prc_perc_solo_a]
[prc_perc_solo_b]
[prc_perc_solo_c]
[prc_perc_solo_d]
[prc_perc_solo_1]
[prc_perc_solo_1a]
[prc_perc_solo_1b]
[prc_perc_solo_1c]
[prc_perc_solo_1d]
[prc_perc_solo_2]
[prc_perc_solo_2a]
[prc_perc_solo_2b]
[prc_perc_solo_2c]
[prc_perc_solo_2d]
[prc_perc_solo_3]
[prc_perc_solo_3a]
[prc_perc_solo_3b]
[prc_perc_solo_3c]
[prc_perc_solo_3d]
[prc_perc_solo_4]
[prc_perc_solo_4a]
[prc_perc_solo_4b]
[prc_perc_solo_4c]
[prc_perc_solo_4d]
[prc_bass_solo]
[prc_bass_solo_a]
[prc_bass_solo_b]
[prc_bass_solo_c]
[prc_bass_solo_d]
[prc_bass_solo_1]
[prc_bass_solo_1a]
[prc_bass_solo_1b]
[prc_bass_solo_1c]
[prc_bass_solo_1d]
[prc_bass_solo_2]
[prc_bass_solo_2a]
[prc_bass_solo_2b]
[prc_bass_solo_2c]
[prc_bass_solo_2d]
[prc_bass_solo_3]
[prc_bass_solo_3a]
[prc_bass_solo_3b]
[prc_bass_solo_3c]
[prc_bass_solo_3d]
[prc_bass_solo_4]
[prc_bass_solo_4a]
[prc_bass_solo_4b]
[prc_bass_solo_4c]
[prc_bass_solo_4d]
[prc_organ_solo]
[prc_organ_solo_a]
[prc_organ_solo_b]
[prc_organ_solo_c]
[prc_organ_solo_d]
[prc_organ_solo_1]
[prc_organ_solo_1a]
[prc_organ_solo_1b]
[prc_organ_solo_1c]
[prc_organ_solo_1d]
[prc_organ_solo_2]
[prc_organ_solo_2a]
[prc_organ_solo_2b]
[prc_organ_solo_2c]
[prc_organ_solo_2d]
[prc_organ_solo_3]
[prc_organ_solo_3a]
[prc_organ_solo_3b]
[prc_organ_solo_3c]
[prc_organ_solo_3d]
[prc_organ_solo_4]
[prc_organ_solo_4a]
[prc_organ_solo_4b]
[prc_organ_solo_4c]
[prc_organ_solo_4d]
[prc_piano_solo]
[prc_piano_solo_a]
[prc_piano_solo_b]
[prc_piano_solo_c]
[prc_piano_solo_d]
[prc_piano_solo_1]
[prc_piano_solo_1a]
[prc_piano_solo_1b]
[prc_piano_solo_1c]
[prc_piano_solo_1d]
[prc_piano_solo_2]
[prc_piano_solo_2a]
[prc_piano_solo_2b]
[prc_piano_solo_2c]
[prc_piano_solo_2d]
[prc_piano_solo_3]
[prc_piano_solo_3a]
[prc_piano_solo_3b]
[prc_piano_solo_3c]
[prc_piano_solo_3d]
[prc_piano_solo_4]
[prc_piano_solo_4a]
[prc_piano_solo_4b]
[prc_piano_solo_4c]
[prc_piano_solo_4d]
[prc_keyboard_solo]
[prc_keyboard_solo_a]
[prc_keyboard_solo_b]
[prc_keyboard_solo_c]
[prc_keyboard_solo_d]
[prc_keyboard_solo_1]
[prc_keyboard_solo_1a]
[prc_keyboard_solo_1b]
[prc_keyboard_solo_1c]
[prc_keyboard_solo_1d]
[prc_keyboard_solo_2]
[prc_keyboard_solo_2a]
[prc_keyboard_solo_2b]
[prc_keyboard_solo_2c]
[prc_keyboard_solo_2d]
[prc_keyboard_solo_3]
[prc_keyboard_solo_3a]
[prc_keyboard_solo_3b]
[prc_keyboard_solo_3c]
[prc_keyboard_solo_3d]
[prc_keyboard_solo_4]
[prc_keyboard_solo_4a]
[prc_keyboard_solo_4b]
[prc_keyboard_solo_4c]
[prc_keyboard_solo_4d]
[prc_synth_solo]
[prc_synth_solo_a]
[prc_synth_solo_b]
[prc_synth_solo_c]
[prc_synth_solo_d]
[prc_synth_solo_1]
[prc_synth_solo_1a]
[prc_synth_solo_1b]
[prc_synth_solo_1c]
[prc_synth_solo_1d]
[prc_synth_solo_2]
[prc_synth_solo_2a]
[prc_synth_solo_2b]
[prc_synth_solo_2c]
[prc_synth_solo_2d]
[prc_synth_solo_3]
[prc_synth_solo_3a]
[prc_synth_solo_3b]
[prc_synth_solo_3c]
[prc_synth_solo_3d]
[prc_synth_solo_4]
[prc_synth_solo_4a]
[prc_synth_solo_4b]
[prc_synth_solo_4c]
[prc_synth_solo_4d]
[prc_harmonica_solo]
[prc_harmonica_solo_a]
[prc_harmonica_solo_b]
[prc_harmonica_solo_c]
[prc_harmonica_solo_d]
[prc_harmonica_solo_1]
[prc_harmonica_solo_1a]
[prc_harmonica_solo_1b]
[prc_harmonica_solo_1c]
[prc_harmonica_solo_1d]
[prc_harmonica_solo_2]
[prc_harmonica_solo_2a]
[prc_harmonica_solo_2b]
[prc_harmonica_solo_2c]
[prc_harmonica_solo_2d]
[prc_harmonica_solo_3]
[prc_harmonica_solo_3a]
[prc_harmonica_solo_3b]
[prc_harmonica_solo_3c]
[prc_harmonica_solo_3d]
[prc_harmonica_solo_4]
[prc_harmonica_solo_4a]
[prc_harmonica_solo_4b]
[prc_harmonica_solo_4c]
[prc_harmonica_solo_4d]
[prc_sax_solo]
[prc_sax_solo_a]
[prc_sax_solo_b]
[prc_sax_solo_c]
[prc_sax_solo_d]
[prc_sax_solo_1]
[prc_sax_solo_1a]
[prc_sax_solo_1b]
[prc_sax_solo_1c]
[prc_sax_solo_1d]
[prc_sax_solo_2]
[prc_sax_solo_2a]
[prc_sax_solo_2b]
[prc_sax_solo_2c]
[prc_sax_solo_2d]
[prc_sax_solo_3]
[prc_sax_solo_3a]
[prc_sax_solo_3b]
[prc_sax_solo_3c]
[prc_sax_solo_3d]
[prc_sax_solo_4]
[prc_sax_solo_4a]
[prc_sax_solo_4b]
[prc_sax_solo_4c]
[prc_sax_solo_4d]
[prc_horn_solo]
[prc_horn_solo_a]
[prc_horn_solo_b]
[prc_horn_solo_c]
[prc_horn_solo_d]
[prc_horn_solo_1]
[prc_horn_solo_1a]
[prc_horn_solo_1b]
[prc_horn_solo_1c]
[prc_horn_solo_1d]
[prc_horn_solo_2]
[prc_horn_solo_2a]
[prc_horn_solo_2b]
[prc_horn_solo_2c]
[prc_horn_solo_2d]
[prc_horn_solo_3]
[prc_horn_solo_3a]
[prc_horn_solo_3b]
[prc_horn_solo_3c]
[prc_horn_solo_3d]
[prc_horn_solo_4]
[prc_horn_solo_4a]
[prc_horn_solo_4b]
[prc_horn_solo_4c]
[prc_horn_solo_4d]
[prc_flute_solo]
[prc_flute_solo_a]
[prc_flute_solo_b]
[prc_flute_solo_c]
[prc_flute_solo_d]
[prc_flute_solo_1]
[prc_flute_solo_1a]
[prc_flute_solo_1b]
[prc_flute_solo_1c]
[prc_flute_solo_1d]
[prc_flute_solo_2]
[prc_flute_solo_2a]
[prc_flute_solo_2b]
[prc_flute_solo_2c]
[prc_flute_solo_2d]
[prc_flute_solo_3]
[prc_flute_solo_3a]
[prc_flute_solo_3b]
[prc_flute_solo_3c]
[prc_flute_solo_3d]
[prc_flute_solo_4]
[prc_flute_solo_4a]
[prc_flute_solo_4b]
[prc_flute_solo_4c]
[prc_flute_solo_4d]
[prc_noise_solo]
[prc_noise_solo_a]
[prc_noise_solo_b]
[prc_noise_solo_c]
[prc_noise_solo_d]
[prc_noise_solo_1]
[prc_noise_solo_1a]
[prc_noise_solo_1b]
[prc_noise_solo_1c]
[prc_noise_solo_1d]
[prc_noise_solo_2]
[prc_noise_solo_2a]
[prc_noise_solo_2b]
[prc_noise_solo_2c]
[prc_noise_solo_2d]
[prc_noise_solo_3]
[prc_noise_solo_3a]
[prc_noise_solo_3b]
[prc_noise_solo_3c]
[prc_noise_solo_3d]
[prc_noise_solo_4]
[prc_noise_solo_4a]
[prc_noise_solo_4b]
[prc_noise_solo_4c]
[prc_noise_solo_4d]
[prc_dj_solo]
[prc_dj_solo_a]
[prc_dj_solo_b]
[prc_dj_solo_c]
[prc_dj_solo_d]
[prc_dj_solo_1]
[prc_dj_solo_1a]
[prc_dj_solo_1b]
[prc_dj_solo_1c]
[prc_dj_solo_1d]
[prc_dj_solo_2]
[prc_dj_solo_2a]
[prc_dj_solo_2b]
[prc_dj_solo_2c]
[prc_dj_solo_2d]
[prc_dj_solo_3]
[prc_dj_solo_3a]
[prc_dj_solo_3b]
[prc_dj_solo_3c]
[prc_dj_solo_3d]
[prc_dj_solo_4]
[prc_dj_solo_4a]
[prc_dj_solo_4b]
[prc_dj_solo_4c]
[prc_dj_solo_4d]
[prc_slow_part]
[prc_slow_part_a]
[prc_slow_part_b]
[prc_slow_part_c]
[prc_slow_part_d]
[prc_slow_part_1]
[prc_slow_part_1a]
[prc_slow_part_1b]
[prc_slow_part_1c]
[prc_slow_part_1d]
[prc_slow_part_2]
[prc_slow_part_2a]
[prc_slow_part_2b]
[prc_slow_part_2c]
[prc_slow_part_2d]
[prc_slow_part_3]
[prc_slow_part_3a]
[prc_slow_part_3b]
[prc_slow_part_3c]
[prc_slow_part_3d]
[prc_slow_part_4]
[prc_slow_part_4a]
[prc_slow_part_4b]
[prc_slow_part_4c]
[prc_slow_part_4d]
[prc_fast_part]
[prc_fast_part_a]
[prc_fast_part_b]
[prc_fast_part_c]
[prc_fast_part_d]
[prc_fast_part_1]
[prc_fast_part_1a]
[prc_fast_part_1b]
[prc_fast_part_1c]
[prc_fast_part_1d]
[prc_fast_part_2]
[prc_fast_part_2a]
[prc_fast_part_2b]
[prc_fast_part_2c]
[prc_fast_part_2d]
[prc_fast_part_3]
[prc_fast_part_3a]
[prc_fast_part_3b]
[prc_fast_part_3c]
[prc_fast_part_3d]
[prc_fast_part_4]
[prc_fast_part_4a]
[prc_fast_part_4b]
[prc_fast_part_4c]
[prc_fast_part_4d]
[prc_quiet_part]
[prc_quiet_part_a]
[prc_quiet_part_b]
[prc_quiet_part_c]
[prc_quiet_part_d]
[prc_quiet_part_1]
[prc_quiet_part_1a]
[prc_quiet_part_1b]
[prc_quiet_part_1c]
[prc_quiet_part_1d]
[prc_quiet_part_2]
[prc_quiet_part_2a]
[prc_quiet_part_2b]
[prc_quiet_part_2c]
[prc_quiet_part_2d]
[prc_quiet_part_3]
[prc_quiet_part_3a]
[prc_quiet_part_3b]
[prc_quiet_part_3c]
[prc_quiet_part_3d]
[prc_quiet_part_4]
[prc_quiet_part_4a]
[prc_quiet_part_4b]
[prc_quiet_part_4c]
[prc_quiet_part_4d]
[prc_loud_part]
[prc_loud_part_a]
[prc_loud_part_b]
[prc_loud_part_c]
[prc_loud_part_d]
[prc_loud_part_1]
[prc_loud_part_1a]
[prc_loud_part_1b]
[prc_loud_part_1c]
[prc_loud_part_1d]
[prc_loud_part_2]
[prc_loud_part_2a]
[prc_loud_part_2b]
[prc_loud_part_2c]
[prc_loud_part_2d]
[prc_loud_part_3]
[prc_loud_part_3a]
[prc_loud_part_3b]
[prc_loud_part_3c]
[prc_loud_part_3d]
[prc_loud_part_4]
[prc_loud_part_4a]
[prc_loud_part_4b]
[prc_loud_part_4c]
[prc_loud_part_4d]
[prc_heavy_part]
[prc_heavy_part_a]
[prc_heavy_part_b]
[prc_heavy_part_c]
[prc_heavy_part_d]
[prc_heavy_part_1]
[prc_heavy_part_1a]
[prc_heavy_part_1b]
[prc_heavy_part_1c]
[prc_heavy_part_1d]
[prc_heavy_part_2]
[prc_heavy_part_2a]
[prc_heavy_part_2b]
[prc_heavy_part_2c]
[prc_heavy_part_2d]
[prc_heavy_part_3]
[prc_heavy_part_3a]
[prc_heavy_part_3b]
[prc_heavy_part_3c]
[prc_heavy_part_3d]
[prc_heavy_part_4]
[prc_heavy_part_4a]
[prc_heavy_part_4b]
[prc_heavy_part_4c]
[prc_heavy_part_4d]
[prc_spacey]
[prc_spacey_part_a]
[prc_spacey_part_b]
[prc_spacey_part_c]
[prc_spacey_part_d]
[prc_spacey_part_1]
[prc_spacey_part_1a]
[prc_spacey_part_1b]
[prc_spacey_part_1c]
[prc_spacey_part_1d]
[prc_spacey_part_2]
[prc_spacey_part_2a]
[prc_spacey_part_2b]
[prc_spacey_part_2c]
[prc_spacey_part_2d]
[prc_spacey_part_3]
[prc_spacey_part_3a]
[prc_spacey_part_3b]
[prc_spacey_part_3c]
[prc_spacey_part_3d]
[prc_spacey_part_4]
[prc_spacey_part_4a]
[prc_spacey_part_4b]
[prc_spacey_part_4c]
[prc_spacey_part_4d]
[prc_trippy_part]
[prc_trippy_part_a]
[prc_trippy_part_b]
[prc_trippy_part_c]
[prc_trippy_part_d]
[prc_trippy_part_1]
[prc_trippy_part_1a]
[prc_trippy_part_1b]
[prc_trippy_part_1c]
[prc_trippy_part_1d]
[prc_trippy_part_2]
[prc_trippy_part_2a]
[prc_trippy_part_2b]
[prc_trippy_part_2c]
[prc_trippy_part_2d]
[prc_trippy_part_3]
[prc_trippy_part_3a]
[prc_trippy_part_3b]
[prc_trippy_part_3c]
[prc_trippy_part_3d]
[prc_trippy_part_4]
[prc_trippy_part_4a]
[prc_trippy_part_4b]
[prc_trippy_part_4c]
[prc_trippy_part_4d]
[prc_break]
[prc_break_a]
[prc_break_b]
[prc_break_c]
[prc_break_d]
[prc_break_1]
[prc_break_1a]
[prc_break_1b]
[prc_break_1c]
[prc_break_1d]
[prc_break_2]
[prc_break_2a]
[prc_break_2b]
[prc_break_2c]
[prc_break_2d]
[prc_break_3]
[prc_break_3a]
[prc_break_3b]
[prc_break_3c]
[prc_break_3d]
[prc_break_4]
[prc_break_4a]
[prc_break_4b]
[prc_break_4c]
[prc_break_4d]
[prc_breakdown]
[prc_breakdown_a]
[prc_breakdown_b]
[prc_breakdown_c]
[prc_breakdown_d]
[prc_breakdown_1]
[prc_breakdown_1a]
[prc_breakdown_1b]
[prc_breakdown_1c]
[prc_breakdown_1d]
[prc_breakdown_2]
[prc_breakdown_2a]
[prc_breakdown_2b]
[prc_breakdown_2c]
[prc_breakdown_2d]
[prc_breakdown_3]
[prc_breakdown_3a]
[prc_breakdown_3b]
[prc_breakdown_3c]
[prc_breakdown_3d]
[prc_breakdown_4]
[prc_breakdown_4a]
[prc_breakdown_4b]
[prc_breakdown_4c]
[prc_breakdown_4d]
[prc_gtr_break]
[prc_gtr_break_a]
[prc_gtr_break_b]
[prc_gtr_break_c]
[prc_gtr_break_d]
[prc_gtr_break_1]
[prc_gtr_break_1a]
[prc_gtr_break_1b]
[prc_gtr_break_1c]
[prc_gtr_break_1d]
[prc_gtr_break_2]
[prc_gtr_break_2a]
[prc_gtr_break_2b]
[prc_gtr_break_2c]
[prc_gtr_break_2d]
[prc_gtr_break_3]
[prc_gtr_break_3a]
[prc_gtr_break_3b]
[prc_gtr_break_3c]
[prc_gtr_break_3d]
[prc_gtr_break_4]
[prc_gtr_break_4a]
[prc_gtr_break_4b]
[prc_gtr_break_4c]
[prc_gtr_break_4d]
[prc_bass_break]
[prc_bass_break_a]
[prc_bass_break_b]
[prc_bass_break_c]
[prc_bass_break_d]
[prc_bass_break_1]
[prc_bass_break_1a]
[prc_bass_break_1b]
[prc_bass_break_1c]
[prc_bass_break_1d]
[prc_bass_break_2]
[prc_bass_break_2a]
[prc_bass_break_2b]
[prc_bass_break_2c]
[prc_bass_break_2d]
[prc_bass_break_3]
[prc_bass_break_3a]
[prc_bass_break_3b]
[prc_bass_break_3c]
[prc_bass_break_3d]
[prc_bass_break_4]
[prc_bass_break_4a]
[prc_bass_break_4b]
[prc_bass_break_4c]
[prc_bass_break_4d]
[prc_drum_break]
[prc_drum_break_a]
[prc_drum_break_b]
[prc_drum_break_c]
[prc_drum_break_d]
[prc_drum_break_1]
[prc_drum_break_1a]
[prc_drum_break_1b]
[prc_drum_break_1c]
[prc_drum_break_1d]
[prc_drum_break_2]
[prc_drum_break_2a]
[prc_drum_break_2b]
[prc_drum_break_2c]
[prc_drum_break_2d]
[prc_drum_break_3]
[prc_drum_break_3a]
[prc_drum_break_3b]
[prc_drum_break_3c]
[prc_drum_break_3d]
[prc_drum_break_4]
[prc_drum_break_4a]
[prc_drum_break_4b]
[prc_drum_break_4c]
[prc_drum_break_4d]
[prc_organ_break]
[prc_organ_break_a]
[prc_organ_break_b]
[prc_organ_break_c]
[prc_organ_break_d]
[prc_organ_break_1]
[prc_organ_break_1a]
[prc_organ_break_1b]
[prc_organ_break_1c]
[prc_organ_break_1d]
[prc_organ_break_2]
[prc_organ_break_2a]
[prc_organ_break_2b]
[prc_organ_break_2c]
[prc_organ_break_2d]
[prc_organ_break_3]
[prc_organ_break_3a]
[prc_organ_break_3b]
[prc_organ_break_3c]
[prc_organ_break_3d]
[prc_organ_break_4]
[prc_organ_break_4a]
[prc_organ_break_4b]
[prc_organ_break_4c]
[prc_organ_break_4d]
[prc_synth_break]
[prc_synth_break_a]
[prc_synth_break_b]
[prc_synth_break_c]
[prc_synth_break_d]
[prc_synth_break_1]
[prc_synth_break_1a]
[prc_synth_break_1b]
[prc_synth_break_1c]
[prc_synth_break_1d]
[prc_synth_break_2]
[prc_synth_break_2a]
[prc_synth_break_2b]
[prc_synth_break_2c]
[prc_synth_break_2d]
[prc_synth_break_3]
[prc_synth_break_3a]
[prc_synth_break_3b]
[prc_synth_break_3c]
[prc_synth_break_3d]
[prc_synth_break_4]
[prc_synth_break_4a]
[prc_synth_break_4b]
[prc_synth_break_4c]
[prc_synth_break_4d]
[prc_piano_break]
[prc_piano_break_a]
[prc_piano_break_b]
[prc_piano_break_c]
[prc_piano_break_d]
[prc_piano_break_1]
[prc_piano_break_1a]
[prc_piano_break_1b]
[prc_piano_break_1c]
[prc_piano_break_1d]
[prc_piano_break_2]
[prc_piano_break_2a]
[prc_piano_break_2b]
[prc_piano_break_2c]
[prc_piano_break_2d]
[prc_piano_break_3]
[prc_piano_break_3a]
[prc_piano_break_3b]
[prc_piano_break_3c]
[prc_piano_break_3d]
[prc_piano_break_4]
[prc_piano_break_4a]
[prc_piano_break_4b]
[prc_piano_break_4c]
[prc_piano_break_4d]
[prc_keyboard_break]
[prc_keyboard_break_a]
[prc_keyboard_break_b]
[prc_keyboard_break_c]
[prc_keyboard_break_d]
[prc_keyboard_break_1]
[prc_keyboard_break_1a]
[prc_keyboard_break_1b]
[prc_keyboard_break_1c]
[prc_keyboard_break_1d]
[prc_keyboard_break_2]
[prc_keyboard_break_2a]
[prc_keyboard_break_2b]
[prc_keyboard_break_2c]
[prc_keyboard_break_2d]
[prc_keyboard_break_3]
[prc_keyboard_break_3a]
[prc_keyboard_break_3b]
[prc_keyboard_break_3c]
[prc_keyboard_break_3d]
[prc_keyboard_break_4]
[prc_keyboard_break_4a]
[prc_keyboard_break_4b]
[prc_keyboard_break_4c]
[prc_keyboard_break_4d]
[prc_horn_break]
[prc_sctrach_break]
[prc_perc_break]
[prc_dj_break]
[prc_interlude]
[prc_interlude_a]
[prc_interlude_b]
[prc_interlude_c]
[prc_interlude_d]
[prc_interlude_1]
[prc_interlude_1a]
[prc_interlude_1b]
[prc_interlude_1c]
[prc_interlude_1d]
[prc_interlude_2]
[prc_interlude_2a]
[prc_interlude_2b]
[prc_interlude_2c]
[prc_interlude_2d]
[prc_interlude_3]
[prc_interlude_3a]
[prc_interlude_3b]
[prc_interlude_3c]
[prc_interlude_3d]
[prc_interlude_4]
[prc_interlude_4a]
[prc_interlude_4b]
[prc_interlude_4c]
[prc_interlude_4d]
[prc_soundscape]
[prc_soundscape_a]
[prc_soundscape_b]
[prc_soundscape_c]
[prc_soundscape_d]
[prc_soundscape_1]
[prc_soundscape_1a]
[prc_soundscape_1b]
[prc_soundscape_1c]
[prc_soundscape_1d]
[prc_soundscape_2]
[prc_soundscape_2a]
[prc_soundscape_2b]
[prc_soundscape_2c]
[prc_soundscape_2d]
[prc_soundscape_3]
[prc_soundscape_3a]
[prc_soundscape_3b]
[prc_soundscape_3c]
[prc_soundscape_3d]
[prc_soundscape_4]
[prc_soundscape_4a]
[prc_soundscape_4b]
[prc_soundscape_4c]
[prc_soundscape_4d]
[prc_jam]
[prc_jam_a]
[prc_jam_b]
[prc_jam_c]
[prc_jam_d]
[prc_jam_1]
[prc_jam_1a]
[prc_jam_1b]
[prc_jam_1c]
[prc_jam_1d]
[prc_jam_2]
[prc_jam_2a]
[prc_jam_2b]
[prc_jam_2c]
[prc_jam_2d]
[prc_jam_3]
[prc_jam_3a]
[prc_jam_3b]
[prc_jam_3c]
[prc_jam_3d]
[prc_jam_4]
[prc_jam_4a]
[prc_jam_4b]
[prc_jam_4c]
[prc_jam_4d]
[prc_space_jam]
[prc_space_jam_a]
[prc_space_jam_b]
[prc_space_jam_c]
[prc_space_jam_d]
[prc_space_jam_1]
[prc_space_jam_1a]
[prc_space_jam_1b]
[prc_space_jam_1c]
[prc_space_jam_1d]
[prc_space_jam_2]
[prc_space_jam_2a]
[prc_space_jam_2b]
[prc_space_jam_2c]
[prc_space_jam_2d]
[prc_space_jam_3]
[prc_space_jam_3a]
[prc_space_jam_3b]
[prc_space_jam_3c]
[prc_space_jam_3d]
[prc_space_jam_4]
[prc_space_jam_4a]
[prc_space_jam_4b]
[prc_space_jam_4c]
[prc_space_jam_4d]
[prc_vamp]
[prc_vamp_a]
[prc_vamp_b]
[prc_vamp_c]
[prc_vamp_d]
[prc_vamp_1]
[prc_vamp_1a]
[prc_vamp_1b]
[prc_vamp_1c]
[prc_vamp_1d]
[prc_vamp_2]
[prc_vamp_2a]
[prc_vamp_2b]
[prc_vamp_2c]
[prc_vamp_2d]
[prc_vamp_3]
[prc_vamp_3a]
[prc_vamp_3b]
[prc_vamp_3c]
[prc_vamp_3d]
[prc_vamp_4]
[prc_vamp_4a]
[prc_vamp_4b]
[prc_vamp_4c]
[prc_vamp_4d]
[prc_build_up]
[prc_build_up_a]
[prc_build_up_b]
[prc_build_up_c]
[prc_build_up_d]
[prc_build_up_1]
[prc_build_up_1a]
[prc_build_up_1b]
[prc_build_up_1c]
[prc_build_up_1d]
[prc_build_up_2]
[prc_build_up_2a]
[prc_build_up_2b]
[prc_build_up_2c]
[prc_build_up_2d]
[prc_build_up_3]
[prc_build_up_3a]
[prc_build_up_3b]
[prc_build_up_3c]
[prc_build_up_3d]
[prc_build_up_4]
[prc_build_up_4a]
[prc_build_up_4b]
[prc_build_up_4c]
[prc_build_up_4d]
[prc_speedup]
[prc_speed_up_a]
[prc_speed_up_b]
[prc_speed_up_c]
[prc_speed_up_d]
[prc_speed_up_1]
[prc_speed_up_1a]
[prc_speed_up_1b]
[prc_speed_up_1c]
[prc_speed_up_1d]
[prc_speed_up_2]
[prc_speed_up_2a]
[prc_speed_up_2b]
[prc_speed_up_2c]
[prc_speed_up_2d]
[prc_speed_up_3]
[prc_speed_up_3a]
[prc_speed_up_3b]
[prc_speed_up_3c]
[prc_speed_up_3d]
[prc_speed_up_4]
[prc_speed_up_4a]
[prc_speed_up_4b]
[prc_speed_up_4c]
[prc_speed_up_4d]
[prc_tension]
[prc_tension_a]
[prc_tension_b]
[prc_tension_c]
[prc_tension_d]
[prc_tension_1]
[prc_tension_1a]
[prc_tension_1b]
[prc_tension_1c]
[prc_tension_1d]
[prc_tension_2]
[prc_tension_2a]
[prc_tension_2b]
[prc_tension_2c]
[prc_tension_2d]
[prc_tension_3]
[prc_tension_3a]
[prc_tension_3b]
[prc_tension_3c]
[prc_tension_3d]
[prc_tension_4]
[prc_tension_4a]
[prc_tension_4b]
[prc_tension_4c]
[prc_tension_4d]
[prc_release]
[prc_release_a]
[prc_release_b]
[prc_release_c]
[prc_release_d]
[prc_release_1]
[prc_release_1a]
[prc_release_1b]
[prc_release_1c]
[prc_release_1d]
[prc_release_2]
[prc_release_2a]
[prc_release_2b]
[prc_release_2c]
[prc_release_2d]
[prc_release_3]
[prc_release_3a]
[prc_release_3b]
[prc_release_3c]
[prc_release_3d]
[prc_release_4]
[prc_release_4a]
[prc_release_4b]
[prc_release_4c]
[prc_release_4d]
[prc_crescendo]
[prc_crescendo_a]
[prc_crescendo_b]
[prc_crescendo_c]
[prc_crescendo_d]
[prc_crescendo_1]
[prc_crescendo_1a]
[prc_crescendo_1b]
[prc_crescendo_1c]
[prc_crescendo_1d]
[prc_crescendo_2]
[prc_crescendo_2a]
[prc_crescendo_2b]
[prc_crescendo_2c]
[prc_crescendo_2d]
[prc_crescendo_3]
[prc_crescendo_3a]
[prc_crescendo_3b]
[prc_crescendo_3c]
[prc_crescendo_3d]
[prc_crescendo_4]
[prc_crescendo_4a]
[prc_crescendo_4b]
[prc_crescendo_4c]
[prc_crescendo_4d]
[prc_melody]
[prc_melody_a]
[prc_melody_b]
[prc_melody_c]
[prc_melody_d]
[prc_melody_1]
[prc_melody_1a]
[prc_melody_1b]
[prc_melody_1c]
[prc_melody_1d]
[prc_melody_2]
[prc_melody_2a]
[prc_melody_2b]
[prc_melody_2c]
[prc_melody_2d]
[prc_melody_3]
[prc_melody_3a]
[prc_melody_3b]
[prc_melody_3c]
[prc_melody_3d]
[prc_melody_4]
[prc_melody_4a]
[prc_melody_4b]
[prc_melody_4c]
[prc_melody_4d]
[prc_lo_melody]
[prc_lo_melody_a]
[prc_lo_melody_b]
[prc_lo_melody_c]
[prc_lo_melody_d]
[prc_lo_melody_1]
[prc_lo_melody_1a]
[prc_lo_melody_1b]
[prc_lo_melody_1c]
[prc_lo_melody_1d]
[prc_lo_melody_2]
[prc_lo_melody_2a]
[prc_lo_melody_2b]
[prc_lo_melody_2c]
[prc_lo_melody_2d]
[prc_lo_melody_3]
[prc_lo_melody_3a]
[prc_lo_melody_3b]
[prc_lo_melody_3c]
[prc_lo_melody_3d]
[prc_lo_melody_4]
[prc_lo_melody_4a]
[prc_lo_melody_4b]
[prc_lo_melody_4c]
[prc_lo_melody_4d]
[prc_hi_melody]
[prc_hi_melody_a]
[prc_hi_melody_b]
[prc_hi_melody_c]
[prc_hi_melody_d]
[prc_hi_melody_1]
[prc_hi_melody_1a]
[prc_hi_melody_1b]
[prc_hi_melody_1c]
[prc_hi_melody_1d]
[prc_hi_melody_2]
[prc_hi_melody_2a]
[prc_hi_melody_2b]
[prc_hi_melody_2c]
[prc_hi_melody_2d]
[prc_hi_melody_3]
[prc_hi_melody_3a]
[prc_hi_melody_3b]
[prc_hi_melody_3c]
[prc_hi_melody_3d]
[prc_hi_melody_4]
[prc_hi_melody_4a]
[prc_hi_melody_4b]
[prc_hi_melody_4c]
[prc_hi_melody_4d]
[prc_main_riff]
[prc_main_riff_a]
[prc_main_riff_b]
[prc_main_riff_c]
[prc_main_riff_d]
[prc_main_riff_e]
[prc_main_riff_f]
[prc_main_riff_1]
[prc_main_riff_1a]
[prc_main_riff_1b]
[prc_main_riff_1c]
[prc_main_riff_1d]
[prc_main_riff_1e]
[prc_main_riff_1f]
[prc_main_riff_2]
[prc_main_riff_2a]
[prc_main_riff_2b]
[prc_main_riff_2c]
[prc_main_riff_2d]
[prc_main_riff_2e]
[prc_main_riff_2f]
[prc_main_riff_3]
[prc_main_riff_3a]
[prc_main_riff_3b]
[prc_main_riff_3c]
[prc_main_riff_3d]
[prc_main_riff_3e]
[prc_main_riff_3f]
[prc_main_riff_4]
[prc_main_riff_4a]
[prc_main_riff_4b]
[prc_main_riff_4c]
[prc_main_riff_4d]
[prc_main_riff_5]
[prc_main_riff_5a]
[prc_main_riff_5b]
[prc_main_riff_5c]
[prc_main_riff_5d]
[prc_main_riff_6]
[prc_main_riff_6a]
[prc_main_riff_6b]
[prc_main_riff_6c]
[prc_main_riff_6d]
[prc_main_riff_7]
[prc_main_riff_7a]
[prc_main_riff_7b]
[prc_main_riff_7c]
[prc_main_riff_7d]
[prc_main_riff_8]
[prc_main_riff_8a]
[prc_main_riff_8b]
[prc_main_riff_8c]
[prc_main_riff_8d]
[prc_main_riff_9]
[prc_main_riff_9a]
[prc_main_riff_9b]
[prc_main_riff_9c]
[prc_main_riff_9d]
[prc_verse_riff]
[prc_verse_riff_a]
[prc_verse_riff_b]
[prc_verse_riff_c]
[prc_verse_riff_d]
[prc_verse_riff_1]
[prc_verse_riff_1a]
[prc_verse_riff_1b]
[prc_verse_riff_1c]
[prc_verse_riff_1d]
[prc_verse_riff_2]
[prc_verse_riff_2a]
[prc_verse_riff_2b]
[prc_verse_riff_2c]
[prc_verse_riff_2d]
[prc_verse_riff_3]
[prc_verse_riff_3a]
[prc_verse_riff_3b]
[prc_verse_riff_3c]
[prc_verse_riff_3d]
[prc_verse_riff_4]
[prc_verse_riff_4a]
[prc_verse_riff_4b]
[prc_verse_riff_4c]
[prc_verse_riff_4d]
[prc_chorus_riff]
[prc_chorus_riff_a]
[prc_chorus_riff_b]
[prc_chorus_riff_c]
[prc_chorus_riff_d]
[prc_chorus_riff_1]
[prc_chorus_riff_1a]
[prc_chorus_riff_1b]
[prc_chorus_riff_1c]
[prc_chorus_riff_1d]
[prc_chorus_riff_2]
[prc_chorus_riff_2a]
[prc_chorus_riff_2b]
[prc_chorus_riff_2c]
[prc_chorus_riff_2d]
[prc_chorus_riff_3]
[prc_chorus_riff_3a]
[prc_chorus_riff_3b]
[prc_chorus_riff_3c]
[prc_chorus_riff_3d]
[prc_chorus_riff_4]
[prc_chorus_riff_4a]
[prc_chorus_riff_4b]
[prc_chorus_riff_4c]
[prc_chorus_riff_4d]
[prc_gtr_riff]
[prc_gtr_riff_a]
[prc_gtr_riff_b]
[prc_gtr_riff_c]
[prc_gtr_riff_d]
[prc_gtr_riff_1]
[prc_gtr_riff_1a]
[prc_gtr_riff_1b]
[prc_gtr_riff_1c]
[prc_gtr_riff_1d]
[prc_gtr_riff_2]
[prc_gtr_riff_2a]
[prc_gtr_riff_2b]
[prc_gtr_riff_2c]
[prc_gtr_riff_2d]
[prc_gtr_riff_3]
[prc_gtr_riff_3a]
[prc_gtr_riff_3b]
[prc_gtr_riff_3c]
[prc_gtr_riff_3d]
[prc_gtr_riff_4]
[prc_gtr_riff_4a]
[prc_gtr_riff_4b]
[prc_gtr_riff_4c]
[prc_gtr_riff_4d]
[prc_bass_riff]
[prc_bass_riff_a]
[prc_bass_riff_b]
[prc_bass_riff_c]
[prc_bass_riff_d]
[prc_bass_riff_1]
[prc_bass_riff_1a]
[prc_bass_riff_1b]
[prc_bass_riff_1c]
[prc_bass_riff_1d]
[prc_bass_riff_2]
[prc_bass_riff_2a]
[prc_bass_riff_2b]
[prc_bass_riff_2c]
[prc_bass_riff_2d]
[prc_bass_riff_3]
[prc_bass_riff_3a]
[prc_bass_riff_3b]
[prc_bass_riff_3c]
[prc_bass_riff_3d]
[prc_bass_riff_4]
[prc_bass_riff_4a]
[prc_bass_riff_4b]
[prc_bass_riff_4c]
[prc_bass_riff_4d]
[prc_big_riff]
[prc_big_riff_a]
[prc_big_riff_b]
[prc_big_riff_c]
[prc_big_riff_d]
[prc_big_riff_1]
[prc_big_riff_1a]
[prc_big_riff_1b]
[prc_big_riff_1c]
[prc_big_riff_1d]
[prc_big_riff_2]
[prc_big_riff_2a]
[prc_big_riff_2b]
[prc_big_riff_2c]
[prc_big_riff_2d]
[prc_big_riff_3]
[prc_big_riff_3a]
[prc_big_riff_3b]
[prc_big_riff_3c]
[prc_big_riff_3d]
[prc_big_riff_4]
[prc_big_riff_4a]
[prc_big_riff_4b]
[prc_big_riff_4c]
[prc_big_riff_4d]
[prc_bigger_riff]
[prc_bigger_riff_a]
[prc_bigger_riff_b]
[prc_bigger_riff_c]
[prc_bigger_riff_d]
[prc_bigger_riff_1]
[prc_bigger_riff_1a]
[prc_bigger_riff_1b]
[prc_bigger_riff_1c]
[prc_bigger_riff_1d]
[prc_bigger_riff_2]
[prc_bigger_riff_2a]
[prc_bigger_riff_2b]
[prc_bigger_riff_2c]
[prc_bigger_riff_2d]
[prc_bigger_riff_3]
[prc_bigger_riff_3a]
[prc_bigger_riff_3b]
[prc_bigger_riff_3c]
[prc_bigger_riff_3d]
[prc_bigger_riff_4]
[prc_bigger_riff_4a]
[prc_bigger_riff_4b]
[prc_bigger_riff_4c]
[prc_bigger_riff_4d]
[prc_heavy_riff]
[prc_heavy_riff_a]
[prc_heavy_riff_b]
[prc_heavy_riff_c]
[prc_heavy_riff_d]
[prc_heavy_riff_1]
[prc_heavy_riff_1a]
[prc_heavy_riff_1b]
[prc_heavy_riff_1c]
[prc_heavy_riff_1d]
[prc_heavy_riff_2]
[prc_heavy_riff_2a]
[prc_heavy_riff_2b]
[prc_heavy_riff_2c]
[prc_heavy_riff_2d]
[prc_heavy_riff_3]
[prc_heavy_riff_3a]
[prc_heavy_riff_3b]
[prc_heavy_riff_3c]
[prc_heavy_riff_3d]
[prc_heavy_riff_4]
[prc_heavy_riff_4a]
[prc_heavy_riff_4b]
[prc_heavy_riff_4c]
[prc_heavy_riff_4d]
[prc_fast_riff]
[prc_fast_riff_a]
[prc_fast_riff_b]
[prc_fast_riff_c]
[prc_fast_riff_d]
[prc_fast_riff_1]
[prc_fast_riff_1a]
[prc_fast_riff_1b]
[prc_fast_riff_1c]
[prc_fast_riff_1d]
[prc_fast_riff_2]
[prc_fast_riff_2a]
[prc_fast_riff_2b]
[prc_fast_riff_2c]
[prc_fast_riff_2d]
[prc_fast_riff_3]
[prc_fast_riff_3a]
[prc_fast_riff_3b]
[prc_fast_riff_3c]
[prc_fast_riff_3d]
[prc_fast_riff_4]
[prc_fast_riff_4a]
[prc_fast_riff_4b]
[prc_fast_riff_4c]
[prc_fast_riff_4d]
[prc_slow_riff]
[prc_slow_riff_a]
[prc_slow_riff_b]
[prc_slow_riff_c]
[prc_slow_riff_d]
[prc_slow_riff_1]
[prc_slow_riff_1a]
[prc_slow_riff_1b]
[prc_slow_riff_1c]
[prc_slow_riff_1d]
[prc_slow_riff_2]
[prc_slow_riff_2a]
[prc_slow_riff_2b]
[prc_slow_riff_2c]
[prc_slow_riff_2d]
[prc_slow_riff_3]
[prc_slow_riff_3a]
[prc_slow_riff_3b]
[prc_slow_riff_3c]
[prc_slow_riff_3d]
[prc_slow_riff_4]
[prc_slow_riff_4a]
[prc_slow_riff_4b]
[prc_slow_riff_4c]
[prc_slow_riff_4d]
[prc_swing_riff]
[prc_swing_riff_a]
[prc_swing_riff_b]
[prc_swing_riff_c]
[prc_swing_riff_d]
[prc_swing_riff_1]
[prc_swing_riff_1a]
[prc_swing_riff_1b]
[prc_swing_riff_1c]
[prc_swing_riff_1d]
[prc_swing_riff_2]
[prc_swing_riff_2a]
[prc_swing_riff_2b]
[prc_swing_riff_2c]
[prc_swing_riff_2d]
[prc_swing_riff_3]
[prc_swing_riff_3a]
[prc_swing_riff_3b]
[prc_swing_riff_3c]
[prc_swing_riff_3d]
[prc_swing_riff_4]
[prc_swing_riff_4a]
[prc_swing_riff_4b]
[prc_swing_riff_4c]
[prc_swing_riff_4d]
[prc_chunky_riff]
[prc_chunky_riff_a]
[prc_chunky_riff_b]
[prc_chunky_riff_c]
[prc_chunky_riff_d]
[prc_chunky_riff_1]
[prc_chunky_riff_1a]
[prc_chunky_riff_1b]
[prc_chunky_riff_1c]
[prc_chunky_riff_1d]
[prc_chunky_riff_2]
[prc_chunky_riff_2a]
[prc_chunky_riff_2b]
[prc_chunky_riff_2c]
[prc_chunky_riff_2d]
[prc_chunky_riff_3]
[prc_chunky_riff_3a]
[prc_chunky_riff_3b]
[prc_chunky_riff_3c]
[prc_chunky_riff_3d]
[prc_chunky_riff_4]
[prc_chunky_riff_4a]
[prc_chunky_riff_4b]
[prc_chunky_riff_4c]
[prc_chunky_riff_4d]
[prc_odd_riff]
[prc_odd_riff_a]
[prc_odd_riff_b]
[prc_odd_riff_c]
[prc_odd_riff_d]
[prc_odd_riff_1]
[prc_odd_riff_1a]
[prc_odd_riff_1b]
[prc_odd_riff_1c]
[prc_odd_riff_1d]
[prc_odd_riff_2]
[prc_odd_riff_2a]
[prc_odd_riff_2b]
[prc_odd_riff_2c]
[prc_odd_riff_2d]
[prc_odd_riff_3]
[prc_odd_riff_3a]
[prc_odd_riff_3b]
[prc_odd_riff_3c]
[prc_odd_riff_3d]
[prc_odd_riff_4]
[prc_odd_riff_4a]
[prc_odd_riff_4b]
[prc_odd_riff_4c]
[prc_odd_riff_4d]
[prc_hook]
[prc_hook_a]
[prc_hook_b]
[prc_hook_c]
[prc_hook_d]
[prc_hook_1]
[prc_hook_1a]
[prc_hook_1b]
[prc_hook_1c]
[prc_hook_1d]
[prc_hook_2]
[prc_hook_2a]
[prc_hook_2b]
[prc_hook_2c]
[prc_hook_2d]
[prc_hook_3]
[prc_hook_3a]
[prc_hook_3b]
[prc_hook_3c]
[prc_hook_3d]
[prc_hook_4]
[prc_hook_4a]
[prc_hook_4b]
[prc_hook_4c]
[prc_hook_4d]
[prc_drum_roll]
[prc_drum_roll_a]
[prc_drum_roll_b]
[prc_drum_roll_c]
[prc_drum_roll_d]
[prc_drum_roll_1]
[prc_drum_roll_1a]
[prc_drum_roll_1b]
[prc_drum_roll_1c]
[prc_drum_roll_1d]
[prc_drum_roll_2]
[prc_drum_roll_2a]
[prc_drum_roll_2b]
[prc_drum_roll_2c]
[prc_drum_roll_2d]
[prc_drum_roll_3]
[prc_drum_roll_3a]
[prc_drum_roll_3b]
[prc_drum_roll_3c]
[prc_drum_roll_3d]
[prc_drum_roll_4]
[prc_drum_roll_4a]
[prc_drum_roll_4b]
[prc_drum_roll_4c]
[prc_drum_roll_4d]
[prc_gtr_lead]
[prc_gtr_lead_a]
[prc_gtr_lead_b]
[prc_gtr_lead_c]
[prc_gtr_lead_d]
[prc_gtr_lead_1]
[prc_gtr_lead_1a]
[prc_gtr_lead_1b]
[prc_gtr_lead_1c]
[prc_gtr_lead_1d]
[prc_gtr_lead_2]
[prc_gtr_lead_2a]
[prc_gtr_lead_2b]
[prc_gtr_lead_2c]
[prc_gtr_lead_2d]
[prc_gtr_lead_3]
[prc_gtr_lead_3a]
[prc_gtr_lead_3b]
[prc_gtr_lead_3c]
[prc_gtr_lead_3d]
[prc_gtr_lead_4]
[prc_gtr_lead_4a]
[prc_gtr_lead_4b]
[prc_gtr_lead_4c]
[prc_gtr_lead_4d]
[prc_gtr_fill]
[prc_gtr_fill_a]
[prc_gtr_fill_b]
[prc_gtr_fill_c]
[prc_gtr_fill_d]
[prc_gtr_fill_1]
[prc_gtr_fill_1a]
[prc_gtr_fill_1b]
[prc_gtr_fill_1c]
[prc_gtr_fill_1d]
[prc_gtr_fill_2]
[prc_gtr_fill_2a]
[prc_gtr_fill_2b]
[prc_gtr_fill_2c]
[prc_gtr_fill_2d]
[prc_gtr_fill_3]
[prc_gtr_fill_3a]
[prc_gtr_fill_3b]
[prc_gtr_fill_3c]
[prc_gtr_fill_3d]
[prc_gtr_fill_4]
[prc_gtr_fill_4a]
[prc_gtr_fill_4b]
[prc_gtr_fill_4c]
[prc_gtr_fill_4d]
[prc_gtr_hook]
[prc_gtr_hook_a]
[prc_gtr_hook_b]
[prc_gtr_hook_c]
[prc_gtr_hook_d]
[prc_gtr_hook_1]
[prc_gtr_hook_1a]
[prc_gtr_hook_1b]
[prc_gtr_hook_1c]
[prc_gtr_hook_1d]
[prc_gtr_hook_2]
[prc_gtr_hook_2a]
[prc_gtr_hook_2b]
[prc_gtr_hook_2c]
[prc_gtr_hook_2d]
[prc_gtr_hook_3]
[prc_gtr_hook_3a]
[prc_gtr_hook_3b]
[prc_gtr_hook_3c]
[prc_gtr_hook_3d]
[prc_gtr_hook_4]
[prc_gtr_hook_4a]
[prc_gtr_hook_4b]
[prc_gtr_hook_4c]
[prc_gtr_hook_4d]
[prc_gtr_melody]
[prc_gtr_melody_a]
[prc_gtr_melody_b]
[prc_gtr_melody_c]
[prc_gtr_melody_d]
[prc_gtr_melody_1]
[prc_gtr_melody_1a]
[prc_gtr_melody_1b]
[prc_gtr_melody_1c]
[prc_gtr_melody_1d]
[prc_gtr_melody_2]
[prc_gtr_melody_2a]
[prc_gtr_melody_2b]
[prc_gtr_melody_2c]
[prc_gtr_melody_2d]
[prc_gtr_melody_3]
[prc_gtr_melody_3a]
[prc_gtr_melody_3b]
[prc_gtr_melody_3c]
[prc_gtr_melody_3d]
[prc_gtr_melody_4]
[prc_gtr_melody_4a]
[prc_gtr_melody_4b]
[prc_gtr_melody_4c]
[prc_gtr_melody_4d]
[prc_gtr_line]
[prc_gtr_line_a]
[prc_gtr_line_b]
[prc_gtr_line_c]
[prc_gtr_line_d]
[prc_gtr_line_1]
[prc_gtr_line_1a]
[prc_gtr_line_1b]
[prc_gtr_line_1c]
[prc_gtr_line_1d]
[prc_gtr_line_2]
[prc_gtr_line_2a]
[prc_gtr_line_2b]
[prc_gtr_line_2c]
[prc_gtr_line_2d]
[prc_gtr_line_3]
[prc_gtr_line_3a]
[prc_gtr_line_3b]
[prc_gtr_line_3c]
[prc_gtr_line_3d]
[prc_gtr_line_4]
[prc_gtr_line_4a]
[prc_gtr_line_4b]
[prc_gtr_line_4c]
[prc_gtr_line_4d]
[prc_gtr_lick]
[prc_gtr_lick_a]
[prc_gtr_lick_b]
[prc_gtr_lick_c]
[prc_gtr_lick_d]
[prc_gtr_lick_1]
[prc_gtr_lick_1a]
[prc_gtr_lick_1b]
[prc_gtr_lick_1c]
[prc_gtr_lick_1d]
[prc_gtr_lick_2]
[prc_gtr_lick_2a]
[prc_gtr_lick_2b]
[prc_gtr_lick_2c]
[prc_gtr_lick_2d]
[prc_gtr_lick_3]
[prc_gtr_lick_3a]
[prc_gtr_lick_3b]
[prc_gtr_lick_3c]
[prc_gtr_lick_3d]
[prc_gtr_lick_4]
[prc_gtr_lick_4a]
[prc_gtr_lick_4b]
[prc_gtr_lick_4c]
[prc_gtr_lick_4d]
[prc_vocal_break]
[prc_vocal_break_a]
[prc_vocal_break_b]
[prc_vocal_break_c]
[prc_vocal_break_d]
[prc_vocal_break_1]
[prc_vocal_break_1a]
[prc_vocal_break_1b]
[prc_vocal_break_1c]
[prc_vocal_break_1d]
[prc_vocal_break_2]
[prc_vocal_break_2a]
[prc_vocal_break_2b]
[prc_vocal_break_2c]
[prc_vocal_break_2d]
[prc_vocal_break_3]
[prc_vocal_break_3a]
[prc_vocal_break_3b]
[prc_vocal_break_3c]
[prc_vocal_break_3d]
[prc_vocal_break_4]
[prc_vocal_break_4a]
[prc_vocal_break_4b]
[prc_vocal_break_4c]
[prc_vocal_break_4d]
[prc_ah]
[prc_yeah]
[prc_yeah!]
[prc_oohs]
[prc_oohs_a]
[prc_oohs_b]
[prc_oohs_c]
[prc_oohs_d]
[prc_oohs_1]
[prc_oohs_1a]
[prc_oohs_1b]
[prc_oohs_1c]
[prc_oohs_1d]
[prc_oohs_2]
[prc_oohs_2a]
[prc_oohs_2b]
[prc_oohs_2c]
[prc_oohs_2d]
[prc_oohs_3]
[prc_oohs_3a]
[prc_oohs_3b]
[prc_oohs_3c]
[prc_oohs_3d]
[prc_oohs_4]
[prc_oohs_4a]
[prc_oohs_4b]
[prc_oohs_4c]
[prc_oohs_4d]
[prc_prayer]
[prc_prayer_a]
[prc_prayer_b]
[prc_prayer_c]
[prc_prayer_d]
[prc_prayer_1]
[prc_prayer_1a]
[prc_prayer_1b]
[prc_prayer_1c]
[prc_prayer_1d]
[prc_prayer_2]
[prc_prayer_2a]
[prc_prayer_2b]
[prc_prayer_2c]
[prc_prayer_2d]
[prc_prayer_3]
[prc_prayer_3a]
[prc_prayer_3b]
[prc_prayer_3c]
[prc_prayer_3d]
[prc_prayer_4]
[prc_prayer_4a]
[prc_prayer_4b]
[prc_prayer_4c]
[prc_prayer_4d]
[prc_chant]
[prc_chant_a]
[prc_chant_b]
[prc_chant_c]
[prc_chant_d]
[prc_chant_1]
[prc_chant_1a]
[prc_chant_1b]
[prc_chant_1c]
[prc_chant_1d]
[prc_chant_2]
[prc_chant_2a]
[prc_chant_2b]
[prc_chant_2c]
[prc_chant_2d]
[prc_chant_3]
[prc_chant_3a]
[prc_chant_3b]
[prc_chant_3c]
[prc_chant_3d]
[prc_chant_4]
[prc_chant_4a]
[prc_chant_4b]
[prc_chant_4c]
[prc_chant_4d]
[prc_spoken_word]
[prc_spoken_word_a]
[prc_spoken_word_b]
[prc_spoken_word_c]
[prc_spoken_word_d]
[prc_spoken_word_1]
[prc_spoken_word_1a]
[prc_spoken_word_1b]
[prc_spoken_word_1c]
[prc_spoken_word_1d]
[prc_spoken_word_2]
[prc_spoken_word_2a]
[prc_spoken_word_2b]
[prc_spoken_word_2c]
[prc_spoken_word_2d]
[prc_spoken_word_3]
[prc_spoken_word_3a]
[prc_spoken_word_3b]
[prc_spoken_word_3c]
[prc_spoken_word_3d]
[prc_spoken_word_4]
[prc_spoken_word_4a]
[prc_spoken_word_4b]
[prc_spoken_word_4c]
[prc_spoken_word_4d]
[prc_outro]
[prc_outro_a]
[prc_outro_b]
[prc_outro_c]
[prc_outro_d]
[prc_outro_1]
[prc_outro_1a]
[prc_outro_1b]
[prc_outro_1c]
[prc_outro_1d]
[prc_outro_2]
[prc_outro_2a]
[prc_outro_2b]
[prc_outro_2c]
[prc_outro_2d]
[prc_outro_3]
[prc_outro_3a]
[prc_outro_3b]
[prc_outro_3c]
[prc_outro_3d]
[prc_outro_4]
[prc_outro_4a]
[prc_outro_4b]
[prc_outro_4c]
[prc_outro_4d]
[prc_outro_solo]
[prc_outro_solo_a]
[prc_outro_solo_b]
[prc_outro_solo_c]
[prc_outro_solo_d]
[prc_outro_chorus]
[prc_outro_chorus_a]
[prc_outro_chorus_b]
[prc_outro_chorus_c]
[prc_outro_chorus_d]
[prc_ending]
[prc_ending_a]
[prc_ending_b]
[prc_ending_c]
[prc_ending_d]
[prc_bre]
[prc_fade_out]
[prc_fade_out_a]
[prc_fade_out_b]
[prc_fade_out_c]
[prc_fade_out_d]
[prc_a]
[prc_a1]
[prc_a2]
[prc_a3]
[prc_a4]
[prc_a5]
[prc_a6]
[prc_a7]
[prc_a8]
[prc_a9]
[prc_b]
[prc_b1]
[prc_b2]
[prc_b3]
[prc_b4]
[prc_b5]
[prc_b6]
[prc_b7]
[prc_b8]
[prc_b9]
[prc_c]
[prc_c1]
[prc_c2]
[prc_c3]
[prc_c4]
[prc_c5]
[prc_c6]
[prc_c7]
[prc_c8]
[prc_c9]
[prc_d]
[prc_d1]
[prc_d2]
[prc_d3]
[prc_d4]
[prc_d5]
[prc_d6]
[prc_d7]
[prc_d8]
[prc_d9]
[prc_e]
[prc_e1]
[prc_e2]
[prc_e3]
[prc_e4]
[prc_e5]
[prc_e6]
[prc_e7]
[prc_e8]
[prc_e9]
[prc_f]
[prc_f1]
[prc_f2]
[prc_f3]
[prc_f4]
[prc_f5]
[prc_f6]
[prc_f7]
[prc_f8]
[prc_f9]
[prc_g]
[prc_g1]
[prc_g2]
[prc_g3]
[prc_g4]
[prc_g5]
[prc_g6]
[prc_g7]
[prc_g8]
[prc_g9]
[prc_h]
[prc_h1]
[prc_h2]
[prc_h3]
[prc_h4]
[prc_h5]
[prc_h6]
[prc_h7]
[prc_h8]
[prc_h9]
[prc_i]
[prc_i1]
[prc_i2]
[prc_i3]
[prc_i4]
[prc_i5]
[prc_i6]
[prc_i7]
[prc_i8]
[prc_i9]
[prc_j]
[prc_j1]
[prc_j2]
[prc_j3]
[prc_j4]
[prc_j5]
[prc_j6]
[prc_j7]
[prc_j8]
[prc_j9]
[prc_k]
[prc_k1]
[prc_k2]
[prc_k3]
[prc_k4]
[prc_k5]
[prc_k6]
[prc_k7]
[prc_k8]
[prc_k9]
--]] __PRC_ALLOWED_END__ = true

