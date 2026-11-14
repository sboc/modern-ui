local ADDON, ns = ...
local UI = ns.UI

-- Unit frame replacement. Plain secure unit buttons (target on click, menu on
-- right click) with health / power / absorb / cast bars and aura rows.
-- Everything that reads unit data is written to survive Midnight's "secret
-- values": numbers are only handed to StatusBars / string.format, never
-- compared or used in arithmetic unless they are verified non-secret.
local UF = ns:NewModule("unitframes")
ns.UnitFrames = UF

local IsSecret = ns.IsSecret
local hider = CreateFrame("Frame")
hider:Hide()

local SINGLES = {
    { key = "player", unit = "player", label = "Player Frame" },
    { key = "target", unit = "target", label = "Target Frame" },
    { key = "targettarget", unit = "targettarget", label = "Target of Target Frame" },
    { key = "focus", unit = "focus", label = "Focus Frame" },
    { key = "pet", unit = "pet", label = "Pet Frame" },
}
local GROUPS = {
    { key = "party", label = "Party Frames", units = { "party1", "party2", "party3", "party4" } },
    { key = "boss", label = "Boss Frames", units = { "boss1", "boss2", "boss3", "boss4", "boss5" } },
}

local frames = {}      -- every unit button
local byKey = {}       -- key -> frame or group container
local started = false

local function interp(smooth)
    if smooth and Enum and Enum.StatusBarInterpolation then
        return Enum.StatusBarInterpolation.ExponentialEaseOut
    end
end

local function setBar(bar, value)
    local i = interp(ns.db.unitframes.smooth)
    if i then bar:SetValue(value, i) else bar:SetValue(value) end
end

----------------------------------------------------------------------
-- Colors
----------------------------------------------------------------------
local function unitColor(unit)
    local g = ns.db.unitframes
    local r, gr, b = 0.25, 0.78, 0.25
    pcall(function()
        if UnitIsPlayer(unit) then
            if g.classColor then
                local _, class = UnitClass(unit)
                local c = class and RAID_CLASS_COLORS[class]
                if c then r, gr, b = c.r, c.g, c.b end
            end
        elseif g.reactionColor then
            if UnitIsTapDenied and UnitIsTapDenied(unit) then
                r, gr, b = 0.55, 0.55, 0.55
            else
                local rx = UnitReaction(unit, "player")
                if rx then
                    if rx >= 5 then r, gr, b = 0.25, 0.78, 0.25
                    elseif rx == 4 then r, gr, b = 1, 0.85, 0.1
                    else r, gr, b = 0.85, 0.2, 0.2 end
                end
            end
        end
    end)
    return r, gr, b
end

local function powerColor(unit)
    local ptype, token = UnitPowerType(unit)
    local c = (token and PowerBarColor and PowerBarColor[token]) or (PowerBarColor and PowerBarColor[ptype])
    if c then return c.r, c.g, c.b end
    return 0.4, 0.5, 0.9
end

----------------------------------------------------------------------
-- Element updates
----------------------------------------------------------------------
local function healthPercent(unit)
    local ok, s = pcall(function()
        if UnitHealthPercent then
            local scale = CurveConstants and CurveConstants.ScaleTo100
            return string.format("%.0f%%", UnitHealthPercent(unit, true, scale))
        end
        local c, m = UnitHealth(unit), UnitHealthMax(unit)
        return string.format("%.0f%%", c / m * 100)
    end)
    return ok and s or ""
end

local function updateHealth(f)
    local unit, cfg = f.unit, f.cfg
    if not cfg or not UnitExists(unit) then return end
    local ok = pcall(function()
        local max = UnitHealthMax(unit)
        f.health:SetMinMaxValues(0, max)
        setBar(f.health, UnitHealth(unit))
        f.absorb:SetMinMaxValues(0, max)
        f.absorb:SetValue(UnitGetTotalAbsorbs and UnitGetTotalAbsorbs(unit) or 0)
    end)
    if not ok then f.absorb:SetValue(0) end

    -- incoming heals: a bar that starts where the health fill ends (clipped to the health bar)
    local predict = ns.db.unitframes.healPrediction and UnitGetIncomingHeals and true or false
    if predict then
        predict = pcall(function()
            f.heal:SetMinMaxValues(0, UnitHealthMax(unit))
            f.heal:SetValue(UnitGetIncomingHeals(unit) or 0)
        end)
    end
    f.heal:SetShown(predict)

    local dead, offline = false, false
    pcall(function()
        offline = not UnitIsConnected(unit)
        dead = UnitIsDeadOrGhost(unit)
    end)
    if offline or dead then
        f.health:SetStatusBarColor(0.4, 0.4, 0.4)
    else
        f.health:SetStatusBarColor(unitColor(unit))
    end

    local text = ""
    local fmt = (cfg.healthFormat and cfg.healthFormat ~= "") and cfg.healthFormat or ns.db.unitframes.healthTextFormat
    if cfg.showHealthText and fmt ~= "NONE" then
        if offline then text = "Offline"
        elseif dead then text = "Dead"
        else
            local ok2, res = pcall(function()
                if fmt == "CURRENT" then
                    return ns.ShortNumber(UnitHealth(unit))
                elseif fmt == "PERCENT" then
                    return healthPercent(unit)
                elseif fmt == "CURRENT_MAX" then
                    return string.format("%s / %s", ns.ShortNumber(UnitHealth(unit)), ns.ShortNumber(UnitHealthMax(unit)))
                end
                return string.format("%s  %s", ns.ShortNumber(UnitHealth(unit)), healthPercent(unit))
            end)
            text = ok2 and res or ""
        end
    end
    f.hpText:SetText(text)
end

local function updatePower(f)
    local unit, cfg = f.unit, f.cfg
    if not cfg or not cfg.showPower or not UnitExists(unit) then return end
    local ptype = UnitPowerType(unit)
    pcall(function()
        f.power:SetMinMaxValues(0, UnitPowerMax(unit, ptype))
        setBar(f.power, UnitPower(unit, ptype))
    end)
    f.power:SetStatusBarColor(powerColor(unit))
    if cfg.showPowerText then
        local ok, s = pcall(function() return ns.ShortNumber(UnitPower(unit, ptype)) end)
        f.powerText:SetText(ok and s or "")
    else
        f.powerText:SetText("")
    end
end

local function updateName(f)
    local unit = f.unit
    if not UnitExists(unit) then return end
    local name = UnitName(unit)
    if f.cfg and f.cfg.showLevel then
        pcall(function()
            local lvl = UnitLevel(unit)
            lvl = (type(lvl) == "number" and lvl > 0) and lvl or "??"
            name = string.format("%s %s", lvl, name or "")
        end)
    end
    f.name:SetText(name or "")
end

