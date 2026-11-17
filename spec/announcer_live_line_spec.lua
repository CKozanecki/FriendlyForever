-- Spec: #407
-- A line is read from the saved settings when it is said, not when it was
-- picked: a line deleted (or edited) while the message waits is not said as
-- it was.
local wow = require("spec.support.wow")

describe("Announcer reads the line when it is said (#407)", function()
    local ns, release

    local function whispers()
        local out = {}
        for _, m in ipairs(wow.sent) do
            if m.channel == "WHISPER" then out[#out + 1] = m.target .. ": " .. m.text end
        end
        return out
    end

    -- A thank-you held (as one waits for its exchange, #36) until release().
    local function schedule(key)
        release = nil
        ns.Announcer.Schedule("buff", key or "Bob-Stone", { channel = "WHISPER", target = key or "Bob-Stone",
            hold = function(go) release = go end })
        wow.advance(ns.db.buff.delay + 1)
        assert.is_function(release, "the message is held")
    end

    local function drain()
        for _ = 1, 6 do
            wow.advance(2)
            wow.keyDown()
        end
    end

    before_each(function()
        ns = wow.boot()
        ns.db.buff.messages = { "Old line {name}" }
    end)

    it("white: an unchanged line is said as picked", function()
        schedule()
        release()
        drain()
        assert.are.same({ "Bob-Stone: Old line Bob" }, whispers())
    end)

    it("white: a line edited while it waits is said as edited", function()
        schedule()
        ns.db.buff.messages[1] = "New line {name}"
        release()
        drain()
        assert.are.same({ "Bob-Stone: New line Bob" }, whispers())
    end)

    it("black: a line deleted while it waits is not said", function()
        schedule()
        ns.db.buff.messages[1] = ""
        release()
        drain()
        assert.are.same({}, whispers())
    end)

    it("black: a line deleted, or its list lost, between the pick and the send says nothing", function()
        for _, damage in ipairs({ "", "   ", 7, false }) do
            ns = wow.boot()
            ns.db.buff.messages = { "Old line {name}" }
            schedule()
            ns.db.buff.messages[1] = damage
            release()
            drain()
            assert.are.same({}, whispers(), tostring(damage))
        end
        ns = wow.boot()
        ns.db.buff.messages = { "Old line {name}" }
        schedule()
        ns.db.buff.messages = "broken"
        release()
        drain()
        assert.are.same({}, whispers(), "a list that isn't a table")
        assert.are.same({}, wow.errors)
        ns = wow.boot()
        ns.db.buff.messages = { "Old line {name}" }
        schedule()
        ns.db.buff = nil -- the whole section lost mid-session (#387)
        release()
        drain()
        assert.are.same({}, whispers(), "a lost section")
        assert.are.same({}, wow.errors)
    end)

    it("white: a line another copy asked for (go(n)) is read live too", function()
        ns.db.buff.messages = { "First {name}", "Second {name}" }
        schedule()
        ns.db.buff.messages[2] = "Second edited {name}"
        release(2)
        drain()
        assert.are.same({ "Bob-Stone: Second edited Bob" }, whispers())
    end)

    it("red: random edits and deletions while messages wait never raise an error or say a blank line", function()
        math.randomseed(407)
        for round = 1, 40 do
            ns = wow.boot()
            wow.errors = {}
            ns.db.buff.messages = { "A {name}", "B {name}", "C {name}" }
            schedule()
            for _ = 1, math.random(0, 3) do
                local pick = math.random(1, 4)
                local v = ({ "", "x {name}", 7, false })[pick]
                ns.db.buff.messages[math.random(1, 3)] = v
            end
            release(math.random(1, 3))
            drain()
            for _, line in ipairs(whispers()) do
                assert.is_truthy(line:find("%S", line:find(":") + 1), "round " .. round)
            end
            assert.are.same({}, wow.errors)
        end
    end)
end)
