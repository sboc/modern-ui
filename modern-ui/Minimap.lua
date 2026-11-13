local ADDON, ns = ...
local UI = ns.UI

-- Minimap replacement. The Blizzard Minimap is re-parented out of
-- MinimapCluster into a holder we own (so the cluster layout cannot resize
-- it), masked square or round, and its satellite buttons are re-anchored.
local MM = ns:NewModule("minimap")
ns.Minimap = MM

local MASK_SQUARE, MASK_ROUND = 130937, 186178

local holder
local started = false

local function cfg() return ns.db.minimap end

----------------------------------------------------------------------
-- Satellite buttons (all optional: skipped when this client lacks them)
----------------------------------------------------------------------
local function cluster(key)
    local c = _G.MinimapCluster
    return c and c[key]
end

local SATELLITES = {
    { opt = "showTracking", get = function() return cluster("Tracking") end,
      point = "TOPLEFT", x = -2, y = 2 },
    { opt = "showCalendar", get = function() return _G.GameTimeFrame end,
      point = "TOPRIGHT", x = 2, y = 2 },
    { opt = "showMail", get = function()
          local i = cluster("IndicatorFrame")
          return i and i.MailFrame or _G.MiniMapMailFrame
      end, point = "BOTTOMLEFT", x = -2, y = -2 },
    { opt = "showMail", get = function()
          local i = cluster("IndicatorFrame")
          return i and i.CraftingOrderFrame
      end, point = "BOTTOMLEFT", x = 22, y = -2 },
    { opt = "showDifficulty", get = function() return cluster("InstanceDifficulty") or _G.MiniMapInstanceDifficulty end,
      point = "TOPLEFT", x = 22, y = 2 },
    { opt = "showLanding", get = function() return _G.ExpansionLandingPageMinimapButton end,
      point = "BOTTOMRIGHT", x = 2, y = -2, flyoutKey = "flyoutQueue" },
    { opt = "showQueue", get = function() return _G.QueueStatusButton end,
      point = "BOTTOMRIGHT", x = -26, y = -2, flyoutKey = "flyoutQueue" },
    { opt = "showAddons", get = function() return _G.AddonCompartmentFrame end,
      point = "TOPRIGHT", x = -22, y = 2, flyoutKey = "flyoutAddons" },
}

local function placeSatellites()
    local c = cfg()
    for _, s in ipairs(SATELLITES) do
        local f = s.get()
        -- buttons the flyout collects are positioned by the flyout instead
        if f and not (s.flyoutKey and c.flyout and c[s.flyoutKey]) then
            if c[s.opt] then
                if f:GetParent() ~= _G.Minimap then f:SetParent(_G.Minimap) end
                ns.ClearPoints(f)
                ns.SetPoint(f, s.point, _G.Minimap, s.point, s.x, s.y)
                f:SetFrameStrata("MEDIUM")
                f:SetFrameLevel(_G.Minimap:GetFrameLevel() + 10)
                -- visibility stays Blizzard's (mail only shows with mail, etc.)
            else
                f:Hide()
                if not f.molHideHook then
                    f.molHideHook = true
                    hooksecurefunc(f, "Show", function(self)
                        if not cfg()[s.opt] and not (s.flyoutKey and cfg().flyout and cfg()[s.flyoutKey]) then self:Hide() end
                    end)
                end
            end
        end
    end
end

----------------------------------------------------------------------
-- Button flyout: Blizzard's queue / PvP / landing page buttons and addon
-- minimap buttons (LibDBIcon) are collected into one panel behind a toggle.
----------------------------------------------------------------------
local BLIZZ_COLLECT = { "QueueStatusButton", "MiniMapBattlefieldFrame", "ExpansionLandingPageMinimapButton" }
local RING_TEXTURES = { [136430] = true, [136467] = true }   -- tracking ring, round background

