-- fcp_tracker_model_build_progress.lua
-- MIDI-take -> STATE tree computation for the Song Progress Tracker.
-- Split out of fcp_tracker_model.lua.

local reaper = reaper
local ImGui  = reaper

function make_sig_for_take(take)
  if not take then return "nil" end
  local _, note_cnt = reaper.MIDI_CountEvts(take)
  local sum = 0
  for ni = 0, note_cnt-1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(take, ni)
    if ok and pitch>=36 and pitch<=127 then sum = sum + ppq_s + ppq_e + pitch*17 end
  end
  return tostring(note_cnt) .. ":" .. tostring(sum)
end

function build_progress_for_take_full(take)
  local prog = {Expert={}, Hard={}, Medium={}, Easy={}}
  local sigs = {Expert={}, Hard={}, Medium={}, Easy={}}
  for _,lab in ipairs(DIFFS) do for i=1,#REGIONS do prog[lab][i] = false; sigs[lab][i] = 0 end end
  if not take or #REGIONS == 0 then return prog, sigs end

  local _, note_cnt = reaper.MIDI_CountEvts(take)
  for ni = 0, note_cnt-1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(take, ni)
    if ok then
      local t_s = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_s)
      local t_e = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_e)

      local hitE = (pitch>=PITCH_RANGE.Expert[1] and pitch<=PITCH_RANGE.Expert[2])
      local hitH = (pitch>=PITCH_RANGE.Hard[1]   and pitch<=PITCH_RANGE.Hard[2])
      local hitM = (pitch>=PITCH_RANGE.Medium[1] and pitch<=PITCH_RANGE.Medium[2])
      local hitL = (pitch>=PITCH_RANGE.Easy[1]   and pitch<=PITCH_RANGE.Easy[2])

      if hitE or hitH or hitM or hitL then
        local h = ppq_s + ppq_e + pitch*17
        for ri = 1, #REGIONS do
          local rs, re_ = REGIONS[ri].pos, REGIONS[ri].r_end
          if t_e > rs and t_s < re_ then
            if hitE then prog.Expert[ri] = true; sigs.Expert[ri] = sigs.Expert[ri] + h end
            if hitH then prog.Hard[ri]   = true; sigs.Hard[ri]   = sigs.Hard[ri]   + h end
            if hitM then prog.Medium[ri] = true; sigs.Medium[ri] = sigs.Medium[ri] + h end
            if hitL then prog.Easy[ri]   = true; sigs.Easy[ri]   = sigs.Easy[ri]   + h end
          end
        end
      end
    end
  end
  return prog, sigs
end

local function build_progress_for_take_range(take, lo, hi)
  local arr = {}
  local sig_arr = {}
  for i=1,#REGIONS do arr[i] = false; sig_arr[i] = 0 end
  if not take or #REGIONS == 0 then return arr, sig_arr end

  local _, note_cnt = reaper.MIDI_CountEvts(take)
  for ni = 0, note_cnt-1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(take, ni)
    if ok and pitch>=lo and pitch<=hi then
      local t_s = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_s)
      local t_e = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_e)
      local h = ppq_s + ppq_e + pitch*17
      for ri = 1, #REGIONS do
        local rs, re_ = REGIONS[ri].pos, REGIONS[ri].r_end
        if t_e > rs and t_s < re_ then arr[ri] = true; sig_arr[ri] = sig_arr[ri] + h end
      end
    end
  end
  return arr, sig_arr
end

