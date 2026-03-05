-- @description Predict Tempo Markers
-- @author FinestCardboardPearls
-- @version 0.6
-- @about
--   Analyzes drum transients and predicts optimal tempo marker placements.
--   Fits tempo changes so musical grid subdivisions (16ths/triplets) align with transients.

local r = reaper

-- Check for ReaImGui
if not r.ImGui_GetVersion then
  r.MB("ReaImGui extension is required for this script.", "Missing Dependency", 0)
  return
end

-- Create ImGui context
local ctx = r.ImGui_CreateContext("Predict Tempo Markers")

-- Beat type options (what each "beat" in beat_count represents)
local beat_types = { "Half Beats", "Quarter Beats", "Eighth Beats", "Sixteenth Beats" }
local beat_type_index = 1 -- 0-indexed for combo: 0=Half, 1=Quarter, 2=Eighth, 3=Sixteenth

-- State variables
local beat_count = 4
local measures = 1
local selected_option = nil -- nil, "A", "B", or "C"
local set_new_time_signature = false -- Toggle for setting time signature on first marker

-- Detect time signature at cursor position
local function GetTimeSigAtCursor()
  local cursor_pos = r.GetCursorPosition()
  local marker_idx = r.FindTempoTimeSigMarker(0, cursor_pos)
  
  if marker_idx >= 0 then
    local _, _, _, _, _, timesig_num, timesig_denom = r.GetTempoTimeSigMarker(0, marker_idx)
    -- Only use if both are valid (non-zero)
    if timesig_num > 0 and timesig_denom > 0 then
      return timesig_num, timesig_denom
    end
  end
  -- Default: 4/4
  return 4, 4
end

-- Convert denominator to beat_type_index (0=Half/2, 1=Quarter/4, 2=Eighth/8, 3=Sixteenth/16)
local function DenomToBeatTypeIndex(denom)
  if denom == 2 then return 0
  elseif denom == 4 then return 1
  elseif denom == 8 then return 2
  elseif denom == 16 then return 3
  else return 1 end -- default to quarter
end

-- Convert beat_type_index to denominator (inverse of above)
local function BeatTypeIndexToDenom()
  local denoms = { 2, 4, 8, 16 }
  return denoms[beat_type_index + 1] or 4
end

-- Initialize from time signature
local init_num, init_denom = GetTimeSigAtCursor()
beat_count = init_num
beat_type_index = DenomToBeatTypeIndex(init_denom)

-- Prediction storage (empty for now)
local predictions = {
  Baseline = nil, -- Single marker at baseline BPM
  A = nil, -- { markers = { {pos=..., bpm=...}, ... } }
  B = nil,
  C = nil
}

-- Analysis results
local baseline_bpm = nil
local baseline_error = nil
local transient_count = 0
local selection_duration = nil

-- Window state
local window_flags = r.ImGui_WindowFlags_NoCollapse()

--------------------------------------------------------------------------------
-- Time Selection Helper
--------------------------------------------------------------------------------

local function GetTimeSelection()
  local start_time, end_time = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if start_time == end_time then
    return nil, nil, "No time selection. Please select a time range."
  end
  return start_time, end_time, nil
end

--------------------------------------------------------------------------------
-- Tempo Marker Functions
--------------------------------------------------------------------------------

local function DeleteMarkersInRange(start_time, end_time)
  -- Delete tempo markers within the time range (iterate backwards)
  local count = r.CountTempoTimeSigMarkers(0)
  for i = count - 1, 0, -1 do
    local _, timepos = r.GetTempoTimeSigMarker(0, i)
    if timepos >= start_time and timepos <= end_time then
      r.DeleteTempoTimeSigMarker(0, i)
    end
  end
end

local function ApplyPrediction(prediction, start_time, end_time)
  if not prediction or not prediction.markers then return end
  
  -- Save the time selection length
  local selection_length = end_time - start_time
  
  r.Undo_BeginBlock()
  
  -- Delete existing markers in range
  DeleteMarkersInRange(start_time, end_time)
  
  -- Add new markers
  for i, marker in ipairs(prediction.markers) do
    if i == 1 and set_new_time_signature then
      -- First marker: set time signature based on current beat_count and beat_type_index
      local timesig_denom = BeatTypeIndexToDenom()
      r.AddTempoTimeSigMarker(0, marker.pos, marker.bpm, beat_count, timesig_denom, false)
    else
      -- Other markers: tempo only, no time signature changes
      r.AddTempoTimeSigMarker(0, marker.pos, marker.bpm, 0, 0, false)
    end
  end
  
  -- Restore time selection to original length
  r.GetSet_LoopTimeRange(true, false, start_time, start_time + selection_length, false)
  
  -- Move edit cursor to end of time selection
  r.SetEditCurPos(start_time + selection_length, false, false)
  
  r.Undo_EndBlock("Apply Tempo Prediction", -1)
  r.UpdateTimeline()
