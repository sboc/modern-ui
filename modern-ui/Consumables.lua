local ADDON, ns = ...

-- Consumables: keeps three global macros ("Food", "Water", "Health Potion", shared by all characters) pointed at the best
-- food / drink / health potion in your bags. The potion pick is simply the biggest heal you can use at your level.
-- "Best" = the user's stat priority list first (attack power, spell power, ...), then the bigger buff, then the bigger
-- restore, then the higher level item. Items above your level are ignored. Macros can only be edited out of
-- combat, so updates made in combat are queued until it ends.
local K = ns:NewModule("consumables")
ns.Consumables = K

K.MACROS = { food = "Food", water = "Water", healthpot = "Health Potion" }
local KINDS = { "food", "water", "healthpot" }
local KIND_LABEL = { food = "Food", water = "Water", healthpot = "Health potion" }
local OLD_MACROS = { food = "MolFood", water = "MolWater" }   -- renamed in place if still around

-- key, label, tooltip fragments (lowercase, plain text match). First matching fragment wins.
K.CATEGORIES = {
    { key = "ATTACK_POWER", label = "Attack power",          find = { "attack power" } },
    { key = "SPELL_POWER",  label = "Spell power / damage",  find = { "spell power", "spell damage", "damage and healing" } },
    { key = "HEALING",      label = "Healing power",         find = { "healing done", "healing power", "bonus healing" } },
    { key = "STRENGTH",     label = "Strength",              find = { "strength" } },
    { key = "AGILITY",      label = "Agility",               find = { "agility" } },
    { key = "INTELLECT",    label = "Intellect",             find = { "intellect" } },
    { key = "SPIRIT",       label = "Spirit",                find = { "spirit" } },
    { key = "STAMINA",      label = "Stamina",               find = { "stamina" } },
    { key = "MP5",          label = "Mana per 5 sec",        find = { "mana per 5", "mana every 5", "mp5" } },
    { key = "CRIT",         label = "Critical strike",       find = { "critical strike" } },
    { key = "HASTE",        label = "Haste",                 find = { "haste" } },
    { key = "MASTERY",      label = "Mastery",               find = { "mastery" } },
    { key = "VERSATILITY",  label = "Versatility",           find = { "versatility" } },
}
local catByKey = {}
for _, c in ipairs(K.CATEGORIES) do catByKey[c.key] = c end

-- default order, best first (disabled categories simply do not count as a bonus)
K.DEFAULT_PRIORITY = {
    food  = { "ATTACK_POWER", "SPELL_POWER", "HEALING", "STRENGTH", "AGILITY", "INTELLECT", "STAMINA", "SPIRIT",
              "MP5", "CRIT", "HASTE", "MASTERY", "VERSATILITY" },
    water = { "INTELLECT", "SPIRIT", "SPELL_POWER", "HEALING", "MP5", "STAMINA", "ATTACK_POWER", "STRENGTH", "AGILITY",
              "CRIT", "HASTE", "MASTERY", "VERSATILITY" },
}

local function cfg() return ns.db.consumables end

----------------------------------------------------------------------
-- Tooltip text (cached per item id)
----------------------------------------------------------------------
local textCache = {}
local tries = {}
local scanTip

local function lineText(t)
    if type(t) ~= "string" or ns.IsSecret(t) then return nil end
    return t
end

