local _, GW = ...

-- Creature portraits from the client: one engine for the Dungeon Guide's
-- encounter list, its boss panel, its map pins and the dungeon HUD's faces.
--
-- SetPortraitTextureFromCreatureDisplayID draws a creature's face into a
-- texture, but the first draw of a creature the client has not loaded yet
-- comes out blank. As in DungeonPlanner (UI/Art.lua, MIT), a creature's
-- first texture is drawn, kept hidden behind the fallback while the model
-- loads, and drawn again once by a single shared timer; after that the
-- creature is "loaded" and every later portrait of it is ready at once.
--
-- Costs and rules:
--   * No OnUpdate, no ticker: one C_Timer.After at a time, only while a
--     creature is loading.
--   * In combat a creature that is not loaded yet is not drawn: the fallback
--     stays and the draw waits for PLAYER_REGEN_ENABLED. Loaded creatures
--     draw at once (a cached face, no model work).
--   * Display IDs only. Callers resolve them (GW.DungeonGuide.DisplayId);
--     an NPC ID is never passed as a display ID.
GW.Portraits = GW.Portraits or {}

local Portraits = GW.Portraits
local Globals = _G or {}
local UI, Theme = GW.UI, GW.Theme

Portraits.LOAD_SECONDS = 2.5
Portraits.MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
Portraits.SKULL = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
Portraits.DEFEATED = "Interface\\RaidFrame\\ReadyCheck-Ready"
Portraits.RARE = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
Portraits.TRASH = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"

local loaded = {}      -- [displayId] = true once a creature finished loading
local waiting = {}     -- textures drawn while their creature loads
local deferred = {}    -- [texture] = { displayId, onReady }: asked for in combat
local timerPending = false
Portraits.loaded = loaded

local function inCombat()
    if type(Globals.InCombatLockdown) ~= "function" then return false end
    local ok, value = pcall(Globals.InCombatLockdown)
    return ok and value == true
end

function Portraits.CanDraw()
    return type(Globals.SetPortraitTextureFromCreatureDisplayID) == "function"
end

local function draw(texture, displayId)
    return pcall(Globals.SetPortraitTextureFromCreatureDisplayID, texture, displayId)
end

local function flush()
    timerPending = false
    local list = waiting
    waiting = {}
    for _, entry in ipairs(list) do
        local texture, displayId = entry[1], entry[2]
        loaded[displayId] = true
        -- Only if the texture still shows that creature.
        if texture.gwDisplay == displayId and not texture.gwReady then
            draw(texture, displayId)
            texture.gwReady = true
            if entry[3] then pcall(entry[3], texture, displayId) end
        end
    end
end

local function schedule()
    if timerPending then return end
    local timer = Globals.C_Timer
    if not timer or type(timer.After) ~= "function" then
        flush()
        return
    end
    timerPending = true
    timer.After(Portraits.LOAD_SECONDS, flush)
end

-- Draws creature displayId into texture. onReady(texture, displayId) runs
-- when the face is complete (at once for a loaded creature). Returns
-- "ready", "loading", "deferred" (combat; drawn after it) or false (no
-- display ID, or the client cannot draw portraits).
function Portraits.Draw(texture, displayId, onReady)
    displayId = tonumber(displayId)
    if not texture or not displayId or displayId <= 0 or not Portraits.CanDraw() then return false end
    deferred[texture] = nil
    if texture.gwDisplay == displayId and texture.gwReady then
        if onReady then pcall(onReady, texture, displayId) end
        return "ready"
    end
    if not loaded[displayId] and inCombat() then
        texture.gwDisplay, texture.gwReady = nil, false
        deferred[texture] = { displayId, onReady }
        return "deferred"
    end
    if not draw(texture, displayId) then
        texture.gwDisplay, texture.gwReady = nil, false
        return false
    end
    texture.gwDisplay = displayId
    if loaded[displayId] then
        texture.gwReady = true
        if onReady then pcall(onReady, texture, displayId) end
        return "ready"
    end
    texture.gwReady = false
    table.insert(waiting, { texture, displayId, onReady })
    schedule()
    return "loading"
end

-- Forgets what a texture shows (a pooled frame about to show another).
function Portraits.Clear(texture)
    if not texture then return end
    deferred[texture] = nil
    texture.gwDisplay, texture.gwReady = nil, false
end

-- Starts loading creatures before anything shows them (out of combat only),
-- into a few parked textures that are reused. Returns how many started.
local staging, stagingTextures, stagingNext = nil, {}, 1
local STAGING_SIZE = 16
function Portraits.Prefetch(displayIds)
    if inCombat() or not Portraits.CanDraw() or type(Globals.CreateFrame) ~= "function" then return 0 end
    local started = 0
    for _, displayId in ipairs(displayIds or {}) do
        displayId = tonumber(displayId)
        if displayId and not loaded[displayId] then
            if not staging then
                staging = Globals.CreateFrame("Frame", nil, Globals.UIParent)
                staging:SetSize(32, 32)
                -- Off screen but shown: a hidden frame does not load models.
                staging:SetPoint("TOPLEFT", Globals.UIParent, "TOPRIGHT", 10000, 0)
                staging:Show()
            end
            local texture = stagingTextures[stagingNext]
            if not texture then
                texture = staging:CreateTexture(nil, "ARTWORK")
                texture:SetAllPoints(staging)
                stagingTextures[stagingNext] = texture
            end
            stagingNext = stagingNext % STAGING_SIZE + 1
            if Portraits.Draw(texture, displayId) == "loading" then started = started + 1 end
        end
    end
    return started
