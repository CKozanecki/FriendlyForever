-- Spec: #495
-- Fast-cast in form, back into the form (#495, the owner's decisions of 18
-- Nov). With "Fast-cast buffs in form" on, in buff mode, a buff press that
-- takes you out of a druid's Cat, Bear (or Dire Bear) or Travel Form, or a
-- shaman's Ghost Wolf, is remembered; once buff mode has nothing left for
-- you to buff, the button offers that form, and the next press (the key or
-- a click) shifts you back. Nothing casts by itself. A fight, a shift by
-- hand, 30 seconds after your last buff or buff mode off drops it. A
-- refused shift back makes the key wait ("click to shift back") with the
-- game's reason. A form that can't be read is no form to go back to.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1 = 9885, 1126
local CAT, BEAR, DIRE, TRAVEL, AQUATIC, MOONKIN, WOLF = 768, 5487, 9634, 783, 1066, 24858, 2645
local WATER_BREATHING, WATER_WALKING = 131, 546
local NAMES = { [CAT] = "Cat Form", [BEAR] = "Bear Form", [DIRE] = "Dire Bear Form", [TRAVEL] = "Travel Form",
    [WOLF] = "Ghost Wolf" }

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Back into your form after fast-cast buffing (#495)", function()
    local ns, button
    local worn = 0 -- how many of wow.landed are worn (wearLanded)

    -- A druid who knows Mark of the Wild and the forms, in buff mode
    -- (opts.noMode: not) with "Fast-cast buffs in form" on (opts.fastCast
    -- false: off), in a party with Ann and Cid (opts.solo: alone), who lack
    -- it. opts.form: the form's spell at the start. opts.shaman: a shaman
    -- who knows Water Breathing and Water Walking instead, in Ghost Wolf,
    -- read as opts.wolfForm (GetShapeshiftForm's answer in it, 1 unless
    -- given) and opts.wolfAura (false: no aura of 2645).
    local function boot(opts)
        opts = opts or {}
        worn = 0
        local db = { buffBack = { fastCastInForm = opts.fastCast ~= false, breathNearWater = false } }
        if opts.db then opts.db(db) end
        ns = wow.boot({ db = db, before = function(state)
            if opts.shaman then
                state.class = "SHAMAN"
                state.knownSpells = { [WATER_BREATHING] = true, [WATER_WALKING] = true, [WOLF] = true }
                state.ghostWolfForm, state.ghostWolfAura = opts.wolfForm or 1, opts.wolfAura
            else
                state.class = "DRUID"
                state.knownSpells = { [MOTW_1] = true, [MOTW] = true, [CAT] = true, [BEAR] = true, [DIRE] = true,
                    [TRAVEL] = true, [AQUATIC] = true, [MOONKIN] = true }
                if opts.form then
                    state.form, state.formSpell = wow.FORM_STANCE[opts.form], opts.form
                end
            end
            if opts.before then opts.before(state) end
        end })
        button = ns.BuffButton.Frame()
        if opts.shaman then wow.setGhostWolf(true) end
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
    local function offersForm() return (clickMacro() or ""):find("^/cast !") ~= nil end
    local function formCasts()
        local out = {}
        for _, c in ipairs(wow.casts) do if c.form then out[#out + 1] = c end end
        return out
    end
    -- Each buff that landed on a party member, worn by them (the simulated
    -- client leaves a member's auras to the spec).
    local function wearLanded()
        for i = worn + 1, #wow.landed do
            local l = wow.landed[i]
            for _, token in ipairs({ "party1", "party2" }) do
                local u = wow.state.units[token]
                if u and u.id == l.target then wow.wearBuff(token, l.id, { source = "player" }) end
            end
        end
        worn = #wow.landed
    end
    -- Scroll until the button offers no buff any more (at most max times).
    local function scrollBuffs(max)
        for _ = 1, max or 12 do
            if offersForm() or not clickMacro() then return end
            scroll()
            wearLanded()
        end
        ns.BuffButton.Refresh()
    end
    -- The form the druid is in now (its spell), or 0.
    local function form() return (wow.state.form or 0) ~= 0 and wow.state.formSpell or 0 end

    describe("going back (white)", function()
        for _, spell in ipairs({ CAT, BEAR, DIRE, TRAVEL }) do
            it(NAMES[spell] .. ": a scroll's buff takes you out of it; once the buffs are done, "
                .. "the next scroll shifts you back", function()
                boot({ form = spell })
                scroll()
                assert.are.equal(MOTW, wow.casts[1].id, "a buff landed")
                assert.are.equal(1, wow.formsCancelled, "the game took you out of the form")
                assert.are.equal(0, form())
                -- Buffs are left: they come first.
                assert.is_false(offersForm())
                assert.matches("Mark of the Wild", button.subtitle:GetText(), 1, true)
                scrollBuffs()
                assert.is_true(offersForm(), "the buffs are done: the form is offered")
                assert.are.equal("/cast !" .. NAMES[spell], clickMacro())
                assert.are.equal(clickMacro(), keyMacro(), "the key presses it")
                assert.matches("shift back into " .. NAMES[spell], button.subtitle:GetText(), 1, true)
                local before = #wow.casts
                scroll()
                assert.are.equal(before + 1, #wow.casts)
                local last = wow.casts[#wow.casts]
                assert.is_true(last.form)
                assert.are.equal(spell, last.id)
                assert.are.equal(spell, form(), "back in the form")
                assert.matches("Back in " .. NAMES[spell] .. ".", wow.lastResult(ns), 1, true)
                -- Done: nothing more is offered, and more scrolls cast nothing.
                assert.is_false(offersForm())
                for _ = 1, 5 do scroll() end
                assert.are.equal(before + 1, #wow.casts)
            end)
        end

        it("a click shifts you back too, and the tooltip says what it does", function()
            boot({ form = CAT })
            scrollBuffs()
            assert.is_true(offersForm())
            wow.run(button, "OnEnter")
            local tip = table.concat(_G.GameTooltip.lines or {}, "\n")
            assert.matches("Shifts you back into Cat Form.", tip, 1, true)
            assert.matches("Right-click to stay out of the form.", tip, 1, true)
            click()
            assert.are.equal(CAT, form())
            assert.are.equal(1, #formCasts())
        end)

        it("the form waits while anyone is still to buff, and shows only once nobody is", function()
            boot({ form = CAT })
            scroll()
            local seen = {}
            for _ = 1, 12 do
                if offersForm() then break end
                seen[#seen + 1] = button.title:GetText()
                scroll()
            end
            assert.is_true(#seen >= 1, "the other members were offered first")
            -- Every member now wears it: the form is all that's left.
            assert.is_true(offersForm())
            assert.is_nil(ns.BuffButton.ArmedOffer().buff)
        end)

        it("Ghost Wolf: a scroll's buff takes a shaman out of it; the next scroll after the buffs shifts back",
            function()
            for _, reading in ipairs({ { form = 1, aura = true }, { form = 0, aura = true } }) do
                boot({ shaman = true, wolfForm = reading.form, wolfAura = reading.aura })
                assert.is_true(wow.state.ghostWolf)
                scroll()
                assert.are.equal(WATER_BREATHING, wow.casts[1].id)
                assert.is_false(wow.state.ghostWolf, "the game took you out of Ghost Wolf")
                scrollBuffs()
                assert.are.equal("/cast !Ghost Wolf", clickMacro())
                scroll()
                assert.is_true(wow.state.ghostWolf, "back in Ghost Wolf")
                assert.are.equal(WOLF, formCasts()[1].id)
            end
        end)

        it("Ghost Wolf takes a moment to cast: meanwhile the button offers nothing, so more scrolls cast nothing "
            .. "and say nothing", function()
            boot({ shaman = true, wolfForm = 1, wolfAura = true })
            scrollBuffs()
            assert.are.equal("/cast !Ghost Wolf", clickMacro())
            wow.state.castLatency = 2.5            -- standing in for its cast time
            local printed = #wow.printed
            scroll()
            assert.are.equal(1, #formCasts())
            assert.is_nil(clickMacro(), "nothing offered while it's cast")
            for _ = 1, 5 do
                wow.advance(0.4)
                scroll()
            end
            wow.advance(1)
            assert.is_true(wow.state.ghostWolf, "back in Ghost Wolf")
            assert.are.equal(1, #formCasts())
            assert.matches("Back in Ghost Wolf.", wow.lastResult(ns), 1, true)
            wow.advance(ns.BuffButton.SENT_ANSWER_SECONDS + 1)
            for i = printed + 1, #wow.printed do
                assert.is_nil(tostring(wow.printed[i]):find("shift back", 1, true), tostring(wow.printed[i]))
            end
            assert.matches("Back in Ghost Wolf.", wow.lastResult(ns), 1, true)
        end)

        it("a trigger's buff mode stays on while the shift back waits, and turns off once you're back", function()
            boot({ form = CAT, noMode = true })
            ns.BuffMode.Set(true, { auto = true, why = "test" })
            wow.advance(0)
            ns.BuffButton.Refresh()
            assert.is_true(ns.BuffMode.IsAuto())
            scroll()
            scrollBuffs()
            ns.BuffButton.Refresh()
            assert.is_true(ns.BuffMode.IsAuto(), "the shift back is work left")
            assert.is_true(offersForm())
            scroll()
            assert.are.equal(CAT, form())
            ns.BuffButton.Refresh()
            assert.is_falsy(ns.BuffMode.LentKey(), "done: buff mode turns itself off")
        end)

        it("each buff press starts the 30 seconds again", function()
            boot({ form = CAT })
            scroll()                      -- leaves Cat Form at 0
            wow.advance(25)
            scroll()                      -- another buff at 25
            scrollBuffs()
            wow.advance(29.9 - 0)         -- 54.9: 29.9 after the last buff press
            ns.BuffButton.Refresh()
            assert.is_true(offersForm())
            wow.advance(0.2)
            assert.is_false(offersForm(), "30 seconds after the last buff, it's gone")
        end)
    end)

    describe("no return to offer (black)", function()
        it("with Fast-cast buffs in form off, a click's buff takes you out, and no form is offered", function()
            boot({ form = CAT, fastCast = false })
            click()
            assert.are.equal(0, form())
            for _ = 1, 12 do
                if not clickMacro() then break end
                click()
            end
            assert.is_nil(clickMacro(), "nothing left, and no form offered")
            assert.are.equal(0, #formCasts())
        end)

        it("with no form before buffing, no form is offered", function()
            boot()
            scrollBuffs()
            assert.is_nil(clickMacro())
            assert.are.equal(0, #formCasts())
        end)

        local UNREADABLE = {
            { "a secret form", function(state) state.selfSecrets.form = true end },
            { "a form read that fails", function() end, function() _G.GetShapeshiftForm = function() error("x") end end },
            { "a secret form spell", function(state) state.selfSecrets.formInfo = true end },
            { "a form spell that is secret but keeps its number type (as the game's secrets do)", function() end,
                function() _G.issecretvalue = function(v) return v == CAT end end },
            { "a form that isn't a number, though the stance bar names Cat Form", function() end, function()
                _G.GetShapeshiftForm = function() return wow.state.form ~= 0 and "3" or 0 end
                _G.GetShapeshiftFormInfo = function() return "icon", true, true, CAT end
            end },
            { "a form info read that fails", function(state) state.formInfoError = true end },
            { "a form number that isn't the form's", function(state) state.formId = 31 end },
            { "a form number that isn't a number", function(state) state.formId = "1" end },
            { "a class that can't be read", function() end, function() _G.UnitClass = function() return nil end end,
                anyBuff = true },
            { "a form spell the game won't name", function() end, function()
                local real = _G.C_Spell.GetSpellName
                _G.C_Spell.GetSpellName = function(id) if id == CAT then return nil end return real(id) end
            end },
            { "a form spell whose name isn't safe in a macro", function() end, function()
                local real = _G.C_Spell.GetSpellName
                _G.C_Spell.GetSpellName = function(id) if id == CAT then return "Cat;Form" end return real(id) end
            end },
        }
        for _, case in ipairs(UNREADABLE) do
            it(case[1] .. " at the press: no form is offered", function()
                boot({ form = CAT, before = case[2] })
                if case[3] then case[3]() end
                ns.BuffButton.Refresh()
                scroll()
                if not case.anyBuff then assert.are.equal(1, wow.formsCancelled, "the buff took you out") end
                assert.is_false(ns.BuffButton.ReturnWaiting(), "nothing remembered")
                scrollBuffs()
                assert.is_false(offersForm())
                assert.are.equal(0, #formCasts())
                _G.issecretvalue = nil
            end)
        end

        it("Aquatic Form (with or without its number), Moonkin Form and a form the game names no spell for "
            .. "are no forms to go back to", function()
            for _, case in ipairs({ { AQUATIC }, { AQUATIC, false }, { MOONKIN }, { false } }) do
                local spell = case[1]
                boot({ form = spell or nil, before = function(state)
                    if not spell then state.form, state.formSpell = 2, nil end
                    if case[2] == false then state.formId = false end
                end })
                scroll()
                assert.is_false(ns.BuffButton.ReturnWaiting())
                scrollBuffs()
                assert.is_false(offersForm())
                assert.are.equal(0, #formCasts())
            end
        end)

        it("Ghost Wolf whose stance bar names another spell than Ghost Wolf: no form is offered", function()
            -- No form number, so the spell alone must say no.
            boot({ shaman = true, wolfForm = 1, wolfAura = true, before = function(state) state.formId = false end })
            wow.state.formSpell = CAT
            ns.BuffButton.Refresh()
            scroll()
            assert.is_false(wow.state.ghostWolf)
            assert.is_false(ns.BuffButton.ReturnWaiting())
        end)

        it("Ghost Wolf read only by the form, with no spell or aura to name it: no form is offered", function()
            boot({ shaman = true, wolfForm = 1, wolfAura = false })
            scroll()
            assert.is_false(wow.state.ghostWolf)
            scrollBuffs()
            assert.is_false(offersForm())
        end)

        it("a Ghost Wolf read the game won't finish (more buffs than are read) means no form is offered", function()
            boot({ shaman = true, wolfForm = 1, wolfAura = true, before = function(state)
                for i = 1, 41 do
                    state.playerAuras[i] = { isHelpful = true, spellId = 900000 + i, name = "Other " .. i,
                        sourceUnit = "party1", duration = 0, expirationTime = 0, auraInstanceID = 800000 + i }
                end
            end })
            -- Even when the stance bar names Ghost Wolf: the buffs can't be read.
            wow.state.formSpell = WOLF
            ns.BuffButton.Refresh()
            scroll()
            assert.is_false(wow.state.ghostWolf, "the buff took you out")
            assert.is_false(ns.BuffButton.ReturnWaiting())
            scrollBuffs()
            assert.is_false(offersForm())
        end)

        it("a form left long after the press, by hand, is not one to go back to", function()
            boot({ form = CAT, before = function(state) state.cvars.autoUnshift = "0" end })
            scroll()                               -- refused: still in Cat Form
            assert.are.equal(0, #wow.casts, "the game refused the buff")
            assert.are.equal(CAT, form())
            wow.advance(ns.BuffButton.LEAVE_SECONDS + 0.5)
            wow.setForm(0)
            wow.advance(0)
            assert.is_false(ns.BuffButton.ReturnWaiting())
            scrollBuffs()
            assert.is_false(offersForm())
        end)

        it("a press refused in a form, then a shift by hand into another form, remembers nothing", function()
            boot({ form = CAT, before = function(state) state.cvars.autoUnshift = "0" end })
            scroll()
            wow.setForm(1, BEAR)
            wow.advance(0)
            assert.is_false(ns.BuffButton.ReturnWaiting())
        end)

        it("a form the game won't say between the press and leaving it remembers nothing", function()
            boot({ form = CAT, before = function(state) state.cvars.autoUnshift = "0" end })
            scroll()                               -- refused: still in Cat Form
            wow.state.selfSecrets.form = true
            ns.BuffButton.Refresh()
            wow.state.selfSecrets.form = nil
            wow.setForm(0)                         -- within the leave window
            wow.advance(0)
            assert.is_false(ns.BuffButton.ReturnWaiting())
        end)
    end)

    describe("the return is dropped (black)", function()
        -- The buffs done from Cat Form: the shift back is offered.
        local function ready(opts)
            boot(opts or { form = CAT })
            scrollBuffs()
            assert.is_true(offersForm())
        end

        it("when a fight starts", function()
            ready()
            wow.enterCombat()
            wow.leaveCombat()
            wow.advance(0)
            assert.is_false(offersForm())
        end)

        it("when you shift by hand into a form, or out of one", function()
            ready()
            wow.setForm(1, BEAR)
            wow.advance(0)
            wow.setForm(0)
            wow.advance(0)
            ns.BuffButton.Refresh()
            assert.is_false(offersForm())
            -- And back into the remembered form by hand: done too.
            ready()
            wow.setForm(3, CAT)
            wow.setForm(0)
            wow.advance(0)
            ns.BuffButton.Refresh()
            assert.is_false(offersForm())
        end)

        it("when your form can no longer be read", function()
            ready()
            wow.state.selfSecrets.form = true
            ns.BuffButton.Refresh()
            assert.is_false(ns.BuffButton.ReturnWaiting())
            wow.state.selfSecrets.form = nil
            ns.BuffButton.Refresh()
            assert.is_false(offersForm())
        end)

        it("when a shift by hand is noticed only at the next press", function()
            ready()
            -- The game changes the form without its event: the press reads it.
            wow.state.form, wow.state.formSpell = 1, BEAR
            local before = #wow.casts
            scroll()
            assert.are.equal(0, #formCasts())
            assert.is_true(#wow.casts <= before)
        end)

        it("30 seconds after your last buff", function()
            ready()
            wow.advance(29.9)
            ns.BuffButton.Refresh()
            assert.is_true(offersForm())
            wow.advance(0.2)
            scroll()
            assert.are.equal(0, #formCasts(), "a press checks first")
            assert.is_false(offersForm())
        end)

        it("30 seconds after your last buff, the button lets it go by itself soon after", function()
            ready()
            wow.advance(30 + ns.BuffButton.RECHECK_SECONDS + 0.1)
            assert.is_false(offersForm())
        end)

        it("when buff mode turns off, even if it turns on again", function()
            ready()
            slash("buffmode off")
            wow.advance(0)
            slash("buffmode on")
            wow.advance(0)
            ns.BuffButton.Refresh()
            assert.is_false(offersForm())
        end)

        it("when Fast-cast buffs in form is turned off", function()
            ready()
            ns.db.buffBack.fastCastInForm = false
            ns.BuffButton.Refresh()
            ns.db.buffBack.fastCastInForm = true
            ns.BuffButton.Refresh()
            assert.is_false(offersForm())
        end)

        it("when buff mode turns off while buffs are still left", function()
            boot({ form = CAT })
            scroll()
            slash("buffmode off")
            wow.advance(0)
            slash("buffmode on")
            wow.advance(0)
            scrollBuffs()
            assert.is_false(offersForm())
        end)

        it("when the setting is damaged mid-session to something other than on", function()
            ready()
            ns.db.buffBack.fastCastInForm = "yes"
            ns.BuffButton.Refresh()
            assert.is_false(offersForm())
            assert.is_false(ns.BuffButton.ReturnWaiting())
        end)

        it("when you right-click it", function()
            ready()
            wow.press(button, "RightButton")
            assert.matches("Staying out of Cat Form.", wow.lastResult(ns), 1, true)
            assert.is_false(offersForm())
        end)

        it("once the game says you're back, even before your form changes", function()
            ready({ form = CAT, before = function(state) state.formAfterSucceeded = true end })
            local formsBefore = #formCasts()
            -- The form changes only after the success: in between, the button
            -- must not offer it again.
            local offeredBetween
            local realFire = wow.fire
            wow.fire = function(event, ...)
                if event == "UPDATE_SHAPESHIFT_FORM" and offeredBetween == nil then
                    offeredBetween = offersForm()
                end
                return realFire(event, ...)
            end
            scroll()
            wow.fire = realFire
            assert.are.equal(formsBefore + 1, #formCasts())
            assert.is_false(offeredBetween)
        end)
    end)

    describe("a refused shift back (black)", function()
        local function ready()
            boot({ form = TRAVEL })
            scrollBuffs()
            assert.is_true(offersForm())
        end

        it("indoors: the key waits, the button says click to shift back with the game's reason, "
            .. "and a click tries again", function()
            ready()
            wow.state.formRefusals = { [TRAVEL] = "Can only use outside." }
            local printed = #wow.printed
            scroll()
            assert.are.equal(0, #formCasts())
            assert.matches("Couldn't shift back into Travel Form: Can only use outside.", wow.lastResult(ns), 1, true)
            assert.is_nil(keyMacro(), "the key waits")
            assert.are.equal("/cast !Travel Form", clickMacro(), "a click still can")
            assert.matches("click to shift back (Can only use outside)", button.mode:GetText(), 1, true)
            -- Never again by itself, and the chat line is said once.
            local chat = #wow.printed
            assert.is_true(chat > printed)
            for _ = 1, 10 do scroll() end
            assert.matches("Click the button to shift back: Can only use outside.", button.result:GetText(), 1, true)
            wow.advance(5)
            assert.are.equal(0, #formCasts())
            -- Outside again: a click shifts you back.
            wow.state.formRefusals = nil
            click()
            assert.are.equal(TRAVEL, form())
            assert.are.equal(1, #formCasts())
        end)

        it("not in water, or any refusal the game gives: the same", function()
            ready()
            wow.state.formRefusals = { [TRAVEL] = "You can't do that here" }
            scroll()
            assert.is_nil(keyMacro())
            assert.matches("click to shift back (You can't do that here)", button.mode:GetText(), 1, true)
        end)

        it("no answer at all counts as refused", function()
            ready()
            wow.state.formRefusals = { [TRAVEL] = "" } -- the game says nothing readable
            scroll()
            -- A spell cast by hand meanwhile doesn't answer it.
            wow.fire("UNIT_SPELLCAST_SENT", "player", "Ann", "Hand-1", MOTW)
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
            assert.matches("Couldn't shift back into Travel Form: the game didn't answer.", wow.lastResult(ns), 1,
                true)
            assert.is_nil(keyMacro())
            assert.are.equal("/cast !Travel Form", clickMacro())
        end)

        it("a failure with no reason counts as refused", function()
            ready()
            wow.state.castLatency = 100
            scroll()
            assert.are.equal(1, #formCasts())
            wow.fire("UNIT_SPELLCAST_FAILED", "player", wow.lastCastGuid, TRAVEL)
            wow.advance(ns.BuffButton.SENT_ANSWER_SECONDS + 1)
            assert.matches("Couldn't shift back into Travel Form: the game gave no reason.", wow.lastResult(ns), 1,
                true)
            assert.is_nil(keyMacro())
            assert.are.equal("/cast !Travel Form", clickMacro(), "offered again, for a click")
        end)

        it("a refused shift back doesn't start the 30 seconds again", function()
            ready()
            wow.advance(20)
            wow.state.formRefusals = { [TRAVEL] = "Can only use outside." }
            click()
            assert.is_nil(keyMacro())
            wow.advance(10.5)                      -- 30.5 after the last buff
            ns.BuffButton.Refresh()
            assert.is_false(offersForm())
        end)

        it("the game naming someone else for the shift back changes nothing: it's on you", function()
            ready()
            wow.state.formSentTarget = "Ann"
            scroll()
            assert.are.equal(TRAVEL, form())
            assert.matches("Back in Travel Form.", wow.lastResult(ns), 1, true)
        end)

        it("/friendly status says to click to shift back, with the game's reason", function()
            ready()
            wow.state.formRefusals = { [TRAVEL] = "Can only use outside." }
            scroll()
            assert.matches("buff mode: on, click to shift back (Can only use outside)", ns.BuffMode.StatusLine(), 1, true)
        end)

        it("a shift back with no word from the game is offered again", function()
            ready()
            wow.state.castLatency = 100
            scroll()
            assert.is_nil(clickMacro(), "not while it's being cast")
            wow.advance(ns.BuffButton.SENT_ANSWER_SECONDS + 1)
            assert.matches("No word back on Travel Form", wow.lastResult(ns), 1, true)
            assert.are.equal("/cast !Travel Form", clickMacro())
        end)

        it("a shift back whose cast stopped (you moved) is offered again at once", function()
            ready()
            wow.state.castLatency = 100
            scroll()
            wow.fire("UNIT_SPELLCAST_FAILED_QUIET", "player", wow.lastCastGuid, TRAVEL)
            assert.are.equal("/cast !Travel Form", clickMacro())
            assert.are.equal(clickMacro(), keyMacro())
        end)

        it("a Ghost Wolf shift back cut off with only an interrupt is offered again at once; a buff's isn't touched",
            function()
            boot({ shaman = true, wolfForm = 1, wolfAura = true })
            scrollBuffs()
            wow.state.castLatency = 100
            scroll()
            assert.is_nil(clickMacro())
            local first = wow.lastCastGuid
            wow.fire("UNIT_SPELLCAST_INTERRUPTED", "player", first, WOLF)
            assert.are.equal("/cast !Ghost Wolf", clickMacro())
            assert.are.equal(clickMacro(), keyMacro())
            -- Pressed again and cast: the first press's timeout doesn't
            -- offer it mid-cast.
            wow.advance(5)
            scroll()                               -- 5 seconds after the first
            assert.is_nil(clickMacro())
            -- More word about the first press doesn't end the newer cast.
            wow.fire("UNIT_SPELLCAST_INTERRUPTED", "player", first, WOLF)
            assert.is_nil(clickMacro(), "another interrupt of the first")
            wow.fire("UNIT_SPELLCAST_FAILED", "player", first, WOLF)
            wow.uiError("Interrupted")
            assert.is_nil(clickMacro(), "the first one's refusal")
            wow.advance(ns.BuffButton.SENT_ANSWER_SECONDS - 5 + 1)
            assert.is_nil(clickMacro(), "the first press's 'no word' doesn't end the newer cast")
            -- A buff's cast cut off changes nothing here.
            boot({ form = CAT })
            wow.state.castLatency = 100
            scroll()
            local before = clickMacro()
            wow.fire("UNIT_SPELLCAST_INTERRUPTED", "player", wow.lastCastGuid, MOTW)
            assert.are.equal(before, clickMacro())
            -- Nor with no return at all.
            boot()
            local errors = ns.Diag.Counters().luaErrors or 0
            wow.state.castLatency = 100
            scroll()
            wow.fire("UNIT_SPELLCAST_INTERRUPTED", "player", wow.lastCastGuid, MOTW)
            wow.fire("UNIT_SPELLCAST_FAILED_QUIET", "player", wow.lastCastGuid, MOTW)
            assert.are.equal(errors, ns.Diag.Counters().luaErrors or 0)
        end)

        it("a key held down while the shift back is cast, released once it's offered again, is no refusal",
            function()
            -- The down half finds the button empty (it's being cast) and the
            -- game acts on it; the up half finds it offered again (the cast
            -- was cut off). That press did nothing, and isn't taken as refused.
            boot({ shaman = true, wolfForm = 1, wolfAura = true })
            scrollBuffs()
            wow.state.castLatency = 100
            scroll()
            local key = wow.state.overrides.MOUSEWHEELUP
            wow.pressHalf(_G[key.button], key.mouseButton, true)
            wow.fire("UNIT_SPELLCAST_INTERRUPTED", "player", wow.lastCastGuid, WOLF)
            wow.pressHalf(_G[key.button], key.mouseButton, false)
            wow.advance(ns.BuffButton.SENT_ANSWER_SECONDS + 1)
            assert.is_nil(tostring(wow.lastResult(ns)):find("Couldn't shift back", 1, true))
            assert.are.equal("/cast !Ghost Wolf", keyMacro(), "the key still shifts you back")
        end)

        it("an answer that comes once the return is gone says nothing", function()
            -- No answer at all, and you shift by hand meanwhile.
            ready()
            local errors = ns.Diag.Counters().luaErrors or 0
            wow.state.formRefusals = { [TRAVEL] = "" }
            scroll()
            wow.setForm(3, CAT)
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
            assert.is_nil(tostring(wow.lastResult(ns)):find("shift back", 1, true))
            assert.are.equal(errors, ns.Diag.Counters().luaErrors or 0)
            -- A failure with its reason, after a fight started.
            ready()
            wow.state.castLatency = 100
            scroll()
            wow.enterCombat()
            wow.fire("UNIT_SPELLCAST_FAILED", "player", wow.lastCastGuid, TRAVEL)
            wow.uiError("Interrupted")
            assert.is_nil(tostring(wow.lastResult(ns)):find("shift back", 1, true))
            assert.are.equal(errors, ns.Diag.Counters().luaErrors or 0)
            errors = ns.Diag.Counters().luaErrors or 0
            wow.advance(ns.BuffButton.SENT_ANSWER_SECONDS + 1)
            assert.is_nil(tostring(wow.lastResult(ns)):find("shift back", 1, true))
            assert.are.equal(errors, ns.Diag.Counters().luaErrors or 0)
        end)

        it("an answer for the shift back into one form doesn't touch a newer return to another", function()
            ready()                                -- Travel Form waits
            wow.state.castLatency = 100
            scroll()                               -- its cast goes out
            local travelCast = wow.lastCastGuid
            wow.state.castLatency = 0
            wow.setForm(3, CAT)                    -- by hand: Travel Form's return is gone
            wow.advance(0)
            for _, token in ipairs({ "party1", "party2" }) do wow.state.units[token].auras = {} end
            ns.BuffButton.Refresh()
            scroll()                               -- a buff takes you out of Cat Form
            assert.are.equal(0, form())
            wow.fire("UNIT_SPELLCAST_FAILED", "player", travelCast, TRAVEL)
            wow.uiError("Interrupted")
            scrollBuffs()
            assert.are.equal("/cast !Cat Form", clickMacro())
            assert.are.equal(clickMacro(), keyMacro(), "the new return isn't refused")
        end)

        it("a press in the global cooldown is no refusal: the next scroll shifts you back", function()
            ready()
            wow.state.formRefusals = { [TRAVEL] = "Spell is not ready yet." }
            scroll()
            assert.are.equal(clickMacro(), keyMacro())
            wow.state.formRefusals = nil
            scroll()
            assert.are.equal(TRAVEL, form())
        end)
    end)

    describe("storms (red)", function()
        -- Forms, buffs fading, fights, presses, shifts by hand, the setting,
        -- buff mode, refusals and time at random, for a druid and for a
        -- shaman whose Ghost Wolf takes a moment to cast. Checked from the
        -- simulated client's own state, and at every step:
        --   nothing is cast but in a press;
        --   a form is cast, or offered on the button, only after a press took
        --   you out of that very form, while you're in no form, with no
        --   fight, shift by hand, setting off or buff mode off since, out of
        --   a fight, and within 30 seconds of the last buff cast.
        -- Each way the return is dropped is counted only when it dropped a
        -- standing return and a press followed (where a wrong offer would
        -- show), and every seed must reach each one, shift back at least
        -- once, and see a refused shift back.
        local DRUID_FORMS = { CAT, BEAR, TRAVEL, DIRE }
        local STAGED = { 5, 1, 5, 2, 5, 3, 5, 4 } -- dropOne's ways, in turn
        local REASONS = { "fight", "shift by hand", "setting off", "buff mode off", "30 seconds",
            "shift by hand just after leaving", "shift out long after a refused press" }

        local function storm(seed, shaman)
            random.seed(seed)
            if shaman then boot({ shaman = true, wolfForm = 1, wolfAura = true }) else boot({ form = CAT }) end
            local errors = ns.Diag.Counters().luaErrors or 0
            local left                 -- the form a press took you out of, while the return may stand
            local lastBuff = -math.huge -- when a buff was last cast by a press
            local pendingDrop          -- a drop of a standing return, counted at the next press
            local reach, backs, refused, nextDrop = {}, 0, 0, 0
            local midCast = 0 -- shift backs looked at while still being cast
            local pressed -- whether this step pressed the button
            local refusedAt, refusedIn -- when, and in which form, a press last cast nothing (autoUnshift off)
            local shiftOut, followUp
            for _, reason in ipairs(REASONS) do reach[reason] = 0 end

            local function formNow()
                if shaman then return wow.state.ghostWolf and WOLF or 0 end
                return form()
            end
            local function drop(reason)
                if left then pendingDrop = reason end
                left = nil
            end
            local function shiftInto(spell)
                if shaman then wow.setGhostWolf(true) else wow.setForm(wow.FORM_STANCE[spell], spell) end
            end
            local function otherForm()
                if shaman then return WOLF end
                local spell
                repeat spell = DRUID_FORMS[random.random(1, #DRUID_FORMS)] until spell ~= formNow()
                return spell
            end
            -- The button never offers a form it shouldn't. After 30 seconds it
            -- lets go at its next re-check (a press checks first). Looked at
            -- once each step is over and its frame has passed.
            local function checkArmed()
                local macro = clickMacro()
                if macro and macro:find("^/cast !") then
                    assert.is_truthy(left, "a form offered with none left by a press")
                    assert.is_true(wow.now - lastBuff < ns.BuffButton.RETURN_SECONDS + ns.BuffButton.RECHECK_SECONDS + 0.5,
                        "offered long after the last buff")
                    assert.are.equal("/cast !" .. NAMES[left], macro, "the form offered is the one you left")
                    assert.are.equal(0, formNow(), "offered only while you're in no form")
                    assert.is_falsy(wow.state.inCombat)
                end
            end
            local function press(how)
                if left and wow.now - lastBuff >= ns.BuffButton.RETURN_SECONDS then drop("30 seconds") end
                if pendingDrop then
                    reach[pendingDrop] = reach[pendingDrop] + 1
                    pendingDrop = nil
                end
                local before, cancelled, was = #wow.casts, wow.formsCancelled, formNow()
                pressed = true
                if how == "click" then click() else scroll() end
                local buffCast = false
                for i = before + 1, #wow.casts do
                    local c = wow.casts[i]
                    if c.form then
                        assert.is_truthy(left, "a form cast with no form left by a press")
                        assert.are.equal(left, c.id, "the form cast is the one you left")
                        assert.is_true(wow.now - lastBuff < ns.BuffButton.RETURN_SECONDS)
                        assert.is_nil(c.inCombat)
                        backs = backs + 1
                        left = nil
                        -- Still being cast: the button is looked at now, mid-cast.
                        if (wow.state.formCastSeconds or 0) > 0 then midCast = midCast + 1 end
                    else
                        buffCast = true
                    end
                end
                if (wow.lastResult(ns) or ""):find("Couldn't shift back", 1, true) then refused = refused + 1 end
                if #wow.casts == before and was ~= 0 then refusedAt, refusedIn = wow.now, was end
                if buffCast then
                    lastBuff = wow.now
                    if wow.formsCancelled > cancelled and ns.db.buffBack.fastCastInForm == true then
                        left = was
                        -- Now and then, a shift by hand at once, within the 3 seconds.
                        if random.random(1, 4) == 1 then
                            shiftInto(otherForm())
                            drop("shift by hand just after leaving")
                        end
                    end
                end
            end
            -- A shift out of your form by hand. Long after a press in the
            -- form the game refused, it isn't left for the press.
            function shiftOut()
                if formNow() ~= 0 then
                    local soon = refusedAt and wow.now - refusedAt <= ns.BuffButton.LEAVE_SECONDS
                    if refusedAt and not soon then pendingDrop = "shift out long after a refused press" end
                    local from, at, inIt = refusedIn, refusedAt, formNow()
                    refusedAt, refusedIn = nil, nil
                    if shaman then wow.setGhostWolf(false) else wow.setForm(0) end
                    drop("shift by hand")
                    -- Within LEAVE_SECONDS of a press in this same form, the
                    -- addon can't tell this from the game taking you out for
                    -- the press, and remembers it (docs/forever-facts.md):
                    -- still a form you were in.
                    if soon and from == inIt and ns.db.buffBack.fastCastInForm == true then
                        left, lastBuff = from, math.max(lastBuff, at)
                    end
                end
            end
            -- A few presses, the button looked at after each (a staged drop
            -- shows only once nothing is left to buff).
            function followUp(n)
                for _ = 1, n do
                    press(random.random(1, 3) == 1 and "click" or "key")
                    wearLanded()
                    wow.advance(0)
                    checkArmed()
                end
            end
            -- One of the ways the return is dropped.
            local function dropOne(which)
                if which == 1 then
                    wow.enterCombat()
                    drop("fight")
                    wow.advance(random.random(0, 3))
                    wow.leaveCombat()
                elseif which == 2 then
                    shiftInto(otherForm())
                    drop("shift by hand")
                elseif which == 3 then
                    ns.db.buffBack.fastCastInForm = false
                    drop("setting off")
                    ns.BuffButton.Refresh()
                    ns.db.buffBack.fastCastInForm = true
                elseif which == 4 then
                    slash("buffmode off")
                    drop("buff mode off")
                    wow.advance(0)
                    slash("buffmode on")
                else
                    -- The button lets go at its next re-check; a press checks
                    -- first, so press at once (press() counts the drop).
                    wow.advance(ns.BuffButton.RETURN_SECONDS + random.random(0, 5))
                    press(random.random(1, 2) == 1 and "key" or "click")
                end
            end

            for _ = 1, 700 do
                local before = #wow.casts
                pressed = false
                local r = random.random(1, 26)
                -- Ghost Wolf takes a moment to cast (2.5 seconds here); druid forms are instant.
                wow.state.formCastSeconds = shaman and 2.5 or nil
                if r <= 7 then
                    press("key")
                elseif r <= 9 then
                    press("click")
                elseif r <= 11 then
                    for _, token in ipairs({ "party1", "party2" }) do wow.state.units[token].auras = {} end
                    worn = #wow.landed
                    ns.BuffButton.Refresh()
                elseif r == 12 then
                    shiftInto(otherForm())
                    drop("shift by hand")
                elseif r == 13 then
                    shiftOut()
                elseif r == 23 then
                    -- A buff press in a form the game refuses (autoUnshift off),
                    -- then a shift out by hand well after it, then the buffs.
                    if formNow() ~= 0 then
                        local unshift = wow.state.cvars.autoUnshift
                        wow.state.cvars.autoUnshift = "0"
                        press("key")
                        wow.state.cvars.autoUnshift = unshift
                        wow.advance(ns.BuffButton.LEAVE_SECONDS + 1)
                        shiftOut()
                        followUp(6)
                    end
                elseif r == 14 then
                    dropOne(1)
                elseif r == 15 then
                    wow.advance(random.random(1, 20))
                elseif r == 16 then
                    if random.random(1, 3) == 1 then dropOne(3) end
                elseif r == 17 then
                    if random.random(1, 3) == 1 then dropOne(4) end
                elseif r == 18 then
                    local refusals = {}
                    for _, spell in ipairs(DRUID_FORMS) do refusals[spell] = "Can only use outside." end
                    refusals[WOLF] = "Can only use outside."
                    wow.state.formRefusals = random.random(1, 3) == 1 and refusals or nil
                elseif r <= 21 then
                    -- A standing return, dropped on purpose: each way in turn.
                    if left then
                        -- 30 seconds every other time: it bites only with nothing left to buff.
                        nextDrop = nextDrop % #STAGED + 1
                        dropOne(STAGED[nextDrop])
                        followUp(3)
                    end
                elseif r == 22 then
                    -- Off, the game refuses a buff in a form instead of
                    -- taking you out of it.
                    wow.state.cvars.autoUnshift = random.random(1, 3) == 1 and "0" or "1"
                else
                    wow.advance(random.random(0, 2))
                    wearLanded()
                end
                -- Nothing is cast but in a press.
                if not pressed then assert.are.equal(before, #wow.casts, "a cast without a press") end
                -- The button re-arms on the next frame after a change (a press
                -- re-arms it first anyway): look at it then.
                wow.advance(0)
                checkArmed()
            end
            for _, reason in ipairs(REASONS) do
                assert.is_true(reach[reason] >= 1, "the storm reached: " .. reason)
            end
            assert.is_true(backs >= 1, "the storm shifted back at least once")
            if shaman then assert.is_true(midCast >= 1, "the storm looked at a shift back mid-cast") end
            assert.is_true(refused >= 1, "the storm refused a shift back at least once")
            assert.are.equal(errors, ns.Diag.Counters().luaErrors or 0)
        end

        for _, seed in ipairs({ 494, 495, 502, 515, 520 }) do
            it("druid, seed " .. seed .. ": never casts without a press, and never offers a form you weren't in",
                function() storm(seed, false) end)
        end
        for _, seed in ipairs({ 465, 470, 472, 481, 495 }) do
            it("shaman, Ghost Wolf with a cast time, seed " .. seed .. ": the same", function() storm(seed, true) end)
        end
    end)
end)
