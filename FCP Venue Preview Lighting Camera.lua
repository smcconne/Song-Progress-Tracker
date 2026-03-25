-- Show LIGHTING, CAMERA, VENUE track MIDI notes at cursor
-- Displays custom note names of all MIDI notes at the edit cursor (or play cursor while playing)
-- Uses ReaImGui for real-time updating display

-- Get script directory
local function GetScriptDir()
    local info = debug.getinfo(1, "S")
    local path = info and info.source or ""
    path = path:gsub("^@", "")
    return path:match("^(.*[\\/])") or "./"
end

local SCRIPT_DIR = GetScriptDir()
local SPRITESHEET_DIRS = {
    Camera = SCRIPT_DIR .. "Spritesheets/Camera/",
    Lighting = SCRIPT_DIR .. "Spritesheets/Lighting/",
    PostProc = SCRIPT_DIR .. "Spritesheets/PostProc/",
}

local ctx = reaper.ImGui_CreateContext("Venue Preview")

-- Sprite sheet animation settings
local SPRITE_COLS = 8
local SPRITE_ROWS = 9
local SPRITE_FRAME_RATE = 30  -- frames per second
local SPRITE_DISPLAY_W = 213
local SPRITE_DISPLAY_H = 120
local SPRITE_BORDER = 1  -- 1px border around each frame

-- Cache for loaded spritesheets: { [category] = { [normalized_name] = { image = ImGui_Image, frame_count = number, path = string } } }
local spritesheet_cache = {}
-- Track start times for each note's spritesheet animation: { [normalized_name] = start_time }
local sprite_start_times = {}
-- Track which notes were active last frame to detect when to reset
local last_active_notes = {}
-- Track which notes are active this frame
local current_active_notes = {}

-- Instrument mode: "GB" (no keys), "KB" (no guitar), "GK" (no bass)
local instrument_mode = "GB"

-- Track camera fallback selection (for filtered notes)
local camera_fallback_name = nil
local camera_fallback_for_note = nil  -- Which filtered note name this fallback is for

-- Manual lighting state (for pitches 34-40: Verse, Chorus, Manual_Cool, Manual_Warm, Dischord, Stomp)
-- State: false = OFF (show frame 0), true = ON (show last frame)
local manual_light_state = false
-- Track the toggle time in project time (when the prev/next note starts)
local manual_light_toggle_time = nil
-- Track current cursor position for animation calculation
local manual_light_cursor_pos = 0
-- Track whether we're animating forward (to ON) or reverse (to OFF)
local manual_light_animating_forward = false
-- Skip animation and jump directly to target frame (when manual light starts with toggle)
local manual_light_skip_animation = false
-- Manual lighting pitches
local MANUAL_LIGHT_PITCHES = { [34] = true, [35] = true, [36] = true, [37] = true, [38] = true, [39] = true, [40] = true }
-- Prev/Next pitches (toggle manual light)
local PREV_NEXT_PITCHES = { [30] = true, [31] = true }
-- First pitch (forces manual light off)
local FIRST_PITCH = 32
-- Post-processing Default pitch
local POSTPROC_DEFAULT_PITCH = 71
-- Post-processing pitch range
local POSTPROC_PITCH_MIN = 41
local POSTPROC_PITCH_MAX = 71

-- Directed cuts: target frame table ("x" means repeating like normal cut but still blocks)
-- Maps normalized note name (post-sanitization, matches spritesheet name minus _spritesheet.png) to target frame (1-indexed)
local DIRECTED_CUTS_TARGET_FRAMES = {
    ["dall"] = 19,
    ["dallcam"] = 52,
    ["dalllt"] = "x",
    ["dallyeah"] = 56,
    ["dbass"] = 33,
    ["dbasscam"] = 49,
    ["dbasscls"] = "x",
    ["dbassnp"] = 16,
    ["dbre"] = 174,
    ["dcrowd"] = 1,
    ["dcrowdbass"] = 43,
    ["dcrowdgtr"] = 65,
    ["dcrowdsurf"] = 38,
    ["ddrums"] = 18,
    ["ddrumskd"] = "x",
    ["ddrumslt"] = "x",
    ["ddrumsnp"] = 48,
    ["ddrumspoint"] = 23,
    ["dduobass"] = 1,
    ["dduodrums"] = 26,
    ["dduogb"] = 3,
    ["dduogtr"] = 33,
    ["dduokb"] = 1,
    ["dduokg"] = 1,
    ["dduokv"] = 17,
    ["dgtr"] = 32,
    ["dgtrcampr"] = 53,
    ["dgtrcampt"] = 15,
    ["dgtrcls"] = "x",
    ["dgtrnp"] = 43,
    ["dkeys"] = 25,
    ["dkeyscam"] = 3,
    ["dkeysnp"] = 1,
    ["dstagedive"] = 17,
    ["dvocals"] = 22,
    ["dvoxcampr"] = 28,
    ["dvoxcampt"] = 28,
    ["dvoxcls"] = 1,
    ["dvoxnp"] = 50,
}

-- State for currently playing directed cut
local directed_cut_active = false
local directed_cut_name = nil
local directed_cut_note_start = nil
local directed_cut_note_end = nil
local directed_cut_frame_count = nil
local directed_cut_started_playing_at_frame = nil  -- The frame number at which playback started
local directed_cut_is_repeating = false  -- True if target is "x" (repeats like normal)

-- Detect first all-black frame using JS_ReaScriptAPI (JS_LICE)
-- Returns the frame index of the first all-black frame, or total frames if none found
local function DetectBlackFrameCount(spritesheet_path)
    -- Check if JS_ReaScriptAPI is available (required)
    if not reaper.JS_LICE_LoadPNG then
        return SPRITE_COLS * SPRITE_ROWS  -- Fallback to default if JS API not available
    end
    
    -- Load the spritesheet with JS_LICE
    local bitmap = reaper.JS_LICE_LoadPNG(spritesheet_path)
    if not bitmap then
        return SPRITE_COLS * SPRITE_ROWS  -- Fallback to default if load fails
    end
    
    local img_w = reaper.JS_LICE_GetWidth(bitmap)
    local img_h = reaper.JS_LICE_GetHeight(bitmap)
    -- Each tile in spritesheet is frame size + border on each side
    local tile_w = SPRITE_DISPLAY_W + SPRITE_BORDER * 2
    local tile_h = SPRITE_DISPLAY_H + SPRITE_BORDER * 2
    
    -- Calculate actual rows/cols from image dimensions (not hardcoded)
    local actual_cols = math.floor(img_w / tile_w)
    local actual_rows = math.floor(img_h / tile_h)
    local total_frames = actual_cols * actual_rows
    
    local first_black_frame = total_frames
    
    for frame = 0, total_frames - 1 do
        local col = frame % actual_cols
        local row = math.floor(frame / actual_cols)
        local start_x = col * tile_w
        local start_y = row * tile_h
        
        local is_all_black = true
        
        -- Sample pixels in this frame, skipping the 1px border (check every 8th pixel for accuracy)
        -- Using 8px interval instead of 16px to avoid missing non-black content in dark frames
        for y = start_y + SPRITE_BORDER, start_y + tile_h - 1 - SPRITE_BORDER, 8 do
            for x = start_x + SPRITE_BORDER, start_x + tile_w - 1 - SPRITE_BORDER, 8 do
                -- JS_LICE_GetPixel returns color as 0xAARRGGBB
                local color = reaper.JS_LICE_GetPixel(bitmap, x, y)
                
                -- Extract RGB components (format is 0xAARRGGBB)
                local r = (color >> 16) & 0xFF
                local g = (color >> 8) & 0xFF
                local b = color & 0xFF
                
                -- Check if pixel is black (or near-black, threshold 5)
                if r > 5 or g > 5 or b > 5 then
                    is_all_black = false
                    break
                end
            end
            if not is_all_black then break end
        end
        
        if is_all_black then
            first_black_frame = frame
            break
        end
    end
    
    -- Clean up the bitmap
    reaper.JS_LICE_DestroyBitmap(bitmap)
    
    return first_black_frame, actual_cols
end

-- Normalize a note name for spritesheet file matching (strip underscores, spaces, and * symbols, lowercase)
local function NormalizeNoteNameForFile(name)
    local normalized = name:gsub("[_ ]", ""):gsub("%*", "")
    return normalized:lower()
end

-- Check if a note name is a directed cut and return its target frame (or nil if not a directed cut)
local function GetDirectedCutTargetFrame(note_name)
    local normalized = NormalizeNoteNameForFile(note_name)
    return DIRECTED_CUTS_TARGET_FRAMES[normalized]
end

-- Check if a note is a directed cut
local function IsDirectedCut(note_name)
    return GetDirectedCutTargetFrame(note_name) ~= nil
end

-- Normalize a note name for priority lookup and filtering (replace _ with space, strip * symbols, lowercase)
local function NormalizeNoteName(name)
    local normalized = name:gsub("_", " "):gsub("%*", "")
    return normalized:lower()
end

-- Find a spritesheet file matching the note name (case-insensitive)
local function FindSpritesheet(category, note_name)
    local normalized = NormalizeNoteNameForFile(note_name)
    
    -- Initialize category cache if needed
    if not spritesheet_cache[category] then
        spritesheet_cache[category] = {}
    end
    
    -- Check cache first (use rawget to distinguish between nil and false)
    local cached = spritesheet_cache[category][normalized]
    if cached ~= nil then
        return cached  -- Return cached result (could be table or false)
    end
    
    -- Get directory for this category
    local dir = SPRITESHEET_DIRS[category]
    if not dir then
        spritesheet_cache[category][normalized] = false
        return false
    end
    
    -- Search directory for matching file
    local i = 0
    repeat
        local file = reaper.EnumerateFiles(dir, i)
        if file then
            -- Check if it's a _spritesheet.png file and matches (case-insensitive)
            if file:lower():match("_spritesheet%.png$") then
                local file_base = file:sub(1, -17)  -- Remove _spritesheet.png extension
                -- Normalize file_base the same way as note names
                local file_normalized = NormalizeNoteNameForFile(file_base)
                if file_normalized == normalized then
                    local full_path = dir .. file
                    local image = reaper.ImGui_CreateImage(full_path)
                    if image then
                        -- Attach image to context to prevent garbage collection
                        reaper.ImGui_Attach(ctx, image)
                        local frame_count, actual_cols = DetectBlackFrameCount(full_path)
                        spritesheet_cache[category][normalized] = {
                            image = image,
                            frame_count = frame_count,
                            cols = actual_cols or SPRITE_COLS,
                            path = full_path
                        }
                        return spritesheet_cache[category][normalized]
                    end
                end
            end
        end
        i = i + 1
    until not file
    
    -- Mark as not found to avoid repeated searches
    spritesheet_cache[category][normalized] = false
    return false
end

-- Draw a spritesheet at a specific frame (for directed cuts)
local function DrawSpritesheetAtFrame(spritesheet_data, currentFrame)
    if not spritesheet_data or not spritesheet_data.image then return end
    
    local image = spritesheet_data.image
    local cols = spritesheet_data.cols or SPRITE_COLS
    
    if not reaper.ImGui_ValidatePtr(image, "ImGui_Image*") then return end
    
    local img_w, img_h = reaper.ImGui_Image_GetSize(image)
    local tile_w = SPRITE_DISPLAY_W + SPRITE_BORDER * 2
    local tile_h = SPRITE_DISPLAY_H + SPRITE_BORDER * 2
    
    local col = currentFrame % cols
    local row = math.floor(currentFrame / cols)
    
    local uv0_x = (col * tile_w + SPRITE_BORDER) / img_w
    local uv0_y = (row * tile_h + SPRITE_BORDER) / img_h
    local uv1_x = ((col + 1) * tile_w - SPRITE_BORDER) / img_w
    local uv1_y = ((row + 1) * tile_h - SPRITE_BORDER) / img_h
    
    reaper.ImGui_Image(ctx, image, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H, uv0_x, uv0_y, uv1_x, uv1_y)
end

