-- fcp_tracker_model.lua
-- Data + logic for the Song Progress Tracker.

local reaper = reaper
local ImGui  = reaper

-- Tree shape keyed by <tab>.<variant>.<mode>; returns a fresh table per call.
local function make_empty_tree()
  local function mode_table(modes)
    local t = {}
    for _, m in ipairs(modes) do t[m] = {} end
    return t
  end
  return {
    Preferences = { regular = {} },
    Setup       = { regular = {} },
    Drums       = { regular = mode_table({"Expert","Hard","Medium","Easy"}) },
    Bass        = { regular = mode_table({"Expert","Hard","Medium","Easy"}) },
    Guitar      = { regular = mode_table({"Expert","Hard","Medium","Easy"}) },
    Keys        = {
      regular = mode_table({"Expert","Hard","Medium","Easy"}),
      pro     = mode_table({"Expert","Hard","Medium","Easy"}),
    },
    Vocals      = { regular = mode_table({"H1","H2","H3","V"}) },
    Venue       = { regular = mode_table({"Camera","Lighting"}) },
    Overdrive   = { regular = {} },
  }
end

-- Public state -----------------------------------------------------------
PROJ            = PROJ            or select(2, reaper.EnumProjects(-1))
REGIONS         = REGIONS         or {}
REG_COL_U32     = REG_COL_U32     or {} -- per region: {header=..., cell=...}
PROGRESS        = PROGRESS        or make_empty_tree()
STATE           = STATE           or make_empty_tree()
SAVED           = SAVED           or {}   -- grows into the nested shape as load_from populates it
REGION_TIME     = REGION_TIME     or {}   -- per-tab per-region seconds spent active

-- Per-region per-difficulty MIDI checksums (built alongside PROGRESS)
PROGRESS_SIG    = PROGRESS_SIG    or make_empty_tree()
-- Checksums captured when a cell is marked Complete (persisted)
COMPLETE_SIG    = COMPLETE_SIG    or {}   -- populated by save_cell_state_v2 when the user marks a cell complete; read by the rebuild to detect MIDI edits since completion

-- Overdrive data: per-instrument, per-measure boolean
OVERDRIVE_DATA     = OVERDRIVE_DATA     or { Drums={}, Bass={}, Guitar={}, Keys={} }
OVERDRIVE_NOTES    = OVERDRIVE_NOTES    or { Drums={}, Bass={}, Guitar={}, Keys={} }  -- tracks if playable notes exist
OVERDRIVE_POSITIONS = OVERDRIVE_POSITIONS or { Drums={}, Bass={}, Guitar={}, Keys={} }  -- OV phrase positions within measures
OVERDRIVE_PHRASES  = OVERDRIVE_PHRASES  or { Drums={}, Bass={}, Guitar={}, Keys={} }  -- OV phrases spanning measures {start_m, start_pos, end_m, end_pos}
OVERDRIVE_FILL     = OVERDRIVE_FILL     or { Drums={} }  -- tracks FILL notes (120-124) for drums only
OVERDRIVE_MEASURES = OVERDRIVE_MEASURES or { first=1, last=1 }

TAB_SIG         = TAB_SIG         or {}
TAB_SCROLL_ROW  = TAB_SCROLL_ROW  or {}
REGION_TIME_LAST_TICK = REGION_TIME_LAST_TICK or nil   -- last time_precise for 1-sec timer
REGION_TIME_LAST_REGION = REGION_TIME_LAST_REGION or nil  -- last active region index
REGION_TIME_LAST_TAB = REGION_TIME_LAST_TAB or nil  -- last active tab
REGION_TIME_LAST_DIFF = REGION_TIME_LAST_DIFF or nil  -- last active difficulty/mode
last_proj_cc    = last_proj_cc    or reaper.GetProjectStateChangeCount(0)
current_tab     = current_tab     or TABS[1]
last_tab        = last_tab        or current_tab
last_mode_key   = last_mode_key   or nil

-- Pending FX alignment after project switch (countdown frames)
PENDING_FX_ALIGN_FRAMES = 0

-- Pending screenset load after project switch (delayed to avoid conflicts)
PENDING_SCREENSET_FRAMES = 0
PENDING_SCREENSET_TAB = nil

-- Flag to suppress normal tab switch handling during project switch
PROJECT_SWITCH_MODE = false

-- Vocals sub-mode
DIFFS_VOX         = DIFFS_VOX         or {"H1","H2","H3","V"}

-- Venue sub-mode
DIFFS_VENUE       = DIFFS_VENUE       or {"Camera","Lighting"}
CAMERA_SUB_MODE   = CAMERA_SUB_MODE   or 1            -- 1=Single, 2=Multi (visible when Camera selected)
CAMERA_DIRECTED   = CAMERA_DIRECTED   or false         -- Toggle: changes which rows Single/Multi show
LIGHTING_SUB_MODE = LIGHTING_SUB_MODE or 1            -- 1=Post, 2=Light, 3=Misc (visible when Lighting selected)

