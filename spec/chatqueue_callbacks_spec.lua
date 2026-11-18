-- Spec: #448
-- The rest of a message's callbacks run protected, as its render does
-- (#446): a channel function, an isValid or an onDone that raises an error,
-- or answers with something that can't be used, drops that message with a
-- reason (or, for onDone, ends only its own call), and the pump goes on.
-- A dropped render doesn't count against the chat cap, an AFK skip never
-- renders, and an emote is aimed only at a unit token.
local wow = require("spec.support.wow")

describe("ChatQueue protects a message's callbacks (#448)", function()
    local ns, Q

    before_each(function()
        ns = wow.boot()
        Q = ns.ChatQueue
        ns.db.linesPerMinute = 10
    end)

    local function push(text, extra)
        local result = { done = 0 }
        local item = { channel = "GUILD", label = "test", getText = function() return text end,
            onDone = function(sent, why) result.done = result.done + 1 result.sent, result.why = sent, why end }
        for k, v in pairs(extra or {}) do item[k] = v end
        Q.Push(item)
        return result
    end

    -- Queue every item while chat is locked down, then let them go.
    local function queued(fn)
        wow.state.lockdown = true
        local out = { fn() }
        wow.state.lockdown = false
        for _ = 1, 5 do wow.advance(Q.MIN_INTERVAL + 1) end
        return unpack(out)
    end

    describe("a channel function (black)", function()
        it("that errors is dropped with a reason, the error is counted, and the next line goes out", function()
            local bad, good = queued(function()
                return push("never", { channel = function() error("no channel here") end }), push("second line")
            end)
            assert.are.same({ "second line" }, wow.sentTo("GUILD"))
            assert.are.equal(1, bad.done)
            assert.is_false(bad.sent)
            assert.are.equal("channel failed to resolve", bad.why)
            assert.is_true(good.sent)
            assert.are.equal(1, ns.Diag.Counters().luaErrors, "the error is counted, not hidden")
            assert.are.equal(1, #wow.errors, "and reaches the game's error display")
        end)

        it("that answers a secret, a number or a table is dropped, never sent", function()
            for _, value in ipairs({ wow.secret("GUILD"), 7, {} }) do
                wow.sent = {}
                local r = push("never", { channel = function() return value end })
                assert.are.same({}, wow.sent, tostring(value))
                assert.are.equal(1, r.done)
                assert.is_false(r.sent)
                assert.are.equal("channel can't be used", r.why)
            end
            assert.are.same({}, wow.errors)
        end)

        it("that answers nil is still dropped as no channel (white)", function()
            local r = push("never", { channel = function() return nil end })
            assert.are.equal("no channel (not in a guild/group any more?)", r.why)
        end)
    end)

    describe("an isValid (black)", function()
        it("that errors is dropped with a reason, the error is counted, and the next line goes out", function()
            local bad, good = queued(function()
                return push("never", { isValid = function() error("bad check") end }), push("second line")
            end)
            assert.are.same({ "second line" }, wow.sentTo("GUILD"))
            assert.are.equal(1, bad.done)
            assert.are.equal("validity check failed", bad.why)
            assert.is_true(good.sent)
            assert.are.equal(1, ns.Diag.Counters().luaErrors)
        end)

        it("whose answer is a secret is dropped, never sent", function()
            local r = push("never", { isValid = function() return wow.secret(true) end })
            assert.are.same({}, wow.sent)
            assert.are.equal("validity check can't be read", r.why)
            assert.are.same({}, wow.errors)
        end)

        it("whose reason is a table or a secret says no reason, without an error", function()
            for _, why in ipairs({ {}, 7, wow.secret("why") }) do
                local r = push("never", { isValid = function() return false, why end })
                assert.are.equal("no longer wanted: no reason given", r.why, tostring(why))
            end
            local r = push("never", { isValid = function() return false, "left the guild" end })
            assert.are.equal("no longer wanted: left the guild", r.why, "a string reason is kept (white)")
            assert.are.same({}, wow.sent)
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("an onDone (black)", function()
        it("that errors after a send is counted, and the next line still goes out", function()
            local first, second = queued(function()
                return push("first line", { onDone = function() error("listener broke") end }), push("second line")
            end)
            assert.is_nil(first.sent)
            assert.are.same({ "first line", "second line" }, wow.sentTo("GUILD"))
            assert.is_true(second.sent)
            assert.are.equal(1, ns.Diag.Counters().luaErrors)
            assert.are.equal(0, Q.Count())
        end)

        it("that errors on a drop doesn't stop the same pump from sending the next line", function()
            local second = queued(function()
                push("never", { isValid = function() return false, "gone" end,
                    onDone = function() error("listener broke") end })
                return push("second line")
            end)
            assert.are.same({ "second line" }, wow.sentTo("GUILD"))
            assert.is_true(second.sent)
            assert.are.equal(1, ns.Diag.Counters().luaErrors)
        end)

        it("that errors when the queue is full doesn't break Push", function()
            wow.state.lockdown = true
            for _ = 1, Q.MAX_PENDING do push("waiting", { maxAge = 600 }) end
            local ok, accepted = pcall(Q.Push, { channel = "GUILD", getText = function() return "x" end,
                onDone = function() error("listener broke") end })
            assert.is_true(ok)
            assert.is_false(accepted)
            assert.are.equal(1, ns.Diag.Counters().luaErrors)
            wow.state.lockdown = false
        end)
    end)

    it("a dropped render doesn't count against the chat cap: the next line still has room (black)", function()
        ns.db.linesPerMinute = 1
        local results = queued(function()
            local out = {}
            out[1] = push(nil, { getText = function() error("bad render") end })
            out[2] = push(nil)
            out[3] = push(nil, { getText = function() return wow.secret("x") end })
            out[4] = push("the one line")
            return out
        end)
        for i = 1, 3 do assert.is_false(results[i].sent, i) end
        assert.is_true(results[4].sent, "the cap's one line a minute is still free")
        assert.are.same({ "the one line" }, wow.sentTo("GUILD"))
    end)

    it("an automatic message skipped while AFK never runs its render or its emote target (black)", function()
        ns.db.skipWhileAFK = true
        wow.state.afk = true
        local renders, targets = 0, 0
        local say = push(nil, { automatic = true, getText = function() renders = renders + 1 return "hi" end })
        local emote = push(nil, { automatic = true, channel = "EMOTE", emote = "THANK", getText = nil,
            getTarget = function() targets = targets + 1 return "party1" end })
        wow.advance(Q.MIN_INTERVAL + 1)
        assert.are.equal(0, renders)
        assert.are.equal(0, targets)
        for _, r in ipairs({ say, emote }) do
            assert.is_false(r.sent)
            assert.are.equal("you are AFK (\"Don't send messages while I'm AFK\" is on)", r.why)
        end
        assert.are.same({}, wow.sent)
        assert.are.same({}, wow.emotes)
    end)

    describe("an emote's target", function()
        it("that is a secret, not a string, or not a unit token aims the emote at no one (black)", function()
            local real = _G.issecretvalue
            _G.issecretvalue = function(v) return v == "party2" or real(v) end
            local values = { wow.secret("party1"), "party2", 7, {}, true, "Bob-Stone", "PARTY1", "party 1", "",
                "raid1\n/cast x", string.rep("a", 33) }
            for i, value in ipairs(values) do
                local r = push(nil, { channel = "EMOTE", emote = "THANK", getText = nil,
                    getTarget = function() return value end })
                wow.advance(Q.CAP_WINDOW / 10 + 1) -- under the cap of ten lines a minute
                assert.are.equal(i, #wow.emotes, tostring(value))
                assert.is_nil(wow.emotes[i].target, tostring(value))
                assert.is_true(r.sent, tostring(value))
            end
            _G.issecretvalue = real
            assert.are.same({}, wow.errors)
        end)

        it("that is a unit token aims the emote at it (white)", function()
            for i, token in ipairs({ "party1", "raid12", "nameplate3", "target" }) do
                push(nil, { channel = "EMOTE", emote = "THANK", getText = nil, getTarget = function() return token end })
                wow.advance(Q.MIN_INTERVAL + 1)
                assert.are.equal(token, wow.emotes[i].target)
            end
        end)
    end)
end)
