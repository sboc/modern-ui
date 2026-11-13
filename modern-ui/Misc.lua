local ADDON, ns = ...
local UI = ns.UI

-- Small quality of life features: fast auto loot, an AFK screen and timers for temporary weapon
-- enchants (poisons, sharpening stones, shaman weapon buffs).
local M = ns:NewModule("misc")
ns.Misc = M

local function cfg() return ns.db.misc end

----------------------------------------------------------------------
-- Fast loot: with auto loot on, every slot is taken the moment the loot is ready instead of
-- waiting for the loot window to fill in.
----------------------------------------------------------------------
local lastLoot = 0

local function fastLoot()
    if not (ns.db and cfg().fastLoot) then return end
    local auto = GetCVarBool and GetCVarBool("autoLootDefault") and true or false
    local toggled = IsModifiedClick and IsModifiedClick("AUTOLOOTTOGGLE") and true or false
    if auto == toggled then return end   -- auto loot is not in effect for this loot
    local now = GetTime()
    if now - lastLoot < 0.3 then return end
    lastLoot = now
    local n = GetNumLootItems and GetNumLootItems() or 0
    for i = n, 1, -1 do pcall(LootSlot, i) end
end

----------------------------------------------------------------------
-- AFK screen: dims the screen and shows how long you have been away. Mouse and keyboard pass
-- through, so anything you do ends it as usual.
----------------------------------------------------------------------
local afk

local function buildAfk()
    afk = CreateFrame("Frame", "ModernUIAfkScreen", UIParent)
    afk:SetFrameStrata("FULLSCREEN")
    afk:SetAllPoints(UIParent)
    afk:EnableMouse(false)
    afk.bg = afk:CreateTexture(nil, "BACKGROUND")
    afk.bg:SetAllPoints()
    afk.bg:SetColorTexture(0, 0, 0, 0.65)
    afk.title = afk:CreateFontString(nil, "OVERLAY")
    afk.title:SetPoint("CENTER", 0, 40)
    afk.title:SetTextColor(0.30, 0.82, 1)
    afk.timer = afk:CreateFontString(nil, "OVERLAY")
    afk.timer:SetPoint("TOP", afk.title, "BOTTOM", 0, -10)
    afk.clock = afk:CreateFontString(nil, "OVERLAY")
    afk.clock:SetPoint("TOP", afk.timer, "BOTTOM", 0, -8)
    afk.clock:SetTextColor(0.62, 0.62, 0.68)
    local acc = 1
    afk:SetScript("OnUpdate", function(self, dt)
        acc = acc + dt
        if acc < 1 then return end
        acc = 0
        local s = math.floor(GetTime() - (self.since or GetTime()))
        self.timer:SetText(string.format("%02d:%02d", math.floor(s / 60), s % 60))
        self.clock:SetText(date("%H:%M"))
    end)
    afk:Hide()
end

local function updateAfk()
    local away = false
    if ns.db and cfg().afkScreen and not InCombatLockdown() then
        local ok, v = pcall(UnitIsAFK, "player")
        away = ok and not ns.IsSecret(v) and v and true or false
    end
    if not away then
        if afk then afk:Hide() end
        return
    end
    if not afk then buildAfk() end
    if afk:IsShown() then return end
    ns:SetFont(afk.title, 40, "OUTLINE")
    ns:SetFont(afk.timer, 28, "OUTLINE")
    ns:SetFont(afk.clock, 18, "OUTLINE")
    afk.title:SetText((UnitName("player") or "") .. "  -  AFK")
    afk.since = GetTime()
    afk:Show()
end

----------------------------------------------------------------------
-- Temporary weapon enchants: main / off hand icon with the time left.
----------------------------------------------------------------------
local we   -- holder frame
local WE_SLOTS = { 16, 17 }

local function timeText(sec)
    if sec >= 3600 then return string.format("%dh", math.floor(sec / 3600 + 0.5)) end
    if sec >= 60 then return string.format("%dm", math.floor(sec / 60 + 0.5)) end
    return string.format("%d", sec)
end

