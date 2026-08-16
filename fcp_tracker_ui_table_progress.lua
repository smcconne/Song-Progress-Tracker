-- fcp_tracker_ui_table_progress.lua
-- Progress table renderer (Region | Difficulty | Timer) plus the preview-line
-- jump helper. Owns the per-tab progress UI state (paint, hover, header).
-- Loaded after fcp_tracker_ui_table_common.lua.
-- Requires: fcp_tracker_ui_helpers.lua, fcp_tracker_ui_tabs.lua (for
--           WANT_CENTER_ON_TAB, CENTER_DELAY_FRAMES), fcp_tracker_ui_table_common.lua.

local reaper = reaper
local ImGui  = reaper

-- UI-local paint state
local PAINT = { down = false, seen = {}, did_any = false, pending_redirect = nil }
local TIME_PAINT = { down = false, min_row = nil, max_row = nil }
local LAST_ACTIVE_ROW = nil
-- Last active tab the header cell was drawn for. Used to re-roll the
-- "header" confetti offset on every tab change (not on every frame).
local LAST_HEADER_TAB = nil

-- Previous-frame hover preview for the measure-offset InputInt
local HOVER_PREVIEW_OFFSET = nil  -- nil = not hovering, number = preview offset
local HOVER_CURRENT_REGION = false -- true when hovering the active (current) region row
local HOVER_MODIFIER_DISTANCE = nil -- nil = not modifier-hovering, number = measure distance from cursor
local HEADER_LABEL_HOVERED = false -- true when hovering the leftmost header cell
local HEADER_LABEL_WAS_HOVERED = false -- previous frame's hover state for edge detection
local HEADER_JUMP_CLICKED = false -- true after jump click, suppresses preview-scroll for rest of hover

