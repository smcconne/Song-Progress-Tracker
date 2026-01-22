-- fcp_tracker_model.lua
-- Data + logic for the Song Progress Tracker.

local reaper = reaper
local ImGui  = reaper -- for color packing helpers only

-- Public state -----------------------------------------------------------
PROJ            = PROJ            or select(2, reaper.EnumProjects(-1))
REGIONS         = REGIONS         or {}
REG_COL_U32     = REG_COL_U32     or {} -- per region: {header=..., cell=...}
PROGRESS        = PROGRESS        or {Drums={}, Bass={}, Guitar={}, Keys={}, Vocals={H1={},H2={},H3={},V={}}, Venue={Camera={},Lighting={}}}
STATE           = STATE           or {Drums={}, Bass={}, Guitar={}, Keys={}, Vocals={H1={},H2={},H3={},V={}}, Venue={Camera={},Lighting={}}}
SAVED           = SAVED           or {}

-- Overdrive data: per-instrument, per-measure boolean
OVERDRIVE_DATA     = OVERDRIVE_DATA     or { Drums={}, Bass={}, Guitar={}, Keys={} }
OVERDRIVE_NOTES    = OVERDRIVE_NOTES    or { Drums={}, Bass={}, Guitar={}, Keys={} }  -- tracks if playable notes exist
OVERDRIVE_POSITIONS = OVERDRIVE_POSITIONS or { Drums={}, Bass={}, Guitar={}, Keys={} }  -- OV phrase positions within measures
OVERDRIVE_PHRASES  = OVERDRIVE_PHRASES  or { Drums={}, Bass={}, Guitar={}, Keys={} }  -- OV phrases spanning measures {start_m, start_pos, end_m, end_pos}
OVERDRIVE_FILL     = OVERDRIVE_FILL     or { Drums={} }  -- tracks FILL notes (120-124) for drums only
OVERDRIVE_MEASURES = OVERDRIVE_MEASURES or { first=1, last=1 }

TAB_SIG         = TAB_SIG         or {}
TAB_SCROLL_ROW  = TAB_SCROLL_ROW  or {}
last_proj_cc    = last_proj_cc    or reaper.GetProjectStateChangeCount(0)
current_tab     = current_tab     or TABS[1]
last_tab        = last_tab        or current_tab
ACTIVE_DIFF     = ACTIVE_DIFF     or "Expert"

-- Pending FX alignment after project switch (countdown frames)
PENDING_FX_ALIGN_FRAMES = 0

-- Pending screenset load after project switch (delayed to avoid conflicts)
PENDING_SCREENSET_FRAMES = 0
PENDING_SCREENSET_TAB = nil

-- Flag to suppress normal tab switch handling during project switch
PROJECT_SWITCH_MODE = false

-- Vocals sub-mode
VOCALS_MODE       = VOCALS_MODE       or "V"          -- "H1"|"H2"|"H3"|"V"
DIFFS_VOX         = DIFFS_VOX         or {"H1","H2","H3","V"}
last_vocals_mode  = last_vocals_mode  or VOCALS_MODE

-- Pro Keys mode
PRO_KEYS_ACTIVE       = PRO_KEYS_ACTIVE       or false
last_pro_keys_active  = last_pro_keys_active  or false
PROGRESS_PRO_KEYS     = PROGRESS_PRO_KEYS     or {X={}, H={}, M={}, E={}}
STATE_PRO_KEYS        = STATE_PRO_KEYS        or {X={}, H={}, M={}, E={}}
SAVED_PRO_KEYS        = SAVED_PRO_KEYS        or {}

-- Venue sub-mode
VENUE_MODE        = VENUE_MODE        or "Camera"     -- "Camera"|"Lighting"
DIFFS_VENUE       = DIFFS_VENUE       or {"Camera","Lighting"}
last_venue_mode   = last_venue_mode   or VENUE_MODE

-- Utilities --------------------------------------------------------------
local function color_to_u32(native_color, a)
  if native_color == 0 then native_color = reaper.GetThemeColor("col_region", 0) or 0 end
  if (native_color & 0x1000000) ~= 0 then native_color = native_color & 0xFFFFFF end
  local r,g,b = reaper.ColorFromNative(native_color)
  return ImGui.ImGui_ColorConvertDouble4ToU32((r or 0)/255, (g or 0)/255, (b or 0)/255, a or 1)
end

-- Regions ---------------------------------------------------------------
-- Build a mapping from region name to current index
function build_region_name_to_index()
  local map = {}
  for i, reg in ipairs(REGIONS) do
    if reg.name then
      -- Use uppercase key for case-insensitive matching
      map[reg.name:upper()] = i
    end
  end
  return map
 end

