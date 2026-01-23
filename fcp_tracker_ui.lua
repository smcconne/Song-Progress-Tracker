-- fcp_tracker_ui.lua 
-- ImGui rendering coordinator for the Song Progress Tracker.
-- Requires: fcp_tracker_ui_dock.lua, fcp_tracker_ui_tabs.lua, fcp_tracker_ui_header.lua, fcp_tracker_ui_table.lua

local reaper = reaper
local ImGui  = reaper

-- Track mouse state for focus redirection
local MOUSE_WAS_DOWN = false
local FOOTER_PAD = 0

-- Focus redirection helper: MIDI editor > inline editor > arrange view
local function redirect_focus_after_click()
  -- 1. Try active MIDI editor (piano roll, not inline)
  local me = reaper.MIDIEditor_GetActive()
  if me then
    local mode = reaper.MIDIEditor_GetMode(me)
    if mode == 0 then  -- 0 = piano roll (not inline)
      reaper.SN_FocusMIDIEditor()
      return
    end
  end

  -- 2. No floating MIDI editor: focus main REAPER window
  local main_hwnd = reaper.GetMainHwnd()
  reaper.JS_Window_SetFocus(main_hwnd)
end


-- Footer rendering
local function draw_footer(ctx, pw, redirect_focus_after_click)
  if PairLikeButton(ctx, "btn_align", "Align", pw, false) then
    reaper.SetExtState(EXT_NS, EXT_LINEUP, "SAVE_RUN", true)
  end

  -- Screenset button
  do
    local label, cmd
    if current_tab == "Keys" and PRO_KEYS_ACTIVE then
      label = "PK ScrSet"
      cmd   = CMD_SCREENSET_SAVE_PRO_KEYS
    elseif current_tab == "Vocals" then
      label = "Vox ScrSet"
      cmd   = CMD_SCREENSET_SAVE_VOCALS
    elseif current_tab == "Venue" then
      label = "Ven ScrSet"
      cmd   = CMD_SCREENSET_SAVE_VENUE
    elseif current_tab == "Overdrive" then
      label = "OV ScrSet"
      cmd   = CMD_SCREENSET_SAVE_OV
    else
      label = "5L ScrSet"
      cmd   = CMD_SCREENSET_SAVE_OTHERS
    end

    ImGui.ImGui_SameLine(ctx)
    if PairLikeButton(ctx, "btn_screenset", label, pw*1.67, false) then
      if cmd and cmd > 0 then
        reaper.Main_OnCommand(cmd, 0)
      end
    end
  end

  -- FX Windows toggle button (show/hide all four floating FX windows)
  do
    -- Check if any FX windows are currently open
    local any_open = false
    for _, key in ipairs(ORDER) do
      local trackname = TRACKS[key]
      local tr = find_track_by_name(trackname)
      if tr then
        local fx = get_instrument_fx_index(tr)
        if fx and reaper.TrackFX_GetFloatingWindow(tr, fx) then
          any_open = true
          break
        end
      end
    end
    
    ImGui.ImGui_SameLine(ctx)
    if PairLikeButton(ctx, "btn_fx_windows", "FX", pw, any_open) then
      if any_open then
        -- Close all FX windows
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
      else
        -- Open all FX windows with stored geometry
        local x, y, w, h = get_master_geom()
        if x and y and w and h then
          -- Calculate positions for each window (tiled horizontally)
          local function pos_k(k) return x + k*(w + GAP_PX), y end
          local positions = {
            DRUMS = {pos_k(0)},
            BASS = {pos_k(1)},
            GUITAR = {pos_k(2)},
            KEYS = {pos_k(3)},
          }
          for _, key in ipairs(ORDER) do
            local trackname = TRACKS[key]
            local tr = find_track_by_name(trackname)
            if tr then
              local px, py = positions[key][1], positions[key][2]
              hard_apply_for_track(key, tr, px, py, w, h, false)
            end
          end
        else
          -- Fallback: just open without positioning
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
        end
      end
      reaper.defer(redirect_focus_after_click)
    end
  end
  
  -- Brightness slider (Overdrive tab only)
  if current_tab == "Overdrive" then
    -- Track the initial max value (set once, never changes)
    OV_MAX_NOTES_INITIAL = OV_MAX_NOTES_INITIAL or (OV_MAX_NOTES_BRIGHTNESS or 40)
    
    ImGui.ImGui_SameLine(ctx)
    ImGui.ImGui_SetNextItemWidth(ctx, 80)
    local slider_flags = ImGui.ImGui_SliderFlags_NoInput()
    local changed, new_val = ImGui.ImGui_SliderInt(ctx, "##brightness", OV_MAX_NOTES_BRIGHTNESS or 40, 1, OV_MAX_NOTES_INITIAL, "%d", slider_flags)
    if changed then
      OV_MAX_NOTES_BRIGHTNESS = new_val
    end
    if ImGui.ImGui_IsItemHovered(ctx) then
      ImGui.ImGui_SetTooltip(ctx, "Max notes for full brightness")
    end
    
    -- Notes visibility toggle button
    ImGui.ImGui_SameLine(ctx)
    if PairLikeButton(ctx, "btn_show_notes", "Notes", pw * 1.2, OV_SHOW_NOTES) then
      OV_SHOW_NOTES = not OV_SHOW_NOTES
    end
  end
  
  -- Pro Keys toggle button (Keys tab only)
  if current_tab == "Keys" then
    ImGui.ImGui_SameLine(ctx)
    if PairLikeButton(ctx, "btn_pro_keys", "Pro", pw, PRO_KEYS_ACTIVE) then
      PRO_KEYS_ACTIVE = not PRO_KEYS_ACTIVE
      -- Force the Keys tab to be re-selected after the display name changes
      force_tab_selection("Keys", 3)
      if PRO_KEYS_ACTIVE then
        -- Load Pro Keys screenset
        if CMD_SCREENSET_LOAD_PRO_KEYS and CMD_SCREENSET_LOAD_PRO_KEYS > 0 then
          reaper.Main_OnCommand(CMD_SCREENSET_LOAD_PRO_KEYS, 0)
        end
        -- Select and open the appropriate Pro Keys track in MIDI editor
        local diff_map = { Expert="X", Hard="H", Medium="M", Easy="E" }
        local diff_key = diff_map[ACTIVE_DIFF] or "X"
        local trackname = PRO_KEYS_TRACKS[diff_key]
        select_and_scroll_track_by_name(trackname, 40818, 40726)
        -- Compute Pro Keys progress for this difficulty
        compute_pro_keys()
      else
        -- Load instrument screenset
        if CMD_SCREENSET_LOAD_OTHERS and CMD_SCREENSET_LOAD_OTHERS > 0 then
          reaper.Main_OnCommand(CMD_SCREENSET_LOAD_OTHERS, 0)
        end
        -- Switch back to PART KEYS
        select_and_scroll_track_by_name(TAB_TRACK["Keys"])
        -- Close MIDI editor only if it's currently open (not inline)
        local me = reaper.MIDIEditor_GetActive()
        if me then
          local mode = reaper.MIDIEditor_GetMode(me)
          if mode == 0 then  -- 0 = piano roll (not inline)
            reaper.MIDIEditor_OnCommand(me, 2)  -- Close window
          end
        end
      end
      reaper.defer(redirect_focus_after_click)
    end
  end

  -- MIDI FX toggle button (Vocals tab only)
  if current_tab == "Vocals" then
    local trackname = VOCALS_TRACKS[VOCALS_MODE]
    local fx_enabled = get_track_fx_enabled(trackname)
    
    ImGui.ImGui_SameLine(ctx)
    if PairLikeButton(ctx, "btn_midi_fx", "MIDI", pw, fx_enabled) then
      local ctrl  = ImGui.ImGui_IsKeyDown(ctx, ImGui.ImGui_Mod_Ctrl())
      local shift = ImGui.ImGui_IsKeyDown(ctx, ImGui.ImGui_Mod_Shift())
      local alt   = ImGui.ImGui_IsKeyDown(ctx, ImGui.ImGui_Mod_Alt())
      
      if ctrl or shift or alt then
        local all_off = true
        for _, tname in pairs(VOCALS_TRACKS) do
          if get_track_fx_enabled(tname) then
            all_off = false
            break
          end
        end
        
        if all_off then
          local harmony_tracks = { VOCALS_TRACKS["H1"], VOCALS_TRACKS["H2"], VOCALS_TRACKS["H3"] }
          for _, tname in ipairs(harmony_tracks) do
            local n = reaper.CountTracks(0)
            for i = 0, n - 1 do
              local tr = reaper.GetTrack(0, i)
              local ok, tn = reaper.GetTrackName(tr)
              if ok and tn == tname then
                reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", 1)
                break
              end
            end
          end
        else
          for _, tname in pairs(VOCALS_TRACKS) do
            local n = reaper.CountTracks(0)
            for i = 0, n - 1 do
              local tr = reaper.GetTrack(0, i)
              local ok, tn = reaper.GetTrackName(tr)
              if ok and tn == tname then
                reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", 0)
                break
              end
            end
          end
        end
      else
        toggle_track_fx_enabled(trackname)
      end
    end
  end
