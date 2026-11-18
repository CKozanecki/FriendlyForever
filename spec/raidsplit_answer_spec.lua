-- Spec: #372, #443
-- The raid buff split reads the raid as buff mode does (#372):
-- GroupBuffs.RaidAnswer, which believes IsInRaid() only when the raid's
-- slots agree. Only a believable "not in a raid" ends the split or forgets
-- its peers; one roster update whose answer is a secret, or false in a raid,
-- or true in a party, leaves everything as it was, and nothing is announced
-- while the answer can't be believed.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local FORT, SPIRIT, SHADOW = 10938, 27841, 10958
local PRIEST_SPELLS = { [FORT] = true, [SPIRIT] = true, [SHADOW] = true }
local ORDER = { "fortitude", "spirit", "shadow" }

local function keysOf(share)
    local out = {}
    for key in pairs(share or {}) do out[#out + 1] = key end
    table.sort(out)
    return table.concat(out, ",")
end

describe("The raid buff split reads the raid as buff mode does (#372)", function()
    local clients, net, realIsInRaid

    local function share(c)
        wow.use(c)
        local mine = c.ns.RaidSplit.Current()
        return mine and keysOf(mine) or nil
    end

    -- How many SHARE messages c has sent on the RAID route so far.
    local function raidSends(c)
        wow.use(c)
        local n = 0
        for _, msg in ipairs(wow.addonSent) do
            if msg.channel == "RAID" then n = n + 1 end
        end
        return n
    end

    -- The text of each SHARE c sent on the RAID route after the first n.
    local function raidTexts(c, n)
        wow.use(c)
        local out = {}
        for i = n + 1, #wow.addonSent do
            local msg = wow.addonSent[i]
            if msg.channel == "RAID" then out[#out + 1] = msg.text end
        end
        return out
    end

    -- Put c in the raid with the other clients and Tor, a warrior without
    -- the addon, with the roster update the game sends.
    local function join(c)
        wow.use(c)
        local names = {}
        for _, m in ipairs(clients) do
            if m ~= c then names[#names + 1] = m.full end
        end
        names[#names + 1] = "Tor-Axe"
        wow.setGroup("raid", names)
        for i = 1, #names - 1 do wow.state.units["raid" .. i].class = "PRIEST" end
        wow.state.units["raid" .. #names].class = "WARRIOR"
        wow.addUnit("raid" .. (#names + 1), { name = c.name, surname = c.surname, id = c.full, class = "PRIEST" })
        wow.fire("GROUP_ROSTER_UPDATE")
    end

    -- Put clients in one raid and let the shares go round.
    local function form()
        for _, c in ipairs(clients) do join(c) end
        wow.advanceAll(net, 30, 0.5)
    end

    before_each(function()
        clients = {}
        for _, p in ipairs({ { "Ann", "Vale" }, { "Bob", "Lake" } }) do
            local c = wow.newClient({ name = p[1], surname = p[2], db = { buffBack = { buffOrder = ORDER } },
                before = function(state)
                    state.class = "PRIEST"
                    state.knownSpells = {}
                    for id in pairs(PRIEST_SPELLS) do state.knownSpells[id] = true end
                end })
            c.ns.BuffMode.Set(true)
            clients[#clients + 1] = c
        end
        net = wow.network(clients)
        form()
        wow.use(clients[1])
        realIsInRaid = _G.IsInRaid
    end)

    -- Ann's IsInRaid() answers as given: "secret", a lie (true or false), or
    -- "throws"; nil or "truth" puts the client's own answer back.
    local function answer(how)
        wow.use(clients[1])
        wow.state.inRaidUnreadable = nil
        _G.IsInRaid = realIsInRaid
        if how == "secret" then
            wow.state.inRaidUnreadable = true
        elseif how == "throws" then
            _G.IsInRaid = function() error("IsInRaid: not now") end
        elseif how ~= nil and how ~= "truth" then
            _G.IsInRaid = function() return how end
        end
    end

    it("in a real raid the split works as before (white)", function()
        -- Two priests, three buffs: one gives one, the other two.
        assert.are.equal("fortitude,shadow,spirit", share(clients[1]) .. "," .. share(clients[2]))
        wow.use(clients[1])
        assert.are.equal(1, clients[1].ns.RaidSplit.PeerCount())
    end)

    for _, how in ipairs({ "secret", false, "throws" }) do
        it("a roster update whose IsInRaid() is " .. tostring(how) .. " in a raid doesn't end the split (black)",
            function()
            local before = share(clients[1])
            assert.is_string(before)
            answer(how)
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(1)
            assert.are.equal(1, clients[1].ns.RaidSplit.PeerCount(), "Bob is still a peer")
            -- While it can't be believed: every buff offered, as without the split.
            local mine, why = clients[1].ns.RaidSplit.Current()
            assert.is_nil(mine)
            assert.are.equal("can't tell if you're in a raid", why)
            -- Readable again: the split is back at once (the next frame), not
            -- after a heartbeat.
            answer(nil)
            wow.advance(0.1)
            assert.are.equal(before, share(clients[1]))
            assert.are.same({}, wow.errors)
        end)
    end

    it("a roster update that can't be believed keeps buff mode's grace for this raid (black)", function()
        local split = clients[1].ns.RaidSplit
        wow.use(clients[1])
        clients[1].ns.BuffMode.Set(false)
        wow.advance(10)
        answer("secret")
        wow.fire("GROUP_ROSTER_UPDATE")
        answer(nil)
        wow.fire("GROUP_ROSTER_UPDATE")
        assert.is_string(share(clients[1]), "still taking part, in the grace after buff mode went off")
        -- A believable "not in a raid" still ends it.
        wow.use(clients[1])
        wow.setGroup(nil)
        wow.fire("GROUP_ROSTER_UPDATE")
        assert.are.equal(0, split.PeerCount())
    end)

    -- The architecture review of #439: a leave whose one roster update can't
    -- be read is seen by the next heartbeat, which forgets the raid as the
    -- update would have. Both ways round, the next raid starts afresh.
    for _, how in ipairs({ "truth", "secret" }) do
        it("a leave whose roster update is " .. how .. " forgets the raid: buff mode off since, the next raid "
            .. "doesn't take you in (black)", function()
            answer(how)
            wow.use(clients[1])
            wow.setGroup(nil)
            wow.fire("GROUP_ROSTER_UPDATE")
            answer(nil)
            wow.use(clients[1])
            wow.advance(clients[1].ns.RaidSplit.HEARTBEAT + 1)
            assert.are.equal(0, clients[1].ns.RaidSplit.PeerCount(), "out of the raid: its peers are forgotten")
            clients[1].ns.BuffMode.Set(false)
            wow.advance(600)
            local before = #wow.addonSent
            form()
            -- The new raid's first word from Ann asks the others for theirs
            -- (its last field): what she last said was the old raid's.
            local said = raidTexts(clients[1], before)
            assert.is_truthy(said[1], "Ann says she doesn't take part")
            assert.is_truthy(said[1]:find(";1$"), said[1])
            local mine, why = clients[1].ns.RaidSplit.Current()
            assert.is_nil(mine)
            assert.are.equal("you take part while buff mode is on", why)
            assert.is_nil(share(clients[2]), "Bob covers everything: Ann isn't in the split")
        end)
    end

    it("a leave and a rejoin within one heartbeat leave one heartbeat, not two (black)", function()
        local split = clients[1].ns.RaidSplit
        wow.use(clients[1])
        wow.setGroup(nil)
        wow.fire("GROUP_ROSTER_UPDATE")
        -- Back before the old heartbeat's next beat could see the leave.
        wow.advance(1)
        form()
        local before = raidSends(clients[1])
        wow.use(clients[1])
        local BEATS = 5
        wow.advance(split.HEARTBEAT * BEATS)
        assert.are.equal(BEATS, raidSends(clients[1]) - before, "one share a heartbeat")
    end)

    -- #443: Ann out of any group, her heartbeat stopped, as a leave leaves it.
    local function leave()
        wow.use(clients[1])
        wow.setGroup(nil)
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advanceAll(net, clients[1].ns.RaidSplit.HEARTBEAT + 1, 0.5)
        assert.are.equal(0, clients[1].ns.RaidSplit.PeerCount())
    end

    -- Ann's heartbeats still pending: her C_Timer calls with the split's
    -- HEARTBEAT, made unlike any other timer's delay for the test.
    local function heartbeats()
        wow.use(clients[1])
        local n = 0
        for _, t in ipairs(wow.timers) do
            if t.heartbeat then n = n + 1 end
        end
        return n
    end
    local function markHeartbeats()
        wow.use(clients[1])
        local split, after = clients[1].ns.RaidSplit, _G.C_Timer.After
        split.HEARTBEAT = 61.25
        _G.C_Timer.After = function(delay, fn)
            after(delay, fn)
            if delay == split.HEARTBEAT then wow.timers[#wow.timers].heartbeat = true end
        end
    end

    it("a raid joined on one unreadable roster update, readable after it with no other update: the split forms "
        .. "within one HEARTBEAT + SETTLE, and says it once a HEARTBEAT after that (black, #443)", function()
        local split = clients[1].ns.RaidSplit
        leave()
        answer("secret")
        join(clients[1])
        answer(nil)
        -- No other roster update comes.
        wow.advanceAll(net, split.HEARTBEAT + split.SETTLE, 0.5)
        assert.are.equal(1, clients[1].ns.RaidSplit.PeerCount(), "Ann hears Bob")
        wow.use(clients[2])
        assert.are.equal(1, clients[2].ns.RaidSplit.PeerCount(), "Bob hears Ann")
        assert.are.equal("fortitude,shadow,spirit", share(clients[1]) .. "," .. share(clients[2]))
        local before = raidSends(clients[1])
        local BEATS = 5
        wow.advanceAll(net, split.HEARTBEAT * BEATS, 0.5)
        assert.are.equal(BEATS, raidSends(clients[1]) - before, "one share a heartbeat")
        assert.are.same({}, wow.errors)
    end)

    it("out of any group, an unreadable roster update and then a readable \"not in a raid\" send nothing, and "
        .. "the heartbeat stops at its first beat (black, #443)", function()
        local split = clients[1].ns.RaidSplit
        leave()
        markHeartbeats()
        local sent = #wow.addonSent
        answer("secret")
        wow.use(clients[1])
        wow.fire("GROUP_ROSTER_UPDATE")
        assert.are.equal(1, heartbeats(), "the heartbeat starts")
        answer(nil)
        wow.use(clients[1])
        wow.advance(split.HEARTBEAT + 1)
        assert.are.equal(0, heartbeats(), "its first beat reads \"not in a raid\" and stops it")
        wow.advance(split.HEARTBEAT * 3)
        assert.are.equal(0, heartbeats())
        assert.are.equal(sent, #wow.addonSent, "nothing sent")
        assert.are.same({}, wow.errors)
    end)

    it("while the answer can't be believed nothing is announced; the heartbeat goes on and speaks once it can be "
        .. "(black)", function()
        answer("secret")
        wow.fire("GROUP_ROSTER_UPDATE")
        local sent = raidSends(clients[1])
        wow.use(clients[1])
        wow.advance(clients[1].ns.RaidSplit.HEARTBEAT * 2)
        assert.are.equal(sent, raidSends(clients[1]), "no message while it can't be told")
        answer(nil)
        wow.use(clients[1])
        wow.advance(clients[1].ns.RaidSplit.HEARTBEAT)
        assert.is_true(raidSends(clients[1]) > sent, "the heartbeat says it again")
    end)

    it("a fight that ends while the answer can't be read still says your share once it can (black)", function()
        local split = clients[1].ns.RaidSplit
        answer("secret")
        local sent = raidSends(clients[1])
        wow.use(clients[1])
        split.OnCombatEnd()
        wow.advance(1)
        answer(nil)
        wow.use(clients[1])
        wow.advance(split.SETTLE + split.MIN_GAP)
        assert.is_true(raidSends(clients[1]) > sent, "said again after the fight")
    end)

    it("IsInRaid() true in a party: nothing goes to the raid route, and the peers wait for a believable answer "
        .. "(black)", function()
        wow.use(clients[1])
        wow.setGroup("party", { "Bob-Lake" })
        answer(true)
        local sent = raidSends(clients[1])
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.use(clients[1])
        wow.advance(clients[1].ns.RaidSplit.HEARTBEAT * 2)
        clients[1].ns.RaidSplit.Announce(true)
        wow.advance(clients[1].ns.RaidSplit.SETTLE + clients[1].ns.RaidSplit.MIN_GAP)
        assert.are.equal(sent, raidSends(clients[1]))
        assert.is_nil(clients[1].ns.RaidSplit.Current())
        assert.are.equal(1, clients[1].ns.RaidSplit.PeerCount(), "an answer that can't be believed forgets nobody")
        answer(nil)
        wow.fire("GROUP_ROSTER_UPDATE")
        assert.are.equal(0, clients[1].ns.RaidSplit.PeerCount(), "a believable \"not in a raid\" forgets them")
    end)

    it("a storm where IsInRaid() sometimes lies, throws or can't be read never sends to the raid route out of a "
        .. "raid, and never errors (red)", function()
        local HOWS = { "secret", false, true, "throws", "truth" }
        for _, seed in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8 }) do
            random.seed(seed)
            answer(nil)
            -- What the storm is for: answers that lie "in a raid" out of one,
            -- and messages that do go out in a raid (the split isn't just mute).
            local liesOutside, sendsInRaid = 0, 0
            for _ = 1, 60 do
                wow.use(clients[1])
                local roll = random.random(6)
                if roll == 1 then
                    wow.setGroup("party", { "Bob-Lake" })
                elseif roll == 2 then
                    wow.setGroup(nil)
                elseif roll == 3 then
                    wow.setGroup("raid", { "Bob-Lake", "Tor-Axe" })
                    wow.addUnit("raid3", { name = "Ann", surname = "Vale", id = "Ann-Vale", class = "PRIEST" })
                end
                local how = HOWS[random.random(#HOWS)]
                answer(how)
                local inRaid = wow.state.groupType == "raid"
                if how == true and not inRaid then liesOutside = liesOutside + 1 end
                local sent = raidSends(clients[1])
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.use(clients[1])
                wow.advance(random.random(1, 90))
                if not inRaid then
                    assert.are.equal(sent, raidSends(clients[1]),
                        "seed " .. seed .. ": a raid message while the client's state says no raid")
                elseif raidSends(clients[1]) > sent then
                    sendsInRaid = sendsInRaid + 1
                end
                wow.deliver(net)
            end
            assert.is_true(liesOutside > 0, "seed " .. seed .. " never lied \"in a raid\" out of one")
            assert.is_true(sendsInRaid > 0, "seed " .. seed .. " never sent in a raid")
            wow.use(clients[1])
            assert.are.same({}, wow.errors, "seed " .. seed)
            wow.use(clients[2])
            assert.are.same({}, wow.errors, "seed " .. seed)
        end
    end)
end)
