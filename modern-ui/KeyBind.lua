local ADDON, ns = ...
local UI = ns.UI

-- Hover key binding (/mui kb): hover an action button and press a key (or a mouse button / the wheel)
-- to bind it. Escape clears the hovered button's bindings. Bindings are Blizzard's own, saved in the
-- current binding set. Out of combat only.
local KB = {}
ns.KeyBind = KB

local active = false
local overlays = {}
local toolbar

local IGNORE = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
                 LMETA = true, RMETA = true, UNKNOWN = true, PRINTSCREEN = true }
local MOUSE = { MiddleButton = "BUTTON3" }

local function command(def, i, btn)
    if type(btn.commandName) == "string" then return btn.commandName end
    return def.bind .. i
end

local function keysOf(cmd)
    local keys = { GetBindingKey(cmd) }
    return #keys > 0 and table.concat(keys, ", ") or "not bound"
end

local function save()
    local set = GetCurrentBindingSet and GetCurrentBindingSet() or 1
    if SaveBindings then pcall(SaveBindings, set) end
end

local function showTip(o)
    GameTooltip:SetOwner(o, "ANCHOR_TOP")
    GameTooltip:SetText(o.label)
    GameTooltip:AddLine("Bound to: " .. keysOf(o.cmd), 1, 1, 1)
    GameTooltip:AddLine("Press a key to bind. Escape clears.", 0.62, 0.62, 0.68)
    GameTooltip:Show()
end

local function bind(o, key)
    if InCombatLockdown() then return end
    key = (IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown() and "CTRL-" or "") .. (IsShiftKeyDown() and "SHIFT-" or "") .. key
    if not pcall(SetBinding, key, o.cmd) then return end
    save()
    ns:Print(string.format("%s bound to %s.", key, o.label))
    showTip(o)
end

local function clear(o)
    if InCombatLockdown() then return end
    for _, key in ipairs({ GetBindingKey(o.cmd) }) do pcall(SetBinding, key) end
    save()
    ns:Print(string.format("Cleared the bindings of %s.", o.label))
    showTip(o)
end

local function getOverlay(n)
    local o = overlays[n]
    if o then return o end
    o = CreateFrame("Frame", nil, UIParent)
    o:SetFrameStrata("DIALOG")
    o:EnableMouse(true)
    o:EnableMouseWheel(true)
    o.bg = o:CreateTexture(nil, "BACKGROUND")
    o.bg:SetAllPoints()
    o.bg:SetColorTexture(0.30, 0.82, 1, 0.18)
    o:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(0.30, 0.82, 1, 0.45)
        self:EnableKeyboard(true)
        showTip(self)
    end)
    o:SetScript("OnLeave", function(self)
        self.bg:SetColorTexture(0.30, 0.82, 1, 0.18)
        self:EnableKeyboard(false)
        GameTooltip:Hide()
    end)
    o:SetScript("OnKeyDown", function(self, key)
        if InCombatLockdown() then return end
        self:SetPropagateKeyboardInput(false)
        if IGNORE[key] then return end
        if key == "ESCAPE" then clear(self) else bind(self, key) end
    end)
    o:SetScript("OnMouseDown", function(self, button)
        local key = MOUSE[button] or (button:match("^Button(%d+)$") and ("BUTTON" .. button:match("^Button(%d+)$")))
        if key then bind(self, key) end
    end)
    o:SetScript("OnMouseWheel", function(self, delta)
        bind(self, delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN")
    end)
    o:Hide()
    overlays[n] = o
    return o
end

local function buildToolbar()
    toolbar = UI.Window(nil, "", 460, 96, "FULLSCREEN_DIALOG")
    toolbar:ClearAllPoints()
    toolbar:SetPoint("TOP", 0, -80)
    toolbar.titleBar:Hide()
    toolbar.head = UI.Text(toolbar, "|cff4dd2ffModern UI|r - key bindings")
    toolbar.head:SetPoint("TOP", 0, -10)
    toolbar.hint = UI.Text(toolbar, "Hover a button and press a key, a mouse button or the wheel. Escape clears the hovered button.",
        "GameFontHighlightSmall", "CENTER")
    toolbar.hint:SetPoint("TOP", 0, -30)
    toolbar.hint:SetWidth(440)
    local done = UI.Button(toolbar, "Done", 120, 24, function() KB:Stop() end)
    done:SetPoint("BOTTOM", 0, 10)
end

function KB:Start()
    if active then return end
    if InCombatLockdown() then
        ns:Print("Cannot change key bindings in combat.")
        return
    end
    if not (ns.ActionBars and ns.ActionBars.defs) then return end
    if ns.Config then ns.Config:Hide() end
    active = true
    local n = 0
    for _, def in ipairs(ns.ActionBars.defs) do
        for i = 1, def.count do
            local btn = _G[def.prefix .. i] or (def.altPrefix and _G[def.altPrefix .. i])
            if btn and btn:IsVisible() then
                n = n + 1
                local o = getOverlay(n)
                o.cmd, o.label = command(def, i, btn), def.label .. " button " .. i
                o:ClearAllPoints()
                o:SetAllPoints(btn)
                o:Show()
            end
        end
    end
    if not toolbar then buildToolbar() end
    toolbar:Show()
end

function KB:Stop()
    if not active then return end
    active = false
    for _, o in ipairs(overlays) do
        o:Hide()
        o:ClearAllPoints()
    end
    if toolbar then toolbar:Hide() end
    GameTooltip:Hide()
end

function KB:Toggle()
    if active then self:Stop() else self:Start() end
end

ns:On("PLAYER_REGEN_DISABLED", function()
    if active then
        KB:Stop()
        ns:Print("Key binding mode closed (entered combat).")
    end
end)
