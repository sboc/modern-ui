local ADDON, ns = ...
local UI = ns.UI

-- Cooldown manager. Blizzard's cooldown viewers (Essential / Utility /
-- Buffs / Buff bars) are Edit Mode systems: they are anchored through the
-- saved C methods to holders we own (so the Mover can place them - by default
-- Essential sits between the player and target frames), scaled, and their
-- icons are re-skinned: square, cropped, thin border, no ring art.
local CD = ns:NewModule("cooldowns")
ns.Cooldowns = CD

local VIEWERS = {
    { key = "essential", global = "EssentialCooldownViewer", label = "Cooldowns: Essential", w = 220, h = 52 },
    { key = "utility", global = "UtilityCooldownViewer", label = "Cooldowns: Utility", w = 220, h = 34 },
    { key = "buffs", global = "BuffIconCooldownViewer", label = "Cooldowns: Buffs", w = 220, h = 34 },
    { key = "bars", global = "BuffBarCooldownViewer", label = "Cooldowns: Buff bars", w = 255, h = 90 },
}
CD.viewers = VIEWERS

local OVERLAY_ATLAS, OVERLAY_FILE = "UI-HUD-CoolDownManager-IconOverlay", 6707800

local holders = {}
local hooked = {}
local started = false
local skinQueued, placeQueued = false, false

local function cfg() return ns.db.cooldowns end

----------------------------------------------------------------------
-- Skin
----------------------------------------------------------------------
local function skinItem(frame)
    local c = cfg()
    pcall(function()
        for _, k in ipairs({ "Border", "Shadow", "IconShadow", "DebuffBorder", "CooldownFlash" }) do
            local part = frame[k]
            if type(part) == "table" and part.SetAlpha then part:SetAlpha(0) end
        end
        -- square the icon: replace the rounded masks with a plain one
        for _, rgn in ipairs({ frame:GetRegions() }) do
            if type(rgn) == "table" and rgn.IsObjectType then
                if rgn:IsObjectType("MaskTexture") then
                    rgn:SetTexture("Interface\\Buttons\\WHITE8X8")
                elseif rgn:IsObjectType("Texture") and rgn ~= frame.Icon then
                    local atlas = rgn.GetAtlas and rgn:GetAtlas()
                    local tex = rgn.GetTexture and rgn:GetTexture()
                    if atlas == OVERLAY_ATLAS or tex == OVERLAY_FILE then rgn:SetAlpha(0) end
                end
            end
        end
        local cdFrame = frame.Cooldown
        if type(cdFrame) == "table" and cdFrame.GetRegions then
            for _, rgn in ipairs({ cdFrame:GetRegions() }) do
                if type(rgn) == "table" and rgn.IsObjectType and rgn:IsObjectType("MaskTexture") then
                    rgn:SetTexture("Interface\\Buttons\\WHITE8X8")
                end
            end
        end
        local icon = frame.Icon
        if type(icon) == "table" and icon.SetTexCoord and c.zoom then
            icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        end
        if c.borders then
            if not frame.molBorderFrame then
                frame.molBorderFrame = CreateFrame("Frame", nil, frame)
                frame.molBorderFrame:SetAllPoints(type(icon) == "table" and icon or frame)
                frame.molBorderFrame:EnableMouse(false)
                frame.molBorder = UI.AddBorder(frame.molBorderFrame, 1, 0, 0, 0, 1, "OVERLAY")
            end
            frame.molBorderFrame:SetFrameLevel(frame:GetFrameLevel() + 5)
            frame.molBorderFrame:Show()
        elseif frame.molBorderFrame then
            frame.molBorderFrame:Hide()
        end
    end)
end

local function eachItem(viewer, fn)
    local pool = viewer.itemFramePool
    if pool and pool.EnumerateActive then
        for frame in pool:EnumerateActive() do fn(frame) end
    end
end

local function skinAll()
    if not cfg().enabled or not cfg().skin then return end
    for _, v in ipairs(VIEWERS) do
        local viewer = _G[v.global]
        if viewer and cfg().viewers[v.key].enabled then eachItem(viewer, skinItem) end
    end
end

local function requestSkin()
    if skinQueued then return end
    skinQueued = true
    C_Timer.After(0, function() skinQueued = false; skinAll() end)
end

