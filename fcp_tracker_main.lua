-- @description FCP Song Progress Tracker
-- @author FinestCardboardPearls
-- @version 2.0
-- @provides
--   [nomain] fcp_tracker_config.lua
--   [nomain] fcp_tracker_chunk_parse.lua
--   [nomain] fcp_tracker_focus.lua
--   [nomain] fcp_tracker_fxchain_geom.lua
--   [nomain] fcp_tracker_layout.lua
--   [nomain] fcp_tracker_templates.lua
--   [nomain] fcp_tracker_util_fs.lua
--   [nomain] fcp_tracker_util_selection.lua
--   [nomain] fcp_tracker_model.lua
--   [nomain] fcp_tracker_ui.lua
--   [nomain] fcp_tracker_ui_dock.lua
--   [nomain] fcp_tracker_ui_header.lua
--   [nomain] fcp_tracker_ui_helpers.lua
--   [nomain] fcp_tracker_ui_prefs.lua
--   [nomain] fcp_tracker_ui_setup.lua
--   [nomain] fcp_tracker_ui_table.lua
--   [nomain] fcp_tracker_ui_tabs.lua
--   [nomain] fcp_tracker_ui_track_utils.lua
--   [nomain] fcp_tracker_ui_widgets.lua
--   [nomain] fcp_jump_regions.lua
-- @about
--   Rock Band Song Progress Tracker for REAPER.
--   Multi-tab interface for tracking song authoring progress,
--   FX chain alignment, screenset management,
--   and hybrid use of floating and inline MIDI editing.

-- fcp_tracker_main.lua
-- Rock Band Song Progress Tracker
-- Entry point. Load modules, init Progress model/UI, run driver + UI.

SCRIPT_VERSION = "2.0"

local function script_dir()
  local info = debug.getinfo(1, "S")
  local p = info and info.source or ""
  p = p:gsub("^@", "")
  return p:match("^(.*[\\/])") or "./"
end

local DIR = script_dir()

-- Load config first to get EXT_NS and TABS
dofile(DIR .. "fcp_tracker_config.lua")

-- Get current project reference
local proj = select(2, reaper.EnumProjects(-1))

-- Restore last used tab BEFORE loading model (so current_tab is set before model initializes)
local EXT_TAB_KEY = "LAST_TAB"
local EXT_DIFF_KEY = "LAST_DIFF"
local EXT_PRO_KEYS_KEY = "PRO_KEYS_ACTIVE"
local restored_tab = nil

-- Restore tab
local retval, saved_tab = reaper.GetProjExtState(proj, EXT_NS, EXT_TAB_KEY)
if saved_tab and saved_tab ~= "" then
  -- Validate saved tab is in TABS list
  local matched = false
  for _, t in ipairs(TABS) do
    if t == saved_tab then
      current_tab = saved_tab
      restored_tab = saved_tab
      matched = true
      break
    end
  end
  if not matched then
    current_tab = "Preferences"
    restored_tab = "Preferences"
  end
end

-- Restore difficulty
local retval2, saved_diff = reaper.GetProjExtState(proj, EXT_NS, EXT_DIFF_KEY)
if saved_diff and saved_diff ~= "" then
  -- Validate saved diff is in DIFFS list
  for _, d in ipairs(DIFFS) do
    if d == saved_diff then
      ACTIVE_DIFF = saved_diff
      break
    end
  end
end

-- Restore Pro Keys state
local retval3, saved_pro_keys = reaper.GetProjExtState(proj, EXT_NS, EXT_PRO_KEYS_KEY)
if saved_pro_keys == "true" then
  PRO_KEYS_ACTIVE = true
elseif saved_pro_keys == "false" then
  PRO_KEYS_ACTIVE = false
end