-- Draw a camera spritesheet animation
local function DrawCameraSpritesheet(spritesheet_data, note_name)
    if not spritesheet_data or not spritesheet_data.image then return end
    
    local image = spritesheet_data.image
    local frame_count = spritesheet_data.frame_count or (SPRITE_COLS * SPRITE_ROWS)
    local cols = spritesheet_data.cols or SPRITE_COLS
    
    if not reaper.ImGui_ValidatePtr(image, "ImGui_Image*") then return end
    
    local normalized = NormalizeNoteNameForFile(note_name)
    
    -- Mark this note as active this frame
    current_active_notes[normalized] = true
    
    -- Check if this note just became active (wasn't active last frame)
    if not last_active_notes[normalized] then
        sprite_start_times[normalized] = reaper.time_precise()
    end
    
    local start_time = sprite_start_times[normalized] or reaper.time_precise()
    local elapsed = reaper.time_precise() - start_time
    local current_frame = math.floor(elapsed * SPRITE_FRAME_RATE) % frame_count
    
    local img_w, img_h = reaper.ImGui_Image_GetSize(image)
    local tile_w = SPRITE_DISPLAY_W + SPRITE_BORDER * 2
    local tile_h = SPRITE_DISPLAY_H + SPRITE_BORDER * 2
    
    local col = current_frame % cols
    local row = math.floor(current_frame / cols)
    
    local uv0_x = (col * tile_w + SPRITE_BORDER) / img_w
    local uv0_y = (row * tile_h + SPRITE_BORDER) / img_h
    local uv1_x = ((col + 1) * tile_w - SPRITE_BORDER) / img_w
    local uv1_y = ((row + 1) * tile_h - SPRITE_BORDER) / img_h
    
    reaper.ImGui_Image(ctx, image, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H, uv0_x, uv0_y, uv1_x, uv1_y)
end

-- Draw a camera spritesheet animation with opacity (0.0 = transparent, 1.0 = opaque)
local function DrawCameraSpritesheetWithOpacity(spritesheet_data, note_name, opacity)
    if not spritesheet_data or not spritesheet_data.image then return end
    if opacity <= 0 then return end  -- Don't draw if fully transparent
    
    local image = spritesheet_data.image
    local frame_count = spritesheet_data.frame_count or (SPRITE_COLS * SPRITE_ROWS)
    local cols = spritesheet_data.cols or SPRITE_COLS
    
    if not reaper.ImGui_ValidatePtr(image, "ImGui_Image*") then return end
    
    local normalized = NormalizeNoteNameForFile(note_name)
    
    -- Mark this note as active this frame
    current_active_notes[normalized] = true
    
    -- Check if this note just became active (wasn't active last frame)
    if not last_active_notes[normalized] then
        sprite_start_times[normalized] = reaper.time_precise()
    end
    
    local start_time = sprite_start_times[normalized] or reaper.time_precise()
    local elapsed = reaper.time_precise() - start_time
    local current_frame = math.floor(elapsed * SPRITE_FRAME_RATE) % frame_count
    
    local img_w, img_h = reaper.ImGui_Image_GetSize(image)
    local tile_w = SPRITE_DISPLAY_W + SPRITE_BORDER * 2
    local tile_h = SPRITE_DISPLAY_H + SPRITE_BORDER * 2
    
    local col = current_frame % cols
    local row = math.floor(current_frame / cols)
    
    local uv0_x = (col * tile_w + SPRITE_BORDER) / img_w
    local uv0_y = (row * tile_h + SPRITE_BORDER) / img_h
    local uv1_x = ((col + 1) * tile_w - SPRITE_BORDER) / img_w
    local uv1_y = ((row + 1) * tile_h - SPRITE_BORDER) / img_h
    
    -- Use DrawList to draw image with tint/opacity
    -- Get current cursor position for drawing
    local cursor_x, cursor_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    
    -- Create tint color with opacity (RGBA format: 0xRRGGBBAA)
    local alpha = math.floor(opacity * 255)
    local tint_col = 0xFFFFFF00 | alpha  -- White with variable alpha
    
    -- Draw image using DrawList (supports color/tint)
    reaper.ImGui_DrawList_AddImage(draw_list, image, 
        cursor_x, cursor_y,
        cursor_x + SPRITE_DISPLAY_W, cursor_y + SPRITE_DISPLAY_H,
        uv0_x, uv0_y, uv1_x, uv1_y,
        tint_col)
    
    -- Reserve space in the layout (since DrawList draws don't advance cursor)
    reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
end

-- Camera shot priority table (higher number = higher priority)
-- Priority groups: 1-10 = four char, 11-20 = three char, 21-40 = one char standard,
-- 41-60 = one char closeup, 61-80 = two char, 81-100 = keys (special), 101+ = directed
local CAMERA_PRIORITY = {
    -- FOUR CHARACTER SHOTS (lowest priority: 1-10)
    ["all behind"] = 1,
    ["all far"] = 2,
    ["all near"] = 3,
    
    -- THREE CHARACTERS / NO DRUMS (11-20)
    ["front behind"] = 11,
    ["front near"] = 12,
    
    -- ONE CHARACTER STANDARD SHOTS (21-40)
    -- Drums and vocals are lower priority within this group
    ["d behind"] = 21,
    ["d near"] = 22,
    ["v behind"] = 23,
    ["v near"] = 24,
    ["b behind"] = 31,
    ["b near"] = 32,
    ["g behind"] = 33,
    ["g near"] = 34,
    ["k behind"] = 35,
    ["k near"] = 36,
    
    -- ONE CHARACTER CLOSEUP SHOTS (41-60)
    -- Drums and vocals are lower priority within this group
    ["d hand"] = 41,
    ["d head"] = 42,
    ["v closeup"] = 43,
    ["b hand"] = 51,
    ["b head"] = 52,
    ["g head"] = 53,
    ["g hand"] = 54,
    ["k hand"] = 55,
    ["k head"] = 56,
    
    -- TWO CHARACTER SHOTS (61-80)
    -- Shots with drums/vocals are lower priority
    ["dv near"] = 61,
    ["bd near"] = 62,
    ["dg near"] = 63,
    ["bv behind"] = 64,
    ["bv near"] = 65,
    ["gv behind"] = 66,
    ["gv near"] = 67,
    ["kv behind"] = 68,
    ["kv near"] = 69,
    ["bg behind"] = 71,
    ["bg near"] = 72,
    ["bk behind"] = 73,
    ["bk near"] = 74,
    ["gk behind"] = 75,
    ["gk near"] = 76,
    
    -- DIRECTED SHOTS - FULL BAND / CROWD (101-120)
    ["d all"] = 101,
    ["d all cam"] = 102,
    ["d all yeah"] = 103,
    ["d all lt"] = 104,
    ["d bre"] = 105,
    ["d bre jump"] = 106,
    ["d crowd"] = 107,
    
    -- DIRECTED SHOTS - SINGLE CHARACTER (121-160)
    ["d drums"] = 121,
    ["d drums-point"] = 122,
    ["d drums np"] = 123,
    ["d drums lt"] = 124,
    ["d drums kd"] = 125,
    ["d vocals"] = 131,
    ["d vox np"] = 132,
    ["d vox cls"] = 133,
    ["d vox cam pr"] = 134,
    ["d vox cam pt"] = 135,
    ["d stagedive"] = 136,
    ["d crowdsurf"] = 137,
    ["d bass"] = 141,
    ["d crowd bass"] = 142,
    ["d bass np"] = 143,
    ["d bass cam"] = 144,
    ["d bass cls"] = 145,
    ["d gtr"] = 151,
    ["d crowd gtr"] = 152,
    ["d gtr np"] = 153,
    ["d gtr cls"] = 154,
    ["d gtr cam pr"] = 155,
    ["d gtr cam pt"] = 156,
    ["d keys"] = 161,
    ["d keys cam"] = 162,
    ["d keys np"] = 163,
    
    -- DIRECTED SHOTS - TWO CHARACTER (171-190)
    ["d duo drums"] = 171,
    ["d duo gtr"] = 172,
    ["d duo bass"] = 173,
    ["d duo kv"] = 174,
    ["d duo gb"] = 175,
    ["d duo kb"] = 176,
    ["d duo kg"] = 177,
}

-- Get camera shot priority (higher = more specific/important)
local function GetCameraPriority(note_name)
    local normalized = NormalizeNoteName(note_name)
    return CAMERA_PRIORITY[normalized] or 0
end

-- Check if a camera note should be hidden based on a specific instrument mode
-- Returns true if the note should be HIDDEN
-- mode parameter: "GB", "KB", or "GK"
local function ShouldHideCameraNoteForMode(note_name, mode)
    local normalized = NormalizeNoteName(note_name)
    
    -- Extract the first part of the name (before space) to check character codes
    local prefix = normalized:match("^(%S+)") or ""
    
    -- Check for directed shots first (these start with "d ")
    if normalized:match("^d ") then
        if mode == "GB" then
            -- No keyboardist - hide keys directed shots
            if normalized:match("^d keys") then return true end
            if normalized:match("^d duo kv") or normalized:match("^d duo kb") or normalized:match("^d duo kg") then return true end
        elseif mode == "KB" then
            -- No guitarist - hide guitar directed shots
            if normalized:match("^d gtr") or normalized:match("^d crowd gtr") then return true end
            if normalized:match("^d duo gtr") or normalized:match("^d duo gb") or normalized:match("^d duo kg") then return true end
        elseif mode == "GK" then
            -- No bassist - hide bass directed shots
            if normalized:match("^d bass") or normalized:match("^d crowd bass") then return true end
            if normalized:match("^d duo bass") or normalized:match("^d duo gb") or normalized:match("^d duo kb") then return true end
        end
        return false
    end
    
    -- For standard shots, check if the excluded instrument letter appears in the prefix
    -- Single char shots: b, g, k, d, v followed by space (e.g., "b near", "g head")
    -- Two char shots: bd, bg, bk, bv, dg, dv, gk, gv, kv followed by space (e.g., "bg near", "dg near")
    
    if mode == "GB" then
        -- No keyboardist - hide if K is in the character prefix
        -- K can appear as: "k ..." (single) or "xk ..." or "kx ..." (duo with x being b,g,v)
        if prefix == "k" then return true end
        if prefix:match("^[bgdv]k$") or prefix:match("^k[bgdv]$") then return true end
    elseif mode == "KB" then
        -- No guitarist - hide if G is in the character prefix
        if prefix == "g" then return true end
        if prefix:match("^[bkdv]g$") or prefix:match("^g[bkdv]$") then return true end
    elseif mode == "GK" then
        -- No bassist - hide if B is in the character prefix
        if prefix == "b" then return true end
        if prefix:match("^[gkdv]b$") or prefix:match("^b[gkdv]$") then return true end
    end
    
    return false
end

-- Check if a camera note should be hidden based on current instrument mode (uses global)
-- Returns true if the note should be HIDDEN
local function ShouldHideCameraNote(note_name)
    return ShouldHideCameraNoteForMode(note_name, instrument_mode)
end

-- Filter to get only the highest priority camera note
-- Also filters out notes that should be hidden based on instrument mode
-- Returns: visible_notes, filtered_highest_note (the highest priority note that was filtered out)
local function GetHighestPriorityNote(notes)
    if #notes == 0 then return {}, nil end
    
    -- Separate visible and hidden notes based on instrument mode
    local visible_notes = {}
    local hidden_notes = {}
    for _, note in ipairs(notes) do
        if not ShouldHideCameraNote(note.name) then
            table.insert(visible_notes, note)
        else
            table.insert(hidden_notes, note)
        end
    end
    
    -- Find highest priority hidden note
    local filtered_highest_note = nil
    local filtered_highest_priority = -1
    for _, note in ipairs(hidden_notes) do
        local priority = GetCameraPriority(note.name)
        if priority > filtered_highest_priority then
            filtered_highest_priority = priority
            filtered_highest_note = note
        end
    end
    
    if #visible_notes == 0 then return {}, filtered_highest_note end
    if #visible_notes == 1 then return visible_notes, filtered_highest_note end
    
    local highest_priority = -1
    local highest_note = nil
    
    for _, note in ipairs(visible_notes) do
        local priority = GetCameraPriority(note.name)
        if priority > highest_priority then
            highest_priority = priority
            highest_note = note
        end
    end
    
    if highest_note then
        return { highest_note }, filtered_highest_note
    end
    return { visible_notes[1] }, filtered_highest_note  -- Fallback to first note if no priorities match
end

-- Fallback camera spritesheets for invalid cuts (notes 98-100: All_Near, All_Far, All_Behind)
local FALLBACK_CAMERA_SPRITESHEETS = { "All_Near", "All_Far", "All_Behind" }

-- Two-character shot pitches (58-71 in CAMERA.txt)
-- When one character is filtered, we can show the remaining character's single shot
local function GetSingleCharFallbackForDuo(filtered_note_name, inst_mode)
    local normalized = NormalizeNoteName(filtered_note_name)
    
    -- Check if this is a two-character shot (format: "XY behind" or "XY near")
    local prefix = normalized:match("^(%S+)")
    if not prefix or #prefix ~= 2 then return nil end
    
    local char1 = prefix:sub(1,1)
    local char2 = prefix:sub(2,2)
    local shot_type = normalized:match("%s+(%S+)$")  -- "near" or "behind"
    
    if not shot_type then return nil end
    
    -- Determine which character is filtered based on instrument mode
    local remaining_char = nil
    if inst_mode == "GB" then
        -- No keys - if K is in the duo, keep the other
        if char1 == "k" then remaining_char = char2
        elseif char2 == "k" then remaining_char = char1
        end
    elseif inst_mode == "KB" then
        -- No guitar - if G is in the duo, keep the other
        if char1 == "g" then remaining_char = char2
        elseif char2 == "g" then remaining_char = char1
        end
    elseif inst_mode == "GK" then
        -- No bass - if B is in the duo, keep the other
        if char1 == "b" then remaining_char = char2
        elseif char2 == "b" then remaining_char = char1
        end
    end
    
    if not remaining_char then return nil end
    
    -- Construct single-character shot name
    -- For vocals, use V_Closeup since that's the standard single-char vocal shot
    if remaining_char == "v" then
        return "V_Closeup"
    else
        -- Capitalize first letter, then shot type with first letter capitalized
        local shot_capitalized = shot_type:sub(1,1):upper() .. shot_type:sub(2)
        return string.upper(remaining_char) .. "_" .. shot_capitalized
    end
end

-- Track names to display
-- pitch_min/pitch_max filter which notes to show, spritesheet_category determines which folder to look in
-- single_priority = true means only show the highest priority note (for Camera)
local TRACK_SECTIONS = {
    { name = "LIGHTING", label = "Post-Processing", pitch_min = 41, pitch_max = 71, spritesheet_category = "PostProc" },
    { name = "LIGHTING", label = "Lighting", pitch_min = 11, pitch_max = 39, spritesheet_category = "Lighting" },
    { name = "CAMERA", label = "Camera", spritesheet_category = "Camera", single_priority = true },
    { name = "VENUE", label = "Venue" },
}

-- Camera singalong note mappings (pitch -> instrument name)
local SINGALONG_CAMERA_NOTES = {
    [14] = "keys",
    [15] = "bass",
    [16] = "guitar",
    [17] = "drums",
}

-- Venue singalong notes that should be present (85-87)
local VENUE_SINGALONG_NOTES = { [85] = true, [86] = true, [87] = true }

-- Camera to Venue singalong note requirements
-- Each camera pitch maps to a table of acceptable venue pitches
local SINGALONG_REQUIREMENTS = {
    [17] = { [86] = true },              -- drums requires 86
    [16] = { [87] = true },              -- guitar requires 87
    [15] = { [85] = true },              -- bass requires 85
    [14] = { [85] = true, [87] = true }, -- keys requires 85 or 87
}

-- Colors
local COLOR_GREY = 0x888888FF
local COLOR_RED = 0xFF4444FF

-- Get custom note name from track's note name map
local function GetCustomNoteName(track, pitch, channel)
    local name = reaper.GetTrackMIDINoteNameEx(0, track, pitch, channel)
    if name and name ~= "" then
        return name
    end
    -- Fallback to standard note name if no custom name set
    local NOTE_NAMES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
    local octave = math.floor(pitch / 12) - 1
    local noteName = NOTE_NAMES[(pitch % 12) + 1]
    return noteName .. octave
end

-- Find track by name
local function FindTrackByName(name)
    local numTracks = reaper.CountTracks(0)
    for i = 0, numTracks - 1 do
        local track = reaper.GetTrack(0, i)
        local _, trackName = reaper.GetTrackName(track)
        if trackName == name then
            return track
        end
    end
    return nil
end

-- Get cursor position (play cursor if playing, edit cursor otherwise)
local function GetCurrentCursorPosition()
    local playState = reaper.GetPlayState()
    if playState & 1 == 1 then -- Playing
        return reaper.GetPlayPosition()
    else
        return reaper.GetCursorPosition()
    end
end

-- Get all camera notes with timing information from a track
-- Returns a list of { name, pitch, startTime, endTime, channel } sorted by startTime
local function GetAllCameraNotesWithTiming(track)
    local notes = {}
    if not track then return notes end
    
    local numItems = reaper.CountTrackMediaItems(track)
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local numTakes = reaper.CountTakes(item)
        
        for t = 0, numTakes - 1 do
            local take = reaper.GetTake(item, t)
            if take and reaper.TakeIsMIDI(take) then
                local _, noteCount = reaper.MIDI_CountEvts(take)
                for n = 0, noteCount - 1 do
                    local _, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, n)
                    local noteStart = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                    local noteEnd = reaper.MIDI_GetProjTimeFromPPQPos(take, endppq)
                    local noteName = GetCustomNoteName(track, pitch, chan)
                    
                    table.insert(notes, {
                        name = noteName,
                        pitch = pitch,
                        startTime = noteStart,
                        endTime = noteEnd,
                        channel = chan
                    })
                end
            end
        end
    end
    
    -- Sort by start time
    table.sort(notes, function(a, b) return a.startTime < b.startTime end)
    return notes
end

-- Find the currently active directed cut and calculate which frame to display
-- Returns: { shouldShow = bool, noteName = string, currentFrame = number, spritesheet_data = table, isFinished = bool, defaultFallback = string }
local function GetDirectedCutDisplay(cameraTrack, cursorPos)
    if not cameraTrack then
        return { shouldShow = false }
    end
    
    local allNotes = GetAllCameraNotesWithTiming(cameraTrack)
    
    -- Find all directed cuts and determine which one should be playing
    local directedCuts = {}
    for _, note in ipairs(allNotes) do
        local targetFrame = GetDirectedCutTargetFrame(note.name)
        if targetFrame then
            table.insert(directedCuts, {
                name = note.name,
                startTime = note.startTime,
                endTime = note.endTime,
                targetFrame = targetFrame,
                pitch = note.pitch
            })
        end
    end
    
    -- Sort directed cuts by start time
    table.sort(directedCuts, function(a, b) return a.startTime < b.startTime end)
    
    -- Find which directed cut should be playing at cursorPos
    -- Key rule: once a directed cut starts, it blocks any other directed cuts
    -- that would start during its playback (even before their first frame)
    
    local activeDirectedCut = nil
    local activePlaybackStartFrame = nil
    local activeCutEndTime = nil  -- When the active cut's playback actually ends
    
    for _, dc in ipairs(directedCuts) do
        -- Get spritesheet info to know frame count
        local spritesheet_data = FindSpritesheet("Camera", dc.name)
        local frameCount = spritesheet_data and spritesheet_data.frame_count or (SPRITE_COLS * SPRITE_ROWS)
        local isRepeating = (dc.targetFrame == "x")
        local targetFrameNum = isRepeating and 1 or dc.targetFrame  -- For "x", treat as starting from frame 1
        
        -- Calculate when this directed cut would start playing (target frame aligns with note-on)
        -- Frame 1 is at note start, so frame N is at note start - (N-1)/SPRITE_FRAME_RATE
        local animDuration = (targetFrameNum - 1) / SPRITE_FRAME_RATE
        local playbackStartTime = dc.startTime - animDuration
        
        -- Calculate when this directed cut would finish (last frame plays, then stops)
        local totalPlaybackDuration
        if isRepeating then
            -- Repeating cuts play until note-off
            totalPlaybackDuration = dc.endTime - playbackStartTime
        else
            -- Non-repeating cuts play until last frame
            totalPlaybackDuration = (frameCount - 1) / SPRITE_FRAME_RATE + animDuration
            -- But also respect note-off if it comes later (continue until last frame regardless)
        end
        local playbackEndTime = playbackStartTime + totalPlaybackDuration
        
        -- For non-repeating, the cut continues until its last frame regardless of note-off
        -- But we use the calculated end based on frame count
        if not isRepeating then
            playbackEndTime = dc.startTime + (frameCount - targetFrameNum) / SPRITE_FRAME_RATE
        end
        
        -- Check if there's already an active directed cut blocking this one
        if activeCutEndTime and playbackStartTime < activeCutEndTime then
            -- This cut would start while another is playing, skip it
            goto continue
        end
        
        -- Check if cursor is within this cut's playback window
        if cursorPos >= playbackStartTime and cursorPos < playbackEndTime then
            activeDirectedCut = dc
            activePlaybackStartFrame = playbackStartTime
            activeCutEndTime = playbackEndTime
            activeDirectedCut.frameCount = frameCount
            activeDirectedCut.isRepeating = isRepeating
            activeDirectedCut.spritesheet_data = spritesheet_data
            activeDirectedCut.playbackEndTime = playbackEndTime
            -- Don't break - we want to find the last valid cut (in case of overlapping considerations)
            -- Actually, break here since we found our active cut
            break
        end
        
        -- Track this cut's end time for blocking future cuts
        if cursorPos >= playbackStartTime and cursorPos >= playbackEndTime then
            -- This cut has finished, update activeCutEndTime for blocking purposes
            activeCutEndTime = playbackEndTime
        elseif playbackStartTime <= cursorPos then
            activeCutEndTime = playbackEndTime
        end
        
        ::continue::
    end
    
    if not activeDirectedCut then
        -- Check if we're in the "finished but note still playing" window for any directed cut
        -- This happens when the animation has finished but the MIDI note is still active
        -- We should show fallback until the note-off, not just for a fixed time
        local finishedDC = nil
        local finishedTime = nil
        for _, dc in ipairs(directedCuts) do
            local spritesheet_data = FindSpritesheet("Camera", dc.name)
            local frameCount = spritesheet_data and spritesheet_data.frame_count or (SPRITE_COLS * SPRITE_ROWS)
            local isRepeating = (dc.targetFrame == "x")
            local targetFrameNum = isRepeating and 1 or dc.targetFrame
            
            local animDuration = (targetFrameNum - 1) / SPRITE_FRAME_RATE
            local playbackStartTime = dc.startTime - animDuration
            local playbackEndTime
            
            if isRepeating then
                playbackEndTime = dc.endTime
            else
                playbackEndTime = dc.startTime + (frameCount - targetFrameNum) / SPRITE_FRAME_RATE
            end
            
            -- Check if animation finished but we're still within the note's duration
            -- This is the "fallback window" - animation done, note still playing
            if cursorPos >= playbackEndTime and cursorPos < dc.endTime then
                -- We're in the fallback window for this directed cut
                if not finishedTime or playbackEndTime > finishedTime then
                    finishedTime = playbackEndTime
                    finishedDC = dc
                end
            end
        end
        
        -- If we're in a directed cut's fallback window (animation done, note still active)
        if finishedDC then
            return {
                shouldShow = false,
                isFinished = true,
                finishedTime = finishedTime,
                finishedName = finishedDC.name,
                noteEndTime = finishedDC.endTime
            }
        end
        
        return { shouldShow = false }
    end
    
    -- Calculate current frame for the active directed cut
    local elapsed = cursorPos - activePlaybackStartFrame
    local rawFrame = math.floor(elapsed * SPRITE_FRAME_RATE)
    local currentFrame
    
    if activeDirectedCut.isRepeating then
        -- Repeating: loop through frames
        currentFrame = rawFrame % activeDirectedCut.frameCount
    else
        -- Non-repeating: clamp to last frame
        currentFrame = math.min(rawFrame, activeDirectedCut.frameCount - 1)
        currentFrame = math.max(0, currentFrame)
    end
    
    return {
        shouldShow = true,
        noteName = activeDirectedCut.name,
        currentFrame = currentFrame,
        spritesheet_data = activeDirectedCut.spritesheet_data,
        isRepeating = activeDirectedCut.isRepeating,
        frameCount = activeDirectedCut.frameCount,
        playbackEndTime = activeDirectedCut.playbackEndTime
    }
end

-- Get the start time of the first post-processing note (pitch 41-71) in the project
-- Returns nil if no post-processing notes exist
local function GetFirstPostProcNoteTime(track)
    if not track then return nil end
    
    local earliest_time = nil
    local numItems = reaper.CountTrackMediaItems(track)
    
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local numTakes = reaper.CountTakes(item)
        
        for t = 0, numTakes - 1 do
            local take = reaper.GetTake(item, t)
            if take and reaper.TakeIsMIDI(take) then
                local _, noteCount = reaper.MIDI_CountEvts(take)
                for n = 0, noteCount - 1 do
                    local _, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, n)
                    if pitch >= POSTPROC_PITCH_MIN and pitch <= POSTPROC_PITCH_MAX then
                        local noteStart = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                        if earliest_time == nil or noteStart < earliest_time then
                            earliest_time = noteStart
                        end
                    end
                end
            end
        end
    end
    
    return earliest_time
end

-- Get the time of the next post-processing note-on after the given time
-- Returns nil if no next post-proc note exists
local function GetNextPostProcEventTime(track, afterTime)
    if not track then return nil end
    
    local next_time = nil
    local numItems = reaper.CountTrackMediaItems(track)
    
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local numTakes = reaper.CountTakes(item)
        
        for t = 0, numTakes - 1 do
            local take = reaper.GetTake(item, t)
            if take and reaper.TakeIsMIDI(take) then
                local _, noteCount = reaper.MIDI_CountEvts(take)
                for n = 0, noteCount - 1 do
                    local _, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, n)
                    if pitch >= POSTPROC_PITCH_MIN and pitch <= POSTPROC_PITCH_MAX then
                        local noteStart = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                        
                        -- Check note-on time only
                        if noteStart > afterTime then
                            if next_time == nil or noteStart < next_time then
                                next_time = noteStart
                            end
                        end
                    end
                end
            end
        end
    end
    
    return next_time
