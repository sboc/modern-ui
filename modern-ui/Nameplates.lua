local ADDON, ns = ...
local UI = ns.UI

-- Enemy nameplates.
-- Blizzard's nameplate frame is hidden (alpha only, kept alive) and a flat
-- Modern UI frame is drawn on the nameplate instead: health bar, name, health %,
-- raid marker, a cast bar, your own debuffs, a white outline on your target
-- and a red outline when the unit has you on its threat list. Friendly
-- nameplates get the same frame (class colored for players, green for NPCs)
-- unless "skinFriendly" is off. Everything that can be a "secret" value is only
-- handed to StatusBars / FontStrings inside pcall, never compared or measured.
local NP = ns:NewModule("nameplates")
ns.Nameplates = NP

local started = false
local active = {}                       -- unit token -> our frame
local owned = setmetatable({}, { __mode = "k" })   -- Blizzard UnitFrames we currently hide
local hookedAlpha = setmetatable({}, { __mode = "k" })
local hookedSel = setmetatable({}, { __mode = "k" })
local parked = setmetatable({}, { __mode = "k" })
local offscreen = CreateFrame("Frame")
offscreen:Hide()

local function cfg() return ns.db.nameplates end
local function secret(v) return issecretvalue and issecretvalue(v) end

local MAX_ICONS = 6
local FRIENDLY_BAR_WIDTH = 0.6    -- friendly bar width as a fraction of the plate width
local FRIENDLY_ALPHA = 0.7         -- friendly bar opacity
local FRIENDLY_BAR_HEIGHT = 1   -- friendly bar: thin line under the name

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function isEnemy(unit)
    local ok, res = pcall(UnitCanAttack, "player", unit)
    if not ok or secret(res) then return false end
    return res and true or false
end

local PET_COLOR = { 0.85, 0.75, 0.5 }   -- name color of friendly pets / minions (tan, not close to any class color)
local PET_SCALE = 0.7                    -- pet plates: font and bar width as a fraction of a normal friendly plate

local function isPet(unit)
    local res = false
    pcall(function() res = not UnitIsPlayer(unit) and UnitPlayerControlled and UnitPlayerControlled(unit) and true or false end)
    return res
end

local function unitColor(unit, friendly)
    local r, g, b
    pcall(function()
        if UnitIsPlayer(unit) then
            local _, class = UnitClass(unit)
            local col = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
            if not col and class and C_ClassColor and C_ClassColor.GetClassColor then
                col = C_ClassColor.GetClassColor(class)
            end
            if col then r, g, b = col.r, col.g, col.b end
        elseif friendly and UnitPlayerControlled and UnitPlayerControlled(unit) then
            r, g, b = PET_COLOR[1], PET_COLOR[2], PET_COLOR[3]
        elseif UnitIsTapDenied and UnitIsTapDenied(unit) then
            r, g, b = 0.5, 0.5, 0.5
        else
            local reaction = UnitReaction(unit, "player")
            local col = reaction and FACTION_BAR_COLORS and FACTION_BAR_COLORS[reaction]
            if col then r, g, b = col.r, col.g, col.b end
        end
    end)
    return r or 0.8, g or 0.2, b or 0.2
end

local function setBar(bar, value)
    pcall(bar.SetValue, bar, value)
end

----------------------------------------------------------------------
-- Frame
----------------------------------------------------------------------
local function createIcon(parent)
    local icon = CreateFrame("Frame", nil, parent)
    icon.tex = icon:CreateTexture(nil, "ARTWORK")
    icon.tex:SetPoint("TOPLEFT", 1, -1)
    icon.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    icon.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon.cd = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
    icon.cd:SetAllPoints(icon.tex)
    icon.cd:SetHideCountdownNumbers(true)
    icon.cd:SetDrawEdge(false)
    icon.count = icon:CreateFontString(nil, "OVERLAY")
    icon.count:SetPoint("BOTTOMRIGHT", 1, 0)
    icon.borders = UI.AddBorder(icon, 1, 0, 0, 0, 1, "OVERLAY")
    icon:EnableMouse(false)
    icon:Hide()
    return icon
end

