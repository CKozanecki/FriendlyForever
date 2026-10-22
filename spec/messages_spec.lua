local wow = require("spec.support.wow")

describe("Messages", function()
    local ns

    before_each(function()
        wow.reset()
        ns = wow.load()
    end)

    it("never picks the same line twice in a row", function()
        local list = { "a", "b", "c" }
        local last
        for _ = 1, 200 do
            local text = ns.Messages.Pick("t", list)
            assert.are_not.equal(last, text)
            last = text
        end
    end)

    it("eventually uses every line", function()
        local seen = {}
        for _ = 1, 200 do seen[ns.Messages.Pick("t", { "a", "b", "c" })] = true end
        assert.are.same({ a = true, b = true, c = true }, seen)
    end)

    it("skips blank lines", function()
        for _ = 1, 50 do
            assert.are.equal("only", ns.Messages.Pick("t", { "", "  ", "only", "" }))
        end
    end)

    it("returns nil when every line is blank", function()
        assert.is_nil(ns.Messages.Pick("t", { "", " " }))
    end)

    it("uses every line once before any line repeats", function()
        local list = {}
        for i = 1, 30 do list[i] = "line " .. i end
        for _ = 1, 5 do
            local round = {}
            for _ = 1, 30 do
                local text = ns.Messages.Pick("t", list)
                assert.is_nil(round[text], "repeated within a round: " .. text)
                round[text] = true
            end
        end
    end)

    it("doesn't start a new round with the line that ended the last one", function()
        -- Three lines means a new round every three picks: 100 round boundaries.
        local list = { "a", "b", "c" }
        local last
        for _ = 1, 300 do
            local text = ns.Messages.Pick("t", list)
            assert.are_not.equal(last, text)
            last = text
        end
    end)

    it("skips a line blanked partway through a round", function()
        local list = { "a", "b", "c", "d" }
        ns.Messages.Pick("t", list)
        list[1], list[2], list[3], list[4] = "", "", "", "d"
        for _ = 1, 10 do assert.are.equal("d", ns.Messages.Pick("t", list)) end
    end)

    it("keeps a separate rotation per message type", function()
        local list = { "a", "b", "c" }
        local x, y = {}, {}
        for _ = 1, 3 do x[ns.Messages.Pick("x", list)] = true end
        for _ = 1, 3 do y[ns.Messages.Pick("y", list)] = true end
        assert.are.same({ a = true, b = true, c = true }, x)
        assert.are.same({ a = true, b = true, c = true }, y)
    end)

    it("carries the rotation across a reload (it lives in the saved settings)", function()
        local booted = wow.boot()
        ns = booted
        local list = {}
        for i = 1, 10 do list[i] = "line " .. i end
        local used = {}
        for _ = 1, 4 do used[ns.Messages.Pick("guildLogin", list)] = true end
        -- Reload: the same saved table comes back, the code starts fresh.
        ns = wow.boot({ db = _G.FriendlyForeverDB })
        ns.Messages.random = math.random
        for _ = 1, 6 do
            local text = ns.Messages.Pick("guildLogin", list)
            assert.is_nil(used[text], "repeated after reload: " .. text)
            used[text] = true
        end
    end)
end)

describe("Cooldowns", function()
    local Cooldowns

    before_each(function()
        wow.reset()
        Cooldowns = wow.load().Cooldowns
    end)

    it("blocks a key until its cooldown passes", function()
        assert.is_true(Cooldowns.TryClaim("k", 180, 0))
        assert.is_false(Cooldowns.TryClaim("k", 180, 179))
        assert.is_true(Cooldowns.TryClaim("k", 180, 180))
    end)

    it("keeps keys independent", function()
        assert.is_true(Cooldowns.TryClaim("a", 180, 0))
        assert.is_true(Cooldowns.TryClaim("b", 180, 0))
    end)

    it("a zero cooldown never blocks", function()
        assert.is_true(Cooldowns.TryClaim("k", 0, 5))
        assert.is_true(Cooldowns.TryClaim("k", 0, 5))
    end)

    it("forgets old entries so memory stays bounded", function()
        for i = 1, 1000 do Cooldowns.TryClaim("old" .. i, 60, 0) end
        for i = 1, 200 do Cooldowns.TryClaim("new" .. i, 60, 5000) end
        assert.is_true(Cooldowns.Count() <= 200 + 1)
    end)
end)
