local ADDON, ns = ...
local UI = ns.UI

-- Small quality of life features: fast auto loot, an AFK screen, thanking strangers for buffs and timers
-- for temporary weapon enchants (poisons, sharpening stones, shaman weapon buffs).
local M = ns:NewModule("misc")
ns.Misc = M

local function cfg() return ns.db.misc end

----------------------------------------------------------------------
-- Fast loot: with auto loot on, every slot is taken the moment the loot is ready instead of
-- waiting for the loot window to fill in.
----------------------------------------------------------------------
local lastLoot = 0

local function fastLoot()
    if not (ns.db and cfg().fastLoot) then return end
    local auto = GetCVarBool and GetCVarBool("autoLootDefault") and true or false
    local toggled = IsModifiedClick and IsModifiedClick("AUTOLOOTTOGGLE") and true or false
    if auto == toggled then return end   -- auto loot is not in effect for this loot
    local now = GetTime()
    if now - lastLoot < 0.3 then return end
    lastLoot = now
    local n = GetNumLootItems and GetNumLootItems() or 0
    for i = n, 1, -1 do pcall(LootSlot, i) end
end

----------------------------------------------------------------------
-- Auto thanks: a player outside your group who buffs you in the open world gets a /thank emote.
-- The combat log is closed to addons on this client: the new aura on you names its caster as a unit
-- (sourceUnit), which is only there while the caster has one (nameplate, target, mouseover, ...).
-- One thanks per caster per minute, so a druid casting Mark of the Wild and Thorns gets one.
----------------------------------------------------------------------
local thanked = {}   -- caster GUID -> GetTime() of the last thanks

