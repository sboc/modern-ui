local ADDON, ns = ...

-- Action bar replacement.
-- Strategy: keep Blizzard's own action buttons (so cooldowns, procs, flyouts,
-- drag & drop, tooltips and key bindings keep working through any patch) but
-- re-parent them into our own bar frames, hide Blizzard's bar containers and
-- art, and re-skin the buttons.
local AB = ns:NewModule("actionbars")
ns.ActionBars = AB

local hider = CreateFrame("Frame")
hider:Hide()

-- key = db key; blizzard bar containers are tried in order. bind = binding command prefix (KeyBind.lua).
local DEFS = {
    { id = "bar1", bind = "ACTIONBUTTON", dbKey = 1, prefix = "ActionButton", count = 12, label = "Action Bar 1",
      containers = { "MainActionBar", "MainMenuBar" }, pageable = true },
    { id = "bar2", bind = "MULTIACTIONBAR1BUTTON", dbKey = 2, prefix = "MultiBarBottomLeftButton", count = 12, label = "Action Bar 2",
      containers = { "MultiBarBottomLeft" } },
    { id = "bar3", bind = "MULTIACTIONBAR2BUTTON", dbKey = 3, prefix = "MultiBarBottomRightButton", count = 12, label = "Action Bar 3",
      containers = { "MultiBarBottomRight" } },
    { id = "bar4", bind = "MULTIACTIONBAR3BUTTON", dbKey = 4, prefix = "MultiBarRightButton", count = 12, label = "Action Bar 4",
      containers = { "MultiBarRight" } },
    { id = "bar5", bind = "MULTIACTIONBAR4BUTTON", dbKey = 5, prefix = "MultiBarLeftButton", count = 12, label = "Action Bar 5",
      containers = { "MultiBarLeft" } },
    { id = "bar6", bind = "MULTIACTIONBAR5BUTTON", dbKey = 6, prefix = "MultiBar5Button", count = 12, label = "Action Bar 6",
      containers = { "MultiBar5" } },
    { id = "bar7", bind = "MULTIACTIONBAR6BUTTON", dbKey = 7, prefix = "MultiBar6Button", count = 12, label = "Action Bar 7",
      containers = { "MultiBar6" } },
    { id = "bar8", bind = "MULTIACTIONBAR7BUTTON", dbKey = 8, prefix = "MultiBar7Button", count = 12, label = "Action Bar 8",
      containers = { "MultiBar7" } },
    { id = "petbar", bind = "BONUSACTIONBUTTON", dbKey = "pet", prefix = "PetActionButton", count = 10, label = "Pet Bar", centered = true,
      containers = { "PetActionBar" } },
    { id = "stancebar", bind = "SHAPESHIFTBUTTON", dbKey = "stance", prefix = "StanceButton", count = 10, label = "Stance Bar", centered = true,
      altPrefix = "ShapeshiftButton", containers = { "StanceBar", "ShapeshiftBarFrame" } },
}
AB.defs = DEFS

-- Some client flavors use other global names (e.g. ShapeshiftButton1).
local function getBtn(def, i)
    return _G[def.prefix .. i] or (def.altPrefix and _G[def.altPrefix .. i]) or nil
end

local started = false

local function cfgFor(def)
    local ab = ns.db.actionbars
    if type(def.dbKey) == "number" then return ab.bars[def.dbKey] end
    return ab[def.dbKey]
end

----------------------------------------------------------------------
-- Paging (bar 1): stance / form / vehicle / override bars
----------------------------------------------------------------------
local function pageDriver()
    local override = (GetOverrideBarIndex and GetOverrideBarIndex()) or 18
    local vehicle = (GetVehicleBarIndex and GetVehicleBarIndex()) or 16
    local temp = (GetTempShapeshiftBarIndex and GetTempShapeshiftBarIndex()) or 17
    -- Same order and pages as Blizzard's own bar 1 (WoW Forever pages bar 1 by
    -- stance / form offset for every class: page 6 + offset).
    return table.concat({
        "[overridebar] " .. override,
        "[vehicleui][possessbar] " .. vehicle,
        "[shapeshift] " .. temp,
        "[bar:2] 2", "[bar:3] 3", "[bar:4] 4", "[bar:5] 5", "[bar:6] 6",
        "[bonusbar:5] 11",
        "[bonusbar:4] 10",
        "[bonusbar:3] 9",
        "[bonusbar:2] 8",
        "[bonusbar:1] 7",
        "1",
    }, "; ")
end

local PAGE_SNIPPET = [[
    local page = tonumber(newstate) or 1
    self:SetAttribute("actionpage", page)
    local kids = newtable(self:GetChildren())
    for _, b in ipairs(kids) do
        b:SetAttribute("actionpage", page)
    end
]]

local function refreshButtons(def)
    for i = 1, def.count do
        local b = getBtn(def, i)
        if b then
            local fn = b.UpdateAction or b.Update
            if type(fn) == "function" then pcall(fn, b) end
        end
    end
end

