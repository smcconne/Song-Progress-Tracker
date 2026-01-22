-- fcp_tracker_util_fs.lua
-- File system and chunk parsing utilities

-- RBN Preview VST identifier for searching in chunks
local RBN_PREVIEW_VST_ID = '<VST "VSTi: RBN Preview (RBN)"'

function slurp(path) local f=io.open(path,"r"); if not f then return nil end local s=f:read("*a"); f:close(); return s end
function resolve_template_path(short)
  local RP = reaper.GetResourcePath()
  for _,p in ipairs({
    RP.."/TrackTemplates/"..short..".RTrackTemplate",
    RP.."/TrackTemplates/"..short,
    short..".RTrackTemplate",
    short
  }) do local f=io.open(p,"r"); if f then f:close(); return p end end
  return nil
end

-- chunk parsing
function extract_first_track_chunk(data)
  return data:match("(<TRACK.-\n>.-)\n<TRACK") or data:match("(<TRACK.-)$")
end
function find_fxchain_span_depth(chunk)
  local startPos = chunk:find("<FXCHAIN", 1, true)
  if not startPos then return nil, nil end
  local i, len, depth = startPos, #chunk, 0
  while i <= len do
    local lineEnd = chunk:find("\n", i) or (len + 1)
    local line = chunk:sub(i, lineEnd - 1)
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    if line:find("^%s*<") then depth = depth + 1 end
    if line:match("^%s*>%s*$") then
      depth = depth - 1
      if depth == 0 then return startPos, lineEnd end
    end
    i = lineEnd + 1
  end
  return startPos, nil
end
function extract_vst_body_and_preset(fxchain)
  if not fxchain then return nil, nil end
  -- Search specifically for RBN Preview VST, not just any VST
  local vstStart = fxchain:find(RBN_PREVIEW_VST_ID, 1, true)
  if not vstStart then return nil, fxchain:match("\n%s*PRESETNAME[^\n]*") end
  local hdrEnd = fxchain:find("\n", vstStart) or (#fxchain + 1)
  local bodyStart = hdrEnd + 1
  local i, len = bodyStart, #fxchain
  while i <= len do
    local lineEnd = fxchain:find("\n", i) or (len + 1)
    local line = fxchain:sub(i, lineEnd - 1)
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    if line:match("^%s*>%s*$") then
      local body = fxchain:sub(bodyStart, i - 1)
      -- Find PRESETNAME that follows THIS VST block, not the first one in the chain
      local afterVst = fxchain:sub(lineEnd)
      local preset = afterVst:match("^%s*PRESETNAME[^\n]*") or afterVst:match("\n%s*PRESETNAME[^\n]*")
      return body, preset
    end
    i = lineEnd + 1
  end
  return nil, fxchain:match("\n%s*PRESETNAME[^\n]*")
end
function replace_vst_body_and_preset_in_fxchain(fxchain, newBody, newPreset)
  if not fxchain or not newBody then return fxchain end
  -- Search specifically for RBN Preview VST, not just any VST
  local vstStart = fxchain:find(RBN_PREVIEW_VST_ID, 1, true)
  if not vstStart then return fxchain end
  local hdrEnd = fxchain:find("\n", vstStart) or (#fxchain + 1)
  local bodyStart = hdrEnd + 1
  local i, len = bodyStart, #fxchain
  local endStart, endEnd
  while i <= len do
    local lineEnd = fxchain:find("\n", i) or (len + 1)
    local line = fxchain:sub(i, lineEnd - 1)
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    if line:match("^%s*>%s*$") then endStart, endEnd = i, lineEnd; break end
    i = lineEnd + 1
  end
  if not endStart then return fxchain end
  local newVST = fxchain:sub(vstStart, hdrEnd) .. newBody .. "\n" .. fxchain:sub(endStart, endEnd - 1)
  local fxNew = fxchain:sub(1, vstStart - 1) .. newVST .. fxchain:sub(endEnd)
  if newPreset and newPreset ~= "" then
    -- Find and replace PRESETNAME that follows the RBN Preview VST block
    local newVstEnd = vstStart + #newVST - 1
    local afterVstSection = fxNew:sub(newVstEnd)
    local presetMatch = afterVstSection:match("^(\n%s*PRESETNAME[^\n]*)")
    if presetMatch then
      -- Replace the PRESETNAME right after the VST block
      fxNew = fxNew:sub(1, newVstEnd) .. "\n    " .. newPreset .. afterVstSection:sub(#presetMatch + 1)
    else
      -- No PRESETNAME after VST, insert one
      local insertPos = newVstEnd + 1
      fxNew = fxNew:sub(1, insertPos - 1) .. "\n    " .. newPreset .. fxNew:sub(insertPos)
    end
  end
  return fxNew
end
function apply_custom_note_order(chunk, noteLine)
  if not noteLine or noteLine == "" then return chunk end
  if chunk:find("CUSTOM_NOTE_ORDER", 1, true) then
    return chunk:gsub("\n%s*CUSTOM_NOTE_ORDER[^\n]*", "\n"..noteLine, 1)
  elseif chunk:find("<MIDINOTENAMES", 1, true) then
    return chunk:gsub("(<MIDINOTENAMES)", noteLine.."\n%1", 1)
  else
    return chunk .. "\n" .. noteLine
  end
end

---------------------------------------
-- FXCHAIN + FLOAT helpers
---------------------------------------
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

-- Save/load global origin + size (X/Y/W/H)
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

-- geometry utilities
local SLOT_IDX = { DRUMS=0, BASS=1, GUITAR=2, KEYS=3 }

-- Prefer saved global X/Y/W/H; fall back to DRUMS chunk if needed; also backfill missing saves
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


function resolve_template_path(short)
  local RP = reaper.GetResourcePath()
  for _,p in ipairs({
    RP.."/TrackTemplates/"..short..".RTrackTemplate",
    RP.."/TrackTemplates/"..short,
    short..".RTrackTemplate",
    short
  }) do local f=io.open(p,"r"); if f then f:close(); return p end end
  return nil
end

