-- Spec: #496
-- Guild leader controls, part 2: the caps and vetoes take effect. A
-- leader's caps lower every copy's guild hellos and welcomes (a player's
-- own lower setting stays), guild hellos can be turned off, a vetoed line
-- is never said again by any copy, and each copy reports the guild lines it
-- said so a leader's copy can list them.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local LOGIN, JOINER = "Thrall", "Newbie"
local GM = { name = "Gina", surname = "Moss" }
local MEMBERS = {
    { name = "Ann", surname = "Vale" }, { name = "Bo", surname = "Lake" }, { name = "Cid", surname = "Moor" },
    { name = "Dee", surname = "Fell" }, { name = "Eli", surname = "Dale" },
}

-- Lines that each name whom they greet and their own number.
local function Lines(word)
    local out = {}
    for i = 1, 30 do out[i] = word .. " {fullname} #" .. i end
    return out
end

-- The test's own hash of a custom line's text, as the token grammar names it
-- ("c" and eight hex digits of a djb2 hash, mod 2^32), written apart from
-- GuildLead so a wrong hash there is caught.
local function Token(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
    return "c" .. string.format("%04x%04x", math.floor(h / 65536), h % 65536)
end

-- The guild master's copy and n members' copies, each with the given own
-- greeter setting, the roster read, and a network carrying what they send.
local function Guild(n, opts)
    opts = opts or {}
    local people = { GM }
    for i = 1, n do people[#people + 1] = MEMBERS[i] end
    local roster = { LOGIN }
    for _, p in ipairs(people) do roster[#roster + 1] = p.name .. "-" .. p.surname end
    for _, name in ipairs(opts.alsoInRoster or {}) do roster[#roster + 1] = name end
    local clients = {}
    for i, p in ipairs(people) do
        local db = { guildLogin = { messages = Lines("Hi"), maxGreeters = opts.own or 5 },
            guildJoin = { messages = Lines("Welcome") } }
        local c = wow.newClient({ name = p.name, surname = p.surname, db = db, guildSync = opts.sync,
            before = function(state)
                state.guildRoster = roster
                state.guildRanks["Gina-Moss"] = 0
            end })
        c.ns.db.guildLogin.messages = Lines("Hi")
        c.ns.db.guildJoin.messages = Lines("Welcome")
        c.ns.Messages.random = random.random
        c.ns.GuildHellos.random = random.random
        c.ns.GuildLead.random = function() return 0 end
        wow.fire("GUILD_ROSTER_UPDATE")
        clients[i] = c
    end
    local net = wow.network(clients)
    return clients, net
end

local function on(c, fn)
    wow.use(c)
    return fn(c.ns)
end

-- The guild master sets a section, and every copy has it.
local function Lead(clients, net, section, items)
    assert.is_true(on(clients[1], function(ns) return ns.GuildLead.Set(section, items) end))
    wow.advanceAll(net, 5, 0.5)
end

local function Arrive(clients, name, line)
    for _, c in ipairs(clients) do
        wow.use(c)
        wow.systemMessage(line or ("|Hplayer:" .. name .. "|h[" .. name .. "]|h has come online."))
    end
end

-- Every guild chat line any copy sent that names this guildmate: { client, text }.
local function Said(clients, name)
    local out = {}
    for _, c in ipairs(clients) do
        wow.use(c)
        for _, s in ipairs(wow.sent) do
            if s.channel == "GUILD" and s.text:find(name, 1, true) then out[#out + 1] = { client = c, text = s.text } end
        end
    end
    return out
end

describe("Guild leader controls: the caps and vetoes take effect (#496)", function()
    before_each(function() random.seed(496) end)
    after_each(function() wow.reset() end)

    describe("caps (white)", function()
        it("a leader's greeter cap lowers how many copies greet one login", function()
            local clients, net = Guild(5)
            Lead(clients, net, "caps", { "g2" })
            Arrive(clients, LOGIN)
            wow.advanceAll(net, 60, 0.1)
            assert.are.equal(2, #Said(clients, LOGIN))
        end)

        it("a copy that heard the guild's cap of announcements before its turn announces nothing", function()
            local clients, net = Guild(1)
            Lead(clients, net, "caps", { "g1" })
            clients[1].ns.GuildHellos.random = function() return 0 end
            clients[2].ns.GuildHellos.random = function() return 0.9 end
            local before = on(clients[2], function() return #wow.addonSent end)
            Arrive(clients, LOGIN)
            wow.advanceAll(net, 60, 0.1)
            assert.are.equal(1, #Said(clients, LOGIN))
            on(clients[2], function()
                for i = before + 1, #wow.addonSent do
                    assert.is_nil(wow.addonSent[i].text:find(";GREET;", 1, true))
                end
            end)
        end)

        it("a player's own lower setting stays under a higher cap", function()
            local clients, net = Guild(5, { own = 1 })
            Lead(clients, net, "caps", { "g3" })
            Arrive(clients, LOGIN)
            wow.advanceAll(net, 60, 0.1)
            assert.are.equal(1, #Said(clients, LOGIN))
            assert.are.equal(1, on(clients[2], function(ns) return ns.GuildHellos.Cap("guildLogin") end))
        end)

        it("guild hellos off: no copy greets; on again: they do", function()
            local clients, net = Guild(3)
            Lead(clients, net, "caps", { "h0" })
            local before = {}
            for _, c in ipairs(clients) do
                wow.use(c)
                before[c] = #wow.addonSent
            end
            Arrive(clients, LOGIN)
            wow.advanceAll(net, 60, 0.1)
            assert.are.equal(0, #Said(clients, LOGIN))
            for _, c in ipairs(clients) do
                wow.use(c)
                for i = before[c] + 1, #wow.addonSent do
                    assert.is_nil(wow.addonSent[i].text:find(";GREET;", 1, true), "nor announces a hello")
                end
            end
            Lead(clients, net, "caps", {})
            wow.advanceAll(net, 600, 1) -- past the repeat cooldown
            Arrive(clients, LOGIN)
            wow.advanceAll(net, 60, 0.1)
            assert.is_true(#Said(clients, LOGIN) >= 1)
        end)

        it("hellos turned off while a hello waits: it isn't said", function()
            local clients, net = Guild(2)
            Arrive(clients, LOGIN)
            wow.advanceAll(net, 5, 0.5)
            Lead(clients, net, "caps", { "h0" })
            wow.advanceAll(net, 60, 0.1)
            assert.are.equal(0, #Said(clients, LOGIN))
        end)

        it("a leader's welcome cap: at most that many copies welcome a new member", function()
            local clients, net = Guild(5)
            Lead(clients, net, "caps", { "w2" })
            Arrive(clients, JOINER, JOINER .. " has joined the guild.")
            wow.advanceAll(net, 60, 0.1)
            local said = Said(clients, JOINER)
            assert.are.equal(2, #said)
            assert.are_not.equal(said[1].text, said[2].text, "with different lines")
        end)

        it("capped welcomes wait the welcome delay and a random while more, as guild hellos do", function()
            local clients, net = Guild(3)
            Lead(clients, net, "caps", { "w1" })
            for _, c in ipairs(clients) do c.ns.GuildHellos.random = function() return 0.5 end end
            local joinedAt = wow.now
            Arrive(clients, JOINER, JOINER .. " has joined the guild.")
            wow.advanceAll(net, 60, 0.1)
            local first
            for _, c in ipairs(clients) do
                wow.use(c)
                for _, sent in ipairs(wow.sent) do
                    if sent.channel == "GUILD" and sent.text:find(JOINER, 1, true) then first = first or sent.time end
                end
            end
            local wait = clients[1].ns.db.guildJoin.delay + clients[1].ns.GuildHellos.Stagger()
            assert.is_true(first - joinedAt >= wait - 0.2, string.format("%.1f s, at least %.1f", first - joinedAt, wait))
        end)

        it("capped welcomes keep different lines when your guild hello lines are all blank", function()
            local clients, net = Guild(1)
            Lead(clients, net, "caps", { "w2" })
            for _, c in ipairs(clients) do
                c.ns.db.guildLogin.messages = { "" }
                c.ns.db.guildJoin.messages = { "Welcome {fullname} A", "Welcome {fullname} B", "Welcome {fullname} C" }
                c.ns.Messages.random = function(n) return n end
                c.ns.GuildHellos.random = function() return 0 end
            end
            Arrive(clients, JOINER, JOINER .. " has joined the guild.")
            wow.advanceAll(net, 60, 0.1)
            local said = Said(clients, JOINER)
            assert.are.equal(2, #said)
            assert.are_not.equal(said[1].text, said[2].text)
        end)

        it("capped welcomes pass over a line another copy took when their zone can't be read", function()
            local clients, net = Guild(1)
            Lead(clients, net, "caps", { "w2" })
            -- Ann announces first, her last line, C. The guild master's last line
            -- needs {zone}, which can't be read, so another is said in its place:
            -- not C, which Ann took, though C is next in the guild master's bag.
            local gm, ann = clients[1], clients[2]
            gm.ns.db.guildJoin.messages = { "Welcome {fullname} A", "Welcome {fullname} B", "Welcome {fullname} C",
                "Welcome {fullname}, all the way from {zone}" }
            ann.ns.db.guildJoin.messages = { "Welcome {fullname} A", "Welcome {fullname} B", "Welcome {fullname} C" }
            for _, c in ipairs(clients) do c.ns.Messages.random = function(n) return n end end
            ann.ns.GuildHellos.random = function() return 0 end
            gm.ns.GuildHellos.random = function() return 0.5 end
            Arrive(clients, JOINER, JOINER .. " has joined the guild.")
            wow.advanceAll(net, 60, 0.1)
            local said = Said(clients, JOINER)
            assert.are.equal(2, #said)
            assert.are_not.equal(said[1].text, said[2].text)
            for _, s in ipairs(said) do assert.is_nil(s.text:find("from", 1, true)) end
        end)

        it("without a welcome cap every copy welcomes, as before", function()
            local clients, net = Guild(3)
            Arrive(clients, JOINER, JOINER .. " has joined the guild.")
            wow.advanceAll(net, 60, 0.1)
            assert.are.equal(4, #Said(clients, JOINER))
        end)

        it("a cap lifted: back to the player's own setting", function()
            local clients, net = Guild(4)
            Lead(clients, net, "caps", { "g1" })
            assert.are.equal(1, on(clients[2], function(ns) return ns.GuildHellos.Cap("guildLogin") end))
            Lead(clients, net, "caps", { "g4", "w3" })
            assert.are.equal(4, on(clients[2], function(ns) return ns.GuildHellos.Cap("guildLogin") end))
            assert.are.equal(3, on(clients[2], function(ns) return ns.GuildHellos.Cap("guildJoin") end))
            Lead(clients, net, "caps", {})
            assert.are.equal(5, on(clients[2], function(ns) return ns.GuildHellos.Cap("guildLogin") end))
            assert.are.equal(math.huge, on(clients[2], function(ns) return ns.GuildHellos.Cap("guildJoin") end))
        end)
    end)

    describe("vetoes (white)", function()
        -- Each copy has only two lines, the first vetoed: every hello uses the second.
        local function TwoLines(clients, kind, first, second)
            for _, c in ipairs(clients) do
                wow.use(c)
                c.ns.db[kind].messages = { first, second }
            end
        end

        it("a vetoed custom line is never said by any copy, by its exact text", function()
            local clients, net = Guild(3)
            TwoLines(clients, "guildLogin", "Hi {fullname} vetoed", "Hi {fullname} kept")
            Lead(clients, net, "vetoes", { Token("Hi {fullname} vetoed") })
            Arrive(clients, LOGIN)
            wow.advanceAll(net, 60, 0.1)
            local said = Said(clients, LOGIN)
            assert.is_true(#said >= 1)
            for _, s in ipairs(said) do assert.are.equal("Hi Thrall kept", s.text) end
        end)

        it("a vetoed built-in line is never said, by its ID, while an edited copy of it is another line", function()
            local clients, net = Guild(2)
            local wow1 = on(clients[1], function(ns) return ns.CasualMessages.guildJoin[1] end)
            TwoLines(clients, "guildJoin", wow1, wow1 .. " Glad you're here.")
            Lead(clients, net, "vetoes", { "bjc1" })
            Arrive(clients, JOINER, JOINER .. " has joined the guild.")
            wow.advanceAll(net, 60, 0.1)
            local said = Said(clients, JOINER)
            assert.are.equal(3, #said)
            for _, s in ipairs(said) do assert.is_truthy(s.text:find("Glad you're here.", 1, true)) end
        end)

        it("two copies that announce the same line at once: the second passes over vetoed lines to one it can say", function()
            local clients, net = Guild(1)
            TwoLines(clients, "guildLogin", "Hi {fullname} v1", "Hi {fullname} v2")
            for _, c in ipairs(clients) do
                table.insert(c.ns.db.guildLogin.messages, "Hi {fullname} said")
                c.ns.Messages.random = function(n) return n end
                c.ns.GuildHellos.random = function() return 0 end
            end
            Lead(clients, net, "vetoes", { Token("Hi {fullname} v1"), Token("Hi {fullname} v2") })
            Arrive(clients, LOGIN)
            wow.advanceAll(net, 60, 0.1)
            local said = Said(clients, LOGIN)
            assert.are.equal(2, #said, "both still greet")
            for _, s in ipairs(said) do assert.are.equal("Hi Thrall said", s.text) end
        end)

        it("every line vetoed: nothing is said", function()
            local clients, net = Guild(2)
            TwoLines(clients, "guildLogin", "Hi {fullname} one", "Hi {fullname} two")
            Lead(clients, net, "vetoes", { Token("Hi {fullname} one"), Token("Hi {fullname} two") })
            Arrive(clients, LOGIN)
            wow.advanceAll(net, 60, 0.1)
            assert.are.equal(0, #Said(clients, LOGIN))
            assert.are.same({}, wow.errors)
        end)

        it("a line vetoed while it waits to be said isn't said", function()
            local clients, net = Guild(1)
            TwoLines(clients, "guildLogin", "Hi {fullname} only", "")
            Arrive(clients, LOGIN)
            wow.advanceAll(net, 5, 0.5)
            Lead(clients, net, "vetoes", { Token("Hi {fullname} only") })
            wow.advanceAll(net, 60, 0.1)
            assert.are.equal(0, #Said(clients, LOGIN))
        end)

        it("a copy that was offline when the veto was made never says it either", function()
            local clients, net = Guild(2, { alsoInRoster = { "Cid-Moor" } })
            Lead(clients, net, "vetoes", { Token("Hi {fullname} vetoed") })
            -- Cid's copy starts now: it has never heard the veto.
            local cid = wow.newClient({ name = "Cid", surname = "Moor", guildSync = true,
                db = { guildLogin = { messages = { "Hi {fullname} vetoed", "Hi {fullname} kept" } } },
                before = function(state)
                    state.guildRoster = { LOGIN, "Gina-Moss", "Ann-Vale", "Bo-Lake", "Cid-Moor" }
                    state.guildRanks["Gina-Moss"] = 0
                end })
            cid.ns.db.guildLogin.messages = { "Hi {fullname} vetoed", "Hi {fullname} kept" }
            cid.ns.GuildLead.random = function() return 0 end
            assert.is_false(cid.ns.GuildLead.IsVetoed(Token("Hi {fullname} vetoed")))
            wow.fire("GUILD_ROSTER_UPDATE")
            net = wow.network({ clients[1], clients[2], clients[3], cid })
            for _, c in ipairs({ clients[1], clients[2], clients[3], cid }) do
                wow.use(c)
                net.seen[c], net.chatSeen[c] = #wow.addonSent, #wow.sent
            end
            -- Cid's check-in, 5 seconds after its roster update, has the guild
            -- master's copy send the veto list, once SEND_GAP since its last send is over.
            wow.advanceAll(net, 120, 0.5)
            wow.use(cid)
            assert.is_true(cid.ns.GuildLead.IsVetoed(Token("Hi {fullname} vetoed")))
            wow.systemMessage("|Hplayer:" .. LOGIN .. "|h[" .. LOGIN .. "]|h has come online.")
            wow.advanceAll(net, 60, 0.1)
            wow.use(cid)
            local mine = {}
            for _, s in ipairs(wow.sent) do if s.channel == "GUILD" then mine[#mine + 1] = s.text end end
            assert.are.same({ "Hi Thrall kept" }, mine)
        end)

        it("a veto undone: the line can be said again", function()
            local clients, net = Guild(1)
            TwoLines(clients, "guildLogin", "Hi {fullname} back", "")
            Lead(clients, net, "vetoes", { Token("Hi {fullname} back") })
            Lead(clients, net, "vetoes", {})
            Arrive(clients, LOGIN)
            wow.advanceAll(net, 60, 0.1)
            assert.is_true(#Said(clients, LOGIN) >= 1)
            for _, s in ipairs(Said(clients, LOGIN)) do assert.are.equal("Hi Thrall back", s.text) end
        end)

        it("names each line by the token a leader vetoes it with", function()
            local ns = wow.boot()
            for i, text in ipairs(ns.DefaultMessages.guildLogin) do
                assert.are.equal("bld" .. i, ns.GuildLead.LineToken("guildLogin", text))
            end
            for i, text in ipairs(ns.CasualMessages.guildJoin) do
                assert.are.equal("bjc" .. i, ns.GuildLead.LineToken("guildJoin", text))
            end
            assert.are.equal(Token("Hi {name}!"), ns.GuildLead.LineToken("guildLogin", "Hi {name}!"))
            assert.are.equal(ns.DefaultMessages.guildJoin[3], ns.GuildLead.BuiltInText("bjd3"))
            assert.are.equal(ns.CasualMessages.guildJoin[1], ns.GuildLead.BuiltInText("bjc1"))
            assert.are.equal(ns.CasualMessages.guildLogin[2], ns.GuildLead.BuiltInText("blc2"))
            assert.is_nil(ns.GuildLead.LineToken("partyJoin", "Hi {name}!"), "only lines said in guild chat")
            assert.is_nil(ns.GuildLead.BuiltInText(Token("x")))
        end)
    end)

    describe("line reports (white)", function()
        it("each copy reports the guild line it said; the leader's copy lists it with its words", function()
            local clients, net = Guild(2, { sync = true })
            Arrive(clients, LOGIN)
            wow.advanceAll(net, 60, 0.1)
            local said = Said(clients, LOGIN)
            assert.is_true(#said >= 1)
            local lines = on(clients[1], function(ns) return ns.GuildLead.RecentLines() end)
            local byText = {}
            for _, entry in ipairs(lines) do byText[entry.text] = entry end
            for _, s in ipairs(said) do
                local entry = byText[s.text]
                assert.is_not_nil(entry, s.text)
                assert.are.equal(s.client.full, entry.sender)
                assert.are.equal("guildLogin", entry.msgType)
                assert.are.equal(Token(s.text:gsub(LOGIN, "{fullname}")), entry.token)
            end
            -- A member's copy keeps no list.
            assert.are.same({}, on(clients[2], function(ns) return ns.GuildLead.RecentLines() end))
        end)

        it("a line withdrawn before it was said isn't reported", function()
            local clients, net = Guild(1, { sync = true })
            Arrive(clients, LOGIN)
            wow.advanceAll(net, 5, 0.5)
            Lead(clients, net, "caps", { "h0" })
            wow.advanceAll(net, 60, 0.5)
            assert.are.equal(0, #Said(clients, LOGIN))
            for _, c in ipairs(clients) do
                wow.use(c)
                for _, msg in ipairs(wow.addonSent) do assert.is_nil(msg.text:find(";GLINE;", 1, true)) end
            end
        end)

        it("a built-in line whose chat line wasn't seen shows its shipped words", function()
            local ns = wow.boot({ guildSync = true, before = function(state)
                state.guildRoster = { "Me", "Ann-Vale" }
                state.guildRanks.Me = 0
            end })
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;GLINE;Ann-Vale;j;bjd2", "GUILD", "Ann-Vale", "", 0, 0, "", 0)
            local lines = ns.GuildLead.RecentLines()
            assert.are.equal(1, #lines)
            assert.are.equal(ns.DefaultMessages.guildJoin[2], lines[1].text)
            -- Their chat line arriving after the report fills in its words.
            wow.guildChat("Welcome, Bob!", "Ann-Vale")
            assert.are.equal("Welcome, Bob!", ns.GuildLead.RecentLines()[1].text)
        end)
    end)

    describe("what a line report can't do (black)", function()
        local function Leader()
            local ns = wow.boot({ guildSync = true, before = function(state)
                state.guildRoster = { "Me", "Ann-Vale" }
                state.guildRanks.Me = 0
            end })
            wow.fire("GUILD_ROSTER_UPDATE")
            return ns
        end
        local function report(text, sender)
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", text, "GUILD", sender, "", 0, 0, "", 0)
            wow.advance(1.1)
        end

        it("a malformed report, or one from outside the roster, adds nothing", function()
            local ns = Leader()
            report("1;GLINE;Ann-Vale;x;bjd2", "Ann-Vale")
            report("1;GLINE;Ann-Vale;j;say this", "Ann-Vale")
            report("1;GLINE;Ann-Vale;j;bjd2;extra", "Ann-Vale")
            report("1;GLINE;Sly-Fox;j;bjd2", "Sly-Fox")
            report("1;GLINE;Ann-Vale;l;bjd2", "Sly-Fox")
            assert.are.same({}, ns.GuildLead.RecentLines())
            report("1;GLINE;Ann-Vale;l;cdeadbeef", "Ann-Vale")
            assert.are.equal(1, #ns.GuildLead.RecentLines())
        end)

        it("a report never makes a copy say or veto anything, and words come only from its sender's own chat", function()
            local ns = Leader()
            wow.guildChat("Bo's words", "Bo-Lake")
            report("1;GLINE;Ann-Vale;l;cdeadbeef", "Ann-Vale")
            assert.is_nil(ns.GuildLead.RecentLines()[1].text)
            -- Bo's next line, after Ann's report, isn't Ann's either.
            wow.guildChat("Bo again", "Bo-Lake")
            assert.is_nil(ns.GuildLead.RecentLines()[1].text)
            assert.are.same({}, wow.sent)
            assert.is_false(ns.GuildLead.IsVetoed("cdeadbeef"))
        end)

        it("a report keeps the words it was given: a later line of theirs doesn't replace them", function()
            local ns = Leader()
            wow.guildChat("first words", "Ann-Vale")
            report("1;GLINE;Ann-Vale;l;cdeadbeef", "Ann-Vale")
            wow.guildChat("chatting on", "Ann-Vale")
            assert.are.equal("first words", ns.GuildLead.RecentLines()[1].text)
        end)

        it("words more than CHAT_MATCH seconds from the report aren't its words, either way round", function()
            local ns = Leader()
            assert.are.equal(10, ns.GuildLead.CHAT_MATCH)
            wow.guildChat("old words", "Ann-Vale")
            wow.advance(11)
            report("1;GLINE;Ann-Vale;l;cdeadbeef", "Ann-Vale")
            assert.is_nil(ns.GuildLead.RecentLines()[1].text)
            wow.advance(11)
            wow.guildChat("late words", "Ann-Vale")
            assert.is_nil(ns.GuildLead.RecentLines()[1].text)
            -- Within it, they are.
            report("1;GLINE;Ann-Vale;l;cdeadbeef", "Ann-Vale")
            assert.are.equal("late words", ns.GuildLead.RecentLines()[2].text)
        end)

        it("a member's copy keeps no one's guild chat; a leader's keeps at most MAX_CHAT, and no empty line", function()
            local member = wow.boot({ before = function(state) state.guildRoster = { "Me", "Ann-Vale" } end })
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.guildChat("hello", "Ann-Vale")
            assert.are.equal(0, member.GuildLead.ChatKept())
            local ns = Leader()
            wow.guildChat("|", "Ann-Vale")
            assert.are.equal(0, ns.GuildLead.ChatKept(), "nothing left once escapes are taken out")
            for i = 1, 120 do wow.guildChat("hi", "Mate-" .. string.char(97 + i % 26, 97 + math.floor(i / 26))) end
            assert.are.equal(100, ns.GuildLead.ChatKept())
        end)

        it("guild chat words are plain text, cut short, and an unreadable line is passed over", function()
            local ns = Leader()
            wow.guildChat("|cffff0000red|r " .. string.rep("x", 300), "Ann-Vale")
            report("1;GLINE;Ann-Vale;l;cdeadbeef", "Ann-Vale")
            local text = ns.GuildLead.RecentLines()[1].text
            assert.is_nil(text:find("|", 1, true))
            assert.is_true(#text <= 255)
            wow.guildChat(wow.secret("hidden"), "Ann-Vale")
            wow.guildChat("words", wow.secret("Ann-Vale"))
            assert.are.same({}, wow.errors)
        end)

        it("keeps at most MAX_LINES recent lines and MAX_CHAT guildmates' chat", function()
            local ns = Leader()
            for _ = 1, ns.GuildLead.MAX_LINES + 5 do report("1;GLINE;Ann-Vale;l;cdeadbeef", "Ann-Vale") end
            assert.are.equal(50, #ns.GuildLead.RecentLines())
            assert.are.equal(100, ns.GuildLead.MAX_CHAT)
            for i = 1, 120 do wow.guildChat("hi", "Mate-" .. string.char(97 + i % 26, 97 + math.floor(i / 26))) end
            assert.are.same({}, wow.errors)
        end)

        it("no guild: no caps, no vetoes, every copy welcomes and greets as before", function()
            local ns = wow.boot({ guildSync = true, before = function(state) state.inGuild = false end })
            assert.are.same({ hellos = true }, ns.GuildLead.Caps())
            assert.are.equal(5, ns.GuildHellos.Cap("guildLogin"))
            assert.are.equal(math.huge, ns.GuildHellos.Cap("guildJoin"))
            assert.is_false(ns.GuildLead.IsLineVetoed("guildLogin", "Hi {name}"))
            assert.is_false((ns.GuildLead.ReportLine("guildLogin", "Hi {name}")))
        end)

        it("a veto only touches lines said in guild chat", function()
            local ns = wow.boot({ before = function(state)
                state.guildRoster = { "Me" }
                state.guildRanks.Me = 0
            end })
            wow.fire("GUILD_ROSTER_UPDATE")
            assert.is_true(ns.GuildLead.Set("vetoes", { Token("Hello {name}") }))
            assert.is_true(ns.GuildLead.IsLineVetoed("guildLogin", "Hello {name}"))
            assert.are.equal("Hello {name}", (ns.Messages.Pick("partyJoin", { "Hello {name}" })))
            assert.is_nil(ns.Messages.Pick("guildLogin", { "Hello {name}" }))
        end)
    end)
    describe("forged and genuine settings, logins and joins together (red)", function()
        -- Rounds of: maybe a genuine change by the guild master, forged
        -- changes and line reports from a member, then a login or a join.
        -- The test keeps its own model of the caps and vetoes, from the
        -- genuine changes only, and checks every round's greetings against it.
        local function Storm(seed, rounds)
            random.seed(seed)
            local clients, net = Guild(3, { own = 5 })
            local model = { greeters = nil, welcomes = nil, off = false, vetoed = {} }
            local function forge(text, sender)
                for _, c in ipairs(clients) do
                    wow.use(c)
                    wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", text, "GUILD", sender, "", 0, 0, "", 0)
                end
            end
            local stats = { rounds = 0, greeted = 0, capped = 0, vetoedSome = 0, off = 0 }
            for round = 1, rounds do
                if random.random(2) == 1 then
                    local caps = {}
                    model.greeters, model.welcomes, model.off = nil, nil, false
                    if random.random(2) == 1 then model.greeters = random.random(1, 3); caps[#caps + 1] = "g" .. model.greeters end
                    if random.random(2) == 1 then model.welcomes = random.random(1, 3); caps[#caps + 1] = "w" .. model.welcomes end
                    if random.random(5) == 1 then model.off = true; caps[#caps + 1] = "h0" end
                    Lead(clients, net, "caps", caps)
                    local vetoes = {}
                    model.vetoed = {}
                    for n = 1, 30 do
                        if random.random(3) == 1 then
                            local token = Token((n % 2 == 0 and "Hi" or "Welcome") .. " {fullname} #" .. n)
                            vetoes[#vetoes + 1] = token
                            model.vetoed[token] = true
                        end
                    end
                    Lead(clients, net, "vetoes", vetoes)
                end
                -- Forged: a member's own changes, the guild master's name taken, line reports.
                local member = clients[2].full
                forge("1;GCAPS;" .. member .. ";999999999998;1;1;g20,w20", member)
                forge("1;GVETO;" .. member .. ";999999999998;1;1;-", member)
                forge("1;GCAPS;Gina-Moss;999999999998;1;1;-", member)
                forge("1;GRANKS;" .. member .. ";999999999998;1;1;1,2,3,4,5", member)
                forge("1;GLINE;" .. member .. ";l;" .. Token("Hi {fullname} #1"), member)
                local join = random.random(2) == 1
                local name = (join and "Joiner" or "Login") .. string.char(96 + round % 26 + 1, 96 + math.floor(round / 26) + 1)
                -- The roster lists them, so a login is greeted.
                for _, c in ipairs(clients) do
                    wow.use(c)
                    local roster = {}
                    for _, n in ipairs(wow.state.guildRoster) do roster[#roster + 1] = n end
                    roster[#roster + 1] = name
                    wow.state.guildRoster = roster
                    wow.state.guildRanks["Gina-Moss"] = 0
                    wow.fire("GUILD_ROSTER_UPDATE")
                end
                Arrive(clients, name, join and (name .. " has joined the guild.") or nil)
                wow.advanceAll(net, 60, 0.5)
                local said = Said(clients, name)
                local cap
                if join then
                    cap = model.welcomes or #clients
                else
                    cap = model.off and 0 or math.min(5, model.greeters or 5)
                end
                assert.is_true(#said <= cap, string.format("seed %d round %d: %d said, cap %d", seed, round, #said, cap))
                for _, line in ipairs(said) do
                    local template = line.text:gsub(name, "{fullname}")
                    assert.is_nil(model.vetoed[Token(template)],
                        string.format("seed %d round %d: a vetoed line was said: %s", seed, round, line.text))
                end
                stats.rounds = stats.rounds + 1
                if #said > 0 then stats.greeted = stats.greeted + 1 end
                if #said == cap and cap < #clients then stats.capped = stats.capped + 1 end
                if next(model.vetoed) then stats.vetoedSome = stats.vetoedSome + 1 end
                if model.off and not join then stats.off = stats.off + 1 end
                -- Nothing forged changed a copy's settings: every copy has the model's.
                for _, c in ipairs(clients) do
                    local caps = on(c, function(ns) return ns.GuildLead.Caps() end)
                    assert.are.equal(model.greeters, caps.greeters)
                    assert.are.equal(model.welcomes, caps.welcomes)
                    assert.are.equal(not model.off, caps.hellos)
                end
            end
            for _, c in ipairs(clients) do
                wow.use(c)
                assert.are.same({}, wow.errors)
                assert.are.equal(0, #wow.casts)
            end
            return stats
        end

        for _, seed in ipairs({ 1, 2, 3 }) do
            it("seed " .. seed .. ": never more than the cap greet or welcome, never a vetoed line", function()
                local stats = Storm(seed, 14)
                assert.is_true(stats.greeted >= 4, "rounds where someone greeted: " .. stats.greeted)
                assert.is_true(stats.capped >= 2, "rounds that met their cap: " .. stats.capped)
                assert.is_true(stats.vetoedSome >= 4, "rounds with vetoes: " .. stats.vetoedSome)
            end)
        end
    end)
end)
