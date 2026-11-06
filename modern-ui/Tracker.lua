local ADDON, ns = ...
local UI = ns.UI

-- Quest / objective tracker.
--  * Position: Blizzard's tracker is an Edit Mode system, so it is anchored
--    through the saved C methods (ns.SetPoint) to a holder we own, and the
--    anchor is re-asserted after every Edit Mode layout apply.
--  * Skin: a panel that fits the visible quests, accent headers without
--    Blizzard's header art, optional objective font size. Re-applied (next
--    frame, debounced) after each tracker Update.
local TR = ns:NewModule("tracker")
ns.Tracker = TR

local ACCENT = { 0.30, 0.82, 1.00 }

local SUB_TRACKERS = {
    "ScenarioObjectiveTracker", "UIWidgetObjectiveTracker", "CampaignQuestObjectiveTracker",
    "QuestObjectiveTracker", "AdventureObjectiveTracker", "AchievementObjectiveTracker",
    "MonthlyActivitiesObjectiveTracker", "ProfessionsRecipeTracker", "BonusObjectiveTracker",
    "WorldQuestObjectiveTracker", "InitiativeTasksObjectiveTracker",
}
-- These two render through a shared widget pool: only their header is safe to touch.
local POOLED = { ScenarioObjectiveTracker = true, UIWidgetObjectiveTracker = true }

local HEADER_ART = { "Background", "Line", "LineSheen", "LineGlow", "Divider", "Sheen", "Glow", "Stripe" }

local holder, panel
local started = false
local requestPlace
local updateBottomShift
local placing = false   -- our own re-anchoring must not trigger the re-anchor hooks
local placeQueued, skinQueued = false, false
local hooked = {}

local function cfg() return ns.db.tracker end

local function eachTracker(fn)
    local seen = {}
    local otf = _G.ObjectiveTrackerFrame
    local modules = otf and (otf.modules or otf.MODULES)
    if type(modules) == "table" then
        for _, t in ipairs(modules) do
            if type(t) == "table" and not seen[t] then seen[t] = true; fn(t) end
        end
    end
    for _, name in ipairs(SUB_TRACKERS) do
        local t = _G[name]
        if type(t) == "table" and not seen[t] then seen[t] = true; fn(t) end
    end
end

----------------------------------------------------------------------
-- Skin
----------------------------------------------------------------------
local function skinHeader(header)
    if type(header) ~= "table" then return end
    -- SetTexture("") only: SetAlpha / SetTexture(nil) taint Blizzard-owned textures.
    for _, k in ipairs(HEADER_ART) do
        local r = header[k]
        if type(r) == "table" and r.SetTexture then pcall(r.SetTexture, r, "") end
    end
    local text = header.Text
    if type(text) == "table" and text.SetTextColor then
        pcall(function()
            ns:SetFont(text, 15, "OUTLINE")
            text:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
        end)
    end
    if not header.molLine then
        local line = header:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.45)
        line:SetHeight(1)
        line:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
        line:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
        header.molLine = line
    end
end

local function fitPanelUnsafe()
    local f = _G.ObjectiveTrackerFrame
    local c = cfg()
    if not (f and panel) then return end
    if not (c.skin and c.background) then panel:Hide() return end
    local top = f:GetTop()
    local bottom
    eachTracker(function(t)
        if t:IsShown() and (t:GetHeight() or 0) > 1 then
            local b = t:GetBottom()
            if b and (not bottom or b < bottom) then bottom = b end
        end
    end)
    if not (top and bottom) or top <= bottom then panel:Hide() return end
    panel:ClearAllPoints()
    panel:SetPoint("TOPRIGHT", f, "TOPRIGHT", 8, 8)
    panel:SetSize((f:GetWidth() or 250) + 16, (top - bottom) + 16)
    panel.bg:SetColorTexture(0.03, 0.03, 0.04, c.bgAlpha)
    panel.borderFrame:SetShown(c.borders)
    panel:Show()
end

local function fitPanel()
    if not pcall(fitPanelUnsafe) and panel then panel:Hide() end
end

local function skinAll()
    local c = cfg()
    if not c.enabled then return end

    if c.fontSize and c.fontSize > 0 and _G.ObjectiveFont then
        pcall(_G.ObjectiveFont.SetFont, _G.ObjectiveFont, ns:GetFont(), c.fontSize, "")
    end

    if c.skin then
        local otf = _G.ObjectiveTrackerFrame
        if otf then skinHeader(otf.Header or otf.HeaderMenu) end
        eachTracker(function(t) skinHeader(t.Header) end)
    end
    fitPanel()
    updateBottomShift()
end

local function requestSkin()
    if skinQueued then return end
    skinQueued = true
    C_Timer.After(0, function()
        skinQueued = false
        skinAll()
    end)
end

local function hookTrackers()
    eachTracker(function(t)
        if not hooked[t] and t.Update then
            hooked[t] = true
            hooksecurefunc(t, "Update", requestSkin)
        end
    end)
    local otf = _G.ObjectiveTrackerFrame
    if otf and not hooked[otf] and otf.Update then
        hooked[otf] = true
        hooksecurefunc(otf, "Update", requestSkin)
    end
end

