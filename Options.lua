-- Options panel: Esc > Options > AddOns > Friendly Forever.
-- One tab per message type: on/off, delay, repeat cooldown, the 30 messages.
local _, ns = ...
local Config = ns.Config

local Options = {}
ns.Options = Options

Options.CONTENT_HEIGHT = 1380

local panel, category
local currentType = Config.TYPES[1]
local widgets = { tabs = {}, edits = {}, steppers = {} }
Options.widgets = widgets -- exposed for tests

local function Label(parent, text, font)
    local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlight")
    fs:SetText(text)
    fs:SetJustifyH("LEFT")
    return fs
end

local function Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function Checkbox(parent, text, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    local label = Label(cb, text)
    label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb.label = label
    return cb
end

-- Setting an edit box's text moves its cursor to the end, and the box
-- scrolls its view to follow the cursor; in a narrow box the text can end up
-- scrolled out of sight until the box is clicked. Always show it from the start.
local function SetBoxText(box, text)
    box:SetText(text)
    box:SetCursorPosition(0)
end

local function TextBox(parent, width, maxLetters)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetMaxLetters(maxLetters)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return box
end

-- Label, [-] [number] [+], bound to ns.db[currentType][field] within limits.
local function Stepper(parent, text, field)
    local limits = Config.LIMITS[field]
    local s = {}

    local function Set(value)
        local cfg = ns.db[currentType]
        cfg[field] = ns.Util.ClampNumber(value, limits.min, limits.max, cfg[field])
        SetBoxText(s.box, tostring(cfg[field]))
    end
    s.Set = Set

    s.label = Label(parent, text)
    s.minus = Button(parent, "-", 24, function() Set(ns.db[currentType][field] - 1) end)
    s.minus:SetPoint("LEFT", s.label, "RIGHT", 8, 0)
    s.box = TextBox(parent, 44, 4)
    s.box:SetNumeric(true)
    s.box:SetJustifyH("CENTER")
    s.box:SetPoint("LEFT", s.minus, "RIGHT", 8, 0)
    s.box:SetScript("OnEditFocusLost", function(self) Set(tonumber(self:GetText())) end)
    s.plus = Button(parent, "+", 24, function() Set(ns.db[currentType][field] + 1) end)
    s.plus:SetPoint("LEFT", s.box, "RIGHT", 4, 0)
    return s
end

function Options.Refresh()
    if not panel then return end
    local cfg = ns.db[currentType]
    local info = Config.TYPE_INFO[currentType]
    local isBuff = currentType == "buff"

    for msgType, tab in pairs(widgets.tabs) do tab:SetEnabled(msgType ~= currentType) end

    widgets.master:SetChecked(ns.db.enabled)
    widgets.skipAFK:SetChecked(ns.db.skipWhileAFK)
    widgets.header:SetText(info.label .. "  |cff999999(sent to " .. info.channel .. ")|r")
    widgets.help:SetText(info.help)
    widgets.enabled:SetChecked(cfg.enabled)
    SetBoxText(widgets.steppers.delay.box, tostring(cfg.delay))
    SetBoxText(widgets.steppers.repeatCooldown.box, tostring(cfg.repeatCooldown))

    widgets.listNames:SetShown(isBuff)
    widgets.whisper:SetShown(isBuff)
    widgets.fallback:SetShown(isBuff)
    widgets.unknownName:SetShown(isBuff)
    if isBuff then
        widgets.listNames:SetChecked(cfg.listBuffNames)
        widgets.whisper:SetChecked(cfg.useWhisper)
        widgets.fallback:SetChecked(cfg.fallbackToSay)
        SetBoxText(widgets.unknownName, cfg.unknownName)
    end

    -- Without friendly nameplates the game can rarely name a buffer.
    local warn = isBuff and ns.Nameplates.FriendlyShown() == false
    widgets.nameplateWarning:SetShown(warn)
    widgets.nameplateButton:SetShown(warn)

    for i, edit in ipairs(widgets.edits) do
        SetBoxText(edit, cfg.messages[i] or "")
    end

    ns.Diag.Log("options", "filled %s tab: delay %s (box shows '%s'), repeat %s (box shows '%s')",
        currentType, cfg.delay, widgets.steppers.delay.box:GetText(),
        cfg.repeatCooldown, widgets.steppers.repeatCooldown.box:GetText())
end

-- Fill the panel whenever it is shown, and once more on the next frame:
-- the settings window may still be laying itself out when OnShow fires.
local function OnPanelShow()
    Options.Refresh()
    C_Timer.After(0, ns.Diag.Wrap(function()
        if panel:IsVisible() then Options.Refresh() end
    end))
end

function Options.SelectType(msgType)
    currentType = msgType
    Options.Refresh()
end

function Options.CurrentType()
    return currentType
end

function Options.Create()
    if panel then return end
    panel = CreateFrame("Frame", "FriendlyForeverOptionsPanel")
    panel.name = ns.TITLE

    -- Everything sits in a scrolling area so no row is cut off on small screens.
    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", -28, 4)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(600, Options.CONTENT_HEIGHT)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, width) content:SetWidth(width) end)
    widgets.content = content

    local title = Label(content, ns.TITLE, "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)

    widgets.master = Checkbox(content, "Addon enabled", function(on) ns.SetEnabled(on) end)
    widgets.master:SetPoint("TOPRIGHT", -150, -10)
    -- On the master switch's row; its label ends just left of that switch,
    -- however wide the font makes it.
    widgets.skipAFK = Checkbox(content, "Don't send messages while I'm AFK", function(on) ns.db.skipWhileAFK = on end)
    local labelWidth = widgets.skipAFK.label:GetStringWidth() or 0
    widgets.skipAFK:SetPoint("RIGHT", widgets.master, "LEFT", -(labelWidth + 16), 0)

    local prev
    for _, msgType in ipairs(Config.TYPES) do
        local tab = Button(content, Config.TYPE_INFO[msgType].label, 92, function() Options.SelectType(msgType) end)
        if prev then
            tab:SetPoint("LEFT", prev, "RIGHT", 6, 0)
        else
            tab:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -14)
        end
        widgets.tabs[msgType] = tab
        prev = tab
    end

    widgets.header = Label(content, "", "GameFontNormal")
    widgets.header:SetPoint("TOPLEFT", widgets.tabs[Config.TYPES[1]], "BOTTOMLEFT", 0, -16)
    widgets.help = Label(content, "", "GameFontHighlightSmall")
    widgets.help:SetPoint("TOPLEFT", widgets.header, "BOTTOMLEFT", 0, -4)

    -- Row 1: enabled, delay
    widgets.enabled = Checkbox(content, "Enabled", function(on) ns.db[currentType].enabled = on end)
    widgets.enabled:SetPoint("TOPLEFT", widgets.help, "BOTTOMLEFT", -4, -8)
    local delay = Stepper(content, "Delay after event (seconds):", "delay")
    delay.label:SetPoint("LEFT", widgets.enabled.label, "RIGHT", 40, 0)
    widgets.steppers.delay = delay

    -- Row 2: repeat cooldown
    local repeatCooldown = Stepper(content, "Don't repeat to the same player for (seconds):", "repeatCooldown")
    repeatCooldown.label:SetPoint("TOPLEFT", widgets.enabled, "BOTTOMLEFT", 4, -10)
    widgets.steppers.repeatCooldown = repeatCooldown

    -- Buff tab only, row 3: list buff names
    widgets.listNames = Checkbox(content, "Name the buffs in the message", function(on)
        ns.db.buff.listBuffNames = on
    end)
    widgets.listNames:SetPoint("TOPLEFT", repeatCooldown.label, "BOTTOMLEFT", -4, -8)

    -- Row 4: whisper instead of say
    widgets.whisper = Checkbox(content, "Whisper the caster instead of /say (sends without a key press)",
        function(on) ns.db.buff.useWhisper = on end)
    widgets.whisper:SetPoint("TOPLEFT", widgets.listNames, "BOTTOMLEFT", 0, -4)

    -- Row 5: /say fallback for casters that can't be named or whispered
    widgets.fallback = Checkbox(content, "If the caster can't be named or whispered, thank them in /say as:",
        function(on) ns.db.buff.fallbackToSay = on end)
    widgets.fallback:SetPoint("TOPLEFT", widgets.whisper, "BOTTOMLEFT", 0, -4)
    widgets.unknownName = TextBox(content, 100, Config.LIMITS.unknownName.maxBytes)
    widgets.unknownName:SetPoint("LEFT", widgets.fallback.label, "RIGHT", 10, 0)
    widgets.unknownName:SetScript("OnTextChanged", function(self, userInput)
        if userInput then ns.db.buff.unknownName = Config.CleanUnknownName(self:GetText()) end
    end)

    -- Row 6: warning + one-click fix when friendly nameplates are off
    widgets.nameplateWarning = Label(content, "|cffff8040Friendly player nameplates are off, so the game "
        .. "can't tell you who buffed you.|r", "GameFontHighlightSmall")
    widgets.nameplateWarning:SetPoint("TOPLEFT", widgets.fallback, "BOTTOMLEFT", 4, -8)
    widgets.nameplateButton = Button(content, "Show friendly player names", 200, function()
        local ok, reason = ns.Nameplates.EnableFriendlyNames()
        ns.Print(ok and "friendly player names are now shown (names only)." or ("couldn't turn them on: " .. reason))
        Options.Refresh()
    end)
    widgets.nameplateButton:SetPoint("LEFT", widgets.nameplateWarning, "RIGHT", 10, 0)

    -- Messages
    local msgHeader = Label(content,
        "Messages (all are used in random order before any repeats; leave a line blank to skip it):",
        "GameFontNormalSmall")
    msgHeader:SetPoint("TOPLEFT", widgets.fallback, "BOTTOMLEFT", 4, -32)

    local anchor = msgHeader
    for i = 1, Config.NUM_MESSAGES do
        local num = Label(content, i .. ".", "GameFontHighlightSmall")
        num:SetWidth(20)
        num:SetJustifyH("RIGHT")
        num:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, i == 1 and -10 or -8)

        local edit = TextBox(content, 400, ns.Util.MAX_CHAT_BYTES)
        edit:SetPoint("LEFT", num, "RIGHT", 10, 0)
        edit:SetPoint("RIGHT", content, "RIGHT", -24, 0)
        edit:SetScript("OnTextChanged", function(self, userInput)
            if userInput then ns.db[currentType].messages[i] = Config.CleanMessage(self:GetText()) end
        end)
        widgets.edits[i] = edit
        anchor = num
    end

    widgets.preview = Button(content, "Preview random", 130, function()
        local template = ns.Messages.Pick(currentType, ns.db[currentType].messages)
        local vars = ns.Util.NameVars(ns.Util.UnitFullName("player") or "Nikki-Shifts")
        vars.buff = "Power Word: Fortitude and Arcane Intellect"
        local text = template and ns.Util.Render(template, vars)
        ns.Print(text or "(no messages)")
    end)
    widgets.preview:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -16)

    widgets.reset = Button(content, "Reset this tab to defaults", 190, function()
        ns.ResetType(currentType)
        Options.Refresh()
    end)
    widgets.reset:SetPoint("LEFT", widgets.preview, "RIGHT", 10, 0)

    local note = Label(content, "Buff thanks in /say: the game only allows /say after a key press, so they wait "
        .. "and go out on your next key press (or type /friendly say). Whispers need no key press.",
        "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", widgets.preview, "BOTTOMLEFT", 0, -12)
    note:SetPoint("RIGHT", content, "RIGHT", -24, 0)
    note:SetWordWrap(true)

    panel:SetScript("OnShow", OnPanelShow)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        category = Settings.RegisterCanvasLayoutCategory(panel, ns.TITLE)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end

    -- Filled straight away too, so nothing can ever show empty boxes.
    Options.Refresh()
end

function Options.Open()
    if category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(category:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end
