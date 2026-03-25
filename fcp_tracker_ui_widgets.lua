-- fcp_tracker_ui_widgets.lua
-- Custom button widgets for Song Progress UI

local reaper = reaper
local ImGui  = reaper

-- Requires globals from fcp_tracker_ui_helpers.lua: pct_scaled_u32, lighten_u32, COL_TEXT
-- Requires globals from fcp_tracker_config.lua: BTN_W

-- Computed locally, depends on BTN_W from config
local PAIR_W = math.floor(BTN_W * 1.6 + 0.5)

function get_PAIR_W()
  return PAIR_W
end

-- Tooltip data for difficulty buttons (advice only, header is generated dynamically)
local DIFF_TOOLTIPS = {
  ProKeys = {
    Expert = "• Up to 4-note chords, spanning 1 octave max\n" ..
             "• 16th note space between sustained notes, 8th >140bpm\n" ..
             "• 8th gap between chords\n" ..
             "• Broken chords allowed up to 4 notes sustained at a time\n" ..
             "• Chart new keyboard layers as they are introduced\n" ..
             "• Avoid playing simultaneous keyboard parts \n" ..
             "• Listen for subtle layers",
    Hard = "• 3-note chords max, span of 7th (11 semitones)\n" ..
           "• Avoid jumps > 7th\n" ..
           "• Usually remove >= 16th notes\n" ..
           "• Thin 8ths to groups of 7 >110 bpm, groups of 3 >140 bpm\n" ..
           "• No glissando/trill\n" ..
           "• Lane shifts allowed, but remove if possible",
    Medium = "• 1/8th note space between sustained notes\n" ..
             "• 1/4 note space between chords\n" ..
             "• 2-note chords max, span of 6th (9 semitones)\n" ..
             "• Avoid jumps > 6th\n" ..
             "• No lane shifts",
    Easy = "• Half note space between playable notes\n" ..
           "• 1/4 note space between sustained notes\n" ..
           "• No chords\n" ..
           "• Avoid jumps > 5th (7 semitones)"
  },
  Keys = {
    Expert = "• [g]Green[/g] + [o]Orange[/o] chords allowed\n" ..
             "• Broken chords allowed\n" ..
             "• Chart new keyboard layers as they are introduced\n" ..
             "• Avoid playing simultaneous keyboard parts \n" ..
             "• Listen for subtle layers",
    Hard = "• Usually remove >= 16th notes\n" ..
           "• Retain chords\n" ..
           "• Avoid quick [g]Green[/g] to [o]Orange[/o] jumps\n" ..
           "• No 3-note or [g]Green[/g]/[o]Orange[/o] chords\n" ..
           "• Thin 8ths to groups of 7 >110 bpm, groups of 3 >140 bpm",
    Medium = "• Notes on strong quarter note beats\n" ..
             "• Retain chords from Hard\n" ..
             "• No 3-note chords\n" ..
             "• 8th note gap between notes\n" ..
             "• 1/4 gap between chords",
    Easy = "• 1/2 notes\n" ..
           "• No chords"
  },
  Drums = {
    Expert = "• Use mk_slicer for [o]kick[/o], [y]t[/y][b]o[/b][g]m[/g]s, [r]snare[/r]\n" ..
             "• [o]2x bass pedal[/o] for >2 consecutive 16ths\n" ..
             "• With [o]heel-toe[/o], can hit steady 8ths or a couple 16ths on single pedal",
    Hard = "• Complete limb independence\n" ..
           "• Steady right-hand rhythm, just [o]kicks[/o] and [r]snares[/r] in between.\n" ..
           "• 2 consecutive 16ths allowed <140 bpm (except two [o]kicks[/o])\n" ..
           "• Remove [o]kicks[/o] during fills\n" ..
           "• Avoid [o]kicks[/o] under [g]crashes[/g] (allowed when gems are sparse)\n" ..
           "• No fast hand crosses\n" ..
           "• Thin 8ths to groups of 7 >110 bpm, groups of 3 >140 bpm",
    Medium = "• No [o]kicks[/o]/[r]snares[/r] between [y]hihat[/y]/[b]ride[/b] gems\n" ..
             "• No 3-limb hits, must be playable with one hand\n" ..
             "• <140 bpm: 8ths ok\n" ..
             "• >110 bpm: [o]kicks[/o] only on quarter notes\n" ..
             "• >170 bpm: one [o]kick[/o] per measure\n" ..
             "• Only downbeat [g]crashes[/g] with [o]kick[/o]",
    Easy = "• No gems with [o]kick[/o]\n" ..
           "• 2-hand beat (no [o]kick[/o]) OR [o]kick[/o] + [r]snare[/r] only\n" ..
           "• Favor crashes instead of [o]kicks[/o]\n" ..
           "• >170 bpm: one [o]kick[/o] per measure\n" ..
           "• Reduce 8th fills to quarter notes at tempo"
  },
  GuitarBass = {
    Expert = "• No 3-note chords with [g]Green[/g] + [o]Orange[/o]\n" ..
             "• 16th note space between sustains, 8th at >140 bpm",
    Hard = "• Usually remove >= 16th notes\n" ..
           "• Thin 8ths to groups of 7 >110 bpm, groups of 3 >140 bpm\n" ..
           "• Only 2 note chords allowed\n" ..
           "• Avoid quick [g]Green[/g] to [o]Orange[/o] jumps",
    Medium = "• Try for quarter notes\n" ..
             "• Maintain 4 lanes at a time\n" ..
             "• Avoid [g]G[/g]-[b]B[/b], [g]G[/g]-[o]O[/o], [r]R[/r]-[o]O[/o] chords and jumps\n" ..
             "• Avoid fast chord changes\n" ..
             "• 1/4 note between sustains",
    Easy = "• 1/2 note spaces\n" ..
           "• 1/4 note between sustains\n" ..
           "• No chords\n" ..
           "• Maintain 3 lanes at a time"
  }
}

