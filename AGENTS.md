# AGENTS.md

REAPER ReaScript (Lua + ReaImGui) for the FCP Song Progress Tracker. Single repo, flat layout, no tests, no CI.

## Verification

- There is no automated test runner, linter, or headless REAPER. All verification is manual inside REAPER.
- For openspec proposals, do not list the details of manual smoke check steps. Keep it to one simply-named "Manual Smoke Check" task that's always last after any new additions. Never fill in the X for "Manual Smoke Check" yourself
- Load the script via Actions → "Load ReaScript..." → `fcp_tracker_main.lua` (or via ReaPack once installed). Reload by closing/reopening the script context.
- A full smoke check requires: REAPER 6.0+, **ReaImGui**, **JS_ReaScriptAPI**, **SWS Extension**, and tracks with `RBN Preview` VSTi. Missing any of these will hard-fail (the script calls `ImGui_*` and `JS_Window_*` directly).
- ReaPack is the only release path; there is no separate packaging step.
- All ReaScript API functions are listed in `List of exposed ReaScript API functions.txt`: when adding ReaScript API functions always verify function names against this source of truth. Check the web for function signatures.

## Entry points and module layout

- `fcp_tracker_main.lua` is the only REaPack entry (`@provides` block at top). It is also the only file that creates the ImGui context and runs the driver loop.
- The four `FCP Switch to *.lua` files are also user-facing ReaScripts (bound to shortcuts/toolbar). They are not loaded by `main` — each one writes a single `reaper.SetExtState("FCP_PREVIEWS", "REQUEST", "EXPERT" | "HARD" | "MEDIUM" | "EASY", false)` and the main loop polls that signal in `check_previews_signal` (`fcp_tracker_main.lua:186-279`).
- `fcp_jump_regions.lua` is loaded differently: it is `dofile`'d and its return value is stashed in `FCP_JUMP_REGIONS`. The main loop calls `FCP_JUMP_REGIONS.tick()` and `FCP_JUMP_REGIONS.process_ext_signals()` (`fcp_tracker_main.lua:121, 290-293`). All other modules are loaded by side-effect (they just attach globals).

## Adding or renaming a module

- The load order is hardcoded twice. You must update **both**:
  1. The `@provides` block at the top of `fcp_tracker_main.lua` (used by ReaPack to bundle files).
  2. The `to_load` table in `fcp_tracker_main.lua:98-117` (used by `dofile`).
- `fcp_tracker_config.lua` must remain first — it sets `EXT_NS`, `TABS`, `DIFFS`, `ACTIVE_DIFF`, and many other globals that downstream modules assume exist.
- `fcp_tracker_tabs.lua` must be loaded immediately after `fcp_tracker_config.lua` (and before any module that reads `current_tab`). Its load order is enforced in two places: the `@provides` block and the `to_load` table. The module builds the `TABS_BY_NAME` registry of thin Tab objects whose methods read from the legacy globals.
- Public functions follow PascalCase: `Progress_Init`, `Progress_Tick`, `Progress_UI_Init`, `Progress_UI_Draw`, `Progress_UI_ForceSelectTab`. Internal helpers are snake_case.

## Release process

- Single branch: `main`. No `develop`. Releases are commits to `main` (e.g. `13976ac` "housed my other scripts in separate repos" shows the workflow is direct).
- Never use git commit, git revert, or git reset leave that to the user
- Bumping `SCRIPT_VERSION` in `fcp_tracker_main.lua` **requires** adding a new `<version>` entry in `index.xml` with `<source main="main">.../fcp_tracker_main.lua</source>` and one `<source file="...">` per module. ReaPack will not pick up new code without a new `<version>` block. See the existing 2.0 → 2.2 blocks in `index.xml` for the template.
- The ReaPack index is committed to the same repo. The `<source>` URLs in `index.xml` point at `raw.githubusercontent.com/smcconne/Song-Progress-Tracker/main/...` for head and pinned commit SHAs for older versions — do not rewrite the pinned SHAs by hand.

## State and persistence

- Per-project state goes in two ExtState namespaces:
  - `FCP_SECMAT_V1` (`EXTNAME` in config): progress data, region timer, sigs. Read/written by `fcp_tracker_model_persistence.lua` (`load_all_saved_states`, `SetProjExtState(0, EXTNAME, ...)`).
  - `FCP_PREVIEWS` (`EXT_NS` in config): last tab, last difficulty, pro keys state, FCP_PREVIEWS signal bus, per-action tab-switch preferences (`ACTION_TABS_<id>`, `ACTION_LEAVING_TAB_SET_<id>`).
