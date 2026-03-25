-- fcp_tracker_config.lua
-- Description: RBN Preview Driver configuration and shared constants

---------------------------------------
-- USER CONFIG
---------------------------------------
STARTUP_POPUP = true

-- App / UI constants for Progress Tracker
APP_NAME   = "Song Progress Tracker"
WINDOW_W   = 900
H          = 380

FIRST_COL_W   = 82
REGION_COL_W  = 82
TIME_COL_W    = 50
BTN_W         = 26
BTN_GAP       = 6
OUTLINE_PAD_X = 6
OUTLINE_PAD_Y = 3

-- Solo button state (nil = not soloed, string = parent track currently soloed)
SOLO_ACTIVE_PARENT = nil

-- Tabs and mappings
TABS         = {"Preferences","Setup","Drums","Bass","Guitar","Keys","Vocals","Venue","Overdrive"}
DIFFS        = {"Expert","Hard","Medium","Easy"}
TAB_TRACK    = {Drums="PART DRUMS", Bass="PART BASS", Guitar="PART GUITAR", Keys="PART KEYS"}
TRACK_TO_TAB = {
  ["PART DRUMS"]="Drums", ["PART BASS"]="Bass", ["PART GUITAR"]="Guitar", ["PART KEYS"]="Keys",
  ["PART REAL_KEYS_X"]="Keys", ["PART REAL_KEYS_H"]="Keys", ["PART REAL_KEYS_M"]="Keys", ["PART REAL_KEYS_E"]="Keys",
  ["CAMERA"]="Venue", ["LIGHTING"]="Venue"
}
TAB_CANON    = { DRUMS="Drums", BASS="Bass", GUITAR="Guitar", KEYS="Keys", VOCALS="Vocals", VENUE="Venue", CAMERA="Camera", LIGHTING="Lighting" }
DIFF_CANON   = { EXPERT="Expert", HARD="Hard", MEDIUM="Medium", EASY="Easy", H1="H1", H2="H2", H3="H3", V="V", CAMERA="Camera", LIGHTING="Lighting" }
ACTIVE_DIFF  = "Expert"

-- Vocals sub-modes and track names
VOCALS_TRACKS = { H1="HARM1", H2="HARM2", H3="HARM3", V="PART VOCALS" }
VOCALS_PITCH_RANGE = {36, 84} -- inclusive

-- Pro Keys sub-modes and track names
PRO_KEYS_TRACKS = { X="PART REAL_KEYS_X", H="PART REAL_KEYS_H", M="PART REAL_KEYS_M", E="PART REAL_KEYS_E" }
PRO_KEYS_PITCH_RANGE = {48, 72} -- inclusive
DIFFS_PRO_KEYS = {"X", "H", "M", "E"}

-- Venue sub-modes and track names
VENUE_TRACKS = { Camera="CAMERA", Lighting="LIGHTING" }
VENUE_MODES  = { "Camera", "Lighting" }

-- Sing/Spot custom note orders for the VENUE track (MIDI note numbers)
SPOT_NOTE_ORDER      = "  CUSTOM_NOTE_ORDER 37 38 39 40 41"
SING_NOTE_ORDER      = "  CUSTOM_NOTE_ORDER 85 86 87"
SING_SPOT_NOTE_ORDER = "  CUSTOM_NOTE_ORDER 37 38 39 40 41 84 85 86 87"

-- Camera sub-mode note orders
-- Single/Multi (undirected)
CAMERA_SINGLE_NOTE_ORDER     = "  CUSTOM_NOTE_ORDER 74 75 76 77 78 79 80 81 82 83 84 85 86 87 88 89 90 91 92 93"
CAMERA_MULTI_NOTE_ORDER      = "  CUSTOM_NOTE_ORDER 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 95 96 97 98 99 100"
-- Single/Multi (directed)
CAMERA_SINGLE_DIR_NOTE_ORDER = "  CUSTOM_NOTE_ORDER 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49"
CAMERA_MULTI_DIR_NOTE_ORDER  = "  CUSTOM_NOTE_ORDER 10 11 12 13 14 15 16 17 18 51 52 53 54 55 56"

-- Lighting sub-mode note orders (Post = rows 41-71, Light = rows 13-39, Misc = rows 8-12 + 73-74)
LIGHTING_POST_NOTE_ORDER  = "  CUSTOM_NOTE_ORDER 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72"
LIGHTING_LIGHT_NOTE_ORDER = "  CUSTOM_NOTE_ORDER 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40"
LIGHTING_MISC_NOTE_ORDER  = "  CUSTOM_NOTE_ORDER 8 9 10 11 12 73 74"

-- Pitch ranges used by the model (non-vocals)
PITCH_RANGE = { Expert={96,100}, Hard={84,88}, Medium={72,76}, Easy={60,64} }

-- Persistence for Progress Tracker
EXTNAME          = "FCP_SECMAT_V1"
JUMP_EXT_SECTION = "FCP_JUMP"
JUMP_EXT_KEY     = "TARGET_REGION_ID"
JUMP_EXT_PERSIST = false

-- Preview Driver track names
TRACKS = {
  DRUMS  = "PART DRUMS",
  BASS   = "PART BASS",
  GUITAR = "PART GUITAR",
  KEYS   = "PART KEYS",
}

