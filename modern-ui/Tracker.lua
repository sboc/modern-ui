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
    if ns.APRSkin and ns.APRSkin.SyncWidth then pcall(ns.APRSkin.SyncWidth, ns.APRSkin) end
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
-- Quest curation
----------------------------------------------------------------------
-- Nothing of Blizzard's is replaced (that taints the tracker's update): the tracked set and its order are
-- managed through the normal quest log API. Blizzard draws quests in the order they were tracked, so
-- re-tracking in level order sorts the tracker.
--  * grey (trivial) and red (too high) quests are untracked, unless the player tracked them by hand
--  * quests the player tracked by hand are "pinned": they stay tracked until they are turned in, abandoned
--    or untracked by the player. Over the max count the oldest pinned one is untracked first.
--  * the free slots go to the lowest level quests, the list is ordered lowest level first
-- The super tracked quest is never untracked. Untracked quests stay in the quest log.
local trimQueued, trimming = false, false
local ignoreUntil = 0   -- watch list events caused by our own changes are not the player's doing

local function pins()
    local c = cfg()
    c.pinned = c.pinned or {}
    return c.pinned
end

local function pinQuest(id)
    local c = cfg()
    c.pinSeq = (c.pinSeq or 0) + 1
    pins()[id] = c.pinSeq
end

local function levelOf(id)
    local lvl = C_QuestLog.GetQuestDifficultyLevel and C_QuestLog.GetQuestDifficultyLevel(id)
    if not lvl or lvl <= 0 then return nil end
    return lvl
end

local function isGreyOrRed(lvl)
    local p = UnitLevel("player") or 1
    local green = (_G.GetQuestGreenRange and _G.GetQuestGreenRange("player")) or 8
    return lvl <= p - green or lvl >= p + 5
end

local function byLevel(x, y)
    local lx, ly = x.lvl or 999, y.lvl or 999   -- unknown level (quest log not loaded yet) sorts last
    if lx ~= ly then return lx < ly end
    return x.idx < y.idx
end

