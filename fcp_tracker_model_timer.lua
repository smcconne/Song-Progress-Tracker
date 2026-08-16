-- fcp_tracker_model_timer.lua
-- Per-region active-time accumulator for the Song Progress Tracker.
-- Split out of fcp_tracker_model.lua.

local reaper = reaper
local ImGui  = reaper

function current_timer_diff()
  -- The active mode's canonical key (Expert/.../H1/.../Camera/Lighting).
  local obj = current_tab_obj and current_tab_obj()
  if obj and obj.current_mode_key then
    local key = obj:current_mode_key()
    if key then return key end
  end
  return "Expert"
end

function region_time_tick()
  local now = reaper.time_precise()
  local ri = active_region_index()
  local tab = current_tab
  local obj = current_tab_obj and current_tab_obj() or nil
  local vkey = "regular"
  if obj and obj.current_variant_key then
    vkey = obj:current_variant_key()
  end
  local diff = current_timer_diff()

  -- Track mouse movement for inactivity detection
  local mx, my = reaper.GetMousePosition()
  if mx ~= MOUSE_LAST_X or my ~= MOUSE_LAST_Y then
    MOUSE_LAST_X = mx
    MOUSE_LAST_Y = my
    MOUSE_LAST_MOVE_TIME = now
  end
  local inactive = MOUSE_LAST_MOVE_TIME and (now - MOUSE_LAST_MOVE_TIME >= 0.5)

  -- Only count for tabs that have a progress table (not Preferences/Setup/Overdrive)
  local valid_tab = (tab == "Drums" or tab == "Bass" or tab == "Guitar"
                     or tab == "Keys" or tab == "Vocals" or tab == "Venue")

  -- Check if the active difficulty cell for this region is In Progress
  local all_idle = false
  if valid_tab and ri then
    -- state_diff is the canonical mode key; current_timer_diff() returns
    -- the right value for each tab, so we reuse it.
    local state_diff = diff
    local st = (STATE[tab] and STATE[tab][vkey] and STATE[tab][vkey][state_diff] and STATE[tab][vkey][state_diff][ri]) or 0
    all_idle = (st ~= 1)
  end

  -- Must reset anchor when conditions change so inactive time isn't credited
  if not valid_tab or not ri or inactive or all_idle
     or ri ~= REGION_TIME_LAST_REGION or tab ~= REGION_TIME_LAST_TAB
     or diff ~= REGION_TIME_LAST_DIFF then
    REGION_TIME_LAST_TICK = nil
    REGION_TIME_LAST_REGION = ri
    REGION_TIME_LAST_TAB = tab
    REGION_TIME_LAST_DIFF = diff
    return
  end

  -- Start fresh anchor when resuming from a reset
  if not REGION_TIME_LAST_TICK then
    REGION_TIME_LAST_TICK = now
    return
  end

  -- Accumulate whole seconds
  local elapsed = now - REGION_TIME_LAST_TICK
  if elapsed >= 1.0 then
    local whole = math.floor(elapsed)
    REGION_TIME_LAST_TICK = REGION_TIME_LAST_TICK + whole
    REGION_TIME[tab] = REGION_TIME[tab] or {}
    REGION_TIME[tab][vkey] = REGION_TIME[tab][vkey] or {}
    REGION_TIME[tab][vkey][diff] = REGION_TIME[tab][vkey][diff] or {}
    local prev = REGION_TIME[tab][vkey][diff][ri] or 0
    REGION_TIME[tab][vkey][diff][ri] = prev + whole
    save_region_time(tab, diff, ri, REGION_TIME[tab][vkey][diff][ri])
  end
end
