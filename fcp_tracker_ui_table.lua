-- fcp_tracker_ui_table.lua
-- Main region table rendering with scrolling and paint logic
-- Requires: fcp_tracker_ui_helpers.lua, fcp_tracker_ui_tabs.lua (for WANT_CENTER_ON_TAB, CENTER_DELAY_FRAMES)

local reaper = reaper
local ImGui  = reaper

-- UI-local paint state
local PAINT = { down = false, seen = {}, did_any = false, pending_redirect = nil }
local TIME_PAINT = { down = false, min_row = nil, max_row = nil }
local LAST_ACTIVE_ROW = nil

-- Minimap bounds for scroll speed detection (from previous frame)
local MINIMAP_BOUNDS = { y1 = 0, y2 = 0 }

-- Pending OV deletions: { {trackname, measure_num, delete_time}, ... }
local PENDING_OV_DELETIONS = {}

-- Check and process pending OV deletions
local function process_pending_ov_deletions()
  local now = reaper.time_precise()
  local i = 1
  while i <= #PENDING_OV_DELETIONS do
    local entry = PENDING_OV_DELETIONS[i]
    if now >= entry.delete_time then
      -- Check if OV still exists and is still invalid
      local trackname = entry.trackname
      local measure_num = entry.measure_num
      local row = entry.row
      
      -- Find the OV note covering this measure and check if ANY measure in its span has notes
      local still_invalid = false
      local tr = find_track_by_name(trackname)
      if tr then
        local tk = first_midi_take_on_track(tr)
        if tk then
          -- Get measure bounds to find OV note
          local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
          local time_start = reaper.TimeMap_QNToTime(qn_start)
          local time_end = reaper.TimeMap_QNToTime(qn_end)
          local ppq_meas_start = reaper.MIDI_GetPPQPosFromProjTime(tk, time_start)
          local ppq_meas_end = reaper.MIDI_GetPPQPosFromProjTime(tk, time_end)
          
          -- Find the OV note in this measure
          local ov_ppq_s, ov_ppq_e = nil, nil
          local _, note_cnt = reaper.MIDI_CountEvts(tk)
          for ni = 0, note_cnt - 1 do
            local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
            if ok and pitch == OVERDRIVE_PITCH then
              if ppq_s < ppq_meas_end and ppq_e > ppq_meas_start then
                ov_ppq_s, ov_ppq_e = ppq_s, ppq_e
                break
              end
            end
          end
          
          if ov_ppq_s and ov_ppq_e then
            -- Check all measures this OV note covers for playable notes
            local ov_proj_start = reaper.MIDI_GetProjTimeFromPPQPos(tk, ov_ppq_s)
            local ov_proj_end = reaper.MIDI_GetProjTimeFromPPQPos(tk, ov_ppq_e)
            
            local span_has_notes = false
            local first_m = OVERDRIVE_MEASURES.first or 1
            local last_m = OVERDRIVE_MEASURES.last or 1
            
            for m = first_m, last_m do
              local _, qn_m_start, qn_m_end = reaper.TimeMap_GetMeasureInfo(0, m - 1)
              local meas_time_start = reaper.TimeMap_QNToTime(qn_m_start)
              local meas_time_end = reaper.TimeMap_QNToTime(qn_m_end)
              
              -- Check if OV covers this measure
              local epsilon = 0.0001
              if ov_proj_start < (meas_time_end - epsilon) and ov_proj_end > (meas_time_start + epsilon) then
                -- OV covers this measure - check for notes (note: 0 is falsy-like, must check > 0)
                local note_count = OVERDRIVE_NOTES[row] and OVERDRIVE_NOTES[row][m] or 0
                if note_count > 0 then
                  span_has_notes = true
                  break
                end
              end
            end
            
            -- Only invalid if the entire span has no notes
            still_invalid = not span_has_notes
          end
        end
      end
      
      if still_invalid then
        -- Delete the OV note
        if tr then
          local tk = first_midi_take_on_track(tr)
          if tk then
            local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
            local time_start = reaper.TimeMap_QNToTime(qn_start)
            local time_end = reaper.TimeMap_QNToTime(qn_end)
            local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(tk, time_start)
            local ppq_end = reaper.MIDI_GetPPQPosFromProjTime(tk, time_end)
            
            local _, note_cnt = reaper.MIDI_CountEvts(tk)
            for ni = note_cnt - 1, 0, -1 do
              local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
              if ok and pitch == OVERDRIVE_PITCH then
                if ppq_s < ppq_end and ppq_e > ppq_start then
                  reaper.MIDI_DeleteNote(tk, ni)
                  break
                end
              end
            end
            reaper.MIDI_Sort(tk)
            collect_overdrive_data()
          end
        end
      end
      
      -- Remove from pending list
      table.remove(PENDING_OV_DELETIONS, i)
    else
      i = i + 1
    end
  end
end