local function curateQuests()
    local c = cfg()
    local max = c.maxQuests or 0
    if not (C_QuestLog and (max > 0 or c.hideGreyRed or c.sortByLevel)) then return end
    local n = C_QuestLog.GetNumQuestWatches() or 0
    if n == 0 then return end
    local sup = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
    if sup == 0 then sup = nil end
    local pin = pins()

    local current, items = {}, {}
    for i = 1, n do   -- watch order = order in which the quests were tracked
        local id = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
        if id then
            current[#current + 1] = id
            items[#items + 1] = { id = id, idx = i, lvl = levelOf(id), seq = pin[id] }
        end
    end
    -- pins of quests that are gone (turned in, abandoned) or not tracked any more
    local tracked = {}
    for _, id in ipairs(current) do tracked[id] = true end
    for id in pairs(pin) do
        if not tracked[id] then pin[id] = nil end
    end

    -- what stays tracked
    local keep = {}
    for _, it in ipairs(items) do
        local hide = c.hideGreyRed and not it.seq and it.lvl and isGreyOrRed(it.lvl) and it.id ~= sup
        if not hide then keep[#keep + 1] = it end
    end
    if max > 0 then
        local S, P, U = nil, {}, {}
        for _, it in ipairs(keep) do
            if it.id == sup then S = it
            elseif it.seq then P[#P + 1] = it
            else U[#U + 1] = it end
        end
        table.sort(P, function(x, y) return x.seq < y.seq end)   -- oldest pinned first
        table.sort(U, byLevel)
        local budget = max - (S and 1 or 0)
        while #P > budget do
            pin[P[1].id] = nil   -- too many turned on: the oldest goes (and is not pinned any more)
            table.remove(P, 1)
        end
        keep = {}
        if S then keep[#keep + 1] = S end
        for _, it in ipairs(P) do keep[#keep + 1] = it end
        for i = 1, math.min(#U, budget - #P) do keep[#keep + 1] = U[i] end
    end
    if c.sortByLevel then table.sort(keep, byLevel)
    else table.sort(keep, function(x, y) return x.idx < y.idx end) end

    local wanted, wantedSet = {}, {}
    for i, it in ipairs(keep) do wanted[i] = it.id; wantedSet[it.id] = true end

    -- first position where the tracked list differs from the wanted one: everything from there is redone
    local tail = {}
    for _, id in ipairs(current) do
        if wantedSet[id] then tail[#tail + 1] = id end
    end
    local cut = 1
    while cut <= #tail and tail[cut] == wanted[cut] do cut = cut + 1 end
    local redo = {}
    for i = cut, #tail do redo[tail[i]] = true end

    local changed = false
    trimming = true
    for _, id in ipairs(current) do
        if not wantedSet[id] or redo[id] then
            pcall(C_QuestLog.RemoveQuestWatch, id)
            changed = true
        end
    end
    local manual = Enum and Enum.QuestWatchType and Enum.QuestWatchType.Manual
    for i = cut, #wanted do
        pcall(C_QuestLog.AddQuestWatch, wanted[i], manual)
        changed = true
    end
    if changed and sup and wantedSet[sup] and C_SuperTrack.GetSuperTrackedQuestID() ~= sup then
        pcall(C_SuperTrack.SetSuperTrackedQuestID, sup)
    end
    trimming = false
    if changed then ignoreUntil = GetTime() + 1 end
end

local function requestTrim()
    if trimQueued or trimming then return end
    trimQueued = true
    C_Timer.After(0.2, function()
        trimQueued = false
        ns:AfterCombat("tracker_trim", curateQuests)
    end)
end

-- the player tracking / untracking a quest by hand (quest log checkbox, shift-click): a manual watch is a pin
-- (auto-tracking on accept is an Automatic watch)
local function onWatchChanged(_, id, added)
    if id and not trimming and GetTime() > ignoreUntil then
        if not added then
            pins()[id] = nil
        else
            local wt = C_QuestLog.GetQuestWatchType and C_QuestLog.GetQuestWatchType(id)
            if Enum and Enum.QuestWatchType and wt == Enum.QuestWatchType.Manual then pinQuest(id) end
        end
    end
    requestSkin()
    requestTrim()
end

----------------------------------------------------------------------
-- Position
----------------------------------------------------------------------
-- where the tracker hangs: attached, its TOP edge sits a fixed distance (the Height option, clamped to the
-- screen) above the top right of the right chat window and the content grows down from there. The frame's
-- own height is Blizzard's business and changes with the layout (minimap, combat, ...): anchoring by the
-- bottom would make the content move with it. Otherwise it hangs on its own mover box.
local function anchorTarget()
    local chat = ns.Chat
    local c = cfg()
    local panel = c.attach and chat and chat.GetRightPanel and chat:GetRightPanel()
    if panel then
        local scale = c.scale * ns.db.general.scale
        local rise = c.height
        local ui, pTop, pScale = UIParent:GetTop(), panel:GetTop(), panel:GetEffectiveScale()
        if ui and pTop and pScale and scale > 0 then
            local free = (ui - pTop * pScale / UIParent:GetEffectiveScale() - 20) / scale
            rise = math.max(100, math.min(rise, math.floor(free)))
        end
        -- (-10 x = a little gap to the screen edge)
        return panel, "TOPRIGHT", "TOPRIGHT", -10, rise
    end
    return holder, "TOPRIGHT", "TOPRIGHT", 0, 0
end

-- Azeroth Pilot Reloaded's "attach to quest log" (guide ABOVE the tracker) takes the tracker frame over: it
-- re-anchors it to UIParent just below its own panels and shortens it. While it owns the frame we must not
-- put it back (the two would fight forever = flicker); we only step in when OUR wanted spot changed.
local lastWanted

local function aprState(f)
    local qt = _G.APR and _G.APR.QuestTracker
    local state = qt and qt.displacement
    if state and state.frame == f then return state end
end

-- APR owns the frame only while it still sits exactly where APR put it (Blizzard or Edit Mode may have
-- moved it since, e.g. during combat: then the frame is ours again)
local function aprOwns(f)
    local state = aprState(f)
    if not state then return false end
    local applied = state.applied
    if type(applied) ~= "table" then return true end
    local ok, same = pcall(function()
        if f:GetNumPoints() ~= #applied then return false end
        for i, p in ipairs(applied) do
            local pt, rel, rp, x, y = f:GetPoint(i)
            if pt ~= p[1] or rel ~= p[2] or rp ~= p[3]
                or math.abs((x or 0) - p[4]) > 0.01 or math.abs((y or 0) - p[5]) > 0.01 then
                return false
            end
        end
        return true
    end)
    return not ok or same
end

local function wantedKey(rel, point, relPoint, x, y)
    local top, right = 0, 0
    if rel and rel.GetTop then
        top, right = math.floor((rel:GetTop() or 0) + 0.5), math.floor((rel:GetRight() or 0) + 0.5)
    end
    return table.concat({ tostring(rel), point, relPoint, x, y, top, right }, "|")
end

local function place()
    local f = _G.ObjectiveTrackerFrame
    if not f or not holder or not cfg().enabled then return end
    ns:AfterCombat("tracker_place", function()
        local c = cfg()
        -- every write from addon code taints the Blizzard frame's state, and its layout code reads that
        -- back (in combat: secret auras -> "Auras cannot be accessed when secret while tainted"), so
        -- only write what actually changed
        local wantScale = c.scale * ns.db.general.scale
        if math.abs((f:GetScale() or 0) - wantScale) > 0.001 then ns.SetScale(f, wantScale) end
        if math.abs((f:GetAlpha() or 0) - c.alpha) > 0.001 then f:SetAlpha(c.alpha) end
        local rel, point, relPoint, x, y = anchorTarget()
        local key = wantedKey(rel, point, relPoint, x, y)
        local state = aprState(f)
        local owned = state ~= nil and aprOwns(f)
        local released = false
        if state and (not owned or key ~= lastWanted) then
            -- our spot moved, or something else moved the frame away from APR's placement: let APR
            -- hand the frame back, then it re-attaches from our spot
            pcall(_G.APR.QuestTracker.Release, _G.APR.QuestTracker)
            owned, released = false, true
        end
        if not owned then
            placing = true
            local p, r, rp, px, py = f:GetPoint(1)
            local same = f:GetNumPoints() == 1 and p == point and r == rel and rp == relPoint
                and math.abs((px or 0) - x) < 0.5 and math.abs((py or 0) - y) < 0.5
            if not same then
                ns.ClearPoints(f)
                ns.SetPoint(f, point, rel, relPoint, x, y)
            end
            placing = false
            if c.overrideHeight then pcall(f.SetHeight, f, c.height) end
            lastWanted = key
            if released then
                C_Timer.After(0.2, function()
                    local cs = _G.APR and _G.APR.currentStep
                    if cs and cs.RefreshCurrentStepFrameAnchor then pcall(cs.RefreshCurrentStepFrameAnchor, cs) end
                end)
            end
        end
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

-- width of the tracker as drawn (its skin panel included), in UIParent units
function TR:GetVisualWidth()
    local f = _G.ObjectiveTrackerFrame
    local c = ns.db and cfg()
    if not (f and c) then return end
    local w, fs, ps = f:GetWidth(), f:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if not (w and fs and ps and ps > 0) then return end
    if c.skin and c.background then w = w + 16 end
    return math.floor(w * fs / ps * 2 + 0.5) / 2
end

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
            if aprOwns(f) then return end
            if not ok or rel ~= (anchorTarget()) then requestPlace() end
        end)
    end
    ns:On("EDIT_MODE_LAYOUTS_UPDATED", requestPlace)
    ns:On("PLAYER_ENTERING_WORLD", requestPlace)
    ns:On("PLAYER_LEVEL_UP", function() requestPlace(); requestTrim() end)
    ns:On("QUEST_LOG_UPDATE", requestSkin)
    ns:On("QUEST_WATCH_LIST_CHANGED", onWatchChanged)
    ns:On("QUEST_TURNED_IN", function(_, id) if id then pins()[id] = nil end end)
    ns:On("QUEST_REMOVED", function(_, id) if id then pins()[id] = nil end end)
    ns:On("QUEST_ACCEPTED", requestTrim)
    requestTrim()
end

function TR:Apply()
    if not ns.db then return end
    if not cfg().enabled then
        if started then ns:Print("Objective tracker takeover disabled: /reload to restore Blizzard's position.") end
        return
    end
    if not started then self:Start() end
    requestTrim()
    place()
end