-- Player frame: crossed swords in combat, "zzz" while resting.
local STATE_ICON = "Interface\\CharacterFrame\\UI-StateIcon"
local function updateStatus(f)
    local st = f.status
    if not st then return end
    if not (f.cfg and f.cfg.showIcons) then st:Hide() return end
    if UnitAffectingCombat("player") then
        st:SetTexCoord(0.5, 1, 0, 0.484375)
        st:Show()
    elseif IsResting() then
        st:SetTexCoord(0, 0.5, 0, 0.421875)
        st:Show()
    else
        st:Hide()
    end
end

local function updateIcons(f)
    local unit, cfg = f.unit, f.cfg
    if not cfg or not UnitExists(unit) then return end
    updateStatus(f)
    if not cfg.showIcons then
        f.raidIcon:Hide(); f.leader:Hide(); f.role:Hide()
        return
    end
    local idx = GetRaidTargetIndex(unit)
    if idx then
        pcall(SetRaidTargetIconTexture, f.raidIcon, idx)
        f.raidIcon:Show()
    else
        f.raidIcon:Hide()
    end
    local lead = false
    pcall(function() lead = UnitIsGroupLeader(unit) end)
    f.leader:SetShown(lead and true or false)

    local role = "NONE"
    pcall(function() role = UnitGroupRolesAssigned(unit) end)
    local atlas = (role == "TANK" and "roleicon-tiny-tank") or (role == "HEALER" and "roleicon-tiny-healer")
        or (role == "DAMAGER" and "roleicon-tiny-dps")
    if atlas and (f.cfgKey == "party" or f.cfgKey == "player") and IsInGroup() then
        local ok = pcall(f.role.SetAtlas, f.role, atlas)
        f.role:SetShown(ok)
    else
        f.role:Hide()
    end
end

-- Hunter pet happiness face (Classic API; absent on retail, and nil for non-hunter pets).
local HAPPY_TEX = "Interface\\PetPaperDollFrame\\UI-PetHappiness"
local HAPPY_COORDS = {
    { 0.375, 0.5625, 0, 0.359375 },    -- 1 unhappy
    { 0.1875, 0.375, 0, 0.359375 },    -- 2 content
    { 0, 0.1875, 0, 0.359375 },        -- 3 happy
}
local HAPPY_NAMES = { "Unhappy", "Content", "Happy" }
local HAPPY_DAMAGE = { 75, 100, 125 }
local function updateHappiness(f)
    local ic = f.happiness
    if not ic then return end
    local h, dmg
    local get = GetPetHappiness or (C_PetInfo and C_PetInfo.GetPetHappiness)
    if get and f.cfg and f.cfg.showHappiness ~= false and UnitExists("pet") then
        local ok, a, b = pcall(get)
        if ok and type(a) == "table" then a, b = a.happiness, a.damagePercentage end
        if ok and type(a) == "number" then h, dmg = a, b end
    end
    if not h or not HAPPY_COORDS[h] then ic:Hide() return end
    ic:SetTexCoord(unpack(HAPPY_COORDS[h]))
    ic.happiness, ic.damage = h, dmg or HAPPY_DAMAGE[h]
    ic:Show()
end

-- Combo points (vanilla rules: they belong to the target).
local function updateCombo(f)
    local pips = f.comboPips
    if not pips then return end
    local n = 0
    if f.cfg and f.cfg.showCombo and UnitExists("target") then
        pcall(function()
            if UnitPower and Enum and Enum.PowerType and Enum.PowerType.ComboPoints then
                n = UnitPower("player", Enum.PowerType.ComboPoints) or 0
            end
            if n == 0 and GetComboPoints then n = GetComboPoints("player", "target") or 0 end
        end)
    end
    for i = 1, #pips do pips[i]:SetShown(i <= n) end
end

local function updateSelection(f)
    if f.unit == "target" or f.unit == "player" then return end
    local sel = false
    pcall(function() sel = UnitIsUnit(f.unit, "target") end)
    if sel then f.borders:SetColor(1, 1, 1, 1) else f.borders:SetColor(0, 0, 0, 1) end
end

-- Auras ---------------------------------------------------------------
-- debuff filter: everything, or only what the player can dispel (the client's own filter token)
local function debuffFilter(cfg)
    if not cfg.onlyDispellable then return "HARMFUL" end
    local F = AuraUtil and AuraUtil.AuraFilters
    return "HARMFUL|" .. ((F and F.RaidPlayerDispellable) or "RAID")
end

local function createAuraIcon(parent)
    local b = CreateFrame("Frame", nil, parent)
    b:EnableMouse(true)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 1, -1)
    b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cd:SetAllPoints(b.icon)
    b.cd:SetDrawEdge(false)
    b.cd:SetHideCountdownNumbers(true)
    b.count = b:CreateFontString(nil, "OVERLAY")
    b.count:SetPoint("BOTTOMRIGHT", 2, -1)
    b.border = UI.AddBorder(b, 1, 0, 0, 0, 1, "OVERLAY")
    b:SetScript("OnEnter", function(self)
        if not self.auraID and not self.index then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        pcall(function()
            if not self.auraID then
                GameTooltip:SetUnitAura(self.unit, self.index, self.filter)
            elseif self.isBuff then
                GameTooltip:SetUnitBuffByAuraInstanceID(self.unit, self.auraID, self.filter)
            else
                GameTooltip:SetUnitDebuffByAuraInstanceID(self.unit, self.auraID, self.filter)
            end
        end)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function fillAuraIcon(icon, unit, aura, isBuff, filter)
    icon.unit, icon.auraID, icon.isBuff, icon.filter = unit, aura.auraInstanceID, isBuff, filter
    icon.index = aura.legacyIndex
    icon.icon:SetTexture(aura.icon)
    icon.cd:SetReverse(true)
    local done = false
    if C_UnitAuras and aura.auraInstanceID and C_UnitAuras.GetAuraDuration and icon.cd.SetCooldownFromDurationObject then
        done = pcall(function()
            local d = C_UnitAuras.GetAuraDuration(unit, aura.auraInstanceID)
            if d then icon.cd:SetCooldownFromDurationObject(d) else icon.cd:Clear() end
        end)
    end
    if not done then
        local ok = pcall(function()
            if aura.duration and aura.duration > 0 then
                icon.cd:SetCooldown(aura.expirationTime - aura.duration, aura.duration)
            else
                icon.cd:Clear()
            end
        end)
        if not ok then icon.cd:Clear() end
    end
    local txt = ""
    pcall(function()
        if C_UnitAuras and aura.auraInstanceID and C_UnitAuras.GetAuraApplicationDisplayCount then
            txt = C_UnitAuras.GetAuraApplicationDisplayCount(unit, aura.auraInstanceID, 2, 99)
        elseif aura.applications and aura.applications > 1 then
            txt = tostring(aura.applications)
        end
    end)
    icon.count:SetText(txt or "")
    if isBuff then
        icon.border:SetColor(0, 0, 0, 1)
    else
        icon.border:SetColor(0.7, 0.1, 0.1, 1)
    end
    icon:Show()
end

local function updateAuraGroup(f, kind)
    local cfg, unit = f.cfg, f.unit
    local box = f[kind]
    local isBuff = (kind == "buffs")
    local enabled = isBuff and cfg.showBuffs or (not isBuff and cfg.showDebuffs)
    if not enabled or not UnitExists(unit) then
        for _, ic in ipairs(box.icons) do ic:Hide() end
        return 0
    end
    local filter = isBuff and "HELPFUL" or debuffFilter(cfg)
    if (isBuff and cfg.onlyMyBuffs) or (not isBuff and cfg.onlyMyDebuffs) then filter = filter .. "|PLAYER" end
    local shown = 0
    local idx = 1
    while shown < cfg.auraCount and idx <= 40 do
        local aura = ns.GetAuraAt(unit, idx, filter, isBuff)
        local ok = aura ~= nil
        if not ok or not aura then break end
        idx = idx + 1
        local icon = box.icons[shown + 1]
        if icon then
            local filled = pcall(fillAuraIcon, icon, unit, aura, isBuff, filter)
            if filled then shown = shown + 1 end
        end
    end
    for i = shown + 1, #box.icons do box.icons[i]:Hide() end
    return shown
end

local function updateAuras(f)
    if not f.cfg or f.engineAuras then return end
    local debuffs = updateAuraGroup(f, "debuffs")
    updateAuraGroup(f, "buffs")
    -- buffs stacked above the debuffs: sit right on top of the debuff rows that are actually shown
    if f.buffsAboveBase then
        local rows = math.ceil((debuffs or 0) / f.buffsPer)
        f.buffs:ClearAllPoints()
        f.buffs:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, f.buffsAboveBase + rows * f.buffsStep)
    end
