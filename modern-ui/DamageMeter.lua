local ADDON, ns = ...
local UI = ns.UI

-- Damage meter window. Reads Blizzard's built-in meter data (C_DamageMeter)
-- and draws its own compact window. Numbers and names can be "secret" in
-- combat, so they only ever go to StatusBars / SetText / string.format.
-- Click a player for the skills behind their number (same type and session);
-- right-click or the back arrow returns to the list.
local DM = ns:NewModule("damagemeter")
ns.DamageMeter = DM

local TYPES = {
    { key = "DamageDone", label = "Damage Done" },
    { key = "Dps", label = "DPS" },
    { key = "HealingDone", label = "Healing Done" },
    { key = "Hps", label = "HPS" },
    { key = "DamageTaken", label = "Damage Taken" },
    { key = "Interrupts", label = "Interrupts" },
    { key = "Dispels", label = "Dispels" },
    { key = "Deaths", label = "Deaths" },
}
local MAX_ROWS = 15
local HEADER_H = 22

local win
local started = false
local rows = {}
local detail   -- the player whose skills are shown: { guid, name, r, g, b }; nil shows the player list

local function cfg() return ns.db.damagemeter end

local function available()
    return C_DamageMeter and C_DamageMeter.GetCombatSessionFromType
        and Enum and Enum.DamageMeterType and Enum.DamageMeterSessionType
end

