-- Spec: #269
-- Renewing a worn buff on buff back: when the person you owe already wears
-- your buff with under the set share of its full time left (default 70%),
-- and yours can replace theirs, buff back offers it again. Over the share,
-- a stronger rank than yours, or a time that can't be read: it counts as worn.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

-- Mark of the Wild (top rank and rank 1), Gift of the Wild, Thorns rank 1.
local MOTW, MOTW_1, GIFT, THORNS_1 = 9885, 1126, 21850, 467
local INTELLECT = 10157
-- Mark of the Wild lasts 30 minutes.
local HALF_HOUR = 1800

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Renewing a worn buff on buff back (#269)", function()
    local ns

    -- A druid who knows Mark of the Wild (both ranks unless told) and Thorns rank 1.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = "DRUID"
            state.knownSpells = opts.known or { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
        end })
        ns.BuffButton.Frame()
    end

    -- Bob Stone, a stranger on a nameplate, who buffed you.
    local function bobBuffsYou()
        wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
        wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
    end

    -- Bob wears spell, lasting duration (default half an hour), with secondsLeft to go.
    local function bobWears(spell, secondsLeft, duration)
        wow.wearBuff("nameplate1", spell, { duration = duration or HALF_HOUR, source = false })
        local u = wow.state.units.nameplate1
        for i, id in ipairs(u.auras) do
            if id == spell then u.auraExpires[i] = wow.now + secondsLeft end
        end
    end

    local function offered()
        local offer = ns.Offers.Current()
        return offer and offer.spell
    end

    local function logLines(fragment)
        local found = {}
        for _, line in ipairs(ns.db.diagLog or {}) do
            if line:find(fragment, 1, true) then found[#found + 1] = line end
        end
        return found
    end

    before_each(function() boot() end)

    describe("the setting (white)", function()
        it("defaults to under 70% left", function()
            assert.are.equal(70, ns.Config.DEFAULTS.buffBack.renewPercent)
            assert.are.equal(70, ns.db.buffBack.renewPercent)
        end)

        it("is a stepper on the Buff Back tab only, stepping by 5 between 0 and 90", function()
            local w = ns.Options.widgets
            local renew = w.steppers.renewPercent
            wow.run(w.tabs.buffBack, "OnClick")
            assert.is_true(renew.box:IsShown())
            assert.are.equal("Renew my buff when theirs has under (% left, 0 = never):", renew.label:GetText())
            assert.are.equal("70", renew.box:GetText())
            wow.run(renew.plus, "OnClick")
            assert.are.equal(75, ns.db.buffBack.renewPercent)
            wow.run(renew.minus, "OnClick")
            wow.run(renew.minus, "OnClick")
            assert.are.equal(65, ns.db.buffBack.renewPercent)
            renew.box:SetText("500")
            wow.run(renew.box, "OnEditFocusLost")
            assert.are.equal(90, ns.db.buffBack.renewPercent, "typed: held to the most")
            wow.run(renew.plus, "OnClick")
            assert.are.equal(90, ns.db.buffBack.renewPercent)
            renew.box:SetText("0")
            wow.run(renew.box, "OnEditFocusLost")
            wow.run(renew.minus, "OnClick")
            assert.are.equal(0, ns.db.buffBack.renewPercent, "never below 0")
            wow.run(w.tabs.buff, "OnClick")
            assert.is_false(renew.box:IsShown(), "not on another tab")
        end)

        it("is found by the options search", function()
            local names = {}
            for _, entry in ipairs(ns.OptionsIndex.Find("renew")) do names[entry.name] = true end
            assert.is_true(names["Renew my buff when theirs has under"])
        end)
    end)

    describe("a worn buff (white)", function()
        it("offers your Mark again when theirs has 10 of its 30 minutes left (the owner's case)", function()
            bobBuffsYou()
            bobWears(MOTW, 10 * 60)
            assert.are.equal("Mark of the Wild", offered())
        end)

        it("counts it as worn with over the share left, and renews it under", function()
            bobBuffsYou()
            bobWears(MOTW, 25 * 60)
            assert.are.equal("Thorns", offered(), "83% left")
            bobWears(MOTW, 21 * 60)
            assert.are.equal("Thorns", offered(), "exactly 70% left isn't under 70%")
            bobWears(MOTW, 21 * 60 - 1)
            assert.are.equal("Mark of the Wild", offered(), "just under 70%")
        end)

        it("follows the setting: 0 never renews, 90 renews sooner", function()
            bobBuffsYou()
            bobWears(MOTW, 60)
            ns.db.buffBack.renewPercent = 0
            assert.are.equal("Thorns", offered(), "0: worn until it's gone, as before #269")
            ns.db.buffBack.renewPercent = 90
            bobWears(MOTW, 26 * 60)
            assert.are.equal("Mark of the Wild", offered(), "26 of 30 minutes is under 90%")
        end)

        it("renews a rank you know as strong (rank 1 worn, top rank known)", function()
            bobBuffsYou()
            bobWears(MOTW_1, 5 * 60)
            assert.are.equal("Mark of the Wild", offered())
        end)
    end)

    describe("never over a stronger buff (white, #41, #206, #253)", function()
        it("leaves a stronger rank than yours alone, however worn", function()
            boot({ known = { [MOTW_1] = true, [THORNS_1] = true } })
            bobBuffsYou()
            bobWears(MOTW, 60)
            assert.are.equal("Thorns", offered())
        end)

        it("leaves a Gift of the Wild stronger than your Mark alone, however worn", function()
            boot({ known = { [MOTW_1] = true, [THORNS_1] = true } })
            bobBuffsYou()
            bobWears(GIFT, 60, 3600)
            assert.are.equal("Thorns", offered())
        end)

        it("renews over a worn Gift of the Wild as strong as your Mark (#206)", function()
            bobBuffsYou()
            bobWears(GIFT, 60, 3600)
            assert.are.equal("Mark of the Wild", offered())
        end)

        it("counts their buff as worn when any copy of it isn't worn off", function()
            bobBuffsYou()
            bobWears(MOTW_1, 60)
            bobWears(GIFT, 3000, 3600)
            assert.are.equal("Thorns", offered(), "the fresh Gift still counts")
        end)
    end)

    describe("the debug log (white)", function()
        it("says a buff was skipped because they wear it, with the time left, once", function()
            ns.Diag.SetEnabled(true)
            bobBuffsYou()
            bobWears(MOTW, 25 * 60)
            offered()
            offered()
            local lines = logLines("skipping Mark of the Wild for Bob-Stone")
            assert.are.equal(1, #lines, "once per favour, though the button re-arms")
            assert.truthy(lines[1]:find("they wear it (25m 00s left, 83%)", 1, true), lines[1])
        end)

        it("says when theirs is one yours can't replace", function()
            boot({ known = { [MOTW_1] = true, [THORNS_1] = true } })
            ns.Diag.SetEnabled(true)
            bobBuffsYou()
            bobWears(GIFT, 60, 3600)
            offered()
            local lines = logLines("skipping Mark of the Wild for Bob-Stone")
            assert.truthy(lines[1] and lines[1]:find("they wear one yours can't replace (1m 00s left, 1%)", 1, true),
                lines[1])
        end)

        it("says when its time can't be read", function()
            ns.Diag.SetEnabled(true)
            bobBuffsYou()
            bobWears(MOTW, 60)
            wow.state.units.nameplate1.secrets = { auraTimes = true }
            offered()
            local lines = logLines("skipping Mark of the Wild for Bob-Stone")
            assert.truthy(lines[1] and lines[1]:find("time left can't be read", 1, true), lines[1])
        end)
    end)

    describe("time that can't be read (black)", function()
        it("counts a buff whose times are secret as worn", function()
            bobBuffsYou()
            bobWears(MOTW, 60)
            wow.state.units.nameplate1.secrets = { auraTimes = true }
            assert.are.equal("Thorns", offered())
        end)

        it("counts a buff that never runs out, or has no times, as worn", function()
            bobBuffsYou()
            bobWears(MOTW, 60)
            local u = wow.state.units.nameplate1
            u.auraDurations[1], u.auraExpires[1] = 0, 0
            assert.are.equal("Thorns", offered(), "never runs out")
            u.auraDurations[1], u.auraExpires[1] = nil, nil
            assert.are.equal("Thorns", offered(), "no times")
            u.auraDurations[1], u.auraExpires[1] = "lots", wow.now + 5
            assert.are.equal("Thorns", offered(), "not numbers")
            u.auraDurations[1], u.auraExpires[1] = 0 / 0, wow.now + 5
            assert.are.equal("Thorns", offered(), "NaN")
        end)
    end)

    describe("a damaged setting (black)", function()
        it("reads as the default when it isn't a number, and is held to its range", function()
            for _, case in ipairs({ { "lots", 70 }, { -5, 0 }, { 1000, 90 }, { 42.7, 42 } }) do
                boot({ db = { buffBack = { renewPercent = case[1] } } })
                assert.are.equal(case[2], ns.db.buffBack.renewPercent, tostring(case[1]))
            end
        end)

        it("damaged mid-session, reads as the default and the button still works", function()
            bobBuffsYou()
            bobWears(MOTW, 20 * 60)
            for _, bad in ipairs({ "lots", {}, 0 / 0, true }) do
                ns.db.buffBack.renewPercent = bad
                assert.are.equal("Mark of the Wild", offered(), "20 of 30 minutes is under 70%")
            end
            bobWears(MOTW, 22 * 60)
            assert.are.equal("Thorns", offered(), "and 22 isn't")
        end)

        it("damaged mid-session past its range, is held to it", function()
            bobBuffsYou()
            bobWears(MOTW, 28 * 60)
            ns.db.buffBack.renewPercent = 95
            assert.are.equal("Thorns", offered(), "28 of 30 minutes is 93%: over the most, 90")
            bobWears(MOTW, 26 * 60)
            assert.are.equal("Mark of the Wild", offered(), "26 is under 90%")
            ns.db.buffBack.renewPercent = -10
            bobWears(MOTW, 1)
            assert.are.equal("Thorns", offered(), "below 0 is 0: never renewed")
        end)
    end)

    describe("buff mode for group members is unchanged (white, #42, #206)", function()
        it("doesn't renew a group member's buff by the buff-back share, only by top-up time", function()
            ns.db.buffBack.renewPercent = 90
            slash("buffmode on")
            wow.setGroup("party", { "Ann-Vale" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            local function annWears(spell, secondsLeft, duration)
                wow.wearBuff("party1", spell, { duration = duration, source = "player" })
                for i, id in ipairs(wow.state.units.party1.auras) do
                    if id == spell then wow.state.units.party1.auraExpires[i] = wow.now + secondsLeft end
                end
            end
            annWears(THORNS_1, 600, 600)
            annWears(MOTW, 10 * 60, HALF_HOUR)
            ns.BuffButton.Refresh()
            local button = ns.BuffButton.Frame()
            local macro = button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
            assert.is_nil(macro, "a third of her Mark left: buff mode leaves it")
            annWears(MOTW, 4 * 60, HALF_HOUR)
            ns.BuffButton.Refresh()
            macro = button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
            assert.truthy(macro and macro:find("Mark of the Wild", 1, true), "under the 5-minute top-up it renews")
        end)
    end)

    describe("chaos (red)", function()
        -- Random worn buffs, times and settings. The expected offer is worked
        -- out from the simulated client's own state, never by asking Offers.
        local function storm(seed, knowsTop)
            local known = { [MOTW_1] = true, [THORNS_1] = true }
            if knowsTop then known[MOTW] = true end
            boot({ known = known })
            random.seed(seed)
            bobBuffsYou()
            local u = wow.state.units.nameplate1
            local settings = { 0, 5, 50, 70, 90, -3, 120, "x", 33.9 }
            for step = 1, 150 do
                u.auras, u.auraSources, u.auraDurations, u.auraExpires, u.secrets = nil, nil, nil, nil, nil
                local setting = settings[random.random(#settings)]
                ns.db.buffBack.renewPercent = setting
                local spell = ({ MOTW, MOTW_1, GIFT })[random.random(3)]
                local duration = ({ HALF_HOUR, 3600, 0 })[random.random(3)]
                local left = random.random(1, math.max(duration, 1))
                bobWears(spell, left, duration)
                if duration == 0 then u.auraExpires[1] = 0 end
                local secret = random.random(4) == 1
                if secret then u.secrets = { auraTimes = true } end

                local share = type(setting) == "number" and math.max(0, math.min(90, math.floor(setting))) or 70
                -- Your rank 1 replaces only rank 1; the top rank replaces
                -- any, and the Gift of the same strength (#206).
                local replaceable = spell == MOTW_1 or knowsTop
                local readable = not secret and duration > 0
                local wornOff = readable and replaceable and left < duration * share / 100
                local expected = wornOff and "Mark of the Wild" or "Thorns"

                local ok, offer = pcall(ns.Offers.Current)
                assert.is_true(ok, tostring(offer))
                assert.are.equal(expected, offer and offer.spell,
                    string.format("seed %d step %d: spell %d, %d of %d s left, setting %s, secret %s",
                        seed, step, spell, left, duration, tostring(setting), tostring(secret)))
                assert.is_false(offer.spell == "Mark of the Wild" and not replaceable,
                    "never offered over a stronger buff")
            end
        end

        it("offers your buff exactly when theirs is worn off and replaceable, over many random cases", function()
            for seed = 1, 4 do storm(seed, seed % 2 == 0) end
        end)
    end)
end)
