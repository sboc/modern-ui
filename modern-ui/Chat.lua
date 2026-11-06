local ADDON, ns = ...
local UI = ns.UI

-- Chat skin. Deliberately conservative: chat frames are full of Blizzard
-- secure/Edit Mode plumbing, so this only (a) paints backgrounds behind the
-- frames, tabs and edit boxes, (b) fades Blizzard's button column out with
-- ALPHA (never re-parenting), (c) optionally places / sizes the main window
-- through the saved C anchor methods, re-asserted after Edit Mode applies.
local CH = ns:NewModule("chat")
ns.Chat = CH

local holder, combatHolder
local started = false
local placeQueued = false

local function cfg() return ns.db.chat end

local function frameName(i) return "ChatFrame" .. i end

local function box(parent, anchorTo, l, t, r, b)
    local f = CreateFrame("Frame", nil, parent)
    f:SetPoint("TOPLEFT", anchorTo, "TOPLEFT", l, t)
    f:SetPoint("BOTTOMRIGHT", anchorTo, "BOTTOMRIGHT", r, b)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0.03, 0.03, 0.04, 0.5)
    f.borders = UI.AddBorder(f, 1, 0, 0, 0, 1, "BORDER")
    return f
end

local TAB_PARTS = { "Left", "Middle", "Right", "ActiveLeft", "ActiveMiddle", "ActiveRight",
                    "HighlightLeft", "HighlightMiddle", "HighlightRight", "leftSelectedTexture",
                    "middleSelectedTexture", "rightSelectedTexture", "leftHighlightTexture",
                    "middleHighlightTexture", "rightHighlightTexture" }
local EDIT_PARTS = { "Left", "Mid", "Right", "FocusLeft", "FocusMid", "FocusRight" }

local function skinFrame(i)
    local cf = _G[frameName(i)]
    if not cf then return end
    local c = cfg()

    if not cf.molBG then
        cf.molBG = box(cf, cf, -4, 4, 4, -6)
        cf.molBG:SetFrameLevel(math.max(0, cf:GetFrameLevel() - 1))
    end
    cf.molBG:SetShown(c.skin)
    cf.molBG.bg:SetColorTexture(0.03, 0.03, 0.04, c.bgAlpha)

    -- tab
    local tab = _G[frameName(i) .. "Tab"]
    if tab then
        for _, k in ipairs(TAB_PARTS) do
            ns.KillTexture(tab[k])
            ns.KillTexture(_G[frameName(i) .. "Tab" .. k])
        end
        local text = tab.Text or _G[frameName(i) .. "TabText"]
        if text then ns:SetFont(text, 13, "OUTLINE") end
    end

    -- edit box
    local eb = cf.editBox or _G[frameName(i) .. "EditBox"]
    if eb then
        for _, k in ipairs(EDIT_PARTS) do
            ns.KillTexture(eb[k])
            ns.KillTexture(_G[frameName(i) .. "EditBox" .. k])
        end
        if not eb.molBG then
            eb.molBG = box(eb, eb, 2, -3, -2, 3)
            eb.molBG:SetFrameLevel(math.max(0, eb:GetFrameLevel() - 1))
        end
        eb.molBG:SetShown(c.skin)
        eb.molBG.bg:SetColorTexture(0.03, 0.03, 0.04, math.min(1, c.bgAlpha + 0.2))
        pcall(ns.SetFont, ns, eb, ns.db.general.fontSize, "")
        -- arrow keys move the text cursor instead of turning the camera
        if eb.SetAltArrowKeyMode then pcall(eb.SetAltArrowKeyMode, eb, not c.arrowKeys) end
    end

    -- Blizzard's button column: alpha only, never re-parent (taint)
    if c.hideButtons then
        for _, name in ipairs({ frameName(i) .. "ButtonFrame", frameName(i) .. "ResizeButton" }) do
            local b = _G[name]
            if b then b:SetAlpha(0); if b.EnableMouse then b:EnableMouse(false) end end
        end
    end

    if c.fontSize and c.fontSize > 0 then
        pcall(cf.SetFont, cf, ns:GetFont(), c.fontSize, "")
    end
end

local function skinAll()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do skinFrame(i) end
    if cfg().hideButtons then
        for _, name in ipairs({ "ChatFrameMenuButton", "ChatFrameChannelButton", "QuickJoinToastButton" }) do
            local b = _G[name]
            if b then b:SetAlpha(0); if b.EnableMouse then b:EnableMouse(false) end end
        end
    end
end

local TIMESTAMP_FORMATS = {
    { value = "none", label = "Off" },
    { value = "%H:%M ", label = "14:05" },
    { value = "%H:%M:%S ", label = "14:05:09" },
    { value = "%I:%M %p ", label = "02:05 PM" },
}
CH.TIMESTAMP_FORMATS = TIMESTAMP_FORMATS

local function applyTimestamps()
    local fmt = cfg().timestamps
    if not fmt then return end
    pcall(SetCVar, "showTimestamps", fmt)
end

