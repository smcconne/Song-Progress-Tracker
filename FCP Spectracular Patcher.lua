-- @description Patch Spectracular defaults (zoom + curves + window min size + wheel behaviour + MIDI note overlay with lyrics + note preview) for Spectracular 3.x
-- @author FinestCardboardPearls
-- @version 3.0
-- @noindex

local function fail(msg)
  reaper.ShowMessageBox(msg, "Spectracular defaults patch", 0)
  error(msg)
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then fail("Could not open file for reading: " .. path) end
  local s = f:read("*a")
  f:close()
  s = s:gsub("\r\n", "\n")
  return s
end

local function write_file(path, s)
  local f = io.open(path, "wb")
  if not f then fail("Could not open file for writing: " .. path) end
  f:write(s)
  f:close()
end

-- Simple plain string replace (no pattern magic), returns new_text, num_replacements
local function plain_replace(haystack, needle, replacement)
  local start_pos, end_pos = haystack:find(needle, 1, true)
  if not start_pos then return haystack, 0 end
  return haystack:sub(1, start_pos - 1) .. replacement .. haystack:sub(end_pos + 1), 1
end

-- Helper to extract a top-level function block starting with a specific line
local function get_function_block(txt, signature_line)
  local start_pos = txt:find(signature_line, 1, true)
  if not start_pos then return nil end

  -- Find the end of this block. We assume top-level functions end with "end" at the start of a line
  -- or just indented "end" if the file is consistent, but the user specified "first non-indented end".
  -- However, Lua patterns are tricky for balancing.
  -- Since the user asked to "replace the block from ... to the first non-indented end",
  -- let's look for "\nend" followed by newline or EOF, assuming standard formatting.
  
  -- A robust way for top-level functions in this specific file context (app.lua)
  -- is to look for the next "end" that is at the start of a line (or preceded only by newline).
  
  local current_pos = start_pos
  while true do
    local end_match_start, end_match_end = txt:find("\nend", current_pos, true)
    if not end_match_start then 
        -- Fallback: maybe it's the last line without a newline
        local last_end = txt:find("\nend$", current_pos)
        if last_end then return txt:sub(start_pos, #txt) end
        return nil 
    end
    
    -- Check if this 'end' is really top-level (not inside an if/for/function).
    -- A simple heuristic for this specific file is that top-level ends are usually at column 1.
    -- The find("\nend") finds a newline then 'end'.
    
    -- Let's verify it's a block end.
    -- For this specific request, we will trust the "first non-indented end" logic.
    -- The pattern "\nend" matches an end at the start of a line.
    
    return txt:sub(start_pos, end_match_end)
  end
end

----------------------------------------------------------------------
-- Locate Spectracular
----------------------------------------------------------------------

local resource      = reaper.GetResourcePath()
local base_dir      = resource .. "/Scripts/ReaTeam Scripts/Various/talagan_Spectracular"
local settings_path = base_dir .. "/modules/settings.lua"
local spectro_path  = base_dir .. "/widgets/spectrograph.lua"
local main_path     = base_dir .. "/widgets/main.lua"
local app_path      = base_dir .. "/app.lua"

if not (reaper.file_exists(settings_path)
        and reaper.file_exists(spectro_path)
        and reaper.file_exists(main_path)
        and reaper.file_exists(app_path)) then
  fail(("Could not find Spectracular in its expected location: %s"):format(base_dir))
end

----------------------------------------------------------------------
-- Patch modules/settings.lua: default curves channel mode => L (chan_mode = 1)
-- + add viewport persistence settings
----------------------------------------------------------------------

local function patch_settings(path)
  local txt = read_file(path)

  -- FCP: Split logic for already patched vs not found
  local patched, n = txt:gsub(
    "(chan_mode%s*=%s*)(%d+)",
    function(prefix, val)
      if val == "1" then return prefix .. val end
      return prefix .. "1"
    end,
    1
  )

  if n == 0 then
    fail("settings.lua: failed to patch chan_mode default (pattern not found).")
  elseif patched == txt then
    reaper.ShowConsoleMsg("Spectracular defaults patch: settings.lua already has chan_mode default = L.\n")
  else
    txt = patched
    reaper.ShowConsoleMsg("Spectracular defaults patch: settings.lua patched (chan_mode default -> L).\n")
  end

  -- FCP: Add viewport persistence settings to SettingDefs
  local viewport_settings = [[  ViewportVB          = { type = "double",  default = nil },
  ViewportVT          = { type = "double",  default = nil },
  ViewportUSpan       = { type = "double",  default = nil },]]

  if txt:find("ViewportVB", 1, true) then
      reaper.ShowConsoleMsg("Spectracular defaults patch: settings.lua viewport settings already present.\n")
  else
      -- Insert after AutoRefresh line
      local insert_after = [[AutoRefresh         = { type = "bool",    default = false}]]
      local insert_replacement = insert_after .. ",\n" .. viewport_settings
      
      local new_txt, n_insert = plain_replace(txt, insert_after, insert_replacement)
      if n_insert > 0 then
          txt = new_txt
          reaper.ShowConsoleMsg("Spectracular defaults patch: settings.lua viewport settings added.\n")
      else
          reaper.ShowConsoleMsg("Spectracular defaults patch: warning, could not add viewport settings to SettingDefs.\n")
      end
  end

  write_file(path, txt)
end

----------------------------------------------------------------------
-- Patch widgets/spectrograph.lua:
--  * default zoom around E3–A4, centered on edit cursor
--  * wheel behaviour:
--      - no modifier: horizontal pan
--      - Ctrl: vertical zoom (small step)
--      - Alt: horizontal zoom
----------------------------------------------------------------------

local function patch_spectrograph(path)
  local txt = read_file(path)

  if not txt:find("SpectrographWidget:resetVerticalZoom", 1, true)
     or not txt:find("SpectrographWidget:resetHorizontalZoom", 1, true) then
    fail("spectrograph.lua: reset functions not found.")
  end

  --------------------------------------------------------------------
  -- FCP: Ensure settings module is imported for viewport persistence
  --------------------------------------------------------------------
  if not txt:find('require "modules/settings"', 1, true) then
      -- Add settings import after the UTILS import
      local utils_import = 'local UTILS                     = require "modules/utils"'
      local settings_import = 'local S                         = require "modules/settings"'
      
      if txt:find(utils_import, 1, true) then
          local new_txt, n = plain_replace(txt, utils_import, utils_import .. "\n" .. settings_import)
          if n > 0 then
              txt = new_txt
              reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua settings module import added.\n")
          end
      else
          reaper.ShowConsoleMsg("Spectracular defaults patch: warning, could not find UTILS import to add settings import after.\n")
      end
  else
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua settings module already imported.\n")
  end

  --------------------------------------------------------------------
  -- Inject _applyDefaultViewForCurrentContext + wrapped reset* once
  --------------------------------------------------------------------
  local new_reset_block = [[
function SpectrographWidget:_applyDefaultViewForCurrentContext()
    -- FCP: default view around E3–A4, centered on edit cursor
    -- Uses saved viewport if available
    local sac = self:spectrumContext()
    if not sac or not sac.signal or not sac.signal.start or not sac.signal.stop then return end

    local nr = sac:noteRange()
    if not nr or not nr.low_note or not nr.high_note then return end

    local semi     = sac.semi_tone_slices or 1
    local pixcount = sac.slice_size or 0
    if pixcount <= 0 then return end

    local function note_to_v(note)
        note = math.max(nr.low_note, math.min(nr.high_note, note))
        local pix_offset = (note - nr.low_note) * semi + 0.5
        return 1 - pix_offset / pixcount
    end

    ------------------------------------------------------------
    -- 1) Vertical range: use saved or default E3 (52) to A4 (69)
    ------------------------------------------------------------
    local saved_vb = S.getSetting("ViewportVB")
    local saved_vt = S.getSetting("ViewportVT")
    
    if saved_vb and saved_vt and saved_vb < saved_vt then
        self.vp_v_b = saved_vb
        self.vp_v_t = saved_vt
    else
        local E3 = 52
        local A4 = 69
        local v_bottom = note_to_v(E3)
        local v_top = note_to_v(A4)
        self.vp_v_b = v_top
        self.vp_v_t = v_bottom
    end

    ------------------------------------------------------------
    -- 2) Horizontal range: use saved span or default ~3 seconds, centered on edit cursor
    ------------------------------------------------------------
    local fullDur = (sac.signal.duration or (sac.signal.stop - sac.signal.start))
    if fullDur <= 0 then
        self.vp_u_l = 0
        self.vp_u_r = 1
        return
    end

    local saved_u_span = S.getSetting("ViewportUSpan")
    local u_span
    
    if saved_u_span and saved_u_span > 0 and saved_u_span <= 1 then
        u_span = saved_u_span
    else
        local time_span = 3.0  -- show 3 seconds
        if time_span > fullDur then time_span = fullDur end
        u_span = time_span / fullDur
    end

    -- Center on edit cursor
    local t_center = reaper.GetCursorPosition()
    if t_center < sac.signal.start or t_center > sac.signal.stop then
        t_center = sac.signal.start + 0.5 * fullDur
    end

    local u_center = (t_center - sac.signal.start) / fullDur
    local u_l = u_center - 0.5 * u_span

    if u_l < 0 then u_l = 0 end
    if u_l + u_span > 1 then u_l = 1 - u_span end

    self.vp_u_l = u_l
    self.vp_u_r = u_l + u_span
end

function SpectrographWidget:saveViewportState()
    -- FCP: Save current viewport to persistent settings
    S.setSetting("ViewportVB", self.vp_v_b)
    S.setSetting("ViewportVT", self.vp_v_t)
    local u_span = self.vp_u_r - self.vp_u_l
    S.setSetting("ViewportUSpan", u_span)
end

function SpectrographWidget:resetVerticalZoom()
    if self.sc then
        local old_ul, old_ur = self.vp_u_l, self.vp_u_r
        self:_applyDefaultViewForCurrentContext()
        self.vp_u_l, self.vp_u_r = old_ul, old_ur
    else
        self.vp_v_t = 1
        self.vp_v_b = 0
    end
end

function SpectrographWidget:resetHorizontalZoom()
    if self.sc then
        local old_vb, old_vt = self.vp_v_b, self.vp_v_t
        self:_applyDefaultViewForCurrentContext()
        self.vp_v_b, self.vp_v_t = old_vb, old_vt
    else
        self.vp_u_l = 0
        self.vp_u_r = 1
    end
end
]]

  if txt:find(new_reset_block, 1, true) then
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua reset/zoom block already present.\n")
  else
      local rvz_sig = "function SpectrographWidget:resetVerticalZoom()"
      local rhz_sig = "function SpectrographWidget:resetHorizontalZoom()"
      
      local old_rvz = get_function_block(txt, rvz_sig)
      local old_rhz = get_function_block(txt, rhz_sig)

      if old_rvz and old_rhz then
          -- Replace vertical zoom with new block
          txt = plain_replace(txt, old_rvz, new_reset_block)
          -- Remove horizontal zoom (it's in the new block now)
          txt = plain_replace(txt, old_rhz, "")
          
          reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua reset/zoom block patched.\n")
      else
          fail("spectrograph.lua: could not find reset functions to replace.")
      end
  end

  --------------------------------------------------------------------
  -- Ensure setSpectrumContext calls our helper ONCE (not on resize)
  --------------------------------------------------------------------
  local set_sig = "function SpectrographWidget:setSpectrumContext(spectrum_context)"
  local old_set = get_function_block(txt, set_sig)

  local new_set_block = [[
function SpectrographWidget:setSpectrumContext(spectrum_context)
    self.sc                 = spectrum_context
    self.need_refresh_rgb   = true
    -- FCP: apply default view only when loading new spectrum (not on resize)
    if not self.viewport_initialized then
        self:_applyDefaultViewForCurrentContext()
        self.viewport_initialized = true
    end
    self.cursor_draw_profile:rebuildData(self.sc)
    self.cursor_slice_draw_profile:rebuildData(self.sc)
    self.rmse_draw_profile:rebuildData(self.sc)
    for _, p in pairs(self.extracted_profiles) do
        p:rebuildData(self.sc)
    end
end]]

  if not old_set then
      fail("spectrograph.lua: setSpectrumContext not found.")
  elseif old_set == new_set_block then
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua setSpectrumContext already patched.\n")
  else
      local patched2, n2 = plain_replace(txt, old_set, new_set_block)
      if n2 > 0 then
          txt = patched2
          reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua setSpectrumContext patched.\n")
      else
          fail("spectrograph.lua: could not patch setSpectrumContext().")
      end
  end

  --------------------------------------------------------------------
  -- Patch setCanvas to handle resize without stretching
  --------------------------------------------------------------------
  local canvas_sig = "function SpectrographWidget:setCanvas(x,y,w,h)"
  local old_setCanvas = get_function_block(txt, canvas_sig)

  local new_setCanvas = [[
function SpectrographWidget:setCanvas(x,y,w,h)
    local old_w = self.w
    local old_h = self.h
    local old_x = self.x
    local old_y = self.y

    self.canvas_pos_changed    = not (self.x == x and self.y == y)
    self.canvas_size_changed   = not (self.w == w and self.h == h)
    self.canvas_changed        = self.canvas_pos_changed or self.canvas_size_changed

    self.x = x
    self.y = y
    self.w = w
    self.h = h

    -- FCP: Adjust viewport to maintain zoom level on resize
    if self.canvas_size_changed and old_w and old_w > 0 and old_h and old_h > 0 then
        -- Horizontal
        local u_span = self.vp_u_r - self.vp_u_l
        local new_u_span = u_span * (w / old_w)
        
        if new_u_span >= 1.0 then
            self.vp_u_l = 0
            self.vp_u_r = 1
        else
            -- If x changed significantly, we are resizing from left -> Anchor Right
            if math.abs(x - old_x) > 0.5 then
                self.vp_u_l = self.vp_u_r - new_u_span
                if self.vp_u_l < 0 then
                    local diff = -self.vp_u_l
                    self.vp_u_l = 0
                    self.vp_u_r = math.min(1.0, self.vp_u_r + diff)
                end
            else
                -- Anchor Left
                self.vp_u_r = self.vp_u_l + new_u_span
                if self.vp_u_r > 1.0 then
                    local diff = self.vp_u_r - 1.0
                    self.vp_u_r = 1.0
                    self.vp_u_l = math.max(0, self.vp_u_l - diff)
                end
            end
        end

        -- Vertical
        local v_span = self.vp_v_t - self.vp_v_b
        local new_v_span = v_span * (h / old_h)
        if new_v_span >= 1.0 then
            self.vp_v_b = 0
            self.vp_v_t = 1
        else
            -- If y changed significantly, we are resizing from top -> Anchor Bottom
            if math.abs(y - old_y) > 0.5 then
                self.vp_v_b = self.vp_v_t - new_v_span
                if self.vp_v_b < 0 then
                    local diff = -self.vp_v_b
                    self.vp_v_b = 0
                    self.vp_v_t = math.min(1, self.vp_v_t + diff)
                end
            else
                -- Anchor Top
                self.vp_v_t = self.vp_v_b + new_v_span
                if self.vp_v_t > 1 then
                    local diff = self.vp_v_t - 1
                    self.vp_v_t = 1
                    self.vp_v_b = math.max(0, self.vp_v_b - diff)
                end
            end
        end
    end
end]]

  if not old_setCanvas then
      fail("spectrograph.lua: setCanvas not found.")
  elseif old_setCanvas == new_setCanvas then
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua setCanvas already patched.\n")
  else
      local patched_canvas, n_canvas = plain_replace(txt, old_setCanvas, new_setCanvas)
      if n_canvas == 0 then
          fail("spectrograph.lua: could not patch setCanvas.")
      end
      txt = patched_canvas
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua setCanvas patched.\n")
  end

  --------------------------------------------------------------------
  -- Patch handleMouseWheel
  --------------------------------------------------------------------
  local wheel_sig = "function SpectrographWidget:handleMouseWheel(ctx)"
  local old_wheel = get_function_block(txt, wheel_sig)

  local new_wheel_block = [[
function SpectrographWidget:handleMouseWheel(ctx)
    -- FCP: Don't consume mouse events when a popup (FFT/RMS dropdown) is open
    local popup_open = ImGui.IsPopupOpen(ctx, "", ImGui.PopupFlags_AnyPopupId + ImGui.PopupFlags_AnyPopupLevel)
    if popup_open then return end

    local mx, my = ImGui.GetMousePos(ctx)

    -- Check if mouse is over active MIDI editor using SWS BR_GetMouseCursorContext
    local over_midi_editor = false
    if reaper.BR_GetMouseCursorContext then
        local window, segment, details = reaper.BR_GetMouseCursorContext()
        -- window will be "midi_editor" when mouse is over the MIDI editor piano roll/note area
        if window == "midi_editor" then
            over_midi_editor = true
        end
    end

    -- Only proceed when hovering the spectrograph itself OR the MIDI editor
    local over_spectro = self:containsPoint(mx, my)
    if not over_spectro and not over_midi_editor then return end
    if self.mw and self.mw.prehemptsMouse and self.mw:prehemptsMouse() then return end
    if self.lr_mix_widget and self.lr_mix_widget:containsPoint(mx, my) then return end

    local sac = self:spectrumContext()
    if not sac or not sac.signal or not sac.signal.start or not sac.signal.stop then return end

    local mw = select(1, ImGui.GetMouseWheel(ctx)) -- >0 up, <0 down
    if mw == 0 then return end

    -- Primary Ctrl/Command modifier from Spectracular helper
    local ctrlDown = (UTILS.modifierKeyIsDown and UTILS.modifierKeyIsDown()) or false
    -- Alt: (1 << 4) == 16
    local altDown  = (reaper.JS_Mouse_GetState(1<<4) ~= 0)
    -- Shift: (1 << 3) == 8
    local shiftDown = (reaper.JS_Mouse_GetState(1<<3) ~= 0)

    -- If over MIDI editor with any modifier, let REAPER handle it natively
    if over_midi_editor and (ctrlDown or altDown or shiftDown) then
        return
    end

    if ctrlDown then
        ----------------------------------------------------------------
        -- Ctrl + wheel: vertical zoom of spectrogram (small step)
        ----------------------------------------------------------------
        local mouse_uv  = self:xyToUV(mx, my)
        local zoom_step = 0.99   -- very gentle zoom per notch
        local zoompower = (mw > 0) and zoom_step or (1.0 / zoom_step)

        local newrange = mouse_uv.rangev * zoompower
        if newrange < 0.02 then newrange = 0.02 end

        local vb = mouse_uv.v - mouse_uv.alphay * newrange
        if vb < 0 then vb = 0 end
        local vt = vb + newrange
        if vt > 1 then
            vt = 1
            vb = vt - newrange
            if vb < 0 then vb = 0 end
        end

        self.vp_v_b = vb
        self.vp_v_t = vt
        return

    elseif shiftDown then
        ----------------------------------------------------------------
        -- Shift + wheel: horizontal pan by fixed time slice (~0.5 s)
        ----------------------------------------------------------------
        local fullDur = sac.signal.duration or (sac.signal.stop - sac.signal.start)
        if fullDur <= 0 then return end

        local scrollSec = 0.5
        local uShift    = -mw * (scrollSec / fullDur)

        local uRange = self.vp_u_r - self.vp_u_l
        local newUl  = math.max(0, math.min(1 - uRange, self.vp_u_l + uShift))
        self.vp_u_l  = newUl
        self.vp_u_r  = newUl + uRange
        return

    elseif altDown then
        ----------------------------------------------------------------
        -- Alt + wheel: horizontal zoom around mouse
        ----------------------------------------------------------------
        local mouse_uv = self:xyToUV(mx, my)
        local wpower   = math.ceil(math.log(math.abs(mw)/0.1 * math.exp(0)))
        local zoompower = ((mw > 0) and 0.9 or 1.1) ^ wpower

        local newrange = mouse_uv.rangeu * zoompower
        local fullDur  = sac.signal.duration or (sac.signal.stop - sac.signal.start)
        local nrs      = fullDur * newrange

        if nrs < 0.01 then
            nrs      = 0.01
            newrange = nrs / fullDur
        end

        self.vp_u_l = mouse_uv.u - mouse_uv.alphax * newrange
        if self.vp_u_l < 0 then self.vp_u_l = 0 end
        self.vp_u_r = self.vp_u_l + newrange
        if self.vp_u_r > 1 then self.vp_u_r = 1 end
        return

    else
        ----------------------------------------------------------------
        -- No modifiers: vertical pan by 1 note row
        ----------------------------------------------------------------
        local semi     = sac.semi_tone_slices or 1
        local pixcount = sac.slice_size or 1
        if pixcount <= 0 then return end

        local v_step = semi / pixcount
        
        -- mw > 0 (up) -> view moves up (show higher notes) -> V decreases
        local direction = (mw > 0) and -1 or 1

        -- FCP: Sync MIDI editor view
        local me = reaper.MIDIEditor_GetActive()
        if me then
            if mw > 0 then
                reaper.MIDIEditor_OnCommand(me, 40138) -- View: Scroll view up
            else
                reaper.MIDIEditor_OnCommand(me, 40139) -- View: Scroll view down
            end
        end

        local delta     = direction * v_step

        local range = self.vp_v_t - self.vp_v_b
        local new_b = self.vp_v_b + delta
        local new_t = self.vp_v_t + delta

        if new_b < 0 then
            new_b = 0
            new_t = range
        end
        if new_t > 1 then
            new_t = 1
            new_b = 1 - range
        end

        self.vp_v_b = new_b
        self.vp_v_t = new_t
        return
    end
end]]


  if not old_wheel then
      fail("spectrograph.lua: handleMouseWheel not found.")
  elseif old_wheel == new_wheel_block then
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua handleMouseWheel already patched.\n")
  else
      local patched3, n3 = plain_replace(txt, old_wheel, new_wheel_block)
      if n3 == 0 then
        fail("spectrograph.lua: could not patch handleMouseWheel().")
      end
      txt = patched3
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua handleMouseWheel patched (vert-pan/Ctrl-vert-zoom/Alt-horiz-zoom/Shift-horiz-pan).\n")
  end

  --------------------------------------------------------------------
  -- Inject scrub helpers (needed for handleLeftMouse)
  --------------------------------------------------------------------
  local scrub_helpers = [[
-- timed scrub after moving the edit cursor from Spectrograph
local DURATION_MS = 384
local EXT_SECTION = "FCP_SCRUB_WATCH" -- shared between left/right to cancel older instances

local function start_auto_stop_scrub(token, ms)
    local t0 = reaper.time_precise()
    local function tick()
        if reaper.GetExtState(EXT_SECTION, "token") ~= token then return end
        if reaper.time_precise() - t0 >= (ms or DURATION_MS) / 1000.0 then
            reaper.Main_OnCommand(41189, 0) -- Scrub: Disable looped-segment scrub at edit cursor
            return
        end
        reaper.defer(tick)
    end
    reaper.defer(tick)
end
]]

  if not txt:find("start_auto_stop_scrub", 1, true) then
      local marker = "local SpectrographWidget = {}"
      if txt:find(marker, 1, true) then
          txt = plain_replace(txt, marker, scrub_helpers .. "\n" .. marker)
          reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua scrub helpers injected.\n")
      else
          -- Try finding where SpectrographWidget is defined if spacing is different
          local marker2 = "local SpectrographWidget={}"
          if txt:find(marker2, 1, true) then
             txt = plain_replace(txt, marker2, scrub_helpers .. "\n" .. marker2)
             reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua scrub helpers injected.\n")
          else
             reaper.ShowConsoleMsg("Spectracular defaults patch: warning, could not find SpectrographWidget definition to inject scrub helpers.\n")
          end
      end
  end

  --------------------------------------------------------------------
  -- Replace handleLeftMouse: pan on drag, click = move edit cursor
  --------------------------------------------------------------------
  local left_sig = "function SpectrographWidget:handleLeftMouse(ctx)"
  local old_left = get_function_block(txt, left_sig)

  local new_left_block = [[function SpectrographWidget:handleLeftMouse(ctx)
    local mx, my = ImGui.GetMousePos(ctx)
    local dx, dy = ImGui.GetMouseDragDelta(ctx, ImGui.MouseButton_Left)

    local inside  = self:containsPoint(mx, my)
    local preempt = self.mw and self.mw.prehemptsMouse and self.mw:prehemptsMouse()
    local over_lr = self.lr_mix_widget and self.lr_mix_widget:containsPoint(mx, my)

    -- FCP: Don't consume mouse events when a popup (FFT/RMS dropdown) is open
    local popup_open = ImGui.IsPopupOpen(ctx, "", ImGui.PopupFlags_AnyPopupId + ImGui.PopupFlags_AnyPopupLevel)
    if popup_open then return end

    -- FCP: Helper to find if mouse is near a note edge
    local function findNoteEdge(mx, my, edge_threshold)
        local me = reaper.MIDIEditor_GetActive()
        if not me then return nil end
        local take = reaper.MIDIEditor_GetTake(me)
        if not take then return nil end
        local sac = self:spectrumContext()
        if not sac or not sac.signal then return nil end
        
        local note_float = self:yToNoteNum(my)
        local hoveredPitch = math.floor(note_float + 0.5)
        
        local idx = 0
        while true do
            local retval, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, idx)
            if not retval then break end
            
            if pitch == hoveredPitch then
                local note_start = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                local note_end = reaper.MIDI_GetProjTimeFromPPQPos(take, endppq)
                
                local x_start = self:timeToX(note_start)
                local x_end = self:timeToX(note_end)
                local y_top = self:noteNumToY(pitch + 0.5)
                local y_bottom = self:noteNumToY(pitch - 0.5)
                
                -- Check if mouse Y is within note height
                if my >= y_top and my <= y_bottom then
                    -- Check left edge
                    if math.abs(mx - x_start) <= edge_threshold then
                        return { idx = idx, edge = "left", take = take, startppq = startppq, endppq = endppq, pitch = pitch, chan = chan, vel = vel, selected = selected, muted = muted }
                    end
                    -- Check right edge
                    if math.abs(mx - x_end) <= edge_threshold then
                        return { idx = idx, edge = "right", take = take, startppq = startppq, endppq = endppq, pitch = pitch, chan = chan, vel = vel, selected = selected, muted = muted }
                    end
                end
            end
            idx = idx + 1
        end
        return nil
    end

    -- FCP: Helper to find if mouse is over a note (not just edge)
    local function findNoteAtPosition(mx, my)
        local me = reaper.MIDIEditor_GetActive()
        if not me then return nil end
        local take = reaper.MIDIEditor_GetTake(me)
        if not take then return nil end
        local sac = self:spectrumContext()
        if not sac or not sac.signal then return nil end
        
        local note_float = self:yToNoteNum(my)
        local hoveredPitch = math.floor(note_float + 0.5)
        
        local idx = 0
        while true do
            local retval, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, idx)
            if not retval then break end
            
            if pitch == hoveredPitch then
                local note_start = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                local note_end = reaper.MIDI_GetProjTimeFromPPQPos(take, endppq)
                
                local x_start = self:timeToX(note_start)
                local x_end = self:timeToX(note_end)
                local y_top = self:noteNumToY(pitch + 0.5)
                local y_bottom = self:noteNumToY(pitch - 0.5)
                
                -- Check if mouse is within note bounds
                if my >= y_top and my <= y_bottom and mx >= x_start and mx <= x_end then
                    return { idx = idx, take = take }
                end
            end
            idx = idx + 1
        end
        return nil
    end

    -- FCP: Double-click to insert or delete MIDI note
    if ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left)
       and not preempt
       and not over_lr
       and inside then
        
        local me = reaper.MIDIEditor_GetActive()
        if me then
            local take = reaper.MIDIEditor_GetTake(me)
            if take then
                -- FCP: Check if double-clicking on an existing note - delete it
                local noteAtPos = findNoteAtPosition(mx, my)
                if noteAtPos then
                    reaper.MIDI_DeleteNote(noteAtPos.take, noteAtPos.idx)
                    reaper.MIDI_Sort(noteAtPos.take)
                    reaper.MarkProjectDirty(0)
                    reaper.MIDIEditor_OnCommand(me, 40767) -- Refresh
                    return
                end

                local sac = self:spectrumContext()
                if sac and sac.signal and sac.signal.stop > sac.signal.start then
                    -- Get note pitch from Y position
                    local note_float = self:yToNoteNum(my)
                    local midiNote = math.floor(note_float + 0.5)
                    
                    if midiNote >= 0 and midiNote <= 127 then
                        -- Get time from X position
                        local relx = (mx - self.x) / self.w
                        if relx < 0 then relx = 0 elseif relx > 1 then relx = 1 end
                        local u = self.vp_u_l + relx * (self.vp_u_r - self.vp_u_l)
                        local t_click = sac.signal.start + u * (sac.signal.stop - sac.signal.start)
                        
                        -- 1/128th note grid step in QN
                        local step = 1/32
                        
                        -- Snap click position to grid
                        local qn_click = reaper.TimeMap2_timeToQN(0, t_click)
                        local snappedQN = math.floor(qn_click / step + 0.5) * step
                        
                        -- Helper to get max dB across all channels at a given time
                        local function getMaxDbAt(time_pos)
                            local maxDb = -math.huge
                            for ch = 1, sac.chan_count do
                                local db = sac:getValueAt(ch, note_float, time_pos)
                                if db and db > maxDb then maxDb = db end
                            end
                            return maxDb
                        end
                        
                        -- Helper to find existing notes at same pitch and get their boundaries
                        local function getExistingNotesAtPitch(pitch)
                            local notes = {}
                            local idx = 0
                            while true do
                                local retval, sel, mut, startppq, endppq, ch, p, vel = reaper.MIDI_GetNote(take, idx)
                                if not retval then break end
                                if p == pitch then
                                    local note_start_time = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                                    local note_end_time = reaper.MIDI_GetProjTimeFromPPQPos(take, endppq)
                                    local note_start_qn = reaper.TimeMap2_timeToQN(0, note_start_time)
                                    local note_end_qn = reaper.TimeMap2_timeToQN(0, note_end_time)
                                    table.insert(notes, { startQN = note_start_qn, endQN = note_end_qn })
                                end
                                idx = idx + 1
                            end
                            return notes
                        end
                        
                        -- Helper to get all note boundaries (start and end times) from all pitches
                        local function getAllNoteBoundaries()
                            local boundaries = {}
                            local idx = 0
                            while true do
                                local retval, sel, mut, startppq, endppq, ch, p, vel = reaper.MIDI_GetNote(take, idx)
                                if not retval then break end
                                local note_start_time = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                                local note_end_time = reaper.MIDI_GetProjTimeFromPPQPos(take, endppq)
                                local note_start_qn = reaper.TimeMap2_timeToQN(0, note_start_time)
                                local note_end_qn = reaper.TimeMap2_timeToQN(0, note_end_time)
                                table.insert(boundaries, note_start_qn)
                                table.insert(boundaries, note_end_qn)
                                idx = idx + 1
                            end
                            -- Sort boundaries
                            table.sort(boundaries)
                            return boundaries
                        end
                        
                        -- Helper to check if a QN position would collide with existing notes
                        local function wouldCollideLeft(testQN, existingNotes)
                            for _, n in ipairs(existingNotes) do
                                -- If testQN is within or at the end of an existing note
                                if testQN >= n.startQN and testQN < n.endQN then
                                    return n.endQN  -- Return the end of that note (boundary)
                                end
                            end
                            return nil
                        end
                        
                        local function wouldCollideRight(testQN, existingNotes)
                            for _, n in ipairs(existingNotes) do
                                -- If testQN is within or at the start of an existing note
                                if testQN > n.startQN and testQN <= n.endQN then
                                    return n.startQN  -- Return the start of that note (boundary)
                                end
                                -- If we're about to enter an existing note
                                if testQN >= n.startQN and testQN < n.endQN then
                                    return n.startQN
                                end
                            end
                            return nil
                        end
                        
                        local existingNotes = getExistingNotesAtPitch(midiNote)
                        local allBoundaries = getAllNoteBoundaries()
                        
                        local DB_THRESHOLD = -45
                        local t_snapped = reaper.TimeMap2_QNToTime(0, snappedQN)
                        local clickDb = getMaxDbAt(t_snapped)
                        
                        local startQN, endQN
                        
                        if clickDb and clickDb > DB_THRESHOLD then
                            -- dB is above threshold: scan left and right to find boundaries
                            local signalStartQN = reaper.TimeMap2_timeToQN(0, sac.signal.start)
                            local signalEndQN = reaper.TimeMap2_timeToQN(0, sac.signal.stop)
                            
                            -- Scan left
                            startQN = snappedQN
                            while startQN > signalStartQN do
                                local testQN = startQN - step
                                
                                -- Check for collision with existing note at same pitch
                                for _, n in ipairs(existingNotes) do
                                    if testQN < n.endQN and testQN >= n.startQN then
                                        -- Would collide, stop one step after the note ends
                                        startQN = n.endQN + step
                                        -- Snap to grid
                                        startQN = math.ceil(startQN / step) * step
                                        goto done_left
                                    end
                                    if testQN < n.endQN and startQN >= n.endQN then
                                        -- About to cross into a note's end boundary
                                        startQN = n.endQN + step
                                        startQN = math.ceil(startQN / step) * step
                                        goto done_left
                                    end
                                end
                                
                                -- Check for any note boundary (any pitch) - stop one step after
                                for _, boundaryQN in ipairs(allBoundaries) do
                                    if testQN < boundaryQN and startQN >= boundaryQN then
                                        -- About to cross a boundary, stop one step after it
                                        startQN = boundaryQN + step
                                        startQN = math.ceil(startQN / step) * step
                                        goto done_left
                                    end
                                end
                                
                                local testTime = reaper.TimeMap2_QNToTime(0, testQN)
                                local testDb = getMaxDbAt(testTime)
                                if not testDb or testDb <= DB_THRESHOLD then
                                    break
                                end
                                startQN = testQN
                            end
                            ::done_left::
                            
                            -- Scan right
                            endQN = snappedQN + step  -- at least 1 grid step
                            while endQN < signalEndQN do
                                -- Check for collision with existing note at same pitch
                                for _, n in ipairs(existingNotes) do
                                    if endQN > n.startQN and endQN <= n.endQN then
                                        -- Would collide, stop one step before the note starts
                                        endQN = n.startQN - step
                                        if endQN < snappedQN + step then endQN = snappedQN + step end
                                        -- Snap to grid
                                        endQN = math.floor(endQN / step) * step
                                        goto done_right
                                    end
                                    if endQN >= n.startQN and (endQN - step) < n.startQN then
                                        -- About to cross into a note's start boundary
                                        endQN = n.startQN - step
                                        if endQN < snappedQN + step then endQN = snappedQN + step end
                                        endQN = math.floor(endQN / step) * step
                                        goto done_right
                                    end
                                end
                                
                                -- Check for any note boundary (any pitch) - stop one step before
                                for _, boundaryQN in ipairs(allBoundaries) do
                                    if endQN >= boundaryQN and (endQN - step) < boundaryQN then
                                        -- About to cross a boundary, stop one step before it
                                        endQN = boundaryQN - step
                                        if endQN < snappedQN + step then endQN = snappedQN + step end
                                        endQN = math.floor(endQN / step) * step
                                        goto done_right
                                    end
                                end
                                
                                local testTime = reaper.TimeMap2_QNToTime(0, endQN)
                                local testDb = getMaxDbAt(testTime)
                                if not testDb or testDb <= DB_THRESHOLD then
                                    break
                                end
                                endQN = endQN + step
                            end
                            ::done_right::
                        else
                            -- dB is below threshold: use default grid length
                            startQN = snappedQN
                            local grid_qn = reaper.MIDI_GetGrid(take) or 0.5
                            if grid_qn <= 0 then grid_qn = 0.5 end
                            endQN = snappedQN + grid_qn
                        end
                        
                        -- Ensure minimum note length of 1 grid step
                        if endQN <= startQN then
                            endQN = startQN + step
                        end
                        
                        -- Get default channel and velocity from MIDI editor
                        local chan = reaper.MIDIEditor_GetSetting_int(me, "default_note_chan") or 0
                        if chan < 0 then chan = 0 elseif chan > 15 then chan = 15 end
                        local vel = reaper.MIDIEditor_GetSetting_int(me, "default_note_vel") or 96
                        if vel < 1 then vel = 96 elseif vel > 127 then vel = 127 end
                        
                        local t_start = reaper.TimeMap2_QNToTime(0, startQN)
                        local t_end = reaper.TimeMap2_QNToTime(0, endQN)
                        
                        -- Convert to PPQ
                        local startppq = reaper.MIDI_GetPPQPosFromProjTime(take, t_start)
                        local endppq = reaper.MIDI_GetPPQPosFromProjTime(take, t_end)
                        
                        -- Insert the note (selected, not muted)
                        reaper.MIDI_InsertNote(take, true, false, startppq, endppq, chan, midiNote, vel, false)
                        reaper.MIDI_Sort(take)
                        reaper.MarkProjectDirty(0)
                        
                        -- Refresh MIDI editor
                        reaper.MIDIEditor_OnCommand(me, 40767) -- Refresh
                    end
                end
            end
        end
        return  -- Don't process as single click
    end

    -- Start of click: check for note edge drag OR memorize viewport for panning
    if ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Left)
       and not UTILS.modifierKeyIsDown()
       and not preempt
       and not over_lr
       and inside then

        -- FCP: Check if clicking on a note edge (5 pixel threshold)
        local edgeInfo = findNoteEdge(mx, my, 5)
        if edgeInfo then
            -- Start edge drag mode
            self.edge_drag = {
                idx = edgeInfo.idx,
                edge = edgeInfo.edge,
                take = edgeInfo.take,
                orig_startppq = edgeInfo.startppq,
                orig_endppq = edgeInfo.endppq,
                pitch = edgeInfo.pitch,
                chan = edgeInfo.chan,
                vel = edgeInfo.vel,
                selected = edgeInfo.selected,
                muted = edgeInfo.muted
            }
            self.click = nil  -- Don't do normal click behavior
            return
        end

        local mouse_uv = self:xyToUV(mx, my)

        self.click = {
            x  = mx,
            y  = my,
            u  = mouse_uv.u,
            v  = mouse_uv.v,
            vb = self.vp_v_b,
            vt = self.vp_v_t,
            hl = self.vp_u_l,
            hr = self.vp_u_r,
            lock_vertical = false,
            -- FCP: Note preview state
            preview_active = false,
            preview_note = nil,
            preview_chan = nil,
            preview_track = nil,
            orig_arm = nil,
            orig_mon = nil,
            orig_in = nil
        }
        
        -- FCP: Start note preview immediately on click
        local me = reaper.MIDIEditor_GetActive()
        if me then
            local note_float = self:yToNoteNum(my)
            local midiNote   = math.floor(note_float + 0.5)
            
            if midiNote >= 0 and midiNote <= 127 then
                local take2 = reaper.MIDIEditor_GetTake(me)
                if take2 then
                    local tr = reaper.GetMediaItemTake_Track(take2)
                    if tr then
                        local chan = reaper.MIDIEditor_GetSetting_int(me, "default_note_chan") or 0
                        if chan < 0 then chan = 0 elseif chan > 15 then chan = 15 end
                        local vel = 96
                        
                        -- Save original track state
                        self.click.orig_arm = reaper.GetMediaTrackInfo_Value(tr, "I_RECARM")
                        self.click.orig_mon = reaper.GetMediaTrackInfo_Value(tr, "I_RECMON")
                        self.click.orig_in  = reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT")
                        
                        -- VKB input routing: MIDI_FLAG(4096) + CH_ALL(0) + VKB_DEVICE(62) * 32 = 6080
                        local recinput_vkb = 4096 + 0 + (62 * 32)
                        
                        -- Configure track for VKB preview
                        reaper.PreventUIRefresh(1)
                        if self.click.orig_arm ~= 1 then reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1) end
                        if self.click.orig_mon ~= 1 then reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1) end
                        if math.floor(self.click.orig_in or 0) ~= recinput_vkb then
                            reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", recinput_vkb)
                        end
                        reaper.TrackList_AdjustWindows(false)
                        reaper.PreventUIRefresh(-1)
                        
                        -- Send Note On
                        reaper.StuffMIDIMessage(0, 0x90 + chan, midiNote, vel)
                        
                        -- Store preview state for cleanup on release
                        self.click.preview_active = true
                        self.click.preview_note = midiNote
                        self.click.preview_chan = chan
                        self.click.preview_track = tr
                    end
                end
            end
        end
    end

    -- Mouse drag, left button: edge drag OR pan
    if not preempt and ImGui.IsMouseDragging(ctx, ImGui.MouseButton_Left) then
        -- FCP: Handle note edge dragging
        if self.edge_drag then
            local sac = self:spectrumContext()
            if sac and sac.signal then
                -- Convert mouse X to time
                local relx = (mx - self.x) / self.w
                if relx < 0 then relx = 0 elseif relx > 1 then relx = 1 end
                local u = self.vp_u_l + relx * (self.vp_u_r - self.vp_u_l)
                local t = sac.signal.start + u * (sac.signal.stop - sac.signal.start)
                
                -- Snap to 1/128th note grid
                local qn = reaper.TimeMap2_timeToQN(0, t)
                local step = 1/32  -- 1/128th note in QN
                local snappedQN = math.floor(qn / step + 0.5) * step
                local snapped_time = reaper.TimeMap2_QNToTime(0, snappedQN)
                local new_ppq = reaper.MIDI_GetPPQPosFromProjTime(self.edge_drag.take, snapped_time)
                
                local new_startppq = self.edge_drag.orig_startppq
                local new_endppq = self.edge_drag.orig_endppq
                
                if self.edge_drag.edge == "left" then
                    -- Don't allow start to go past end (leave at least 1 grid step)
                    local min_len_qn = step
                    local end_time = reaper.MIDI_GetProjTimeFromPPQPos(self.edge_drag.take, self.edge_drag.orig_endppq)
                    local end_qn = reaper.TimeMap2_timeToQN(0, end_time)
                    local min_start_qn = end_qn - min_len_qn
                    if snappedQN >= min_start_qn then
                        snappedQN = min_start_qn - step
                        snapped_time = reaper.TimeMap2_QNToTime(0, snappedQN)
                        new_ppq = reaper.MIDI_GetPPQPosFromProjTime(self.edge_drag.take, snapped_time)
                    end
                    new_startppq = new_ppq
                else
                    -- Don't allow end to go before start (leave at least 1 grid step)
                    local min_len_qn = step
                    local start_time = reaper.MIDI_GetProjTimeFromPPQPos(self.edge_drag.take, self.edge_drag.orig_startppq)
                    local start_qn = reaper.TimeMap2_timeToQN(0, start_time)
                    local min_end_qn = start_qn + min_len_qn
                    if snappedQN <= min_end_qn then
                        snappedQN = min_end_qn + step
                        snapped_time = reaper.TimeMap2_QNToTime(0, snappedQN)
                        new_ppq = reaper.MIDI_GetPPQPosFromProjTime(self.edge_drag.take, snapped_time)
                    end
                    new_endppq = new_ppq
                end
                
                -- Update the note in place
                reaper.MIDI_SetNote(self.edge_drag.take, self.edge_drag.idx, self.edge_drag.selected, self.edge_drag.muted, new_startppq, new_endppq, self.edge_drag.chan, self.edge_drag.pitch, self.edge_drag.vel, true)
            end
            return
        end

        -- Normal pan behavior
        if self.mw and self.mw.rmse_widget and not self.mw.rmse_widget.dragged and self.click then
            local ddx    = dx / self.w
            local uSpan  = (self.vp_u_r - self.vp_u_l)

            self.vp_u_l = self.click.hl - ddx * uSpan
            if self.vp_u_l < 0 then self.vp_u_l = 0 end
            self.vp_u_r = self.vp_u_l + uSpan
            if self.vp_u_r > 1 then self.vp_u_r = 1 end
            self.vp_u_l = self.vp_u_r - uSpan

            if not self.click.lock_vertical then
                local ddy    = dy / self.h
                local vSpan  = (self.vp_v_t - self.vp_v_b)

                self.vp_v_b = self.click.vb - ddy * vSpan
                if self.vp_v_b < 0 then self.vp_v_b = 0 end
                self.vp_v_t = self.vp_v_b + vSpan
                if self.vp_v_t > 1 then
                    local diff = self.vp_v_t - 1
                    self.vp_v_t = 1
                    self.vp_v_b = math.max(0, self.vp_v_b - diff)
                end
                self.vp_v_b = self.vp_v_t - vSpan
            end
        end
        return
    end

    -- Mouse released: stop preview, move edit cursor if no drag
    if ImGui.IsMouseReleased(ctx, ImGui.MouseButton_Left) then
        -- FCP: Finalize edge drag
        if self.edge_drag then
            reaper.MIDI_Sort(self.edge_drag.take)
            reaper.MarkProjectDirty(0)
            self.edge_drag = nil
            -- Push keyboard focus back to the MIDI editor
            if reaper.SN_FocusMIDIEditor then
                reaper.SN_FocusMIDIEditor()
            end
            return
        end

        -- FCP: Stop note preview and restore track state
        if self.click and self.click.preview_active then
            local tr = self.click.preview_track
            local chan = self.click.preview_chan
            local note = self.click.preview_note
            
            -- Send Note Off
            reaper.StuffMIDIMessage(0, 0x80 + chan, note, 0)
            
            -- Restore original track state
            if tr then
                reaper.PreventUIRefresh(1)
                if self.click.orig_arm ~= nil then reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", self.click.orig_arm) end
                if self.click.orig_mon ~= nil then reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", self.click.orig_mon) end
                if self.click.orig_in ~= nil then reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", self.click.orig_in) end
                reaper.TrackList_AdjustWindows(false)
                reaper.PreventUIRefresh(-1)
            end
        end
        
        -- Move edit cursor and set MIDI row on simple click (no drag)
        if inside and not preempt and not over_lr and dx == 0 and dy == 0 then
            local sac = self:spectrumContext()
            if sac and sac.signal and sac.signal.stop > sac.signal.start then
                -- FCP: Check if clicking on a note - select it
                local noteAtPos = findNoteAtPosition(mx, my)
                if noteAtPos then
                    -- Deselect all notes first, then select this one
                    local me = reaper.MIDIEditor_GetActive()
                    if me then
                        reaper.MIDI_SelectAll(noteAtPos.take, false)  -- Deselect all
                        local retval, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(noteAtPos.take, noteAtPos.idx)
                        if retval then
                            reaper.MIDI_SetNote(noteAtPos.take, noteAtPos.idx, true, muted, startppq, endppq, chan, pitch, vel, true)
                            reaper.MIDI_Sort(noteAtPos.take)
                            reaper.MarkProjectDirty(0)
                        end
                    end
                    
                    self.click = nil
                    if reaper.SN_FocusMIDIEditor then
                        reaper.SN_FocusMIDIEditor()
                    end
                    return
                end

                -- horizontal -> time within current viewport
                local relx = (mx - self.x) / self.w
                if relx < 0 then relx = 0 elseif relx > 1 then relx = 1 end

                local u = self.vp_u_l + relx * (self.vp_u_r - self.vp_u_l)
                local t = sac.signal.start + u * (sac.signal.stop - sac.signal.start)

                -- FCP: Always snap to 1/128th note (1/32 of a quarter note)
                local qn = reaper.TimeMap2_timeToQN(0, t)
                local step = 1/32  -- 1/128th note in QN
                local snappedQN = math.floor(qn / step + 0.5) * step
                t = reaper.TimeMap2_QNToTime(0, snappedQN)

                reaper.SetEditCurPos(t, false, false)

                -- vertical -> MIDI note row using the same mapping as the tooltip (yToNoteNum)
                local me = reaper.MIDIEditor_GetActive()
                if me then
                    local note_float = self:yToNoteNum(my)
                    local midiNote   = math.floor(note_float + 0.5)

                    -- only move the pitch cursor if within C2-C6 (36-84)
                    if midiNote >= 36 and midiNote <= 84 then
                        local take2 = reaper.MIDIEditor_GetTake(me)
                        reaper.MIDIEditor_SetSetting_int(me, "active_note_row", midiNote)
                        if take2 then
                            reaper.MIDI_RefreshEditors(take2)
                        end
                    end
                end

                -- timed scrub at new edit cursor
                reaper.PreventUIRefresh(1)
                reaper.Main_OnCommand(41188, 0) -- Scrub: Enable looped-segment scrub at edit cursor
                reaper.PreventUIRefresh(-1)

                local token = tostring(reaper.time_precise()) .. "-" .. tostring(math.random())
                reaper.SetExtState(EXT_SECTION, "token", token, false)
                start_auto_stop_scrub(token, DURATION_MS)

                -- push keyboard focus back to the MIDI editor
                if reaper.SN_FocusMIDIEditor then
                    reaper.SN_FocusMIDIEditor()
                end
            end
        end
        
        self.click = nil
        
        -- FCP: Return focus to MIDI editor only if click was inside spectrograph
        if inside and reaper.SN_FocusMIDIEditor then
            reaper.SN_FocusMIDIEditor()
        end
    end
