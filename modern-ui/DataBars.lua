local ADDON, ns = ...
local UI = ns.UI

-- Experience and reputation bars. Blizzard's StatusTrackingBarManager is
-- hidden (optional) and replaced by two simple bars.
local DB = ns:NewModule("databars")
ns.DataBars = DB

local hider = CreateFrame("Frame")
hider:Hide()

local bars = {}
local started = false

local function cfgOf(key) return ns.db.databars[key] end

----------------------------------------------------------------------
-- Data
----------------------------------------------------------------------
local function xpData()
    local ok, res = pcall(function()
        if IsXPUserDisabled and IsXPUserDisabled() then return nil end
        local lvl = UnitLevel("player")
        local maxLvl = GetMaxPlayerLevel and GetMaxPlayerLevel() or 60
        if lvl >= maxLvl then return nil end
        local cur, max = UnitXP("player"), UnitXPMax("player")
        if not max or max <= 0 then return nil end
        return { cur = cur, max = max, rested = GetXPExhaustion and GetXPExhaustion() or 0, level = lvl }
    end)
    return ok and res or nil
end

local function repData()
    local ok, res = pcall(function()
        local name, reaction, min, max, value
        if C_Reputation and C_Reputation.GetWatchedFactionData then
            local d = C_Reputation.GetWatchedFactionData()
            if d and d.name and d.name ~= "" then
                name, reaction = d.name, d.reaction
                min, max, value = d.currentReactionThreshold, d.nextReactionThreshold, d.currentStanding
            end
        elseif GetWatchedFactionInfo then
            name, reaction, min, max, value = GetWatchedFactionInfo()
        end
        if not name then return nil end
        local cur, span = value - min, max - min
        if span <= 0 then cur, span = 1, 1 end
        return { cur = cur, max = span, name = name, reaction = reaction }
    end)
    return ok and res or nil
end

local function repColor(reaction)
    local c = reaction and FACTION_BAR_COLORS and FACTION_BAR_COLORS[reaction]
    if c then return c.r, c.g, c.b end
    return 0.2, 0.7, 0.3
end

----------------------------------------------------------------------
-- Bars
----------------------------------------------------------------------
local function textFor(key, d)
    if key == "xp" then
        local pct = d.cur / d.max * 100
        local s = string.format("Level %d   %s / %s  (%.1f%%)", d.level, ns.ShortNumber(d.cur), ns.ShortNumber(d.max), pct)
        if d.rested and d.rested > 0 then
            s = s .. string.format("   |cff6cb7ff+%s rested|r", ns.ShortNumber(d.rested))
        end
        return s
    end
    return string.format("%s   %s / %s  (%.1f%%)", d.name, ns.ShortNumber(d.cur), ns.ShortNumber(d.max), d.cur / d.max * 100)
end

local function createBar(key, label)
    local f = CreateFrame("Frame", "ModernUI_databar_" .. key, UIParent)
    f:SetSize(600, 10)
    f:EnableMouse(true)
    f.key = key
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0.03, 0.03, 0.04, 0.9)
    f.rested = CreateFrame("StatusBar", nil, f)
    f.rested:SetPoint("TOPLEFT", 1, -1)
    f.rested:SetPoint("BOTTOMRIGHT", -1, 1)
    f.bar = CreateFrame("StatusBar", nil, f)
    f.bar:SetPoint("TOPLEFT", 1, -1)
    f.bar:SetPoint("BOTTOMRIGHT", -1, 1)
    f.bar:SetFrameLevel(f.rested:GetFrameLevel() + 1)
    f.overlay = CreateFrame("Frame", nil, f)
    f.overlay:SetAllPoints()
    f.overlay:SetFrameLevel(f.bar:GetFrameLevel() + 2)
    f.borders = UI.AddBorder(f.overlay, 1, 0, 0, 0, 1, "OVERLAY")
    f.text = f.overlay:CreateFontString(nil, "OVERLAY")
    f.text:SetPoint("CENTER")
    f:SetScript("OnEnter", function(self)
        local c = cfgOf(self.key)
        if self.data then self.text:SetText(textFor(self.key, self.data)) end
        if c.text == "HOVER" then self.text:Show() end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.label or "")
        if self.data then GameTooltip:AddLine(textFor(self.key, self.data), 1, 1, 1) end
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if cfgOf(self.key).text == "HOVER" then self.text:Hide() end
    end)
    f.label = label
    bars[key] = f
    ns.Mover:Register("databar_" .. key, f, label)
    return f