end

function Portraits.OnCombatEnded()
    local list = deferred
    deferred = {}
    for texture, entry in pairs(list) do
        if texture.gwDisplay == nil then Portraits.Draw(texture, entry[1], entry[2]) end
    end
end

-- For tests: a fresh session.
function Portraits.Reset()
    for key in pairs(loaded) do loaded[key] = nil end
    waiting, deferred, timerPending = {}, {}, false
end

function Portraits.Pending()
    return #waiting, timerPending
end

-- The widget -----------------------------------------------------------------------------
--
-- A round creature portrait with a ring: Guildweaver's HUD face, at any
-- size. States (the ring and the face):
--   available  plain ring, full face
--   selected   bright gold ring
--   engaged    red ring (only what the dungeon run observed)
--   defeated   gold ring, greyed face, a check
--   unknown    no display ID: a dim skull (or the given icon)

local RING = { available = "borderStrong", selected = "goldBright", engaged = "bad", defeated = "gold", unknown = "border" }
Portraits.RING = RING

local function mask(frame, texture)
    if type(frame.CreateMaskTexture) ~= "function" or type(texture.AddMaskTexture) ~= "function" then return end
    local circle = frame:CreateMaskTexture()
    pcall(circle.SetTexture, circle, Portraits.MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    circle:SetAllPoints(texture)
    pcall(texture.AddMaskTexture, texture, circle)
end

local function paint(portrait)
    local state = portrait.gwState or "available"
    Theme.Tint(portrait.ring, RING[state] or "borderStrong")
    local defeated = state == "defeated"
    for _, texture in ipairs({ portrait.face, portrait.fallback }) do
        pcall(texture.SetDesaturated, texture, defeated)
    end
    pcall(portrait.face.SetAlpha, portrait.face, defeated and 0.65 or 1)
    pcall(portrait.fallback.SetAlpha, portrait.fallback, portrait.gwIcon and 1 or 0.55)
    UI.SetShown(portrait.check, defeated)
    UI.SetShown(portrait.face, portrait.gwFaceReady == true)
    UI.SetShown(portrait.fallback, portrait.gwFaceReady ~= true)
end

-- A portrait button. opts: onClick(portrait), onEnter(portrait), onLeave.
function UI.Portrait(parent, size, opts)
    opts = opts or {}
    local portrait = UI.CreateFrame("Button", parent)
    portrait:SetSize(size, size)
    local ring = portrait:CreateTexture(nil, "BACKGROUND")
    ring:SetAllPoints(portrait)
    pcall(ring.SetColorTexture, ring, 1, 1, 1, 1)
    mask(portrait, ring)
    local inset = math.max(1.5, size / 22)
    local back = portrait:CreateTexture(nil, "BORDER")
    back:SetPoint("TOPLEFT", portrait, "TOPLEFT", inset, -inset)
    back:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", -inset, inset)
    Theme.Fill(back, "bgInset")
    mask(portrait, back)
    local fallback = portrait:CreateTexture(nil, "ARTWORK")
    fallback:SetPoint("TOPLEFT", portrait, "TOPLEFT", size * 0.22, -size * 0.22)
    fallback:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", -size * 0.22, size * 0.22)
    local face = portrait:CreateTexture(nil, "ARTWORK", nil, 1)
    face:SetAllPoints(back)
    mask(portrait, face)
    face:Hide()
    local check = portrait:CreateTexture(nil, "OVERLAY")
    check:SetSize(math.max(10, size * 0.45), math.max(10, size * 0.45))
    check:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", size * 0.08, -size * 0.08)
    pcall(check.SetTexture, check, Portraits.DEFEATED)
    check:Hide()
    portrait.ring, portrait.back, portrait.fallback, portrait.face, portrait.check = ring, back, fallback, face, check
    portrait.gwState, portrait.gwFaceReady = "available", false
    if opts.onClick then
        pcall(portrait.RegisterForClicks, portrait, "LeftButtonUp")
        portrait:SetScript("OnClick", function() opts.onClick(portrait) end)
    else
        pcall(portrait.EnableMouse, portrait, opts.onEnter ~= nil)
    end
    if opts.onEnter then
        portrait:SetScript("OnEnter", function() opts.onEnter(portrait) end)
        portrait:SetScript("OnLeave", opts.onLeave or UI.HideTooltip)
    end

    -- Shows a creature: its face once ready, the icon (or a skull) until
    -- then and when there is no display ID.
    function portrait:SetCreature(displayId, icon)
        displayId = tonumber(displayId)
        if self.gwIcon ~= icon then
            self.gwIcon = icon
            pcall(self.fallback.SetTexture, self.fallback, icon or Portraits.SKULL)
        end
        if displayId == self.gwDisplay and (self.gwFaceReady or self.gwLoading) then
            paint(self)
            return self.gwFaceReady and "ready" or "loading"
        end
        self.gwDisplay, self.gwFaceReady, self.gwLoading = displayId, false, false
        Portraits.Clear(self.face)
        local result = displayId and Portraits.Draw(self.face, displayId, function(_, ready)
            if self.gwDisplay == ready then
                self.gwFaceReady, self.gwLoading = true, false
                paint(self)
            end
        end) or false
        self.gwLoading = result == "loading" or result == "deferred"
        paint(self)
        return result
    end

    function portrait:SetState(state)
        state = RING[state] and state or "available"
        if self.gwState ~= state then
            self.gwState = state
            paint(self)
        end
    end

    pcall(fallback.SetTexture, fallback, Portraits.SKULL)
    paint(portrait)
    return portrait
end