-- Get tooltip for current tab and difficulty
local function get_diff_tooltip(diff)
  local category
  if current_tab == "Keys" and PRO_KEYS_ACTIVE then
    category = "ProKeys"
  elseif current_tab == "Keys" then
    category = "Keys"
  elseif current_tab == "Drums" then
    category = "Drums"
  elseif current_tab == "Guitar" or current_tab == "Bass" then
    category = "GuitarBass"
  else
    return nil
  end
  
  return DIFF_TOOLTIPS[category] and DIFF_TOOLTIPS[category][diff]
end

-- Color tag lookup for tooltip rendering: [g]...[/g], [r]...[/r], etc.
local TAG_COLORS = {
  g = ImGui.ImGui_ColorConvertDouble4ToU32(0.18, 0.85, 0.18, 1.0),  -- Green
  r = ImGui.ImGui_ColorConvertDouble4ToU32(0.90, 0.20, 0.20, 1.0),  -- Red
  y = ImGui.ImGui_ColorConvertDouble4ToU32(0.95, 0.90, 0.15, 1.0),  -- Yellow
  b = ImGui.ImGui_ColorConvertDouble4ToU32(0.20, 0.50, 0.95, 1.0),  -- Blue
  o = ImGui.ImGui_ColorConvertDouble4ToU32(0.95, 0.55, 0.10, 1.0),  -- Orange
}

