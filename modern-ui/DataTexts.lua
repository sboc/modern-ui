local ADDON, ns = ...
local UI = ns.UI

-- Data texts: one thin strip with gold, frame rate / latency, durability, free bag slots and a clock.
local DT = ns:NewModule("datatexts")
ns.DataTexts = DT

local strip
local started = false
local warnedLow = false

local function cfg() return ns.db.datatexts end

----------------------------------------------------------------------
-- Data
----------------------------------------------------------------------
local function goldText()
    local c = GetMoney and GetMoney() or 0
    local g, s, cp = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    if g > 0 then return string.format("%d|cffffd700g|r %d|cffc7c7cfs|r", g, s) end
    return string.format("%d|cffc7c7cfs|r %d|cffeda55fc|r", s, cp)
end

-- lowest durability over the equipped items (percent), nil when nothing has durability
local function durability()
    local low
    for slot = 1, 18 do
        local ok, cur, max = pcall(GetInventoryItemDurability, slot)
        if ok and type(cur) == "number" and type(max) == "number" and max > 0 then
            local p = cur / max * 100
            if not low or p < low then low = p end
        end
    end
    return low
end

local function durabilityText()
    local p = durability()
    if not p then return "|cff9e9eadDur|r -" end
    local color = p < 20 and "ff4d4d" or p < 50 and "ffd24d" or "ffffff"
    if p >= 20 then
        warnedLow = false
    elseif not warnedLow then
        warnedLow = true
        ns:Print(string.format("|cffff4d4dLow durability|r: %d%%. Time to repair.", p))
    end
    return string.format("|cff9e9eadDur|r |cff%s%d%%|r", color, p)
end

local function bagSlots()
    local free, total = 0, 0
    local api = C_Container
    if not (api and api.GetContainerNumSlots and api.GetContainerNumFreeSlots) then return 0, 0 end
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        local ok, n = pcall(api.GetContainerNumSlots, bag)
        local ok2, f = pcall(api.GetContainerNumFreeSlots, bag)
        if ok and type(n) == "number" then total = total + n end
        if ok2 and type(f) == "number" then free = free + f end
    end
    return free, total
end

local function bagText()
    local free, total = bagSlots()
    local color = free <= 2 and "ff4d4d" or "ffffff"
    return string.format("|cff9e9eadBags|r |cff%s%d|r/%d", color, total - free, total)
end

local function latency()
    local _, _, home, world = GetNetStats()
    return home or 0, world or 0
end

local function fpsText()
    local home, world = latency()
    return string.format("%d|cff9e9eadfps|r %d|cff9e9eadms|r", math.floor((GetFramerate() or 0) + 0.5), math.max(home, world))
end

local function clockText()
    local m = ns.db.minimap
    return date((m and m.clock24 == false) and "%I:%M %p" or "%H:%M")
end

----------------------------------------------------------------------
-- Class supplies: what the class runs out of. Hunters: ammunition in the ammo slot. Everyone else: reagents
-- counted in the bags (every rank of a reagent family adds up). A reagent the character has never carried
-- stays hidden (a level 10 mage has no use for portal runes); once seen it stays, so "0" is visible.
----------------------------------------------------------------------
local CLASS_ITEMS = {
    WARLOCK = { { label = "Shards", ids = { 6265 }, low = 1 } },
    ROGUE = { { label = "Flash", ids = { 5140 } }, { label = "Blind", ids = { 5530 } } },
    MAGE = { { label = "Powder", ids = { 17020 } }, { label = "Teleport", ids = { 17031 } }, { label = "Portal", ids = { 17032 } } },
    PRIEST = { { label = "Candles", ids = { 17028, 17029 } } },
    DRUID = { { label = "Seeds", ids = { 17034, 17035, 17036, 17037, 17038 }, low = 1 }, { label = "Thornroot", ids = { 17021, 17026 } } },
    SHAMAN = { { label = "Ankhs", ids = { 17030 }, low = 1 } },
    PALADIN = { { label = "Symbols", ids = { 17033, 21177 } } },
}

local function itemCount(id)
    local get = (C_Item and C_Item.GetItemCount) or GetItemCount
    if not get then return 0 end
    local ok, n = pcall(get, id)
    return (ok and type(n) == "number" and not ns.IsSecret(n)) and n or 0
end

local function ammoCount()
    local ok, slot = pcall(GetInventorySlotInfo, "AmmoSlot")
    if not ok or type(slot) ~= "number" or not GetInventoryItemID("player", slot) then return nil end
    local n = GetInventoryItemCount("player", slot)
    return (type(n) == "number" and not ns.IsSecret(n)) and n or nil
end

