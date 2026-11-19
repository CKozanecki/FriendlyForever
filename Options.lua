-- Options panel: Esc > Options > AddOns > Friendly Forever.
-- One tab per greeting message type: on/off, delay, repeat cooldown, the 30
-- messages. Then Favours (#491), thanking people who buff you and buffing
-- them back, with both sets of lines, and Buffs (#408).
-- Two pages under it: General (snooze, chat limit, ignore list, profiles,
-- export/import, bug report) and Favour Ledger.
local _, ns = ...
local Config = ns.Config

local Options = {}
ns.Options = Options

-- Room for the tallest tab, before the content is sized to its rows (#482).
-- That was the Buff Back tab with its buff list and
-- who gets each (#363), about 2133 px with the UI simulator's pessimistic line
-- wrapping. Those rows are on the Buffs tab now (#408), which is shorter: a
-- paladin's 11 buff rows, its own options and one place's rows with a buff's
-- names open. The UI simulator's scenario "the Buffs tab stays inside its page
-- at its tallest" checks every place fits.
Options.CONTENT_HEIGHT = 2200
Options.TABS_PER_ROW = 4
-- The Buffs tab's name among the tabs (#408): not a message type.
Options.BUFFS_TAB = "buffs"
-- The Favours tab's (#491): the buff and buffBack sections, which were the
-- Buff Thanks and Buff Back tabs, on one tab. Its lines are a sub-tab each.
Options.FAVOURS_TAB = "favours"
-- The tabs, in the panel's order: every message type that isn't a favour's,
-- then Favours and Buffs. Worked out from Config.TYPES, so a new message
-- type can't go without its tab.
Options.TABS = {}
Options.FAVOUR_LINES = {} -- the Favours tab's lines' sub-tabs, in order
for _, msgType in ipairs(Config.TYPES) do
    local list = Config.TYPE_INFO[msgType].favours and Options.FAVOUR_LINES or Options.TABS
    list[#list + 1] = msgType
end
Options.TABS[#Options.TABS + 1] = Options.FAVOURS_TAB
Options.TABS[#Options.TABS + 1] = Options.BUFFS_TAB
Options.TAB_TEXT = { [Options.FAVOURS_TAB] = "Favours", [Options.BUFFS_TAB] = "Buffs" }
local TAB_NAMES = {}
for _, tab in ipairs(Options.TABS) do TAB_NAMES[tab] = true end

local panel, category, startPage, generalPage, ledgerPage
local weaponPage -- Weapon buffs (#45)
local currentType = Config.TYPES[1] -- the tab shown: a message type, Favours or Buffs
local favourLines = Options.FAVOUR_LINES[1] -- the Favours tab's lines shown (#491)
local widgets = { tabs = {}, edits = {}, steppers = {}, general = {}, ledger = {}, start = {}, weapon = {} }
-- Every number box a Stepper makes, so ClearEditFocus can't miss one (#171).
local numberBoxes = {}

-- The message type whose rows show: the tab's, or nil on Favours and Buffs.
local function MessageTab()
    local info = Config.TYPE_INFO[currentType]
    if info and not info.favours then return currentType end
end

-- The message type whose lines show: the tab's, or on Favours its lines'
-- sub-tab (#491); nil on Buffs.
local function LinesType()
    if currentType == Options.FAVOURS_TAB then return favourLines end
    return MessageTab()
end
Options.LinesType = LinesType

-- The tab's settings section: never a damaged one (Config.Section, #166).
-- Only a message tab's rows call it.
local function Current()
    return Config.Section(MessageTab())
end

-- The two sections the Favours tab's controls write (#491), whichever tab
-- shows: never damaged ones either (#330).
local function Buff()
    return Config.Section("buff")
end
local function BuffBack()
    return Config.Section("buffBack")
end
Options.widgets = widgets -- exposed for tests

Options.LEDGER_ROWS = 25
Options.IGNORE_SHOWN = 12 -- names listed on the General page; the rest are counted
Options.PROFILES_SHOWN = 6 -- profiles listed there, the same way
-- The General page's scrolling content: room for its sections with both
-- lists at their longest (#52).
Options.GENERAL_HEIGHT = 720
-- The pages' frame names, so the UI simulator's scenarios can find them (#52).
Options.GENERAL_PAGE = "FriendlyForeverGeneralPage"
Options.START_PAGE = "FriendlyForeverStartPage"
-- The Start here page's scrolling content (#47), with room to spare for its
-- notes wrapping more in the game than expected.
Options.START_HEIGHT = 680
Options.LEDGER_PAGE = "FriendlyForeverLedgerPage"
Options.WEAPON_PAGE = "FriendlyForeverWeaponPage"

-- How to thank someone who buffs you, and what to do when that can't reach
-- them (#101), in the order each dropdown lists them (#274).
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

-- While the panel is made, the rows made on its scrolling content are noted
-- in a list (Options.Collect): a message tab's own in one, the lines (a
-- message tab's and the Favours tab's) in another, the Favours tab's own
-- (#491) and the Buffs tab's (#408) in theirs, so each tab shows its own and
-- hides the others'. They stay the content's own children, where the UI
-- simulator reads them.
local collector, collectParent
local typeRows, linesRows, favoursRows, buffsRows = {}, {}, {}, {}
function Options.Collect(list, parent)
    collector, collectParent = list, parent
end
-- The Buffs tab's rows, as noted (BuffsTab.Owns).
function Options.BuffsRows() return buffsRows end
local function Noted(object, parent)
    if collector and parent == collectParent then collector[#collector + 1] = object end
    return object
end
Options.Noted = Noted

-- A frame on a scrolling content that floats over it (a list that opens, a
-- key capture covering the tab) and so isn't part of how tall it is (#482).
local function Floating(frame)
    frame.floating = true
    return frame
end
Options.Floating = Floating

-- Below a page's last shown control, the room its scrolling ends with (#482).
Options.SCROLL_MARGIN = 16

-- The lowest bottom edge of content's shown rows, or nil when none can be
-- read yet (not laid out). Only the content's own frames and text count:
-- a control's parts sit inside it.
local function LowestBottom(content)
    local lowest
    local function Look(region)
        if region.floating or not region:IsShown() then return end
        local bottom = region:GetBottom()
        if type(bottom) == "number" and bottom == bottom and (not lowest or bottom < lowest) then lowest = bottom end
    end
    for _, child in ipairs({ content:GetChildren() }) do Look(child) end
    for _, region in ipairs({ content:GetRegions() }) do Look(region) end
    return lowest
end

-- Sizes a scrolling area's content to its rows (#482): it scrolls only to
-- its last shown control plus SCROLL_MARGIN, never into an empty pane, and a
-- page that fits has no scroll range and no scroll bar. The offset is kept
-- inside the new range, so a tab or sub-tab with less on it never shows
-- empty space. Edges the game can't give yet change nothing.
local function FitHeight(scroll, content)
    local top, lowest = content:GetTop(), LowestBottom(content)
    if type(top) ~= "number" or top ~= top or not lowest then return end
    local height = math.max(1, top - lowest + Options.SCROLL_MARGIN)
    content:SetHeight(height)
    local view = scroll:GetHeight()
    local range = math.max(0, height - (type(view) == "number" and view or 0))
    if scroll:GetVerticalScroll() > range then scroll:SetVerticalScroll(range) end
    if scroll.ScrollBar then scroll.ScrollBar:SetShown(range > 0) end
    return height, range
end
Options.FitHeight = FitHeight

-- After a page fills: the game lays out the rows it asks the edges of. The
-- settings window's own late layout is caught by the next-frame fit each
-- show runs (FollowWidth), and by the panel's next-frame refill.
local Refit = FitHeight

local function Label(parent, text, font)
    local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlight")
    fs:SetText(text)
    fs:SetJustifyH("LEFT")
    return Noted(fs, parent)
end

local function Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return Noted(b, parent)
end

-- A dropdown listing every choice (#274). It is built from the same buttons
-- as the rest of the options, so it works wherever they do: the game's own
-- dropdown menus are left out, as they are known to taint other UI. The
-- button shows the current choice and opens the list below it; picking a row
-- (or clicking anywhere else, or hiding the button) closes it. order lists
-- the saved values, texts says how each reads. get() returns the saved
-- value (anything damaged reads as the first, the default); pick(value)
-- saves the chosen one.
local ARROW = "Interface\\Buttons\\Arrow-Down-Up"
local function Dropdown(parent, order, texts, width, get, pick)
    local dd = Button(parent, texts[order[1]], width, nil)
    local text = dd:GetFontString()
    text:ClearAllPoints()
    text:SetPoint("LEFT", dd, "LEFT", 8, 0)
    text:SetPoint("RIGHT", dd, "RIGHT", -22, 0)
    text:SetJustifyH("LEFT")
    local arrow = dd:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture(ARROW)
    arrow:SetSize(14, 14)
    arrow:SetPoint("RIGHT", dd, "RIGHT", -6, 0)

    local list = CreateFrame("Frame", nil, dd)
    list:SetFrameStrata("DIALOG")
    list:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
    list:SetSize(width, 22 * #order)
    list:Hide()
    -- Behind the rows: a click anywhere else closes the list.
    local catcher = CreateFrame("Button", nil, list)
    catcher:SetAllPoints(UIParent)
    catcher:EnableMouse(true)
    catcher:SetScript("OnClick", function() list:Hide() end)
    list.catcher = catcher
    dd.list, dd.rows = list, {}
    -- Frames made from one parent get one frame level, and the game doesn't
    -- say which of them takes a click where they overlap, so the catcher
    -- could take the click meant for a row and close the list without saving
    -- (#427). Give the rows an explicit level above it, again each time the
    -- list opens, whatever the panel did to the levels meanwhile.
    local function Layer()
        local base = list:GetFrameLevel()
        catcher:SetFrameLevel(base)
        for _, row in ipairs(dd.rows) do row:SetFrameLevel(base + 2) end
    end
    list:SetScript("OnShow", Layer)
    for i, value in ipairs(order) do
        local row = Button(list, texts[value], width, function()
            list:Hide()
            pick(value)
        end)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -22 * (i - 1))
        row.value = value
        dd.rows[i] = row
    end

    -- The current choice on the button, and marked in the list.
    function dd.Fill()
        local current = get()
        if texts[current] == nil then current = order[1] end
        dd:SetText(texts[current])
        for _, row in ipairs(dd.rows) do
            if row.value == current then row:LockHighlight() else row:UnlockHighlight() end
        end
    end
    dd:SetScript("OnClick", function()
        if not list:IsShown() then Layer() end
        list:SetShown(not list:IsShown())
    end)
    dd:SetScript("OnHide", function() list:Hide() end)
    return dd
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

-- The message boxes' hover (#441): sample values for what a line fills in,
-- how many examples it shows, and the most phrases it lists for one placeholder.
Options.SAMPLE_NAME = "Nikki-Shifts"
Options.SAMPLE_BUFF = "Power Word: Fortitude"
Options.PREVIEW_EXAMPLES = 3
-- A guild message's {zone} is the guildmate's (#486): previews of a guild
-- tab's lines say this one, and the hover says whose it is.
Options.SAMPLE_ZONE = "Stranglethorn Vale"
Options.GUILD_ZONE_NOTE = "{zone} here is the guildmate's zone, from the guild roster (such as %s). "
    .. "When the roster can't say, a line or phrase that needs it isn't used."

-- The moment a preview of msgType's lines renders in: a guild tab's has the
-- sample guildmate's zone and the guild's phrases (#486); nil reads yours.
function Options.PreviewContext(msgType)
    local info = Config.TYPE_INFO[msgType]
    if info and info.guild then return ns.Flavour.Context({ zone = Options.SAMPLE_ZONE }) end
end
Options.PREVIEW_POOL_MAX = 24
Options.PREVIEW_WIDTH = 70

Options.RAID_SPLIT_TOOLTIP = "In a raid, copies of Friendly Forever share out the buffs their class has "
    .. "in common, so three priests give Fortitude, Spirit and Shadow Protection between them. Buff mode then "
    .. "offers you only your share; the button's tooltip says what it is. Players of a class who outnumber "
    .. "its buffs split the raid's groups (a spare paladin waits as a backup). You take part while buff mode "
    .. "is on, and for 5 minutes after. Off: you're offered everything, and within 3 minutes other copies stop "
    .. "counting on you."
Options.GROUP_VERSIONS_TOOLTIP = "In buff mode, offer the group version of a buff (Arcane Brilliance, "
    .. "Prayer of Fortitude, Prayer of Spirit, Prayer of Shadow Protection, Gift of the Wild) "
    .. "when you know it, carry its reagent, and enough of the party it covers (in a raid, the subgroup) "
    .. "are missing the buff. Never cast at anyone flagged for PvP "
    .. "when you aren't, unless your whole group is inside a dungeon or raid with you, "
    .. "and never against your \"who gets each buff\" rules."
Options.SELF_BUFFS_TOOLTIP = "In buff mode, once your favours and your group are done, offer the self-buffs "
    .. "you're missing (\"you only\" in the list above: Inner Fire, armors, Aspects, auras...), in your buff "
    .. "order. Not while you're dead, mounted, flying or in a form, or the game says the spell can't be cast now."
Options.SOLO_OWN_BUFFS_TOOLTIP = "In buff mode, when you're not in a group, offer your own buffs on you "
    .. "(Fortitude, Arcane Intellect, Mark of the Wild, a Blessing...) when you're missing them or they're "
    .. "running low, by your buff order, Never offer and who gets each buff. Single buffs only, never a "
    .. "group version. Someone else's copy on you counts until it runs low."
Options.BREATH_TOOLTIP = "Offer Unending Breath and Water Breathing only while you're swimming or underwater, "
    .. "for 2 minutes after, or in an underwater dungeon."

local function Checkbox(parent, text, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    local label = Label(cb, text)
    label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb.label = label
    return Noted(cb, parent)
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
    return Noted(box, parent)
end

-- Label, [-] [number] [+], bound to settings()[field] within limits;
-- settings defaults to the tab's section (Current), whose field is read
-- checked (Config.Field, #330). Does nothing on a type without that field
-- (its stepper is hidden there). font: the label's, if not the usual one.
local function Stepper(parent, text, field, settings, font, step)
    local limits = Config.LIMITS[field]
    step = step or 1
    local s = {}
    local read = settings and function() return settings()[field] end
        or function()
            -- A message tab's own stepper: nothing to read on Favours or Buffs.
            local msgType = MessageTab()
            return msgType and Config.Field(msgType, field)
        end
    settings = settings or Current

    local function Set(value)
        if read() == nil then
            SetBoxText(s.box, "")
            return
        end
        local cfg = settings()
        cfg[field] = ns.Util.ClampNumber(value, limits.min, limits.max, cfg[field])
        SetBoxText(s.box, tostring(cfg[field]))
    end
    s.Set = Set

    local function Step(by)
        local current = read()
        if current ~= nil then Set(current + by) end
    end

    s.label = Label(parent, text, font)
    s.minus = Button(parent, "-", 24, function() Step(-step) end)
    s.minus:SetPoint("LEFT", s.label, "RIGHT", 8, 0)
    s.box = TextBox(parent, 44, 4)
    s.box:SetNumeric(true)
    s.box:SetJustifyH("CENTER")
    s.box:SetPoint("LEFT", s.minus, "RIGHT", 8, 0)
    s.box:SetScript("OnEditFocusLost", function(self) Set(tonumber(self:GetText())) end)
    numberBoxes[#numberBoxes + 1] = s.box
    s.plus = Button(parent, "+", 24, function() Step(step) end)
    s.plus:SetPoint("LEFT", s.box, "RIGHT", 4, 0)
    return s
end

-- Leave alone a box the player is typing in: rewriting it would undo their
-- edit and move the cursor to the start.
local function FillBox(box, text)
    if not box:HasFocus() then SetBoxText(box, text) end
end

-- Finish any edit in progress (a number box saves when it loses focus)
-- before a tab switch or reset gives the boxes new contents. Every number
-- box is in numberBoxes, so a new one can't be left out (#171).
local function ClearEditFocus()
    local boxes = { widgets.unknownName }
    for _, box in ipairs(numberBoxes) do boxes[#boxes + 1] = box end
    for _, edit in ipairs(widgets.edits) do boxes[#boxes + 1] = edit end
    if widgets.who then
        boxes[#boxes + 1] = widgets.who.always
        boxes[#boxes + 1] = widgets.who.never
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
    BuffBack() -- the key is saved there: never to a damaged section (#330)
    local ok, why = ns.BuffMode.SetKey(ModifierPrefix() .. key)
    if not ok then ns.Print("couldn't set the buff mode key: " .. why .. ".") end
    widgets.buffModeKey:SetText(KeyButtonText())
end

-- How far above its tab's content the capture sits. The widgets there are
-- siblings of the capture (children of that content), one level above it or a
-- few more for their own lists, so the margin is generous (#429).
Options.KEY_CAPTURE_LEVEL = 100

function Options.StartKeyCapture()
    if InCombatLockdown() then return ns.Print("keys can't be changed in a fight.") end
    local capture = widgets.keyCapture
    capture.Layer()
    capture.active = true
    capture:Show()
    capture:EnableKeyboard(true)
    capture:SetPropagateKeyboardInput(false)
    capture:EnableMouseWheel(true)
    capture:EnableMouse(true)
    widgets.buffModeKey:SetText(Options.KEY_PROMPT)
end

local function CreateKeyCapture(parent)
    local capture = Floating(CreateFrame("Frame", nil, parent))
    capture:SetAllPoints(parent)
    capture:Hide()
    -- It covers the tab, so it must take a click wherever one lands. Frames
    -- made from one parent share a frame level and the game doesn't say which
    -- takes a click where they overlap, so the capture could lose one to a
    -- checkbox under it and change a setting instead of choosing the key
    -- (#429, as the dropdowns in #427). Set an explicit level well above its
    -- siblings, each time the capture starts or shows, whatever the panel
    -- did to the levels meanwhile.
    function capture.Layer() capture:SetFrameLevel(parent:GetFrameLevel() + Options.KEY_CAPTURE_LEVEL) end
    capture:SetScript("OnShow", capture.Layer)
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

-- Your class's buffs in your order, for moving one (the Buffs tab's Up and
-- Down). Read checked (#330), so the section then written is never a damaged one.
local function OrderedClassBuffs()
    return ns.BuffData.InOrder(ns.BuffData.ClassBuffs(), Config.Field("buffBack", "buffOrder"))
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
    local never = Config.Field("buffBack", "neverOffer") -- never a damaged list (#330)
    -- A buff that's never offered by default (Righteous Fury, #44) keeps an
    -- untick as false; any other buff's untick is no entry, as before.
    local buff = ns.BuffData.ByKey(key)
    if on then
        never[key] = true
    elseif buff and buff.defaultNever then
        never[key] = false
    else
        never[key] = nil
    end
    ns.BuffButton.Refresh()
    Options.Refresh()
end

local function ClassText(class)
    local names = rawget(_G, "LOCALIZED_CLASS_NAMES_MALE")
    local name = type(names) == "table" and names[class]
    if type(name) == "string" then return name end
    return class:sub(1, 1) .. class:sub(2):lower()
end

-- The helpers the Buffs tab (BuffsTab.lua, #408) builds its rows with.
Options.UI = { Label = Label, Button = Button, Checkbox = Checkbox, Tooltip = Tooltip, TextBox = TextBox,
    FillBox = FillBox, Stepper = Stepper, ClassText = ClassText, BuffBack = BuffBack,
    ClearEditFocus = function() ClearEditFocus() end }

local function ShowStepper(stepper, shown)
    for _, part in ipairs({ stepper.label, stepper.minus, stepper.box, stepper.plus }) do part:SetShown(shown) end
end

-- The Buffs tab's rows for when buff mode turns on and off by itself (#491).
Options.AUTO_SWITCHES = { "autoOnJoin", "autoOnDeath", "autoOnBuffed", "autoOnMissing", "autoOnCampfire",
    "autoOffPull", "autoOffDone" }
-- Their labels, which the walkthrough (Walkthrough.lua) repeats.
Options.AUTO_TEXT = {
    autoOnJoin = "with my group",
    autoOnDeath = "after a death in my group",
    autoOnBuffed = "when a stranger buffs me",
    autoOnMissing = "when someone's missing my buffs",
    autoOnCampfire = "at a campfire",
    autoOffPull = "at the first pull",
    autoOffDone = "when everyone has my buffs",
}

Options.AUTO_JOIN_TIP = "In a dungeon or raid with your group: it waits until everyone is in and has "
    .. "your buffs, or the first pull. Out in the world: when you join a group with another member "
    .. "close by (about 40 yards), for 2 minutes after joining."

Options.AUTO_MISSING_TIP = "In any group, out of combat: when someone close by (about 40 yards), you "
    .. "included, has none of a buff you give (never cast, or faded away), or has it running low: a "
    .. "minute left for a buff of 10 minutes or less (Thorns), your Top up time for a longer one. "
    .. "Looked at as a fight ends, and every few seconds. Turned off yourself, it stays off for those "
    .. "buffs until they're cast again; another one running low or fading turns it back on. Solo, the same "
    .. "for your own buffs, and your self-buffs if you offer them."

-- The campfire trigger (#39).
Options.AUTO_CAMPFIRE_TIP = "When a campfire's warmth (Cozy Fire) or a camp benefit is added to you, out "
    .. "of combat. Then passers-by count too (Favours tab), and buff mode stays on while one is "
    .. "missing a buff. Not in a capital city where quiet mode holds."

-- Passers-by (#39), on the Favours tab, in its first view (#491, #493).
Options.PASSERS_BY_TIP = "In buff mode, after everyone else, offer your buffs to players nearby who aren't "
    .. "in your group: a buff they're missing, or one with less than half its time left, as your rules for "
    .. "strangers allow (the Buffs tab's Strangers place). Only in the open world, never in a capital city or a "
    .. "fight; never anyone flagged for PvP while you aren't. Nothing is said to them. Right-click skips one "
    .. "for 10 minutes."
Options.PASSERS_BY_HELP = "Players nearby who aren't in your group and are missing a buff, or whose buff "
    .. "is half gone. Uses your rules for strangers (Buffs tab). Needs friendly nameplates."
-- Without friendly nameplates the game can rarely name who buffed you, and
-- nobody nearby can be seen (Nameplates.lua).
Options.NAMEPLATES_OFF = "Friendly player nameplates are off, so the game can rarely tell you who buffed you, "
    .. "and passers-by can't be seen."

-- Top-up timing (#42, #397): the stepper's mouse-over.
Options.TOP_UP_TIP = "A buff you give with less than this many minutes left is offered again in buff mode, "
    .. "so you can renew it before it runs out. A buff of 10 minutes or less (Thorns) waits until it has "
    .. "under a minute left. 0: never; a buff is offered only once it's gone."

local function FillAuto()
    local b = ns.db.buffBack
    for _, field in ipairs(Options.AUTO_SWITCHES) do widgets.auto[field]:SetChecked(b[field] == true) end
    FillBox(widgets.steppers.autoOffMinutes.box, tostring(b.autoOffMinutes))
    FillBox(widgets.steppers.topUpMinutes.box, tostring(b.topUpMinutes))
end

-- A greeting message tab's own rows; returns what its lines hang from.
local function FillMessageTab()
    local cfg = ns.db[currentType]
    local info = Config.TYPE_INFO[currentType]
    widgets.header:SetText(info.label .. "  " .. ns.Colours.Text("muted", "(sent to " .. info.channel .. ")"))
    widgets.help:SetText(info.help)
    widgets.enabled:SetChecked(cfg.enabled)
    ShowStepper(widgets.steppers.delay, not info.noTiming)
    ShowStepper(widgets.steppers.repeatCooldown, not info.noTiming)
    FillBox(widgets.steppers.delay.box, cfg.delay and tostring(cfg.delay) or "")
    FillBox(widgets.steppers.repeatCooldown.box, cfg.repeatCooldown and tostring(cfg.repeatCooldown) or "")

    local isGuildLogin = currentType == "guildLogin"
    ShowStepper(widgets.steppers.maxGreeters, isGuildLogin)
    widgets.greetersHelp:SetShown(isGuildLogin)
    if isGuildLogin then FillBox(widgets.steppers.maxGreeters.box, tostring(cfg.maxGreeters)) end
    ns.Diag.Log("options", "filled %s tab: delay %s (box shows '%s'), repeat %s (box shows '%s')",
        currentType, cfg.delay, widgets.steppers.delay.box:GetText(),
        cfg.repeatCooldown, widgets.steppers.repeatCooldown.box:GetText())
    -- The messages follow the last row this tab shows: a hidden row still
    -- takes its space, so following one would leave an empty gap.
    if isGuildLogin then return widgets.greetersHelp, 0, -18 end
    return widgets.steppers.repeatCooldown.label, 0, -18
end

-- The Favours tab's own rows (#491), from the buff and buffBack sections;
-- returns what its lines hang from.
local function FillFavours()
    local buff, back = ns.db.buff, ns.db.buffBack
    widgets.thankEnabled:SetChecked(buff.enabled)
    FillBox(widgets.steppers.thankDelay.box, tostring(buff.delay))
    FillBox(widgets.steppers.thankRepeat.box, tostring(buff.repeatCooldown))
    widgets.listNames:SetChecked(buff.listBuffNames)
    widgets.receipts:SetChecked(buff.receipts)
    widgets.thankStyle.Fill()
    widgets.fallback.Fill()
    -- The name box only means something for the /say fallback.
    widgets.unknownName:SetShown(buff.fallback == "say")
    FillBox(widgets.unknownName, buff.unknownName)
    widgets.quiet:SetChecked(buff.quietInCities)

    widgets.offerEnabled:SetChecked(back.enabled)
    widgets.sayLine:SetChecked(back.sayLine)
    FillBox(widgets.steppers.owedMinutes.box, tostring(back.owedMinutes))

    widgets.buffRequests:SetChecked(back.requests == true)
    widgets.passersBy:SetChecked(back.passersBy == true)
    -- Without friendly nameplates the game can rarely name a buffer, and
    -- nobody nearby shows: say so under passers-by, and what follows moves
    -- down under it.
    local warn = ns.Nameplates.FriendlyShown() == false
    widgets.nameplateWarning:SetShown(warn)
    widgets.nameplateButton:SetShown(warn)
    widgets.buttonHeader:ClearAllPoints()
    widgets.buttonHeader:SetPoint("TOPLEFT", warn and widgets.nameplateButton or widgets.passersByHelp,
        "BOTTOMLEFT", 0, -16)

    widgets.showInCities:SetChecked(back.showInCities)
    FillBox(widgets.steppers.renewPercent.box, tostring(back.renewPercent))

    for msgType, button in pairs(widgets.linesTabs) do button:SetEnabled(msgType ~= favourLines) end
    local info = Config.TYPE_INFO[favourLines]
    widgets.linesHelp:SetText(info.help .. "  " .. ns.Colours.Text("muted", "(sent to " .. info.channel .. ")"))
    return widgets.linesHelp, 0, -14
end

local function Fill()
    -- A section, or a field in one, damaged mid-session heals as the panel
    -- fills, whichever tab shows, and reads as its defaults (#166, #330).
    for _, msgType in ipairs(Config.TYPES) do Config.CheckedSection(msgType) end
    for tab, button in pairs(widgets.tabs) do button:SetEnabled(tab ~= currentType) end
    widgets.master:SetChecked(ns.db.enabled)
    widgets.skipAFK:SetChecked(ns.db.skipWhileAFK)
    -- The Buffs tab (#408) and the Favours tab (#491) are no message type:
    -- their rows show instead. Each tab's fill then hides the rows it
    -- doesn't show.
    local onBuffs, onFavours = currentType == Options.BUFFS_TAB, currentType == Options.FAVOURS_TAB
    for _, row in ipairs(typeRows) do row:SetShown(not onBuffs and not onFavours) end
    for _, row in ipairs(linesRows) do row:SetShown(not onBuffs) end
    for _, row in ipairs(favoursRows) do row:SetShown(onFavours) end
    for _, row in ipairs(buffsRows) do row:SetShown(onBuffs) end
    if onBuffs then
        ns.BuffsTab.Fill()
        return Refit(widgets.scroll, widgets.content)
    end
    ns.BuffsTab.Close()
    local above, x, y
    if onFavours then
        above, x, y = FillFavours()
    else
        above, x, y = FillMessageTab()
    end
    widgets.msgHeader:ClearAllPoints()
    widgets.msgHeader:SetPoint("TOPLEFT", above, "BOTTOMLEFT", x, y)
    -- The note on /say waiting for a key press is about thanks.
    widgets.sayNote:SetShown(onFavours)

    local cfg = ns.db[LinesType()]
    for i, edit in ipairs(widgets.edits) do
        FillBox(edit, cfg.messages[i] or "")
    end
    Refit(widgets.scroll, widgets.content)
end

local FillStart, FillGeneral, FillLedger, FillWeapon

-- A page the player can see. The game counts a shown frame with no parent
-- as visible, and our pages have none until the Settings window adopts them,
-- so IsVisible alone is true for a page nobody has opened (#267).
local function IsOpen(page)
    return page ~= nil and page:GetParent() ~= nil and page:IsVisible()
end

-- Settings changes (CVAR_UPDATE, slash commands, the minimap button) call
-- this while the panel may be closed; OnShow fills it when it opens.
function Options.Refresh()
    if IsOpen(panel) then Fill() end
    if IsOpen(startPage) then FillStart() end
    if IsOpen(generalPage) then FillGeneral() end
    if IsOpen(ledgerPage) then FillLedger() end
    if IsOpen(weaponPage) then FillWeapon() end
end

-- Fill the panel whenever it is shown, and once more on the next frame:
-- the settings window may still be laying itself out when OnShow fires.
local function OnPanelShow()
    Fill()
    C_Timer.After(0, ns.Diag.Wrap(function() Options.Refresh() end))
end

-- Show a tab: an Options.TABS name, or a favour's message type ("buff" or
-- "buffBack"), which opens the Favours tab at its lines (#491). Anything
-- else changes nothing.
function Options.SelectType(tab)
    local info, lines = Config.TYPE_INFO[tab], favourLines
    if info and info.favours then
        lines, tab = tab, Options.FAVOURS_TAB
    elseif not TAB_NAMES[tab] then
        return
    end
    -- An edit in progress saves to the lines it was typed in, before they change.
    ClearEditFocus()
    currentType, favourLines = tab, lines
    Options.Refresh()
end

-- Show one of the Favours tab's lines (#491): "buff" or "buffBack".
function Options.SelectLines(msgType)
    local info = Config.TYPE_INFO[msgType]
    if not (info and info.favours) then return end
    ClearEditFocus()
    favourLines = msgType
    Options.Refresh()
end

function Options.CurrentType()
    return currentType
end

-- Keeps a scrolling area's content as wide as its scroll frame: on a size
-- change, and on each show, now and on the next frame. The settings window
-- may lay a panel out without a size change reaching its scroll frame, and
-- a stale width would wrap or cut every line pinned to the content's right
-- (#52, #112). Its height follows its rows each time (#482).
local function FollowWidth(scroll, content)
    -- Blizzard's scroll frame code hides the bar of a frame with no range
    -- itself (ScrollFrame_OnScrollRangeChanged, SecureScrollTemplates.lua).
    scroll.scrollBarHideable = true
    scroll:SetScript("OnSizeChanged", function(_, width)
        content:SetWidth(width)
        FitHeight(scroll, content)
    end)
    local function Fit()
        local width = scroll:GetWidth()
        if width and width > 0 then content:SetWidth(width) end
        FitHeight(scroll, content)
    end
    scroll:SetScript("OnShow", function()
        Fit()
        C_Timer.After(0, ns.Diag.Wrap(Fit))
    end)
end

-- Buff mode's rows (#491: on the Buffs tab, since buff mode serves your
-- party, raid and solo buffing, not only favours): the key it lends the buff
-- button, when it turns on and off by itself, and top-up. BuffsTab.Create
-- makes them while its rows are collected, under anchor; returns the last
-- row, for what follows to hang from. Each writes the buffBack section.
function Options.CreateBuffMode(content, anchor)
    widgets.buffModeHeader = Label(content, "Buff mode", "GameFontNormal")
    widgets.buffModeHeader:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -16)
    widgets.buffModeKey = Button(content, "", 290, function() Options.StartKeyCapture() end)
    widgets.buffModeKey:SetPoint("TOPLEFT", widgets.buffModeHeader, "BOTTOMLEFT", 0, -6)
    widgets.keyCapture = CreateKeyCapture(content)

    -- When buff mode turns on and off by itself (BuffModeAuto.lua).
    widgets.auto = {}
    local function AutoBox(field)
        local cb = Checkbox(content, Options.AUTO_TEXT[field], function(on)
            BuffBack()[field] = on
            ns.BuffButton.Refresh()
        end)
        widgets.auto[field] = cb
        return cb
    end
    widgets.autoHeader = Label(content, "Buff mode turns on by itself:", "GameFontNormalSmall")
    widgets.autoHeader:SetPoint("TOPLEFT", widgets.buffModeKey, "BOTTOMLEFT", 0, -10)
    local onJoin = AutoBox("autoOnJoin")
    -- The short label leaves room on its row; the detail is on the mouse-over (#256).
    Tooltip(onJoin, Options.AUTO_JOIN_TIP)
    onJoin:SetPoint("TOPLEFT", widgets.autoHeader, "BOTTOMLEFT", -4, -2)
    local onDeath = AutoBox("autoOnDeath")
    onDeath:SetPoint("LEFT", onJoin.label, "RIGHT", 16, 0)
    local onBuffed = AutoBox("autoOnBuffed")
    onBuffed:SetPoint("LEFT", onDeath.label, "RIGHT", 16, 0)
    -- A row of its own: the three above fill theirs at 1024 x 768 (#272).
    local onMissing = AutoBox("autoOnMissing")
    Tooltip(onMissing, Options.AUTO_MISSING_TIP)
    onMissing:SetPoint("TOPLEFT", onJoin, "BOTTOMLEFT", 0, -2)
    local onCampfire = AutoBox("autoOnCampfire")
    Tooltip(onCampfire, Options.AUTO_CAMPFIRE_TIP)
    onCampfire:SetPoint("LEFT", onMissing.label, "RIGHT", 16, 0)
    widgets.autoOffHeader = Label(content, "...and off again (only when it turned itself on):", "GameFontNormalSmall")
    widgets.autoOffHeader:SetPoint("TOPLEFT", onMissing, "BOTTOMLEFT", 4, -6)
    local offPull = AutoBox("autoOffPull")
    offPull:SetPoint("TOPLEFT", widgets.autoOffHeader, "BOTTOMLEFT", -4, -2)
    local offDone = AutoBox("autoOffDone")
    offDone:SetPoint("LEFT", offPull.label, "RIGHT", 16, 0)
    local offMinutes = Stepper(content, "or after (minutes, 0 = never):", "autoOffMinutes", BuffBack)
    offMinutes.label:SetPoint("TOPLEFT", offPull, "BOTTOMLEFT", 4, -8)
    widgets.steppers.autoOffMinutes = offMinutes
    -- Top-up timing (GroupBuffs.lua, #42): renew a buff before it runs out.
    local topUp = Stepper(content, "Top up my buffs with under (minutes left, 0 = never):", "topUpMinutes", BuffBack)
    topUp.label:SetPoint("TOPLEFT", offMinutes.label, "BOTTOMLEFT", 0, -14)
    widgets.steppers.topUpMinutes = topUp
    Tooltip(topUp.box, Options.TOP_UP_TIP)

    return topUp.label
end

-- Fills buff mode's rows (BuffsTab.Fill), from the buffBack section.
function Options.FillBuffMode()
    if not widgets.keyCapture.active then widgets.buffModeKey:SetText(KeyButtonText()) end
    FillAuto()
end

-- The Favours tab's own rows (#491), below the tabs (tabsBottom): when
-- someone buffs you, returning the favour, buffs asked for and passers-by,
-- then the buff button, then its lines' sub-tabs. Passers-by
-- sits in the tab's first view at 1024 x 768 (#493). Each control writes its
-- own section (Buff or BuffBack), never the tab's.
function Options.CreateFavours(content, tabsBottom)
    -- When someone buffs you: the buff section.
    widgets.thanksHeader = Label(content, "When someone buffs you", "GameFontNormal")
    widgets.thanksHeader:SetPoint("TOPLEFT", tabsBottom, "BOTTOMLEFT", 0, -16)
    widgets.thankEnabled = Checkbox(content, "Thank them", function(on)
        Buff().enabled = on
        ns.RefreshEvents()
        ns.BuffButton.Refresh()
    end)
    widgets.thankEnabled:SetPoint("TOPLEFT", widgets.thanksHeader, "BOTTOMLEFT", -4, -2)
    local thankDelay = Stepper(content, "Delay before thanking (seconds):", "delay", Buff)
    thankDelay.label:SetPoint("LEFT", widgets.thankEnabled.label, "RIGHT", 40, 0)
    widgets.steppers.thankDelay = thankDelay
    local thankRepeat = Stepper(content, "Don't thank the same player again for (seconds):", "repeatCooldown", Buff)
    thankRepeat.label:SetPoint("TOPLEFT", widgets.thankEnabled, "BOTTOMLEFT", 4, -8)
    widgets.steppers.thankRepeat = thankRepeat

    widgets.listNames = Checkbox(content, "Name the buffs in the message", function(on)
        Buff().listBuffNames = on
    end)
    widgets.listNames:SetPoint("TOPLEFT", thankRepeat.label, "BOTTOMLEFT", -4, -6)
    -- Beside it: tell players I buff that it was me (Receipts.lua).
    widgets.receipts = Checkbox(content, "Tell players I buff that it was me", function(on)
        Buff().receipts = on
    end)
    widgets.receipts:SetPoint("LEFT", widgets.listNames.label, "RIGHT", 40, 0)

    -- Thank them with a line in /say, a whisper, a /thank emote, or a line
    -- and an emote (a dropdown, #274).
    widgets.thankStyleLabel = Label(content, "Thank them with:")
    widgets.thankStyleLabel:SetPoint("TOPLEFT", widgets.listNames, "BOTTOMLEFT", 4, -8)
    widgets.thankStyle = Dropdown(content, Options.THANK_STYLES, Options.THANK_STYLE_TEXT, 220,
        function() return ns.db.buff.thankStyle end,
        function(value)
            Buff().thankStyle = value
            Options.Refresh()
        end)
    widgets.thankStyle:SetPoint("LEFT", widgets.thankStyleLabel, "RIGHT", 10, 0)

    -- If that can't reach them (no name, or the whisper fails): a line in
    -- /say calling them the name in the box, a /thank, or nothing.
    widgets.fallbackLabel = Label(content, "If that can't reach them:")
    widgets.fallbackLabel:SetPoint("TOPLEFT", widgets.thankStyleLabel, "BOTTOMLEFT", 0, -14)
    widgets.fallback = Dropdown(content, Options.FALLBACKS, Options.FALLBACK_TEXT, 160,
        function() return ns.db.buff.fallback end,
        function(value)
            Buff().fallback = value
            Options.Refresh()
        end)
    widgets.fallback:SetPoint("LEFT", widgets.fallbackLabel, "RIGHT", 10, 0)
    widgets.unknownName = TextBox(content, 100, Config.LIMITS.unknownName.maxBytes)
    widgets.unknownName:SetPoint("LEFT", widgets.fallback, "RIGHT", 10, 0)
    widgets.unknownName:SetScript("OnTextChanged", function(self, userInput)
        if userInput then Buff().unknownName = Config.CleanUnknownName(self:GetText()) end
    end)

    -- Quiet in capital cities (Cities.lua).
    widgets.quiet = Checkbox(content, "Stay quiet in capital cities (no thank-yous; the ledger still counts)",
        function(on) Buff().quietInCities = on end)
    widgets.quiet:SetPoint("TOPLEFT", widgets.fallbackLabel, "BOTTOMLEFT", -4, -6)

    -- Return the favour: the buffBack section's switch, how long a favour
    -- is offered, and the line when your buff lands (off unless the player
    -- turns it on, #491).
    widgets.returnHeader = Label(content, "Return the favour", "GameFontNormal")
    widgets.returnHeader:SetPoint("TOPLEFT", widgets.quiet, "BOTTOMLEFT", 4, -10)
    widgets.offerEnabled = Checkbox(content, "Offer my buff back", function(on)
        BuffBack().enabled = on
        ns.RefreshEvents()
        ns.BuffButton.Refresh()
    end)
    widgets.offerEnabled:SetPoint("TOPLEFT", widgets.returnHeader, "BOTTOMLEFT", -4, -2)
    Tooltip(widgets.offerEnabled, "When someone outside your group buffs you, the buff button offers to buff "
        .. "them back. It casts only when you press it.")
    local owedMinutes = Stepper(content, "Offer for (minutes):", "owedMinutes", BuffBack)
    owedMinutes.label:SetPoint("LEFT", widgets.offerEnabled.label, "RIGHT", 40, 0)
    widgets.steppers.owedMinutes = owedMinutes
    widgets.sayLine = Checkbox(content, "Say a line when my buff lands", function(on)
        BuffBack().sayLine = on
        ns.BuffButton.Refresh()
    end)
    widgets.sayLine:SetPoint("TOPLEFT", widgets.offerEnabled, "BOTTOMLEFT", 0, -2)
    Tooltip(widgets.sayLine, "Off: your thank-you is the one line said for the favour. On: a line from \"When my "
        .. "buff lands\" (below) is said too, once your buff reaches them.")

    -- Asked and passing by: buff requests in chat (Requests.lua, #40) and
    -- passers-by (#39), off the Buff Back and Buffs tabs (#491).
    widgets.askedHeader = Label(content, "Asked and passing by", "GameFontNormal")
    widgets.askedHeader:SetPoint("TOPLEFT", widgets.sayLine, "BOTTOMLEFT", 4, -10)
    widgets.buffRequests = Checkbox(content, ns.Requests.LABEL, function(on) ns.Requests.SetEnabled(on) end)
    widgets.buffRequests:SetPoint("TOPLEFT", widgets.askedHeader, "BOTTOMLEFT", -4, -2)
    Tooltip(widgets.buffRequests, ns.Requests.TOOLTIP)
    widgets.passersBy = Checkbox(content, "Also offer my buffs to passers-by in buff mode", function(on)
        BuffBack().passersBy = on
        ns.BuffButton.Refresh()
    end)
    widgets.passersBy:SetPoint("TOPLEFT", widgets.buffRequests, "BOTTOMLEFT", 0, -2)
    Tooltip(widgets.passersBy, Options.PASSERS_BY_TIP)
    -- Pinned on both sides, so it wraps inside the page at any width.
    widgets.passersByHelp = Label(content, Options.PASSERS_BY_HELP, "GameFontHighlightSmall")
    widgets.passersByHelp:SetPoint("TOPLEFT", widgets.passersBy, "BOTTOMLEFT", 4, -2)
    widgets.passersByHelp:SetPoint("RIGHT", content, "RIGHT", -24, 0)
    widgets.passersByHelp:SetWordWrap(true)
    -- A warning and a one-click fix when friendly nameplates are off (Fill).
    widgets.nameplateWarning = Label(content, ns.Colours.Text("warn", Options.NAMEPLATES_OFF), "GameFontHighlightSmall")
    widgets.nameplateWarning:SetPoint("TOPLEFT", widgets.passersByHelp, "BOTTOMLEFT", 0, -6)
    widgets.nameplateWarning:SetPoint("RIGHT", content, "RIGHT", -24, 0)
    widgets.nameplateWarning:SetWordWrap(true)
    widgets.nameplateButton = Button(content, "Show friendly player names", 200, function()
        local ok, reason = ns.Nameplates.EnableFriendlyNames()
        ns.Print(ok and "friendly player names are now shown (names only)." or ("couldn't turn them on: " .. reason))
        Options.Refresh()
    end)
    widgets.nameplateButton:SetPoint("TOPLEFT", widgets.nameplateWarning, "BOTTOMLEFT", 0, -6)

    -- The buff button: the buffBack section's other rows for returning
    -- favours, below the first view (anchored in Fill, under the nameplate
    -- warning when it shows).
    widgets.buttonHeader = Label(content, "The buff button", "GameFontNormal")
    widgets.showInCities = Checkbox(content, "Show the button in capital cities (buff mode always shows it)",
        function(on)
            BuffBack().showInCities = on
            ns.BuffButton.Refresh()
        end)
    widgets.showInCities:SetPoint("TOPLEFT", widgets.buttonHeader, "BOTTOMLEFT", -4, -2)
    -- Renewing your buff they already wear, partly worn off (Offers.lua, #269).
    local renew = Stepper(content, "Renew my buff when theirs has under (% left, 0 = never):", "renewPercent",
        BuffBack, nil, 5)
    renew.label:SetPoint("TOPLEFT", widgets.showInCities, "BOTTOMLEFT", 4, -8)
    widgets.steppers.renewPercent = renew

    -- Who gets each buff, the order, Never offer and buff mode are on the
    -- Buffs tab (#408, #491).
    widgets.buffsLink = Label(content, "Who gets which buff, the buff order, Never offer and buff mode are on "
        .. "the Buffs tab.", "GameFontNormalSmall")
    widgets.buffsLink:SetPoint("TOPLEFT", renew.label, "BOTTOMLEFT", 0, -14)
    widgets.openBuffs = Button(content, "Open the Buffs tab", 150, function() Options.SelectType(Options.BUFFS_TAB) end)
    widgets.openBuffs:SetPoint("TOPLEFT", widgets.buffsLink, "BOTTOMLEFT", 0, -6)

    -- The lines: a sub-tab for the thank-you lines and one for the line
    -- when your buff lands. The lines' own rows follow (Fill).
    widgets.linesHeader = Label(content, "Lines", "GameFontNormal")
    widgets.linesHeader:SetPoint("TOPLEFT", widgets.openBuffs, "BOTTOMLEFT", 0, -16)
    widgets.linesTabs = {}
    local prev
    for _, msgType in ipairs(Options.FAVOUR_LINES) do
        local tab = Button(content, Config.TYPE_INFO[msgType].linesLabel, 150, function()
            Options.SelectLines(msgType)
        end)
        if prev then
            tab:SetPoint("LEFT", prev, "RIGHT", 6, 0)
        else
            tab:SetPoint("TOPLEFT", widgets.linesHeader, "BOTTOMLEFT", 0, -6)
        end
        widgets.linesTabs[msgType] = tab
        prev = tab
    end
    widgets.linesHelp = Label(content, "", "GameFontHighlightSmall")
    widgets.linesHelp:SetPoint("TOPLEFT", widgets.linesTabs[Options.FAVOUR_LINES[1]], "BOTTOMLEFT", 0, -8)
    widgets.linesHelp:SetPoint("RIGHT", content, "RIGHT", -24, 0)
    widgets.linesHelp:SetWordWrap(true)
end

function Options.Create()
    if panel then return end
    panel = CreateFrame("Frame", "FriendlyForeverOptionsPanel")
    panel.name = ns.TITLE
    -- Hidden until the Settings window shows it: a frame created shown fires
    -- no OnShow when the window takes it in, and counts as visible with no
    -- parent (#267).
    panel:Hide()

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

    widgets.master = Checkbox(content, "Addon enabled", function(on)
        -- The events and the button then follow every section's switch:
        -- never a damaged section's (#330).
        for _, msgType in ipairs(Config.TYPES) do Config.Section(msgType) end
        ns.SetEnabled(on)
    end)
    widgets.master:SetPoint("TOPRIGHT", -150, -10)
    -- On the master switch's row; its label ends just left of that switch,
    -- however wide the font makes it.
    widgets.skipAFK = Checkbox(content, "Don't send messages while I'm AFK", function(on) ns.db.skipWhileAFK = on end)
    local labelWidth = widgets.skipAFK.label:GetStringWidth() or 0
    widgets.skipAFK:SetPoint("RIGHT", widgets.master, "LEFT", -(labelWidth + 16), 0)

    -- Tabs wrap after Options.TABS_PER_ROW, so eight of them still fit the
    -- panel's width (#273): two rows since Favours took the place of two
    -- (#491). The header hangs from the last row.
    local prev, rowStart
    for i, tabName in ipairs(Options.TABS) do
        local text = Options.TAB_TEXT[tabName] or Config.TYPE_INFO[tabName].label
        local tab = Button(content, text, 84, function() Options.SelectType(tabName) end)
        if i == 1 then
            tab:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -14)
            rowStart = tab
        elseif (i - 1) % Options.TABS_PER_ROW == 0 then
            tab:SetPoint("TOPLEFT", rowStart, "BOTTOMLEFT", 0, -4)
            rowStart = tab
        else
            tab:SetPoint("LEFT", prev, "RIGHT", 6, 0)
        end
        widgets.tabs[tabName] = tab
        prev = tab
    end
    -- Everything below the tabs: a message type's rows, the Favours tab's
    -- or the Buffs tab's (BuffsTab.lua), each noted in its list, and the
    -- lines, which a message tab and Favours show.
    Options.Collect(buffsRows, content)
    ns.BuffsTab.Create(content, rowStart)
    Options.Collect(favoursRows, content)
    Options.CreateFavours(content, rowStart)
    Options.Collect(typeRows, content)

    widgets.header = Label(content, "", "GameFontNormal")
    widgets.header:SetPoint("TOPLEFT", rowStart, "BOTTOMLEFT", 0, -16)
    -- Wraps at the panel's right edge, should a tab's help run wider than
    -- the panel (#112). The rows below hang from it, so they move down.
    widgets.help = Label(content, "", "GameFontHighlightSmall")
    widgets.help:SetPoint("TOPLEFT", widgets.header, "BOTTOMLEFT", 0, -4)
    widgets.help:SetPoint("RIGHT", content, "RIGHT", -24, 0)
    widgets.help:SetWordWrap(true)

    -- Row 1: enabled, delay
    widgets.enabled = Checkbox(content, "Enabled", function(on)
        Current().enabled = on
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
    widgets.greetersHelp = Label(content, "Everyone with the addon greets a guildmate who logs in, 15 seconds "
        .. "after they come online by default and a few seconds apart and "
        .. "with different lines, up to this many. Copies that can't reach the others "
        .. "(inside an instance, say) greet anyway.", "GameFontHighlightSmall")
    widgets.greetersHelp:SetPoint("TOPLEFT", maxGreeters.label, "BOTTOMLEFT", 0, -10)
    widgets.greetersHelp:SetPoint("RIGHT", content, "RIGHT", -24, 0)
    widgets.greetersHelp:SetWordWrap(true)

    -- The lines: a message tab's, or the Favours tab's sub-tab's. Anchored in Fill.
    Options.Collect(linesRows, content)
    local msgHeader = Label(content,
        "Messages (all are used in random order before any repeats; leave a line blank to skip it):",
        "GameFontNormalSmall")
    widgets.msgHeader = msgHeader

    -- Hovering a line shows what it can say for your character (#441): up to
    -- 3 examples from the real renderer, each flavour placeholder's phrases and
    -- what {zone}, {timeofday} and {myclass} read now. It only reads the box's
    -- text: nothing is saved, nothing goes to chat, the shuffle bag and the
    -- real flavour choices are left alone (Flavour.Preview).
    local function MessageTip(box)
        GameTooltip:SetOwner(box, "ANCHOR_RIGHT")
        local ok, preview = pcall(function()
            local msgType = LinesType()
            local vars = Config.NameVars(msgType, Options.SAMPLE_NAME)
            vars.buff = Options.SAMPLE_BUFF
            return ns.Flavour.Preview(box:GetText(), vars, Options.PreviewContext(msgType),
                Options.PREVIEW_EXAMPLES)
        end)
        local function Line(colour, text)
            local r, g, b = ns.Colours.RGB(colour)
            GameTooltip:AddLine(text, r, g, b, true)
        end
        if not ok then
            Line("muted", "No preview for this line.")
        elseif preview.empty then
            Line("muted", "Empty: this line is skipped.")
        else
            Line("title", #preview.examples > 1 and "What it can say for you:" or "What it says for you:")
            for _, said in ipairs(preview.examples) do Line("text", said) end
            for _, pool in ipairs(preview.pools) do
                local shown = {}
                for n = 1, math.min(#pool.phrases, Options.PREVIEW_POOL_MAX) do shown[n] = pool.phrases[n] end
                local more = #pool.phrases - #shown
                Line("title", "{" .. pool.key .. "} can be:")
                if more > 0 then shown[#shown + 1] = "... and " .. more .. " more" end
                -- Broken into lines of about PREVIEW_WIDTH letters here, so a long pool
                -- stays inside the screen whether or not the game wraps the tooltip.
                local row = ""
                for n, phrase in ipairs(shown) do
                    local piece = phrase .. (n < #shown and " /" or "")
                    if row ~= "" and #row + 1 + #piece > Options.PREVIEW_WIDTH then
                        Line("text", row)
                        row = piece
                    else
                        row = row == "" and piece or (row .. " " .. piece)
                    end
                end
                if row ~= "" then Line("text", row) end
            end
            for _, now in ipairs(preview.now) do
                if now.theirs then
                    Line("muted", Options.GUILD_ZONE_NOTE:format(now.value))
                else
                    Line("muted", "{" .. now.key .. "} now reads: " .. now.value)
                end
            end
        end
        GameTooltip:Show()
    end

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
            -- Saved to the lines shown: a message tab's, or the Favours sub-tab's (#491).
            local msgType = LinesType()
            if userInput and msgType then Config.Field(msgType, "messages")[i] = Config.CleanMessage(self:GetText()) end
        end)
        edit:SetScript("OnEnter", MessageTip)
        edit:SetScript("OnLeave", function() GameTooltip:Hide() end)
        widgets.edits[i] = edit
        anchor = num
    end

    widgets.preview = Button(content, "Preview random", 130, function()
        local msgType = LinesType()
        if not msgType then return end
        local template = ns.Messages.Preview(Config.Field(msgType, "messages"))
        local vars = ns.Config.NameVars(msgType, ns.Util.UnitFullName("player") or "Nikki-Shifts")
        vars.buff = "Power Word: Fortitude and Arcane Intellect"
        local text = template and ns.Util.Render(template, ns.Flavour.Vars(vars, Options.PreviewContext(msgType)))
        ns.Print(text or "(no messages)")
    end)
    widgets.preview:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -16)

    -- On Favours it resets both its sections (#491), as Reset on the Buff
    -- Thanks and Buff Back tabs did, each keeping what Core.lua's ns.ResetType keeps.
    widgets.reset = Button(content, "Reset this tab to defaults", 190, function()
        ClearEditFocus()
        local types = currentType == Options.FAVOURS_TAB and Options.FAVOUR_LINES or { MessageTab() }
        for _, msgType in ipairs(types) do
            Config.Section(msgType) -- a damaged section is healed first: the reset keeps its local-only fields
            ns.ResetType(msgType)
        end
        Options.Refresh()
    end)
    widgets.reset:SetPoint("LEFT", widgets.preview, "RIGHT", 10, 0)

    -- Swap only the 30 lines shown (a message tab's, or the Favours
    -- sub-tab's) for a shipped set.
    local function LoadLines(set)
        ClearEditFocus()
        local msgType = LinesType()
        if not msgType then return end
        local lines = {}
        for i, line in ipairs(set[msgType]) do lines[i] = line end
        Config.Section(msgType).messages = lines
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

    -- Favours only (Fill): thanks and the line when your buff lands.
    local note = Label(content, "Lines in /say: the game only allows /say after a key press, so they wait "
        .. "and go out on your next key press or buff button press (or type /friendly say). "
        .. "Whispers need no key press. "
        .. "A /thank emote needs no key press and goes out at once.",
        "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", flavour, "BOTTOMLEFT", 0, -10)
    note:SetPoint("RIGHT", content, "RIGHT", -24, 0)
    note:SetWordWrap(true)
    widgets.sayNote = note
    Options.Collect(nil)

    panel:SetScript("OnShow", OnPanelShow)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        category = Settings.RegisterCanvasLayoutCategory(panel, ns.TITLE)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end

    -- Start here first, so it's the first page listed under Friendly Forever.
    Options.CreateStartPage()
    Options.CreateGeneralPage()
    Options.CreateLedgerPage()
    Options.CreateWeaponPage()
    ns.OptionsIndex.RegisterSearch(category)

    -- Filled straight away too, so nothing can ever show empty boxes.
    Fill()
end

-- A page listed under Friendly Forever in the AddOns options.
local function SubPage(name, title, frameName)
    local page = CreateFrame("Frame", frameName)
    page.name = name
    page.parent = ns.TITLE
    page:Hide() -- as the main panel (#267)
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

-- The binding in Key Bindings > AddOns that presses the buff button.
Options.BUTTON_BINDING = "CLICK FriendlyForeverBuffButton:LeftButton"

-- Start here (#47): an introduction. What the addon does, the settings that
-- apply and the keys, shown as they're saved, a link to every other page
-- and the walkthrough. It changes no setting: each is changed on its own
-- page (the owner's decision on #47).
function Options.CreateStartPage()
    local w = widgets.start
    startPage = SubPage("Start here", "Start here", Options.START_PAGE)
    local page = startPage
    -- Everything below the heading scrolls (#46's rule: content that can
    -- grow scrolls rather than overflowing).
    local area = ScrollArea(page, Options.START_HEIGHT)

    local about = Label(area, "What it does", "GameFontNormal")
    about:SetPoint("TOPLEFT", 16, -12)
    w.about = Note(area, about, "Greets guildmates who log in, welcomes new guild and party members, and thanks "
        .. "people who buff you. When someone outside your group buffs you, a button offers to buff them back; "
        .. "it casts only when you press it.")

    local now = Section(area, w.about, "Your settings")
    w.enabled = Note(area, now, "")
    w.thanks = Note(area, w.enabled, "")
    w.nameplates = Note(area, w.thanks, "")
    w.buttonKey = Note(area, w.nameplates, "")
    w.buffModeKey = Note(area, w.buttonKey, "")
    -- How to turn buff mode on by hand (#458), and where the passers-by
    -- switch is (#455); the link opens it on the Favours tab (#491).
    w.buffModeSwitch = Note(area, w.buffModeKey, "Turn buff mode on or off by hand: shift-click the minimap button "
        .. "(its tooltip shows whether it's on), or type /friendly buffmode. Right-click on the minimap button "
        .. "turns the whole addon on or off.")
    w.passersByNote = Note(area, w.buffModeSwitch, "")
    w.openPassersBy = Button(area, "Passers-by switch (Favours tab)", 230, function()
        Options.OpenTab(Options.FAVOURS_TAB, "passersBy")
    end)
    w.openPassersBy:SetPoint("TOPLEFT", w.passersByNote, "BOTTOMLEFT", 0, -6)
    w.change = Note(area, w.openPassersBy, ns.Colours.Text("muted", "Each is changed on its own page, below."))

    local more = Section(area, w.change, "Every other page")
    w.openMessages = Button(area, "Messages and Favours", 180, function() Options.Open() end)
    w.openMessages:SetPoint("TOPLEFT", more, "BOTTOMLEFT", 0, -8)
    w.openGeneral = Button(area, "General", 100, function() Options.OpenPage(generalPage) end)
    w.openGeneral:SetPoint("LEFT", w.openMessages, "RIGHT", 8, 0)
    w.openLedger = Button(area, "Favour Ledger", 120, function() Options.OpenPage(ledgerPage) end)
    w.openLedger:SetPoint("LEFT", w.openGeneral, "RIGHT", 8, 0)

    local tour = Section(area, w.openMessages, "The walkthrough")
    w.tour = Button(area, "Take the walkthrough", 180, function() ns.Walkthrough.Start() end)
    w.tour:SetPoint("TOPLEFT", tour, "BOTTOMLEFT", 0, -8)
    w.tourHelp = Note(area, w.tour, "A step at a time through your buffs, buff mode, favours and the welcome "
        .. "lines, opening each page. It only shows and explains; it never changes a setting.")

    page:SetScript("OnShow", function() FillStart() end)
    page.widgets = w
    panel.startPage = page
end

-- The buff button's key in Key Bindings > AddOns, as the game names
-- it, or nil when it has none.
local function ButtonKeyText()
    local key = ns.Util.ReadGameValues(GetBindingKey, Options.BUTTON_BINDING)
    if type(key) ~= "string" or key == "" then return nil end
    return ns.BuffMode.KeyText(key)
end

-- Fills Start here from the saved settings, read through damage: a section
-- that isn't a table reads as empty.
FillStart = function()
    local w = widgets.start
    local buff = type(ns.db.buff) == "table" and ns.db.buff or {}
    w.enabled:SetText(ns.db.enabled == true and "Friendly Forever is on."
        or ns.Colours.Text("warn", "Friendly Forever is off.")
            .. " Its switch is at the top of Messages and Favours.")
    w.thanks:SetText(buff.enabled == true
        and ("Thanks are on (Favours tab): you thank people who buff you with "
            .. (Options.THANK_STYLE_TEXT[buff.thankStyle] or Options.THANK_STYLE_TEXT.message) .. ".")
        or "Thanks are off (Favours tab): people who buff you aren't thanked.")
    w.nameplates:SetText(ns.Nameplates.FriendlyShown() == false
        and ns.Colours.Text("warn", "Friendly player nameplates are off,")
            .. " so the game can rarely tell you who buffed you. The Favours tab can show them."
        or "Friendly player nameplates are on, so the game can tell you who buffed you.")
    local buttonKey = ButtonKeyText()
    w.buttonKey:SetText(buttonKey and ("Buff button key: " .. buttonKey .. " (Key Bindings > AddOns).")
        or "Buff button key: none yet. Set one in Key Bindings > AddOns, or click the button.")
    local buffBack = type(ns.db.buffBack) == "table" and ns.db.buffBack or {}
    w.passersByNote:SetText("Buff mode also offers your buffs to players nearby who aren't in your group: "
        .. (buffBack.passersBy == true and "passers-by is on." or "passers-by is off until you turn it on."))
    w.buffModeKey:SetText("Buff mode key: " .. ns.BuffMode.KeyText((ns.BuffMode.Key()))
        .. ". Buff mode lends it to the buff button to buff a group quickly (the Buffs tab).")
    Refit(startPage.scroll, startPage.content)
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
    Refit(generalPage.scroll, generalPage.content)
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
    w.note = Note(page, w.clear, "Buffs from players outside your group, while thanking or offering your buff "
        .. "back is on (Favours tab). The newest " .. ns.Ledger.MAX_ENTRIES
        .. " are kept; /friendly ledger shows them in chat.")
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
function Options.Pages() return generalPage, ledgerPage, weaponPage end
function Options.StartPage() return startPage end
function Options.FillStart() FillStart() end

function Options.Open()
    if category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(category:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end

-- Opens one of the pages under Friendly Forever (Start here, General or
-- Favour Ledger), as clicking it in the AddOns options would.
function Options.OpenPage(page)
    if page.category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(page.category:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(page)
    end
end

function Options.OpenStart() Options.OpenPage(startPage) end

-- Scrolls the main panel so region (one of its rows) is near the top, or to
-- the top without one. Edges the game can't give yet leave it at the top.
local function ScrollTo(region)
    local scroll = widgets.scroll
    local top, at = widgets.content:GetTop(), region and region:GetTop()
    local offset = 0
    if type(top) == "number" and type(at) == "number" then offset = math.max(0, top - at - 12) end
    local range = scroll:GetVerticalScrollRange()
    offset = math.min(offset, type(range) == "number" and range or 0)
    scroll:SetVerticalScroll(offset)
end

-- Opens the main panel at a tab (as Options.SelectType takes it), scrolled
-- to its row called row (a key of Options.widgets), for the walkthrough
-- (Walkthrough.lua) and Start here. Scrolled again on the next frame, once
-- the panel has laid the tab's rows out.
function Options.OpenTab(tab, row)
    Options.Open()
    Options.SelectType(tab)
    ScrollTo(widgets[row])
    C_Timer.After(0, ns.Diag.Wrap(function() ScrollTo(widgets[row]) end))
end

------------------------------------------------------------------------
-- Weapon buffs (#45): its own small page, experimental, off by default.
------------------------------------------------------------------------

Options.WEAPON_HELP = "Experimental. In buff mode, once your favours, your group and your self-buffs are done, "
    .. "the button offers the kind you choose for a hand that has none on it: the best one you carry and can "
    .. "use. One press puts it on. Nothing is ever put on by itself. Right-click skips your weapon buffs for "
    .. "5 minutes."
Options.WEAPON_KIND_TEXT = { none = "nothing" }

-- The hand's chosen kind, read from a section that may be damaged (#330).
local function WeaponKind(field)
    return Config.Field("buffBack", field)
end

-- A dropdown of the kinds your class may use on a hand (all of them when
-- your class can't be read).
local function WeaponDropdown(parent, slot, field)
    local _, class = ns.Util.ReadGameValues(UnitClass, "player")
    local order = { "none" }
    local texts = { none = Options.WEAPON_KIND_TEXT.none }
    for _, key in ipairs(ns.WeaponBuffs.KindsFor(type(class) == "string" and class or nil, slot)) do
        order[#order + 1] = key
        texts[key] = ns.WeaponBuffs.KINDS[key].label
    end
    -- Without a class every class's kinds are listed; a dropdown always
    -- shows the current choice, even one the list doesn't hold.
    for _, key in ipairs(Config.WEAPON_KINDS) do
        if not texts[key] then texts[key] = ns.WeaponBuffs.KINDS[key].label end
    end
    return Dropdown(parent, order, texts, 200, function() return WeaponKind(field) end, function(value)
        BuffBack()[field] = value
        Options.Refresh()
        ns.BuffButton.Refresh()
    end)
end

function Options.CreateWeaponPage()
    local w = widgets.weapon
    weaponPage = SubPage("Weapon buffs", "Weapon buffs (experimental)", Options.WEAPON_PAGE)
    local page = weaponPage
    w.help = Note(page, page.heading, Options.WEAPON_HELP)
    w.enabled = Checkbox(page, "Offer weapon buffs in buff mode, after my self-buffs", function(on)
        BuffBack().weaponBuffs = on
        Options.Refresh()
        ns.BuffButton.Refresh()
    end)
    w.enabled:SetPoint("TOPLEFT", w.help, "BOTTOMLEFT", -4, -10)
    w.mainLabel = Label(page, "Main hand:")
    w.mainLabel:SetPoint("TOPLEFT", w.enabled, "BOTTOMLEFT", 4, -16)
    w.main = WeaponDropdown(page, 16, "weaponMain")
    w.main:SetPoint("LEFT", w.mainLabel, "LEFT", 80, 0)
    w.offLabel = Label(page, "Off hand:")
    w.offLabel:SetPoint("TOPLEFT", w.mainLabel, "BOTTOMLEFT", 0, -18)
    w.off = WeaponDropdown(page, 17, "weaponOff")
    w.off:SetPoint("LEFT", w.offLabel, "LEFT", 80, 0)
    w.note = Note(page, w.offLabel, "Stones and oils for anyone, poisons for rogues, a shaman's imbues for the "
        .. "main hand. A hand whose weapon has its own Use is left for you to do by hand. In a druid's form or "
        .. "Ghost Wolf, a press may drop you out of the form to put it on, as doing it by hand would.")
    page:SetScript("OnShow", function() FillWeapon() end)
end

FillWeapon = function()
    local w = widgets.weapon
    w.enabled:SetChecked(Config.Field("buffBack", "weaponBuffs") == true)
    w.main.Fill()
    w.off.Fill()
end