-- Load remaining modules (order matters)
local to_load = {
  "fcp_tracker_util_selection.lua",
  "fcp_tracker_util_fs.lua",
  "fcp_tracker_chunk_parse.lua",
  "fcp_tracker_fxchain_geom.lua",
  "fcp_tracker_templates.lua",
  "fcp_tracker_focus.lua",
  "fcp_tracker_layout.lua",
  "fcp_tracker_model.lua",
  "fcp_tracker_ui_helpers.lua",
  "fcp_tracker_ui_widgets.lua",
  "fcp_tracker_ui_track_utils.lua",
  "fcp_tracker_ui_dock.lua",          -- NEW: docked height control
  "fcp_tracker_ui_tabs.lua",          -- NEW: tab bar rendering
  "fcp_tracker_ui_header.lua",        -- NEW: header row with buttons
  "fcp_tracker_ui_table.lua",         -- NEW: main region table
  "fcp_tracker_ui_prefs.lua",         -- NEW: Prefs tab (Action Command IDs)
  "fcp_tracker_ui_setup.lua",         -- NEW: Setup tab (PRC events tool)
  "fcp_tracker_ui.lua",               -- Slimmed down coordinator
}
for _, fname in ipairs(to_load) do dofile(DIR .. fname) end

-- Load Jump Regions module (integrated into progress tracker)
FCP_JUMP_REGIONS = dofile(DIR .. "fcp_jump_regions.lua")

-- One global ImGui context, created once with a unique label.
-- Pass ConfigFlags_DockingEnable as second parameter
local ImGui = reaper
FCP_CTX = ImGui.ImGui_CreateContext(
  (APP_NAME or "Song Progress Tracker") .. "##FCP",
  ImGui.ImGui_ConfigFlags_DockingEnable()
)

-- Initialize model + UI once
Progress_Init(true)  -- skip_fx_align=true, startup has its own flow

-- Auto-select leftmost incomplete difficulty for the restored tab
auto_select_difficulty(current_tab)

Progress_UI_Init(FCP_CTX)

-- Show audio tracks in MCP, hide MIDI-only tracks
set_mcp_visibility_for_audio_tracks()

-- Flag to suppress tab-switch side effects during startup
-- This is a global so fcp_tracker_ui.lua can check it
FCP_STARTUP_MODE = true

-- Force the restored tab to be selected in the UI (for multiple frames)
if restored_tab then
  Progress_UI_ForceSelectTab(restored_tab, 5)
end

-- Force SET mode at startup only if the restored tab wants floating FX
local startup_fx_tab = (restored_tab == "Keys" and PRO_KEYS_ACTIVE) and "Pro Keys" or restored_tab
if get_show_floating_fx(startup_fx_tab) then
  reaper.SetExtState(EXT_NS, EXT_FOCUS, "SET", false)
end

-- Jump Regions is now a headless module (UI drawn inline in table header)
-- No separate window to start

-- Save current tab, difficulty, and Pro Keys state on exit (project level)
local function save_state_on_exit()
  if current_tab then
    reaper.SetProjExtState(proj, EXT_NS, EXT_TAB_KEY, current_tab)
  end
  if ACTIVE_DIFF then
    reaper.SetProjExtState(proj, EXT_NS, EXT_DIFF_KEY, ACTIVE_DIFF)
  end
  reaper.SetProjExtState(proj, EXT_NS, EXT_PRO_KEYS_KEY, tostring(PRO_KEYS_ACTIVE or false))

  -- Run any actions with "leaving tab set" enabled for the current tab
  -- (dest="" means dest_in is always false, so only leaving-flagged actions fire)
  if current_tab then
    run_actions_on_tab_switch(current_tab, "")
  end

  -- Close floating FX windows and active MIDI editor on exit
  close_floating_fx()
  close_midi_editor_if_not_inline()
end
reaper.atexit(save_state_on_exit)

-- Delay screenset loading until after window is established
local startup_frames = 3