----------------------------------------------------------------------
-- Placement
----------------------------------------------------------------------
local function anchored(viewer, holder)
    local ok, _, rel = pcall(viewer.GetPoint, viewer, 1)
    return ok and rel == holder
end

local function placeViewer(v)
    local viewer, holder = _G[v.global], holders[v.key]
    local vc = cfg().viewers[v.key]
    if not (viewer and holder and vc.enabled) then return end
    viewer.molPlacing = true
    pcall(function()
        holder:SetScale(vc.scale * ns.db.general.scale)
        ns.SetScale(viewer, vc.scale * ns.db.general.scale)
        viewer:SetAlpha(vc.alpha)
        ns.ClearPoints(viewer)
        ns.SetPoint(viewer, "CENTER", holder, "CENTER", 0, 0)
    end)
    viewer.molPlacing = false
    ns.Mover:Position("cdm_" .. v.key)
end

local function placeAll()
    if not cfg().enabled then return end
    for _, v in ipairs(VIEWERS) do placeViewer(v) end
end

-- Blizzard moves its viewers around (Edit Mode applies, layout refreshes,
-- spec changes): every time, check that ours is still where we put it.
local function enforce()
    if not cfg().enabled then return end
    for _, v in ipairs(VIEWERS) do
        local viewer, holder = _G[v.global], holders[v.key]
        if viewer and holder and cfg().viewers[v.key].enabled and not anchored(viewer, holder) then
            placeViewer(v)
        end
    end
end

local function requestPlace()
    if placeQueued then return end
    placeQueued = true
    C_Timer.After(0, function() placeQueued = false; enforce(); requestSkin() end)
end

local function hookViewers()
    for _, v in ipairs(VIEWERS) do
        local viewer = _G[v.global]
        if viewer and not hooked[viewer] then
            hooked[viewer] = true
            if viewer.ApplySystemAnchor then hooksecurefunc(viewer, "ApplySystemAnchor", requestPlace) end
            for _, m in ipairs({ "SetPoint", "ClearAllPoints", "SetScale" }) do
                pcall(hooksecurefunc, viewer, m, function(self)
                    if not self.molPlacing then requestPlace() end
                end)
            end
            for _, m in ipairs({ "RefreshLayout", "UpdateLayout", "Layout" }) do
                if type(viewer[m]) == "function" then
                    pcall(hooksecurefunc, viewer, m, requestPlace)
                end
            end
            if viewer.itemFramePool and viewer.itemFramePool.Acquire then
                pcall(hooksecurefunc, viewer.itemFramePool, "Acquire", requestSkin)
            end
        end
    end
end

----------------------------------------------------------------------
-- Module API
----------------------------------------------------------------------
function CD:Init()
    if not ns.db.cooldowns.enabled then return end
    self:Start()
end

function CD:Start()
    if started then return end
    started = true
    for _, v in ipairs(VIEWERS) do
        local h = CreateFrame("Frame", "ModernUI_cdm_" .. v.key, UIParent)
        h:SetSize(v.w, v.h)
        holders[v.key] = h
        ns.Mover:Register("cdm_" .. v.key, h, v.label)
    end
    ns:On("EDIT_MODE_LAYOUTS_UPDATED", requestPlace)
    ns:On("PLAYER_ENTERING_WORLD", function() hookViewers(); placeAll(); requestPlace() end)
    ns:On("PLAYER_REGEN_ENABLED", requestPlace)
    -- safety net: a slow check that catches anything the hooks miss
    local wd, acc = CreateFrame("Frame"), 0
    wd:SetScript("OnUpdate", function(_, e)
        acc = acc + e
        if acc < 0.5 then return end
        acc = 0
        if ns.db and ns.db.cooldowns.enabled then hookViewers(); enforce() end
    end)
    ns:On("PLAYER_SPECIALIZATION_CHANGED", requestPlace)
    ns:On("TRAIT_CONFIG_UPDATED", requestSkin)
    ns:On("PLAYER_TALENT_UPDATE", requestSkin)
end

function CD:Apply()
    if not ns.db then return end
    if not cfg().enabled then
        if started then ns:Print("Cooldown manager takeover disabled: /reload to restore Blizzard's position.") end
        return
    end
    if not started then self:Start() end
    hookViewers()
    placeAll()
    requestSkin()
end