end

-- Cast bar -------------------------------------------------------------
local function castOnUpdate(bar, elapsed)
    local now = GetTime()
    if bar.channel then
        bar:SetValue(bar.endTime - now + bar.startTime)
    else
        bar:SetValue(now)
    end
    if bar.endTime - now <= 0 then bar:Hide() end
    bar.time:SetFormattedText("%.1f", math.max(0, bar.endTime - now))
end

-- duration object path: the bar animates itself, only the remaining time text needs a refresh.
-- The remaining time may be a secret value: it is only ever handed to SetFormattedText.
local function castTimerOnUpdate(bar, elapsed)
    bar.timeAcc = (bar.timeAcc or 0) + elapsed
    if bar.timeAcc < 0.05 then return end
    bar.timeAcc = 0
    local d = bar.duration
    if not (d and d.GetRemainingDuration
            and pcall(function() bar.time:SetFormattedText("%.1f", d:GetRemainingDuration()) end)) then
        bar.time:SetText("")
    end
end

local function doUpdateCast(f)
    local unit, bar = f.unit, f.cast
    local channel = false
    local name, text, tex, startMS, endMS, notInt = nil, nil, nil, nil, nil, nil
    local _
    name, text, tex, startMS, endMS, _, _, notInt = UnitCastingInfo(unit)
    if not name then
        name, text, tex, startMS, endMS, _, notInt = UnitChannelInfo(unit)
        channel = true
    end
    if not name then
        bar:SetScript("OnUpdate", nil)
        bar:Hide()
        return
    end

    bar.icon:SetTexture(tex)
    bar.text:SetText(text or name)
    bar.channel = channel
    bar:SetStatusBarColor(1, 0.7, 0)

    local usedTimer = false
    local dur = channel and UnitChannelDuration and UnitChannelDuration(unit)
        or (not channel and UnitCastingDuration and UnitCastingDuration(unit))
    if dur and bar.SetTimerDuration and Enum and Enum.StatusBarTimerDirection then
        usedTimer = pcall(function()
            local dir = channel and Enum.StatusBarTimerDirection.RemainingTime
                or Enum.StatusBarTimerDirection.ElapsedTime
            bar:SetTimerDuration(dur, Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate, dir)
        end)
    end
    if usedTimer then
        bar.duration = dur
        bar.timeAcc = 1
        bar:SetScript("OnUpdate", castTimerOnUpdate)
    else
        bar.startTime, bar.endTime = startMS / 1000, endMS / 1000
        bar:SetMinMaxValues(bar.startTime, bar.endTime)
        bar:SetScript("OnUpdate", castOnUpdate)
    end

    -- grey out uninterruptible casts
    local tex2 = bar:GetStatusBarTexture()
    if tex2 and tex2.SetVertexColorFromBoolean then
        pcall(tex2.SetVertexColorFromBoolean, tex2, notInt, CreateColor(0.6, 0.6, 0.6, 1), CreateColor(1, 0.7, 0, 1))
    else
        pcall(function() if notInt then bar:SetStatusBarColor(0.6, 0.6, 0.6) end end)
    end
    bar:Show()
end

local function updateCast(f)
    -- with the long focus cast bar on, the focus frame carries no cast bar of its own
    local suppressed = f.cfgKey == "focus" and ns.db.unitframes.focusCast and ns.db.unitframes.focusCast.enabled
    if not f.cfg or not f.cfg.showCastbar or suppressed or not UnitExists(f.unit) then
        f.cast:SetScript("OnUpdate", nil)
        f.cast:Hide()
        return
    end
    if not pcall(doUpdateCast, f) then
        f.cast:SetScript("OnUpdate", nil)
        f.cast:Hide()
    end
end

local function updateAll(f)
    if not f.cfg or not UnitExists(f.unit) then return end
    updateName(f)
    updateHealth(f)
    updatePower(f)
    updateIcons(f)
    updateAuras(f)
    updateCast(f)
    updateSelection(f)
    updateCombo(f)
    updateHappiness(f)
end

----------------------------------------------------------------------
-- Frame construction
----------------------------------------------------------------------
local UNIT_EVENT_HANDLERS = {
    UNIT_HEALTH = updateHealth, UNIT_MAXHEALTH = updateHealth, UNIT_ABSORB_AMOUNT_CHANGED = updateHealth,
    UNIT_HEAL_PREDICTION = updateHealth,
    UNIT_CONNECTION = updateAll, UNIT_FLAGS = updateHealth, UNIT_FACTION = updateAll,
    UNIT_POWER_UPDATE = function(f) updatePower(f); updateHappiness(f) end, UNIT_MAXPOWER = updatePower, UNIT_DISPLAYPOWER = updateAll,
    UNIT_NAME_UPDATE = updateName, UNIT_LEVEL = updateName,
    UNIT_HAPPINESS = updateHappiness,
    UNIT_AURA = updateAuras, UNIT_PET = updateAll, UNIT_TARGET = updateAll,
    UNIT_SPELLCAST_START = updateCast, UNIT_SPELLCAST_STOP = updateCast, UNIT_SPELLCAST_FAILED = updateCast,
    UNIT_SPELLCAST_INTERRUPTED = updateCast, UNIT_SPELLCAST_DELAYED = updateCast,
    UNIT_SPELLCAST_CHANNEL_START = updateCast, UNIT_SPELLCAST_CHANNEL_STOP = updateCast,
    UNIT_SPELLCAST_CHANNEL_UPDATE = updateCast, UNIT_SPELLCAST_INTERRUPTIBLE = updateCast,
    UNIT_SPELLCAST_NOT_INTERRUPTIBLE = updateCast, UNIT_SPELLCAST_EMPOWER_START = updateCast,
    UNIT_SPELLCAST_EMPOWER_STOP = updateCast, UNIT_SPELLCAST_EMPOWER_UPDATE = updateCast,
}

