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
  
  -- Listen button (first in editor row). Resolve the active trackname via
  -- the Tab wrapper so the branches below share one lookup path.
  local cur_obj = current_tab_obj and current_tab_obj()
  local cur_mode = cur_obj and cur_obj:current_mode() or nil
  local cur_trackname = cur_mode and cur_mode.trackname or nil
  if cur_obj and cur_obj:is_pro() then
    -- Pro Keys Listen: reflects any of the four pro tracks; click toggles
    -- the group (all off -> restore saved, else current mode's track).
    local pro_keys_tracknames = { PRO_KEYS_TRACKS["Expert"], PRO_KEYS_TRACKS["Hard"],
                                 PRO_KEYS_TRACKS["Medium"], PRO_KEYS_TRACKS["Easy"] }
    local fx_enabled = false
    local active_trackname = nil
    for _, tname in ipairs(pro_keys_tracknames) do
      if get_reasynth_enabled(tname) then
        fx_enabled = true
        active_trackname = tname
        break
      end
    end

    local listen_clicked, _ = ListenButtonWithVolume(ctx, "btn_listen", "Listen", pw, fx_enabled)
    if listen_clicked then
      if fx_enabled then
        FCP_PK_LISTEN_SAVED = active_trackname
        for _, tname in ipairs(pro_keys_tracknames) do
          set_reasynth_enabled(tname, false)
        end
      elseif FCP_PK_LISTEN_SAVED and find_track_by_name(FCP_PK_LISTEN_SAVED) then
        ensure_track_fx_chain_enabled(FCP_PK_LISTEN_SAVED)
        set_reasynth_enabled(FCP_PK_LISTEN_SAVED, true)
      else
        local pro_keys_trackname = cur_trackname or (function()
          local cur_key = (cur_obj and cur_obj:current_mode_key()) or "Expert"
          return PRO_KEYS_TRACKS[cur_key] or PRO_KEYS_TRACKS["Expert"]
        end)()
        ensure_track_fx_chain_enabled(pro_keys_trackname)
        set_reasynth_enabled(pro_keys_trackname, true)
      end
      reaper.defer(redirect_focus_after_click)
    end
  elseif current_tab == "Vocals" then
    local trackname = cur_trackname or (current_tab_obj() and current_tab_obj():current_mode().trackname)
    local fx_enabled = false
    for _, tname in pairs(VOCALS_TRACKS) do
      if get_reasynth_enabled(tname) then
        fx_enabled = true
        break
      end
    end

    local listen_clicked, _ = ListenButtonWithVolume(ctx, "btn_vocals_listen", "Listen", pw, fx_enabled)
    if listen_clicked then
      -- Master toggle: any track on -> all off + remember on-set;
      -- all off + saved -> restore saved; all off + no saved -> turn on H1/H2/H3.
      local on_set = {}
      for _, tname in pairs(VOCALS_TRACKS) do
        if get_reasynth_enabled(tname) then
          on_set[tname] = true
        end
      end

      if next(on_set) then
        for _, tname in pairs(VOCALS_TRACKS) do
          set_reasynth_enabled(tname, false)
        end
        VOCALS_LISTEN_SAVED = on_set
      elseif VOCALS_LISTEN_SAVED then
        for tname in pairs(VOCALS_LISTEN_SAVED) do
          ensure_track_fx_chain_enabled(tname)
          set_reasynth_enabled(tname, true)
        end
      else
        local harmony_tracks = { VOCALS_TRACKS["H1"], VOCALS_TRACKS["H2"], VOCALS_TRACKS["H3"] }
        for _, tname in ipairs(harmony_tracks) do
          ensure_track_fx_chain_enabled(tname)
          set_reasynth_enabled(tname, true)
        end
      end
      reaper.defer(redirect_focus_after_click)
    end
  else
    -- 5-lane Listen button (Drums, Bass, Guitar, Keys non-Pro)
    local listen_trackname = cur_trackname
    if current_tab == "Keys" and (not cur_obj or not cur_obj:is_pro()) then
      -- Prefer the pro Expert track if it has MIDI; otherwise the regular Keys track
      local pk_tr = find_track_by_name(PRO_KEYS_TRACKS["Expert"])
      if pk_tr and track_has_midi(pk_tr) then
        listen_trackname = PRO_KEYS_TRACKS["Expert"]
      else
        listen_trackname = TRACKS.KEYS
      end
    end
    if listen_trackname then
      local fx_enabled = get_reasynth_enabled(listen_trackname)
      local listen_clicked, _ = ListenButtonWithVolume(ctx, "btn_inst_listen", "Listen", pw, fx_enabled)
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
  
  -- Sing/Spot toggle buttons (Venue editor row). The Venue variant's
  -- overlay_toggles is the single source of truth for these toggles.
  if current_tab == "Venue" then
    local venue_obj = TABS_BY_NAME and TABS_BY_NAME["Venue"]
    local venue_toggles = venue_obj and venue_obj:current_variant().overlay_toggles or nil
    local sing_active = venue_toggles and venue_toggles.sing or false
    local spot_active = venue_toggles and venue_toggles.spot or false
    ImGui.ImGui_SameLine(ctx, 0, 4)
    if PairLikeButton(ctx, "btn_sing", "Singalong", pw * 1.5, sing_active) then
      if venue_toggles then
        venue_toggles.sing = not venue_toggles.sing
        if venue_toggles.sing or venue_toggles.spot then
          apply_venue_note_order_and_select(
            (venue_toggles.sing and venue_toggles.spot) and SING_SPOT_NOTE_ORDER
            or venue_toggles.sing and SING_NOTE_ORDER
            or SPOT_NOTE_ORDER)
        else
          local venue_mode_obj = current_tab_obj and current_tab_obj()
          local venue_trackname = venue_mode_obj and venue_mode_obj:current_mode() and venue_mode_obj:current_mode().trackname or nil
          if venue_trackname then
            select_and_scroll_track_by_name(venue_trackname, 40818, 40726)
          end
          local me2 = reaper.MIDIEditor_GetActive()
          if me2 then
            reaper.MIDIEditor_OnCommand(me2, 40452)
            reaper.MIDIEditor_OnCommand(me2, 40454)
          end
        end
      end
      reaper.defer(redirect_focus_after_click)
    end

    ImGui.ImGui_SameLine(ctx, 0, 4)
    if PairLikeButton(ctx, "btn_spot", "Spotlight", pw * 1.5, spot_active) then
      if venue_toggles then
        venue_toggles.spot = not venue_toggles.spot
        if venue_toggles.sing or venue_toggles.spot then
          apply_venue_note_order_and_select(
            (venue_toggles.sing and venue_toggles.spot) and SING_SPOT_NOTE_ORDER
            or venue_toggles.sing and SING_NOTE_ORDER
            or SPOT_NOTE_ORDER)
        else
          local venue_mode_obj = current_tab_obj and current_tab_obj()
          local venue_trackname = venue_mode_obj and venue_mode_obj:current_mode() and venue_mode_obj:current_mode().trackname or nil
          if venue_trackname then
            select_and_scroll_track_by_name(venue_trackname, 40818, 40726)
          end
          local me2 = reaper.MIDIEditor_GetActive()
          if me2 then
            reaper.MIDIEditor_OnCommand(me2, 40452)
            reaper.MIDIEditor_OnCommand(me2, 40454)
          end
        end
      end
      reaper.defer(redirect_focus_after_click)
    end
  end

  -- Spectral button (Vocals editor row)
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
    if PairLikeButton(ctx, "btn_pro_keys", "Pro", pw * 0.8, (cur_obj and cur_obj:is_pro()) or false) then
      -- Variant flip: set_active_tab runs the full orchestration, with
      -- force_screenset so the destination variant's screenset loads.
      local new_variant = (cur_obj and cur_obj:is_pro()) and "regular" or "pro"
      force_tab_selection("Keys", 3)
      if set_active_tab then
        set_active_tab("Keys", new_variant, nil, true)
      end
      reaper.defer(redirect_focus_after_click)
    end

    -- Spectral button (Pro Keys, if Spectracular enabled for this tab)
    if cur_obj and cur_obj:is_pro() then
      local spec_tabs = get_action_tabs("spectracular")
      if spec_tabs["Pro Keys"] then
        ImGui.ImGui_SameLine(ctx, 0, 4)
        if PairLikeButton(ctx, "btn_spectracular_pk", "Spectral", pw * 1.25, false) then
          start_spectracular()
          reaper.defer(redirect_focus_after_click)
        end
      end
    end
  end
end

-- Footer rendering
local function draw_footer(ctx, pw, redirect_focus_after_click)
  -- Add spacing from Editor row
  local cur_y = ImGui.ImGui_GetCursorPosY(ctx)
  ImGui.ImGui_SetCursorPosY(ctx, cur_y + 2)

  -- Thin Tab wrapper locals: the single source of truth for active tab/variant/mode.
  local cur_obj = current_tab_obj and current_tab_obj() or nil
  local is_pro_keys = cur_obj and cur_obj:is_pro() or false

  -- Screenset button
  do
    local label, cmd
    if is_pro_keys then
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
  if is_pro_keys or current_tab == "Vocals" or current_tab == "Venue" then
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
  if is_pro_keys then
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
    if is_pro_keys or current_tab == "Vocals" or current_tab == "Venue" then
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
        -- selection→tab follow (skip on Overdrive/Setup/Preferences to avoid
        -- switching away). FCP_TAB_CHANGE_PENDING suppresses it briefly after a tab click.
        if (not FCP_TAB_CHANGE_PENDING or FCP_TAB_CHANGE_PENDING <= 0)
           and current_tab ~= "Overdrive"
           and reaper.CountSelectedTracks(0) == 1
        then
          local tr = reaper.GetSelectedTrack(0, 0)
          local ok, name = reaper.GetTrackName(tr)
          local tab = ok and TRACK_TO_TAB[name] or nil
          if tab and tab ~= current_tab then
            -- Infer destination tab/variant/mode from the track name and
            -- dispatch via set_active_tab with an explicit variant.
            local new_tab_obj, new_variant, new_mode = infer_tab_for_track and infer_tab_for_track(name)
            if new_tab_obj and set_active_tab then
              force_tab_selection(tab, 2)  -- Force ImGui to select this tab
              if new_tab_obj.name == "Keys" and new_variant == "pro" then
                TABS_BY_NAME["Keys"]:set_variant("pro")
              end
              local explicit_variant = new_variant
              if new_tab_obj.name == "Keys" and explicit_variant == nil then
                explicit_variant = "regular"
              end
              set_active_tab(new_tab_obj.name, explicit_variant, new_mode)
            end
          end
        end
        -- Decrement the tab-change-pending counter (set by set_active_tab on tab click).
        if FCP_TAB_CHANGE_PENDING and FCP_TAB_CHANGE_PENDING > 0 then
          FCP_TAB_CHANGE_PENDING = FCP_TAB_CHANGE_PENDING - 1
        end

        progress_and_count_row(ctx, redirect_focus_after_click)

        local footer_h   = (ImGui.ImGui_GetFrameHeight(ctx) * 2) + FOOTER_PAD + 4  -- Two rows of buttons
        local avail_h    = select(2, ImGui.ImGui_GetContentRegionAvail(ctx))
        local table_h    = math.max(20, avail_h - footer_h)

        if table_h > 30 then
          if ImGui.ImGui_BeginChild(ctx, "table_zone", 0, table_h, 0, 0) then
            if current_tab == "Overdrive" then
              draw_overdrive_table(ctx, redirect_focus_after_click)
            else
              draw_progress_table(ctx, redirect_focus_after_click)
            end
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
