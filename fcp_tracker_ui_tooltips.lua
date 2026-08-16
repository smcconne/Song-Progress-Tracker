-- fcp_tracker_ui_tooltips.lua
--
-- Shared ImGui tooltip rendering for the Song Progress Tracker.
-- Centralizes the tooltip skeleton that was previously duplicated
-- across fcp_tracker_ui_tabs.lua, fcp_tracker_ui_header.lua, and
-- fcp_tracker_ui_widgets.lua at six call sites (3 tab tooltips,
-- 2 mode-button tooltips, 1 difficulty-button tooltip).
--
-- Public API:
--   draw_tab_tooltip(ctx, opts, body_fn)
--     opts: { item_bottom_y, key, header, pct }
--     Width is fixed at 194 (per-kind). body_fn(ctx) is called
--     between the confetti draw and EndTooltip; body_fn is
--     nil-safe and should not call BeginTooltip/EndTooltip
--     itself.
--
--   draw_mode_tooltip(ctx, opts)
--     opts: { item_bottom_y, key, header, pct, is_empty, width }
--     Width is passed in (120 for Vocals, 140 for Venue).
--     is_empty=true renders "Empty" in gray and suppresses confetti.
--     No body content.
--
--   draw_diff_tooltip(ctx, opts, body_fn)
--     opts: { item_bottom_y, key, header, pct }
--     Width is fixed at 194. body_fn(ctx) renders the advice text
--     (caller is responsible for separator + PushTextWrapPos +
--     render_colored_text + PopTextWrapPos).
--
--   Tooltips_FrameTick()
--     Advance the rising-edge state to a new frame. MUST be called
--     exactly once per frame, BEFORE any draw_*_tooltip call. See
--     "Rising-edge state" below.
--
-- Body-fn contract:
--   body_fn runs INSIDE the tooltip after the confetti draw and
--   before EndTooltip. Do NOT call BeginTooltip/EndTooltip inside
--   body_fn. body_fn is called with the same ctx as the public
--   function. If body_fn is nil, no body is rendered (and no
--   separator is emitted by this module).
--
-- Rising-edge state:
--   The rising-edge mechanism uses a two-set frame tracking pattern:
--     ACTIVE_THIS_FRAME  - keys drawn in the current (in-progress) frame
--     ACTIVE_LAST_FRAME  - keys drawn in the previous (completed) frame
--   A key is on a "rising edge" when it is absent from
--   ACTIVE_LAST_FRAME (i.e., the source was not drawn in the prior
--   frame) and present in ACTIVE_THIS_FRAME (i.e., it is being drawn
--   in the current frame). The rising edge fires once per (frame,
--   key) pair; subsequent frames while the source remains hovered
--   find the key already in ACTIVE_LAST_FRAME and do not re-roll.
--   Tooltips_FrameTick() rotates the two sets at the frame boundary
--   (ACTIVE_LAST_FRAME <- ACTIVE_THIS_FRAME; ACTIVE_THIS_FRAME = {}).
--   This makes the rising-edge check independent of how often
--   callers invoke the draw function, so callers that only invoke
--   the draw function inside an IsItemHovered block (the actual
--   pattern in this codebase) still get a single re-roll per hover
--   rather than a re-roll every frame.
--
--   Keys MUST be namespaced:
--     "tab:<name>"      - tab tooltips
--     "mode:<label>"    - mode-button tooltips (Venue/Vocals)
--     "diff:<diff>"     - difficulty-button tooltips (X/H/M/E)
--
-- Load-order constraint:
--   Must be loaded AFTER fcp_tracker_ui_widgets.lua (so DIFF_TOOLTIPS
--   and render_colored_text are available, even though this module
--   does not call render_colored_text itself). Must be loaded BEFORE
--   fcp_tracker_ui_tabs.lua, fcp_tracker_ui_header.lua, and any
--   caller of draw_diff_tooltip inside DiffSquareButton (which is
--   itself in fcp_tracker_ui_widgets.lua but the function is called
--   at draw time, not load time, so as long as the new module is
--   loaded before the first draw frame this is fine).
--
-- Requires globals from:
--   fcp_tracker_confetti_anim.lua : Progress_Confetti_DrawInRect,
--                                   Randomize_Confetti_Offset
--   fcp_tracker_config.lua        : CONFETTI_WIDTH
--   fcp_tracker_model.lua         : (not directly used; this module
--                                   consumes caller-computed pct)
--   fcp_tracker_ui_helpers.lua    : pct_scaled_u32
--   fcp_tracker_ui_widgets.lua    : (not directly used; the diff
--                                   body_fn uses render_colored_text
--                                   at the call site)

local reaper = reaper
local ImGui  = reaper

-- Module-local state

-- Two-set frame tracking: a key rises when drawn this frame but not last.
-- Keys are namespaced: "tab:<name>", "mode:<label>", "diff:<diff>".
local ACTIVE_THIS_FRAME = {}
local ACTIVE_LAST_FRAME = {}

