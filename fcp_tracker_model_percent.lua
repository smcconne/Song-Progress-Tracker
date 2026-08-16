-- fcp_tracker_model_percent.lua
-- Read-only percent calculations and auto-select-difficulty for the
-- Song Progress Tracker. Split out of fcp_tracker_model.lua.

local reaper = reaper
local ImGui  = reaper

-- Cursors and percent ---------------------------------------------------
function diff_pct(tab, diff)
  local num, den = 0, 0
  -- Variant comes from the queried Tab object, not current_tab.
  local obj = TABS_BY_NAME and TABS_BY_NAME[tab]
  local variant = (obj and obj:current_variant_key()) or "regular"
  local row = STATE[tab] and STATE[tab][variant] and STATE[tab][variant][diff]
  if row then
    for r = 1, #REGIONS do
      local st = row[r] or 0
      if st ~= 3 then
        den = den + 3
        if     st == 2 then num = num + 3
        elseif st == 1 then num = num + 1 end
      end
    end
  end
  return (den > 0) and math.floor((num/den)*100) or 0
end

-- Check if all cells for a tab/diff are Empty (state 3)
-- Returns true if all cells are Empty (or no regions exist)
function is_all_empty(tab, diff)
  -- Look up STATE[tab][variant][diff]; resolve variant from the Tab object.
  local obj = TABS_BY_NAME and TABS_BY_NAME[tab]
  local variant = (obj and obj:current_variant_key()) or "regular"
  local row = STATE[tab] and STATE[tab][variant] and STATE[tab][variant][diff]
  if not row then return true end
  for r = 1, #REGIONS do
    local st = row[r] or 0
    if st ~= 3 then
      return false
    end
  end
  return true
end

-- Weighted overall completion for instrument tabs
-- X=50%, H=25%, M=15%, E=10%
function weighted_tab_pct(tab)
  local weights = { Expert=0.50, Hard=0.25, Medium=0.15, Easy=0.10 }

  -- The Tab object determines whether we're on the pro variant.
  local obj = TABS_BY_NAME and TABS_BY_NAME[tab]
  local is_pro = obj and obj:is_pro() or false

  -- For Keys tab with Pro Keys active, use the pro variant
  if tab == "Keys" and is_pro then
    local total = 0
    for mkey, weight in pairs(weights) do
      local pct = 0
      local row = STATE["Keys"] and STATE["Keys"]["pro"] and STATE["Keys"]["pro"][mkey]
      if row then
        local num, den = 0, 0
        for r = 1, #REGIONS do
          local st = row[r] or 0
          if st ~= 3 then
            den = den + 3
            if     st == 2 then num = num + 3
            elseif st == 1 then num = num + 1 end
          end
        end
        if den > 0 then pct = (num / den) * 100 end
      end
      total = total + (pct * weight)
    end
    return math.floor(total)
  end

  -- For standard instrument tabs (Drums, Bass, Guitar, Keys regular)
  if tab == "Drums" or tab == "Bass" or tab == "Guitar" or tab == "Keys" then
    local total = 0
    for diff, weight in pairs(weights) do
      local pct = 0
      local row = STATE[tab] and STATE[tab]["regular"] and STATE[tab]["regular"][diff]
      if row then
        local num, den = 0, 0
        for r = 1, #REGIONS do
          local st = row[r] or 0
          if st ~= 3 then
            den = den + 3
            if     st == 2 then num = num + 3
            elseif st == 1 then num = num + 1 end
          end
        end
        if den > 0 then pct = (num / den) * 100 end
      end
      total = total + (pct * weight)
    end
    return math.floor(total)
  end

  -- For other tabs (Vocals, Venue, Overdrive), return 0
  return 0
end

-- Overdrive completion: 67% from instrument OV placement, 33% from drum fill placement.
function overdrive_completion_pct()
  local first_m = OVERDRIVE_MEASURES.first or 1
  local last_m = OVERDRIVE_MEASURES.last or 1
  
  -- Effective last measure (exclude last 16 measures from requirement)
  local effective_last = math.max(first_m, last_m - 16)
  local range = effective_last - first_m
  if range <= 0 then return 100 end  -- No range to fill
  
  -- Calculate overdrive progress for each instrument (25% each of 67%)
  local total_od_progress = 0
  for _, row in ipairs(OVERDRIVE_ROWS) do
    local data = OVERDRIVE_DATA[row]
    if data then
      -- Check last 16 measures first - any placement there = 100% for this instrument
      local in_final_16 = false
      for m = last_m, effective_last + 1, -1 do
        if data[m] then
          in_final_16 = true
          break
        end
      end
      
      local inst_progress = 0
      if in_final_16 then
        inst_progress = 1
      else
        -- Find furthest-right placement within effective range
        for m = effective_last, first_m, -1 do
          if data[m] then
            inst_progress = (m - first_m) / range
            break
          end
        end
      end
      
      inst_progress = math.min(1, math.max(0, inst_progress))
      total_od_progress = total_od_progress + (inst_progress * 0.25)  -- 25% each
    end
  end
  
  -- Find furthest-right drum fill placement
  -- Check last 16 measures first - any placement there = 100%
  local fill_in_final_16 = false
  local fill_data = OVERDRIVE_FILL["Drums"]
  if fill_data then
    for m = last_m, effective_last + 1, -1 do
      if fill_data[m] then
        fill_in_final_16 = true
        break
      end
    end
  end
  
  local max_fill_measure = 0
  if not fill_in_final_16 and fill_data then
    for m = effective_last, first_m, -1 do
      if fill_data[m] then
        max_fill_measure = m
        break
      end
    end
  end
  
  -- Calculate percentages for each factor
  local fill_progress = fill_in_final_16 and 1 or ((max_fill_measure > 0) and ((max_fill_measure - first_m) / range) or 0)
  
  -- Clamp to 0-1 range, then combine: 67% OD (split 4 ways) + 33% fill
  fill_progress = math.min(1, math.max(0, fill_progress))
  
  local combined = (total_od_progress * 0.67) + (fill_progress * 0.33)
  return math.floor(combined * 100)
end
