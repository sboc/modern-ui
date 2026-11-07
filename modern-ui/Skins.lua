local ADDON, ns = ...
local UI = ns.UI

-- Window skins: character frame, spellbook and world map get the same flat look as the bag windows
-- and tooltips. Blizzard's frame art is faded out and replaced by a flat background with a 1px
-- border; item / spell icon buttons become flat dark squares with a (quality colored) border.
-- Blizzard keeps owning every button and panel, so drag/drop, tooltips, tabs, casting from the
-- spellbook, map pins and quest log keep working. Frames that load on demand (spellbook, map)
-- are picked up when their Blizzard addon loads.
local SK = ns:NewModule("skins")
ns.Skins = SK

local started = false
local styled = {}   -- frame -> target key
local lightenAll    -- defined with the text helpers below

local function cfg() return ns.db.skins end

local function isOn(key)
    local c = ns.db and ns.db.skins
    return c and c.enabled and c[key] and true or false
end

-- textures on a button that carry information: never hidden
local KEEP = { "JunkIcon", "UpgradeIcon", "IconQuestTexture", "NewItemTexture", "IconOverlay", "IconOverlay2",
               "ItemContextOverlay", "searchOverlay", "SearchOverlay", "ProfessionQualityOverlay", "flash", "Flash",
               "Highlight", "highlight", "AutoCastable", "AutoCastOverlay", "AutoCastShine", "FlyoutArrow",
               "TrainBook", "TrainableIcon", "ActionBarHighlight", "LevelLinkLock", "GlyphIcon", "GlyphActivateHighlight",
               "cooldown", "Cooldown", "ignoreTexture", "popoutButton" }

local SLOT_NAMES = { "Head", "Neck", "Shoulder", "Back", "Chest", "Shirt", "Tabard", "Wrist", "Hands", "Waist", "Legs",
                     "Feet", "Finger0", "Finger1", "Trinket0", "Trinket1", "MainHand", "SecondaryHand", "Ranged", "Ammo" }

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
-- Hides a Blizzard texture / frame while its target skin is on, and fights Show / SetAtlas / SetAlpha
-- calls that would bring it back. Turning the skin off lets it show again.
local HOOKED = { "Show", "SetShown", "SetAtlas", "SetTexture", "SetAlpha" }
local function kill(obj, key)
    if type(obj) ~= "table" or type(obj.SetAlpha) ~= "function" or obj.molKeep then return end
    obj.molKey = key
    pcall(obj.SetAlpha, obj, isOn(key) and 0 or 1)
    if obj.molKillHooked then return end
    obj.molKillHooked = true
    for _, m in ipairs(HOOKED) do
        if type(obj[m]) == "function" then
            pcall(hooksecurefunc, obj, m, function(self)
                if self.molFix or not isOn(self.molKey) then return end
                if self:GetAlpha() ~= 0 then
                    self.molFix = true
                    pcall(self.SetAlpha, self, 0)
                    self.molFix = false
                end
            end)
        end
    end
end

local function killKeys(frame, keys, key)
    if type(frame) ~= "table" then return end
    for _, k in ipairs(keys) do kill(frame[k], key) end
end

local function killRegions(frame, key, keep)
    if type(frame) ~= "table" or not frame.GetRegions then return end
    for _, region in ipairs({ frame:GetRegions() }) do
        if type(region) == "table" and region.GetObjectType and region:GetObjectType() == "Texture"
           and not region.molOwn and not (keep and keep[region]) then
            kill(region, key)
        end
    end
end

local function killByName(names, key)
    for _, n in ipairs(names) do kill(_G[n], key) end
end

-- ButtonFrameTemplate leftovers: inset panels keep their content, only their art goes
local FRAME_ART = { "NineSlice", "Bg", "Background", "TopTileStreaks", "TitleBg", "PortraitContainer", "portrait",
                    "Portrait", "InsetBorderTop", "InsetBorderBottom", "InsetBorderLeft", "InsetBorderRight",
                    "TopBorder", "BottomBorder", "LeftBorder", "RightBorder" }

local function stripFrame(frame, key)
    if type(frame) ~= "table" then return end
    killKeys(frame, FRAME_ART, key)
    killRegions(frame, key)
    for _, inset in ipairs({ frame.Inset, frame.InsetRight, frame.LeftInset }) do
        if type(inset) == "table" then
            killKeys(inset, FRAME_ART, key)
            killRegions(inset, key)
        end
    end
end

-- flat background + 1px border behind a frame; margins are only used by old 384x512 style frames
local function backdrop(frame, key, l, t, r, b)
    local bg = frame.molBG
    if not bg then
        bg = CreateFrame("Frame", nil, frame)
        bg:EnableMouse(false)
        bg:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
        bg.bg = bg:CreateTexture(nil, "BACKGROUND")
        bg.bg:SetAllPoints()
        bg.borders = UI.AddBorder(bg, 1, 0, 0, 0, 1, "BORDER")
        frame.molBG = bg
    end
    bg:ClearAllPoints()
    bg:SetPoint("TOPLEFT", frame, "TOPLEFT", l or 0, t or 0)
    bg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", r or 0, b or 0)
    bg.bg:SetColorTexture(0.04, 0.04, 0.05, cfg().bgAlpha)
    bg:SetShown(isOn(key))
    return bg
end