-- Advance the two-set frame tracking once per frame before any tooltip draw.
function Tooltips_FrameTick()
  ACTIVE_LAST_FRAME = ACTIVE_THIS_FRAME
  ACTIVE_THIS_FRAME = {}
end

-- Private helpers

-- Anchor the tooltip below the hovered item, aligned to the window's left edge.
local function tooltip_window_begin(ctx, item_bottom_y, width)
  local win_x, _ = ImGui.ImGui_GetWindowPos(ctx)
  ImGui.ImGui_SetNextWindowPos(ctx, win_x, item_bottom_y + 5)
  ImGui.ImGui_SetNextWindowSize(ctx, width, 0)
end

-- Begin the tooltip, re-roll confetti on rising edge, and capture the
-- first-row rect for the confetti background layer.
local function tooltip_begin(ctx, key)
  ImGui.ImGui_BeginTooltip(ctx)

  -- Re-roll the "tooltip" confetti offset only on a rising-edge hover.
  if not ACTIVE_LAST_FRAME[key] then
    Randomize_Confetti_Offset("tooltip")
  end
  ACTIVE_THIS_FRAME[key] = true

  -- Capture the first-row rect for the confetti background
  -- (rightmost CONFETTI_WIDTH pixels, behind the percentage).
  local tt_sx, tt_sy = ImGui.ImGui_GetCursorScreenPos(ctx)
  local tt_w = ImGui.ImGui_GetContentRegionAvail(ctx)
  local tt_h = ImGui.ImGui_GetTextLineHeightWithSpacing(ctx)
  return tt_sx, tt_sy, tt_w, tt_h
end

-- Render left header + right pct (gray "Empty" when empty; confetti at 100%).
local function tooltip_draw_header_pct(ctx, tt_sx, tt_sy, tt_w, tt_h, header, pct, is_empty)
  -- Left-aligned header
  ImGui.ImGui_Text(ctx, header)

  -- Right-aligned percentage on same line, colored by percentage
  -- (gray + "Empty" when the source is empty)
  ImGui.ImGui_SameLine(ctx)
  local pct_text = is_empty and "Empty" or (tostring(pct) .. "%")
  local avail_w = ImGui.ImGui_GetContentRegionAvail(ctx)
  local pct_w = ImGui.ImGui_CalcTextSize(ctx, pct_text)
  ImGui.ImGui_SetCursorPosX(ctx, ImGui.ImGui_GetCursorPosX(ctx) + avail_w - pct_w)

  if is_empty then
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), 0x808080FF)
  else
    local pct_col = pct_scaled_u32(pct, 1.0, 1.0)
    ImGui.ImGui_PushStyleColor(ctx, ImGui.ImGui_Col_Text(), pct_col)
  end
  ImGui.ImGui_Text(ctx, pct_text)
  ImGui.ImGui_PopStyleColor(ctx)

  -- Confetti only at 100% (and not empty), behind the rightmost pixels.
  if pct == 100 and not is_empty then
    Progress_Confetti_DrawInRect(ctx, tt_sx + tt_w - CONFETTI_WIDTH, tt_sy, CONFETTI_WIDTH, tt_h, "tooltip")
  end
end

-- End the tooltip; the frame tick handles state cleanup.
local function tooltip_end(ctx, key)
  ImGui.ImGui_EndTooltip(ctx)
end

-- Public API

-- Tab tooltip: fixed 194px width, optional body_fn for the per-tab breakdown.
function draw_tab_tooltip(ctx, opts, body_fn)
  tooltip_window_begin(ctx, opts.item_bottom_y, 194)
  local tt_sx, tt_sy, tt_w, tt_h = tooltip_begin(ctx, opts.key)
  tooltip_draw_header_pct(ctx, tt_sx, tt_sy, tt_w, tt_h, opts.header, opts.pct, false)
  if body_fn then body_fn(ctx) end
  tooltip_end(ctx, opts.key)
end

-- Mode-button tooltip; opts.width sizes it, is_empty greys "Empty".
function draw_mode_tooltip(ctx, opts)
  tooltip_window_begin(ctx, opts.item_bottom_y, opts.width)
  local tt_sx, tt_sy, tt_w, tt_h = tooltip_begin(ctx, opts.key)
  tooltip_draw_header_pct(ctx, tt_sx, tt_sy, tt_w, tt_h, opts.header, opts.pct, opts.is_empty)
  tooltip_end(ctx, opts.key)
end

-- Difficulty tooltip: fixed 194px; the caller's body_fn renders the advice.
function draw_diff_tooltip(ctx, opts, body_fn)
  tooltip_window_begin(ctx, opts.item_bottom_y, 194)
  local tt_sx, tt_sy, tt_w, tt_h = tooltip_begin(ctx, opts.key)
  tooltip_draw_header_pct(ctx, tt_sx, tt_sy, tt_w, tt_h, opts.header, opts.pct, false)
  if body_fn then body_fn(ctx) end
  tooltip_end(ctx, opts.key)
end
