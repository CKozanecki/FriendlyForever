local wow = require("spec.support.wow")

-- The hot paths: events that fire many times a second in cities, raids and
-- battlegrounds. These check they stay cheap without changing what is sent.
describe("Hot paths", function()
    local ns

    local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

    -- The addon's event frame: the one listening for system messages.
    local function eventFrame()
        for _, f in ipairs(wow.frames) do
            if f.events.CHAT_MSG_SYSTEM then return f end
        end
    end

    local function listensForCasts()
        return eventFrame():IsEventRegistered("UNIT_SPELLCAST_SUCCEEDED")
    end

    before_each(function()
        ns = wow.boot()
    end)

    describe("spellcasts are only listened for while Buff Thanks or Buff Back is on", function()
        it("on by default", function()
            assert.is_true(listensForCasts())
        end)

        it("not when both were off at login", function()
            ns = wow.boot({ db = { buff = { enabled = false }, buffBack = { enabled = false } } })
            assert.is_false(listensForCasts())
        end)

        it("while Buff Back offers, even with Buff Thanks off", function()
            ns = wow.boot({ db = { buff = { enabled = false } } })
            assert.is_true(listensForCasts())
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            w.enabled:SetChecked(false)
            wow.run(w.enabled, "OnClick")
            assert.is_false(listensForCasts())
        end)

        it("follows the Buff Thanks checkbox", function()
            ns.db.buffBack.enabled = false
            local w = ns.Options.widgets
            wow.run(w.tabs.buff, "OnClick")
            w.enabled:SetChecked(false)
            wow.run(w.enabled, "OnClick")
            assert.is_false(listensForCasts())
            w.enabled:SetChecked(true)
            wow.run(w.enabled, "OnClick")
            assert.is_true(listensForCasts())
        end)

        it("follows the addon's master switch", function()
            slash("off")
            assert.is_false(listensForCasts())
            slash("on")
            assert.is_true(listensForCasts())
        end)

        it("comes back when Buff Thanks is reset to its defaults", function()
            ns.db.buff.enabled = false
            ns.RefreshEvents()
            ns.ResetType("buff")
            assert.is_true(listensForCasts())
        end)
    end)

    describe("a spellcast", function()
        local classified

        before_each(function()
            classified = 0
            local classify = ns.BuffTracker.Classify
            ns.BuffTracker.Classify = function(...)
                classified = classified + 1
                return classify(...)
            end
        end)

        it("from my group or other units never thanked is rejected before any unit lookups", function()
            for _, unit in ipairs({ "party1", "raid12", "player", "pet", "arena1", "boss1", "softenemy" }) do
                wow.fire("UNIT_SPELLCAST_SUCCEEDED", unit, "g", 1459)
            end
            assert.are.equal(0, classified)
        end)

        it("from the units that can name a caster is still looked at", function()
            for _, unit in ipairs({ "target", "focus", "mouseover", "nameplate7", "softfriend" }) do
                wow.addUnit(unit, { name = "Bob" })
                wow.fire("UNIT_SPELLCAST_SUCCEEDED", unit, "g", 1459)
            end
            assert.are.equal(5, classified)
        end)

        it("isn't looked at while Buff Thanks and Buff Back are off, even if one arrives", function()
            ns.db.buff.enabled = false
            ns.db.buffBack.enabled = false
            wow.addUnit("target", { name = "Bob" })
            ns.BuffTracker.OnSpellcastSucceeded("target", "g", 1459)
            assert.are.equal(0, classified)
        end)
    end)

    -- Measured with the collector stopped, so the count only grows. The old
    -- path made a table and a closure per event, plus a table per remembered
    -- cast: about 1.4MB for 5000 group casts, 2.1MB for 5000 aimed at me.
    local function allocatedKB(unit, times)
        local f = eventFrame()
        local onEvent = f.scripts.OnEvent
        for _ = 1, 10 do onEvent(f, "UNIT_SPELLCAST_SUCCEEDED", unit, "g", 1459) end
        collectgarbage("collect")
        collectgarbage("stop")
        local before = collectgarbage("count")
        for _ = 1, times do onEvent(f, "UNIT_SPELLCAST_SUCCEEDED", unit, "g", 1459) end
        local grown = collectgarbage("count") - before
        collectgarbage("restart")
        return grown
    end

    it("handling a spellcast from my group allocates nothing", function()
        local grown = allocatedKB("raid12", 5000)
        assert.is_true(grown < 1, string.format("grew %.1fKB", grown))
    end)

    it("remembering a stranger's repeated cast at me allocates nothing", function()
        wow.addUnit("nameplate3", { name = "Bob", target = "player" })
        local grown = allocatedKB("nameplate3", 5000)
        assert.is_true(grown < 1, string.format("grew %.1fKB", grown))
    end)

    it("hands a system message's handler only the message, so it takes the fast path", function()
        local counts = {}
        local call = ns.Diag.Call
        ns.Diag.Call = function(fn, ...)
            counts[#counts + 1] = select("#", ...)
            return call(fn, ...)
        end
        local extra = {}
        for i = 1, 16 do extra[i] = "x" end
        wow.fire("CHAT_MSG_SYSTEM", "|Hplayer:Thrall|h[Thrall]|h has come online.", unpack(extra))
        assert.are.same({ 1 }, counts)
        assert.are.equal(1, ns.Diag.Counters().systemMessages)
    end)

    describe("Diag.Call", function()
        it("passes up to four arguments, and more, through unchanged", function()
            local got
            local function record(...) got = { n = select("#", ...), ... } end
            ns.Diag.Call(record)
            assert.are.equal(0, got.n)
            ns.Diag.Call(record, "a", nil)
            assert.are.equal(2, got.n)
            ns.Diag.Call(record, "a", nil, 3, false)
            assert.are.equal(4, got.n)
            assert.are.same({ "a", nil, 3, false }, { got[1], got[2], got[3], got[4] })
            ns.Diag.Call(record, 1, 2, 3, 4, 5, 6)
            assert.are.equal(6, got.n)
            assert.are.same({ 1, 2, 3, 4, 5, 6 }, { got[1], got[2], got[3], got[4], got[5], got[6] })
        end)

        it("returns the function's results after true", function()
            assert.are.same({ true, 3, "x" }, { ns.Diag.Call(function(a, b) return a + b, "x" end, 1, 2) })
        end)

        it("isn't confused by a Diag.Call made inside the function", function()
            local outer
            ns.Diag.Call(function(a, b)
                ns.Diag.Call(function() end, "inner", "args")
                outer = { a, b }
            end, "outer", "args")
            assert.are.same({ "outer", "args" }, outer)
        end)

        it("still counts and reports an error", function()
            local ok = ns.Diag.Call(function(a) error("bad " .. a) end, "news")
            assert.is_false(ok)
            assert.are.equal(1, ns.Diag.Counters().luaErrors)
            assert.truthy(ns.Diag.lastError:find("bad news", 1, true))
        end)

        it("passes nothing on to the next call after an error", function()
            ns.Diag.Call(function() error("first") end, "leftover")
            local got = "unset"
            ns.Diag.Call(function(a) got = a end)
            assert.is_nil(got)
        end)
    end)
end)