-- old style 384x512 frames draw their art inside that rect with transparent margins
local function margins(frame)
    if frame.NineSlice then return 0, 0, 0, 0 end
    local ok, w, h = pcall(function() return frame:GetWidth(), frame:GetHeight() end)
    if ok and type(w) == "number" and type(h) == "number" and math.abs(w - 384) < 3 and math.abs(h - 512) < 3 then
        return 10, -12, -32, 76
    end
    return 0, 0, 0, 0
end

-- a flat dark panel behind a sub area (stats pane, spell list, quest log...)
local function panelBG(owner, key, alpha)
    if type(owner) ~= "table" or not owner.CreateTexture then return end
    local p = owner.molPanel
    if not p then
        p = owner:CreateTexture(nil, "BACKGROUND", nil, -7)
        p:SetAllPoints()
        p.molOwn = true
        owner.molPanel = p
    end
    p:SetColorTexture(0, 0, 0, alpha or 0.25)
    p:SetShown(isOn(key))
end

----------------------------------------------------------------------
-- Icon buttons (equipment slots, spells)
----------------------------------------------------------------------
local function syncQuality(btn)
    local ib = btn.IconBorder
    if cfg().qualityColors and type(ib) == "table" and ib.IsShown and ib:IsShown() and ib.GetVertexColor then
        local ok, r, g, b = pcall(ib.GetVertexColor, ib)
        if ok and type(r) == "number" then
            btn.molBorder:SetColor(r, g, b, 1)
            return
        end
    end
    btn.molBorder:SetColor(0, 0, 0, 1)
end

local function sweepButton(btn, key)
    pcall(function()
        local icon = btn.molIcon
        if type(icon) ~= "table" then return end
        local name = btn:GetName() or ""
        local keep = { [icon] = true, [btn.molBGTex] = true, [btn.molHL] = true }
        for _, k in ipairs(KEEP) do
            local t = btn[k] or _G[name .. k]
            if type(t) == "table" then keep[t] = true end
        end
        for _, region in ipairs({ btn:GetRegions() }) do
            if type(region) == "table" and region.GetObjectType then
                local kind = region:GetObjectType()
                if kind == "MaskTexture" then
                    if icon.RemoveMaskTexture then pcall(icon.RemoveMaskTexture, icon, region) end
                elseif kind == "Texture" and not keep[region] then
                    kill(region, key)
                end
            end
        end
    end)
end

local function flatButton(btn, key, wide)
    if type(btn) ~= "table" or not btn.CreateTexture then return end
    local name = btn:GetName() or ""
    if not btn.molSkinned then
        btn.molSkinned = true
        local icon = btn.icon or btn.Icon or _G[name .. "IconTexture"] or _G[name .. "Icon"]
        if type(icon) ~= "table" or icon:GetObjectType() ~= "Texture" then return end
        btn.molIcon = icon

        -- wide buttons (quest rewards: icon on the left, name on the right) keep their icon size;
        -- box, border and highlight hug the icon instead of the whole row
        local okw, bw, bh = pcall(function() return btn:GetWidth(), btn:GetHeight() end)
        if not wide and okw and type(bw) == "number" and type(bh) == "number" and bh > 0 and bw > bh * 1.5 then wide = true end
        btn.molWide = wide and true or false
        local function fit(o)
            if btn.molWide then
                o:SetPoint("TOPLEFT", icon, "TOPLEFT", 0, 0)
                o:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 0, 0)
            else
                o:SetAllPoints(btn)
            end
        end

        btn.molBGTex = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
        btn.molBGTex.molOwn = true
        fit(btn.molBGTex)
        btn.molBGTex:SetColorTexture(0.04, 0.04, 0.05, 0.85)

        btn.molBorderFrame = CreateFrame("Frame", nil, btn)
        fit(btn.molBorderFrame)
        btn.molBorderFrame:SetFrameLevel(btn:GetFrameLevel() + 5)
        btn.molBorderFrame:EnableMouse(false)
        btn.molBorder = UI.AddBorder(btn.molBorderFrame, 1, 0, 0, 0, 1, "OVERLAY")

        btn.molHL = btn:CreateTexture(nil, "HIGHLIGHT")
        btn.molHL.molOwn = true
        fit(btn.molHL)
        btn.molHL:SetColorTexture(1, 1, 1, 0.12)

        -- Blizzard re-colors / shows / hides the quality border on every item change
        local ib = btn.IconBorder
        if type(ib) == "table" then
            for _, m in ipairs({ "SetVertexColor", "Show", "Hide", "SetShown", "SetAtlas" }) do
                if type(ib[m]) == "function" then
                    pcall(hooksecurefunc, ib, m, function() if isOn(btn.molKey) then syncQuality(btn) end end)
                end
            end
        end
    end
    btn.molKey = key
    local on = isOn(key)
    local icon = btn.molIcon
    if type(icon) ~= "table" then return end

    killKeys(btn, { "NormalTexture", "PushedTexture", "IconBorder", "SlotHighlightTexture", "Border", "EmptySlot",
                    "SlotFrame", "TextBackground", "TextBackground2", "Backplate", "UnlearnedFrame", "BattlepayItemTexture" }, key)
    killByName({ name .. "NormalTexture", name .. "Border", name .. "EmptySlot", name .. "SlotFrame",
                 name .. "TextBackground", name .. "TextBackground2", name .. "Frame" }, key)
    if btn.GetNormalTexture then
        local ok, nt = pcall(btn.GetNormalTexture, btn)
        if ok then kill(nt, key) end
    end
    for _, m in ipairs({ "CircleMask", "IconMask" }) do
        if btn[m] and icon.RemoveMaskTexture then pcall(icon.RemoveMaskTexture, icon, btn[m]) end
    end
    sweepButton(btn, key)

    if on then
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        if not btn.molWide then
            icon:ClearAllPoints()
            icon:SetPoint("TOPLEFT", 1, -1)
            icon:SetPoint("BOTTOMRIGHT", -1, 1)
        end
    end
    btn.molBGTex:SetShown(on)
    btn.molBorderFrame:SetShown(on)
    btn.molHL:SetShown(on)
    if on then syncQuality(btn) end
