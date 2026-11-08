local ADDON, ns = ...
local UI = ns.UI

-- Tooltip skin + default position.
--  * Skin: Blizzard's nine-slice frame is faded out and replaced by a flat
--    background with a 1px border (colored by item quality for items).
--  * Position: tooltips that use the default anchor (world units, buttons
--    without their own anchor) sit with their bottom left corner on the top
--    left corner of action bar 4, a small gap above it.
local TT = ns:NewModule("tooltip")
ns.Tooltip = TT

local TOOLTIPS = {
    "GameTooltip", "ItemRefTooltip", "ItemRefShoppingTooltip1", "ItemRefShoppingTooltip2",
    "ShoppingTooltip1", "ShoppingTooltip2", "EmbeddedItemTooltip", "FriendsTooltip",
}

local started = false
local skinned = {}

local function cfg() return ns.db.tooltip end

local function setBorder(tt, r, g, b)
    if tt.molBG and tt.molBG.borders then tt.molBG.borders:SetColor(r, g, b, 1) end
end

local function restyle(tt)
    local c = cfg()
    local bg = tt.molBG
    if not bg then return end
    bg:SetShown(c.skin)
    bg.bg:SetColorTexture(0.03, 0.03, 0.04, c.bgAlpha)
    local ns9 = tt.NineSlice
    if type(ns9) == "table" and ns9.SetAlpha then pcall(ns9.SetAlpha, ns9, c.skin and 0 or 1) end
end

local function skin(tt)
    if type(tt) ~= "table" or skinned[tt] or not tt.HookScript then return end
    skinned[tt] = true
    local bg = CreateFrame("Frame", nil, tt)
    bg:SetAllPoints()
    bg:SetFrameLevel(math.max(0, tt:GetFrameLevel() - 1))
    bg:EnableMouse(false)
    bg.bg = bg:CreateTexture(nil, "BACKGROUND")
    bg.bg:SetAllPoints()
    bg.borders = UI.AddBorder(bg, 1, 0, 0, 0, 1, "BORDER")
    tt.molBG = bg
    pcall(tt.HookScript, tt, "OnShow", function(self) restyle(self) end)
    pcall(tt.HookScript, tt, "OnTooltipCleared", function(self) setBorder(self, 0, 0, 0) end)
    restyle(tt)
end

local function skinAll()
    for _, name in ipairs(TOOLTIPS) do skin(_G[name]) end
    for _, tt in ipairs({ _G.GameTooltip, _G.ItemRefTooltip }) do
        if type(tt) == "table" then restyle(tt) end
    end
    local bar = _G.GameTooltipStatusBar
    if bar and bar.SetStatusBarTexture then pcall(bar.SetStatusBarTexture, bar, ns:GetTexture()) end
end

local function fonts()
    local c = cfg()
    if not c.fontSize or c.fontSize <= 0 then return end
    for name, delta in pairs({ GameTooltipHeaderText = 2, GameTooltipText = 0, GameTooltipTextSmall = -1 }) do
        local o = _G[name]
        if o and o.SetFont then pcall(o.SetFont, o, ns:GetFont(), c.fontSize + delta, "") end
    end
end

-- true when the tooltip is owned by a quest reward / choice button, so it can be told apart from the
-- equipped-item comparison tooltips shown beside it
local function isQuestReward(tooltip)
    local owner = tooltip.GetOwner and tooltip:GetOwner()
    for _ = 1, 4 do
        if not owner then return false end
        local name = owner.GetName and owner:GetName()
        if owner.type == "reward" or owner.type == "choice"
            or (name and (name:find("^QuestInfo") or name:find("^QuestProgressItem") or name:find("^QuestLogItem"))) then
            return true
        end
        owner = owner.GetParent and owner:GetParent()
    end
    return false
end

-- item quality border (quest rewards get the accent blue instead)
local function onItem(tooltip)
    if not (cfg().enabled and cfg().skin) then return end
    pcall(function()
        if tooltip == _G.GameTooltip and isQuestReward(tooltip) then
            local a = UI.colors.accent
            setBorder(tooltip, a[1], a[2], a[3])
            return
        end
        local _, link = tooltip:GetItem()
        if not link then return end
        local quality = select(3, GetItemInfo(link))
        local col = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
        if col and quality > 1 then setBorder(tooltip, col.r, col.g, col.b) end
    end)
end

-- Puts the tooltip on top of action bar 4. The unit tooltip's health bar hangs BELOW the
-- tooltip, so its height is added to the gap while it is showing.
local function anchorTooltip(tooltip)
    local bar = _G.ModernUIbar4
    if not bar then return end
    local extra = 0
    local sb = _G.GameTooltipStatusBar
    if sb and sb.IsShown and sb:IsShown() then extra = (sb:GetHeight() or 8) + 2 end
    tooltip:ClearAllPoints()
    tooltip:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, (cfg().gap or 6) + extra)
end

-- class / reaction colors for unit tooltips
local function tooltipUnitColor()
    local r, g, b
    pcall(function()
        local _, unit = GameTooltip:GetUnit()
        if not unit then return end
        if UnitIsPlayer(unit) then
            local _, class = UnitClass(unit)
            local col = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
            if col then r, g, b = col.r, col.g, col.b end
        else
            local reaction = UnitReaction(unit, "player")
            local col = reaction and FACTION_BAR_COLORS and FACTION_BAR_COLORS[reaction]
            if col then r, g, b = col.r, col.g, col.b end
        end
    end)
    return r, g, b