local function setupPaging(bar, def, enable)
    if not def.pageable then return end
    if enable and not bar.molPaging then
        bar.molPaging = true
        bar:SetAttribute("_onstate-page", PAGE_SNIPPET)
        RegisterStateDriver(bar, "page", pageDriver())
        bar:HookScript("OnAttributeChanged", function(_, name)
            if name == "state-page" or name == "actionpage" then
                C_Timer.After(0, function() refreshButtons(def) end)
            end
        end)
    elseif not enable and bar.molPaging then
        bar.molPaging = false
        UnregisterStateDriver(bar, "page")
        bar:SetAttribute("actionpage", 1)
        for i = 1, def.count do
            local b = getBtn(def, i)
            if b then b:SetAttribute("actionpage", 1) end
        end
        refreshButtons(def)
    end
end

----------------------------------------------------------------------
-- Skinning
----------------------------------------------------------------------
local function killTexture(tex)
    if type(tex) ~= "table" or not tex.SetAlpha then return end
    tex:SetAlpha(0)
    if not tex.molKilled then
        tex.molKilled = true
        hooksecurefunc(tex, "Show", function(self) self:SetAlpha(0) end)
        if tex.SetAtlas then hooksecurefunc(tex, "SetAtlas", function(self) self:SetAlpha(0) end) end
    end
end

-- Flat replacements for Blizzard's glowing mouseover / pressed / checked / flash / proc art.
local WHITE = "Interface\\Buttons\\WHITE8X8"
local ACCENT = { 0.30, 0.82, 1.00 }
local PROC = { 1.00, 0.82, 0.20 }

local function flatten(tex, r, g, b, a, btn)
    if type(tex) ~= "table" or not tex.SetTexture then return end
    pcall(function()
        tex:SetTexture(WHITE)
        tex:SetTexCoord(0, 1, 0, 1)
        tex:SetVertexColor(r, g, b, a)
        tex:SetBlendMode("BLEND")
        tex:ClearAllPoints()
        tex:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
        tex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
    end)
end

local function skinHighlights(btn)
    pcall(function()
        if btn.SetHighlightTexture then btn:SetHighlightTexture(WHITE) end
        if btn.SetPushedTexture then btn:SetPushedTexture(WHITE) end
        if btn.SetCheckedTexture then btn:SetCheckedTexture(WHITE) end
    end)
    flatten(btn.GetHighlightTexture and btn:GetHighlightTexture(), 1, 1, 1, 0.16, btn)
    flatten(btn.GetPushedTexture and btn:GetPushedTexture(), 1, 1, 1, 0.30, btn)
    -- checked (auto attack / auto shot / toggled spell) and auto-repeat flash: full-icon washes grey the icon out,
    -- so hide both and mark the checked state with an accent outline instead
    local checkedTex = btn.GetCheckedTexture and btn:GetCheckedTexture()
    killTexture(checkedTex)
    -- pet / stance buttons: Blizzard's update code resets the checked texture's alpha, leaving a solid white
    -- wash over the icon - pin it to 0 and re-assert it whenever the checked state changes
    if type(checkedTex) == "table" and checkedTex.SetAlpha and not checkedTex.molPinned then
        checkedTex.molPinned = true
        pcall(hooksecurefunc, checkedTex, "SetAlpha", function(self, a)
            if a ~= 0 then self:SetAlpha(0) end
        end)
        pcall(hooksecurefunc, checkedTex, "SetVertexColor", function(self) self:SetAlpha(0) end)
        pcall(hooksecurefunc, btn, "SetChecked", function()
            local t = btn:GetCheckedTexture()
            if t then t:SetAlpha(0) end
        end)
    end
    killTexture(btn.Flash)
    if not btn.molChecked and btn.SetChecked then
        local f = CreateFrame("Frame", nil, btn)
        f:SetAllPoints()
        f:SetFrameLevel(btn:GetFrameLevel() + 7)
        f:EnableMouse(false)
        ns.UI.AddBorder(f, 2, ACCENT[1], ACCENT[2], ACCENT[3], 1, "OVERLAY")
        f:Hide()
        btn.molChecked = f
        pcall(hooksecurefunc, btn, "SetChecked", function(self)
            -- read the real state back: callers pass 0 / 1 / nil, and 0 is truthy in Lua
            local on = self:GetChecked()
            f:SetShown(on == true or on == 1)
        end)
        local function sync()
            local on = btn:GetChecked()
            f:SetShown(on == true or on == 1)
        end
        pcall(sync)
        -- SetChecked hooks miss updates once Blizzard's secure button code takes over in combat, so also poll
        local driver, elapsed = CreateFrame("Frame", nil, btn), 0
        driver:SetScript("OnUpdate", function(_, dt)
            elapsed = elapsed + dt
            if elapsed < 0.1 then return end
            elapsed = 0
            sync()
        end)
    end
    -- equipped / new-action / spellbook-hover art
    killTexture(btn.Border)
    killTexture(btn.NewActionTexture)
    killTexture(btn.SpellHighlightTexture)
    killTexture(btn.IconBorder)

    -- cast / target-reticle / interrupt animations: Blizzard's glowing frame art while a spell is being cast
    for _, key in ipairs({ "SpellCastAnimFrame", "TargetReticleAnimFrame", "InterruptDisplay" }) do
        local fr = btn[key]
        if type(fr) == "table" and fr.SetAlpha then
            pcall(function()
                fr:SetAlpha(0)
                if fr.HookScript and not fr.molHidden then
                    fr.molHidden = true
                    fr:HookScript("OnShow", function(self) self:SetAlpha(0) end)
                end
            end)
        end
    end

    -- proc glow: keep the alert frame (Blizzard drives it) but show a plain gold border instead of the animated art
    local alert = btn.SpellActivationAlert
    if type(alert) == "table" and alert.HookScript and not btn.molProc then
        local f = CreateFrame("Frame", nil, btn)
        f:SetAllPoints()
        f:SetFrameLevel(btn:GetFrameLevel() + 8)
        f:EnableMouse(false)
        ns.UI.AddBorder(f, 2, PROC[1], PROC[2], PROC[3], 1, "OVERLAY")
        f:Hide()
        btn.molProc = f
        pcall(function()
            alert:SetAlpha(0)
            alert:HookScript("OnShow", function(self) self:SetAlpha(0); f:Show() end)
            alert:HookScript("OnHide", function() f:Hide() end)
            if alert:IsShown() then f:Show() end
        end)
    end
