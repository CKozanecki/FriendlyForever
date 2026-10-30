-- Finding a setting (#48): one table of every setting in the options, with
-- the page it's on and words to find it by. /friendly find reads it, and so
-- does the game's own Settings search, where the game has one. A spec checks
-- that every control on every options page is in it, so it can't drift from
-- the pages.
local _, ns = ...

local OptionsIndex = {}
ns.OptionsIndex = OptionsIndex

OptionsIndex.MAX_RESULTS = 8 -- lines /friendly find prints; the rest are counted
OptionsIndex.MAX_QUERY = 40 -- letters (bytes) a search may have
OptionsIndex.SEARCH_PAGE = "Find a setting" -- the page listing them all, for the game's search

local MAIN = "the top of the options, every tab"
local EVERY_TAB = "every message tab"
local BUFF = "the Buff Thanks tab"
local BUFF_BACK = "the Buff Back tab"
local GENERAL = "the General page"
local LEDGER = "the Favour Ledger page"

-- name: as the page shows it. page: where it is. keywords: more words to find
-- it by. controls: the Options.widgets paths of its controls ("*" for any
-- row of a list), which the spec checks against the pages.
OptionsIndex.SETTINGS = {
    { name = "Addon enabled", page = MAIN, keywords = "on off master switch enable disable",
        controls = { "master" } },
    { name = "Don't send messages while I'm AFK", page = MAIN, keywords = "afk away skip",
        controls = { "skipAFK" } },
    { name = "Enabled", page = EVERY_TAB, keywords = "on off message type switch",
        controls = { "enabled" } },
    { name = "Delay after event", page = EVERY_TAB, keywords = "wait seconds timing",
        controls = { "steppers.delay" } },
    { name = "Don't repeat to the same player for", page = EVERY_TAB, keywords = "repeat cooldown seconds again",
        controls = { "steppers.repeatCooldown" } },
    { name = "Messages", page = EVERY_TAB, keywords = "lines text edit greeting thanks random",
        controls = { "edits" } },
    { name = "Preview random", page = EVERY_TAB, keywords = "test try message lines",
        controls = { "preview" } },
    { name = "Reset this tab to defaults", page = EVERY_TAB, keywords = "default restore messages lines",
        controls = { "reset" } },
    { name = "Load fantasy lines or casual lines", page = EVERY_TAB, keywords = "messages set default style",
        controls = { "loadFantasy", "loadCasual" } },

    { name = "Name the buffs in the message", page = BUFF, keywords = "buff spell names thanks",
        controls = { "listNames" } },
    { name = "Tell players I buff that it was me", page = BUFF, keywords = "buff receipts receipt caster",
        controls = { "receipts" } },
    { name = "Thank them with", page = BUFF, keywords = "buff thanks say whisper emote /thank style",
        controls = { "thankStyle" } },
    { name = "If that can't reach them", page = BUFF, keywords = "buff thanks fallback unknown name friend",
        controls = { "fallback", "unknownName" } },
    { name = "Stay quiet in capital cities", page = BUFF, keywords = "buff thanks quiet city cities capital",
        controls = { "quiet" } },
    { name = "Show friendly player names", page = BUFF, keywords = "nameplate nameplates names caster",
        controls = { "nameplateButton" } },

    { name = "Offer to buff back players who buff me", page = BUFF_BACK, keywords = "buff back favour offer",
        controls = { "enabled" } },
    { name = "Say a line once my buff lands", page = BUFF_BACK, keywords = "buff back message thanks",
        controls = { "sayLine" } },
    { name = "Buff mode key", page = BUFF_BACK, keywords = "buff mode key bind binding mouse wheel",
        controls = { "buffModeKey" } },
    { name = "Offer for (minutes)", page = BUFF_BACK, keywords = "buff back favour owed time minutes",
        controls = { "steppers.owedMinutes" } },
    { name = "Show the button in capital cities", page = BUFF_BACK, keywords = "buff back button city cities",
        controls = { "showInCities" } },
    { name = "Buff order", page = BUFF_BACK, keywords = "buff up down order first",
        controls = { "buffRows.*.up", "buffRows.*.down" } },
    { name = "Never offer a buff", page = BUFF_BACK, keywords = "buff never offer skip",
        controls = { "buffRows.*.never" } },
    { name = "Who gets each buff in buff mode", page = BUFF_BACK,
        keywords = "buff mode who class classes always never names players",
        controls = { "buffRows.*.who", "who.classes", "who.always", "who.never" } },
    { name = "Revoke Salvation", page = BUFF_BACK, keywords = "paladin salvation revoke tank names",
        controls = { "who.revoke", "who.revokeNames" } },
    { name = "Blessings I give in this raid", page = BUFF_BACK, keywords = "paladin blessing blessings raid buff",
        controls = { "who.raidBlessings" } },
    { name = "Buff mode turns on by itself", page = BUFF_BACK,
        keywords = "buff mode automatic auto group join death stranger",
        controls = { "auto.autoOnJoin", "auto.autoOnDeath", "auto.autoOnBuffed" } },
    { name = "Buff mode turns off again", page = BUFF_BACK, keywords = "buff mode automatic auto pull minutes",
        controls = { "auto.autoOffPull", "auto.autoOffDone", "steppers.autoOffMinutes" } },
    { name = "Buff in the preparation phase", page = BUFF_BACK, keywords = "buff battleground battlegrounds bg pvp",
        controls = { "bgPrepBuff" } },
    { name = "Water breathing: only near water", page = BUFF_BACK,
        keywords = "buff unending breath water breathing swim underwater",
        controls = { "breathNearWater" } },

    { name = "Snooze", page = GENERAL, keywords = "snooze pause mute quiet wake",
        controls = { "general.snooze15", "general.snooze60", "general.wake" } },
    { name = "Lines per minute in each chat", page = GENERAL, keywords = "chat limit rate spam cap",
        controls = { "general.linesPerMinute" } },
    { name = "Never greet or thank", page = GENERAL, keywords = "ignore list block player",
        controls = { "general.ignoreBox", "general.ignoreAdd", "general.ignoreRemove" } },
    { name = "Profiles", page = GENERAL, keywords = "profile new use delete character",
        controls = { "general.profileBox", "general.profileNew", "general.profileUse", "general.profileDelete" } },
    { name = "Share your settings", page = GENERAL, keywords = "export import undo share copy",
        controls = { "general.export", "general.import", "general.undoImport" } },
    { name = "Copy for a bug report", page = GENERAL, keywords = "bug report debug log help",
        controls = { "general.report" } },

    { name = "Clear the ledger", page = LEDGER, keywords = "favour ledger history clear",
        controls = { "ledger.clear" } },
}

-- Everything a setting can be found by, in lower case.
local function Haystack(entry)
    return (entry.name .. " " .. entry.keywords .. " " .. entry.page):lower()
end

-- The settings matching every word of query, in table order, or nil and why.
-- Plain matching: chat text is never read as a pattern.
function OptionsIndex.Find(query)
    if type(query) ~= "string" then return nil, "empty" end
    if #query > OptionsIndex.MAX_QUERY then return nil, "long" end
    local words = {}
    for word in query:lower():gmatch("%S+") do words[#words + 1] = word end
    if #words == 0 then return nil, "empty" end
    local found = {}
    for _, entry in ipairs(OptionsIndex.SETTINGS) do
        local haystack, all = Haystack(entry), true
        for _, word in ipairs(words) do
            if not haystack:find(word, 1, true) then all = false break end
        end
        if all then found[#found + 1] = entry end
    end
    return found
end

-- /friendly find <word>: the matching settings and the page each is on.
function OptionsIndex.Command(args)
    local found, why = OptionsIndex.Find(args)
    if not found then
        if why == "long" then
            return ns.Print(string.format("find: search for a word or two, up to %d letters.", OptionsIndex.MAX_QUERY))
        end
        return ns.Print("/friendly find <word> - which settings match, and the page each is on")
    end
    local shown = ns.Util.StripChat(args)
    if #found == 0 then
        return ns.Print("no settings match \"" .. shown .. "\". Try another word, such as buff, snooze or ignore.")
    end
    ns.Print("settings matching \"" .. shown .. "\" (Esc > Options > AddOns > Friendly Forever):")
    for i = 1, math.min(#found, OptionsIndex.MAX_RESULTS) do
        ns.Print("  " .. found[i].name .. ": on " .. found[i].page)
    end
    if #found > OptionsIndex.MAX_RESULTS then
        ns.Print(string.format("  and %d more: add a word to narrow it down.", #found - OptionsIndex.MAX_RESULTS))
    end
end

-- The game's Settings search, where it has one: a page under the addon's
-- listing every setting as a heading tagged with its words, which the
-- search box finds. Only when the client has every part of that API; the
-- other pages are drawn by the addon (canvas pages), which the search can't
-- look into. Returns whether the page was made. Launch check (#50): does
-- Forever's Settings panel have a search box, and does it find these?
function OptionsIndex.RegisterSearch(parent)
    if not (parent and type(Settings) == "table"
        and type(Settings.RegisterVerticalLayoutSubcategory) == "function"
        and type(CreateSettingsListSectionHeaderInitializer) == "function") then
        return false
    end
    -- An API shaped differently from expected mustn't stop the options loading.
    local ok, made = pcall(function()
        local _, layout = Settings.RegisterVerticalLayoutSubcategory(parent, OptionsIndex.SEARCH_PAGE)
        for _, entry in ipairs(OptionsIndex.SETTINGS) do
            local init = CreateSettingsListSectionHeaderInitializer(entry.name .. " (on " .. entry.page .. ")")
            if init then
                if type(init.AddSearchTags) == "function" then
                    local tags = { entry.name, entry.page }
                    for word in entry.keywords:gmatch("%S+") do tags[#tags + 1] = word end
                    init:AddSearchTags(unpack(tags))
                end
                layout:AddInitializer(init)
            end
        end
        return true
    end)
    local done = ok and made == true
    ns.Diag.Log("options", "settings search page: %s", done and "made" or ("not made: " .. tostring(made)))
    return done
end