local function createFrame(plate)
    local f = CreateFrame("Frame", nil, plate)
    f:EnableMouse(false)
    f:SetFrameStrata("BACKGROUND")
    f:SetFrameLevel(10)

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0.03, 0.03, 0.04, 0.9)
    f.health = CreateFrame("StatusBar", nil, f)
    f.health:SetPoint("TOPLEFT", 1, -1)
    f.health:SetPoint("BOTTOMRIGHT", -1, 1)
    f.health:SetMinMaxValues(0, 1)
    f.health:SetValue(1)
    f.border = CreateFrame("Frame", nil, f)
    f.border:SetAllPoints()
    f.border:SetFrameLevel(f.health:GetFrameLevel() + 3)
    f.borders = UI.AddBorder(f.border, 1, 0, 0, 0, 1, "OVERLAY")

    f.name = f.border:CreateFontString(nil, "OVERLAY")
    f.name:SetJustifyH("CENTER")
    f.name:SetWordWrap(false)
    f.hpText = f.border:CreateFontString(nil, "OVERLAY")
    f.hpText:SetJustifyH("RIGHT")
    f.raid = f.border:CreateTexture(nil, "OVERLAY")
    f.raid:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    f.raid:Hide()

    -- cast bar
    local cast = CreateFrame("StatusBar", nil, f)
    cast:Hide()
    cast:SetMinMaxValues(0, 1)
    cast:SetValue(0)
    cast.bg = cast:CreateTexture(nil, "BACKGROUND")
    cast.bg:SetAllPoints()
    cast.bg:SetColorTexture(0.03, 0.03, 0.04, 0.9)
    cast.borders = UI.AddBorder(cast, 1, 0, 0, 0, 1, "BORDER")
    cast.icon = cast:CreateTexture(nil, "OVERLAY")
    cast.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    cast.text = cast:CreateFontString(nil, "OVERLAY")
    cast.text:SetJustifyH("LEFT")
    cast.text:SetWordWrap(false)
    f.cast = cast

    -- own debuffs
    f.icons, f.buffIcons = {}, {}
    for i = 1, MAX_ICONS do
        f.icons[i] = createIcon(f)
        f.buffIcons[i] = createIcon(f)
    end

    f:Hide()
    return f
end

