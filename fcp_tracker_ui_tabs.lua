-- fcp_tracker_ui_tabs.lua
-- Tab bar rendering and tab switching logic
-- Requires: fcp_tracker_ui_dock.lua, fcp_tracker_ui_helpers.lua

local reaper = reaper
local ImGui  = reaper

-- Module-local state for tab forcing
local force_select_tab = nil
local force_select_frames = 0

-- Public function to force tab selection from external code
function force_tab_selection(tab_name, frames)
  force_select_tab = tab_name
  force_select_frames = frames or 2
end

-- Frame delay for centering after screenset load
CENTER_DELAY_FRAMES = 0

-- Centering flags (shared with table module)
WANT_CENTER_ON_TAB = false
LAST_SEEN_TAB = current_tab

function handle_tab_height_switch(ctx, new_tab)
  -- Skip during startup - main_loop handles initial screenset load
  if FCP_STARTUP_MODE then return end
  
  -- Skip during project switch - model handles screenset load
  if PROJECT_SWITCH_MODE then return end
  
  -- Handle Jump Regions window visibility based on tab
  if FCP_JUMP_REGIONS then
    if new_tab == "Setup" then
      -- Close Jump Regions when switching to Setup
      FCP_JUMP_REGIONS.stop()
    elseif current_tab == "Setup" and new_tab ~= "Setup" then
      -- Open Jump Regions when switching from Setup to any other tab
      FCP_JUMP_REGIONS.start()
    elseif not FCP_JUMP_REGIONS.is_running() and new_tab ~= "Setup" then
      -- Ensure Jump Regions is running on non-Setup tabs
      FCP_JUMP_REGIONS.start()
    end
  end
  
  -- Determine direction of switch
  local is_switching_to_vocals   = (new_tab == "Vocals"    and current_tab ~= "Vocals")
  local is_switching_from_vocals = (current_tab == "Vocals" and new_tab ~= "Vocals")
  local is_switching_to_ov       = (new_tab == "Overdrive" and current_tab ~= "Overdrive")
  local is_switching_from_ov     = (current_tab == "Overdrive" and new_tab ~= "Overdrive")
  local is_switching_to_venue    = (new_tab == "Venue" and current_tab ~= "Venue")
  local is_switching_from_venue  = (current_tab == "Venue" and new_tab ~= "Venue")
  local is_switching_to_setup    = (new_tab == "Setup" and current_tab ~= "Setup")
  
  -- Instrument tabs: Drums, Bass, Guitar, Keys
  local instrument_tabs = { Drums = true, Bass = true, Guitar = true, Keys = true }
  local is_switching_to_instrument = instrument_tabs[new_tab] and not instrument_tabs[current_tab]

  if is_switching_to_vocals then
    if CMD_SCREENSET_LOAD_VOCALS and CMD_SCREENSET_LOAD_VOCALS > 0 then
      reaper.Main_OnCommand(CMD_SCREENSET_LOAD_VOCALS, 0)
    end
    CENTER_DELAY_FRAMES = 2
  elseif is_switching_to_ov then
    if CMD_SCREENSET_LOAD_OV and CMD_SCREENSET_LOAD_OV > 0 then
      reaper.Main_OnCommand(CMD_SCREENSET_LOAD_OV, 0)
    end
    CENTER_DELAY_FRAMES = 2
    -- Trigger Align action for floating FX windows
    reaper.SetExtState(EXT_NS, EXT_LINEUP, "SAVE_RUN", true)
  elseif is_switching_to_venue then
    if CMD_SCREENSET_LOAD_VENUE and CMD_SCREENSET_LOAD_VENUE > 0 then
      reaper.Main_OnCommand(CMD_SCREENSET_LOAD_VENUE, 0)
    end
    CENTER_DELAY_FRAMES = 2
  elseif is_switching_to_setup then
    -- Switching to Setup: no screenset load needed
    CENTER_DELAY_FRAMES = 0
  elseif is_switching_to_instrument then
    -- Switching to Drums/Bass/Guitar/Keys from non-instrument tab
    if CMD_SCREENSET_LOAD_OTHERS and CMD_SCREENSET_LOAD_OTHERS > 0 then
      reaper.Main_OnCommand(CMD_SCREENSET_LOAD_OTHERS, 0)
    end
    CENTER_DELAY_FRAMES = 2
    -- Don't trigger SAVE_RUN here - FX windows are positioned via hard_apply_for_track
    -- when switching from Setup, and we don't want to override those positions
  elseif is_switching_from_vocals or is_switching_from_ov or is_switching_from_venue then
    -- Switching from Vocals/OV/Venue to another special tab (handled above catches Setup/instruments)
    if CMD_SCREENSET_LOAD_OTHERS and CMD_SCREENSET_LOAD_OTHERS > 0 then
      reaper.Main_OnCommand(CMD_SCREENSET_LOAD_OTHERS, 0)
    end
    CENTER_DELAY_FRAMES = 2
    -- Trigger Align action for floating FX windows
    reaper.SetExtState(EXT_NS, EXT_LINEUP, "SAVE_RUN", true)
  end
