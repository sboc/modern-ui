local ADDON, ns = ...
local UI = ns.UI
local C = UI.colors
local O = ns.Options

-- Setup wizard. Runs for every profile that has not been through it yet (first load, new profile,
-- reset; again whenever SETUP_VERSION is bumped), and can be started any time with /mui wizard.
local W = {}
ns.Wizard = W

----------------------------------------------------------------------
-- "Apply to all" helpers
----------------------------------------------------------------------
local function allBars(fn)
    local ab = ns.db.actionbars
    for i = 1, 8 do fn(ab.bars[i], i) end
    fn(ab.pet, "pet")
    fn(ab.stance, "stance")
end

local function allFrames(fn)
    for _, f in pairs(ns.db.unitframes.frames) do fn(f) end
end

local function enableBar(label, getter)
    return { type = "check", label = label,
        get = function() return getter().enabled end,
        set = function(v) getter().enabled = v end,
        apply = "actionbars" }
end

----------------------------------------------------------------------
-- Steps
----------------------------------------------------------------------
local steps = {}

steps[1] = {
    title = "Welcome to Modern UI",
    desc = "Modern UI replaces the default action bars and unit frames. This short wizard picks a layout and the options you care about. Everything can be changed later with /mui.",
    options = function()
        return {
            O.Text("Nothing here is permanent. Re-run this wizard any time with /mui wizard, or fine-tune individual options in the settings window."),
            O.Header("Start fresh?"),
            O.Text("Your current settings are kept unless you press the button below. It restores every option and every frame position to the Modern UI defaults."),
            O.Button("Reset everything to defaults", function()
                UI.Confirm("Reset ALL Modern UI settings of this profile to defaults?", function()
                    ns:ResetProfile()
                    W:Render()
                end)
            end, 240),
        }
    end,
}

