-- ═══════════════════════════════════════════════════════════════════════════════
-- pagoda / Script.lua
-- Pagoda of the Unknown — standalone stage (split out of dan_select).
--
-- Reached from dan_select via the `dan_doors` transition (doors close over the dojo,
-- open onto this title screen) and returns the same way. The title screen layers,
-- bottom-to-top: animated day skybox (Lua3DScene) → the selector's tower scene resting at
-- the base floor (selector.drawTitle — identical to hovering level 10 in the selector) →
-- the pagoda UI (title / best rank / Challenge·Practice·Exit menu), drawn by pagoda.lua.
-- Owns a looping Title BGM that fades in as the doors open and out as they close.
-- All menu / challenge / practice logic lives in pagoda.lua; this file is the shell.
-- ═══════════════════════════════════════════════════════════════════════════════

local OWM      = require("OWM3d")
local pagoda   = require("pagoda")
local selector = require("selector")
local NavInput = require("NavInput")

local TXT = "Textures/tower/"
local SEL = "Textures/selector/"
local PTC = "Textures/particles/"
local SND = "Sounds/"

-- ── Constants ────────────────────────────────────────────────────────────────

local PUCHI_FLOAT_AMP = 6.0
local PUCHI_N_FRAMES  = 2

local BGM_FADE_SEC = 0.7   -- match dan_doors FADE_OUT_SECONDS / FADE_IN_SECONDS

-- Sky animation speed multiplier: the day sky's clouds/sun drift off the scene's time,
-- which advances 1:1 with real time by default (feels static). Scale it up for livelier
-- clouds without touching the fixed noon time-of-day.
local SKY_SPEED = 5

-- ── State ────────────────────────────────────────────────────────────────────

local world        = nil   -- 3D day-sky scene (lazily created on first activate)
local world_failed = false -- disable the skybox for the session if it ever errors
local tex         = nil    -- table of tower + selector textures (built lazily)
local font_header  = nil   -- selector: Practice / Start at... / Exit
local font_name    = nil   -- selector: level name on the details strip
local font_confirm = nil   -- selector: "Accept the Challenge?" prompt
local snd_bgm   = nil

local bgm_vol   = 0.0    -- current BGM volume percent (0..100)
local bgm_fade  = nil    -- "in" | "out" | nil
local exiting   = false  -- true once we've called Exit() to leave for the dojo

-- ── BGM (fade in / out instead of a hard start / stop) ────────────────────────

local function startBGM()
    if snd_bgm == nil then return end
    if not snd_bgm.IsPlaying then
        bgm_vol = 0.0
        snd_bgm:SetVolumePercent(0)
        snd_bgm:SetLoop(true)
        snd_bgm:Play()
    end
    bgm_fade = "in"   -- ramp up to full; a no-op once already at 100
end

local function stopBGM()
    if snd_bgm ~= nil and snd_bgm.IsPlaying then snd_bgm:Stop() end
    bgm_fade = nil
end

-- ── Shared callbacks handed to pagoda.lua (same shape dan_select provided) ─────

local CB = {
    startBGM = startBGM,
    stopBGM  = stopBGM,
    ctx = {},
    puchiSineY    = 0,
    puchiIdxFrame = 0,
}

function CB.startCounter(key, startVal, endVal, interval, mode, updateCallback, onFinish)
    local c = COUNTER:CreateCounter(startVal, endVal, interval, onFinish)
    if mode == "loop"   then c:SetLoop(true)
    elseif mode == "bounce" then c:SetBounce(true) end
    if updateCallback then c:Listen(updateCallback) end
    c:Start()
    CB.ctx[key] = c
    return c
end

function CB.drawPlayerChara(x, y, opacity)
    local chara = GetSaveFile(0):GetCharacter()
    if chara ~= nil and chara.IsValid then
        chara:Update(CHARACTER.ANIM_MENU_NORMAL, true)
        chara:DrawAtAnchor(x, y, CHARACTER.ANIM_MENU_NORMAL, "bottom", 1.0, 1.0, math.floor(opacity * 255))
    end
