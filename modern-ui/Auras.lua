local ADDON, ns = ...
local UI = ns.UI

-- Aura rows on the engine-driven "AuraContainer" frame (12.1 / WoW Forever).
-- On this client the aura lists of other units are not readable from Lua
-- (C_UnitAuras.GetAuraDataByIndex returns nothing), so the engine draws the
-- aura buttons itself: we only declare WHICH auras (filter strings), how many,
-- how they are laid out, and what a button looks like (icon, swipe, stacks,
-- border). Rows wrap and grow on their own, so nothing here needs to know how
-- many auras a unit has.
--
--   ns.Auras.Supported()                 -> true when the client has AuraContainer
--   ns.Auras.Set(owner, field, parent, unit, spec)  create / update owner[field]
--   ns.Auras.Clear(owner, field)         retire it
--
-- spec = { point = { point, relativeTo, relativePoint, x, y }, anchor = "BOTTOMLEFT",
--          growH = "Right"|"Left", growV = "Up"|"Down", rowWidth = px,
--          groups = { { key, filter, max, size, gap, border = {r,g,b}, newLine, cancel }, ... } }
--          (cancel = right-click cancels the aura: only for the player's own buffs)
local A = {}
ns.Auras = A

local supported

function A.Supported()
    if supported ~= nil then return supported end
    supported = false
    pcall(function()
        if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.LoadAddOn
           and not C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer") then
            C_AddOns.LoadAddOn("Blizzard_AuraContainer")
        end
        local probe = CreateFrame("AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
        probe:Hide()
        supported = probe.AddAuraGroup ~= nil and probe.SetUnit ~= nil
    end)
    return supported
end

-- Countdown text of a timer-enabled group: a Font object per size, so the countdown follows the Modern UI font.
local timerFonts = {}
function A.TimerFont(size)
    size = math.max(8, math.floor(size * 0.5))
    local name = "ModernUIAuraTimer" .. size
    local f = timerFonts[size]
    if not f then
        f = CreateFont(name)
        timerFonts[size] = f
    end
    local g = ns.db and ns.db.general
    pcall(f.SetFont, f, g and g.font or STANDARD_TEXT_FONT, size, "OUTLINE")
    return name
end

-- The button initializer: runs once per engine-created button (inside its creation window).
-- Every region is created and styled first, THEN registered with the button (registering runs the
-- engine's display update, which writes text into the font strings: they need a font by then).
local function makeInit(g)
    return function(button)
        -- the engine places the buttons but does not size them
        button:SetSize(g.size, g.size)

        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", -1, 1)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        cd:SetPoint("TOPLEFT", 1, -1)
        cd:SetPoint("BOTTOMRIGHT", -1, 1)
        if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(not g.timer) end
        if g.timer and cd.SetCountdownFont then pcall(cd.SetCountdownFont, cd, A.TimerFont(g.size)) end
        if cd.SetReverse then cd:SetReverse(true) end
        cd:Show()

        local bf = CreateFrame("Frame", nil, button)
        bf:SetAllPoints(button)
        bf:SetFrameLevel(cd:GetFrameLevel() + 1)
        bf:EnableMouse(false)
        local b = g.border or { 0, 0, 0 }
        UI.AddBorder(bf, 1, b[1], b[2], b[3], 1, "OVERLAY")

        local carrier = CreateFrame("Frame", nil, button)
        carrier:SetAllPoints(button)
        carrier:SetFrameLevel(bf:GetFrameLevel() + 2)
        carrier:EnableMouse(false)
        local stack = carrier:CreateFontString(nil, "OVERLAY")
        ns:SetFont(stack, math.max(8, math.floor(g.size * 0.5)), "OUTLINE")
        stack:SetPoint("BOTTOMRIGHT", 1, 0)

        -- engine buttons come click-enabled: on nameplates that would swallow target clicks.
        -- A cancel group (your own buffs) keeps clicks: right-click cancels the buff, like Blizzard's buff frame.
        if g.cancel then
            pcall(button.SetCancelAuraButtons, button, "RightButtonUp")
        else
            pcall(button.SetCancelAuraButtons, button, nil)
            pcall(button.SetMouseClickEnabled, button, false)
        end

        button:SetIcon(icon)
        button:SetDurationCooldown(cd)
        button:SetApplicationCount(stack, {})
    end
end

local function growthDirections(spec)
    local FD = AnchorUtil and AnchorUtil.FlowDirection
    if not FD then return nil, nil end
    return FD[spec.growH or "Right"], FD[spec.growV or "Up"]
end

local function applyFlow(c, spec)
    local setAnchor = c.SetFlowLayoutAnchorPoint or c.SetAuraLayoutAnchorPoint
    if setAnchor then setAnchor(c, spec.anchor or "BOTTOMLEFT") end
    local h, v = growthDirections(spec)
    local setGrowth = c.SetFlowLayoutGrowthDirection or c.SetAuraLayoutGrowthDirection
    if setGrowth and h and v then setGrowth(c, h, v) end
    local setPad = c.SetFlowLayoutPadding or c.SetAuraLayoutPadding
    if setPad then setPad(c, 0, 0, 0, 0) end
    local setRow = c.SetFlowLayoutMaximumLineSize or c.SetAuraLayoutRowWidth
    if setRow then setRow(c, spec.rowWidth) end
end

-- what must be rebuilt when it changes (groups cannot be re-declared, only added)
local function signature(spec)
    local parts = { spec.anchor or "", spec.growH or "", spec.growV or "", tostring(spec.rowWidth or "") }
    for _, g in ipairs(spec.groups) do
        parts[#parts + 1] = table.concat({ g.key, g.filter, g.size, g.gap, tostring(g.newLine), tostring(g.timer), tostring(g.cancel) }, ":")
    end
    return table.concat(parts, "|")
end

local function retire(c)
    if not c then return end
    pcall(function()
        for _, key in ipairs(c.molKeys or {}) do
            if c.SetAuraGroupEnabled then c:SetAuraGroupEnabled(key, false) end
            if c.SetAuraGroupMaxFrameCount then c:SetAuraGroupMaxFrameCount(key, 0) end
        end
        c:Hide()
        c:ClearAllPoints()
    end)
    pcall(c.SetUnit, c, nil)
end

function A.Clear(owner, field)
    retire(owner[field])
    owner[field] = nil
end

local function build(parent, unit, spec)
    local c = CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")
    c:SetSize(1, 1)
    applyFlow(c, spec)
    c.molKeys = {}
    for i, g in ipairs(spec.groups) do
        c:AddAuraGroup(g.key, g.filter, {
            maxFrameCount = 0,   -- switched on with the live setters below (how EllesmereUI declares its groups)
            candidateFilters = {},
            initializeFrame = makeInit(g),
            layout = {
                elementWidth = g.size, elementHeight = g.size,
                elementSpacing = g.gap, lineSpacing = g.gap,
                forceNewLine = g.newLine and true or nil,
                layoutIndex = i,
            },
        })
        c.molKeys[#c.molKeys + 1] = g.key
    end
    return c
end

-- create or update owner[field]; spec == nil removes it
function A.Set(owner, field, parent, unit, spec)
    if not spec or #spec.groups == 0 or not A.Supported() then
        A.Clear(owner, field)
        return nil
    end
    local sig = signature(spec)
    local c = owner[field]
    if c and c.molSig ~= sig then
        retire(c)
        c = nil
    end
    if not c then
        local ok, res = pcall(build, parent, unit, spec)
        if not ok then
            if not A.errored then
                A.errored = true
                ns:Print("aura container failed: " .. tostring(res))
            end
            return nil
        end
        c = res
        c.molSig = sig
        owner[field] = c
    end
    c:ClearAllPoints()
    c:SetPoint(unpack(spec.point))
    -- live group setters: enable, count, layout (the order the engine expects)
    for i, g in ipairs(spec.groups) do
        if g.timer then A.TimerFont(g.size) end   -- refresh the font if the Modern UI font changed
        pcall(function()
            if c.SetAuraGroupEnabled then c:SetAuraGroupEnabled(g.key, true) end
            c:SetAuraGroupMaxFrameCount(g.key, g.max)
            if c.SetAuraGroupLayout then
                c:SetAuraGroupLayout(g.key, {
                    elementWidth = g.size, elementHeight = g.size,
                    elementSpacing = g.gap, lineSpacing = g.gap,
                    forceNewLine = g.newLine and true or nil,
                    layoutIndex = i,
                })
            end
        end)
    end
    -- activation order used by the other aura-container addons on this client:
    -- unit, show, enable, refresh
    pcall(function()
        c:SetUnit(unit)
        c:Show()
        if c.SetEnabled then c:SetEnabled(true) end
        c:UpdateAllAuras()
    end)
    return c
end

-- /mui auratest: bare aura rows to see whether the engine draws anything here.
--   A) on UIParent, left of the screen center: your own buffs AND debuffs (unit "player")
--   B) on the target frame, to its right: the target's buffs AND debuffs
-- A labelled marker is drawn next to each row, so "no squares" can be told apart from "test did not run".
local testOwner = {}
local markers = {}

local function marker(key, parent, text, point, rel, relPoint, x, y)
    local m = markers[key]
    if not m then
        m = CreateFrame("Frame", nil, parent)
        m:SetSize(160, 18)
        m.bg = m:CreateTexture(nil, "BACKGROUND")
        m.bg:SetAllPoints()
        m.bg:SetColorTexture(0, 0, 0, 0.7)
        m.text = m:CreateFontString(nil, "OVERLAY")
        ns:SetFont(m.text, 13, "OUTLINE")
        m.text:SetPoint("CENTER")
        markers[key] = m
    end
    m:SetParent(parent)
    m:ClearAllPoints()
    m:SetPoint(point, rel, relPoint, x, y)
    m.text:SetText(text)
    m:Show()
end

function A.Test(arg)
    if arg == "off" then
        A.Clear(testOwner, "a"); A.Clear(testOwner, "b")
        if testOwner.c then pcall(function() testOwner.c:Hide(); testOwner.c:SetUnit(nil) end); testOwner.c = nil end
        for _, m in pairs(markers) do m:Hide() end
        ns:Print("aura test removed")
        return
    end
    ns:Print("supported=" .. tostring(A.Supported()) .. " inCombat=" .. tostring(InCombatLockdown()))
    local groups = function(size, border)
        return {
            { key = "debuffs", filter = "HARMFUL", max = 8, size = size, gap = 4, border = { 1, 0, 0 } },
            { key = "buffs", filter = "HELPFUL", max = 8, size = size, gap = 4, border = { 0, 1, 0 }, newLine = true },
        }
    end
    local a = A.Set(testOwner, "a", UIParent, "player", {
        point = { "CENTER", UIParent, "CENTER", -300, 0 }, anchor = "TOPLEFT", growH = "Right", growV = "Down",
        rowWidth = 400, groups = groups(36),
    })
    ns:Print("test A created (player buffs / debuffs): " .. tostring(a ~= nil))
    marker("a", UIParent, "TEST A: player auras", "BOTTOMLEFT", UIParent, "CENTER", -300, 10)
    local tf = ns.UnitFrames and ns.UnitFrames.GetFrame and ns.UnitFrames:GetFrame("target")
    if tf then
        local b = A.Set(testOwner, "b", tf, "target", {
            point = { "TOPLEFT", tf, "TOPRIGHT", 10, 0 }, anchor = "TOPLEFT", growH = "Right", growV = "Down",
            rowWidth = 400, groups = groups(36),
        })
        ns:Print("test B created (target buffs / debuffs): " .. tostring(b ~= nil))
        marker("b", tf, "TEST B: target auras", "BOTTOMLEFT", tf, "TOPRIGHT", 10, 4)
    else
        ns:Print("no target frame")
    end
    local function report(label, c)
        if not c then return end
        for _, key in ipairs(c.molKeys or {}) do
            local ok, count = pcall(c.GetAuraGroupFrameCount, c, key)
            local line = label .. " " .. key .. ": frames=" .. tostring(ok and count or "n/a")
            if ok and c.GetAuraGroupFrame then
                local okf, fr = pcall(c.GetAuraGroupFrame, c, key, 1)
                if okf and fr then
                    local function n(v) return (v ~= nil and not (issecretvalue and issecretvalue(v))) and string.format("%.0f", v) or "?" end
                    local okg, w, h = pcall(function() return fr:GetWidth(), fr:GetHeight() end)
                    line = line .. string.format(" first=%sx%s", okg and n(w) or "?", okg and n(h) or "?")
                end
            end
            ns:Print(line)
        end
        local ok, w, h = pcall(function() return c:GetWidth(), c:GetHeight() end)
        if ok then ns:Print(label .. " container size " .. string.format("%.0fx%.0f", w or 0, h or 0)) end
    end
    -- C) the same kind of row built by EllesmereUI's own aura code (if it is loaded): if THIS shows squares
    --    and A does not, the difference is in how Modern UI sets its buttons up
    local EUI = _G.EllesmereUI
    local AK = EUI and EUI.AuraKit
    if AK and AK.CreateContainer and AnchorUtil and AnchorUtil.FlowDirection then
        local FD = AnchorUtil.FlowDirection
        AK.styles = AK.styles or {}
        AK.styles.moltest = AK.styles.moltest or {}
        local okC, resC = pcall(AK.CreateContainer, UIParent, "player", {
            point = { "CENTER", UIParent, "CENTER", 300, 0 },
            layout = { anchorPoint = "TOPLEFT", growthH = FD.Right, growthV = FD.Down, padding = { 0, 0, 0, 0 }, rowWidth = 400 },
            groups = { { key = "moltest", filter = { "HELPFUL" }, maxFrameCount = 8, style = "moltest",
                layout = { elementWidth = 36, elementHeight = 36, elementSpacing = 4, lineSpacing = 4 } } },
        })
        ns:Print("test C (EllesmereUI's aura code, player buffs, right of center): " .. tostring(okC and resC ~= nil)
            .. (okC and "" or (" error: " .. tostring(resC))))
        if okC then testOwner.c = resC end
        marker("c", UIParent, "TEST C: EllesmereUI aura code", "BOTTOMLEFT", UIParent, "CENTER", 300, 10)
    else
        ns:Print("test C skipped: EllesmereUI is not loaded")
    end
    ns:Print("Green = buffs, red = debuffs. '/mui auratest off' removes the test. Report in 2 seconds...")
    C_Timer.After(2, function()
        ns:Print("--- 2 seconds later ---")
        report("A", testOwner.a)
        report("B", testOwner.b)
    end)
end