local collected, collectedSet = {}, {}
local flyout, toggle
local launcher   -- Modern UI's own map button (created below), collected like an addon button
local flyQueued = false

local function isAddonButton(f)
    local name = f:GetName()
    if not name then return false end
    if name:find("^LibDBIcon10_") then return true end
    if name:find("MinimapButton") or name:find("MinimapBtn") then return true end
    return false
end

local layoutFlyout   -- forward

local function requestFlyoutLayout()
    if flyQueued then return end
    flyQueued = true
    C_Timer.After(0, function() flyQueued = false; if layoutFlyout then layoutFlyout() end end)
end

local function setupCollected(f)
    if f.molFly then return end
    f.molFly = true
    ns.KillTexture(f.border)
    ns.KillTexture(f.background)
    for _, r in ipairs({ f:GetRegions() }) do
        if type(r) == "table" and r.GetObjectType and r:GetObjectType() == "Texture" then
            local ok, t = pcall(r.GetTexture, r)
            if ok and (RING_TEXTURES[t] or (type(t) == "string" and (t:find("TrackingBorder") or t:find("UI%-Minimap%-Background")))) then
                ns.KillTexture(r)
            end
        end
    end
    pcall(f.RegisterForDrag, f)            -- no dragging around the minimap rim
    f.molBG = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    f.molBG:SetAllPoints()
    f.molBG:SetColorTexture(0.16, 0.16, 0.2, 1)
    -- the round ring highlight is gone with the rest of the ring art: a flat hover glow shows the button is live
    if f.SetHighlightTexture then
        pcall(f.SetHighlightTexture, f, "Interface\\Buttons\\WHITE8X8", "ADD")
        local hl = f.GetHighlightTexture and f:GetHighlightTexture()
        if hl then
            hl:SetAllPoints()
            hl:SetVertexColor(1, 1, 1, 0.25)
        end
    end
    f.molBorderFrame = CreateFrame("Frame", nil, f)
    f.molBorderFrame:SetAllPoints()
    f.molBorderFrame:SetFrameLevel(f:GetFrameLevel() + 5)
    f.molBorderFrame:EnableMouse(false)
    UI.AddBorder(f.molBorderFrame, 1, 0, 0, 0, 1, "OVERLAY")
    -- keep it where the flyout put it
    for _, m in ipairs({ "SetPoint", "SetParent", "Show", "Hide" }) do
        pcall(hooksecurefunc, f, m, function(self)
            if not self.molPlacing then requestFlyoutLayout() end
        end)
    end
end

