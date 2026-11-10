local ADDON, ns = ...

-- Consumables: keeps four global macros ("Food", "Water", "Health Potion", "Pet Food", shared by all characters) pointed at the
-- best food / drink / health potion in your bags. The potion pick is simply the biggest heal you can use at your level.
-- Hunters also get "Pet Food": the WORST food (by the food stat priority) that the current pet's diet allows, so the good
-- buff food stays for the player.
-- "Best" = the user's stat priority list first (attack power, spell power, ...), then the bigger buff, then the bigger
-- restore, then the higher level item. Items above your level are ignored. Macros can only be edited out of
-- combat, so updates made in combat are queued until it ends.
local K = ns:NewModule("consumables")
ns.Consumables = K

K.MACROS = { food = "Food", water = "Water", healthpot = "Health Potion", petfood = "Pet Food" }
local KINDS = { "food", "water", "healthpot", "petfood" }
local KIND_LABEL = { food = "Food", water = "Water", healthpot = "Health potion", petfood = "Pet food" }
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
-- Class / spec detection: picks the stat order that suits the character when "auto" is on
----------------------------------------------------------------------
-- archetype -> { label, food = head of the order, water = head of the order }; categories not listed follow in default order
local ARCHETYPES = {
    healer     = { label = "Healer",
                   food  = { "HEALING", "SPELL_POWER", "INTELLECT", "SPIRIT", "MP5", "STAMINA" },
                   water = { "INTELLECT", "SPIRIT", "HEALING", "SPELL_POWER", "MP5", "STAMINA" } },
    caster     = { label = "Caster",
                   food  = { "SPELL_POWER", "INTELLECT", "SPIRIT", "MP5", "STAMINA" },
                   water = { "INTELLECT", "SPIRIT", "SPELL_POWER", "MP5", "STAMINA" } },
    melee_str  = { label = "Strength melee",
                   food  = { "ATTACK_POWER", "STRENGTH", "STAMINA" },
                   water = { "INTELLECT", "SPIRIT", "STAMINA" } },
    melee_agi  = { label = "Agility melee / ranged",
                   food  = { "ATTACK_POWER", "AGILITY", "STAMINA" },
                   water = { "INTELLECT", "SPIRIT", "STAMINA" } },
    tank_str   = { label = "Strength tank",
                   food  = { "STRENGTH", "STAMINA", "ATTACK_POWER" },
                   water = { "INTELLECT", "SPIRIT", "STAMINA" } },
    tank_agi   = { label = "Agility tank",
                   food  = { "AGILITY", "STAMINA", "ATTACK_POWER" },
                   water = { "INTELLECT", "SPIRIT", "STAMINA" } },
}

-- used when the client reports no usable spec; classes that can be anything are left out on purpose
local CLASS_ARCHETYPE = {
    WARRIOR = "melee_str", DEATHKNIGHT = "melee_str", ROGUE = "melee_agi", HUNTER = "melee_agi",
    DEMONHUNTER = "melee_agi", MAGE = "caster", WARLOCK = "caster", PRIEST = "healer",
}

local PRIMARY_STAT = { [1] = "str", [2] = "agi", [4] = "int" }   -- LE_UNIT_STAT_*: 1 strength, 2 agility, 3 stamina, 4 intellect

local function specArchetype()
    local I = C_SpecializationInfo
    local getSpec = (I and I.GetSpecialization) or GetSpecialization
    local getInfo = (I and I.GetSpecializationInfo) or GetSpecializationInfo
    if not getSpec or not getInfo then return end
    local okS, idx = pcall(getSpec)
    if not okS or type(idx) ~= "number" or idx < 1 then return end
    local ok, _, _, _, _, role, primary = pcall(getInfo, idx)
    if not ok or type(role) ~= "string" then return end
    local stat = PRIMARY_STAT[primary]
    if role == "HEALER" then return "healer" end
    if role == "TANK" then
        if stat == "agi" then return "tank_agi" end
        return "tank_str"
    end
    if role == "DAMAGER" then
        if stat == "int" then return "caster" end
        if stat == "agi" then return "melee_agi" end
        if stat == "str" then return "melee_str" end
    end
end

-- archetype key or nil when nothing can be told
function K:DetectArchetype()
    local key = specArchetype()
    if key then return key end
    local _, class = UnitClass("player")
    return class and CLASS_ARCHETYPE[class] or nil
end

-- readable result for the settings page
function K:DetectedLabel()
    local key = K:DetectArchetype()
    return key and ARCHETYPES[key].label or nil
