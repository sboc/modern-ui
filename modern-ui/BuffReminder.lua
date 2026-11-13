local ADDON, ns = ...
local UI = ns.UI

-- Buff reminder: an icon per buff of your class that is missing or about to run out, on yourself and (optionally)
-- on party / raid members in range. Party and raid checks are off by default. Only for buffs you know.
-- Other units' auras can be unreadable on this client: a unit whose auras cannot be read is skipped, never
-- reported as "missing". Hidden in combat and while dead.
local R = ns:NewModule("buffreminder")
ns.BuffReminder = R

-- spells[1] is the buff you cast, the others also count as having it (Gift of the Wild covers Mark of the Wild).
-- Names come from the spell ids so they follow the client language.
local BUFFS = {
    DRUID = {
        { cast = 1126, also = { 21849 }, fallback = "Mark of the Wild" },
        { cast = 467,                    fallback = "Thorns" },
    },
}

local frame, rows
local entries     -- the buffs of this class, resolved: { name = {...}, castName, icon }
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
        local names = { [spellName(b.cast, b.fallback)] = true }
        for _, id in ipairs(b.also or {}) do names[spellName(id, "")] = true end
        entries[#entries + 1] = { id = b.cast, name = spellName(b.cast, b.fallback), names = names, icon = spellTexture(b.cast) }
    end
    return entries
end

-- seconds left of the buff on the unit: 0 = missing, math.huge = no expiry, nil = auras of the unit unreadable
local function timeLeft(unit, e)
    local now, readable, best = GetTime(), false, 0
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

local function refresh()
    if not frame then return end
    local c = cfg()
    local list = resolve()
    if not c.enabled or #list == 0 or UnitAffectingCombat("player") or UnitIsDeadOrGhost("player") then
        frame:Hide()
        return
    end
    local units = groupUnits(c)
    local shown = 0
    for i, e in ipairs(list) do
        local text
        if known(e.id) then
            local own
            if c.self then
                local left = timeLeft("player", e)
                if left and left < math.max(c.threshold, 1) then own = left == 0 and "missing" or fmt(left) end
            end
            local missing = 0
            for _, u in ipairs(units) do
                if inReach(u) then
                    local left = timeLeft(u, e)
                    if left and left < math.max(c.threshold, 1) then missing = missing + 1 end
                end
            end
            if own or missing > 0 then
                text = e.name
                if own then text = text .. ": " .. own end
                if missing > 0 then text = text .. (own and "  " or ": ") .. missing .. " in group" end
            end
        end
        local row = rows[i]
        if text then
            shown = shown + 1
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(shown - 1) * (c.size + 4))
            row.icon:SetTexture(e.icon)
            row.text:SetText(text)
            row:Show()
        else
            row:Hide()
        end
    end
    frame:SetShown(shown > 0)
end

local function layout()
    local c = cfg()
    frame:SetScale(c.scale * ns.db.general.scale)
    frame:SetSize(c.size + 8 + 220, c.size)
    for _, row in ipairs(rows) do
        row:SetSize(c.size + 8 + 220, c.size)
        row.icon:SetSize(c.size, c.size)
        ns:SetFont(row.text, math.max(10, math.floor(c.size * 0.45)), "OUTLINE")
    end
end

local function build()
    frame = CreateFrame("Frame", "ModernUIBuffReminder", UIParent)
    frame:SetFrameStrata("HIGH")
    rows = {}
    for i = 1, #resolve() do
        local row = CreateFrame("Frame", nil, frame)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetPoint("LEFT")
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        UI.AddBorder(row, 1, 0, 0, 0, 1, "OVERLAY")
        row.text = row:CreateFontString(nil, "OVERLAY")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
        row.text:SetJustifyH("LEFT")
        row:Hide()
        rows[i] = row
    end
    -- own driver: a hidden frame gets no OnUpdate. One scan a second also covers buff expiry and the roster's auras
    CreateFrame("Frame"):SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 1 then elapsed = 0; refresh() end
    end)
    for _, e in ipairs({ "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "SPELLS_CHANGED",
                         "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST" }) do
        ns:On(e, refresh)
    end
    ns.Mover:Register("buffreminder", frame, "Buff Reminder")
end

function R:Apply()
    if not ns.db then return end
    if not frame then
        if #resolve() == 0 then return end
        build()
    end
    layout()
    ns.Mover:Position("buffreminder")
    refresh()
end
