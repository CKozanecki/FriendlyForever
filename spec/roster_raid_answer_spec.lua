-- Spec: #359, #370, #373
-- Buff mode's triggers read the group's slots the way its group look does
-- (#346): IsInRaid() is believed only when the slots agree. While it can't
-- be, the "someone is missing your buff" trigger forgets nobody it
-- remembers (#272), the death trigger forgets nobody it saw dead, and the
-- join trigger counts nobody close. A roster update that can't read
-- IsInGroup() is neither a join nor a leave (#373).
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

        it("a fade during a look with IsInRaid() wrong is noted: off by hand stays off once the answer is true (black)", function()
            for what, case in pairs(LIES) do
                boot("autoOnMissing")
                case.group()
                coverAll()
                look()
                case.wrong()
                -- Ann is in your own subgroup (party1): read at every look.
                wow.state.units.party1.auras = {}
                look()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": Ann's Mark faded")
                assert.is_true(printedHas("(Ann Vale is missing your Mark of the Wild)"), what)
                slash("buffmode off")
                truth()
                for _ = 1, 3 do look() end
                assert.is_false(ns.BuffMode.IsOn(), what .. ": Ann is the same fade")
                assert.are.same({}, wow.errors, what)
            end
        end)

        it("after a reload, a first look with IsInRaid() wrong notes nothing: a fade missing all along stays old (black)", function()
            for what, case in pairs(LIES) do
                boot("autoOnMissing")
                case.group()
                coverAll()
                look()
                wow.state.units[case.token].auras = {}
                look()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": Cid's Mark faded")
                slash("buffmode off")
                wow.reloadInPlace(false, { keepTimers = true })
                case.wrong()
                look()
                assert.is_false(ns.BuffMode.IsOn(), what .. ": the first look after the reload")
                truth()
                for _ = 1, 3 do look() end
                assert.is_false(ns.BuffMode.IsOn(), what .. ": Cid was missing all along, not new")
                wow.state.units[case.group == raid and "raid5" or "party1"].auras = {}
                look()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": a new fade still counts")
                assert.are.same({}, wow.errors, what)
            end
        end)
    end)

    -- #370: the first look after a login or reload notes nothing while the
    -- group's slots weren't known (IsInGroup() unreadable), as it already
    -- does while the roster can't be told (#359).
    describe("the first look after a reload, with IsInGroup() (#370)", function()
        -- Cid's Mark fades, buff mode turns on, and the player turns it off.
        local function fadedAndOff(group, token)
            boot("autoOnMissing")
            group()
            coverAll()
            look()
            wow.state.units[token].auras = {}
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "Cid's Mark faded")
            slash("buffmode off")
        end

        it("a first look with the group readable notes as before: off by hand stays off, a new fade counts (white)", function()
            for _, group in ipairs({ raid, party }) do
                fadedAndOff(group, group == raid and "raid4" or "party2")
                wow.reloadInPlace(false, { keepTimers = true })
                for _ = 1, 4 do look() end
                assert.is_false(ns.BuffMode.IsOn(), "Cid was missing all along, not new")
                wow.state.units[group == raid and "raid5" or "party1"].auras = {}
                look()
                assert.is_true(ns.BuffMode.IsAuto(), "a new fade still counts")
                assert.is_true(printedHas(group == raid and "(Dot Moss is missing your Mark of the Wild)"
                    or "(Ann Vale is missing your Mark of the Wild)"))
                assert.are.same({}, wow.errors)
            end
        end)

        it("a reload whose first look can't read IsInGroup() doesn't turn buff mode on later for a buff missing all along (black)", function()
            for _, group in ipairs({ party, raid }) do
                local what = group == raid and "raid" or "party"
                fadedAndOff(group, group == raid and "raid4" or "party2")
                wow.reloadInPlace(false, { keepTimers = true })
                wow.state.inGroupUnreadable = true
                look()
                assert.is_false(ns.BuffMode.IsOn(), what .. ": the look that can't read the group")
                wow.state.inGroupUnreadable = nil
                for _ = 1, 4 do look() end
                assert.is_false(ns.BuffMode.IsOn(), what .. ": Cid was missing all along, not new")
                wow.state.units[group == raid and "raid5" or "party1"].auras = {}
                look()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": a new fade still counts")
                assert.are.same({}, wow.errors, what)
            end
        end)

        it("a reload that can't read IsInGroup() at all: the next roster update that can is where it starts, not a group joined (black)", function()
            for _, group in ipairs({ party, raid }) do
                local what = group == raid and "raid" or "party"
                fadedAndOff(group, group == raid and "raid4" or "party2")
                wow.state.inGroupUnreadable = true
                wow.reloadInPlace(false, { keepTimers = true })
                look()
                -- A roster update while it still can't be read changes nothing.
                wow.fire("GROUP_ROSTER_UPDATE")
                look()
                assert.is_false(ns.BuffMode.IsOn(), what .. ": while the group can't be read")
                wow.state.inGroupUnreadable = nil
                wow.fire("GROUP_ROSTER_UPDATE")
                for _ = 1, 4 do look() end
                assert.is_false(ns.BuffMode.IsOn(), what .. ": Cid was missing all along, not new")
                wow.state.units[group == raid and "raid5" or "party1"].auras = {}
                look()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": the looks run again, and a new fade counts")
                assert.are.same({}, wow.errors, what)
            end
        end)

        it("a reload that can't read IsInGroup() and finds you out of a group starts there: joining one later is a join (black)", function()
            boot("autoOnMissing")
            wow.state.inGroupUnreadable = true
            wow.reloadInPlace(false, { keepTimers = true })
            wow.state.inGroupUnreadable = nil
            -- The update that reads it says no group; then you join one where
            -- Cid is missing your Mark: everyone missing a buff is new (#272).
            wow.fire("GROUP_ROSTER_UPDATE")
            party()
            wow.wearBuff("party1", MOTW, { source = "player" })
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "Cid is missing your Mark in the group you joined")
            assert.is_true(printedHas("(Cid Rock is missing your Mark of the Wild)"))
            assert.are.same({}, wow.errors)
        end)

        it("a first look with a member's name still loading notes nothing either: the roster half alone (black)", function()
            fadedAndOff(party, "party2")
            wow.reloadInPlace(false, { keepTimers = true })
            -- The slots are known, but Cid can't be named yet.
            wow.state.units.party2.nameLoading = true
            look()
            assert.is_false(ns.BuffMode.IsOn(), "the look that can't name Cid")
            wow.state.units.party2.nameLoading = nil
            for _ = 1, 4 do look() end
            assert.is_false(ns.BuffMode.IsOn(), "Cid was missing all along, not new")
            assert.are.same({}, wow.errors)
        end)
    end)

    -- #373: in the middle of a session, a roster update that can't read
    -- IsInGroup() changes nothing: no join, no leave. The next one that can
    -- decides. While the group isn't known after a login (#370), the looks
    -- read IsInGroup() again, so they don't wait for a roster update.
    describe("a roster update that can't read IsInGroup() (#373)", function()
        local function unreadableUpdate()
            wow.state.inGroupUnreadable = true
            wow.fire("GROUP_ROSTER_UPDATE")
        end
        local function readableUpdate()
            wow.state.inGroupUnreadable = nil
            wow.fire("GROUP_ROSTER_UPDATE")
        end
        local function leave()
            wow.setGroup(nil, {})
            wow.fire("GROUP_ROSTER_UPDATE")
        end

        -- Cid's Mark fades, buff mode turns on, and the player turns it off.
        local function fadedAndOff(group, token)
            boot("autoOnMissing")
            group()
            coverAll()
            look()
            wow.state.units[token].auras = {}
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "Cid's Mark faded")
            slash("buffmode off")
        end

        local GROUPS = {
            { "party", party, "party2", "party1", "(Ann Vale is missing your Mark of the Wild)" },
            { "raid", raid, "raid4", "raid5", "(Dot Moss is missing your Mark of the Wild)" },
        }

        it("joining and leaving behave as before: a group joined counts everyone missing a buff as new, and leaving forgets (white)", function()
            for _, case in ipairs(GROUPS) do
                local what, group = case[1], case[2]
                -- The missing-buff trigger: Cid's fade, off by hand, stays off.
                fadedAndOff(group, case[3])
                for _ = 1, 3 do look() end
                assert.is_false(ns.BuffMode.IsOn(), what .. ": Cid was missing at the last look")
                -- Leaving forgets; joining again, Cid missing is new.
                leave()
                look()
                assert.is_false(ns.BuffMode.IsOn(), what .. ": out of the group")
                group()
                coverAll()
                wow.state.units[case[3]].auras = {}
                look()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": the group joined again: Cid is missing, as new")
                -- The join trigger: on at a join, off by hand, on at the next join.
                boot("autoOnJoin")
                group()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": joined with someone close")
                slash("buffmode off")
                leave()
                group()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": joined again")
                assert.are.same({}, wow.errors, what)
            end
        end)

        it("one roster update that can't read IsInGroup(), in a party or a raid, forgets no missing buff (black)", function()
            for _, case in ipairs(GROUPS) do
                local what = case[1]
                fadedAndOff(case[2], case[3])
                unreadableUpdate()
                look()
                assert.is_false(ns.BuffMode.IsOn(), what .. ": the look after the update that can't read the group")
                readableUpdate()
                for _ = 1, 4 do look() end
                assert.is_false(ns.BuffMode.IsOn(), what .. ": Cid was missing all along, not new")
                -- A new fade still counts.
                wow.state.units[case[4]].auras = {}
                look()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": a new fade still counts")
                assert.is_true(printedHas(case[5]), what)
                assert.are.same({}, wow.errors, what)
            end
        end)

        it("one roster update that can't read IsInGroup() isn't a join: buff mode turned off stays off, in the world or a dungeon (black)", function()
            for _, case in ipairs(GROUPS) do
                for _, where in ipairs({ "world", "dungeon" }) do
                    local what = case[1] .. " in the " .. where
                    boot("autoOnJoin")
                    if where == "dungeon" then wow.enterDungeon(33, "Shadowfang Keep") end
                    case[2]()
                    assert.is_true(ns.BuffMode.IsAuto(), what .. ": joined")
                    slash("buffmode off")
                    unreadableUpdate()
                    readableUpdate()
                    assert.is_false(ns.BuffMode.IsOn(), what .. ": the same group, not a join")
                    for _ = 1, 3 do look() end
                    assert.is_false(ns.BuffMode.IsOn(), what .. ": and nothing later either")
                    assert.are.same({}, wow.errors, what)
                end
            end
        end)

        it("one roster update that can't read IsInGroup() isn't a leave: the group's first pull holds, so a death still counts (black)", function()
            for _, case in ipairs(GROUPS) do
                local what = case[1]
                boot("autoOnDeath")
                case[2]()
                wow.enterCombat()
                wow.leaveCombat()
                unreadableUpdate()
                readableUpdate()
                wow.state.units[case[3]].dead = true
                wow.fire("UNIT_HEALTH", case[3])
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": Cid died after the group's first pull")
                assert.is_true(printedHas("(someone in your group died)"), what)
                assert.are.same({}, wow.errors, what)
            end
        end)

        it("a real leave read while IsInGroup() can't be read: the next update that can read it leaves (black)", function()
            for _, case in ipairs(GROUPS) do
                local what = case[1]
                fadedAndOff(case[2], case[3])
                wow.setGroup(nil, {})
                unreadableUpdate()
                readableUpdate()
                look()
                assert.is_false(ns.BuffMode.IsOn(), what .. ": out of the group")
                -- Joining again: Cid missing is new, so leaving forgot.
                case[2]()
                coverAll()
                wow.state.units[case[3]].auras = {}
                look()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": the group joined again: Cid is missing, as new")
                assert.are.same({}, wow.errors, what)
            end
        end)

        it("one roster update that can't read IsInGroup() still notes who is dead: their release isn't a new death (black)", function()
            for _, case in ipairs(GROUPS) do
                local what = case[1]
                boot("autoOnDeath")
                case[2]()
                wow.enterCombat()
                wow.leaveCombat()
                -- Cid died where the game sent no health change.
                wow.state.units[case[3]].dead = true
                unreadableUpdate()
                wow.state.inGroupUnreadable = nil
                wow.enterCombat()
                wow.fire("UNIT_HEALTH", case[3])
                wow.leaveCombat()
                assert.is_false(ns.BuffMode.IsOn(), what .. ": Cid's release isn't a new death")
                assert.are.same({}, wow.errors, what)
            end
        end)

        it("out of a group, a look while IsInGroup() can't be read keeps you out: joining later is still a join (black)", function()
            for _, case in ipairs(GROUPS) do
                local what = case[1]
                boot("autoOnJoin")
                case[2]()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": joined")
                slash("buffmode off")
                leave()
                -- The look already scheduled comes while the game can't say.
                wow.state.inGroupUnreadable = true
                for _ = 1, 3 do look() end
                -- Readable again at the join itself.
                wow.state.inGroupUnreadable = nil
                case[2]()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": joined again, with someone close")
                assert.is_true(printedHas("(you joined a group)"), what)
                assert.are.same({}, wow.errors, what)
            end
        end)

        -- Leaving or joining can send one roster update and no other: when
        -- that one can't read IsInGroup(), the next look reads it again and
        -- decides (the architecture review of PR #378).
        local function leaveUnread()
            wow.setGroup(nil, {})
            unreadableUpdate()
            look()
            wow.state.inGroupUnreadable = nil
        end

        it("a leave whose only roster update can't read IsInGroup() is seen at a later look: the next group is a join (black)", function()
            for _, case in ipairs(GROUPS) do
                local what = case[1]
                boot("autoOnJoin")
                case[2]()
                slash("buffmode off")
                leaveUnread()
                for _ = 1, 4 do look() end
                -- A new group: Bo and Dot, out in the world, close by.
                wow.setGroup("party", { "Bo-Fern", "Dot-Moss" })
                wow.fire("GROUP_ROSTER_UPDATE")
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": joining Bo and Dot's party is a join")
                assert.is_true(printedHas("(you joined a group)"), what)
                assert.are.same({}, wow.errors, what)
            end
        end)

        it("a leave whose only roster update can't read IsInGroup() ends the group's first pull: a death in the next group before its pull doesn't count (black)", function()
            for _, case in ipairs(GROUPS) do
                local what = case[1]
                boot("autoOnDeath")
                case[2]()
                wow.enterCombat()
                wow.leaveCombat()
                leaveUnread()
                for _ = 1, 4 do look() end
                wow.setGroup("party", { "Bo-Fern", "Dot-Moss" })
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.state.units.party1.dead = true
                wow.fire("UNIT_HEALTH", "party1")
                assert.is_false(ns.BuffMode.IsOn(), what .. ": the new group hasn't fought yet")
                assert.are.same({}, wow.errors, what)
            end
        end)

        it("a join whose only roster update can't read IsInGroup() is seen at the next look that can (black)", function()
            for _, case in ipairs(GROUPS) do
                local what = case[1]
                boot("autoOnJoin")
                wow.state.inGroupUnreadable = true
                case[2]()
                assert.is_false(ns.BuffMode.IsOn(), what .. ": the update that can't read the group")
                look()
                assert.is_false(ns.BuffMode.IsOn(), what .. ": the look that can't read it either")
                wow.state.inGroupUnreadable = nil
                look()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": the next look reads the join")
                assert.is_true(printedHas("(you joined a group)"), what)
                assert.are.same({}, wow.errors, what)
            end
        end)

        it("once a look decides after an update that couldn't read IsInGroup(), someone coming close is checked only at the next roster change (black)", function()
            -- Joining out in the world with nobody close: the join trigger
            -- waits for a roster change with someone close (#256).
            local function joinedFar()
                boot("autoOnJoin")
                wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
                wow.state.units.party1.outOfRange = true
                wow.state.units.party2.outOfRange = true
                wow.fire("GROUP_ROSTER_UPDATE")
                assert.is_false(ns.BuffMode.IsOn(), "nobody close at the join")
            end
            for _, how in ipairs({ "a look", "a roster update" }) do
                joinedFar()
                unreadableUpdate()
                if how == "a look" then
                    wow.state.inGroupUnreadable = nil
                    look()
                else
                    readableUpdate()
                end
                -- The same group, decided by `how`. Ann comes close; the game
                -- sends no roster change.
                wow.state.units.party1.outOfRange = nil
                for _ = 1, 3 do look() end
                assert.is_false(ns.BuffMode.IsOn(), how .. ": the looks don't check who is close")
                wow.fire("GROUP_ROSTER_UPDATE")
                assert.is_true(ns.BuffMode.IsAuto(), how .. ": the next roster change does")
                assert.is_true(printedHas("(you joined a group)"), how)
                assert.are.same({}, wow.errors, how)
            end
        end)

        it("after a reload that can't read IsInGroup(), the looks read it again without a roster update (black)", function()
            for _, case in ipairs(GROUPS) do
                local what = case[1]
                fadedAndOff(case[2], case[3])
                wow.state.inGroupUnreadable = true
                wow.reloadInPlace(false, { keepTimers = true })
                for _ = 1, 3 do look() end
                assert.is_false(ns.BuffMode.IsOn(), what .. ": while the group can't be read")
                -- Readable again, and no roster update comes.
                wow.state.inGroupUnreadable = nil
                for _ = 1, 4 do look() end
                assert.is_false(ns.BuffMode.IsOn(), what .. ": Cid was missing all along, not new")
                wow.state.units[case[4]].auras = {}
                look()
                assert.is_true(ns.BuffMode.IsAuto(), what .. ": the looks run again, and a new fade counts")
                assert.is_true(printedHas(case[5]), what)
                assert.are.same({}, wow.errors, what)
            end
            -- Out of a group: the look that reads it stops there, and joining
            -- one later is a join (everyone missing a buff is new, #272).
            boot("autoOnMissing")
            wow.state.inGroupUnreadable = true
            wow.reloadInPlace(false, { keepTimers = true })
            look()
            wow.state.inGroupUnreadable = nil
            look()
            party()
            wow.wearBuff("party1", MOTW, { source = "player" })
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "Cid is missing your Mark in the group you joined")
            assert.is_true(printedHas("(Cid Rock is missing your Mark of the Wild)"))
            assert.are.same({}, wow.errors)
            -- And with the join trigger: the look's "not in a group" is kept,
            -- so the party joined later is a join.
            boot("autoOnJoin")
            wow.state.inGroupUnreadable = true
            wow.reloadInPlace(false, { keepTimers = true })
            look()
            wow.state.inGroupUnreadable = nil
            for _ = 1, 2 do look() end
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.BuffMode.IsAuto(), "joining after the look read no group is a join")
            assert.is_true(printedHas("(you joined a group)"))
            assert.are.same({}, wow.errors)
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

        it("members already dead when the group is read with IsInRaid() wrong are noted, at a roster change or a reload (black)", function()
            local CASES = {
                { "false in a raid", raid, { "raid1", "raid4" }, function() lie(false) end },
                { "unreadable in a raid", raid, { "raid1", "raid4" },
                    function() wow.state.inRaidUnreadable = true end },
                { "true in a party", party, { "party1", "party2" }, function() lie(true) end },
            }
            for _, case in ipairs(CASES) do
                local what, group, tokens, wrong = case[1], case[2], case[3], case[4]
                for _, how in ipairs({ "roster", "reload" }) do
                    boot("autoOnDeath")
                    group()
                    wow.enterCombat()
                    wow.leaveCombat()
                    -- Ann (your subgroup) and Cid (subgroup 2 in the raid)
                    -- died where the game sent no health change.
                    for _, token in ipairs(tokens) do wow.state.units[token].dead = true end
                    wrong()
                    if how == "roster" then
                        wow.fire("GROUP_ROSTER_UPDATE")
                    else
                        wow.reloadInPlace(false, { keepTimers = true })
                        wow.enterCombat()
                        wow.leaveCombat()
                    end
                    truth()
                    wow.enterCombat()
                    for _, token in ipairs(tokens) do wow.fire("UNIT_HEALTH", token) end
                    wow.leaveCombat()
                    assert.is_false(ns.BuffMode.IsOn(), what .. ", " .. how .. ": their release isn't a new death")
                    assert.are.same({}, wow.errors, what .. ", " .. how)
                end
            end
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

    -- red: regroups, buffs worn and lost, range and sight changes, an
    -- IsInRaid() that tells the truth, flips half its answers, always lies,
    -- or can't be read, an IsInGroup() that sometimes can't be read
    -- (#370), and roster updates that come while it can't (#373). The
    -- missing-buff trigger never turns buff mode on
    -- for a member the client's state shows was already missing at an
    -- earlier look the addon could see them at, and hasn't been seen wearing
    -- it or left since. Buff mode is turned off by hand after each turn-on,
    -- so each one is seen. Nobody presses.
    it("a storm with an IsInRaid() that sometimes lies never turns buff mode on for a buff already missing (red)", function()
        local POOL = { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed", "Gus-Lane", "Hal-Pine" }
        local MODES = { "truth", "flips", "inverted", "unreadable" }
        local total = { looks = 0, turnedOn = 0, raidAsParty = 0, partyAsRaid = 0, reloads = 0, freshLies = 0,
            freshNoGroup = 0, noGroup = 0, unreadableRoster = 0, unreadableRosterHeld = 0 }
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
            -- Also held: a member in party1..4 seen missing, in reach, at any
            -- look once the group has been noted (wasNoted: since the last
            -- reload a look has noted it). Whatever IsInRaid() says, the addon
            -- reads those slots at every look: your own subgroup in a raid,
            -- everyone in a party.
            local function note(wasNoted)
                -- While IsInGroup() can't be read, the addon may have seen
                -- nobody: nobody new is held (#370).
                local seen = not wow.state.inGroupUnreadable
                local inGroup, partySlot = {}, {}
                for i = 1, 4 do
                    local u = wow.state.units["party" .. i]
                    if u then partySlot[u.id] = true end
                end
                for _, token in ipairs(others()) do
                    local u = wow.state.units[token]
                    inGroup[u.id] = true
                    if inReach(u) then
                        if wears(u) then
                            known[u.id] = nil
                        elseif seen and (mode == "truth" or (wasNoted and partySlot[u.id])) then
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

            -- Since a reload, whether no look could have noted the group yet:
            -- every one since lied outright or couldn't be read. Until one
            -- could, the first look after it only notes, so nothing turns on.
            local fresh = false
            -- Whether a look since the last reload has surely noted the group:
            -- joining one notes it (as empty), and so does a look where
            -- IsInRaid() told the truth.
            local noted = false

            local function regroup()
                wow.setGroup(nil, {})
                wow.fire("GROUP_ROSTER_UPDATE")
                known, fresh, noted = {}, false, true
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
                reload = function()
                    wow.reloadInPlace(false, { keepTimers = true })
                    known, fresh, noted = {}, true, false
                    total.reloads = total.reloads + 1
                    -- Sometimes IsInGroup() can't be read from just after the
                    -- reload, for its first look (#370).
                    if random.random(3) == 1 then wow.state.inGroupUnreadable = true end
                end,
                lie = function()
                    mode = MODES[random.random(#MODES)]
                    wow.state.inRaidUnreadable = mode == "unreadable" or nil
                end,
                -- IsInGroup() can't be read, or can again (#370).
                group = function()
                    wow.state.inGroupUnreadable = not wow.state.inGroupUnreadable or nil
                end,
                -- A roster update with the group unchanged (#373): when
                -- IsInGroup() can't be read, it's neither a join nor a leave.
                roster = function()
                    if wow.state.inGroupUnreadable and wow.state.groupType then
                        total.unreadableRoster = total.unreadableRoster + 1
                        if next(known) then total.unreadableRosterHeld = total.unreadableRosterHeld + 1 end
                    end
                    wow.fire("GROUP_ROSTER_UPDATE")
                end,
            }
            local NAMES = { "regroup", "wear", "strip", "strip", "range", "sight", "lie", "lie", "lie", "reload",
                "group", "group", "roster", "roster" }

            regroup()
            for step = 1, 250 do
                local action = NAMES[random.random(#NAMES)]
                ACTIONS[action]()
                local where = ("seed %d, step %d (%s, IsInRaid %s)"):format(seed, step, action, mode)
                count()
                local wasOn, printed, wasFresh = ns.BuffMode.IsOn(), #wow.printed, fresh
                if fresh and (mode == "inverted" or mode == "unreadable") then
                    total.freshLies = total.freshLies + 1
                end
                -- A look with IsInGroup() unreadable, and one right after a
                -- reload with a member missing their Mark in reach: the old
                -- first look noted nobody there, and that member turned buff
                -- mode on at the next look (#370).
                local noGroup = wow.state.inGroupUnreadable == true
                if noGroup and wow.state.groupType then
                    total.noGroup = total.noGroup + 1
                    if fresh then
                        for _, token in ipairs(others()) do
                            local u = wow.state.units[token]
                            if inReach(u) and not wears(u) then
                                total.freshNoGroup = total.freshNoGroup + 1
                                break
                            end
                        end
                    end
                end
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
                    assert.is_false(wasFresh, where .. ": turned on for " .. named
                        .. " before any look since the reload could see the group")
                    slash("buffmode off")
                end
                if not noGroup and (mode == "truth" or mode == "flips") then fresh = false end
                note(noted)
                if mode == "truth" and not noGroup then noted = true end
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
        assert.is_true(total.freshLies > 0, "a look right after a reload that lied or couldn't read: " .. total.freshLies)
        assert.is_true(total.noGroup > 0, "a look in a group with IsInGroup() unreadable")
        assert.is_true(total.freshNoGroup > 0, "a first look after a reload with IsInGroup() unreadable, someone missing: "
            .. total.freshNoGroup)
        -- #373: roster updates that couldn't read IsInGroup(), in a group,
        -- some while a member was held as missing.
        assert.is_true(total.unreadableRosterHeld > 0, ("roster updates with IsInGroup() unreadable: %d, %d with a member held missing")
            :format(total.unreadableRoster, total.unreadableRosterHeld))
    end)
end)
