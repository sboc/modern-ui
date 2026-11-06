local ADDON, ns = ...
local UI = ns.UI

-- Bag windows (the item grids, not the bag bar): Blizzard's frame art is faded out and replaced by a
-- flat background with a 1px border; every item slot gets a flat dark square with a border that is
-- colored by item quality. Blizzard keeps owning the buttons, so drag/drop, tooltips, search, sorting,
-- cooldowns and bindings are untouched.
local BW = ns:NewModule("bagwindows")
ns.BagWindows = BW

local MAX_FRAMES = 13
local FRAME_ART = { "NineSlice", "Bg", "TopTileStreaks", "Background1", "Background2", "Background3",
                    "BackgroundTop", "BackgroundMiddle1", "BackgroundMiddle2", "BackgroundBottom" }

-- textures on an item slot that carry information: never hidden
local KEEP_OVERLAYS = { "JunkIcon", "UpgradeIcon", "IconQuestTexture", "NewItemTexture", "IconOverlay", "IconOverlay2",
                        "ItemContextOverlay", "searchOverlay", "SearchOverlay", "ProfessionQualityOverlay",
                        "flash", "Flash", "BagIndicator" }

local started = false
local skinnedFrames = {}

local function cfg() return ns.db.bagwindows end

local function eachItem(frame, fn)
    if frame.EnumerateValidItems then
        local ok = pcall(function()
            for _, b in frame:EnumerateValidItems() do fn(b) end
        end)
        if ok then return end
    end
    if type(frame.Items) == "table" then
        for _, b in ipairs(frame.Items) do fn(b) end
        return
    end
    local name = frame:GetName()
    if not name then return end
    for i = 1, 64 do
        local b = _G[name .. "Item" .. i]
        if b then fn(b) end
    end
end

----------------------------------------------------------------------
-- Item slots
----------------------------------------------------------------------
-- hides a Blizzard texture for good: also fights SetAlpha / Show / SetShown / SetAtlas calls
-- (the empty slot background gets its alpha set to 0.5 by Blizzard on every update)
local function hardKill(tex)
    if type(tex) ~= "table" or not tex.SetAlpha then return end
    tex:SetAlpha(0)
    if tex.molHard then return end
    tex.molHard = true
    for _, m in ipairs({ "SetAlpha", "Show", "SetShown", "SetAtlas", "SetTexture" }) do
        if type(tex[m]) == "function" then
            pcall(hooksecurefunc, tex, m, function(self)
                if self.molFixing then return end
                if self:GetAlpha() ~= 0 then
                    self.molFixing = true
                    self:SetAlpha(0)
                    self.molFixing = false
                end
            end)
        end
    end
end

local function setSlotBorder(btn, r, g, b)
    if btn.molBorder then btn.molBorder:SetColor(r, g, b, 1) end
end

-- border color follows Blizzard's own quality border (IconBorder is hidden, but still driven)
local function syncQuality(btn)
    local c = cfg()
    local ib = btn.IconBorder
    if c.qualityColors and type(ib) == "table" and ib.IsShown and ib:IsShown() and ib.GetVertexColor then
        local ok, r, g, b = pcall(ib.GetVertexColor, ib)
        if ok and type(r) == "number" then
            setSlotBorder(btn, r, g, b)
            return
        end
    end
    setSlotBorder(btn, 0, 0, 0)
end

local function slotEmpty(btn)
    local api = C_Container and C_Container.GetContainerItemInfo
    local bag = btn.GetBagID and btn:GetBagID()
    local slot = btn.GetID and btn:GetID()
    if not (api and bag and slot) then return false end
    local ok, info = pcall(api, bag, slot)
    return ok and info == nil
end

-- everything Blizzard draws on a slot (empty slot background, bevel, frame art) goes;
-- only the item icon and the functional overlays (junk coin, upgrade arrow, quest, new item...) stay
function BW.sweepSlot(btn)
    pcall(function()
        local icon = btn.molIcon
        local name = btn:GetName() or ""
        local keep = { [icon or false] = true, [btn.molBG] = true, [btn.molHL] = true }
        for _, key in ipairs(KEEP_OVERLAYS) do
            local t = btn[key] or _G[name .. key]
            if type(t) == "table" then keep[t] = true end
        end
        for _, region in ipairs({ btn:GetRegions() }) do
            if type(region) == "table" and region.GetObjectType then
                local kind = region:GetObjectType()
                if kind == "MaskTexture" then
                    if type(icon) == "table" and icon.RemoveMaskTexture then pcall(icon.RemoveMaskTexture, icon, region) end
                elseif kind == "Texture" and not keep[region] and type(icon) == "table" then
                    hardKill(region)
                end
            end
        end
    end)
end

