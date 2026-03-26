-- fcp_tracker_ui_prefs.lua
-- Prefs tab for Action Command ID configuration
-- Integrated into Song Progress Tracker as a tab module

local reaper = reaper
local ImGui  = reaper

--------------------------------------------------------------------------------
-- Prefs test progress: percentage of passed action tests (0–100)
--------------------------------------------------------------------------------
-- Shared list of tab names (used by multiple sections below)
local FLOAT_FX_TABS = {"Setup","Drums","Bass","Guitar","Keys","Pro Keys","Vocals","Venue","Overdrive"}

local DEFAULT_ACTION_LABEL = "Find an Action to Run on Tab Switch"

--------------------------------------------------------------------------------
-- Unified action definitions: key, ExtState command key, default label, default tabs
--------------------------------------------------------------------------------
local ACTION_DEFS = {
  { key = "encore_vox",       ext_cmd = "CMD_ENCORE_VOX",       default_label = "Encore Vox Preview:",  default_tabs = { Vocals = true } },
  { key = "lyrics_clip",      ext_cmd = "CMD_LYRICS_CLIP",      default_label = "Lyrics Clipboard:",    default_tabs = { Vocals = true } },
  { key = "spectracular",     ext_cmd = "CMD_SPECTRACULAR",     default_label = "Spectracular Stereo:", default_tabs = { Vocals = true } },
  { key = "venue_preview",    ext_cmd = "CMD_VENUE_PREVIEW",    default_label = "Venue Preview:",        default_tabs = { Venue = true } },
  { key = "pro_keys_preview", ext_cmd = "CMD_PRO_KEYS_PREVIEW", default_label = "Pro Keys Preview:",     default_tabs = { ["Pro Keys"] = true } },
  { key = "action_6",  ext_cmd = "CMD_ACTION_6",  default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
  { key = "action_7",  ext_cmd = "CMD_ACTION_7",  default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
  { key = "action_8",  ext_cmd = "CMD_ACTION_8",  default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
  { key = "action_9",  ext_cmd = "CMD_ACTION_9",  default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
  { key = "action_10", ext_cmd = "CMD_ACTION_10", default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
  { key = "action_11", ext_cmd = "CMD_ACTION_11", default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
  { key = "action_12", ext_cmd = "CMD_ACTION_12", default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
  { key = "action_13", ext_cmd = "CMD_ACTION_13", default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
  { key = "action_14", ext_cmd = "CMD_ACTION_14", default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
  { key = "action_15", ext_cmd = "CMD_ACTION_15", default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
  { key = "action_16", ext_cmd = "CMD_ACTION_16", default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
  { key = "action_17", ext_cmd = "CMD_ACTION_17", default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
  { key = "action_18", ext_cmd = "CMD_ACTION_18", default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
  { key = "action_19", ext_cmd = "CMD_ACTION_19", default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
  { key = "action_20", ext_cmd = "CMD_ACTION_20", default_label = DEFAULT_ACTION_LABEL, default_tabs = {} },
}

-- Derive action keys list and tab defaults from ACTION_DEFS
local PREFS_ACTION_KEYS = {}
local ACTION_TAB_DEFAULTS = {}
for _, def in ipairs(ACTION_DEFS) do
  PREFS_ACTION_KEYS[#PREFS_ACTION_KEYS + 1] = def.key
  ACTION_TAB_DEFAULTS[def.key] = def.default_tabs
end

function get_action_tabs(action_key)
  local val = reaper.GetExtState(EXT_NS, EXT_ACTION_TABS_PREFIX .. action_key)
  if val and val ~= "" then
    local tabs = {}
    for name in val:gmatch("[^,]+") do
      tabs[name] = true
    end
    return tabs
  end
  -- Return a copy of defaults
  local defaults = ACTION_TAB_DEFAULTS[action_key] or {}
  local copy = {}
  for k, v in pairs(defaults) do copy[k] = v end
  return copy
end

function set_action_tabs(action_key, tabs)
  local parts = {}
  for _, name in ipairs(FLOAT_FX_TABS) do
    if tabs[name] then parts[#parts+1] = name end
  end
  reaper.SetExtState(EXT_NS, EXT_ACTION_TABS_PREFIX .. action_key, table.concat(parts, ","), true)
end

function get_action_leaving_tab_set(action_key)
  local val = reaper.GetExtState(EXT_NS, EXT_ACTION_LEAVING_TAB_SET_PREFIX .. action_key)
  if val == "0" then return false end
  return true
end

function set_action_leaving_tab_set(action_key, on)
  reaper.SetExtState(EXT_NS, EXT_ACTION_LEAVING_TAB_SET_PREFIX .. action_key, on and "1" or "0", true)
end

--- Run actions on tab switch using origin/destination comparison.
-- For each action, if exactly one of origin or destination is in the tab list, run it.
-- If both or neither are present, do nothing.
function run_actions_on_tab_switch(origin_tab, dest_tab)
  -- Resolve Keys → Pro Keys
  local origin = (origin_tab == "Keys" and PRO_KEYS_ACTIVE) and "Pro Keys" or origin_tab
  local dest   = (dest_tab == "Keys" and PRO_KEYS_ACTIVE) and "Pro Keys" or dest_tab
  local known = {}
  for _, name in ipairs(FLOAT_FX_TABS) do known[name] = true end

  for _, def in ipairs(ACTION_DEFS) do
    local tabs = get_action_tabs(def.key)
    -- Filter to known tabs only
    local origin_in = known[origin] and tabs[origin] or false
    local dest_in   = known[dest]   and tabs[dest]   or false
    local leaving = get_action_leaving_tab_set(def.key)
    local should_run
    if leaving then
      should_run = origin_in ~= dest_in
    else
      should_run = dest_in and not origin_in
    end
    if should_run then
      -- Exactly one of origin/destination is in the list: run the action
      local lookup_str = reaper.GetExtState(EXT_NS, def.ext_cmd)
      if lookup_str and lookup_str ~= "" then
        local cmd_id = reaper.NamedCommandLookup(lookup_str)
        if cmd_id ~= 0 then
          -- Spectracular needs MIDI item selected on PART VOCALS first
          if def.key == "spectracular" then
            local n = reaper.CountTracks(0)
            for i = 0, n - 1 do
              local tr = reaper.GetTrack(0, i)
              local ok, tname = reaper.GetTrackName(tr)
              if ok and tname == "PART VOCALS" then
                select_first_midi_item_on_track_no_editor(tr)
                break
              end
            end
          end
          reaper.Main_OnCommand(cmd_id, 0)
        end
      end
    end
  end
end

local function load_test_state(key)
  local val = reaper.GetExtState(EXT_NS, "TEST_STATE_" .. key)
  if val == "1" then return true end
  if val == "0" then return false end
  return nil
end

local function save_test_state(key, state)
  if state == true then
    reaper.SetExtState(EXT_NS, "TEST_STATE_" .. key, "1", true)
  elseif state == false then
    reaper.SetExtState(EXT_NS, "TEST_STATE_" .. key, "0", true)
  else
    reaper.DeleteExtState(EXT_NS, "TEST_STATE_" .. key, true)
  end
end

function prefs_test_pct()
  if not PREFS_TEST_STATE then return 0 end
  local passed = 0
  for _, key in ipairs(PREFS_ACTION_KEYS) do
    if PREFS_TEST_STATE[key] == true then passed = passed + 1 end
  end
  return math.floor(passed / #PREFS_ACTION_KEYS * 100)
end

--------------------------------------------------------------------------------
-- Show Floating Preview FX preference (global, per-tab)
--------------------------------------------------------------------------------
local FLOATING_FX_DEFAULTS = {
  Setup = false,
  Drums = true, Bass = true, Guitar = true, Keys = true,
  ["Pro Keys"] = false,
  Vocals = false, Venue = false, Overdrive = true,
}

-- Reverse lookup: fx key -> 0-based dropdown index
local FLOAT_FX_TAB_IDX = {}
for i, name in ipairs(FLOAT_FX_TABS) do FLOAT_FX_TAB_IDX[name] = i - 1 end

-- Set the Preferences dropdown to show the given runtime tab
function set_prefs_dropdown_for_tab(tab)
  local key = tab
  if key == "Keys" and PRO_KEYS_ACTIVE then key = "Pro Keys" end
  local idx = FLOAT_FX_TAB_IDX[key]
  if idx then PREFS_SELECTED_TAB_IDX = idx end
end

--------------------------------------------------------------------------------
-- MIDI Editor Open preference (global, per-tab)
--------------------------------------------------------------------------------
local MIDI_EDITOR_DEFAULTS = {
  Setup = false,
  Drums = false, Bass = false, Guitar = false, Keys = false,
  ["Pro Keys"] = true,
  Vocals = true, Venue = true, Overdrive = false,
}

-- Map runtime tab names to MIDI editor preference keys (same mapping as FX)
local MIDI_EDITOR_KEY = {
}

function get_midi_editor_open(tab)
  local key = MIDI_EDITOR_KEY[tab] or tab
  local val = reaper.GetExtState(EXT_NS, "MIDI_EDITOR_OPEN_" .. key)
  if val == "1" then return true end
  if val == "0" then return false end
  return MIDI_EDITOR_DEFAULTS[key] or false
end

function set_midi_editor_open(tab, on)
  local key = MIDI_EDITOR_KEY[tab] or tab
  reaper.SetExtState(EXT_NS, "MIDI_EDITOR_OPEN_" .. key, on and "1" or "0", true)
end

function get_show_floating_fx(tab)
  local key = tab
  local val = reaper.GetExtState(EXT_NS, "SHOW_FLOAT_FX_" .. key)
  if val == "1" then return true end
  if val == "0" then return false end
  return FLOATING_FX_DEFAULTS[key] or false
end

function set_show_floating_fx(tab, on)
  local key = tab
  reaper.SetExtState(EXT_NS, "SHOW_FLOAT_FX_" .. key, on and "1" or "0", true)
end

function get_show_just_fx(tab)
  local val = reaper.GetExtState(EXT_NS, "SHOW_JUST_FX_" .. tab)
  return val == "1"
end

function set_show_just_fx(tab, on)
  reaper.SetExtState(EXT_NS, "SHOW_JUST_FX_" .. tab, on and "1" or "0", true)
end

-- Open the 4 known floating FX windows and trigger alignment
function open_floating_fx_and_align()
  for _, key in ipairs(ORDER) do
    local trackname = TRACKS[key]
    local tr = find_track_by_name(trackname)
    if tr then
      local fx = get_instrument_fx_index(tr)
      if fx then
        reaper.TrackFX_Show(tr, fx, 3)  -- Show floating
      end
    end
  end
  reaper.SetExtState(EXT_NS, EXT_LINEUP, "SAVE_RUN", true)
end

-- Close the 4 known floating FX windows if they are open
function close_floating_fx()
  for _, key in ipairs(ORDER) do
    local trackname = TRACKS[key]
    local tr = find_track_by_name(trackname)
    if tr then
      local fx = get_instrument_fx_index(tr)
      if fx then
        local hwnd = reaper.TrackFX_GetFloatingWindow(tr, fx)
        if hwnd then
          reaper.TrackFX_Show(tr, fx, 2)  -- Toggle close
        end
      end
    end
  end
end

-- Per-tab "Just This" FX window geometry (separate from All tiling)
local TAB_TO_ORDER = { Drums="DRUMS", Bass="BASS", Guitar="GUITAR", Keys="KEYS", ["Pro Keys"]="KEYS" }

function get_just_fx_geom(tab)
  local sx = reaper.GetExtState(EXT_NS, "JUST_FX_X_" .. tab)
  local sy = reaper.GetExtState(EXT_NS, "JUST_FX_Y_" .. tab)
  local sw = reaper.GetExtState(EXT_NS, "JUST_FX_W_" .. tab)
  local sh = reaper.GetExtState(EXT_NS, "JUST_FX_H_" .. tab)
  if sx ~= "" and sy ~= "" and sw ~= "" and sh ~= "" then
    return tonumber(sx), tonumber(sy), tonumber(sw), tonumber(sh)
  end
  return nil
end

function save_just_fx_geom(tab)
  local this_key = TAB_TO_ORDER[tab]
  if not this_key then return end
  local tr = find_track_by_name(TRACKS[this_key])
  if not tr then return end
  local fx = get_instrument_fx_index(tr)
  if not fx then return end
  local hwnd = reaper.TrackFX_GetFloatingWindow(tr, fx)
  if not hwnd then return end
  local _, x, y, r, b = reaper.JS_Window_GetRect(hwnd)
  local w, h = r - x, b - y
  reaper.SetExtState(EXT_NS, "JUST_FX_X_" .. tab, tostring(x), true)
  reaper.SetExtState(EXT_NS, "JUST_FX_Y_" .. tab, tostring(y), true)
  reaper.SetExtState(EXT_NS, "JUST_FX_W_" .. tab, tostring(w), true)
  reaper.SetExtState(EXT_NS, "JUST_FX_H_" .. tab, tostring(h), true)
end

-- Open just one instrument's floating FX with saved per-tab geometry, close the other three
function open_just_instrument_fx(tab)
  local this_key = TAB_TO_ORDER[tab]
  if not this_key then return end
  for _, key in ipairs(ORDER) do
    local tr = find_track_by_name(TRACKS[key])
    if tr then
      local fx = get_instrument_fx_index(tr)
      if fx then
        if key == this_key then
          local hwnd = reaper.TrackFX_GetFloatingWindow(tr, fx)
          if not hwnd then
            reaper.TrackFX_Show(tr, fx, 3)
            hwnd = reaper.TrackFX_GetFloatingWindow(tr, fx)
          end
          if hwnd then
            local gx, gy, gw, gh = get_just_fx_geom(tab)
            if gx and gy and gw and gh then
              reaper.JS_Window_Move(hwnd, math.floor(gx), math.floor(gy))
              reaper.JS_Window_Resize(hwnd, math.floor(gw), math.floor(gh))
            else
              local _, _, w, h = get_master_geom()
              if w and h then
                reaper.JS_Window_Resize(hwnd, math.floor(w), math.floor(h))
              end
            end
          end
        else
          if reaper.TrackFX_GetFloatingWindow(tr, fx) then
            reaper.TrackFX_Show(tr, fx, 2)
          end
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Combo+Checkbox dropdown for per-action tab list
--------------------------------------------------------------------------------
-- Cache for action tab lists (loaded once, updated on checkbox change)
local action_tab_cache = {}

local function get_cached_action_tabs(action_key)
  if not action_tab_cache[action_key] then
    action_tab_cache[action_key] = get_action_tabs(action_key)
  end
  return action_tab_cache[action_key]
end

local function draw_action_tab_combo(ctx, action_key)
  local tabs = get_cached_action_tabs(action_key)
  -- Build preview string from checked tabs
  local preview_parts = {}
  for _, name in ipairs(FLOAT_FX_TABS) do
    if tabs[name] then preview_parts[#preview_parts+1] = name end
  end
  local preview = #preview_parts > 0 and table.concat(preview_parts, ", ") or "(none)"
  ImGui.ImGui_SetNextItemWidth(ctx, -1)
  if ImGui.ImGui_BeginCombo(ctx, "##tabs_" .. action_key, preview) then
    for _, name in ipairs(FLOAT_FX_TABS) do
      local rv, val = ImGui.ImGui_Checkbox(ctx, name .. "##tab_" .. action_key, tabs[name] or false)
      if rv then
        tabs[name] = val or nil
        set_action_tabs(action_key, tabs)
      end
    end
    ImGui.ImGui_EndCombo(ctx)
  end
end

--------------------------------------------------------------------------------
-- Draw Prefs Tab Content (public function called from fcp_tracker_ui.lua)
--------------------------------------------------------------------------------
function draw_prefs_tab(ctx)
  local _, avail_h = ImGui.ImGui_GetContentRegionAvail(ctx)

  if not PREFS_SELECTED_TAB_IDX then PREFS_SELECTED_TAB_IDX = 0 end
  ImGui.ImGui_AlignTextToFramePadding(ctx)
  ImGui.ImGui_Text(ctx, "On tab")
  ImGui.ImGui_SameLine(ctx)
  ImGui.ImGui_SetNextItemWidth(ctx, 120)
  local changed_tab, new_idx = ImGui.ImGui_Combo(ctx, "##prefs_tab_combo", PREFS_SELECTED_TAB_IDX, table.concat(FLOAT_FX_TABS, "\0") .. "\0")
  if changed_tab then PREFS_SELECTED_TAB_IDX = new_idx end
  ImGui.ImGui_SameLine(ctx)
  ImGui.ImGui_Text(ctx, "show:")
  ImGui.ImGui_SameLine(ctx)
  local x, y = ImGui.ImGui_GetCursorScreenPos(ctx)
  local line_h = ImGui.ImGui_GetTextLineHeightWithSpacing(ctx)
  ImGui.ImGui_DrawList_AddLine(ImGui.ImGui_GetWindowDrawList(ctx), x, y, x, y + line_h, 0x666666FF)
  ImGui.ImGui_Dummy(ctx, 1, 0)
  ImGui.ImGui_SameLine(ctx)
  ImGui.ImGui_Text(ctx, "5-Lane Previews:")
  ImGui.ImGui_SameLine(ctx)
  local sel_tab_name = FLOAT_FX_TABS[PREFS_SELECTED_TAB_IDX + 1] or FLOAT_FX_TABS[1]
  local float_fx_on = get_show_floating_fx(sel_tab_name)
  local chg_fx, new_fx = ImGui.ImGui_Checkbox(ctx, "All", float_fx_on)
  if chg_fx then
    set_show_floating_fx(sel_tab_name, new_fx)
    if new_fx then set_show_just_fx(sel_tab_name, false) end
  end
  local INSTRUMENT_TABS = { Drums=true, Bass=true, Guitar=true, Keys=true, ["Pro Keys"]=true }
  if INSTRUMENT_TABS[sel_tab_name] then
    ImGui.ImGui_SameLine(ctx)
    local just_on = get_show_just_fx(sel_tab_name)
    local just_label = sel_tab_name:gsub("^Pro ", "")
    local chg_jt, new_jt = ImGui.ImGui_Checkbox(ctx, "Just " .. just_label, just_on)
    if chg_jt then
      set_show_just_fx(sel_tab_name, new_jt)
      if new_jt then set_show_floating_fx(sel_tab_name, false) end
    end
  end
  ImGui.ImGui_SameLine(ctx)
  local x, y = ImGui.ImGui_GetCursorScreenPos(ctx)
  ImGui.ImGui_DrawList_AddLine(ImGui.ImGui_GetWindowDrawList(ctx), x, y, x, y + line_h, 0x666666FF)
  ImGui.ImGui_Dummy(ctx, 1, 0)
  ImGui.ImGui_SameLine(ctx)
  local midi_ed_on = get_midi_editor_open(sel_tab_name)
  local chg_me, new_me = ImGui.ImGui_Checkbox(ctx, "MIDI Editor", midi_ed_on)
  if chg_me then set_midi_editor_open(sel_tab_name, new_me) end
  ImGui.ImGui_SameLine(ctx)
  ImGui.ImGui_Dummy(ctx, 1, 0)
  if PREFS_CMD_ID_COL_X then
    local win_x = ImGui.ImGui_GetWindowPos(ctx)
    ImGui.ImGui_SameLine(ctx, PREFS_CMD_ID_COL_X - win_x)
  else
    ImGui.ImGui_SameLine(ctx)
  end
  if ImGui.ImGui_Button(ctx, "Open Action List") then
    reaper.Main_OnCommand(40605, 0)
  end
  ImGui.ImGui_Spacing(ctx)
  ImGui.ImGui_Separator(ctx)
  ImGui.ImGui_Spacing(ctx)

  -- Scrollbar width used to keep header and body table columns aligned
  local scrollbar_w = ImGui.ImGui_GetStyleVar(ctx, ImGui.ImGui_StyleVar_ScrollbarSize())

  -- Initialize buffers from ExtState if not already done
  if not SETUP_CMD_BUFFERS then
    SETUP_CMD_BUFFERS = {}
    for _, def in ipairs(ACTION_DEFS) do
      SETUP_CMD_BUFFERS[def.key] = reaper.GetExtState(EXT_NS, def.ext_cmd) or ""
    end
  end

  -- Track test button state: nil = untested (red), true = success (green), false = failed (red)
  if not PREFS_TEST_STATE then
    PREFS_TEST_STATE = {}
    for _, def in ipairs(ACTION_DEFS) do
      PREFS_TEST_STATE[def.key] = load_test_state(def.key)
    end
  end

  -- Labels that update to the action name on Test
  if not PREFS_ACTION_LABELS then
    PREFS_ACTION_LABELS = {}
    for _, def in ipairs(ACTION_DEFS) do
      if def.default_label == DEFAULT_ACTION_LABEL then
        local saved = reaper.GetExtState(EXT_NS, "ACTION_LABEL_" .. def.key)
        PREFS_ACTION_LABELS[def.key] = (saved ~= "" and saved) or def.default_label
      else
        PREFS_ACTION_LABELS[def.key] = def.default_label
      end
    end
  end

  local test_btn_w = 56

  -- Reserve space for version footer, then use remaining height for scrollable table
  local line_height_for_footer = ImGui.ImGui_GetTextLineHeightWithSpacing(ctx)
  local footer_reserve = line_height_for_footer + 6  -- version line + separator + minimal spacing
  local _, action_avail_h = ImGui.ImGui_GetContentRegionAvail(ctx)

  local row_h = PREFS_ROW_H or ImGui.ImGui_GetFrameHeightWithSpacing(ctx)
  local tbl_flags = ImGui.ImGui_TableFlags_SizingStretchProp() + ImGui.ImGui_TableFlags_RowBg() + ImGui.ImGui_TableFlags_Borders()

  --------------------------------------------------------------
  -- HEADER TABLE (fixed, outside scrolling child)
  --------------------------------------------------------------
  local hdr_avail_w = ImGui.ImGui_GetContentRegionAvail(ctx)
  if ImGui.ImGui_BeginTable(ctx, "PrefsActionsHdr", 5, tbl_flags, hdr_avail_w - scrollbar_w) then
    ImGui.ImGui_TableSetupColumn(ctx, "Action Name", ImGui.ImGui_TableColumnFlags_WidthStretch(), 1.0)
    ImGui.ImGui_TableSetupColumn(ctx, "Run When Navigating to This Set of Tabs", ImGui.ImGui_TableColumnFlags_WidthStretch(), 1.0)
    ImGui.ImGui_TableSetupColumn(ctx, "Leaving Tab Set", ImGui.ImGui_TableColumnFlags_WidthFixed(), 90)
    ImGui.ImGui_TableSetupColumn(ctx, "Action Command ID", ImGui.ImGui_TableColumnFlags_WidthStretch(), 1.0)
    ImGui.ImGui_TableSetupColumn(ctx, "Run", ImGui.ImGui_TableColumnFlags_WidthFixed(), test_btn_w)
    ImGui.ImGui_TableHeadersRow(ctx)
    -- Capture column positions for alignment
    ImGui.ImGui_TableSetColumnIndex(ctx, 1)
    PREFS_RUN_ON_TAB_X = ImGui.ImGui_GetCursorScreenPos(ctx)
    ImGui.ImGui_TableSetColumnIndex(ctx, 3)
    PREFS_CMD_ID_COL_X = ImGui.ImGui_GetCursorScreenPos(ctx)
    ImGui.ImGui_EndTable(ctx)
  end

  --------------------------------------------------------------
  -- BODY metrics
  --------------------------------------------------------------
  local body_avail_h = select(2, ImGui.ImGui_GetContentRegionAvail(ctx))
  local num_actions = #ACTION_DEFS
  local rows_fit = math.max(1, math.min(num_actions, math.floor((body_avail_h - footer_reserve) / row_h)))
  local body_h = rows_fit * row_h + 1
  local max_n = math.max(0, num_actions - rows_fit)
  local scroll_key = "prefs"

  --------------------------------------------------------------
  -- BODY: native scrollbar, 1-row wheel steps, snap to rows
  --------------------------------------------------------------
  local child_flags = ImGui.ImGui_WindowFlags_NoScrollWithMouse()
  if ImGui.ImGui_BeginChild(ctx, "prefs_rows_scroller", 0, body_h, 0, child_flags) then

    local sy = ImGui.ImGui_GetScrollY(ctx)

    do
      local n_from_sy = math.max(0, math.min(
        max_n, math.floor((sy / row_h) + 0.5)
      ))
      if TAB_SCROLL_ROW[scroll_key] ~= n_from_sy then
        TAB_SCROLL_ROW[scroll_key] = n_from_sy
      end
    end

    if TAB_SCROLL_ROW[scroll_key] ~= nil then
      local target_sy = (TAB_SCROLL_ROW[scroll_key] or 0) * row_h
      if math.abs(sy - target_sy) > 0.5 then
        ImGui.ImGui_SetScrollY(ctx, target_sy)
        sy = target_sy
      end
    end

    if ImGui.ImGui_IsWindowHovered(ctx, 0) then
      local wheel = ImGui.ImGui_GetMouseWheel(ctx) or 0
      if wheel ~= 0 then
        local step = (wheel > 0) and -1 or 1
        local n = (TAB_SCROLL_ROW[scroll_key] or 0) + step
        if n < 0 then n = 0
        elseif n > max_n then n = max_n end
        TAB_SCROLL_ROW[scroll_key] = n
        ImGui.ImGui_SetScrollY(ctx, n * row_h)
      end
    end

  if ImGui.ImGui_BeginTable(ctx, "PrefsActions", 5, tbl_flags) then
  ImGui.ImGui_TableSetupColumn(ctx, "Action Name", ImGui.ImGui_TableColumnFlags_WidthStretch(), 1.0)
  ImGui.ImGui_TableSetupColumn(ctx, "Run When Navigating to This Set of Tabs", ImGui.ImGui_TableColumnFlags_WidthStretch(), 1.0)
  ImGui.ImGui_TableSetupColumn(ctx, "Leaving Tab Set", ImGui.ImGui_TableColumnFlags_WidthFixed(), 90)
  ImGui.ImGui_TableSetupColumn(ctx, "Action Command ID", ImGui.ImGui_TableColumnFlags_WidthStretch(), 1.0)
  ImGui.ImGui_TableSetupColumn(ctx, "Run", ImGui.ImGui_TableColumnFlags_WidthFixed(), test_btn_w)

  local first_row_y
  for i, def in ipairs(ACTION_DEFS) do
    local key = def.key
    if i == num_actions then
      ImGui.ImGui_TableNextRow(ctx, 0, row_h + 1)
    else
      ImGui.ImGui_TableNextRow(ctx)
    end
    if i == 1 then
      first_row_y = select(2, ImGui.ImGui_GetCursorScreenPos(ctx))
    elseif i == 2 and first_row_y then
      local measured = select(2, ImGui.ImGui_GetCursorScreenPos(ctx)) - first_row_y
      if measured > 0 then PREFS_ROW_H = measured end
    end
    ImGui.ImGui_TableNextColumn(ctx)
    local is_custom = (def.default_label == DEFAULT_ACTION_LABEL)
    if is_custom and PREFS_EDITING_LABEL == key then
      ImGui.ImGui_SetNextItemWidth(ctx, -1)
      if PREFS_EDITING_LABEL_FOCUS then
        ImGui.ImGui_SetKeyboardFocusHere(ctx)
        PREFS_EDITING_LABEL_FOCUS = false
      end
      local changed_lbl, new_lbl = ImGui.ImGui_InputText(ctx, "##lbl_edit_" .. key, PREFS_EDITING_LABEL_BUF or "")
      if changed_lbl then PREFS_EDITING_LABEL_BUF = new_lbl end
      if ImGui.ImGui_IsItemDeactivatedAfterEdit(ctx) or
         (ImGui.ImGui_IsKeyPressed(ctx, ImGui.ImGui_Key_Escape()) and ImGui.ImGui_IsItemActive(ctx)) then
        if PREFS_EDITING_LABEL_BUF and PREFS_EDITING_LABEL_BUF ~= "" then
          PREFS_ACTION_LABELS[key] = PREFS_EDITING_LABEL_BUF
          reaper.SetExtState(EXT_NS, "ACTION_LABEL_" .. key, PREFS_EDITING_LABEL_BUF, true)
        end
        PREFS_EDITING_LABEL = nil
        PREFS_EDITING_LABEL_BUF = nil
      elseif not ImGui.ImGui_IsItemActive(ctx) and not ImGui.ImGui_IsItemFocused(ctx) then
        PREFS_EDITING_LABEL = nil
        PREFS_EDITING_LABEL_BUF = nil
      end
    else
      ImGui.ImGui_Text(ctx, PREFS_ACTION_LABELS[key])
      if is_custom and ImGui.ImGui_IsItemHovered(ctx) and ImGui.ImGui_IsMouseDoubleClicked(ctx, 0) then
        PREFS_EDITING_LABEL = key
        PREFS_EDITING_LABEL_BUF = PREFS_ACTION_LABELS[key]
        PREFS_EDITING_LABEL_FOCUS = true
      end
    end
    ImGui.ImGui_TableNextColumn(ctx)
    draw_action_tab_combo(ctx, key)
    ImGui.ImGui_TableNextColumn(ctx)
    local leaving_on = get_action_leaving_tab_set(key)
    local cell_x, cell_y = ImGui.ImGui_GetCursorScreenPos(ctx)
    local cell_w = ImGui.ImGui_GetContentRegionAvail(ctx)
    local cell_h = ImGui.ImGui_GetFrameHeight(ctx)
    local chg_leaving, new_leaving = ImGui.ImGui_Checkbox(ctx, "##leaving_" .. key, leaving_on)
    if chg_leaving then set_action_leaving_tab_set(key, new_leaving) end
    ImGui.ImGui_SameLine(ctx)
    ImGui.ImGui_Text(ctx, leaving_on and "UI Toggles" or "No Toggle")
    if not chg_leaving then
      local mx, my = ImGui.ImGui_GetMousePos(ctx)
      if ImGui.ImGui_IsMouseClicked(ctx, 0) and mx >= cell_x and mx <= cell_x + cell_w and my >= cell_y and my <= cell_y + cell_h then
        set_action_leaving_tab_set(key, not leaving_on)
      end
    end
    ImGui.ImGui_TableNextColumn(ctx)
    ImGui.ImGui_SetNextItemWidth(ctx, -1)
    local changed, new_val = ImGui.ImGui_InputText(ctx, "##" .. key, SETUP_CMD_BUFFERS[key])
    if changed and new_val ~= SETUP_CMD_BUFFERS[key] then
      SETUP_CMD_BUFFERS[key] = new_val
      reaper.SetExtState(EXT_NS, def.ext_cmd, new_val, true)
      PREFS_TEST_STATE[key] = nil
      save_test_state(key, nil)
    end
    ImGui.ImGui_TableNextColumn(ctx)
    if PREFS_TEST_STATE[key] == true then
      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Button(), 0x2E7D32FF)
      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonHovered(), 0x388E3CFF)
      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonActive(), 0x1B5E20FF)
    else
      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Button(), 0xB71C1CFF)
      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonHovered(), 0xD32F2FFF)
      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonActive(), 0x7F0000FF)
    end
    if ImGui.ImGui_Button(ctx, "Test##test_" .. key, -1, 0) then
      local cmd = SETUP_CMD_BUFFERS[key]
      local cmd_id = cmd ~= "" and reaper.NamedCommandLookup(cmd) or 0
      if cmd_id ~= 0 then
        reaper.Main_OnCommand(cmd_id, 0)
        local aname = reaper.kbd_getTextFromCmd(cmd_id, reaper.SectionFromUniqueID(0))
        if aname and aname ~= "" then
          PREFS_ACTION_LABELS[key] = aname
          if def.default_label == DEFAULT_ACTION_LABEL then
            reaper.SetExtState(EXT_NS, "ACTION_LABEL_" .. key, aname, true)
          end
        end
        PREFS_TEST_STATE[key] = true
        save_test_state(key, true)
      else
        SETUP_CMD_BUFFERS[key] = ""
        reaper.SetExtState(EXT_NS, def.ext_cmd, "", true)
        PREFS_ACTION_LABELS[key] = def.default_label
        if def.default_label == DEFAULT_ACTION_LABEL then
          reaper.DeleteExtState(EXT_NS, "ACTION_LABEL_" .. key, true)
        end
        PREFS_TEST_STATE[key] = false
        save_test_state(key, false)
      end
    end
    ImGui.ImGui_PopStyleColor(ctx, 3)
  end

  ImGui.ImGui_EndTable(ctx)
  end
  ImGui.ImGui_EndChild(ctx)
  end

  -- Version info at bottom left
  local line_height = ImGui.ImGui_GetTextLineHeightWithSpacing(ctx)
  local version_height = line_height + 10
  local win_h = ImGui.ImGui_GetWindowHeight(ctx)
  local target_y = win_h - version_height
  local current_y = ImGui.ImGui_GetCursorPosY(ctx)
  if target_y > current_y then
    ImGui.ImGui_SetCursorPosY(ctx, target_y)
  end
  ImGui.ImGui_Spacing(ctx)
  ImGui.ImGui_Separator(ctx)
  local version_text = "v" .. (SCRIPT_VERSION or "?.?.?")
  ImGui.ImGui_Text(ctx, "Version: " .. version_text .. " (Updates via ReaPack)")
  local hint_text = "Open the Action List, find an action, right-click → Copy Selected Action Command ID, and paste it above"
  if PREFS_RUN_ON_TAB_X then
    local win_x = ImGui.ImGui_GetWindowPos(ctx)
    ImGui.ImGui_SameLine(ctx, PREFS_RUN_ON_TAB_X - win_x)
  end
  ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), 0x999999FF)
  ImGui.ImGui_Text(ctx, hint_text)
  ImGui.ImGui_PopStyleColor(ctx)
end
