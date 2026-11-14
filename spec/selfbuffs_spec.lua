-- Spec: #44
-- Self-buffs: in buff mode, once the favours you owe and your group are
-- done, the button offers your own missing self-buffs (Inner Fire, armors,
-- Aspects, auras, Battle Shout...), one per press, on you, through the same
-- secure button. The committed buff table holds only Battle Shout of these
-- until their spells are extracted, so these specs load the table the
-- generator would make (wow.selfBuffTable), at Classic Era's IDs.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local INNER_FIRE, INNER_FIRE_1 = 10952, 588
local FORT = 10938
local ICE_ARMOR, FROST_ARMOR, MAGE_ARMOR = 10220, 7301, 22783
local INTELLECT = 10157
local HAWK, MONKEY, WILD, CHEETAH, PACK, BEAST = 25296, 13163, 20190, 5118, 13159, 13161
local TRUESHOT = 20906
local DEVOTION, RETRIBUTION, CONCENTRATION = 10293, 10301, 19746
local RIGHTEOUS_FURY = 25780
local BATTLE_SHOUT = 25289
local OMEN, LIGHTNING_SHIELD, DEMON_ARMOR, DEMON_SKIN = 16864, 10432, 11735, 696
local BLESSING_OF_KINGS = 20217

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Self-buffs in buff mode", function()
    local ns, button
    local logLines -- debug lines said since boot

    -- A class (a priest unless said) who knows `known` (spell IDs), in buff
    -- mode unless opts.noMode.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, buffSelf = true, autoBuffMode = opts.auto, buffTable = wow.selfBuffTable(),
            before = function(state)
                state.class = opts.class or "PRIEST"
                state.knownSpells = {}
                for _, id in ipairs(opts.known or { INNER_FIRE }) do state.knownSpells[id] = true end
                state.powerType = opts.power or "MANA"
                if opts.before then opts.before(state) end
            end })
        button = ns.BuffButton.Frame()
        logLines = {}
        local log = ns.Diag.Log
        ns.Diag.Log = function(category, fmt, ...)
            local args = { ... }
            for i = 1, select("#", ...) do args[i] = tostring(args[i]) end
            logLines[#logLines + 1] = string.format(fmt, unpack(args, 1, select("#", ...)))
            return log(category, fmt, ...)
        end
        if not opts.noMode then slash("buffmode on") end
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    -- Press the lent key once: the cast it made, or nil.
    local function press()
        local before = #wow.casts
        wow.pressKey("MOUSEWHEELUP")
        return wow.casts[before + 1]
    end

    local function party(names)
        wow.setGroup("party", names)
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    local function refresh() ns.BuffButton.Refresh() end

    -- Put a buff on you: yours unless source says otherwise, lasting seconds
    -- (0: a toggle that never runs out).
    local function wear(id, seconds, source)
        seconds = seconds or 600
        return wow.gainBuff({ spellId = id, sourceUnit = source == nil and "player" or source or nil,
            duration = seconds, expirationTime = seconds > 0 and wow.now + seconds or 0 })
    end

    local function strip()
        wow.state.playerAuras = {}
    end

    local function subtitle() return button.subtitle:GetText() end

    -- The debug log's lines that mention text.
    local function logged(text)
        local n = 0
        for _, line in ipairs(logLines) do
            if line:find(text, 1, true) then n = n + 1 end
        end
        return n
    end

    before_each(function() boot() end)

    describe("what it offers (white)", function()
        it("offers a self-buff you know and are missing on you, once favours and the group are done, "
            .. "and a press casts it", function()
            boot({ known = { INNER_FIRE, FORT } })
            party({ "Ann-Vale" })
            wow.wearBuff("party1", FORT, { source = "player" })
            wear(FORT, 3600)
            refresh()
            assert.are.equal(0, ns.Offers.Count())
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
            assert.are.equal("You", button.title:GetText())
            assert.are.equal("missing your Inner Fire", subtitle())
            local cast = press()
            assert.are.equal("Me", cast.target)
            assert.are.equal(INNER_FIRE, cast.id)
            assert.is_nil(cast.failed)
            -- It landed: worn now, so nothing is left.
            assert.is_nil(macro())
            assert.is_truthy(ns.BuffButton.StatusLines()[#ns.BuffButton.StatusLines()]:find("Cast Inner Fire on you", 1, true))
        end)

        it("offers them solo too (the owner, #44 Q2)", function()
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
            press()
            assert.is_nil(macro())
            assert.are.equal("you're not in a group", subtitle())
        end)

        it("casts the highest rank you know by its name", function()
            boot({ known = { INNER_FIRE_1 } })
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
            assert.are.equal(INNER_FIRE_1, press().id)
        end)

        it("names a two-spell buff by the one you know best: Frost Armor before you learn Ice Armor", function()
            boot({ class = "MAGE", known = { FROST_ARMOR } })
            assert.are.equal("/cast [@player,nodead] Frost Armor", macro())
            local cast = press()
            assert.are.equal(FROST_ARMOR, cast.id)
            assert.is_nil(macro(), "Frost Armor counts as the armor")
            boot({ class = "MAGE", known = { FROST_ARMOR, ICE_ARMOR } })
            assert.are.equal("/cast [@player,nodead] Ice Armor", macro())
        end)

        it("doesn't offer one you wear with more than the top-up time left, and offers one running low", function()
            wear(INNER_FIRE, 600)
            refresh()
            assert.is_nil(macro())
            -- Top-up time is 5 minutes, under half of 10: 4:59 left is low.
            wow.state.playerAuras[1].expirationTime = wow.now + 299
            refresh()
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
            wow.state.playerAuras[1].expirationTime = wow.now + 301
            refresh()
            assert.is_nil(macro())
        end)

        it("caps the top-up time at half the buff's full time: a 2-minute Battle Shout isn't low when it lands",
            function()
            boot({ class = "WARRIOR", known = { BATTLE_SHOUT }, power = "RAGE" })
            assert.are.equal("/cast [@player,nodead] Battle Shout", macro())
            press()
            assert.is_nil(macro(), "a fresh shout isn't running low")
            wow.advance(59)
            refresh()
            assert.is_nil(macro(), "61 seconds left of 120: more than half")
            wow.advance(2)
            refresh()
            assert.are.equal("/cast [@player,nodead] Battle Shout", macro(), "under a minute left of two")
        end)

        it("tops up with 0 top-up minutes only once it's gone", function()
            ns.db.buffBack.topUpMinutes = 0
            wear(INNER_FIRE, 600)
            wow.state.playerAuras[1].expirationTime = wow.now + 1
            refresh()
            assert.is_nil(macro())
        end)

        it("never tops up over a rank stronger than any you know", function()
            boot({ known = { INNER_FIRE_1 } })
            wear(INNER_FIRE, 600)
            wow.state.playerAuras[1].expirationTime = wow.now + 10
            refresh()
            assert.is_nil(macro())
        end)

        it("offers group members missing your buffs first, and your self-buffs after the last of them", function()
            boot({ known = { INNER_FIRE, FORT } })
            party({ "Ann-Vale", "Bo-Fern" })
            wear(FORT, 3600)
            local order = {}
            for _ = 1, 4 do
                local text = macro()
                if not text then break end
                local cast = press()
                order[#order + 1] = cast.target .. ":" .. cast.spell
                -- Show their buff on them.
                for token, u in pairs(wow.state.units) do
                    if u.id == cast.target and token:find("^party") then wow.wearBuff(token, cast.id, { source = "player" }) end
                end
                refresh()
            end
            assert.are.same({ "Ann-Vale:Power Word: Fortitude", "Bo-Fern:Power Word: Fortitude", "Me:Inner Fire" }, order)
        end)

        it("comes after your own copy of your group buffs too (#198)", function()
            boot({ known = { INNER_FIRE, FORT } })
            party({ "Ann-Vale" })
            wow.wearBuff("party1", FORT, { source = "player" })
            refresh()
            assert.are.equal("/cast [@player,nodead] Power Word: Fortitude", macro())
        end)

        it("never comes before a favour you owe", function()
            boot({ known = { INNER_FIRE, FORT } })
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
            wow.gainBuff({ sourceUnit = "nameplate1", spellId = INTELLECT })
            refresh()
            assert.are.equal(1, ns.Offers.Count())
            assert.is_truthy(macro():find("/targetexact Bob Stone", 1, true))
            local cast = press()
            assert.are.equal("Bob-Stone", cast.target)
            refresh()
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
        end)
    end)

    describe("toggles and families (white)", function()
        it("offers a hunter's first Aspect in the buff order, with \"!\", and never tops it up", function()
            boot({ class = "HUNTER", known = { HAWK, MONKEY } })
            assert.are.equal("/cast [@player,nodead] !Aspect of the Hawk", macro())
            local cast = press()
            assert.are.equal(HAWK, cast.id)
            assert.is_nil(macro())
            -- A toggle never runs low: hours later, still nothing.
            wow.advance(7200)
            refresh()
            assert.is_nil(macro())
        end)

        it("Monkey before level 10, while Hawk isn't known (#44 Q8)", function()
            boot({ class = "HUNTER", known = { MONKEY } })
            assert.are.equal("/cast [@player,nodead] !Aspect of the Monkey", macro())
        end)

        it("never replaces the Aspect you chose: wearing Monkey, Cheetah or Pack, no Aspect is offered", function()
            boot({ class = "HUNTER", known = { HAWK, MONKEY } })
            for _, id in ipairs({ MONKEY, CHEETAH, PACK, BEAST, WILD }) do
                strip()
                wear(id, 0)
                refresh()
                assert.is_nil(macro(), "wearing " .. id)
            end
        end)

        it("offers the first Aspect not marked Never offer, in your order", function()
            boot({ class = "HUNTER", known = { HAWK, MONKEY, WILD } })
            ns.Options.SetNeverOffer("hawk", true)
            assert.are.equal("/cast [@player,nodead] !Aspect of the Monkey", macro())
            ns.Options.MoveBuff("wildaspect", -1)
            ns.Options.MoveBuff("wildaspect", -1)
            assert.are.equal("/cast [@player,nodead] !Aspect of the Wild", macro())
        end)

        it("offers Trueshot Aura beside your Aspect: its own toggle", function()
            boot({ class = "HUNTER", known = { HAWK, TRUESHOT } })
            wear(HAWK, 0)
            refresh()
            assert.are.equal("/cast [@player,nodead] !Trueshot Aura", macro())
            press()
            assert.is_nil(macro())
        end)

        it("offers a paladin's first aura (Devotion by default) only when no aura of yours is on", function()
            boot({ class = "PALADIN", known = { DEVOTION, RETRIBUTION, CONCENTRATION } })
            assert.are.equal("/cast [@player,nodead] !Devotion Aura", macro())
            wear(CONCENTRATION, 0)
            refresh()
            assert.is_nil(macro())
        end)

        it("one armor at a time: with Mage Armor on, no Ice Armor; with neither, the first in your order", function()
            boot({ class = "MAGE", known = { ICE_ARMOR, MAGE_ARMOR } })
            assert.are.equal("/cast [@player,nodead] Ice Armor", macro(), "Ice before Mage Armor by default (Q8)")
            wear(MAGE_ARMOR, 1800)
            refresh()
            assert.is_nil(macro())
            strip()
            ns.Options.MoveBuff("magearmor", -1)
            refresh()
            assert.are.equal("/cast [@player,nodead] Mage Armor", macro())
        end)

        it("tops up the armor you wear, not the first of its family", function()
            boot({ class = "MAGE", known = { ICE_ARMOR, MAGE_ARMOR } })
            wear(MAGE_ARMOR, 1800)
            wow.state.playerAuras[1].expirationTime = wow.now + 100
            refresh()
            assert.are.equal("/cast [@player,nodead] Mage Armor", macro())
        end)

        it("another warrior's Battle Shout on you counts as having it, and is never cast over", function()
            boot({ class = "WARRIOR", known = { BATTLE_SHOUT }, power = "RAGE" })
            party({ "Ann-Vale" })
            wow.state.playerAuras = {}
            wear(BATTLE_SHOUT, 120, "party1")
            wow.state.playerAuras[1].expirationTime = wow.now + 5
            refresh()
            assert.is_nil(macro())
        end)

        it("another paladin's aura, or another hunter's Aspect of the Wild, isn't yours", function()
            boot({ class = "PALADIN", known = { DEVOTION } })
            party({ "Ann-Vale" })
            wear(DEVOTION, 0, "party1")
            refresh()
            assert.are.equal("/cast [@player,nodead] !Devotion Aura", macro())
            boot({ class = "HUNTER", known = { HAWK } })
            party({ "Ann-Vale" })
            wear(WILD, 0, "party1")
            refresh()
            assert.are.equal("/cast [@player,nodead] !Aspect of the Hawk", macro())
        end)

        it("a press after the toggle is already on switches nothing off (the \"!\")", function()
            boot({ class = "HUNTER", known = { HAWK } })
            local text = macro()
            press()
            -- The same macro pressed again (a second press before the re-arm):
            -- the game casts nothing, and the Aspect stays on.
            wow.runMacro(text)
            assert.are.equal(1, #wow.state.playerAuras)
            assert.are.equal(HAWK, wow.state.playerAuras[1].spellId)
        end)

        it("keeps your target as it is", function()
            boot({ class = "HUNTER", known = { HAWK } })
            wow.addUnit("target", { name = "Bob", surname = "Stone", id = "Bob-Stone" })
            local target = wow.state.units.target
            press()
            assert.are.equal(target, wow.state.units.target)
        end)
    end)

    describe("your settings (white)", function()
        it("Never offer: a self-buff that's off is never offered, and buff mode's done check doesn't wait",
            function()
            boot({ auto = true, noMode = true, known = { INNER_FIRE } })
            ns.Options.SetNeverOffer("innerfire", true)
            ns.BuffMode.Set(true, { auto = true, why = "test" })
            assert.is_false(ns.BuffMode.IsOn(), "nothing to do: buff mode doesn't even turn on")
            assert.is_nil(ns.SelfBuffs.Next())
        end)

        it("\"Offer my self-buffs\" off: none is offered", function()
            ns.db.buffBack.selfBuffs = false
            refresh()
            assert.is_nil(macro())
            assert.are.equal("you're not in a group", subtitle())
        end)

        it("a setting damaged mid-session reads as off, never as on", function()
            for _, junk in ipairs({ "yes", 1, {}, "true" }) do
                ns.db.buffBack.selfBuffs = junk
                refresh()
                assert.is_nil(macro(), tostring(junk))
            end
            ns.db.buffBack.selfBuffs = true
            refresh()
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
        end)

        it("offers a self-buff you've just learned", function()
            boot({ known = { FORT } })
            assert.is_nil(macro())
            wow.state.knownSpells[INNER_FIRE] = true
            wow.fire("SPELLS_CHANGED")
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
            wow.state.knownSpells[INNER_FIRE] = nil
            wow.fire("SPELLS_CHANGED")
            assert.is_nil(macro())
        end)

        it("the buff order decides among self-buffs too", function()
            boot({ class = "PALADIN", known = { DEVOTION, RETRIBUTION } })
            ns.Options.MoveBuff("retribution", -1)
            assert.are.equal("/cast [@player,nodead] !Retribution Aura", macro())
        end)

        it("Righteous Fury isn't offered until you untick its Never offer, and the untick is kept", function()
            boot({ class = "PALADIN", known = { RIGHTEOUS_FURY } })
            assert.is_true(ns.BuffData.NeverOffered(ns.BuffData.ByKey("righteousfury")))
            assert.is_nil(macro())
            assert.are.same({}, ns.db.buffBack.neverOffer, "the saved default stays empty")
            ns.Options.SetNeverOffer("righteousfury", false)
            assert.is_false(ns.db.buffBack.neverOffer.righteousfury)
            assert.are.equal("/cast [@player,nodead] Righteous Fury", macro())
            -- Kept through a reload's settings check.
            local saved = ns.db
            boot({ class = "PALADIN", known = { RIGHTEOUS_FURY }, db = saved })
            assert.are.equal("/cast [@player,nodead] Righteous Fury", macro())
            ns.Options.SetNeverOffer("righteousfury", true)
            assert.is_nil(macro())
        end)

        it("an untick of an ordinary buff saves nothing, as before", function()
            ns.Options.SetNeverOffer("innerfire", true)
            ns.Options.SetNeverOffer("innerfire", false)
            assert.is_nil(ns.db.buffBack.neverOffer.innerfire)
        end)

        it("checks the new setting on load: junk falls back to on", function()
            boot({ db = { buffBack = { selfBuffs = "yes", neverOffer = { righteousfury = false, innerfire = 7,
                nonsense = true } } } })
            assert.is_true(ns.db.buffBack.selfBuffs)
            assert.are.same({ righteousfury = false }, ns.db.buffBack.neverOffer)
        end)

        it("is on by default (the owner, Q1)", function()
            assert.is_true(ns.Config.DEFAULTS.buffBack.selfBuffs)
        end)

        it("shows self-buffs on the Buff Back tab as \"(you only)\", with no Who button, "
            .. "and the switch below the list", function()
            boot({ class = "PALADIN", known = { BLESSING_OF_KINGS, DEVOTION, RIGHTEOUS_FURY } })
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            local byKey = {}
            for _, row in ipairs(w.buffRows) do
                if row.key then byKey[row.key] = row end
            end
            assert.is_truthy(byKey.devotion.name:GetText():find("(you only)", 1, true))
            assert.is_false(byKey.devotion.who:IsShown())
            assert.is_true(byKey.kings.who:IsShown())
            assert.is_falsy(byKey.kings.name:GetText():find("(you only)", 1, true))
            assert.is_true(byKey.righteousfury.never:GetChecked(), "Righteous Fury: Never offer by default")
            assert.is_true(w.selfBuffs:IsShown())
            assert.is_true(w.selfBuffs:GetChecked())
            wow.run(w.selfBuffs, "OnClick")
            -- The Who section is never about a self-buff.
            ns.Options.CycleWho("devotion")
            assert.is_falsy(w.who.header:GetText():find("Devotion", 1, true))
        end)
    end)

    describe("the clickable list (white)", function()
        -- The rows shown, as text.
        local function rows()
            local out = {}
            local frame = ns.BuffList.Frame()
            if not frame or not frame:IsShown() then return out end
            for _, row in ipairs(ns.BuffList.Rows()) do
                if row:IsShown() then out[#out + 1] = row.text:GetText() end
            end
            return out
        end

        it("shows your self-buff as a \"You\" row, after every member's", function()
            boot({ known = { INNER_FIRE, FORT } })
            party({ "Ann-Vale", "Bo-Fern" })
            wear(FORT, 3600)
            refresh()
            assert.are.same({ "> Ann Vale: Power Word: Fortitude", "Bo Fern: Power Word: Fortitude",
                "You: Inner Fire" }, rows())
            -- Once they have it, your row is the one left, and the button's.
            wow.wearBuff("party1", FORT, { source = "player" })
            wow.wearBuff("party2", FORT, { source = "player" })
            refresh()
            assert.are.same({ "> You: Inner Fire" }, rows())
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
        end)

        it("a click on your row arms it", function()
            boot({ known = { INNER_FIRE, FORT } })
            party({ "Ann-Vale" })
            wear(FORT, 3600)
            refresh()
            ns.BuffList.Rows()[2].scripts.OnClick(ns.BuffList.Rows()[2])
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
        end)
    end)

    describe("buff mode's turn-on and turn-off (white)", function()
        it("a missing self-buff alone doesn't turn buff mode on (Q6)", function()
            boot({ auto = true, noMode = true, known = { INNER_FIRE, FORT } })
            wear(FORT, 3600)
            -- Joining a group whose members all have your buffs: nothing to do.
            wow.setGroup("party", { "Ann-Vale" })
            wow.wearBuff("party1", FORT, { source = "player" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(30)
            assert.is_false(ns.BuffMode.IsOn())
            -- A missing buff of yours on a member (#272) would: yours doesn't.
            ns.db.buffBack.autoOnMissing = true
            wow.advance(30)
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.equal("innerfire", ns.SelfBuffs.Next().buff.key, "Inner Fire is missing all along")
        end)

        it("\"everyone has your buffs\" waits for your self-buffs, then ends buff mode", function()
            boot({ auto = true, noMode = true, known = { INNER_FIRE, FORT } })
            party({ "Ann-Vale" })
            wear(FORT, 3600)
            wow.advance(30)
            assert.is_true(ns.BuffMode.IsAuto(), "Ann is missing Fortitude")
            press()
            wow.wearBuff("party1", FORT, { source = "player" })
            refresh()
            assert.is_true(ns.BuffMode.IsOn(), "still on: you're missing Inner Fire")
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
            press()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        -- Buff mode a stranger's buff turned on, with that favour returned
        -- and you missing Inner Fire for the reason setup gives.
        local function autoWith(setup)
            boot({ auto = true, noMode = true, known = { INNER_FIRE, FORT } })
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "PRIEST" })
            wow.gainBuff({ sourceUnit = "nameplate1", spellId = INTELLECT })
            wow.advance(1)
            assert.is_true(ns.BuffMode.IsAuto(), "a stranger's buff turned it on")
            wear(FORT, 3600)
            setup(wow.state)
            assert.are.equal("Bob-Stone", press().target)
            refresh()
            assert.are.equal(0, ns.Offers.Count())
            return ns.BuffMode.IsOn()
        end

        it("waits while your self-buff can come back by itself: power, death, or what can't be read", function()
            for name, setup in pairs({
                power = function(s) s.unusable["Inner Fire"] = "power" end,
                dead = function(s) s.units.player.dead = true end,
                auras = function(s) s.aurasRestricted = true end,
                usable = function(s) s.selfSecrets.usable = true end,
                mounted = function(s) s.selfSecrets.mounted = true end,
            }) do
                assert.is_true(autoWith(setup), name .. ": buff mode waits")
            end
        end)

        it("ends when only your choices hold your self-buff back: a mount, a flight, a form, Never offer, "
            .. "the switch, or a spell the game won't let you cast now", function()
            for name, setup in pairs({
                mounted = function(s) s.mounted = true end,
                taxi = function(s) s.onTaxi = true end,
                other = function(s) s.unusable["Inner Fire"] = "other" end,
                never = function() ns.db.buffBack.neverOffer.innerfire = true end,
                off = function() ns.db.buffBack.selfBuffs = false end,
                worn = function() wear(INNER_FIRE, 600) end,
            }) do
                assert.is_false(autoWith(setup), name .. ": buff mode ends")
            end
        end)

        it("ends once the self-buff it waited for lands", function()
            assert.is_true(autoWith(function() end))
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
            press()
            assert.is_false(ns.BuffMode.IsOn())
        end)
    end)

    describe("what can't be read (black)", function()
        it("offers nothing when your buffs can't be read at all, and says why", function()
            wow.state.aurasRestricted = true
            refresh()
            assert.is_nil(macro())
            assert.is_truthy(subtitle():find("You: can't see your buffs", 1, true))
        end)

        it("offers nothing for a secret aura, a secret or junk spell ID, or a missing API", function()
            local api = _G.C_UnitAuras.GetAuraDataByIndex
            finally(function() _G.C_UnitAuras.GetAuraDataByIndex = api end)
            for _, damaged in ipairs({
                function(_, i) if i == 1 then return wow.secret({ spellId = INNER_FIRE }) end end,
                function(_, i) if i == 1 then return { spellId = wow.secret(FORT) } end end,
                function(_, i) if i == 1 then return { spellId = "Inner Fire" } end end,
                function(_, i) if i == 1 then return "junk" end end,
                function() error("restricted") end,
            }) do
                _G.C_UnitAuras.GetAuraDataByIndex = damaged
                refresh()
                assert.is_nil(macro())
                assert.is_truthy(subtitle():find("can't see your buffs", 1, true))
            end
            _G.C_UnitAuras.GetAuraDataByIndex = nil
            refresh()
            assert.is_nil(macro())
        end)

        it("never casts over an aura whose times are secret or junk, and never errors", function()
            for _, times in ipairs({
                { wow.secret(600), wow.secret(wow.now + 1) }, { "ten", wow.now + 1 }, { 600, "soon" },
                { 0 / 0, wow.now + 1 }, { 600, 0 / 0 }, { nil, nil },
            }) do
                strip()
                wow.state.playerAuras[1] = { isHelpful = true, spellId = INNER_FIRE, sourceUnit = "player",
                    duration = times[1], expirationTime = times[2], auraInstanceID = 1, charges = wow.secret(3) }
                refresh()
                assert.is_nil(macro())
            end
            assert.are.same({}, wow.errors)
        end)

        it("never casts over a toggle whose caster can't be read", function()
            boot({ class = "HUNTER", known = { HAWK } })
            wow.state.playerAuras[1] = { isHelpful = true, spellId = MONKEY, sourceUnit = wow.secret("player"),
                duration = 0, expirationTime = 0, auraInstanceID = 1 }
            refresh()
            assert.is_nil(macro())
            assert.is_truthy(subtitle():find("can't tell who cast your", 1, true))
        end)

        it("a secret or junk usable answer never errors and never casts", function()
            local api = _G.C_Spell.IsSpellUsable
            finally(function() _G.C_Spell.IsSpellUsable = api end)
            for _, answer in ipairs({
                function() return wow.secret(true), wow.secret(false) end,
                function() return "yes" end,
                function() return nil end,
                function() error("no") end,
            }) do
                _G.C_Spell.IsSpellUsable = answer
                refresh()
                assert.is_nil(macro())
                assert.is_truthy(subtitle():find("can't tell whether Inner Fire can be cast now", 1, true))
            end
            -- An older client: IsUsableSpell answers instead.
            _G.C_Spell.IsSpellUsable = nil
            refresh()
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("when it waits (black)", function()
        local cases = {
            { "dead", function(s) s.units.player.dead = true end, "you're dead" },
            { "mounted", function(s) s.mounted = true end, "you're mounted" },
            { "on a flight path", function(s) s.onTaxi = true end, "you're on a flight path" },
        }
        for _, case in ipairs(cases) do
            it("offers nothing while you're " .. case[1] .. ", says why, and logs it once", function()
                case[2](wow.state)
                refresh()
                assert.is_nil(macro())
                assert.is_truthy(subtitle():find("You: " .. case[3], 1, true))
                refresh()
                refresh()
                assert.are.equal(1, logged("self-buff not offered: " .. case[3]))
            end)
        end

        it("offers nothing to a druid in a form, or a shaman in Ghost Wolf", function()
            boot({ class = "DRUID", known = { OMEN }, before = function(s) s.form = 1 end })
            assert.is_nil(macro())
            assert.is_truthy(subtitle():find("you're in a form", 1, true))
            wow.state.form = 0
            refresh()
            assert.are.equal("/cast [@player,nodead] Omen of Clarity", macro())
            boot({ class = "SHAMAN", known = { LIGHTNING_SHIELD }, before = function(s) s.form = 1 end })
            assert.is_nil(macro())
            assert.is_truthy(subtitle():find("you're in Ghost Wolf", 1, true))
        end)

        it("a warrior's stance is no reason to wait", function()
            boot({ class = "WARRIOR", known = { BATTLE_SHOUT }, power = "RAGE", before = function(s) s.form = 2 end })
            assert.are.equal("/cast [@player,nodead] Battle Shout", macro())
        end)

        it("says \"not enough rage\" (or mana) when the game says so", function()
            boot({ class = "WARRIOR", known = { BATTLE_SHOUT }, power = "RAGE",
                before = function(s) s.unusable["Battle Shout"] = "power" end })
            assert.is_nil(macro())
            assert.is_truthy(subtitle():find("not enough rage for Battle Shout", 1, true))
            assert.are.equal(1, logged("not enough rage for Battle Shout"))
            boot({ before = function(s) s.unusable["Inner Fire"] = "power" end })
            assert.is_truthy(subtitle():find("not enough mana for Inner Fire", 1, true))
        end)

        it("offers nothing the game says can't be cast now (Inner Fire in Shadowform)", function()
            boot({ before = function(s) s.unusable["Inner Fire"] = "other" end })
            assert.is_nil(macro())
            assert.is_truthy(subtitle():find("Inner Fire can't be cast now", 1, true))
        end)

        it("skips an unusable one and offers the next", function()
            boot({ class = "MAGE", known = { ICE_ARMOR }, before = function(s) s.unusable["Ice Armor"] = "power" end })
            assert.is_nil(macro())
            boot({ class = "PALADIN", known = { DEVOTION, RIGHTEOUS_FURY },
                before = function(s) s.unusable["Devotion Aura"] = "power" end })
            ns.Options.SetNeverOffer("righteousfury", false)
            assert.are.equal("/cast [@player,nodead] Righteous Fury", macro())
        end)

        it("can't tell whether you're mounted, flying, dead or in a form: offers nothing", function()
            for _, field in ipairs({ "mounted", "taxi" }) do
                boot()
                wow.state.selfSecrets[field] = true
                refresh()
                assert.is_nil(macro(), field)
                assert.is_truthy(subtitle():find("can't tell whether", 1, true), field)
            end
            boot({ class = "DRUID", known = { OMEN } })
            wow.state.selfSecrets.form = true
            refresh()
            assert.is_nil(macro())
            assert.is_truthy(subtitle():find("can't tell whether you're in a form", 1, true))
            boot()
            wow.state.units.player.secrets = { dead = true }
            local real = _G.UnitIsDeadOrGhost
            finally(function() _G.UnitIsDeadOrGhost = real end)
            _G.UnitIsDeadOrGhost = function(unit) if unit == "player" then return wow.secret(false) end return real(unit) end
            refresh()
            assert.is_nil(macro())
            for _, name in ipairs({ "IsMounted", "UnitOnTaxi" }) do
                boot()
                local fn = _G[name]
                _G[name] = nil
                refresh()
                assert.is_nil(macro(), name .. " missing")
                _G[name] = fn
            end
        end)

        it("never arms a spell name that isn't safe in a macro, or a macro over 255 characters", function()
            local real = _G.C_Spell.GetSpellName
            finally(function() _G.C_Spell.GetSpellName = real end)
            for _, bad in ipairs({ "Inner Fire\n/cast Pyroblast", "Inner Fire; Pyroblast", "[harm] Inner Fire",
                "/yell boo", "a |cffff0000red|r spell", string.rep("x", 240) }) do
                _G.C_Spell.GetSpellName = function(id) if id == INNER_FIRE then return bad end return real(id) end
                refresh()
                assert.is_nil(macro(), bad)
            end
            -- "/cast [@player,nodead] !" is 24 characters.
            assert.is_nil(ns.BuffButton.BuildCastMacro("Me", string.rep("x", 232), true, true, true))
            assert.are.equal(255, #ns.BuffButton.BuildCastMacro("Me", string.rep("x", 231), true, true, true))
        end)

        it("never offers a stance or form, Cheetah, Pack or Beast, or a removed spell, "
            .. "even if the saved order names it", function()
            boot({ class = "HUNTER", known = { CHEETAH, PACK, BEAST },
                db = { buffBack = { buffOrder = { "cheetah", "pack", "beast", "bearform", "salvation", "light" } } } })
            assert.is_nil(macro())
            boot({ class = "PALADIN", known = { 19977, 1038 } })
            assert.is_nil(macro())
            for _, id in ipairs({ CHEETAH, PACK, BEAST }) do
                assert.is_nil(ns.BuffData.ForCast(id))
                assert.are.equal("aspect", ns.BuffData.SelfFamilyOf(id))
            end
        end)

        it("offers and arms nothing in combat, and again after the fight", function()
            wow.enterCombat()
            refresh()
            assert.is_nil(macro())
            assert.is_nil(ns.SelfBuffs.Next())
            local before = #wow.casts
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(before, #wow.casts)
            wow.leaveCombat()
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
        end)

        it("a refused cast waits a moment, and the next press goes to the next self-buff", function()
            boot({ class = "PALADIN", known = { DEVOTION, RIGHTEOUS_FURY } })
            ns.Options.SetNeverOffer("righteousfury", false)
            wow.state.castFailures.Me = "You can't do that right now."
            local cast = press()
            assert.are.equal(RIGHTEOUS_FURY, cast.id, "first in the class's order")
            assert.is_truthy(cast.failed)
            wow.state.castFailures.Me = nil
            refresh()
            assert.are.equal("/cast [@player,nodead] !Devotion Aura", macro())
            press()
            refresh()
            assert.is_nil(macro(), "Righteous Fury waits after its refusal")
            assert.is_truthy(subtitle():find("the game refused your last Righteous Fury", 1, true))
            wow.advance(ns.SelfBuffs.HELD_BACK_SECONDS + 1)
            refresh()
            assert.are.equal("/cast [@player,nodead] Righteous Fury", macro())
        end)

        it("right-click skips your self-buffs for a while", function()
            wow.press(button, "RightButton")
            assert.is_nil(macro())
            wow.advance(ns.SelfBuffs.SKIP_SECONDS + 1)
            refresh()
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
            -- Shift adds you to no Never list.
            wow.press(button, "RightButton", { shift = true })
            assert.are.same({}, ns.db.buffBack.whoGets.innerfire or {})
            assert.is_nil(macro())
        end)

        it("is never a favour, a receipt, a thank-you or a line in chat, even cast by hand", function()
            ns.db.buff.receipts = true
            press()
            wow.runMacro("/cast Inner Fire")
            assert.are.same({}, wow.sent)
            assert.are.same({}, wow.addonSent)
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("leaves the dungeon round's re-sync to the group's buffs (#256)", function()
            boot({ class = "MAGE", known = { ICE_ARMOR, INTELLECT } })
            party({ "Ann-Vale" })
            -- Put up well before the round began, with plenty left: left alone.
            wear(ICE_ARMOR, 1800)
            wow.advance(400)
            wow.wearBuff("party1", INTELLECT, { source = "player" })
            wear(INTELLECT, 3600)
            ns.GroupBuffs.StartRound()
            refresh()
            assert.is_nil(macro())
        end)
    end)

    describe("chaos (red)", function()
        -- Put a cast's buff on whoever it landed on, as the game would (your
        -- own self-buffs the simulated client puts on itself).
        local function show(cast)
            if not cast or cast.failed or cast.target == "Me" then return end
            for token, u in pairs(wow.state.units) do
                if u.id == cast.target and token:find("^party%d") then
                    wow.wearBuff(token, cast.id, { source = "player" })
                end
            end
        end

        it("a self-buff never takes priority over a favour you owe or a member missing your buff", function()
            local members = { "Ann-Vale", "Bo-Fern", "Cid-Rock" }
            local reached = { self = 0, group = 0, favour = 0, contested = 0 }
            for _, seed in ipairs({ 5, 23, 144, 808, 2026, 4242 }) do
                random.seed(seed)
                boot({ known = { INNER_FIRE, FORT } })
                ns.db.buffBack.owedMinutes = 30
                party(members)
                local strangers = 0
                -- [stranger's id] = true while you owe them: they buffed you,
                -- and no cast of yours has reached them since.
                local owed = {}
                -- [member's id] = when your buff last reached them: the addon
                -- counts it as theirs for JUST_GIVEN_SECONDS, as the game shows
                -- it a moment later.
                local given = {}
                for _ = 1, 300 do
                    local roll = random.random(1, 10)
                    if roll == 1 then
                        -- A member's Fortitude fades.
                        local u = wow.state.units["party" .. random.random(1, 3)]
                        u.auras, u.auraSources, u.auraDurations, u.auraExpires = {}, {}, {}, {}
                    elseif roll == 2 then
                        -- Your own buffs fade.
                        strip()
                    elseif roll == 3 and strangers < 8 then
                        -- A new stranger buffs you.
                        strangers = strangers + 1
                        -- Player names have no digits.
                        local name = ({ "Bob", "Cal", "Dee", "Eli", "Fay", "Gil", "Hal", "Ida" })[strangers]
                        wow.addUnit("nameplate" .. strangers, { name = name, surname = "Far", id = name .. "-Far",
                            class = "MAGE" })
                        wow.gainBuff({ sourceUnit = "nameplate" .. strangers, spellId = INTELLECT })
                        owed[name .. "-Far"] = true
                    elseif roll == 4 then
                        wow.advance(random.random(1, 30))
                    else
                        refresh()
                        -- Before the press, from the client's own state: is
                        -- anything ahead of your self-buffs, and are you missing one?
                        local ahead = next(owed) ~= nil
                        for i = 1, 3 do
                            local u = wow.state.units["party" .. i]
                            local has = given[u.id] ~= nil and wow.now - given[u.id] < ns.GroupBuffs.JUST_GIVEN_SECONDS
                            for _, id in ipairs(u.auras or {}) do
                                has = has or id == FORT
                            end
                            ahead = ahead or not has
                        end
                        local mineMissing = true
                        for _, a in ipairs(wow.state.playerAuras) do
                            if a.spellId == INNER_FIRE then mineMissing = false end
                        end
                        local cast = press()
                        if cast and not cast.failed then
                            if cast.id == INNER_FIRE then
                                reached.self = reached.self + 1
                                assert.is_false(ahead, "seed " .. seed .. ": Inner Fire went before someone waiting")
                            elseif owed[cast.target] then
                                owed[cast.target] = nil
                                reached.favour = reached.favour + 1
                            else
                                reached.group = reached.group + 1
                            end
                            if ahead and mineMissing then reached.contested = reached.contested + 1 end
                            given[cast.target] = wow.now
                            show(cast)
                        end
                    end
                end
                assert.are.same({}, wow.errors)
            end
            assert.is_true(reached.self >= 50, "self-buffs cast: " .. reached.self)
            assert.is_true(reached.group >= 150, "group buffs cast: " .. reached.group)
            assert.is_true(reached.favour >= 25, "favours returned: " .. reached.favour)
            assert.is_true(reached.contested >= 80, "presses with both waiting: " .. reached.contested)
        end)

        -- The classes the storm plays, with every self-buff they know.
        local CLASSES = {
            { class = "PALADIN", power = "MANA", known = { DEVOTION, RETRIBUTION, CONCENTRATION, RIGHTEOUS_FURY } },
            { class = "HUNTER", power = "MANA", known = { HAWK, MONKEY, WILD, TRUESHOT, CHEETAH, PACK } },
            { class = "MAGE", power = "MANA", known = { ICE_ARMOR, FROST_ARMOR, MAGE_ARMOR } },
            { class = "WARRIOR", power = "RAGE", known = { BATTLE_SHOUT } },
            { class = "DRUID", power = "MANA", known = { OMEN } },
            { class = "WARLOCK", power = "MANA", known = { DEMON_ARMOR, DEMON_SKIN } },
        }

        it("a storm of auras, deaths, mounts, forms, fights, power, spells and junk settings never errors, "
            .. "never casts when it mustn't, and heals to a correct offer", function()
            local reached = { cast = 0, combat = 0, waited = 0, healed = 0 }
            -- Saved settings are plain data: never a secret.
            local junk = { "yes", 7, {}, false, true, { innerfire = "x" }, { 5, "monkey" } }
            for _, seed in ipairs({ 3, 41, 97, 512, 1999, 31337 }) do
                random.seed(seed)
                local setup = CLASSES[random.random(1, #CLASSES)]
                boot({ class = setup.class, known = setup.known, power = setup.power })
                local spellNames = {}
                for _, id in ipairs(setup.known) do spellNames[#spellNames + 1] = wow.SPELL_NAMES[id] end
                -- The damage passes: all of it (all), or one kind at random.
                local function heal(all)
                    local s = wow.state
                    local kind = all and 0 or random.random(1, 4)
                    if all or kind == 1 then
                        if s.inCombat then wow.leaveCombat() end
                        s.units.player.dead, s.mounted, s.onTaxi, s.form = false, false, false, 0
                    end
                    if all or kind == 2 then s.aurasRestricted, s.unusable, s.selfSecrets = false, {}, {} end
                    if all or kind == 3 then
                        for _, id in ipairs(setup.known) do s.knownSpells[id] = true end
                        wow.fire("SPELLS_CHANGED")
                    end
                    if all or kind == 4 then
                        ns.db.buffBack.selfBuffs, ns.db.buffBack.topUpMinutes = true, 5
                        ns.db.buffBack.neverOffer, ns.db.buffBack.buffOrder = { righteousfury = false }, {}
                    end
                end
                for step = 1, 800 do
                    local roll = random.random(1, 22)
                    local s = wow.state
                    if roll == 1 then strip()
                    elseif roll == 2 then wear(setup.known[random.random(1, #setup.known)], random.random(0, 1) * 600)
                    elseif roll == 3 then
                        -- A secret, junk or another player's aura.
                        local pick = random.random(1, 3)
                        if pick == 1 then
                            s.playerAuras[#s.playerAuras + 1] = wow.lockedAura(setup.known[1])
                        elseif pick == 2 then
                            s.playerAuras[#s.playerAuras + 1] = { isHelpful = true, spellId = "junk", auraInstanceID = step }
                        else
                            wear(setup.known[random.random(1, #setup.known)], 0, false)
                        end
                    elseif roll == 4 then s.units.player.dead = not s.units.player.dead
                    elseif roll == 5 then s.mounted = not s.mounted
                    elseif roll == 6 then s.onTaxi = random.random(1, 4) == 1
                    elseif roll == 7 then s.form = random.random(0, 2) - 1 < 1 and 0 or 1
                    elseif roll == 8 then
                        if s.inCombat then wow.leaveCombat() else wow.enterCombat() end
                    elseif roll == 9 then
                        local name = spellNames[random.random(1, #spellNames)]
                        local kinds = { nil, "power", "other" }
                        s.unusable[name] = kinds[random.random(1, 3)]
                    elseif roll == 10 then
                        -- A spell forgotten or learned (a respec, a trainer).
                        local id = setup.known[random.random(1, #setup.known)]
                        s.knownSpells[id] = not s.knownSpells[id] or nil
                        wow.fire("SPELLS_CHANGED")
                    elseif roll == 11 then
                        local field = ({ "selfBuffs", "topUpMinutes", "neverOffer", "buffOrder" })[random.random(1, 4)]
                        ns.db.buffBack[field] = junk[random.random(1, #junk)]
                    elseif roll == 12 then
                        local field = ({ "mounted", "taxi", "form", "usable", "power" })[random.random(1, 5)]
                        s.selfSecrets[field] = not s.selfSecrets[field] or nil
                    elseif roll == 13 then s.aurasRestricted = random.random(1, 3) == 1
                    elseif roll == 14 then wow.advance(random.random(1, 400))
                    elseif roll <= 17 then heal(false)
                    else
                        local blocked = s.inCombat or s.units.player.dead or s.mounted or s.onTaxi
                            or s.aurasRestricted
                        local before = #wow.casts
                        local ok, err = pcall(press)
                        assert.is_true(ok, tostring(err))
                        for i = before + 1, #wow.casts do
                            local cast = wow.casts[i]
                            assert.is_nil(cast.inCombat, "seed " .. seed .. ": a cast in combat")
                            assert.are.equal("Me", cast.target, "seed " .. seed .. ": on someone else")
                            assert.is_nil(cast.toggledOff, "seed " .. seed .. ": a toggle switched off")
                            local info = wow.SELF_SPELLS[cast.id]
                            assert.is_truthy(info, "seed " .. seed .. ": not a self-buff")
                            assert.is_true(info.toggle ~= true or cast.bang == true, "seed " .. seed .. ": a toggle without !")
                            assert.is_falsy(blocked, "seed " .. seed .. ": cast when it must wait")
                            assert.is_nil(s.unusable[cast.spell] and not s.selfSecrets.usable and true or nil,
                                "seed " .. seed .. ": cast while unusable")
                            assert.is_true(cast.id ~= CHEETAH and cast.id ~= PACK, "seed " .. seed .. ": Cheetah or Pack")
                            reached.cast = reached.cast + 1
                        end
                        if #wow.casts == before then
                            if s.inCombat then reached.combat = reached.combat + 1 else reached.waited = reached.waited + 1 end
                        end
                    end
                end
                assert.are.same({}, wow.errors)
                -- Heal: the damage stops, and the settings are put right.
                local s = wow.state
                heal(true)
                strip()
                wow.advance(ns.SelfBuffs.SKIP_SECONDS + 1)
                refresh()
                -- Press until nothing is left: then every family and buff
                -- of the class (the client's own list) is on you.
                for _ = 1, 12 do
                    if not press() then break end
                end
                refresh()
                assert.is_nil(macro(), "seed " .. seed .. ": still offering")
                local wanted = {}
                for _, id in ipairs(setup.known) do
                    local info = wow.SELF_SPELLS[id]
                    if id ~= CHEETAH and id ~= PACK then wanted[info.family or wow.SPELL_NAMES[id]] = true end
                end
                for _, a in ipairs(s.playerAuras) do
                    local info = wow.SELF_SPELLS[a.spellId]
                    if info then wanted[info.family or wow.SPELL_NAMES[a.spellId]] = nil end
                end
                assert.are.same({}, wanted, "seed " .. seed .. ": healed, all on")
                reached.healed = reached.healed + 1
            end
            assert.is_true(reached.cast >= 20, "casts: " .. reached.cast)
            assert.is_true(reached.combat >= 100, "presses in combat: " .. reached.combat)
            assert.is_true(reached.waited >= 200, "presses that waited: " .. reached.waited)
            assert.are.equal(6, reached.healed)
        end)
    end)

    describe("found by the architecture review (#44)", function()
        it("with more helpful buffs on you than the addon looks through, still works and never errors (black)",
            function()
            for i = 1, ns.Offers.MAX_AURAS + 5 do wear(900000 + i, 3600, false) end
            refresh()
            assert.are.same({}, wow.errors)
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
            assert.is_not_nil(ns.SelfBuffs.Next())
        end)

        it("a clicked \"You\" row for your group buff doesn't carry over to your self-buffs ahead of a favour (red)",
            function()
            boot({ known = { INNER_FIRE, FORT } })
            party({ "Ann-Vale" })
            wow.wearBuff("party1", FORT, { source = "player" })
            refresh()
            -- The "You" row offers your Fortitude (#198): click it, and press.
            local rows = ns.BuffList.Rows()
            local youRow
            for i, offer in ipairs(ns.BuffList.ShownOffers()) do
                if offer.self then youRow = rows[i] end
            end
            if youRow then youRow.scripts.OnClick(youRow) end
            assert.are.equal("/cast [@player,nodead] Power Word: Fortitude", macro())
            press()
            -- Then a stranger buffs you: the favour comes before Inner Fire.
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
            wow.gainBuff({ sourceUnit = "nameplate1", spellId = INTELLECT })
            refresh()
            assert.are.equal(1, ns.Offers.Count())
            assert.is_truthy(macro():find("/targetexact Bob Stone", 1, true), macro())
        end)

        it("a clicked self-buff row picks that self-buff (white)", function()
            boot({ known = { INNER_FIRE, FORT } })
            party({ "Ann-Vale" })
            wear(FORT, 3600)
            refresh()
            ns.BuffButton.Choose(ns.SelfBuffs.Next().name, true)
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
        end)

        it("logs each reason once while it holds, whoever asks (black)", function()
            boot({ class = "PALADIN", known = { DEVOTION, RIGHTEOUS_FURY },
                before = function(s) s.unusable["Devotion Aura"] = "power" end })
            ns.Options.SetNeverOffer("righteousfury", false)
            for _ = 1, 10 do
                refresh()
                ns.SelfBuffs.Next()
                wow.advance(5)
            end
            assert.are.equal("/cast [@player,nodead] Righteous Fury", macro())
            assert.are.equal(1, logged("not enough mana for Devotion Aura"))
        end)

        it("a self-buff the game says went to another player never returns their favour (black)", function()
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
            wow.gainBuff({ sourceUnit = "nameplate1", spellId = INTELLECT })
            ns.db.buffBack.selfBuffs = false
            refresh()
            assert.are.equal(1, ns.Offers.Count())
            -- A hand cast whose SENT names Bob, your target (#326 says how
            -- Forever names a self-only spell's target).
            wow.state.units.target = wow.state.units.nameplate1
            ns.BuffButton.OnSpellcastSent("player", "Bob", "Cast-hand", INNER_FIRE)
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-hand", INNER_FIRE)
            assert.are.equal(1, ns.Offers.Count())
            assert.are.same({}, wow.addonSent)
        end)
    end)

    describe("an update that adds SelfBuffs.lua (black)", function()
        it("asks for a restart, not erroring, after only a /reload", function()
            wow.reset()
            local loaded = {}
            local _, files = wow.parseToc()
            for _, file in ipairs(files) do
                if file ~= "SelfBuffs.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
            end
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            wow.fire("PLAYER_ENTERING_WORLD", true, false)
            wow.advance(20)
            assert.are.same({}, wow.errors)
            assert.are.equal(0, #wow.casts)
            assert.truthy(table.concat(wow.printed, "\n"):find("Restart the game (not /reload)", 1, true))
        end)
    end)
end)
