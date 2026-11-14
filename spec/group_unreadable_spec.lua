-- Spec: #322
-- Buff mode's group look when the game won't say whether you're in a raid or
-- a group: GroupBuffs.Next is never settled then, and offers no group
-- version, since a raid taken for a party is only your own subgroup.
local wow = require("spec.support.wow")

local INTELLECT, BRILLIANCE = 10157, 23028

describe("Buff mode when IsInRaid() or IsInGroup() can't be read (#322)", function()
    local ns

    -- A mage who knows Arcane Intellect and Arcane Brilliance and carries
    -- Arcane Powder, in a raid: Ann, Bo and Eve in your subgroup 1, Cid and
    -- Dot in subgroup 2. In the game a raid also gives your own subgroup's other
    -- members as party1..4; the simulated client doesn't yet (#322's harness
    -- PR adds it), so they are added here.
    local function bootRaid()
        ns = wow.boot({ before = function(state)
            state.class = "MAGE"
            state.knownSpells = { [INTELLECT] = true, [BRILLIANCE] = true }
            state.items = { [wow.ITEM.arcanePowder] = 5 }
        end })
        wow.setGroup("raid", { "Ann-Vale", "Bo-Fern", "Eve-Hill", "Cid-Rock", "Dot-Moss" })
        for i = 4, 5 do wow.state.units["raid" .. i].subgroup = 2 end
        for i = 1, 3 do wow.state.units["party" .. i] = wow.state.units["raid" .. i] end
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    -- Your subgroup has your Arcane Intellect; subgroup 2 lacks it.
    local function subgroupOneBuffed()
        for _, token in ipairs({ "raid1", "raid2", "raid3", "player" }) do
            wow.wearBuff(token, INTELLECT, { source = "player" })
        end
    end

    -- The ways an answer can't be read.
    local UNREADABLE = {
        ["a secret true"] = function() return wow.secret(true) end,
        ["a secret false"] = function() return wow.secret(false) end,
        nothing = function() return nil end,
        ["an error"] = function() error("blocked") end,
        ["a number"] = function() return 1 end,
    }

    local function hide(fn, answer)
        _G[fn] = UNREADABLE[answer]
    end

    it("readable, a raid behaves as before: the subgroup missing it is offered, and it settles once all have it (black)", function()
        bootRaid()
        subgroupOneBuffed()
        local offer = ns.GroupBuffs.Next()
        assert.are.equal("Cid", offer and offer.name:match("^[^%-]+"))
        for _, token in ipairs({ "raid4", "raid5" }) do wow.wearBuff(token, INTELLECT, { source = "player" }) end
        local none, why, settled = ns.GroupBuffs.Next()
        assert.is_nil(none)
        assert.are.equal("everyone in your group has your buffs", why)
        assert.is_true(settled)
        assert.are.same({}, wow.errors)
    end)

    it("IsInRaid() unreadable in a raid: one subgroup buffed is never taken for everyone (black)", function()
        for answer in pairs(UNREADABLE) do
            bootRaid()
            subgroupOneBuffed()
            hide("IsInRaid", answer)
            local none, why, settled = ns.GroupBuffs.Next()
            assert.is_nil(none, answer)
            assert.is_false(settled, answer)
            assert.are.equal("the game won't say whether you're in a raid or a group", why, answer)
            assert.are.same({}, wow.errors, answer)
        end
    end)

    it("IsInRaid() unreadable in a raid: no group version, only single buffs, and still not settled (black)", function()
        for answer in pairs(UNREADABLE) do
            bootRaid()
            local offer = ns.GroupBuffs.Next()
            assert.are.equal("Arcane Brilliance", offer and offer.spell, answer .. ": readable, the group version")
            hide("IsInRaid", answer)
            offer = ns.GroupBuffs.Next()
            assert.are.equal("Arcane Intellect", offer and offer.spell, answer)
            assert.is_nil(offer.cast, answer)
            local list = {}
            ns.GroupBuffs.Next(list)
            assert.is_true(#list > 0, answer)
            for _, entry in ipairs(list) do
                assert.are.equal("Arcane Intellect", entry.spell, answer)
                assert.is_nil(entry.cast, answer)
            end
            -- Your subgroup gets its buffs one at a time; then nothing is
            -- offered, and it still isn't settled.
            subgroupOneBuffed()
            local none, _, settled = ns.GroupBuffs.Next()
            assert.is_nil(none, answer)
            assert.is_false(settled, answer)
            assert.are.same({}, wow.errors, answer)
        end
    end)

    it("IsInGroup() unreadable never settles, in a raid or a party (black)", function()
        for answer in pairs(UNREADABLE) do
            bootRaid()
            subgroupOneBuffed()
            for _, token in ipairs({ "raid4", "raid5" }) do wow.wearBuff(token, INTELLECT, { source = "player" }) end
            hide("IsInGroup", answer)
            local none, _, settled = ns.GroupBuffs.Next()
            assert.is_nil(none, answer)
            assert.is_false(settled, answer .. ": in a raid, everyone buffed")

            wow.setGroup("party", { "Ann-Vale" })
            wow.wearBuff("party1", INTELLECT, { source = "player" })
            local why
            none, why, settled = ns.GroupBuffs.Next()
            assert.is_nil(none, answer)
            assert.is_false(settled, answer .. ": in a party")
            assert.are.equal("the game won't say whether you're in a raid or a group", why, answer)
            assert.are.same({}, wow.errors, answer)
        end
    end)

    it("with no buffs to offer, or only one waiting for water, it isn't settled either while the group can't be read (black)", function()
        bootRaid()
        wow.state.knownSpells = {}
        local _, why, settled = ns.GroupBuffs.Next()
        assert.are.equal("you have no buffs to offer", why)
        assert.is_true(settled, "readable: settled")
        hide("IsInRaid", "nothing")
        _, why, settled = ns.GroupBuffs.Next()
        assert.are.equal("you have no buffs to offer", why)
        assert.is_false(settled)

        -- A warlock whose Unending Breath waits for water.
        bootRaid()
        wow.state.class, wow.state.knownSpells = "WARLOCK", { [5697] = true }
        _, why, settled = ns.GroupBuffs.Next()
        assert.are.equal("Unending Breath waits until you're near water", why)
        assert.is_true(settled, "readable: settled")
        hide("IsInRaid", "nothing")
        _, why, settled = ns.GroupBuffs.Next()
        assert.are.equal("Unending Breath waits until you're near water", why)
        assert.is_false(settled)
        assert.are.same({}, wow.errors)
    end)

    it("buff mode a raid turned on doesn't end as done while IsInRaid() can't be read (black)", function()
        ns = wow.boot({ autoBuffMode = true, before = function(state)
            state.class = "MAGE"
            state.knownSpells = { [INTELLECT] = true }
        end })
        local button = ns.BuffButton.Frame()
        wow.setGroup("raid", { "Ann-Vale", "Bo-Fern", "Eve-Hill", "Cid-Rock", "Dot-Moss" })
        for i = 4, 5 do wow.state.units["raid" .. i].subgroup = 2 end
        for i = 1, 3 do wow.state.units["party" .. i] = wow.state.units["raid" .. i] end
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
        assert.is_true(ns.BuffMode.IsAuto(), "joining with someone close by turned it on")
        subgroupOneBuffed()
        hide("IsInRaid", "a secret false")
        ns.BuffButton.Refresh()
        assert.is_true(ns.BuffMode.IsAuto(), "subgroup 2 is missing it: not done")
        assert.is_nil(button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText),
            "nothing to offer from your own subgroup")
        _G.IsInRaid = function() return true end
        ns.BuffButton.Refresh()
        assert.is_true(ns.BuffMode.IsAuto())
        assert.is_not_nil(button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText),
            "readable again: subgroup 2 is offered")
        assert.are.same({}, wow.errors)
        assert.are.equal(0, #wow.casts, "nothing casts without a press")
    end)
end)
