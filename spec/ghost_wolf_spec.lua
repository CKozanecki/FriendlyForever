-- Spec: #466, #544
-- In Ghost Wolf, buff mode's key waits for a shaman's spell buffs, as it
-- does for a druid in a form (#452; the owner's decision on #466, 17 Nov):
-- the button still shows the buff and a click casts it (the game takes you
-- out of Ghost Wolf), but scrolling never does. "Fast-cast buffs in form"
-- covers Ghost Wolf too. Weapon imbues keep #45's choice B. An unreadable
-- form answer means the key waits. How Forever reports Ghost Wolf is
-- unconfirmed (#467): the game's form, or Ghost Wolf's aura on you. The key
-- waits when either says so, so every spec here runs each way the game might
-- report it.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local WATER_BREATHING, WATER_WALKING = 131, 546
local WINDFURY_4 = 16362

-- The ways the game might report Ghost Wolf (#467): its form (1) and its
-- aura; only the form (the aura's ID isn't 2645 on Forever); only the aura
-- (GetShapeshiftForm gives 0 for a shaman).
local READINGS = {
    { name = "form and aura", form = 1, aura = true },
    { name = "form only", form = 1, aura = false },
    { name = "aura only", form = 0, aura = true },
}

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("A shaman's buffs in Ghost Wolf (#466)", function()
    local ns, button

    -- A shaman who knows Water Breathing and Water Walking, in buff mode
    -- (opts.noMode: not), in a party with Ann and Cid (opts.solo: alone), who
    -- lack Water Breathing, offered away from water. opts.wolf: in Ghost Wolf
    -- at the start, read as opts.reading (READINGS[1] unless given).
    local function boot(opts)
        opts = opts or {}
        local reading = opts.reading or READINGS[1]
        local db = opts.db or {}
        db.buffBack = db.buffBack or {}
        if db.buffBack.breathNearWater == nil then db.buffBack.breathNearWater = false end
        ns = wow.boot({ db = db, before = function(state)
            state.class = opts.class or "SHAMAN"
            state.knownSpells = opts.known or { [WATER_BREATHING] = true, [WATER_WALKING] = true }
            state.ghostWolfForm, state.ghostWolfAura = reading.form, reading.aura
            if opts.before then opts.before(state) end
        end })
        button = ns.BuffButton.Frame()
        if opts.wolf then wow.setGhostWolf(true) end
        if not opts.noMode then slash("buffmode on") end
        if not opts.solo then
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
            wow.fire("GROUP_ROSTER_UPDATE")
        end
        wow.advance(0)
        ns.BuffButton.Refresh()
    end

    local A = function() return ns.BuffButton.SECURE_ATTRIBUTE end
    local function clickMacro() return button:GetAttribute(A().leftButtonMacroText) end
    local function keyMacro() return button:GetAttribute(A().keyMacroText) end
    local function scroll() wow.pressKey("MOUSEWHEELUP") end
    local function click() wow.press(button) end
    local function castCount() return #wow.casts end
    -- Whether you wear Ghost Wolf's aura, from the simulated client's own list.
    local function wearsWolf()
        for _, aura in ipairs(wow.state.playerAuras) do
            if aura.spellId == wow.GHOST_WOLF then return true end
        end
        return false
    end

    describe("in Ghost Wolf, with the setting off (white)", function()
        for _, reading in ipairs(READINGS) do
            it(reading.name .. ": scrolling never casts a buff, and a click on the button does", function()
                boot({ wolf = true, reading = reading })
                assert.is_true(wow.state.ghostWolf)
                assert.are.equal(reading.aura, wearsWolf())
                assert.is_truthy(clickMacro(), "the button still offers the buff")
                assert.matches("Water Breathing", button.subtitle:GetText(), 1, true)
                assert.is_nil(keyMacro(), "the key has no action")
                for _ = 1, 5 do scroll() end
                assert.are.equal(0, castCount())
                assert.is_true(wow.state.ghostWolf, "still in Ghost Wolf")
                assert.are.equal(0, wow.formsCancelled)
                click()
                assert.are.equal(1, castCount())
                assert.are.equal(WATER_BREATHING, wow.casts[1].id)
                assert.is_false(wow.state.ghostWolf, "the game took you out of Ghost Wolf")
                assert.is_false(wearsWolf())
                assert.are.equal(1, wow.formsCancelled, "the game did, not the addon")
                assert.matches("Gave Water Breathing to", wow.lastResult(ns), 1, true)
            end)
        end

        it("the button says the key waits, and why", function()
            boot({ wolf = true })
            assert.matches("click to buff (you're in Ghost Wolf)", button.mode:GetText(), 1, true)
            local lines = table.concat(ns.BuffButton.StatusLines(), "\n")
            assert.matches("buff mode's key waits: you're in Ghost Wolf", lines, 1, true)
            scroll()
            assert.matches("Click the button to buff: you're in Ghost Wolf.", button.result:GetText(), 1, true)
        end)

        for _, reading in ipairs(READINGS) do
            it(reading.name .. ": leaving Ghost Wolf lets the key cast again, at once", function()
                boot({ wolf = true, reading = reading })
                scroll()
                assert.are.equal(0, castCount())
                wow.setGhostWolf(false)
                wow.advance(0)
                assert.are.equal(clickMacro(), keyMacro())
                assert.matches("MOUSEWHEELUP", button.mode:GetText(), 1, true)
                scroll()
                assert.are.equal(1, castCount())
                assert.are.equal(0, wow.formsCancelled)
            end)

            it(reading.name .. ": going into Ghost Wolf stops the key at once, even before any refresh", function()
                boot({ reading = reading })
                assert.is_truthy(keyMacro())
                -- No event yet: the press itself reads the form and your buffs.
                wow.state.ghostWolf, wow.state.form = true, reading.form
                if reading.aura then
                    wow.state.playerAuras[#wow.state.playerAuras + 1] = { isHelpful = true,
                        spellId = wow.GHOST_WOLF, sourceUnit = "player", duration = 0, expirationTime = 0 }
                end
                scroll()
                assert.are.equal(0, castCount())
                assert.is_true(wow.state.ghostWolf)
                assert.is_nil(button:GetAttribute(A().keyActionType))
                assert.is_nil(keyMacro())
            end)
        end

        it("Water Walking asked for in chat waits for a click too", function()
            boot({ solo = true, wolf = true, db = { buffBack = { requests = true } } })
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
            wow.whisper("ww pls", "Bob-Stone")
            ns.BuffButton.Refresh()
            assert.matches("asked for Water Walking", button.subtitle:GetText(), 1, true)
            scroll()
            assert.are.equal(0, castCount())
            click()
            assert.are.equal(WATER_WALKING, wow.casts[1].id)
            assert.are.equal("Bob-Stone", wow.casts[1].target)
        end)

        it("buff back's favours wait for a click too", function()
            boot({ solo = true, wolf = true })
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = 10157 })
            ns.BuffButton.Refresh()
            assert.matches("Bob", button.title:GetText(), 1, true)
            scroll()
            assert.are.equal(0, castCount())
            click()
            assert.are.equal("Bob-Stone", wow.casts[1].target)
            assert.matches("Returned Water Breathing to Bob Stone.", button.result:GetText(), 1, true)
        end)

        for _, reading in ipairs(READINGS) do
            it(reading.name .. ": a weapon imbue is a spell: it waits for a click, as any buff (#544)", function()
                boot({ solo = true, wolf = true, reading = reading, known = { [WINDFURY_4] = true },
                    db = { buffBack = { weaponBuffs = true, weaponMain = "windfury", soloOwnBuffs = false } } })
                assert.are.equal("/cast [@player,nodead] Windfury Weapon\n/use 16", clickMacro())
                assert.is_nil(keyMacro())
                scroll()
                assert.are.equal(0, #wow.applied)
                click()
                assert.are.equal(1, #wow.applied)
                assert.are.equal(1, wow.formsCancelled, "the game took you out of Ghost Wolf, as by hand")
            end)
        end

        it("Ghost Wolf's aura holds only a shaman's key: a druid out of form wearing it still casts", function()
            boot({ class = "DRUID", known = { [1126] = true, [9885] = true } })
            wow.gainBuff({ spellId = wow.GHOST_WOLF, name = "Ghost Wolf", sourceUnit = "player" })
            ns.BuffButton.Refresh()
            assert.is_truthy(keyMacro())
            scroll()
            assert.are.equal(1, castCount())
        end)
    end)

    describe("with Fast-cast buffs in form on (white)", function()
        for _, reading in ipairs(READINGS) do
            it(reading.name .. ": scrolling casts in Ghost Wolf, and the game takes you out of it", function()
                boot({ wolf = true, reading = reading, db = { buffBack = { fastCastInForm = true } } })
                assert.are.equal(clickMacro(), keyMacro())
                scroll()
                assert.are.equal(1, castCount())
                assert.is_false(wow.state.ghostWolf)
                assert.are.equal(1, wow.formsCancelled)
            end)
        end

        it("the key casts a weapon imbue in Ghost Wolf too, as any buff (#544)", function()
            boot({ solo = true, wolf = true, known = { [WINDFURY_4] = true }, db = { buffBack = {
                weaponBuffs = true, weaponMain = "windfury", soloOwnBuffs = false, fastCastInForm = true } } })
            assert.are.equal("/cast [@player,nodead] Windfury Weapon\n/use 16", keyMacro())
            scroll()
            assert.are.equal(1, #wow.applied)
        end)

        it("its tooltip names druid forms and Ghost Wolf, and the options search finds it by Ghost Wolf", function()
            boot({ wolf = true })
            ns.Options.SelectType(ns.Options.BUFFS_TAB)
            local box = ns.Options.widgets.fastCastInForm
            assert.matches("For druid forms and Ghost Wolf.", box.tooltip, 1, true)
            assert.are.equal(ns.BuffsTab.FAST_CAST_TOOLTIP, box.tooltip)
            local found = false
            for _, entry in ipairs(ns.OptionsIndex.Find("ghost wolf")) do
                if entry.name == "Fast-cast buffs in form" then found = true end
            end
            assert.is_true(found)
            -- Switched on from the tab, the key casts in Ghost Wolf at once.
            assert.is_nil(keyMacro())
            box:SetChecked(true)
            wow.run(box, "OnClick")
            assert.is_truthy(keyMacro())
        end)
    end)

    describe("what can't be read (black)", function()
        -- Your buff list, read through a wrapper that answers bad for you.
        local function badPlayerAuras(answer)
            local real = _G.C_UnitAuras.GetAuraDataByIndex
            -- One bad answer, then the end of the list (too many: buffs
            -- that aren't Ghost Wolf past all the addon reads).
            _G.C_UnitAuras.GetAuraDataByIndex = function(unit, index, filter)
                if unit ~= "player" then return real(unit, index, filter) end
                if answer == "too many" then return { spellId = 1, isHelpful = true } end
                if index > 1 then return nil end
                if answer == "error" then error("aura data is restricted") end
                if answer == "secret aura" then return wow.secret({ spellId = 1 }) end
                if answer == "secret id" then return { spellId = wow.secret(wow.GHOST_WOLF), isHelpful = true } end
                if answer == "text id" then return { spellId = "2645", isHelpful = true } end
                if answer == "NaN id" then return { spellId = 0 / 0, isHelpful = true } end
                if answer == "not a table" then return "Ghost Wolf" end
                return real(unit, index, filter)
            end
            return function() _G.C_UnitAuras.GetAuraDataByIndex = real end
        end

        it("a secret form means the key waits; a click still casts", function()
            boot({ before = function(s) s.selfSecrets.form = true end })
            assert.is_truthy(clickMacro())
            assert.is_nil(keyMacro())
            assert.matches("can't tell whether you're in Ghost Wolf", button.mode:GetText(), 1, true)
            scroll()
            assert.are.equal(0, castCount())
            click()
            assert.are.equal(1, castCount())
        end)

        it("a form read that fails, or isn't a number, means the key waits", function()
            for _, answer in ipairs({ "error", "text", 0 / 0, false }) do
                boot()
                _G.GetShapeshiftForm = function()
                    if answer == "error" then error("GetShapeshiftForm: not now") end
                    return answer
                end
                ns.BuffButton.Refresh()
                assert.is_nil(keyMacro(), tostring(answer))
                assert.matches("can't tell whether you're in Ghost Wolf", button.mode:GetText(), 1, true)
                scroll()
                assert.are.equal(0, castCount(), tostring(answer))
            end
        end)

        it("your buffs that can't be read mean the key waits, out of Ghost Wolf too; a click still casts", function()
            for _, answer in ipairs({ "error", "secret aura", "secret id", "text id", "NaN id", "not a table",
                "too many" }) do
                boot()
                local restore = badPlayerAuras(answer)
                ns.BuffButton.Refresh()
                assert.is_nil(keyMacro(), answer)
                assert.matches("can't tell whether you're in Ghost Wolf", button.mode:GetText(), 1, true)
                scroll()
                assert.are.equal(0, castCount(), answer)
                assert.is_truthy(clickMacro(), answer)
                click()
                restore()
                assert.are.equal(1, castCount(), answer)
            end
        end)

        it("no aura API at all means the key waits", function()
            boot()
            local real = _G.C_UnitAuras
            _G.C_UnitAuras = { GetAuraDataByIndex = "not a function" }
            assert.are.equal("can't tell whether you're in Ghost Wolf", ns.BuffButton.KeyWaits({ name = "Ann-Vale" }))
            _G.C_UnitAuras = nil
            assert.are.equal("can't tell whether you're in Ghost Wolf", ns.BuffButton.KeyWaits({ name = "Ann-Vale" }))
            _G.C_UnitAuras = real
            assert.is_nil(ns.BuffButton.KeyWaits({ name = "Ann-Vale" }))
        end)

        it("the setting on lets the key cast even when nothing can be read", function()
            boot({ db = { buffBack = { fastCastInForm = true } },
                before = function(s) s.selfSecrets.form = true end })
            local restore = badPlayerAuras("error")
            ns.BuffButton.Refresh()
            assert.is_truthy(keyMacro())
            restore()
        end)
    end)

    describe("storms (red)", function()
        -- Ghost Wolf in and out (each time read one of the READINGS ways),
        -- form secrets, unreadable buffs, scrolls, clicks, fights, favours
        -- and the setting, at random. Checked from the simulated client's own
        -- state, as each press happens: a scroll in Ghost Wolf, or with the
        -- form or your buffs unreadable, with the setting off, never casts and
        -- never ends Ghost Wolf. Each hazard is counted only where it bites
        -- (out of a fight, a buff armed, the setting off), and every seed must
        -- reach each one.
        local HAZARDS = { "form and aura", "form only", "aura only", "form unreadable", "buffs unreadable" }
        local STRANGERS = { "Bob", "Dot", "Eve", "Fay", "Gil", "Hal", "Ivy" }
        local SURNAMES = { "Stone", "Brook", "Vale", "Marsh", "Holt" }

        -- A buff of yours whose ID is secret: your buffs can't be read.
        local function unreadable()
            for _, aura in ipairs(wow.state.playerAuras) do
                if aura.unreadable then return true end
            end
            return false
        end

        local function hazardOf()
            if wow.state.selfSecrets.form == true then return "form unreadable" end
            if wow.state.ghostWolf then
                local form, aura = wow.state.form ~= 0, wearsWolf()
                return (form and aura) and "form and aura" or form and "form only" or "aura only"
            end
            if unreadable() then return "buffs unreadable" end
            return nil
        end

        for _, seed in ipairs({ 466, 11, 1118, 2027, 4242 }) do
            it("seed " .. seed .. ": never casts on a scroll in Ghost Wolf, or unreadable, with the setting off",
                function()
                random.seed(seed)
                boot()
                local errors = ns.Diag.Counters().luaErrors or 0
                local reached, clicked, keyCasts, strangers = {}, 0, 0, 0
                for _, h in ipairs(HAZARDS) do reached[h] = 0 end
                local function strip()
                    for _, token in ipairs({ "party1", "party2" }) do
                        if wow.state.units[token] then wow.state.units[token].auras = {} end
                    end
                    wow.fire("UNIT_AURA", "party1", { isFullUpdate = true })
                    wow.fire("UNIT_AURA", "party2", { isFullUpdate = true })
                end
                for _ = 1, 1000 do
                    local roll = random.random(1, 14)
                    if roll <= 5 then
                        if random.random() < 0.5 then strip() end
                        local hazard = hazardOf()
                        local fast = ns.db.buffBack.fastCastInForm == true
                        local fight = wow.state.inCombat
                        local before, cancelled, wolf = castCount(), wow.formsCancelled, wow.state.ghostWolf
                        scroll()
                        local armed = not fight and clickMacro() ~= nil
                        if hazard and not fast then
                            assert.are.equal(before, castCount(), "seed " .. seed .. ": a scroll cast, " .. hazard)
                            assert.are.equal(cancelled, wow.formsCancelled, "seed " .. seed)
                            assert.are.equal(wolf, wow.state.ghostWolf, "seed " .. seed)
                            if armed then reached[hazard] = reached[hazard] + 1 end
                        elseif castCount() > before then
                            keyCasts = keyCasts + 1
                        end
                    elseif roll == 6 then
                        if not wow.state.inCombat then
                            local before = castCount()
                            click()
                            if castCount() > before then clicked = clicked + 1 end
                        end
                    elseif roll <= 8 then
                        if wow.state.ghostWolf or random.random() < 0.4 then
                            wow.setGhostWolf(false)
                        else
                            local reading = READINGS[random.random(1, #READINGS)]
                            wow.state.ghostWolfForm, wow.state.ghostWolfAura = reading.form, reading.aura
                            wow.setGhostWolf(true)
                        end
                    elseif roll == 9 then
                        local pick = random.random(1, 3)
                        wow.state.selfSecrets.form = pick == 1
                        for i = #wow.state.playerAuras, 1, -1 do
                            if wow.state.playerAuras[i].unreadable then table.remove(wow.state.playerAuras, i) end
                        end
                        if pick == 2 then
                            wow.state.playerAuras[#wow.state.playerAuras + 1] = { isHelpful = true,
                                unreadable = true, spellId = wow.secret(1), auraInstanceID = 680000 + seed }
                        end
                        wow.fire("UPDATE_SHAPESHIFT_FORM")
                    elseif roll == 10 and not wow.state.inCombat and random.random() < 0.5 then
                        wow.enterCombat()
                    elseif roll == 10 and wow.state.inCombat and random.random() < 0.5 then
                        wow.leaveCombat()
                    elseif roll == 11 or roll == 10 then
                        strangers = strangers + 1
                        local first = STRANGERS[strangers % #STRANGERS + 1]
                        local last = SURNAMES[math.floor(strangers / #STRANGERS) % #SURNAMES + 1]
                        wow.addUnit("nameplate1", { name = first, surname = last, id = first .. "-" .. last,
                            class = "WARRIOR" })
                        wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = 10157 })
                    elseif roll == 12 then
                        if not wow.state.inCombat then
                            ns.db.buffBack.fastCastInForm = random.random() < 0.25
                            ns.BuffButton.Refresh()
                        end
                    else
                        if wow.state.inCombat and random.random() < 0.5 then wow.leaveCombat() end
                        wow.advance(random.random(0, 20) / 10)
                    end
                end
                if wow.state.inCombat then wow.leaveCombat() end
                assert.are.equal(errors, ns.Diag.Counters().luaErrors or 0, "seed " .. seed .. ": no Lua error")
                for _, h in ipairs(HAZARDS) do
                    assert.is_true(reached[h] >= 2, ("seed %d: %s reached %d times"):format(seed, h, reached[h]))
                end
                assert.is_true(keyCasts > 0 and clicked > 0, ("seed %d: key casts %d, clicks %d"):format(seed,
                    keyCasts, clicked))
            end)
        end
    end)
end)
