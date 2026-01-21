-- fcp_tracker_chunk_parse.lua
-- Split from Switch RBN Previews Driver (background).lua

-- RBN Preview VST identifier for searching in chunks
local RBN_PREVIEW_VST_ID = '<VST "VSTi: RBN Preview (RBN)"'

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
    -- We need to find the PRESETNAME right after the VST's closing >
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

