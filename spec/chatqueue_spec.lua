local wow = require("spec.support.wow")

describe("ChatQueue", function()
    local ns, Q

    before_each(function()
        ns = wow.boot()
        Q = ns.ChatQueue
    end)

    local function push(channel, text, extra)
        local item = { channel = channel, getText = function() return text end }
        for k, v in pairs(extra or {}) do item[k] = v end
        return Q.Push(item)
    end

    it("sends immediately when nothing is blocking", function()
        push("GUILD", "hello")
        assert.are.same({ "hello" }, wow.sentTo("GUILD"))
    end)

    it("spaces messages out to avoid flooding chat", function()
        for i = 1, 5 do push("GUILD", "m" .. i) end
        assert.are.equal(1, #wow.sent)
        wow.advance(Q.MIN_INTERVAL * 4 + 0.01)
        assert.are.same({ "m1", "m2", "m3", "m4", "m5" }, wow.sentTo("GUILD"))
        for i = 2, #wow.sent do
            assert.is_true(wow.sent[i].time - wow.sent[i - 1].time >= Q.MIN_INTERVAL)
        end
    end)

    it("drops messages beyond the queue limit and reports it", function()
        local dropped = 0
        for i = 1, Q.MAX_PENDING + 10 do
            push("GUILD", "m" .. i, { onDone = function(sent) if not sent then dropped = dropped + 1 end end })
        end
        assert.are.equal(9, dropped) -- first one is sent at once, so 25 fit after it
    end)

    it("holds messages during chat lockdown and sends them after", function()
        wow.state.lockdown = true
        push("PARTY", "welcome")
        wow.advance(10)
        assert.are.equal(0, #wow.sent)
        assert.are.equal(0, #wow.blocked, "never even attempts a blocked send")
        wow.state.lockdown = false
        wow.advance(Q.RETRY_DELAY)
        assert.are.same({ "welcome" }, wow.sentTo("PARTY"))
    end)

    it("expires messages that wait too long", function()
        wow.state.lockdown = true
        local result
        push("PARTY", "old", { onDone = function(sent) result = sent end })
        wow.advance(Q.MAX_AGE + Q.RETRY_DELAY + 1)
        assert.is_false(result)
        wow.state.lockdown = false
        wow.advance(10)
        assert.are.equal(0, #wow.sent)
        assert.are.equal(0, Q.Count())
    end)

    it("expires a message after its own max age, others after the usual one", function()
        wow.state.lockdown = true
        local short, long
        push("SAY", "quick", { maxAge = 30, onDone = function(sent) short = sent end })
        push("WHISPER", "slow", { target = "Bob", onDone = function(sent) long = sent end })
        wow.advance(30 + Q.RETRY_DELAY + 1)
        assert.is_false(short)
        assert.is_nil(long, "still waiting")
        wow.state.lockdown = false
        wow.advance(Q.RETRY_DELAY)
        assert.is_true(long)
        assert.are.same({ "slow" }, wow.sentTo("WHISPER"))
    end)

    it("waits for a key press before /say outside instances", function()
        push("SAY", "thanks")
        wow.advance(10)
        assert.are.equal(0, #wow.sent)
        assert.are.equal(0, #wow.blocked, "never attempts /say without a hardware event")
        assert.is_true(Q.IsWaitingForHardware())
        wow.keyDown("W")
        assert.are.same({ "thanks" }, wow.sentTo("SAY"))
        assert.is_false(Q.IsWaitingForHardware())
    end)

    it("sends /say inside instances without a key press", function()
        wow.state.inInstance = true
        push("SAY", "thanks")
        assert.are.same({ "thanks" }, wow.sentTo("SAY"))
    end)

    it("lets other channels through while /say waits", function()
        push("SAY", "thanks")
        wow.advance(Q.MIN_INTERVAL)
        push("GUILD", "hi")
        assert.are.same({ "hi" }, wow.sentTo("GUILD"))
        assert.are.equal(1, Q.Count())
    end)

    it("whispers need no key press", function()
        push("WHISPER", "thanks", { target = "Bob" })
        assert.are.equal(1, #wow.sent)
        assert.are.equal("Bob", wow.sent[1].target)
    end)

    it("drops a whisper with no target instead of sending it", function()
        local result
        push("WHISPER", "thanks", { onDone = function(sent) result = sent end })
        assert.is_false(result)
        assert.are.equal(0, #wow.sent)
    end)

    it("re-checks validity right before sending", function()
        wow.state.lockdown = true
        local valid = true
        push("PARTY", "hi", { isValid = function() return valid end })
        valid = false
        wow.state.lockdown = false
        wow.advance(Q.RETRY_DELAY)
        assert.are.equal(0, #wow.sent)
    end)

    it("resolves the channel at send time", function()
        local channel = nil
        local result
        push(function() return channel end, "hi", { onDone = function(sent) result = sent end })
        assert.is_false(result, "no channel means the message is dropped")
        channel = "RAID"
        push(function() return channel end, "hi")
        assert.are.same({ "hi" }, wow.sentTo("RAID"))
    end)

    it("survives a send that throws", function()
        _G.C_ChatInfo.SendChatMessage = function() error("boom") end
        local result
        push("GUILD", "x", { onDone = function(sent) result = sent end })
        assert.is_false(result)
        _G.C_ChatInfo.SendChatMessage = nil
        _G.SendChatMessage = function(text, channel) wow.sent[#wow.sent + 1] = { text = text, channel = channel } end
        wow.advance(Q.MIN_INTERVAL)
        push("GUILD", "y")
        assert.are.same({ "y" }, wow.sentTo("GUILD"))
    end)

    it("sets up the key listener after combat if loaded mid-fight", function()
        ns = wow.boot({ before = function(state) state.inCombat = true end })
        local keyFrame
        -- The queue's own listener: the first made (the options' key chooser comes later).
        for _, f in ipairs(wow.frames) do
            if f.scripts.OnKeyDown then
                keyFrame = f
                break
            end
        end
        assert.is_truthy(keyFrame)
        assert.is_nil(keyFrame.propagate)
        wow.state.inCombat = false
        wow.fire("PLAYER_REGEN_ENABLED")
        assert.is_true(keyFrame.keyboard)
        assert.is_true(keyFrame.propagate, "keys must still reach the game")
    end)
end)
