-- Options panel: Esc > Options > AddOns > Friendly Forever.
-- One tab per message type: on/off, delay, repeat cooldown, the 30 messages.
-- Two pages under it: General (snooze, chat limit, ignore list, profiles,
-- export/import, bug report) and Favour Ledger.
local _, ns = ...
local Config = ns.Config

local Options = {}
ns.Options = Options

-- Room for the Buff Back tab's buff list, who gets each, and buff mode rows above its lines.
Options.CONTENT_HEIGHT = 1940

local panel, category, generalPage, ledgerPage
local currentType = Config.TYPES[1]
local widgets = { tabs = {}, edits = {}, steppers = {}, general = {}, ledger = {} }
Options.widgets = widgets -- exposed for tests

Options.LEDGER_ROWS = 25
Options.IGNORE_SHOWN = 12 -- names listed on the General page; the rest are counted
Options.PROFILES_SHOWN = 6 -- profiles listed there, the same way
-- The General page's scrolling content: room for its sections with both
-- lists at their longest (#52).
Options.GENERAL_HEIGHT = 720
-- The pages' frame names, so the UI simulator's scenarios can find them (#52).
Options.GENERAL_PAGE = "FriendlyForeverGeneralPage"
Options.LEDGER_PAGE = "FriendlyForeverLedgerPage"

-- How to thank someone who buffs you, and what to do when that can't reach
-- them (#101), in the order each button cycles.
Options.THANK_STYLES = { "message", "whisper", "emote", "both" }
Options.THANK_STYLE_TEXT = {
    message = "a line in /say",
    whisper = "a whisper",
    emote = "a /thank emote",
    both = "a line in /say and an emote",
}
Options.FALLBACKS = { "say", "emote", "none" }
-- "say" is followed by the box with the name they're called.
Options.FALLBACK_TEXT = {
    say = "say it in /say as",
    emote = "/thank instead",
    none = "do nothing",
}

-- The next entry after current in list (the first, after the last or an unknown one).
local function NextIn(list, current)
    for i, value in ipairs(list) do
        if value == current then return list[i % #list + 1] end
    end
    return list[1]
end

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

-- Words shown when the mouse is over frame (kept on it as frame.tooltip).
local function Tooltip(frame, text)
    frame.tooltip = text
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local r, g, b, a = ns.Colours.RGBA("bright")
        GameTooltip:SetText(self.tooltip, r, g, b, a, true)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

Options.BREATH_TOOLTIP = "Offer Unending Breath and Water Breathing only while you're swimming or underwater, "
    .. "for 2 minutes after, or in an underwater dungeon."

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

-- Label, [-] [number] [+], bound to settings()[field] within limits;
-- settings defaults to ns.db[currentType]. Does nothing on a type without
-- that field (its stepper is hidden there). font: the label's, if not the
-- usual one.
local function Stepper(parent, text, field, settings, font)
    local limits = Config.LIMITS[field]
    local s = {}
    settings = settings or function() return ns.db[currentType] end

    local function Set(value)
        local cfg = settings()
        if cfg[field] == nil then
            SetBoxText(s.box, "")
            return
        end
        cfg[field] = ns.Util.ClampNumber(value, limits.min, limits.max, cfg[field])
        SetBoxText(s.box, tostring(cfg[field]))
    end
    s.Set = Set

    local function Step(by)
        local current = settings()[field]
        if current ~= nil then Set(current + by) end
    end

    s.label = Label(parent, text, font)
    s.minus = Button(parent, "-", 24, function() Step(-1) end)
    s.minus:SetPoint("LEFT", s.label, "RIGHT", 8, 0)
    s.box = TextBox(parent, 44, 4)
    s.box:SetNumeric(true)
    s.box:SetJustifyH("CENTER")
    s.box:SetPoint("LEFT", s.minus, "RIGHT", 8, 0)
    s.box:SetScript("OnEditFocusLost", function(self) Set(tonumber(self:GetText())) end)
    s.plus = Button(parent, "+", 24, function() Step(1) end)
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
    local boxes = { widgets.steppers.delay.box, widgets.steppers.repeatCooldown.box,
        widgets.steppers.owedMinutes.box, widgets.steppers.topUpMinutes.box, widgets.steppers.maxGreeters.box,
        widgets.unknownName }
    for _, edit in ipairs(widgets.edits) do boxes[#boxes + 1] = edit end
    if widgets.who then
        boxes[#boxes + 1] = widgets.who.always
        boxes[#boxes + 1] = widgets.who.never
        boxes[#boxes + 1] = widgets.who.revokeNames
    end
    for _, box in ipairs(boxes) do
        if box:HasFocus() then box:ClearFocus() end
    end
end

-- Finish any edit in the panel (saving it), before a list it shows is
-- changed from outside: a box still open would save its old text over it.
function Options.FinishEdits()
    if widgets.steppers.delay then ClearEditFocus() end -- once the panel is made
end

-- Choosing buff mode's key: click the button, then press a key, scroll the
-- mouse wheel or click a side mouse button (Esc cancels).
Options.KEY_PROMPT = "Press a key or scroll the wheel (Esc cancels)"
local MOUSE_KEYS = { MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" }

local function ModifierPrefix()
    local out = ""
    if IsAltKeyDown() then out = out .. "ALT-" end
    if IsControlKeyDown() then out = out .. "CTRL-" end
    if IsShiftKeyDown() then out = out .. "SHIFT-" end
    return out
end

local function KeyButtonText()
    return "Buff mode key: " .. ns.BuffMode.KeyText((ns.BuffMode.Key()))
end

local function StopKeyCapture()
    local capture = widgets.keyCapture
    if not capture.active then return end
    capture.active = false
    capture:EnableKeyboard(false)
    capture:EnableMouseWheel(false)
    capture:EnableMouse(false)
    capture:Hide()
    widgets.buffModeKey:SetText(KeyButtonText())
end

local function TakeKey(key)
    if InCombatLockdown() then return StopKeyCapture() end
    StopKeyCapture()
    local ok, why = ns.BuffMode.SetKey(ModifierPrefix() .. key)
    if not ok then ns.Print("couldn't set the buff mode key: " .. why .. ".") end
    widgets.buffModeKey:SetText(KeyButtonText())
end

function Options.StartKeyCapture()
    if InCombatLockdown() then return ns.Print("keys can't be changed in a fight.") end
    local capture = widgets.keyCapture
    capture.active = true
    capture:Show()
    capture:EnableKeyboard(true)
    capture:SetPropagateKeyboardInput(false)
    capture:EnableMouseWheel(true)
    capture:EnableMouse(true)
    widgets.buffModeKey:SetText(Options.KEY_PROMPT)
end

local function CreateKeyCapture(parent)
    local capture = CreateFrame("Frame", nil, parent)
    capture:SetAllPoints(parent)
    capture:Hide()
    capture:SetScript("OnKeyDown", function(_, key)
        if ns.BuffMode.MODIFIER_KEYS[key] then return end
        if key == "ESCAPE" then return StopKeyCapture() end
        TakeKey(key)
    end)
    capture:SetScript("OnMouseWheel", function(_, delta) TakeKey(delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN") end)
    capture:SetScript("OnMouseDown", function(_, mouseButton)
        if MOUSE_KEYS[mouseButton] then TakeKey(MOUSE_KEYS[mouseButton]) end
    end)
    capture:SetScript("OnHide", StopKeyCapture)
    -- A fight starting ends the wait, while the game still allows it: in a
    -- fight your keys must reach your abilities, not choose buff mode's key.
    capture:RegisterEvent("PLAYER_REGEN_DISABLED")
    capture:SetScript("OnEvent", StopKeyCapture)
    return capture
end

-- The Buff Back tab's buff list: your class's buffs in your order.
local function OrderedClassBuffs()
    return ns.BuffData.InOrder(ns.BuffData.ClassBuffs(), ns.db.buffBack.buffOrder)
end

-- Move a buff of your class one place up (-1) or down (+1). Saved as your
-- class's keys in the new order, then any other classes' keys as they were.
function Options.MoveBuff(key, step)
    -- The first buff may change, and with it the one the name boxes are for.
    ClearEditFocus()
    local keys = {}
    for i, buff in ipairs(OrderedClassBuffs()) do keys[i] = buff.key end
    for i, k in ipairs(keys) do
        local j = i + step
        if k == key and keys[j] then
            keys[i], keys[j] = keys[j], keys[i]
            break
        end
    end
    local mine = {}
    for _, k in ipairs(keys) do mine[k] = true end
    local saved = type(ns.db.buffBack.buffOrder) == "table" and ns.db.buffBack.buffOrder or {}
    for _, k in ipairs(saved) do
        if not mine[k] then keys[#keys + 1] = k end
    end
    ns.db.buffBack.buffOrder = Config.FIELD_VALIDATORS.buffOrder(keys, {})
    ns.BuffButton.Refresh()
    Options.Refresh()
end

function Options.SetNeverOffer(key, on)
    if type(ns.db.buffBack.neverOffer) ~= "table" then ns.db.buffBack.neverOffer = {} end
    ns.db.buffBack.neverOffer[key] = on or nil
    ns.BuffButton.Refresh()
    Options.Refresh()
end

-- The buff whose "who gets it" is shown below the buff list: the one whose
-- Who button you clicked last, else the first in your order.
local whoKey

local function WhoBuff(buffs)
    for _, buff in ipairs(buffs) do
        if buff.key == whoKey then return buff end
    end
    return buffs[1]
end

-- A buff row's Who button: step its rule on, and show its details below.
function Options.CycleWho(key)
    local buff
    for _, b in ipairs(OrderedClassBuffs()) do
        if b.key == key then buff = b end
    end
    if not buff then return end
    ClearEditFocus() -- a name box being typed in saves to its own buff first
    whoKey = key
    ns.BuffRules.SetRule(key, ns.BuffRules.NextRule(buff))
    Options.Refresh()
end

function Options.SetWhoClass(class, on)
    local buff = WhoBuff(OrderedClassBuffs())
    if buff then ns.BuffRules.SetClass(buff.key, class, on) end
    Options.Refresh()
end

-- The buff the name boxes showed when one was focused: an edit saves to it,
-- whatever the boxes show by the time focus leaves.
function Options.WhoBuffKey()
    local buff = WhoBuff(OrderedClassBuffs())
    return buff and buff.key
end

-- An Always or Never box lost focus: save it to key (the buff it was opened
-- for), or say why not and show what's kept. Unchanged text isn't saved.
function Options.SetWhoNames(key, list, text)
    if not key or text == ns.BuffRules.NamesText(key, list) then return Options.Refresh() end
    local ok, why = ns.BuffRules.SetNames(key, list, text)
    if not ok then ns.Print((list == "always" and "Always" or "Never") .. " list not saved: " .. why .. ".") end
    Options.Refresh()
end

local function ClassText(class)
    local names = rawget(_G, "LOCALIZED_CLASS_NAMES_MALE")
    local name = type(names) == "table" and names[class]
    if type(name) == "string" then return name end
    return class:sub(1, 1) .. class:sub(2):lower()
end

-- Below the buff list: who gets the chosen buff. Returns what the next rows anchor to.
local function FillWho(shown, buffs, last)
    local who = widgets.who
    local buff = shown and WhoBuff(buffs) or nil
    local rule = buff and ns.BuffRules.Rule(buff)
    who.header:SetShown(buff ~= nil)
    who.header:ClearAllPoints()
    who.header:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -12)
    local showClasses = rule == "classes"
    for _, class in ipairs(ns.BuffRules.CLASSES) do
        who.classes[class]:SetShown(showClasses)
        if showClasses then who.classes[class]:SetChecked(ns.BuffRules.HasClass(buff, class)) end
    end
    for _, part in ipairs({ who.alwaysLabel, who.always, who.neverLabel, who.never }) do part:SetShown(buff ~= nil) end
    if not buff then return last end
    local name = ns.BuffData.SpellName(buff) or buff.key
    who.header:SetText("Who gets " .. name .. " in buff mode: " .. ns.BuffRules.RULE_TEXT[rule]
        .. "  " .. ns.Colours.Text("muted", "(a buff's Who button changes it)"))
    who.alwaysLabel:ClearAllPoints()
    who.alwaysLabel:SetPoint("TOPLEFT", showClasses and who.classRows[2] or who.header, "BOTTOMLEFT",
        showClasses and 4 or 0, -10)
    FillBox(who.always, ns.BuffRules.NamesText(buff.key, "always"))
    FillBox(who.never, ns.BuffRules.NamesText(buff.key, "never"))
    return who.neverLabel
end

-- Below who gets each buff, for classes with Salvation (paladins): whose
-- Salvation buff mode offers to Revoke. Returns what the next rows anchor to.
local function FillRevoke(shown, buffs, last)
    local who = widgets.who
    local hasSalvation = false
    for _, buff in ipairs(shown and buffs or {}) do
        if buff.key == ns.BuffData.REVOKE.removes then hasSalvation = true end
    end
    local mode = ns.BuffRules.RevokeMode()
    local named = hasSalvation and ns.BuffRules.REVOKE_NAMED[mode] == true
    who.revoke:SetShown(hasSalvation)
    who.revokeLabel:SetShown(named)
    who.revokeNames:SetShown(named)
    if not hasSalvation then return last end
    who.revoke:ClearAllPoints()
    who.revoke:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -12)
    who.revoke:SetText("Revoke Salvation from: " .. ns.BuffRules.REVOKE_TEXT[mode])
    if not named then return who.revoke end
    FillBox(who.revokeNames, ns.BuffRules.RevokeNamesText())
    return who.revokeLabel
end

-- Below Revoke, for classes with Blessings: which you give in this raid.
-- Not saved (BuffRules.lua); the tick boxes only work in a raid.
local function FillRaidBlessings(shown, last)
    local who = widgets.who
    local mine = shown and ns.BuffRules.MyBlessings() or {}
    local inRaid = ns.Util.ReadGameValues(IsInRaid) == true
    who.raidHeader:SetShown(#mine > 0)
    for i, cb in ipairs(who.raidBlessings) do
        local buff = mine[i]
        cb:SetShown(buff ~= nil)
        cb.key = buff and buff.key
        if buff then
            cb.label:SetText(ns.BuffData.SpellName(buff) or buff.key)
            cb:SetChecked(ns.BuffRules.CoversInRaid(buff))
            cb:SetEnabled(inRaid)
        end
    end
    if #mine == 0 then return last end
    who.raidHeader:ClearAllPoints()
    who.raidHeader:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -12)
    who.raidHeader:SetText("Blessings I give in this raid:  "
        .. ns.Colours.Text("muted", inRaid and "(until you leave it)" or "(join a raid to choose)"))
    return who.raidBlessings[1]
end

-- A raid Blessing tick box was clicked: cover the ticked ones.
function Options.SetRaidBlessing()
    local keys = {}
    for _, cb in ipairs(widgets.who.raidBlessings) do
        if cb:IsShown() and cb.key and cb:GetChecked() then keys[#keys + 1] = cb.key end
    end
    local ok, why = ns.BuffRules.SetRaidBlessings(keys)
    if not ok then ns.Print("Blessings for this raid not changed: " .. why .. ".") end
    Options.Refresh()
end

function Options.CycleRevoke()
    ClearEditFocus()
    ns.BuffRules.SetRevokeMode(ns.BuffRules.NextRevokeMode())
    Options.Refresh()
end

-- The Revoke names box lost focus: save it, or say why not.
function Options.SetRevokeNames(text)
    if text == ns.BuffRules.RevokeNamesText() then return Options.Refresh() end
    local ok, why = ns.BuffRules.SetRevokeNames(text)
    if not ok then ns.Print("Revoke list not saved: " .. why .. ".") end
    Options.Refresh()
end

local function FillBuffRows(shown)
    widgets.buffOrderHeader:SetShown(shown)
    local buffs = shown and OrderedClassBuffs() or {}
    -- Read only for the Buff Back tab: the other tabs mustn't depend on its settings.
    local never = shown and type(ns.db.buffBack.neverOffer) == "table" and ns.db.buffBack.neverOffer or {}
    for i, row in ipairs(widgets.buffRows) do
        local buff = buffs[i]
        for _, part in ipairs({ row.name, row.up, row.down, row.never, row.who }) do part:SetShown(buff ~= nil) end
        row.key = buff and buff.key
        if buff then
            local name = ns.BuffData.SpellName(buff) or buff.key
            if not ns.BuffData.IsKnown(buff) then name = name .. " " .. ns.Colours.Text("muted", "(not known yet)") end
            row.name:SetText(i .. ". " .. name)
            row.up:SetEnabled(i > 1)
            row.down:SetEnabled(i < #buffs)
            row.never:SetChecked(never[buff.key] == true)
            row.who:SetText("Who: " .. ns.BuffRules.RULE_TEXT[ns.BuffRules.Rule(buff)])
        end
    end
    if shown and #buffs == 0 then
        widgets.buffOrderHeader:SetText("Your class has no buffs to offer.")
    else
        widgets.buffOrderHeader:SetText("Buff order (first that suits them is offered):")
    end
    -- On this tab the buff mode rows follow the buff list, and the messages
    -- follow them; on the others the messages follow the buff options.
    local last = buffs[1] and widgets.buffRows[#buffs].up or widgets.buffOrderHeader
    last = FillWho(shown, buffs, last)
    last = FillRevoke(shown, buffs, last)
    last = FillRaidBlessings(shown, last)
    widgets.autoHeader:ClearAllPoints()
    widgets.autoHeader:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -14)
end

local function ShowStepper(stepper, shown)
    for _, part in ipairs({ stepper.label, stepper.minus, stepper.box, stepper.plus }) do part:SetShown(shown) end
end

-- The Buff Back tab's rows for when buff mode turns on and off by itself.
Options.AUTO_SWITCHES = { "autoOnJoin", "autoOnDeath", "autoOnBuffed", "autoOffPull", "autoOffDone" }

local function FillAuto(shown)
    widgets.autoHeader:SetShown(shown)
    widgets.autoOffHeader:SetShown(shown)
    for _, field in ipairs(Options.AUTO_SWITCHES) do
        widgets.auto[field]:SetShown(shown)
        if shown then widgets.auto[field]:SetChecked(ns.db.buffBack[field] == true) end
    end
    ShowStepper(widgets.steppers.autoOffMinutes, shown)
    if shown then FillBox(widgets.steppers.autoOffMinutes.box, tostring(ns.db.buffBack.autoOffMinutes)) end
    ShowStepper(widgets.steppers.topUpMinutes, shown)
    if shown then FillBox(widgets.steppers.topUpMinutes.box, tostring(ns.db.buffBack.topUpMinutes)) end
    widgets.bgHeader:SetShown(shown)
    widgets.bgPrepBuff:SetShown(shown)
    if shown then widgets.bgPrepBuff:SetChecked(ns.db.buffBack.bgPrepBuff == true) end
    widgets.waterHeader:SetShown(shown)
    widgets.breathNearWater:SetShown(shown)
    if shown then widgets.breathNearWater:SetChecked(ns.db.buffBack.breathNearWater == true) end
end

local function Fill()
    local cfg = ns.db[currentType]
    local info = Config.TYPE_INFO[currentType]
    local isBuff = currentType == "buff"

    for msgType, tab in pairs(widgets.tabs) do tab:SetEnabled(msgType ~= currentType) end

    widgets.master:SetChecked(ns.db.enabled)
    widgets.skipAFK:SetChecked(ns.db.skipWhileAFK)
    widgets.header:SetText(info.label .. "  " .. ns.Colours.Text("muted", "(sent to " .. info.channel .. ")"))
    widgets.help:SetText(info.help)
    widgets.enabled:SetChecked(cfg.enabled)
    widgets.enabled.label:SetText(info.enabledLabel or "Enabled")
    -- Buff Back's line is said by your own press: no delay or repeat cooldown.
    ShowStepper(widgets.steppers.delay, not info.noTiming)
    ShowStepper(widgets.steppers.repeatCooldown, not info.noTiming)
    FillBox(widgets.steppers.delay.box, cfg.delay and tostring(cfg.delay) or "")
    FillBox(widgets.steppers.repeatCooldown.box, cfg.repeatCooldown and tostring(cfg.repeatCooldown) or "")

    local isGuildLogin = currentType == "guildLogin"
    ShowStepper(widgets.steppers.maxGreeters, isGuildLogin)
    widgets.greetersHelp:SetShown(isGuildLogin)
    if isGuildLogin then FillBox(widgets.steppers.maxGreeters.box, tostring(cfg.maxGreeters)) end

    local isBuffBack = currentType == "buffBack"
    widgets.sayLine:SetShown(isBuffBack)
    widgets.showInCities:SetShown(isBuffBack)
    widgets.buffModeKey:SetShown(isBuffBack)
    if not widgets.keyCapture.active then widgets.buffModeKey:SetText(KeyButtonText()) end
    ShowStepper(widgets.steppers.owedMinutes, isBuffBack)
    if isBuffBack then
        widgets.sayLine:SetChecked(cfg.sayLine)
        widgets.showInCities:SetChecked(cfg.showInCities)
        FillBox(widgets.steppers.owedMinutes.box, tostring(cfg.owedMinutes))
    end
    FillBuffRows(isBuffBack)
    FillAuto(isBuffBack)

    widgets.listNames:SetShown(isBuff)
    widgets.receipts:SetShown(isBuff)
    widgets.thankStyleLabel:SetShown(isBuff)
    widgets.thankStyle:SetShown(isBuff)
    widgets.fallbackLabel:SetShown(isBuff)
    widgets.fallback:SetShown(isBuff)
    widgets.quiet:SetShown(isBuff)
    -- The name box only means something for the /say fallback.
    widgets.unknownName:SetShown(isBuff and cfg.fallback == "say")
    if isBuff then
        widgets.listNames:SetChecked(cfg.listBuffNames)
        widgets.receipts:SetChecked(cfg.receipts)
        widgets.thankStyle:SetText(Options.THANK_STYLE_TEXT[cfg.thankStyle])
        widgets.fallback:SetText(Options.FALLBACK_TEXT[cfg.fallback])
        widgets.quiet:SetChecked(cfg.quietInCities)
        FillBox(widgets.unknownName, cfg.unknownName)
    end

    -- Without friendly nameplates the game can rarely name a buffer.
    local warn = isBuff and ns.Nameplates.FriendlyShown() == false
    widgets.nameplateWarning:SetShown(warn)
    widgets.nameplateButton:SetShown(warn)

    -- The messages follow the last row this tab shows: a hidden row still
    -- takes its space, so following one would leave an empty gap.
    local above, x, y = widgets.steppers.repeatCooldown.label, 0, -18
    if isBuffBack then
        above, x, y = widgets.breathNearWater, 4, -14
    elseif isGuildLogin then
        above = widgets.greetersHelp
    elseif warn then
        above = widgets.nameplateWarning
    elseif isBuff then
        above, x, y = widgets.quiet, 4, -14
    end
    widgets.msgHeader:SetPoint("TOPLEFT", above, "BOTTOMLEFT", x, y)

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

-- Keeps a scrolling area's content as wide as its scroll frame: on a size
-- change, and on each show, now and on the next frame. The settings window
-- may lay a panel out without a size change reaching its scroll frame, and
-- a stale width would wrap or cut every line pinned to the content's right
-- (#52, #112).
local function FollowWidth(scroll, content)
    scroll:SetScript("OnSizeChanged", function(_, width) content:SetWidth(width) end)
    local function Fit()
        local width = scroll:GetWidth()
        if width and width > 0 then content:SetWidth(width) end
    end
    scroll:SetScript("OnShow", function()
        Fit()
        C_Timer.After(0, ns.Diag.Wrap(Fit))
    end)
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
    FollowWidth(scroll, content)
    widgets.scroll, widgets.content = scroll, content

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
        local tab = Button(content, Config.TYPE_INFO[msgType].label, 84, function() Options.SelectType(msgType) end)
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
    -- Wraps at the panel's right edge: the Buff Back tab's runs wider than
    -- the panel (#112). The rows below hang from it, so they move down.
    widgets.help = Label(content, "", "GameFontHighlightSmall")
    widgets.help:SetPoint("TOPLEFT", widgets.header, "BOTTOMLEFT", 0, -4)
    widgets.help:SetPoint("RIGHT", content, "RIGHT", -24, 0)
    widgets.help:SetWordWrap(true)

    -- Row 1: enabled, delay
    widgets.enabled = Checkbox(content, "Enabled", function(on)
        ns.db[currentType].enabled = on
        ns.RefreshEvents()
        ns.BuffButton.Refresh()
    end)
    widgets.enabled:SetPoint("TOPLEFT", widgets.help, "BOTTOMLEFT", -4, -8)
    local delay = Stepper(content, "Delay after event (seconds):", "delay")
    delay.label:SetPoint("LEFT", widgets.enabled.label, "RIGHT", 40, 0)
    widgets.steppers.delay = delay

    -- Row 2: repeat cooldown
    local repeatCooldown = Stepper(content, "Don't repeat to the same player for (seconds):", "repeatCooldown")
    repeatCooldown.label:SetPoint("TOPLEFT", widgets.enabled, "BOTTOMLEFT", 4, -10)
    widgets.steppers.repeatCooldown = repeatCooldown

    -- Guild Login tab only, row 3: the most copies that greet one login (#38).
    local maxGreeters = Stepper(content, "Most players with Friendly Forever who greet one login:", "maxGreeters")
    maxGreeters.label:SetPoint("TOPLEFT", repeatCooldown.label, "BOTTOMLEFT", 0, -16)
    widgets.steppers.maxGreeters = maxGreeters
    widgets.greetersHelp = Label(content, "Everyone with the addon greets a guildmate who logs in, a few "
        .. "seconds apart and with different lines, up to this many. Copies that can't reach the others "
        .. "(inside an instance, say) greet anyway.", "GameFontHighlightSmall")
    widgets.greetersHelp:SetPoint("TOPLEFT", maxGreeters.label, "BOTTOMLEFT", 0, -10)
    widgets.greetersHelp:SetPoint("RIGHT", content, "RIGHT", -24, 0)
    widgets.greetersHelp:SetWordWrap(true)

    -- Buff tab only, row 3: list buff names
    widgets.listNames = Checkbox(content, "Name the buffs in the message", function(on)
        ns.db.buff.listBuffNames = on
    end)
    widgets.listNames:SetPoint("TOPLEFT", repeatCooldown.label, "BOTTOMLEFT", -4, -8)
    -- Beside it: tell players I buff that it was me (Receipts.lua).
    widgets.receipts = Checkbox(content, "Tell players I buff that it was me", function(on)
        ns.db.buff.receipts = on
    end)
    widgets.receipts:SetPoint("LEFT", widgets.listNames.label, "RIGHT", 40, 0)

    -- Buff Back tab only, right under Enabled (the tab has no timing rows):
    -- the line, and how long favours last.
    widgets.sayLine = Checkbox(content, "Say a line once my buff lands", function(on)
        ns.db.buffBack.sayLine = on
        ns.BuffButton.Refresh()
    end)
    widgets.sayLine:SetPoint("TOPLEFT", widgets.enabled, "BOTTOMLEFT", 0, -4)
    -- On the delay's place in row 1 (Buff Back has no delay).
    widgets.buffModeKey = Button(content, "", 290, function() Options.StartKeyCapture() end)
    widgets.buffModeKey:SetPoint("LEFT", widgets.enabled.label, "RIGHT", 40, 0)
    widgets.keyCapture = CreateKeyCapture(content)
    local owedMinutes = Stepper(content, "Offer for (minutes):", "owedMinutes")
    owedMinutes.label:SetPoint("LEFT", widgets.sayLine.label, "RIGHT", 40, 0)
    widgets.steppers.owedMinutes = owedMinutes
    widgets.showInCities = Checkbox(content, "Show the button in capital cities (buff mode always shows it)",
        function(on)
            ns.db.buffBack.showInCities = on
            ns.BuffButton.Refresh()
        end)
    widgets.showInCities:SetPoint("TOPLEFT", widgets.sayLine, "BOTTOMLEFT", 0, -4)

    -- Row 4: thank them with a line in /say, a whisper, a /thank emote, or a
    -- line and an emote (click to cycle).
    widgets.thankStyleLabel = Label(content, "Thank them with:")
    widgets.thankStyleLabel:SetPoint("TOPLEFT", widgets.listNames, "BOTTOMLEFT", 4, -10)
    widgets.thankStyle = Button(content, Options.THANK_STYLE_TEXT.message, 220, function()
        ns.db.buff.thankStyle = NextIn(Options.THANK_STYLES, ns.db.buff.thankStyle)
        Options.Refresh()
    end)
    widgets.thankStyle:SetPoint("LEFT", widgets.thankStyleLabel, "RIGHT", 10, 0)

    -- Row 5: if that can't reach them (no name, or the whisper fails): a
    -- line in /say calling them the name in the box, a /thank, or nothing.
    widgets.fallbackLabel = Label(content, "If that can't reach them:")
    widgets.fallbackLabel:SetPoint("TOPLEFT", widgets.thankStyleLabel, "BOTTOMLEFT", 0, -16)
    widgets.fallback = Button(content, Options.FALLBACK_TEXT.say, 160, function()
        ns.db.buff.fallback = NextIn(Options.FALLBACKS, ns.db.buff.fallback)
        Options.Refresh()
    end)
    widgets.fallback:SetPoint("LEFT", widgets.fallbackLabel, "RIGHT", 10, 0)
    widgets.unknownName = TextBox(content, 100, Config.LIMITS.unknownName.maxBytes)
    widgets.unknownName:SetPoint("LEFT", widgets.fallback, "RIGHT", 10, 0)
    widgets.unknownName:SetScript("OnTextChanged", function(self, userInput)
        if userInput then ns.db.buff.unknownName = Config.CleanUnknownName(self:GetText()) end
    end)

    -- Row 6: quiet in capital cities (Cities.lua)
    widgets.quiet = Checkbox(content, "Stay quiet in capital cities (no thank-yous; the ledger still counts)",
        function(on) ns.db.buff.quietInCities = on end)
    widgets.quiet:SetPoint("TOPLEFT", widgets.fallbackLabel, "BOTTOMLEFT", -4, -8)

    -- Row 7: warning + one-click fix when friendly nameplates are off
    widgets.nameplateWarning = Label(content, ns.Colours.Text("warn", "Friendly player nameplates are off, so the game "
        .. "can't tell you who buffed you."), "GameFontHighlightSmall")
    widgets.nameplateWarning:SetPoint("TOPLEFT", widgets.quiet, "BOTTOMLEFT", 4, -8)
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
    msgHeader:SetPoint("TOPLEFT", widgets.quiet, "BOTTOMLEFT", 4, -32)
    widgets.msgHeader = msgHeader

    -- Buff Back tab only, in the buff tab's rows 4 to 6: the buff order, one
    -- row per buff of your class (the most any class has).
    widgets.buffOrderHeader = Label(content, "", "GameFontNormalSmall")
    widgets.buffOrderHeader:SetPoint("TOPLEFT", widgets.showInCities, "BOTTOMLEFT", 4, -10)
    local most = 0
    for _, list in pairs(ns.BuffData.CLASSES) do most = math.max(most, #list) end
    widgets.buffRows = {}
    local above = widgets.buffOrderHeader
    for i = 1, most do
        local row = {}
        row.up = Button(content, "Up", 44, function() if row.key then Options.MoveBuff(row.key, -1) end end)
        row.up:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -4)
        row.down = Button(content, "Down", 54, function() if row.key then Options.MoveBuff(row.key, 1) end end)
        row.down:SetPoint("LEFT", row.up, "RIGHT", 4, 0)
        row.name = Label(content, "", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.down, "RIGHT", 10, 0)
        row.name:SetWidth(220)
        row.never = Checkbox(content, "Never offer", function(on)
            if row.key then Options.SetNeverOffer(row.key, on) end
        end)
        row.never:SetPoint("LEFT", row.name, "RIGHT", 10, 0)
        row.who = Button(content, "", 170, function() if row.key then Options.CycleWho(row.key) end end)
        row.who:SetPoint("LEFT", row.never.label, "RIGHT", 12, 0)
        widgets.buffRows[i] = row
        above = row.up
    end

    -- Buff Back tab only, below the buff list: who gets the chosen buff in
    -- buff mode (BuffRules.lua). Anchored in FillWho.
    local who = { classes = {}, classRows = {} }
    widgets.who = who
    who.header = Label(content, "", "GameFontNormalSmall")
    local prevClass
    for i, class in ipairs(ns.BuffRules.CLASSES) do
        local cb = Checkbox(content, ClassText(class), function(on) Options.SetWhoClass(class, on) end)
        if i == 1 or i == 6 then
            cb:SetPoint("TOPLEFT", i == 1 and who.header or who.classRows[1], "BOTTOMLEFT", i == 1 and -4 or 0, -2)
            who.classRows[#who.classRows + 1] = cb
        else
            cb:SetPoint("LEFT", prevClass.label, "RIGHT", 12, 0)
        end
        who.classes[class] = cb
        prevClass = cb
    end
    local function NamesBox(list, labelText)
        local label = Label(content, labelText, "GameFontHighlightSmall")
        label:SetWidth(60)
        local box = TextBox(content, 380, ns.BuffRules.MAX_LIST_LETTERS)
        box:SetPoint("LEFT", label, "RIGHT", 6, 0)
        box:SetScript("OnEditFocusGained", function(self) self.buffKey = Options.WhoBuffKey() end)
        box:SetScript("OnEditFocusLost", function(self)
            local key = self.buffKey
            self.buffKey = nil
            Options.SetWhoNames(key, list, self:GetText())
        end)
        return label, box
    end
    who.alwaysLabel, who.always = NamesBox("always", "Always:")
    who.neverLabel, who.never = NamesBox("never", "Never:")
    who.neverLabel:SetPoint("TOPLEFT", who.alwaysLabel, "BOTTOMLEFT", 0, -12)
    -- Paladins: whose Salvation to Revoke (BuffRules.lua). Anchored in FillRevoke.
    who.revoke = Button(content, "", 300, function() Options.CycleRevoke() end)
    who.revokeLabel = Label(content, "Names:", "GameFontHighlightSmall")
    who.revokeLabel:SetWidth(60)
    who.revokeLabel:SetPoint("TOPLEFT", who.revoke, "BOTTOMLEFT", 0, -10)
    who.revokeNames = TextBox(content, 380, ns.BuffRules.MAX_LIST_LETTERS)
    who.revokeNames:SetPoint("LEFT", who.revokeLabel, "RIGHT", 6, 0)
    who.revokeNames:SetScript("OnEditFocusLost", function(self) Options.SetRevokeNames(self:GetText()) end)
    -- Paladins: the Blessings given in this raid. Anchored in FillRaidBlessings.
    who.raidHeader = Label(content, "", "GameFontNormalSmall")
    who.raidBlessings = {}
    local mostBlessings = 0
    for _, list in pairs(ns.BuffData.CLASSES) do
        local n = 0
        for _, buff in ipairs(list) do if buff.family == "blessing" then n = n + 1 end end
        mostBlessings = math.max(mostBlessings, n)
    end
    for i = 1, mostBlessings do
        local cb = Checkbox(content, "", function() Options.SetRaidBlessing() end)
        if i == 1 then
            cb:SetPoint("TOPLEFT", who.raidHeader, "BOTTOMLEFT", -4, -2)
        else
            cb:SetPoint("LEFT", who.raidBlessings[i - 1].label, "RIGHT", 12, 0)
        end
        who.raidBlessings[i] = cb
    end

    -- Buff Back tab only, below the buff list: when buff mode turns on and
    -- off by itself (BuffModeAuto.lua). Anchored in FillBuffRows.
    widgets.auto = {}
    local function AutoBox(field, text)
        local cb = Checkbox(content, text, function(on)
            ns.db.buffBack[field] = on
            ns.BuffButton.Refresh()
        end)
        widgets.auto[field] = cb
        return cb
    end
    widgets.autoHeader = Label(content, "Buff mode turns on by itself:", "GameFontNormalSmall")
    local onJoin = AutoBox("autoOnJoin", "when I join a group")
    onJoin:SetPoint("TOPLEFT", widgets.autoHeader, "BOTTOMLEFT", -4, -2)
    local onDeath = AutoBox("autoOnDeath", "after a death in my group")
    onDeath:SetPoint("LEFT", onJoin.label, "RIGHT", 16, 0)
    local onBuffed = AutoBox("autoOnBuffed", "when a stranger buffs me")
    onBuffed:SetPoint("LEFT", onDeath.label, "RIGHT", 16, 0)
    widgets.autoOffHeader = Label(content, "...and off again (only when it turned itself on):", "GameFontNormalSmall")
    widgets.autoOffHeader:SetPoint("TOPLEFT", onJoin, "BOTTOMLEFT", 4, -6)
    local offPull = AutoBox("autoOffPull", "at the first pull")
    offPull:SetPoint("TOPLEFT", widgets.autoOffHeader, "BOTTOMLEFT", -4, -2)
    local offDone = AutoBox("autoOffDone", "when everyone has my buffs")
    offDone:SetPoint("LEFT", offPull.label, "RIGHT", 16, 0)
    local offMinutes = Stepper(content, "or after (minutes, 0 = never):", "autoOffMinutes")
    offMinutes.label:SetPoint("TOPLEFT", offPull, "BOTTOMLEFT", 4, -8)
    widgets.steppers.autoOffMinutes = offMinutes
    -- Top-up timing (GroupBuffs.lua, #42): renew a buff before it runs out.
    local topUp = Stepper(content, "Top up my buffs with under (minutes left, 0 = never):", "topUpMinutes")
    topUp.label:SetPoint("TOPLEFT", offMinutes.label, "BOTTOMLEFT", 0, -14)
    widgets.steppers.topUpMinutes = topUp

    -- Battlegrounds (Battleground.lua): after the gates open the addon is
    -- quiet whatever this says; this is about the preparation phase.
    widgets.bgHeader = Label(content, "Battlegrounds (quiet once the battle starts):", "GameFontNormalSmall")
    widgets.bgHeader:SetPoint("TOPLEFT", topUp.label, "BOTTOMLEFT", 0, -14)
    widgets.bgPrepBuff = Checkbox(content, "Buff in the preparation phase", function(on)
        ns.db.buffBack.bgPrepBuff = on
        ns.Battleground.Update()
        ns.BuffButton.Refresh()
    end)
    widgets.bgPrepBuff:SetPoint("TOPLEFT", widgets.bgHeader, "BOTTOMLEFT", -4, -2)

    -- Unending Breath and Water Breathing wait for water (Water.lua, #136).
    -- Its own heading, so it doesn't read as a battleground setting.
    widgets.waterHeader = Label(content, "Unending Breath and Water Breathing:", "GameFontNormalSmall")
    widgets.waterHeader:SetPoint("TOPLEFT", widgets.bgPrepBuff, "BOTTOMLEFT", 4, -10)
    widgets.breathNearWater = Checkbox(content, "Water breathing: only near water", function(on)
        ns.db.buffBack.breathNearWater = on
        ns.BuffButton.Refresh()
    end)
    widgets.breathNearWater:SetPoint("TOPLEFT", widgets.waterHeader, "BOTTOMLEFT", -4, -2)
    Tooltip(widgets.breathNearWater, Options.BREATH_TOOLTIP)

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
    widgets.loadCasual = Button(content, "Load casual lines (0.6)", 170, function() LoadLines(ns.CasualMessages) end)
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
local function SubPage(name, title, frameName)
    local page = CreateFrame("Frame", frameName)
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

-- A scrolling area filling page below its heading, for a page whose text
-- can outgrow it (#52). height is the scrolled content's, which holds the
-- page's longest text as the game wraps it. Returns the content frame, which
-- is also page.content.
local function ScrollArea(page, height)
    local scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", page.heading, "BOTTOMLEFT", -16, -4)
    scroll:SetPoint("BOTTOMRIGHT", -28, 4)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(600, height)
    scroll:SetScrollChild(content)
    FollowWidth(scroll, content)
    page.scroll, page.content = scroll, content
    return content
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
    generalPage = SubPage("General", "General", Options.GENERAL_PAGE)
    local page = generalPage
    -- Everything below the heading scrolls (#52): a long ignore list or
    -- profile list, or text that wraps more in the game than expected, can't
    -- push the last lines out of reach.
    local area = ScrollArea(page, Options.GENERAL_HEIGHT)

    -- Snooze
    local snooze = Label(area, "Snooze", "GameFontNormal")
    snooze:SetPoint("TOPLEFT", 16, -12)
    w.snoozeState = Note(area, snooze, "")
    w.snooze15 = Button(area, "15 minutes", 110, function() ns.SnoozeFor(15) end)
    w.snooze15:SetPoint("TOPLEFT", w.snoozeState, "BOTTOMLEFT", 0, -6)
    w.snooze60 = Button(area, "1 hour", 90, function() ns.SnoozeFor(60) end)
    w.snooze60:SetPoint("LEFT", w.snooze15, "RIGHT", 8, 0)
    w.wake = Button(area, "Wake up", 90, function() ns.SnoozeFor(nil) end)
    w.wake:SetPoint("LEFT", w.snooze60, "RIGHT", 8, 0)

    -- Chat limit (#35). The stepper is its own section heading, which keeps
    -- the page short.
    w.linesPerMinute = Stepper(area, "Lines per minute in each chat:", "linesPerMinute", function() return ns.db end,
        "GameFontNormal")
    w.linesPerMinute.label:SetPoint("TOPLEFT", w.snooze15, "BOTTOMLEFT", 0, -20)
    -- Says why the limit is there (#35): the addon helps people talk, and
    -- mustn't become the spam it's meant to soften.
    w.capHelp = Note(area, w.linesPerMinute.label, "Keeps Friendly Forever a helper, not a spammer: at most this "
        .. "many lines a minute go to each chat (/say, whispers, emotes, guild, group). Thank-yous over the "
        .. "limit are skipped; greetings wait their turn.")
    w.capHelp:SetPoint("TOPLEFT", w.linesPerMinute.label, "BOTTOMLEFT", 0, -10)

    -- Ignore list
    local ignore = Section(area, w.capHelp, "Never greet or thank")
    w.ignoreList = Note(area, ignore, "")
    w.ignoreBox = TextBox(area, 220, 60)
    w.ignoreBox:SetPoint("TOPLEFT", w.ignoreList, "BOTTOMLEFT", 6, -8)
    w.ignoreAdd = Button(area, "Add", 70, function()
        local name, why = ns.Ignore.Add(w.ignoreBox:GetText())
        if name then w.ignoreBox:SetText("") end
        Say(name, "couldn't add: " .. tostring(why),
            name and (ns.Util.DisplayName(name) .. " won't be greeted or thanked."))
    end)
    w.ignoreAdd:SetPoint("LEFT", w.ignoreBox, "RIGHT", 8, 0)
    w.ignoreRemove = Button(area, "Remove", 80, function()
        local name, why = ns.Ignore.Remove(w.ignoreBox:GetText())
        if name then w.ignoreBox:SetText("") end
        Say(name, "couldn't remove: " .. tostring(why), name and (ns.Util.DisplayName(name) .. " is off the list."))
    end)
    w.ignoreRemove:SetPoint("LEFT", w.ignoreAdd, "RIGHT", 6, 0)
    w.ignoreHelp = Note(area, w.ignoreBox, "Full names, such as Nikki Shifts. Leave the box empty and click Add "
        .. "to add your target.")
    w.ignoreHelp:SetPoint("TOPLEFT", w.ignoreBox, "BOTTOMLEFT", -6, -6)

    -- Profiles
    local profiles = Section(area, w.ignoreHelp, "Profiles")
    w.profileState = Note(area, profiles, "")
    w.profileBox = TextBox(area, 160, ns.Profiles.MAX_NAME)
    w.profileBox:SetPoint("TOPLEFT", w.profileState, "BOTTOMLEFT", 6, -8)
    local function ProfileButton(text, width, fn, success)
        return Button(area, text, width, function()
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
    w.profileHelp = Note(area, w.profileBox, "Type a name, then New (a copy of your settings) or Use. "
        .. "Each character switches to the profile it used last when it logs in.")
    w.profileHelp:SetPoint("TOPLEFT", w.profileBox, "BOTTOMLEFT", -6, -6)

    -- Export / import
    local share = Section(area, w.profileHelp, "Share your settings")
    w.export = Button(area, "Export", 90, function() ns.ShowExport() end)
    w.export:SetPoint("TOPLEFT", share, "BOTTOMLEFT", 0, -8)
    w.import = Button(area, "Import", 90, function() ns.ShowImport() end)
    w.import:SetPoint("LEFT", w.export, "RIGHT", 8, 0)
    w.undoImport = Button(area, "Undo import", 110, function()
        local ok, why = ns.Profiles.UndoImport()
        Say(ok, "couldn't undo: " .. tostring(why), "your settings from before the import are back.")
    end)
    w.undoImport:SetPoint("LEFT", w.import, "RIGHT", 8, 0)
    w.shareHelp = Note(area, w.export, "One line of text with your messages and options. Importing never turns "
        .. "the addon on or off and only adds to your ignore list.")

    -- Bug report
    local help = Section(area, w.shareHelp, "Something not working?")
    w.report = Button(area, "Copy for a bug report", 180, function() ns.ShowBugReport() end)
    w.report:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -8)
    w.reportHelp = Note(area, w.report, "Shows /friendly status and the debug log as text to copy. "
        .. "Turn on /friendly debug and make the problem happen first, so the log shows it.")

    page:SetScript("OnShow", function() FillGeneral() end)
    -- For the UI simulator's layout checks and screenshot (uitests/), which
    -- see the addon only through its globals: everything must fit in
    -- page.content, the scrolling area.
    page.widgets = w
    panel.generalPage = page
end

-- The first shown items of list, then how many more there are and the
-- command that lists them all.
local function Shown(list, shown, command)
    if #list <= shown then return table.concat(list, ", ") end
    return table.concat(list, ", ", 1, shown)
        .. string.format(" and %d more (%s shows them all).", #list - shown, command)
end

FillGeneral = function()
    local w = widgets.general
    local left = ns.Announcer.SnoozeLeft()
    w.snoozeState:SetText(left and string.format("Snoozed: nothing is sent for %d more min.", math.ceil(left / 60))
        or "Awake: messages are sent as usual.")
    w.wake:SetEnabled(left ~= nil)
    FillBox(w.linesPerMinute.box, tostring(ns.db.linesPerMinute))
    -- A few names or profiles and a count, so a long list stays inside the
    -- page's scrolling content (Options.GENERAL_HEIGHT), and the page tidy.
    local names = ns.Ignore.List()
    w.ignoreList:SetText(#names > 0 and Shown(names, Options.IGNORE_SHOWN, "/friendly ignore list") or "Nobody.")
    w.profileState:SetText("Using " .. ns.Profiles.Active() .. ". All profiles: "
        .. Shown(ns.Profiles.List(), Options.PROFILES_SHOWN, "/friendly profile"))
    w.undoImport:SetEnabled(ns.Profiles.CanUndoImport())
end

function Options.CreateLedgerPage()
    local w = widgets.ledger
    ledgerPage = SubPage("Favour Ledger", "Favour Ledger", Options.LEDGER_PAGE)
    local page = ledgerPage
    w.summary = Note(page, page.heading, "")
    local anchor = w.summary
    w.rows = {}
    for i = 1, Options.LEDGER_ROWS do
        local row = Label(page, "", "GameFontHighlightSmall")
        row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, i == 1 and -12 or -4)
        row:SetPoint("RIGHT", page, "RIGHT", -24, 0)
        -- One line each, cut with "…" when long: a row that wrapped would push
        -- the rows below it off the page (#52). /friendly ledger shows them whole.
        row:SetWordWrap(false)
        w.rows[i] = row
        anchor = row
    end
    w.clear = Button(page, "Clear the ledger", 140, function()
        ns.Ledger.Clear()
        Options.Refresh()
    end)
    w.clear:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -14)
    w.note = Note(page, w.clear, "Buffs from players outside your group, while Buff Thanks or Buff Back is on. "
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
