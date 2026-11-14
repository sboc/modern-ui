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
local reanchors = 0   -- times Blizzard moved the tracker and we put it back (/mui tracker)
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
            -- the skin runs after every tracker update (each looted item fires one): a font write re-renders
            -- the text even when nothing changed, so only write what differs
            local file, size, flags = text:GetFont()
            if file ~= ns:GetFont() or math.abs((size or 0) - 15) > 0.01 or flags ~= "OUTLINE" then
                ns:SetFont(text, 15, "OUTLINE")
            end
            local r, g, b = text:GetTextColor()
            if math.abs(r - ACCENT[1]) > 0.01 or math.abs(g - ACCENT[2]) > 0.01 or math.abs(b - ACCENT[3]) > 0.01 then
                text:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
            end
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
    if panel:GetNumPoints() == 0 then panel:SetPoint("TOPRIGHT", f, "TOPRIGHT", 8, 8) end
    local w, h = (f:GetWidth() or 250) + 16, (top - bottom) + 16
    if math.abs(panel:GetWidth() - w) > 0.01 or math.abs(panel:GetHeight() - h) > 0.01 then panel:SetSize(w, h) end
    if panel.bgAlpha ~= c.bgAlpha then
        panel.bgAlpha = c.bgAlpha
        panel.bg:SetColorTexture(0.03, 0.03, 0.04, c.bgAlpha)
    end
    panel.borderFrame:SetShown(c.borders)
    panel:Show()
end

local function fitPanel()
    if not pcall(fitPanelUnsafe) and panel then panel:Hide() end
end

local function skinAll()
    local c = cfg()
    if not c.enabled then return end

    -- ObjectiveFont is shared by every objective line: setting it (even to the same values) re-renders them all
    local of = _G.ObjectiveFont
    if c.fontSize and c.fontSize > 0 and of then
        local file, size, flags = of:GetFont()
        if file ~= ns:GetFont() or math.abs((size or 0) - c.fontSize) > 0.01 or (flags or "") ~= "" then
            pcall(of.SetFont, of, ns:GetFont(), c.fontSize, "")
        end
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
-- Quest limit
----------------------------------------------------------------------
-- Nothing of Blizzard's is replaced or called into: a replaced tracker method taints every tracker update, and a
-- tainted update errors in combat ("Auras cannot be accessed when secret while tainted"). The limit is applied
-- through the quest watch API instead. Quests over the limit are untracked for real and remembered ("parked", per
-- character); they are tracked again when a slot frees up, when the route reaches them, or when the limit is set
-- to 0. What stays tracked, in order: the super tracked quest, quests the player tracked by hand (pinned), with
-- an Azeroth Pilot Reloaded route running the quests the route reaches next, then the rest in the order they were
-- tracked. Parked quests stay in the quest log.
local trimQueued, trimming = false, false
local ignoreUntil = 0   -- watch list events caused by our own changes are not the player's doing
local lastLimit = 0
local lastTrim          -- what the last pass did (/mui tracker)

local function limitMax()
    local n = cfg().maxQuests or 0
    return n > 0 and n or nil
end

-- per character: the settings profile can be shared between characters, quests are not
local function charStore(key)
    local guid = UnitGUID("player")
    if type(guid) ~= "string" then return end
    local c = cfg()
    c[key] = c[key] or {}
    c[key][guid] = c[key][guid] or {}
    return c[key][guid]
end

-- Azeroth Pilot Reloaded: the quests the route needs next. Returns { [questID] = position } where position is the
-- first upcoming step (current step included) that mentions the quest, or nil when APR has no route running.
local ROUTE_LOOKAHEAD = 400