end]]

  if not old_left then
      fail("spectrograph.lua: handleLeftMouse not found.")
  elseif old_left == new_left_block then
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua handleLeftMouse already patched.\n")
  else
      local patched4, n4 = plain_replace(txt, old_left, new_left_block)
      if n4 == 0 then
        fail("spectrograph.lua: could not patch handleLeftMouse().")
      end
      txt = patched4
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua handleLeftMouse patched (click moves cursor/pitch).\n")
  end

  --------------------------------------------------------------------
  -- Replace handleRightMouse: continuous pan to edit cursor while held
  --------------------------------------------------------------------
  local right_sig = "function SpectrographWidget:handleRightMouse(ctx)"
  local old_right = get_function_block(txt, right_sig)

  local new_right_block = [[function SpectrographWidget:handleRightMouse(ctx)
    -- FCP: Don't consume mouse events when a popup (FFT/RMS dropdown) is open
    local popup_open = ImGui.IsPopupOpen(ctx, "", ImGui.PopupFlags_AnyPopupId + ImGui.PopupFlags_AnyPopupLevel)
    if popup_open then return end

    local mx, my = ImGui.GetMousePos(ctx)
    local dx, dy = ImGui.GetMouseDragDelta(ctx, ImGui.MouseButton_Right)

    local inside  = self:containsPoint(mx, my)
    local preempt = self.mw and self.mw.prehemptsMouse and self.mw:prehemptsMouse()
    local over_lr = self.lr_mix_widget and self.lr_mix_widget:containsPoint(mx, my)

    -- Right click (held or released): delete hovered profile, or pan to edit cursor
    if inside and not preempt and not over_lr then
        -- Check for hovered profile to delete on quick click
        if ImGui.IsMouseReleased(ctx, ImGui.MouseButton_Right) and dx == 0 and dy == 0 then
            local torem = self:hoveredProfile(ctx)
            if torem then
                table.remove(self.extracted_profiles, torem)
                return
            end
        end

        -- While right mouse is down: continuously pan horizontally to position cursor 1/3 from left
        if ImGui.IsMouseDown(ctx, ImGui.MouseButton_Right) then
            local sac = self:spectrumContext()
            if sac and sac.signal and sac.signal.stop > sac.signal.start then
                local fullDur = sac.signal.duration or (sac.signal.stop - sac.signal.start)
                
                -- Use play cursor if playing, otherwise edit cursor
                local play_state = reaper.GetPlayState()
                local t_cursor
                if play_state & 1 == 1 then  -- playing
                    t_cursor = reaper.GetPlayPosition()
                else
                    t_cursor = reaper.GetCursorPosition()
                end

                -- Clamp cursor to signal range
                if t_cursor < sac.signal.start then t_cursor = sac.signal.start end
                if t_cursor > sac.signal.stop then t_cursor = sac.signal.stop end

                local u_cursor = (t_cursor - sac.signal.start) / fullDur
                local u_span = self.vp_u_r - self.vp_u_l

                -- Position cursor 1/3 from left edge of viewport
                local target_ul = u_cursor - (1/3) * u_span
                if target_ul < 0 then target_ul = 0 end
                if target_ul + u_span > 1 then target_ul = 1 - u_span end

                -- Lerp factor for smooth panning
                local lerp = 1
                local new_ul = self.vp_u_l + lerp * (target_ul - self.vp_u_l)

                -- Clamp
                if new_ul < 0 then new_ul = 0 end
                if new_ul + u_span > 1 then new_ul = 1 - u_span end

                self.vp_u_l = new_ul
                self.vp_u_r = new_ul + u_span
            end

            -- FCP: Focus MIDI editor while right mouse is held
            --if reaper.SN_FocusMIDIEditor then
            --    reaper.SN_FocusMIDIEditor()
            --end
        end

        -- FCP: Focus MIDI editor when right mouse is released
        if ImGui.IsMouseReleased(ctx, ImGui.MouseButton_Right) then
            if reaper.SN_FocusMIDIEditor then
                reaper.SN_FocusMIDIEditor()
            end
        end
    end
end]]

  if not old_right then
      fail("spectrograph.lua: handleRightMouse not found.")
  elseif old_right == new_right_block then
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua handleRightMouse already patched.\n")
  else
      local patched_right, n_right = plain_replace(txt, old_right, new_right_block)
      if n_right == 0 then
        fail("spectrograph.lua: could not patch handleRightMouse().")
      end
      txt = patched_right
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua handleRightMouse patched (pan to edit cursor).\n")
  end

  --------------------------------------------------------------------
  -- Comment out drawer background behind side frequency curve
  -- (ImGui.DrawList_AddRectFilled(..., T.DRAWER_BG))
  --------------------------------------------------------------------
  do
      local rect_old = "        ImGui.DrawList_AddRectFilled(draw_list, self.x + self.w - self.drawer_width, self.y, self.x + self.w, self.y + self.h, T.DRAWER_BG)"
      local rect_new = table.concat({
        "        -- FCP: disable drawer background",
        "        -- ImGui.DrawList_AddRectFilled(draw_list, self.x + self.w - self.drawer_width, self.y, self.x + self.w, self.y + self.h, T.DRAWER_BG)"
      }, "\n")

      if txt:find(rect_new, 1, true) then
          reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua drawer background already disabled.\n")
      elseif txt:find(rect_old, 1, true) then
          local new_txt, n = plain_replace(txt, rect_old, rect_new)
          if n == 0 then
            reaper.ShowConsoleMsg("Spectracular defaults patch: warning, could not find drawer background line to comment out.\n")
          else
            txt = new_txt
            reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua drawer background disabled.\n")
          end
      else
          reaper.ShowConsoleMsg("Spectracular defaults patch: warning, drawer background line not found.\n")
      end
  end

  --------------------------------------------------------------------
  -- Patch drawTooltip: fixed position in bottom-left or top-left
  --------------------------------------------------------------------
  local tooltip_sig = "function SpectrographWidget:drawTooltip(ctx)"
  local old_tooltip = get_function_block(txt, tooltip_sig)

  local new_tooltip_block = [[function SpectrographWidget:drawTooltip(ctx)
    local sac = self:spectrumContext()
    if not sac then return end

    local mx, my = ImGui.GetMousePos(ctx)

    -- FCP: Also hide tooltip when any popup (FFT/RMS combo) is open
    local popup_open = ImGui.IsPopupOpen(ctx, "", ImGui.PopupFlags_AnyPopupId + ImGui.PopupFlags_AnyPopupLevel)
    if not self:containsPoint(mx,my) or self.lr_mix_widget:containsPoint(mx, my) or popup_open then
        return
    end

    local draw_list = ImGui.GetWindowDrawList(ctx)
    local note_name = self:noteNameForY(my)

    local note_text = "" .. note_name
    local db_texts  = {}
    local db_width  = 0

    for i=1, sac.chan_count do
        db_texts[i] = (self.hovered_db[i] and string.format("%.1f dB", self.hovered_db[i]) or "?"):gsub("%.0+$", "")
        local dbw = ImGui.CalcTextSize(ctx, db_texts[i])
        if dbw > db_width then db_width = dbw end
    end

    local tw, th            = ImGui.CalcTextSize(ctx, note_text)

    local sqw               = 8
    local chan_num_w        = 6
    local px, py            = 10, 5
    local mgx, mgy          = 10, 10

    local w                 = px + sqw + px + tw + px + db_width + px
    local h                 = 2 * py + sac.chan_count * th + (sac.chan_count - 1) * py

    if sac.chan_count > 1 then
        w = w + px + 10
    end

    -- FCP: Fixed position in bottom-left corner, move to top-left if mouse is too close
    local box_x = self.x + mgx + 30  -- shifted right by 30 pixels
    local box_y = self.y + self.h - h - mgy  -- bottom-left (box_y is top of the box)

    -- Check if mouse is too close to bottom-left corner
    local mouse_near_bottom_left = (mx - self.x < w + 2 * mgx + 30) and (self.y + self.h - my < h + 2 * mgy)
    
    if mouse_near_bottom_left then
        -- Move to top-left corner
        box_y = self.y + mgy
    end

    -- Tooltip's frame
    ImGui.DrawList_AddRectFilled(draw_list, box_x, box_y, box_x + w, box_y + h, T.TOOLTIP_BG )
    ImGui.DrawList_AddRect(draw_list,       box_x, box_y, box_x + w, box_y + h, T.H_CURSOR, 1.0 )

    local cx = box_x + px
    local cy = box_y + math.floor(0.5 + h/2 - sqw/2)

    -- Draw color rect
    ImGui.DrawList_AddRectFilled(draw_list, cx, cy, cx + sqw, cy + sqw, T.SPECTRO_PROFILES[ ((self:firstAvailableProfileColorIdx()-1) % #T.SPECTRO_PROFILES) + 1] )
    cx = cx + sqw + px

    ImGui.DrawList_AddText(draw_list, cx, box_y + math.floor(0.5 + h/2 - th/2), T.H_CURSOR , note_text)
    cx = cx + tw + px

    for i=1, sac.chan_count do
        local cox = 0
        if sac.chan_count > 1 then
            if sac.chan_count == 2 then
                ImGui.DrawList_AddText(draw_list, cx, box_y + py + (i-1) * (th + py), (i==1) and T.SLICE_CURVE_L or T.SLICE_CURVE_R , (i==1) and "L" or "R")
            end

            cox = chan_num_w + px
        end
        ImGui.DrawList_AddText(draw_list, cx + cox, box_y + py + (i-1) * (th + py), T.H_CURSOR , db_texts[i])
    end
end]]

  if not old_tooltip then
      fail("spectrograph.lua: drawTooltip not found.")
  elseif old_tooltip == new_tooltip_block then
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua drawTooltip already patched.\n")
  else
      local patched_tooltip, n_tooltip = plain_replace(txt, old_tooltip, new_tooltip_block)
      if n_tooltip == 0 then
        fail("spectrograph.lua: could not patch drawTooltip().")
      end
      txt = patched_tooltip
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua drawTooltip patched (fixed corner position).\n")
  end

  --------------------------------------------------------------------
  -- Patch drawHorizontalCursor to hide when popups are open + resize cursor
  --------------------------------------------------------------------
  local hcursor_sig = "function SpectrographWidget:drawHorizontalCursor(ctx, draw_list)"
  local old_hcursor = get_function_block(txt, hcursor_sig)

  local new_hcursor_block = [[function SpectrographWidget:drawHorizontalCursor(ctx, draw_list)
    local mx, my = ImGui.GetMousePos(ctx)
    -- FCP: Also hide crosshairs when any popup (FFT/RMS combo) is open
    local popup_open = ImGui.IsPopupOpen(ctx, "", ImGui.PopupFlags_AnyPopupId + ImGui.PopupFlags_AnyPopupLevel)
    if self:containsPoint(mx,my) and not self.lr_mix_widget:containsPoint(mx, my) and not popup_open then
        -- FCP: Check if hovering over a note edge - draw resize cursor instead
        local on_note_edge = false
        local me = reaper.MIDIEditor_GetActive()
        if me then
            local take = reaper.MIDIEditor_GetTake(me)
            if take then
                local sac = self:spectrumContext()
                if sac and sac.signal then
                    local note_float = self:yToNoteNum(my)
                    local hoveredPitch = math.floor(note_float + 0.5)
                    local edge_threshold = 5
                    
                    local idx = 0
                    while true do
                        local retval, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, idx)
                        if not retval then break end
                        
                        if pitch == hoveredPitch then
                            local note_start = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                            local note_end = reaper.MIDI_GetProjTimeFromPPQPos(take, endppq)
                            
                            local x_start = self:timeToX(note_start)
                            local x_end = self:timeToX(note_end)
                            local y_top = self:noteNumToY(pitch + 0.5)
                            local y_bottom = self:noteNumToY(pitch - 0.5)
                            
                            if my >= y_top and my <= y_bottom then
                                if math.abs(mx - x_start) <= edge_threshold or math.abs(mx - x_end) <= edge_threshold then
                                    on_note_edge = true
                                    break
                                end
                            end
                        end
                        idx = idx + 1
                    end
                end
            end
        end
        
        if on_note_edge then
            -- FCP: Draw resize cursor (short horizontal line with arrowheads)
            local RESIZE_COLOR = 0xFFFF00FF  -- Yellow, fully opaque
            local half_len = 12
            local arrow_len = 4
            
            -- Short horizontal line
            ImGui.DrawList_AddLine(draw_list, mx - half_len, my, mx + half_len, my, RESIZE_COLOR, 1)
            
            -- Left arrowhead (pointing left)
            ImGui.DrawList_AddLine(draw_list, mx - half_len, my, mx - half_len + arrow_len, my + arrow_len, RESIZE_COLOR, 1)
            ImGui.DrawList_AddLine(draw_list, mx - half_len, my, mx - half_len + arrow_len, my - arrow_len, RESIZE_COLOR, 1)
            
            -- Right arrowhead (pointing right)
            ImGui.DrawList_AddLine(draw_list, mx + half_len, my, mx + half_len - arrow_len, my + arrow_len, RESIZE_COLOR, 1)
            ImGui.DrawList_AddLine(draw_list, mx + half_len, my, mx + half_len - arrow_len, my - arrow_len, RESIZE_COLOR, 1)
        else
            -- Normal horizontal line cursor
            ImGui.DrawList_AddLine(draw_list, self.x, my, self.x + self.w, my, T.H_CURSOR)
        end
    end
end]]

  if not old_hcursor then
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua drawHorizontalCursor not found.\n")
  elseif old_hcursor == new_hcursor_block then
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua drawHorizontalCursor already patched.\n")
  else
      local patched_hcursor, n_hcursor = plain_replace(txt, old_hcursor, new_hcursor_block)
      if n_hcursor == 0 then
        reaper.ShowConsoleMsg("Spectracular defaults patch: warning, could not patch drawHorizontalCursor.\n")
      else
        txt = patched_hcursor
        reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua drawHorizontalCursor patched (hide on popup + resize cursor).\n")
      end
  end

  --------------------------------------------------------------------
  -- Inject drawMidiNotes function to draw MIDI note rectangles
  --------------------------------------------------------------------
  local draw_midi_notes_func = [[
function SpectrographWidget:drawMidiNotes(ctx, draw_list)
    -- FCP: Draw rectangles representing MIDI notes from active MIDI editor
    local me = reaper.MIDIEditor_GetActive()
    if not me then return end
    
    local take = reaper.MIDIEditor_GetTake(me)
    if not take then return end
    
    local sac = self:spectrumContext()
    if not sac or not sac.signal then return end
    
    -- Get time bounds for culling
    local view_start = sac.signal.start + self.vp_u_l * (sac.signal.stop - sac.signal.start)
    local view_end = sac.signal.start + self.vp_u_r * (sac.signal.stop - sac.signal.start)
    
    -- Get the media item to convert PPQ to project time
    local item = reaper.GetMediaItemTake_Item(take)
    if not item then return end
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    
    -- Colors for MIDI note rectangles
    local NOTE_FILL = 0x44AAFF40   -- semi-transparent blue fill
    local NOTE_BORDER = 0x44AAFFCC -- more opaque blue border
    local NOTE_SELECTED_FILL = 0xFF666680   -- semi-transparent red fill for selected
    local NOTE_SELECTED_BORDER = 0xFF6666DD -- more opaque red border for selected
    local LYRIC_COLOR = NOTE_BORDER -- same light blue as note outline
    
    -- FCP: Build a map of PPQ positions to lyric text (type 5 = lyric event)
    -- NOTE: Do NOT call MIDI_Sort here - it interferes with note dragging in MIDI editor
    local _, _, _, txtCnt = reaper.MIDI_CountEvts(take)
    local lyrics_by_ppq = {}
    for ti = 0, txtCnt - 1 do
        local retval, selected, muted, ppqpos, evt_type, msg = reaper.MIDI_GetTextSysexEvt(take, ti)
        if retval and evt_type == 5 and msg and msg ~= "" then
            -- Store lyric at this PPQ position
            if lyrics_by_ppq[ppqpos] then
                lyrics_by_ppq[ppqpos] = lyrics_by_ppq[ppqpos] .. " " .. msg
            else
                lyrics_by_ppq[ppqpos] = msg
            end
        end
    end
    
    -- Enumerate all notes
    local idx = 0
    while true do
        local retval, selected, muted, startppqpos, endppqpos, chan, pitch, vel = reaper.MIDI_GetNote(take, idx)
        if not retval then break end
        
        -- Convert PPQ to project time
        local note_start_src = reaper.MIDI_GetProjTimeFromPPQPos(take, startppqpos)
        local note_end_src = reaper.MIDI_GetProjTimeFromPPQPos(take, endppqpos)
        
        -- Cull notes outside the view
        if note_end_src >= view_start and note_start_src <= view_end then
            -- Convert to screen coordinates
            local x1 = self:timeToX(note_start_src)
            local x2 = self:timeToX(note_end_src)
            
            -- Get Y coordinates for the note (note spans from pitch to pitch+1)
            local y_top = self:noteNumToY(pitch + 0.5)
            local y_bottom = self:noteNumToY(pitch - 0.5)
            
            -- Clamp to widget bounds
            local x1_clamped = math.max(self.x, math.min(self.x + self.w, x1))
            local x2_clamped = math.max(self.x, math.min(self.x + self.w, x2))
            y_top = math.max(self.y, math.min(self.y + self.h, y_top))
            y_bottom = math.max(self.y, math.min(self.y + self.h, y_bottom))
            
            -- Only draw if there's something visible
            if x2_clamped > x1_clamped and y_bottom > y_top then
                local fill_color = selected and NOTE_SELECTED_FILL or NOTE_FILL
                local border_color = selected and NOTE_SELECTED_BORDER or NOTE_BORDER
                
                -- Draw filled rectangle
                ImGui.DrawList_AddRectFilled(draw_list, x1_clamped, y_top, x2_clamped, y_bottom, fill_color)
                -- Draw border
                ImGui.DrawList_AddRect(draw_list, x1_clamped, y_top, x2_clamped, y_bottom, border_color, 0, 0, 1)
                
                -- FCP: Draw lyric if present at this note's start position
                -- Look for lyric within a small tolerance of the note start (e.g., 1 PPQ)
                local lyric = lyrics_by_ppq[startppqpos]
                if not lyric then
                    -- Try to find a lyric within a small window (for quantization tolerance)
                    for ppq, txt in pairs(lyrics_by_ppq) do
                        if math.abs(ppq - startppqpos) < 10 then
                            lyric = txt
                            break
                        end
                    end
                end
                
                if lyric then
                    -- Draw lyric text at the left edge of the note, vertically centered
                    local text_x = x1_clamped + 3  -- small padding from left edge
                    local text_y = y_top + (y_bottom - y_top) / 2 - 6  -- roughly center vertically (assuming ~12px font)
                    ImGui.DrawList_AddText(draw_list, text_x, text_y, LYRIC_COLOR, lyric)
                end
            end
        end
        
        idx = idx + 1
    end
end
]]

  -- Check if drawMidiNotes already exists - if so, replace it; otherwise insert it
  local existing_midi_notes_sig = "function SpectrographWidget:drawMidiNotes(ctx, draw_list)"
  local existing_midi_notes = get_function_block(txt, existing_midi_notes_sig)
  
  if existing_midi_notes then
      -- Replace the existing function with the new version
      local patched_midi, n_midi = plain_replace(txt, existing_midi_notes, draw_midi_notes_func)
      if n_midi > 0 then
          txt = patched_midi
          reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua drawMidiNotes replaced with latest version.\n")
      else
          reaper.ShowConsoleMsg("Spectracular defaults patch: warning, could not replace drawMidiNotes.\n")
      end
  else
      -- Insert after drawHorizontalCursor function
      local insert_marker = "function SpectrographWidget:drawHorizontalCursor(ctx, draw_list)"
      local insert_block = get_function_block(txt, insert_marker)
      if insert_block then
          txt = plain_replace(txt, insert_block, insert_block .. "\n\n" .. draw_midi_notes_func)
          reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua drawMidiNotes function added.\n")
      else
          reaper.ShowConsoleMsg("Spectracular defaults patch: warning, could not find insertion point for drawMidiNotes.\n")
      end
  end

  --------------------------------------------------------------------
  -- Patch draw() to call drawMidiNotes
  --------------------------------------------------------------------
  local draw_call_old = [[    -- Show grid lines for notes
    self:drawHorizontalNoteTicks(ctx, draw_list)

    -- Show note cursor line (mouse hover)
    self:drawHorizontalCursor(ctx, draw_list)]]

  local draw_call_new = [[    -- Show grid lines for notes
    self:drawHorizontalNoteTicks(ctx, draw_list)

    -- FCP: Draw MIDI note rectangles from active MIDI editor
    self:drawMidiNotes(ctx, draw_list)

    -- Show note cursor line (mouse hover)
    self:drawHorizontalCursor(ctx, draw_list)]]

  if txt:find(draw_call_new, 1, true) then
      reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua draw() already calls drawMidiNotes.\n")
  elseif txt:find(draw_call_old, 1, true) then
      local patched_draw, n_draw = plain_replace(txt, draw_call_old, draw_call_new)
      if n_draw > 0 then
          txt = patched_draw
          reaper.ShowConsoleMsg("Spectracular defaults patch: spectrograph.lua draw() patched to call drawMidiNotes.\n")
      else
          reaper.ShowConsoleMsg("Spectracular defaults patch: warning, could not patch draw() to call drawMidiNotes.\n")
      end
  else
      reaper.ShowConsoleMsg("Spectracular defaults patch: warning, draw() call site for drawMidiNotes not found.\n")
  end

  write_file(path, txt)
end

----------------------------------------------------------------------
-- Patch widgets/main.lua: curves (RMSE) defaults + drag-splitter
-- + smaller minimum curves height
----------------------------------------------------------------------

local function patch_main(path)
  local content = read_file(path)
  local new_content = content
  local changed = false

  -- 1) Shorter default curves (RMSE) height: 160 -> 50
  local rmse_old = "    self.rmse_height = 160"
  local rmse_new = "    self.rmse_height = 50"
  
  if new_content:find(rmse_new, 1, true) then
      -- already patched
  elseif new_content:find(rmse_old, 1, true) then
      local n1
      new_content, n1 = plain_replace(new_content, rmse_old, rmse_new)
      if n1 == 0 then fail("widgets/main.lua: could not patch default rmse_height.") end
      changed = true
  else
      fail("widgets/main.lua: default rmse_height line not found.")
  end

  -- 2) Allow resizing curves area by dragging on the ruler without a modifier key
  local ruler_old = [[        if self.ruler_widget:containsPoint(mx,my) then
            if UTILS.modifierKeyIsDown() then]]
  local ruler_new = [[        if self.ruler_widget:containsPoint(mx,my) then
            if true then -- allow resizing curves area without modifier key]]

  if new_content:find(ruler_new, 1, true) then
      -- already patched
  elseif new_content:find(ruler_old, 1, true) then
      local n2
      new_content, n2 = plain_replace(new_content, ruler_old, ruler_new)
      if n2 == 0 then fail("widgets/main.lua: could not patch ruler resize block.") end
      changed = true
  else
      fail("widgets/main.lua: ruler resize block not found.")
  end

  -- 3) Smaller minimum curves area (half original 100 -> 50)
  local min_old = "                if new_rmse_widget_size < 100               then new_rmse_widget_size = 100 end"
  local min_new = "                if new_rmse_widget_size < 50                then new_rmse_widget_size = 50 end"

  if new_content:find(min_new, 1, true) then
      -- already patched
  elseif new_content:find(min_old, 1, true) then
      local n3
      new_content, n3 = plain_replace(new_content, min_old, min_new)
      if n3 == 0 then fail("widgets/main.lua: could not patch RMSE min height.") end
      changed = true
  else
      fail("widgets/main.lua: RMSE min height line not found.")
  end

  -- 4) Keep a minimum spectrogram height (slightly more restrictive max)
  local max_old = "                if new_rmse_widget_size > (self.h - 100)    then new_rmse_widget_size = (self.h - 100) end"
  local max_new = "                if new_rmse_widget_size > (self.h - 120)    then new_rmse_widget_size = (self.h - 120) end"

  if new_content:find(max_new, 1, true) then
      -- already patched
  elseif new_content:find(max_old, 1, true) then
      local n4
      new_content, n4 = plain_replace(new_content, max_old, max_new)
      if n4 == 0 then fail("widgets/main.lua: could not patch RMSE max height.") end
      changed = true
  else
      fail("widgets/main.lua: RMSE max height line not found.")
  end

  if changed then
    write_file(path, new_content)
    reaper.ShowConsoleMsg("Spectracular defaults patch: widgets/main.lua patched (curves defaults + splitter + min height).\n")
  else
    reaper.ShowConsoleMsg("Spectracular defaults patch: widgets/main.lua already patched.\n")
  end
