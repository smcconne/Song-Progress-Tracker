-- @description FCP Song Progress Tracker
-- @author FinestCardboardPearls
-- @version 2.5
-- @provides
--   [nomain] fcp_tracker_config.lua
--   [nomain] fcp_tracker_tabs.lua
--   [nomain] fcp_tracker_chunk_parse.lua
--   [nomain] fcp_tracker_focus.lua
--   [nomain] fcp_tracker_fxchain_geom.lua
--   [nomain] fcp_tracker_layout.lua
--   [nomain] fcp_tracker_chunk_update.lua
--   [nomain] fcp_tracker_util_fs.lua
--   [nomain] fcp_tracker_util_selection.lua
--   [nomain] fcp_tracker_util_tracks.lua
--   [nomain] fcp_tracker_confetti_anim.lua
--   [nomain] fcp_tracker_model.lua
--   [nomain] fcp_tracker_model_persistence.lua
--   [nomain] fcp_tracker_model_build_progress.lua
--   [nomain] fcp_tracker_model_timer.lua
--   [nomain] fcp_tracker_model_percent.lua
--   [nomain] fcp_tracker_model_mutate.lua
--   [nomain] fcp_tracker_ui.lua
--   [nomain] fcp_tracker_ui_dock.lua
--   [nomain] fcp_tracker_ui_header.lua
--   [nomain] fcp_tracker_ui_helpers.lua
--   [nomain] fcp_tracker_ui_setup.lua
--   [nomain] fcp_tracker_ui_table_common.lua
--   [nomain] fcp_tracker_ui_table_overdrive.lua
--   [nomain] fcp_tracker_ui_table_prefs.lua
--   [nomain] fcp_tracker_ui_table_progress.lua
--   [nomain] fcp_tracker_ui_tabs.lua
--   [nomain] fcp_tracker_ui_widgets.lua
--   [nomain] fcp_tracker_listen_icon.lua
--   [nomain] fcp_tracker_ui_tooltips.lua
--   [nomain] fcp_jump_regions.lua
-- @about
--   Rock Band Song Progress Tracker for REAPER.
--   Multi-tab interface for tracking song authoring progress,
--   FX chain alignment, screenset management,
--   and hybrid use of floating and inline MIDI editing.

-- fcp_tracker_main.lua
-- Rock Band Song Progress Tracker
-- Entry point. Load modules, init Progress model/UI, run driver + UI.

SCRIPT_VERSION = "2.5"

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

-- Restore saved difficulty/mode. Raw local; validated against the current
-- tab's own mode list once the modules (DIFFS_VOX/DIFFS_VENUE) are loaded.
local pending_saved_diff = nil
local retval2, saved_diff = reaper.GetProjExtState(proj, EXT_NS, EXT_DIFF_KEY)
if saved_diff and saved_diff ~= "" then
  pending_saved_diff = saved_diff
end



