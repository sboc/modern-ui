local ADDON, ns = ...

-- Micro menu (game menu buttons) and bag bar replacement.
-- Same approach as the action bars: Blizzard's own buttons are re-parented
-- into our bar frames and re-skinned, so their behaviour (tooltips, flashing
-- notifications, bag item drag/drop, ...) stays Blizzard-maintained.
local MB = ns:NewModule("menubars")
ns.MenuBars = MB

local hider = CreateFrame("Frame")
hider:Hide()

local MICRO_FALLBACK = {
    "CharacterMicroButton", "ProfessionMicroButton", "PlayerSpellsMicroButton", "SpellbookMicroButton",
    "TalentMicroButton", "AchievementMicroButton", "QuestLogMicroButton", "HousingMicroButton",
    "GuildMicroButton", "SocialsMicroButton", "LFDMicroButton", "LFGMicroButton", "CollectionsMicroButton",
    "EJMicroButton", "WorldMapMicroButton", "StoreMicroButton", "MainMenuMicroButton", "HelpMicroButton",
}

local DEFS = {
    { id = "menu_micro", dbKey = "micro", label = "Micro Menu",
      containers = { "MicroMenuContainer", "MicroMenu" },
      names = function() return _G.MICRO_BUTTONS or MICRO_FALLBACK end },
    { id = "menu_bags", dbKey = "bags", label = "Bags",
      containers = { "BagsBar" },
      hide = { "BagBarExpandToggle" },
      bag = true,
      names = function()
          return { "MainMenuBarBackpackButton", "CharacterBag0Slot", "CharacterBag1Slot",
                   "CharacterBag2Slot", "CharacterBag3Slot", "CharacterReagentBag0Slot" }
      end },
}
MB.defs = DEFS

local bars = {}

-- Buttons whose feature this client does not ship are hidden automatically. A micro button opens a
-- Blizzard UI addon (or needs a service); when that is missing there is nothing for the button to open.
local FEATURE_ADDON = {
    HousingMicroButton = "Blizzard_HousingDashboard",
    AchievementMicroButton = "Blizzard_AchievementUI",
    CollectionsMicroButton = "Blizzard_Collections",
    EJMicroButton = "Blizzard_EncounterJournal",
    ProfessionMicroButton = "Blizzard_Professions",
}

local function autoIrrelevant(name)
    if name == "StoreMicroButton" then
        local sp = _G.C_StorePublic
        if sp and sp.IsEnabled then
            local ok, on = pcall(sp.IsEnabled)
            if ok and not on then return true end
        end
        return false
    end
    local addon = FEATURE_ADDON[name]
    local api = _G.C_AddOns
    if addon and api and api.DoesAddOnExist then
        local ok, exists = pcall(api.DoesAddOnExist, addon)
        if ok and not exists then return true end
    end
    return false
end

-- explicit setting wins (true = hidden, false = shown); nothing set = automatic
function MB.IsButtonHidden(name)
    local h = ns.db and ns.db.menus.micro.hidden
    local v = h and h[name]
    if v ~= nil then return v end
    return autoIrrelevant(name)
end

local function cfgFor(def) return ns.db.menus[def.dbKey] end

