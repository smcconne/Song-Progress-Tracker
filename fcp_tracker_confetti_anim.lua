-- fcp_tracker_confetti_anim.lua
--
-- Animates the smooth-confetti.png spritesheet using ReaImGui UV cropping.
--
-- Spritesheet: 10x10 grid of 194x52 tiles (192x50 inner content + 1px
-- transparent border on each side, matching smooth-confetti_spritesheet.bat).
-- 100 frames at CONFETTI_FPS frames per second; the loop is continuous.
--
-- Pattern adapted from
--   RB3-Venue-Preview/FCP Venue Preview Lighting Camera.lua
-- (DrawCameraSpritesheet: reaper.ImGui_CreateImage + ImGui_Attach + UV-cropped
-- ImGui_Image, frame advance via reaper.time_precise()).
--
-- Public API (call after FCP_CTX exists):
--   Progress_Confetti_Draw(ctx)            -- primary method. Auto-loads on
--                                            first call, auto-starts the
--                                            animation, draws the current
--                                            frame at the ImGui cursor pos.
--                                            Returns drawn (w, h).
--   Progress_Confetti_DrawAt(ctx, x, y, w, h)
--                                         -- same, but at an absolute screen
--                                            position with explicit size.
--   Progress_Confetti_DrawInRect(ctx, x, y, w, h, key)
--                                         -- submit the current frame to the
--                                            foreground draw list at the given
--                                            screen rect, preserving the
--                                            frame's native aspect ratio
--                                            (centered crop-to-fill). Does NOT
--                                            advance the cursor. Use this when
--                                            you want the spritesheet to be a
--                                            background layer behind subsequent
--                                            widgets (e.g. text) in the same
--                                            layout cell. The optional `key`
--                                            argument enables per-key
--                                            randomized crop offset: when
--                                            provided, the active crop axis is
--                                            positioned by the stored offset
--                                            for that key; when omitted, the
--                                            crop is centered (pre-change
--                                            behavior). Callers are
--                                            responsible for invoking
--                                            Randomize_Confetti_Offset(key) on
--                                            whatever trigger they care about.
--   Randomize_Confetti_Offset(key)        -- re-roll the stored crop offset
--                                            for `key`. When key is non-nil,
--                                            draws two fresh values from the
--                                            module's RNG and replaces the
--                                            stored {x, y}. When key is nil,
--                                            no-op. Callers invoke this on
--                                            the trigger that should change
--                                            the visible slice (e.g. tab
--                                            change, BeginTooltip). The
--                                            confetti module does not hook
--                                            into tab or tooltip events.
--   Progress_Confetti_Stop()              -- halt animation; subsequent draws
--                                            show frame 0.
--   Progress_Confetti_Start()             -- (re)start the animation timer.
--   Progress_Confetti_IsActive()          -- bool.
--   Progress_Confetti_EnsureLoaded(ctx)   -- explicit pre-load; idempotent.
--                                            Returns true on success.
--
-- Typical usage: call Progress_Confetti_Draw(FCP_CTX) once per frame from
-- any ImGui draw call (e.g. inside the editor row, the footer, or a custom
-- child window). The animation advances with wall-clock time, so no tick
-- function is needed -- just call Draw every frame.

-- ============================================================
-- Local state
-- ============================================================
local confetti_image   = nil
local confetti_loaded  = false
local confetti_active  = false
local confetti_start_t = nil

-- Per-key randomized crop offsets { x, y } in [0, 1]; lazy or Randomize_Confetti_Offset
local confetti_offsets = {}

-- Seed the module RNG from wall-clock time; warm-up draws discard
-- low-entropy first values (no other module consumes math.random).
math.randomseed(reaper.time_precise() * 1000)
math.random()
math.random()

-- Spritesheet constants
local CONFETTI_COLS       = 10
local CONFETTI_ROWS       = 10
local CONFETTI_FRAME_COUNT = CONFETTI_COLS * CONFETTI_ROWS  -- 100
local CONFETTI_FPS        = 30
local CONFETTI_BORDER     = 1  -- 1px border on each side of every tile