end

local function skinButton(btn)
    if btn.molSkinned then return end
    btn.molSkinned = true
    local name = btn:GetName() or ""

    local icon = btn.icon or btn.Icon or _G[name .. "Icon"]
    btn.molIcon = icon

    -- Blizzard slot art
    killTexture(btn.SlotArt)
    killTexture(btn.SlotBackground)
    killTexture(btn.NormalTexture)
    killTexture(btn.FloatingBG)
    killTexture(_G[name .. "FloatingBG"])
    killTexture(_G[name .. "NormalTexture"])
    if btn.GetNormalTexture then killTexture(btn:GetNormalTexture()) end
    if icon and btn.IconMask and icon.RemoveMaskTexture then
        pcall(icon.RemoveMaskTexture, icon, btn.IconMask)
    end

    -- pet / stance buttons: older art with different texture names (NormalTexture2, shine...) - hide every
    -- texture that is not the icon or one of the highlight textures we restyle ourselves
    if name:find("^PetActionButton") or name:find("^StanceButton") or name:find("^ShapeshiftButton") then
        pcall(function()
            if type(icon) ~= "table" then return end
            local keep = { [icon] = true }
            for _, getter in ipairs({ "GetHighlightTexture", "GetPushedTexture", "GetCheckedTexture" }) do
                if type(btn[getter]) == "function" then
                    local ok, tex = pcall(btn[getter], btn)
                    if ok and type(tex) == "table" then keep[tex] = true end
                end
            end
            if type(btn.Flash) == "table" then keep[btn.Flash] = true end
            for _, region in ipairs({ btn:GetRegions() }) do
                if type(region) == "table" and not keep[region] and region.GetObjectType
                   and region:GetObjectType() == "Texture" then
                    killTexture(region)
                end
            end
            killTexture(_G[name .. "NormalTexture2"])
        end)
    end

    btn.molBG = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
    btn.molBG:SetAllPoints()
    btn.molBG:SetColorTexture(0.04, 0.04, 0.05, 0.85)

    btn.molBorderFrame = CreateFrame("Frame", nil, btn)
    btn.molBorderFrame:SetAllPoints()
    btn.molBorderFrame:SetFrameLevel(btn:GetFrameLevel() + 5)
    btn.molBorderFrame:EnableMouse(false)
    btn.molBorder = ns.UI.AddBorder(btn.molBorderFrame, 1, 0, 0, 0, 1, "OVERLAY")

    skinHighlights(btn)
end

local function styleButton(btn, cfg, global)
    skinButton(btn)
    local name = btn:GetName() or ""

    if btn.molIcon then
        if global.iconZoom then
            btn.molIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        else
            btn.molIcon:SetTexCoord(0, 1, 0, 1)
        end
        btn.molIcon:ClearAllPoints()
        btn.molIcon:SetPoint("TOPLEFT", 1, -1)
        btn.molIcon:SetPoint("BOTTOMRIGHT", -1, 1)
    end

    btn.molBorderFrame:SetShown(global.borders)
    btn.molBG:SetShown(global.borders)

    local hk = btn.HotKey or _G[name .. "HotKey"]
    if hk then
        hk:SetAlpha(cfg.hotkeys and 1 or 0)
        ns:SetFont(hk, math.max(8, math.floor(cfg.size * 0.28)), "OUTLINE")
        hk:ClearAllPoints()
        hk:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -2, -3)
    end
    local nm = btn.Name or _G[name .. "Name"]
    if nm then
        nm:SetAlpha(cfg.macros and 1 or 0)
        ns:SetFont(nm, math.max(8, math.floor(cfg.size * 0.25)), "OUTLINE")
    end
    local ct = btn.Count or _G[name .. "Count"]
    if ct then
        ct:SetAlpha(cfg.counts and 1 or 0)
        ns:SetFont(ct, math.max(9, math.floor(cfg.size * 0.30)), "OUTLINE")
        ct:ClearAllPoints()
        ct:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
    end
