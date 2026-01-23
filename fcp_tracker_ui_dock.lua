-- fcp_tracker_ui_dock.lua
-- Docked window height control and screenset commands

local reaper = reaper

-- Window screenset command IDs (Main section)
CMD_SCREENSET_LOAD_OTHERS   = 40454  -- Screenset: Load window set #01
CMD_SCREENSET_LOAD_VOCALS   = 40455  -- Screenset: Load window set #02
CMD_SCREENSET_LOAD_OV       = 40456  -- Screenset: Load window set #03
CMD_SCREENSET_LOAD_VENUE    = 40457  -- Screenset: Load window set #04
CMD_SCREENSET_LOAD_PRO_KEYS = 40458  -- Screenset: Load window set #05
CMD_SCREENSET_SAVE_OTHERS   = 40474  -- Screenset: Save window set #01
CMD_SCREENSET_SAVE_VOCALS   = 40475  -- Screenset: Save window set #02
CMD_SCREENSET_SAVE_OV       = 40476  -- Screenset: Save window set #03
CMD_SCREENSET_SAVE_VENUE    = 40477  -- Screenset: Save window set #04
CMD_SCREENSET_SAVE_PRO_KEYS = 40478  -- Screenset: Save window set #05

function GetDockedHeight()
  local hwnd = reaper.JS_Window_Find(APP_NAME, true)
  if hwnd then
    local container = reaper.JS_Window_GetParent(hwnd)
    if container then
      local retval, left, top, right, bottom = reaper.JS_Window_GetRect(container)
      if retval then return bottom - top end
    end
  end
  return nil
end

function SetDockedHeight(h)
  if not h then return end
  if h < 100 then h = 100 end
  
  local hwnd = reaper.JS_Window_Find(APP_NAME, true)
  if not hwnd then return end
  
  local container = reaper.JS_Window_GetParent(hwnd)
  if not container then return end
  
  local retval, left, top, right, bottom = reaper.JS_Window_GetRect(container)
  if not retval then return end
  
  local w = right - left
  
  -- Resize the container
  reaper.JS_Window_Resize(container, w, h)
  
  -- Force REAPER to recalculate dock layout using DockID refresh
  local dock_id = reaper.DockIsChildOfDock(hwnd)
  if dock_id and dock_id >= 0 then
    reaper.DockWindowRefresh()
  end
  
  -- Post WM_SIZE message to trigger layout
  if reaper.JS_WindowMessage_Post then
    local WM_SIZE = 0x0005
    reaper.JS_WindowMessage_Post(container, WM_SIZE, 0, 0, w, h)
  end
  
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
end