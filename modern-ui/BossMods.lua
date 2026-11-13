local ADDON, ns = ...
local UI = ns.UI

-- Boss mod timer bars in the Modern UI look.
--   BigWigs: registers a bar style ("Modern UI") - pick it in BigWigs > Bars > Style.
--   DBM: flat texture, cropped icons and a 1 pixel border on every timer bar.
-- Both only touch the bars through the addons' own style hooks; neither addon is required.
local BM = ns:NewModule("bossmods")
ns.BossMods = BM

local bigwigsDone, dbmDone = false, false

local function on()
    local s = ns.db and ns.db.skins
    return s and s.enabled and s.bossmods
end

-- a dark panel with a black border, one pixel larger than its owner
local function makeBackdrop()
    local bd = CreateFrame("Frame")
    bd.bg = bd:CreateTexture(nil, "BACKGROUND")
    bd.bg:SetAllPoints()
    bd.bg:SetColorTexture(0.03, 0.03, 0.04, 0.9)
    UI.AddBorder(bd, 1, 0, 0, 0, 1, "BORDER")
    return bd
end

-- parent = a frame; around = the region it frames (a frame or a texture of that frame)
local function attach(bd, parent, around)
    around = around or parent
    bd:SetParent(parent)
    bd:ClearAllPoints()
    bd:SetPoint("TOPLEFT", around, "TOPLEFT", -1, 1)
    bd:SetPoint("BOTTOMRIGHT", around, "BOTTOMRIGHT", 1, -1)
    bd:SetFrameLevel(math.max(0, parent:GetFrameLevel() - 1))
    bd:Show()
end

----------------------------------------------------------------------
-- BigWigs
----------------------------------------------------------------------
local pool = {}

local function release(bar, key)
    local bd = bar:Get(key)
    if not bd then return end
    bd:Hide()
    bd:SetParent(UIParent)
    bd:ClearAllPoints()
    pool[#pool + 1] = bd
    bar:Set(key, nil)
end

local function bigwigsApply(bar)
    bar:SetTexture(ns:GetTexture())
    if bar.candyBarBackground then bar.candyBarBackground:SetVertexColor(0, 0, 0, 0) end
    local bd = table.remove(pool) or makeBackdrop()
    attach(bd, bar.candyBarBar)
    bar:Set("modernui:bar", bd)
    local icon = bar.candyBarIconFrame
    if icon and icon.GetTexture and icon:GetTexture() then
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        local ibd = table.remove(pool) or makeBackdrop()
        attach(ibd, bar, icon)   -- the icon is a texture of the bar
        bar:Set("modernui:icon", ibd)
    end
end

local function bigwigsStopped(bar)
    release(bar, "modernui:bar")
    release(bar, "modernui:icon")
    if bar.candyBarBackground then bar.candyBarBackground:SetVertexColor(0.5, 0.5, 0.5, 0.3) end
end

local function registerBigWigs()
    if bigwigsDone or not on() then return end
    local api = _G.BigWigsAPI
    if type(api) ~= "table" or type(api.RegisterBarStyle) ~= "function" then return end
    bigwigsDone = true
    pcall(api.RegisterBarStyle, api, "ModernUI", {
        apiVersion = 1,
        version = 1,
        barSpacing = 4,
        GetSpacing = function() return 4 end,
        ApplyStyle = function(bar) pcall(bigwigsApply, bar) end,
        BarStopped = function(bar) pcall(bigwigsStopped, bar) end,
        GetStyleName = function() return "Modern UI" end,
    })
end

----------------------------------------------------------------------
-- DBM
----------------------------------------------------------------------
local function skinDbmBar(bar)
    local frame = bar and bar.frame
    local name = frame and frame.GetName and frame:GetName()
    if not name then return end
    local tbar = _G[name .. "Bar"]
    if not tbar then return end
    pcall(tbar.SetStatusBarTexture, tbar, ns:GetTexture())
    local spark = _G[name .. "BarSpark"]
    if spark then spark:SetAlpha(0) end
    for _, suffix in ipairs({ "BarIcon1", "BarIcon2" }) do
        local icon = _G[name .. suffix]
        if icon and icon.SetTexCoord then icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
    end
    if not tbar.molBackdrop then
        tbar.molBackdrop = makeBackdrop()
        attach(tbar.molBackdrop, tbar)
    end
end

local function hookDbm()
    if dbmDone or not on() then return end
    local dbt = _G.DBT
    if type(dbt) ~= "table" or type(dbt.CreateBar) ~= "function" then return end
    dbmDone = true
    local function sweep(self)
        if not on() then return end
        pcall(function()
            for bar in self:GetBarIterator() do skinDbmBar(bar) end
        end)
    end
    hooksecurefunc(dbt, "CreateBar", sweep)
    sweep(dbt)
end

local function tryAll()
    registerBigWigs()
    hookDbm()
end

function BM:Init()
    ns:On("ADDON_LOADED", function() if ns.db then tryAll() end end)
    tryAll()
end

function BM:Apply()
    if ns.db then tryAll() end
end
