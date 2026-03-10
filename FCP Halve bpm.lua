-- @description Cut-time convert: 4/4 -> 2/4 + halve BPM, preserve real-time for items, MIDI, envelopes
-- @version 1.0
-- @author you
-- @noindex

local proj = 0

----------------------------------------------------------------
-- helpers
----------------------------------------------------------------
local function clamp01(x) if x < 0 then return 0 elseif x > 1 then return 1 else return x end end

----------------------------------------------------------------
-- snapshot: items (start,len in seconds)
----------------------------------------------------------------
local function snapshot_items()
  local items = {}
  local ntr = reaper.CountTracks(proj)
  for ti = 0, ntr-1 do
    local tr = reaper.GetTrack(proj, ti)
    local ni = reaper.CountTrackMediaItems(tr)
    for ii = 0, ni-1 do
      local it = reaper.GetTrackMediaItem(tr, ii)
      local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      items[#items+1] = { it = it, pos = pos, len = len }
    end
  end
  return items
end

local function restore_items(items)
  for i = 1, #items do
    local e = items[i]
    if reaper.ValidatePtr2(proj, e.it, "MediaItem*") then
      reaper.SetMediaItemPosition(e.it, e.pos, false)
      reaper.SetMediaItemLength(e.it, e.len, false)
    end
  end
end

----------------------------------------------------------------
-- snapshot: envelopes (track envelopes + their automation items)
----------------------------------------------------------------
local function snapshot_envelopes()
  local envs = {}
  local ntr = reaper.CountTracks(proj)
  for ti = 0, ntr-1 do
    local tr = reaper.GetTrack(proj, ti)
    local ne = reaper.CountTrackEnvelopes(tr)
    for ei = 0, ne-1 do
      local env = reaper.GetTrackEnvelope(tr, ei)
      local pack = { env = env, base = {}, ai = {} }

      -- base lane points
      local pc = reaper.CountEnvelopePointsEx(env, -1)
      for pi = 0, pc-1 do
        local ok, time, val, shape, tens, sel = reaper.GetEnvelopePointEx(env, -1, pi)
        if ok then pack.base[#pack.base+1] = {t=time, v=val, s=shape, z=tens, sel=sel and true or false} end
      end

      -- automation items
      local aic = reaper.CountAutomationItems(env)
      for ai = 0, aic-1 do
        local list = {}
        local pic = reaper.CountEnvelopePointsEx(env, ai)
        for pi = 0, pic-1 do
          local ok, time, val, shape, tens, sel = reaper.GetEnvelopePointEx(env, ai, pi)
          if ok then list[#list+1] = {t=time, v=val, s=shape, z=tens, sel=sel and true or false} end
        end
        pack.ai[ai] = list
      end

      envs[#envs+1] = pack
    end
  end
  return envs
end

local function restore_envelopes(envs)
  for i = 1, #envs do
    local E = envs[i]
    local env = E.env
    if reaper.ValidatePtr2(proj, env, "TrackEnvelope*") then
      -- clear all points in wide range then reinsert
      reaper.DeleteEnvelopePointRangeEx(env, -1, -1e12, 1e12)
      for ai, list in pairs(E.ai) do
        reaper.DeleteEnvelopePointRangeEx(env, ai, -1e12, 1e12)
        for j = 1, #list do
          local p = list[j]
          reaper.InsertEnvelopePointEx(env, ai, p.t, p.v, p.s, p.z, p.sel, true)
        end
        reaper.Envelope_SortPointsEx(env, ai)
      end
      for j = 1, #E.base do
        local p = E.base[j]
        reaper.InsertEnvelopePointEx(env, -1, p.t, p.v, p.s, p.z, p.sel, true)
      end
      reaper.Envelope_SortPointsEx(env, -1)
    end
  end
end

----------------------------------------------------------------
-- snapshot: MIDI (absolute project-time for every note/cc/text)
----------------------------------------------------------------
local function snapshot_midi()
  local takes = {}
  local ntr = reaper.CountTracks(proj)
  for ti = 0, ntr-1 do
    local tr = reaper.GetTrack(proj, ti)
    local ni = reaper.CountTrackMediaItems(tr)
    for ii = 0, ni-1 do
      local it = reaper.GetTrackMediaItem(tr, ii)
      local nt = reaper.GetMediaItemNumTakes(it)
      for ki = 0, nt-1 do
        local tk = reaper.GetMediaItemTake(it, ki)
        if tk and reaper.TakeIsMIDI(tk) then
          reaper.MIDI_DisableSort(tk)
          local notes, ccs, texts = {}, {}, {}
          local _, nct, cct, txt = reaper.MIDI_CountEvts(tk)

          for n = 0, nct-1 do
            local ok, sel, mute, sPPQ, ePPQ, ch, p, v = reaper.MIDI_GetNote(tk, n)
            if ok then
              local st = reaper.MIDI_GetProjTimeFromPPQPos(tk, sPPQ)
              local et = reaper.MIDI_GetProjTimeFromPPQPos(tk, ePPQ)
              notes[#notes+1] = {idx=n, sel=sel, mute=mute, st=st, et=et, ch=ch, p=p, v=v}
            end
          end

          for c = 0, cct-1 do
            local ok, sel, mute, ppq, chanmsg, chan, msg2, msg3, shape, bez = reaper.MIDI_GetCC(tk, c)
            if ok then
              local t = reaper.MIDI_GetProjTimeFromPPQPos(tk, ppq)
              ccs[#ccs+1] = {idx=c, sel=sel, mute=mute, t=t, chanmsg=chanmsg, chan=chan, msg2=msg2, msg3=msg3, shape=shape, bez=bez}
            end
          end

          for x = 0, txt-1 do
            local ok, sel, mute, ppq, typ, msg = reaper.MIDI_GetTextSysexEvt(tk, x)
            if ok then
              local t = reaper.MIDI_GetProjTimeFromPPQPos(tk, ppq)
              texts[#texts+1] = {idx=x, sel=sel, mute=mute, t=t, typ=typ, msg=msg}
            end
          end

          reaper.MIDI_DisableSort(tk) -- keep set until restore
          takes[#takes+1] = { tk=tk, notes=notes, ccs=ccs, texts=texts }
        end
      end
    end
  end
  return takes
end

local function restore_midi(takes)
  for i = 1, #takes do
    local T = takes[i]
    local tk = T.tk
    if reaper.ValidatePtr2(proj, tk, "MediaItem_Take*") then
      -- notes
      for j = 1, #T.notes do
        local n = T.notes[j]
        local sPPQ = reaper.MIDI_GetPPQPosFromProjTime(tk, n.st)
        local ePPQ = reaper.MIDI_GetPPQPosFromProjTime(tk, n.et)
        reaper.MIDI_SetNote(tk, n.idx, n.sel, n.mute, sPPQ, ePPQ, n.ch, n.p, n.v, true)
      end
      -- CC
      for j = 1, #T.ccs do
        local c = T.ccs[j]
        local ppq = reaper.MIDI_GetPPQPosFromProjTime(tk, c.t)
        reaper.MIDI_SetCC(tk, c.idx, c.sel, c.mute, ppq, c.chanmsg, c.chan, c.msg2, c.msg3, true)
        if c.shape then
          reaper.MIDI_SetCCShape(tk, c.idx, c.shape, c.bez or 0, true)
        end
      end
      -- Text/Sysex
      for j = 1, #T.texts do
        local x = T.texts[j]
        local ppq = reaper.MIDI_GetPPQPosFromProjTime(tk, x.t)
        reaper.MIDI_SetTextSysexEvt(tk, x.idx, x.sel, x.mute, ppq, x.typ, x.msg, true)
      end
      reaper.MIDI_Sort(tk)
    end
  end
end

----------------------------------------------------------------
-- tempo-map transform: 4/4 -> 2/4 and BPM -> BPM/2 (only when top number of time signature is even)
----------------------------------------------------------------
-- Make project start 4/4, keep later TS changes as-is, halve BPM everywhere
local function transform_tempo_map()
  local n = reaper.CountTempoTimeSigMarkers(proj)

  -- Effective start tempo and linear flag
  local tempo0 = reaper.Master_GetTempo()
  local zero_linear = false
  for i = 0, n-1 do
    local ok, t, _, _, bpm, _, _, lin = reaper.GetTempoTimeSigMarker(proj, i)
    if ok and math.abs(t) < 1e-12 then
      tempo0 = bpm or tempo0
      zero_linear = lin and true or false
      break
    end
  end

  -- Snapshot all markers
  local marks = {}
  for i = 0, n-1 do
    local ok, t, _, _, bpm, num, den, lin = reaper.GetTempoTimeSigMarker(proj, i)
    if ok then
      marks[#marks+1] = {t=t, bpm=bpm or tempo0, num=num or 0, den=den or 0, linear=lin and true or false}
    end
  end

  -- Rebuild from scratch
  for i = n-1, 0, -1 do reaper.DeleteTempoTimeSigMarker(proj, i) end

  -- 1.1.00: explicitly 4/4 at half BPM
  reaper.SetTempoTimeSigMarker(proj, -1, 0.0, -1, -1, (tempo0 * 0.5), 4, 4, zero_linear)

  -- Rest: halve BPM, preserve TS explicitness as-is
  table.sort(marks, function(a,b) return a.t < b.t end)
  for _, m in ipairs(marks) do
    if m.t > 1e-12 then
      local out_bpm = m.bpm * 0.5
      if m.num == 0 and m.den == 0 then
        -- tempo-only marker remains tempo-only
        reaper.SetTempoTimeSigMarker(proj, -1, m.t, -1, -1, out_bpm, 0, 0, m.linear)
      else
        -- explicit TS change preserved
        reaper.SetTempoTimeSigMarker(proj, -1, m.t, -1, -1, out_bpm, m.num, m.den, m.linear)
      end
    end
  end
end

----------------------------------------------------------------
-- main
----------------------------------------------------------------
reaper.Undo_BeginBlock2(proj)
reaper.PreventUIRefresh(1)

-- snapshot world
local items   = snapshot_items()
local envs    = snapshot_envelopes()
local midis   = snapshot_midi()

-- change tempo map (cut time)
transform_tempo_map()

-- force items back to same seconds
restore_items(items)

-- re-time MIDI content to same seconds under new tempo map
restore_midi(midis)

-- ensure envelopes stay at same seconds
restore_envelopes(envs)

reaper.UpdateArrange()
reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock2(proj, "Cut-time: 4/4 -> 2/4 and halve BPM (preserve real time)", -1)