-- Public entry points ---------------------------------------------------
function Progress_Init(skip_fx_align)
  PROJ = select(2, reaper.EnumProjects(-1))
  REGIONS = collect_regions()
  
  -- Reset state tables for new project
  PROGRESS = make_empty_tree()
  STATE = make_empty_tree()
  REGION_TIME = {}
  REGION_TIME_LAST_TICK = nil
  REGION_TIME_LAST_REGION = nil
  REGION_TIME_LAST_TAB = nil
  REGION_TIME_LAST_DIFF = nil
  PROGRESS_SIG = make_empty_tree()
  COMPLETE_SIG = {}
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

  -- Always build the Pro Keys tree at startup so its tooltip shows data.
  if TABS_BY_NAME and TABS_BY_NAME["Keys"] then
    compute_pro_keys()
  end

  last_proj_cc = reaper.GetProjectStateChangeCount(0)
  last_tab = current_tab
  local m_obj = current_tab_obj and current_tab_obj()
  last_mode_key = m_obj and m_obj:current_mode_key()

end

function Progress_Tick()
  -- Check if the project has changed (must be first, before any saves)
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
    -- Re-apply the active difficulty's preview FX/note order for the new tab
    apply_run_set_for_tab(current_tab)
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

  -- Tick region time counter (after project switch check to avoid saving old values to new project)
  region_time_tick()

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

  local cc = reaper.GetProjectStateChangeCount(0)
  local tab_switched = (current_tab ~= last_tab)
  local cur_obj_t = current_tab_obj and current_tab_obj()
  local cur_mode_key = cur_obj_t and cur_obj_t:current_mode_key()
  local mode_switched = (cur_mode_key ~= last_mode_key)
  local project_changed = (cc ~= last_proj_cc)

  if tab_switched then
    last_tab = current_tab
    -- Save current tab to project extended state whenever it changes
    reaper.SetProjExtState(PROJ, EXT_NS, "LAST_TAB", current_tab)
  end
  if mode_switched then last_mode_key = cur_mode_key end

  -- If project changed, update ALL tabs so tooltips and button colors are accurate
  if project_changed then
    -- Update all instrument tabs (the regular variant; pro variant handled below)
    for _, t in ipairs({"Drums", "Bass", "Guitar", "Keys"}) do
      local tr = find_track_by_name(TAB_TRACK[t])
      local tk = first_midi_take_on_track(tr)
      local sig = make_sig_for_take(tk)
      if TAB_SIG[t] ~= sig then
        local prog, sigs = build_progress_for_take_full(tk)
        PROGRESS[t] = PROGRESS[t] or {}
        PROGRESS[t]["regular"] = prog
        PROGRESS_SIG[t] = PROGRESS_SIG[t] or {}
        PROGRESS_SIG[t]["regular"] = sigs
        TAB_SIG[t] = sig
        rebuild_state_for_tab(t, "regular")
      end
    end
    -- Update Vocals
    compute_vocals()
    -- Update Venue
    compute_venue()
    -- Update Overdrive
    collect_overdrive_data()
    -- Update Pro Keys when the active Keys variant is pro
    local obj_pc = current_tab_obj and current_tab_obj()
    if obj_pc and obj_pc.name == "Keys" and obj_pc:is_pro() then
      compute_pro_keys()
    end
  elseif tab_switched then
    -- Just switching tabs, only update the new tab
    local obj_ts = current_tab_obj and current_tab_obj()
    if current_tab == "Vocals" then
      compute_vocals()
    elseif current_tab == "Venue" then
      compute_venue()
    elseif current_tab == "Overdrive" then
      collect_overdrive_data()
    elseif current_tab == "Keys" and obj_ts and obj_ts:is_pro() then
      compute_pro_keys()
    elseif current_tab ~= "Setup" and current_tab ~= "Preferences" then
      local tr = find_track_by_name(TAB_TRACK[current_tab])
      local tk = first_midi_take_on_track(tr)
      local sig = make_sig_for_take(tk)
      if TAB_SIG[current_tab] ~= sig then
        local prog, sigs = build_progress_for_take_full(tk)
        PROGRESS[current_tab] = PROGRESS[current_tab] or {}
        PROGRESS[current_tab]["regular"] = prog
        PROGRESS_SIG[current_tab] = PROGRESS_SIG[current_tab] or {}
        PROGRESS_SIG[current_tab]["regular"] = sigs
        TAB_SIG[current_tab] = sig
        rebuild_state_for_tab(current_tab, "regular")
      end
    end
  else
    -- No project change, no tab switch - just handle mode switches
    local obj_else = current_tab_obj and current_tab_obj()
    if mode_switched and current_tab == "Vocals" then
      compute_vocals()
    elseif mode_switched and current_tab == "Venue" then
      compute_venue()
    elseif obj_else and obj_else.name == "Keys" and obj_else:is_pro()
       and current_tab == "Keys"
       and (PROGRESS["Keys"] == nil or PROGRESS["Keys"]["pro"] == nil) then
      -- The pro variant hasn't been computed yet this session; do it now
      compute_pro_keys()
    end
  end

  last_proj_cc = cc
end
