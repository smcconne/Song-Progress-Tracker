-- fcp_tracker_ui_table_common.lua
-- Shared helpers consumed by the table renderers (progress, overdrive, prefs).
-- Loaded before any of the three table files in the to_load chain. No state,
-- no side effects. The four helpers here are the only legitimate cross-file
-- table helpers; table-local state stays in each table file.

local reaper = reaper
local ImGui  = reaper

-- Encapsulates the TAB_SCROLL_ROW <-> SetScrollY <-> wheel-step dance. Pass
-- preserve_index = true when the caller just set TAB_SCROLL_ROW for centering.
function scroll_snap_to_row(ctx, scroll_key, max_n, row_h, preserve_index)
  local sy = ImGui.ImGui_GetScrollY(ctx)
  if not preserve_index then
    do
      local n_from_sy = math.max(0, math.min(max_n, math.floor((sy / row_h) + 0.5)))
      if TAB_SCROLL_ROW[scroll_key] ~= n_from_sy then
        TAB_SCROLL_ROW[scroll_key] = n_from_sy
      end
    end
  end
  if TAB_SCROLL_ROW[scroll_key] ~= nil then
    local target_sy = (TAB_SCROLL_ROW[scroll_key] or 0) * row_h
    if math.abs(sy - target_sy) > 0.5 then
      ImGui.ImGui_SetScrollY(ctx, target_sy)
      sy = target_sy
    end
  end
  if ImGui.ImGui_IsWindowHovered(ctx, 0) then
    local wheel = ImGui.ImGui_GetMouseWheel(ctx) or 0
    if wheel ~= 0 then
      local step = (wheel > 0) and -1 or 1
      local n = (TAB_SCROLL_ROW[scroll_key] or 0) + step
      if n < 0 then n = 0 elseif n > max_n then n = max_n end
      TAB_SCROLL_ROW[scroll_key] = n
      ImGui.ImGui_SetScrollY(ctx, n * row_h)
    end
  end
end

-- Last row gets an extra 1px of height to avoid scrollbar artifacts.
function last_row_height_hack(row_idx, num_rows, row_h)
  if row_idx == num_rows then
    return ImGui.ImGui_TableRowFlags_None(), row_h + 1
  end
  return ImGui.ImGui_TableRowFlags_None(), row_h
end

-- BeginChild wrapper for the scrollable body: centralises NoScrollWithMouse
-- and the height contract. Callers call ImGui_EndChild themselves.
function table_zone_child(ctx, name, body_h)
  local child_flags = ImGui.ImGui_WindowFlags_NoScrollWithMouse()
  return ImGui.ImGui_BeginChild(ctx, name, 0, body_h, 0, child_flags)
end

-- Convert a take-local PPQ position to a 1-based measure number.
function ppq_to_measure(tk, ppq)
  local proj_time = reaper.MIDI_GetProjTimeFromPPQPos(tk, ppq)
  local _, measure_raw = reaper.TimeMap2_timeToBeats(0, proj_time)
  return math.floor(measure_raw) + 1
end