local function newBar(parent)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    return bar
end

local function makeCastBar(parent)
    local cast = newBar(parent)
    cast:Hide()
    cast.bg = cast:CreateTexture(nil, "BACKGROUND")
    cast.bg:SetAllPoints()
    cast.bg:SetColorTexture(0.03, 0.03, 0.04, 0.9)
    cast.borders = UI.AddBorder(cast, 1, 0, 0, 0, 1, "BORDER")
    cast.icon = cast:CreateTexture(nil, "OVERLAY")
    cast.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    cast.text = cast:CreateFontString(nil, "OVERLAY")
    cast.text:SetJustifyH("LEFT")
    cast.text:SetWordWrap(false)
    cast.time = cast:CreateFontString(nil, "OVERLAY")
    cast.time:SetJustifyH("CENTER")
    return cast
end

local layoutHealth   -- defined below

local function bindUnitEvents(f, unit)
    f:UnregisterAllEvents()
    for event in pairs(UNIT_EVENT_HANDLERS) do
        local u = unit
        if event == "UNIT_TARGET" then u = (unit == "targettarget") and "target" or nil end
        if event == "UNIT_PET" then u = (unit == "pet") and "player" or nil end
        if u then pcall(f.RegisterUnitEvent, f, event, u) end
    end
end

local function createUnitFrame(unit, name, cfgKey)
    local f = CreateFrame("Button", "ModernUI_" .. name, UIParent, "SecureUnitButtonTemplate")
    f.unit, f.cfgKey = unit, cfgKey
    f:SetAttribute("unit", unit)
    f:SetAttribute("*type1", "target")
    f:SetAttribute("*type2", "togglemenu")
    f:RegisterForClicks("AnyUp")

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0.03, 0.03, 0.04, 0.9)
    f.borders = UI.AddBorder(f, 1, 0, 0, 0, 1, "BORDER")

    f.power = newBar(f)
    f.health = newBar(f)
    f.absorb = newBar(f)
    f.absorb:SetFrameLevel(f.health:GetFrameLevel() + 1)
    f.absorb:SetStatusBarColor(1, 1, 1, 0.35)
    f.absorb:SetValue(0)
    f.heal = newBar(f.health)
    f.heal:SetStatusBarColor(0.25, 0.9, 0.45, 0.5)
    f.heal:SetValue(0)
    f.heal:Hide()
    pcall(f.health.SetClipsChildren, f.health, true)

    f.overlay = CreateFrame("Frame", nil, f)
    f.overlay:SetAllPoints()
    f.overlay:SetFrameLevel(f.health:GetFrameLevel() + 5)
    f.overlay:EnableMouse(false)

    f.name = f.overlay:CreateFontString(nil, "OVERLAY")
    f.name:SetJustifyH("LEFT")
    f.name:SetWordWrap(false)
    f.hpText = f.overlay:CreateFontString(nil, "OVERLAY")
    f.hpText:SetJustifyH("RIGHT")
    f.powerText = f.overlay:CreateFontString(nil, "OVERLAY")
    f.powerText:SetJustifyH("RIGHT")

    f.raidIcon = f.overlay:CreateTexture(nil, "OVERLAY")
    f.raidIcon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    f.raidIcon:SetSize(16, 16)
    f.raidIcon:SetPoint("CENTER", f, "TOP", 0, 0)
    f.leader = f.overlay:CreateTexture(nil, "OVERLAY")
    f.leader:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
    f.leader:SetSize(14, 14)
    f.leader:SetPoint("CENTER", f, "TOPLEFT", 2, 0)
    f.role = f.overlay:CreateTexture(nil, "OVERLAY")
    f.role:SetSize(14, 14)
    f.role:SetPoint("CENTER", f, "TOPRIGHT", -2, 0)

    if cfgKey == "player" then
        f.status = f.overlay:CreateTexture(nil, "OVERLAY")
        f.status:SetTexture(STATE_ICON)
        f.status:SetSize(22, 22)
        f.status:SetPoint("CENTER", f, "BOTTOMLEFT", 14, 0)
        f.status:Hide()
    end

    if cfgKey == "pet" then
        f.happiness = f.overlay:CreateTexture(nil, "OVERLAY")
        f.happiness:SetTexture(HAPPY_TEX)
        f.happiness:SetSize(18, 18)
        f.happiness:SetPoint("CENTER", f, "BOTTOMRIGHT", -12, 0)
        f.happiness:Hide()
    end

    f.hl = f.overlay:CreateTexture(nil, "HIGHLIGHT")
    f.hl:SetAllPoints()
    f.hl:SetColorTexture(1, 1, 1, 0.07)

    if cfgKey == "target" then
        f.comboPips = {}
        for i = 1, 5 do
            local pip = f.overlay:CreateTexture(nil, "OVERLAY")
            pip:SetColorTexture(1, 0.82, 0.1, 1)
            pip:SetSize(10, 6)
            pip:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -(5 - i) * 12, 3)
            pip:Hide()
            f.comboPips[i] = pip
        end
    end

    -- cast bar
    local cast = makeCastBar(f)
    f.cast = cast
    cast:HookScript("OnShow", function() if f.cfg and f.cfg.castAnchor == "inside" then layoutHealth(f) end end)
    cast:HookScript("OnHide", function() if f.cfg and f.cfg.castAnchor == "inside" then layoutHealth(f) end end)

    -- aura rows
    for _, kind in ipairs({ "buffs", "debuffs" }) do
        local box = CreateFrame("Frame", nil, f)
        box.icons = {}
        for i = 1, 24 do
            box.icons[i] = createAuraIcon(box)
            box.icons[i]:Hide()
        end
        f[kind] = box
    end

    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if not pcall(GameTooltip.SetUnit, GameTooltip, self.unit) then GameTooltip:Hide() return end
        local hp = self.happiness
        if hp and hp:IsShown() and hp.happiness then
            GameTooltip:AddLine(string.format("Pet happiness: %s (%d%% damage)", HAPPY_NAMES[hp.happiness], hp.damage), 1, 0.82, 0)
        end
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f:SetScript("OnShow", function(self) updateAll(self) end)
    f:SetScript("OnEvent", function(self, event)
        local h = UNIT_EVENT_HANDLERS[event]
        if h then h(self) end
    end)
    bindUnitEvents(f, unit)

    frames[#frames + 1] = f
    f:Hide()
    return f
end

----------------------------------------------------------------------
-- Configuration of one frame
----------------------------------------------------------------------
-- remaining time sits in the middle of the bar, the spell name fills the left half up to it
local function anchorCastTexts(cast, fs)
    cast.time:ClearAllPoints()
    cast.time:SetPoint("CENTER", cast, "CENTER", 0, 0)
    cast.text:SetPoint("RIGHT", cast, "CENTER", -(fs * 1.4 + 4), 0)
end

local function configureCast(f, cfg)
    local cast = f.cast
    local h = cfg.castHeight
    cast:ClearAllPoints()
    cast.icon:ClearAllPoints()
    cast.text:ClearAllPoints()
    cast.time:ClearAllPoints()

    local top = (cfg.castAnchor == "bars") and ns.ActionBars and ns.ActionBars.GetTopBar and ns.ActionBars:GetTopBar()
    local other = (cfg.castAnchor == "between") and byKey.target
    if cfg.castAnchor == "inside" then
        -- a thin line along the bottom of the health bar, just above the power bar (no icon / text)
        local pH = cfg.showPower and cfg.powerHeight or 0
        local baseY = pH > 0 and (pH + 2) or 1
        -- above the health fill, below the name / health text overlay
        cast:SetFrameLevel(f.health:GetFrameLevel() + 3)
        cast:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, baseY)
        cast:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, baseY)
        cast.icon:SetPoint("LEFT", cast, "LEFT", 1, 0)
        cast.icon:SetSize(1, 1)
    elseif other and other ~= f then
        -- in the gap between the player and target frames, vertically centered on the player frame
        cast:SetPoint("LEFT", f, "RIGHT", 4, 0)
        cast:SetPoint("RIGHT", other, "LEFT", -4, 0)
        cast.icon:SetPoint("LEFT", cast, "LEFT", 1, 0)
        cast.icon:SetSize(h - 2, h - 2)
        cast.text:SetPoint("LEFT", cast, "LEFT", h + 4, 0)
    elseif top then
        -- stacked on the top center action bar, same width, icon inside the bar
        -- stacks on the xp / reputation bar when one is showing, otherwise straight on the action bar
        local db = ns.DataBars and ns.DataBars:GetTopBar()
        if db then
            cast:SetPoint("BOTTOMLEFT", db, "TOPLEFT", 0, 2)
            cast:SetPoint("BOTTOMRIGHT", db, "TOPRIGHT", 0, 2)
        else
            cast:SetPoint("BOTTOMLEFT", top, "TOPLEFT", 0, 3)
            cast:SetPoint("BOTTOMRIGHT", top, "TOPRIGHT", 0, 3)
        end
        cast.icon:SetPoint("LEFT", cast, "LEFT", 1, 0)
        cast.icon:SetSize(h - 2, h - 2)
        cast.text:SetPoint("LEFT", cast, "LEFT", h + 4, 0)
    elseif cfg.castAbove then
        local lift = 3 + (cfg.aboveLift or 0)
        cast:SetPoint("BOTTOMLEFT", f, "TOPLEFT", h + 2, lift)
        cast:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, lift)
        cast.icon:SetPoint("TOPRIGHT", cast, "TOPLEFT", -2, 0)
        cast.icon:SetSize(h, h)
        cast.text:SetPoint("LEFT", cast, "LEFT", 4, 0)
    else
        cast:SetPoint("TOPLEFT", f, "BOTTOMLEFT", h + 2, -3)
        cast:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, -3)
        cast.icon:SetPoint("TOPRIGHT", cast, "TOPLEFT", -2, 0)
        cast.icon:SetSize(h, h)
        cast.text:SetPoint("LEFT", cast, "LEFT", 4, 0)
    end
    cast:SetHeight(h)
    local thin = cfg.castAnchor == "inside"
    cast.icon:SetShown(not thin)
    cast.text:SetShown(not thin)
    cast.time:SetShown(not thin)
    cast:SetStatusBarTexture(ns:GetTexture())
    local fs = math.max(8, math.min(ns.db.general.fontSize, h - 3))
    ns:SetFont(cast.text, fs)
    ns:SetFont(cast.time, fs)
    anchorCastTexts(cast, fs)