end

-- Public API ------------------------------------------------------------
function Progress_UI_Init()
  init_colors()
  init_header_metrics()
end

function Progress_UI_Draw()
  local ctx = FCP_CTX
  local PAIR_W = get_PAIR_W()

  ImGui.ImGui_SetNextWindowPos(ctx, 100, 100, ImGui.ImGui_Cond_FirstUseEver())
  ImGui.ImGui_SetNextWindowSize(ctx, WINDOW_W, H, ImGui.ImGui_Cond_FirstUseEver())

  local visible, open = ImGui.ImGui_Begin(
    ctx, APP_NAME, true, 
    ImGui.ImGui_WindowFlags_NoCollapse() +
    ImGui.ImGui_WindowFlags_NoScrollbar() +
    ImGui.ImGui_WindowFlags_NoScrollWithMouse()
  )

  -- Track mouse release over window for focus redirection
  local mouse_down      = ImGui.ImGui_IsMouseDown(ctx, 0)
  local window_hovered  = ImGui.ImGui_IsWindowHovered(ctx, ImGui.ImGui_HoveredFlags_ChildWindows())

  if MOUSE_WAS_DOWN and not mouse_down and window_hovered then
    reaper.defer(redirect_focus_after_click)
  end
  MOUSE_WAS_DOWN = mouse_down

  if visible then
    local win_w, win_h = ImGui.ImGui_GetWindowSize(ctx)
    if win_h < 120 then
      ImGui.ImGui_Text(ctx, "Window too small")
    else
      tabs_row(ctx, redirect_focus_after_click)
      
      -- Setup tab has its own content, skip normal header/table/footer
      if current_tab == "Setup" then
        draw_setup_tab(ctx)
      else
        -- selection→tab follow (skip when on Overdrive or Setup to avoid switching away)
        -- Must run AFTER tabs_row so ImGui tab state is updated
        if current_tab ~= "Overdrive" and reaper.CountSelectedTracks(0) == 1 then
          local tr = reaper.GetSelectedTrack(0, 0)
          local ok, name = reaper.GetTrackName(tr)
          local tab = ok and TRACK_TO_TAB[name] or nil
          if tab and tab ~= current_tab then
            force_tab_selection(tab, 2)  -- Force ImGui to select this tab
            handle_tab_height_switch(ctx, tab)
            local was_vocals = (current_tab == "Vocals")
            local is_vocals  = (tab == "Vocals")
            if tab == "Vocals" then
              select_and_scroll_track_by_name(VOCALS_TRACKS[VOCALS_MODE], 40818, 40726)
            elseif tab == "Venue" then
              close_midi_editor_if_not_inline()
              if name == "CAMERA" then VENUE_MODE = "Camera"
              elseif name == "LIGHTING" then VENUE_MODE = "Lighting" end
            end
            -- Don't reselect track for instrument tabs - user already selected the track they want
            if was_vocals or is_vocals then
              start_encore_vox_preview()
            end
            current_tab = tab
            WANT_CENTER_ON_TAB = true
            LAST_SEEN_TAB = tab
            
            -- Ensure track zoom to max height is enabled after tab switch
            local zoom_cmd = 40113  -- View: Toggle track zoom to maximum height
            if reaper.GetToggleCommandState(zoom_cmd) == 0 then
              reaper.Main_OnCommand(zoom_cmd, 0)
            end
          end
        end

        progress_and_count_row(ctx, redirect_focus_after_click)

        local footer_h   = ImGui.ImGui_GetFrameHeight(ctx) + FOOTER_PAD
        local avail_h    = select(2, ImGui.ImGui_GetContentRegionAvail(ctx))
        local table_h    = math.max(20, avail_h - footer_h)

        if table_h > 30 then
          if ImGui.ImGui_BeginChild(ctx, "table_zone", 0, table_h, 0, 0) then
            draw_table(ctx, redirect_focus_after_click)
          end
          ImGui.ImGui_EndChild(ctx)
        end

        -- Footer buttons
        draw_footer(ctx, PAIR_W, redirect_focus_after_click)
      end
    end
    ImGui.ImGui_End(ctx)
  end
  
  return open
end
