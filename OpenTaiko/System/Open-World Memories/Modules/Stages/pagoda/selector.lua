-- pagoda / selector.lua
-- Floor-selection screen shared by Practice (pick any beaten level) and Challenge (pick a
-- checkpoint): selection input + camera, the fixed-centre selection UI (frame, details plaque,
-- tier glyph, level number, carets), and sky control (day-night across roofs + pitch parallax).
-- It also renders the title-screen pose (the same scene resting at the base floor).
-- Scene rendering lives in selector_scene.lua, the practice confirm in selector_confirm.lua.
-- UI offsets are measured from the selected floor's normal.png top-left (source: plan1.xcf).

local scene   = require("selector_scene")
local confirm = require("selector_confirm")

local M = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────
local NORMAL_W, NORMAL_H = scene.NORMAL_W, scene.NORMAL_H

-- offsets from the selected floor's reference top-left  {dx, dy, w, h}
local OFF_DETAILS  = { -736,  -67, 729, 499 }
local OFF_GATE     = { -631,   45, 305, 209 }
local OFF_NUMBER   = { -332,   -5, 230, 280 }
local OFF_FRAME    = {  -30,  -52,1105, 458 }
local OFF_CARET_UP = { -537, -279, 305, 209 }
local OFF_CARET_DN = { -535,  433, 305, 209 }

local SCROLL_SPEED  = 9.0      -- exp-smoothing rate of the tower scroll
local DIGIT_ADVANCE = 170      -- horizontal step between number digits
local CARET_BOB_AMP = 14
local CARET_BOB_SPD = 3.2

-- sky: pitch follows the camera; the rest pose is the base floor at its title height
local BASE_PITCH     = -6      -- matches the stage's world pitch
local BASE_BOTTOM_WY = 517     -- world-Y of the pagoda base bottom (pitch rest point)
local SKY_PITCH_RATE = 0.0006  -- degrees of pitch per scrolled pixel

-- day-night across roofs: each roof tier past the first adds ROOF_HOUR_STEP hours until
-- midnight (24), then holds midnight
local ROOF_START_HOUR = 12.0
local ROOF_HOUR_STEP  = 2.0

-- ── State ─────────────────────────────────────────────────────────────────────
local _world, _tex, _fonts = nil, nil, nil
local _color_fn = nil           -- level -> {r,g,b} dan-plate colour (from pagoda.lua)
local _highest  = 0             -- highest reached level

local _items   = {}             -- ordered top→bottom: { {kind="level", level=N} ..., {kind="exit"} }
local _sel     = 1              -- index into _items
local _mode    = "practice"
local _lowest  = 1              -- lowest selectable level (the Exit entry shares its position)
local _cam     = 0              -- animated world-Y at the focus
local _bob_t   = 0
local _last_hour = nil

M.active = false

local function _sk(key, fallback)
    local s = THEME:GetSkinString(key)
    if s == nil or s == "" then return fallback end
    return s
end

-- ── Level helpers ─────────────────────────────────────────────────────────────
-- tier bands: base/training 1-10 (題), gates 11-20 (扉), roofs 21+ (穹天)
local function band(level)
    if     level <= 10 then return "base"
    elseif level <= 20 then return "gate"
    else                    return "roof"
    end
end

-- the number shown on the plaque: within-tier (gate 1 for level 11, roof 1 for level 21)
local function tier_number(L)
    if L <= 10 then return L
    elseif L <= 20 then return L - 10
    else return L - 20 end
end

-- time-of-day for a roof tier; reusable by other pagoda menus
function M.roofSkyHour(level)
    local roof_index = level - 20
    return math.min(24.0, ROOF_START_HOUR + (roof_index - 1) * ROOF_HOUR_STEP)
end

-- ── Camera ────────────────────────────────────────────────────────────────────
local function focus_y() return THEME:GetResolution().Y * 0.5 end

-- Exit shares the lowest level's spot so selecting it never scrolls the tower
local function item_level(item)
    if item.kind == "exit" then return _lowest end
    return item.level
end

local function cam_target(item)
    return scene.floor_center(item_level(item)) - focus_y()
end

-- pitch parallax; `hour` is only pushed to the sky when it changes (light recompute)
local function apply_sky(hour)
    if _world == nil then return end
    if hour ~= nil and hour ~= _last_hour then
        _world.daynight:setHour(hour)
        _last_hour = hour
    end
    local rest = BASE_BOTTOM_WY - THEME:GetResolution().Y
    _world.cam:setPitch(BASE_PITCH + (rest - _cam) * SKY_PITCH_RATE)
