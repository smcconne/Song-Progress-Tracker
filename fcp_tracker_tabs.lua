-- fcp_tracker_tabs.lua
-- Tab / Variant / Mode registry for the Song Progress Tracker.
--
-- This module owns the TABS registry, the Tab object model, and the
-- tab-change / mode-change dispatchers. It is loaded immediately after
-- fcp_tracker_config.lua and before any module that reads `current_tab`.
--
-- See openspec/changes/refactor-tab-architecture/ for the design.
--
-- The TABS_BY_NAME dict of Tab objects owns the active variant
-- (_variant_key) and mode (_mode_key on the active variant). Data tables
-- (TAB_TRACK, VOCALS_TRACKS, PRO_KEYS_TRACKS, VENUE_TRACKS, PITCH_RANGE,
-- etc.) in fcp_tracker_config.lua remain the source of truth for
-- tracknames/pitch data, but the active mode no longer lives in a global.

-- Dispatcher stubs (state mutation only; side effects run in fcp_tracker_ui_tabs.lua)

-- Per-tab default mode key (canonical form: Expert/Hard/Medium/Easy for
-- instruments+Keys, H1/H2/H3/V for Vocals, Camera/Lighting for Venue).
local TAB_DEFAULT_MODE = {
  Drums = "Expert", Bass = "Expert", Guitar = "Expert",
  Keys  = "Expert",
  Vocals = "V", Venue = "Camera",
}

-- Re-apply the active difficulty's preview FX/note order (instrument tabs only).
-- Internal helper: snake_case; global so other modules can call it.
function apply_run_set_for_tab(tab_name)
  if tab_name == "Drums" or tab_name == "Bass" or tab_name == "Guitar" or tab_name == "Keys" then
    local mode = TABS_BY_NAME[tab_name]:current_mode_key()
    if mode and (mode == "Expert" or mode == "Hard" or mode == "Medium" or mode == "Easy") then
      if run_set then run_set(mode:upper()) end
    end
  end
end

function set_active_tab(name, variant_or_nil, mode_or_nil, force_screenset)
  -- State mutator + dispatcher. Captures the old variant/mode state BEFORE
  -- mutating so idempotency/persist/run_actions see the old values.
  local new_obj = TABS_BY_NAME[name]
  if not new_obj then return end

  local old_name        = current_tab
  local old_obj         = TABS_BY_NAME[old_name]

  -- Snapshot pre-mutation mode keys for idempotency, persist, run_actions.
  local keys_obj = TABS_BY_NAME["Keys"]
  local old_pro_keys_active = keys_obj._variant_key == "pro"
  local old_keys_mode   = keys_obj:current_mode_key()
  local old_vocals_mode = TABS_BY_NAME["Vocals"]:current_mode_key()
  local old_venue_mode  = TABS_BY_NAME["Venue"]:current_mode_key()

  -- Skip during startup so screenset / FX alignment defers until the
  -- ImGui window has time to lay out.
  if FCP_STARTUP_MODE then
    if variant_or_nil ~= nil and name == "Keys" then
      keys_obj:set_variant(variant_or_nil == "pro" and "pro" or "regular")
    end
    if mode_or_nil ~= nil then
      new_obj:set_mode(mode_or_nil)
    end
    current_tab = name
    return
  end

  -- Apply variant change (only Keys has a pro variant today).
  if variant_or_nil ~= nil and name == "Keys" then
    keys_obj:set_variant(variant_or_nil == "pro" and "pro" or "regular")
  end

  -- Apply mode change (route through the Tab setter; Pro Keys takes the
  -- X/H/M/E signal form and stores the canonical key).
  if mode_or_nil ~= nil then
    new_obj:set_mode(mode_or_nil)
  end

  -- Update current_tab.
  current_tab = name

  -- Suppress auto-switch-by-track-selection for this frame; the defer
  -- clears the counter for the Preferences/Setup path.
  FCP_TAB_CHANGE_PENDING = 1
  reaper.defer(function()
    if FCP_TAB_CHANGE_PENDING and FCP_TAB_CHANGE_PENDING > 0 then
      FCP_TAB_CHANGE_PENDING = 0
    end
  end)

  -- Run the side-effect orchestration with the pre-mutation snapshot.
  apply_tab_change(old_obj, new_obj, {
    pro_keys_active  = old_pro_keys_active,
    old_keys_mode    = old_keys_mode,
    old_vocals_mode  = old_vocals_mode,
    old_venue_mode   = old_venue_mode,
    force_screenset  = force_screenset,
    explicit_variant = variant_or_nil,
  })
