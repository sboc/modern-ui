local ADDON, ns = ...
local UI = ns.UI

-- Shaman totem bar: one button per element (fire, earth, water, air) showing the active totem and its
-- time left. Left-click drops the totem last used for that element again, right-click dismisses it.
-- The buttons are secure, so what they cast only changes out of combat.
local T = ns:NewModule("totems")
ns.Totems = T

local bar
local started = false
local SLOTS = {   -- GetTotemInfo slot order
    { name = "Fire", color = { 0.90, 0.35, 0.15 } },
    { name = "Earth", color = { 0.55, 0.75, 0.25 } },
    { name = "Water", color = { 0.25, 0.60, 0.95 } },
    { name = "Air", color = { 0.75, 0.70, 0.95 } },
}

local function cfg() return ns.db.totems end

local function isShaman()
    local _, class = UnitClass("player")
    return class == "SHAMAN"
end

local function spellTexture(spell)
    if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(spell) end
    if GetSpellTexture then return GetSpellTexture(spell) end
end

-- "Searing Totem IV" (the totem's unit name) -> "Searing Totem" (casts the highest known rank)
local function spellName(totem)
    return (totem:gsub("%s+[IVX]+$", ""))
end

local function setSpell(btn, spell)
    if btn.spell == spell then return end
    btn.spell = spell
    ns:AfterCombat("totem_spell_" .. btn.slot, function() btn:SetAttribute("spell", btn.spell) end)
end

local function updateButton(btn)
    local ok, have, name, start, duration, icon = pcall(GetTotemInfo, btn.slot)
    local active = false
    if ok and not ns.IsSecret(have) and have and not ns.IsSecret(name) and type(name) == "string" and name ~= "" then
        active = true
        btn.icon:SetTexture(icon)
        btn.icon:SetDesaturated(false)
        btn.icon:SetAlpha(1)
        if not pcall(btn.cd.SetCooldown, btn.cd, start, duration) then btn.cd:Clear() end
        local spell = spellName(name)
        cfg().last[btn.slot] = spell
        setSpell(btn, spell)
    end
    if not active then
        btn.cd:Clear()
        local last = cfg().last[btn.slot]
        local tex = last and spellTexture(last)
        btn.icon:SetTexture(tex)
        btn.icon:SetDesaturated(true)
        btn.icon:SetAlpha(tex and 0.55 or 0)
        setSpell(btn, last)
    end
    btn.active = active
end

local function updateAll()
    if not bar or not GetTotemInfo then return end
    for _, btn in ipairs(bar.buttons) do updateButton(btn) end
end

local function build()
    bar = CreateFrame("Frame", "ModernUITotemBar", UIParent)
    bar.buttons = {}
    for slot, def in ipairs(SLOTS) do
        local btn = CreateFrame("Button", "ModernUITotemButton" .. slot, bar, "SecureActionButtonTemplate")
        btn.slot = slot
        btn:RegisterForClicks("AnyUp", "AnyDown")
        btn:SetAttribute("type1", "spell")
        btn:SetAttribute("type2", "destroytotem")
        btn:SetAttribute("totem-slot", slot)
        btn.bg = btn:CreateTexture(nil, "BACKGROUND")
        btn.bg:SetAllPoints()
        btn.bg:SetColorTexture(0.04, 0.04, 0.05, 0.85)
        btn.icon = btn:CreateTexture(nil, "ARTWORK")
        btn.icon:SetPoint("TOPLEFT", 1, -1)
        btn.icon:SetPoint("BOTTOMRIGHT", -1, 1)
        btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        btn.cd = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
        btn.cd:SetAllPoints(btn.icon)
        btn.cd:SetDrawEdge(false)
        if btn.cd.SetReverse then btn.cd:SetReverse(true) end
        btn.borders = UI.AddBorder(btn, 1, def.color[1], def.color[2], def.color[3], 1, "OVERLAY")
        btn.hl = btn:CreateTexture(nil, "HIGHLIGHT")
        btn.hl:SetAllPoints()
        btn.hl:SetColorTexture(1, 1, 1, 0.14)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(def.name .. " totem", def.color[1], def.color[2], def.color[3])
            if self.spell then
                GameTooltip:AddLine("Left-click: " .. self.spell, 1, 1, 1)
            else
                GameTooltip:AddLine("Drop a " .. def.name:lower() .. " totem once: this button then casts it again.", 1, 1, 1, true)
            end
            if self.active then GameTooltip:AddLine("Right-click: dismiss", 1, 1, 1) end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        bar.buttons[slot] = btn
    end
    ns.Mover:Register("totembar", bar, "Totem Bar")
end

function T:Start()
    if started or not isShaman() or not GetTotemInfo then return end
    if InCombatLockdown() then
        ns:AfterCombat("totems_start", function() T:Start(); T:Apply() end)
        return
    end
    started = true
    build()
    for _, e in ipairs({ "PLAYER_TOTEM_UPDATE", "PLAYER_ENTERING_WORLD", "SPELLS_CHANGED" }) do
        ns:On(e, updateAll)
    end
end

function T:Init()
    if cfg().enabled then self:Start() end
end

function T:Apply()
    if not ns.db then return end
    local c = cfg()
    if c.enabled and not started then self:Start() end
    if not started then return end
    ns:AfterCombat("totems_apply", function()
        if not c.enabled then bar:Hide() return end
        local size, gap = c.size, c.spacing
        bar:SetScale(c.scale * ns.db.general.scale)
        bar:SetSize(#SLOTS * size + (#SLOTS - 1) * gap, size)
        for i, btn in ipairs(bar.buttons) do
            btn:SetSize(size, size)
            btn:ClearAllPoints()
            btn:SetPoint("LEFT", bar, "LEFT", (i - 1) * (size + gap), 0)
        end
        bar:Show()
        ns.Mover:Position("totembar")
        updateAll()
    end)
end