end

-- Get the next post-processing note-on after the given time, returning full note info
-- Returns: { name, pitch, startTime } or nil
local function GetNextPostProcNote(track, afterTime)
    if not track then return nil end
    
    local next_note = nil
    local numItems = reaper.CountTrackMediaItems(track)
    
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local numTakes = reaper.CountTakes(item)
        
        for t = 0, numTakes - 1 do
            local take = reaper.GetTake(item, t)
            if take and reaper.TakeIsMIDI(take) then
                local _, noteCount = reaper.MIDI_CountEvts(take)
                for n = 0, noteCount - 1 do
                    local _, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, n)
                    if pitch >= POSTPROC_PITCH_MIN and pitch <= POSTPROC_PITCH_MAX then
                        local noteStart = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                        if noteStart > afterTime then
                            if next_note == nil or noteStart < next_note.startTime then
                                local name = reaper.GetTrackMIDINoteNameEx(0, track, pitch, 0)
                                if not name or name == "" then
                                    local NOTE_NAMES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
                                    local octave = math.floor(pitch / 12) - 1
                                    name = NOTE_NAMES[(pitch % 12) + 1] .. octave
                                end
                                next_note = { name = name, pitch = pitch, startTime = noteStart }
                            end
                        end
                    end
                end
            end
        end
    end
    
    return next_note
