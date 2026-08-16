-- fcp_tracker_ui_tabs.lua
-- Tab bar rendering and tab switching logic
-- Requires: fcp_tracker_ui_dock.lua, fcp_tracker_ui_helpers.lua,
--           fcp_tracker_ui_tooltips.lua

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

-- Tab-change orchestration: screenset + floating FX + MCP visibility.
-- was_tab / was_pro_keys_active must be the pre-mutation snapshot.
function handle_tab_height_switch(ctx, new_tab, was_tab, was_pro_keys_active, force_screenset)
  -- Skip during startup - main_loop handles initial screenset load
  if FCP_STARTUP_MODE then return end

  -- Skip during project switch - model handles screenset load
  if PROJECT_SWITCH_MODE then return end

  -- Tabs that share Setup-like behavior (no screenset, close MIDI editor, etc.)
  local SETUP_LIKE = { Setup = true, Preferences = true }
  -- Default was_tab to current_tab for callers that didn't pass it.
  was_tab = was_tab or current_tab
  -- Default to the live Keys variant; the refactored path passes the snapshot.
  if was_pro_keys_active == nil then was_pro_keys_active = TABS_BY_NAME["Keys"]:is_pro() end

  -- Determine direction of switch
  local is_switching_to_vocals   = (new_tab == "Vocals"    and was_tab ~= "Vocals")
  local is_switching_from_vocals = (was_tab == "Vocals" and new_tab ~= "Vocals")
  local is_switching_to_ov       = (new_tab == "Overdrive" and was_tab ~= "Overdrive")
  local is_switching_from_ov     = (was_tab == "Overdrive" and new_tab ~= "Overdrive")
  local is_switching_to_venue    = (new_tab == "Venue" and was_tab ~= "Venue")
  local is_switching_from_venue  = (was_tab == "Venue" and new_tab ~= "Venue")
  local is_switching_to_setup    = (SETUP_LIKE[new_tab] and not SETUP_LIKE[was_tab])
  local is_switching_to_pro_keys = (new_tab == "Keys" and TABS_BY_NAME["Keys"]:is_pro() and was_tab ~= "Keys")
  local is_switching_from_pro_keys = (was_tab == "Keys" and was_pro_keys_active and new_tab ~= "Keys")

  -- Instrument tabs: Drums, Bass, Guitar, Keys (but not Pro Keys)
  local instrument_tabs = { Drums = true, Bass = true, Guitar = true }
  -- Keys is only an "instrument tab" if NOT in Pro Keys mode
  if not TABS_BY_NAME["Keys"]:is_pro() then instrument_tabs.Keys = true end
  local is_switching_to_instrument = instrument_tabs[new_tab] and not instrument_tabs[was_tab]

  -- force_screenset treats the source as a different tab (Pro variant flip).
  local is_switching_via_variant = force_screenset

  if is_switching_to_pro_keys or (is_switching_via_variant and new_tab == "Keys" and TABS_BY_NAME["Keys"]:is_pro()) then
    if CMD_SCREENSET_LOAD_PRO_KEYS and CMD_SCREENSET_LOAD_PRO_KEYS > 0 then
      reaper.Main_OnCommand(CMD_SCREENSET_LOAD_PRO_KEYS, 0)
    end
    CENTER_DELAY_FRAMES = 2
  elseif is_switching_to_vocals then
    if CMD_SCREENSET_LOAD_VOCALS and CMD_SCREENSET_LOAD_VOCALS > 0 then
      reaper.Main_OnCommand(CMD_SCREENSET_LOAD_VOCALS, 0)
    end
    VOCALS_NOTE_START = 48
    apply_vocals_note_order(VOCALS_NOTE_START)
    CENTER_DELAY_FRAMES = 2
  elseif is_switching_to_ov then
    if CMD_SCREENSET_LOAD_OV and CMD_SCREENSET_LOAD_OV > 0 then
      reaper.Main_OnCommand(CMD_SCREENSET_LOAD_OV, 0)
    end
    CENTER_DELAY_FRAMES = 2
  elseif is_switching_to_venue then
    if CMD_SCREENSET_LOAD_VENUE and CMD_SCREENSET_LOAD_VENUE > 0 then
      reaper.Main_OnCommand(CMD_SCREENSET_LOAD_VENUE, 0)
    end
    CENTER_DELAY_FRAMES = 2
  elseif is_switching_to_setup then
    -- Switching to Setup: no screenset load needed
    CENTER_DELAY_FRAMES = 0
  elseif is_switching_to_instrument or (is_switching_via_variant and new_tab == "Keys" and not TABS_BY_NAME["Keys"]:is_pro()) then
    -- Switching to Drums/Bass/Guitar/Keys from non-instrument tab, OR
    -- variant flip on Keys from pro to regular
    if CMD_SCREENSET_LOAD_OTHERS and CMD_SCREENSET_LOAD_OTHERS > 0 then
      reaper.Main_OnCommand(CMD_SCREENSET_LOAD_OTHERS, 0)
    end
    CENTER_DELAY_FRAMES = 2
    -- Don't trigger SAVE_RUN here - FX windows are positioned via hard_apply_for_track
    -- when switching from Setup, and we don't want to override those positions
  elseif is_switching_from_vocals or is_switching_from_ov or is_switching_from_venue or is_switching_from_pro_keys then
    -- Switching from Vocals/OV/Venue/Pro Keys to another special tab (handled above catches Setup/instruments)
    if CMD_SCREENSET_LOAD_OTHERS and CMD_SCREENSET_LOAD_OTHERS > 0 then
      reaper.Main_OnCommand(CMD_SCREENSET_LOAD_OTHERS, 0)
    end
    CENTER_DELAY_FRAMES = 2
  end

  -- Floating FX open/close per-tab preference; origin/destination resolved
  -- from the pre/post-mutation variants so Pro Keys tracks separately.
  local dest_fx_tab   = (new_tab == "Keys" and TABS_BY_NAME["Keys"]:is_pro()) and "Pro Keys" or new_tab
  local origin_fx_tab = (was_tab == "Keys" and was_pro_keys_active) and "Pro Keys" or was_tab
  local dest_wants_fx   = get_show_floating_fx(dest_fx_tab)
  local dest_wants_just = get_show_just_fx(dest_fx_tab)
  local origin_has_fx   = get_show_floating_fx(origin_fx_tab)
  local origin_has_just = get_show_just_fx(origin_fx_tab)
  -- Save Just FX geometry before switching away
  if origin_has_just then save_just_fx_geom(origin_fx_tab) end
  if dest_wants_just then
    open_just_instrument_fx(dest_fx_tab)
  elseif dest_wants_fx and not origin_has_fx and not origin_has_just then
    open_floating_fx_and_align()
  elseif dest_wants_fx and (origin_has_fx or origin_has_just) then
    -- Destination wants all FX - ensure all are open and re-align
    open_floating_fx_and_align()
  elseif not dest_wants_fx then
    -- Always close when destination doesn't want FX (screensets may have opened them)
    close_floating_fx()
  end

  -- Update MCP visibility: show audio tracks, hide MIDI-only tracks
  set_mcp_visibility_for_audio_tracks()
