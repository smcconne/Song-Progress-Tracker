-- fcp_tracker_templates.lua
-- Inline preview FX + CUSTOM_NOTE_ORDER, no .RTrackTemplate I/O.

-- Expected globals from other modules:
--   TRACKS                 (from rbn_preview_config.lua)
--   find_track_by_name     (from util/focus helpers)
--   snapshot_selection,
--   restore_selection,
--   deselect_all_tracks    (selection helpers)
--   extract_vst_body_and_preset,
--   find_fxchain_span_depth,
--   apply_custom_note_order (from chunk/FX helpers)

local reaper = reaper

----------------------------------------------------------------
-- 1. Inline template data
--
-- Each entry is keyed by "kind" (EXPERT, HARD, HOPOS, etc),
-- then by slot key ("DRUMS", "BASS", "GUITAR", "KEYS").
--
-- For each slot you can provide:
--   fxchain           -> string containing a <VST ...> block (or whole <FXCHAIN> block)
--   custom_note_order -> string WITHOUT leading newline, e.g.
--                        "  CUSTOM_NOTE_ORDER 96 97 98 99 100"
--
-- If fxchain is nil, the FX are left alone and only CUSTOM_NOTE_ORDER is applied.
----------------------------------------------------------------

local INLINE_TEMPLATES = {
  ----------------------------------------------------------------
  -- Expert difficulty: shared CUSTOM_NOTE_ORDER for all four tracks.
  -- The Bass Expert fxchain below is taken from your generator
  -- script that was built from "Bass Expert Only.RTrackTemplate".
  ----------------------------------------------------------------
  EXPERT = {
    DRUMS = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 469 172 1756 1068
    SHOW 0
    LASTSEL 0
    DOCKED 0
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AwGqAA==
      AEV4cGVydCBQcm8gRHJ1bXMAAAAAAA==
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 96 97 98 99 100",
    },

    BASS = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 221 84 903 877
    SHOW 0
    LASTSEL 0
    DOCKED 0
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AwCqAA==
      AEV4cGVydCBHdWl0YXIvQmFzcwAAAAAA
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 96 97 98 99 100",
    },

    GUITAR = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 236 144 1080 1068
    SHOW 0
    LASTSEL 0
    DOCKED 1
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AwCqAA==
      AEV4cGVydCBHdWl0YXIvQmFzcwAAAAAA
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 96 97 98 99 100",
    },

    KEYS = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 1622 443 878 585
    SHOW 0
    LASTSEL 0
    DOCKED 0
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AwOqAA==
      AAAAAAAA
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 96 97 98 99 100",
    },
  },

  ----------------------------------------------------------------
  HARD = {
    DRUMS = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 469 172 1756 1068
    SHOW 0
    LASTSEL 0
    DOCKED 0
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AgGqAA==
      AEhhcmQgUHJvIERydW1zAAAAAAA=
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 84 85 86 87 88",
    },

    BASS = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 221 84 903 877
    SHOW 0
    LASTSEL 0
    DOCKED 0
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AgCqAA==
      AEV4cGVydCBHdWl0YXIvQmFzcwAAAAAA
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 84 85 86 87 88",
    },

    GUITAR = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 236 144 1080 1068
    SHOW 0
    LASTSEL 0
    DOCKED 1
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AgCqAA==
      AEhhcmQgR3VpdGFyL0Jhc3MAAAAAAA==
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 84 85 86 87 88",
    },

    KEYS = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 1622 443 878 585
    SHOW 0
    LASTSEL 0
    DOCKED 0
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AgOqAA==
      AAAAAAAA
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 84 85 86 87 88",
    },
  },

  ----------------------------------------------------------------
  MEDIUM = {
    DRUMS = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 469 172 1756 1068
    SHOW 0
    LASTSEL 0
    DOCKED 0
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AQGqAA==
      AEV4cGVydCBQcm8gRHJ1bXMAAAAAAA==
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 72 73 74 75 76",
    },

    BASS = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 221 84 903 877
    SHOW 0
    LASTSEL 0
    DOCKED 0
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AQCqAA==
      AE1lZGl1bSBHdWl0YXIvQmFzcwAAAAAA
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 72 73 74 75 76",
    },

    GUITAR = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 236 144 1080 1068
    SHOW 0
    LASTSEL 0
    DOCKED 1
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AQCqAA==
      AE1lZGl1bSBHdWl0YXIvQmFzcwAAAAAA
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 72 73 74 75 76",
    },
    
    KEYS = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 1622 443 878 585
    SHOW 0
    LASTSEL 0
    DOCKED 0
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AQOqAA==
      AAAAAAAA
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 72 73 74 75 76",
    },
  },

  ----------------------------------------------------------------
  EASY = {
    DRUMS = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 469 172 1756 1068
    SHOW 0
    LASTSEL 0
    DOCKED 0
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AAGqAA==
      AEV4cGVydCBQcm8gRHJ1bXMAAAAAAA==
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 60 61 62 63 64",
    },
    
    BASS = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 221 84 903 877
    SHOW 0
    LASTSEL 0
    DOCKED 0
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AACqAA==
      AEVhc3kgR3VpdGFyL0Jhc3MAAAAAAA==
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 60 61 62 63 64",
    },

    GUITAR = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 236 144 1080 1068
    SHOW 0
    LASTSEL 0
    DOCKED 1
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AACqAA==
      AEVhc3kgR3VpdGFyL0Jhc3MAAAAAAA==
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 60 61 62 63 64",
    },

    KEYS = {
      fxchain = [[
  <FXCHAIN
    WNDRECT 1622 443 878 585
    SHOW 0
    LASTSEL 0
    DOCKED 0
    BYPASS 0 0 0
    <VST "VSTi: RBN Preview (RBN)" rbprev_vst.dll 0 "" 1919053942<5653547262707672626E707265766965> ""
      dnBicu5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAEAAAAAQAAAAAAAAA=
      AAOqAA==
      AAAAAAAA
    >
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 60 61 62 63 64",
    },
  },

  ----------------------------------------------------------------
  -- Example: HOPOs (and Toms) view, note rows only (FX unchanged).
  ----------------------------------------------------------------
  HOPOS = {
    DRUMS = {
      fxchain = [[
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 110 111 112",
    },
    BASS = {
      fxchain = [[
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 89 90 101 102",
    },
    GUITAR = {
      fxchain = [[
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 89 90 101 102",
    },
    KEYS = {
      fxchain = [[
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 89 90 101 102",
    },
  },

  ----------------------------------------------------------------
  -- Example: TRILLS view, note rows only (FX unchanged).
  ----------------------------------------------------------------
  TRILLS = {
    DRUMS = {
      fxchain = [[
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 126 127 103",
    },
    BASS = {
      fxchain = [[
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 126 127 103",
    },
    GUITAR = {
      fxchain = [[
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 126 127 103",
    },
    KEYS = {
      fxchain = [[
]],
      custom_note_order = "  CUSTOM_NOTE_ORDER 126 127 103",
    },
  },
}

----------------------------------------------------------------
-- 2. Precompute per-kind/per-slot preview state
--    (VST body, preset line, CUSTOM_NOTE_ORDER line)
----------------------------------------------------------------

local PREVIEW_STATE = {}

for kind, perInst in pairs(INLINE_TEMPLATES) do
  local kindState = PREVIEW_STATE[kind] or {}
  for slotKey, tpl in pairs(perInst) do
    local vstBody, preset = nil, nil
    if tpl.fxchain and tpl.fxchain ~= "" then
      vstBody, preset = extract_vst_body_and_preset(tpl.fxchain)
      if not vstBody then
        error(
          ("INLINE_TEMPLATES[%s][%s].fxchain does not contain a valid <VST> block")
          :format(tostring(kind), tostring(slotKey))
        )
      end
    end
    kindState[slotKey] = {
      vst_body = vstBody,                 -- may be nil (no FX change)
      preset   = preset,                  -- may be nil if no PRESETNAME in fxchain
      noteLine = tpl.custom_note_order,   -- may be nil (no CUSTOM_NOTE_ORDER change)
    }
  end
  PREVIEW_STATE[kind] = kindState
end

----------------------------------------------------------------
-- 3. Internal helper: apply inline state to a single track
----------------------------------------------------------------

local function apply_preview_state_to_track(track, slotKey, kind)
  local kindState = PREVIEW_STATE[kind]
  if not kindState then
    error(("No PREVIEW_STATE defined for kind '%s'"):format(tostring(kind)))
  end

  local cfg = kindState[slotKey]
  if not cfg then
    error(
      ("No PREVIEW_STATE defined for kind '%s', slot '%s'")
      :format(tostring(kind), tostring(slotKey))
    )
  end

  if not track then return end

  local ok, chunk = reaper.GetTrackStateChunk(track, "", true)
  if not ok or not chunk or chunk == "" then return end

  -- 3a. FXCHAIN update (if we have a stored VST body)
  if cfg.vst_body then
    local sPos, ePos = find_fxchain_span_depth(chunk)
    local liveFX = sPos and ePos and chunk:sub(sPos, ePos - 1) or nil
    if not liveFX then
      -- This is a structural problem, so highlight it but don't crash.
      local _, trName = reaper.GetTrackName(track, "")
      reaper.ShowMessageBox(
        ("Track '%s' has no FXCHAIN; expected RBN Preview instrument.\n\nSlot: %s / Kind: %s")
        :format(tostring(trName or slotKey), tostring(slotKey), tostring(kind)),
        "RBN Previews",
        0
      )
      return
    end

    local liveFX_new = replace_vst_body_and_preset_in_fxchain(
      liveFX,
      cfg.vst_body,
      cfg.preset
    )

    chunk = chunk:sub(1, sPos - 1) .. liveFX_new .. chunk:sub(ePos)
  end

  -- 3b. CUSTOM_NOTE_ORDER update (if configured)
  if cfg.noteLine and cfg.noteLine ~= "" then
    chunk = apply_custom_note_order(chunk, cfg.noteLine)
  end

  reaper.SetTrackStateChunk(track, chunk, false)
end

----------------------------------------------------------------
-- 4. Public API used by the preview driver
----------------------------------------------------------------

-- Kept as a thin wrapper so existing call sites can be migrated easily
local function apply_template_to_named_track(trackName, slotKey, kind)
  local tr = find_track_by_name(trackName)
  if not tr then return end
  apply_preview_state_to_track(tr, slotKey, kind)
end

function run_set(kind)
  local saved = snapshot_selection()

  local function select_only(tr)
    if tr then
      deselect_all_tracks()
      reaper.SetOnlyTrackSelected(tr)
    end
  end

  reaper.PreventUIRefresh(1)

  do
    local tr = find_track_by_name(TRACKS.DRUMS)
    select_only(tr)
    if tr then apply_preview_state_to_track(tr, "DRUMS",  kind) end
  end

  do
    local tr = find_track_by_name(TRACKS.BASS)
    select_only(tr)
    if tr then apply_preview_state_to_track(tr, "BASS",   kind) end
  end

  do
    local tr = find_track_by_name(TRACKS.GUITAR)
    select_only(tr)
    if tr then apply_preview_state_to_track(tr, "GUITAR", kind) end
  end

  do
    local tr = find_track_by_name(TRACKS.KEYS)
    select_only(tr)
    if tr then apply_preview_state_to_track(tr, "KEYS",   kind) end
  end

  reaper.PreventUIRefresh(-1)

  restore_selection(saved)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
end