-- Combat log (ChatFrame2) as its own window on the right.
local function placeCombatLog()
    local cl = _G.ChatFrame2
    local c = cfg()
    if not cl or not combatHolder or not c.combatLog then return end
    ns:AfterCombat("chat_combatlog", function()
        if not c.combatLogDone then
            c.combatLogDone = true
            local docked = cl.isDocked
            if docked == nil and _G.FCF_IsChatWindowDocked then docked = true end
            if docked and _G.FCF_UnDockFrame then pcall(_G.FCF_UnDockFrame, cl) end
            pcall(cl.Show, cl)
        end
        combatHolder:SetSize(c.width, c.height)
        ns.Mover:Position("chat_combat")
        ns.ClearPoints(cl)
        ns.SetPoint(cl, "BOTTOMRIGHT", combatHolder, "BOTTOMRIGHT", 0, 0)
        local setSize = cl.SetSizeBase or cl.SetSize
        pcall(setSize, cl, c.width, c.height)
    end)
end

local function place()
    local cf = _G.ChatFrame1
    local c = cfg()
    if not cf or not holder or not c.move then return end
    ns:AfterCombat("chat_place", function()
        holder:SetSize(c.width, c.height)
        ns.Mover:Position("chat")
        ns.ClearPoints(cf)
        ns.SetPoint(cf, "BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 0)
        local setSize = cf.SetSizeBase or cf.SetSize
        pcall(setSize, cf, c.width, c.height)
    end)
end


----------------------------------------------------------------------
-- Custom chat window ("custom" = true)
--
-- The general chat is drawn by our own ScrollingMessageFrame inside a panel
-- that fills its rectangle edge to edge (tab strip on top, input bar below).
-- Blizzard's ChatFrame1 stays alive but invisible: it does the message
-- routing / formatting / filtering (secret-value safe), and every line it
-- adds is mirrored into our window through a hooksecurefunc post-hook on its
-- AddMessage (same bridge the other chat replacements on this client use).
-- Rules kept here: no HookScript on the chat frame, no fields written onto
-- Blizzard frames, text suppressed with alpha only, secret strings are only
-- ever passed along whole (never concatenated / measured outside a pcall).
-- Its edit box is moved into our input bar, so slash commands, macros and
-- replies keep working. The combat log (ChatFrame2) cannot be re-implemented,
-- so it is placed inside a matching panel on the other side.
----------------------------------------------------------------------
local TABS = {
    { key = "all", label = "All" },
    { key = "say", label = "Say" },
    { key = "group", label = "Group" },
    { key = "guild", label = "Guild" },
    { key = "whisper", label = "Whispers" },
    { key = "channel", label = "Channels" },
    { key = "system", label = "Loot & System" },
}
CH.TABS = TABS

local EVENT_CAT = {}
local function cat(key, events) for _, e in ipairs(events) do EVENT_CAT["CHAT_MSG_" .. e] = key end end
cat("say", { "SAY", "YELL", "EMOTE", "TEXT_EMOTE", "MONSTER_SAY", "MONSTER_YELL", "MONSTER_EMOTE",
           "MONSTER_WHISPER", "MONSTER_PARTY", "RAID_BOSS_EMOTE", "RAID_BOSS_WHISPER" })
cat("group", { "PARTY", "PARTY_LEADER", "RAID", "RAID_LEADER", "RAID_WARNING", "INSTANCE_CHAT",
           "INSTANCE_CHAT_LEADER", "BATTLEGROUND", "BATTLEGROUND_LEADER" })
cat("guild", { "GUILD", "OFFICER", "GUILD_ACHIEVEMENT", "ACHIEVEMENT" })
cat("whisper", { "WHISPER", "WHISPER_INFORM", "BN_WHISPER", "BN_WHISPER_INFORM", "AFK", "DND" })

local function classify(event)
    if type(event) ~= "string" or (issecretvalue and issecretvalue(event)) then return "system" end
    if EVENT_CAT[event] then return EVENT_CAT[event] end
    if event:find("^CHAT_MSG_CHANNEL") then return "channel" end
    return "system"
end

local HEADER_H, INPUT_H, PAD = 22, 26, 5
local MAX_KEEP = 800

local panel, combatPanel
local smf, tabButtons, scrollBtn
local smf2, rightButtons
local cmf   -- our own combat log window (fed from Blizzard's combat log frame)
local rightTab = "system"
local buffer = {}
local currentTab = "all"
local hooked = false
local stats = { hook = 0, shown = 0, errors = 0 }
local reported = {}

-- run one setup step; a failure is reported once (in chat) and never stops the others
local function step(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        stats.errors = stats.errors + 1
        if not reported[name] then
            reported[name] = true
            ns:Print("chat step '" .. name .. "' failed: " .. tostring(err))
        end
    end
    return ok
end

local function chatFontSize()
    local c = cfg()
    return (c.fontSize and c.fontSize > 0) and c.fontSize or ns.db.general.fontSize
end

local function stamped(e)
    local fmt = cfg().timestamps
    if fmt and fmt ~= "none" and e.t then
        -- secret message text cannot be concatenated: fall back to no timestamp
        local ok, res = pcall(function() return "|cff7f7f7f" .. date(fmt, e.t) .. "|r" .. e.text end)
        if ok and res then return res end
    end
    return e.text
end

local function refreshTabLook()
    if not tabButtons then return end
    local acc = ns.UI.colors.accent
    for key, b in pairs(tabButtons) do
        local sel = key == currentTab
        b.under:SetShown(sel)
        if sel then
            b.text:SetTextColor(1, 1, 1)
        elseif b.unread then
            b.text:SetTextColor(acc[1], acc[2], acc[3])
        else
            b.text:SetTextColor(0.62, 0.62, 0.66)
        end
    end
end

local function toRight(e)
    return smf2 ~= nil and e.cat == "system" and cfg().systemRight
end

local function show(e, target)
    (target or smf):AddMessage(stamped(e), e.r, e.g, e.b, e.id)
    stats.shown = stats.shown + 1
end

local function display(e)
    if toRight(e) then
        if rightTab == "system" then show(e, smf2) end
        return
    end
    if currentTab == "all" or e.cat == currentTab then
        show(e)
    elseif tabButtons and tabButtons[e.cat] then
        tabButtons[e.cat].unread = true
        refreshTabLook()
    end
end

local function selectTab(key)
    if not smf then return end
    currentTab = key
    if tabButtons and tabButtons[key] then tabButtons[key].unread = false end
    smf:Clear()
    for _, e in ipairs(buffer) do
        if not toRight(e) and (key == "all" or e.cat == key) then show(e) end
    end
    smf:ScrollToBottom()
    refreshTabLook()
end

local function refreshRightLook()
    if not rightButtons then return end
    for key, b in pairs(rightButtons) do
        local sel = key == rightTab
        b.under:SetShown(sel)
        b.text:SetTextColor(sel and 1 or 0.62, sel and 1 or 0.62, sel and 1 or 0.66)
    end
end

local function placeCombatLog2()
    local c = cfg()
    local cl = _G.ChatFrame2
    if not (cl and c.combatLog and combatPanel) then return end
    if not c.combatLogDone then
        c.combatLogDone = true
        if _G.FCF_UnDockFrame and cl.isDocked ~= false then pcall(_G.FCF_UnDockFrame, cl) end
    end
    -- Blizzard's combat log frame keeps formatting / filtering the lines, invisibly, behind our window.
    -- One anchor + an explicit size, like Blizzard's own layout does (two-corner anchors get
    -- overwritten when it applies the window size).
    ns.ClearPoints(cl)
    ns.SetPoint(cl, "TOPLEFT", combatPanel, "TOPLEFT", PAD, -(HEADER_H + 4))
    local setSize = cl.SetSizeBase or cl.SetSize
    pcall(setSize, cl, math.max(50, c.width - PAD * 2), math.max(50, c.height - HEADER_H - 4 - PAD))
    pcall(cl.Show, cl)
    pcall(function() cl:SetAlpha(0); cl:EnableMouse(false) end)
    local tab = _G.ChatFrame2Tab
    if tab then pcall(function() tab:SetAlpha(0); tab:EnableMouse(false) end) end
    -- Blizzard's quick filter buttons: hidden (alpha only), the lines they filter are shown by cmf
    local qb = _G.CombatLogQuickButtonFrame_Custom or _G.CombatLogQuickButtonFrame
    -- its buttons are children (EnableMouse(false) on the bar does not stop them): Hide() it, otherwise
    -- the invisible buttons sit on top of our tab strip and eat the clicks
    if qb then pcall(function() qb:SetAlpha(0); qb:EnableMouse(false); qb:Hide() end) end
    local bg = cl.molBG
    if bg then bg:Hide() end
end

local function selectRight(key)
    rightTab = key
    if cmf then
        cmf:SetShown(key == "combat")
        if key == "combat" then cmf:ScrollToBottom() end
    end
    if smf2 then
        smf2:SetShown(key == "system")
        if key == "system" then
            smf2:Clear()
            for _, e in ipairs(buffer) do
                if toRight(e) then show(e, smf2) end
            end
            smf2:ScrollToBottom()
        end
    end
    refreshRightLook()
    step("combatlog", placeCombatLog2)
end


----------------------------------------------------------------------
-- Copy window: chat text cannot be selected in a message frame, so the
-- visible lines are put into a small edit box (Ctrl+C there).
----------------------------------------------------------------------
local copyWin

local function plainText(t)
    t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    t = t:gsub("|H.-|h(.-)|h", "%1"):gsub("|T.-|t", ""):gsub("|A.-|a", "")
    return t
end

local function copyLines(side)
    local lines, hidden = {}, 0
    local c = cfg()
    if side == "combat" then
        if not (cmf and cmf.GetNumMessages and cmf.GetMessageInfo) then return lines, hidden end
        for i = 1, cmf:GetNumMessages() do
            local ok, line = pcall(function()
                local text = cmf:GetMessageInfo(i)
                if issecretvalue and issecretvalue(text) then error("secret") end
                return plainText(text)
            end)
            if ok and line then lines[#lines + 1] = line else hidden = hidden + 1 end
        end
        while #lines > 400 do table.remove(lines, 1) end
        return lines, hidden
    end
    local fmt = (c.timestamps and c.timestamps ~= "none") and c.timestamps or "%H:%M "
    for _, e in ipairs(buffer) do
        local want
        if side == "right" then
            want = e.cat == "system"
        else
            want = not toRight(e) and (currentTab == "all" or e.cat == currentTab)
        end
        if want then
            local ok, line = pcall(function()
                if issecretvalue and issecretvalue(e.text) then error("secret") end
                return date(fmt, e.t or time()) .. plainText(e.text)
            end)
            if ok and line then lines[#lines + 1] = line else hidden = hidden + 1 end
        end
    end
    -- the last few hundred lines are plenty
    while #lines > 400 do table.remove(lines, 1) end
    return lines, hidden
end

local function openCopy(side)
    if not copyWin then
        local win = UI.Window("ModernUIChatCopy", "Copy chat text", 600, 380)
        win.hint = UI.Text(win, "", "GameFontNormalSmall")
        win.hint:SetPoint("TOPLEFT", 14, -34)
        win.hint:SetTextColor(unpack(UI.colors.dim))
        local area = UI.ScrollArea(win)
        area.frame:SetPoint("TOPLEFT", 12, -54)
        area.frame:SetPoint("BOTTOMRIGHT", -12, 12)
        local eb = CreateFrame("EditBox", nil, area.content)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFont(ns:GetFont(), 14, "")
        eb:SetTextColor(1, 1, 1)
        eb:SetPoint("TOPLEFT", 0, 0)
        eb:SetWidth(560)
        eb:SetScript("OnEscapePressed", function() win:Hide() end)
        eb:SetScript("OnTextChanged", function(self)
            area:SetContentHeight((self:GetHeight() or 100) + 16)
        end)
        win.eb, win.area = eb, area
        copyWin = win
    end
    local lines, hidden = copyLines(side)
    copyWin.hint:SetText("Ctrl+C copies the selection (everything is selected). Esc closes."
        .. (hidden > 0 and ("  " .. hidden .. " protected line(s) cannot be copied.") or ""))
    copyWin.eb:SetText(table.concat(lines, "\n"))
    copyWin:Show()
    copyWin.eb:SetFocus()
    copyWin.eb:HighlightText()
    copyWin.area:ScrollToBottom()
end

CH.OpenCopy = openCopy

local function makeSmallButton(parent, label, x, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetFrameStrata("HIGH")
    b:SetFrameLevel(parent:GetFrameLevel() + 20)
    b:SetSize(HEADER_H + 14, HEADER_H)
    b:SetPoint("TOPRIGHT", parent, "TOPRIGHT", x, 0)
    b.text = b:CreateFontString(nil, "OVERLAY")
    b.text:SetPoint("CENTER")
    ns:SetFont(b.text, math.max(9, ns.db.general.fontSize - 1), "")
    b.text:SetText(label)
    b.text:SetTextColor(0.62, 0.62, 0.66)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.07)
    b:SetScript("OnClick", onClick)
    return b
end

local function push(text, r, g, b, id, event, t)
    if text == nil then return end
    local e = { text = text, r = r or 1, g = g or 1, b = b or 1, id = id, cat = classify(event), t = t or time() }
    buffer[#buffer + 1] = e
    if #buffer > MAX_KEEP + 100 then
        local keep = {}
        for i = #buffer - MAX_KEEP + 1, #buffer do keep[#keep + 1] = buffer[i] end
        buffer = keep
    end
    if smf then display(e) end
end

-- hook body: touches our own frames only; never errors into Blizzard's pipeline
local function onBlizzardMessage(_, text, r, g, b, id, _, _, event)
    stats.hook = stats.hook + 1
    local ok = pcall(push, text, r, g, b, id, event)
    if not ok then stats.errors = stats.errors + 1 end
end

-- lines that arrived before the hook (login messages)
local function backfill()
    local cf = _G.ChatFrame1
    if not (cf and cf.GetNumMessages and cf.GetMessageInfo) then return end
    local n = cf:GetNumMessages()
    local now = time()
    for i = 1, n do
        local text, r, g, b, id, _, _, event = cf:GetMessageInfo(i)
        push(text, r, g, b, id, event, now)
    end
end

local function hookBlizzardChat()
    if hooked then return end
    local cf = _G.ChatFrame1
    if not cf then error("ChatFrame1 missing") end
    hooked = true
    hooksecurefunc(cf, "AddMessage", onBlizzardMessage)
end

-- the combat log lines Blizzard formats / filters are mirrored into our own window
local combatHooked = false
local function onCombatMessage(_, text, r, g, b, id)
    if not cmf or text == nil then return end
    if not pcall(cmf.AddMessage, cmf, text, r or 1, g or 1, b or 1, id) then stats.errors = stats.errors + 1 end
end

local function hookBlizzardCombat()
    if combatHooked then return end
    local cl = _G.ChatFrame2
    if not (cl and cmf) then return end
    combatHooked = true
    hooksecurefunc(cl, "AddMessage", onCombatMessage)
end

local function makePanel(name)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetFrameStrata("MEDIUM")
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0.03, 0.03, 0.04, 0.5)
    f.header = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.header:SetPoint("TOPLEFT", 0, 0)
    f.header:SetPoint("TOPRIGHT", 0, 0)
    f.header:SetHeight(HEADER_H)
    f.header:SetColorTexture(0, 0, 0, 0.55)
    f.borders = UI.AddBorder(f, 1, 0, 0, 0, 1, "BORDER")
    return f
end

local function makeTabButtons(parent, defs, onSelect)
    local out = {}
    local acc = ns.UI.colors.accent
    for _, def in ipairs(defs) do
        local b = CreateFrame("Button", nil, parent)
        b:SetHeight(HEADER_H)
        -- above anything Blizzard leaves lying over the header (invisible tabs, filter bars)
        b:SetFrameStrata("HIGH")
        b:SetFrameLevel(parent:GetFrameLevel() + 20)
        b.text = b:CreateFontString(nil, "OVERLAY")
        b.text:SetPoint("CENTER", 0, 0)
        b.under = b:CreateTexture(nil, "OVERLAY")
        b.under:SetColorTexture(acc[1], acc[2], acc[3], 1)
        b.under:SetPoint("BOTTOMLEFT", 4, 0)
        b.under:SetPoint("BOTTOMRIGHT", -4, 0)
        b.under:SetHeight(2)
        b.hl = b:CreateTexture(nil, "HIGHLIGHT")
        b.hl:SetAllPoints()
        b.hl:SetColorTexture(1, 1, 1, 0.07)
        b:SetScript("OnClick", function() onSelect(def.key) end)
        out[def.key] = b
    end
    return out
end

local RIGHT_TABS = { { key = "system", label = "Loot & System" }, { key = "combat", label = "Combat Log" } }

local function buildTabs()
    tabButtons = makeTabButtons(panel, TABS, selectTab)
    rightButtons = makeTabButtons(combatPanel, RIGHT_TABS, selectRight)
end

local function placeTabRow(parent, defs, buttons, visible)
    local x = 2
    for _, def in ipairs(defs) do
        local b = buttons[def.key]
        local on = visible(def)
        b:SetShown(on)
        if on then
            ns:SetFont(b.text, math.max(9, ns.db.general.fontSize - 1), "")
            b.text:SetText(def.label)
            b:SetWidth((b.text:GetStringWidth() or 40) + 18)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, 0)
            x = x + b:GetWidth()
        end
    end
end

local function layoutTabs()
    local c = cfg()
    placeTabRow(panel, TABS, tabButtons, function(def)
        if def.key == "all" then return true end
        if def.key == "system" and c.systemRight then return false end
        return not (c.tabs and c.tabs[def.key] == false)
    end)
    if currentTab == "system" and c.systemRight then currentTab = "all" end
    if c.tabs and c.tabs[currentTab] == false then currentTab = "all" end
    placeTabRow(combatPanel, RIGHT_TABS, rightButtons, function(def)
        return def.key == "system" or c.combatLog
    end)
end

local function buildPanels()
    local c = cfg()
    panel = makePanel("ModernUI_Chat")
    panel:SetSize(c.width, c.height)
    holder = panel
    ns.Mover:Register("chat", panel, "Chat")

    -- input bar (the Blizzard edit box is moved on top of it)
    panel.input = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
    panel.input:SetPoint("BOTTOMLEFT", 0, 0)
    panel.input:SetPoint("BOTTOMRIGHT", 0, 0)
    panel.input:SetHeight(INPUT_H)
    panel.input:SetColorTexture(0, 0, 0, 0.55)

    smf = CreateFrame("ScrollingMessageFrame", "ModernUI_ChatLog", panel)
    smf:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -(HEADER_H + 4))
    smf:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD, INPUT_H + 4)
    smf:SetFrameLevel(panel:GetFrameLevel() + 2)
    smf:SetFont(ns:GetFont(), chatFontSize(), "")
    smf:SetFading(false)
    smf:SetMaxLines(600)
    smf:SetJustifyH("LEFT")
    smf:SetIndentedWordWrap(true)
    smf:SetHyperlinksEnabled(true)
    smf:EnableMouseWheel(true)
    smf:SetScript("OnMouseWheel", function(self, delta)
        if IsControlKeyDown() then
            if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
        elseif IsShiftKeyDown() then
            for _ = 1, 8 do if delta > 0 then self:ScrollUp() else self:ScrollDown() end end
        else
            for _ = 1, 3 do if delta > 0 then self:ScrollUp() else self:ScrollDown() end end
        end
    end)
    smf:SetScript("OnHyperlinkClick", function(_, link, text, button)
        pcall(SetItemRef, link, text, button, _G.ChatFrame1)
    end)
    smf:SetScript("OnHyperlinkEnter", function(self, link)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        if not pcall(GameTooltip.SetHyperlink, GameTooltip, link) then GameTooltip:Hide() return end
        GameTooltip:Show()
    end)
    smf:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)

    scrollBtn = CreateFrame("Button", nil, panel)
    scrollBtn:SetSize(HEADER_H, HEADER_H)
    scrollBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    scrollBtn.text = scrollBtn:CreateFontString(nil, "OVERLAY")
    scrollBtn.text:SetPoint("CENTER")
    ns:SetFont(scrollBtn.text, math.max(9, ns.db.general.fontSize - 1), "")
    scrollBtn.text:SetText("v")
    scrollBtn.text:SetTextColor(0.62, 0.62, 0.66)
    scrollBtn.hl = scrollBtn:CreateTexture(nil, "HIGHLIGHT")
    scrollBtn.hl:SetAllPoints()
    scrollBtn.hl:SetColorTexture(1, 1, 1, 0.07)
    scrollBtn:SetScript("OnClick", function() smf:ScrollToBottom() end)
    makeSmallButton(panel, "Copy", -HEADER_H, function() openCopy("left") end)

    combatPanel = makePanel("ModernUI_ChatCombat")
    combatPanel:SetSize(c.width, c.height)
    combatHolder = combatPanel
    ns.Mover:Register("chat_combat", combatPanel, "Loot & Combat Log")

    -- right window: our own log for loot / system lines (the combat log is Blizzard's frame, swapped in by its tab)
    smf2 = CreateFrame("ScrollingMessageFrame", "ModernUI_ChatLog2", combatPanel)
    smf2:SetPoint("TOPLEFT", combatPanel, "TOPLEFT", PAD, -(HEADER_H + 4))
    smf2:SetPoint("BOTTOMRIGHT", combatPanel, "BOTTOMRIGHT", -PAD, PAD)
    smf2:SetFrameLevel(combatPanel:GetFrameLevel() + 2)
    smf2:SetFont(ns:GetFont(), chatFontSize(), "")
    smf2:SetFading(false)
    smf2:SetMaxLines(600)
    smf2:SetJustifyH("LEFT")
    smf2:SetIndentedWordWrap(true)
    smf2:SetHyperlinksEnabled(true)
    smf2:EnableMouseWheel(true)
    smf2:SetScript("OnMouseWheel", function(self, delta)
        for _ = 1, (IsShiftKeyDown() and 8 or 3) do if delta > 0 then self:ScrollUp() else self:ScrollDown() end end
    end)
    smf2:SetScript("OnHyperlinkClick", function(_, link, text, button)
        pcall(SetItemRef, link, text, button, _G.ChatFrame1)
    end)
    smf2:SetScript("OnHyperlinkEnter", function(self, link)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        if not pcall(GameTooltip.SetHyperlink, GameTooltip, link) then GameTooltip:Hide() return end
        GameTooltip:Show()
    end)
    smf2:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)

    makeSmallButton(combatPanel, "Copy", 0, function()
        openCopy(rightTab == "combat" and "combat" or "right")
    end)
    makeSmallButton(combatPanel, "Clear", -(HEADER_H + 14), function()
        if rightTab == "combat" and cmf then cmf:Clear() elseif smf2 then smf2:Clear() end
    end)

    -- right window, second page: our own combat log window
    cmf = CreateFrame("ScrollingMessageFrame", "ModernUI_CombatLog", combatPanel)
    cmf:SetPoint("TOPLEFT", combatPanel, "TOPLEFT", PAD, -(HEADER_H + 4))
    cmf:SetPoint("BOTTOMRIGHT", combatPanel, "BOTTOMRIGHT", -PAD, PAD)
    cmf:SetFrameLevel(combatPanel:GetFrameLevel() + 2)
    cmf:SetFont(ns:GetFont(), math.max(8, chatFontSize() - 1), "")
    cmf:SetFading(false)
    cmf:SetMaxLines(1000)
    cmf:SetJustifyH("LEFT")
    cmf:SetIndentedWordWrap(true)
    cmf:SetHyperlinksEnabled(true)
    cmf:EnableMouseWheel(true)
    cmf:SetScript("OnMouseWheel", function(self, delta)
        if IsControlKeyDown() then
            if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
            return
        end
        for _ = 1, (IsShiftKeyDown() and 8 or 3) do if delta > 0 then self:ScrollUp() else self:ScrollDown() end end
    end)
    cmf:SetScript("OnHyperlinkClick", function(_, link, text, button)
        pcall(SetItemRef, link, text, button, _G.ChatFrame1)
    end)
    cmf:SetScript("OnHyperlinkEnter", function(self, link)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        if not pcall(GameTooltip.SetHyperlink, GameTooltip, link) then GameTooltip:Hide() return end
        GameTooltip:Show()
    end)
    cmf:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
    cmf:Hide()

    step("tabs", buildTabs)
