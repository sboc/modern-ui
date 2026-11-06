local ADDON, ns = ...

-- Small self-contained widget kit. Built from plain frames and textures only,
-- so it does not depend on Blizzard templates that change between patches.
local UI = {}
ns.UI = UI

local C = {
    bg = { 0.07, 0.07, 0.09, 0.97 },
    panel = { 0.12, 0.12, 0.15, 1 },
    hover = { 0.20, 0.20, 0.26, 1 },
    accent = { 0.30, 0.82, 1.00, 1 },
    text = { 0.92, 0.92, 0.92, 1 },
    dim = { 0.62, 0.62, 0.68, 1 },
}
UI.colors = C

----------------------------------------------------------------------
-- Primitives
----------------------------------------------------------------------
-- Borders are measured in physical screen pixels (when general.pixelBorders is on), so a 1 pixel
-- border is one crisp pixel at any resolution / UI scale. They are re-measured whenever scales change.
local borderRegistry = setmetatable({}, { __mode = "k" })

function UI.RefreshBorders()
    for edges in pairs(borderRegistry) do edges:Refresh() end
end

function UI.AddBorder(f, size, r, g, b, a, layer)
    size = size or 1
    local edges = { units = size }
    local function edge()
        local t = f:CreateTexture(nil, layer or "BORDER")
        t:SetColorTexture(r or 0, g or 0, b or 0, a or 1)
        edges[#edges + 1] = t
        return t
    end
    local top, bottom, left, right = edge(), edge(), edge(), edge()
    top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT")
    bottom:SetPoint("BOTTOMLEFT"); bottom:SetPoint("BOTTOMRIGHT")
    left:SetPoint("TOPLEFT"); left:SetPoint("BOTTOMLEFT")
    right:SetPoint("TOPRIGHT"); right:SetPoint("BOTTOMRIGHT")
    local function setSize(sz)
        top:SetHeight(sz); bottom:SetHeight(sz); left:SetWidth(sz); right:SetWidth(sz)
    end
    function edges.SetColor(_, nr, ng, nb, na)
        for i = 1, 4 do edges[i]:SetColorTexture(nr, ng, nb, na or 1) end
    end
    -- raw UI units, never re-measured
    function edges.SetSize(_, sz)
        edges.raw = true
        setSize(sz)
    end
    -- n physical pixels (UI units when pixel borders are off)
    function edges.SetPixels(_, n)
        edges.raw = false
        edges.units = n
        edges:Refresh()
    end
    function edges.Refresh()
        if edges.raw then return end
        local gen = ns.db and ns.db.general
        if gen and gen.pixelBorders and ns.PixelSize then
            setSize(edges.units * ns.PixelSize(f))
        else
            setSize(edges.units)
        end
    end
    borderRegistry[edges] = true
    edges:Refresh()
    return edges
end

function UI.Box(parent, color)
    local f = CreateFrame("Frame", nil, parent)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(unpack(color or C.bg))
    f.borders = UI.AddBorder(f, 1, 0, 0, 0, 1)
    return f
end

function UI.Text(parent, text, template, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    -- keep the template's size/flags, swap only the face (fixed path: UI chrome ignores the font setting)
    local _, size, flags = fs:GetFont()
    pcall(fs.SetFont, fs, ns.DEFAULT_FONT, (size or 12) + 2, flags or "")
    fs:SetJustifyH(justify or "LEFT")
    if text then fs:SetText(text) end
    return fs
end

function UI.Button(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 100, h or 22)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(unpack(C.panel))
    b.borders = UI.AddBorder(b, 1, 0, 0, 0, 1)
    b.text = UI.Text(b, text, "GameFontHighlight", "CENTER")
    b.text:SetPoint("LEFT", 6, 0)
    b.text:SetPoint("RIGHT", -6, 0)
    b.SetLabel = function(self, t) self.text:SetText(t) end
    b.SetSelected = function(self, sel)
        self.selected = sel
        self.bg:SetColorTexture(unpack(sel and C.hover or C.panel))
        self.borders:SetColor(sel and C.accent[1] or 0, sel and C.accent[2] or 0, sel and C.accent[3] or 0, 1)
    end
    b:SetScript("OnEnter", function(self) self.bg:SetColorTexture(unpack(C.hover)) end)
    b:SetScript("OnLeave", function(self) self.bg:SetColorTexture(unpack(self.selected and C.hover or C.panel)) end)
    b:SetScript("OnClick", function(self, ...) if onClick then onClick(self, ...) end end)
    return b
end

----------------------------------------------------------------------
-- Checkbox
----------------------------------------------------------------------
function UI.Checkbox(parent, label, get, set)
    local f = CreateFrame("Button", nil, parent)
    f:SetHeight(22)
    local box = CreateFrame("Frame", nil, f)
    box:SetSize(16, 16)
    box:SetPoint("LEFT", 0, 0)
    box.bg = box:CreateTexture(nil, "BACKGROUND")
    box.bg:SetAllPoints()
    box.bg:SetColorTexture(unpack(C.panel))
    box.borders = UI.AddBorder(box, 1, 0, 0, 0, 1)
    local check = box:CreateTexture(nil, "ARTWORK")
    check:SetPoint("TOPLEFT", 3, -3)
    check:SetPoint("BOTTOMRIGHT", -3, 3)
    check:SetColorTexture(unpack(C.accent))
    f.text = UI.Text(f, label)
    f.text:SetPoint("LEFT", box, "RIGHT", 8, 0)
    function f:Refresh() check:SetShown(get() and true or false) end
    f:SetScript("OnClick", function() set(not get()); f:Refresh() end)
    f:SetScript("OnEnter", function() box.bg:SetColorTexture(unpack(C.hover)) end)
    f:SetScript("OnLeave", function() box.bg:SetColorTexture(unpack(C.panel)) end)
    f:Refresh()
    return f
end

----------------------------------------------------------------------
-- Slider
----------------------------------------------------------------------
function UI.Slider(parent, label, min, max, step, get, set, fmt)
    fmt = fmt or function(v) return tostring(v) end
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(40)
    f.text = UI.Text(f, label)
    f.text:SetPoint("TOPLEFT", 0, 0)
    f.valueText = UI.Text(f, "", "GameFontNormal", "RIGHT")
    f.valueText:SetPoint("TOPRIGHT", 0, 0)

    local s = CreateFrame("Slider", nil, f)
    s:SetOrientation("HORIZONTAL")
    s:SetHeight(14)
    s:SetPoint("BOTTOMLEFT", 0, 4)
    s:SetPoint("BOTTOMRIGHT", 0, 4)
    s:SetMinMaxValues(min, max)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT"); track:SetPoint("RIGHT"); track:SetHeight(4)
    track:SetColorTexture(unpack(C.panel))
    s:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    local thumb = s:GetThumbTexture()
    thumb:SetSize(8, 14)
    thumb:SetVertexColor(unpack(C.accent))
    f.slider = s

    local function snap(v)
        v = math.floor((v - min) / step + 0.5) * step + min
        return tonumber(string.format("%.4f", v))
    end

    s:SetScript("OnValueChanged", function(_, v)
        if f.updating then return end
        v = snap(v)
        f.valueText:SetText(fmt(v))
        if v ~= get() then set(v) end
    end)
    -- no mouse wheel on sliders: they would swallow the wheel and block page scrolling

    function f:Refresh()
        local v = get()
        if type(v) ~= "number" then v = min end
        f.updating = true
        s:SetValue(v)
        f.updating = false
        f.valueText:SetText(fmt(v))
    end
    f:Refresh()
    return f
end

----------------------------------------------------------------------
-- Dropdown (custom list, no Blizzard dropdown API)
----------------------------------------------------------------------
local dropList, dropCatcher
local ROW_H, MAX_ROWS = 22, 12

local function CloseDrop()
    if dropList then dropList:Hide() end
    if dropCatcher then dropCatcher:Hide() end
end

local function GetDropList()
    if dropList then return dropList end
    dropCatcher = CreateFrame("Button", nil, UIParent)
    dropCatcher:SetAllPoints(UIParent)
    dropCatcher:SetFrameStrata("FULLSCREEN")
    dropCatcher:RegisterForClicks("AnyUp")
    dropCatcher:SetScript("OnClick", CloseDrop)
    dropCatcher:Hide()

    dropList = UI.Box(UIParent, C.bg)
    dropList:SetFrameStrata("FULLSCREEN_DIALOG")
    dropList:SetToplevel(true)
    dropList:EnableMouse(true)
    dropList:EnableMouseWheel(true)
    dropList.rows = {}
    dropList.offset = 0
    dropList:Hide()

    function dropList:Redraw()
        local items = self.items
        for i = 1, MAX_ROWS do
            local row = self.rows[i]
            local item = items[i + self.offset]
            if item and i <= self.shown then
                row.item = item
                row.text:SetText(item.label)
                row.text:SetTextColor(unpack(item.value == self.current and C.accent or C.text))
                row:Show()
            elseif row then
                row:Hide()
            end
        end
    end

    dropList:SetScript("OnMouseWheel", function(self, delta)
        local maxOff = math.max(0, #self.items - self.shown)
        self.offset = math.max(0, math.min(maxOff, self.offset - delta))
        self:Redraw()
    end)
    dropList:SetScript("OnHide", function() dropCatcher:Hide() end)
    return dropList
end

function UI.OpenDropdown(owner, items, current, onSelect)
    local l = GetDropList()
    if l:IsShown() and l.owner == owner then CloseDrop() return end
    l.owner, l.items, l.current, l.offset = owner, items, current, 0
    l.shown = math.min(#items, MAX_ROWS)
    for i = 1, MAX_ROWS do
        if not l.rows[i] then
            local row = CreateFrame("Button", nil, l)
            row:SetHeight(ROW_H)
            row:SetPoint("TOPLEFT", 1, -(i - 1) * ROW_H - 1)
            row:SetPoint("TOPRIGHT", -1, -(i - 1) * ROW_H - 1)
            row.hl = row:CreateTexture(nil, "BACKGROUND")
            row.hl:SetAllPoints()
            row.hl:SetColorTexture(unpack(C.hover))
            row.hl:Hide()
            row.text = UI.Text(row, "")
            row.text:SetPoint("LEFT", 8, 0)
            row:SetScript("OnEnter", function(self) self.hl:Show() end)
            row:SetScript("OnLeave", function(self) self.hl:Hide() end)
            row:SetScript("OnClick", function(self)
                CloseDrop()
                if l.onSelect then l.onSelect(self.item.value) end
            end)
            l.rows[i] = row
        end
    end
    l.onSelect = onSelect
    l:ClearAllPoints()
    l:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    l:SetWidth(math.max(owner:GetWidth(), 140))
    l:SetHeight(l.shown * ROW_H + 2)
    l:Redraw()
    dropCatcher:Show()
    l:Show()
end

function UI.Dropdown(parent, label, items, get, set, width)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(46)
    f.text = UI.Text(f, label)
    f.text:SetPoint("TOPLEFT", 0, 0)
    local btn = UI.Button(f, "", width or 220, 22)
    btn:SetPoint("BOTTOMLEFT", 0, 0)
    local arrow = UI.Text(btn, "v", "GameFontNormal", "RIGHT")
    arrow:SetPoint("RIGHT", -8, 0)
    btn.text:SetPoint("RIGHT", -20, 0)
    btn.text:SetJustifyH("LEFT")
    f.button = btn

    local function list() return type(items) == "function" and items() or items end

    function f:Refresh()
        local cur, name = get(), nil
        for _, it in ipairs(list()) do
            if it.value == cur then name = it.label break end
        end
        btn:SetLabel(name or tostring(cur or "?"))
    end
    btn:SetScript("OnClick", function()
        UI.OpenDropdown(btn, list(), get(), function(v) set(v); f:Refresh() end)
    end)
    f:Refresh()
    return f
end

----------------------------------------------------------------------
-- Windows, prompts, confirm
----------------------------------------------------------------------
function UI.Window(name, title, w, h, strata)
    local f = UI.Box(UIParent, C.bg)
    if name then _G[name] = f; table.insert(UISpecialFrames, name) end
    f:SetSize(w, h)
    f:SetPoint("CENTER")
    -- strata is set before any child frame exists, so children inherit it; fixed so nothing re-sorts it
    f:SetFrameStrata(strata or "DIALOG")
    f:SetFixedFrameStrata(true)
    f:SetToplevel(true)
    f:Hide()   -- windows start hidden: callers Show() them (otherwise the first Toggle would hide a fresh window)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)

    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("TOPLEFT"); bar:SetPoint("TOPRIGHT"); bar:SetHeight(28)
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetColorTexture(0.10, 0.10, 0.13, 1)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() f:StartMoving() end)
    bar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f.title = UI.Text(bar, title, "GameFontNormalLarge")
    f.title:SetPoint("LEFT", 12, 0)

    local close = UI.Button(bar, "X", 22, 20, function() f:Hide() end)
    close:SetPoint("RIGHT", -4, 0)
    f.titleBar = bar
    return f
end

local prompt
function UI.Prompt(title, default, onAccept)
    if not prompt then
        prompt = UI.Window(nil, "", 320, 130, "FULLSCREEN_DIALOG")
        prompt.edit = CreateFrame("EditBox", nil, prompt)
        prompt.edit:SetFontObject("GameFontHighlight")
        pcall(prompt.edit.SetFont, prompt.edit, ns.DEFAULT_FONT, 14, "")
        prompt.edit:SetAutoFocus(true)
        prompt.edit:SetSize(280, 22)
        prompt.edit:SetPoint("TOP", 0, -50)
        prompt.edit:SetTextInsets(6, 6, 0, 0)
        prompt.edit.bg = prompt.edit:CreateTexture(nil, "BACKGROUND")
        prompt.edit.bg:SetAllPoints()
        prompt.edit.bg:SetColorTexture(unpack(C.panel))
        UI.AddBorder(prompt.edit, 1, 0, 0, 0, 1)
        prompt.edit:SetScript("OnEscapePressed", function() prompt:Hide() end)
        prompt.edit:SetScript("OnEnterPressed", function() prompt.ok:Click() end)
        prompt.ok = UI.Button(prompt, "OK", 100, 24, function()
            local t = prompt.edit:GetText()
            prompt:Hide()
            if prompt.cb then prompt.cb(t) end
        end)
        prompt.ok:SetPoint("BOTTOMRIGHT", prompt, "BOTTOM", -6, 12)
        prompt.cancel = UI.Button(prompt, "Cancel", 100, 24, function() prompt:Hide() end)
        prompt.cancel:SetPoint("BOTTOMLEFT", prompt, "BOTTOM", 6, 12)
    end
    prompt.title:SetText(title)
    prompt.cb = onAccept
    prompt.edit:SetText(default or "")
    prompt:ClearAllPoints()
    prompt:SetPoint("CENTER", 0, 120)
    prompt:Show()
    prompt:Raise()
    prompt.edit:SetFocus()
end

local confirm
function UI.Confirm(text, onYes)
    if not confirm then
        confirm = UI.Window(nil, "Confirm", 360, 140, "FULLSCREEN_DIALOG")
        confirm.msg = UI.Text(confirm, "", "GameFontHighlight", "CENTER")
        confirm.msg:SetPoint("TOPLEFT", 16, -44)
        confirm.msg:SetPoint("TOPRIGHT", -16, -44)
        confirm.msg:SetWordWrap(true)
        confirm.yes = UI.Button(confirm, "Yes", 100, 24, function()
            confirm:Hide()
            if confirm.cb then confirm.cb() end
        end)
        confirm.yes:SetPoint("BOTTOMRIGHT", confirm, "BOTTOM", -6, 12)
        confirm.no = UI.Button(confirm, "No", 100, 24, function() confirm:Hide() end)
        confirm.no:SetPoint("BOTTOMLEFT", confirm, "BOTTOM", 6, 12)
    end
    confirm.msg:SetText(text)
    confirm.cb = onYes
    confirm:ClearAllPoints()
    confirm:SetPoint("CENTER", 0, 120)
    confirm:Show()
    confirm:Raise()
end

----------------------------------------------------------------------
-- Scroll area (custom: clip frame + content + thin scrollbar)
----------------------------------------------------------------------
function UI.ScrollArea(parent)
    local sf = CreateFrame("ScrollFrame", nil, parent)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(1, 1)
    sf:SetScrollChild(content)

    local bar = CreateFrame("Slider", nil, parent)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(6)
    bar:SetPoint("TOPRIGHT", sf, "TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", sf, "BOTTOMRIGHT", 0, 0)
    bar:SetMinMaxValues(0, 1)
    bar:SetValueStep(1)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(unpack(C.panel))
    bar:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    bar:GetThumbTexture():SetSize(6, 40)
    bar:GetThumbTexture():SetVertexColor(unpack(C.accent))

    local area = { frame = sf, content = content, bar = bar }

    function area:SetContentHeight(h)
        content:SetHeight(math.max(h, 1))
        local range = math.max(0, h - sf:GetHeight())
        bar:SetMinMaxValues(0, range)
        bar:SetShown(range > 0)
        if sf:GetVerticalScroll() > range then sf:SetVerticalScroll(range) end
        bar:SetValue(sf:GetVerticalScroll())
    end
    function area:ScrollToTop() sf:SetVerticalScroll(0); bar:SetValue(0) end
    function area:ScrollToBottom()
        local _, max = bar:GetMinMaxValues()
        sf:SetVerticalScroll(max or 0)
        bar:SetValue(max or 0)
    end

    bar:SetScript("OnValueChanged", function(_, v) sf:SetVerticalScroll(v) end)
    local function wheel(_, delta)
        local _, max = bar:GetMinMaxValues()
        bar:SetValue(math.max(0, math.min(max, bar:GetValue() - delta * 40)))
    end
    -- wheel works over the whole window, not just the clip frame
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", wheel)
    parent:EnableMouseWheel(true)
    parent:SetScript("OnMouseWheel", wheel)
    sf:SetScript("OnSizeChanged", function(_, w, h)
        content:SetWidth(w - 12)
        if area.contentHeight then area:SetContentHeight(area.contentHeight) end
    end)
    return area
end

----------------------------------------------------------------------
-- Declarative option builder
--   { type="header", text=... }
--   { type="text",   text=... }
--   { type="check",  path=..., label=... }
--   { type="range",  path=..., label=..., min=, max=, step=, fmt= }
--   { type="select", path=..., label=..., values={ {value=,label=}, ... } | function }
--   { type="button", label=..., onClick=function }
--   { type="spacer", height=n }
--   { type="priority", list=function() -> array of keys, disabled=function() -> {key=true}, labels={key=label},
--                      onChange=function() }   reorderable list with on / off toggles
-- Every setting is bound to a path inside ns.db and applies live.
----------------------------------------------------------------------
-- Reorderable list: up / down arrows move a row, the checkbox turns a row on / off.
function UI.PriorityList(parent, o, width)
    local ROW = 24
    local f = CreateFrame("Frame", nil, parent)
    f:SetWidth(width)
    local rows = {}

    local function row(i)
        if rows[i] then return rows[i] end
        local r = CreateFrame("Frame", nil, f)
        r:SetSize(math.min(width, 340), ROW)
        r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW)
        r.num = UI.Text(r, "", "GameFontHighlight")
        r.num:SetPoint("LEFT", 2, 0)
        r.num:SetWidth(20)
        r.num:SetTextColor(unpack(C.dim))
        r.up = UI.Button(r, "^", 22, 20, function() r.move(-1) end)
        r.up:SetPoint("RIGHT", -26, 0)
        r.down = UI.Button(r, "v", 22, 20, function() r.move(1) end)
        r.down:SetPoint("RIGHT", 0, 0)
        r.check = UI.Checkbox(r, "", function() return not o.disabled()[r.key] end, function(v)
            o.disabled()[r.key] = (not v) or nil
            if o.onChange then o.onChange() end
        end)
        r.check:SetPoint("LEFT", 24, 0)
        r.check:SetWidth(260)
        r.move = function(d)
            local list = o.list()
            local j = r.index + d
            if j < 1 or j > #list then return end
            list[r.index], list[j] = list[j], list[r.index]
            f:Refresh()
            if o.onChange then o.onChange() end
        end
        rows[i] = r
        return r
    end

    function f:Refresh()
        local list = o.list()
        for i, key in ipairs(list) do
            local r = row(i)
            r.index, r.key = i, key
            r.num:SetText(i .. ".")
            if r.check.text then r.check.text:SetText((o.labels and o.labels[key]) or key) end
            r.check:Refresh()
            r:Show()
        end
        for i = #list + 1, #rows do rows[i]:Hide() end
    end

    f:SetHeight(#o.list() * ROW)
    f:Refresh()
    return f
end

local function pathRoot(path) return path:match("^[^%.]+") end

function UI.BuildOptions(parent, options, width)
    local container = CreateFrame("Frame", nil, parent)
    container:SetWidth(width)
    local y = 0
    local widgets = {}

    for _, o in ipairs(options) do
        local w, h
        -- o.get / o.set override the default path binding (used for "apply to
        -- all bars" style controls and for profile management).
        local function get()
            if o.get then return o.get() end
            return ns:Get(o.path)
        end
        local function set(v)
            if o.set then
                o.set(v)
            else
                ns:Set(o.path, v)
            end
            if o.onChange then o.onChange(v) end
            local root = o.apply or (o.path and pathRoot(o.path))
            if root then ns:RequestApply(root) end
        end

        if o.type == "header" then
            y = y + 8
            w = UI.Text(container, o.text, "GameFontNormalLarge")
            w:SetTextColor(unpack(C.accent))
            local line = container:CreateTexture(nil, "ARTWORK")
            line:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.35)
            line:SetHeight(1)
            line:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -(y + 22))
            line:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -(y + 22))
            w:SetPoint("TOPLEFT", 0, -y)
            h = 30
        elseif o.type == "text" then
            w = UI.Text(container, o.text, "GameFontHighlight")
            w:SetTextColor(unpack(C.dim))
            w:SetWidth(width)
            w:SetWordWrap(true)
            w:SetPoint("TOPLEFT", 0, -y)
            h = math.max(14, w:GetStringHeight()) + 8
        elseif o.type == "check" then
            w = UI.Checkbox(container, o.label, get, set)
            w:SetWidth(width)
            w:SetPoint("TOPLEFT", 0, -y)
            h = 26
        elseif o.type == "range" then
            w = UI.Slider(container, o.label, o.min, o.max, o.step or 1, get, set, o.fmt)
            w:SetWidth(math.min(width, 340))
            w:SetPoint("TOPLEFT", 0, -y)
            h = 46
        elseif o.type == "select" then
            w = UI.Dropdown(container, o.label, o.values, get, set, math.min(width, 260))
            w:SetWidth(math.min(width, 260))
            w:SetPoint("TOPLEFT", 0, -y)
            h = 52
        elseif o.type == "button" then
            w = UI.Button(container, o.label, o.width or 200, 24, function() o.onClick() end)
            w:SetPoint("TOPLEFT", 0, -y)
            h = 32
        elseif o.type == "priority" then
            w = UI.PriorityList(container, o, width)
            w:SetPoint("TOPLEFT", 0, -y)
            h = w:GetHeight() + 6
        elseif o.type == "spacer" then
            h = o.height or 10
        end

        if w and w.Refresh then widgets[#widgets + 1] = w end
        y = y + (h or 0)
    end

    container:SetHeight(y)
    local function refresh()
        for _, w in ipairs(widgets) do w:Refresh() end
    end
    return container, y, refresh
end
