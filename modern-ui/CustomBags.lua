local ADDON, ns = ...
local UI = ns.UI
local BW = ns.BagWindows

-- Grouped bag windows: one window that replaces Blizzard's bag windows and one that replaces the bank window, both
-- sorting the items into labeled sections (new items, quest, equipment, food, potions, ...). Every item is a real
-- Blizzard item button tied to its real bag and slot, so click / use / split / drag / tooltips / cooldowns behave
-- exactly like the default bags. Sections come from the item class; items can be moved into any section (or into
-- your own sections) by dragging them onto a section header. Sections and assignments are shared by both windows.
-- Buttons cannot be moved or shown in combat, so layout changes made in combat wait until it ends.
local CB = ns:NewModule("custombags")
ns.CustomBags = CB

local PAD, GAP, HEADER_H, TOP_H, FOOT_H = 8, 3, 18, 58, 24

-- built-in sections in display order (custom sections come first)
local SECTIONS = {
    { key = "NEW",        label = "New items" },
    { key = "QUEST",      label = "Quest" },
    { key = "EQUIP",      label = "Equipment" },
    { key = "FOOD",       label = "Food & drink" },
    { key = "POTION",     label = "Potions & elixirs" },
    { key = "CONSUMABLE", label = "Consumables" },
    { key = "TRADE",      label = "Trade goods" },
    { key = "GEMS",       label = "Gems" },
    { key = "RECIPE",     label = "Recipes" },
    { key = "CONTAINER",  label = "Bags & containers" },
    { key = "MISC",       label = "Miscellaneous" },
    { key = "JUNK",       label = "Junk" },
}
local builtin = {}
for _, s in ipairs(SECTIONS) do builtin[s.key] = s end

-- item class (GetItemInfoInstant classID) -> section
local CLASS_SECTION = {
    [1] = "CONTAINER", [2] = "EQUIP", [3] = "GEMS", [4] = "EQUIP", [5] = "TRADE", [7] = "TRADE",
    [9] = "RECIPE", [11] = "CONTAINER", [12] = "QUEST",
}

local function cfg() return ns.db.custombags end
local function isSecret(v) return ns.IsSecret and ns.IsSecret(v) end

local function bagRange()
    return 0, (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0)
end

local function inRange(id)
    local first, last = bagRange()
    return type(id) == "number" and id >= first and id <= last
end