-- Get region name by index (for saving)
-- Returns uppercase name for consistent key format
function get_region_name_by_index(ri)
  if REGIONS[ri] and REGIONS[ri].name then
    return REGIONS[ri].name:upper()
  end
  return nil
end

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
      header = color_to_u32(regs[i].color, 0.65),
      cell   = color_to_u32(regs[i].color, 0.25)
    }
  end
  return regs
end

-- MIDI sources ----------------------------------------------------------
function first_midi_take_on_track(tr)
  if not tr then return end
  local n = reaper.CountTrackMediaItems(tr)
  for i = 0, n-1 do
    local it = reaper.GetTrackMediaItem(tr, i)
    local tk = reaper.GetActiveTake(it)
    if tk and reaper.TakeIsMIDI(tk) then return tk end
  end
end

function make_sig_for_take(take)
  if not take then return "nil" end
  local _, note_cnt = reaper.MIDI_CountEvts(take)
  local sum = 0
  for ni = 0, note_cnt-1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(take, ni)
    if ok and pitch>=36 and pitch<=127 then sum = sum + ppq_s + ppq_e + pitch*17 end
  end
  return tostring(note_cnt) .. ":" .. tostring(sum)
end

local function build_progress_for_take_full(take)
  local prog = {Expert={}, Hard={}, Medium={}, Easy={}}
  for _,lab in ipairs(DIFFS) do for i=1,#REGIONS do prog[lab][i] = false end end
  if not take or #REGIONS == 0 then return prog end

  local _, note_cnt = reaper.MIDI_CountEvts(take)
  for ni = 0, note_cnt-1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(take, ni)
    if ok then
      local t_s = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_s)
      local t_e = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_e)

      local hitE = (pitch>=PITCH_RANGE.Expert[1] and pitch<=PITCH_RANGE.Expert[2])
      local hitH = (pitch>=PITCH_RANGE.Hard[1]   and pitch<=PITCH_RANGE.Hard[2])
      local hitM = (pitch>=PITCH_RANGE.Medium[1] and pitch<=PITCH_RANGE.Medium[2])
      local hitL = (pitch>=PITCH_RANGE.Easy[1]   and pitch<=PITCH_RANGE.Easy[2])

      if hitE or hitH or hitM or hitL then
        for ri = 1, #REGIONS do
          local rs, re_ = REGIONS[ri].pos, REGIONS[ri].r_end
          if t_e > rs and t_s < re_ then
            if hitE then prog.Expert[ri] = true end
            if hitH then prog.Hard[ri]   = true end
            if hitM then prog.Medium[ri] = true end
            if hitL then prog.Easy[ri]   = true end
          end
        end
      end
    end
  end
  return prog
end

local function build_progress_for_take_range(take, lo, hi)
  local arr = {}
  for i=1,#REGIONS do arr[i] = false end
  if not take or #REGIONS == 0 then return arr end

  local _, note_cnt = reaper.MIDI_CountEvts(take)
  for ni = 0, note_cnt-1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(take, ni)
    if ok and pitch>=lo and pitch<=hi then
      local t_s = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_s)
      local t_e = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_e)
      for ri = 1, #REGIONS do
        local rs, re_ = REGIONS[ri].pos, REGIONS[ri].r_end
        if t_e > rs and t_s < re_ then arr[ri] = true end
      end
    end
  end
  return arr
end

-- Persistence -----------------------------------------------------------
local function load_from(proj)
  -- Build name-to-index mapping from current regions
  local name_to_idx = build_region_name_to_index()
  
  local i = 0
  while true do
    local ok, key, val = reaper.EnumProjExtState(proj, EXTNAME, i)
    if not ok then break end
    if type(key) == "string" and key:find("|",1,true) then
      -- Check for Pro Keys format: "ProKeys|X|RegionName"
      local pk_diff, pk_name = key:match("^ProKeys|(%w+)|(.+)$")
      if pk_diff and pk_name then
        -- Use uppercase for case-insensitive matching
        local pk_ri = name_to_idx[pk_name:upper()]
        if pk_ri then
          local st = tonumber(val or "")
          if pk_diff and st then
            SAVED_PRO_KEYS[pk_diff] = SAVED_PRO_KEYS[pk_diff] or {}
            SAVED_PRO_KEYS[pk_diff][pk_ri] = st
          end
        end
      else
        -- Standard format: "Tab|Diff|RegionName" (new) or "Tab|Diff|number" (legacy)
        local t, d, region_key = key:match("([^|]+)|([^|]+)|(.+)$")
        if t and d and region_key then
          t  = TAB_CANON[(t:upper())]  or t
          d  = DIFF_CANON[(d:upper())] or d
          local st = tonumber(val or "")
          -- Try to find region index by name first (new format) - use uppercase for case-insensitive matching
          local ri = name_to_idx[region_key:upper()]
          -- Fall back to numeric index (legacy format)
          if not ri then
            ri = tonumber(region_key)
          end
          if t and d and ri and st then
            SAVED[t] = SAVED[t] or {}
            SAVED[t][d] = SAVED[t][d] or {}
            SAVED[t][d][ri] = st
          end
        end
      end
    end
    i = i + 1
  end