local function scanButtons()
    local c = cfg()
    if not c.flyout or not flyout then return end
    local function add(f)
        if type(f) == "table" and f.GetName and not collectedSet[f] then
            collectedSet[f] = true
            collected[#collected + 1] = f
            setupCollected(f)
        end
    end
    if c.flyoutQueue then
        for _, n in ipairs(BLIZZ_COLLECT) do add(_G[n]) end
    end
    if c.flyoutAddons then
        add(launcher)
        add(_G.AddonCompartmentFrame)   -- Blizzard's own addon collector joins ours: one button, one panel
        for _, parent in ipairs({ _G.Minimap, _G.MinimapBackdrop, _G.MinimapCluster }) do
            if parent and parent.GetChildren then
                for _, child in ipairs({ parent:GetChildren() }) do
                    if child.IsObjectType and child:IsObjectType("Button") and isAddonButton(child) then add(child) end
                end
            end
        end
    end
    requestFlyoutLayout()
end

layoutFlyout = function()
    local c = cfg()
    if not flyout then return end
    local shown = {}
    if c.flyout then
        for _, b in ipairs(collected) do
            if b:IsShown() then shown[#shown + 1] = b end
        end
    end
    local n = #shown
    local size, gap, pad = c.flyoutSize, 4, 6
    local cols = math.max(1, math.min(math.max(n, 1), c.flyoutColumns))
    local rows = math.max(1, math.ceil(n / cols))
    flyout:SetSize(pad * 2 + cols * size + (cols - 1) * gap, pad * 2 + rows * size + (rows - 1) * gap)

    for i, b in ipairs(shown) do
        b.molPlacing = true
        if b:GetParent() ~= flyout then b:SetParent(flyout) end
        b:SetScale(1)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", flyout, "TOPLEFT", pad + ((i - 1) % cols) * (size + gap),
            -(pad + math.floor((i - 1) / cols) * (size + gap)))
        b:SetSize(size, size)
        -- LibDBIcon pins its buttons to MEDIUM / level 8 with fixed strata / level, which ignores the calls
        -- below: the flyout (HIGH) then sits on top of the buttons and eats every click
        if b.SetFixedFrameStrata then b:SetFixedFrameStrata(false) end
        if b.SetFixedFrameLevel then b:SetFixedFrameLevel(false) end
        b:SetFrameStrata("HIGH")
        -- addon buttons keep their own low frame level (LibDBIcon uses 8): below the flyout they sit under its dark background
        b:SetFrameLevel(flyout:GetFrameLevel() + 2)
        if b.molBorderFrame then b.molBorderFrame:SetFrameLevel(b:GetFrameLevel() + 5) end
        local icon = b.icon or b.Icon
        if icon and icon.ClearAllPoints then
            icon:ClearAllPoints()
            icon:SetPoint("TOPLEFT", 3, -3)
            icon:SetPoint("BOTTOMRIGHT", -3, 3)
            -- addon icons are drawn for a grey ring: make sure nothing dims or greys them here
            icon:SetAlpha(1)
            if icon.SetVertexColor then icon:SetVertexColor(1, 1, 1, 1) end
            if icon.SetDesaturated then icon:SetDesaturated(false) end
            if icon.SetDrawLayer then icon:SetDrawLayer("ARTWORK", 7) end
        end
        b.molPlacing = false
    end

    -- the toggle only exists when there is something to collect; a dot warns
    -- of a queue / battleground invite waiting inside
    toggle:SetShown(c.flyout and n > 0)
    local alert = false
    for _, n2 in ipairs({ "QueueStatusButton", "MiniMapBattlefieldFrame" }) do
        local f = _G[n2]
        if f and collectedSet[f] and f:IsShown() then alert = true end
    end
    toggle.dot:SetShown(alert)
    if (not c.flyout) or n == 0 then flyout:Hide() end
end

local function openFlyout()
    scanButtons()
    layoutFlyout()
    flyout:ClearAllPoints()
    -- beside the minimap: to the right when it fits (default position), else to the left;
    -- aligned with the minimap's bottom edge in the lower half of the screen, its top edge in the upper half
    local cx, cy = holder:GetCenter()
    local right = holder:GetRight() or 0
    local fits = right + 4 + flyout:GetWidth() <= UIParent:GetRight()
    local upper = cy and cy > UIParent:GetHeight() / 2
    if fits then
        if upper then flyout:SetPoint("TOPLEFT", holder, "TOPRIGHT", 4, 0)
        else flyout:SetPoint("BOTTOMLEFT", holder, "BOTTOMRIGHT", 4, 0) end
    else
        if upper then flyout:SetPoint("TOPRIGHT", holder, "TOPLEFT", -4, 0)
        else flyout:SetPoint("BOTTOMRIGHT", holder, "BOTTOMLEFT", -4, 0) end
    end
    flyout:Show()
end

local function createFlyout()
    toggle = UI.Button(holder, "+", 18, 18, function()
        if flyout:IsShown() then flyout:Hide() else openFlyout() end
    end)
    toggle:SetFrameLevel(holder:GetFrameLevel() + 40)
    toggle:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -3, 3)
    toggle.dot = toggle:CreateTexture(nil, "OVERLAY")
    toggle.dot:SetColorTexture(1, 0.82, 0.1, 1)
    toggle.dot:SetSize(7, 7)
    toggle.dot:SetPoint("TOPRIGHT", toggle, "TOPRIGHT", 2, 2)
    toggle.dot:Hide()
    toggle:Hide()

    flyout = UI.Box(holder, { 0.1, 0.1, 0.13, 0.97 })
    flyout:SetFrameStrata("HIGH")
    flyout:SetClampedToScreen(true)
    flyout:EnableMouse(true)
    flyout:Hide()
    -- close when the mouse has been away for a moment
    local away = 0
    flyout:SetScript("OnUpdate", function(self, e)
        if self:IsMouseOver() or toggle:IsMouseOver() then away = 0 return end
        away = away + e
        if away > 0.6 then self:Hide() end
    end)
    flyout:SetScript("OnShow", function() away = 0 end)
