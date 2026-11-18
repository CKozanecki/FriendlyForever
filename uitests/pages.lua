-- The phase 1 pages (#52): the options' General and Favour Ledger pages,
-- filled the way a long-time player's would be, for the scenarios
-- (scenarios.lua) to check and the screenshot job to show. The screenshot
-- job runs this file, then FriendlyForeverUIPages.Show("<page>"), through
-- --exec-lua. So this file only defines things, and calls no test().
--
-- The main panel's tabs (#112) too: FriendlyForeverUIPages.ShowTab("<tab>")
-- opens the panel and clicks that tab's button, as a player would. The Buff
-- Back tab's buffs carry their Forever names, which the simulator has itself
-- (UnnamedBuff checks it does, #158, #160).
--
-- The simulator loads the test files in name order, so this one comes before
-- scenarios.lua and FriendlyForeverUIPages is there when they run.
--
-- The fill is a worst case a player could reach: names as long as WoW
-- Forever allows (a first name and a surname of up to 12 letters each), more
-- ignored names and profiles than the General page lists, and a full
-- page of ledger entries with long buff names and notes. Fill's undo puts
-- back everything it changed.

local Pages = {}
FriendlyForeverUIPages = Pages

-- Every action the client blocks or forbids an addon while this file is
-- loaded, as "<event> <addon> <action>": in order, and counted (#160). The
-- simulator's Forever profile prints "Interface action failed because of an
-- AddOn" in chat in the shots that open the main panel, and nothing said
-- who it blamed for what. Each new one is printed as it happens, so a shot's
-- own log has it too (the screenshot job runs this file, not the
-- scenarios); the scenarios' last test lists them all.
Pages.blocked = { order = {}, count = {} }
if type(CreateFrame) == "function" then
    pcall(function()
        local say = type(A_Print) == "function" and A_Print or print
        local watcher = CreateFrame("Frame")
        watcher:RegisterEvent("ADDON_ACTION_BLOCKED")
        watcher:RegisterEvent("ADDON_ACTION_FORBIDDEN")
        watcher:SetScript("OnEvent", function(_, event, addon, action)
            local what = ("%s %s %s"):format(tostring(event), tostring(addon), tostring(action))
            local blocked = Pages.blocked
            if not blocked.count[what] then
                blocked.order[#blocked.order + 1] = what
                say("FACT sim blocked action, as it happens: " .. what)
            end
            blocked.count[what] = (blocked.count[what] or 0) + 1
        end)
    end)
end

-- That chat line has a second source, which fires no event: Blizzard's own
-- DisplayInterfaceActionBlockedMessage, which its panel and gamepad
-- navigation code call directly (Blizzard_UIParentPanelManager and
-- Blizzard_GamepadSmartNavigation at 1.60.1.70707). So its first call after
-- this file loads is printed with the lines that called it, and kept in
-- Pages.blockedMessage for the scenarios' last test (#160). The client's
-- function is put back before it runs, so it is called exactly as it was.
Pages.blockedMessage = {}
if type(_G.DisplayInterfaceActionBlockedMessage) == "function" then
    local original = _G.DisplayInterfaceActionBlockedMessage
    _G.DisplayInterfaceActionBlockedMessage = function(...)
        _G.DisplayInterfaceActionBlockedMessage = original
        local say = type(A_Print) == "function" and A_Print or print
        local ok, stack = pcall(function() return _G.debugstack(2, 12, 0) end)
        if not ok or type(stack) ~= "string" or stack == "" then stack = "(the client gave no call stack)" end
        for line in stack:gmatch("[^\r\n]+") do
            Pages.blockedMessage[#Pages.blockedMessage + 1] = line
            say("FACT sim the blocked-action chat line, called from: " .. line)
        end
        return original(...)
    end
end

-- The frames' names (Options.GENERAL_PAGE, Options.LEDGER_PAGE,
-- Options.WEAPON_PAGE, Options.START_PAGE, Window.NAME and Walkthrough.NAME).
Pages.GENERAL = "FriendlyForeverGeneralPage"
Pages.LEDGER = "FriendlyForeverLedgerPage"
Pages.WEAPON = "FriendlyForeverWeaponPage" -- weapon buffs (#45)
Pages.START = "FriendlyForeverStartPage"
Pages.WINDOW = "FriendlyForeverTextWindow"
Pages.WALKTHROUGH = "FriendlyForeverWalkthrough"

-- The simulator starts with no saved settings, a new install: the addon is
-- off and its walkthrough open (#47). Every page and tab shown here skips it
-- first, by its Skip button, as a player would, which turns the addon on.
function Pages.SkipWalkthrough()
    local walkthrough = _G[Pages.WALKTHROUGH]
    if type(walkthrough) == "table" and walkthrough:IsShown() then walkthrough.skip:Click() end
end

-- Twelve-letter first names and surnames, as long as Forever names get.
local FIRSTS = { "Aerendhiliel", "Brannoctavus", "Caelithrandr", "Dorvanimbrel", "Elowyndraeth", "Faelandoriel",
    "Galdrenthory", "Halvardinsen", "Isolwendrith", "Jorundmikael", "Kaelthandrys", "Lorenthaliel",
    "Maelistrandr", "Nyssandoriel" }
local SURNAMES = { "Stormwhisper", "Thunderfoots", "Moonshadower", "Brightbanner" }

local function FullName(i)
    return FIRSTS[(i - 1) % #FIRSTS + 1] .. "-" .. SURNAMES[(i - 1) % #SURNAMES + 1]
end

-- A caster's buffs, as one caster can give them at once.
local BUFFS = {
    { "Power Word: Fortitude", "Divine Spirit", "Shadow Protection" },
    { "Mark of the Wild", "Thorns" },
    { "Blessing of Wisdom", "Blessing of Might" },
    { "Arcane Intellect", "Dampen Magic" },
}
-- What happened to each favour, with the longest notes the ledger writes.
local RESULTS = {
    { result = "thanked", returned = "Power Word: Fortitude" },
    { result = "not thanked", note = "too many messages waiting", returnNote = "the time to return it ran out" },
    { result = "thanked", returnNote = "it answered your buff to them" },
    { result = "not thanked", note = "no key press in time", returnNote = "you let it go" },
}

-- How many ignored names (Options.IGNORE_SHOWN lists 12, then counts the
-- rest) and ledger entries (Options.LEDGER_ROWS rows show) to fill in.
Pages.IGNORED = 14
Pages.ENTRIES = 25
Pages.PROFILES = 9 -- Options.PROFILES_SHOWN lists 6

local function Today()
    return type(date) == "function" and date("%Y-%m-%d") or ""
end

-- Fills the saved settings the pages show. Returns a function that puts
-- them back.
function Pages.Fill()
    local db = FriendlyForeverDB
    local saved = { ignore = db.ignore, profiles = db.profiles, activeProfile = db.activeProfile, ledger = db.ledger }
    -- Weapon buffs (#45): switched on, with a kind chosen for each hand.
    local weapon = { weaponBuffs = db.buffBack.weaponBuffs, weaponMain = db.buffBack.weaponMain,
        weaponOff = db.buffBack.weaponOff }
    db.buffBack.weaponBuffs, db.buffBack.weaponMain, db.buffBack.weaponOff = true, "wizardOil", "sharpening"

    local ignore = {}
    for i = 1, Pages.IGNORED do
        local full = FullName(i)
        ignore[full:lower()] = full
    end
    db.ignore = ignore

    -- More profiles than the page lists (Options.PROFILES_SHOWN), with names
    -- as long as they get (Profiles.MAX_NAME, 32 letters).
    local profiles = {}
    for i = 1, Pages.PROFILES do
        profiles[string.format("Raid nights in Naxxramas, team %d", i)] = {}
    end
    db.profiles = profiles
    db.activeProfile = "Raid nights in Naxxramas, team 1"

    local now = type(time) == "function" and time() or 0
    local entries = {}
    for i = 1, Pages.ENTRIES do
        local outcome = RESULTS[(i - 1) % #RESULTS + 1]
        local buffs = {}
        for _, b in ipairs(BUFFS[(i - 1) % #BUFFS + 1]) do buffs[#buffs + 1] = b end
        entries[i] = { t = now - (Pages.ENTRIES - i) * 3700, who = FullName(i + 3), buffs = buffs,
            result = outcome.result, note = outcome.note, returned = outcome.returned, returnNote = outcome.returnNote }
    end
    db.ledger = {
        entries = entries,
        totals = { received = 12345, thanked = 11873, returned = 10982 },
        today = { day = Today(), received = 142, thanked = 139, returned = 128 },
    }

    return function()
        for key, value in pairs(saved) do db[key] = value end
        for key, value in pairs(weapon) do db.buffBack[key] = value end
    end
end

-- Opens one of the options pages ("general", "ledger", "weapon" or "start") as
-- clicking it in the AddOns options would. Returns the page.
local PAGE_FRAMES = { general = Pages.GENERAL, ledger = Pages.LEDGER, weapon = Pages.WEAPON, start = Pages.START }
function Pages.Open(which)
    local page = _G[PAGE_FRAMES[which] or Pages.GENERAL]
    if type(page) ~= "table" then error("no options page called " .. tostring(which), 2) end
    Pages.SkipWalkthrough()
    -- A page fills itself when shown. One an earlier scenario left open is
    -- hidden first, so it shows, and fills, afresh from what Fill set.
    if page:IsShown() then page:Hide() end
    Settings.OpenToCategory(page.category:GetID())
    if not page:IsShown() then page:Show() end
    return page
end

-- For the screenshot job: fill the pages, then show one.
function Pages.Show(which)
    Pages.Fill()
    Pages.Open(which)
end

-- The main panel's tabs (#112), in the panel's order (Config.TYPES): the
-- name each screenshot and LAYOUT line goes by, and the text on its button.
-- spec/uitests_pages_spec.lua checks this list against Config.TYPE_INFO, so
-- a new tab can't go without its shot.
Pages.TABS = {
    { name = "guild-login", label = "Guild Login" },
    { name = "buff-thanks", label = "Buff Thanks" },
    { name = "guild-join", label = "Guild Join" },
    { name = "party-join", label = "Party Join" },
    { name = "party-hello", label = "Party Hello" },
    { name = "hello-again", label = "Hello Again" },
    { name = "level-up", label = "Level Up" },
    { name = "buff-back", label = "Buff Back" },
}
Pages.PANEL = "FriendlyForeverOptionsPanel"

local report = type(A_Print) == "function" and A_Print or print

-- The tab called name, or nothing and why not. Only a name from Pages.TABS
-- is known: anything else, of any type, gets the list of names.
local function FindTab(name)
    for _, tab in ipairs(Pages.TABS) do
        if tab.name == name then return tab end
    end
    local names = {}
    for i, tab in ipairs(Pages.TABS) do names[i] = tab.name end
    return nil, ("no options tab called %s; the tabs are %s"):format(tostring(name), table.concat(names, ", "))
end

-- The button under frame (the panel, its scroll frame and its content)
-- whose text is label, if any.
local function FindButton(frame, label, depth)
    for _, child in ipairs({ frame:GetChildren() }) do
        if child:GetObjectType() == "Button" and child.GetText and child:GetText() == label then return child end
        if depth > 1 then
            local found = FindButton(child, label, depth - 1)
            if found then return found end
        end
    end
end

-- Opens the options panel at the tab called name (a Pages.TABS name), by
-- clicking that tab's button, as a player would. Returns the panel's
-- scrolling content, where the tab's rows are, and the tab. An unknown name
-- is answered with a message, and nothing is returned: no Lua error.
function Pages.OpenTab(name)
    local tab, why = FindTab(name)
    if not tab then
        report(why)
        return nil, why
    end
    Pages.SkipWalkthrough()
    SlashCmdList.FRIENDLYFOREVER("")
    local panel = _G[Pages.PANEL]
    local button = type(panel) == "table" and FindButton(panel, tab.label, 3)
    if not button then
        why = "the options panel has no " .. tab.label .. " tab button"
        report(why)
        return nil, why
    end
    -- The selected tab's button is disabled, and a click on it does nothing.
    if button:IsEnabled() then button:Click() end
    return button:GetParent(), tab
end

-- The Buffs tab (#408): not a message type, so not in TABS. Its places, in
-- the tab's order, each shot on its own, and the shots with a buff's
-- who-gets list open, its names open, and the choice before it's made.
Pages.BUFFS_LABEL = "Buffs"
Pages.BUFFS_PLACES = {
    { name = "buff-back", label = "Buff Back" },
    { name = "party", label = "Party" },
    { name = "raid", label = "Raid" },
    { name = "pvp", label = "PvP" },
}
-- "top" is the tab unscrolled (#472): the buff order and the first rows. "passers-by" is
-- it scrolled from "Use group versions" (the row the unscrolled shot cuts off) down to the
-- passers-by switch (#472, #474): for a paladin
-- (the simulator's class, with 11 buff rows) the switch sits about 690 px under the top
-- at 1920 x 1080, below the 593 px the panel shows, so it can't be in the unscrolled shot.
Pages.BUFFS_SHOTS = { "top", "passers-by", "buff-back", "party", "raid", "pvp", "party-list", "raid-names",
    "party-choice",
    "raid-blessings", "raid-blessings-in", "raid-blessings-unreadable" }

-- Every button under frame (to depth) whose text is label, in order.
local function FindButtons(frame, label, depth, out)
    out = out or {}
    for _, child in ipairs({ frame:GetChildren() }) do
        if child:GetObjectType() == "Button" and child.GetText and child:GetText() == label then
            out[#out + 1] = child
        end
        if depth > 1 then FindButtons(child, label, depth - 1, out) end
    end
    return out
end

-- Opens the options panel at the Buffs tab, at the place called place (a
-- BUFFS_PLACES name; Party when left out), by clicking their buttons as a
-- player would. The place "Buff Back" shares its text with the Buff Back
-- message tab, which is made first: a place's button is the last one with
-- its text. Returns the panel's scrolling content, or nothing and why.
function Pages.OpenBuffs(place)
    Pages.SkipWalkthrough()
    SlashCmdList.FRIENDLYFOREVER("")
    local panel = _G[Pages.PANEL]
    local tab = type(panel) == "table" and FindButtons(panel, Pages.BUFFS_LABEL, 3)[1]
    if not tab then
        report("the options panel has no Buffs tab button")
        return nil, "no Buffs tab"
    end
    if tab:IsEnabled() then tab:Click() end
    local content = tab:GetParent()
    local label
    for _, p in ipairs(Pages.BUFFS_PLACES) do
        if p.name == (place or "party") then label = p.label end
    end
    if not label then
        report("no Buffs place called " .. tostring(place))
        return nil, "no such place"
    end
    local buttons = FindButtons(content, label, 1)
    local button = buttons[#buttons]
    if button and button:IsEnabled() then button:Click() end
    return content
end

-- The raid Blessings rows on the Raid place (#444). A paladin who knows
-- Kings, Wisdom and Might (their lowest ranks, which BuffData.lua lists), in
-- one of three states: "out" of a raid; "in" one, with Might unticked; or
-- with the game's answer to IsInRaid() unreadable ("unreadable"), the choice
-- kept. The simulator has no raid setter, and a party change takes it
-- 20 to 90 seconds (docs/ui-simulator.md), too long for a shot: so "in"
-- wraps IsInRaid (true) and UnitIsUnit (raid1 is you) as the addon reads
-- them, and "unreadable" keeps both wraps and then makes IsInRaid answer
-- nothing. The run on #479 showed SetPartySize(7) hadn't made IsInRaid true
-- when the tab opened.
-- Returns the panel's content and a function that puts everything back
-- (the globals, the spells), or nothing and why.
Pages.RAID_BLESSING_SPELLS = { 20217, 19742, 19740 } -- Kings, Wisdom, Might
Pages.RAID_STATES = { out = true, ["in"] = true, unreadable = true }
function Pages.ShowRaidBlessings(state)
    state = (state == nil or state == "") and "out" or state
    if not Pages.RAID_STATES[state] then
        local why = "no raid Blessings state called " .. tostring(state)
        report(why)
        return nil, why
    end
    local knew = {}
    for _, id in ipairs(Pages.RAID_BLESSING_SPELLS) do
        knew[id] = IsSpellKnown(id)
        if not knew[id] then A_Admin.LearnSpell(id) end
    end
    A_Admin.FireEvent("SPELLS_CHANGED")
    local realIsInRaid, realIsUnit = IsInRaid, UnitIsUnit
    local function putBack()
        _G.IsInRaid, _G.UnitIsUnit = realIsInRaid, realIsUnit
        for _, id in ipairs(Pages.RAID_BLESSING_SPELLS) do
            if not knew[id] then A_Admin.UnlearnSpell(id) end
        end
        A_Admin.FireEvent("SPELLS_CHANGED")
    end
    -- The panel fills its rows when it is shown, not when it is already open: it is
    -- hidden first, so each state is read afresh (the run on #479 showed the
    -- header of the state before).
    local function OpenFresh()
        local panel = _G[Pages.PANEL]
        if type(panel) == "table" and panel.IsShown and panel:IsShown() then panel:Hide() end
        return Pages.OpenBuffs("raid")
    end
    local content
    local ok, err = pcall(function()
        if state ~= "out" then
            _G.IsInRaid = function() return true end
            _G.UnitIsUnit = function(a, b, ...)
                if a == "raid1" and b == "player" then return true end
                if b == "player" and type(a) == "string" and a:find("^raid%d") then return false end
                return realIsUnit(a, b, ...)
            end
        end
        content = OpenFresh()
        if state ~= "out" and content then
            -- Might unticked, as a player does it: a click on its box.
            for _, child in ipairs({ content:GetChildren() }) do
                if child.key == "might" and child:IsShown() and child:GetChecked() then child:Click() end
            end
        end
        if state == "unreadable" then
            _G.IsInRaid = function() return nil end
            content = OpenFresh() -- the tab fills itself again from the new answer
        end
    end)
    if not ok or not content then
        putBack()
        if not ok then report("the raid Blessings state failed: " .. tostring(err)) end
        return nil, tostring(err or "no Buffs tab")
    end
    return content, putBack
end

-- For the screenshot job: the Buffs tab at one of BUFFS_SHOTS. "party-list"
-- opens the first buff's who-gets list, "raid-names" the first buff's names,
-- and "party-choice" shows the choice as a player updating from 1.3.3 sees it.
function Pages.ShowBuffs(shot)
    local db = FriendlyForeverDB
    local place, extra = shot:match("^([%a-]-)%-(%a+)$")
    if not extra or extra == "back" then place, extra = shot, nil end
    if extra == "choice" and type(db) == "table" and type(db.buffBack) == "table" then
        db.buffBack.whoChoice = "pending"
    elseif type(db) == "table" and type(db.buffBack) == "table" and db.buffBack.whoChoice == "pending" then
        db.buffBack.whoChoice = "new"
    end
    if shot:find("^raid%-blessings") then
        local content = Pages.ShowRaidBlessings(shot:match("^raid%-blessings%-?(.*)$"))
        if content then
            local header
            for _, region in ipairs({ content:GetRegions() }) do
                local text = region.GetText and region:GetText()
                if text and region:IsShown() and text:find("Blessings I give in this raid:", 1, true) == 1 then
                    header = region
                end
            end
            if header then Pages.ShowFrameAt(content, header, "top") end
        end
        return content
    end
    if shot == "passers-by" then
        -- Scrolled so "Use group versions", the top row #472 names that the unscrolled shot
        -- cuts off, is near the top of the view, with the rows below it down to the
        -- passers-by switch (#474): about 66 px apart, both inside the 593 px view.
        local content = Pages.OpenBuffs()
        if not content then return content end
        local row
        for _, child in ipairs({ content:GetChildren() }) do
            local text = child.label and child.label.GetText and child.label:GetText() or ""
            if text:find("Use group versions", 1, true) == 1 then row = child end
        end
        if not row then
            report("the Buffs tab has no group versions row to show")
            return content
        end
        Pages.ShowFrameAt(content, row, "top")
        if C_Timer and C_Timer.After then C_Timer.After(0, function() Pages.ShowFrameAt(content, row, "top") end) end
        return content
    end
    if shot == "top" then
        -- Opened as a player opens it, and left unscrolled (#472, #474): the buff
        -- order, the self-buff, water and form rows and the passers-by switch.
        return (Pages.OpenBuffs())
    end
    local content = Pages.OpenBuffs(place)
    if not content then return content end
    -- The place's own button, its rows and options below it: scrolled near
    -- the top of the view, as a player scrolls down to them (#408's testing
    -- review: unscrolled, every shot showed only the buff order).
    local label
    for _, p in ipairs(Pages.BUFFS_PLACES) do
        if p.name == place then label = p.label end
    end
    local buttons = FindButtons(content, label, 1)
    local placeButton = buttons[#buttons]
    -- The first buff's who-gets button (200 wide, the highest), or its Names.
    local function First(isIt)
        local found
        for _, child in ipairs({ content:GetChildren() }) do
            if child:IsShown() and isIt(child) and (not found or (child:GetTop() or 0) > (found:GetTop() or 0)) then
                found = child
            end
        end
        return found
    end
    local function Arrange(again)
        if placeButton then Pages.ShowFrameAt(content, placeButton, "top") end
        if extra == "names" and not again then
            local names = First(function(c)
                local t = c.GetText and c:GetText() or ""
                return c:GetObjectType() == "Button" and t:find("Names", 1, true) == 1
            end)
            if names then names:Click() end
        elseif extra == "list" then
            -- Opened (closed first, a frame later) once the row sits where the
            -- shot draws it, so the list is placed against it.
            local who = First(function(c) return c:GetObjectType() == "Button" and c:GetWidth() == 200 end)
            local open = First(function(c) return c:GetObjectType() == "Frame" and c:GetFrameStrata() == "DIALOG" end)
            if who then
                if open then who:Click() end
                who:Click()
            end
        end
    end
    Arrange(false)
    if C_Timer and C_Timer.After then C_Timer.After(0, function() Arrange(true) end) end
    return content
end

-- The Buff Back tab's buffs by their Forever names (#158). The simulator
-- plays Forever with Forever's spell data (#160), so it names them itself;
-- until then a fixture here answered for it, and without one the tab showed
-- the buff keys ("wisdom"), much shorter than what a player reads. This list
-- is what the tab must show: UnnamedBuff checks the simulator against it.
-- The ranks are BuffData.lua's PALADIN ranks, which
-- spec/uitests_pages_spec.lua checks: every paladin buff, the self-buffs
-- (#44) included, since the workflow adds their spells to the simulator's
-- spell data (#343).
Pages.BUFF_NAMES = {
    { key = "kings", name = "Blessing of Kings", ranks = { 20217 } },
    { key = "wisdom", name = "Blessing of Wisdom", ranks = { 25290, 19854, 19853, 19852, 19850, 19742 } },
    { key = "might", name = "Blessing of Might", ranks = { 25291, 19838, 19837, 19836, 19835, 19834, 19740 } },
    { key = "righteousfury", name = "Righteous Fury", ranks = { 25780 } },
    { key = "devotion", name = "Devotion Aura", ranks = { 10293, 10292, 1032, 10291, 643, 10290, 465 } },
    { key = "retribution", name = "Retribution Aura", ranks = { 10301, 10300, 10299, 10298, 7294 } },
    { key = "concentration", name = "Concentration Aura", ranks = { 19746 } },
    { key = "shadowaura", name = "Shadow Resistance Aura", ranks = { 19896, 19895, 19876 } },
    { key = "frostaura", name = "Frost Resistance Aura", ranks = { 19898, 19897, 19888 } },
    { key = "fireaura", name = "Fire Resistance Aura", ranks = { 19900, 19899, 19891 } },
    { key = "sanctity", name = "Sanctity Aura", ranks = { 20218 } },
}

-- The first rank in BUFF_NAMES the client doesn't give its Forever name, as
-- a message, or nil when it names them all. A simulator that lost Forever's
-- spell data would show the tab's rows as buff keys again, and the tab's
-- layout checks would pass on text far shorter than a player reads (#158):
-- the tab scenarios fail on this message instead.
function Pages.UnnamedBuff()
    local getName = type(C_Spell) == "table" and C_Spell.GetSpellName or nil
    for _, buff in ipairs(Pages.BUFF_NAMES) do
        for _, id in ipairs(buff.ranks) do
            local ok, name = pcall(function() return getName(id) end)
            if not ok or name ~= buff.name then
                return ("the client names spell %d %s, not \"%s\""):format(id, ok and type(name) == "string"
                    and ("\"" .. name .. "\"") or "nothing", buff.name)
            end
        end
    end
    return nil
end

-- For the screenshot job: show one tab.
function Pages.ShowTab(name)
    Pages.OpenTab(name)
end

-- A message line's hover (#441), for the screenshot job: the tab (by TABS name)
-- with its line 4 holding a line that uses flavour placeholders, and the
-- pointer over that box, as a player's would be. The text is put in the box
-- only (no typing, so nothing is saved); the simulator is left as it is.
Pages.MESSAGE_LINES = 30 -- Config.NUM_MESSAGES; spec/uitests_pages_spec.lua checks it
Pages.HOVER_LINE = "{greeting}, {name}! {blessing}"
function Pages.ShowMessageHover(name)
    local content = Pages.OpenTab(name)
    if not content then return nil end
    local boxes = {}
    for _, child in ipairs({ content:GetChildren() }) do
        -- The message boxes are the wide ones; the steppers' number boxes are narrow.
        if child:GetObjectType() == "EditBox" and child:GetWidth() >= 300 then boxes[#boxes + 1] = child end
    end
    -- Other wide boxes come first (a stand-in name's); the 30 message lines are the last 30.
    local box = boxes[#boxes - Pages.MESSAGE_LINES + 4]
    if #boxes < Pages.MESSAGE_LINES or not box then
        report("the " .. tostring(name) .. " tab has no fourth message box")
        return nil
    end
    -- The panel fills its boxes from the saved settings and lays itself out on
    -- the next frame, so the line goes in and the pointer arrives then (as
    -- ShowFrameAt does); the first time is for a client with no timer.
    local function Hover()
        box:SetText(Pages.HOVER_LINE)
        local enter = box:GetScript("OnEnter")
        if enter then enter(box) end
    end
    Hover()
    if C_Timer and C_Timer.After then C_Timer.After(0, Hover) end
    return box
end

-- The options panel's scroll frame (the one holding the tab's rows), or nil.
local function PanelScroll()
    local panel = _G[Pages.PANEL]
    if type(panel) ~= "table" then return nil end
    for _, child in ipairs({ panel:GetChildren() }) do
        if child.GetScrollChild and child:GetScrollChild() then return child end
    end
end

-- Lays each region and child of content out again, in order (the same trick
-- as Settle in uitests/scenarios.lua): the simulator lays out only 16 links
-- of an anchor chain when something moves, so a row deep in the Buff Back
-- tab reads a stale place until then (docs/ui-simulator.md).
local function Settle(content)
    local function Again(region)
        local points = {}
        for i = 1, (region.GetNumPoints and region:GetNumPoints() or 0) do points[i] = { region:GetPoint(i) } end
        if #points == 0 then return end
        region:ClearAllPoints()
        for _, p in ipairs(points) do region:SetPoint(unpack(p, 1, 5)) end
        if region.GetTop then region:GetTop() end
    end
    for _ = 1, 2 do
        for _, region in ipairs({ content:GetRegions() }) do Again(region) end
        for _, child in ipairs({ content:GetChildren() }) do Again(child) end
    end
end

-- The row of content (a check box, by the start of its label's text), or nil.
local function FindRow(content, text)
    for _, child in ipairs({ content:GetChildren() }) do
        local label = child.label
        if label and label.GetText and (label:GetText() or ""):find(text, 1, true) == 1 then return child end
    end
end

-- One edge pair of region (GetTop and GetBottom, say), if both are numbers.
local function EdgePair(region, first, second)
    local ok, a, b = pcall(function() return region[first](region), region[second](region) end)
    if ok and type(a) == "number" and type(b) == "number" then return a, b end
end

-- Shows frame near the top ("top") or the bottom ("bottom") of the options
-- panel's view, as a player scrolls a row into view to use it (#408). The
-- client reads a scrolled child's regions unscrolled (docs/ui-simulator.md),
-- so code that places a frame from a row's edges (the Buffs tab's who-gets
-- list) would place it where the row sits unscrolled. The scroll child is
-- moved up by the offset instead, as the game draws it scrolled: the row's
-- edges, what the code reads from them and the shot then agree. Returns the
-- offset and a function that puts the child back, or nothing when edges
-- can't be read. The offset is worked out from the child's own top, so a
-- second call (a frame later, once the panel has laid out) gives the same.
function Pages.ShowFrameAt(content, frame, at)
    local scroll = content:GetParent()
    Settle(content)
    local viewTop, viewBottom = EdgePair(scroll, "GetTop", "GetBottom")
    local rowTop, rowBottom = EdgePair(frame, "GetTop", "GetBottom")
    local contentTop = EdgePair(content, "GetTop", "GetBottom")
    if not (viewTop and rowTop and contentTop) then return end
    local offset = contentTop - rowTop - 12
    if at == "bottom" then offset = (contentTop - viewTop) + viewBottom + 12 - rowBottom end
    offset = math.max(0, offset)
    local points = {}
    for i = 1, (content.GetNumPoints and content:GetNumPoints() or 0) do points[i] = { content:GetPoint(i) } end
    local left = EdgePair(content, "GetLeft", "GetRight")
    local scrollLeft = EdgePair(scroll, "GetLeft", "GetRight")
    content:ClearAllPoints()
    content:SetPoint("TOPLEFT", scroll, "TOPLEFT", (left and scrollLeft) and (left - scrollLeft) or 0, offset)
    Settle(content)
    return offset, function()
        content:ClearAllPoints()
        for _, p in ipairs(points) do content:SetPoint(unpack(p, 1, 5)) end
        if #points == 0 then scroll:SetScrollChild(content) end
        Settle(content)
    end
end

-- Scrolls the options panel so the row whose text starts with rowText sits
-- near the top of its view (#254), as Options.lua's ScrollTo does for the
-- walkthrough, and returns a function that puts the scroll back where it was.
-- The offset is also kept inside the range and inside the child's height
-- less the view's: the simulator's range can overshoot (2060 for a 1970 px
-- child in a 593 px view, which draws nothing). It is set again a frame
-- later, once the panel has laid the tab's rows out. Returns nothing, and
-- why, if there is no panel or row to scroll to.
function Pages.ScrollToRow(rowText)
    local scroll = PanelScroll()
    local content = scroll and scroll:GetScrollChild()
    local row = content and FindRow(content, rowText)
    if not row then
        local why = "the options panel has no row \"" .. tostring(rowText) .. "\" to scroll to"
        report(why)
        return nil, why
    end
    local before = scroll:GetVerticalScroll()
    local undone = false
    local function place()
        if undone then return end
        Settle(content)
        local top, at = content:GetTop(), row:GetTop()
        local offset = (type(top) == "number" and type(at) == "number") and math.max(0, top - at - 12) or 0
        local range = scroll:GetVerticalScrollRange()
        if type(range) == "number" then offset = math.min(offset, range) end
        local ch, vh = content:GetHeight(), scroll:GetHeight()
        if type(ch) == "number" and type(vh) == "number" and ch > vh then offset = math.min(offset, ch - vh) end
        scroll:SetVerticalScroll(offset)
    end
    place()
    if C_Timer and C_Timer.After then C_Timer.After(0, place) end
    -- Also cancels the scroll set for the next frame, if it hasn't come yet.
    return function()
        undone = true
        scroll:SetVerticalScroll(before)
    end
end

-- The row the lower shot starts at (#254): buff requests in chat, the last of
-- the Buff Back tab's own rows before its lines (the buff rows moved to the
-- Buffs tab, #408).
Pages.LOWER_ROW = "Offer my buffs to players who ask in chat"

-- For the screenshot job: a tab with its lower rows in view (#254), from the
-- buff requests row down. Like ShowTab, it leaves the panel as it is for
-- the shot.
function Pages.ShowTabLower(name)
    Pages.ShowTab(name)
    return Pages.ScrollToRow(Pages.LOWER_ROW)
end

-- The row the middle shot starts at (#383): the first of buff mode's
-- turn-on switches, with the turn-off switches and the top-up stepper below
-- it (the buff rows moved to the Buffs tab, #408).
Pages.MIDDLE_ROW = "with my group"

-- For the screenshot job: a tab with its middle rows in view (#383), from the
-- turn-on switches down, scrolled as the lower shot is.
function Pages.ShowTabMiddle(name)
    Pages.ShowTab(name)
    return Pages.ScrollToRow(Pages.MIDDLE_ROW)
end

-- The walkthrough's steps the screenshots show (#47), each named by a
-- word in its title: the first, and buff mode's key and triggers, which
-- the walkthrough must reach, taken again from Start here. whatsNew: the
-- step as a returning player sees it after an update, titled "What's new:"
-- (#169): buff requests in chat, added in walkthrough version 2 (#40, #362),
-- and the Buffs tab, added in version 3, with its keep-or-reset choice
-- offered (choice: the player's buff rules are made to wait for it, #408).
Pages.WALKTHROUGH_STEPS = {
    { name = "welcome", title = "Welcome" },
    { name = "buff-mode-key", title = "its key" },
    { name = "buff-mode-triggers", title = "turns on and off" },
    { name = "whats-new-requests", title = "Buff requests in chat", whatsNew = true },
    { name = "whats-new-buffs", title = "Your buffs have a tab of their own", whatsNew = true, choice = true },
}
-- The walkthrough version a returning player last finished, for a What's new
-- run: the one before the buff requests step's (Walkthrough.lua's since = 2).
Pages.WHATS_NEW_SEEN = 1

-- A What's new run, the way the game starts one: a player who finished an
-- older walkthrough logs in (Walkthrough.OnLogin, on PLAYER_ENTERING_WORLD
-- with isLogin). The saved state says which version they finished. Nothing
-- else answers for the addon. Finishing or skipping it saves the current
-- version again, as before.
-- choice: the player's buff rules wait for the keep-or-reset choice
-- (buffBack.whoChoice "pending", as every file saved before #408 does), so
-- the step offers it; Pages.PutBackChoice puts the saved value back.
local savedChoice
local function StartWhatsNew(choice)
    Pages.SkipWalkthrough()
    FriendlyForeverDB.walkthrough = { seen = Pages.WHATS_NEW_SEEN, firstRun = false }
    if choice and type(FriendlyForeverDB.buffBack) == "table" then
        if savedChoice == nil then savedChoice = FriendlyForeverDB.buffBack.whoChoice end
        FriendlyForeverDB.buffBack.whoChoice = "pending"
    end
    if type(A_Admin) ~= "table" or type(A_Admin.FireEvent) ~= "function" then
        error("the simulator has no A_Admin.FireEvent")
    end
    A_Admin.FireEvent("PLAYER_ENTERING_WORLD", true, false)
end

-- Takes the walkthrough again from the Start here page, as a player would,
-- or (a whatsNew step) as a returning player logging in, and clicks Next up
-- to the step called name (a Pages.WALKTHROUGH_STEPS name). Returns the
-- walkthrough's frame, or nothing and why not.
function Pages.OpenWalkthrough(name)
    local wanted
    for _, step in ipairs(Pages.WALKTHROUGH_STEPS) do
        if step.name == name then wanted = step end
    end
    if not wanted then
        local why = "no walkthrough step called " .. tostring(name)
        report(why)
        return nil, why
    end
    if wanted.whatsNew then
        StartWhatsNew(wanted.choice)
    else
        local start = Pages.Open("start")
        start.widgets.tour:Click()
    end
    local walkthrough = _G[Pages.WALKTHROUGH]
    -- At most one click a step, so a title never found can't loop forever.
    for _ = 1, 20 do
        if not walkthrough:IsShown() then break end
        if (walkthrough.title:GetText() or ""):find(wanted.title, 1, true) then return walkthrough end
        walkthrough.next:Click()
    end
    local why = "the walkthrough never reached " .. name
    report(why)
    return nil, why
end

-- Puts back the choice a choice step made wait (StartWhatsNew), unless one
-- was made since.
function Pages.PutBackChoice()
    local b = FriendlyForeverDB.buffBack
    if savedChoice ~= nil and type(b) == "table" and b.whoChoice == "pending" then b.whoChoice = savedChoice end
    savedChoice = nil
end

-- For the screenshot job: the walkthrough at one step.
function Pages.ShowWalkthrough(name)
    Pages.OpenWalkthrough(name)
end
