-- Regression tests for problems found in review of the 1.7.0 work.
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
        local NEW_FILES = { ["Flavour.lua"] = true, ["FlavourText.lua"] = true, ["Ignore.lua"] = true,
            ["Ledger.lua"] = true, ["Serialize.lua"] = true, ["Profiles.lua"] = true, ["Window.lua"] = true }

        it("asks for a restart instead of erroring", function()
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
    end)
end)
