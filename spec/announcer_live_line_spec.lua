-- Spec: #407
-- A line is read from the saved settings when it is said, not when it was
-- picked: a line deleted (or edited) while the message waits is not said as
-- it was.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

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

    -- A /say line waits in the queue for a key press (#407): edit it after it
    -- is queued and before the press, the window the report is about.
    local function said()
        local out = {}
        for _, m in ipairs(wow.sent) do
            if m.channel == "SAY" then out[#out + 1] = m.text end
        end
        return out
    end

    local function queueSay(done)
        ns.Announcer.Schedule("buff", "Bob-Stone", { channel = "SAY", onDone = done })
        wow.advance(ns.db.buff.delay + 6)
        assert.are.same({}, said(), "held for a key press")
    end

    it("white: a line edited after it was queued, before the key press, is said as edited", function()
        queueSay()
        ns.db.buff.messages[1] = "New line {name}"
        drain()
        assert.are.same({ "New line Bob" }, said())
    end)

    it("black: a line deleted after it was queued, before the key press, is not said, and onDone hears why", function()
        local sent, why
        queueSay(function(ok, reason) sent, why = ok, reason end)
        ns.db.buff.messages[1] = ""
        drain()
        assert.are.same({}, said())
        assert.is_false(sent)
        assert.is_string(why)
        assert.are.same({}, wow.errors)
    end)

    it("white: a go(n) line edited after release(2) is read live too", function()
        ns.db.buff.messages = { "First {name}", "Second {name}" }
        ns.Announcer.Schedule("buff", "Bob-Stone", { channel = "SAY", hold = function(go) release = go end })
        wow.advance(ns.db.buff.delay + 1)
        release(2)
        wow.advance(6)
        assert.are.same({}, said(), "held for a key press")
        ns.db.buff.messages[2] = "Second edited {name}"
        drain()
        assert.are.same({ "Second edited Bob" }, said())
    end)

    it("white: the section replaced (a reset or a profile switch) while it waits: the new line is said", function()
        queueSay()
        ns.ResetType("buff")
        drain()
        assert.are.equal(1, #said())
        assert.are_not.equal("Old line Bob", said()[1])
    end)

    it("black: the list lost or damaged after it was queued says nothing and raises no Lua error", function()
        for _, damage in ipairs({ "nil", 7, false, "broken", "fn" }) do
            ns = wow.boot()
            ns.db.buff.messages = { "Old line {name}" }
            local sent
            queueSay(function(ok) sent = ok end)
            local value = damage
            if damage == "nil" then value = nil elseif damage == "fn" then value = function() end end
            ns.db.buff.messages = value
            drain()
            assert.are.same({}, said(), tostring(damage))
            assert.are.same({}, wow.errors, tostring(damage))
            assert.is_false(sent, tostring(damage))
        end
    end)

    it("red: random edits and deletions while a message waits say exactly the line that is live when it goes out",
        function()
        random.seed(407)
        local damaged, spoken = 0, 0
        for round = 1, 60 do
            ns = wow.boot()
            wow.errors = {}
            ns.db.buff.messages = { "A {name}", "B {name}", "C {name}" }
            local held = random.random(1, 2) == 1
            local target = random.random(1, 3)
            if held then
                -- A /say line waiting for a key press: the line is damaged after it is queued.
                ns.Announcer.Schedule("buff", "Bob-Stone", { channel = "SAY" })
                wow.advance(ns.db.buff.delay + 6)
            else
                schedule()
            end
            -- The line it will say is the one picked: find it from the saved list's only non-blank line.
            ns.db.buff.messages = { "", "", "" }
            ns.db.buff.messages[target] = "T" .. round .. " {name}"
            for _ = 1, random.random(0, 2) do
                local pick = random.random(1, 4)
                ns.db.buff.messages[random.random(1, 3)] = ({ "", "x {name}", 7, false })[pick]
            end
            if random.random() < 0.15 then ns.db.buff.messages = ({ 7, false, "broken" })[random.random(1, 3)] end
            local list = ns.db.buff.messages
            if held then drain() else release(random.random(1, 3)); drain() end
            -- Expected, worked out from the storm's own record of the list: a line said is one the
            -- list holds, non-blank, as a whole line; the rest says nothing.
            local lines = held and said() or whispers()
            for _, line in ipairs(lines) do
                local text = line:gsub("^Bob%-Stone: ", "")
                local found = false
                if type(list) == "table" then
                    for i = 1, 3 do
                        if type(list[i]) == "string" and list[i]:find("%S") and list[i]:gsub("{name}", "Bob") == text then
                            found = true
                        end
                    end
                end
                assert.is_true(found, "round " .. round .. " said " .. line)
                spoken = spoken + 1
            end
            if type(list) ~= "table" or type(list[1]) ~= "string" or not list[1]:find("%S") then damaged = damaged + 1 end
            assert.are.same({}, wow.errors, "round " .. round)
        end
        assert.is_true(damaged > 0, "storm reached a damaged first line")
        assert.is_true(spoken > 0, "storm said some lines")
    end)
end)
