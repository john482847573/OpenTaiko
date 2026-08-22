-- pagoda / selector_scene.lua
-- Renders the landscape + tower scene shared by the floor selector and the title screen:
-- parallax background (forest canopy + three mountain layers), per-level tower art, overlay
-- objects (guardian gate, lanterns), and the corruption clouds/particles covering doors above
-- the highest reached level. Stateless toward the caller: draw(cam, highest) each frame.

local M = {}

-- ── Layout ────────────────────────────────────────────────────────────────────
M.NORMAL_W, M.NORMAL_H = 1063, 403      -- normal.png; every level occupies one NORMAL_H slot
local NORMAL_W, NORMAL_H = M.NORMAL_W, M.NORMAL_H
local FLOOR_W = 1198                    -- floor_top.png / road tile width (right-aligned)
local DOOR_X  = 812                     -- path/door column inside the road tiles
local ROOF_W, ROOF_H = 996, 403         -- roof.png (gate 10 = level 20)

-- world-space vertical centre of a level's slot (y grows downward; higher level = higher up)
function M.floor_center(level)
    return -NORMAL_H * (level - 10) + NORMAL_H * 0.5
end

-- ── Background layers ─────────────────────────────────────────────────────────
-- Layers draw at native pixel size; `rate` only scales scroll speed. The forest is a 2D-tiled
-- fill capped by a treeline fringe (its bottom rows tuck under the fill). The mountains are
-- three depth layers drawn far → near; each is opaque from its ridge base down, so the layer
-- in front always covers the bottom edge of the one behind it.
local BG_FOREST = { key = "bg_near", rate = 0.60, wyTop = 700, rows = 5, tile = 512 }
local BG_FRINGE = { key = "bg_near_top", overlap = 40 }
local BG_MTNS = {
    { key = "bg_far1", rate = 0.20, wyBottom = 1260, hTotal = 640 },
    { key = "bg_far2", rate = 0.26, wyBottom = 1440, hTotal = 560 },
    { key = "bg_far3", rate = 0.32, wyBottom = 1740, hTotal = 714 },
}

-- ── Overlays ──────────────────────────────────────────────────────────────────
local GATE_ROW   = 230                  -- L5 tile row of the guardian gate's base line
local LANTERN_DX = 186                  -- lantern pairs at DOOR_X ± this
local LANTERNS = {
    { L = 2, row = 300 }, { L = 3, row = 140 }, { L = 4, row = 300 },
    { L = 6, row = 250 }, { L = 7, row = 120 }, { L = 8, row = 280 },
}

-- ── Corruption effects (doors above the highest reached level) ────────────────
local FLOOR_DARKEN   = { 0.10, 0.04, 0.14 }  -- tint on an undiscovered floor's art
local DARK_CROP_LEFT = 300                   -- skip the eave; effects cover the trunk only

local SHADOW_MAX   = 260                     -- particle pool cap (motes + spirals)
local SHADOW_RATE  = 72                      -- motes per second per visible floor
local SHADOW_LIFE  = { 0.9, 2.3 }
local SHADOW_RISE  = { 12, 95 }              -- upward drift (world px/s)
local SHADOW_SIZE  = { 0.5, 3.8 }
local SHADOW_SWIRL = 55                      -- horizontal swirl (px/s)
local SPIRAL_RATE  = 7
local SPIRAL_LIFE  = { 1.3, 2.6 }
local SPIRAL_SIZE  = { 1.1, 3.2 }
local SPIRAL_SPIN  = { 70, 250 }             -- deg/s, random direction
local SHADOW_COLS  = {
    { 0.02, 0.00, 0.04 },
    { 0.16, 0.02, 0.24 },
    { 0.09, 0.01, 0.15 },
    { 0.22, 0.03, 0.30 },
}

local CLOUD_COLS, CLOUD_ROWS = 7, 5
local CLOUD_SCALE   = { 0.75, 1.4 }
local CLOUD_SWAY    = 10
local CLOUD_DRIFT   = 24
local CLOUD_OPACITY = 0.9
local CLOUD_COL_A   = { 0.02, 0.00, 0.04 }
local CLOUD_COL_B   = { 0.20, 0.03, 0.28 }

-- ── State ─────────────────────────────────────────────────────────────────────
local _tex = nil
local _cam, _highest = 0, 0             -- refreshed on every draw() call
local _t = 0                            -- scene clock (cloud sway)
local _particles  = {}
local _emit_acc   = 0
local _spiral_acc = 0

