-- Spec: #426
-- Solo, buff mode turns on by itself when one of your own buffs is missing
-- or running low (the owner, 16 Nov), by the group trigger's rules (#272,
-- #397): the same running-low times, looked for every WATCH_SECONDS and as
-- a fight ends, never in an arena or battleground, under "missing your
-- buffs" (autoOnMissing). Self-buffs count with "Offer my self-buffs" on,
-- your own copy of the buffs you give with "Offer my own buffs when I'm not
-- in a group" (#329) on.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local FORT, SPIRIT, INNER_FIRE = 10938, 27841, 10952

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Buff mode turns on by itself solo (#426)", function()
    local ns, button

    -- A priest who knows `known` (Fortitude and Spirit unless said), solo,
    -- with buff mode off and only the missing-buff trigger on, wearing
    -- `wearing` (each of yours, 30 minutes) when the login's look notes it.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ buffSelf = true, autoBuffMode = true, before = function(state)
            state.class = "PRIEST"
            state.knownSpells = {}
            for _, id in ipairs(opts.known or { FORT, SPIRIT }) do state.knownSpells[id] = true end
        end })
        for _, field in ipairs({ "autoOnJoin", "autoOnDeath", "autoOnBuffed", "autoOnCampfire" }) do
            ns.db.buffBack[field] = false
        end
        for _, id in ipairs(opts.wearing or { FORT, SPIRIT }) do
            wow.gainBuff({ spellId = id, sourceUnit = "player", duration = 1800, expirationTime = wow.now + 1800 })
        end
        button = ns.BuffButton.Frame()
        -- The login's look only notes what you wear.
        wow.advance(ns.BuffModeAuto.WATCH_SECONDS)
    end

    local function look() wow.advance(ns.BuffModeAuto.WATCH_SECONDS) end

    local function armed()
        ns.BuffButton.Refresh()
        local text = button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
        return text and text:match("^/cast %[@player,nodead%] ([^\n]+)$")
    end

    -- Your buff of this spell fades (or is cancelled).
    local function fade(id) wow.loseBuff(id) end

    -- Your buff of this spell, put up again by you, with left seconds of its 30 minutes to go.
    local function wear(id, left)
        wow.loseBuff(id)
        return wow.gainBuff({ spellId = id, sourceUnit = "player", duration = 1800,
            expirationTime = wow.now + (left or 1800) })
    end

    local function printedHas(fragment)
        for _, line in ipairs(wow.printed) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end

    describe("turning on (white)", function()
        it("solo, your Fortitude fades out of combat: buff mode turns on, and the button offers it on you", function()
            boot()
            look()
            assert.is_false(ns.BuffMode.IsOn(), "you have your buffs")
            fade(FORT)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("you're missing your Power Word: Fortitude"))
            assert.are.equal("Power Word: Fortitude", armed())
            assert.are.equal(0, #wow.casts, "it never casts by itself")
        end)

        it("solo, a buff running low past the Top up time turns it on", function()
            boot()
            wear(FORT, ns.db.buffBack.topUpMinutes * 60 + 30)
            look()
            assert.is_false(ns.BuffMode.IsOn(), "not yet low")
            wow.advance(31)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("your Power Word: Fortitude is running low"))
        end)

        it("with Top up 0, a long buff running low never turns it on", function()
            boot()
            ns.db.buffBack.topUpMinutes = 0
            wear(FORT, 20)
            for _ = 1, 3 do look() end
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("a self-buff counts solo with Offer my self-buffs on, and not with it off", function()
            boot({ known = { FORT, INNER_FIRE }, wearing = { FORT, INNER_FIRE } })
            ns.db.buffBack.selfBuffs = false
            fade(INNER_FIRE)
            look()
            assert.is_false(ns.BuffMode.IsOn(), "self-buffs are off")
            boot({ known = { FORT, INNER_FIRE }, wearing = { FORT, INNER_FIRE } })
            fade(INNER_FIRE)
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "your Inner Fire")
            assert.are.equal("Inner Fire", armed())
        end)

        it("your own copy counts only with Offer my own buffs when I'm not in a group on", function()
            boot()
            ns.db.buffBack.soloOwnBuffs = false
            fade(FORT)
            look()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("is the missing-buff trigger's: off, nothing solo turns on", function()
            boot()
            ns.db.buffBack.autoOnMissing = false
            fade(FORT)
            look()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("in a fight it waits: the fight's end turns it on", function()
            boot()
            wow.enterCombat()
            fade(FORT)
            look()
            assert.is_false(ns.BuffMode.IsOn(), "in the fight")
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("the fight ended and you're missing your Power Word: Fortitude"))
        end)

        it("never in an arena or a battleground", function()
            for _, kind in ipairs({ "arena", "pvp" }) do
                boot()
                wow.state.inInstance, wow.state.instanceType = true, kind
                fade(FORT)
                look()
                wow.enterCombat()
                wow.leaveCombat()
                assert.is_false(ns.BuffMode.IsOn(), kind)
            end
        end)

        it("in a group, a missing self-buff alone still never turns it on (#44 Q6)", function()
            boot({ known = { FORT, INNER_FIRE }, wearing = { FORT, INNER_FIRE } })
            wow.setGroup("party", { "Ann-Vale" })
            wow.wearBuff("party1", FORT, { source = "player" })
            wow.fire("GROUP_ROSTER_UPDATE")
            look()
            fade(INNER_FIRE)
            look()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("leaving a group, a buff you were already missing isn't new; one that fades after is", function()
            boot({ wearing = { SPIRIT } })
            wow.setGroup("party", { "Ann-Vale" })
            wow.wearBuff("party1", FORT, { source = "player" })
            wow.wearBuff("party1", SPIRIT, { source = "player" })
            wow.fire("GROUP_ROSTER_UPDATE")
            look()
            slash("buffmode off")
            wow.setGroup(nil, {})
            wow.fire("GROUP_ROSTER_UPDATE")
            look()
            look()
            assert.is_false(ns.BuffMode.IsOn(), "your Fortitude was missing before you left")
            fade(SPIRIT)
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "your Spirit faded since")
        end)
    end)

    describe("turned off by hand, and turning off (white)", function()
        it("turned off by hand, it stays off until a different buff drops, or the same one is recast and drops", function()
            boot()
            fade(FORT)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            slash("buffmode off")
            for _ = 1, 3 do look() end
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn(), "the same buff, even as a fight ends")
            fade(SPIRIT)
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "a different buff dropped")
            slash("buffmode off")
            wear(FORT)
            wear(SPIRIT)
            look()
            fade(FORT)
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "recast, then dropped again")
        end)

        it("turns off once you have your buffs, at the first pull, or at the timeout", function()
            boot()
            fade(FORT)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            wear(FORT)
            ns.BuffButton.Refresh()
            assert.is_false(ns.BuffMode.IsOn(), "you have your buffs")
            assert.is_true(printedHas("you have your buffs"))
            look()
            fade(FORT)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.enterCombat()
            assert.is_false(ns.BuffMode.IsOn(), "the pull")
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto(), "the fight ended and it's still missing")
            wow.advance(ns.db.buffBack.autoOffMinutes * 60 + 1)
            assert.is_false(ns.BuffMode.IsOn(), "the timeout")
        end)
    end)

    describe("unreadable (black)", function()
        it("with your auras unreadable, nothing turns on and nothing errors", function()
            boot()
            wow.state.aurasRestricted = true
            fade(FORT)
            for _ = 1, 3 do look() end
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end)

        it("with your auras secret, nothing turns on and nothing errors", function()
            boot()
            local real = _G.C_UnitAuras.GetAuraDataByIndex
            _G.C_UnitAuras.GetAuraDataByIndex = function(unit, i, filter)
                if unit == "player" then return wow.secret({ spellId = SPIRIT }) end
                return real(unit, i, filter)
            end
            fade(FORT)
            for _ = 1, 3 do look() end
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end)

        it("with the group answer unreadable, nothing turns on and nothing errors", function()
            boot()
            wow.state.inGroupUnreadable = true
            fade(FORT)
            for _ = 1, 3 do look() end
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("storms (red)", function()
        it("a chaos storm of solo aura changes, fights, group joins and leaves never errors, never casts, "
            .. "and never turns on in a fight", function()
            local function chance(p) return random.random() < p end
            local turnedOn = 0
            for seed = 1, 6 do
                random.seed(seed)
                boot({ known = { FORT, SPIRIT, INNER_FIRE }, wearing = { FORT, SPIRIT, INNER_FIRE } })
                for _ = 1, 120 do
                    local id = ({ FORT, SPIRIT, INNER_FIRE })[random.random(3)]
                    if chance(0.3) then fade(id) end
                    if chance(0.3) then wear(id, random.random(10, 1800)) end
                    if chance(0.05) then
                        wow.setGroup(chance(0.5) and "party" or nil, chance(0.5) and { "Ann-Vale" } or {})
                        wow.fire("GROUP_ROSTER_UPDATE")
                    end
                    if chance(0.05) then wow.state.inGroupUnreadable = chance(0.3) or nil end
                    if chance(0.05) then wow.state.aurasRestricted = chance(0.3) end
                    if chance(0.05) then
                        ns.db.buffBack.topUpMinutes = chance(0.3) and 0 or 5
                    end
                    if chance(0.05) and ns.BuffMode.IsOn() then slash("buffmode off") end
                    local fighting = wow.state.inCombat
                    if chance(0.1) then
                        if fighting then wow.leaveCombat() else wow.enterCombat() end
                    end
                    local wasOn = ns.BuffMode.IsOn()
                    wow.advance(random.random(1, 6))
                    if wow.state.inCombat then
                        assert.is_false(not wasOn and ns.BuffMode.IsOn(), "turned on in a fight")
                    end
                    if not wasOn and ns.BuffMode.IsOn() then turnedOn = turnedOn + 1 end
                    assert.are.same({}, wow.errors)
                    assert.are.equal(0, #wow.casts)
                end
                if wow.state.inCombat then wow.leaveCombat() end
            end
            assert.is_true(turnedOn > 10, turnedOn .. " times it turned on")
        end)
    end)
end)
