local ADDON, ns = ...
local UI = ns.UI

-- Positions are stored as { point, x, y } relative to the same point of
-- UIParent (nearest of 9 anchors), so layouts survive resolution changes.
local Mover = ns:NewModule("mover")
ns.Mover = Mover

local registry, order = {}, {}
local unlocked = false
local toolbar

local function round(v) return math.floor(v + 0.5) end

local function pointXY(l, r, b, t, point)
    local x, y
    if point:find("LEFT") then x = l elseif point:find("RIGHT") then x = r else x = (l + r) / 2 end
    if point:find("BOTTOM") then y = b elseif point:find("TOP") then y = t else y = (b + t) / 2 end
    return x, y
end

local function computeSave(l, r, b, t)
    local W, H = UIParent:GetWidth(), UIParent:GetHeight()
    local cx, cy = (l + r) / 2, (b + t) / 2
    local v = (cy < H / 3) and "BOTTOM" or (cy > H * 2 / 3) and "TOP" or ""
    local h = (cx < W / 3) and "LEFT" or (cx > W * 2 / 3) and "RIGHT" or ""
    local point = v .. h
    if point == "" then point = "CENTER" end
    local fx, fy = pointXY(l, r, b, t, point)
    local px, py = pointXY(0, W, 0, H, point)
    return { point = point, x = round(fx - px), y = round(fy - py), g = ns.db.general.scale }
end

function Mover:Register(key, frame, label)
    if not registry[key] then order[#order + 1] = key end
    registry[key] = registry[key] or {}
    registry[key].frame = frame
    registry[key].label = label or key
    return frame
end

-- Every Modern UI frame grows with the global scale, so offsets from the screen edges / center grow with it
-- too: the layout keeps its proportions and nothing starts to overlap. Defaults are designed for scale 1;
-- a saved position remembers the global scale it was made at (g) and is stretched from there.
function Mover:GetPosition(key)
    local g = (ns.db.general and ns.db.general.scale) or 1
    local saved = ns.db.positions[key]
    local d = ns.defaults.positions[key]
    -- older "reset" buttons stored a copy of the defaults: those are defaults, not user choices
    if saved and d and not saved.g and saved.point == d.point and saved.x == d.x and saved.y == d.y then saved = nil end
    if saved then
        if not saved.g then saved.g = g end   -- saved before scale tracking: take it as made at the current scale
        local k = g / saved.g
        return { point = saved.point, x = saved.x * k, y = saved.y * k, g = g }
    elseif d then
        return { point = d.point, x = d.x * g, y = d.y * g, g = g }
    end
end

function Mover:Position(key)
    local entry = registry[key]
    if not entry or not ns.db then return end
    ns:AfterCombat("mover_pos_" .. key, function()
        local f = entry.frame
        local p = Mover:GetPosition(key)
        if not p then return end
        local s = f:GetScale()
        if not s or s <= 0 then s = 1 end
        f:ClearAllPoints()
        f:SetPoint(p.point, UIParent, p.point, p.x / s, p.y / s)
    end)
end

----------------------------------------------------------------------
-- Overlays
----------------------------------------------------------------------
local function SyncOverlay(key)
    local entry = registry[key]
    local o = entry and entry.overlay
    if not o then return end
    local f = entry.frame
    local k = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    o:SetSize(math.max(24, (f:GetWidth() or 0) * k), math.max(24, (f:GetHeight() or 0) * k))
    o:ClearAllPoints()
    o:SetPoint("CENTER", f, "CENTER")
end

local function CreateOverlay(key)
    local entry = registry[key]
    local o = CreateFrame("Frame", nil, UIParent)
    o:SetFrameStrata("DIALOG")
    o:SetFrameLevel(100)
    o:SetMovable(true)
    o:SetClampedToScreen(true)
    o:EnableMouse(true)
    o:RegisterForDrag("LeftButton")
    o.bg = o:CreateTexture(nil, "BACKGROUND")
    o.bg:SetAllPoints()
    o.bg:SetColorTexture(0.30, 0.82, 1, 0.30)
    o.borders = UI.AddBorder(o, 1, 0.30, 0.82, 1, 1)
    o.text = UI.Text(o, entry.label, "GameFontNormal", "CENTER")
    o.text:SetPoint("CENTER")
    o.text:SetWidth(200)

    o:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(0.30, 0.82, 1, 0.55)
        self:EnableKeyboard(true)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(entry.label)
        GameTooltip:AddLine("Drag to move. Arrow keys nudge. Right-click resets.", 1, 1, 1)
        GameTooltip:Show()
    end)
    o:SetScript("OnLeave", function(self)
        self.bg:SetColorTexture(0.30, 0.82, 1, 0.30)
        self:EnableKeyboard(false)
        GameTooltip:Hide()
    end)
    o:SetScript("OnKeyDown", function(self, k)
        local dx, dy = 0, 0
        if k == "LEFT" then dx = -1 elseif k == "RIGHT" then dx = 1
        elseif k == "UP" then dy = 1 elseif k == "DOWN" then dy = -1 end
        if dx == 0 and dy == 0 then
            self:SetPropagateKeyboardInput(true)
            return
        end
        self:SetPropagateKeyboardInput(false)
        if IsShiftKeyDown() then dx, dy = dx * 10, dy * 10 end
        local p = Mover:GetPosition(key)
        if not p then return end
        p.x, p.y = p.x + dx, p.y + dy
        ns.db.positions[key] = p
        Mover:Position(key)
    end)
    o:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            ns.db.positions[key] = nil   -- back to the (scaled) default
            Mover:Position(key)
        end
    end)
    o:SetScript("OnDragStart", function(self)
        local cx, cy = self:GetCenter()
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, cy)
        entry.frame:ClearAllPoints()
        entry.frame:SetPoint("CENTER", self, "CENTER")
        self:StartMoving()
    end)
    o:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local l, r, b, t = self:GetLeft(), self:GetRight(), self:GetBottom(), self:GetTop()
        ns.db.positions[key] = computeSave(l, r, b, t)
        Mover:Position(key)
        SyncOverlay(key)
    end)
    o:Hide()
    entry.overlay = o
    return o
