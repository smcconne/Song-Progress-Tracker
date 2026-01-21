-- fcp_tracker_focus.lua
-- Focus helpers + driver loop. Assumes JS_ReaScript API is present.

-- Target FX name to search for (substring match)
local RBN_PREVIEW_FX_NAME = "RBN Preview"

-- get RBN Preview FX index on a track (searches by name, not just first instrument)
function get_instrument_fx_index(tr)
  if not tr then return nil end
  local cnt = reaper.TrackFX_GetCount(tr)
  -- First pass: search for RBN Preview by name
  for i = 0, cnt - 1 do
    local rv, fxname = reaper.TrackFX_GetFXName(tr, i, "")
    if rv and fxname and fxname:find(RBN_PREVIEW_FX_NAME, 1, true) then
      return i
    end
  end
  -- Fallback: no RBN Preview found
  return nil
end

-- hide a specific floater on a track (no toggle-close after)
function hide_float_if_any(tr, fx)
  local hwnd = reaper.TrackFX_GetFloatingWindow(tr, fx)
  if hwnd then
    reaper.TrackFX_Show(tr, fx, 4) -- hide
    if reaper.TrackFX_GetFloatingWindow(tr, fx) then
      reaper.TrackFX_Show(tr, fx, 2) -- one toggle close
    end
  end
end

-- close all floaters on a track
function close_all_floats_on_track(tr)
  local cnt = reaper.TrackFX_GetCount(tr)
  for fx = 0, cnt-1 do hide_float_if_any(tr, fx) end
end

-- ensure floater exists and focus it
function focus_floating(tr)
  if not tr then return end
  local fx = get_instrument_fx_index(tr); if not fx then return end

  local hwnd = reaper.TrackFX_GetFloatingWindow(tr, fx)
  if not hwnd then
    local saved = snapshot_selection()
    reaper.SetOnlyTrackSelected(tr)
    reaper.TrackFX_Show(tr, fx, 3) -- show floater
    restore_selection(saved)
    local t0 = reaper.time_precise()
    while (not hwnd) and (reaper.time_precise() - t0 < 0.05) do
      hwnd = reaper.TrackFX_GetFloatingWindow(tr, fx)
    end
  end

  if hwnd then
    reaper.JS_Window_SetForeground(hwnd)
    reaper.JS_Window_SetFocus(hwnd)
  end
end

-- epoch bookkeeping to cancel stale async ops
function bump_epoch(key) focus_epoch[key] = (focus_epoch[key] or 0) + 1; return focus_epoch[key] end
function is_stale(key, epoch) return epoch ~= focus_epoch[key] end

-- ensure open, persist geometry, slam window position/size, optional nudge on reopen, then focus
function hard_apply_for_track(key, tr, x, y, w, h, nudge_on_reopen)
  if not tr then return end
  local fx = get_instrument_fx_index(tr); if not fx then return end
  local epoch = bump_epoch(key)

  if x and y and w and h then apply_float_to_track(tr, x, y, w, h) end

  local hwnd = reaper.TrackFX_GetFloatingWindow(tr, fx)
  local wasOpen = hwnd ~= nil
  if not wasOpen then
    local saved = snapshot_selection(); reaper.SetOnlyTrackSelected(tr)
    reaper.TrackFX_Show(tr, fx, 3)
    restore_selection(saved)
    local t0 = reaper.time_precise()
    while (not hwnd) and (reaper.time_precise() - t0 < 0.25) do
      hwnd = reaper.TrackFX_GetFloatingWindow(tr, fx)
    end
  end

  if is_stale(key, epoch) then return end

  hwnd = reaper.TrackFX_GetFloatingWindow(tr, fx)
  if hwnd and x and y and w and h then
    reaper.JS_Window_Move(hwnd, math.floor(x), math.floor(y))
    reaper.JS_Window_Resize(hwnd, math.floor(w), math.floor(h))
    if (not wasOpen) and nudge_on_reopen then
      nudge_resize_track_keep_xy(tr, w, h, function()
        if not is_stale(key, epoch) then focus_floating(tr) end
      end)
    else
      focus_floating(tr)
    end
    return
  end

  if wasOpen then
    reaper.TrackFX_Show(tr, fx, 4)  -- hide
    local t1 = reaper.time_precise()
    local function show_again()
      if is_stale(key, epoch) then return end
      if reaper.time_precise() - t1 < 0.03 then return reaper.defer(show_again) end
      reaper.TrackFX_Show(tr, fx, 3) -- show
      local function finalize()
        if is_stale(key, epoch) then return end
        if (not wasOpen) and nudge_on_reopen then
          nudge_resize_track_keep_xy(tr, w, h, function()
            if not is_stale(key, epoch) then focus_floating(tr) end
          end)
        else
          focus_floating(tr)
        end
      end
      reaper.defer(finalize)
    end
    reaper.defer(show_again)
  else
    if nudge_on_reopen then
      nudge_resize_track_keep_xy(tr, w, h, function()
        if not is_stale(key, epoch) then focus_floating(tr) end
      end)
    else
      focus_floating(tr)
    end
  end