----------------------------------------------------------------------
-- Position
----------------------------------------------------------------------
-- The tracker frame is taller than its content (Blizzard sizes it to the maximum) and lays the content
-- out from the TOP. Attached below a chat window, the empty part would sit between content and window:
-- the frame is moved down by that empty height so the content's bottom edge meets the window.
local bottomShift = 0

function updateBottomShift()
    local c = cfg()
    local f = _G.ObjectiveTrackerFrame
    local chat = ns.Chat
    local want = 0
    if f and c.attach and chat and chat.GetRightPanel and chat:GetRightPanel() then
        local ok = pcall(function()
            local top = f:GetTop()
            local bottom
            eachTracker(function(t)
                if t:IsShown() and (t:GetHeight() or 0) > 1 then
                    local b = t:GetBottom()
                    if b and (not bottom or b < bottom) then bottom = b end
                end
            end)
            if top and bottom and top > bottom then
                want = math.max(0, math.floor((f:GetHeight() or 0) - (top - bottom) - 6))
            end
        end)
        if not ok then want = 0 end
    end
    if math.abs(want - bottomShift) > 2 then
        bottomShift = want
        requestPlace()
    end
end

-- where the tracker hangs: the top right of the right chat window (growing upwards) when attached,
-- otherwise its own mover box
local function anchorTarget()
    local chat = ns.Chat
    local panel = cfg().attach and chat and chat.GetRightPanel and chat:GetRightPanel()
    -- (x = a little gap to the screen edge)
    if panel then return panel, "BOTTOMRIGHT", "TOPRIGHT", 4 - bottomShift, -10 end
    return holder, "TOPRIGHT", "TOPRIGHT", 0, 0
end

local function place()
    local f = _G.ObjectiveTrackerFrame
    if not f or not holder or not cfg().enabled then return end
    ns:AfterCombat("tracker_place", function()
        local c = cfg()
        ns.SetScale(f, c.scale * ns.db.general.scale)
        f:SetAlpha(c.alpha)
        placing = true
        ns.ClearPoints(f)
        local rel, point, relPoint, y, x = anchorTarget()
        ns.SetPoint(f, point, rel, relPoint, x, y)
        placing = false
        if c.overrideHeight then pcall(f.SetHeight, f, c.height) end
        holder:SetScale(c.scale * ns.db.general.scale)
        holder:SetSize(250, c.overrideHeight and c.height or 300)
        ns.Mover:Position("tracker")
        hookTrackers()
        requestSkin()
    end)
end

function requestPlace()
    if placeQueued then return end
    placeQueued = true
    C_Timer.After(0, function() placeQueued = false; place() end)
end

function TR:RequestPlace() requestPlace() end

function TR:Init()
    if not ns.db.tracker.enabled then return end
    self:Start()
end

function TR:Start()
    if started then return end
    started = true
    holder = CreateFrame("Frame", "ModernUI_Tracker", UIParent)
    holder:SetSize(250, 300)
    ns.Mover:Register("tracker", holder, "Objective Tracker")

    local f = _G.ObjectiveTrackerFrame
    if f then
        -- child of the tracker: inherits its scale and fades with it
        panel = CreateFrame("Frame", nil, f)
        panel:SetFrameLevel(math.max(0, f:GetFrameLevel() - 1))
        panel.bg = panel:CreateTexture(nil, "BACKGROUND")
        panel.bg:SetAllPoints()
        panel.borderFrame = CreateFrame("Frame", nil, panel)
        panel.borderFrame:SetAllPoints()
        panel.borders = UI.AddBorder(panel.borderFrame, 1, 0, 0, 0, 1, "BORDER")
        panel:Hide()
        if f.ApplySystemAnchor then hooksecurefunc(f, "ApplySystemAnchor", requestPlace) end
        -- Blizzard re-anchors the tracker to its default spot (under the old minimap) from several
        -- code paths: put it back whenever its anchor is not our holder any more
        for _, m in ipairs({ "SetPoint", "ClearAllPoints" }) do
            if type(f[m]) == "function" then
                pcall(hooksecurefunc, f, m, function()
                    if started and not placing and cfg().enabled then requestPlace() end
                end)
            end
        end
        local wd, acc = CreateFrame("Frame"), 0
        wd:SetScript("OnUpdate", function(_, e)
            acc = acc + e
            if acc < 0.5 then return end
            acc = 0
            if not (started and ns.db and cfg().enabled and holder) then return end
            local ok, _, rel = pcall(f.GetPoint, f, 1)
            if not ok or rel ~= (anchorTarget()) then requestPlace() end
        end)
    end
    ns:On("EDIT_MODE_LAYOUTS_UPDATED", requestPlace)
    ns:On("PLAYER_ENTERING_WORLD", requestPlace)
    ns:On("PLAYER_LEVEL_UP", requestPlace)
    ns:On("QUEST_LOG_UPDATE", requestSkin)
    ns:On("QUEST_WATCH_LIST_CHANGED", requestSkin)
end

function TR:Apply()
    if not ns.db then return end
    if not cfg().enabled then
        if started then ns:Print("Objective tracker takeover disabled: /reload to restore Blizzard's position.") end
        return
    end
    if not started then self:Start() end
    place()
end
