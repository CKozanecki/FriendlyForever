-- Spec: #136
-- Water breathing only near water: a warlock's Unending Breath and a
-- shaman's Water Breathing are offered (buff back and buff mode) only while
-- you're swimming, underwater, with your breath bar showing, in an
-- underwater dungeon, or within 2 minutes of leaving the water. Thanks are
-- unchanged. The setting turns the rule off.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local BREATH, WATER_BREATHING = 5697, 131
local INTELLECT = 10157
local GRACE = 120 -- the issue's 2 minutes, written out rather than read from the addon
local BLACKFATHOM = 48

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

-- Each class with its water buff: the spell, its name and its key.
local CASTERS = {
    { class = "WARLOCK", id = BREATH, spell = "Unending Breath", key = "breath", other = WATER_BREATHING },
    { class = "SHAMAN", id = WATER_BREATHING, spell = "Water Breathing", key = "waterbreathing", other = BREATH },
}

describe("Water breathing near water", function()
    local ns, button

    -- A caster who knows their water buff. opts.caster (default the
    -- warlock), opts.db, opts.buffMode, opts.before(state).
    local function boot(opts)
        opts = opts or {}
        local caster = opts.caster or CASTERS[1]
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = caster.class
            state.knownSpells = opts.known or { [caster.id] = true }
            if opts.before then opts.before(state) end
        end })
        button = ns.BuffButton.Frame()
        if opts.buffMode then slash("buffmode on") end
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    -- What the armed button casts, and on whom.
    local function armed()
        local text = macro()
        if not text then return nil end
        return text:match("/targetexact ([^\n]+)") .. ": " .. text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    local function party(names)
        wow.setGroup("party", names)
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    -- Bob Stone, a stranger on a nameplate, buffs you with Arcane Intellect:
    -- you owe him one.
    local function owed()
        wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
        wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
    end

    local function refresh()
        ns.BuffButton.Refresh()
        return armed()
    end

    for _, caster in ipairs(CASTERS) do
        local spell = caster.spell
        describe(caster.class:lower() .. "'s " .. spell, function()
            describe("in buff mode (white)", function()
                before_each(function()
                    boot({ caster = caster, buffMode = true })
                    party({ "Ann-Vale" })
                end)

                it("isn't offered on dry land", function()
                    assert.is_nil(refresh())
                    assert.are.equal(spell .. " waits until you're near water", button.subtitle:GetText())
                    wow.press(button)
                    assert.are.equal(0, #wow.casts)
                end)

                it("is offered while you swim, while you're underwater, and while your breath bar shows", function()
                    wow.swim()
                    assert.are.equal("Ann Vale: " .. spell, refresh())
                    wow.state.swimming = false
                    wow.state.submerged = true -- IsSubmerged alone
                    assert.are.equal("Ann Vale: " .. spell, refresh())
                    wow.press(button)
                    assert.are.same({ caster.id, "Ann-Vale" }, { wow.casts[1].id, wow.casts[1].target })
                end)

                it("is offered with the breath bar alone, on a client without the other two calls", function()
                    _G.IsSwimming, _G.IsSubmerged = nil, nil
                    wow.state.breath = "refilling" -- no event: it reads the bar itself
                    assert.are.equal("Ann Vale: " .. spell, refresh())
                    wow.state.breath = nil
                    wow.advance(GRACE + 1)
                    assert.is_nil(refresh())
                end)

                it("counts the 2 minutes on a client with only one of the calls", function()
                    -- Only IsSwimming: its "no" is what makes the 2 minutes count.
                    _G.IsSubmerged, _G.GetMirrorTimerInfo = nil, nil
                    wow.swim()
                    refresh()
                    wow.state.swimming = false
                    wow.advance(GRACE - 5)
                    assert.are.equal("Ann Vale: " .. spell, refresh())
                    -- Only the mirror timers: an unused timer's "UNKNOWN" is a readable no.
                    boot({ caster = caster, buffMode = true })
                    party({ "Ann-Vale" })
                    _G.IsSwimming, _G.IsSubmerged = nil, nil
                    wow.dive()
                    wow.leaveWater()
                    wow.advance(wow.BREATH_REFILL_SECONDS + GRACE - 5)
                    assert.are.equal("Ann Vale: " .. spell, refresh())
                end)

                it("is armed as you dive, without waiting for the button's next re-check", function()
                    assert.is_nil(refresh())
                    wow.dive()
                    assert.are.equal("Ann Vale: " .. spell, armed())
                end)

                it("stays offered for 2 minutes after you climb out, and not a second longer", function()
                    wow.dive()
                    wow.advance(30)
                    wow.leaveWater()
                    -- The breath bar refills, then goes: the 2 minutes start then.
                    wow.advance(wow.BREATH_REFILL_SECONDS)
                    assert.is_nil(wow.state.breath)
                    local out = wow.now
                    wow.advance(GRACE - 1)
                    assert.are.equal("Ann Vale: " .. spell, refresh())
                    wow.advance(out + GRACE - wow.now)
                    assert.are.equal("Ann Vale: " .. spell, refresh(), "at exactly 2 minutes")
                    wow.advance(1)
                    assert.is_nil(refresh())
                    assert.are.equal(spell .. " waits until you're near water", button.subtitle:GetText())
                end)

                it("counts from the last time it saw you swimming on the surface (no event for that)", function()
                    wow.swim()
                    wow.advance(7) -- it looks every few seconds
                    wow.state.swimming = false
                    local out = wow.now
                    wow.advance(GRACE - 10)
                    assert.are.equal("Ann Vale: " .. spell, refresh())
                    wow.advance(out + GRACE + 1 - wow.now)
                    assert.is_nil(refresh())
                end)

                it("is offered in an underwater dungeon: Blackfathom Deeps by ID, The Drowned City by name", function()
                    wow.enterDungeon(BLACKFATHOM, "Blackfathom Deeps")
                    assert.are.equal("Ann Vale: " .. spell, refresh())
                    wow.leaveDungeon()
                    assert.is_nil(refresh())
                    wow.enterDungeon(nil, "The Drowned City")
                    assert.are.equal("Ann Vale: " .. spell, refresh())
                    wow.leaveDungeon()
                    wow.enterDungeon(36, "The Deadmines")
                    assert.is_nil(refresh(), "a dungeon that isn't underwater")
                    wow.leaveDungeon()
                    -- Only dungeons count: an instance the game calls a raid doesn't.
                    wow.enterDungeon(BLACKFATHOM, "Blackfathom Deeps")
                    wow.state.instanceType = "raid"
                    assert.is_nil(refresh(), "a raid")
                end)

                it("holds back only water buffs: others in the same list stay, in order", function()
                    local intellect, fortitude = ns.BuffData.ByKey("intellect"), ns.BuffData.ByKey("fortitude")
                    local water = ns.BuffData.ByKey(caster.key)
                    local kept, held = ns.Water.Filter({ intellect, water, fortitude })
                    assert.are.same({ intellect, fortitude }, kept)
                    assert.are.equal(water, held)
                    wow.swim()
                    kept, held = ns.Water.Filter({ intellect, water, fortitude })
                    assert.are.same({ intellect, water, fortitude }, kept)
                    assert.is_nil(held)
                    -- Two held back: the first is named.
                    wow.state.swimming = false
                    wow.advance(GRACE + 10)
                    local breath, shaman = ns.BuffData.ByKey("breath"), ns.BuffData.ByKey("waterbreathing")
                    kept, held = ns.Water.Filter({ breath, shaman })
                    assert.are.same({}, kept)
                    assert.are.equal(breath, held)
                    _, held = ns.Water.Filter({ shaman, breath })
                    assert.are.equal(shaman, held)
                    -- Nothing left to give in buff mode is settled: buff mode
                    -- that turned itself on may turn off ("everyone has my buffs").
                    local offer, why, settled = ns.GroupBuffs.Next()
                    assert.is_nil(offer)
                    assert.are.equal(spell .. " waits until you're near water", why)
                    assert.is_true(settled)
                end)
            end)

            describe("in buff back (white)", function()
                before_each(function() boot({ caster = caster }) end)

                it("isn't offered back to a stranger on dry land, and is while you swim", function()
                    owed()
                    local offer, why = ns.Offers.Current()
                    assert.is_nil(offer)
                    assert.are.equal("Bob Stone: " .. spell .. " waits until you're near water", why)
                    assert.is_nil(refresh())
                    wow.swim()
                    assert.are.equal("Bob Stone: " .. spell, refresh())
                    wow.press(button)
                    assert.are.same({ caster.id, "Bob-Stone" }, { wow.casts[1].id, wow.casts[1].target })
                end)

                it("remembers a swim from before anyone was owed (it looks every few seconds)", function()
                    wow.swim()
                    wow.advance(6)
                    wow.state.swimming = false
                    wow.advance(60)
                    owed()
                    assert.are.equal("Bob Stone: " .. spell, refresh())
                end)
            end)

            it("is offered on dry land with the setting off, in buff mode and buff back (white)", function()
                boot({ caster = caster, buffMode = true, db = { buffBack = { breathNearWater = false } } })
                assert.is_false(ns.db.buffBack.breathNearWater)
                party({ "Ann-Vale" })
                assert.are.equal("Ann Vale: " .. spell, refresh())
                slash("buffmode off")
                wow.setGroup(nil, {})
                owed()
                assert.are.equal("Bob Stone: " .. spell, refresh())
            end)

            it("isn't offered to someone wearing the other class's water buff, near water (white)", function()
                boot({ caster = caster, buffMode = true, before = function(state) state.swimming = true end })
                wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
                wow.state.units.party1.auras = { caster.other }
                ns.BuffButton.Refresh()
                assert.are.equal("Cid Rock: " .. spell, armed())
            end)
        end)
    end

    describe("looking for water when nothing else does", function()
        local calls
        local function count()
            calls = 0
            _G.IsSwimming = function() calls = calls + 1 return true end
            wow.advance(60)
            return calls
        end

        it("looks every few seconds for a warlock who knows Unending Breath", function()
            boot()
            assert.is_true(count() >= 10)
        end)

        it("doesn't for a class with no water buff: no timer at all", function()
            boot({ before = function(state) state.class = "MAGE" end, known = { [INTELLECT] = true } })
            assert.are.equal(0, count())
            assert.are.same({}, wow.timers, "nothing left waiting")
        end)

        it("doesn't for a warlock who hasn't learned it, with the setting off, or the addon off", function()
            boot({ known = {} })
            assert.are.equal(0, count())
            boot({ db = { buffBack = { breathNearWater = false } } })
            assert.are.equal(0, count())
            boot()
            ns.db.enabled = false
            assert.are.equal(0, count())
        end)

        it("looks no more often when made a second time (one look, one event frame)", function()
            boot()
            local once = count()
            local refreshes = 0
            local realRefresh = ns.BuffButton.Refresh
            ns.BuffButton.Refresh = function() refreshes = refreshes + 1 end
            ns.Water.Create()
            assert.are.equal(once, count())
            wow.fire("MIRROR_TIMER_START", "BREATH", 1, 1, -1, 0, "Breath")
            assert.are.equal(1, refreshes, "one frame heard it")
            ns.BuffButton.Refresh = realRefresh
        end)
    end)

    describe("buff mode that turned itself on (white)", function()
        local function printedHas(fragment)
            for _, line in ipairs(wow.printed) do
                if line:find(fragment, 1, true) then return true end
            end
            return false
        end

        for _, caster in ipairs(CASTERS) do
            it("turns off past the 2 minutes on dry land, saying " .. caster.spell .. " waits for water", function()
                boot({ caster = caster, db = { buffBack = { autoOnJoin = true } },
                    before = function(state) state.swimming = true end })
                party({ "Ann-Vale" })
                assert.is_true(ns.BuffMode.IsAuto(), "joining turned it on")
                wow.state.swimming = false
                wow.advance(GRACE - 10)
                assert.is_true(ns.BuffMode.IsOn(), "still within the 2 minutes")
                wow.advance(20)
                assert.is_false(ns.BuffMode.IsOn())
                assert.is_true(printedHas("buff mode off (" .. caster.spell .. " waits until you're near water)."))
                assert.is_false(printedHas("everyone has your buffs"), "nobody has it")
            end)
        end
    end)

    describe("buff thanks (white)", function()
        it("still thanks a stranger who gives you Unending Breath or Water Breathing on dry land", function()
            for _, caster in ipairs(CASTERS) do
                boot({ caster = caster })
                ns.db.buff.messages = { "Thank you for the {buff}, {name}!" }
                wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = caster.class })
                wow.gainBuff({ sourceUnit = "nameplate1", name = caster.spell, spellId = caster.id })
                wow.advance(ns.db.buff.delay + 0.01)
                wow.keyDown()
                assert.are.same({ "Thank you for the " .. caster.spell .. ", Bob!" }, wow.sentTo("SAY"))
            end
        end)
    end)

    describe("the shaman's buff (white)", function()
        it("is Water Breathing (131), held back away from water, counting Unending Breath as having it", function()
            boot()
            local list = ns.BuffData.CLASSES.SHAMAN
            assert.are.equal(1, #list)
            assert.are.same({ key = "waterbreathing", ranks = { WATER_BREATHING }, blockers = { BREATH }, water = true },
                list[1])
            assert.is_true(ns.BuffData.KEYS.waterbreathing)
            assert.is_true(ns.BuffData.Covers(list[1], BREATH))
            assert.is_true(ns.BuffData.Covers(ns.BuffData.ByKey("breath"), WATER_BREATHING))
            assert.are.equal("waterbreathing", ns.BuffData.ForAura(WATER_BREATHING).key)
            assert.are.equal("breath", ns.BuffData.ForAura(BREATH).key)
            assert.are.equal("waterbreathing", ns.BuffData.ForCast(WATER_BREATHING).key)
            assert.is_false(ns.BuffData.Covers(list[1], INTELLECT))
            assert.is_false(ns.BuffData.Covers(ns.BuffData.REVOKE, WATER_BREATHING), "not a buff in the data")
            assert.is_false(ns.BuffData.Covers({}, BREATH))
            for _, class in ipairs(ns.BuffRules.CLASSES) do
                assert.is_true(ns.BuffData.Useful(list[1], class), class)
            end
        end)

        it("is a shaman's buff: known shamans offer it, and its order and never offer work", function()
            boot({ caster = CASTERS[2], buffMode = true, before = function(state) state.swimming = true end })
            assert.are.same({ "waterbreathing" }, (function()
                local keys = {}
                for _, buff in ipairs(ns.BuffData.Mine()) do keys[#keys + 1] = buff.key end
                return keys
            end)())
            ns.db.buffBack.neverOffer = { waterbreathing = true }
            party({ "Ann-Vale" })
            assert.is_nil(refresh())
        end)
    end)

    it("asks for a restart, not erroring, after an update that added Water.lua and only a /reload (black)", function()
        wow.reset()
        wow.state.class = "WARLOCK"
        wow.state.knownSpells = { [BREATH] = true }
        local loaded = {}
        local _, files = wow.parseToc()
        for _, file in ipairs(files) do
            if file ~= "Water.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
        end
        wow.fire("ADDON_LOADED", wow.ADDON_NAME)
        wow.fire("PLAYER_ENTERING_WORLD", true, false)
        wow.advance(20)
        assert.are.same({}, wow.errors)
        assert.truthy(table.concat(wow.printed, "\n"):find("Restart the game (not /reload)", 1, true))
    end)

    describe("unreadable state (black)", function()
        before_each(function()
            boot({ buffMode = true })
            party({ "Ann-Vale" })
        end)

        it("isn't offered when the game has none of the calls, with no Lua error", function()
            wow.dive()
            _G.IsSwimming, _G.IsSubmerged, _G.GetMirrorTimerInfo = nil, nil, nil
            assert.is_nil(refresh())
            assert.are.equal("Unending Breath waits until you're near water", button.subtitle:GetText())
            local near, why = ns.Water.Near()
            assert.is_false(near)
            assert.are.equal("can't tell whether you're in the water", why)
            assert.are.same({}, wow.errors)
        end)

        it("isn't offered when every reading is secret, even within the 2 minutes", function()
            wow.dive()
            assert.is_not_nil(refresh())
            wow.state.waterSecret = true
            assert.is_nil(refresh(), "secret readings, though it was in the water a moment ago")
            wow.state.waterSecret = false
            assert.is_not_nil(refresh(), "readable again")
            assert.are.same({}, wow.errors)
        end)

        it("isn't offered when the calls raise errors or give junk", function()
            wow.dive()
            local function boom() error("not now") end
            _G.IsSwimming, _G.IsSubmerged, _G.GetMirrorTimerInfo = boom, boom, boom
            assert.is_nil(refresh())
            for _, junk in ipairs({ "yes", 0, {}, function() end }) do
                local value = junk
                _G.IsSwimming = function() return value end
                _G.IsSubmerged = function() return value end
                _G.GetMirrorTimerInfo = function() return value end
                assert.is_nil(refresh(), "junk: " .. type(junk))
            end
            assert.are.same({}, wow.errors)
        end)

        it("takes a reading that says yes over ones that can't be read", function()
            _G.IsSubmerged, _G.GetMirrorTimerInfo = nil, nil
            wow.swim()
            assert.are.equal("Ann Vale: Unending Breath", refresh())
            _G.IsSwimming = function() return 1 end -- older clients' yes
            wow.state.swimming = false
            assert.are.equal("Ann Vale: Unending Breath", refresh())
        end)

        it("doesn't count a dungeon whose details are secret, missing, or the wrong type", function()
            wow.enterDungeon(BLACKFATHOM, "Blackfathom Deeps")
            wow.state.instanceSecret = true
            assert.is_nil(refresh())
            wow.state.instanceSecret = false
            wow.state.instanceId, wow.state.instanceName = "48", 48
            assert.is_nil(refresh())
            _G.GetInstanceInfo = nil
            assert.is_nil(refresh())
            _G.GetInstanceInfo = function() error("loading") end
            assert.is_nil(refresh())
            assert.are.same({}, wow.errors)
        end)

        it("doesn't take The Drowned City's name outside a dungeon (a zone of that name)", function()
            _G.GetInstanceInfo = function() return "The Drowned City", "none", 0, "", 0, false, false, 0 end
            assert.is_nil(refresh())
        end)

        it("ignores a secret or other mirror timer event", function()
            wow.fire("MIRROR_TIMER_START", wow.secret("BREATH"), 1, 1, -1, 0, "Breath")
            wow.fire("MIRROR_TIMER_STOP", "EXHAUSTION")
            wow.fire("MIRROR_TIMER_STOP", nil)
            assert.is_nil(refresh())
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("the setting (black)", function()
        it("defaults to on, and a damaged value repairs to on", function()
            boot()
            assert.is_true(ns.db.buffBack.breathNearWater)
            for _, damaged in ipairs({ "false", 0, 1, {}, "yes" }) do
                boot({ db = { buffBack = { breathNearWater = damaged } } })
                assert.is_true(ns.db.buffBack.breathNearWater, tostring(damaged))
            end
        end)

        it("reads as on when damaged mid-session, so water breathing is still held back", function()
            boot({ buffMode = true })
            party({ "Ann-Vale" })
            ns.db.buffBack.breathNearWater = "off"
            assert.is_true(ns.Water.OnlyNear())
            assert.is_nil(refresh())
            ns.db.buffBack = nil
            assert.is_true(ns.Water.OnlyNear())
            assert.are.same({}, wow.errors)
        end)

        it("travels in an exported settings line and a profile", function()
            boot()
            ns.db.buffBack.breathNearWater = false
            local line = assert(ns.Profiles.Export())
            ns.db.buffBack.breathNearWater = true
            assert.is_true(ns.Profiles.Import(line))
            assert.is_false(ns.db.buffBack.breathNearWater)
            assert.is_false(ns.Profiles.Snapshot(ns.db).buffBack.breathNearWater)
        end)

        it("is a checkbox on the Buff Back tab only, and clicking it changes the setting at once", function()
            boot({ buffMode = true })
            party({ "Ann-Vale" })
            local w = ns.Options.widgets
            slash("")
            wow.run(w.tabs.buffBack, "OnClick")
            assert.is_true(w.breathNearWater:IsShown())
            assert.is_true(w.waterHeader:IsShown())
            assert.are.equal("Unending Breath and Water Breathing:", w.waterHeader:GetText(),
                "its own heading, not under Battlegrounds")
            assert.is_true(w.breathNearWater:GetChecked())
            -- The owner's wording (#136).
            assert.are.equal("Water breathing: only near water", w.breathNearWater.label:GetText())
            assert.are.equal("Offer Unending Breath and Water Breathing only while you're swimming or underwater, "
                .. "for 2 minutes after, or in an underwater dungeon.", w.breathNearWater.tooltip)
            local tip = {}
            _G.GameTooltip.SetOwner = function(_, owner) tip.owner = owner end
            _G.GameTooltip.SetText = function(_, text) tip.text = text end
            _G.GameTooltip.Show = function() tip.shown = true end
            _G.GameTooltip.Hide = function() tip.shown = false end
            wow.run(w.breathNearWater, "OnEnter")
            assert.are.same({ owner = w.breathNearWater, text = w.breathNearWater.tooltip, shown = true }, tip)
            wow.run(w.breathNearWater, "OnLeave")
            assert.is_false(tip.shown)
            w.breathNearWater:SetChecked(false)
            wow.run(w.breathNearWater, "OnClick")
            assert.is_false(ns.db.buffBack.breathNearWater)
            assert.are.equal("Ann Vale: Unending Breath", armed(), "offered at once on dry land")
            w.breathNearWater:SetChecked(true)
            wow.run(w.breathNearWater, "OnClick")
            assert.is_nil(armed())
            wow.run(w.tabs.buff, "OnClick")
            assert.is_false(w.breathNearWater:IsShown())
            assert.is_false(w.waterHeader:IsShown())
        end)

        it("is in /friendly status, with the setting on or off", function()
            local function said(pattern)
                for _, line in ipairs(wow.printed) do
                    if line:find(pattern) then return true end
                end
                return false
            end
            boot()
            slash("status")
            assert.is_true(said("near water: no %(not near water%); water breathing only near water"))
            boot({ db = { buffBack = { breathNearWater = false } } })
            wow.swim()
            slash("status")
            assert.is_true(said("near water: yes %(in the water%); water breathing offered anywhere"))
        end)
    end)

    describe("chaos (red tests)", function()
        it("in and out of water, dungeons and rosters: never offered on dry land past 2 minutes, never errors", function()
            local everyone = { "Ann-Vale", "Cid-Rock", "Dot-Fern", "Eve-Moss" }
            local totals = { casts = 0 }
            for _, seed in ipairs({ 7, 136, 404, 1999, 2026, 31337 }) do
                random.seed(seed)
                local caster = CASTERS[seed % 2 + 1]
                boot({ caster = caster, buffMode = true })
                party(everyone)
                local lastWet = -math.huge -- the client's own last moment in the water
                local function noteWater()
                    if wow.inWater() then lastWet = wow.now end
                    if wow.state.breathStoppedAt and wow.state.breathStoppedAt > lastWet then
                        lastWet = wow.state.breathStoppedAt
                    end
                end
                -- From the client's state, never the addon's: may it be offered now?
                local function dungeonNow()
                    local s = wow.state
                    return s.inInstance and not s.instanceSecret and _G.GetInstanceInfo ~= nil
                        and (s.instanceId == BLACKFATHOM or s.instanceName == "The Drowned City")
                end
                local function mayOffer()
                    if ns.db.buffBack.breathNearWater == false then return true end
                    if dungeonNow() then return true end
                    if wow.state.waterSecret then return false end
                    return wow.now - lastWet <= GRACE
                end
                local function giveTo(id)
                    for _, u in pairs(wow.state.units) do
                        if u.id == id then
                            u.auras = { caster.id }
                            u.auraSources = { "player" }
                        end
                    end
                end
                local reached = { offeredInWater = 0, offeredInGrace = 0, heldOnLand = 0, dungeon = 0, secret = 0 }
                local actions = {
                    wow.swim, wow.dive, wow.surface, wow.leaveWater, wow.leaveWater,
                    function() wow.state.swimming = false end, -- out with no breath bar
                    function() wow.enterDungeon(BLACKFATHOM, "Blackfathom Deeps") end,
                    function() wow.enterDungeon(nil, "The Drowned City") end,
                    function() wow.enterDungeon(36, "The Deadmines") end,
                    function() if wow.state.inInstance then wow.leaveDungeon() end end,
                    function() wow.setMap(random.random() < 0.5 and wow.ELWYNN or 1437) end,
                    function() wow.state.waterSecret = random.random() < 0.25 end,
                    function() wow.state.instanceSecret = random.random() < 0.2 end,
                    function()
                        local names = {}
                        for _, name in ipairs(everyone) do
                            if random.random() < 0.7 then names[#names + 1] = name end
                        end
                        party(names)
                    end,
                    function()
                        local u = wow.state.units["party" .. random.random(4)]
                        if u then u.auras, u.auraSources = nil, nil end
                    end,
                    function()
                        local before = #wow.casts
                        wow.pressKey("MOUSEWHEELUP")
                        local cast = wow.casts[before + 1]
                        if cast and not cast.failed then giveTo(cast.target) end
                    end,
                    function() wow.press(button) end,
                    function() wow.advance(random.random() * 40) end,
                    function() wow.advance(random.random() * 150) end,
                    function() ns.db.buffBack.breathNearWater = random.random() < 0.9 end,
                }
                ns.BuffButton.Refresh()
                noteWater()
                for step = 1, 600 do
                    local where = ("seed %d, step %d"):format(seed, step)
                    local allowed = mayOffer()
                    local before = #wow.casts
                    actions[random.random(#actions)]()
                    for i = before + 1, #wow.casts do
                        local cast = wow.casts[i]
                        assert.are.equal(caster.id, cast.id, where)
                        assert.is_true(allowed, where .. ": cast on dry land past the 2 minutes")
                        totals.casts = totals.casts + 1
                    end
                    noteWater()
                    ns.BuffButton.Refresh()
                    local offered = macro() ~= nil
                    if offered then
                        assert.is_true(mayOffer(), where .. ": offered on dry land past the 2 minutes")
                        if ns.db.buffBack.breathNearWater ~= false then
                            if wow.inWater() and not wow.state.waterSecret then
                                reached.offeredInWater = reached.offeredInWater + 1
                            elseif dungeonNow() then
                                reached.dungeon = reached.dungeon + 1
                            else
                                reached.offeredInGrace = reached.offeredInGrace + 1
                            end
                        end
                    elseif not mayOffer() then
                        reached.heldOnLand = reached.heldOnLand + 1
                        if wow.state.waterSecret and wow.inWater() then reached.secret = reached.secret + 1 end
                    end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
                for what, n in pairs(reached) do
                    assert.is_true(n > 0, ("seed %d never reached %s"):format(seed, what))
                end
            end
            assert.is_true(totals.casts > 50, "casts: " .. totals.casts)
        end)
    end)
end)