end

----------------------------------------------------------------------
-- Modern UI launcher: a small button on the map rim. Left-click opens the
-- settings, right-click reloads the UI, dragging slides it round the rim.
----------------------------------------------------------------------
local function placeLauncher()
    if not launcher then return end
    local c = cfg()
    -- collected into the flyout: the flyout lays it out
    if c.flyout and c.flyoutAddons then return end
    launcher.molPlacing = true
    if launcher:GetParent() ~= holder then
        launcher:SetParent(holder)
        launcher:SetSize(24, 24)
        launcher:SetFrameStrata(holder:GetFrameStrata())
        launcher:SetFrameLevel(holder:GetFrameLevel() + 45)
        launcher:RegisterForDrag("LeftButton")
    end
    local rad = math.rad(c.buttonAngle or 180)
    local dx, dy = math.cos(rad), math.sin(rad)
    local half = holder:GetWidth() / 2
    if c.shape ~= "round" then
        local m = math.max(math.abs(dx), math.abs(dy))
        dx, dy = dx / m, dy / m
    end
    launcher:ClearAllPoints()
    launcher:SetPoint("CENTER", holder, "CENTER", dx * half, dy * half)
    launcher.molPlacing = false
end

local function createLauncher()
    launcher = CreateFrame("Button", "ModernUILauncher", holder)
    launcher:SetSize(24, 24)
    launcher:SetFrameLevel(holder:GetFrameLevel() + 45)
    -- background, border and hover glow come from setupCollected (same look as the other buttons)
    launcher.icon = launcher:CreateTexture(nil, "ARTWORK")
    launcher.icon:SetPoint("TOPLEFT", 3, -3)
    launcher.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    launcher.icon:SetTexture("Interface\\AddOns\\modern-ui\\media\\icon.tga")
    setupCollected(launcher)

    launcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    launcher:SetScript("OnClick", function(_, button)
        if button == "RightButton" then ReloadUI() else ns.Config:Toggle() end
    end)

    launcher:RegisterForDrag("LeftButton")
    launcher:SetScript("OnDragStart", function(self)
        if cfg().flyout and cfg().flyoutAddons then return end   -- collected: no rim dragging
        self:SetScript("OnUpdate", function()
            local cx, cy = holder:GetCenter()
            local scale = holder:GetEffectiveScale()
            local mx, my = GetCursorPosition()
            cfg().buttonAngle = math.deg(math.atan2(my / scale - cy, mx / scale - cx)) % 360
            placeLauncher()
        end)
    end)
    launcher:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    launcher:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Modern UI")
        GameTooltip:AddLine("Left-click: settings", 1, 1, 1)
        GameTooltip:AddLine("Right-click: reload UI", 1, 1, 1)
        GameTooltip:AddLine("Drag: move around the map", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    launcher:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

----------------------------------------------------------------------
-- Zone text + clock
----------------------------------------------------------------------
local function zoneColor()
    local pvp = GetZonePVPInfo and GetZonePVPInfo()
    if pvp == "sanctuary" then return 0.41, 0.8, 0.94
    elseif pvp == "arena" or pvp == "hostile" then return 1, 0.1, 0.1
    elseif pvp == "friendly" then return 0.1, 1, 0.1
    elseif pvp == "contested" then return 1, 0.7, 0
    end
    return 1, 0.82, 0
end

local function updateZone()
    if not holder or not holder.zone then return end
    local text = GetMinimapZoneText and GetMinimapZoneText() or ""
    holder.zone:SetText(text)
    holder.zone:SetTextColor(zoneColor())
end

local function updateClock()
    if not holder or not holder.clock then return end
    local c = cfg()
    local h, m
    if c.serverTime then
        h, m = GetGameTime()
    else
        local t = date("*t")
        h, m = t.hour, t.min
    end
    if c.clock24 then
        holder.clock:SetText(string.format("%02d:%02d", h, m))
    else
        local suffix = h >= 12 and "pm" or "am"
        h = h % 12
        if h == 0 then h = 12 end
        holder.clock:SetText(string.format("%d:%02d %s", h, m, suffix))
    end
end

----------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------
local function adopt()
    local mm = _G.Minimap
    if not mm then return end
    if mm:GetParent() ~= holder then mm:SetParent(holder) end
    if not mm.molGuard then
        mm.molGuard = true
        -- Blizzard re-parents the minimap on some transitions: put it back.
        hooksecurefunc(mm, "SetParent", function()
            if started and mm:GetParent() ~= holder then
                ns:AfterCombat("mm_reparent", function()
                    if mm:GetParent() ~= holder then mm:SetParent(holder) end
                end)
            end
        end)
        mm:EnableMouseWheel(true)
        mm:SetScript("OnMouseWheel", function(self, delta)
            if not cfg().mouseZoom then return end
            local z = self:GetZoom() + (delta > 0 and 1 or -1)
            local max = (self.GetZoomLevels and self:GetZoomLevels() or 6) - 1
            self:SetZoom(math.max(0, math.min(max, z)))
        end)
    end
    -- Blizzard's satellites (instance difficulty, mail, crafting orders) call self:GetParent():Layout()
    -- when they update (zoning). Re-parented to the Minimap they would hit a nil method: give it a no-op.
    if not mm.Layout then mm.Layout = function() end end
    local cl = _G.MinimapCluster
    if cl then
        cl:SetAlpha(0)
        cl:EnableMouse(false)
    end
end

-- Blizzard's round frame art: ring, header bar, compass, N tag, clock button,
-- zoom buttons. Hidden with alpha + a Show hook (they re-show on rotate etc.);
-- MinimapBackdrop itself must stay shown (the compass lives on it).
local DECOR = { "MinimapBorder", "MinimapBorderTop", "MinimapNorthTag", "MinimapCompassTexture",
                "MinimapCompassTextureUnderlay", "MinimapZoomIn", "MinimapZoomOut", "TimeManagerClockButton",
                "MiniMapWorldMapButton" }

local function hideDecorations()
    for _, name in ipairs(DECOR) do ns.KillTexture(_G[name]) end
    local mm = _G.Minimap
    if mm then
        ns.KillTexture(mm.ZoomIn)
        ns.KillTexture(mm.ZoomOut)
    end
    local cl = _G.MinimapCluster
    if cl then
        ns.KillTexture(cl.BorderTop)
        ns.KillTexture(cl.ZoneTextButton)
    end
end

-- The map texture keeps rendering at its old size (black strip on the right / bottom)
-- until the zoom changes, so nudge the zoom once and put it back.
local function refreshMap()
    local mm = _G.Minimap
    if not (mm and mm.GetZoom and mm.SetZoom) then return end
    pcall(function()
        local z = mm:GetZoom()
        local max = (mm.GetZoomLevels and mm:GetZoomLevels() or 6) - 1
        mm:SetZoom(z > 0 and z - 1 or math.min(max, z + 1))
        mm:SetZoom(z)
    end)
end

local function create()
    holder = CreateFrame("Frame", "ModernUI_Minimap", UIParent)
    holder:SetSize(160, 160)
    ns.Mover:Register("minimap", holder, "Minimap")

    holder.bg = holder:CreateTexture(nil, "BACKGROUND")
    holder.bg:SetAllPoints()
    holder.bg:SetColorTexture(0.03, 0.03, 0.04, 1)
    holder.borderFrame = CreateFrame("Frame", nil, holder)
    holder.borderFrame:SetAllPoints()
    holder.borderFrame:SetFrameLevel(holder:GetFrameLevel() + 20)
    holder.borders = UI.AddBorder(holder.borderFrame, 1, 0, 0, 0, 1, "OVERLAY")

    -- round shape: a ring + disc behind the map, cut with the round mask
    holder.ring = holder:CreateTexture(nil, "BACKGROUND", nil, -7)
    holder.ring:SetColorTexture(0, 0, 0, 1)
    holder.ringMask = holder:CreateMaskTexture()
    holder.ringMask:SetTexture(MASK_ROUND, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    holder.ringMask:SetAllPoints(holder.ring)
    holder.ring:AddMaskTexture(holder.ringMask)

    -- text lives on its own frame: the Minimap is a child frame and would draw over text on the holder
    holder.textFrame = CreateFrame("Frame", nil, holder)
    holder.textFrame:SetAllPoints()
    holder.textFrame:SetFrameLevel(holder:GetFrameLevel() + 30)
    holder.textFrame:EnableMouse(false)
    holder.zone = holder.textFrame:CreateFontString(nil, "OVERLAY")
    holder.zone:SetPoint("TOP", holder, "TOP", 0, -5)
    holder.zone:SetWidth(holder:GetWidth() - 10)
    holder.zone:SetWordWrap(false)
    holder.zone:SetAlpha(0.8)
    holder.zone:SetShadowColor(0, 0, 0, 0.9)
    holder.zone:SetShadowOffset(1, -1)
    holder.clock = holder.textFrame:CreateFontString(nil, "OVERLAY")
    holder.clock:SetPoint("BOTTOM", holder, "BOTTOM", 0, 5)
    holder.clock:SetAlpha(0.8)
    holder.clock:SetShadowColor(0, 0, 0, 0.9)
    holder.clock:SetShadowOffset(1, -1)

    createFlyout()
    createLauncher()

    local tick = CreateFrame("Frame", nil, holder)
    local acc = 1
    tick:SetScript("OnUpdate", function(_, e)
        acc = acc + e
        if acc >= 1 then acc = 0; updateClock() end
    end)
    for _, e in ipairs({ "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" }) do
        ns:On(e, updateZone)
    end
end

-- /mui flyout: opens the flyout, then 5 seconds later lists every collected button's state and what is under the mouse
function MM:DebugFlyout()
    if not flyout then ns:Print("flyout not created") return end
    openFlyout()
    ns:Print("Flyout open: hover a button in it now (5 seconds)...")
    C_Timer.After(5, function()
        ns:Print(string.format("flyout: shown=%s strata=%s level=%d mouse=%s alpha=%.2f eff=%.2f",
            tostring(flyout:IsShown()), flyout:GetFrameStrata(), flyout:GetFrameLevel(), tostring(flyout:IsMouseEnabled()),
            flyout:GetAlpha(), flyout:GetEffectiveAlpha()))
        for _, b in ipairs(collected) do
            local par = b:GetParent()
            ns:Print(string.format("%s: shown=%s parent=%s strata=%s level=%d mouse=%s alpha=%.2f eff=%.2f size=%dx%d prot=%s",
                b:GetName() or "?", tostring(b:IsShown()), par and par:GetName() or tostring(par), b:GetFrameStrata(),
                b:GetFrameLevel(), tostring(b:IsMouseEnabled()), b:GetAlpha(), b:GetEffectiveAlpha(),
                b:GetWidth(), b:GetHeight(), tostring(b:IsProtected())))
        end
        local f
        if GetMouseFoci then f = GetMouseFoci()[1] elseif GetMouseFocus then f = GetMouseFocus() end
        local chain, depth = {}, 0
        while f and depth < 8 do
            chain[#chain + 1] = (f.GetName and f:GetName()) or tostring(f:GetObjectType())
            f = f.GetParent and f:GetParent() or nil
            depth = depth + 1
        end
        ns:Print("under mouse: " .. (#chain > 0 and table.concat(chain, " < ") or "nothing"))
    end)
end

function MM:Init()
    if not ns.db.minimap.enabled then return end
    self:Start()
end

function MM:Start()
    if started then return end
    started = true
    if not _G.GameTimeFrame and C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "Blizzard_TimeManager")
    end
    create()
    -- addons create their minimap buttons a little after login
    ns:On("PLAYER_ENTERING_WORLD", function()
        C_Timer.After(1, function() hideDecorations(); refreshMap() end)
        for _, t in ipairs({ 1, 3, 6, 12 }) do C_Timer.After(t, scanButtons) end
    end)
    ns:On("ADDON_LOADED", function() C_Timer.After(1, scanButtons) end)
    ns:On("UPDATE_BATTLEFIELD_STATUS", requestFlyoutLayout)
    ns:On("LFG_UPDATE", requestFlyoutLayout)
    ns:On("LFG_QUEUE_STATUS_UPDATE", requestFlyoutLayout)
end

function MM:Apply()
    if not ns.db then return end
    local c = cfg()
    if not c.enabled then
        if started then ns:Print("Minimap disabled: /reload to restore the Blizzard minimap.") end
        return
    end
    if not started then self:Start() end
    ns:AfterCombat("mm_apply", function()
        local mm = _G.Minimap
        if not mm then return end
        local size = c.size
        local round = (c.shape == "round")

        holder:SetScale(c.scale * ns.db.general.scale)
        holder:SetSize(size, size)
        holder:SetAlpha(c.alpha)
        holder.bg:SetShown(not round)
        holder.borderFrame:SetShown(c.borders and not round)
        holder.ring:ClearAllPoints()
        holder.ring:SetPoint("TOPLEFT", holder, "TOPLEFT", -2, 2)
        holder.ring:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 2, -2)
        holder.ring:SetShown(round and c.borders)

        -- deferred: avoids tainting the secure map-open path (see Blizzard's pin data providers)
        C_Timer.After(0, function()
            if InCombatLockdown() then return end
            adopt()
            mm:SetScale(1)
            mm:ClearAllPoints()
            mm:SetPoint("CENTER", holder, "CENTER", 0, 0)
            mm:SetSize(size - (round and 0 or 2), size - (round and 0 or 2))
            mm:SetMaskTexture(round and MASK_ROUND or MASK_SQUARE)
            if mm.SetArchBlobRingScalar then mm:SetArchBlobRingScalar(round and 1 or 0) end
            if mm.SetQuestBlobRingScalar then mm:SetQuestBlobRingScalar(round and 1 or 0) end
            placeSatellites()
            hideDecorations()
            scanButtons()
            refreshMap()
            C_Timer.After(0.5, refreshMap)
            C_Timer.After(2, refreshMap)
        end)

        ns:SetFont(holder.zone, math.max(9, ns.db.general.fontSize - 2), "")
        ns:SetFont(holder.clock, math.max(9, ns.db.general.fontSize - 2), "")
        holder.zone:SetWidth(size - 10)
        launcher:SetShown(c.showButton)
        placeLauncher()
        holder.zone:SetShown(c.zoneText)
        holder.clock:SetShown(c.clock)
        updateZone()
        updateClock()
        ns.Mover:Position("minimap")
    end)
end