end

function CB.drawPlayerPuchi(x, y, opacity, idxFrame)
    local puchi = GetSaveFile(0):GetPuchichara()
    if puchi == nil or puchi.tx == nil or not puchi.tx.Loaded then return end
    local frameW = math.floor(puchi.tx.Width / PUCHI_N_FRAMES)
    idxFrame = idxFrame or 0
    puchi.tx:SetScale(1.0, 1.0)
    puchi.tx:SetOpacity(opacity)
    puchi.tx:DrawRectAtAnchor(x, y, idxFrame * frameW, 0, frameW, puchi.tx.Height, "bottom")
    puchi.tx:SetOpacity(1.0)
end

local function load_menu_chara()
    local chara = GetSaveFile(0):GetCharacter()
    if chara ~= nil and chara.IsValid then chara:LoadAnimation(CHARACTER.ANIM_MENU_NORMAL) end
end

-- ── Lazy resource creation ────────────────────────────────────────────────────

-- onStart runs eagerly at skin-load for every stage, so the (relatively heavy) day-sky
-- scene is built on the first real entry instead and kept alive until the stage is torn
-- down, so re-entries after each play round are instant.
local function ensure_world()
    if world ~= nil then return end
    local res = THEME:GetResolution()
    world = OWM.World.new{
        rw = 1280, rh = 720,
        screenW = res.X, screenH = res.Y,
        fov = 30, yaw = 40, pitch = -6,
        lit = true, hour = 12,          -- noon → clear day sky
    }
    world:setFog(false)

    -- Warm the sky shader here (ensure_world runs in activate(), during the door
    -- transition's Load phase while the doors are shut). Otherwise the very first
    -- world:render() — a multi-hundred-ms GPU shader compile — happens inside the
    -- FadeIn's Target.Draw(), which inflates the transition's elapsed time past
    -- FadeInSeconds (0.7s) so `t` clamps to 1.0 and the doors snap open with no
    -- animation on first entry (CStageTransition.cs FadeIn). Best-effort: if an
    -- off-screen warm render isn't valid here, we simply compile on the first draw().
    pcall(function() world:update(0, 0, 0, 0) ; world:render() end)
end

local function ensure_resources()
    if tex == nil then
        tex = {
            -- (landbg.png / floor.png are no longer loaded: the title reuses the selector's
            --  scene, and floor.png only serves as the offline crop source for floor_top +
            --  the top of road_stairs_base)
            floor_top = TEXTURE:CreateTexture(TXT .. "floor_top.png"),   -- level 10 (pagoda base, rows 0-436)
            normal = TEXTURE:CreateTexture(TXT .. "normal.png"),
            roof   = TEXTURE:CreateTexture(TXT .. "roof.png"),
            roof_beanstalk = TEXTURE:CreateTexture(TXT .. "roof_beanstalk.png"), -- roof 1 variant once door 10 beaten
            beanstalk = TEXTURE:CreateTexture(TXT .. "beanstalk.png"),    -- roof 2+ continuity (single repeatable tile)
            checkpoint_cleared = TEXTURE:CreateTexture(TXT .. "checkpoint_cleared.png"),
            -- foreground road column (right-aligned, path @ x=812): repeatable forest/stairs tiles +
            -- the L5/L9 transition tiles. The niōmon gate + lanterns are overlay objects; the dojo
            -- is the full-width top-view tile in the slot BELOW level 1 (the departure point).
            road_forest        = TEXTURE:CreateTexture(TXT .. "road_forest.png"),        -- levels 1-4
            road_stairs        = TEXTURE:CreateTexture(TXT .. "road_stairs.png"),        -- levels 6-8
            road_forest_stairs = TEXTURE:CreateTexture(TXT .. "road_forest_stairs.png"), -- level 5
            road_stairs_base   = TEXTURE:CreateTexture(TXT .. "road_stairs_base.png"),   -- level 9
            dojo    = TEXTURE:CreateTexture(TXT .. "dojo.png"),   -- slot 0: dojo from above
            niomon  = TEXTURE:CreateTexture(TXT .. "gate.png"),   -- guardian gate (L5)
            lantern = TEXTURE:CreateTexture(TXT .. "lantern.png"),
            -- parallax background (separate images): forest fill + treeline fringe + 3 mountain layers
            bg_far1     = TEXTURE:CreateTexture(TXT .. "bg/far1.png"),     -- distant snow peaks (slowest)
            bg_far2     = TEXTURE:CreateTexture(TXT .. "bg/far2.png"),     -- mid ridge
            bg_far3     = TEXTURE:CreateTexture(TXT .. "bg/far3.png"),     -- near ridge + foothills + skirt
            bg_near     = TEXTURE:CreateTexture(TXT .. "bg/near.png"),     -- 2D-tiled forest canopy
            bg_near_top = TEXTURE:CreateTexture(TXT .. "bg/near_top.png"), -- organic treeline cap
            caret    = TEXTURE:CreateTexture(SEL .. "caret.png"),
            caret_up = TEXTURE:CreateTexture(SEL .. "caret_up.png"),
            gate     = TEXTURE:CreateTexture(SEL .. "gate.png"),
            gateT    = TEXTURE:CreateTexture(SEL .. "gateT.png"),
            gateR    = TEXTURE:CreateTexture(SEL .. "gateR.png"),
            details  = TEXTURE:CreateTexture(SEL .. "details.png"),
            frame    = TEXTURE:CreateTexture(SEL .. "frame.png"),
            shadow   = TEXTURE:CreateTexture(PTC .. "shadow.png"),
            spiral   = TEXTURE:CreateTexture(PTC .. "spiral.png"),
            cloud    = TEXTURE:CreateTexture(PTC .. "cloud.png"),
            spark    = TEXTURE:CreateTexture(PTC .. "spark.png"),
            sword    = TEXTURE:CreateTexture(SEL .. "sword.png"),
            black1   = TEXTURE:CreateTexture(SEL .. "black1.png"),
            num = {},
        }
        for d = 0, 9 do tex.num[d] = TEXTURE:CreateTexture(SEL .. "number/" .. d .. ".png") end
    end
    if font_header  == nil then font_header  = TEXT:Create(40, "regular") end
    if font_name    == nil then font_name    = TEXT:Create(30, "regular") end
    if font_confirm == nil then font_confirm = TEXT:Create(64, "regular") end
    selector.setup(world, tex, { header = font_header, name = font_name, confirm = font_confirm })
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

function onStart()
    -- Nothing heavy here: fonts belong to pagoda.lua, and the 3D scene / textures are
    -- created lazily in activate() so a skin-load never spins up an unused day sky.
end

function onDestroy()
    if world ~= nil then world:dispose() ; world = nil end
    if tex ~= nil then
        for _, t in pairs(tex) do
            if type(t) == "table" then for _, g in pairs(t) do if g ~= nil then g:Dispose() end end
            elseif t ~= nil then t:Dispose() end
        end
        tex = nil
    end
    if font_header  ~= nil then font_header:Dispose()  ; font_header  = nil end
    if font_name    ~= nil then font_name:Dispose()    ; font_name    = nil end
    if font_confirm ~= nil then font_confirm:Dispose() ; font_confirm = nil end
    pagoda.destroy()
end

function activate()
    CONFIG.PlayerCount = 1
    CONFIG.SongSpeed   = 20   -- reset speed (a challenge may have changed it)

    exiting      = false
    world_failed = false
    ensure_world()
    ensure_resources()
    load_menu_chara()

    snd_bgm = SOUND:CreateBGM(SND .. "Title.ogg")

    CB.startCounter("puchi_sine", 0, 360, 1/120, "loop", function(val)
        CB.puchiSineY = math.sin(val * math.pi / 180) * PUCHI_FLOAT_AMP
    end)
    CB.startCounter("puchi_frame", 0, 1, 4.8, "loop", function(val)
        CB.puchiIdxFrame = math.floor(val * PUCHI_N_FRAMES)
    end)

    -- Returning from a just-played dan (challenge / practice) restores the post-play
    -- screen; a fresh entry from the dojo opens the title menu.
    if pagoda.is_returning_from_play() then
        pagoda.activate(CB)
        pagoda.on_return(CB)
    else
        pagoda.enter(CB)
    end

    startBGM()   -- silent → swells in during the door-open FadeIn
end

function deactivate()
    stopBGM()
    selector.close()   -- defensive: restore the sky if we ever leave mid-selection
    pagoda.deactivate()

    for k in pairs(CB.ctx) do CB.ctx[k] = COUNTER:EmptyCounter() end

    if snd_bgm ~= nil then snd_bgm:Dispose() ; snd_bgm = nil end
end

function afterSongEnum()
    pagoda.afterSongEnum()
end

-- ── Update ────────────────────────────────────────────────────────────────────

function update()
    local dt = fps.deltaTime

    -- Advance the day sky (drifts clouds / sun via uTime). Guarded: a map-less 3D
    -- scene is an untrodden path, so if it ever throws we drop the skybox for the
    -- session and keep the rest of the title screen alive.
    if world ~= nil and not world_failed then
        if not pcall(world.update, world, dt * SKY_SPEED, 0, 0, 0) then world_failed = true end
    end

    -- BGM fade-in (advances during the door-open FadeIn phase and normal play).
    if bgm_fade == "in" and snd_bgm ~= nil then
        bgm_vol = math.min(100, bgm_vol + dt / BGM_FADE_SEC * 100)
        snd_bgm:SetVolumePercent(bgm_vol)
        if bgm_vol >= 100 then bgm_fade = nil end
    end

    if INPUT:Pressed("ToggleAutoP1") then
        CONFIG:SetAutoStatus(0, not CONFIG:GetAutoStatus(0))
        SHARED:GetSharedSound("Move"):Play()
    end

    -- pagoda.lua ticks CB.ctx itself, drives its state machine, and returns a verb.
    local result = pagoda.update(dt)
    if result == "back" then
        -- Exit → back to the dojo. Fade the Title BGM out as the doors close (draw()
        -- keeps running through the FadeOut phase; update() does not).
        exiting  = true
        bgm_fade = "out"
        return Exit("stage", "dan_select", "dan_doors")
    elseif result == "play" then
        -- pagoda already hard-stopped the BGM via _CB.stopBGM before returning "play".
        return Exit("play", nil)
    end
end

-- ── Draw ─────────────────────────────────────────────────────────────────────

function draw()
    -- Layer 0 — animated day skybox (pcall-guarded, see update()).
    if world ~= nil and not world_failed then
        local ok = pcall(world.render, world)
        if ok then ok = pcall(world.blit, world) end
        if not ok then world_failed = true end
    end

    -- Title background — only when the floor selector isn't up (selector.draw() renders the
    -- same scene itself then). This is the selector's landscape + tower resting at the base
    -- floor (level 10) — identical to hovering it — and since the camera EASES to that pose,
    -- backing out of Challenge/Practice scrolls smoothly home instead of snapping.
    if tex ~= nil and not selector.active then
        selector.drawTitle(pagoda.highest_level())
    end

    -- BGM fade-out while the doors close (update() is frozen once Exit() was called).
    if exiting and bgm_fade == "out" and snd_bgm ~= nil then
        bgm_vol = math.max(0, bgm_vol - fps.deltaTime / BGM_FADE_SEC * 100)
        snd_bgm:SetVolumePercent(bgm_vol)
    end

    -- Layer 5 — pagoda UI (title / best rank / menu / previews / results / nameplate).
    pagoda.draw()
end
