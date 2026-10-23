local wow = require("spec.support.wow")

describe("Config", function()
    local Config

    before_each(function()
        wow.reset()
        Config = wow.load().Config
    end)

    it("ships 30 default messages for every type", function()
        for _, msgType in ipairs(Config.TYPES) do
            assert.are.equal(Config.NUM_MESSAGES, #Config.DEFAULTS[msgType].messages, msgType)
            for _, text in ipairs(Config.DEFAULTS[msgType].messages) do
                if msgType == "partyHello" or msgType == "partyHelloAgain" then
                    -- Said to the whole group: there's no one name to fill in.
                    assert.is_nil(text:find("{"), msgType .. ": " .. text)
                else
                    assert.is_truthy(text:find("{name}"), msgType .. ": " .. text)
                end
                assert.is_nil(text:find("|"), "no escape codes in defaults")
            end
        end
    end)

    it("takes its default messages from Defaults.lua, same types and line counts as before the move", function()
        local ns = wow.load()
        local expected = { guildLogin = 30, buff = 30, guildJoin = 30, partyJoin = 30, partyHello = 30, partyHelloAgain = 30 }
        local fromDefaults, fromFile = {}, {}
        -- Config.DEFAULTS also holds general settings, so go by Config.TYPES.
        for _, msgType in ipairs(ns.Config.TYPES) do
            fromDefaults[msgType] = #ns.Config.DEFAULTS[msgType].messages
        end
        -- Defaults.lua holds only message types; pairs also catches an extra one.
        for msgType, list in pairs(ns.DefaultMessages) do fromFile[msgType] = #list end
        assert.are.same(expected, fromDefaults)
        assert.are.same(expected, fromFile)
        for _, msgType in ipairs(ns.Config.TYPES) do
            assert.are.equal(ns.DefaultMessages[msgType], ns.Config.DEFAULTS[msgType].messages, msgType)
        end
    end)

    it("defaults the repeat cooldown to 3 minutes (30s per group leader for hellos)", function()
        local db = Config.Load(nil)
        for _, msgType in ipairs(Config.TYPES) do
            local expected = msgType:find("^partyHello") and 30 or 180
            assert.are.equal(expected, db[msgType].repeatCooldown, msgType)
        end
    end)

    it("lowers 1.4.0's 180s Party Hello cooldown, but keeps a custom one", function()
        local db = Config.Load({ schemaVersion = 3, partyHello = { repeatCooldown = 180 } })
        assert.are.equal(30, db.partyHello.repeatCooldown)
        db = Config.Load({ schemaVersion = 3, partyHello = { repeatCooldown = 90 } })
        assert.are.equal(90, db.partyHello.repeatCooldown)
    end)

    it("defaults buff thanks to /say with a 'friend' fallback", function()
        local db = Config.Load(nil)
        assert.is_false(db.buff.useWhisper)
        assert.are.equal("friend", db.buff.unknownName)
        assert.is_true(db.buff.listBuffNames)
    end)

    it("builds a complete database from nothing", function()
        local db = Config.Load(nil)
        assert.are.equal(Config.SCHEMA_VERSION, db.schemaVersion)
        assert.is_true(db.enabled)
        assert.are.same({ angle = 220, hide = false }, db.minimap)
        for _, msgType in ipairs(Config.TYPES) do
            assert.are.same(Config.DEFAULTS[msgType].messages, db[msgType].messages)
            assert.is_true(db[msgType].enabled)
        end
    end)

    it("keeps valid user settings", function()
        local db = Config.Load({
            schemaVersion = 2, enabled = false,
            guildLogin = { enabled = false, delay = 10, repeatCooldown = 600, messages = { "Yo {name}" } },
        })
        assert.is_false(db.enabled)
        assert.is_false(db.guildLogin.enabled)
        assert.are.equal(10, db.guildLogin.delay)
        assert.are.equal(600, db.guildLogin.repeatCooldown)
        assert.are.equal("Yo {name}", db.guildLogin.messages[1])
        assert.are.equal("", db.guildLogin.messages[2], "missing lines become blank, not defaults")
    end)

    it("keeps a 1.4.2 list of 10 (edits included) and adds the 20 new default lines", function()
        local mine = {}
        for i = 1, 10 do mine[i] = "my line " .. i .. ", {name}" end
        local db = Config.Load({ schemaVersion = 4, guildLogin = { messages = mine } })
        for i = 1, 10 do assert.are.equal(mine[i], db.guildLogin.messages[i]) end
        for i = 11, 30 do assert.are.equal(Config.DEFAULTS.guildLogin.messages[i], db.guildLogin.messages[i]) end
    end)

    it("swaps untouched old guild login lines for the new ones, keeping edited ones", function()
        local saved = { "Welcome back, {name}!", "my own line, {name}", "Hi {name}! Hope you're having a great day." }
        for i = 4, 10 do saved[i] = "" end
        local db = Config.Load({ schemaVersion = 4, guildLogin = { messages = saved } })
        assert.are.equal(Config.DEFAULTS.guildLogin.messages[1], db.guildLogin.messages[1])
        assert.are.equal("my own line, {name}", db.guildLogin.messages[2])
        assert.are.equal(Config.DEFAULTS.guildLogin.messages[3], db.guildLogin.messages[3])
        assert.are.equal("", db.guildLogin.messages[4])
    end)

    it("upgrades a 1.4.2 file to the shipped 1.5.0 lines, not just whatever DEFAULTS holds", function()
        local saved = { "Welcome back, {name}!", "my own line, {name}" }
        for i = 3, 10 do saved[i] = "" end
        local db = Config.Load({ schemaVersion = 4, guildLogin = { messages = saved },
            buff = { messages = { "Thanks, {name}!" } } })
        assert.are.equal("{name} has logged in. Quick, everyone look busy.", db.guildLogin.messages[1])
        assert.are.equal("my own line, {name}", db.guildLogin.messages[2])
        assert.are.equal("Ah, {name}. Right on time. Probably.", db.guildLogin.messages[11])
        assert.are.equal("Welcome back, {name}. The fishing spot is free. For now.", db.guildLogin.messages[30])
        assert.are.equal("Thanks, {name}!", db.buff.messages[1])
        assert.are.equal("Thanks so much for the {buff}, {name}!", db.buff.messages[11])
    end)

    it("keeps a valid message rotation and repairs a broken one", function()
        local db = Config.Load({ messageBags = {
            buff = { left = { 3, 7, 30 }, last = 12 },
            guildLogin = { left = { 0, 31, 2.5, "x", 4 }, last = 99 },
            partyJoin = "garbage",
            notAType = { left = { 1 } },
        } })
        assert.are.same({ left = { 3, 7, 30 }, last = 12 }, db.messageBags.buff)
        assert.are.same({ left = { 4 } }, db.messageBags.guildLogin)
        assert.is_nil(db.messageBags.partyJoin)
        assert.is_nil(db.messageBags.notAType)
    end)

    it("repairs corrupted or hand-edited values", function()
        local db = Config.Load({
            enabled = "yes",
            minimap = { angle = "north", hide = 1 },
            buff = { enabled = 1, delay = -50, repeatCooldown = 1e9, listBuffNames = "no",
                     useWhisper = "sure", unknownName = "|cffff0000pal\n", messages = { 42, true, "ok" } },
            partyJoin = "garbage",
        })
        assert.is_true(db.enabled)
        assert.are.equal(220, db.minimap.angle)
        assert.is_false(db.minimap.hide)
        assert.is_true(db.buff.enabled)
        assert.are.equal(0, db.buff.delay)
        assert.are.equal(3600, db.buff.repeatCooldown)
        assert.is_true(db.buff.listBuffNames)
        assert.is_false(db.buff.useWhisper)
        assert.are.equal("cffff0000pal", db.buff.unknownName)
        local expected = { "", "", "ok", "", "", "", "", "", "", "" }
        for i = 11, Config.NUM_MESSAGES do expected[i] = Config.DEFAULTS.buff.messages[i] end
        assert.are.same(expected, db.buff.messages)
        assert.are.same(Config.DEFAULTS.partyJoin.messages, db.partyJoin.messages)
    end)

    it("cuts saved messages to the chat limit", function()
        local db = Config.Load({ buff = { messages = { string.rep("x", 400) } } })
        assert.are.equal(255, #db.buff.messages[1])
    end)

    it("migrates the 1.0 buff cooldown to repeatCooldown", function()
        local db = Config.Load({ buff = { cooldown = 90 } })
        assert.are.equal(90, db.buff.repeatCooldown)
        assert.is_nil(db.buff.cooldown)
        assert.are.equal(Config.SCHEMA_VERSION, db.schemaVersion)
    end)

    it("keeps an existing repeatCooldown over the old field", function()
        local db = Config.Load({ buff = { cooldown = 90, repeatCooldown = 300 } })
        assert.are.equal(300, db.buff.repeatCooldown)
    end)

    it("ignores schema versions from the future instead of crashing", function()
        local db = Config.Load({ schemaVersion = 99 })
        assert.are.equal(Config.SCHEMA_VERSION, db.schemaVersion)
    end)

    it("DefaultsFor returns an independent copy", function()
        local a = Config.DefaultsFor("guildJoin")
        a.messages[1] = "changed"
        assert.are_not.equal("changed", Config.DEFAULTS.guildJoin.messages[1])
    end)
end)
