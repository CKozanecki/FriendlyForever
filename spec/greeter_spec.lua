local wow = require("spec.support.wow")

describe("Greetings", function()
    local ns

    local function online(name)
        wow.systemMessage("|Hplayer:" .. name .. "|h[" .. name .. "]|h has come online.")
    end

    before_each(function()
        ns = wow.boot({ before = function(state) state.guildRoster = { "Thrall", "Jaina" } end })
        wow.fire("GUILD_ROSTER_UPDATE")
        for _, msgType in ipairs(ns.Config.TYPES) do
            ns.db[msgType].messages = { ns.Config.DEFAULTS[msgType].messages[1] }
        end
    end)

    describe("guild login", function()
        it("greets a guild member in guild chat after the delay", function()
            online("Thrall")
            wow.advance(ns.db.guildLogin.delay - 0.5)
            assert.are.equal(0, #wow.sent)
            wow.advance(0.6)
            assert.are.same({ "Thrall has logged in. Quick, everyone look busy." }, wow.sentTo("GUILD"))
        end)

        it("doesn't greet friends who aren't in the guild", function()
            online("Stranger")
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("confirms unknown names against a fresh roster", function()
            local before = wow.rosterRequests
            online("Newbie")
            assert.are.equal(before + 1, wow.rosterRequests)
            wow.state.guildRoster[#wow.state.guildRoster + 1] = "Newbie"
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.advance(ns.db.guildLogin.delay + 0.1)
            assert.are.same({ "Newbie has logged in. Quick, everyone look busy." }, wow.sentTo("GUILD"))
        end)

        it("gives up on a roster confirmation that comes too late", function()
            online("Newbie")
            wow.advance(ns.Greeter.PENDING_TIMEOUT + 1)
            wow.state.guildRoster[#wow.state.guildRoster + 1] = "Newbie"
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't repeat within the cooldown (default 3 minutes)", function()
            online("Thrall")
            wow.advance(5)
            online("Thrall")
            wow.advance(170)
            online("Thrall")
            wow.advance(5)
            assert.are.equal(1, #wow.sent)
            wow.advance(10)
            online("Thrall")
            wow.advance(5)
            assert.are.equal(2, #wow.sent)
        end)

        it("respects a custom repeat cooldown", function()
            ns.db.guildLogin.repeatCooldown = 0
            online("Thrall")
            wow.advance(5)
            online("Thrall")
            wow.advance(5)
            assert.are.equal(2, #wow.sent)
        end)

        it("doesn't greet me", function()
            wow.state.guildRoster[#wow.state.guildRoster + 1] = "Me"
            wow.fire("GUILD_ROSTER_UPDATE")
            online("Me")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't greet while not in a guild", function()
            wow.state.inGuild = false
            online("Thrall")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't greet when switched off", function()
            ns.db.guildLogin.enabled = false
            online("Thrall")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't react during the login grace period", function()
            ns = wow.boot({ noGrace = true, before = function(state) state.guildRoster = { "Thrall" } end })
            wow.fire("GUILD_ROSTER_UPDATE")
            online("Thrall")
            wow.advance(30)
            assert.are.equal(0, #wow.sent)
        end)

        it("paces a login wave instead of flooding guild chat", function()
            for i = 1, 6 do wow.state.guildRoster[#wow.state.guildRoster + 1] = "Member" .. string.char(96 + i) end
            wow.fire("GUILD_ROSTER_UPDATE")
            for i = 1, 6 do online("Member" .. string.char(96 + i)) end
            wow.advance(60)
            assert.are.equal(6, #wow.sent)
            for i = 2, #wow.sent do
                assert.is_true(wow.sent[i].time - wow.sent[i - 1].time >= ns.ChatQueue.MIN_INTERVAL)
            end
        end)

        it("caps the names waiting for roster confirmation", function()
            for i = 1, ns.Greeter.MAX_PENDING + 50 do
                online("Pend" .. string.rep(string.char(97 + i % 26), 1 + math.floor(i / 26)))
            end
            -- Doesn't error and doesn't greet anyone unconfirmed.
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.advance(60)
            assert.are.equal(0, #wow.sent)
        end)
    end)

    describe("guild join", function()
        it("welcomes a new member in guild chat", function()
            wow.systemMessage("Varian has joined the guild.")
            wow.advance(ns.db.guildJoin.delay + 0.1)
            assert.are.same({ "Welcome to the guild, Varian! We're glad to have you." }, wow.sentTo("GUILD"))
        end)

        it("treats the newcomer as a member for later logins", function()
            wow.systemMessage("Varian has joined the guild.")
            wow.advance(10)
            online("Varian")
            wow.advance(10)
            assert.are.same({ "Welcome to the guild, Varian! We're glad to have you.", "Varian has logged in. Quick, everyone look busy." },
                wow.sentTo("GUILD"))
        end)

        it("can be switched off", function()
            ns.db.guildJoin.enabled = false
            wow.systemMessage("Varian has joined the guild.")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)
    end)

    describe("party join", function()
        local function join(name, groupType)
            wow.setGroup(groupType or "party", { name })
        end

        it("welcomes in party chat", function()
            join("Anduin")
            wow.systemMessage("Anduin joins the party.")
            wow.advance(ns.db.partyJoin.delay + 0.1)
            assert.are.same({ "Welcome to the group, Anduin!" }, wow.sentTo("PARTY"))
        end)

        it("uses raid chat in a raid, after the merge window", function()
            join("Sylvanas", "raid")
            wow.systemMessage("Sylvanas has joined the raid group.")
            wow.advance(ns.Greeter.RAID_MERGE_WINDOW - 0.5)
            assert.are.equal(0, #wow.sent)
            wow.advance(0.6)
            assert.are.same({ "Welcome to the group, Sylvanas!" }, wow.sentTo("RAID"))
        end)

        -- Classic Era has no group finder: its instance groups are battlegrounds.
        it("doesn't welcome anyone in a battleground (raid-sized instance group)", function()
            wow.state.inInstance, wow.state.instanceType = true, "pvp"
            wow.setGroup("instance", { "Varian-Wrynn", "Jaina-Proudmoore", "Thrall-Durotan" }, true)
            wow.systemMessage("Varian Wrynn has joined the instance group.")
            wow.systemMessage("Jaina Proudmoore has joined the raid group.")
            wow.advance(30)
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't welcome in a battleground the game doesn't call an instance group", function()
            wow.state.inInstance, wow.state.instanceType = true, "pvp"
            wow.setGroup("raid", { "Varian-Wrynn", "Jaina-Proudmoore" })
            wow.systemMessage("Varian Wrynn has joined the raid group.")
            wow.advance(30)
            assert.are.equal(0, #wow.sent)
        end)

        it("still welcomes in a raid dungeon", function()
            wow.state.inInstance = true
            join("Sylvanas-Windrunner", "raid")
            wow.systemMessage("Sylvanas Windrunner has joined the raid group.")
            wow.advance(30)
            assert.are.same({ "Welcome to the group, Sylvanas!" }, wow.sentTo("RAID"))
        end)

        describe("raid joins close together", function()
            local names = { "Ann-Aa", "Bob-Bb", "Cid-Cc", "Dot-Dd", "Eve-Ee" }

            local function joinRaid(list)
                wow.setGroup("raid", list)
            end

            local function raidJoin(full)
                wow.systemMessage(full:gsub("%-", " ") .. " has joined the raid group.")
            end

            it("share one welcome line", function()
                joinRaid(names)
                for _, full in ipairs(names) do
                    raidJoin(full)
                    wow.advance(1)
                end
                wow.advance(10)
                assert.are.same({ "Welcome to the group, Ann, Bob, Cid, Dot and Eve!" }, wow.sentTo("RAID"))
            end)

            it("list everyone in {fullname} too", function()
                ns.db.partyJoin.messages = { "Hi {fullname}!" }
                joinRaid(names)
                raidJoin(names[1])
                raidJoin(names[2])
                wow.advance(10)
                assert.are.same({ "Hi Ann Aa and Bob Bb!" }, wow.sentTo("RAID"))
            end)

            it("start a new line for a join after the welcome went out", function()
                joinRaid(names)
                raidJoin(names[1])
                raidJoin(names[2])
                wow.advance(10)
                raidJoin(names[3])
                wow.advance(10)
                assert.are.same({ "Welcome to the group, Ann and Bob!", "Welcome to the group, Cid!" },
                    wow.sentTo("RAID"))
            end)

            it("leave out someone who left before it was sent", function()
                joinRaid(names)
                raidJoin(names[1])
                raidJoin(names[2])
                raidJoin(names[3])
                joinRaid({ names[1], names[3] }) -- Bob left
                wow.advance(10)
                assert.are.same({ "Welcome to the group, Ann and Cid!" }, wow.sentTo("RAID"))
            end)

            it("send nothing if everyone in it left", function()
                joinRaid(names)
                raidJoin(names[1])
                raidJoin(names[2])
                joinRaid({ names[3] })
                wow.advance(10)
                assert.are.equal(0, #wow.sent)
            end)

            it("keep each player's repeat cooldown", function()
                joinRaid(names)
                raidJoin(names[1])
                wow.advance(10)
                raidJoin(names[2])
                raidJoin(names[1]) -- left and came back
                wow.advance(10)
                assert.are.same({ "Welcome to the group, Ann!", "Welcome to the group, Bob!" }, wow.sentTo("RAID"))
            end)

            it("don't welcome the party again when it becomes a raid", function()
                wow.state.isLeader = true
                wow.setGroup("party", { names[1], names[2] })
                wow.fire("GROUP_ROSTER_UPDATE")
                joinRaid({ names[1], names[2] })
                wow.fire("GROUP_ROSTER_UPDATE")
                raidJoin(names[1])
                raidJoin(names[2])
                joinRaid({ names[1], names[2], names[3] })
                wow.fire("GROUP_ROSTER_UPDATE")
                raidJoin(names[3])
                wow.advance(10)
                assert.are.same({ "Welcome to the group, Cid!" }, wow.sentTo("RAID"))
            end)
        end)

        it("doesn't welcome someone who left before the delay ran out", function()
            join("Anduin")
            wow.systemMessage("Anduin joins the party.")
            wow.setGroup("party", {}) -- Anduin left again
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't send if the group broke up", function()
            join("Anduin")
            wow.systemMessage("Anduin joins the party.")
            wow.state.groupType = nil
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("waits for the chat lockdown to end", function()
            join("Anduin")
            wow.state.lockdown = true
            wow.systemMessage("Anduin joins the party.")
            wow.advance(30)
            assert.are.equal(0, #wow.sent)
            wow.state.lockdown = false
            wow.advance(ns.ChatQueue.RETRY_DELAY)
            assert.are.same({ "Welcome to the group, Anduin!" }, wow.sentTo("PARTY"))
        end)

        -- In-game: "Sorum Md joins the party." was dropped as "no longer
        -- wanted" because the group check was asked about "Sorum-Md" by name.
        it("welcomes a Forever-named player who is in a group slot (the in-game bug)", function()
            wow.setGroup("party", { "Dax-Windstrike", "Smoakkin-Chaos", "Sorum-Md" })
            wow.systemMessage("Sorum Md joins the party.")
            wow.advance(ns.db.partyJoin.delay + 0.1)
            assert.are.same({ "Welcome to the group, Sorum!" }, wow.sentTo("PARTY"))
        end)

        it("finds the newcomer anywhere in a raid", function()
            local names = {}
            for i = 1, 25 do names[i] = "Member-" .. string.rep(string.char(96 + (i % 26) + 1), 3) end
            names[25] = "Varian-Wrynn"
            wow.setGroup("raid", names)
            wow.systemMessage("Varian Wrynn has joined the raid group.")
            wow.advance(ns.Greeter.RAID_MERGE_WINDOW + 0.1)
            assert.are.same({ "Welcome to the group, Varian!" }, wow.sentTo("RAID"))
        end)

        it("says exactly why a welcome was dropped", function()
            ns.db.debug = true
            join("Anduin-Wrynn")
            wow.systemMessage("Anduin Wrynn joins the party.")
            wow.setGroup("party", {})
            wow.advance(10)
            local found
            for _, line in ipairs(ns.db.diagLog) do
                if line:find("dropped partyJoin for Anduin-Wrynn: no longer wanted: Anduin-Wrynn is no longer in your group", 1, true) then
                    found = true
                end
            end
            assert.is_true(found)
        end)

        it("keeps the welcome if names can't be read (combat)", function()
            join("Anduin-Wrynn")
            wow.systemMessage("Anduin Wrynn joins the party.")
            wow.state.unitsRestricted = true
            wow.advance(10)
            assert.are.equal(1, #wow.sentTo("PARTY"))
        end)

        it("can be switched off", function()
            ns.db.partyJoin.enabled = false
            join("Anduin")
            wow.systemMessage("Anduin joins the party.")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)
    end)

    describe("party hello (joining someone else's group)", function()
        -- The first name listed leads, unless isLeader says I do.
        local function joinGroup(groupType, names, isLeader)
            names = names or { "Alex-Roberts" }
            wow.state.isLeader = isLeader
            wow.state.leader = not isLeader and names[1] or nil
            wow.setGroup(groupType or "party", names)
            wow.fire("GROUP_ROSTER_UPDATE")
        end

        local function leaveGroup()
            wow.setGroup(nil, {})
            wow.fire("GROUP_ROSTER_UPDATE")
        end

        it("says hello in party chat after the delay", function()
            joinGroup()
            wow.advance(ns.db.partyHello.delay - 0.5)
            assert.are.equal(0, #wow.sent)
            wow.advance(0.6)
            assert.are.same({ "Hi all! Thanks for the invite." }, wow.sentTo("PARTY"))
        end)

        it("uses raid chat when joining a raid", function()
            joinGroup("raid")
            wow.advance(10)
            assert.are.same({ "Hi all! Thanks for the invite." }, wow.sentTo("RAID"))
        end)

        it("says hello once, not on every later roster change", function()
            joinGroup()
            wow.advance(10)
            wow.setGroup("party", { "Alex-Roberts", "Udders-Healz" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(10)
            assert.are.same({ "Hi all! Thanks for the invite." }, wow.sentTo("PARTY"))
        end)

        it("doesn't say hello when someone accepts my invite (I lead)", function()
            joinGroup("party", { "Anduin" }, true)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't say hello in a battleground (instance group)", function()
            joinGroup("instance")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't say hello in a battleground the game doesn't call an instance group", function()
            wow.state.inInstance, wow.state.instanceType = true, "pvp"
            joinGroup("raid")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't say hello if leadership can't be read (combat)", function()
            wow.state.unitsRestricted = true
            joinGroup()
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't send if I left before the delay ran out", function()
            joinGroup()
            wow.state.groupType = nil
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        -- In-game: joined Rlain's group, left, and joined Allister's 27s later;
        -- the second hello was skipped by a single 180s cooldown for all groups.
        it("says hello to a second, different group right away (the in-game bug)", function()
            joinGroup("party", { "Rlain-Stormblessed" })
            wow.advance(10)
            leaveGroup()
            wow.advance(17)
            joinGroup("party", { "Allister-Reaper" })
            wow.advance(10)
            assert.are.same({ "Hi all! Thanks for the invite.", "Hi all! Thanks for the invite." },
                wow.sentTo("PARTY"))
        end)

        it("says hello again when rejoining the same leader's group", function()
            joinGroup()
            wow.advance(10)
            leaveGroup()
            wow.advance(ns.db.partyHello.repeatCooldown)
            joinGroup()
            wow.advance(10)
            assert.are.same({ "Hi all! Thanks for the invite.", "Nice to see you all again!" }, wow.sentTo("PARTY"))
        end)

        it("says a plain hello to each group whose leader can't be read", function()
            wow.state.leaderUnreadable = true
            joinGroup("party", { "Rlain-Stormblessed" })
            wow.advance(10)
            leaveGroup()
            wow.advance(ns.db.partyHello.repeatCooldown + 30)
            joinGroup("party", { "Allister-Reaper" })
            wow.advance(10)
            leaveGroup()
            wow.advance(5) -- well within the repeat cooldown
            joinGroup("party", { "Kaladin-Stormblessed" })
            wow.advance(10)
            assert.are.same({ "Hi all! Thanks for the invite.", "Hi all! Thanks for the invite.",
                "Hi all! Thanks for the invite." }, wow.sentTo("PARTY"))
        end)

        it("decides on hello again after the delay, when the leader can be read", function()
            joinGroup()
            wow.advance(10)
            leaveGroup()
            wow.advance(ns.db.partyHello.repeatCooldown)
            wow.state.leaderUnreadable = true
            joinGroup()
            wow.advance(1)
            wow.state.leaderUnreadable = false
            wow.advance(10)
            assert.are.same({ "Hi all! Thanks for the invite.", "Nice to see you all again!" }, wow.sentTo("PARTY"))
        end)

        it("doesn't carry a hello over to a group I form before the delay runs out", function()
            joinGroup()
            leaveGroup()
            wow.advance(1)
            joinGroup("party", { "Anduin" }, true)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't repeat for a rapid leave and rejoin of the same group", function()
            joinGroup()
            wow.advance(10)
            leaveGroup()
            joinGroup()
            wow.advance(10)
            assert.are.equal(1, #wow.sent)
        end)

        it("uses the normal hello when Hello Again is switched off", function()
            ns.db.partyHelloAgain.enabled = false
            ns.db.partyHello.repeatCooldown = 0
            joinGroup()
            wow.advance(10)
            leaveGroup()
            joinGroup()
            wow.advance(10)
            assert.are.equal(2, #wow.sentTo("PARTY"))
            assert.are.equal("Hi all! Thanks for the invite.", wow.sentTo("PARTY")[2])
        end)

        it("doesn't say hello after a reload while already grouped", function()
            ns = wow.boot({ before = function(state)
                state.groupType = "party"
                state.groupMembers = { ["Alex-Roberts"] = true }
            end })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("can be switched off", function()
            ns.db.partyHello.enabled = false
            joinGroup()
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)
    end)

    it("the master switch silences everything", function()
        ns.db.enabled = false
        online("Thrall")
        wow.systemMessage("Varian has joined the guild.")
        wow.advance(30)
        assert.are.equal(0, #wow.sent)
    end)

    it("a message turned off after scheduling is not sent", function()
        online("Thrall")
        ns.db.guildLogin.enabled = false
        wow.advance(10)
        assert.are.equal(0, #wow.sent)
    end)
end)
