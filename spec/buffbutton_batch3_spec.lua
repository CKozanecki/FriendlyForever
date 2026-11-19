-- Spec: #483, #484, #485, #491
-- The 1.4.4 buff button batch (the owner's 1.4.3 play-test, 18 Nov):
-- #483: a refusal about you (no mana, combat, a form, silence, a text that
-- can't be read or isn't known) holds nobody; a press in the global cooldown
-- isn't a refusal at all; only a refusal about the target (too low level,
-- out of range, out of sight, not a valid target) holds them for #459's
-- time. Passers-by, party, raid and self-buffs alike.
-- #484: in a resting area, passers-by never turn buff mode on or keep it on;
-- turned off by hand, they don't turn it back on until you change zone.
-- #485: Moonkin Form doesn't hold buff mode's key; buff mode's chat line in
-- a form the key waits for says to click.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, THORNS = 9885, 9910
local INNER_FIRE = 10952
local INTELLECT = 10157
local LOS, LOW, RANGE = "Target not in line of sight", "Target is too low level", "Out of range."
local GCD = "Spell is not ready yet."
-- Refusals about the target, and about you (or not known to be about them).
local ABOUT_THEM = { LOS, LOW, RANGE, "Invalid target.", "A more powerful spell is already active." }
local ABOUT_YOU = { "Not enough mana", "Not enough rage", "You are in combat.", "Can't do that while silenced.",
    "You can't do that while shapeshifted.", "Interrupted", "Something nobody has seen before" }

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("The buff button batch (1.4.4)", function()
    local ns, button

    -- A druid (opts.class: another) who knows Mark of the Wild and Thorns
    -- (opts.known: others), with passers-by on, in buff mode unless
    -- opts.noMode. opts.auto keeps the turn-on triggers; opts.buffSelf
    -- offers your own copy of your buffs.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, buffSelf = opts.buffSelf, autoBuffMode = opts.auto, before = function(state)
            state.class = opts.class or "DRUID"
            state.knownSpells = {}
            for _, id in ipairs(opts.known or { MOTW, THORNS }) do state.knownSpells[id] = true end
            if opts.before then opts.before(state) end
        end })
        button = ns.BuffButton.Frame()
        ns.db.buffBack.passersBy = opts.passersBy ~= false
        if opts.auto then
            for _, field in ipairs(wow.TURN_ON_TRIGGERS) do ns.db.buffBack[field] = opts[field] == true end
        end
        if not opts.noMode then slash("buffmode on") end
    end

    -- A stranger on a nameplate, a warrior unless spec says.
    local function stranger(token, name, surname, spec)
        spec = spec or {}
        spec.name, spec.surname, spec.id = name, surname, name .. "-" .. surname
        spec.class = spec.class or "WARRIOR"
        spec.auras = spec.auras or {}
        wow.addUnit(token, spec)
        return wow.state.units[token]
    end

    local function party(names)
        wow.setGroup("party", names)
        wow.fire("GROUP_ROSTER_UPDATE")
    end

    -- A fresh look, passers-by included (a look is otherwise kept a second).
    local function refresh()
        ns.PassersBy.Fresh()
        ns.BuffButton.Refresh()
    end
    local function title() return button.title:GetText() end
    local function subtitle() return button.subtitle:GetText() or "" end
    local function result() return button.result:GetText() or "" end

    -- Press the button once: the cast it made, or nil.
    local function press()
        local before = #wow.casts
        wow.press(button)
        return wow.casts[before + 1]
    end

    -- Chat lines said since `from` (an index into wow.printed) that hold text.
    local function saidSince(from, text)
        local n = 0
        for i = from + 1, #wow.printed do
            if wow.printed[i]:find(text, 1, true) then n = n + 1 end
        end
        return n
    end

    describe("#483: a refusal about you holds nobody", function()
        it("\"Not enough mana\" puts no passer-by on the hold, and the next press offers the same one (white)", function()
            boot()
            stranger("nameplate1", "Bob", "Stone")
            stranger("nameplate2", "Cid", "Rock")
            -- Out of mana: the game refuses every cast, whoever it's for.
            wow.state.unusable["Mark of the Wild"] = "power"
            refresh()
            assert.are.equal("Bob Stone", title())
            local cast = press()
            assert.are.same({ "Bob-Stone", "Not enough mana" }, { cast.target, cast.failed })
            assert.matches("Couldn't buff Bob Stone: Not enough mana", result(), 1, true)
            refresh()
            assert.are.equal("Bob Stone", title(), "Bob isn't held: the refusal was about you")
            assert.matches("Not enough mana", result(), 1, true, "the button still shows why")
            assert.are.equal("Bob-Stone", press().target, "the next press offers Bob again")
            -- The mana comes back: Bob gets his buff.
            wow.state.unusable = {}
            refresh()
            cast = press()
            assert.are.same({ "Bob-Stone", "Mark of the Wild" }, { cast.target, cast.spell })
            assert.is_nil(cast.failed)
            assert.are.same({}, wow.errors)
        end)

        it("held down, a refusal about you is said in chat once, not at every press (white)", function()
            boot()
            stranger("nameplate1", "Bob", "Stone")
            wow.state.unusable["Mark of the Wild"] = "power"
            local from = #wow.printed
            for _ = 1, 6 do
                press()
                wow.advance(0.2)
            end
            assert.are.equal(1, saidSince(from, "Couldn't buff Bob Stone: Not enough mana"))
            -- Once the line under the button has gone, it's said again.
            wow.advance(ns.BuffButton.RESULT_SHOWN_SECONDS + 1)
            press()
            assert.are.equal(2, saidSince(from, "Couldn't buff Bob Stone: Not enough mana"))
            -- Another refusal at once is a new line: it's said.
            wow.state.unusable = {}
            wow.state.castFailures["Bob-Stone"] = LOS
            wow.advance(0.2)
            press()
            assert.are.equal(1, saidSince(from, "Couldn't buff Bob Stone: " .. LOS))
        end)

        it("every refusal about you leaves a passer-by, a party member and a favour where they were (white)", function()
            for _, text in ipairs(ABOUT_YOU) do
                -- A passer-by.
                boot()
                stranger("nameplate1", "Bob", "Stone")
                stranger("nameplate2", "Cid", "Rock")
                wow.state.castFailures["Bob-Stone"] = text
                assert.are.equal("Bob-Stone", press().target)
                refresh()
                assert.are.equal("Bob Stone", title(), text)
                -- A party member.
                boot()
                party({ "Ann-Vale", "Dee-Moss" })
                refresh()
                wow.state.castFailures["Ann-Vale"] = text
                assert.are.equal("Ann-Vale", press().target, text)
                refresh()
                assert.are.equal("Ann Vale", title(), text)
                assert.are.equal("Ann-Vale", press().target, text)
                -- A favour: Bob buffed you.
                boot()
                stranger("nameplate1", "Bob", "Stone")
                wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
                assert.are.equal(1, ns.Offers.Count())
                wow.state.castFailures["Bob-Stone"] = text
                assert.are.equal("Bob-Stone", press().target, text)
                refresh()
                assert.are.equal("Bob Stone", title(), text)
                assert.are.same({}, wow.errors, text)
            end
        end)

        it("a self-buff refused for a reason about you is offered again at the next press (white)", function()
            for _, text in ipairs(ABOUT_YOU) do
                boot({ class = "PRIEST", known = { INNER_FIRE } })
                ns.db.buffBack.selfBuffs = true
                refresh()
                assert.are.equal("Inner Fire", (ns.BuffButton.ArmedOffer() or {}).spell, text)
                wow.state.castFailures[wow.state.units.player.id] = text
                assert.are.equal("Inner Fire", press().spell, text)
                refresh()
                assert.are.equal("Inner Fire", (ns.BuffButton.ArmedOffer() or {}).spell, text)
                assert.is_nil(subtitle():find("the game refused your last", 1, true), text)
            end
        end)

        it("a press in the global cooldown is no refusal: no hold, no line, nothing in chat (white)", function()
            boot()
            stranger("nameplate1", "Bob", "Stone")
            stranger("nameplate2", "Cid", "Rock")
            wow.state.castFailures["Bob-Stone"] = GCD
            local from = #wow.printed
            assert.are.equal("Bob-Stone", press().target)
            refresh()
            assert.are.equal("Bob Stone", title(), "Bob isn't held")
            assert.are.equal("", result(), "nothing under the button")
            assert.are.equal(0, saidSince(from, "Couldn't buff"))
            -- Its "not ready" text without the stop, and the ability one, are the same.
            for _, text in ipairs({ "Spell is not ready yet", "Ability is not ready yet." }) do
                wow.state.castFailures["Bob-Stone"] = text
                assert.are.equal("Bob-Stone", press().target, text)
                refresh()
                assert.are.equal("Bob Stone", title(), text)
            end
            assert.are.equal(0, saidSince(from, "Couldn't buff"))
            wow.state.castFailures["Bob-Stone"] = nil
            local cast = press()
            assert.are.same({ "Bob-Stone", "Mark of the Wild" }, { cast.target, cast.spell })
            assert.is_nil(cast.failed)
        end)

        it("a party member and a self-buff in the global cooldown aren't held either (white)", function()
            boot()
            party({ "Ann-Vale", "Dee-Moss" })
            refresh()
            wow.state.castFailures["Ann-Vale"] = GCD
            assert.are.equal("Ann-Vale", press().target)
            refresh()
            assert.are.equal("Ann Vale", title())
            boot({ class = "PRIEST", known = { INNER_FIRE } })
            ns.db.buffBack.selfBuffs = true
            wow.state.castFailures[wow.state.units.player.id] = GCD
            assert.are.equal("Inner Fire", press().spell)
            refresh()
            assert.are.equal("Inner Fire", (ns.BuffButton.ArmedOffer() or {}).spell)
        end)
    end)

    describe("#483: a refusal about the target still holds them (#459)", function()
        it("the hold is #459's 15 seconds, for passers-by, group members, favours and self-buffs (white)", function()
            boot()
            assert.are.same({ 15, 15, 15, 15 }, { ns.PassersBy.HELD_BACK_SECONDS, ns.GroupBuffs.HELD_BACK_SECONDS,
                ns.Offers.HELD_BACK_SECONDS, ns.SelfBuffs.HELD_BACK_SECONDS })
        end)

        it("too low level, out of range, out of sight, not a valid target: the passer-by waits its time (white)",
            function()
                for _, text in ipairs(ABOUT_THEM) do
                    boot()
                    stranger("nameplate1", "Bob", "Stone")
                    stranger("nameplate2", "Cid", "Rock")
                    wow.state.castFailures["Bob-Stone"] = text
                    assert.are.equal("Bob-Stone", press().target, text)
                    refresh()
                    assert.are.equal("Cid Rock", title(), text .. ": Bob waits")
                    assert.are.equal("Cid-Rock", press().target, text)
                    wow.state.castFailures["Bob-Stone"] = nil
                    wow.advance(14) -- #459's 15 seconds, less one
                    refresh()
                    assert.are_not.equal("Bob Stone", title(), text .. ": still within the hold")
                    wow.advance(2)
                    refresh()
                    assert.are.equal("Bob Stone", title(), text .. ": the hold is over")
                end
            end)

        it("a party member, a favour and a self-buff refused for a reason about them wait too (white)", function()
            for _, text in ipairs(ABOUT_THEM) do
                boot()
                party({ "Ann-Vale", "Dee-Moss" })
                refresh()
                wow.state.castFailures["Ann-Vale"] = text
                assert.are.equal("Ann-Vale", press().target, text)
                refresh()
                assert.are.equal("Dee Moss", title(), text)
                -- A favour.
                boot()
                stranger("nameplate1", "Bob", "Stone")
                wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
                wow.state.castFailures["Bob-Stone"] = text
                assert.are.equal("Bob-Stone", press().target, text)
                ns.BuffButton.Refresh()
                assert.matches("the game refused your last cast to them", subtitle(), 1, true, text)
            end
            -- A self-buff a stronger copy blocks.
            boot({ class = "PRIEST", known = { INNER_FIRE } })
            ns.db.buffBack.selfBuffs = true
            wow.state.castFailures[wow.state.units.player.id] = "A more powerful spell is already active."
            assert.are.equal("Inner Fire", press().spell)
            refresh()
            assert.matches("the game refused your last Inner Fire", subtitle(), 1, true)
        end)

        it("is read whatever its case, spaces or end stop; anything else, or nothing readable, is about you (black)",
            function()
                boot()
                local kind = ns.BuffButton.RefusalKind
                assert.are.equal("target", kind("  Out of range.  "))
                assert.are.equal("target", kind("TARGET NOT IN LINE OF SIGHT"))
                assert.are.equal("target", kind("Target is too low level."))
                assert.are.equal("cooldown", kind("Spell is not ready yet"))
                assert.are.equal("cooldown", kind("spell is not ready yet!"))
                for _, junk in ipairs({ "", "Out of range, almost", "Not enough mana", "out of", "range" }) do
                    assert.are.equal("you", kind(junk), junk)
                end
                for _, unreadable in ipairs({ 42, true, {}, wow.secret(LOS), wow.secret(GCD) }) do
                    assert.are.equal("you", kind(unreadable), tostring(unreadable))
                end
                assert.are.equal("you", kind(nil))
            end)

        it("a refusal text that can't be read holds nobody, and the button says why (black)", function()
            boot()
            stranger("nameplate1", "Bob", "Stone")
            stranger("nameplate2", "Cid", "Rock")
            -- The game's text comes as a secret: the press waits for an answer, and gets none.
            wow.state.castFailures["Bob-Stone"] = wow.secret(LOS)
            assert.are.equal("Bob-Stone", press().target)
            wow.advance(ns.BuffButton.SENT_ANSWER_SECONDS + 1)
            assert.matches("Couldn't buff Bob Stone (the game gave no reason).", wow.lastResult(ns), 1, true)
            refresh()
            assert.are.equal("Bob Stone", title(), "Bob isn't held")
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("#483: a storm of presses and refusals (red)", function()
        it("chaos: a refusal about you never moves the button on, nobody is held without a refusal about them, "
            .. "and the list is never walked in a second", function()
            local names = { { "Bob", "Stone" }, { "Cid", "Rock" }, { "Dee", "Moss" }, { "Eve", "Lark" } }
            local HOLD
            -- The spec's own reading of the texts, kept apart from the code's.
            local targetText = {}
            for _, text in ipairs(ABOUT_THEM) do targetText[text] = true end
            local texts = { GCD, "Ability is not ready yet.", "Not enough mana", "You are in combat.",
                "Something nobody has seen before", LOS, LOW, RANGE, "Invalid target." }
            local seen = { you = 0, them = 0, unreadable = 0, landed = 0 }
            for seed = 1, 10 do
                random.seed(seed)
                boot()
                HOLD = ns.PassersBy.HELD_BACK_SECONDS
                for i, n in ipairs(names) do stranger("nameplate" .. i, n[1], n[2]) end
                local refusedAt = {} -- [target] = when the game last refused them for a reason about them
                local log = {}       -- { at, target, kind = "you", "them" or "landed" } for each cast
                -- Note a cast: the hold it starts, the buff it put up, the kind of answer.
                local function note(cast, where)
                    local failed = cast.failed
                    local kind
                    if failed == nil then
                        kind = "landed"
                        seen.landed = seen.landed + 1
                        -- The game shows the buff on them a moment later.
                        for i = 1, #names do
                            local token = "nameplate" .. i
                            if wow.state.units[token].id == cast.target then
                                wow.wearBuff(token, cast.id, { source = "player" })
                            end
                        end
                    elseif type(failed) == "string" and targetText[failed] then
                        kind = "them"
                        seen.them = seen.them + 1
                    else
                        kind = "you"
                        if type(failed) == "table" then seen.unreadable = seen.unreadable + 1
                        else seen.you = seen.you + 1 end
                    end
                    -- Nobody refused for a reason about them is offered within their hold.
                    local at = refusedAt[cast.target]
                    assert.is_false(at ~= nil and wow.now - at < HOLD - 0.01,
                        where .. ": " .. cast.target .. " cast at while held")
                    if kind == "them" then refusedAt[cast.target] = wow.now end
                    log[#log + 1] = { at = wow.now, target = cast.target, kind = kind }
                    return kind
                end
                for step = 1, 70 do
                    local where = ("seed %d, step %d"):format(seed, step)
                    local roll = random.random(1, 10)
                    if roll <= 2 then
                        local who = names[random.random(1, #names)]
                        local pick = random.random(1, #texts + 2)
                        local text = texts[pick]
                        if pick == #texts + 1 then text = wow.secret(LOS) end -- unreadable
                        wow.state.castFailures[who[1] .. "-" .. who[2]] = text
                    elseif roll == 3 then
                        wow.state.unusable["Mark of the Wild"] = wow.state.unusable["Mark of the Wild"] == nil
                            and "power" or nil
                    elseif roll == 4 then
                        wow.advance(random.random(1, 20) / 4)
                    elseif roll == 5 then
                        -- Much later, everyone has lost their buffs: work again.
                        wow.advance(ns.PassersBy.SKIP_SECONDS + 1)
                        for i = 1, #names do wow.state.units["nameplate" .. i].auras = {} end
                    else
                        local cast = press()
                        if cast and note(cast, where) == "you" then
                            -- At once, with nothing else changed, the next press goes to the same player.
                            local again = press()
                            assert.is_truthy(again, where .. ": the button emptied after a refusal about you")
                            assert.are.equal(cast.target, again.target,
                                where .. ": a refusal about you moved the button on")
                            note(again, where)
                        end
                    end
                    refresh()
                end
                -- Refusals about you never walk the list: two within a second
                -- go to one player, unless something about the players moved
                -- the button between them (a refusal about them, a buff that
                -- landed, a hold that ended).
                for i, a in ipairs(log) do
                    if a.kind == "you" then
                        local moved = false
                        for j = i + 1, #log do
                            local b = log[j]
                            if b.at - a.at >= 1 then break end
                            moved = moved or b.kind ~= "you"
                            for _, r in ipairs(log) do
                                if r.kind == "them" and r.at + HOLD > a.at and r.at + HOLD <= b.at + 0.01 then
                                    moved = true
                                end
                            end
                            if b.kind == "you" and not moved then
                                assert.are.equal(a.target, b.target,
                                    ("seed %d: refusals about you went to %s and %s in a second"):format(
                                        seed, a.target, b.target))
                            end
                        end
                    end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
            -- The storm met every kind.
            for kind, n in pairs(seen) do assert.is_true(n > 0, kind .. " never happened") end
        end)
    end)

    describe("#484: passers-by in a resting area", function()
        -- Your Thorns, worn until now, goes missing: the missing-buff trigger
        -- turns buff mode on (solo, your own buffs, #426).
        local function bootMissing(opts)
            opts = opts or {}
            boot({ auto = true, noMode = true, buffSelf = true, autoOnMissing = true, autoOnCampfire = true,
                before = opts.before })
            ns.db.buffBack.soloOwnBuffs = true
            for _, id in ipairs({ MOTW, THORNS }) do
                wow.state.playerAuras[#wow.state.playerAuras + 1] = { isHelpful = true, spellId = id,
                    sourceUnit = "player", duration = 1800, expirationTime = wow.now + 1800,
                    auraInstanceID = 900000 + id }
            end
            wow.advance(ns.BuffModeAuto.WATCH_SECONDS + 1)
            for i = #wow.state.playerAuras, 1, -1 do
                if wow.state.playerAuras[i].spellId == THORNS then table.remove(wow.state.playerAuras, i) end
            end
            wow.advance(ns.BuffModeAuto.WATCH_SECONDS + 1)
            assert.is_true(ns.BuffMode.IsAuto(), "your missing Thorns turned buff mode on")
        end

        -- Your Thorns back on: only Bob, passing by, is left.
        local function castThorns()
            local cast = press()
            assert.are.same({ "Thorns", wow.state.units.player.id }, { cast.spell, cast.target })
            wow.gainBuff({ spellId = THORNS, sourceUnit = "player", duration = 1800 })
            refresh()
        end

        it("resting: once nothing else needs it, buff mode turns off though a passer-by waits (white)", function()
            bootMissing()
            wow.rest(true)
            stranger("nameplate1", "Bob", "Stone")
            castThorns()
            assert.is_false(ns.BuffMode.IsOn(), "Bob passing by doesn't keep it on in a resting area")
        end)

        it("out of resting areas, a passer-by still keeps it on, as #462 has it (white)", function()
            bootMissing()
            wow.rest(false)
            stranger("nameplate1", "Bob", "Stone")
            castThorns()
            assert.is_true(ns.BuffMode.IsAuto(), "Bob waits: buff mode stays on (#462)")
        end)

        it("resting: a passer-by is still offered while buff mode is on for something else (white)", function()
            boot()
            wow.rest(true)
            stranger("nameplate1", "Bob", "Stone")
            refresh()
            assert.are.equal("Bob Stone", title())
            local cast = press()
            assert.are.same({ "Bob-Stone", "Mark of the Wild" }, { cast.target, cast.spell })
            -- A trigger's buff mode with your own buffs still to give offers Bob after them.
            bootMissing()
            wow.rest(true)
            stranger("nameplate1", "Bob", "Stone")
            refresh()
            assert.are.equal("Thorns", (ns.BuffButton.ArmedOffer() or {}).spell)
            local list = {}
            ns.PassersBy.Next(list)
            assert.are.equal("Bob-Stone", list[1] and list[1].name, "Bob is in the list after your Thorns")
        end)

        it("resting: the campfire doesn't turn buff mode on for passers-by alone (white)", function()
            boot({ auto = true, noMode = true, autoOnCampfire = true })
            wow.rest(true)
            stranger("nameplate1", "Bob", "Stone")
            wow.gainBuff({ spellId = 1232234, name = "Cozy Fire" })
            assert.is_false(ns.BuffMode.IsOn())
            -- Out of a resting area, the same fire does (#39).
            boot({ auto = true, noMode = true, autoOnCampfire = true })
            stranger("nameplate1", "Bob", "Stone")
            wow.gainBuff({ spellId = 1232234, name = "Cozy Fire" })
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("an IsResting() that can't be read counts as resting (black)", function()
            -- A secret.
            bootMissing({ before = function(state) state.restingSecret = true end })
            stranger("nameplate1", "Bob", "Stone")
            castThorns()
            assert.is_false(ns.BuffMode.IsOn(), "a secret answer: resting")
            -- An error, and no function at all.
            for _, broken in ipairs({ function() error("no") end, false }) do
                bootMissing()
                _G.IsResting = broken or nil
                stranger("nameplate1", "Bob", "Stone")
                castThorns()
                assert.is_false(ns.BuffMode.IsOn(), "an unreadable answer: resting")
                assert.are.same({}, wow.errors)
            end
        end)
    end)

    describe("#484: turned off by hand, passers-by don't turn it back on until you change zone", function()
        -- At a campfire, with Bob passing by: the campfire turned buff mode on.
        local function bootFire()
            boot({ auto = true, noMode = true, autoOnCampfire = true })
            stranger("nameplate1", "Bob", "Stone")
            wow.gainBuff({ spellId = 1232234, name = "Cozy Fire" })
            assert.is_true(ns.BuffMode.IsAuto())
            slash("buffmode off")
            assert.is_false(ns.BuffMode.IsOn())
        end

        it("another campfire aura doesn't turn it back on for Bob; a new zone, or a loading screen, lets it (white)",
            function()
                for _, how in ipairs({ "zone", "loading" }) do
                    bootFire()
                    wow.gainBuff({ spellId = 1283391, name = "Campfire Nearby" })
                    refresh()
                    assert.is_false(ns.BuffMode.IsOn(), how .. ": still off, Bob still passing by")
                    if how == "zone" then
                        wow.setMap(1426)
                    else
                        wow.fire("PLAYER_ENTERING_WORLD", false, false)
                    end
                    wow.gainBuff({ spellId = 1229739, name = "Welcoming Campfire" })
                    assert.is_true(ns.BuffMode.IsAuto(), how .. ": a new zone: the campfire counts Bob again")
                end
            end)

        it("a move within the zone (a subzone, indoors) isn't a change of zone (black)", function()
            bootFire()
            wow.fire("ZONE_CHANGED")
            wow.fire("ZONE_CHANGED_INDOORS")
            wow.gainBuff({ spellId = 1283391, name = "Campfire Nearby" })
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("work of your own still turns it on, and a stranger's favour too (white)", function()
            bootFire()
            ns.db.buffBack.autoOnBuffed = true
            stranger("nameplate2", "Ann", "Vale")
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
            assert.is_true(ns.BuffMode.IsAuto(), "the favour turns it on")
        end)
    end)

    describe("#485: Moonkin Form", function()
        local CAT, BEAR, TRAVEL, AQUATIC, MOONKIN = 1, 2, 3, 4, 5
        -- A druid in a party with Ann and Dee, who lack both buffs, in buff mode.
        local function bootDruid(opts)
            opts = opts or {}
            boot({ db = opts.db, noMode = opts.noMode, class = opts.class })
            party({ "Ann-Vale", "Dee-Moss" })
            if opts.form then wow.setForm(opts.form, opts.spell) end
            wow.advance(0)
            refresh()
        end
        local A = function() return ns.BuffButton.SECURE_ATTRIBUTE end
        local function keyMacro() return button:GetAttribute(A().keyMacroText) end
        local function clickMacro() return button:GetAttribute(A().leftButtonMacroText) end
        local function scroll()
            local before = #wow.casts
            wow.pressKey("MOUSEWHEELUP")
            return wow.casts[before + 1]
        end

        it("with fast-cast off, the key casts Mark of the Wild and Thorns, and the button doesn't wait (white)",
            function()
                bootDruid({ form = MOONKIN, spell = wow.MOONKIN_FORM })
                assert.is_truthy(keyMacro())
                assert.are.equal(clickMacro(), keyMacro())
                assert.is_nil(button.mode:GetText():find("click to buff", 1, true))
                local spells = {}
                for _ = 1, 4 do
                    local cast = scroll()
                    assert.is_truthy(cast, "the key cast")
                    assert.is_nil(cast.failed)
                    spells[cast.spell] = true
                    wow.advance(0.1)
                    refresh()
                end
                assert.is_true(spells["Mark of the Wild"] and spells["Thorns"], "both buffs cast")
                assert.are.equal(MOONKIN, wow.state.form, "still in Moonkin Form")
                assert.are.equal(0, wow.formsCancelled)
                assert.is_nil(table.concat(ns.BuffButton.StatusLines(), "\n"):find("key waits", 1, true))
            end)

        it("in cat, bear, travel or aquatic form, the key still waits, as #452 has it (white)", function()
            for _, f in ipairs({ { CAT, wow.CAT_FORM }, { BEAR, wow.BEAR_FORM }, { TRAVEL, wow.TRAVEL_FORM },
                { AQUATIC, wow.AQUATIC_FORM } }) do
                bootDruid({ form = f[1], spell = f[2] })
                assert.is_nil(keyMacro(), "form " .. f[1])
                assert.matches("click to buff (you're in a form)", button.mode:GetText(), 1, true)
                assert.is_nil(scroll(), "form " .. f[1])
                assert.are.equal(f[1], wow.state.form)
            end
        end)

        it("a form answer that can't be read, or isn't known to be Moonkin, means the key waits (black)", function()
            local cases = {
                { "no spell named, no form number", function() end, nil },
                { "an unknown spell", function() wow.state.formId = false end, 99999 },
                { "both secrets", function()
                    wow.state.selfSecrets.formInfo, wow.state.selfSecrets.formId = true, true
                end, wow.MOONKIN_FORM },
                { "the info fails, no number", function()
                    wow.state.formInfoError, wow.state.formId = true, false
                end, wow.MOONKIN_FORM },
                { "Moonkin's spell, a cat's number", function() wow.state.formId = 1 end, wow.MOONKIN_FORM },
                { "a cat's spell, Moonkin's number", function() wow.state.formId = 31 end, wow.CAT_FORM },
                { "a number that isn't a number", function() wow.state.formId = 0 / 0 end, 99999 },
                { "no form API at all", function()
                    _G.GetShapeshiftFormInfo, _G.GetShapeshiftFormID = nil, nil
                end, wow.MOONKIN_FORM },
            }
            for _, case in ipairs(cases) do
                bootDruid()
                case[2]()
                wow.setForm(MOONKIN, case[3])
                refresh()
                assert.is_nil(keyMacro(), case[1])
                assert.is_nil(scroll(), case[1])
                assert.are.same({}, wow.errors, case[1])
            end
            -- The form's spell alone says Moonkin while the number can't be read, and the other way round.
            for _, case in ipairs({
                { "spell only", function() wow.state.formId = false end },
                { "number only", function() wow.state.formInfoError = true end },
                -- A secret spell says nothing (it isn't "not Moonkin"): the number decides.
                { "a secret spell, Moonkin's number", function() wow.state.selfSecrets.formInfo = true end },
            }) do
                bootDruid()
                case[2]()
                wow.setForm(MOONKIN, wow.MOONKIN_FORM)
                refresh()
                assert.is_truthy(keyMacro(), case[1])
            end
        end)

        it("Moonkin's spell on a shaman's form doesn't let the key cast in Ghost Wolf (black)", function()
            boot({ class = "SHAMAN", known = {} })
            party({ "Ann-Vale", "Dee-Moss" })
            wow.setGhostWolf(true)
            wow.state.formSpell = wow.MOONKIN_FORM
            refresh()
            if ns.BuffButton.ArmedOffer() then
                assert.is_truthy(ns.BuffButton.ArmedOffer().keyWaits)
                assert.is_nil(keyMacro())
            end
            assert.are.equal("you're in Ghost Wolf", ns.BuffButton.KeyWaits({}))
        end)

        it("buff mode's chat line in a waiting form says to click; fast-cast on, or Moonkin, names the key (white)",
            function()
                -- Cat form: click.
                bootDruid({ noMode = true, form = CAT, spell = wow.CAT_FORM })
                local from = #wow.printed
                slash("buffmode on")
                assert.are.equal(1, saidSince(from, "buff mode on: click the buff button to buff (you're in a form)."))
                assert.are.equal(0, saidSince(from, "presses the buff button"))
                assert.matches("click the button to buff (you're in a form)", ns.BuffMode.StatusLine(), 1, true)
                -- Fast-cast on: the key.
                bootDruid({ noMode = true, form = CAT, spell = wow.CAT_FORM,
                    db = { buffBack = { fastCastInForm = true } } })
                from = #wow.printed
                slash("buffmode on")
                assert.are.equal(1, saidSince(from, "buff mode on: MOUSEWHEELUP presses the buff button."))
                assert.matches("MOUSEWHEELUP presses the button", ns.BuffMode.StatusLine(), 1, true)
                -- Moonkin: the key.
                bootDruid({ noMode = true, form = MOONKIN, spell = wow.MOONKIN_FORM })
                from = #wow.printed
                slash("buffmode on")
                assert.are.equal(1, saidSince(from, "buff mode on: MOUSEWHEELUP presses the buff button."))
                -- Cat form with nothing to offer (solo, no passers-by): still click.
                boot({ noMode = true, passersBy = false })
                wow.setForm(CAT, wow.CAT_FORM)
                from = #wow.printed
                slash("buffmode on")
                assert.is_nil(ns.BuffButton.ArmedOffer())
                assert.are.equal(1, saidSince(from, "buff mode on: click the buff button to buff (you're in a form)."))
                -- Caster form, with nothing to offer: the key.
                boot({ noMode = true })
                from = #wow.printed
                slash("buffmode on")
                assert.are.equal(1, saidSince(from, "buff mode on: MOUSEWHEELUP presses the buff button."))
            end)

        it("a trigger turning buff mode on in a waiting form says to click too, with its reason (white)", function()
            boot({ auto = true, noMode = true, autoOnCampfire = true })
            wow.setForm(CAT, wow.CAT_FORM)
            stranger("nameplate1", "Bob", "Stone")
            local from = #wow.printed
            wow.gainBuff({ spellId = 1232234, name = "Cozy Fire" })
            assert.is_true(ns.BuffMode.IsAuto())
            assert.are.equal(1, saidSince(from, ": click the buff button to buff (you're in a form)."))
            assert.are.equal(1, saidSince(from, "buff mode on (you're by a campfire)"))
        end)
    end)
end)
