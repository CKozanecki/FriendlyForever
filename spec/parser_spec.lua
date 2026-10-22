local wow = require("spec.support.wow")

describe("Parser", function()
    local Parser

    before_each(function()
        wow.reset()
        Parser = wow.load().Parser
    end)

    local function parse(msg) return { Parser.Parse(msg) } end

    it("recognises a guild member coming online", function()
        assert.are.same({ "guildOnline", "Thrall" }, parse("|Hplayer:Thrall|h[Thrall]|h has come online."))
    end)

    it("recognises guild joins", function()
        assert.are.same({ "guildJoin", "Jaina" }, parse("Jaina has joined the guild."))
    end)

    it("recognises party, raid and instance group joins", function()
        assert.are.same({ "partyJoin", "Anduin" }, parse("Anduin joins the party."))
        assert.are.same({ "partyJoin", "Sylvanas" }, parse("Sylvanas has joined the raid group."))
        assert.are.same({ "partyJoin", "Varian" }, parse("Varian has joined the instance group."))
    end)

    it("ignores unrelated and look-alike messages", function()
        assert.are.same({}, parse("Anduin has left the party."))
        assert.are.same({}, parse("You have joined the guild."))
        assert.are.same({}, parse(""))
    end)

    it("ignores messages whose captured name is not a plausible player", function()
        assert.are.same({}, parse("Some Guy Here has joined the guild."))
        assert.are.same({}, parse("|cffff0000Evil|r has joined the guild."))
    end)

    it("ignores secret and non-string messages", function()
        assert.are.same({}, parse(wow.secret("Anduin joins the party.")))
        assert.are.same({}, parse(nil))
        assert.are.same({}, parse(42))
    end)

    it("uses the client's localized strings", function()
        _G.ERR_GUILD_JOIN_S = "%s ist der Gilde beigetreten."
        Parser.Build()
        assert.are.same({ "guildJoin", "Hans" }, parse("Hans ist der Gilde beigetreten."))
    end)

    it("copes with a client that lacks one of the strings", function()
        _G.ERR_INSTANCE_GROUP_ADDED_S = nil
        Parser.Build()
        assert.are.same({ "partyJoin", "Anduin" }, parse("Anduin joins the party."))
    end)
end)