-- Load remaining modules (order matters)
local to_load = {
  "fcp_tracker_tabs.lua",              -- Tab registry, must follow config
  "fcp_tracker_util_selection.lua",
  "fcp_tracker_util_fs.lua",
  "fcp_tracker_chunk_parse.lua",
  "fcp_tracker_fxchain_geom.lua",
  "fcp_tracker_chunk_update.lua",
  "fcp_tracker_focus.lua",
  "fcp_tracker_layout.lua",
  "fcp_tracker_model.lua",
  "fcp_tracker_model_persistence.lua",
  "fcp_tracker_model_build_progress.lua",
  "fcp_tracker_model_timer.lua",
  "fcp_tracker_model_percent.lua",
  "fcp_tracker_model_mutate.lua",
  "fcp_tracker_ui_helpers.lua",
  "fcp_tracker_ui_widgets.lua",
  "fcp_tracker_listen_icon.lua",
  "fcp_tracker_ui_tooltips.lua",
  "fcp_tracker_confetti_anim.lua",
  "fcp_tracker_util_tracks.lua",
  "fcp_tracker_ui_dock.lua",          -- docked height control
  "fcp_tracker_ui_tabs.lua",          -- tab bar rendering
  "fcp_tracker_ui_header.lua",        -- header row with buttons
  "fcp_tracker_ui_table_common.lua",  -- shared table helpers
  "fcp_tracker_ui_table_progress.lua",-- progress table renderer
  "fcp_tracker_ui_table_overdrive.lua",-- overdrive table renderer
  "fcp_tracker_ui_table_prefs.lua",   -- prefs table renderer
  "fcp_tracker_ui_setup.lua",         -- Setup tab (PRC events tool)
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

-- Validate the restored difficulty/mode against the tab's mode list,
-- falling back to the first mode.
local boot_obj = current_tab_obj and current_tab_obj() or nil
if boot_obj then
  local mode_list = DIFFS
  if boot_obj.name == "Vocals" then
    mode_list = DIFFS_VOX
  elseif boot_obj.name == "Venue" then
    mode_list = DIFFS_VENUE
  end
  local chosen_mode = pending_saved_diff
  local valid = false
  if chosen_mode then
    for _, m in ipairs(mode_list) do
      if m == chosen_mode then valid = true; break end
    end
  end
  set_active_mode(valid and chosen_mode or mode_list[1])
  last_mode_key = boot_obj:current_mode_key()
  -- Re-apply the active difficulty's preview FX/note order on boot
  apply_run_set_for_tab(current_tab)
end

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

-- Force SET mode at startup only if the restored tab wants floating FX.
local startup_cur_obj = current_tab_obj and current_tab_obj() or nil
local startup_fx_tab = (restored_tab == "Keys" and startup_cur_obj and startup_cur_obj:is_pro()) and "Pro Keys" or restored_tab
if get_show_floating_fx(startup_fx_tab) then
  reaper.SetExtState(EXT_NS, EXT_FOCUS, "SET", false)
end

-- Save current tab, difficulty, and Pro Keys state on exit (project level)
local function save_state_on_exit()
  if current_tab then
    reaper.SetProjExtState(proj, EXT_NS, EXT_TAB_KEY, current_tab)
  end
  local exit_obj = current_tab_obj and current_tab_obj() or nil
  local exit_diff = exit_obj and exit_obj:current_mode_key() or nil
  if exit_diff then
    reaper.SetProjExtState(proj, EXT_NS, EXT_DIFF_KEY, exit_diff)
  end

  -- Run leaving-tab actions for the current tab; translate Keys to
  -- "Pro Keys" when Pro is on for the variant key check.
  if current_tab then
    local exit_cur_obj = current_tab_obj and current_tab_obj() or nil
    local origin_v = (current_tab == "Keys" and exit_cur_obj and exit_cur_obj:is_pro()) and "Pro Keys" or current_tab
    run_actions_on_tab_switch(origin_v, "")
  end

  -- Close floating FX windows and active MIDI editor on exit
  close_floating_fx()
  close_midi_editor_if_not_inline()
end
reaper.atexit(save_state_on_exit)

-- Delay screenset loading until after window is established
local startup_frames = 3

-- Read + clear the FCP_PREVIEWS request and dispatch to the active Tab.
local function check_previews_signal()
  local request = reaper.GetExtState("FCP_PREVIEWS", "REQUEST")
  if not request or request == "" then return end
  reaper.DeleteExtState("FCP_PREVIEWS", "REQUEST", false)

  local obj = current_tab_obj and current_tab_obj()
  if obj and obj.handle_difficulty_signal then
    obj:handle_difficulty_signal(request)
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
  
  -- Tooltip frame tick: advance the rising-edge state before any draw.
  Tooltips_FrameTick()

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
      -- Thin Tab wrapper locals: the single source of truth for active tab/variant/mode.
      local cur_obj = current_tab_obj and current_tab_obj() or nil
      local cur_mode = cur_obj and cur_obj:current_mode() or nil
      local cur_trackname = cur_mode and cur_mode.trackname or nil
      local is_pro_keys = cur_obj and cur_obj:is_pro() or false

      -- Load the appropriate screenset once; no post-screenset recompute needed.
      if is_pro_keys then
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
      local fx_tab = is_pro_keys and "Pro Keys" or current_tab
      if not get_show_floating_fx(fx_tab) then
        close_floating_fx()
      end
      -- Enforce MIDI editor open/close preference for the startup tab
      local me_tab = is_pro_keys and "Pro Keys" or current_tab
      local want_midi_editor = get_midi_editor_open(me_tab)
      local me_open = false
      local me = reaper.MIDIEditor_GetActive()
      if me and reaper.MIDIEditor_GetMode(me) == 0 then me_open = true end

      if want_midi_editor and not me_open then
        -- Open MIDI editor for the appropriate track
        if current_tab == "Vocals" and cur_trackname then
          select_and_scroll_track_by_name(cur_trackname, 40818, 40726)
        elseif current_tab == "Venue" and cur_trackname then
          select_and_scroll_track_by_name(cur_trackname, 40818, 40726)
        elseif is_pro_keys and cur_trackname then
          select_and_scroll_track_by_name(cur_trackname, 40818, 40726)
        elseif current_tab ~= "Setup" and current_tab ~= "Preferences" then
          select_track_for_tab(current_tab)
          local sel_tr = reaper.GetSelectedTrack(0, 0)
          if sel_tr then select_first_midi_item_on_track(sel_tr) end
        end
      elseif not want_midi_editor and me_open then
        close_midi_editor_if_not_inline()
      end
      -- Run per-action tab-switch scripts for the startup tab ("" origin
      -- so every action whose list includes the startup tab fires).
      local dest_v = is_pro_keys and "Pro Keys" or current_tab
      run_actions_on_tab_switch("", dest_v)
      disable_reasynth_except_for_tab(current_tab)
      ensure_listen_fx_for_tab(current_tab)
      -- Apply default Pro Keys note rows (48-72) on startup if in Pro Keys mode
      if is_pro_keys then
        reaper.SetExtState("FCP_PREVIEWS", "REQUEST", "PK_DEFAULT", false)
      end
      -- Apply default Vocals note rows (48-66) on startup if in Vocals mode
      if current_tab == "Vocals" then
        VOCALS_NOTE_START = 48
        apply_vocals_note_order(VOCALS_NOTE_START)
      end
      -- End startup mode - now tab switches can have normal side effects
      FCP_STARTUP_MODE = false
    end
  end
  
  if open then
    reaper.defer(main_loop)
  end
end
reaper.defer(main_loop)