end

-- Side-effect orchestration for a tab change; idempotent on equal
-- (name, variant) tuples. `old_state` is the pre-mutation snapshot.
function apply_tab_change(old_tab, new_tab, old_state)
  old_state = old_state or {}
  local old_pro_keys_active = old_state.pro_keys_active
  local force_screenset     = old_state.force_screenset

  -- Idempotency: skip when the (name, variant, mode) tuple is unchanged,
  -- unless force_screenset (variant flip) says otherwise.
  if old_tab and new_tab
     and old_tab.name == new_tab.name
     and not force_screenset
  then
    local old_variant_key = "regular"
    if old_tab.name == "Keys" then
      old_variant_key = old_state.pro_keys_active and "pro" or "regular"
    end
    local old_mode
    if old_tab.name == "Keys" then
      old_mode = old_state.old_keys_mode
    elseif old_tab.name == "Vocals" then
      old_mode = old_state.old_vocals_mode
    elseif old_tab.name == "Venue" then
      old_mode = old_state.old_venue_mode
    end
    if old_variant_key == new_tab:current_variant_key()
       and old_mode == new_tab:current_mode_key()
    then
      return
    end
  end

  local name = new_tab.name
  local reaper = reaper

  local was_tab    = old_tab and old_tab.name or nil
  local was_setup  = (was_tab == "Setup" or was_tab == "Preferences")
  local is_setup   = (name == "Setup" or name == "Preferences")
  local is_venue   = (name == "Venue")

  -- 1. Persist variant + overlay toggles of the old tab from the snapshot.
  if old_tab and old_tab.name == "Keys" then
    local saved_variant = old_pro_keys_active and "pro" or "regular"
    reaper.SetProjExtState(0, EXT_NS,
      "LAST_VARIANT_Keys",
      saved_variant)
  end
  if old_tab and old_tab.name == "Venue" then
    local t = old_tab:current_variant().overlay_toggles
    reaper.SetProjExtState(0, EXT_NS, "LAST_VENUE_OVERLAY_SING",   t.sing  and "1" or "0")
    reaper.SetProjExtState(0, EXT_NS, "LAST_VENUE_OVERLAY_SPOT",   t.spot  and "1" or "0")
  end

  -- 2. Restore variant + overlay toggles of the new tab (real tab change only).
  if old_tab and old_tab.name ~= name then
    if name == "Keys" and not old_state.explicit_variant then
      -- Restore the Keys variant from LAST_VARIANT_Keys only. The legacy
      -- PRO_KEYS_ACTIVE ExtState key is no longer consulted.
      local _, last = reaper.GetProjExtState(0, EXT_NS, ("LAST_VARIANT_Keys"):upper())
      if last == "pro" then
        TABS_BY_NAME["Keys"]:set_variant("pro")
      elseif last == "regular" then
        TABS_BY_NAME["Keys"]:set_variant("regular")
      end
    end
    if name == "Venue" then
      local t = TABS_BY_NAME["Venue"]:current_variant().overlay_toggles
      local _, sing = reaper.GetProjExtState(0, EXT_NS, "LAST_VENUE_OVERLAY_SING")
      local _, spot = reaper.GetProjExtState(0, EXT_NS, "LAST_VENUE_OVERLAY_SPOT")
      t.sing = (sing == "1")
      t.spot = (spot == "1")
    end
  end

  -- 3. Screenset load + post-screenset track select (screenset first,
  -- matching the original BeginTabItem ordering).
  if handle_tab_height_switch and not FCP_STARTUP_MODE and not PROJECT_SWITCH_MODE then
    handle_tab_height_switch(nil, name, was_tab, old_pro_keys_active, force_screenset)
  end

  -- Re-apply the active difficulty's preview FX/note order on tab entry
  apply_run_set_for_tab(name)

  -- Re-run track select for plain instrument tabs after the screenset load.
  if name ~= "Setup" and name ~= "Preferences" and name ~= "Vocals"
     and name ~= "Venue" and name ~= "Overdrive"
     and not (name == "Keys" and TABS_BY_NAME["Keys"]:is_pro())
     and select_track_for_tab
  then
    local sel_tr = reaper.GetSelectedTrack(0, 0)
    local sel_name = sel_tr and select(2, reaper.GetTrackName(sel_tr))
    local sel_tab = sel_name and TRACK_TO_TAB[sel_name]
    if sel_tab ~= name then
      select_track_for_tab(name)
    end
  end

  -- 4. FX preference resolution (re-run after screenset in case
  -- the screenset opened floating FX windows)
  local fx_tab = (name == "Keys" and TABS_BY_NAME["Keys"]:is_pro()) and "Pro Keys" or name
  if get_show_floating_fx and get_show_floating_fx(fx_tab) and open_floating_fx_and_align then
    open_floating_fx_and_align()
  end

  -- Prefs dropdown (only when entering the Preferences tab)
  if name == "Preferences" and set_prefs_dropdown_for_tab then
    set_prefs_dropdown_for_tab(was_tab)
  end

  -- TCP visibility (Setup-like tabs only)
  if is_setup ~= was_setup and set_tcp_visibility_for_setup then
    set_tcp_visibility_for_setup(is_setup)
  end

  -- 9. Master track show/hide
  if is_setup and not was_setup then
    local cmd_show = reaper.NamedCommandLookup("_SWS_SHOWMASTER")
    if cmd_show ~= 0 then reaper.Main_OnCommand(cmd_show, 0) end
  elseif was_setup and not is_setup then
    local cmd_hide = reaper.NamedCommandLookup("_SWS_HIDEMASTER")
    if cmd_hide ~= 0 then reaper.Main_OnCommand(cmd_hide, 0) end
  end

  -- 8. MIDI editor open/close + track select
  local me_tab = (name == "Keys" and TABS_BY_NAME["Keys"]:is_pro()) and "Pro Keys" or name
  local want_midi_editor = get_midi_editor_open and get_midi_editor_open(me_tab) or false
  if name == "Setup" or name == "Prefs" or name == "Preferences" then
    if not want_midi_editor and close_midi_editor_if_not_inline then
      close_midi_editor_if_not_inline()
    end
  elseif name == "Vocals" then
    local vocals_trackname = VOCALS_TRACKS[TABS_BY_NAME["Vocals"]:current_mode_key()]
    if want_midi_editor then
      select_and_scroll_track_by_name(vocals_trackname, 40818, 40726)
    else
      select_and_scroll_track_by_name(vocals_trackname)
      if close_midi_editor_if_not_inline then close_midi_editor_if_not_inline() end
    end
  elseif name == "Venue" then
    local venue_trackname = VENUE_TRACKS[TABS_BY_NAME["Venue"]:current_mode_key()]
    if want_midi_editor then
      select_and_scroll_track_by_name(venue_trackname, 40818, 40726)
    else
      select_and_scroll_track_by_name(venue_trackname)
      if close_midi_editor_if_not_inline then close_midi_editor_if_not_inline() end
    end
  elseif name == "Overdrive" then
    if not want_midi_editor and close_midi_editor_if_not_inline then
      close_midi_editor_if_not_inline()
    end
  elseif name == "Keys" and TABS_BY_NAME["Keys"]:is_pro() then
    local trackname = PRO_KEYS_TRACKS[TABS_BY_NAME["Keys"]:current_mode_key()] or PRO_KEYS_TRACKS["Expert"]
    if want_midi_editor then
      select_and_scroll_track_by_name(trackname, 40818, 40726)
    else
      select_and_scroll_track_by_name(trackname)
      if close_midi_editor_if_not_inline then close_midi_editor_if_not_inline() end
    end
  else
    if not want_midi_editor and close_midi_editor_if_not_inline then
      close_midi_editor_if_not_inline()
    end
    if select_track_for_tab then
      local sel_tr = reaper.GetSelectedTrack(0, 0)
      local sel_name = sel_tr and select(2, reaper.GetTrackName(sel_tr))
      local sel_tab = sel_name and TRACK_TO_TAB[sel_name]
      if sel_tab ~= name then
        select_track_for_tab(name)
      end
    end
    if want_midi_editor and select_first_midi_item_on_track then
      local sel_tr2 = reaper.GetSelectedTrack(0, 0)
      if sel_tr2 then select_first_midi_item_on_track(sel_tr2) end
    end
  end

  -- 6. Run-actions. Translate "Keys" to "Pro Keys" alias using the
  -- snapshot for the origin (the live global is the new variant).
  if run_actions_on_tab_switch then
    local origin_v = (was_tab == "Keys" and old_pro_keys_active) and "Pro Keys" or was_tab
    local dest_v   = (name     == "Keys" and TABS_BY_NAME["Keys"]:is_pro()) and "Pro Keys" or name
    run_actions_on_tab_switch(origin_v, dest_v)
  end

  -- 7. ReaSynth + listen-FX
  if disable_reasynth_except_for_tab then
    disable_reasynth_except_for_tab(name)
  end
  if ensure_listen_fx_for_tab then
    ensure_listen_fx_for_tab(name)
  end

  -- 5. MCP visibility
  if set_mcp_visibility_for_audio_tracks then
    set_mcp_visibility_for_audio_tracks()
  end

  -- 10. Variant-specific setup (Vocals note order, Pro Keys default)
  if name == "Vocals" and apply_vocals_note_order then
    VOCALS_NOTE_START = VOCALS_NOTE_START or 48
    apply_vocals_note_order(VOCALS_NOTE_START)
  end
  if name == "Keys" and TABS_BY_NAME["Keys"]:is_pro() then
    reaper.SetExtState(EXT_NS, EXT_REQ, "PK_DEFAULT", false)
    if compute_pro_keys then compute_pro_keys() end
  end

  -- Center on the new tab in the ImGui region table
  WANT_CENTER_ON_TAB = true
  LAST_SEEN_TAB = name

  -- Track zoom to max (skip Setup/Prefs)
  if name ~= "Setup" and name ~= "Prefs" and name ~= "Preferences" then
    local zoom_cmd = 40113
    if reaper.GetToggleCommandState(zoom_cmd) == 0 then
      reaper.Main_OnCommand(zoom_cmd, 0)
    end
  end
