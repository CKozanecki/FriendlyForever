-- Spec: #400
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
        ns = wow.boot({ before = function(state) state.guildRoster = { "Thrall", "Jaina" } end })
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
        local sentLines, unreadableSteps = 0, 0
        for _, seed in ipairs({ 4, 400, 2026, 31337 }) do
            random.seed(seed)
            boot()
            local sentBefore = 0
            for step = 1, 300 do
                local at = ("seed %d, step %d"):format(seed, step)
                local roll = random.random(1, 12)
                if roll <= 3 then
                    local read = reads[random.random(#reads)]
                    broken[read] = random.random() < 0.5 and ways[random.random(#ways)] or nil
                elseif roll == 4 then
                    joinGroup(({ "party", "raid", "instance" })[random.random(3)],
                        { "Alex-Roberts", "Udders-Healz" })
                elseif roll == 5 then
                    leaveGroup()
                elseif roll == 6 then
                    wow.state.isLeader = true
                    wow.systemMessage("Anduin joins the party.")
                elseif roll == 7 then
                    online("Thrall")
                elseif roll == 8 then
                    if wow.state.groupType then
                        local token = (wow.state.groupType == "party") and "party1" or "raid1"
                        if wow.state.units[token] then wow.levelUp(token, random.random(2, 59)) end
                    end
                elseif roll == 9 then
                    wow.reloadInPlace(true)
                    install()
                else
                    if broken.group or broken.instance or broken.raid then unreadableSteps = unreadableSteps + 1 end
                    wow.advance(random.random(1, 20))
                    wow.keyDown()
                end
                -- What went out this step, checked against the simulated
                -- client's own group, and the answers the addon could read.
                local groupType = wow.state.groupType
                for i = sentBefore + 1, #wow.sent do
                    local channel = wow.sent[i].channel
                    if GROUP_CHANNELS[channel] then
                        sentLines = sentLines + 1
                        assert.is_nil(broken.group, at .. ": a group line while IsInGroup() couldn't be read")
                        assert.is_nil(broken.instance, at .. ": a group line on an unreadable instance answer")
                        assert.is_nil(broken.raid, at .. ": a group line on an unreadable raid answer")
                        local want = (groupType == "instance") and "INSTANCE_CHAT"
                            or (groupType == "raid" and "RAID") or (groupType == "party" and "PARTY") or nil
                        assert.are.equal(want, channel, at .. ": a line to " .. channel)
                    elseif channel == "GUILD" then
                        assert.is_nil(broken.guild, at .. ": a guild line on an unreadable guild answer")
                    end
                end
                sentBefore = #wow.sent
                assert.are.same({}, wow.errors, at)
            end
            restore()
        end
        -- Live: lines went out to groups, and unreadable answers came up.
        assert.is_true(sentLines > 0, "group lines: " .. sentLines)
        assert.is_true(unreadableSteps > 0, "steps with an unreadable answer: " .. unreadableSteps)
    end)
end)
