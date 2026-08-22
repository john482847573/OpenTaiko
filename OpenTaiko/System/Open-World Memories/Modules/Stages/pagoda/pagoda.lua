-- pagoda.lua  —  Pagoda of the Unknown sub-module for dan_select

local NavInput = require("NavInput")
local selector = require("selector")

local M = {}

-- ── Song pools (loaded from pagoda_pools.json) ────────────────────────────────
-- Keys are integer level numbers; _get_pool() falls back downward if a level
-- has no dedicated pool entry.

local _pools_cache = nil

-- NLua cannot use pairs() on C# Dictionary objects; use GetEnumerator() instead.
local function _dict_iter(d)
    local e = d:GetEnumerator()
    return function()
        if e:MoveNext() then return e.Current.Key, e.Current.Value end
    end
end

local function _load_pools()
    if _pools_cache ~= nil then return _pools_cache end
    local raw = JSONLOADER:JsonParseFile("pagoda_pools.json")

    -- Parse a single entry object { "id": "...", "diff": N }
    local function parse_entry(e_obj)
        local id, diff = nil, 0
        for k, v in _dict_iter(e_obj) do
            if k == "id"   then id   = v end
            if k == "diff" then diff = tonumber(v) or 0 end
        end
        return id ~= nil and { id = id, diff = diff } or nil
    end

    -- Parse a pool object containing "blue", "green", "red", "purple" arrays
    local function parse_pool(raw_pool)
        local pool = {}
        for _, color in ipairs({ "blue", "green", "red", "purple" }) do
            pool[color] = {}
            -- find the color key among the pool's dictionary entries
            local raw_entries = nil
            for k, v in _dict_iter(raw_pool) do
                if k == color then raw_entries = v ; break end
            end
            if raw_entries ~= nil then
                for _, entry_obj in _dict_iter(raw_entries) do
                    local entry = parse_entry(entry_obj)
                    if entry ~= nil then table.insert(pool[color], entry) end
                end
            end
        end
        return pool
    end

    _pools_cache = {}
    for k, v in _dict_iter(raw) do
        local lv = tonumber(k)
        if lv ~= nil then
            _pools_cache[lv] = parse_pool(v)
        end
    end
    return _pools_cache
end

local function _get_pool(level)
    local pools = _load_pools()
    local lv = level
    while lv >= 1 do
        if pools[lv] ~= nil then return pools[lv] end
        lv = lv - 1
    end
    return pools[1]  -- ultimate fallback
end

-- ── Level helpers ─────────────────────────────────────────────────────────────

local KANJI_NUMS = { "一","二","三","四","五","六","七","八","九","十" }

local function _level_name(level)
    if level >= 1 and level <= 10 then
        -- 一題 … 十題
        return (KANJI_NUMS[level] or tostring(level)) .. "題"
    elseif level >= 11 and level <= 20 then
        -- level 11 → 扉一, level 20 → 扉十
        return "扉" .. (KANJI_NUMS[level - 10] or tostring(level - 10))
    else
        -- level 21 → 穹天1, level 22 → 穹天2, ...
        return "穹天" .. tostring(level - 20)
    end
end

local function _level_tick(level)
    if     level <= 10 then return 0
    elseif level <= 20 then return 2
    end
    return 4
end

local function _hsv_to_rgb(h, s, v)
    -- h in [0, 360], s and v in [0, 1]; returns r, g, b in [0, 255]
    local hi = math.floor(h / 60) % 6
    local f  = h / 60 - math.floor(h / 60)
    local p  = v * (1 - s)
    local q  = v * (1 - f * s)
    local t  = v * (1 - (1 - f) * s)
    local r, g, b
    if     hi == 0 then r, g, b = v, t, p
    elseif hi == 1 then r, g, b = q, v, p
    elseif hi == 2 then r, g, b = p, v, t
    elseif hi == 3 then r, g, b = p, q, v
    elseif hi == 4 then r, g, b = t, p, v
    else                r, g, b = v, p, q end
    return math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)
end

local function _level_tick_color(level)
    if level <= 10 then
        return { 139, 69, 19 }       -- brown (題)
    elseif level <= 20 then
        -- rainbow: blue (扉一) → red (扉八) → magenta (扉九) → magenta-purple (扉十)
        local d = level - 10             -- door index 1..10
        local h
        if d <= 8 then
            local t = (d - 1) / 7        -- 0.0 at 扉一, 1.0 at 扉八
            h = 240 * (1 - t)^1.4        -- 240° (blue) → 0° (red)
        else
            h = 360 - (d - 8) * 35       -- 扉九 → 325° (magenta), 扉十 → 290° (magenta-purple)
        end
        local r, g, b = _hsv_to_rgb(h, 0.88, 1.0)
        return { r, g, b }
    else
        return { 0, 0, 0 }           -- black (穹天)
    end
end

-- EXAM 1: Gauge thresholds (red / gold), range = More (player must reach)
local function _exam1_gauge(level)
    if level <= 5 then
        return 70, 80
    elseif level <= 10 then
        return 80, 90
    elseif level <= 20 then
        local n = level - 11
        return math.min(100, 90 + n), math.min(100, 95 + n)
    else
        return 100, 100
    end
end

