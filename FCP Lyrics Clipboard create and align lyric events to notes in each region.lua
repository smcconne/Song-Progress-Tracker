-- @description Lyrics Clipboard: create and align lyric events to notes in each region
-- @version 2.20
-- @author FinestCardboardPearls
-- @about
--   • Run in the Main context on a selected track’s first MIDI item.  
--   • Paste/type lyrics; each new MIDI note grabs the next word as a Lyric event and leaves the note in place.  
--   • **+** prepends “+ ”.  
--   • **Undo** removes the last-inserted Lyric event *and* deletes its associated note, restoring the word.  
--   • **Close** stops and saves remaining lyrics per-project.

local reaper = reaper

-------------------------------------------------------------------------------
-- 0) FETCH THE TARGET TAKE
-------------------------------------------------------------------------------
local tr = reaper.GetSelectedTrack(0,0)
if not tr then reaper.ShowMessageBox("Please select a track.","Error",0) return end
local item = reaper.GetTrackMediaItem(tr,0)
if not item then reaper.ShowMessageBox("No media item on selected track.","Error",0) return end
local take = reaper.GetActiveTake(item)
if not (take and reaper.TakeIsMIDI(take)) then
  reaper.ShowMessageBox("First media item has no MIDI take.","Error",0)
  return
end

-------------------------------------------------------------------------------
-- 1) LOAD & PARSE SAVED LYRICS (per-region)
-------------------------------------------------------------------------------
local proj = reaper.EnumProjects(-1)

-- Table to store lyrics per region (keyed by region marker index)
local regionLyrics = {}
local lyrics = ""  -- current displayed lyrics
local currentRegionKey = nil  -- track which region's lyrics are loaded
local words = {}