end

----------------------------------------------------------------------
-- Hiding Blizzard bars
----------------------------------------------------------------------
local function hideBlizzardArt()
    -- Pre-11.0 style main bar art, harmless if missing.
    for _, n in ipairs({ "MainMenuBarArtFrame", "MainMenuBarArtFrameBackground", "MainMenuBarLeftEndCap",
                         "MainMenuBarRightEndCap", "MainMenuBarPageNumber", "ActionBarUpButton",
                         "ActionBarDownButton" }) do
        local f = _G[n]
        if f then f:Hide(); f:SetAlpha(0) end
    end
    local main = _G.MainActionBar or _G.MainMenuBar
    if main then
        for _, k in ipairs({ "EndCaps", "BorderArt", "ActionBarPageNumber", "Background" }) do
            local part = main[k]
            if part then part:SetAlpha(0); if part.Hide then part:Hide() end end
        end
    end
end

local function hideContainer(def)
    for _, cname in ipairs(def.containers) do
        local c = _G[cname]
        if c then
            -- Legacy "MainMenuBar" also held the micro menu / bags on old
            -- clients, so never re-parent it; its art is hidden separately.
            if cname ~= "MainMenuBar" then c:SetParent(hider) end
            -- Blizzard re-lays out its buttons from time to time.
            if not c.molHooked then
                c.molHooked = true
                for _, m in ipairs({ "UpdateGridLayout", "Layout", "UpdateShownButtons" }) do
                    if type(c[m]) == "function" then
                        hooksecurefunc(c, m, function() AB:RequestLayout() end)
                    end
                end
            end
            break
        end
    end
end

----------------------------------------------------------------------
-- Bars
----------------------------------------------------------------------
local bars = {}

local function createBar(def)
    local bar = CreateFrame("Frame", "ModernUI" .. def.id, UIParent, "SecureHandlerStateTemplate")
    bar:SetSize(40, 40)
    bar.def = def
    bars[def.id] = bar
    ns.Mover:Register(def.id, bar, def.label)
    return bar
end

-- Bars 1-4 are the core of the layout: always enabled, never faded.
local function isCore(def) return type(def.dbKey) == "number" and def.dbKey <= 4 end

local function layoutBar(def)
    local bar = bars[def.id]
    local cfg = cfgFor(def)
    if isCore(def) then cfg.enabled, cfg.fade = true, false end
    local global = ns.db.actionbars

    bar:SetScale(cfg.scale * ns.db.general.scale)

    local n = math.max(1, math.min(def.count, cfg.buttons))
    -- pet / stance: only the buttons Blizzard currently shows count, so the bar is centered around them
    local sized = n
    if def.centered then
        -- from the game state, not from the buttons: hidden buttons under a hidden bar would read as "none"
        local v = 0
        if def.id == "stancebar" then
            v = (GetNumShapeshiftForms and GetNumShapeshiftForms()) or 0
        else
            v = (PetHasActionBar and PetHasActionBar()) and n or 0
        end
        v = math.min(v, n)
        bar.molActive = v > 0
        sized = math.max(1, v)
    end
    local perRow = math.max(1, math.min(sized, cfg.perRow))
    local rows = math.ceil(sized / perRow)
    local size, gap = cfg.size, cfg.spacing
    bar:SetSize(perRow * size + (perRow - 1) * gap, rows * size + (rows - 1) * gap)

    for i = 1, def.count do
        local btn = getBtn(def, i)
        if btn then
            if i <= n and cfg.enabled then
                if btn:GetParent() ~= bar then btn:SetParent(bar) end
                local col = (i - 1) % perRow
                local row = math.floor((i - 1) / perRow)
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", bar, "TOPLEFT", col * (size + gap), -row * (size + gap))
                btn:SetSize(size, size)
                styleButton(btn, cfg, global)
                if def.id == "petbar" then
                    -- Blizzard hides pet slots that hold no action; the pet bar shows all its slots
                    -- (empty ones as plain dark squares) while it is active
                    if not InCombatLockdown() then btn:Show() end
                    if not btn.molShowHook then
                        btn.molShowHook = true
                        local function reshow(self)
                            if InCombatLockdown() then return end
                            local b = bars.petbar
                            if b and b:IsShown() then
                                C_Timer.After(0, function() if not InCombatLockdown() then self:Show() end end)
                            end
                        end
                        pcall(hooksecurefunc, btn, "Hide", reshow)
                        pcall(hooksecurefunc, btn, "SetShown", function(self, shown) if not shown then reshow(self) end end)
                    end
                end
                if def.centered then
                    -- Blizzard fades empty pet / stance slots to alpha 0 (its "no grid" rule): keep the slot visible
                    pcall(function()
                        btn:SetAlpha(1)
                        if not btn.molAlphaHook then
                            btn.molAlphaHook = true
                            local guard = false
                            hooksecurefunc(btn, "SetAlpha", function(self, a)
                                if guard or a == 1 then return end
                                guard = true
                                self:SetAlpha(1)
                                guard = false
                            end)
                        end
                    end)
                end
            else
                -- unused slots (or whole bar disabled): park them hidden.
                -- Key bindings still reach them through their CLICK binding.
                if btn:GetParent() ~= hider then btn:SetParent(hider) end
            end
        end
    end

    -- pet / stance bars only exist while there is a pet / a stance (always shown while unlocking)
    local wanted = cfg.enabled and (not def.centered or bar.molActive or ns.Mover:IsUnlocked())
    if wanted then bar:Show() else bar:Hide() end
    setupPaging(bar, def, cfg.enabled and cfg.paging)
    ns.Mover:Position(def.id)
