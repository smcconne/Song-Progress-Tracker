-- fcp_tracker_auto_updater.lua
-- Auto-updater for Song Progress Tracker
-- REAPER-compatible implementation inspired by hexarobi/stand-lua-auto-updater

local AutoUpdater = {}

-- Configuration
AutoUpdater.config = {
  -- GitHub repository info
  github_user = "smcconne",
  github_repo = "Song-Progress-Tracker",
  branch = "main",
  
  -- Update check interval (seconds) - default 24 hours
  check_interval = 86400,
  
  -- Script info
  script_name = "Song Progress Tracker",
  version_key = "FCP_UPDATER_LAST_CHECK",
  version_id_key = "FCP_UPDATER_VERSION_ID",
  
  -- Files to update (relative to the script folder)
  files = {
    "fcp_tracker_main.lua",
    "fcp_tracker_config.lua",
    "fcp_tracker_chunk_parse.lua",
    "fcp_tracker_focus.lua",
    "fcp_tracker_fxchain_geom.lua",
    "fcp_tracker_layout.lua",
    "fcp_tracker_templates.lua",
    "fcp_tracker_util_fs.lua",
    "fcp_tracker_util_selection.lua",
    "fcp_tracker_model.lua",
    "fcp_tracker_ui.lua",
    "fcp_tracker_ui_dock.lua",
    "fcp_tracker_ui_header.lua",
    "fcp_tracker_ui_helpers.lua",
    "fcp_tracker_ui_setup.lua",
    "fcp_tracker_ui_table.lua",
    "fcp_tracker_ui_tabs.lua",
    "fcp_tracker_ui_track_utils.lua",
    "fcp_tracker_ui_widgets.lua",
    "fcp_tracker_auto_updater.lua",
    "fcp_jump_regions.lua",
  },
  
  -- GitHub raw content base URL
  raw_base_url = "https://raw.githubusercontent.com",
  
  -- Local path (will be set at runtime)
  local_path = nil,
  
  -- Debug mode
  debug = false,
  
  -- Silent updates (no toast on success)
  silent_updates = false,
}

-- Version will be set by fcp_tracker_main.lua via AutoUpdater.SCRIPT_VERSION
AutoUpdater.SCRIPT_VERSION = nil

-------------------------------------------------------------------------------
-- Utility Functions
-------------------------------------------------------------------------------

local function log(msg)
  if AutoUpdater.config.debug then
    reaper.ShowConsoleMsg("[RBN Auto-Updater] " .. tostring(msg) .. "\n")
  end
end

local function get_script_path()
  local info = debug.getinfo(1, "S")
  local path = info.source:match("@(.+[\\/])")
  return path or ""
end