end

-- Blizzard's tabs, dock and button column: alpha only (they are re-shown by Blizzard's own fade code,
-- so the watchdog calls this again).
local BLIZZ_CHROME = { "GeneralDockManager", "ChatFrameMenuButton", "ChatFrameChannelButton", "QuickJoinToastButton" }
local function hideBlizzardTabs()
    local names = {}
    for _, n in ipairs(BLIZZ_CHROME) do names[#names + 1] = n end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        names[#names + 1] = "ChatFrame" .. i .. "Tab"
        names[#names + 1] = "ChatFrame" .. i .. "ButtonFrame"
    end
    for _, name in ipairs(names) do
        local f = _G[name]
        if f and f.SetAlpha and f.GetAlpha then
            pcall(function()
                if f:GetAlpha() ~= 0 then f:SetAlpha(0) end
                -- Blizzard turns the tabs' mouse back on when it re-docks / re-lays them out
                if f.IsMouseEnabled and f.EnableMouse and f:IsMouseEnabled() then f:EnableMouse(false) end
            end)
        end
    end
end

-- Blizzard's general chat window: invisible, still doing its job.
local function hideBlizzardGeneral()
    local cf = _G.ChatFrame1
    if not cf then return end
    cf:SetAlpha(0)
    local fsc = cf.FontStringContainer
    if type(fsc) == "table" and fsc.SetAlpha then fsc:SetAlpha(0) end
    cf:EnableMouse(false)
    hideBlizzardTabs()
end

local function anchorEditBox()
    local eb = _G.ChatFrame1EditBox
    if not (eb and panel) then return end
    for _, k in ipairs(EDIT_PARTS) do
        ns.KillTexture(eb[k])
        ns.KillTexture(_G["ChatFrame1EditBox" .. k])
    end
    if eb.SetIgnoreParentAlpha then eb:SetIgnoreParentAlpha(true) end
    eb:SetFrameStrata("HIGH")
    eb:ClearAllPoints()
    eb:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 3, 2)
    eb:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -3, 2)
    eb:SetHeight(INPUT_H - 4)
    ns:SetFont(eb, chatFontSize(), "")
    if eb.SetAltArrowKeyMode then eb:SetAltArrowKeyMode(not cfg().arrowKeys) end
