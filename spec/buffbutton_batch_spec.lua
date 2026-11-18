-- Spec: #461, #462
-- The 1.4.3 buff button batch (the owner's 1.4.1 play-testing):
-- #461: the button's last-result line goes as soon as the button offers a
-- different player, so a stranger's offer never sits under "Gave Thorns to you."
-- #462: with passers-by on, a passer-by the button offers counts as work left,
-- so buff mode turned on by any trigger stays on while one waits; the pull and
-- the timeout still end it, and passers-by never turn it on by themselves.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, THORNS = 9885, 9910
local INTELLECT = 10157

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("The buff button batch (1.4.3)", function()
    local ns, button

    -- A druid who knows Mark of the Wild and Thorns, out in the world, with
    -- passers-by on (opts.off: off), solo buff mode offering your own buffs.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ buffSelf = true, autoBuffMode = opts.auto, before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW] = true, [THORNS] = true }
        end })
        button = ns.BuffButton.Frame()
        ns.db.buffBack.passersBy = opts.off ~= true
        ns.db.buffBack.soloOwnBuffs = true
        if opts.auto then
            -- Only the missing-buff and buffed-by-a-stranger triggers here.
            for _, field in ipairs(wow.TURN_ON_TRIGGERS) do ns.db.buffBack[field] = false end
            ns.db.buffBack.autoOnMissing = true
            ns.db.buffBack.autoOnBuffed = true
        else
            slash("buffmode on")
        end
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

    -- You wear both your buffs, cast by you.
    local function wearMine()
        for _, id in ipairs({ MOTW, THORNS }) do
            wow.state.playerAuras[#wow.state.playerAuras + 1] = { isHelpful = true, spellId = id,
                sourceUnit = "player", duration = 1800, expirationTime = wow.now + 1800,
                auraInstanceID = 900000 + id }
        end
    end

    local function result() return button.result:GetText() end
    -- A fresh look, passers-by included (a look is otherwise kept a second).
    local function refresh()
        ns.PassersBy.Fresh()
        ns.BuffButton.Refresh()
    end
    -- Your Thorns, worn until now, goes missing: the missing-buff trigger
    -- notices it at its next look (a buff missing from the start is only noted).
    local function loseThorns()
        wearMine()
        wow.advance(ns.BuffModeAuto.WATCH_SECONDS + 1)
        for i = #wow.state.playerAuras, 1, -1 do
            if wow.state.playerAuras[i].spellId == THORNS then table.remove(wow.state.playerAuras, i) end
        end
        wow.advance(ns.BuffModeAuto.WATCH_SECONDS + 1)
    end
    local function title() return button.title:GetText() end
    local function lastCast() return wow.casts[#wow.casts] end

    -- Press the button, and let a buff that landed show on whoever it
    -- reached, as the game does a moment later (the simulated client leaves
    -- that to the spec for a buff for others).
    local function press()
        local before = #wow.casts
        wow.press(button)
        local cast = wow.casts[before + 1]
        if not cast or cast.failed then return cast end
        if cast.target == wow.state.units.player.id then
            wow.gainBuff({ spellId = cast.id, sourceUnit = "player", duration = 1800 })
        else
            for token, u in pairs(wow.state.units) do
                if u.id == cast.target and token:find("^nameplate") then
                    wow.wearBuff(token, cast.id, { source = "player" })
                end
            end
        end
        return cast
    end

    describe("#461: the last result goes when the button moves to another player", function()
        it("your own Thorns, then a passer-by: \"Gave Thorns to you.\" goes as the stranger shows (white)", function()
            boot()
            -- You lack only Thorns; Bob, passing by, lacks Mark of the Wild.
            wow.state.playerAuras[1] = { isHelpful = true, spellId = MOTW, sourceUnit = "player",
                duration = 1800, expirationTime = wow.now + 1800, auraInstanceID = 1 }
            stranger("nameplate1", "Bob", "Stone", { auras = { THORNS }, auraSources = { false } })
            refresh()
            assert.are.equal("You", title())
            press()
            assert.are.same({ "Thorns", wow.state.units.player.id }, { lastCast().spell, lastCast().target })
            refresh()
            assert.are.equal("Bob Stone", title(), "the next offer is Bob's")
            assert.are.equal("", result(), "the result about you is gone the moment Bob shows (the owner's case)")
            assert.are.equal(0, #wow.errors)
        end)

        it("stays while the button still offers the same player, and while it's empty (white)", function()
            boot()
            wearMine()
            stranger("nameplate1", "Bob", "Stone")
            press()
            assert.are.same({ "Mark of the Wild", "Bob-Stone" }, { lastCast().spell, lastCast().target })
            refresh()
            assert.are.equal("Bob Stone", title(), "Bob's Thorns next")
            assert.are.equal("Gave Mark of the Wild to Bob Stone (passing by).", result(), "about Bob, who is still shown")
            press()
            refresh()
            assert.are.equal("Gave Thorns to Bob Stone (passing by).", result(),
                "nobody else is offered: the button stays up for its result")
        end)

        it("a right-click's line stays until it times out, wherever the button moves (the owner, #461, white)",
            function()
            boot()
            wearMine()
            stranger("nameplate1", "Bob", "Stone")
            stranger("nameplate2", "Cid", "Rock")
            refresh()
            assert.are.equal("Bob Stone", title())
            wow.press(button, "RightButton")
            refresh()
            assert.are.equal("Cid Rock", title())
            assert.are.equal("Skipping Bob Stone for 10 minutes.", result(), "it stays under Cid's offer")
            wow.advance(ns.BuffButton.RESULT_SHOWN_SECONDS + 1)
            refresh()
            assert.are.equal("", result(), "and goes at its time")
        end)

        it("a refusal's line about a player goes when the button moves on (black)", function()
            boot()
            wearMine()
            stranger("nameplate1", "Bob", "Stone")
            stranger("nameplate2", "Cid", "Rock")
            wow.state.castFailures["Bob-Stone"] = "Spell is not ready yet."
            press()
            refresh()
            assert.are.equal("Cid Rock", title(), "Bob waits after the refusal (#459)")
            assert.are.equal("", result())
        end)

        it("chaos: whenever a press's result shows under an offer, it's about the player offered (red)", function()
            for seed = 1, 6 do
                random.seed(seed)
                boot()
                local names = { { "Bob", "Stone" }, { "Cid", "Rock" }, { "Dee", "Moss" } }
                for i, n in ipairs(names) do stranger("nameplate" .. i, n[1], n[2]) end
                for step = 1, 60 do
                    local roll = random.random(1, 6)
                    if roll == 1 then
                        local who = names[random.random(1, 3)]
                        wow.state.castFailures[who[1] .. "-" .. who[2]] =
                            random.random(1, 2) == 1 and "Spell is not ready yet." or nil
                    elseif roll == 2 then
                        wow.press(button, "RightButton")
                    elseif roll == 3 then
                        wow.advance(random.random(1, 20))
                    elseif roll == 4 then
                        wow.state.playerAuras = {}
                    else
                        press()
                    end
                    refresh()
                    local shown, offered = result(), title()
                    -- A right-click's line stays wherever the button moves (the owner, #461).
                    local rightClick = shown:find("^Skipping ") or shown:find("^Let ")
                    if shown ~= "" and not rightClick and button:IsShown() and offered ~= "" and offered ~= "Buff mode" then
                        local about = offered == "You" and "you" or offered
                        assert.is_truthy(shown:find(about, 1, true),
                            ("seed %d, step %d: %q under %s"):format(seed, step, shown, offered))
                    end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
        end)
    end)

    describe("#462: a passer-by keeps any trigger's buff mode on", function()
        it("buff mode a missing buff of yours turned on stays on while a passer-by waits (white)", function()
            boot({ auto = true })
            stranger("nameplate1", "Bob", "Stone")
            -- Your Thorns goes missing: the trigger turns buff mode on.
            loseThorns()
            assert.is_true(ns.BuffMode.IsAuto(), "turned on for your Thorns")
            press()
            assert.are.same({ "Thorns", wow.state.units.player.id }, { lastCast().spell, lastCast().target })
            refresh()
            assert.is_true(ns.BuffMode.IsOn(), "Bob still waits: not \"you have your buffs\" (the owner's case)")
            assert.are.equal("Bob Stone", title(), "and the key does what the button shows")
            press()
            assert.are.same({ "Mark of the Wild", "Bob-Stone" }, { lastCast().spell, lastCast().target })
            press()
            refresh()
            assert.is_false(ns.BuffMode.IsOn(), "Bob has your buffs: everyone has, and it turns off")
        end)

        it("a favour's buff mode stays on for a passer-by after the favour is returned (white)", function()
            boot({ auto = true })
            wearMine()
            stranger("nameplate1", "Bob", "Stone")
            stranger("nameplate2", "Ann", "Vale", { class = "MAGE" })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
            assert.is_true(ns.BuffMode.IsAuto())
            press()
            assert.are.equal("Ann-Vale", lastCast().target)
            refresh()
            assert.is_true(ns.BuffMode.IsOn(), "Bob passing by keeps it on")
        end)

        it("a passer-by refused on the global cooldown or for mana still waits: buff mode stays on (#459, black)",
            function()
            for _, why in ipairs({ "Spell is not ready yet.", "Not enough mana" }) do
                boot({ auto = true })
                wearMine()
                stranger("nameplate1", "Bob", "Stone")
                stranger("nameplate2", "Ann", "Vale", { class = "MAGE", auras = { THORNS }, auraSources = { false } })
                wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
                press()
                refresh()
                assert.are.equal("Bob Stone", title(), why)
                wow.state.castFailures["Bob-Stone"] = why
                press()
                refresh()
                assert.is_true(ns.BuffMode.IsOn(), why .. ": Bob waits out his hold, buff mode with him")
                wow.state.castFailures["Bob-Stone"] = nil
                wow.advance(ns.PassersBy.HELD_BACK_SECONDS + 1)
                refresh()
                assert.is_true(ns.BuffMode.IsOn(), why)
                assert.are.equal("Bob Stone", title(), why .. ": offered again after the hold")
            end
        end)

        it("ends when the passer-by is skipped or gone, at the timeout, and at the pull (white, red)", function()
            local ends = {
                skipped = function() wow.press(button, "RightButton") end,
                gone = function() wow.state.units.nameplate1 = nil end,
                timeout = function() wow.advance(ns.db.buffBack.autoOffMinutes * 60 + 1) end,
                pull = function() wow.enterCombat() end,
            }
            for how, finish in pairs(ends) do
                boot({ auto = true })
                wearMine()
                stranger("nameplate1", "Bob", "Stone")
                -- Ann wears someone's Thorns: your Mark returns her favour, and she has both.
                stranger("nameplate2", "Ann", "Vale", { class = "MAGE", auras = { THORNS }, auraSources = { false } })
                wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
                press()
                refresh()
                assert.is_true(ns.BuffMode.IsOn(), how)
                finish()
                ns.PassersBy.Fresh()
                if how ~= "pull" then refresh() end
                assert.is_false(ns.BuffMode.IsOn(), how)
            end
        end)

        it("with passers-by off, nothing changes: it turns off once you have your buffs (white)", function()
            boot({ auto = true, off = true })
            stranger("nameplate1", "Bob", "Stone")
            loseThorns()
            assert.is_true(ns.BuffMode.IsAuto())
            press()
            refresh()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("passers-by never turn buff mode on by themselves (black)", function()
            boot({ auto = true })
            wearMine()
            stranger("nameplate1", "Bob", "Stone")
            wow.advance(ns.BuffModeAuto.WATCH_SECONDS * 3)
            refresh()
            assert.is_false(ns.BuffMode.IsOn(), "Bob waits, but nothing of yours is missing")
        end)

        it("with buff mode off, the button never shows a passer-by (black)", function()
            boot({ auto = true })
            wearMine()
            stranger("nameplate1", "Bob", "Stone")
            refresh()
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_false(button:IsShown(), "nothing owed, buff mode off: no Bob")
        end)

        it("chaos: buff mode a trigger turned on turns off before its timeout only when no passer-by on a "
            .. "nameplate lacks a buff of yours, unless right-clicked away (red)", function()
            local names = { { "Bob", "Stone" }, { "Cid", "Rock" } }
            local turnedOff = 0
            for seed = 1, 6 do
                random.seed(seed)
                boot({ auto = true })
                wearMine()
                wow.advance(ns.BuffModeAuto.WATCH_SECONDS + 1)
                local skippedAt, onAt, wasAuto = {}, nil, false
                for step = 1, 50 do
                    local roll = random.random(1, 7)
                    if roll == 1 then
                        local i = random.random(1, 2)
                        if wow.state.units["nameplate" .. i] then
                            wow.state.units["nameplate" .. i] = nil
                        else
                            stranger("nameplate" .. i, names[i][1], names[i][2])
                        end
                    elseif roll == 2 then
                        wow.state.playerAuras = {}
                        wow.advance(ns.BuffModeAuto.WATCH_SECONDS + 1)
                    elseif roll == 3 then
                        local armedFor = ns.BuffButton.ArmedOffer()
                        if armedFor and armedFor.passerBy then skippedAt[armedFor.name] = wow.now end
                        wow.press(button, "RightButton")
                    elseif roll == 4 then
                        wow.advance(random.random(1, 30))
                    else
                        press()
                    end
                    refresh()
                    -- Buff mode a trigger had on at the end of the last step
                    -- turned off in this one (often inside the press itself).
                    if not ns.BuffMode.IsOn() then
                        if wasAuto and wow.now - onAt < ns.db.buffBack.autoOffMinutes * 60 then
                            turnedOff = turnedOff + 1
                            -- Independently, from the client's own state: every
                            -- stranger shown wears both your buffs, or was skipped.
                            for i = 1, 2 do
                                local u = wow.state.units["nameplate" .. i]
                                local id = u and (u.name .. "-" .. u.surname)
                                if u and not (skippedAt[id] and wow.now - skippedAt[id] < ns.PassersBy.SKIP_SECONDS) then
                                    local wears = {}
                                    for _, aura in ipairs(u.auras or {}) do wears[aura] = true end
                                    assert.is_true(wears[MOTW] == true and wears[THORNS] == true,
                                        ("seed %d, step %d: off while %s lacks a buff"):format(seed, step, id))
                                end
                            end
                        end
                        onAt = nil
                    end
                    wasAuto = ns.BuffMode.IsAuto()
                    if wasAuto and not onAt then onAt = wow.now end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
            assert.is_true(turnedOff >= 3, "the storm turned buff mode off " .. turnedOff .. " times")
        end)
    end)
end)
