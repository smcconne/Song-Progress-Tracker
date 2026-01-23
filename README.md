# Song Progress Tracker

A comprehensive song progress tracking tool for Rock Band 3 custom song authors using REAPER. This all-in-one ImGui-based interface streamlines the charting workflow with intelligent context switching, automatic FX window management, and visual progress tracking across all instruments and difficulties.

## Features

### 🎵 Multi-Tab Instrument Workflow

The tracker organizes your work into logical tabs:

- **Setup** - Configuration and Practice Section (PRC) event insertion tool
- **Drums** - Track progress for PART DRUMS
- **Bass** - Track progress for PART BASS  
- **Guitar** - Track progress for PART GUITAR
- **Keys** - Track progress for PART KEYS (with Pro Keys support)
- **Vocals** - Track progress for PART VOCALS and HARM1/HARM2/HARM3
- **Venue** - Track progress for CAMERA and LIGHTING tracks
- **Overdrive** - Visual overview of overdrive phrase placement across all instruments

### 📊 Region-Based Progress Tracking

- Automatically detects project regions and displays them as columns
- Color-coded progress cells match region colors from your project
- Three-state progress tracking per cell:
  - **Red** - Not Started
  - **Yellow** - In Progress  
  - **Green** - Complete
  - **Gray** - Empty (no notes in this region for this difficulty)
- Click cells to cycle through states; right-click difficulty (or track-toggle) buttons to batch-cycle all cells
- Progress data is saved per-project and persists across sessions

### 🎚️ Difficulty Management

Switch between difficulties with a single click:

- **Expert / Hard / Medium / Easy** buttons for instrument tabs
- Changing difficulty automatically:
  - Updates RBN Preview FX presets to show correct note lanes
  - Adjusts inline MIDI editor note row visibility via CUSTOM_NOTE_ORDER
  - Updates the progress table to show completion for that difficulty

### 🎹 Pro Keys Support

- Toggle **Pro Keys** mode on the Keys tab
- Tracks per-difficulty progress for PART REAL_KEYS_X/H/M/E
- Automatically opens the appropriate Pro Keys track in the MIDI editor
- Separate progress state saved independently from standard Keys

### 🎤 Vocals Sub-Modes

- Switch between **V** (Lead Vocals), **H1**, **H2**, **H3** (Harmonies)
- Each harmony track has independent progress tracking
- **MIDI FX** toggle button to enable/disable MIDI FX on the current vocals track
- Any modifier (Ctrl/Shift/Alt) + click toggles all harmony MIDI FX at once

### 🎬 Venue Sub-Modes

- Switch between **Camera** and **Lighting** tracks
- Independent progress tracking for each venue track

### 🔊 Overdrive Visualization Tab

A unique bird's-eye view of overdrive phrase placement:

- Displays all measures of the song horizontally
- Four rows for Drums, Bass, Guitar, and Keys
- **Yellow cells** indicate measures with overdrive phrases
- **Brightness** indicates note density (adjustable via slider)
- **Gray rectangles** show playable notes (toggleable)
- **Red cells** mark invalid overdrive phrases (no notes under phrase)
- Click to place/entend/erase overdrive phrases
- Minimap scrollbar for quick navigation through long songs
- Fast-scroll when hovering over the minimap

### 🪟 Automatic FX Window Management

- **Align** button tiles all four RBN Preview FX windows horizontally
- **FX** toggle button shows/hides all floating FX windows at once
- Geometry is saved and restored between sessions
- Intelligent focus management redirects keyboard focus back to MIDI editor after UI interactions

### 📐 Screenset Integration

Uses REAPER screensets 1-5 for quick context switching:

- **Screenset 1** - Instrument tabs (5-lane view with FX windows)
- **Screenset 2** - Vocals tab layout
- **Screenset 3** - Overdrive tab layout
- **Screenset 4** - Venue tab layout
- **Screenset 5** - Pro Keys tab layout

**Save Screenset** button saves the current window layout to the appropriate screenset. Screensets auto-load when switching between tab categories.

### 🔧 Setup Tab - PRC Events Tool

Comprehensive Practice Section (PRC) event insertion tool:

- Insert `[prc_*]` text events at region boundaries
- Smart dropdowns show only valid PRC token combinations
- Whitelist of allowed tokens from official RB3 documentation
- Batch operations for adding events to multiple regions
- Preview and validation before insertion