-- { { label, count, low }, ... } for this character
local function classSupplies()
    local _, class = UnitClass("player")
    local out = {}
    if class == "HUNTER" then
        local n = ammoCount()
        if n then out[1] = { label = "Ammo", count = n, low = ns.db.actionbars.ammoWarn or 0 } end
        return out
    end
    local seen = cfg().seen
    for _, def in ipairs(CLASS_ITEMS[class] or {}) do
        local n = 0
        for _, id in ipairs(def.ids) do n = n + itemCount(id) end
        if n > 0 then seen[def.label] = true end
        if seen[def.label] then out[#out + 1] = { label = def.label, count = n, low = def.low or 5 } end
    end
    return out
end

local function classText()
    local parts = {}
    for _, s in ipairs(classSupplies()) do
        parts[#parts + 1] = string.format("|cff9e9ead%s|r |cff%s%d|r", s.label, s.count < s.low and "ff4d4d" or "ffffff", s.count)
    end
    return table.concat(parts, "  ")
end

-- Clicks never open Blizzard panels: a panel shown from addon code runs tainted, and its own code then fails
-- on secret values (the character frame's status bars did). Only Modern UI's own bag window is toggled.
local function ownBags() return ns.CustomBags and ns.CustomBags.active end
local function toggleBags() if ownBags() then ns.CustomBags:Toggle() end end
local function bagHint() return ownBags() and " Click: bags" or "" end

-- key, text function, refresh on the 1 second tick, tooltip lines, click
local SEGMENTS = {
    { key = "gold", text = goldText, click = toggleBags, tip = function() return "Gold", ownBags() and "Click: bags" or nil end },
    { key = "durability", text = durabilityText, tip = function() return "Durability", "Lowest equipped item" end },
    { key = "bags", text = bagText, click = toggleBags,
      tip = function()
          local free = bagSlots()
          return "Bags", free .. " free slots." .. bagHint()
      end },
    { key = "class", text = classText, tick = true,
      tip = function() return "Class supplies", "Ammunition or reagents. Red when running low." end },
    { key = "fps", text = fpsText, tick = true,
      tip = function()
          local home, world = latency()
          return "Performance", string.format("Home %d ms, world %d ms", home, world)
      end },
    { key = "clock", text = clockText, tick = true, tip = function() return "Clock", date("%A, %d %B %Y") end },
}

----------------------------------------------------------------------
-- Strip
----------------------------------------------------------------------
local GAP, PAD = 16, 8

-- Fixed width (datatexts.width > 0): the strip is cut into equal slots, one per text, and each text is centered
-- in its slot - nothing moves when a number gets longer. Width 0: the strip is as wide as its texts.
local function layout()
    local list = {}
    for _, seg in ipairs(strip.segments) do
        if seg:IsShown() then
            local w = (seg.text:GetText() or "") ~= "" and math.ceil(seg.text:GetStringWidth() or 0) or 0
            seg:ClearAllPoints()
            seg:SetPoint("LEFT", strip, "LEFT", 0, 0)
            seg:SetWidth(1)
            if w > 0 then list[#list + 1] = { seg = seg, w = w } end   -- an empty text (no class supplies) takes no room
        end
    end
    local fixed = cfg().width or 0
    local slot = fixed > 0 and #list > 0 and (fixed - 2 * PAD) / #list or nil
    local x = PAD
    for _, it in ipairs(list) do
        local seg = it.seg
        seg:ClearAllPoints()
        seg:SetPoint("LEFT", strip, "LEFT", x, 0)
        seg:SetWidth(slot or it.w)
        seg.text:ClearAllPoints()
        seg.text:SetPoint(slot and "CENTER" or "LEFT")
        x = x + (slot or (it.w + GAP))
    end
    strip:SetWidth(fixed > 0 and fixed or math.max(40, x - GAP + PAD))
    strip:SetShown(#list > 0)
end

local function refresh(tickOnly)
    if not strip or not ns.db or not cfg().enabled then return end
    for _, seg in ipairs(strip.segments) do
        if seg:IsShown() and (seg.def.tick or not tickOnly) then
            local ok, text = pcall(seg.def.text)
            seg.text:SetText(ok and text or "")
        end
    end
    layout()
end

local function build()
    strip = CreateFrame("Frame", "ModernUIDataTexts", UIParent)
    strip:SetHeight(20)
    strip.bg = strip:CreateTexture(nil, "BACKGROUND")
    strip.bg:SetAllPoints()
    strip.bg:SetColorTexture(0.03, 0.03, 0.04, 0.6)
    strip.borders = UI.AddBorder(strip, 1, 0, 0, 0, 1, "BORDER")
    strip.segments = {}
    for i, def in ipairs(SEGMENTS) do
        local seg = CreateFrame("Button", nil, strip)
        seg.def = def
        seg:SetHeight(20)
        seg.text = seg:CreateFontString(nil, "OVERLAY")
        seg.text:SetPoint("LEFT")
        seg:SetScript("OnClick", function() if def.click and not InCombatLockdown() then pcall(def.click) end end)
        seg:SetScript("OnEnter", function(self)
            local title, line = def.tip()
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM", 0, -4)
            GameTooltip:SetText(title)
            if line then GameTooltip:AddLine(line, 1, 1, 1) end
            GameTooltip:Show()
        end)
        seg:SetScript("OnLeave", function() GameTooltip:Hide() end)
        strip.segments[i] = seg
    end
    local acc = 0
    strip:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc < 1 then return end
        acc = 0
        refresh(true)
    end)
    ns.Mover:Register("datatexts", strip, "Data Texts")
end

function DT:Start()
    if started then return end
    started = true
    build()
    for _, e in ipairs({ "PLAYER_MONEY", "UPDATE_INVENTORY_DURABILITY", "BAG_UPDATE_DELAYED", "PLAYER_ENTERING_WORLD",
                         "PLAYER_EQUIPMENT_CHANGED", "MERCHANT_CLOSED" }) do
        ns:On(e, function() refresh() end)
    end
end

function DT:Init()
    if cfg().enabled then self:Start() end
end

function DT:Apply()
    if not ns.db then return end
    local c = cfg()
    if not c.enabled then
        if strip then strip:Hide() end
        return
    end
    if not started then self:Start() end
    strip:SetScale(c.scale * ns.db.general.scale)
    strip:SetAlpha(c.alpha)
    strip.bg:SetShown(c.background)
    for _, edge in ipairs(strip.borders) do edge:SetShown(c.background) end
    local size = (c.fontSize or 0) > 0 and c.fontSize or ns.db.general.fontSize
    strip:SetHeight(size + 8)
    for _, seg in ipairs(strip.segments) do
        seg:SetHeight(size + 8)
        ns:SetFont(seg.text, size)
        seg:SetShown(c[seg.def.key] and true or false)
    end
    strip:Show()
    refresh()
    ns.Mover:Position("datatexts")
end
