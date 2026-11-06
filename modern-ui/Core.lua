local ADDON, ns = ...
_G.ModernUI = ns

-- Bump this when a new release needs the setup wizard to run again.
ns.SETUP_VERSION = 3

ns.modules = {}
ns.moduleList = {}

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.version = (GetMeta and GetMeta(ADDON, "Version")) or "dev"

-- WoW Forever ("camelot" game type): the 12.1 engine with vanilla content,
-- reporting a 1.60+ interface number (16001).
local build = select(4, GetBuildInfo())
ns.IS_FOREVER = type(build) == "number" and build >= 16000 and build < 20000

-- Midnight (12.0+) "secret values": comparisons/arithmetic on them error out.
ns.IsSecret = issecretvalue or function() return false end

function ns:Print(...)
    print("|cff4dd2ffModern UI|r:", ...)
end

----------------------------------------------------------------------
-- Table helpers
----------------------------------------------------------------------
function ns.CopyTable(src)
    if type(src) ~= "table" then return src end
    local out = {}
    for k, v in pairs(src) do out[k] = ns.CopyTable(v) end
    return out
end

-- Fill missing keys in dst from src (never overwrites existing values).
function ns.Defaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            ns.Defaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

-- Recursively assign src onto dst (overwrites).
function ns.Override(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            ns.Override(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end

local function splitPath(path)
    local keys = {}
    for k in path:gmatch("[^%.]+") do keys[#keys + 1] = tonumber(k) or k end
    return keys
end

function ns:Get(path)
    local node = self.db
    for _, k in ipairs(splitPath(path)) do
        if type(node) ~= "table" then return nil end
        node = node[k]
    end
    return node
end

function ns:Set(path, value)
    local keys = splitPath(path)
    local node = self.db
    for i = 1, #keys - 1 do
        if type(node[keys[i]]) ~= "table" then node[keys[i]] = {} end
        node = node[keys[i]]
    end
    node[keys[#keys]] = value
end

----------------------------------------------------------------------
-- Number / text helpers (secret-value safe)
----------------------------------------------------------------------
function ns.ShortNumber(v)
    if ns.IsSecret(v) then
        local ok, s = pcall(function()
            if AbbreviateLargeNumbers then return AbbreviateLargeNumbers(v) end
            return string.format("%d", v)
        end)
        return ok and s or ""
    end
    if type(v) ~= "number" then return "" end
    local a = math.abs(v)
    if a >= 1e9 then return string.format("%.2fB", v / 1e9)
    elseif a >= 1e6 then return string.format("%.1fM", v / 1e6)
    elseif a >= 1e3 then return string.format("%.1fK", v / 1e3)
    end
    return string.format("%d", v)
end

----------------------------------------------------------------------
-- Anchoring Edit Mode managed Blizzard frames (chat, objective tracker, ...).
-- Edit Mode replaces their SetPoint / ClearAllPoints / SetScale with Lua
-- overrides; calling those from addon code taints Edit Mode. The saved C
-- methods (*Base) are used instead; other frames use their own.
----------------------------------------------------------------------
function ns.ClearPoints(f)
    local fn = f.ClearAllPointsBase or f.ClearAllPoints
    fn(f)
end

function ns.SetPoint(f, ...)
    local fn = f.SetPointBase or f.SetPoint
    fn(f, ...)
end

function ns.SetScale(f, scale)
    local fn = f.SetScaleBase or f.SetScale
    fn(f, scale)
end

----------------------------------------------------------------------
-- Screen / pixel helpers. WoW lays frames out in "UI units": one unit is 768 / screenHeight physical
-- pixels at effective scale 1, so what a unit looks like depends on resolution and UI scale.
----------------------------------------------------------------------
local REF_W, REF_H = 1920, 1080   -- the UI area the default layout is designed for (UI units)

-- physical screen size in pixels
function ns.ScreenPixels()
    local w, h
    if GetPhysicalScreenSize then w, h = GetPhysicalScreenSize() end
    if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then w, h = 1920, 1080 end
    return w, h
end

-- UI units covered by one physical pixel, as seen by frame f (defaults to UIParent)
function ns.PixelSize(f)
    local _, h = ns.ScreenPixels()
    local es = f and f.GetEffectiveScale and f:GetEffectiveScale() or UIParent:GetEffectiveScale()
    if type(es) ~= "number" or es <= 0 then es = 1 end
    return (768 / h) / es
end

-- n physical pixels in f's units
function ns.Pixels(n, f) return n * ns.PixelSize(f) end

-- Blizzard UI scale at which one UI unit is exactly one physical pixel
function ns.PerfectUIScale()
    local _, h = ns.ScreenPixels()
    return 768 / h
end

-- size of the game's UI area in UI units
function ns.UIArea() return UIParent:GetWidth(), UIParent:GetHeight() end

-- global Modern UI scale that makes the default layout fill the UI area as designed (clamped to the slider range)
function ns.SuggestScale()
    local w, h = ns.UIArea()
    local s = math.min(w / REF_W, h / REF_H)
    s = math.floor(s / 0.05 + 0.5) * 0.05
    return math.max(0.6, math.min(2, s))
end

function ns.AspectLabel()
    local w, h = ns.ScreenPixels()
    local r = w / h
    if r >= 2.2 then return "ultrawide"
    elseif r >= 1.7 then return "16:9"
    elseif r >= 1.55 then return "16:10"
    elseif r >= 1.4 then return "3:2"
    else return "4:3" end
end

-- Sets Blizzard's own UI scale to the pixel-perfect value (affects every addon and the default UI).
-- Returns ok, scaleNow, scaleWanted. The previous setting is kept so it can be restored.
function ns.SetPerfectUIScale()
    if InCombatLockdown() then return false end
    ModernUIDB = ModernUIDB or {}
    if not ModernUIDB.prevUiScale then
        ModernUIDB.prevUiScale = { use = GetCVar("useUiScale"), scale = GetCVar("uiScale") }
    end
    local want = math.min(1, ns.PerfectUIScale())
    pcall(SetCVar, "useUiScale", "1")
    pcall(SetCVar, "uiScale", string.format("%.4f", want))
    local now = tonumber(GetCVar("uiScale")) or want
    return math.abs(now - ns.PerfectUIScale()) < 0.005, now, ns.PerfectUIScale()
end

function ns.RestoreUIScale()
    local p = ModernUIDB and ModernUIDB.prevUiScale
    if not p or InCombatLockdown() then return false end
    pcall(SetCVar, "useUiScale", p.use or "0")
    if p.scale then pcall(SetCVar, "uiScale", p.scale) end
    ModernUIDB.prevUiScale = nil
    return true
end

function ns.KillTexture(tex)
    if type(tex) ~= "table" or not tex.SetAlpha then return end
    tex:SetAlpha(0)
    if not tex.molKilled then
        tex.molKilled = true
        pcall(hooksecurefunc, tex, "Show", function(self) self:SetAlpha(0) end)
        if tex.SetAtlas then pcall(hooksecurefunc, tex, "SetAtlas", function(self) self:SetAlpha(0) end) end
    end
end

----------------------------------------------------------------------
-- Media
----------------------------------------------------------------------
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

ns.DEFAULT_FONT = "Interface\\AddOns\\modern-ui\\media\\fonts\\Expressway.ttf"

ns.media = {
    fonts = {
        { value = ns.DEFAULT_FONT, label = "Expressway" },
        { value = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", label = "Blizzard Default" },
        { value = "Fonts\\FRIZQT__.TTF", label = "Friz Quadrata" },
        { value = "Fonts\\ARIALN.TTF", label = "Arial Narrow" },
        { value = "Fonts\\SKURRI.TTF", label = "Skurri" },
        { value = "Fonts\\MORPHEUS.TTF", label = "Morpheus" },
    },
    textures = {
        { value = "Interface\\Buttons\\WHITE8X8", label = "Flat" },
        { value = "Interface\\TargetingFrame\\UI-StatusBar", label = "Blizzard" },
        { value = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill", label = "Raid" },
        { value = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar", label = "Skills" },
    },
}

if LSM then
    for _, name in ipairs(LSM:List("font")) do
        table.insert(ns.media.fonts, { value = LSM:Fetch("font", name), label = name })
    end
    for _, name in ipairs(LSM:List("statusbar")) do
        table.insert(ns.media.textures, { value = LSM:Fetch("statusbar", name), label = name })
    end
end

function ns:GetFont() return self.db.general.font end
function ns:GetTexture() return self.db.general.texture end

function ns:SetFont(fs, size, outlineOverride)
    local g = self.db.general
    local ok = pcall(fs.SetFont, fs, g.font, size or g.fontSize, outlineOverride or g.outline)
    if not ok then fs:SetFont(STANDARD_TEXT_FONT, size or g.fontSize, outlineOverride or g.outline) end
end

----------------------------------------------------------------------
-- Events + combat queue
----------------------------------------------------------------------
local ev = CreateFrame("Frame")
local handlers = {}

function ns:On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        pcall(ev.RegisterEvent, ev, event)
    end
    table.insert(handlers[event], fn)
end

ev:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if list then
        for i = 1, #list do list[i](event, ...) end
    end
end)

local queue, queueOrder = {}, {}

-- Runs fn now, or after combat ends. Same key replaces an older queued fn.
function ns:AfterCombat(key, fn)
    if InCombatLockdown() then
        if not queue[key] then queueOrder[#queueOrder + 1] = key end
        queue[key] = fn
        return false
    end
    fn()
    return true
end

ns:On("PLAYER_REGEN_ENABLED", function()
    local order = queueOrder
    queueOrder = {}
    for _, key in ipairs(order) do
        local fn = queue[key]
        queue[key] = nil
        if fn then xpcall(fn, geterrorhandler()) end
    end
end)

----------------------------------------------------------------------
-- Modules
----------------------------------------------------------------------
function ns:NewModule(name)
    local m = { name = name }
    self.modules[name] = m
    table.insert(self.moduleList, m)
    return m
end

function ns:ApplyAll()
    for _, m in ipairs(self.moduleList) do
        if m.Apply then xpcall(m.Apply, geterrorhandler(), m) end
    end
    if ns.UI and ns.UI.RefreshBorders then ns.UI.RefreshBorders() end
    if self.Config and self.Config.Refresh then self.Config:Refresh() end
end

-- One aura of a unit, whichever API this client has. Tries the buff / debuff specific calls first
-- (they are the ones that always take a plain index), then the general one, then the legacy UnitAura.
function ns.GetAuraAt(unit, idx, filter, isBuff)
    local api = C_UnitAuras
    if api then
        local fn = isBuff and api.GetBuffDataByIndex or api.GetDebuffDataByIndex
        if fn then
            local ok, a = pcall(fn, unit, idx, filter)
            if ok and a then return a end
        end
        if api.GetAuraDataByIndex then
            local ok, a = pcall(api.GetAuraDataByIndex, unit, idx, filter)
            if ok and a then return a end
        end
    end
    if UnitAura then
        local n, ic, count, _, duration, expires = UnitAura(unit, idx, filter)
        if n then
            return { icon = ic, applications = count, duration = duration, expirationTime = expires, legacyIndex = idx }
        end
    end
end

ns.applyAlias = { menus = "menubars" }

function ns:Apply(name)
    name = ns.applyAlias[name] or name
    local m = self.modules[name]
    if m and m.Apply then xpcall(m.Apply, geterrorhandler(), m) end
    if ns.UI and ns.UI.RefreshBorders then ns.UI.RefreshBorders() end
end

local pending = {}
-- Debounced apply used by config widgets (sliders fire a lot).
function ns:RequestApply(root)
    if pending[root] then return end
    pending[root] = true
    C_Timer.After(0.05, function()
        pending[root] = nil
        if root == "general" then ns:ApplyAll() else ns:Apply(root) end
    end)
end

----------------------------------------------------------------------
-- Profiles
----------------------------------------------------------------------
function ns:CharKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

function ns:InitDB()
    -- addon was called MolUI before: adopt its saved settings once
    if not ModernUIDB and MolUIDB then
        ModernUIDB = MolUIDB
        MolUIDB = nil
    end
    ModernUIDB = ModernUIDB or {}
    ModernUIDB.profiles = ModernUIDB.profiles or {}
    ModernUIDB.profileKeys = ModernUIDB.profileKeys or {}
end

function ns:SelectProfile(name, skipApply)
    ModernUIDB.profiles[name] = ModernUIDB.profiles[name] or {}
    ModernUIDB.profileKeys[self:CharKey()] = name
    self.profileName = name
    self.db = ModernUIDB.profiles[name]
    ns.Defaults(self.db, ns.defaults)
    self:Migrate()
    if not skipApply then self:ApplyAll() end
end

ns.DB_VERSION = 44

-- Settings that changed meaning between releases.
function ns:Migrate()
    local db = self.db
    local v = db.dbVersion or 0
    if v < 37 then
        -- layout presets were removed: everything layout related goes back to
        -- the one standard layout (toggles like class colors are kept)
        local d = ns.defaults
        local copy = ns.CopyTable
        db.actionbars.bars, db.actionbars.pet, db.actionbars.stance =
            copy(d.actionbars.bars), copy(d.actionbars.pet), copy(d.actionbars.stance)
        db.unitframes.frames = copy(d.unitframes.frames)
        for _, k in ipairs({ "menus", "minimap", "tracker", "databars", "chat", "nameplates", "positions" }) do
            db[k] = copy(d[k])
        end
        db.layoutPreset = nil
    end
    if v < 38 then
        -- chat font "0 = follow the general size" was too small: bring it up to the new default
        if type(db.chat) == "table" and (db.chat.fontSize or 0) <= 0 then db.chat.fontSize = ns.defaults.chat.fontSize end
    end
    if v < 39 then
        -- default font is now Expressway: move profiles still on the Blizzard font
        local f = db.general and db.general.font
        if f == nil or f == STANDARD_TEXT_FONT or f == "Fonts\\FRIZQT__.TTF" then db.general.font = ns.DEFAULT_FONT end
    end
    if v < 40 then
        -- enemy nameplates got larger: bump profiles still on the old default size
        local n = db.nameplates
        if type(n) == "table" and n.width == 170 and n.height == 16 and n.castHeight == 12 then
            n.width, n.height, n.castHeight = ns.defaults.nameplates.width, ns.defaults.nameplates.height, ns.defaults.nameplates.castHeight
        end
    end
    if v < 41 then
        -- all fonts got bigger: bump profiles still on the old default sizes
        if type(db.general) == "table" and db.general.fontSize == 12 then db.general.fontSize = ns.defaults.general.fontSize end
        if type(db.chat) == "table" and db.chat.fontSize == 14 then db.chat.fontSize = ns.defaults.chat.fontSize end
    end
    if v < 42 then
        -- player / target power bars are twice as tall: bump profiles still on the old default
        local fr = db.unitframes and db.unitframes.frames
        for _, u in ipairs({ "player", "target" }) do
            if fr and type(fr[u]) == "table" and fr[u].powerHeight == 5 then fr[u].powerHeight = 10 end
        end
    end
    if v < 43 then
        -- party frames: square row above the damage meter. Only profiles still on the old default size / spot move.
        local p = db.unitframes and db.unitframes.frames and db.unitframes.frames.party
        if type(p) == "table" and p.width == 200 and p.height == 34 and not p.horizontal then
            local d = ns.defaults.unitframes.frames.party
            for _, k in ipairs({ "width", "height", "spacing", "horizontal", "auraPerRow" }) do p[k] = d[k] end
            local pos = db.positions and db.positions.uf_party
            if type(pos) ~= "table" or (pos.point == "LEFT" and pos.x == 30 and pos.y == 60) then
                db.positions = db.positions or {}
                db.positions.uf_party = ns.CopyTable(ns.defaults.positions.uf_party)
            end
        end
    end
    if v < 44 then
        -- party squares: smaller two line text (only for profiles on the new square default)
        local p = db.unitframes and db.unitframes.frames and db.unitframes.frames.party
        if type(p) == "table" and p.width == 51 and p.height == 51 then
            p.fontSize, p.textStack = 9, true
            if p.healthFormat == nil or p.healthFormat == "" then p.healthFormat = "PERCENT" end
        end
    end
    db.dbVersion = ns.DB_VERSION
end

function ns:ProfileList()
    local list = {}
    for name in pairs(ModernUIDB.profiles) do list[#list + 1] = { value = name, label = name } end
    table.sort(list, function(a, b) return a.label < b.label end)
    return list
end

function ns:CreateProfile(name, copyFrom)
    if not name or name == "" or ModernUIDB.profiles[name] then return false end
    ModernUIDB.profiles[name] = copyFrom and ns.CopyTable(ModernUIDB.profiles[copyFrom]) or {}
    return true
end

function ns:DeleteProfile(name)
    if name == self.profileName or not ModernUIDB.profiles[name] then return false end
    ModernUIDB.profiles[name] = nil
    for k, v in pairs(ModernUIDB.profileKeys) do
        if v == name then ModernUIDB.profileKeys[k] = nil end
    end
    return true
end

-- Throw away all settings of the active profile and start over from the
-- defaults (the standard layout).
function ns:ResetProfile()
    local fresh = {}
    ModernUIDB.profiles[self.profileName] = fresh
    self.db = fresh
    ns.Defaults(fresh, ns.defaults)
    fresh.dbVersion = ns.DB_VERSION
    self:ApplyAll()
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------
ns:On("ADDON_LOADED", function(_, name)
    if name == ADDON then ns:InitDB() end
end)

ns:On("PLAYER_LOGIN", function()
    local key = ns:CharKey()
    local profile = ModernUIDB.profileKeys[key] or "Default"
    ns:SelectProfile(profile, true)

    for _, m in ipairs(ns.moduleList) do
        if m.Init then xpcall(m.Init, geterrorhandler(), m) end
    end
    ns:ApplyAll()

    if ns.db.setupVersion ~= ns.SETUP_VERSION then
        C_Timer.After(1.5, function()
            ns:AfterCombat("wizard", function() ns.Wizard:Show() end)
        end)
    end
end)

-- UI scale / resolution changes: re-seat everything.
ns:On("UI_SCALE_CHANGED", function() if ns.db then ns:ApplyAll() end end)
ns:On("DISPLAY_SIZE_CHANGED", function()
    if ns.db then ns:Apply("mover") end
    if ns.UI and ns.UI.RefreshBorders then ns.UI.RefreshBorders() end
end)

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_MODERNUI1 = "/mui"
SlashCmdList["MODERNUI"] = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)")
    local rest = (msg or ""):lower():match("^%s*%S+%s+(%S+)")
    if cmd == "" or cmd == "config" or cmd == "options" then
        ns.Config:Toggle()
    elseif cmd == "wizard" or cmd == "setup" then
        ns.Wizard:Show()
    elseif cmd == "reset" then
        ns.UI.Confirm("Reset ALL Modern UI settings of this profile to defaults?", function()
            ns:ResetProfile()
            ns:Print("Profile reset to defaults.")
        end)
    elseif cmd == "unlock" or cmd == "move" then
        ns.Mover:Unlock()
    elseif cmd == "lock" then
        ns.Mover:Lock()
    elseif cmd == "bags" and ns.MenuBars and ns.MenuBars.DebugBags then
        ns.MenuBars:DebugBags()
    elseif cmd == "auras" then
        -- /mui auras [unit]: what each aura API returns for a unit (default: target)
        local unit = (rest and rest ~= "") and rest or "target"
        local api = C_UnitAuras
        local function count(fn, ...)
            if not fn then return "n/a" end
            local n = 0
            for i = 1, 40 do
                local ok, a = pcall(fn, unit, i, ...)
                if not (ok and a) then break end
                n = i
            end
            return tostring(n)
        end
        ns:Print(string.format("auras on %s: GetAuraDataByIndex HARMFUL=%s | GetDebuffDataByIndex=%s | GetBuffDataByIndex=%s | GetAuraDataByIndex HELPFUL=%s | ns.GetAuraAt debuffs=%s",
            unit,
            count(api and api.GetAuraDataByIndex, "HARMFUL"),
            count(api and api.GetDebuffDataByIndex, "HARMFUL"),
            count(api and api.GetBuffDataByIndex, "HELPFUL"),
            count(api and api.GetAuraDataByIndex, "HELPFUL"),
            (function() local n = 0 for i = 1, 40 do if ns.GetAuraAt(unit, i, "HARMFUL", false) then n = i else break end end return n end)()))
        if ns.UnitFrames and ns.UnitFrames.AuraDebug then ns.UnitFrames:AuraDebug() end
    elseif cmd == "auratest" and ns.Auras then
        ns.Auras.Test(rest)
    elseif cmd == "test" and ns.UnitFrames then
        ns.UnitFrames:Test(rest or "party")
    elseif cmd == "plates" and ns.Nameplates then
        ns.Nameplates:Debug()
    elseif cmd == "focus" then
        -- hover something within 4 seconds: prints the frame under the mouse and its parents
        ns:Print("Hover the frame in question now (4 seconds)...")
        C_Timer.After(4, function()
            local f
            if GetMouseFoci then f = GetMouseFoci()[1] elseif GetMouseFocus then f = GetMouseFocus() end
            local chain = {}
            local depth = 0
            while f and depth < 8 do
                chain[#chain + 1] = (f.GetName and f:GetName()) or tostring(f:GetObjectType())
                f = f.GetParent and f:GetParent() or nil
                depth = depth + 1
            end
            ns:Print("under mouse: " .. (#chain > 0 and table.concat(chain, " < ") or "nothing"))
        end)
    elseif cmd == "flyout" and ns.Minimap and ns.Minimap.DebugFlyout then
        ns.Minimap:DebugFlyout()
    elseif cmd == "food" and ns.Consumables then
        ns.Consumables:Debug(rest == "all")
    elseif cmd == "chat" and ns.Chat and ns.Chat.Debug then
        ns.Chat:Debug()
    else
        ns:Print("Commands: /mui (config), /mui wizard, /mui unlock, /mui lock, /mui reset, /mui test party, /mui chat (chat diagnostics)")
    end
end
