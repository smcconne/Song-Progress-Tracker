-- fcp_tracker_ui_header.lua
-- Header row with difficulty buttons, mode buttons, and region count
-- Requires: fcp_tracker_ui_widgets.lua, fcp_tracker_ui_helpers.lua

local reaper = reaper
local ImGui  = reaper

-- global single-select state across tabs: 0 = none, 1 = A (Toms/HOPOs), 2 = B (Rolls/Trills)
PAIR_MODE = PAIR_MODE or 0

-- Metrics (initialized in Progress_UI_Init)
BUTTONS_COL_W = nil

function init_header_metrics()
  local PAIR_W = get_PAIR_W()
  BUTTONS_COL_W = 4*BTN_W + 8*BTN_GAP + 2*PAIR_W
end

function progress_and_count_row(ctx, redirect_focus_after_click)
  local PAIR_W = get_PAIR_W()
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
        local venue_btn_w = PAIR_W * 1.5
        for i, lab in ipairs(labels) do
          ImGui.ImGui_SetCursorPosX(ctx, x0 + (i-1)*(venue_btn_w+BTN_GAP))
          ImGui.ImGui_SetCursorPosY(ctx, y0)
          local track_is_empty = is_all_empty("Venue", lab)
          if DiffSquareButton(ctx, lab, lab, VENUE_MODE==lab, venue_btn_w, track_is_empty) then
            VENUE_MODE = lab
            select_and_scroll_track_by_name(VENUE_TRACKS[VENUE_MODE], 40818, 40726)
            WANT_CENTER_ON_TAB = true
            reaper.defer(redirect_focus_after_click)
          end
          
          -- Tooltip showing percentage (styled like difficulty buttons)
          if ImGui.ImGui_IsItemHovered(ctx) then
            local pct = diff_pct("Venue", lab)
            local tooltip_w = 140
            
            -- Position: below the button, left edge at window left edge
            local win_x, _ = ImGui.ImGui_GetWindowPos(ctx)
            local _, btn_max_y = ImGui.ImGui_GetItemRectMax(ctx)
            
            ImGui.ImGui_SetNextWindowPos(ctx, win_x, btn_max_y + 5)
            ImGui.ImGui_SetNextWindowSize(ctx, tooltip_w, 0)
            
            ImGui.ImGui_BeginTooltip(ctx)
            
            -- Left-aligned header
            ImGui.ImGui_Text(ctx, lab)
            
            -- Right-aligned percentage on same line, colored by percentage
            ImGui.ImGui_SameLine(ctx)
            local pct_text = track_is_empty and "Empty" or (tostring(pct) .. "%")
            local avail_w = ImGui.ImGui_GetContentRegionAvail(ctx)
            local pct_w = ImGui.ImGui_CalcTextSize(ctx, pct_text)
            ImGui.ImGui_SetCursorPosX(ctx, ImGui.ImGui_GetCursorPosX(ctx) + avail_w - pct_w)
            
            if track_is_empty then
              ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), 0x808080FF)
            else
              local pct_col = pct_scaled_u32(pct, 1.0, 1.0)
              ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), pct_col)
            end
            ImGui.ImGui_Text(ctx, pct_text)
            ImGui.ImGui_PopStyleColor(ctx)
            
            ImGui.ImGui_EndTooltip(ctx)
          end
          
          -- Right-click: cycle all cells for this track
          if ImGui.ImGui_IsItemClicked(ctx, 1) then
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
                  save_cell_state("Venue", lab, r, 0)
                end
              elseif all_not_started then
                -- All Not Started -> change to Empty
                for r = 1, #REGIONS do
                  row[r] = 3
                  save_cell_state("Venue", lab, r, 3)
                end
              elseif has_not_started then
                -- Any Not Started -> change all Not Started to Empty
                for r = 1, #REGIONS do
                  if row[r] == 0 then
                    row[r] = 3
                    save_cell_state("Venue", lab, r, 3)
                  end
                end
              elseif has_in_progress then
                -- No Not Started, but has In Progress -> change all In Progress to Complete
                for r = 1, #REGIONS do
                  if row[r] == 1 then
                    row[r] = 2
                    save_cell_state("Venue", lab, r, 2)
                  end
                end
              elseif has_complete then
                -- No Not Started, no In Progress, but has Complete -> change all Complete to In Progress
                for r = 1, #REGIONS do
                  if row[r] == 2 then
                    row[r] = 1
                    save_cell_state("Venue", lab, r, 1)
                  end
                end
              end
            end
            reaper.defer(redirect_focus_after_click)
          end
        end
      elseif current_tab == "Vocals" then
        -- Vocals: H1/H2/H3/V
        local labels = {"H1","H2","H3","V"}
        for i, lab in ipairs(labels) do
          ImGui.ImGui_SetCursorPosX(ctx, x0 + (i-1)*(BTN_W+BTN_GAP))
          ImGui.ImGui_SetCursorPosY(ctx, y0)
          local track_is_empty = is_all_empty("Vocals", lab)
          if DiffSquareButton(ctx, lab, lab, VOCALS_MODE==lab, nil, track_is_empty) then
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
              VOCALS_MODE = lab
              select_and_scroll_track_by_name(VOCALS_TRACKS[VOCALS_MODE], 40818, 40726)
              WANT_CENTER_ON_TAB = true
            end
            reaper.defer(redirect_focus_after_click)
          end
          
          -- Tooltip showing percentage (styled like difficulty buttons)
          if ImGui.ImGui_IsItemHovered(ctx) then
            local pct = diff_pct("Vocals", lab)
            local tooltip_w = 120
            
            -- Position: below the button, left edge at window left edge
            local win_x, _ = ImGui.ImGui_GetWindowPos(ctx)
            local _, btn_max_y = ImGui.ImGui_GetItemRectMax(ctx)
            
            ImGui.ImGui_SetNextWindowPos(ctx, win_x, btn_max_y + 5)
            ImGui.ImGui_SetNextWindowSize(ctx, tooltip_w, 0)
            
            ImGui.ImGui_BeginTooltip(ctx)
            
            -- Left-aligned header
            ImGui.ImGui_Text(ctx, lab)
            
            -- Right-aligned percentage on same line, colored by percentage
            ImGui.ImGui_SameLine(ctx)
            local pct_text = track_is_empty and "Empty" or (tostring(pct) .. "%")
            local avail_w = ImGui.ImGui_GetContentRegionAvail(ctx)
            local pct_w = ImGui.ImGui_CalcTextSize(ctx, pct_text)
            ImGui.ImGui_SetCursorPosX(ctx, ImGui.ImGui_GetCursorPosX(ctx) + avail_w - pct_w)
            
            if track_is_empty then
              ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), 0x808080FF)
            else
              local pct_col = pct_scaled_u32(pct, 1.0, 1.0)
              ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), pct_col)
            end
            ImGui.ImGui_Text(ctx, pct_text)
            ImGui.ImGui_PopStyleColor(ctx)
            
            ImGui.ImGui_EndTooltip(ctx)
          end
          
          -- Right-click: cycle all cells for this track
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
              
              -- Apply state changes based on priority and save each cell
              if all_empty then
                -- All Empty -> change to Not Started
                for r = 1, #REGIONS do
                  row[r] = 0
                  save_cell_state("Vocals", lab, r, 0)
                end
              elseif all_not_started then
                -- All Not Started -> change to Empty
                for r = 1, #REGIONS do
                  row[r] = 3
                  save_cell_state("Vocals", lab, r, 3)
                end
              elseif has_not_started then
                -- Any Not Started -> change all Not Started to Empty
                for r = 1, #REGIONS do
                  if row[r] == 0 then
                    row[r] = 3
                    save_cell_state("Vocals", lab, r, 3)
                  end
                end
              elseif has_in_progress then
                -- No Not Started, but has In Progress -> change all In Progress to Complete
                for r = 1, #REGIONS do
                  if row[r] == 1 then
                    row[r] = 2
                    save_cell_state("Vocals", lab, r, 2)
                  end
                end
              elseif has_complete then
                -- No Not Started, no In Progress, but has Complete -> change all Complete to In Progress
                for r = 1, #REGIONS do
                  if row[r] == 2 then
                    row[r] = 1
                    save_cell_state("Vocals", lab, r, 1)
                  end
                end
              end
            end
            reaper.defer(redirect_focus_after_click)
          end
        end
      else
        -- Difficulties X/H/M/E
        local map = { "X","H","M","E" }
        local toD = { X="Expert", H="Hard", M="Medium", E="Easy" }
        local toU = { X="EXPERT", H="HARD", M="MEDIUM", E="EASY" }
        for i, k in ipairs(map) do
          ImGui.ImGui_SetCursorPosX(ctx, x0 + (i-1)*(BTN_W+BTN_GAP))
          ImGui.ImGui_SetCursorPosY(ctx, y0)
          if DiffSquareButton(ctx, k, toD[k], toD[k]==ACTIVE_DIFF) then
            PAIR_MODE   = 0
            ACTIVE_DIFF = toD[k]
            reaper.SetExtState(EXT_NS, EXT_REQ, toU[k], false)
            
            -- If Pro Keys mode is active on Keys tab, switch to appropriate Pro Keys track
            if current_tab == "Keys" and PRO_KEYS_ACTIVE then
              local trackname = PRO_KEYS_TRACKS[k]
              select_and_scroll_track_by_name(trackname)
              compute_pro_keys()
            end
            
            reaper.defer(redirect_focus_after_click)
          end
        end

        -- Pair buttons (hide HOPOs/Trills when in Pro Keys mode)
        if not (current_tab == "Keys" and PRO_KEYS_ACTIVE) then
          local base_x  = x0 + 4*(BTN_W+BTN_GAP) + BTN_GAP
          local A_label = (current_tab == "Drums") and "Toms"  or "HOPOs"
          local B_label = (current_tab == "Drums") and "Rolls" or "Trills"

          ImGui.ImGui_SetCursorPosX(ctx, base_x)
          ImGui.ImGui_SetCursorPosY(ctx, y0)
          if PairSquareButton(ctx, A_label, PAIR_MODE == 1, PAIR_W) then
            if PAIR_MODE == 1 then
              PAIR_MODE = 0
              local back = ({Expert="EXPERT", Hard="HARD", Medium="MEDIUM", Easy="EASY"})[ACTIVE_DIFF]
              reaper.SetExtState(EXT_NS, EXT_REQ, back, false)
            else
              PAIR_MODE = 1
              reaper.SetExtState(EXT_NS, EXT_REQ, "HOPOS", false)
            end
            reaper.defer(redirect_focus_after_click)
          end

          ImGui.ImGui_SetCursorPosX(ctx, base_x + PAIR_W + BTN_GAP)
          ImGui.ImGui_SetCursorPosY(ctx, y0)
          if PairSquareButton(ctx, B_label, PAIR_MODE == 2, PAIR_W) then
            if PAIR_MODE == 2 then
              PAIR_MODE = 0
              local back = ({Expert="EXPERT", Hard="HARD", Medium="MEDIUM", Easy="EASY"})[ACTIVE_DIFF]
              reaper.SetExtState(EXT_NS, EXT_REQ, back, false)
            else
              PAIR_MODE = 2
              reaper.SetExtState(EXT_NS, EXT_REQ, "TRILLS", false)
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