local function layout(f)
    local c = cfg()
    local w, h = c.width, c.height
    local friendly = f.friendly
    local pet = friendly and f.pet
    if friendly then f:SetSize(math.floor(w * FRIENDLY_BAR_WIDTH * (pet and PET_SCALE or 1)), FRIENDLY_BAR_HEIGHT) else f:SetSize(w, h) end
    f.health:ClearAllPoints()
    if friendly then
        f.health:SetAllPoints(f)
    else
        f.health:SetPoint("TOPLEFT", 1, -1)
        f.health:SetPoint("BOTTOMRIGHT", -1, 1)
    end
    f:ClearAllPoints()
    f:SetPoint("CENTER", f.plate, "CENTER", 0, c.offsetY)

    local tex = ns:GetTexture()
    f.health:SetStatusBarTexture(tex)
    f.cast:SetStatusBarTexture(tex)

    local base = math.max(9, ns.db.general.fontSize - 1)
    local fs = friendly and base or base + 1    -- enemy plates: one size up
    f.bg:SetShown(not friendly)
    f.health:SetShown(true)
    f.health:SetAlpha(friendly and FRIENDLY_ALPHA or 1)
    ns:SetFont(f.name, pet and math.max(8, math.floor(fs * PET_SCALE + 0.5)) or friendly and math.max(10, fs) or fs, "OUTLINE")
    ns:SetFont(f.hpText, math.max(8, math.min(fs, h - 1)), "OUTLINE")
    ns:SetFont(f.cast.text, math.max(7, fs - 1), "OUTLINE")
    f.name:ClearAllPoints()
    if friendly then
        f.name:SetPoint("BOTTOM", f, "TOP", 0, 2)   -- name above the thin bar
        f.name:SetWidth(w - 4)
    else
        f.name:SetPoint("BOTTOM", f, "TOP", 0, 3)
        f.name:SetWidth(w + 20)
    end
    f.hpText:ClearAllPoints()
    f.hpText:SetPoint("RIGHT", f.health, "RIGHT", -3, 0)
    f.hpText:SetShown(c.showHealthText and not friendly)
    f.raid:ClearAllPoints()
    f.raid:SetSize(h + 6, h + 6)
    f.raid:SetPoint("RIGHT", f, "LEFT", -3, 0)

    local ch = c.castHeight
    f.cast:ClearAllPoints()
    f.cast:SetPoint("TOPLEFT", f, "BOTTOMLEFT", ch + 2, -3)
    f.cast:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, -3)
    f.cast:SetHeight(ch)
    f.cast.icon:ClearAllPoints()
    f.cast.icon:SetPoint("TOPRIGHT", f.cast, "TOPLEFT", -2, 0)
    f.cast.icon:SetSize(ch, ch)
    f.cast.text:ClearAllPoints()
    f.cast.text:SetPoint("LEFT", f.cast, "LEFT", 3, 0)
    f.cast.text:SetPoint("RIGHT", f.cast, "RIGHT", -3, 0)

    local size = c.debuffSize
    local rowY = fs + 8

    -- engine aura rows: debuffs on the row above the name, buffs stacked above them
    if friendly then
        f.engineAuras = false
        if f.auraBox then ns.Auras.Clear(f, "auraBox") end
    elseif ns.Auras and ns.Auras.Supported() then
        f.engineAuras = true
        for i = 1, MAX_ICONS do f.icons[i]:Hide(); f.buffIcons[i]:Hide() end
        local gap = 2
        local groups = {}
        if c.showDebuffs then
            groups[#groups + 1] = { key = "debuffs", filter = c.onlyMyDebuffs and "HARMFUL|PLAYER" or "HARMFUL",
                max = MAX_ICONS, size = size, gap = gap, border = { 0.75, 0.12, 0.12 },
                timer = c.debuffTimer }
        end
        if c.showBuffs then
            groups[#groups + 1] = { key = "buffs", filter = "HELPFUL", max = MAX_ICONS, size = size, gap = gap,
                border = { 0, 0, 0 }, newLine = c.showDebuffs and true or nil }
        end
        ns.Auras.Set(f, "auraBox", f, f.unit, {
            point = { "BOTTOMLEFT", f, "TOPLEFT", 0, rowY }, anchor = "BOTTOMLEFT", growH = "Right", growV = "Up",
            rowWidth = MAX_ICONS * (size + gap), groups = groups })
    else
        f.engineAuras = false
        if f.auraBox then ns.Auras.Clear(f, "auraBox") end
    end
    for i = 1, MAX_ICONS do
        local d, b = f.icons[i], f.buffIcons[i]
        d:SetSize(size, size)
        d:ClearAllPoints()
        d:SetPoint("BOTTOMLEFT", f, "TOPLEFT", (i - 1) * (size + 2), rowY)
        ns:SetFont(d.count, math.max(8, math.floor(size * 0.5)), "OUTLINE")
        d.cd:SetHideCountdownNumbers(not c.debuffTimer)
        if c.debuffTimer and d.cd.SetCountdownFont and ns.Auras then pcall(d.cd.SetCountdownFont, d.cd, ns.Auras.TimerFont(size)) end
        b:SetSize(size, size)
        b:ClearAllPoints()
        -- buffs: a row above the debuffs
        b:SetPoint("BOTTOMLEFT", f, "TOPLEFT", (i - 1) * (size + 2), rowY + size + 3)
        ns:SetFont(b.count, math.max(8, math.floor(size * 0.5)), "OUTLINE")
    end
end

----------------------------------------------------------------------
-- Updates
----------------------------------------------------------------------
local function healthPercent(unit)
    local ok, s = pcall(function()
        if UnitHealthPercent then
            local scale = CurveConstants and CurveConstants.ScaleTo100
            return string.format("%.0f%%", UnitHealthPercent(unit, true, scale))
        end
        return string.format("%.0f%%", UnitHealth(unit) / UnitHealthMax(unit) * 100)
    end)
    return ok and s or ""
end

local function updateHealth(f)
    local unit = f.unit
    if not unit then return end
    pcall(function()
        f.health:SetMinMaxValues(0, UnitHealthMax(unit))
        setBar(f.health, UnitHealth(unit))
    end)
    if f.friendly then f.health:SetStatusBarColor(1, 1, 1) else f.health:SetStatusBarColor(unitColor(unit)) end
    if cfg().showHealthText and not f.friendly then f.hpText:SetText(healthPercent(unit)) end