end

local function updateBar(key)
    local f = bars[key]
    if not f then return end
    local c = cfgOf(key)
    local d
    if c.enabled then
        if key == "xp" then d = xpData() else d = repData() end
    end
    f.data = d
    if not d then f:Hide() return end
    f:Show()
    f.bar:SetMinMaxValues(0, d.max)
    f.bar:SetValue(d.cur)
    f.rested:SetMinMaxValues(0, d.max)
    if key == "xp" then
        f.bar:SetStatusBarColor(0.58, 0.0, 0.55)
        f.rested:SetStatusBarColor(0.25, 0.5, 0.9, 0.8)
        f.rested:SetValue(math.min(d.max, d.cur + (d.rested or 0)))
        f.rested:Show()
    else
        f.bar:SetStatusBarColor(repColor(d.reaction))
        f.rested:Hide()
    end
    f.text:SetText(textFor(key, d))
    f.text:SetShown(c.text == "ALWAYS")
end

-- Topmost bar that is currently showing (the cast bar stacks on it).
function DB:GetTopBar()
    for _, key in ipairs({ "rep", "xp" }) do
        local f = bars[key]
        if f and f:IsShown() then return f end
    end
end

local lastTop
local function updateAll()
    for key in pairs(bars) do updateBar(key) end
    local top = DB:GetTopBar()
    if top ~= lastTop then
        lastTop = top
        if ns.UnitFrames and ns.UnitFrames.RefreshCastAnchor then ns.UnitFrames:RefreshCastAnchor() end
    end
end

local function layout()
    local tex = ns:GetTexture()
    for key, f in pairs(bars) do
        local c = cfgOf(key)
        f:SetSize(c.width, c.height)
        f:SetScale(c.scale * ns.db.general.scale)
        f:SetAlpha(c.alpha)
        f.bar:SetStatusBarTexture(tex)
        f.rested:SetStatusBarTexture(tex)
        ns:SetFont(f.text, math.max(8, math.min(ns.db.general.fontSize, c.height - 1)), "OUTLINE")
        ns.Mover:Position("databar_" .. key)
    end
    updateAll()
end

function DB:Init()
    local d = ns.db.databars
    if not (d.xp.enabled or d.rep.enabled) then return end
    self:Start()
end

function DB:Start()
    if started then return end
    started = true
    createBar("xp", "Experience Bar")
    createBar("rep", "Reputation Bar")
    for _, e in ipairs({ "PLAYER_XP_UPDATE", "UPDATE_EXHAUSTION", "PLAYER_LEVEL_UP", "PLAYER_UPDATE_RESTING",
                         "UPDATE_FACTION", "PLAYER_ENTERING_WORLD", "ENABLE_XP_GAIN", "DISABLE_XP_GAIN" }) do
        ns:On(e, updateAll)
    end
end

function DB:Apply()
    if not ns.db then return end
    local d = ns.db.databars
    if not started then
        if d.xp.enabled or d.rep.enabled then self:Start() else return end
    end
    ns:AfterCombat("databars_apply", function()
        if d.hideBlizzard and _G.StatusTrackingBarManager then
            _G.StatusTrackingBarManager:SetParent(hider)
        end
        layout()
        if ns.UnitFrames and ns.UnitFrames.RefreshCastAnchor then ns.UnitFrames:RefreshCastAnchor() end
    end)
end
