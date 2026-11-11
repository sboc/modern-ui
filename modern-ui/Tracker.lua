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
-- Blizzard's quest modules build the list of quests to draw in BuildQuestWatchInfos: the list is cut to the
-- configured count there (the quests stay tracked, they are just not drawn). The super tracked quest is always
-- kept. With an Azeroth Pilot Reloaded route running, the quests the route reaches next are the ones kept. Only hooked once a limit is set; 0 hands the full list back.
local LIMIT_MODULES = { "CampaignQuestObjectiveTracker", "QuestObjectiveTracker" }   -- in drawing order
local limitState = {}
local lastLimit = 0

local function limitMax()
    local n = cfg().maxQuests or 0
    return n > 0 and n or nil
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

-- The quests allowed in the tracker when a route runs: the super tracked quest, then the watched quests in the
-- order the route reaches them, then the rest in Blizzard's watch order. nil = no route, use the plain cut.
local function routeAllowed(max)
    if not (C_QuestLog and C_QuestLog.GetNumQuestWatches and C_QuestLog.GetQuestIDForQuestWatchIndex) then return end
    local ranks = routeRanks()
    if not ranks then return end
    local sup = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID() or 0
    local list = {}
    for i = 1, C_QuestLog.GetNumQuestWatches() or 0 do
        local id = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
        if id then
            local rank = (id == sup and 0) or ranks[id] or (1e6 + i)
            list[#list + 1] = { id = id, rank = rank, order = i }
        end
    end
    if #list == 0 then return end
    table.sort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.order < b.order
    end)
    local allowed = {}
    for i = 1, math.min(max, #list) do allowed[list[i].id] = true end
    return allowed
end

local drawnSig   -- what the last cut kept ("plain" without a route): a rebuild is only worth it when this changes

local function allowedSig(allowed)
    if not allowed then return "plain" end
    local ids = {}
    for id in pairs(allowed) do ids[#ids + 1] = id end
    table.sort(ids)
    return table.concat(ids, ",")
end

local function limitInfos(tracker, infos)
    local max = limitMax()
    local state = limitState[tracker]
    if not (max and type(infos) == "table") then
        if state then state.shown = #(infos or {}) end
        return infos
    end
    local allowed = routeAllowed(max)
    state.mode = allowed and "route" or "plain"
    drawnSig = allowedSig(allowed)
    if allowed then
        local out = {}
        for _, info in ipairs(infos) do
            if info.quest and allowed[info.quest:GetID()] then out[#out + 1] = info end
        end
        state.shown = #out
        return out
    end
    -- quests already drawn by the modules before this one share the same budget
    local used = 0
    for _, name in ipairs(LIMIT_MODULES) do
        local t = _G[name]
        if t == tracker then break end
        local st = t and limitState[t]
        used = used + (st and st.shown or 0)
    end
    local budget = math.max(0, max - used)
    if #infos <= budget then state.shown = #infos return infos end
    local keep, n = {}, 0
    local sup = budget > 0 and C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
    if sup and sup ~= 0 then
        for i, info in ipairs(infos) do
            if info.quest and info.quest:GetID() == sup then keep[i] = true; n = 1; break end
        end
    end
    for i = 1, #infos do
        if n >= budget then break end
        if not keep[i] then keep[i] = true; n = n + 1 end
    end
    local out = {}
    for i, info in ipairs(infos) do
        if keep[i] then out[#out + 1] = info end
    end
    state.shown = #out
    return out
end

local function markLimitDirty(onlyIfChanged)
    ns:AfterCombat("tracker_limit", function()
        if onlyIfChanged then
            -- every rebuild resizes the tracker (and APR re-attaches to it): skip it when the same quests stay
            local max = limitMax()
            local ok, allowed = pcall(routeAllowed, max or 0)
            if max and ok and allowedSig(allowed) == drawnSig then return end
        end
        for _, name in ipairs(LIMIT_MODULES) do
            local t = _G[name]
            if t and limitState[t] and t.MarkDirty then pcall(t.MarkDirty, t) end
        end
    end)
end

-- the route moved on: the quests that are next change, so the cut has to be redone
local aprHooked = false
local function hookRoute()
    local apr = _G.APR
    if aprHooked or not (apr and type(apr.SetRouteProgress) == "function") then return end
    aprHooked = true
    hooksecurefunc(apr, "SetRouteProgress", function()
        if limitMax() then C_Timer.After(0, function() markLimitDirty(true) end) end
    end)
end

-- /mui tracker: what the route based cut sees and picks (errors are shown, not swallowed)
function TR:Debug()
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
    for i = 1, (C_QuestLog and C_QuestLog.GetNumQuestWatches and C_QuestLog.GetNumQuestWatches() or 0) do
        local id = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
        ns:Print(string.format("  watch %d: %s (%s) route step %s", i, tostring(id),
            tostring(id and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)),
            tostring(ranks and id and ranks[id])))
    end
    for _, name in ipairs(LIMIT_MODULES) do
        local t = _G[name]
        local st = t and limitState[t]
        ns:Print(string.format("%s: exists=%s wrapped=%s mode=%s calls=%s in=%s shown=%s err=%s", name, tostring(t ~= nil),
            tostring(st ~= nil), tostring(st and st.mode), tostring(st and st.calls), tostring(st and st.lastIn), tostring(st and st.shown),
            tostring(st and st.lastErr)))
    end
    local max = limitMax()
    if not max then return end
    local ok2, allowed = pcall(routeAllowed, max)
    if not ok2 then ns:Print("routeAllowed error: " .. tostring(allowed)) return end
    local ids = {}
    for id in pairs(allowed or {}) do ids[#ids + 1] = id end
    ns:Print("allowed: " .. (allowed and table.concat(ids, ", ") or "nil (plain cut)"))
end

local function applyLimit()
    local max = limitMax() or 0
    if max > 0 then hookRoute() end
    for _, name in ipairs(LIMIT_MODULES) do
        local t = _G[name]
        if t and type(t.BuildQuestWatchInfos) == "function" and not limitState[t] and max > 0 then
            local state = { original = t.BuildQuestWatchInfos, shown = 0, calls = 0 }
            limitState[t] = state
            t.BuildQuestWatchInfos = function(self, ...)
                local infos = state.original(self, ...)
                local ok, out = pcall(limitInfos, self, infos)
                state.calls = state.calls + 1
                state.lastIn = type(infos) == "table" and #infos or tostring(infos)
                state.lastErr = (not ok) and tostring(out) or nil
                return ok and out or infos
            end
        end
    end
    if max == lastLimit then return end
    lastLimit = max
    markLimitDirty()
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
        -- code paths (its own layout runs on every tracker update, e.g. each looted item): put it back
        -- right away. Waiting for the next frame drew it one frame at Blizzard's spot = flicker. In combat
        -- place() still queues itself until combat ends.
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
    -- APR sets up its route after Blizzard drew the tracker the first time: redo the cut once it has settled
    ns:On("PLAYER_ENTERING_WORLD", function()
        if not limitMax() then return end
        hookRoute()
        for _, delay in ipairs({ 1, 3, 6 }) do C_Timer.After(delay, function() markLimitDirty(true) end) end
    end)
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
    applyLimit()
    place()
end
