-- Spec: #273
local wow = require("spec.support.wow")
local random = require("spec.support.random")

describe("Level-up congratulations", function()
    local ns

    local function party(names, levels, groupType)
        names = names or { "Alex-Roberts", "Udders-Healz" }
        wow.state.isLeader = true
        wow.setGroup(groupType or "party", names)
        local prefix = groupType == "raid" and "raid" or "party"
        for i, level in ipairs(levels or {}) do wow.state.units[prefix .. i].level = level end
        wow.fire("GROUP_ROSTER_UPDATE")
    end

    local function sentLines() return wow.sentTo("PARTY") end

    before_each(function()
        ns = wow.boot()
        ns.db.levelUp.messages = { ns.CasualMessages.levelUp[1] } -- fixed wording: "Congrats, {name}!"
    end)

    describe("a party member levels up (white)", function()
        it("sends one congratulation to PARTY after the delay", function()
            party(nil, { 10, 20 })
            wow.levelUp("party1", 11)
            wow.advance(ns.db.levelUp.delay - 0.5)
            assert.are.equal(0, #wow.sent)
            wow.advance(1)
            assert.are.same({ "Congrats, Alex!" }, sentLines())
        end)

        it("congratulates members in every party slot, not only the first two", function()
            party({ "Alex-Roberts", "Udders-Healz", "Bob-Smith", "Cid-Jones" }, { 10, 20, 30, 40 })
            wow.levelUp("party3", 31)
            wow.levelUp("party4", 41)
            wow.advance(10)
            assert.are.same({ "Congrats, Bob!", "Congrats, Cid!" }, sentLines())
        end)

        it("names the member who levelled, not the others", function()
            party(nil, { 10, 20 })
            wow.levelUp("party2", 21)
            wow.advance(10)
            assert.are.same({ "Congrats, Udders!" }, sentLines())
        end)

        it("goes to the instance chat in a dungeon-finder group", function()
            party(nil, { 10, 20 }, "instance")
            wow.levelUp("party1", 11)
            wow.advance(10)
            assert.are.same({ "Congrats, Alex!" }, wow.sentTo("INSTANCE_CHAT"))
        end)

        it("is on by default, with a 3 second delay and a 60 second repeat cooldown", function()
            assert.is_true(ns.Config.DEFAULTS.levelUp.enabled)
            assert.are.equal(3, ns.Config.DEFAULTS.levelUp.delay)
            assert.are.equal(60, ns.Config.DEFAULTS.levelUp.repeatCooldown)
        end)

        it("sends one of the shipped lines, which never name a level, in both sets", function()
            for _, set in ipairs({ ns.DefaultMessages.levelUp, ns.CasualMessages.levelUp }) do
                assert.are.equal(ns.Config.NUM_MESSAGES, #set)
                for _, line in ipairs(set) do
                    assert.is_nil(line:find("%d"), line)
                    assert.is_nil(line:lower():find("level", 1, true), line)
                    assert.is_nil(line:find("{level}", 1, true), line)
                end
            end
            ns.db.levelUp.messages = ns.DefaultMessages.levelUp
            party(nil, { 10, 20 })
            wow.levelUp("party1", 11)
            wow.advance(10)
            assert.are.equal(1, #sentLines())
        end)

        it("has its own tab and switch", function()
            assert.is_truthy(ns.Options.widgets.tabs.levelUp)
            local found
            for _, t in ipairs(ns.Config.TYPES) do found = found or t == "levelUp" end
            assert.is_true(found)
        end)
    end)

    describe("when it stays quiet", function()
        it("sends nothing for your own level-up", function()
            -- Your own name also sits in a slot, so only "never track yourself" can keep this quiet.
            party({ "Alex-Roberts", "Udders-Healz", "Me-Self" }, { 10, 20, 10 })
            wow.addUnit("player", { name = "Me", surname = "Self", id = "Me-Self", level = 10 })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.fire("UNIT_LEVEL", "player")
            wow.state.units.player.level = 11 -- the real level-up
            wow.fire("UNIT_LEVEL", "player")
            ns.LevelUps.OnUnitLevel("player")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("sends nothing in a raid, even if a party slot still reads", function()
            party(nil, { 10, 20 })
            wow.state.groupType = "raid"
            wow.levelUp("party1", 11)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
            wow.state.groupType, wow.state.raidSized = "instance", true -- a raid-sized instance group
            wow.levelUp("party1", 12)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("sends nothing in a battleground or an arena", function()
            party(nil, { 10, 20 })
            wow.state.inInstance, wow.state.instanceType = true, "pvp"
            wow.levelUp("party1", 11)
            wow.advance(10)
            wow.state.instanceType = "arena"
            wow.levelUp("party2", 21)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("sends nothing for a battleground's instance group", function()
            party(nil, { 10, 20 }, "instance")
            wow.state.inInstance, wow.state.instanceType = true, "pvp"
            wow.levelUp("party1", 11)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("drops it if you enter a raid or battleground before it goes out", function()
            party(nil, { 10, 20 })
            wow.levelUp("party1", 11)
            wow.advance(1)
            wow.state.inInstance, wow.state.instanceType = true, "arena"
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("drops it if they leave the group before it goes out", function()
            party(nil, { 10, 20 })
            wow.levelUp("party1", 11)
            wow.advance(1)
            party({ "Udders-Healz" }, { 20 })
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("sends nothing when the level didn't rise", function()
            party(nil, { 10, 20 })
            wow.levelUp("party1", 10)
            wow.levelUp("party2", 19)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("sends nothing when their earlier level was never read", function()
            party(nil, { nil, 20 })
            wow.levelUp("party1", 11)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
            wow.levelUp("party1", 12) -- now there is a level to be higher than
            wow.advance(10)
            assert.are.equal(1, #sentLines())
        end)

        it("sends nothing when its type is switched off, or the addon is", function()
            party(nil, { 10, 20 })
            ns.db.levelUp.enabled = false
            wow.levelUp("party1", 11)
            wow.advance(10)
            ns.db.levelUp.enabled, ns.db.enabled = true, false
            wow.levelUp("party1", 12)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("sends nothing while you're AFK or snoozed", function()
            party(nil, { 10, 20 })
            wow.state.afk = true
            wow.levelUp("party1", 11)
            wow.advance(10)
            wow.state.afk = false
            ns.Announcer.Snooze(5)
            wow.levelUp("party1", 12)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("sends nothing for an ignored player, even one ignored after the level-up", function()
            party(nil, { 10, 20 })
            ns.Ignore.Add("Alex-Roberts")
            wow.levelUp("party1", 11)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
            ns.Ignore.Remove("Alex-Roberts")
            wow.levelUp("party1", 12)
            wow.advance(1)
            ns.Ignore.Add("Alex-Roberts")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("sends nothing in the login grace period", function()
            ns = wow.boot({ noGrace = true })
            ns.db.levelUp.messages = { ns.CasualMessages.levelUp[1] }
            party(nil, { 10, 20 })
            wow.levelUp("party1", 11)
            wow.advance(ns.Announcer.LOGIN_GRACE - 4)
            assert.are.equal(0, #wow.sent)
        end)
    end)

    describe("the decision to send (mutation-checked)", function()
        it("doesn't use up the cooldown on a level-up it stayed quiet for", function()
            party(nil, { 10, 20 })
            ns.Announcer.Snooze(1)
            wow.levelUp("party1", 12)
            ns.Announcer.Snooze(0)
            wow.state.groupType = "raid"
            wow.levelUp("party1", 13)
            wow.state.groupType = "party"
            ns.Ignore.Add("Alex-Roberts")
            wow.levelUp("party1", 14)
            ns.Ignore.Remove("Alex-Roberts")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
            wow.levelUp("party1", 15) -- all of that was quiet, so this one is the first
            wow.advance(10)
            assert.are.equal(1, #sentLines())
        end)

        it("is quiet in a raid even when the same name still sits in a party slot", function()
            wow.state.isLeader = true
            wow.setGroup("raid", { "Alex-Roberts" })
            wow.state.units.raid1.level = 10
            wow.addUnit("party1", { name = "Alex", surname = "Roberts", id = "Alex-Roberts", level = 10 })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.levelUp("party1", 11)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
            local ok, why = ns.LevelUps.Allowed()
            assert.is_false(ok)
            assert.are.equal("in a raid", why)
        end)

        it("is quiet in a battleground's preparation phase, when the battle hasn't started", function()
            wow.enterBattleground({})
            wow.setGroup("instance", { "Alex-Roberts" })
            wow.state.units.party1.level = 10
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(ns.Battleground.Quiet(), "the preparation phase isn't quiet for the Announcer")
            wow.levelUp("party1", 11)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("is quiet in an arena, and says so", function()
            party(nil, { 10, 20 })
            wow.state.inInstance, wow.state.instanceType = true, "arena"
            local ok, why = ns.LevelUps.Allowed()
            assert.is_false(ok)
            assert.is_truthy(why)
            wow.state.instanceType = "party"
            assert.is_true(ns.LevelUps.Allowed())
        end)

        it("is quiet outside a group", function()
            party(nil, { 10, 20 })
            wow.setGroup(nil, {})
            assert.is_false((ns.LevelUps.Allowed()))
        end)

        it("only watches party slots: another unit's rising level is never congratulated", function()
            party({ "Mallory-Evil" }, { 5 })
            -- The same player, reached through another token (your target).
            wow.addUnit("target", { name = "Mallory", surname = "Evil", id = "Mallory-Evil", level = 6 })
            ns.LevelUps.OnUnitLevel("target")
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("doesn't take a fractional rise for a level", function()
            party(nil, { 10, 20 })
            wow.levelUp("party1", 10.5)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)
    end)

    describe("the repeat cooldown", function()
        it("skips a second level-up by the same player inside it", function()
            party(nil, { 10, 20 })
            wow.levelUp("party1", 11)
            wow.advance(10)
            wow.levelUp("party1", 12)
            wow.advance(10)
            assert.are.equal(1, #sentLines())
        end)

        it("congratulates them again once it has run out", function()
            party(nil, { 10, 20 })
            wow.levelUp("party1", 11)
            wow.advance(ns.db.levelUp.repeatCooldown + 1)
            wow.levelUp("party1", 12)
            wow.advance(10)
            assert.are.equal(2, #sentLines())
        end)

        it("is per player", function()
            party(nil, { 10, 20 })
            wow.levelUp("party1", 11)
            wow.levelUp("party2", 21)
            wow.advance(10)
            assert.are.equal(2, #sentLines())
        end)
    end)

    describe("bad input (black)", function()
        it("ignores levels that aren't sane integers, and unit tokens that aren't party slots", function()
            party(nil, { 10, 20 })
            local bad = { 0, -3, 1.5, 101, 1e9, 0 / 0, math.huge, "12", true, {} }
            for _, level in ipairs(bad) do
                wow.state.units.party1.level = level
                assert.has_no.errors(function() ns.LevelUps.OnUnitLevel("party1") end)
            end
            for _, unit in ipairs({ "party5", "raid1", "target", "", 42, true, {} }) do
                assert.has_no.errors(function() ns.LevelUps.OnUnitLevel(unit) end)
            end
            assert.has_no.errors(function() ns.LevelUps.OnUnitLevel(nil) end)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("sends nothing when the level or name is a secret value", function()
            party(nil, { 10, 20 })
            wow.state.units.party1.secrets = { level = true }
            wow.levelUp("party1", 11)
            wow.state.units.party1.secrets = { name = true }
            wow.levelUp("party1", 12)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)

        it("sends nothing when it can't tell if you're in an arena", function()
            party(nil, { 10, 20 })
            wow.state.inInstance, wow.state.inInstanceSecret = true, true
            wow.levelUp("party1", 11)
            wow.advance(10)
            assert.are.equal(0, #wow.sent)
        end)
    end)

    describe("chaos (red)", function()
        it("never congratulates outside a party, in a raid or pvp, while AFK, or inside a cooldown", function()
            random.seed(273)
            local names = { "Alex-Roberts", "Udders-Healz", "Bob-Smith", "Cid-Jones" }
            local checked, lastAt = 0, {}
            local reached = { raid = 0, pvp = 0, afk = 0 }
            -- Checked against the client's own state, a second at a time, so
            -- the state that held when a line went out is the one read here.
            local function step(seconds)
                for _ = 1, seconds do
                    local before = #wow.sent
                    wow.advance(1)
                    for i = before + 1, #wow.sent do
                        local rec = wow.sent[i]
                        local who = rec.text:match("^Congrats, (%a+)!$")
                        assert.is_truthy(who, rec.text)
                        checked = checked + 1
                        local s2 = wow.state
                        assert.is_truthy(s2.groupType, "sent with no group")
                        assert.is_false(s2.groupType == "raid", "sent in a raid")
                        assert.is_false(s2.inInstance and (s2.instanceType == "pvp" or s2.instanceType == "arena"),
                            "sent in pvp")
                        assert.is_falsy(s2.afk, "sent while AFK")
                        assert.is_truthy(rec.channel == "PARTY" or rec.channel == "INSTANCE_CHAT", rec.channel)
                        assert.is_true(not lastAt[who] or rec.time - lastAt[who] >= 60, "inside the cooldown")
                        lastAt[who] = rec.time
                    end
                end
            end
            for _ = 1, 500 do
                local roll = random.random(8)
                if roll == 1 then
                    local kind = ({ "party", "raid", "instance", "party" })[random.random(4)]
                    local count = random.random(0, 4)
                    local members = {}
                    for i = 1, count do members[i] = names[i] end
                    wow.state.isLeader = true
                    wow.setGroup(kind, members)
                    for i = 1, count do
                        wow.state.units[(kind == "raid" and "raid" or "party") .. i].level = random.random(1, 60)
                        if kind == "raid" then
                            -- In the game a raid's subgroup still answers to party1-4.
                            local first, last = members[i]:match("^([^%-]+)%-(.+)$")
                            wow.addUnit("party" .. i, { name = first, surname = last, id = members[i],
                                level = random.random(1, 60) })
                        end
                    end
                    wow.fire("GROUP_ROSTER_UPDATE")
                elseif roll == 2 then
                    wow.state.inInstance = random.random(2) == 1
                    wow.state.instanceType = ({ "party", "pvp", "arena", "raid" })[random.random(4)]
                elseif roll == 3 then
                    wow.state.afk = random.random(2) == 1
                else
                    local slot = "party" .. random.random(4)
                    if wow.state.units[slot] then
                        wow.levelUp(slot, random.random(1, 61))
                        local s2 = wow.state
                        if s2.groupType == "raid" then reached.raid = reached.raid + 1 end
                        if s2.inInstance and (s2.instanceType == "pvp" or s2.instanceType == "arena") then
                            reached.pvp = reached.pvp + 1
                        end
                        if s2.afk then reached.afk = reached.afk + 1 end
                    else
                        wow.fire("UNIT_LEVEL", slot)
                    end
                end
                step(random.random(0, 40))
            end
            step(60)
            assert.is_true(checked > 0, "the storm never sent anything, so it proved nothing")
            -- It must also have reached the quiet cases it checks.
            assert.is_true(reached.raid > 0, "no level-up reached the storm's raid")
            assert.is_true(reached.pvp > 0, "no level-up reached the storm's battleground or arena")
            assert.is_true(reached.afk > 0, "no level-up reached the storm while AFK")
        end)
    end)

    describe("a reload in a party (white)", function()
        it("congratulates a member's first level-up even with no roster update after the reload", function()
            ns = wow.boot({ before = function(state)
                state.isLeader = true
                wow.setGroup("party", { "Alex-Roberts", "Udders-Healz" })
                wow.state.units.party1.level = 10
                wow.state.units.party2.level = 20
            end })
            ns.db.levelUp.messages = { ns.CasualMessages.levelUp[1] }
            wow.fire("PLAYER_ENTERING_WORLD", false, true) -- a /reload, and no GROUP_ROSTER_UPDATE
            wow.advance(ns.Announcer.LOGIN_GRACE)
            wow.levelUp("party1", 11)
            wow.advance(10)
            assert.are.same({ "Congrats, Alex!" }, sentLines())
        end)
    end)

    describe("an update that adds LevelUps.lua (black)", function()
        it("asks for a restart, not erroring, after only a /reload", function()
            wow.reset()
            local loaded = {}
            local _, files = wow.parseToc()
            for _, file in ipairs(files) do
                if file ~= "LevelUps.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
            end
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            wow.fire("PLAYER_ENTERING_WORLD", true, false)
            wow.advance(20)
            assert.are.same({}, wow.errors)
            assert.truthy(table.concat(wow.printed, "\n"):find("Restart the game (not /reload)", 1, true))
        end)
    end)
end)