end

-- full ordered category list for the detected archetype, or nil
local function autoPriority(kind)
    local arch = ARCHETYPES[K:DetectArchetype() or ""]
    if not arch then return end
    local out, seen = {}, {}
    for _, key in ipairs(arch[kind]) do
        if catByKey[key] and not seen[key] then seen[key] = true; out[#out + 1] = key end
    end
    for _, key in ipairs(K.DEFAULT_PRIORITY[kind]) do
        if not seen[key] then seen[key] = true; out[#out + 1] = key end
    end
    return out
end

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
-- Hunter pet food
----------------------------------------------------------------------
-- The client has no item -> diet lookup, so the diet is guessed from the item name (English). First matching diet wins,
-- fish / fungus / cheese / bread / fruit are checked before the broad meat words.
local DIET_WORDS = {
    { "fish",   { "fish", "salmon", "trout", "bass", "catfish", "snapper", "eel", "mackerel", "cod", "lobster", "clam", "oyster",
                  "squid", "tuna", "herring", "yellowtail", "mudfish", "shrimp", "crab", "sturgeon", "bream" } },
    { "fungus", { "mushroom", "fungus", "shroom", "truffle", "morel", "toadstool", "cap" } },
    { "cheese", { "cheese" } },
    { "bread",  { "bread", "loaf", "muffin", "biscuit", "roll", "pastry", "bun", "cake", "cracker", "pretzel", "scone" } },
    { "fruit",  { "apple", "banana", "melon", "grape", "pear", "orange", "berry", "berries", "fruit", "cherry", "peach", "plum",
                  "pineapple", "lemon", "mango", "papaya", "coconut" } },
    { "meat",   { "meat", "jerky", "steak", "ribs", "chop", "haunch", "sausage", "wing", "bacon", "roast", "kabob", "venison",
                  "ham", "tenderloin", "chicken", "brisket", "drumstick", "stew", "liver", "heart", "tongue", "egg" } },
}

local function itemName(link)
    local n = type(link) == "string" and link:match("%[(.-)%]")
    return n and n:lower() or ""
end

-- diet key ("meat", "fish", ...) or nil
local function itemDiet(link, classID, subClassID)
    local name = itemName(link)
    for _, d in ipairs(DIET_WORDS) do
        for _, w in ipairs(d[2]) do
            -- whole words only ("roll" must not match "troll")
            if (" " .. name .. " "):find("%A" .. w .. "s?%A") then return d[1] end
        end
    end
    local tradeGoods = (Enum and Enum.ItemClass and Enum.ItemClass.Tradegoods) or 7
    if classID == tradeGoods and subClassID == 8 then return "meat" end   -- raw meat (Trade Goods > Meat)
end

-- uncooked fish ("Raw Sagefish"): a cooking ingredient, never picked for the pet food or the food macro
local function isRawFish(link, classID, subClassID)
    return itemName(link):find("^raw ") ~= nil and itemDiet(link, classID, subClassID) == "fish"
end

-- vanilla diets by creature family, only used when the client has no GetPetFoodTypes (English family names)
local FAMILY_DIET = {
    ["Bat"] = "fruit fungus", ["Bear"] = "bread fish fruit fungus meat", ["Boar"] = "bread cheese fish fruit fungus meat",
    ["Carrion Bird"] = "fish meat", ["Cat"] = "fish meat", ["Crab"] = "bread fish fruit fungus", ["Crocolisk"] = "fish meat",
    ["Gorilla"] = "fruit fungus", ["Hyena"] = "fruit meat", ["Owl"] = "meat", ["Raptor"] = "meat", ["Scorpid"] = "meat",
    ["Serpent"] = "meat", ["Spider"] = "meat", ["Tallstrider"] = "fruit fungus", ["Turtle"] = "fish fruit fungus",
    ["Wind Serpent"] = "bread cheese fish", ["Wolf"] = "meat",
}

-- set of diet keys the current pet eats (a cat: meat + fish), or nil without a pet / when nothing can tell
local function petDiets()
    if not UnitExists("pet") then return end
    local set, n = {}, 0
    if GetPetFoodTypes then
        local ok, list = pcall(function() return { GetPetFoodTypes() } end)
        if ok and type(list) == "table" then
            for _, v in ipairs(list) do
                if type(v) == "string" then set[v:lower()] = true; n = n + 1 end
            end
        end
    end
    if n == 0 then
        local family = UnitCreatureFamily and UnitCreatureFamily("pet")
        local words = type(family) == "string" and FAMILY_DIET[family]
        for w in (words or ""):gmatch("%a+") do set[w] = true; n = n + 1 end
    end
    return n > 0 and set or nil
end

local function isHunter()
    local _, class = UnitClass("player")
    return class == "HUNTER"
end

function K:PetFoodActive()
    return isHunter() and cfg().petfood and cfg().petfood.enabled
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
    local list, off = c.priority, c.disabled
    if cfg().auto then
        local auto = autoPriority(kind)
        if auto then list, off = auto, {} end
    end
    for _, key in ipairs(list) do
        if catByKey[key] and not off[key] then
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

-- pet food: reverse of the food order. Items with no listed stat are the worst (rank 1000), then the smallest buff,
-- then the smallest restore; a higher item level wins last so the feeding still gives the pet happiness
local function petScore(info, rank, minLevel)
    local bestRank, bestAmt = 1000, 0
    for key, amt in pairs(info.cats) do
        local r = rank[key]
        if r and (r < bestRank or (r == bestRank and amt > bestAmt)) then bestRank, bestAmt = r, amt end
    end
    return { -bestRank, bestAmt, info.healthAmt, -minLevel }
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
    local diets = K:PetFoodActive() and petDiets() or nil
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
                local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
                local _, _, _, _, _, classID, subClassID = getInstant(link)
                local raw = isRawFish(link, classID, subClassID)
                if raw then info = nil end
                if diets and not raw then
                    local diet = itemDiet(link, classID, subClassID)
                    local consumable = (Enum and Enum.ItemClass and Enum.ItemClass.Consumable) or 0
                    -- cooked food must be real food (not a drink or potion); raw meat has no tooltip restore line
                    local edible = diet and diets[diet] and (classID ~= consumable or (info and info.food and not info.healthpot))
                    if edible then
                        local minLevel = itemMinLevel(link)
                        if not minLevel then pending = true end
                        minLevel = minLevel or 0
                        if minLevel <= playerLevel then
                            local pinfo = info or { healthAmt = 0, manaAmt = 0, cats = {} }
                            local s = petScore(pinfo, ranks.food, minLevel)
                            if better(s, bestScore.petfood) then
                                bestScore.petfood = s
                                best.petfood = { itemID = id, link = link }
                            end
                        end
                    end
                end
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
    if pick and kind == "petfood" then return "#showtooltip\n/cast Feed Pet\n/use item:" .. pick.itemID end
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
            local active = cfg()[kind] and cfg()[kind].enabled
            if kind == "petfood" then
                -- hunters only; without a pet the macro keeps its last item (it is still created, empty, if missing)
                active = active and K:PetFoodActive()
                if active and not (UnitExists("pet") and petDiets()) and GetMacroIndexByName(K.MACROS.petfood) > 0 then active = false end
            end
            if active then
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
    ns:Print("auto priority: " .. (cfg().auto and ("on, " .. (K:DetectedLabel() or "nothing detected, using manual order")) or "off"))
    for _, kind in ipairs(KINDS) do
        local p = best[kind]
        ns:Print(string.format("%s: %s", kind, p and p.link or "none"))
    end
    if isHunter() then
        local d = petDiets()
        local names = {}
        for k in pairs(d or {}) do names[#names + 1] = k end
        ns:Print("pet diet: " .. (#names > 0 and table.concat(names, ", ") or "unknown (no pet, or the client gave no diet)"))
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
    ns:On("UNIT_PET", function(_, unit)
        if (unit == nil or unit == "player") and ns.db and isHunter() then K:Queue(1) end
    end)
    ns:On("PET_STABLE_UPDATE", function() if ns.db and isHunter() then K:Queue(1) end end)
    ns:On("PLAYER_SPECIALIZATION_CHANGED", function(_, unit)
        if (unit == nil or unit == "player") and ns.db and cfg().auto then K:Queue(1) end
    end)
    ns:On("ACTIVE_TALENT_GROUP_CHANGED", function() if ns.db and cfg().auto then K:Queue(1) end end)
    ns:On("PLAYER_ENTERING_WORLD", function()
        K:Queue(2)
        -- bag / item data can still be arriving right after login: one more pass later
        C_Timer.After(8, function() if ns.db and cfg().enabled then K:Queue(0.1) end end)
    end)
    ns:On("GET_ITEM_INFO_RECEIVED", function() if ns.db and cfg().enabled then K:Queue(1) end end)
end
