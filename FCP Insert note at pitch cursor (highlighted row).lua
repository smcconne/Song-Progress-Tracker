-- @description Insert note at edit cursor snapped-left to MIDI grid at pitch caret (vel=96, deselect first)
-- @version 1.3

local function main()
  local me = reaper.MIDIEditor_GetActive()
  if not me then return end
  local take = reaper.MIDIEditor_GetTake(me)
  if not take or not reaper.TakeIsMIDI(take) then return end

  -- Ensure default insert velocity is 96 for future manual inserts
  if reaper.APIExists("MIDIEditor_SetSetting_int") then
    reaper.MIDIEditor_SetSetting_int(me, "default_note_vel", 96)
  end

  local cur_time = reaper.GetCursorPosition()
  local cur_qn   = reaper.TimeMap2_timeToQN(0, cur_time)

  -- MIDI editor grid length (QN)
  local grid_qn = reaper.MIDI_GetGrid(take)
  if not grid_qn or grid_qn <= 0 then grid_qn = 0.25 end

  -- Left grid line at or before cursor
  local eps = 1e-12
  local left_qn  = math.floor((cur_qn + eps) / grid_qn) * grid_qn
  local right_qn = left_qn + grid_qn

  local left_time  = reaper.TimeMap2_QNToTime(0, left_qn)
  local right_time = reaper.TimeMap2_QNToTime(0, right_qn)

  local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(take, left_time)
  local ppq_end   = reaper.MIDI_GetPPQPosFromProjTime(take, right_time)

  -- Pitch caret row
  local pitch = reaper.MIDIEditor_GetSetting_int(me, "active_note_row") or 60
  if pitch < 0 or pitch > 127 then pitch = 60 end

  local chan = reaper.MIDIEditor_GetSetting_int(me, "default_note_chan") or 0
  if chan < 0 or chan > 15 then chan = 0 end
  local vel = 96

  reaper.Undo_BeginBlock2(0)
  reaper.PreventUIRefresh(1)
  reaper.MIDI_DisableSort(take)

  -- Deselect all MIDI events in this take
  reaper.MIDI_SelectAll(take, false)

  reaper.MIDI_InsertNote(take, true, false, ppq_start, ppq_end, chan, pitch, vel, true)

  reaper.MIDI_Sort(take)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock2(0, "Insert note at grid-left of edit cursor at pitch caret (vel=96, deselect first)", -1)
end

main()

