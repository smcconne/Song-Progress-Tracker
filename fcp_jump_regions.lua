-- @description Jumps the edit cursor the difference in measures between regions
-- @version 2.0.0
-- @author FinestCardboardPearls

-- Headless logic module for measure-offset jumping.
-- UI is rendered inline by fcp_tracker_ui_table.lua (Region header cell).

local JumpRegions = {}

local proj = 0
local ME_GO_TO_EDIT_CURSOR = 40151
local EXT_SECTION = "REGIONS_JUMP_UI"
local EXT_KEY_JUMP = "JUMP_NOW"
local EXT_SECTION_PT = "FCP_JUMP"
local EXT_KEY_PT_REGION_ID = "TARGET_REGION_ID"

-- Public state (read/written by the table header UI)
JumpRegions.MEAS_OFFSET = 0
JumpRegions.input_active = false  -- true while the InputInt is focused

-- Deferred MIDI-editor recenter
local me_recenter_target_time, me_recenter_frames = nil, 0

-- Helpers ----------------------------------------------------------------

local function region_info_at_time(t)
  local _, idx = reaper.GetLastMarkerAndCurRegion(proj, t)
  if idx and idx >= 0 and reaper.EnumProjectMarkers3 then
    local ok, isrgn, pos, r_end, name, id, color = reaper.EnumProjectMarkers3(proj, idx)
    if ok and isrgn then
      return { label=(name and name~="") and name or ("Region "..tostring(id or 0)),
               id=id or -1, pos=pos or 0, rgnend=r_end or pos or 0, color=color or 0 }
    end
  end
  return nil
end

local function find_index_by_region_id(id, regs)
  if not id then return nil end
  for i, r in ipairs(regs) do if r.id == id then return i end end
  return nil
end

local function measure_index_at_time(t)
  local _, m = reaper.TimeMap2_timeToBeats(proj, t); return math.floor(m or 0)
end
local function measure_qn_bounds(i)
  local _, s, e = reaper.TimeMap_GetMeasureInfo(proj, i); return s or 0, e or 0
end
local function frac_in_measure_at_time(t)
  local qn = reaper.TimeMap_timeToQN(t) or 0
  local m = measure_index_at_time(t)
  local s, e = measure_qn_bounds(m)
  local L = e - s
  if L <= 0 then return 0.0, m end
  return (qn - s) / L, m
end
local function time_at_measure_with_frac(i, f)
  local s, e = measure_qn_bounds(i)
  local L = e - s
  if L <= 0 then return reaper.TimeMap_QNToTime(s) end
  local qt = s + (math.max(0, math.min(1, f)) * L)
  return reaper.TimeMap_QNToTime(qt)
end
local function jump_time_by_measures(t, off)
  local frac, m = frac_in_measure_at_time(t)
  return time_at_measure_with_frac(m + (off or 0), frac)
end

local function preserve_view_relative_to_edit_cursor(pre_t, post_t)
  local st, et = reaper.GetSet_ArrangeView2(proj, false, 0, 0)
  if not (st and et) then return end
  local ns = post_t - (pre_t - st)
  local ne = post_t + (et - pre_t)
  if ns < 0 then local sh = -ns; ns = 0; ne = ne + sh end
  reaper.GetSet_ArrangeView2(proj, true, 0, 0, ns, ne)
end

local function redirect_focus()
  if reaper.MIDIEditor_GetActive() and reaper.SN_FocusMIDIEditor then
    reaper.SN_FocusMIDIEditor()
  else
    reaper.SetCursorContext(0, nil)
  end
end

-- Jump execution ---------------------------------------------------------

