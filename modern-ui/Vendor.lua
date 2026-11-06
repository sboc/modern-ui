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

local function useItem(bag, slot)
    local fn = (C_Container and C_Container.UseContainerItem) or UseContainerItem
    if fn then pcall(fn, bag, slot) end
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
            if info and info.quality == poor and not info.hasNoValue and not info.isLocked then
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

function V:Init()
    ns:On("MERCHANT_SHOW", function()
        merchantOpen = true
        if ns.db and cfg().autoSellJunk then C_Timer.After(0.2, function() V:SellJunk() end) end
    end)
    ns:On("MERCHANT_CLOSED", function() merchantOpen = false; selling = false end)
end
