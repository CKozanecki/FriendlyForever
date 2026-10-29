-- Spec: #76, #84
-- The simulated client itself, where its test hooks could fool other specs.
local wow = require("spec.support.wow")

local MOTW, MOTW_1 = 9885, 1126
local MACRO = "/targetexact Ann Stone\n/cast [help,nodead] Mark of the Wild"

describe("The simulated client", function()
    -- A druid who knows Mark of the Wild, near Ann-Stone (not flagged for PvP)
    -- and Dot-Stone (flagged).
    before_each(function()
        wow.boot({ before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
        end })
        wow.addUnit("nameplate5", { name = "Ann", surname = "Stone", class = "MAGE", id = "Ann-Stone" })
        wow.addUnit("nameplate4", { name = "Dot", surname = "Stone", class = "MAGE", id = "Dot-Stone", pvp = true })
    end)

    describe("PvP flags from casts state.castLandsOn sent elsewhere (white)", function()
        it("keeps a flag from a redirected cast out of flaggedBy, in flaggedElsewhere", function()
            wow.state.castLandsOn = "nameplate4"
            wow.runMacro(MACRO)
            assert.are.equal("Dot-Stone", wow.casts[1].target, "the cast went to Dot")
            assert.is_true(wow.state.pvp, "helping a flagged player still flags you")
            assert.are.same({}, wow.flaggedBy)
            assert.are.same({ "Dot-Stone" }, wow.flaggedElsewhere)
        end)

        it("does the same when the server answers late", function()
            wow.state.castLandsOn = "nameplate4"
            wow.state.castLatency = 1.5
            wow.runMacro(MACRO)
            assert.is_falsy(wow.state.pvp, "not until the server answers")
            wow.advance(2)
            assert.is_true(wow.state.pvp)
            assert.are.same({}, wow.flaggedBy)
            assert.are.same({ "Dot-Stone" }, wow.flaggedElsewhere)
        end)

        it("still puts a flag from a cast aimed at a flagged player in flaggedBy", function()
            wow.runMacro("/targetexact Dot Stone\n/cast [help,nodead] Mark of the Wild")
            assert.are.same({ "Dot-Stone" }, wow.flaggedBy)
            assert.are.same({}, wow.flaggedElsewhere)
        end)

        it("counts a cast as aimed when state.castLandsOn names the player the macro aimed at", function()
            wow.state.castLandsOn = "nameplate4"
            wow.runMacro("/targetexact Dot Stone\n/cast [help,nodead] Mark of the Wild")
            assert.are.same({ "Dot-Stone" }, wow.flaggedBy)
            assert.are.same({}, wow.flaggedElsewhere)
        end)

        it("counts a cast as aimed when state.castLandsOn names another token for the same player", function()
            wow.addUnit("nameplate7", { name = "Dot", surname = "Stone", class = "MAGE", id = "Dot-Stone", pvp = true })
            wow.state.castLandsOn = "nameplate7"
            wow.runMacro("/targetexact Dot Stone\n/cast [help,nodead] Mark of the Wild")
            assert.are.equal("Dot-Stone", wow.casts[1].target)
            assert.are.same({ "Dot-Stone" }, wow.flaggedBy, "the player the macro aimed at")
            assert.are.same({}, wow.flaggedElsewhere)
        end)

        it("flags nothing when the redirected cast lands on someone unflagged", function()
            wow.state.castLandsOn = "nameplate5"
            wow.runMacro("/targetexact Dot Stone\n/cast [help,nodead] Mark of the Wild")
            assert.are.equal("Ann-Stone", wow.casts[1].target)
            assert.is_falsy(wow.state.pvp)
            assert.are.same({}, wow.flaggedBy)
            assert.are.same({}, wow.flaggedElsewhere)
        end)
    end)

    describe("a macro's conditions on the unit state.castLandsOn sends the cast to (white)", function()
        it("casts nothing for a [help,nodead] macro when the cast would land on a dead unit", function()
            wow.addUnit("nameplate2", { name = "Cid", surname = "Stone", class = "MAGE", id = "Cid-Stone", dead = true })
            wow.state.castLandsOn = "nameplate2"
            wow.runMacro(MACRO)
            assert.are.equal(0, #wow.casts, "no cast on the dead unit")
        end)

        it("casts nothing for a [help,nodead] macro when the cast would land on a hostile unit", function()
            wow.addUnit("nameplate2", { name = "Cid", surname = "Stone", class = "MAGE", id = "Cid-Stone", hostile = true })
            wow.state.castLandsOn = "nameplate2"
            wow.runMacro(MACRO)
            assert.are.equal(0, #wow.casts, "no cast on the hostile unit")
        end)

        it("still lands on a living friendly unit", function()
            wow.state.castLandsOn = "nameplate4"
            wow.runMacro(MACRO)
            assert.are.equal(1, #wow.casts)
            assert.are.equal("Dot-Stone", wow.casts[1].target)
        end)

        it("still checks your target: a dead target casts nothing, wherever the cast would land", function()
            wow.addUnit("nameplate2", { name = "Cid", surname = "Stone", class = "MAGE", id = "Cid-Stone", dead = true })
            wow.state.castLandsOn = "nameplate4"
            wow.runMacro("/targetexact Cid Stone\n/cast [help,nodead] Mark of the Wild")
            assert.are.equal(0, #wow.casts)
        end)
    end)
end)
