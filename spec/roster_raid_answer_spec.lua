-- Spec: #359
-- Buff mode's triggers read the group's slots the way its group look does
-- (#346): IsInRaid() is believed only when the slots agree. While it can't
-- be, the "someone is missing your buff" trigger forgets nobody it
-- remembers (#272), the death trigger forgets nobody it saw dead, and the
-- join trigger counts nobody close.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1 = 9885, 1126

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

local function printedHas(fragment)
    for _, line in ipairs(wow.printed) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

describe("Buff mode's triggers believe IsInRaid() only when the slots agree (#359)", function()
    local ns, realIsInRaid

    local function lie(answer) _G.IsInRaid = function() return answer end end
    -- Back to the client's own answer, readable again.
    local function truth()
        _G.IsInRaid = realIsInRaid
        wow.state.inRaidUnreadable = nil
    end

    -- A druid who knows Mark of the Wild, with one trigger on (the rest off).
    local function boot(trigger)
        local db = { buffBack = { autoOnJoin = false, autoOnDeath = false, autoOnBuffed = false,
            autoOnMissing = false } }
        db.buffBack[trigger] = true
        ns = wow.boot({ db = db, autoBuffMode = true, before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
        end })
        realIsInRaid = _G.IsInRaid
    end

    -- A raid in the open world: Ann, Bo and Eve in your subgroup 1, Cid and
    -- Dot in subgroup 2; you are raid6. The client gives your subgroup's
    -- other members as party1..3 (#337).
    local function raid()
        wow.setGroup("raid", { "Ann-Vale", "Bo-Fern", "Eve-Hill", "Cid-Rock", "Dot-Moss" })
        for i = 4, 5 do wow.state.units["raid" .. i].subgroup = 2 end
        wow.fire("GROUP_ROSTER_UPDATE")
    end

    local function party()
        wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
        wow.fire("GROUP_ROSTER_UPDATE")
    end

    local function coverAll()
        for token, u in pairs(wow.state.units) do
            if (token:find("^raid%d+$") or token:find("^party%d+$")) and u ~= wow.state.units.player then
                wow.wearBuff(token, MOTW, { source = "player" })
            end
        end
    end

    -- Long enough for the next look at the group.
    local function look() wow.advance(ns.BuffModeAuto.WATCH_SECONDS + 0.1) end

    describe("the missing-buff trigger (#272)", function()
        it("a real raid and a real party behave as before: a fade turns it on, and off by hand stays off (white)", function()
            for _, group in ipairs({ raid, party }) do
                boot("autoOnMissing")
                group()
                coverAll()
                look()
                local token = group == raid and "raid4" or "party2"
                wow.state.units[token].auras = {}
                look()
                assert.is_true(ns.BuffMode.IsAuto(), "Cid's Mark faded")
                assert.is_true(printedHas("(Cid Rock is missing your Mark of the Wild)"))
                slash("buffmode off")
                for _ = 1, 5 do look() end
                assert.is_false(ns.BuffMode.IsOn(), "Cid is still the same fade")
                assert.are.same({}, wow.errors)
            end
        end)

        -- One look with an answer that can't be believed, then the truth.
        local LIES = {
            ["IsInRaid() false in a raid"] = { group = raid, token = "raid4", wrong = function() lie(false) end },
            ["IsInRaid() unreadable in a raid"] = { group = raid, token = "raid4",
                wrong = function() wow.state.inRaidUnreadable = true end },
            ["IsInRaid() true in a party"] = { group = party, token = "party2", wrong = function() lie(true) end },
        }

        it("one look with IsInRaid() wrong forgets no remembered missing buff: off by hand stays off (black)", function()
            for what, case in pairs(LIES) do
                boot("autoOnMissing")
                case.group()
                coverAll()
                look()
                wow.state.units[case.token].auras = {}
                look()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": Cid's Mark faded")
                slash("buffmode off")
                case.wrong()
                look()
                assert.is_false(ns.BuffMode.IsOn(), what .. ": the wrong look")
                truth()
                for _ = 1, 3 do look() end
                assert.is_false(ns.BuffMode.IsOn(), what .. ": Cid was remembered, not new again")
                -- Someone else going missing still turns it on.
                wow.state.units[case.group == raid and "raid5" or "party1"].auras = {}
                look()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": a new fade still counts")
                assert.are.same({}, wow.errors, what)
            end
        end)
    end)

    describe("the death trigger", function()
        -- Cid joins dead; later, in a fight, Cid releases as a ghost (their
        -- health changes, still dead): not a new death.
        local function joinsDead(group, token, wrong)
            boot("autoOnDeath")
            group()
            wow.enterCombat()
            wow.leaveCombat()
            wow.state.units[token].dead = true
            wow.fire("GROUP_ROSTER_UPDATE")
            wrong()
            wow.fire("GROUP_ROSTER_UPDATE")
            truth()
            wow.enterCombat()
            wow.fire("UNIT_HEALTH", token)
            wow.leaveCombat()
        end

        it("a member who joins dead isn't a new death, in a real raid or party (white)", function()
            joinsDead(raid, "raid4", function() end)
            assert.is_false(ns.BuffMode.IsOn())
            joinsDead(party, "party2", function() end)
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end)

        it("a roster change read with IsInRaid() wrong forgets nobody seen dead (black)", function()
            joinsDead(raid, "raid4", function() lie(false) end)
            assert.is_false(ns.BuffMode.IsOn(), "false in a raid")
            joinsDead(raid, "raid4", function() wow.state.inRaidUnreadable = true end)
            assert.is_false(ns.BuffMode.IsOn(), "unreadable in a raid")
            joinsDead(party, "party2", function() lie(true) end)
            assert.is_false(ns.BuffMode.IsOn(), "true in a party")
            -- A real death afterwards still counts.
            wow.state.units.party1.dead = true
            wow.enterCombat()
            wow.fire("UNIT_HEALTH", "party1")
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto(), "Ann died: a new death")
            assert.is_true(printedHas("(someone in your group died)"))
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("the join trigger", function()
        it("joining with someone close turns it on in a real raid or party (white)", function()
            for _, group in ipairs({ raid, party }) do
                boot("autoOnJoin")
                group()
                assert.is_true(ns.BuffMode.IsAuto())
                assert.are.same({}, wow.errors)
            end
        end)

        it("while IsInRaid() can't be believed nobody counts as close; the next roster change looks again (black)", function()
            for what, wrong in pairs({ ["false in a raid"] = function() lie(false) end,
                ["unreadable in a raid"] = function() wow.state.inRaidUnreadable = true end }) do
                boot("autoOnJoin")
                wrong()
                raid()
                assert.is_false(ns.BuffMode.IsOn(), what)
                truth()
                wow.fire("GROUP_ROSTER_UPDATE")
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": a true answer at the next roster change")
                assert.are.same({}, wow.errors, what)
            end
        end)
    end)

    -- red: regroups, buffs worn and lost, range and sight changes, and an
    -- IsInRaid() that tells the truth, flips half its answers, always lies,
    -- or can't be read. The missing-buff trigger never turns buff mode on
    -- for a member the client's state shows was already missing at an
    -- earlier look the addon could see them at, and hasn't been seen wearing
    -- it or left since. Buff mode is turned off by hand after each turn-on,
    -- so each one is seen. Nobody presses.
    it("a storm with an IsInRaid() that sometimes lies never turns buff mode on for a buff already missing (red)", function()
        local POOL = { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed", "Gus-Lane", "Hal-Pine" }
        local MODES = { "truth", "flips", "inverted", "unreadable" }
        local total = { looks = 0, turnedOn = 0, raidAsParty = 0, partyAsRaid = 0 }
        local perSeed = {}
        for _, seed in ipairs({ 11, 359, 1024, 4242, 31337, 77777 }) do
            random.seed(seed)
            for _ = 1, 5 do random.random() end
            boot("autoOnMissing")
            local mode, lieState = "truth", seed
            local realRaid = _G.IsInRaid
            _G.IsInRaid = function()
                local answer = realRaid()
                if mode == "inverted" then return not answer end
                if mode ~= "flips" then return answer end
                lieState = (lieState * 48271) % 2147483647
                if lieState % 2 == 0 then return not answer end
                return answer
            end
            local reached = { raidAsParty = 0, partyAsRaid = 0 }

            -- The other members' slots (a raid's party1..4 are found on demand,
            -- never keys, so each member is seen once).
            local function others()
                local out = {}
                for token, u in pairs(wow.state.units) do
                    if (token:find("^party%d+$") or token:find("^raid%d+$")) and u ~= wow.state.units.player then
                        out[#out + 1] = token
                    end
                end
                table.sort(out)
                return out
            end
            local function wears(u)
                for i, id in ipairs(u.auras or {}) do
                    if (id == MOTW or id == MOTW_1) and not wow.auraExpired(u, i) then return true end
                end
                return false
            end
            local function inReach(u) return not (u.offline or u.dead or u.hidden or u.outOfRange) end

            -- The model, from the client's state: [id] = true for a member
            -- seen missing their Mark, in reach, at a look where the answer
            -- was true (so the addon saw them too), and not seen wearing it,
            -- in reach, or out of the group since.
            local known = {}
            local function note()
                local inGroup = {}
                for _, token in ipairs(others()) do
                    local u = wow.state.units[token]
                    inGroup[u.id] = true
                    if inReach(u) then
                        if wears(u) then
                            known[u.id] = nil
                        elseif mode == "truth" then
                            known[u.id] = true
                        end
                    end
                end
                for id in pairs(known) do
                    if not inGroup[id] then known[id] = nil end
                end
            end

            -- How often a look came while every answer lied and a member the
            -- model holds as missing was out of what the answer shows: in
            -- another subgroup of a raid read as a party, or in a party read
            -- as a raid.
            local function count()
                if mode ~= "inverted" then return end
                local mine = wow.state.units.player.subgroup or 1
                for _, token in ipairs(others()) do
                    local u = wow.state.units[token]
                    if known[u.id] then
                        if wow.state.groupType == "raid" and (u.subgroup or 1) ~= mine then
                            reached.raidAsParty = reached.raidAsParty + 1
                            total.raidAsParty = total.raidAsParty + 1
                            return
                        elseif wow.state.groupType == "party" then
                            reached.partyAsRaid = reached.partyAsRaid + 1
                            total.partyAsRaid = total.partyAsRaid + 1
                            return
                        end
                    end
                end
            end

            local function regroup()
                wow.setGroup(nil, {})
                wow.fire("GROUP_ROSTER_UPDATE")
                known = {}
                local names = {}
                for _, name in ipairs(POOL) do
                    if random.random(3) > 1 then names[#names + 1] = name end
                end
                if #names == 0 then return end
                if #names > 4 or random.random(2) == 1 then
                    wow.setGroup("raid", names)
                    wow.state.units.player.subgroup = random.random(2)
                    for i = 1, #names do wow.state.units["raid" .. i].subgroup = random.random(2) end
                else
                    wow.setGroup("party", names)
                end
                for _, token in ipairs(others()) do
                    if random.random(4) > 1 then wow.wearBuff(token, MOTW, { source = "player" }) end
                end
                wow.fire("GROUP_ROSTER_UPDATE")
            end
            local function anyOther()
                local list = others()
                return list[1] and wow.state.units[list[random.random(#list)]]
            end

            local ACTIONS = {
                regroup = regroup,
                wear = function()
                    local u = anyOther()
                    if u then wow.wearBuff(wow.tokenFor(u), MOTW, { source = "player" }) end
                end,
                strip = function()
                    local u = anyOther()
                    if u then u.auras = {} end
                end,
                range = function()
                    local u = anyOther()
                    if u then u.outOfRange = not u.outOfRange or nil end
                end,
                sight = function()
                    local u = anyOther()
                    if u then u.hidden = not u.hidden or nil end
                end,
                lie = function()
                    mode = MODES[random.random(#MODES)]
                    wow.state.inRaidUnreadable = mode == "unreadable" or nil
                end,
            }
            local NAMES = { "regroup", "wear", "strip", "strip", "range", "sight", "lie", "lie", "lie" }

            regroup()
            for step = 1, 150 do
                local action = NAMES[random.random(#NAMES)]
                ACTIONS[action]()
                local where = ("seed %d, step %d (%s, IsInRaid %s)"):format(seed, step, action, mode)
                count()
                local wasOn, printed = ns.BuffMode.IsOn(), #wow.printed
                local before = {}
                for id in pairs(known) do before[id] = true end
                look()
                total.looks = total.looks + 1
                local why
                for i = printed + 1, #wow.printed do
                    why = why or wow.printed[i]:match("buff mode on %((.-)%)")
                end
                if not wasOn and ns.BuffMode.IsAuto() then
                    total.turnedOn = total.turnedOn + 1
                    local named = why and why:match("^(.-) is missing your")
                    assert.is_not_nil(named, where .. ": turned on, but why? " .. tostring(why))
                    local id = named:gsub(" ", "-")
                    assert.is_nil(before[id], where .. ": turned on for " .. named
                        .. ", already missing at an earlier look")
                    slash("buffmode off")
                end
                note()
                assert.are.same({}, wow.errors, where)
                assert.are.equal(0, #wow.casts, where .. ": nothing casts without a press")
            end
            perSeed[#perSeed + 1] = ("seed %d: %d raid as party, %d party as raid")
                :format(seed, reached.raidAsParty, reached.partyAsRaid)
        end
        local bySeed = table.concat(perSeed, "; ")
        assert.is_true(total.turnedOn > 0, "turned on somewhere")
        assert.is_true(total.raidAsParty > 0, "a raid read as a party, another subgroup's fade remembered: " .. bySeed)
        assert.is_true(total.partyAsRaid > 0, "a party read as a raid, a fade remembered: " .. bySeed)
    end)
end)
