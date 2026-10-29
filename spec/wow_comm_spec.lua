-- Spec: #32, #37, #36
-- The simulated client's addon messages and its several-clients network,
-- which the hidden channel's tests rely on: if these were wrong, those
-- tests could pass while the addon breaks the game's rules.
local wow = require("spec.support.wow")

local R -- Enum.SendAddonMessageResult

local function send(prefix, text, chatType, target)
    return _G.C_ChatInfo.SendAddonMessage(prefix, text, chatType, target)
end

-- Record CHAT_MSG_ADDON on the live client.
local function listen()
    local got = {}
    local f = _G.CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_ADDON")
    f:SetScript("OnEvent", function(_, _, prefix, text, channel, sender)
        got[#got + 1] = { prefix = prefix, text = text, channel = channel, sender = sender }
    end)
    return got
end

describe("The simulated client's addon messages", function()
    before_each(function()
        wow.boot()
        R = _G.Enum.SendAddonMessageResult
        _G.C_ChatInfo.RegisterAddonMessagePrefix("T")
    end)

    it("registers prefixes of 1 to 16 characters, once each (white, black)", function()
        local P = _G.Enum.RegisterAddonMessagePrefixResult
        local reg = _G.C_ChatInfo.RegisterAddonMessagePrefix
        assert.are.equal(P.Success, reg(string.rep("p", 16)))
        assert.are.equal(P.DuplicatePrefix, reg(string.rep("p", 16)))
        assert.are.equal(P.InvalidPrefix, reg(string.rep("p", 17)))
        assert.are.equal(P.InvalidPrefix, reg(""))
        assert.are.equal(P.InvalidPrefix, reg(5))
    end)

    it("sends a good message and records it (white)", function()
        assert.are.equal(R.Success, send("T", "hi", "GUILD"))
        assert.are.same({ prefix = "T", text = "hi", channel = "GUILD", time = wow.now },
            { prefix = wow.addonSent[1].prefix, text = wow.addonSent[1].text, channel = wow.addonSent[1].channel,
                time = wow.addonSent[1].time })
        assert.are.same({}, wow.addonRefused)
    end)

    it("refuses what the game refuses, with its code, and records why (black)", function()
        local cases = {
            { R.InvalidPrefix, string.rep("p", 17), "hi", "GUILD" },
            { R.InvalidPrefix, "", "hi", "GUILD" },
            { R.InvalidPrefix, 5, "hi", "GUILD" },
            { R.InvalidMessage, "T", string.rep("x", 256), "GUILD" },
            { R.InvalidMessage, "T", "a\0b", "GUILD" },
            { R.InvalidMessage, "T", 42, "GUILD" },
            { R.InvalidChatType, "T", "hi", "SAY" },
            { R.TargetRequired, "T", "hi", "WHISPER" },
            { R.TargetRequired, "T", "hi", "WHISPER", "" },
            { R.NotInGroup, "T", "hi", "PARTY" },
            { R.NotInGroup, "T", "hi", "RAID" },
            { R.NotInGroup, "T", "hi", "INSTANCE_CHAT" },
        }
        for i, c in ipairs(cases) do
            assert.are.equal(c[1], send(c[2], c[3], c[4], c[5]), "case " .. i)
            assert.are.equal(i, #wow.addonRefused)
            assert.are.equal(c[1], wow.addonRefused[i].result)
        end
        assert.are.same({}, wow.addonSent)
        -- The edges that are allowed.
        assert.are.equal(R.Success, send(string.rep("p", 16), string.rep("x", 255), "WHISPER", "Ann-Vale"))
        wow.state.inGuild = false
        assert.are.equal(R.NotInGroup, send("T", "hi", "GUILD"))
    end)

    it("knows which group routes are open (white)", function()
        wow.setGroup("party", { "Ann-Vale" })
        assert.are.equal(R.Success, send("T", "hi", "PARTY"))
        assert.are.equal(R.NotInGroup, send("T", "hi", "RAID"))
        wow.setGroup("raid", { "Ann-Vale" })
        assert.are.equal(R.Success, send("T", "hi", "RAID"))
        assert.are.equal(R.Success, send("T", "hi", "PARTY"))
        wow.setGroup("instance", { "Ann-Vale" })
        assert.are.equal(R.Success, send("T", "hi", "INSTANCE_CHAT"))
        assert.are.equal(R.NotInGroup, send("T", "hi", "PARTY"))
    end)

    it("refuses everything in lockdown or where addon messages are blocked (black)", function()
        wow.state.lockdown = true
        assert.are.equal(R.GeneralError, send("T", "hi", "GUILD"))
        wow.state.lockdown = false
        wow.state.addonBlocked = true
        assert.are.equal(R.GeneralError, send("T", "hi", "GUILD"))
        assert.are.same({}, wow.addonSent)
    end)

    it("throttles each prefix as the game does: 10 at once, then one a second (black)", function()
        for _ = 1, 10 do assert.are.equal(R.Success, send("T", "hi", "GUILD")) end
        assert.are.equal(R.AddonMessageThrottle, send("T", "hi", "GUILD"))
        assert.are.equal(R.Success, send("U", "hi", "GUILD"), "another prefix has its own allowance")
        wow.advance(1)
        assert.are.equal(R.Success, send("T", "hi", "GUILD"))
        assert.are.equal(R.AddonMessageThrottle, send("T", "hi", "GUILD"))
        wow.advance(2)
        assert.are.equal(R.Success, send("T", "hi", "GUILD"))
        assert.are.equal(R.Success, send("T", "hi", "GUILD"))
        assert.are.equal(R.AddonMessageThrottle, send("T", "hi", "GUILD"))
        wow.advance(100)
        for _ = 1, 10 do assert.are.equal(R.Success, send("T", "hi", "GUILD")) end
        assert.are.equal(R.AddonMessageThrottle, send("T", "hi", "GUILD"), "never more than 10 saved up")
    end)

    it("has no addon messages at all in a client without them (black)", function()
        wow.boot({ before = function(s) s.noAddonMessages = true end })
        assert.has_error(function() _G.C_ChatInfo.RegisterAddonMessagePrefix("T") end)
        assert.has_error(function() send("T", "hi", "GUILD") end)
    end)
end)

describe("The simulated network of clients", function()
    local a, b, c, net, heard

    -- Ann and Bo in a party, Cid on his own; all in the guild; all listening
    -- on prefix "T".
    before_each(function()
        heard = {}
        local function setup(name, group)
            return function(state)
                if group then wow.setGroup("party", group) end
                state.marker = name
            end
        end
        a = wow.newClient({ name = "Ann", surname = "Vale", before = setup("a", { "Bo-Lake" }) })
        _G.C_ChatInfo.RegisterAddonMessagePrefix("T")
        heard.a = listen()
        b = wow.newClient({ name = "Bo", surname = "Lake", before = setup("b", { "Ann-Vale" }) })
        _G.C_ChatInfo.RegisterAddonMessagePrefix("T")
        heard.b = listen()
        c = wow.newClient({ name = "Cid", surname = "Rock", before = setup("c") })
        _G.C_ChatInfo.RegisterAddonMessagePrefix("T")
        heard.c = listen()
        net = wow.network({ a, b, c })
    end)

    local function from(client, text, route, target)
        wow.use(client)
        send("T", text, route, target)
        wow.deliver(net)
    end

    it("keeps each client's game apart (white)", function()
        wow.use(a)
        assert.are.equal("a", wow.state.marker)
        assert.are.equal("Ann", (_G.UnitName("player")))
        wow.extraField = 1
        _G.ExtraGlobal = 1
        local dbA = _G.FriendlyForeverDB
        wow.use(b)
        assert.are.equal("b", wow.state.marker)
        assert.are.equal("Bo", (_G.UnitName("player")))
        assert.is_nil(wow.extraField)
        assert.is_nil(_G.ExtraGlobal)
        assert.are_not.equal(dbA, _G.FriendlyForeverDB)
        wow.use(a)
        assert.are.equal(1, wow.extraField)
        assert.are.equal(dbA, _G.FriendlyForeverDB)
        wow.extraField, _G.ExtraGlobal = nil, nil
    end)

    it("delivers a whisper to the player it names, and no one else (white)", function()
        from(a, "w1", "WHISPER", "Bo-Lake")
        from(a, "w2", "WHISPER", "Cid Rock")
        from(a, "w3", "WHISPER", "Ann-Vale")
        assert.are.same({ { prefix = "T", text = "w1", channel = "WHISPER", sender = "Ann-Vale" } }, heard.b)
        assert.are.same({ { prefix = "T", text = "w2", channel = "WHISPER", sender = "Ann-Vale" } }, heard.c)
        assert.are.same({}, heard.a, "not to yourself")
    end)

    it("drops each copy of a message net.lose says to, and only that copy (white, #36)", function()
        local asked = {}
        net.lose = function(msg, sender, receiver)
            asked[#asked + 1] = msg.text .. ":" .. sender.full .. ">" .. receiver.full
            return receiver == b
        end
        from(a, "g", "GUILD")
        from(a, "w", "WHISPER", "Bo-Lake")
        assert.are.same({}, heard.b)
        assert.are.equal(1, #heard.c, "Cid still hears the guild message")
        assert.are.equal(1, #heard.a, "and it still comes back to Ann")
        assert.are.same({ "g:Ann-Vale>Ann-Vale", "g:Ann-Vale>Bo-Lake", "g:Ann-Vale>Cid-Rock",
            "w:Ann-Vale>Bo-Lake" }, asked, "asked only about copies that would arrive")
    end)

    it("delivers a group message to the group and back to its sender, not to others (white)", function()
        from(a, "p", "PARTY")
        assert.are.equal(1, #heard.a)
        assert.are.equal(1, #heard.b)
        assert.are.same({}, heard.c)
    end)

    it("doesn't deliver a group message to someone not in that kind of group (black)", function()
        wow.use(a)
        wow.setGroup("raid", { "Bo-Lake" })
        from(a, "r", "RAID")
        assert.are.equal(1, #heard.a)
        assert.are.same({}, heard.b, "Bo still thinks he's in a party")
    end)

    it("delivers a guild message to everyone in the guild (white)", function()
        wow.use(c)
        wow.state.inGuild = false
        from(a, "g", "GUILD")
        assert.are.equal(1, #heard.a)
        assert.are.equal(1, #heard.b)
        assert.are.same({}, heard.c)
    end)

    it("delivers only prefixes the receiver registered (black)", function()
        wow.use(b)
        _G.C_ChatInfo.RegisterAddonMessagePrefix("Other")
        wow.use(a)
        _G.C_ChatInfo.RegisterAddonMessagePrefix("Other")
        send("Other", "o", "WHISPER", "Cid-Rock")
        send("Other", "o", "WHISPER", "Bo-Lake")
        wow.deliver(net)
        assert.are.same({}, heard.c, "Cid never registered it")
        assert.are.equal("Other", heard.b[1].prefix, "Bo did")
    end)

    it("spells the sender as the receiving client's setting says (white)", function()
        wow.use(b)
        wow.state.addonSenderForm = "space"
        from(a, "p", "PARTY")
        assert.are.equal("Ann Vale", heard.b[1].sender)
        assert.are.equal("Ann-Vale", heard.a[1].sender)
    end)

    it("leaves the live client as it was (white)", function()
        -- Bo, who isn't the last client delivered to.
        wow.use(a)
        send("T", "p", "PARTY")
        wow.use(b)
        wow.deliver(net)
        assert.are.equal("b", wow.state.marker)
        assert.are.equal(1, #heard.b)
        wow.advanceAll(net, 1, 0.5)
        assert.are.equal("b", wow.state.marker)
    end)

    it("moves every clock on together (white)", function()
        wow.use(a)
        local start = wow.now
        wow.advanceAll(net, 2.5, 1)
        for _, client in ipairs({ a, b, c }) do
            wow.use(client)
            assert.are.equal(start + 2.5, wow.now)
        end
        assert.has_error(function() wow.advanceAll(net, 1) end)
        assert.has_error(function() wow.advanceAll(net, 1, 0) end)
        assert.has_error(function() wow.advanceAll(net, 1, -1) end)
    end)

    it("delivers what is sent during advanceAll, answers included (white)", function()
        wow.use(b)
        local f = _G.CreateFrame("Frame")
        f:RegisterEvent("CHAT_MSG_ADDON")
        f:SetScript("OnEvent", function(_, _, _, text)
            if text == "ping" then send("T", "pong", "WHISPER", "Ann-Vale") end
        end)
        wow.use(a)
        _G.C_Timer.After(0.5, function() send("T", "ping", "WHISPER", "Bo-Lake") end)
        wow.advanceAll(net, 1, 1)
        assert.are.equal("pong", heard.a[1] and heard.a[1].text)
    end)

    it("stops two clients that answer each other for ever (black)", function()
        for _, client in ipairs({ a, b }) do
            wow.use(client)
            local f = _G.CreateFrame("Frame")
            f:RegisterEvent("CHAT_MSG_ADDON")
            local other = client == a and "Bo-Lake" or "Ann-Vale"
            f:SetScript("OnEvent", function() wow.addonSent[#wow.addonSent + 1] = {
                prefix = "T", text = "again", channel = "WHISPER", target = other } end)
        end
        assert.has_error(function() from(a, "go", "WHISPER", "Bo-Lake") end,
            "M.deliver: the clients never stopped answering each other")
    end)
end)

describe("Buffs between simulated clients (#37)", function()
    local a, b, c, net
    local MOTW_1 = 1126

    before_each(function()
        a = wow.newClient({ name = "Ann", surname = "Vale", before = function(state)
            state.class, state.knownSpells = "DRUID", { [MOTW_1] = true }
        end })
        b = wow.newClient({ name = "Bo", surname = "Lake", before = function()
            wow.addUnit("nameplate3", { name = "Ann", surname = "Vale", id = "Ann-Vale" })
            wow.addUnit("nameplate2", { name = "Ann", surname = "Vale", id = "Ann-Vale" })
        end })
        c = wow.newClient({ name = "Cid", surname = "Rock" })
        net = wow.network({ a, b, c })
    end)

    local function castOn(target)
        wow.use(a)
        wow.addUnit("target", target)
        wow.runMacro("/cast Mark of the Wild")
    end

    it("records each cast that lands, and none that fails (white)", function()
        castOn({ name = "Bo", surname = "Lake", id = "Bo-Lake" })
        wow.state.castFailures["Bo-Lake"] = "Out of range"
        castOn({ name = "Bo", surname = "Lake", id = "Bo-Lake" })
        assert.are.same({ { spell = "Mark of the Wild", id = MOTW_1, target = "Bo-Lake", at = wow.now } }, wow.landed)
        assert.are.equal(2, #wow.casts)
    end)

    it("records when each cast landed, latency included (white, #36)", function()
        wow.use(a)
        wow.state.castLatency = 0.5
        local sentAt = wow.now
        castOn({ name = "Bo", surname = "Lake", id = "Bo-Lake" })
        assert.are.same({}, wow.landed, "not before the server answers")
        wow.advance(1)
        assert.are.equal(sentAt + 0.5, wow.landed[1].at)
    end)

    it("brings a landed buff to its target only, once, named by its first token showing the caster (white)", function()
        castOn({ name = "Bo", surname = "Lake", id = "Bo-Lake" })
        wow.deliverBuffs(net)
        wow.use(b)
        local aura = wow.state.playerAuras[1]
        wow.deliverBuffs(net)
        wow.use(b)
        assert.are.equal(1, #wow.state.playerAuras)
        assert.are.equal(aura, wow.state.playerAuras[1], "not brought again")
        assert.are.equal("nameplate2", aura.sourceUnit)
        assert.are.equal(MOTW_1, aura.spellId)
        assert.are.equal("Mark of the Wild", aura.name)
        wow.use(c)
        assert.are.equal(0, #wow.state.playerAuras)
        wow.use(a)
        assert.are.equal(0, #wow.state.playerAuras, "not back to its caster")
    end)

    it("names no caster when the target has no unit for them, and replaces a buff it refreshes (white)", function()
        castOn({ name = "Cid", surname = "Rock", id = "Cid-Rock" })
        castOn({ name = "Cid", surname = "Rock", id = "Cid-Rock" })
        wow.deliverBuffs(net)
        wow.use(c)
        assert.are.equal(1, #wow.state.playerAuras)
        assert.is_nil(wow.state.playerAuras[1].sourceUnit)
    end)

    it("never brings a buff on yourself back to you as another's (white)", function()
        wow.use(a)
        castOn(wow.state.units.player)
        assert.are.equal("Ann-Vale", wow.landed[1].target)
        wow.deliverBuffs(net)
        wow.use(a)
        assert.are.equal(0, #wow.state.playerAuras)
    end)

    it("leaves the live client as it was (white)", function()
        castOn({ name = "Bo", surname = "Lake", id = "Bo-Lake" })
        wow.use(c)
        wow.deliverBuffs(net)
        assert.are.equal("Cid", (_G.UnitName("player")))
    end)
end)