end

-- Re-anchor the player's cast bar after the action bars changed.
function UF:RefreshCastAnchor()
    local f = byKey.player
    if not (started and f and f.cfg and (f.cfg.castAnchor == "bars" or f.cfg.castAnchor == "between")) then return end
    ns:AfterCombat("uf_castanchor", function() configureCast(f, f.cfg) end)
end

local function configureAuras(f, cfg)
    local size, per = cfg.auraSize, math.max(1, cfg.auraPerRow)
    local side = f.isGroup and not cfg.horizontal   -- auras beside the frame, not above / below
    local castBelow = (cfg.showCastbar and not f.isGroup and not cfg.castAbove and cfg.castAnchor == "frame")
        and (cfg.castHeight + 3) or 0
    local castAbovePad = (cfg.showCastbar and not f.isGroup and cfg.castAbove and cfg.castAnchor == "frame")
        and (cfg.castHeight + 3) or 0
    local lift = (not f.isGroup) and (cfg.aboveLift or 0) or 0   -- room for a frame stacked above (target of target)
    local debuffRows = cfg.showDebuffs and math.ceil(cfg.auraCount / per) or 0
    f.buffsAboveBase = nil

    -- Engine aura rows (the aura lists themselves are not readable from Lua on this client)
    if ns.Auras and ns.Auras.Supported() then
        f.engineAuras = true
        for _, kind in ipairs({ "buffs", "debuffs" }) do f[kind]:Hide() end
        local gap = 2
        local function group(key, filter, extra, border, newLine)
            return { key = key, filter = filter .. (extra and "|PLAYER" or ""), max = cfg.auraCount,
                size = size, gap = gap, border = border, newLine = newLine }
        end
        local debuffs = cfg.showDebuffs and group("debuffs", debuffFilter(cfg), cfg.onlyMyDebuffs, { 0.7, 0.1, 0.1 })
        local buffs = cfg.showBuffs and group("buffs", "HELPFUL", cfg.onlyMyBuffs, { 0, 0, 0 })
        -- your own buffs: right-click cancels them (like Blizzard's buff frame)
        if buffs and f.unit == "player" then buffs.cancel = true end
        local rowWidth = per * (size + gap)
        local top, bottom
        if side then
            -- beside the frame: debuffs, then buffs on the next row
            local groups = {}
            if debuffs then groups[#groups + 1] = debuffs end
            if buffs then buffs.newLine = debuffs and true or nil; groups[#groups + 1] = buffs end
            top = { point = { "TOPLEFT", f, "TOPRIGHT", 4, 0 }, anchor = "TOPLEFT", growH = "Right", growV = "Down",
                    rowWidth = rowWidth, groups = groups }
        elseif cfg.aurasAbove or not buffs then
            -- everything above the frame: debuffs on the row next to it, buffs stacked on top
            local groups = {}
            if debuffs then groups[#groups + 1] = debuffs end
            if buffs and cfg.aurasAbove then
                buffs.newLine = debuffs and true or nil
                groups[#groups + 1] = buffs
            end
            top = { point = { "BOTTOMLEFT", f, "TOPLEFT", 0, 4 + lift + castAbovePad }, anchor = "BOTTOMLEFT",
                    growH = "Right", growV = "Up", rowWidth = rowWidth, groups = groups }
        else
            top = { point = { "BOTTOMLEFT", f, "TOPLEFT", 0, 4 + lift + castAbovePad }, anchor = "BOTTOMLEFT",
                    growH = "Right", growV = "Up", rowWidth = rowWidth, groups = { debuffs or nil } }
            bottom = { point = { "TOPLEFT", f, "BOTTOMLEFT", 0, -(castBelow + 4) }, anchor = "TOPLEFT",
                       growH = "Right", growV = "Down", rowWidth = rowWidth, groups = { buffs } }
        end
        ns.Auras.Set(f, "auraTop", f, f.unit, top)
        ns.Auras.Set(f, "auraBottom", f, f.unit, bottom)
        return
    end
    f.engineAuras = false
    for _, kind in ipairs({ "buffs", "debuffs" }) do
        local box = f[kind]
        box:ClearAllPoints()
        local isBuff = kind == "buffs"
        -- grows upward from the frame top (default for debuffs; buffs too when aurasAbove)
        local up = not side and (not isBuff or cfg.aurasAbove)
        if side then
            if isBuff then box:SetPoint("TOPLEFT", f, "TOPRIGHT", 4, 0)
            else box:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", 4, 0) end
        elseif isBuff and cfg.aurasAbove then
            box:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 4 + lift + castAbovePad + debuffRows * (size + 2))
            f.buffsAboveBase, f.buffsStep, f.buffsPer = 4 + lift + castAbovePad, size + 2, per
        elseif isBuff then
            box:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -(castBelow + 4))
        else
            box:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 4 + lift + castAbovePad)
        end
        box:SetSize(per * (size + 2), size)
        for i, icon in ipairs(box.icons) do
            local col = (i - 1) % per
            local row = math.floor((i - 1) / per)
            icon:SetSize(size, size)
            icon:ClearAllPoints()
            local dy = row * (size + 2)
            if side then
                icon:SetPoint(isBuff and "TOPLEFT" or "BOTTOMLEFT", box, isBuff and "TOPLEFT" or "BOTTOMLEFT",
                    col * (size + 2), isBuff and -dy or dy)
            elseif up then
                icon:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", col * (size + 2), dy)
            else
                icon:SetPoint("TOPLEFT", box, "TOPLEFT", col * (size + 2), -dy)
            end
            ns:SetFont(icon.count, math.max(8, math.floor(size * 0.45)), "OUTLINE")
        end
    end
end

-- Health bar fills the frame above the power bar; while a cast bar sits "inside" the frame
-- and is showing, the health bar gives up that strip.
function layoutHealth(f)
    local cfg = f.cfg
    if not cfg then return end
    local pH = cfg.showPower and cfg.powerHeight or 0
    local lift = 0
    -- (the "inside" cast line overlaps the bottom of the health bar, so nothing moves while casting)
    f.health:ClearAllPoints()
    f.health:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    f.health:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    if pH > 0 then
        f.health:SetPoint("BOTTOMLEFT", f.power, "TOPLEFT", 0, 1 + lift)
        f.health:SetPoint("BOTTOMRIGHT", f.power, "TOPRIGHT", 0, 1 + lift)
    else
        f.health:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1 + lift)
        f.health:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1 + lift)
    end