end

local layoutQueued = false
function AB:RequestLayout()
    if not started or layoutQueued then return end
    layoutQueued = true
    C_Timer.After(0, function()
        layoutQueued = false
        AB:Apply()
    end)
end

----------------------------------------------------------------------
-- Mouseover fade
----------------------------------------------------------------------
local fader = CreateFrame("Frame")
local acc = 0
fader:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc < 0.03 then return end
    acc = 0
    if not started or not ns.db then return end
    local holding = GetCursorInfo and GetCursorInfo() ~= nil
    local flyout = _G.SpellFlyout and _G.SpellFlyout:IsShown()
    for _, def in ipairs(DEFS) do
        local bar = bars[def.id]
        local cfg = bar and cfgFor(def)
        if cfg and isCore(def) then cfg.enabled, cfg.fade = true, false end
        if bar and cfg and cfg.enabled then
            local target = cfg.alpha
            if cfg.fade and not ns.Mover:IsUnlocked() then
                local over = holding or bar:IsMouseOver() or (flyout and _G.SpellFlyout:IsMouseOver())
                target = over and cfg.alpha or cfg.fadeAlpha
            end
            local cur = bar:GetAlpha()
            if math.abs(cur - target) > 0.01 then
                bar:SetAlpha(cur + (target - cur) * 0.35)
            elseif cur ~= target then
                bar:SetAlpha(target)
            end
        end
    end
end)

----------------------------------------------------------------------
-- Swing timer: countdown to the next auto attack on the Attack button
----------------------------------------------------------------------
-- Addons cannot register for the combat log (blocked as a Blizzard-only action), so the timer is an
-- estimate: one swing when auto attack starts, then repeating every weapon speed. It can drift from
-- the real swings (parries, resets), but needs no protected calls.
local swing = { start = nil, speed = 2, estimated = true }
-- Auto Shot / Shoot (wand): the same countdown on the auto-repeat button. Every shot restarts it
-- (UNIT_SPELLCAST_SUCCEEDED); between those it repeats every ranged weapon speed.
local shot = { start = nil, speed = 2, estimated = true }
local AUTO_REPEAT_SPELLS = { [75] = true, [5019] = true }   -- Auto Shot, Shoot
local swingButtons, shotButtons, countButtons, swingDirty = {}, {}, {}, true
local swingFrame = CreateFrame("Frame")

local function swingEnabled()
    return ns.db and ns.db.actionbars and ns.db.actionbars.swingTimer
end

local function shotEnabled()
    return ns.db and ns.db.actionbars and ns.db.actionbars.rangedTimer
end

-- 12.x returns "secret" numbers from UnitAttackSpeed in some situations (no compare / arithmetic on them,
-- and touching one taints the addon): only clean numbers are ever stored. The fallback is the weapon's
-- own speed from its tooltip, read while not in combat.
local function clean(v)
    if type(v) ~= "number" then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    if v <= 0 then return nil end
    return v
end

local weaponSpeed   -- from the main hand tooltip

local function readWeaponSpeed()
    if InCombatLockdown() then return end
    pcall(function()
        local data = C_TooltipInfo and C_TooltipInfo.GetInventoryItem and C_TooltipInfo.GetInventoryItem("player", 16)
        if not data or not data.lines then return end
        for _, line in ipairs(data.lines) do
            for _, text in ipairs({ line.leftText, line.rightText }) do
                if type(text) == "string" and not (issecretvalue and issecretvalue(text)) then
                    local n = text:match("(%d+[%.,]%d+)")
                    if n and text:lower():find("speed") then
                        local v = clean(tonumber((n:gsub(",", "."))))
                        if v then weaponSpeed = v return end
                    end
                end
            end
        end
    end)
end

local function currentSpeed()
    local ok, v = pcall(UnitAttackSpeed, "player")
    return (ok and clean(v)) or weaponSpeed or swing.speed or 2
end

local function rangedSpeed()
    if not UnitRangedDamage then return shot.speed or 2 end
    local ok, v = pcall(UnitRangedDamage, "player")
    return (ok and clean(v)) or shot.speed or 2
end

local function swingBegin(estimated)
    swing.start = GetTime()
    swing.speed = currentSpeed()
    swing.estimated = estimated
end

