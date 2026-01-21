-- fcp_tracker_layout.lua
-- Split from Switch RBN Previews Driver (background).lua

function focus_walk_left_to_right()
  local tracks = {}
  for _,key in ipairs(ORDER) do
    local tr = find_track_by_name(TRACKS[key])
    if tr then tracks[#tracks+1] = tr end
  end
  local i = 1
  local function go()
    if i > #tracks then return no_undo() end
    focus_floating(tracks[i]); i = i + 1
    local tF = reaper.time_precise()
    local function waitF()
      if reaper.time_precise() - tF < FOCUS_DELAY then return reaper.defer(waitF) end
      go()
    end
    reaper.defer(waitF)
  end
  go()
end

function restore_set_layout_open_all_parallel(cb)
  local x0,y0,w,h = get_master_geom()
  if not x0 then if cb then cb() end; return end

  local pending, started = 0, 0
  local fired = false
  local function fire_once()
    if fired then return end
    fired = true
    if cb then cb() end
  end

  -- watchdog: guarantee cb within ~0.8s
  local t_start = reaper.time_precise()
  local function watchdog()
    if fired then return end
    if reaper.time_precise() - t_start >= 0.8 then
      fire_once()
    else
      reaper.defer(watchdog)
    end
  end
  reaper.defer(watchdog)

  local function done_one()
    if fired then return end
    pending = pending - 1
    if pending <= 0 then fire_once() end
  end

  for _,key in ipairs(ORDER) do
    local tr = find_track_by_name(TRACKS[key])
    local fx = tr and get_instrument_fx_index(tr) or nil
    if tr and fx then
      started = started + 1
      pending = pending + 1
      local tx, ty = slot_xy(key, x0,y0,w,h)

      local saved = snapshot_selection(); reaper.SetOnlyTrackSelected(tr)
      reaper.TrackFX_Show(tr, fx, 3) -- open floater
      restore_selection(saved)

      local t0 = reaper.time_precise()
      local function after_open()
        if reaper.time_precise() - t0 < 0.03 then return reaper.defer(after_open) end
        apply_float_to_track(tr, tx, ty, w, h)
        local hwnd = reaper.TrackFX_GetFloatingWindow(tr, fx)
        if HAS_JS_MOVE and hwnd then
          reaper.JS_Window_Move(hwnd, math.floor(tx), math.floor(ty))
          reaper.JS_Window_Resize(hwnd, math.floor(w), math.floor(h))
        end
        nudge_resize_track_keep_xy(tr, w, h, done_one)
      end
      reaper.defer(after_open)
    end
  end

  if started == 0 then fire_once() end
end

function lineup_save_and_apply_then_focus()
  local trD = find_track_by_name(TRACKS.DRUMS); if not trD then return end
  local _,_,_, fxD = get_fxchain_and_span(trD); if not fxD then return end
  local x, y, w, h = get_float_from_fxchain(fxD); if not (x and y and w and h) then return end

  -- Save global origin + size
  save_origin_global(x, y)
  save_wh_global(w, h)

  local function pos_k(k) return x + k*(w + GAP_PX), y end
  local trB = find_track_by_name(TRACKS.BASS)
  local trG = find_track_by_name(TRACKS.GUITAR)
  local trK = find_track_by_name(TRACKS.KEYS)

  local x0,y0 = pos_k(0); local x1,y1 = pos_k(1); local x2,y2 = pos_k(2); local x3,y3 = pos_k(3)
  local function apply_all(dw, dh)
    local aw, ah = w + (dw or 0), h + (dh or 0)
    apply_float_to_track(trD, x0,y0, aw,ah)
    if trB then apply_float_to_track(trB, x1,y1, aw,ah) end
    if trG then apply_float_to_track(trG, x2,y2, aw,ah) end
    if trK then apply_float_to_track(trK, x3,y3, aw,ah) end
    reaper.TrackList_AdjustWindows(false)
  end

  apply_all(NUDGE_BIG, NUDGE_BIG)
  local tA = reaper.time_precise()
  local function stepB()
    if reaper.time_precise() - tA < DELAY_BIG then return reaper.defer(stepB) end
    apply_all(0,0)
    local tB = reaper.time_precise()
    local function stepC()
      if reaper.time_precise() - tB < DELAY_SMALL then return reaper.defer(stepC) end
      apply_all(NUDGE_SMALL, NUDGE_SMALL)
      local tC = reaper.time_precise()
      local function stepD()
        if reaper.time_precise() - tC < DELAY_SMALL then return reaper.defer(stepD) end
        apply_all(0,0)
        focus_walk_left_to_right()
      end
      reaper.defer(stepD)
    end
    reaper.defer(stepC)
  end
  reaper.defer(stepB)
end

