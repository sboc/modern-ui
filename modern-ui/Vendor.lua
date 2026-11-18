local ADDON, ns = ...

-- Vendor helpers: sells gray (poor quality) items when a merchant window opens. On by default (Bag Windows page).
-- Sold items can always be bought back from the merchant's buyback tab.
local V = ns:NewModule("vendor")
ns.Vendor = V

local merchantOpen = false
local selling = false

local function cfg() return ns.db.vendor end

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

-- Never replace C_Container.UseContainerItem: writing to a Blizzard table taints it, and then every right-click
-- use of an item (scrolls, potions...) runs tainted and gets blocked as a protected action. Selling is only
-- observed with hooksecurefunc; a protected item that got sold is bought back right away and confirmed instead.
local bypass = false

local function useItem(bag, slot)
    local use = (C_Container and C_Container.UseContainerItem) or UseContainerItem
    if not use then return end
    bypass = true
    pcall(use, bag, slot)
    bypass = false
end

-- protected items: itemID -> true. Selling one (right-click at a merchant) asks for confirmation first.
local function isProtected(itemID)
    local db = ns.db and cfg()
    return itemID and db and db.protected and db.protected[itemID] or false
end

local function itemIDFromLink(link)
    return link and tonumber(tostring(link):match("item:(%d+)"))
end

local function slotItemID(bag, slot)
    local info = slotInfo(bag, slot)
    return info and (info.itemID or itemIDFromLink(info.hyperlink)), info
end

local function itemName(link, id)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local ok, name = pcall(getInfo, link or id)
    return (ok and type(name) == "string") and name or ("item " .. tostring(id))
end

function V:IsProtected(itemID) return isProtected(itemID) and true or false end

function V:SetProtected(link, state)
    local id = itemIDFromLink(link)
    if not id or not ns.db then return end
    local db = cfg()
    db.protected = db.protected or {}
    if state == nil then state = not db.protected[id] end
    db.protected[id] = state and true or nil
    ns:Print(string.format("%s %s %s.", state and "Protected" or "Unprotected", link,
        state and "- selling it will ask for confirmation" or "- it can be sold normally again"))
end

function V:ClearProtected()
    if ns.db then cfg().protected = {} end
end

