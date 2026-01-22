-- @description FCP Switch to Hard Difficulty
-- @author FinestCardboardPearls
-- @version 1.0.0
-- RBN Preview – Hard (signal)
reaper.SetExtState("FCP_PREVIEWS", "REQUEST", "HARD", false)
reaper.defer(function() end) -- no undo point