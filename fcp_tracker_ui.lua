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


-- Editor row rendering (above footer)
local function draw_editor_row(ctx, pw, redirect_focus_after_click)
  -- Move up 4px
  local cur_y = ImGui.ImGui_GetCursorPosY(ctx)
  ImGui.ImGui_SetCursorPosY(ctx, cur_y - 3)
  
  -- Check if MIDI editor is open (not inline)
  local midi_editor_open = false
  local me = reaper.MIDIEditor_GetActive()
  if me then
    local mode = reaper.MIDIEditor_GetMode(me)
    if mode == 0 then  -- 0 = piano roll (floating), 1 = inline
      midi_editor_open = true
    end
  end
  
  -- Listen button (first in editor row)
  if current_tab == "Keys" and PRO_KEYS_ACTIVE then
    local diff_map = { Expert="X", Hard="H", Medium="M", Easy="E" }
    local diff_key = diff_map[ACTIVE_DIFF] or "X"
    local pro_keys_trackname = PRO_KEYS_TRACKS[diff_key]
    local fx_enabled = get_reasynth_enabled(pro_keys_trackname)
    local current_vol = get_reasynth_volume(pro_keys_trackname) or 0
    
    local listen_clicked, _ = ListenButtonWithVolume(ctx, "btn_listen", "Listen", pw, fx_enabled, current_vol, pro_keys_trackname)
    if listen_clicked then
      ensure_track_fx_chain_enabled(pro_keys_trackname)
      toggle_reasynth_enabled(pro_keys_trackname)
      reaper.defer(redirect_focus_after_click)
    end
  elseif current_tab == "Vocals" then
    local trackname = VOCALS_TRACKS[VOCALS_MODE]
    local fx_enabled = get_reasynth_enabled(trackname)
    local current_vol = get_reasynth_volume(trackname) or 0
    
    local listen_clicked, _ = ListenButtonWithVolume(ctx, "btn_vocals_listen", "Listen", pw, fx_enabled, current_vol, trackname)
    if listen_clicked then
      local ctrl  = ImGui.ImGui_IsKeyDown(ctx, ImGui.ImGui_Mod_Ctrl())
      local shift = ImGui.ImGui_IsKeyDown(ctx, ImGui.ImGui_Mod_Shift())
      local alt   = ImGui.ImGui_IsKeyDown(ctx, ImGui.ImGui_Mod_Alt())
      
      if ctrl or shift or alt then
        local all_off = true
        for _, tname in pairs(VOCALS_TRACKS) do
          if get_reasynth_enabled(tname) then
            all_off = false
            break
          end
        end
        
        if all_off then
          local harmony_tracks = { VOCALS_TRACKS["H1"], VOCALS_TRACKS["H2"], VOCALS_TRACKS["H3"] }
          for _, tname in ipairs(harmony_tracks) do
            ensure_track_fx_chain_enabled(tname)
            set_reasynth_enabled(tname, true)
          end
        else
          for _, tname in pairs(VOCALS_TRACKS) do
            set_reasynth_enabled(tname, false)
          end
        end
      else
        ensure_track_fx_chain_enabled(trackname)
        toggle_reasynth_enabled(trackname)
      end
      reaper.defer(redirect_focus_after_click)
    end
  else
    -- 5-lane Listen button (Drums, Bass, Guitar, Keys non-Pro)
    local listen_track_map = {
      Drums  = TRACKS.DRUMS,
      Bass   = TRACKS.BASS,
      Guitar = TRACKS.GUITAR,
    }
    local listen_trackname = listen_track_map[current_tab]
    if current_tab == "Keys" and not PRO_KEYS_ACTIVE then
      local pk_tr = find_track_by_name(PRO_KEYS_TRACKS["X"])
      if pk_tr and track_has_midi(pk_tr) then
        listen_trackname = PRO_KEYS_TRACKS["X"]
      else
        listen_trackname = TRACKS.KEYS
      end
    end
    if listen_trackname then
      local fx_enabled = get_reasynth_enabled(listen_trackname)
      local current_vol = get_reasynth_volume(listen_trackname) or 0
      local listen_clicked, _ = ListenButtonWithVolume(ctx, "btn_inst_listen", "Listen", pw, fx_enabled, current_vol, listen_trackname)
      if listen_clicked then
        ensure_track_fx_chain_enabled(listen_trackname)
        toggle_reasynth_enabled(listen_trackname)
        reaper.defer(redirect_focus_after_click)
      end
    end
  end

  -- Solo button (after Listen, before Editor)
  local solo_parent_map = {
    Drums = "PART DRUMS",
    Bass = "PART BASS",
    Guitar = "PART GUITAR",
    Keys = "PART KEYS",
    Vocals = "PART VOCALS",
  }
  local solo_parent = solo_parent_map[current_tab]
  if solo_parent then
    ImGui.ImGui_SameLine(ctx, 0, 4)
    if PairLikeButton(ctx, "btn_solo", "Solo", pw, SOLO_ACTIVE_PARENT == solo_parent) then
      if SOLO_ACTIVE_PARENT == solo_parent then
        unsolo_tab_audio()
        SOLO_ACTIVE_PARENT = nil
      else
        solo_tab_audio(solo_parent)
        SOLO_ACTIVE_PARENT = solo_parent
      end
      reaper.defer(redirect_focus_after_click)
    end
  end

  -- Overdrive tab: Editor + brightness slider + Notes button
  if current_tab == "Overdrive" then
    OV_LAST_EDITOR_TRACK = OV_LAST_EDITOR_TRACK or "PART DRUMS"
    if PairLikeButton(ctx, "btn_editor", "Editor", pw * 1, midi_editor_open) then
      if midi_editor_open then
        reaper.MIDIEditor_OnCommand(me, 2)  -- File: Close window
      else
        local tr = find_track_by_name(OV_LAST_EDITOR_TRACK)
        if tr then
          select_first_midi_item_on_track(tr)
        end
      end
      reaper.defer(redirect_focus_after_click)
    end

    ImGui.ImGui_SameLine(ctx, 0, 4)
    ImGui.ImGui_SetNextItemWidth(ctx, 80)
    local slider_flags = ImGui.ImGui_SliderFlags_NoInput()
    local changed, new_val = ImGui.ImGui_SliderInt(ctx, "##brightness", OV_MAX_NOTES_BRIGHTNESS or 12, 25, 1, "%d", slider_flags)
    if changed then
      OV_MAX_NOTES_BRIGHTNESS = new_val
    end
    if ImGui.ImGui_IsItemHovered(ctx) then
      ImGui.ImGui_SetTooltip(ctx, "Max notes for full brightness")
    end

    ImGui.ImGui_SameLine(ctx, 0, 4)
    if PairLikeButton(ctx, "btn_show_notes", "Notes", pw * 1.2, OV_SHOW_NOTES) then
      OV_SHOW_NOTES = not OV_SHOW_NOTES
    end
  else
    -- Editor toggle — SameLine only if a preceding button was drawn
    if solo_parent or current_tab ~= "Venue" then
      ImGui.ImGui_SameLine(ctx, 0, 4)
    end
    if PairLikeButton(ctx, "btn_editor", "Editor", pw * 1, midi_editor_open) then
      if midi_editor_open then
        -- Close the MIDI editor
        reaper.MIDIEditor_OnCommand(me, 2)  -- File: Close window
      else
        -- Open MIDI editor for selected item
        reaper.Main_OnCommand(40153, 0)  -- Item: Open in built-in MIDI editor
      end
      reaper.defer(redirect_focus_after_click)
    end
  end
  
  -- Sing/Spot toggle buttons (Venue editor row)
  if current_tab == "Venue" then
    ImGui.ImGui_SameLine(ctx, 0, 4)
    if PairLikeButton(ctx, "btn_sing", "Singalong", pw * 1.5, SING_ACTIVE) then
      SING_ACTIVE = not SING_ACTIVE
      if SING_ACTIVE or SPOT_ACTIVE then
        apply_venue_note_order_and_select(
          (SING_ACTIVE and SPOT_ACTIVE) and SING_SPOT_NOTE_ORDER
          or SING_ACTIVE and SING_NOTE_ORDER
          or SPOT_NOTE_ORDER)
      else
        select_and_scroll_track_by_name(VENUE_TRACKS[VENUE_MODE], 40818, 40726)
        local me2 = reaper.MIDIEditor_GetActive()
        if me2 then
          reaper.MIDIEditor_OnCommand(me2, 40452)
          reaper.MIDIEditor_OnCommand(me2, 40454)
        end
      end
      reaper.defer(redirect_focus_after_click)
    end

    ImGui.ImGui_SameLine(ctx, 0, 4)
    if PairLikeButton(ctx, "btn_spot", "Spotlight", pw * 1.5, SPOT_ACTIVE) then
      SPOT_ACTIVE = not SPOT_ACTIVE
      if SING_ACTIVE or SPOT_ACTIVE then
        apply_venue_note_order_and_select(
          (SING_ACTIVE and SPOT_ACTIVE) and SING_SPOT_NOTE_ORDER
          or SING_ACTIVE and SING_NOTE_ORDER
          or SPOT_NOTE_ORDER)
      else
        select_and_scroll_track_by_name(VENUE_TRACKS[VENUE_MODE], 40818, 40726)
        local me2 = reaper.MIDIEditor_GetActive()
        if me2 then
          reaper.MIDIEditor_OnCommand(me2, 40452)
          reaper.MIDIEditor_OnCommand(me2, 40454)
        end
      end
      reaper.defer(redirect_focus_after_click)
    end
  end

  -- Spectral button (Vocals editor row only)
  if current_tab == "Vocals" then
    ImGui.ImGui_SameLine(ctx, 0, 4)
    if PairLikeButton(ctx, "btn_spectracular", "Spectral", pw * 1.25, false) then
      start_spectracular()
      reaper.defer(redirect_focus_after_click)
    end
    ImGui.ImGui_SameLine(ctx, 0, 4)
    if PairLikeButton(ctx, "btn_lyrics_clip", "LCB", pw * 0.85, false) then
      start_lyrics_clipboard()
      reaper.defer(redirect_focus_after_click)
    end
  end

  -- Pro Keys toggle button (Keys tab editor row)
  if current_tab == "Keys" then
    ImGui.ImGui_SameLine(ctx, 0, 4)
    if PairLikeButton(ctx, "btn_pro_keys", "Pro", pw, PRO_KEYS_ACTIVE) then
      PRO_KEYS_ACTIVE = not PRO_KEYS_ACTIVE
      force_tab_selection("Keys", 3)
      if PRO_KEYS_ACTIVE then
        if CMD_SCREENSET_LOAD_PRO_KEYS and CMD_SCREENSET_LOAD_PRO_KEYS > 0 then
          reaper.Main_OnCommand(CMD_SCREENSET_LOAD_PRO_KEYS, 0)
        end
        local diff_map = { Expert="X", Hard="H", Medium="M", Easy="E" }
        local diff_key = diff_map[ACTIVE_DIFF] or "X"
        local trackname = PRO_KEYS_TRACKS[diff_key]
        select_and_scroll_track_by_name(trackname, 40818, 40726)
        compute_pro_keys()
      else
        if CMD_SCREENSET_LOAD_OTHERS and CMD_SCREENSET_LOAD_OTHERS > 0 then
          reaper.Main_OnCommand(CMD_SCREENSET_LOAD_OTHERS, 0)
        end
        select_and_scroll_track_by_name(TAB_TRACK["Keys"])
        local me = reaper.MIDIEditor_GetActive()
        if me then
          local mode = reaper.MIDIEditor_GetMode(me)
          if mode == 0 then
            reaper.MIDIEditor_OnCommand(me, 2)
          end
        end
      end
      reaper.defer(redirect_focus_after_click)
    end
  end