-- Handle FCP_PREVIEWS signal for difficulty switching
local function check_previews_signal()
  local request = reaper.GetExtState("FCP_PREVIEWS", "REQUEST")
  if request and request ~= "" then
    reaper.DeleteExtState("FCP_PREVIEWS", "REQUEST", false)
    
    if current_tab == "Vocals" then
      -- On Vocals tab: switch VOCALS_MODE (H1/H2/H3/V)
      local mode_map = { EXPERT="H1", HARD="H2", MEDIUM="H3", EASY="V" }
      local new_mode = mode_map[request]
      if new_mode and VOCALS_MODE ~= new_mode then
        VOCALS_MODE = new_mode
        select_and_scroll_track_by_name(VOCALS_TRACKS[VOCALS_MODE], 40818, 40726)
      end
    elseif current_tab == "Venue" then
      -- On Venue tab: 1=Camera, 2=Lighting, 3=toggle Sing, 4=toggle Spot
      if request == "MEDIUM" or request == "EASY" then
        -- Toggle individual Sing/Spot
        local toggling_sing = (request == "MEDIUM")
        if toggling_sing then SING_ACTIVE = not SING_ACTIVE
        else                  SPOT_ACTIVE = not SPOT_ACTIVE end

        if SING_ACTIVE or SPOT_ACTIVE then
          local order = (SING_ACTIVE and SPOT_ACTIVE) and SING_SPOT_NOTE_ORDER
                     or SING_ACTIVE and SING_NOTE_ORDER
                     or SPOT_NOTE_ORDER
          apply_venue_note_order_and_select(order)
        else
          -- Both off: restore current Camera/Lighting mode
          select_and_scroll_track_by_name(VENUE_TRACKS[VENUE_MODE], 40818, 40726)
          local me = reaper.MIDIEditor_GetActive()
          if me then
            reaper.MIDIEditor_OnCommand(me, 40452)
            reaper.MIDIEditor_OnCommand(me, 40454)
          end
        end
      else
        -- EXPERT=Camera, HARD=Lighting
        local mode_map = { EXPERT="Camera", HARD="Lighting" }
        local new_mode = mode_map[request]
        if new_mode then
          -- Disable Sing/Spot when switching to Camera/Lighting
          if SING_ACTIVE or SPOT_ACTIVE then
            SING_ACTIVE = false
            SPOT_ACTIVE = false
          end
          if VENUE_MODE ~= new_mode then
            VENUE_MODE = new_mode
            select_and_scroll_track_by_name(VENUE_TRACKS[VENUE_MODE], 40818, 40726)
          end
          -- Run 40452 then 40454 in MIDI editor
          local me = reaper.MIDIEditor_GetActive()
          if me then
            reaper.MIDIEditor_OnCommand(me, 40452)
            reaper.MIDIEditor_OnCommand(me, 40454)
          end
        end
      end
    else
      -- On other tabs: switch ACTIVE_DIFF (global difficulty)
      local diff_map = { EXPERT="Expert", HARD="Hard", MEDIUM="Medium", EASY="Easy" }
      local new_diff = diff_map[request]
      if new_diff then
        -- Always apply RBN Preview FX preset changes when difficulty request is received
        -- (ACTIVE_DIFF may already be set by button handler, but we still need to run_set)
        ACTIVE_DIFF = new_diff
        PAIR_MODE = 0
        -- Apply RBN Preview FX preset changes to all instrument tracks
        run_set(request)
        -- Trigger track selection for the new difficulty
        if current_tab == "Keys" and PRO_KEYS_ACTIVE then
          local pk_map = { Expert="X", Hard="H", Medium="M", Easy="E" }
          local diff_key = pk_map[new_diff] or "X"
          local trackname = PRO_KEYS_TRACKS[diff_key]
          select_and_scroll_track_by_name(trackname, 40818, 40726)
        end
      end
    end
  end
end