end

function load_all_saved_states()
  SAVED = {}
  SAVED_PRO_KEYS = {}
  load_from(0)
end

function save_cell_state(tab,diff,ri,state)
  tab  = TAB_CANON[(tab:upper())]   or tab
  diff = DIFF_CANON[(diff:upper())] or diff
  -- Use region name instead of index for persistence
  local region_name = get_region_name_by_index(ri)
  if not region_name then return end
  local k = ("%s|%s|%s"):format(tab, diff, region_name)
  -- Use 0 (current project) to ensure we save to the active project
  reaper.SetProjExtState(0, EXTNAME, k, tostring(state))
  SAVED[tab] = SAVED[tab] or {}
  SAVED[tab][diff] = SAVED[tab][diff] or {}
  SAVED[tab][diff][ri] = state
end

-- Merge rules / state ---------------------------------------------------
local function row_has_progress(tab, row)
  local diffs = (tab=="Vocals") and DIFFS_VOX or DIFFS
  for _,d in ipairs(diffs) do
    local st = STATE[tab] and STATE[tab][d] and STATE[tab][d][row]
    if st == 1 or st == 2 then return true end
  end
  return false
end

function set_row_empty(tab, row)
  if row_has_progress(tab, row) then return end
  local diffs = (tab=="Vocals") and DIFFS_VOX or DIFFS
  for _,d in ipairs(diffs) do
    STATE[tab][d][row] = 3
    save_cell_state(tab, d, row, 3)
  end
end

function set_row_not_started(tab, row)
  local diffs = (tab=="Vocals") and DIFFS_VOX or DIFFS
  for _,d in ipairs(diffs) do
    STATE[tab][d][row] = 0
    save_cell_state(tab, d, row, 0)
  end
end

function apply_toggle(tab, diff, r)
  -- Handle Pro Keys mode separately
  if tab == "Keys" and PRO_KEYS_ACTIVE then
    -- diff will be "Pro X", "Pro H", etc. - extract the key
    local diff_key = diff:match("Pro (%w)") or diff
    apply_toggle_pro_keys(diff_key, r)
    return
  end
  
  local st = (STATE[tab] and STATE[tab][diff] and STATE[tab][diff][r]) or 0
  local nxt = st
  if st == 1 then
    nxt = 2
  elseif st == 2 then
    nxt = 1
  elseif st == 0 then
    local live = PROGRESS[tab] and PROGRESS[tab][diff] and PROGRESS[tab][diff][r]
    if tab == "Vocals" then
      -- For Vocals: check if ANY of H1/H2/H3/V have notes in this region
      local any_live = false
      for _,d in ipairs(DIFFS_VOX) do
        if PROGRESS.Vocals and PROGRESS.Vocals[d] and PROGRESS.Vocals[d][r] then
          any_live = true
          break
        end
      end
      if not any_live then
        -- None have notes: set all to Empty (linked)
        for _,d in ipairs(DIFFS_VOX) do STATE[tab][d][r] = 3; save_cell_state(tab, d, r, 3) end
      else
        -- Some have notes: only set current cell to Empty if it has no notes
        if not live then
          STATE[tab][diff][r] = 3
          save_cell_state(tab, diff, r, 3)
        end
      end
    elseif tab == "Venue" then
      -- For Venue: only set current cell to Empty if it has no notes
      if not live then
        STATE[tab][diff][r] = 3
        save_cell_state(tab, diff, r, 3)
      end
    else
      -- For instruments: link rows to Empty if no progress and no live notes
      if not row_has_progress(tab, r) and not live then
        for _,d in ipairs(DIFFS) do STATE[tab][d][r] = 3; save_cell_state(tab, d, r, 3) end
      end
    end
    nxt = st
  elseif st == 3 then
    -- For Vocals and Venue: only set current cell to Not Started, not the whole row
    if tab == "Vocals" or tab == "Venue" then
      STATE[tab][diff][r] = 0
      save_cell_state(tab, diff, r, 0)
      nxt = 0
    else
      local diffs = DIFFS
      for _,d in ipairs(diffs) do STATE[tab][d][r] = 0; save_cell_state(tab, d, r, 0) end
      nxt = 0
    end
  end
  local live = PROGRESS[tab] and PROGRESS[tab][diff] and PROGRESS[tab][diff][r] or false
  if (nxt == 1 or nxt == 2) and not live then nxt = 0 end
  if nxt ~= st then
    STATE[tab][diff][r] = nxt
    save_cell_state(tab, diff, r, nxt)
  end