local function routeRanks()
    local apr = _G.APR
    if not (apr and apr.ActiveRoute and apr.ActiveRoute ~= "" and apr.PlayerID and _G.APRData
        and type(apr.GetRouteSteps) == "function" and type(apr.GetStepQuestIDs) == "function") then return end
    local progress = _G.APRData[apr.PlayerID]
    local index = progress and progress[apr.ActiveRoute]
    if type(index) ~= "number" then return end
    local steps = apr:GetRouteSteps(apr.ActiveRoute)
    if type(steps) ~= "table" or #steps == 0 then return end
    local ranks, count = {}, 0
    for i = index, math.min(#steps, index + ROUTE_LOOKAHEAD) do
        local step = steps[i]
        if step and (type(apr.StepFilterQoL) ~= "function" or apr:StepFilterQoL(step)) then
            for _, id in ipairs(apr:GetStepQuestIDs(step)) do
                if not ranks[id] then ranks[id] = i; count = count + 1 end
            end
        end
    end
    if count > 0 then return ranks end
end

local function inLog(id)
    if C_QuestLog.IsOnQuest then return C_QuestLog.IsOnQuest(id) and true or false end
    return C_QuestLog.GetLogIndexForQuestID ~= nil and C_QuestLog.GetLogIndexForQuestID(id) ~= nil
end

local function trimQuests()
    local Q = C_QuestLog
    if not (Q and Q.GetNumQuestWatches and Q.GetQuestIDForQuestWatchIndex and Q.AddQuestWatch and Q.RemoveQuestWatch) then
        lastTrim = "quest watch API missing"
        return
    end
    -- quest log not loaded yet: nothing can be told apart from "quest is gone"
    if Q.GetNumQuestLogEntries and (Q.GetNumQuestLogEntries() or 0) == 0 then lastTrim = "quest log empty" return end
    local parked, pinned = charStore("parkedQuests"), charStore("pinnedQuests")
    if not (parked and pinned) then lastTrim = "no player GUID" return end
    local max = limitMax()

    -- candidates: what is tracked now (in the order it was tracked), then what we parked (oldest first)
    local watched, list = {}, {}
    for i = 1, Q.GetNumQuestWatches() or 0 do
        local id = Q.GetQuestIDForQuestWatchIndex(i)
        if id then
            watched[id] = true
            parked[id] = nil   -- tracked again by the player
            list[#list + 1] = { id = id, order = i }
        end
    end
    for id in pairs(pinned) do
        if not watched[id] then pinned[id] = nil end
    end
    local seq = 0
    for id, s in pairs(parked) do
        if inLog(id) then
            list[#list + 1] = { id = id, order = 1e5 + s }
            if s > seq then seq = s end
        else
            parked[id] = nil   -- turned in or abandoned
        end
    end

    local keep = {}
    if max then
        local ok, ranks = pcall(routeRanks)
        if not ok then ranks = nil end
        local sup = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID() or 0
        for _, it in ipairs(list) do
            it.rank = (it.id == sup and 0) or (pinned[it.id] and 1) or (ranks and ranks[it.id] and 1 + ranks[it.id]) or 1e7
        end
        table.sort(list, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            return a.order < b.order
        end)
        for i = 1, math.min(max, #list) do keep[list[i].id] = true end
    else
        for _, it in ipairs(list) do keep[it.id] = true end   -- limit off: everything parked comes back
    end

    local removed, added = 0, 0
    local auto = Enum and Enum.QuestWatchType and Enum.QuestWatchType.Automatic
    trimming = true
    for _, it in ipairs(list) do
        if watched[it.id] and not keep[it.id] and pcall(Q.RemoveQuestWatch, it.id) then
            seq = seq + 1
            parked[it.id] = seq
            removed = removed + 1
        end
    end
    for _, it in ipairs(list) do
        if keep[it.id] and not watched[it.id] then
            local ok, res = pcall(Q.AddQuestWatch, it.id, auto)
            if ok and res ~= false then
                parked[it.id] = nil
                added = added + 1
            end
        end
    end
    trimming = false
    if removed + added > 0 then ignoreUntil = GetTime() + 1 end
    lastTrim = string.format("limit=%s candidates=%d untracked=%d tracked=%d", tostring(max), #list, removed, added)
end

local function requestTrim()
    if trimQueued then return end
    trimQueued = true
    C_Timer.After(0.2, function()
        trimQueued = false
        ns:AfterCombat("tracker_trim", function()
            local ok, err = pcall(trimQuests)
            trimming = false
            if not ok then lastTrim = "error: " .. tostring(err) end
        end)
    end)
end

-- the player tracking / untracking a quest by hand (quest log, shift-click): a manual watch is pinned and stays
-- until it is untracked, turned in or abandoned. Tracking on accept is an Automatic watch: not pinned.
local function onWatchChanged(_, id, added)
    if type(id) == "number" and not trimming and GetTime() > ignoreUntil then
        local pinned = charStore("pinnedQuests")
        if pinned then
            local manual = Enum and Enum.QuestWatchType and Enum.QuestWatchType.Manual
            local wt = added and C_QuestLog.GetQuestWatchType and C_QuestLog.GetQuestWatchType(id)
            pinned[id] = (added and manual ~= nil and wt == manual) and true or nil
        end
    end
    requestSkin()
    requestTrim()
end

-- the route moved on: the quests that are next change
local aprHooked = false
local function hookRoute()
    local apr = _G.APR
    if aprHooked or not (apr and type(apr.SetRouteProgress) == "function") then return end
    aprHooked = true
    hooksecurefunc(apr, "SetRouteProgress", function()
        if limitMax() then requestTrim() end
    end)
end

-- Which fields of the tracker frames (and which globals its update reads) were last written by addon code:
-- reading one of those taints Blizzard's update, and a tainted update errors on secret auras in combat.
-- A healthy tracker lists only our own header lines (molLine), which Blizzard never reads.
local TAINT_GLOBALS = {
    "ShouldShowMawBuffs", "IsInJailersTower", "IsOnGroundFloorInJailersTower", "PlaySound", "SOUNDKIT",
    "C_Scenario", "C_UnitAuras", "ObjectiveTrackerFrame", "ObjectiveTrackerManager", "ScenarioObjectiveTracker",
    "EditModeManagerFrame", "GenerateClosure", "ipairs", "pairs", "math", "table",
}
local TAINT_MIXINS = {
    "ObjectiveTrackerFrameMixin", "ObjectiveTrackerContainerMixin", "ObjectiveTrackerContainerHeaderMixin",
    "ObjectiveTrackerModuleMixin", "ObjectiveTrackerModuleHeaderMixin", "ScenarioObjectiveTrackerMixin",
    "EditModeSystemMixin",
}

local function taintScan()
    local out = {}
    local function check(label, t, k)
        local ok, secure, who = pcall(issecurevariable, t, k)
        if ok and not secure then out[#out + 1] = label .. " <- " .. tostring(who) end
    end
    local function scan(label, t)
        if type(t) ~= "table" then return end
        for k in pairs(t) do
            if type(k) == "string" then check(label .. "." .. k, t, k) end
        end
    end
    for _, name in ipairs(TAINT_GLOBALS) do check(name, _G, name) end
    for _, name in ipairs(TAINT_MIXINS) do
        check(name, _G, name)
        scan(name, _G[name])
    end
    local function frame(label, f)
        if type(f) ~= "table" then return end
        scan(label, f)
        scan(label .. ".Header", f.Header)
        scan(label .. ".Header.MinimizeButton", type(f.Header) == "table" and f.Header.MinimizeButton or nil)
    end
    frame("ObjectiveTrackerFrame", _G.ObjectiveTrackerFrame)
    eachTracker(function(t)
        local ok, name = pcall(t.GetName, t)
        frame(ok and name or tostring(t), t)
    end)
    return out
end

function TR:Debug()
    self:DebugPlacement()
    local scan = taintScan()
    cfg().taintScan = nil   -- (an earlier build kept the list in the settings)
    ns:Print("addon-written tracker fields: " .. #scan)
    for i = 1, math.min(#scan, 40) do ns:Print("  " .. scan[i]) end
    local apr = _G.APR
    ns:Print(string.format("limit=%s APR=%s route=%s PlayerID=%s hooked=%s",
        tostring(limitMax()), tostring(apr ~= nil), tostring(apr and apr.ActiveRoute), tostring(apr and apr.PlayerID),
        tostring(aprHooked)))
    ns:Print("re-anchored after Blizzard moved it: " .. reanchors .. " times")
    local prog = apr and _G.APRData and _G.APRData[apr.PlayerID]
    ns:Print("step index: " .. tostring(prog and apr.ActiveRoute and prog[apr.ActiveRoute]))
    ns:Print(string.format("watch API: %s / %s, watches=%s",
        tostring(C_QuestLog and C_QuestLog.GetNumQuestWatches ~= nil),
        tostring(C_QuestLog and C_QuestLog.GetQuestIDForQuestWatchIndex ~= nil),
        tostring(C_QuestLog and C_QuestLog.GetNumQuestWatches and C_QuestLog.GetNumQuestWatches())))
    local ok, ranks = pcall(routeRanks)
    if not ok then ns:Print("routeRanks error: " .. tostring(ranks)) return end
    local n = 0
    for _ in pairs(ranks or {}) do n = n + 1 end
    ns:Print("route quests ahead: " .. n)
    local pinned, parked = charStore("pinnedQuests") or {}, charStore("parkedQuests") or {}
    local function line(label, id)
        ns:Print(string.format("  %s: %s (%s) route step %s%s", label, tostring(id),
            tostring(id and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)),
            tostring(ranks and id and ranks[id]), pinned[id] and " pinned" or ""))
    end
    for i = 1, (C_QuestLog and C_QuestLog.GetNumQuestWatches and C_QuestLog.GetNumQuestWatches() or 0) do
        line("watch " .. i, C_QuestLog.GetQuestIDForQuestWatchIndex(i))
    end
    for id in pairs(parked) do line("parked", id) end
    ns:Print("last limit pass: " .. tostring(lastTrim))
end

local function applyLimit()
    local max = limitMax() or 0
    if max > 0 then hookRoute() end
    if max == lastLimit then return end
    lastLimit = max
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
        local underMinimap = false
        local ui, pTop, pRight, pScale = UIParent:GetTop(), panel:GetTop(), panel:GetRight(), panel:GetEffectiveScale()
        if ui and pTop and pRight and pScale and scale > 0 then
            local uiScale = UIParent:GetEffectiveScale()
            pTop, pRight = pTop * pScale / uiScale, pRight * pScale / uiScale
            local limit = ui - 20
            -- a minimap above the tracker's column (16:9 layout: top right): the tracker hangs right under it
            -- (12 px gap, like the other frames) instead of the Height option
            local mm = ns.Minimap and ns.Minimap.GetFrame and ns.Minimap:GetFrame()
            if mm and mm:IsShown() then
                local k = mm:GetEffectiveScale() / uiScale
                local l, r, b = mm:GetLeft(), mm:GetRight(), mm:GetBottom()
                if l and r and b and b * k > pTop and l * k < pRight and r * k > pRight - 250 * scale then
                    limit = math.min(limit, b * k - 12)
                    rise = math.huge
                    underMinimap = true
                end
            end
            rise = math.max(100, math.min(rise, math.floor((limit - pTop) / scale)))
        end
        -- (-10 x = a little gap to the screen edge)
        return panel, "TOPRIGHT", "TOPRIGHT", -10, rise, underMinimap
    end
    return holder, "TOPRIGHT", "TOPRIGHT", 0, 0, false
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

local function placeNow()
    local f = _G.ObjectiveTrackerFrame
    if not f or not holder or not cfg().enabled then return end
    do
        local c = cfg()
        -- only write what actually changed
        local wantScale = c.scale * ns.db.general.scale
        if math.abs((f:GetScale() or 0) - wantScale) > 0.001 then ns.SetScale(f, wantScale) end
        if math.abs((f:GetAlpha() or 0) - c.alpha) > 0.001 then f:SetAlpha(c.alpha) end
        local rel, point, relPoint, x, y, underMinimap = anchorTarget()
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
            -- Blizzard's own height can be more than the room under the tracker's top. A frame clamped to the
            -- screen is then pushed up to the top edge. Under a top right minimap that hides it: our spot wins
            -- instead. Everywhere else (ultrawide: minimap at the bottom) the push to the top right is the
            -- layout, so the clamp stays (and comes back after a switch from a narrow screen).
            -- (Setting the height does not stick: Blizzard puts its own back and re-anchors = endless loop.)
            if f:IsClampedToScreen() == underMinimap then pcall(f.SetClampedToScreen, f, not underMinimap) end
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
    end
end

-- Blizzard puts the tracker back at its default spot (under the default minimap) after every tracker update,
-- also in combat (ManageFramePositions). The frame is only locked in combat while it holds a protected child
-- (a quest item button): otherwise it is put back right away. A pass after combat always follows: APR does
-- nothing in combat, so its attach to the tracker is redone then.
local function place()
    local f = _G.ObjectiveTrackerFrame
    if not f or not holder or not cfg().enabled then return end
    if InCombatLockdown() then
        ns:AfterCombat("tracker_place", placeNow)
        local ok, protected = pcall(f.IsProtected, f)
        if not ok or protected then return end
    end
    placeNow()
end

function requestPlace()
    if placeQueued then return end
    placeQueued = true
    C_Timer.After(0, function() placeQueued = false; place() end)
end

function TR:RequestPlace() requestPlace() end

-- where the tracker is and why; also kept in the saved variables (ModernUIDB.trackerDebug), readable after /reload
function TR:DebugPlacement()
    local out = {}
    local function add(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end out[#out + 1] = table.concat(t, " ") end
    local f = _G.ObjectiveTrackerFrame
    local function frame(label, fr)
        if not fr then add(label, "none") return end
        local ok, l, r, b, t = pcall(function() return fr:GetLeft(), fr:GetRight(), fr:GetBottom(), fr:GetTop() end)
        add(label, fr:GetName() or "anon", "shown", fr:IsShown(), "lrbt", l, r, b, t, "eff", fr:GetEffectiveScale(), "strata", fr:GetFrameStrata(), fr:GetFrameLevel(), "clamped", fr:IsClampedToScreen())
    end
    add("UIParent", UIParent:GetWidth(), UIParent:GetHeight(), "eff", UIParent:GetEffectiveScale(), "aspect", ns.AspectLabel())
    add("cfg attach", cfg().attach, "height", cfg().height, "scale", cfg().scale, "general", ns.db.general.scale)
    frame("tracker", f)
    if f then
        for i = 1, f:GetNumPoints() do
            local p, rel, rp, x, y = f:GetPoint(i)
            add("  point", i, p, rel and (rel.GetName and rel:GetName() or "anon"), rp, x, y)
        end
    end
    local rel, point, relPoint, x, y = anchorTarget()
    add("wanted", rel and (rel:GetName() or "anon"), point, relPoint, x, y, "rel is holder", rel == holder)
    frame("holder", holder)
    frame("chat right", ns.Chat and ns.Chat.GetRightPanel and ns.Chat:GetRightPanel())
    frame("minimap", ns.Minimap and ns.Minimap.GetFrame and ns.Minimap:GetFrame())
    local state = f and aprState(f)
    add("APR state", state ~= nil, "owns", f and state and aprOwns(f))
    for _, line in ipairs(out) do ns:Print(line) end
    ModernUIDB.trackerDebug = out
end

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
        -- code paths (its own layout runs on every tracker update, e.g. each looted item): put it back
        -- right away. Waiting for the next frame drew it one frame at Blizzard's spot = flicker. In combat
        -- place() does the same unless the frame is locked (see place).
        for _, m in ipairs({ "SetPoint", "ClearAllPoints" }) do
            if type(f[m]) == "function" then
                pcall(hooksecurefunc, f, m, function()
                    if started and not placing and cfg().enabled then
                        reanchors = reanchors + 1
                        xpcall(place, geterrorhandler())
                    end
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
    -- also with the limit off: quests parked earlier come back. APR sets up its route a little after login:
    -- redo the limit once it has settled
    ns:On("PLAYER_ENTERING_WORLD", function()
        requestTrim()
        if not limitMax() then return end
        hookRoute()
        for _, delay in ipairs({ 1, 3, 6 }) do C_Timer.After(delay, requestTrim) end
    end)
    ns:On("PLAYER_LEVEL_UP", requestPlace)
    ns:On("QUEST_LOG_UPDATE", requestSkin)
    ns:On("QUEST_WATCH_LIST_CHANGED", onWatchChanged)
    ns:On("QUEST_REMOVED", requestTrim)
end

function TR:Apply()
    if not ns.db then return end
    if not cfg().enabled then
        if started then ns:Print("Objective tracker takeover disabled: /reload to restore Blizzard's position.") end
        return
    end
    if not started then self:Start() end
    applyLimit()
    place()
end
