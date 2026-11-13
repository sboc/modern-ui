local ADDON, ns = ...

----------------------------------------------------------------------
-- Defaults = the one standard layout.
--
--   * action bars centered at the bottom (pet / stance bars either side)
--   * player and target frames above the bars
--   * the cooldown manager between them
--   * minimap + objective tracker top right, chat bottom left,
--     damage meter bottom right
----------------------------------------------------------------------
local function merge(base, over)
    local t = ns.CopyTable(base)
    if over then ns.Override(t, over) end
    return t
end

local barBase = {
    enabled = true,
    buttons = 12,
    perRow = 12,
    size = 48,         -- bars 1 / 2 are the big ones (3 / 4 override this)
    spacing = 4,
    scale = 1,
    alpha = 1,
    fade = false,      -- fade out unless moused over
    fadeAlpha = 0,
    hotkeys = true,
    macros = false,
    counts = true,
    paging = true,     -- bar 1 only: stance / form / vehicle paging
}

local frameBase = {
    enabled = true,
    width = 220,
    height = 36,
    scale = 1,
    showPower = true,
    powerHeight = 5,
    showName = true,
    showHealthText = true,
    healthFormat = "",     -- "" = the global health text format
    showPowerText = false,
    fontSize = 0,          -- name / health text size: 0 = automatic
    textStack = false,     -- name above the health text (two centered lines) instead of side by side
    showIcons = true,      -- raid marker, leader, role
    showLevel = false,     -- "60 Name"
    showCombo = false,     -- combo points (target frame; vanilla combo points live on the target)
    showCastbar = false,
    castHeight = 14,
    castAnchor = "frame",  -- "frame" (under the frame), "inside" (strip between health and power bar), "bars" (stacked on the top center action bar) or "between" (player: between player and target)
    castAbove = false,     -- cast bar above the frame instead of below
    aurasAbove = false,    -- buffs stack above the debuffs, all above the frame
    showBuffs = false,
    showDebuffs = false,
    onlyMyDebuffs = false,
    onlyMyBuffs = false,
    auraSize = 20,
    auraPerRow = 8,
    auraCount = 16,
    spacing = 6,           -- party / boss only
    growUp = false,        -- party / boss only
    horizontal = false,    -- party / boss only: lay the frames out in a row
    aboveLift = 0,         -- extra room above the frame for cast bar / auras (a frame stacked above it)
    onlyDispellable = false,   -- debuffs: only the ones you can dispel
}

local viewerBase = { enabled = true, scale = 0.85, alpha = 1 }