end

function apply_toggle_pro_keys(diff_key, r)
  -- Ensure the table exists
  STATE_PRO_KEYS[diff_key] = STATE_PRO_KEYS[diff_key] or {}
  
  local st = (STATE_PRO_KEYS[diff_key] and STATE_PRO_KEYS[diff_key][r]) or 0
  local nxt = st
  if st == 1 then
    nxt = 2
  elseif st == 2 then
    nxt = 1
  elseif st == 0 then
    local live = PROGRESS_PRO_KEYS[diff_key] and PROGRESS_PRO_KEYS[diff_key][r]
    if not live then
      nxt = 3  -- Empty
    end
  elseif st == 3 then
    nxt = 0  -- Not Started
  end
  local live = PROGRESS_PRO_KEYS[diff_key] and PROGRESS_PRO_KEYS[diff_key][r] or false
  if (nxt == 1 or nxt == 2) and not live then nxt = 0 end
  if nxt ~= st then
    STATE_PRO_KEYS[diff_key][r] = nxt
    save_pro_keys_cell_state(diff_key, r, nxt)
  end
end

function save_pro_keys_cell_state(diff_key, ri, state)
  -- Use region name instead of index for persistence
  local region_name = get_region_name_by_index(ri)
  if not region_name then return end -- Can't save without a valid region name
  local k = ("ProKeys|%s|%s"):format(diff_key, region_name)
  -- Use 0 (current project) to ensure we save to the active project
  reaper.SetProjExtState(0, EXTNAME, k, tostring(state))
  SAVED_PRO_KEYS[diff_key] = SAVED_PRO_KEYS[diff_key] or {}
  SAVED_PRO_KEYS[diff_key][ri] = state
end

local function rebuild_state_for_pro_keys()
  -- Process ALL difficulties, not just the active one, so button colors are correct
  local diff_keys = { "X", "H", "M", "E" }
  for _, diff_key in ipairs(diff_keys) do
    STATE_PRO_KEYS[diff_key] = STATE_PRO_KEYS[diff_key] or {}
    for ri = 1, #REGIONS do
      local live = PROGRESS_PRO_KEYS[diff_key] and PROGRESS_PRO_KEYS[diff_key][ri] or false
      local saved = SAVED_PRO_KEYS[diff_key] and SAVED_PRO_KEYS[diff_key][ri]
      local st
      if saved ~= nil then
        if saved == 3 and live then
          st = 1
          save_pro_keys_cell_state(diff_key, ri, 1)
        elseif saved == 0 then
          st = live and 1 or 0
        else
          st = saved
        end
      else
        st = live and 1 or 0
      end
      STATE_PRO_KEYS[diff_key][ri] = st
    end
  end
end

local function rebuild_state_for_tab(tab)
  if tab == "Vocals" then
    for _,diff in ipairs(DIFFS_VOX) do
      STATE.Vocals[diff] = STATE.Vocals[diff] or {}
      for ri=1,#REGIONS do
        local live  = PROGRESS.Vocals and PROGRESS.Vocals[diff] and PROGRESS.Vocals[diff][ri] or false
        local saved = SAVED.Vocals and SAVED.Vocals[diff] and SAVED.Vocals[diff][ri]
        local st
        if saved ~= nil then
          -- If saved was Empty (3) but notes now exist, transition to In Progress
          if saved == 3 and live then
            st = 1
            save_cell_state("Vocals", diff, ri, 1)
          elseif saved == 0 then
            st = live and 1 or 0
          else
            st = saved
          end
        else
          st = live and 1 or 0
        end
        STATE.Vocals[diff][ri] = st
      end
    end
    return
  end

  if tab == "Venue" then
    for _,diff in ipairs(DIFFS_VENUE) do
      STATE.Venue[diff] = STATE.Venue[diff] or {}
      for ri=1,#REGIONS do
        local live  = PROGRESS.Venue and PROGRESS.Venue[diff] and PROGRESS.Venue[diff][ri] or false
        local saved = SAVED.Venue and SAVED.Venue[diff] and SAVED.Venue[diff][ri]
        local st
        if saved ~= nil then
          -- If saved was Empty (3) but notes now exist, transition to In Progress
          if saved == 3 and live then
            st = 1
            save_cell_state("Venue", diff, ri, 1)
          elseif saved == 0 then
            st = live and 1 or 0
          else
            st = saved
          end
        else
          st = live and 1 or 0
        end
        STATE.Venue[diff][ri] = st
      end
    end
    return
  end

  STATE[tab] = STATE[tab] or {}
  for _,diff in ipairs(DIFFS) do
    STATE[tab][diff] = STATE[tab][diff] or {}
    for ri=1,#REGIONS do
      local live  = PROGRESS[tab] and PROGRESS[tab][diff] and PROGRESS[tab][diff][ri] or false
      local saved = SAVED[tab] and SAVED[tab][diff] and SAVED[tab][diff][ri]
      local st
      if saved ~= nil then
        -- If saved was Empty (3) but notes now exist, transition to In Progress
        if saved == 3 and live then
          st = 1
          save_cell_state(tab, diff, ri, 1)
        elseif saved == 0 then
          st = live and 1 or 0
        else
          st = saved
        end
      else
        st = live and 1 or 0
      end
      STATE[tab][diff][ri] = st
    end
  end
