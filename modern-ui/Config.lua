local ADDON, ns = ...
local UI = ns.UI
local C = UI.colors

local Config = {}
ns.Config = Config

----------------------------------------------------------------------
-- Option helpers
----------------------------------------------------------------------
local function pct(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end
local function px(v) return string.format("%d px", v) end
local function x2(v) return string.format("%.2f", v) end

local function Header(t) return { type = "header", text = t } end
local function Text(t) return { type = "text", text = t } end
local function Check(path, label) return { type = "check", path = path, label = label } end
local function Range(path, label, min, max, step, fmt)
    return { type = "range", path = path, label = label, min = min, max = max, step = step, fmt = fmt }
end
local function Select(path, label, values) return { type = "select", path = path, label = label, values = values } end
local function Button(label, fn, width) return { type = "button", label = label, onClick = fn, width = width } end

ns.Options = { Header = Header, Text = Text, Check = Check, Range = Range, Select = Select, Button = Button,
               pct = pct, px = px, x2 = x2 }

local OUTLINES = {
    { value = "", label = "None" },
    { value = "OUTLINE", label = "Outline" },
    { value = "THICKOUTLINE", label = "Thick outline" },
}
local HEALTH_FORMATS = {
    { value = "NONE", label = "None" },
    { value = "CURRENT", label = "Current" },
    { value = "PERCENT", label = "Percent" },
    { value = "CURRENT_PERCENT", label = "Current + percent" },
    { value = "CURRENT_MAX", label = "Current / max" },
}
ns.Options.OUTLINES, ns.Options.HEALTH_FORMATS = OUTLINES, HEALTH_FORMATS

----------------------------------------------------------------------
-- Pages
----------------------------------------------------------------------
local function generalOptions()
    return {
        Header("Appearance"),
        Select("general.font", "Font", ns.media.fonts),
        Range("general.fontSize", "Font size", 8, 24, 1, px),
        Select("general.outline", "Font outline", OUTLINES),
        Select("general.texture", "Bar texture", ns.media.textures),
        Range("general.scale", "Global scale (all Modern UI frames)", 0.6, 2, 0.05, x2),
        Header("Tools"),
        Button("Unlock frames (move)", function() ns.Mover:Unlock() end),
        Button("Run setup wizard", function() Config:Hide(); ns.Wizard:Show() end),
        Button("Reset everything to defaults", function()
            UI.Confirm("Reset ALL settings of the active profile to defaults?\nThis also re-runs the layout defaults.", function()
                ns:ResetProfile()
                ns:Print("Profile reset to defaults.")
            end)
        end),
        Text("Slash commands: /mui, /mui wizard, /mui unlock, /mui lock, /mui reset"),
    }
end

local function profileOptions()
    return {
        Header("Profiles"),
        Text("Each character uses one profile. Characters can share a profile, or have their own."),
        { type = "select", label = "Active profile", values = function() return ns:ProfileList() end,
          get = function() return ns.profileName end,
          set = function(v) ns:SelectProfile(v) end },
        Button("New empty profile...", function()
            UI.Prompt("New profile name", "", function(name)
                if name ~= "" and ns:CreateProfile(name) then
                    ns:SelectProfile(name)
                    ns:Print("Created profile " .. name)
                    Config:Hide()
                    ns.Wizard:Show()
                else
                    ns:Print("Invalid or duplicate profile name.")
                end
            end)
        end),
        Button("Copy current to new profile...", function()
            UI.Prompt("Copy to profile name", ns.profileName .. " copy", function(name)
                if name ~= "" and ns:CreateProfile(name, ns.profileName) then
                    ns:SelectProfile(name)
                    ns:Print("Created profile " .. name)
                else
                    ns:Print("Invalid or duplicate profile name.")
                end
            end)
        end),
        Button("Delete current profile", function()
            if ns.profileName == "Default" then
                ns:Print("The Default profile cannot be deleted. Use reset instead.")
                return
            end
            UI.Confirm("Delete profile '" .. ns.profileName .. "'?", function()
                local old = ns.profileName
                ns:SelectProfile("Default")
                ns:DeleteProfile(old)
                ns:Print("Deleted profile " .. old)
            end)
        end),
        Header("Reset"),
        Button("Reset current profile to defaults", function()
            UI.Confirm("Reset profile '" .. ns.profileName .. "' to defaults?", function()
                ns:ResetProfile()
            end)
        end, 240),
    }
end

local function actionBarGeneral()
    return {
        Header("Action Bars"),
        Check("actionbars.enabled", "Replace the Blizzard action bars"),
        Text("Turning this off needs a /reload to bring the Blizzard bars back."),
        Check("actionbars.iconZoom", "Crop icon edges"),
        Check("actionbars.borders", "Draw button borders"),
        Check("actionbars.swingTimer", "Swing timer on the Attack button"),
        Check("actionbars.autoRank", "Auto-replace spells with their highest known rank"),
        Text("Classic only. When you learn a new rank, every lower rank on your bars is swapped for it (runs out of combat)."),
        Header("Layout"),
        Text("Use 'Unlock frames' on the General page (or /mui unlock) to drag bars into place."),
        Button("Unlock frames (move)", function() ns.Mover:Unlock() end),
        Text("Key bindings, flyouts, cooldowns and drag-and-drop still work exactly as before - Modern UI only moves and re-skins the Blizzard buttons."),
    }
end

local function barOptions(def, base)
    local core = type(def.dbKey) == "number" and def.dbKey <= 4
    local o = { Header(def.label) }
    if core then
        o[#o + 1] = Text("Bars 1-4 are the core of the layout and are always shown.")
    else
        o[#o + 1] = Check(base .. ".enabled", "Enable this bar")
    end
    local rest = {
        Range(base .. ".buttons", "Number of buttons", 1, def.count, 1),
        Range(base .. ".perRow", "Buttons per row", 1, def.count, 1),
        Range(base .. ".size", "Button size", 20, 70, 1, px),
        Range(base .. ".spacing", "Spacing", 0, 20, 1, px),
        Range(base .. ".scale", "Scale", 0.5, 2, 0.05, x2),
        Range(base .. ".alpha", "Opacity", 0.1, 1, 0.05, pct),
    }
    for _, r in ipairs(rest) do o[#o + 1] = r end
    if not core then
        o[#o + 1] = Check(base .. ".fade", "Hide until moused over")
        o[#o + 1] = Range(base .. ".fadeAlpha", "Opacity while hidden", 0, 1, 0.05, pct)
    end
    o[#o + 1] = Header("Text")
    o[#o + 1] = Check(base .. ".hotkeys", "Show key bindings")
    o[#o + 1] = Check(base .. ".macros", "Show macro names")
    o[#o + 1] = Check(base .. ".counts", "Show item counts / charges")
    if def.pageable then
        o[#o + 1] = Header("Paging")
        o[#o + 1] = Check(base .. ".paging", "Switch page with stance / form / vehicle / override bar")
    end
    return o
end

local function menuOptions(def)
    local b = "menus." .. def.dbKey
    local o = {
        Header(def.label),
        Check(b .. ".enabled", "Replace the Blizzard " .. def.label:lower()),
        Text("Turning this off needs a /reload to bring the Blizzard version back."),
        Range(b .. ".size", def.bag and "Button size" or "Button width", 14, 64, 1, px),
    }
    if not def.bag then o[#o + 1] = Range(b .. ".height", "Button height", 14, 64, 1, px) end
    local rest = {
        Range(b .. ".spacing", "Spacing", 0, 20, 1, px),
        Range(b .. ".perRow", "Buttons per row", 1, 18, 1),
        Range(b .. ".scale", "Scale", 0.5, 2, 0.05, x2),
        Range(b .. ".alpha", "Opacity", 0.1, 1, 0.05, pct),
        Check(b .. ".attach", "Attach to the left of the right chat window (bottom aligned)"),
        Text("While attached, buttons are square and sized to fill the chat window's height (the size options below are ignored)."),
        Check(b .. ".fade", "Hide until moused over"),
        Range(b .. ".fadeAlpha", "Opacity while hidden", 0, 1, 0.05, pct),
        Check(b .. ".borders", "Draw button borders"),
    }
    for _, r in ipairs(rest) do o[#o + 1] = r end
    if not def.bag then
        o[#o + 1] = Header("Buttons")
        o[#o + 1] = Text("Buttons whose feature this client does not have are hidden automatically. Untick or tick a button to override that.")
        local seen = {}
        for _, name in ipairs(def.names()) do
            if type(name) == "string" and not seen[name] then
                seen[name] = true
                local label = name:gsub("MicroButton$", ""):gsub("(%l)(%u)", "%1 %2")
                o[#o + 1] = { type = "check", label = label,
                    get = function() return not ns.MenuBars.IsButtonHidden(name) end,
                    set = function(v)
                        ns.db.menus.micro.hidden = ns.db.menus.micro.hidden or {}
                        ns.db.menus.micro.hidden[name] = not v   -- explicit false: defaults never refill it
                    end,
                    apply = "menus" }
            end
        end
    end
    return o
end

local function bagWindowOptions()
    return {
        Header("Bag Windows"),
        Check("bagwindows.enabled", "Skin the bag windows"),
        Text("Turning this off needs a /reload to bring Blizzard's bags back."),
        Check("bagwindows.skin", "Flat background and border for the bag windows"),
        Range("bagwindows.bgAlpha", "Background opacity", 0.3, 1, 0.02, pct),
        Check("bagwindows.borders", "Flat item slots with borders"),
        Check("bagwindows.qualityColors", "Color slot borders by item quality"),
        Check("bagwindows.movable", "Move bag windows by dragging their background"),
        Button("Reset bag window positions", function() if ns.BagWindows then ns.BagWindows:ResetPositions() end end),
        Header("Vendor"),
        Check("vendor.autoSellJunk", "Automatically sell gray (junk) items when a merchant opens"),
        Check("vendor.summary", "Print what was sold and for how much"),
        Text("Sold items can be bought back from the merchant's buyback tab."),
    }
end

local function skinOptions()
    local o = {
        Header("Window Skins"),
        Check("skins.enabled", "Skin Blizzard's windows"),
        Text("Turning this off needs a /reload to fully bring Blizzard's windows back."),
        Header("Windows"),
    }
    for _, opt in ipairs(ns.Skins.options) do
        o[#o + 1] = Check("skins." .. opt[1], opt[2])
    end
    o[#o + 1] = Header("Look")
    o[#o + 1] = Range("skins.bgAlpha", "Background opacity", 0.3, 1, 0.02, pct)
    o[#o + 1] = Check("skins.qualityColors", "Color equipment slot borders by item quality")
    return o
end

local function consumableOptions()
    local K = ns.Consumables
    local labels = {}
    for _, c in ipairs(K.CATEGORIES) do labels[c.key] = c.label end
    local function apply() ns:RequestApply("consumables") end
    local o = {
        Header("Food & Water Macros"),
        Check("consumables.enabled", "Keep the " .. K.MACROS.food .. " and " .. K.MACROS.water .. " macros up to date"),
        Text("Creates two global macros (shared by all characters) and points them at the best food / drink in your bags. Drag them to an action bar once; they update themselves, using whichever character is logged in. Updates made in combat wait until combat ends. Items above your level are ignored."),
        Check("consumables.announce", "Print in chat when the pick changes"),
        Button("Update now", function() ns.Consumables:Update() end),
    }
    for _, kind in ipairs({ "food", "water" }) do
        local title = kind == "food" and "Food" or "Water"
        o[#o + 1] = Header(title .. " priority")
        o[#o + 1] = Check("consumables." .. kind .. ".enabled", "Manage the " .. K.MACROS[kind] .. " macro")
        o[#o + 1] = Text("Best first. The item giving the highest ticked stat wins; ties go to the bigger buff, then the bigger restore. Untick a stat to ignore it; with nothing ticked you get the biggest plain " .. kind .. ".")
        o[#o + 1] = { type = "priority", labels = labels, onChange = apply,
            list = function() return ns.db.consumables[kind].priority end,
            disabled = function() return ns.db.consumables[kind].disabled end }
        o[#o + 1] = Button("Reset " .. kind .. " order", function()
            ns.db.consumables[kind].priority = ns.CopyTable(K.DEFAULT_PRIORITY[kind])
            ns.db.consumables[kind].disabled = {}
            apply()
            if ns.Config.RebuildPage then ns.Config:RebuildPage("consumables") end
        end)
    end
    return o
end

local SHAPES = { { value = "square", label = "Square" }, { value = "round", label = "Round" } }
local TEXT_MODES = { { value = "NEVER", label = "Never" }, { value = "HOVER", label = "On mouseover" },
                     { value = "ALWAYS", label = "Always" } }

local function minimapOptions()
    return {
        Header("Minimap"),
        Check("minimap.enabled", "Replace the Blizzard minimap"),
        Text("Turning this off needs a /reload to bring the Blizzard minimap back."),
        Select("minimap.shape", "Shape", SHAPES),
        Range("minimap.size", "Size", 100, 320, 1, px),
        Range("minimap.scale", "Scale", 0.5, 2, 0.05, x2),
        Range("minimap.alpha", "Opacity", 0.1, 1, 0.05, pct),
        Check("minimap.borders", "Draw border (square)"),
        Check("minimap.mouseZoom", "Zoom with the mouse wheel"),
        Header("Text"),
        Check("minimap.zoneText", "Show zone name"),
        Check("minimap.clock", "Show clock"),
        Check("minimap.clock24", "24-hour clock"),
        Check("minimap.serverTime", "Use server time"),
        Header("Buttons"),
        Check("minimap.showTracking", "Tracking"),
        Check("minimap.showCalendar", "Calendar"),
        Check("minimap.showMail", "Mail / crafting orders"),
        Check("minimap.showDifficulty", "Instance difficulty"),
        Check("minimap.showAddons", "Addon compartment"),
        Header("Button flyout"),
        Text("Collects the group finder / PvP queue buttons and addon minimap buttons behind one small + button on the map. A yellow dot on it means a queue is waiting."),
        Check("minimap.flyout", "Collect buttons into a flyout"),
        Check("minimap.flyoutQueue", "Include queue, PvP and landing page buttons"),
        Check("minimap.flyoutAddons", "Include addon minimap buttons"),
        Range("minimap.flyoutColumns", "Flyout columns", 1, 8, 1),
        Range("minimap.flyoutSize", "Flyout button size", 20, 44, 1, px),
        Text("Used only when the flyout is off or does not collect them:"),
        Check("minimap.showLanding", "Landing page button"),
        Check("minimap.showQueue", "Queue status button"),
    }
end

local function trackerOptions()
    return {
        Header("Objective Tracker"),
        Check("tracker.enabled", "Position the quest / objective tracker"),
        Text("Moves Blizzard's tracker to a Modern UI anchor (unlock to drag it). Turning this off needs a /reload."),
        Range("tracker.scale", "Scale", 0.5, 2, 0.05, x2),
        Range("tracker.alpha", "Opacity", 0.1, 1, 0.05, pct),
        Check("tracker.skin", "Skin headers (accent text, no Blizzard header art)"),
        Check("tracker.background", "Draw a background panel behind the quests"),
        Check("tracker.attach", "Attach to the top right of the right chat window (grows upwards)"),
        Range("tracker.bgAlpha", "Background opacity", 0, 1, 0.05, pct),
        Check("tracker.borders", "Draw a border around the panel"),
        Range("tracker.fontSize", "Objective text size (0 = leave as is)", 0, 24, 1),
        Check("tracker.overrideHeight", "Override tracker height"),
        Range("tracker.height", "Height", 150, 900, 10, px),
    }
end

local function dataBarOptions(key, label)
    local b = "databars." .. key
    local o = {
        Header(label),
        Check(b .. ".enabled", "Show " .. label:lower()),
        Range(b .. ".width", "Width", 100, 1200, 5, px),
        Range(b .. ".height", "Height", 4, 30, 1, px),
        Range(b .. ".scale", "Scale", 0.5, 2, 0.05, x2),
        Range(b .. ".alpha", "Opacity", 0.1, 1, 0.05, pct),
        Select(b .. ".text", "Text", TEXT_MODES),
    }
    if key == "xp" then
        o[#o + 1] = Header("Blizzard bar")
        o[#o + 1] = Check("databars.hideBlizzard", "Hide Blizzard's experience / reputation bar")
        o[#o + 1] = Text("The experience bar hides itself at max level, and the reputation bar shows your watched faction.")
    end
    return o
end

local function tooltipOptions()
    return {
        Header("Tooltip"),
        Check("tooltip.enabled", "Skin the tooltips"),
        Text("Turning this off needs a /reload to bring Blizzard's tooltip back."),
        Check("tooltip.skin", "Flat background and border (border colored by item quality)"),
        Check("tooltip.className", "Class / reaction colored name line on unit tooltips"),
        Check("tooltip.classBar", "Class / reaction colored health bar on unit tooltips"),
        Range("tooltip.bgAlpha", "Background opacity", 0.3, 1, 0.02, pct),
        Range("tooltip.fontSize", "Font size (0 = leave as is)", 0, 24, 1),
        Header("Position"),
        Check("tooltip.anchor", "Default tooltips: bottom left just above the top left of action bar 4"),
        Range("tooltip.gap", "Gap above the bar", 0, 30, 1, px),
    }
end

local function nameplateOptions()
    return {
        Header("Nameplates"),
        Check("nameplates.enabled", "Skin nameplates"),
        Text("Draws Modern UI's flat nameplate on units and hides Blizzard's. Enemy players are shown in their class color; friendly plates get a thin white bar with a class-colored name. Turning this off needs a /reload."),
        Check("nameplates.skinFriendly", "Friendly nameplates: thin white bar, class colored name"),
        Header("Size"),
        Range("nameplates.width", "Width", 60, 300, 1, px),
        Range("nameplates.height", "Health bar height", 4, 40, 1, px),
        Range("nameplates.offsetY", "Vertical offset", -40, 40, 1, px),
        Header("Elements"),
        Check("nameplates.showHealthText", "Health percentage"),
        Check("nameplates.showCast", "Cast bar"),
        Range("nameplates.castHeight", "Cast bar height", 4, 24, 1, px),
        Check("nameplates.showDebuffs", "Debuffs on the unit"),
        Check("nameplates.onlyMyDebuffs", "Only my own debuffs"),
        Check("nameplates.debuffTimer", "Time remaining on debuffs"),
        Check("nameplates.showBuffs", "Buffs on the unit"),
        Range("nameplates.debuffSize", "Debuff icon size", 10, 36, 1, px),
        Header("Highlights"),
        Check("nameplates.highlightTarget", "White outline on your target"),
        Check("nameplates.threatOutline", "Red outline when the unit has you on its threat list"),
        Range("nameplates.targetScale", "Target scale", 1, 1.6, 0.05, x2),
        Check("nameplates.dimOthers", "Dim nameplates that are not your target"),
        Range("nameplates.dimAlpha", "Dimmed opacity", 0.2, 1, 0.05, pct),
    }
end

local function chatOptions()
    return {
        Header("Chat"),
        Check("chat.enabled", "Skin the chat windows"),
        Text("Turning this off needs a /reload to bring Blizzard's chat look back."),
        Check("chat.custom", "Modern UI chat window (replaces Blizzard's general chat window; needs /reload)"),
        Text("The general chat is drawn by Modern UI with tabs for Say, Group, Guild, Whispers, Channels and Loot & System. Blizzard's frame keeps handling the messages invisibly. The combat log stays Blizzard's, in a matching window on the other side."),
        Check("chat.systemRight", "Loot & system lines in the right window only (not in the left one)"),
        Header("Tabs"),
        Check("chat.tabs.say", "Say tab"),
        Check("chat.tabs.group", "Group tab"),
        Check("chat.tabs.guild", "Guild tab"),
        Check("chat.tabs.whisper", "Whispers tab"),
        Check("chat.tabs.channel", "Channels tab"),
        Check("chat.tabs.system", "Loot & System tab"),
        Header("Look"),
        Check("chat.skin", "Draw backgrounds behind chat, tabs and edit box"),
        Range("chat.bgAlpha", "Background opacity", 0, 1, 0.05, pct),
        Check("chat.hideButtons", "Hide Blizzard's chat buttons"),
        Select("chat.timestamps", "Timestamps", ns.Chat.TIMESTAMP_FORMATS),
        Check("chat.arrowKeys", "Arrow keys move the text cursor (instead of turning the camera)"),
        { type = "check", label = "Combat log as its own window on the right",
          get = function() return ns.db.chat.combatLog end,
          set = function(v) ns.db.chat.combatLog = v; ns.db.chat.combatLogDone = false end,
          apply = "chat" },
        Range("chat.fontSize", "Font size (0 = leave as is)", 0, 28, 1),
        Header("Position"),
        Check("chat.move", "Take over the main chat window's position and size"),
        Range("chat.width", "Width", 200, 900, 5, px),
        Range("chat.height", "Height", 80, 600, 5, px),
        Button("Unlock frames (move)", function() ns.Mover:Unlock() end),
    }
end

local SESSIONS = { { value = "Current", label = "Current fight" }, { value = "Overall", label = "Overall" } }

local function damageMeterOptions()
    return {
        Header("Damage Meter"),
        Check("damagemeter.enabled", "Show the damage meter window"),
        Text("Reads Blizzard's built-in meter data and draws a compact window. Click the header buttons to switch type / session, R resets."),
        Check("damagemeter.hideBlizzard", "Turn off Blizzard's own damage meter window"),
        Select("damagemeter.type", "Meter type", function() return ns.DamageMeter:TypeValues() end),
        Select("damagemeter.session", "Session", SESSIONS),
        Range("damagemeter.width", "Width", 160, 500, 5, px),
        Range("damagemeter.rows", "Bars shown", 3, 15, 1),
        Range("damagemeter.rowHeight", "Bar height", 12, 30, 1, px),
        Range("damagemeter.scale", "Scale", 0.5, 2, 0.05, x2),
        Range("damagemeter.alpha", "Opacity", 0.1, 1, 0.05, pct),
        Range("damagemeter.bgAlpha", "Background opacity", 0, 1, 0.05, pct),
        Check("damagemeter.showRank", "Show rank numbers"),
        Check("damagemeter.hideOutOfCombat", "Only show in combat"),
        Button("Unlock frames (move)", function() ns.Mover:Unlock() end),
    }
end

local function cooldownOptions()
    local o = {
        Header("Cooldown Manager"),
        Check("cooldowns.enabled", "Position and skin Blizzard's cooldown manager"),
        Text("Moves the cooldown viewers to Modern UI anchors (by default Essential sits between the player and target frames). Turn the viewers on in Blizzard's Edit Mode / cooldown manager settings. Turning this off needs a /reload."),
        Check("cooldowns.skin", "Skin icons (square, no ring art)"),
        Check("cooldowns.zoom", "Crop icon edges"),
        Check("cooldowns.borders", "Draw icon borders"),
    }
    for _, v in ipairs(ns.Cooldowns.viewers) do
        local b = "cooldowns.viewers." .. v.key
        o[#o + 1] = Header(v.label)
        o[#o + 1] = Check(b .. ".enabled", "Manage this viewer")
        o[#o + 1] = Range(b .. ".scale", "Scale", 0.4, 2, 0.05, x2)
        o[#o + 1] = Range(b .. ".alpha", "Opacity", 0.1, 1, 0.05, pct)
    end
    o[#o + 1] = Button("Unlock frames (move)", function() ns.Mover:Unlock() end)
    return o
end

local function unitCommon()
    return {
        Header("Unit Frames"),
        Check("unitframes.enabled", "Replace the Blizzard unit frames"),
        Text("Turning this off needs a /reload to bring the Blizzard frames back."),
        Header("Look"),
        Check("unitframes.classColor", "Class colored health (players)"),
        Check("unitframes.reactionColor", "Reaction colored health (NPCs)"),
        Check("unitframes.smooth", "Smooth bar animation"),
        Select("unitframes.healthTextFormat", "Health text", HEALTH_FORMATS),
        Header("Blizzard buffs / debuffs"),
        Check("unitframes.showBlizzardAuras", "Show Blizzard's buff / debuff window"),
        Text("Off by default: buffs and debuffs are shown on the player and target frames. Re-enabling may need a /reload to restore the window's position."),
        Header("Focus cast bar"),
        Check("unitframes.focusCast.enabled", "Show the focus' cast bar above the player cast bar"),
        Range("unitframes.focusCast.height", "Focus cast bar height", 8, 30, 1, px),
        Text("Works even when the Focus frame is off."),
        Header("Layout"),
        Button("Unlock frames (move)", function() ns.Mover:Unlock() end),
        Text("Party and boss frames only show while you are in a group / an encounter - unlock to see where they sit."),
    }
end

local function frameOptions(key, label, opts)
    opts = opts or {}
    local b = "unitframes.frames." .. key
    local o = {
        Header(label),
        Check(b .. ".enabled", "Enable"),
        Range(b .. ".width", "Width", 60, 400, 1, px),
        Range(b .. ".height", "Height", 14, 100, 1, px),
        Range(b .. ".scale", "Scale", 0.5, 2, 0.05, x2),
        Header("Elements"),
        Check(b .. ".showName", "Show name"),
        Check(b .. ".showHealthText", "Show health text"),
        Select(b .. ".healthFormat", "Health text format", {
            { value = "", label = "Use the global setting" }, { value = "CURRENT", label = "Current" },
            { value = "PERCENT", label = "Percent" }, { value = "CURRENT_PERCENT", label = "Current + percent" },
            { value = "CURRENT_MAX", label = "Current / max" } }),
        Check(b .. ".showPower", "Show power bar"),
        Range(b .. ".powerHeight", "Power bar height", 2, 20, 1, px),
        Check(b .. ".showPowerText", "Show power text"),
        Range(b .. ".fontSize", "Text size (0 = automatic)", 0, 24, 1, px),
        Check(b .. ".textStack", "Name above health text (two lines, centered)"),
        Check(b .. ".showIcons", "Show raid marker / leader / role icons (player: combat / rest)"),
        Check(b .. ".showLevel", "Show level in the name"),
        Check(b .. ".showCastbar", "Show cast bar"),
        { type = "select", label = "Cast bar position", get = function() return ns:Get(b .. ".castAnchor") end,
          set = function(v) ns:Set(b .. ".castAnchor", v) end, apply = "unitframes",
          values = { { value = "frame", label = "On the frame" },
                     { value = "inside", label = "Thin line on the bottom of the health bar" },
                     { value = "bars", label = "Stacked on the top center action bar" },
                     { value = "between", label = "Between player and target frame" } } },
        Check(b .. ".castAbove", "Cast bar above the frame (instead of below)"),
        Check(b .. ".aurasAbove", "Buffs stack above the debuffs (all above the frame)"),
        Range(b .. ".castHeight", "Cast bar height", 2, 30, 1, px),
        Header("Auras"),
        Check(b .. ".showBuffs", "Show buffs"),
        Check(b .. ".onlyMyBuffs", "Only show my own buffs (HoTs)"),
        Check(b .. ".showDebuffs", "Show debuffs"),
        Check(b .. ".onlyMyDebuffs", "Only show my own debuffs"),
        Range(b .. ".auraSize", "Icon size", 12, 40, 1, px),
        Range(b .. ".auraPerRow", "Icons per row", 1, 12, 1),
        Range(b .. ".auraCount", "Maximum icons", 1, 24, 1),
    }
    if key == "target" then
        table.insert(o, 16, Check(b .. ".showCombo", "Show combo points"))
    end
    if opts.group then
        o[#o + 1] = Header("Stacking")
        o[#o + 1] = Range(b .. ".spacing", "Spacing between frames", 0, 40, 1, px)
        o[#o + 1] = Check(b .. ".horizontal", "Lay out in a row (instead of a column)")
        o[#o + 1] = Check(b .. ".growUp", "Stack upwards (column only)")
        o[#o + 1] = Header("Test")
        o[#o + 1] = Button("Toggle test mode (every frame shows you)", function() ns.UnitFrames:Test(key) end)
        o[#o + 1] = Text("Or /mui test " .. key .. ". Shows the frames without a group so size, spacing and position can be checked.")
    end
    return o
end

----------------------------------------------------------------------
-- Page registry
----------------------------------------------------------------------
local pages
local function buildPageList()
    pages = {
        { group = "General" },
        { key = "general", title = "Appearance & Tools", options = generalOptions },
        { key = "profiles", title = "Profiles", options = profileOptions },
        { group = "Action Bars" },
        { key = "abgeneral", title = "General", options = actionBarGeneral },
    }
    for _, def in ipairs(ns.ActionBars.defs) do
        local base = type(def.dbKey) == "number" and ("actionbars.bars." .. def.dbKey) or ("actionbars." .. def.dbKey)
        pages[#pages + 1] = { key = def.id, title = def.label, options = function() return barOptions(def, base) end }
    end
    pages[#pages + 1] = { group = "Menus" }
    for _, def in ipairs(ns.MenuBars.defs) do
        pages[#pages + 1] = { key = def.id, title = def.label, options = function() return menuOptions(def) end }
    end
    pages[#pages + 1] = { key = "bagwindows", title = "Bag Windows", options = bagWindowOptions }
    pages[#pages + 1] = { key = "consumables", title = "Food & Water", options = consumableOptions }
    pages[#pages + 1] = { key = "skins", title = "Window Skins", options = skinOptions }
    pages[#pages + 1] = { group = "Interface" }
    pages[#pages + 1] = { key = "minimap", title = "Minimap", options = minimapOptions }
    pages[#pages + 1] = { key = "tracker", title = "Objective Tracker", options = trackerOptions }
    pages[#pages + 1] = { key = "databar_xp", title = "Experience Bar", options = function() return dataBarOptions("xp", "Experience Bar") end }
    pages[#pages + 1] = { key = "databar_rep", title = "Reputation Bar", options = function() return dataBarOptions("rep", "Reputation Bar") end }
    pages[#pages + 1] = { key = "chat", title = "Chat", options = chatOptions }
    pages[#pages + 1] = { key = "nameplates", title = "Nameplates", options = nameplateOptions }
    pages[#pages + 1] = { key = "tooltip", title = "Tooltip", options = tooltipOptions }
    pages[#pages + 1] = { key = "damagemeter", title = "Damage Meter", options = damageMeterOptions }
    pages[#pages + 1] = { key = "cooldowns", title = "Cooldown Manager", options = cooldownOptions }
    pages[#pages + 1] = { group = "Unit Frames" }
    pages[#pages + 1] = { key = "ufgeneral", title = "General", options = unitCommon }
    for _, p in ipairs({
        { "player", "Player" }, { "target", "Target" }, { "targettarget", "Target of Target" },
        { "focus", "Focus" }, { "pet", "Pet" }, { "party", "Party", true }, { "boss", "Boss", true },
    }) do
        pages[#pages + 1] = { key = "uf_" .. p[1], title = p[2],
            options = function() return frameOptions(p[1], p[2] .. " Frame", { group = p[3] }) end }
    end
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
function Config:Build()
    if self.win then return end
    buildPageList()
    local win = UI.Window("ModernUIConfigFrame", "Modern UI  |cff888888v" .. ns.version .. "|r", 820, 620)
    self.win = win

    local side = CreateFrame("Frame", nil, win)
    side:SetPoint("TOPLEFT", 0, -28)
    side:SetPoint("BOTTOMLEFT", 0, 0)
    side:SetWidth(180)
    side.bg = side:CreateTexture(nil, "BACKGROUND")
    side.bg:SetAllPoints()
    side.bg:SetColorTexture(0.09, 0.09, 0.12, 1)

    -- sidebar scrolls too: the page list is longer than the window
    local sideArea = UI.ScrollArea(side)
    sideArea.frame:SetPoint("TOPLEFT", side, "TOPLEFT", 0, -4)
    sideArea.frame:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", 0, 4)
    self.sideArea = sideArea

    local area = UI.ScrollArea(win)
    area.frame:SetPoint("TOPLEFT", side, "TOPRIGHT", 14, -10)
    area.frame:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -14, 12)
    self.area = area

    local y = -4
    self.buttons = {}
    for _, p in ipairs(pages) do
        if p.group then
            y = y - 6
            local t = UI.Text(sideArea.content, p.group:upper(), "GameFontNormalSmall")
            t:SetTextColor(unpack(C.dim))
            t:SetPoint("TOPLEFT", 10, y)
            y = y - 16
        else
            local b = UI.Button(sideArea.content, p.title, 156, 20, function() Config:ShowPage(p.key) end)
            b:SetPoint("TOPLEFT", 8, y)
            b.text:SetJustifyH("LEFT")
            self.buttons[p.key] = b
            p.button = b
            y = y - 22
        end
    end
    sideArea.contentHeight = -y + 8
    sideArea:SetContentHeight(sideArea.contentHeight)
end

function Config:ShowPage(key)
    self:Build()
    local target
    for _, p in ipairs(pages) do if p.key == key then target = p end end
    target = target or pages[2]
    for _, p in ipairs(pages) do
        if p.container then p.container:Hide() end
        if p.button then p.button:SetSelected(p == target) end
    end
    if not target.container then
        local cont, h, refresh = UI.BuildOptions(self.area.content, target.options(), 520)
        cont:SetPoint("TOPLEFT", self.area.content, "TOPLEFT", 8, -4)
        target.container, target.height, target.refresh = cont, h, refresh
    else
        target.refresh()
    end
    target.container:Show()
    self.current = target
    self.area.contentHeight = target.height + 24
    self.area:SetContentHeight(self.area.contentHeight)
    self.area:ScrollToTop()
end

-- throw away a page's built widgets so the next show rebuilds them (and show it again if it is open)
function Config:RebuildPage(key)
    if not pages then return end
    for _, p in ipairs(pages) do
        if p.key == key and p.container then
            p.container:Hide()
            p.container, p.refresh = nil, nil
            if self.current == p then self:ShowPage(key) end
        end
    end
end

function Config:Refresh()
    if not self.win then return end
    -- Rebuild lazily after profile / preset changes: widgets re-read values.
    for _, p in ipairs(pages) do
        if p.refresh then p.refresh() end
    end
end

function Config:Show(key)
    self:Build()
    self.win:Show()
    self:ShowPage(key or (self.current and self.current.key) or "general")
end

function Config:Hide()
    if self.win then self.win:Hide() end
end

function Config:Toggle()
    self:Build()
    if self.win:IsShown() then self.win:Hide() else self:Show() end
end