local function swingOverlay(btn)
    local o = btn.molSwing
    if o then return o end
    o = CreateFrame("Frame", nil, btn)
    o:SetAllPoints()
    o:SetFrameLevel(btn:GetFrameLevel() + 9)
    o:EnableMouse(false)
    o.bar = o:CreateTexture(nil, "OVERLAY", nil, 6)
    o.bar:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.95)
    o.bar:SetHeight(3)
    o.bar:SetPoint("BOTTOMLEFT", o, "BOTTOMLEFT", 1, 1)
    o.text = o:CreateFontString(nil, "OVERLAY", nil, 7)
    o.text:SetPoint("CENTER", o, "CENTER", 0, 0)
    o.text:SetShadowColor(0, 0, 0, 1)
    o.text:SetShadowOffset(1, -1)
    o:Hide()
    btn.molSwing = o
    return o
end

local function rebuildSwingButtons()
    swingDirty = false
    for _, list in ipairs({ swingButtons, shotButtons, countButtons }) do
        for i = #list, 1, -1 do list[i] = nil end
    end
    for _, def in ipairs(DEFS) do
        if type(def.dbKey) == "number" then
            for i = 1, def.count do
                local btn = getBtn(def, i)
                local slot = btn and (btn.action or (btn.GetAttribute and btn:GetAttribute("action")))
                if btn and slot and btn:IsVisible() then
                    btn.molSlot = slot
                    countButtons[#countButtons + 1] = btn
                    local ok, isAttack = pcall(IsAttackAction or error, slot)
                    local ok2, isRepeat = pcall(IsAutoRepeatAction or error, slot)
                    if ok and isAttack then swingButtons[#swingButtons + 1] = btn
                    elseif ok2 and isRepeat then shotButtons[#shotButtons + 1] = btn end
                end
            end
        end
    end
    -- a button that stopped being the attack / shot button keeps no stale overlay
    for _, btn in ipairs(countButtons) do
        if btn.molSwing then btn.molSwing:Hide() end
        if btn.molAmmo then btn.molAmmo:SetText("") end
    end
end

local function hideSwing(list)
    for _, btn in ipairs(list or swingButtons) do
        if btn.molSwing then btn.molSwing:Hide() end
    end
end

-- seconds until the next swing / shot, nil while the timer is not running
local function remainingOf(timer)
    if not timer.start then return nil end
    local age = GetTime() - timer.start
    if timer.estimated then age = age % timer.speed end
    local remaining = timer.speed - age
    return remaining > 0 and remaining or nil
end

local function drawTimer(timer, list, enabled)
    local remaining = enabled and remainingOf(timer) or nil
    if not remaining then hideSwing(list) return end
    local frac = math.min(1, remaining / timer.speed)
    for _, btn in ipairs(list) do
        local o = swingOverlay(btn)
        local size = btn:GetWidth()
        if not o.fontSize or o.fontSize ~= size then
            o.fontSize = size
            ns:SetFont(o.text, math.max(10, math.floor(size * 0.40)), "OUTLINE")
        end
        o.text:SetText(string.format("%.1f", remaining))
        o.bar:SetWidth(math.max(1, (size - 2) * frac))
        o:Show()
    end
end

----------------------------------------------------------------------
-- Counts: ammunition on the Auto Shot button, and item / reagent counts turn red when low
----------------------------------------------------------------------
local ammoWarned = false

local function ammoCount()
    local ok, slot = pcall(GetInventorySlotInfo, "AmmoSlot")
    if not ok or type(slot) ~= "number" then return nil end
    if not GetInventoryItemID("player", slot) then return nil end
    return clean(GetInventoryItemCount("player", slot))
end

local function updateCounts()
    local ab = ns.db.actionbars
    local low = ab.lowCount or 0
    for _, btn in ipairs(countButtons) do
        local ct = btn.Count or _G[(btn:GetName() or "") .. "Count"]
        if ct then
            local ok, n = pcall(GetActionCount, btn.molSlot)
            n = ok and type(n) == "number" and not (issecretvalue and issecretvalue(n)) and n or nil
            if low > 0 and n and n <= low then ct:SetTextColor(1, 0.3, 0.3) else ct:SetTextColor(1, 1, 1) end
        end
    end
    local ammo = ab.ammoCount and #shotButtons > 0 and ammoCount() or nil
    local warn = ab.ammoWarn or 0
    for _, btn in ipairs(shotButtons) do
        local fs = btn.molAmmo
        if not fs and ammo then
            local o = swingOverlay(btn)
            local holder = CreateFrame("Frame", nil, btn)
            holder:SetAllPoints()
            holder:SetFrameLevel(o:GetFrameLevel())
            holder:EnableMouse(false)
            fs = holder:CreateFontString(nil, "OVERLAY")
            fs:SetPoint("BOTTOMRIGHT", -2, 5)
            btn.molAmmo = fs
        end
        if fs then
            if ammo then
                ns:SetFont(fs, math.max(9, math.floor(btn:GetWidth() * 0.30)), "OUTLINE")
                fs:SetText(ammo)
                if warn > 0 and ammo < warn then fs:SetTextColor(1, 0.3, 0.3) else fs:SetTextColor(1, 1, 1) end
            else
                fs:SetText("")
            end
        end
    end
    if ammo and warn > 0 then
        if ammo >= warn then
            ammoWarned = false
        elseif not ammoWarned then
            ammoWarned = true
            ns:Print(string.format("|cffff4d4dLow ammunition|r: %d left.", ammo))
        end
    end
end

----------------------------------------------------------------------
-- Timer bar: the running swing / shot timer as a thin bar of its own (option; by default it sits in the
-- gap between the Essential and Utility cooldown rows). Fills up towards the next swing / shot.
----------------------------------------------------------------------
local timerBar

local function layoutTimerBar()
    local ab = ns.db.actionbars
    if not ab.swingBar then
        if timerBar then timerBar:Hide() end
        return
    end
    if not timerBar then
        timerBar = CreateFrame("StatusBar", "ModernUISwingBar", UIParent)
        timerBar:SetMinMaxValues(0, 1)
        timerBar.bg = timerBar:CreateTexture(nil, "BACKGROUND")
        timerBar.bg:SetAllPoints()
        timerBar.bg:SetColorTexture(0.03, 0.03, 0.04, 0.9)
        timerBar.borders = ns.UI.AddBorder(timerBar, 1, 0, 0, 0, 1, "OVERLAY")
        timerBar:Hide()
        ns.Mover:Register("swingbar", timerBar, "Swing / Shot Timer Bar")
    end
    timerBar:SetStatusBarTexture(ns:GetTexture())
    timerBar:SetStatusBarColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    timerBar:SetSize(ab.swingBarWidth, ab.swingBarHeight)
    timerBar:SetScale(ns.db.general.scale)
    ns.Mover:Position("swingbar")
end

local function drawTimerBar()
    if not timerBar or not ns.db.actionbars.swingBar then return end
    local timer = remainingOf(shot) and shot or swing
    local remaining = remainingOf(timer)
    if remaining then
        timerBar:SetValue(1 - math.min(1, remaining / timer.speed))
        timerBar:Show()
    elseif ns.Mover:IsUnlocked() then
        timerBar:SetValue(0.6)
        timerBar:Show()
    else
        timerBar:Hide()
    end
end

local countAcc = 0
swingFrame:SetScript("OnUpdate", function(_, elapsed)
    if not started or not ns.db then return end
    if swingDirty then rebuildSwingButtons() end
    drawTimer(swing, swingButtons, swingEnabled())
    drawTimer(shot, shotButtons, shotEnabled())
    drawTimerBar()
    countAcc = countAcc + elapsed
    if countAcc >= 0.5 then
        countAcc = 0
        updateCounts()
    end
end)

local function setupSwingTimer()
    for _, e in ipairs({ "ACTIONBAR_SLOT_CHANGED", "UPDATE_BONUS_ACTIONBAR", "ACTIONBAR_PAGE_CHANGED", "PLAYER_ENTERING_WORLD" }) do
        ns:On(e, function() swingDirty = true end)
    end
    ns:On("PLAYER_ENTER_COMBAT", function() if not swing.start then swingBegin(true) end end)
    ns:On("PLAYER_LEAVE_COMBAT", function() swing.start = nil; hideSwing() end)
    -- haste changes: next swing uses the new speed
    ns:On("UNIT_ATTACK_SPEED", function(_, unit)
        if unit == "player" and swing.start then swing.speed = currentSpeed() end
    end)
    for _, e in ipairs({ "PLAYER_EQUIPMENT_CHANGED", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED" }) do
        ns:On(e, function() C_Timer.After(0.5, readWeaponSpeed) end)
    end
    ns:On("START_AUTOREPEAT_SPELL", function() shot.start, shot.speed = GetTime(), rangedSpeed() end)
    ns:On("STOP_AUTOREPEAT_SPELL", function() shot.start = nil; hideSwing(shotButtons) end)
    ns:On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
        if unit ~= "player" or not shot.start then return end
        if issecretvalue and issecretvalue(spellID) then return end
        if AUTO_REPEAT_SPELLS[spellID] then shot.start, shot.speed = GetTime(), rangedSpeed() end
    end)
end

----------------------------------------------------------------------
-- Module API
----------------------------------------------------------------------
-- The top bar of the center stack (bar 2, or bar 1 when bar 2 is off): the
-- player's cast bar stacks on it.
function AB:GetTopBar()
    if not started or not ns.db then return nil end
    local b2 = ns.db.actionbars.bars[2]
    if b2 and b2.enabled and bars.bar2 then return bars.bar2 end
    return bars.bar1
end

function AB:Init()
    if not ns.db.actionbars.enabled then return end
    self:Start()
end

function AB:Start()
    if started then return end
    if InCombatLockdown() then
        ns:AfterCombat("ab_start", function() AB:Start(); AB:Apply() end)
        return
    end
    started = true
    -- Blizzard only populates bars 2-4 when they are switched on in its own
    -- options; Modern UI's layout needs all four.
    pcall(function()
        if C_ActionBar and C_ActionBar.SetActionBarToggles then
            C_ActionBar.SetActionBarToggles(true, true, true, true, true)
        elseif SetActionBarToggles then
            SetActionBarToggles(true, true, true, true, true)
        end
    end)
    for _, def in ipairs(DEFS) do createBar(def) end
    -- reparent first, then hide containers (buttons must leave them alive)
    for _, def in ipairs(DEFS) do
        local bar = bars[def.id]
        for i = 1, def.count do
            local btn = getBtn(def, i)
            if btn then
                btn:SetParent(bar)
                bar:SetAttribute("actionpage", 1)
                if def.pageable then btn:SetAttribute("actionpage", 1) end
            end
        end
        hideContainer(def)
    end
    hideBlizzardArt()
    for _, e in ipairs({ "UPDATE_SHAPESHIFT_FORMS", "PET_BAR_UPDATE", "UNIT_PET", "PLAYER_REGEN_ENABLED" }) do
        ns:On(e, function() AB:RequestLayout() end)
    end
    ns:On("EDIT_MODE_LAYOUTS_UPDATED", function() AB:RequestLayout() end)
    setupSwingTimer()
    ns:On("PLAYER_ENTERING_WORLD", function() AB:RequestLayout() end)
    ns:On("UPDATE_BONUS_ACTIONBAR", function() if bars.bar1 then C_Timer.After(0, function() refreshButtons(DEFS[1]) end) end end)
end

----------------------------------------------------------------------
-- Auto max rank (classic): swap lower spell ranks on the bars for the highest known rank
----------------------------------------------------------------------
local function spellInfoByIdOrName(x)
    if C_Spell and C_Spell.GetSpellInfo then
        local i = C_Spell.GetSpellInfo(x)
        if i then return i.name, i.spellID end
        return
    end
    local name, _, _, _, _, _, id = GetSpellInfo(x)
    return name, id
end

local function rankOf(id)
    local sub
    if C_Spell and C_Spell.GetSpellSubtext then sub = C_Spell.GetSpellSubtext(id)
    elseif GetSpellSubtext then sub = GetSpellSubtext(id) end
    return sub and tonumber(sub:match("(%d+)"))
end

local function upgradeRanks()
    if not ns.db or not ns.db.actionbars.autoRank then return end
    if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then return end   -- no spell ranks on retail
    if InCombatLockdown() or not GetActionInfo then return end
    local changed = 0
    for slot = 1, 180 do
        local kind, id = GetActionInfo(slot)
        if kind == "spell" and id then
            local name = spellInfoByIdOrName(id)
            if name then
                -- a name lookup resolves to the highest known rank
                local _, best = spellInfoByIdOrName(name)
                local cur, top = rankOf(id), best and rankOf(best)
                if best and best ~= id and cur and top and top > cur then
                    ClearCursor()
                    if C_Spell and C_Spell.PickupSpell then C_Spell.PickupSpell(best) else PickupSpell(best) end
                    if GetCursorInfo() then
                        PlaceAction(slot)
                        changed = changed + 1
                    end
                    ClearCursor()
                end
            end
        end
    end
    if changed > 0 then ns:Print(("Upgraded %d action bar spell(s) to the highest rank."):format(changed)) end
end

function AB:UpgradeRanks()
    ns:AfterCombat("ab_autorank", function() C_Timer.After(0.5, upgradeRanks) end)
end

for _, e in ipairs({ "LEARNED_SPELL_IN_TAB", "SPELLS_CHANGED", "PLAYER_LEVEL_UP", "PLAYER_ENTERING_WORLD" }) do
    ns:On(e, function() AB:UpgradeRanks() end)
end

function AB:Apply()
    if not ns.db then return end
    if not ns.db.actionbars.enabled then
        if started then
            ns:Print("Action bars disabled: /reload to restore the Blizzard bars.")
        end
        for _, bar in pairs(bars) do ns:AfterCombat("ab_hide" .. bar:GetName(), function() bar:Hide() end) end
        return
    end
    if not started then self:Start() end
    if not started then return end
    ns:AfterCombat("ab_apply", function()
        for _, def in ipairs(DEFS) do layoutBar(def) end
        -- both pet and stance bar active: both sit at the same centered spot, so put them side by side
        local pb, sb = bars.petbar, bars.stancebar
        if pb and sb and pb.molActive and sb.molActive and pb:IsShown() and sb:IsShown() then
            local function shift(bar, dx)
                local point, rel, relPoint, x, y = bar:GetPoint(1)
                if point then bar:ClearAllPoints(); bar:SetPoint(point, rel, relPoint, (x or 0) + dx, y or 0) end
            end
            shift(pb, -(pb:GetWidth() / 2 + 3))
            shift(sb, sb:GetWidth() / 2 + 3)
        end
        hideBlizzardArt()
        swingDirty = true
        layoutTimerBar()
        AB:UpgradeRanks()
        if ns.UnitFrames and ns.UnitFrames.RefreshCastAnchor then ns.UnitFrames:RefreshCastAnchor() end
    end)
end
