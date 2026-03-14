-- fcp_tracker_ui_prefs.lua
-- Prefs tab for Action Command ID configuration
-- Integrated into Song Progress Tracker as a tab module

local reaper = reaper
local ImGui  = reaper

--------------------------------------------------------------------------------
-- Prefs test progress: percentage of passed action tests (0–100)
--------------------------------------------------------------------------------
local PREFS_ACTION_KEYS = {"encore_vox", "lyrics_clip", "spectracular", "venue_preview", "pro_keys_preview"}

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

local FLOAT_FX_TABS = {"Setup","Drums","Bass","Guitar","Keys","Pro Keys","Vocals","Venue","Overdrive"}

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
-- Draw Prefs Tab Content (public function called from fcp_tracker_ui.lua)
--------------------------------------------------------------------------------
function draw_prefs_tab(ctx)
  local _, avail_h = ImGui.ImGui_GetContentRegionAvail(ctx)

  if not PREFS_SELECTED_TAB_IDX then PREFS_SELECTED_TAB_IDX = 0 end
  ImGui.ImGui_Text(ctx, "Show by default for:")
  ImGui.ImGui_SameLine(ctx)
  ImGui.ImGui_SetNextItemWidth(ctx, 120)
  local changed_tab, new_idx = ImGui.ImGui_Combo(ctx, "##prefs_tab_combo", PREFS_SELECTED_TAB_IDX, table.concat(FLOAT_FX_TABS, "\0") .. "\0")
  if changed_tab then PREFS_SELECTED_TAB_IDX = new_idx end
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

  -- Track test button state: nil = untested (red), true = success (green), false = failed (red)
  if not PREFS_TEST_STATE then
    PREFS_TEST_STATE = {}
    for _, key in ipairs(PREFS_ACTION_KEYS) do
      PREFS_TEST_STATE[key] = load_test_state(key)
    end
  end

  -- Labels that update to the action name on Test
  if not PREFS_ACTION_LABELS then
    PREFS_ACTION_LABELS = {
      encore_vox       = "Encore Vox Preview:",
      lyrics_clip      = "Lyrics Clipboard:",
      spectracular     = "Spectracular Stereo:",
      venue_preview    = "Venue Preview:",
      pro_keys_preview = "Pro Keys Preview:",
    }
  end

  local label_w = 240
  local tab_col_w = 80
  local cmd_col_x = label_w + tab_col_w
  local test_btn_w = 56
  local item_spacing_x = ({ImGui.ImGui_GetStyleVar(ctx, ImGui.ImGui_StyleVar_ItemSpacing())})[1]
  local input_reserve = test_btn_w + item_spacing_x
  
  -- Header row
  local content_w = ImGui.ImGui_GetContentRegionAvail(ctx)
  ImGui.ImGui_Text(ctx, "Action Name")
  ImGui.ImGui_SameLine(ctx, label_w)
  ImGui.ImGui_Text(ctx, "Run On Tab")
  ImGui.ImGui_SameLine(ctx, cmd_col_x + 1)
  ImGui.ImGui_Text(ctx, "Action Command ID")
  ImGui.ImGui_SameLine(ctx, content_w - test_btn_w + 7)
  ImGui.ImGui_Text(ctx, "Run")
  ImGui.ImGui_Separator(ctx)

  -- Encore Vox Preview
  ImGui.ImGui_Text(ctx, PREFS_ACTION_LABELS.encore_vox)
  ImGui.ImGui_SameLine(ctx, label_w)
  ImGui.ImGui_Text(ctx, "Vocals")
  ImGui.ImGui_SameLine(ctx, cmd_col_x)
  ImGui.ImGui_SetNextItemWidth(ctx, -input_reserve)
  local changed1, new_val1 = ImGui.ImGui_InputText(ctx, "##encore_vox", SETUP_CMD_BUFFERS.encore_vox)
  if changed1 and new_val1 ~= SETUP_CMD_BUFFERS.encore_vox then
    SETUP_CMD_BUFFERS.encore_vox = new_val1
    reaper.SetExtState(EXT_NS, EXT_CMD_ENCORE_VOX, new_val1, true)
    PREFS_TEST_STATE.encore_vox = nil
    save_test_state("encore_vox", nil)
  end
  ImGui.ImGui_SameLine(ctx)
  if PREFS_TEST_STATE.encore_vox == true then
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Button(), 0x2E7D32FF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonHovered(), 0x388E3CFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonActive(), 0x1B5E20FF)
  else
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Button(), 0xB71C1CFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonHovered(), 0xD32F2FFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonActive(), 0x7F0000FF)
  end
  if ImGui.ImGui_Button(ctx, "Test##test_encore_vox", test_btn_w, 0) then
    local cmd = SETUP_CMD_BUFFERS.encore_vox
    local cmd_id = cmd ~= "" and reaper.NamedCommandLookup(cmd) or 0
    if cmd_id ~= 0 then
      reaper.Main_OnCommand(cmd_id, 0)
      local name = reaper.kbd_getTextFromCmd(cmd_id, reaper.SectionFromUniqueID(0))
      if name and name ~= "" then PREFS_ACTION_LABELS.encore_vox = name end
      PREFS_TEST_STATE.encore_vox = true
      save_test_state("encore_vox", true)
    else
      SETUP_CMD_BUFFERS.encore_vox = ""
      reaper.SetExtState(EXT_NS, EXT_CMD_ENCORE_VOX, "", true)
      PREFS_ACTION_LABELS.encore_vox = "Encore Vox Preview:"
      PREFS_TEST_STATE.encore_vox = false
      save_test_state("encore_vox", false)
    end
  end
  ImGui.ImGui_PopStyleColor(ctx, 3)

  -- Lyrics Clipboard
  ImGui.ImGui_Text(ctx, PREFS_ACTION_LABELS.lyrics_clip)
  ImGui.ImGui_SameLine(ctx, label_w)
  ImGui.ImGui_Text(ctx, "Vocals")
  ImGui.ImGui_SameLine(ctx, cmd_col_x)
  ImGui.ImGui_SetNextItemWidth(ctx, -input_reserve)
  local changed2, new_val2 = ImGui.ImGui_InputText(ctx, "##lyrics_clip", SETUP_CMD_BUFFERS.lyrics_clip)
  if changed2 and new_val2 ~= SETUP_CMD_BUFFERS.lyrics_clip then
    SETUP_CMD_BUFFERS.lyrics_clip = new_val2
    reaper.SetExtState(EXT_NS, EXT_CMD_LYRICS_CLIP, new_val2, true)
    PREFS_TEST_STATE.lyrics_clip = nil
    save_test_state("lyrics_clip", nil)
  end
  ImGui.ImGui_SameLine(ctx)
  if PREFS_TEST_STATE.lyrics_clip == true then
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Button(), 0x2E7D32FF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonHovered(), 0x388E3CFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonActive(), 0x1B5E20FF)
  else
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Button(), 0xB71C1CFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonHovered(), 0xD32F2FFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonActive(), 0x7F0000FF)
  end
  if ImGui.ImGui_Button(ctx, "Test##test_lyrics_clip", test_btn_w, 0) then
    local cmd = SETUP_CMD_BUFFERS.lyrics_clip
    local cmd_id = cmd ~= "" and reaper.NamedCommandLookup(cmd) or 0
    if cmd_id ~= 0 then
      reaper.Main_OnCommand(cmd_id, 0)
      local name = reaper.kbd_getTextFromCmd(cmd_id, reaper.SectionFromUniqueID(0))
      if name and name ~= "" then PREFS_ACTION_LABELS.lyrics_clip = name end
      PREFS_TEST_STATE.lyrics_clip = true
      save_test_state("lyrics_clip", true)
    else
      SETUP_CMD_BUFFERS.lyrics_clip = ""
      reaper.SetExtState(EXT_NS, EXT_CMD_LYRICS_CLIP, "", true)
      PREFS_ACTION_LABELS.lyrics_clip = "Lyrics Clipboard:"
      PREFS_TEST_STATE.lyrics_clip = false
      save_test_state("lyrics_clip", false)
    end
  end
  ImGui.ImGui_PopStyleColor(ctx, 3)

  -- Spectracular (runs with Vocals tab)
  ImGui.ImGui_Text(ctx, PREFS_ACTION_LABELS.spectracular)
  ImGui.ImGui_SameLine(ctx, label_w)
  ImGui.ImGui_Text(ctx, "Vocals")
  ImGui.ImGui_SameLine(ctx, cmd_col_x)
  ImGui.ImGui_SetNextItemWidth(ctx, -input_reserve)
  local changed3, new_val3 = ImGui.ImGui_InputText(ctx, "##spectracular", SETUP_CMD_BUFFERS.spectracular)
  if changed3 and new_val3 ~= SETUP_CMD_BUFFERS.spectracular then
    SETUP_CMD_BUFFERS.spectracular = new_val3
    reaper.SetExtState(EXT_NS, EXT_CMD_SPECTRACULAR, new_val3, true)
    PREFS_TEST_STATE.spectracular = nil
    save_test_state("spectracular", nil)
  end
  ImGui.ImGui_SameLine(ctx)
  if PREFS_TEST_STATE.spectracular == true then
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Button(), 0x2E7D32FF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonHovered(), 0x388E3CFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonActive(), 0x1B5E20FF)
  else
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Button(), 0xB71C1CFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonHovered(), 0xD32F2FFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonActive(), 0x7F0000FF)
  end
  if ImGui.ImGui_Button(ctx, "Test##test_spectracular", test_btn_w, 0) then
    local cmd = SETUP_CMD_BUFFERS.spectracular
    local cmd_id = cmd ~= "" and reaper.NamedCommandLookup(cmd) or 0
    if cmd_id ~= 0 then
      reaper.Main_OnCommand(cmd_id, 0)
      local name = reaper.kbd_getTextFromCmd(cmd_id, reaper.SectionFromUniqueID(0))
      if name and name ~= "" then PREFS_ACTION_LABELS.spectracular = name end
      PREFS_TEST_STATE.spectracular = true
      save_test_state("spectracular", true)
    else
      SETUP_CMD_BUFFERS.spectracular = ""
      reaper.SetExtState(EXT_NS, EXT_CMD_SPECTRACULAR, "", true)
      PREFS_ACTION_LABELS.spectracular = "Spectracular Stereo:"
      PREFS_TEST_STATE.spectracular = false
      save_test_state("spectracular", false)
    end
  end
  ImGui.ImGui_PopStyleColor(ctx, 3)

  -- Venue Preview (runs with Venue tab)
  ImGui.ImGui_Text(ctx, PREFS_ACTION_LABELS.venue_preview)
  ImGui.ImGui_SameLine(ctx, label_w)
  ImGui.ImGui_Text(ctx, "Venue")
  ImGui.ImGui_SameLine(ctx, cmd_col_x)
  ImGui.ImGui_SetNextItemWidth(ctx, -input_reserve)
  local changed4, new_val4 = ImGui.ImGui_InputText(ctx, "##venue_preview", SETUP_CMD_BUFFERS.venue_preview)
  if changed4 and new_val4 ~= SETUP_CMD_BUFFERS.venue_preview then
    SETUP_CMD_BUFFERS.venue_preview = new_val4
    reaper.SetExtState(EXT_NS, EXT_CMD_VENUE_PREVIEW, new_val4, true)
    PREFS_TEST_STATE.venue_preview = nil
    save_test_state("venue_preview", nil)
  end
  ImGui.ImGui_SameLine(ctx)
  if PREFS_TEST_STATE.venue_preview == true then
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Button(), 0x2E7D32FF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonHovered(), 0x388E3CFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonActive(), 0x1B5E20FF)
  else
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Button(), 0xB71C1CFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonHovered(), 0xD32F2FFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonActive(), 0x7F0000FF)
  end
  if ImGui.ImGui_Button(ctx, "Test##test_venue_preview", test_btn_w, 0) then
    local cmd = SETUP_CMD_BUFFERS.venue_preview
    local cmd_id = cmd ~= "" and reaper.NamedCommandLookup(cmd) or 0
    if cmd_id ~= 0 then
      reaper.Main_OnCommand(cmd_id, 0)
      local name = reaper.kbd_getTextFromCmd(cmd_id, reaper.SectionFromUniqueID(0))
      if name and name ~= "" then PREFS_ACTION_LABELS.venue_preview = name end
      PREFS_TEST_STATE.venue_preview = true
      save_test_state("venue_preview", true)
    else
      SETUP_CMD_BUFFERS.venue_preview = ""
      reaper.SetExtState(EXT_NS, EXT_CMD_VENUE_PREVIEW, "", true)
      PREFS_ACTION_LABELS.venue_preview = "Venue Preview:"
      PREFS_TEST_STATE.venue_preview = false
      save_test_state("venue_preview", false)
    end
  end
  ImGui.ImGui_PopStyleColor(ctx, 3)

  -- Pro Keys Preview (runs with Pro Keys tab)
  ImGui.ImGui_Text(ctx, PREFS_ACTION_LABELS.pro_keys_preview)
  ImGui.ImGui_SameLine(ctx, label_w)
  ImGui.ImGui_Text(ctx, "Pro Keys")
  ImGui.ImGui_SameLine(ctx, cmd_col_x)
  ImGui.ImGui_SetNextItemWidth(ctx, -input_reserve)
  local changed5, new_val5 = ImGui.ImGui_InputText(ctx, "##pro_keys_preview", SETUP_CMD_BUFFERS.pro_keys_preview)
  if changed5 and new_val5 ~= SETUP_CMD_BUFFERS.pro_keys_preview then
    SETUP_CMD_BUFFERS.pro_keys_preview = new_val5
    reaper.SetExtState(EXT_NS, EXT_CMD_PRO_KEYS_PREVIEW, new_val5, true)
    PREFS_TEST_STATE.pro_keys_preview = nil
    save_test_state("pro_keys_preview", nil)
  end
  ImGui.ImGui_SameLine(ctx)
  if PREFS_TEST_STATE.pro_keys_preview == true then
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Button(), 0x2E7D32FF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonHovered(), 0x388E3CFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonActive(), 0x1B5E20FF)
  else
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Button(), 0xB71C1CFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonHovered(), 0xD32F2FFF)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_ButtonActive(), 0x7F0000FF)
  end
  if ImGui.ImGui_Button(ctx, "Test##test_pro_keys_preview", test_btn_w, 0) then
    local cmd = SETUP_CMD_BUFFERS.pro_keys_preview
    local cmd_id = cmd ~= "" and reaper.NamedCommandLookup(cmd) or 0
    if cmd_id ~= 0 then
      reaper.Main_OnCommand(cmd_id, 0)
      local name = reaper.kbd_getTextFromCmd(cmd_id, reaper.SectionFromUniqueID(0))
      if name and name ~= "" then PREFS_ACTION_LABELS.pro_keys_preview = name end
      PREFS_TEST_STATE.pro_keys_preview = true
      save_test_state("pro_keys_preview", true)
    else
      SETUP_CMD_BUFFERS.pro_keys_preview = ""
      reaper.SetExtState(EXT_NS, EXT_CMD_PRO_KEYS_PREVIEW, "", true)
      PREFS_ACTION_LABELS.pro_keys_preview = "Pro Keys Preview:"
      PREFS_TEST_STATE.pro_keys_preview = false
      save_test_state("pro_keys_preview", false)
    end
  end
  ImGui.ImGui_PopStyleColor(ctx, 3)

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
end