end

-- Get the most recently ended post-proc notes with their end time
-- Returns: (notes table with endTime field, latest end time or nil)
local function GetLastEndedPostProcNotesWithTime(track, timePos)
    local lastEndedNotes = {}
    local latestEndTime = nil
    local firstNoteStart = nil
    local numItems = reaper.CountTrackMediaItems(track)
    
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local numTakes = reaper.CountTakes(item)
        
        for t = 0, numTakes - 1 do
            local take = reaper.GetTake(item, t)
            
            if take and reaper.TakeIsMIDI(take) then
                local _, noteCount = reaper.MIDI_CountEvts(take)
                
                for n = 0, noteCount - 1 do
                    local _, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, n)
                    
                    -- Only consider post-proc notes (including Default)
                    if pitch >= POSTPROC_PITCH_MIN and pitch <= POSTPROC_PITCH_MAX then
                        local noteStart = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                        local noteEnd = reaper.MIDI_GetProjTimeFromPPQPos(take, endppq)
                        
                        -- Track the first note start time in range
                        if firstNoteStart == nil or noteStart < firstNoteStart then
                            firstNoteStart = noteStart
                        end
                        
                        -- Check if this note ended before current position
                        if noteEnd <= timePos then
                            if latestEndTime == nil or noteEnd > latestEndTime then
                                -- New latest end time, reset the list
                                latestEndTime = noteEnd
                                lastEndedNotes = {{
                                    pitch = pitch,
                                    name = GetCustomNoteName(track, pitch, chan),
                                    channel = chan + 1,
                                    velocity = vel,
                                    endTime = noteEnd
                                }}
                            elseif noteEnd == latestEndTime then
                                -- Same end time, add to list
                                table.insert(lastEndedNotes, {
                                    pitch = pitch,
                                    name = GetCustomNoteName(track, pitch, chan),
                                    channel = chan + 1,
                                    velocity = vel,
                                    endTime = noteEnd
                                })
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Only return notes if we're past the first note in range
    if firstNoteStart and timePos >= firstNoteStart then
        return lastEndedNotes, latestEndTime
    end
    return {}, nil
end

-- Get all MIDI notes at a specific time position on a track
local function GetNotesAtPosition(track, timePos)
    local notes = {}
    local numItems = reaper.CountTrackMediaItems(track)
    
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local itemLength = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local itemEnd = itemStart + itemLength
        
        -- Check if cursor is within this item
        if timePos >= itemStart and timePos < itemEnd then
            local numTakes = reaper.CountTakes(item)
            
            for t = 0, numTakes - 1 do
                local take = reaper.GetTake(item, t)
                
                if take and reaper.TakeIsMIDI(take) then
                    -- Convert time position to PPQ
                    local ppqPos = reaper.MIDI_GetPPQPosFromProjTime(take, timePos)
                    
                    -- Get note count
                    local _, noteCount = reaper.MIDI_CountEvts(take)
                    
                    for n = 0, noteCount - 1 do
                        local _, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, n)
                        
                        -- Check if note is playing at this position
                        if ppqPos >= startppq and ppqPos < endppq then
                            table.insert(notes, {
                                pitch = pitch,
                                name = GetCustomNoteName(track, pitch, chan),
                                channel = chan + 1,
                                velocity = vel
                            })
                        end
                    end
                end
            end
        end
    end
    
    return notes
end

-- Get the most recently ended notes before the current position on a track
-- Returns notes that ended most recently (could be multiple if they ended at same time)
local function GetLastEndedNotes(track, timePos)
    local lastEndedNotes = {}
    local latestEndTime = nil
    local firstNoteStart = nil
    local numItems = reaper.CountTrackMediaItems(track)
    
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local itemLength = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local itemEnd = itemStart + itemLength
        
        local numTakes = reaper.CountTakes(item)
        
        for t = 0, numTakes - 1 do
            local take = reaper.GetTake(item, t)
            
            if take and reaper.TakeIsMIDI(take) then
                local _, noteCount = reaper.MIDI_CountEvts(take)
                
                for n = 0, noteCount - 1 do
                    local _, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, n)
                    
                    -- Convert PPQ to project time
                    local noteStart = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                    local noteEnd = reaper.MIDI_GetProjTimeFromPPQPos(take, endppq)
                    
                    -- Track the first note start time
                    if firstNoteStart == nil or noteStart < firstNoteStart then
                        firstNoteStart = noteStart
                    end
                    
                    -- Check if this note ended before current position
                    if noteEnd <= timePos then
                        if latestEndTime == nil or noteEnd > latestEndTime then
                            -- New latest end time, reset the list
                            latestEndTime = noteEnd
                            lastEndedNotes = {{
                                pitch = pitch,
                                name = GetCustomNoteName(track, pitch, chan),
                                channel = chan + 1,
                                velocity = vel
                            }}
                        elseif noteEnd == latestEndTime then
                            -- Same end time, add to list
                            table.insert(lastEndedNotes, {
                                pitch = pitch,
                                name = GetCustomNoteName(track, pitch, chan),
                                channel = chan + 1,
                                velocity = vel
                            })
                        end
                    end
                end
            end
        end
    end
    
    -- Only return notes if we're past the first note
    if firstNoteStart and timePos >= firstNoteStart then
        return lastEndedNotes
    end
    return {}
end

-- Get the most recently ended notes within a specific pitch range
-- Returns notes that ended most recently (could be multiple if they ended at same time)
local function GetLastEndedNotesInRange(track, timePos, pitchMin, pitchMax)
    local lastEndedNotes = {}
    local latestEndTime = nil
    local firstNoteStart = nil
    local numItems = reaper.CountTrackMediaItems(track)
    
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local numTakes = reaper.CountTakes(item)
        
        for t = 0, numTakes - 1 do
            local take = reaper.GetTake(item, t)
            
            if take and reaper.TakeIsMIDI(take) then
                local _, noteCount = reaper.MIDI_CountEvts(take)
                
                for n = 0, noteCount - 1 do
                    local _, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, n)
                    
                    -- Only consider notes within the pitch range
                    if pitch >= pitchMin and pitch <= pitchMax then
                        local noteStart = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                        local noteEnd = reaper.MIDI_GetProjTimeFromPPQPos(take, endppq)
                        
                        -- Track the first note start time in range
                        if firstNoteStart == nil or noteStart < firstNoteStart then
                            firstNoteStart = noteStart
                        end
                        
                        -- Check if this note ended before current position
                        if noteEnd <= timePos then
                            if latestEndTime == nil or noteEnd > latestEndTime then
                                -- New latest end time, reset the list
                                latestEndTime = noteEnd
                                lastEndedNotes = {{
                                    pitch = pitch,
                                    name = GetCustomNoteName(track, pitch, chan),
                                    channel = chan + 1,
                                    velocity = vel
                                }}
                            elseif noteEnd == latestEndTime then
                                -- Same end time, add to list
                                table.insert(lastEndedNotes, {
                                    pitch = pitch,
                                    name = GetCustomNoteName(track, pitch, chan),
                                    channel = chan + 1,
                                    velocity = vel
                                })
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Only return notes if we're past the first note in range
    if firstNoteStart and timePos >= firstNoteStart then
        return lastEndedNotes
    end
    return {}
end

-- Get the most recently ended notes within a specific pitch range, also returning the end time
-- Returns: (notes table, latest end time or nil)
local function GetLastEndedNotesInRangeWithTime(track, timePos, pitchMin, pitchMax)
    local lastEndedNotes = {}
    local latestEndTime = nil
    local firstNoteStart = nil
    local numItems = reaper.CountTrackMediaItems(track)
    
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local numTakes = reaper.CountTakes(item)
        
        for t = 0, numTakes - 1 do
            local take = reaper.GetTake(item, t)
            
            if take and reaper.TakeIsMIDI(take) then
                local _, noteCount = reaper.MIDI_CountEvts(take)
                
                for n = 0, noteCount - 1 do
                    local _, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, n)
                    
                    -- Only consider notes within the pitch range
                    if pitch >= pitchMin and pitch <= pitchMax then
                        local noteStart = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                        local noteEnd = reaper.MIDI_GetProjTimeFromPPQPos(take, endppq)
                        
                        -- Track the first note start time in range
                        if firstNoteStart == nil or noteStart < firstNoteStart then
                            firstNoteStart = noteStart
                        end
                        
                        -- Check if this note ended before current position
                        if noteEnd <= timePos then
                            if latestEndTime == nil or noteEnd > latestEndTime then
                                -- New latest end time, reset the list
                                latestEndTime = noteEnd
                                lastEndedNotes = {{
                                    pitch = pitch,
                                    name = GetCustomNoteName(track, pitch, chan),
                                    channel = chan + 1,
                                    velocity = vel
                                }}
                            elseif noteEnd == latestEndTime then
                                -- Same end time, add to list
                                table.insert(lastEndedNotes, {
                                    pitch = pitch,
                                    name = GetCustomNoteName(track, pitch, chan),
                                    channel = chan + 1,
                                    velocity = vel
                                })
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Only return notes if we're past the first note in range
    if firstNoteStart and timePos >= firstNoteStart then
        return lastEndedNotes, latestEndTime
    end
    return {}, nil
end