end

function tabs_row(ctx, redirect_focus_after_click)
  local PAIR_W = get_PAIR_W()
  
  -- Calculate underline color based on weighted percentage for instrument tabs
  local underline_pct
  if current_tab == "Setup" then
    underline_pct = 50  -- Neutral gray for Setup tab
  elseif current_tab == "Drums" or current_tab == "Bass" or current_tab == "Guitar" or current_tab == "Keys" then
    underline_pct = weighted_tab_pct(current_tab)
  elseif current_tab == "Overdrive" then
    underline_pct = overdrive_completion_pct()
  else
    local current_diff
    if current_tab == "Vocals" then
      current_diff = VOCALS_MODE
    elseif current_tab == "Venue" then
      current_diff = VENUE_MODE
    else
      current_diff = ACTIVE_DIFF
    end
    underline_pct = diff_pct(current_tab, current_diff)
  end
  local col = pct_scaled_u32(underline_pct, 0.86, 1.0)

  ImGui.ImGui_BeginGroup(ctx)
  if ImGui.ImGui_BeginTabBar(ctx, "bands_tabbar", 0) then
    for _, name in ipairs(TABS) do
      -- Determine tab coloring based on weighted percentage for instruments
      local p
      if name == "Setup" then
        p = 50  -- Neutral gray for Setup tab (no progress tracking)
      elseif name == "Drums" or name == "Bass" or name == "Guitar" or name == "Keys" then
        p = weighted_tab_pct(name)
      elseif name == "Overdrive" then
        p = overdrive_completion_pct()
      elseif name == "Venue" then
        -- Venue uses 50/50 average of Camera and Lighting
        local camera_pct = diff_pct("Venue", "Camera")
        local lighting_pct = diff_pct("Venue", "Lighting")
        p = math.floor((camera_pct + lighting_pct) / 2)
      elseif name == "Vocals" then
        -- Vocals uses equal weighting for H1, H2, H3, V (only non-empty tracks count)
        local vocals_tracks = {"H1", "H2", "H3", "V"}
        local total_pct = 0
        local track_count = 0
        for _, vt in ipairs(vocals_tracks) do
          if not is_all_empty("Vocals", vt) then
            total_pct = total_pct + diff_pct("Vocals", vt)
            track_count = track_count + 1
          end
        end
        if track_count > 0 then
          p = math.floor(total_pct / track_count)
        else
          p = 0
        end
      else
        p = diff_pct(name, ACTIVE_DIFF)
      end
      local ci = pct_scaled_u32(p, 0.46, 1.0)
      local ch = pct_scaled_u32(p, 0.74, 1.0)
      local ca = pct_scaled_u32(p, 0.86, 1.0)

      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Tab(),        ci)
      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_TabHovered(), ch)
      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_TabSelected(),ca)

      -- Force selection for multiple frames on startup
      local flags = 0
      if force_select_tab == name and force_select_frames > 0 then
        flags = ImGui.ImGui_TabItemFlags_SetSelected()
      end
      
      -- Display "Pro Keys" instead of "Keys" when Pro Keys is active
      local display_name = name
      if name == "Keys" and PRO_KEYS_ACTIVE then
        display_name = "Pro Keys"
      end
      
      if ImGui.ImGui_BeginTabItem(ctx, display_name, nil, flags) then
        if current_tab ~= name then
          handle_tab_height_switch(ctx, name)
          local was_vocals = (current_tab == "Vocals")
          local was_setup  = (current_tab == "Setup")
          local was_venue  = (current_tab == "Venue")
          local is_vocals  = (name == "Vocals")
          local is_setup   = (name == "Setup")
          local is_venue   = (name == "Venue")
          current_tab = name
          
          -- Update TCP visibility based on Setup mode
          if is_setup ~= was_setup then
            set_tcp_visibility_for_setup(is_setup)
          end
          
          -- Show/hide master track based on Setup mode
          if is_setup and not was_setup then
            -- Switching TO Setup: show master
            local cmd_show = reaper.NamedCommandLookup("_SWS_SHOWMASTER")
            if cmd_show ~= 0 then reaper.Main_OnCommand(cmd_show, 0) end
          elseif was_setup and not is_setup then
            -- Switching FROM Setup: hide master
            local cmd_hide = reaper.NamedCommandLookup("_SWS_HIDEMASTER")
            if cmd_hide ~= 0 then reaper.Main_OnCommand(cmd_hide, 0) end
          end
          
          if name == "Setup" then
            -- Setup tab: no track selection or special handling needed
            close_midi_editor_if_not_inline()
            -- Close all floating FX windows
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
          elseif name == "Vocals" then
            select_and_scroll_track_by_name(VOCALS_TRACKS[VOCALS_MODE], 40818, 40726)
          elseif name == "Venue" then
            select_and_scroll_track_by_name(VENUE_TRACKS[VENUE_MODE], 40818, 40726)
          elseif name == "Overdrive" then
            close_midi_editor_if_not_inline()
            -- Don't select any track - prevents selection→tab follow from switching away
          elseif name == "Keys" and PRO_KEYS_ACTIVE then
            -- Pro Keys mode: open MIDI editor for the appropriate Pro Keys track
            local diff_map = { Expert="X", Hard="H", Medium="M", Easy="E" }
            local diff_key = diff_map[ACTIVE_DIFF] or "X"
            local trackname = PRO_KEYS_TRACKS[diff_key]
            select_and_scroll_track_by_name(trackname, 40818, 40726)
          else
            close_midi_editor_if_not_inline()
            -- Only select track if user didn't already select one for this tab
            local sel_tr = reaper.GetSelectedTrack(0, 0)
            local sel_name = sel_tr and select(2, reaper.GetTrackName(sel_tr))
            local sel_tab = sel_name and TRACK_TO_TAB[sel_name]
            if sel_tab ~= name then
              select_track_for_tab(name)
            end
            -- Open floating FX windows when switching from Setup to instrument tabs
            -- Just open them without repositioning - screenset #1 already positioned them correctly
            -- Using get_master_geom() here would apply the SAVED positions from Overdrive tab
            if was_setup then
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
          -- Only run Encore preview when switching to or from Vocals (not during startup)
          if not FCP_STARTUP_MODE and (was_vocals or is_vocals) then
            start_encore_vox_preview()
          end
          -- Run Venue Preview when switching to or from Venue tab (not during startup)
          if not FCP_STARTUP_MODE and (was_venue or is_venue) then
            start_venue_preview()
          end
          -- Run Pro Keys Preview when switching to or from Pro Keys mode (not during startup)
          local is_pro_keys = (name == "Keys" and PRO_KEYS_ACTIVE)
          local was_pro_keys = (last_tab == "Keys" and PRO_KEYS_ACTIVE)
          if not FCP_STARTUP_MODE and (was_pro_keys or is_pro_keys) then
            start_pro_keys_preview()
          end
          WANT_CENTER_ON_TAB = true
          LAST_SEEN_TAB = name
          
          -- Ensure track zoom to max height is enabled after tab switch (skip for Setup)
          if name ~= "Setup" then
            local zoom_cmd = 40113  -- View: Toggle track zoom to maximum height
            if reaper.GetToggleCommandState(zoom_cmd) == 0 then
              reaper.Main_OnCommand(zoom_cmd, 0)
            end
          end
          
          -- Give focus back after the tab switch has completed
          reaper.defer(redirect_focus_after_click)
        end
        ImGui.ImGui_EndTabItem(ctx)
      end
      
      -- Show tooltip on hover for instrument tabs (positioned below tab, left edge at window left)
      if ImGui.ImGui_IsItemHovered(ctx) then
        if name == "Drums" or name == "Bass" or name == "Guitar" or name == "Keys" then
          local display_name = name
          if name == "Keys" and PRO_KEYS_ACTIVE then
            display_name = "Pro Keys"
          end
          local pct_text = tostring(p) .. "%"
          
          local tooltip_w = 194  -- Fixed width for tooltip
          
          -- Position: below the tab, left edge at window left edge
          local win_x, _ = ImGui.ImGui_GetWindowPos(ctx)
          local _, item_bottom = ImGui.ImGui_GetItemRectMax(ctx)
          
          ImGui.ImGui_SetNextWindowPos(ctx, win_x, item_bottom + 5)
          ImGui.ImGui_SetNextWindowSize(ctx, tooltip_w, 0)  -- 0 height = auto
          
          ImGui.ImGui_BeginTooltip(ctx)
          
          -- Left-aligned instrument name
          ImGui.ImGui_Text(ctx, display_name .. " Progress:")
          
          -- Right-aligned percentage on same line, colored by weighted percentage
          ImGui.ImGui_SameLine(ctx)
          local avail_w = ImGui.ImGui_GetContentRegionAvail(ctx)
          local pct_w = ImGui.ImGui_CalcTextSize(ctx, pct_text)
          ImGui.ImGui_SetCursorPosX(ctx, ImGui.ImGui_GetCursorPosX(ctx) + avail_w - pct_w)
          
          local pct_col = pct_scaled_u32(p, 1.0, 1.0)
          ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), pct_col)
          ImGui.ImGui_Text(ctx, pct_text)
          ImGui.ImGui_PopStyleColor(ctx)
          
          -- Show calculation breakdown
          ImGui.ImGui_Separator(ctx)
          local diffs, weights
          if name == "Keys" and PRO_KEYS_ACTIVE then
            diffs = { "Pro X", "Pro H", "Pro M", "Pro E" }
            weights = { 50, 25, 15, 10 }
          else
            diffs = { "Expert", "Hard", "Medium", "Easy" }
            weights = { 50, 25, 15, 10 }
          end
          for i, diff in ipairs(diffs) do
            local diff_p = diff_pct(name, diff)
            local calc_text = string.format("%s (%d%%): %d%%", diff, weights[i], diff_p)
            ImGui.ImGui_Text(ctx, calc_text)
          end
          
          ImGui.ImGui_EndTooltip(ctx)
        elseif name == "Vocals" or name == "Venue" or name == "Overdrive" then
          local display_name = name
          local tooltip_pct
          local camera_pct, lighting_pct  -- For Venue calculation breakdown
          local vocals_breakdown = {}  -- For Vocals calculation breakdown {track, pct, is_empty}
          if name == "Overdrive" then
            tooltip_pct = overdrive_completion_pct()
          elseif name == "Venue" then
            -- Venue uses 50/50 average of Camera and Lighting
            camera_pct = diff_pct("Venue", "Camera")
            lighting_pct = diff_pct("Venue", "Lighting")
            tooltip_pct = math.floor((camera_pct + lighting_pct) / 2)
          elseif name == "Vocals" then
            -- Vocals uses equal weighting for non-empty tracks
            local vocals_tracks = {"H1", "H2", "H3", "V"}
            local total_pct = 0
            local track_count = 0
            for _, vt in ipairs(vocals_tracks) do
              local is_empty = is_all_empty("Vocals", vt)
              local pct = diff_pct("Vocals", vt)
              table.insert(vocals_breakdown, {track = vt, pct = pct, is_empty = is_empty})
              if not is_empty then
                total_pct = total_pct + pct
                track_count = track_count + 1
              end
            end
            if track_count > 0 then
              tooltip_pct = math.floor(total_pct / track_count)
            else
              tooltip_pct = 0
            end
          end
          local pct_text = tostring(tooltip_pct) .. "%"
          
          local tooltip_w = 194  -- Fixed width for tooltip
          
          -- Position: below the tab, left edge at window left edge
          local win_x, _ = ImGui.ImGui_GetWindowPos(ctx)
          local _, item_bottom = ImGui.ImGui_GetItemRectMax(ctx)
          
          ImGui.ImGui_SetNextWindowPos(ctx, win_x, item_bottom + 5)
          ImGui.ImGui_SetNextWindowSize(ctx, tooltip_w, 0)  -- 0 height = auto
          
          ImGui.ImGui_BeginTooltip(ctx)
          
          -- Left-aligned tab name
          ImGui.ImGui_Text(ctx, display_name .. " Progress:")
          
          -- Right-aligned percentage on same line, colored by percentage
          ImGui.ImGui_SameLine(ctx)
          local avail_w = ImGui.ImGui_GetContentRegionAvail(ctx)
          local pct_w = ImGui.ImGui_CalcTextSize(ctx, pct_text)
          ImGui.ImGui_SetCursorPosX(ctx, ImGui.ImGui_GetCursorPosX(ctx) + avail_w - pct_w)
          
          local pct_col = pct_scaled_u32(tooltip_pct, 1.0, 1.0)
          ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), pct_col)
          ImGui.ImGui_Text(ctx, pct_text)
          ImGui.ImGui_PopStyleColor(ctx)
          
          -- Show calculation breakdown
          ImGui.ImGui_Separator(ctx)
          if name == "Venue" then
            ImGui.ImGui_Text(ctx, string.format("Camera (50%%): %d%%", camera_pct))
            ImGui.ImGui_Text(ctx, string.format("Lighting (50%%): %d%%", lighting_pct))
          elseif name == "Vocals" then
            -- Count non-empty tracks for weight display
            local non_empty_count = 0
            for _, vb in ipairs(vocals_breakdown) do
              if not vb.is_empty then non_empty_count = non_empty_count + 1 end
            end
            local weight_pct = non_empty_count > 0 and math.floor(100 / non_empty_count) or 0
            for _, vb in ipairs(vocals_breakdown) do
              if vb.is_empty then
                ImGui.ImGui_Text(ctx, string.format("%s: Empty", vb.track))
              else
                ImGui.ImGui_Text(ctx, string.format("%s (%d%%): %d%%", vb.track, weight_pct, vb.pct))
              end
            end
          elseif name == "Overdrive" then
            ImGui.ImGui_Text(ctx, "Based on OV + Fill placement")
          end
          
          ImGui.ImGui_EndTooltip(ctx)
        end
      end

      ImGui.ImGui_PopStyleColor(ctx); ImGui.ImGui_PopStyleColor(ctx); ImGui.ImGui_PopStyleColor(ctx)
    end
    ImGui.ImGui_EndTabBar(ctx)
  end
  ImGui.ImGui_EndGroup(ctx)

  -- Decrement force select counter
  if force_select_frames > 0 then
    force_select_frames = force_select_frames - 1
    if force_select_frames == 0 then
      force_select_tab = nil
    end
  end

  -- Underline tabs
  local dl          = ImGui.ImGui_GetWindowDrawList(ctx)
  local win_x, _    = ImGui.ImGui_GetWindowPos(ctx)
  local win_w       = select(1, ImGui.ImGui_GetWindowSize(ctx))
  local pad         = 4
  local x1          = win_x + pad
  local x2          = win_x + win_w - pad
  local _, group_y2 = ImGui.ImGui_GetItemRectMax(ctx)
  local y           = group_y2 - 1
  ImGui.ImGui_DrawList_AddLine(dl, x1, y, x2, y, col, 2.0)
end

function Progress_UI_ForceSelectTab(tab_name, frames)
  force_select_tab = tab_name
  force_select_frames = frames or 3
end