function JumpRegions.do_jump(skip_adjustments)
  local MEAS_OFFSET = JumpRegions.MEAS_OFFSET
  if type(MEAS_OFFSET) ~= "number" then return end

  local was_playing = (reaper.GetPlayState() & 1) == 1
  local t_edit_now0 = reaper.GetCursorPosition()
  local t_play_now  = reaper.GetPlayPosition()

  local adjusted_offset = MEAS_OFFSET

  if not skip_adjustments then
    local cur_rg_info = region_info_at_time(t_edit_now0)
    if cur_rg_info then
      local frac_at_region_start = frac_in_measure_at_time(cur_rg_info.pos)
      if frac_at_region_start > 0.001 then
        if adjusted_offset > 0 then
          adjusted_offset = adjusted_offset - 1
        elseif adjusted_offset < 0 then
          adjusted_offset = adjusted_offset + 1
        end
      end
    end
    local t_preliminary = jump_time_by_measures(t_edit_now0, adjusted_offset)
    local tgt_rg_info = region_info_at_time(t_preliminary)
    if tgt_rg_info then
      local frac_at_target_start = frac_in_measure_at_time(tgt_rg_info.pos)
      if frac_at_target_start > 0.001 then
        adjusted_offset = adjusted_offset + 1
      end
    end
  end

  local t_edit_new = jump_time_by_measures(t_edit_now0, adjusted_offset)
  local t_play_new = jump_time_by_measures(t_play_now, adjusted_offset)
  reaper.SetEditCurPos(t_edit_new, false, false)
  if was_playing then
    reaper.SetEditCurPos(t_play_new, false, true)
    reaper.SetEditCurPos(t_edit_new, false, false)
  end
  preserve_view_relative_to_edit_cursor(t_edit_now0, t_edit_new)
  me_recenter_target_time = t_edit_new
  me_recenter_frames = 2
  JumpRegions.MEAS_OFFSET = -MEAS_OFFSET
  redirect_focus()
end

-- Per-frame tick (deferred MIDI recenter) --------------------------------

function JumpRegions.tick()
  if me_recenter_frames > 0 then
    me_recenter_frames = me_recenter_frames - 1
    if me_recenter_frames == 0 and me_recenter_target_time then
      reaper.SetEditCurPos(me_recenter_target_time, false, false)
      local me = reaper.MIDIEditor_GetActive()
      if me and ME_GO_TO_EDIT_CURSOR > 0 then
        reaper.MIDIEditor_OnCommand(me, ME_GO_TO_EDIT_CURSOR)
      end
      me_recenter_target_time = nil
    end
  end
end

-- External signal processing ---------------------------------------------
-- Uses the global REGIONS from fcp_tracker_model.lua

function JumpRegions.process_ext_signals()
  -- Signal 1: simple "jump now" flag
  do
    local sig = reaper.GetExtState(EXT_SECTION, EXT_KEY_JUMP)
    if sig == "1" then
      reaper.DeleteExtState(EXT_SECTION, EXT_KEY_JUMP, false)
      JumpRegions.do_jump(true)
    end
  end

  -- Signal 2: region-id based jump (from progress tracker table clicks)
  do
    local ret, rid_str = reaper.GetProjExtState(0, EXT_SECTION_PT, EXT_KEY_PT_REGION_ID)
    if ret == 1 and rid_str ~= "" then
      reaper.SetProjExtState(0, EXT_SECTION_PT, EXT_KEY_PT_REGION_ID, "")

      local is_absolute = false
      if rid_str:sub(1, 4) == "ABS:" then
        is_absolute = true
        rid_str = rid_str:sub(5)
      end

      local rid = tonumber(rid_str)
      if rid then
        local regs = REGIONS  -- global from fcp_tracker_model.lua
        local idx = find_index_by_region_id(rid, regs)
        if idx and regs[idx] then
          if is_absolute then
            local t_edit_now0 = reaper.GetCursorPosition()
            local t_target = regs[idx].pos
            reaper.SetEditCurPos(t_target, false, false)
            preserve_view_relative_to_edit_cursor(t_edit_now0, t_target)
            me_recenter_target_time = t_target
            me_recenter_frames = 2
            JumpRegions.MEAS_OFFSET = -JumpRegions.MEAS_OFFSET
            redirect_focus()
          else
            local cur_rg2 = region_info_at_time(reaper.GetCursorPosition())
            if cur_rg2 then
              local cur_m = measure_index_at_time(cur_rg2.pos)
              local cur_frac = frac_in_measure_at_time(cur_rg2.pos)
              local cur_effective_m = (cur_frac > 0.001) and (cur_m + 1) or cur_m

              local tgt_m = measure_index_at_time(regs[idx].pos)
              local tgt_frac = frac_in_measure_at_time(regs[idx].pos)
              local tgt_effective_m = (tgt_frac > 0.001) and (tgt_m + 1) or tgt_m

              JumpRegions.MEAS_OFFSET = tgt_effective_m - cur_effective_m
            end
            JumpRegions.do_jump(true)
          end
        end
      end
    end
  end
end

-- Return the module
return JumpRegions