function M.setup(tex)
    _tex = tex
end

function M.reset()
    _particles, _emit_acc, _spiral_acc = {}, 0, 0
end

-- ── Draw helpers ──────────────────────────────────────────────────────────────
local function screen_y(world_y) return world_y - _cam end

-- right-aligned floor image at a world-Y top; `dark` tints undiscovered floors
local function draw_floor_img(tx, w, h, world_top, dark)
    if tx == nil or not tx.Loaded then return end
    local res = THEME:GetResolution()
    local y = screen_y(world_top)
    if y > res.Y or y + h < 0 then return end
    if dark then tx:SetColor(FLOOR_DARKEN[1], FLOOR_DARKEN[2], FLOOR_DARKEN[3]) end
    tx:Draw(res.X - w, y)
    if dark then tx:SetColor(1, 1, 1) end
end

local function draw_parallax()
    local res   = THEME:GetResolution()
    local focus = res.Y * 0.5
    for _, mt in ipairs(BG_MTNS) do
        local m = _tex[mt.key]
        if m ~= nil and m.Loaded then
            local mb  = (mt.wyBottom - _cam - focus) * mt.rate + focus
            local top = math.floor(mb + 0.5) - mt.hTotal
            if top < res.Y and top + mt.hTotal > 0 then
                local x = 0
                while x < res.X do m:DrawAtAnchor(x, top, "topleft") ; x = x + m.Width end
            end
        end
    end
    local f = _tex[BG_FOREST.key]
    if f ~= nil and f.Loaded then
        -- convert the origin once and round once; tiles go at exact integer offsets from it
        local base = (BG_FOREST.wyTop - _cam - focus) * BG_FOREST.rate + focus
        base = math.floor(base + 0.5)
        local fr = _tex[BG_FRINGE.key]
        if fr ~= nil and fr.Loaded then
            local fy = base - (fr.Height - BG_FRINGE.overlap)
            if fy < res.Y and fy + fr.Height > 0 then
                local x = 0
                while x < res.X do fr:DrawAtAnchor(x, fy, "topleft") ; x = x + fr.Width end
            end
        end
        for row = 0, BG_FOREST.rows - 1 do
            local y = base + row * BG_FOREST.tile
            if y < res.Y and y + BG_FOREST.tile > 0 then
                local x = 0
                while x < res.X do f:DrawAtAnchor(x, y, "topleft") ; x = x + f.Width end
            end
        end
    end
end

-- ── Tower art ─────────────────────────────────────────────────────────────────
local function road_tex(L)
    if     L == 5 then return _tex.road_forest_stairs   -- forest → stairs transition
    elseif L == 9 then return _tex.road_stairs_base     -- stairs → pagoda-base transition
    elseif L >= 6 then return _tex.road_stairs
    else               return _tex.road_forest end
end

-- slot 0 = dojo (departure point), 1-9 = road column, 10 = pagoda base, 11-19 = doors,
-- 20 = gate 10 wearing the crown, 21+ = beanstalk once gate 10 is beaten
local function draw_level_art(L)
    local wtop = -NORMAL_H * (L - 10)
    if L == 0 then
        local dj = _tex.dojo
        if dj ~= nil and dj.Loaded then draw_floor_img(dj, dj.Width, dj.Height, wtop, false) end
    elseif L >= 1 and L <= 9 then
        draw_floor_img(road_tex(L), FLOOR_W, NORMAL_H, wtop, false)
    elseif L == 10 then
        draw_floor_img(_tex.floor_top, FLOOR_W, NORMAL_H, wtop, false)
    elseif L >= 11 and L <= 20 then
        if L == 20 then
            local rtex = (_highest >= 20 and _tex.roof_beanstalk ~= nil and _tex.roof_beanstalk.Loaded)
                         and _tex.roof_beanstalk or _tex.roof
            draw_floor_img(rtex, ROOF_W, ROOF_H, wtop, L > _highest)
        else
            local ftex = _tex.normal
            if L == 15 and _highest >= 15 and _tex.checkpoint_cleared ~= nil then
                ftex = _tex.checkpoint_cleared
            end
            draw_floor_img(ftex, NORMAL_W, NORMAL_H, wtop, L > _highest)
        end
    else
        if _highest >= 20 then draw_floor_img(_tex.beanstalk, ROOF_W, NORMAL_H, wtop, false) end
    end