function rebuild_state_for_tab(tab, variant)
  -- Nested tree is tab -> variant -> mode -> region; variant defaults to "regular".
  variant = variant or "regular"
  if tab == "Vocals" then
    for _,diff in ipairs(DIFFS_VOX) do
      STATE.Vocals[variant] = STATE.Vocals[variant] or {}
      STATE.Vocals[variant][diff] = STATE.Vocals[variant][diff] or {}
      for ri=1,#REGIONS do
        local live  = PROGRESS.Vocals and PROGRESS.Vocals[variant] and PROGRESS.Vocals[variant][diff] and PROGRESS.Vocals[variant][diff][ri] or false
        local saved = SAVED.Vocals and SAVED.Vocals[variant] and SAVED.Vocals[variant][diff] and SAVED.Vocals[variant][diff][ri]
        local st
        if saved ~= nil then
          -- If saved was Empty (3) but notes now exist, transition to In Progress
          if saved == 3 and live then
            st = 1
            save("Vocals", diff, ri, 1)
          elseif saved == 0 then
            st = live and 1 or 0
          elseif saved == 2 then
            -- Downgrade to In Progress if the MIDI changed since completion
            local cur_sig = PROGRESS_SIG.Vocals and PROGRESS_SIG.Vocals[variant] and PROGRESS_SIG.Vocals[variant][diff] and PROGRESS_SIG.Vocals[variant][diff][ri] or 0
            local cmp_sig = COMPLETE_SIG.Vocals and COMPLETE_SIG.Vocals[variant] and COMPLETE_SIG.Vocals[variant][diff] and COMPLETE_SIG.Vocals[variant][diff][ri]
            if cmp_sig ~= nil and cur_sig ~= cmp_sig then
              st = 1
              save("Vocals", diff, ri, 1)
            else
              st = saved
            end
          else
            st = saved
          end
        else
          st = live and 1 or 0
        end
        STATE.Vocals[variant][diff][ri] = st
      end
    end
    return
  end

  if tab == "Venue" then
    for _,diff in ipairs(DIFFS_VENUE) do
      STATE.Venue[variant] = STATE.Venue[variant] or {}
      STATE.Venue[variant][diff] = STATE.Venue[variant][diff] or {}
      for ri=1,#REGIONS do
        local live  = PROGRESS.Venue and PROGRESS.Venue[variant] and PROGRESS.Venue[variant][diff] and PROGRESS.Venue[variant][diff][ri] or false
        local saved = SAVED.Venue and SAVED.Venue[variant] and SAVED.Venue[variant][diff] and SAVED.Venue[variant][diff][ri]
        local st
        if saved ~= nil then
          -- If saved was Empty (3) but notes now exist, transition to In Progress
          if saved == 3 and live then
            st = 1
            save("Venue", diff, ri, 1)
          elseif saved == 0 then
            st = live and 1 or 0
          elseif saved == 2 then
            -- See the matching Vocals comment above for why we don't
            -- populate COMPLETE_SIG here.
            local cur_sig = PROGRESS_SIG.Venue and PROGRESS_SIG.Venue[variant] and PROGRESS_SIG.Venue[variant][diff] and PROGRESS_SIG.Venue[variant][diff][ri] or 0
            local cmp_sig = COMPLETE_SIG.Venue and COMPLETE_SIG.Venue[variant] and COMPLETE_SIG.Venue[variant][diff] and COMPLETE_SIG.Venue[variant][diff][ri]
            if cmp_sig ~= nil and cur_sig ~= cmp_sig then
              st = 1
              save("Venue", diff, ri, 1)
            else
              st = saved
            end
          else
            st = saved
          end
        else
          st = live and 1 or 0
        end
        STATE.Venue[variant][diff][ri] = st
      end
    end
    return
  end

  STATE[tab] = STATE[tab] or {}
  STATE[tab][variant] = STATE[tab][variant] or {}
  for _,diff in ipairs(DIFFS) do
    STATE[tab][variant][diff] = STATE[tab][variant][diff] or {}
    for ri=1,#REGIONS do
      local live  = PROGRESS[tab] and PROGRESS[tab][variant] and PROGRESS[tab][variant][diff] and PROGRESS[tab][variant][diff][ri] or false
      local saved = SAVED[tab] and SAVED[tab][variant] and SAVED[tab][variant][diff] and SAVED[tab][variant][diff][ri]
      local st
      if saved ~= nil then
        -- If saved was Empty (3) but notes now exist, transition to In Progress
        if saved == 3 and live then
          st = 1
          save(tab, diff, ri, 1)
        elseif saved == 0 then
          st = live and 1 or 0
        elseif saved == 2 then
          -- See the matching Vocals comment above for why we don't
          -- populate COMPLETE_SIG here.
          local cur_sig = PROGRESS_SIG[tab] and PROGRESS_SIG[tab][variant] and PROGRESS_SIG[tab][variant][diff] and PROGRESS_SIG[tab][variant][diff][ri] or 0
          local cmp_sig = COMPLETE_SIG[tab] and COMPLETE_SIG[tab][variant] and COMPLETE_SIG[tab][variant][diff] and COMPLETE_SIG[tab][variant][diff][ri]
          if cmp_sig ~= nil and cur_sig ~= cmp_sig then
            st = 1
            save(tab, diff, ri, 1)
          else
            st = saved
          end
        else
          st = saved
        end
      else
        st = live and 1 or 0
      end
      STATE[tab][variant][diff][ri] = st
    end
  end