-- Check and update manual lighting state based on prev/next/first notes on LIGHTING track
-- Calculates state by counting prev/next notes from most recent `first` (or start) to current position
-- Also finds the next upcoming toggle to animate towards
local function UpdateManualLightState(cursorPos)
    local track = FindTrackByName("LIGHTING")
    if not track then 
        manual_light_state = false
        manual_light_toggle_time = nil
        manual_light_skip_animation = false
        return 
    end
    
    -- Collect all first/prev/next note start times from the LIGHTING track
    local first_times = {}  -- start times of `first` notes
    local toggle_times = {} -- start times of prev/next notes
    local manual_light_starts = {} -- start times of manual lighting notes (34-39)
    
    local numItems = reaper.CountTrackMediaItems(track)
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        
        local numTakes = reaper.CountTakes(item)
        for t = 0, numTakes - 1 do
            local take = reaper.GetTake(item, t)
            if take and reaper.TakeIsMIDI(take) then
                local _, noteCount = reaper.MIDI_CountEvts(take)
                for n = 0, noteCount - 1 do
                    local _, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, n)
                    local noteStart = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                    
                    if pitch == FIRST_PITCH then
                        table.insert(first_times, noteStart)
                    elseif PREV_NEXT_PITCHES[pitch] then
                        table.insert(toggle_times, noteStart)
                    elseif MANUAL_LIGHT_PITCHES[pitch] then
                        table.insert(manual_light_starts, noteStart)
                    end
                end
            end
        end
    end
    
    -- Sort times
    table.sort(first_times)
    table.sort(toggle_times)
    table.sort(manual_light_starts)
    
    -- Find the most recent `first` note start time (or 0 for beginning of project)
    local last_first_time = 0
    for _, t in ipairs(first_times) do
        if t <= cursorPos then
            last_first_time = t
        end
    end
    
    -- Count prev/next toggles that started after the last `first` and at or before cursor
    -- This determines the CURRENT stable state
    local toggle_count = 0
    for _, t in ipairs(toggle_times) do
        if t > last_first_time and t <= cursorPos then
            toggle_count = toggle_count + 1
        end
    end
    
    -- Current stable state is ON if odd number of toggles, OFF if even
    local current_state = (toggle_count % 2) == 1
    
    -- Find the NEXT upcoming toggle (first toggle after cursorPos, but still after last_first_time)
    local next_toggle_time = nil
    for _, t in ipairs(toggle_times) do
        if t > cursorPos and t > last_first_time then
            next_toggle_time = t
            break
        end
    end
    
    -- Check if any manual lighting note starts at the same time as the next toggle
    local toggle_has_manual_start = false
    if next_toggle_time then
        for _, t in ipairs(manual_light_starts) do
            if math.abs(t - next_toggle_time) < 0.001 then
                toggle_has_manual_start = true
                break
            end
        end
    end
    
    -- Update global state
    manual_light_state = current_state
    manual_light_skip_animation = toggle_has_manual_start
    manual_light_cursor_pos = cursorPos
    
    -- Store the NEXT toggle time for animation (we animate TOWARDS the upcoming toggle)
    if next_toggle_time then
        manual_light_toggle_time = next_toggle_time
        -- The upcoming state will be the opposite of current state
        manual_light_animating_forward = not current_state
    else
        manual_light_toggle_time = nil
    end
end

-- Draw a manual lighting spritesheet with special state-based animation
-- Animation completes (lands on target frame) exactly when the prev/next note starts
-- When OFF: freeze on frame 0
-- When toggling ON: play forward, freeze on last frame
-- When toggling OFF: play reverse from last frame to 0, freeze on frame 0
-- If skip_animation is true, jump directly to the target frame
local function DrawManualLightingSpritesheet(spritesheet_data, note_name)
    if not spritesheet_data or not spritesheet_data.image then return end
    
    local image = spritesheet_data.image
    local frame_count = spritesheet_data.frame_count or (SPRITE_COLS * SPRITE_ROWS)
    local cols = spritesheet_data.cols or SPRITE_COLS
    
    if not reaper.ImGui_ValidatePtr(image, "ImGui_Image*") then return end
    if frame_count < 1 then frame_count = 1 end
    
    local last_frame = frame_count - 1
    local current_frame = 0
    
    -- Calculate animation duration in seconds
    local anim_duration = frame_count / SPRITE_FRAME_RATE
    
    -- Check if we're in the animation window before the next toggle
    local in_animation_window = false
    if manual_light_toggle_time then
        local anim_start_time = manual_light_toggle_time - anim_duration
        in_animation_window = (manual_light_cursor_pos >= anim_start_time) and (manual_light_cursor_pos < manual_light_toggle_time)
    end
    
    -- If skip animation flag is set (manual light note starts with toggle), jump directly to target frame
    if manual_light_skip_animation and manual_light_toggle_time and manual_light_cursor_pos >= manual_light_toggle_time then
        -- We're at or past a toggle that has a manual light starting - show the NEW state
        local new_state = not manual_light_state  -- The state AFTER the toggle
        current_frame = new_state and last_frame or 0
    elseif in_animation_window and not manual_light_skip_animation then
        -- We're in the animation window - animate towards the upcoming toggle
        local anim_start_time = manual_light_toggle_time - anim_duration
        local elapsed = manual_light_cursor_pos - anim_start_time
        local anim_frame = math.floor(elapsed * SPRITE_FRAME_RATE)
        
        if manual_light_animating_forward then
            -- Playing forward (toggling to ON)
            if anim_frame >= last_frame then
                current_frame = last_frame
            else
                current_frame = math.max(0, anim_frame)
            end
        else
            -- Playing reverse (toggling to OFF)
            if anim_frame >= last_frame then
                current_frame = 0
            else
                current_frame = math.max(0, last_frame - anim_frame)
            end
        end
    else
        -- Not in animation window - show stable current state
        current_frame = manual_light_state and last_frame or 0
    end
    
    local img_w, img_h = reaper.ImGui_Image_GetSize(image)
    local tile_w = SPRITE_DISPLAY_W + SPRITE_BORDER * 2
    local tile_h = SPRITE_DISPLAY_H + SPRITE_BORDER * 2
    
    local col = current_frame % cols
    local row = math.floor(current_frame / cols)
    
    local uv0_x = (col * tile_w + SPRITE_BORDER) / img_w
    local uv0_y = (row * tile_h + SPRITE_BORDER) / img_h
    local uv1_x = ((col + 1) * tile_w - SPRITE_BORDER) / img_w
    local uv1_y = ((row + 1) * tile_h - SPRITE_BORDER) / img_h
    
    reaper.ImGui_Image(ctx, image, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H, uv0_x, uv0_y, uv1_x, uv1_y)
end

-- Get display name for a note (normalizes "Default" to "default" for display)
local function GetDisplayName(name)
    if name == "Default" then
        return "default"
    end
    return name
end

-- Helper function to display notes with spritesheets in horizontal layout
local function DisplayNotesWithSpritesheets(notes, spritesheet_category, isGreyed)
    if #notes == 0 then return end
    
    -- Display all note names horizontally on one line
    reaper.ImGui_Indent(ctx)
    for i, note in ipairs(notes) do
        if i > 1 then
            reaper.ImGui_SameLine(ctx)
        end
        -- Use fixed width for each name column to align with videos below
        local text_width = SPRITE_DISPLAY_W
        reaper.ImGui_PushItemWidth(ctx, text_width)
        reaper.ImGui_Text(ctx, GetDisplayName(note.name))
        reaper.ImGui_PopItemWidth(ctx)
        -- Add spacing to match video width
        if i < #notes then
            reaper.ImGui_SameLine(ctx, 0, SPRITE_DISPLAY_W - reaper.ImGui_CalcTextSize(ctx, GetDisplayName(note.name)) + 8)
        end
    end
    
    -- Display all spritesheets horizontally on the next line (if category defined)
    if spritesheet_category then
        for i, note in ipairs(notes) do
            if i > 1 then
                reaper.ImGui_SameLine(ctx)
            end
            local spritesheet_data = FindSpritesheet(spritesheet_category, note.name)
            if spritesheet_data then
                -- Use special drawing for manual lighting notes (pitches 34-39) - only for Lighting category
                if spritesheet_category == "Lighting" and MANUAL_LIGHT_PITCHES[note.pitch] then
                    DrawManualLightingSpritesheet(spritesheet_data, note.name)
                else
                    DrawCameraSpritesheet(spritesheet_data, note.name)
                end
            else
                -- Leave empty space where video would be
                reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
            end
        end
    end
    reaper.ImGui_Unindent(ctx)
end

-- Helper to draw a single note with "Section: NoteName" label above and spritesheet below
local function DrawSingleNoteBlock(sectionLabel, note, spritesheet_category, isGreyed)
    reaper.ImGui_Text(ctx, sectionLabel .. ": ")
    reaper.ImGui_SameLine(ctx, 0, 0)
    if isGreyed then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
    end
    reaper.ImGui_Text(ctx, GetDisplayName(note.name))
    if isGreyed then
        reaper.ImGui_PopStyleColor(ctx)
    end
    
    local spritesheet_data = FindSpritesheet(spritesheet_category, note.name)
    if spritesheet_data then
        if spritesheet_category == "Lighting" and MANUAL_LIGHT_PITCHES[note.pitch] then
            DrawManualLightingSpritesheet(spritesheet_data, note.name)
        else
            DrawCameraSpritesheet(spritesheet_data, note.name)
        end
    else
        reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
    end
end

-- Helper to draw a placeholder block with "Section: label" format
local function DrawPlaceholderBlock(sectionLabel, label, isGreyed)
    reaper.ImGui_Text(ctx, sectionLabel .. ": ")
    reaper.ImGui_SameLine(ctx, 0, 0)
    if isGreyed then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
    end
    reaper.ImGui_Text(ctx, label)
    if isGreyed then
        reaper.ImGui_PopStyleColor(ctx)
    end
    reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
end

-- Draw just the first frame of a spritesheet (static, no animation)
local function DrawStaticFirstFrame(spritesheet_data)
    if not spritesheet_data or not spritesheet_data.image then
        reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
        return
    end
    
    local image = spritesheet_data.image
    if not reaper.ImGui_ValidatePtr(image, "ImGui_Image*") then
        reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
        return
    end
    
    local img_w, img_h = reaper.ImGui_Image_GetSize(image)
    local tile_w = SPRITE_DISPLAY_W + SPRITE_BORDER * 2
    local tile_h = SPRITE_DISPLAY_H + SPRITE_BORDER * 2
    
    -- First frame is at col=0, row=0
    local uv0_x = SPRITE_BORDER / img_w
    local uv0_y = SPRITE_BORDER / img_h
    local uv1_x = (tile_w - SPRITE_BORDER) / img_w
    local uv1_y = (tile_h - SPRITE_BORDER) / img_h
    
    reaper.ImGui_Image(ctx, image, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H, uv0_x, uv0_y, uv1_x, uv1_y)
end

