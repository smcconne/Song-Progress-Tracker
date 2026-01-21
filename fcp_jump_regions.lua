-- @description Jumps the edit cursor the difference in measures between regions
-- @version 1.4.5
-- @author FinestCardboardPearls

-- Module table for integration with progress tracker
local JumpRegions = {}

local proj = 0
local ME_GO_TO_EDIT_CURSOR = 40151
local EXT_SECTION = "REGIONS_JUMP_UI"
local EXT_KEY_JUMP = "JUMP_NOW"
local EXT_SECTION_PT = "RBN_JUMP"
local EXT_KEY_PT_REGION_ID = "TARGET_REGION_ID"

-- Module state
local ctx = nil
local is_running = false

-- ImGui: enum + color helper
local TGT_CELL = (reaper.ImGui_TableBgTarget_CellBg and reaper.ImGui_TableBgTarget_CellBg()) or 3
local function color_to_u32(native_color, a)
  if not native_color or native_color == 0 then
    native_color = reaper.GetThemeColor("col_region", 0) or 0
  end
  if (native_color & 0x1000000) ~= 0 then native_color = native_color & 0xFFFFFF end
  local r,g,b = reaper.ColorFromNative(native_color)
  return reaper.ImGui_ColorConvertDouble4ToU32((r or 0)/255, (g or 0)/255, (b or 0)/255, a or 1)
end

