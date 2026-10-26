-- Options panel: Esc > Options > AddOns > Friendly Forever.
-- One tab per message type: on/off, delay, repeat cooldown, the 30 messages.
-- Two pages under it: General (snooze, ignore list, profiles, export/import,
-- bug report) and Favour Ledger.
local _, ns = ...
local Config = ns.Config

local Options = {}
ns.Options = Options

Options.CONTENT_HEIGHT = 1470

local panel, category, generalPage, ledgerPage
local currentType = Config.TYPES[1]
local widgets = { tabs = {}, edits = {}, steppers = {}, general = {}, ledger = {} }
Options.widgets = widgets -- exposed for tests

Options.LEDGER_ROWS = 25

-- How to thank someone who buffs you, in the order the button cycles.
Options.THANK_STYLES = { "message", "emote", "both" }
Options.THANK_STYLE_TEXT = {
    message = "How to thank: a line in /say or a whisper",
    emote = "How to thank: a /thank emote",
    both = "How to thank: a line and a /thank emote",
}

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

-- Leave alone a box the player is typing in: rewriting it would undo their
-- edit and move the cursor to the start.
local function FillBox(box, text)
    if not box:HasFocus() then SetBoxText(box, text) end
end

-- Finish any edit in progress (a number box saves when it loses focus)
-- before a tab switch or reset gives the boxes new contents.
local function ClearEditFocus()
    local boxes = { widgets.steppers.delay.box, widgets.steppers.repeatCooldown.box, widgets.unknownName }
    for _, edit in ipairs(widgets.edits) do boxes[#boxes + 1] = edit end
    for _, box in ipairs(boxes) do
        if box:HasFocus() then box:ClearFocus() end
    end
end

local function Fill()
    local cfg = ns.db[currentType]
    local info = Config.TYPE_INFO[currentType]
    local isBuff = currentType == "buff"

    for msgType, tab in pairs(widgets.tabs) do tab:SetEnabled(msgType ~= currentType) end

    widgets.master:SetChecked(ns.db.enabled)
    widgets.skipAFK:SetChecked(ns.db.skipWhileAFK)
    widgets.header:SetText(info.label .. "  |cff999999(sent to " .. info.channel .. ")|r")
    widgets.help:SetText(info.help)
    widgets.enabled:SetChecked(cfg.enabled)
    FillBox(widgets.steppers.delay.box, tostring(cfg.delay))
    FillBox(widgets.steppers.repeatCooldown.box, tostring(cfg.repeatCooldown))

    widgets.listNames:SetShown(isBuff)
    widgets.thankStyle:SetShown(isBuff)
    widgets.whisper:SetShown(isBuff)
    widgets.fallback:SetShown(isBuff)
    widgets.unknownName:SetShown(isBuff)
    if isBuff then
        widgets.listNames:SetChecked(cfg.listBuffNames)
        widgets.thankStyle:SetText(Options.THANK_STYLE_TEXT[cfg.thankStyle])
        widgets.whisper:SetChecked(cfg.useWhisper)
        widgets.fallback:SetChecked(cfg.fallbackToSay)
        FillBox(widgets.unknownName, cfg.unknownName)
    end

    -- Without friendly nameplates the game can rarely name a buffer.
    local warn = isBuff and ns.Nameplates.FriendlyShown() == false
    widgets.nameplateWarning:SetShown(warn)
    widgets.nameplateButton:SetShown(warn)

    for i, edit in ipairs(widgets.edits) do
        FillBox(edit, cfg.messages[i] or "")
    end

    ns.Diag.Log("options", "filled %s tab: delay %s (box shows '%s'), repeat %s (box shows '%s')",
        currentType, cfg.delay, widgets.steppers.delay.box:GetText(),
        cfg.repeatCooldown, widgets.steppers.repeatCooldown.box:GetText())
end

local FillGeneral, FillLedger

-- Settings changes (CVAR_UPDATE, slash commands, the minimap button) call
-- this while the panel may be closed; OnShow fills it when it opens.
function Options.Refresh()
    if panel and panel:IsVisible() then Fill() end
    if generalPage and generalPage:IsVisible() then FillGeneral() end
    if ledgerPage and ledgerPage:IsVisible() then FillLedger() end
end

-- Fill the panel whenever it is shown, and once more on the next frame:
-- the settings window may still be laying itself out when OnShow fires.
local function OnPanelShow()
    Fill()
    C_Timer.After(0, ns.Diag.Wrap(function() Options.Refresh() end))
end

function Options.SelectType(msgType)
    ClearEditFocus()
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
    widgets.enabled = Checkbox(content, "Enabled", function(on)
        ns.db[currentType].enabled = on
        ns.RefreshEvents()
    end)
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

    -- Same row: a line, a /thank emote, or both (click to cycle).
    widgets.thankStyle = Button(content, Options.THANK_STYLE_TEXT.message, 290, function()
        local cfg = ns.db.buff
        for i, style in ipairs(Options.THANK_STYLES) do
            if style == cfg.thankStyle then
                cfg.thankStyle = Options.THANK_STYLES[i % #Options.THANK_STYLES + 1]
                break
            end
        end
        Options.Refresh()
    end)
    widgets.thankStyle:SetPoint("LEFT", widgets.listNames.label, "RIGHT", 30, 0)

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
        local template = ns.Messages.Preview(ns.db[currentType].messages)
        local vars = ns.Util.NameVars(ns.Util.UnitFullName("player") or "Nikki-Shifts")
        vars.buff = "Power Word: Fortitude and Arcane Intellect"
        local text = template and ns.Util.Render(template, ns.Flavour.Vars(vars))
        ns.Print(text or "(no messages)")
    end)
    widgets.preview:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -16)

    widgets.reset = Button(content, "Reset this tab to defaults", 190, function()
        ClearEditFocus()
        ns.ResetType(currentType)
        Options.Refresh()
    end)
    widgets.reset:SetPoint("LEFT", widgets.preview, "RIGHT", 10, 0)

    -- Swap only this tab's 30 lines for a shipped set.
    local function LoadLines(set)
        ClearEditFocus()
        local lines = {}
        for i, line in ipairs(set[currentType]) do lines[i] = line end
        ns.db[currentType].messages = lines
        Options.Refresh()
    end
    widgets.loadFantasy = Button(content, "Load fantasy lines", 150, function() LoadLines(ns.DefaultMessages) end)
    widgets.loadFantasy:SetPoint("TOPLEFT", widgets.preview, "BOTTOMLEFT", 0, -8)
    widgets.loadCasual = Button(content, "Load casual lines (1.6)", 170, function() LoadLines(ns.CasualMessages) end)
    widgets.loadCasual:SetPoint("LEFT", widgets.loadFantasy, "RIGHT", 10, 0)

    local flavour = Label(content, "Flavour: {greeting} {thanks} {blessing} {cheer} change with your race, "
        .. "faction, where you are and the hour. Also {zone}, {timeofday}, {myclass}, and {class} (theirs, "
        .. "when the game says; otherwise \"friend\").", "GameFontHighlightSmall")
    flavour:SetPoint("TOPLEFT", widgets.loadFantasy, "BOTTOMLEFT", 0, -12)
    flavour:SetPoint("RIGHT", content, "RIGHT", -24, 0)
    flavour:SetWordWrap(true)

    local note = Label(content, "Buff thanks in /say: the game only allows /say after a key press, so they wait "
        .. "and go out on your next key press (or type /friendly say). Whispers need no key press. "
        .. "A /thank emote waits for a key press too.",
        "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", flavour, "BOTTOMLEFT", 0, -10)
    note:SetPoint("RIGHT", content, "RIGHT", -24, 0)
    note:SetWordWrap(true)

    panel:SetScript("OnShow", OnPanelShow)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        category = Settings.RegisterCanvasLayoutCategory(panel, ns.TITLE)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end

    Options.CreateGeneralPage()
    Options.CreateLedgerPage()

    -- Filled straight away too, so nothing can ever show empty boxes.
    Fill()