-- Draw just the first frame of a spritesheet with opacity (static, no animation)
local function DrawStaticFirstFrameWithOpacity(spritesheet_data, opacity)
    if not spritesheet_data or not spritesheet_data.image then
        reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
        return
    end
    if opacity <= 0 then
        reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
        return
    end
    
    local image = spritesheet_data.image
    if not reaper.ImGui_ValidatePtr(image, "ImGui_Image*") then
        reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
        return
    end
    
    local img_w, img_h = reaper.ImGui_Image_GetSize(image)
    local tile_w = SPRITE_DISPLAY_W + SPRITE_BORDER * 2
    local tile_h = SPRITE_DISPLAY_H + SPRITE_BORDER * 2
    
    -- First frame is at col=0, row=0
    local uv0_x = SPRITE_BORDER / img_w
    local uv0_y = SPRITE_BORDER / img_h
    local uv1_x = (tile_w - SPRITE_BORDER) / img_w
    local uv1_y = (tile_h - SPRITE_BORDER) / img_h
    
    -- Use DrawList to draw image with tint/opacity
    local cursor_x, cursor_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    
    -- Create tint color with opacity (RGBA format: 0xRRGGBBAA)
    local alpha = math.floor(opacity * 255)
    local tint_col = 0xFFFFFF00 | alpha  -- White with variable alpha
    
    -- Draw image using DrawList (supports color/tint)
    reaper.ImGui_DrawList_AddImage(draw_list, image, 
        cursor_x, cursor_y,
        cursor_x + SPRITE_DISPLAY_W, cursor_y + SPRITE_DISPLAY_H,
        uv0_x, uv0_y, uv1_x, uv1_y,
        tint_col)
    
    -- Reserve space in the layout (since DrawList draws don't advance cursor)
    reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
end

-- Get the lowest pitch note from a list
local function GetLowestPitchNote(notes)
    if #notes == 0 then return nil end
    local lowest = notes[1]
    for i = 2, #notes do
        if notes[i].pitch < lowest.pitch then
            lowest = notes[i]
        end
    end
    return lowest
end

-- Display a section for a track
local function DisplayTrackSection(section, cursorPos, isFirst, singalongWarnings)
    local trackName = section.name
    local label = section.label
    local pitch_min = section.pitch_min
    local pitch_max = section.pitch_max
    local spritesheet_category = section.spritesheet_category
    local single_priority = section.single_priority
    
    local track = FindTrackByName(trackName)
    
    if not isFirst then
        reaper.ImGui_Separator(ctx)
    end
    reaper.ImGui_Text(ctx, label)
    
    if track then
        local allNotes = GetNotesAtPosition(track, cursorPos)
        local notes = {}
        
        -- Filter notes by pitch range if specified
        for _, note in ipairs(allNotes) do
            if (not pitch_min or note.pitch >= pitch_min) and (not pitch_max or note.pitch <= pitch_max) then
                table.insert(notes, note)
            end
        end
        
        -- If single_priority is set, only keep the highest priority note
        if single_priority and #notes > 1 then
            notes = GetHighestPriorityNote(notes)
        end
        
        local hasContent = false
        
        -- Display singalong warnings first (for VENUE track)
        if singalongWarnings and #singalongWarnings > 0 then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_RED)
            for _, warning in ipairs(singalongWarnings) do
                reaper.ImGui_Text(ctx, "  no " .. warning .. " singalong")
            end
            reaper.ImGui_PopStyleColor(ctx)
            hasContent = true
        end
        
        if #notes > 0 then
            DisplayNotesWithSpritesheets(notes, spritesheet_category, false)
            hasContent = true
        end
        
        if not hasContent then
            -- Special handling for Post-Processing section
            if label == "Post-Processing" then
                -- Check if note 71 (Default) is active OR if we're before any post-processing notes
                local showDefault = false
                
                -- Check if Default note (71) is currently playing
                for _, note in ipairs(allNotes) do
                    if note.pitch == POSTPROC_DEFAULT_PITCH then
                        showDefault = true
                        break
                    end
                end
                
                -- Check if we're before any post-processing notes
                if not showDefault then
                    local firstPostProcTime = GetFirstPostProcNoteTime(track)
                    if firstPostProcTime == nil or cursorPos < firstPostProcTime then
                        showDefault = true
                    end
                end
                
                if showDefault then
                    -- Show "default" with spritesheet if available
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
                    reaper.ImGui_Indent(ctx)
                    reaper.ImGui_Text(ctx, "default")
                    local spritesheet_data = FindSpritesheet(spritesheet_category, "Default")
                    if spritesheet_data then
                        DrawCameraSpritesheet(spritesheet_data, "Default")
                    else
                        reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
                    end
                    reaper.ImGui_Unindent(ctx)
                    reaper.ImGui_PopStyleColor(ctx)
                else
                    -- Show last ended post-processing note (only notes in pitch range 41-71)
                    -- This includes Default which will fade like other notes
                    local lastEnded = GetLastEndedNotesInRange(track, cursorPos, POSTPROC_PITCH_MIN, POSTPROC_PITCH_MAX)
                    
                    if #lastEnded > 0 then
                        -- Show last ended post-proc notes (greyed)
                        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
                        DisplayNotesWithSpritesheets(lastEnded, spritesheet_category, true)
                        reaper.ImGui_PopStyleColor(ctx)
                    else
                        -- No ended notes - show "default"
                        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
                        reaper.ImGui_Indent(ctx)
                        reaper.ImGui_Text(ctx, "default")
                        local spritesheet_data = FindSpritesheet(spritesheet_category, "Default")
                        if spritesheet_data then
                            DrawCameraSpritesheet(spritesheet_data, "Default")
                        else
                            reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
                        end
                        reaper.ImGui_Unindent(ctx)
                        reaper.ImGui_PopStyleColor(ctx)
                    end
                end
            -- For other tracks with spritesheet category, show last ended notes instead of "none"
            elseif spritesheet_category then
                local lastEnded = {}
                
                -- Use pitch-filtered search if range is specified
                if pitch_min and pitch_max then
                    lastEnded = GetLastEndedNotesInRange(track, cursorPos, pitch_min, pitch_max)
                else
                    lastEnded = GetLastEndedNotes(track, cursorPos)
                end
                
                -- If single_priority is set, only keep the highest priority note
                if single_priority and #lastEnded > 1 then
                    lastEnded = GetHighestPriorityNote(lastEnded)
                end
                
                if #lastEnded > 0 then
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
                    DisplayNotesWithSpritesheets(lastEnded, spritesheet_category, true)
                    reaper.ImGui_PopStyleColor(ctx)
                else
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
                    reaper.ImGui_Text(ctx, "  none")
                    reaper.ImGui_PopStyleColor(ctx)
                    -- Add vertical padding to match video height
                    reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
                end
            else
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
                reaper.ImGui_Text(ctx, "  none")
                reaper.ImGui_PopStyleColor(ctx)
            end
        end
    else
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
        reaper.ImGui_Text(ctx, "  (track not found)")
        reaper.ImGui_PopStyleColor(ctx)
    end
end

-- Check for singalong validation issues
-- Only warns if CAMERA has a singalong note and VENUE has NO singalong note
-- anywhere within the bounds of that CAMERA note
local function CheckSingalongWarnings(cursorPos)
    local warnings = {}
    
    local cameraTrack = FindTrackByName("CAMERA")
    local venueTrack = FindTrackByName("VENUE")
    
    if not cameraTrack or not venueTrack then
        return warnings
    end
    
    -- Get camera notes with their full time bounds
    local cameraSingalongNotes = {}
    local numItems = reaper.CountTrackMediaItems(cameraTrack)
    
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(cameraTrack, i)
        local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local itemLength = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local itemEnd = itemStart + itemLength
        
        if cursorPos >= itemStart and cursorPos < itemEnd then
            local numTakes = reaper.CountTakes(item)
            
            for t = 0, numTakes - 1 do
                local take = reaper.GetTake(item, t)
                
                if take and reaper.TakeIsMIDI(take) then
                    local ppqPos = reaper.MIDI_GetPPQPosFromProjTime(take, cursorPos)
                    local _, noteCount = reaper.MIDI_CountEvts(take)
                    
                    for n = 0, noteCount - 1 do
                        local _, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, n)
                        
                        -- Check if this is a singalong note playing at cursor
                        if ppqPos >= startppq and ppqPos < endppq and SINGALONG_CAMERA_NOTES[pitch] then
                            local noteStart = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                            local noteEnd = reaper.MIDI_GetProjTimeFromPPQPos(take, endppq)
                            table.insert(cameraSingalongNotes, {
                                pitch = pitch,
                                instrument = SINGALONG_CAMERA_NOTES[pitch],
                                startTime = noteStart,
                                endTime = noteEnd
                            })
                        end
                    end
                end
            end
        end
    end
    
    -- For each camera singalong note, check if venue has the required singalong note within its bounds
    for _, camNote in ipairs(cameraSingalongNotes) do
        local hasMatchingVenueSingalong = false
        local requiredVenueNotes = SINGALONG_REQUIREMENTS[camNote.pitch]
        
        if not requiredVenueNotes then
            -- No requirements defined, skip
            goto continue
        end
        
        local venueNumItems = reaper.CountTrackMediaItems(venueTrack)
        for i = 0, venueNumItems - 1 do
            local item = reaper.GetTrackMediaItem(venueTrack, i)
            local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local itemLength = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            local itemEnd = itemStart + itemLength
            
            -- Check if item could contain notes overlapping with camera note
            if itemEnd > camNote.startTime and itemStart < camNote.endTime then
                local numTakes = reaper.CountTakes(item)
                
                for t = 0, numTakes - 1 do
                    local take = reaper.GetTake(item, t)
                    
                    if take and reaper.TakeIsMIDI(take) then
                        local _, noteCount = reaper.MIDI_CountEvts(take)
                        
                        for n = 0, noteCount - 1 do
                            local _, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, n)
                            
                            -- Check if this venue note matches the required pitches for this camera note
                            if requiredVenueNotes[pitch] then
                                local noteStart = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
                                local noteEnd = reaper.MIDI_GetProjTimeFromPPQPos(take, endppq)
                                
                                -- Check if venue note overlaps with camera note bounds
                                if noteEnd > camNote.startTime and noteStart < camNote.endTime then
                                    hasMatchingVenueSingalong = true
                                    break
                                end
                            end
                        end
                    end
                    if hasMatchingVenueSingalong then break end
                end
            end
            if hasMatchingVenueSingalong then break end
        end
        
        if not hasMatchingVenueSingalong then
            table.insert(warnings, camNote.instrument)
        end
        
        ::continue::
    end
    
    return warnings
end

-- Check if a given mode would filter out ALL camera notes at a position
-- Returns true if the mode would have no valid camera cuts (all filtered)
local function ModeWouldFilterAllNotes(cameraNotes, mode)
    if #cameraNotes == 0 then return false end  -- No notes to filter
    
    for _, note in ipairs(cameraNotes) do
        if not ShouldHideCameraNoteForMode(note.name, mode) then
            return false  -- At least one note is visible in this mode
        end
    end
    return true  -- All notes were filtered
end