end

local function updateName(f)
    local unit = f.unit
    if not unit then return end
    pcall(function() f.name:SetText(UnitName(unit)) end)
    if f.friendly then f.name:SetTextColor(unitColor(unit, true)) else f.name:SetTextColor(1, 1, 1) end
end

local function updateOutline(f)
    local unit = f.unit
    if not unit then return end
    local r, g, b = 0, 0, 0
    local isTarget = false
    pcall(function() isTarget = UnitIsUnit(unit, "target") end)
    if secret(isTarget) then isTarget = false end
    if isTarget and cfg().highlightTarget then
        r, g, b = 1, 1, 1
    elseif cfg().threatOutline then
        local status
        pcall(function() status = UnitThreatSituation("player", unit) end)
        if type(status) == "number" and not secret(status) and status >= 2 then r, g, b = 1, 0.15, 0.1 end
    end
    local c = cfg()
    if f.friendly then
        f.borders:SetColor(0, 0, 0, 0)
        f:SetScale(isTarget and c.targetScale or 1)
        f:SetAlpha(1)
        return
    end
    f:SetScale(isTarget and c.targetScale or 1)
    f.borders:SetColor(r, g, b, 1)
    -- target outline: as thin as the screen allows (one physical pixel), other borders stay 1
    local px = 1
    if isTarget and c.highlightTarget then px = math.min(1, ns.PixelSize(f)) end
    f.borders:SetSize(px)
    f:SetAlpha((isTarget or not c.dimOthers) and 1 or c.dimAlpha)
end

local function updateRaid(f)
    local unit = f.unit
    local idx
    pcall(function() idx = GetRaidTargetIndex(unit) end)
    if idx and not secret(idx) then
        pcall(SetRaidTargetIconTexture, f.raid, idx)
        f.raid:Show()
    else
        f.raid:Hide()
    end
end

local function castOnUpdate(bar)
    local now = GetTime()
    pcall(function()
        if bar.channel then bar:SetValue(bar.endTime - now + bar.startTime) else bar:SetValue(now) end
        if now >= bar.endTime then bar:Hide() end
    end)
end

local function doUpdateCast(f)
    local unit, bar = f.unit, f.cast
    local channel = false
    local name, text, tex, startMS, endMS, notInt
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
        bar:SetScript("OnUpdate", nil)
    else
        bar.startTime, bar.endTime = startMS / 1000, endMS / 1000
        bar:SetMinMaxValues(bar.startTime, bar.endTime)
        bar:SetScript("OnUpdate", castOnUpdate)
    end
    -- grey for uninterruptible casts
    local t = bar:GetStatusBarTexture()
    if t and t.SetVertexColorFromBoolean then
        pcall(t.SetVertexColorFromBoolean, t, notInt, CreateColor(0.6, 0.6, 0.6, 1), CreateColor(1, 0.7, 0, 1))
    else
        pcall(function() if notInt then bar:SetStatusBarColor(0.6, 0.6, 0.6) end end)
    end
    bar:Show()
end

local function updateCast(f)
    if not f.unit or f.friendly or not cfg().showCast then
        f.cast:SetScript("OnUpdate", nil)
        f.cast:Hide()
        return
    end
    if not pcall(doUpdateCast, f) then
        f.cast:SetScript("OnUpdate", nil)
        f.cast:Hide()
    end
end

local function fillIcons(f, icons, filter, enabled, border)
    local unit = f.unit
    local shown = 0
    if unit and enabled then
        local idx = 1
        local isBuff = filter:find("HELPFUL", 1, true) ~= nil
        while shown < MAX_ICONS and idx <= 40 do
            local aura = ns.GetAuraAt(unit, idx, filter, isBuff)
            if not aura then break end
            idx = idx + 1
            local icon = icons[shown + 1]
            local filled = pcall(function()
                icon.tex:SetTexture(aura.icon)
                icon.count:SetText((aura.applications and aura.applications > 1) and aura.applications or "")
                if aura.duration and aura.expirationTime then
                    icon.cd:SetCooldown(aura.expirationTime - aura.duration, aura.duration)
                else
                    icon.cd:Clear()
                end
            end)
            if filled then
                icon.borders:SetColor(border[1], border[2], border[3], 1)
                icon:Show()
                shown = shown + 1
            end
        end
    end
    for i = shown + 1, MAX_ICONS do icons[i]:Hide() end
