-- @description FCP Song Progress Tracker
-- @author FinestCardboardPearls
-- @version 1.0.2
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

SCRIPT_VERSION = "1.0.2"

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
  for _, t in ipairs(TABS) do
    if t == saved_tab then
      current_tab = saved_tab
      restored_tab = saved_tab
      break
    end
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
Progress_UI_Init(FCP_CTX)

-- Hide all MIDI tracks from MCP (mixer control panel)
local function hide_midi_tracks_from_mcp()
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local item_count = reaper.CountTrackMediaItems(tr)
    for j = 0, item_count - 1 do
      local item = reaper.GetTrackMediaItem(tr, j)
      local take = reaper.GetActiveTake(item)
      if take and reaper.TakeIsMIDI(take) then
        -- This track has a MIDI item, hide it from MCP
        reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 0)
        break
      end
    end
  end
end
hide_midi_tracks_from_mcp()

-- Flag to suppress tab-switch side effects during startup
-- This is a global so fcp_tracker_ui.lua can check it
FCP_STARTUP_MODE = true

-- Force the restored tab to be selected in the UI (for multiple frames)
if restored_tab then
  Progress_UI_ForceSelectTab(restored_tab, 5)
end

-- If starting on Keys tab with Pro Keys active, ensure MIDI editor is open
if restored_tab == "Keys" and PRO_KEYS_ACTIVE then
  -- Select the appropriate Pro Keys track
  local diff_map = { Expert="X", Hard="H", Medium="M", Easy="E" }
  local diff_key = diff_map[ACTIVE_DIFF] or "X"
  local trackname = PRO_KEYS_TRACKS[diff_key]
  
  -- Find and select the track, then open MIDI editor
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, name = reaper.GetTrackName(tr)
    if ok and name == trackname then
      reaper.SetOnlyTrackSelected(tr)
      -- Open MIDI editor if not already open
      local me = reaper.MIDIEditor_GetActive()
      if not me then
        -- Select first MIDI item and open editor
        local item_count = reaper.CountTrackMediaItems(tr)
        for j = 0, item_count - 1 do
          local item = reaper.GetTrackMediaItem(tr, j)
          local take = reaper.GetActiveTake(item)
          if take and reaper.TakeIsMIDI(take) then
            reaper.SetMediaItemSelected(item, true)
            reaper.Main_OnCommand(40153, 0)  -- Item: Open in built-in MIDI editor
            break
          end
        end
      end
      break
    end
  end
end

-- Force SET mode at startup (skip if starting on Vocals, Overdrive, or Setup - no FX alignment needed)
if restored_tab ~= "Vocals" and restored_tab ~= "Overdrive" and restored_tab ~= "Setup" then
  reaper.SetExtState(EXT_NS, EXT_FOCUS, "SET", false)
end

-- Start Jump Regions window if not on Setup tab
if restored_tab ~= "Setup" and FCP_JUMP_REGIONS then
  FCP_JUMP_REGIONS.start()
end

-- Save current tab, difficulty, and Pro Keys state on exit (project level)
local function save_state_on_exit()
  if current_tab then
    reaper.SetProjExtState(proj, EXT_NS, EXT_TAB_KEY, current_tab)
  end
  if ACTIVE_DIFF then
    reaper.SetProjExtState(proj, EXT_NS, EXT_DIFF_KEY, ACTIVE_DIFF)
  end
  reaper.SetProjExtState(proj, EXT_NS, EXT_PRO_KEYS_KEY, tostring(PRO_KEYS_ACTIVE or false))
end
reaper.atexit(save_state_on_exit)

-- Delay screenset loading until after window is established
local startup_frames = 3

-- Handle FCP_PREVIEWS signal for Vocals tab difficulty switching
local function check_previews_signal()
  local request = reaper.GetExtState("FCP_PREVIEWS", "REQUEST")
  if request and request ~= "" then
    reaper.DeleteExtState("FCP_PREVIEWS", "REQUEST", false)
    -- Only switch VOCALS_MODE if on Vocals tab
    if current_tab == "Vocals" then
      local mode_map = { EXPERT="H1", HARD="H2", MEDIUM="H3", EASY="V" }
      local new_mode = mode_map[request]
      if new_mode and VOCALS_MODE ~= new_mode then
        VOCALS_MODE = new_mode
        select_and_scroll_track_by_name(VOCALS_TRACKS[VOCALS_MODE], 40818, 40726)
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
      if current_tab == "Vocals" then
        reaper.Main_OnCommand(40455, 0)  -- Screenset: Load window set #02
      elseif current_tab == "Overdrive" then
        reaper.Main_OnCommand(40456, 0)  -- Screenset: Load window set #03
        -- Trigger Align action for floating FX windows
        reaper.SetExtState(EXT_NS, EXT_LINEUP, "SAVE_RUN", true)
      elseif current_tab == "Setup" then
        -- Skip screenset loading and FX alignment for Setup tab
      else
        reaper.Main_OnCommand(40454, 0)  -- Screenset: Load window set #01
      end
      -- End startup mode - now tab switches can have normal side effects
      FCP_STARTUP_MODE = false
    end
  end
  
  if open then
    reaper.defer(main_loop)
  else
    -- Progress Tracker closed - also stop Jump Regions window
    if FCP_JUMP_REGIONS and FCP_JUMP_REGIONS.stop then
      FCP_JUMP_REGIONS.stop()
    end
  end
end
reaper.defer(main_loop)