-- Path resolution
local function confetti_script_dir()
  local info = debug.getinfo(1, "S")
  local p = info and info.source or ""
  p = p:gsub("^@", "")
  return p:match("^(.*[\\/])") or "./"
end

local CONFETTI_SPRITESHEET_PATH = confetti_script_dir() .. "smooth-confetti.png"

-- Helpers
local function confetti_current_frame()
  if not (confetti_active and confetti_start_t) then return 0 end
  local elapsed = reaper.time_precise() - confetti_start_t
  if elapsed < 0 then return 0 end
  return math.floor(elapsed * CONFETTI_FPS) % CONFETTI_FRAME_COUNT
end

-- UV rectangle for a frame as fractions of the spritesheet (mirrors DrawCameraSpritesheet)
local function confetti_uvs(frame)
  local img_w, img_h = reaper.ImGui_Image_GetSize(confetti_image)
  if img_w <= 0 or img_h <= 0 then return 0, 0, 0, 0 end
  local tile_w = math.floor(img_w / CONFETTI_COLS)
  local tile_h = math.floor(img_h / CONFETTI_ROWS)
  local col = frame % CONFETTI_COLS
  local row = math.floor(frame / CONFETTI_COLS)
  local uv0_x = (col * tile_w       + CONFETTI_BORDER) / img_w
  local uv0_y = (row * tile_h       + CONFETTI_BORDER) / img_h
  local uv1_x = (col * tile_w + tile_w - CONFETTI_BORDER) / img_w
  local uv1_y = (row * tile_h + tile_h - CONFETTI_BORDER) / img_h
  return uv0_x, uv0_y, uv1_x, uv1_y
end

-- Inner content size (excludes the 1px border on each side).
local function confetti_inner_size()
  local img_w, img_h = reaper.ImGui_Image_GetSize(confetti_image)
  local tile_w = math.floor(img_w / CONFETTI_COLS)
  local tile_h = math.floor(img_h / CONFETTI_ROWS)
  return tile_w - 2 * CONFETTI_BORDER, tile_h - 2 * CONFETTI_BORDER
end

-- Public API
function Progress_Confetti_EnsureLoaded(ctx)
  if confetti_loaded and confetti_image
     and reaper.ImGui_ValidatePtr(confetti_image, "ImGui_Image*") then
    return true
  end
  if not ctx then return false end
  if not reaper.file_exists(CONFETTI_SPRITESHEET_PATH) then
    mb("smooth-confetti.png not found at:\n" .. CONFETTI_SPRITESHEET_PATH)
    return false
  end
  confetti_image = reaper.ImGui_CreateImage(CONFETTI_SPRITESHEET_PATH)
  if not confetti_image then
    mb("Failed to load ImGui image:\n" .. CONFETTI_SPRITESHEET_PATH)
    return false
  end
  -- Prevent GC for the lifetime of the SPT's ImGui context.
  reaper.ImGui_Attach(ctx, confetti_image)
  confetti_loaded = true
  return true
end

function Progress_Confetti_Start()
  if not confetti_loaded then return false end
  confetti_start_t = reaper.time_precise()
  confetti_active  = true
  return true
end

function Progress_Confetti_Stop()
  confetti_active  = false
  confetti_start_t = nil
end

function Progress_Confetti_IsActive()
  return confetti_active
end

-- Re-roll a key's stored crop offset (nil key is a no-op)
function Randomize_Confetti_Offset(key)
  if key == nil then return end
  confetti_offsets[key] = { x = math.random(), y = math.random() }
end

