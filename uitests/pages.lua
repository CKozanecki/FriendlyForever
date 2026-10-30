-- The phase 1 pages (#52): the options' General and Favour Ledger pages,
-- filled the way a long-time player's would be, for the scenarios
-- (scenarios.lua) to check and the screenshot job to show. The screenshot
-- job runs this file, then FriendlyForeverUIPages.Show("<page>"), through
-- --exec-lua. So this file only defines things, and calls no test().
--
-- The main panel's tabs (#112) too: FriendlyForeverUIPages.ShowTab("<tab>")
-- opens the panel and clicks that tab's button, as a player would, with the
-- Buff Back tab's buffs named as on Forever (NameBuffs, #158).
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

-- The frames' names (Options.GENERAL_PAGE, Options.LEDGER_PAGE and Window.NAME).
Pages.GENERAL = "FriendlyForeverGeneralPage"
Pages.LEDGER = "FriendlyForeverLedgerPage"
Pages.WINDOW = "FriendlyForeverTextWindow"

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
    { "Blessing of Wisdom", "Blessing of Salvation" },
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

-- Opens one of the options pages ("general" or "ledger") as clicking it in
-- the AddOns options would. Returns the page.
function Pages.Open(which)
    local page = _G[which == "ledger" and Pages.LEDGER or Pages.GENERAL]
    if type(page) ~= "table" then error("no options page called " .. tostring(which), 2) end
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

-- The Buff Back tab's buffs by their Forever names (#158). The simulator's
-- spell data is retail's, with none of Forever's buffs (docs/ui-simulator.md),
-- so without these the tab shows the buff keys ("salvation"), much shorter
-- than what a player reads. The ranks are BuffData.lua's PALADIN ranks,
-- which spec/uitests_pages_spec.lua checks.
Pages.BUFF_NAMES = {
    { key = "kings", name = "Blessing of Kings", ranks = { 20217 } },
    { key = "wisdom", name = "Blessing of Wisdom", ranks = { 25290, 19854, 19853, 19852, 19850, 19742 } },
    { key = "might", name = "Blessing of Might", ranks = { 25291, 19838, 19837, 19836, 19835, 19834, 19740 } },
    { key = "light", name = "Blessing of Light", ranks = { 19979, 19978, 19977 } },
    { key = "salvation", name = "Blessing of Salvation", ranks = { 1038 } },
}

-- Makes C_Spell.GetSpellName answer BUFF_NAMES' ranks, and pass every
-- other spell on to the simulator's own. Returns a function that puts the
-- original back.
function Pages.NameBuffs()
    local names = {}
    for _, buff in ipairs(Pages.BUFF_NAMES) do
        for _, id in ipairs(buff.ranks) do names[id] = buff.name end
    end
    local original = C_Spell.GetSpellName
    C_Spell.GetSpellName = function(spell, ...)
        if names[spell] then return names[spell] end
        if original then return original(spell, ...) end
    end
    return function() C_Spell.GetSpellName = original end
end

-- Runs fn with the buffs named (NameBuffs), and puts the original back
-- afterwards, even when fn fails, raising fn's error then.
function Pages.WithBuffNames(fn)
    local undo = Pages.NameBuffs()
    local ok, err = pcall(fn)
    undo()
    if not ok then error(err, 0) end
end

-- For the screenshot job: show one tab, the Buff Back tab with its buffs'
-- Forever names. The names stay, like the tab, for the shot taken after.
function Pages.ShowTab(name)
    Pages.NameBuffs()
    Pages.OpenTab(name)
end
