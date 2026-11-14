-- Spec: #346
-- Buff mode's group look believes IsInRaid() only when the group's slots
-- agree with it, as the PvP rule's EveryoneInside does (#335): not a raid
-- means raid1 is empty, a raid means one of raid1..40 is you. An answer the
-- slots disagree with is treated like one that can't be read (#322):
-- GroupBuffs.Next is never settled and offers no group version, since a raid
-- taken for a party is only your own subgroup.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local INTELLECT, BRILLIANCE = 10157, 23028
local UNKNOWN = "the game won't say whether you're in a raid or a group"

describe("Buff mode's group look believes IsInRaid() only when the slots agree (#346)", function()
    local ns

    local function lie(answer) _G.IsInRaid = function() return answer end end

    local function mage(opts)
        opts = opts or {}
        return wow.boot({ autoBuffMode = opts.autoBuffMode, before = function(state)
            state.class = "MAGE"
            state.knownSpells = { [INTELLECT] = true, [BRILLIANCE] = true }
            state.items = { [wow.ITEM.arcanePowder] = 5 }
        end })
    end

    -- A raid: Ann, Bo and Eve in your subgroup 1, Cid and Dot in subgroup 2,
    -- you in raid6. As in the game, the simulated client also gives your own
    -- subgroup's other members as party1..4 in a raid (#322).
    local function raid()
        wow.setGroup("raid", { "Ann-Vale", "Bo-Fern", "Eve-Hill", "Cid-Rock", "Dot-Moss" })
        for i = 4, 5 do wow.state.units["raid" .. i].subgroup = 2 end
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    local function bootRaid()
        ns = mage()
        raid()
    end

    -- A party of four: party1..4, you in none of them.
    local function bootParty()
        ns = mage()
        wow.setGroup("party", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    local function buff(tokens)
        for _, token in ipairs(tokens) do wow.wearBuff(token, INTELLECT, { source = "player" }) end
    end

    local SUBGROUP_ONE, SUBGROUP_TWO = { "raid1", "raid2", "raid3" }, { "raid4", "raid5" }
    local PARTY = { "party1", "party2", "party3", "party4" }

    local function first(name) return name and name:match("^[^%-]+") end

    -- Next's offers, as the button's list has them.
    local function listed()
        local list = {}
        ns.GroupBuffs.Next(list)
        return list
    end

    local function assertNoGroupVersion(list, what)
        for _, entry in ipairs(list) do
            assert.are.equal("Arcane Intellect", entry.spell, what)
            assert.is_nil(entry.cast, what)
        end
    end

    it("a real party behaves as before: its group version, then settled once all have it (white)", function()
        bootParty()
        local offer = ns.GroupBuffs.Next()
        assert.are.equal("Arcane Brilliance", offer and offer.spell)
        assert.are.equal("your party", offer.cast.label)
        buff(PARTY)
        local none, why, settled = ns.GroupBuffs.Next()
        assert.is_nil(none)
        assert.are.equal("everyone in your group has your buffs", why)
        assert.is_true(settled)
        assert.are.same({}, wow.errors)
    end)

    it("a real raid behaves as before: each subgroup's group version, then settled once all have it (white)", function()
        bootRaid()
        local offer = ns.GroupBuffs.Next()
        assert.are.equal("Arcane Brilliance", offer and offer.spell)
        assert.are.equal("Group 1", offer.cast.label)
        buff(SUBGROUP_ONE)
        offer = ns.GroupBuffs.Next()
        assert.are.equal("Cid", first(offer and offer.name), "subgroup 2 is still missing it")
        buff(SUBGROUP_TWO)
        local none, why, settled = ns.GroupBuffs.Next()
        assert.is_nil(none)
        assert.are.equal("everyone in your group has your buffs", why)
        assert.is_true(settled)
        assert.are.same({}, wow.errors)
    end)

    it("you are found in any of the 40 raid slots, a full raid included, and it settles (white)", function()
        local names = {}
        for i = 1, 39 do
            names[i] = "M" .. string.char(97 + (i - 1) % 26) .. string.char(97 + math.floor((i - 1) / 26)) .. "-Vale"
        end
        for _, slot in ipairs({ 1, 17, 40 }) do
            ns = mage()
            wow.setGroup("raid", names) -- you are raid40
            local units = wow.state.units
            units["raid" .. slot], units.raid40 = units.raid40, units["raid" .. slot]
            wow.fire("GROUP_ROSTER_UPDATE")
            for i = 1, 40 do
                if units["raid" .. i] ~= units.player then buff({ "raid" .. i }) end
            end
            local none, why, settled = ns.GroupBuffs.Next()
            assert.is_nil(none, "you in raid" .. slot)
            assert.are.equal("everyone in your group has your buffs", why, "you in raid" .. slot)
            assert.is_true(settled, "you in raid" .. slot)
        end
        assert.are.same({}, wow.errors)
    end)

    it("not in a group, with raid1 empty, is settled as before (white)", function()
        ns = mage()
        local none, why, settled = ns.GroupBuffs.Next()
        assert.is_nil(none)
        assert.are.equal("you're not in a group", why)
        assert.is_true(settled)
    end)

    it("IsInRaid() false in a raid: your subgroup buffed never settles, and no group version (black)", function()
        bootRaid()
        lie(false)
        local list = listed()
        assert.are.same({ "Ann", "Bo", "Eve" }, { first(list[1] and list[1].name),
            first(list[2] and list[2].name), first(list[3] and list[3].name) },
            "only your subgroup's slots are seen, one at a time")
        assertNoGroupVersion(list, "a raid read as a party")
        buff(SUBGROUP_ONE)
        local none, why, settled = ns.GroupBuffs.Next()
        assert.is_nil(none)
        assert.are.equal(UNKNOWN, why)
        assert.is_false(settled, "Cid and Dot are missing it")
        -- Even once everyone has it, an answer the slots disagree with never settles.
        buff(SUBGROUP_TWO)
        none, why, settled = ns.GroupBuffs.Next()
        assert.is_nil(none)
        assert.are.equal(UNKNOWN, why)
        assert.is_false(settled)
        assert.are.same({}, wow.errors)
    end)

    it("IsInRaid() true in a party: never settles, and no group version (black)", function()
        bootParty()
        lie(true)
        local list = listed()
        assert.are.equal(4, #list, "the party is offered single buffs, one each")
        assertNoGroupVersion(list, "a party read as a raid")
        buff(PARTY)
        local none, why, settled = ns.GroupBuffs.Next()
        assert.is_nil(none)
        assert.are.equal(UNKNOWN, why)
        assert.is_false(settled, "no raid slot is you: the answer is wrong")
        assert.are.same({}, wow.errors)
    end)

    it("IsInRaid() true out of a group never settles either (black)", function()
        ns = mage()
        lie(true)
        local none, why, settled = ns.GroupBuffs.Next()
        assert.is_nil(none)
        assert.are.equal(UNKNOWN, why)
        assert.is_false(settled)
        assert.are.same({}, wow.errors)
    end)

    -- The ways one slot answer can't be read.
    local UNREADABLE = {
        ["a secret"] = function(value) return wow.secret(value) end,
        nothing = function() return nil end,
        ["an error"] = function() error("blocked") end,
        ["a number"] = function() return 1 end,
    }

    it("a raid1 that can't be read as empty never confirms not a raid (black)", function()
        for answer, give in pairs(UNREADABLE) do
            bootParty()
            buff(PARTY)
            local realExists = _G.UnitExists
            _G.UnitExists = function(unit)
                if unit == "raid1" then return give(false) end
                return realExists(unit)
            end
            local none, why, settled = ns.GroupBuffs.Next()
            assert.is_nil(none, answer)
            assert.are.equal(UNKNOWN, why, answer)
            assert.is_false(settled, answer)
            assert.are.same({}, wow.errors, answer)
        end
    end)

    it("a raid where no slot can be read as you never confirms a raid (black)", function()
        for answer, give in pairs(UNREADABLE) do
            bootRaid()
            buff(SUBGROUP_ONE)
            buff(SUBGROUP_TWO)
            local realIsUnit = _G.UnitIsUnit
            _G.UnitIsUnit = function(a, b)
                if a:find("^raid%d+$") and b == "player" then return give(realIsUnit(a, b)) end
                return realIsUnit(a, b)
            end
            local none, why, settled = ns.GroupBuffs.Next()
            assert.is_nil(none, answer)
            assert.are.equal(UNKNOWN, why, answer)
            assert.is_false(settled, answer)
            assert.are.same({}, wow.errors, answer)
        end
    end)

    it("IsInRaid() asked again in the same look can't make the raid's group version one party's (black)", function()
        bootRaid()
        -- A raid on the first read of each look, not one on any read after.
        local reads = 0
        _G.IsInRaid = function()
            reads = reads + 1
            return reads == 1
        end
        local list = {}
        ns.GroupBuffs.Next(list)
        local labels = {}
        for _, entry in ipairs(list) do
            if entry.cast then
                labels[#labels + 1] = entry.cast.label
                assert.is_true(entry.cast.count <= 4, entry.cast.label .. ": no more than your subgroup")
            end
        end
        -- Subgroup 2's two members are too few for a group version.
        assert.are.same({ "Group 1" }, labels, "read as one party, it would be \"your party\"")
        assert.are.same({}, wow.errors)
    end)

    it("buff mode turned on in a raid doesn't end as done while IsInRaid() reads false (black)", function()
        ns = mage({ autoBuffMode = true })
        local button = ns.BuffButton.Frame()
        raid()
        assert.is_true(ns.BuffMode.IsAuto(), "joining with someone close by turned it on")
        buff(SUBGROUP_ONE)
        lie(false)
        ns.BuffButton.Refresh()
        assert.is_true(ns.BuffMode.IsAuto(), "subgroup 2 is missing it: not done")
        assert.is_nil(button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText),
            "nothing to offer from your own subgroup")
        _G.IsInRaid = function() return true end
        ns.BuffButton.Refresh()
        assert.is_true(ns.BuffMode.IsAuto())
        assert.is_not_nil(button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText),
            "a true answer: subgroup 2 is offered")
        assert.are.same({}, wow.errors)
        assert.are.equal(0, #wow.casts, "nothing casts without a press")
    end)

    -- red: a storm of regroups, buffs, range and zone changes, with an
    -- IsInRaid() that tells the truth, flips half its answers, always lies,
    -- or can't be read (the client's state.inRaidUnreadable). Whenever Next says settled, or buff mode ends itself as done,
    -- every other member the client's own state shows in reach wears your
    -- Arcane Intellect. Nobody presses: no cast counts as just given.
    it("a storm with an IsInRaid() that sometimes lies never ends buff mode as done while a member in reach is missing your buff (red)", function()
        local POOL = { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed", "Gus-Lane", "Hal-Pine" }
        local MODES = { "truth", "flips", "inverted", "unreadable" }
        -- How often the storm reached the cases the red criterion is about,
        -- counted from the client's own state: a raid taken for a party (a
        -- lying answer, your subgroup all buffed, someone in reach in another
        -- subgroup missing it) and a party taken for a raid (always lying, in
        -- a party, someone in reach missing it). By seed too.
        local total = { looks = 0, settled = 0, ended = 0, raidAsParty = 0, partyAsRaid = 0 }
        local perSeed = {}
        for _, seed in ipairs({ 7, 41, 313, 2026, 8191, 65537 }) do
            random.seed(seed)
            for _ = 1, 5 do random.random() end
            ns = mage({ autoBuffMode = true })
            wow.state.items[wow.ITEM.arcanePowder] = 1000
            ns.BuffButton.Frame()
            local mode, lieState = "truth", seed
            local realRaid = _G.IsInRaid
            _G.IsInRaid = function()
                local truth = realRaid()
                if mode == "inverted" then return not truth end
                if mode == "truth" or mode == "unreadable" then return truth end
                lieState = (lieState * 48271) % 2147483647
                if lieState % 2 == 0 then return not truth end
                return truth
            end

            -- The other members' slots (the client gives a raid's party1..4
            -- on demand, never as keys, so each member is seen once).
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
                    if (id == INTELLECT or id == BRILLIANCE) and not wow.auraExpired(u, i) then return true end
                end
                return false
            end

            -- In reach, by the client's state: online, alive, in sight and in range.
            local function inReach(u) return not (u.offline or u.dead or u.hidden or u.outOfRange) end

            -- A member the client's state shows in reach and missing your buff, or nil.
            local function missingInReach()
                for _, token in ipairs(others()) do
                    local u = wow.state.units[token]
                    if inReach(u) and not wears(u) then
                        return token
                    end
                end
            end

            -- Whether the client's state is a raid taken for a party, or a
            -- party taken for a raid, while IsInRaid() is lying.
            local function raidAsParty()
                if wow.state.groupType ~= "raid" or (mode ~= "inverted" and mode ~= "flips") then return false end
                local mine, oursAll, theirsMissing = wow.state.units.player.subgroup or 1, true, false
                for _, token in ipairs(others()) do
                    local u = wow.state.units[token]
                    if (u.subgroup or 1) == mine then
                        oursAll = oursAll and wears(u)
                    elseif inReach(u) and not wears(u) then
                        theirsMissing = true
                    end
                end
                return oursAll and theirsMissing
            end
            local function partyAsRaid()
                return wow.state.groupType == "party" and mode == "inverted" and missingInReach() ~= nil
            end

            local function strip(token)
                local u = wow.state.units[token]
                for i = #(u.auras or {}), 1, -1 do
                    if u.auras[i] == INTELLECT then
                        table.remove(u.auras, i)
                        table.remove(u.auraSources, i)
                        table.remove(u.auraDurations, i)
                        table.remove(u.auraExpires, i)
                    end
                end
            end

            local function regroup()
                wow.setGroup(nil)
                wow.fire("GROUP_ROSTER_UPDATE")
                local pick, names = random.random(0, #POOL), {}
                for _, name in ipairs(POOL) do
                    if #names < pick and random.random(2) == 1 then names[#names + 1] = name end
                end
                if #names == 0 then
                    wow.advance(0)
                    return
                end
                if #names > 4 or random.random(2) == 1 then
                    wow.setGroup("raid", names)
                    wow.state.units.player.subgroup = random.random(2)
                    for i = 1, #names do wow.state.units["raid" .. i].subgroup = random.random(2) end
                else
                    wow.setGroup("party", names)
                end
                for _, token in ipairs(others()) do
                    if random.random(3) == 1 then wow.wearBuff(token, INTELLECT, { source = "player" }) end
                end
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.advance(0)
            end

            local function anyOther()
                local list = others()
                return list[1] and list[random.random(#list)]
            end

            local ACTIONS = {
                regroup = regroup,
                wear = function()
                    local token = anyOther()
                    if token then wow.wearBuff(token, INTELLECT, { source = "player" }) end
                end,
                wearAll = function()
                    for _, token in ipairs(others()) do
                        if random.random(4) > 1 then wow.wearBuff(token, INTELLECT, { source = "player" }) end
                    end
                end,
                strip = function()
                    local token = anyOther()
                    if token then strip(token) end
                end,
                range = function()
                    local token = anyOther()
                    if token then
                        local u = wow.state.units[token]
                        u.outOfRange = not u.outOfRange or nil
                    end
                end,
                zone = function()
                    local token = anyOther()
                    if token then
                        if wow.state.units[token].hidden then wow.zoneIn(token) else wow.zoneOut(token) end
                    end
                end,
                lie = function()
                    mode = MODES[random.random(#MODES)]
                    wow.state.inRaidUnreadable = mode == "unreadable"
                end,
            }
            local reached = { raidAsParty = 0, partyAsRaid = 0 }
            perSeed[#perSeed + 1] = ("seed %d: %d raid as party, %d party as raid"):format(seed, 0, 0)
            local NAMES = { "regroup", "wear", "wearAll", "wearAll", "strip", "range", "zone", "lie", "lie" }

            for step = 1, 80 do
                local action = NAMES[random.random(#NAMES)]
                ACTIONS[action]()
                local where = ("seed %d, step %d (%s, IsInRaid %s)"):format(seed, step, action, mode)
                local _, _, settled = ns.GroupBuffs.Next()
                total.looks = total.looks + 1
                if raidAsParty() then
                    total.raidAsParty = total.raidAsParty + 1
                    reached.raidAsParty = reached.raidAsParty + 1
                end
                if partyAsRaid() then
                    total.partyAsRaid = total.partyAsRaid + 1
                    reached.partyAsRaid = reached.partyAsRaid + 1
                end
                if settled then
                    total.settled = total.settled + 1
                    local missing = missingInReach()
                    assert.is_nil(missing, where .. ": settled while " .. tostring(missing) .. " is missing it")
                end
                local wasAuto = ns.BuffMode.IsAuto()
                ns.BuffButton.Refresh()
                if wasAuto and not ns.BuffMode.IsAuto() then
                    total.ended = total.ended + 1
                    local missing = missingInReach()
                    assert.is_nil(missing, where .. ": buff mode ended while " .. tostring(missing) .. " is missing it")
                end
                assert.are.same({}, wow.errors, where)
                assert.are.equal(0, #wow.casts, where .. ": nothing casts without a press")
            end
            perSeed[#perSeed] = ("seed %d: %d raid as party, %d party as raid")
                :format(seed, reached.raidAsParty, reached.partyAsRaid)
        end
        -- The storm reached the cases it is about.
        assert.is_true(total.settled > 0, "Next settled somewhere")
        local bySeed = table.concat(perSeed, "; ")
        assert.is_true(total.raidAsParty > 0, "a raid read as a party, your subgroup buffed, another missing: " .. bySeed)
        assert.is_true(total.partyAsRaid > 0, "a party read as a raid, someone missing: " .. bySeed)
        assert.is_true(total.ended > 0, "buff mode ended as done somewhere")
    end)
end)