end

local function configureFrame(f, scale)
    local cfg = ns.db.unitframes.frames[f.cfgKey]
    f.cfg = cfg
    local w, h = cfg.width, cfg.height
    f:SetSize(w, h)
    if scale then f:SetScale(scale) end

    local tex = ns:GetTexture()
    for _, bar in ipairs({ f.health, f.power, f.absorb, f.heal }) do bar:SetStatusBarTexture(tex) end
    f.absorb:SetStatusBarColor(1, 1, 1, 0.35)
    f.heal:SetStatusBarColor(0.25, 0.9, 0.45, 0.5)
    local fill = f.health:GetStatusBarTexture()
    f.heal:ClearAllPoints()
    if fill then
        f.heal:SetPoint("TOPLEFT", fill, "TOPRIGHT", 0, 0)
        f.heal:SetPoint("BOTTOMLEFT", fill, "BOTTOMRIGHT", 0, 0)
        f.heal:SetWidth(math.max(1, cfg.width - 2))
    end

    local pH = cfg.showPower and cfg.powerHeight or 0
    f.power:ClearAllPoints()
    f.absorb:ClearAllPoints()
    if pH > 0 then
        f.power:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
        f.power:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
        f.power:SetHeight(pH)
        f.power:Show()
    else
        f.power:Hide()
    end
    layoutHealth(f)
    f.absorb:SetAllPoints(f.health)

    local fs = math.max(8, math.min(ns.db.general.fontSize, math.floor(h * 0.45)))
    if (cfg.fontSize or 0) > 0 then fs = cfg.fontSize end   -- own text size for this frame
    ns:SetFont(f.name, fs)
    ns:SetFont(f.hpText, fs)
    ns:SetFont(f.powerText, math.max(6, fs - 2))

    f.hpText:ClearAllPoints()
    f.name:ClearAllPoints()
    if cfg.textStack and cfg.showName and cfg.showHealthText then
        -- two centered lines: name over health info
        local off = math.ceil(fs * 0.6)
        f.name:SetJustifyH("CENTER")
        f.hpText:SetJustifyH("CENTER")
        f.name:SetPoint("CENTER", f.health, "CENTER", 0, off)
        f.hpText:SetPoint("CENTER", f.health, "CENTER", 0, -off)
        f.name:SetWidth(w - 4)
        f.hpText:SetWidth(w - 4)
    else
        f.name:SetJustifyH("LEFT")
        f.hpText:SetJustifyH("RIGHT")
        f.hpText:SetWidth(0)
        if cfg.showName then
            f.hpText:SetPoint("RIGHT", f.health, "RIGHT", -4, 0)
        else
            f.hpText:SetPoint("CENTER", f.health, "CENTER", 0, 0)   -- no name: the health info is centered
        end
        f.name:SetPoint("LEFT", f.health, "LEFT", 4, 0)
        f.name:SetWidth(cfg.showHealthText and (w * 0.55) or (w - 10))
    end
    f.name:SetShown(cfg.showName)
    f.powerText:ClearAllPoints()
    if pH >= 10 then
        f.powerText:SetPoint("RIGHT", f.power, "RIGHT", -4, 0)
    else
        f.powerText:SetPoint("BOTTOMRIGHT", f.health, "BOTTOMRIGHT", -4, 2)
    end

    configureCast(f, cfg)
    configureAuras(f, cfg)
