-- fcp_tracker_ui_header.lua
-- Header row with difficulty buttons, mode buttons, and region count
-- Requires: fcp_tracker_ui_widgets.lua, fcp_tracker_ui_helpers.lua,
--           fcp_tracker_ui_tooltips.lua

local reaper = reaper
local ImGui  = reaper

-- global single-select state across tabs: 0 = none, 1 = A (Toms/HOPOs), 2 = B (Rolls/Trills)
PAIR_MODE = PAIR_MODE or 0

-- Vocals note row range: start note (range is start .. start+18)
VOCALS_NOTE_START = VOCALS_NOTE_START or 48
local VOCALS_NOTE_MIN = 36
local VOCALS_NOTE_MAX = 66
local VOCALS_NOTE_STEP = 3

-- Listen icon dimensions. LISTEN_SLOT_W is the per-slot footprint
-- (BTN_W + icon + gaps) so the width is defined in exactly one place.
local LISTEN_ICON_SIZE       = 14
local LISTEN_ICON_LEFT_GAP   = 1
local LISTEN_ICON_RIGHT_GAP  = 2
local LISTEN_SLOT_W          = BTN_W + LISTEN_ICON_LEFT_GAP + LISTEN_ICON_SIZE + LISTEN_ICON_RIGHT_GAP

-- Metrics (initialized in Progress_UI_Init)
BUTTONS_COL_W = nil

-- Standard save entry point: resolve the variant from the tab's own
-- _variant_key and call save_cell_state_v2.
local function save(tab, diff, ri, state)
  local obj = TABS_BY_NAME and TABS_BY_NAME[tab]
  local variant = (obj and obj.current_variant_key) and obj:current_variant_key() or "regular"
  save_cell_state_v2(tab, variant, diff, ri, state)
end

function init_header_metrics()
  local PAIR_W = get_PAIR_W()
  BUTTONS_COL_W = 4*BTN_W + 8*BTN_GAP + 3*PAIR_W
end