local function readTooltip(link)
    local lines = {}
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
        if ok and type(data) == "table" and type(data.lines) == "table" then
            if TooltipUtil and TooltipUtil.SurfaceArgs then pcall(TooltipUtil.SurfaceArgs, data) end
            for _, line in ipairs(data.lines) do
                if TooltipUtil and TooltipUtil.SurfaceArgs then pcall(TooltipUtil.SurfaceArgs, line) end
                local t = lineText(line.leftText)
                if t then lines[#lines + 1] = t end
            end
            if #lines > 0 then return lines end
        end
    end
    -- fallback: hidden tooltip
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "ModernUIConsumableScan", UIParent, "GameTooltipTemplate")
    end
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    local ok = pcall(scanTip.SetHyperlink, scanTip, link)
    if ok then
        for i = 1, scanTip:NumLines() do
            local fs = _G["ModernUIConsumableScanTextLeft" .. i]
            local t = fs and lineText(fs:GetText())
            if t then lines[#lines + 1] = t end
        end
    end
    return lines
end

-- lowercase tooltip body without the item name; nil while the tooltip is not loaded yet
local function tooltipText(itemID, link)
    local c = textCache[itemID]
    if c then return c end
    local lines = readTooltip(link)
    if #lines < 2 then return nil end
    table.remove(lines, 1)
    c = table.concat(lines, " "):lower()
    -- a half-loaded tooltip (name + level, no "Use:" line yet) must not be cached, or the item stays "not food" all session
    -- (after a few tries accept it: some items genuinely have no restore text)
    if not (c:find("health", 1, true) or c:find("mana", 1, true)) then
        tries[itemID] = (tries[itemID] or 0) + 1
        if tries[itemID] < 5 then return nil end
    end
    textCache[itemID] = c
    return c
end

----------------------------------------------------------------------
-- Classification
----------------------------------------------------------------------
local function number(text, pattern)
    local n = text:match(pattern)
    return n and tonumber(n) or nil
end

-- the number that belongs to a stat: "12 Stamina and Spirit" or "attack power by 20"
local function statAmount(text, fragment)
    local f = fragment:gsub("%p", "%%%0")
    return number(text, "(%d+)%s*[%a%s,']-" .. f) or number(text, f .. "[%a%s,']-(%d+)") or 0
end

-- { food = bool, water = bool, healthAmt, manaAmt, cats = { KEY = amount } } or nil if not food / drink
local function classify(itemID, link)
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not getInstant then return end
    local _, _, _, _, _, classID, subClassID = getInstant(link)
    local consumable = (Enum and Enum.ItemClass and Enum.ItemClass.Consumable) or 0
    local isPotion = subClassID == 1
    if classID ~= consumable or (subClassID ~= 5 and not isPotion) then return end   -- 5 = Food & Drink, 1 = Potion

    local text = tooltipText(itemID, link)
    if not text then return nil, true end   -- not loaded yet

    if isPotion then
        -- "Restores 1050 to 1750 health" (range, averaged) or "Restores 700 health"
        local lo, hi = text:match("restores (%d+) to (%d+) health")
        local amt = lo and (tonumber(lo) + tonumber(hi)) / 2 or number(text, "restores (%d+) health") or 0
        if amt <= 0 or text:find(" over ", 1, true) then return end   -- not an instant heal
        return { healthpot = true, healthAmt = amt, manaAmt = number(text, "restores %d+ to (%d+) mana")
                 or number(text, "restores (%d+) mana") or 0, cats = {} }
    end

    local info = {
        healthAmt = number(text, "restores (%d+) health") or number(text, "(%d+) health over") or 0,
        manaAmt = number(text, "restores (%d+) mana") or number(text, "(%d+) mana over") or 0,
        cats = {},
    }
    info.food = info.healthAmt > 0
    info.water = info.manaAmt > 0
    if not info.food and not info.water then return end

    -- stat text lives after the restore part; check the whole tooltip, the restore numbers are never a stat keyword
    for _, c in ipairs(K.CATEGORIES) do
        for _, frag in ipairs(c.find) do
            if text:find(frag, 1, true) then
                info.cats[c.key] = statAmount(text, frag)
                break
            end
        end
    end
    return info
end

----------------------------------------------------------------------
-- Choosing
----------------------------------------------------------------------
local function bagRange()
    return 0, (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 1)
end

local function numSlots(bag)
    local fn = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    return fn and fn(bag) or 0
end

local function slotInfo(bag, slot)
    local api = C_Container and C_Container.GetContainerItemInfo
    if not api then return end
    local ok, info = pcall(api, bag, slot)
    if ok and type(info) == "table" then return info end
end

-- nil while item data is not loaded yet
local function itemMinLevel(link)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local ok, _, _, _, _, minLevel = pcall(getInfo, link)
    return (ok and type(minLevel) == "number") and minLevel or nil
end

-- priority: { rank = { KEY = position } } built from the enabled categories of one list
local function buildRank(kind)
    local c = cfg()[kind]
    local rank, n = {}, 0
    for _, key in ipairs(c.priority) do
        if catByKey[key] and not c.disabled[key] then
            n = n + 1
            rank[key] = n
        end
    end
    return rank
end

-- score: bigger table order = better. Returns nil if the item gives nothing for this kind.
local function score(info, kind, rank, minLevel)
    local bestRank, bestAmt = 1000, 0
    for key, amt in pairs(info.cats) do
        local r = rank[key]
        if r and (r < bestRank or (r == bestRank and amt > bestAmt)) then bestRank, bestAmt = r, amt end
    end
    if kind == "healthpot" then return { -info.healthAmt, info.manaAmt, -minLevel } end   -- biggest heal, pure heal before rejuvenation
    local restore = kind == "food" and info.healthAmt or info.manaAmt
    return { bestRank, -bestAmt, -restore, -minLevel }
end

local function better(a, b)
    if not b then return true end
    for i = 1, #a do
        if a[i] ~= b[i] then return a[i] < b[i] end
    end
    return false
end

-- returns { food = { itemID, link, name }, water = ... }, pending (tooltips still loading)
function K:Scan()
    local playerLevel = UnitLevel("player") or 1
    local ranks = { food = buildRank("food"), water = buildRank("water") }
    local best, bestScore = {}, {}
    local pending = false
    local seen = {}
    local first, last = bagRange()
    for bag = first, last do
        for slot = 1, numSlots(bag) do
            local si = slotInfo(bag, slot)
            local link = si and si.hyperlink
            local id = si and si.itemID
            if link and id and not seen[id] then
                seen[id] = true
                local info, wait = classify(id, link)
                if wait then pending = true end
                if info then
                    local minLevel = itemMinLevel(link)
                    if not minLevel then pending = true end
                    minLevel = minLevel or 0
                    if minLevel <= playerLevel then
                        for _, kind in ipairs(KINDS) do
                            if info[kind] and cfg()[kind] and cfg()[kind].enabled then
                                local s = score(info, kind, ranks[kind], minLevel)
                                if better(s, bestScore[kind]) then
                                    bestScore[kind] = s
                                    best[kind] = { itemID = id, link = link }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return best, pending
end

----------------------------------------------------------------------
-- Macros
----------------------------------------------------------------------
local function macroBody(kind, pick)
    if pick then return "#showtooltip\n/use item:" .. pick.itemID end
    return "#showtooltip\n/run print(\"Modern UI: no " .. KIND_LABEL[kind]:lower() .. " in your bags\")"
end

local lastPick = {}

local function writeMacro(kind, pick)
    local name = K.MACROS[kind]
    local body = macroBody(kind, pick)
    local idx = GetMacroIndexByName and GetMacroIndexByName(name) or 0
    if (not idx or idx == 0) and GetMacroIndexByName and OLD_MACROS[kind] then
        idx = GetMacroIndexByName(OLD_MACROS[kind]) or 0   -- keeps the action bar slot
    end
    -- an older character-specific macro cannot be turned global: replace it (its action bar slot is lost once)
    if idx and idx > (MAX_ACCOUNT_MACROS or 120) then
        DeleteMacro(idx)
        idx = 0
        ns:Print("Replaced the character " .. name .. " macro with a global one - drag it back to your action bar.")
    end
    if idx and idx > 0 then
        local current = GetMacroBody(idx)
        local curName = GetMacroInfo(idx)
        if current ~= body or curName ~= name then EditMacro(idx, name, nil, body) end
    else
        local global = GetNumMacros()
        if global >= (MAX_ACCOUNT_MACROS or 120) then
            if not K.warnedFull then
                K.warnedFull = true
                ns:Print("Global macro slots are full - delete one to let Modern UI create the " .. name .. " macro.")
            end
            return
        end
        CreateMacro(name, "INV_Misc_QuestionMark", body, false)
    end
    local id = pick and pick.itemID or nil
    if cfg().announce and lastPick[kind] ~= id then
        ns:Print(string.format("%s macro: %s", KIND_LABEL[kind], pick and pick.link or "nothing found"))
    end
    lastPick[kind] = id
end

function K:Update()
    if not ns.db or not cfg().enabled then return end
    ns:AfterCombat("consumables", function()
        local best, pending = K:Scan()
        for _, kind in ipairs(KINDS) do
            if cfg()[kind] and cfg()[kind].enabled then
                local ok, err = pcall(writeMacro, kind, best[kind])
                if not ok then geterrorhandler()(err) end
            end
        end
        if pending then K:Queue(1.5) end   -- item data still arriving
    end)
end

local timerToken = 0
function K:Queue(delay)
    timerToken = timerToken + 1
    local token = timerToken
    C_Timer.After(delay or 0.5, function()
        if token == timerToken then K:Update() end
    end)
end

-- /mui food: what would be picked, and why. "/mui food all" also dumps every food / drink in the bags with
-- its parsed numbers and tooltip text, to see what the parser makes of an item.
function K:Debug(verbose)
    local best = K:Scan()
    for _, kind in ipairs(KINDS) do
        local p = best[kind]
        ns:Print(string.format("%s: %s", kind, p and p.link or "none"))
    end
    if not verbose then return end
    local seen = {}
    local first, last = bagRange()
    for bag = first, last do
        for slot = 1, numSlots(bag) do
            local si = slotInfo(bag, slot)
            local link, id = si and si.hyperlink, si and si.itemID
            if link and id and not seen[id] then
                seen[id] = true
                local info, wait = classify(id, link)
                if wait then
                    ns:Print(link, "- tooltip not loaded yet")
                elseif not info then
                    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
                    local _, _, _, _, _, classID, subClassID = getInstant(link)
                    ns:Print(link, string.format("rejected: class %s sub %s", tostring(classID), tostring(subClassID)))
                    if classID == 0 then ns:Print("   ", textCache[id] or tooltipText(id, link) or "?") end
                else
                    local cats = {}
                    for key, amt in pairs(info.cats) do cats[#cats + 1] = key .. "=" .. amt end
                    ns:Print(link, string.format("hp %d, mana %d, minLevel %d, stats: %s",
                        info.healthAmt, info.manaAmt, itemMinLevel(link) or -1, #cats > 0 and table.concat(cats, ",") or "NONE"))
                    ns:Print("   ", textCache[id] or "?")
                end
            end
        end
    end
end

function K:Apply()
    if ns.db then K:Queue(0.2) end
end

function K:Init()
    ns:On("BAG_UPDATE_DELAYED", function() K:Queue(0.5) end)
    ns:On("PLAYER_LEVEL_UP", function() K:Queue(1) end)
    ns:On("PLAYER_ENTERING_WORLD", function()
        K:Queue(2)
        -- bag / item data can still be arriving right after login: one more pass later
        C_Timer.After(8, function() if ns.db and cfg().enabled then K:Queue(0.1) end end)
    end)
    ns:On("GET_ITEM_INFO_RECEIVED", function() if ns.db and cfg().enabled then K:Queue(1) end end)
end
