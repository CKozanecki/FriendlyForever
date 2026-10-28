-- Spec: #71
-- Battlegrounds: buffing in the preparation phase, then quiet until you
-- leave or the battleground ends.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1 = 9885, 1126
local INTELLECT = 10157

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

local function printedHas(fragment)
    for _, line in ipairs(wow.printed) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

local TEAM = { "Ann-Vale", "Cid-Rock" }

describe("Battlegrounds", function()
    local ns, button

    -- A druid who knows Mark of the Wild, with buff mode's triggers on, in a
    -- guild with Thrall in it.
    local function boot(db)
        ns = wow.boot({ db = db, autoBuffMode = true, before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
            state.guildRoster = { "Thrall" }
        end })
        wow.fire("GUILD_ROSTER_UPDATE")
        for _, msgType in ipairs(ns.Config.TYPES) do
            ns.db[msgType].messages = { ns.CasualMessages[msgType][1] } -- fixed wording
        end
        ns.db.buff.messages = { "Thanks {name}" }
        button = ns.BuffButton.Frame()
    end

    -- Bob Stone, a stranger, buffs you.
    local function strangerBuffs()
        wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
        wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
    end

    local function guildmateLogsIn()
        wow.systemMessage("|Hplayer:Thrall|h[Thrall]|h has come online.")
    end

    local function nonGuildLines()
        local out = {}
        for _, s in ipairs(wow.sent) do
            if s.channel ~= "GUILD" then out[#out + 1] = s.text end
        end
        return out
    end

    -- Scroll once; the buff shows on whoever it reached.
    local function scroll()
        local before = #wow.casts
        wow.pressKey("MOUSEWHEELUP")
        local cast = wow.casts[before + 1]
        if cast then
            for token, u in pairs(wow.state.units) do
                if u.id == cast.target and token ~= "target" then
                    u.auras = u.auras or {}
                    u.auras[#u.auras + 1] = cast.id
                end
            end
        end
        return cast
    end

    local function lent() return wow.state.overrides.MOUSEWHEELUP ~= nil end

    before_each(function() boot() end)

    describe("before the gates open (white)", function()
        it("buff mode and its triggers work as in a raid in the preparation phase", function()
            wow.enterBattleground(TEAM)
            assert.is_true(ns.BuffMode.IsOn(), "joining the battleground group turned it on")
            assert.is_true(printedHas("(you joined a group)"))
            assert.is_true(lent())
            local cast = scroll()
            assert.is_not_nil(cast)
            assert.are.equal("Mark of the Wild", cast.spell)
            assert.are.equal("Ann-Vale", cast.target)
            assert.are.equal("Cid-Rock", scroll().target)
            assert.is_false(ns.BuffMode.IsOn(), "off when everyone has your buffs, as in a raid")
        end)

        it("turns on for joining whichever comes first, the group or the phase", function()
            -- enterBattleground sends the group first, before the phase can be read.
            wow.enterBattleground(TEAM)
            assert.is_true(ns.BuffMode.IsOn())
            boot()
            wow.enterBattleground(TEAM, { rosterLast = true })
            assert.is_true(ns.BuffMode.IsOn())
            for _, rosterLast in ipairs({ false, true }) do
                boot()
                wow.enterBattleground(TEAM, { rosterLast = rosterLast, auraLate = true })
                assert.is_true(ns.BuffMode.IsOn(), "the aura after the loading screen")
            end
        end)

        it("reads the preparation phase from the start-of-battle timer alone", function()
            wow.enterBattleground(TEAM, { preparation = false, timer = 62 })
            assert.are.equal("preparation", ns.Battleground.Phase())
            assert.is_true(ns.BuffMode.IsOn())
            wow.advance(61)
            assert.are.equal("preparation", ns.Battleground.Phase())
            assert.is_true(lent())
            wow.advance(1)
            assert.are.equal("battle", ns.Battleground.Phase())
            assert.is_false(ns.BuffMode.IsOn(), "the timer running out opened the gates")
            assert.is_false(lent())
        end)

        it("after a reload in the preparation phase, trusts the timer but not the aura alone", function()
            wow.enterBattleground(TEAM, { timer = 60 })
            wow.reloadInPlace()
            assert.are.equal("battle", ns.Battleground.Phase(), "the aura alone: the quiet side")
            wow.startTimer(50)
            assert.are.equal("preparation", ns.Battleground.Phase())
            wow.advance(50)
            assert.are.equal("battle", ns.Battleground.Phase())
        end)

        it("takes a timer at zero as the gates opening", function()
            wow.enterBattleground(TEAM)
            wow.startTimer(0)
            assert.are.equal("battle", ns.Battleground.Phase())
            wow.gainBuff({ spellId = wow.PREPARATION_ID })
            assert.are.equal("battle", ns.Battleground.Phase(), "and stays started")
        end)

        it("reads the newer client's timer type too", function()
            wow.useStartTimerEnum()
            wow.enterBattleground(TEAM, { preparation = false, timer = 30 })
            assert.are.equal("preparation", ns.Battleground.Phase())
            wow.advance(30)
            assert.are.equal("battle", ns.Battleground.Phase())
        end)

        it("thanks and welcomes as usual in the preparation phase", function()
            wow.enterBattleground(TEAM)
            strangerBuffs()
            wow.advance(10)
            assert.are.same({ "Thanks Bob" }, wow.sentTo("SAY"))
        end)
    end)

    describe("once the gates open (white)", function()
        before_each(function()
            wow.enterBattleground(TEAM)
            wow.openGates()
        end)

        it("ends buff mode and hides the buff back button, even with a favour owed", function()
            boot()
            ns.db.buffBack.autoOnBuffed = false
            wow.enterBattleground(TEAM)
            strangerBuffs()
            assert.are.equal(1, ns.Offers.Count(), "a favour from the preparation phase")
            wow.openGates()
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode off (the battle has started)"))
            assert.is_false(lent())
            assert.is_false(button:IsShown())
            assert.is_nil(ns.BuffButton.ArmedOffer())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal("default", wow.keyActions[#wow.keyActions].action, "the wheel does its own job")
        end)

        it("turns nothing on: no trigger, no stranger's buff, no death, not even you", function()
            strangerBuffs()
            wow.state.units.raid1.dead = true
            wow.fire("UNIT_HEALTH", "raid1")
            wow.setGroup("instance", { "Ann-Vale", "Cid-Rock", "Dot-Fern" }, true)
            wow.fire("GROUP_ROSTER_UPDATE")
            slash("buffmode on")
            assert.is_true(printedHas("buff mode stays off: the battle has started."))
            FriendlyForever_ToggleBuffMode()
            wow.advance(30)
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_false(lent())
            assert.is_false(button:IsShown())
            assert.are.equal(0, #wow.casts)
        end)

        it("doesn't owe or thank a buff you get, and sends no lines", function()
            strangerBuffs()
            wow.systemMessage("Dot has joined the instance group.")
            wow.advance(30)
            assert.are.same({}, nonGuildLines())
            assert.are.same({}, wow.emotes)
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("works nothing out: no group buffs, favours or buff casts are read", function()
            local reads = 0
            local function counted(fn) return function(...) reads = reads + 1 return fn(...) end end
            ns.GroupBuffs.Next = counted(ns.GroupBuffs.Next)
            ns.Offers.Current = counted(ns.Offers.Current)
            ns.BuffTracker.Classify = counted(ns.BuffTracker.Classify)
            strangerBuffs()
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-x", INTELLECT)
            wow.setGroup("instance", { "Ann-Vale", "Cid-Rock", "Dot-Fern" }, true)
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.enterCombat()
            wow.leaveCombat()
            wow.state.units.raid1.dead = true
            wow.fire("UNIT_HEALTH", "raid1")
            wow.advance(60)
            assert.are.equal(0, reads)
        end)

        it("acts on the gates opening once, not on every change of your buffs after", function()
            boot()
            ns.db.debug = true
            local refreshes = 0
            local refresh = ns.BuffButton.Refresh
            ns.BuffButton.Refresh = function(...) refreshes = refreshes + 1 return refresh(...) end
            wow.enterBattleground(TEAM)
            wow.openGates()
            local before = refreshes
            for _ = 1, 5 do wow.gainBuff({ spellId = 1 }) end
            assert.are.equal(before, refreshes)
            local logged = 0
            for _, line in ipairs(ns.db.diagLog) do
                if line:find("battleground: quiet", 1, true) then logged = logged + 1 end
            end
            assert.are.equal(1, logged)
        end)

        it("schedules no line, so no repeat cooldown is spent in the battle", function()
            assert.is_false(ns.Announcer.Schedule("buff", "Bob-Stone", { channel = "SAY" }))
            assert.is_true(ns.Announcer.Schedule("guildLogin", "Thrall", { channel = "GUILD" }))
        end)

        it("still greets guildmates in guild chat", function()
            guildmateLogsIn()
            wow.advance(10)
            assert.are.equal(1, #wow.sentTo("GUILD"))
        end)

        it("drops a thank-you that was waiting as the gates opened", function()
            boot()
            wow.enterBattleground(TEAM)
            strangerBuffs()
            wow.openGates()
            wow.advance(30)
            assert.are.same({}, nonGuildLines())
        end)

        it("stays quiet after you die and are resurrected with a new Preparation aura", function()
            wow.die()
            wow.resurrect(true)
            assert.are.equal("battle", ns.Battleground.Phase())
            strangerBuffs()
            wow.advance(30)
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, nonGuildLines())
        end)

        it("stays quiet after a reload or relog with a resurrection's Preparation aura", function()
            wow.die()
            wow.resurrect(true)
            wow.reloadInPlace()
            assert.are.equal("battle", ns.Battleground.Phase())
            wow.reloadInPlace(true)
            assert.are.equal("battle", ns.Battleground.Phase())
            strangerBuffs()
            wow.advance(30)
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, nonGuildLines())
        end)

        it("forgets triggers it refused once you leave or the battleground ends", function()
            wow.enterCombat()
            wow.leaveCombat()
            wow.state.units.raid1.dead = true
            wow.fire("UNIT_HEALTH", "raid1")
            wow.endBattleground(0)
            assert.is_false(ns.BuffMode.IsOn())
            boot()
            wow.enterBattleground(TEAM)
            wow.openGates()
            wow.setGroup("instance", { "Ann-Vale" }, true)
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.setGroup(nil, {})
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.setGroup("instance", TEAM, true)
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.leaveBattleground()
            assert.is_false(ns.BuffMode.IsOn())
            -- Nor in the next battleground's preparation phase.
            boot()
            ns.db.buffBack.autoOnJoin = false
            wow.enterBattleground(TEAM)
            wow.openGates()
            wow.enterCombat()
            wow.leaveCombat()
            wow.state.units.raid1.dead = true
            wow.fire("UNIT_HEALTH", "raid1")
            wow.leaveBattleground()
            wow.enterBattleground(TEAM)
            assert.are.equal("preparation", ns.Battleground.Phase())
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("counts a death as the battle having started, whatever the aura says", function()
            boot()
            wow.enterBattleground(TEAM)
            wow.die()
            assert.are.equal("battle", ns.Battleground.Phase())
            assert.is_false(ns.BuffMode.IsOn())
        end)
    end)

    describe("outside battlegrounds (white)", function()
        it("treats a dungeon as any other place", function()
            wow.state.inInstance, wow.state.instanceType = true, "party"
            wow.setGroup("party", TEAM)
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.are.equal("none", ns.Battleground.Phase())
            assert.is_true(ns.BuffMode.IsOn())
            strangerBuffs()
            wow.advance(10)
            assert.are.same({ "Thanks Bob" }, wow.sentTo("SAY"))
        end)

        it("doesn't read your buffs for the Preparation aura", function()
            local reads = 0
            local api = _G.C_UnitAuras.GetAuraDataByIndex
            _G.C_UnitAuras.GetAuraDataByIndex = function(unit, ...)
                if unit == "player" then reads = reads + 1 end
                return api(unit, ...)
            end
            strangerBuffs()
            wow.gainBuff({ spellId = wow.PREPARATION_ID })
            assert.are.equal(0, reads)
        end)
    end)

    describe("leaving or finishing (white)", function()
        it("puts everything back when you leave", function()
            wow.enterBattleground(TEAM)
            wow.openGates()
            wow.leaveBattleground()
            assert.are.equal("none", ns.Battleground.Phase())
            strangerBuffs()
            assert.is_true(ns.BuffMode.IsOn(), "a stranger's buff turns buff mode on again")
            assert.is_true(button:IsShown())
            assert.are.equal("Bob-Stone", ns.BuffButton.ArmedOffer().name)
            wow.advance(10)
            wow.keyDown()
            assert.are.same({ "Thanks Bob" }, wow.sentTo("SAY"))
        end)

        it("shows a favour from the preparation phase again as soon as the battleground ends", function()
            ns.db.buffBack.autoOnBuffed = false
            ns.db.buffBack.autoOnJoin = false
            wow.enterBattleground(TEAM)
            strangerBuffs()
            wow.openGates()
            assert.is_false(button:IsShown())
            wow.endBattleground(1)
            assert.is_true(button:IsShown())
            assert.are.equal("Bob-Stone", ns.BuffButton.ArmedOffer().name)
        end)

        it("puts everything back when the battleground ends", function()
            wow.enterBattleground(TEAM)
            wow.openGates()
            wow.endBattleground(1)
            assert.are.equal("ended", ns.Battleground.Phase())
            strangerBuffs()
            wow.advance(10)
            assert.are.same({ "Thanks Bob" }, wow.sentTo("SAY"))
            assert.is_true(ns.BuffMode.IsOn())
        end)

        it("reads a battleground entered straight from another afresh", function()
            wow.enterBattleground(TEAM)
            wow.openGates()
            wow.enterBattleground(TEAM)
            assert.are.equal("preparation", ns.Battleground.Phase())
        end)

        it("reads the next battleground afresh", function()
            wow.enterBattleground(TEAM)
            wow.openGates()
            wow.leaveBattleground()
            wow.enterBattleground(TEAM)
            assert.are.equal("preparation", ns.Battleground.Phase())
            assert.is_true(ns.BuffMode.IsOn())
        end)
    end)

    describe("the setting", function()
        it("is on by default, and off keeps the preparation phase quiet too (white)", function()
            assert.is_true(ns.db.buffBack.bgPrepBuff)
            ns.db.buffBack.bgPrepBuff = false
            wow.enterBattleground(TEAM)
            assert.are.equal("preparation", ns.Battleground.Phase())
            assert.is_false(ns.BuffMode.IsOn())
            strangerBuffs()
            wow.advance(30)
            assert.are.same({}, nonGuildLines())
        end)

        it("switched off in the preparation phase ends buff mode there and then (white)", function()
            wow.enterBattleground(TEAM)
            assert.is_true(ns.BuffMode.IsOn())
            slash("")
            wow.run(ns.Options.widgets.tabs.buffBack, "OnClick")
            local box = ns.Options.widgets.bgPrepBuff
            assert.is_true(box:IsShown())
            assert.is_true(box:GetChecked())
            box:SetChecked(false)
            wow.run(box, "OnClick")
            assert.is_false(ns.db.buffBack.bgPrepBuff)
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_false(lent())
            wow.run(ns.Options.widgets.tabs.buff, "OnClick")
            assert.is_false(box:IsShown(), "only on the Buff Back tab")
        end)

        it("switched off by a profile in the preparation phase ends buff mode (white)", function()
            ns.db.buffBack.bgPrepBuff = false
            local text = ns.Profiles.Export()
            ns.db.buffBack.bgPrepBuff = true
            wow.enterBattleground(TEAM)
            assert.is_true(ns.BuffMode.IsOn())
            assert.is_true(ns.Profiles.Import(text))
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode off: buffing in a battleground's preparation phase is off."))
            assert.is_false(lent())
        end)

        it("is carried in profiles and export (white)", function()
            ns.db.buffBack.bgPrepBuff = false
            local text = ns.Profiles.Export()
            ns.db.buffBack.bgPrepBuff = true
            assert.is_true(ns.Profiles.Import(text))
            assert.is_false(ns.db.buffBack.bgPrepBuff)
        end)

        it("damaged settings are repaired to the default (black)", function()
            boot({ buffBack = { bgPrepBuff = "yes" } })
            assert.is_true(ns.db.buffBack.bgPrepBuff)
            boot({ buffBack = { bgPrepBuff = {} } })
            assert.is_true(ns.db.buffBack.bgPrepBuff)
        end)

        it("damaged mid-session reads as off, the quiet side, without errors (black)", function()
            ns.db.buffBack.bgPrepBuff = 7
            wow.enterBattleground(TEAM)
            assert.is_false(ns.BuffMode.IsOn())
            ns.db.buffBack = nil
            assert.is_true(ns.Battleground.Quiet())
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("an unreadable phase counts as started (black)", function()
        it("with no aura and no timer", function()
            wow.enterBattleground(TEAM, { preparation = false })
            assert.are.equal("battle", ns.Battleground.Phase())
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("while your buffs can't be read", function()
            wow.state.aurasRestricted = true
            wow.enterBattleground(TEAM)
            assert.are.equal("battle", ns.Battleground.Phase())
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end)

        it("while the aura's ID is a secret", function()
            wow.enterBattleground(TEAM, { preparation = false })
            wow.gainBuff({ spellId = wow.secret(wow.PREPARATION_ID) })
            assert.are.equal("battle", ns.Battleground.Phase())
            assert.are.same({}, wow.errors)
        end)

        it("ignores a secret timer, another kind of countdown, and a nonsense one", function()
            wow.enterBattleground(TEAM, { preparation = false })
            wow.fire("START_TIMER", wow.secret(1), 60, 120)
            wow.fire("START_TIMER", 1, wow.secret(60), 120)
            wow.startTimer(60, 3) -- a player's /countdown
            wow.fire("START_TIMER", 1, "soon", 120)
            assert.are.equal("battle", ns.Battleground.Phase())
            assert.are.same({}, wow.errors)
        end)

        it("doesn't call a battleground over when the winner can't be read", function()
            wow.enterBattleground(TEAM)
            wow.openGates()
            wow.state.bgWinner = wow.secret(1)
            wow.fire("UPDATE_BATTLEFIELD_STATUS", 1)
            assert.are.equal("battle", ns.Battleground.Phase())
            assert.are.same({}, wow.errors)
        end)

        it("isn't fooled by the aura flickering unreadable once the gates have opened", function()
            wow.enterBattleground(TEAM)
            wow.state.aurasRestricted = true
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            wow.state.aurasRestricted = false
            wow.openGates()
            wow.gainBuff({ spellId = wow.PREPARATION_ID })
            assert.are.equal("battle", ns.Battleground.Phase())
        end)
    end)

    describe("chaos (red tests)", function()
        it("never sends a line or offers a buff after the gates open, through deaths, fights, roster changes "
            .. "and the end", function()
            local quietSteps, prepCasts, guildLinesWhileQuiet, rounds = 0, 0, 0, 0
            for _, seed in ipairs({ 7, 71, 404, 1999, 2026 }) do
                random.seed(seed)
                boot()
                -- Guild hellos as often as they come, so some fall in quiet steps.
                ns.db.guildLogin.repeatCooldown = 0
                -- The test's own record of the battleground, from what it did.
                local inBG, ended, startedHere, aura, timerEnd = false, false, false, false, nil
                local prepBuff = true -- the setting, as last clicked
                local distrusted = false -- reloaded in this battleground: its aura alone proves nothing
                local function quietExpected()
                    if not inBG or ended then return false end
                    local prep = not startedHere and ((aura and not distrusted) or (timerEnd ~= nil and wow.now < timerEnd))
                    if timerEnd and wow.now >= timerEnd then return true end
                    return not prep or not prepBuff
                end
                local everyone = { "Ann-Vale", "Cid-Rock", "Dot-Fern", "Eve-Moss" }
                local function roster()
                    local names = {}
                    for _, n in ipairs(everyone) do if random.random() < 0.7 then names[#names + 1] = n end end
                    return names
                end
                local actions = {
                    function()
                        if inBG then return end
                        local opts = { preparation = random.random() < 0.7, rosterLast = random.random() < 0.5,
                            auraLate = random.random() < 0.5,
                            timer = random.random() < 0.5 and random.random(5, 90) or nil }
                        wow.enterBattleground(roster(), opts)
                        inBG, ended, startedHere, aura, distrusted = true, false, false, opts.preparation, false
                        timerEnd = opts.timer and (wow.now + opts.timer) or nil
                        rounds = rounds + 1
                    end,
                    function()
                        if not inBG then return end
                        wow.openGates()
                        if aura then startedHere = true end
                        aura = false
                    end,
                    function()
                        if not inBG or wow.state.units.player.dead then return end
                        wow.die()
                        startedHere = true
                    end,
                    function()
                        if not wow.state.units.player.dead then return end
                        wow.resurrect(random.random() < 0.5)
                        aura = true
                    end,
                    function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                    function()
                        -- A reload or relog: the timer is forgotten unless it's sent again.
                        wow.reloadInPlace(random.random() < 0.3)
                        if inBG then distrusted, timerEnd = true, nil end
                    end,
                    function()
                        if not inBG then return end
                        wow.setGroup("instance", roster(), true)
                        wow.fire("GROUP_ROSTER_UPDATE")
                    end,
                    function()
                        local token = "raid" .. random.random(1, 4)
                        if wow.state.units[token] then
                            wow.state.units[token].dead = not wow.state.units[token].dead
                            wow.fire("UNIT_HEALTH", token)
                        end
                    end,
                    strangerBuffs,
                    guildmateLogsIn,
                    function() wow.systemMessage("Gus has joined the instance group.") end,
                    scroll,
                    function() if not wow.state.inCombat then wow.press(button) end end,
                    function() wow.advance(random.random() * 20) end,
                    function() slash(({ "buffmode", "buffmode on", "buffmode off" })[random.random(3)]) end,
                    function()
                        -- The setting's box on the Buff Back tab, as a player clicks it.
                        slash("")
                        wow.run(ns.Options.widgets.tabs.buffBack, "OnClick")
                        local box = ns.Options.widgets.bgPrepBuff
                        prepBuff = random.random() < 0.7
                        box:SetChecked(prepBuff)
                        wow.run(box, "OnClick")
                    end,
                    function()
                        if not inBG then return end
                        wow.endBattleground(random.random(0, 1))
                        ended = true
                    end,
                    function()
                        if not inBG then return end
                        wow.leaveBattleground()
                        inBG, ended, startedHere, aura, timerEnd = false, false, false, false, nil
                        distrusted = false
                    end,
                }
                for step = 1, 600 do
                    local where = ("seed %d, step %d"):format(seed, step)
                    local quietBefore = quietExpected()
                    local sentBefore, emotesBefore, castsBefore = #wow.sent, #wow.emotes, #wow.casts
                    local action = random.random(#actions)
                    actions[action]()
                    local quietAfter = quietExpected()
                    -- Quiet all through the step: it ended no battleground, and
                    -- quiet at both ends is quiet throughout (started stays
                    -- started; without a signal nothing became one).
                    if quietBefore and quietAfter and action < #actions - 1 then
                        quietSteps = quietSteps + 1
                        for i = sentBefore + 1, #wow.sent do
                            local s = wow.sent[i]
                            assert.are.equal("GUILD", s.channel, where .. ": sent " .. s.text)
                            guildLinesWhileQuiet = guildLinesWhileQuiet + 1
                        end
                        assert.are.equal(emotesBefore, #wow.emotes, where .. ": an emote")
                        assert.are.equal(castsBefore, #wow.casts, where .. ": a buff was offered and cast")
                    elseif inBG and not quietBefore then
                        prepCasts = prepCasts + (#wow.casts - castsBefore)
                    end
                    if quietAfter and not wow.state.inCombat then
                        assert.is_nil(wow.state.overrides.MOUSEWHEELUP, where .. ": a key is lent")
                        assert.is_false(button.shown, where .. ": the button shows")
                    end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
            assert.is_true(rounds > 20, "battlegrounds entered: " .. rounds)
            assert.is_true(quietSteps > 300, "steps checked quiet: " .. quietSteps)
            assert.is_true(prepCasts > 5, "buffs given before the gates opened: " .. prepCasts)
            assert.is_true(guildLinesWhileQuiet > 0, "guild hellos while quiet: " .. guildLinesWhileQuiet)
        end)
    end)
end)
