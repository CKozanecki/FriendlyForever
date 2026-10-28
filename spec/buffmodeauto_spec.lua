-- Spec: #29, #76
-- When buff mode turns on and off by itself.
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

describe("Buff mode turning on and off by itself", function()
    local ns

    -- A druid who knows Mark of the Wild (one buff keeps the counting simple).
    local function boot(db)
        ns = wow.boot({ db = db, autoBuffMode = true, before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
        end })
    end

    local function lent() return ns.BuffMode.LentKey() end

    local function join(names)
        wow.setGroup("party", names or { "Ann-Vale", "Cid-Rock" })
        wow.fire("GROUP_ROSTER_UPDATE")
    end

    local function leave()
        wow.setGroup(nil, {})
        wow.fire("GROUP_ROSTER_UPDATE")
    end

    local function dies(token)
        wow.state.units[token].dead = true
        wow.fire("UNIT_HEALTH", token)
    end

    -- Scroll once and let the buff show on whoever it reached.
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

    before_each(function() boot() end)

    describe("turning on", function()
        it("turns on by default for each trigger: joining, a stranger's buff, a death after a pull", function()
            local b = ns.db.buffBack
            assert.is_true(b.autoOnJoin)
            assert.is_true(b.autoOnDeath)
            assert.is_true(b.autoOnBuffed)
            join()
            assert.is_true(ns.BuffMode.IsOn())
            assert.is_true(printedHas("(you joined a group)"))
            slash("buffmode off")
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            assert.is_true(ns.BuffMode.IsOn())
            assert.is_true(printedHas("(someone buffed you)"))
            slash("buffmode off")
            wow.enterCombat()
            wow.leaveCombat()
            dies("party1")
            assert.is_true(ns.BuffMode.IsOn())
            assert.is_true(printedHas("(someone in your group died)"))
        end)

        it("says once a session where the triggers are switched, and not when you turn it on yourself", function()
            local HINT = "choose when on the Buff Back tab"
            local function hints()
                local n = 0
                for _, line in ipairs(wow.printed) do
                    if line:find(HINT, 1, true) then n = n + 1 end
                end
                return n
            end
            slash("buffmode on")
            slash("buffmode off")
            assert.are.equal(0, hints(), "your own buff mode needs no hint")
            join()
            assert.is_true(ns.BuffMode.IsOn())
            assert.are.equal(1, hints())
            leave()
            slash("buffmode off")
            join({ "Cid-Rock" })
            assert.is_true(ns.BuffMode.IsOn())
            assert.are.equal(1, hints(), "once a session")
        end)

        it("other specs start with the triggers off unless their saved settings set them", function()
            local function triggers(n)
                local b = n.db.buffBack
                return { b.autoOnJoin, b.autoOnDeath, b.autoOnBuffed }
            end
            assert.are.same({ false, false, false }, triggers(wow.boot()))
            assert.are.same({ false, false, false }, triggers(wow.boot({ db = { enabled = true } })))
            assert.are.same({ false, false, false }, triggers(wow.boot({ db = { buffBack = { sayLine = true } } })))
            assert.are.same({ true, false, false }, triggers(wow.boot({ db = { buffBack = { autoOnJoin = true } } })))
            local saved = _G.FriendlyForeverDB
            assert.are.same({ true, false, false }, triggers(wow.boot({ db = saved })), "kept over a reload")
            assert.are.same({ true, true, true }, triggers(wow.boot({ db = { enabled = true }, autoBuffMode = true })))
        end)

        it("does nothing with every trigger that turns it on switched off", function()
            local b = ns.db.buffBack
            b.autoOnJoin, b.autoOnDeath, b.autoOnBuffed = false, false, false
            join()
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            wow.enterCombat()
            wow.leaveCombat()
            dies("party1")
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_nil(lent())
        end)

        it("turns on when you join a group, saying why", function()
            ns.db.buffBack.autoOnJoin = true
            join()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.are.equal("MOUSEWHEELUP", lent())
            assert.is_true(printedHas("buff mode on (you joined a group): MOUSEWHEELUP presses the buff-back button."))
            wow.printed = {}
            join({ "Ann-Vale", "Cid-Rock", "Dot-Fern" }) -- the roster changing isn't joining again
            assert.is_false(printedHas("buff mode on"))
        end)

        it("turns on when someone outside your group buffs you", function()
            ns.db.buffBack.autoOnBuffed = true
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("(someone buffed you)"))
        end)

        it("join, pull, death, pull: on, off, on, off", function()
            ns.db.buffBack.autoOnJoin = true
            ns.db.buffBack.autoOnDeath = true
            local states = {}
            local function note() states[#states + 1] = ns.BuffMode.IsOn() and "on" or "off" end
            join()
            note()
            wow.enterCombat()
            note()
            dies("party1")
            wow.leaveCombat()
            note()
            wow.enterCombat()
            note()
            assert.are.same({ "on", "off", "on", "off" }, states)
            assert.is_true(printedHas("buff mode off (the fight started)."))
            assert.is_true(printedHas("(someone in your group died)"))
            assert.are.same({}, wow.errors)
        end)

        it("doesn't turn on for a death before the group's first pull", function()
            ns.db.buffBack.autoOnJoin = false
            join()
            dies("party1")
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("answers a death out of a fight at once, after the first pull", function()
            ns.db.buffBack.autoOnDeath = true
            join()
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn(), "nobody died")
            dies("party2") -- a fall, say
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("never turns on in a fight: a trigger in one waits for it to end", function()
            ns.db.buffBack.autoOnJoin = true
            wow.enterCombat()
            join()
            assert.is_false(ns.BuffMode.IsOn())
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.are.equal("MOUSEWHEELUP", lent())
        end)

        it("doesn't lend a key when there's nothing to buff", function()
            ns.db.buffBack.autoOnJoin = true
            wow.setGroup("party", { "Ann-Vale" })
            wow.state.units.party1.auras = { MOTW }
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_false(printedHas("buff mode"))
        end)

        it("doesn't count a group you were already in at login as joining one", function()
            ns = wow.boot({ db = { buffBack = { autoOnJoin = true } }, autoBuffMode = true, before = function(state)
                state.class = "DRUID"
                state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
                -- The roster arrives after the addon loads, as it does in the game.
                local f = CreateFrame("Frame")
                f:RegisterEvent("PLAYER_ENTERING_WORLD")
                f:SetScript("OnEvent", function()
                    -- ...with its update before the addon has seen the login finish.
                    wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
                    wow.fire("GROUP_ROSTER_UPDATE")
                end)
            end })
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(ns.BuffMode.IsOn(), "buff mode is off after a login")
        end)

        it("counts a death once: a ghost's health changing isn't another", function()
            ns.db.buffBack.autoOnDeath = true
            join()
            wow.enterCombat()
            dies("party1")
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.enterCombat() -- the next pull ends it
            wow.fire("UNIT_HEALTH", "party1") -- they release: still dead, as a ghost
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn(), "nobody died in that fight")
            wow.fire("UNIT_HEALTH", "party1")
            assert.is_false(ns.BuffMode.IsOn())
            wow.state.units.party1.dead = false -- rezzed
            wow.fire("UNIT_HEALTH", "party1")
            dies("party1") -- and dies again
            assert.is_true(ns.BuffMode.IsAuto(), "a new death counts")
        end)

        it("doesn't count someone who joins already dead as a death", function()
            ns.db.buffBack.autoOnDeath = true
            join()
            wow.enterCombat()
            wow.leaveCombat()
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock", "Dot-Fern" })
            wow.state.units.party3.dead = true
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.fire("UNIT_HEALTH", "party3")
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("is switched in the Buff Back tab", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            for _, field in ipairs(ns.Options.AUTO_SWITCHES) do
                local box = w.auto[field]
                assert.is_true(box:IsShown(), field)
                box:SetChecked(not ns.db.buffBack[field])
                wow.run(box, "OnClick")
                assert.are.equal(box:GetChecked(), ns.db.buffBack[field], field)
            end
            assert.is_true(w.steppers.autoOffMinutes.box:IsShown())
            wow.run(w.steppers.autoOffMinutes.plus, "OnClick")
            assert.are.equal(6, ns.db.buffBack.autoOffMinutes)
            wow.run(w.tabs.buff, "OnClick")
            assert.is_false(w.auto.autoOnJoin:IsShown())
            assert.is_false(w.steppers.autoOffMinutes.box:IsShown())
        end)
    end)

    describe("turning off", function()
        before_each(function() ns.db.buffBack.autoOnJoin = true end)

        it("turns off once everyone has your buffs", function()
            join()
            scroll()
            assert.is_true(ns.BuffMode.IsOn(), "Cid still needs it")
            scroll()
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_nil(lent())
            assert.is_true(printedHas("buff mode off (everyone has your buffs)."))
        end)

        it("isn't kept on by a member it can't buff anyway (offline, out of sight, or skipped)", function()
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock", "Dot-Fern" })
            wow.state.units.party2.offline = true
            wow.state.units.party3.hidden = true
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.BuffMode.IsOn(), "Ann needs it")
            scroll()
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("(everyone has your buffs)"))
        end)

        it("ends at the pull without arming the button for the fight, even with a favour owed", function()
            ns.db.buffBack.autoOnJoin = false
            ns.db.buffBack.autoOnBuffed = true
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_truthy(ns.BuffButton.ArmedOffer(), "the favour is armed before the pull")
            wow.enterCombat()
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_nil(ns.BuffButton.ArmedOffer(), "empty for the fight")
            local button = ns.BuffButton.Frame()
            assert.is_nil(button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText))
            assert.is_false(button:IsShown())
            assert.is_true(printedHas("buff mode off (the fight started)."))
            assert.are.same({}, wow.errors)
        end)

        it("is kept on by a member who's dead or out of range, who still needs a buff", function()
            ns.db.buffBack.autoOnJoin = false
            ns.db.buffBack.autoOnDeath = true
            join()
            wow.state.units.party1.auras = { MOTW }
            wow.state.units.party2.auras = { MOTW }
            wow.enterCombat()
            wow.state.units.party1.auras = nil -- a death takes the buffs
            dies("party1")
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto(), "Ann needs it once she's up")
            wow.advance(30)
            assert.is_true(ns.BuffMode.IsOn(), "not 'everyone has your buffs' while she's dead")

            boot()
            ns.db.buffBack.autoOnJoin = true
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            wow.state.units.party1.auras = { MOTW }
            wow.state.units.party2.outOfRange = true
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.BuffMode.IsAuto(), "Cid needs it when he's back in range")
        end)

        it("is kept on by a member whose PvP flag can't be read, or whose cast was just refused", function()
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            wow.state.units.party1.auras = { MOTW }
            wow.state.units.party2.secrets = { pvp = true }
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.BuffMode.IsAuto(), "unreadable flag: may still need it")

            boot()
            ns.db.buffBack.autoOnJoin = true
            join()
            wow.state.castFailures["Cid-Rock"] = "Target not in line of sight"
            scroll() -- Ann
            wow.pressKey("MOUSEWHEELUP") -- Cid: refused
            assert.is_true(ns.BuffMode.IsOn(), "Cid still needs it once he's in sight")
        end)

        it("isn't kept on by a member flagged for PvP when you aren't, or one you right-clicked away", function()
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            wow.state.units.party2.pvp = true
            wow.fire("GROUP_ROSTER_UPDATE")
            scroll()
            assert.is_false(ns.BuffMode.IsOn(), "flagged: nothing you'd do")
            assert.is_true(printedHas("(everyone has your buffs)"))

            boot()
            ns.db.buffBack.autoOnJoin = true
            join()
            scroll() -- Ann
            wow.press(ns.BuffButton.Frame(), "RightButton") -- skip Cid
            assert.is_false(ns.BuffMode.IsOn(), "skipped: you chose not to")
        end)

        it("is kept on by a member whose name can't be read", function()
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            wow.state.units.party1.auras = { MOTW }
            wow.state.units.party2.secrets = { name = true }
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("turns off after the timeout, and never with 0", function()
            join()
            wow.advance(5 * 60 - 10)
            assert.is_true(ns.BuffMode.IsOn())
            wow.advance(11)
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode off (5 minutes passed)."))
            leave()
            ns.db.buffBack.autoOffMinutes = 0
            join()
            wow.advance(30 * 60)
            assert.is_true(ns.BuffMode.IsOn())
        end)

        it("a new start gets its own full timeout; the last one's timer doesn't cut it short", function()
            join()
            wow.advance(60)
            leave()
            slash("buffmode off")
            wow.advance(3 * 60)
            join()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.advance(2 * 60) -- the first start's timer would end it here
            assert.is_true(ns.BuffMode.IsOn())
            wow.advance(3 * 60 + 1)
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("each way off can be switched off", function()
            ns.db.buffBack.autoOffPull = false
            ns.db.buffBack.autoOffDone = false
            ns.db.buffBack.autoOffMinutes = 0
            join()
            wow.enterCombat()
            assert.is_true(ns.BuffMode.IsOn(), "the pull doesn't end it")
            assert.is_nil(lent(), "the key is still handed back for the fight")
            wow.leaveCombat()
            scroll()
            scroll()
            assert.is_true(ns.BuffMode.IsOn(), "everyone buffed doesn't end it")
            assert.are.equal("MOUSEWHEELUP", lent())
        end)

        it("never turns off buff mode you turned on yourself", function()
            join({ "Ann-Vale" })
            slash("buffmode off")
            slash("buffmode on")
            assert.is_false(ns.BuffMode.IsAuto())
            wow.enterCombat()
            wow.leaveCombat()
            scroll()
            wow.advance(31 * 60)
            assert.is_true(ns.BuffMode.IsOn())
        end)

        it("a manual switch makes a trigger's buff mode yours", function()
            join()
            assert.is_true(ns.BuffMode.IsAuto())
            slash("buffmode on")
            assert.is_false(ns.BuffMode.IsAuto())
            wow.advance(6 * 60)
            assert.is_true(ns.BuffMode.IsOn())
        end)
    end)

    describe("what it can't see (black)", function()
        it("never assumes everyone is buffed when someone's buffs can't be read; the timeout still ends it", function()
            ns.db.buffBack.autoOnJoin = true
            wow.setGroup("party", { "Ann-Vale" })
            wow.state.units.party1.auras = { MOTW }
            wow.state.units.party1.secrets = { auras = true }
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.BuffMode.IsOn(), "can't tell: worth buff mode")
            wow.advance(60)
            assert.is_true(ns.BuffMode.IsOn(), "not 'everyone has your buffs'")
            wow.advance(5 * 60)
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("ends at the timeout even in a fight (the key is already handed back)", function()
            ns.db.buffBack.autoOnJoin = true
            ns.db.buffBack.autoOffPull = false
            join()
            wow.enterCombat()
            wow.advance(5 * 60 + 1)
            assert.is_false(ns.BuffMode.IsOn())
            wow.leaveCombat()
            assert.is_nil(lent())
            assert.are.same({}, wow.errors)
        end)

        it("repairs damaged settings, and keeps working when they're damaged mid-session", function()
            boot({ buffBack = { autoOnJoin = "yes", autoOffMinutes = 999, autoOffDone = {} } })
            local b = ns.db.buffBack
            assert.is_true(b.autoOnJoin, "repaired to the default")
            assert.are.equal(ns.Config.LIMITS.autoOffMinutes.max, b.autoOffMinutes)
            assert.is_true(b.autoOffDone)
            b.autoOnJoin = true
            b.autoOffMinutes = "ten"
            b.autoOffDone = 7
            join()
            wow.advance(60)
            assert.are.same({}, wow.errors)
            assert.is_true(ns.BuffMode.IsOn())
            wow.advance(5 * 60)
            assert.is_false(ns.BuffMode.IsOn(), "a damaged timeout reads as the default, not never")
        end)
    end)

    describe("chaos (red tests)", function()
        -- What the simulated client shows after a step, for the replay check:
        -- the clock, the fight, who is in which party slot, the keys lent, and
        -- what was printed, sent and cast.
        local function snapshot()
            local keys, slots = {}, {}
            for key in pairs(wow.state.overrides) do keys[#keys + 1] = key end
            table.sort(keys)
            for i = 1, 4 do
                local u = wow.state.units["party" .. i]
                slots[i] = u and (u.id .. (u.dead and " (dead)" or "")) or "-"
            end
            return table.concat({ wow.now, tostring(wow.state.inCombat), table.concat(slots, ","),
                table.concat(keys, "+"), #wow.printed, wow.printed[#wow.printed] or "", #wow.sent, #wow.casts }, " | ")
        end

        -- One seeded storm; returns how often it reached the outcomes that
        -- count, and the client's state after every step.
        local function storm(seed)
            local turnedOn, timedOut, hinted, trace = 0, 0, 0, {}
            random.seed(seed)
            boot()
            local function setAll()
                local b = ns.db.buffBack
                b.autoOnJoin, b.autoOnDeath, b.autoOnBuffed = true, true, true
                b.autoOffPull = random.random() < 0.5
                b.autoOffDone = random.random() < 0.5
                b.autoOffMinutes = random.random(1, 3)
            end
            setAll()
            local startedAt
            local everyone = { "Ann-Vale", "Cid-Rock", "Dot-Fern", "Eve-Moss" }
            local actions = {
                function()
                    local names = {}
                    for _, n in ipairs(everyone) do if random.random() < 0.6 then names[#names + 1] = n end end
                    if #names == 0 then leave() else join(names) end
                end,
                leave,
                function()
                    local token = "party" .. random.random(1, 4)
                    if wow.state.units[token] then dies(token) end
                end,
                function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                function()
                    local token = "nameplate" .. random.random(1, 3)
                    local name = ({ "Bob", "Gus", "Hal" })[random.random(3)]
                    wow.addUnit(token, { name = name, surname = "Stone", class = "MAGE", id = name .. "-Stone" })
                    wow.gainBuff({ sourceUnit = token, name = "Arcane Intellect", spellId = INTELLECT })
                end,
                scroll,
                function() wow.advance(random.random() * 40) end,
                function() slash(({ "buffmode", "buffmode on", "buffmode off" })[random.random(3)]) end,
                function()
                    wow.state.inCombat = false
                    boot(_G.FriendlyForeverDB)
                    setAll()
                end,
                function() ns.db.buffBack.autoOffMinutes = random.random(1, 3) end,
            }
            local limit -- the timeout in force when the trigger's buff mode started
            local function track(where)
                if ns.BuffMode.IsAuto() then
                    if not startedAt then
                        startedAt, limit = wow.now, ns.db.buffBack.autoOffMinutes * 60
                        turnedOn = turnedOn + 1
                    end
                    assert.is_true(wow.now - startedAt <= limit, where .. ": past its timeout")
                else
                    startedAt = nil
                end
            end
            for step = 1, 500 do
                local where = ("seed %d, step %d"):format(seed, step)
                local wasOn = ns.BuffMode.IsOn()
                actions[random.random(#actions)]()
                -- Including the step that starts a fight.
                assert.is_true(not (wow.state.inCombat and not wasOn and ns.BuffMode.IsAuto()),
                    where .. ": turned on in a fight")
                track(where)
                assert.is_true(not wow.state.inCombat or lent() == nil, where .. ": a key lent in a fight")
                -- The hint is said at most once a session (a reload starts a new one).
                local hints = 0
                for _, line in ipairs(wow.printed) do
                    if line:find("choose when on the Buff Back tab", 1, true) then hints = hints + 1 end
                end
                assert.is_true(hints <= 1, where .. ": the hint said " .. hints .. " times")
                if hints == 1 then hinted = hinted + 1 end
                -- Now and then, nothing but time: the timeout itself must end it.
                if step % 25 == 0 and ns.BuffMode.IsAuto() then
                    wow.advance(limit - (wow.now - startedAt))
                    assert.is_false(ns.BuffMode.IsAuto(), where .. ": still on at its timeout")
                    timedOut = timedOut + 1
                    track(where)
                end
                trace[step] = snapshot()
            end
            assert.are.same({}, wow.errors, "seed " .. seed)
            return turnedOn, timedOut, hinted, trace
        end

        it("never turns buff mode on in a fight, and a trigger's buff mode always ends within the timeout", function()
            local turnedOn, timedOut, hinted = 0, 0, 0
            for _, seed in ipairs({ 4, 29, 81, 512, 2026 }) do
                local on, out, hint = storm(seed)
                turnedOn, timedOut, hinted = turnedOn + on, timedOut + out, hinted + hint
            end
            assert.is_true(turnedOn > 20, "turned on by triggers: " .. turnedOn)
            assert.is_true(timedOut > 5, "ended by the timeout alone: " .. timedOut)
            assert.is_true(hinted > 0, "the hint was said")
        end)

        it("replays a seed's storm identically, step by step (#76)", function()
            local _, _, _, first = storm(29)
            -- Something in between, so the replay doesn't start from the same memory.
            storm(81)
            local _, _, _, again = storm(29)
            assert.are.equal(500, #first)
            for step = 1, #first do
                assert.are.equal(first[step], again[step], "step " .. step)
            end
        end)
    end)
end)