end

-- Build progress for tabs -----------------------------------------------
local function find_track_by_name(want)
  local n = reaper.CountTracks(0)
  for i = 0, n-1 do
    local tr = reaper.GetTrack(0, i)
    local ok, name = reaper.GetTrackName(tr)
    if ok and name == want then return tr end
  end
end

function compute_tab(tab)
  local tr = find_track_by_name(TAB_TRACK[tab])
  local tk = first_midi_take_on_track(tr)
  PROGRESS[tab] = build_progress_for_take_full(tk)
  TAB_SIG[tab]  = make_sig_for_take(tk)
  rebuild_state_for_tab(tab)
end

local function compute_vocals()
  -- Compute ALL vocal modes so button colors are correct
  for _, mode in ipairs(DIFFS_VOX) do
    local trackname = VOCALS_TRACKS[mode]
    local tr = find_track_by_name(trackname)
    local tk = first_midi_take_on_track(tr)
    local lo, hi = VOCALS_PITCH_RANGE[1], VOCALS_PITCH_RANGE[2]
    PROGRESS.Vocals[mode] = build_progress_for_take_range(tk, lo, hi)
  end
  -- Use active mode's take for signature
  local active_tr = find_track_by_name(VOCALS_TRACKS[VOCALS_MODE])
  local active_tk = first_midi_take_on_track(active_tr)
  TAB_SIG.Vocals = make_sig_for_take(active_tk)
  rebuild_state_for_tab("Vocals")
end

local function compute_venue()
  -- Compute ALL venue modes so button colors are correct
  for _, mode in ipairs(DIFFS_VENUE) do
    local trackname = VENUE_TRACKS[mode]
    local tr = find_track_by_name(trackname)
    local tk = first_midi_take_on_track(tr)
    -- Use full pitch range for venue tracks
    PROGRESS.Venue[mode] = build_progress_for_take_range(tk, 0, 127)
  end
  TAB_SIG.Venue = "venue_computed"  -- Simple signature since we compute both
  rebuild_state_for_tab("Venue")
end

-- Pro Keys progress computation
local function compute_pro_keys_difficulty(diff_key)
  local trackname = PRO_KEYS_TRACKS[diff_key]
  local tr = find_track_by_name(trackname)
  local tk = first_midi_take_on_track(tr)
  local lo, hi = PRO_KEYS_PITCH_RANGE[1], PRO_KEYS_PITCH_RANGE[2]
  PROGRESS_PRO_KEYS[diff_key] = build_progress_for_take_range(tk, lo, hi)
end

function compute_pro_keys()
  -- Compute ALL difficulties so button colors are correct
  local diff_keys = { "X", "H", "M", "E" }
  for _, diff_key in ipairs(diff_keys) do
    compute_pro_keys_difficulty(diff_key)
  end
  rebuild_state_for_pro_keys()
end

-- Overdrive measure collection ------------------------------------------

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

-- Cursors and percent ---------------------------------------------------
function cursor_region_index()
  local t = reaper.GetCursorPosition()
  for i = 1, #REGIONS do
    if t >= (REGIONS[i].pos or 0) and t < (REGIONS[i].r_end or 0) then return i end
  end
  return nil
end

function diff_pct(tab, diff)
  local num, den = 0, 0
  
  -- Handle Pro Keys mode
  local row
  if tab == "Keys" and PRO_KEYS_ACTIVE then
    -- diff will be "Pro X", "Pro H", etc. - extract the key
    local diff_key = diff:match("Pro (%w)")
    row = STATE_PRO_KEYS[diff_key]
  else
    row = STATE[tab] and STATE[tab][diff]
  end
  
  if row then
    for r = 1, #REGIONS do
      local st = row[r] or 0
      if st ~= 3 then
        den = den + 3
        if     st == 2 then num = num + 3
        elseif st == 1 then num = num + 1 end
      end
    end
  end
  return (den > 0) and math.floor((num/den)*100) or 0