-- Regions
local function scan_regions()
  local regs = {}
  local _, n_mark, n_rgn = reaper.CountProjectMarkers(0)
  local total = (n_mark or 0) + (n_rgn or 0)
  for i = 0, total-1 do
    local ok, isrgn, pos, r_end, name, id, color = reaper.EnumProjectMarkers3(0, i)
    if ok and isrgn then
      regs[#regs+1] = { label=(name and name~="") and name or ("Region "..tostring(id)), id=id or -1, pos=pos or 0, rgnend=r_end or pos or 0, color=color or 0 }
    end
  end
  table.sort(regs, function(a,b) return a.pos < b.pos end)
  return regs
end

local function current_region_info()
  local play_state = reaper.GetPlayState()
  local pos = ((play_state & 1) == 1) and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  local _, idx = reaper.GetLastMarkerAndCurRegion(proj, pos)
  if idx and idx >= 0 then
    local ok, isrgn, rstart, _, name, id = reaper.EnumProjectMarkers2(proj, idx)
    if ok ~= 0 and isrgn then
      return ((name and name~="") and name or (""..(id or 0))), rstart, id
    end
  end
  return "undefined", nil, nil
end

local function find_index_by_region_id(id, regs)
  if not id then return nil end
  for i,r in ipairs(regs) do if r.id==id then return i end end
  return nil
end

local function region_info_at_time(t)
  local _, idx = reaper.GetLastMarkerAndCurRegion(proj, t)
  if idx and idx >= 0 and reaper.EnumProjectMarkers3 then
    local ok, isrgn, pos, r_end, name, id, color = reaper.EnumProjectMarkers3(proj, idx)
    if ok and isrgn then
      return { label=(name and name~="") and name or ("Region "..tostring(id or 0)), id=id or -1, pos=pos or 0, rgnend=r_end or pos or 0, color=color or 0 }
    end
  end
  return nil
end

-- Measure helpers
local function measure_index_at_time(t) local _,m=reaper.TimeMap2_timeToBeats(proj,t) return math.floor(m or 0) end
local function measure_qn_bounds(i) local _,s,e=reaper.TimeMap_GetMeasureInfo(proj,i) return s or 0,e or 0 end
local function frac_in_measure_at_time(t) local qn=reaper.TimeMap_timeToQN(t) or 0 local m=measure_index_at_time(t) local s,e=measure_qn_bounds(m) local L=e-s if L<=0 then return 0.0,m end return (qn-s)/L,m end
local function time_at_measure_with_frac(i,f) local s,e=measure_qn_bounds(i) local L=e-s if L<=0 then return reaper.TimeMap_QNToTime(s) end local qt=s+(math.max(0,math.min(1,f))*L) return reaper.TimeMap_QNToTime(qt) end
local function jump_time_by_measures(t,off) local frac,m=frac_in_measure_at_time(t) return time_at_measure_with_frac(m+(off or 0),frac) end

-- View helper
local function preserve_view_relative_to_edit_cursor(pre_t, post_t)
  local st, et = reaper.GetSet_ArrangeView2(proj, false, 0, 0)
  if not (st and et) then return end
  local ns = post_t - (pre_t - st)
  local ne = post_t + (et - pre_t)
  if ns < 0 then local sh=-ns ns=0 ne=ne+sh end
  reaper.GetSet_ArrangeView2(proj, true, 0, 0, ns, ne)
end

-- Focus handoff
local was_focused, pending_focus_redirect = false, false
local function redirect_focus()
  if reaper.MIDIEditor_GetActive() and reaper.SN_FocusMIDIEditor then reaper.SN_FocusMIDIEditor() else reaper.SetCursorContext(0, nil) end
end
local function any_mouse_down(ctx)
  if reaper.ImGui_IsAnyMouseDown then return reaper.ImGui_IsAnyMouseDown(ctx) end
  return reaper.ImGui_IsMouseDown(ctx,0) or reaper.ImGui_IsMouseDown(ctx,1) or reaper.ImGui_IsMouseDown(ctx,2)
end

-- State
local REGIONS          = {}
local last_proj_change = 0
local MEAS_OFFSET      = 0
local MEAS_OFFSET_STR  = "0"
local me_recenter_target_time, me_recenter_frames = nil, 0
local WIN_FLAGS = nil

local function ui_loop()
  if not is_running or not ctx then return end
  
  local cur_change = reaper.GetProjectStateChangeCount(0)
  if cur_change ~= last_proj_change then last_proj_change = cur_change; REGIONS = scan_regions() end

  reaper.ImGui_SetNextWindowSize(ctx, 420, 200, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 9, 9)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),   9, 9)

  local visible, open = reaper.ImGui_Begin(ctx, "Jump Regions", true, WIN_FLAGS)
  if visible then
    -- deferred MIDI recenter
    if me_recenter_frames > 0 then
      me_recenter_frames = me_recenter_frames - 1
      if me_recenter_frames == 0 and me_recenter_target_time then
        reaper.SetEditCurPos(me_recenter_target_time, false, false)
        local me = reaper.MIDIEditor_GetActive()
        if me and ME_GO_TO_EDIT_CURSOR > 0 then reaper.MIDIEditor_OnCommand(me, ME_GO_TO_EDIT_CURSOR) end
        me_recenter_target_time = nil
      end
    end

    -- current / target
    local play_state = reaper.GetPlayState()
    local t_now = ((play_state & 1) == 1) and reaper.GetPlayPosition() or reaper.GetCursorPosition()
    local cur_rg = region_info_at_time(t_now)

    local t_edit_now = reaper.GetCursorPosition()
    local t_target   = jump_time_by_measures(t_edit_now, MEAS_OFFSET)
    local tgt_rg     = region_info_at_time(t_target)

    local cur_name = cur_rg and cur_rg.label or "undefined"
    local tgt_name = tgt_rg and tgt_rg.label or "undefined"
    local cur_colU32 = cur_rg and color_to_u32(cur_rg.color, 0.65) or nil
    local tgt_colU32 = tgt_rg and color_to_u32(tgt_rg.color, 0.65) or nil

    if reaper.ImGui_BeginTable(ctx, "rgntable", 2, reaper.ImGui_TableFlags_SizingStretchProp()) then
      reaper.ImGui_TableSetupColumn(ctx, "Label", reaper.ImGui_TableColumnFlags_WidthFixed(), 70)
      reaper.ImGui_TableSetupColumn(ctx, "Name",  reaper.ImGui_TableColumnFlags_WidthStretch())

      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableSetColumnIndex(ctx, 0); reaper.ImGui_Text(ctx, "Current")
      reaper.ImGui_TableSetColumnIndex(ctx, 1)
      if cur_colU32 then
        local col_idx = reaper.ImGui_TableGetColumnIndex(ctx)
        reaper.ImGui_TableSetBgColor(ctx, TGT_CELL, cur_colU32, col_idx)
      end
      reaper.ImGui_Text(ctx, cur_name)

      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableSetColumnIndex(ctx, 0); reaper.ImGui_Text(ctx, "Target")
      reaper.ImGui_TableSetColumnIndex(ctx, 1)
      if tgt_colU32 then
        local col_idx = reaper.ImGui_TableGetColumnIndex(ctx)
        reaper.ImGui_TableSetBgColor(ctx, TGT_CELL, tgt_colU32, col_idx)
      end
      reaper.ImGui_Text(ctx, tgt_name)

      reaper.ImGui_EndTable(ctx)
    else
      reaper.ImGui_Text(ctx, "Current: " .. cur_name)
      reaper.ImGui_Text(ctx, "Target:  " .. tgt_name)
    end

    reaper.ImGui_Separator(ctx)

    -- offset input
    reaper.ImGui_Text(ctx, "Measure offset:"); reaper.ImGui_SameLine(ctx)
    local em = reaper.ImGui_GetFontSize(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, math.floor(em * 6))
    local changed, v = reaper.ImGui_InputInt(ctx, "##meas_off", MEAS_OFFSET, 0, 0)
    local input_active = reaper.ImGui_IsItemActive(ctx)
    if changed then MEAS_OFFSET = v; MEAS_OFFSET_STR = tostring(v) end
    if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then redirect_focus(); pending_focus_redirect=false end

    local function do_jump(skip_adjustments)
      if type(MEAS_OFFSET) ~= "number" then return end
      local was_playing = (reaper.GetPlayState() & 1) == 1
      local t_edit_now0 = reaper.GetCursorPosition()
      local t_play_now  = reaper.GetPlayPosition()
      
      local adjusted_offset = MEAS_OFFSET
      
      if not skip_adjustments then
        -- Check if current region starts on the one
        local cur_rg_info = region_info_at_time(t_edit_now0)
        if cur_rg_info then
          local frac_at_region_start = frac_in_measure_at_time(cur_rg_info.pos)
          -- If region doesn't start on the one (frac > 0), subtract one from measure distance
          if frac_at_region_start > 0.001 then  -- small tolerance for floating point
            if adjusted_offset > 0 then
              adjusted_offset = adjusted_offset - 1
            elseif adjusted_offset < 0 then
              adjusted_offset = adjusted_offset + 1
            end
          end
        end
        
        -- Check if target region doesn't start on the one
        local t_preliminary = jump_time_by_measures(t_edit_now0, adjusted_offset)
        local tgt_rg_info = region_info_at_time(t_preliminary)
        if tgt_rg_info then
          local frac_at_target_start = frac_in_measure_at_time(tgt_rg_info.pos)
          -- If target region doesn't start on the one (frac > 0), add one measure
          -- (target's "measure 1" is effectively the next measure)
          if frac_at_target_start > 0.001 then
            adjusted_offset = adjusted_offset + 1
          end
        end
      end
      
      local t_edit_new  = jump_time_by_measures(t_edit_now0, adjusted_offset)
      local t_play_new  = jump_time_by_measures(t_play_now,  adjusted_offset)
      reaper.SetEditCurPos(t_edit_new, false, false)
      if was_playing then
        reaper.SetEditCurPos(t_play_new, false, true)
        reaper.SetEditCurPos(t_edit_new, false, false)
      end
      preserve_view_relative_to_edit_cursor(t_edit_now0, t_edit_new)
      me_recenter_target_time = t_edit_new; me_recenter_frames = 2
      MEAS_OFFSET = -MEAS_OFFSET; MEAS_OFFSET_STR = tostring(MEAS_OFFSET)
      if any_mouse_down(ctx) then pending_focus_redirect=true else redirect_focus() end
    end

    if reaper.ImGui_Button(ctx, "Jump") then do_jump(true) end

    -- external triggers
    do
      local sig = reaper.GetExtState(EXT_SECTION, EXT_KEY_JUMP)
      if sig == "1" then reaper.DeleteExtState(EXT_SECTION, EXT_KEY_JUMP, false); do_jump(true) end
    end
    do
      local ret, rid_str = reaper.GetProjExtState(0, EXT_SECTION_PT, EXT_KEY_PT_REGION_ID)
      if ret == 1 and rid_str ~= "" then
        reaper.SetProjExtState(0, EXT_SECTION_PT, EXT_KEY_PT_REGION_ID, "")
        
        -- Check for absolute jump prefix
        local is_absolute = false
        if rid_str:sub(1, 4) == "ABS:" then
          is_absolute = true
          rid_str = rid_str:sub(5)  -- Remove the prefix
        end
        
        local rid = tonumber(rid_str)
        if rid then
          local regs = REGIONS
          local idx = find_index_by_region_id(rid, regs)
          if idx and regs[idx] then
            if is_absolute then
              -- Absolute jump: go to start of target region
              local t_edit_now0 = reaper.GetCursorPosition()
              local t_target = regs[idx].pos
              reaper.SetEditCurPos(t_target, false, false)
              preserve_view_relative_to_edit_cursor(t_edit_now0, t_target)
              me_recenter_target_time = t_target
              me_recenter_frames = 2
              -- Set measure offset for potential return jump
              local cur_rg2 = region_info_at_time(t_edit_now0)
              if cur_rg2 then
                local m_sel = measure_index_at_time(regs[idx].pos)
                local m_cur = measure_index_at_time(cur_rg2.pos)
                MEAS_OFFSET = -(m_sel - m_cur)
                MEAS_OFFSET_STR = tostring(MEAS_OFFSET)
              end
              if any_mouse_down(ctx) then pending_focus_redirect=true else redirect_focus() end
            else
              -- Relative jump: use measure offset
              local cur_rg2 = region_info_at_time(reaper.GetCursorPosition())
              if cur_rg2 then
                -- Calculate effective first measure of current region
                local cur_m = measure_index_at_time(cur_rg2.pos)
                local cur_frac = frac_in_measure_at_time(cur_rg2.pos)
                local cur_effective_m = (cur_frac > 0.001) and (cur_m + 1) or cur_m
                
                -- Calculate effective first measure of target region
                local tgt_m = measure_index_at_time(regs[idx].pos)
                local tgt_frac = frac_in_measure_at_time(regs[idx].pos)
                local tgt_effective_m = (tgt_frac > 0.001) and (tgt_m + 1) or tgt_m
                
                -- Offset is difference between effective first measures
                MEAS_OFFSET = tgt_effective_m - cur_effective_m
                MEAS_OFFSET_STR = tostring(MEAS_OFFSET)
              end
              do_jump(true)  -- skip adjustments since we already calculated correctly
            end
          end
        end
      end
    end

    -- background click -> give up focus (not while editing textbox)
    do
      local bg_click = reaper.ImGui_IsWindowHovered(ctx)
                    and (reaper.ImGui_IsMouseReleased(ctx,0) or reaper.ImGui_IsMouseClicked(ctx,0))
                    and not input_active
      if bg_click then if any_mouse_down(ctx) then pending_focus_redirect=true else redirect_focus() end end
    end

    -- deferred handoff
    do
      local focused_now = reaper.ImGui_IsWindowFocused(ctx)
      local any_down = any_mouse_down(ctx)
      local block_redirect = input_active
      if focused_now and not was_focused then
        if not block_redirect then
          if any_down then pending_focus_redirect=true else redirect_focus() end
        else
          pending_focus_redirect=false
        end
      end
      if pending_focus_redirect and not any_down and not block_redirect then redirect_focus(); pending_focus_redirect=false end
      was_focused = focused_now
    end
  end

  reaper.ImGui_End(ctx)
  reaper.ImGui_PopStyleVar(ctx, 2)
  if open == false or not is_running then
    is_running = false
    return
  end
  reaper.defer(ui_loop)
end

-- Start the Jump Regions window
function JumpRegions.start()
  if is_running then return end  -- Already running
  
  -- Initialize state
  REGIONS = scan_regions()
  last_proj_change = reaper.GetProjectStateChangeCount(0)
  MEAS_OFFSET = 0
  MEAS_OFFSET_STR = "0"
  me_recenter_target_time = nil
  me_recenter_frames = 0
  was_focused = false
  pending_focus_redirect = false
  
  -- Create ImGui context
  ctx = reaper.ImGui_CreateContext("Jump Regions")
  WIN_FLAGS = reaper.ImGui_WindowFlags_NoCollapse()
  
  is_running = true
  reaper.defer(ui_loop)
end

-- Stop the Jump Regions window
function JumpRegions.stop()
  is_running = false
  -- Context will be garbage collected when no longer referenced
end

-- Check if running
function JumpRegions.is_running()
  return is_running
end

-- Return the module
return JumpRegions

