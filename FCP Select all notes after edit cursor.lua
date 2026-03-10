-- @description Select all MIDI notes + lyric events except those before the edit cursor
-- @version 1.1

local me = reaper.MIDIEditor_GetActive()
if not me then return end

local take = reaper.MIDIEditor_GetTake(me)
if not take or not reaper.TakeIsMIDI(take) then return end

-- Edit-cursor time → PPQ
local cur_time = reaper.GetCursorPosition()
local cur_ppq  = reaper.MIDI_GetPPQPosFromProjTime(take, cur_time)

reaper.Undo_BeginBlock2(0)
reaper.MIDI_DisableSort(take)

-- Deselect everything
reaper.MIDI_SelectAll(take, false)

local _, noteCount, ccCount, textCount = reaper.MIDI_CountEvts(take)

------------------------------------------------------------
-- NOTES
------------------------------------------------------------
for i = 0, noteCount - 1 do
  local ok, sel, mute, s_ppq, e_ppq, ch, pitch, vel =
    reaper.MIDI_GetNote(take, i)
  if ok then
    local want = (s_ppq >= cur_ppq)
    if sel ~= want then
      reaper.MIDI_SetNote(take, i, want, mute, s_ppq, e_ppq, ch, pitch, vel, true)
    end
  end
end

------------------------------------------------------------
-- LYRIC EVENTS (Text/Sysex evtType = 5)
------------------------------------------------------------
for i = 0, textCount - 1 do
  local ok, sel, mute, ppqpos, evtType, msg =
    reaper.MIDI_GetTextSysexEvt(take, i)
  if ok and evtType == 5 then
    local want = (ppqpos >= cur_ppq)
    if sel ~= want then
      reaper.MIDI_SetTextSysexEvt(take, i, want, mute, ppqpos, evtType, msg, true)
    end
  end
end

reaper.MIDI_Sort(take)
reaper.Undo_EndBlock2(0, "Select notes + lyric events except those before edit cursor", -1)

