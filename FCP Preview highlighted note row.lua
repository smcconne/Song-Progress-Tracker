-- @description Background: hold ; (VK 0xB9) to preview MIDI editor pitch-caret row (no note created)
-- @version 4.4
-- @author FinestCardboardPearls
-- @about
--   Persistent background action. While VK 0xB9 is held, plays the active MIDI Editor’s pitch-caret row
--   through the editor track’s instrument using StuffMIDIMessage + VKB input routing.
--   Sends NoteOn on key-down edge and NoteOff on key-up. Restores track input/arm/monitor.
--   Press Esc to stop.

------------------------------------------------------------
-- settings
------------------------------------------------------------
local TRIG_VK   = 0xB9     -- hard-coded semicolon on this machine
local VK_ESC    = 0x1A
local VELOCITY  = 96
local SAFETY_MS = 15000

------------------------------------------------------------
-- requirements
------------------------------------------------------------
if not reaper.APIExists("JS_VKeys_GetState") then return end

------------------------------------------------------------
-- utils
------------------------------------------------------------
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end
local function now_ms() return reaper.time_precise() * 1000.0 end

------------------------------------------------------------
-- state
------------------------------------------------------------
local note_active, note_pitch, note_chan = false, 60, 0
local tgt_tr, orig_arm, orig_mon, orig_in = nil, nil, nil, nil
local started_ms = 0
local was_down = false

reaper.atexit(function()
  if note_active then reaper.StuffMIDIMessage(0, 0x80 + note_chan, note_pitch, 0) end
  if tgt_tr then
    reaper.PreventUIRefresh(1)
    if orig_arm ~= nil then reaper.SetMediaTrackInfo_Value(tgt_tr, "I_RECARM",   orig_arm) end
    if orig_mon ~= nil then reaper.SetMediaTrackInfo_Value(tgt_tr, "I_RECMON",   orig_mon) end
    if orig_in  ~= nil then reaper.SetMediaTrackInfo_Value(tgt_tr, "I_RECINPUT", orig_in)  end
    reaper.TrackList_AdjustWindows(false); reaper.UpdateArrange()
    reaper.PreventUIRefresh(-1)
  end
end)

------------------------------------------------------------
-- helpers
------------------------------------------------------------
local function begin_note_if_possible()
  local me = reaper.MIDIEditor_GetActive(); if not me then return end
  local take = reaper.MIDIEditor_GetTake(me); if not take then return end
  local tr   = reaper.GetMediaItemTake_Track(take); if not tr then return end

  local pitch = clamp(reaper.MIDIEditor_GetSetting_int(me, "active_note_row") or 60, 0, 127)
  local chan  = clamp(reaper.MIDIEditor_GetSetting_int(me, "default_note_chan") or 0, 0, 15)

  -- save and set input to VKB, arm + monitor
  orig_arm = reaper.GetMediaTrackInfo_Value(tr, "I_RECARM")
  orig_mon = reaper.GetMediaTrackInfo_Value(tr, "I_RECMON")
  orig_in  = reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT")

  local VKB_DEVICE, MIDI_FLAG, CH_ALL = 62, 4096, 0
  local recinput_vkb = MIDI_FLAG + CH_ALL + (VKB_DEVICE * 32)

  reaper.PreventUIRefresh(1)
  if orig_arm ~= 1 then reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1) end
  if orig_mon ~= 1 then reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1) end
  if math.floor(orig_in or 0) ~= recinput_vkb then
    reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", recinput_vkb)
  end
  reaper.TrackList_AdjustWindows(false); reaper.UpdateArrange()
  reaper.PreventUIRefresh(-1)

  reaper.StuffMIDIMessage(0, 0x90 + chan, pitch, VELOCITY)

  note_active, note_pitch, note_chan = true, pitch, chan
  tgt_tr = tr
  started_ms = now_ms()
end

local function end_note_and_restore()
  if note_active then
    reaper.StuffMIDIMessage(0, 0x80 + note_chan, note_pitch, 0)
    note_active = false
  end
  if tgt_tr then
    reaper.PreventUIRefresh(1)
    if orig_arm ~= nil then reaper.SetMediaTrackInfo_Value(tgt_tr, "I_RECARM",   orig_arm) end
    if orig_mon ~= nil then reaper.SetMediaTrackInfo_Value(tgt_tr, "I_RECMON",   orig_mon) end
    if orig_in  ~= nil then reaper.SetMediaTrackInfo_Value(tgt_tr, "I_RECINPUT", orig_in)  end
    reaper.TrackList_AdjustWindows(false); reaper.UpdateArrange()
    reaper.PreventUIRefresh(-1)
    tgt_tr, orig_arm, orig_mon, orig_in = nil, nil, nil, nil
  end
end

------------------------------------------------------------
-- loop
------------------------------------------------------------
reaper.JS_VKeys_Intercept(TRIG_VK, 1) -- suppress auto-repeats while running
reaper.JS_VKeys_Intercept(VK_ESC, 1)

local function loop()
  reaper.defer(loop)

  local buf = reaper.JS_VKeys_GetState(0) or string.rep("\0", 256)

  if buf:byte(VK_ESC + 1) == 1 then
    end_note_and_restore()
    return
  end

  local is_down = (buf:byte(TRIG_VK + 1) == 1)

  if is_down and not was_down and not note_active then
    begin_note_if_possible()
  elseif (not is_down) and was_down then
    end_note_and_restore()
  end

  if note_active and (now_ms() - started_ms) >= SAFETY_MS then
    end_note_and_restore()
  end

  was_down = is_down
end

loop()