end

-- Build progress for tabs -----------------------------------------------
function compute_tab(tab)
  -- Wrap the flat per-mode writer output as the "regular" variant cell.
  local tr = find_track_by_name(TAB_TRACK[tab])
  local tk = first_midi_take_on_track(tr)
  local prog, sigs = build_progress_for_take_full(tk)
  PROGRESS[tab] = { regular = prog }
  PROGRESS_SIG[tab] = { regular = sigs }
  TAB_SIG[tab]  = make_sig_for_take(tk)
  rebuild_state_for_tab(tab, "regular")
end

function compute_vocals()
  -- Compute ALL vocal modes so button colors are correct
  PROGRESS.Vocals = PROGRESS.Vocals or {}
  PROGRESS.Vocals["regular"] = PROGRESS.Vocals["regular"] or {}
  PROGRESS_SIG.Vocals = PROGRESS_SIG.Vocals or {}
  PROGRESS_SIG.Vocals["regular"] = PROGRESS_SIG.Vocals["regular"] or {}
  for _, mode in ipairs(DIFFS_VOX) do
    local trackname = VOCALS_TRACKS[mode]
    local tr = find_track_by_name(trackname)
    local tk = first_midi_take_on_track(tr)
    local lo, hi = VOCALS_PITCH_RANGE[1], VOCALS_PITCH_RANGE[2]
    local prog, sig_arr = build_progress_for_take_range(tk, lo, hi)
    PROGRESS.Vocals["regular"][mode] = prog
    PROGRESS_SIG.Vocals["regular"][mode] = sig_arr
  end
  -- Use active mode's take for signature (the Vocals tab's own mode, not
  -- current_tab: compute_vocals also runs at init on any tab).
  local vocals_mode = TABS_BY_NAME and TABS_BY_NAME["Vocals"]
                    and TABS_BY_NAME["Vocals"]:current_mode_key() or "V"
  local active_tr = find_track_by_name(VOCALS_TRACKS[vocals_mode])
  local active_tk = first_midi_take_on_track(active_tr)
  TAB_SIG.Vocals = make_sig_for_take(active_tk)
  rebuild_state_for_tab("Vocals", "regular")
end

function compute_venue()
  -- Compute ALL venue modes so button colors are correct
  PROGRESS.Venue = PROGRESS.Venue or {}
  PROGRESS.Venue["regular"] = PROGRESS.Venue["regular"] or {}
  PROGRESS_SIG.Venue = PROGRESS_SIG.Venue or {}
  PROGRESS_SIG.Venue["regular"] = PROGRESS_SIG.Venue["regular"] or {}
  for _, mode in ipairs(DIFFS_VENUE) do
    local trackname = VENUE_TRACKS[mode]
    local tr = find_track_by_name(trackname)
    local tk = first_midi_take_on_track(tr)
    -- Use full pitch range for venue tracks
    local prog, sig_arr = build_progress_for_take_range(tk, 0, 127)
    PROGRESS.Venue["regular"][mode] = prog
    PROGRESS_SIG.Venue["regular"][mode] = sig_arr
  end
  TAB_SIG.Venue = "venue_computed"  -- Simple signature since we compute both
  rebuild_state_for_tab("Venue", "regular")
