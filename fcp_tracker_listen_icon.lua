-- fcp_tracker_listen_icon.lua
--
-- Renders a small per-track Listen (ReaSynth-enabled) indicator next to
-- the Vocals H1/H2/H3/V mode buttons and the Pro Keys X/H/M/E
-- difficulty buttons in the tab header. The indicator is a thin
-- read/toggle surface over the existing get_reasynth_enabled /
-- set_reasynth_enabled / toggle_reasynth_enabled /
-- get_reasynth_volume / ensure_track_fx_chain_enabled primitives; it
-- does not introduce new tab-switch side effects, listen-FX logic, or
-- per-track preferences.
--
-- Public API (call after FCP_CTX exists and the global toggle
-- primitives in fcp_tracker_util_tracks.lua are loaded):
--
--   ListenIcon_Draw(ctx, id, trackname, btn_h, frame_h, radio_group,
--                   redirect_focus_after_click)
--       Draws a volume bar + listen icon at the current ImGui cursor
--       position. The caller is responsible for placing the cursor on
--       the same row as the preceding mode/difficulty button
--       (typically with ImGui_SameLine(ctx, 0, gap_px) immediately
--       before this call); the function does NOT reposition the
--       cursor itself.
--
--       The function issues an ImGui_InvisibleButton of size
--       btn_h x frame_h so the click target spans the icon's full
--       area (the caller has already offset the cursor X by
--       BTN_W + LISTEN_ICON_LEFT_GAP, so the button's left edge is
--       at the icon's left edge). Behind the icon image it draws a
--       vertical fill bar (bottom-up, blue when Listen is on, grey
--       when off) whose fill height equals vol * frame_h where
--       vol = get_reasynth_volume. The icon image is drawn on top
--       of the bar, centered within the slot.
--
--       Each frame, the on/off state and volume are read live via
--       get_reasynth_enabled / get_reasynth_volume -- no caching --
--       so external toggles (the editor-row Listen button, another
--       script) are reflected immediately.
--
--       On left-click (ImGui_IsItemClicked(ctx, 0)) the gesture is
--       tentatively a tap. If the mouse moves beyond DRAG_THRESHOLD_PX
--       before release, the gesture is reclassified as a drag and the
--       y-position within the slot maps linearly to volume
--       (top = max, bottom = 0). On release:
--         - tap (no drag): branches on radio_group as before.
--           nil (Vocals): independent toggle. ensure_track_fx_chain_enabled,
--             then toggle_reasynth_enabled, clear VOCALS_LISTEN_SAVED.
--           table (Pro Keys): radio toggle. compute
--             want_on = not current_state; ensure the target's FX
--             chain; set_reasynth_enabled(target, want_on); if
--             want_on then set_reasynth_enabled(other, false) for each
--             entry in radio_group.
--         - drag: volume was updated live during the drag; no toggle.
--
--       The release frame defers redirect_focus_after_click so the
--       user's focus returns to the script window after both tap and
--       drag.
--
--       The redirect_focus_after_click parameter is the focus-redirect
--       helper from fcp_tracker_ui.lua. It is local to that file's
--       dofile chunk, so the caller (which receives it as a parameter
--       of progress_and_count_row) must pass it in.
--
-- Typical usage: called once per Vocals/Pro Keys button from inside
-- the header's button loop, with ImGui_SameLine(ctx, 0, gap_px)
-- immediately before. The caller is responsible for the per-slot
-- horizontal layout math -- this function only handles the bar draw,
-- icon draw, and gesture routing.

-- ============================================================
-- Local state
-- ============================================================
local volume_on_image   = nil
local volume_on_loaded  = false
local volume_off_image  = nil
local volume_off_loaded = false

-- Bar colours (packed 0xAABBGGRR ints): active blue, inactive grey
local LISTEN_BAR_ACTIVE_COL   = 0x3399FFFF
local LISTEN_BAR_INACTIVE_COL = 0x808080FF

-- Volume at which the bar is full; drag-to-top writes this (not 1.0)
-- so the per-track listen volume is rescaled down to 2/3 of the old max.
local LISTEN_BAR_MAX_VOLUME = 2/3

-- Mouse-move distance past which a click is reclassified as a drag
local DRAG_THRESHOLD_PX = 4

-- Per-icon gesture state; cleared when the slot's button is no longer active
local drag_state = {}

-- Path resolution (mirrors confetti_script_dir in fcp_tracker_confetti_anim.lua)
local function listen_icon_script_dir()
  local info = debug.getinfo(1, "S")
  local p = info and info.source or ""
  p = p:gsub("^@", "")
  return p:match("^(.*[\\/])") or "./"
end

local VOLUME_ON_PATH  = listen_icon_script_dir() .. "volume-on.png"
local VOLUME_OFF_PATH = listen_icon_script_dir() .. "volume-off.png"

-- Lazy-load helpers: mirror Progress_Confetti_EnsureLoaded - cached-handle
-- check, file-exists, ImGui_CreateImage, Attach, mb() on failure (no pcall).
local function ensure_volume_on_loaded(ctx)
  if volume_on_loaded and volume_on_image
     and reaper.ImGui_ValidatePtr(volume_on_image, "ImGui_Image*") then
    return true
  end
  if not ctx then return false end
  if not reaper.file_exists(VOLUME_ON_PATH) then
    mb("volume-on.png not found at:\n" .. VOLUME_ON_PATH)
    return false
  end
  volume_on_image = reaper.ImGui_CreateImage(VOLUME_ON_PATH)
  if not volume_on_image then
    mb("Failed to load ImGui image:\n" .. VOLUME_ON_PATH)
    return false
  end
  -- Prevent GC for the lifetime of the SPT's ImGui context.
  reaper.ImGui_Attach(ctx, volume_on_image)
  volume_on_loaded = true
  return true
end

local function ensure_volume_off_loaded(ctx)
  if volume_off_loaded and volume_off_image
     and reaper.ImGui_ValidatePtr(volume_off_image, "ImGui_Image*") then
    return true
  end
  if not ctx then return false end
  if not reaper.file_exists(VOLUME_OFF_PATH) then
    mb("volume-off.png not found at:\n" .. VOLUME_OFF_PATH)
    return false
  end
  volume_off_image = reaper.ImGui_CreateImage(VOLUME_OFF_PATH)
  if not volume_off_image then
    mb("Failed to load ImGui image:\n" .. VOLUME_OFF_PATH)
    return false
  end
  reaper.ImGui_Attach(ctx, volume_off_image)
  volume_off_loaded = true
  return true
end

-- Public API: only entry point; image handles, colours, and gesture state are file-local.
-- Caller must place the cursor on the button's line first; this consumes the slot.
function ListenIcon_Draw(ctx, id, trackname, btn_h, frame_h, radio_group, redirect_focus_after_click)
  if not ctx then return end
  if not ensure_volume_on_loaded(ctx) then return end
  if not ensure_volume_off_loaded(ctx) then return end

  -- Full-slot click target (btn_h x frame_h) so any click/drag on the icon
  -- adjusts volume; LISTEN_SLOT_W would spill the bar into the next slot.
  reaper.ImGui_InvisibleButton(ctx, id, btn_h, frame_h)
  local slot_x_min, slot_y_min = reaper.ImGui_GetItemRectMin(ctx)
  local slot_x_max, slot_y_max = reaper.ImGui_GetItemRectMax(ctx)

  -- Live reads (no caching) so external toggles and volume changes show next frame
  local is_on = get_reasynth_enabled(trackname)
  local vol   = get_reasynth_volume(trackname) or 0
  local bar_color = is_on and LISTEN_BAR_ACTIVE_COL or LISTEN_BAR_INACTIVE_COL

  -- Bottom-up volume bar on the foreground draw list, skipped at vol == 0.
  -- Clamp the read volume to LISTEN_BAR_MAX_VOLUME so stale high values fill.
  local vol_for_bar = vol
  if vol_for_bar > LISTEN_BAR_MAX_VOLUME then
    vol_for_bar = LISTEN_BAR_MAX_VOLUME
  end

  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  if vol_for_bar > 0 then
    -- Extend the bar 1px left of the slot; fill height scales to
    -- LISTEN_BAR_MAX_VOLUME, corner radius matches button styling (4).
    reaper.ImGui_DrawList_AddRectFilled(draw_list,
      slot_x_min - 1, slot_y_max - (vol_for_bar / LISTEN_BAR_MAX_VOLUME) * frame_h,
      slot_x_max, slot_y_max,
      bar_color, 4, 0)
  end

  -- Mark the gesture as a tap; the drag path upgrades it to dragging
  if reaper.ImGui_IsItemClicked(ctx, 0) and not drag_state[id] then
    drag_state[id] = { dragging = false }
  end

  -- Right-click sets volume to half of LISTEN_BAR_MAX_VOLUME (discrete; independent of tap/drag)
  if reaper.ImGui_IsItemClicked(ctx, 1) then
    set_reasynth_volume(trackname, LISTEN_BAR_MAX_VOLUME / 2)
    if redirect_focus_after_click then
      reaper.defer(redirect_focus_after_click)
    end
  end

  -- Drag reclassifies the tap to a drag and writes volume live, mapping
  -- frame_h to 0..LISTEN_BAR_MAX_VOLUME (drag-to-top rescales the max down).
  local state = drag_state[id]
  if state and reaper.ImGui_IsItemActive(ctx)
     and reaper.ImGui_IsMouseDragging(ctx, 0, DRAG_THRESHOLD_PX) then
    state.dragging = true
    local _, mouse_y = reaper.ImGui_GetMousePos(ctx)
    local new_vol = (1 - (mouse_y - slot_y_min) / frame_h) * LISTEN_BAR_MAX_VOLUME
    if new_vol < 0 then new_vol = 0 end
    if new_vol > LISTEN_BAR_MAX_VOLUME then new_vol = LISTEN_BAR_MAX_VOLUME end
    set_reasynth_volume(trackname, new_vol)
  end

  -- Tap fires on release of a never-dragged gesture: ImGui_IsMouseReleased
  -- gated on drag_state[id] (ReaImGui has no ImGui_IsItemReleased).
  local is_release = reaper.ImGui_IsMouseReleased(ctx, 0)
  if state and is_release and not state.dragging then
    if radio_group == nil then
      -- Vocals: independent toggle; clears the master button's saved on-set
      ensure_track_fx_chain_enabled(trackname)
      toggle_reasynth_enabled(trackname)
      VOCALS_LISTEN_SAVED = nil
    else
      -- Pro Keys: radio toggle; only force other group tracks off when the
      -- target turns on. Clears the master button's saved track (as above).
      local want_on = not is_on
      ensure_track_fx_chain_enabled(trackname)
      set_reasynth_enabled(trackname, want_on)
      if want_on then
        for _, other in ipairs(radio_group) do
          set_reasynth_enabled(other, false)
        end
      end
      FCP_PK_LISTEN_SAVED = nil
    end
  end

  -- Drop gesture state once the slot is no longer active (guard missing keys)
  if drag_state[id] and not reaper.ImGui_IsItemActive(ctx) then
    drag_state[id] = nil
  end

  -- Restore focus once per gesture on the release frame
  if is_release and redirect_focus_after_click then
    reaper.defer(redirect_focus_after_click)
  end

  -- Icon over the bar on the same foreground draw list; rect is centered
  -- vertically in the slot (AddImage takes absolute screen coords).
  local y_offset = (frame_h - btn_h) / 2
  local image = is_on and volume_on_image or volume_off_image
  reaper.ImGui_DrawList_AddImage(draw_list, image,
    slot_x_min, slot_y_min + y_offset,
    slot_x_min + btn_h, slot_y_min + y_offset + btn_h,
    0, 0, 1, 1)
end