end

local colorizing = false
local function colorBar()
    local c = ns.db and cfg()
    local sb = _G.GameTooltipStatusBar
    if colorizing or not (c and c.enabled and c.classBar and sb and sb.SetStatusBarColor) then return end
    local r, g, b = tooltipUnitColor()
    if r then
        colorizing = true
        pcall(sb.SetStatusBarColor, sb, r, g, b)
        colorizing = false
    end
end

local function colorName(tooltip)
    local c = ns.db and cfg()
    if tooltip ~= _G.GameTooltip or not (c and c.enabled and c.className) then return end
    local line = _G.GameTooltipTextLeft1
    if not (line and line.SetTextColor) then return end
    local r, g, b = tooltipUnitColor()
    if r then pcall(line.SetTextColor, line, r, g, b) end
end

local function hookStatusBar()
    local sb = _G.GameTooltipStatusBar
    if not (sb and sb.HookScript) then return end
    pcall(hooksecurefunc, sb, "SetStatusBarColor", colorBar)
    pcall(sb.HookScript, sb, "OnShow", colorBar)
    pcall(sb.HookScript, sb, "OnValueChanged", colorBar)
end

local function hookAnchor()
    if type(_G.GameTooltip_SetDefaultAnchor) ~= "function" then return end
    hooksecurefunc("GameTooltip_SetDefaultAnchor", function(tooltip, parent)
        if tooltip ~= _G.GameTooltip then return end
        tooltip.molAnchored = false
        if not (ns.db and cfg().enabled) then return end
        -- a button on one of our bars (bags, game menu, action buttons): the tooltip goes next to the
        -- button, not to the default corner spot
        if parent and parent ~= UIParent and parent.GetParent then
            local bar = parent:GetParent()
            local pname = bar and bar.GetName and bar:GetName()
            if pname and pname:find("^ModernUI") then
                local x = parent:GetCenter()
                local right = x and x > (UIParent:GetWidth() or 0) / 2
                tooltip:SetOwner(parent, right and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
                return
            end
        end
        if not cfg().anchor then return end
        if not _G.ModernUIbar4 then return end
        tooltip.molAnchored = true
        anchorTooltip(tooltip)
    end)
    local sb = _G.GameTooltipStatusBar
    if sb and sb.HookScript then
        local function refit()
            local tt = _G.GameTooltip
            if not (tt and tt.molAnchored and tt:IsShown()) then return end
            -- only while it is still a default-anchored tooltip (not re-owned by something else)
            local ok, kind = pcall(tt.GetAnchorType, tt)
            if ok and kind == "ANCHOR_NONE" then anchorTooltip(tt) end
        end
        pcall(sb.HookScript, sb, "OnShow", refit)
        pcall(sb.HookScript, sb, "OnHide", refit)
    end
end

-- Any tooltip frame that receives tooltip data (aura tooltips and other add-on / engine frames that are
-- not in TOOLTIPS) is skinned on first use; Blizzard re-applies its backdrop style when the content is
-- set, so the nine-slice is hidden again afterwards.
local function skinAny(tooltip)
    if not (ns.db and cfg().enabled) or type(tooltip) ~= "table" then return end
    if tooltip.IsForbidden and tooltip:IsForbidden() then return end
    pcall(skin, tooltip)
    pcall(restyle, tooltip)
end

local function hookBackdropStyle()
    if type(_G.SharedTooltip_SetBackdropStyle) ~= "function" then return end
    hooksecurefunc("SharedTooltip_SetBackdropStyle", function(tooltip)
        if skinned[tooltip] and ns.db and cfg().enabled then pcall(restyle, tooltip) end
    end)
end

function TT:Init()
    if not ns.db.tooltip.enabled then return end
    self:Start()
end

function TT:Start()
    if started then return end
    started = true
    hookAnchor()
    hookStatusBar()
    local tdp = _G.TooltipDataProcessor
    if tdp and tdp.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        pcall(tdp.AddTooltipPostCall, Enum.TooltipDataType.Item, onItem)
        pcall(tdp.AddTooltipPostCall, Enum.TooltipDataType.Unit, colorName)
    end
    if tdp and tdp.AddTooltipPostCall then
        local all = Enum and Enum.TooltipDataProcessorAllTypes
        if all then
            pcall(tdp.AddTooltipPostCall, all, skinAny)
        elseif Enum and Enum.TooltipDataType then
            for _, t in pairs(Enum.TooltipDataType) do pcall(tdp.AddTooltipPostCall, t, skinAny) end
        end
    end
    hookBackdropStyle()
    ns:On("PLAYER_ENTERING_WORLD", function() TT:Apply() end)
end

function TT:Apply()
    if not ns.db then return end
    if not cfg().enabled then
        if started then ns:Print("Tooltip skin disabled: /reload to restore Blizzard's tooltip.") end
        return
    end
    if not started then self:Start() end
    skinAll()
    fonts()
end