- Progress is keyed on region name and tab. On-disk format: `<tab>|<mode>|<region_name>` for single-variant tabs (Drums, Bass, Guitar, Vocals, Venue), and `<tab>:<variant>|<mode>|<region_name>` for variant-owning tabs (Keys only today, with `regular` and `pro` variants). Renaming a region in REAPER breaks its saved progress.
- Per-tab project ExtState: `LAST_VARIANT_<TabName>` (e.g. `LAST_VARIANT_Keys`) records the variant that was active when the tab was last exited; restored on re-entry. `LAST_VENUE_OVERLAY_SING` and `LAST_VENUE_OVERLAY_SPOT` record the Venue overlay toggles. The legacy `PRO_KEYS_ACTIVE` and `Pro Keys` keys are no longer read or written.
- REAPER normalizes ExtState keys to uppercase on save, same for Project-level keys. The model's `load_*` and `save_*` helpers in `fcp_tracker_model_persistence.lua` canonicalize the tab and mode segments (via `TAB_CANON` and `DIFF_CANON`) on read, and uppercase the on-disk key on write, so the in-memory `SAVED` / `REGION_TIME` trees use canonical mode keys regardless of REAPER's on-disk shape.

## Hardcoded conventions

- Track names in `fcp_tracker_config.lua` are required verbatim, including the `PART ` prefix and case: `PART DRUMS`, `PART BASS`, `PART GUITAR`, `PART KEYS`, `PART REAL_KEYS_X/H/M/E`, `PART VOCALS`, `HARM1/HARM2/HARM3`, `CAMERA`, `LIGHTING`. `TRACK_TO_TAB` and `TAB_TRACK` map these to tabs — if a user renames tracks, auto-switch by track selection (`fcp_tracker_util_tracks.lua`) silently breaks.
- Tabs order is fixed: `{"Preferences","Setup","Drums","Bass","Guitar","Keys","Vocals","Venue","Overdrive"}`. The first entry is the fallback when an unknown tab is restored.
- The startup screenset commands are hardcoded REAPER action IDs in `fcp_tracker_main.lua:308-319`: 40454 (#01), 40455 (#02), 40456 (#03), 40458 (#05). Setup/Preferences deliberately skip screenset loading.
- The first 3 frames of the loop are a "startup mode" that defers screenset + FX alignment + tab-switch action runs so the ImGui window has time to lay out (`FCP_STARTUP_MODE` global, `fcp_tracker_main.lua:144, 183, 366`). Any side effect added to a tab switch must respect this flag — see `fcp_tracker_ui.lua` for the existing pattern.

## Rules to follow
- Do not attempt to support backwards-compatibility with legacy versions of the software - no safety net.
- Check `List of exposed ReaScript API functions.txt` for any new ReaScript functions you want to use (don't just guess, search for the name), if unsure research the best candidates at https://www.extremraym.com/cloud/reascript-doc/#l_funcs for correct function bodies, big but searchable: contains ReaImGui, JS_ReaScriptAPI, SWS/BS, and Lua-native function bodies.

## Architecture quirks

- Modules share a single global scope; they do **not** use Lua modules. Cross-module state lives in globals: `current_tab`, `ACTIVE_DIFF`, `PRO_KEYS_ACTIVE`, `PAIR_MODE`, `VOCALS_MODE`, `VENUE_MODE`, `SING_ACTIVE`, `SPOT_ACTIVE`, `VOCALS_NOTE_START`, `FCP_CTX`, `FCP_STARTUP_MODE`, `PROJECT_SWITCH_MODE`. Adding new state does not require plumbing — just assign it where it makes sense and read it elsewhere.
- ImGui context is created exactly once in `fcp_tracker_main.lua:126-129` with `ImGui_ConfigFlags_DockingEnable`. There is one `FCP_CTX` global. Do not create another context.
- The main loop (`fcp_tracker_main.lua:282-373`) is a single `reaper.defer` chain. It calls, in order: `check_previews_signal`, `loop_tick` (focus + FX alignment driver from `fcp_tracker_focus.lua`), `FCP_JUMP_REGIONS.tick/.process_ext_signals`, `Progress_Tick`, `Progress_UI_Draw`, `check_pending_region_refresh`. New per-frame work goes in the right spot relative to these.
- Screenset/FX/MIDI-editor side effects on tab switch are centralized in `run_actions_on_tab_switch` and helpers in `fcp_tracker_util_tracks.lua` and `fcp_tracker_ui_table_prefs.lua`. Prefer extending those over scattering new "do X on tab change" code.
- Changing screensets does not change track selection

## Tab model

- The `TABS_BY_NAME` registry in `fcp_tracker_tabs.lua` is a dict of thin Tab objects keyed by tab name. Each tab has a `name`, a `variants` collection (only Keys has more than one today: `regular` and `pro`), and a `current_variant_key`.
- `current_tab` is a Tab object, not a string. Use `current_tab.name` for the string, `current_tab:variant_key()` for the canonical per-tab key (e.g. `"Drums"`, `"Keys:pro"`), and `current_tab:is_pro()` to test the Pro variant.
- A tab has variants; a variant has modes. The variant is owned by the tab; the mode is owned by the variant. Variants and modes are never read across tabs.
- `current_tab:current_mode().key` returns the active mode key for the active variant. For instrument tabs this is the active difficulty (`Expert`/`Hard`/`Medium`/`Easy`); for Vocals it is `H1`/`H2`/`H3`/`V`; for Venue it is `Camera`/`Lighting`.
- `current_tab:listen_tracknames()` returns the deduplicated set of tracknames that should have listen-FX enabled for this tab. It iterates the active variant's modes' `trackname`s.
- `current_tab:handle_difficulty_signal(token)` is the per-tab FCP_PREVIEWS receiver. The tab owns the meaning of `EXPERT` in its context.
- `apply_tab_change(old_tab, new_tab)` is the single entry point for tab-identity or variant-change side effects. It is idempotent on equal `(name, variant)` tuples.
- `set_active_tab(name, variant_or_nil, mode_or_nil)` is the single entry point for changing the active tab. Direct mutation of `current_tab` from outside this function is forbidden.
- The `force_select_tab` mechanism (`fcp_tracker_ui_tabs.lua`) is for ImGui state only; it is not a side-effect dispatcher.
- Per-tab preferences (`SHOW_FLOAT_FX_<tab>`, `MIDI_EDITOR_OPEN_<tab>`, `JUST_FX_*_<tab>`, `ACTION_TABS_*` lists) are keyed by `tab:variant_key()`. The `variant_key_resolve()` helper in `fcp_tracker_tabs.lua` accepts either a string or a Tab object and returns the canonical key. The preference helpers in `fcp_tracker_ui_table_prefs.lua` also fall back to legacy keys (`SHOW_FLOAT_FX_Pro Keys`, etc.) on miss.
- The Tab object owns the variant and the mode (canonical Expert/Hard/Medium/Easy for instruments+Keys, H1/H2/H3/V for Vocals, Camera/Lighting for Venue). The X/H/M/E form is used only at the PRO_KEYS_TRACKS lookup and the Pro Keys difficulty button labels. The five data trees (`PROGRESS`, `STATE`, `SAVED`, `PROGRESS_SIG`, `COMPLETE_SIG`) are unified and keyed by `<tab>.<variant>.<mode>` (single-variant tabs use the `regular` variant). The legacy parallel Pro Keys data trees (`PROGRESS_PRO_KEYS`, `STATE_PRO_KEYS`, etc.) do not exist.
- Storage key format: `<tab>:<variant>|<mode>|<region_name>` for variant-owning tabs (Keys only today); `<tab>|<mode>|<region_name>` for single-variant tabs. The `storage_key_for()` helper and the `migrate_fcp_secmat_v1()` walker in `fcp_tracker_model_persistence.lua` handle the new shape.
- Adding a new variant (e.g. Pro Guitar, Pro Bass) is a single `register_tab` call with the variant def. No new globals, no new files.

## Lua comment rules

- Comments must be no more than one or two consecutive lines except the top-of-file comment header.
- Curtly get the gist across of what the very next line of code does.
- An outside observer doesn't care to read what our wider goals are. Limit comments to just summarize the immediate code. Do not refer to proposal numbers or outside behaviour in comments.
- Comments are necessary before functions, and long functions also need a comment before each distinct code block. Do not leave comments on self-explanatory lines, save them for key areas that are especially convoluted to parse.

## Conventions that differ from defaults

- Prioritize retrieval-led reasoning over pretrained-knowledge-led reasoning. Use skills, preferably in parallel.
- There is no error guardrail. The script will `MB()` (modal message box via `reaper.MB`) on real failures — see `mb()` in `fcp_tracker_config.lua:152`. Do not add silent fallbacks; do not wrap in pcall and swallow.
- New tracks, screensets, and other REAPER-side state are expected to exist. Don't auto-create tracks or templates from the script.
- Prefer to use encapsulation, abstraction or polymorphism to consolidate, and make reusable functions or objects. Suggest refactor opportunities.

## Files to leave alone

- `List of exposed ReaScript API functions.txt` is a REAPER-generated dump of the user's installed API, not project content. Reference it as needed. Do not change it.
- `index.xml` is the release manifest — Do not edit unless explicitly asked.