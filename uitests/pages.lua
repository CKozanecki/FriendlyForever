-- The phase 1 pages (#52): the options' General and Favour Ledger pages,
-- filled the way a long-time player's would be, for the scenarios
-- (scenarios.lua) to check and the screenshot job to show. The screenshot
-- job runs this file, then FriendlyForeverUIPages.Show("<page>"), through
-- --exec-lua. So this file only defines things, and calls no test().
--
-- The simulator loads the test files in name order, so this one comes before
-- scenarios.lua and FriendlyForeverUIPages is there when they run.
--
-- The fill is a worst case a player could reach: names as long as WoW
-- Forever allows (a first name and a surname of up to 12 letters each), more
-- ignored names than the General page lists, several profiles, and a full
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

    db.profiles = { ["Raid nights in Naxxramas"] = {}, ["Battlegrounds"] = {}, ["Quiet questing"] = {},
        ["Dungeons with friends"] = {} }
    db.activeProfile = "Raid nights in Naxxramas"

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