end

-- ── Session control ───────────────────────────────────────────────────────────
function M.setup(world, tex, fonts)
    _world, _tex, _fonts = world, tex, fonts
    scene.setup(tex)
    confirm.setup(tex, fonts)
    _cam = scene.floor_center(10) - focus_y()   -- start at the title pose
end

-- mode: "practice" | "checkpoint";  levels: ascending;  initial: level to select.
-- info = { name = fn(level)->string, color = fn(level)->{r,g,b}, highest = N }
function M.open(mode, levels, initial, info)
    _mode     = mode
    _color_fn = info and info.color
    _highest  = (info and info.highest) or 0
    _lowest   = levels[1] or 1
    scene.reset()
    confirm.reset()
    _items = {}
    for i = #levels, 1, -1 do _items[#_items + 1] = { kind = "level", level = levels[i] } end
    _items[#_items + 1] = { kind = "exit" }
    _sel = #_items - 1
    for i, it in ipairs(_items) do
        if it.kind == "level" and it.level == initial then _sel = i ; break end
    end
    -- _cam is not snapped: it eases from the title pose / previous selection
    _bob_t     = 0
    _last_hour = nil
    M.active   = true
end

function M.close()
    M.active   = false
    _last_hour = nil
    confirm.reset()
    if _world ~= nil then
        _world.daynight:setHour(12)
        _world.cam:setPitch(BASE_PITCH)
    end
end

local function selected_level()
    local it = _items[_sel]
    return (it and it.kind == "level") and it.level or nil
end

-- current cursor level (nil on Exit); used to reopen practice on the same floor
function M.hovered_level() return selected_level() end

-- ── Update ────────────────────────────────────────────────────────────────────
-- Returns nil | { sel = level } | "exit"
function M.update(dt, nav)
    _bob_t = _bob_t + dt

    local result = nil
    if confirm.active() then
        result = confirm.update(dt, nav)
    else
        if nav.upOrPadLeft() then
            if _sel > 1 then _sel = _sel - 1 ; SHARED:GetSharedSound("Move"):Play() end
        elseif nav.downOrPadRight() then
            if _sel < #_items then _sel = _sel + 1 ; SHARED:GetSharedSound("Move"):Play() end
        end

        if nav.cancel() then
            SHARED:GetSharedSound("Cancel"):Play()
            result = "exit"
        elseif nav.decide() then
            local it = _items[_sel]
            if it.kind == "exit" then
                SHARED:GetSharedSound("Cancel"):Play()
                result = "exit"
            elseif _mode == "practice" then
                confirm.enter(it.level)
                SHARED:GetSharedSound("Decide"):Play()
            else
                SHARED:GetSharedSound("Decide"):Play()
                result = { sel = it.level }
            end
        end
    end

    -- the tower keeps easing toward the selection, including behind the confirm overlay
    local target = cam_target(_items[_sel])
    _cam = _cam + (target - _cam) * (1 - math.exp(-SCROLL_SPEED * dt))

    local L = selected_level()
    apply_sky((L ~= nil and L >= 21) and M.roofSkyHour(L) or 12.0)
    return result
end

-- ── Selection UI ──────────────────────────────────────────────────────────────
local function draw_tex(tx, x, y)
    if tx ~= nil and tx.Loaded then tx:Draw(x, y) end
end

-- the selected item always scrolls to the centre, so the UI reference point is fixed there;
-- drawing against it keeps the frame/details readable while the tower slides behind
local function ref_topleft()
    local res = THEME:GetResolution()
    return res.X - NORMAL_W, res.Y * 0.5 - NORMAL_H * 0.5
end

-- big number tint = the level's dan-plate colour; roofs stay white
local function num_tint(level)
    if level >= 21 then return 1, 1, 1 end
    if _color_fn ~= nil then
        local c = _color_fn(level)
        if c ~= nil then return c[1] / 255, c[2] / 255, c[3] / 255 end
    end
    return 1, 1, 1
end

local function draw_number(level, nx, ny)
    local s = tostring(tier_number(level))
    local n = #s
    local tr, tg, tb = num_tint(level)
    local cell_cx = nx + OFF_NUMBER[1] + OFF_NUMBER[3] * 0.5
    local total   = (n - 1) * DIGIT_ADVANCE
    local x0      = cell_cx - total * 0.5 - OFF_NUMBER[3] * 0.5
    local y       = ny + OFF_NUMBER[2]
    for i = 1, n do
        local g = _tex.num[tonumber(s:sub(i, i))]
        if g ~= nil and g.Loaded then
            g:SetColor(tr, tg, tb)
            g:Draw(x0 + (i - 1) * DIGIT_ADVANCE, y)
            g:SetColor(1, 1, 1)
        end
    end
end

local function gate_tex(level)
    local b = band(level)
    if b == "base" then return _tex.gateT
    elseif b == "roof" then return _tex.gateR
    else return _tex.gate end
end

-- ── Draw ──────────────────────────────────────────────────────────────────────

-- Title screen: the scene easing back to the base floor pose. Called by Script.lua every
-- title frame; `highest` keeps the door darkening in sync with the save.
function M.drawTitle(highest)
    if highest ~= nil then _highest = highest end
    local dt = fps.deltaTime
    local target = scene.floor_center(10) - focus_y()
    _cam = _cam + (target - _cam) * (1 - math.exp(-SCROLL_SPEED * dt))
    apply_sky(nil)
    scene.draw(_cam, _highest)
end

function M.draw()
    scene.draw(_cam, _highest)

    local item = _items[_sel]
    local rx, ry = ref_topleft()

    if item.kind == "exit" then
        draw_tex(_tex.details, rx + OFF_DETAILS[1], ry + OFF_DETAILS[2])
        local cx = rx + OFF_DETAILS[1] + OFF_DETAILS[3] * 0.5
        local cy = ry + OFF_DETAILS[2] + OFF_DETAILS[4] * 0.5
        local t = _fonts.header:GetText(_sk("PAGODA_EXIT", "Exit"), false, 600)
        if t ~= nil then t:DrawAtAnchor(cx, cy, "center") end
    else
        local L = item.level
        if _tex.frame ~= nil and _tex.frame.Loaded then
            _tex.frame:SetOpacity(0.75 + 0.25 * math.sin(_bob_t * 3.2))
            _tex.frame:Draw(rx + OFF_FRAME[1], ry + OFF_FRAME[2])
            _tex.frame:SetOpacity(1)
        end
        draw_tex(_tex.details, rx + OFF_DETAILS[1], ry + OFF_DETAILS[2])
        draw_tex(gate_tex(L), rx + OFF_GATE[1], ry + OFF_GATE[2])
        draw_number(L, rx, ry)

        local hdr = (_mode == "checkpoint") and _sk("PAGODA_START_AT", "Start at...")
                                             or  _sk("PAGODA_PRACTICE", "Practice")
        local h = _fonts.header:GetText(hdr, false, 500)
        if h ~= nil then h:DrawAtAnchor(rx + OFF_DETAILS[1] + 34, ry + OFF_DETAILS[2] + 30, "topleft") end

        -- "Level N" strip: the raw pagoda level, black text with a transparent outline
        local lvl = _fonts.name:GetText(_sk("PAGODA_LEVEL", "Level") .. " " .. tostring(L),
            false, 500, COLOR:CreateColorFromRGBA(0, 0, 0, 255), COLOR:CreateColorFromRGBA(0, 0, 0, 0))
        local sx = rx + OFF_DETAILS[1] + OFF_DETAILS[3] * 0.5
        local sy = ry + OFF_DETAILS[2] + OFF_DETAILS[4] - 62
        if lvl ~= nil then lvl:DrawAtAnchor(sx, sy, "center") end
    end

    -- carets only toward an available neighbour, bobbing
    local bob = (math.sin(_bob_t * CARET_BOB_SPD) * 0.5 + 0.5) * CARET_BOB_AMP
    if _sel > 1 and _tex.caret_up ~= nil and _tex.caret_up.Loaded then
        _tex.caret_up:Draw(rx + OFF_CARET_UP[1], ry + OFF_CARET_UP[2] - bob)
    end
    if _sel < #_items and _tex.caret ~= nil and _tex.caret.Loaded then
        _tex.caret:Draw(rx + OFF_CARET_DN[1], ry + OFF_CARET_DN[2] + bob)
    end

    confirm.draw()
end

return M
