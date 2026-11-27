-- Spec: #452, #459, #461, #544
-- In a druid's form, buff mode's key doesn't cast your buffs (#452, the
-- owner's decision of 17 Nov): the button still shows the buff and a click
-- casts it (the game takes you out of the form), but scrolling never knocks
-- a feral druid out of form. "Fast-cast buffs in form" (off by default) lets
-- the key cast in a form too. Weapon buffs keep #45's choice B. A form or
-- class the game won't say counts as a form. The key presses the button as a
-- button of its own (BuffButton.KEY_BUTTON), whose action is written only
-- when it may cast: no binding changes with the form.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1, THORNS = 9885, 1126, 9910
local INNER_FIRE = 10952
local W = wow.WEAPON
local CAT, TRAVEL, BEAR = 1, 3, 5

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Druid buffs in a form (#452)", function()
    local ns, button

    -- A druid who knows Mark of the Wild and Thorns, in buff mode (opts.noMode:
    -- not), in a party with Ann and Cid, who lack both. opts.form: the form at
    -- the start; opts.db: saved settings; opts.class: another class.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = opts.class or "DRUID"
            state.knownSpells = opts.known or { [MOTW_1] = true, [MOTW] = true, [THORNS] = true }
            state.form = opts.form or 0
            if opts.before then opts.before(state) end
        end })
        button = ns.BuffButton.Frame()
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

    describe("in a form, with the setting off (white)", function()
        for _, form in ipairs({ CAT, BEAR, TRAVEL }) do
            it("form " .. form .. ": scrolling casts no druid buff, and a click on the button does", function()
                boot({ form = form })
                assert.is_truthy(clickMacro(), "the button still offers the buff")
                assert.matches("Mark of the Wild", button.subtitle:GetText(), 1, true)
                assert.is_nil(keyMacro(), "the key has no action")
                for _ = 1, 5 do scroll() end
                assert.are.equal(0, castCount())
                assert.are.equal(form, wow.state.form, "still in the form")
                assert.are.equal(0, wow.formsCancelled)
                click()
                assert.are.equal(1, castCount())
                assert.are.equal(MOTW, wow.casts[1].id)
                assert.are.equal(0, wow.state.form, "the game took you out of the form")
                assert.are.equal(1, wow.formsCancelled, "the game did, not the addon")
                -- The click is a press like any other: its own result shows.
                assert.matches("Gave Mark of the Wild to Ann Vale.", wow.lastResult(ns), 1, true)
            end)
        end

        it("a click in a form the game refuses shows the game's reason, as any press does", function()
            boot({ form = CAT })
            wow.state.castFailures["Ann-Vale"] = "Not enough mana"
            click()
            assert.matches("Couldn't buff Ann Vale: Not enough mana", wow.lastResult(ns), 1, true)
        end)

        it("a scroll that waits is no press: no 'No answer', and the member isn't held back", function()
            boot({ form = CAT })
            ns.db.debug = true
            ns.db.diagLog = {}
            scroll()
            for _, line in ipairs(ns.db.diagLog) do
                assert.is_nil(line:find("pressed: ", 1, true), "no press logged: " .. line)
            end
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
            local lines = table.concat(ns.BuffButton.StatusLines(), "\n")
            assert.matches("last result: Click the button to buff: you're in a form.", lines, 1, true)
            assert.is_nil(lines:find("No answer", 1, true))
            ns.BuffButton.Refresh()
            assert.matches("Ann", button.title:GetText(), 1, true)
            click()
            assert.are.equal("Ann-Vale", wow.casts[1].target)
        end)

        it("the button says the key waits, and why", function()
            boot({ form = CAT })
            assert.matches("click to buff (you're in a form)", button.mode:GetText(), 1, true)
            local lines = table.concat(ns.BuffButton.StatusLines(), "\n")
            assert.matches("buff mode's key waits: you're in a form", lines, 1, true)
            scroll()
            assert.matches("Click the button to buff: you're in a form.", button.result:GetText(), 1, true)
        end)

        it("shifting back lets the key cast again, at once", function()
            boot({ form = CAT })
            scroll()
            assert.are.equal(0, castCount())
            wow.setForm(0)
            wow.advance(0)
            assert.are.equal(clickMacro(), keyMacro())
            assert.matches("MOUSEWHEELUP", button.mode:GetText(), 1, true) -- the key's name, as the client gives it
            assert.matches("buff mode's key presses it too", table.concat(ns.BuffButton.StatusLines(), "\n"), 1, true)
            scroll()
            assert.are.equal(1, castCount())
        end)

        it("shifting into a form stops the key at once, even before any refresh", function()
            boot()
            assert.is_truthy(keyMacro())
            wow.state.form = BEAR -- no event yet: the press itself reads the form
            scroll()
            assert.are.equal(0, castCount())
            assert.are.equal(BEAR, wow.state.form)
            -- The key's action is gone, not left as a macro with no text.
            assert.is_nil(button:GetAttribute(A().keyActionType))
            assert.is_nil(keyMacro())
        end)

        it("buff back's favours wait for a click too", function()
            boot({ solo = true, form = CAT })
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Power Word: Fortitude", spellId = 10938 })
            assert.are.equal(1, ns.Offers.Count())
            ns.BuffButton.Refresh()
            assert.matches("Bob", button.title:GetText(), 1, true)
            scroll()
            assert.are.equal(0, castCount())
            click()
            assert.are.equal(1, castCount())
            assert.are.equal("Bob-Stone", wow.casts[1].target)
            assert.matches("Returned Mark of the Wild to Bob Stone.", button.result:GetText(), 1, true)
        end)

        it("a buff asked for in chat waits for a click too", function()
            boot({ solo = true, form = TRAVEL, db = { buffBack = { requests = true } } })
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
            wow.whisper("thorns pls", "Bob-Stone")
            ns.BuffButton.Refresh()
            assert.matches("asked for Thorns", button.subtitle:GetText(), 1, true)
            scroll()
            assert.are.equal(0, castCount())
            click()
            assert.are.equal(THORNS, wow.casts[1].id)
            assert.matches("Gave Thorns to Bob Stone, who asked for it.", button.result:GetText(), 1, true)
        end)

        it("a weapon buff that uses an item waits for a click in a form, as everywhere (#544)", function()
            for _, fast in ipairs({ false, true }) do
                boot({ solo = true, form = CAT, known = {}, db = { buffBack = { weaponBuffs = true,
                    weaponMain = "wizardOil", soloOwnBuffs = false, fastCastInForm = fast } },
                    before = function(s) s.items = { [W.brilliantWizardOil] = 2 } end })
                assert.are.equal("/use item:20749\n/use 16", clickMacro())
                assert.is_nil(keyMacro(), "fast-cast " .. tostring(fast))
                scroll()
                assert.are.equal(0, #wow.applied, "the key never uses it")
                click()
                assert.are.equal(1, #wow.applied, "a click puts it on: the game takes you out of the form")
            end
        end)

        it("another class's form doesn't hold the key: a priest in Shadowform still casts", function()
            boot({ class = "PRIEST", known = { [INNER_FIRE] = true }, solo = true, form = 1,
                db = { buffBack = { soloOwnBuffs = false } } })
            assert.is_truthy(keyMacro())
            scroll()
            assert.are.equal(1, castCount())
        end)
    end)

    describe("with Fast-cast buffs in form on (white)", function()
        it("scrolling casts in a form, and the game takes you out of it", function()
            boot({ form = CAT, db = { buffBack = { fastCastInForm = true } } })
            assert.are.equal(clickMacro(), keyMacro())
            scroll()
            assert.are.equal(1, castCount())
            assert.are.equal(0, wow.state.form)
            assert.are.equal(1, wow.formsCancelled)
        end)

        it("switching it on from the Buffs tab lets the key cast at once, and off stops it again", function()
            boot({ form = BEAR })
            ns.Options.SelectType(ns.Options.BUFFS_TAB)
            local box = ns.Options.widgets.fastCastInForm
            assert.are.equal("Fast-cast buffs in form", box.label:GetText())
            assert.is_false(box:GetChecked())
            assert.are.equal(ns.BuffsTab.FAST_CAST_TOOLTIP, box.tooltip)
            box:SetChecked(true)
            wow.run(box, "OnClick")
            assert.is_true(ns.db.buffBack.fastCastInForm)
            assert.is_truthy(keyMacro())
            box:SetChecked(false)
            wow.run(box, "OnClick")
            assert.is_false(ns.db.buffBack.fastCastInForm)
            assert.is_nil(keyMacro())
        end)

        it("is off by default, kept in profiles, and found by the options search", function()
            boot()
            assert.is_false(ns.db.buffBack.fastCastInForm)
            ns.db.buffBack.fastCastInForm = true
            assert.is_true(ns.Profiles.Snapshot(ns.db).buffBack.fastCastInForm)
            local found = false
            for _, entry in ipairs(ns.OptionsIndex.Find("fast cast form")) do
                if entry.name == "Fast-cast buffs in form" then found = true end
            end
            assert.is_true(found)
        end)
    end)

    describe("what can't be read (black)", function()
        it("a secret form means the key waits; a click still casts", function()
            boot({ form = 0, before = function(s) s.selfSecrets.form = true end })
            assert.is_truthy(clickMacro())
            assert.is_nil(keyMacro())
            assert.matches("can't tell whether you're in a form", button.mode:GetText(), 1, true)
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
                assert.matches("can't tell whether you're in a form", button.mode:GetText(), 1, true)
                scroll()
                assert.are.equal(0, castCount(), tostring(answer))
            end
        end)

        it("a class that can't be read means the key waits", function()
            boot()
            local real = _G.UnitClass
            _G.UnitClass = function(unit)
                if unit == "player" then return wow.secret("Druid"), wow.secret("DRUID") end
                return real(unit)
            end
            ns.BuffButton.Refresh()
            scroll()
            _G.UnitClass = real
            assert.are.equal(0, castCount())
        end)

        it("a damaged setting reads as off", function()
            boot({ form = CAT })
            ns.db.buffBack.fastCastInForm = "yes"
            ns.BuffButton.Refresh()
            assert.is_nil(keyMacro())
        end)

        it("the button never holds an action a key press could fall back on", function()
            boot({ form = CAT })
            for _, name in ipairs({ "type", "*type*", "macrotext", "*macrotext*", "type-BuffModeKey",
                A().keyActionType, A().keyMacroText }) do
                assert.is_nil(button:GetAttribute(name), name)
            end
            assert.are.equal("macro", button:GetAttribute(A().leftButtonActionType), "a click still casts")
            -- The key is lent as its own button, never as a left click.
            local lent = wow.state.overrides.MOUSEWHEELUP
            assert.are.equal(ns.BuffButton.KEY_BUTTON, lent.mouseButton)
        end)
    end)

    describe("storms (red)", function()
        -- Form changes, scrolls, clicks, fights, favours, aura updates and the
        -- setting, at random. Checked from the simulated client's own state,
        -- as each press happens: a scroll in a form (or with the form
        -- unreadable), with the setting off, never casts and never ends the
        -- form; and no binding or secure attribute ever changes in a fight.
        -- Each hazard is counted only where it bites (out of a fight, a buff
        -- armed, the setting off), and every seed must reach each one.
        local HAZARDS = { "cat", "bear", "travel", "unreadable in caster form", "unreadable in a form" }
        local FORM_NAME = { [CAT] = "cat", [BEAR] = "bear", [TRAVEL] = "travel" }
        -- Strangers who buff you (a player's name has letters only).
        local STRANGERS = { "Bob", "Dot", "Eve", "Fay", "Gil", "Hal", "Ivy" }
        local SURNAMES = { "Stone", "Brook", "Vale", "Marsh", "Holt" }

        local function hazardOf()
            if wow.state.selfSecrets.form == true then
                return wow.state.form == 0 and "unreadable in caster form" or "unreadable in a form"
            end
            return FORM_NAME[wow.state.form]
        end

        for _, seed in ipairs({ 452, 7, 1117, 2026, 31337 }) do
            it("seed " .. seed .. ": never casts on a scroll in a form with the setting off, "
                .. "and never changes a binding or the button in a fight", function()
                random.seed(seed)
                boot()
                local errors = ns.Diag.Counters().luaErrors or 0
                local inFight, fightRefreshes, fightOffers = {}, 0, 0
                local realSet, realClear = _G.SetOverrideBindingClick, _G.ClearOverrideBindings
                _G.SetOverrideBindingClick = function(...)
                    if wow.state.inCombat then inFight[#inFight + 1] = "SetOverrideBindingClick" end
                    return realSet(...)
                end
                _G.ClearOverrideBindings = function(...)
                    if wow.state.inCombat then inFight[#inFight + 1] = "ClearOverrideBindings" end
                    return realClear(...)
                end
                local realAttr = button.SetAttribute
                button.SetAttribute = function(self, ...)
                    if wow.state.inCombat then inFight[#inFight + 1] = "SetAttribute" end
                    return realAttr(self, ...)
                end
                local realRefresh = ns.BuffButton.Refresh
                ns.BuffButton.Refresh = function(...)
                    if wow.state.inCombat then
                        fightRefreshes = fightRefreshes + 1
                        if ns.Offers.Current() then fightOffers = fightOffers + 1 end
                    end
                    return realRefresh(...)
                end
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
                        local before, cancelled, form = castCount(), wow.formsCancelled, wow.state.form
                        scroll()
                        -- The press re-armed the button: a buff it holds now is
                        -- what the scroll would have cast.
                        local armed = not fight and clickMacro() ~= nil
                        if hazard and not fast then
                            assert.are.equal(before, castCount(), "seed " .. seed .. ": a scroll cast, " .. hazard)
                            assert.are.equal(cancelled, wow.formsCancelled, "seed " .. seed)
                            assert.are.equal(form, wow.state.form, "seed " .. seed)
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
                        wow.setForm(({ 0, CAT, BEAR, TRAVEL })[random.random(1, 4)])
                    elseif roll == 9 then
                        wow.state.selfSecrets.form = random.random() < 0.4
                        wow.fire("UPDATE_SHAPESHIFT_FORM")
                    elseif roll == 10 and not wow.state.inCombat and random.random() < 0.5 then
                        wow.enterCombat()
                    elseif roll == 10 and wow.state.inCombat and random.random() < 0.5 then
                        -- Fights are short: out again soon after.
                        wow.leaveCombat()
                    elseif roll == 11 or roll == 10 then
                        -- A stranger buffs you, in a fight or out (often just as
                        -- one starts): a favour the button would arm for, if
                        -- anything let it in a fight.
                        strangers = strangers + 1
                        local first = STRANGERS[strangers % #STRANGERS + 1]
                        local last = SURNAMES[math.floor(strangers / #STRANGERS) % #SURNAMES + 1]
                        wow.addUnit("nameplate1", { name = first, surname = last, id = first .. "-" .. last,
                            class = "WARRIOR" })
                        wow.gainBuff({ sourceUnit = "nameplate1", name = "Power Word: Fortitude", spellId = 10938 })
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
                _G.SetOverrideBindingClick, _G.ClearOverrideBindings = realSet, realClear
                button.SetAttribute = realAttr
                ns.BuffButton.Refresh = realRefresh
                assert.are.same({}, inFight, "seed " .. seed)
                assert.are.equal(errors, ns.Diag.Counters().luaErrors or 0, "seed " .. seed .. ": no Lua error")
                -- The storm reached every hazard where it bites, and the button
                -- was asked to re-arm in fights, so the fight check could fail.
                for _, h in ipairs(HAZARDS) do
                    assert.is_true(reached[h] >= 2, ("seed %d: %s reached %d times"):format(seed, h, reached[h]))
                end
                assert.is_true(fightRefreshes > 0, "seed " .. seed .. ": no re-arm was asked for in a fight")
                assert.is_true(fightOffers > 0, "seed " .. seed .. ": nothing was owed in a fight")
                assert.is_true(keyCasts > 0 and clicked > 0, ("seed %d: key casts %d, clicks %d"):format(seed,
                    keyCasts, clicked))
            end)
        end
    end)
end)
