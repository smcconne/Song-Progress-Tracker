-- @description FCP Switch to Expert Difficulty
-- @author FinestCardboardPearls
-- @version 1.0.0
-- RBN Preview – Expert (signal)
reaper.SetExtState("FCP_PREVIEWS", "REQUEST", "EXPERT", false)
reaper.defer(function() end) -- no undo point