local function skinSlot(btn)
    if btn.molSkinned then return end
    btn.molSkinned = true
    local name = btn:GetName() or ""

    ns.KillTexture(btn.NormalTexture)
    ns.KillTexture(btn.PushedTexture)
    ns.KillTexture(btn.IconBorder)
    ns.KillTexture(btn.BattlepayItemTexture)
    ns.KillTexture(btn.SlotHighlightTexture)
    ns.KillTexture(_G[name .. "NormalTexture"])
    if btn.GetNormalTexture then
        local ok, nt = pcall(btn.GetNormalTexture, btn)
        if ok then ns.KillTexture(nt) end
    end

    local icon = btn.icon or btn.Icon or _G[name .. "IconTexture"]
    btn.molIcon = icon
    if type(icon) == "table" then
        for _, m in ipairs({ "CircleMask", "IconMask" }) do
            if btn[m] and icon.RemoveMaskTexture then pcall(icon.RemoveMaskTexture, icon, btn[m]) end
        end
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", -1, 1)
    end

    btn.molBG = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
    btn.molBG:SetAllPoints()
    btn.molBG:SetColorTexture(0.04, 0.04, 0.05, 0.85)

    btn.molBorderFrame = CreateFrame("Frame", nil, btn)
    btn.molBorderFrame:SetAllPoints()
    btn.molBorderFrame:SetFrameLevel(btn:GetFrameLevel() + 5)
    btn.molBorderFrame:EnableMouse(false)
    btn.molBorder = UI.AddBorder(btn.molBorderFrame, 1, 0, 0, 0, 1, "OVERLAY")

    btn.molHL = btn:CreateTexture(nil, "HIGHLIGHT")
    btn.molHL:SetAllPoints()
    btn.molHL:SetColorTexture(1, 1, 1, 0.12)

    BW.sweepSlot(btn)

    -- Blizzard re-colors / shows / hides the quality border on every item change
    local ib = btn.IconBorder
    if type(ib) == "table" then
        for _, m in ipairs({ "SetVertexColor", "Show", "Hide", "SetShown", "SetAtlas" }) do
            if type(ib[m]) == "function" then
                pcall(hooksecurefunc, ib, m, function() if cfg().enabled then syncQuality(btn) end end)
            end
        end
    end
end

local function styleSlot(btn)
    skinSlot(btn)
    BW.sweepSlot(btn)
    local c = cfg()
    btn.molBG:SetShown(c.borders)
    btn.molBorderFrame:SetShown(c.borders)
    local icon = btn.molIcon
    if type(icon) == "table" then icon:SetAlpha(slotEmpty(btn) and 0 or 1) end
    syncQuality(btn)
end

----------------------------------------------------------------------
-- Windows
----------------------------------------------------------------------
local function restyleFrame(frame)
    local c = cfg()
    local bg = frame.molBG
    if not bg then return end
    -- above the chat windows (their tab buttons sit on HIGH)
    if frame:GetFrameStrata() ~= "DIALOG" then pcall(frame.SetFrameStrata, frame, "DIALOG") end
    bg:SetShown(c.skin)
    bg.bg:SetColorTexture(0.04, 0.04, 0.05, c.bgAlpha)
    for _, key in ipairs(FRAME_ART) do
        local art = frame[key]
        if type(art) == "table" and art.SetAlpha then pcall(art.SetAlpha, art, c.skin and 0 or 1) end
    end
    for _, region in ipairs({ frame:GetRegions() }) do
        if type(region) == "table" and region.GetObjectType and region:GetObjectType() == "Texture" then
            pcall(region.SetAlpha, region, c.skin and 0 or 1)
        end
    end
    eachItem(frame, function(btn) pcall(styleSlot, btn) end)
end

local function skinFrame(frame)
    if type(frame) ~= "table" or skinnedFrames[frame] or not frame.HookScript then return end
    skinnedFrames[frame] = true
    local bg = CreateFrame("Frame", nil, frame)
    bg:SetPoint("TOPLEFT", 0, 0)
    bg:SetPoint("BOTTOMRIGHT", 0, 0)
    bg:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
    bg:EnableMouse(false)
    bg.bg = bg:CreateTexture(nil, "BACKGROUND")
    bg.bg:SetAllPoints()
    bg.borders = UI.AddBorder(bg, 1, 0, 0, 0, 1, "BORDER")
    frame.molBG = bg
    pcall(frame.HookScript, frame, "OnShow", function(self) if cfg().enabled then restyleFrame(self) end end)
    for _, m in ipairs({ "UpdateItems", "Update", "UpdateName" }) do
        if type(frame[m]) == "function" then
            pcall(hooksecurefunc, frame, m, function(self) if cfg().enabled and self:IsShown() then restyleFrame(self) end end)
        end
    end
end

local function allFrames()
    local list = { _G.ContainerFrameCombinedBags }
    for i = 1, MAX_FRAMES do list[#list + 1] = _G["ContainerFrame" .. i] end
    return list
end

local restyleQueued = false
local function requestRestyle()
    if restyleQueued or not started then return end
    restyleQueued = true
    C_Timer.After(0, function()
        restyleQueued = false
        if not (ns.db and cfg().enabled) then return end
        for _, f in ipairs(allFrames()) do
            if skinnedFrames[f] and f:IsShown() then restyleFrame(f) end
        end
    end)
end

function BW:Start()
    if started then return end
    started = true
    for _, e in ipairs({ "BAG_UPDATE_DELAYED", "BAG_UPDATE", "ITEM_LOCK_CHANGED", "INVENTORY_SEARCH_UPDATE", "BAG_NEW_ITEMS_UPDATED" }) do
        ns:On(e, requestRestyle)
    end
    ns:On("PLAYER_ENTERING_WORLD", function() BW:Apply() end)
end

function BW:Init()
    if not ns.db.bagwindows.enabled then return end
    self:Start()
end

function BW:Apply()
    if not ns.db then return end
    if not cfg().enabled then
        if started then ns:Print("Bag skin disabled: /reload to restore Blizzard's bags.") end
        return
    end
    if not started then self:Start() end
    for _, f in ipairs(allFrames()) do skinFrame(f) end
    requestRestyle()
end
