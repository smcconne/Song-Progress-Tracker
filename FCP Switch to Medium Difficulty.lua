-- @description FCP Switch to Medium Difficulty
-- @author FinestCardboardPearls
-- @version 1.0.0
-- RBN Preview – Medium (signal)
reaper.SetExtState("FCP_PREVIEWS", "REQUEST", "MEDIUM", false)
reaper.defer(function() end) -- no undo point