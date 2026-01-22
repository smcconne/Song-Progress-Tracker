-- @description FCP Switch to Easy Difficulty
-- @author FinestCardboardPearls
-- @version 1.0.0
-- RBN Preview – Easy (signal)
reaper.SetExtState("FCP_PREVIEWS", "REQUEST", "EASY", false)
reaper.defer(function() end) -- no undo point