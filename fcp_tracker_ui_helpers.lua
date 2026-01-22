-- fcp_tracker_ui_helpers.lua
-- Color helpers, measure helpers, and utility functions for Song Progress UI

local reaper = reaper
local ImGui  = reaper

-- Color helpers ---------------------------------------------------------

function pct_to_u32(p)
  if p < 0 then p = 0 elseif p > 100 then p = 100 end
  local r,g,b
  if p <= 60 then local t=p/60; r,g,b = 1, t, 0 else local t=(p-60)/40; r,g,b = 1-t, 1, 0 end
  return ImGui.ImGui_ColorConvertDouble4ToU32(r,g,b,1)
end

function pct_scaled_u32(p, mul, a)
  if p < 0 then p = 0 elseif p > 100 then p = 100 end
  local r,g,b
  if p <= 60 then local t=p/60; r,g,b = 1, t, 0 else local t=(p-60)/40; r,g,b = 1-t, 1, 0 end
  local base = 1 - 0.25*(p/100)
  local m = (mul or 1) * base
  return ImGui.ImGui_ColorConvertDouble4ToU32(math.min(1,r*m), math.min(1,g*m), math.min(1,b*m), a or 1)
end

function lighten_u32(col_u32, amt)
  local r =  (col_u32        & 0xFF) / 255.0
  local g = ((col_u32 >>  8) & 0xFF) / 255.0
  local b = ((col_u32 >> 16) & 0xFF) / 255.0
  local a = ((col_u32 >> 24) & 0xFF) / 255.0
  r = r + (1.0 - r) * amt
  g = g + (1.0 - g) * amt
  b = b + (1.0 - b) * amt
  return ImGui.ImGui_ColorConvertDouble4ToU32(r, g, b, a)
end

-- Pre-computed colors (initialized lazily)
local colors_initialized = false
COL_TEXT = nil
COL_CURSOR_LINE = nil
COL_PREVIEW_LINE = nil

function init_colors()
  if colors_initialized then return end
  COL_TEXT = ImGui.ImGui_ColorConvertDouble4ToU32(1,1,1,1)
  COL_CURSOR_LINE = ImGui.ImGui_ColorConvertDouble4ToU32(0, 0.6, 0.4, 0.7)
  COL_PREVIEW_LINE = ImGui.ImGui_ColorConvertDouble4ToU32(0.8, 0.4, 0.1, 0.7)
  colors_initialized = true
end

-- Modifier key helper ---------------------------------------------------

function any_modifier_held()
  -- JS_Mouse_GetState with bitmask to query modifier keys:
  -- Control/Cmd: (1 << 2) = 4
  -- Shift: (1 << 3) = 8
  -- Alt/Option: (1 << 4) = 16
  local ctrl  = reaper.JS_Mouse_GetState(1 << 2) ~= 0
  local shift = reaper.JS_Mouse_GetState(1 << 3) ~= 0
  local alt   = reaper.JS_Mouse_GetState(1 << 4) ~= 0
  return ctrl or shift or alt
end

-- Active region helper --------------------------------------------------

function active_region_index()
  local st = reaper.GetPlayState()
  local t  = (st & 1) == 1 and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  
  -- First pass: check if cursor is exactly at the start of any region
  -- This ensures boundary cases show the cursor in the "beginning" region
  for i = 1, #REGIONS do
    local rs = REGIONS[i].pos or 0
    if math.abs(t - rs) < 0.0001 then  -- Effectively equal to region start
      return i
    end
  end
  
  -- Second pass: find which region contains the cursor
  for i = 1, #REGIONS do
    local rs, re_ = REGIONS[i].pos or 0, REGIONS[i].r_end or 0
    if t >= rs and t < re_ then return i end
  end
end

-- Measure helpers for preview line calculation --------------------------

function measure_index_at_time(t)
  local _, m = reaper.TimeMap2_timeToBeats(0, t)
  return math.floor(m or 0)
end

function measure_qn_bounds(i)
  local _, s, e = reaper.TimeMap_GetMeasureInfo(0, i)
  return s or 0, e or 0
end

function frac_in_measure_at_time(t)
  local qn = reaper.TimeMap_timeToQN(t) or 0
  local m = measure_index_at_time(t)
  local s, e = measure_qn_bounds(m)
  local L = e - s
  if L <= 0 then return 0.0, m end
  return (qn - s) / L, m
end

function time_at_measure_with_frac(i, f)
  local s, e = measure_qn_bounds(i)
  local L = e - s
  if L <= 0 then return reaper.TimeMap_QNToTime(s) end
  local qt = s + (math.max(0, math.min(1, f)) * L)
  return reaper.TimeMap_QNToTime(qt)
end

function jump_time_by_measures(t, off)
  local frac, m = frac_in_measure_at_time(t)
  return time_at_measure_with_frac(m + (off or 0), frac)
end

-- Metrics helper --------------------------------------------------------

function max_label_width(ctx)
  local maxw = 0
  for _,t in ipairs(TABS) do
    local s = t.." Progress"
    local w = select(1, ImGui.ImGui_CalcTextSize(ctx, s))
    if w > maxw then maxw = w end
  end
  return math.ceil(maxw) + 12
end