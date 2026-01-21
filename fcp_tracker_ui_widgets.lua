-- fcp_tracker_ui_widgets.lua
-- Custom button widgets for RBN Progress UI

local reaper = reaper
local ImGui  = reaper

-- Requires globals from rbn_ui_helpers.lua: pct_scaled_u32, lighten_u32, COL_TEXT
-- Requires globals from rbn_preview_config.lua: BTN_W

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
           "• >110 bpm: thin 8ths to groups of 7\n" ..
           "• >140 bpm: thin 8ths to groups of 3\n" ..
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
    Expert = "• Green + Orange chords allowed\n" ..
             "• Broken chords allowed\n" ..
             "• Chart new keyboard layers as they are introduced\n" ..
             "• Avoid playing simultaneous keyboard parts \n" ..
             "• Listen for subtle layers",
    Hard = "• Usually remove >= 16th notes\n" ..
           "• Retain chords\n" ..
           "• Avoid quick Green to Orange jumps\n" ..
           "• No 3-note or Green/Orange chords\n" ..
           "• Avoid continuous 8ths >= 160 bpm\n" ..
           "• Groups of 3 or 7 8ths for playability",
    Medium = "• Notes on strong quarter note beats\n" ..
             "• Retain chords from Hard\n" ..
             "• No 3-note chords\n" ..
             "• 8th note gap between notes\n" ..
             "• 1/4 gap between chords",
    Easy = "• 1/2 notes\n" ..
           "• No chords"
  },
  Drums = {
    Expert = "• Use mk_slicer for kick, toms, snare\n" ..
             "• 2x bass pedal for >2 consecutive 16ths\n" ..
             "• With heel-toe, can hit steady 8ths or a couple 16ths on single pedal",
    Hard = "• Complete limb independence\n" ..
           "• Kicks and snares can fall in between a steady right-hand rhythm.\n" ..
           "• 2 consecutive 16ths allowed <140 bpm (unless both are kicks)\n" ..
           "• Remove kicks during fills\n" ..
           "• Avoid kicks under crashes (allowed when sparse) \n" ..
           "• No fast hand crosses\n" ..
           "• >110 bpm: try thinning 8ths to groups of 7\n" ..
           "• >140 bpm: try thinning 8ths to groups of 3",
    Medium = "• No kicks/snares between hihat/ride gems\n" ..
             "• No 3-limb hits\n" ..
             "• 8ths ok up to 140 bpm\n" ..
             "• >= 110 bpm: kicks only on quarter notes\n" ..
             "• >= 170 bpm: one kick per measure\n" ..
             "• Only downbeat crashes with kick\n" ..
             "• Stream of gems must be playable with one hand",
    Easy = "• No gems with kick\n" ..
           "• 2-hand beat (no kick) OR kick + snare only\n" ..
           "• Favor crashes instead of kicks\n" ..
           "• >= 170 bpm: one kick per measure\n" ..
           "• Reduce 8th fills to quarter notes at tempo"
  },
  GuitarBass = {
    Expert = "• No 3-note chords with Green + Orange\n" ..
             "• 16th note space between sustains, 8th at >140bpm",
    Hard = "• Usually remove >= 16th notes\n" ..
           "• >110 bpm: thin 8ths to groups of 7\n" ..
           "• >140 bpm: thin 8ths to groups of 3\n" ..
           "• Only 2 note chords allowed\n" ..
           "• Avoid quick Green to Orange jumps",
    Medium = "• Try for quarter notes\n" ..
             "• Maintain 4 lanes at a time\n" ..
             "• Avoid G-B, G-O, R-O chords and jumps\n" ..
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
      elseif current_tab == "Guitar" or current_tab == "Bass" then
        instrument_name = "Guitar/Bass"
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
      ImGui.ImGui_Text(ctx, tooltip)
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