local function protectedList()
    local out = {}
    for id in pairs((ns.db and cfg().protected) or {}) do out[#out + 1] = itemName(nil, id) end
    table.sort(out)
    return out
end

local lastBag = (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 1)

local function findItem(id)
    for bag = 0, lastBag do
        for slot = 1, numSlots(bag) do
            if slotItemID(bag, slot) == id then return bag, slot end
        end
    end
end

-- buyback slots holding this item: index of the newest one and how many there are
local function buybackCount(id)
    local n, newest = 0, nil
    if GetNumBuybackItems and GetBuybackItemLink then
        for i = 1, GetNumBuybackItems() do
            if itemIDFromLink(GetBuybackItemLink(i)) == id then n = n + 1; newest = i end
        end
    end
    return n, newest
end

-- A protected item was right-clicked at the merchant. The client keeps showing it until the server answers, so it
-- is still readable here. Wait until it shows up in the buyback list (retrying - latency varies), buy it back,
-- then ask whether it should really be sold.
local pending = {}
local function onUse(bag, slot)
    if bypass or not merchantOpen or not ns.db or not BuybackItem then return end
    local id, info = slotItemID(bag, slot)
    local key = bag * 100 + slot
    if not id or not isProtected(id) or pending[key] then return end
    pending[key] = true
    local link = info and info.hyperlink
    local before = buybackCount(id)
    local tries = 0
    local function check()
        if not merchantOpen then pending[key] = nil; return end
        local now, idx = buybackCount(id)
        if now > before and idx then
            pending[key] = nil
            BuybackItem(idx)
            ns.UI.Confirm("Sell protected item?\n" .. (link or itemName(nil, id)), function()
                if not merchantOpen then return end
                C_Timer.After(0.1, function()
                    local b, sl = findItem(id)
                    if b then useItem(b, sl) end
                end)
            end)
            return
        end
        tries = tries + 1
        if tries >= 15 then pending[key] = nil; return end
        C_Timer.After(0.15, check)
    end
    C_Timer.After(0.1, check)
end

local function sellPrice(info)
    local link = info.hyperlink
    if not link then return 0 end
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local ok, _, _, _, _, _, _, _, _, _, _, price = pcall(getInfo, link)
    return (ok and type(price) == "number") and price or 0
end

-- every poor quality slot that actually has a vendor value
local function collect()
    local list = {}
    local poor = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0
    local last = (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 1)
    for bag = 0, last do
        for slot = 1, numSlots(bag) do
            local info = slotInfo(bag, slot)
            if info and info.quality == poor and not info.hasNoValue and not info.isLocked
               and not isProtected(info.itemID or itemIDFromLink(info.hyperlink)) then
                list[#list + 1] = { bag = bag, slot = slot,
                                    value = sellPrice(info) * (info.stackCount or 1) }
            end
        end
    end
    return list
end

local function money(copper)
    if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then return C_CurrencyInfo.GetCoinTextureString(copper) end
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    return tostring(copper) .. "c"
end

function V:SellJunk()
    if selling or not merchantOpen then return end
    local list = collect()
    if #list == 0 then return end
    selling = true
    local i, total, count = 1, 0, 0
    -- a few items per tick: selling everything in one frame can be dropped by the server
    local function step()
        if not merchantOpen then selling = false; return end
        for _ = 1, 6 do
            local it = list[i]
            if not it then break end
            useItem(it.bag, it.slot)
            total, count = total + it.value, count + 1
            i = i + 1
        end
        if i <= #list then
            C_Timer.After(0.1, step)
        else
            selling = false
            if cfg().summary and count > 0 then
                ns:Print(string.format("Sold %d junk item%s for %s.", count, count == 1 and "" or "s", money(total)))
            end
        end
    end
    step()
end

-- Repairs everything when a repair merchant opens. With vendor.guildRepair the guild bank pays when the character is
-- allowed to repair from it and the allowance covers the cost; own gold pays otherwise, and also when the guild
-- repair did not go through (checked a moment later: anything still damaged is paid for from own gold).
local function repairOwn(cost)
    if cost > (GetMoney and GetMoney() or 0) then
        ns:Print(string.format("Not enough gold to repair (%s needed).", money(cost)))
        return
    end
    pcall(RepairAllItems, false)
    if cfg().summary then ns:Print(string.format("Repaired for %s.", money(cost))) end
end

local function repairCost()
    if not (merchantOpen and CanMerchantRepair and CanMerchantRepair()) then return end
    local ok, cost, can = pcall(GetRepairAllCost)
    if ok and type(cost) == "number" and cost > 0 and can then return cost end
end

local function guildCanPay(cost)
    if not (cfg().guildRepair and IsInGuild and IsInGuild() and CanGuildBankRepair and CanGuildBankRepair()) then return false end
    local ok, limit = pcall(GetGuildBankWithdrawMoney)
    -- a negative allowance means unlimited (guild master)
    return ok and type(limit) == "number" and (limit < 0 or limit >= cost)
end

function V:Repair()
    local cost = repairCost()
    if not cost then return end
    if not guildCanPay(cost) then return repairOwn(cost) end
    pcall(RepairAllItems, true)
    C_Timer.After(0.5, function()
        local left = repairCost()
        if left then return repairOwn(left) end
        if merchantOpen and cfg().summary then ns:Print(string.format("Repaired for %s (guild bank).", money(cost))) end
    end)
end

-- Trash button: first click highlights the gray items whose whole stack is worth less than a set price (everything
-- else in the bags is dimmed), then every further left-click deletes one of them, cheapest stack first. Right-click
-- stops; it also stops by itself when nothing is left. Protected items are never marked.
-- DeleteCursorItem only runs during a real key press or click, and only once per click: a loop that deletes several
-- stacks in one click is blocked ("Interface action failed because of an AddOn"). So pickup and delete happen right
-- inside OnClick, one stack each, with the bags re-read every time.
local trashShown = false
local trashButtons = {}

-- whole-stack vendor value; nil while the item data is not cached yet (never guess 0 for something about to be deleted)
local function stackValue(info)
    if info.hasNoValue then return 0 end
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local ok, name, _, _, _, _, _, _, _, _, _, price = pcall(getInfo, info.hyperlink or info.itemID)
    if not (ok and name and type(price) == "number") then return end
    return price * (info.stackCount or 1)
end

local function trashValue(info, limit)
    local poor = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0
    if not (info and info.quality == poor) then return end
    if isProtected(info.itemID or itemIDFromLink(info.hyperlink)) then return end
    local value = stackValue(info)
    if value and value < limit then return value end
end

-- marked stacks, cheapest first (bag order breaks ties)
local function trashList(limit)
    local list = {}
    for bag = 0, lastBag do
        for slot = 1, numSlots(bag) do
            local info = slotInfo(bag, slot)
            local value = trashValue(info, limit)
            if value then
                list[#list + 1] = { bag = bag, slot = slot, value = value, info = info, order = #list }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.value ~= b.value then return a.value < b.value end
        return a.order < b.order
    end)
    return list
end

function V:TrashShown() return trashShown end

-- checked live, so the marks follow the items when the bags change
function V:IsTrash(bag, slot)
    return trashValue(slotInfo(bag, slot), cfg().trashMax or 0) ~= nil
end

local function setTrashShown(state)
    trashShown = state
    for _, b in ipairs(trashButtons) do b:SetSelected(state) end
    if ns.CustomBags and ns.CustomBags.RequestAll then ns.CustomBags.RequestAll() end
    if ns.BagWindows and ns.BagWindows.RequestRestyle then ns.BagWindows.RequestRestyle() end
end

local function noTrashText(limit)
    return limit > 0 and ("No gray items worth less than " .. money(limit) .. ".")
           or "Set a price limit first (Config > Bag Windows > Vendor)."
end

-- deletes the cheapest marked stack; must be called straight from a click
local function deleteCheapest(limit)
    if InCombatLockdown and InCombatLockdown() then ns:Print("Cannot delete items in combat."); return end
    if GetCursorInfo and GetCursorInfo() then ns:Print("Drop what is on your cursor first."); return end
    local list = trashList(limit)
    local it
    for _, entry in ipairs(list) do
        if not entry.info.isLocked then it = entry; break end
    end
    if not it then
        if #list == 0 then ns:Print(noTrashText(limit)); setTrashShown(false) end
        return
    end
    local pickup = (C_Container and C_Container.PickupContainerItem) or PickupContainerItem
    local id = it.info.itemID or itemIDFromLink(it.info.hyperlink)
    pcall(pickup, it.bag, it.slot)
    local kind, cursorID = GetCursorInfo()
    if kind ~= "item" or cursorID ~= id then ClearCursor(); return end
    DeleteCursorItem()
    kind, cursorID = GetCursorInfo()
    if kind == "item" and cursorID == id then
        ClearCursor()
        ns:Print("The client blocked deleting the item.")
        return
    end
    local left = #list - 1
    ns:Print(string.format("Deleted %s%s (%s). %s", it.info.hyperlink or itemName(nil, id),
        (it.info.stackCount or 1) > 1 and (" x" .. it.info.stackCount) or "", money(it.value),
        left > 0 and string.format("%d left.", left) or "None left."))
    if left == 0 then setTrashShown(false) end
end

function V:TrashClick(button)
    local limit = cfg().trashMax or 0
    if button == "RightButton" then
        if trashShown then setTrashShown(false) end
        return
    end
    if trashShown then return deleteCheapest(limit) end
    local count = #trashList(limit)
    if count == 0 then ns:Print(noTrashText(limit)); return end
    ns:Print(string.format("%d gray item stack%s worth less than %s highlighted. Click Trash again to delete the cheapest one (one per click); right-click to stop.",
        count, count == 1 and "" or "s", money(limit)))
    setTrashShown(true)
end

-- shared by the grouped bag window and the Blizzard backpack
function V:CreateTrashButton(parent, w, h)
    local b = ns.UI.Button(parent, "Trash", w or 46, h or 20, function(_, button) V:TrashClick(button) end)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    trashButtons[#trashButtons + 1] = b
    b:SetSelected(trashShown)
    b:HookScript("OnEnter", function(self)
        local limit = ns.db and cfg().trashMax or 0
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Delete gray items", 1, 1, 1)
        GameTooltip:AddLine("Worth less than " .. money(limit) .. " per stack.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Click: highlight them, then each click deletes the cheapest stack.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right-click: stop. Change the limit in Config > Bag Windows.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

-- Deposit / Withdraw buttons at the bank: move every trade goods stack (item class Tradeskill) from the bags into the
-- bank, or from the character bank into the bags, the same way a right-click does - so a deposit lands in whichever
-- bank tab / panel is open. Whatever does not fit (or cannot go there, e.g. soulbound into the warband bank) stays.
local bankOpen, moving = false, false
local TRADEGOODS = (Enum and Enum.ItemClass and Enum.ItemClass.Tradegoods) or 7

local function isTradeGood(info)
    local id = info.itemID or itemIDFromLink(info.hyperlink)
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not (id and getInstant) then return false end
    local ok, _, _, _, _, _, classID = pcall(getInstant, id)
    return ok and classID == TRADEGOODS
end

local function playerBags()
    local list = {}
    for bag = 0, lastBag do list[#list + 1] = bag end
    return list
end

-- the character bank containers (old bank and bank bags and / or bank tabs), shared with the grouped bank window
local function bankBags()
    local CB = ns.CustomBags
    return CB and CB.BankBags and CB.BankBags() or {}
end

local function tradeGoodSlots(bags)
    local list = {}
    for _, bag in ipairs(bags) do
        for slot = 1, numSlots(bag) do
            local info = slotInfo(bag, slot)
            if info and not info.isLocked and isTradeGood(info) then list[#list + 1] = { bag = bag, slot = slot } end
        end
    end
    return list
end

-- from: bag list to move out of; verb / none / full: chat wording
local function moveTradeGoods(from, verb, none, full)
    if moving or not bankOpen then return end
    if CursorHasItem and CursorHasItem() then ns:Print("Drop the item on your cursor first."); return end
    local list = tradeGoodSlots(from())
    if #list == 0 then ns:Print(none); return end
    moving = true
    local i = 1
    -- a few stacks per tick, like selling: moving everything in one frame can be dropped by the server
    local function step()
        if not bankOpen then moving = false; return end
        for _ = 1, 6 do
            local it = list[i]
            if not it then break end
            useItem(it.bag, it.slot)
            i = i + 1
        end
        if i <= #list then C_Timer.After(0.1, step) return end
        -- count again once the server has answered: what is still there did not fit
        C_Timer.After(0.5, function()
            moving = false
            local left = #tradeGoodSlots(from())
            local moved = math.max(0, #list - left)
            ns:Print(string.format("%s %d trade goods stack%s.%s", verb, moved, moved == 1 and "" or "s",
                left > 0 and string.format(" %d could not be moved (%s full?).", left, full) or ""))
        end)
    end
    step()
end

function V:DepositTradeGoods()
    moveTradeGoods(playerBags, "Deposited", "No trade goods in your bags.", "bank")
end

function V:WithdrawTradeGoods()
    moveTradeGoods(bankBags, "Withdrew", "No trade goods in your bank.", "bags")
end

local function bankButton(parent, label, w, h, onClick, title, text)
    local b = ns.UI.Button(parent, label, w, h, onClick)
    b:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        GameTooltip:AddLine(text, 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

-- also used by the grouped bank window (CustomBags.lua)
function V:CreateDepositButton(parent, w, h)
    return bankButton(parent, "Deposit", w or 70, h or 20, function() V:DepositTradeGoods() end,
        "Deposit trade goods", "Moves all trade goods from your bags into the open bank tab.")
end

function V:CreateWithdrawButton(parent, w, h)
    return bankButton(parent, "Withdraw", w or 70, h or 20, function() V:WithdrawTradeGoods() end,
        "Withdraw trade goods", "Moves all trade goods from your bank into your bags.")
end

local depositButton
local function createDepositButton()
    local bank = _G.BankFrame
    if depositButton or not bank then return end
    depositButton = V:CreateDepositButton(bank, 70, 20)
    depositButton:SetPoint("TOPRIGHT", bank, "BOTTOMRIGHT", 0, -2)
    V:CreateWithdrawButton(bank, 70, 20):SetPoint("RIGHT", depositButton, "LEFT", -4, 0)
end

-- Alt+click an item in a bag toggles its protection
local function bagButtonUnderMouse()
    local f
    if GetMouseFoci then f = GetMouseFoci(); f = f and f[1] else f = GetMouseFocus and GetMouseFocus() end
    if not f then return false end
    return (f.molBag or f.GetBagID) and true or false
end

function V:Init()
    if C_Container and C_Container.UseContainerItem then hooksecurefunc(C_Container, "UseContainerItem", onUse)
    elseif _G.UseContainerItem then hooksecurefunc("UseContainerItem", onUse) end

    if _G.HandleModifiedItemClick then
        hooksecurefunc("HandleModifiedItemClick", function(link)
            if link and IsAltKeyDown() and not IsShiftKeyDown() and not IsControlKeyDown()
               and ns.db and bagButtonUnderMouse() then
                V:SetProtected(link)
            end
        end)
    end

    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tip, data)
            if tip ~= GameTooltip or not ns.db then return end
            local id = data and data.id
            if id and isProtected(id) then
                pcall(function() tip:AddLine("Protected from selling (Alt+click to change)", 1, 0.82, 0.2) end)
            end
        end)
    end

    ns:On("MERCHANT_SHOW", function()
        merchantOpen = true
        if ns.db and cfg().autoSellJunk then C_Timer.After(0.2, function() V:SellJunk() end) end
        if ns.db and cfg().autoRepair then C_Timer.After(0.4, function() V:Repair() end) end
    end)
    ns:On("MERCHANT_CLOSED", function() merchantOpen = false; selling = false end)
    ns:On("BANKFRAME_OPENED", function() bankOpen = true; createDepositButton() end)
    ns:On("BANKFRAME_CLOSED", function() bankOpen = false end)
end

V.ProtectedNames = protectedList
V.SellPrice = sellPrice
