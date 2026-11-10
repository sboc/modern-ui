local ADDON, ns = ...

-- Azeroth Pilot Reloaded (APR) skin override.
--  APR draws its guide panels (current step, fillers, quest order list, ...) from a theme table it asks
--  for through APR:GetTheme(scope). For those panels only, we answer with our own flat palette (same
--  look as the objective tracker skin) and APR's own "modern" renderer does the drawing. APR's files and
--  settings are never touched; turning the option off hands the answer back to APR.
local AP = ns:NewModule("aprskin")
ns.APRSkin = AP

local SCOPES = {
    currentStep = true, fillers = true, questOrderList = true, afk = true,
    party = true, buff = true, heirloom = true, coordinates = true,
}
local ACCENT = { 0.30, 0.82, 1.00 }   -- same accent as the objective tracker headers

local APR
local installed = false
local headers = setmetatable({}, { __mode = "k" })
local theme = {
    style = "modern", label = "Modern UI",
    background = { 0.03, 0.03, 0.04, 0.55 }, surface = { 0.07, 0.07, 0.09, 0.9 },
    border = { 0, 0, 0, 1 }, accent = { ACCENT[1], ACCENT[2], ACCENT[3], 1 },
    icon = { ACCENT[1], ACCENT[2], ACCENT[3], 1 }, selection = { ACCENT[1], ACCENT[2], ACCENT[3], 1 },
    base = { 0.88, 0.90, 0.92, 1 }, muted = { 0.5, 0.5, 0.5, 1 }, warning = { 1, 0.82, 0.30, 1 },
    stripe = { 0.10, 0.10, 0.12, 1 },
}

local function cfg() return ns.db and ns.db.tracker end

local function active(scope)
    local c = cfg()
    return c and c.aprSkin and scope and SCOPES[scope] or false
end

local function syncTheme()
    local c = cfg()
    local bgAlpha = c.background and c.bgAlpha or 0
    theme.background[4] = bgAlpha
    theme.surface[4] = math.min(1, bgAlpha + 0.35) * (c.background and 1 or 0)
    theme.border[4] = c.borders and 1 or 0
end

-- Headers: APR's own header chrome (boxed border + left accent bar) is hidden and replaced by a plain fill
-- with an accent line on the top and the bottom edge, like the tracker's headers.
local function styleHeader(header)
    if not header then return end
    local m = header.muiHeader
    if not m then
        m = {
            bg = header:CreateTexture(nil, "BACKGROUND", nil, -7),
            top = header:CreateTexture(nil, "BORDER"),
            bottom = header:CreateTexture(nil, "BORDER"),
        }
        m.bg:SetAllPoints()
        m.top:SetHeight(1)
        m.top:SetPoint("TOPLEFT"); m.top:SetPoint("TOPRIGHT")
        m.bottom:SetHeight(1)
        m.bottom:SetPoint("BOTTOMLEFT"); m.bottom:SetPoint("BOTTOMRIGHT")
        header.muiHeader = m
    end
    if header.aprModernHeader then header.aprModernHeader:SetAlpha(0) end
    local bg, a = theme.background, theme.accent
    m.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    m.top:SetColorTexture(a[1], a[2], a[3], 0.45)
    m.bottom:SetColorTexture(a[1], a[2], a[3], 0.45)
    headers[header] = true
end

-- As wide as the quest log (its skin panel when drawn): the guide panels and the snapped quest order list
local origWidths = setmetatable({}, { __mode = "k" })

function AP:SyncWidth()
    if not (installed and cfg()) or InCombatLockdown() then return end
    local qt = APR.QuestTracker
    local c = cfg()
    local want = ns.Tracker and ns.Tracker.GetVisualWidth and ns.Tracker:GetVisualWidth()
    local function one(frame, scope, module)
        if not (frame and module and module.SetContentWidth) then return end
        local useIt = want and c.aprSkin and qt and qt.IsAppearanceScope and qt:IsAppearanceScope(scope)
            and select(3, qt:Resolve()) == "blizzard"
        if useIt then
            if not origWidths[frame] then origWidths[frame] = frame:GetWidth() end
            module:SetContentWidth(want)
        elseif origWidths[frame] then
            local w = origWidths[frame]
            origWidths[frame] = nil
            module:SetContentWidth(w)
        end
    end
    one(_G.CurrentStepScreenPanel, "currentStep", APR.currentStep)
    one(_G.FillersScreenPanel, "fillers", APR.fillersFrame)
end

