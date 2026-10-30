-- Spec: #38
-- Guild hellos: every copy in the guild greets a guildmate who logs in, a
-- random while apart, with different lines, and at most K of them.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local LOGIN = "Thrall"
local LOGIN_FULL = "Thrall"

-- Thirty different lines, each naming the login, so a line tells whom it greets.
local function Lines()
    local out = {}
    for i = 1, 30 do out[i] = "Hi {fullname} #" .. i end
    return out
end

local PEOPLE = {
    { name = "Ann", surname = "Vale" }, { name = "Bo", surname = "Lake" }, { name = "Cid", surname = "Moor" },
    { name = "Dee", surname = "Fell" }, { name = "Eli", surname = "Dale" }, { name = "Fay", surname = "Holt" },
    { name = "Gus", surname = "Reed" }, { name = "Hal", surname = "Wood" },
}

local function online(name)
    wow.systemMessage("|Hplayer:" .. name .. "|h[" .. name .. "]|h has come online.")
end

-- n clients in one guild, each with the cap given (default: the shipped 5).
local function Guild(n, cap, roster)
    local clients = {}
    for i = 1, n do
        local p = PEOPLE[i]
        local db = { guildLogin = { messages = Lines(), maxGreeters = cap } }
        clients[i] = wow.newClient({ name = p.name, surname = p.surname, db = db,
            before = function(state) state.guildRoster = roster or { LOGIN } end })
        clients[i].ns.db.guildLogin.messages = Lines()
        clients[i].ns.Messages.random = random.random
        clients[i].ns.GuildHellos.random = random.random
        clients[i].ns.db.debug = true
        wow.fire("GUILD_ROSTER_UPDATE")
    end
    return clients, wow.network(clients)
end

-- Every client sees the login line at the same moment.
local function LogIn(clients, name)
    for _, c in ipairs(clients) do
        wow.use(c)
        online(name)
    end
end

-- Every guild line every client sent: { client, text, time }.
local function Hellos(clients)
    local out = {}
    for _, c in ipairs(clients) do
        wow.use(c)
        for _, s in ipairs(wow.sent) do
            if s.channel == "GUILD" then out[#out + 1] = { client = c, text = s.text, time = s.time } end
        end
    end
    return out
end

-- An addon message from someone else, straight to the live client.
local function Greet(sender, text)
    wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", text, "GUILD", sender, "", 0, 0, "", 0)
end

-- One of each client's own GREETs has come back this session (about a
-- login it isn't tracking): from now on, one that doesn't come back means
-- it was lost.
local function Prove(clients)
    for _, c in ipairs(clients) do
        wow.use(c)
        wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;GREET;" .. c.full .. ";Nobody-Here;1", "GUILD", c.full,
            "", 0, 0, "", 0)
    end
end

