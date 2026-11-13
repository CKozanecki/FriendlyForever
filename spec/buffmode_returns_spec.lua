-- Spec: #272
-- Buff mode comes back on by itself, in any group, out of combat, when a
-- member is missing one of your buffs outright: never cast, or fully faded,
-- not merely running low. It stays on until everyone is covered, or the next
-- pull.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1 = 9885, 1126
-- Every Mark of the Wild rank the storms below put on anyone: the chaos
-- test's own idea of "wearing it", read from the client's state.
local MARKS = { [MOTW] = true, [MOTW_1] = true }
local INTELLECT = 10157

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

local function printedHas(fragment)
    for _, line in ipairs(wow.printed) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

describe("Buff mode coming back when a buff of yours is missing (#272)", function()
    local ns

    -- A druid who knows Mark of the Wild, with only this trigger on: joining,
    -- a death or a stranger's buff never turn it on here.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = { buffBack = { autoOnJoin = false, autoOnDeath = false, autoOnBuffed = false } },
            autoBuffMode = true, buffSelf = opts.buffSelf, before = function(state)
                state.class = "DRUID"
                state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
            end })
    end

    -- Ann and Cid join, each wearing your Mark for duration seconds.
    local function joinCovered(duration)
        wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
        for _, token in ipairs({ "party1", "party2" }) do
            wow.wearBuff(token, MOTW, { source = "player", duration = duration or 1800 })
        end
        wow.fire("GROUP_ROSTER_UPDATE")
    end

    -- Long enough for the next look at the group.
    local function look() wow.advance(ns.BuffModeAuto.WATCH_SECONDS + 0.1) end

    -- Take Ann's buffs away at once (a dispel, say: fully gone).
    local function strip(token) wow.state.units[token or "party1"].auras = {} end

    -- Scroll once and let the buff show on whoever it reached.
    local function scroll()
        local before = #wow.casts
        wow.pressKey("MOUSEWHEELUP")
        local cast = wow.casts[before + 1]
        if cast then
            for token, u in pairs(wow.state.units) do
                if u.id == cast.target and token ~= "target" then
                    wow.wearBuff(token, cast.id, { source = "player" })
                end
            end
        end
        return cast
    end

    before_each(function() boot() end)

    describe("turning on (white)", function()
        it("after combat ends with a member lacking your buff, buff mode turns on", function()
            joinCovered()
            look()
            assert.is_false(ns.BuffMode.IsOn(), "everyone is covered")
            wow.enterCombat()
            strip("party1")
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.are.equal("MOUSEWHEELUP", ns.BuffMode.LentKey())
            assert.is_true(printedHas("(the fight ended and Ann Vale is missing your Mark of the Wild)"))
            assert.are.same({}, wow.casts, "turning on never casts")
        end)

        it("after combat ends, a member who was never buffed turns it on too", function()
            wow.setGroup("party", { "Ann-Vale" })
            wow.state.units.party1.outOfRange = true -- not close by yet: nothing on joining
            wow.fire("GROUP_ROSTER_UPDATE")
            look()
            assert.is_false(ns.BuffMode.IsOn())
            wow.enterCombat()
            wow.state.units.party1.outOfRange = nil
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("a buff of yours fully fading from a member, out of combat, turns it on; a buff running low doesn't", function()
            -- Top-up time is 5 minutes (the default): under that is running low.
            assert.are.equal(5, ns.db.buffBack.topUpMinutes)
            joinCovered(1800)
            wow.wearBuff("party2", MOTW, { source = "player", duration = 3600 })
            look()
            assert.is_false(ns.BuffMode.IsOn())
            wow.advance(1800 - 120) -- Ann's has 2 minutes left: running low
            look()
            assert.is_false(ns.BuffMode.IsOn(), "running low isn't missing")
            wow.advance(120) -- and now it's gone, with no UNIT_AURA from the game
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("(Ann Vale is missing your Mark of the Wild)"))
        end)

        it("counts a member who joins already missing your buff, close by", function()
            joinCovered()
            look()
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock", "Dot-Fern" })
            wow.wearBuff("party1", MOTW, { source = "player" })
            wow.wearBuff("party2", MOTW, { source = "player" })
            wow.fire("GROUP_ROSTER_UPDATE")
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("(Dot Fern is missing your Mark of the Wild)"))
        end)

        it("counts you as a member: your own buff fading turns it on (#198)", function()
            boot({ buffSelf = true })
            joinCovered()
            wow.gainBuff({ sourceUnit = "player", name = "Mark of the Wild", spellId = MOTW })
            look()
            assert.is_false(ns.BuffMode.IsOn())
            wow.state.playerAuras = {}
            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = {} })
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("(you're missing your Mark of the Wild)"))
        end)

        it("a copy someone else put up counts as covered: another member's, or a stranger's", function()
            joinCovered()
            look()
            strip("party1")
            wow.wearBuff("party1", MOTW, { source = "party2" })
            strip("party2")
            wow.wearBuff("party2", MOTW, { source = false }) -- the game names no caster: a stranger
            look()
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("is switched on the Buff Back tab, on by default, and says on the mouse-over when it applies", function()
            assert.is_true(ns.db.buffBack.autoOnMissing)
            local box = ns.Options.widgets.auto.autoOnMissing
            assert.are.equal("when someone's missing my buffs", box.label:GetText())
            assert.are.equal(ns.Options.AUTO_MISSING_TIP, box.tooltip)
            assert.is_truthy(box.tooltip:find("40 yards", 1, true))
            assert.is_truthy(box.tooltip:find("not just running low", 1, true))
            box:SetChecked(false)
            wow.run(box, "OnClick")
            assert.is_false(ns.db.buffBack.autoOnMissing, "unticking it switches the trigger off")
            joinCovered()
            look()
            strip("party1")
            look()
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn())
        end)
    end)

    describe("turning off (white)", function()
        it("turns off once all members have your buffs", function()
            joinCovered()
            look()
            strip("party1")
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_not_nil(scroll(), "the button offers Ann her Mark")
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode off (everyone has your buffs)"))
            look()
            assert.is_false(ns.BuffMode.IsOn(), "and stays off: nobody is missing one")
        end)

        it("turns off at the next pull, and comes back when that fight ends if someone is still missing one", function()
            joinCovered()
            look()
            strip("party1")
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.enterCombat()
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_nil(ns.BuffMode.LentKey())
            look()
            assert.is_false(ns.BuffMode.IsOn(), "never in a fight")
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("keeps the timeout of buff mode a trigger turned on", function()
            joinCovered()
            look()
            strip("party1")
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.advance(5 * 60 + 1)
            assert.is_false(ns.BuffMode.IsOn())
            look()
            assert.is_false(ns.BuffMode.IsOn(), "Ann was missing it already: no new reason")
        end)

        it("stays off when you turn it off yourself, until someone else goes missing", function()
            joinCovered()
            look()
            strip("party1")
            look()
            slash("buffmode off")
            for _ = 1, 10 do look() end
            assert.is_false(ns.BuffMode.IsOn())
            strip("party2")
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("(Cid Rock is missing your Mark of the Wild)"))
        end)

        it("doesn't turn on after a login or reload with someone already missing one", function()
            wow.setGroup("party", { "Ann-Vale" })
            wow.fire("GROUP_ROSTER_UPDATE")
            boot()
            for _ = 1, 3 do look() end
            assert.is_false(ns.BuffMode.IsOn(), "buff mode is off after a login")
        end)
    end)

    describe("the debug log (white)", function()
        local function logged(fragment)
            local n = 0
            for _, line in ipairs(ns.db.diagLog) do
                if line:find(fragment, 1, true) then n = n + 1 end
            end
            return n
        end

        before_each(function()
            ns.db.debug = true
            ns.db.diagLog = {}
        end)

        it("says why it turned on and off: a fade, then everyone covered", function()
            joinCovered()
            look()
            strip("party1")
            look()
            assert.are.equal(1, logged("auto turned on: Ann Vale is missing your Mark of the Wild"))
            scroll()
            assert.are.equal(1, logged("auto turned off: everyone has your buffs"))
        end)

        it("says why it turned on and off: a fight's end, then the next pull", function()
            joinCovered()
            look()
            wow.enterCombat()
            strip("party1")
            wow.leaveCombat()
            assert.are.equal(1, logged("auto turned on: the fight ended and Ann Vale is missing your Mark of the Wild"))
            wow.enterCombat()
            assert.are.equal(1, logged("auto turned off: the fight started"))
        end)

        it("logs decisions, not looks: a hundred looks with nothing new add no lines (#268)", function()
            joinCovered()
            look()
            strip("party1")
            look()
            slash("buffmode off")
            local lines = #ns.db.diagLog
            for _ = 1, 100 do look() end
            assert.are.equal(lines, #ns.db.diagLog)
        end)
    end)

    describe("what it can't see, and where it never turns on (black)", function()
        -- Ann is missing your Mark in the given way; Cid is covered. A fight
        -- ends, the strongest reason to turn on, and time passes.
        local function neverTurnsOn(setup)
            boot()
            joinCovered()
            look()
            strip("party1")
            setup(wow.state.units.party1)
            wow.fire("GROUP_ROSTER_UPDATE")
            for _ = 1, 3 do look() end
            wow.enterCombat()
            wow.leaveCombat()
            look()
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end

        it("never for a member whose buffs can't be read", function()
            -- A buff of some kind, so there is something the game hides (with
            -- none at all, it says so plainly).
            neverTurnsOn(function(u)
                u.auras = { INTELLECT }
                u.secrets = { auras = true }
            end)
        end)

        it("never for a member whose connection can't be read, or who is offline", function()
            neverTurnsOn(function(u) u.secrets = { offline = true } end)
            neverTurnsOn(function(u) u.offline = true end)
        end)

        it("never for a member whose name can't be read", function()
            neverTurnsOn(function(u) u.secrets = { name = true } end)
        end)

        it("never for a member out of range, or whose range the game won't give or gives as a secret", function()
            neverTurnsOn(function(u) u.outOfRange = true end)
            neverTurnsOn(function(u) u.rangeUnknown = true end)
            neverTurnsOn(function(u) u.secrets = { range = true } end)
        end)

        it("never for a member who is dead, or out of sight", function()
            neverTurnsOn(function(u) u.dead = true end)
            neverTurnsOn(function(u) u.hidden = true end)
        end)

        it("never for a member your rules leave out of the buff", function()
            neverTurnsOn(function(u)
                u.class = "WARRIOR"
                ns.db.buffBack.whoGets.motw = { rule = "classes", classes = { MAGE = true } }
            end)
        end)

        it("arenas and battlegrounds still never turn it on", function()
            for _, kind in ipairs({ "arena", "pvp" }) do
                neverTurnsOn(function()
                    wow.state.inInstance, wow.state.instanceType = true, kind
                end)
            end
        end)

        it("never where the game won't say what kind of place you're in", function()
            neverTurnsOn(function() wow.state.inInstanceSecret = true end)
        end)

        it("never in a fight: a buff fading in one waits for it to end", function()
            joinCovered()
            look()
            wow.enterCombat()
            strip("party1")
            for _ = 1, 5 do look() end
            assert.is_false(ns.BuffMode.IsOn())
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("a damaged switch reads as off, and is repaired at the next load", function()
            ns.db.buffBack.autoOnMissing = "yes"
            joinCovered()
            look()
            strip("party1")
            look()
            assert.is_false(ns.BuffMode.IsOn())
            boot()
            ns = wow.boot({ db = { buffBack = { autoOnMissing = {} } }, autoBuffMode = true })
            assert.is_true(ns.db.buffBack.autoOnMissing, "repaired to the default")
        end)

        it("leaves your top-up cast counted as just given while it's still running low", function()
            joinCovered(1800)
            ns.db.buffBack.autoOnMissing = true
            wow.advance(1800 - 120)
            slash("buffmode on")
            local cast = wow.pressKey("MOUSEWHEELUP") or wow.casts[#wow.casts]
            assert.is_not_nil(cast, "Ann's running-low Mark is topped up")
            local target = cast.target
            -- The game hasn't shown the new one yet; a look at the group happens.
            look()
            wow.pressKey("MOUSEWHEELUP")
            local again = wow.casts[#wow.casts]
            assert.is_true(again == cast or again.target ~= target, "not offered to the same member again at once")
        end)
    end)

    describe("chaos (red tests)", function()
        -- Whether the client's own state shows a member close by, online,
        -- readable and alive, without any Mark: a reason this trigger may
        -- turn buff mode on. Worked out from the client, never the addon.
        local function someoneMissing()
            for i = 1, 4 do
                local u = wow.state.units["party" .. i]
                local secrets = u and u.secrets or {}
                if u and not u.offline and not u.dead and not u.outOfRange and not u.rangeUnknown
                    and not u.hidden and not secrets.name and not secrets.offline and not secrets.range then
                    -- Hidden buffs can't be read, but a member wearing none
                    -- at all is shown plainly as wearing none.
                    local wearing, worn = false, 0
                    for j, id in ipairs(u.auras or {}) do
                        if not wow.auraExpired(u, j) then
                            worn = worn + 1
                            if MARKS[id] then wearing = true end
                        end
                    end
                    if not wearing and not (secrets.auras and worn > 0) then return true end
                end
            end
            return false
        end

        local function storm(seed)
            random.seed(seed)
            boot()
            local turnedOn = 0
            local everyone = { "Ann-Vale", "Cid-Rock", "Dot-Fern", "Eve-Moss" }
            local actions = {
                function()
                    local names = {}
                    for _, n in ipairs(everyone) do if random.random() < 0.7 then names[#names + 1] = n end end
                    wow.setGroup(#names > 0 and "party" or nil, names)
                    wow.fire("GROUP_ROSTER_UPDATE")
                end,
                function()
                    local token = "party" .. random.random(1, 4)
                    if wow.state.units[token] then
                        wow.wearBuff(token, random.random() < 0.5 and MOTW or MOTW_1, {
                            source = ({ "player", "party1", false })[random.random(3)],
                            duration = random.random(5, 120) })
                    end
                end,
                function()
                    local u = wow.state.units["party" .. random.random(1, 4)]
                    if u then u.auras = {} end
                end,
                function()
                    local token = "party" .. random.random(1, 4)
                    if wow.state.units[token] then wow.wearBuff(token, INTELLECT, { source = false }) end
                end,
                function()
                    local u = wow.state.units["party" .. random.random(1, 4)]
                    if not u then return end
                    local field = ({ "offline", "dead", "outOfRange", "rangeUnknown", "hidden" })[random.random(5)]
                    u[field] = not u[field] or nil
                end,
                function()
                    local u = wow.state.units["party" .. random.random(1, 4)]
                    if not u then return end
                    local field = ({ "auras", "offline", "name", "range" })[random.random(4)]
                    u.secrets = u.secrets or {}
                    u.secrets[field] = not u.secrets[field] or nil
                    if next(u.secrets) == nil then u.secrets = nil end
                end,
                function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                function()
                    local kind = ({ "none", "party", "arena", "pvp" })[random.random(4)]
                    wow.state.inInstance = kind ~= "none" or nil
                    wow.state.instanceType = kind ~= "none" and kind or nil
                end,
                function() wow.state.inInstanceSecret = random.random() < 0.2 or nil end,
                function() wow.advance(random.random() * 12) end,
                function() slash("buffmode off") end,
                function() ns.db.buffBack.autoOnMissing = ({ true, true, false, "yes", {}, 1 })[random.random(6)] end,
                function() ns.db.buffBack.topUpMinutes = ({ 0, 1, 5, -3, "x", 1 / 0 })[random.random(6)] end,
            }
            for step = 1, 400 do
                local where = ("seed %d, step %d"):format(seed, step)
                local wasOn = ns.BuffMode.IsOn()
                local printed = #wow.printed
                actions[random.random(#actions)]()
                local why
                for i = printed + 1, #wow.printed do
                    why = why or wow.printed[i]:match("buff mode on %((.-)%)")
                end
                if not wasOn and ns.BuffMode.IsAuto() and why and why:find("missing your", 1, true) then
                    turnedOn = turnedOn + 1
                    assert.is_false(wow.state.inCombat == true, where .. ": turned on in a fight")
                    local kind = wow.state.inInstance and (wow.state.instanceType or "party") or "none"
                    assert.is_true(kind == "none" or kind == "party", where .. ": turned on in " .. kind)
                    assert.is_nil(wow.state.inInstanceSecret, where .. ": turned on where it can't tell")
                    assert.is_true(ns.db.buffBack.autoOnMissing == true, where .. ": turned on while switched off")
                    assert.is_true(someoneMissing(), where .. ": turned on with nobody missing a buff")
                end
                assert.are.same({}, wow.casts, where .. ": something cast without a press")
            end
            assert.are.same({}, wow.errors, "seed " .. seed)
            -- It heals: with the switch repaired and Ann plainly missing her
            -- Mark, the end of a fight turns it on.
            ns.db.buffBack.autoOnMissing = true
            ns.db.buffBack.topUpMinutes = 5
            wow.state.inInstance, wow.state.instanceType, wow.state.inInstanceSecret = nil, nil, nil
            if wow.state.inCombat then wow.leaveCombat() end
            slash("buffmode off")
            wow.setGroup("party", { "Ann-Vale" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto(), "seed " .. seed .. ": works again after the storm")
            return turnedOn
        end

        it("never turns on in a fight, an arena or battleground, or with nobody plainly missing a buff; never casts", function()
            local turnedOn = 0
            for _, seed in ipairs({ 7, 272, 1312, 4096, 2026 }) do turnedOn = turnedOn + storm(seed) end
            assert.is_true(turnedOn > 10, "turned on by a missing buff: " .. turnedOn)
        end)
    end)
end)