end

local function CreateToolbar()
    toolbar = UI.Window(nil, "Modern UI - Move frames", 440, 96)
    toolbar:SetFrameStrata("FULLSCREEN_DIALOG")
    toolbar:ClearAllPoints()
    toolbar:SetPoint("TOP", 0, -80)
    toolbar.titleBar:Hide()
    toolbar.title = UI.Text(toolbar, "|cff4dd2ffModern UI|r - move frames")
    toolbar.title:SetPoint("TOP", 0, -10)
    toolbar.hint = UI.Text(toolbar, "Drag the blue boxes. Arrow keys nudge (Shift = 10px). Right-click a box to reset it.", "GameFontHighlightSmall", "CENTER")
    toolbar.hint:SetPoint("TOP", 0, -30)
    toolbar.hint:SetWidth(420)
    local lock = UI.Button(toolbar, "Lock", 120, 24, function() Mover:Lock() end)
    lock:SetPoint("BOTTOMLEFT", toolbar, "BOTTOM", 6, 10)
    local reset = UI.Button(toolbar, "Reset all positions", 160, 24, function()
        UI.Confirm("Reset every frame to its default position?", function()
            ns.db.positions = {}   -- back to the (scaled) defaults
            Mover:Apply()
        end)
    end)
    reset:SetPoint("BOTTOMRIGHT", toolbar, "BOTTOM", -6, 10)
    toolbar:Hide()
end

function Mover:Unlock()
    if InCombatLockdown() then
        ns:Print("Cannot move frames in combat.")
        return
    end
    if ns.Config then ns.Config:Hide() end
    if ns.Wizard then ns.Wizard:Hide() end
    unlocked = true
    if not toolbar then CreateToolbar() end
    toolbar:Show()
    for _, key in ipairs(order) do
        local entry = registry[key]
        if not entry.overlay then CreateOverlay(key) end
        SyncOverlay(key)
        entry.overlay:Show()
    end
    -- bars that only exist with a pet / stance are shown (and can be moved) while unlocked
    if ns.ActionBars and ns.ActionBars.RequestLayout then ns.ActionBars:RequestLayout() end
end

function Mover:Lock()
    unlocked = false
    if ns.ActionBars and ns.ActionBars.RequestLayout then ns.ActionBars:RequestLayout() end
    if toolbar then toolbar:Hide() end
    for _, key in ipairs(order) do
        local o = registry[key].overlay
        if o then o:Hide() end
    end
end

function Mover:IsUnlocked() return unlocked end

function Mover:Apply()
    if not ns.db then return end
    for _, key in ipairs(order) do
        Mover:Position(key)
        if unlocked then SyncOverlay(key) end
    end
end

ns:On("PLAYER_REGEN_DISABLED", function()
    if unlocked then
        Mover:Lock()
        ns:Print("Frames locked (entered combat).")
    end
end)
