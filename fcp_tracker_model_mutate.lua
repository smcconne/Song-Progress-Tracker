-- fcp_tracker_model_mutate.lua
-- State-machine transitions over STATE for the Song Progress Tracker.
-- Split out of fcp_tracker_model.lua.

local reaper = reaper
local ImGui  = reaper

-- Merge rules / state ---------------------------------------------------
local function row_has_progress(tab, row)
  local diffs = (tab=="Vocals") and DIFFS_VOX or DIFFS
  -- Read from the regular variant; these helpers never run for the Keys pro variant.
  local variant = "regular"
  for _,d in ipairs(diffs) do
    local st = STATE[tab] and STATE[tab][variant] and STATE[tab][variant][d] and STATE[tab][variant][d][row]
    if st == 1 or st == 2 then return true end
  end
  return false
end

function apply_toggle(tab, diff, r)
  -- Variant comes from the active Tab object; caller passes the canonical mode key.
  local obj = TABS_BY_NAME and TABS_BY_NAME[tab]
  local variant = "regular"
  if obj and obj.current_variant_key then
    variant = obj:current_variant_key()
  end

  local st = (STATE[tab] and STATE[tab][variant] and STATE[tab][variant][diff] and STATE[tab][variant][diff][r]) or 0
  local nxt = st
  if st == 1 then
    nxt = 2
  elseif st == 2 then
    nxt = 1
  elseif st == 0 then
    local live = PROGRESS[tab] and PROGRESS[tab][variant] and PROGRESS[tab][variant][diff] and PROGRESS[tab][variant][diff][r]
    if live then
      -- Notes exist for this cell: advance to In Progress
      nxt = 1
    else
      -- No notes for this cell: apply the Empty (linked) logic per tab
      if tab == "Vocals" then
        -- For Vocals: check if ANY of H1/H2/H3/V have notes in this region
        local any_live = false
        for _,d in ipairs(DIFFS_VOX) do
          if PROGRESS.Vocals and PROGRESS.Vocals["regular"] and PROGRESS.Vocals["regular"][d] and PROGRESS.Vocals["regular"][d][r] then
            any_live = true
            break
          end
        end
        if not any_live then
          -- None have notes: set all to Empty (linked)
          for _,d in ipairs(DIFFS_VOX) do
            STATE.Vocals["regular"][d] = STATE.Vocals["regular"][d] or {}
            STATE.Vocals["regular"][d][r] = 3
            save(tab, d, r, 3)
          end
        else
          -- Some have notes: set this cell to Empty
          STATE[tab][variant][diff][r] = 3
          save(tab, diff, r, 3)
        end
      elseif tab == "Venue" then
        -- For Venue: only set current cell to Empty
        STATE[tab][variant][diff][r] = 3
        save(tab, diff, r, 3)
      else
        -- For instruments: link rows to Empty if no other progress
        if not row_has_progress(tab, r) then
          for _,d in ipairs(DIFFS) do
            STATE[tab][variant][d] = STATE[tab][variant][d] or {}
            STATE[tab][variant][d][r] = 3
            save(tab, d, r, 3)
          end
        end
      end
    end
  elseif st == 3 then
    -- For Vocals and Venue: only set current cell to Not Started, not the whole row
    if tab == "Vocals" or tab == "Venue" then
      STATE[tab][variant][diff][r] = 0
      save(tab, diff, r, 0)
      nxt = 0
    else
      local diffs = DIFFS
      for _,d in ipairs(diffs) do
        STATE[tab][variant][d] = STATE[tab][variant][d] or {}
        STATE[tab][variant][d][r] = 0
        save(tab, d, r, 0)
      end
      nxt = 0
    end
  end
  local live = PROGRESS[tab] and PROGRESS[tab][variant] and PROGRESS[tab][variant][diff] and PROGRESS[tab][variant][diff][r] or false
  if (nxt == 1 or nxt == 2) and not live then nxt = 0 end
  if nxt ~= st then
    STATE[tab][variant][diff][r] = nxt
    save(tab, diff, r, nxt)
  end
end