end

-- Pro Keys progress: writes PROGRESS["Keys"]["pro"][mkey] / sigs.
local function compute_pro_keys_difficulty(mkey)
  local trackname = PRO_KEYS_TRACKS[mkey] or PRO_KEYS_TRACKS["Expert"]
  local tr = find_track_by_name(trackname)
  local tk = first_midi_take_on_track(tr)
  local lo, hi = PRO_KEYS_PITCH_RANGE[1], PRO_KEYS_PITCH_RANGE[2]
  local prog, sig_arr = build_progress_for_take_range(tk, lo, hi)
  PROGRESS["Keys"] = PROGRESS["Keys"] or {}
  PROGRESS["Keys"]["pro"] = PROGRESS["Keys"]["pro"] or {}
  PROGRESS["Keys"]["pro"][mkey] = prog
  PROGRESS_SIG["Keys"] = PROGRESS_SIG["Keys"] or {}
  PROGRESS_SIG["Keys"]["pro"] = PROGRESS_SIG["Keys"]["pro"] or {}
  PROGRESS_SIG["Keys"]["pro"][mkey] = sig_arr
end

-- compute_pro_keys writes to the nested tree and rebuilds STATE inline.
function compute_pro_keys()
  -- Compute ALL difficulties so button colors are correct
  for _, mkey in ipairs({"Expert", "Hard", "Medium", "Easy"}) do
    compute_pro_keys_difficulty(mkey)
  end
  -- Per-cell STATE rebuild for the pro variant. Same logic as
  -- rebuild_state_for_tab but inlined and targeted at STATE["Keys"]["pro"].
  STATE["Keys"] = STATE["Keys"] or {}
  STATE["Keys"]["pro"] = STATE["Keys"]["pro"] or {}
  for _, mkey in ipairs({"Expert","Hard","Medium","Easy"}) do
    STATE["Keys"]["pro"][mkey] = STATE["Keys"]["pro"][mkey] or {}
    for ri = 1, #REGIONS do
      local live = PROGRESS["Keys"] and PROGRESS["Keys"]["pro"] and PROGRESS["Keys"]["pro"][mkey] and PROGRESS["Keys"]["pro"][mkey][ri] or false
      local saved = SAVED["Keys"] and SAVED["Keys"]["pro"] and SAVED["Keys"]["pro"][mkey] and SAVED["Keys"]["pro"][mkey][ri]
      local st
      if saved ~= nil then
        if saved == 3 and live then
          st = 1
          save("Keys", mkey, ri, 1)
        elseif saved == 0 then
          st = live and 1 or 0
        elseif saved == 2 then
          local cur_sig = PROGRESS_SIG["Keys"] and PROGRESS_SIG["Keys"]["pro"] and PROGRESS_SIG["Keys"]["pro"][mkey] and PROGRESS_SIG["Keys"]["pro"][mkey][ri] or 0
          local cmp_sig = COMPLETE_SIG["Keys"] and COMPLETE_SIG["Keys"]["pro"] and COMPLETE_SIG["Keys"]["pro"][mkey] and COMPLETE_SIG["Keys"]["pro"][mkey][ri]
          if cmp_sig ~= nil and cur_sig ~= cmp_sig then
            st = 1
            save("Keys", mkey, ri, 1)
          else
            st = saved
          end
        else
          st = saved
        end
      else
        st = live and 1 or 0
      end
      STATE["Keys"]["pro"][mkey][ri] = st
    end
  end
end
