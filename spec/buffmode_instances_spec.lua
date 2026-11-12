-- Spec: #256
-- Buff mode in a dungeon or raid: it turns on there with your group, and
-- waits until every member is in and has your buffs, or the first pull.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1 = 9885, 1126
local DEADMINES = 36

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

local function printedHas(fragment)
    for _, line in ipairs(wow.printed) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

describe("Buff mode in a dungeon or raid (#256)", function()
    local ns

    -- A druid who knows Mark of the Wild (one buff keeps the counting simple),
    -- with the turn-on triggers on as shipped.
    local function boot(db)
        ns = wow.boot({ db = db, autoBuffMode = true, before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
        end })
    end

    local function group(kind, names)
        wow.setGroup(kind or "party", names or { "Ann-Vale", "Cid-Rock" })
        wow.fire("GROUP_ROSTER_UPDATE")
    end

    -- Scroll once and let the buff show on whoever it reached.
    local function scroll()
        local before = #wow.casts
        wow.pressKey("MOUSEWHEELUP")
        local cast = wow.casts[before + 1]
        if cast then
            for token, u in pairs(wow.state.units) do
                if u.id == cast.target and token ~= "target" then
                    u.auras = u.auras or {}
                    u.auras[#u.auras + 1] = cast.id
                end
            end
        end
        return cast
    end

    -- Scroll until nothing is cast; how many casts that took.
    local function scrollAll()
        local n = 0
        while scroll() do n = n + 1 end
        return n
    end

    -- Your group, formed out in the world with everyone elsewhere, so joining
    -- turns nothing on (they aren't in sight).
    local function groupElsewhere(names, kind)
        wow.setGroup(kind or "party", names or { "Ann-Vale", "Cid-Rock" })
        for token in pairs(wow.state.units) do
            if token:find("^party%d") or token:find("^raid%d") then wow.zoneOut(token) end
        end
        ns.db.buffBack.autoOnJoin = false
        wow.fire("GROUP_ROSTER_UPDATE")
        ns.db.buffBack.autoOnJoin = true
    end

    -- Mark of the Wild on token, put up by `by` (a unit token; false: the game
    -- names no caster). The other member's Mark is a group member's buff,
    -- which buff mode leaves alone (#256).
    local function marked(token, by)
        wow.state.units[token].auras, wow.state.units[token].auraSources = { MOTW }, { by }
    end
    local OTHER = { party1 = "party2", party2 = "party1" }

    before_each(function() boot() end)

    describe("turning on (white)", function()
        it("turns on when you enter a dungeon with your group, saying why", function()
            groupElsewhere()
            assert.is_false(ns.BuffMode.IsOn())
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("buff mode on (you're in a dungeon with your group)"))
        end)

        it("turns on when you enter a raid with your raid group", function()
            groupElsewhere({ "Ann-Vale", "Cid-Rock", "Dot-Fern" }, "raid")
            wow.enterRaid(409, "Molten Core")
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("(you're in a raid with your group)"))
        end)

        it("turns on when you join a group while inside a dungeon", function()
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_false(ns.BuffMode.IsOn(), "alone: no group to buff")
            group()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("(you're in a dungeon with your group)"))
        end)

        it("turns on again each time you enter with your group", function()
            groupElsewhere()
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.enterCombat()
            assert.is_false(ns.BuffMode.IsOn(), "the first pull ends it")
            wow.leaveCombat()
            wow.leaveDungeon()
            wow.enterDungeon(DEADMINES, "The Deadmines") -- the run back after a wipe
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("doesn't turn on entering a dungeon alone, or an arena or battleground", function()
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_false(ns.BuffMode.IsOn())
            wow.leaveDungeon()
            groupElsewhere()
            wow.enterDungeon(nil, nil, "arena")
            assert.is_false(ns.BuffMode.IsOn(), "an arena isn't a dungeon or raid")
            wow.leaveDungeon()
            wow.enterDungeon(nil, nil, "pvp")
            assert.is_false(ns.BuffMode.IsOn(), "nor is a battleground")
        end)

        it("doesn't turn on with its switch off", function()
            groupElsewhere()
            ns.db.buffBack.autoOnJoin = false
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("doesn't lend a key when everyone is in and wears a group member's buff", function()
            groupElsewhere()
            for _, token in ipairs({ "party1", "party2" }) do
                wow.zoneIn(token)
                marked(token, OTHER[token])
            end
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("turns on even when everyone is in with your earlier buffs: each gets yours once more", function()
            groupElsewhere()
            for _, token in ipairs({ "party1", "party2" }) do
                wow.zoneIn(token)
                wow.wearBuff(token, MOTW, { source = "player" })
            end
            wow.advance(10 * 60) -- put up 10 minutes before you enter: out of step (#256, the owner)
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_true(ns.BuffMode.IsAuto())
            assert.are.equal(2, scrollAll())
            assert.is_false(ns.BuffMode.IsOn(), "everyone has this round's buff")
        end)

        it("turns on even when everyone inside has your buffs, while someone is still outside", function()
            groupElsewhere()
            wow.zoneIn("party1")
            wow.state.units.party1.auras = { MOTW }
            wow.state.units.party2.auras = { MOTW } -- buffed, but not in yet
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("waits for a fight to end when you enter in one", function()
            groupElsewhere()
            wow.enterCombat()
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_false(ns.BuffMode.IsOn())
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.advance(60 * 60)
            assert.is_true(ns.BuffMode.IsAuto(), "it waits for everyone: no timeout inside")
        end)

        it("in a fight, the dungeon trigger outranks a trigger that fired before it (seed 9)", function()
            groupElsewhere()
            wow.enterCombat()
            wow.zoneIn("party1")
            wow.fire("GROUP_ROSTER_UPDATE") -- someone close, in the open world: waits for the fight
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("(you're in a dungeon with your group)"))
            scrollAll()
            assert.is_true(ns.BuffMode.IsAuto(), "Cid is still outside")
        end)

        it("a login or reload inside isn't entering: buff mode stays off", function()
            groupElsewhere()
            wow.state.inInstance, wow.state.instanceType = true, "party"
            wow.reloadInPlace()
            assert.is_false(ns.BuffMode.IsOn())
        end)
    end)

    describe("joining a group in the open world: only when someone is close by (white)", function()
        it("turns on when another member is within the group range check", function()
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            wow.zoneOut("party2")
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.BuffMode.IsAuto(), "Ann is close")
            assert.is_true(printedHas("(you joined a group)"))
        end)

        it("doesn't turn on when nobody is close by", function()
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            wow.state.units.party1.outOfRange = true
            wow.zoneOut("party2")
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("turns on when someone comes close on a roster change within 2 minutes of joining", function()
            groupElsewhere()
            wow.advance(119)
            wow.zoneIn("party1")
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("stops looking 2 minutes after you joined", function()
            groupElsewhere()
            wow.advance(121)
            wow.zoneIn("party1")
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("turns on once in that window: turned off, it doesn't come back on a roster change", function()
            groupElsewhere()
            wow.zoneIn("party1")
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.BuffMode.IsAuto())
            slash("buffmode off")
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("inside, after the first pull, a roster change in those 2 minutes doesn't turn it on", function()
            groupElsewhere()
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn())
            wow.zoneIn("party1")
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(ns.BuffMode.IsOn(), "the open-world rule doesn't apply inside")
        end)

        -- Cid is out of range and missing your buffs, so there is something
        -- to do: only the range read decides whether Ann counts as close.
        local function joinWithAnn(setUp)
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            wow.state.units.party2.outOfRange = true
            setUp(wow.state.units.party1)
            wow.fire("GROUP_ROSTER_UPDATE")
        end

        it("a range the game won't check isn't close", function()
            joinWithAnn(function(ann) ann.rangeUnknown = true end)
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end)

        it("a range the game gives as a secret isn't close (her name still readable)", function()
            joinWithAnn(function(ann) ann.secrets = { range = true } end)
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end)

        it("the same group with Ann's range readable does turn on (the two tests above reach the range)", function()
            joinWithAnn(function() end)
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("in a raid joined out in the world, your own raid slot isn't someone close by", function()
            wow.setGroup("raid", { "Ann-Vale", "Cid-Rock" })
            -- The game gives you a raid slot too (#255): the same unit as "player".
            wow.addUnit("raid3", wow.state.units.player)
            assert.is_true(UnitIsUnit("raid3", "player"))
            wow.state.units.raid1.outOfRange = true
            wow.state.units.raid2.outOfRange = true
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(ns.BuffMode.IsOn())
            wow.state.units.raid1.outOfRange = nil
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.BuffMode.IsAuto(), "Ann comes close")
        end)
    end)

    describe("staying on until everyone is in and buffed (white)", function()
        it("stays on until the last member comes in and has your buffs", function()
            groupElsewhere()
            wow.zoneIn("party1")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal(1, scrollAll(), "Ann, the one inside")
            assert.is_true(ns.BuffMode.IsAuto(), "Cid isn't in yet")
            wow.advance(30 * 60)
            assert.is_true(ns.BuffMode.IsAuto(), "the timeout doesn't apply inside")
            wow.zoneIn("party2")
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.BuffMode.IsAuto(), "Cid is in, without your buffs")
            assert.are.equal(1, scrollAll())
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode off (everyone is here and has your buffs)."))
        end)

        it("stays on for a member who comes in with a group member's buff only until they're in", function()
            groupElsewhere()
            marked("party2", "party1")
            wow.zoneIn("party1")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            scrollAll()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.zoneIn("party2") -- no event: buff mode's own recheck sees it
            wow.advance(ns.BuffButton.RECHECK_SECONDS)
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("an offline member isn't in: buff mode stays on", function()
            groupElsewhere()
            wow.zoneIn("party1")
            wow.zoneIn("party2")
            wow.state.units.party2.offline = true
            wow.enterDungeon(DEADMINES, "The Deadmines")
            scrollAll()
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("in a raid, waits for every raid member", function()
            groupElsewhere({ "Ann-Vale", "Cid-Rock", "Dot-Fern" }, "raid")
            -- The game gives you a raid slot too (#255): the same unit as "player".
            wow.addUnit("raid4", wow.state.units.player)
            assert.is_true(UnitIsUnit("raid4", "player"))
            wow.zoneIn("raid1")
            wow.zoneIn("raid2")
            wow.enterRaid(409, "Molten Core")
            scrollAll()
            assert.is_true(ns.BuffMode.IsAuto(), "Dot is still outside")
            wow.zoneIn("raid3")
            wow.fire("GROUP_ROSTER_UPDATE")
            scrollAll()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("the first pull still ends it, with someone still outside", function()
            groupElsewhere()
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_true(ns.BuffMode.IsAuto())
            wow.enterCombat()
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode off (the fight started)."))
        end)

        it("with \"at the first pull\" off, the pull ends the wait: the timeout runs from then", function()
            groupElsewhere()
            ns.db.buffBack.autoOffPull = false
            wow.zoneIn("party1") -- in, and not buffed yet (no press)
            wow.state.units.party2.offline = true -- dropped at the entrance: never in
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.advance(20 * 60)
            assert.is_true(ns.BuffMode.IsAuto(), "waiting: no timeout before the pull")
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto(), "the pull doesn't end it with its switch off")
            wow.advance(5 * 60 - 1)
            assert.is_true(ns.BuffMode.IsAuto())
            wow.advance(1)
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode off (5 minutes passed)."))
        end)

        it("after the first pull (its switch off), \"everyone has your buffs\" no longer waits for someone outside", function()
            groupElsewhere()
            ns.db.buffBack.autoOffPull = false
            wow.zoneIn("party1")
            wow.state.units.party2.offline = true
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.enterCombat()
            wow.leaveCombat()
            assert.are.equal(1, scrollAll())
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode off (everyone has your buffs)."))
        end)

        it("its switch says on the mouse-over when it applies", function()
            local box = ns.Options.widgets.auto.autoOnJoin
            assert.are.equal("with my group", box.label:GetText())
            assert.are.equal(ns.Options.AUTO_JOIN_TIP, box.tooltip)
            assert.is_truthy(box.tooltip:find("dungeon or raid", 1, true))
            assert.is_truthy(box.tooltip:find("40 yards", 1, true))
        end)

        it("leaving the dungeon starts the timeout from then", function()
            groupElsewhere()
            wow.zoneIn("party1") -- with you, and not buffed yet
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.advance(20 * 60)
            wow.leaveDungeon()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.advance(5 * 60 - 1)
            assert.is_true(ns.BuffMode.IsAuto())
            wow.advance(1)
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode off (5 minutes passed)."))
        end)

        it("a trigger's buff mode from outside waits for everyone once you enter", function()
            group() -- everyone close: the join trigger turns it on, with its timeout
            assert.is_true(ns.BuffMode.IsAuto())
            wow.zoneOut("party2")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.advance(30 * 60)
            assert.is_true(ns.BuffMode.IsAuto(), "no timeout inside")
        end)

        it("never turns off buff mode you turned on yourself", function()
            groupElsewhere()
            slash("buffmode on")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_true(ns.BuffMode.IsOn())
            assert.is_false(ns.BuffMode.IsAuto())
            for _, token in ipairs({ "party1", "party2" }) do wow.zoneIn(token) end
            scrollAll()
            assert.is_true(ns.BuffMode.IsOn())
        end)

        it("with \"when everyone has my buffs\" off, stays on until the first pull", function()
            groupElsewhere()
            ns.db.buffBack.autoOffDone = false
            wow.enterDungeon(DEADMINES, "The Deadmines")
            for _, token in ipairs({ "party1", "party2" }) do wow.zoneIn(token) end
            scrollAll()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.enterCombat()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("ends when you leave the group inside", function()
            groupElsewhere()
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.setGroup(nil, {})
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(ns.BuffButton.RECHECK_SECONDS)
            assert.is_false(ns.BuffMode.IsOn())
        end)
    end)

    describe("what it can't read (black)", function()
        it("doesn't turn on when the game won't say whether you're in an instance", function()
            groupElsewhere()
            wow.state.inInstanceSecret = true
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end)

        local unreadable = {
            { "whether they're in sight", function(u) u.secrets = { hidden = true } end },
            { "whether they're online", function(u) u.secrets = { offline = true } end },
            { "their name", function(u) u.secrets = { name = true } end },
        }
        for _, case in ipairs(unreadable) do
            it("a member is never in when the game won't say " .. case[1], function()
                groupElsewhere()
                for _, token in ipairs({ "party1", "party2" }) do
                    wow.zoneIn(token)
                    marked(token, OTHER[token])
                end
                wow.enterDungeon(DEADMINES, "The Deadmines") -- nothing to do: stays off
                assert.is_false(ns.BuffMode.IsOn())
                wow.leaveDungeon()
                case[2](wow.state.units.party2)
                wow.enterDungeon(DEADMINES, "The Deadmines")
                assert.is_true(ns.BuffMode.IsAuto(), "not counted as in and buffed")
                wow.advance(60)
                wow.fire("GROUP_ROSTER_UPDATE")
                assert.is_true(ns.BuffMode.IsAuto())
                assert.are.same({}, wow.errors)
            end)
        end

        it("a member is never in while units read as secrets", function()
            groupElsewhere()
            for _, token in ipairs({ "party1", "party2" }) do
                wow.zoneIn(token)
                wow.state.units[token].auras = { MOTW }
            end
            wow.state.unitsRestricted = true
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(ns.BuffButton.RECHECK_SECONDS)
            -- Nobody can be read, so nobody is in: it turns on and stays on.
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_false(printedHas("everyone is here"))
            assert.are.same({}, wow.errors)
        end)

        it("nothing casts without a press", function()
            groupElsewhere()
            for _, token in ipairs({ "party1", "party2" }) do wow.zoneIn(token) end
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(120)
            assert.are.equal(0, #wow.casts)
        end)
    end)

    describe("chaos (red)", function()
        -- Whether the simulated client says every member is in (connected,
        -- shown, readable) and wears your Mark: worked out from its own state.
        local function everyoneInAndBuffed()
            for token, u in pairs(wow.state.units) do
                if token:find("^party%d") then
                    if u.offline or u.hidden or u.dead or u.secrets then return false end
                    local has = false
                    for _, id in ipairs(u.auras or {}) do has = has or id == MOTW end
                    if not has then return false end
                end
            end
            return true
        end

        local function storm(seed)
            random.seed(seed)
            boot()
            local everyone = { "Ann-Vale", "Cid-Rock", "Dot-Fern", "Eve-Moss" }
            groupElsewhere({ "Ann-Vale", "Cid-Rock" })
            -- A short timeout, so a storm can outlast it inside: a timeout
            -- that wrongly ran there would turn buff mode off early.
            ns.db.buffBack.autoOffMinutes = 1
            local pulled = false
            local reachedInside, endedDone, outlasted = 0, 0, 0
            local autoSince -- when buff mode last became the trigger's
            local function party()
                local out = {}
                for i = 1, 4 do if wow.state.units["party" .. i] then out[#out + 1] = "party" .. i end end
                return out
            end
            local function anyMember() local p = party() return p[random.random(math.max(#p, 1))] end
            local actions = {
                function() -- members join or leave (each new member starts elsewhere)
                    local names = {}
                    for _, n in ipairs(everyone) do if random.random() < 0.6 then names[#names + 1] = n end end
                    if #names == 0 then names = { everyone[1] } end
                    local was = {}
                    for _, t in ipairs(party()) do was[wow.state.units[t].id] = wow.state.units[t] end
                    wow.setGroup("party", names)
                    for _, t in ipairs(party()) do
                        local old = was[wow.state.units[t].id]
                        if old then wow.state.units[t] = old else wow.zoneOut(t) end
                    end
                    wow.fire("GROUP_ROSTER_UPDATE")
                end,
                function() local t = anyMember() if t then wow.zoneIn(t) wow.fire("GROUP_ROSTER_UPDATE") end end,
                function() local t = anyMember() if t then wow.zoneOut(t) wow.fire("GROUP_ROSTER_UPDATE") end end,
                function()
                    local t = anyMember()
                    if t then wow.state.units[t].offline = not wow.state.units[t].offline end
                    wow.fire("GROUP_ROSTER_UPDATE")
                end,
                function()
                    local t = anyMember()
                    if t then wow.state.units[t].secrets = random.random() < 0.5 and { hidden = true } or nil end
                end,
                function() local t = anyMember() if t then wow.state.units[t].auras = {} end end,
                scroll, scroll,
                function() wow.advance(random.random() * 120) end,
                function()
                    if wow.state.inInstance then
                        wow.leaveDungeon()
                    else
                        pulled = false
                        wow.enterDungeon(DEADMINES, "The Deadmines")
                    end
                end,
                function()
                    if wow.state.inCombat then wow.leaveCombat() else
                        wow.enterCombat()
                        if wow.state.inInstance then pulled = true end
                    end
                end,
            }
            for step = 1, 400 do
                local where = ("seed %d, step %d"):format(seed, step)
                local casts = #wow.casts
                local wasAutoInside = ns.BuffMode.IsAuto() and wow.state.inInstance and not wow.state.inCombat
                local action = actions[random.random(#actions)]
                local pressed = action == scroll
                action()
                if not pressed then assert.are.equal(casts, #wow.casts, where .. ": cast without a press") end
                if wasAutoInside and wow.state.inInstance then
                    reachedInside = reachedInside + 1
                    if not ns.BuffMode.IsOn() and not wow.state.inCombat and not pulled then
                        assert.is_true(everyoneInAndBuffed(), where .. ": turned off early, before the first pull")
                        endedDone = endedDone + 1
                    end
                end
                assert.are.same({}, wow.errors, where)
                if ns.BuffMode.IsAuto() then
                    autoSince = autoSince or wow.now
                    if wow.state.inInstance and not pulled and wow.now - autoSince > 60 then
                        outlasted = outlasted + 1
                    end
                else
                    autoSince = nil
                end
            end
            return reachedInside, endedDone, outlasted
        end

        it("members joining, leaving, zoning in and out and going offline never turn it off early", function()
            local inside, done, outlasted = 0, 0, 0
            for seed = 1, 12 do
                local a, b, c = storm(seed)
                inside, done, outlasted = inside + a, done + b, outlasted + c
            end
            -- The storms must reach the cases that count.
            assert.is_true(inside > 50, "waited inside " .. inside .. " times")
            assert.is_true(done > 0, "ended with everyone in and buffed " .. done .. " times")
            assert.is_true(outlasted > 0, "stayed on inside past the timeout " .. outlasted .. " times")
        end)
    end)
end)