end

----------------------------------------------------------------------
-- Tabs
----------------------------------------------------------------------
local function flatTab(tab, key, insetX, insetY)
    if type(tab) ~= "table" or not tab.CreateTexture then return end
    -- icon tabs (character sheet sidebar: stats / titles / equipment manager) must keep their icon
    local keep = {}
    local tabName = tab.GetName and tab:GetName() or ""
    for _, icon in ipairs({ tab.Icon or false, tab.icon or false, _G[tabName .. "Icon"] or false }) do
        if icon then keep[icon] = true end
    end
    killRegions(tab, key, keep)
    killKeys(tab, { "Left", "Middle", "Right", "LeftDisabled", "MiddleDisabled", "RightDisabled", "LeftActive",
                    "MiddleActive", "RightActive", "Bg", "Background", "NormalTexture", "PushedTexture",
                    "HighlightTexture", "DisabledTexture" }, key)
    if not tab.molTabBG then
        local bg = tab:CreateTexture(nil, "BACKGROUND", nil, -7)
        bg:SetPoint("TOPLEFT", insetX or 2, -(insetY or 3))
        bg:SetPoint("BOTTOMRIGHT", -(insetX or 2), insetY or 3)
        bg.molOwn = true
        tab.molTabBG = bg
        tab.molTabLine = UI.AddBorder(tab, 1, 0, 0, 0, 1, "BORDER")
        local hl = tab:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(bg)
        hl:SetColorTexture(1, 1, 1, 0.1)
        hl.molOwn = true
        tab.molTabHL = hl
    end
    tab.molTabBG:SetColorTexture(0.10, 0.10, 0.13, 0.95)
    tab.molTabBG:SetShown(isOn(key))
    tab.molTabHL:SetShown(isOn(key))
    for i = 1, 4 do tab.molTabLine[i]:SetShown(isOn(key)) end
end

local function flatTabs(prefix, count, key)
    for i = 1, count do flatTab(_G[prefix .. i], key) end
end

-- children of a tab strip (retail style TabSystem)
local function flatTabChildren(strip, key)
    if type(strip) ~= "table" or not strip.GetChildren then return end
    for _, c in ipairs({ strip:GetChildren() }) do flatTab(c, key) end
end

----------------------------------------------------------------------
-- Character frame
----------------------------------------------------------------------
local CHARACTER_PANELS = { "PaperDollFrame", "ReputationFrame", "SkillFrame", "TokenFrame", "CurrencyFrame",
                           "HonorFrame", "PVPFrame", "CharacterStatsPane", "PaperDollSidebarTabs",
                           "PaperDollEquipmentManagerPane", "PaperDollTitlesPane" }
local MODEL_ART = { "BackgroundTopLeft", "BackgroundTopRight", "BackgroundBotLeft", "BackgroundBotRight",
                    "BackgroundOverlay", "Background", "ClassBackground" }

local function styleCharacter(frame)
    local key = "character"
    stripFrame(frame, key)
    killByName({ "CharacterFramePortrait", "CharacterFrameBg", "CharacterFrameTopLeft", "CharacterFrameTopRight",
                 "CharacterFrameBotLeft", "CharacterFrameBotRight", "CharacterFrameInsetBg" }, key)
    backdrop(frame, key, margins(frame))

    for _, n in ipairs(CHARACTER_PANELS) do
        local p = _G[n]
        if type(p) == "table" then
            killRegions(p, key)
            killKeys(p, { "Bg", "Background", "ClassBackground", "InsetBorderTop", "InsetBorderBottom" }, key)
            if type(p.Inset) == "table" then stripFrame(p.Inset, key) end
        end
    end
    for _, n in ipairs({ "CharacterModelFrame", "CharacterModelScene" }) do
        local m = _G[n]
        if type(m) == "table" then
            killKeys(m, MODEL_ART, key)
            killRegions(m, key)
            if type(m.ControlFrame) == "table" then killRegions(m.ControlFrame, key) end
        end
    end
    killByName({ "CharacterModelFrameBackgroundTopLeft", "CharacterModelFrameBackgroundTopRight",
                 "CharacterModelFrameBackgroundBotLeft", "CharacterModelFrameBackgroundBotRight",
                 "CharacterModelFrameBackgroundOverlay" }, key)

    for _, s in ipairs(SLOT_NAMES) do flatButton(_G["Character" .. s .. "Slot"], key) end
    flatTabs("CharacterFrameTab", 6, key)
    flatTabChildren(frame.TabSystem, key)
    flatTabs("PaperDollSidebarTab", 4, key)
    panelBG(_G.CharacterStatsPane, key, 0.2)
end

