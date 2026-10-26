-- WoW Forever names are a first name plus a mandatory surname, and the pair
-- is the player's identity. These tests use names in both shapes the client
-- may report them: "First-Surname" in one string, or the first name with the
-- surname as UnitName's second return.
local wow = require("spec.support.wow")

describe("Forever first name + surname", function()
    local ns

    local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

    local function settle()
        wow.advance(ns.db.buff.delay + 0.01)
        wow.keyDown()
    end

    before_each(function()
        ns = wow.boot({ before = function(state)
            state.units.player = { name = "Nikki-Shifts", id = "Nikki-Shifts", isPlayer = true }
            state.guildRoster = { "Thrall-Stormcaller", "Thrall-Ironfist" }
        end })
        wow.fire("GUILD_ROSTER_UPDATE")
        for _, msgType in ipairs(ns.Config.TYPES) do
            ns.db[msgType].messages = { ns.CasualMessages[msgType][1] } -- fixed wording
        end
    end)

    describe("self-test", function()
        it("whispers your full name", function()
            slash("selftest")
            assert.are.equal("Nikki-Shifts", wow.sent[1].target)
        end)

        it("whispers your full name when the surname comes separately", function()
            wow.state.units.player = { name = "Nikki", surname = "Shifts", id = "me", isPlayer = true }
            slash("selftest")
            assert.are.equal("Nikki-Shifts", wow.sent[1].target)
        end)
    end)

    describe("buff thanks", function()
        before_each(function() ns.db.buff.messages = { "Thank you for the {buff}, {name}!" } end)

        it("addresses the caster by first name", function()
            wow.addUnit("target", { name = "Bob-Brightwood" })
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            settle()
            assert.are.same({ "Thank you for the Fort, Bob!" }, wow.sentTo("SAY"))
        end)

        it("whispers the caster's full name", function()
            ns.db.buff.useWhisper = true
            wow.addUnit("target", { name = "Bob", surname = "Brightwood" })
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(ns.db.buff.delay + 0.01)
            assert.are.equal("Bob-Brightwood", wow.sent[1].target)
            assert.are.equal("Thank you for the Fort, Bob!", wow.sent[1].text)
        end)

        it("supports {fullname}", function()
            ns.db.buff.messages = { "Thanks, {fullname}!" }
            wow.addUnit("target", { name = "Bob-Brightwood" })
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            settle()
            assert.are.same({ "Thanks, Bob Brightwood!" }, wow.sentTo("SAY"))
        end)

        it("treats two people with the same first name as different people", function()
            wow.addUnit("target", { name = "Bob-Brightwood" })
            wow.addUnit("nameplate1", { name = "Bob-Ashford" })
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Int" })
            settle()
            wow.advance(2)
            wow.keyDown()
            assert.are.equal(2, #wow.sentTo("SAY"), "the repeat cooldown is per full name")
        end)

        it("never thanks yourself", function()
            wow.addUnit("target", { name = "Nikki-Shifts", id = "Nikki-Shifts" })
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            settle()
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't thank a groupmate who shares your first name only by first name", function()
            wow.state.groupType = "party"
            wow.state.groupMembers["Bob-Brightwood"] = true
            wow.addUnit("party1", { name = "Bob-Brightwood" })
            wow.addUnit("target", { name = "Bob-Ashford" })
            wow.gainBuff({ sourceUnit = "party1", name = "Fort" })
            wow.gainBuff({ sourceUnit = "target", name = "Int" })
            settle()
            assert.are.same({ "Thank you for the Int, Bob!" }, wow.sentTo("SAY"))
        end)
    end)

    describe("guild", function()
        local function online(link, shown)
            wow.systemMessage("|Hplayer:" .. link .. "|h[" .. (shown or link) .. "]|h has come online.")
        end

        it("greets a member by first name, matched on the full name", function()
            online("Thrall-Stormcaller", "Thrall Stormcaller")
            wow.advance(10)
            assert.are.same({ "Thrall has logged in. Quick, everyone look busy." }, wow.sentTo("GUILD"))
        end)

        it("keeps members with the same first name apart", function()
            online("Thrall-Stormcaller")
            wow.advance(5)
            online("Thrall-Ironfist")
            wow.advance(5)
            assert.are.equal(2, #wow.sentTo("GUILD"), "different people, separate cooldowns")
        end)

        it("doesn't treat a friend as a guild member just for sharing a first name", function()
            online("Thrall-Wanderer")
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("welcomes a new member and recognises them at their next login", function()
            wow.systemMessage("Jaina-Proudmoore has joined the guild.")
            wow.advance(10)
            online("Jaina-Proudmoore")
            wow.advance(10)
            assert.are.same({ "Welcome to the guild, Jaina! We're glad to have you.", "Jaina has logged in. Quick, everyone look busy." },
                wow.sentTo("GUILD"))
        end)

        it("doesn't greet yourself", function()
            wow.state.guildRoster[#wow.state.guildRoster + 1] = "Nikki-Shifts"
            wow.fire("GUILD_ROSTER_UPDATE")
            online("Nikki-Shifts")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)
    end)

    describe("party", function()
        it("welcomes by first name and checks membership by full name", function()
            wow.setGroup("party", { "Anduin-Wrynn" })
            wow.systemMessage("Anduin-Wrynn joins the party.")
            wow.advance(10)
            assert.are.same({ "Welcome to the group, Anduin!" }, wow.sentTo("PARTY"))
        end)

        it("handles a join message that shows the name with a space", function()
            wow.setGroup("party", { "Anduin-Wrynn" })
            wow.systemMessage("Anduin Wrynn joins the party.")
            wow.advance(10)
            assert.are.same({ "Welcome to the group, Anduin!" }, wow.sentTo("PARTY"))
        end)
    end)

    it("/friendly names shows what the game returns and what the addon uses", function()
        slash("names")
        local all = table.concat(wow.printed, "\n")
        assert.is_truthy(all:find("UnitName(player): 'Nikki-Shifts'", 1, true))
        assert.is_truthy(all:find("Friendly Forever uses: 'Nikki-Shifts'", 1, true))
        assert.is_truthy(all:find("guild roster #1: 'Thrall-Stormcaller'", 1, true))
    end)
end)