local function install()
    if installed then return true end
    if not (APR and type(APR.GetTheme) == "function" and type(APR.GetThemeRadius) == "function") then return false end
    installed = true

    local getTheme, getRadius = APR.GetTheme, APR.GetThemeRadius
    function APR:GetTheme(scope, ...)
        if active(scope) then return theme, "modernui" end
        return getTheme(self, scope, ...)
    end
    -- flat, square panels like the tracker's
    function APR:GetThemeRadius(base, scope, ...)
        if active(scope) then return 0 end
        return getRadius(self, base, scope, ...)
    end

    -- our font on the guide text (size and outline stay APR's)
    if type(APR.ApplyTextStyle) == "function" then
        hooksecurefunc(APR, "ApplyTextStyle", function(_, fs, scope)
            if not (active(scope) and fs and fs.GetFont and fs.SetFont) then return end
            local _, size, flags = fs:GetFont()
            if size then pcall(fs.SetFont, fs, ns:GetFont(), size, flags) end
        end)
    end
    -- guide headers
    if type(APR.ApplyModernTheme) == "function" then
        hooksecurefunc(APR, "ApplyModernTheme", function(_, frame, kind, _, scope)
            if kind == "header" and active(scope) then styleHeader(frame) end
        end)
    end
    -- width follows the quest log whenever APR lays itself out against it
    local qt = APR.QuestTracker
    if qt and type(qt.RefreshWidths) == "function" then
        hooksecurefunc(qt, "RefreshWidths", function() AP:SyncWidth() end)
    end
    return true
end

-- Navigation arrow position. APR keeps it in its own profile (arrowleft / arrowtop) and rewrites it on
-- UI_SCALE_CHANGED, DISPLAY_SIZE_CHANGED and PLAYER_ENTERING_WORLD (clamping it to the screen as it is at
-- that moment). We keep our own copy of the spot the player dragged it to and put it back after every
-- APR restore. Left / top are APR's own units: UIParent offsets from its top-left corner.
local arrowHooked, arrowSaving = false, false

local function arrowSaved() return cfg() and cfg().arrow end

local function applyArrow()
    local saved = arrowSaved()
    local arrow, frame = APR.Arrow, APR.ArrowFrameM
    local profile = APR.settings and APR.settings.profile
    if not (saved and arrow and frame and profile) then return end
    local left, top = arrow:ClampPosition(saved.left, saved.top)
    if left == nil then return end
    profile.arrowleft, profile.arrowtop = left, top
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", left, top)
end

local function installArrow()
    if arrowHooked then return end
    local arrow = APR.Arrow
    if not (arrow and type(arrow.SavePosition) == "function" and type(arrow.RestorePosition) == "function"
        and type(arrow.ClampPosition) == "function" and APR.ArrowFrameM) then return end
    local profile = APR.settings and APR.settings.profile
    if not (profile and cfg()) then return end   -- APR's saved variables not loaded yet: retried on entering the world
    arrowHooked = true

    -- no saved spot yet: adopt wherever APR has it now, so nothing moves the first time
    if cfg() and not cfg().arrow and profile and type(profile.arrowleft) == "number"
        and type(profile.arrowtop) == "number" then
        cfg().arrow = { left = profile.arrowleft, top = profile.arrowtop }
    end

    -- the player dragged it (or placed it in APR's layout editor): remember that spot
    local save = arrow.SavePosition
    function arrow:SavePosition(frame, prof, ...)
        arrowSaving = true
        local ok, err = pcall(save, self, frame, prof, ...)
        arrowSaving = false
        if not ok then error(err, 0) end
        local p = APR.settings and APR.settings.profile
        if cfg() and p and (prof == nil or prof == p)
            and type(p.arrowleft) == "number" and type(p.arrowtop) == "number" then
            cfg().arrow = { left = p.arrowleft, top = p.arrowtop }
        end
    end
    -- APR restored it from its own profile (scale / resolution / zone change): ours wins
    hooksecurefunc(arrow, "RestorePosition", function()
        if not arrowSaving then applyArrow() end
    end)
    applyArrow()
end

local lastSig
local function refresh(force)
    if not (installed and cfg()) then return end
    syncTheme()
    local c = cfg()
    local sig = table.concat({ tostring(c.aprSkin), tostring(c.background), tostring(c.borders),
        tostring(c.bgAlpha), tostring(ns:GetFont()) }, "|")
    if sig == lastSig and not force then return end
    lastSig = sig
    pcall(function()
        if APR.RefreshRegisteredSkins then APR:RefreshRegisteredSkins(true) end
        if APR.RefreshTextAppearance then APR:RefreshTextAppearance() end
        for header in pairs(headers) do if active("currentStep") then styleHeader(header) end end
        AP:SyncWidth()
    end)
end

function AP:Init()
    APR = _G.APR
    if not APR then return end
    -- the arrow is kept in place whether or not the guide panels are skinned
    ns:On("PLAYER_ENTERING_WORLD", function() C_Timer.After(0, function() installArrow(); applyArrow() end) end)
    pcall(installArrow)
    if not install() then return end
    -- APR builds (and skins) its frames on its own schedule: re-skin once it has settled
    C_Timer.After(1, function() refresh(true) end)
    ns:On("PLAYER_ENTERING_WORLD", function() C_Timer.After(2, function() refresh(true) end) end)
end

function AP:Apply()
    if not (ns.db and installed) then return end
    refresh()
    AP:SyncWidth()
end
