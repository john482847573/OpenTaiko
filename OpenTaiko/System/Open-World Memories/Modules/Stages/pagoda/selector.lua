-- ═══════════════════════════════════════════════════════════════════════════════
-- pagoda / selector.lua
-- The floor-selection screen shared by Practice (pick any beaten level) and Challenge
-- (pick a checkpoint). Draws the scrolling pagoda tower with the selected floor framed,
-- a details panel (tier gate + level number), up/down carets, an Exit entry at the
-- bottom, plus landbg/skybox parallax and a day-night cycle across the roof tiers.
--
-- Layout constants come from plan1.xcf: every element's offset is measured from the
-- selected floor's normal.PNG top-left. The stage (Script.lua) renders the skybox and
-- hands us the world + textures + fonts via setup(); we only nudge the sky (hour/pitch).
-- ═══════════════════════════════════════════════════════════════════════════════

local M = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────
local NORMAL_W, NORMAL_H = 1063, 403     -- normal.png (a gate floor; doors 11-20)
local FLOOR_W            = 1198          -- floor_top/bottom width (the base, split from floor.png)
local ROOF_W,   ROOF_H   =  996, 403     -- roof.png (door 10 = level 20)

-- element offsets from the selected floor's normal.PNG top-left  {dx, dy, w, h}
local OFF_DETAILS  = { -736,  -67, 729, 499 }
local OFF_GATE     = { -631,   45, 305, 209 }
local OFF_NUMBER   = { -332,   -5, 230, 280 }
local OFF_FRAME    = {  -30,  -52,1105, 458 }
local OFF_CARET_UP = { -537, -279, 305, 209 }
local OFF_CARET_DN = { -535,  433, 305, 209 }

local SCROLL_SPEED   = 9.0     -- exp-smoothing rate for the tower scroll (bigger = snappier)
local DIGIT_ADVANCE  = 170     -- horizontal step between digits when centering multi-digit numbers
-- world-Y of the pagoda base bottom = floor.png full height (floor_top[0,403] + floor_bottom
-- content[403,517]). The landbg bottom pins here (moving 1:1 with the tower), so when the base
-- is centred (~level 10-11) the landbg sits exactly at its title-screen position, no cutoff.
local BASE_BOTTOM_WY = 517
local SKY_PITCH_RATE = 0.0006  -- degrees of camera pitch per scrolled pixel (weak = far sky)
local BASE_PITCH     = -6      -- matches Script.lua's world pitch
local CARET_BOB_AMP  = 14
local CARET_BOB_SPD  = 3.2

-- Shadow-corruption particles on floors not yet discovered (level > highest reached).
-- Two kinds: soft "motes" that fill the floor + rotating "spirals" for a cartoon swirl.
-- Particles live in world-Y so they scroll ATTACHED to their floor.
local SHADOW_MAX   = 260       -- pool cap (motes + spirals)
local SHADOW_RATE  = 72        -- motes spawned per second, per visible undiscovered floor
local SHADOW_LIFE  = { 0.9, 2.3 }   -- mote lifetime range (s)
local SHADOW_RISE  = { 12, 95 }     -- upward drift range (world px/s) — mixed speeds
local SHADOW_SIZE  = { 0.5, 3.8 }   -- mote scale range (sprite is 64px) — mixed sizes
local SHADOW_SWIRL = 55        -- horizontal swirl amplitude (px/s)
local SPIRAL_RATE  = 7         -- spirals spawned per second, per floor
local SPIRAL_LIFE  = { 1.3, 2.6 }
local SPIRAL_SIZE  = { 1.1, 3.2 }   -- spiral sprite is 128px
local SPIRAL_SPIN  = { 70, 250 }    -- rotation speed range (deg/s), random direction
local SHADOW_COLS  = {              -- black / dark-purple corruption palette
    { 0.02, 0.00, 0.04 },
    { 0.16, 0.02, 0.24 },
    { 0.09, 0.01, 0.15 },
    { 0.22, 0.03, 0.30 },
}

-- Dark cloud bank that blankets an undiscovered floor so its art can't be read.
-- Every puff is clamped to sit fully INSIDE the floor image, so nothing overflows it.
local CLOUD_COLS    = 7
local CLOUD_ROWS    = 5
local CLOUD_SCALE   = { 0.75, 1.4 }  -- puff scale; kept so a puff never exceeds a short floor's height
local CLOUD_SWAY    = 10             -- per-puff jiggle (px)
local CLOUD_DRIFT   = 24             -- whole-oval gentle left/right drift (px)
local CLOUD_OPACITY = 0.9
local CLOUD_COL_A   = { 0.02, 0.00, 0.04 }   -- near-black  ┐ each puff lerps a random
local CLOUD_COL_B   = { 0.20, 0.03, 0.28 }   -- dark purple ┘ amount between these two
local FLOOR_DARKEN  = { 0.10, 0.04, 0.14 }   -- undiscovered floor image tint (hide contents)
local DARK_CROP_LEFT = 300           -- skip this many px of the floor's left edge (the roof eave, not the trunk)

