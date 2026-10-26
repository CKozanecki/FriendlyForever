-- The favour ledger and the /thank emote: what Buff Thanks remembers and the
-- other way it can say thank you.
local wow = require("spec.support.wow")

local function bootBuffs(db)
    local ns = wow.boot({ db = db })
    ns.db.buff.messages = { "Thank you for the {buff}, {name}!" }
    return ns
end

local function stranger(token, name, surname, class)
    wow.addUnit(token, { name = name, surname = surname, class = class })
end

describe("Favour ledger", function()
    local ns

    local function settle()
        wow.advance(ns.db.buff.delay + 0.01)
        wow.keyDown()
    end

    before_each(function() ns = bootBuffs() end)

    it("records who buffed you, with what, and that you thanked them", function()
        stranger("target", "Bob", "Stone")
        local at = _G.time()
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        local entry = ns.db.ledger.entries[1]
        assert.are.equal("pending", entry.result)
        settle()
        assert.are.equal("Bob-Stone", entry.who)
        assert.are.same({ "Arcane Intellect" }, entry.buffs)
        assert.are.equal("thanked", entry.result)
        assert.are.equal(at, entry.t)
        local s = ns.Ledger.Summary()
        assert.are.same({ 1, 1, 1, 1 }, { s.todayReceived, s.todayThanked, s.received, s.thanked })
    end)

    it("puts buffs from one caster before the thanks into one entry", function()
        stranger("target", "Bob", "Stone")
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        wow.gainBuff({ sourceUnit = "target", name = "Dampen Magic" })
        settle()
        assert.are.equal(1, #ns.db.ledger.entries)
        assert.are.same({ "Arcane Intellect", "Dampen Magic" }, ns.db.ledger.entries[1].buffs)
    end)

    it("records a favour it didn't thank, and why", function()
        stranger("target", "Bob", "Stone")
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        settle()
        wow.advance(30)
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        settle()
        local second = ns.db.ledger.entries[2]
        assert.are.equal("not thanked", second.result)
        assert.are.equal("thanked them a moment ago", second.note)
        assert.are.equal(2, ns.Ledger.Summary().received)
        assert.are.equal(1, ns.Ledger.Summary().thanked)
    end)

    it("records a /say thanks that never got its key press", function()
        stranger("target", "Bob", "Stone")
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        wow.advance(ns.db.buff.delay + 60)
        local entry = ns.db.ledger.entries[1]
        assert.are.equal("not thanked", entry.result)
        assert.are.equal("no key press in time", entry.note)
    end)

    it("records someone it can't name as unnamed", function()
        wow.gainBuff({ name = "Mark of the Wild" })
        settle()
        local entry = ns.db.ledger.entries[1]
        assert.are.equal(ns.Ledger.UNKNOWN, entry.who)
        assert.are.equal("thanked", entry.result)
        assert.is_truthy(ns.Ledger.Lines(1)[1]:find("^Someone unnamed"))
    end)

    it("records nothing while Buff Thanks is off (it doesn't watch buffs then)", function()
        ns.db.buff.enabled = false
        stranger("target", "Bob", "Stone")
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        settle()
        assert.are.equal(0, #ns.db.ledger.entries)
    end)

    it("records a favour while snoozed, as not thanked", function()
        ns.Announcer.Snooze(15)
        stranger("target", "Bob", "Stone")
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        settle()
        assert.are.equal(0, #wow.sent)
        assert.are.equal("not thanked", ns.db.ledger.entries[1].result)
        assert.are.equal("snoozed", ns.db.ledger.entries[1].note)
    end)

    it("never records group members", function()
        wow.setGroup("party", { "Pal-Friend" })
        wow.gainBuff({ sourceUnit = "party1", name = "Fort" })
        settle()
        assert.are.equal(0, #ns.db.ledger.entries)
    end)

    it("starts today's count afresh on a new day, keeping the totals", function()
        stranger("target", "Bob", "Stone")
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        settle()
        wow.state.today = "2026-10-27"
        local s = ns.Ledger.Summary()
        assert.are.same({ 0, 0, 1, 1 }, { s.todayReceived, s.todayThanked, s.received, s.thanked })
    end)

    it("keeps at most MAX_ENTRIES, dropping the oldest, while totals keep counting", function()
        for i = 1, ns.Ledger.MAX_ENTRIES + 5 do
            ns.Ledger.Received("Bob-Stone", "Buff " .. i)
        end
        assert.are.equal(ns.Ledger.MAX_ENTRIES, #ns.db.ledger.entries)
        assert.are.equal("Buff 6", ns.db.ledger.entries[1].buffs[1])
        assert.are.equal(ns.Ledger.MAX_ENTRIES + 5, ns.Ledger.Summary().received)
    end)

    it("lists entries newest first, with how long ago", function()
        ns.Ledger.Settle(ns.Ledger.Received("Bob-Stone", "Arcane Intellect"), true)
        wow.advance(7 * 60)
        ns.Ledger.Settle(ns.Ledger.Received("Ann-Vale", "Thorns"), false, "you were AFK")
        assert.are.same({
            "Ann Vale - Thorns - not thanked (you were AFK) - just now",
            "Bob Stone - Arcane Intellect - thanked - 7 min ago",
        }, ns.Ledger.Lines(5))
    end)

    it("says how long ago in words", function()
        assert.are.equal("just now", ns.Ledger.Ago(59))
        assert.are.equal("2 hr ago", ns.Ledger.Ago(2 * 3600 + 5))
        assert.are.equal("yesterday", ns.Ledger.Ago(86400 + 1))
        assert.are.equal("3 days ago", ns.Ledger.Ago(3 * 86400))
    end)

    it("survives a reload, and a pending favour becomes not thanked", function()
        stranger("target", "Bob", "Stone")
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        ns = bootBuffs(_G.FriendlyForeverDB)
        local entry = ns.db.ledger.entries[1]
        assert.are.equal("Bob-Stone", entry.who)
        assert.are.equal("not thanked", entry.result)
    end)

    it("repairs a damaged ledger in the saved file", function()
        ns = bootBuffs({ ledger = {
            entries = {
                { t = 5, who = "Bob-Stone", buffs = { "Thorns", 7, "Bad|Name" }, result = "thanked" },
                { t = "x", who = "Ann-Vale" },
                { t = 6, who = "<script>" },
                "junk",
                { t = 7, who = "Ann-Vale", result = "weird", note = string.rep("n", 500) },
            },
            totals = { received = -4, thanked = "lots" },
            today = { day = 3 },
        } })
        local entries = ns.db.ledger.entries
        assert.are.equal(2, #entries)
        assert.are.same({ "Thorns", "BadName" }, entries[1].buffs)
        assert.are.equal("not thanked", entries[2].result)
        assert.are.equal(ns.Ledger.MAX_TEXT, #entries[2].note)
        assert.are.same({ received = 0, thanked = 0 }, ns.db.ledger.totals)
    end)

    it("prints with /friendly ledger and clears with /friendly ledger clear", function()
        ns.Ledger.Settle(ns.Ledger.Received("Bob-Stone", "Arcane Intellect"), true)
        _G.SlashCmdList.FRIENDLYFOREVER("ledger")
        local all = table.concat(wow.printed, "\n")
        assert.is_truthy(all:find("today: buffed by 1, thanked 1", 1, true))
        assert.is_truthy(all:find("Bob Stone - Arcane Intellect - thanked", 1, true))
        _G.SlashCmdList.FRIENDLYFOREVER("ledger clear")
        assert.are.equal(0, #ns.db.ledger.entries)
        assert.are.equal(0, ns.Ledger.Summary().received)
    end)
end)

describe("Thank emote", function()
    local ns

    before_each(function() ns = bootBuffs() end)

    local function settle()
        wow.advance(ns.db.buff.delay + 0.01)
        wow.keyDown()
    end

    it("is off by default: thanks are a line", function()
        assert.are.equal("message", ns.db.buff.thankStyle)
    end)

    it("/thanks the caster instead of a line, aimed at their unit, on a key press", function()
        ns.db.buff.thankStyle = "emote"
        stranger("nameplate3", "Bob", "Stone")
        wow.gainBuff({ sourceUnit = "nameplate3", name = "Arcane Intellect" })
        wow.advance(ns.db.buff.delay + 0.01)
        assert.are.equal(0, #wow.emotes, "waits for a key press, like /say")
        wow.keyDown()
        assert.are.equal(0, #wow.sent)
        assert.are.equal(1, #wow.emotes)
        assert.are.equal("THANK", wow.emotes[1].token)
        assert.are.equal("nameplate3", wow.emotes[1].target)
        assert.are.equal("thanked", ns.db.ledger.entries[1].result)
    end)

    it("sends both a line and an emote with 'both'", function()
        ns.db.buff.thankStyle = "both"
        stranger("target", "Bob", "Stone")
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        settle()
        wow.advance(2)
        wow.keyDown()
        assert.are.same({ "Thank you for the Arcane Intellect, Bob!" }, wow.sentTo("SAY"))
        assert.are.equal(1, #wow.emotes)
        assert.are.equal(1, ns.Ledger.Summary().thanked, "one favour, thanked once")
    end)

    it("makes a plain /thank when the unit is now someone else", function()
        ns.db.buff.thankStyle = "emote"
        stranger("nameplate3", "Bob", "Stone")
        wow.gainBuff({ sourceUnit = "nameplate3", name = "Arcane Intellect" })
        stranger("nameplate3", "Ann", "Vale")
        settle()
        assert.are.equal(1, #wow.emotes)
        assert.is_nil(wow.emotes[1].target)
    end)

    it("makes a plain /thank for someone it can't name", function()
        ns.db.buff.thankStyle = "emote"
        wow.gainBuff({ name = "Mark of the Wild" })
        settle()
        assert.are.equal(1, #wow.emotes)
        assert.is_nil(wow.emotes[1].target)
    end)

    it("doesn't repeat to the same caster within the repeat cooldown", function()
        ns.db.buff.thankStyle = "emote"
        stranger("target", "Bob", "Stone")
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        settle()
        wow.gainBuff({ sourceUnit = "target", name = "Dampen Magic" })
        settle()
        assert.are.equal(1, #wow.emotes)
    end)

    it("counts an emote the game held back as not thanked", function()
        ns.db.buff.thankStyle = "emote"
        _G.C_ChatInfo.PerformEmote = function() return true end
        stranger("target", "Bob", "Stone")
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        settle()
        assert.are.equal("not thanked", ns.db.ledger.entries[1].result)
        assert.are.equal("the game refused it", ns.db.ledger.entries[1].note)
    end)

    it("works without the emote function, as not thanked", function()
        ns.db.buff.thankStyle = "emote"
        _G.C_ChatInfo.PerformEmote = nil
        stranger("target", "Bob", "Stone")
        wow.gainBuff({ sourceUnit = "target", name = "Arcane Intellect" })
        settle()
        assert.are.equal("not thanked", ns.db.ledger.entries[1].result)
        assert.are.equal(0, #wow.errors)
    end)

    it("repairs a bad thank style in the saved file", function()
        ns = bootBuffs({ buff = { thankStyle = "dance" } })
        assert.are.equal("message", ns.db.buff.thankStyle)
    end)
end)