-- Mode/difficulty buttons and region count row
function progress_and_count_row(ctx, redirect_focus_after_click)
  local PAIR_W = get_PAIR_W()
  -- Thin Tab wrapper locals: the single source of truth for active tab/variant/mode.
  local cur_obj = current_tab_obj and current_tab_obj() or nil
  local cur_mode = cur_obj and cur_obj:current_mode() or nil
  local cur_trackname = cur_mode and cur_mode.trackname or nil
  if ImGui.ImGui_BeginTable(ctx, "progress_row", 2, ImGui.ImGui_TableFlags_SizingFixedFit()) then
    ImGui.ImGui_TableSetupColumn(ctx, "btns",  ImGui.ImGui_TableColumnFlags_WidthFixed(),   BUTTONS_COL_W)
    ImGui.ImGui_TableSetupColumn(ctx, "right", ImGui.ImGui_TableColumnFlags_WidthStretch(), 0.0001)
    ImGui.ImGui_TableNextRow(ctx)

    -- Left column
    ImGui.ImGui_TableNextColumn(ctx)
    do
      local x0 = ImGui.ImGui_GetCursorPosX(ctx)
      local y0 = ImGui.ImGui_GetCursorPosY(ctx)

      if current_tab == "Overdrive" then
        -- Overdrive: No difficulty buttons, just show info text
        ImGui.ImGui_Text(ctx, "Overdrive Phrases")
      elseif current_tab == "Venue" then
        -- Venue: Camera/Lighting buttons
        local labels = {"Camera", "Lighting"}
        local venue_btn_w = PAIR_W * 1.25
        for i, lab in ipairs(labels) do
          ImGui.ImGui_SetCursorPosX(ctx, x0 + (i-1)*(venue_btn_w+BTN_GAP))
          ImGui.ImGui_SetCursorPosY(ctx, y0)
          local track_is_empty = is_all_empty("Venue", lab)
          if DiffSquareButton(ctx, lab, lab, (cur_mode and cur_mode.key == lab or false), venue_btn_w, track_is_empty) then
            -- Disable Sing/Spot mode when clicking Camera/Lighting
            local venue_toggles = TABS_BY_NAME and TABS_BY_NAME["Venue"]
              and TABS_BY_NAME["Venue"]:current_variant().overlay_toggles or nil
            if venue_toggles then
              venue_toggles.sing = false
              venue_toggles.spot = false
            end
            set_active_mode(lab)
            if lab == "Camera" then
              CAMERA_SUB_MODE = 1
              CAMERA_DIRECTED = false
              apply_camera_note_order_and_select(CAMERA_SINGLE_NOTE_ORDER)
            else
              LIGHTING_SUB_MODE = 1
              apply_lighting_note_order_and_select(LIGHTING_POST_NOTE_ORDER)
            end
            WANT_CENTER_ON_TAB = true
            reaper.defer(redirect_focus_after_click)
          end

          -- Tooltip showing percentage (styled like difficulty buttons)
          if ImGui.ImGui_IsItemHovered(ctx) then
            local pct = diff_pct("Venue", lab)
            local _, btn_max_y = ImGui.ImGui_GetItemRectMax(ctx)
            draw_mode_tooltip(ctx, {
              item_bottom_y = btn_max_y,
              key           = "mode:" .. lab,
              header        = lab,
              pct           = pct,
              is_empty      = track_is_empty,
              width         = 140,
            })
          end

          -- Right-click: cycle all cells for this track
          if ImGui.ImGui_IsItemClicked(ctx, 1) then
            -- Disable Sing/Spot mode when clicking Camera/Lighting
            local venue_toggles = TABS_BY_NAME and TABS_BY_NAME["Venue"]
              and TABS_BY_NAME["Venue"]:current_variant().overlay_toggles or nil
            if venue_toggles then
              venue_toggles.sing = false
              venue_toggles.spot = false
            end
            local row = STATE["Venue"] and STATE["Venue"][lab]
            if row then
              -- Count cells in each state
              local has_not_started = false
              local has_in_progress = false
              local has_complete = false
              local all_not_started = true
              local all_empty = true

              for r = 1, #REGIONS do
                local st = row[r] or 0
                if st == 0 then has_not_started = true
                elseif st == 1 then has_in_progress = true; all_not_started = false; all_empty = false
                elseif st == 2 then has_complete = true; all_not_started = false; all_empty = false
                elseif st == 3 then all_not_started = false  -- Empty
                end
                if st ~= 3 then all_empty = false end
                if st ~= 0 then all_not_started = false end
              end

              -- Apply state changes based on priority and save each cell
              if all_empty then
                -- All Empty -> change to Not Started
                for r = 1, #REGIONS do
                  row[r] = 0
                  save("Venue", lab, r, 0)
                end
              elseif all_not_started then
                -- All Not Started -> change to Empty
                for r = 1, #REGIONS do
                  row[r] = 3
                  save("Venue", lab, r, 3)
                end
              elseif has_not_started then
                -- Any Not Started -> change all Not Started to Empty
                for r = 1, #REGIONS do
                  if row[r] == 0 then
                    row[r] = 3
                    save("Venue", lab, r, 3)
                  end
                end
              elseif has_in_progress then
                -- No Not Started, but has In Progress -> change all In Progress to Complete
                for r = 1, #REGIONS do
                  if row[r] == 1 then
                    row[r] = 2
                    save("Venue", lab, r, 2)
                  end
                end
              elseif has_complete then
                -- No Not Started, no In Progress, but has Complete -> change all Complete to In Progress
                for r = 1, #REGIONS do
                  if row[r] == 2 then
                    row[r] = 1
                    save("Venue", lab, r, 1)
                  end
                end
              end
            end
            reaper.defer(redirect_focus_after_click)
          end
        end

        -- Sub-mode buttons depending on Camera or Lighting
        local sub_base_x = x0 + 2*(venue_btn_w+BTN_GAP)
        -- Read Sing/Spot state from the wrapper's overlay_toggles (the new owner).
        local venue_obj = TABS_BY_NAME and TABS_BY_NAME["Venue"]
        local venue_toggles = venue_obj and venue_obj:current_variant().overlay_toggles or nil
        local sing_spot = venue_toggles and (venue_toggles.sing or venue_toggles.spot) or false
        if cur_mode and cur_mode.key == "Camera" then
          ImGui.ImGui_SetCursorPosX(ctx, sub_base_x)
          ImGui.ImGui_SetCursorPosY(ctx, y0)
          sing_spot = venue_toggles and (venue_toggles.sing or venue_toggles.spot) or false

          -- Helper to get current camera note order
          local function cam_note_order(sub, dir)
            if sub == 1 then
              return dir and CAMERA_SINGLE_DIR_NOTE_ORDER or CAMERA_SINGLE_NOTE_ORDER
            else
              return dir and CAMERA_MULTI_DIR_NOTE_ORDER or CAMERA_MULTI_NOTE_ORDER
            end
          end

          -- Single / Multi buttons
          local cam_labels = {"One", "Multi"}
          local cam_widths = {PAIR_W * 0.7, PAIR_W * 0.85}
          local cx = sub_base_x
          for ci, clab in ipairs(cam_labels) do
            ImGui.ImGui_SetCursorPosX(ctx, cx)
            ImGui.ImGui_SetCursorPosY(ctx, y0)
            local cw = cam_widths[ci]
            if PairSquareButton(ctx, clab, CAMERA_SUB_MODE == ci and not sing_spot, cw) then
              if CAMERA_SUB_MODE ~= ci or sing_spot then
                CAMERA_SUB_MODE = ci
                local venue_toggles = TABS_BY_NAME and TABS_BY_NAME["Venue"]
                  and TABS_BY_NAME["Venue"]:current_variant().overlay_toggles or nil
                if venue_toggles then
                  venue_toggles.sing = false
                  venue_toggles.spot = false
                end
                apply_camera_note_order_and_select(cam_note_order(ci, CAMERA_DIRECTED))
              end
              reaper.defer(redirect_focus_after_click)
            end
            cx = cx + cw + BTN_GAP
          end

          -- Directed toggle
          ImGui.ImGui_SetCursorPosX(ctx, cx)
          ImGui.ImGui_SetCursorPosY(ctx, y0)
          if PairSquareButton(ctx, "Directed", CAMERA_DIRECTED and not sing_spot, PAIR_W * 1.25) then
            CAMERA_DIRECTED = not CAMERA_DIRECTED
            local venue_toggles = TABS_BY_NAME and TABS_BY_NAME["Venue"]
              and TABS_BY_NAME["Venue"]:current_variant().overlay_toggles or nil
            if venue_toggles then
              venue_toggles.sing = false
              venue_toggles.spot = false
            end
            apply_camera_note_order_and_select(cam_note_order(CAMERA_SUB_MODE, CAMERA_DIRECTED))
            reaper.defer(redirect_focus_after_click)
          end
        elseif cur_mode and cur_mode.key == "Lighting" then
          local sing_spot = venue_toggles and (venue_toggles.sing or venue_toggles.spot) or false
          local light_labels = {"PostProc", "Lighting", "..."}
          local light_orders = {LIGHTING_POST_NOTE_ORDER, LIGHTING_LIGHT_NOTE_ORDER, LIGHTING_MISC_NOTE_ORDER}
          local light_widths = {PAIR_W * 1.25, PAIR_W * 1.2, PAIR_W * 0.33}
          local lx = sub_base_x
          for li, llab in ipairs(light_labels) do
            ImGui.ImGui_SetCursorPosX(ctx, lx)
            ImGui.ImGui_SetCursorPosY(ctx, y0)
            local lw = light_widths[li]
            if PairSquareButton(ctx, llab, LIGHTING_SUB_MODE == li and not sing_spot, lw) then
              if LIGHTING_SUB_MODE ~= li or sing_spot then
                LIGHTING_SUB_MODE = li
                local venue_toggles = TABS_BY_NAME and TABS_BY_NAME["Venue"]
                  and TABS_BY_NAME["Venue"]:current_variant().overlay_toggles or nil
                if venue_toggles then
                  venue_toggles.sing = false
                  venue_toggles.spot = false
                end
                apply_lighting_note_order_and_select(light_orders[li])
              end
              reaper.defer(redirect_focus_after_click)
            end
            lx = lx + lw + BTN_GAP
          end
        end

      elseif current_tab == "Vocals" then
        -- Vocals: H1/H2/H3/V. Vocals always renders the listen icon,
        -- so the per-slot width is just LISTEN_SLOT_W.
        local labels = {"H1","H2","H3","V"}
        local slot_w = LISTEN_SLOT_W
        local frame_h = ImGui.ImGui_GetFrameHeight(ctx)
        for i, lab in ipairs(labels) do
          local slot_start = x0 + (i-1)*slot_w
          ImGui.ImGui_SetCursorPosX(ctx, slot_start)
          ImGui.ImGui_SetCursorPosY(ctx, y0)
          local track_is_empty = is_all_empty("Vocals", lab)
          if DiffSquareButton(ctx, lab, lab, (cur_mode and cur_mode.key == lab or false), nil, track_is_empty) then
            local ctrl  = ImGui.ImGui_IsKeyDown(ctx, ImGui.ImGui_Mod_Ctrl())
            local shift = ImGui.ImGui_IsKeyDown(ctx, ImGui.ImGui_Mod_Shift())
            local alt   = ImGui.ImGui_IsKeyDown(ctx, ImGui.ImGui_Mod_Alt())

            if ctrl or shift or alt then
              -- Modifier held: toggle MIDI editor visibility for this track
              local trackname = VOCALS_TRACKS[lab]
              local n = reaper.CountTracks(0)
              for ti = 0, n - 1 do
                local tr = reaper.GetTrack(0, ti)
                local ok, tname = reaper.GetTrackName(tr)
                if ok and tname == trackname then
                  local _, current_flags = reaper.MIDIEditorFlagsForTrack(tr, 0, 0, false)
                  local new_flags
                  if (current_flags & 1) == 1 then
                    new_flags = current_flags - 1
                  else
                    new_flags = current_flags + 1
                  end
                  reaper.MIDIEditorFlagsForTrack(tr, 0, new_flags, true)
                  break
                end
              end
            else
              set_active_mode(lab)
              -- Re-read trackname from the wrapper after the mode mutation
              local new_mode = current_tab_obj and current_tab_obj():current_mode() or nil
              local trackname = new_mode and new_mode.trackname or nil
              if trackname then
                select_and_scroll_track_by_name(trackname, 40818, 40726)
              end
              WANT_CENTER_ON_TAB = true
            end
            reaper.defer(redirect_focus_after_click)
          end

          -- Tooltip before the icon so IsItemHovered queries the button, not the icon.
          if ImGui.ImGui_IsItemHovered(ctx) then
            local pct = diff_pct("Vocals", lab)
            local _, btn_max_y = ImGui.ImGui_GetItemRectMax(ctx)
            draw_mode_tooltip(ctx, {
              item_bottom_y = btn_max_y,
              key           = "mode:" .. lab,
              header        = lab,
              pct           = pct,
              is_empty      = track_is_empty,
              width         = 120,
            })
          end

          -- Right-click: cycle all cells. Placed before the icon so
          -- IsItemClicked (ctx, 1) queries the button, not the icon.
          if ImGui.ImGui_IsItemClicked(ctx, 1) then
            local row = STATE["Vocals"] and STATE["Vocals"][lab]
            if row then
              -- Count cells in each state
              local has_not_started = false
              local has_in_progress = false
              local has_complete = false
              local all_not_started = true
              local all_empty = true

              for r = 1, #REGIONS do
                local st = row[r] or 0
                if st == 0 then has_not_started = true
                elseif st == 1 then has_in_progress = true; all_not_started = false; all_empty = false
                elseif st == 2 then has_complete = true; all_not_started = false; all_empty = false
                elseif st == 3 then all_not_started = false  -- Empty
                end
                if st ~= 3 then all_empty = false end
                if st ~= 0 then all_not_started = false end
              end

              -- Apply state changes and save each cell
              if all_empty then
                -- All Empty -> change to Not Started
                for r = 1, #REGIONS do
                  row[r] = 0
                  save("Vocals", lab, r, 0)
                end
              elseif has_not_started or has_in_progress then
                -- Combined: Not Started -> Empty, In Progress -> Complete
                for r = 1, #REGIONS do
                  local st = row[r] or 0
                  if st == 0 then
                    row[r] = 3
                    save("Vocals", lab, r, 3)
                  elseif st == 1 then
                    row[r] = 2
                    save("Vocals", lab, r, 2)
                  end
                end
              elseif has_complete then
                -- Only Complete remaining -> toggle to In Progress
                for r = 1, #REGIONS do
                  if row[r] == 2 then
                    row[r] = 1
                    save("Vocals", lab, r, 1)
                  end
                end
              end
            end
            reaper.defer(redirect_focus_after_click)
          end

          -- Listen indicator 1px right of the button; SameLine anchors
          -- it on the row so the icon doesn't wrap.
          ImGui.ImGui_SameLine(ctx, 0, 0)
          ImGui.ImGui_SetCursorPosX(ctx, slot_start + BTN_W + LISTEN_ICON_LEFT_GAP)
          ListenIcon_Draw(ctx, "listen_icon_" .. lab:lower(),
                          VOCALS_TRACKS[lab], LISTEN_ICON_SIZE, frame_h, nil,
                          redirect_focus_after_click)
        end

        -- Up/Down arrow buttons for shifting Vocals note row range
        local arrow_w = ImGui.ImGui_GetFrameHeight(ctx)  -- square: width == height
        -- Each of the four preceding button+icon pairs is slot_w wide;
        -- add one trailing BTN_GAP to clear the last pair.
        local arrow_base_x = x0 + 4*slot_w + BTN_GAP
        local saved_col_text = COL_TEXT

        -- Up arrow
        ImGui.ImGui_SetCursorPosX(ctx, arrow_base_x)
        ImGui.ImGui_SetCursorPosY(ctx, y0)
        local at_max = VOCALS_NOTE_START >= VOCALS_NOTE_MAX
        if at_max then COL_TEXT = 0x555555FF end
        if PairSquareButton(ctx, "\xe2\x96\xb2", false, arrow_w, 0.6) and not at_max then
          VOCALS_NOTE_START = math.min(VOCALS_NOTE_START + VOCALS_NOTE_STEP, VOCALS_NOTE_MAX)
          apply_vocals_note_order(VOCALS_NOTE_START)
          reaper.defer(redirect_focus_after_click)
        end
        if at_max then COL_TEXT = saved_col_text end

        -- Down arrow
        ImGui.ImGui_SetCursorPosX(ctx, arrow_base_x + arrow_w + BTN_GAP)
        ImGui.ImGui_SetCursorPosY(ctx, y0)
        local at_min = VOCALS_NOTE_START <= VOCALS_NOTE_MIN
        if at_min then COL_TEXT = 0x555555FF end
        if PairSquareButton(ctx, "\xe2\x96\xbc", false, arrow_w, 0.75) and not at_min then
          VOCALS_NOTE_START = math.max(VOCALS_NOTE_START - VOCALS_NOTE_STEP, VOCALS_NOTE_MIN)
          apply_vocals_note_order(VOCALS_NOTE_START)
          reaper.defer(redirect_focus_after_click)
        end
        if at_min then COL_TEXT = saved_col_text end

      else
        -- Difficulties X/H/M/E
        local map = { "X","H","M","E" }
        local toD = { X="Expert", H="Hard", M="Medium", E="Easy" }
        local toU = { X="EXPERT", H="HARD", M="MEDIUM", E="EASY" }
        -- Gate for the Pro Keys listen icons: only on Keys tab when pro.
        local show_pro_listen_icons = (current_tab == "Keys"
                                       and cur_obj and cur_obj:is_pro()) or false
        -- Slot width is LISTEN_SLOT_W when icons show, else BTN_W + BTN_GAP.
        local slot_w = show_pro_listen_icons and LISTEN_SLOT_W or (BTN_W + BTN_GAP)
        local frame_h = ImGui.ImGui_GetFrameHeight(ctx)
        for i, k in ipairs(map) do
          local slot_start = x0 + (i-1)*slot_w
          ImGui.ImGui_SetCursorPosX(ctx, slot_start)
          ImGui.ImGui_SetCursorPosY(ctx, y0)
          if DiffSquareButton(ctx, k, toD[k], toD[k]==(cur_obj and cur_obj:current_mode_key() or "")) then
            PAIR_MODE   = 0
            set_active_mode(toD[k])
            reaper.SetExtState(EXT_NS, EXT_REQ, toU[k], false)

            -- If Pro Keys mode is active on Keys tab, switch to appropriate Pro Keys track
            if cur_obj and cur_obj:is_pro() then
              -- Re-read trackname from the wrapper after the mode mutation
              local new_mode = current_tab_obj and current_tab_obj():current_mode() or nil
              local trackname = new_mode and new_mode.trackname or nil
              if trackname then
                select_and_scroll_track_by_name(trackname)
              end
              compute_pro_keys()
            end

            reaper.defer(redirect_focus_after_click)
          end

          -- Right-click: cycle cells. Placed before the icon so
          -- IsItemClicked (ctx, 1) queries the button, not the icon.
          if ImGui.ImGui_IsItemClicked(ctx, 1) then
            -- Pro Keys reads from STATE["Keys"]["pro"][mkey] (canonical mode key)
            if cur_obj and cur_obj:is_pro() then
              local mkey = toD[k]  -- "Expert"/"Hard"/"Medium"/"Easy"
              local row = STATE["Keys"] and STATE["Keys"]["pro"] and STATE["Keys"]["pro"][mkey]
              if row then
                -- Count cells in each state
                local has_not_started = false
                local has_in_progress = false
                local has_complete = false
                local all_not_started = true
                local all_empty = true

                for r = 1, #REGIONS do
                  local st = row[r] or 0
                  if st == 0 then has_not_started = true
                  elseif st == 1 then has_in_progress = true; all_not_started = false; all_empty = false
                  elseif st == 2 then has_complete = true; all_not_started = false; all_empty = false
                  elseif st == 3 then all_not_started = false  -- Empty
                  end
                  if st ~= 3 then all_empty = false end
                  if st ~= 0 then all_not_started = false end
                end

                -- Apply state changes and save each cell
                if all_empty then
                  for r = 1, #REGIONS do
                    row[r] = 0
                    save("Keys", mkey, r, 0)
                  end
                elseif has_not_started or has_in_progress then
                  -- Combined: Not Started -> Empty, In Progress -> Complete
                  for r = 1, #REGIONS do
                    local st = row[r] or 0
                    if st == 0 then
                      row[r] = 3
                      save("Keys", mkey, r, 3)
                    elseif st == 1 then
                      row[r] = 2
                      save("Keys", mkey, r, 2)
                    end
                  end
                elseif has_complete then
                  for r = 1, #REGIONS do
                    if (row[r] or 0) == 2 then
                      row[r] = 1
                      save("Keys", mkey, r, 1)
                    end
                  end
                end
              end
            else
              -- Standard instrument tabs use STATE[tab][diff]
              local diff_name = toD[k]
              local row = STATE[current_tab] and STATE[current_tab][diff_name]
              if row then
                -- Count cells in each state
                local has_not_started = false
                local has_in_progress = false
                local has_complete = false
                local all_not_started = true
                local all_empty = true

                for r = 1, #REGIONS do
                  local st = row[r] or 0
                  if st == 0 then has_not_started = true
                  elseif st == 1 then has_in_progress = true; all_not_started = false; all_empty = false
                  elseif st == 2 then has_complete = true; all_not_started = false; all_empty = false
                  elseif st == 3 then all_not_started = false  -- Empty
                  end
                  if st ~= 3 then all_empty = false end
                  if st ~= 0 then all_not_started = false end
                end

                -- Apply state changes and save each cell
                if all_empty then
                  for r = 1, #REGIONS do
                    row[r] = 0
                    save(current_tab, diff_name, r, 0)
                  end
                elseif has_not_started or has_in_progress then
                  -- Combined: Not Started -> Empty (with 5-lane MIDI check), In Progress -> Complete
                  for r = 1, #REGIONS do
                    local st = row[r] or 0
                    if st == 0 then
                      -- Only mark Empty if no MIDI notes exist on this track for any difficulty in this region
                      local has_any_notes = false
                      if PROGRESS[current_tab] then
                        for _, d in ipairs(DIFFS) do
                          if PROGRESS[current_tab][d] and PROGRESS[current_tab][d][r] then
                            has_any_notes = true
                            break
                          end
                        end
                      end
                      if not has_any_notes then
                        -- Set Empty for all difficulties on this row
                        for _, d in ipairs(DIFFS) do
                          local drow = STATE[current_tab] and STATE[current_tab][d]
                          if drow then
                            drow[r] = 3
                            save(current_tab, d, r, 3)
                          end
                        end
                      end
                    elseif st == 1 then
                      row[r] = 2
                      save(current_tab, diff_name, r, 2)
                    end
                  end
                elseif has_complete then
                  for r = 1, #REGIONS do
                    if (row[r] or 0) == 2 then
                      row[r] = 1
                      save(current_tab, diff_name, r, 1)
                    end
                  end
                end
              end
            end
          end

          -- Pro Keys listen indicator; the other pro tracks form a
          -- radio_group so at most one is on.
          if show_pro_listen_icons then
            local all_pro = { PRO_KEYS_TRACKS["Expert"], PRO_KEYS_TRACKS["Hard"],
                              PRO_KEYS_TRACKS["Medium"], PRO_KEYS_TRACKS["Easy"] }
            local others = { all_pro[1], all_pro[2], all_pro[3], all_pro[4] }
            for oi = #others, 1, -1 do
              if others[oi] == PRO_KEYS_TRACKS[toD[k]] then
                table.remove(others, oi)
              end
            end
            ImGui.ImGui_SameLine(ctx, 0, 0)
            ImGui.ImGui_SetCursorPosX(ctx, slot_start + BTN_W + LISTEN_ICON_LEFT_GAP)
            ListenIcon_Draw(ctx, "listen_icon_pk" .. k:lower(),
                            PRO_KEYS_TRACKS[toD[k]], LISTEN_ICON_SIZE, frame_h, others,
                            redirect_focus_after_click)
          end
        end

        -- Pair buttons: Pro Keys mode shows Range/Trill, others show HOPOs/Trills (or Toms/Rolls)
        do
          -- Pair buttons must clear the last icon (each slot is slot_w wide).
          local base_x  = x0 + 4*slot_w + BTN_GAP
          local is_pro_keys = (cur_obj and cur_obj:is_pro()) or false
          local A_label = is_pro_keys and "Range"
                       or (current_tab == "Drums") and "Toms" or "HOPOs"
          local B_label = is_pro_keys and "Trill"
                       or (current_tab == "Drums") and "Rolls" or "Trills"
          local A_req   = is_pro_keys and "PK_RANGE" or "HOPOS"
          local B_req   = is_pro_keys and "PK_TRILL" or "TRILLS"

          ImGui.ImGui_SetCursorPosX(ctx, base_x)
          ImGui.ImGui_SetCursorPosY(ctx, y0)
          if PairSquareButton(ctx, A_label, PAIR_MODE == 1, PAIR_W) then
            if PAIR_MODE == 1 then
              PAIR_MODE = 0
              local cur_key = (cur_obj and cur_obj:current_mode_key()) or "Expert"
              local back = is_pro_keys and "PK_DEFAULT" or ({Expert="EXPERT", Hard="HARD", Medium="MEDIUM", Easy="EASY"})[cur_key]
              reaper.SetExtState(EXT_NS, EXT_REQ, back, false)
            else
              PAIR_MODE = 1
              reaper.SetExtState(EXT_NS, EXT_REQ, A_req, false)
            end
            reaper.defer(redirect_focus_after_click)
          end

          ImGui.ImGui_SetCursorPosX(ctx, base_x + PAIR_W + BTN_GAP)
          ImGui.ImGui_SetCursorPosY(ctx, y0)
          if PairSquareButton(ctx, B_label, PAIR_MODE == 2, PAIR_W) then
            if PAIR_MODE == 2 then
              PAIR_MODE = 0
              local cur_key = (cur_obj and cur_obj:current_mode_key()) or "Expert"
              local back = is_pro_keys and "PK_DEFAULT" or ({Expert="EXPERT", Hard="HARD", Medium="MEDIUM", Easy="EASY"})[cur_key]
              reaper.SetExtState(EXT_NS, EXT_REQ, back, false)
            else
              PAIR_MODE = 2
              reaper.SetExtState(EXT_NS, EXT_REQ, B_req, false)
            end
            reaper.defer(redirect_focus_after_click)
          end
        end
      end

      ImGui.ImGui_SetCursorPosY(ctx, y0 + ImGui.ImGui_GetFrameHeight(ctx))
      ImGui.ImGui_Dummy(ctx, 0, 0)
    end

    -- Right column: region count
    ImGui.ImGui_TableNextColumn(ctx)
    local rc  = tostring(#REGIONS).." region(s)"
    local tw  = select(1, ImGui.ImGui_CalcTextSize(ctx, rc))
    local cx  = ImGui.ImGui_GetCursorPosX(ctx)
    local wid = select(1, ImGui.ImGui_GetContentRegionAvail(ctx))
    ImGui.ImGui_SetCursorPosX(ctx, cx + math.max(0, wid - tw))
    ImGui.ImGui_TextDisabled(ctx, rc)

    ImGui.ImGui_EndTable(ctx)
  end
end