-- Practice sword-confirm overlay (darken → two swords spin in and cross → flash + sparks →
-- "Accept the Challenge?" + Yes/No). Only appears when selecting a practice level.
local CFM_CROSS_TIME = 0.7           -- swords fly in + spin, crossing at this time
local CFM_INTRO_TIME = 0.5           -- after the clash, wait this long (prompt/Yes-No settle) before input
local CFM_SWORD_SPINS = 2            -- whole turns while approaching (integer → lands on the tilt)
local CFM_SWORD_SCALE = 0.62
local CFM_START_OFF   = 760          -- swords start this far outside the screen
local CFM_CROSS_ANGLE = 28           -- final tilt of each sword (deg) forming the X
local CFM_CROSS_DX     = 64          -- final horizontal offset from centre
local CFM_DARK_MAX    = 0.62         -- max screen-darkening opacity
local CFM_FLASH_TIME  = 0.32         -- white clash-flash decay
local CFM_FADE_OUT    = 0.35         -- cancel fade-out duration
local SPARK_COUNT     = 46
local SPARK_GRAVITY   = 900

-- day-night across roofs: roof 1 starts here and each higher roof adds ROOF_HOUR_STEP hours
-- until midnight (24), after which every roof stays at midnight.
local ROOF_START_HOUR = 12.0    -- roof 1 (level 21) — noon, matching the day-lit doors below
local ROOF_HOUR_STEP  = 2.0

-- ── State ─────────────────────────────────────────────────────────────────────
local _world, _tex, _fonts = nil, nil, nil
local _color_fn = nil           -- level -> {r,g,b} dan-plate colour (from pagoda.lua)
local _highest  = 0             -- highest reached level (floors above are "undiscovered")

local _items   = {}             -- ordered top→bottom: { {kind="level", level=N} ..., {kind="exit"} }
local _sel     = 1              -- index into _items
local _mode    = "practice"
local _lowest  = 1              -- lowest selectable level (the Exit entry shares its position)
local _cam     = 0              -- animated world-Y at the focus
local _bob_t   = 0
local _last_hour = nil          -- so we only snap the sky (light recompute) on a real change

local _particles  = {}          -- shadow-corruption motes + spirals over undiscovered floors
local _emit_acc   = 0
local _spiral_acc = 0
local _confirm    = nil         -- practice sword-confirm overlay state, or nil when browsing
local _sparks     = {}          -- clash spark particles

M.active = false

-- skin-locale string with an English fallback
local function _sk(key, fallback)
    local s = THEME:GetSkinString(key)
    if s == nil or s == "" then return fallback end
    return s
end

-- ── Level → tier band ─────────────────────────────────────────────────────────
local function band(level)
    if     level <= 10 then return "base"    -- training (題)
    elseif level <= 20 then return "gate"    -- doors 1-10 = levels 11-20 (扉)
    else                    return "roof"    -- roofs (穹天)
    end
end

-- world-space vertical CENTER of a level's floor image (y increases downward; higher
-- level = higher up = more negative). Every level is a uniform NORMAL_H-tall slot.
local function floor_center(level)
    -- every level (training, doors, roofs) stacks in uniform NORMAL_H steps
    return -NORMAL_H * (level - 10) + NORMAL_H * 0.5
end

-- time-of-day for a roof tier (level 21 = roof 1): starts at ROOF_START_HOUR and adds
-- ROOF_HOUR_STEP per roof up to midnight (24, which the sky reads as 0), then holds midnight.
-- Reusable across menus.
function M.roofSkyHour(level)
    local roof_index = level - 20                       -- 1-based
    return math.min(24.0, ROOF_START_HOUR + (roof_index - 1) * ROOF_HOUR_STEP)
end

-- ── Camera target for the current selection ───────────────────────────────────
local function focus_y() return THEME:GetResolution().Y * 0.5 end

-- the level an item resolves to for layout; Exit shares the LOWEST level's spot so
-- selecting it never scrolls the tower/elements — only the plaque contents change.
local function item_level(item)
    if item.kind == "exit" then return _lowest end
    return item.level
end