----------------------------------------------------------------------
-- Spellbook
----------------------------------------------------------------------
-- retail style spellbooks build their spell rows from a pool, so rows are found by shape
local function eachSpellRow(root, fn, depth)
    depth = depth or 0
    if type(root) ~= "table" or depth > 5 or not root.GetChildren then return end
    for _, c in ipairs({ root:GetChildren() }) do
        if type(c) == "table" and c.GetObjectType then
            if type(c.Button) == "table" and c.Name then
                fn(c)
            elseif c.GetName and (c:GetName() or ""):match("^SpellButton%d+$") then
                fn(c)
            else
                eachSpellRow(c, fn, depth + 1)
            end
        end
    end
end

local function styleSpellRow(row, key)
    if type(row.Button) == "table" then
        flatButton(row.Button, key)
        killKeys(row, { "Backplate", "Border", "Bg", "Background" }, key)
        killRegions(row, key)
    else
        flatButton(row, key)
    end
end

local autoStrip   -- defined with the generic styles below

local function styleSpellbook(frame)
    local key = "spellbook"
    stripFrame(frame, key)
    autoStrip(frame, key)
    for _, sub in ipairs({ frame.TalentsFrame, frame.SpecFrame, frame.SpellBookFrame }) do autoStrip(sub, key) end
    killByName({ "SpellBookFrameBg", "SpellBookFramePortrait", "SpellBookPage1", "SpellBookPage2", "SpellBookFrameTopLeft",
                 "SpellBookFrameTopRight", "SpellBookFrameBotLeft", "SpellBookFrameBotRight", "SpellBookBookmarksFrame" }, key)
    backdrop(frame, key, margins(frame))

    for _, sub in ipairs({ frame.SpellBookFrame, frame.TalentsFrame, frame.SpecFrame }) do
        if type(sub) == "table" then
            killKeys(sub, { "Bg", "Background", "BookBGLeft", "BookBGRight", "BookBGHalved", "BookCornerFlipbook",
                            "BookBGMiddle", "Border" }, key)
            if type(sub.PagedSpellsFrame) == "table" then
                killKeys(sub.PagedSpellsFrame, { "BookBGLeft", "BookBGRight", "BookBGHalved", "BookCornerFlipbook",
                                                 "BookBGMiddle", "Bg", "Background" }, key)
            end
        end
    end

    eachSpellRow(frame, function(row) styleSpellRow(row, key) end)
    flatTabs("SpellBookFrameTabButton", 6, key)
    flatTabChildren(frame.CategoryTabSystem, key)
    flatTabChildren(frame.TabSystem, key)
    for i = 1, 12 do
        local t = _G["SpellBookSkillLineTab" .. i]
        if type(t) == "table" then
            killKeys(t, { "TabBg", "TabBg2" }, key)
            killByName({ "SpellBookSkillLineTab" .. i .. "TabardIconFrame" }, key)
        end
    end
    -- spell names / descriptions are drawn in dark ink for the book pages we removed
    lightenAll(frame, key)
end

----------------------------------------------------------------------
-- World map
----------------------------------------------------------------------
local function styleWorldMap(frame)
    local key = "worldmap"
    stripFrame(frame, key)
    local bf = frame.BorderFrame
    if type(bf) == "table" then stripFrame(bf, key) end
    backdrop(frame, key, 0, 0, 0, 0)

    local nav = frame.NavBar
    if type(nav) == "table" then
        killKeys(nav, { "overlay", "Bg", "Background", "InsetBorderTop", "NineSlice" }, key)
        killRegions(nav, key)
        if type(nav.homeButton) == "table" then killRegions(nav.homeButton, key) end
    end
    local qm = _G.QuestMapFrame
    if type(qm) == "table" then
        lightenAll(qm, key)
        killKeys(qm, { "Background", "BorderFrame" }, key)
        killRegions(qm, key)
        if type(qm.DetailsFrame) == "table" then
            killKeys(qm.DetailsFrame, { "Bg", "BackgroundTop", "Background" }, key)
            killRegions(qm.DetailsFrame, key)
        end
    end
end

----------------------------------------------------------------------
-- Text: Blizzard draws quest / book text in dark ink for the parchment we removed
----------------------------------------------------------------------
local LIGHT = 0.92

local function fixText(fs)
    if fs.molFixing or not isOn(fs.molTextKey) then return end
    local ok, r, g, b = pcall(fs.GetTextColor, fs)
    if ok and type(r) == "number" and r < 0.5 and g < 0.5 and b < 0.5 then
        fs.molFixing = true
        pcall(fs.SetTextColor, fs, LIGHT, LIGHT, LIGHT)
        fs.molFixing = false
    end
end

local function lightenFS(fs, key)
    fs.molTextKey = key
    fixText(fs)
    if not fs.molTextHooked then
        fs.molTextHooked = true
        pcall(hooksecurefunc, fs, "SetTextColor", fixText)
    end
end

-- only dark text (all channels below 0.5) is touched: colored and quality colored text stays
lightenAll = function(root, key, depth)
    depth = depth or 0
    if type(root) ~= "table" or depth > 7 or not isOn(key) then return end
    if root.GetRegions then
        for _, region in ipairs({ root:GetRegions() }) do
            if type(region) == "table" and region.GetObjectType and region:GetObjectType() == "FontString" then
                lightenFS(region, key)
            end
        end
    end
    if root.GetObjectType and root:GetObjectType() == "SimpleHTML" then
        for _, tag in ipairs({ "P", "H1", "H2", "H3" }) do pcall(root.SetTextColor, root, tag, LIGHT, LIGHT, LIGHT) end
    end
    if root.GetChildren then
        for _, c in ipairs({ root:GetChildren() }) do lightenAll(c, key, depth + 1) end
    end
