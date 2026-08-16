-- fcp_tracker_model_persistence.lua
-- ExtState load/save, variant-aware storage key format, and region name<->index
-- lookup for the Song Progress Tracker. Split out of fcp_tracker_model.lua.

local reaper = reaper
local ImGui  = reaper

-- Regions ---------------------------------------------------------------
-- Build a mapping from region name to current index
function build_region_name_to_index()
  local map = {}
  for i, reg in ipairs(REGIONS) do
    if reg.name then
      -- Use uppercase key for case-insensitive matching
      map[reg.name:upper()] = i
    end
  end
  return map
 end

-- Get region name by index (for saving)
-- Returns uppercase name for consistent key format
function get_region_name_by_index(ri)
  if REGIONS[ri] and REGIONS[ri].name then
    return REGIONS[ri].name:upper()
  end
  return nil
end

-- MIDI sources ----------------------------------------------------------
function first_midi_take_on_track(tr)
  if not tr then return end
  local n = reaper.CountTrackMediaItems(tr)
  for i = 0, n-1 do
    local it = reaper.GetTrackMediaItem(tr, i)
    local tk = reaper.GetActiveTake(it)
    if tk and reaper.TakeIsMIDI(tk) then return tk end
  end
end

-- Persistence -----------------------------------------------------------
-- Single classifier over the two new-format ExtState key shapes.

-- Mode keys per tab category.
local function mode_keys_for_tab(tab_name)
  if tab_name == "Vocals" then return DIFFS_VOX end
  if tab_name == "Venue"  then return DIFFS_VENUE end
  return DIFFS
end

local function tab_mode_valid(tab_name, mode)
  -- REAPER normalizes ExtState keys to uppercase on save; canonicalize
  -- the mode via DIFF_CANON so DIFFS / DIFFS_VOX / DIFFS_VENUE (proper-case) can match.
  local canon_mode = DIFF_CANON[mode:upper()] or mode
  for _, m in ipairs(mode_keys_for_tab(tab_name)) do
    if m == canon_mode then return true end
  end
  return false
end

-- Resolve the (tab, variant) tuple from a tab segment; single-variant tabs reject any suffix.
local function resolve_tab_variant(tab_segment)
  local colon = tab_segment:find(":", 1, true)
  local raw_tab, raw_variant
  if colon then
    raw_tab = tab_segment:sub(1, colon - 1)
    raw_variant = tab_segment:sub(colon + 1):lower()
    if raw_tab == "" or raw_variant == "" then return nil, nil end
  else
    raw_tab = tab_segment
  end
  -- REAPER normalizes ExtState keys to uppercase on save; canonicalize
  -- the tab part so TABS_BY_NAME (proper-case) can find it.
  raw_tab = TAB_CANON[raw_tab:upper()] or raw_tab
  local tab_obj = TABS_BY_NAME and TABS_BY_NAME[raw_tab]
  if not tab_obj then return nil, nil end
  if tab_obj.name == "Keys" then
    if raw_variant then
      if not tab_obj.variants[raw_variant] then return nil, nil end
      return tab_obj, raw_variant
    end
    return tab_obj, "regular"
  else
    if raw_variant then return nil, nil end
    return tab_obj, "regular"
  end
end

-- Classify and load a cell key. Returns true on success, false on ignore.
local function load_cell_key(key, val, name_to_idx)
  -- Cell key shape: <TAB>(:<VARIANT>)?|<MODE>|<REGION>
  local p1 = key:find("|", 1, true)
  if not p1 then return false end
  local tab_segment = key:sub(1, p1 - 1)
  local rest = key:sub(p1 + 1)
  local p2 = rest:find("|", 1, true)
  if not p2 then return false end
  local mode_segment = rest:sub(1, p2 - 1)
  local region_segment = rest:sub(p2 + 1)
  if tab_segment == "" or mode_segment == "" or region_segment == "" then return false end

  local tab_obj, variant = resolve_tab_variant(tab_segment)
  if not tab_obj then return false end
  if not tab_mode_valid(tab_obj.name, mode_segment) then return false end

  local ri = name_to_idx[region_segment:upper()]
  if not ri then return false end
  local st = tonumber(val or "")
  if not st then return false end

  -- REAPER uppercases the on-disk key; store the canonical mode in the
  -- in-memory tree so readers see the same proper-case keys they always did.
  local canon_mode = DIFF_CANON[mode_segment:upper()] or mode_segment
  SAVED[tab_obj.name] = SAVED[tab_obj.name] or {}
  SAVED[tab_obj.name][variant] = SAVED[tab_obj.name][variant] or {}
  SAVED[tab_obj.name][variant][canon_mode] = SAVED[tab_obj.name][variant][canon_mode] or {}
  SAVED[tab_obj.name][variant][canon_mode][ri] = st

  return true