end

-- Blizzard's own fade code can bring the frame back: re-assert from our own slow ticker
-- (nothing is hooked on the Blizzard frame).
local watchdog
local function startWatchdog()
    if watchdog then return end
    watchdog = CreateFrame("Frame")
    local acc = 0
    watchdog:SetScript("OnUpdate", function(_, e)
        acc = acc + e
        if acc < 0.5 then return end
        acc = 0
        if not (ns.db and cfg().custom and cfg().enabled) then return end
        local cf = _G.ChatFrame1
        if cf and cf.GetAlpha and cf:GetAlpha() ~= 0 then pcall(cf.SetAlpha, cf, 0) end
        hideBlizzardTabs()
        -- the combat log drifts when Blizzard re-applies its window layout: pull it back
        local qb = _G.CombatLogQuickButtonFrame_Custom or _G.CombatLogQuickButtonFrame
        if qb and cfg().combatLog and qb.IsShown and qb:IsShown() then pcall(qb.SetAlpha, qb, 0); pcall(qb.Hide, qb) end
        local cl = _G.ChatFrame2
        if cl and cl.GetAlpha and cfg().combatLog and cl:GetAlpha() ~= 0 then pcall(cl.SetAlpha, cl, 0) end
        if cl and combatPanel and cfg().combatLog and not InCombatLockdown() then
            local ok, _, rel = pcall(cl.GetPoint, cl, 1)
            if ok and rel ~= combatPanel then pcall(placeCombatLog2) end
        end
    end)