end

--------------------------------------------------------------------------------
-- Analysis Function (All-Lua using REAPER's transient detection)
--------------------------------------------------------------------------------

local analysis_start_time = 0
local analysis_end_time = 0

-- Get beat duration multiplier based on beat type
-- beat_type_index: 0=Half, 1=Quarter, 2=Eighth, 3=Sixteenth
local function GetBeatMultiplier()
  local multipliers = { 2.0, 1.0, 0.5, 0.25 }
  return multipliers[beat_type_index + 1] or 1.0
end

-- Subdivision positions within a quarter note (as fractions 0-1)
-- 16ths: 0, 0.25, 0.5, 0.75; Triplets: 0, 0.333, 0.667
-- Combined unique positions (sorted):
local SUBDIVISIONS = { 0, 0.25, 1/3, 0.5, 2/3, 0.75 }

-- Find which subdivision position a fraction (0-1) is closest to
-- Returns the subdivision fraction
local function NearestSubdivision(frac)
  local best_subdiv = 0
  local best_dist = math.huge
  for _, subdiv in ipairs(SUBDIVISIONS) do
    local dist = math.abs(frac - subdiv)
    if dist < best_dist then
      best_dist = dist
      best_subdiv = subdiv
    end
  end
  -- Also check 1.0 (next beat) 
  if math.abs(frac - 1.0) < best_dist then
    return 1.0
  end
  return best_subdiv
end

-- Get transients by walking cursor through transient positions
-- Uses REAPER's "Move cursor to next transient" action which reliably finds transients
local function GetTransientsInRange(start_time, end_time)
  local transients = {}
  
  -- Check that we have a selected item (required for transient detection)
  local sel_item = r.GetSelectedMediaItem(0, 0)
  if not sel_item then return transients, "No item selected. Please select a media item." end
  
  -- Save current cursor position and view
  local saved_cursor = r.GetCursorPosition()
  
  -- Position cursor just before start_time
  r.SetEditCurPos(start_time - 0.001, false, false)
  
  -- Walk through transients using "Move cursor to next transient in items" (action 40375)
  local max_iterations = 1000 -- safety limit
  local iterations = 0
  local last_pos = -1
  
  while iterations < max_iterations do
    iterations = iterations + 1
    
    -- Move to next transient
    r.Main_OnCommand(40375, 0) -- Item: Move cursor to next transient in items
    
    local cur_pos = r.GetCursorPosition()
    
    -- Check if cursor moved (didn't find a transient)
    if math.abs(cur_pos - last_pos) < 0.0001 then
      break -- Cursor didn't move - no more transients
    end
    
    -- Check if we're past the end of our range
    if cur_pos > end_time + 0.001 then
      break
    end
    
    -- Check if we're in our range
    if cur_pos >= start_time - 0.001 and cur_pos <= end_time + 0.001 then
      table.insert(transients, cur_pos)
    end
    
    last_pos = cur_pos
  end
  
  -- Restore cursor position
  r.SetEditCurPos(saved_cursor, false, false)
  
  -- Sort and dedupe transients
  table.sort(transients)
  local unique_transients = {}
  for _, t in ipairs(transients) do
    if #unique_transients == 0 or math.abs(t - unique_transients[#unique_transients]) > 0.001 then
      table.insert(unique_transients, t)
    end
  end
  
  return unique_transients, nil
end

-- Round a quarter-note-fraction to nearest valid subdivision
-- Valid subdivisions: multiples of 16ths (0.25) or triplets (1/3)
local function RoundToNearestSubdivision(quarters)
  local best = quarters
  local best_err = math.huge
  
  -- Check multiples of 16ths (0.25) and triplets (1/3) up to 12 subdivisions
  for n = 1, 12 do
    local as_16ths = n * 0.25
    local err = math.abs(quarters - as_16ths)
    if err < best_err then
      best_err = err
      best = as_16ths
    end
    
    local as_trips = n * (1/3)
    err = math.abs(quarters - as_trips)
    if err < best_err then
      best_err = err
      best = as_trips
    end
  end
  
  return best
end

-- Subdivision grid positions within each quarter note (fractions 0-1)
-- 16ths: 0, 0.25, 0.5, 0.75; Triplets: 0, 1/3, 2/3
-- Combined unique positions (sorted):
local GRID_SUBDIVISIONS = { 0, 0.25, 1/3, 0.5, 2/3, 0.75 }

-- Calculate total alignment error: sum of distances from each transient to nearest grid line
-- Grid lines are placed at every 16th note plus triplet positions, warped by tempo markers
local function CalculateAlignmentError(markers, start_time, end_time, transients, total_quarter_beats)
  if #markers == 0 or #transients == 0 then return 0 end
  
  -- Sort markers by position
  local sorted_markers = {}
  for _, m in ipairs(markers) do
    table.insert(sorted_markers, { pos = m.pos, bpm = m.bpm })
  end
  table.sort(sorted_markers, function(a, b) return a.pos < b.pos end)
  
  -- Ensure first marker starts at selection start
  if sorted_markers[1].pos > start_time + 0.001 then
    table.insert(sorted_markers, 1, { pos = start_time, bpm = sorted_markers[1].bpm })
  end
  
  -- Build list of all grid line times by walking through musical beats
  -- and converting to time based on which tempo segment we're in
  local grid_times = {}
  
  -- For each subdivision position in the musical timeline (in quarter notes)
  -- figure out what absolute time it corresponds to
  local function BeatPositionToTime(beat_pos)
    -- Walk through tempo segments to find cumulative time
    local cumulative_beat = 0
    local cumulative_time = start_time
    
    for seg_idx = 1, #sorted_markers do
      local seg_start_time = sorted_markers[seg_idx].pos
      local seg_end_time = (seg_idx < #sorted_markers) and sorted_markers[seg_idx + 1].pos or end_time
      local seg_bpm = sorted_markers[seg_idx].bpm
      local quarter_dur = 60 / seg_bpm
      
      -- How many beats does this segment cover?
      local seg_duration = seg_end_time - seg_start_time
      local seg_beats = seg_duration / quarter_dur
      
      if beat_pos <= cumulative_beat + seg_beats then
        -- Target beat is in this segment
        local beats_into_seg = beat_pos - cumulative_beat
        return seg_start_time + beats_into_seg * quarter_dur
      end
      
      cumulative_beat = cumulative_beat + seg_beats
      cumulative_time = seg_end_time
    end
    
    -- Past end of selection
    return end_time
  end
  
  -- Generate grid positions for all subdivisions from beat 0 to total_quarter_beats
  for quarter = 0, math.ceil(total_quarter_beats) do
    for _, subdiv in ipairs(GRID_SUBDIVISIONS) do
      local beat_pos = quarter + subdiv
      if beat_pos >= 0 and beat_pos <= total_quarter_beats then
        local grid_time = BeatPositionToTime(beat_pos)
        if grid_time >= start_time and grid_time <= end_time then
          table.insert(grid_times, grid_time)
        end
      end
    end
  end
  
  -- Sort and dedupe grid times
  table.sort(grid_times)
  local unique_grid = {}
  for _, t in ipairs(grid_times) do
    if #unique_grid == 0 or math.abs(t - unique_grid[#unique_grid]) > 0.001 then
      table.insert(unique_grid, t)
    end
  end
  
  if #unique_grid == 0 then return 0 end
  
  -- For each transient, find distance to nearest grid line (binary search would be faster but this works)
  local total_error = 0
  for _, trans_time in ipairs(transients) do
    local min_dist = math.huge
    for _, grid_time in ipairs(unique_grid) do
      local dist = math.abs(trans_time - grid_time)
      if dist < min_dist then
        min_dist = dist
      end
    end
    total_error = total_error + min_dist
  end
  
  return total_error
end

-- Generate tempo predictions by fitting grid to transients
-- Algorithm:
-- Use CUSUM (Cumulative Sum) to detect drift hot spots
-- Key insight: Track signed error (early/late), detect when cumulative drift shifts
-- sensitivity: threshold multiplier (lower = more sensitive, more markers)
local function GeneratePredictions(transients, start_time, end_time, baseline_bpm, total_quarter_beats, max_markers, sensitivity)
  if #transients < 2 then return nil end
  
  sensitivity = sensitivity or 1.0
  local baseline_quarter_dur = 60 / baseline_bpm
  local selection_duration = end_time - start_time
  local three_beats_duration = baseline_quarter_dur * 3
  
  -- Calculate SIGNED alignment error for each transient (negative = early, positive = late)
  local function GetSignedError(transient_time)
    local time_from_start = transient_time - start_time
    local quarters_from_start = time_from_start / baseline_quarter_dur
    local frac = quarters_from_start % 1
    
    -- Find nearest subdivision and direction
    local best_subdiv = 0
    local best_dist = math.huge
    for _, subdiv in ipairs(SUBDIVISIONS) do
      local dist = math.abs(frac - subdiv)
      if dist < best_dist then
        best_dist = dist
        best_subdiv = subdiv
      end
    end
    -- Check wrap to next beat
    if math.abs(frac - 1.0) < best_dist then
      best_dist = math.abs(frac - 1.0)
      best_subdiv = 1.0
    end
    
    -- Signed error: positive if transient is late, negative if early
    local signed_error = (frac - best_subdiv) * baseline_quarter_dur
    return signed_error
  end
  
  -- Calculate rolling mean signed error over 3-beat windows
  local rolling_signed_errors = {}
  for i, t in ipairs(transients) do
    local sum_err = 0
    local count = 0
    for j = i, #transients do
      if transients[j] > t + three_beats_duration then break end
      sum_err = sum_err + GetSignedError(transients[j])
      count = count + 1
    end
    rolling_signed_errors[i] = (count > 0) and (sum_err / count) or 0
  end
  
  -- CUSUM: Track cumulative deviation from zero (neutral timing)
  -- Don't reset during scan - we need full magnitude info for scoring
  local cusum_pos = {} -- Cumulative sum tracking late drift
  local cusum_neg = {} -- Cumulative sum tracking early drift
  local k = 0.002 -- Slack parameter (2ms tolerance before counting as drift)
  
  cusum_pos[1] = math.max(0, rolling_signed_errors[1] - k)
  cusum_neg[1] = math.max(0, -rolling_signed_errors[1] - k)
  
  for i = 2, #rolling_signed_errors do
    cusum_pos[i] = math.max(0, cusum_pos[i-1] + rolling_signed_errors[i] - k)
    cusum_neg[i] = math.max(0, cusum_neg[i-1] - rolling_signed_errors[i] - k)
  end
  
  -- MAGNITUDE-FIRST: Identify ALL potential change points and score by drift magnitude
  local h = 0.008 * sensitivity -- Decision threshold (scaled by sensitivity)
  local min_spacing = math.max(2, math.floor(3 * sensitivity)) -- Minimum transients between markers
  
  -- Collect all candidate change points with their scores
  local candidates = {}
  
  for i = 2, #transients do
    local dominated_by_drift = false
    local score = 0
    
    -- Check for threshold crossing (significant drift accumulated)
    if cusum_pos[i] > h or cusum_neg[i] > h then
      dominated_by_drift = true
      score = math.max(cusum_pos[i], cusum_neg[i])
    end
    
    -- Check for direction reversal (drift switched from early to late or vice versa)
    local prev_bias = rolling_signed_errors[i-1]
    local curr_bias = rolling_signed_errors[i]
    if (prev_bias > k and curr_bias < -k) or (prev_bias < -k and curr_bias > k) then
      dominated_by_drift = true
      -- Score direction reversals by magnitude of the swing
      local reversal_magnitude = math.abs(prev_bias - curr_bias)
      score = math.max(score, reversal_magnitude * 10)
    end
    
    if dominated_by_drift then
      -- Add rolling error magnitude to score
      score = score + math.abs(rolling_signed_errors[i] or 0) * 5
      table.insert(candidates, { idx = i - 1, score = score })
    end
  end
  
  -- Sort candidates by score (highest first) - magnitude-first selection
  table.sort(candidates, function(a, b) return a.score > b.score end)
  
  -- Select top candidates while respecting minimum spacing
  local change_points = {}
  for _, cand in ipairs(candidates) do
    if #change_points >= max_markers - 1 then break end
    
    -- Check spacing against already-selected points
    local too_close = false
    for _, selected_idx in ipairs(change_points) do
      if math.abs(cand.idx - selected_idx) < min_spacing then
        too_close = true
        break
      end
    end
    
    if not too_close then
      table.insert(change_points, cand.idx)
    end
  end
  
  -- Sort selected change points by position (for marker placement order)
  table.sort(change_points)
  
  -- Build marker positions: start_time + each change point transient
  local marker_positions = { start_time }
  for _, idx in ipairs(change_points) do
    if transients[idx] and transients[idx] > start_time + 0.01 then
      table.insert(marker_positions, transients[idx])
    end
  end
  
  -- Calculate optimal BPM for each segment using iterative error minimization
  -- Start with baseline, make tiny adjustments, increase until error stops improving
  local segments = {} -- {start, duration, bpm, transient_indices}
  
  for i, marker_pos in ipairs(marker_positions) do
    local seg_start = marker_pos
    local seg_end = marker_positions[i + 1] or end_time
    local seg_duration = seg_end - seg_start
    
    -- Collect transient indices in this segment
    local seg_transient_indices = {}
    for ti, t in ipairs(transients) do
      if t >= seg_start and t < seg_end then
        table.insert(seg_transient_indices, ti)
      end
    end
    
    -- Determine direction from average error
    local avg_error = 0
    if #seg_transient_indices > 0 then
      local sum = 0
      for _, ti in ipairs(seg_transient_indices) do
        sum = sum + (rolling_signed_errors[ti] or 0)
      end
      avg_error = sum / #seg_transient_indices
    end
    
    -- Direction: negative error = early = need to speed up = positive direction
    local direction = (avg_error < 0) and 1 or -1
    
    table.insert(segments, {
      start = seg_start,
      duration = seg_duration,
      bpm = baseline_bpm,
      direction = direction,
      transient_indices = seg_transient_indices
    })
  end
  
  -- Helper: calculate total error for current segment BPMs
  local function CalcTotalError()
    local total_err = 0
    for _, seg in ipairs(segments) do
      local seg_quarter_dur = 60 / seg.bpm
      for _, ti in ipairs(seg.transient_indices) do
        local t = transients[ti]
        local time_in_seg = t - seg.start
        local quarters_in_seg = time_in_seg / seg_quarter_dur
        local frac = quarters_in_seg % 1
        local best_dist = math.huge
        for _, subdiv in ipairs(SUBDIVISIONS) do
          local dist = math.abs(frac - subdiv)
          if dist < best_dist then best_dist = dist end
        end
        if math.abs(frac - 1.0) < best_dist then best_dist = math.abs(frac - 1.0) end
        total_err = total_err + best_dist * seg_quarter_dur
      end
    end
    return total_err
  end
  
  -- Iteratively adjust each segment's BPM to minimize error
  local step_size = 0.1 -- Start with 0.1 BPM steps
  local max_adjustment = 3.0 -- Maximum total adjustment from baseline
  
  for iter = 1, 50 do
    local improved = false
    
    for si, seg in ipairs(segments) do
      local current_error = CalcTotalError()
      local current_bpm = seg.bpm
      
      -- Try adjusting in the preferred direction
      local trial_bpm = current_bpm + (step_size * seg.direction)
      
      -- Clamp to baseline ± max_adjustment
      if trial_bpm < baseline_bpm - max_adjustment then
        trial_bpm = baseline_bpm - max_adjustment
      elseif trial_bpm > baseline_bpm + max_adjustment then
        trial_bpm = baseline_bpm + max_adjustment
      end
      
      seg.bpm = trial_bpm
      local new_error = CalcTotalError()
      
      if new_error < current_error - 0.0001 then
        -- Keep the change
        improved = true
      else
        -- Revert
        seg.bpm = current_bpm
        -- Try opposite direction
        trial_bpm = current_bpm - (step_size * seg.direction)
        if trial_bpm >= baseline_bpm - max_adjustment and trial_bpm <= baseline_bpm + max_adjustment then
          seg.bpm = trial_bpm
          new_error = CalcTotalError()
          if new_error < current_error - 0.0001 then
            seg.direction = -seg.direction -- Flip direction for future
            improved = true
          else
            seg.bpm = current_bpm -- Revert
          end
        end
      end
    end
    
    if not improved then
      -- Reduce step size and try again
      step_size = step_size * 0.5
      if step_size < 0.01 then break end
    end
  end
  
  -- Scale all BPMs proportionally to preserve total beats
  local total_raw_beats = 0
  for _, seg in ipairs(segments) do
    total_raw_beats = total_raw_beats + (seg.bpm * seg.duration) / 60
  end
  
  local scale = total_quarter_beats / total_raw_beats
  for _, seg in ipairs(segments) do
    seg.bpm = seg.bpm * scale
  end
  
  local markers = {}
  for _, seg in ipairs(segments) do
    local final_bpm = math.floor(seg.bpm * 1000 + 0.5) / 1000
    table.insert(markers, { pos = seg.start, bpm = final_bpm })
  end
  
  -- If no swings detected, return single baseline marker
  if #markers == 0 then
    markers = { { pos = start_time, bpm = baseline_bpm } }
  end
  
  -- Deduplicate adjacent markers with same BPM
  local deduped = { markers[1] }
  for i = 2, #markers do
    if math.abs(markers[i].bpm - deduped[#deduped].bpm) > 0.001 then
      table.insert(deduped, markers[i])
    end
  end
  
  local alignment_error = CalculateAlignmentError(deduped, start_time, end_time, transients, total_quarter_beats)
  return { markers = deduped, total_beats = total_quarter_beats, error = alignment_error }
end

local function AnalyzeSelection()
  -- Get time selection
  local start_time, end_time, err = GetTimeSelection()
  if not start_time then
    r.MB(err, "Analysis Error", 0)
    return false
  end
  
  -- Store for later use when applying
  analysis_start_time = start_time
  analysis_end_time = end_time
  
  -- Get transients by cursor navigation
  local transients, trans_err = GetTransientsInRange(start_time, end_time)
  if trans_err then
    r.MB(trans_err, "Analysis Error", 0)
    return false
  end
  
  if #transients < 2 then
    r.MB("Not enough transients found in selection (found " .. #transients .. ").\n\nMake sure:\n- A media item is selected\n- The item has visible transients (waveform peaks)", "Analysis Error", 0)
    return false
  end
  
  -- Store transient count
  transient_count = #transients
  
  -- Calculate baseline BPM from time selection
  selection_duration = end_time - start_time
  local beat_mult = GetBeatMultiplier()
  local total_quarter_beats = beat_count * beat_mult * measures
  baseline_bpm = (total_quarter_beats / selection_duration) * 60
  baseline_bpm = math.floor(baseline_bpm * 1000 + 0.5) / 1000 -- round to 3 decimals
  
  -- Calculate baseline error (single marker at baseline tempo)
  local baseline_markers = { { pos = start_time, bpm = baseline_bpm } }
  baseline_error = CalculateAlignmentError(baseline_markers, start_time, end_time, transients, total_quarter_beats)
  
  -- Store baseline as a prediction option
  predictions.Baseline = { 
    markers = baseline_markers, 
    total_beats = total_quarter_beats, 
    error = baseline_error 
  }
  
  -- Generate predictions with different sensitivities (lower = more markers)
  predictions.A = GeneratePredictions(transients, start_time, end_time, baseline_bpm, total_quarter_beats, 2, 2.0)  -- Less sensitive, fewer markers
  predictions.B = GeneratePredictions(transients, start_time, end_time, baseline_bpm, total_quarter_beats, 3, 1.0)  -- Medium sensitivity
  predictions.C = GeneratePredictions(transients, start_time, end_time, baseline_bpm, total_quarter_beats, 4, 0.5)  -- Most sensitive, more markers
  
  -- Reject predictions that don't improve on baseline error
  if predictions.A and predictions.A.error >= baseline_error then predictions.A = nil end
  if predictions.B and predictions.B.error >= baseline_error then predictions.B = nil end
  if predictions.C and predictions.C.error >= baseline_error then predictions.C = nil end
  
  selected_option = nil
  
  return true
end

local function RenderPredictionButton(label, prediction, option_key)
  local button_width = 100
  local button_height = 150
  
  r.ImGui_BeginGroup(ctx)
  
  -- Button header
  local is_selected = selected_option == option_key
  if is_selected then
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x4A90D9FF)
  end
  
  if prediction then
    -- Has prediction data
    local marker_count = #prediction.markers
    local beats_str = prediction.total_beats and string.format(" (%.2f beats)", prediction.total_beats) or ""
    local button_label = string.format("%s\n%d marker%s", label, marker_count, marker_count == 1 and "" or "s")
    
    if r.ImGui_Button(ctx, button_label, button_width, 30) then
      selected_option = option_key
      ApplyPrediction(prediction, analysis_start_time, analysis_end_time)
    end
    
    -- Show BPM list
    if r.ImGui_BeginChild(ctx, "##bpm_list_" .. option_key, button_width, button_height - 35, r.ImGui_ChildFlags_Borders()) then
      if prediction.total_beats then
        r.ImGui_Text(ctx, string.format("%.2f beats", prediction.total_beats))
      end
      if prediction.error then
        r.ImGui_Text(ctx, string.format("Error: %.4f s", prediction.error))
      end
      if prediction.total_beats or prediction.error then
        r.ImGui_Separator(ctx)
      end
      for i, marker in ipairs(prediction.markers) do
        r.ImGui_BulletText(ctx, string.format("%.3f BPM", marker.bpm))
      end
    end
    r.ImGui_EndChild(ctx)
  else
    -- Empty state
    if r.ImGui_Button(ctx, label .. "\n--", button_width, 30) then
      -- No action when empty
    end
    
    if r.ImGui_BeginChild(ctx, "##empty_" .. option_key, button_width, button_height - 35, r.ImGui_ChildFlags_Borders()) then
      r.ImGui_TextDisabled(ctx, "No prediction")
    end
    r.ImGui_EndChild(ctx)
  end
  
  if is_selected then
    r.ImGui_PopStyleColor(ctx)
  end
  
  r.ImGui_EndGroup(ctx)
end

local function Loop()
  local visible, open = r.ImGui_Begin(ctx, "Predict Tempo Markers", true, window_flags)
  
  if visible then
    -- Configuration section
    r.ImGui_SeparatorText(ctx, "Configuration")
    
    -- 3-column layout: [beat count slider (flexible)] [beat type dropdown (fixed)] [per measure label (fixed)]
    local avail_width = r.ImGui_GetContentRegionAvail(ctx)
    local col2_width = 130 -- fixed dropdown
    local col3_width = 80  -- fixed label
    local spacing = 20
    local col1_width = avail_width - col2_width - col3_width - spacing
    
    r.ImGui_SetNextItemWidth(ctx, col1_width)
    local changed_bc, new_bc = r.ImGui_SliderInt(ctx, "##beat_count", beat_count, 1, 16)
    if changed_bc then
      beat_count = new_bc
    end
    
    r.ImGui_SameLine(ctx, 0, 10)
    
    r.ImGui_SetNextItemWidth(ctx, col2_width)
    if r.ImGui_BeginCombo(ctx, "##beat_type", beat_types[beat_type_index + 1]) then
      for i, name in ipairs(beat_types) do
        local is_selected = (beat_type_index == i - 1)
        if r.ImGui_Selectable(ctx, name, is_selected) then
          beat_type_index = i - 1
        end
        if is_selected then
          r.ImGui_SetItemDefaultFocus(ctx)
        end
      end
      r.ImGui_EndCombo(ctx)
    end
    
    r.ImGui_SameLine(ctx, 0, 10)
    r.ImGui_Text(ctx, "per measure")
    
    r.ImGui_SetNextItemWidth(ctx, col1_width)
    local changed_m, new_m = r.ImGui_SliderInt(ctx, "  Measures in time selection", measures, 1, 16)
    if changed_m then
      measures = new_m
    end
    
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Guess") then
      -- Calculate measures from time selection at baseline BPM (or project tempo if no analysis)
      local sel_start, sel_end = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
      if sel_end > sel_start then
        local duration = sel_end - sel_start
        local bpm_to_use = baseline_bpm or r.Master_GetTempo()
        local quarter_dur = 60 / bpm_to_use
        local beats_per_measure = beat_count
        local measure_dur = quarter_dur * beats_per_measure
        local guessed_measures = math.floor(duration / measure_dur + 0.5)
        if guessed_measures < 1 then guessed_measures = 1 end
        if guessed_measures > 16 then guessed_measures = 16 end
        measures = guessed_measures
      end
    end
    
    r.ImGui_Spacing(ctx)
    
    -- Navigation buttons
    if r.ImGui_Button(ctx, "Prev Transient") then
      r.Main_OnCommand(40376, 0)
    end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Next Transient") then
      r.Main_OnCommand(40375, 0)
    end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Set Start Point") then
      r.Main_OnCommand(40625, 0)
    end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Set End Point") then
      r.Main_OnCommand(40626, 0)
    end
    
    r.ImGui_Spacing(ctx)
    
    -- Tempo adjustment buttons
    if r.ImGui_Button(ctx, "-0.1 BPM") then
      local cmd = r.NamedCommandLookup("_BR_DEC_TEMPO_0.1_BPM")
      if cmd > 0 then r.Main_OnCommand(cmd, 0) end
    end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "+0.1 BPM") then
      local cmd = r.NamedCommandLookup("_BR_INC_TEMPO_0.1_BPM")
      if cmd > 0 then r.Main_OnCommand(cmd, 0) end
    end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Insert Empty Space") then
      r.Main_OnCommand(40200, 0)
    end
    r.ImGui_SameLine(ctx)
    local was_on = set_new_time_signature
    local toggle_label = was_on and "Set as New Time Signature ON" or "Set as New Time Signature OFF"
    if was_on then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x4A90D9FF)
    end
    if r.ImGui_Button(ctx, toggle_label) then
      set_new_time_signature = not set_new_time_signature
    end
    if was_on then
      r.ImGui_PopStyleColor(ctx)
    end
    
    r.ImGui_Spacing(ctx)
    
    -- Analyze and Shift buttons side by side
    local avail_width = r.ImGui_GetContentRegionAvail(ctx)
    local button_width = (avail_width - 5) / 2  -- 5px spacing between buttons
    
    if r.ImGui_Button(ctx, "Analyze Selection", button_width, 30) then
      AnalyzeSelection()
    end
    
    r.ImGui_SameLine(ctx)
    
    if r.ImGui_Button(ctx, "Shift Time Right", button_width, 30) then
      r.Main_OnCommand(40038, 0)  -- Move time selection right (by time selection length)
      -- Move cursor to end of new time selection
      local new_start, new_end = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
      r.SetEditCurPos(new_end, false, false)
      -- Scroll to center view
      local scroll_cmd = r.NamedCommandLookup("_SWS_HSCROLL50")
      if scroll_cmd > 0 then r.Main_OnCommand(scroll_cmd, 0) end
    end
    
    r.ImGui_Spacing(ctx)
    
    -- Predictions section
    r.ImGui_SeparatorText(ctx, "Predictions")
    
    -- Show baseline info if we've analyzed
    if baseline_bpm then
      local error_str = baseline_error and string.format(" | Error: %.4fs", baseline_error) or ""
      local dur_str = selection_duration and string.format(" | Dur: %.6fs", selection_duration) or ""
      r.ImGui_Text(ctx, string.format("Baseline: %.3f BPM | %d transients%s%s", baseline_bpm, transient_count, error_str, dur_str))
    else
      r.ImGui_TextDisabled(ctx, "Click 'Analyze Selection' to generate predictions")
    end
    
    r.ImGui_Spacing(ctx)
    
    -- Four prediction buttons side by side
    RenderPredictionButton("Baseline", predictions.Baseline, "Baseline")
    r.ImGui_SameLine(ctx, 0, 10)
    RenderPredictionButton("Option A", predictions.A, "A")
    r.ImGui_SameLine(ctx, 0, 10)
    RenderPredictionButton("Option B", predictions.B, "B")
    r.ImGui_SameLine(ctx, 0, 10)
    RenderPredictionButton("Option C", predictions.C, "C")
    
    r.ImGui_Spacing(ctx)
    
    -- Selection status
    if selected_option then
      local label = selected_option == "Baseline" and "Baseline" or string.format("Option %s", selected_option)
      r.ImGui_TextColored(ctx, 0x00FF00FF, string.format("Applied: %s", label))
    else
      r.ImGui_TextDisabled(ctx, "No prediction applied")
    end
    
    r.ImGui_End(ctx)
  end
  
  if open then
    r.defer(Loop)
  end
end

-- Startup: Select items on Kick, Snare, Toms tracks and run transient detection
local startup_done = false
local function StartupSelectDrumItems()
  if startup_done then return end
  startup_done = true
  
  local target_names = { "Kick", "Snare", "Toms" }
  local track_count = r.CountTracks(0)
  
  -- First deselect all items
  r.SelectAllMediaItems(0, false)
  
  -- Find and select items on target tracks
  for i = 0, track_count - 1 do
    local track = r.GetTrack(0, i)
    if track then
      local _, track_name = r.GetTrackName(track)
      for _, target in ipairs(target_names) do
        if track_name == target then
          -- Select all items on this track
          local item_count = r.CountTrackMediaItems(track)
          for j = 0, item_count - 1 do
            local item = r.GetTrackMediaItem(track, j)
            if item then
              r.SetMediaItemSelected(item, true)
            end
          end
          break
        end
      end
    end
  end
  
  -- Run action 42028 (Dynamic split items)
  r.Main_OnCommand(42028, 0)
  r.UpdateArrange()
end

-- Run startup on first defer (after script fully initialized)
r.defer(function()
  StartupSelectDrumItems()
  r.defer(Loop)
end)