local function updateEnchants()
    if not we then return end
    local on = ns.db and ns.db.weaponenchants.enabled and GetWeaponEnchantInfo
    local info = {}
    if on then
        local ok, hasMain, mainMs, mainCharges, _, hasOff, offMs, offCharges = pcall(GetWeaponEnchantInfo)
        if ok and not ns.IsSecret(hasMain) and not ns.IsSecret(hasOff) then
            info[1] = hasMain and { ms = mainMs, charges = mainCharges } or nil
            info[2] = hasOff and { ms = offMs, charges = offCharges } or nil
        end
    end
    local unlocked = ns.Mover and ns.Mover:IsUnlocked()
    for i, icon in ipairs(we.icons) do
        local e = info[i]
        if e then
            icon.tex:SetTexture(GetInventoryItemTexture("player", WE_SLOTS[i]))
            local ok = pcall(function()
                local sec = e.ms / 1000
                icon.time:SetText(timeText(sec))
                if sec < 60 then icon.time:SetTextColor(1, 0.3, 0.3) else icon.time:SetTextColor(1, 1, 1) end
                icon.count:SetText((e.charges and e.charges > 0) and e.charges or "")
            end)
            if not ok then icon.time:SetText(""); icon.count:SetText("") end
            icon:Show()
        else
            icon:Hide()
        end
    end
    we:SetShown(on and (info[1] or info[2] or unlocked) and true or false)
end

local function buildEnchants()
    we = CreateFrame("Frame", "ModernUIWeaponEnchants", UIParent)
    we.icons = {}
    for i, slot in ipairs(WE_SLOTS) do
        local icon = CreateFrame("Frame", nil, we)
        icon:EnableMouse(true)
        icon.bg = icon:CreateTexture(nil, "BACKGROUND")
        icon.bg:SetAllPoints()
        icon.bg:SetColorTexture(0.04, 0.04, 0.05, 0.85)
        icon.tex = icon:CreateTexture(nil, "ARTWORK")
        icon.tex:SetPoint("TOPLEFT", 1, -1)
        icon.tex:SetPoint("BOTTOMRIGHT", -1, 1)
        icon.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        icon.borders = UI.AddBorder(icon, 1, 0.55, 0.25, 0.85, 1, "OVERLAY")
        icon.time = icon:CreateFontString(nil, "OVERLAY")
        icon.time:SetPoint("CENTER", 0, 0)
        icon.count = icon:CreateFontString(nil, "OVERLAY")
        icon.count:SetPoint("BOTTOMRIGHT", 1, 0)
        icon:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            if not pcall(GameTooltip.SetInventoryItem, GameTooltip, "player", slot) then GameTooltip:Hide() return end
            GameTooltip:Show()
        end)
        icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
        icon:Hide()
        we.icons[i] = icon
    end
    local acc = 0
    we.driver = CreateFrame("Frame")
    we.driver:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc < 0.5 then return end
        acc = 0
        updateEnchants()
    end)
    ns.Mover:Register("weaponenchant", we, "Weapon Enchants")
end

local function layoutEnchants()
    local c = ns.db.weaponenchants
    if not c.enabled then
        if we then we:Hide() end
        return
    end
    if not GetWeaponEnchantInfo then return end
    if not we then buildEnchants() end
    local size = c.size
    we:SetScale(ns.db.general.scale)
    we:SetSize(size * 2 + 2, size)
    for i, icon in ipairs(we.icons) do
        icon:SetSize(size, size)
        icon:ClearAllPoints()
        icon:SetPoint("LEFT", we, "LEFT", (i - 1) * (size + 2), 0)
        ns:SetFont(icon.time, math.max(8, math.floor(size * 0.45)), "OUTLINE")
        ns:SetFont(icon.count, math.max(7, math.floor(size * 0.38)), "OUTLINE")
    end
    ns.Mover:Position("weaponenchant")
    updateEnchants()
end

----------------------------------------------------------------------
-- Module API
----------------------------------------------------------------------
function M:Init()
    ns:On("LOOT_READY", fastLoot)
    ns:On("PLAYER_FLAGS_CHANGED", function(_, unit) if unit == "player" then updateAfk() end end)
    ns:On("PLAYER_REGEN_DISABLED", updateAfk)
    ns:On("PLAYER_ENTERING_WORLD", updateAfk)
end

function M:Apply()
    if not ns.db then return end
    updateAfk()
    layoutEnchants()
end