end

local editHooked = false
local function hookEditBox()
    if editHooked then return end
    local eb = _G.ChatFrame1EditBox
    if not (eb and eb.HookScript) then return end
    editHooked = true
    -- Blizzard re-anchors the edit box when it opens: put it back (our code only)
    eb:HookScript("OnShow", function() if cfg().custom then pcall(anchorEditBox) end end)
end

local function placeCustom()
    local c = cfg()
    if not panel then return end
    ns:AfterCombat("chat_place", function()
        step("size", function()
            panel:SetSize(c.width, c.height)
            combatPanel:SetSize(c.width, c.height)
            ns.Mover:Position("chat")
            ns.Mover:Position("chat_combat")
            for _, p in ipairs({ panel, combatPanel }) do
                p.bg:SetColorTexture(0.03, 0.03, 0.04, c.bgAlpha)
                p.header:SetShown(c.skin)
            end
            combatPanel:SetShown(c.combatLog)
        end)
        step("font", function()
            smf:SetFont(ns:GetFont(), chatFontSize(), "")
            smf:SetShadowColor(0, 0, 0, 0.9)
            smf:SetShadowOffset(1, -1)
            smf:SetSpacing(2)
            smf2:SetFont(ns:GetFont(), chatFontSize(), "")
            smf2:SetShadowColor(0, 0, 0, 0.9)
            smf2:SetShadowOffset(1, -1)
            smf2:SetSpacing(2)
            cmf:SetFont(ns:GetFont(), math.max(8, chatFontSize() - 1), "")
            cmf:SetShadowColor(0, 0, 0, 0.9)
            cmf:SetShadowOffset(1, -1)
            cmf:SetSpacing(1)
        end)
        step("tabs-layout", function() layoutTabs(); refreshTabLook(); refreshRightLook() end)
        step("hide-blizzard", hideBlizzardGeneral)
        step("watchdog", startWatchdog)
        step("editbox", anchorEditBox)
        step("editbox-hook", hookEditBox)
        step("combatlog", placeCombatLog2)
        if not c.combatLog and rightTab == "combat" then rightTab = "system" end
        step("right-refresh", function() selectRight(rightTab) end)
        -- the micro menu / bag bar hang off the right window: let them re-attach
        step("menus-attach", function()
            if ns.MenuBars and ns.MenuBars.RequestLayout then ns.MenuBars:RequestLayout() end
            if ns.Tracker and ns.Tracker.RequestPlace then ns.Tracker:RequestPlace() end
        end)
    end)
