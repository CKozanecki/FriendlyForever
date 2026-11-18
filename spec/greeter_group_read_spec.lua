-- Spec: #400, #459
-- Greeter and LevelUps read IsInGroup(), IsInRaid() and IsInGuild() through
-- Util.ReadGameValues. An answer that can't be read (a secret, nil, a number,
-- an error) never errors, is never tested, and decides no greeting: no line
-- on a route the game may not accept, and no join or leave seen across it.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

-- The ways a yes-or-no answer can't be read.
local UNREADABLE = {
    ["a secret true"] = function() return wow.secret(true) end,
    ["a secret false"] = function() return wow.secret(false) end,
    nothing = function() return nil end,
    ["a number"] = function() return 1 end,
    ["an error"] = function() error("blocked") end,
}

local GROUP_CHANNELS = { PARTY = true, RAID = true, INSTANCE_CHAT = true }

describe("Greetings when the game's group answers can't be read (#400)", function()
    local ns
    local real = {}

    -- Which reads give an unreadable answer, and which way: [read] = way.
    -- "group" is IsInGroup() with no category, "instance" IsInGroup with the
    -- instance category, "raid" IsInRaid(), "guild" IsInGuild().
    local broken = {}

    local wrappers = {}

    -- Wraps the simulated client's answers; a reload in place keeps the
    -- wrappers, so they are never wrapped again.
    local function install()
        if wrappers[_G.IsInGroup] then return end
        real.IsInGroup, real.IsInRaid, real.IsInGuild = _G.IsInGroup, _G.IsInRaid, _G.IsInGuild
        _G.IsInGroup = function(category, ...)
            local which = category == nil and "group" or "instance"
            if broken[which] then return UNREADABLE[broken[which]]() end
            return real.IsInGroup(category, ...)
        end
        _G.IsInRaid = function(...)
            if broken.raid then return UNREADABLE[broken.raid]() end
            return real.IsInRaid(...)
        end
        _G.IsInGuild = function(...)
            if broken.guild then return UNREADABLE[broken.guild]() end
            return real.IsInGuild(...)
        end
        wrappers[_G.IsInGroup], wrappers[_G.IsInRaid], wrappers[_G.IsInGuild] = true, true, true
    end

    local function restore()
        _G.IsInGroup, _G.IsInRaid, _G.IsInGuild = real.IsInGroup, real.IsInRaid, real.IsInGuild
        broken = {}
    end

    local function boot()
        -- No level until a test gives one (#459's default of 60 off), as level-ups expect.
        ns = wow.boot({ defaultLevel = false, before = function(state) state.guildRoster = { "Thrall", "Jaina" } end })
        wow.fire("GUILD_ROSTER_UPDATE")
        for _, msgType in ipairs(ns.Config.TYPES) do
            ns.db[msgType].messages = { ns.CasualMessages[msgType][1] } -- fixed wording
        end
        install()
    end

    before_each(boot)
    after_each(restore)

    -- Joining someone else's group: the first name leads.
    local function joinGroup(groupType, names)
        names = names or { "Alex-Roberts" }
        wow.state.isLeader = false
        wow.state.leader = names[1]
        wow.setGroup(groupType or "party", names)
        wow.fire("GROUP_ROSTER_UPDATE")
    end

    local function leaveGroup()
        wow.setGroup(nil, {})
        wow.fire("GROUP_ROSTER_UPDATE")
    end

    local function groupLines()
        local out = {}
        for _, record in ipairs(wow.sent) do
            if GROUP_CHANNELS[record.channel] then out[#out + 1] = record end
        end
        return out
    end

    local function online(name)
        wow.systemMessage("|Hplayer:" .. name .. "|h[" .. name .. "]|h has come online.")
    end

    describe("readable answers (white)", function()
        it("says hello in party chat on joining a party, and in raid chat on joining a raid", function()
            joinGroup("party")
            wow.advance(10)
            assert.are.same({ "Hi all! Thanks for the invite." }, wow.sentTo("PARTY"))
            leaveGroup()
            wow.advance(ns.db.partyHello.repeatCooldown + 1)
            joinGroup("raid", { "Bree-Stone" })
            wow.advance(10)
            assert.are.same({ "Hi all! Thanks for the invite." }, wow.sentTo("RAID"))
            assert.are.same({}, wow.errors)
        end)

        it("welcomes a party joiner, and greets a guildmate in guild chat", function()
            wow.state.isLeader = true
            wow.setGroup("party", { "Anduin" })
            wow.systemMessage("Anduin joins the party.")
            wow.advance(ns.Greeter.PARTY_MERGE_WINDOW + 0.1)
            assert.are.same({ "Welcome to the group, Anduin!" }, wow.sentTo("PARTY"))
            online("Thrall")
            wow.advance(30)
            assert.are.equal(1, #wow.sentTo("GUILD"))
            assert.are.same({}, wow.errors)
        end)

        it("says the group chat route in /friendly status, and none out of a group", function()
            assert.is_nil(ns.Greeter.GroupChannel())
            _G.SlashCmdList.FRIENDLYFOREVER("status")
            assert.is_truthy(table.concat(wow.printed, "\n"):find("group chat channel: none (not grouped)", 1, true))
            joinGroup("party")
            assert.are.equal("PARTY", ns.Greeter.GroupChannel())
            joinGroup("raid")
            assert.are.equal("RAID", ns.Greeter.GroupChannel())
        end)
    end)

    -- You lead a party with Alex in it, and it becomes a raid with Bree too.
    -- between() runs while it's still a party, as seen; during() while the
    -- raid is formed and before its roster update reads clean.
    local function partyBecomesRaid(between, during)
        wow.state.isLeader = true
        wow.setGroup("party", { "Alex-Roberts" })
        wow.fire("GROUP_ROSTER_UPDATE")
        if between then between() end
        wow.advance(ns.Announcer.LOGIN_GRACE + 1) -- past a reload's grace
        wow.setGroup("raid", { "Alex-Roberts", "Bree-Stone" })
        if during then during() end
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.systemMessage("Alex Roberts has joined the raid group.")
        wow.systemMessage("Bree Stone has joined the raid group.")
        wow.advance(ns.Greeter.RAID_MERGE_WINDOW + 1)
        return wow.sentTo("RAID")
    end

    it("a party that becomes a raid welcomes only the new member, as before (white)", function()
        assert.are.same({ "Welcome to the group, Bree!" }, partyBecomesRaid())
        assert.are.same({}, wow.errors)
    end)

    it("a hello after a reload goes out when the group reads, as before (white)", function()
        wow.reloadInPlace(true)
        wow.advance(ns.Announcer.LOGIN_GRACE + 1)
        joinGroup("party")
        wow.advance(30)
        assert.are.same({ "Hi all! Thanks for the invite." }, wow.sentTo("PARTY"))
    end)

    for way in pairs(UNREADABLE) do
        describe("an answer read as " .. way .. " (black)", function()
            it("IsInGroup() at joining: no hello, then or once it reads again", function()
                broken.group = way
                joinGroup("party")
                wow.advance(10)
                broken.group = nil
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.advance(30)
                assert.are.same({}, groupLines(), "no join seen across an unreadable answer")
                assert.are.same({}, wow.errors)
            end)

            it("IsInGroup() at login: no hello decided on it when the group then reads", function()
                broken.group = way
                wow.reloadInPlace(true)
                broken.group = nil
                wow.advance(ns.Announcer.LOGIN_GRACE + 1)
                joinGroup("party")
                wow.advance(30)
                assert.are.same({}, groupLines())
                assert.are.same({}, wow.errors)
            end)

            it("IsInGroup() on a roster change drops a hello still waiting, even once it reads again", function()
                joinGroup("party")
                broken.group = way
                wow.fire("GROUP_ROSTER_UPDATE")
                broken.group = nil
                wow.advance(30)
                assert.are.same({}, groupLines())
                assert.are.same({}, wow.errors)
            end)

            for _, groupType in ipairs({ "party", "raid" }) do
                it("IsInGroup() just before a " .. groupType .. " hello goes out: no hello", function()
                    joinGroup(groupType, { "Bree-Stone" })
                    wow.advance(ns.db.partyHello.delay - 0.5)
                    broken.group = way
                    wow.advance(30)
                    assert.are.same({}, groupLines())
                    assert.are.same({}, wow.errors)
                end)
            end

            for _, read in ipairs({ "group", "instance", "raid" }) do
                it("the " .. read .. " read on the chat route: no route, and no line", function()
                    joinGroup("party")
                    broken[read] = way
                    assert.is_nil(ns.Greeter.GroupChannel())
                    wow.advance(30)
                    assert.are.same({}, groupLines())
                    assert.are.same({}, wow.errors)
                end)
            end

            for _, read in ipairs({ "group", "raid" }) do
                it("the " .. read .. " read: /friendly status says the game won't say, not that you aren't grouped",
                    function()
                        joinGroup("party")
                        broken[read] = way
                        _G.SlashCmdList.FRIENDLYFOREVER("status")
                        local printed = table.concat(wow.printed, "\n")
                        assert.is_truthy(printed:find(
                            "group chat channel: none (the game won't say which group you're in)", 1, true))
                        assert.are.same({}, wow.errors)
                    end)
            end

            it("the instance read: counted as a battleground, so greetings stay quiet", function()
                broken.instance = way
                assert.is_true(ns.Greeter.InBattleground())
                assert.are.same({}, wow.errors)
            end)

            it("IsInRaid() on a party join line: no welcome decided on it, even once it reads again", function()
                wow.state.isLeader = false
                wow.state.leader = "Bree-Stone"
                wow.setGroup("party", { "Bree-Stone", "Anduin" })
                broken.raid = way
                wow.systemMessage("Anduin joins the party.")
                broken.raid = nil
                wow.advance(ns.Greeter.RAID_MERGE_WINDOW + 30)
                assert.are.same({}, groupLines())
                assert.are.same({}, wow.errors)
            end)

            it("IsInRaid() while walking the group: can't tell who's in it or who leads", function()
                joinGroup("party", { "Alex-Roberts", "Udders-Healz" })
                broken.raid = way
                assert.is_nil(ns.Greeter.IsInMyGroup("Udders-Healz"))
                assert.is_nil(ns.Greeter.GroupLeaderName())
                assert.are.same({}, wow.errors)
            end)

            it("IsInGroup() while a party becomes a raid: its members aren't welcomed again", function()
                local lines = partyBecomesRaid(function()
                    broken.group = way
                    wow.fire("GROUP_ROSTER_UPDATE")
                    broken.group = nil
                end)
                assert.are.same({ "Welcome to the group, Bree!" }, lines)
                assert.are.same({}, wow.errors)
            end)

            it("IsInRaid() while a party becomes a raid: its members aren't welcomed again", function()
                local lines = partyBecomesRaid(nil, function()
                    broken.raid = way
                    wow.fire("GROUP_ROSTER_UPDATE")
                    broken.raid = nil
                end)
                assert.are.same({ "Welcome to the group, Bree!" }, lines)
                assert.are.same({}, wow.errors)
            end)

            it("IsInRaid() at login, then the party becomes a raid: its members aren't welcomed again", function()
                local lines = partyBecomesRaid(function()
                    broken.raid = way
                    wow.reloadInPlace(true)
                    broken.raid = nil
                end)
                assert.are.same({ "Welcome to the group, Bree!" }, lines)
                assert.are.same({}, wow.errors)
            end)

            it("IsInGuild() when a guildmate comes online: no greeting, even once it reads again", function()
                broken.guild = way
                online("Thrall")
                broken.guild = nil
                wow.advance(30)
                assert.are.same({}, wow.sentTo("GUILD"))
                assert.are.same({}, wow.errors)
            end)

            it("IsInGuild() just before a guild greeting goes out: no greeting", function()
                online("Thrall")
                wow.advance(ns.db.guildLogin.delay + ns.GuildHellos.STAGGER_MIN + wow.ADDON_ECHO_DELAY - 0.1)
                assert.are.same({}, wow.sentTo("GUILD"), "not yet")
                broken.guild = way
                wow.advance(30)
                assert.are.same({}, wow.sentTo("GUILD"))
                assert.are.same({}, wow.errors)
            end)

            it("IsInGuild() on a roster update: the roster isn't taken from it", function()
                assert.is_true(ns.Greeter.IsGuildMember("Thrall"))
                broken.guild = way
                wow.fire("GUILD_ROSTER_UPDATE")
                assert.is_false(ns.Greeter.IsGuildMember("Thrall"))
                assert.are.same({}, wow.errors)
            end)

            for _, read in ipairs({ "group", "raid" }) do
                it("the " .. read .. " read for a level-up: not allowed, and no congratulation", function()
                    wow.state.isLeader = true
                    wow.setGroup("party", { "Alex-Roberts" })
                    wow.state.units.party1.level = 10
                    wow.fire("GROUP_ROSTER_UPDATE")
                    assert.is_true(ns.LevelUps.Allowed())
                    broken[read] = way
                    local ok, why = ns.LevelUps.Allowed()
                    assert.is_false(ok)
                    assert.is_truthy(why:find("can't tell", 1, true), why)
                    wow.levelUp("party1", 11)
                    wow.advance(ns.db.levelUp.delay + 1)
                    assert.are.same({}, groupLines())
                    assert.are.same({}, wow.errors)
                end)
            end
        end)
    end

    it("a storm of joins, leaves, reloads and greetings with the group answers sometimes unreadable never errors, "
        .. "and never sends to a route the group isn't on (red)", function()
        local ways = {}
        for way in pairs(UNREADABLE) do ways[#ways + 1] = way end
        table.sort(ways)
        local reads = { "group", "instance", "raid", "guild" }
        -- Leaders and joiners from a pool, so repeat cooldowns don't silence
        -- the storm after its first greeting.
        local LEADERS = { "Alex-Roberts", "Bree-Stone", "Cid-Moss", "Dot-Reed", "Eve-Hart" }
        local JOINERS = { "Anduin", "Jaina", "Varian" }
        -- What went out, read from the simulated client: by kind and by route.
        local seen = { hello = 0, welcome = 0, levelUp = 0, guild = 0, PARTY = 0, RAID = 0, INSTANCE_CHAT = 0,
            unreadableGroupReads = 0, dueWhileUnreadable = 0 }
        for _, seed in ipairs({ 4, 400, 2026, 31337 }) do
            random.seed(seed)
            boot()
            -- Every join greets, whoever leads.
            ns.db.partyHello.repeatCooldown, ns.db.partyHelloAgain.repeatCooldown = 0, 0
            -- Count IsInGroup() asked while it can't be read, from the wrapper's own state.
            local wrapped = _G.IsInGroup
            _G.IsInGroup = function(category, ...)
                if category == nil and broken.group then seen.unreadableGroupReads = seen.unreadableGroupReads + 1 end
                return wrapped(category, ...)
            end
            local levels = {}
            local sentBefore = 0
            -- What went out since the last check, checked against the
            -- simulated client's own group and the answers the addon could read.
            local function checkSent(at)
                local groupType = wow.state.groupType
                for i = sentBefore + 1, #wow.sent do
                    local record = wow.sent[i]
                    local channel, text = record.channel, record.text or ""
                    if GROUP_CHANNELS[channel] then
                        seen[channel] = seen[channel] + 1
                        -- The reads each line depends on: its route (the
                        -- instance answer, then raid, then group), and the
                        -- group answer a hello or a level-up checks itself.
                        local kind = "levelUp"
                        if text:find("Thanks for the invite", 1, true) or text:find("again", 1, true) then
                            kind = "hello"
                        elseif text:find("Welcome", 1, true) then
                            kind = "welcome"
                        end
                        seen[kind] = seen[kind] + 1
                        assert.is_nil(broken.instance, at .. ": a group line on an unreadable instance answer")
                        if channel ~= "INSTANCE_CHAT" or kind == "levelUp" then
                            assert.is_nil(broken.raid, at .. ": a " .. kind .. " on an unreadable raid answer")
                        end
                        if channel == "PARTY" or kind ~= "welcome" then
                            assert.is_nil(broken.group, at .. ": a " .. kind .. " while IsInGroup() couldn't be read")
                        end
                        local want = (groupType == "instance") and "INSTANCE_CHAT"
                            or (groupType == "raid" and "RAID") or (groupType == "party" and "PARTY") or nil
                        assert.are.equal(want, channel, at .. ": a line to " .. channel .. ": " .. text)
                    elseif channel == "GUILD" then
                        seen.guild = seen.guild + 1
                        assert.is_nil(broken.guild, at .. ": a guild line on an unreadable guild answer")
                    end
                end
                sentBefore = #wow.sent
            end
            for step = 1, 600 do
                local at = ("seed %d, step %d"):format(seed, step)
                -- Mostly time passing, so greetings fall due under every answer.
                local roll = random.random(1, 24)
                if roll <= 3 then
                    local read = reads[random.random(#reads)]
                    broken[read] = random.random() < 0.3 and ways[random.random(#ways)] or nil
                elseif roll == 4 then
                    local names = { LEADERS[random.random(#LEADERS)] }
                    for _, joiner in ipairs(JOINERS) do names[#names + 1] = joiner end
                    joinGroup(({ "party", "party", "raid", "instance" })[random.random(4)], names)
                    levels = {}
                elseif roll == 5 then
                    leaveGroup()
                elseif roll == 6 then
                    -- Someone already in the group joins, as the game reports it.
                    wow.state.isLeader = true
                    local who = JOINERS[random.random(#JOINERS)]
                    wow.systemMessage(wow.state.groupType == "raid" and (who .. " has joined the raid group.")
                        or (who .. " joins the party."))
                elseif roll == 7 then
                    online("Thrall")
                elseif roll == 8 then
                    if wow.state.groupType then
                        local token = (wow.state.groupType == "raid" or wow.state.raidSized) and "raid1" or "party1"
                        local unit = wow.state.units[token]
                        if unit then
                            levels[token] = (levels[token] or unit.level or 10) + 1
                            wow.levelUp(token, math.min(levels[token], 59))
                        end
                    end
                elseif roll == 9 and random.random() < 0.3 then
                    wow.reloadInPlace(true)
                elseif roll == 10 then
                    -- A hello falls due while one answer it needs can't be read:
                    -- join cleanly, then one read breaks before it goes out.
                    for read in pairs(broken) do broken[read] = nil end
                    leaveGroup()
                    local names = { LEADERS[random.random(#LEADERS)] }
                    for _, joiner in ipairs(JOINERS) do names[#names + 1] = joiner end
                    joinGroup(({ "party", "raid" })[random.random(2)], names)
                    wow.advance(math.max(0, math.min(ns.db.partyHello.delay, ns.db.partyHelloAgain.delay) - 0.5))
                    checkSent(at .. ", before the read breaks")
                    broken[reads[random.random(3)]] = ways[random.random(#ways)]
                    seen.dueWhileUnreadable = seen.dueWhileUnreadable + 1
                else
                    wow.advance(random.random(1, 20))
                    wow.keyDown()
                end
                checkSent(at)
                assert.are.same({}, wow.errors, at)
            end
            restore()
        end
        -- Live: every kind of greeting went out, on the party and raid
        -- routes, and IsInGroup() was asked while it couldn't be read.
        for _, key in ipairs({ "hello", "welcome", "levelUp", "guild", "PARTY", "RAID", "unreadableGroupReads",
            "dueWhileUnreadable" }) do
            assert.is_true(seen[key] > 0, key .. ": " .. seen[key])
        end
    end)
end)
