-- Spec: #48
-- Finding a setting: /friendly find <word>, the game's Settings search where
-- the client has one, and the one table both read (OptionsIndex.lua).
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local CONTROL_KINDS = { Button = true, CheckButton = true, EditBox = true }
-- Not settings: the tabs move between pages, and the key capture only waits
-- for buff mode's key (its button is in the table).
local NOT_SETTINGS = { tabs = true, keyCapture = true }

-- Every control in Options.widgets, by its path ("*" for a list's rows), found
-- by walking the widgets table itself, not the index.
local function ControlPaths(widgets)
    local paths, seen = {}, {}
    local function Walk(t, path)
        if seen[t] then return end
        seen[t] = true
        -- A frame's own fields (its anchors, its label) aren't the widgets
        -- table's: stop at it.
        if t.kind then
            if CONTROL_KINDS[t.kind] then paths[t] = path end
            return
        end
        for key, value in pairs(t) do
            if type(value) == "table" and not (path == "" and NOT_SETTINGS[key]) then
                local part = type(key) == "number" and "*" or tostring(key)
                Walk(value, path == "" and part or (path .. "." .. part))
            end
        end
    end
    Walk(widgets, "")
    return paths
end

-- Whether frame descends from one of the options pages.
local function OnAPage(frame, pages)
    local f = frame.parent
    while f do
        if pages[f] then return true end
        f = f.parent
    end
    return false
end

local function Covers(entryPath, path)
    return path == entryPath or path:sub(1, #entryPath + 1) == entryPath .. "."
end

local function Names(found)
    local names = {}
    for _, entry in ipairs(found) do names[#names + 1] = entry.name end
    return names
end

local function Has(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
end

describe("Finding a setting (#48)", function()
    local ns

    before_each(function()
        ns = wow.boot()
    end)

    describe("the settings table", function()
        it("has every control on every options page, so it can't drift from the pages", function()
            local paths = ControlPaths(ns.Options.widgets)
            local general, ledger = ns.Options.Pages()
            local pages = { [_G.FriendlyForeverOptionsPanel] = true, [general] = true, [ledger] = true }
            local missing = {}
            for _, frame in ipairs(wow.frames) do
                if CONTROL_KINDS[frame.kind] and OnAPage(frame, pages) then
                    local path = paths[frame]
                    local tab = false
                    for _, t in pairs(ns.Options.widgets.tabs) do tab = tab or t == frame end
                    if not tab then
                        local covered = false
                        for _, entry in ipairs(ns.OptionsIndex.SETTINGS) do
                            for _, c in ipairs(entry.controls) do covered = covered or (path and Covers(c, path)) end
                        end
                        if not covered then missing[#missing + 1] = path or ("a " .. frame.kind .. " not in widgets") end
                    end
                end
            end
            assert.are.same({}, missing)
        end)

        it("names only controls that exist, each with a name, a page and keywords", function()
            local paths = {}
            for _, path in pairs(ControlPaths(ns.Options.widgets)) do paths[#paths + 1] = path end
            for _, entry in ipairs(ns.OptionsIndex.SETTINGS) do
                assert.is_true(type(entry.name) == "string" and entry.name ~= "", "an entry has no name")
                assert.is_true(type(entry.page) == "string" and entry.page ~= "", entry.name .. " has no page")
                assert.is_true(type(entry.keywords) == "string", entry.name .. " has no keywords")
                assert.is_true(#entry.controls > 0, entry.name .. " has no controls")
                for _, c in ipairs(entry.controls) do
                    local exists = false
                    for _, path in ipairs(paths) do exists = exists or Covers(c, path) end
                    assert.is_true(exists, entry.name .. ": no control at " .. c)
                end
            end
        end)

        it("names each setting as its page shows it", function()
            local shown = {}
            for _, frame in ipairs(wow.frames) do
                if frame.text and frame.text ~= "" then shown[#shown + 1] = frame.text:lower() end
            end
            -- Not one label: a group of controls, or a label the tab fills in.
            local grouped = { ["Enabled"] = true, ["Messages"] = true, ["Load fantasy lines or casual lines"] = true,
                ["Buff order"] = true, ["Never offer a buff"] = true, ["Who gets each buff in buff mode"] = true,
                ["Revoke Salvation"] = true, ["Blessings I give in this raid"] = true, ["Buff mode key"] = true,
                ["Buff mode turns off again"] = true, ["Offer to buff back players who buff me"] = true,
                ["Share your settings"] = true, ["Snooze"] = true, ["Profiles"] = true,
                ["Never greet or thank"] = true }
            for _, entry in ipairs(ns.OptionsIndex.SETTINGS) do
                if not grouped[entry.name] then
                    local found = false
                    for _, text in ipairs(shown) do found = found or text:find(entry.name:lower(), 1, true) ~= nil end
                    assert.is_true(found, entry.name .. " isn't on any page")
                end
            end
        end)
    end)

    describe("/friendly find (white)", function()
        local function Find(word)
            wow.printed = {}
            _G.SlashCmdList.FRIENDLYFOREVER("find " .. word)
            return table.concat(wow.printed, "\n")
        end

        it("finds the nameplate setting on the Buff Thanks tab", function()
            local names = Names(ns.OptionsIndex.Find("nameplate"))
            assert.are.same({ "Show friendly player names" }, names)
            assert.truthy(Find("nameplate"):find("Show friendly player names: on the Buff Thanks tab", 1, true))
        end)

        it("finds snooze on the General page", function()
            assert.are.same({ "Snooze" }, Names(ns.OptionsIndex.Find("snooze")))
            assert.truthy(Find("Snooze"):find("Snooze: on the General page", 1, true))
        end)

        it("finds the buff settings, printing a few and counting the rest", function()
            local found = ns.OptionsIndex.Find("buff")
            local names = Names(found)
            for _, name in ipairs({ "Name the buffs in the message", "Offer to buff back players who buff me",
                "Buff mode key", "Never offer a buff" }) do
                assert.is_true(Has(names, name), name .. " not found")
            end
            assert.is_true(#found > ns.OptionsIndex.MAX_RESULTS)
            Find("buff")
            -- a heading, MAX_RESULTS settings, then the count
            assert.are.equal(ns.OptionsIndex.MAX_RESULTS + 2, #wow.printed)
            assert.truthy(wow.printed[#wow.printed]:find(
                string.format("and %d more", #found - ns.OptionsIndex.MAX_RESULTS), 1, true))
        end)

        it("matches every word, in any case", function()
            assert.are.same({ "Buff mode key" }, Names(ns.OptionsIndex.Find("BUFF   Key")))
        end)

        it("says so when nothing matches", function()
            assert.truthy(Find("zebra"):find("no settings match \"zebra\"", 1, true))
        end)

        it("is in /friendly help", function()
            wow.printed = {}
            _G.SlashCmdList.FRIENDLYFOREVER("help")
            assert.truthy(table.concat(wow.printed, "\n"):find("/friendly find <word>", 1, true))
        end)
    end)

    describe("/friendly find with bad input (black)", function()
        local function Run(input)
            wow.printed = {}
            _G.SlashCmdList.FRIENDLYFOREVER(input)
            return table.concat(wow.printed, "\n")
        end

        it("shows how to use it for an empty search", function()
            assert.truthy(Run("find"):find("/friendly find <word>", 1, true))
            assert.truthy(Run("find    "):find("/friendly find <word>", 1, true))
            assert.is_nil(ns.OptionsIndex.Find(""))
            assert.is_nil(ns.OptionsIndex.Find(nil))
            assert.is_nil(ns.OptionsIndex.Find(42))
        end)

        it("reads pattern characters as plain text", function()
            for _, word in ipairs({ "%", "[", "%a", "(", ".", "*", "^$", "[%]", "%f[%w]", ")" }) do
                local found = ns.OptionsIndex.Find(word)
                assert.is_table(found, word)
                local out = Run("find " .. word)
                assert.truthy(out ~= "", word)
            end
            -- "." isn't "any letter": only settings with a dot in their text.
            for _, entry in ipairs(ns.OptionsIndex.Find(".")) do
                assert.truthy((entry.name .. entry.keywords .. entry.page):find(".", 1, true))
            end
            assert.are.same({}, ns.OptionsIndex.Find("%a"))
            -- the one with an apostrophe really is found by it
            assert.is_true(Has(Names(ns.OptionsIndex.Find("can't")), "If that can't reach them"))
        end)

        it("turns down a very long search without searching", function()
            local long = string.rep("buff", 1000)
            local found, why = ns.OptionsIndex.Find(long)
            assert.is_nil(found)
            assert.are.equal("long", why)
            local out = Run("find " .. long)
            assert.truthy(out:find("up to " .. ns.OptionsIndex.MAX_QUERY .. " letters", 1, true))
            assert.is_nil(out:find(long, 1, true))
            assert.is_table(ns.OptionsIndex.Find(string.rep("a", ns.OptionsIndex.MAX_QUERY)))
            assert.is_nil(ns.OptionsIndex.Find(string.rep("a", ns.OptionsIndex.MAX_QUERY + 1)))
        end)

        it("never echoes chat codes back", function()
            local out = Run("find |cffff0000red|r|Hitem:1|h")
            -- (ns.Print colours its own prefix, so look for the player's codes)
            assert.is_nil(out:find("|cffff0000", 1, true))
            assert.is_nil(out:find("|H", 1, true))
            assert.truthy(out:find("cffff0000redrHitem:1h", 1, true))
        end)
    end)

    describe("random searches (red)", function()
        it("never errors, prints at most a heading, the cap and a count, and never changes a setting", function()
            local before = ns.Serialize.Encode(ns.db)
            local bytes = { "%", "[", "]", "(", ")", ".", "*", "+", "-", "?", "^", "$", "|", "\\", " ", "a", "b",
                "u", "f", "\0", "\255", "\195", "e" }
            random.seed(48)
            for _ = 1, 500 do
                local parts = {}
                for i = 1, random.random(0, 60) do parts[i] = bytes[random.random(#bytes)] end
                local input = table.concat(parts)
                wow.printed = {}
                local ok, err = pcall(_G.SlashCmdList.FRIENDLYFOREVER, "find " .. input)
                assert.is_true(ok, tostring(err))
                assert.is_true(#wow.printed >= 1 and #wow.printed <= ns.OptionsIndex.MAX_RESULTS + 2)
            end
            assert.are.same({}, wow.errors)
            assert.are.equal(before, ns.Serialize.Encode(ns.db))
        end)
    end)

    describe("the game's Settings search", function()
        it("isn't used on a client without it, and the options still load", function()
            assert.is_nil(wow.settings.vertical)
            local names = {}
            for _, sub in ipairs(wow.settings.subcategories) do names[#names + 1] = sub.name end
            assert.is_false(Has(names, ns.OptionsIndex.SEARCH_PAGE))
            assert.is_false(ns.OptionsIndex.RegisterSearch({}))
        end)

        it("finds nameplate, snooze and buff settings where the client has it", function()
            ns = wow.boot({ before = function(state) state.settingsSearch = true end })
            local search = wow.settings.vertical[1]
            assert.are.equal(ns.OptionsIndex.SEARCH_PAGE, search.name)
            assert.are.equal(4242, search.parent:GetID())
            assert.are.equal(#ns.OptionsIndex.SETTINGS, #search.layout.initializers)
            assert.are.same({ "Show friendly player names (on the Buff Thanks tab)" }, wow.searchSettings("nameplate"))
            assert.are.same({ "Snooze (on the General page)" }, wow.searchSettings("snooze"))
            local buff = wow.searchSettings("buff")
            assert.is_true(Has(buff, "Buff mode key (on the Buff Back tab)"))
            assert.is_true(Has(buff, "Name the buffs in the message (on the Buff Thanks tab)"))
            -- the same table as /friendly find
            assert.are.equal(#ns.OptionsIndex.Find("buff"), #buff)
        end)

        it("still lists the settings when headings can't be tagged", function()
            ns = wow.boot({ before = function(state) state.settingsSearch = "noTags" end })
            assert.are.equal(#ns.OptionsIndex.SETTINGS, #wow.settings.vertical[1].layout.initializers)
            assert.are.same({}, wow.searchSettings("snooze"))
        end)

        it("makes no page without the headings, or the addon's own page to hang it on", function()
            ns = wow.boot({ before = function(state) state.settingsSearch = true end })
            local made = #wow.settings.vertical
            assert.is_false(ns.OptionsIndex.RegisterSearch(nil))
            assert.are.equal(made, #wow.settings.vertical)
            _G.CreateSettingsListSectionHeaderInitializer = nil
            assert.is_false(ns.OptionsIndex.RegisterSearch({}))
            assert.are.equal(made, #wow.settings.vertical)
        end)

        it("doesn't stop the options loading when the API answers unexpectedly", function()
            ns = wow.boot({ before = function(state) state.settingsSearch = true end })
            _G.Settings.RegisterVerticalLayoutSubcategory = function() error("changed API") end
            assert.is_false(ns.OptionsIndex.RegisterSearch({}))
            _G.Settings.RegisterVerticalLayoutSubcategory = function() return {}, nil end
            assert.is_false(ns.OptionsIndex.RegisterSearch({}))
            _G.Settings.RegisterVerticalLayoutSubcategory = function() return {}, { AddInitializer = 1 } end
            assert.is_false(ns.OptionsIndex.RegisterSearch({}))
            _G.CreateSettingsListSectionHeaderInitializer = function() error("changed API") end
            _G.Settings.RegisterVerticalLayoutSubcategory = function() return {}, { AddInitializer = function() end } end
            assert.is_false(ns.OptionsIndex.RegisterSearch({}))
            assert.is_false(ns.OptionsIndex.RegisterSearch(nil))
        end)
    end)
end)