-- Draw the current tab's progress table (Region | Difficulty | Timer).
function draw_progress_table(ctx, redirect_focus_after_click)

  local row_h   = ImGui.ImGui_GetTextLineHeightWithSpacing(ctx) * 0.976
  local row_of_cursor = active_region_index()
  -- Thin Tab wrapper locals: the single source of truth for active tab/variant/mode.
  local cur_obj = current_tab_obj and current_tab_obj() or nil
  local cur_mode = cur_obj and cur_obj:current_mode() or nil
  local cur_trackname = cur_mode and cur_mode.trackname or nil
  -- Pro Keys header pct: STATE["Keys"]["pro"] is keyed by the canonical
  -- mode; cur_mode.key is the X/H/M/E display form.
  local DIFF_TO_CANON = { X="Expert", H="Hard", M="Medium", E="Easy" }

  --------------------------------------------------------------
  -- HEADER (fixed, no extra child)
  if ImGui.ImGui_BeginTable(
      ctx, "hdr_tbl", 3,
      ImGui.ImGui_TableFlags_SizingFixedFit() +
      ImGui.ImGui_TableFlags_Borders()
    ) then

    local display_diff
    if cur_mode then
      display_diff = cur_mode.key
    else
      display_diff = (cur_obj and cur_obj:current_mode_key()) or ACTIVE_DIFF
    end

    ImGui.ImGui_TableSetupColumn(
      ctx, "Region",
      ImGui.ImGui_TableColumnFlags_WidthFixed(), FIRST_COL_W
    )
    ImGui.ImGui_TableSetupColumn(
      ctx, display_diff,
      ImGui.ImGui_TableColumnFlags_WidthFixed(), REGION_COL_W
    )
    ImGui.ImGui_TableSetupColumn(
      ctx, "Timer",
      ImGui.ImGui_TableColumnFlags_WidthFixed(), TIME_COL_W
    )

    ImGui.ImGui_TableNextRow(ctx, ImGui.ImGui_TableRowFlags_Headers())

    ImGui.ImGui_TableNextColumn(ctx)
    do
      local rx0 = ImGui.ImGui_GetCursorPosX(ctx)
      local ry0 = ImGui.ImGui_GetCursorPosY(ctx)
      local rw  = select(1, ImGui.ImGui_GetContentRegionAvail(ctx))
      local row_height = ImGui.ImGui_GetTextLineHeightWithSpacing(ctx)

      -- Right-aligned measure-offset InputInt (from Jump Regions)
      if FCP_JUMP_REGIONS then
        local em = ImGui.ImGui_GetFontSize(ctx)
        local input_w = math.floor(em * 3)
        local gap = 4  -- gap between label area and InputInt

        -- Draw label as an invisible button that triggers jump on click
        local label_w = rw - input_w - gap
        if label_w < 1 then label_w = 1 end
        ImGui.ImGui_SetCursorPosX(ctx, rx0)
        ImGui.ImGui_SetCursorPosY(ctx, ry0)
        ImGui.ImGui_InvisibleButton(ctx, "##region_jump", label_w, row_height)
        local cell_clicked = ImGui.ImGui_IsItemClicked(ctx, 0)
        local label_hovered = ImGui.ImGui_IsItemHovered(ctx)
        HEADER_LABEL_HOVERED = label_hovered

        -- Determine header state based on what's being hovered
        local any_hover = label_hovered or HOVER_CURRENT_REGION or (HOVER_PREVIEW_OFFSET ~= nil) or (HOVER_MODIFIER_DISTANCE ~= nil)
        -- The value that would be shown in the textbox right now
        local effective_val
        if HOVER_MODIFIER_DISTANCE ~= nil then
          effective_val = HOVER_MODIFIER_DISTANCE
        elseif HOVER_PREVIEW_OFFSET ~= nil then
          effective_val = HOVER_PREVIEW_OFFSET
        else
          effective_val = FCP_JUMP_REGIONS.MEAS_OFFSET
        end
        local show_current = any_hover and (effective_val == 0)
        local show_orange  = any_hover and (effective_val ~= 0)

        -- Draw label text over the invisible button
        local text_h = ImGui.ImGui_GetTextLineHeight(ctx)
        local label_y_offset = math.floor((row_height - text_h) / 2)
        ImGui.ImGui_SetCursorPosX(ctx, rx0)
        ImGui.ImGui_SetCursorPosY(ctx, ry0 + label_y_offset)
        local header_label = "Target"
        if show_current then
          header_label = "Current"
        elseif show_orange then
          header_label = "Jump"
          ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), COL_PREVIEW_LINE)
        end
        ImGui.ImGui_Text(ctx, header_label)
        if show_orange then
          ImGui.ImGui_PopStyleColor(ctx)
        end

        -- InputInt right-aligned, orange text when previewing
        ImGui.ImGui_SetCursorPosX(ctx, rx0 + rw - input_w)
        ImGui.ImGui_SetCursorPosY(ctx, ry0)
        ImGui.ImGui_SetNextItemWidth(ctx, input_w)
        local display_val = FCP_JUMP_REGIONS.MEAS_OFFSET
        local is_previewing = (HOVER_PREVIEW_OFFSET ~= nil) or (HOVER_MODIFIER_DISTANCE ~= nil)
        if HOVER_MODIFIER_DISTANCE ~= nil then
          display_val = HOVER_MODIFIER_DISTANCE
        elseif HOVER_PREVIEW_OFFSET ~= nil then
          display_val = HOVER_PREVIEW_OFFSET
        end
        if show_orange then
          ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), COL_PREVIEW_LINE)
        end
        local changed, v = ImGui.ImGui_InputInt(ctx, "##meas_off", display_val, 0, 0)
        if show_orange then
          ImGui.ImGui_PopStyleColor(ctx)
        end
        local input_active = ImGui.ImGui_IsItemActive(ctx)
        FCP_JUMP_REGIONS.input_active = input_active
        if changed and not is_previewing then FCP_JUMP_REGIONS.MEAS_OFFSET = v end
        if ImGui.ImGui_IsItemDeactivatedAfterEdit(ctx) then
          if redirect_focus_after_click then reaper.defer(redirect_focus_after_click) end
        end

        -- Trigger jump when the label area is clicked
        if cell_clicked and not input_active then
          FCP_JUMP_REGIONS.do_jump(true)
          HEADER_JUMP_CLICKED = true
        end
      else
        ImGui.ImGui_Text(ctx, "Region")
      end
    end

    ImGui.ImGui_TableNextColumn(ctx)
    local cell_sx, cell_sy = ImGui.ImGui_GetCursorScreenPos(ctx)
    local x0 = ImGui.ImGui_GetCursorPosX(ctx)
    local w  = select(1, ImGui.ImGui_GetContentRegionAvail(ctx))
    local pct_row_h = ImGui.ImGui_GetTextLineHeightWithSpacing(ctx)

    -- Canonicalize the Pro Keys mode before reading the data tree
    -- (hoisted so the confetti gate below can read pct before drawing).
    local pct_diff = display_diff
    if cur_obj and cur_obj:is_pro() and cur_mode then
      pct_diff = DIFF_TO_CANON[cur_mode.key] or cur_mode.key
    end
    local pct = diff_pct(current_tab, pct_diff)

    -- Confetti: only when this difficulty is fully complete. Drawn as a
    -- background layer behind the rightmost CONFETTI_WIDTH pixels of the cell.
    if pct == 100 then
      -- Re-roll the header confetti offset on every tab change (keyed
      -- "header" so the tooltip stays independent).
      if current_tab ~= LAST_HEADER_TAB then
        Randomize_Confetti_Offset("header")
        LAST_HEADER_TAB = current_tab
      end
      Progress_Confetti_DrawInRect(ctx, cell_sx + w - CONFETTI_WIDTH, cell_sy, CONFETTI_WIDTH, pct_row_h, "header")
    end

    local diff_label_y = ImGui.ImGui_GetCursorPosY(ctx)
    ImGui.ImGui_Text(ctx, display_diff)

    local t   = tostring(pct) .. "%"
    local tw  = select(1, ImGui.ImGui_CalcTextSize(ctx, t))
    local th  = select(2, ImGui.ImGui_CalcTextSize(ctx, t))
    local pct_y_off = math.floor((pct_row_h - th) / 2)

    ImGui.ImGui_SetCursorPosX(ctx, x0 + w - tw)
    ImGui.ImGui_SetCursorPosY(ctx, diff_label_y + pct_y_off)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), pct_to_u32(pct))
    ImGui.ImGui_Text(ctx, t)
    ImGui.ImGui_PopStyleColor(ctx)

    -- Time header column
    ImGui.ImGui_TableNextColumn(ctx)
    ImGui.ImGui_Text(ctx, "Timer")

    ImGui.ImGui_EndTable(ctx)
  end

  --------------------------------------------------------------
  -- BODY metrics
  local avail_h  = select(2, ImGui.ImGui_GetContentRegionAvail(ctx))
  local rows_fit = math.max(1, math.min(#REGIONS, math.floor(avail_h / row_h)))
  local body_h   = rows_fit * row_h + 1
  local max_n    = math.max(0, #REGIONS - rows_fit)
  local key      = current_tab

  local need_center_now = false
  
  -- Handle delayed centering after screenset load
  if CENTER_DELAY_FRAMES > 0 then
    CENTER_DELAY_FRAMES = CENTER_DELAY_FRAMES - 1
    if CENTER_DELAY_FRAMES == 0 then
      WANT_CENTER_ON_TAB = true
    end
  end
  
  if row_of_cursor then
    if WANT_CENTER_ON_TAB or row_of_cursor ~= LAST_ACTIVE_ROW then
      local desired = row_of_cursor - math.floor(rows_fit / 2)
      if desired < 0 then
        desired = 0
      elseif desired > max_n then
        desired = max_n
      end
      TAB_SCROLL_ROW[key] = desired
      WANT_CENTER_ON_TAB  = false
      LAST_ACTIVE_ROW     = row_of_cursor
      need_center_now     = true
    end
  end

  -- Header hover scroll: center on preview line row or snap back to current region
  if HEADER_LABEL_HOVERED and not HEADER_JUMP_CLICKED and FCP_JUMP_REGIONS and FCP_JUMP_REGIONS.MEAS_OFFSET ~= 0 and row_of_cursor then
    local st = reaper.GetPlayState()
    local cursor_t = (st & 1) == 1 and reaper.GetPlayPosition() or reaper.GetCursorPosition()
    local target_t = jump_time_by_measures(cursor_t, FCP_JUMP_REGIONS.MEAS_OFFSET)
    local target_row = nil
    for i = 1, #REGIONS do
      local rs = REGIONS[i].pos or 0
      local re = REGIONS[i].r_end or 0
      if target_t >= rs and target_t < re then target_row = i; break end
    end
    if target_row then
      local desired = target_row - math.floor(rows_fit / 2)
      if desired < 0 then desired = 0 elseif desired > max_n then desired = max_n end
      TAB_SCROLL_ROW[key] = desired
      need_center_now = true
    end
  elseif HEADER_LABEL_HOVERED and HEADER_JUMP_CLICKED and row_of_cursor then
    -- After jump click, stay centered on the (now-updated) active region
    local desired = row_of_cursor - math.floor(rows_fit / 2)
    if desired < 0 then desired = 0 elseif desired > max_n then desired = max_n end
    TAB_SCROLL_ROW[key] = desired
    need_center_now = true
  elseif not HEADER_LABEL_HOVERED and HEADER_LABEL_WAS_HOVERED and row_of_cursor then
    local desired = row_of_cursor - math.floor(rows_fit / 2)
    if desired < 0 then desired = 0 elseif desired > max_n then desired = max_n end
    TAB_SCROLL_ROW[key] = desired
    need_center_now = true
    HEADER_JUMP_CLICKED = false
  end
  HEADER_LABEL_WAS_HOVERED = HEADER_LABEL_HOVERED

  -- Mouse press/release edge: reset paint set
  do
    local now = ImGui.ImGui_IsMouseDown(ctx, 0)
    if now ~= PAINT.down then
      -- On mouse release, call pending redirect if any
      if not now and PAINT.pending_redirect then
        reaper.defer(PAINT.pending_redirect)
      end
      PAINT.seEN, PAINT.did_any, PAINT.down, PAINT.pending_redirect = {}, false, now, nil
    end
  end

  -- Right-click press/release edge: handle time selection paint
  do
    local now = ImGui.ImGui_IsMouseDown(ctx, 1)
    if now ~= TIME_PAINT.down then
      if not now and TIME_PAINT.min_row and TIME_PAINT.max_row then
        local start_time = REGIONS[TIME_PAINT.min_row].pos or 0
        local end_time = REGIONS[TIME_PAINT.max_row].r_end or 0
        reaper.GetSet_LoopTimeRange(true, false, start_time, end_time, false)
      end
      TIME_PAINT.down = now
      TIME_PAINT.min_row = nil
      TIME_PAINT.max_row = nil
    end
  end

  --------------------------------------------------------------
  -- BODY: native scrollbar, 1-row wheel steps, snap to rows
  if table_zone_child(ctx, "rows_scroller", body_h) then

    -- Visible bounds of the scroll child (screen coords) for hit-test clamping
    local child_sx, child_sy = ImGui.ImGui_GetWindowPos(ctx)
    local child_visible_y1 = child_sy
    local child_visible_y2 = child_sy + body_h

    scroll_snap_to_row(ctx, current_tab, max_n, row_h, need_center_now)

    if ImGui.ImGui_BeginTable(
        ctx, "body_tbl", 3,
        ImGui.ImGui_TableFlags_SizingFixedFit() +
        ImGui.ImGui_TableFlags_Borders()
      ) then

      local display_diff
      if cur_obj and cur_obj:is_pro() then
        display_diff = "Pro " .. cur_mode.key
      elseif cur_mode then
        display_diff = cur_mode.key
      else
        display_diff = (cur_obj and cur_obj:current_mode_key()) or ACTIVE_DIFF
      end

      ImGui.ImGui_TableSetupColumn(
        ctx, "Region",
        ImGui.ImGui_TableColumnFlags_WidthFixed(), FIRST_COL_W
      )
      ImGui.ImGui_TableSetupColumn(
        ctx, display_diff,
        ImGui.ImGui_TableColumnFlags_WidthFixed(), REGION_COL_W
      )
      ImGui.ImGui_TableSetupColumn(
        ctx, "Timer",
        ImGui.ImGui_TableColumnFlags_WidthFixed(), TIME_COL_W
      )

      local hovered_region_row = nil
      local region_cell_positions = {}
      HOVER_CURRENT_REGION = false  -- reset each frame before row loop

      for r = 1, #REGIONS do
        ImGui.ImGui_TableNextRow(ctx, last_row_height_hack(r, #REGIONS, row_h))

        -- Highlight entire row (including area right of columns) for the current region
        if row_of_cursor == r then
          ImGui.ImGui_TableSetBgColor(
            ctx, ImGui.ImGui_TableBgTarget_RowBg0(), REG_COL_U32[r].header
          )
        end

        -- Region cell
        ImGui.ImGui_TableNextColumn(ctx)
        if row_of_cursor ~= r then
          ImGui.ImGui_TableSetBgColor(
            ctx, ImGui.ImGui_TableBgTarget_CellBg(), REG_COL_U32[r].header
          )
        end
        
        local cell_x, cell_y = ImGui.ImGui_GetCursorScreenPos(ctx)
        region_cell_positions[r] = { x = cell_x, y = cell_y }
        
        ImGui.ImGui_PushID(ctx, "region_click|" .. r)
        local clicked_region = ImGui.ImGui_Selectable(ctx, REGIONS[r].name, false)
        local region_hovered = ImGui.ImGui_IsItemHovered(ctx)
        
        -- Right-click drag paint for time selection
        if TIME_PAINT.down and region_hovered then
          if TIME_PAINT.min_row == nil then
            TIME_PAINT.min_row = r
            TIME_PAINT.max_row = r
          else
            if r < TIME_PAINT.min_row then TIME_PAINT.min_row = r end
            if r > TIME_PAINT.max_row then TIME_PAINT.max_row = r end
          end
        end
        
        if clicked_region then
          local modifier_held = any_modifier_held()
          
          if modifier_held then
            -- Compute floored measure distance from cursor to clicked region start
            if FCP_JUMP_REGIONS and row_of_cursor then
              local st = reaper.GetPlayState()
              local cursor_t = (st & 1) == 1 and reaper.GetPlayPosition() or reaper.GetCursorPosition()
              local cur_m = measure_index_at_time(cursor_t)
              local cur_frac = frac_in_measure_at_time(cursor_t)
              local cur_eff = (cur_frac > 0.001) and (cur_m + 1) or cur_m
              local hov_m = measure_index_at_time(REGIONS[r].pos or 0)
              local hov_frac = frac_in_measure_at_time(REGIONS[r].pos or 0)
              local hov_eff = (hov_frac > 0.001) and (hov_m + 1) or hov_m
              FCP_JUMP_REGIONS.MEAS_OFFSET = math.floor(hov_eff - cur_eff)
            end
            reaper.SetProjExtState(
              PROJ, JUMP_EXT_SECTION, JUMP_EXT_KEY, "ABS:" .. tostring(REGIONS[r].id)
            )
          else
            reaper.SetProjExtState(
              PROJ, JUMP_EXT_SECTION, JUMP_EXT_KEY, tostring(REGIONS[r].id)
            )
          end
          if redirect_focus_after_click then
            reaper.defer(redirect_focus_after_click)
          end
        end
        ImGui.ImGui_PopID(ctx)
        
        if region_hovered and row_of_cursor and row_of_cursor ~= r then
          hovered_region_row = r
        end

        -- Track hovering over the current (active) region row
        if region_hovered and row_of_cursor and row_of_cursor == r then
          HOVER_CURRENT_REGION = true
        end
        
        -- Draw cursor position line if this is the active region
        if row_of_cursor == r then
          local reg_start = REGIONS[r].pos or 0
          local reg_end   = REGIONS[r].r_end or 0
          local reg_len   = reg_end - reg_start
          
          if reg_len > 0 then
            local st = reaper.GetPlayState()
            local cursor_t = (st & 1) == 1 and reaper.GetPlayPosition() or reaper.GetCursorPosition()
            
            local pct_through = (cursor_t - reg_start) / reg_len
            if pct_through < 0 then pct_through = 0 end
            if pct_through > 1 then pct_through = 1 end
            
            local cell_w = FIRST_COL_W
            local cell_h = row_h
            local line_x = cell_x + (cell_w * pct_through)
            
            local dl = ImGui.ImGui_GetWindowDrawList(ctx)
            ImGui.ImGui_DrawList_AddLine(dl, line_x, cell_y - 2, line_x, cell_y + cell_h - 3, COL_CURSOR_LINE, 2.0)
          end
        end

        -- Progress cell with drag-paint
        ImGui.ImGui_TableNextColumn(ctx)

        local st
        local obj = current_tab_obj and current_tab_obj()
        local cell_diff  -- canonical diff key used for both the read and the write path
        if obj and obj.name == "Keys" and obj:is_pro() then
          -- Pro Keys reads from STATE["Keys"]["pro"][mkey]; current_mode().key
          -- is already the canonical key the tree is indexed by.
          local mkey = obj:current_mode().key
          cell_diff = mkey
          st = (STATE["Keys"] and STATE["Keys"]["pro"]
                     and STATE["Keys"]["pro"][mkey]
                     and STATE["Keys"]["pro"][mkey][r]) or 0
        else
          -- Non-pro tabs read from STATE[current_tab]["regular"][display_diff]
          cell_diff = display_diff
          st = (STATE[current_tab] and STATE[current_tab]["regular"]
                     and STATE[current_tab]["regular"][display_diff]
                     and STATE[current_tab]["regular"][display_diff][r]) or 0
        end
        local text = STATE_TEXT[st]
        local col  = STATE_COLOR[st]

        ImGui.ImGui_PushID(ctx, current_tab .. "|" .. display_diff .. "|" .. r)
        
        -- Get cell screen position before drawing
        local prog_cell_x, prog_cell_y = ImGui.ImGui_GetCursorScreenPos(ctx)
        
        ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), col)
        local clicked = ImGui.ImGui_Selectable(ctx, text, false)
        ImGui.ImGui_PopStyleColor(ctx)

        -- Manual hit test for drag-paint: check if mouse is within this cell's bounds
        local mouse_x, mouse_y = ImGui.ImGui_GetMousePos(ctx)
        local cell_w = REGION_COL_W
        local cell_h = row_h
        local mouse_in_cell = mouse_x >= prog_cell_x and mouse_x < prog_cell_x + cell_w
                          and mouse_y >= prog_cell_y and mouse_y < prog_cell_y + cell_h
                          and mouse_y >= child_visible_y1 and mouse_y < child_visible_y2
        
        if PAINT.down and mouse_in_cell and not PAINT.seEN[r] and not LISTEN_DRAG_ACTIVE then
          apply_toggle(current_tab, cell_diff, r)
          PAINT.seEN[r], PAINT.did_any = true, true
          -- Store redirect to call on mouse release, don't call immediately
          if redirect_focus_after_click then
            PAINT.pending_redirect = redirect_focus_after_click
          end
        end

        -- Handle single click (only if not already processed by drag-paint)
        if clicked and not PAINT.seEN[r] and not LISTEN_DRAG_ACTIVE then
          apply_toggle(current_tab, cell_diff, r)
          PAINT.seEN[r], PAINT.did_any = true, true
          -- Store redirect to call on mouse release, don't call immediately
          if redirect_focus_after_click then
            PAINT.pending_redirect = redirect_focus_after_click
          end
        end

        ImGui.ImGui_PopID(ctx)

        -- Time cell
        ImGui.ImGui_TableNextColumn(ctx)
        local time_diff = current_timer_diff()
        local secs = get_region_time(current_tab, time_diff, r)
        local time_str
        if secs >= 3600 then
          time_str = string.format("%d:%02d:%02d", math.floor(secs/3600), math.floor(secs/60)%60, secs%60)
        elseif secs >= 60 then
          time_str = string.format("%d:%02d", math.floor(secs/60), secs%60)
        else
          time_str = string.format(":%02d", secs)
        end
        ImGui.ImGui_PushID(ctx, "time|" .. current_tab .. "|" .. time_diff .. "|" .. r)
        local time_clicked = ImGui.ImGui_Selectable(ctx, time_str, false)
        if time_clicked then
          if any_modifier_held() then
            -- Modifier+click: reset to 0
            REGION_TIME[current_tab] = REGION_TIME[current_tab] or {}
            REGION_TIME[current_tab][time_diff] = REGION_TIME[current_tab][time_diff] or {}
            REGION_TIME[current_tab][time_diff][r] = 0
            save_region_time(current_tab, time_diff, r, 0)
          else
            -- Left click: subtract 10 seconds (min 0)
            local new_secs = math.max(0, secs - 10)
            REGION_TIME[current_tab] = REGION_TIME[current_tab] or {}
            REGION_TIME[current_tab][time_diff] = REGION_TIME[current_tab][time_diff] or {}
            REGION_TIME[current_tab][time_diff][r] = new_secs
            save_region_time(current_tab, time_diff, r, new_secs)
          end
          REGION_TIME_LAST_TICK = nil  -- reset tick anchor so counting restarts fresh
        end
        -- Right-click: reset to 0
        if ImGui.ImGui_IsItemClicked(ctx, 1) then
          REGION_TIME[current_tab] = REGION_TIME[current_tab] or {}
          REGION_TIME[current_tab][time_diff] = REGION_TIME[current_tab][time_diff] or {}
          REGION_TIME[current_tab][time_diff][r] = 0
          save_region_time(current_tab, time_diff, r, 0)
          REGION_TIME_LAST_TICK = nil  -- reset tick anchor so counting restarts fresh
        end
        ImGui.ImGui_PopID(ctx)
      end
      
      -- Draw preview line showing where cursor would land after jump
      if hovered_region_row and row_of_cursor then
        draw_preview_line(ctx, row_of_cursor, hovered_region_row, region_cell_positions, row_h)
      end

      -- Update hover preview offset for next frame's header InputInt
      if hovered_region_row and row_of_cursor then
        local cur_reg = REGIONS[row_of_cursor]
        local hov_reg = REGIONS[hovered_region_row]
        if cur_reg and hov_reg and not any_modifier_held() then
          local cur_m = measure_index_at_time(cur_reg.pos or 0)
          local cur_frac = frac_in_measure_at_time(cur_reg.pos or 0)
          local cur_eff = (cur_frac > 0.001) and (cur_m + 1) or cur_m
          local hov_m = measure_index_at_time(hov_reg.pos or 0)
          local hov_frac = frac_in_measure_at_time(hov_reg.pos or 0)
          local hov_eff = (hov_frac > 0.001) and (hov_m + 1) or hov_m
          HOVER_PREVIEW_OFFSET = hov_eff - cur_eff
          HOVER_MODIFIER_DISTANCE = nil
        elseif cur_reg and hov_reg and any_modifier_held() then
          HOVER_PREVIEW_OFFSET = nil
          -- Compute measure distance from cursor to hovered region start
          local st = reaper.GetPlayState()
          local cursor_t = (st & 1) == 1 and reaper.GetPlayPosition() or reaper.GetCursorPosition()
          local cur_m = measure_index_at_time(cursor_t)
          local cur_frac = frac_in_measure_at_time(cursor_t)
          local cur_eff = (cur_frac > 0.001) and (cur_m + 1) or cur_m
          local hov_m = measure_index_at_time(hov_reg.pos or 0)
          local hov_frac = frac_in_measure_at_time(hov_reg.pos or 0)
          local hov_eff = (hov_frac > 0.001) and (hov_m + 1) or hov_m
          local dist = hov_eff - cur_eff
          HOVER_MODIFIER_DISTANCE = dist
        else
          HOVER_PREVIEW_OFFSET = nil
          HOVER_MODIFIER_DISTANCE = nil
        end
      else
        -- Hovering current region (hovered_region_row is nil)
        if HOVER_CURRENT_REGION and any_modifier_held() and row_of_cursor then
          HOVER_PREVIEW_OFFSET = nil
          local hov_reg = REGIONS[row_of_cursor]
          if hov_reg then
            local st = reaper.GetPlayState()
            local cursor_t = (st & 1) == 1 and reaper.GetPlayPosition() or reaper.GetCursorPosition()
            local cur_m = measure_index_at_time(cursor_t)
            local cur_frac = frac_in_measure_at_time(cursor_t)
            local cur_eff = (cur_frac > 0.001) and (cur_m + 1) or cur_m
            local hov_m = measure_index_at_time(hov_reg.pos or 0)
            local hov_frac = frac_in_measure_at_time(hov_reg.pos or 0)
            local hov_eff = (hov_frac > 0.001) and (hov_m + 1) or hov_m
            HOVER_MODIFIER_DISTANCE = hov_eff - cur_eff
            -- Draw preview line at the region start when distance is non-zero
            if HOVER_MODIFIER_DISTANCE ~= 0 and region_cell_positions[row_of_cursor] then
              local tc = region_cell_positions[row_of_cursor]
              local dl = ImGui.ImGui_GetWindowDrawList(ctx)
              ImGui.ImGui_DrawList_AddLine(dl, tc.x, tc.y - 2, tc.x, tc.y + row_h - 3, COL_PREVIEW_LINE, 2.0)
            end
          else
            HOVER_MODIFIER_DISTANCE = nil
          end
        elseif HOVER_CURRENT_REGION then
          -- Hovering current region without modifier: preview offset is 0
          HOVER_PREVIEW_OFFSET = 0
          HOVER_MODIFIER_DISTANCE = nil
        else
          HOVER_PREVIEW_OFFSET = nil
          HOVER_MODIFIER_DISTANCE = nil
        end
      end

      -- Draw jump-target line based on measure offset when not hovering a region
      if not hovered_region_row and not HOVER_CURRENT_REGION and FCP_JUMP_REGIONS and FCP_JUMP_REGIONS.MEAS_OFFSET ~= 0 then
        local st = reaper.GetPlayState()
        local cursor_t = (st & 1) == 1 and reaper.GetPlayPosition() or reaper.GetCursorPosition()
        local target_t = jump_time_by_measures(cursor_t, FCP_JUMP_REGIONS.MEAS_OFFSET)

        local target_row = nil
        for i = 1, #REGIONS do
          local rs = REGIONS[i].pos or 0
          local re = REGIONS[i].r_end or 0
          if target_t >= rs and target_t < re then target_row = i; break end
        end

        if target_row and region_cell_positions[target_row] then
          local treg = REGIONS[target_row]
          local tlen = (treg.r_end or 0) - (treg.pos or 0)
          if tlen > 0 then
            local pct = (target_t - treg.pos) / tlen
            -- Snap to next region if landing at boundary
            if pct >= 0.9999 and target_row < #REGIONS then
              target_row = target_row + 1
              pct = 0
            end
            if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
            local tc = region_cell_positions[target_row]
            if tc then
              local line_x = tc.x + (FIRST_COL_W * pct)
              local dl = ImGui.ImGui_GetWindowDrawList(ctx)
              ImGui.ImGui_DrawList_AddLine(dl, line_x, tc.y - 2, line_x, tc.y + row_h - 3, COL_PREVIEW_LINE, 2.0)
            end
          end
        end
      end

      ImGui.ImGui_EndTable(ctx)
    end
  end
  ImGui.ImGui_EndChild(ctx)
end


-- Draw the preview line on the row the cursor would land on after a jump.
function draw_preview_line(ctx, row_of_cursor, hovered_region_row, region_cell_positions, row_h)
  local cur_reg = REGIONS[row_of_cursor]
  local hov_reg = REGIONS[hovered_region_row]
  
  if not (cur_reg and hov_reg) then return end
  
  local modifier_held = any_modifier_held()
  
  if modifier_held then
    if region_cell_positions[hovered_region_row] then
      local target_cell = region_cell_positions[hovered_region_row]
      local cell_h = row_h
      local line_x = target_cell.x
      
      local dl = ImGui.ImGui_GetWindowDrawList(ctx)
      ImGui.ImGui_DrawList_AddLine(dl, line_x, target_cell.y - 2, line_x, target_cell.y + cell_h - 3, COL_PREVIEW_LINE, 2.0)
    end
  else
    local cur_m = measure_index_at_time(cur_reg.pos or 0)
    local cur_frac = frac_in_measure_at_time(cur_reg.pos or 0)
    local cur_effective_m = (cur_frac > 0.001) and (cur_m + 1) or cur_m
    
    local hov_m = measure_index_at_time(hov_reg.pos or 0)
    local hov_frac = frac_in_measure_at_time(hov_reg.pos or 0)
    local hov_effective_m = (hov_frac > 0.001) and (hov_m + 1) or hov_m
    
    local meas_offset = hov_effective_m - cur_effective_m
    local preview_t = jump_time_by_measures(reaper.GetCursorPosition(), meas_offset)
    
    local preview_region_idx = nil
    for i = 1, #REGIONS do
      local rs = REGIONS[i].pos or 0
      local re = REGIONS[i].r_end or 0
      if preview_t >= rs and preview_t < re then
        preview_region_idx = i
        break
      end
    end
    
    if preview_region_idx and region_cell_positions[preview_region_idx] then
      local target_reg = REGIONS[preview_region_idx]
      local target_reg_start = target_reg.pos or 0
      local target_reg_end = target_reg.r_end or 0
      local target_reg_len = target_reg_end - target_reg_start
      
      if target_reg_len > 0 then
        local pct_preview = (preview_t - target_reg_start) / target_reg_len
        
        if pct_preview >= 0.9999 and preview_region_idx < #REGIONS then
          preview_region_idx = preview_region_idx + 1
          if region_cell_positions[preview_region_idx] then
            target_reg = REGIONS[preview_region_idx]
            pct_preview = 0
          end
        end
        
        if pct_preview < 0 then pct_preview = 0 end
        if pct_preview > 1 then pct_preview = 1 end
        
        local target_cell = region_cell_positions[preview_region_idx]
        if target_cell then
          local cell_h = row_h
          local line_x = target_cell.x + (FIRST_COL_W * pct_preview)
          
          local dl = ImGui.ImGui_GetWindowDrawList(ctx)
          ImGui.ImGui_DrawList_AddLine(dl, line_x, target_cell.y - 2, line_x, target_cell.y + cell_h - 3, COL_PREVIEW_LINE, 2.0)
        end
      end
    end
  end
end