end

----------------------------------------------------------------------
-- Hiding Blizzard frames
----------------------------------------------------------------------
local function unregisterBars(frame, depth)
    if depth > 4 then return end
    for _, child in ipairs({ frame:GetChildren() }) do
        if child.GetObjectType and child:GetObjectType() == "StatusBar" and child.UnregisterAllEvents then
            child:UnregisterAllEvents()
        end
        if child.GetChildren then unregisterBars(child, depth + 1) end
    end
end

local function killFrame(frame)
    if not frame or frame.molKilled then return end
    frame.molKilled = true
    if frame.UnregisterAllEvents then frame:UnregisterAllEvents() end
    pcall(unregisterBars, frame, 0)
    frame:Hide()
    frame:SetParent(hider)
end

local BLIZZARD = {
    player = { "PlayerFrame" },
    target = { "TargetFrame" },
    targettarget = {},      -- child of TargetFrame
    focus = { "FocusFrame" },
    pet = { "PetFrame" },
    party = { "PartyFrame" },
    boss = { "BossTargetFrameContainer", "Boss1TargetFrame", "Boss2TargetFrame", "Boss3TargetFrame",
             "Boss4TargetFrame", "Boss5TargetFrame" },
}

local function killBlizzardFor(key)
    local cfg = ns.db.unitframes.frames[key]
    if not cfg or not cfg.enabled then return end
    for _, n in ipairs(BLIZZARD[key] or {}) do killFrame(_G[n]) end
    if key == "player" and cfg.showCastbar then killFrame(_G.PlayerCastingBarFrame) end
end

----------------------------------------------------------------------
-- Layout of groups (party / boss)
----------------------------------------------------------------------
local function layoutGroup(c)
    local cfg = ns.db.unitframes.frames[c.def.key]
    local n = #c.frames
    local extra = (cfg.showCastbar and cfg.castAnchor ~= "inside" and (cfg.castHeight + 3)) or 0
    local stepY = cfg.height + cfg.spacing + extra
    local stepX = cfg.width + cfg.spacing
    c:SetScale(cfg.scale * ns.db.general.scale)
    if cfg.horizontal then
        c:SetSize(n * stepX - cfg.spacing, cfg.height + extra)
    else
        c:SetSize(cfg.width, n * stepY - (stepY - cfg.height))
    end
    for i, f in ipairs(c.frames) do
        configureFrame(f, 1)
        f:ClearAllPoints()
        if cfg.horizontal then
            f:SetPoint("TOPLEFT", c, "TOPLEFT", (i - 1) * stepX, 0)
        elseif cfg.growUp then
            f:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 0, (i - 1) * stepY)
        else
            f:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -(i - 1) * stepY)
        end
    end
end

local function setWatch(f, enabled)
    if enabled then
        if not f.watching then RegisterUnitWatch(f); f.watching = true end
    else
        if f.watching then UnregisterUnitWatch(f); f.watching = false end
        f:Hide()
    end
end

----------------------------------------------------------------------
-- Test mode: party / boss frames normally need a group / an encounter. While testing, every frame of the
-- group shows the player instead, so size, spacing, position and the text can be checked alone.
----------------------------------------------------------------------
local testing = {}

function UF:IsTesting(key) return testing[key] and true or false end

function UF:Test(key, on)
    local c = byKey[key]
    if not (started and c and c.def) then
        ns:Print("Test works for the party and boss frames (/mui test party).")
        return
    end
    if on == nil then on = not testing[key] end
    testing[key] = on or nil
    ns:AfterCombat("uf_test_" .. key, function()
        local cfg = ns.db.unitframes.frames[key]
        for i, f in ipairs(c.frames) do
            local unit = on and "player" or c.def.units[i]
            f.unit = unit
            f:SetAttribute("unit", unit)
            bindUnitEvents(f, unit)
        end
        layoutGroup(c)
        for _, f in ipairs(c.frames) do
            if not cfg.enabled then setWatch(f, cfg.enabled or on) end
            if f:IsShown() then updateAll(f) end
        end
        ns:Print(string.format("%s frames test %s.", key, on and "on (every frame shows you)" or "off"))
    end)
end

----------------------------------------------------------------------
-- Module API
----------------------------------------------------------------------
local ticker = CreateFrame("Frame")
local acc = 0
ticker:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc < 0.2 then return end
    acc = 0
    if not started then return end
    local tot = byKey.targettarget
    if tot and tot:IsShown() then updateAll(tot) end
    local party = byKey.party
    if party then
        for _, f in ipairs(party.frames) do
            if f:IsShown() then
                local ok, inRange, checked = pcall(UnitInRange, f.unit)
                if ok and not IsSecret(inRange) and not IsSecret(checked) then
                    f:SetAlpha((checked and not inRange) and 0.5 or 1)
                end
            end
        end
    end
end)

local function onGlobalEvent(event)
    if not started then return end
    if event == "PLAYER_TARGET_CHANGED" then
        for _, f in ipairs(frames) do
            if f.unit == "target" or f.unit == "targettarget" then updateAll(f) else updateSelection(f) end
        end
    elseif event == "PLAYER_FOCUS_CHANGED" then
        if byKey.focus then updateAll(byKey.focus) end
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_UPDATE_RESTING" then
        if byKey.player then updateStatus(byKey.player) end
    elseif event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" or event == "UNIT_TARGETABLE_CHANGED" then
        if byKey.boss then for _, f in ipairs(byKey.boss.frames) do updateAll(f) end end
    else
        for _, f in ipairs(frames) do updateAll(f) end
    end
end

----------------------------------------------------------------------
-- Focus cast bar: a stand-alone cast bar for the focus, stacked on the
-- player's cast bar. Works without a focus frame.
----------------------------------------------------------------------
local focusCast

local function buildFocusCast()
    if focusCast then return focusCast end
    local fc = CreateFrame("Frame", "ModernUI_FocusCast", UIParent)
    fc:SetSize(1, 1)
    fc.unit = "focus"
    fc.cfg = { showCastbar = false }
    fc.cast = makeCastBar(fc)
    for event in pairs(UNIT_EVENT_HANDLERS) do
        if event:find("^UNIT_SPELLCAST") then pcall(fc.RegisterUnitEvent, fc, event, "focus") end
    end
    fc:RegisterEvent("PLAYER_FOCUS_CHANGED")
    fc:SetScript("OnEvent", function(self) updateCast(self) end)
    focusCast = fc
    return fc
end