-- Main loop function
local first_frame = true
local function MainLoop()
    if first_frame then
        reaper.ImGui_SetNextWindowSize(ctx, 450, 322)
        first_frame = false
    end
    local visible, open = reaper.ImGui_Begin(ctx, "Venue Preview", true)
    
    if visible then
        -- Get cursor position and camera notes early so we can check button colors
        local cursorPos = GetCurrentCursorPosition()
        local cameraTrack = FindTrackByName("CAMERA")
        
        -- Check which modes would filter all camera notes (for button coloring)
        -- Also check last ended notes when no current notes exist
        local gb_has_issue = false
        local kb_has_issue = false
        local gk_has_issue = false
        
        if cameraTrack then
            local cameraNotes = GetNotesAtPosition(cameraTrack, cursorPos)
            local notesToCheck = cameraNotes
            
            -- If no current notes, check last ended notes instead
            if #notesToCheck == 0 then
                notesToCheck = GetLastEndedNotes(cameraTrack, cursorPos)
            end
            
            if #notesToCheck > 0 then
                gb_has_issue = ModeWouldFilterAllNotes(notesToCheck, "GB")
                kb_has_issue = ModeWouldFilterAllNotes(notesToCheck, "KB")
                gk_has_issue = ModeWouldFilterAllNotes(notesToCheck, "GK")
            end
        end
        
        -- Store button info for later use (drawn to the right of Camera)
        local button_w = 40
        local gb_active = instrument_mode == "GB"
        local kb_active = instrument_mode == "KB"
        local gk_active = instrument_mode == "GK"
        
        -- Reset current active notes for this frame
        current_active_notes = {}
        
        -- Update manual lighting state based on prev/next/first notes
        UpdateManualLightState(cursorPos)
        
        local lightingTrack = FindTrackByName("LIGHTING")
        local venueTrack = FindTrackByName("VENUE")
        
        -- ========== ROW 1: Camera + Lighting side by side ==========
        
        -- Check for directed cuts first (they take precedence)
        local directedCutDisplay = GetDirectedCutDisplay(cameraTrack, cursorPos)
        
        -- Get camera note (highest priority) - but directed cuts override
        local cameraNote = nil
        local cameraIsGreyed = false
        local cameraFilteredNote = nil  -- Highest priority note that was filtered out by instrument mode
        local usingDirectedCut = false
        local directedCutFallback = nil  -- Fallback camera when directed cut just finished
        
        if directedCutDisplay.shouldShow then
            -- A directed cut is playing - it takes precedence
            usingDirectedCut = true
            cameraNote = { name = directedCutDisplay.noteName, pitch = 0 }  -- Pitch not needed for display
        elseif directedCutDisplay.isFinished then
            -- A directed cut just finished, prefer non-directed cuts that are still playing
            -- Only fall back to default if no valid non-directed cuts are active
            local foundNonDirectedFallback = false
            
            if cameraTrack then
                local cameraNotes = GetNotesAtPosition(cameraTrack, cursorPos)
                -- Filter to only non-directed cuts
                local nonDirectedNotes = {}
                for _, note in ipairs(cameraNotes) do
                    if not IsDirectedCut(note.name) then
                        table.insert(nonDirectedNotes, note)
                    end
                end
                
                -- Apply instrument mode filtering and priority
                local visibleNotes, filteredNote = GetHighestPriorityNote(nonDirectedNotes)
                if #visibleNotes > 0 then
                    -- Use the non-directed cut as fallback
                    cameraNote = visibleNotes[1]
                    foundNonDirectedFallback = true
                end
            end
            
            if not foundNonDirectedFallback then
                -- No non-directed cuts playing, use default fallback
                local fallbackIndex = (math.floor(directedCutDisplay.finishedTime * 10) % #FALLBACK_CAMERA_SPRITESHEETS) + 1
                directedCutFallback = FALLBACK_CAMERA_SPRITESHEETS[fallbackIndex]
            end
        end
        
        if not usingDirectedCut and cameraTrack then
            local cameraNotes = GetNotesAtPosition(cameraTrack, cursorPos)
            local visibleNotes, filteredNote = GetHighestPriorityNote(cameraNotes)
            cameraFilteredNote = filteredNote
            if #visibleNotes > 0 then
                cameraNote = visibleNotes[1]
            elseif not cameraFilteredNote then
                -- Only try last ended if we don't have a filtered current note
                -- (If we have a filtered current note, we want to show it in red, not fall back to previous)
                local lastEnded = GetLastEndedNotes(cameraTrack, cursorPos)
                local visibleLastEnded, filteredLastEnded = GetHighestPriorityNote(lastEnded)
                if #visibleLastEnded > 0 then
                    cameraNote = visibleLastEnded[1]
                    cameraIsGreyed = true
                end
                -- Use filtered last ended note if no visible ones
                if not cameraFilteredNote then
                    cameraFilteredNote = filteredLastEnded
                end
            end
        end
        
        -- Get lighting note (lowest pitch in range 11-29 or 33-39, excluding prev/next/first)
        local lightingNote = nil
        local lightingIsGreyed = false
        local prevNextFirstNotes = {}  -- Notes 30-32
        if lightingTrack then
            local allNotes = GetNotesAtPosition(lightingTrack, cursorPos)
            local lightingNotes = {}
            for _, note in ipairs(allNotes) do
                -- Separate prev/next/first notes (30-32)
                if note.pitch >= 30 and note.pitch <= 32 then
                    table.insert(prevNextFirstNotes, note)
                -- Regular lighting notes (11-29 or 33-39)
                elseif (note.pitch >= 11 and note.pitch <= 29) or (note.pitch >= 33 and note.pitch <= 39) then
                    table.insert(lightingNotes, note)
                end
            end
            lightingNote = GetLowestPitchNote(lightingNotes)
            
            if not lightingNote then
                -- Try last ended in range (excluding 30-32)
                -- We need to find the most recently ended note across both ranges
                local lastEnded1, latestTime1 = GetLastEndedNotesInRangeWithTime(lightingTrack, cursorPos, 11, 29)
                local lastEnded2, latestTime2 = GetLastEndedNotesInRangeWithTime(lightingTrack, cursorPos, 33, 39)
                
                -- Pick the notes from whichever range ended most recently
                local combinedLastEnded = {}
                if latestTime1 and latestTime2 then
                    if latestTime2 > latestTime1 then
                        -- Manual lighting notes ended more recently
                        combinedLastEnded = lastEnded2
                    elseif latestTime1 > latestTime2 then
                        -- Regular lighting notes ended more recently
                        combinedLastEnded = lastEnded1
                    else
                        -- Same end time, combine both
                        for _, note in ipairs(lastEnded1) do table.insert(combinedLastEnded, note) end
                        for _, note in ipairs(lastEnded2) do table.insert(combinedLastEnded, note) end
                    end
                elseif latestTime2 then
                    combinedLastEnded = lastEnded2
                elseif latestTime1 then
                    combinedLastEnded = lastEnded1
                end
                
                lightingNote = GetLowestPitchNote(combinedLastEnded)
                if lightingNote then
                    lightingIsGreyed = true
                end
            end
        end
        
        -- ========== ROW 1: Venue (left column) + Camera (right) ==========
        
        -- Check for singalong warnings (needed for Venue display)
        local singalongWarnings = CheckSingalongWarnings(cursorPos)
        
        -- Draw Venue column (left, fixed width)
        local VENUE_COLUMN_WIDTH = 120
        reaper.ImGui_BeginGroup(ctx)
        reaper.ImGui_Text(ctx, "Venue:")
        reaper.ImGui_SameLine(ctx, VENUE_COLUMN_WIDTH)
        reaper.ImGui_Dummy(ctx, 0, 0)
        if venueTrack then
            local allVenueNotes = GetNotesAtPosition(venueTrack, cursorPos)
            
            -- Filter venue notes to only include pitches 37-41 and 85-87
            local venueNotes = {}
            for _, note in ipairs(allVenueNotes) do
                if (note.pitch >= 37 and note.pitch <= 41) or (note.pitch >= 85 and note.pitch <= 87) then
                    table.insert(venueNotes, note)
                end
            end
            
            -- Separate spotlight notes from other venue notes
            local spotlightNotes = {}
            local otherNotes = {}
            for _, note in ipairs(venueNotes) do
                if note.pitch >= 37 and note.pitch <= 41 then
                    table.insert(spotlightNotes, note)
                else
                    table.insert(otherNotes, note)
                end
            end
            
            -- Display other venue notes first
            for _, note in ipairs(otherNotes) do
                reaper.ImGui_Text(ctx, "  " .. note.name)
            end
            
            -- Display spotlight notes under "Spotlight:" header
            if #spotlightNotes > 0 then
                reaper.ImGui_Text(ctx, "  Spotlight:")
                for _, note in ipairs(spotlightNotes) do
                    -- Strip "Spotlight on " prefix for brevity
                    local shortName = note.name:gsub("^[Ss]potlight on ", "")
                    reaper.ImGui_Text(ctx, "    " .. shortName)
                end
            end
            
            -- Display singalong warnings under "No Singalong:" header
            if #singalongWarnings > 0 then
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_RED)
                reaper.ImGui_Text(ctx, "  No Singalong:")
                for _, warning in ipairs(singalongWarnings) do
                    local capitalized = warning:sub(1,1):upper() .. warning:sub(2)
                    reaper.ImGui_Text(ctx, "    " .. capitalized)
                end
                reaper.ImGui_PopStyleColor(ctx)
            end
        else
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
            reaper.ImGui_Text(ctx, "  (track not found)")
            reaper.ImGui_PopStyleColor(ctx)
        end
        reaper.ImGui_EndGroup(ctx)
        
        -- Camera block (fixed position to the right of Venue column)
        reaper.ImGui_SameLine(ctx, VENUE_COLUMN_WIDTH)
        reaper.ImGui_BeginGroup(ctx)
        if usingDirectedCut and directedCutDisplay.shouldShow then
            -- Draw directed cut with calculated frame
            reaper.ImGui_Text(ctx, "Camera: ")
            reaper.ImGui_SameLine(ctx, 0, 0)
            -- Show directed cut name with "(D)" indicator
            reaper.ImGui_Text(ctx, directedCutDisplay.noteName .. " (D)")
            
            if directedCutDisplay.spritesheet_data then
                DrawSpritesheetAtFrame(directedCutDisplay.spritesheet_data, directedCutDisplay.currentFrame)
            else
                reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
            end
            -- Clear fallback tracking
            camera_fallback_name = nil
            camera_fallback_for_note = nil
        elseif directedCutFallback then
            -- Directed cut just finished, show fallback camera
            reaper.ImGui_Text(ctx, "Camera: ")
            reaper.ImGui_SameLine(ctx, 0, 0)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
            reaper.ImGui_Text(ctx, directedCutFallback)
            reaper.ImGui_PopStyleColor(ctx)
            
            local spritesheet_data = FindSpritesheet("Camera", directedCutFallback)
            if spritesheet_data then
                DrawCameraSpritesheet(spritesheet_data, directedCutFallback)
            else
                reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
            end
            -- Clear fallback tracking
            camera_fallback_name = nil
            camera_fallback_for_note = nil
        elseif cameraNote then
            DrawSingleNoteBlock("Camera", cameraNote, "Camera", cameraIsGreyed)
            -- Clear fallback tracking when we have a valid note
            camera_fallback_name = nil
            camera_fallback_for_note = nil
        elseif cameraFilteredNote then
            -- No valid camera cut for instrument mode, show filtered note in red
            reaper.ImGui_Text(ctx, "Camera: ")
            reaper.ImGui_SameLine(ctx, 0, 0)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_RED)
            reaper.ImGui_Text(ctx, cameraFilteredNote.name)
            reaper.ImGui_PopStyleColor(ctx)
            
            -- Determine which fallback to show
            local fallbackName = nil
            
            -- First, try to get a single-char fallback for two-char shots (pitches 58-71)
            if cameraFilteredNote.pitch >= 58 and cameraFilteredNote.pitch <= 71 then
                fallbackName = GetSingleCharFallbackForDuo(cameraFilteredNote.name, instrument_mode)
            end
            
            -- If no single-char fallback, use random selection (but keep it consistent)
            if not fallbackName then
                -- Check if we need to pick a new random fallback
                if camera_fallback_for_note ~= cameraFilteredNote.name then
                    -- New filtered note, pick a random fallback
                    camera_fallback_for_note = cameraFilteredNote.name
                    local randomIndex = math.random(1, #FALLBACK_CAMERA_SPRITESHEETS)
                    camera_fallback_name = FALLBACK_CAMERA_SPRITESHEETS[randomIndex]
                end
                fallbackName = camera_fallback_name
            end
            
            -- Show the fallback video
            local spritesheet_data = FindSpritesheet("Camera", fallbackName)
            if spritesheet_data then
                DrawCameraSpritesheet(spritesheet_data, fallbackName)
            else
                reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
            end
        else
            DrawPlaceholderBlock("Camera", "none", true)
            -- Clear fallback tracking
            camera_fallback_name = nil
            camera_fallback_for_note = nil
        end
        reaper.ImGui_EndGroup(ctx)
        
        -- Draw instrument mode buttons to the right of Camera (stacked vertically)
        reaper.ImGui_SameLine(ctx, 0, 39)  -- 39px spacing to the right
        reaper.ImGui_BeginGroup(ctx)
        reaper.ImGui_Dummy(ctx, 1, 46)  -- 46px down
        
        -- GB button: light red if active+issue, blue if active, red if issue, default otherwise
        if gb_active and gb_has_issue then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xFF8888FF)
        elseif gb_active then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x4488FFFF)
        elseif gb_has_issue then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xFF4444FF)
        end
        if reaper.ImGui_Button(ctx, "GB", button_w) then
            instrument_mode = "GB"
        end
        if gb_active or gb_has_issue then
            reaper.ImGui_PopStyleColor(ctx)
        end
        
        -- KB button: light red if active+issue, blue if active, red if issue, default otherwise
        if kb_active and kb_has_issue then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xFF8888FF)
        elseif kb_active then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x4488FFFF)
        elseif kb_has_issue then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xFF4444FF)
        end
        if reaper.ImGui_Button(ctx, "KB", button_w) then
            instrument_mode = "KB"
        end
        if kb_active or kb_has_issue then
            reaper.ImGui_PopStyleColor(ctx)
        end
        
        -- GK button: light red if active+issue, blue if active, red if issue, default otherwise
        if gk_active and gk_has_issue then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xFF8888FF)
        elseif gk_active then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x4488FFFF)
        elseif gk_has_issue then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xFF4444FF)
        end
        if reaper.ImGui_Button(ctx, "GK", button_w) then
            instrument_mode = "GK"
        end
        if gk_active or gk_has_issue then
            reaper.ImGui_PopStyleColor(ctx)
        end
        
        reaper.ImGui_EndGroup(ctx)
        
        -- ========== ROW 2: Post-Processing + Lighting (side by side) ==========
        
        local postProcNotes = {}
        local postProcFadingNotes = {}  -- Notes that are fading out (ended but before next note starts)
        local postProcIncomingNote = nil  -- Next note fading in (overlaid on top of fading out)
        local postProcIncomingOpacity = 0  -- Opacity of incoming note (0 to 1)
        local postProcIsGreyed = false
        local postProcShowDefault = false  -- Special flag for default state
        if lightingTrack then
            local allNotes = GetNotesAtPosition(lightingTrack, cursorPos)
            for _, note in ipairs(allNotes) do
                if note.pitch >= POSTPROC_PITCH_MIN and note.pitch <= POSTPROC_PITCH_MAX then
                    -- Check if this is the Default note (pitch 71) - treat it specially
                    if note.pitch == POSTPROC_DEFAULT_PITCH then
                        postProcShowDefault = true
                    else
                        table.insert(postProcNotes, note)
                    end
                end
            end
            
            -- If only Default note is playing (or no notes at all), show default state
            if #postProcNotes == 0 then
                if not postProcShowDefault then
                    -- Check if we're before any post-processing notes
                    local firstPostProcTime = GetFirstPostProcNoteTime(lightingTrack)
                    if firstPostProcTime == nil or cursorPos < firstPostProcTime then
                        postProcShowDefault = true
                    end
                end
                
                if postProcShowDefault then
                    -- Show default with special handling
                    postProcIsGreyed = true
                end
            end
            
            -- Always check for fading notes (even when there are active notes)
            -- This allows ended notes to fade while other notes are still playing
            if not postProcShowDefault then
                local lastEndedNotes, lastEndTime = GetLastEndedPostProcNotesWithTime(lightingTrack, cursorPos)
                
                if #lastEndedNotes > 0 and lastEndTime then
                    -- Calculate fade opacity based on position between note-off and next note-on
                    local nextEventTime = GetNextPostProcEventTime(lightingTrack, lastEndTime)
                    
                    -- Skip fading if a new note starts exactly when the old one ended (seamless transition)
                    local seamlessTransition = nextEventTime and math.abs(nextEventTime - lastEndTime) < 0.001
                    
                    if not seamlessTransition then
                        local opacity = 1.0
                        
                        if nextEventTime then
                            -- Calculate how far we are between note-off and next note-on
                            local fadeWindow = nextEventTime - lastEndTime
                            local fadeProgress = (cursorPos - lastEndTime) / fadeWindow
                            opacity = math.max(0, 1.0 - fadeProgress)
                            
                            -- Find the incoming note and calculate its fade-in opacity
                            local nextNote = GetNextPostProcNote(lightingTrack, lastEndTime)
                            if nextNote and math.abs(nextNote.startTime - nextEventTime) < 0.001 then
                                postProcIncomingNote = nextNote
                                postProcIncomingOpacity = math.min(1.0, fadeProgress)
                            end
                        end
                        -- If no next event, keep at full opacity (greyed but visible)
                        
                        if opacity > 0 then
                            for _, note in ipairs(lastEndedNotes) do
                                -- Only add to fading notes if not currently active
                                local isActive = false
                                for _, activeNote in ipairs(postProcNotes) do
                                    if activeNote.pitch == note.pitch then
                                        isActive = true
                                        break
                                    end
                                end
                                if not isActive then
                                    note.fadeOpacity = opacity
                                    table.insert(postProcFadingNotes, note)
                                end
                            end
                        end
                    end
                end
                
                if #postProcNotes == 0 and #postProcFadingNotes == 0 then
                    postProcIsGreyed = true
                end
            end
        end
        
        -- Draw post-proc block
        reaper.ImGui_BeginGroup(ctx)
        if postProcShowDefault then
            -- Special handling for default: show BKNear first frame from Camera folder
            reaper.ImGui_Text(ctx, "Post-Proc: ")
            reaper.ImGui_SameLine(ctx, 0, 0)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
            reaper.ImGui_Text(ctx, "default")
            reaper.ImGui_PopStyleColor(ctx)
            local bkNearData = FindSpritesheet("Camera", "BKNear")
            DrawStaticFirstFrame(bkNearData)
        else
            -- Draw single active post-proc note (only one can be active at a time)
            if #postProcNotes > 0 then
                local note = postProcNotes[1]  -- Take the first (only) active note
                DrawSingleNoteBlock("Post-Proc", note, "PostProc", postProcIsGreyed)
            elseif #postProcFadingNotes > 0 then
                -- Draw single fading note with optional incoming note crossfade
                local note = postProcFadingNotes[1]
                
                -- Show incoming note name if available, otherwise show fading note name
                if postProcIncomingNote and postProcIncomingOpacity > 0 then
                    local inAlpha = math.floor(postProcIncomingOpacity * 255)
                    local inTextColor = 0xFFFFFF00 | inAlpha
                    reaper.ImGui_Text(ctx, "Post-Proc: ")
                    reaper.ImGui_SameLine(ctx, 0, 0)
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), inTextColor)
                    reaper.ImGui_Text(ctx, GetDisplayName(postProcIncomingNote.name))
                    reaper.ImGui_PopStyleColor(ctx)
                else
                    local textAlpha = math.floor(note.fadeOpacity * 128)
                    local fadedTextColor = 0x88888800 | textAlpha
                    reaper.ImGui_Text(ctx, "Post-Proc: ")
                    reaper.ImGui_SameLine(ctx, 0, 0)
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), fadedTextColor)
                    reaper.ImGui_Text(ctx, GetDisplayName(note.name))
                    reaper.ImGui_PopStyleColor(ctx)
                end
                
                -- Draw fading-out spritesheet
                local spritesheet_data
                if note.pitch == POSTPROC_DEFAULT_PITCH then
                    spritesheet_data = FindSpritesheet("Camera", "BKNear")
                else
                    spritesheet_data = FindSpritesheet("PostProc", note.name)
                end
                
                -- Remember position before drawing for incoming overlay
                local overlayX, overlayY = reaper.ImGui_GetCursorScreenPos(ctx)
                
                if spritesheet_data then
                    if note.pitch == POSTPROC_DEFAULT_PITCH then
                        DrawStaticFirstFrameWithOpacity(spritesheet_data, note.fadeOpacity)
                    else
                        DrawCameraSpritesheetWithOpacity(spritesheet_data, note.name, note.fadeOpacity)
                    end
                else
                    reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
                end
                
                -- Overlay incoming note spritesheet on top (fading in)
                if postProcIncomingNote and postProcIncomingOpacity > 0 then
                    local incomingData
                    if postProcIncomingNote.pitch == POSTPROC_DEFAULT_PITCH then
                        incomingData = FindSpritesheet("Camera", "BKNear")
                    else
                        incomingData = FindSpritesheet("PostProc", postProcIncomingNote.name)
                    end
                    if incomingData and incomingData.image and reaper.ImGui_ValidatePtr(incomingData.image, "ImGui_Image*") then
                        local image = incomingData.image
                        local frame_count = incomingData.frame_count or (SPRITE_COLS * SPRITE_ROWS)
                        local cols = incomingData.cols or SPRITE_COLS
                        local img_w, img_h = reaper.ImGui_Image_GetSize(image)
                        local tile_w = SPRITE_DISPLAY_W + SPRITE_BORDER * 2
                        local tile_h = SPRITE_DISPLAY_H + SPRITE_BORDER * 2
                        
                        -- Calculate current frame
                        local normalized = NormalizeNoteNameForFile(postProcIncomingNote.name)
                        current_active_notes[normalized] = true
                        if not last_active_notes[normalized] then
                            sprite_start_times[normalized] = reaper.time_precise()
                        end
                        local start_time = sprite_start_times[normalized] or reaper.time_precise()
                        local elapsed = reaper.time_precise() - start_time
                        local current_frame
                        if postProcIncomingNote.pitch == POSTPROC_DEFAULT_PITCH then
                            current_frame = 0
                        else
                            current_frame = math.floor(elapsed * SPRITE_FRAME_RATE) % frame_count
                        end
                        
                        local col = current_frame % cols
                        local row = math.floor(current_frame / cols)
                        local uv0_x = (col * tile_w + SPRITE_BORDER) / img_w
                        local uv0_y = (row * tile_h + SPRITE_BORDER) / img_h
                        local uv1_x = ((col + 1) * tile_w - SPRITE_BORDER) / img_w
                        local uv1_y = ((row + 1) * tile_h - SPRITE_BORDER) / img_h
                        
                        local alpha = math.floor(postProcIncomingOpacity * 255)
                        local tint_col = 0xFFFFFF00 | alpha
                        local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
                        reaper.ImGui_DrawList_AddImage(draw_list, image,
                            overlayX, overlayY,
                            overlayX + SPRITE_DISPLAY_W, overlayY + SPRITE_DISPLAY_H,
                            uv0_x, uv0_y, uv1_x, uv1_y, tint_col)
                    end
                end
            end
            
            -- If no post-proc notes at all, or only fading Default that has fully faded
            -- Check if we should show "default" after fade completes
            local showDefaultAfterFade = false
            if #postProcNotes == 0 and #postProcFadingNotes == 0 and not postProcShowDefault then
                -- Check if last ended note was Default (show default after it fades)
                local lastEndedAll = GetLastEndedNotesInRange(lightingTrack, cursorPos, POSTPROC_PITCH_MIN, POSTPROC_PITCH_MAX)
                for _, note in ipairs(lastEndedAll) do
                    if note.pitch == POSTPROC_DEFAULT_PITCH then
                        showDefaultAfterFade = true
                        break
                    end
                end
            end
            
            if showDefaultAfterFade then
                -- Show greyed "default" after Default note has fully faded
                reaper.ImGui_Text(ctx, "Post-Proc: ")
                reaper.ImGui_SameLine(ctx, 0, 0)
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
                reaper.ImGui_Text(ctx, "default")
                reaper.ImGui_PopStyleColor(ctx)
                local bkNearData = FindSpritesheet("Camera", "BKNear")
                DrawStaticFirstFrame(bkNearData)
            elseif #postProcNotes == 0 and #postProcFadingNotes == 0 and not postProcShowDefault then
                DrawPlaceholderBlock("Post-Proc", "none", true)
            end
        end
        reaper.ImGui_EndGroup(ctx)
        
        -- Same line for Lighting
        reaper.ImGui_SameLine(ctx)
        
        -- Draw Lighting block with prev/next/first notes in same group
        reaper.ImGui_BeginGroup(ctx)
        
        -- First line: Lighting label + note name, then right-aligned prev/next/first
        if lightingNote then
            reaper.ImGui_Text(ctx, "Lighting: ")
            reaper.ImGui_SameLine(ctx, 0, 0)
            if lightingIsGreyed then
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
            end
            reaper.ImGui_Text(ctx, lightingNote.name)
            if lightingIsGreyed then
                reaper.ImGui_PopStyleColor(ctx)
            end
        else
            reaper.ImGui_Text(ctx, "Lighting: ")
            reaper.ImGui_SameLine(ctx, 0, 0)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_GREY)
            reaper.ImGui_Text(ctx, "none")
            reaper.ImGui_PopStyleColor(ctx)
        end
        
        -- Add prev/next/first notes right-aligned on same line
        if #prevNextFirstNotes > 0 then
            local noteNamesText = ""
            for i, note in ipairs(prevNextFirstNotes) do
                if i > 1 then noteNamesText = noteNamesText .. ", " end
                noteNamesText = noteNamesText .. note.name
            end
            reaper.ImGui_SameLine(ctx)
            local availWidth = reaper.ImGui_GetContentRegionAvail(ctx)
            local textWidth = reaper.ImGui_CalcTextSize(ctx, noteNamesText)
            reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + availWidth - textWidth)
            reaper.ImGui_Text(ctx, noteNamesText)
        end
        
        -- Draw lighting spritesheet
        if lightingNote then
            local spritesheet_data = FindSpritesheet("Lighting", lightingNote.name)
            if spritesheet_data then
                if MANUAL_LIGHT_PITCHES[lightingNote.pitch] then
                    DrawManualLightingSpritesheet(spritesheet_data, lightingNote.name)
                else
                    DrawCameraSpritesheet(spritesheet_data, lightingNote.name)
                end
            else
                reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
            end
        else
            reaper.ImGui_Dummy(ctx, SPRITE_DISPLAY_W, SPRITE_DISPLAY_H)
        end
        
        reaper.ImGui_EndGroup(ctx)
        
        -- Update last_active_notes for next frame comparison
        last_active_notes = current_active_notes
        
        reaper.ImGui_End(ctx)
    end
    
    if open then
        reaper.defer(MainLoop)
    end
end

reaper.defer(MainLoop)
