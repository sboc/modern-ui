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

-- Damage / healing per mana on spell tooltips (DPM / HPM), read from the spell's description:
--  * "14 to 23" counts as the average (18.5); direct and over-time amounts of one spell add up
--    ("16 to 25 Fire damage and an additional 2 Fire damage over 4 sec" = 22.5)
--  * "N every X sec" / "N each second" is multiplied out over the spell's duration ("for D sec", "Lasts D sec")
--  * a clause counts as healing when it mentions heal, else as damage when it mentions damage; a clause with
--    neither ("and another 98 over 21 sec") belongs to the one before it
--  * weapon bonuses ("N additional damage"), absorbs, damage to attackers and repeating totem attacks are left out
local NOT_AMOUNT = {   -- word after a number that makes it a duration / range / count rather than an amount
    sec = true, second = true, seconds = true, min = true, minute = true, minutes = true,
    yd = true, yds = true, yard = true, yards = true, mana = true, rage = true, energy = true,
    target = true, targets = true, time = true, times = true, charge = true, charges = true,
    stack = true, stacks = true, level = true, additional = true,
}

local function seconds(n, unit)
    unit = unit:lower()
    if unit:find("^sec") then return n end
    if unit:find("^min") then return n * 60 end
end

-- first "for N sec" / "lasts N min" in text
local function durationIn(text)
    for word, n, unit in text:gmatch("(%a+) (%d+%.?%d*) (%a+)") do
        word = word:lower()
        if word == "for" or word == "lasts" then
            local s = seconds(tonumber(n), unit)
            if s then return s end
        end
    end
end

local function amount(text, clause, kind, p, q, n)
    local before, after = clause:sub(1, p - 1):lower(), clause:sub(q)
    if after:find("^%%") or before:find("absorb%a*%s+$") or before:find("with%s+$") then return 0 end
    local word = (after:match("^%s+(%a+)") or ""):lower()
    if kind == "damage" then
        if not (word == "damage" or (word ~= "additional" and after:find("^%s+%a+ damage"))) then return 0 end
        if after:lower():find("^%s+%a*%s*damage to %a*self") then return 0 end   -- Hellfire's damage to the caster
    elseif NOT_AMOUNT[word] then
        return 0
    end
    local rest = after:lower()
    local every = tonumber(rest:match("every (%d+%.?%d*) sec")) or ((rest:find("each second") or rest:find("every second")) and 1)
    if not every then return n end
    local dur = durationIn(after) or durationIn(text)
    return (dur and every > 0) and n * dur / every or 0
end

-- returns total damage, total healing in a spell description
local function spellAmounts(desc)
    local text = desc:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("[\r\n]+", ". ")
    text = text:gsub("(%d),(%d%d%d)", "%1%2")
    text = text:gsub("(%d+%.?%d*) to (%d+%.?%d*)", function(a, b) return tostring((tonumber(a) + tonumber(b)) / 2) end)
    local damage, healing = 0, 0
    for sentence in text:gsub("(%d)%.(%d)", "%1\1%2"):gmatch("[^%.]+") do
        sentence = sentence:gsub("\1", ".")
        local kind
        for clause in sentence:gsub(" and ", ","):gmatch("[^,]+") do
            local low = clause:lower()
            if low:find("heal") then kind = "heal" elseif low:find("damage") then kind = "damage" end
            if kind and not (low:find("attacker") or low:find("repeated")) then
                for p, n, q in clause:gmatch("()(%d+%.?%d*)()") do
                    local v = amount(text, clause, kind, p, q, tonumber(n))
                    if kind == "heal" then healing = healing + v else damage = damage + v end
                end
            end
        end
    end
    return damage, healing
end