end

-- gossip / quest list lines carry their color as an escape code in these strings
local COLOR_STRINGS = { NORMAL_QUEST_DISPLAY = "|cffffffff%s|r", TRIVIAL_QUEST_DISPLAY = "|cff9d9d9d%s|r",
                        IGNORED_QUEST_DISPLAY = "|cff9d9d9d%s|r" }
local originalStrings = {}
local function applyColorStrings(on)
    for name, light in pairs(COLOR_STRINGS) do
        if originalStrings[name] == nil then originalStrings[name] = _G[name] or false end
        if on then _G[name] = light elseif originalStrings[name] then _G[name] = originalStrings[name] end
    end
end

----------------------------------------------------------------------
-- Generic frames (menus, NPC windows, social, bank, ...)
----------------------------------------------------------------------
-- keys of a frame's own fields that are pure chrome
local ART_KEYS = { "^Bg$", "^Background", "^NineSlice$", "^Inset", "Border$", "^Border", "Decor", "^Portrait",
                   "TopTileStreaks", "Tile", "Shadow", "^Top[LR]", "^Bot[LR]", "Divider", "Streaks", "^TitleBg" }
local ART_SUFFIXES = { "Bg", "Portrait", "TopLeft", "TopRight", "BotLeft", "BotRight", "BackgroundTopLeft",
                       "BackgroundTopRight", "BackgroundBotLeft", "BackgroundBotRight", "Inset", "InsetBg",
                       "TitleBg", "Background" }

local function isArtKey(k)
    if k:find("Button") or k:find("^mol") then return false end
    for _, pat in ipairs(ART_KEYS) do
        if k:find(pat) then return true end
    end
    return false
end

autoStrip = function(frame, key)
    if type(frame) ~= "table" then return end
    for k, v in pairs(frame) do
        if type(k) == "string" and type(v) == "table" and v ~= frame and type(v.GetObjectType) == "function" and isArtKey(k) then
            local ok, kind = pcall(v.GetObjectType, v)
            if ok then
                if kind == "Texture" or k == "NineSlice" then
                    kill(v, key)
                elseif kind == "Frame" then
                    -- childless frames (nine slice borders) are pure art
                    if not k:find("^Inset") and select("#", v:GetChildren()) == 0 then
                        kill(v, key)
                    else
                        killKeys(v, FRAME_ART, key)
                        killRegions(v, key)
                    end
                end
            end
        end
    end
end

local function killNamed(name, key)
    for _, sfx in ipairs(ART_SUFFIXES) do kill(_G[name .. sfx], key) end
end

local function fullStrip(frame, key)
    if type(frame) ~= "table" then return end
    -- icons that carry information (popup alert icon, ...) stay
    local n0 = frame.GetName and frame:GetName()
    for _, k in ipairs({ "AlertIcon", "Icon", "icon" }) do
        for _, o in ipairs({ frame[k] or false, n0 and _G[n0 .. k] or false }) do
            if type(o) == "table" then o.molKeep = true end
        end
    end
    stripFrame(frame, key)
    autoStrip(frame, key)
    local n = frame.GetName and frame:GetName()
    if n then killNamed(n, key) end
end

local function eachFormat(fmt, count, fn)
    if count == 0 then
        local o = _G[fmt]
        if type(o) == "table" then fn(o, 0) end
        return
    end
    for i = 1, count do
        local o = _G[fmt:format(i)]
        if type(o) == "table" then fn(o, i) end
    end
end

-- spec: art = frames stripped as well, hide = frames hidden completely, subs = fields of the frame stripped,
-- buttons = { { "Format%d", count } } icon buttons, tabs = { "Prefix", count }, flatButtons = frames /
-- formats made into flat push buttons, kill = { { "Format%d", count } } decor textures, extra = function(frame)
local function genericStyle(t, frame)
    local key = t.key
    fullStrip(frame, key)
    backdrop(frame, key, margins(frame))
    for _, n in ipairs(t.art or {}) do fullStrip(_G[n], key) end
    for _, n in ipairs(t.hide or {}) do kill(_G[n], key) end
    for _, k in ipairs(t.subs or {}) do fullStrip(frame[k], key) end
    for _, b in ipairs(t.buttons or {}) do eachFormat(b[1], b[2], function(o) flatButton(o, key, b[3]) end) end
    for _, b in ipairs(t.kill or {}) do eachFormat(b[1], b[2], function(o) kill(o, key) end) end
    for _, b in ipairs(t.flatButtons or {}) do eachFormat(b[1], b[2], function(o) flatTab(o, key, 1, 1) end) end
    if t.tabs then flatTabs(t.tabs[1], t.tabs[2], key) end
    flatTabChildren(frame.TabSystem, key)
    if type(frame.Tabs) == "table" then
        for _, tab in ipairs(frame.Tabs) do flatTab(tab, key) end
    end
    if t.flatChildren then
        for _, c in ipairs({ frame:GetChildren() }) do
            if type(c) == "table" and c.GetObjectType and c:GetObjectType() == "Button" then flatTab(c, key, 1, 1) end
        end
    end
    if t.extra then t.extra(frame, key) end
    if t.lighten then lightenAll(frame, key) end
end

local function eachBankItem(frame, key)
    for _, panel in ipairs({ frame.BankPanel, frame.AccountBankPanel }) do
        if type(panel) == "table" and panel.EnumerateValidItems then
            pcall(function() for _, b in panel:EnumerateValidItems() do flatButton(b, key) end end)
        end
    end
