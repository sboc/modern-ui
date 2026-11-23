local ADDON, ns = ...
local UI = ns.UI

-- Buff reminder: an icon per buff of your class that is missing or about to run out, on yourself and (optionally)
-- on party / raid members in range. Party and raid checks are off by default. Only for buffs you know; each one
-- can be switched off in the options. Other units' auras can be unreadable on this client: a unit whose auras
-- cannot be read is skipped, never reported as "missing". Hidden in combat, while dead, while resting (inn, city)
-- and while fishing (plus a few seconds after each cast, so it does not flash up between casts).
-- One more row for food: you are not Well Fed while the Food macro's pick gives a buff (ns.Consumables.buffFood).
-- Custom reminders (buffreminder.custom, added in the options by spell id or buff name): checked on you only, shown
-- whether or not you know a spell for them (elixirs, scrolls, other classes' buffs).
-- Clicking a row hides it for buffreminder.snooze minutes, or until it has nothing left to remind of (the buff is
-- back, you are Well Fed), whichever comes first. Not saved: a /reload shows it again.
local R = ns:NewModule("buffreminder")
ns.BuffReminder = R

-- One entry per reminder. spells: the buffs you can cast for it, first known one is shown (so Demon Armor wins over
-- Demon Skin once trained); any of them counts as present. also: other buffs that count too (Gift of the Wild covers
-- Mark of the Wild). selfOnly: never checked on group members (armors, auras, aspects). label: shown instead of the
-- spell name when the spells are a choice (any aura does). The first spell id is the key for the on/off setting.
-- Names come from the spell ids so they follow the client language; fallback only for the first spell.
-- weapon: a temporary weapon enchant instead of a buff (Firestone, shaman weapon imbues, poisons), read with
-- GetWeaponEnchantInfo; "main" = main hand only, "both" = every hand holding a weapon (not a shield / off-hand item).
-- spells are what tells that you can make it (Create Firestone, the imbue, the Poisons skill); any enchant counts.
-- Not here: Battle Shout (2 minutes, cast in combat, so it would show the whole time out of combat), Omen of
-- Clarity (a proc on this client, not a buff you keep up).
local BUFFS = {
    DRUID = {
        { spells = { 1126 }, also = { 21849 }, fallback = "Mark of the Wild" },
        { spells = { 467 }, fallback = "Thorns" },
    },
    PRIEST = {
        { spells = { 1243 }, also = { 21562 }, fallback = "Power Word: Fortitude" },
        { spells = { 14752 }, also = { 27681 }, fallback = "Divine Spirit" },
        { spells = { 976 }, also = { 27683 }, fallback = "Shadow Protection" },
        { spells = { 588 }, selfOnly = true, fallback = "Inner Fire" },
    },
    MAGE = {
        { spells = { 1459 }, also = { 23028 }, fallback = "Arcane Intellect" },
        { spells = { 6117, 7302, 168 }, selfOnly = true, label = "Armor", fallback = "Frost Armor" },
    },
    WARLOCK = {
        { spells = { 706, 687 }, selfOnly = true, fallback = "Demon Skin" },
        { spells = { 6366, 2362 }, weapon = "main", selfOnly = true, label = "Firestone / Spellstone",
          fallback = "Create Firestone" },
    },
    ROGUE = {
        { spells = { 2842 }, weapon = "both", selfOnly = true, label = "Poison", fallback = "Poisons" },
    },
    PALADIN = {
        { spells = { 465, 7294, 19746, 19876, 19888, 19891, 20218 }, selfOnly = true, label = "Aura", fallback = "Devotion Aura" },
        { spells = { 19740, 19742, 20217, 1038, 19977, 20911 }, also = { 25782, 25894, 25898, 25895, 25890, 25899 },
          selfOnly = true, label = "Blessing", fallback = "Blessing of Might" },
    },
    HUNTER = {
        { spells = { 13165, 13163, 5118, 13159, 20043, 13161 }, selfOnly = true, label = "Aspect", fallback = "Aspect of the Hawk" },
        { spells = { 19506 }, selfOnly = true, fallback = "Trueshot Aura" },
    },
    SHAMAN = {
        { spells = { 324 }, selfOnly = true, fallback = "Lightning Shield" },
        { spells = { 8017, 8024, 8033, 8232 }, weapon = "both", selfOnly = true, label = "Weapon imbue",
          fallback = "Rockbiter Weapon" },
    },
}

local frame, rows
local getRow
local entries     -- the buffs of this class, resolved: { key, spells, names = {...}, selfOnly, label, title }
local customs     -- the custom reminders, resolved: { key, custom = true, spells, names, selfOnly, title, icon }
local NONE = {}
local dismissed = {}   -- entry key ("food" for the food row) -> GetTime() when the clicked-away row may show again
local elapsed = 0

local function cfg() return ns.db.buffreminder end

local function spellName(id, fallback)
    local n
    if C_Spell and C_Spell.GetSpellName then n = C_Spell.GetSpellName(id) elseif GetSpellInfo then n = GetSpellInfo(id) end
    return n or fallback
end

local function spellTexture(id)
    if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(id) end
    if GetSpellTexture then return GetSpellTexture(id) end
end

local function known(id)
    if IsPlayerSpell then return IsPlayerSpell(id) end
    if IsSpellKnown then return IsSpellKnown(id) end
    return true
end

local function resolve()
    if entries then return entries end
    entries = {}
    local _, class = UnitClass("player")
    for _, b in ipairs(BUFFS[class] or {}) do
        local names, spells = {}, {}
        for i, id in ipairs(b.spells) do
            local n = spellName(id, i == 1 and b.fallback or nil)
            if n then names[n] = true; spells[#spells + 1] = n end
        end
        for _, id in ipairs(b.also or {}) do
            local n = spellName(id)
            if n then names[n] = true end
        end
        entries[#entries + 1] = { key = b.spells[1], spells = b.spells, names = names, selfOnly = b.selfOnly,
                                  weapon = b.weapon, label = b.label, title = b.label or table.concat(spells, " / ") }
    end
    return entries
end

-- a custom reminder as saved (spell id or buff name) -> its entry; the name is the client's spelling when the
-- client knows the spell, else as typed (it must match the buff's name)
local function customEntry(v)
    local id = type(v) == "number" and v or nil
    local name = id and spellName(id) or (not id and spellName(v)) or (not id and v) or nil
    if not name then return nil end
    local icon = (id and spellTexture(id)) or spellTexture(name) or 134400   -- question mark
    return { key = "custom:" .. tostring(v), custom = true, spells = { id }, names = { [name] = true }, selfOnly = true,
             title = name, icon = icon }
end

local function resolveCustom()
    if customs then return customs end
    customs = {}
    for _, v in ipairs(cfg().custom or NONE) do
        local e = customEntry(v)
        if e then customs[#customs + 1] = e end
    end
    return customs
end

-- the spell of the entry you would cast: first known one, nil = none trained
local function knownSpell(e)
    if e.custom then return e.spells[1] or 0 end   -- shown whether known or not; 0 = no spell id, only a name
    for _, id in ipairs(e.spells) do
        if known(id) then return id end
    end
end

-- the buffs of your class for the options: { key, title }; the setting is buffreminder.off[key]
function R:ClassBuffs()
    return resolve()
end

-- the custom reminders for the options: { key, title, icon } in the order of buffreminder.custom
function R:CustomBuffs()
    customs = nil   -- the options page is rebuilt right after a change, before the module applies it
    return resolveCustom()
end

-- the name of a spell id (nil when the client does not know the id), for checking what is typed in the options
function R:SpellName(id)
    return spellName(id)
end

-- seconds left of the buff on the unit: 0 = missing, math.huge = no expiry, nil = auras of the unit unreadable.
-- A group member without any aura counts as unreadable; your own auras are readable out of combat (the only time
-- this runs), so no aura at all on you means missing.
local function timeLeft(unit, e)
    local now, readable, best = GetTime(), unit == "player", 0
    for i = 1, 40 do
        local a = ns.GetAuraAt(unit, i, "HELPFUL", true)
        if not a then break end
        local name = a.name
        if ns.IsSecret(name) or type(name) ~= "string" then return nil end
        readable = true
        if e.names[name] then
            local exp, dur = a.expirationTime, a.duration
            if ns.IsSecret(exp) or ns.IsSecret(dur) then return nil end
            local left = (not exp or exp == 0 or not dur or dur == 0) and math.huge or exp - now
            if left > best then best = left end
        end
    end
    if not readable then return nil end
    return best
end

-- true when the slot holds a weapon (a shield or an off-hand item takes no weapon enchant)
local function holdsWeapon(slot)
    local id = GetInventoryItemID("player", slot)
    if not id then return false end
    local info = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not info then return slot == 16 end
    local _, _, _, _, _, classID = info(id)
    return classID == 2   -- Enum.ItemClass.Weapon
end

-- seconds left of the weapon enchant of the entry, lowest of the hands it covers: 0 = missing, nil = no weapon
-- to check (or unreadable); second value: "main" / "off", the hand it is about
local function weaponLeft(e)
    if not GetWeaponEnchantInfo then return nil end
    local ok, hasMain, mainMs, _, _, hasOff, offMs = pcall(GetWeaponEnchantInfo)
    if not ok or ns.IsSecret(hasMain) or ns.IsSecret(hasOff) or ns.IsSecret(mainMs) or ns.IsSecret(offMs) then
        return nil
    end
    local best, hand
    local function check(slot, has, ms, which)
        if not holdsWeapon(slot) then return end
        local left = has and (ms or 0) / 1000 or 0
        if not best or left < best then best, hand = left, which end
    end
    check(16, hasMain, mainMs, "main")
    if e.weapon == "both" then check(17, hasOff, offMs, "off") end
    return best, hand
end

local function fmt(s)
    return s >= 60 and string.format("%d:%02d", s / 60, s % 60) or string.format("%ds", s)
end

local function groupUnits(c)
    local list = {}
    if IsInRaid() then
        if c.raid then
            for i = 1, GetNumGroupMembers() do list[#list + 1] = "raid" .. i end
        end
    elseif c.party and IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do list[#list + 1] = "party" .. i end
    end
    return list
end

local function inReach(unit)
    if not UnitExists(unit) or UnitIsUnit(unit, "player") or not UnitIsConnected(unit) or UnitIsDeadOrGhost(unit) then return false end
    if not UnitIsVisible(unit) then return false end
    if UnitInRange then
        local inRange, checked = UnitInRange(unit)
        if checked and not inRange then return false end
    end
    return true
end

-- the food row: a pseudo entry for timeLeft, names filled on first use (spell names can be missing at load)
local FOOD = { names = {} }
local function foodRow(c)
    local food = c.food and ns.Consumables and ns.Consumables.buffFood
    if not food then return end
    if not next(FOOD.names) then   -- while eating ("Food") counts too, Well Fed only comes after 10 seconds
        FOOD.names[spellName(19705, "Well Fed")] = true
        FOOD.names[spellName(433, "Food")] = true
    end
    local left = timeLeft("player", FOOD)
    if not left or left >= math.max(c.threshold, 1) then return end
    local getIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
    local name = food.link:match("%[(.-)%]") or "food"
    return (left == 0 and "Not Well Fed" or "Well Fed: " .. fmt(left)) .. " (eat " .. name .. ")",
           getIcon and getIcon(food.itemID)
end

-- fishing: the channel's name (every rank is called "Fishing"); the reminder stays away FISHING_GRACE seconds
-- after a cast ends, the time it takes to loot and cast again
local FISHING_GRACE = 10
local fishedAt
local function fishing()
    local name = UnitChannelInfo and UnitChannelInfo("player")
    if type(name) == "string" and not (issecretvalue and issecretvalue(name)) and name == spellName(7620, "Fishing") then
        fishedAt = GetTime()
    end
    return fishedAt ~= nil and GetTime() - fishedAt < FISHING_GRACE
end

-- true while a clicked-away row stays hidden; the snooze ends early once the row has nothing to show
local function snoozed(key, text)
    local untilTime = dismissed[key]
    if not untilTime then return false end
    if not text or GetTime() >= untilTime then dismissed[key] = nil return false end
    return true
end

local function refresh()
    if not frame then return end
    local c = cfg()
    local list = {}
    for _, e in ipairs(resolve()) do list[#list + 1] = e end
    for _, e in ipairs(resolveCustom()) do list[#list + 1] = e end
    if not c.enabled or UnitAffectingCombat("player") or UnitIsDeadOrGhost("player")
       or (IsResting and IsResting()) or fishing() then
        frame:Hide()
        return
    end
    local units = groupUnits(c)
    local shown = 0
    for i, e in ipairs(list) do
        local text
        local id = not (c.off and c.off[e.key]) and knownSpell(e)
        if id then
            local own
            if c.self then
                local left, hand
                if e.weapon then left, hand = weaponLeft(e) else left = timeLeft("player", e) end
                if left and left < math.max(c.threshold, 1) then
                    own = left == 0 and "missing" or fmt(left)
                    if e.weapon == "both" then own = hand .. " hand " .. own end
                end
            end
            local missing = 0
            for _, u in ipairs(e.selfOnly and NONE or units) do
                if inReach(u) then
                    local left = timeLeft(u, e)
                    if left and left < math.max(c.threshold, 1) then missing = missing + 1 end
                end
            end
            if own or missing > 0 then
                text = e.label or (e.custom and e.title) or spellName(id, e.title)
                if own then text = text .. ": " .. own end
                if missing > 0 then text = text .. (own and "  " or ": ") .. missing .. " in group" end
            end
        end
        if snoozed(e.key, text) then text = nil end
        local row = getRow(i)
        row.key = e.key
        if text then
            shown = shown + 1
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(shown - 1) * (c.size + 4))
            row.icon:SetTexture(e.icon or spellTexture(id))
            row.text:SetText(text)
            row:Show()
        else
            row:Hide()
        end
    end
    for i = #list + 2, #rows do rows[i]:Hide() end   -- rows of removed custom reminders
    local row = getRow(#list + 1)
    row.key = "food"
    local text, icon = foodRow(c)
    if snoozed("food", text) then text = nil end
    if text then
        shown = shown + 1
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(shown - 1) * (c.size + 4))
        row.icon:SetTexture(icon)
        row.text:SetText(text)
        row:Show()
    else
        row:Hide()
    end
    frame:SetShown(shown > 0)
end

local function layoutRow(row)
    local c = cfg()
    row:SetSize(c.size + 8 + 220, c.size)
    row.icon:SetSize(c.size, c.size)
    ns:SetFont(row.text, math.max(10, math.floor(c.size * 0.45)), "OUTLINE")
end

local function layout()
    local c = cfg()
    frame:SetScale(c.scale * ns.db.general.scale)
    frame:SetSize(c.size + 8 + 220, c.size)
    for _, row in ipairs(rows) do layoutRow(row) end
end

-- rows are made as needed (class buffs + custom reminders + the food row); refresh sets each row's key
function getRow(i)
    local row = rows[i]
    if not row then
        row = CreateFrame("Frame", nil, frame)
        row:EnableMouse(true)
        row:SetScript("OnMouseUp", function(self)
            dismissed[self.key] = GetTime() + (cfg().snooze or 5) * 60
            GameTooltip:Hide()
            refresh()
        end)
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(string.format("Click to hide this reminder for %d min", cfg().snooze or 5), 1, 1, 1)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetPoint("LEFT")
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        UI.AddBorder(row, 1, 0, 0, 0, 1, "OVERLAY")
        row.text = row:CreateFontString(nil, "OVERLAY")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
        row.text:SetJustifyH("LEFT")
        row:Hide()
        rows[i] = row
        layoutRow(row)
    end
    return row
end

local function build()
    frame = CreateFrame("Frame", "ModernUIBuffReminder", UIParent)
    frame:SetFrameStrata("HIGH")
    rows = {}
    -- own driver: a hidden frame gets no OnUpdate. One scan a second also covers buff expiry and the roster's auras
    CreateFrame("Frame"):SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 1 then elapsed = 0; refresh() end
    end)
    for _, e in ipairs({ "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "SPELLS_CHANGED",
                         "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST",
                         "PLAYER_UPDATE_RESTING" }) do
        ns:On(e, refresh)
    end
    ns:On("UNIT_SPELLCAST_CHANNEL_START", function(_, unit) if unit == "player" then refresh() end end)
    ns.Mover:Register("buffreminder", frame, "Buff Reminder")
end

function R:Apply()
    if not ns.db then return end
    if not frame then build() end
    customs = nil   -- the list may have changed in the options
    layout()
    ns.Mover:Position("buffreminder")
    refresh()
end
