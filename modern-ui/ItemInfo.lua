local ADDON, ns = ...
local UI = ns.UI

-- Item slot extras: item level on equippable items (character frame and bags), a corner marker on
-- items that belong to an equipment set, and a glow on new bag items.
--   ns.ItemInfo.Decorate(btn, link, isNew, where)   where = "bags" or "character"
local II = ns:NewModule("iteminfo")
ns.ItemInfo = II

local ACCENT = { 0.30, 0.82, 1.00 }
local decorated = {}   -- every button that got an overlay (cleared again when the feature is switched off)
local setItems         -- itemID -> true, nil = rebuild

local function cfg() return ns.db.iteminfo end

local function itemID(link) return tonumber(link:match("item:(%d+)")) end

local function isEquipment(link)
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not getInstant then return false end
    local ok, _, _, _, equipLoc, _, classID = pcall(getInstant, link)
    if not ok then return false end
    -- weapons and armor that actually go into a slot (not bags, not ammunition)
    return (classID == 2 or classID == 4) and type(equipLoc) == "string" and equipLoc ~= "" and equipLoc ~= "INVTYPE_BAG"
end

local function itemLevel(link)
    local get = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo
    if not get then return nil end
    local ok, lvl = pcall(get, link)
    if ok and type(lvl) == "number" and not ns.IsSecret(lvl) and lvl > 0 then return lvl end
end

local function inSet(id)
    if not setItems then
        setItems = {}
        local api = C_EquipmentSet
        if api and api.GetEquipmentSetIDs and api.GetItemIDs then
            pcall(function()
                for _, setID in ipairs(api.GetEquipmentSetIDs()) do
                    for _, item in pairs(api.GetItemIDs(setID) or {}) do
                        if type(item) == "number" and item > 0 then setItems[item] = true end
                    end
                end
            end)
        end
    end
    return setItems[id] or false
end

local function overlay(btn)
    local o = btn.molInfo
    if o then return o end
    o = CreateFrame("Frame", nil, btn)
    o:SetAllPoints()
    o:SetFrameLevel(btn:GetFrameLevel() + 6)
    o:EnableMouse(false)
    o.level = o:CreateFontString(nil, "OVERLAY")
    o.level:SetPoint("BOTTOMRIGHT", -1, 2)
    o.set = o:CreateTexture(nil, "OVERLAY")
    o.set:SetSize(6, 6)
    o.set:SetPoint("TOPLEFT", 2, -2)
    o.set:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    o.glow = CreateFrame("Frame", nil, o)
    o.glow:SetAllPoints()
    UI.AddBorder(o.glow, 2, ACCENT[1], ACCENT[2], ACCENT[3], 1, "OVERLAY")
    btn.molInfo = o
    decorated[btn] = true
    return o
end

function II.Decorate(btn, link, isNew, where)
    if not ns.db or type(btn) ~= "table" then return end
    local c = cfg()
    local on = c.enabled and c[where or "bags"] and type(link) == "string" and not ns.IsSecret(link)
    if not on and not btn.molInfo then return end
    local o = overlay(btn)
    local level, set = nil, false
    if on and isEquipment(link) then
        level = itemLevel(link)
        local id = c.sets and itemID(link)
        set = id and inSet(id) or false
    end
    if level then
        ns:SetFont(o.level, math.max(8, math.floor((btn:GetWidth() or 36) * 0.30)), "OUTLINE")
        o.level:SetText(level)
    else
        o.level:SetText("")
    end
    o.set:SetShown(set)
    o.glow:SetShown(c.enabled and c.newGlow and where ~= "character" and isNew and true or false)
end

-- a Blizzard bag button: the bag / slot come from the button itself
function II.DecorateBagButton(btn)
    local parent = btn:GetParent()
    local bag = btn.GetBagID and btn:GetBagID() or (parent and parent:GetID())
    local slot = btn:GetID()
    local link
    if bag and slot and C_Container and C_Container.GetContainerItemLink then
        local ok, l = pcall(C_Container.GetContainerItemLink, bag, slot)
        link = ok and l or nil
    end
    II.Decorate(btn, link, false, "bags")
end

local function characterSlot(btn)
    if type(btn) ~= "table" or not btn.GetID then return end
    local ok, link = pcall(GetInventoryItemLink, "player", btn:GetID())
    II.Decorate(btn, ok and link or nil, false, "character")
end

function II:Init()
    if type(_G.PaperDollItemSlotButton_Update) == "function" then
        hooksecurefunc("PaperDollItemSlotButton_Update", function(btn) pcall(characterSlot, btn) end)
    end
    ns:On("EQUIPMENT_SETS_CHANGED", function() setItems = nil end)
end

function II:Apply()
    if not ns.db then return end
    setItems = nil
    if not cfg().enabled then
        for btn in pairs(decorated) do II.Decorate(btn, nil) end
    end
    if ns.BagWindows and ns.BagWindows.RequestRestyle then ns.BagWindows.RequestRestyle() end
    if ns.CustomBags and ns.CustomBags.Refresh then ns.CustomBags:Refresh() end
    if _G.CharacterFrame and _G.CharacterFrame:IsShown() then
        for _, name in ipairs({ "Head", "Neck", "Shoulder", "Back", "Chest", "Shirt", "Tabard", "Wrist", "Hands", "Waist",
                                "Legs", "Feet", "Finger0", "Finger1", "Trinket0", "Trinket1", "MainHand", "SecondaryHand", "Ranged" }) do
            pcall(characterSlot, _G["Character" .. name .. "Slot"])
        end
    end
end