local function parseWords()
  words = {}
  for w in lyrics:gmatch("%S+") do words[#words+1]=w end
end

-- Load all region lyrics from project
local function loadAllRegionLyrics()
  regionLyrics = {}
  local _, jsonStr = reaper.GetProjExtState(proj, "LyricsToMIDI", "regionLyrics")
  if _ == 1 and jsonStr ~= "" then
    -- Simple parsing: format is "idx1:lyrics1||idx2:lyrics2||..."
    for entry in jsonStr:gmatch("([^|]+)") do
      local idx, lyr = entry:match("^(%d+):(.*)$")
      if idx then
        regionLyrics[tonumber(idx)] = lyr or ""
      end
    end
  end
end

-- Save all region lyrics to project
local function saveAllRegionLyrics()
  -- First save current region's lyrics
  if currentRegionKey then
    regionLyrics[currentRegionKey] = lyrics
  end
  -- Serialize to string
  local parts = {}
  for idx, lyr in pairs(regionLyrics) do
    -- Replace | with a placeholder to avoid breaking our format
    local safeLyr = lyr:gsub("|", "\1")
    parts[#parts+1] = tostring(idx) .. ":" .. safeLyr
  end
  local jsonStr = table.concat(parts, "|")
  reaper.SetProjExtState(proj, "LyricsToMIDI", "regionLyrics", jsonStr)
end

-- Load lyrics for a specific region
local function loadLyricsForRegion(regionIdx)
  -- Save current region's lyrics first
  if currentRegionKey then
    regionLyrics[currentRegionKey] = lyrics
  end
  -- Load new region's lyrics
  currentRegionKey = regionIdx
  if regionIdx and regionLyrics[regionIdx] then
    lyrics = regionLyrics[regionIdx]:gsub("\1", "|")
  else
    lyrics = ""
  end
  parseWords()
end

loadAllRegionLyrics()
parseWords()

-------------------------------------------------------------------------------
-- 2) REMEMBER EXISTING NOTES + UNDO STACK
-------------------------------------------------------------------------------
local seenPPQs = {}
reaper.MIDI_Sort(take)
do
  local _, noteCnt = reaper.MIDI_CountEvts(take)
  for i=0,noteCnt-1 do
    local _,_,_,sp = reaper.MIDI_GetNote(take,i)
    seenPPQs[sp] = true
  end
end

-- undo_stack holds { word=..., ppq=... }
local undo_stack = {}

-- region selection
local regions = {}
local selectedRegionIdx = 0  -- 0 = no region selected
local userSelectedRegion = false  -- track if user manually selected

local function refreshRegions()
  regions = {}
  local _, num_markers, num_regions = reaper.CountProjectMarkers(proj)
  local idx = 0
  while true do
    local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers(idx)
    if retval == 0 then break end
    if isrgn then
      regions[#regions+1] = {
        idx = markrgnindexnumber,
        name = name ~= "" and name or ("Region " .. markrgnindexnumber),
        start_pos = pos,
        end_pos = rgnend
      }
    end
    idx = idx + 1
  end
end
refreshRegions()

local function findRegionAtCursor()
  local cursorPos = reaper.GetCursorPosition()
  for i, rgn in ipairs(regions) do
    if cursorPos >= rgn.start_pos and cursorPos < rgn.end_pos then
      return i
    end
  end
  return 0
end

local function updateRegionFromCursor()
  local newIdx = findRegionAtCursor()
  if newIdx ~= selectedRegionIdx then
    local oldIdx = selectedRegionIdx
    selectedRegionIdx = newIdx
    -- Load lyrics for new region (saves old region's lyrics automatically)
    local regionKey = newIdx > 0 and regions[newIdx].idx or nil
    local oldRegionKey = oldIdx > 0 and regions[oldIdx] and regions[oldIdx].idx or nil
    if regionKey ~= currentRegionKey then
      if currentRegionKey then
        regionLyrics[currentRegionKey] = lyrics
      end
      loadLyricsForRegion(regionKey)
    end
  end
end

-------------------------------------------------------------------------------
-- 3) NEW-NOTE DETECTION & LYRIC INSERTION (no auto-deletion)
-------------------------------------------------------------------------------

-- Apply all lyrics from textbox to existing notes in current region
local function applyLyricsToRegion()
  if selectedRegionIdx == 0 or not regions[selectedRegionIdx] then
    reaper.ShowMessageBox("No region selected.", "Error", 0)
    return
  end
  if #words == 0 then return end
  
  local rgn = regions[selectedRegionIdx]
  local startPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, rgn.start_pos)
  local endPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, rgn.end_pos)
  
  -- Delete existing lyric events in this region
  reaper.MIDI_Sort(take)
  local _, _, _, txtCnt = reaper.MIDI_CountEvts(take)
  for ti = txtCnt - 1, 0, -1 do
    local _, _, _, ppqpos, evtType, _ = reaper.MIDI_GetTextSysexEvt(take, ti)
    if evtType == 5 and ppqpos >= startPPQ and ppqpos < endPPQ then
      reaper.MIDI_DeleteTextSysexEvt(take, ti)
    end
  end
  
  -- Collect all notes in this region, sorted by PPQ
  reaper.MIDI_Sort(take)
  local _, noteCnt = reaper.MIDI_CountEvts(take)
  local notesInRegion = {}
  for i = 0, noteCnt - 1 do
    local _, _, _, sp = reaper.MIDI_GetNote(take, i)
    if sp >= startPPQ and sp < endPPQ then
      notesInRegion[#notesInRegion + 1] = sp
    end
  end
  table.sort(notesInRegion)
  
  -- Remove duplicate PPQs (multiple notes at same position)
  local uniquePPQs = {}
  local lastPPQ = nil
  for _, ppq in ipairs(notesInRegion) do
    if ppq ~= lastPPQ then
      uniquePPQs[#uniquePPQs + 1] = ppq
      lastPPQ = ppq
    end
  end
  
  if #uniquePPQs == 0 then return end
  
  -- Apply lyrics to notes (stop when we run out of either)
  local count = math.min(#words, #uniquePPQs)
  for i = 1, count do
    reaper.MIDI_InsertTextSysexEvt(take, false, false, uniquePPQs[i], 5, words[i])
    -- Mark PPQ as seen so auto-detect doesn't re-process
    seenPPQs[uniquePPQs[i]] = true
  end
end

local function updateMidi()
  reaper.MIDI_Sort(take)
  local _, noteCnt = reaper.MIDI_CountEvts(take)
  local newPPQs = {}

  for i=0,noteCnt-1 do
    local _,_,_,sp = reaper.MIDI_GetNote(take,i)
    if not seenPPQs[sp] then
      seenPPQs[sp] = true
      newPPQs[#newPPQs+1] = sp
    end
  end

  if #newPPQs == 0 then return end
  table.sort(newPPQs)
  for _, sp in ipairs(newPPQs) do
    if words[1] then
      -- insert lyric event
      reaper.MIDI_InsertTextSysexEvt(take,false,false,sp,5,words[1])
      -- push onto undo stack (including region key)
      undo_stack[#undo_stack+1] = { word = words[1], ppq = sp, regionKey = currentRegionKey }
      -- remove from textbox
      lyrics = lyrics:gsub("^%s*%S+%s*","")
      if currentRegionKey then regionLyrics[currentRegionKey] = lyrics end
      parseWords()
    end
  end
end

-------------------------------------------------------------------------------
-- 4) ImGui SETUP & PERSISTENCE
-------------------------------------------------------------------------------
local ctx     = reaper.ImGui_CreateContext("LyricsToMIDI")
local running = true
local BUF_SZ  = 16*1024

-- EEL callback to track cursor position
local inputCallback = reaper.ImGui_CreateFunctionFromEEL([[
  cursor_pos = CursorPos;
]])
reaper.ImGui_Attach(ctx, inputCallback)

local textboxFocusedThisFrame = false     -- current frame's focus state
local textboxHadFocusRecently = false     -- persists until + button uses it
local savedCursorPos = 0                  -- cursor position saved when textbox loses focus

-- Allowed track names for Apply mode
local APPLY_ALLOWED_TRACKS = {
  ["PART VOCALS"] = true, ["PART HARM1"] = true, ["PART HARM2"] = true, ["PART HARM3"] = true,
  ["HARM1"] = true, ["HARM2"] = true, ["HARM3"] = true,
}

local function isTrackAllowedForApply()
  local tr = reaper.GetSelectedTrack(0, 0)
  if not tr then return false end
  local _, name = reaper.GetTrackName(tr)
  return APPLY_ALLOWED_TRACKS[name] == true
end

-- Apply Lyrics toggle state
local applyLyricsEnabled = false
local lastAppliedLyrics = nil
local lastAppliedRegionKey = nil
local lastAppliedNotePPQs = nil  -- track note positions for change detection
local pendingApplyTime = nil     -- debounce: timestamp when change was detected
local APPLY_DEBOUNCE = 0.3       -- seconds to wait after last change before applying
local lastNoteCheckTime = 0      -- throttle note position checks
local NOTE_CHECK_INTERVAL = 0.2  -- only check note positions every N seconds

-- Get a string representation of note positions in current region (for change detection)
-- NOTE: Does NOT call MIDI_Sort to avoid interfering with MIDI editor drag operations
local function getRegionNotePPQsString()
  if selectedRegionIdx == 0 or not regions[selectedRegionIdx] then return "" end
  local rgn = regions[selectedRegionIdx]
  local startPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, rgn.start_pos)
  local endPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, rgn.end_pos)
  
  -- Don't call MIDI_Sort here - it interferes with note dragging
  local _, noteCnt = reaper.MIDI_CountEvts(take)
  local ppqs = {}
  for i = 0, noteCnt - 1 do
    local _, _, _, sp = reaper.MIDI_GetNote(take, i)
    if sp >= startPPQ and sp < endPPQ then
      ppqs[#ppqs + 1] = sp
    end
  end
  table.sort(ppqs)  -- sort in Lua instead
  -- convert to string
  for i = 1, #ppqs do ppqs[i] = tostring(ppqs[i]) end
  return table.concat(ppqs, ",")
end

-- Refresh take from currently selected track (in case user changed selection)
local function refreshTake()
  local tr = reaper.GetSelectedTrack(0, 0)
  if not tr then return end
  local item = reaper.GetTrackMediaItem(tr, 0)
  if not item then return end
  local newTake = reaper.GetActiveTake(item)
  if not (newTake and reaper.TakeIsMIDI(newTake)) then return end
  if newTake ~= take then
    take = newTake
    -- Track changed: turn off Apply mode
    if applyLyricsEnabled then
      applyLyricsEnabled = false
      pendingApplyTime = nil
    end
    -- Refresh seenPPQs for new take
    seenPPQs = {}
    reaper.MIDI_Sort(take)
    local _, noteCnt = reaper.MIDI_CountEvts(take)
    for i = 0, noteCnt - 1 do
      local _, _, _, sp = reaper.MIDI_GetNote(take, i)
      seenPPQs[sp] = true
    end
  end
end

reaper.atexit(function() end)

-------------------------------------------------------------------------------
-- 5) MAIN UI + LOOP (Undo now removes both lyric *and* note)
-------------------------------------------------------------------------------
local function loop()
  refreshTake()
  reaper.ImGui_SetNextWindowSize(ctx,600,400,reaper.ImGui_Cond_FirstUseEver())
  local pad = 9
  reaper.ImGui_PushStyleVar(ctx,reaper.ImGui_StyleVar_WindowPadding(),pad,pad)
  reaper.ImGui_PushStyleVar(ctx,reaper.ImGui_StyleVar_ItemSpacing(),pad,pad)

  local flags = reaper.ImGui_WindowFlags_NoCollapse()
  local vis   = reaper.ImGui_Begin(ctx,"Lyrics Clipboard",nil,flags)
  if vis then
    -- [+]
    if reaper.ImGui_Button(ctx,"+",40,0) then
      if textboxHadFocusRecently then
        -- Textbox had focus recently: use saved cursor position
        local cursorPos = savedCursorPos
        textboxHadFocusRecently = false  -- consume the flag
        
        -- Special case: cursor at or past end of text, just append
        if cursorPos >= #lyrics then
          lyrics = lyrics .. " +"
        else
          -- Find word boundaries around cursor
          local wordStart, wordEnd = cursorPos, cursorPos
          -- Find start of word (search backwards for whitespace)
          while wordStart > 0 and not lyrics:sub(wordStart, wordStart):match("%s") do
            wordStart = wordStart - 1
          end
          -- Find end of word (search forwards for whitespace)
          while wordEnd < #lyrics and not lyrics:sub(wordEnd + 1, wordEnd + 1):match("%s") do
            wordEnd = wordEnd + 1
          end
          
          local wordLen = wordEnd - wordStart
          local cursorInWord = cursorPos - wordStart
          
          if wordLen > 0 and cursorInWord >= wordLen / 2 then
            -- Cursor at or past halfway: append ` +` after the word
            local before = lyrics:sub(1, wordEnd)
            local after = lyrics:sub(wordEnd + 1)
            lyrics = before .. " +" .. after
          else
            -- Cursor before halfway: prepend `+ ` before the word
            local before = lyrics:sub(1, wordStart)
            local after = lyrics:sub(wordStart + 1)
            lyrics = before .. "+ " .. after
          end
        end
      else
        -- Textbox not focused: find note nearest to edit cursor and insert + before that word
        if selectedRegionIdx > 0 and regions[selectedRegionIdx] then
          local rgn = regions[selectedRegionIdx]
          local startPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, rgn.start_pos)
          local endPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, rgn.end_pos)
          local cursorTime = reaper.GetCursorPosition()
          local cursorPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, cursorTime)
          
          -- Get all notes in region sorted by PPQ
          reaper.MIDI_Sort(take)
          local _, noteCnt = reaper.MIDI_CountEvts(take)
          local notesInRegion = {}
          for i = 0, noteCnt - 1 do
            local _, _, _, sp = reaper.MIDI_GetNote(take, i)
            if sp >= startPPQ and sp < endPPQ then
              notesInRegion[#notesInRegion + 1] = sp
            end
          end
          table.sort(notesInRegion)
          
          -- Remove duplicates
          local uniquePPQs = {}
          local lastPPQ = nil
          for _, ppq in ipairs(notesInRegion) do
            if ppq ~= lastPPQ then
              uniquePPQs[#uniquePPQs + 1] = ppq
              lastPPQ = ppq
            end
          end
          
          -- Find nearest note to cursor
          local nearestIdx = 1
          local nearestDist = math.huge
          for i, ppq in ipairs(uniquePPQs) do
            local dist = math.abs(ppq - cursorPPQ)
            if dist < nearestDist then
              nearestDist = dist
              nearestIdx = i
            end
          end
          
          -- Insert + before the word at nearestIdx position
          if nearestIdx > 0 and #words >= nearestIdx then
            -- Find the character position of word nearestIdx
            local charPos = 0
            local wordCount = 0
            for w in lyrics:gmatch("%S+") do
              wordCount = wordCount + 1
              if wordCount == nearestIdx then
                break
              end
              -- Find this word in lyrics and skip past it
              local wStart, wEnd = lyrics:find("%S+", charPos + 1)
              if wEnd then charPos = wEnd end
            end
            -- Find the start of the target word
            local wStart = lyrics:find("%S", charPos + 1) or (#lyrics + 1)
            local before = lyrics:sub(1, wStart - 1)
            local after = lyrics:sub(wStart)
            lyrics = before .. "+ " .. after
          else
            -- No matching word, prepend
            lyrics = "+ " .. lyrics
          end
        else
          -- No region selected, just prepend
          lyrics = "+ " .. lyrics
        end
      end
      
      parseWords()
      if currentRegionKey then regionLyrics[currentRegionKey] = lyrics end
    end

    -- [Save]
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx,"Save",40,0) then
      saveAllRegionLyrics()
    end

    -- [Clip Lyric Events] - read all lyric events from current region
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx,"Clip Lyric Events",100,0) then
      if selectedRegionIdx > 0 and regions[selectedRegionIdx] then
        local rgn = regions[selectedRegionIdx]
        local startPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, rgn.start_pos)
        local endPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, rgn.end_pos)
        
        -- Collect all lyric events in this region
        reaper.MIDI_Sort(take)
        local _, _, _, txtCnt = reaper.MIDI_CountEvts(take)
        local lyricEvents = {}
        for ti = 0, txtCnt - 1 do
          local _, sel, mut, ppqpos, evtType, msg = reaper.MIDI_GetTextSysexEvt(take, ti)
          if evtType == 5 and ppqpos >= startPPQ and ppqpos < endPPQ then
            lyricEvents[#lyricEvents + 1] = { ppq = ppqpos, word = msg }
          end
        end
        
        -- Sort by PPQ position and concatenate
        table.sort(lyricEvents, function(a, b) return a.ppq < b.ppq end)
        local words_list = {}
        for _, evt in ipairs(lyricEvents) do
          words_list[#words_list + 1] = evt.word
        end
        
        -- Replace textbox contents
        lyrics = table.concat(words_list, " ")
        lyrics = lyrics:gsub("(.)@", "%1\n@")  -- Add newline before each @ symbol (except first)
        parseWords()
        if currentRegionKey then regionLyrics[currentRegionKey] = lyrics end
      end
    end

    -- Region dropdown (auto-updates from cursor position)
    refreshRegions()
    updateRegionFromCursor()
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 100)
    local previewLabel = selectedRegionIdx == 0 and "Region..." or (regions[selectedRegionIdx] and regions[selectedRegionIdx].name or "Region...")
    if reaper.ImGui_BeginCombo(ctx, "##regionCombo", previewLabel) then
      if reaper.ImGui_Selectable(ctx, "(None)", selectedRegionIdx == 0) then
        selectedRegionIdx = 0
        loadLyricsForRegion(nil)
      end
      for i, rgn in ipairs(regions) do
        local isSelected = (selectedRegionIdx == i)
        if reaper.ImGui_Selectable(ctx, rgn.name, isSelected) then
          selectedRegionIdx = i
          -- Move cursor to selected region
          reaper.SetEditCurPos(rgn.start_pos, true, false)
          -- Load lyrics for this region
          loadLyricsForRegion(rgn.idx)
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end

    -- [Apply Lyrics] Toggle
    local win_w,_ = reaper.ImGui_GetWindowSize(ctx)
    reaper.ImGui_SameLine(ctx,win_w-150-pad)
    -- Style the button differently when toggle is active
    local wasEnabled = applyLyricsEnabled  -- track state before button click
    if wasEnabled then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x4488FFFF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x66AAFFFF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x3377EEFF)
    end
    if reaper.ImGui_Button(ctx, applyLyricsEnabled and "Apply ON" or "Apply OFF", 80, 0) then
      if not applyLyricsEnabled and not isTrackAllowedForApply() then
        -- Don't enable if track is not allowed
      else
        applyLyricsEnabled = not applyLyricsEnabled
      end
      if applyLyricsEnabled then
        -- Initialize change tracking state
        lastAppliedLyrics = lyrics
        lastAppliedRegionKey = currentRegionKey
        lastAppliedNotePPQs = getRegionNotePPQsString()
        pendingApplyTime = nil  -- clear any pending debounce
        -- Apply immediately on enable
        applyLyricsToRegion()
      end
    end
    if wasEnabled then
      reaper.ImGui_PopStyleColor(ctx, 3)
    end

    -- [Close]
    reaper.ImGui_SameLine(ctx,win_w-60-pad)
    if reaper.ImGui_Button(ctx,"Close",60,0) then running=false end

    -- === SECOND ROW OF BUTTONS ===
    
    -- [Prev Note]
    if reaper.ImGui_Button(ctx, "Prev Note", 60, 0) then
      local cursorTime = reaper.GetCursorPosition()
      local cursorPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, cursorTime)
      reaper.MIDI_Sort(take)
      local _, noteCnt = reaper.MIDI_CountEvts(take)
      local prevPPQ = nil
      for i = 0, noteCnt - 1 do
        local _, _, _, sp = reaper.MIDI_GetNote(take, i)
        if sp < cursorPPQ then
          if not prevPPQ or sp > prevPPQ then
            prevPPQ = sp
          end
        end
      end
      if prevPPQ then
        local newTime = reaper.MIDI_GetProjTimeFromPPQPos(take, prevPPQ)
        reaper.SetEditCurPos(newTime, true, false)
      end
    end

    -- [Next Note]
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Next Note", 60, 0) then
      local cursorTime = reaper.GetCursorPosition()
      local cursorPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, cursorTime)
      reaper.MIDI_Sort(take)
      local _, noteCnt = reaper.MIDI_CountEvts(take)
      local nextPPQ = nil
      for i = 0, noteCnt - 1 do
        local _, _, _, sp = reaper.MIDI_GetNote(take, i)
        if sp > cursorPPQ then
          if not nextPPQ or sp < nextPPQ then
            nextPPQ = sp
          end
        end
      end
      if nextPPQ then
        local newTime = reaper.MIDI_GetProjTimeFromPPQPos(take, nextPPQ)
        reaper.SetEditCurPos(newTime, true, false)
      end
    end

    -- [Undo]
    reaper.ImGui_SameLine(ctx)
    if #undo_stack>0 and reaper.ImGui_Button(ctx,"Undo",60,0) then
      local e = table.remove(undo_stack)
      -- restore word to the correct region
      if e.regionKey == currentRegionKey then
        lyrics = e.word.." "..lyrics; parseWords()
        if currentRegionKey then regionLyrics[currentRegionKey] = lyrics end
      elseif e.regionKey then
        -- restore to a different region
        local oldLyr = regionLyrics[e.regionKey] or ""
        regionLyrics[e.regionKey] = e.word.." "..oldLyr
      end
      -- delete lyric event
      reaper.MIDI_Sort(take)
      local _,_,_, txtCnt = reaper.MIDI_CountEvts(take)
      for ti=txtCnt-1,0,-1 do
        local _, sel, mut, ppqpos, evtType, msg =
          reaper.MIDI_GetTextSysexEvt(take, ti)
        if evtType==5 and ppqpos==e.ppq and msg==e.word then
          reaper.MIDI_DeleteTextSysexEvt(take, ti)
          break
        end
      end
      -- delete note
      reaper.MIDI_Sort(take)
      local _, noteCnt2 = reaper.MIDI_CountEvts(take)
      for ni=noteCnt2-1,0,-1 do
        local _, _, _, sp2 = reaper.MIDI_GetNote(take, ni)
        if sp2==e.ppq then
          reaper.MIDI_DeleteNote(take, ni)
          break
        end
      end
      -- allow that PPQ for new notes
      seenPPQs[e.ppq] = nil
    end

    -- multiline textbox (updated for newer ReaImGui)
    local w, h = reaper.ImGui_GetContentRegionAvail(ctx)
    local textFlags = reaper.ImGui_InputTextFlags_AllowTabInput() | reaper.ImGui_InputTextFlags_CallbackAlways()
    local ch, newB = reaper.ImGui_InputTextMultiline(
      ctx, "##lyrics", lyrics, BUF_SZ,
      w, h, textFlags, inputCallback
    )
    if ch then
      lyrics = newB
      parseWords()
      if currentRegionKey then regionLyrics[currentRegionKey] = lyrics end
    end
    
    -- Track textbox focus and cursor position for the + button logic
    -- Use IsItemFocused (keyboard focus) OR IsItemActive (being interacted with)
    local wasFocused = textboxFocusedThisFrame
    textboxFocusedThisFrame = reaper.ImGui_IsItemFocused(ctx) or reaper.ImGui_IsItemActive(ctx)
    
    if textboxFocusedThisFrame then
      -- Textbox is focused - continuously update cursor position and set flag
      savedCursorPos = math.floor(reaper.ImGui_Function_GetValue(inputCallback, 'cursor_pos') or 0)
      textboxHadFocusRecently = true
    end
    -- When focus is lost, textboxHadFocusRecently stays true until + button consumes it
    
    -- Auto-apply lyrics when toggle is enabled and changes detected (with debounce)
    if applyLyricsEnabled then
      -- Check lyrics/region changes immediately, but throttle note position checks
      local lyricsChanged = (lyrics ~= lastAppliedLyrics) or (currentRegionKey ~= lastAppliedRegionKey)
      local noteChanged = false
      
      local now = reaper.time_precise()
      if now - lastNoteCheckTime >= NOTE_CHECK_INTERVAL then
        lastNoteCheckTime = now
        local currentNotePPQs = getRegionNotePPQsString()
        if currentNotePPQs ~= lastAppliedNotePPQs then
          noteChanged = true
          lastAppliedNotePPQs = currentNotePPQs
        end
      end
      
      if lyricsChanged or noteChanged then
        -- Change detected, start/reset debounce timer
        pendingApplyTime = reaper.time_precise()
        lastAppliedLyrics = lyrics
        lastAppliedRegionKey = currentRegionKey
      elseif pendingApplyTime then
        -- No change this frame, but we have a pending apply - check if debounce expired
        if reaper.time_precise() - pendingApplyTime >= APPLY_DEBOUNCE then
          applyLyricsToRegion()
          lastAppliedNotePPQs = getRegionNotePPQsString()  -- re-read after apply
          pendingApplyTime = nil
        end
      end
    end
    
  end

  reaper.ImGui_End(ctx)
  reaper.ImGui_PopStyleVar(ctx,2)

  if not running then return end
  reaper.defer(loop)
end

loop()