local function plain(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end

local function thankCaster(unit)
    local ok, isPlayer, isMe, guid = pcall(function()
        return UnitIsPlayer(unit), UnitIsUnit(unit, "player"), UnitGUID(unit)
    end)
    if not (ok and plain(isPlayer) and plain(isMe) and plain(guid)) or not isPlayer or isMe then return end
    if UnitInParty(unit) or UnitInRaid(unit) then return end
    local now = GetTime()
    if thanked[guid] and now - thanked[guid] < 60 then return end
    thanked[guid] = now
    pcall(DoEmote, "THANK", unit)
end

local function autoThank(_, unit, info)
    if unit ~= "player" or not (ns.db and cfg().autoThank) then return end
    if type(info) ~= "table" or IsInInstance() then return end
    -- In combat the client hands over addedAuras (or its entries) as secret values: skip those.
    local added = info.addedAuras
    if not plain(added) or type(added) ~= "table" then return end
    for _, aura in ipairs(added) do
        if not plain(aura) or type(aura) ~= "table" then return end
        local src = aura.sourceUnit
        if plain(src) and plain(aura.isHelpful) and aura.isHelpful then thankCaster(src) end
    end
end

----------------------------------------------------------------------
-- AFK screen: dims the screen and shows how long you have been away. Mouse and keyboard pass
-- through, so anything you do ends it as usual.
----------------------------------------------------------------------
local afk

local function buildAfk()
    afk = CreateFrame("Frame", "ModernUIAfkScreen", UIParent)
    afk:SetFrameStrata("FULLSCREEN")
    afk:SetAllPoints(UIParent)
    afk:EnableMouse(false)
    afk.bg = afk:CreateTexture(nil, "BACKGROUND")
    afk.bg:SetAllPoints()
    afk.bg:SetColorTexture(0, 0, 0, 0.65)
    afk.title = afk:CreateFontString(nil, "OVERLAY")
    afk.title:SetPoint("CENTER", 0, 40)
    afk.title:SetTextColor(0.30, 0.82, 1)
    afk.timer = afk:CreateFontString(nil, "OVERLAY")
    afk.timer:SetPoint("TOP", afk.title, "BOTTOM", 0, -10)
    afk.clock = afk:CreateFontString(nil, "OVERLAY")
    afk.clock:SetPoint("TOP", afk.timer, "BOTTOM", 0, -8)
    afk.clock:SetTextColor(0.62, 0.62, 0.68)
    local acc = 1
    afk:SetScript("OnUpdate", function(self, dt)
        acc = acc + dt
        if acc < 1 then return end
        acc = 0
        local s = math.floor(GetTime() - (self.since or GetTime()))
        self.timer:SetText(string.format("%02d:%02d", math.floor(s / 60), s % 60))
        self.clock:SetText(date("%H:%M"))
    end)
    afk:Hide()
end

local function updateAfk()
    local away = false
    if ns.db and cfg().afkScreen and not InCombatLockdown() then
        local ok, v = pcall(UnitIsAFK, "player")
        away = ok and not ns.IsSecret(v) and v and true or false
    end
    if not away then
        if afk then afk:Hide() end
        return
    end
    if not afk then buildAfk() end
    if afk:IsShown() then return end
    ns:SetFont(afk.title, 40, "OUTLINE")
    ns:SetFont(afk.timer, 28, "OUTLINE")
    ns:SetFont(afk.clock, 18, "OUTLINE")
    -- Each time, a coin flip between the plain name and "Mr"/"Mrs" in front of it.
    local name = UnitName("player") or ""
    local sex = UnitSex("player") -- 2 male, 3 female
    if (sex == 2 or sex == 3) and math.random(2) == 1 then
        name = (sex == 3 and "Mrs " or "Mr ") .. name
    end
    afk.title:SetText(name .. "  -  AFK")
    afk.since = GetTime()
    afk:Show()
end

----------------------------------------------------------------------
-- Temporary weapon enchants: main / off hand icon with the time left.
----------------------------------------------------------------------
local we   -- holder frame
local WE_SLOTS = { 16, 17 }

local function timeText(sec)
    if sec >= 3600 then return string.format("%dh", math.floor(sec / 3600 + 0.5)) end
    if sec >= 60 then return string.format("%dm", math.floor(sec / 60 + 0.5)) end
    return string.format("%d", sec)
end

local function updateEnchants()
    if not we then return end
    local on = ns.db and ns.db.weaponenchants.enabled and GetWeaponEnchantInfo
    local info = {}
    if on then
        local ok, hasMain, mainMs, mainCharges, _, hasOff, offMs, offCharges = pcall(GetWeaponEnchantInfo)
        if ok and not ns.IsSecret(hasMain) and not ns.IsSecret(hasOff) then
            info[1] = hasMain and { ms = mainMs, charges = mainCharges } or nil
            info[2] = hasOff and { ms = offMs, charges = offCharges } or nil
        end
    end
    local unlocked = ns.Mover and ns.Mover:IsUnlocked()
    for i, icon in ipairs(we.icons) do
        local e = info[i]
        if e then
            icon.tex:SetTexture(GetInventoryItemTexture("player", WE_SLOTS[i]))
            local ok = pcall(function()
                local sec = e.ms / 1000
                icon.time:SetText(timeText(sec))
                if sec < 60 then icon.time:SetTextColor(1, 0.3, 0.3) else icon.time:SetTextColor(1, 1, 1) end
                icon.count:SetText((e.charges and e.charges > 0) and e.charges or "")
            end)
            if not ok then icon.time:SetText(""); icon.count:SetText("") end
            icon:Show()
        else
            icon:Hide()
        end
    end
    we:SetShown(on and (info[1] or info[2] or unlocked) and true or false)
end

local function buildEnchants()
    we = CreateFrame("Frame", "ModernUIWeaponEnchants", UIParent)
    we.icons = {}
    for i, slot in ipairs(WE_SLOTS) do
        local icon = CreateFrame("Frame", nil, we)
        icon:EnableMouse(true)
        icon.bg = icon:CreateTexture(nil, "BACKGROUND")
        icon.bg:SetAllPoints()
        icon.bg:SetColorTexture(0.04, 0.04, 0.05, 0.85)
        icon.tex = icon:CreateTexture(nil, "ARTWORK")
        icon.tex:SetPoint("TOPLEFT", 1, -1)
        icon.tex:SetPoint("BOTTOMRIGHT", -1, 1)
        icon.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        icon.borders = UI.AddBorder(icon, 1, 0.55, 0.25, 0.85, 1, "OVERLAY")
        icon.time = icon:CreateFontString(nil, "OVERLAY")
        icon.time:SetPoint("CENTER", 0, 0)
        icon.count = icon:CreateFontString(nil, "OVERLAY")
        icon.count:SetPoint("BOTTOMRIGHT", 1, 0)
        icon:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            if not pcall(GameTooltip.SetInventoryItem, GameTooltip, "player", slot) then GameTooltip:Hide() return end
            GameTooltip:Show()
        end)
        icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
        icon:Hide()
        we.icons[i] = icon
    end
    local acc = 0
    we.driver = CreateFrame("Frame")
    we.driver:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc < 0.5 then return end
        acc = 0
        updateEnchants()
    end)
    ns.Mover:Register("weaponenchant", we, "Weapon Enchants")
end

