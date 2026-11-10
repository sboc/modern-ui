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

-- originals, captured before the sell guard below wraps them (auto sell and confirmed sells go through these)
local origUse = (C_Container and C_Container.UseContainerItem) or UseContainerItem
local origGlobalUse = _G.UseContainerItem

local function useItem(bag, slot)
    if origUse then pcall(origUse, bag, slot) end
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

-- confirm popup for selling a protected item
local function confirmSell(bag, slot, id, link)
    ns.UI.Confirm("Sell protected item?\n" .. (link or itemName(nil, id)), function()
        if merchantOpen and slotItemID(bag, slot) == id then useItem(bag, slot) end
    end)
end

local function guard(orig)
    return function(bag, slot, ...)
        if merchantOpen and ns.db and not InCombatLockdown() then
            local id, info = slotItemID(bag, slot)
            if isProtected(id) then
                confirmSell(bag, slot, id, info and info.hyperlink)
                return
            end
        end
        return orig(bag, slot, ...)
    end
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

-- Alt+click an item in a bag toggles its protection
local function bagButtonUnderMouse()
    local f
    if GetMouseFoci then f = GetMouseFoci(); f = f and f[1] else f = GetMouseFocus and GetMouseFocus() end
    if not f then return false end
    return (f.molBag or f.GetBagID) and true or false
end

function V:Init()
    if C_Container and C_Container.UseContainerItem then C_Container.UseContainerItem = guard(origUse)
    elseif origGlobalUse then _G.UseContainerItem = guard(origGlobalUse) end

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
    end)
    ns:On("MERCHANT_CLOSED", function() merchantOpen = false; selling = false end)
end

V.ProtectedNames = protectedList