-- Simple HTTP GET using reaper.ExecProcess with curl (Windows/Mac/Linux compatible)
local function http_get(url, timeout_ms)
  timeout_ms = timeout_ms or 10000
  
  -- Use curl which is available on most systems
  local curl_cmd
  if reaper.GetOS():match("Win") then
    -- Windows: use curl (available in Windows 10+)
    curl_cmd = string.format('curl -s -L --max-time %d "%s"', math.floor(timeout_ms/1000), url)
  else
    -- macOS/Linux
    curl_cmd = string.format('curl -s -L --max-time %d "%s"', math.floor(timeout_ms/1000), url)
  end
  
  log("HTTP GET: " .. url)
  local result = reaper.ExecProcess(curl_cmd, timeout_ms)
  
  if result and result ~= "" then
    log("Raw result length: " .. #result)
    
    -- ExecProcess returns exit code + output separated by newline
    -- Try to parse exit code first
    local exit_code, content = result:match("^(%d+)\n(.*)$")
    if exit_code and content and #content > 0 then
      -- We have exit code + content format
      -- Check if content looks like valid Lua (starts with --)
      if content:match("^%-%-") then
        log("HTTP GET success (valid Lua content), length: " .. #content)
        return content, true
      elseif exit_code == "0" then
        log("HTTP GET success (exit 0), content length: " .. #content)
        return content, true
      else
        log("HTTP GET exit code " .. exit_code .. " with non-Lua content")
      end
    end
    
    -- No exit code pattern found - the result IS the content
    -- This happens when ExecProcess doesn't prepend exit code
    if result:match("^%-%-") then
      -- Looks like Lua code, treat as success
      log("HTTP GET success (raw content), length: " .. #result)
      return result, true
    end
    
    -- Last resort: return as-is if it looks like valid content (long enough)
    if #result > 100 then
      log("HTTP GET success (fallback), length: " .. #result)
      return result, true
    end
  end
  
  log("HTTP GET failed for: " .. url)
  return nil, false
end

-- Get the ETag or last-modified header for a URL
local function http_head(url)
  local curl_cmd
  if reaper.GetOS():match("Win") then
    curl_cmd = string.format('curl -s -I -L --max-time 10 "%s"', url)
  else
    curl_cmd = string.format('curl -s -I -L --max-time 10 "%s"', url)
  end
  
  local result = reaper.ExecProcess(curl_cmd, 10000)
  if result then
    local etag = result:match('[Ee][Tt][Aa][Gg]:%s*"?([^"\r\n]+)"?')
    local last_modified = result:match('[Ll]ast%-[Mm]odified:%s*([^\r\n]+)')
    return etag, last_modified
  end
  return nil, nil
end

-- Read file contents
local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*all")
  f:close()
  return content
end

-- Write file contents
local function write_file(path, content)
  -- Create directory if needed
  local dir = path:match("(.+[\\/])")
  if dir then
    reaper.RecursiveCreateDirectory(dir, 0)
  end
  
  local f = io.open(path, "wb")
  if not f then
    log("Failed to write file: " .. path)
    return false
  end
  f:write(content)
  f:close()
  log("Wrote file: " .. path)
  return true
end

-- Simple string hash for version comparison
local function string_hash(str)
  if not str then return "" end
  local hash = 0
  for i = 1, #str do
    hash = ((hash * 31) + string.byte(str, i)) % 2147483647
  end
  return tostring(hash)
end

-- Parse semantic version string into comparable parts
local function parse_version(ver_str)
  if not ver_str then return {0, 0, 0} end
  local major, minor, patch = ver_str:match("^(%d+)%.(%d+)%.(%d+)")
  if major then
    return {tonumber(major), tonumber(minor), tonumber(patch)}
  end
  -- Fallback for non-standard versions
  local num = ver_str:match("^(%d+)")
  return {tonumber(num) or 0, 0, 0}
end

-- Compare two version strings: returns true if v1 > v2
local function version_greater(v1_str, v2_str)
  local v1 = parse_version(v1_str)
  local v2 = parse_version(v2_str)
  for i = 1, 3 do
    if v1[i] > v2[i] then return true end
    if v1[i] < v2[i] then return false end
  end
  return false  -- Equal versions
end

-------------------------------------------------------------------------------
-- Version Management
-------------------------------------------------------------------------------

local function get_last_check_time()
  local val = reaper.GetExtState("RBN_UPDATER", "LAST_CHECK")
  return tonumber(val) or 0
end

local function set_last_check_time(time)
  reaper.SetExtState("RBN_UPDATER", "LAST_CHECK", tostring(time), true)
end

local function get_stored_version_hash()
  return reaper.GetExtState("RBN_UPDATER", "VERSION_HASH") or ""
end

local function set_stored_version_hash(hash)
  reaper.SetExtState("RBN_UPDATER", "VERSION_HASH", hash, true)
end

local function is_due_for_check()
  local last_check = get_last_check_time()
  local now = os.time()
  local interval = AutoUpdater.config.check_interval
  
  if interval == 0 then return true end  -- Force check
  return (now - last_check) >= interval
end

-------------------------------------------------------------------------------
-- Update Check
-------------------------------------------------------------------------------

-- Build the raw GitHub URL for a file
local function get_raw_url(filename)
  local cfg = AutoUpdater.config
  return string.format("%s/%s/%s/%s/%s",
    cfg.raw_base_url,
    cfg.github_user,
    cfg.github_repo,
    cfg.branch,
    filename
  )
end

-- Check for updates to the main script file
local function check_for_updates_silent()
  log("Checking for updates...")
  
  -- Always save check time to avoid repeated checks on failures
  set_last_check_time(os.time())
  
  local main_file = "fcp_tracker_main.lua"
  local url = get_raw_url(main_file)
  
  -- Get remote file content (5 second timeout to avoid slow startup)
  local remote_content, success = http_get(url, 5000)
  if not success or not remote_content then
    log("Failed to fetch remote file for update check")
    return false, nil
  end
  
  -- Verify it looks like valid Lua code
  if not remote_content:match("^%-%-") then
    log("Remote file doesn't appear to be valid Lua")
    return false, nil
  end
  
  -- Extract versions for comparison
  local remote_version = remote_content:match('SCRIPT_VERSION%s*=%s*"([^"]+)"')
  local local_version = AutoUpdater.SCRIPT_VERSION
  
  log("Local version: " .. (local_version or "unknown") .. ", Remote version: " .. (remote_version or "unknown"))
  
  -- Only offer update if remote version is actually newer
  if remote_version and local_version and version_greater(remote_version, local_version) then
    log("Update available! " .. local_version .. " -> " .. remote_version)
    return true, remote_version
  end
  
  log("No updates available (local is same or newer)")
  return false, nil
end

-------------------------------------------------------------------------------
-- Async Download State Machine
-------------------------------------------------------------------------------

local async_state = {
  active = false,
  files_to_check = {},
  current_file_index = 0,
  temp_file = nil,
  done_file = nil,
  updated_files = {},
  failed_files = {},
  on_complete = nil,
  local_path = nil,
}

-- Generate temp file paths
local function get_temp_files()
  local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
  local base = temp_dir .. "/rbn_update_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999))
  return base .. ".tmp", base .. ".done"
end

-- Start async download of a single file to temp location with completion signal
local function start_async_download(url, temp_file, done_file)
  -- Delete any existing temp/done files first
  os.remove(temp_file)
  os.remove(done_file)
  
  local curl_cmd
  if reaper.GetOS():match("Win") then
    -- Windows: run curl then create done file when complete
    -- Using cmd /c with && to chain commands
    curl_cmd = string.format('start /b cmd /c "curl -s -L --max-time 60 "%s" > "%s" && echo done > "%s""', 
      url, temp_file, done_file)
  else
    -- macOS/Linux: use ; to chain commands  
    curl_cmd = string.format('(curl -s -L --max-time 60 "%s" > "%s" ; echo done > "%s") &', 
      url, temp_file, done_file)
  end
  
  log("Starting async download: " .. url)
  os.execute(curl_cmd)
end

-- Check if download is complete (done file exists)
local function check_download_complete(temp_file, done_file)
  -- Check if done file exists
  local f = io.open(done_file, "r")
  if not f then return false, nil end
  f:close()
  
  -- Done file exists, read the actual content
  local content_file = io.open(temp_file, "rb")
  if not content_file then return false, nil end
  
  local content = content_file:read("*all")
  content_file:close()
  
  -- Verify it looks like Lua code
  if content and #content > 50 and content:match("^%-%-") then
    return true, content
  end
  
  return false, nil
end

-- Normalize content for comparison (normalize line endings and strip trailing whitespace)
local function normalize_content(content)
  if not content then return "" end
  -- Convert CRLF to LF, then strip trailing whitespace
  local normalized = content:gsub("\r\n", "\n")
  normalized = normalized:gsub("\r", "\n")
  normalized = normalized:gsub("%s+$", "")
  return normalized
end

-- Process current file in async state machine
local function process_current_file()
  if not async_state.active then return end
  
  local cfg = AutoUpdater.config
  local index = async_state.current_file_index
  local files = async_state.files_to_check
  
  if index > #files then
    -- All files processed
    async_state.active = false
    
    -- Cleanup temp files
    if async_state.temp_file then os.remove(async_state.temp_file) end
    if async_state.done_file then os.remove(async_state.done_file) end
    
    set_last_check_time(os.time())
    
    log(string.format("Async update complete: %d files updated, %d failed", 
      #async_state.updated_files, #async_state.failed_files))
    
    if async_state.on_complete then
      async_state.on_complete(#async_state.updated_files, #async_state.failed_files, async_state.updated_files)
    end
    return
  end
  
  local filename = files[index]
  local url = get_raw_url(filename)
  local local_file = async_state.local_path .. filename
  
  -- Start download for this file
  async_state.temp_file, async_state.done_file = get_temp_files()
  start_async_download(url, async_state.temp_file, async_state.done_file)
  
  -- Start polling for completion
  local poll_count = 0
  local max_polls = 300  -- 30 seconds max per file
  
  local function poll_download()
    -- Poll multiple times per defer cycle to speed up when REAPER is focused
    -- (defer runs slower when focused due to UI frame rate)
    for _ = 1, 10 do
      poll_count = poll_count + 1
      
      local complete, content = check_download_complete(async_state.temp_file, async_state.done_file)
      
      if complete then
        -- Download finished - compare with local
        local local_content = read_file(local_file)
        
        -- Normalize both for comparison
        local norm_remote = normalize_content(content)
        local norm_local = normalize_content(local_content)
        
        -- Log progress
        reaper.ShowConsoleMsg(string.format("[Update] %d/%d: %s ... ", 
          index, #files, filename))
        
        -- Only update if content is actually different
        if norm_remote ~= norm_local then
          if write_file(local_file, content) then
            table.insert(async_state.updated_files, filename)
            reaper.ShowConsoleMsg("UPDATED\n")
          else
            table.insert(async_state.failed_files, filename)
            reaper.ShowConsoleMsg("FAILED\n")
          end
        else
          reaper.ShowConsoleMsg("unchanged\n")
        end
        
        -- Clean up temp files
        os.remove(async_state.temp_file)
        os.remove(async_state.done_file)
        
        -- Move to next file
        async_state.current_file_index = index + 1
        reaper.defer(process_current_file)
        return  -- Exit the poll loop
        
      elseif poll_count >= max_polls then
        -- Timeout - skip this file
        reaper.ShowConsoleMsg(string.format("[Update] %d/%d: %s ... TIMEOUT\n", 
          index, #files, filename))
        table.insert(async_state.failed_files, filename)
        os.remove(async_state.temp_file)
        os.remove(async_state.done_file)
        async_state.current_file_index = index + 1
        reaper.defer(process_current_file)
        return  -- Exit the poll loop
      end
    end
    
    -- Still waiting, defer again
    reaper.defer(poll_download)
  end
  
  -- Start polling after a short delay
  reaper.defer(poll_download)
end

-- Start async update process
local function apply_updates_async(on_complete)
  log("Starting async update...")
  
  local cfg = AutoUpdater.config
  
  async_state.active = true
  async_state.files_to_check = {}
  async_state.current_file_index = 1
  async_state.updated_files = {}
  async_state.failed_files = {}
  async_state.on_complete = on_complete
  async_state.local_path = cfg.local_path or get_script_path()
  
  -- Copy file list
  for _, f in ipairs(cfg.files) do
    table.insert(async_state.files_to_check, f)
  end
  
  -- Start processing
  reaper.defer(process_current_file)
end

-- Legacy synchronous apply_updates (kept for compatibility but not recommended)
local function apply_updates(on_complete)
  log("Applying updates (sync mode - not recommended)...")
  
  local cfg = AutoUpdater.config
  local local_path = cfg.local_path or get_script_path()
  local updated_files = {}
  local failed_files = {}
  
  for _, filename in ipairs(cfg.files) do
    local url = get_raw_url(filename)
    local local_file = local_path .. filename
    
    log("Downloading: " .. filename)
    local content, success = http_get(url, 30000)
    
    if success and content and content:match("^%-%-") then
      -- Compare with local content
      local local_content = read_file(local_file)
      
      if normalize_content(content) ~= normalize_content(local_content) then
        -- Write new file (no backup)
        if write_file(local_file, content) then
          table.insert(updated_files, filename)
          log("Updated (changed): " .. filename)
        else
          table.insert(failed_files, filename)
        end
      else
        log("Skipped (unchanged): " .. filename)
      end
    else
      -- File might not exist in repo (optional), skip silently
      log("Skipped (not found or invalid): " .. filename)
    end
  end
  
  set_last_check_time(os.time())
  
  log(string.format("Update complete: %d files updated, %d failed", 
    #updated_files, #failed_files))
  
  if on_complete then
    on_complete(#updated_files, #failed_files, updated_files)
  end
  
  return #updated_files > 0
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

-- Initialize the updater with the script's path
function AutoUpdater.init(script_path)
  AutoUpdater.config.local_path = script_path or get_script_path()
  log("Initialized with path: " .. AutoUpdater.config.local_path)
end

-- Set GitHub repository info
function AutoUpdater.set_repo(user, repo, branch)
  AutoUpdater.config.github_user = user
  AutoUpdater.config.github_repo = repo
  AutoUpdater.config.branch = branch or "main"
end

-- Check for updates (non-blocking, returns immediately)
-- Returns: has_update (bool), version (string or nil)
function AutoUpdater.check()
  if not is_due_for_check() then
    log("Skipping check - not due yet")
    return false, nil
  end
  return check_for_updates_silent()
end

-- Force check for updates regardless of interval
function AutoUpdater.force_check()
  AutoUpdater.config.check_interval = 0
  local has_update, version = check_for_updates_silent()
  AutoUpdater.config.check_interval = 86400  -- Reset to default
  return has_update, version
end

-- Async check for updates - calls callback(has_update, version) when done
-- This is non-blocking and respects check_interval
function AutoUpdater.check_async(callback)
  if not is_due_for_check() then
    log("Skipping check - not due yet")
    if callback then callback(false, nil) end
    return
  end
  
  -- For the version check, we use synchronous HTTP since it's fast (5 second timeout)
  -- The actual file downloads use async
  local has_update, version = check_for_updates_silent()
  if callback then
    callback(has_update, version)
  end
end

-- Apply available updates (async version - recommended)
-- on_complete receives: (updated_count, failed_count, file_list)
function AutoUpdater.update_async(on_complete)
  apply_updates_async(on_complete)
end

-- Apply available updates (sync version - blocks REAPER, avoid if possible)
-- Returns: success (bool), count of files updated
function AutoUpdater.update(on_complete)
  return apply_updates(on_complete)
end

-- Check and update in one call (async)
function AutoUpdater.run(show_message)
  local has_update, version = AutoUpdater.check()
  
  if has_update then
    if show_message then
      local response = reaper.MB(
        string.format(
          "Detected a newer version of the Song Progress Tracker.\n\nYou are on: v%s\nLatest version: v%s\n\nWould you like to update now?\n\n(The script will close after updating. Please restart it.)",
          AutoUpdater.SCRIPT_VERSION or "unknown",
          version or "unknown"
        ),
        "Update Available",
        4  -- Yes/No
      )
      
      if response == 6 then  -- Yes
        AutoUpdater.update_async(function(updated, failed, files)
          if updated > 0 then
            reaper.MB(
              string.format(
                "Updated %d file(s) successfully!\n\nThe script will now close. Please start it again to use the new version.",
                updated
              ),
              "Update Complete",
              0
            )
            -- Signal to stop the script
            if RBN_STOP_SCRIPT then
              RBN_STOP_SCRIPT()
            end
          elseif failed > 0 then
            reaper.MB(
              string.format("Update failed for %d file(s). Please try again later.", failed),
              "Update Failed",
              0
            )
          else
            reaper.MB("No files needed updating - you already have the latest version.", "Up to Date", 0)
          end
        end)
        return true
      end
    else
      AutoUpdater.update_async()
      return true
    end
  elseif show_message then
    reaper.MB("You are running the latest version (v" .. (AutoUpdater.SCRIPT_VERSION or "?") .. ").", "Up to Date", 0)
  end
  
  return false
end

-- Force check and update (bypasses check interval) - use for manual "Check for Updates" button
function AutoUpdater.force_run(show_message)
  -- Enable debug logging for manual checks
  local old_debug = AutoUpdater.config.debug
  AutoUpdater.config.debug = true
  
  local has_update, version = AutoUpdater.force_check()
  
  AutoUpdater.config.debug = old_debug
  
  if has_update then
    if show_message then
      local response = reaper.MB(
        string.format(
          "Detected a newer version of the Song Progress Tracker.\n\nYou are on: v%s\nLatest version: v%s\n\nWould you like to update now?\n\n(The script will close after updating. Please restart it.)",
          AutoUpdater.SCRIPT_VERSION or "unknown",
          version or "unknown"
        ),
        "Update Available",
        4  -- Yes/No
      )
      
      if response == 6 then  -- Yes
        AutoUpdater.update_async(function(updated, failed, files)
          if updated > 0 then
            reaper.MB(
              string.format(
                "Updated %d file(s) successfully!\n\nThe script will now close. Please start it again to use the new version.",
                updated
              ),
              "Update Complete",
              0
            )
            -- Signal to stop the script
            if RBN_STOP_SCRIPT then
              RBN_STOP_SCRIPT()
            end
          elseif failed > 0 then
            reaper.MB(
              string.format("Update failed for %d file(s). Please try again later.", failed),
              "Update Failed",
              0
            )
          else
            reaper.MB("No files needed updating - you already have the latest version.", "Up to Date", 0)
          end
        end)
        return true
      end
    else
      AutoUpdater.update_async()
      return true
    end
  elseif show_message then
    reaper.MB("You are running the latest version (v" .. (AutoUpdater.SCRIPT_VERSION or "?") .. ").", "Up to Date", 0)
  end
  
  return false
end

-- Get current version
function AutoUpdater.get_version()
  return AutoUpdater.SCRIPT_VERSION
end

-- Enable/disable debug logging
function AutoUpdater.set_debug(enabled)
  AutoUpdater.config.debug = enabled
end

-------------------------------------------------------------------------------
-- Return module
-------------------------------------------------------------------------------

return AutoUpdater
