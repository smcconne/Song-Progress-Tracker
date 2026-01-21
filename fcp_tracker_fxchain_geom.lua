-- fcp_tracker_fxchain_geom.lua
-- Split from Switch RBN Previews Driver (background).lua

function get_fxchain_and_span(tr)
  local ok, chunk = reaper.GetTrackStateChunk(tr, "", true); if not ok or not chunk then return nil end
  local sPos, ePos = find_fxchain_span_depth(chunk); if not sPos or not ePos then return nil end
  return chunk, sPos, ePos, chunk:sub(sPos, ePos - 1)
end


function get_float_from_fxchain(fxchain)
  local x, y, w, h = fxchain:match("\n%s*FLOAT%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)")
  if x and y and w and h then return tonumber(x), tonumber(y), tonumber(w), tonumber(h) end
  return nil
end


function set_float_in_fxchain(fxchain, x, y, w, h)
  local nx, ny, nw, nh = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
  local newLine = string.format("\nFLOAT %d %d %d %d", nx, ny, nw, nh)
  if fxchain:find("\n%s*FLOAT%s+") then
    return fxchain:gsub("\n%s*FLOAT%s+[%-%d%.]+%s+[%-%d%.]+%s+[%-%d%.]+%s+[%-%d%.]+", newLine, 1)
  else
    local fxidPos = fxchain:find("\n%s*FXID%s*%b{}")
    if fxidPos then
      return fxchain:sub(1, fxidPos-1) .. newLine .. "\n" .. fxchain:sub(fxidPos)
    else
      -- insert before closing '>'
      local i, len, lastGT = 1, #fxchain, nil
      while i <= len do
        local lineEnd = fxchain:find("\n", i) or (len + 1)
        local line = fxchain:sub(i, lineEnd - 1)
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        if line:match("^%s*>%s*$") then lastGT = i; break end
        i = lineEnd + 1
      end
      if lastGT then
        return fxchain:sub(1, lastGT - 1) .. newLine .. "\n" .. fxchain:sub(lastGT)
      else
        return fxchain .. newLine .. "\n"
      end
    end
  end
end


function apply_float_to_track(tr, x, y, w, h)
  if not tr then return end
  local chunk, sPos, ePos, fx = get_fxchain_and_span(tr); if not chunk then return end
  local fxNew = set_float_in_fxchain(fx, x, y, w, h)
  local updated = chunk:sub(1, sPos - 1) .. fxNew .. chunk:sub(ePos)
  reaper.SetTrackStateChunk(tr, updated, false)
end


function save_origin_global(x,y)
  if x and y then
    reaper.SetExtState(EXT_NS, EXT_WH_X, tostring(math.floor(x)), true)
    reaper.SetExtState(EXT_NS, EXT_WH_Y, tostring(math.floor(y)), true)
  end
end


function get_saved_origin()
  local x = tonumber(reaper.GetExtState(EXT_NS, EXT_WH_X) or "")
  local y = tonumber(reaper.GetExtState(EXT_NS, EXT_WH_Y) or "")
  if x and y then return x,y end
  return nil
end


function save_wh_global(w,h)
  if w and h and w > 0 and h > 0 then
    reaper.SetExtState(EXT_NS, EXT_WH_W, tostring(math.floor(w)), true)
    reaper.SetExtState(EXT_NS, EXT_WH_H, tostring(math.floor(h)), true)
  end
end


function get_saved_wh()
  local w = tonumber(reaper.GetExtState(EXT_NS, EXT_WH_W) or "")
  local h = tonumber(reaper.GetExtState(EXT_NS, EXT_WH_H) or "")
  if w and h and w > 0 and h > 0 then return w, h end
  return nil
end


function get_master_geom()
  local sx,sy = get_saved_origin()
  local sw,sh = get_saved_wh()
  if sx and sy and sw and sh then return sx, sy, sw, sh end

  local trD = find_track_by_name(TRACKS.DRUMS); if not trD then return nil end
  local _,_,_, fxD = get_fxchain_and_span(trD); if not fxD then return nil end
  local x,y,w,h = get_float_from_fxchain(fxD); if not (x and y and w and h) then return nil end

  if not sx or not sy then save_origin_global(x,y) end
  if not sw or not sh then save_wh_global(w,h) end

  return x, y, (sw or w), (sh or h)
end


function slot_xy(slotKey, x0,y0,w,h)
  local k = SLOT_IDX[slotKey] or 0
  return x0 + k*(w + GAP_PX), y0
end


function nudge_resize_track_keep_xy(tr, w, h, cb_done)
  if not tr or not w or not h then if cb_done then cb_done() end; return end
  local _,_,_,fx = get_fxchain_and_span(tr); if not fx then if cb_done then cb_done() end; return end
  local x,y = get_float_from_fxchain(fx); if not (x and y) then if cb_done then cb_done() end; return end
  local function stepA()
    apply_float_to_track(tr, x, y, w + NUDGE_BIG, h + NUDGE_BIG)
    local t0 = reaper.time_precise()
    local function stepB()
      if reaper.time_precise() - t0 < DELAY_BIG then return reaper.defer(stepB) end
      apply_float_to_track(tr, x, y, w, h)
      local t1 = reaper.time_precise()
      local function stepC()
        if reaper.time_precise() - t1 < DELAY_SMALL then return reaper.defer(stepC) end
        apply_float_to_track(tr, x, y, w + NUDGE_SMALL, h + NUDGE_SMALL)
        local t2 = reaper.time_precise()
        local function stepD()
          if reaper.time_precise() - t2 < DELAY_SMALL then return reaper.defer(stepD) end
          apply_float_to_track(tr, x, y, w, h)
          if cb_done then cb_done() end
        end
        reaper.defer(stepD)
      end
      reaper.defer(stepC)
    end
    reaper.defer(stepB)
  end
  stepA()
end