end

-- close others, apply to target
function manage_floats(targetKey)
  local x0,y0,w,h = get_master_geom()
  for _,key in ipairs(ORDER) do
    if key ~= targetKey then
      local tr = find_track_by_name(TRACKS[key])
      if tr then close_all_floats_on_track(tr) end
    end
  end
  local tr_target = find_track_by_name(TRACKS[targetKey])
  if tr_target and x0 then
    hard_apply_for_track(targetKey, tr_target, x0, y0, w, h, true)
  elseif tr_target then
    local fx = get_instrument_fx_index(tr_target); if fx then
      local saved = snapshot_selection(); reaper.SetOnlyTrackSelected(tr_target)
      reaper.TrackFX_Show(tr_target, fx, 3)
      restore_selection(saved)
      focus_floating(tr_target)
    end
  end
end

-- enable only the focused instrument
function set_focus_enabled(targetKey)
  for key, name in pairs(TRACKS) do
    local tr = find_track_by_name(name)
    if tr then
      local fx = get_instrument_fx_index(tr)
      if fx then reaper.TrackFX_SetEnabled(tr, fx, key == targetKey) end
    end
  end
end

-- enable all instruments
function clear_focus_enabled()
  for _, name in pairs(TRACKS) do
    local tr = find_track_by_name(name)
    if tr then
      local fx = get_instrument_fx_index(tr)
      if fx then reaper.TrackFX_SetEnabled(tr, fx, true) end
    end
  end
end

-- driver loop tick (called from main loop, does NOT defer itself)
local current_focus = "NONE"  -- DRUMS|BASS|GUITAR|KEYS|VOCALS|NONE

function loop_tick()
  -- set requests
  local req = reaper.GetExtState(EXT_NS, EXT_REQ)
  if req and req ~= "" then
    reaper.DeleteExtState(EXT_NS, EXT_REQ, true)

    if     req == "EXPERT"  then ACTIVE_DIFF = "Expert"; PAIR_MODE = 0; run_set("EXPERT")
    elseif req == "HARD"    then ACTIVE_DIFF = "Hard";   PAIR_MODE = 0; run_set("HARD")
    elseif req == "MEDIUM"  then ACTIVE_DIFF = "Medium"; PAIR_MODE = 0; run_set("MEDIUM")
    elseif req == "EASY"    then ACTIVE_DIFF = "Easy";   PAIR_MODE = 0; run_set("EASY")

    -- Pair modes
    elseif req == "HOPOS"   then PAIR_MODE = 1; run_set("HOPOS")
    elseif req == "TRILLS"  then PAIR_MODE = 2; run_set("TRILLS")
    end

    if current_focus ~= "NONE" then
      set_focus_enabled(current_focus)
      manage_floats(current_focus)
    end
  end

  -- lineup (save X/Y/W/H, tile, focus L→R)
  local lu = reaper.GetExtState(EXT_NS, EXT_LINEUP)
  if lu and lu ~= "" then
    reaper.DeleteExtState(EXT_NS, EXT_LINEUP, true)
    lineup_save_and_apply_then_focus()
  end

  -- focus switch
  local foc = reaper.GetExtState(EXT_NS, EXT_FOCUS)
  if foc and foc ~= "" then
    reaper.DeleteExtState(EXT_NS, EXT_FOCUS, true)
    if foc == "NONE" or foc == "SET" then
      current_focus = "NONE"
      clear_focus_enabled()
      restore_set_layout_open_all_parallel(function()
        focus_walk_left_to_right()
      end)
    elseif TRACKS[foc] then
      current_focus = foc
      set_focus_enabled(current_focus)
      manage_floats(current_focus)
    end
  end
  
  -- No defer here - main_loop handles that
end

-- Keep old loop() for backwards compatibility if needed
function loop()
  loop_tick()
  reaper.defer(loop)
end