end

local function updateAuras(f)
    if f.engineAuras then return end
    if f.friendly then
        for i = 1, MAX_ICONS do f.icons[i]:Hide(); f.buffIcons[i]:Hide() end
        return
    end
    local c = cfg()
    fillIcons(f, f.icons, c.onlyMyDebuffs and "HARMFUL|PLAYER" or "HARMFUL", c.showDebuffs, { 0.75, 0.12, 0.12 })
    fillIcons(f, f.buffIcons, "HELPFUL", c.showBuffs, { 0, 0, 0 })
end

local function updateAll(f)
    if not f.unit then return end
    updateName(f)
    updateHealth(f)
    updateOutline(f)
    updateRaid(f)
    updateCast(f)
    updateAuras(f)
end

----------------------------------------------------------------------
-- Taking over / releasing Blizzard's nameplate frame
----------------------------------------------------------------------
local function hideBlizzard(plate)
    local uf = plate.UnitFrame
    if not uf then return end
    owned[uf] = true
    pcall(function()
        uf:SetAlpha(0)
        -- its aura buttons are mouse-enabled templates: park them so they cannot trap clicks / tooltips
        local auras = uf.AurasFrame
        if auras and not auras:IsForbidden() then
            -- Blizzard's aura row can ignore its parent's alpha: make sure it follows it, and fade it too
            if auras.SetIgnoreParentAlpha then pcall(auras.SetIgnoreParentAlpha, auras, false) end
            pcall(auras.SetAlpha, auras, 0)
            if auras:GetParent() ~= offscreen then
                parked[auras] = uf
                auras:SetParent(offscreen)
            end
        end
        -- Blizzard's own target outline ignores the UnitFrame's alpha: keep it hidden on enemy plates
        local sel = uf.selectionHighlight
        if type(sel) == "table" and sel.SetAlpha then
            sel:SetAlpha(0)
            if sel.Hide then sel:Hide() end
            if not hookedSel[sel] then
                hookedSel[sel] = true
                local function again(self) if owned[uf] then self:SetAlpha(0); self:Hide() end end
                pcall(hooksecurefunc, sel, "Show", again)
                pcall(hooksecurefunc, sel, "SetShown", function(self, shown) if shown then again(self) end end)
            end
        end
        if not hookedAlpha[uf] then
            hookedAlpha[uf] = true
            local locked = false
            hooksecurefunc(uf, "SetAlpha", function(self, a)
                if locked or not owned[self] or a == 0 then return end
                locked = true
                self:SetAlpha(0)
                locked = false
            end)
        end
    end)
end

local function reclaimBlizzard(plate)
    local uf = plate and plate.UnitFrame
    if not uf or not owned[uf] then return end
    owned[uf] = nil
    pcall(function()
        local auras = uf.AurasFrame
        if auras and parked[auras] == uf then
            parked[auras] = nil
            pcall(auras.SetAlpha, auras, 1)
            if auras:GetParent() == offscreen then auras:SetParent(uf) end
        end
        uf:SetAlpha(1)
    end)
end

-- RegisterUnitEvent filters on at most two unit tokens, so one shared frame registered for
-- nameplate1..40 only ever saw the first plates. Each plate frame listens for its own unit instead.
local HANDLERS, onEvent   -- defined in the Events section below

local function bindEvents(f, unit)
    f:UnregisterAllEvents()
    f:SetScript("OnEvent", onEvent)
    for event in pairs(HANDLERS) do
        pcall(f.RegisterUnitEvent, f, event, unit)
    end
end

local function unbindEvents(f)
    f:UnregisterAllEvents()
    f:SetScript("OnEvent", nil)
end