end

-- A page listed under Friendly Forever in the AddOns options.
local function SubPage(name, title)
    local page = CreateFrame("Frame", nil)
    page.name = name
    page.parent = ns.TITLE
    local heading = Label(page, ns.TITLE .. ": " .. title, "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", 16, -16)
    page.heading = heading
    if Settings and Settings.RegisterCanvasLayoutSubcategory and category then
        page.category = Settings.RegisterCanvasLayoutSubcategory(category, page, name)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(page)
    end
    return page
end

local function Section(page, anchor, text, gap)
    local label = Label(page, text, "GameFontNormal")
    label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(gap or 20))
    return label
end

local function Note(page, anchor, text)
    local label = Label(page, text, "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
    label:SetPoint("RIGHT", page, "RIGHT", -24, 0)
    label:SetWordWrap(true)
    return label
end

local function Say(ok, why, success)
    ns.Print(ok and success or why)
    Options.Refresh()
end

function Options.CreateGeneralPage()
    local w = widgets.general
    generalPage = SubPage("General", "General")
    local page = generalPage

    -- Snooze
    local snooze = Section(page, page.heading, "Snooze", 16)
    w.snoozeState = Note(page, snooze, "")
    w.snooze15 = Button(page, "15 minutes", 110, function() ns.SnoozeFor(15) end)
    w.snooze15:SetPoint("TOPLEFT", w.snoozeState, "BOTTOMLEFT", 0, -6)
    w.snooze60 = Button(page, "1 hour", 90, function() ns.SnoozeFor(60) end)
    w.snooze60:SetPoint("LEFT", w.snooze15, "RIGHT", 8, 0)
    w.wake = Button(page, "Wake up", 90, function() ns.SnoozeFor(nil) end)
    w.wake:SetPoint("LEFT", w.snooze60, "RIGHT", 8, 0)

    -- Ignore list
    local ignore = Section(page, w.snooze15, "Never greet or thank")
    w.ignoreList = Note(page, ignore, "")
    w.ignoreBox = TextBox(page, 220, 60)
    w.ignoreBox:SetPoint("TOPLEFT", w.ignoreList, "BOTTOMLEFT", 6, -8)
    w.ignoreAdd = Button(page, "Add", 70, function()
        local name, why = ns.Ignore.Add(w.ignoreBox:GetText())
        if name then w.ignoreBox:SetText("") end
        Say(name, "couldn't add: " .. tostring(why),
            name and (ns.Util.DisplayName(name) .. " won't be greeted or thanked."))
    end)
    w.ignoreAdd:SetPoint("LEFT", w.ignoreBox, "RIGHT", 8, 0)
    w.ignoreRemove = Button(page, "Remove", 80, function()
        local name, why = ns.Ignore.Remove(w.ignoreBox:GetText())
        if name then w.ignoreBox:SetText("") end
        Say(name, "couldn't remove: " .. tostring(why), name and (ns.Util.DisplayName(name) .. " is off the list."))
    end)
    w.ignoreRemove:SetPoint("LEFT", w.ignoreAdd, "RIGHT", 6, 0)
    local ignoreHelp = Note(page, w.ignoreBox, "Full names, such as Nikki Shifts. Leave the box empty and click Add "
        .. "to add your target.")
    ignoreHelp:SetPoint("TOPLEFT", w.ignoreBox, "BOTTOMLEFT", -6, -6)

    -- Profiles
    local profiles = Section(page, ignoreHelp, "Profiles")
    w.profileState = Note(page, profiles, "")
    w.profileBox = TextBox(page, 160, ns.Profiles.MAX_NAME)
    w.profileBox:SetPoint("TOPLEFT", w.profileState, "BOTTOMLEFT", 6, -8)
    local function ProfileButton(text, width, fn, success)
        return Button(page, text, width, function()
            local name, why = fn(w.profileBox:GetText())
            if name then w.profileBox:SetText("") end
            Say(name, "profile: " .. tostring(why), name and success(name))
        end)
    end
    w.profileNew = ProfileButton("New", 60, ns.Profiles.New, function(n) return "now using the new profile " .. n end)
    w.profileNew:SetPoint("LEFT", w.profileBox, "RIGHT", 8, 0)
    w.profileUse = ProfileButton("Use", 60, ns.Profiles.Use, function(n) return "now using profile " .. n end)
    w.profileUse:SetPoint("LEFT", w.profileNew, "RIGHT", 6, 0)
    w.profileDelete = ProfileButton("Delete", 70, ns.Profiles.Delete, function(n) return "deleted profile " .. n end)
    w.profileDelete:SetPoint("LEFT", w.profileUse, "RIGHT", 6, 0)
    local profileHelp = Note(page, w.profileBox, "Type a name, then New (a copy of your settings) or Use. "
        .. "Each character switches to the profile it used last when it logs in.")
    profileHelp:SetPoint("TOPLEFT", w.profileBox, "BOTTOMLEFT", -6, -6)

    -- Export / import
    local share = Section(page, profileHelp, "Share your settings")
    w.export = Button(page, "Export", 90, function() ns.ShowExport() end)
    w.export:SetPoint("TOPLEFT", share, "BOTTOMLEFT", 0, -8)
    w.import = Button(page, "Import", 90, function() ns.ShowImport() end)
    w.import:SetPoint("LEFT", w.export, "RIGHT", 8, 0)
    w.undoImport = Button(page, "Undo import", 110, function()
        local ok, why = ns.Profiles.UndoImport()
        Say(ok, "couldn't undo: " .. tostring(why), "your settings from before the import are back.")
    end)
    w.undoImport:SetPoint("LEFT", w.import, "RIGHT", 8, 0)
    local shareHelp = Note(page, w.export, "One line of text with your messages and options. Importing never turns "
        .. "the addon on or off and only adds to your ignore list.")

    -- Bug report
    local help = Section(page, shareHelp, "Something not working?")
    w.report = Button(page, "Copy for a bug report", 180, function() ns.ShowBugReport() end)
    w.report:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -8)
    Note(page, w.report, "Shows /friendly status and the debug log as text to copy. Turn on /friendly debug "
        .. "and make the problem happen first, so the log shows it.")

    page:SetScript("OnShow", function() FillGeneral() end)
