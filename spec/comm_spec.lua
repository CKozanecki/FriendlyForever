-- Spec: #32
-- The hidden channel between copies of the addon: addon messages over the
-- game's own routes, with every incoming message treated as untrusted.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local PREFIX = "FriendlyFvr"
local ME = "Me"

-- What the addon sees from one other player's message.
local function receive(text, route, sender, prefix)
    wow.fire("CHAT_MSG_ADDON", prefix or PREFIX, text, route or "WHISPER", sender or "Ann-Vale", "", 0, 0, "", 0)
end

local function hello(subject, version, wantsReply, protocol)
    return table.concat({ protocol or "1", "HELLO", subject, version or "0.8.0", wantsReply or "0" }, ";")
end

local function count(ns, key)
    return ns.Diag.Counters()[key] or 0
end

local function noErrors(ns)
    assert.are.same({}, wow.errors)
    assert.are.equal(0, count(ns, "luaErrors"))
end

describe("Hidden channel", function()
    describe("two simulated clients exchange versioned messages over each route (white)", function()
        local a, b, net

        -- Ann and Bo, each running the addon, in the same guild and in the
        -- given group (or none).
        local function pair(groupType, raidSized, opts)
            opts = opts or {}
            local function group(state, other)
                if groupType then
                    wow.setGroup(groupType, { other }, raidSized)
                end
                if opts.before then opts.before(state) end
            end
            a = wow.newClient({ name = "Ann", surname = "Vale", before = function(s) group(s, "Bo-Lake") end })
            b = wow.newClient({ name = "Bo", surname = "Lake", before = function(s) group(s, "Ann-Vale") end })
            net = wow.network({ a, b })
        end

        local function sayHelloFrom(client, route, target)
            wow.use(client)
            local ok, why = client.ns.Comm.SayHello(route, target)
            assert.is_true(ok, why)
            wow.deliver(net)
        end

        -- What client sent, decoded from the simulator's own record.
        local function sentBy(client)
            wow.use(client)
            local out = {}
            for _, m in ipairs(wow.addonSent) do out[#out + 1] = m end
            return out
        end

        local function knows(client, other, version)
            wow.use(client)
            assert.is_true(client.ns.Comm.IsPeer(other.full), client.full .. " knows " .. other.full)
            assert.are.equal(version or "0.8.0", client.ns.Comm.PeerVersion(other.full))
        end

        it("registers one prefix of at most 16 characters", function()
            pair()
            wow.use(a)
            assert.is_true(wow.addonPrefixes[PREFIX])
            assert.is_true(#PREFIX <= 16)
            assert.are.equal(PREFIX, a.ns.Comm.PREFIX)
            assert.is_true(a.ns.Comm.Ready())
        end)

        it("WHISPER: a whispered hello is answered once, and each side learns the other runs the addon", function()
            pair()
            sayHelloFrom(a, "WHISPER", "Bo-Lake")
            knows(b, a)
            knows(a, b)
            local fromA, fromB = sentBy(a), sentBy(b)
            assert.are.equal(1, #fromA)
            assert.are.equal(1, #fromB)
            assert.are.same({ prefix = PREFIX, channel = "WHISPER", target = "Bo-Lake" },
                { prefix = fromA[1].prefix, channel = fromA[1].channel, target = fromA[1].target })
            assert.are.equal("1;HELLO;Ann-Vale;0.8.0;1", fromA[1].text)
            assert.are.equal("1;HELLO;Bo-Lake;0.8.0;0", fromB[1].text)
            wow.use(a); noErrors(a.ns)
            wow.use(b); noErrors(b.ns)
        end)

        for _, case in ipairs({
            { route = "PARTY", groupType = "party" },
            { route = "RAID", groupType = "raid" },
            { route = "INSTANCE_CHAT", groupType = "instance" },
            { route = "GUILD" },
        }) do
            it(case.route .. ": a hello reaches the other copy, which doesn't answer it", function()
                pair(case.groupType)
                sayHelloFrom(a, case.route)
                knows(b, a)
                wow.use(a)
                assert.is_false(a.ns.Comm.IsPeer("Bo-Lake"), "group and guild hellos aren't answered")
                assert.are.equal(1, #sentBy(a))
                assert.are.equal(0, #sentBy(b))
                assert.are.equal(case.route, sentBy(a)[1].channel)
                assert.are.equal("1;HELLO;Ann-Vale;0.8.0;0", sentBy(a)[1].text)
                -- B answers on the same route and A learns of it too.
                sayHelloFrom(b, case.route)
                knows(a, b)
                wow.use(b); assert.are.equal(1, count(b.ns, "commReceived"))
                wow.use(a); assert.are.equal(1, count(a.ns, "commReceived"))
            end)
        end

        it("reads the sender whether the game spells it 'First-Surname' or 'First Surname'", function()
            pair(nil, nil, { before = function(s) s.addonSenderForm = "space" end })
            sayHelloFrom(a, "WHISPER", "Bo-Lake")
            knows(b, a)
            knows(a, b)
        end)

        it("doesn't hear its own group and guild messages coming back", function()
            pair("party")
            sayHelloFrom(a, "PARTY")
            sayHelloFrom(a, "GUILD")
            wow.use(a)
            assert.are.equal(0, count(a.ns, "commReceived"))
            assert.are.equal(0, a.ns.Comm.PeerCount())
        end)

        it("answers a whispered hello from the same player at most once per few minutes", function()
            pair()
            for _ = 1, 3 do sayHelloFrom(a, "WHISPER", "Bo-Lake") end
            assert.are.equal(1, #sentBy(b))
            wow.advanceAll(net, 299, 1)
            sayHelloFrom(a, "WHISPER", "Bo-Lake")
            assert.are.equal(1, #sentBy(b), "not again within 5 minutes")
            wow.advanceAll(net, 1, 1)
            sayHelloFrom(a, "WHISPER", "Bo-Lake")
            assert.are.equal(2, #sentBy(b), "again after 5 minutes")
        end)

        it("never sends a chat line, casts or changes a setting while talking", function()
            pair("raid")
            sayHelloFrom(a, "RAID")
            sayHelloFrom(a, "WHISPER", "Bo-Lake")
            for _, c in ipairs({ a, b }) do
                wow.use(c)
                assert.are.same({}, wow.sent)
                assert.are.same({}, wow.casts)
                assert.are.same({}, wow.cvarWrites)
            end
        end)
    end)

    describe("sending", function()
        local ns

        before_each(function()
            ns = wow.boot()
        end)

        it("stays under its own limit: a burst, then one message every couple of seconds (white)", function()
            local C = ns.Comm
            for _ = 1, C.MAX_QUEUE + C.SEND_BURST do C.SayHello("GUILD") end
            assert.are.equal(C.SEND_BURST, #wow.addonSent)
            wow.advance(C.SEND_REFILL * 3 + 0.01)
            assert.are.equal(C.SEND_BURST + 3, #wow.addonSent)
            wow.advance(60)
            -- The queue holds at most MAX_QUEUE, each for at most MAX_QUEUE_AGE
            -- (10 s): those due at 2, 4 ... 10 s go, the three due later don't.
            assert.are.equal(C.SEND_BURST + 5, #wow.addonSent)
            assert.are.same({}, wow.addonRefused)
            assert.are.equal(C.SEND_BURST + 5, count(ns, "commSent"))
            assert.are.equal(3, count(ns, "commNotSent"))
            assert.are.equal(0, C.QueueLength())
            -- Once it has drained, the next message goes straight away.
            C.SayHello("GUILD")
            assert.are.equal(C.SEND_BURST + 6, #wow.addonSent)
        end)

        it("drops rather than queues without limit (black)", function()
            local C = ns.Comm
            local refused = 0
            for _ = 1, 100 do
                if not C.SayHello("GUILD") then refused = refused + 1 end
            end
            assert.are.equal(100 - C.SEND_BURST - C.MAX_QUEUE, refused)
            assert.are.equal(refused, count(ns, "commNotSent"))
            assert.are.equal(C.MAX_QUEUE, C.QueueLength())
            assert.are.equal(1, #wow.timers, "one timer drains the queue, however many wait")
        end)

        it("only uses the routes the game offers, and only those it's in (black)", function()
            local C = ns.Comm
            assert.is_false((C.Send("HELLO", { "0.8.0", "0" }, "SAY")))
            assert.is_false((C.Send("HELLO", { "0.8.0", "0" }, "CHANNEL", "1")))
            assert.is_false((C.Send("HELLO", { "0.8.0", "1" }, "WHISPER", "not a name!")))
            -- Not in a party: queued, then not sent, without asking the game.
            assert.is_true((C.SayHello("PARTY")))
            assert.are.same({}, wow.addonSent)
            assert.are.same({}, wow.addonRefused)
            assert.are.equal(1, count(ns, "commNotSent"))
        end)

        it("checks its own messages like anyone else's (black)", function()
            local C = ns.Comm
            assert.is_false((C.Send("HELLO", { "x;y", "0" }, "GUILD")))
            assert.is_false((C.Send("HELLO", { "0.8.0" }, "GUILD")))
            assert.is_false((C.Send("HELLO", { "0.8.0", "0", "extra" }, "GUILD")))
            assert.is_false((C.Send("NOPE", {}, "GUILD")))
            assert.are.same({}, wow.addonSent)
        end)

        it("sends nothing in chat lockdown or when the game refuses it, and counts it (black)", function()
            local C = ns.Comm
            wow.state.lockdown = true
            C.SayHello("GUILD")
            wow.state.lockdown = false
            wow.state.addonBlocked = true
            C.SayHello("GUILD")
            assert.are.same({}, wow.addonSent)
            assert.are.equal(2, count(ns, "commNotSent"))
            noErrors(ns)
        end)

        it("sends nothing and hears nothing while the addon is switched off (white)", function()
            ns.SetEnabled(false)
            assert.is_false((ns.Comm.SayHello("GUILD")))
            receive(hello("Ann-Vale"), "GUILD")
            assert.are.same({}, wow.addonSent)
            assert.are.equal(0, ns.Comm.PeerCount())
            ns.SetEnabled(true)
            receive(hello("Ann-Vale"), "GUILD")
            assert.is_true(ns.Comm.IsPeer("Ann-Vale"))
        end)
    end)

    describe("fallback: without addon messages the addon works as before (black)", function()
        it("loads and runs with no addon-message API", function()
            local ns = wow.boot({ before = function(s) s.noAddonMessages = true end })
            assert.is_false(ns.Comm.Ready())
            assert.is_false((ns.Comm.SayHello("GUILD")))
            receive(hello("Ann-Vale"), "GUILD")
            assert.are.equal(0, ns.Comm.PeerCount())
            noErrors(ns)
        end)

        it("stays closed when the prefix can't be registered", function()
            local ns = wow.boot({ before = function()
                _G.C_ChatInfo.RegisterAddonMessagePrefix = function()
                    return _G.Enum.RegisterAddonMessagePrefixResult.MaxPrefixes
                end
            end })
            assert.is_false(ns.Comm.Ready())
            noErrors(ns)
        end)

        it("forgets other copies after a while", function()
            local ns = wow.boot()
            receive(hello("Ann-Vale"), "GUILD")
            assert.is_true(ns.Comm.IsPeer("Ann-Vale"))
            wow.advance(ns.Comm.PEER_TTL + 1)
            assert.is_false(ns.Comm.IsPeer("Ann-Vale"))
            assert.are.equal(0, ns.Comm.PeerCount())
        end)

        it("shows the channel in /friendly status", function()
            local ns = wow.boot()
            local function status()
                wow.printed = {}
                ns.Diag.Call(SlashCmdList.FRIENDLYFOREVER, "status")
                return table.concat(wow.printed, "\n")
            end
            ns.Comm.SayHello("GUILD")
            ns.Comm.SayHello("PARTY") -- not in a party: not sent
            ns.Comm.SayHello("RAID")
            receive(hello("Ann-Vale"), "GUILD")
            -- A different count of each kind, from different senders, spaced out.
            local n = 0
            local function times(k, text, route, sender, prefix)
                for _ = 1, k do
                    n = n + 1
                    receive(text, route, sender or ("Eve-M" .. string.char(97 + n % 26) .. string.char(97 + math.floor(n / 26))), prefix)
                end
                wow.advance(10)
            end
            times(1, wow.secret(hello("Bo-Lake")), "GUILD", "Bo-Lake")
            times(2, string.rep("x", 300), "GUILD")
            times(3, "junk", "GUILD")
            times(4, hello("Ann-Vale", nil, nil, "2"), "GUILD")
            times(5, "1;NOPE;x", "GUILD")
            times(6, hello("Ann-Vale"), "SAY")
            times(7, hello("Ann-Vale"), "GUILD")
            times(6 + 8, hello("Fay-Dune"), "GUILD", "Fay-Dune")
            local text = status()
            assert.truthy(text:find("addon messages: |cff00ff00open|r; 1 sent, 2 not sent, 7 received; "
                .. "2 other copies seen", 1, true), text)
            assert.truthy(text:find("addon messages dropped: 1 unreadable, 2 oversized, 3 malformed, 4 wrong version, "
                .. "5 unknown type, 6 wrong route, 7 spoofed, 8 flooding", 1, true), text)
            ns.SetEnabled(false)
            assert.truthy(status():find("addon messages: closed (addon off);", 1, true))
        end)

        it("shows a closed channel in /friendly status when the game has none", function()
            local ns = wow.boot({ before = function(s) s.noAddonMessages = true end })
            wow.printed = {}
            ns.Diag.Call(SlashCmdList.FRIENDLYFOREVER, "status")
            assert.truthy(table.concat(wow.printed, "\n"):find("addon messages: |cffff4040closed|r;", 1, true))
        end)
    end)

    describe("malformed, oversized, wrong-version, spoofed-sender and flooding messages (black)", function()
        local ns

        before_each(function()
            ns = wow.boot()
        end)

        local function dropped(key, text, route, sender, prefix)
            -- Spaced out, so these aren't a flood.
            wow.advance(ns.Comm.PEER_BURST * ns.Comm.PEER_REFILL)
            local before = count(ns, key)
            receive(text, route, sender, prefix)
            assert.are.equal(before + 1, count(ns, key), key .. " for " .. tostring(text))
            assert.are.equal(0, count(ns, "commReceived"))
            assert.are.equal(0, ns.Comm.PeerCount())
            noErrors(ns)
        end

        it("drops malformed messages and counts them", function()
            for _, text in ipairs({
                "", "1", "1;HELLO", "x;HELLO;Ann-Vale;0.8.0;0", "1.0;HELLO;Ann-Vale;0.8.0;0",
                "1;HELLO;Ann-Vale;0.8.0", "1;HELLO;Ann-Vale;0.8.0;0;extra", "1;HELLO;Ann-Vale;0.8.0;2",
                "1;HELLO;Ann-Vale;banana;0", "1;HELLO;Ann-Vale;|cffff0000x|r;0", "1;HELLO;Ann-Vale;;0",
                "1;HELLO;Ann-Vale;0.8.0;0;;;;;;;;;;;;;", "1;HELLO;Ann-Vale;99999999999999.0.0;0",
            }) do
                dropped("commMalformed", text)
            end
            dropped("commMalformed", 42)
            dropped("commMalformed", nil)
            dropped("commMalformed", { "table" })
            dropped("commMalformed", hello("Ann-Vale"), "WHISPER", "")
            dropped("commMalformed", hello("Ann-Vale"), "WHISPER", 12)
        end)

        it("drops messages over 255 bytes and counts them", function()
            dropped("commOversized", hello("Ann-Vale") .. string.rep("x", 256))
            dropped("commOversized", string.rep(";", 256))
        end)

        it("ignores other protocol versions and unknown types, and counts them", function()
            dropped("commWrongVersion", hello("Ann-Vale", nil, nil, "2"))
            dropped("commWrongVersion", hello("Ann-Vale", nil, nil, "0"))
            dropped("commUnknownType", "1;GOODBYE;Ann-Vale;0.8.0;0")
            dropped("commUnknownType", "1;__index;Ann-Vale")
        end)

        it("drops messages on routes the addon doesn't use", function()
            dropped("commWrongRoute", hello("Ann-Vale"), "SAY")
            dropped("commWrongRoute", hello("Ann-Vale"), "CHANNEL")
            dropped("commWrongRoute", hello("Ann-Vale"), 7)
        end)

        it("drops a message about someone other than its sender (spoofed)", function()
            dropped("commSpoofed", hello("Bo-Lake"), "WHISPER", "Ann-Vale")
            dropped("commSpoofed", hello("Ann"), "WHISPER", "Ann-Vale")
            dropped("commSpoofed", hello(ME), "GUILD", "Ann-Vale")
        end)

        it("drops unreadable (secret) messages without comparing them", function()
            dropped("commUnreadable", wow.secret(hello("Ann-Vale")), "GUILD", "Ann-Vale")
            dropped("commUnreadable", hello("Ann-Vale"), "GUILD", wow.secret("Ann-Vale"))
            dropped("commUnreadable", hello("Ann-Vale"), wow.secret("GUILD"), "Ann-Vale")
        end)

        it("ignores other addons' messages, and any with an unreadable prefix, without counting them", function()
            receive(hello("Ann-Vale"), "GUILD", "Ann-Vale", "OtherAddon")
            receive("anything", "GUILD", "Ann-Vale", 5)
            receive(hello("Ann-Vale"), "GUILD", "Ann-Vale", wow.secret(PREFIX))
            for key, n in pairs(ns.Diag.Counters()) do
                assert.is_nil(key:find("^comm"), key .. " = " .. n)
            end
            noErrors(ns)
        end)

        it("drops a flood from one sender after a short burst, and counts it", function()
            local C = ns.Comm
            for _ = 1, 50 do receive(hello("Ann-Vale"), "GUILD", "Ann-Vale") end
            assert.are.equal(C.PEER_BURST, count(ns, "commReceived"))
            assert.are.equal(50 - C.PEER_BURST, count(ns, "commFlood"))
            -- Someone else is still heard.
            receive(hello("Bo-Lake"), "GUILD", "Bo-Lake")
            assert.is_true(C.IsPeer("Bo-Lake"))
            -- And Ann again, once her allowance has refilled.
            wow.advance(C.PEER_REFILL * C.PEER_BURST)
            receive(hello("Ann-Vale", "0.9.0"), "GUILD", "Ann-Vale")
            assert.are.equal("0.9.0", C.PeerVersion("Ann-Vale"))
            noErrors(ns)
        end)

        it("caps what everyone together can make it read", function()
            local C = ns.Comm
            for i = 1, 300 do
                local name = "Ann-V" .. string.char(97 + i % 26) .. string.char(97 + math.floor(i / 26) % 26)
                receive(hello(name), "GUILD", name)
            end
            assert.are.equal(C.ALL_BURST, count(ns, "commReceived"))
            assert.are.equal(300 - C.ALL_BURST, count(ns, "commFlood"))
        end)

        it("keeps its lists of senders and other copies bounded", function()
            local C = ns.Comm
            local n = 0
            for i = 1, 26 do
                for j = 1, 26 do
                    n = n + 1
                    if n > C.MAX_PEERS + 50 then break end
                    local name = "Ann-V" .. string.char(96 + i) .. string.char(96 + j)
                    receive(hello(name), "GUILD", name)
                    wow.advance(C.ALL_REFILL)
                end
            end
            assert.are.equal(C.MAX_PEERS, C.PeerCount())
            -- The newest are kept, the oldest forgotten.
            assert.is_true(C.IsPeer("Ann-Vjp"))
            assert.is_false(C.IsPeer("Ann-Vaa"))
            noErrors(ns)
        end)

        it("answers a whisper flood at most once", function()
            for _ = 1, 30 do receive(hello("Ann-Vale", nil, "1"), "WHISPER", "Ann-Vale") end
            wow.advance(60)
            assert.are.equal(1, #wow.addonSent)
            assert.are.equal("Ann-Vale", wow.addonSent[1].target)
        end)

        it("keeps working when a message handler raises an error", function()
            ns.Comm.RegisterType("BOOM", { fields = {}, routes = { GUILD = true }, handler = function() error("boom") end })
            receive("1;BOOM;Ann-Vale", "GUILD")
            assert.are.equal(1, count(ns, "luaErrors"))
            receive(hello("Ann-Vale"), "GUILD")
            assert.is_true(ns.Comm.IsPeer("Ann-Vale"))
        end)
    end)

    describe("chaos (red tests)", function()
        local SENDERS = { "Ann-Vale", "Bo-Lake", "Me", "Cid Rock", "x", "", "Dot-Fern-Moss" }
        local ROUTES = { "WHISPER", "PARTY", "RAID", "INSTANCE_CHAT", "GUILD", "SAY", "CHANNEL" }

        local function randomBytes()
            local n = random.random(0, 300)
            local out = {}
            for i = 1, n do
                -- Mostly bytes that mean something to the parser.
                local r = random.random()
                if r < 0.2 then out[i] = ";"
                elseif r < 0.3 then out[i] = tostring(random.random(0, 9))
                else out[i] = string.char(random.random(0, 255)) end
            end
            return table.concat(out)
        end

        local function deepCopy(v)
            if type(v) ~= "table" then return v end
            local out = {}
            for k, x in pairs(v) do out[k] = deepCopy(x) end
            return out
        end

        it("never errors, casts or speaks, leaves settings alone and stays under its send limit", function()
            for _, seed in ipairs({ 3, 32, 404, 2026 }) do
                random.seed(seed)
                local ns = wow.boot()
                local C = ns.Comm
                wow.setGroup(({ "party", "raid", "instance" })[random.random(3)], { "Ann-Vale", "Bo-Lake" })
                local settings = deepCopy(ns.db)
                local valid = 0
                for _ = 1, 1500 do
                    local r = random.random()
                    local sender = SENDERS[random.random(#SENDERS)]
                    local route = ROUTES[random.random(#ROUTES)]
                    if r < 0.4 then
                        receive(randomBytes(), route, sender, random.random() < 0.9 and PREFIX or "Other")
                    elseif r < 0.55 then
                        -- A valid-looking hello, maybe about someone else, maybe asking for a reply.
                        local about = random.random() < 0.8 and sender or SENDERS[random.random(#SENDERS)]
                        valid = valid + 1
                        receive(hello(about, nil, random.random() < 0.5 and "1" or "0"), route, sender)
                    elseif r < 0.65 then
                        -- A flood.
                        for _ = 1, random.random(5, 40) do receive(hello(sender), route, sender) end
                    elseif r < 0.7 then
                        receive(hello("Ann-Vale"), wow.secret(route), wow.secret(sender), wow.secret(PREFIX))
                    elseif r < 0.85 then
                        C.SayHello(route, SENDERS[random.random(#SENDERS)])
                    elseif r < 0.9 then
                        wow.state.lockdown = random.random() < 0.3
                        wow.state.addonBlocked = random.random() < 0.3
                    else
                        wow.advance(random.random() * 5)
                    end
                end
                wow.advance(60)

                -- Invariants from the simulator's own records.
                assert.are.same({}, wow.errors, "seed " .. seed)
                assert.are.same({}, wow.sent, "no chat lines")
                assert.are.same({}, wow.blocked, "no chat lines tried")
                assert.are.same({}, wow.emotes)
                assert.are.same({}, wow.casts, "no casts")
                assert.are.same({}, wow.cvarWrites)
                for _, m in ipairs(wow.addonRefused) do
                    assert.are_not.equal(_G.Enum.SendAddonMessageResult.AddonMessageThrottle, m.result,
                        "the game's throttle is never reached")
                end
                -- Our own limit, from the times the game recorded: in any
                -- window of w seconds, at most SEND_BURST + w / SEND_REFILL.
                local attempts = {}
                for _, m in ipairs(wow.addonSent) do attempts[#attempts + 1] = m.time end
                for _, m in ipairs(wow.addonRefused) do attempts[#attempts + 1] = m.time end
                table.sort(attempts)
                for i = 1, #attempts do
                    for j = i, #attempts do
                        local w = attempts[j] - attempts[i]
                        assert.is_true(j - i + 1 <= C.SEND_BURST + w / C.SEND_REFILL + 1e-9,
                            string.format("seed %d: %d sends in %.2fs", seed, j - i + 1, w))
                    end
                end
                assert.are.same(settings.enabled, ns.db.enabled)
                for key, value in pairs(settings) do
                    if key ~= "diagLog" then assert.are.same(value, ns.db[key], "setting " .. key) end
                end
                assert.is_true(C.PeerCount() <= C.MAX_PEERS)
                assert.is_true(C.QueueLength() <= C.MAX_QUEUE)
                assert.is_true(valid > 0)

                -- And afterwards the channel still works.
                wow.state.lockdown, wow.state.addonBlocked = false, false
                wow.advance(C.PEER_REFILL * C.PEER_BURST + C.ALL_REFILL * C.ALL_BURST)
                receive(hello("Eve-Moss", "1.2.3"), "GUILD", "Eve-Moss")
                assert.are.equal("1.2.3", C.PeerVersion("Eve-Moss"), "seed " .. seed)
            end
        end)
    end)
end)

describe("No chat channel is ever joined", function()
    -- Every file the addon loads.
    local function addonSources()
        local _, files = wow.parseToc()
        local out = {}
        for _, file in ipairs(files) do out[#out + 1] = { file = file, text = wow.readFile(file) } end
        return out
    end

    it("no addon file calls a function that joins or makes a chat channel (white)", function()
        for _, src in ipairs(addonSources()) do
            for _, fn in ipairs({ "JoinChannelByName", "JoinTemporaryChannel", "JoinPermanentChannel",
                "ChatFrame_AddChannel", "SwapChatChannelByLocalID", "C_ChatInfo.SwapChatChannelsByChannelIndex" }) do
                assert.is_nil(src.text:find(fn, 1, true), src.file .. " uses " .. fn)
            end
        end
    end)

    it("addon messages use only the game's own routes (white)", function()
        local ns = wow.boot()
        assert.are.same({ WHISPER = true, PARTY = true, RAID = true, INSTANCE_CHAT = true, GUILD = true }, ns.Comm.ROUTES)
    end)

    it("the README says so (white)", function()
        local readme = wow.readFile("README.md")
        assert.truthy(readme:find("**No chat channel is ever joined.**", 1, true))
        assert.truthy(readme:find("General, Trade and LocalDefense keep their numbers", 1, true))
    end)
end)

describe("Hidden channel hot path", function()
    -- CHAT_MSG_ADDON fires for every addon's messages, many a second in a raid.
    local ns

    before_each(function()
        ns = wow.boot()
    end)

    local function eventFrame()
        for _, f in ipairs(wow.frames) do
            if f.events.CHAT_MSG_ADDON then return f end
        end
    end

    it("hands CHAT_MSG_ADDON's handler only its four arguments, so it takes the fast path", function()
        local counts = {}
        local call = ns.Diag.Call
        ns.Diag.Call = function(fn, ...)
            counts[#counts + 1] = select("#", ...)
            return call(fn, ...)
        end
        receive(hello("Ann-Vale"), "GUILD")
        assert.are.equal(4, counts[1])
        assert.is_true(ns.Comm.IsPeer("Ann-Vale"))
    end)

    it("handling another addon's message allocates nothing", function()
        local f = eventFrame()
        local onEvent = f.scripts.OnEvent
        for _ = 1, 10 do onEvent(f, "CHAT_MSG_ADDON", "OtherAddon", "data", "RAID", "Ann-Vale", "", 0, 0, "", 0) end
        collectgarbage("collect")
        collectgarbage("stop")
        local before = collectgarbage("count")
        for _ = 1, 5000 do onEvent(f, "CHAT_MSG_ADDON", "OtherAddon", "data", "RAID", "Ann-Vale", "", 0, 0, "", 0) end
        local grown = collectgarbage("count") - before
        collectgarbage("restart")
        assert.is_true(grown < 1, string.format("grew %.1fKB", grown))
    end)
end)

describe("After an update that adds Comm.lua and a /reload (no restart) (black)", function()
    it("asks for a restart instead of erroring, and hears no addon messages", function()
        wow.reset()
        local loaded = {}
        local _, files = wow.parseToc()
        for _, file in ipairs(files) do
            if file ~= "Comm.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
        end
        wow.fire("ADDON_LOADED", wow.ADDON_NAME)
        wow.fire("PLAYER_ENTERING_WORLD", true, false)
        receive(hello("Ann-Vale"), "GUILD")
        _G.SlashCmdList.FRIENDLYFOREVER("status")
        assert.are.same({}, wow.errors)
        assert.are.same({}, wow.addonSent)
        assert.is_truthy(table.concat(wow.printed, "\n"):find("Restart the game", 1, true))
    end)
end)

describe("Hidden channel limits and edge cases", function()
    local function logText(ns)
        return table.concat(ns.db.diagLog, "\n")
    end

    it("keeps to the limits written on #32, well below the game's own (white)", function()
        local C = wow.boot().Comm
        assert.are.same({
            VERSION = 1, MAX_BYTES = 255, MAX_FIELDS = 8,
            SEND_BURST = 5, SEND_REFILL = 2, MAX_QUEUE = 8, MAX_QUEUE_AGE = 10,
            PEER_BURST = 6, PEER_REFILL = 1, ALL_BURST = 40, ALL_REFILL = 0.1, MAX_SENDERS = 200,
            MAX_PEERS = 200, PEER_TTL = 1800, REPLY_GAP = 300,
        }, {
            VERSION = C.VERSION, MAX_BYTES = C.MAX_BYTES, MAX_FIELDS = C.MAX_FIELDS,
            SEND_BURST = C.SEND_BURST, SEND_REFILL = C.SEND_REFILL, MAX_QUEUE = C.MAX_QUEUE,
            MAX_QUEUE_AGE = C.MAX_QUEUE_AGE, PEER_BURST = C.PEER_BURST, PEER_REFILL = C.PEER_REFILL,
            ALL_BURST = C.ALL_BURST, ALL_REFILL = C.ALL_REFILL, MAX_SENDERS = C.MAX_SENDERS,
            MAX_PEERS = C.MAX_PEERS, PEER_TTL = C.PEER_TTL, REPLY_GAP = C.REPLY_GAP,
        })
        assert.is_true(C.SEND_BURST <= wow.ADDON_BURST / 2)
        assert.is_true(C.SEND_REFILL >= 2 * wow.ADDON_REFILL)
    end)

    describe("the game's answers (black)", function()
        it("counts a prefix that's already registered as registered", function()
            local ns = wow.boot({ before = function() wow.addonPrefixes[PREFIX] = true end })
            assert.is_true(ns.Comm.Ready())
        end)

        it("works with an older client that answers true and has no Enum", function()
            local ns = wow.boot({ before = function()
                _G.Enum = nil
                local send = _G.C_ChatInfo.SendAddonMessage
                _G.C_ChatInfo.RegisterAddonMessagePrefix = function() return true end
                _G.C_ChatInfo.SendAddonMessage = function(...) send(...) return true end
            end })
            assert.is_true(ns.Comm.Ready())
            ns.Comm.SayHello("GUILD")
            assert.are.equal(1, count(ns, "commSent"))
        end)

        it("reads the game's result codes without Enum", function()
            local ns = wow.boot({ before = function() _G.Enum = nil end })
            assert.is_true(ns.Comm.Ready())
            ns.Comm.SayHello("GUILD")
            assert.are.equal(1, count(ns, "commSent"))
            wow.state.addonBlocked = true
            ns.Comm.SayHello("GUILD")
            assert.are.equal(1, count(ns, "commNotSent"))
        end)

        it("counts a send the game errors on, or answers with a secret, as not sent", function()
            local ns = wow.boot()
            _G.C_ChatInfo.SendAddonMessage = function() error("nope") end
            ns.Comm.SayHello("GUILD")
            _G.C_ChatInfo.SendAddonMessage = function() return wow.secret(0) end
            ns.Comm.SayHello("GUILD")
            assert.are.equal(0, count(ns, "commSent"))
            assert.are.equal(2, count(ns, "commNotSent"))
            noErrors(ns)
        end)

        it("never reads a secret answer, to a send or a registration", function()
            local ns = wow.boot({ db = { debug = true }, before = function()
                _G.C_ChatInfo.RegisterAddonMessagePrefix = function() return wow.secret(0) end
            end })
            assert.is_false(ns.Comm.Registered())
            assert.truthy(logText(ns):find("couldn't register the prefix: unreadable answer", 1, true))
            ns = wow.boot({ db = { debug = true } })
            _G.C_ChatInfo.SendAddonMessage = function() return wow.secret(0) end
            ns.Comm.SayHello("GUILD")
            assert.truthy(logText(ns):find("didn't send HELLO on GUILD: unreadable answer", 1, true))
            assert.is_nil(logText(ns):find("<secret>", 1, true))
            noErrors(ns)
        end)

        it("stays closed and says why when the client has no addon messages", function()
            local ns = wow.boot({ db = { debug = true }, before = function()
                _G.C_ChatInfo.RegisterAddonMessagePrefix = nil
            end })
            assert.is_false(ns.Comm.Registered())
            assert.truthy(logText(ns):find("this game client has no addon messages", 1, true))
        end)

        it("stays closed when registering raises an error", function()
            local ns = wow.boot({ db = { debug = true }, before = function()
                _G.C_ChatInfo.RegisterAddonMessagePrefix = function() error("no") end
            end })
            assert.is_false(ns.Comm.Registered())
            assert.truthy(logText(ns):find("couldn't register the prefix: error", 1, true))
            noErrors(ns)
        end)

        it("logs a prefix the game won't register", function()
            local ns = wow.boot({ db = { debug = true }, before = function()
                _G.C_ChatInfo.RegisterAddonMessagePrefix = function() return 3 end
            end })
            assert.is_false(ns.Comm.Registered())
            assert.truthy(logText(ns):find("couldn't register the prefix: 3", 1, true))
        end)
    end)

    describe("message types", function()
        local ns
        before_each(function() ns = wow.boot() end)

        local function noop() end

        it("refuses a badly made type (black)", function()
            local R = ns.Comm.RegisterType
            local ok8 = {}
            for i = 1, 8 do ok8[i] = ns.Comm.Field.Key end
            local nine = { unpack(ok8) }
            nine[9] = ns.Comm.Field.Key
            for _, bad in ipairs({
                { "lower", { fields = {}, routes = {}, handler = noop } },
                { "THIRTEENCHARS", { fields = {}, routes = {}, handler = noop } },
                { 42, { fields = {}, routes = {}, handler = noop } },
                { "NINE", { fields = nine, routes = {}, handler = noop } },
                { "NOHANDLER", { fields = {}, routes = {} } },
                { "SAYS", { fields = {}, routes = { SAY = true }, handler = noop } },
            }) do
                assert.has_error(function() R(bad[1], bad[2]) end, nil, tostring(bad[1]))
            end
            assert.has_no.errors(function() R("TWELVECHARSX", { fields = ok8, routes = { GUILD = true }, handler = noop }) end)
        end)

        it("accepts a type's full field count and no more (white, black)", function()
            local got
            local fields = {}
            for i = 1, 8 do fields[i] = ns.Comm.Field.Key end
            ns.Comm.RegisterType("EIGHT", { fields = fields, routes = { GUILD = true },
                handler = function(sender, f) got = { sender, #f } end })
            receive("1;EIGHT;Ann-Vale;a;b;c;d;e;f;g;h", "GUILD")
            assert.are.same({ "Ann-Vale", 8 }, got)
            wow.advance(10)
            receive("1;EIGHT;Ann-Vale;a;b;c;d;e;f;g;h;i", "GUILD")
            assert.are.equal(1, count(ns, "commMalformed"))
        end)

        it("checks keys: letters, digits and underscores, 1 to 24 (black)", function()
            local K = ns.Comm.Field.Key
            assert.is_true(K("kings_1"))
            assert.is_true(K(string.rep("a", 24)))
            assert.is_false(K(string.rep("a", 25)))
            assert.is_false(K(""))
            assert.is_false(K("a b"))
            assert.is_false(K("a-b"))
        end)
    end)

    describe("incoming edges (black)", function()
        local ns
        before_each(function() ns = wow.boot({ db = { debug = true } }) end)

        it("reads 255 bytes as a message, and 256 as oversized", function()
            receive(string.rep("x", 255), "GUILD")
            assert.are.equal(1, count(ns, "commMalformed"))
            assert.are.equal(0, count(ns, "commOversized"))
            receive(string.rep("x", 256), "GUILD")
            assert.are.equal(1, count(ns, "commOversized"))
        end)

        it("drops a message whose route isn't text", function()
            receive(hello("Ann-Vale"), {}, "Ann-Vale")
            wow.fire("CHAT_MSG_ADDON", PREFIX, hello("Ann-Vale"), nil, "Ann-Vale")
            assert.are.equal(2, count(ns, "commWrongRoute"))
            noErrors(ns)
        end)

        it("logs why each message was dropped, and who sent it", function()
            receive(hello("Bo-Lake"), "GUILD", "Ann-Vale")
            receive(hello("Ann-Vale"), "GUILD", wow.secret("Ann-Vale"))
            assert.truthy(logText(ns):find("dropped a message from Ann-Vale: says it is about Bo-Lake", 1, true))
            assert.truthy(logText(ns):find("dropped a message from ?: unreadable text, route or sender", 1, true))
        end)

        it("logs who runs the addon, and what wasn't sent and why", function()
            receive(hello("Ann-Vale", "0.9.1"), "GUILD")
            ns.Comm.SayHello("PARTY")
            _G.C_ChatInfo.SendAddonMessage = function() return 9 end
            ns.Comm.SayHello("GUILD")
            _G.C_ChatInfo.SendAddonMessage = function() error("boom") end
            ns.Comm.SayHello("GUILD")
            local log = logText(ns)
            assert.truthy(log:find("Ann-Vale runs Friendly Forever 0.9.1", 1, true))
            assert.truthy(log:find("didn't send HELLO on PARTY: not in that group any more", 1, true))
            assert.truthy(log:find("didn't send HELLO on GUILD: the game answered 9", 1, true))
            assert.truthy(log:find("didn't send HELLO on GUILD: error", 1, true))
        end)
    end)

    describe("other copies seen", function()
        local ns
        before_each(function() ns = wow.boot() end)

        it("remembers a copy for 30 minutes exactly (white)", function()
            receive(hello("Ann-Vale"), "GUILD")
            wow.advance(1800)
            assert.is_true(ns.Comm.IsPeer("Ann-Vale"))
            assert.are.equal(1, ns.Comm.PeerCount())
            wow.advance(0.5)
            assert.is_false(ns.Comm.IsPeer("Ann-Vale"))
        end)

        it("forgets every copy if the clock goes backwards (black)", function()
            receive(hello("Ann-Vale"), "GUILD")
            receive(hello("Bo-Lake"), "GUILD", "Bo-Lake")
            wow.now = wow.now - 1
            assert.are.equal(0, ns.Comm.PeerCount())
            assert.is_false(ns.Comm.IsPeer("Ann-Vale"))
        end)

        it("makes room by forgetting expired copies first, keeping the rest (white)", function()
            local C = ns.Comm
            receive(hello("Old-Timer"), "GUILD", "Old-Timer")
            wow.advance(1000)
            local names = {}
            for i = 1, C.MAX_PEERS - 1 do
                local name = "Ann-V" .. string.char(97 + i % 26) .. string.char(97 + math.floor(i / 26))
                names[i] = name
                receive(hello(name), "GUILD", name)
                wow.advance(C.ALL_REFILL)
            end
            assert.are.equal(C.MAX_PEERS, C.PeerCount())
            wow.advance(801) -- Old-Timer has expired; the rest haven't
            receive(hello("New-Comer"), "GUILD", "New-Comer")
            assert.are.equal(C.MAX_PEERS, C.PeerCount())
            assert.is_true(C.IsPeer(names[1]), "the oldest live copy is kept")
            assert.is_true(C.IsPeer("New-Comer"))
            assert.is_false(C.IsPeer("Old-Timer"))
        end)

        it("says '?' for its own version when it can't read it (black)", function()
            ns.VERSION = "beta"
            ns.Comm.SayHello("GUILD")
            assert.are.equal("1;HELLO;Me;?;0", wow.addonSent[1].text)
            receive(hello("Ann-Vale", "?"), "GUILD")
            assert.are.equal("?", ns.Comm.PeerVersion("Ann-Vale"))
        end)
    end)
end)

describe("Hidden channel edge cases, continued", function()
    local ns
    before_each(function() ns = wow.boot() end)

    local function anything() return true end

    it("needs a whole token to send: most of a refill after a burst, nothing more goes (black)", function()
        local C = ns.Comm
        for _ = 1, C.SEND_BURST do C.SayHello("GUILD") end
        wow.advance(0.9 * C.SEND_REFILL)
        C.SayHello("GUILD")
        assert.are.equal(C.SEND_BURST, #wow.addonSent)
    end)

    it("needs a whole token to hear a sender: most of a refill after a burst is still a flood (black)", function()
        local C = ns.Comm
        for _ = 1, C.PEER_BURST do receive(hello("Ann-Vale"), "GUILD") end
        wow.advance(0.9 * C.PEER_REFILL)
        receive(hello("Ann-Vale"), "GUILD")
        assert.are.equal(1, count(ns, "commFlood"))
    end)

    it("answers a whispered hello again if the clock goes backwards (black)", function()
        receive(hello("Ann-Vale", nil, "1"), "WHISPER")
        assert.are.equal(1, #wow.addonSent)
        wow.now = wow.now - 10
        wow.advance(ns.Comm.PEER_BURST * ns.Comm.PEER_REFILL) -- not a flood
        receive(hello("Ann-Vale", nil, "1"), "WHISPER")
        -- A second answer is attempted (the game may refuse it: its own
        -- throttle doesn't refill when the clock goes back).
        assert.are.equal(2, count(ns, "commSent") + count(ns, "commNotSent"))
    end)

    it("sends no target on group and guild routes (white)", function()
        ns.Comm.SayHello("GUILD", "Bo-Lake")
        assert.is_nil(wow.addonSent[1].target)
    end)

    it("sends nothing when it can't read your own name (black)", function()
        wow.state.units.player.name = wow.secret("Me")
        local ok, why = ns.Comm.SayHello("GUILD")
        assert.is_false(ok)
        assert.are.equal("can't read your name", why)
        assert.are.same({}, wow.addonSent)
    end)

    it("sends a message of exactly 255 bytes, and refuses a longer one (black)", function()
        ns.Comm.RegisterType("LONG", { fields = { anything }, routes = { GUILD = true }, handler = function() end })
        local header = "1;LONG;Me;"
        local ok = ns.Comm.Send("LONG", { string.rep("a", 255 - #header) }, "GUILD")
        assert.is_true(ok)
        assert.are.equal(255, #wow.addonSent[1].text)
        local ok2, why = ns.Comm.Send("LONG", { string.rep("a", 256 - #header) }, "GUILD")
        assert.is_false(ok2)
        assert.are.equal("too long", why)
    end)

    it("reads versions of up to 16 characters (black)", function()
        local V = ns.Comm.Field.Version
        assert.is_true(V("1234567.12345.12"))
        assert.is_false(V("1234567.12345.123"))
        assert.is_false(V("1.2"))
    end)

    describe("the senders it keeps limits for (black)", function()
        local C
        local function name(i)
            return "Ann-V" .. string.char(97 + i % 26) .. string.char(97 + math.floor(i / 26) % 26)
                .. string.char(97 + math.floor(i / 676))
        end

        before_each(function()
            C = ns.Comm
            C.ALL_BURST = 100000 -- these tests are about the per-sender limit
            wow.advance(100)
        end)

        it("keeps at most MAX_SENDERS, and turns new ones away while all are busy", function()
            for i = 1, C.MAX_SENDERS do receive(hello(name(i)), "GUILD", name(i)) end
            assert.are.equal(C.MAX_SENDERS, count(ns, "commReceived"))
            assert.are.equal(C.MAX_SENDERS, C.TrackedSenders())
            receive(hello("New-Comer"), "GUILD", "New-Comer")
            assert.are.equal(1, count(ns, "commFlood"))
            assert.are.equal(C.MAX_SENDERS, C.TrackedSenders())
        end)

        it("forgets idle senders to make room, and only those", function()
            for i = 1, C.MAX_SENDERS - 1 do receive(hello(name(i)), "GUILD", name(i)) end
            wow.advance(C.PEER_BURST * C.PEER_REFILL) -- they're idle now
            -- A busy flooder, then a crowd of newcomers.
            for _ = 1, C.PEER_BURST + 3 do receive(hello("Flood-Er"), "GUILD", "Flood-Er") end
            assert.are.equal(3, count(ns, "commFlood"))
            for i = 1, C.MAX_SENDERS - 1 do receive(hello(name(1000 + i)), "GUILD", name(1000 + i)) end
            assert.are.equal(C.MAX_SENDERS, C.TrackedSenders())
            assert.are.equal(3, count(ns, "commFlood"), "every newcomer had room")
            -- Full again, with everyone busy: the next newcomer waits.
            receive(hello("Late-Comer"), "GUILD", "Late-Comer")
            assert.are.equal(4, count(ns, "commFlood"))
            assert.are.equal(C.MAX_SENDERS, C.TrackedSenders())
            -- The flooder kept its spent allowance through all that.
            receive(hello("Flood-Er"), "GUILD", "Flood-Er")
            assert.are.equal(5, count(ns, "commFlood"))
        end)
    end)
end)