-- Single combined loop: driver + UI
local function main_loop()
  -- Check for FCP_PREVIEWS signal (Vocals tab difficulty switching)
  check_previews_signal()
  
  -- Driver tick (from fcp_tracker_focus.lua)
  loop_tick()
  
  -- Jump Regions: deferred MIDI recenter + external signal processing
  if FCP_JUMP_REGIONS then
    FCP_JUMP_REGIONS.tick()
    FCP_JUMP_REGIONS.process_ext_signals()
  end
  
  -- UI tick
  Progress_Tick()
  local open = Progress_UI_Draw()
  
  -- Check for pending region refresh (from Setup tab)
  if check_pending_region_refresh then
    check_pending_region_refresh()
  end
  
  -- Load screenset after a few frames to let ImGui window establish
  if startup_frames > 0 then
    startup_frames = startup_frames - 1
    if startup_frames == 0 then
      -- Load the appropriate screenset once
      if current_tab == "Keys" and PRO_KEYS_ACTIVE then
        reaper.Main_OnCommand(40458, 0)  -- Screenset: Load window set #05 (Pro Keys)
      elseif current_tab == "Vocals" then
        reaper.Main_OnCommand(40455, 0)  -- Screenset: Load window set #02
      elseif current_tab == "Overdrive" then
        reaper.Main_OnCommand(40456, 0)  -- Screenset: Load window set #03
      elseif current_tab == "Setup" or current_tab == "Preferences" then
        -- Skip screenset loading for Setup/Preferences tab
      else
        reaper.Main_OnCommand(40454, 0)  -- Screenset: Load window set #01
      end
      -- Close floating FX if the saved preference says so;
      -- opening + alignment is already handled by the SET signal in the driver loop
      local fx_tab = (current_tab == "Keys" and PRO_KEYS_ACTIVE) and "Pro Keys" or current_tab
      if not get_show_floating_fx(fx_tab) then
        close_floating_fx()
      end
      -- Enforce MIDI editor open/close preference for the startup tab
      local me_tab = (current_tab == "Keys" and PRO_KEYS_ACTIVE) and "Pro Keys" or current_tab
      local want_midi_editor = get_midi_editor_open(me_tab)
      local me_open = false
      local me = reaper.MIDIEditor_GetActive()
      if me and reaper.MIDIEditor_GetMode(me) == 0 then me_open = true end

      if want_midi_editor and not me_open then
        -- Open MIDI editor for the appropriate track
        if current_tab == "Vocals" then
          select_and_scroll_track_by_name(VOCALS_TRACKS[VOCALS_MODE], 40818, 40726)
        elseif current_tab == "Venue" then
          select_and_scroll_track_by_name(VENUE_TRACKS[VENUE_MODE], 40818, 40726)
        elseif current_tab == "Keys" and PRO_KEYS_ACTIVE then
          local diff_map = { Expert="X", Hard="H", Medium="M", Easy="E" }
          local diff_key = diff_map[ACTIVE_DIFF] or "X"
          select_and_scroll_track_by_name(PRO_KEYS_TRACKS[diff_key], 40818, 40726)
        elseif current_tab ~= "Setup" and current_tab ~= "Preferences" then
          select_track_for_tab(current_tab)
          local sel_tr = reaper.GetSelectedTrack(0, 0)
          if sel_tr then select_first_midi_item_on_track(sel_tr) end
        end
      elseif not want_midi_editor and me_open then
        close_midi_editor_if_not_inline()
      end
      -- Run per-action tab-switch scripts for the startup tab
      -- Use "" as origin so every action whose tab list includes the startup tab will fire
      run_actions_on_tab_switch("", current_tab)
      disable_reasynth_except_for_tab(current_tab)
      ensure_listen_fx_for_tab(current_tab)
      -- End startup mode - now tab switches can have normal side effects
      FCP_STARTUP_MODE = false
    end
  end
  
  if open then
    reaper.defer(main_loop)
  end
end
reaper.defer(main_loop)