local function buttonsFor(def)
    local list = {}
    local seen = {}
    for _, name in ipairs(def.names()) do
        local b = type(name) == "string" and _G[name] or nil
        if b and not seen[b] then
            seen[b] = true
            list[#list + 1] = b
        end
    end
    return list
end

local function killTexture(tex)
    if type(tex) ~= "table" or not tex.SetAlpha then return end
    tex:SetAlpha(0)
    if not tex.molKilled then
        tex.molKilled = true
        pcall(hooksecurefunc, tex, "Show", function(self) self:SetAlpha(0) end)
        pcall(hooksecurefunc, tex, "SetShown", function(self) self:SetAlpha(0) end)
        pcall(hooksecurefunc, tex, "SetAlpha", function(self, a)
            if a ~= 0 and not self.molFix then
                self.molFix = true
                self:SetAlpha(0)
                self.molFix = nil
            end
        end)
        if tex.SetAtlas then pcall(hooksecurefunc, tex, "SetAtlas", function(self) self:SetAlpha(0) end) end
    end
end

----------------------------------------------------------------------
-- Skin
----------------------------------------------------------------------
local function skinButton(btn, def)
    if btn.molSkinned then return end
    btn.molSkinned = true
    local name = btn:GetName() or ""

    -- micro button backdrop art
    killTexture(btn.Background)
    killTexture(btn.PushedBackground)
    killTexture(btn.FlashBorder)
    -- bag slot art
    killTexture(btn.NormalTexture)
    killTexture(btn.IconBorder)
    killTexture(btn.SlotHighlightTexture)
    killTexture(_G[name .. "NormalTexture"])
    if def.bag then
        local icon = btn.icon or btn.Icon or _G[name .. "IconTexture"]
        btn.molIcon = icon
        for _, m in ipairs({ "CircleMask", "IconMask" }) do
            if icon and btn[m] and icon.RemoveMaskTexture then pcall(icon.RemoveMaskTexture, icon, btn[m]) end
        end
    end

    -- bag slots carry several Blizzard background / border textures (names differ between clients):
    -- everything except the item icon goes
    if def.bag then
        pcall(function()
            local icon = btn.molIcon
            if type(icon) ~= "table" then return end   -- cannot tell the icon from the art: leave it alone
            for _, region in ipairs({ btn:GetRegions() }) do
                if type(region) == "table" and region ~= icon and region.GetObjectType
                   and region:GetObjectType() == "Texture" then
                    killTexture(region)
                end
            end
            for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetCheckedTexture" }) do
                local fn = btn[getter]
                if type(fn) == "function" then
                    local ok, tex = pcall(fn, btn)
                    if ok and tex ~= icon then killTexture(tex) end
                end
            end
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

    btn.molHL = btn:CreateTexture(nil, "HIGHLIGHT")
    btn.molHL:SetAllPoints()
    btn.molHL:SetColorTexture(1, 1, 1, 0.12)

    -- "drop the bag here" marker: Blizzard's SlotHighlightTexture is killed above, so we draw our own
    if def.bag then
        btn.molDrop = btn.molBorderFrame:CreateTexture(nil, "OVERLAY", nil, 7)
        btn.molDrop:SetAllPoints()
        btn.molDrop:SetColorTexture(1, 0.82, 0.1, 0.35)
        btn.molDrop:Hide()
    end
end

local function styleButton(btn, def, cfg)
    skinButton(btn, def)
    btn.molBG:SetShown(cfg.borders)
    btn.molBorderFrame:SetShown(cfg.borders)
    if btn.molIcon then
        btn.molIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        btn.molIcon:ClearAllPoints()
        btn.molIcon:SetPoint("TOPLEFT", 1, -1)
        btn.molIcon:SetPoint("BOTTOMRIGHT", -1, 1)
    end
end

----------------------------------------------------------------------
-- Bag slots: Blizzard repaints its bevel / frame art on bag changes, so the fade is re-applied
-- (same set of pieces the Forever client builds a bag button from: NormalTexture bevel, IconBorder,
-- "iconframe" atlas regions, icon masks).
----------------------------------------------------------------------
local function repaintBag(btn)
    pcall(function()
        local icon = btn.molIcon
        local nt = (btn.GetNormalTexture and btn:GetNormalTexture()) or btn.NormalTexture
        if type(nt) == "table" and nt ~= icon then killTexture(nt) end
        killTexture(btn.IconBorder)
        for _, region in ipairs({ btn:GetRegions() }) do
            if type(region) == "table" and region.GetObjectType then
                local kind = region:GetObjectType()
                if kind == "MaskTexture" then
                    if type(icon) == "table" and icon.RemoveMaskTexture then pcall(icon.RemoveMaskTexture, icon, region) end
                    if type(nt) == "table" and nt ~= icon and nt.RemoveMaskTexture then pcall(nt.RemoveMaskTexture, nt, region) end
                elseif kind == "Texture" and region ~= icon and region ~= btn.molBG and region ~= btn.molHL
                       and type(icon) == "table" then
                    killTexture(region)
                end
            end
        end
        -- an EMPTY bag slot shows Blizzard's paper-doll slot picture as its "icon": that is the
        -- Blizzard background. Hide the icon then (our dark square shows instead).
        if type(icon) == "table" then
            local empty = false
            local id = btn.GetID and btn:GetID()
            if btn ~= _G.MainMenuBarBackpackButton and id and id > 0 and GetInventoryItemID then
                local item = GetInventoryItemID("player", id)
                if not (item and not (issecretvalue and issecretvalue(item))) then empty = true end
            end
            if not empty and icon.GetTexture then
                local ok, path = pcall(icon.GetTexture, icon)
                if ok and type(path) == "string" and not (issecretvalue and issecretvalue(path))
                   and (path:lower():find("paperdoll", 1, true) or path:lower():find("slot%-bag")) then
                    empty = true
                end
            end
            icon:SetAlpha(empty and 0 or 1)
        end
    end)
end

local function repaintAllBags()
    local def = DEFS[2]
    for _, btn in ipairs(buttonsFor(def)) do
        if btn.molSkinned then repaintBag(btn) end
    end
end

-- A bag on the cursor lights up the slots it can go into (every bag slot, not the backpack).
local function cursorHoldsBag()
    if not GetCursorInfo then return false end
    local ok, kind, id = pcall(GetCursorInfo)
    if not ok or kind ~= "item" or not id then return false end
    if issecretvalue and issecretvalue(id) then return false end
    local getter = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not getter then return false end
    local ok2, _, _, _, _, _, classID = pcall(getter, id)
    local container = (Enum and Enum.ItemClass and Enum.ItemClass.Container) or 1
    return ok2 and classID == container
end

local function updateBagDrop()
    local def = DEFS[2]
    local holding = cursorHoldsBag()
    for _, btn in ipairs(buttonsFor(def)) do
        if btn.molDrop then
            btn.molDrop:SetShown(holding and btn ~= _G.MainMenuBarBackpackButton)
        end
    end
end

local repaintQueued = false
local function requestRepaint()
    if repaintQueued then return end
    repaintQueued = true
    C_Timer.After(0, function() repaintQueued = false; repaintAllBags() end)
end

----------------------------------------------------------------------
-- Layout
----------------------------------------------------------------------
local laying = false
local function layoutBar(def)
    laying = true
    local ok, err = pcall(function()
    local bar = bars[def.id]
    local cfg = cfgFor(def)
    bar:SetScale(cfg.scale * ns.db.general.scale)

    local w = cfg.size
    local h = def.bag and cfg.size or cfg.height
    local gap = cfg.spacing

    local shown = {}
    for _, btn in ipairs(buttonsFor(def)) do
        if not cfg.enabled or (not def.bag and MB.IsButtonHidden(btn:GetName() or "")) then
            -- off, or a button this client has no use for (housing, store...): parked out of sight
            btn:SetParent(hider)
        elseif btn:IsShown() or btn:GetParent() == hider then
            if btn:GetParent() == hider then btn:SetParent(bar) end
            if btn:IsShown() then shown[#shown + 1] = btn end
        end
    end
    local n = #shown
    local perRow = math.max(1, math.min(math.max(n, 1), cfg.perRow))
    local rows = math.max(1, math.ceil(n / perRow))

    -- attached to the right chat window: square buttons sized so the rows fill exactly its height
    local chat = ns.Chat
    local panel = cfg.attach and cfg.enabled and chat and chat.GetRightPanel and chat:GetRightPanel()
    if panel then
        local avail = panel:GetHeight() / math.max(0.1, cfg.scale * ns.db.general.scale)
        local fit = math.floor((avail - (rows - 1) * gap) / rows)
        w = math.max(14, fit)
        h = w
    end
    bar:SetSize(math.max(1, perRow * w + (perRow - 1) * gap), math.max(1, rows * h + (rows - 1) * gap))

    for i, btn in ipairs(shown) do
        if btn:GetParent() ~= bar then btn:SetParent(bar) end
        local col = (i - 1) % perRow
        local row = math.floor((i - 1) / perRow)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", bar, "TOPLEFT", col * (w + gap), -row * (h + gap))
        btn:SetSize(w, h)
        if btn:GetFrameStrata() ~= "HIGH" then pcall(btn.SetFrameStrata, btn, "HIGH") end
        styleButton(btn, def, cfg)
    end
    bar:SetShown(cfg.enabled)
    if def.bag then requestRepaint() end
    -- attached: bottom aligned, left of the right chat window (bags go left of the micro menu)
    local attached = false
    if cfg.attach and cfg.enabled then
        local chat = ns.Chat
        local anchor = chat and chat.GetRightPanel and chat:GetRightPanel()
        if anchor then
            local micro = bars.menu_micro
            if def.id == "menu_bags" and micro and ns.db.menus.micro.enabled and ns.db.menus.micro.attach then
                anchor = micro
            end
            bar:ClearAllPoints()
            bar:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMLEFT", -4, 0)
            attached = true
        end
    end
    if not attached then ns.Mover:Position(def.id) end
    end)
    laying = false
    if not ok then geterrorhandler()(err) end
end

local layoutQueued = false
function MB:RequestLayout()
    if layoutQueued or not ns.db then return end
    layoutQueued = true
    C_Timer.After(0, function()
        layoutQueued = false
        MB:Apply()
    end)
end

local function takeOver(def)
    if def.started then return end
    def.started = true
    local bar = CreateFrame("Frame", "ModernUI_" .. def.id, UIParent)
    bar:SetSize(40, 40)
    -- above the chat windows (their tab buttons sit on HIGH): the bars attach to the right chat window's edge
    bar:SetFrameStrata("HIGH")
    bar:SetFrameLevel(100)
    bar.def = def
    bars[def.id] = bar
    ns.Mover:Register(def.id, bar, def.label)

    for _, btn in ipairs(buttonsFor(def)) do
        btn:SetParent(bar)
        -- Blizzard's bag bar re-parents / re-anchors its slots back (bag picked up, mouseover): take them back
        if def.bag and not btn.molHookParent then
            btn.molHookParent = true
            pcall(hooksecurefunc, btn, "SetParent", function(self, parent)
                if laying or not bars[def.id] or not cfgFor(def).enabled then return end
                if parent ~= bars[def.id] and parent ~= hider and not InCombatLockdown() then
                    self:SetParent(bars[def.id])
                end
                MB:RequestLayout()
            end)
            for _, m in ipairs({ "SetPoint", "ClearAllPoints" }) do
                pcall(hooksecurefunc, btn, m, function()
                    if not laying then MB:RequestLayout() end
                end)
            end
        end
        -- Blizzard shows / hides buttons as features unlock: follow along.
        for _, m in ipairs({ "Show", "Hide", "SetShown" }) do
            if btn[m] and not btn["molHook" .. m] then
                btn["molHook" .. m] = true
                pcall(hooksecurefunc, btn, m, function() MB:RequestLayout() end)
            end
        end
    end
    def.blizz = {}
    for _, cname in ipairs(def.containers) do
        local c = _G[cname]
        if c then
            def.blizz[#def.blizz + 1] = c
            c:SetParent(hider)
            for _, m in ipairs({ "Layout", "UpdateGridLayout" }) do
                if type(c[m]) == "function" and not c["molHook" .. m] then
                    c["molHook" .. m] = true
                    pcall(hooksecurefunc, c, m, function() MB:RequestLayout() end)
                end
            end
            break
        end
    end
    for _, n in ipairs(def.hide or {}) do
        local f = _G[n]
        if f then f:SetParent(hider); def.blizz[#def.blizz + 1] = f end
    end
end

----------------------------------------------------------------------
-- Mouseover fade
----------------------------------------------------------------------
local fader = CreateFrame("Frame")
local acc = 0
fader:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc < 0.03 or not ns.db then return end
    acc = 0
    for _, def in ipairs(DEFS) do
        local bar = bars[def.id]
        local cfg = bar and cfgFor(def)
        -- Blizzard's own bar sometimes comes back (Edit Mode / mouseover code re-parents it): put it away again
        if bar and cfg.enabled and def.blizz and not InCombatLockdown() then
            for _, c in ipairs(def.blizz) do
                if c:GetParent() ~= hider then pcall(c.SetParent, c, hider) end
            end
        end
        if bar and cfg.enabled then
            local target = cfg.alpha
            if cfg.fade and not ns.Mover:IsUnlocked() then
                target = bar:IsMouseOver() and cfg.alpha or cfg.fadeAlpha
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
-- Module API
----------------------------------------------------------------------
function MB:Init()
    for _, e in ipairs({ "BAG_UPDATE_DELAYED", "BAG_SLOT_FLAGS_UPDATED", "UNIT_INVENTORY_CHANGED", "PLAYER_ENTERING_WORLD" }) do
        ns:On(e, requestRepaint)
    end
    ns:On("CURSOR_CHANGED", updateBagDrop)
    ns:On("PLAYER_ENTERING_WORLD", function() MB:RequestLayout() end)
    ns:On("PLAYER_REGEN_ENABLED", function() MB:RequestLayout() end)
end

function MB:Apply()
    if not ns.db then return end
    ns:AfterCombat("menus_apply", function()
        for _, def in ipairs(DEFS) do
            local cfg = cfgFor(def)
            if cfg.enabled then
                def.warned = false
                takeOver(def)
                layoutBar(def)
            elseif def.started then
                layoutBar(def)
                if not def.warned then
                    def.warned = true
                    ns:Print(def.label .. " disabled: /reload to restore the Blizzard version.")
                end
            end
        end
    end)
end

-- /mui bags: lists what a bag slot is made of (for skin problems)
function MB:DebugBags()
    -- first item slot of the first open bag window (the item grid skin)
    for _, fname in ipairs({ "ContainerFrameCombinedBags", "ContainerFrame1" }) do
        local f = _G[fname]
        if f and f:IsShown() then
            local item
            pcall(function()
                if f.EnumerateValidItems then for _, b in f:EnumerateValidItems() do item = b break end
                elseif f.Items then item = f.Items[1] end
            end)
            if item then
                ns:Print(fname .. " item " .. tostring(item:GetName()) .. " empty-slot sample")
                for i, r in ipairs({ item:GetRegions() }) do
                    local ok, line = pcall(function()
                        local kind = r:GetObjectType()
                        local what = kind == "Texture" and (r:GetAtlas() or tostring(r:GetTexture())) or ""
                        return string.format("  region %d %s %s a=%.1f shown=%s", i, kind, tostring(what), r:GetAlpha(), tostring(r:IsShown()))
                    end)
                    if ok then ns:Print(line) end
                end
                for i, c in ipairs({ item:GetChildren() }) do
                    ns:Print("  child " .. i .. " " .. tostring(c.GetName and c:GetName() or c:GetObjectType()) .. " shown=" .. tostring(c:IsShown()))
                end
            end
            break
        end
    end
    for _, name in ipairs({ "CharacterBag0Slot", "MainMenuBarBackpackButton" }) do
        local b = _G[name]
        if b then
            local par = b:GetParent()
            ns:Print(name .. " alpha=" .. tostring(b:GetAlpha()) .. " id=" .. tostring(b.GetID and b:GetID())
                .. " parent=" .. tostring(par and par.GetName and par:GetName()) .. " shown=" .. tostring(b:IsShown()))
            for i, r in ipairs({ b:GetRegions() }) do
                local ok, line = pcall(function()
                    local kind = r:GetObjectType()
                    local what = kind == "Texture" and (r:GetAtlas() or tostring(r:GetTexture())) or ""
                    return string.format("  region %d %s %s a=%.1f shown=%s", i, kind, tostring(what), r:GetAlpha(), tostring(r:IsShown()))
                end)
                if ok then ns:Print(line) end
            end
            for i, c in ipairs({ b:GetChildren() }) do
                ns:Print("  child " .. i .. " " .. tostring(c.GetName and c:GetName() or c:GetObjectType()) .. " shown=" .. tostring(c:IsShown()))
            end
        end
    end
end