end

----------------------------------------------------------------------
-- Patch app.lua: allow smaller minimum Spectracular window size
-- (change constraints to 300x220, robust + idempotent)
----------------------------------------------------------------------

local function patch_app(path)
  local txt = read_file(path)

  -- 1. Patch window size constraints (simple regex replacement)
  local constraints_pattern = "ImGui%.SetNextWindowSizeConstraints%s*%(%s*ctx%s*,%s*%d+%s*,%s*%d+%s*,%s*math%.huge%s*,%s*math%.huge%s*%)"
  local desired_constraints = "ImGui.SetNextWindowSizeConstraints(ctx, 300, 220, math.huge, math.huge)"
  
  local current_match = txt:match(constraints_pattern)
  
  if not current_match then
      reaper.ShowConsoleMsg("Spectracular defaults patch: app.lua window size constraints line not found.\n")
  elseif current_match == desired_constraints then
      reaper.ShowConsoleMsg("Spectracular defaults patch: app.lua already patched (window min size 300x220).\n")
  else
      local patched, n = plain_replace(txt, current_match, desired_constraints)
      if n > 0 then
          txt = patched
          reaper.ShowConsoleMsg("Spectracular defaults patch: app.lua patched (window min size -> 300x220).\n")
      else
          fail("app.lua: failed to replace window size constraints.")
      end
  end

  -- 2. Replace refreshOptionsWidgets
  local refresh_sig = "local function refreshOptionsWidgets(ctx)"
  local old_refresh = get_function_block(txt, refresh_sig)

  local new_refresh = [[local function refreshOptionsWidgets(ctx)
    local v, b = ImGui.Checkbox(ctx, "Time select", S.instance_params.keep_time_selection)
    if v then
        S.instance_params.keep_time_selection = b
        S.setSetting("KeepTimeSelection", b)
    end
    TT(ctx, "When refreshing, keep the original time selection even if it's changed in REAPER")

    SL(ctx)

    local v, b = ImGui.Checkbox(ctx, "Track select", S.instance_params.keep_track_selection)
    if v then
        S.instance_params.keep_track_selection = b
        S.setSetting("KeepTrackSelection", b)
    end
    TT(ctx, "When refreshing, keep the original track selection even if it's changed in REAPER")

    SL(ctx)

    local v, b = ImGui.Checkbox(ctx, "Auto refresh", S.instance_params.auto_refresh)
    if v then
        S.instance_params.auto_refresh = b
        S.setSetting("AutoRefresh", b)
    end
    TT(ctx, "If this option is on, this Spectracular window will watch for changes\n\z
             happening in the currently edited MIDI take and auto-refresh.")

    SL(ctx)

    if ImGui.Button(ctx, "Refresh") then
        want_refresh = true
    end

    SL(ctx)

    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, "(?)")

    if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Left) then
        local cx, cy        = ImGui.GetWindowPos(ctx)
        HelpWindow.open(cx,cy)
    end

    if ImGui.IsItemHovered(ctx) and UTILS.isMouseStalled(0.5) then
        ImGui.SetTooltip(ctx, "Click to open help")
    end
end]]

  if not old_refresh then
      reaper.ShowConsoleMsg("Spectracular defaults patch: app.lua refreshOptionsWidgets not found.\n")
  elseif old_refresh == new_refresh then
      reaper.ShowConsoleMsg("Spectracular defaults patch: app.lua refreshOptionsWidgets already patched.\n")
  else
      local patched_refresh, n_refresh = plain_replace(txt, old_refresh, new_refresh)
      if n_refresh > 0 then
          txt = patched_refresh
          reaper.ShowConsoleMsg("Spectracular defaults patch: app.lua refreshOptionsWidgets replaced.\n")
      else
          reaper.ShowConsoleMsg("Spectracular defaults patch: warning, could not replace refreshOptionsWidgets (replace failed).\n")
      end
  end

  -- 3. Replace drawBottomSettings
  local bottom_sig = "local function drawBottomSettings(ctx)"
  local old_bottom = get_function_block(txt, bottom_sig)

  local new_bottom = [[local function drawBottomSettings(ctx)

    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 2, 2)
    ImGui.BeginGroup(ctx)

    -- FCP: Compact layout (removed Analysis params label)
    -- ImGui.AlignTextToFramePadding(ctx)
    -- ImGui.TextColored(ctx, 0xCC88FFFF, "Analysis params")
    -- SL(ctx)
    timeResolutionWidget(ctx)
    SL(ctx)
    FFTWidget(ctx)
    SL(ctx)
    zeroPaddingWidget(ctx)
    SL(ctx)
    RMSWidget(ctx)

    ImGui.AlignTextToFramePadding(ctx)
    ImGui.TextColored(ctx, 0xCC88FFFF, "Keep:")
    SL(ctx)
    refreshOptionsWidgets(ctx)
    ImGui.EndGroup(ctx)
    -- FCP: Buttons moved to refreshOptionsWidgets
    ImGui.PopStyleVar(ctx)
end]]

  if not old_bottom then
      reaper.ShowConsoleMsg("Spectracular defaults patch: app.lua drawBottomSettings not found.\n")
  elseif old_bottom == new_bottom then
      reaper.ShowConsoleMsg("Spectracular defaults patch: app.lua drawBottomSettings already patched.\n")
  else
      local patched_bottom, n_bottom = plain_replace(txt, old_bottom, new_bottom)
      if n_bottom > 0 then
          txt = patched_bottom
          reaper.ShowConsoleMsg("Spectracular defaults patch: app.lua drawBottomSettings replaced.\n")
      else
          reaper.ShowConsoleMsg("Spectracular defaults patch: warning, could not replace drawBottomSettings (replace failed).\n")
      end
  end

  -- 4. Patch loop to save viewport on close
  local loop_close_old = [[    if open then
        reaper.defer(loop)
    end
    ImGui.PopFont(ctx)
end]]

  local loop_close_new = [[    if open then
        reaper.defer(loop)
    else
        -- FCP: Save viewport state on close
        if main_widget and main_widget.spectrograph_widget then
            main_widget.spectrograph_widget:saveViewportState()
        end
    end
    ImGui.PopFont(ctx)
end]]

  if txt:find(loop_close_new, 1, true) then
      reaper.ShowConsoleMsg("Spectracular defaults patch: app.lua loop close already patched.\n")
  elseif txt:find(loop_close_old, 1, true) then
      local patched_loop, n_loop = plain_replace(txt, loop_close_old, loop_close_new)
      if n_loop > 0 then
          txt = patched_loop
          reaper.ShowConsoleMsg("Spectracular defaults patch: app.lua loop close patched (save viewport on exit).\n")
      else
          reaper.ShowConsoleMsg("Spectracular defaults patch: warning, could not patch loop close.\n")
      end
  else
      reaper.ShowConsoleMsg("Spectracular defaults patch: warning, loop close block not found.\n")
  end

  write_file(path, txt)
end

----------------------------------------------------------------------
-- Run patches
----------------------------------------------------------------------

reaper.ClearConsole()
patch_settings(settings_path)
patch_spectrograph(spectro_path)
patch_main(main_path)
patch_app(app_path)
reaper.ShowConsoleMsg("Spectracular defaults patch: completed successfully.\n")
