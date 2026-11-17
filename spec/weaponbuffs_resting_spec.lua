-- Spec: #449
-- Weapon buffs aren't offered while you're resting (the owner, 17 Nov): in
-- a city, an inn or a town with one, by the game's resting flag
-- (IsResting()), weapon buffs (#45) are never offered: no list row, no
-- press, and they never keep buff mode on. An unreadable or secret answer
-- counts as resting. Self-buffs and solo buff mode (#426) are unchanged.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local W = wow.WEAPON
local FORT, INNER_FIRE = 10938, 10952
local OIL_MACRO = "/use item:20749\n/use 16"

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Weapon buffs while resting (#449)", function()
    local ns, button

    -- A mage with a bare main hand and wizard oil in the bags, weapon buffs
    -- on, resting if opts.resting, in buff mode unless opts.noMode.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = { buffBack = { weaponBuffs = true, weaponMain = "wizardOil", weaponOff = "none" } },
            buffSelf = true, autoBuffMode = opts.auto, before = function(state)
                state.class = opts.class or "MAGE"
                state.knownSpells = {}
                for _, id in ipairs(opts.known or {}) do state.knownSpells[id] = true end
                state.items = { [W.brilliantWizardOil] = 2 }
                state.itemNames = { [W.brilliantWizardOil] = "Brilliant Wizard Oil" }
                state.resting = opts.resting
                state.zone = opts.zone
                if opts.before then opts.before(state) end
            end })
        button = ns.BuffButton.Frame()
        if not opts.noMode then slash("buffmode on") end
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end
    local function subtitle() return button.subtitle:GetText() end
    local function refresh() ns.BuffButton.Refresh() end
    local function press() wow.press(button) end

    -- The weapon rows in the list beside the button.
    local function weaponRows()
        local list = ns.BuffList.Frame()
        if not (list and list:IsShown()) then return 0 end
        local n = 0
        for _, offer in ipairs(ns.BuffList.ShownOffers()) do
            if offer.weapon then n = n + 1 end
        end
        return n
    end

    -- Nothing of a weapon buff anywhere: no macro, no row, and a press puts nothing on.
    local function nothingOffered(why)
        refresh()
        assert.is_nil(macro(), "no press is armed")
        assert.are.equal(0, weaponRows(), "no list row")
        if why then assert.matches("Weapons: " .. why, subtitle(), 1, true) end
        local offer, reason, settled = ns.WeaponBuffs.Next()
        assert.is_nil(offer)
        assert.is_true(settled, "settled: it never keeps buff mode on")
        if why then assert.are.equal(why, reason) end
        press()
        wow.advance(0)
        assert.are.equal(0, #wow.applied, "a press puts nothing on")
    end

    describe("in a rested place (white)", function()
        it("in a capital, with a bare hand and an oil in your bags, nothing is offered; leaving offers it again", function()
            boot({ resting = true, zone = "Stormwind City" })
            nothingOffered("you're resting")
            -- Out of the city: the game's event refreshes the button, nobody else.
            wow.state.zone = "Elwynn Forest"
            wow.rest(false)
            wow.advance(0)
            assert.are.equal(OIL_MACRO, macro())
            assert.are.equal(1, weaponRows())
            press()
            assert.are.equal(1, #wow.applied)
        end)

        it("in an inn or a town the capital list doesn't know, the same", function()
            for _, zone in ipairs({ "Goldshire", "Valanaar" }) do
                boot({ resting = true, zone = zone })
                nothingOffered("you're resting")
            end
        end)

        it("walking into a rested place takes the offer away at once, with no refresh but the game's event", function()
            boot()
            assert.are.equal(OIL_MACRO, macro())
            wow.rest(true)
            wow.advance(0)
            assert.is_nil(macro())
            assert.are.equal(0, weaponRows())
            assert.matches("Weapons: you're resting", subtitle(), 1, true)
        end)

        it("a press made just after you start resting, before any refresh, puts nothing on", function()
            boot()
            assert.are.equal(OIL_MACRO, macro())
            wow.state.resting = true -- the event hasn't come yet
            press()
            wow.advance(0)
            assert.are.equal(0, #wow.applied)
            assert.are.equal(0, #wow.weaponCasts)
        end)

        it("your self-buffs are offered as usual while resting", function()
            boot({ class = "PRIEST", known = { INNER_FIRE }, resting = true })
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
            press()
            wow.advance(0)
            nothingOffered("you're resting")
        end)

        it("a missing weapon buff never keeps buff mode on while resting, though it does outside", function()
            for _, resting in ipairs({ true, false }) do
                boot({ auto = true, noMode = true, class = "PRIEST", known = { FORT }, resting = resting })
                wow.gainBuff({ spellId = FORT, sourceUnit = "player", duration = 3600, expirationTime = wow.now + 3600 })
                wow.setGroup("party", { "Ann-Vale" })
                ns.db.buffBack.autoOnMissing = true
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.advance(30)
                assert.is_true(ns.BuffMode.IsAuto(), "Ann is missing Fortitude")
                press()
                wow.wearBuff("party1", FORT, { source = "player" })
                refresh()
                if resting then
                    assert.is_false(ns.BuffMode.IsOn(), "resting: the oil doesn't keep it on")
                else
                    assert.is_true(ns.BuffMode.IsOn(), "outside: still on for the oil")
                    assert.are.equal(OIL_MACRO, macro())
                end
            end
        end)

        it("solo buff mode (#426) still turns on and offers your Fortitude while resting, and the oil never keeps it on", function()
            ns = wow.boot({ db = { buffBack = { weaponBuffs = true, weaponMain = "wizardOil", weaponOff = "none" } },
                buffSelf = true, autoBuffMode = true, before = function(state)
                    state.class = "PRIEST"
                    state.knownSpells = { [FORT] = true }
                    state.items = { [W.brilliantWizardOil] = 2 }
                    state.resting = true
                end })
            for _, field in ipairs({ "autoOnJoin", "autoOnDeath", "autoOnBuffed", "autoOnCampfire" }) do
                ns.db.buffBack[field] = false
            end
            wow.gainBuff({ spellId = FORT, sourceUnit = "player", duration = 1800, expirationTime = wow.now + 1800 })
            button = ns.BuffButton.Frame()
            wow.advance(ns.BuffModeAuto.WATCH_SECONDS)
            wow.advance(ns.BuffModeAuto.WATCH_SECONDS)
            assert.is_false(ns.BuffMode.IsOn(), "you have your Fortitude, and the oil is no trigger")
            wow.loseBuff(FORT)
            wow.advance(ns.BuffModeAuto.WATCH_SECONDS)
            assert.is_true(ns.BuffMode.IsAuto(), "solo, your Fortitude faded: on, resting or not")
            refresh()
            assert.are.equal("/cast [@player,nodead] Power Word: Fortitude", macro())
            press()
            wow.advance(0)
            refresh()
            assert.is_false(ns.BuffMode.IsOn(), "done: the oil doesn't keep it on while resting")
        end)
    end)

    describe("when resting can't be read (black)", function()
        it("a secret answer counts as resting: nothing is offered", function()
            boot({ before = function(s) s.restingSecret = true end })
            nothingOffered("can't tell whether you're resting")
            wow.state.restingSecret = nil
            refresh()
            assert.are.equal(OIL_MACRO, macro())
        end)

        it("no such function, an error, or an answer that isn't true or false counts as resting", function()
            local cases = {
                { "missing", nil },
                { "error", function() error("no") end },
                { "nil", function() return nil end },
                { "one", function() return 1 end },
                { "text", function() return "no" end },
                { "zero", function() return 0 end },
            }
            for _, case in ipairs(cases) do
                boot()
                _G.IsResting = case[2]
                nothingOffered("can't tell whether you're resting")
            end
        end)

        it("an unreadable answer never keeps buff mode on", function()
            boot({ auto = true, noMode = true, class = "PRIEST", known = { FORT },
                before = function(s) s.restingSecret = true end })
            wow.gainBuff({ spellId = FORT, sourceUnit = "player", duration = 3600, expirationTime = wow.now + 3600 })
            wow.setGroup("party", { "Ann-Vale" })
            ns.db.buffBack.autoOnMissing = true
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(30)
            assert.is_true(ns.BuffMode.IsAuto())
            press()
            wow.wearBuff("party1", FORT, { source = "player" })
            refresh()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("in a fight in town, says you're resting, and it's settled", function()
            boot({ resting = true })
            wow.enterCombat()
            local offer, why, settled = ns.WeaponBuffs.Next()
            assert.is_nil(offer)
            assert.are.equal("you're resting", why)
            assert.is_true(settled)
        end)

        it("says it once in debug while it holds", function()
            boot()
            local said = 0
            local log = ns.Diag.Log
            ns.Diag.Log = function(category, fmt, ...)
                if string.format(fmt, ...):find("you're resting", 1, true) then said = said + 1 end
                return log(category, fmt, ...)
            end
            wow.rest(true)
            for _ = 1, 10 do
                refresh()
                ns.WeaponBuffs.Next()
                wow.advance(5)
            end
            assert.are.equal(1, said)
        end)
    end)

    describe("a storm of places (red)", function()
        local SEEDS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 }
        local ZONES = { "Stormwind City", "Goldshire", "Valanaar", "Elwynn Forest", "Duskwood", "Orgrimmar" }
        local offeredOutside, refusedInside = 0, 0

        for _, seed in ipairs(SEEDS) do
            it("never offers or puts on a weapon buff while resting, and never errors (seed " .. seed .. ")", function()
                random.seed(seed)
                local function int(m, n) return random.random(m, n) end
                boot({ before = function(s) s.items[W.brilliantWizardOil] = 50 end })
                -- Whether the client says you rest, worked out from its own state.
                local function resting() return wow.state.resting == true or wow.state.restingSecret == true end
                for step = 1, 150 do
                    local where = string.format("seed %d step %d", seed, step)
                    local s = wow.state
                    local roll = int(1, 12)
                    if roll <= 3 then
                        s.zone = ZONES[int(1, #ZONES)]
                        wow.fire(({ "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA" })[int(1, 3)])
                    elseif roll <= 5 then
                        wow.rest(int(1, 2) == 1)
                    elseif roll == 6 then
                        -- The answer changes with no event yet.
                        s.resting = int(1, 2) == 1
                    elseif roll == 7 then
                        s.restingSecret = int(1, 4) == 1 or nil
                    elseif roll == 8 then
                        s.weaponEnchants[16] = nil
                    else
                        local before = #wow.applied
                        local wasResting = resting()
                        press()
                        if wasResting then
                            assert.are.equal(before, #wow.applied, where .. ": put on while resting")
                            refusedInside = refusedInside + 1
                        elseif #wow.applied > before then
                            offeredOutside = offeredOutside + 1
                        end
                    end
                    wow.advance(int(0, 2))
                    refresh()
                    if resting() then
                        assert.is_nil(macro(), where .. ": armed while resting")
                        assert.are.equal(0, weaponRows(), where .. ": a row while resting")
                    end
                    assert.are.same({}, wow.errors, where)
                end
            end)
        end

        it("the storms pressed both resting and not, and put oil on outside, so they test something", function()
            assert.is_true(refusedInside > 0)
            assert.is_true(offeredOutside > 0)
        end)
    end)
end)
