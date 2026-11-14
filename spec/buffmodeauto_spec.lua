-- Spec: #29, #71, #76, #99, #245, #259, #268, #272
-- When buff mode turns on and off by itself.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1 = 9885, 1126
local INTELLECT = 10157

local function logHas(ns, fragment)
    for _, line in ipairs(ns.db.diagLog) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

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
        it("says nothing when a trigger can't turn it on (Buff Back off)", function()
            ns.db.buffBack.enabled = false
            join()
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_false(printedHas("buff mode needs"))
        end)

        it("turns on by default for each trigger: joining, a stranger's buff, a death after a pull", function()
            local b = ns.db.buffBack
            assert.is_true(b.autoOnJoin)
            assert.is_true(b.autoOnDeath)
            assert.is_true(b.autoOnBuffed)
            assert.is_true(b.autoOnMissing)
            -- A member missing your buff turns it on as the fight ends (#272):
            -- off here, so the death is what does.
            b.autoOnMissing = false
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
                return { b.autoOnJoin, b.autoOnDeath, b.autoOnBuffed, b.autoOnMissing }
            end
            assert.are.same({ false, false, false, false }, triggers(wow.boot()))
            assert.are.same({ false, false, false, false }, triggers(wow.boot({ db = { enabled = true } })))
            assert.are.same({ false, false, false, false },
                triggers(wow.boot({ db = { buffBack = { sayLine = true } } })))
            assert.are.same({ true, false, false, false },
                triggers(wow.boot({ db = { buffBack = { autoOnJoin = true } } })))
            local saved = _G.FriendlyForeverDB
            assert.are.same({ true, false, false, false }, triggers(wow.boot({ db = saved })), "kept over a reload")
            assert.are.same({ true, true, true, true },
                triggers(wow.boot({ db = { enabled = true }, autoBuffMode = true })))
        end)

        it("does nothing with every trigger that turns it on switched off", function()
            local b = ns.db.buffBack
            b.autoOnJoin, b.autoOnDeath, b.autoOnBuffed, b.autoOnMissing = false, false, false, false
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
            ns.db.buffBack.autoOnMissing = false -- the death alone (#272)
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
            ns.db.buffBack.autoOnMissing = false -- the death alone (#272)
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
            ns.db.buffBack.autoOnMissing = false -- the death alone (#272)
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

    describe("the debug log (#268)", function()
        before_each(function()
            ns.db.buffBack.autoOnJoin = true
            ns.db.debug = true
            ns.db.diagLog = {}
        end)

        it("logs a turn-on only when buff mode really came on", function()
            ns.db.buffBack.enabled = false
            join()
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_false(logHas(ns, "auto turned on"))
        end)

        it("logs the turn-off when everyone has your buffs", function()
            join()
            assert.is_true(logHas(ns, "auto turned on: you joined a group"))
            scroll()
            scroll()
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(logHas(ns, "auto turned off: everyone has your buffs"))
        end)

        it("logs the turn-off at the timeout, with the minutes", function()
            join()
            wow.advance(5 * 60 + 1)
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(logHas(ns, "auto turned off: 5 minutes passed"))
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

        it("is kept on by a member whose name hasn't loaded ('Unknown')", function()
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            wow.state.units.party1.auras = { MOTW }
            wow.state.units.party2.auras = { MOTW }
            wow.state.units.party2.nameLoading = true
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
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
        -- #259: group slots whose existence reads as secret were passed over
        -- as empty, so "everyone has your buffs" ended it with nobody read.
        it("isn't ended by 'everyone has your buffs' while unit reads are restricted; the timeout still ends it (#259)", function()
            for _, order in ipairs({ "off", "first" }) do
                boot()
                ns.GroupBuffs.SELF_ORDER = order
                ns.db.buffBack.autoOnJoin = true
                join()
                assert.is_true(ns.BuffMode.IsAuto(), order .. ": the join turned it on")
                for _, token in ipairs({ "party1", "party2" }) do wow.state.units[token].auras = { MOTW } end
                wow.gainBuff({ spellId = MOTW, sourceUnit = "player" })
                wow.state.unitsRestricted = true
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.advance(60)
                ns.BuffButton.Refresh()
                assert.is_true(ns.BuffMode.IsAuto(), order .. ": nobody read, so not 'everyone has your buffs'")
                assert.is_false(printedHas("everyone has your buffs"), order)
                wow.advance(5 * 60)
                assert.is_false(ns.BuffMode.IsOn(), order .. ": the timeout ends it")
                assert.are.same({}, wow.errors, order)
            end
        end)

        it("isn't ended by 'everyone has your buffs' while one slot's existence can't be read (#259)", function()
            ns.GroupBuffs.SELF_ORDER = "first"
            ns.db.buffBack.autoOnJoin = true
            join()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.state.units.party1.auras = { MOTW }
            wow.gainBuff({ spellId = MOTW, sourceUnit = "player" })
            local real = _G.UnitExists
            -- party2 (Cid, still missing Mark) reads as a secret slot.
            _G.UnitExists = function(unit)
                if unit == "party2" then return wow.secret(true) end
                return real(unit)
            end
            ns.BuffButton.Refresh()
            assert.is_true(ns.BuffMode.IsAuto(), "Cid can't be read: not done")
            assert.is_false(printedHas("everyone has your buffs"))
            -- Readable again and buffed: it ends as usual.
            _G.UnitExists = real
            wow.state.units.party2.auras = { MOTW }
            ns.BuffButton.Refresh()
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode off (everyone has your buffs)."))
            assert.are.same({}, wow.errors)
        end)

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
            ns.db.buffBack.autoOnMissing = false -- not back on as the fight ends (#272)
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

    -- #245: in a fight the game hides aura updates from addons (#268, seen in
    -- game). A stranger's buff that landed then was never read, so it wasn't
    -- owed and buff mode never turned on.
    describe("a stranger's buff that lands in a fight (#245)", function()
        local nextId = 24500

        -- The buff lands on you (the game's list has it), but the update
        -- that says so is hidden: its fields are secret, or the whole payload.
        local function landHidden(fields, lockPayload)
            nextId = nextId + 1
            local aura = { isHelpful = true, isFromPlayerOrPlayerPet = true, auraInstanceID = nextId,
                name = "Arcane Intellect", spellId = INTELLECT, duration = 1800, expirationTime = wow.now + 1800 }
            for k, v in pairs(fields or {}) do aura[k] = v end
            wow.state.playerAuras[#wow.state.playerAuras + 1] = aura
            if lockPayload then
                wow.fire("UNIT_AURA", "player", wow.secret({ addedAuras = { aura } }))
            else
                wow.fire("UNIT_AURA", "player", { addedAuras = wow.secret({ aura }) })
            end
            return aura
        end

        local function bob(token)
            wow.addUnit(token or "nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
        end

        before_each(function()
            ns.db.buffBack.autoOnBuffed = true
            ns.db.debug = true
        end)

        it("turns buff mode on as the fight ends, owing them, and casts nothing", function()
            bob()
            wow.enterCombat()
            landHidden({ sourceUnit = "nameplate1" })
            wow.advance(20) -- a fight longer than the stale limit
            assert.is_false(ns.BuffMode.IsOn(), "nothing turns on in a fight")
            local casts = #wow.casts
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.are.equal(1, ns.Offers.Count())
            assert.is_true(printedHas("(someone buffed you)"))
            assert.is_true(logHas(ns, "caught up on 1 buff that came while aura updates were hidden"))
            assert.is_true(logHas(ns, "you owe Bob-Stone a buff"))
            assert.are.equal(casts, #wow.casts, "nothing casts without a press")
        end)

        it("does the same when the whole update payload is locked", function()
            bob()
            wow.enterCombat()
            landHidden({ sourceUnit = "nameplate1" }, true)
            wow.advance(10)
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.are.equal(1, ns.Offers.Count())
        end)

        it("catches up at the next update it can read, when the hidden one wasn't in a fight", function()
            bob()
            landHidden({ sourceUnit = "nameplate1" })
            wow.advance(10)
            assert.is_false(ns.BuffMode.IsOn())
            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = {} }) -- any update it can read
            assert.is_true(ns.BuffMode.IsAuto())
            assert.are.equal(1, ns.Offers.Count())
        end)

        it("reads a buff whose own data was locked in a fight once the fight ends", function()
            bob()
            wow.enterCombat()
            nextId = nextId + 1
            local aura = { isHelpful = true, isFromPlayerOrPlayerPet = true, auraInstanceID = nextId,
                name = "Arcane Intellect", spellId = INTELLECT, sourceUnit = "nameplate1",
                duration = 1800, expirationTime = wow.now + 1800 }
            wow.state.playerAuras[#wow.state.playerAuras + 1] = aura
            -- The event's copy is locked, and so is the game's query by its ID.
            wow.state.queryOverride = { [nextId] = wow.secret(aura) }
            wow.fire("UNIT_AURA", "player", { addedAuras = { wow.lockedAura(nextId) } })
            assert.are.equal(0, ns.Offers.Count())
            wow.state.queryOverride = nil
            wow.advance(10)
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.are.equal(1, ns.Offers.Count())
        end)

        it("owes and thanks each hidden buff once, however many updates follow", function()
            ns.db.buff.messages = { "Thanks, {name}!" }
            ns.db.buff.thankStyle = "whisper"
            bob()
            wow.enterCombat()
            landHidden({ sourceUnit = "nameplate1" })
            wow.leaveCombat()
            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = {} })
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            wow.advance(ns.db.buff.delay + 1)
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            local owed = 0
            for _, line in ipairs(ns.db.diagLog) do
                if line:find("you owe Bob-Stone a buff", 1, true) then owed = owed + 1 end
            end
            assert.are.equal(1, owed)
            assert.are.equal(1, #wow.sentTo("WHISPER"))
            assert.are.equal(1, #ns.db.ledger.entries)
        end)

        it("doesn't count a buff you already had before the fight, or one cast before the updates were hidden", function()
            bob()
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Mark of the Wild", spellId = MOTW }) -- read and owed
            slash("buffmode off")
            ns.Offers.Forget("Bob-Stone")
            wow.advance(60)
            wow.enterCombat()
            -- Re-sent by the game, hidden: cast a minute ago, before anything was hidden.
            landHidden({ sourceUnit = "nameplate1", name = "Thorns", spellId = 9910,
                duration = 600, expirationTime = wow.now + 540 })
            wow.advance(10)
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.equal(0, ns.Offers.Count())
            assert.is_true(logHas(ns, "Thorns (spell 9910): cast 70s ago, so I already had it -> skip"))
        end)

        local function owedLines(name)
            local n = 0
            for _, line in ipairs(ns.db.diagLog) do
                if line:find("you owe " .. name .. " a buff", 1, true) then n = n + 1 end
            end
            return n
        end

        it("in a fight, a buff it still can't read is looked at again as the fight ends; one it read isn't read twice",
            function()
                ns.db.buff.thankStyle = "whisper"
                bob()
                wow.addUnit("nameplate2", { name = "Gus", surname = "Stone", class = "MAGE", id = "Gus-Stone" })
                wow.enterCombat()
                landHidden({ sourceUnit = "nameplate1" })
                -- Gus's buff is on the game's list, but its entry can't be read yet.
                -- (A secret instance ID stands in for an entry the addon can't
                -- read: the simulated list can't hold a secret table.)
                local gus = landHidden({ sourceUnit = "nameplate2", name = "Mark of the Wild", spellId = MOTW })
                local gusId = gus.auraInstanceID
                gus.auraInstanceID = wow.secret(gusId)
                wow.advance(ns.db.buff.delay + 1)
                wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = {} }) -- readable, still in the fight
                assert.are.equal(1, owedLines("Bob-Stone"))
                assert.are.equal(0, owedLines("Gus-Stone"))
                wow.advance(ns.db.buff.delay + 1) -- Bob's thank-you has gone: a second read would be a new favour
                gus.auraInstanceID = gusId
                wow.leaveCombat()
                assert.are.equal(1, owedLines("Bob-Stone"), "Bob's buff is read once")
                assert.are.equal(1, owedLines("Gus-Stone"), "Gus's buff is read as the fight ends")
                assert.are.equal(2, ns.Offers.Count())
                assert.is_true(ns.BuffMode.IsAuto())
            end)

        it("a new buff in the update that catches up is read once, not again from the update", function()
            bob()
            landHidden({ sourceUnit = "nameplate1" })
            wow.addUnit("nameplate3", { name = "Hal", surname = "Stone", class = "MAGE", id = "Hal-Stone" })
            wow.gainBuff({ sourceUnit = "nameplate3", name = "Mark of the Wild", spellId = MOTW })
            assert.are.equal(1, owedLines("Hal-Stone"))
            assert.are.equal(1, owedLines("Bob-Stone"))
            assert.is_false(logHas(ns, "added to the thank-you already waiting for Hal-Stone"))
        end)

        it("still doesn't count a group member's buff, or your own, that came in a fight", function()
            ns.db.buffBack.autoOnMissing = false -- Ann missing your Mark would turn it on (#272)
            join({ "Ann-Vale" })
            slash("buffmode off")
            wow.enterCombat()
            landHidden({ sourceUnit = "party1" })
            landHidden({ sourceUnit = "player", name = "Thorns", spellId = 9910 })
            wow.leaveCombat()
            assert.is_false(printedHas("(someone buffed you)"))
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("isn't lost when the game won't list your buffs as the fight ends: read at the next update", function()
            bob()
            wow.enterCombat()
            landHidden({ sourceUnit = "nameplate1" })
            wow.state.aurasRestricted = true
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn())
            wow.state.aurasRestricted = false
            wow.advance(30)
            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = {} })
            assert.is_true(ns.BuffMode.IsAuto())
            assert.are.equal(1, ns.Offers.Count())
        end)

        it("with the addon switched off as the fight ends, notes the hidden buff without owing it", function()
            bob()
            wow.enterCombat()
            landHidden({ sourceUnit = "nameplate1" })
            ns.db.enabled = false -- nothing is watched: the buff is only noted
            wow.leaveCombat()
            ns.db.enabled = true
            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = {} })
            assert.are.equal(0, ns.Offers.Count())
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("counts the time unreadable from the first hidden update, not the last", function()
            bob()
            wow.enterCombat()
            landHidden({ sourceUnit = "nameplate1" })
            wow.advance(15)
            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = wow.secret({}) }) -- another change, hidden
            wow.advance(5)
            wow.leaveCombat()
            assert.are.equal(1, ns.Offers.Count())
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("out of a fight, an entry it can't read doesn't keep the stale limit stretched afterwards", function()
            bob()
            local odd = { isHelpful = true, isFromPlayerOrPlayerPet = true, auraInstanceID = wow.secret(24999),
                sourceUnit = "player", name = "Thorns", spellId = 9910, duration = 600, expirationTime = wow.now + 600 }
            wow.state.playerAuras[#wow.state.playerAuras + 1] = odd
            wow.fire("UNIT_AURA", "player", wow.secret({})) -- a locked payload, out of a fight
            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = {} }) -- readable: it catches up
            wow.advance(3600)
            -- Re-sent by the game under a new ID (zoning): Bob cast it 700 s ago.
            nextId = nextId + 1
            wow.state.playerAuras[#wow.state.playerAuras + 1] = { isHelpful = true, isFromPlayerOrPlayerPet = true,
                auraInstanceID = nextId, sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT,
                duration = 1800, expirationTime = wow.now + 1100 }
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            assert.are.equal(0, ns.Offers.Count())
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("a buff read by a catch-up in the fight isn't read again as the fight ends", function()
            ns.db.buff.thankStyle = "whisper"
            bob()
            wow.enterCombat()
            landHidden({ sourceUnit = "nameplate1" })
            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = {} }) -- readable: it catches up in the fight
            wow.advance(ns.db.buff.delay + 1) -- the thank-you goes
            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = wow.secret({}) }) -- hidden again
            wow.leaveCombat()
            wow.advance(ns.db.buff.delay + 1)
            assert.are.equal(1, owedLines("Bob-Stone"))
            assert.are.equal(1, #wow.sentTo("WHISPER"))
        end)

        it("a full update whose list the game refuses forgets nothing, so a buff caught up once isn't read again",
            function()
                ns.db.buff.thankStyle = "whisper"
                bob()
                wow.enterCombat()
                landHidden({ sourceUnit = "nameplate1" })
                wow.advance(2)
                wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = {} }) -- caught up: Bob is owed
                wow.advance(1)
                wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = wow.secret({}) }) -- hidden again
                wow.state.aurasRestricted = true
                wow.fire("UNIT_AURA", "player", { isFullUpdate = true }) -- the game won't list your buffs
                wow.state.aurasRestricted = false
                wow.advance(30)
                wow.leaveCombat()
                wow.advance(ns.db.buff.delay + 1)
                assert.are.equal(1, owedLines("Bob-Stone"))
                assert.are.equal(1, #wow.sentTo("WHISPER"))
                assert.are.equal(1, #ns.db.ledger.entries)
            end)

        it("a full update whose list the game refuses is read later: a buff landing then isn't lost", function()
            bob()
            wow.state.aurasRestricted = true
            nextId = nextId + 1
            wow.state.playerAuras[#wow.state.playerAuras + 1] = { isHelpful = true, isFromPlayerOrPlayerPet = true,
                auraInstanceID = nextId, sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT,
                duration = 1800, expirationTime = wow.now + 1800 }
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            assert.are.equal(0, ns.Offers.Count())
            wow.state.aurasRestricted = false
            wow.advance(20)
            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = {} })
            assert.are.equal(1, ns.Offers.Count())
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("a full update whose list breaks off part way reads what it saw once, and the rest later", function()
            ns.db.buff.thankStyle = "whisper"
            bob()
            wow.addUnit("nameplate2", { name = "Gus", surname = "Stone", class = "MAGE", id = "Gus-Stone" })
            for _, who in ipairs({ "nameplate1", "nameplate2" }) do
                nextId = nextId + 1
                wow.state.playerAuras[#wow.state.playerAuras + 1] = { isHelpful = true, isFromPlayerOrPlayerPet = true,
                    auraInstanceID = nextId, sourceUnit = who, name = "Arcane Intellect", spellId = INTELLECT,
                    duration = 1800, expirationTime = wow.now + 1800 }
            end
            -- The game gives the first entry, then raises an error.
            local byIndex = _G.C_UnitAuras.GetAuraDataByIndex
            _G.C_UnitAuras.GetAuraDataByIndex = function(unit, index, ...)
                if unit == "player" and index > 1 then error("aura data is restricted") end
                return byIndex(unit, index, ...)
            end
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            assert.are.equal(1, owedLines("Bob-Stone"))
            assert.are.equal(0, owedLines("Gus-Stone"))
            _G.C_UnitAuras.GetAuraDataByIndex = byIndex
            wow.advance(ns.db.buff.delay + 1) -- Bob's thank-you goes: a second read would be a new favour
            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = {} })
            assert.are.equal(1, owedLines("Bob-Stone"), "Bob's buff is read once")
            assert.are.equal(1, owedLines("Gus-Stone"), "Gus's buff is read once the list comes back")
        end)

        it("when the game won't list your buffs, a readable update's new buff is still read", function()
            bob()
            wow.fire("UNIT_AURA", "player", wow.secret({})) -- something was missed
            wow.state.aurasRestricted = true
            nextId = nextId + 1
            local aura = { isHelpful = true, isFromPlayerOrPlayerPet = true, auraInstanceID = nextId,
                sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT,
                duration = 1800, expirationTime = wow.now + 1800 }
            wow.state.playerAuras[#wow.state.playerAuras + 1] = aura
            wow.fire("UNIT_AURA", "player", { addedAuras = { aura } })
            assert.are.equal(1, ns.Offers.Count())
        end)

        it("chaos: hidden and readable updates, refused lists, unreadable entries, locked data and fights in " ..
            "any order read each buff at most once, never turn buff mode on in a fight, and raise no Lua error",
            function()
                -- How often the storm reached each path, over all seeds.
                local reach = { fightEnd = 0, update = 0, refused = 0, partial = 0, locked = 0, read = 0 }
                for _, seed in ipairs({ 7, 245, 9001 }) do
                    random.seed(seed)
                    boot()
                    ns.db.buffBack.autoOnBuffed, ns.db.debug = true, true
                    -- Each landed buff has a name of its own, so each read is counted
                    -- from what reached the thank-you, not from the code's own state.
                    local reads, hiddenIds, n = {}, {}, 0
                    local addBuff = ns.BuffTracker.AddBuff
                    ns.BuffTracker.AddBuff = function(caster, key, name, ...)
                        reads[name] = (reads[name] or 0) + 1
                        return addBuff(caster, key, name, ...)
                    end
                    local catchUp, from = ns.BuffTracker.CatchUp, nil
                    ns.BuffTracker.CatchUp = function()
                        local unreadable = next(hiddenIds) ~= nil
                        local ok = catchUp()
                        if wow.state.aurasRestricted then
                            reach.refused = reach.refused + 1
                        elseif from and ok then
                            reach[from] = reach[from] + 1
                            if unreadable and wow.state.inCombat then reach.partial = reach.partial + 1 end
                        end
                        return ok
                    end
                    local log = ns.Diag.Log
                    ns.Diag.Log = function(cat, fmt, ...)
                        if fmt:find("its data is locked", 1, true) then reach.locked = reach.locked + 1 end
                        return log(cat, fmt, ...)
                    end
                    local function newAura(name)
                        n = n + 1
                        local aura = { isHelpful = true, isFromPlayerOrPlayerPet = true, auraInstanceID = 50000 + n,
                            name = "Buff " .. seed .. "-" .. n, spellId = INTELLECT, sourceUnit = "nameplate1",
                            duration = 1800, expirationTime = wow.now + 1800 }
                        wow.addUnit("nameplate1", { name = name, surname = "Stone", class = "MAGE", id = name .. "-Stone" })
                        wow.state.playerAuras[#wow.state.playerAuras + 1] = aura
                        return aura
                    end
                    for step = 1, 300 do
                        local where = ("seed %d, step %d"):format(seed, step)
                        local wasOn = ns.BuffMode.IsOn()
                        local name = ({ "Bob", "Gus", "Hal" })[random.random(3)]
                        local r = random.random(11)
                        from = nil
                        if r == 1 then
                            from = "fightEnd"
                            if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end
                        elseif r == 2 then
                            landHidden({ sourceUnit = "nameplate1", name = "Buff " .. seed .. "-h" .. step },
                                random.random() < 0.3)
                            wow.addUnit("nameplate1", { name = name, surname = "Stone", class = "MAGE",
                                id = name .. "-Stone" })
                        elseif r == 3 then
                            -- A readable update that brings a new buff.
                            from = "update"
                            local aura = newAura(name)
                            wow.fire("UNIT_AURA", "player", { addedAuras = { aura } })
                        elseif r == 4 then
                            -- A buff whose data is locked, in the event and in the game's query.
                            from = "update"
                            local aura = newAura(name)
                            wow.state.queryOverride = wow.state.queryOverride or {}
                            wow.state.queryOverride[aura.auraInstanceID] = wow.secret(aura)
                            wow.fire("UNIT_AURA", "player", { addedAuras = { wow.lockedAura(aura.auraInstanceID) } })
                        elseif r == 5 then
                            from = "update"
                            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = {} })
                        elseif r == 6 then
                            from = "update"
                            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
                        elseif r == 7 then
                            wow.state.aurasRestricted = not wow.state.aurasRestricted
                        elseif r == 8 then
                            -- One entry on the list can't be read, or can again.
                            -- (A secret instance ID stands in for an entry the addon
                            -- can't read: the simulated list can't hold a secret table.)
                            local aura = wow.state.playerAuras[random.random(math.max(1, #wow.state.playerAuras))]
                            if aura and hiddenIds[aura] then
                                aura.auraInstanceID, hiddenIds[aura] = hiddenIds[aura], nil
                            elseif aura then
                                hiddenIds[aura], aura.auraInstanceID = aura.auraInstanceID, wow.secret(aura.auraInstanceID)
                            end
                        elseif r == 9 then
                            wow.advance(random.random() * 20)
                        elseif r == 10 then
                            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = wow.secret({}) })
                        else
                            slash("buffmode off")
                        end
                        assert.is_true(not (wow.state.inCombat and not wasOn and ns.BuffMode.IsAuto()),
                            where .. ": turned on in a fight")
                        for buffName, count in pairs(reads) do
                            assert.is_true(count <= 1, ("%s: %s read %d times"):format(where, buffName, count))
                        end
                    end
                    for _ in pairs(reads) do reach.read = reach.read + 1 end
                    assert.are.same({}, wow.errors, "seed " .. seed)
                end
                for path, count in pairs(reach) do
                    assert.is_true(count > 0, "the storm never reached: " .. path)
                end
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