end

-- Classify and load a TIME key. Ignore silently on any miss.
local function load_time_key(key, val, name_to_idx)
  -- TIME key shape: TIME|<TAB>(:<VARIANT>)?|<MODE>|<REGION>
  if key:sub(1, 5) ~= "TIME|" then return end
  local body = key:sub(6)
  local p1 = body:find("|", 1, true)
  if not p1 then return end
  local tab_segment = body:sub(1, p1 - 1)
  local rest = body:sub(p1 + 1)
  local p2 = rest:find("|", 1, true)
  if not p2 then return end
  local mode_segment = rest:sub(1, p2 - 1)
  local region_segment = rest:sub(p2 + 1)
  if tab_segment == "" or mode_segment == "" or region_segment == "" then return end

  local tab_obj, variant = resolve_tab_variant(tab_segment)
  if not tab_obj then return end
  if not tab_mode_valid(tab_obj.name, mode_segment) then return end

  local ri = name_to_idx[region_segment:upper()]
  local secs = tonumber(val or "")
  if not (ri and secs) then return end

  -- REAPER uppercases the on-disk key; store the canonical mode in the
  -- in-memory tree so readers see the same proper-case keys they always did.
  local canon_mode = DIFF_CANON[mode_segment:upper()] or mode_segment
  REGION_TIME[tab_obj.name] = REGION_TIME[tab_obj.name] or {}
  REGION_TIME[tab_obj.name][variant] = REGION_TIME[tab_obj.name][variant] or {}
  REGION_TIME[tab_obj.name][variant][canon_mode] = REGION_TIME[tab_obj.name][variant][canon_mode] or {}
  REGION_TIME[tab_obj.name][variant][canon_mode][ri] = secs

end

local function load_from(proj)
  local name_to_idx = build_region_name_to_index()
  local i = 0
  while true do
    local ok, key, val = reaper.EnumProjExtState(proj, EXTNAME, i)
    if not ok then break end
    i = i + 1
    if type(key) == "string" then
      if key:sub(1, 5) == "TIME|" then
        load_time_key(key, val, name_to_idx)
      elseif key:find("|", 1, true) then
        load_cell_key(key, val, name_to_idx)
      end
    end
  end
end

