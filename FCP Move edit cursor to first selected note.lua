-- @description Move edit cursor to first selected note
-- @version 1.0.0
-- @author FinestCardboardPearls

local function main()
  local me = reaper.MIDIEditor_GetActive()
  if not me then
    reaper.ShowMessageBox("No active MIDI editor.", "Error", 0)
    return
  end
  
  local take = reaper.MIDIEditor_GetTake(me)
  if not take or not reaper.ValidatePtr(take, "MediaItem_Take*") then
    reaper.ShowMessageBox("No valid take in MIDI editor.", "Error", 0)
    return
  end
  
  -- Find the first selected note (earliest start time)
  local _, note_count = reaper.MIDI_CountEvts(take)
  local first_ppq = nil
  
  for i = 0, note_count - 1 do
    local retval, selected, _, startppq = reaper.MIDI_GetNote(take, i)
    if retval and selected then
      if not first_ppq or startppq < first_ppq then
        first_ppq = startppq
      end
    end
  end
  
  if not first_ppq then
    reaper.ShowMessageBox("No notes selected.", "Error", 0)
    return
  end
  
  -- Convert PPQ to project time
  local target_time = reaper.MIDI_GetProjTimeFromPPQPos(take, first_ppq)
  
  -- Move edit cursor to that position
  reaper.SetEditCurPos(target_time, false, false)
  
  -- Scroll MIDI editor to edit cursor (action 40151: View: Go to edit cursor)
  reaper.MIDIEditor_OnCommand(me, 40151)
  
  -- Also scroll arrange view to edit cursor
  local start_time, end_time = reaper.GetSet_ArrangeView2(0, false, 0, 0)
  local view_length = end_time - start_time
  local new_start = target_time - (view_length * 0.1)  -- Position cursor at 10% from left
  if new_start < 0 then new_start = 0 end
  reaper.GetSet_ArrangeView2(0, true, 0, 0, new_start, new_start + view_length)
end

reaper.Undo_BeginBlock()
main()
reaper.Undo_EndBlock("Move edit cursor to first selected note", -1)