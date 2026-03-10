-- @description Step edit cursor LEFT via MIDI editor grid; else previous arrange grid; auto-stop scrub after 768ms; cancel on newer instance (no undo point)
-- @version 2.2
-- @noindex

local DURATION_MS = 384
local EXT_SECTION = "FCP_SCRUB_WATCH" -- shared between left/right to cancel older instances

local function start_auto_stop_scrub(token, ms)
  local t0 = reaper.time_precise()
  local function tick()
    if reaper.GetExtState(EXT_SECTION, "token") ~= token then return end
    if reaper.time_precise() - t0 >= (ms or 768) / 1000.0 then
      reaper.Main_OnCommand(41189, 0)
      return
    end
    reaper.defer(tick)
  end
  reaper.defer(tick)
end

reaper.PreventUIRefresh(1)

local hadME = false
local me = reaper.MIDIEditor_GetActive()

-- If a MIDI editor (non-inline) is open, use its grid step left
if me and reaper.MIDIEditor_GetTake(me) then
  reaper.MIDIEditor_OnCommand(me, 40047) -- Navigate: Move edit cursor left by grid
  hadME = true
end

-- Fallback: step to previous arrange grid line via SWS
if not hadME then
  local cur = reaper.GetCursorPosition()
  local prv = reaper.BR_GetPrevGridDivision(cur)
  if prv and prv < cur then
    reaper.SetEditCurPos(prv, true, false)
  end
end

-- If MIDI editor was open, enable scrub and start cancelable timer
if hadME then
  reaper.Main_OnCommand(41188, 0) -- Scrub: Enable looped-segment scrub at edit cursor
  local token = tostring(reaper.time_precise()) .. "-" .. tostring(math.random())
  reaper.SetExtState(EXT_SECTION, "token", token, false)
  start_auto_stop_scrub(token, DURATION_MS)
else
  reaper.defer(function() end) -- no undo point
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()