local function onAdded(unit)
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit(unit)
    if not plate or (plate.IsForbidden and plate:IsForbidden()) then return end
    local enemy = isEnemy(unit)
    if not enemy and not cfg().skinFriendly then
        reclaimBlizzard(plate)
        if plate.molFrame then plate.molFrame:Hide(); plate.molFrame.unit = nil; unbindEvents(plate.molFrame) end
        return
    end
    local f = plate.molFrame
    if not f then
        f = createFrame(plate)
        f.plate = plate
        plate.molFrame = f
    end
    f.unit = unit
    f.friendly = not enemy
    f.pet = not enemy and isPet(unit)
    active[unit] = f
    bindEvents(f, unit)
    hideBlizzard(plate)
    layout(f)
    f:Show()
    updateAll(f)
end

local function onRemoved(unit)
    local f = active[unit]
    active[unit] = nil
    if f then
        f.unit = nil
        unbindEvents(f)
        if f.auraBox then pcall(f.auraBox.SetUnit, f.auraBox, nil) end
        f.cast:SetScript("OnUpdate", nil)
        f.cast:Hide()
        f:Hide()
    end
end

-- A unit can turn hostile after its plate was added (neutral mob pulled, flagging for PvP):
-- re-run the take-over when its attackable state no longer matches how the plate was built.
local function recheck(unit)
    if not unit or not (C_NamePlate and C_NamePlate.GetNamePlateForUnit(unit)) then return end
    local ok, res = pcall(UnitCanAttack, "player", unit)
    if not ok or secret(res) then return end
    local enemy = res and true or false
    local f = active[unit]
    if f then
        if f.friendly == enemy then onAdded(unit) end
    elseif enemy or cfg().skinFriendly then
        onAdded(unit)
    end
end

local function recheckAll()
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if unit then
            recheck(unit)
            local f = active[unit]
            if f then pcall(updateAll, f) end
        end
    end
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
HANDLERS = {
    UNIT_HEALTH = updateHealth, UNIT_MAXHEALTH = updateHealth, UNIT_HEALTH_FREQUENT = updateHealth,
    UNIT_NAME_UPDATE = updateName, UNIT_FACTION = updateAll, UNIT_FLAGS = updateHealth,
    UNIT_THREAT_LIST_UPDATE = updateOutline, UNIT_THREAT_SITUATION_UPDATE = updateOutline,
    UNIT_AURA = updateAuras,
    UNIT_SPELLCAST_START = updateCast, UNIT_SPELLCAST_STOP = updateCast, UNIT_SPELLCAST_FAILED = updateCast,
    UNIT_SPELLCAST_INTERRUPTED = updateCast, UNIT_SPELLCAST_DELAYED = updateCast,
    UNIT_SPELLCAST_CHANNEL_START = updateCast, UNIT_SPELLCAST_CHANNEL_STOP = updateCast,
    UNIT_SPELLCAST_CHANNEL_UPDATE = updateCast, UNIT_SPELLCAST_INTERRUPTIBLE = updateCast,
    UNIT_SPELLCAST_NOT_INTERRUPTIBLE = updateCast, UNIT_SPELLCAST_EMPOWER_START = updateCast,
    UNIT_SPELLCAST_EMPOWER_STOP = updateCast, UNIT_SPELLCAST_EMPOWER_UPDATE = updateCast,
}

function onEvent(_, event, unit)
    if event == "NAME_PLATE_UNIT_ADDED" then onAdded(unit) return end
    if event == "NAME_PLATE_UNIT_REMOVED" then onRemoved(unit) return end
    if event == "PLAYER_TARGET_CHANGED" then
        for _, f in pairs(active) do
            updateOutline(f)
            if f.plate then hideBlizzard(f.plate) end   -- Blizzard re-shows its target outline on a target change
        end
        return
    end
    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        recheckAll()
        return
    end
    if event == "UNIT_FACTION" or event == "UNIT_FLAGS" then pcall(recheck, unit) end
    if event == "RAID_TARGET_UPDATE" then
        for _, f in pairs(active) do updateRaid(f) end
        return
    end
    local f = unit and active[unit]
    local h = HANDLERS[event]
    if f and h then pcall(h, f) end
end

