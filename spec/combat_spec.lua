-- In combat (and encounters, Mythic+, PvP) the game hands addons "secret"
-- values: buff update fields and unit queries among them. Testing one in an
-- `if` raises a Lua error in the real client. In this simulation such a test
-- silently counts as true, so each case checks the addon doesn't act on it.
local wow = require("spec.support.wow")

describe("In combat (restricted data)", function()
    local ns

    before_each(function()
        ns = wow.boot()
        ns.db.buff.messages = { "Thank you for the {buff}, {name}!" }
        ns.db.debug = true
        wow.addUnit("target", { name = "Bob-Brightwood" })
    end)

    local function settle()
        wow.advance(30)
        wow.keyDown()
    end

    local function logHas(fragment)
        for _, line in ipairs(ns.db.diagLog) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end

    local function noErrors()
        assert.is_nil(ns.Diag.Counters().luaErrors, ns.Diag.lastError)
        assert.are.same({}, wow.errors)
    end

    describe("buff updates with secret fields", function()
        -- The in-game error: "attempt to perform boolean test on field
        -- 'isFullUpdate' (a secret boolean value)" after killing a mob.
        it("a secret isFullUpdate is skipped, not treated as a full update", function()
            wow.state.playerAuras = {
                { auraInstanceID = 1, isHelpful = true, name = "Fort", sourceUnit = "target",
                  isFromPlayerOrPlayerPet = true },
            }
            wow.fire("UNIT_AURA", "player", { isFullUpdate = wow.secret(false) })
            settle()
            assert.are.equal(0, #wow.sent)
            assert.is_true(logHas("aura update is restricted (combat?); skipped"))
            noErrors()
        end)

        it("a secret list of added buffs is skipped", function()
            wow.fire("UNIT_AURA", "player", { addedAuras = wow.secret({ { isHelpful = true } }) })
            settle()
            assert.are.equal(0, #wow.sent)
            assert.is_true(logHas("restricted"))
            noErrors()
        end)

        it("a secret list of removed buffs is skipped", function()
            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = wow.secret({ 1 }) })
            assert.is_true(logHas("restricted"))
            noErrors()
        end)

        it("counts restricted updates for /friendly status", function()
            wow.fire("UNIT_AURA", "player", { isFullUpdate = wow.secret(true) })
            wow.fire("UNIT_AURA", "player", { isFullUpdate = wow.secret(true) })
            assert.are.equal(2, ns.Diag.Counters().restrictedAuraUpdates)
            _G.SlashCmdList.FRIENDLYFOREVER("status")
            local all = table.concat(wow.printed, "\n")
            assert.is_truthy(all:find("2 restricted buff updates skipped", 1, true))
        end)

        it("buff thanks work again once the fight is over", function()
            wow.fire("UNIT_AURA", "player", { isFullUpdate = wow.secret(false) })
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            settle()
            assert.are.same({ "Thank you for the Fort, Bob!" }, wow.sentTo("SAY"))
            noErrors()
        end)
    end)

    describe("unit queries answer with secrets", function()
        before_each(function() wow.state.unitsRestricted = true end)

        it("a buff from a unit we can't read isn't thanked, and nothing errors", function()
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            settle()
            assert.are.equal(0, #wow.sent)
            noErrors()
        end)

        it("casts from units we can't read are ignored", function()
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "target", "g", 1459)
            noErrors()
        end)

        it("a party member joining mid-fight is still welcomed", function()
            wow.state.groupType = "party"
            wow.state.groupMembers["Anduin-Wrynn"] = true
            wow.systemMessage("Anduin-Wrynn joins the party.")
            settle()
            assert.are.same({ "Welcome to the group, Anduin!" }, wow.sentTo("PARTY"))
            noErrors()
        end)

        it("the self-test and status don't break", function()
            _G.SlashCmdList.FRIENDLYFOREVER("status")
            _G.SlashCmdList.FRIENDLYFOREVER("names")
            noErrors()
        end)
    end)

    it("secret values in the simulation behave like the game's", function()
        local s = wow.secret(5)
        assert.has_error(function() return s + 1 end)
        assert.has_error(function() return s < 1 end)
        assert.has_error(function() return s.field end)
        -- (#s can't be made to error: Lua 5.1 ignores __len on tables.)
    end)
end)
