-- Spec: #80, #35
-- Regression tests for problems found in review of the 0.8.0 work.
local wow = require("spec.support.wow")

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Regressions", function()
    local ns

    before_each(function() ns = wow.boot() end)

    describe("import undo", function()
        it("can't be applied to another profile after switching", function()
            ns.db.guildLogin.delay = 7
            ns.Profiles.New("A")
            ns.Profiles.New("B")
            ns.db.guildLogin.delay = 9
            ns.Profiles.Use("A")
            local line = ns.Serialize.Encode({ v = 1, settings = { guildLogin = { delay = 1 } } })
            assert.is_true(ns.Profiles.Import(line))
            ns.Profiles.Use("B")
            assert.is_false(ns.Profiles.CanUndoImport())
            assert.is_nil(ns.Profiles.UndoImport())
            assert.are.equal(9, ns.db.guildLogin.delay, "B's settings are untouched")
        end)

        it("is dropped when a new profile is made", function()
            ns.Profiles.Import(ns.Profiles.Export())
            ns.Profiles.New("Fresh")
            assert.is_false(ns.Profiles.CanUndoImport())
        end)

        it("takes off only the ignored names the import added", function()
            ns.Ignore.Add("Ann-Vale")
            local line = ns.Serialize.Encode({ v = 1, settings = { ignore = { ["bob-stone"] = "Bob-Stone" } } })
            ns.Profiles.Import(line)
            ns.Ignore.Add("Cid-Moon") -- added after the import
            ns.Profiles.UndoImport()
            assert.are.same({ "Ann Vale", "Cid Moon" }, ns.Ignore.List())
        end)
    end)

    describe("import contents", function()
        it("keeps only the settings each message type has", function()
            local line = ns.Serialize.Encode({ v = 1, settings = {
                buff = { junk = string.rep("x", 5000), nested = { a = { b = 1 } }, delay = 2 },
                guildLogin = { listBuffNames = false, thankStyle = "both" },
            } })
            assert.is_true(ns.Profiles.Import(line))
            assert.is_nil(ns.db.buff.junk)
            assert.is_nil(ns.db.buff.nested)
            assert.are.equal(2, ns.db.buff.delay)
            assert.is_nil(ns.db.guildLogin.listBuffNames, "buff-only options don't appear on other types")
            assert.is_nil(ns.db.guildLogin.thankStyle)
            assert.is_true(#ns.Profiles.Export() < 20000)
        end)

        it("rejects infinite numbers", function()
            assert.is_nil(ns.Serialize.Decode("FF1:Ninf;"))
            assert.is_nil(ns.Serialize.Decode("FF1:N-inf;"))
        end)

        it("brings a line from an older version up to date", function()
            local casual = {}
            for i, line in ipairs(ns.CasualMessages.guildJoin) do casual[i] = line end
            local line = ns.Serialize.Encode({ v = 1, settings = { schemaVersion = 5, guildJoin = { messages = casual } } })
            ns.Profiles.Import(line)
            assert.are.same(ns.DefaultMessages.guildJoin, ns.db.guildJoin.messages)
        end)

        it("takes a line without a version as current (no old migrations)", function()
            ns.Profiles.Import(ns.Serialize.Encode({ v = 1, settings = { guildLogin = { messages = { "Hi {name}" } } } }))
            assert.are.equal("Hi {name}", ns.db.guildLogin.messages[1])
            assert.are.equal("", ns.db.guildLogin.messages[11])
        end)

        it("stores the settings version in profiles and exports", function()
            ns.Profiles.New("P")
            assert.are.equal(ns.Config.SCHEMA_VERSION, ns.db.profiles.P.schemaVersion)
            local data = ns.Serialize.Decode(ns.Profiles.Export())
            assert.are.equal(ns.Config.SCHEMA_VERSION, data.settings.schemaVersion)
        end)

        it("never drops your own ignored names to make room for imported ones", function()
            local letters = "abcdefghijklmnopqrstuvwxyz"
            local mine = {}
            for i = 0, ns.Config.MAX_IGNORED - 1 do
                local a, b = (i % 26) + 1, math.floor(i / 26) + 1
                local name = "M" .. letters:sub(a, a) .. letters:sub(b, b) .. "-Own"
                assert.is_truthy(ns.Ignore.Add(name), name)
                mine[#mine + 1] = name
            end
            local line = ns.Serialize.Encode({ v = 1, settings = { ignore = { ["zed-new"] = "Zed-New" } } })
            ns.Profiles.Import(line)
            assert.are.equal(ns.Config.MAX_IGNORED, #ns.Ignore.List())
            assert.is_false(ns.Ignore.Has("Zed-New"))
            for _, name in ipairs(mine) do assert.is_true(ns.Ignore.Has(name), name) end
        end)
    end)

    describe("ignore list case", function()
        it("a name typed in lower case still matches the game's name", function()
            _G.SlashCmdList.FRIENDLYFOREVER("ignore thrall hellscream")
            ns.db.guildLogin.messages = { "Hello {name}" }
            wow.rosterUpdate({ "Thrall-Hellscream" })
            wow.systemMessage("|Hplayer:Thrall-Hellscream|h[Thrall-Hellscream]|h has come online.")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
            assert.are.same({ "thrall hellscream" }, ns.Ignore.List(), "shown as typed")
        end)
    end)

    describe("buff thanks", function()
        local function settle()
            wow.advance(ns.db.buff.delay + 0.01)
            wow.keyDown()
        end

        before_each(function() ns.db.buff.messages = { "Thanks, {class} {name}!" } end)

        it("doesn't name the class of whoever a reused unit token points at now", function()
            wow.addUnit("mouseover", { name = "Bob", surname = "Stone", class = "MAGE", target = "player" })
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "mouseover", "cast-1", 1459)
            wow.addUnit("mouseover", { name = "Ann", surname = "Vale", class = "WARRIOR" })
            wow.gainBuff({ name = "Arcane Intellect", spellId = 1459 })
            settle()
            assert.are.same({ "Thanks, friend Bob!" }, wow.sentTo("SAY"))
        end)

        it("with 'both', a buff after the line went out is a favour of its own", function()
            ns.db.buff.thankStyle = "both"
            ns.db.buff.repeatCooldown = 0
            wow.addUnit("target", { name = "Bob", surname = "Stone" })
            wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
            settle() -- the line goes; the emote waits behind the send interval
            wow.gainBuff({ sourceUnit = "target", name = "Thorns" })
            assert.are.equal(2, #ns.db.ledger.entries)
            assert.are.same({ "Thorns" }, ns.db.ledger.entries[2].buffs)
        end)
    end)

    it("clearing the ledger while a thank-you waits doesn't count it afterwards", function()
        wow.addUnit("target", { name = "Bob", surname = "Stone" })
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        ns.Ledger.Clear()
        wow.advance(ns.db.buff.delay + 0.01)
        wow.keyDown()
        local s = ns.Ledger.Summary()
        assert.are.same({ 0, 0 }, { s.received, s.thanked })
    end)

    describe("ignoring someone while their message waits", function()
        it("drops a buff thank-you already scheduled", function()
            ns.db.buff.messages = { "Thanks {name}" }
            wow.addUnit("target", { name = "Bob", surname = "Stone" })
            wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
            ns.Ignore.Add("Bob-Stone")
            wow.advance(ns.db.buff.delay + 0.01)
            wow.keyDown()
            assert.are.same({}, wow.sent)
            assert.are.equal("on your ignore list", ns.db.ledger.entries[1].note)
        end)

        it("drops a /thank emote already scheduled", function()
            ns.db.buff.thankStyle = "emote"
            wow.addUnit("target", { name = "Bob", surname = "Stone" })
            wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
            ns.Ignore.Add("Bob-Stone")
            wow.advance(ns.db.buff.delay + 0.01)
            wow.keyDown()
            assert.are.equal(0, #wow.emotes)
        end)

        it("drops a guild login greeting and a guild welcome", function()
            ns.db.guildLogin.messages = { "Hello {name}" }
            ns.db.guildJoin.messages = { "Welcome {name}" }
            wow.rosterUpdate({ "Thrall-Hellscream" })
            wow.systemMessage("|Hplayer:Thrall-Hellscream|h[Thrall-Hellscream]|h has come online.")
            wow.systemMessage("Bob-Stone has joined the guild.")
            ns.Ignore.Add("Thrall-Hellscream")
            ns.Ignore.Add("Bob-Stone")
            wow.advance(10)
            assert.are.same({}, wow.sent)
        end)

        it("leaves them out of a party welcome, welcoming the rest", function()
            ns.db.partyJoin.messages = { "Hi {name}" }
            wow.state.isLeader = true
            wow.setGroup("party", { "Bob-Stone", "Ann-Vale" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.systemMessage("Bob-Stone joins the party.")
            wow.systemMessage("Ann-Vale joins the party.")
            ns.Ignore.Add("Bob-Stone")
            wow.advance(10)
            assert.are.same({ "Hi Ann" }, wow.sentTo("PARTY"))
        end)
    end)

    it("the General page lists a few ignored names and counts the rest", function()
        local L = "abcdefghijklmnopqrstuvwxyz"
        for i = 1, 200 do
            local a, b = math.floor(i / 26) % 26 + 1, i % 26 + 1
            ns.Ignore.Add("Na" .. L:sub(a, a) .. L:sub(b, b) .. "-Stone")
        end
        ns.Options.FillGeneral()
        local text = ns.Options.widgets.general.ignoreList:GetText()
        assert.is_true(#text < 400)
        assert.is_truthy(text:find("and 188 more", 1, true))
    end)

    it("the ignore list holds at most MAX_IGNORED names", function()
        local L = "abcdefghijklmnopqrstuvwxyz"
        local function name(i)
            local a, b = math.floor(i / 26) % 26 + 1, i % 26 + 1
            return "Na" .. L:sub(a, a) .. L:sub(b, b) .. "-Stone"
        end
        for i = 1, ns.Config.MAX_IGNORED do assert.is_truthy(ns.Ignore.Add(name(i))) end
        local ok, why = ns.Ignore.Add("Zed-Last")
        assert.is_nil(ok)
        assert.is_truthy(why:find("full", 1, true))
        assert.are.equal(name(1), ns.Ignore.Add(name(1)), "a name already there is still fine")
    end)

    it("caps a saved snooze at a day, so a damaged file or clock can't mute the addon for good", function()
        ns = wow.boot({ db = { snoozeUntil = math.huge } })
        local left = ns.Announcer.SnoozeLeft() -- capped at load; the login grace has passed since
        assert.is_true(left <= 24 * 60 * 60 and left > 24 * 60 * 60 - 60)
        assert.is_truthy(ns.Announcer.ActiveState():find("1440 min left", 1, true))
    end)

    it("drops ledger entries with an infinite time", function()
        ns = wow.boot({ db = { ledger = { entries = {
            { t = math.huge, who = "Bob-Stone" }, { t = -math.huge, who = "Bob-Stone" }, { t = 5, who = "Ann-Vale" },
        } } } })
        assert.are.equal(1, #ns.db.ledger.entries)
        assert.are.equal("Ann-Vale", ns.db.ledger.entries[1].who)
    end)

    it("a saved ledger longer than MAX_ENTRIES keeps the newest", function()
        local entries = {}
        for i = 1, 250 do entries[i] = { t = i, who = "Bob-Stone", buffs = {}, result = "thanked" } end
        ns = wow.boot({ db = { ledger = { entries = entries } } })
        assert.are.equal(ns.Ledger.MAX_ENTRIES, #ns.db.ledger.entries)
        assert.are.equal(51, ns.db.ledger.entries[1].t)
    end)

    it("a saved file with too many profiles keeps MAX of them, the active one first", function()
        local profiles = {}
        for i = 1, 30 do profiles[string.format("P%02d", i)] = {} end
        ns = wow.boot({ db = { profiles = profiles, activeProfile = "P30" } })
        local n = 0
        for _ in pairs(ns.db.profiles) do n = n + 1 end
        assert.are.equal(ns.Profiles.MAX, n)
        assert.is_table(ns.db.profiles.P30)
        assert.is_table(ns.db.profiles.P01)
        assert.is_nil(ns.db.profiles.P29, "after the active one, the first names in order")
    end)

    it("won't export a line import would refuse", function()
        for _, msgType in ipairs(ns.Config.TYPES) do
            for i = 1, ns.Config.NUM_MESSAGES do ns.db[msgType].messages[i] = string.rep("%", 255) end
        end
        local text, why = ns.Profiles.Export()
        assert.is_nil(text)
        assert.is_truthy(why:find("too long", 1, true))
    end)

    it("a secret zone, hour, instance, faction and race ID fall back without errors", function()
        ns = wow.boot({ shippedLines = true })
        local S = wow.secret
        _G.UnitRace = function() return "Skyborne", "Skyborne", S(95) end
        _G.UnitFactionGroup = function() return S("Alliance"), S("Alliance") end
        _G.GetRealZoneText = function() return S("Westfall") end
        _G.GetZoneText = function() return S("Westfall") end
        _G.IsInInstance = function() return S(true), S("party") end
        _G.IsResting = function() return S(true) end
        _G.GetGameTime = function() return S(3), S(0) end
        local text = ns.Util.Render("{zone} {timeofday} {blessing}", ns.Flavour.Vars({ name = "Nikki" }))
        assert.is_truthy(text:find("^these lands evening "))
        assert.is_nil(ns.Flavour.Context().race, "a Skyborne with no readable ID or faction gets general lines")
        slash("status")
        assert.are.same({}, wow.errors)
    end)

    it("a snooze under a minute is a minute, not zero", function()
        slash("snooze 0.5")
        assert.are.equal(60, ns.Announcer.SnoozeLeft())
    end)

    it("the text window closes with Esc", function()
        slash("report")
        local found = false
        for _, name in ipairs(_G.UISpecialFrames) do found = found or name == ns.Window.NAME end
        assert.is_true(found)
    end)

    describe("after an update and a /reload (no restart)", function()
        -- The files each update added, by the release it updates from.
        local UPDATES = {
            { from = "an older release", files = { ["Flavour.lua"] = true, ["FlavourText.lua"] = true, ["Ignore.lua"] = true,
                ["Ledger.lua"] = true, ["Serialize.lua"] = true, ["Profiles.lua"] = true, ["Window.lua"] = true } },
            { from = "0.8.0", files = { ["RateLimit.lua"] = true } }, -- #35
        }

        for _, update in ipairs(UPDATES) do
            local NEW_FILES = update.files
            it("asks for a restart instead of erroring (updating from " .. update.from .. ")", function()
                wow.reset()
                local loaded = {}
                local _, files = wow.parseToc()
                for _, file in ipairs(files) do
                    if not NEW_FILES[file] then
                        assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded)
                    end
                end
                wow.fire("ADDON_LOADED", wow.ADDON_NAME)
                wow.fire("PLAYER_ENTERING_WORLD", true, false)
                wow.advance(20)
                wow.addUnit("target", { name = "Bob", surname = "Stone" })
                wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
                wow.systemMessage("Bob-Stone has joined the guild.")
                _G.SlashCmdList.FRIENDLYFOREVER("status")
                wow.advance(10)
                assert.are.same({}, wow.errors)
                assert.are.equal(0, #wow.sent)
                local all = table.concat(wow.printed, "\n")
                assert.is_truthy(all:find("Restart the game", 1, true))
                assert.is_truthy(all:find("restart the game (not /reload)", 1, true))
            end)
        end
    end)
end)