steps[2] = {
    title = "Action bars",
    desc = "Choose which bars to show. Bars that are off keep working through their key bindings.",
    options = function()
        local o = {
            O.Check("actionbars.enabled", "Replace the Blizzard action bars"),
            O.Header("Bars"),
        }
        o[#o + 1] = O.Text("Bars 1-4 are always shown: 1 and 2 stacked in the middle, 3 and 4 smaller (two columns) on either side.")
        for i = 5, 8 do
            o[#o + 1] = enableBar("Action Bar " .. i, function() return ns.db.actionbars.bars[i] end)
        end
        o[#o + 1] = enableBar("Pet Bar", function() return ns.db.actionbars.pet end)
        o[#o + 1] = enableBar("Stance Bar", function() return ns.db.actionbars.stance end)
        o[#o + 1] = O.Header("Look")
        o[#o + 1] = { type = "range", label = "Button size (bars 1 and 2)", min = 24, max = 60, step = 1, fmt = O.px,
            get = function() return ns.db.actionbars.bars[1].size end,
            set = function(v) allBars(function(b, id) if id == 1 or id == 2 or (type(id) == "number" and id >= 5) then b.size = v end end) end,
            apply = "actionbars" }
        o[#o + 1] = { type = "check", label = "Hide bars 5-8 until moused over",
            get = function() return ns.db.actionbars.bars[5].fade end,
            set = function(v) for i = 5, 8 do ns.db.actionbars.bars[i].fade = v end end,
            apply = "actionbars" }
        o[#o + 1] = { type = "check", label = "Show key bindings on buttons",
            get = function() return ns.db.actionbars.bars[1].hotkeys end,
            set = function(v) allBars(function(b) b.hotkeys = v end) end,
            apply = "actionbars" }
        o[#o + 1] = { type = "check", label = "Show macro names on buttons",
            get = function() return ns.db.actionbars.bars[1].macros end,
            set = function(v) allBars(function(b) b.macros = v end) end,
            apply = "actionbars" }
        return o
    end,
}

steps[3] = {
    title = "Unit frames",
    desc = "Choose which frames Modern UI draws. Anything you switch off disappears entirely - and the Blizzard version stays hidden until you /reload with the master option off.",
    options = function()
        local o = {
            O.Check("unitframes.enabled", "Replace the Blizzard unit frames"),
            O.Header("Frames"),
        }
        for _, p in ipairs({
            { "player", "Player" }, { "target", "Target" }, { "targettarget", "Target of Target" },
            { "focus", "Focus" }, { "pet", "Pet" }, { "party", "Party" }, { "boss", "Boss" },
        }) do
            o[#o + 1] = O.Check("unitframes.frames." .. p[1] .. ".enabled", p[2])
        end
        o[#o + 1] = O.Check("unitframes.showBlizzardAuras", "Show Blizzard's buff / debuff window")
        o[#o + 1] = O.Check("unitframes.focusCast.enabled", "Focus cast bar above the player cast bar")
        o[#o + 1] = O.Header("Look")
        o[#o + 1] = O.Check("unitframes.classColor", "Class colored health")
        o[#o + 1] = O.Select("unitframes.healthTextFormat", "Health text", O.HEALTH_FORMATS)
        o[#o + 1] = { type = "range", label = "Frame scale (all frames)", min = 0.6, max = 1.6, step = 0.05, fmt = O.x2,
            get = function() return ns.db.unitframes.frames.player.scale end,
            set = function(v) allFrames(function(f) f.scale = v end) end,
            apply = "unitframes" }
        return o
    end,
}

steps[4] = {
    title = "Game menu & bags",
    desc = "The micro menu (character, spellbook, quests, game menu...) and the bag bar get the same look as the rest.",
    options = function()
        return {
            O.Check("menus.micro.enabled", "Replace the micro menu"),
            O.Check("menus.bags.enabled", "Replace the bag bar"),
            O.Check("bagwindows.enabled", "Skin the bag windows"),
            O.Check("skins.enabled", "Skin Blizzard's windows (character, spellbook, map, quests, bank, mail...)"),
            O.Header("Look"),
            { type = "check", label = "Hide both until moused over",
              get = function() return ns.db.menus.micro.fade and ns.db.menus.bags.fade end,
              set = function(v) ns.db.menus.micro.fade = v; ns.db.menus.bags.fade = v end,
              apply = "menubars" },
            O.Text("Position them with the unlock step at the end. Turning a menu off needs a /reload to bring Blizzard's version back."),
        }
    end,
}

steps[5] = {
    title = "Minimap, quests, XP, chat & meters",
    desc = "Choose which of these Modern UI should take over. Each can be fine-tuned later under Interface in /mui.",
    options = function()
        return {
            O.Check("minimap.enabled", "Minimap"),
            O.Select("minimap.shape", "Minimap shape", { { value = "square", label = "Square" }, { value = "round", label = "Round" } }),
            O.Range("minimap.size", "Minimap size", 100, 320, 1, O.px),
            O.Check("tracker.enabled", "Quest / objective tracker position"),
            O.Check("databars.xp.enabled", "Experience bar"),
            O.Check("databars.rep.enabled", "Reputation bar"),
            O.Check("databars.hideBlizzard", "Hide Blizzard's experience bar"),
            O.Check("chat.enabled", "Chat skin"),
            O.Check("tooltip.enabled", "Tooltip skin"),
            O.Check("nameplates.enabled", "Nameplates"),
            O.Check("damagemeter.enabled", "Damage meter"),
            O.Check("cooldowns.enabled", "Cooldown manager position / skin"),
            O.Check("chat.move", "Take over the chat window's position"),
        }
    end,
}

steps[6] = {
    title = "Extras",
    desc = "Smaller helpers. Pick the ones you want; each has more options in /mui.",
    options = function()
        return {
            O.Header("Bags & vendors"),
            O.Check("custombags.enabled", "Use one grouped bag window (replaces Blizzard's bags)"),
            O.Check("iteminfo.enabled", "Show item details on item slots"),
            O.Check("vendor.autoSellJunk", "Automatically sell gray (junk) items when a merchant opens"),
            O.Check("vendor.autoRepair", "Automatically repair when a repair merchant opens"),
            O.Header("Buffs & consumables"),
            O.Check("consumables.enabled", "Keep the Food and Water macros on the best item in your bags"),
            O.Check("buffreminder.enabled", "Remind me of missing buffs (druids: Mark of the Wild, Thorns)"),
            O.Check("weaponenchants.enabled", "Show temporary weapon enchants with their time left"),
            O.Check("totems.enabled", "Totem bar (shamans)"),
            O.Header("Other"),
            O.Check("datatexts.enabled", "Data text strip at the top of the screen"),
            O.Check("misc.fastLoot", "Fast loot: take everything at once when auto loot is on"),
            O.Check("misc.afkScreen", "Dim the screen and show a timer while you are AFK"),
        }
    end,
}

steps[7] = {
    title = "Appearance",
    desc = "Font and bar texture are shared by every bar and frame.",
    options = function()
        return {
            O.Select("general.font", "Font", ns.media.fonts),
            O.Range("general.fontSize", "Font size", 8, 24, 1, O.px),
            O.Select("general.outline", "Font outline", O.OUTLINES),
            O.Select("general.texture", "Bar texture", ns.media.textures),
        }
    end,
}

-- inserted as step 2: it runs before anything is positioned, so later steps already see the right scale
local function displayStep()
    return {
        title = "Display",
        desc = "Modern UI's default layout is designed for a 1920 x 1080 sized UI. This step reads your screen and sizes everything to fit.",
        options = function()
            local pw, ph = ns.ScreenPixels()
            local uw, uh = ns.UIArea()
            local uiScale = UIParent:GetScale()
            local cur = ns.db.general.scale
            local suggested = ns.SuggestScale()
            local perfect = ns.PerfectUIScale()
            local prev = ModernUIDB and ModernUIDB.prevUiScale

            local o = {
                O.Header("Your screen"),
                O.Text(string.format("Screen: %d x %d pixels (%s).", pw, ph, ns.AspectLabel())),
                O.Text(string.format("Game UI area: %d x %d units at Blizzard UI scale %.2f. Modern UI global scale: %.2f.",
                    uw, uh, uiScale, cur)),
                O.Header("Size"),
            }
            if math.abs(suggested - cur) >= 0.05 then
                o[#o + 1] = O.Text(string.format("The UI area is %s the layout it was designed for. A global scale of %.2f fits it.",
                    suggested < 1 and "smaller than" or "bigger than", suggested))
            else
                o[#o + 1] = O.Text("The global scale already fits your UI area.")
            end
            o[#o + 1] = O.Text("Medium fits your screen as designed. Small and Large size everything down or up from there.")
            for _, b in ipairs(ns.SizeButtons(O.Button, function() W:Render() end)) do o[#o + 1] = b end
            o[#o + 1] = O.Range("general.scale", "Global scale", 0.6, 2, 0.05, O.x2)

            o[#o + 1] = O.Header("Sharp lines")
            o[#o + 1] = O.Check("general.pixelBorders", "Pixel-perfect borders (always one physical pixel wide)")
            if perfect > 1 then
                o[#o + 1] = O.Text("Your screen is too small for a pixel-perfect Blizzard UI scale, so only the borders are snapped.")
            elseif math.abs(uiScale - perfect) < 0.005 then
                o[#o + 1] = O.Text("Blizzard's UI scale is already pixel-perfect: one UI unit is one screen pixel.")
            else
                o[#o + 1] = O.Text(string.format("Optional: set Blizzard's own UI scale to %.3f so one UI unit is exactly one screen pixel. This is the Video > UI Scale setting, so it also changes the default UI and other addons. Pick a size again afterwards.", perfect))
                o[#o + 1] = O.Button("Set pixel-perfect UI scale", function()
                    if InCombatLockdown() then ns:Print("Not in combat.") return end
                    local ok, now, want = ns.SetPerfectUIScale()
                    if not ok then
                        ns:Print(string.format("The client limited the UI scale to %.3f (wanted %.3f).", now, want))
                    end
                    -- UIParent resizes a moment after the CVar changes
                    C_Timer.After(0.3, function()
                        ns:ApplyAll()
                        if W.win and W.win:IsShown() and W.index == 2 then W:Render() end
                    end)
                end, 240)
            end
            if prev then
                o[#o + 1] = O.Button("Restore my previous UI scale", function()
                    if ns.RestoreUIScale() then
                        C_Timer.After(0.3, function()
                            ns:ApplyAll()
                            if W.win and W.win:IsShown() and W.index == 2 then W:Render() end
                        end)
                    else
                        ns:Print("Not in combat.")
                    end
                end, 240)
            end

            o[#o + 1] = O.Header("Positions")
            o[#o + 1] = O.Text("Positions are saved relative to the nearest screen edge, so they survive resolution changes. Ultrawide and narrower screens (16:9 and similar) each have their own default layout; frames you have not moved follow the screen shape.")
            o[#o + 1] = O.Button("Reset all frame positions", function()
                UI.Confirm("Reset every Modern UI frame position to the defaults?", function()
                    ns.db.positions = {}
                    ns:Apply("mover")
                end)
            end, 240)
            return o
        end,
    }
end
table.insert(steps, 2, displayStep())

steps[#steps + 1] = {
    title = "All set",
    desc = "Modern UI is configured. Last step: put things exactly where you want them.",
    options = function()
        return {
            O.Text("Unlock frames to drag every bar and unit frame into place. Arrow keys nudge the box under your cursor; right-click resets it."),
            O.Button("Unlock frames now", function()
                W:Finish()
                ns.Mover:Unlock()
            end),
            O.Button("Open full settings", function()
                W:Finish()
                ns.Config:Show()
            end),
            O.Text("Press Finish to close the wizard. /mui opens the settings, /mui wizard runs this again."),
        }
    end,
}

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
function W:Build()
    if self.win then return end
    local win = UI.Window("ModernUIWizardFrame", "Modern UI Setup", 600, 520)
    self.win = win
    win:SetFrameStrata("FULLSCREEN_DIALOG")

    win.step = UI.Text(win, "", "GameFontNormalSmall", "RIGHT")
    win.step:SetPoint("TOPRIGHT", -40, -9)
    win.step:SetTextColor(unpack(C.dim))

    win.heading = UI.Text(win, "", "GameFontNormalHuge")
    win.heading:SetPoint("TOPLEFT", 24, -46)
    win.heading:SetTextColor(unpack(C.accent))

    win.desc = UI.Text(win, "", "GameFontHighlight")
    win.desc:SetPoint("TOPLEFT", 24, -78)
    win.desc:SetWidth(552)
    win.desc:SetWordWrap(true)
    win.desc:SetTextColor(unpack(C.dim))

    local area = UI.ScrollArea(win)
    area.frame:SetPoint("TOPLEFT", 24, -128)
    area.frame:SetPoint("BOTTOMRIGHT", -24, 62)
    self.area = area

    win.back = UI.Button(win, "Back", 100, 26, function() W:Go(self.index - 1) end)
    win.back:SetPoint("BOTTOMLEFT", 24, 18)
    win.skip = UI.Button(win, "Skip wizard", 120, 26, function()
        W:Finish()
        ns:Print("Wizard skipped. /mui wizard runs it again.")
    end)
    win.skip:SetPoint("BOTTOM", 0, 18)
    win.next = UI.Button(win, "Next", 100, 26, function()
        if W.index >= #steps then W:Finish() else W:Go(W.index + 1) end
    end)
    win.next:SetPoint("BOTTOMRIGHT", -24, 18)
    win.next.text:SetTextColor(unpack(C.accent))
end

function W:Render()
    local step = steps[self.index]
    local win = self.win
    win.step:SetText(string.format("Step %d of %d", self.index, #steps))
    win.heading:SetText(step.title)
    win.desc:SetText(step.desc)
    win.back:SetShown(self.index > 1)
    win.next:SetLabel(self.index >= #steps and "Finish" or "Next")

    for _, s in ipairs(steps) do
        if s.container then s.container:Hide() end
    end
    -- always rebuild so values reflect resets / preset changes
    if step.container then step.container:Hide(); step.container = nil end
    local cont, h
    if step.custom then
        cont, h = step.custom(self.area.content)
    else
        cont, h = UI.BuildOptions(self.area.content, step.options(), 500)
    end
    cont:SetPoint("TOPLEFT", self.area.content, "TOPLEFT", 0, -4)
    cont:Show()
    step.container = cont
    self.area.contentHeight = h + 16
    self.area:SetContentHeight(self.area.contentHeight)
    self.area:ScrollToTop()
end

function W:Go(i)
    self.index = math.max(1, math.min(#steps, i))
    self:Render()
end

function W:Show()
    if not ns.db then return end
    if ns.Mover and ns.Mover:IsUnlocked() then ns.Mover:Lock() end
    if ns.Config then ns.Config:Hide() end
    self:Build()
    self.win:Show()
    self:Go(1)
end

function W:Hide()
    if self.win then self.win:Hide() end
end

function W:Finish()
    ns.db.setupVersion = ns.SETUP_VERSION
    self:Hide()
end