end

-- Tab bar row with per-tab coloring and tooltips
function tabs_row(ctx, redirect_focus_after_click)
  local PAIR_W = get_PAIR_W()
  
  -- Calculate underline color based on weighted percentage for instrument tabs
  local underline_pct
  if current_tab == "Setup" then
    underline_pct = 50  -- Neutral gray for Setup tab
  elseif current_tab == "Preferences" then
    underline_pct = prefs_test_pct()
  elseif current_tab == "Drums" or current_tab == "Bass" or current_tab == "Guitar" or current_tab == "Keys" then
    underline_pct = weighted_tab_pct(current_tab)
  elseif current_tab == "Overdrive" then
    underline_pct = overdrive_completion_pct()
  else
    -- Use the thin Tab wrapper for the active mode key (canonical form).
    local cur_obj = current_tab_obj and current_tab_obj() or nil
    local cur_mode = cur_obj and cur_obj:current_mode() or nil
    local current_diff = (cur_mode and cur_mode.key) or (cur_obj and cur_obj:current_mode_key())
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
      elseif name == "Preferences" then
        p = prefs_test_pct()
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
        -- Vocals uses fixed weighting: H1=50%, H2=20%, H3=20%, V=10% (only non-empty tracks count, weights renormalized)
        local vocals_weights = {H1=0.50, H2=0.20, H3=0.20, V=0.10}
        local vocals_tracks = {"H1", "H2", "H3", "V"}
        local total_pct = 0
        local weight_sum = 0
        for _, vt in ipairs(vocals_tracks) do
          if not is_all_empty("Vocals", vt) then
            weight_sum = weight_sum + vocals_weights[vt]
          end
        end
        if weight_sum > 0 then
          for _, vt in ipairs(vocals_tracks) do
            if not is_all_empty("Vocals", vt) then
              total_pct = total_pct + diff_pct("Vocals", vt) * (vocals_weights[vt] / weight_sum)
            end
          end
          p = math.floor(total_pct)
        else
          p = 0
        end
      else
        local m_obj = current_tab_obj and current_tab_obj()
        local mkey = (m_obj and m_obj:current_mode_key()) or ACTIVE_DIFF
        p = diff_pct(name, mkey)
      end
      local ci = pct_scaled_u32(p, 0.46, 1.0)
      local ch = pct_scaled_u32(p, 0.74, 1.0)
      local ca = pct_scaled_u32(p, 0.86, 1.0)

      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Tab(),        ci)
      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_TabHovered(), ch)
      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_TabSelected(),ca)

      -- Force selection for multiple frames on startup
      local flags = ImGui.ImGui_TabItemFlags_NoTooltip()
      if force_select_tab == name and force_select_frames > 0 then
        flags = flags | ImGui.ImGui_TabItemFlags_SetSelected()
      end
      
      -- Label reflects the Keys tab's own variant, not the current tab's.
      local display_name = name
      if name == "Keys" and TABS_BY_NAME["Keys"]:is_pro() then
        display_name = "Pro Keys"
      end
      
      if ImGui.ImGui_BeginTabItem(ctx, display_name .. "###" .. name, nil, flags) then
        if current_tab ~= name then
          -- set_active_tab is the single entry point for tab changes (side
          -- effects centralized in apply_tab_change). Pass the variant explicitly.
          if set_active_tab then
            local dest_variant = (name == "Keys") and TABS_BY_NAME[name]:current_variant_key() or nil
            set_active_tab(name, dest_variant, nil)
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
          if name == "Keys" and TABS_BY_NAME["Keys"]:is_pro() then
            display_name = "Pro Keys"
          end
          local _, item_bottom = ImGui.ImGui_GetItemRectMax(ctx)
          -- Both variants store canonical Expert/Hard/Medium/Easy, so labels match.
          local diffs   = { "Expert", "Hard", "Medium", "Easy" }
          local weights = { 50, 25, 15, 10 }
          draw_tab_tooltip(ctx, {
            item_bottom_y = item_bottom,
            key           = "tab:" .. name,
            header        = display_name .. " Progress:",
            pct           = p,
          }, function(c)
            ImGui.ImGui_Separator(c)
            for i, diff in ipairs(diffs) do
              local diff_p = diff_pct(name, diff)
              local label_text = string.format("%s (%d%%)", diff, weights[i])
              local value_text = string.format("%d%%", diff_p)
              ImGui.ImGui_Text(c, label_text)
              ImGui.ImGui_SameLine(c)
              local avail_w2 = ImGui.ImGui_GetContentRegionAvail(c)
              local val_w = ImGui.ImGui_CalcTextSize(c, value_text)
              ImGui.ImGui_SetCursorPosX(c, ImGui.ImGui_GetCursorPosX(c) + avail_w2 - val_w)
              ImGui.ImGui_Text(c, value_text)
            end
          end)
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
            -- Vocals uses fixed weighting: H1=50%, H2=20%, H3=20%, V=10% (renormalized for non-empty tracks)
            local vocals_weights = {H1=0.50, H2=0.20, H3=0.20, V=0.10}
            local vocals_tracks = {"H1", "H2", "H3", "V"}
            local total_pct = 0
            local weight_sum = 0
            for _, vt in ipairs(vocals_tracks) do
              local is_empty = is_all_empty("Vocals", vt)
              local pct = diff_pct("Vocals", vt)
              table.insert(vocals_breakdown, {track = vt, pct = pct, is_empty = is_empty, weight = vocals_weights[vt]})
              if not is_empty then
                weight_sum = weight_sum + vocals_weights[vt]
              end
            end
            if weight_sum > 0 then
              for _, vb in ipairs(vocals_breakdown) do
                if not vb.is_empty then
                  total_pct = total_pct + vb.pct * (vb.weight / weight_sum)
                end
              end
              tooltip_pct = math.floor(total_pct)
            else
              tooltip_pct = 0
            end
          end
          local _, item_bottom = ImGui.ImGui_GetItemRectMax(ctx)
          draw_tab_tooltip(ctx, {
            item_bottom_y = item_bottom,
            key           = "tab:" .. name,
            header        = display_name .. " Progress:",
            pct           = tooltip_pct,
          }, function(c)
            ImGui.ImGui_Separator(c)
            if name == "Venue" then
              local venue_items = {
                {label = "Camera (50%)", value = string.format("%d%%", camera_pct)},
                {label = "Lighting (50%)", value = string.format("%d%%", lighting_pct)},
              }
              for _, vi in ipairs(venue_items) do
                ImGui.ImGui_Text(c, vi.label)
                ImGui.ImGui_SameLine(c)
                local avail_w2 = ImGui.ImGui_GetContentRegionAvail(c)
                local val_w = ImGui.ImGui_CalcTextSize(c, vi.value)
                ImGui.ImGui_SetCursorPosX(c, ImGui.ImGui_GetCursorPosX(c) + avail_w2 - val_w)
                ImGui.ImGui_Text(c, vi.value)
              end
            elseif name == "Vocals" then
              -- Show fixed weights (renormalized for non-empty tracks)
              local weight_sum = 0
              for _, vb in ipairs(vocals_breakdown) do
                if not vb.is_empty then weight_sum = weight_sum + vb.weight end
              end
              for _, vb in ipairs(vocals_breakdown) do
                if vb.is_empty then
                  local empty_text = "Empty"
                  ImGui.ImGui_Text(c, vb.track)
                  ImGui.ImGui_SameLine(c)
                  local avail_w2 = ImGui.ImGui_GetContentRegionAvail(c)
                  local val_w = ImGui.ImGui_CalcTextSize(c, empty_text)
                  ImGui.ImGui_SetCursorPosX(c, ImGui.ImGui_GetCursorPosX(c) + avail_w2 - val_w)
                  ImGui.ImGui_Text(c, empty_text)
                else
                  local display_w = weight_sum > 0 and math.floor(vb.weight / weight_sum * 100 + 0.5) or 0
                  local label_text = string.format("%s (%d%%)", vb.track, display_w)
                  local value_text = string.format("%d%%", vb.pct)
                  ImGui.ImGui_Text(c, label_text)
                  ImGui.ImGui_SameLine(c)
                  local avail_w2 = ImGui.ImGui_GetContentRegionAvail(c)
                  local val_w = ImGui.ImGui_CalcTextSize(c, value_text)
                  ImGui.ImGui_SetCursorPosX(c, ImGui.ImGui_GetCursorPosX(c) + avail_w2 - val_w)
                  ImGui.ImGui_Text(c, value_text)
                end
              end
            elseif name == "Overdrive" then
              ImGui.ImGui_Text(c, "Based on OV + Fill placement")
            end
          end)
        elseif name == "Preferences" then
          local pref_pct = prefs_test_pct()
          local _, item_bottom = ImGui.ImGui_GetItemRectMax(ctx)
          draw_tab_tooltip(ctx, {
            item_bottom_y = item_bottom,
            key           = "tab:Preferences",
            header        = "Preferences Progress:",
            pct           = pref_pct,
          }, function(c)
            ImGui.ImGui_Separator(c)
            local action_labels = {
              {key = "encore_vox",       label = "Encore Vox Preview"},
              {key = "lyrics_clip",      label = "Lyrics Clipboard"},
              {key = "spectracular",     label = "Spectracular Stereo"},
              {key = "venue_preview",    label = "Venue Preview"},
              {key = "pro_keys_preview", label = "Pro Keys Preview"},
            }
            for _, entry in ipairs(action_labels) do
              local state = PREFS_TEST_STATE and PREFS_TEST_STATE[entry.key]
              local status
              if state == true then
                status = "Pass"
              elseif state == false then
                status = "Fail"
              else
                status = "Untested"
              end
              ImGui.ImGui_Text(c, entry.label)
              ImGui.ImGui_SameLine(c)
              local avail_w2 = ImGui.ImGui_GetContentRegionAvail(c)
              local status_w = ImGui.ImGui_CalcTextSize(c, status)
              ImGui.ImGui_SetCursorPosX(c, ImGui.ImGui_GetCursorPosX(c) + avail_w2 - status_w)
              ImGui.ImGui_Text(c, status)
            end
          end)
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