end

-- overlays overhang the slot above, so they draw in a second pass after every tile
local function draw_overlays(Lmin, Lmax)
    local res   = THEME:GetResolution()
    local col_x = res.X - FLOOR_W + DOOR_X
    for _, lt in ipairs(LANTERNS) do
        if lt.L >= Lmin and lt.L <= Lmax and _tex.lantern ~= nil and _tex.lantern.Loaded then
            local y = screen_y(-NORMAL_H * (lt.L - 10) + lt.row)
            _tex.lantern:DrawAtAnchor(col_x - LANTERN_DX, y, "bottom")
            _tex.lantern:DrawAtAnchor(col_x + LANTERN_DX, y, "bottom")
        end
    end
    if Lmin <= 5 and 5 <= Lmax and _tex.niomon ~= nil and _tex.niomon.Loaded then
        _tex.niomon:DrawAtAnchor(col_x, screen_y(-NORMAL_H * (5 - 10) + GATE_ROW), "bottom")
    end
end

-- ── Corruption clouds + particles ─────────────────────────────────────────────
-- effect box for an undiscovered door, in world space (x is screen space: no horizontal scroll)
local function floor_world_box(L)
    local res = THEME:GetResolution()
    local c = DARK_CROP_LEFT
    if L >= 11 and L <= 20 then
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
        x  = b[1] + math.random() * b[3],
        wy = b[2] + math.random() * b[4],
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
    local mg = NORMAL_H                     -- seed one slot beyond the screen to avoid pop-in
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
            local a = math.sin((1 - p.life / p.max) * math.pi)
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

local function clamp_center(v, lo, hi)
    if lo >= hi then return (lo + hi) * 0.5 end
    return math.max(lo, math.min(hi, v))
end

-- dark puffs in an oval per undiscovered door, each clamped fully inside the floor image
local function draw_clouds()
    local cl = _tex.cloud
    if cl == nil or not cl.Loaded then return end
    local res = THEME:GetResolution()
    local mg = NORMAL_H
    local drift = math.sin(_t * 0.5) * CLOUD_DRIFT
    for L = 11, 20 do
        if L > _highest then
            local x, wy, w, h = floor_world_box(L)
            if x ~= nil then
                local sy = screen_y(wy)
                if sy < res.Y + mg and sy + h > -mg then
                    for cxi = 0, CLOUD_COLS - 1 do
                        for cyi = 0, CLOUD_ROWS - 1 do
                            local u = (cxi + 0.5) / CLOUD_COLS * 2 - 1
                            local v = (cyi + 0.5) / CLOUD_ROWS * 2 - 1
                            if u * u + v * v <= 1.0 then
                                local idx = cxi * CLOUD_ROWS + cyi
                                local sc = CLOUD_SCALE[1] + (idx % 4) / 4 * (CLOUD_SCALE[2] - CLOUD_SCALE[1])
                                local hw, hh = sc * cl.Width * 0.5, sc * cl.Height * 0.5
                                local px = x  + (cxi + 0.5) / CLOUD_COLS * w + drift + math.sin(_t * 0.9 + idx) * CLOUD_SWAY
                                local py = sy + (cyi + 0.5) / CLOUD_ROWS * h + math.cos(_t * 0.6 + idx * 1.7) * (CLOUD_SWAY * 0.5)
                                px = clamp_center(px, x + hw,  x + w - hw)
                                py = clamp_center(py, sy + hh, sy + h - hh)
                                local t = (idx * 0.618034) % 1
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

-- ── Frame entry point ─────────────────────────────────────────────────────────
function M.draw(cam, highest)
    _cam = cam
    if highest ~= nil then _highest = highest end
    local dt = fps.deltaTime
    _t = _t + dt
    local res = THEME:GetResolution()
    draw_parallax()
    local Lmin = math.max(0, math.floor(10 - (_cam + res.Y + NORMAL_H) / NORMAL_H) - 1)
    local Lmax =             math.floor(10 - (_cam - NORMAL_H) / NORMAL_H) + 1
    for L = Lmin, Lmax do draw_level_art(L) end
    draw_overlays(Lmin, Lmax)
    draw_clouds()
    update_particles(dt) ; emit_particles(dt) ; draw_particles()
end

return M
