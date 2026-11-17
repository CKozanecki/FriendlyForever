-- Spec: #446
-- A message whose getText (or an emote's getTarget) raises an error, or
-- returns something that can't be sent, is dropped with a reason: onDone
-- hears it, nothing is sent, and the pump goes on with the next message.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

describe("ChatQueue protects a message's render (#446)", function()
    local ns, Q

    before_each(function()
        ns = wow.boot()
        Q = ns.ChatQueue
        ns.db.linesPerMinute = 30
    end)

    local function push(text, extra)
        local result = { done = 0 }
        local item = { channel = "GUILD", label = "test", getText = function() return text end,
            onDone = function(sent, why) result.done = result.done + 1 result.sent, result.why = sent, why end }
        for k, v in pairs(extra or {}) do item[k] = v end
        Q.Push(item)
        return result
    end

    it("white: a getText that errors is dropped with a reason, onDone runs, and the next line goes out", function()
        wow.state.lockdown = true -- queue both before either can go
        local bad = push(nil, { getText = function() error("bad render") end })
        local good = push("second line")
        wow.state.lockdown = false
        wow.advance(Q.RETRY_DELAY)
        assert.are.same({ "second line" }, wow.sentTo("GUILD"))
        assert.are.equal(1, bad.done)
        assert.is_false(bad.sent)
        assert.are.equal("message failed to render", bad.why)
        assert.is_true(good.sent)
        assert.are.same({}, wow.errors)
    end)

    it("white: the drop is logged without the message text", function()
        ns.db.debug = true
        push(nil, { getText = function() error("secret chat text") end })
        for _, line in ipairs(wow.printed) do assert.is_nil(line:find("secret chat text", 1, true)) end
        assert.is_true((ns.Diag.Counters().renderErrors or 0) >= 1)
    end)

    it("black: a getText returning a non-string or a secret value is dropped, never sent", function()
        for _, value in ipairs({ 7, true, {}, wow.secret("hi") }) do
            wow.sent = {}
            local r = push(nil, { getText = function() return value end })
            assert.are.same({}, wow.sent, tostring(value))
            assert.is_false(r.sent)
            assert.are.equal(1, r.done)
            assert.are.equal("message rendered as something that can't be sent", r.why)
        end
        assert.are.same({}, wow.errors)
    end)

    it("black: a secret string (the game reports its type as a string) is dropped, never sent", function()
        local real = _G.issecretvalue
        _G.issecretvalue = function(v) return v == "hidden text" end
        local r = push("hidden text")
        _G.issecretvalue = real
        assert.are.same({}, wow.sent)
        assert.is_false(r.sent)
        assert.are.equal("message rendered as something that can't be sent", r.why)
    end)

    it("black: a nil getText is still dropped as empty", function()
        local r = push(nil)
        assert.are.equal("message rendered empty", r.why)
    end)

    it("black: an emote whose getTarget errors is dropped, not sent at everyone", function()
        local r = push(nil, { channel = "EMOTE", emote = "THANK", getText = nil,
            getTarget = function() error("no target") end })
        assert.are.same({}, wow.emotes)
        assert.is_false(r.sent)
        assert.are.equal("emote target failed to resolve", r.why)
    end)

    it("white: an emote with a good target still goes out", function()
        local r = push(nil, { channel = "EMOTE", emote = "THANK", getText = nil, getTarget = function() return "party1" end })
        assert.are.equal(1, #wow.emotes)
        assert.are.equal("party1", wow.emotes[1].target)
        assert.is_true(r.sent)
    end)

    it("red: a storm of erroring, nil, wrong-type and valid renders never sticks the queue or loses an onDone", function()
        random.seed(446)
        local kinds = {
            function() return "ok" end, function() error("boom") end, function() return nil end,
            function() return 7 end, function() return wow.secret("x") end,
        }
        local results, valid = {}, 0
        for _ = 1, 60 do
            wow.state.lockdown = true
            for _ = 1, random.random(1, 4) do
                local k = random.random(1, #kinds)
                if k == 1 then valid = valid + 1 end
                results[#results + 1] = push(nil, { getText = kinds[k], maxAge = 600 })
            end
            wow.state.lockdown = false
            for _ = 1, 30 do wow.advance(Q.MIN_INTERVAL + 1) end
            assert.are.same({}, wow.errors)
        end
        wow.advance(Q.MAX_AGE + 5)
        local sentOk, droppedOk = 0, 0
        for _, r in ipairs(results) do
            assert.are.equal(1, r.done, "every message hears onDone exactly once")
            if r.sent then sentOk = sentOk + 1 else droppedOk = droppedOk + 1 end
        end
        assert.is_true(sentOk > 0 and droppedOk > 0, "both outcomes were reached")
        assert.are.equal(sentOk, #wow.sentTo("GUILD"), "only valid lines were sent")
        for _, text in ipairs(wow.sentTo("GUILD")) do assert.are.equal("ok", text) end
    end)
end)