local function manaCost(spellID)
    local get = (C_Spell and C_Spell.GetSpellPowerCost) or _G.GetSpellPowerCost
    local costs = get and get(spellID)
    if type(costs) ~= "table" then return end
    local MANA = (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0
    for _, c in ipairs(costs) do
        if (c.type == MANA or c.name == "MANA") and not ns.IsSecret(c.cost) and (c.cost or 0) > 0 then return c.cost end
    end
end

-- spell tooltips (spellbook, action bars, ...): damage / healing per mana, and the spell ID (for the options that
-- take one: custom buff reminders, kept spell ranks)
local function onSpell(tooltip, data)
    local c = ns.db and cfg()
    if not (c and c.enabled and (c.perMana or c.spellID)) or type(data) ~= "table" then return end
    if tooltip.IsForbidden and tooltip:IsForbidden() then return end
    local id = data.id
    if type(id) ~= "number" or ns.IsSecret(id) then return end
    if c.perMana then pcall(function()
        local cost = manaCost(id)
        if not cost then return end
        local getDesc = (C_Spell and C_Spell.GetSpellDescription) or _G.GetSpellDescription
        local desc = getDesc and getDesc(id)
        if type(desc) ~= "string" or ns.IsSecret(desc) or desc == "" then return end
        local damage, healing = spellAmounts(desc)
        local parts = {}
        if damage > 0 then parts[#parts + 1] = ("DPM: %.2f"):format(damage / cost) end
        if healing > 0 then parts[#parts + 1] = ("HPM: %.2f"):format(healing / cost) end
        if #parts == 0 then return end
        local a = UI.colors.accent
        tooltip:AddLine(table.concat(parts, "   "), a[1], a[2], a[3])
    end) end
    if c.spellID then pcall(tooltip.AddLine, tooltip, "Spell ID: " .. id, 0.6, 0.6, 0.65) end
    pcall(tooltip.Show, tooltip)
end

-- Crafting windows: an item shown from one (reagents, the made item) gets a line per character whose saved bank
-- holds some, read from the copies the bags module keeps (each bank as of that character's last banker visit).
-- Reached two ways, since a client may not route the crafting tooltips through TooltipDataProcessor: the item
-- post-call (owner inside a crafting window) and hooks on the crafting Set* methods. molBankDone keeps it to one
-- block per tooltip content; it is cleared with the tooltip.
local CRAFT_FRAMES = { TradeSkillFrame = true, CraftFrame = true, ProfessionsFrame = true, ClassicProfessionFrame = true }

local function inCraftWindow(tooltip)
    local owner = tooltip.GetOwner and tooltip:GetOwner()
    for _ = 1, 10 do
        if not owner then return false end
        local name = owner.GetName and owner:GetName()
        if name and CRAFT_FRAMES[name] then return true end
        owner = owner.GetParent and owner:GetParent()
    end
    return false
end

local function addBankCounts(tooltip)
    local c = ns.db and cfg()
    if not (c and c.enabled and c.bankReagents) or tooltip ~= _G.GameTooltip or tooltip.molBankDone then return end
    if not (ns.CustomBags and ns.CustomBags.BankCounts) then return end
    if tooltip.IsForbidden and tooltip:IsForbidden() then return end
    pcall(function()
        local _, link = tooltip:GetItem()
        if type(link) ~= "string" or ns.IsSecret(link) then return end
        local id = tonumber(link:match("item:(%d+)"))
        if not id then return end
        tooltip.molBankDone = true
        local rows = ns.CustomBags:BankCounts(id)
        if #rows == 0 then return end
        local a = UI.colors.accent
        tooltip:AddLine("In bank:", a[1], a[2], a[3])
        for _, r in ipairs(rows) do tooltip:AddDoubleLine("  " .. r.label, tostring(r.count), 1, 1, 1, 1, 1, 1) end
        tooltip:Show()
    end)
end

local function onCraftItem(tooltip)
    if tooltip == _G.GameTooltip and not tooltip.molBankDone and inCraftWindow(tooltip) then addBankCounts(tooltip) end
end

local function hookCraftTooltips()
    local tt = _G.GameTooltip
    if not tt then return end
    pcall(tt.HookScript, tt, "OnTooltipCleared", function(self) self.molBankDone = nil end)
    for _, m in ipairs({ "SetTradeSkillItem", "SetCraftItem", "SetRecipeReagentItem" }) do
        if type(tt[m]) == "function" then pcall(hooksecurefunc, tt, m, addBankCounts) end
    end
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
    hookCraftTooltips()
    local tdp = _G.TooltipDataProcessor
    if tdp and tdp.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        pcall(tdp.AddTooltipPostCall, Enum.TooltipDataType.Item, onItem)
        pcall(tdp.AddTooltipPostCall, Enum.TooltipDataType.Item, onCraftItem)
        pcall(tdp.AddTooltipPostCall, Enum.TooltipDataType.Unit, colorName)
        if Enum.TooltipDataType.Spell then pcall(tdp.AddTooltipPostCall, Enum.TooltipDataType.Spell, onSpell) end
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