local function typeValues()
    local list = {}
    for _, t in ipairs(TYPES) do
        if Enum.DamageMeterType[t.key] ~= nil then list[#list + 1] = { value = t.key, label = t.label } end
    end
    return list
end

function DM:TypeValues()
    if not available() then return { { value = "DamageDone", label = "Damage Done" } } end
    return typeValues()
end

local function typeLabel(key)
    for _, t in ipairs(TYPES) do if t.key == key then return t.label end end
    return key
end

local function classColor(src)
    local ok, r, g, b = pcall(function()
        local c = src.classFilename and RAID_CLASS_COLORS[src.classFilename]
        if c then return c.r, c.g, c.b end
    end)
    if ok and r then return r, g, b end
    return 0.55, 0.55, 0.6
end

local function secret(v) return issecretvalue and issecretvalue(v) end

-- amount as a percentage of total, nil while either is secret
local function share(amount, total)
    local ok, p = pcall(function() if total > 0 then return amount / total * 100 end end)
    return ok and p or nil
end

local function createRow(i)
    local r = CreateFrame("StatusBar", nil, win)
    r:SetMinMaxValues(0, 1)
    r:SetValue(0)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.bg:SetColorTexture(0.1, 0.1, 0.12, 0.5)
    r.rank = r:CreateFontString(nil, "OVERLAY")
    r.rank:SetPoint("LEFT", 4, 0)
    r.name = r:CreateFontString(nil, "OVERLAY")
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.value = r:CreateFontString(nil, "OVERLAY")
    r.value:SetJustifyH("RIGHT")
    r.value:SetPoint("RIGHT", -4, 0)
    r.icon = r:CreateTexture(nil, "OVERLAY")
    r.icon:SetPoint("LEFT", 1, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r:EnableMouse(true)
    r:SetScript("OnMouseUp", function(self, button)
        if detail then
            if button == "RightButton" then DM:ShowList() end
        elseif button == "LeftButton" and self.src then
            DM:ShowSource(self.src)
        end
    end)
    rows[i] = r
    return r
end

local function update()
    if not win or not win:IsShown() then return end
    local c = cfg()
    local meterType = Enum.DamageMeterType[c.type]
    local sessionType = Enum.DamageMeterSessionType[c.session]
    local s
    if meterType ~= nil and sessionType ~= nil then
        local ok, res = pcall(C_DamageMeter.GetCombatSessionFromType, sessionType, meterType)
        if ok then s = res end
    end
    local isRate = (c.type == "Dps" or c.type == "Hps")
    if detail then
        local d
        if meterType ~= nil and sessionType ~= nil and C_DamageMeter.GetCombatSessionSourceFromType then
            local ok, res = pcall(C_DamageMeter.GetCombatSessionSourceFromType, sessionType, meterType, detail.guid)
            if ok then d = res end
        end
        DM.UpdateSpells(c, d, isRate)
        return
    end
    local sources = s and s.combatSources

    for i = 1, MAX_ROWS do
        local row = rows[i]
        local src = (i <= c.rows) and sources and sources[i] or nil
        if row then row.src = src end
        if row and src then
            pcall(function()
                local mx = s.maxAmount
                if mx == nil then mx = sources[1].totalAmount end
                row:SetMinMaxValues(0, mx)
                row:SetValue(src.totalAmount)
                row:SetStatusBarColor(classColor(src))
                row.rank:SetText(c.showRank and (i .. ".") or "")
                row.name:SetText(src.name)
                if isRate then
                    row.value:SetText(ns.ShortNumber(src.amountPerSecond or src.totalAmount))
                else
                    row.value:SetFormattedText("%s  (%s)", ns.ShortNumber(src.totalAmount), ns.ShortNumber(src.amountPerSecond))
                end
            end)
            row:Show()
        elseif row then
            row:Hide()
        end
    end
end

-- the skills of one player: biggest first (sorted here while the numbers are readable, the client's
-- order otherwise), with each skill's share of the player's total when that can be worked out
function DM.UpdateSpells(c, d, isRate)
    local spells = d and d.combatSpells
    local list, total = spells, nil
    if spells and spells[1] and not secret(spells[1].totalAmount) then
        local ok = pcall(function()
            local copy, sum = {}, 0
            for i, sp in ipairs(spells) do copy[i] = sp; sum = sum + sp.totalAmount end
            table.sort(copy, function(a, b) return a.totalAmount > b.totalAmount end)
            list, total = copy, sum
        end)
        if not ok then list, total = spells, nil end
    end
    local getName = (C_Spell and C_Spell.GetSpellName) or GetSpellInfo
    local getIcon = (C_Spell and C_Spell.GetSpellTexture) or GetSpellTexture
    for i = 1, MAX_ROWS do
        local row = rows[i]
        local sp = (i <= c.rows) and list and list[i] or nil
        if row and sp then
            pcall(function()
                local mx = d.maxAmount
                if mx == nil then mx = list[1].totalAmount end
                row:SetMinMaxValues(0, mx)
                row:SetValue(sp.totalAmount)
                row:SetStatusBarColor(detail.r, detail.g, detail.b)
                row.rank:SetText("")
                row.icon:SetTexture(getIcon and getIcon(sp.spellID) or 134400)
                row.name:SetText(getName and getName(sp.spellID) or "")
                pcall(function()   -- pet skills: whose they are
                    if type(sp.creatureName) == "string" then
                        row.name:SetFormattedText("%s (%s)", getName(sp.spellID), sp.creatureName)
                    end
                end)
                local pct = not isRate and total and share(sp.totalAmount, total)
                if isRate then
                    row.value:SetText(ns.ShortNumber(sp.amountPerSecond or sp.totalAmount))
                elseif pct then
                    row.value:SetFormattedText("%s  (%.1f%%)", ns.ShortNumber(sp.totalAmount), pct)
                else
                    row.value:SetFormattedText("%s  (%s)", ns.ShortNumber(sp.totalAmount), ns.ShortNumber(sp.amountPerSecond))
                end
            end)
            row:Show()
        elseif row then
            row:Hide()
        end
    end
end

local function layout()
    local c = cfg()
    win:SetScale(c.scale * ns.db.general.scale)
    win:SetAlpha(c.alpha)
    local rh = c.rowHeight
    win:SetSize(c.width, HEADER_H + c.rows * (rh + 1) + 4)
    win.bg:SetColorTexture(0.03, 0.03, 0.04, c.bgAlpha)
    win.typeBtn:SetLabel(typeLabel(c.type))
    win.sessionBtn:SetLabel(c.session == "Overall" and "Overall" or "Current")
    ns:SetFont(win.typeBtn.text, 13, "")
    ns:SetFont(win.title, 13, "")
    win.typeBtn:SetShown(not detail)
    win.backBtn:SetShown(detail ~= nil)
    win.title:SetShown(detail ~= nil)
    if detail then pcall(win.title.SetText, win.title, detail.name) end
    for i = 1, MAX_ROWS do
        local r = rows[i] or createRow(i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", win, "TOPLEFT", 2, -(HEADER_H + (i - 1) * (rh + 1)))
        r:SetPoint("TOPRIGHT", win, "TOPRIGHT", -2, -(HEADER_H + (i - 1) * (rh + 1)))
        r:SetHeight(rh)
        r:SetStatusBarTexture(ns:GetTexture())
        local fs = math.max(8, math.min(ns.db.general.fontSize, rh - 4))
        ns:SetFont(r.rank, fs, "OUTLINE")
        ns:SetFont(r.name, fs, "OUTLINE")
        ns:SetFont(r.value, fs, "OUTLINE")
        r.icon:SetSize(rh - 2, rh - 2)
        r.icon:SetShown(detail ~= nil)
        r.name:ClearAllPoints()
        r.name:SetPoint("LEFT", r, "LEFT", detail and (rh + 3) or (c.showRank and 22 or 6), 0)
        r.name:SetPoint("RIGHT", r.value, "LEFT", -6, 0)
    end
    update()
end

local function create()
    win = CreateFrame("Frame", "ModernUI_DamageMeter", UIParent)
    win:SetSize(260, 190)
    win.bg = win:CreateTexture(nil, "BACKGROUND")
    win.bg:SetAllPoints()
    win.borderFrame = CreateFrame("Frame", nil, win)
    win.borderFrame:SetAllPoints()
    win.borderFrame:SetFrameLevel(win:GetFrameLevel() + 20)
    win.borderFrame:EnableMouse(false)
    UI.AddBorder(win.borderFrame, 1, 0, 0, 0, 1, "OVERLAY")

    win.typeBtn = UI.Button(win, "", 120, HEADER_H - 4, function(self)
        UI.OpenDropdown(self, typeValues(), cfg().type, function(v) cfg().type = v; layout() end)
    end)
    win.typeBtn:SetPoint("TOPLEFT", 2, -2)
    win.sessionBtn = UI.Button(win, "", 66, HEADER_H - 4, function()
        cfg().session = (cfg().session == "Overall") and "Current" or "Overall"
        layout()
    end)
    win.sessionBtn:SetPoint("LEFT", win.typeBtn, "RIGHT", 3, 0)
    -- skill breakdown header: back arrow and the player's name, in the type button's place
    win.backBtn = UI.Button(win, "<", HEADER_H - 4, HEADER_H - 4, function() DM:ShowList() end)
    win.backBtn:SetPoint("TOPLEFT", 2, -2)
    win.title = win:CreateFontString(nil, "OVERLAY")
    win.title:SetJustifyH("LEFT")
    win.title:SetWordWrap(false)
    win.title:SetPoint("LEFT", win.backBtn, "RIGHT", 4, 0)
    win.title:SetPoint("RIGHT", win.sessionBtn, "LEFT", -3, 0)
    win.resetBtn = UI.Button(win, "R", HEADER_H - 4, HEADER_H - 4, function()
        UI.Confirm("Reset all damage meter data?", function()
            if C_DamageMeter and C_DamageMeter.ResetAllCombatSessions then pcall(C_DamageMeter.ResetAllCombatSessions) end
            update()
        end)
    end)
    win.resetBtn:SetPoint("TOPRIGHT", -2, -2)

    ns.Mover:Register("damagemeter", win, "Damage Meter")

    local acc = 0
    win:SetScript("OnUpdate", function(_, e)
        acc = acc + e
        if acc < (InCombatLockdown() and 0.25 or 1) then return end
        acc = 0
        update()
    end)
    ns:On("PLAYER_REGEN_ENABLED", function() update(); DM:UpdateVisibility() end)
    ns:On("PLAYER_REGEN_DISABLED", function() update(); DM:UpdateVisibility() end)
    ns:On("DAMAGE_METER_COMBAT_SESSION_UPDATED", update)
    ns:On("DAMAGE_METER_CURRENT_SESSION_UPDATED", update)
    ns:On("DAMAGE_METER_RESET", function() DM:ShowList() end)
end

-- src: an entry of the session's combatSources (its guid and name can be secret: they are only passed on)
function DM:ShowSource(src)
    if not win then return end
    if type(src.sourceGUID) == "nil" then
        ns:Print("Damage meter: the client gives no id for this entry, so no skill breakdown.")
        return
    end
    local r, g, b = classColor(src)
    detail = { guid = src.sourceGUID, name = src.name, r = r, g = g, b = b }
    layout()
end

function DM:ShowList()
    if not win then return end
    detail = nil
    layout()
end

function DM:UpdateVisibility()
    if not win then return end
    local c = cfg()
    local show = c.enabled and (not c.hideOutOfCombat or InCombatLockdown() or ns.Mover:IsUnlocked())
    win:SetShown(show)
end

function DM:Init()
    if not ns.db.damagemeter.enabled then return end
    self:Start()
end

function DM:Start()
    if started then return end
    if not available() then return end   -- client without the damage meter API
    started = true
    create()
end

function DM:Apply()
    if not ns.db then return end
    local c = cfg()
    if c.enabled and not started then self:Start() end
    if not started then return end
    if c.hideBlizzard then pcall(C_CVar.SetCVar, "damageMeterEnabled", 0) end
    layout()
    ns.Mover:Position("damagemeter")
    self:UpdateVisibility()
end