end

-- Check if all cells for a tab/diff are Empty (state 3)
-- Returns true if all cells are Empty (or no regions exist)
function is_all_empty(tab, diff)
  local row = STATE[tab] and STATE[tab][diff]
  if not row then return true end
  for r = 1, #REGIONS do
    local st = row[r] or 0
    if st ~= 3 then
      return false
    end
  end
  return true
end

-- Weighted overall completion for instrument tabs
-- X=50%, H=25%, M=15%, E=10%
function weighted_tab_pct(tab)
  local weights = { Expert=0.50, Hard=0.25, Medium=0.15, Easy=0.10 }
  local pro_keys_weights = { X=0.50, H=0.25, M=0.15, E=0.10 }
  
  -- For Keys tab with Pro Keys active, use Pro Keys state
  if tab == "Keys" and PRO_KEYS_ACTIVE then
    local total = 0
    for diff_key, weight in pairs(pro_keys_weights) do
      local pct = 0
      local row = STATE_PRO_KEYS[diff_key]
      if row then
        local num, den = 0, 0
        for r = 1, #REGIONS do
          local st = row[r] or 0
          if st ~= 3 then
            den = den + 3
            if     st == 2 then num = num + 3
            elseif st == 1 then num = num + 1 end
          end
        end
        if den > 0 then pct = (num / den) * 100 end
      end
      total = total + (pct * weight)
    end
    return math.floor(total)
  end
  
  -- For standard instrument tabs (Drums, Bass, Guitar, Keys without Pro)
  if tab == "Drums" or tab == "Bass" or tab == "Guitar" or tab == "Keys" then
    local total = 0
    for diff, weight in pairs(weights) do
      local pct = 0
      local row = STATE[tab] and STATE[tab][diff]
      if row then
        local num, den = 0, 0
        for r = 1, #REGIONS do
          local st = row[r] or 0
          if st ~= 3 then
            den = den + 3
            if     st == 2 then num = num + 3
            elseif st == 1 then num = num + 1 end
          end
        end
        if den > 0 then pct = (num / den) * 100 end
      end
      total = total + (pct * weight)
    end
    return math.floor(total)
  end
  
  -- For other tabs (Vocals, Venue, Overdrive), return 0
  return 0
end

-- Overdrive tab completion percentage
-- Factor A (67%): Each instrument contributes 25% of 67% based on furthest-right overdrive placement
-- Factor B (33%): How close to (last measure - 16) the furthest-right drum fill placement is
-- Any placement within the last 16 measures counts as 100% for that factor
function overdrive_completion_pct()
  local first_m = OVERDRIVE_MEASURES.first or 1
  local last_m = OVERDRIVE_MEASURES.last or 1
  
  -- Effective last measure (exclude last 16 measures from requirement)
  local effective_last = math.max(first_m, last_m - 16)
  local range = effective_last - first_m
  if range <= 0 then return 100 end  -- No range to fill
  
  -- Calculate overdrive progress for each instrument (25% each of 67%)
  local total_od_progress = 0
  for _, row in ipairs(OVERDRIVE_ROWS) do
    local data = OVERDRIVE_DATA[row]
    if data then
      -- Check last 16 measures first - any placement there = 100% for this instrument
      local in_final_16 = false
      for m = last_m, effective_last + 1, -1 do
        if data[m] then
          in_final_16 = true
          break
        end
      end
      
      local inst_progress = 0
      if in_final_16 then
        inst_progress = 1
      else
        -- Find furthest-right placement within effective range
        for m = effective_last, first_m, -1 do
          if data[m] then
            inst_progress = (m - first_m) / range
            break
          end
        end
      end
      
      inst_progress = math.min(1, math.max(0, inst_progress))
      total_od_progress = total_od_progress + (inst_progress * 0.25)  -- 25% each
    end
  end
  
  -- Find furthest-right drum fill placement
  -- Check last 16 measures first - any placement there = 100%
  local fill_in_final_16 = false
  local fill_data = OVERDRIVE_FILL["Drums"]
  if fill_data then
    for m = last_m, effective_last + 1, -1 do
      if fill_data[m] then
        fill_in_final_16 = true
        break
      end
    end
  end
  
  local max_fill_measure = 0
  if not fill_in_final_16 and fill_data then
    for m = effective_last, first_m, -1 do
      if fill_data[m] then
        max_fill_measure = m
        break
      end
    end
  end
  
  -- Calculate percentages for each factor
  local fill_progress = fill_in_final_16 and 1 or ((max_fill_measure > 0) and ((max_fill_measure - first_m) / range) or 0)
  
  -- Clamp to 0-1 range, then combine: 67% OD (split 4 ways) + 33% fill
  fill_progress = math.min(1, math.max(0, fill_progress))
  
  local combined = (total_od_progress * 0.67) + (fill_progress * 0.33)
  return math.floor(combined * 100)
