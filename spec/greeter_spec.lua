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

        -- Issue #7: a roster update that came before the refreshed roster
        -- used to drop the pending name, so the greeting was lost.
        it("keeps a pending login through a roster update that doesn't list it yet", function()
            online("Newbie")
            wow.rosterUpdate({ "Thrall", "Jaina" })
            assert.are.equal(1, ns.Greeter.PendingCount())
            wow.rosterUpdate({ "Thrall", "Jaina", "Newbie" })
            wow.advance(ns.db.guildLogin.delay + 0.1)
            assert.are.same({ "Newbie has logged in. Quick, everyone look busy." }, wow.sentTo("GUILD"))
            -- Exactly once, however many updates follow.
            wow.rosterUpdate({ "Thrall", "Jaina", "Newbie" })
            wow.advance(ns.Greeter.PENDING_TIMEOUT)
            assert.are.equal(1, #wow.sent)
            assert.are.equal(0, ns.Greeter.PendingCount())
        end)

        it("greets with Show Offline Members off, when updates arrive out of order", function()
            wow.state.showOffline = false
            wow.state.guildOffline = { Newbie = true }
            wow.rosterUpdate({ "Thrall", "Jaina", "Newbie" })
            assert.are.equal(2, ns.Greeter.MemberCount(), "only online members are listed")

            wow.state.rosterReplyDelay = 2 -- the server answers our request after 2s
            online("Newbie")
            wow.queueRosterUpdate({ "Thrall", "Jaina", "Newbie" }, 1) -- stale, from someone else's request
            wow.advance(1)
            assert.are.equal(1, ns.Greeter.PendingCount())
            wow.state.guildOffline = {}
            wow.advance(1 + ns.db.guildLogin.delay + 0.1)
            assert.are.same({ "Newbie has logged in. Quick, everyone look busy." }, wow.sentTo("GUILD"))
        end)

        it("never greets a friend outside the guild, and forgets them after the timeout", function()
            ns.db.debug = true
            online("Stranger")
            wow.rosterUpdate({ "Thrall", "Jaina" })
            wow.rosterUpdate({ "Thrall", "Jaina" })
            assert.are.equal(1, ns.Greeter.PendingCount())
            -- No further roster update: the timeout alone cleans up.
            wow.advance(ns.Greeter.PENDING_TIMEOUT)
            assert.are.equal(0, ns.Greeter.PendingCount())
            local logged = false
            for _, line in ipairs(ns.db.diagLog) do
                if line:find("Stranger is not in the guild roster (a friend?)", 1, true) then logged = true end
            end
            assert.is_true(logged)
            wow.advance(30)
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't greet a name confirmed after the timeout, even with roster updates in between", function()
            online("Newbie")
            wow.rosterUpdate({ "Thrall", "Jaina" })
            wow.advance(ns.Greeter.PENDING_TIMEOUT - 1)
            wow.rosterUpdate({ "Thrall", "Jaina" })
            wow.advance(2)
            wow.rosterUpdate({ "Thrall", "Jaina", "Newbie" })
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("keeps a relog within the timeout pending until its own timeout", function()
            online("Newbie")
            wow.advance(20)
            online("Newbie") -- logged out and back in
            wow.advance(ns.Greeter.PENDING_TIMEOUT - 20 + 1) -- the first login's timer has run
            assert.are.equal(1, ns.Greeter.PendingCount())
            wow.rosterUpdate({ "Thrall", "Jaina", "Newbie" })
            wow.advance(ns.db.guildLogin.delay + 0.1)
            assert.are.same({ "Newbie has logged in. Quick, everyone look busy." }, wow.sentTo("GUILD"))
        end)

        it("tracks at most MAX_PENDING logins, and logs the ones it can't", function()
            ns.db.debug = true
            -- Names are letters only: "Newbieaa", "Newbieab", ...
            local function newbie(i)
                return "Newbie" .. string.char(97 + math.floor((i - 1) / 26), 97 + (i - 1) % 26)
            end
            for i = 1, ns.Greeter.MAX_PENDING + 1 do online(newbie(i)) end
            assert.are.equal(ns.Greeter.MAX_PENDING, ns.Greeter.PendingCount())
            local logged = false
            for _, line in ipairs(ns.db.diagLog) do
                if line:find("not tracking " .. newbie(ns.Greeter.MAX_PENDING + 1), 1, true) then logged = true end
            end
            assert.is_true(logged)
            wow.advance(ns.Greeter.PENDING_TIMEOUT)
            assert.are.equal(0, ns.Greeter.PendingCount())
        end)

        it("refreshes a relog at the MAX_PENDING cap", function()
            local function newbie(i)
                return "Newbie" .. string.char(97 + math.floor((i - 1) / 26), 97 + (i - 1) % 26)
            end
            for i = 1, ns.Greeter.MAX_PENDING do online(newbie(i)) end
            wow.advance(20)
            online(newbie(1)) -- relogged, at the cap
            wow.advance(ns.Greeter.PENDING_TIMEOUT - 20 + 1) -- the others have expired
            assert.are.equal(1, ns.Greeter.PendingCount())
        end)

        it("expires on its own timer even when GetTime() lags the timer's clock", function()
            online("Stranger")
            _G.GetTime = function() return wow.now - 0.005 end -- frame time just behind the timer clock
            wow.advance(ns.Greeter.PENDING_TIMEOUT)
            assert.are.equal(0, ns.Greeter.PendingCount())
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

        it("welcomes in party chat, after the party merge window", function()
            join("Anduin")
            wow.systemMessage("Anduin joins the party.")
            wow.advance(ns.Greeter.PARTY_MERGE_WINDOW - 0.5)
            assert.are.equal(0, #wow.sent)
            wow.advance(0.6)
            assert.are.same({ "Welcome to the group, Anduin!" }, wow.sentTo("PARTY"))
        end)

        it("keeps a single party welcome within a second of the Party Join delay", function()
            assert.is_true(ns.Greeter.PARTY_MERGE_WINDOW - ns.db.partyJoin.delay <= 1)
        end)

        describe("party joins close together", function()
            local names = { "Ann-Aa", "Bob-Bb", "Cid-Cc", "Dot-Dd" }

            local function partyJoin(full)
                wow.systemMessage(full:gsub("%-", " ") .. " joins the party.")
            end

            it("share one welcome line", function()
                wow.setGroup("party", { names[1], names[2], names[3] })
                partyJoin(names[1])
                wow.advance(1)
                partyJoin(names[2])
                wow.advance(1)
                partyJoin(names[3])
                wow.advance(10)
                assert.are.same({ "Welcome to the group, Ann, Bob and Cid!" }, wow.sentTo("PARTY"))
            end)

            it("start a new line for a join after the welcome went out", function()
                wow.setGroup("party", { names[1], names[2], names[3], names[4] })
                partyJoin(names[1])
                partyJoin(names[2])
                wow.advance(10)
                partyJoin(names[3])
                partyJoin(names[4])
                wow.advance(10)
                assert.are.same({ "Welcome to the group, Ann and Bob!", "Welcome to the group, Cid and Dot!" },
                    wow.sentTo("PARTY"))
            end)

            it("leave out someone who left before it was sent", function()
                wow.setGroup("party", { names[1], names[2], names[3] })
                partyJoin(names[1])
                partyJoin(names[2])
                partyJoin(names[3])
                wow.setGroup("party", { names[1], names[3] }) -- Bob left
                wow.advance(10)
                assert.are.same({ "Welcome to the group, Ann and Cid!" }, wow.sentTo("PARTY"))
            end)

            it("list a player only once, even with no repeat cooldown", function()
                ns.db.partyJoin.repeatCooldown = 0
                wow.setGroup("party", { names[1] })
                partyJoin(names[1])
                partyJoin(names[1])
                wow.advance(10)
                assert.are.same({ "Welcome to the group, Ann!" }, wow.sentTo("PARTY"))
            end)

            it("aren't sent if the zone turns out to be a battleground", function()
                wow.setGroup("party", { names[1], names[2] })
                partyJoin(names[1])
                partyJoin(names[2])
                wow.advance(1)
                wow.state.inInstance, wow.state.instanceType = true, "pvp"
                wow.advance(10)
                assert.are.equal(0, #wow.sent)
            end)

            it("cap a long list so the line still ends as written", function()
                ns.db.partyJoin.messages = { "Welcome, {fullname}! Glad you're here." }
                local long = {}
                for i = 1, 12 do
                    long[i] = "Bartholomew" .. string.char(96 + i) .. "-Featherstonehaugh"
                end
                wow.state.isLeader = true
                wow.setGroup("raid", long)
                for _, full in ipairs(long) do
                    wow.systemMessage(full:gsub("%-", " ") .. " has joined the raid group.")
                end
                wow.advance(10)
                local sent = wow.sentTo("RAID")
                assert.are.equal(1, #sent)
                assert.are.equal("Welcome, Bartholomewa Featherstonehaugh, Bartholomewb Featherstonehaugh, "
                    .. "Bartholomewc Featherstonehaugh, Bartholomewd Featherstonehaugh, "
                    .. "Bartholomewe Featherstonehaugh and 7 others! Glad you're here.", sent[1])
            end)

            it("list one extra name rather than \"and 1 others\"", function()
                local six = { "Ann-Aa", "Bob-Bb", "Cid-Cc", "Dot-Dd", "Eve-Ee", "Fay-Ff" }
                wow.state.isLeader = true
                wow.setGroup("raid", six)
                for _, full in ipairs(six) do
                    wow.systemMessage(full:gsub("%-", " ") .. " has joined the raid group.")
                end
                wow.advance(10)
                assert.are.same({ "Welcome to the group, Ann, Bob, Cid, Dot, Eve and Fay!" }, wow.sentTo("RAID"))
            end)

            it("don't stay stuck behind a welcome that never finished", function()
                wow.setGroup("party", { names[1], names[2] })
                local push = ns.ChatQueue.Push
                ns.ChatQueue.Push = function() end -- the message is lost
                partyJoin(names[1])
                wow.advance(10)
                ns.ChatQueue.Push = push
                wow.advance(ns.Greeter.RAID_MERGE_WINDOW + ns.ChatQueue.MAX_AGE)
                partyJoin(names[2])
                wow.advance(10)
                assert.are.same({ "Welcome to the group, Bob!" }, wow.sentTo("PARTY"))
            end)
        end)

        it("uses raid chat in a raid, after the merge window", function()
            wow.state.isLeader = true
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
            wow.state.inInstance, wow.state.isLeader = true, true
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

            -- Only the raid leader welcomes (see "only the leader" below).
            before_each(function()
                wow.state.isLeader = true
            end)

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
                wow.advance(ns.Greeter.RAID_MIN_INTERVAL)
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
                wow.advance(ns.Greeter.RAID_MIN_INTERVAL)
                assert.are.same({ "Welcome to the group, Ann!", "Welcome to the group, Bob!" }, wow.sentTo("RAID"))
            end)

            it("don't welcome the party again if the join lines come before the roster update", function()
                wow.state.isLeader = true
                wow.setGroup("party", { names[1], names[2] })
                wow.fire("GROUP_ROSTER_UPDATE")
                raidJoin(names[1]) -- still a party as far as the client says
                joinRaid({ names[1], names[2] })
                raidJoin(names[2]) -- a raid, but no roster update yet
                wow.fire("GROUP_ROSTER_UPDATE")
                joinRaid({ names[1], names[2], names[3] })
                wow.fire("GROUP_ROSTER_UPDATE")
                raidJoin(names[3])
                wow.advance(10)
                assert.are.same({ "Welcome to the group, Cid!" }, wow.sentTo("RAID"))
            end)

            it("welcome only the newcomer when a party with a new member becomes a raid", function()
                wow.state.isLeader = true
                wow.setGroup("party", { names[1], names[2] })
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.setGroup("party", { names[1], names[2], names[3] })
                wow.fire("GROUP_ROSTER_UPDATE") -- the roster shows Cid before the line does
                wow.systemMessage("Cid Cc joins the party.")
                wow.advance(10)
                raidJoin(names[1])
                raidJoin(names[2])
                raidJoin(names[3])
                joinRaid({ names[1], names[2], names[3] })
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.advance(10)
                assert.are.same({ "Welcome to the group, Cid!" }, wow.sentTo("PARTY"))
                assert.are.equal(1, #wow.sent)
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

            it("are only sent by the raid leader", function()
                wow.state.isLeader = false
                joinRaid(names)
                raidJoin(names[1])
                wow.advance(30)
                assert.are.equal(0, #wow.sent)
            end)

            it("aren't sent when you can't tell if you lead the raid", function()
                wow.state.isLeader, wow.state.isLeaderUnreadable = true, true
                joinRaid(names)
                raidJoin(names[1])
                wow.advance(30)
                assert.are.equal(0, #wow.sent)
            end)

            it("still welcome if the game has no instance group constant", function()
                _G.LE_PARTY_CATEGORY_INSTANCE = nil -- IsInGroup(nil) would mean any group
                joinRaid(names)
                raidJoin(names[1])
                wow.advance(10)
                assert.are.same({ "Welcome to the group, Ann!" }, wow.sentTo("RAID"))
            end)

            it("add a joiner to a line still held by chat lockdown after a long delay", function()
                ns.db.partyJoin.delay = 60
                wow.state.lockdown = true
                joinRaid(names)
                raidJoin(names[1])
                wow.advance(130) -- the line has waited in the queue since 60s
                raidJoin(names[2])
                wow.advance(20)
                wow.state.lockdown = false
                wow.advance(100)
                assert.are.same({ "Welcome to the group, Ann and Bob!" }, wow.sentTo("RAID"))
            end)

            it("don't make a new raid wait out the last one's interval", function()
                joinRaid(names)
                wow.fire("GROUP_ROSTER_UPDATE")
                raidJoin(names[1])
                wow.advance(ns.Greeter.RAID_MERGE_WINDOW + 0.1)
                wow.setGroup(nil, {})
                wow.fire("GROUP_ROSTER_UPDATE")
                joinRaid({ names[2] })
                wow.fire("GROUP_ROSTER_UPDATE")
                raidJoin(names[2])
                wow.advance(ns.Greeter.RAID_MERGE_WINDOW + 0.1)
                assert.are.same({ "Welcome to the group, Ann!", "Welcome to the group, Bob!" }, wow.sentTo("RAID"))
            end)

            -- What flooded raid chat in 1.5.0: a raid filling up one by one,
            -- each join further apart than the merge window.
            it("go out at most once per RAID_MIN_INTERVAL while a raid forms slowly", function()
                local list = {}
                for i = 1, 20 do
                    list[i] = "P" .. string.char(96 + i) .. "-Xx"
                    joinRaid(list)
                    raidJoin(list[i])
                    wow.advance(8)
                end
                wow.advance(ns.Greeter.RAID_MIN_INTERVAL)
                local sent = wow.sentTo("RAID")
                assert.are.equal(6, #sent) -- 20 lines in 1.5.0
                -- Everyone is still welcomed, in some line.
                local all = table.concat(sent, " ")
                for i = 1, 20 do
                    assert.truthy(all:find("P" .. string.char(96 + i), 1, true))
                end
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
            wow.advance(ns.Greeter.PARTY_MERGE_WINDOW + 0.1)
            assert.are.same({ "Welcome to the group, Sorum!" }, wow.sentTo("PARTY"))
        end)

        it("finds the newcomer anywhere in a raid", function()
            local names = {}
            for i = 1, 25 do names[i] = "Member-" .. string.rep(string.char(96 + (i % 26) + 1), 3) end
            names[25] = "Varian-Wrynn"
            wow.state.isLeader = true
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

        it("doesn't count a dropped hello toward Hello Again", function()
            joinGroup()
            wow.advance(0.1)
            wow.state.inInstance, wow.state.instanceType = true, "pvp" -- dropped at send time
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
            wow.state.inInstance = false
            leaveGroup()
            joinGroup()
            wow.advance(10)
            assert.are.same({ "Hi all! Thanks for the invite." }, wow.sentTo("PARTY"))
        end)

        it("doesn't count a hello dropped while AFK toward Hello Again", function()
            wow.state.afk = true
            joinGroup()
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
            wow.state.afk = false
            leaveGroup()
            joinGroup()
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

        it("doesn't say hello if the zone turns out to be a battleground", function()
            joinGroup()
            wow.advance(1)
            wow.state.inInstance, wow.state.instanceType = true, "pvp"
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't say hello for a group joined during the login grace period", function()
            ns = wow.boot({ noGrace = true })
            wow.advance(ns.Announcer.LOGIN_GRACE - 1)
            joinGroup()
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("uses Hello Again's own delay when it is shorter", function()
            ns.db.partyHello.delay, ns.db.partyHelloAgain.delay = 5, 1
            joinGroup()
            wow.advance(4.9)
            assert.are.equal(0, #wow.sent)
            wow.advance(0.2)
            assert.are.equal(1, #wow.sent)
            leaveGroup()
            wow.advance(ns.db.partyHello.repeatCooldown)
            joinGroup()
            wow.advance(0.9)
            assert.are.equal(1, #wow.sent)
            wow.advance(0.2)
            assert.are.same({ "Hi all! Thanks for the invite.", "Nice to see you all again!" }, wow.sentTo("PARTY"))
        end)

        it("uses Hello Again's own delay when it is longer", function()
            ns.db.partyHelloAgain.delay = 8
            joinGroup()
            wow.advance(10)
            leaveGroup()
            wow.advance(ns.db.partyHello.repeatCooldown)
            joinGroup()
            wow.advance(7.9)
            assert.are.equal(1, #wow.sent)
            wow.advance(0.2)
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