-- tiling order used across modules
ORDER = { "DRUMS", "BASS", "GUITAR", "KEYS" }

-- instrument FX name substring used to find the VSTi
TARGET_FX_NAME = "RBN Preview"

TEMPLATES = {
  EXPERT = { DRUMS="Drums Expert Only",  BASS="Bass Expert Only",  GUITAR="Guitar Expert Only",  KEYS="Keys Expert Only" },
  HARD   = { DRUMS="Drums Hard Only",    BASS="Bass Hard Only",    GUITAR="Guitar Hard Only",    KEYS="Keys Hard Only"   },
  MEDIUM = { DRUMS="Drums Medium Only",  BASS="Bass Medium Only",  GUITAR="Guitar Medium Only",  KEYS="Keys Medium Only" },
  EASY   = { DRUMS="Drums Easy Only",    BASS="Bass Easy Only",    GUITAR="Guitar Easy Only",    KEYS="Keys Easy Only"   },

  HOPOS      = { DRUMS="Drums Toms",  BASS="Bass HOPOs",               GUITAR="Guitar HOPOs",               KEYS="Keys HOPOs"               },
  TRILLS     = { DRUMS="Drums Rolls OD Solo", BASS="Bass Trill Strum", GUITAR="Guitar Trill Strum",         KEYS="Keys Trill Strum"         },
  BRE        = { DRUMS="Drums Fills", BASS="Bass BRE",                 GUITAR="Guitar BRE",                 KEYS="Keys BRE"                  },
}

-- Tiling + focus timings
GAP_PX      = -50
NUDGE_BIG   = 4
NUDGE_SMALL = 1
DELAY_BIG   = 0.10
DELAY_SMALL = 0.10
FOCUS_DELAY = 0.06

-- ExtState keys
EXT_NS     = "FCP_PREVIEWS"
EXT_REQ    = "REQUEST"
EXT_FOCUS  = "FOCUS"
EXT_LINEUP = "LINEUP"
EXT_WH_X   = "GEOM_X"
EXT_WH_Y   = "GEOM_Y"
EXT_WH_W   = "GEOM_W"
EXT_WH_H   = "GEOM_H"

-- Script command lookup strings (stored globally, not per-project)
EXT_CMD_ENCORE_VOX    = "CMD_ENCORE_VOX"
EXT_CMD_LYRICS_CLIP   = "CMD_LYRICS_CLIP"
EXT_CMD_SPECTRACULAR  = "CMD_SPECTRACULAR"
EXT_CMD_VENUE_PREVIEW = "CMD_VENUE_PREVIEW"
EXT_CMD_PRO_KEYS_PREVIEW = "CMD_PRO_KEYS_PREVIEW"

-- Per-action tab list prefix (stored as comma-separated tab names)
EXT_ACTION_TABS_PREFIX = "ACTION_TABS_"

-- Per-action "leaving tab set" preference prefix
EXT_ACTION_LEAVING_TAB_SET_PREFIX = "ACTION_LEAVING_TAB_SET_"

-- Colors as U32 (requires ReaImGui but no context)
local ImGui = reaper
COL_RED     = ImGui.ImGui_ColorConvertDouble4ToU32(1,0,0,1)
COL_YELLOW  = ImGui.ImGui_ColorConvertDouble4ToU32(1,1,0,1)
COL_GREEN   = ImGui.ImGui_ColorConvertDouble4ToU32(0,1,0,1)
COL_GRAY    = ImGui.ImGui_ColorConvertDouble4ToU32(0.6,0.6,0.6,1)
OUTLINE_COL = ImGui.ImGui_ColorConvertDouble4ToU32(1,1,1,1)

-- Status captions and colors used by the progress table
STATE_TEXT  = { [0]="Not Started", [1]="In Progress", [2]="Complete", [3]="Empty" }
STATE_COLOR = { [0]=COL_RED,       [1]=COL_YELLOW,    [2]=COL_GREEN,  [3]=COL_GRAY }

-- indices used by tiling helpers (left→right slots)
SLOT_IDX = SLOT_IDX or { DRUMS=0, BASS=1, GUITAR=2, KEYS=3 }

-- focus bookkeeping
focus_epoch = focus_epoch or {}

function mb(msg, title) return reaper.MB(tostring(msg or ""), tostring(title or "RBN Preview Driver"), 0) end
function no_undo() reaper.defer(function() end) end

-- Overdrive pitch (used across all instrument tracks)
OVERDRIVE_PITCH = 116

-- Overdrive tracks to scan (in row order)
OVERDRIVE_TRACKS = {"PART DRUMS", "PART BASS", "PART GUITAR", "PART KEYS"}
OVERDRIVE_ROWS = {"Drums", "Bass", "Guitar", "Keys"}

-- OV table brightness: max notes per measure for full brightness (1-100)
OV_MAX_NOTES_BRIGHTNESS = OV_MAX_NOTES_BRIGHTNESS or 12

-- OV table: show grey note rectangles (on by default)
OV_SHOW_NOTES = (OV_SHOW_NOTES == nil) and true or OV_SHOW_NOTES