end

function CH:GetRightPanel()
    if combatPanel and combatPanel:IsShown() then return combatPanel end
end

function CH:Debug()
    local cf, cl = _G.ChatFrame1, _G.ChatFrame2
    local counts = {}
    for _, e in ipairs(buffer) do counts[e.cat] = (counts[e.cat] or 0) + 1 end
    local cs = {}
    for k, v in pairs(counts) do cs[#cs + 1] = k .. "=" .. v end
    ns:Print(string.format("chat: custom=%s panel=%s smf=%s hooked=%s tab=%s/%s", tostring(cfg().custom),
        tostring(panel and panel:IsShown()), tostring(smf ~= nil), tostring(hooked), currentTab, rightTab))
    ns:Print(string.format("chat: hook calls=%d shown=%d errors=%d | buffer=%d (%s) | left lines=%s right lines=%s blizzard lines=%s",
        stats.hook, stats.shown, stats.errors, #buffer, table.concat(cs, " "),
        tostring(smf and smf:GetNumMessages()), tostring(smf2 and smf2:GetNumMessages()),
        tostring(cf and cf.GetNumMessages and cf:GetNumMessages())))
    ns:Print(string.format("chat: own combat log lines=%s hooked=%s", tostring(cmf and cmf:GetNumMessages()), tostring(combatHooked)))
    if cl then
        local ok, p, rel = pcall(cl.GetPoint, cl, 1)
        ns:Print(string.format("chat: combat log shown=%s alpha=%s anchoredToPanel=%s lines=%s",
            tostring(cl:IsShown()), tostring(cl:GetAlpha()), tostring(ok and rel == combatPanel),
            tostring(cl.GetNumMessages and cl:GetNumMessages())))
    end
end

local function requestPlace()
    if placeQueued then return end
    placeQueued = true
    C_Timer.After(0, function()
        placeQueued = false
        if cfg().custom then placeCustom() else place(); placeCombatLog() end
    end)
end

function CH:Init()
    if not ns.db.chat.enabled then return end
    self:Start()
end

function CH:Start()
    if started then return end
    started = true
    if cfg().custom then
        step("panels", buildPanels)
        step("bridge", hookBlizzardChat)
        step("combat-bridge", hookBlizzardCombat)
        step("backfill", backfill)
        pcall(SetCVar, "showTimestamps", "none")   -- we stamp the lines ourselves
    else
        holder = CreateFrame("Frame", "ModernUI_Chat", UIParent)
        holder:SetSize(420, 180)
        ns.Mover:Register("chat", holder, "Chat")
        combatHolder = CreateFrame("Frame", "ModernUI_ChatCombat", UIParent)
        combatHolder:SetSize(420, 180)
        ns.Mover:Register("chat_combat", combatHolder, "Combat Log")
    end

    local cf = _G.ChatFrame1
    if cf and cf.ApplySystemAnchor then hooksecurefunc(cf, "ApplySystemAnchor", requestPlace) end
    local cl = _G.ChatFrame2
    if cl and cl.ApplySystemAnchor then hooksecurefunc(cl, "ApplySystemAnchor", requestPlace) end
    ns:On("EDIT_MODE_LAYOUTS_UPDATED", requestPlace)
    ns:On("PLAYER_ENTERING_WORLD", function() requestPlace(); CH:Apply() end)
    ns:On("UPDATE_CHAT_WINDOWS", function() CH:Apply() end)
    ns:On("UPDATE_FLOATING_CHAT_WINDOWS", function() CH:Apply() end)
end

function CH:Apply()
    if not ns.db then return end
    if not cfg().enabled then
        if started then ns:Print("Chat skin disabled: /reload to restore Blizzard's chat look.") end
        return
    end
    if not started then self:Start() end
    if cfg().custom then
        -- frames 1 / 2 belong to the custom window; any extra chat windows still get the skin
        for i = 3, (NUM_CHAT_WINDOWS or 10) do skinFrame(i) end
        placeCustom()
        if currentTab and smf then selectTab(currentTab) end
        return
    end
    skinAll()
    applyTimestamps()
    place()
    placeCombatLog()
end
