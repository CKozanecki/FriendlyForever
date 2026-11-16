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
local INTELLECT, ICE_ARMOR, MAGE_ARMOR = 10157, 10220, 22783

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Buff mode turns on by itself solo (#426)", function()
    local ns, button

    -- A priest who knows `known` (Fortitude and Spirit unless said), solo,
    -- with buff mode off and only the missing-buff trigger on, wearing
    -- `wearing` (each of yours, 30 minutes) when the login's look notes it.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, buffSelf = true, autoBuffMode = true, before = function(state)
            state.class = opts.class or "PRIEST"
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

        -- The game may send no roster update for a leave (#373): until one
        -- is read, the looks aren't solo ones, and the first that is only notes.
        it("leaving a group before a roster update says so, a self-buff missing all along isn't new", function()
            boot({ known = { FORT, SPIRIT, INNER_FIRE }, wearing = { FORT, SPIRIT } })
            wow.setGroup("party", { "Ann-Vale" })
            wow.wearBuff("party1", FORT, { source = "player" })
            wow.wearBuff("party1", SPIRIT, { source = "player" })
            wow.fire("GROUP_ROSTER_UPDATE")
            look()
            assert.is_false(ns.BuffMode.IsOn(), "in a group, your Inner Fire alone")
            wow.setGroup(nil, {})
            look()
            assert.is_false(ns.BuffMode.IsOn(), "the leave isn't read yet")
            wow.fire("GROUP_ROSTER_UPDATE")
            look()
            look()
            assert.is_false(ns.BuffMode.IsOn(), "your Inner Fire was missing before you left")
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

    describe("self-buffs and their families (white)", function()
        it("a self-buff running low says so", function()
            boot({ known = { FORT, INNER_FIRE }, wearing = { FORT } })
            wear(INNER_FIRE, 600)
            local aura = wow.state.playerAuras[#wow.state.playerAuras]
            aura.duration, aura.expirationTime = 600, wow.now + 90
            look()
            assert.is_false(ns.BuffMode.IsOn())
            wow.advance(40)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("your Inner Fire is running low"))
        end)

        it("a self-buff turned off by hand while low stays dismissed when it only stops counting as low", function()
            boot({ known = { FORT, INNER_FIRE }, wearing = { FORT } })
            wear(INNER_FIRE, 600)
            local aura = wow.state.playerAuras[#wow.state.playerAuras]
            aura.duration, aura.expirationTime = 600, wow.now + 300
            look()
            wow.advance(250)
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "running low")
            slash("buffmode off")
            ns.db.buffBack.topUpMinutes = 0 -- no longer "low": not a fresh copy
            look()
            ns.db.buffBack.topUpMinutes = 5
            look()
            assert.is_false(ns.BuffMode.IsOn(), "the same copy, low again")
        end)

        it("an armor counts by its family: wearing another of yours covers it, and its recast forgets a dismissal",
            function()
            boot({ class = "MAGE", known = { INTELLECT, ICE_ARMOR, MAGE_ARMOR }, wearing = { INTELLECT, MAGE_ARMOR } })
            look()
            assert.is_false(ns.BuffMode.IsOn(), "Mage Armor covers the family")
            fade(MAGE_ARMOR)
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "no armor of yours")
            slash("buffmode off")
            -- You put up the other armor, then it fades: a fresh copy dropped.
            wear(ICE_ARMOR)
            look()
            fade(ICE_ARMOR)
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "the family was recast, then dropped")
        end)

        it("turned off by hand just as a buff fades, before any look, it stays off for that buff", function()
            boot({ known = { FORT, INNER_FIRE }, wearing = { FORT, INNER_FIRE } })
            slash("buffmode on")
            fade(INNER_FIRE)
            slash("buffmode off")
            look()
            look()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("a buff that fades as you leave a group isn't new at the first solo look", function()
            boot()
            wow.setGroup("party", { "Ann-Vale" })
            wow.wearBuff("party1", FORT, { source = "player" })
            wow.wearBuff("party1", SPIRIT, { source = "player" })
            wow.fire("GROUP_ROSTER_UPDATE")
            look()
            assert.is_false(ns.BuffMode.IsOn())
            fade(FORT)
            wow.setGroup(nil, {})
            wow.fire("GROUP_ROSTER_UPDATE")
            look()
            look()
            assert.is_false(ns.BuffMode.IsOn(), "the first solo look only notes")
        end)

        it("a fight's end while the group answer isn't known since the login does nothing", function()
            boot()
            wow.state.inGroupUnreadable = true
            wow.reloadInPlace(true)
            wow.state.inGroupUnreadable = nil
            fade(FORT)
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn())
        end)
    end)

    describe("the looks solo (white)", function()
        -- The addon's own timers waiting (the game's are kept apart).
        local function ticking()
            local n = 0
            for _, t in ipairs(wow.timers) do
                if not t.game then n = n + 1 end
            end
            return n
        end

        it("solo with the trigger off, nothing ticks from the login on; switched on, the looks start", function()
            boot({ db = { buffBack = { autoOnMissing = false } } })
            look()
            assert.are.equal(0, ticking(), "nothing ticks")
            ns.db.buffBack.autoOnMissing = true
            ns.BuffButton.Refresh() -- as ticking its box does
            look() -- the first look since the login only notes
            fade(FORT)
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "the looks started again")
        end)

        it("switched off solo, the looks stop", function()
            boot()
            look()
            ns.db.buffBack.autoOnMissing = false
            look()
            look()
            assert.are.equal(0, ticking())
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

        -- The mutation check: with no guard on when a copy was put up, a
        -- damaged duration of 0 read as a fresh copy and forgot the dismissal.
        it("a copy whose times read damaged isn't a recast: turned off by hand while low, it stays off", function()
            boot({ known = { FORT, INNER_FIRE }, wearing = { FORT } })
            wear(INNER_FIRE, 600)
            local aura = wow.state.playerAuras[#wow.state.playerAuras]
            aura.duration, aura.expirationTime = 600, wow.now + 300
            look()
            wow.advance(250)
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "running low")
            slash("buffmode off")
            local expires = aura.expirationTime
            aura.duration, aura.expirationTime = 0, wow.now + 600 -- damaged: no full time
            look()
            aura.duration, aura.expirationTime = 600, expires -- the same copy, read again
            look()
            assert.is_false(ns.BuffMode.IsOn(), "the same copy, still low")
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

        -- #417's architecture review: the self-buffs went by the last group
        -- answer read, not this look's.
        it("with the group answer unreadable, a missing self-buff alone turns nothing on", function()
            boot({ known = { FORT, SPIRIT, INNER_FIRE }, wearing = { FORT, SPIRIT, INNER_FIRE } })
            look()
            wow.state.inGroupUnreadable = true
            fade(INNER_FIRE)
            for _ = 1, 3 do look() end
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end)

        it("a group joined in a fight that couldn't be read: a missing self-buff alone turns nothing on as it ends",
            function()
                boot({ known = { FORT, SPIRIT, INNER_FIRE }, wearing = { FORT, SPIRIT, INNER_FIRE } })
                look()
                wow.enterCombat()
                fade(INNER_FIRE)
                wow.setGroup("party", { "Ann-Vale" })
                wow.wearBuff("party1", FORT, { source = "player" })
                wow.wearBuff("party1", SPIRIT, { source = "player" })
                wow.state.inGroupUnreadable = true
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.state.inGroupUnreadable = nil
                wow.leaveCombat()
                assert.is_false(ns.BuffMode.IsOn(), "in a group now: your Inner Fire alone")
                look()
                assert.is_false(ns.BuffMode.IsOn(), "the next look reads the group")
                assert.are.same({}, wow.errors)
            end)

        it("solo again and readable, a self-buff that fades after turns it on", function()
            boot({ known = { FORT, SPIRIT, INNER_FIRE }, wearing = { FORT, SPIRIT, INNER_FIRE } })
            look()
            wow.state.inGroupUnreadable = true
            look()
            wow.state.inGroupUnreadable = nil
            look()
            fade(INNER_FIRE)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
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