end

-- Footer rendering
local function draw_footer(ctx, pw, redirect_focus_after_click)
  -- Add spacing from Editor row
  local cur_y = ImGui.ImGui_GetCursorPosY(ctx)
  ImGui.ImGui_SetCursorPosY(ctx, cur_y + 2)
  
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

    if PairLikeButton(ctx, "btn_screenset", label, pw*1.67, false) then
      if cmd and cmd > 0 then
        reaper.Main_OnCommand(cmd, 0)
      end
    end
  end

  ImGui.ImGui_SameLine(ctx, 0, 4)
  if PairLikeButton(ctx, "btn_align", "Align", pw, false) then
    reaper.SetExtState(EXT_NS, EXT_LINEUP, "SAVE_RUN", true)
  end

  -- 5L FX toggle (Pro Keys, Vocals, Venue — between Align and Highway)
  if (current_tab == "Keys" and PRO_KEYS_ACTIVE) or current_tab == "Vocals" or current_tab == "Venue" then
    do
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

      ImGui.ImGui_SameLine(ctx, 0, 4)
      if PairLikeButton(ctx, "btn_fx_windows_row1", "5L", pw, any_open) then
        if any_open then
          for _, key in ipairs(ORDER) do
            local trackname = TRACKS[key]
            local tr = find_track_by_name(trackname)
            if tr then
              local fx = get_instrument_fx_index(tr)
              if fx then
                local hwnd = reaper.TrackFX_GetFloatingWindow(tr, fx)
                if hwnd then
                  reaper.TrackFX_Show(tr, fx, 2)
                end
              end
            end
          end
        else
          local x, y, w, h = get_master_geom()
          if x and y and w and h then
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
            for _, key in ipairs(ORDER) do
              local trackname = TRACKS[key]
              local tr = find_track_by_name(trackname)
              if tr then
                local fx = get_instrument_fx_index(tr)
                if fx then
                  reaper.TrackFX_Show(tr, fx, 3)
                end
              end
            end
          end
        end
        reaper.defer(redirect_focus_after_click)
      end
    end
  end

  -- Highway visualizer button (Pro Keys, Vocals, Venue)
  if current_tab == "Keys" and PRO_KEYS_ACTIVE then
    ImGui.ImGui_SameLine(ctx, 0, 4)
    if PairLikeButton(ctx, "btn_visualizer", "Highway", pw * 1.5, false) then
      start_pro_keys_preview()
      reaper.defer(redirect_focus_after_click)
    end
  elseif current_tab == "Vocals" then
    ImGui.ImGui_SameLine(ctx, 0, 4)
    if PairLikeButton(ctx, "btn_visualizer", "Highway", pw * 1.5, false) then
      start_encore_vox_preview_only()
      reaper.defer(redirect_focus_after_click)
    end
  elseif current_tab == "Venue" then
    ImGui.ImGui_SameLine(ctx, 0, 4)
    if PairLikeButton(ctx, "btn_visualizer", "Ven Preview", pw * 1.8, false) then
      start_venue_preview()
      reaper.defer(redirect_focus_after_click)
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
    
    -- Skip FX button on Pro Keys, Vocals, Venue (5L is rendered above instead)
    if (current_tab == "Keys" and PRO_KEYS_ACTIVE) or current_tab == "Vocals" or current_tab == "Venue" then
      -- 5L FX toggle is rendered above, skip here
    else
    local fx_hw_label = get_show_just_fx(current_tab) and "Highway" or "Highways"
    ImGui.ImGui_SameLine(ctx, 0, 4)
    if PairLikeButton(ctx, "btn_fx_windows", fx_hw_label, pw * 1.5, any_open) then
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
    end -- end if not Pro Keys
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
      
      -- Setup/Preferences tabs have their own content, skip normal header/table/footer
      if current_tab == "Preferences" then
        draw_prefs_tab(ctx)
      elseif current_tab == "Setup" then
        draw_setup_tab(ctx)
      else
        -- selection→tab follow (skip when on Overdrive, Setup, or Preferences to avoid switching away)
        -- Must run AFTER tabs_row so ImGui tab state is updated
        if current_tab ~= "Overdrive" and reaper.CountSelectedTracks(0) == 1 then
          local tr = reaper.GetSelectedTrack(0, 0)
          local ok, name = reaper.GetTrackName(tr)
          local tab = ok and TRACK_TO_TAB[name] or nil
          if tab and tab ~= current_tab then
            force_tab_selection(tab, 2)  -- Force ImGui to select this tab
            handle_tab_height_switch(ctx, tab)
            if tab == "Vocals" then
              select_and_scroll_track_by_name(VOCALS_TRACKS[VOCALS_MODE], 40818, 40726)
            elseif tab == "Venue" then
              close_midi_editor_if_not_inline()
              if name == "CAMERA" then VENUE_MODE = "Camera"
              elseif name == "LIGHTING" then VENUE_MODE = "Lighting" end
            end
            -- Don't reselect track for instrument tabs - user already selected the track they want
            run_actions_on_tab_switch(current_tab, tab)
            disable_reasynth_except_for_tab(tab)
            ensure_listen_fx_for_tab(tab)
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

        local footer_h   = (ImGui.ImGui_GetFrameHeight(ctx) * 2) + FOOTER_PAD + 4  -- Two rows of buttons
        local avail_h    = select(2, ImGui.ImGui_GetContentRegionAvail(ctx))
        local table_h    = math.max(20, avail_h - footer_h)

        if table_h > 30 then
          if ImGui.ImGui_BeginChild(ctx, "table_zone", 0, table_h, 0, 0) then
            draw_table(ctx, redirect_focus_after_click)
          end
          ImGui.ImGui_EndChild(ctx)
        end

        -- Editor row (above footer)
        draw_editor_row(ctx, PAIR_W, redirect_focus_after_click)
        
        -- Footer buttons
        draw_footer(ctx, PAIR_W, redirect_focus_after_click)
      end
    end
    ImGui.ImGui_End(ctx)
  end
  
  return open
end
