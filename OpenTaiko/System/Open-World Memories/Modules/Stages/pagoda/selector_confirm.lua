-- pagoda / selector_confirm.lua
-- Practice confirmation overlay: the screen darkens while two swords fly in and cross, sparks
-- burst on the clash, then "Accept the Challenge?" with a Yes/No choice. The selector keeps
-- scrolling behind it; input is accepted only once the intro has finished.

local M = {}

local CROSS_TIME  = 0.7      -- swords fly in + spin, crossing at this time
local INTRO_TIME  = 0.5      -- settle time after the clash before input is accepted
local SWORD_SPINS = 2        -- whole turns on approach (integer so it lands on the tilt)
local SWORD_SCALE = 0.62
local START_OFF   = 760      -- swords start this far outside the screen
local CROSS_ANGLE = 28       -- final tilt of each sword (deg)
local CROSS_DX    = 64       -- final horizontal offset from centre
local DARK_MAX    = 0.62     -- max screen-darkening opacity
local FLASH_TIME  = 0.32     -- clash-flash decay
local FADE_OUT    = 0.35     -- cancel fade-out duration
local SPARK_COUNT   = 46
local SPARK_GRAVITY = 900

local _tex, _fonts = nil, nil
local _c      = nil          -- overlay state, nil while inactive
local _sparks = {}
local _t      = 0            -- clock for the hovered-option bounce

local function _sk(key, fallback)
    local s = THEME:GetSkinString(key)
    if s == nil or s == "" then return fallback end
    return s
end

function M.setup(tex, fonts)
    _tex, _fonts = tex, fonts
end

function M.active() return _c ~= nil end

function M.enter(level)
    _c = { level = level, t = 0, sel = 1, crossed = false, flash = 0, closing = false, close_t = 0 }
    _sparks = {}
end

function M.reset()
    _c, _sparks = nil, {}
end

-- ── Sparks ────────────────────────────────────────────────────────────────────
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

-- ── Update / draw ─────────────────────────────────────────────────────────────
-- returns nil | { sel = level } (Yes accepted); Cancel/No fade the overlay out
function M.update(dt, nav)
    local c = _c
    _t = _t + dt
    update_sparks(dt)
    if c.closing then
        c.close_t = c.close_t + dt
        if c.close_t >= FADE_OUT then _c = nil end
        return nil
    end
    c.t = c.t + dt
    if not c.crossed and c.t >= CROSS_TIME then
        c.crossed = true ; c.flash = 1.0
        local res = THEME:GetResolution()
        spawn_sparks(res.X * 0.5, res.Y * 0.5)
        SHARED:GetSharedSound("Decide"):Play()
    end
    if c.flash > 0 then c.flash = math.max(0, c.flash - dt / FLASH_TIME) end
    if c.crossed and c.t >= CROSS_TIME + INTRO_TIME then
        if nav.left()  or nav.upOrPadLeft()    then c.sel = 1 ; SHARED:GetSharedSound("Move"):Play() end
        if nav.right() or nav.downOrPadRight() then c.sel = 2 ; SHARED:GetSharedSound("Move"):Play() end
        if nav.decide() then
            if c.sel == 1 then
                SHARED:GetSharedSound("SongDecide"):Play()
                local lvl = c.level ; _c = nil ; return { sel = lvl }
            else
                c.closing = true ; c.close_t = 0 ; SHARED:GetSharedSound("Cancel"):Play()
            end
        elseif nav.cancel() then
            c.closing = true ; c.close_t = 0 ; SHARED:GetSharedSound("Cancel"):Play()
        end
    end
    return nil
end

function M.draw()
    local c = _c
    if c == nil then return end
    local res = THEME:GetResolution()
    local cx, cy = res.X * 0.5, res.Y * 0.5
    local fade = c.closing and (1 - math.min(1, c.close_t / FADE_OUT)) or 1

    -- screen darkening (1px black stretched to fill)
    local blk = _tex.black1
    if blk ~= nil and blk.Loaded then
        local da = DARK_MAX * math.min(1, c.t / CROSS_TIME) * fade
        blk:SetScale(res.X / math.max(1, blk.Width), res.Y / math.max(1, blk.Height))
        blk:SetOpacity(da) ; blk:Draw(0, 0)
        blk:SetOpacity(1) ; blk:SetScale(1, 1)
    end

    -- swords flying in from both sides, crossing into an X
    local sw = _tex.sword
    if sw ~= nil and sw.Loaded then
        local t01 = math.min(1, c.t / CROSS_TIME)
        local e   = 1 - (1 - t01) * (1 - t01)
        local lx  = -START_OFF + (cx - CROSS_DX + START_OFF) * e
        local rx  = (res.X + START_OFF) + (cx + CROSS_DX - res.X - START_OFF) * e
        local la  =  SWORD_SPINS * 360 * e - CROSS_ANGLE
        local ra  = -SWORD_SPINS * 360 * e + CROSS_ANGLE
        local function draw_sword(px, ang)
            sw:SetScale(SWORD_SCALE, SWORD_SCALE) ; sw:SetOpacity(fade) ; sw:SetRotation(ang)
            sw:DrawAtAnchor(px, cy, "center")
            if c.flash > 0 then
                sw:SetBlendMode("Add") ; sw:SetOpacity(c.flash * fade)
                sw:DrawAtAnchor(px, cy, "center") ; sw:SetBlendMode("Normal")
            end
        end
        draw_sword(lx, la) ; draw_sword(rx, ra)
        sw:SetRotation(0) ; sw:SetOpacity(1) ; sw:SetScale(1, 1)
    end

    -- white burst + sparks on the clash
    if c.flash > 0 and _tex.shadow ~= nil and _tex.shadow.Loaded then
        _tex.shadow:SetBlendMode("Add") ; _tex.shadow:SetColor(1, 1, 1)
        _tex.shadow:SetOpacity(c.flash * 0.9 * fade) ; _tex.shadow:SetScale(15, 15)
        _tex.shadow:DrawAtAnchor(cx, cy, "center")
        _tex.shadow:SetBlendMode("Normal") ; _tex.shadow:SetColor(1, 1, 1) ; _tex.shadow:SetOpacity(1) ; _tex.shadow:SetScale(1, 1)
    end
    draw_sparks()

    -- prompt + Yes/No once the swords have crossed
    if c.crossed then
        local pt  = c.t - CROSS_TIME
        local pop = 1 + 0.3 * math.max(0, 1 - pt / 0.22)
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
                local sc = on and (1.0 + 0.07 * math.sin(_t * 7)) or 1.0
                t:SetScale(sc, sc) ; t:SetOpacity(ya)
                t:DrawAtAnchor(ox, res.Y * 0.70, "center")
                t:SetScale(1, 1) ; t:SetOpacity(1)
            end
        end
        opt(_sk("PAGODA_YES", "Yes"), cx - 150, c.sel == 1)
        opt(_sk("PAGODA_NO",  "No"),  cx + 150, c.sel == 2)
    end
end

return M