-- /mui plates: what is on the target's nameplate (Blizzard pieces still visible = the "second plate")
function NP:Debug()
    local function n(v) return (v ~= nil and not (issecretvalue and issecretvalue(v))) and string.format("%.2f", v) or "?" end
    local function b(v) return (v ~= nil and not (issecretvalue and issecretvalue(v))) and tostring(v) or "?" end
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit("target")
    if not plate then ns:Print("no nameplate for your target (target something with a visible plate)") return end
    local uf = plate.UnitFrame
    local f = plate.molFrame
    ns:Print(string.format("plate %s alpha=%s | ours: %s shown=%s alpha=%s scale=%s | uf owned=%s",
        tostring(plate.GetName and plate:GetName()), n(plate:GetAlpha()), tostring(f ~= nil),
        b(f and f:IsShown()), n(f and f:GetAlpha()), n(f and f:GetScale()), tostring(uf and owned[uf])))
    if uf then
        ns:Print(string.format("UnitFrame alpha=%s shown=%s", n(uf:GetAlpha()), b(uf:IsShown())))
        local i = 0
        for _, c in ipairs({ uf:GetChildren() }) do
            i = i + 1
            local okn, name = pcall(function() return c:GetName() end)
            ns:Print(string.format("  child %d %s alpha=%s eff=%s shown=%s ignoreParent=%s", i,
                tostring(okn and name or c:GetObjectType()), n(c:GetAlpha()), n(c:GetEffectiveAlpha()), b(c:IsShown()),
                b(c.IsIgnoringParentAlpha and c:IsIgnoringParentAlpha())))
        end
        local r = 0
        for _, reg in ipairs({ uf:GetRegions() }) do
            r = r + 1
            local ok, line = pcall(function()
                return string.format("  region %d %s alpha=%s eff=%s shown=%s", r, reg:GetObjectType(),
                    n(reg:GetAlpha()), n(reg:GetEffectiveAlpha()), b(reg:IsShown()))
            end)
            if ok then ns:Print(line) end
        end
    end
    for i, c in ipairs({ plate:GetChildren() }) do
        local okn, name = pcall(function() return c:GetName() end)
        local tag = (c == uf and " [Blizzard UnitFrame]") or (c == f and " [ours]") or ""
        local okp, p1, rel, p2, x, y = pcall(c.GetPoint, c, 1)
        ns:Print(string.format("  plate child %d %s%s size=%sx%s alpha=%s eff=%s shown=%s lvl=%s kids=%d regions=%d point=%s", i,
            tostring(okn and name or c:GetObjectType()), tag, n(c:GetWidth()), n(c:GetHeight()), n(c:GetAlpha()),
            n(c:GetEffectiveAlpha()), b(c:IsShown()), n(c:GetFrameLevel()), select("#", c:GetChildren()),
            select("#", c:GetRegions()), tostring(okp and p1)))
        if tag == "" then
            for j, k in ipairs({ c:GetChildren() }) do
                ns:Print(string.format("      sub %d %s size=%sx%s alpha=%s eff=%s shown=%s", j,
                    tostring((k.GetName and k:GetName()) or k:GetObjectType()), n(k:GetWidth()), n(k:GetHeight()),
                    n(k:GetAlpha()), n(k:GetEffectiveAlpha()), b(k:IsShown())))
            end
        end
    end
end

NP.OnEvent = onEvent   -- (diagnostics / tests)

function NP:Init()
    if not ns.db.nameplates.enabled then return end
    self:Start()
end

function NP:Start()
    if started then return end
    started = true
    local ev = CreateFrame("Frame")
    ev:SetScript("OnEvent", onEvent)
    ev:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    ev:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    ev:RegisterEvent("PLAYER_TARGET_CHANGED")
    ev:RegisterEvent("RAID_TARGET_UPDATE")
    ev:RegisterEvent("PLAYER_REGEN_DISABLED")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    -- plates that exist already (reload)
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
            local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
            if unit then onAdded(unit) end
        end
    end
end

function NP:Apply()
    if not ns.db then return end
    if not cfg().enabled then
        if started then ns:Print("Nameplate skin disabled: /reload to restore Blizzard's nameplates.") end
        return
    end
    if not started then self:Start() end
    -- re-evaluate every plate (friendly skin toggled) and refresh the ones we own
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
            local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
            if unit then
                if active[unit] then onRemoved(unit) end
                onAdded(unit)
            end
        end
    else
        for _, f in pairs(active) do
            layout(f)
            updateAll(f)
        end
    end
end