local function layoutEnchants()
    local c = ns.db.weaponenchants
    if not c.enabled then
        if we then we:Hide() end
        return
    end
    if not GetWeaponEnchantInfo then return end
    if not we then buildEnchants() end
    local size = c.size
    we:SetScale(ns.db.general.scale)
    we:SetSize(size * 2 + 2, size)
    for i, icon in ipairs(we.icons) do
        icon:SetSize(size, size)
        icon:ClearAllPoints()
        icon:SetPoint("LEFT", we, "LEFT", (i - 1) * (size + 2), 0)
        ns:SetFont(icon.time, math.max(8, math.floor(size * 0.45)), "OUTLINE")
        ns:SetFont(icon.count, math.max(7, math.floor(size * 0.38)), "OUTLINE")
    end
    ns.Mover:Position("weaponenchant")
    updateEnchants()
end

----------------------------------------------------------------------
-- Error text filter: the red lines that every button press in combat can produce ("Not enough rage",
-- "Spell is not ready yet", "Out of range", ...) are dropped. UIErrorsFrame stops listening to
-- UI_ERROR_MESSAGE; every other message is handed to Blizzard's own handler, so it keeps its look and sound.
----------------------------------------------------------------------
local ERROR_SPAM = {
    "ERR_OUT_OF_RAGE", "ERR_OUT_OF_ENERGY", "ERR_OUT_OF_MANA", "ERR_OUT_OF_FOCUS",
    "ERR_SPELL_COOLDOWN", "ERR_ABILITY_COOLDOWN", "ERR_ITEM_COOLDOWN", "SPELL_FAILED_NOT_READY",
    "ERR_OUT_OF_RANGE", "SPELL_FAILED_OUT_OF_RANGE", "SPELL_FAILED_TOO_CLOSE",
    "ERR_BADATTACKFACING", "ERR_BADATTACKPOS", "SPELL_FAILED_UNIT_NOT_INFRONT",
    "ERR_NO_ATTACK_TARGET", "ERR_INVALID_ATTACK_TARGET", "ERR_GENERIC_NO_TARGET",
    "SPELL_FAILED_BAD_TARGETS", "SPELL_FAILED_BAD_IMPLICIT_TARGETS", "SPELL_FAILED_TARGETS_DEAD",
    "SPELL_FAILED_NO_COMBO_POINTS", "SPELL_FAILED_SPELL_IN_PROGRESS", "SPELL_FAILED_MOVING",
    "SPELL_FAILED_CASTER_AURASTATE", "SPELL_FAILED_TARGET_AURASTATE",
}
local spam            -- message text -> true (built from the client's own strings)
local errorListener   -- our UI_ERROR_MESSAGE frame while the filter is on
local blizzardOnError -- UIErrorsFrame's own OnEvent

local function isSpam(msg)
    local ok, hit = pcall(function() return spam[msg] end)   -- (a secret message cannot be a table key)
    return ok and hit
end

local function applyErrorFilter()
    local ef = _G.UIErrorsFrame
    if not ef then return end
    local on = cfg().hideErrors and true or false
    if on == (errorListener ~= nil and errorListener.on) then return end
    if not errorListener then
        spam = {}
        for _, key in ipairs(ERROR_SPAM) do
            if type(_G[key]) == "string" then spam[_G[key]] = true end
        end
        errorListener = CreateFrame("Frame")
        errorListener:SetScript("OnEvent", function(_, event, ...)
            -- 12.x: (error type, message); older clients: (message)
            local a, b = ...
            local msg = (b ~= nil) and b or a
            if isSpam(msg) then return end
            local handler = blizzardOnError or ef:GetScript("OnEvent")
            if handler then handler(ef, event, ...) end
        end)
    end
    errorListener.on = on
    if on then
        blizzardOnError = blizzardOnError or ef:GetScript("OnEvent")
        ef:UnregisterEvent("UI_ERROR_MESSAGE")
        errorListener:RegisterEvent("UI_ERROR_MESSAGE")
    else
        errorListener:UnregisterEvent("UI_ERROR_MESSAGE")
        ef:RegisterEvent("UI_ERROR_MESSAGE")
    end
end

----------------------------------------------------------------------
-- Social automation (each one off by default): accept summons and resurrections, decline duels,
-- accept group invites from friends and guild members.
----------------------------------------------------------------------
local function hidePopup(which)
    if StaticPopup_Hide then pcall(StaticPopup_Hide, which) end
end

local function inCombat(unit)
    local ok, v = pcall(UnitAffectingCombat, unit)
    if not ok or not plain(v) then return true end   -- unknown: treat as in combat
    return v and true or false
end

local function onSummon()
    if not cfg().acceptSummon or inCombat("player") then return end
    local S = C_SummonInfo
    local who = S and S.GetSummonConfirmSummoner and S.GetSummonConfirmSummoner()
    local where = S and S.GetSummonConfirmAreaName and S.GetSummonConfirmAreaName()
    local ok = pcall(function()
        if S and S.ConfirmSummon then S.ConfirmSummon() else ConfirmSummon() end
    end)
    if not ok then return end
    hidePopup("CONFIRM_SUMMON")
    ns:Print(string.format("Accepted the summon%s%s.", plain(who) and who and (" from " .. who) or "",
        plain(where) and where and (" to " .. where) or ""))
end

-- a resurrection from someone who is still fighting (a battle res) is left for you to take
local function onResurrect(_, who)
    if not cfg().acceptRes then return end
    if plain(who) and who and inCombat(who) then return end
    if not pcall(AcceptResurrect) then return end
    hidePopup("RESURRECT")
    hidePopup("RESURRECT_NO_SICKNESS")
    hidePopup("RESURRECT_NO_TIMER")
end

local function onDuel(_, who)
    if not cfg().declineDuels then return end
    if not pcall(CancelDuel) then return end
    hidePopup("DUEL_REQUESTED")
    if plain(who) and who then ns:Print("Declined a duel from " .. who .. ".") end
end

local function isFriendOrGuild(guid)
    if not (plain(guid) and guid) then return false end
    local ok, res = pcall(function()
        if C_FriendList and C_FriendList.IsFriend and C_FriendList.IsFriend(guid) then return true end
        if IsGuildMember and IsGuildMember(guid) then return true end
        if C_BattleNet and C_BattleNet.GetGameAccountInfoByGUID and C_BattleNet.GetGameAccountInfoByGUID(guid) then return true end
        return false
    end)
    return ok and plain(res) and res and true or false
end

local function onInvite(_, who, _, _, _, _, _, guid)
    if not cfg().acceptInvites or not isFriendOrGuild(guid) then return end
    if not pcall(AcceptGroup) then return end
    -- the invite dialog declines when it hides without being accepted: mark it accepted first
    pcall(function()
        local d = StaticPopup_FindVisible and StaticPopup_FindVisible("PARTY_INVITE")
        if d then d.inviteAccepted = 1 end
    end)
    hidePopup("PARTY_INVITE")
    if plain(who) and who then ns:Print("Joined " .. who .. "'s group.") end
end

----------------------------------------------------------------------
-- Quests: accept quests and turn in finished ones (hold Shift while talking to the NPC to skip).
-- Only quests in your quest log are turned in: repeatable hand-ins (cloth, reputation items) never sit in
-- the log, so they are not repeated until the items run out. Rewards are taken only when there is no
-- choice; trivial (grey) and repeatable quests are not picked up from the NPC's list.
----------------------------------------------------------------------
local function questsOn() return cfg().autoQuest and not IsShiftKeyDown() end

local function inLog(questID)
    if not (plain(questID) and questID and questID > 0) then return false end
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
        return C_QuestLog.GetLogIndexForQuestID(questID) ~= nil
    end
    if GetQuestLogIndexByID then return (GetQuestLogIndexByID(questID) or 0) > 0 end
    return true
end

local function onGossip()
    if not questsOn() then return end
    local G = C_GossipInfo
    if not G then return end
    pcall(function()
        for _, q in ipairs(G.GetActiveQuests and G.GetActiveQuests() or {}) do
            if q.isComplete and inLog(q.questID) then G.SelectActiveQuest(q.questID) return end
        end
        for _, q in ipairs(G.GetAvailableQuests and G.GetAvailableQuests() or {}) do
            if not q.isTrivial and not q.repeatable then G.SelectAvailableQuest(q.questID) return end
        end
    end)
end

-- older quest NPCs: the greeting list instead of gossip
local function onGreeting()
    if not questsOn() then return end
    pcall(function()
        for i = 1, GetNumActiveQuests() do
            local _, complete = GetActiveTitle(i)
            local id = GetActiveQuestID and GetActiveQuestID(i)
            if complete and (not id or inLog(id)) then SelectActiveQuest(i) return end
        end
        for i = 1, GetNumAvailableQuests() do
            local trivial, _, repeatable = GetAvailableQuestInfo(i)
            if not trivial and not repeatable then SelectAvailableQuest(i) return end
        end
    end)
end

local function onQuestDetail()
    if questsOn() then pcall(AcceptQuest) end
end

local function onQuestProgress()
    if not questsOn() or not inLog(GetQuestID()) then return end
    if (GetQuestMoneyToGet and GetQuestMoneyToGet() or 0) > 0 then return end   -- costs gold: your call
    if IsQuestCompletable() then pcall(CompleteQuest) end
end

local function onQuestComplete()
    if not questsOn() or not inLog(GetQuestID()) then return end
    local n = GetNumQuestChoices() or 0
    if n <= 1 then pcall(GetQuestReward, n) end
end

----------------------------------------------------------------------
-- Mail: an "Open all" button on the inbox that takes the gold and items of every mail, one mail at a
-- time. Cash on delivery mail is skipped; it stops when the bags are full or the mailbox closes.
-- Clients whose inbox already has Blizzard's own "Open All" button keep that one.
----------------------------------------------------------------------
local mailButton, mailRunning, mailStartMoney
local mailTries = {}   -- mail -> attempts: one that does not empty (unique item, ...) is skipped after 3

local function freeBagSlots()
    local n = 0
    local get = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        local free = get and get(bag)
        n = n + (free or 0)
    end
    return n
end

local function stopMail(reason)
    if not mailRunning then return end
    mailRunning = false
    if mailButton then mailButton:SetEnabled(true) end
    local gained = GetMoney() - (mailStartMoney or GetMoney())
    local msg = reason or "Mail opened."
    if gained > 0 and GetCoinTextureString then msg = msg .. " Gold taken: " .. GetCoinTextureString(gained) end
    ns:Print(msg)
end

local function mailStep()
    if not mailRunning then return end
    if not (MailFrame and MailFrame:IsShown()) then stopMail() return end
    for i = GetInboxNumItems(), 1, -1 do
        local _, _, _, subject, money, cod, _, itemCount = GetInboxHeaderInfo(i)
        local key = string.format("%d:%s:%d:%d", i, tostring(subject), money or 0, itemCount or 0)
        if (cod or 0) == 0 and ((money or 0) > 0 or (itemCount or 0) > 0) and (mailTries[key] or 0) < 3 then
            mailTries[key] = (mailTries[key] or 0) + 1
            if (itemCount or 0) > 0 and freeBagSlots() == 0 then stopMail("Bags are full.") return end
            if AutoLootMailItem then
                AutoLootMailItem(i)
            else
                if (money or 0) > 0 then TakeInboxMoney(i) end
                if (itemCount or 0) > 0 then TakeInboxItem(i, 1) end
            end
            C_Timer.After(0.4, mailStep)   -- the server takes a moment per mail
            return
        end
    end
    stopMail()
end

local function onMailShow()
    if mailButton then mailButton:SetShown(cfg().openAllMail) end
    if mailButton or not cfg().openAllMail or _G.OpenAllMail or not _G.InboxFrame then return end
    mailButton = UI.Button(InboxFrame, "Open all", 90, 22, function()
        if mailRunning then return end
        mailRunning, mailStartMoney = true, GetMoney()
        wipe(mailTries)
        mailButton:SetEnabled(false)
        mailStep()
    end)
    -- under the mail window's right edge (the tabs sit under its left edge)
    mailButton:SetPoint("TOPRIGHT", MailFrame, "BOTTOMRIGHT", 0, -2)
end

----------------------------------------------------------------------
-- Module API
----------------------------------------------------------------------
function M:Init()
    ns:On("CONFIRM_SUMMON", onSummon)
    ns:On("RESURRECT_REQUEST", onResurrect)
    ns:On("DUEL_REQUESTED", onDuel)
    ns:On("PARTY_INVITE_REQUEST", onInvite)
    ns:On("GOSSIP_SHOW", onGossip)
    ns:On("QUEST_GREETING", onGreeting)
    ns:On("QUEST_DETAIL", onQuestDetail)
    ns:On("QUEST_PROGRESS", onQuestProgress)
    ns:On("QUEST_COMPLETE", onQuestComplete)
    ns:On("MAIL_SHOW", onMailShow)
    ns:On("MAIL_CLOSED", function() stopMail() end)
    ns:On("LOOT_READY", fastLoot)
    ns:On("UNIT_AURA", autoThank)
    ns:On("PLAYER_FLAGS_CHANGED", function(_, unit) if unit == "player" then updateAfk() end end)
    ns:On("PLAYER_REGEN_DISABLED", updateAfk)
    ns:On("PLAYER_ENTERING_WORLD", updateAfk)
end

function M:Apply()
    if not ns.db then return end
    applyErrorFilter()
    updateAfk()
    layoutEnchants()
end