describe("Guild hellos (#38)", function()
    before_each(function() random.seed(38) end)

    describe("defaults", function()
        it("greets with at most 5 copies, adjustable from 1 to 20 and checked like every setting", function()
            local ns = wow.boot()
            assert.are.equal(5, ns.Config.DEFAULTS.guildLogin.maxGreeters)
            assert.are.equal(5, ns.db.guildLogin.maxGreeters)
            for saved, loaded in pairs({ [0] = 1, [21] = 20, [3.7] = 3, [-4] = 1 }) do
                ns = wow.boot({ db = { guildLogin = { maxGreeters = saved } } })
                assert.are.equal(loaded, ns.db.guildLogin.maxGreeters, tostring(saved))
            end
            ns = wow.boot({ db = { guildLogin = { maxGreeters = "lots" } } })
            assert.are.equal(5, ns.db.guildLogin.maxGreeters)
        end)

        it("is set on the Guild Login tab only", function()
            local ns = wow.boot()
            local w = ns.Options.widgets
            wow.run(w.tabs.guildLogin, "OnClick")
            assert.is_true(w.steppers.maxGreeters.box:IsShown())
            assert.is_true(w.greetersHelp:IsShown())
            assert.are.equal("5", w.steppers.maxGreeters.box:GetText())
            wow.run(w.steppers.maxGreeters.plus, "OnClick")
            assert.are.equal(6, ns.db.guildLogin.maxGreeters)
            for _ = 1, 30 do wow.run(w.steppers.maxGreeters.minus, "OnClick") end
            assert.are.equal(1, ns.db.guildLogin.maxGreeters, "never below 1: someone always greets")
            assert.are.equal("1", w.steppers.maxGreeters.box:GetText())
            wow.run(w.tabs.guildJoin, "OnClick")
            assert.is_false(w.steppers.maxGreeters.box:IsShown())
            assert.is_false(w.greetersHelp:IsShown())
        end)

        it("reads a cap damaged while you play as its default, without errors", function()
            local clients, net = Guild(1, 1)
            local ns = clients[1].ns
            ns.db.guildLogin.maxGreeters = "broken"
            LogIn(clients, LOGIN)
            wow.advanceAll(net, 40, 0.1)
            assert.are.same({}, wow.errors)
            assert.are.equal(1, #Hellos(clients))
        end)

        it("carries the cap in profiles and settings lines", function()
            local ns = wow.boot()
            ns.db.guildLogin.maxGreeters = 2
            local line = ns.Profiles.Export()
            ns.db.guildLogin.maxGreeters = 7
            assert.is_true((ns.Profiles.Import(line)))
            assert.are.equal(2, ns.db.guildLogin.maxGreeters)
        end)
    end)

    -- White: five simulated guildmates greet one login.
    describe("five guildmates greet one login", function()
        local function run(cap)
            local clients, net = Guild(5, cap)
            local start = wow.now
            LogIn(clients, LOGIN)
            wow.advanceAll(net, 40, 0.1)
            return clients, Hellos(clients), start
        end

        it("with different lines, spread over time, and no more than K", function()
            local clients, hellos, start = run(nil)
            local delay = clients[1].ns.db.guildLogin.delay
            assert.are.equal(5, #hellos, "K is 5: all five greet")
            local seen, first, last = {}, math.huge, -math.huge
            for _, h in ipairs(hellos) do
                assert.is_nil(seen[h.text], "two copies said " .. h.text)
                seen[h.text] = true
                assert.truthy(h.text:find("^Hi " .. LOGIN_FULL .. " #%d+$"), h.text)
                local waited = h.time - start
                assert.is_true(waited >= delay + 1, "greeted after " .. waited .. "s")
                assert.is_true(waited <= delay + 8 + 1, "greeted after " .. waited .. "s")
                first, last = math.min(first, h.time), math.max(last, h.time)
            end
            assert.is_true(last - first >= 1, "the hellos land at least a second apart overall")
        end)

        it("only K greet when the cap is lower than the number of copies", function()
            for _, cap in ipairs({ 1, 2, 3 }) do
                local clients, hellos = run(cap)
                assert.are.equal(cap, #hellos, "K = " .. cap)
                -- A copy that already heard K announces nothing.
                local greets = 0
                for _, c in ipairs(clients) do
                    wow.use(c)
                    for _, m in ipairs(wow.addonSent) do
                        if m.text:find(";GREET;", 1, true) then greets = greets + 1 end
                    end
                end
                assert.is_true(greets < #clients, cap .. ": " .. greets .. " announcements")
                local seen = {}
                for _, h in ipairs(hellos) do
                    assert.is_nil(seen[h.text], "two copies said " .. h.text)
                    seen[h.text] = true
                end
            end
        end)

        it("notes a skipped hello in diagnostics", function()
            local clients = run(1)
            local skipped = 0
            for _, c in ipairs(clients) do
                wow.use(c)
                for _, line in ipairs(c.ns.db.diagLog) do
                    if line:find("other copies", 1, true) and line:find("most: 1", 1, true) then
                        skipped = skipped + 1
                        break
                    end
                end
            end
            assert.are.equal(4, skipped)
        end)

        it("greets with the random wait only when the channel is closed", function()
            local clients, net = Guild(3, 1)
            for _, c in ipairs(clients) do
                wow.use(c)
                c.ns.db.enabled = true
                wow.state.inInstance = true -- addons may not message other players there
            end
            local start = wow.now
            LogIn(clients, LOGIN)
            wow.advanceAll(net, 40, 0.1)
            local hellos = Hellos(clients)
            assert.are.equal(3, #hellos, "without the channel nothing caps them")
            local delay = clients[1].ns.db.guildLogin.delay
            local times = {}
            for _, h in ipairs(hellos) do
                assert.is_true(h.time - start >= delay + 1)
                times[#times + 1] = h.time
            end
            table.sort(times)
            assert.is_true(times[#times] - times[1] > 0, "spread out")
            wow.use(clients[1])
            assert.are.equal(0, #wow.addonSent, "no announcement from inside an instance")
        end)

        it("greets alone, with the random wait, when no other copy is online", function()
            local clients, net = Guild(1, 1)
            local start = wow.now
            LogIn(clients, LOGIN)
            wow.advanceAll(net, 40, 0.1)
            local hellos = Hellos(clients)
            assert.are.equal(1, #hellos)
            assert.is_true(hellos[1].time - start >= clients[1].ns.db.guildLogin.delay + 1)
        end)
    end)

    -- Black: spoofed, late, malformed and flooding announcements.
    describe("untrusted announcements", function()
        local clients, net, me, ns

        before_each(function()
            clients, net = Guild(1, 1, { LOGIN, "Liar", "Old" })
            me = clients[1]
            ns = me.ns
        end)

        local function greeted()
            wow.advanceAll(net, 40, 0.1)
            return #Hellos(clients)
        end

        it("a forged announcement, sent in someone else's name, never stops the hello", function()
            LogIn(clients, LOGIN)
            Greet("Liar", "1;GREET;Ann-Vale;" .. LOGIN_FULL .. ";1")
            Greet("Liar", "1;GREET;Other-Name;" .. LOGIN_FULL .. ";1")
            assert.are.equal(1, greeted())
            assert.is_true(ns.Diag.Counters().commSpoofed >= 2)
        end)

        it("an announcement before the login, or about a login nobody saw, doesn't count", function()
            Greet("Liar", "1;GREET;Liar;" .. LOGIN_FULL .. ";1")
            LogIn(clients, LOGIN)
            assert.are.equal(1, greeted())
        end)

        it("an announcement for an earlier login doesn't count for a relog", function()
            ns.db.guildLogin.repeatCooldown = 0
            LogIn(clients, LOGIN)
            wow.advance(1)
            Greet("Liar", "1;GREET;Liar;" .. LOGIN_FULL .. ";1")
            wow.advance(1)
            LogIn(clients, LOGIN) -- relogs before anyone greeted
            assert.are.equal(0, #Hellos(clients), "before anyone greeted")
            assert.are.equal(1, greeted(), "once: the second login's own hello")
        end)

        it("an announcement that arrives after ours came back changes nothing", function()
            LogIn(clients, LOGIN)
            -- Run until ours is out and back, but before our line is said.
            for _ = 1, 400 do
                wow.advanceAll(net, 0.05, 0.05)
                if #wow.addonSent > 0 then break end
            end
            assert.are.equal(1, #wow.addonSent, "announced")
            Greet("Liar", "1;GREET;Liar;" .. LOGIN_FULL .. ";1")
            assert.are.equal(1, greeted())
        end)

        it("an announcement long after the login doesn't count for it", function()
            LogIn(clients, LOGIN)
            wow.advance(ns.GuildHellos.LOGIN_TTL + 1)
            Greet("Liar", "1;GREET;Liar;" .. LOGIN_FULL .. ";1")
            assert.are.equal(0, ns.GuildHellos.Tracked())
        end)

        it("the player who logged in can't claim their own hello", function()
            LogIn(clients, LOGIN)
            Greet(LOGIN, "1;GREET;" .. LOGIN_FULL .. ";" .. LOGIN_FULL .. ";1")
            assert.are.equal(1, greeted())
        end)

        it("drops malformed announcements and greets anyway", function()
            LogIn(clients, LOGIN)
            local bad = {
                "1;GREET;Liar;" .. LOGIN_FULL .. ";0", "1;GREET;Liar;" .. LOGIN_FULL .. ";31",
                "1;GREET;Liar;" .. LOGIN_FULL .. ";01", "1;GREET;Liar;" .. LOGIN_FULL .. ";x",
                "1;GREET;Liar;bad name;1", "1;GREET;Liar;" .. LOGIN_FULL, "1;GREET;Liar;" .. LOGIN_FULL .. ";1;2",
                "1;GREET;Liar;" .. string.rep("a", 33) .. "-" .. string.rep("b", 33) .. ";1", -- 67 bytes
                "1;GREET;Liar;;1",
            }
            -- Each from its own sender, so none is dropped as flooding first.
            for i, text in ipairs(bad) do
                local sender = "Liar" .. string.char(96 + i)
                Greet(sender, (text:gsub("Liar", sender)))
            end
            assert.are.equal(1, greeted())
            assert.is_true(ns.Diag.Counters().commMalformed >= #bad)
        end)

        it("drops an announcement on a route other than the guild's", function()
            LogIn(clients, LOGIN)
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", "1;GREET;Liar;" .. LOGIN_FULL .. ";1", "WHISPER", "Liar",
                "", 0, 0, "", 0)
            assert.are.equal(1, greeted())
        end)

        it("one flooding guildmate can't stop the hello", function()
            LogIn(clients, LOGIN)
            for _ = 1, 50 do Greet("Liar", "1;GREET;Liar;" .. LOGIN_FULL .. ";1") end
            -- The first counts; K is 1 here, so make room for one more.
            ns.db.guildLogin.maxGreeters = 2
            assert.are.equal(1, greeted())
            assert.is_true(ns.Diag.Counters().commFlood > 0)
        end)

        it("at least one of several copies greets whatever the liars send", function()
            local many, manyNet = Guild(4, 1, { LOGIN, "Liar" })
            LogIn(many, LOGIN)
            for _, c in ipairs(many) do
                wow.use(c)
                Greet("Liar", "1;GREET;Ann-Vale;" .. LOGIN_FULL .. ";1")  -- forged
                Greet("Liar", "1;GREET;Liar;Someone;2")                   -- not a login it saw
                Greet(LOGIN, "1;GREET;" .. LOGIN_FULL .. ";" .. LOGIN_FULL .. ";3")
            end
            wow.advanceAll(manyNet, 40, 0.1)
            assert.are.equal(1, #Hellos(many))
        end)
    end)

    describe("lines and timing", function()
        it("copies that announce at the same moment with the same line still say different ones", function()
            -- Same random numbers everywhere: the same line, at the same time.
            local clients, net = Guild(3, 5)
            for _, c in ipairs(clients) do
                c.ns.Messages.random = function() return 1 end
                c.ns.GuildHellos.random = function() return 0 end
            end
            LogIn(clients, LOGIN)
            wow.advanceAll(net, 40, 0.5)
            local hellos = Hellos(clients)
            assert.are.equal(3, #hellos)
            local seen = {}
            for _, h in ipairs(hellos) do
                assert.is_nil(seen[h.text], "two copies said " .. h.text)
                seen[h.text] = true
            end
        end)

        it("copies that announce at the same moment are still cut to K", function()
            local clients, net = Guild(4, 2)
            for _, c in ipairs(clients) do
                c.ns.Messages.random = function() return 1 end
                c.ns.GuildHellos.random = function() return 0 end
            end
            LogIn(clients, LOGIN)
            wow.advanceAll(net, 40, 0.5)
            local hellos = Hellos(clients)
            assert.are.equal(2, #hellos)
            assert.are_not.equal(hellos[1].text, hellos[2].text)
            local announced = 0
            for _, c in ipairs(clients) do
                wow.use(c)
                announced = announced + #wow.addonSent
            end
            assert.are.equal(4, announced, "all four announced before hearing the others")
        end)

        it("picks a line no one announced, even when the rest of this round's lines are taken", function()
            local ns = wow.boot()
            ns.Messages.random = function(n) return n end
            local msgs = { "a", "b", "c" }
            ns.db.messageBags.t = { left = { 1 }, last = 3 }
            local text, index = ns.Messages.Pick("t", msgs, { [1] = true })
            assert.are.equal(3, index, "random among lines 2 and 3")
            assert.are.equal(msgs[index], text)
            assert.are.same({ 1 }, ns.db.messageBags.t.left, "the round still has line 1 to use")
            text, index = ns.Messages.Pick("t", msgs, { [1] = true, [2] = true, [3] = true })
            assert.are.equal(1, index, "every line taken: the bag's next")
            assert.are.equal("a", text)
            ns.db.messageBags.t = { left = { 1, 2, 3 }, last = 9 }
            local _, next = ns.Messages.Pick("t", msgs, { [3] = true })
            assert.are.equal(2, next, "the bag's next line that isn't taken")
            assert.are.same({ 1, 3 }, ns.db.messageBags.t.left)
        end)

        it("drop sends nothing and tells onDone, once", function()
            local ns = wow.boot()
            local done = {}
            ns.Announcer.Schedule("guildJoin", "Thrall", { channel = "GUILD", delay = 1,
                hold = function(_, _, drop) drop("a test") end,
                onDone = function(sent, why) done[#done + 1] = { sent, why } end })
            wow.advance(5)
            assert.are.same({ { false, "a test" } }, done)
            assert.are.equal(0, #wow.sent)
        end)

        it("go with another line says that line", function()
            local ns = wow.boot()
            ns.db.guildJoin.messages = { "one {name}", "two {name}", "  " }
            ns.Announcer.Schedule("guildJoin", "Thrall", { channel = "GUILD", delay = 1,
                hold = function(go, line)
                    assert.are.equal(1, line)
                    go(2)
                end })
            local own
            ns.Announcer.Schedule("guildJoin", "Jaina", { channel = "GUILD", delay = 1,
                hold = function(go, line)
                    own = line
                    go(3) -- blank: its own line
                end })
            wow.advance(10)
            assert.are.same({ "two Thrall", (ns.db.guildJoin.messages[own]:gsub("{name}", "Jaina")) },
                wow.sentTo("GUILD"))
        end)

        it("forgets logins past their time, or when the clock goes back, and keeps at most MAX_LOGINS", function()
            local ns = wow.boot({ before = function(state) state.guildRoster = { LOGIN } end })
            wow.advance(5)
            online(LOGIN)
            assert.are.equal(1, ns.GuildHellos.Tracked())
            wow.now = wow.now - 1
            assert.are.equal(0, ns.GuildHellos.Tracked(), "a clock that went back")
            ns.GuildHellos.MAX_LOGINS = 3
            for _, name in ipairs({ "Aa", "Bb", "Cc", "Dd", "Ee" }) do
                online(name)
                wow.advance(0.1)
            end
            assert.are.equal(3, ns.GuildHellos.Tracked())
            assert.is_nil(ns.GuildHellos.Heard("Bb"), "the oldest went first")
            assert.are.equal(0, ns.GuildHellos.Heard("Ee"))
            wow.advance(ns.GuildHellos.LOGIN_TTL + 1)
            assert.are.equal(0, ns.GuildHellos.Tracked())
        end)

        it("counts each other copy once, and keeps at most MAX_GREETS", function()
            local clients = Guild(1, 5)
            local ns = clients[1].ns
            ns.GuildHellos.MAX_GREETS = 3
            LogIn(clients, LOGIN)
            Greet("Liar", "1;GREET;Liar;" .. LOGIN_FULL .. ";1")
            Greet("Liar", "1;GREET;Liar;" .. LOGIN_FULL .. ";2")
            assert.are.equal(1, ns.GuildHellos.Heard(LOGIN))
            for _, sender in ipairs({ "Aa", "Bb", "Cc", "Dd" }) do
                Greet(sender, "1;GREET;" .. sender .. ";" .. LOGIN_FULL .. ";3")
            end
            assert.are.equal(3, ns.GuildHellos.Heard(LOGIN))
        end)

        -- Lines 1 to 19 announced by 19 other copies (K is 20 here).
        local function Taken19()
            for n = 1, 19 do
                local sender = "Liar" .. string.char(96 + n)
                Greet(sender, "1;GREET;" .. sender .. ";" .. LOGIN_FULL .. ";" .. n)
            end
        end

        local function Said(hellos)
            return tonumber(hellos[1].text:match("#(%d+)$"))
        end

        it("announces and says a line no other copy announced", function()
            local clients, net = Guild(1, 20)
            LogIn(clients, LOGIN)
            Taken19()
            wow.advanceAll(net, 40, 0.1)
            assert.is_true(tonumber(wow.addonSent[1].text:match(";(%d+)$")) >= 20, wow.addonSent[1].text)
            local hellos = Hellos(clients)
            assert.are.equal(1, #hellos)
            assert.is_true(Said(hellos) >= 20, hellos[1].text)
        end)

        it("says a line no other copy announced without the channel too", function()
            local clients, net = Guild(1, 20)
            wow.state.inInstance = true
            LogIn(clients, LOGIN)
            Taken19()
            wow.advanceAll(net, 40, 0.1)
            local hellos = Hellos(clients)
            assert.are.equal(1, #hellos)
            assert.is_true(Said(hellos) >= 20, hellos[1].text)
        end)

        it("greets with the random wait only during chat lockdown, once it lifts", function()
            local clients, net = Guild(1, 1)
            Prove(clients)
            LogIn(clients, LOGIN)
            wow.state.lockdown = true
            wow.advanceAll(net, 15, 0.1)
            assert.are.equal(0, #Hellos(clients), "nothing during lockdown")
            wow.state.lockdown = false
            wow.advanceAll(net, 40, 0.1)
            assert.are.equal(1, #Hellos(clients))
            assert.are.equal(0, #wow.addonSent, "no announcement it couldn't send")
        end)

        it("doesn't greet a login it has stopped tracking", function()
            local clients, net = Guild(1, 5, { LOGIN, "Jaina" })
            clients[1].ns.GuildHellos.MAX_LOGINS = 1
            LogIn(clients, LOGIN)
            LogIn(clients, "Jaina") -- pushes Thrall out
            wow.advanceAll(net, 40, 0.1)
            local hellos = Hellos(clients)
            assert.are.equal(1, #hellos)
            assert.truthy(hellos[1].text:find("^Hi Jaina"))
        end)

        it("a malformed message of its own back doesn't count as one of its GREETs back", function()
            local clients, net = Guild(1, 1)
            local me = clients[1].full
            net.lose = function() return true end
            Greet(me, "1;GREET;" .. me .. ";Nobody-Here;99")
            Greet(me, "1;GREET;" .. me .. ";Nobody Here;1")
            Greet(me, nil)
            Greet(me, 42)
            LogIn(clients, LOGIN)
            wow.advanceAll(net, 40, 0.1)
            assert.are.equal(1, #Hellos(clients), "still unproven: greets anyway")
            assert.are.same({}, wow.errors)
        end)

        it("unproven and never back, it still says a line no copy before it took", function()
            local clients, net = Guild(1, 20)
            local ns = clients[1].ns
            ns.db.guildLogin.messages[1] = "  " -- the lowest free line is blank here
            net.lose = function() return true end
            LogIn(clients, LOGIN)
            for _ = 1, 400 do
                wow.advance(0.05)
                if #wow.addonSent > 0 then break end
            end
            local mine = tonumber(wow.addonSent[1].text:match(";(%d+)$"))
            Greet("Liar", "1;GREET;Liar;" .. LOGIN_FULL .. ";" .. mine) -- took ours first
            wow.advanceAll(net, 40, 0.1)
            local hellos = Hellos(clients)
            assert.are.equal(1, #hellos)
            local said = tonumber(hellos[1].text:match("#(%d+)$"))
            assert.are_not.equal(mine, said)
            assert.are_not.equal(1, said)
        end)

        it("greets with the random wait only when this client has no addon messages", function()
            local ns = wow.boot({ before = function(state)
                state.guildRoster = { LOGIN }
                state.noAddonMessages = true
            end })
            wow.fire("GUILD_ROSTER_UPDATE")
            assert.is_false(ns.Comm.Ready())
            online(LOGIN)
            wow.advance(ns.db.guildLogin.delay + ns.GuildHellos.STAGGER_MIN - 0.1)
            assert.are.equal(0, #wow.sentTo("GUILD"), "not before the random wait")
            wow.advance(0.2)
            assert.are.equal(1, #wow.sentTo("GUILD"))
        end)

        it("greets with the random wait only when it can't read its own name", function()
            local clients, net = Guild(1, 1)
            LogIn(clients, LOGIN)
            wow.state.unitsRestricted = true
            wow.advanceAll(net, 40, 0.1)
            assert.are.equal(1, #Hellos(clients))
            assert.are.equal(0, #wow.addonSent)
        end)

        it("only its own GREET, exactly as sent and on the guild route, counts as back", function()
            local clients, net = Guild(1, 1)
            local ns = clients[1].ns
            Prove(clients)
            net.lose = function() return true end -- the real one never comes back
            LogIn(clients, LOGIN)
            for _ = 1, 400 do
                wow.advance(0.05)
                if #wow.addonSent > 0 then break end
            end
            local sent = wow.addonSent[1].text
            local line = sent:match(";(%d+)$")
            local me = clients[1].full
            local fakes = {
                sent .. ";9", "2" .. sent:sub(2), (sent:gsub(me:gsub("%-", "%%-"), "Bo-Lake")),
                "1;GREET;" .. me .. ";" .. LOGIN_FULL .. ";" .. (line == "1" and "2" or "1"),
                "1;GREET;" .. me .. ";" .. LOGIN_FULL .. ";99", "1;HELLO;" .. me .. ";0.9.0;0",
            }
            for _, text in ipairs(fakes) do Greet(me, text) end
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", sent, "WHISPER", me, "", 0, 0, "", 0)
            wow.fire("CHAT_MSG_ADDON", "FriendlyFvr", sent, "PARTY", me, "", 0, 0, "", 0)
            wow.advanceAll(net, 40, 0.1)
            assert.are.equal(0, #Hellos(clients))
            assert.are.equal(0, ns.Comm.PeerCount(), "our own HELLO doesn't make us a peer")
            -- And the real one, once, would have done.
            ns.db.guildLogin.repeatCooldown = 0
            net.lose = nil
            LogIn(clients, LOGIN)
            wow.advanceAll(net, 40, 0.1)
            assert.are.equal(1, #Hellos(clients))
        end)

        it("says why when it couldn't announce", function()
            local clients, net = Guild(1, 1)
            local ns = clients[1].ns
            LogIn(clients, LOGIN)
            ns.Comm.SendGreet = function() return false, "too many waiting" end
            wow.advanceAll(net, 40, 0.1)
            local found = false
            for _, l in ipairs(ns.db.diagLog) do
                if l:find("couldn't announce it", 1, true) then found = true end
            end
            assert.is_true(found)
            assert.are.equal(0, #Hellos(clients))
        end)
    end)

    -- Black: when it can't count the others, it doesn't greet (the cap holds).
    describe("fail closed", function()
        it("doesn't greet when its announcement never comes back", function()
            local clients, net = Guild(2, 5)
            Prove(clients)
            net.lose = function() return true end
            LogIn(clients, LOGIN)
            wow.advanceAll(net, 40, 0.1)
            assert.are.equal(0, #Hellos(clients))
            wow.use(clients[1])
            local found = false
            for _, line in ipairs(clients[1].ns.db.diagLog) do
                if line:find("never came back", 1, true) then found = true end
            end
            assert.is_true(found)
        end)

        it("still greets, with the random wait, while none of its announcements has come back yet", function()
            -- The game may not send them back, or may name us otherwise
            -- (launch checks, #50): that mustn't silence every hello.
            local clients, net = Guild(2, 5)
            net.lose = function() return true end
            LogIn(clients, LOGIN)
            wow.advanceAll(net, 40, 0.1)
            local hellos = Hellos(clients)
            assert.are.equal(2, #hellos)
            assert.are_not.equal(hellos[1].text, hellos[2].text)
            -- Once one has come back, a lost one means lost.
            Prove({ clients[1] })
            for _, c in ipairs(clients) do
                wow.use(c)
                c.ns.db.guildLogin.repeatCooldown = 0
            end
            LogIn(clients, LOGIN)
            wow.advanceAll(net, 40, 0.1)
            local by = {}
            for _, h in ipairs(Hellos(clients)) do by[h.client] = (by[h.client] or 0) + 1 end
            assert.are.equal(1, by[clients[1]], "the proven copy stays quiet")
            assert.are.equal(2, by[clients[2]], "the other still greets")
        end)

        it("doesn't greet when the limits on everyone together dropped messages since the login", function()
            local clients, net = Guild(1, 5)
            local ns = clients[1].ns
            LogIn(clients, LOGIN)
            for i = 1, ns.Comm.ALL_BURST + 5 do
                Greet("Sender" .. string.char(97 + i % 26, 97 + math.floor(i / 26)), "1;HELLO;x")
            end
            assert.is_true(ns.Comm.CrowdDrops() > 0)
            wow.advanceAll(net, 40, 0.1)
            assert.are.equal(0, #Hellos(clients))
            assert.are.equal(0, #wow.addonSent, "nor announces")
        end)

        it("doesn't greet when its announcement came back after a crowd dropped messages", function()
            local clients, net = Guild(1, 5)
            local ns = clients[1].ns
            ns.Comm.MAX_SENDERS = 2
            LogIn(clients, LOGIN)
            for _ = 1, 400 do
                wow.advance(0.05) -- this client only: nothing is delivered yet
                if #wow.addonSent > 0 then break end
            end
            assert.are.equal(1, #wow.addonSent, "announced")
            for _, sender in ipairs({ "Aa", "Bb", "Cc" }) do Greet(sender, "1;HELLO;" .. sender .. ";0.9.0;0") end
            assert.are.equal(1, ns.Comm.CrowdDrops(), "the third sender waits: more than MAX_SENDERS")
            wow.advanceAll(net, 40, 0.1)
            assert.are.equal(0, #Hellos(clients))
        end)
    end)

    -- Red: a storm of logins and lost messages never sends more than K
    -- hellos for one login.
    describe("chaos", function()
        -- Enough names that most logins are told apart, and some relog.
        local NAMES = { "Thrall", "Jaina", "Rexxar", "Garona", "Medivh", "Khadgar", "Varian", "Tyrande",
            "Cairne", "Sylvanas", "Uther", "Arthas", "Vol", "Rokhan", "Tirion", "Magni" }

        -- Across all seeds: copies cut to K when their GREET came back
        -- (those that announced together), before announcing, and after a
        -- lost GREET.
        local reached = { capAtEcho = 0, capBefore = 0, lost = 0 }

        local function storm(seed)
            random.seed(seed)
            -- MINSTD's first draws after a small seed are near 0: skip them,
            -- or every storm would be 2 copies with a cap that can't bind.
            for _ = 1, 5 do random.random() end
            local n = random.random(3, 8)
            local cap = random.random(1, math.min(5, n - 1)) -- fewer than the copies, so it binds
            local clients, net = Guild(n, cap, NAMES)
            -- Echoes are known to work: until then, a lost one still greets.
            Prove(clients)
            -- What the storm reached, from the copies' own diagnostics.
            for _, c in ipairs(clients) do
                local log = c.ns.Diag.Log
                c.ns.Diag.Log = function(category, fmt, ...)
                    local ok, line = pcall(string.format, fmt, ...)
                    if ok and category == "guildLogin" then
                        if line:find("other copies announced first", 1, true) then
                            reached.capAtEcho = reached.capAtEcho + 1
                        elseif line:find("other copies already greet them", 1, true) then
                            reached.capBefore = reached.capBefore + 1
                        elseif line:find("never came back", 1, true) then
                            reached.lost = reached.lost + 1
                        end
                    end
                    return log(category, fmt, ...)
                end
            end
            for _, c in ipairs(clients) do
                wow.use(c)
                c.ns.db.guildLogin.repeatCooldown = random.random(0, 1) * 30
                c.ns.db.guildLogin.delay = random.random(0, 4)
            end
            -- The game relays a guild message to everyone or no one (a launch
            -- check, #50): each message is lost whole, echo included.
            local lost = {}
            net.lose = function(msg)
                if lost[msg] == nil then lost[msg] = random.random() < 0.3 end
                return lost[msg]
            end
            -- Logins: { name, at }, from the simulated client's own clock.
            local logins = {}
            for _ = 1, 25 do
                local name = NAMES[random.random(#NAMES)]
                logins[#logins + 1] = { name = name, at = wow.now }
                LogIn(clients, name)
                -- Now and then a stray, forged or junk message, and a damaged cap.
                local c = clients[random.random(n)]
                wow.use(c)
                if random.random() < 0.3 then
                    Greet("Liar", "1;GREET;Liar;" .. NAMES[random.random(#NAMES)] .. ";" .. random.random(30))
                end
                if random.random() < 0.1 then Greet("Liar", "1;GREET;Ann-Vale;" .. name .. ";1") end
                -- Damage that heals to the same cap: a fraction rounds down;
                -- anything unreadable is the default.
                if random.random() < 0.05 then
                    c.ns.db.guildLogin.maxGreeters = cap == 5 and "broken" or cap + 0.5
                end
                wow.advanceAll(net, ({ 0.2, 1, 3, 9, 30 })[random.random(5)], ({ 0.05, 0.1, 0.5 })[random.random(3)])
            end
            wow.advanceAll(net, 120, 0.5)
            return clients, logins, cap, Hellos(clients)
        end

        for _, seed in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 38, 138, 2026 }) do
            it("never sends more than K hellos for one login (seed " .. seed .. ")", function()
                local clients, logins, cap, hellos = storm(seed)
                -- A hello greets a login of the name it says, at most `reach`
                -- seconds before it: the longest delay, random wait and wait
                -- for our announcement, then the longest the chat queue holds
                -- a line. Lines held by the chat cap can land after a relog,
                -- so each hello may belong to any such login: K hellos a
                -- login is kept if they can be shared out so (taking the
                -- earliest login with room first, in time order, finds a way
                -- whenever there is one, all windows being as long).
                local G = clients[1].ns.GuildHellos
                local reach = 4 + G.STAGGER_MAX + G.ECHO_WAIT + clients[1].ns.ChatQueue.MAX_AGE + 1
                table.sort(hellos, function(x, y) return x.time < y.time end)
                local per = {}
                for _, h in ipairs(hellos) do
                    local name = h.text:match("^Hi (%a+) #%d+$")
                    assert.truthy(name, "a hello: " .. h.text)
                    local which
                    for i, l in ipairs(logins) do
                        if not which and l.name == name and l.at <= h.time and h.time <= l.at + reach
                            and (per[i] or 0) < cap then
                            which = i
                        end
                    end
                    assert.truthy(which, string.format("%s at %.2f: more than K = %d hellos for %s's logins",
                        h.client.full, h.time, cap, name))
                    per[which] = (per[which] or 0) + 1
                end
            end)
        end

        it("reached every outcome it guards, across the seeds", function()
            assert.is_true(reached.capAtEcho > 0, "copies that announced together, cut to K")
            assert.is_true(reached.capBefore > 0, "copies that heard K and stayed quiet")
            assert.is_true(reached.lost > 0, "lost GREETs")
        end)
    end)
end)

describe("After an update that adds GuildHellos.lua and a /reload (no restart) (black)", function()
    it("asks for a restart instead of erroring, and greets no one", function()
        wow.reset()
        local loaded = {}
        local _, files = wow.parseToc()
        for _, file in ipairs(files) do
            if file ~= "GuildHellos.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
        end
        wow.fire("ADDON_LOADED", wow.ADDON_NAME)
        wow.fire("PLAYER_ENTERING_WORLD", true, false)
        wow.advance(30)
        online(LOGIN)
        wow.advance(30)
        assert.are.same({}, wow.errors)
        assert.are.same({}, wow.sent)
        assert.is_truthy(table.concat(wow.printed, "\n"):find("Restart the game", 1, true))
    end)
end)