end

-- Public entry points ---------------------------------------------------
function Progress_Init(skip_fx_align)
  PROJ = select(2, reaper.EnumProjects(-1))
  REGIONS = collect_regions()
  
  -- Reset state tables for new project
  PROGRESS = {Drums={}, Bass={}, Guitar={}, Keys={}, Vocals={H1={},H2={},H3={},V={}}, Venue={Camera={},Lighting={}}}
  STATE = {Drums={}, Bass={}, Guitar={}, Keys={}, Vocals={H1={},H2={},H3={},V={}}, Venue={Camera={},Lighting={}}}
  PROGRESS_PRO_KEYS = {X={}, H={}, M={}, E={}}
  STATE_PRO_KEYS = {X={}, H={}, M={}, E={}}
  OVERDRIVE_DATA = { Drums={}, Bass={}, Guitar={}, Keys={} }
  OVERDRIVE_NOTES = { Drums={}, Bass={}, Guitar={}, Keys={} }
  OVERDRIVE_NOTE_POSITIONS = { Drums={}, Bass={}, Guitar={}, Keys={} }  -- Note positions within measures (0-1)
  OVERDRIVE_POSITIONS = { Drums={}, Bass={}, Guitar={}, Keys={} }  -- OV phrase positions within measures (0-1)
  OVERDRIVE_PHRASES = { Drums={}, Bass={}, Guitar={}, Keys={} }  -- OV phrases spanning measures
  OVERDRIVE_FILL = { Drums={} }
  OVERDRIVE_MEASURES = { first=1, last=1 }
  TAB_SIG = {}
  
  load_all_saved_states()

  for _,t in ipairs(TABS) do
    if t == "Vocals" then
      compute_vocals()
    elseif t == "Venue" then
      compute_venue()
    elseif t == "Overdrive" then
      collect_overdrive_data()
    else
      compute_tab(t)
    end
  end
  
  -- Also compute Pro Keys if it was active (PRO_KEYS_ACTIVE is restored before this)
  if PRO_KEYS_ACTIVE then
    compute_pro_keys()
  end

  last_proj_cc = reaper.GetProjectStateChangeCount(0)
  last_tab = current_tab
  last_vocals_mode = VOCALS_MODE
  last_venue_mode = VENUE_MODE
  
  -- Note: FX alignment is now scheduled in Progress_Tick after we know the restored tab
end