-- the world-Y the camera settles at so the selected item sits at the focus (or, for the
-- base band, is pinned to the bottom so its details lean low instead of centering).
local function cam_target(item)
    return floor_center(item_level(item)) - focus_y()   -- every level centres uniformly (no base pin)
end

-- the within-tier number shown big:  training 1-10, gates 1-10 (door n), roofs 1-n
local function tier_number(L)
    if L <= 10 then return L
    elseif L <= 20 then return L - 10
    else return L - 20 end
end

-- ── Session control ───────────────────────────────────────────────────────────

-- Called once by Script.lua after the world + textures exist.
function M.setup(world, tex, fonts)
    _world, _tex, _fonts = world, tex, fonts
end

-- mode: "practice" | "checkpoint";  levels: ascending list;  initial: level to select.
-- info = { name = fn(level)->string, color = fn(level)->{r,g,b}, highest = N }
function M.open(mode, levels, initial, info)
    _mode     = mode
    _color_fn = info and info.color
    _highest  = (info and info.highest) or 0
    _lowest   = levels[1] or 1
    _particles  = {}
    _emit_acc   = 0
    _spiral_acc = 0
    _confirm    = nil
    _sparks     = {}
    _items   = {}
    -- ordered top (highest) → bottom (lowest), then the Exit entry at the very bottom
    for i = #levels, 1, -1 do _items[#_items + 1] = { kind = "level", level = levels[i] } end
    _items[#_items + 1] = { kind = "exit" }
    -- start on `initial` (fall back to the lowest level)
    _sel = #_items - 1
    for i, it in ipairs(_items) do
        if it.kind == "level" and it.level == initial then _sel = i ; break end
    end
    _cam    = cam_target(_items[_sel])
    _bob_t  = 0
    _last_hour = nil
    M.active = true
end

function M.close()
    M.active = false
    _last_hour = nil
    _confirm   = nil
    _sparks    = {}
    if _world ~= nil then
        _world.daynight:setHour(12)                     -- back to noon for the title
        _world.cam:setPitch(BASE_PITCH)
    end
end

local function selected_level()
    local it = _items[_sel]
    return (it and it.kind == "level") and it.level or nil
end

-- the level the cursor is currently on (nil when it's on the Exit entry) — used to reopen
-- practice on the same floor.
function M.hovered_level() return selected_level() end

-- ── Practice sword confirm (update side) ────────────────────────────────────────
local function spawn_sparks(x, y)
    for _ = 1, SPARK_COUNT do
        local a  = math.random() * 6.2832
        local sp = 260 + math.random() * 560
        local life = 0.28 + math.random() * 0.42
        _sparks[#_sparks + 1] = {
            x = x, y = y, vx = math.cos(a) * sp, vy = math.sin(a) * sp - 120,
            life = life, max = life, size = 0.30 + math.random() * 0.55,
            rot = math.random() * 360, spin = (math.random() - 0.5) * 900,
        }
    end
end

local function update_sparks(dt)
    local i = 1
    while i <= #_sparks do
        local p = _sparks[i]
        p.life = p.life - dt
        if p.life <= 0 then
            _sparks[i] = _sparks[#_sparks] ; _sparks[#_sparks] = nil
        else
            p.vy = p.vy + SPARK_GRAVITY * dt
            p.x = p.x + p.vx * dt ; p.y = p.y + p.vy * dt
            p.rot = p.rot + p.spin * dt
            i = i + 1
        end
    end
end

local function enter_confirm(level)
    _confirm = { level = level, t = 0, sel = 1, crossed = false, flash = 0, closing = false, close_t = 0 }
    _sparks  = {}
end

-- returns nil | { sel = level }  (Yes accepted)
local function update_confirm(dt, nav)
    local c = _confirm
    update_sparks(dt)
    if c.closing then
        c.close_t = c.close_t + dt
        if c.close_t >= CFM_FADE_OUT then _confirm = nil end
        return nil
    end
    c.t = c.t + dt
    if not c.crossed and c.t >= CFM_CROSS_TIME then     -- the clash
        c.crossed = true ; c.flash = 1.0
        local res = THEME:GetResolution()
        spawn_sparks(res.X * 0.5, res.Y * 0.5)
        SHARED:GetSharedSound("Decide"):Play()
    end
    if c.flash > 0 then c.flash = math.max(0, c.flash - dt / CFM_FLASH_TIME) end
    -- input only once the whole intro (swords crossed + prompt/Yes-No settled) has played
    if c.crossed and c.t >= CFM_CROSS_TIME + CFM_INTRO_TIME then
        if nav.left()  or nav.upOrPadLeft()    then c.sel = 1 ; SHARED:GetSharedSound("Move"):Play() end
        if nav.right() or nav.downOrPadRight() then c.sel = 2 ; SHARED:GetSharedSound("Move"):Play() end
        if nav.decide() then
            if c.sel == 1 then
                SHARED:GetSharedSound("SongDecide"):Play()
                local lvl = c.level ; _confirm = nil ; return { sel = lvl }
            else
                c.closing = true ; c.close_t = 0 ; SHARED:GetSharedSound("Cancel"):Play()
            end
        elseif nav.cancel() then
            c.closing = true ; c.close_t = 0 ; SHARED:GetSharedSound("Cancel"):Play()
        end
    end
    return nil
end

-- ── Update ────────────────────────────────────────────────────────────────────
-- Returns nil | { sel = level } | "exit"
function M.update(dt, nav)
    _bob_t = _bob_t + dt

    local result = nil
    if _confirm ~= nil then
        -- the sword-confirm overlay owns input; the tower keeps scrolling behind it
        result = update_confirm(dt, nav)
    else
        -- move selection (up = higher item / earlier index, down = lower item)
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
                enter_confirm(it.level)              -- practice: raise the sword-confirm overlay
                SHARED:GetSharedSound("Decide"):Play()
            else
                SHARED:GetSharedSound("Decide"):Play()
                result = { sel = it.level }          -- challenge: straight to the level preview
            end
        end
    end

    -- ease the tower scroll toward the selected item — keeps settling even during the
    -- confirm (bigger jumps move faster, intended)
    local target = cam_target(_items[_sel])
    _cam = _cam + (target - _cam) * (1 - math.exp(-SCROLL_SPEED * dt))

    -- drive the sky: day-night across roofs + a weak vertical parallax
    if _world ~= nil then
        local L = selected_level()
        local hour = (L ~= nil and L >= 21) and M.roofSkyHour(L) or 12.0
        if hour ~= _last_hour then _world.daynight:setHour(hour) ; _last_hour = hour end
        local cam_base = BASE_BOTTOM_WY - THEME:GetResolution().Y   -- rest pitch when the base is centred
        _world.cam:setPitch(BASE_PITCH + (cam_base - _cam) * SKY_PITCH_RATE)
    end
    return result
end

-- ── Draw helpers ──────────────────────────────────────────────────────────────
local function screen_y(world_y) return world_y - _cam end

local function draw_tex(tx, x, y)
    if tx ~= nil and tx.Loaded then tx:Draw(x, y) end
end

-- draw a tower floor image right-aligned, at a world-Y top; cull if fully off-screen.
-- `dark` tints an undiscovered floor to a near-black silhouette so its art can't be read.
local function draw_floor_img(tx, w, h, world_top, dark)
    if tx == nil or not tx.Loaded then return end
    local res = THEME:GetResolution()
    local y = screen_y(world_top)
    if y > res.Y or y + h < 0 then return end
    if dark then tx:SetColor(FLOOR_DARKEN[1], FLOOR_DARKEN[2], FLOOR_DARKEN[3]) end
    tx:Draw(res.X - w, y)
    if dark then tx:SetColor(1, 1, 1) end
end

-- the selected floor's normal.PNG reference top-left (screen space). X is always the
-- normal-width right alignment so the details panel stays on-screen; Y follows the band.
-- The selected item always scrolls to the centre, so its normal-ref top-left is FIXED at
-- screen-centre. Drawing the frame / details / number against this (instead of the animating
-- world position) keeps them still and readable while the tower floors slide behind.
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
    local s = tostring(tier_number(level))              -- within-tier: 1-10 / 1-n, not the raw level
    local n = #s
    local tr, tg, tb = num_tint(level)
    -- position from OFF_NUMBER; centre the group horizontally for 2+ digits
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
    else return _tex.gate end                            -- doors (11-20)
end

-- ── Shadow-corruption particles over undiscovered floors (level > highest) ──────
-- A floor's box in WORLD space (x is screen-space since horizontal never scrolls; the
-- y is a world-Y top so particles stay glued to the floor as the tower scrolls).
local function floor_world_box(L)
    local res = THEME:GetResolution()
    local c = DARK_CROP_LEFT           -- drop the left eave; keep only the trunk for the darkness
    if L >= 11 and L <= 20 then        -- doors only; roofs (21+) aren't corrupted
        return res.X - NORMAL_W + c, -NORMAL_H * (L - 10), NORMAL_W - c, NORMAL_H
    end
    return nil
end

local function spawn_particle(kind, b)
    local lr = (kind == "spiral") and SPIRAL_LIFE or SHADOW_LIFE
    local sr = (kind == "spiral") and SPIRAL_SIZE or SHADOW_SIZE
    local life = lr[1] + math.random() * (lr[2] - lr[1])
    _particles[#_particles + 1] = {
        kind = kind,
        x  = b[1] + math.random() * b[3],                    -- across the FULL floor width
        wy = b[2] + math.random() * b[4],                    -- across the FULL floor height (world-Y)
        vy = -(SHADOW_RISE[1] + math.random() * (SHADOW_RISE[2] - SHADOW_RISE[1])),
        phase = math.random() * 6.28,
        life = life, max = life,
        size = sr[1] + math.random() * (sr[2] - sr[1]),
        col  = SHADOW_COLS[math.random(#SHADOW_COLS)],
        rot  = math.random() * 360,
        spin = (SPIRAL_SPIN[1] + math.random() * (SPIRAL_SPIN[2] - SPIRAL_SPIN[1]))
               * (math.random() < 0.5 and 1 or -1),
    }
end

local function emit_particles(dt)
    local res = THEME:GetResolution()
    local mg = NORMAL_H          -- also seed one floor beyond the screen so scrolling never pops it in
    local boxes = {}
    for L = 11, 20 do
        if L > _highest then
            local x, wy, w, h = floor_world_box(L)
            if x ~= nil then
                local sy = screen_y(wy)
                if sy < res.Y + mg and sy + h > -mg then boxes[#boxes + 1] = { x, wy, w, h } end
            end
        end
    end
    if #boxes == 0 then return end
    _emit_acc = math.min(8, _emit_acc + SHADOW_RATE * #boxes * dt)
    while _emit_acc >= 1 and #_particles < SHADOW_MAX do
        _emit_acc = _emit_acc - 1
        spawn_particle("mote", boxes[math.random(#boxes)])
    end
    _spiral_acc = math.min(4, _spiral_acc + SPIRAL_RATE * #boxes * dt)
    while _spiral_acc >= 1 and #_particles < SHADOW_MAX do
        _spiral_acc = _spiral_acc - 1
        spawn_particle("spiral", boxes[math.random(#boxes)])
    end
end

local function update_particles(dt)
    local i = 1
    while i <= #_particles do
        local p = _particles[i]
        p.life = p.life - dt
        if p.life <= 0 then
            _particles[i] = _particles[#_particles]
            _particles[#_particles] = nil
        else
            p.phase = p.phase + dt * 3
            p.wy = p.wy + p.vy * dt
            p.x  = p.x + math.cos(p.phase) * SHADOW_SWIRL * dt
            if p.kind == "spiral" then p.rot = p.rot + p.spin * dt end
            i = i + 1
        end
    end
end

local function draw_particles()
    for _, p in ipairs(_particles) do
        local tx = (p.kind == "spiral") and _tex.spiral or _tex.shadow
        if tx ~= nil and tx.Loaded then
            local a = math.sin((1 - p.life / p.max) * math.pi)       -- fade in then out
            tx:SetScale(p.size, p.size)
            tx:SetColor(p.col[1], p.col[2], p.col[3])
            tx:SetOpacity(a * (p.kind == "spiral" and 0.75 or 0.9))
            if p.kind == "spiral" then tx:SetRotation(p.rot) end
            tx:DrawAtAnchor(p.x, screen_y(p.wy), "center")
            if p.kind == "spiral" then tx:SetRotation(0) end
        end
    end
    if _tex.shadow ~= nil then _tex.shadow:SetColor(1, 1, 1) ; _tex.shadow:SetOpacity(1) ; _tex.shadow:SetScale(1, 1) end
    if _tex.spiral ~= nil then _tex.spiral:SetColor(1, 1, 1) ; _tex.spiral:SetOpacity(1) ; _tex.spiral:SetScale(1, 1) end
end

-- keep a value inside [lo, hi]; if the span is negative (box smaller than the puff) centre it
local function clamp_center(v, lo, hi)
    if lo >= hi then return (lo + hi) * 0.5 end
    return math.max(lo, math.min(hi, v))
end

-- Dark cloud bank over each undiscovered floor: soft dark puffs arranged in an OVAL (grid
-- cells outside the inscribed ellipse are skipped), the whole bank easing left/right, each
-- puff a different shade between black and dark purple. Every puff is clamped by its own
-- half-size so the WHOLE sprite stays inside the floor image; floors one screen beyond are
-- drawn so scrolling never cuts the effect in.
local function draw_clouds()
    local cl = _tex.cloud
    if cl == nil or not cl.Loaded then return end
    local res = THEME:GetResolution()
    local mg = NORMAL_H
    local drift = math.sin(_bob_t * 0.5) * CLOUD_DRIFT              -- whole oval drifts left/right
    for L = 11, 20 do
        if L > _highest then
            local x, wy, w, h = floor_world_box(L)
            if x ~= nil then
                local sy = screen_y(wy)
                if sy < res.Y + mg and sy + h > -mg then
                    for cxi = 0, CLOUD_COLS - 1 do
                        for cyi = 0, CLOUD_ROWS - 1 do
                            local u = (cxi + 0.5) / CLOUD_COLS * 2 - 1      -- cell position in [-1,1]
                            local v = (cyi + 0.5) / CLOUD_ROWS * 2 - 1
                            if u * u + v * v <= 1.0 then                    -- keep only cells inside the oval
                                local idx = cxi * CLOUD_ROWS + cyi
                                local sc = CLOUD_SCALE[1] + (idx % 4) / 4 * (CLOUD_SCALE[2] - CLOUD_SCALE[1])
                                local hw, hh = sc * cl.Width * 0.5, sc * cl.Height * 0.5
                                local px = x  + (cxi + 0.5) / CLOUD_COLS * w + drift + math.sin(_bob_t * 0.9 + idx) * CLOUD_SWAY
                                local py = sy + (cyi + 0.5) / CLOUD_ROWS * h + math.cos(_bob_t * 0.6 + idx * 1.7) * (CLOUD_SWAY * 0.5)
                                px = clamp_center(px, x + hw,  x + w - hw)
                                py = clamp_center(py, sy + hh, sy + h - hh)
                                local t = (idx * 0.618034) % 1             -- stable per-puff shade
                                cl:SetScale(sc, sc)
                                cl:SetColor(CLOUD_COL_A[1] + (CLOUD_COL_B[1] - CLOUD_COL_A[1]) * t,
                                            CLOUD_COL_A[2] + (CLOUD_COL_B[2] - CLOUD_COL_A[2]) * t,
                                            CLOUD_COL_A[3] + (CLOUD_COL_B[3] - CLOUD_COL_A[3]) * t)
                                cl:SetOpacity(CLOUD_OPACITY)
                                cl:DrawAtAnchor(px, py, "center")
                            end
                        end
                    end
                end
            end
        end
    end
    cl:SetColor(1, 1, 1) ; cl:SetOpacity(1) ; cl:SetScale(1, 1)
end

-- ── Practice sword confirm (draw side) ──────────────────────────────────────────
local function draw_sparks()
    local sk = _tex.spark
    if sk == nil or not sk.Loaded then return end
    sk:SetBlendMode("Add")
    for _, p in ipairs(_sparks) do
        local a = math.min(1, p.life / p.max * 2)
        sk:SetScale(p.size, p.size)
        sk:SetColor(1.0, 0.93, 0.55)
        sk:SetOpacity(a)
        sk:SetRotation(p.rot)
        sk:DrawAtAnchor(p.x, p.y, "center")
    end
    sk:SetBlendMode("Normal") ; sk:SetColor(1, 1, 1) ; sk:SetOpacity(1) ; sk:SetScale(1, 1) ; sk:SetRotation(0)
end

local function draw_confirm()
    local c = _confirm
    if c == nil then return end
    local res = THEME:GetResolution()
    local cx, cy = res.X * 0.5, res.Y * 0.5
    local fade = c.closing and (1 - math.min(1, c.close_t / CFM_FADE_OUT)) or 1

    -- 1) darken the screen (1px black stretched to fill), easing in with the swords
    local blk = _tex.black1
    if blk ~= nil and blk.Loaded then
        local da = CFM_DARK_MAX * math.min(1, c.t / CFM_CROSS_TIME) * fade
        blk:SetScale(res.X / math.max(1, blk.Width), res.Y / math.max(1, blk.Height))
        blk:SetOpacity(da) ; blk:Draw(0, 0)
        blk:SetOpacity(1) ; blk:SetScale(1, 1)
    end

    -- 2) two swords fly in from off left/right, spinning, crossing into an X at the centre
    local sw = _tex.sword
    if sw ~= nil and sw.Loaded then
        local t01 = math.min(1, c.t / CFM_CROSS_TIME)
        local e   = 1 - (1 - t01) * (1 - t01)                              -- ease-out
        local lx  = -CFM_START_OFF + (cx - CFM_CROSS_DX + CFM_START_OFF) * e
        local rx  = (res.X + CFM_START_OFF) + (cx + CFM_CROSS_DX - res.X - CFM_START_OFF) * e
        local la  =  CFM_SWORD_SPINS * 360 * e - CFM_CROSS_ANGLE
        local ra  = -CFM_SWORD_SPINS * 360 * e + CFM_CROSS_ANGLE
        local function draw_sword(px, ang)
            sw:SetScale(CFM_SWORD_SCALE, CFM_SWORD_SCALE) ; sw:SetOpacity(fade) ; sw:SetRotation(ang)
            sw:DrawAtAnchor(px, cy, "center")
            if c.flash > 0 then                                            -- white clash flash
                sw:SetBlendMode("Add") ; sw:SetOpacity(c.flash * fade)
                sw:DrawAtAnchor(px, cy, "center") ; sw:SetBlendMode("Normal")
            end
        end
        draw_sword(lx, la) ; draw_sword(rx, ra)
        sw:SetRotation(0) ; sw:SetOpacity(1) ; sw:SetScale(1, 1)
    end

    -- 3) white burst + sparks at the clash
    if c.flash > 0 and _tex.shadow ~= nil and _tex.shadow.Loaded then
        _tex.shadow:SetBlendMode("Add") ; _tex.shadow:SetColor(1, 1, 1)
        _tex.shadow:SetOpacity(c.flash * 0.9 * fade) ; _tex.shadow:SetScale(15, 15)
        _tex.shadow:DrawAtAnchor(cx, cy, "center")
        _tex.shadow:SetBlendMode("Normal") ; _tex.shadow:SetColor(1, 1, 1) ; _tex.shadow:SetOpacity(1) ; _tex.shadow:SetScale(1, 1)
    end
    draw_sparks()

    -- 4) prompt + Yes/No, once the swords have clashed
    if c.crossed then
        local pt  = c.t - CFM_CROSS_TIME
        local pop = 1 + 0.3 * math.max(0, 1 - pt / 0.22)                   -- flash-in scale pop
        local ta  = math.min(1, pt / 0.18) * fade
        local tf  = _fonts.confirm or _fonts.header
        local q = tf:GetText(_sk("PAGODA_ACCEPT", "Accept the Challenge?"), false, 1700,
            COLOR:CreateColorFromRGBA(255, 255, 255, 255), COLOR:CreateColorFromRGBA(0, 0, 0, 255))
        if q ~= nil then
            q:SetScale(pop, pop) ; q:SetOpacity(ta) ; q:DrawAtAnchor(cx, res.Y * 0.30, "center")
            q:SetScale(1, 1) ; q:SetOpacity(1)
        end
        local ya = math.min(1, math.max(0, (pt - 0.15) / 0.3)) * fade
        local function opt(txt, ox, on)
            local col = on and COLOR:CreateColorFromRGBA(255, 220, 90, 255)
                            or  COLOR:CreateColorFromRGBA(205, 205, 205, 255)
            local t = _fonts.header:GetText(txt, false, 500, col, COLOR:CreateColorFromRGBA(0, 0, 0, 255))
            if t ~= nil then
                local sc = on and (1.0 + 0.07 * math.sin(_bob_t * 7)) or 1.0   -- gentle bounce on the hovered option
                t:SetScale(sc, sc) ; t:SetOpacity(ya)
                t:DrawAtAnchor(ox, res.Y * 0.70, "center")
                t:SetScale(1, 1) ; t:SetOpacity(1)
            end
        end
        opt(_sk("PAGODA_YES", "Yes"), cx - 150, c.sel == 1)
        opt(_sk("PAGODA_NO",  "No"),  cx + 150, c.sel == 2)
    end
end

-- ── Draw ──────────────────────────────────────────────────────────────────────
function M.draw()
    local res   = THEME:GetResolution()
    local res_w = res.X

    -- landbg parallax (skybox itself is drawn by Script.lua behind us)
    if _tex.landbg ~= nil and _tex.landbg.Loaded then
        -- bottom pinned to the pagoda base bottom; matches the title-screen landbg when the
        -- base is centred (~level 10-11), and scrolls 1:1 with the tower elsewhere
        _tex.landbg:DrawAtAnchor(res_w, screen_y(BASE_BOTTOM_WY), "bottomright")
    end

    -- tower: base + gate floors (11-19) + roof (20). Roofs (21+) have no image.
    -- Undiscovered floors (level > highest reached) are darkened, then buried under a
    -- dark cloud bank + shadow particles so their art can't be read.
    -- base: level 10 building (floor_top, worldY [0,403]) and level 9 (floor_bottom, the
    -- removed bottom slice transparent-padded to a full 403 slot, worldY [403,806]). Levels
    -- 1-8 have no floor image. Training isn't corrupted, so no darken flag.
    local bx = THEME:GetResolution().X - FLOOR_W
    if _tex.floor_top    ~= nil and _tex.floor_top.Loaded    then _tex.floor_top:Draw(bx, screen_y(0)) end
    if _tex.floor_bottom ~= nil and _tex.floor_bottom.Loaded then _tex.floor_bottom:Draw(bx, screen_y(NORMAL_H)) end
    for L = 11, 19 do
        -- door 5 (level 15) becomes the checkpoint-cleared floor once beaten
        local ftex = _tex.normal
        if L == 15 and _highest >= 15 and _tex.checkpoint_cleared ~= nil then
            ftex = _tex.checkpoint_cleared
        end
        draw_floor_img(ftex, NORMAL_W, NORMAL_H, -NORMAL_H * (L - 10), L > _highest)
    end
    -- door 10 (level 20): roof.png as its floor image, still shadowed until beaten.
    -- Roofs (21+) have no floor image.
    draw_floor_img(_tex.roof, ROOF_W, ROOF_H, -NORMAL_H * 10, 20 > _highest)

    -- dark clouds blanket the undiscovered floors, then the corruption particles on top
    draw_clouds()
    local pdt = fps.deltaTime
    update_particles(pdt) ; emit_particles(pdt) ; draw_particles()

    -- selection UI for the current item (drawn at a fixed screen-centre so it stays readable)
    local item = _items[_sel]
    local rx, ry = ref_topleft()

    if item.kind == "exit" then
        -- a details plaque with only the word Exit, centred
        draw_tex(_tex.details, rx + OFF_DETAILS[1], ry + OFF_DETAILS[2])
        local cx = rx + OFF_DETAILS[1] + OFF_DETAILS[3] * 0.5
        local cy = ry + OFF_DETAILS[2] + OFF_DETAILS[4] * 0.5
        local t = _fonts.header:GetText(_sk("PAGODA_EXIT", "Exit"), false, 600)
        if t ~= nil then t:DrawAtAnchor(cx, cy, "center") end
    else
        local L = item.level
        -- frame on EVERY floor (only the Exit entry has none), with a pulsing "bounce" opacity
        if _tex.frame ~= nil and _tex.frame.Loaded then
            _tex.frame:SetOpacity(0.75 + 0.25 * math.sin(_bob_t * 3.2))
            _tex.frame:Draw(rx + OFF_FRAME[1], ry + OFF_FRAME[2])
            _tex.frame:SetOpacity(1)
        end
        draw_tex(_tex.details, rx + OFF_DETAILS[1], ry + OFF_DETAILS[2])
        draw_tex(gate_tex(L), rx + OFF_GATE[1], ry + OFF_GATE[2])
        draw_number(L, rx, ry)

        -- header (Practice / Checkpoint) at the details top-left
        local hdr = (_mode == "checkpoint") and _sk("PAGODA_START_AT", "Start at...")
                                             or  _sk("PAGODA_PRACTICE", "Practice")
        local h = _fonts.header:GetText(hdr, false, 500)
        if h ~= nil then h:DrawAtAnchor(rx + OFF_DETAILS[1] + 34, ry + OFF_DETAILS[2] + 30, "topleft") end

        -- "Level N" on the details' white strip: black text, transparent outline. N = the
        -- raw pagoda level (Level 11 for Gate 1), NOT the within-tier number on the big glyph.
        local lvl = _fonts.name:GetText(_sk("PAGODA_LEVEL", "Level") .. " " .. tostring(L),
            false, 500, COLOR:CreateColorFromRGBA(0, 0, 0, 255), COLOR:CreateColorFromRGBA(0, 0, 0, 0))
        local sx = rx + OFF_DETAILS[1] + OFF_DETAILS[3] * 0.5
        local sy = ry + OFF_DETAILS[2] + OFF_DETAILS[4] - 62
        if lvl ~= nil then lvl:DrawAtAnchor(sx, sy, "center") end
    end

    -- carets (only toward an available neighbour), bobbing out then in
    local bob = (math.sin(_bob_t * CARET_BOB_SPD) * 0.5 + 0.5) * CARET_BOB_AMP
    if _sel > 1 and _tex.caret_up ~= nil and _tex.caret_up.Loaded then
        _tex.caret_up:Draw(rx + OFF_CARET_UP[1], ry + OFF_CARET_UP[2] - bob)
    end
    if _sel < #_items and _tex.caret ~= nil and _tex.caret.Loaded then
        _tex.caret:Draw(rx + OFF_CARET_DN[1], ry + OFF_CARET_DN[2] + bob)
    end

    -- practice sword-confirm overlay, on top of the (frozen) selector
    draw_confirm()
end

return M
