local wow = require("spec.support.wow")

describe("Don't send messages while I'm AFK", function()
    local ns

    local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

    local function online(name)
        wow.systemMessage("|Hplayer:" .. name .. "|h[" .. name .. "]|h has come online.")
    end

    local function logHas(fragment)
        for _, line in ipairs(ns.db.diagLog) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end

    local function buffFromStranger()
        wow.addUnit("target", { name = "Bob" })
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
    end

    before_each(function()
        ns = wow.boot({ before = function(state) state.guildRoster = { "Thrall" } end })
        wow.fire("GUILD_ROSTER_UPDATE")
        ns.db.debug = true
    end)

    it("is on by default", function()
        assert.is_true(ns.db.skipWhileAFK)
    end)

    describe("when on", function()
        it("drops a guild greeting that comes due while AFK, and logs why", function()
            wow.state.afk = true
            online("Thrall")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
            assert.are.equal(0, ns.ChatQueue.Count(), "dropped, not held")
            assert.is_true(logHas("dropped guildLogin for Thrall: you are AFK"))
            wow.state.afk = false
            wow.advance(150)
            assert.are.equal(0, #wow.sent, "not sent later either")
        end)

        it("drops party welcomes and buff thanks too", function()
            wow.state.afk = true
            wow.setGroup("party", { "Sorum-Md" })
            wow.systemMessage("Sorum-Md joins the party.")
            buffFromStranger()
            wow.advance(10)
            wow.keyDown()
            assert.are.equal(0, #wow.sent)
            assert.is_true(logHas("dropped partyJoin for Sorum-Md: you are AFK"))
            assert.is_true(logHas("dropped buff for Bob: you are AFK"))
        end)

        it("sends a /say thank-you when the key press it waits for brings me back", function()
            buffFromStranger()
            wow.advance(ns.db.buff.delay + 0.1)
            assert.are.equal(1, ns.ChatQueue.Count(), "waiting for a key press")
            wow.state.afk = true
            wow.advance(ns.ChatQueue.RETRY_DELAY * 3)
            assert.are.equal(1, ns.ChatQueue.Count(), "judged at the key press, not while waiting for it")
            wow.state.keyClearsAFK = true
            wow.keyDown()
            assert.are.equal(1, #wow.sentTo("SAY"))
        end)

        it("drops it if I'm still AFK at the key press", function()
            buffFromStranger()
            wow.advance(ns.db.buff.delay + 0.1)
            wow.state.afk = true
            wow.keyDown()
            assert.are.equal(0, #wow.sent)
            assert.are.equal(0, ns.ChatQueue.Count())
        end)

        it("sends as usual when AFK can't be read (restricted)", function()
            wow.state.afk = true
            wow.state.unitsRestricted = true
            online("Thrall")
            wow.advance(10)
            assert.are.equal(1, #wow.sentTo("GUILD"))
        end)

        it("still lets /friendly test preview and /friendly selftest send", function()
            wow.state.afk = true
            slash("test")
            assert.are.equal(#ns.Config.TYPES, #wow.printed)
            slash("selftest")
            assert.are.equal(1, #wow.sentTo("WHISPER"))
        end)
    end)

    describe("when off", function()
        it("sends while AFK", function()
            ns.db.skipWhileAFK = false
            wow.state.afk = true
            online("Thrall")
            wow.advance(10)
            assert.are.equal(1, #wow.sentTo("GUILD"))
        end)

        it("the options checkbox switches it", function()
            local box = ns.Options.widgets.skipAFK
            assert.is_true(box:GetChecked())
            box:SetChecked(false)
            wow.run(box, "OnClick")
            assert.is_false(ns.db.skipWhileAFK)
            wow.state.afk = true
            online("Thrall")
            wow.advance(10)
            assert.are.equal(1, #wow.sentTo("GUILD"))
        end)
    end)

    describe("saved settings", function()
        it("old saved variables without the field get it on", function()
            ns = wow.boot({ db = { schemaVersion = 5, enabled = true, guildLogin = { delay = 7 } } })
            assert.is_true(ns.db.skipWhileAFK)
            assert.are.equal(7, ns.db.guildLogin.delay)
        end)

        it("keeps it off once switched off, and repairs a bad value", function()
            assert.is_false(ns.Config.Load({ skipWhileAFK = false }).skipWhileAFK)
            assert.is_true(ns.Config.Load({ skipWhileAFK = "yes" }).skipWhileAFK)
        end)
    end)
end)