-- EXAM 2: Accuracy % (kyuu/doors levels 1-20, More) or Ok count (穹天 levels 21+, Less)
-- Returns: type, red, gold, lessThan
local function _exam2(level)
    if level <= 20 then
        local t = {
            -- 題 (kyuu) 1-10 : Easy band 1-4, Normal band 5-7, Hard band 8-10 (accuracy resets at 8)
            [1]={78,88},  [2]={80,90},  [3]={84,92},  [4]={86,93},  [5]={88,94},
            [6]={90,95},  [7]={92,96},  [8]={70,85},  [9]={72,86},  [10]={75,87},
            -- 扉 (doors) 11-20 (was old doors 6-15)
            [11]={80,90}, [12]={84,92}, [13]={88,94}, [14]={90,95}, [15]={92,96},
            [16]={94,97}, [17]={95,97}, [18]={96,98}, [19]={97,98}, [20]={98,99},
        }
        local e = t[level] or {80, 90}
        return "a", e[1], e[2], false
    elseif level == 21 then return "jg", 50, 25, true
    elseif level == 22 then return "jg", 40, 20, true
    elseif level == 23 then return "jg", 30, 15, true
    elseif level == 24 then return "jg", 20, 10, true
    elseif level == 25 then return "jg", 15,  8, true
    elseif level == 26 then return "jg", 10,  5, true
    else
        -- level 27+: red -1/level, gold -1/2 levels, both floor at 1
        local n    = level - 27
        local red  = math.max(1, 10 - n)
        local gold = math.max(1, 5 - math.floor(n / 2))
        return "jg", red, gold, true
    end
end

-- EXAM 3: Bad count base values (red / gold); multiply by 1.25 (floor) if purple picked
local function _exam3_base(level)
    if level <= 20 then
        local t = {
            -- 題 (kyuu) 1-10
            [1]={32,22}, [2]={30,20}, [3]={28,19}, [4]={27,18}, [5]={26,18},
            [6]={25,18}, [7]={25,17}, [8]={24,17}, [9]={23,16}, [10]={22,16},
            -- 扉 (doors) 11-20 (was old doors 6-15)
            [11]={20,15}, [12]={16,12}, [13]={12,8}, [14]={10,7}, [15]={9,6},
            [16]={8,6},   [17]={7,5},   [18]={6,4},  [19]={5,3},  [20]={4,2},
        }
        local e = t[level] or {4, 2}
        return e[1], e[2]
    elseif level <= 23 then return 3, 1
    elseif level <= 26 then return 2, 1
    else                    return 1, 1
    end
end


local function _purple_prob(level)
    if     level <= 19 then return 0.10
    elseif level == 20 then return 1.00   -- 扉十 (last door): guaranteed purple
    elseif level <= 26 then return 0.10
    else
        -- level 27 → 0 %, level 28 → 10 %, level 29 → 20 %, …
        return math.max(0.0, math.min(1.0, (level - 27) * 0.10))
    end
end