end

local function lootRoll(frame, key)
    flatButton(frame.IconFrame, key)
end

-- Flight map: the continent map is drawn by textures of the frame itself, so the blanket strip
-- the other NPC windows get would erase it. Only textures that look like frame chrome go.
local TAXI_CHROME = { "[Pp]ortrait", "[Bb]order", "[Cc]orner", "UI%-Frame", "UI%-DialogBox", "UI%-Panel",
                      "TopLeft", "TopRight", "BotLeft", "BotRight", "BottomLeft", "BottomRight", "TitleBg" }
local TAXI_ATLAS = { "[Ff]rame", "[Bb]order", "[Pp]ortrait", "[Hh]eader" }

local function isTaxiChrome(region)
    local ok, tex = pcall(region.GetTexture, region)
    if ok and type(tex) == "string" then
        if tex:find("[Mm]ap") then return false end
        for _, p in ipairs(TAXI_CHROME) do
            if tex:find(p) then return true end
        end
    end
    local okA, atlas = pcall(region.GetAtlas, region)
    if okA and type(atlas) == "string" then
        for _, p in ipairs(TAXI_ATLAS) do
            if atlas:find(p) then return true end
        end
    end
    return false
end

local function styleTaxi(frame)
    local key = "taxi"
    backdrop(frame, key, margins(frame))
    killKeys(frame, FRAME_ART, key)
    for _, region in ipairs({ frame:GetRegions() }) do
        if type(region) == "table" and region.GetObjectType and region:GetObjectType() == "Texture"
           and not region.molOwn and isTaxiChrome(region) then
            kill(region, key)
        end
    end
    lightenAll(frame, key)
end

local SCROLL_PANELS ={ "QuestDetailScrollFrame", "QuestProgressScrollFrame", "QuestRewardScrollFrame",
                        "QuestGreetingScrollFrame", "GossipGreetingScrollFrame" }

local generic = {
    { key = "gamemenu", label = "Game menu, popups and dropdowns",
      frames = { "GameMenuFrame", "StaticPopup1", "StaticPopup2", "StaticPopup3", "StaticPopup4",
                 "DropDownList1", "DropDownList2", "DropDownList3", "ReadyCheckFrame", "ChatConfigFrame" },
      hide = { "DropDownList1Backdrop", "DropDownList1MenuBackdrop", "DropDownList2Backdrop", "DropDownList2MenuBackdrop",
               "DropDownList3Backdrop", "DropDownList3MenuBackdrop" },
      flatChildren = true,
      flatButtons = { { "StaticPopup1Button%d", 4 }, { "StaticPopup2Button%d", 4 }, { "StaticPopup3Button%d", 4 },
                      { "StaticPopup4Button%d", 4 } } },
    { key = "npc", label = "Quest, gossip and merchant windows",
      frames = { "QuestFrame", "GossipFrame", "MerchantFrame", "ItemTextFrame", "QuestLogPopupDetailFrame",
                 "ClassTrainerFrame", "TabardFrame", "PetStableFrame" },
      art = { "QuestFrameDetailPanel", "QuestFrameProgressPanel", "QuestFrameRewardPanel", "QuestFrameGreetingPanel",
              "GossipFrameGreetingPanel", "MerchantFrameInset", "MerchantMoneyInset", "MerchantExtraCurrencyInset",
              "MerchantMoneyBg", "MerchantExtraCurrencyBg", "QuestDetailScrollChildFrame", "QuestDetailScrollFrame",
              "QuestProgressScrollFrame", "QuestRewardScrollFrame", "QuestGreetingScrollFrame",
              "GossipGreetingScrollFrame", "ItemTextScrollFrame" },
      buttons = { { "MerchantItem%dItemButton", 12 }, { "MerchantBuyBackItemItemButton", 0 }, { "QuestInfoItem%d", 10, true },
                  { "QuestProgressItem%d", 6, true } },
      kill = { { "MerchantItem%dSlotTexture", 12 }, { "MerchantItem%dNameFrame", 12 } },
      tabs = { "MerchantFrameTab", 2 },
      lighten = true, ticker = true,
      sweep = function(frame) lightenAll(frame, "npc") end },
    { key = "loot", label = "Loot and group loot windows",
      frames = { "LootFrame", "GroupLootFrame1", "GroupLootFrame2", "GroupLootFrame3", "GroupLootFrame4",
                 "MasterLooterFrame", "BonusRollFrame" },
      buttons = { { "LootButton%d", 4 }, { "GroupLootFrame%dIconFrame", 4 } },
      kill = { { "LootButton%dNameFrame", 4 } },
      extra = function(frame, key) lootRoll(frame, key) end },
    { key = "social", label = "Friends, guild and who list",
      frames = { "FriendsFrame", "ChannelFrame", "RaidInfoFrame", "QuickJoinFrame", "GuildFrame", "CommunitiesFrame",
                 "RaidFrame", "AddFriendFrame" },
      art = { "FriendsListFrame", "IgnoreListFrame", "WhoFrame", "FriendsFrameInset", "WhoFrameListInset",
              "WhoFrameEditBoxInset", "RaidFrameInset" },
      tabs = { "FriendsFrameTab", 5 } },
    { key = "bank", label = "Bank",
      frames = { "BankFrame" },
      buttons = { { "BankFrameItem%d", 28 }, { "BankFrameBag%d", 7 } },
      kill = { { "BankFrameBag%dSlotTexture", 7 } },
      tabs = { "BankFrameTab", 3 },
      extra = eachBankItem },
    { key = "groupfinder", label = "Group finder and dungeon journal",
      frames = { "PVEFrame", "EncounterJournal", "LFGParentFrame", "LFDParentFrame", "PVPUIFrame", "ChallengesFrame" },
      subs = { "GroupFinderFrame", "PVPUIFrame", "ChallengesFrame", "instanceSelect", "encounter", "inset", "navBar" },
      art = { "PVEFrameLeftInset", "PVEFrameBlueBg", "EncounterJournalInset" },
      tabs = { "PVEFrameTab", 4 } },
    { key = "collections", label = "Achievements, collections and professions",
      frames = { "AchievementFrame", "CollectionsJournal", "ProfessionsFrame", "ProfessionsBookFrame", "TradeSkillFrame",
                 "CraftFrame", "ClassicProfessionFrame" },
      subs = { "MountJournal", "PetJournal", "ToyBox", "HeirloomsJournal", "WardrobeCollectionFrame", "CraftingPage",
               "SpecPage", "OrdersPage", "Header", "searchResults", "SearchResults" },
      art = { "AchievementFrameCategories", "AchievementFrameAchievements", "AchievementFrameStats",
              "AchievementFrameSummary", "TradeSkillListScrollFrame", "TradeSkillDetailScrollFrame" },
      tabs = { "CollectionsJournalTab", 5 } },
    { key = "services", label = "Mail, trade and auction house",
      frames = { "MailFrame", "OpenMailFrame", "TradeFrame", "AuctionHouseFrame", "AuctionFrame" },
      art = { "InboxFrame", "SendMailFrame", "MailFrameInset", "SendMailScrollFrame", "AuctionFrameBrowse",
              "AuctionFrameBid", "AuctionFrameAuctions" },
      subs = { "BrowseResultsFrame", "CategoriesList", "ItemBuyFrame", "ItemSellFrame", "CommoditiesBuyFrame",
               "CommoditiesSellFrame", "AuctionsFrame", "BidsFrame" },
      buttons = { { "MailItem%dButton", 7 }, { "SendMailAttachment%d", 12 }, { "OpenMailAttachmentButton%d", 16 },
                  { "TradePlayerItem%dItemButton", 7 }, { "TradeRecipientItem%dItemButton", 7 } },
      kill = { { "MailItem%dSlot", 7 } },
      tabs = { "MailFrameTab", 2 } },
}

