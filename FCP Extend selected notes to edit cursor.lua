--[[
  Lengthen selected notes to the edit cursor (Inline MIDI Editor)
  • Works on the active take (inline or floating), so no additional focus hacks
  • For each selected note whose end is before the edit cursor, set its end to the cursor
]]

-- 1) Get the first selected media item
local item = reaper.GetSelectedMediaItem(0, 0)
if not item then return end

-- 2) Get the take that’s currently active (inline editor’s take)
local take = reaper.GetActiveTake(item)
if not take or not reaper.TakeIsMIDI(take) then return end

-- 3) Begin undo block
reaper.Undo_BeginBlock()

-- 4) Compute cursor position in PPQ for this take
local cursorTime = reaper.GetCursorPosition()
local cursorPPQ  = reaper.MIDI_GetPPQPosFromProjTime(take, cursorTime)

-- 5) Iterate all notes and extend selected ones
local _, noteCount = reaper.MIDI_CountEvts(take)
for i = 0, noteCount-1 do
  local _, sel, muted, startPPQ, endPPQ, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
  if sel and endPPQ < cursorPPQ then
    reaper.MIDI_SetNote(take, i, sel, muted, startPPQ, cursorPPQ, chan, pitch, vel, false)
  end
end

-- 6) Re-sort and end undo
reaper.MIDI_Sort(take)
reaper.Undo_EndBlock("Lengthen notes to edit cursor", -1)

