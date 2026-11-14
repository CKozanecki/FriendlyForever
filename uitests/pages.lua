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
-- Options.START_PAGE, Window.NAME and Walkthrough.NAME).
Pages.GENERAL = "FriendlyForeverGeneralPage"
Pages.LEDGER = "FriendlyForeverLedgerPage"
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
    end
end

-- Opens one of the options pages ("general", "ledger" or "start") as
-- clicking it in the AddOns options would. Returns the page.
local PAGE_FRAMES = { general = Pages.GENERAL, ledger = Pages.LEDGER, start = Pages.START }
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

-- The Buff Back tab's buffs by their Forever names (#158). The simulator
-- plays Forever with Forever's spell data (wow-ui-sim 936d5f5, #160), so it
-- names them itself; until then a fixture here answered for it, and without
-- one the tab showed the buff keys ("wisdom"), much shorter than what a
-- player reads. This list is what the tab must show: UnnamedBuff checks the
-- simulator against it. The ranks are BuffData.lua's PALADIN ranks, which
-- spec/uitests_pages_spec.lua checks: the paladin's buffs for others only.
-- The paladin's self-buffs (#44: Righteous Fury and the auras) aren't in the
-- simulator's spell data yet, so it can't name them and their rows show
-- their keys ("retribution"; Devotion Aura is named because the simulator's
-- own source gives its player that spell, 465, at the start, though 465
-- isn't in the downloaded list). Listing them here would fail every tab's layout
-- scenarios on UnnamedBuff. #343 gives the simulator their spells, and then
-- this list takes them too. Until then spec/layout_spec.lua checks every
-- class's rows, self-buffs included, with their real names.
Pages.BUFF_NAMES = {
    { key = "kings", name = "Blessing of Kings", ranks = { 20217 } },
    { key = "wisdom", name = "Blessing of Wisdom", ranks = { 25290, 19854, 19853, 19852, 19850, 19742 } },
    { key = "might", name = "Blessing of Might", ranks = { 25291, 19838, 19837, 19836, 19835, 19834, 19740 } },
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

-- The row the lower shot starts at: the group versions check box, the first
-- of the rows below the buff order and the turn-on triggers (#254).
Pages.LOWER_ROW = "Use group versions"

-- For the screenshot job: a tab with its lower rows in view (#254), from the
-- group versions row down. Like ShowTab, it leaves the panel as it is for
-- the shot.
function Pages.ShowTabLower(name)
    Pages.ShowTab(name)
    return Pages.ScrollToRow(Pages.LOWER_ROW)
end

-- The walkthrough's steps the screenshots show (#47), each named by a
-- word in its title: the first, and buff mode's key and triggers, which
-- the walkthrough must reach.
Pages.WALKTHROUGH_STEPS = {
    { name = "welcome", title = "Welcome" },
    { name = "buff-mode-key", title = "its key" },
    { name = "buff-mode-triggers", title = "turns on and off" },
}

-- Takes the walkthrough again from the Start here page, as a player would,
-- and clicks Next up to the step called name (a Pages.WALKTHROUGH_STEPS
-- name). Returns the walkthrough's frame, or nothing and why not.
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
    local start = Pages.Open("start")
    start.widgets.tour:Click()
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

-- For the screenshot job: the walkthrough at one step.
function Pages.ShowWalkthrough(name)
    Pages.OpenWalkthrough(name)
end