----------------------------------------------------------------------
-- Breath / fatigue / feign death timers (MirrorTimerContainer on current clients, MirrorTimer1-3 on classic)
----------------------------------------------------------------------
local function styleMirrorTimer(timer, key)
    if type(timer) ~= "table" or not timer.GetObjectType then return end
    local name = timer.GetName and timer:GetName()
    local sb = timer.StatusBar or (name and _G[name .. "StatusBar"])
    local label = timer.Text or (name and _G[name .. "Text"])
    local keep = {}
    if sb and sb.GetStatusBarTexture then
        keep[sb:GetStatusBarTexture()] = true
        -- swapping the texture can reset the tint to white: put Blizzard's colour back (blue for breath)
        local r, g, b = sb:GetStatusBarColor()
        pcall(sb.SetStatusBarTexture, sb, ns:GetTexture())
        if not r or (r > 0.95 and g > 0.95 and b > 0.95) then r, g, b = 0.0, 0.5, 1.0 end
        sb:SetStatusBarColor(r, g, b)
    end
    killKeys(timer, { "Border", "Background", "Bg", "BG" }, key)
    killRegions(timer, key)
    if name then killByName({ name .. "Border", name .. "Background" }, key) end
    if sb then
        killKeys(sb, { "Border", "Background", "Bg", "BG" }, key)
        killRegions(sb, key, keep)
    end
    -- dark fill behind the bar, no border
    local bg = backdrop(timer, key, 0, 0, 0, 0)
    for i = 1, 4 do if bg.borders[i] then bg.borders[i]:Hide() end end
    if label and label.SetFont then
        ns:SetFont(label, math.max(9, ns.db.general.fontSize - 1), "OUTLINE")
        label:SetShown(true)
    end
end

local function styleMirror(frame)
    if frame.GetName and frame:GetName() == "MirrorTimerContainer" then
        for _, child in ipairs({ frame:GetChildren() }) do styleMirrorTimer(child, "breath") end
    else
        styleMirrorTimer(frame, "breath")
    end
end

----------------------------------------------------------------------
-- Chat bubbles (say / yell / NPC speech above heads)
----------------------------------------------------------------------
-- Bubbles are created and recycled by the engine, so a light sweep looks for new ones and
-- restyles any it finds: Blizzard's art goes, a flat panel with a 1px border takes its place.
local function styleBubble(bubble)
    local frame = bubble.GetChildren and bubble:GetChildren()
    if type(frame) ~= "table" or not frame.GetRegions then return end
    local str = frame.String
    if not str then
        for _, region in ipairs({ frame:GetRegions() }) do
            if region.GetObjectType and region:GetObjectType() == "FontString" then str = region break end
        end
    end
    killRegions(frame, "bubbles")
    if type(frame.Tail) == "table" then kill(frame.Tail, "bubbles") end
    backdrop(frame, "bubbles", -4, 4, 4, -4)
    if str and isOn("bubbles") then
        local _, size = str:GetFont()
        pcall(str.SetFont, str, ns:GetFont(), size or 13, "")
    end