### 🎯 Smart Track Selection

- Selecting a track in REAPER automatically switches to the corresponding tab
- Tab switches automatically select and scroll to the relevant track
- Works with inline MIDI editors and floating MIDI editor windows

### ⌨️ Workflow Features

- **Paint mode - update progress** - Left click and drag across right-column cells to batch-update progress
- **Paint mode - region time select** - Right click and drag across left-column cells to change the time selection to span across regions under the mouse
- **Playhead following** - Current region is highlighted in the table
- **Center on tab switch** - Automatically centers view on current region
- **Docking support** - Window can be docked in REAPER's docker

## Requirements

- **REAPER** v6.0+ with ReaImGui extension installed
- **JS_ReaScriptAPI** extension for window management
- **RBN Preview VSTi** for instrument preview functionality
- **SWS Extension** required for additional features

## Installation

### Via ReaPack (Recommended)

1. Install [ReaPack](https://reapack.com/) if you haven't already
2. In REAPER, go to Extensions → ReaPack → Import repositories...
3. Paste this URL:
   ```
   https://raw.githubusercontent.com/smcconne/Song-Progress-Tracker/main/index.xml
   ```
4. Go to Extensions → ReaPack → Browse packages
5. Search for "Song Progress Tracker" and install
6. Updates will be available automatically via Extensions → ReaPack → Synchronize packages

### Manual Installation

1. Copy all `fcp_tracker_*.lua` files to your REAPER Scripts folder
2. In REAPER, go to Actions → Show action list
3. Click "New action..." → "Load ReaScript..."
4. Select `fcp_tracker_main.lua`
5. Assign a keyboard shortcut or toolbar button as desired

## File Structure

| File | Purpose |
|------|---------|
| `fcp_tracker_main.lua` | Entry point, initialization, main loop |
| `fcp_tracker_config.lua` | Configuration constants and shared settings |
| `fcp_tracker_model.lua` | Data model, MIDI scanning, persistence |
| `fcp_tracker_ui.lua` | Main UI coordinator |
| `fcp_tracker_ui_tabs.lua` | Tab bar rendering and switching |
| `fcp_tracker_ui_header.lua` | Difficulty buttons and mode switches |
| `fcp_tracker_ui_table.lua` | Region table and overdrive table rendering |
| `fcp_tracker_ui_widgets.lua` | Reusable UI components |
| `fcp_tracker_ui_helpers.lua` | UI utility functions |
| `fcp_tracker_ui_track_utils.lua` | Track selection and scrolling helpers |
| `fcp_tracker_ui_dock.lua` | Docking height control |
| `fcp_tracker_ui_setup.lua` | Setup tab with PRC events tool |
| `fcp_tracker_focus.lua` | Focus management and driver loop |
| `fcp_tracker_layout.lua` | FX window tiling and positioning |
| `fcp_tracker_templates.lua` | Inline FX templates for difficulty switching |
| `fcp_tracker_chunk_parse.lua` | Track chunk parsing utilities |
| `fcp_tracker_fxchain_geom.lua` | FX chain geometry handling |
| `fcp_tracker_util_fs.lua` | File system utilities |
| `fcp_tracker_util_selection.lua` | Selection snapshot/restore |
| `fcp_jump_regions.lua` | Jump Regions navigation window |

## Usage Tips

1. **Add events and audio** 
2. **Create regions** - Create regions for each song section (Intro, Verse, Chorus, etc.) for granular progress tracking
1. **Set up screensets** - Arrange your windows as desired for each tab category, then use the screenset save buttons and these layouts will be recalled automatically when changing tabs.
3. **Right-click for batch operations** - Right-click the difficulty (or track-toggle) buttons to cycle all progress cells (useful for old projects)
4. **Hover over buttons for charting tips** - Hover over difficulty buttons for charting recommendations specific to each instrument
4. **Switch on Pro toggle for Pro Keys** - Pro Keys progress tracked separately from standard Keys charting
5. **Create overdrive and drum fills** - Overdrive tab tracks locations of overdrive phrases and drum fills. Left click to place overdrive have notes underneath

## License

This project is provided as-is for the Rock Band custom song authoring community.

## Credits

Developed by FinestCardboardPearls for the Rock Band 3 custom song community.