-- @description List REAPER API functions in pages (600 per page) and wait for user input
-- @version 1.0
-- @author ChatGPT
-- @noindex

local PAGE_SIZE = 600

local function collect_api_names()
  local names = {}
  for k, v in pairs(reaper) do
    if type(k) == "string" and type(v) == "function" then
      names[#names + 1] = k
    end
  end
  table.sort(names, function(a, b)
    a = a:lower(); b = b:lower()
    if a == b then return a < b end
    return a < b
  end)
  return names
end

local function msg(s) reaper.ShowConsoleMsg(s) end

local function run()
  reaper.ClearConsole()
  msg("Starting API function list...\n")
  msg(("Page size: %d\n\n"):format(PAGE_SIZE))

  local begin = reaper.MB(
    ("Press OK to begin listing APIs in pages of %d.\nPress Cancel to abort."):format(PAGE_SIZE),
    "REAPER API Pager",
    1 -- OK/Cancel
  )
  if begin ~= 1 then return end

  local names = collect_api_names()
  local total = #names
  local pages = math.max(1, math.ceil(total / PAGE_SIZE))

  local printed = 0
  for p = 1, pages do
    local start_i = (p - 1) * PAGE_SIZE + 1
    local end_i   = math.min(p * PAGE_SIZE, total)

    msg(("--- PAGE %d of %d | entries %d–%d of %d ---\n"):format(p, pages, start_i, end_i, total))
    for i = start_i, end_i do
      msg(names[i] .. "\n")
      printed = printed + 1
    end
    msg("\n")

    if p < pages then
      local cont = reaper.MB(
        ("Printed %d of %d.\nPress OK for next page.\nPress Cancel to stop."):format(printed, total),
        "REAPER API Pager",
        1 -- OK/Cancel
      )
      if cont ~= 1 then break end
    end
  end

  msg(("Done. Listed %d of %d API functions.\n"):format(printed, total))
end

run()