end

FillGeneral = function()
    local w = widgets.general
    local left = ns.Announcer.SnoozeLeft()
    w.snoozeState:SetText(left and string.format("Snoozed: nothing is sent for %d more min.", math.ceil(left / 60))
        or "Awake: messages are sent as usual.")
    w.wake:SetEnabled(left ~= nil)
    local names = ns.Ignore.List()
    w.ignoreList:SetText(#names == 0 and "Nobody." or table.concat(names, ", "))
    w.profileState:SetText("Using " .. ns.Profiles.Active() .. ". All profiles: "
        .. table.concat(ns.Profiles.List(), ", "))
    w.undoImport:SetEnabled(ns.Profiles.CanUndoImport())
end

function Options.CreateLedgerPage()
    local w = widgets.ledger
    ledgerPage = SubPage("Favour Ledger", "Favour Ledger")
    local page = ledgerPage
    w.summary = Note(page, page.heading, "")
    local anchor = w.summary
    w.rows = {}
    for i = 1, Options.LEDGER_ROWS do
        local row = Label(page, "", "GameFontHighlightSmall")
        row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, i == 1 and -12 or -4)
        row:SetPoint("RIGHT", page, "RIGHT", -24, 0)
        w.rows[i] = row
        anchor = row
    end
    w.clear = Button(page, "Clear the ledger", 140, function()
        ns.Ledger.Clear()
        Options.Refresh()
    end)
    w.clear:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -14)
    Note(page, w.clear, "Buffs from players outside your group, while Buff Thanks is on. "
        .. "The newest " .. ns.Ledger.MAX_ENTRIES .. " are kept; /friendly ledger shows them in chat.")
    page:SetScript("OnShow", function() FillLedger() end)
end

FillLedger = function()
    local w = widgets.ledger
    w.summary:SetText(ns.LedgerSummaryText())
    local lines = ns.Ledger.Lines(Options.LEDGER_ROWS)
    for i, row in ipairs(w.rows) do
        local line = lines[i]
        row:SetText(line and ns.Diag.Safe(line) or (i == 1 and "Nobody outside your group has buffed you yet." or ""))
    end
end

function Options.FillGeneral() FillGeneral() end
function Options.FillLedger() FillLedger() end
function Options.Pages() return generalPage, ledgerPage end

function Options.Open()
    if category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(category:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end