local function _pick_entry(entries, used_ids)
    for _ = 1, 20 do
        local e = entries[math.random(#entries)]
        if not used_ids[e.id] then return e end
    end
    return entries[math.random(#entries)]   -- fallback: allow repeat
end

local function _shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
end

-- ── Persistent state (survives activate / deactivate) ─────────────────────────

local _pagoda_state    = "main_menu"
local _challenge_level = 1
local _practice_level  = 1
local _practice_hover  = nil     -- last floor hovered in practice, so it reopens there
local _in_challenge    = false   -- true  = we just exited to play (challenge)
local _in_practice     = false   -- true  = we just exited to play (practice)
local _song_list_cache    = nil
local _missing_song_count = nil   -- nil = not yet validated; >=0 after first check

-- Challenge-mode preview (pre-rolled songs + speed slider)
local _preview_songs   = nil    -- { {color, node, entry}, ... } for blue/green/red
local _preview_purple  = nil    -- { node, entry } or nil
local _preview_level   = -1     -- which level the preview was rolled for
local _preview_speed   = 20     -- current slider value

-- ── Per-activation state ──────────────────────────────────────────────────────

local _CB                 = nil
local _font_hero          = nil   -- big title-screen heading
local _font_title         = nil
local _font_body          = nil
local _font_hint          = nil
local _status_msg         = ""
local _status_timer       = 0.0
local _menu_sel           = 1
local _practice_sel       = 1
local _result_was_clear   = false
local _btn_timer          = 0.0

local NP_X            = 20
local NP_Y            = 980

-- ── Song list ────────────────────────────────────────────────────────────────

local function _get_song_list()
    if _song_list_cache ~= nil then return _song_list_cache end
    local lsls = GenerateSongListSettings()
    lsls.AppendMainRandomBox  = false
    lsls.AppendSubRandomBoxes = false
    lsls.FlattenOpenedFolders = true
    _song_list_cache = RequestSongList(lsls)
    return _song_list_cache
end

-- ── Pool validation ──────────────────────────────────────────────────────────

local function _count_missing_songs()
    local pools = _load_pools()
    if pools == nil then return 0 end

    local lsls = GenerateSongListSettings()
    lsls.AppendMainRandomBox  = false
    lsls.AppendSubRandomBoxes = false
    lsls.FlattenOpenedFolders = true
    lsls.ExcludeHiddenSongs   = false
    local sl = RequestSongList(lsls)

    local diff_names = { [0] = "Easy", [1] = "Normal", [2] = "Hard", [3] = "Oni", [4] = "Edit" }

    local seen    = {}
    local missing = 0
    for _, pool in pairs(pools) do
        for _, color in ipairs({ "blue", "green", "red", "purple" }) do
            local entries = pool[color]
            if entries ~= nil then
                for _, entry in ipairs(entries) do
                    local key = (entry.id or "") .. "\0" .. tostring(entry.diff)
                    if not seen[key] then
                        seen[key] = true
                        local node  = sl:GetSongByUniqueId(entry.id)
                        local diff  = diff_names[entry.diff] or tostring(entry.diff)
                        if node == nil then
                            debugLog("[Pagoda] Missing song – id: " .. tostring(entry.id) .. "  diff: " .. diff)
                            missing = missing + 1
                        elseif node:GetChart(entry.diff) == nil then
                            local title = node.Title or entry.id
                            debugLog("[Pagoda] Missing difficulty – \"" .. title .. "\"  id: " .. tostring(entry.id) .. "  diff: " .. diff)
                            missing = missing + 1
                        end
                    end
                end
            end
        end
    end
    return missing
end

-- ── Persistence helpers ───────────────────────────────────────────────────────

local function _highest_level()
    return math.max(1, math.floor(GetSaveFile(0):GetGlobalCounter("pagoda_highest_level")))
end

local function _set_highest_level(level)
    if level > _highest_level() then
        GetSaveFile(0):SetGlobalCounter("pagoda_highest_level", level)
    end
end

-- exposed for Script.lua: the title screen draws the selector's tower scene, which needs the
-- highest reached level to darken the undiscovered doors identically to the floor selector
function M.highest_level() return _highest_level() end

-- One-time migration for the 題/扉/穹天 restructure: the kyuu range grew from 5 to 10 levels and the
-- 扉/穹天 tiers shifted +5, so a saved highest_level from before this update must be renumbered or the
-- player would lose progress / start-point unlocks. Old level → new level:
--   kyuu 1..5 → 2, 3, 5, 8, 10   (the old kyuu pools now live at those positions)
--   anything ≥ 6 (扉/屋根) → +5
-- Version-gated so it runs exactly once; brand-new saves (highest 0) are left untouched.
local function _migrate_save()
    local sf = GetSaveFile(0)
    if math.floor(sf:GetGlobalCounter("pagoda_structure_version")) >= 2 then return end
    local old = math.floor(sf:GetGlobalCounter("pagoda_highest_level"))
    if old >= 1 then
        local KYUU = { [1] = 2, [2] = 3, [3] = 5, [4] = 8, [5] = 10 }
        local new  = (old <= 5) and (KYUU[old] or old) or (old + 5)
        sf:SetGlobalCounter("pagoda_highest_level", new)
    end
    sf:SetGlobalCounter("pagoda_structure_version", 2)
end

-- Returns the checkpoint level to restart from when failing at `level`.
local function _checkpoint_for(level)
    if level >= 21     then return 21
    elseif level >= 16 then return 16
    elseif level >= 11 then return 11
    elseif level >= 6  then return 6
    else                    return 1
    end
end

-- Returns the list of valid challenge starting levels for the current save.
--   一題(1) / 六題(6) / 扉一(11) always ; 扉六(16) after clearing 扉五(15) ; 穹天1(21) after 扉十(20)
local function _start_options()
    local highest = _highest_level()
    local opts = { 1, 6, 11 }
    if highest >= 15 then table.insert(opts, 16) end
    if highest >= 20 then table.insert(opts, 21) end
    return opts
end

-- Open the shared floor selector for challenge (checkpoints) or practice (every beaten level).
local function _selector_info()
    return { name = _level_name, color = _level_tick_color, highest = _highest_level() }
end

local function _open_checkpoint_select()
    selector.open("checkpoint", _start_options(), _challenge_level, _selector_info())
end

local function _open_practice_select()
    local highest = math.max(_highest_level(), 11)
    local levels = {}
    for lv = 1, highest do levels[#levels + 1] = lv end
    -- reopen on the last hovered floor; selector.open() falls back to the bottom floor
    -- if that level isn't in the list (the "is it still playable" gate)
    selector.open("practice", levels, _practice_hover or _practice_level, _selector_info())
end

-- ── Challenge preview (pre-rolled song selection) ────────────────────────────

local DIFF_NAMES = { [0] = "Easy", [1] = "Normal", [2] = "Hard", [3] = "Oni", [4] = "Edit" }

local function _spd_range(level)
    local SPEED = CONFIG.SONGSPEED
    -- speed starts ramping at 穹天18 (level 38); below that it stays x1
    local min = (level >= 38) and (1 + (level - 37) / SPEED.ScaleFromActual) or 1
    local max = min + 1
    return SPEED:FromActual(min), SPEED:FromActual(max)
end

-- Roll and cache the songs that will be used for the given challenge level.
-- Also initialises _preview_speed for the slider.
local function _build_preview(level)
    _preview_songs  = {}
    _preview_purple = nil
    _preview_level  = level

    -- Initialise speed to x1 (or the level-scaled base for lv33+)
    local spd_min = _spd_range(level)
    _preview_speed = spd_min

    local sl   = _get_song_list()
    local pool = _get_pool(level)
    if pool == nil then return end

    local used_ids = {}
    local colors = { "blue", "green", "red" }
    _shuffle(colors)

    for _, color in ipairs(colors) do
        local entries = pool[color]
        if entries ~= nil and #entries > 0 then
            local entry = _pick_entry(entries, used_ids)
            if entry ~= nil then
                local node = sl:GetSongByUniqueId(entry.id)
                if node ~= nil and node.NotNull then
                    table.insert(_preview_songs, { color = color, node = node, entry = entry })
                    used_ids[entry.id] = true
                end
            end
        end
    end

    if math.random() < _purple_prob(level) then
        local entries = pool["purple"]
        if entries ~= nil and #entries > 0 then
            local entry = _pick_entry(entries, used_ids)
            if entry ~= nil then
                local node = sl:GetSongByUniqueId(entry.id)
                if node ~= nil and node.NotNull then
                    _preview_purple = { node = node, entry = entry }
                end
            end
        end
    end
end

local function _clear_preview()
    _preview_songs  = nil
    _preview_purple = nil
    _preview_level  = -1
end

-- ── Dan building ─────────────────────────────────────────────────────────────

local function _build_dan(level)
    local tc = _level_tick_color(level)

    DANBUILDER:Clear()
    DANBUILDER:SetTitle(_level_name(level))
    DANBUILDER:SetDanTick(_level_tick(level))
    DANBUILDER:SetDanTickColor(tc[1], tc[2], tc[3])

    local added_count = 0
    local had_purple  = false

    if _preview_songs ~= nil and _preview_level == level then
        -- Use pre-rolled songs from the preview
        for _, item in ipairs(_preview_songs) do
            DANBUILDER:AddSong(item.node, item.entry.diff)
            added_count = added_count + 1
        end
        if _preview_purple ~= nil then
            DANBUILDER:AddSong(_preview_purple.node, _preview_purple.entry.diff)
            added_count = added_count + 1
            had_purple  = true
        end
        _clear_preview()
    else
        -- Fallback: roll fresh (practice mode, or no preview cached)
        local sl   = _get_song_list()
        local pool = _get_pool(level)
        local used_ids = {}
        local colors = { "blue", "green", "red" }
        _shuffle(colors)

        for _, color in ipairs(colors) do
            local entries = pool[color]
            if entries ~= nil and #entries > 0 then
                local entry = _pick_entry(entries, used_ids)
                if entry ~= nil then
                    local node = sl:GetSongByUniqueId(entry.id)
                    if node ~= nil and node.NotNull then
                        DANBUILDER:AddSong(node, entry.diff)
                        used_ids[entry.id] = true
                        added_count = added_count + 1
                    end
                end
            end
        end

        if math.random() < _purple_prob(level) then
            local entries = pool["purple"]
            if entries ~= nil and #entries > 0 then
                local entry = _pick_entry(entries, used_ids)
                if entry ~= nil then
                    local node = sl:GetSongByUniqueId(entry.id)
                    if node ~= nil and node.NotNull then
                        DANBUILDER:AddSong(node, entry.diff)
                        added_count = added_count + 1
                        had_purple  = true
                    end
                end
            end
        end

        -- Use default speed when no preview (practice, or missing cache)
        _preview_speed = _spd_range(level)
    end

    if added_count == 0 then return false end

    -- EXAM 1: Gauge
    local g_red, g_gold = _exam1_gauge(level)
    DANBUILDER:SetGlobalExam(1, "g", g_red, g_gold, false)

    -- EXAM 2: Accuracy (題/扉 levels 1-20, More) / Ok count (穹天 levels 21+, Less)
    local e2_type, e2_red, e2_gold, e2_less = _exam2(level)
    DANBUILDER:SetGlobalExam(2, e2_type, e2_red, e2_gold, e2_less)

    -- EXAM 3: Bad count (Less); purple multiplies threshold by 1.25 (floor)
    local bad_red, bad_gold = _exam3_base(level)
    if had_purple then
        bad_red  = math.floor(bad_red  * 1.25)
        bad_gold = math.floor(bad_gold * 1.25)
    end
    DANBUILDER:SetGlobalExam(3, "jb", bad_red, bad_gold, true)

    CONFIG.SongSpeed = _preview_speed
    CONFIG:SetAutoStatus(0, false)

    return DANBUILDER:Mount()
end

-- ── Draw helpers ─────────────────────────────────────────────────────────────

local function _ensure_fonts()
    if _font_title ~= nil then return end
    _font_hero  = TEXT:Create(72, "regular")
    _font_title = TEXT:Create(44, "regular")
    _font_body  = TEXT:Create(32, "regular")
    _font_hint  = TEXT:Create(22, "regular")
end

-- Skin-locale string with an English fallback (skin Locales/*.json via THEME).
local function _sk(key, fallback)
    local s = THEME:GetSkinString(key)
    if s == nil or s == "" then return fallback end
    return s
end

local function _set_status(msg, t)
    _status_msg   = msg
    _status_timer = t or 2.0
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.is_returning_from_play()
    return _in_challenge or _in_practice
end

-- Called when the player selects Pagoda from the 3-way menu
function M.enter(CB)
    _CB    = CB
    _migrate_save()
    _btn_timer    = 0.15
    _status_msg   = ""
    _status_timer = 0.0
    _ensure_fonts()

    if _missing_song_count == nil then
        _missing_song_count = _count_missing_songs()
    end

    if _missing_song_count > 0 then
        _pagoda_state = "missing_songs"
    else
        _pagoda_state = "main_menu"
        _menu_sel     = 1
    end

    local chara = GetSaveFile(0):GetCharacter()
    if chara ~= nil and chara.IsValid then chara:LoadAnimation(CHARACTER.ANIM_MENU_NORMAL) end
end

-- Called when the player returns to the 3-way menu
function M.leave()
    _in_challenge = false
    _in_practice  = false
    _pagoda_state = "main_menu"
    M.deactivate()
end

-- Called from Script.lua's activate() whenever the pagoda module is active
function M.activate(CB)
    _CB = CB
    _migrate_save()
    _btn_timer = 0.15
    _ensure_fonts()

    local chara = GetSaveFile(0):GetCharacter()
    if chara ~= nil and chara.IsValid then chara:LoadAnimation(CHARACTER.ANIM_MENU_NORMAL) end
end

-- Called from Script.lua's deactivate()
function M.deactivate()
    local chara = GetSaveFile(0):GetCharacter()
    if chara ~= nil and chara.IsValid then chara:DisposeAnimation(CHARACTER.ANIM_MENU_NORMAL) end
end

-- Called in Script.lua's activate() after activate(), only when is_returning_from_play() is true.
-- PLAYSTATE still holds valid data from the just-completed dan at this point.
function M.on_return(CB)
    _CB = CB
    local passed = not PLAYSTATE:WasPlayAborted() and PLAYSTATE:IsPass()
    _result_was_clear = passed

    if _in_challenge then
        _in_challenge = false
        if passed then
            _set_highest_level(_challenge_level)   -- record the level we just cleared
            _challenge_level = _challenge_level + 1
            _pagoda_state = "level_clear"
        else
            _pagoda_state = "game_over"
        end
    elseif _in_practice then
        -- practice has no result screen: drop straight back onto the selector, on the floor
        -- that was just played (the last hover)
        _in_practice  = false
        _pagoda_state = "practice_select"
        _open_practice_select()
    end

    _menu_sel  = 1
    _btn_timer = 0.15
end

function M.afterSongEnum()
    _song_list_cache    = nil
    _pools_cache        = nil
    _missing_song_count = nil
    _clear_preview()
end

function M.destroy()
    if _font_hero  ~= nil then _font_hero:Dispose()  ; _font_hero  = nil end
    if _font_title ~= nil then _font_title:Dispose() ; _font_title = nil end
    if _font_body  ~= nil then _font_body:Dispose()  ; _font_body  = nil end
    if _font_hint  ~= nil then _font_hint:Dispose()  ; _font_hint  = nil end
end

-- Returns: nil | "back" (return to 3-way menu) | "play" (exit to play)
function M.update(dt)
    if _CB then
        for _, c in pairs(_CB.ctx) do c:Tick() end
    end

    _btn_timer    = math.max(0, _btn_timer - dt)
    _status_timer = math.max(0, _status_timer - dt)

    local navPn = NavInput.p[1]
    if INPUT:Pressed("ToggleAutoP1") then
        CONFIG:SetAutoStatus(0, not CONFIG:GetAutoStatus(0))
        SHARED:GetSharedSound("Move"):Play()
    end

    if _btn_timer > 0 then return nil end

    local up_p   = navPn.upOrPadLeft()
    local down_p = navPn.downOrPadRight()
    local ok_p   = navPn.decide()
    local back_p = navPn.cancel()

    -- ── MISSING SONGS ──────────────────────────────────────────────────────────
    if _pagoda_state == "missing_songs" then
        if ok_p or back_p then
            SHARED:GetSharedSound("Cancel"):Play()
            return "back"
        end
        return nil
    end

    -- ── MAIN MENU ──────────────────────────────────────────────────────────────
    if _pagoda_state == "main_menu" then
        if up_p   then
            _menu_sel = math.max(1, _menu_sel - 1)
            SHARED:GetSharedSound("Move"):Play()
        end
        if down_p then
            _menu_sel = math.min(3, _menu_sel + 1)
            SHARED:GetSharedSound("Move"):Play()
        end
        if back_p then
            SHARED:GetSharedSound("Cancel"):Play()
            return "back"
        end
        if ok_p then
            if _menu_sel == 1 then
                _pagoda_state = "start_choice"
                _open_checkpoint_select()
                SHARED:GetSharedSound("Decide"):Play()
            elseif _menu_sel == 2 then
                _pagoda_state = "practice_select"
                _open_practice_select()
                SHARED:GetSharedSound("Decide"):Play()
            elseif _menu_sel == 3 then
                SHARED:GetSharedSound("Cancel"):Play()
                return "back"
            end
        end
        return nil
    end

    -- ── START CHOICE (checkpoint selector) ──────────────────────────────────────
    if _pagoda_state == "start_choice" then
        local r = selector.update(dt, navPn)
        if r == "exit" then
            selector.close()
            _pagoda_state = "main_menu" ; _menu_sel = 1   -- back to title on "Challenge"
        elseif type(r) == "table" and r.sel ~= nil then
            selector.close()
            _challenge_level = r.sel
            _build_preview(_challenge_level)
            _pagoda_state = "level_preview"
        end
        return nil
    end

    -- ── LEVEL PREVIEW (challenge) ───────────────────────────────────────────────
    if _pagoda_state == "level_preview" then
        local highest  = _highest_level()
        local is_past  = (_challenge_level < highest)
        local spd_min, spd_max = _spd_range(_challenge_level)

        -- Speed slider (left/right), only for already-cleared levels
        if is_past then
            if navPn.left()  then
                _preview_speed = math.max(spd_min, _preview_speed - 1)
                SHARED:GetSharedSound("Move"):Play()
            end
            if navPn.right() then
                _preview_speed = math.min(spd_max, _preview_speed + 1)
                SHARED:GetSharedSound("Move"):Play()
            end
        end

        if back_p then
            _clear_preview()
            _pagoda_state = "main_menu" ; _menu_sel = 1
            SHARED:GetSharedSound("Cancel"):Play()
            return nil
        end
        if ok_p then
            local ok = _build_dan(_challenge_level)
            if ok then
                _in_challenge = true
                if _CB ~= nil then _CB.stopBGM() end
                SHARED:GetSharedSound("SongDecide"):Play()
                return "play"
            else
                SHARED:GetSharedSound("Error"):Play()
                _set_status("Failed to load songs!", 3.0)
            end
        end
        return nil
    end

    -- ── LEVEL CLEAR ────────────────────────────────────────────────────────────
    if _pagoda_state == "level_clear" then
        if up_p or navPn.left() then
            _menu_sel = math.max(1, _menu_sel - 1)
            SHARED:GetSharedSound("Move"):Play()
        end
        if down_p or navPn.right() then
            _menu_sel = math.min(2, _menu_sel + 1)
            SHARED:GetSharedSound("Move"):Play()
        end
        if ok_p or back_p then
            if _menu_sel == 1 and not back_p then
                _build_preview(_challenge_level)
                _pagoda_state = "level_preview"
                SHARED:GetSharedSound("Decide"):Play()
            else
                _pagoda_state = "main_menu" ; _menu_sel = 1
                SHARED:GetSharedSound("Cancel"):Play()
                if _CB ~= nil then _CB.startBGM() end
            end
        end
        return nil
    end

    -- ── GAME OVER ──────────────────────────────────────────────────────────────
    if _pagoda_state == "game_over" then
        if up_p or navPn.left() then
            _menu_sel = math.max(1, _menu_sel - 1)
            SHARED:GetSharedSound("Move"):Play()
        end
        if down_p or navPn.right() then
            _menu_sel = math.min(2, _menu_sel + 1)
            SHARED:GetSharedSound("Move"):Play()
        end
        if ok_p or back_p then
            if _menu_sel == 1 and not back_p then
                local cp = _checkpoint_for(_challenge_level)
                _challenge_level = cp
                _build_preview(cp)
                _pagoda_state = "level_preview"
                SHARED:GetSharedSound("Decide"):Play()
            else
                _pagoda_state = "main_menu" ; _menu_sel = 1
                SHARED:GetSharedSound("Cancel"):Play()
                if _CB ~= nil then _CB.startBGM() end
            end
        end
        return nil
    end

    -- ── PRACTICE SELECT (level selector) ────────────────────────────────────────
    -- The selector runs the sword "Accept the Challenge?" confirm itself, so a returned
    -- selection is already confirmed — build the dan and play straight away.
    if _pagoda_state == "practice_select" then
        local r = selector.update(dt, navPn)
        if r == "exit" then
            selector.close()
            _pagoda_state = "main_menu" ; _menu_sel = 2   -- back to title on "Practice"
        elseif type(r) == "table" and r.sel ~= nil then
            selector.close()
            _practice_level = r.sel
            if _build_dan(_practice_level) then
                _in_practice = true
                if _CB ~= nil then _CB.stopBGM() end
                return "play"
            else
                SHARED:GetSharedSound("Error"):Play()
                _open_practice_select()                   -- reopen and let them try again
            end
        else
            _practice_hover = selector.hovered_level() or _practice_hover   -- remember the floor
        end
        return nil
    end

    -- ── PRACTICE PREVIEW ───────────────────────────────────────────────────────
    if _pagoda_state == "practice_preview" then
        if up_p or navPn.left() then
            _menu_sel = math.max(1, _menu_sel - 1)
            SHARED:GetSharedSound("Move"):Play()
        end
        if down_p or navPn.right() then
            _menu_sel = math.min(2, _menu_sel + 1)
            SHARED:GetSharedSound("Move"):Play()
        end
        if back_p then
            SHARED:GetSharedSound("Cancel"):Play()
            _pagoda_state = "practice_select" ; _open_practice_select() ; return nil
        end
        if ok_p then
            if _menu_sel == 1 then
                local ok = _build_dan(_practice_level)
                if ok then
                    _in_practice = true
                    if _CB ~= nil then _CB.stopBGM() end
                    SHARED:GetSharedSound("SongDecide"):Play()
                    return "play"
                else
                    SHARED:GetSharedSound("Error"):Play()
                    _set_status("Failed to load songs!", 3.0)
                end
            else
                _pagoda_state = "practice_select"
                _open_practice_select()
                SHARED:GetSharedSound("Cancel"):Play()
            end
        end
        return nil
    end

    -- ── PRACTICE RESULT ────────────────────────────────────────────────────────
    if _pagoda_state == "practice_result" then
        if ok_p or back_p then
            _pagoda_state = "practice_select"
            _open_practice_select()
            SHARED:GetSharedSound("Cancel"):Play()
            if _CB ~= nil then _CB.startBGM() end
        end
        return nil
    end

    return nil
end

-- ── Draw ─────────────────────────────────────────────────────────────────────

function M.draw()
    if _font_title == nil then return end

    local res   = THEME:GetResolution()
    local res_w = res.X
    local res_h = res.Y
    local cx    = res_w / 2

    local C_WHITE  = COLOR:CreateColorFromRGBA(255, 255, 255, 255)
    local C_DIM    = COLOR:CreateColorFromRGBA(180, 180, 180, 220)
    local C_SEL    = COLOR:CreateColorFromRGBA(255, 220,  80, 255)
    local C_PASS   = COLOR:CreateColorFromRGBA(100, 255, 150, 255)
    local C_FAIL   = COLOR:CreateColorFromRGBA(255,  80,  80, 255)

    local function opt(label, x, y, sel)
        _font_body:GetText(label, false, 900, sel and C_SEL or C_DIM):DrawAtAnchor(x, y, "center")
    end

    local function level_color(level)
        local tc = _level_tick_color(level)
        return COLOR:CreateColorFromRGBA(tc[1], tc[2], tc[3], 255)
    end

    local base_y = res_h / 2

    -- ── MISSING SONGS ──────────────────────────────────────────────────────────
    if _pagoda_state == "missing_songs" then
        _font_body:GetText("Some songs are missing to play this game mode",    false, 900, C_FAIL):DrawAtAnchor(cx, base_y - 40,  "center")
        _font_body:GetText("Please update the OpenTaiko soundtrack and try again", false, 900, C_WHITE):DrawAtAnchor(cx, base_y + 20, "center")
        _font_hint:GetText("(Missing song count: " .. tostring(_missing_song_count) .. ")", false, 600, C_DIM):DrawAtAnchor(cx, base_y + 80, "center")
        _font_hint:GetText("Press any button to go back", false, 600, C_DIM):DrawAtAnchor(cx, base_y + 130, "center")

    -- ── TITLE SCREEN (main menu) ────────────────────────────────────────────────
    -- The stage draws the day-sky + the selector's tower scene behind this; here we
    -- lay the heading over the upper half, the best rank just below it, and the
    -- Challenge / Practice / Exit options across the lower half.
    elseif _pagoda_state == "main_menu" then
        _font_hero:GetText(_sk("PAGODA_TITLE", "Pagoda of the Unknown"), false, 1600, C_WHITE)
            :DrawAtAnchor(cx, res_h * 0.24, "center")

        local hl = _highest_level()
        _font_body:GetText(
            _sk("PAGODA_BEST", "Best") .. ":  " .. _level_name(hl) .. "  (Lv." .. tostring(hl) .. ")",
            false, 900, level_color(hl)):DrawAtAnchor(cx, res_h * 0.40, "center")

        opt(_sk("PAGODA_CHALLENGE", "Challenge"), cx, res_h * 0.58, _menu_sel == 1)
        opt(_sk("PAGODA_PRACTICE",  "Practice"),  cx, res_h * 0.68, _menu_sel == 2)
        opt(_sk("PAGODA_EXIT",      "Exit"),      cx, res_h * 0.78, _menu_sel == 3)
        -- (input-helper hints intentionally omitted for now — design TBD)

    -- ── START CHOICE (checkpoint selector) ──────────────────────────────────────
    elseif _pagoda_state == "start_choice" then
        selector.draw()

    -- ── LEVEL PREVIEW ──────────────────────────────────────────────────────────
    elseif _pagoda_state == "level_preview" then
        local lv      = _challenge_level
        local name    = _level_name(lv)
        local highest = _highest_level()
        local is_past = (lv < highest)
        local gap     = highest - lv   -- levels below the frontier

        _font_title:GetText("Challenge  " .. name, false, 800, level_color(lv)):DrawAtAnchor(cx, base_y - 200, "center")
        _font_hint:GetText("Lv." .. tostring(lv), false, 200, C_DIM):DrawAtAnchor(cx, base_y - 150, "center")

        local prob = _purple_prob(lv)
        local sc_text
        if prob <= 0.0 then
            sc_text = "3 songs"
        elseif prob >= 1.0 then
            sc_text = "4 songs"
        else
            sc_text = string.format("3~4 songs (Purple %d%%)", math.floor(prob * 100))
        end
        _font_hint:GetText("Songs: " .. sc_text, false, 500, C_DIM):DrawAtAnchor(cx, base_y - 115, "center")

        -- local gr, gg = _exam1_gauge(lv)
        -- _font_hint:GetText(
        --     string.format("Clear condition: gauge %d%% (red) / %d%% (gold)", gr, gg),
        --     false, 700, C_DIM):DrawAtAnchor(cx, base_y - 82, "center")

        -- Speed slider — only for levels the player has already passed
        if is_past then
            local spd_min, spd_max = _spd_range(lv)
            local SPEED = CONFIG.SONGSPEED
            local spd_label = string.format("◄  Speed  x%.2f  ►      min x%.2f  /  max x%.2f",
                SPEED:ToActual(_preview_speed), SPEED:ToActual(spd_min), SPEED:ToActual(spd_max))
            _font_hint:GetText(spd_label, false, 800, C_SEL):DrawAtAnchor(cx, base_y - 50, "center")
        end

        -- Song list reveal
        if is_past and gap > 3 and _preview_songs ~= nil then
            local reveal_purple = (gap > 5)
            local list_y        = base_y - 10
            local COLOR_LABELS  = { blue = "Blue", green = "Green", red = "Red" }
            for i, item in ipairs(_preview_songs) do
                local title = (item.node ~= nil) and (item.node.Title or "???") or "???"
                local diff  = (item.entry ~= nil) and (DIFF_NAMES[item.entry.diff] or "?") or "?"
                local lbl   = string.format("[ %s ]  %s  (%s)",
                    COLOR_LABELS[item.color] or item.color, title, diff)
                _font_hint:GetText(lbl, false, 700, C_DIM):DrawAtAnchor(cx, list_y + (i - 1) * 30, "center")
            end
            -- Purple slot
            local purple_y = list_y + 3 * 30
            if reveal_purple then
                if _preview_purple ~= nil then
                    local title = (_preview_purple.node ~= nil) and (_preview_purple.node.Title or "???") or "???"
                    local diff  = (_preview_purple.entry ~= nil) and (DIFF_NAMES[_preview_purple.entry.diff] or "?") or "?"
                    local lbl   = string.format("[ Purple ]  %s  (%s)", title, diff)
                    local C_PURPLE = COLOR:CreateColorFromRGBA(200, 100, 255, 220)
                    _font_hint:GetText(lbl, false, 700, C_PURPLE):DrawAtAnchor(cx, purple_y, "center")
                else
                    _font_hint:GetText("[ Purple ]  —  (none)", false, 700, C_DIM):DrawAtAnchor(cx, purple_y, "center")
                end
            else
                local C_MYS = COLOR:CreateColorFromRGBA(160, 100, 200, 180)
                _font_hint:GetText("[ ??? ]  A mysterious force lurks beyond...", false, 700, C_MYS):DrawAtAnchor(cx, purple_y, "center")
            end
        end

        -- Start / Cancel (Confirm / Cancel buttons — no menu_sel)
        local C_START = COLOR:CreateColorFromRGBA(100, 255, 150, 255)
        _font_body:GetText("Confirm  —  Start", false, 900, C_START):DrawAtAnchor(cx, base_y + 145, "center")
        _font_body:GetText("Cancel  —  Back",   false, 900, C_DIM):DrawAtAnchor(cx, base_y + 205, "center")

    -- ── LEVEL CLEAR ────────────────────────────────────────────────────────────
    elseif _pagoda_state == "level_clear" then
        local cleared_name = _level_name(_challenge_level - 1)
        local next_name    = _level_name(_challenge_level)
        _font_title:GetText("CLEAR!", false, 600, C_PASS):DrawAtAnchor(cx, base_y - 130, "center")
        _font_body:GetText(cleared_name .. " cleared!", false, 700, C_WHITE):DrawAtAnchor(cx, base_y - 65, "center")
        _font_hint:GetText(
            "Next: " .. next_name .. "  (Lv." .. tostring(_challenge_level) .. ")",
            false, 700, C_DIM):DrawAtAnchor(cx, base_y - 15, "center")
        opt("Continue", cx - 130, base_y + 70, _menu_sel == 1)
        opt("Quit",     cx + 130, base_y + 70, _menu_sel == 2)

    -- ── GAME OVER ──────────────────────────────────────────────────────────────
    elseif _pagoda_state == "game_over" then
        local failed_name = _level_name(_challenge_level)
        _font_title:GetText("GAME OVER", false, 600, C_FAIL):DrawAtAnchor(cx, base_y - 130, "center")
        _font_body:GetText("Failed at " .. failed_name, false, 700, C_WHITE):DrawAtAnchor(cx, base_y - 65, "center")
        local hl = _highest_level()
        _font_hint:GetText(
            "Highest reached: " .. _level_name(hl) .. "  (Lv." .. tostring(hl) .. ")",
            false, 600, C_DIM):DrawAtAnchor(cx, base_y - 15, "center")
        local cp = _checkpoint_for(_challenge_level)
        local retry_lbl = (cp == _challenge_level) and "Retry" or ("Retry from Lv." .. tostring(cp))
        opt(retry_lbl,   cx, base_y + 70, _menu_sel == 1)
        opt("Main menu", cx, base_y + 130, _menu_sel == 2)

    -- ── PRACTICE SELECT (level selector) ────────────────────────────────────────
    elseif _pagoda_state == "practice_select" then
        selector.draw()

    -- ── PRACTICE PREVIEW ───────────────────────────────────────────────────────
    elseif _pagoda_state == "practice_preview" then
        local lv   = _practice_level
        local name = _level_name(lv)
        _font_title:GetText("Practice  " .. name, false, 800, level_color(lv)):DrawAtAnchor(cx, base_y - 130, "center")
        -- local gr, gg = _exam1_gauge(lv)
        -- _font_hint:GetText(
        --     string.format("Clear condition: gauge %d%% (red) / %d%% (gold)", gr, gg),
        --     false, 700, C_DIM):DrawAtAnchor(cx, base_y - 40, "center")
        opt("Start",  cx - 130, base_y + 50, _menu_sel == 1)
        opt("Cancel", cx + 130, base_y + 50, _menu_sel == 2)

    -- ── PRACTICE RESULT ────────────────────────────────────────────────────────
    elseif _pagoda_state == "practice_result" then
        local name = _level_name(_practice_level)
        if _result_was_clear then
            _font_title:GetText("CLEAR!", false, 600, C_PASS):DrawAtAnchor(cx, base_y - 70, "center")
        else
            _font_title:GetText("FAILED", false, 600, C_FAIL):DrawAtAnchor(cx, base_y - 70, "center")
        end
        _font_body:GetText(name, false, 400, C_WHITE):DrawAtAnchor(cx, base_y, "center")
        _font_hint:GetText("Press any button to continue", false, 500, C_DIM):DrawAtAnchor(cx, base_y + 60, "center")
    end

    -- Status flash
    if _status_timer > 0 then
        local alpha = math.min(255, math.floor(_status_timer * 255))
        _font_hint:GetText(_status_msg, false, 900,
            COLOR:CreateColorFromRGBA(255, 220, 80, alpha)):DrawAtAnchor(cx, res_h - 90, "center")
    end

    -- Nameplate only — the character / puchichara are intentionally not drawn on the pagoda.
    -- Hidden while the floor selector is up (it's a full-screen scene of its own).
    if not selector.active then
        NAMEPLATE:DrawPlayerNameplate(NP_X, NP_Y, 255, 0)
    end
end

return M