-- Primary method. Auto-loads and auto-starts so the caller only has to
-- invoke it once per frame. Returns the (w, h) actually drawn.
function Progress_Confetti_Draw(ctx)
  if not ctx then return 0, 0 end
  if not (confetti_loaded and confetti_image
          and reaper.ImGui_ValidatePtr(confetti_image, "ImGui_Image*")) then
    if not Progress_Confetti_EnsureLoaded(ctx) then return 0, 0 end
  end
  if not confetti_active then Progress_Confetti_Start() end

  local w, h = confetti_inner_size()
  local frame = confetti_current_frame()
  local uv0_x, uv0_y, uv1_x, uv1_y = confetti_uvs(frame)
  reaper.ImGui_Image(ctx, confetti_image, w, h, uv0_x, uv0_y, uv1_x, uv1_y)
  return w, h
end

-- Same as Draw but at an absolute screen position with explicit size.
function Progress_Confetti_DrawAt(ctx, x, y, w, h)
  if not ctx then return end
  if not (confetti_loaded and confetti_image
          and reaper.ImGui_ValidatePtr(confetti_image, "ImGui_Image*")) then
    if not Progress_Confetti_EnsureLoaded(ctx) then return end
  end
  if not confetti_active then Progress_Confetti_Start() end

  local prev_x, prev_y = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local frame = confetti_current_frame()
  local uv0_x, uv0_y, uv1_x, uv1_y = confetti_uvs(frame)
  reaper.ImGui_Image(ctx, confetti_image, w, h, uv0_x, uv0_y, uv1_x, uv1_y)
  reaper.ImGui_SetCursorScreenPos(ctx, prev_x, prev_y)
end

-- Background-layer variant: draw the current frame onto the foreground draw
-- list at a rect (crop-to-fill), no cursor advance; key picks the crop offset.
function Progress_Confetti_DrawInRect(ctx, x, y, w, h, key)
  if not ctx then return end
  if not (confetti_loaded and confetti_image
          and reaper.ImGui_ValidatePtr(confetti_image, "ImGui_Image*")) then
    if not Progress_Confetti_EnsureLoaded(ctx) then return end
  end
  if not confetti_active then Progress_Confetti_Start() end

  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  if not draw_list then return end
  if w <= 0 or h <= 0 then return end

  -- Frame UVs in the full spritesheet (where the current frame lives).
  local frame = confetti_current_frame()
  local fx0, fy0, fx1, fy1 = confetti_uvs(frame)
  local inner_w, inner_h = confetti_inner_size()
  if inner_w <= 0 or inner_h <= 0 then return end

  -- Per-key crop offset (lazy-init safety net for callers that haven't
  -- called Randomize yet). No key -> centered defaults (pre-change).
  local off_x, off_y
  if key == nil then
    off_x, off_y = 0.5, 0.5
  else
    local stored = confetti_offsets[key]
    if stored == nil then
      stored = { x = math.random(), y = math.random() }
      confetti_offsets[key] = stored
    end
    off_x, off_y = stored.x, stored.y
  end

  -- Crop-to-fill: scale to cover the rect, then crop the longer axis to the
  -- target aspect; the active axis is offset by the per-key (x, y) in [0, 1].
  local target_ar = w / h
  local source_ar = inner_w / inner_h
  local fu0, fv0, fu1, fv1
  if target_ar > source_ar then
    -- Target is wider: drop top and bottom of the frame.
    local uv_h = source_ar / target_ar
    local uv_y = (1 - uv_h) * off_y
    fu0 = fx0
    fv0 = fy0 + (fy1 - fy0) * uv_y
    fu1 = fx1
    fv1 = fy0 + (fy1 - fy0) * (uv_y + uv_h)
  elseif target_ar < source_ar then
    -- Target is narrower: drop left and right of the frame.
    local uv_w = target_ar / source_ar
    local uv_x = (1 - uv_w) * off_x
    fu0 = fx0 + (fx1 - fx0) * uv_x
    fv0 = fy0
    fu1 = fx0 + (fx1 - fx0) * (uv_x + uv_w)
    fv1 = fy1
  else
    -- Aspect ratios match: use the full frame.
    fu0, fv0, fu1, fv1 = fx0, fy0, fx1, fy1
  end

  reaper.ImGui_DrawList_AddImage(
    draw_list, confetti_image,
    x, y, x + w, y + h,
    fu0, fv0, fu1, fv1
  )
end
