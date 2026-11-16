-- Spec: #350, #408
-- The shaman's Water Walking is offered only when someone asks for it in
-- chat (#40; the owner's decision on #350): "water walking", "ww" or "walk
-- on water". Buff back and buff mode never offer it unasked, and the water
-- rule doesn't hold it back. Its ID on Forever is 546 (owner, from Wowhead's
-- Forever page), which the extracted spell data doesn't have, so it is
-- hand-listed: it is offered only when the client names spell 546 exactly
-- "Water Walking", so a wrong ID would never be offered or cast. A player
-- with Water Walking from any source (546, the item effect 1299351, the
-- potions 11319 and 1310296) already has it (owner, #350).
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local WATER_WALKING = 546
local WATER_BREATHING = 131
-- Water Walking from an item and from potions (owner, #350).
local OTHER_WATER_WALKING = { 1299351, 11319, 1310296 }
local INTELLECT = 10157
local ME = { name = "Nikki", surname = "Shifts", id = "Nikki-Shifts", isPlayer = true }

-- Ways players ask for it, written from how players ask.
local ASKS = { "ww", "ww pls", "WW?", "water walking", "Water Walking please", "can i get ww?",
    "walk on water", "could i get walk on water", "any ww?", "need water walking pls ty" }

describe("Water Walking, offered only on request", function()
    local ns, button

    local function slash(cmd) _G.SlashCmdList.FRIENDLYFOREVER(cmd) end

    -- A shaman who knows known (spell IDs), with requests on unless off.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = opts.class or "SHAMAN"
            state.knownSpells = {}
            for _, id in ipairs(opts.known or { WATER_WALKING, WATER_BREATHING }) do state.knownSpells[id] = true end
            state.units.player = { name = ME.name, surname = ME.surname, id = ME.id, isPlayer = true }
        end })
        if opts.requests ~= false then ns.Requests.SetEnabled(true) end
        ns.db.debug = true
        button = ns.BuffButton.Frame()
    end

    local function stranger(spec)
        spec = spec or {}
        spec.name, spec.surname, spec.class = "Bob", "Stone", spec.class or "WARRIOR"
        spec.id = "Bob-Stone"
        wow.addUnit("nameplate1", spec)
    end

    local function offered()
        local offer, why = ns.Offers.Current()
        return offer and offer.spell, offer and offer.name, why
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    -- Every buff key the button could offer anyone now.
    local function offeredKeys()
        local list = {}
        ns.Offers.Current(list)
        local keys = {}
        for _, offer in ipairs(list) do keys[#keys + 1] = offer.buff.key end
        return keys
    end

    -- Restores spell 546's name after a spec renames it.
    local saved
    before_each(function() saved = wow.SPELL_NAMES[WATER_WALKING] end)
    after_each(function() wow.SPELL_NAMES[WATER_WALKING] = saved end)

    describe("asked for in chat (white)", function()
        it("\"water walking\", \"ww\" and \"walk on water\", by whisper, /say or party, put Water Walking on the "
            .. "button for them, and the press casts it on them", function()
            for i, text in ipairs(ASKS) do
                boot()
                stranger()
                if i % 3 == 0 then
                    wow.whisper(text, "Bob-Stone")
                elseif i % 3 == 1 then
                    wow.say(text, "Bob-Stone")
                else
                    wow.party(text, "Bob-Stone")
                end
                local spell, name = offered()
                assert.are.equal("Water Walking", spell, text)
                assert.are.equal("Bob-Stone", name, text)
            end
            assert.are.equal("asked for Water Walking", button.subtitle:GetText())
            assert.is_truthy(macro():find("/cast [help,nodead] Water Walking", 1, true))
            assert.are.equal(0, #wow.casts, "a request never casts by itself")
            wow.press(button)
            assert.are.same({ spell = "Water Walking", id = WATER_WALKING, target = "Bob-Stone" }, wow.casts[1])
            assert.is_nil(offered(), "answered: they're no longer on the button")
        end)

        it("isn't held back away from water: the water rule doesn't apply to it", function()
            boot()
            assert.is_false(wow.inWater())
            stranger()
            wow.whisper("ww pls", "Bob-Stone")
            assert.are.equal("Water Walking", (offered()))
        end)

        it("is listed on the Buffs tab as \"(when asked)\", with no Who button, and \"never offer\" doesn't "
            .. "stop requests for it (#408)", function()
            boot()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffs, "OnClick")
            local row
            for _, r in ipairs(w.buffRows) do
                if r.key == "waterwalking" then row = r end
            end
            assert.is_truthy(row, "a row for Water Walking")
            assert.is_truthy(row.name:GetText():find("Water Walking", 1, true))
            assert.is_truthy(row.name:GetText():find("(when asked)", 1, true))
            assert.is_falsy(row.name:GetText():find("(not known yet)", 1, true))
            assert.is_true(row.never:IsVisible())
            for _, place in ipairs(ns.BuffRules.PLACES) do
                wow.run(w.placeTabs[place], "OnClick")
                for _, who in ipairs(w.whoRows) do
                    if who.key == "waterwalking" then assert.is_false(who.who:IsVisible(), place) end
                end
            end
            -- The owner (#408, question 5): a request is given whatever Never offer says.
            ns.Options.SetNeverOffer("waterwalking", true)
            stranger()
            wow.whisper("ww pls", "Bob-Stone")
            assert.is_truthy(offered(), "asked for, so offered, even marked never offer")
        end)
    end)

    describe("already has it, from any source (white)", function()
        it("a player wearing Water Walking from the spell, an item or a potion isn't offered it: their request "
            .. "is met", function()
            for _, id in ipairs({ WATER_WALKING, OTHER_WATER_WALKING[1], OTHER_WATER_WALKING[2],
                OTHER_WATER_WALKING[3] }) do
                boot()
                stranger({ auras = { id } })
                wow.whisper("ww pls", "Bob-Stone")
                local spell, _, why = offered()
                assert.is_nil(spell, id)
                assert.are.equal("Bob Stone: they already have Water Walking", why, id)
                -- Once it's gone, it's offered.
                wow.state.units.nameplate1.auras = {}
                assert.are.equal("Water Walking", (offered()), id)
            end
        end)

        it("the item's and potions' Water Walking count as having it, but are never cast or learned as it",
            function()
                boot()
                local buff = ns.BuffData.ByKey("waterwalking")
                for _, id in ipairs(OTHER_WATER_WALKING) do
                    assert.is_true(ns.BuffData.Covers(buff, id), id)
                    assert.are.equal(buff, ns.BuffData.ForAura(id), id)
                    assert.is_nil(ns.BuffData.ForCast(id), id)
                    assert.is_false(ns.BuffData.CanReplace(buff, id), id)
                end
                -- Knowing only an effect's ID isn't knowing the spell.
                boot({ known = OTHER_WATER_WALKING })
                assert.is_false(ns.BuffData.IsKnown(ns.BuffData.ByKey("waterwalking")))
                assert.is_false(ns.BuffData.Covers(ns.BuffData.ByKey("waterbreathing"), OTHER_WATER_WALKING[1]))
            end)
    end)

    describe("never offered unasked (white)", function()
        it("buff back offers a favour your other buffs, never Water Walking", function()
            boot()
            wow.swim() -- Water Breathing isn't held back
            stranger()
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            assert.are.equal("Water Breathing", (offered()))
            -- They wear it: nothing left to give, and Water Walking isn't it.
            wow.state.units.nameplate1.auras = { WATER_BREATHING }
            local spell, _, why = offered()
            assert.is_nil(spell)
            assert.are.equal("Bob Stone: they already have your buffs", why)
        end)

        it("buff back with Water Walking the only buff you know offers nothing to a favour", function()
            boot({ known = { WATER_WALKING } })
            stranger()
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            local spell, _, why = offered()
            assert.is_nil(spell)
            assert.are.equal("Bob Stone: you know no buffs to give", why)
            assert.are.same({}, ns.BuffData.Offerable())
            assert.are.same({ "waterwalking" }, { ns.BuffData.Requestable()[1].key })
        end)

        it("a favour whose player also asked for it gets Water Walking: they asked", function()
            boot()
            stranger()
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            wow.whisper("ww pls", "Bob-Stone")
            assert.are.equal("Water Walking", (offered()))
        end)

        it("buff mode never casts it on your group, in water or out", function()
            boot({ known = { WATER_WALKING } })
            wow.setGroup("party", { "Ann-Vale" })
            wow.state.units.party1.class = "WARRIOR"
            slash("buffmode on")
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            wow.swim()
            ns.BuffButton.Refresh()
            wow.pressKey("MOUSEWHEELUP")
            wow.advance(30)
            wow.pressKey("MOUSEWHEELUP")
            for _, cast in ipairs(wow.casts) do
                assert.are_not.equal("Water Walking", cast.spell)
            end
            assert.are.same({}, offeredKeys())
        end)

        it("a raid's buff split never shares it, even when a copy says it gives it", function()
            -- Two shamans' copies in a raid, both knowing both buffs, buff mode on.
            local clients = {}
            for _, p in ipairs({ { "Ann", "Vale" }, { "Bob", "Lake" } }) do
                local c = wow.newClient({ name = p[1], surname = p[2], before = function(state)
                    state.class = "SHAMAN"
                    state.knownSpells = { [WATER_WALKING] = true, [WATER_BREATHING] = true }
                end })
                c.ns.BuffMode.Set(true)
                clients[#clients + 1] = c
            end
            local net = wow.network(clients)
            for i, c in ipairs(clients) do
                wow.use(c)
                local other = clients[3 - i]
                wow.setGroup("raid", { other.full })
                wow.state.units.raid1.class = "SHAMAN"
                wow.addUnit("raid2", { name = c.name, surname = c.surname, id = c.full, class = "SHAMAN" })
                wow.fire("GROUP_ROSTER_UPDATE")
            end
            wow.advanceAll(net, 30, 0.5)
            local ann = clients[1]
            wow.use(ann)
            local mine, shares = ann.ns.RaidSplit.Current()
            assert.is_truthy(mine, "a split: " .. tostring(shares))
            -- Bob's copy says it gives Water Walking: it's no buff the split shares.
            ann.ns.RaidSplit.OnShare("Bob-Lake", "waterwalking,waterbreathing", "", false)
            mine, shares = ann.ns.RaidSplit.Current()
            assert.is_truthy(mine)
            for name, share in pairs(shares) do
                assert.is_nil(share.waterwalking, name .. " is given Water Walking")
            end
            assert.is_nil(mine.waterwalking)
            assert.is_false(ann.ns.RaidSplit.Covers(ann.ns.BuffData.ByKey("waterwalking")))
        end)
    end)

    describe("a wrong or unknown ID fails safe (black)", function()
        -- Asked for by name, and by the client's own name of spell 546.
        local function asked(text)
            stranger()
            wow.whisper(text, "Bob-Stone")
            return offered()
        end

        it("spell 546 named otherwise by the client: not known, never offered or cast, \"(not known yet)\"",
            function()
                wow.SPELL_NAMES[WATER_WALKING] = "Earth Shock"
                boot()
                local buff = ns.BuffData.ByKey("waterwalking")
                assert.is_false(ns.BuffData.IsKnown(buff))
                assert.is_nil(ns.BuffData.SpellName(buff))
                assert.is_nil(ns.BuffData.CastName(buff))
                for _, text in ipairs({ "ww", "water walking", "walk on water", "earth shock" }) do
                    assert.is_nil(asked(text), text)
                end
                wow.press(button)
                assert.are.same({}, wow.casts)
                local w = ns.Options.widgets
                wow.run(w.tabs.buffs, "OnClick")
                local shown
                for _, r in ipairs(w.buffRows) do
                    if r.key == "waterwalking" then shown = r.name:GetText() end
                end
                assert.is_truthy(shown and shown:find("(not known yet)", 1, true), shown)
                assert.is_falsy(shown:find("Earth Shock", 1, true), "the other spell's name is never shown")
            end)

        it("spell 546 named otherwise: a Water Walking they wear isn't one yours can replace", function()
            wow.SPELL_NAMES[WATER_WALKING] = "Earth Shock"
            boot()
            assert.is_false(ns.BuffData.CanReplace(ns.BuffData.ByKey("waterwalking"), WATER_WALKING))
            wow.SPELL_NAMES[WATER_WALKING] = "Water Walking"
            boot()
            assert.is_true(ns.BuffData.CanReplace(ns.BuffData.ByKey("waterwalking"), WATER_WALKING))
        end)

        it("an empty name from the client is no name, for any buff", function()
            local saved131 = wow.SPELL_NAMES[WATER_BREATHING]
            wow.SPELL_NAMES[WATER_BREATHING] = ""
            boot()
            local name = ns.BuffData.SpellName(ns.BuffData.ByKey("waterbreathing"))
            wow.SPELL_NAMES[WATER_BREATHING] = saved131
            assert.is_nil(name)
        end)

        it("a class the game won't say isn't remembered: your buffs are found once it can be read", function()
            boot()
            local class = wow.state.class
            wow.state.class = wow.secret(class)
            ns.BuffData.SpellsChanged()
            assert.are.same({}, ns.BuffData.Requestable())
            wow.state.class = class
            assert.are.equal("waterwalking", ns.BuffData.Requestable()[2].key)
        end)

        it("spell 546 the client can't name, or names in an unreadable way: never offered", function()
            for _, name in ipairs({ false, "", wow.secret("Water Walking") }) do
                wow.SPELL_NAMES[WATER_WALKING] = name or nil
                boot()
                assert.is_false(ns.BuffData.IsKnown(ns.BuffData.ByKey("waterwalking")), tostring(name))
                assert.is_nil(asked("ww"), tostring(name))
            end
        end)

        it("a shaman who hasn't learned it: \"ww\" queues nobody, and the tab says \"(not known yet)\"", function()
            boot({ known = { WATER_BREATHING } })
            assert.is_nil(asked("ww pls"))
            assert.is_nil(asked("walk on water"))
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            for _, r in ipairs(w.buffRows) do
                if r.key == "waterwalking" then
                    assert.is_truthy(r.name:GetText():find("(not known yet)", 1, true))
                end
            end
        end)

        it("another class (a warlock, a druid) is never asked for it, even knowing spell 546", function()
            for _, class in ipairs({ "WARLOCK", "DRUID" }) do
                boot({ class = class, known = { WATER_WALKING } })
                assert.is_nil(asked("ww"), class)
                assert.is_nil(asked("water walking"), class)
            end
        end)

        it("anything around the name, or a near miss, queues nobody", function()
            boot()
            for _, text in ipairs({ "ww2", "www", "w w", "wwpls", "ww |cffff0000x", "walk on water now",
                "water walk", "waterwalking", "ww ww", "ww " .. string.rep("pls ", 20) }) do
                assert.is_nil(asked(text), text)
            end
        end)

        it("with requests off, \"ww\" queues nobody", function()
            boot({ requests = false })
            assert.is_nil(asked("ww pls"))
        end)
    end)

    describe("a storm (red)", function()
        -- The texts the storm whispers, and which of them ask for Water Walking.
        local TEXTS = { "ww", "ww pls", "water walking", "walk on water", "WATER WALKING", "ww?!",
            "wb", "x", "ww 7", "wwpls" }
        local ASKS_WW = { ["ww"] = true, ["ww pls"] = true, ["water walking"] = true, ["walk on water"] = true,
            ["WATER WALKING"] = true, ["ww?!"] = true }
        local PLAYERS = { { "Bob", "Stone" }, { "Ann", "Vale" }, { "Cid", "Rock" } }
        local function pick(list) return list[random.random(#list)] end
        -- Each reaches a Water Walking offer to a player who asked, a cast of
        -- it, and a press while 546 is renamed or unknown with a player
        -- waiting (the storm counts and checks all three).
        local STORM_SEEDS = { 3, 17, 41, 77, 350 }

        it("random requests, favours, renamed spells and spellbook changes never error, never cast anything "
            .. "but Water Walking by its name, and never offer it unasked", function()
            for _, seed in ipairs(STORM_SEEDS) do
                random.seed(seed)
                -- Each seed starts from the real name: one seed's rename mustn't reach the next.
                wow.SPELL_NAMES[WATER_WALKING] = "Water Walking"
                boot()
                -- Who has asked for Water Walking, readably: the client's own record.
                local askedWW = {}
                -- What the seed reaches, counted so a seed that stops reaching it fails.
                local reached = { offers = 0, casts = 0, unnamedPresses = 0 }
                for step = 1, 150 do
                    local r = random.random(100)
                    local p = pick(PLAYERS)
                    local who = p[1] .. "-" .. p[2]
                    if r <= 30 then
                        wow.addUnit("nameplate1", { name = p[1], surname = p[2], id = who, class = "WARRIOR" })
                        local text = pick(TEXTS)
                        if random.random(10) == 1 then
                            wow.whisper(text, wow.secret(who))
                        else
                            wow.whisper(text, who)
                            if ASKS_WW[text] then askedWW[who] = true end
                        end
                    elseif r <= 45 then
                        wow.addUnit("nameplate1", { name = p[1], surname = p[2], id = who, class = "MAGE" })
                        wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
                    elseif r <= 55 then
                        wow.SPELL_NAMES[WATER_WALKING] = pick({ "Water Walking", "Earth Shock", "Water Walking" })
                        ns.BuffData.SpellsChanged()
                    elseif r <= 65 then
                        wow.state.knownSpells[WATER_WALKING] = random.random(10) <= 7 or nil
                        ns.BuffData.SpellsChanged()
                    elseif r <= 75 then
                        local named = wow.SPELL_NAMES[WATER_WALKING] == "Water Walking"
                            and wow.state.knownSpells[WATER_WALKING] == true
                        if not named and next(askedWW) then reached.unnamedPresses = reached.unnamedPresses + 1 end
                        wow.press(button)
                    elseif r <= 85 then
                        if wow.inWater() then wow.leaveWater() else wow.swim() end
                    else
                        wow.advance(random.random(90))
                    end
                    local where = ("seed %d step %d"):format(seed, step)
                    local list = {}
                    ns.Offers.Current(list)
                    for _, offer in ipairs(list) do
                        if offer.buff.key == "waterwalking" then
                            reached.offers = reached.offers + 1
                            assert.is_true(askedWW[offer.name], where .. ": offered only to a player who asked")
                            assert.are.equal("Water Walking", wow.SPELL_NAMES[WATER_WALKING], where)
                            assert.is_true(wow.state.knownSpells[WATER_WALKING], where)
                            assert.are.equal("Water Walking", offer.spell, where)
                        end
                    end
                    for _, cast in ipairs(wow.casts) do
                        assert.are_not.equal("Earth Shock", cast.spell, where .. ": never another spell")
                        if cast.spell == "Water Walking" and not cast.counted then
                            cast.counted = true
                            reached.casts = reached.casts + 1
                        end
                        if cast.spell == "Water Walking" then
                            assert.is_true(askedWW[cast.target], where .. ": cast only for a player who asked")
                        end
                    end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
                for what, n in pairs(reached) do
                    assert.is_true(n > 0, ("seed %d reaches no %s"):format(seed, what))
                end
            end
        end)
    end)
end)
