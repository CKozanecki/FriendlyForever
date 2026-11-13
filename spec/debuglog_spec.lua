-- Spec: #268, #294
-- The debug log holds decisions, not repeats, so an hour in a dungeon fits.
local wow = require("spec.support.wow")

local MOTW, MOTW_1 = 9885, 1126
local DEADMINES = 36

describe("The debug log keeps decisions, not repeats (#268)", function()
    local ns

    local function boot(extra)
        ns = wow.boot({ autoBuffMode = true, before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
            state.guildRoster = { "Thrall", "Jaina" }
            if extra then extra(state) end
        end })
        ns.db.debug = true
        ns.db.diagLog = {}
    end

    local function count(fragment)
        local n = 0
        for _, line in ipairs(ns.db.diagLog) do
            if line:find(fragment, 1, true) then n = n + 1 end
        end
        return n
    end

    local function restricted() wow.fire("UNIT_AURA", "player", { isFullUpdate = wow.secret(false) }) end

    before_each(function() boot() end)

    describe("restricted aura updates (white)", function()
        it("logs one line per run, then the count when combat ends", function()
            wow.enterCombat()
            for _ = 1, 50 do restricted() end
            assert.are.equal(1, count("aura update is restricted"))
            wow.leaveCombat()
            assert.are.equal(1, count("49 more restricted aura updates skipped"))
            assert.are.equal(50, ns.Diag.Counters().restrictedAuraUpdates)
        end)

        it("a single restricted update gets no count line", function()
            restricted()
            wow.fire("PLAYER_REGEN_ENABLED")
            assert.are.equal(1, count("aura update is restricted"))
            assert.are.equal(0, count("more restricted"))
        end)

        it("the next readable update also ends the run, and a new run logs again", function()
            restricted() restricted() restricted()
            wow.fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = {} })
            assert.are.equal(1, count("2 more restricted"))
            restricted()
            assert.are.equal(2, count("aura update is restricted"))
        end)
    end)

    describe("guild roster (white)", function()
        it("logs the member count only when it changes", function()
            for _ = 1, 5 do wow.fire("GUILD_ROSTER_UPDATE") end
            assert.are.equal(1, count("roster update: 2 members known"))
            wow.state.guildRoster[#wow.state.guildRoster + 1] = "Newbie"
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.fire("GUILD_ROSTER_UPDATE")
            assert.are.equal(1, count("roster update: 3 members known"))
        end)
    end)

    describe("your own auras (white)", function()
        it("a form of yours leaves no skip line, but a stranger's buff is still logged", function()
            wow.gainBuff({ sourceUnit = "player", name = "Cat Form", spellId = 768 })
            assert.are.equal(0, count("Cat Form"))
            assert.are.equal(1, ns.Diag.Counters().ownAuras)
            wow.addUnit("target", { name = "Bob-Brightwood" })
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            assert.are.equal(1, count("Fort"))
        end)

        it("a groupmate's buff keeps its skip line", function()
            wow.setGroup("party", { "Ann-Vale" })
            wow.gainBuff({ sourceUnit = "party1", name = "Fort", spellId = 1243 })
            assert.are.equal(1, count("is you, your pet, your group"))
        end)
    end)

    describe("buff mode (white)", function()
        it("logs each turn-on and turn-off with its reason", function()
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            for token in pairs(wow.state.units) do
                if token:find("^party%d") then wow.zoneOut(token) end
            end
            ns.db.buffBack.autoOnJoin = false
            wow.fire("GROUP_ROSTER_UPDATE")
            ns.db.buffBack.autoOnJoin = true
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal(1, count("auto turned on: you're in a dungeon with your group"))
            wow.enterCombat()
            assert.are.equal(1, count("auto turned off: the fight started"))
        end)

        it("logs no turn-off for buff mode the player turned on", function()
            _G.SlashCmdList.FRIENDLYFOREVER("buffmode")
            wow.enterCombat()
            assert.are.equal(0, count("auto turned"))
        end)
    end)

    describe("locked aura update payloads (white, #294)", function()
        local function locked() wow.fire("UNIT_AURA", "player", wow.secret({})) end

        it("logs the first of a run, then a count when the next readable update comes", function()
            for _ = 1, 50 do locked() end
            assert.are.equal(1, count("payload is locked"))
            assert.are.equal(0, count("more locked"))
            wow.fire("UNIT_AURA", "player", { isFullUpdate = false })
            assert.are.equal(1, count("49 more locked aura update payloads skipped"))
            locked()
            assert.are.equal(2, count("payload is locked"))
        end)

        it("logs the count when the fight ends, and none for a single update", function()
            wow.enterCombat()
            for _ = 1, 5 do locked() end
            wow.leaveCombat()
            assert.are.equal(1, count("4 more locked"))
            locked()
            wow.fire("UNIT_AURA", "player", { isFullUpdate = false })
            assert.are.equal(1, count("4 more locked"))
            assert.are.equal(0, count("0 more locked"))
        end)

        it("a combat storm leaves the decisions in the log (red)", function()
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            wow.enterDungeon(DEADMINES, "The Deadmines")
            for fight = 1, 20 do
                wow.enterCombat()
                for _ = 1, 150 do locked() end
                wow.leaveCombat()
                wow.addUnit("target", { name = "Bob-Brightwood" })
                wow.gainBuff({ sourceUnit = "target", name = "Fort " .. fight })
            end
            assert.is_true(#ns.db.diagLog < ns.Diag.MAX_LOG, "the log never filled: " .. #ns.db.diagLog)
            assert.are.equal(20, count("payload is locked"))
            assert.are.equal(20, count("149 more locked"))
            for fight = 1, 20 do assert.are.equal(1, count("Fort " .. fight .. " ")) end
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("battleground-quiet turn-off (white, #294)", function()
        it("logs one line with its reason when the gates open", function()
            wow.enterBattleground({ "Ann-Vale", "Cid-Rock" })
            assert.is_true(ns.BuffMode.IsOn())
            ns.db.diagLog = {}
            wow.openGates()
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.equal(1, count("turned off: the battle has started"))
        end)

        it("logs one line when the preparation-phase setting is switched off", function()
            wow.enterBattleground({ "Ann-Vale", "Cid-Rock" })
            assert.is_true(ns.BuffMode.IsOn())
            ns.db.diagLog = {}
            ns.db.buffBack.bgPrepBuff = false
            ns.Battleground.Update()
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.equal(1, count("turned off: buffing in a battleground's preparation phase is off"))
        end)

        it("logs one line when Apply sees the quiet phase first", function()
            wow.enterBattleground({ "Ann-Vale", "Cid-Rock" })
            ns.db.diagLog = {}
            ns.db.buffBack.bgPrepBuff = false
            ns.BuffMode.Apply()
            assert.is_false(ns.BuffMode.IsOn())
            ns.Battleground.Update()
            assert.are.equal(1, count("turned off: buffing in a battleground's preparation phase is off"))
        end)
    end)

    describe("a dungeon's worth of events (red)", function()
        it("keeps every decision in the log", function()
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            for token in pairs(wow.state.units) do
                if token:find("^party%d") then wow.zoneOut(token) end
            end
            ns.db.buffBack.autoOnJoin = false
            wow.fire("GROUP_ROSTER_UPDATE")
            ns.db.buffBack.autoOnJoin = true
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.addUnit("target", { name = "Bob-Brightwood" })
            for fight = 1, 20 do
                wow.enterCombat()
                for _ = 1, 150 do restricted() end
                wow.leaveCombat()
                for _ = 1, 10 do wow.fire("GUILD_ROSTER_UPDATE") end
                wow.gainBuff({ sourceUnit = "player", name = "Cat Form", spellId = 768 })
                wow.gainBuff({ sourceUnit = "target", name = "Fort " .. fight })
            end
            assert.is_true(#ns.db.diagLog < ns.Diag.MAX_LOG, "the log never filled: " .. #ns.db.diagLog)
            assert.are.equal(1, count("auto turned on: you're in a dungeon"))
            -- Later buffs from strangers turn it on again; every turn-on is
            -- followed by its turn-off at the next pull.
            assert.is_true(count("auto turned on") >= 1)
            local stillOn = ns.BuffMode.IsAuto() and 1 or 0
            assert.are.equal(count("auto turned on"), count("auto turned off: the fight started") + stillOn)
            for fight = 1, 20 do assert.are.equal(1, count("Fort " .. fight .. " ")) end
            assert.are.equal(20, count("aura update is restricted"))
            assert.are.equal(20, count("149 more restricted"))
            assert.are.equal(1, count("roster update: 2 members known"))
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("the log stays safe (black)", function()
        it("formats nothing with debug off, and a secret in a reason is made safe", function()
            ns.db.debug = false
            ns.db.diagLog = {}
            wow.enterCombat()
            for _ = 1, 5 do restricted() end
            wow.leaveCombat()
            assert.are.same({}, ns.db.diagLog)
            ns.db.debug = true
            ns.Diag.Log("buffMode", "auto turned on: %s", wow.secret("x"))
            assert.are.equal(1, count("<secret>"))
        end)
    end)
end)