local function playerBags()
    local list = {}
    local first, last = bagRange()
    for bag = first, last do list[#list + 1] = bag end
    return list
end

local BANK = BANK_CONTAINER or (Enum and Enum.BagIndex and Enum.BagIndex.Bank) or -1

-- Character bank containers: the old bank (main slots plus bank bags) and / or the bank tabs, whichever this client
-- has; a container it does not have reports 0 slots and adds nothing. The warband bank stays Blizzard's.
local function bankBags()
    local list, seen = {}, {}
    local E = Enum and Enum.BagIndex
    local account = E and E.AccountBankTab_1
    local _, last = bagRange()
    local function add(id)
        if type(id) ~= "number" or seen[id] or (id >= 0 and id <= last) or (account and id >= account) then return end
        seen[id] = true
        list[#list + 1] = id
    end
    add(BANK)
    if E then for i = 1, 6 do add(E["CharacterBankTab_" .. i]) end end
    for i = 1, NUM_BANKBAGSLOTS or 0 do add(last + i) end
    return list
end

local function numSlots(bag)
    local fn = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    return fn and fn(bag) or 0
end

-- what an empty slot in this bag accepts: normal, quiver / ammo pouch, soul bag, reagent bag, or a profession bag
local FAMILY_LABEL = {
    [1] = "Quiver", [2] = "Ammo pouch", [4] = "Soul bag", [8] = "Leatherworking bag", [16] = "Inscription bag",
    [32] = "Herb bag", [64] = "Enchanting bag", [128] = "Engineering bag", [512] = "Gem bag", [1024] = "Mining bag",
    [2048] = "Unused", [4096] = "Vanity pets bag",
}

local function bagKind(bag, plain)
    local reagent = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag or 5
    if (NUM_REAGENTBAG_SLOTS or 0) > 0 and bag == reagent then return "reagent", "Reagent bag", 1000 end
    local fn = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    if fn then
        local ok, _, family = pcall(fn, bag)
        if ok and type(family) == "number" and not isSecret(family) and family ~= 0 then
            return "f" .. family, FAMILY_LABEL[family] or "Special bag", family
        end
    end
    return "bag", plain, 0
end

local function itemInfo(bag, slot)
    local fn = C_Container and C_Container.GetContainerItemInfo
    if not fn then return end
    local ok, info = pcall(fn, bag, slot)
    if ok and type(info) == "table" then return info end
end

local dragging = false
local windows = {}

----------------------------------------------------------------------
-- Sections
----------------------------------------------------------------------
local function customKey(name) return "c:" .. name end

local function isCustom(key) return type(key) == "string" and key:sub(1, 2) == "c:" end

local function validKey(key)
    if builtin[key] then return true end
    if isCustom(key) then
        for _, n in ipairs(cfg().sections) do if customKey(n) == key then return true end end
    end
    return false
end

local function sectionLabel(key)
    if builtin[key] then return builtin[key].label end
    return key:sub(3)
end

local classCache = {}
local function classOf(id, link)
    local c = classCache[id]
    if c then return c[1], c[2] end
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not getInstant then return end
    local _, _, _, _, _, classID, subClassID = getInstant(link or id)
    if classID then classCache[id] = { classID, subClassID or 0 } end
    return classID, subClassID
end

local function isNew(bag, slot)
    local api = C_NewItems and C_NewItems.IsNewItem
    if not api then return false end
    local ok, v = pcall(api, bag, slot)
    return ok and v and not isSecret(v) or false
end

local function categoryOf(e)
    local pin = cfg().pins[e.id]
    if pin and validKey(pin) then return pin end
    if cfg().showNew and isNew(e.bag, e.slot) then return "NEW" end
    if e.quality == 0 then return "JUNK" end
    local classID, subClassID = classOf(e.id, e.link)
    if classID == 0 then
        if subClassID == 5 then return "FOOD" end
        if subClassID == 1 or subClassID == 2 or subClassID == 3 then return "POTION" end
        return "CONSUMABLE"
    end
    return CLASS_SECTION[classID] or "MISC"
end

-- every window shows the shared sections, so a change to them redraws all
local function refreshAll()
    for _, w in ipairs(windows) do
        w.lastSig = nil
        w:Refresh()
    end
end

local function requestAll()
    for _, w in ipairs(windows) do w:RequestRefresh() end
end
CB.RequestAll = requestAll

----------------------------------------------------------------------
-- Items
----------------------------------------------------------------------
local function gather(w)
    local entries, empties = {}, {}
    for _, bag in ipairs(w.spec.bags()) do
        for slot = 1, numSlots(bag) do
            local e = { bag = bag, slot = slot }
            local info = itemInfo(bag, slot)
            if info and info.itemID and not isSecret(info.itemID) then
                e.info = info
                e.id = info.itemID
                e.link = (type(info.hyperlink) == "string" and not isSecret(info.hyperlink)) and info.hyperlink or nil
                e.quality = (type(info.quality) == "number" and not isSecret(info.quality)) and info.quality or 1
                e.count = (type(info.stackCount) == "number" and not isSecret(info.stackCount)) and info.stackCount or 1
                e.name = e.link and e.link:match("%[(.-)%]") or ""
                entries[#entries + 1] = e
            else
                e.empty = true
                empties[#empties + 1] = e
            end
        end
    end
    return entries, empties
end

local function sortItems(a, b)
    if a.quality ~= b.quality then return a.quality > b.quality end
    if a.name ~= b.name then return a.name < b.name end
    if a.id ~= b.id then return a.id < b.id end
    if a.count ~= b.count then return a.count > b.count end
    if a.bag ~= b.bag then return a.bag < b.bag end
    return a.slot < b.slot
end

local function bagFrame(w, bag)
    local f = w.bagFrames[bag]
    if not f then
        f = CreateFrame("Frame", "ModernUIBagContainer" .. bag, w.content)
        f:SetID(bag)
        f:SetAllPoints(w.content)
        w.bagFrames[bag] = f
    end
    return f
end

local function updateCooldown(btn, bag, slot)
    local cd = btn.Cooldown or btn.cooldown
    local fn = C_Container and C_Container.GetContainerItemCooldown
    if not (cd and fn) then return end
    pcall(function()
        local start, duration, enable = fn(bag, slot)
        if CooldownFrame_Set then
            CooldownFrame_Set(cd, start, duration, enable)
        elseif start and duration then
            cd:SetCooldown(start, duration)
        end
    end)
end

local function setQuality(btn, quality)
    local ib = btn.IconBorder
    if type(ib) == "table" then
        local color = quality and quality >= 1 and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
        if color then
            pcall(ib.SetVertexColor, ib, color.r, color.g, color.b)
            ib:Show()
        else
            ib:Hide()
        end
    end
    if BW and BW.SyncQuality then BW.SyncQuality(btn) end
end

local function updateButton(w, btn, e)
    local info = e.info
    local icon = info and info.iconFileID
    if SetItemButtonTexture then
        SetItemButtonTexture(btn, icon)
    elseif btn.icon then
        btn.icon:SetTexture(icon)
        btn.icon:SetShown(icon ~= nil)
    end
    if SetItemButtonCount then SetItemButtonCount(btn, info and e.count or 0) end
    if SetItemButtonDesaturated then
        SetItemButtonDesaturated(btn, info and info.isLocked and not isSecret(info.isLocked) or false)
    end
    btn.hasItem = info and true or nil
    setQuality(btn, info and e.quality or nil)
    if btn.JunkIcon and btn.JunkIcon.SetShown then
        btn.JunkIcon:SetShown(info and e.quality == 0 and not info.hasNoValue or false)
    end
    if info then updateCooldown(btn, e.bag, e.slot) elseif btn.Cooldown then pcall(btn.Cooldown.Clear, btn.Cooldown) end
    if ns.ItemInfo then ns.ItemInfo.Decorate(btn, info and e.link or nil, info and isNew(e.bag, e.slot), "bags") end
    local dim = false
    if w.search ~= "" and info then dim = not (e.name:lower():find(w.search, 1, true)) end
    -- Trash button on: only the cheap gray stacks stay bright
    local V = ns.Vendor
    if not dim and w.spec.key == "bags" and V and V.TrashShown and V:TrashShown() then
        dim = not (info and V:IsTrash(e.bag, e.slot))
    end
    btn:SetAlpha(dim and 0.25 or 1)
end

-- tooltip for the one visible empty slot of a bag kind: says which kind of slot it is
local function showFreeTip(btn)
    pcall(function()
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:SetText(btn.molFreeLabel, 1, 1, 1)
        GameTooltip:AddLine(btn.molFreeCount .. " empty", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
end

-- extra tooltip line on items in the grouped windows: which bag holds it
local function bagLabel(bag)
    if bag == BANK then return "Bank" end
    local fn = (C_Container and C_Container.GetBagName) or GetBagName
    local ok, name = pcall(fn, bag)
    if not ok or type(name) ~= "string" or isSecret(name) or name == "" then name = nil end
    if bag == 0 then return name or "Backpack" end
    local suffix = name and (": " .. name) or ""
    local _, last = bagRange()
    if bag > last then
        local tab1 = Enum and Enum.BagIndex and Enum.BagIndex.CharacterBankTab_1
        if tab1 and bag >= tab1 then return "Bank tab " .. (bag - tab1 + 1) .. suffix end
        return "Bank bag " .. (bag - last) .. suffix
    end
    return "Bag " .. bag .. suffix
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tip)
        if tip ~= GameTooltip then return end
        local owner = tip:GetOwner()
        if not (owner and owner.molBag) or owner.molFreeLabel then return end
        pcall(function() tip:AddLine("In " .. bagLabel(owner.molBag), 0.6, 0.8, 1) end)
    end)
end

local function itemTooltip(btn, bag, slot)
    pcall(function()
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        -- the old bank's main slots are inventory slots on older clients
        if bag == BANK and BankButtonIDToInvSlotID then
            GameTooltip:SetInventoryItem("player", BankButtonIDToInvSlotID(slot))
        else
            GameTooltip:SetBagItem(bag, slot)
        end
        GameTooltip:Show()
    end)
end

local function createButton(w, bag, slot)
    if InCombatLockdown() then return end
    local name = "ModernUIBagItem" .. bag .. "_" .. slot
    local parent = bagFrame(w, bag)
    local ok, btn = pcall(CreateFrame, "ItemButton", name, parent, "ContainerFrameItemButtonTemplate")
    if not ok or not btn then
        ok, btn = pcall(CreateFrame, "Button", name, parent, "ContainerFrameItemButtonTemplate")
    end
    if not ok or not btn then
        if not CB.warned then
            CB.warned = true
            ns:Print("Grouped bags: could not create item buttons on this client (" .. tostring(btn) .. ").")
        end
        return
    end
    btn:SetID(slot)
    btn.molBag, btn.molSlot = bag, slot
    if BW and BW.StyleSlot then pcall(BW.StyleSlot, btn) end
    -- Blizzard's per-frame tooltip refresh clears the tooltip of an empty slot, so put ours back while hovered
    pcall(btn.HookScript, btn, "OnUpdate", function(self)
        if self.molFreeLabel and self:IsMouseOver() and not (GameTooltip:IsShown() and GameTooltip:GetOwner() == self and GameTooltip:NumLines() > 0) then
            showFreeTip(self)
        end
    end)
    pcall(btn.HookScript, btn, "OnEnter", function(self)
        -- Blizzard's own handler fills the tooltip; if it did not, do it here
        C_Timer.After(0, function()
            if not self:IsMouseOver() then return end
            if self.molFreeLabel then showFreeTip(self) return end
            if not (GameTooltip:IsShown() and GameTooltip:GetOwner() == self) then itemTooltip(self, bag, slot) end
            if C_NewItems and C_NewItems.RemoveNewItem then pcall(C_NewItems.RemoveNewItem, bag, slot) end
        end)
    end)
    w.buttons[bag] = w.buttons[bag] or {}
    w.buttons[bag][slot] = btn
    return btn
end

local function getButton(w, bag, slot)
    local t = w.buttons[bag]
    return (t and t[slot]) or createButton(w, bag, slot)
end

----------------------------------------------------------------------
-- Headers (section titles, also drop targets)
----------------------------------------------------------------------
local function dropOnHeader(h)
    if h.kind == "free" then return false end
    local kind, id = GetCursorInfo()
    if kind ~= "item" or type(id) ~= "number" then return false end
    ClearCursor()
    if h.kind == "new" then
        UI.Prompt("New section name", "", function(text)
            text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if text == "" then return end
            local exists = false
            for _, n in ipairs(cfg().sections) do if n == text then exists = true end end
            if not exists then table.insert(cfg().sections, text) end
            cfg().pins[id] = customKey(text)
            refreshAll()
        end)
    elseif h.kind == "auto" then
        cfg().pins[id] = nil
    else
        cfg().pins[id] = h.key
    end
    refreshAll()
    return true
end

local function deleteSection(key)
    local name = key:sub(3)
    for i, n in ipairs(cfg().sections) do
        if n == name then table.remove(cfg().sections, i) break end
    end
    for id, k in pairs(cfg().pins) do
        if k == key then cfg().pins[id] = nil end
    end
    cfg().collapsed[key] = nil
    refreshAll()
end

local function makeHeader(w, i)
    local h = CreateFrame("Button", nil, w.content)
    h:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    h.bg = h:CreateTexture(nil, "BACKGROUND")
    h.bg:SetAllPoints()
    h.bg:SetColorTexture(1, 1, 1, 0.05)
    h.text = UI.Text(h, "", "GameFontNormal", "LEFT")
    h.text:SetPoint("LEFT", 4, 0)
    h.text:SetPoint("RIGHT", -4, 0)
    h:SetScript("OnEnter", function(self) self.bg:SetColorTexture(1, 1, 1, 0.12) end)
    h:SetScript("OnLeave", function(self) self.bg:SetColorTexture(1, 1, 1, 0.05) end)
    h:SetScript("OnReceiveDrag", function(self) dropOnHeader(self) end)
    h:SetScript("OnClick", function(self, mouse)
        if dropOnHeader(self) then return end
        if self.kind then return end
        if mouse == "RightButton" and isCustom(self.key) then
            UI.Confirm("Delete the section \"" .. sectionLabel(self.key) .. "\"? Its items go back to their automatic sections.",
                function() deleteSection(self.key) end)
        elseif mouse == "LeftButton" then
            cfg().collapsed[self.key] = not cfg().collapsed[self.key] or nil
            refreshAll()
        end
    end)
    w.headers[i] = h
    return h
end

----------------------------------------------------------------------
-- Layout
----------------------------------------------------------------------
-- gold / silver / copper with the coin icons; plain coloured letters if this client has no coin-string call
local function moneyText(copper)
    local api = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
    if api then
        local ok, text = pcall(api, copper, 12)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    local g = math.floor(copper / 10000)
    local sv = math.floor(copper / 100) % 100
    local cp = copper % 100
    return string.format("|cffffd700%d|rg |cffc7c7cf%d|rs |cffeda55f%d|rc", g, sv, cp)
end

local function fitScale(frame, height)
    local avail = UIParent:GetHeight() * 0.92
    local s = math.min(1, avail / math.max(height, 1))
    if math.abs(frame:GetScale() - s) > 0.005 then frame:SetScale(s) end
end

local function layout(w, groups, freeGroup)
    local c = cfg()
    local content = w.content
    local size, cols = c.slotSize, c.columns
    local step = size + GAP
    local width = cols * step - GAP
    local y = 0
    local used = {}
    local hi = 0

    local function header(key, label, count, kind, value)
        hi = hi + 1
        local h = w.headers[hi] or makeHeader(w, hi)
        h.key, h.kind = key, kind
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        h:SetSize(width, HEADER_H)
        local collapsed = not kind and c.collapsed[key]
        local r, g, b = 1, 0.82, 0
        if kind then r, g, b = 0.62, 0.62, 0.68 elseif isCustom(key) then r, g, b = 0.30, 0.82, 1 end
        h.text:SetTextColor(r, g, b)
        h.text:SetText((kind and "" or (collapsed and "+ " or "- ")) .. label .. (count and (" (" .. count .. ")") or "")
            .. ((value and value > 0) and ("   " .. moneyText(value)) or ""))
        h:Show()
        y = y + HEADER_H + 2
        return collapsed
    end

    local function place(items)
        for i, e in ipairs(items) do
            local btn = getButton(w, e.bag, e.slot)
            if btn then
                local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", content, "TOPLEFT", col * step, -(y + row * step))
                btn:SetSize(size, size)
                btn:Show()
                used[btn] = true
            end
        end
        y = y + math.ceil(#items / cols) * step + 4
    end

    for _, g in ipairs(groups) do
        local collapsed = header(g.key, sectionLabel(g.key), #g.items, nil, g.value)
        if not collapsed then place(g.items) end
    end
    if freeGroup then
        local tiles, sum = {}, 0
        for _, fg in ipairs(freeGroup) do
            tiles[#tiles + 1] = fg.items[1]
            sum = sum + fg.total
        end
        header("FREE", "Empty slots", sum, "free")
        place(tiles)
    end
    if dragging then
        header("NEW", "+ New section (drop an item here)", nil, "new")
        header("AUTO", "Automatic (drop an item here to reset it)", nil, "auto")
    end

    for _, t in pairs(w.buttons) do
        for _, btn in pairs(t) do
            if not used[btn] then btn:Hide() end
        end
    end
    for i = hi + 1, #w.headers do w.headers[i]:Hide() end

    content:SetSize(width, math.max(y, 1))
    local fw = math.max(width + 2 * PAD, w.spec.minWidth or 250)
    local fh = y + TOP_H + FOOT_H + PAD
    w.frame:SetSize(fw, fh)
    fitScale(w.frame, fh)
end

local function buildGroups(w, entries, empties)
    local byKey = {}
    for _, e in ipairs(entries) do
        local k = categoryOf(e)
        local g = byKey[k]
        if not g then g = { key = k, items = {} } byKey[k] = g end
        g.items[#g.items + 1] = e
    end
    local groups = {}
    local function add(key)
        local g = byKey[key]
        if g then
            table.sort(g.items, sortItems)
            if key == "JUNK" and ns.Vendor and ns.Vendor.SellPrice then
                g.value = 0
                for _, e in ipairs(g.items) do
                    if not e.info.hasNoValue then g.value = g.value + ns.Vendor.SellPrice(e.info) * e.count end
                end
            end
            groups[#groups + 1] = g
        elseif dragging then
            groups[#groups + 1] = { key = key, items = {} }
        end
    end
    for _, n in ipairs(cfg().sections) do add(customKey(n)) end
    for _, s in ipairs(SECTIONS) do add(s.key) end

    -- one real empty slot per bag kind stays visible so items can be dropped into the bags; it shows how many are free.
    -- Kinds: normal bags, quiver / ammo, reagent bag, profession bags. Regular bags first (they take any item).
    local kinds, list = {}, {}
    for _, e in ipairs(empties) do
        local kind, label, order = bagKind(e.bag, w.spec.slotLabel)
        local k = kinds[kind]
        if not k then
            k = { kind = kind, label = label, order = order, items = { e }, total = 0 }
            kinds[kind] = k
            list[#list + 1] = k
        end
        k.total = k.total + 1
    end
    table.sort(list, function(a, b) return a.order < b.order end)
    local free = #list > 0 and list or nil
    return groups, free
end

local function signature(groups, free)
    local c = cfg()
    local parts = { c.columns, c.slotSize, dragging and "d" or "n" }
    for _, g in ipairs(groups) do
        parts[#parts + 1] = g.key .. (c.collapsed[g.key] and "!" or ":") .. (g.value or "")
        if not c.collapsed[g.key] then
            for _, e in ipairs(g.items) do parts[#parts + 1] = e.bag .. "," .. e.slot end
        end
    end
    if free then
        for _, fg in ipairs(free) do parts[#parts + 1] = "f" .. fg.kind .. fg.items[1].bag .. "," .. fg.items[1].slot end
    end
    return table.concat(parts, " ")
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local Window = {}
Window.__index = Window

local function newWindow(spec)
    local w = setmetatable({ spec = spec, buttons = {}, bagFrames = {}, headers = {}, search = "",
                             refreshQueued = false }, Window)
    windows[#windows + 1] = w
    return w
end

function Window:IsOpen() return self.frame and self.frame:IsShown() or false end

function Window:Refresh()
    if not self:IsOpen() then return end
    local entries, empties = gather(self)
    local combat = InCombatLockdown()

    -- make sure every slot has a button (only possible out of combat)
    if not combat then
        for _, e in ipairs(entries) do getButton(self, e.bag, e.slot) end
        for _, e in ipairs(empties) do getButton(self, e.bag, e.slot) end
    end

    local groups, free = buildGroups(self, entries, empties)
    local sig = signature(groups, free)
    if sig ~= self.lastSig then
        if combat then
            ns:AfterCombat("custombags-" .. self.spec.key, function() self.lastSig = nil self:Refresh() end)
        else
            self.lastSig = sig
            layout(self, groups, free)
        end
    end

    for _, e in ipairs(entries) do
        local btn = self.buttons[e.bag] and self.buttons[e.bag][e.slot]
        if btn then
            btn.molFreeLabel = nil
            pcall(updateButton, self, btn, e)
        end
    end
    for _, e in ipairs(empties) do
        local btn = self.buttons[e.bag] and self.buttons[e.bag][e.slot]
        if btn then
            btn.molFreeLabel = nil
            pcall(updateButton, self, btn, e)
            if free and SetItemButtonCount then
                for _, fg in ipairs(free) do
                    if fg.items[1] == e then
                        SetItemButtonCount(btn, fg.total)
                        btn.molFreeLabel, btn.molFreeCount = fg.label .. " slot", fg.total
                    end
                end
            end
        end
    end

    local total = #entries + #empties
    self.footFree:SetText(string.format("%d / %d", #entries, total))
    if self.spec.money then self.footMoney:SetText(moneyText(GetMoney and GetMoney() or 0)) end
end

function Window:RequestRefresh()
    if self.refreshQueued or not self:IsOpen() then return end
    self.refreshQueued = true
    C_Timer.After(0, function()
        self.refreshQueued = false
        self:Refresh()
    end)
end

function Window:SavePosition()
    local point, _, rel, x, y = self.frame:GetPoint()
    if point then cfg()[self.spec.posKey] = { point = point, rel = rel, x = x, y = y } end
end

function Window:ApplyPosition()
    local p = cfg()[self.spec.posKey]
    local f = self.frame
    f:ClearAllPoints()
    if p then
        f:SetPoint(p.point, UIParent, p.rel, p.x, p.y)
    else
        local d = self.spec.defaultPos
        f:SetPoint(d[1], UIParent, d[1], d[2], d[3])
    end
end

local function sound(kind)
    pcall(function()
        if SOUNDKIT then PlaySound(kind == "open" and SOUNDKIT.IG_BACKPACK_OPEN or SOUNDKIT.IG_BACKPACK_CLOSE) end
    end)
end

function Window:Build()
    if self.frame then return true end
    if InCombatLockdown() then return false end
    local spec = self.spec
    local frame = UI.Box(UIParent, { 0.04, 0.04, 0.05, ns.db.bagwindows.bgAlpha or 0.92 })
    self.frame = frame
    _G[spec.name] = frame
    table.insert(UISpecialFrames, spec.name)
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    frame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        self:SavePosition()
    end)
    frame:SetScript("OnShow", function()
        if spec.sound then sound("open") end
        self.lastSig = nil
        self:Refresh()
    end)
    frame:SetScript("OnHide", function()
        if spec.sound then sound("close") end
        if self.searchBox then self.searchBox:ClearFocus() end
        if spec.onHide then spec.onHide() end
    end)
    frame:Hide()
    self:ApplyPosition()

    local title = UI.Text(frame, spec.title, "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", PAD + 2, -8)

    local close = UI.Button(frame, "X", 22, 20, function() frame:Hide() end)
    close:SetPoint("TOPRIGHT", -6, -6)
    local sort = UI.Button(frame, "Sort", 46, 20, function() pcall(spec.sort) end)
    sort:SetPoint("RIGHT", close, "LEFT", -4, 0)
    local left = sort
    for _, make in ipairs(spec.buttons or {}) do
        local b = make(frame)
        if b then
            b:SetPoint("RIGHT", left, "LEFT", -4, 0)
            left = b
        end
    end

    local searchBox = CreateFrame("EditBox", nil, frame)
    self.searchBox = searchBox
    searchBox:SetFontObject("GameFontHighlight")
    pcall(searchBox.SetFont, searchBox, ns.DEFAULT_FONT, 13, "")
    searchBox:SetAutoFocus(false)
    searchBox:SetHeight(20)
    searchBox:SetPoint("TOPLEFT", PAD, -32)
    searchBox:SetPoint("TOPRIGHT", -PAD, -32)
    searchBox:SetTextInsets(6, 6, 0, 0)
    searchBox.bg = searchBox:CreateTexture(nil, "BACKGROUND")
    searchBox.bg:SetAllPoints()
    searchBox.bg:SetColorTexture(unpack(UI.colors.panel))
    UI.AddBorder(searchBox, 1, 0, 0, 0, 1)
    searchBox.hint = UI.Text(searchBox, "Search", "GameFontDisable", "LEFT")
    searchBox.hint:SetPoint("LEFT", 6, 0)
    searchBox:SetScript("OnEscapePressed", function(b) b:SetText("") b:ClearFocus() end)
    searchBox:SetScript("OnEnterPressed", function(b) b:ClearFocus() end)
    searchBox:SetScript("OnTextChanged", function(b)
        self.search = (b:GetText() or ""):lower()
        b.hint:SetShown(self.search == "")
        self:Refresh()
    end)

    local content = CreateFrame("Frame", nil, frame)
    self.content = content
    content:SetPoint("TOPLEFT", PAD, -TOP_H)
    content:SetSize(10, 10)

    self.footMoney = UI.Text(frame, "", "GameFontHighlight", "LEFT")
    self.footMoney:SetPoint("BOTTOMLEFT", PAD + 2, 8)
    self.footFree = UI.Text(frame, "", "GameFontHighlight", "RIGHT")
    self.footFree:SetPoint("BOTTOMRIGHT", -PAD - 2, 8)
    self.footFree:SetTextColor(unpack(UI.colors.dim))
    return true
end

function Window:Open()
    if not self:Build() then return false end
    self.frame:Show()
    return true
end

function Window:Close()
    if self.frame then self.frame:Hide() end
end

----------------------------------------------------------------------
-- The two windows
----------------------------------------------------------------------
local bags = newWindow({
    key = "bags", name = "ModernUIBagFrame", title = "Bags", posKey = "position", defaultPos = { "BOTTOMRIGHT", -70, 110 },
    bags = playerBags, slotLabel = "Bag", money = true, sound = true,
    sort = function()
        if C_Container and C_Container.SortBags then C_Container.SortBags() elseif SortBags then SortBags() end
    end,
    buttons = { function(parent) return ns.Vendor and ns.Vendor.CreateTrashButton and ns.Vendor:CreateTrashButton(parent, 46, 20) end },
    onHide = function() if C_NewItems and C_NewItems.ClearAll then pcall(C_NewItems.ClearAll) end end,
})

-- Bank: Blizzard's bank window has to stay shown while the bank is open (hiding it ends the visit), so it is faded
-- and parked off screen instead. "Blizzard" in the title bar brings it back for this visit (buying bank tabs or
-- slots, the warband bank, ...).
local bankOpen = false     -- at a banker
local blizzBank = false    -- Blizzard's bank window wanted for this visit
local parked               -- Blizzard's bank window anchors before it was parked

local function bankActive() return CB.active and cfg().bank ~= false and not blizzBank end

local function parkBankFrame()
    local f = _G.BankFrame
    if not (f and f:IsShown() and bankOpen and bankActive()) then return end
    if not parked then
        parked = { clamped = f:IsClampedToScreen() }
        for i = 1, f:GetNumPoints() do parked[i] = { f:GetPoint(i) } end
    end
    f:SetAlpha(0)
    f:SetClampedToScreen(false)
    f:ClearAllPoints()
    f:SetPoint("TOPRIGHT", UIParent, "TOPLEFT", -5000, 0)
end

local function unparkBankFrame()
    local f = _G.BankFrame
    local p = parked
    parked = nil
    if not (f and p) then return end
    f:ClearAllPoints()
    for _, pt in ipairs(p) do f:SetPoint(unpack(pt)) end
    f:SetClampedToScreen(p.clamped)
    f:SetAlpha(1)
end

local function closeBank()
    if C_Bank and C_Bank.CloseBankFrame then pcall(C_Bank.CloseBankFrame)
    elseif CloseBankFrame then pcall(CloseBankFrame)
    elseif _G.BankFrame and HideUIPanel then pcall(HideUIPanel, _G.BankFrame) end
end

local bank
local function showBlizzardBank()
    blizzBank = true
    unparkBankFrame()
    bank:Close()
end

local function blizzardButton(parent)
    local b = UI.Button(parent, "Blizzard", 62, 20, showBlizzardBank)
    b:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Blizzard's bank window", 1, 1, 1)
        GameTooltip:AddLine("For buying bank slots or tabs and the warband bank. Back to this window next visit.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

bank = newWindow({
    key = "bank", name = "ModernUIBankFrame", title = "Bank", posKey = "bankPosition", defaultPos = { "TOPLEFT", 40, -120 },
    bags = bankBags, slotLabel = "Bank", minWidth = 300,
    sort = function()
        if C_Container and C_Container.SortBank and Enum and Enum.BankType then C_Container.SortBank(Enum.BankType.Character)
        elseif C_Container and C_Container.SortBankBags then C_Container.SortBankBags()
        elseif SortBankBags then SortBankBags() end
    end,
    buttons = {
        function(parent) return ns.Vendor and ns.Vendor.CreateDepositButton and ns.Vendor:CreateDepositButton(parent, 60, 20) end,
        blizzardButton,
    },
    -- closing this window (X, Escape) leaves the bank, unless Blizzard's window took over
    onHide = function() if bankOpen and not blizzBank then closeBank() end end,
})

local function openBank()
    if not (bankOpen and bankActive()) then return end
    if bank:Open() then
        parkBankFrame()
    elseif _G.BankFrame then
        -- buttons cannot be made in combat: Blizzard's window (faded on show) stays
        _G.BankFrame:SetAlpha(1)
    end
end

local function onBankOpened()
    bankOpen, blizzBank = true, false
    openBank()
end

local function onBankClosed()
    bankOpen = false
    unparkBankFrame()
    bank:Close()
    blizzBank = false
end

local bankHooked = false
local function hookBankFrame()
    local f = _G.BankFrame
    if bankHooked or not (f and f.HookScript) then return end
    bankHooked = true
    -- fade at once (no flash), park once Blizzard's panel layout has placed it
    f:HookScript("OnShow", function(self)
        if bankOpen and bankActive() then
            self:SetAlpha(0)
            C_Timer.After(0, openBank)
        end
    end)
    if type(_G.UpdateUIPanelPositions) == "function" then
        hooksecurefunc("UpdateUIPanelPositions", function() if parked then parkBankFrame() end end)
    end
end

-- Cursor carrying an item: show every section (and the "new section" drop target) so it can be dropped on one.
local function onCursor()
    local kind = GetCursorInfo()
    local now = kind == "item"
    if now ~= dragging then
        dragging = now
        requestAll()
    end
end

----------------------------------------------------------------------
-- Replacing the bag open / close functions
----------------------------------------------------------------------
local installed = false

function CB:IsOpen() return bags:IsOpen() end
function CB:Open() return bags:Open() end
function CB:Close() bags:Close() end

function CB:Toggle()
    if bags:IsOpen() then bags:Close() return true end
    return bags:Open()
end

function CB:Refresh() refreshAll() end

-- Post-hooks only: replacing Blizzard globals (OpenAllBags etc.) with addon
-- functions taints the secure path that opens the bank / merchant / mail and
-- gives "action only available to the Blizzard UI". Let Blizzard open its own
-- frames, then hide them and show ours instead.
local hiding = 0
local function hideBlizzardBags()
    hiding = hiding + 1
    local list = { _G.ContainerFrameCombinedBags }
    for i = 1, 13 do list[#list + 1] = _G["ContainerFrame" .. i] end
    for _, f in ipairs(list) do
        if f and f:IsShown() and (f == _G.ContainerFrameCombinedBags or inRange(f:GetID())) then
            pcall(f.Hide, f)
        end
    end
    hiding = hiding - 1
end

-- Blizzard's Toggle*/Open* call each other and per-bag functions, so one key press fires several
-- hooks (inner ones first, the outermost last). Collect them and act once next frame: the last
-- intent wins, and "toggle" is relative to our state before the first hook.
local pending
local function resolve()
    local p = pending
    pending = nil
    if not p or not CB.active then return end
    if p.kind == "open" then CB:Open()
    elseif p.kind == "close" then CB:Close()
    elseif p.was then CB:Close()
    else CB:Open() end
end

local function post(name, kind, ranged)
    if type(_G[name]) ~= "function" then return end
    hooksecurefunc(name, function(id)
        if not CB.active or hiding > 0 then return end
        if ranged and not inRange(id) then return end
        if not pending then
            pending = { was = CB:IsOpen() }
            C_Timer.After(0, resolve)
        end
        pending.kind = kind
        hideBlizzardBags()
    end)
end

local function install()
    if installed then return end
    installed = true
    for _, n in ipairs({ "ToggleAllBags", "ToggleBackpack" }) do post(n, "toggle") end
    for _, n in ipairs({ "OpenAllBags", "OpenBackpack" }) do post(n, "open") end
    for _, n in ipairs({ "CloseAllBags", "CloseBackpack" }) do post(n, "close") end
    post("ToggleBag", "toggle", true)
    post("OpenBag", "open", true)
    post("CloseBag", "close", true)
    local list = { _G.ContainerFrameCombinedBags }
    for i = 1, 13 do list[#list + 1] = _G["ContainerFrame" .. i] end
    for _, f in ipairs(list) do
        if f and f.HookScript then
            f:HookScript("OnShow", function() if CB.active then hideBlizzardBags() end end)
        end
    end
    hookBankFrame()
end

function CB:Clear()
    if not ns.db then return end
    cfg().pins = {}
    refreshAll()
end

function CB:Apply()
    if not ns.db then return end
    if cfg().enabled then
        install()
        CB.active = true
    else
        CB.active = false
        bags:Close()
    end
    -- at the bank right now: switch to whichever bank window the settings ask for
    if bankOpen then
        if bankActive() then openBank()
        elseif bank:IsOpen() or parked then showBlizzardBank() end
    end
    for _, w in ipairs(windows) do
        if w.frame then w.frame.bg:SetColorTexture(0.04, 0.04, 0.05, ns.db.bagwindows.bgAlpha or 0.92) end
    end
    refreshAll()
end

function CB:Init()
    for _, e in ipairs({ "BAG_UPDATE", "BAG_UPDATE_DELAYED", "ITEM_LOCK_CHANGED", "BAG_UPDATE_COOLDOWN",
                         "PLAYER_MONEY", "BAG_NEW_ITEMS_UPDATED", "PLAYERBANKSLOTS_CHANGED",
                         "PLAYERBANKBAGSLOTS_CHANGED", "BANK_TABS_CHANGED", "BANK_TAB_SETTINGS_UPDATED" }) do
        ns:On(e, requestAll)
    end
    ns:On("CURSOR_CHANGED", onCursor)
    ns:On("BANKFRAME_OPENED", onBankOpened)
    ns:On("BANKFRAME_CLOSED", onBankClosed)
    if cfg().enabled then
        install()
        CB.active = true
    end
end