function draw_table(ctx, redirect_focus_after_click)
  -- Dispatch to specialized table for Overdrive tab
  if current_tab == "Overdrive" then
    draw_overdrive_table(ctx, redirect_focus_after_click)
    return
  end

  local row_h   = ImGui.ImGui_GetTextLineHeightWithSpacing(ctx) * 0.976
  local row_of_cursor = active_region_index()

  --------------------------------------------------------------
  -- HEADER (fixed, no extra child)
  --------------------------------------------------------------
  if ImGui.ImGui_BeginTable(
      ctx, "hdr_tbl", 2,
      ImGui.ImGui_TableFlags_SizingFixedFit() +
      ImGui.ImGui_TableFlags_Borders()
    ) then

    local display_diff
    if current_tab == "Vocals" then
      display_diff = VOCALS_MODE
    elseif current_tab == "Venue" then
      display_diff = VENUE_MODE
    elseif current_tab == "Keys" and PRO_KEYS_ACTIVE then
      local diff_map = { Expert="X", Hard="H", Medium="M", Easy="E" }
      display_diff = "Pro " .. (diff_map[ACTIVE_DIFF] or "X")
    else
      display_diff = ACTIVE_DIFF
    end

    ImGui.ImGui_TableSetupColumn(
      ctx, "Region",
      ImGui.ImGui_TableColumnFlags_WidthFixed(), FIRST_COL_W
    )
    ImGui.ImGui_TableSetupColumn(
      ctx, display_diff,
      ImGui.ImGui_TableColumnFlags_WidthFixed(), REGION_COL_W
    )

    ImGui.ImGui_TableNextRow(ctx, ImGui.ImGui_TableRowFlags_Headers())

    ImGui.ImGui_TableNextColumn(ctx)
    ImGui.ImGui_Text(ctx, "Region")

    ImGui.ImGui_TableNextColumn(ctx)
    local x0 = ImGui.ImGui_GetCursorPosX(ctx)
    local y0 = ImGui.ImGui_GetCursorPosY(ctx)
    local w  = select(1, ImGui.ImGui_GetContentRegionAvail(ctx))

    ImGui.ImGui_Text(ctx, display_diff)

    local pct = diff_pct(current_tab, display_diff)
    local t   = tostring(pct) .. "%"
    local tw  = select(1, ImGui.ImGui_CalcTextSize(ctx, t))

    ImGui.ImGui_SetCursorPosX(ctx, x0 + w - tw)
    ImGui.ImGui_SetCursorPosY(ctx, y0)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), pct_to_u32(pct))
    ImGui.ImGui_Text(ctx, t)
    ImGui.ImGui_PopStyleColor(ctx)

    ImGui.ImGui_EndTable(ctx)
  end

  --------------------------------------------------------------
  -- BODY metrics
  --------------------------------------------------------------
  local avail_h  = select(2, ImGui.ImGui_GetContentRegionAvail(ctx))
  local rows_fit = math.max(1, math.min(#REGIONS, math.floor(avail_h / row_h)))
  local body_h   = rows_fit * row_h
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
  --------------------------------------------------------------
  local child_flags = ImGui.ImGui_WindowFlags_NoScrollWithMouse()
  if ImGui.ImGui_BeginChild(ctx, "rows_scroller", 0, body_h, 0, child_flags) then

    local sy = ImGui.ImGui_GetScrollY(ctx)

    if not need_center_now then
      local n_from_sy = math.max(0, math.min(
        max_n, math.floor((sy / row_h) + 0.5)
      ))
      if TAB_SCROLL_ROW[key] ~= n_from_sy then
        TAB_SCROLL_ROW[key] = n_from_sy
      end
    end

    if TAB_SCROLL_ROW[key] ~= nil then
      local target_sy = (TAB_SCROLL_ROW[key] or 0) * row_h
      if math.abs(sy - target_sy) > 0.5 then
        ImGui.ImGui_SetScrollY(ctx, target_sy)
        sy = target_sy
      end
    end

    if ImGui.ImGui_IsWindowHovered(ctx, 0) then
      local wheel = ImGui.ImGui_GetMouseWheel(ctx) or 0
      if wheel ~= 0 then
        local step = (wheel > 0) and -1 or 1
        local n = (TAB_SCROLL_ROW[key] or 0) + step
        if n < 0 then n = 0
        elseif n > max_n then n = max_n end
        TAB_SCROLL_ROW[key] = n
        ImGui.ImGui_SetScrollY(ctx, n * row_h)
      end
    end

    if ImGui.ImGui_BeginTable(
        ctx, "body_tbl", 2,
        ImGui.ImGui_TableFlags_SizingFixedFit() +
        ImGui.ImGui_TableFlags_Borders()
      ) then

      local display_diff
      if current_tab == "Vocals" then
        display_diff = VOCALS_MODE
      elseif current_tab == "Venue" then
        display_diff = VENUE_MODE
      elseif current_tab == "Keys" and PRO_KEYS_ACTIVE then
        local diff_map = { Expert="X", Hard="H", Medium="M", Easy="E" }
        display_diff = "Pro " .. (diff_map[ACTIVE_DIFF] or "X")
      else
        display_diff = ACTIVE_DIFF
      end

      ImGui.ImGui_TableSetupColumn(
        ctx, "Region",
        ImGui.ImGui_TableColumnFlags_WidthFixed(), FIRST_COL_W
      )
      ImGui.ImGui_TableSetupColumn(
        ctx, display_diff,
        ImGui.ImGui_TableColumnFlags_WidthFixed(), REGION_COL_W
      )

      local hovered_region_row = nil
      local region_cell_positions = {}

      for r = 1, #REGIONS do
        ImGui.ImGui_TableNextRow(ctx)

        -- Region cell
        ImGui.ImGui_TableNextColumn(ctx)
        ImGui.ImGui_TableSetBgColor(
          ctx, ImGui.ImGui_TableBgTarget_CellBg(), REG_COL_U32[r].header
        )
        
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
        local cell_bg = (row_of_cursor == r) and REG_COL_U32[r].header
                                         or  REG_COL_U32[r].cell
        ImGui.ImGui_TableSetBgColor(
          ctx, ImGui.ImGui_TableBgTarget_CellBg(), cell_bg
        )

        local st
        if current_tab == "Keys" and PRO_KEYS_ACTIVE then
          local diff_map = { Expert="X", Hard="H", Medium="M", Easy="E" }
          local diff_key = diff_map[ACTIVE_DIFF] or "X"
          st = (STATE_PRO_KEYS[diff_key] and STATE_PRO_KEYS[diff_key][r]) or 0
        else
          st = (STATE[current_tab]
                     and STATE[current_tab][display_diff]
                     and STATE[current_tab][display_diff][r]) or 0
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
        local cell_w = ImGui.ImGui_GetContentRegionAvail(ctx) + 50  -- approximate width
        local cell_h = row_h
        local mouse_in_cell = mouse_x >= prog_cell_x and mouse_x < prog_cell_x + cell_w
                          and mouse_y >= prog_cell_y and mouse_y < prog_cell_y + cell_h
        
        if PAINT.down and mouse_in_cell and not PAINT.seEN[r] then
          apply_toggle(current_tab, display_diff, r)
          PAINT.seEN[r], PAINT.did_any = true, true
          -- Store redirect to call on mouse release, don't call immediately
          if redirect_focus_after_click then
            PAINT.pending_redirect = redirect_focus_after_click
          end
        end

        -- Handle single click (only if not already processed by drag-paint)
        if clicked and not PAINT.seEN[r] then
          apply_toggle(current_tab, display_diff, r)
          PAINT.seEN[r], PAINT.did_any = true, true
          -- Store redirect to call on mouse release, don't call immediately
          if redirect_focus_after_click then
            PAINT.pending_redirect = redirect_focus_after_click
          end
        end

        ImGui.ImGui_PopID(ctx)
      end
      
      -- Draw preview line showing where cursor would land after jump
      if hovered_region_row and row_of_cursor then
        draw_preview_line(ctx, row_of_cursor, hovered_region_row, region_cell_positions, row_h)
      end

      ImGui.ImGui_EndTable(ctx)
    end
  end
  ImGui.ImGui_EndChild(ctx)
end

-- Overdrive table drawing -----------------------------------------------

-- Track last cursor measure for centering logic (edit cursor only)
local OV_LAST_CURSOR_M = nil

-- Helper to get region color as U32
local function get_region_color_u32(region, alpha)
  local native_color = region.color or 0
  if native_color == 0 then
    native_color = reaper.GetThemeColor("col_region", 0) or 0
  end
  if (native_color & 0x1000000) ~= 0 then
    native_color = native_color & 0xFFFFFF
  end
  local r, g, b = reaper.ColorFromNative(native_color)
  return ImGui.ImGui_ColorConvertDouble4ToU32((r or 0)/255, (g or 0)/255, (b or 0)/255, alpha or 1)
end

-- Helper to find region containing a given time
local function find_region_at_time(t)
  for i = 1, #REGIONS do
    local rs = REGIONS[i].pos or 0
    local re = REGIONS[i].r_end or 0
    if t >= rs and t < re then
      return REGIONS[i], i
    end
  end
  return nil, nil
end

-- Draw region color bar above overdrive table
local function draw_region_bar(ctx, first_m, start_col, end_col, cell_w, label_w, cell_padding, border_padding)
  local bar_h = 6  -- Height of the region bar
  local bar_y_offset = 0  -- Gap between bar and table
  
  -- Get current cursor position (where bar will be drawn)
  local bar_start_x, bar_start_y = ImGui.ImGui_GetCursorScreenPos(ctx)
  
  -- Offset for the label column
  local measures_start_x = bar_start_x + label_w + cell_padding + (border_padding / 2) - 4
  
  local dl = ImGui.ImGui_GetWindowDrawList(ctx)
  
  -- Track which region each measure belongs to
  local measure_regions = {}
  for c = start_col, end_col do
    local measure_num = (OVERDRIVE_MEASURES.first or 1) + c
    -- Get the time at the first beat of this measure
    local _, qn_start = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
    local time_start = reaper.TimeMap_QNToTime(qn_start)
    
    local region = find_region_at_time(time_start)
    measure_regions[c] = region
  end
  
  -- Draw continuous segments for each region and store segment bounds for tooltip
  local col_total_w = cell_w + cell_padding
  local segment_start_col = start_col
  local current_region = measure_regions[start_col]
  local segments = {}  -- Store segment bounds and region for tooltip
  
  for c = start_col, end_col + 1 do
    local this_region = measure_regions[c]
    
    -- Check if region changed or we're at the end
    if this_region ~= current_region or c > end_col then
      -- Draw segment for the previous region
      if current_region then
        local seg_x1 = measures_start_x + (segment_start_col - start_col) * col_total_w
        local seg_x2 = measures_start_x + (c - start_col) * col_total_w - (cell_padding / 2)
        local col = get_region_color_u32(current_region, 1.0)
        
        ImGui.ImGui_DrawList_AddRectFilled(dl, seg_x1, bar_start_y, seg_x2, bar_start_y + bar_h, col)
        table.insert(segments, { x1 = seg_x1, x2 = seg_x2, region = current_region })
      end
      
      -- Start new segment
      segment_start_col = c
      current_region = this_region
    end
  end
  
  -- Check for tooltip on hover
  local mouse_x, mouse_y = ImGui.ImGui_GetMousePos(ctx)
  if mouse_y >= bar_start_y and mouse_y <= bar_start_y + bar_h then
    for _, seg in ipairs(segments) do
      if mouse_x >= seg.x1 and mouse_x <= seg.x2 then
        ImGui.ImGui_SetTooltip(ctx, seg.region.name or "Unknown Region")
        break
      end
    end
  end
  
  -- Reserve space for the bar
  ImGui.ImGui_Dummy(ctx, 0, bar_h + bar_y_offset)
end

-- Helper to get track color as U32
local function get_track_color_u32(trackname, alpha)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, name = reaper.GetTrackName(tr)
    if ok and name == trackname then
      local native_color = reaper.GetTrackColor(tr)
      if native_color == 0 then
        -- Track has no custom color, return a default gray
        return ImGui.ImGui_ColorConvertDouble4ToU32(0.3, 0.3, 0.3, alpha or 1)
      end
      -- Convert native color to RGB
      local r, g, b = reaper.ColorFromNative(native_color)
      return ImGui.ImGui_ColorConvertDouble4ToU32((r or 0)/255, (g or 0)/255, (b or 0)/255, alpha or 1)
    end
  end
  -- Track not found, return default
  return ImGui.ImGui_ColorConvertDouble4ToU32(0.3, 0.3, 0.3, alpha or 1)
end

-- Helper to find track by name
local function find_track_by_name(trackname)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, name = reaper.GetTrackName(tr)
    if ok and name == trackname then
      return tr
    end
  end
  return nil
end

-- Helper to get measure number from PPQ position (1-based)
local function ppq_to_measure(tk, ppq)
  local proj_time = reaper.MIDI_GetProjTimeFromPPQPos(tk, ppq)
  local _, measure_raw = reaper.TimeMap2_timeToBeats(0, proj_time)
  return math.floor(measure_raw) + 1
end

-- Helper to find an existing overdrive note's exact PPQ bounds in any track for a given measure
local function find_existing_ov_ppq_bounds(measure_num)
  -- Get measure bounds in project time
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
  local time_start = reaper.TimeMap_QNToTime(qn_start)
  local time_end = reaper.TimeMap_QNToTime(qn_end)
  
  -- Search all overdrive tracks for an existing OV note in this measure
  for _, tn in ipairs(OVERDRIVE_TRACKS) do
    local tr = find_track_by_name(tn)
    if tr then
      local tk = first_midi_take_on_track(tr)
      if tk then
        local ppq_meas_start = reaper.MIDI_GetPPQPosFromProjTime(tk, time_start)
        local ppq_meas_end = reaper.MIDI_GetPPQPosFromProjTime(tk, time_end)
        
        local _, note_cnt = reaper.MIDI_CountEvts(tk)
        for ni = 0, note_cnt - 1 do
          local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
          if ok and pitch == OVERDRIVE_PITCH then
            if ppq_s < ppq_meas_end and ppq_e > ppq_meas_start then
              -- Found an OV note in this measure, return its project time bounds
              local proj_time_start = reaper.MIDI_GetProjTimeFromPPQPos(tk, ppq_s)
              local proj_time_end = reaper.MIDI_GetProjTimeFromPPQPos(tk, ppq_e)
              return proj_time_start, proj_time_end
            end
          end
        end
      end
    end
  end
  
  return nil, nil  -- No existing OV found
end

-- Helper to insert overdrive note on a track at exact project time bounds
local function insert_ov_at_times(trackname, proj_time_start, proj_time_end, measure_num)
  local tr = find_track_by_name(trackname)
  if not tr then return false end
  
  local tk = first_midi_take_on_track(tr)
  if not tk then return false end
  
  -- Convert project times to PPQ for this take
  local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(tk, proj_time_start)
  local ppq_end = reaper.MIDI_GetPPQPosFromProjTime(tk, proj_time_end)
  
  -- Get measure bounds for FILL note removal
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
  local meas_time_start = reaper.TimeMap_QNToTime(qn_start)
  local meas_time_end = reaper.TimeMap_QNToTime(qn_end)
  local meas_ppq_start = reaper.MIDI_GetPPQPosFromProjTime(tk, meas_time_start)
  local meas_ppq_end = reaper.MIDI_GetPPQPosFromProjTime(tk, meas_time_end)
  
  -- Remove any FILL notes (120-124) in this measure
  local _, note_cnt = reaper.MIDI_CountEvts(tk)
  for ni = note_cnt - 1, 0, -1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
    if ok and pitch >= 120 and pitch <= 124 then
      if ppq_s < meas_ppq_end and ppq_e > meas_ppq_start then
        reaper.MIDI_DeleteNote(tk, ni)
      end
    end
  end
  
  -- Check if OV already exists in this measure (don't duplicate)
  _, note_cnt = reaper.MIDI_CountEvts(tk)
  for ni = 0, note_cnt - 1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
    if ok and pitch == OVERDRIVE_PITCH then
      if ppq_s < meas_ppq_end and ppq_e > meas_ppq_start then
        -- Already has OV, skip
        reaper.MIDI_Sort(tk)
        return false
      end
    end
  end
  
  -- Insert the new overdrive note
  reaper.MIDI_InsertNote(tk, false, false, ppq_start, ppq_end, 0, OVERDRIVE_PITCH, 100, false)
  reaper.MIDI_Sort(tk)
  return true
end

-- Helper to delete overdrive note from a specific track in a measure
local function delete_ov_from_track(trackname, measure_num)
  local tr = find_track_by_name(trackname)
  if not tr then return false end
  
  local tk = first_midi_take_on_track(tr)
  if not tk then return false end
  
  -- Get measure bounds
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
  local time_start = reaper.TimeMap_QNToTime(qn_start)
  local time_end = reaper.TimeMap_QNToTime(qn_end)
  local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(tk, time_start)
  local ppq_end = reaper.MIDI_GetPPQPosFromProjTime(tk, time_end)
  
  local _, note_cnt = reaper.MIDI_CountEvts(tk)
  local deleted = false
  for ni = note_cnt - 1, 0, -1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
    if ok and pitch == OVERDRIVE_PITCH then
      if ppq_s < ppq_end and ppq_e > ppq_start then
        reaper.MIDI_DeleteNote(tk, ni)
        deleted = true
      end
    end
  end
  
  if deleted then
    reaper.MIDI_Sort(tk)
  end
  return deleted
end

-- Helper to trim OV on a track based on clicked measure position
-- trim_type: "left" (set start to measure end), "right" (set end to measure start), "middle" (isolate measure)
local function trim_ov_on_track(trackname, measure_num, trim_type)
  local tr = find_track_by_name(trackname)
  if not tr then return false end
  
  local tk = first_midi_take_on_track(tr)
  if not tk then return false end
  
  -- Get measure bounds
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
  local time_start = reaper.TimeMap_QNToTime(qn_start)
  local time_end = reaper.TimeMap_QNToTime(qn_end)
  local ppq_meas_start = reaper.MIDI_GetPPQPosFromProjTime(tk, time_start)
  local ppq_meas_end = reaper.MIDI_GetPPQPosFromProjTime(tk, time_end)
  
  local _, note_cnt = reaper.MIDI_CountEvts(tk)
  for ni = 0, note_cnt - 1 do
    local ok, sel, muted, ppq_s, ppq_e, chan, pitch, vel = reaper.MIDI_GetNote(tk, ni)
    if ok and pitch == OVERDRIVE_PITCH then
      if ppq_s < ppq_meas_end and ppq_e > ppq_meas_start then
        if trim_type == "left" then
          -- Set start to end of clicked measure
          reaper.MIDI_SetNote(tk, ni, sel, muted, ppq_meas_end, ppq_e, chan, OVERDRIVE_PITCH, vel, false)
        elseif trim_type == "right" then
          -- Set end to start of clicked measure
          reaper.MIDI_SetNote(tk, ni, sel, muted, ppq_s, ppq_meas_start, chan, OVERDRIVE_PITCH, vel, false)
        else -- "middle"
          -- Isolate just this measure
          reaper.MIDI_SetNote(tk, ni, sel, muted, ppq_meas_start, ppq_meas_end, chan, OVERDRIVE_PITCH, vel, false)
        end
        reaper.MIDI_Sort(tk)
        return true
      end
    end
  end
  return false
end

-- Helper to get the OV note index and bounds that covers a specific measure
local function get_ov_note_in_measure(tk, measure_num)
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
  local time_start = reaper.TimeMap_QNToTime(qn_start)
  local time_end = reaper.TimeMap_QNToTime(qn_end)
  local ppq_meas_start = reaper.MIDI_GetPPQPosFromProjTime(tk, time_start)
  local ppq_meas_end = reaper.MIDI_GetPPQPosFromProjTime(tk, time_end)
  
  local _, note_cnt = reaper.MIDI_CountEvts(tk)
  for ni = 0, note_cnt - 1 do
    local ok, sel, muted, ppq_s, ppq_e, chan, pitch, vel = reaper.MIDI_GetNote(tk, ni)
    if ok and pitch == OVERDRIVE_PITCH then
      if ppq_s < ppq_meas_end and ppq_e > ppq_meas_start then
        return ni, ppq_s, ppq_e, sel, muted, chan, vel
      end
    end
  end
  return nil
end

-- Helper to check if a measure has a FILL (for drums track)
local function measure_has_fill(tk, measure_num)
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
  local time_start = reaper.TimeMap_QNToTime(qn_start)
  local time_end = reaper.TimeMap_QNToTime(qn_end)
  local ppq_meas_start = reaper.MIDI_GetPPQPosFromProjTime(tk, time_start)
  local ppq_meas_end = reaper.MIDI_GetPPQPosFromProjTime(tk, time_end)
  
  local _, note_cnt = reaper.MIDI_CountEvts(tk)
  for ni = 0, note_cnt - 1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
    if ok and pitch >= 120 and pitch <= 124 then
      if ppq_s < ppq_meas_end and ppq_e > ppq_meas_start then
        return true
      end
    end
  end
  return false
end

-- Helper to extend an existing OV note to cover a new measure
-- Returns true if extension happened, false if new note should be created
-- Also extends OV on all other tracks that have OV in the adjacent measure
local function try_extend_adjacent_ov(trackname, measure_num)
  local tr = find_track_by_name(trackname)
  if not tr then return false end
  
  local tk = first_midi_take_on_track(tr)
  if not tk then return false end
  
  -- Get target measure bounds
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
  local time_start = reaper.TimeMap_QNToTime(qn_start)
  local time_end = reaper.TimeMap_QNToTime(qn_end)
  local ppq_meas_start = reaper.MIDI_GetPPQPosFromProjTime(tk, time_start)
  local ppq_meas_end = reaper.MIDI_GetPPQPosFromProjTime(tk, time_end)
  
  -- Check for FILL in target measure (can't place OV there)
  if trackname == "PART DRUMS" and measure_has_fill(tk, measure_num) then
    return false
  end
  
  -- Check previous measure for OV to extend forward
  local prev_measure = measure_num - 1
  local prev_ov_ni, prev_ppq_s, prev_ppq_e, prev_sel, prev_muted, prev_chan, prev_vel
  if prev_measure >= 1 then
    -- Check if previous measure has a FILL (can't extend through it)
    if not (trackname == "PART DRUMS" and measure_has_fill(tk, prev_measure)) then
      prev_ov_ni, prev_ppq_s, prev_ppq_e, prev_sel, prev_muted, prev_chan, prev_vel = get_ov_note_in_measure(tk, prev_measure)
    end
  end
  
  -- Check next measure for OV to extend backward
  local next_measure = measure_num + 1
  local next_ov_ni, next_ppq_s, next_ppq_e, next_sel, next_muted, next_chan, next_vel
  -- Check if next measure has a FILL (can't extend through it)
  if not (trackname == "PART DRUMS" and measure_has_fill(tk, next_measure)) then
    next_ov_ni, next_ppq_s, next_ppq_e, next_sel, next_muted, next_chan, next_vel = get_ov_note_in_measure(tk, next_measure)
  end
  
  -- Helper to extend OV on all other tracks that have OV in the source measure
  local function extend_all_tracks(source_measure, direction)
    for _, tn in ipairs(OVERDRIVE_TRACKS) do
      if tn ~= trackname then
        local other_tr = find_track_by_name(tn)
        if other_tr then
          local other_tk = first_midi_take_on_track(other_tr)
          if other_tk then
            local other_ppq_meas_start = reaper.MIDI_GetPPQPosFromProjTime(other_tk, time_start)
            local other_ppq_meas_end = reaper.MIDI_GetPPQPosFromProjTime(other_tk, time_end)
            
            local ov_ni, ov_ppq_s, ov_ppq_e, ov_sel, ov_muted, ov_chan, ov_vel = get_ov_note_in_measure(other_tk, source_measure)
            if ov_ni then
              if direction == "forward" then
                -- Extend forward to cover target measure
                reaper.MIDI_SetNote(other_tk, ov_ni, ov_sel, ov_muted, ov_ppq_s, other_ppq_meas_end, ov_chan, OVERDRIVE_PITCH, ov_vel, true)
              else
                -- Extend backward to cover target measure
                reaper.MIDI_SetNote(other_tk, ov_ni, ov_sel, ov_muted, other_ppq_meas_start, ov_ppq_e, ov_chan, OVERDRIVE_PITCH, ov_vel, true)
              end
              reaper.MIDI_Sort(other_tk)
            end
          end
        end
      end
    end
  end
  
  -- If both adjacent measures have OV, merge them
  if prev_ov_ni and next_ov_ni then
    -- Extend the previous note to cover through the next note's end
    reaper.MIDI_SetNote(tk, prev_ov_ni, prev_sel, prev_muted, prev_ppq_s, next_ppq_e, prev_chan, OVERDRIVE_PITCH, prev_vel, true)
    -- Delete the next note (indices may have shifted, so re-find it)
    local _, note_cnt = reaper.MIDI_CountEvts(tk)
    for ni = note_cnt - 1, 0, -1 do
      local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
      if ok and pitch == OVERDRIVE_PITCH and ppq_s == next_ppq_s and ppq_e == next_ppq_e then
        reaper.MIDI_DeleteNote(tk, ni)
        break
      end
    end
    reaper.MIDI_Sort(tk)
    -- Extend other tracks forward (they will merge if needed on their own later)
    extend_all_tracks(prev_measure, "forward")
    return true
  elseif prev_ov_ni then
    -- Extend previous note to cover this measure
    reaper.MIDI_SetNote(tk, prev_ov_ni, prev_sel, prev_muted, prev_ppq_s, ppq_meas_end, prev_chan, OVERDRIVE_PITCH, prev_vel, true)
    reaper.MIDI_Sort(tk)
    -- Extend OV on all other tracks that have OV in the previous measure
    extend_all_tracks(prev_measure, "forward")
    return true
  elseif next_ov_ni then
    -- Extend next note backward to cover this measure
    reaper.MIDI_SetNote(tk, next_ov_ni, next_sel, next_muted, ppq_meas_start, next_ppq_e, next_chan, OVERDRIVE_PITCH, next_vel, true)
    reaper.MIDI_Sort(tk)
    -- Extend OV on all other tracks that have OV in the next measure
    extend_all_tracks(next_measure, "backward")
    return true
  end
  
  return false
end

-- Helper to count how many tracks have OV in a given measure
local function count_tracks_with_ov(measure_num)
  local count = 0
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
  local time_start = reaper.TimeMap_QNToTime(qn_start)
  local time_end = reaper.TimeMap_QNToTime(qn_end)
  
  for _, tn in ipairs(OVERDRIVE_TRACKS) do
    local tr = find_track_by_name(tn)
    if tr then
      local tk = first_midi_take_on_track(tr)
      if tk then
        local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(tk, time_start)
        local ppq_end = reaper.MIDI_GetPPQPosFromProjTime(tk, time_end)
        
        local _, note_cnt = reaper.MIDI_CountEvts(tk)
        for ni = 0, note_cnt - 1 do
          local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
          if ok and pitch == OVERDRIVE_PITCH then
            if ppq_s < ppq_end and ppq_e > ppq_start then
              count = count + 1
              break  -- Found one on this track, move to next track
            end
          end
        end
      end
    end
  end
  
  return count
end

-- Helper to get the start time of a FILL in a given measure (from drums track)
local function get_fill_start_time(measure_num)
  local drums_track = find_track_by_name("PART DRUMS")
  if not drums_track then return nil end
  
  local tk = first_midi_take_on_track(drums_track)
  if not tk then return nil end
  
  -- Get measure bounds
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
  local time_start = reaper.TimeMap_QNToTime(qn_start)
  local time_end = reaper.TimeMap_QNToTime(qn_end)
  local ppq_meas_start = reaper.MIDI_GetPPQPosFromProjTime(tk, time_start)
  local ppq_meas_end = reaper.MIDI_GetPPQPosFromProjTime(tk, time_end)
  
  local _, note_cnt = reaper.MIDI_CountEvts(tk)
  for ni = 0, note_cnt - 1 do
    local ok, _, _, ppq_s, _, _, pitch = reaper.MIDI_GetNote(tk, ni)
    if ok and pitch >= 120 and pitch <= 124 then
      if ppq_s >= ppq_meas_start and ppq_s < ppq_meas_end then
        -- Found a FILL note starting in this measure, return its start time
        return reaper.MIDI_GetProjTimeFromPPQPos(tk, ppq_s)
      end
    end
  end
  
  return nil
end

-- Helper to pull back OV notes that touch a fill start time by 1/64th note
-- Checks previous measure for all 4 tracks
local function pull_back_ov_touching_fill(fill_measure_num)
  local prev_measure = fill_measure_num - 1
  if prev_measure < 1 then return end
  
  -- Get the fill start time from drums track in fill_measure_num
  local fill_start_time = get_fill_start_time(fill_measure_num)
  if not fill_start_time then return end
  
  -- Calculate 1/64th note duration at the fill start position
  -- Get tempo at fill start
  local bpm = reaper.TimeMap_GetDividedBpmAtTime(fill_start_time)
  local beat_duration = 60.0 / bpm  -- Duration of one beat in seconds
  local sixtyfourth_note = beat_duration / 16  -- 1/64th note = 1/16th of a beat (since a beat is a quarter note)
  
  -- Get previous measure bounds
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, prev_measure - 1)
  local prev_meas_time_start = reaper.TimeMap_QNToTime(qn_start)
  local prev_meas_time_end = reaper.TimeMap_QNToTime(qn_end)
  
  -- Check all 4 overdrive tracks
  for _, tn in ipairs(OVERDRIVE_TRACKS) do
    local tr = find_track_by_name(tn)
    if tr then
      local tk = first_midi_take_on_track(tr)
      if tk then
        local ppq_meas_start = reaper.MIDI_GetPPQPosFromProjTime(tk, prev_meas_time_start)
        local ppq_meas_end = reaper.MIDI_GetPPQPosFromProjTime(tk, prev_meas_time_end)
        local ppq_fill_start = reaper.MIDI_GetPPQPosFromProjTime(tk, fill_start_time)
        local ppq_pullback = reaper.MIDI_GetPPQPosFromProjTime(tk, fill_start_time - sixtyfourth_note)
        
        local _, note_cnt = reaper.MIDI_CountEvts(tk)
        for ni = 0, note_cnt - 1 do
          local ok, sel, muted, ppq_s, ppq_e, chan, pitch, vel = reaper.MIDI_GetNote(tk, ni)
          if ok and pitch == OVERDRIVE_PITCH then
            -- Check if this OV note is in the previous measure and ends at or after fill start
            if ppq_s >= ppq_meas_start and ppq_s < ppq_meas_end then
              -- OV starts in previous measure - check if it touches fill start
              if ppq_e >= ppq_fill_start then
                -- Pull back the end by 1/64th note
                reaper.MIDI_SetNote(tk, ni, sel, muted, ppq_s, ppq_pullback, chan, pitch, vel, true)
              end
            end
          end
        end
        reaper.MIDI_Sort(tk)
      end
    end
  end
end

-- Helper to get the end time of a FILL in a given measure (from drums track)
local function get_fill_end_time(measure_num)
  local drums_track = find_track_by_name("PART DRUMS")
  if not drums_track then return nil end
  
  local tk = first_midi_take_on_track(drums_track)
  if not tk then return nil end
  
  -- Get measure bounds
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
  local time_start = reaper.TimeMap_QNToTime(qn_start)
  local time_end = reaper.TimeMap_QNToTime(qn_end)
  local ppq_meas_start = reaper.MIDI_GetPPQPosFromProjTime(tk, time_start)
  local ppq_meas_end = reaper.MIDI_GetPPQPosFromProjTime(tk, time_end)
  
  local _, note_cnt = reaper.MIDI_CountEvts(tk)
  for ni = 0, note_cnt - 1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
    if ok and pitch >= 120 and pitch <= 124 then
      if ppq_s >= ppq_meas_start and ppq_s < ppq_meas_end then
        -- Found a FILL note in this measure, return its end time
        return reaper.MIDI_GetProjTimeFromPPQPos(tk, ppq_e)
      end
    end
  end
  
  return nil
end

-- Helper to push forward OV notes that touch a fill end time by 1/64th note
-- Checks next measure for all 4 tracks
local function push_forward_ov_touching_fill(fill_measure_num)
  local next_measure = fill_measure_num + 1
  
  -- Get the fill end time from drums track in fill_measure_num
  local fill_end_time = get_fill_end_time(fill_measure_num)
  if not fill_end_time then return end
  
  -- Calculate 1/64th note duration at the fill end position
  local bpm = reaper.TimeMap_GetDividedBpmAtTime(fill_end_time)
  local beat_duration = 60.0 / bpm
  local sixtyfourth_note = beat_duration / 16
  
  -- Get next measure bounds
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, next_measure - 1)
  local next_meas_time_start = reaper.TimeMap_QNToTime(qn_start)
  local next_meas_time_end = reaper.TimeMap_QNToTime(qn_end)
  
  -- Check all 4 overdrive tracks
  for _, tn in ipairs(OVERDRIVE_TRACKS) do
    local tr = find_track_by_name(tn)
    if tr then
      local tk = first_midi_take_on_track(tr)
      if tk then
        local ppq_meas_start = reaper.MIDI_GetPPQPosFromProjTime(tk, next_meas_time_start)
        local ppq_meas_end = reaper.MIDI_GetPPQPosFromProjTime(tk, next_meas_time_end)
        local ppq_fill_end = reaper.MIDI_GetPPQPosFromProjTime(tk, fill_end_time)
        local ppq_pushforward = reaper.MIDI_GetPPQPosFromProjTime(tk, fill_end_time + sixtyfourth_note)
        
        local _, note_cnt = reaper.MIDI_CountEvts(tk)
        for ni = 0, note_cnt - 1 do
          local ok, sel, muted, ppq_s, ppq_e, chan, pitch, vel = reaper.MIDI_GetNote(tk, ni)
          if ok and pitch == OVERDRIVE_PITCH then
            -- Check if this OV note is in the next measure and starts at or before fill end
            if ppq_s >= ppq_meas_start and ppq_s < ppq_meas_end then
              -- OV starts in next measure - check if it touches fill end
              if ppq_s <= ppq_fill_end then
                -- Push forward the start by 1/64th note
                reaper.MIDI_SetNote(tk, ni, sel, muted, ppq_pushforward, ppq_e, chan, pitch, vel, true)
              end
            end
          end
        end
        reaper.MIDI_Sort(tk)
      end
    end
  end
end

-- Toggle overdrive note for a specific track and measure
local function toggle_overdrive_note(trackname, measure_num)
  -- Prevent OV placement in the last measure (contains [end] event)
  local last_m = OVERDRIVE_MEASURES and OVERDRIVE_MEASURES.last or 9999
  if measure_num >= last_m then
    return
  end
  
  local tr = find_track_by_name(trackname)
  if not tr then return end
  
  local tk = first_midi_take_on_track(tr)
  if not tk then return end
  
  -- Get measure bounds in project time
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
  local time_start = reaper.TimeMap_QNToTime(qn_start)
  local time_end = reaper.TimeMap_QNToTime(qn_end)
  
  -- Convert to PPQ
  local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(tk, time_start)
  local ppq_end = reaper.MIDI_GetPPQPosFromProjTime(tk, time_end)
  
  reaper.Undo_BeginBlock()
  
  -- First, remove any FILL notes (120-124) in this measure
  local _, note_cnt = reaper.MIDI_CountEvts(tk)
  for ni = note_cnt - 1, 0, -1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
    if ok and pitch >= 120 and pitch <= 124 then
      if ppq_s < ppq_end and ppq_e > ppq_start then
        reaper.MIDI_DeleteNote(tk, ni)
      end
    end
  end
  
  -- Re-check for overdrive note after deleting fills (indices may have changed)
  _, note_cnt = reaper.MIDI_CountEvts(tk)
  local found_note_idx = nil
  local found_ppq_s, found_ppq_e = nil, nil
  for ni = 0, note_cnt - 1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
    if ok and pitch == OVERDRIVE_PITCH then
      if ppq_s < ppq_end and ppq_e > ppq_start then
        found_note_idx = ni
        found_ppq_s = ppq_s
        found_ppq_e = ppq_e
        break
      end
    end
  end
  
  local placing_new_ov = (found_note_idx == nil)
  
  if found_note_idx then
    -- This track has OV - check if other tracks also have OV in this measure
    local ov_count = count_tracks_with_ov(measure_num)
    
    -- Check if OV spans multiple measures
    local ov_start_measure = ppq_to_measure(tk, found_ppq_s)
    local ov_end_measure = ppq_to_measure(tk, found_ppq_e - 1)  -- -1 to handle notes ending exactly on measure boundary
    local spans_multiple = (ov_start_measure ~= ov_end_measure)
    
    if ov_count > 1 then
      -- Multiple tracks have OV - delete OV from all OTHER tracks, keep this one
      for _, tn in ipairs(OVERDRIVE_TRACKS) do
        if tn ~= trackname then
          delete_ov_from_track(tn, measure_num)
        end
      end
    else
      -- Only this track has OV
      if spans_multiple then
        -- Multi-measure span - trim instead of delete
        local is_leftmost = (measure_num == ov_start_measure)
        local is_rightmost = (measure_num == ov_end_measure)
        
        -- Get note properties to preserve
        local ok, sel, muted, _, _, chan, _, vel = reaper.MIDI_GetNote(tk, found_note_idx)
        
        if is_leftmost then
          -- Clicked on leftmost measure - set start to end of clicked measure
          reaper.MIDI_SetNote(tk, found_note_idx, sel, muted, ppq_end, found_ppq_e, chan, OVERDRIVE_PITCH, vel, false)
        elseif is_rightmost then
          -- Clicked on rightmost measure - set end to start of clicked measure
          reaper.MIDI_SetNote(tk, found_note_idx, sel, muted, found_ppq_s, ppq_start, chan, OVERDRIVE_PITCH, vel, false)
        else
          -- Clicked on middle measure - isolate just this measure
          reaper.MIDI_SetNote(tk, found_note_idx, sel, muted, ppq_start, ppq_end, chan, OVERDRIVE_PITCH, vel, false)
        end
      else
        -- Single measure OV - delete it like usual
        reaper.MIDI_DeleteNote(tk, found_note_idx)
      end
    end
  else
    -- Check if another track has OV in this measure - if so, duplicate to all tracks
    local existing_ov_start, existing_ov_end = find_existing_ov_ppq_bounds(measure_num)
    
    if existing_ov_start and existing_ov_end then
      -- Another track has OV - duplicate to ALL tracks that don't have it yet
      for _, tn in ipairs(OVERDRIVE_TRACKS) do
        insert_ov_at_times(tn, existing_ov_start, existing_ov_end, measure_num)
      end
    else
      -- No existing OV anywhere - try to extend adjacent OV first
      local extended = try_extend_adjacent_ov(trackname, measure_num)
      if not extended then
        -- No adjacent OV to extend - insert a new overdrive note spanning the measure
        reaper.MIDI_InsertNote(tk, false, false, ppq_start, ppq_end, 0, OVERDRIVE_PITCH, 100, false)
      end
    end
    
    -- If placing OV on drums track, check for fills before/after
    if trackname == "PART DRUMS" then
      -- Check if there's a fill in the previous measure that ends where this OV starts
      local prev_measure = measure_num - 1
      if prev_measure >= 1 then
        local fill_end = get_fill_end_time(prev_measure)
        if fill_end then
          -- Push forward this OV and any others that start at or before the fill end
          push_forward_ov_touching_fill(prev_measure)
        end
      end
      
      -- Check if there's a fill in the next measure that starts where this OV ends
      local next_measure = measure_num + 1
      local fill_start = get_fill_start_time(next_measure)
      if fill_start then
        -- Pull back this OV and any others that end at or after the fill start
        pull_back_ov_touching_fill(next_measure)
      end
    end
  end
  
  reaper.MIDI_Sort(tk)
  reaper.Undo_EndBlock("Toggle Overdrive Note", -1)
  
  -- Trigger data refresh
  collect_overdrive_data()
  
  -- If we just placed new OV, check ALL tracks for invalid OV (no notes) and schedule deletion
  if placing_new_ov then
    for i, tn in ipairs(OVERDRIVE_TRACKS) do
      local row = OVERDRIVE_ROWS[i]
      local note_count = OVERDRIVE_NOTES[row] and OVERDRIVE_NOTES[row][measure_num] or 0
      local has_notes = note_count > 0
      local has_ov = OVERDRIVE_DATA[row] and OVERDRIVE_DATA[row][measure_num]
      
      if has_ov and not has_notes then
        -- Schedule deletion in 0.3 seconds
        table.insert(PENDING_OV_DELETIONS, {
          trackname = tn,
          measure_num = measure_num,
          row = row,
          delete_time = reaper.time_precise() + 0.3
        })
      end
    end
  end
end

-- Toggle FILL notes (120-124) for drums - right-click action
local function toggle_fill_note(trackname, measure_num)
  -- Prevent FILL placement in the last measure (contains [end] event)
  local last_m = OVERDRIVE_MEASURES and OVERDRIVE_MEASURES.last or 9999
  if measure_num >= last_m then
    return
  end
  
  local tr = find_track_by_name(trackname)
  if not tr then return end
  
  local tk = first_midi_take_on_track(tr)
  if not tk then return end
  
  -- Get measure bounds in project time
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
  local time_start = reaper.TimeMap_QNToTime(qn_start)
  local time_end = reaper.TimeMap_QNToTime(qn_end)
  
  -- Convert to PPQ
  local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(tk, time_start)
  local ppq_end = reaper.MIDI_GetPPQPosFromProjTime(tk, time_end)
  
  local _, note_cnt = reaper.MIDI_CountEvts(tk)
  
  -- Check if FILL notes already exist in this measure
  local has_fill = false
  for ni = 0, note_cnt - 1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
    if ok and pitch >= 120 and pitch <= 124 then
      if ppq_s < ppq_end and ppq_e > ppq_start then
        has_fill = true
        break
      end
    end
  end
  
  reaper.Undo_BeginBlock()
  
  if has_fill then
    -- Remove existing FILL notes
    _, note_cnt = reaper.MIDI_CountEvts(tk)
    for ni = note_cnt - 1, 0, -1 do
      local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
      if ok and pitch >= 120 and pitch <= 124 then
        if ppq_s < ppq_end and ppq_e > ppq_start then
          reaper.MIDI_DeleteNote(tk, ni)
        end
      end
    end
  else
    -- Remove any existing OV note first
    _, note_cnt = reaper.MIDI_CountEvts(tk)
    for ni = note_cnt - 1, 0, -1 do
      local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(tk, ni)
      if ok and pitch == OVERDRIVE_PITCH then
        if ppq_s < ppq_end and ppq_e > ppq_start then
          reaper.MIDI_DeleteNote(tk, ni)
        end
      end
    end
    
    -- Insert FILL notes (120-124)
    for pitch = 120, 124 do
      reaper.MIDI_InsertNote(tk, false, false, ppq_start, ppq_end, 0, pitch, 100, false)
    end
    
    reaper.MIDI_Sort(tk)
    
    -- Pull back any OV notes in previous measure that touch this fill's start
    pull_back_ov_touching_fill(measure_num)
    
    -- Push forward any OV notes in next measure that touch this fill's end
    push_forward_ov_touching_fill(measure_num)
  end
  
  reaper.MIDI_Sort(tk)
  reaper.Undo_EndBlock("Toggle Fill Notes", -1)
  
  -- Trigger data refresh
  collect_overdrive_data()
end

function draw_overdrive_table(ctx, redirect_focus_after_click)
  -- Process any pending OV deletions
  process_pending_ov_deletions()
  
  -- Highlight distance (global so it persists)
  OV_HIGHLIGHT_DISTANCE = OV_HIGHLIGHT_DISTANCE or 10
  OV_HIGHLIGHT_ENABLED = OV_HIGHLIGHT_ENABLED == nil and true or OV_HIGHLIGHT_ENABLED
  
  -- Drum Fill Guide mode (toggleable, shows only Drums guide)
  DRUM_FILL_GUIDE_MODE = DRUM_FILL_GUIDE_MODE or false
  DRUM_FILL_GUIDE_WIDTH = DRUM_FILL_GUIDE_WIDTH or 4
  SAVED_OV_HIGHLIGHT_DISTANCE = SAVED_OV_HIGHLIGHT_DISTANCE or OV_HIGHLIGHT_DISTANCE
  
  local first_m = OVERDRIVE_MEASURES.first or 1
  local last_m = OVERDRIVE_MEASURES.last or 1
  local num_measures = last_m - first_m + 1
  
  if num_measures <= 0 then
    ImGui.ImGui_Text(ctx, "No measures found")
    return
  end
  
  local row_h = ImGui.ImGui_GetTextLineHeightWithSpacing(ctx) * 1.2
  local cell_w = 26  -- Width per measure column
  local label_w = 40  -- Width for row labels
  local cell_padding = 9  -- Padding per cell for borders
  local border_padding = 14  -- Left and right table borders
  
  -- Helper to calculate brightness alpha from note count (exponential scaling)
  local function note_count_to_alpha(count)
    local base_alpha = 0  -- Minimum brightness (black)
    local max_alpha = 0.75   -- Maximum brightness
    local max_notes = OV_MAX_NOTES_BRIGHTNESS or 40
    local normalized = math.min(1.0, count / max_notes)
    local scaled = math.sqrt(normalized)  -- Exponential: brightens quickly at first
    return base_alpha + (max_alpha - base_alpha) * scaled
  end
  
  -- Get track RGB values for each row (for dynamic brightness calculation)
  local row_rgb = {}
  for i, row in ipairs(OVERDRIVE_ROWS) do
    local trackname = OVERDRIVE_TRACKS[i]
    local n = reaper.CountTracks(0)
    local r, g, b = 0.3, 0.3, 0.3  -- Default gray
    for j = 0, n - 1 do
      local tr = reaper.GetTrack(0, j)
      local ok, name = reaper.GetTrackName(tr)
      if ok and name == trackname then
        local native_color = reaper.GetTrackColor(tr)
        if native_color ~= 0 then
          r, g, b = reaper.ColorFromNative(native_color)
          r, g, b = r/255, g/255, b/255
        end
        break
      end
    end
    row_rgb[row] = { r = r, g = g, b = b }
  end
  
  -- Get track colors for each row (cache for row label only)
  local row_colors = {}
  for i, row in ipairs(OVERDRIVE_ROWS) do
    local trackname = OVERDRIVE_TRACKS[i]
    row_colors[row] = {
      base = get_track_color_u32(trackname, 0.45),        -- For row label
    }
  end
  
  -- Get current edit cursor measure (for centering logic)
  local edit_cursor_t = reaper.GetCursorPosition()
  local _, edit_cursor_m_raw = reaper.TimeMap2_timeToBeats(0, edit_cursor_t)
  -- Round up if very close to next measure boundary (handles floating point imprecision)
  local edit_fractional = edit_cursor_m_raw - math.floor(edit_cursor_m_raw)
  if edit_fractional > 0.999 then
    edit_cursor_m_raw = math.ceil(edit_cursor_m_raw)
  end
  local edit_cursor_m = math.floor(edit_cursor_m_raw) + 1
  
  -- Get display cursor measure (play cursor if playing, else edit cursor)
  local play_state = reaper.GetPlayState()
  local is_playing = (play_state & 1) == 1
  local display_cursor_t = edit_cursor_t  -- Default to edit cursor
  if is_playing then
    local play_pos = reaper.GetPlayPosition()
    -- If play position is behind edit cursor but very close, use edit cursor
    -- This handles the initial playback frame where play pos may lag slightly
    if play_pos < edit_cursor_t and (edit_cursor_t - play_pos) < 0.1 then
      display_cursor_t = edit_cursor_t
    else
      display_cursor_t = play_pos
    end
  end
  local _, display_cursor_m_raw = reaper.TimeMap2_timeToBeats(0, display_cursor_t)
  -- Round up if very close to next measure boundary (handles floating point imprecision)
  local display_fractional = display_cursor_m_raw - math.floor(display_cursor_m_raw)
  if display_fractional > 0.999 then
    display_cursor_m_raw = math.ceil(display_cursor_m_raw)
  end
  local cursor_m = math.floor(display_cursor_m_raw) + 1  -- Used for highlighting
  
  -- Calculate visible columns based on actual available width
  -- Each column takes cell_w + cell_padding, plus label column, plus table borders
  local avail_w = select(1, ImGui.ImGui_GetContentRegionAvail(ctx))
  local usable_w = avail_w - label_w - cell_padding - border_padding  -- subtract label column, its padding, and table borders
  local col_total_w = cell_w + cell_padding  -- total width per measure column
  local visible_cols = math.floor(usable_w / col_total_w) - 1  -- Reserve space for Ratio column
  if visible_cols < 1 then visible_cols = 1 end
  if visible_cols > num_measures then visible_cols = num_measures end
  
  -- Scroll state for overdrive tab
  OV_SCROLL_COL = OV_SCROLL_COL or 0
  local max_scroll = math.max(0, num_measures - visible_cols)
  
  -- Only auto-center when EDIT cursor measure changes
  if edit_cursor_m >= first_m and edit_cursor_m <= last_m then
    if OV_LAST_CURSOR_M ~= edit_cursor_m then
      local cursor_col = edit_cursor_m - first_m
      local desired_scroll = cursor_col - math.floor(visible_cols / 2)
      if desired_scroll < 0 then desired_scroll = 0 end
      if desired_scroll > max_scroll then desired_scroll = max_scroll end
      OV_SCROLL_COL = desired_scroll
      OV_LAST_CURSOR_M = edit_cursor_m
    end
  end
  
  -- Handle mouse wheel scrolling
  if ImGui.ImGui_IsWindowHovered(ctx, 0) then
    local wheel = ImGui.ImGui_GetMouseWheel(ctx) or 0
    if wheel ~= 0 then
      -- Check if mouse is over minimap area (use bounds from previous frame)
      local _, mouse_y = ImGui.ImGui_GetMousePos(ctx)
      local over_minimap = mouse_y >= MINIMAP_BOUNDS.y1 and mouse_y <= MINIMAP_BOUNDS.y2
      local step_size = over_minimap and 6 or 2
      local step = (wheel > 0) and -step_size or step_size
      OV_SCROLL_COL = math.max(0, math.min(max_scroll, OV_SCROLL_COL + step))
    end
  end
  
  local start_col = OV_SCROLL_COL
  local end_col = math.min(start_col + visible_cols - 1, num_measures - 1)
  local actual_cols = end_col - start_col + 1
  
  -- Calculate exact table width needed
  local table_w = label_w + cell_padding + (actual_cols * (cell_w + cell_padding)) + 1
  
  -- Draw region color bar above the table
  draw_region_bar(ctx, first_m, start_col, end_col, cell_w, label_w, cell_padding, border_padding)
  
  -- Colors
  local col_ov_valid = ImGui.ImGui_ColorConvertDouble4ToU32(1.0, 0.9, 0.0, 1.0)  -- Opaque yellow for OV with notes
  local col_ov_empty = ImGui.ImGui_ColorConvertDouble4ToU32(0.4, 0.0, 0.0, 1.0)  -- Opaque dark red for OV without notes
  local col_cursor_header = ImGui.ImGui_ColorConvertDouble4ToU32(0.5, 0.5, 0.55, 1.0)  -- Brighter header for cursor column
  local col_header = ImGui.ImGui_ColorConvertDouble4ToU32(0.3, 0.3, 0.35, 1.0)
  local col_cursor_border = ImGui.ImGui_ColorConvertDouble4ToU32(0.65, 0.65, 0.77, 1.0)  -- Bright border for cursor column
  
  -- FILL rainbow gradient colors (green at top to red at bottom, blended for single cell)
  local col_fill = ImGui.ImGui_ColorConvertDouble4ToU32(1.0, 0.5, 0.0, 1.0)  -- Orange as blended rainbow
  
  -- Compute highlight measures for each row based on configurable distance
  -- For each row, find the measure that is N measures-with-notes forward and backward from cursor
  -- Exception: In Drum Fill Guide mode, Drums uses fixed measure offset (ignores note count)
  local highlight_measures = {}  -- highlight_measures[row] = { back = measure_num or nil, forward = measure_num or nil }
  for ri, row in ipairs(OVERDRIVE_ROWS) do
    highlight_measures[row] = { back = nil, forward = nil }
    
    -- In Drum Fill Guide mode, Drums uses fixed measure offset
    if DRUM_FILL_GUIDE_MODE and row == "Drums" then
      local back_m = cursor_m - OV_HIGHLIGHT_DISTANCE
      local fwd_m = cursor_m + OV_HIGHLIGHT_DISTANCE
      if back_m >= first_m then
        highlight_measures[row].back = back_m
      end
      if fwd_m <= last_m then
        highlight_measures[row].forward = fwd_m
      end
    else
      -- Count backward from cursor (measures with notes)
      local count_back = 0
      for m = cursor_m - 1, first_m, -1 do
        local nc = OVERDRIVE_NOTES[row] and OVERDRIVE_NOTES[row][m] or 0
        if nc > 0 then
          count_back = count_back + 1
          if count_back == OV_HIGHLIGHT_DISTANCE then
            highlight_measures[row].back = m
            break
          end
        end
      end
      
      -- Count forward from cursor (measures with notes)
      local count_fwd = 0
      for m = cursor_m + 1, last_m do
        local nc = OVERDRIVE_NOTES[row] and OVERDRIVE_NOTES[row][m] or 0
        if nc > 0 then
          count_fwd = count_fwd + 1
          if count_fwd == OV_HIGHLIGHT_DISTANCE then
            highlight_measures[row].forward = m
            break
          end
        end
      end
    end
  end
  
  -- Compute OV spans for each row from OVERDRIVE_PHRASES
  -- ov_spans[row] = { {start_col, end_col, start_pos, end_pos, has_notes}, ... }
  local ov_spans = {}
  for ri, row in ipairs(OVERDRIVE_ROWS) do
    ov_spans[row] = {}
    local phrases = OVERDRIVE_PHRASES and OVERDRIVE_PHRASES[row]
    if phrases then
      for _, phrase in ipairs(phrases) do
        -- Check if phrase overlaps visible columns
        local phrase_start_col = phrase.start_m - first_m
        local phrase_end_col = phrase.end_m - first_m
        
        if phrase_end_col >= start_col and phrase_start_col <= end_col then
          -- Clamp to visible range
          local span_start_col = math.max(phrase_start_col, start_col)
          local span_end_col = math.min(phrase_end_col, end_col)
          
          -- Calculate positions within the cells
          local span_start_pos = (phrase_start_col == span_start_col) and phrase.start_pos or 0
          local span_end_pos = (phrase_end_col == span_end_col) and phrase.end_pos or 1
          
          -- Check if any measure in the span has notes
          local span_has_notes = false
          for c = span_start_col, span_end_col do
            local measure_num = first_m + c
            if OVERDRIVE_NOTES[row] and OVERDRIVE_NOTES[row][measure_num] and OVERDRIVE_NOTES[row][measure_num] > 0 then
              span_has_notes = true
              break
            end
          end
          
          table.insert(ov_spans[row], {
            start_col = span_start_col,
            end_col = span_end_col,
            start_pos = span_start_pos,
            end_pos = span_end_pos,
            has_notes = span_has_notes
          })
        end
      end
    end
  end
  
  -- Build lookup table for which spans cover each cell
  -- ov_span_lookup[row][col] = span or nil
  local ov_span_lookup = {}
  for _, row in ipairs(OVERDRIVE_ROWS) do
    ov_span_lookup[row] = {}
    for _, span in ipairs(ov_spans[row]) do
      for c = span.start_col, span.end_col do
        ov_span_lookup[row][c] = span
      end
    end
  end
  
  -- Calculate OV scores for each instrument
  -- Score = (OV notes + unison bonus) / measures with notes
  local ov_scores = {}
  local ov_details = {}  -- Store breakdown for tooltips
  for _, row in ipairs(OVERDRIVE_ROWS) do
    local ov_notes = 0
    local unison_bonus = 0
    local measures_with_notes = 0
    for m = first_m, last_m do
      local note_count = OVERDRIVE_NOTES[row] and OVERDRIVE_NOTES[row][m] or 0
      if note_count > 0 then
        measures_with_notes = measures_with_notes + 1
        if OVERDRIVE_DATA[row] and OVERDRIVE_DATA[row][m] then
          ov_notes = ov_notes + 1
          -- Check if all instruments with notes in this measure have OV
          local all_have_ov = true
          for _, other_row in ipairs(OVERDRIVE_ROWS) do
            local other_notes = OVERDRIVE_NOTES[other_row] and OVERDRIVE_NOTES[other_row][m] or 0
            if other_notes > 0 then
              if not (OVERDRIVE_DATA[other_row] and OVERDRIVE_DATA[other_row][m]) then
                all_have_ov = false
                break
              end
            end
          end
          if all_have_ov then
            unison_bonus = unison_bonus + 1  -- Extra point when all have OV
          end
        end
      end
    end
    if measures_with_notes > 0 then
      ov_scores[row] = (ov_notes + unison_bonus) / measures_with_notes
    else
      ov_scores[row] = 0
    end
    ov_details[row] = {
      ov_notes = ov_notes,
      unison_bonus = unison_bonus,
      measures_with_notes = measures_with_notes
    }
  end
  
  -- Track cell positions for cursor column border drawing
  local cursor_col_cells = {}
  
  -- Build table with row label + measure columns
  local table_flags = ImGui.ImGui_TableFlags_Borders() +
                      ImGui.ImGui_TableFlags_SizingFixedFit()
  
  local header_y = 0  -- Will be set inside table for ratio header drawing
  
  if ImGui.ImGui_BeginTable(ctx, "overdrive_grid", actual_cols + 1, table_flags, table_w) then
    -- Setup columns
    ImGui.ImGui_TableSetupColumn(ctx, "Inst", ImGui.ImGui_TableColumnFlags_WidthFixed(), label_w)
    for c = start_col, end_col do
      local measure_num = first_m + c
      ImGui.ImGui_TableSetupColumn(ctx, tostring(measure_num), ImGui.ImGui_TableColumnFlags_WidthFixed(), cell_w)
    end
    
    -- Header row with measure numbers
    ImGui.ImGui_TableNextRow(ctx, ImGui.ImGui_TableRowFlags_Headers())
    ImGui.ImGui_TableNextColumn(ctx)
    -- Set grey background, then draw triangle matching window bg over top-left
    ImGui.ImGui_TableSetBgColor(ctx, ImGui.ImGui_TableBgTarget_CellBg(), col_header)
    local cell_x, cell_y = ImGui.ImGui_GetCursorScreenPos(ctx)
    header_y = cell_y  -- Save for ratio header drawing later
    local cell_h = row_h
    local dl = ImGui.ImGui_GetWindowDrawList(ctx)
    -- Draw triangle to cover top-left corner, oversized
    local bg_col = ImGui.ImGui_ColorConvertDouble4ToU32(0x0f/255, 0x0f/255, 0x0f/255, 1.0)
    local offset_x = 5  -- Offset left
    local offset_y = 2.5  -- Offset up
    local oversize_x = 5  -- Extra size right
    local oversize_y = -6  -- Shortened upwards (negative = less height)
    ImGui.ImGui_DrawList_AddTriangleFilled(dl,
      cell_x - offset_x, cell_y - offset_y,                          -- top-left (right angle)
      cell_x + label_w + oversize_x, cell_y - offset_y,              -- top-right
      cell_x - offset_x, cell_y + cell_h + oversize_y,               -- bottom-left
      bg_col)
    ImGui.ImGui_Text(ctx, "")
    
    -- Track header cell positions for cursor line
    local header_cell_positions = {}
    
    for c = start_col, end_col do
      ImGui.ImGui_TableNextColumn(ctx)
      local measure_num = first_m + c
      
      -- Highlight cursor column header with brighter grey
      if measure_num == cursor_m then
        ImGui.ImGui_TableSetBgColor(ctx, ImGui.ImGui_TableBgTarget_CellBg(), col_cursor_header)
        -- Track cell position for border drawing
        local cell_min_x, cell_min_y = ImGui.ImGui_GetCursorScreenPos(ctx)
        table.insert(cursor_col_cells, { x = cell_min_x, y = cell_min_y, w = cell_w, h = row_h })
      else
        ImGui.ImGui_TableSetBgColor(ctx, ImGui.ImGui_TableBgTarget_CellBg(), col_header)
      end
      
      -- Store original cursor position and screen position for cursor line
      local orig_x = ImGui.ImGui_GetCursorPosX(ctx)
      local cell_screen_x, cell_screen_y = ImGui.ImGui_GetCursorScreenPos(ctx)
      header_cell_positions[measure_num] = { x = cell_screen_x, y = cell_screen_y }
      
      -- Clickable header to jump to measure (invisible, full width)
      ImGui.ImGui_PushID(ctx, "header|" .. measure_num)
      if ImGui.ImGui_Selectable(ctx, "", false) then
        -- Jump to the start of this measure
        local _, qn_start = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
        local jump_time = reaper.TimeMap_QNToTime(qn_start)
        reaper.SetEditCurPos(jump_time, true, true)  -- Third param: move play cursor if playing
        if redirect_focus_after_click then
          reaper.defer(redirect_focus_after_click)
        end
      end
      ImGui.ImGui_PopID(ctx)
      
      -- Draw centered label on top of selectable
      ImGui.ImGui_SameLine(ctx, 0, 0)
      local label = tostring(measure_num)
      local tw = select(1, ImGui.ImGui_CalcTextSize(ctx, label))
      local pad = (cell_w - tw) / 2
      ImGui.ImGui_SetCursorPosX(ctx, orig_x + pad)
      ImGui.ImGui_Text(ctx, label)
    end
    
    -- Store cursor line info for drawing after table (to span full height)
    local cursor_line_x = nil
    local cursor_line_top_y = nil
    if cursor_m >= first_m and cursor_m <= last_m and header_cell_positions[cursor_m] then
      -- Get measure bounds
      local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, cursor_m - 1)
      local measure_start_time = reaper.TimeMap_QNToTime(qn_start)
      local measure_end_time = reaper.TimeMap_QNToTime(qn_end)
      local measure_len = measure_end_time - measure_start_time
      
      if measure_len > 0 then
        local pct_through = (display_cursor_t - measure_start_time) / measure_len
        if pct_through < 0 then pct_through = 0 end
        if pct_through > 1 then pct_through = 1 end
        
        local cell_pos = header_cell_positions[cursor_m]
        local full_cell_w = cell_w + 8  -- Include 4px padding on each side
        cursor_line_x = (cell_pos.x - 4) + (full_cell_w * pct_through)
        cursor_line_top_y = cell_pos.y - 2
      end
    end
    
    -- Track cell screen positions for OV span drawing
    local cell_positions = {}  -- cell_positions[row][col] = {x, y}
    
    -- Track cells to highlight (10 notes away)
    local highlight_cells = {}  -- { {x, y, w, h, color}, ... }
    local row_screen_positions = {}  -- Track Y position of each row for score drawing
    
    -- Data rows (Drums, Bass, Guitar, Keys)
    for ri, row in ipairs(OVERDRIVE_ROWS) do
      cell_positions[row] = {}
      ImGui.ImGui_TableNextRow(ctx)
      
      -- Row label - use track color, clickable to open MIDI editor
      ImGui.ImGui_TableNextColumn(ctx)
      ImGui.ImGui_TableSetBgColor(ctx, ImGui.ImGui_TableBgTarget_CellBg(), row_colors[row].base)
      local row_x, row_y = ImGui.ImGui_GetCursorScreenPos(ctx)
      row_screen_positions[row] = { y = row_y }
      
      -- Make row label clickable
      ImGui.ImGui_PushID(ctx, "row_label|" .. row)
      if ImGui.ImGui_Selectable(ctx, row, false) then
        local trackname = OVERDRIVE_TRACKS[ri]
        local tr = find_track_by_name(trackname)
        if tr then
          select_first_midi_item_on_track(tr)
        end
        if redirect_focus_after_click then
          reaper.defer(redirect_focus_after_click)
        end
      end
      ImGui.ImGui_PopID(ctx)
      
      -- Measure cells
      for c = start_col, end_col do
        ImGui.ImGui_TableNextColumn(ctx)
        local measure_num = first_m + c
        local has_ov = OVERDRIVE_DATA[row] and OVERDRIVE_DATA[row][measure_num]
        local note_count = OVERDRIVE_NOTES[row] and OVERDRIVE_NOTES[row][measure_num] or 0
        local has_notes = note_count > 0
        local has_fill = row == "Drums" and OVERDRIVE_FILL and OVERDRIVE_FILL["Drums"] and OVERDRIVE_FILL["Drums"][measure_num]
        
        -- Store cell position for OV span drawing
        local cell_x, cell_y = ImGui.ImGui_GetCursorScreenPos(ctx)
        cell_positions[row][c] = { x = cell_x, y = cell_y }
        
        -- Track cursor column cell positions for border drawing
        if measure_num == cursor_m then
          table.insert(cursor_col_cells, { x = cell_x, y = cell_y, w = cell_w, h = row_h })
        end
        
        -- Track highlight cells (N notes away forward/backward) - only if guide enabled
        -- In Drum Fill Guide mode, only show guide for Drums row
        local show_guide_for_row = OV_HIGHLIGHT_ENABLED and (not DRUM_FILL_GUIDE_MODE or row == "Drums")
        if show_guide_for_row then
          local hl = highlight_measures[row]
          if hl and (measure_num == hl.back or measure_num == hl.forward) then
            -- Use consistent yellow color for all tracks (same as drums guide)
            local hl_color = ImGui.ImGui_ColorConvertDouble4ToU32(1.0, 1.0, 0.0, 1.0)
            table.insert(highlight_cells, { x = cell_x, y = cell_y, w = cell_w, h = row_h, color = hl_color })
          end
        end
        
        -- Check if this cell is part of an OV span (we'll draw spans separately)
        local ov_span = ov_span_lookup[row][c]
        local is_ov_span_cell = ov_span ~= nil and not has_fill
        
        -- Calculate dynamic brightness based on note count (same for cursor and non-cursor)
        local alpha = note_count_to_alpha(note_count)
        local rgb = row_rgb[row]
        local dynamic_bg = ImGui.ImGui_ColorConvertDouble4ToU32(rgb.r, rgb.g, rgb.b, alpha)
        
        -- Background color logic:
        -- FILL = rainbow gradient (drawn separately)
        -- OV spans = drawn separately as single rectangles
        -- Other cells: use dynamic brightness based on note count
        local bg_col
        local cell_text = ""
        
        if has_fill then
          -- We'll draw gradient manually, use dynamic color
          bg_col = dynamic_bg
          cell_text = "FILL"
        elseif is_ov_span_cell then
          -- OV span cells - use transparent background, we'll draw the span rectangle later
          bg_col = nil  -- Will be drawn as span
          cell_text = "OV"
        else
          -- Use dynamic brightness based on note count
          bg_col = dynamic_bg
        end
        
        -- Draw FILL rainbow gradient if applicable
        if has_fill then
          local dl = ImGui.ImGui_GetWindowDrawList(ctx)
          local gradient_h = row_h - 6
          local num_bands = 5
          local band_h = gradient_h / num_bands
          
          -- Colors: Green, Blue, Yellow, Red, Orange (top to bottom)
          -- Use darker versions if no notes in this measure
          local brightness = has_notes and 1.0 or 0.35
          local colors = {
            ImGui.ImGui_ColorConvertDouble4ToU32(0.0, brightness, 0.0, 1.0),  -- Green
            ImGui.ImGui_ColorConvertDouble4ToU32(0.0, brightness * 0.55, brightness, 1.0),  -- Blue
            ImGui.ImGui_ColorConvertDouble4ToU32(brightness, brightness, 0.0, 1.0),  -- Yellow
            ImGui.ImGui_ColorConvertDouble4ToU32(brightness, 0.0, 0.0, 1.0),  -- Red
            ImGui.ImGui_ColorConvertDouble4ToU32(brightness, brightness * 0.55, 0.0, 1.0),  -- Orange
          }
          
          for band = 1, num_bands do
            local y1 = cell_y + (band - 1) * band_h - 1
            local y2 = cell_y + band * band_h - 0.5
            ImGui.ImGui_DrawList_AddRectFilled(dl, cell_x - 4, y1, cell_x + cell_w + 4, y2, colors[band])
          end
        elseif is_ov_span_cell then
          -- First draw the background color based on note count
          ImGui.ImGui_TableSetBgColor(ctx, ImGui.ImGui_TableBgTarget_CellBg(), dynamic_bg)
          
          -- Then draw OV span rectangle on top (only from the first cell of the span)
          if ov_span.start_col == c then
            local dl = ImGui.ImGui_GetWindowDrawList(ctx)
            local span_color = ov_span.has_notes and col_ov_valid or col_ov_empty
            local full_cell_w = cell_w + 8  -- Include 4px padding on each side
            local span_start_x = (cell_x - 4) + (ov_span.start_pos or 0) * full_cell_w
            local span_end_x = (cell_x - 4) + (ov_span.end_col - ov_span.start_col) * (cell_w + cell_padding) + (ov_span.end_pos or 1) * full_cell_w
            ImGui.ImGui_DrawList_AddRectFilled(dl, span_start_x, cell_y - 1, span_end_x, cell_y + row_h - 7, span_color)
          end
        elseif bg_col then
          ImGui.ImGui_TableSetBgColor(ctx, ImGui.ImGui_TableBgTarget_CellBg(), bg_col)
        end
        
        -- Clickable cell to toggle overdrive note (left-click) or FILL (right-click for drums)
        ImGui.ImGui_PushID(ctx, row .. "|" .. measure_num)
        
        -- Use black text for FILL or OV cells with notes (including span cells)
        -- Use grey text for OV cells without notes
        local use_black_text = (has_fill or is_ov_span_cell) and has_notes
        local use_grey_text = is_ov_span_cell and not has_notes
        if use_black_text then
          ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), ImGui.ImGui_ColorConvertDouble4ToU32(0.0, 0.0, 0.0, 1.0))
        elseif use_grey_text then
          ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), ImGui.ImGui_ColorConvertDouble4ToU32(0.5, 0.5, 0.5, 1.0))
        end
        
        -- For OV/FILL cells, use an invisible selectable then draw centered text
        local orig_x = ImGui.ImGui_GetCursorPosX(ctx)
        local cell_screen_x, cell_screen_y = ImGui.ImGui_GetCursorScreenPos(ctx)
        
        if ImGui.ImGui_Selectable(ctx, "", false) then
          -- Left-click: toggle overdrive (removes FILL if present, then toggles OV)
          local trackname = OVERDRIVE_TRACKS[ri]
          toggle_overdrive_note(trackname, measure_num)
          if redirect_focus_after_click then
            reaper.defer(redirect_focus_after_click)
          end
        end
        
        -- Draw mini note overview (5 rows showing note positions by pitch)
        if OV_SHOW_NOTES then
          local note_positions = OVERDRIVE_NOTE_POSITIONS and OVERDRIVE_NOTE_POSITIONS[row] and OVERDRIVE_NOTE_POSITIONS[row][measure_num]
          if note_positions and #note_positions > 0 then
            local dl = ImGui.ImGui_GetWindowDrawList(ctx)
            local mini_h = row_h - 6  -- Total height matching FILL gradient
            local num_bands = 5
            local band_h = mini_h / num_bands
            local mini_col = ImGui.ImGui_ColorConvertDouble4ToU32(0.0, 0.0, 0.0, 0.4)  -- Dark semi-transparent
            local full_cell_w = cell_w + 8  -- Include 4px padding on each side
            local cell_start_x = cell_screen_x - 4  -- Start from left edge of visual cell
            for _, np in ipairs(note_positions) do
              local x1 = cell_start_x + np.start * full_cell_w
              local x2 = cell_start_x + np.fin * full_cell_w
              -- Minimum width of 1 pixel
              if x2 - x1 < 1 then x2 = x1 + 1 end
              -- Calculate y position based on pitch row (mirrored: 4=top, 0=bottom)
              local band_idx = 4 - (np.row or 0)  -- Flip: pitch 100 at top, 96 at bottom
              local y1 = cell_screen_y + band_idx * band_h - 1
              local y2 = y1 + band_h - 0.5
              ImGui.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, mini_col)
            end
          end
        end
        
        -- Draw centered text on top of selectable
        if cell_text ~= "" then
          ImGui.ImGui_SameLine(ctx, 0, 0)
          local text_w = select(1, ImGui.ImGui_CalcTextSize(ctx, cell_text))
          local pad = (cell_w - text_w) / 2
          ImGui.ImGui_SetCursorPosX(ctx, orig_x + pad)
          ImGui.ImGui_Text(ctx, cell_text)
        end
        
        if use_black_text or use_grey_text then
          ImGui.ImGui_PopStyleColor(ctx)
        end
        
        -- Right-click for drums: toggle FILL
        if row == "Drums" and ImGui.ImGui_IsItemClicked(ctx, 1) then
          local trackname = OVERDRIVE_TRACKS[ri]
          toggle_fill_note(trackname, measure_num)
          if redirect_focus_after_click then
            reaper.defer(redirect_focus_after_click)
          end
        end
        
        -- Tooltip showing note count (check full visual cell area including padding)
        local mouse_x, mouse_y = ImGui.ImGui_GetMousePos(ctx)
        local cell_left = cell_screen_x - 4
        local cell_right = cell_screen_x + cell_w + 4
        local cell_top = cell_screen_y - 1
        local cell_bottom = cell_screen_y + row_h - 7
        if mouse_x >= cell_left and mouse_x <= cell_right and mouse_y >= cell_top and mouse_y <= cell_bottom then
          local note_word = note_count == 1 and "Note" or "Notes"
          ImGui.ImGui_SetTooltip(ctx, note_count .. " " .. row .. " " .. note_word)
        end
        
        ImGui.ImGui_PopID(ctx)
      end
    end
    
    ImGui.ImGui_EndTable(ctx)
    
    -- Draw bright borders around cursor column cells (use window draw list so tooltips appear on top)
    local dl = ImGui.ImGui_GetWindowDrawList(ctx)
    for _, cell in ipairs(cursor_col_cells) do
      ImGui.ImGui_DrawList_AddRect(dl, cell.x - 5, cell.y - 2, cell.x + cell.w + 5, cell.y + cell.h - 6, col_cursor_border, 0, 0, 1.0)
    end
    
    -- Draw highlight rectangles for "N notes away" cells
    for _, cell in ipairs(highlight_cells) do
      ImGui.ImGui_DrawList_AddRect(dl, cell.x - 5, cell.y - 2, cell.x + cell.w + 5, cell.y + cell.h - 6, cell.color, 0, 0, 1.0)
    end
    
    -- Draw cursor position line spanning full table height
    if cursor_line_x and cursor_line_top_y then
      -- Find the bottom of the table from last cursor column cell, or use header if no cursor cells
      local cursor_line_bottom_y = cursor_line_top_y + ImGui.ImGui_GetTextLineHeightWithSpacing(ctx) - 1
      if #cursor_col_cells > 0 then
        local last_cell = cursor_col_cells[#cursor_col_cells]
        cursor_line_bottom_y = last_cell.y + last_cell.h - 6
      end
      ImGui.ImGui_DrawList_AddLine(dl, cursor_line_x, cursor_line_top_y, cursor_line_x, cursor_line_bottom_y, COL_CURSOR_LINE, 2.0)
    end
    
    -- Cover top portion of vertical cell borders in header row with header color
    -- Build region boundary lookup and strong beat pattern
    local region_boundaries = {}  -- measures that start a new region
    local measure_regions = {}
    for c = start_col, end_col do
      local measure_num = first_m + c
      local _, qn_start = reaper.TimeMap_GetMeasureInfo(0, measure_num - 1)
      local time_start = reaper.TimeMap_QNToTime(qn_start)
      measure_regions[c] = find_region_at_time(time_start)
    end
    -- Find region boundaries (where region changes)
    local prev_region = nil
    for c = start_col, end_col do
      if measure_regions[c] ~= prev_region then
        region_boundaries[c] = true
      end
      prev_region = measure_regions[c]
    end
    
    -- Determine strong beats: region boundary or every other measure from boundary
    -- But if measure before region boundary would be strong, make it weak
    local is_strong = {}
    for c = start_col, end_col do
      if region_boundaries[c] then
        is_strong[c] = true
      else
        -- Find distance from previous region boundary
        local dist = 0
        for search_c = c - 1, start_col, -1 do
          dist = dist + 1
          if region_boundaries[search_c] then break end
        end
        -- Every other measure from boundary is strong
        is_strong[c] = (dist % 2 == 0)
      end
    end
    -- Adjust: if measure before region boundary would be strong, make it weak
    for c = start_col, end_col do
      if region_boundaries[c] and c > start_col then
        local prev_c = c - 1
        if is_strong[prev_c] then
          is_strong[prev_c] = false
        end
      end
    end
    
    for c = start_col, end_col do
      local measure_num = first_m + c
      -- Skip borders adjacent to cursor measure (left and right sides)
      local cursor_col = cursor_m - first_m
      if c == cursor_col or c == cursor_col + 1 then
        -- Don't draw rectangle for cursor measure borders
      elseif header_cell_positions[measure_num] then
        local cell_pos = header_cell_positions[measure_num]
        -- Draw a small rectangle over the vertical border (left edge of cell)
        local border_x = cell_pos.x - 5  -- Left edge where border is drawn
        -- Strong beat = taller (header_y + 11), weak beat = shorter (header_y + 15)
        local bottom_y = is_strong[c] and (header_y + 11) or (header_y + 15)
        ImGui.ImGui_DrawList_AddRectFilled(dl, border_x, header_y - 1, border_x + 1, bottom_y, col_header)
      end
    end
    
    -- Draw OV scores to the right of the table with "Ratio" header
    local score_x = table_w + 34  -- Right of the table with some padding
    -- Draw "Ratio" header
    ImGui.ImGui_DrawList_AddText(dl, score_x - 2, header_y, 
      ImGui.ImGui_ColorConvertDouble4ToU32(1.0, 1.0, 1.0, 0.6),
      "Ratio")
    -- Get mouse position for hover detection
    local mouse_x, mouse_y = ImGui.ImGui_GetMousePos(ctx)
    for _, row in ipairs(OVERDRIVE_ROWS) do
      if row_screen_positions[row] then
        local score_text = string.format("%.2f", ov_scores[row] or 0)
        local text_w, text_h = ImGui.ImGui_CalcTextSize(ctx, score_text)
        local text_y = row_screen_positions[row].y
        ImGui.ImGui_DrawList_AddText(dl, score_x, text_y, 
          ImGui.ImGui_ColorConvertDouble4ToU32(1.0, 1.0, 1.0, 0.8),
          score_text)
        -- Check if mouse is hovering over this score
        if mouse_x >= score_x and mouse_x <= score_x + text_w and
           mouse_y >= text_y and mouse_y <= text_y + text_h then
          local details = ov_details[row]
          if details then
            ImGui.ImGui_SetTooltip(ctx, string.format(
              "%s OV Ratio\nOV notes: %d\nUnison bonus: %d\nMeasures with notes: %d",
              row, details.ov_notes, details.unison_bonus, details.measures_with_notes))
          end
        end
      end
    end
  end
  
  
  -- Draw region color bar below the table (duplicate of top bar)
  draw_region_bar(ctx, first_m, start_col, end_col, cell_w, label_w, cell_padding, border_padding)
  
  -- Calculate drum fill ratio: measures with fills / measures with drum notes
  local drum_fill_ratio = 0
  local drums_measures_with_notes = 0
  local drums_measures_with_fills = 0
  for m = first_m, last_m do
    local note_count = OVERDRIVE_NOTES["Drums"] and OVERDRIVE_NOTES["Drums"][m] or 0
    if note_count > 0 then
      drums_measures_with_notes = drums_measures_with_notes + 1
      if OVERDRIVE_FILL["Drums"] and OVERDRIVE_FILL["Drums"][m] then
        drums_measures_with_fills = drums_measures_with_fills + 1
      end
    end
  end
  if drums_measures_with_notes > 0 then
    drum_fill_ratio = drums_measures_with_fills / drums_measures_with_notes
  end
  
  -- Info row in a borderless table for alignment (6 columns: Regions | OV Guide label | measures | buttons | Drum Fill Guide toggle | Drum Fill Ratio)
  local table_flags = ImGui.ImGui_TableFlags_None()
  -- Calculate fixed widths for the label columns to prevent layout shift
  local ov_label_w = ImGui.ImGui_CalcTextSize(ctx, "OV Placement Guide Width:") + 8
  local dfg_label_w = ImGui.ImGui_CalcTextSize(ctx, "Drum Fill Guide Width:") + 8
  local max_label_w = math.max(ov_label_w, dfg_label_w)
  local toggle_btn_w = ImGui.ImGui_CalcTextSize(ctx, "OV Placement Guide") + 30  -- button + padding + spacing
  if ImGui.ImGui_BeginTable(ctx, "info_row", 6, table_flags) then
    ImGui.ImGui_TableSetupColumn(ctx, "##left", ImGui.ImGui_TableColumnFlags_WidthStretch())
    ImGui.ImGui_TableSetupColumn(ctx, "##guide_label", ImGui.ImGui_TableColumnFlags_WidthFixed(), max_label_w)
    ImGui.ImGui_TableSetupColumn(ctx, "##measures", ImGui.ImGui_TableColumnFlags_WidthFixed(), 75)
    ImGui.ImGui_TableSetupColumn(ctx, "##buttons", ImGui.ImGui_TableColumnFlags_WidthFixed())
    ImGui.ImGui_TableSetupColumn(ctx, "##drum_fill_toggle", ImGui.ImGui_TableColumnFlags_WidthFixed(), toggle_btn_w)
    ImGui.ImGui_TableSetupColumn(ctx, "##right", ImGui.ImGui_TableColumnFlags_WidthStretch())
    ImGui.ImGui_TableNextRow(ctx)
    
    -- Left column: Regions info
    ImGui.ImGui_TableNextColumn(ctx)
    -- Find which regions are visible in the current view
    local first_visible_time = reaper.TimeMap_QNToTime(select(2, reaper.TimeMap_GetMeasureInfo(0, first_m + start_col - 1)))
    local last_visible_time = reaper.TimeMap_QNToTime(select(3, reaper.TimeMap_GetMeasureInfo(0, first_m + end_col - 1)))
    local first_visible_region, last_visible_region = nil, nil
    for i, reg in ipairs(REGIONS) do
      -- Check if region overlaps with visible range
      if reg.r_end > first_visible_time and reg.pos < last_visible_time then
        if not first_visible_region then first_visible_region = i end
        last_visible_region = i
      end
    end
    local total_regions = #REGIONS
    if first_visible_region and last_visible_region then
      ImGui.ImGui_Text(ctx, string.format("Regions %d-%d of %d", 
        first_visible_region, last_visible_region, total_regions))
    else
      ImGui.ImGui_Text(ctx, string.format("Regions - of %d", total_regions))
    end
    
    -- Second column: OV Placement Guide Width / Drum Fill Guide Width label (clickable, right-aligned)
    ImGui.ImGui_TableNextColumn(ctx)
    local pushed_grey = not OV_HIGHLIGHT_ENABLED
    if pushed_grey then
      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), ImGui.ImGui_ColorConvertDouble4ToU32(0.5, 0.5, 0.5, 1.0))
    end
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_HeaderHovered(), 0x00000000)
    local guide_label = DRUM_FILL_GUIDE_MODE and "Drum Fill Guide Width:" or "OV Placement Guide Width:"
    local label_w_size = ImGui.ImGui_CalcTextSize(ctx, guide_label)
    -- Right-align within the fixed-width column
    local col_avail_w = ImGui.ImGui_GetContentRegionAvail(ctx)
    ImGui.ImGui_SetCursorPosX(ctx, ImGui.ImGui_GetCursorPosX(ctx) + col_avail_w - label_w_size - 4)
    if ImGui.ImGui_Selectable(ctx, guide_label, false, ImGui.ImGui_SelectableFlags_None(), label_w_size + 4, 0) then
      OV_HIGHLIGHT_ENABLED = not OV_HIGHLIGHT_ENABLED
    end
    ImGui.ImGui_PopStyleColor(ctx)  -- Pop HeaderHovered
    if ImGui.ImGui_IsItemHovered(ctx) then
      if OV_HIGHLIGHT_ENABLED then
        ImGui.ImGui_SetTooltip(ctx, "Turn off guide")
      else
        ImGui.ImGui_SetTooltip(ctx, "Turn on guide")
      end
    end
    if pushed_grey then
      ImGui.ImGui_PopStyleColor(ctx)
    end
    
    -- Third column: X measures (fixed width, clickable, right-aligned)
    ImGui.ImGui_TableNextColumn(ctx)
    local pushed_grey_measures = not OV_HIGHLIGHT_ENABLED
    if pushed_grey_measures then
      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), ImGui.ImGui_ColorConvertDouble4ToU32(0.5, 0.5, 0.5, 1.0))
    end
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_HeaderHovered(), 0x00000000)
    local measures_text = tostring(OV_HIGHLIGHT_DISTANCE) .. " measures"
    local measures_w = ImGui.ImGui_CalcTextSize(ctx, measures_text)
    local col_w = 75
    ImGui.ImGui_SetCursorPosX(ctx, ImGui.ImGui_GetCursorPosX(ctx) + col_w - measures_w - 4)
    if ImGui.ImGui_Selectable(ctx, measures_text, false, ImGui.ImGui_SelectableFlags_None(), measures_w + 4, 0) then
      OV_HIGHLIGHT_ENABLED = not OV_HIGHLIGHT_ENABLED
    end
    ImGui.ImGui_PopStyleColor(ctx)  -- Pop HeaderHovered
    if ImGui.ImGui_IsItemHovered(ctx) then
      if OV_HIGHLIGHT_ENABLED then
        ImGui.ImGui_SetTooltip(ctx, "Turn off guide")
      else
        ImGui.ImGui_SetTooltip(ctx, "Turn on guide")
      end
    end
    if pushed_grey_measures then
      ImGui.ImGui_PopStyleColor(ctx)
    end
    
    -- Fourth column: Arrow buttons
    ImGui.ImGui_TableNextColumn(ctx)
    local left_arrow_w = ImGui.ImGui_CalcTextSize(ctx, "◀")
    local right_arrow_w = ImGui.ImGui_CalcTextSize(ctx, "▶")
    local max_arrow_w = math.max(left_arrow_w, right_arrow_w)
    local btn_w = max_arrow_w + 8  -- Add padding
    ImGui.ImGui_PushStyleVar(ctx, ImGui.ImGui_StyleVar_FramePadding(), 1, 0)
    if ImGui.ImGui_Button(ctx, "◀##ov_dist_dec", btn_w, 18) then
      OV_HIGHLIGHT_DISTANCE = math.max(1, OV_HIGHLIGHT_DISTANCE - 1)
    end
    ImGui.ImGui_SameLine(ctx)
    if ImGui.ImGui_Button(ctx, "▶##ov_dist_inc", btn_w, 18) then
      OV_HIGHLIGHT_DISTANCE = math.max(1, OV_HIGHLIGHT_DISTANCE + 1)
    end
    ImGui.ImGui_PopStyleVar(ctx)
    
    -- Fifth column: Guide mode toggle button (fixed width)
    ImGui.ImGui_TableNextColumn(ctx)
    ImGui.ImGui_Dummy(ctx, 12, 0)  -- Add spacing before button
    ImGui.ImGui_SameLine(ctx)
    local dfg_pushed = DRUM_FILL_GUIDE_MODE
    if dfg_pushed then
      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Button(), ImGui.ImGui_ColorConvertDouble4ToU32(0.3, 0.5, 0.8, 1.0))
    end
    ImGui.ImGui_PushStyleVar(ctx, ImGui.ImGui_StyleVar_FramePadding(), 4, 0)
    -- Use fixed width button so layout doesn't shift when label changes
    local guide_btn_label = DRUM_FILL_GUIDE_MODE and "OV Placement Guide" or "Drum Fill Guide"
    local fixed_btn_w = ImGui.ImGui_CalcTextSize(ctx, "OV Placement Guide") + 10  -- Use longer label for width
    if ImGui.ImGui_Button(ctx, guide_btn_label, fixed_btn_w, 18) then
      DRUM_FILL_GUIDE_MODE = not DRUM_FILL_GUIDE_MODE
      if DRUM_FILL_GUIDE_MODE then
        -- Switching to Drum Fill Guide mode: save OV distance, load Drum Fill distance
        SAVED_OV_HIGHLIGHT_DISTANCE = OV_HIGHLIGHT_DISTANCE
        OV_HIGHLIGHT_DISTANCE = DRUM_FILL_GUIDE_WIDTH
      else
        -- Switching back to OV mode: save Drum Fill distance, restore OV distance
        DRUM_FILL_GUIDE_WIDTH = OV_HIGHLIGHT_DISTANCE
        OV_HIGHLIGHT_DISTANCE = SAVED_OV_HIGHLIGHT_DISTANCE
      end
    end
    ImGui.ImGui_PopStyleVar(ctx)
    if dfg_pushed then
      ImGui.ImGui_PopStyleColor(ctx)
    end
    
    -- Sixth column: Drum Fill Ratio (right-aligned with padding)
    ImGui.ImGui_TableNextColumn(ctx)
    local right_padding = 9
    local fill_text = string.format("Drum Fill Ratio:       %.2f", drum_fill_ratio)
    local fill_text_w = ImGui.ImGui_CalcTextSize(ctx, fill_text)
    local avail_w = ImGui.ImGui_GetContentRegionAvail(ctx)
    ImGui.ImGui_SetCursorPosX(ctx, ImGui.ImGui_GetCursorPosX(ctx) + avail_w - fill_text_w - right_padding)
    ImGui.ImGui_Text(ctx, fill_text)
    if ImGui.ImGui_IsItemHovered(ctx) then
      ImGui.ImGui_SetTooltip(ctx, string.format(
        "Drum Fill Ratio\nMeasures with fills: %d\nMeasures with notes: %d",
        drums_measures_with_fills, drums_measures_with_notes))
    end
    
    ImGui.ImGui_EndTable(ctx)
  end
  
  -- Mini-map: 4x4 pixel squares for each measure, one row per instrument
  local sq_size = 4
  local sq_gap = 1
  local total_measures = last_m - first_m + 1
  local minimap_w = total_measures * (sq_size + sq_gap) - sq_gap
  local minimap_h = 4 * (sq_size + sq_gap) - sq_gap  -- 4 rows
  local region_bar_h = 3  -- Height of region color bars
  local view_line_h = 3  -- Height reserved for view indicator lines (top and bottom)
  local total_h = view_line_h + region_bar_h + 1 + minimap_h + 1 + region_bar_h + view_line_h
  
  -- Calculate available width and determine if scrolling is needed FIRST
  local content_w = ImGui.ImGui_GetContentRegionAvail(ctx)
  local minimap_padding = 31
  local max_minimap_w = content_w - minimap_padding * 2
  local needs_scroll = minimap_w > max_minimap_w
  
  -- Calculate flexible spacing to split equally above and below minimap
  -- Account for item spacing between elements (approx 4px per item)
  local avail_h = select(2, ImGui.ImGui_GetContentRegionAvail(ctx))
  local item_spacing = ImGui.ImGui_GetStyleVar(ctx, ImGui.ImGui_StyleVar_ItemSpacing())
  local extra_margin = item_spacing * 2 + 4  -- Extra buffer for spacing between top dummy, minimap, bottom dummy
  local max_spacing = 16  -- Maximum spacing per side
  local total_spacing = avail_h - total_h - extra_margin
  local spacing_h = 0
  if total_spacing > 0 then
    spacing_h = math.min(total_spacing / 2, max_spacing)
  end
  
  -- Add top spacing
  if spacing_h > 0 then
    ImGui.ImGui_Dummy(ctx, 0, spacing_h)
  end
  
  -- Calculate scroll offset to center the visible region
  local scroll_offset = 0
  local sq_total_w = sq_size + sq_gap
  local display_w = max_minimap_w
  
  if needs_scroll then
    -- Calculate how many complete measures fit in the display area
    local visible_measure_count = math.floor(max_minimap_w / sq_total_w)
    display_w = visible_measure_count * sq_total_w - sq_gap  -- Actual width showing complete measures
    
    -- Calculate the center of the visible table view in minimap coordinates
    local view_center_col = start_col + (end_col - start_col) / 2
    local view_center_x = view_center_col * sq_total_w
    -- Calculate desired scroll to center this position
    scroll_offset = view_center_x - display_w / 2
    -- Snap to measure boundary
    scroll_offset = math.floor(scroll_offset / sq_total_w) * sq_total_w
    -- Clamp scroll offset to valid range
    if scroll_offset < 0 then scroll_offset = 0 end
    local max_scroll = minimap_w - display_w
    if scroll_offset > max_scroll then scroll_offset = max_scroll end
  end
  
  -- Add left padding (same as right padding)
  ImGui.ImGui_SetCursorPosX(ctx, ImGui.ImGui_GetCursorPosX(ctx) + minimap_padding)
  
  -- Center the minimap horizontally when not scrolling
  if not needs_scroll then
    local extra_space = content_w - minimap_w - minimap_padding * 2
    ImGui.ImGui_SetCursorPosX(ctx, ImGui.ImGui_GetCursorPosX(ctx) + extra_space / 2)
  end
  
  -- Save cursor position for invisible button overlay (after padding/centering adjustments)
  local minimap_start_x = ImGui.ImGui_GetCursorPosX(ctx)
  local minimap_start_y = ImGui.ImGui_GetCursorPosY(ctx)
  
  -- Begin clipped child region if scrolling needed (no scrollbar, we handle offset ourselves)
  if needs_scroll then
    local window_flags = ImGui.ImGui_WindowFlags_NoScrollbar() | ImGui.ImGui_WindowFlags_NoScrollWithMouse() | ImGui.ImGui_WindowFlags_NoInputs()
    local child_flags = ImGui.ImGui_ChildFlags_None()
    ImGui.ImGui_BeginChild(ctx, "##minimap_scroll", display_w, total_h, child_flags, window_flags)
  end
  
  -- Colors
  local grey_col = ImGui.ImGui_ColorConvertDouble4ToU32(0.26, 0.26, 0.26, 1.0)  -- Header grey (has notes, no OV)
  local dark_grey_col = ImGui.ImGui_ColorConvertDouble4ToU32(0.15, 0.15, 0.15, 1.0)  -- Darker grey (no notes)
  local yellow_col = ImGui.ImGui_ColorConvertDouble4ToU32(1.0, 0.9, 0.0, 1.0)  -- Overdrive yellow
  local blue_col = ImGui.ImGui_ColorConvertDouble4ToU32(0.2, 0.4, 1.0, 1.0)  -- Drum fill blue
  local red_col = ImGui.ImGui_ColorConvertDouble4ToU32(0.8, 0.2, 0.2, 1.0)  -- Invalid OV red
  
  local base_x, base_y = ImGui.ImGui_GetCursorScreenPos(ctx)
  -- Apply scroll offset to base_x
  base_x = base_x - scroll_offset
  local dl = ImGui.ImGui_GetWindowDrawList(ctx)
  
  -- Build region info for each measure in minimap
  local minimap_measure_regions = {}
  for m = first_m, last_m do
    local _, qn_start = reaper.TimeMap_GetMeasureInfo(0, m - 1)
    local time_start = reaper.TimeMap_QNToTime(qn_start)
    minimap_measure_regions[m] = find_region_at_time(time_start)
  end
  
  -- Draw top region bar
  local sq_total_w = sq_size + sq_gap
  local segment_start_m = first_m
  local current_region = minimap_measure_regions[first_m]
  -- Offset base_y to make room for top view line
  local top_line_y = base_y
  local top_bar_y = base_y + 3
  
  -- Draw grey line above top region bar showing visible table range
  local view_line_col = ImGui.ImGui_ColorConvertDouble4ToU32(0.5, 0.5, 0.5, 1.0)
  local view_start_m = first_m + start_col
  local view_end_m = first_m + end_col
  local view_x1 = base_x + start_col * sq_total_w - 1
  local view_x2 = base_x + (end_col + 1) * sq_total_w - sq_gap
  ImGui.ImGui_DrawList_AddLine(dl, view_x1 + 1, top_line_y, view_x2 - 1, top_line_y, view_line_col, 1.0)
  -- Add 2px dots below the top line at each edge (extending upward away from center)
  ImGui.ImGui_DrawList_AddRectFilled(dl, view_x1 + 1, top_line_y + 1, view_x1 + 2, top_line_y + 3, view_line_col)
  ImGui.ImGui_DrawList_AddRectFilled(dl, view_x2 - 1, top_line_y + 1, view_x2, top_line_y + 3, view_line_col)
  
  for m = first_m, last_m + 1 do
    local this_region = minimap_measure_regions[m]
    if this_region ~= current_region or m > last_m then
      if current_region then
        local seg_x1 = base_x + (segment_start_m - first_m) * sq_total_w
        local seg_x2 = base_x + (m - first_m) * sq_total_w - sq_gap
        local col = get_region_color_u32(current_region, 1.0)
        ImGui.ImGui_DrawList_AddRectFilled(dl, seg_x1, top_bar_y, seg_x2, top_bar_y + region_bar_h, col)
      end
      segment_start_m = m
      current_region = this_region
    end
  end
  
  -- Offset for the instrument squares (after top line and top region bar)
  local squares_y = top_bar_y + region_bar_h + 1
  
  -- Pre-calculate which measures have ALL instruments WITH NOTES having overdrive
  local all_ov_measures = {}
  for m = first_m, last_m do
    local all_with_notes_have_ov = true
    local any_has_notes = false
    for _, check_row in ipairs(OVERDRIVE_ROWS) do
      local note_count = OVERDRIVE_NOTES[check_row] and OVERDRIVE_NOTES[check_row][m] or 0
      if note_count > 0 then
        any_has_notes = true
        if not (OVERDRIVE_DATA[check_row] and OVERDRIVE_DATA[check_row][m]) then
          all_with_notes_have_ov = false
          break
        end
      end
    end
    -- Only mark as "all OV" if there are notes and all instruments with notes have OV
    all_ov_measures[m] = any_has_notes and all_with_notes_have_ov
  end
  
  local orange_col = ImGui.ImGui_ColorConvertDouble4ToU32(1.0, 0.5, 0.0, 1.0)  -- Orange for all OV
  local sq_total_w = sq_size + sq_gap
  
  -- First pass: Draw all base colors and fills
  for row_idx, row in ipairs(OVERDRIVE_ROWS) do
    local y = squares_y + (row_idx - 1) * sq_total_w
    for m = first_m, last_m do
      local col_idx = m - first_m
      local x = base_x + col_idx * sq_total_w
      
      local note_count = OVERDRIVE_NOTES[row] and OVERDRIVE_NOTES[row][m] or 0
      local has_notes = note_count > 0
      
      -- Draw base color (grey for notes, dark grey for no notes)
      local base_color = has_notes and grey_col or dark_grey_col
      ImGui.ImGui_DrawList_AddRectFilled(dl, x, y, x + sq_size, y + sq_size, base_color)
      
      -- Check for drum fill (only for drums row) - draw as full square overlay
      if row == "Drums" and OVERDRIVE_FILL["Drums"] and OVERDRIVE_FILL["Drums"][m] then
        ImGui.ImGui_DrawList_AddRectFilled(dl, x, y, x + sq_size, y + sq_size, blue_col)
      end
    end
  end
  
  -- Second pass: Draw OV phrases as continuous rectangles spanning measures
  for row_idx, row in ipairs(OVERDRIVE_ROWS) do
    local y = squares_y + (row_idx - 1) * sq_total_w
    local phrases = OVERDRIVE_PHRASES and OVERDRIVE_PHRASES[row]
    if phrases then
      for _, phrase in ipairs(phrases) do
        -- Check if phrase overlaps visible range
        if phrase.end_m >= first_m and phrase.start_m <= last_m then
          -- Calculate x positions for the phrase
          local start_col = phrase.start_m - first_m
          local end_col = phrase.end_m - first_m
          local x1 = base_x + start_col * sq_total_w + phrase.start_pos * sq_size
          local x2 = base_x + end_col * sq_total_w + phrase.end_pos * sq_size
          -- Ensure minimum width of 1 pixel
          if x2 - x1 < 1 then x2 = x1 + 1 end
          
          -- Determine color based on whether phrase covers measures with notes
          -- Check if any measure in the phrase has notes and if all have OV
          local has_notes_in_phrase = false
          local all_ov_in_phrase = true
          for m = phrase.start_m, phrase.end_m do
            if m >= first_m and m <= last_m then
              local nc = OVERDRIVE_NOTES[row] and OVERDRIVE_NOTES[row][m] or 0
              if nc > 0 then
                has_notes_in_phrase = true
                if not all_ov_measures[m] then
                  all_ov_in_phrase = false
                end
              end
            end
          end
          
          local ov_color
          if not has_notes_in_phrase then
            ov_color = red_col
          elseif all_ov_in_phrase then
            ov_color = orange_col
          else
            ov_color = yellow_col
          end
          
          ImGui.ImGui_DrawList_AddRectFilled(dl, x1, y, x2, y + sq_size, ov_color)
        end
      end
    end
  end
  
  -- Draw cursor measure highlight rectangle around the 4 dots
  if cursor_m >= first_m and cursor_m <= last_m then
    local cursor_col_idx = cursor_m - first_m
    local cursor_x = base_x + cursor_col_idx * sq_total_w
    local cursor_top_y = squares_y
    local cursor_bottom_y = squares_y + minimap_h
    -- Use same color as table cursor border
    local minimap_cursor_col = ImGui.ImGui_ColorConvertDouble4ToU32(0.65, 0.65, 0.77, 1.0)
    ImGui.ImGui_DrawList_AddRect(dl, cursor_x - 1, cursor_top_y - 1, cursor_x + sq_size + 1, cursor_bottom_y + 1, minimap_cursor_col, 0, 0, 1.0)
    
    -- Draw horizontal lines between instrument rows within cursor column
    for row_idx = 1, 3 do  -- 3 lines between 4 rows
      local line_y = squares_y + row_idx * (sq_size + sq_gap) - 1
      ImGui.ImGui_DrawList_AddLine(dl, cursor_x - 1, line_y, cursor_x + sq_size, line_y, minimap_cursor_col, 1.0)
    end
  end
  
  -- Draw bottom region bar
  local bottom_bar_y = squares_y + minimap_h + 1
  segment_start_m = first_m
  current_region = minimap_measure_regions[first_m]
  
  for m = first_m, last_m + 1 do
    local this_region = minimap_measure_regions[m]
    if this_region ~= current_region or m > last_m then
      if current_region then
        local seg_x1 = base_x + (segment_start_m - first_m) * sq_total_w
        local seg_x2 = base_x + (m - first_m) * sq_total_w - sq_gap
        local col = get_region_color_u32(current_region, 1.0)
        ImGui.ImGui_DrawList_AddRectFilled(dl, seg_x1, bottom_bar_y, seg_x2, bottom_bar_y + region_bar_h, col)
      end
      segment_start_m = m
      current_region = this_region
    end
  end
  
  -- Draw grey line below bottom region bar showing visible table range
  local bottom_line_y = bottom_bar_y + region_bar_h + 2
  ImGui.ImGui_DrawList_AddLine(dl, view_x1 + 1, bottom_line_y, view_x2 - 1, bottom_line_y, view_line_col, 1.0)
  -- Add 2px dots above the bottom line at each edge (extending downward away from center)
  ImGui.ImGui_DrawList_AddRectFilled(dl, view_x1 + 1, bottom_line_y - 2, view_x1 + 2, bottom_line_y, view_line_col)
  ImGui.ImGui_DrawList_AddRectFilled(dl, view_x2 - 1, bottom_line_y - 2, view_x2, bottom_line_y, view_line_col)
  
  -- Store minimap bounds for scroll speed detection (used next frame)
  MINIMAP_BOUNDS.y1 = top_line_y
  MINIMAP_BOUNDS.y2 = bottom_line_y
  
  -- End child region if we used scrolling (before invisible button so it can receive clicks)
  if needs_scroll then
    ImGui.ImGui_EndChild(ctx)
  end
  
  -- Create invisible button to capture clicks on the minimap
  -- Restore cursor to minimap start position
  ImGui.ImGui_SetCursorPos(ctx, minimap_start_x, minimap_start_y)
  local button_w = needs_scroll and display_w or minimap_w
  local button_screen_x, button_screen_y = ImGui.ImGui_GetCursorScreenPos(ctx)
  if ImGui.ImGui_InvisibleButton(ctx, "##minimap_click", button_w, total_h) then
    -- Calculate which measure was clicked
    local mouse_x, mouse_y = ImGui.ImGui_GetMousePos(ctx)
    -- Calculate relative position within button, then add scroll offset
    local rel_x = mouse_x - button_screen_x + scroll_offset
    local sq_w = sq_size + sq_gap
    local clicked_col = math.floor(rel_x / sq_w)
    local clicked_measure = first_m + clicked_col
    
    -- Clamp to valid range
    if clicked_measure >= first_m and clicked_measure <= last_m then
      -- Jump to the start of this measure
      local _, qn_start = reaper.TimeMap_GetMeasureInfo(0, clicked_measure - 1)
      local jump_time = reaper.TimeMap_QNToTime(qn_start)
      reaper.SetEditCurPos(jump_time, true, true)
      if redirect_focus_after_click then
        reaper.defer(redirect_focus_after_click)
      end
    end
  end
  
  -- Add bottom spacing (same as top)
  if spacing_h > 0 then
    ImGui.ImGui_Dummy(ctx, 0, spacing_h)
  end
end

-- Helper to draw preview line for jump destination
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