ns.defaults = {
    general = {
        font = ns.DEFAULT_FONT,
        fontSize = 14,
        outline = "OUTLINE",
        texture = "Interface\\Buttons\\WHITE8X8",
        scale = 1,
        pixelBorders = true,   -- borders are 1 physical screen pixel at any resolution / UI scale
    },
    actionbars = {
        enabled = true,
        iconZoom = true,
        borders = true,
        swingTimer = true,
        rangedTimer = true,    -- the same countdown on the Auto Shot / Shoot button
        swingBar = false,      -- the running swing / shot timer as a bar of its own
        swingBarWidth = 220, swingBarHeight = 4,
        ammoCount = true,      -- ammunition left, on the Auto Shot button
        ammoWarn = 200,        -- ammunition count turns red below this (0 = never)
        lowCount = 5,          -- item / reagent counts on the bars turn red at or below this (0 = never)
        autoRank = false,      -- classic: replace spells on the bars with their highest known rank
        bars = {
            [1] = merge(barBase),
            [2] = merge(barBase),
            -- bars 1-4 are always shown. 3 / 4 are smaller (34): 2 columns x 6 rows (71 x 219), flanking the stack, same height as the minimap / damage meter
            [3] = merge(barBase, { perRow = 2, size = 34, spacing = 3 }),
            [4] = merge(barBase, { perRow = 2, size = 34, spacing = 3 }),
            [5] = merge(barBase, { enabled = false, perRow = 1 }),
            [6] = merge(barBase, { enabled = false }),
            [7] = merge(barBase, { enabled = false }),
            [8] = merge(barBase, { enabled = false }),
        },
        pet = merge(barBase, { buttons = 10, perRow = 10, size = 28, spacing = 3, paging = false }),
        stance = merge(barBase, { buttons = 10, perRow = 10, size = 28, spacing = 3, paging = false }),
    },
    minimap = {
        enabled = true, shape = "square", size = 219, scale = 1, alpha = 1, borders = true,
        zoneText = true, clock = true, clock24 = true, serverTime = false, mouseZoom = true,
        showTracking = true, showCalendar = true, showMail = true, showDifficulty = true,
        showLanding = true, showQueue = true, showAddons = true,
        flyout = true, flyoutQueue = true, flyoutAddons = true, flyoutColumns = 4, flyoutSize = 28,
        showButton = true, buttonAngle = 180,   -- Modern UI launcher on the map rim (angle in degrees, 0 = right, counter-clockwise)
    },
    tracker = {
        enabled = true, scale = 1, alpha = 1, skin = true, background = true, bgAlpha = 0.55, attach = true,
        borders = true, fontSize = 0, overrideHeight = false, height = 500,
        maxQuests = 0,   -- 0 = no limit; over the limit quests are untracked and remembered (Tracker.lua)
        aprSkin = true,   -- also skin Azeroth Pilot Reloaded's guide panels like the tracker (when installed)
    },
    databars = {
        hideBlizzard = true,
        xp = { enabled = true, width = 620, height = 5, scale = 1, alpha = 1, text = "HOVER" },
        rep = { enabled = true, width = 620, height = 5, scale = 1, alpha = 1, text = "HOVER" },
    },
    chat = {
        enabled = true, skin = true, bgAlpha = 0.88, move = true, width = 500, height = 220,
        fontSize = 16, hideButtons = true, timestamps = "%H:%M ", arrowKeys = true,
        combatLog = true, combatLogDone = false,
        urls = true,   -- web addresses in chat become clickable (opens a copy box)
        fadeDelay = 15, fadeAlpha = 0.2,   -- idle fade: seconds without activity (0 = never), faded opacity
        systemRight = true,   -- loot / system lines live in the right window only
        custom = true,   -- our own chat window (Blizzard's ChatFrame1 keeps routing the messages invisibly)
        tabs = { say = true, group = true, guild = true, whisper = true, channel = true, system = true },
    },
    tooltip = { enabled = true, skin = true, bgAlpha = 0.92, anchor = true, gap = 6, classBar = true, className = true, fontSize = 0 },
    nameplates = {
        enabled = true, skinFriendly = true, width = 190, height = 18, castHeight = 13, offsetY = 0,
        showHealthText = true, showLevel = true, showCast = true, showDebuffs = true, onlyMyDebuffs = false, showBuffs = true, debuffSize = 22,
        debuffTimer = true,   -- time remaining on the debuff icons
        highlightTarget = true, threatOutline = true, targetScale = 1.1, dimOthers = true, dimAlpha = 0.75,
    },
    damagemeter = {
        enabled = true, hideBlizzard = true, width = 219, rows = 8, rowHeight = 23, scale = 1,
        alpha = 1, bgAlpha = 0.45, type = "DamageDone", session = "Current", showRank = true,
        hideOutOfCombat = false,
    },
    cooldowns = {
        enabled = true, skin = true, borders = true, zoom = true,
        viewers = {
            essential = merge(viewerBase, { scale = 0.85 }),
            utility = merge(viewerBase, { scale = 0.7 }),
            buffs = merge(viewerBase, { scale = 0.7 }),
            bars = merge(viewerBase, { scale = 0.8 }),
        },
    },
    menus = {
        -- vertical columns attached to the left side of the right (loot / combat log) window; they fade out until moused over
        micro = { enabled = true, size = 22, height = 30, spacing = 2, perRow = 2, scale = 1,
                  alpha = 1, fade = true, fadeAlpha = 0, borders = true, attach = true,
                  hidden = { HousingMicroButton = true, StoreMicroButton = true } },   -- per button: true = hide, false = show, missing = automatic
        bags = { enabled = true, size = 28, spacing = 3, perRow = 1, scale = 1,
                 alpha = 1, fade = true, fadeAlpha = 0, borders = true, attach = true },
    },
    bagwindows = { enabled = true, skin = true, bgAlpha = 0.92, borders = true, qualityColors = true,
                   movable = true, positions = {} },
    custombags = { enabled = false, bank = true, columns = 10, slotSize = 36, showNew = true,
                   sections = {}, pins = {}, collapsed = {} },   -- bank: grouped bank window too; own sections, itemID -> section key, collapsed sections
    vendor = { autoSellJunk = true, autoRepair = true, summary = true, protected = {}, trashMax = 100 },   -- protected: itemID -> true, selling asks first; trashMax: Trash button highlights gray stacks worth less (copper)
    consumables = {
        enabled = true,    -- keep the Food / Water / Health Potion macros pointed at the best item in the bags
        announce = true,   -- print when the pick changes
        auto = true,       -- derive the food / water stat order from class and spec (manual lists apply when off or undetected)
        food  = { enabled = true, priority = ns.CopyTable(ns.Consumables.DEFAULT_PRIORITY.food),  disabled = {} },
        water = { enabled = true, priority = ns.CopyTable(ns.Consumables.DEFAULT_PRIORITY.water), disabled = {} },
        healthpot = { enabled = true },
        petfood = { enabled = true },   -- hunters only: worst food the current pet can eat
    },
    skins = { enabled = true, character = true, spellbook = true, worldmap = true, gamemenu = true, npc = true, loot = true,
              social = true, bank = true, groupfinder = true, collections = true, services = true, taxi = true, breath = true, bubbles = true,
              bgAlpha = 0.92, qualityColors = true,
              bossmods = true,     -- BigWigs bar style / DBM timer bars
              lootMover = true },  -- group loot roll frames sit on a Modern UI anchor
    misc = { fastLoot = true, afkScreen = true },
    datatexts = { enabled = true, scale = 1, alpha = 1, fontSize = 0, background = true,
                  width = 620,   -- fixed strip width (the action bar stack's); 0 = as wide as its texts
                  gold = true, fps = true, durability = true, bags = true, clock = false,
                  class = true, seen = {} },   -- class: ammunition / reagents; seen: reagent label -> carried at least once
    iteminfo = { enabled = true, character = true, bags = true, sets = true, newGlow = true },
    totems = { enabled = true, size = 32, spacing = 3, scale = 1, last = {} },   -- last: slot -> spell the slot's button casts
    weaponenchants = { enabled = true, size = 24 },
    unitframes = {
        enabled = true,
        classColor = true,
        reactionColor = true,
        smooth = true,
        healthTextFormat = "CURRENT_PERCENT",
        showBlizzardAuras = false,   -- Blizzard's own buff / debuff window
        healPrediction = true,       -- incoming heals drawn past the end of the health bar
        focusCast = { enabled = true, height = 18 },   -- focus cast bar stacked on the player cast bar
        frames = {
            -- player / target are 200 wide: they sit over the left / right ends of the stack, above the focus / target of target row
            player = merge(frameBase, { width = 200, height = 52, powerHeight = 10, castHeight = 18, showCastbar = true,
                castAnchor = "bars", showBuffs = true, showDebuffs = true, aurasAbove = true, auraSize = 22, auraPerRow = 8,
                auraCount = 16 }),
            target = merge(frameBase, { width = 200, height = 52, powerHeight = 10, castHeight = 3, showCastbar = true,
                castAnchor = "inside", aurasAbove = true, showLevel = true, showCombo = true, showBuffs = true,
                showDebuffs = true, onlyMyDebuffs = false, auraSize = 22, auraPerRow = 8, auraCount = 16 }),
            targettarget = merge(frameBase, { width = 200, height = 32, showPower = true, showHealthText = true,
                showIcons = false, showCastbar = true, castHeight = 3, castAnchor = "inside" }),
            -- focus: a small square sitting on top of action bar 3 (71 wide, like the bar);
            -- its cast bar is the separate focus cast bar stacked on the player cast bar
            focus = merge(frameBase, { width = 71, height = 71, showName = false, showHealthText = true,
                healthFormat = "PERCENT", showCastbar = false, castHeight = 3, castAnchor = "inside" }),
            pet = merge(frameBase, { width = 200, height = 32, showPower = true, showHealthText = true,
                showIcons = false }),
            -- party: a row of 4 squares, 219 wide in total = the damage meter's width (4 x 51 + 3 x 5), sitting right above it
            party = merge(frameBase, { width = 51, height = 51, spacing = 5, horizontal = true,
                fontSize = 9, textStack = true, healthFormat = "PERCENT",
                showCastbar = true, castHeight = 3, castAnchor = "inside",
                showBuffs = false, showDebuffs = true,
                auraSize = 16, auraPerRow = 2, auraCount = 4 }),
            boss = merge(frameBase, { width = 200, height = 34, showCastbar = true, showLevel = true,
                castHeight = 3, castAnchor = "inside" }),
        },
    },
    positions = {},
}

----------------------------------------------------------------------
-- Positions of the standard layout ({ anchor point on UIParent, x, y }).
--
-- Bars 1 / 2: stacked, centered, large (48 + 4 gap) = 620 wide, 100 high.
-- Pet + stance bars: one row below bar 1, centered (side by side when both are active).
-- XP + reputation bars: on top of bar 2, stack width.
-- Player cast bar: above the xp bar, stack width.
-- Above that: [ player 200 ][ cooldown manager 220 ][ target 200 ], and under the
-- player / target frames: [ pet 200 ] .. [ target of target 200 ]; the focus cast bar
-- sits on the player cast bar and the focus frame is a square on top of bar 3
-- Bars 3 / 4: smaller (34), 2 columns x 6 rows (71 x 219), flanking the stack.
-- Outside of them, mirrored: damage meter (left) and minimap (right), both
-- 219 x 219 so bars 3 / 4 line up with their height. All bottom aligned with bar 1.
--
--                          [ player 200 ][ cdm 220 ][ target 200 ]   (buffs / debuffs above)
--                          [ pet 200    ]           [ target of target 200 ]
--                          [ focus cast bar (stack width, option)]
--                          [ player cast bar (stack width)       ]
--                          [ xp / rep bar                        ]
--                          [ bar 2  (large)                      ]
--  [ damage ][ b3 ][ b3 ]  [ bar 1  (large)                      ]  [ b4 ][ b4 ][ minimap ]
--  [ meter  ][    ][    ]  [ pet / stance bar (centered)         ]  [    ][    ][         ]
----------------------------------------------------------------------
local function pos(point, x, y) return { point = point, x = x, y = y } end

ns.defaults.positions = {
    bar1 = pos("BOTTOM", 0, 40),
    bar2 = pos("BOTTOM", 0, 92),
    bar3 = pos("BOTTOM", -350, 40),
    bar4 = pos("BOTTOM", 350, 40),
    bar5 = pos("RIGHT", -6, 0),
    bar6 = pos("RIGHT", -48, 0),
    bar7 = pos("CENTER", 300, 200),
    bar8 = pos("CENTER", 0, 260),
    petbar = pos("BOTTOM", 0, 6),
    stancebar = pos("BOTTOM", 0, 6),

    uf_player = pos("BOTTOM", -210, 240),
    uf_target = pos("BOTTOM", 210, 240),
    uf_focus = pos("BOTTOM", -350, 263),
    uf_targettarget = pos("BOTTOM", 210, 202),
    uf_pet = pos("BOTTOM", -210, 202),
    uf_party = pos("BOTTOM", -499, 262),   -- 4 px above the damage meter (bottom 40 + height 218)
    uf_boss = pos("RIGHT", -30, 150),

    -- the cooldown manager sits between player and target (same row)
    cdm_essential = pos("BOTTOM", 0, 240),
    cdm_utility = pos("BOTTOM", 0, 298),
    cdm_buffs = pos("BOTTOM", 0, 338),
    cdm_bars = pos("BOTTOM", 0, 380),
    swingbar = pos("BOTTOM", 0, 293),   -- in the 6 px gap between the Essential (top 292) and Utility (298) rows

    minimap = pos("BOTTOM", 499, 40),
    tracker = pos("TOPRIGHT", -12, -12),
    chat = pos("BOTTOMLEFT", 0, 0),
    chat_combat = pos("BOTTOMRIGHT", 0, 0),
    damagemeter = pos("BOTTOM", -499, 40),
    menu_micro = pos("BOTTOMRIGHT", -10, 10),
    menu_bags = pos("BOTTOMRIGHT", -10, 48),
    databar_xp = pos("BOTTOM", 0, 144),
    databar_rep = pos("BOTTOM", 0, 151),
    datatexts = pos("TOP", 0, -4),
    totembar = pos("BOTTOM", 0, 6),          -- the pet / stance bar spot (shamans have neither)
    weaponenchant = pos("BOTTOM", -350, 338),   -- on top of the focus frame
    lootroll = pos("TOP", 0, -160),
}
