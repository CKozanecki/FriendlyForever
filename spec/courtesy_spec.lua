-- Spec: #52
-- The ignore list and snooze: two ways to keep the addon quiet.
local wow = require("spec.support.wow")

describe("Ignore list", function()
    local ns

    local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

    local function printedHas(fragment)
        for _, line in ipairs(wow.printed) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end

    before_each(function()
        ns = wow.boot()
        ns.db.buff.messages = { "Thank you for the {buff}, {name}!" }
        ns.db.guildLogin.messages = { "Hello {name}" }
        ns.db.guildJoin.messages = { "Welcome {name}" }
        ns.db.partyJoin.messages = { "Hi {name}" }
    end)

    it("adds a name typed with a space or a hyphen, as the full name", function()
        slash("ignore Nikki Shifts")
        slash("ignore Bob-Stone")
        assert.is_true(ns.Ignore.Has("Nikki-Shifts"))
        assert.is_true(ns.Ignore.Has("Bob-Stone"))
        assert.are.same({ "Bob Stone", "Nikki Shifts" }, ns.Ignore.List())
    end)

    it("adds your target when no name is given", function()
        wow.addUnit("target", { name = "Ann", surname = "Vale" })
        slash("ignore")
        assert.is_true(ns.Ignore.Has("Ann-Vale"))
    end)

    it("doesn't add an NPC target", function()
        wow.addUnit("target", { name = "Guard", surname = "Thomas", isPlayer = false })
        slash("ignore")
        assert.is_false(ns.Ignore.Has("Guard-Thomas"))
    end)

    it("lists the names when there's nothing to add", function()
        ns.Ignore.Add("Nikki Shifts")
        slash("ignore")
        assert.is_true(printedHas("Nikki Shifts"))
    end)

    it("warns about a name without a surname", function()
        slash("ignore Nikki")
        assert.is_true(printedHas("surname"))
    end)

    it("rejects text that isn't a name", function()
        slash("ignore 12 34 56")
        assert.are.same({}, ns.Ignore.List())
        assert.is_true(printedHas("isn't a player name"))
    end)

    it("removes a name, and says when it wasn't there", function()
        ns.Ignore.Add("Nikki Shifts")
        slash("unignore nikki shifts")
        assert.is_false(ns.Ignore.Has("Nikki-Shifts"), "names match whatever their case")
        slash("unignore Nikki Shifts")
        assert.is_true(printedHas("isn't on the list"))
    end)

    it("doesn't thank an ignored player who buffs you, and says so in the ledger", function()
        ns.Ignore.Add("Bob-Stone")
        wow.addUnit("target", { name = "Bob", surname = "Stone" })
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        wow.advance(10)
        wow.keyDown()
        assert.are.equal(0, #wow.sent)
        local entry = ns.db.ledger.entries[1]
        assert.are.equal("Bob-Stone", entry.who)
        assert.are.equal("not thanked", entry.result)
        assert.are.equal("on your ignore list", entry.note)
    end)

    it("doesn't greet an ignored guildmate logging in", function()
        ns.Ignore.Add("Bob-Stone")
        wow.rosterUpdate({ "Bob-Stone", "Ann-Vale" })
        wow.systemMessage("|Hplayer:Bob-Stone|h[Bob-Stone]|h has come online.")
        wow.systemMessage("|Hplayer:Ann-Vale|h[Ann-Vale]|h has come online.")
        wow.advance(10)
        assert.are.same({ "Hello Ann" }, wow.sentTo("GUILD"))
    end)

    it("doesn't welcome an ignored player to the guild", function()
        ns.Ignore.Add("Bob-Stone")
        wow.systemMessage("Bob-Stone has joined the guild.")
        wow.advance(10)
        assert.are.equal(0, #wow.sent)
    end)

    it("leaves an ignored player out of a party welcome, but welcomes the rest", function()
        ns.Ignore.Add("Bob-Stone")
        wow.state.isLeader = true
        wow.setGroup("party", { "Bob-Stone", "Ann-Vale" })
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.systemMessage("Bob-Stone joins the party.")
        wow.systemMessage("Ann-Vale joins the party.")
        wow.advance(10)
        assert.are.same({ "Hi Ann" }, wow.sentTo("PARTY"))
    end)

    it("is saved, and survives a reload with a damaged entry dropped", function()
        local db = { ignore = { ["Bob-Stone"] = true, ["not a name!"] = true, ["Ann-Vale"] = "yes",
            ["cid-moon"] = "Ann-Vale" } }
        ns = wow.boot({ db = db })
        assert.is_true(ns.Ignore.Has("Bob-Stone"))
        assert.are.same({ "Bob Stone" }, ns.Ignore.List())
    end)
end)

describe("Snooze", function()
    local ns

    local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

    before_each(function()
        ns = wow.boot()
        ns.db.guildJoin.messages = { "Welcome {name}" }
    end)

    local function join(name)
        wow.systemMessage(name .. " has joined the guild.")
        wow.advance(10)
    end

    it("sends nothing for 15 minutes by default", function()
        slash("snooze")
        join("Bob-Stone")
        assert.are.equal(0, #wow.sent)
        wow.advance(15 * 60)
        join("Ann-Vale")
        assert.are.same({ "Welcome Ann" }, wow.sentTo("GUILD"))
    end)

    it("takes a number of minutes, and 'off' wakes it early", function()
        slash("snooze 60")
        wow.advance(30 * 60)
        join("Bob-Stone")
        assert.are.equal(0, #wow.sent)
        slash("snooze off")
        join("Ann-Vale")
        assert.are.same({ "Welcome Ann" }, wow.sentTo("GUILD"))
    end)

    it("caps a snooze at a day", function()
        slash("snooze 100000")
        assert.are.equal(24 * 60 * 60, ns.Announcer.SnoozeLeft())
    end)

    it("drops a message already waiting when the snooze starts", function()
        join("Bob-Stone")
        wow.state.lockdown = true -- holds the line in the queue
        ns.db.guildJoin.delay = 0
        wow.systemMessage("Ann-Vale has joined the guild.")
        wow.advance(1)
        slash("snooze")
        wow.state.lockdown = false
        wow.advance(5)
        assert.are.same({ "Welcome Bob" }, wow.sentTo("GUILD"))
    end)

    it("holds across a reload (it is wall-clock time)", function()
        slash("snooze 30")
        local saved = _G.FriendlyForeverDB
        ns = wow.boot({ db = saved })
        ns.db.guildJoin.messages = { "Welcome {name}" }
        join("Bob-Stone")
        assert.are.equal(0, #wow.sent)
        assert.is_truthy(ns.Announcer.ActiveState():find("snoozed", 1, true))
    end)

    it("ignores a bad snooze time in the saved file", function()
        ns = wow.boot({ db = { snoozeUntil = "soon" } })
        assert.is_nil(ns.db.snoozeUntil)
        assert.is_true(ns.Announcer.IsActive())
    end)

    it("rejects a bad snooze command", function()
        slash("snooze later")
        assert.is_nil(ns.db.snoozeUntil)
    end)
end)