local function configureFocusCast()
    local c = ns.db.unitframes.focusCast
    local fc = buildFocusCast()
    fc.cfg.showCastbar = c.enabled and true or false
    local cast, h = fc.cast, c.height
    cast:ClearAllPoints()
    cast.icon:ClearAllPoints()
    cast.text:ClearAllPoints()
    cast.time:ClearAllPoints()
    local p = byKey.player
    local anchor = p and p.cast or UIParent
    fc:SetScale(((p and p.cfg and p.cfg.scale) or 1) * ns.db.general.scale)
    cast:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 4)
    cast:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 4)
    cast:SetHeight(h)
    cast:SetStatusBarTexture(ns:GetTexture())
    cast.icon:SetPoint("LEFT", cast, "LEFT", 1, 0)
    cast.icon:SetSize(h - 2, h - 2)
    cast.text:SetPoint("LEFT", cast, "LEFT", h + 4, 0)
    local fs = math.max(8, math.min(ns.db.general.fontSize, h - 3))
    ns:SetFont(cast.text, fs)
    ns:SetFont(cast.time, fs)
    anchorCastTexts(cast, fs)
    updateCast(fc)
end

function UF:GetFrame(key) return byKey[key] end

-- /mui auras: what the engine aura rows of the target frame look like
function UF:AuraDebug()
    local f = byKey.target
    ns:Print(string.format("engine auras supported=%s createError=%s", tostring(ns.Auras and ns.Auras.Supported()),
        tostring(ns.Auras and ns.Auras.errored)))
    if not f then ns:Print("no target frame") return end
    ns:Print(string.format("target frame: engineAuras=%s shown=%s unit=%s", tostring(f.engineAuras), tostring(f:IsShown()), tostring(f.unit)))
    local restricted = "n/a"
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        local ok, r = pcall(C_Secrets.ShouldAurasBeSecret)
        restricted = ok and ((issecretvalue and issecretvalue(r)) and "secret" or tostring(r)) or "error"
    end
    ns:Print("ShouldAurasBeSecret=" .. restricted .. " inCombat=" .. tostring(InCombatLockdown()))
    local function num(v) return (v ~= nil and not (issecretvalue and issecretvalue(v))) and string.format("%.0f", v) or "?" end
    for _, field in ipairs({ "auraTop", "auraBottom" }) do
        local c = f[field]
        if c then
            local ok, p1, rel, p2, x, y = pcall(c.GetPoint, c, 1)
            ns:Print(string.format("%s: shown=%s size=%sx%s alpha=%s level=%s keys=%s point=%s->%s/%s %s,%s", field,
                tostring(c:IsShown()), num(c:GetWidth()), num(c:GetHeight()), num(c:GetAlpha()), num(c:GetFrameLevel()),
                table.concat(c.molKeys or {}, ","), tostring(p1), tostring(rel and rel.GetName and rel:GetName()),
                tostring(p2), num(x), num(y)))
            local n = 0
            for _, k in ipairs({ c:GetChildren() }) do
                n = n + 1
                if n <= 3 then
                    local okp, kp, _, kr, kx, ky = pcall(k.GetPoint, k, 1)
                    ns:Print(string.format("  button %d: size=%sx%s alpha=%s point=%s %s,%s", n, num(k:GetWidth()), num(k:GetHeight()),
                        num(k:GetAlpha()), tostring(okp and kp), num(kx), num(ky)))
                end
            end
            ns:Print("  children=" .. n)
        else
            ns:Print(field .. ": none")
        end
    end
end

function UF:Init()
    if not ns.db.unitframes.enabled then return end
    self:Start()
end

function UF:Start()
    if started then return end
    started = true
    for _, def in ipairs(SINGLES) do
        local f = createUnitFrame(def.unit, def.key, def.key)
        byKey[def.key] = f
        ns.Mover:Register("uf_" .. def.key, f, def.label)
    end
    for _, def in ipairs(GROUPS) do
        local c = CreateFrame("Frame", "ModernUI_" .. def.key .. "Group", UIParent)
        c.def, c.frames = def, {}
        for i, unit in ipairs(def.units) do
            local f = createUnitFrame(unit, def.key .. i, def.key)
            f.isGroup = true
            f:SetParent(c)
            c.frames[i] = f
        end
        byKey[def.key] = c
        ns.Mover:Register("uf_" .. def.key, c, def.label)
    end
    ns:On("UNIT_POWER_UPDATE", function(_, unit)
        if unit == "player" and byKey.target then updateCombo(byKey.target) end
    end)
    ns:On("UNIT_COMBO_POINTS", function() if byKey.target then updateCombo(byKey.target) end end)
    for _, e in ipairs({ "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "GROUP_ROSTER_UPDATE",
                         "RAID_TARGET_UPDATE", "PARTY_LEADER_CHANGED", "PLAYER_ROLES_ASSIGNED",
                         "INSTANCE_ENCOUNTER_ENGAGE_UNIT", "UNIT_TARGETABLE_CHANGED",
                         "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
                         "PLAYER_UPDATE_RESTING" }) do
        ns:On(e, onGlobalEvent)
    end
end

-- Blizzard's own buff / debuff window: hidden unless the option asks for it.
local AURA_FRAMES = { "BuffFrame", "DebuffFrame", "TemporaryEnchantFrame" }
local auraParents = {}

local function applyBlizzardAuras()
    local show = ns.db.unitframes.showBlizzardAuras
    ns:AfterCombat("uf_blizzauras", function()
        for _, name in ipairs(AURA_FRAMES) do
            local f = _G[name]
            if f and f.SetParent then
                if show then
                    if auraParents[name] then
                        pcall(f.SetParent, f, auraParents[name])
                        auraParents[name] = nil
                    end
                elseif not auraParents[name] then
                    auraParents[name] = f:GetParent() or UIParent
                    pcall(f.SetParent, f, hider)
                end
            end
        end
    end)
end

function UF:Apply()
    if not ns.db then return end
    applyBlizzardAuras()
    if not ns.db.unitframes.enabled then
        if started then
            ns:AfterCombat("uf_off", function()
                for _, f in ipairs(frames) do setWatch(f, false) end
            end)
            ns:Print("Unit frames disabled: /reload to restore the Blizzard frames.")
        end
        return
    end
    if not started then self:Start() end
    ns:AfterCombat("uf_apply", function()
        local frameCfg = ns.db.unitframes.frames
        for _, def in ipairs(SINGLES) do
            local f = byKey[def.key]
            local cfg = frameCfg[def.key]
            configureFrame(f, cfg.scale * ns.db.general.scale)
            killBlizzardFor(def.key)
            setWatch(f, cfg.enabled)
            ns.Mover:Position("uf_" .. def.key)
            if cfg.enabled then updateAll(f) end
        end
        configureFocusCast()
        for _, def in ipairs(GROUPS) do
            local c = byKey[def.key]
            local cfg = frameCfg[def.key]
            layoutGroup(c)
            killBlizzardFor(def.key)
            for _, f in ipairs(c.frames) do
                setWatch(f, cfg.enabled)
                if cfg.enabled then updateAll(f) end
            end
            ns.Mover:Position("uf_" .. def.key)
        end
    end)
end
