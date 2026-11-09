-- Spec: #76, #84, #136, #42, #47, #169, #198, #219, #41
-- The simulated client itself, where its test hooks could fool other specs.
local wow = require("spec.support.wow")

local MOTW, MOTW_1 = 9885, 1126
local MACRO = "/targetexact Ann Stone\n/cast [help,nodead] Mark of the Wild"

describe("The simulated client", function()
    -- A druid who knows Mark of the Wild, near Ann-Stone (not flagged for PvP)
    -- and Dot-Stone (flagged).
    before_each(function()
        wow.boot({ before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
        end })
        wow.addUnit("nameplate5", { name = "Ann", surname = "Stone", class = "MAGE", id = "Ann-Stone" })
        wow.addUnit("nameplate4", { name = "Dot", surname = "Stone", class = "MAGE", id = "Dot-Stone", pvp = true })
    end)

    describe("PvP flags from casts state.castLandsOn sent elsewhere (white)", function()
        it("keeps a flag from a redirected cast out of flaggedBy, in flaggedElsewhere", function()
            wow.state.castLandsOn = "nameplate4"
            wow.runMacro(MACRO)
            assert.are.equal("Dot-Stone", wow.casts[1].target, "the cast went to Dot")
            assert.is_true(wow.state.pvp, "helping a flagged player still flags you")
            assert.are.same({}, wow.flaggedBy)
            assert.are.same({ "Dot-Stone" }, wow.flaggedElsewhere)
        end)

        it("does the same when the server answers late", function()
            wow.state.castLandsOn = "nameplate4"
            wow.state.castLatency = 1.5
            wow.runMacro(MACRO)
            assert.is_falsy(wow.state.pvp, "not until the server answers")
            wow.advance(2)
            assert.is_true(wow.state.pvp)
            assert.are.same({}, wow.flaggedBy)
            assert.are.same({ "Dot-Stone" }, wow.flaggedElsewhere)
        end)

        it("still puts a flag from a cast aimed at a flagged player in flaggedBy", function()
            wow.runMacro("/targetexact Dot Stone\n/cast [help,nodead] Mark of the Wild")
            assert.are.same({ "Dot-Stone" }, wow.flaggedBy)
            assert.are.same({}, wow.flaggedElsewhere)
        end)

        it("counts a cast as aimed when state.castLandsOn names the player the macro aimed at", function()
            wow.state.castLandsOn = "nameplate4"
            wow.runMacro("/targetexact Dot Stone\n/cast [help,nodead] Mark of the Wild")
            assert.are.same({ "Dot-Stone" }, wow.flaggedBy)
            assert.are.same({}, wow.flaggedElsewhere)
        end)

        it("counts a cast as aimed when state.castLandsOn names another token for the same player", function()
            wow.addUnit("nameplate7", { name = "Dot", surname = "Stone", class = "MAGE", id = "Dot-Stone", pvp = true })
            wow.state.castLandsOn = "nameplate7"
            wow.runMacro("/targetexact Dot Stone\n/cast [help,nodead] Mark of the Wild")
            assert.are.equal("Dot-Stone", wow.casts[1].target)
            assert.are.same({ "Dot-Stone" }, wow.flaggedBy, "the player the macro aimed at")
            assert.are.same({}, wow.flaggedElsewhere)
        end)

        it("flags nothing when the redirected cast lands on someone unflagged", function()
            wow.state.castLandsOn = "nameplate5"
            wow.runMacro("/targetexact Dot Stone\n/cast [help,nodead] Mark of the Wild")
            assert.are.equal("Ann-Stone", wow.casts[1].target)
            assert.is_falsy(wow.state.pvp)
            assert.are.same({}, wow.flaggedBy)
            assert.are.same({}, wow.flaggedElsewhere)
        end)
    end)

    describe("a macro's conditions on the unit state.castLandsOn sends the cast to (white)", function()
        it("casts nothing for a [help,nodead] macro when the cast would land on a dead unit", function()
            wow.addUnit("nameplate2", { name = "Cid", surname = "Stone", class = "MAGE", id = "Cid-Stone", dead = true })
            wow.state.castLandsOn = "nameplate2"
            wow.runMacro(MACRO)
            assert.are.equal(0, #wow.casts, "no cast on the dead unit")
        end)

        it("casts nothing for a [help,nodead] macro when the cast would land on a hostile unit", function()
            wow.addUnit("nameplate2", { name = "Cid", surname = "Stone", class = "MAGE", id = "Cid-Stone", hostile = true })
            wow.state.castLandsOn = "nameplate2"
            wow.runMacro(MACRO)
            assert.are.equal(0, #wow.casts, "no cast on the hostile unit")
        end)

        it("still lands on a living friendly unit", function()
            wow.state.castLandsOn = "nameplate4"
            wow.runMacro(MACRO)
            assert.are.equal(1, #wow.casts)
            assert.are.equal("Dot-Stone", wow.casts[1].target)
        end)

        it("still checks your target: a dead target casts nothing, wherever the cast would land", function()
            wow.addUnit("nameplate2", { name = "Cid", surname = "Stone", class = "MAGE", id = "Cid-Stone", dead = true })
            wow.state.castLandsOn = "nameplate4"
            wow.runMacro("/targetexact Cid Stone\n/cast [help,nodead] Mark of the Wild")
            assert.are.equal(0, #wow.casts)
        end)
    end)
    describe("water and dungeons (#136, white)", function()
        -- The mirror timer events a frame hears, as "EVENT NAME".
        local heard
        before_each(function()
            heard = {}
            local f = _G.CreateFrame("Frame")
            f:RegisterEvent("MIRROR_TIMER_START")
            f:RegisterEvent("MIRROR_TIMER_STOP")
            f:SetScript("OnEvent", function(_, event, name) heard[#heard + 1] = event .. " " .. tostring(name) end)
        end)

        local function readings()
            return { _G.IsSwimming(), _G.IsSubmerged(), (_G.GetMirrorTimerInfo(2)) }
        end

        it("starts on dry land: not swimming, not underwater, no breath bar", function()
            assert.are.same({ false, false, "UNKNOWN" }, readings())
            assert.is_false(wow.inWater())
            for _, i in ipairs({ 1, 3 }) do assert.are.equal("UNKNOWN", (_G.GetMirrorTimerInfo(i))) end
            wow.dive()
            assert.are.same({ "UNKNOWN", "BREATH", "UNKNOWN" }, { (_G.GetMirrorTimerInfo(1)),
                (_G.GetMirrorTimerInfo(2)), (_G.GetMirrorTimerInfo(3)) }, "breath is the second slot")
        end)

        it("swims, dives, surfaces and climbs out, with the breath bar's events", function()
            wow.swim()
            assert.are.same({ true, false, "UNKNOWN" }, readings())
            assert.are.same({}, heard, "no event for swimming on the surface")
            wow.dive()
            assert.are.same({ true, true, "BREATH" }, readings())
            assert.are.same({ "MIRROR_TIMER_START BREATH" }, heard)
            local _, _, _, scale = _G.GetMirrorTimerInfo(2)
            assert.is_true(scale < 0, "draining")
            wow.surface()
            assert.are.same({ true, false, "BREATH" }, readings())
            _, _, _, scale = _G.GetMirrorTimerInfo(2)
            assert.is_true(scale > 0, "refilling")
            wow.leaveWater()
            assert.are.same({ false, false, "BREATH" }, readings())
            assert.is_true(wow.inWater(), "the bar still shows")
            wow.advance(wow.BREATH_REFILL_SECONDS - 0.5)
            assert.are.equal(1, #heard)
            wow.advance(0.5)
            assert.are.same({ "MIRROR_TIMER_START BREATH", "MIRROR_TIMER_STOP BREATH" }, heard)
            assert.are.equal(wow.now, wow.state.breathStoppedAt)
            assert.is_false(wow.inWater())
        end)

        it("drops an older refill's stop when you dive again before it ends", function()
            wow.dive()
            wow.surface()
            wow.advance(3)
            wow.dive()
            assert.are.equal(1, #heard, "a refilling bar turns round without a new start")
            wow.advance(wow.BREATH_REFILL_SECONDS)
            assert.are.equal("BREATH", (_G.GetMirrorTimerInfo(2)))
            assert.are.equal(1, #heard)
            wow.leaveWater()
            wow.advance(wow.BREATH_REFILL_SECONDS)
            assert.are.equal(2, #heard)
            assert.is_nil(wow.state.breath)
        end)

        it("makes every reading a secret with state.waterSecret", function()
            wow.state.waterSecret = true
            for _, value in ipairs(readings()) do assert.is_true(_G.issecretvalue(value)) end
        end)

        it("answers GetInstanceInfo in the world, in a dungeon, and with secrets", function()
            local name, kind, _, _, _, _, _, id = _G.GetInstanceInfo()
            assert.are.same({ "Eastern Kingdoms", "none", 0 }, { name, kind, id })
            wow.enterDungeon(48, "Blackfathom Deeps")
            assert.is_true(_G.IsInInstance())
            name, kind, _, _, _, _, _, id = _G.GetInstanceInfo()
            assert.are.same({ "Blackfathom Deeps", "party", 48 }, { name, kind, id })
            wow.state.instanceSecret = true
            name, kind, _, _, _, _, _, id = _G.GetInstanceInfo()
            for _, value in ipairs({ name, kind, id }) do assert.is_true(_G.issecretvalue(value)) end
            wow.state.instanceSecret = false
            wow.leaveDungeon()
            assert.is_false(_G.IsInInstance())
            name, kind = _G.GetInstanceInfo()
            assert.are.same({ "Eastern Kingdoms", "none" }, { name, kind })
        end)
    end)

    describe("a group member's buff times (#42, white)", function()
        local function aura(i) return _G.C_UnitAuras.GetAuraDataByIndex("party1", i, "HELPFUL") end

        before_each(function()
            wow.setGroup("party", { "Ann-Vale" })
        end)

        it("gives no times unless a spec sets them", function()
            wow.state.units.party1.auras = { MOTW }
            local a = aura(1)
            assert.are.equal(MOTW, a.spellId)
            assert.is_nil(a.duration)
            assert.is_nil(a.expirationTime)
        end)

        it("puts a buff on with wearBuff, on the game clock, replacing one of the same spell", function()
            wow.wearBuff("party1", MOTW, { duration = 1800, source = "player" })
            wow.wearBuff("party1", MOTW_1)
            assert.are.same({ spellId = MOTW, isHelpful = true, sourceUnit = "player", duration = 1800,
                expirationTime = wow.now + 1800 }, aura(1))
            assert.are.equal(3600, aura(2).duration, "an hour by default")
            assert.is_nil(aura(2).sourceUnit)
            wow.advance(100)
            wow.wearBuff("party1", MOTW, { duration = 1800 })
            assert.are.equal(wow.now + 1800, aura(1).expirationTime, "refreshed in its place")
            assert.is_nil(aura(3))
            wow.wearBuff("party1", MOTW_1, { duration = 0 })
            assert.are.equal(0, aura(2).expirationTime, "0: never runs out")
            wow.advance(100000)
            assert.are.equal(MOTW_1, aura(1).spellId, "still there; the Mark ran out")
        end)

        it("takes a buff away once its time has come, with the others moving up", function()
            local start = wow.now
            wow.wearBuff("party1", MOTW, { duration = 60, source = "party1" })
            wow.wearBuff("party1", MOTW_1, { duration = 120, source = "player" })
            wow.advance(59)
            assert.are.equal(MOTW, aura(1).spellId)
            wow.advance(1)
            -- The second moves up whole: its spell, times and caster together.
            assert.are.same({ spellId = MOTW_1, isHelpful = true, sourceUnit = "player", duration = 120,
                expirationTime = start + 120 }, aura(1))
            assert.is_nil(aura(2))
            assert.is_true(wow.auraExpired(wow.state.units.party1, 1))
            wow.advance(60)
            assert.is_nil(aura(1))
        end)

        it("makes only the times secret with secrets.auraTimes", function()
            wow.wearBuff("party1", MOTW, { duration = 1800, source = "player" })
            wow.state.units.party1.secrets = { auraTimes = true }
            local a = aura(1)
            assert.are.equal(MOTW, a.spellId)
            assert.are.equal("player", a.sourceUnit)
            assert.is_true(_G.issecretvalue(a.duration))
            assert.is_true(_G.issecretvalue(a.expirationTime))
            assert.has.errors(function() return a.expirationTime - 1 end)
            wow.state.units.party1.auraDurations[1] = nil
            assert.is_nil(aura(1).duration, "unset stays nil")
        end)
    end)
end)

-- #47: the walkthrough opens at login until it's finished or skipped, and a
-- first install is off until then. boot turns both off for most specs;
-- opts.walkthrough, and given settings that set them, keep them.
describe("The simulated client's boot and the walkthrough (#47)", function()
    local SEEN = { seen = wow.boot().Config.WALKTHROUGH_VERSION, firstRun = false }

    it("starts a first install switched on, its walkthrough finished, unless asked", function()
        local ns = wow.boot()
        assert.are.same(SEEN, ns.db.walkthrough)
        assert.is_true(ns.db.enabled)
        assert.is_false(ns.Walkthrough.Frame():IsShown())
        ns = wow.boot({ walkthrough = true })
        assert.are.same({ seen = 0, firstRun = true }, ns.db.walkthrough)
        assert.is_false(ns.db.enabled)
        assert.is_true(ns.Walkthrough.Frame():IsShown())
    end)

    it("starts given settings without a walkthrough state as finished, and leaves their switch", function()
        local ns = wow.boot({ db = { enabled = false } })
        assert.are.same(SEEN, ns.db.walkthrough)
        assert.is_false(ns.db.enabled)
        assert.is_false(ns.Walkthrough.Frame():IsShown())
    end)

    it("leaves a given walkthrough state alone, so one not yet seen still starts", function()
        local ns = wow.boot({ db = { walkthrough = { seen = 0, firstRun = false } } })
        assert.are.same({ seen = 0, firstRun = false }, ns.db.walkthrough)
        assert.is_true(ns.Walkthrough.Frame():IsShown())
    end)

    it("opts.afterLoad changes the loaded code before the saved settings are checked (#169)", function()
        local seenBy
        local ns = wow.boot({ db = { enabled = true, walkthrough = { seen = 2, firstRun = false } },
            afterLoad = function(loaded)
                seenBy = loaded.db
                loaded.Config.WALKTHROUGH_VERSION = 2
            end })
        assert.is_nil(seenBy, "the settings aren't loaded yet")
        assert.are.equal(2, ns.Config.WALKTHROUGH_VERSION)
        assert.are.same({ seen = 2, firstRun = false }, ns.db.walkthrough, "2 is checked against the new version")
    end)
end)

describe("The simulated client's [@unit] casts and buff-self default (#198)", function()
    local function boot(opts)
        opts = opts or {}
        opts.before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
        end
        return wow.boot(opts)
    end

    it("casts on the unit named, leaving your target alone", function()
        boot()
        wow.setGroup("party", { "Ann-Vale" })
        wow.addUnit("target", { name = "Bob", surname = "Stone", id = "Bob-Stone" })
        wow.runMacro("/cast [@party1] Mark of the Wild")
        assert.are.equal("Ann-Vale", wow.casts[1].target)
        assert.are.equal("Bob-Stone", wow.state.units.target.id)
    end)

    it("takes [@player] with the conditions after it, or none", function()
        boot()
        wow.runMacro("/cast [@player] Mark of the Wild")
        wow.runMacro("/cast [@player,nodead] Mark of the Wild")
        assert.are.equal(2, #wow.casts)
        assert.are.equal("Me", wow.casts[2].target)
    end)

    it("tests the other conditions against that unit: nothing on a dead you", function()
        boot()
        wow.state.units.player.dead = true
        wow.runMacro("/cast [@player,nodead] Mark of the Wild")
        assert.are.equal(0, #wow.casts)
    end)

    it("casts nothing for a unit that isn't there", function()
        boot()
        wow.runMacro("/cast [@party3] Mark of the Wild")
        assert.are.equal(0, #wow.casts)
    end)

    it("boots with buff mode not buffing you, unless buffSelf keeps it", function()
        assert.are.equal("off", boot().GroupBuffs.SELF_ORDER)
        assert.are.equal("first", boot({ buffSelf = true }).GroupBuffs.SELF_ORDER)
    end)

    it("boots with Wisdom, Might and Thorns at Everyone, unless saved or buffDefaults keeps the defaults (#219)", function()
        local who = boot().db.buffBack.whoGets
        for _, key in ipairs({ "wisdom", "might", "thorns" }) do assert.are.equal("all", who[key].rule, key) end
        local given = boot({ db = { buffBack = { whoGets = { wisdom = { rule = "tanks" } } } } }).db.buffBack.whoGets
        assert.are.equal("tanks", given.wisdom.rule)
        assert.are.equal("all", given.might.rule)
        local kept = boot({ buffDefaults = true }).db.buffBack.whoGets
        assert.is_nil(kept.wisdom)
        assert.is_nil(kept.thorns)
    end)
end)

describe("The simulated client's group versions (#41)", function()
    local function cast(text) wow.runMacro(text) end

    local function boot(items)
        wow.boot({ before = function(state)
            state.class = "MAGE"
            state.knownSpells = { [10157] = true, [23028] = true }
            state.items = items or { [wow.ITEM.arcanePowder] = 1 }
        end })
        wow.setGroup("raid", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
        wow.state.units.raid1.subgroup = 2
        wow.state.units.raid2.subgroup = 2
        wow.state.units.raid3.subgroup = 2
        wow.state.units.raid4.subgroup = 1
    end

    it("answers reagent counts, and secrets and failures as asked", function()
        boot({ [17020] = 3 })
        assert.are.equal(3, GetItemCount(17020))
        assert.are.equal(3, C_Item.GetItemCount(17020))
        assert.are.equal(0, GetItemCount(17029))
        wow.state.itemsSecret = true
        assert.is_true(issecretvalue(GetItemCount(17020)))
    end)

    it("answers the raid roster's subgroups by slot", function()
        boot()
        assert.are.equal(2, select(3, GetRaidRosterInfo(1)))
        assert.are.equal(1, select(3, GetRaidRosterInfo(4)))
        assert.is_nil(GetRaidRosterInfo(5))
        wow.state.units.raid1.secrets = { subgroup = true }
        assert.is_true(issecretvalue(select(3, GetRaidRosterInfo(1))))
        wow.state.rosterSecret = true
        assert.is_true(issecretvalue(GetRaidRosterInfo(2)))
    end)

    it("covers the target's subgroup, uses a reagent, and puts the buff on those reached", function()
        boot()
        wow.state.units.raid2.outOfRange = true
        cast("/targetexact Ann Vale\n/cast [help,nodead] Arcane Brilliance")
        local record = wow.casts[1]
        assert.are.same({ "Ann-Vale", "Cid-Rock" }, record.covered)
        assert.are.equal(0, wow.state.items[17020])
        assert.are.same({ 23028 }, wow.state.units.raid1.auras)
        assert.are.equal("player", wow.state.units.raid1.auraSources[1])
        assert.is_nil(wow.state.units.raid2.auras, "out of range: not reached")
        assert.is_nil(wow.state.units.raid4.auras, "another subgroup: not reached")
    end)

    it("fails with no reagent, also when it runs out while the server answers", function()
        boot({})
        cast("/targetexact Ann Vale\n/cast [help,nodead] Arcane Brilliance")
        assert.is_truthy(wow.casts[1].failed)
        assert.are.equal(0, #wow.landed)
        boot()
        wow.state.castLatency = 1
        cast("/targetexact Ann Vale\n/cast [help,nodead] Arcane Brilliance")
        wow.state.items[17020] = 0
        wow.advance(2)
        assert.are.equal(0, #wow.landed)
        assert.are.equal(0, wow.state.items[17020])
    end)

    it("flags you for a covered player who is flagged, whoever the target is", function()
        boot()
        wow.state.units.raid3.pvp = true
        cast("/targetexact Ann Vale\n/cast [help,nodead] Arcane Brilliance")
        assert.is_true(wow.state.pvp)
        assert.are.same({ "Ann-Vale", "Cid-Rock" }, wow.flaggedBy)
    end)

    it("shows the buff only after state.auraDelay", function()
        boot()
        wow.state.auraDelay = 2
        cast("/targetexact Ann Vale\n/cast [help,nodead] Arcane Brilliance")
        assert.is_nil(wow.state.units.raid1.auras)
        wow.advance(2)
        assert.are.same({ 23028 }, wow.state.units.raid1.auras)
    end)

    it("makes the buff last state.groupBuffSeconds, an hour by default", function()
        boot()
        cast("/targetexact Ann Vale\n/cast [help,nodead] Arcane Brilliance")
        assert.are.equal(3600, wow.state.units.raid1.auraDurations[1])
        boot()
        wow.state.groupBuffSeconds = 30
        cast("/targetexact Ann Vale\n/cast [help,nodead] Arcane Brilliance")
        assert.are.equal(30, wow.state.units.raid1.auraDurations[1])
        assert.is_false(wow.auraExpired(wow.state.units.raid1, 1))
        wow.advance(31)
        assert.is_true(wow.auraExpired(wow.state.units.raid1, 1))
        assert.is_nil(C_UnitAuras.GetAuraDataByIndex("raid1", 1), "gone from the aura list")
    end)

    it("covers you when your own raid slot is in the target's subgroup, and not otherwise", function()
        boot()
        wow.addUnit("raid5", wow.state.units.player)
        wow.state.units.player.subgroup = 2
        wow.state.playerAuras = { { isHelpful = true, spellId = 10938, sourceUnit = "player", auraInstanceID = 1 } }
        cast("/targetexact Ann Vale\n/cast [help,nodead] Arcane Brilliance")
        local record = wow.casts[1]
        assert.are.same({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Me" }, record.covered)
        assert.are.same({ 10938 }, record.before.Me, "what you wore, from your own buffs")
        assert.are.same({ "player" }, record.beforeSources.Me)
        local worn = C_UnitAuras.GetAuraDataByIndex("player", 2)
        assert.are.equal(23028, worn.spellId, "and now you wear it")
        assert.are.same({}, wow.flaggedBy)
        wow.state.units.player.subgroup = 1
        cast("/targetexact Ann Vale\n/cast [help,nodead] Arcane Brilliance")
        for _, id in ipairs(wow.casts[2].covered) do assert.are_not.equal("Me", id) end
    end)

    it("covers the target's class for a Greater Blessing, and uses a Symbol of Kings", function()
        wow.boot({ before = function(state)
            state.class = "PALADIN"
            state.knownSpells = { [25898] = true }
            state.items = { [wow.ITEM.symbolOfKings] = 2 }
        end })
        wow.setGroup("raid", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
        for i, class in ipairs({ "WARRIOR", "MAGE", "WARRIOR", "WARRIOR" }) do
            wow.state.units["raid" .. i].class = class
        end
        wow.state.units.raid4.outOfRange = true
        wow.state.units.raid1.subgroup = 5 -- the subgroup doesn't matter to a class cast
        cast("/targetexact Ann Vale\n/cast [help,nodead] Greater Blessing of Kings")
        local record = wow.casts[1]
        assert.are.same({ "Ann-Vale", "Cid-Rock" }, record.covered, "warriors in range, whatever their subgroup")
        assert.are.equal(1, wow.state.items[wow.ITEM.symbolOfKings])
        assert.are.same({ 25898 }, wow.state.units.raid3.auras)
        assert.is_nil(wow.state.units.raid2.auras, "the mage isn't covered")
    end)

    it("covers you in a Greater Blessing when your class is the target's", function()
        wow.boot({ before = function(state)
            state.class = "PALADIN"
            state.knownSpells = { [25898] = true }
            state.items = { [wow.ITEM.symbolOfKings] = 2 }
        end })
        wow.setGroup("party", { "Ann-Vale" })
        wow.state.units.party1.class = "PALADIN"
        cast("/targetexact Ann Vale\n/cast [help,nodead] Greater Blessing of Kings")
        assert.are.same({ "Ann-Vale", "Me" }, wow.casts[1].covered)
        wow.state.units.party1.class = "WARRIOR"
        cast("/targetexact Ann Vale\n/cast [help,nodead] Greater Blessing of Kings")
        assert.are.same({ "Ann-Vale" }, wow.casts[2].covered)
    end)

    it("doesn't touch a unit that left the group before a slow answer", function()
        boot()
        wow.state.castLatency = 1
        cast("/targetexact Ann Vale\n/cast [help,nodead] Arcane Brilliance")
        wow.setGroup(nil, {})
        wow.advance(2)
        assert.are.same({}, wow.errors)
    end)
end)
