-- Spec: #377
-- A loading screen whose IsInGroup() can't be read (#322): buff mode goes by
-- the group as last read (#373), so entering a dungeon or raid with your
-- group starts the round (#256) and the trigger as when it can be read. With
-- the group not known either (a reload that couldn't read it, #370), nothing
-- for the group starts or ends.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1 = 9885, 1126
local DEADMINES, MOLTEN_CORE = 36, 409

local function printedHas(fragment)
    for _, line in ipairs(wow.printed) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

describe("A loading screen with IsInGroup() unreadable (#377)", function()
    local ns, realIsInGroup

    -- The ways IsInGroup() can't be read.
    local UNREADABLE = {
        ["a secret true"] = function() return wow.secret(true) end,
        ["a secret false"] = function() return wow.secret(false) end,
        nothing = function() return nil end,
        ["an error"] = function() error("blocked") end,
        ["a number"] = function() return 1 end,
    }

    -- A druid who knows Mark of the Wild, with the turn-on triggers on.
    local function boot()
        ns = wow.boot({ autoBuffMode = true, before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
        end })
        realIsInGroup = _G.IsInGroup
    end

    -- Your group, formed out in the world with everyone elsewhere, so joining
    -- turns nothing on (they aren't in sight).
    local function groupElsewhere(kind, names)
        wow.setGroup(kind, names)
        for token in pairs(wow.state.units) do
            if (token:find("^party%d") or token:find("^raid%d")) and wow.state.units[token] ~= wow.state.units.player then
                wow.zoneOut(token)
            end
        end
        ns.db.buffBack.autoOnJoin = false
        wow.fire("GROUP_ROSTER_UPDATE")
        ns.db.buffBack.autoOnJoin = true
    end

    local GROUPS = {
        dungeon = { kind = "party", names = { "Ann-Vale", "Cid-Rock" },
            enter = function() wow.enterDungeon(DEADMINES, "The Deadmines") end },
        raid = { kind = "raid", names = { "Ann-Vale", "Cid-Rock", "Dot-Fern" },
            enter = function() wow.enterRaid(MOLTEN_CORE, "Molten Core") end },
    }

    it("readable, entering and leaving a dungeon or raid with your group behave as before (white)", function()
        for what, g in pairs(GROUPS) do
            boot()
            groupElsewhere(g.kind, g.names)
            assert.is_false(ns.BuffMode.IsOn(), what)
            g.enter()
            assert.is_true(ns.BuffMode.IsAuto(), what)
            assert.is_true(ns.GroupBuffs.InRound(), what .. ": the round started")
            assert.is_true(printedHas("(you're in a " .. what .. " with your group)"), what)
            wow.leaveDungeon()
            assert.is_false(ns.GroupBuffs.InRound(), what .. ": the round ended")
            assert.are.same({}, wow.errors, what)
        end
    end)

    it("unreadable at the loading screen, entering with your group starts the round and the trigger as when readable (black)", function()
        for what, g in pairs(GROUPS) do
            for answer, unreadable in pairs(UNREADABLE) do
                local where = what .. ", " .. answer
                boot()
                groupElsewhere(g.kind, g.names)
                _G.IsInGroup = unreadable
                g.enter()
                assert.is_true(ns.BuffMode.IsAuto(), where)
                assert.is_true(ns.GroupBuffs.InRound(), where .. ": the round started")
                assert.is_true(printedHas("(you're in a " .. what .. " with your group)"), where)
                -- Out again, still unreadable: the round ends, as when readable.
                wow.leaveDungeon()
                assert.is_false(ns.GroupBuffs.InRound(), where .. ": the round ended")
                _G.IsInGroup = realIsInGroup
                assert.are.same({}, wow.errors, where)
            end
        end
    end)

    it("readable at the loading screen, its answer counts over a roster update that couldn't read it (black)", function()
        boot()
        -- Joined while the roster update couldn't read IsInGroup().
        wow.state.inGroupUnreadable = true
        groupElsewhere("party", { "Ann-Vale", "Cid-Rock" })
        wow.state.inGroupUnreadable = nil
        wow.enterDungeon(DEADMINES, "The Deadmines")
        assert.is_true(ns.GroupBuffs.InRound())
        assert.is_true(ns.BuffMode.IsAuto())
        assert.are.same({}, wow.errors)
    end)

    it("readable at the loading screen, \"not in a group\" counts over the group as last read (white)", function()
        boot()
        groupElsewhere("party", { "Ann-Vale", "Cid-Rock" })
        -- Left; the roster update comes after the loading screen.
        wow.setGroup(nil, {})
        wow.enterDungeon(DEADMINES, "The Deadmines")
        assert.is_false(ns.GroupBuffs.InRound())
        assert.is_false(ns.BuffMode.IsOn())
        wow.fire("GROUP_ROSTER_UPDATE")
        assert.is_false(ns.GroupBuffs.InRound())
        assert.are.same({}, wow.errors)
    end)

    it("the client's own switch (state.inGroupUnreadable) starts the round too (black)", function()
        boot()
        groupElsewhere("party", { "Ann-Vale", "Cid-Rock" })
        wow.state.inGroupUnreadable = true
        wow.enterDungeon(DEADMINES, "The Deadmines")
        assert.is_true(ns.GroupBuffs.InRound())
        assert.is_true(ns.BuffMode.IsAuto())
        assert.are.same({}, wow.errors)
    end)

    it("out of a group as last read, an unreadable loading screen starts nothing (black)", function()
        for answer, unreadable in pairs(UNREADABLE) do
            boot()
            wow.setGroup("party", { "Ann-Vale" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.setGroup(nil, {})
            wow.fire("GROUP_ROSTER_UPDATE") -- left: read as no group
            _G.IsInGroup = unreadable
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_false(ns.GroupBuffs.InRound(), answer)
            assert.is_false(printedHas("with your group)"), answer)
            _G.IsInGroup = realIsInGroup
            assert.are.same({}, wow.errors, answer)
        end
    end)

    it("with the group not known since a reload, nothing starts or ends (black)", function()
        for answer, unreadable in pairs(UNREADABLE) do
            -- In: a round already running is left alone.
            boot()
            groupElsewhere("party", { "Ann-Vale", "Cid-Rock" })
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_true(ns.GroupBuffs.InRound(), answer)
            -- The reload reads a secret (other modules read IsInGroup() at a
            -- reload too); the loading screens after it, each unreadable way.
            wow.state.inGroupUnreadable = true
            wow.reloadInPlace(false)
            wow.state.inGroupUnreadable = nil
            _G.IsInGroup = unreadable
            ns.GroupBuffs.StartRound() -- a round, though the reload ended its own
            wow.leaveDungeon()
            assert.is_true(ns.GroupBuffs.InRound(), answer .. ": not ended")
            -- Not in one yet: none is started.
            ns.GroupBuffs.EndRound()
            ns.BuffMode.Set(false)
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_false(ns.GroupBuffs.InRound(), answer .. ": not started")
            assert.is_false(ns.BuffMode.IsOn(), answer .. ": not turned on")
            _G.IsInGroup = realIsInGroup
            assert.are.same({}, wow.errors, answer)
        end
    end)

    -- Loading screens, regroups, roster updates, reloads and IsInGroup()
    -- answers that can't be read, at random. The model is the client's
    -- state and when it was readable: the group as the last readable answer
    -- gave it (a roster update or a reload; nil after a reload that couldn't
    -- read it). A round starts only where that model says you're in a group.
    -- Time doesn't pass, so the looks (Watch) read nothing in between.
    it("a storm of loading screens, regroups and unreadable answers never errors, nor starts a round out of a group (red)", function()
        local started, withUnreadable = 0, 0
        for _, seed in ipairs({ 3, 377, 2026, 9001 }) do
            random.seed(seed)
            boot()
            local unreadable = false
            _G.IsInGroup = function(...)
                if unreadable then return wow.secret(true) end
                return realIsInGroup(...)
            end
            local lastRead = false
            local function inGroupNow() return wow.state.groupType ~= nil end
            local mayStart -- set by each action: whether it may start a round
            local actions = {
                function()
                    local r = random.random()
                    if r < 0.3 then
                        wow.setGroup(nil, {})
                    else
                        wow.setGroup(r < 0.65 and "party" or "raid", { "Ann-Vale", "Cid-Rock" })
                    end
                    -- The game sends a roster update for every change.
                    wow.fire("GROUP_ROSTER_UPDATE")
                    if not unreadable then lastRead = inGroupNow() end
                    mayStart = not unreadable and inGroupNow()
                end,
                function()
                    wow.fire("GROUP_ROSTER_UPDATE")
                    if not unreadable then lastRead = inGroupNow() end
                    mayStart = not unreadable and inGroupNow()
                end,
                function() unreadable = not unreadable end,
                -- The group changes, and its roster update comes only after
                -- a loading screen.
                function()
                    if random.random() < 0.5 then
                        wow.setGroup(nil, {})
                    else
                        wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
                    end
                    if unreadable then mayStart = lastRead == true else mayStart = inGroupNow() end
                    wow.enterDungeon(DEADMINES, "The Deadmines")
                    wow.fire("GROUP_ROSTER_UPDATE")
                    if not unreadable then
                        lastRead = inGroupNow()
                        mayStart = mayStart or inGroupNow()
                    end
                end,
                function()
                    if unreadable then mayStart = lastRead == true else mayStart = inGroupNow() end
                    if random.random() < 0.5 then
                        wow.enterDungeon(DEADMINES, "The Deadmines")
                    else
                        wow.enterRaid(MOLTEN_CORE, "Molten Core")
                    end
                end,
                function() wow.leaveDungeon() end,
                function()
                    wow.reloadInPlace(false)
                    if unreadable then lastRead = nil else lastRead = inGroupNow() end
                end,
            }
            for step = 1, 300 do
                local where = ("seed %d, step %d"):format(seed, step)
                local before = ns.GroupBuffs.InRound()
                mayStart = false
                actions[random.random(#actions)]()
                if ns.GroupBuffs.InRound() and not before then
                    assert.is_true(mayStart, where .. ": a round started out of a group as last read")
                    started = started + 1
                    if unreadable then withUnreadable = withUnreadable + 1 end
                end
                assert.are.same({}, wow.errors, where)
            end
            _G.IsInGroup = realIsInGroup
        end
        assert.is_true(started > 10, "rounds started: " .. started)
        assert.is_true(withUnreadable > 3, "rounds started at an unreadable loading screen: " .. withUnreadable)
    end)
end)
