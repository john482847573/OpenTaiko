-- ═══════════════════════════════════════════════════════════════════════════════
-- pagoda / Script.lua
-- Pagoda of the Unknown — standalone stage (split out of dan_select).
--
-- Reached from dan_select via the `dan_doors` transition (doors close over the dojo,
-- open onto this title screen) and returns the same way. The title screen layers,
-- bottom-to-top: animated day skybox (Lua3DScene) → landbg → floor → normal ×2 →
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

-- Pagoda tower: vertical nudge where each floor meets the one below. 0 = each floor
-- sits exactly on top of the previous (its bottom edge on the previous top edge) —
-- "just over". Positive overlaps the pieces, negative leaves a gap. The art fills
-- its bounding box, so 0 butts them cleanly.
local STACK_OVERLAP = 0

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
            landbg = TEXTURE:CreateTexture(TXT .. "landbg.png"),
            floor  = TEXTURE:CreateTexture(TXT .. "floor.png"),          -- title-screen tower base
            floor_top    = TEXTURE:CreateTexture(TXT .. "floor_top.png"),    -- selector: level 10 (building)
            floor_bottom = TEXTURE:CreateTexture(TXT .. "floor_bottom.png"), -- selector: level 9 (transparent-padded)
            normal = TEXTURE:CreateTexture(TXT .. "normal.png"),
            roof   = TEXTURE:CreateTexture(TXT .. "roof.png"),
            checkpoint_cleared = TEXTURE:CreateTexture(TXT .. "checkpoint_cleared.png"),
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
    local res   = THEME:GetResolution()
    local res_w = res.X
    local res_h = res.Y

    -- Layer 0 — animated day skybox (pcall-guarded, see update()).
    if world ~= nil and not world_failed then
        local ok = pcall(world.render, world)
        if ok then ok = pcall(world.blit, world) end
        if not ok then world_failed = true end
    end

    -- Title background — only when the floor selector isn't up (it draws its own
    -- scrolling landbg + tower, via pagoda.draw() → selector.draw()).
    if tex ~= nil and not selector.active then
        -- Layer 1 — landbg (full-frame backdrop, pinned bottom-right).
        if tex.landbg ~= nil and tex.landbg.Loaded then
            tex.landbg:DrawAtAnchor(res_w, res_h, "bottomright")
        end

        -- Layers 2-4 — the pagoda tower: floor base at the bottom-right, then two
        -- normal tiers stacked UP the screen, each resting on the roof of the piece
        -- below it (nested by STACK_OVERLAP), so they read as one continuous tower.
        if tex.floor ~= nil and tex.floor.Loaded and tex.normal ~= nil and tex.normal.Loaded then
            local y = res_h
            tex.floor:DrawAtAnchor(res_w, y, "bottomright")
            y = y - tex.floor.Height + STACK_OVERLAP
            tex.normal:DrawAtAnchor(res_w, y, "bottomright")
            y = y - tex.normal.Height + STACK_OVERLAP
            tex.normal:DrawAtAnchor(res_w, y, "bottomright")
        end
    end

    -- BGM fade-out while the doors close (update() is frozen once Exit() was called).
    if exiting and bgm_fade == "out" and snd_bgm ~= nil then
        bgm_vol = math.max(0, bgm_vol - fps.deltaTime / BGM_FADE_SEC * 100)
        snd_bgm:SetVolumePercent(bgm_vol)
    end

    -- Layer 5 — pagoda UI (title / best rank / menu / previews / results / nameplate).
    pagoda.draw()
end