-- Render text with [g]...[/g] style color tags using DrawList for correct wrapping
local function render_colored_text(ctx, text)
  local dl = ImGui.ImGui_GetWindowDrawList(ctx)
  local default_col = COL_TEXT
  local line_step = ImGui.ImGui_GetTextLineHeightWithSpacing(ctx)
  local avail_w = ImGui.ImGui_GetContentRegionAvail(ctx)
  local space_w = ImGui.ImGui_CalcTextSize(ctx, " ")
  local sx, sy = ImGui.ImGui_GetCursorScreenPos(ctx)
  local cy = sy

  for line in (text .. "\n"):gmatch("(.-)\n") do
    -- Pass 1: parse into flat runs {text, color} with tags stripped
    local runs = {}
    local pos = 1
    while pos <= #line do
      local ts, te, tc = line:find("%[([groyb])%]", pos)
      if ts then
        if ts > pos then
          runs[#runs+1] = {line:sub(pos, ts - 1), default_col}
        end
        local cs, ce = line:find("%[/" .. tc .. "%]", te + 1)
        if cs then
          runs[#runs+1] = {line:sub(te + 1, cs - 1), TAG_COLORS[tc]}
          pos = ce + 1
        else
          runs[#runs+1] = {line:sub(pos, te), default_col}
          pos = te + 1
        end
      else
        runs[#runs+1] = {line:sub(pos), default_col}
        break
      end
    end

    -- Pass 2: split runs into word groups separated by spaces
    -- Each group is a list of {text, color} sub-runs forming one "word"
    local groups = {}      -- list of {sub_runs, total_w, space_before}
    local cur_group = {}   -- sub-runs for current word
    local had_space = false

    for _, run in ipairs(runs) do
      local rtxt, rcol = run[1], run[2]
      local ri = 1
      while ri <= #rtxt do
        local si = rtxt:find(" ", ri)
        if si then
          -- Text before the space belongs to current group
          if si > ri then
            cur_group[#cur_group+1] = {rtxt:sub(ri, si - 1), rcol}
          end
          -- Finish current group if non-empty
          if #cur_group > 0 then
            local tw = 0
            for _, sr in ipairs(cur_group) do
              tw = tw + ImGui.ImGui_CalcTextSize(ctx, sr[1])
            end
            groups[#groups+1] = {cur_group, tw, had_space}
            cur_group = {}
          end
          had_space = true
          ri = si + 1
        else
          -- Rest of run is part of current word
          cur_group[#cur_group+1] = {rtxt:sub(ri), rcol}
          break
        end
      end
    end
    -- Flush last group
    if #cur_group > 0 then
      local tw = 0
      for _, sr in ipairs(cur_group) do
        tw = tw + ImGui.ImGui_CalcTextSize(ctx, sr[1])
      end
      groups[#groups+1] = {cur_group, tw, had_space}
    end

    -- Pass 3: render word groups with wrapping
    local cx = sx
    local max_x = sx + avail_w

    for _, grp in ipairs(groups) do
      local sub_runs, tw, sp = grp[1], grp[2], grp[3]
      local needed = tw + (sp and space_w or 0)
      if cx + needed > max_x and cx > sx then
        cy = cy + line_step
        cx = sx
        sp = false
      end
      if sp then cx = cx + space_w end
      for _, sr in ipairs(sub_runs) do
        local sw = ImGui.ImGui_CalcTextSize(ctx, sr[1])
        ImGui.ImGui_DrawList_AddText(dl, cx, cy, sr[2], sr[1])
        cx = cx + sw
      end
    end

    cy = cy + line_step
  end

  ImGui.ImGui_Dummy(ctx, avail_w, cy - sy)
end

-- Difficulty square button (colored by progress percentage)
-- force_grey: if true, uses grey color instead of progress-based color
function DiffSquareButton(ctx, label, diff, is_active, custom_w, force_grey)
  -- For Pro Keys mode, pass the correct format to diff_pct
  local pct_diff = diff
  if current_tab == "Keys" and PRO_KEYS_ACTIVE then
    local diff_map = { Expert="X", Hard="H", Medium="M", Easy="E" }
    pct_diff = "Pro " .. (diff_map[diff] or "X")
  end
  local pct = diff_pct(current_tab, pct_diff)
  
  local base, hover, held, border_col
  if force_grey then
    -- Grey colors for empty tracks
    local grey_val = is_active and 0.5 or 0.35
    local grey_hover = is_active and 0.6 or 0.45
    local grey_held = is_active and 0.45 or 0.30
    base   = ImGui.ImGui_ColorConvertDouble4ToU32(grey_val, grey_val, grey_val, 1.0)
    hover  = ImGui.ImGui_ColorConvertDouble4ToU32(grey_hover, grey_hover, grey_hover, 1.0)
    held   = ImGui.ImGui_ColorConvertDouble4ToU32(grey_held, grey_held, grey_held, 1.0)
    border_col = ImGui.ImGui_ColorConvertDouble4ToU32(0.25, 0.25, 0.25, 1.0)
  else
    base   = is_active and pct_scaled_u32(pct, 0.85, 1.0) or pct_scaled_u32(pct, 0.55, 1.0)
    hover  = is_active and pct_scaled_u32(pct, 1.00, 1.0) or pct_scaled_u32(pct, 0.70, 1.0)
    held   = is_active and pct_scaled_u32(pct, 0.78, 1.0) or pct_scaled_u32(pct, 0.50, 1.0)
    border_col = pct_scaled_u32(pct, 0.35, 1.0)
  end

  local w = custom_w or BTN_W
  local h = ImGui.ImGui_GetFrameHeight(ctx)
  local x, y = ImGui.ImGui_GetCursorScreenPos(ctx)

  ImGui.ImGui_InvisibleButton(ctx, "diffbtn|"..label, w, h)
  local hovered = ImGui.ImGui_IsItemHovered(ctx)
  local active  = ImGui.ImGui_IsItemActive(ctx)
  local clicked = ImGui.ImGui_IsItemClicked(ctx)

  -- Show tooltip on hover (positioned below button, left edge at window left)
  if hovered then
    local tooltip = get_diff_tooltip(diff)
    if tooltip then
      local tooltip_w = 194  -- Fixed width for wrapping
      
      -- Position: below the button, left edge at window left edge
      local win_x, _ = ImGui.ImGui_GetWindowPos(ctx)
      local btn_bottom = y + h  -- y is button top, h is button height
      
      ImGui.ImGui_SetNextWindowPos(ctx, win_x, btn_bottom + 5)
      ImGui.ImGui_SetNextWindowSize(ctx, tooltip_w, 0)  -- 0 height = auto
      
      ImGui.ImGui_BeginTooltip(ctx)
      
      -- Build header: "Expert Keys" or "Expert Pro Keys"
      local instrument_name = current_tab
      if current_tab == "Keys" and PRO_KEYS_ACTIVE then
        instrument_name = "Pro Keys"
      end
      local header_text = diff .. " " .. instrument_name
      local pct_text = tostring(pct) .. "%"
      
      -- Left-aligned header
      ImGui.ImGui_Text(ctx, header_text)
      
      -- Right-aligned percentage on same line, colored by percentage
      ImGui.ImGui_SameLine(ctx)
      local avail_w = ImGui.ImGui_GetContentRegionAvail(ctx)
      local pct_w = ImGui.ImGui_CalcTextSize(ctx, pct_text)
      ImGui.ImGui_SetCursorPosX(ctx, ImGui.ImGui_GetCursorPosX(ctx) + avail_w - pct_w)
      
      local pct_col = pct_scaled_u32(pct, 1.0, 1.0)
      ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), pct_col)
      ImGui.ImGui_Text(ctx, pct_text)
      ImGui.ImGui_PopStyleColor(ctx)
      
      -- Separator and advice text
      ImGui.ImGui_Separator(ctx)
      ImGui.ImGui_PushTextWrapPos(ctx, tooltip_w - 10)
      render_colored_text(ctx, tooltip)
      ImGui.ImGui_PopTextWrapPos(ctx)
      
      ImGui.ImGui_EndTooltip(ctx)
    end
  end

  local dl = ImGui.ImGui_GetWindowDrawList(ctx)
  local fill = base
  if hovered then fill = hover end
  if active  then fill = held  end

  ImGui.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, fill, 4)
  ImGui.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, border_col, 4, 0, 1)

  local tw, th = ImGui.ImGui_CalcTextSize(ctx, label)
  ImGui.ImGui_DrawList_AddText(dl, x + (w - tw)*0.5, y + (h - th)*0.5 - 1, COL_TEXT, label)
  return clicked
end

-- Pair square button (gray, for Toms/HOPOs/Rolls/Trills)
function PairSquareButton(ctx, label, is_active, w)
  local bw = w or PAIR_W
  local h  = ImGui.ImGui_GetFrameHeight(ctx)
  local x, y = ImGui.ImGui_GetCursorScreenPos(ctx)

  local base  = is_active and ImGui.ImGui_ColorConvertDouble4ToU32(0.50,0.50,0.50,1)
                         or ImGui.ImGui_ColorConvertDouble4ToU32(0.30,0.30,0.30,1)
  local hover = lighten_u32(base, 0.25)
  local held  = lighten_u32(base, 0.10)

  ImGui.ImGui_InvisibleButton(ctx, "pair|"..label, bw, h)
  local hovered = ImGui.ImGui_IsItemHovered(ctx)
  local active  = ImGui.ImGui_IsItemActive(ctx)
  local clicked = ImGui.ImGui_IsItemClicked(ctx)

  local dl   = ImGui.ImGui_GetWindowDrawList(ctx)
  local fill = base
  if hovered then fill = hover end
  if active  then fill = held  end

  ImGui.ImGui_DrawList_AddRectFilled(dl, x, y, x+bw, y+h, fill, 4)
  ImGui.ImGui_DrawList_AddRect(dl, x, y, x+bw, y+h, lighten_u32(base, 0.05), 4, 0, 1)

  local tw, th = ImGui.ImGui_CalcTextSize(ctx, label)
  ImGui.ImGui_DrawList_AddText(dl, x + (bw - tw)*0.5, y + (h - th)*0.5, COL_TEXT, label)
  return clicked
end

-- Generic pair-like button (for Align, Focus, Screenset, MIDI)
function PairLikeButton(ctx, id, label, w, is_active)
  local base_active   = ImGui.ImGui_ColorConvertDouble4ToU32(0.50, 0.50, 0.50, 1.0)
  local base_inactive = ImGui.ImGui_ColorConvertDouble4ToU32(0.22, 0.22, 0.22, 1.0)

  local h = ImGui.ImGui_GetFrameHeight(ctx)
  local x, y = ImGui.ImGui_GetCursorScreenPos(ctx)

  ImGui.ImGui_InvisibleButton(ctx, id, w, h)
  local hovered = ImGui.ImGui_IsItemHovered(ctx)
  local held    = ImGui.ImGui_IsItemActive(ctx)
  local clicked = ImGui.ImGui_IsItemClicked(ctx)

  local fill = is_active and base_active or base_inactive
  if hovered then fill = lighten_u32(fill, 0.20) end
  if held    then fill = lighten_u32(fill, 0.10) end

  local dl = ImGui.ImGui_GetWindowDrawList(ctx)
  ImGui.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, fill, 4)
  ImGui.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, lighten_u32(fill, 0.05), 4, 0, 1)

  local tw, th = ImGui.ImGui_CalcTextSize(ctx, label)
  ImGui.ImGui_DrawList_AddText(dl, x + (w - tw)*0.5, y + (h - th)*0.5, COL_TEXT, label)

  return clicked
end

-- Global drag state for Listen button volume control
LISTEN_DRAG_STATE = LISTEN_DRAG_STATE or {
  dragging = false,
  start_y = 0,
  start_vol = 0,
}

-- Global flag to suppress paint-toggle while Listen button is being dragged
LISTEN_DRAG_ACTIVE = false

-- dB range for Listen button handle
local LISTEN_DB_MIN = -40   -- bottom of range (treat as -inf)
local LISTEN_DB_MAX = -12   -- top of range
local LISTEN_DB_RANGE = LISTEN_DB_MAX - LISTEN_DB_MIN  -- 88

-- Convert ReaSynth linear volume to visual position (0-1)
local function vol_to_pos(vol)
  if not vol or vol <= 0 then return 0 end
  local db = 20 * math.log(vol, 10)
  if db <= LISTEN_DB_MIN then return 0 end
  if db >= LISTEN_DB_MAX then return 1 end
  return (db - LISTEN_DB_MIN) / LISTEN_DB_RANGE
end

-- Convert visual position (0-1) to ReaSynth linear volume
local function pos_to_vol(pos)
  if pos <= 0 then return 0 end
  if pos >= 1 then return 10 ^ (LISTEN_DB_MAX / 20) end
  local db = LISTEN_DB_MIN + pos * LISTEN_DB_RANGE
  return 10 ^ (db / 20)
end

-- Listen button with volume drag control and visual indicator
-- Returns: clicked (boolean), volume_changed (boolean)
function ListenButtonWithVolume(ctx, id, label, w, is_active, volume, trackname)
  local base_active   = ImGui.ImGui_ColorConvertDouble4ToU32(0.50, 0.50, 0.50, 1.0)
  local base_inactive = ImGui.ImGui_ColorConvertDouble4ToU32(0.22, 0.22, 0.22, 1.0)
  local dark_overlay  = ImGui.ImGui_ColorConvertDouble4ToU32(0.0, 0.0, 0.0, 0.4)  -- Darken below line
  local vol_line_col  = ImGui.ImGui_ColorConvertDouble4ToU32(1.0, 1.0, 1.0, 0.8)  -- Volume indicator line

  local h = ImGui.ImGui_GetFrameHeight(ctx)
  local x, y = ImGui.ImGui_GetCursorScreenPos(ctx)

  ImGui.ImGui_InvisibleButton(ctx, id, w, h)
  local hovered = ImGui.ImGui_IsItemHovered(ctx)
  local held    = ImGui.ImGui_IsItemActive(ctx)
  local clicked = false
  local volume_changed = false
  
  -- Handle drag for volume control
  local _, mouse_y = ImGui.ImGui_GetMousePos(ctx)
  
  if held then
    if not LISTEN_DRAG_STATE.dragging then
      -- Start dragging
      LISTEN_DRAG_STATE.dragging = true
      LISTEN_DRAG_ACTIVE = true  -- Suppress paint-toggle globally
      LISTEN_DRAG_STATE.start_y = mouse_y
      -- Store starting position (not volume) for smoother dragging
      LISTEN_DRAG_STATE.start_pos = vol_to_pos(volume or 0)
    else
      -- Continue dragging - calculate position change, then convert to volume
      local delta_y = LISTEN_DRAG_STATE.start_y - mouse_y  -- Positive = drag up = increase
      local sensitivity = 0.01  -- Position change per pixel
      local new_pos = LISTEN_DRAG_STATE.start_pos + (delta_y * sensitivity)
      new_pos = math.max(0.0, math.min(1.0, new_pos))
      local new_vol = pos_to_vol(new_pos)
      
      if trackname and math.abs(new_vol - (volume or 0)) > 0.001 then
        set_reasynth_volume(trackname, new_vol)
        volume_changed = true
      end
    end
  else
    if LISTEN_DRAG_STATE.dragging then
      -- Just released
      local delta_y = math.abs(mouse_y - LISTEN_DRAG_STATE.start_y)
      if delta_y < 3 then
        -- Small movement = click
        clicked = true
      end
      LISTEN_DRAG_STATE.dragging = false
      LISTEN_DRAG_ACTIVE = false  -- Re-enable paint-toggle
    end
  end

  -- Draw button background
  local fill = is_active and base_active or base_inactive
  if hovered then fill = lighten_u32(fill, 0.20) end
  if held    then fill = lighten_u32(fill, 0.10) end

  local dl = ImGui.ImGui_GetWindowDrawList(ctx)
  ImGui.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, fill, 4)
  
  -- Draw volume indicator (darker portion above the volume line = unfilled)
  -- Use curved position for visual display
  local vol = volume or 0
  local vol_pos = vol_to_pos(vol)  -- Convert to visual position
  local vol_y = y + h * (1.0 - vol_pos)  -- Volume line position (bottom = full volume)
  
  -- Dark overlay above volume line (unfilled portion)
  if vol_pos < 1.0 then
    ImGui.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, vol_y, dark_overlay, 4)
  end
  
  -- Volume indicator line
  if vol_pos > 0.0 then
    ImGui.ImGui_DrawList_AddLine(dl, x+2, vol_y, x+w-2, vol_y, vol_line_col, 2)
  end
  
  -- Border
  ImGui.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, lighten_u32(fill, 0.05), 4, 0, 1)

  -- Label
  local tw, th = ImGui.ImGui_CalcTextSize(ctx, label)
  ImGui.ImGui_DrawList_AddText(dl, x + (w - tw)*0.5, y + (h - th)*0.5, COL_TEXT, label)

  return clicked, volume_changed
end