function load_all_saved_states()
  SAVED = {}
  REGION_TIME = {}
  load_from(0)
  -- Startup summary: counts and contents of
  -- the in-memory SAVED and REGION_TIME tables only.
  local function dump_tree(tree)
    if not tree then return "<empty>" end
    local parts = {}
    for k, v in pairs(tree) do
      if type(v) == "table" then
        parts[#parts+1] = tostring(k) .. "=" .. dump_tree(v)
      else
        parts[#parts+1] = tostring(k) .. "=" .. tostring(v)
      end
    end
    return table.concat(parts, ",")
  end
  local function count_loaded_cells(tree)
    local count = 0
    if not tree then return 0 end
    for _, variants in pairs(tree) do
      if type(variants) == "table" then
        for _, modes in pairs(variants) do
          if type(modes) == "table" then
            for _, regions in pairs(modes) do
              if type(regions) == "table" then
                for _ in pairs(regions) do count = count + 1 end
              end
            end
          end
        end
      end
    end
    return count
  end
  local loaded_cell_keys = count_loaded_cells(SAVED)
  local cur_tab = current_tab
  local cur_variant = "regular"
  local cur_obj = current_tab_obj and current_tab_obj()
  if cur_obj and cur_obj.current_variant_key then
    cur_variant = cur_obj:current_variant_key()
  end
end

function save_region_time(tab, diff, ri, secs)
  local region_name = get_region_name_by_index(ri)
  if not region_name then return end
  -- Build the variant-aware on-disk key; Keys gets the :pro suffix.
  local obj = TABS_BY_NAME and TABS_BY_NAME[tab]
  local variant = (obj and obj.name == current_tab and obj:current_variant_key()) or "regular"
  local tab_part = (tab == "Keys" and variant == "pro") and "Keys:pro" or tab
  local k = ("TIME|%s|%s|%s"):format(tab_part, diff, region_name):upper()
  reaper.SetProjExtState(0, EXTNAME, k, tostring(secs))
  -- Read-back probe: verify the write landed in extstate.
  local _, rb = reaper.GetProjExtState(0, EXTNAME, k)
end

function get_region_time(tab, diff, ri)
  -- Variant-aware read; non-current tabs default to "regular".
  local obj = TABS_BY_NAME and TABS_BY_NAME[tab]
  local variant = (obj and obj.name == current_tab and obj:current_variant_key()) or "regular"
  local v = (REGION_TIME[tab] and REGION_TIME[tab][variant] and REGION_TIME[tab][variant][diff] and REGION_TIME[tab][variant][diff][ri]) or 0

  return v
end

-- Variant-aware storage key: "Tab:variant|mode|region" or "Tab|mode|region".
local function storage_key_for(tab, variant_key_or_nil, diff, region_name)
  local tab_part = tab
  if variant_key_or_nil and variant_key_or_nil:find(":", 1, true) then
    -- Has explicit variant suffix; keep it
    tab_part = variant_key_or_nil
  end
  return ("%s|%s|%s"):format(tab_part, diff, region_name)
end

-- Save a cell via the variant-aware key; variant comes from the arg or the Tab object.
function save_cell_state_v2(tab, variant_key_or_nil, diff, ri, state)
  tab  = TAB_CANON[(tab:upper())]   or tab
  diff = DIFF_CANON[(diff:upper())] or diff
  local region_name = get_region_name_by_index(ri)
  if not region_name then return end
  -- Resolve variant from arg (short or colon form) or the queried Tab object.
  local variant = "regular"
  if variant_key_or_nil and variant_key_or_nil ~= "" then
    if variant_key_or_nil:sub(-4) == ":pro" or variant_key_or_nil == "pro" then
      variant = "pro"
    elseif variant_key_or_nil:sub(-9) == ":regular" or variant_key_or_nil == "regular" then
      variant = "regular"
    end
  else
    local obj = TABS_BY_NAME and TABS_BY_NAME[tab]
    if obj and obj.current_variant_key then
      variant = obj:current_variant_key()
    end
  end
  -- Build the on-disk key. For Keys: "Keys:pro|..." or
  -- "Keys:regular|...". For other tabs: "<tab>|...".
  local tab_part = tab
  if tab == "Keys" then
    tab_part = (variant == "pro") and "Keys:pro" or "Keys:regular"
  end
  local k = ("%s|%s|%s"):format(tab_part, diff, region_name):upper()
  reaper.SetProjExtState(0, EXTNAME, k, tostring(state))
  -- Read-back probe: verify the write landed in extstate.
  local _, rb = reaper.GetProjExtState(0, EXTNAME, k)

  -- Update the in-memory SAVED tree
  SAVED[tab] = SAVED[tab] or {}
  SAVED[tab][variant] = SAVED[tab][variant] or {}
  SAVED[tab][variant][diff] = SAVED[tab][variant][diff] or {}
  SAVED[tab][variant][diff][ri] = state
  if state == 2 then
    local sig_val = PROGRESS_SIG[tab] and PROGRESS_SIG[tab][variant] and PROGRESS_SIG[tab][variant][diff] and PROGRESS_SIG[tab][variant][diff][ri] or 0
    COMPLETE_SIG[tab] = COMPLETE_SIG[tab] or {}
    COMPLETE_SIG[tab][variant] = COMPLETE_SIG[tab][variant] or {}
    COMPLETE_SIG[tab][variant][diff] = COMPLETE_SIG[tab][variant][diff] or {}
    COMPLETE_SIG[tab][variant][diff][ri] = sig_val
  end
end

-- Standard save entry point: resolve variant from the queried tab and delegate.
function save(tab, diff, ri, state)
  local obj = TABS_BY_NAME and TABS_BY_NAME[tab]
  local variant = (obj and obj.current_variant_key) and obj:current_variant_key() or "regular"
  save_cell_state_v2(tab, variant, diff, ri, state)
end