function Progress_Tick()
  -- Process pending screenset load (for project switches)
  if PENDING_SCREENSET_FRAMES > 0 then
    PENDING_SCREENSET_FRAMES = PENDING_SCREENSET_FRAMES - 1
    if PENDING_SCREENSET_FRAMES == 0 and PENDING_SCREENSET_TAB then
      if PENDING_SCREENSET_TAB == "Vocals" then
        if CMD_SCREENSET_LOAD_VOCALS and CMD_SCREENSET_LOAD_VOCALS > 0 then
          reaper.Main_OnCommand(CMD_SCREENSET_LOAD_VOCALS, 0)
        end
      elseif PENDING_SCREENSET_TAB == "Overdrive" then
        if CMD_SCREENSET_LOAD_OV and CMD_SCREENSET_LOAD_OV > 0 then
          reaper.Main_OnCommand(CMD_SCREENSET_LOAD_OV, 0)
        end
        -- Schedule FX alignment after Overdrive screenset loads
        PENDING_FX_ALIGN_FRAMES = 5
      elseif PENDING_SCREENSET_TAB == "Venue" then
        if CMD_SCREENSET_LOAD_VENUE and CMD_SCREENSET_LOAD_VENUE > 0 then
          reaper.Main_OnCommand(CMD_SCREENSET_LOAD_VENUE, 0)
        end
      else
        if CMD_SCREENSET_LOAD_OTHERS and CMD_SCREENSET_LOAD_OTHERS > 0 then
          reaper.Main_OnCommand(CMD_SCREENSET_LOAD_OTHERS, 0)
        end
      end
      PENDING_SCREENSET_TAB = nil
      -- Clear project switch mode after screenset is loaded
      PROJECT_SWITCH_MODE = false
    end
  end
  
  -- Process pending FX alignment (for project switches)
  if PENDING_FX_ALIGN_FRAMES > 0 then
    PENDING_FX_ALIGN_FRAMES = PENDING_FX_ALIGN_FRAMES - 1
    if PENDING_FX_ALIGN_FRAMES == 0 then
      -- Trigger SET focus which opens FX windows and applies saved layout
      -- Skip for Vocals tab which doesn't use FX windows
      if current_tab ~= "Vocals" then
        reaper.SetExtState(EXT_NS, EXT_FOCUS, "SET", false)
      end
    end
  end
  
  -- Check if the project has changed
  local new_proj = select(2, reaper.EnumProjects(-1))
  if new_proj ~= PROJ then
    -- Set flag to suppress normal tab switch handling
    PROJECT_SWITCH_MODE = true
    
    -- Project changed - reinitialize everything (this updates PROJ to new_proj)
    Progress_Init()
    
    -- Restore tab from NEW project (or reset to first tab if none saved)
    local _, saved_tab = reaper.GetProjExtState(PROJ, EXT_NS, "LAST_TAB")
    reaper.ShowConsoleMsg("Project switch - saved_tab from new project: '" .. tostring(saved_tab) .. "'\n")
    local found_tab = nil
    if saved_tab and saved_tab ~= "" then
      -- Validate saved tab is in TABS list
      for _, t in ipairs(TABS) do
        if t == saved_tab then
          found_tab = saved_tab
          break
        end
      end
    end
    -- Apply found tab, or reset to first tab if no saved tab
    current_tab = found_tab or TABS[1]
    last_tab = current_tab
    -- Force ImGui to actually select this tab (it maintains internal state)
    if force_tab_selection then
      force_tab_selection(current_tab, 3)
    end
    -- Schedule screenset load after a delay to avoid conflicts with tab switching
    PENDING_SCREENSET_TAB = current_tab
    PENDING_SCREENSET_FRAMES = 5
    reaper.ShowConsoleMsg("Applied tab: '" .. tostring(current_tab) .. "'\n")
    return
  end
  
  local cc = reaper.GetProjectStateChangeCount(0)
  local tab_switched = (current_tab ~= last_tab)
  local vox_switched = (VOCALS_MODE ~= last_vocals_mode)
  local venue_switched = (VENUE_MODE ~= last_venue_mode)
  local project_changed = (cc ~= last_proj_cc)

  if tab_switched then
    last_tab = current_tab
    -- Save current tab to project extended state whenever it changes
    reaper.SetProjExtState(PROJ, EXT_NS, "LAST_TAB", current_tab)
  end
  if vox_switched then last_vocals_mode = VOCALS_MODE end
  if venue_switched then last_venue_mode = VENUE_MODE end

  -- If project changed, update ALL tabs so tooltips and button colors are accurate
  if project_changed then
    -- Update all instrument tabs
    for _, t in ipairs({"Drums", "Bass", "Guitar", "Keys"}) do
      local tr = find_track_by_name(TAB_TRACK[t])
      local tk = first_midi_take_on_track(tr)
      local sig = make_sig_for_take(tk)
      if TAB_SIG[t] ~= sig then
        PROGRESS[t] = build_progress_for_take_full(tk)
        TAB_SIG[t] = sig
        rebuild_state_for_tab(t)
      end
    end
    -- Update Vocals
    compute_vocals()
    -- Update Venue
    compute_venue()
    -- Update Overdrive
    collect_overdrive_data()
    -- Update Pro Keys if active
    if PRO_KEYS_ACTIVE then
      compute_pro_keys()
    end
    last_pro_keys_active = PRO_KEYS_ACTIVE
  elseif tab_switched then
    -- Just switching tabs, only update the new tab
    if current_tab == "Vocals" then
      compute_vocals()
    elseif current_tab == "Venue" then
      compute_venue()
    elseif current_tab == "Overdrive" then
      collect_overdrive_data()
    elseif current_tab == "Keys" and PRO_KEYS_ACTIVE then
      compute_pro_keys()
      last_pro_keys_active = PRO_KEYS_ACTIVE
    elseif current_tab ~= "Setup" then
      local tr = find_track_by_name(TAB_TRACK[current_tab])
      local tk = first_midi_take_on_track(tr)
      local sig = make_sig_for_take(tk)
      if TAB_SIG[current_tab] ~= sig then
        PROGRESS[current_tab] = build_progress_for_take_full(tk)
        TAB_SIG[current_tab] = sig
        rebuild_state_for_tab(current_tab)
      end
    end
  else
    -- No project change, no tab switch - just handle mode switches
    if vox_switched and current_tab == "Vocals" then
      compute_vocals()
    elseif venue_switched and current_tab == "Venue" then
      compute_venue()
    elseif PRO_KEYS_ACTIVE ~= last_pro_keys_active then
      last_pro_keys_active = PRO_KEYS_ACTIVE
      if current_tab == "Keys" and PRO_KEYS_ACTIVE then
        compute_pro_keys()
      end
    end
  end

  last_proj_cc = cc
end
