local ADDON, ns = ...
local UI = ns.UI

-- Damage meter window. Reads Blizzard's built-in meter data (C_DamageMeter)
-- and draws its own compact window. Numbers and names can be "secret" in
-- combat, so they only ever go to StatusBars / SetText / string.format.
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
    local sources = s and s.combatSources
    local isRate = (c.type == "Dps" or c.type == "Hps")

    for i = 1, MAX_ROWS do
        local row = rows[i]
        local src = (i <= c.rows) and sources and sources[i] or nil
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
        r.name:ClearAllPoints()
        r.name:SetPoint("LEFT", r, "LEFT", c.showRank and 22 or 6, 0)
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
    ns:On("DAMAGE_METER_RESET", update)
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
