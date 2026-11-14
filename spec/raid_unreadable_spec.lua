-- Spec: #322
-- party1..4 in a raid, and buff mode when the game won't say whether you are
-- in a raid.
local wow = require("spec.support.wow")

describe("Buff mode when IsInRaid or IsInGroup can't be read (#322)", function()
    local ns

    local function bootRaid()
        ns = wow.boot({ before = function(state)
            state.class = "MAGE"
            state.knownSpells = { [10157] = true }
        end })
        -- Two in my subgroup 1, two in subgroup 2.
        wow.setGroup("raid", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
        wow.state.units.raid3.subgroup = 2
        wow.state.units.raid4.subgroup = 2
        -- Everyone in subgroup 1 has Arcane Intellect; subgroup 2 is missing it.
        for _, token in ipairs({ "raid1", "raid2" }) do wow.wearBuff(token, 10157, { source = "player" }) end
        wow.wearBuff("player", 10157, { source = "player" })
    end

    it("readable: offers the subgroup 2 member in the raid (white, as before)", function()
        bootRaid()
        local offer = ns.GroupBuffs.Next()
        assert.is_not_nil(offer)
    end)

    it("IsInRaid unreadable: nothing errors, and Next still answers (black)", function()
        bootRaid()
        wow.state.inRaidUnreadable = true
        assert.has_no.errors(function() ns.GroupBuffs.Next() end)
        assert.has_no.errors(function() ns.GroupBuffs.EveryoneInside() end)
        assert.are.same({}, wow.errors)
    end)

    it("IsInGroup unreadable: nothing errors (black)", function()
        bootRaid()
        wow.state.inGroupUnreadable = true
        assert.has_no.errors(function() ns.GroupBuffs.Next() end)
        assert.are.same({}, wow.errors)
    end)

    it("EveryoneInside is false while IsInRaid can't be read, as #306 made it (black)", function()
        bootRaid()
        wow.state.inRaidUnreadable = true
        assert.is_false(ns.GroupBuffs.EveryoneInside())
    end)
end)