end

local function sweepBubbles()
    if not (C_ChatBubbles and C_ChatBubbles.GetAllChatBubbles) then return end
    local ok, list = pcall(C_ChatBubbles.GetAllChatBubbles)
    if not ok or type(list) ~= "table" then return end
    for _, bubble in ipairs(list) do
        if not (bubble.IsForbidden and bubble:IsForbidden()) then pcall(styleBubble, bubble) end
    end
end

local function startBubbles()
    local acc = 0
    local f = CreateFrame("Frame")
    f:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc < 0.25 then return end
        acc = 0
        if isOn("bubbles") or SK.bubblesDirty then
            SK.bubblesDirty = not isOn("bubbles") and nil
            sweepBubbles()
        end
    end)
end

----------------------------------------------------------------------
-- Targets
----------------------------------------------------------------------
local targets = {
    { key = "character", style = styleCharacter, frames = { "CharacterFrame" }, hooks = true },
    { key = "spellbook", style = styleSpellbook, frames = { "PlayerSpellsFrame", "SpellBookFrame" },
      hooks = true, ticker = true },
    { key = "worldmap", style = styleWorldMap, frames = { "WorldMapFrame" }, hooks = true },
    { key = "breath", style = styleMirror,
      frames = { "MirrorTimerContainer", "MirrorTimer1", "MirrorTimer2", "MirrorTimer3" } },
    { key = "taxi", style = styleTaxi, frames = { "TaxiFrame" } },
}
SK.options = {   -- label per toggle, used by the settings page
    { "character", "Character frame (equipment slots, stats, tabs)" },
    { "spellbook", "Spellbook and talents" },
    { "worldmap", "World map" },
    { "breath", "Breath, fatigue and feign death bars" },
    { "taxi", "Flight map" },
    { "bubbles", "Chat bubbles" },
}
for _, g in ipairs(generic) do
    g.style = function(frame) genericStyle(g, frame) end
    targets[#targets + 1] = g
    SK.options[#SK.options + 1] = { g.key, g.label }
end

local function restyle(target, frame)
    if not (ns.db and ns.db.skins) then return end
    local ok, err = pcall(target.style, frame)
    if not ok and ns.debug then ns:Print("skin " .. target.key .. ": " .. tostring(err)) end
end

local function hookFrame(target, frame)
    if type(frame) ~= "table" or styled[frame] or not frame.HookScript then return end
    styled[frame] = target.key
    pcall(frame.HookScript, frame, "OnShow", function(self)
        restyle(target, self)
        -- pooled / paged content (spells, map panels) appears after OnShow
        C_Timer.After(0, function() if self:IsShown() then restyle(target, self) end end)
    end)
    for _, m in ipairs({ "Update", "UpdateDisplayedSpells", "UpdateSpells", "SetPage", "UpdateTabs", "SetDisplayMode" }) do
        if target.hooks and type(frame[m]) == "function" then
            pcall(hooksecurefunc, frame, m, function(self)
                if self:IsShown() and isOn(target.key) then SK:RequestRestyle() end
            end)
        end
    end
    if target.ticker then
        -- the spell list is rebuilt on every page / tab change: a light sweep while shown catches all of it
        local acc = 0
        local sweeper = CreateFrame("Frame", nil, frame)
        sweeper:SetScript("OnUpdate", function(_, dt)
            acc = acc + dt
            if acc < 0.4 then return end
            acc = 0
            if not isOn(target.key) then return end
            if target.sweep then pcall(target.sweep, frame) else restyle(target, frame) end
        end)
    end
    if frame:IsShown() then restyle(target, frame) end
end

local restyleQueued = false
function SK:RequestRestyle()
    if restyleQueued or not started then return end
    restyleQueued = true
    C_Timer.After(0, function()
        restyleQueued = false
        for frame, key in pairs(styled) do
            for _, t in ipairs(targets) do
                if t.key == key and frame:IsShown() then restyle(t, frame) end
            end
        end
    end)
end

local function hookAll()
    for _, t in ipairs(targets) do
        for _, name in ipairs(t.frames) do hookFrame(t, _G[name]) end
    end
end

function SK:Start()
    if started then return end
    started = true
    ns:On("ADDON_LOADED", function(_, name)
        if type(name) == "string" and name:find("^Blizzard_") then
            C_Timer.After(0, function() if ns.db and cfg().enabled then hookAll() end end)
        end
    end)
    ns:On("PLAYER_ENTERING_WORLD", function() SK:Apply() end)
    startBubbles()
    -- timers are pooled / shown by Blizzard's own handler on the same event: restyle right after it
    ns:On("MIRROR_TIMER_START", function() if isOn("breath") then SK:RequestRestyle() end end)
end

function SK:Init()
    if not ns.db.skins.enabled then return end
    self:Start()
end

function SK:Apply()
    if not ns.db then return end
    applyColorStrings(cfg().enabled and cfg().npc)
    SK.bubblesDirty = true   -- one more sweep so toggling the option updates visible bubbles
    if not cfg().enabled then
        if started then
            -- art comes back at once for everything already styled, buttons need a /reload
            for frame, key in pairs(styled) do
                for _, t in ipairs(targets) do
                    if t.key == key then restyle(t, frame) end
                end
            end
            ns:Print("Window skins disabled: /reload to fully restore Blizzard's windows.")
        end
        return
    end
    if not started then self:Start() end
    hookAll()
    self:RequestRestyle()
end