end

function set_active_mode(mode_key)
  -- State mutator only; no track re-selection.
  local obj = current_tab_obj and current_tab_obj()
  if not obj then return end
  obj:set_mode(mode_key)
end

-- Thin Tab object factory (reads the config data tables at call time).
local function make_tab_obj(name)
  -- _variant_key holds the active variant; only Keys has "pro" today.
  local self = { name = name, _variant_key = "regular" }

  -- set_variant is the only variant mutation site.
  function self:set_variant(variant_key)
    self._variant_key = variant_key
  end

  -- Per-tab default_preferences; every tab in TABS is present so the
  -- read helper never indexes a missing field.
  local SINGLE_VARIANT_DEFAULTS = {
    Preferences = { show_float_fx = false, show_just_fx = false, midi_editor_open = false },
    Setup     = { show_float_fx = false, show_just_fx = false, midi_editor_open = false },
    Drums     = { show_float_fx = true,  show_just_fx = false, midi_editor_open = false },
    Bass      = { show_float_fx = true,  show_just_fx = false, midi_editor_open = false },
    Guitar    = { show_float_fx = true,  show_just_fx = false, midi_editor_open = false },
    Vocals    = { show_float_fx = false, show_just_fx = false, midi_editor_open = true  },
    Venue     = { show_float_fx = false, show_just_fx = false, midi_editor_open = true  },
    Overdrive = { show_float_fx = true,  show_just_fx = false, midi_editor_open = false },
  }

  -- Variants dict keyed by variant key; Venue owns the Sing/Spot overlays.
  local default_mode = TAB_DEFAULT_MODE[name] or "Expert"
  local variants_dict
  if name == "Keys" then
    variants_dict = {
      regular = { key = "regular", display_name = "Keys",     is_five_lane = true,  screenset = nil, overlay_toggles = nil,
                  _mode_key = default_mode,
                  default_preferences = { show_float_fx = true,  show_just_fx = false, midi_editor_open = false } },
      pro     = { key = "pro",     display_name = "Pro Keys", is_five_lane = false, screenset = nil, overlay_toggles = nil,
                  _mode_key = default_mode,
                  default_preferences = { show_float_fx = false, show_just_fx = true,  midi_editor_open = true  } },
    }
  elseif name == "Venue" then
    variants_dict = {
      regular = {
        key = "regular", display_name = name, is_five_lane = false, screenset = nil,
        overlay_toggles = { sing = false, spot = false },
        _mode_key = default_mode,
        default_preferences = SINGLE_VARIANT_DEFAULTS[name],
      },
    }
  else
    variants_dict = {
      regular = { key = "regular", display_name = name, is_five_lane = nil, screenset = nil, overlay_toggles = nil,
                  _mode_key = default_mode,
                  default_preferences = SINGLE_VARIANT_DEFAULTS[name] },
    }
  end
  self.variants = variants_dict

  function self:set_mode(mode_key)
    -- Mutate the active variant's _mode_key; return the previous key.
    local v = self:current_variant()
    local prev = v._mode_key
    v._mode_key = mode_key
    return prev
  end

  function self.is_pro()
    -- True only for the Keys tab in the "pro" variant.
    return name == "Keys" and self._variant_key == "pro"
  end

  function self.variant_key()
    -- "<tab>" for single-variant, "<tab>:<variant>" for variant-owning.
    if self:is_pro() then return "Keys:pro" end
    return name
  end

  function self.display_name()
    if self:is_pro() then return "Pro Keys" end
    return name
  end

  function self.current_variant_key()
    -- Keys returns self._variant_key; all other tabs return "regular".
    if name == "Keys" then
      return self._variant_key
    end
    return "regular"
  end

  function self.current_variant() return variants_dict[self:current_variant_key()] end

  function self.is_five_lane_tab()
    return name == "Drums" or name == "Bass" or name == "Guitar"
       or (name == "Keys" and not self:is_pro())
  end

  function self.current_mode_key()
    -- Returns the canonical mode key for the active variant.
    local v = self:current_variant()
    if v and v._mode_key then return v._mode_key end
    return nil
  end

  -- Build the mode descriptor (key/trackname/pitch_range) for the active variant.
  function self.current_mode()
    local key = self:current_mode_key()
    if not key then return nil end
    if self:is_pro() then
      return { key = key, trackname = PRO_KEYS_TRACKS[key], pitch_range = PRO_KEYS_PITCH_RANGE }
    end
    if name == "Vocals" then
      return { key = key, trackname = VOCALS_TRACKS[key], pitch_range = VOCALS_PITCH_RANGE }
    end
    if name == "Venue" then
      return { key = key, trackname = VENUE_TRACKS[key], pitch_range = {0, 127} }
    end
    if name == "Drums" or name == "Bass" or name == "Guitar" then
      local tname = TAB_TRACK[name] or (TRACKS and TRACKS[name:upper()])
      return { key = key, trackname = tname, pitch_range = PITCH_RANGE and PITCH_RANGE[key] }
    end
    if name == "Keys" then
      return { key = key, trackname = TAB_TRACK.Keys, pitch_range = PITCH_RANGE and PITCH_RANGE[key] }
    end
    return nil
  end

  function self.has_variant_persistence()
    -- Only Keys has variant persistence today.
    return name == "Keys"
  end

  function self:matches_track(trackname)
    -- Returns the mode key if this track belongs to this tab, else nil.
    -- Colon definition: colon call sites pass the table implicitly.
    if not trackname then return nil end
    if name == "Keys" then
      for k, tn in pairs(PRO_KEYS_TRACKS or {}) do
        if tn == trackname then return k end
      end
    end
    if name == "Vocals" then
      for k, tn in pairs(VOCALS_TRACKS or {}) do
        if tn == trackname then return k end
      end
    end
    if name == "Venue" then
      for k, tn in pairs(VENUE_TRACKS or {}) do
        if tn == trackname then return k end
      end
    end
    if TAB_TRACK and TAB_TRACK[name] == trackname then
      return self:current_mode_key()
    end
    return nil
  end

  function self.listen_tracknames()
    -- Per-tab listen-FX track set (deduplicated).
    local out, seen = {}, {}
    local function add(tn)
      if tn and not seen[tn] then seen[tn] = true; out[#out+1] = tn end
    end
    if name == "Vocals" then
      for _, tn in pairs(VOCALS_TRACKS or {}) do add(tn) end
    elseif name == "Venue" then
      for _, tn in pairs(VENUE_TRACKS or {}) do add(tn) end
    elseif name == "Keys" then
      if not self:is_pro() and TAB_TRACK then add(TAB_TRACK.Keys) end
      for _, tn in pairs(PRO_KEYS_TRACKS or {}) do add(tn) end
    else
      if TAB_TRACK then add(TAB_TRACK[name]) end
    end
    return out
  end

  function self.all_tracknames()
    -- All tracks for this tab across all variants.
    local out, seen = {}, {}
    local function add(tn)
      if tn and not seen[tn] then seen[tn] = true; out[#out+1] = tn end
    end
    if name == "Vocals" then
      for _, tn in pairs(VOCALS_TRACKS or {}) do add(tn) end
    elseif name == "Venue" then
      for _, tn in pairs(VENUE_TRACKS or {}) do add(tn) end
    elseif name == "Keys" then
      if TAB_TRACK then add(TAB_TRACK.Keys) end
      for _, tn in pairs(PRO_KEYS_TRACKS or {}) do add(tn) end
    else
      if TAB_TRACK then add(TAB_TRACK[name]) end
    end
    return out
  end

  function self:handle_difficulty_signal(token)
    -- The tab owns the meaning of the FCP_PREVIEWS difficulty signal.
    if not token then return end

    local reaper = reaper

    if name == "Vocals" then
      local mode_map = { EXPERT="H1", HARD="H2", MEDIUM="H3", EASY="V" }
      local new_mode = mode_map[token]
      if new_mode and self:set_mode(new_mode) ~= new_mode then
        select_and_scroll_track_by_name(VOCALS_TRACKS[new_mode], 40818, 40726)
      end
    elseif name == "Venue" then
      if token == "MEDIUM" or token == "EASY" then
        -- Toggle Sing/Spot on the Venue variant's overlay_toggles
        local toggles = self:current_variant().overlay_toggles
        local toggling_sing = (token == "MEDIUM")
        if toggling_sing then toggles.sing = not toggles.sing
        else                  toggles.spot = not toggles.spot end

        if toggles.sing or toggles.spot then
          local order = (toggles.sing and toggles.spot) and SING_SPOT_NOTE_ORDER
                     or toggles.sing and SING_NOTE_ORDER
                     or SPOT_NOTE_ORDER
          apply_venue_note_order_and_select(order)
        else
          select_and_scroll_track_by_name(VENUE_TRACKS[self:current_mode_key()], 40818, 40726)
          local me = reaper.MIDIEditor_GetActive()
          if me then
            reaper.MIDIEditor_OnCommand(me, 40452)
            reaper.MIDIEditor_OnCommand(me, 40454)
          end
        end
      else
        local mode_map = { EXPERT="Camera", HARD="Lighting" }
        local new_mode = mode_map[token]
        if new_mode then
          local toggles = self:current_variant().overlay_toggles
          toggles.sing = false
          toggles.spot = false
          if self:set_mode(new_mode) ~= new_mode then
            select_and_scroll_track_by_name(VENUE_TRACKS[new_mode], 40818, 40726)
          end
          local me = reaper.MIDIEditor_GetActive()
          if me then
            reaper.MIDIEditor_OnCommand(me, 40452)
            reaper.MIDIEditor_OnCommand(me, 40454)
          end
        end
      end
    else
      -- Map the difficulty/pair-mode tokens for instrument tabs.
      local diff_map = { EXPERT="Expert", HARD="Hard", MEDIUM="Medium", EASY="Easy" }
      local new_diff = diff_map[token]
      if new_diff then
        self:set_mode(new_diff)
        PAIR_MODE = 0
        run_set(token)
        if self:is_pro() then
          select_and_scroll_track_by_name(PRO_KEYS_TRACKS[new_diff], 40818, 40726)
        end
      elseif token == "HOPOS" then
        PAIR_MODE = 1
        run_set("HOPOS")
      elseif token == "TRILLS" then
        PAIR_MODE = 2
        run_set("TRILLS")
      elseif token == "PK_DEFAULT" then
        PAIR_MODE = 0
        run_set("PK_DEFAULT")
      elseif token == "PK_RANGE" then
        PAIR_MODE = 1
        run_set("PK_RANGE")
      elseif token == "PK_TRILL" then
        PAIR_MODE = 2
        run_set("PK_TRILL")
      end
    end
  end

  return self
end

-- Build the thin registry (not named TABS so it doesn't shadow the legacy array).
TABS_BY_NAME = {}
for _, name in ipairs(TABS or {}) do
  TABS_BY_NAME[name] = make_tab_obj(name)
end

-- Lookup helper: returns the thin Tab object for the given name.
-- Returns nil if the tab is not registered.
function tab_for(name)
  return TABS_BY_NAME[name]
end

-- Lookup helper: returns the thin Tab object for the current_tab global.
function current_tab_obj()
  if not current_tab then return nil end
  return TABS_BY_NAME[current_tab]
end

-- Variant key resolution (on-disk "<tab>:<variant>" for Keys, "<tab>" otherwise).

-- Resolve a Tab object or legacy string ("Pro Keys", "Keys") to a variant key.
function variant_key_resolve(tab_input)
  if not tab_input then return nil end
  if type(tab_input) == "table" and tab_input.variant_key then
    return tab_input:variant_key()
  end
  if type(tab_input) == "string" then
    if tab_input == "Pro Keys" then return "Keys:pro" end
    if tab_input == "Keys" then return "Keys:regular" end
    return tab_input
  end
  return nil
end

-- All variant keys in the registry, in display order. Used for the
-- Preferences dropdown.
function all_variant_keys()
  local out = {}
  for _, name in ipairs(TABS or {}) do
    local t = TABS_BY_NAME[name]
    if t and t.variant_key then
      out[#out+1] = t:variant_key()
    end
  end
  return out
end

-- Derive the union of every mode's trackname across every variant of
-- every tab. Used as the all-Listen set.
local _all_listen_cache = nil
function all_listen_tracks()
  if _all_listen_cache then return _all_listen_cache end
  local seen, out = {}, {}
  for _, name in ipairs(TABS or {}) do
    local t = TABS_BY_NAME[name]
    if t and t.listen_tracknames then
      for _, tn in ipairs(t:listen_tracknames()) do
        if not seen[tn] then seen[tn] = true; out[#out+1] = tn end
      end
    end
  end
  _all_listen_cache = out
  return out
end

-- Map a trackname to its tab, variant, and mode; nil if not found.
function infer_tab_for_track(trackname)
  if not trackname then return nil end
  for _, name in ipairs(TABS or {}) do
    local t = TABS_BY_NAME[name]
    if t and t.listen_tracknames then
      for _, tn in ipairs(t:all_tracknames()) do
        if tn == trackname then
          -- Determine variant: if it's a Pro Keys track, variant is "pro"
          local variant = nil
          if name == "Keys" and PRO_KEYS_TRACKS then
            for _, ptn in pairs(PRO_KEYS_TRACKS) do
              if ptn == trackname then variant = "pro"; break end
            end
          end
          -- Determine mode: use matches_track for the mode key
          local mode = t:matches_track(trackname)
          return t, variant, mode
        end
      end
    end
  end
  return nil
end
