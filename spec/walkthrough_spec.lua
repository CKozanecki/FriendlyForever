-- Spec: #47, #169, #330
-- The Start here page and the walkthrough: the page's controls change the
-- same settings as their full pages, the walkthrough reaches buff mode's key
-- and triggers, skipping or finishing it is remembered, it can be replayed,
-- and both are safe with damaged settings and in fights.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local BUTTON_BINDING = "CLICK FriendlyForeverBuffButton:LeftButton"
-- The walkthrough's state once it's been finished or skipped.
local V0 = wow.boot().Config.WALKTHROUGH_VERSION  -- the shipped walkthrough version
local SEEN = { seen = V0, firstRun = false }

local function printedHas(fragment)
    for _, line in ipairs(wow.printed) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

-- The saved settings, less the walkthrough's own state and the ledger,
-- which isn't a setting (Config.lua) and starts a new day when shown.
local function settingsBut(db)
    local copy = {}
    for key, value in pairs(db) do
        if key ~= "walkthrough" and key ~= "ledger" then copy[key] = value end
    end
    return copy
end

describe("Start here", function()
    local ns, w

    local function boot(opts)
        ns = wow.boot(opts)
        w = ns.Options.widgets.start
    end

    before_each(function() boot() end)

    local function shown(fragment)
        ns.Options.FillStart()
        for _, key in ipairs({ "enabled", "thanks", "nameplates", "buttonKey", "buffModeKey" }) do
            if w[key]:GetText():find(fragment, 1, true) then return true end
        end
        return false
    end

    it("is the first page listed under Friendly Forever, and fills when shown", function()
        local names = {}
        for _, sub in ipairs(wow.settings.subcategories) do names[#names + 1] = sub.name end
        assert.are.same({ "Start here", "General", "Favour Ledger" }, names)
        assert.are.equal(ns.Options.StartPage(), _G.FriendlyForeverStartPage)
        ns.db.enabled = false
        wow.run(ns.Options.StartPage(), "OnShow")
        assert.is_truthy(w.enabled:GetText():find("Friendly Forever is off", 1, true))
    end)

    describe("shows the settings that apply, as they're saved (white)", function()
        it("the addon's switch, and follows it when it changes elsewhere", function()
            assert.is_true(shown("Friendly Forever is on."))
            _G.SlashCmdList.FRIENDLYFOREVER("off")
            assert.is_truthy(w.enabled:GetText():find("Friendly Forever is off", 1, true), "refreshed by the change")
        end)

        it("how you thank, and that Buff Thanks is off when it is", function()
            for _, style in ipairs(ns.Options.THANK_STYLES) do
                ns.db.buff.thankStyle = style
                assert.is_true(shown("you thank people who buff you with " .. ns.Options.THANK_STYLE_TEXT[style] .. "."),
                    style)
            end
            ns.db.buff.enabled = false
            assert.is_true(shown("Buff Thanks is off"))
        end)

        it("friendly nameplates, on or off", function()
            assert.is_true(shown("Friendly player nameplates are on"))
            wow.state.cvars.nameplateShowFriendlyPlayers = "0"
            assert.is_true(shown("Friendly player nameplates are off"))
        end)

        it("the buff-back button's key from Key Bindings, or that it has none, and buff mode's key", function()
            assert.is_true(shown("Buff-back button key: none yet"))
            wow.state.bindings[""] = BUTTON_BINDING
            assert.is_true(shown("Buff-back button key: none yet"), "an empty key is none")
            wow.state.bindings[""] = nil
            wow.state.bindings.F7 = BUTTON_BINDING
            wow.state.bindings.F2 = "TOGGLEBACKPACK"
            assert.is_true(shown("Buff-back button key: F7 (Key Bindings > AddOns)."))
            assert.is_true(shown("Buff mode key: MOUSEWHEELUP."))
            _G.SlashCmdList.FRIENDLYFOREVER("buffmode key mousewheeldown")
            assert.is_true(shown("Buff mode key: MOUSEWHEELDOWN."))
        end)

        it("links to every other page", function()
            wow.run(w.openGeneral, "OnClick")
            assert.are.equal("General", wow.settings.opened)
            wow.run(w.openLedger, "OnClick")
            assert.are.equal("Favour Ledger", wow.settings.opened)
            wow.run(w.openMessages, "OnClick")
            assert.are.equal(4242, wow.settings.opened)
        end)

        it("has no control that changes a setting: only its links and the walkthrough's button", function()
            local page = ns.Options.StartPage()
            local area = page.content
            local buttons = {}
            for _, frame in ipairs(wow.frames) do
                local parent = frame.parent
                if (parent == page or parent == area) and frame.kind ~= "FontString" and frame.kind ~= "ScrollFrame"
                    and frame ~= area then
                    assert.are.equal("Button", frame.kind, "a " .. frame.kind .. " on Start here")
                    buttons[#buttons + 1] = frame
                end
            end
            assert.are.equal(4, #buttons)
            local before = ns.Util.DeepCopy(settingsBut(ns.db))
            for _, button in ipairs(buttons) do wow.run(button, "OnClick") end
            ns.Walkthrough.Skip()
            assert.are.same(before, settingsBut(ns.db))
        end)
    end)
end)

describe("The walkthrough", function()
    local ns, tour

    local function boot(opts)
        opts = opts or {}
        opts.walkthrough = true
        ns = wow.boot(opts)
        tour = ns.Walkthrough.Frame()
    end

    local function stepTitled(fragment)
        for i, step in ipairs(ns.Walkthrough.STEPS) do
            if step.title:find(fragment, 1, true) then return i end
        end
        error("no step titled " .. fragment)
    end

    local function goTo(index)
        while ns.Walkthrough.Step() < index do wow.run(tour.next, "OnClick") end
    end

    -- Whether the window is showing a what's-new run, from its title.
    local function whatsNewShown()
        return tour.title:GetText():find("What's new: ", 1, true) == 1
    end
    -- A later release's code: the walkthrough at `version`, with one new
    -- step for each version above 1, spliced in before "That's it". Used as
    -- opts.afterLoad.
    local opened = {}  -- the versions of the fake steps that opened their page, in order
    local function release(version)
        return function(loaded)
            opened = {}
            local steps = loaded.Walkthrough.STEPS
            local closing = table.remove(steps)
            for v = V0 + 1, version do
                steps[#steps + 1] = { since = v, title = "New " .. v, text = function() return "text " .. v end,
                    open = function() opened[#opened + 1] = v end }
            end
            steps[#steps + 1] = closing
            loaded.Config.WALKTHROUGH_VERSION = version
        end
    end
    local A, B = V0 + 1, V0 + 2  -- the versions two later releases add a step each at
    local function bootAt(version, db)
        boot({ db = db, afterLoad = release(version) })
    end
    -- The titles of a run in order, by stepping to its end with Next. Leaves
    -- it finished.
    local function runTitles()
        local out = {}
        while ns.Walkthrough.Step() do
            out[#out + 1] = tour.title:GetText()
            wow.run(tour.next, "OnClick")
        end
        return out
    end

    describe("on a first install", function()
        before_each(function() boot() end)

        it("starts at login, and the chat message points to Start here", function()
            assert.is_true(tour:IsShown())
            assert.are.equal(1, ns.Walkthrough.Step())
            assert.are.same({ seen = 0, firstRun = true }, ns.db.walkthrough)
            assert.is_true(printedHas("Esc > Options > AddOns > Friendly Forever > Start here"))
            assert.is_false(tour.back:IsShown())
            assert.are.equal("Show me around", tour.next:GetText())
            wow.run(tour.back, "OnClick")
            assert.are.equal(1, ns.Walkthrough.Step(), "nothing before the first step")
        end)

        it("sizes its scrolling text area to each step's text, shown from the top", function()
            tour.stepText.GetStringHeight = function() return 90 end
            tour.scroll.verticalScroll = 50
            wow.run(tour.next, "OnClick")
            assert.are.equal(98, tour.body.height)
            assert.are.equal(0, tour.scroll:GetVerticalScroll())
            assert.are.equal("2 of " .. #ns.Walkthrough.STEPS, tour.count:GetText())
            assert.are.equal(ns.Walkthrough.STEPS[2].title, tour.title:GetText())
        end)

        it("reaches buff mode's key and its triggers, each shown with its switch (white)", function()
            goTo(stepTitled("its key"))
            assert.are.equal(4242, wow.settings.opened)
            assert.are.equal("buffBack", ns.Options.CurrentType())
            assert.is_true(ns.Options.widgets.buffModeKey:IsShown())
            assert.is_truthy(tour.stepText:GetText():find("MOUSEWHEELUP", 1, true))

            ns.db.buffBack.autoOnDeath = false
            goTo(stepTitled("turns on and off"))
            assert.are.equal("buffBack", ns.Options.CurrentType())
            assert.is_true(ns.Options.widgets.autoHeader:IsShown())
            local text = tour.stepText:GetText()
            for _, field in ipairs(ns.Options.AUTO_SWITCHES) do
                assert.are.equal(ns.Options.AUTO_TEXT[field], ns.Options.widgets.auto[field].label:GetText(),
                    "the walkthrough names each switch as its checkbox does")
                local state = ns.db.buffBack[field] and "on" or "off"
                local shown = ns.Colours.Text(state == "on" and "good" or "bad", state)
                assert.is_truthy(text:find(ns.Options.AUTO_TEXT[field] .. ": " .. shown, 1, true),
                    field .. " shown as " .. state)
            end
        end)

        it("opens each step's page: Buff Back, Buff Thanks, Guild Join, then Start here", function()
            local seen = {}
            while ns.Walkthrough.Step() < #ns.Walkthrough.STEPS do
                wow.run(tour.next, "OnClick")
                seen[#seen + 1] = wow.settings.opened == 4242 and ns.Options.CurrentType() or wow.settings.opened
            end
            assert.are.same({ "buffBack", "buffBack", "buffBack", "buff", "guildJoin", "Start here" }, seen)
            assert.are.equal("Finish", tour.next:GetText())
            assert.is_false(tour.skip:IsShown())
            wow.run(tour.back, "OnClick")
            assert.are.equal(#ns.Walkthrough.STEPS - 1, ns.Walkthrough.Step())
            assert.are.equal("guildJoin", ns.Options.CurrentType())
        end)

        it("scrolls the panel to the step's rows, within its range, now and once laid out", function()
            local w = ns.Options.widgets
            w.content.top, w.autoHeader.top, w.scroll.scrollRange = 1000, 400, 2000
            goTo(stepTitled("turns on and off"))
            assert.are.equal(588, w.scroll:GetVerticalScroll())
            w.autoHeader.top = 300
            wow.advance(0)
            assert.are.equal(688, w.scroll:GetVerticalScroll(), "again on the next frame")
            w.scroll.scrollRange = 500
            wow.run(tour.back, "OnClick")
            wow.run(tour.next, "OnClick")
            assert.are.equal(500, w.scroll:GetVerticalScroll(), "never past the end")
            wow.run(tour.next, "OnClick")
            assert.are.equal(0, w.scroll:GetVerticalScroll(), "a row with no edges yet: the top")
        end)

        it("changes no setting, forward and back, until it's finished or skipped", function()
            local before = ns.Util.DeepCopy(settingsBut(ns.db))
            goTo(#ns.Walkthrough.STEPS)
            while ns.Walkthrough.Step() > 1 do wow.run(tour.back, "OnClick") end
            assert.are.same(before, settingsBut(ns.db))
        end)

        it("finishing it is remembered, and it doesn't start at the next login", function()
            goTo(#ns.Walkthrough.STEPS)
            wow.run(tour.next, "OnClick")
            assert.is_false(tour:IsShown())
            assert.is_nil(ns.Walkthrough.Step())
            assert.are.same(SEEN, ns.db.walkthrough)
            local db = ns.db
            boot({ db = db })
            assert.is_false(tour:IsShown())
            assert.is_false(printedHas("Start here"))
        end)

        it("its window's close button skips it, remembered like the Skip button", function()
            goTo(2)
            wow.run(tour.CloseButton, "OnClick")
            assert.is_false(tour:IsShown())
            assert.are.same(SEEN, ns.db.walkthrough)
            assert.is_true(ns.db.enabled, "and turns the addon on, as skipping does")
            assert.is_false(ns.Walkthrough.IsPending())
            local db = ns.db
            boot({ db = db })
            assert.is_false(tour:IsShown())
        end)

        it("skipping it is remembered, and it doesn't start at the next login", function()
            goTo(3)
            wow.run(tour.skip, "OnClick")
            assert.is_false(tour:IsShown())
            assert.are.same(SEEN, ns.db.walkthrough)
            local db = ns.db
            boot({ db = db })
            assert.is_false(tour:IsShown())
        end)

        it("can be replayed from Start here, after being skipped or finished, changing no setting", function()
            wow.run(tour.skip, "OnClick")
            for _ = 1, 2 do
                local before = ns.Util.DeepCopy(ns.db)
                before.ledger = nil
                wow.run(ns.Options.widgets.start.tour, "OnClick")
                assert.is_true(tour:IsShown())
                assert.are.equal(1, ns.Walkthrough.Step())
                goTo(stepTitled("its key"))
                assert.are.equal("buffBack", ns.Options.CurrentType())
                goTo(#ns.Walkthrough.STEPS)
                wow.run(tour.next, "OnClick")
                local after = ns.Util.DeepCopy(ns.db)
                after.ledger = nil
                assert.are.same(before, after)
            end
        end)
    end)

    describe("first run, and players who already use the addon (white)", function()
        it("on a new install, the addon is off until it's finished, and finishing turns it on", function()
            boot()
            assert.is_false(ns.db.enabled)
            assert.is_true(printedHas("Friendly Forever is off until you finish or skip its walkthrough"))
            assert.is_truthy(tour.stepText:GetText():find("either turns it on", 1, true))
            goTo(#ns.Walkthrough.STEPS)
            assert.is_truthy(tour.stepText:GetText():find("Finish turns Friendly Forever on.", 1, true))
            assert.is_false(ns.db.enabled, "still off at the last step")
            wow.run(tour.next, "OnClick")
            assert.is_true(ns.db.enabled)
            assert.is_true(printedHas("enabled"))
            assert.is_true(ns.BuffTracker.Watching(), "the addon really is on")
        end)

        it("on a new install, skipping turns it on too", function()
            boot()
            wow.run(tour.skip, "OnClick")
            assert.is_true(ns.db.enabled)
            assert.are.same(SEEN, ns.db.walkthrough)
        end)

        it("during first run, /friendly on and the main panel's switch still work, and are the player's choice", function()
            boot()
            _G.SlashCmdList.FRIENDLYFOREVER("on")
            assert.is_true(ns.db.enabled)
            assert.is_false(ns.Walkthrough.FirstRun())
            assert.is_true(tour:IsShown(), "the walkthrough carries on")
            boot()
            ns.Options.widgets.master:SetChecked(true)
            wow.run(ns.Options.widgets.master, "OnClick")
            assert.is_true(ns.db.enabled)
            ns.Options.widgets.master:SetChecked(false)
            wow.run(ns.Options.widgets.master, "OnClick")
            wow.run(tour.skip, "OnClick")
            assert.is_false(ns.db.enabled, "switched off by hand: skipping leaves it off")
            assert.are.same(SEEN, ns.db.walkthrough)
        end)

        it("shows once to someone already using the addon, and finishing or skipping changes no setting", function()
            for _, finish in ipairs({ "next", "skip" }) do
                boot({ db = { buff = { thankStyle = "whisper" } } })
                assert.is_true(tour:IsShown())
                assert.is_true(ns.db.enabled)
                assert.is_true(printedHas("new: a short walkthrough of the main settings."))
                assert.is_falsy(tour.stepText:GetText():find("is off until", 1, true))
                local before = ns.Util.DeepCopy(settingsBut(ns.db))
                if finish == "next" then goTo(#ns.Walkthrough.STEPS) end
                wow.run(tour[finish], "OnClick")
                assert.are.same(before, settingsBut(ns.db), finish)
                assert.are.same(SEEN, ns.db.walkthrough)
                local db = ns.db
                boot({ db = db })
                assert.is_false(tour:IsShown(), "only once")
            end
        end)

        it("leaves someone who switched the addon off before it existed switched off", function()
            boot({ db = { enabled = false } })
            assert.is_true(tour:IsShown())
            wow.run(tour.skip, "OnClick")
            assert.is_false(ns.db.enabled)
        end)
    end)

    -- Damaged states: what a file damaged by another addon, a bad /run or
    -- an editor could hold instead of { seen = <0..1>, firstRun = <bool> }.
    local DAMAGED = { 42, "new", "done", true, {}, { "seen" }, { seen = "1" }, { seen = -1 }, { seen = 1.5 },
        { seen = V0 + 1 }, { seen = 0 / 0 }, { seen = math.huge }, { seen = -math.huge } }
    -- A damaged first-run mark: never a first run, so never a switch turned on.
    local DAMAGED_MARK = { { seen = 0, firstRun = "yes" }, { seen = 0, firstRun = 1 }, { seen = 0, firstRun = {} } }

    describe("a damaged or missing walkthrough state (black)", function()
        it("never leaves the addon off for a player who finished or skipped it; damage shows everything once", function()
            for _, damaged in ipairs(DAMAGED) do
                boot()
                wow.run(tour.skip, "OnClick")
                local db = ns.db
                db.walkthrough = damaged
                boot({ db = db })
                assert.is_true(ns.db.enabled, tostring(damaged))
                assert.is_true(tour:IsShown(), tostring(damaged))
                assert.is_false(ns.Walkthrough.FirstRun())
                assert.is_false(whatsNewShown(), "a damaged version isn't a what's-new run: every step")
                assert.are.equal(#ns.Walkthrough.STEPS, ns.Walkthrough.Count())
                wow.run(tour.skip, "OnClick")
                assert.is_true(ns.db.enabled, tostring(damaged))
                assert.are.same(SEEN, ns.db.walkthrough, "and finishing heals it")
                local healed = ns.db
                boot({ db = healed })
                assert.is_false(tour:IsShown(), "once")
            end
        end)

        it("never switches off a player already using the addon, missing or damaged", function()
            for _, damaged in ipairs(DAMAGED) do
                boot({ db = { enabled = true, walkthrough = damaged } })
                assert.is_true(ns.db.enabled, tostring(damaged))
                assert.is_true(tour:IsShown(), "a damaged state is shown once")
                wow.run(tour.skip, "OnClick")
                assert.is_true(ns.db.enabled, tostring(damaged))
            end
            boot({ db = { enabled = true } })
            assert.is_true(tour:IsShown(), "missing: shown once")
            wow.run(tour.skip, "OnClick")
            assert.is_true(ns.db.enabled)
        end)

        it("never switches on an addon the player switched off: damage isn't a first run", function()
            for _, damaged in ipairs(DAMAGED) do
                boot({ db = { enabled = false, walkthrough = damaged } })
                assert.is_false(ns.Walkthrough.FirstRun())
                assert.is_false(ns.db.enabled, tostring(damaged))
                assert.is_true(tour:IsShown(), tostring(damaged))
                wow.run(tour.skip, "OnClick")
                assert.is_false(ns.db.enabled, "skipping a damaged state's walkthrough doesn't switch it on")
            end
            for _, damaged in ipairs(DAMAGED_MARK) do
                boot({ db = { enabled = false, walkthrough = damaged } })
                assert.is_true(tour:IsShown(), "not yet seen: shown")
                assert.is_false(ns.Walkthrough.FirstRun(), tostring(damaged.firstRun))
                wow.run(tour.skip, "OnClick")
                assert.is_false(ns.db.enabled, "a damaged first-run mark doesn't switch it on")
            end
        end)

        it("a first run already seen isn't a first run, and damage mid-session heals at the next login", function()
            boot({ db = { enabled = false, walkthrough = { seen = V0, firstRun = true } } })
            assert.is_false(tour:IsShown())
            assert.is_false(ns.db.enabled, "seen, so its switch is the player's")
            wow.run(ns.Options.widgets.start.tour, "OnClick")
            goTo(#ns.Walkthrough.STEPS)
            wow.run(tour.next, "OnClick")
            assert.is_false(ns.db.enabled, "and taking it again doesn't switch it on")
            -- Not yet seen, with no first-run mark: shown, but the switch is left alone.
            boot({ db = { enabled = false, walkthrough = { seen = 0 } } })
            assert.is_true(tour:IsShown())
            wow.run(tour.skip, "OnClick")
            assert.is_false(ns.db.enabled, "only a first run marked true turns it on")
            boot()
            ns.db.walkthrough = "broken"
            ns.Walkthrough.Start()
            wow.run(tour.skip, "OnClick")
            assert.is_false(ns.db.enabled, "damaged mid-session: not a first run, so skipping leaves it off")
            assert.are.same(SEEN, ns.db.walkthrough)
            assert.are.same({}, wow.errors)
        end)
    end)

    -- Red: storms of logins, each with random damage to the walkthrough's
    -- state and the addon's switch (never a deliberate false: damage that
    -- reads as a choice isn't damage), and the walkthrough finished, skipped,
    -- interrupted by a fight or left alone. The invariants are worked out
    -- from the storm's own record of what the player did, not from the
    -- addon: once they have finished or skipped it, or if they were already
    -- using the addon, it is on at every login after.
    describe("storms of damage between logins (red)", function()
        local SWITCH_DAMAGE = { "on", 1, {}, 0 / 0 }
        -- What the storms reached, over every seed (checked last).
        local reached = { newFinished = 0, newSkipped = 0, damagedAfterDone = 0, switchDamagedAfterDone = 0,
            fightResumed = 0 }

        for seed = 1, 40 do
            it("keeps the addon on for a player who finished, skipped or already used it (seed " .. seed .. ")", function()
                random.seed(seed)
                -- A small seed's first draws are always small: skip a few.
                for _ = 1, 5 do random.random() end
                -- Half the storms start as a new install, half as a player
                -- already using the addon.
                local existing = seed % 2 == 0
                local db = existing and { enabled = true } or nil
                local done = existing
                -- Damage to a new install's state before it was finished loses
                -- its first run (#169: damage is never a first run), so
                -- finishing no longer switches the addon on.
                local lost = false
                for login = 1, 8 do
                    if db and random.random(3) == 1 then
                        db.walkthrough = DAMAGED[random.random(#DAMAGED)]
                        if done then reached.damagedAfterDone = reached.damagedAfterDone + 1 else lost = true end
                    end
                    if db and random.random(4) == 1 then
                        db.enabled = SWITCH_DAMAGE[random.random(#SWITCH_DAMAGE)]
                        if done then reached.switchDamagedAfterDone = reached.switchDamagedAfterDone + 1 end
                    end
                    boot({ db = db })
                    local where = ("seed %d, login %d"):format(seed, login)
                    if done then assert.is_true(ns.db.enabled, where) end
                    local action = random.random(4)
                    if tour:IsShown() then
                        local new = not done
                        if action == 1 then
                            goTo(#ns.Walkthrough.STEPS)
                            wow.run(tour.next, "OnClick")
                            done = not lost
                            if new and done then reached.newFinished = reached.newFinished + 1 end
                        elseif action == 2 then
                            wow.run(tour.skip, "OnClick")
                            done = not lost
                            if new and done then reached.newSkipped = reached.newSkipped + 1 end
                        elseif action == 3 then
                            wow.enterCombat()
                            wow.leaveCombat()
                            if tour:IsShown() then reached.fightResumed = reached.fightResumed + 1 end
                        end
                    end
                    if done then assert.is_true(ns.db.enabled, where .. ", after") end
                    assert.are.same({}, wow.errors, where)
                    db = ns.Util.DeepCopy(ns.db)
                end
            end)
        end

        it("reached every case it's for: new installs finished and skipped, damage after, fights", function()
            for case, count in pairs(reached) do assert.is_true(count > 0, case .. " never happened") end
        end)
    end)

    -- What's new (#169): steps record the version they were added in, and a
    -- player who finished an older version sees only the newer steps.
    describe("what's new after an update (white)", function()
        local FINISHED = { seen = V0, firstRun = false }

        it("every step knows the version it was added in, and the version is the latest of them", function()
            boot()
            local latest, inOrder = 0, 0
            for i, info in ipairs(ns.Walkthrough.STEPS) do
                assert.is_true(type(info.since) == "number" and info.since == math.floor(info.since)
                    and info.since >= 1, info.title)
                latest = math.max(latest, info.since)
                -- Steps are in the order they were added, but for the closing
                -- "That's it" (the last), which stays last.
                if i < #ns.Walkthrough.STEPS then
                    assert.is_true(info.since >= inOrder, "in the order they were added: " .. info.title)
                    inOrder = info.since
                end
            end
            assert.are.equal(ns.Config.WALKTHROUGH_VERSION, latest,
                "a release that adds a step raises Config.WALKTHROUGH_VERSION to match")
        end)

        it("a new player sees every step, with no 'what's new' title", function()
            bootAt(B, nil)
            assert.is_false(ns.Walkthrough.WhatsNew())
            assert.are.equal(#ns.Walkthrough.STEPS, ns.Walkthrough.Count())
            local titles = runTitles()
            assert.are.equal("Welcome to Friendly Forever", titles[1])
            assert.are.equal(#ns.Walkthrough.STEPS, #titles)
            assert.is_false(titles[#titles]:find("What's new", 1, true) ~= nil)
        end)

        it("a player who finished version 1 sees only the steps added since, introduced as what's new", function()
            bootAt(B, { enabled = true, walkthrough = FINISHED })
            assert.is_true(tour:IsShown())
            assert.is_true(ns.Walkthrough.WhatsNew())
            assert.is_true(printedHas("what's new in Friendly Forever: 2 new steps"))
            assert.is_true(printedHas("Start here"))
            assert.are.equal("1 of 2", tour.count:GetText())
            assert.are.equal("What's new: New " .. A, tour.title:GetText())
            assert.are.equal("Next", tour.next:GetText(), "the welcome's button isn't on a new step")
            assert.is_false(tour.back:IsShown())
            assert.is_true(tour.skip:IsShown())
            wow.run(tour.next, "OnClick")
            assert.are.equal("What's new: New " .. B, tour.title:GetText())
            assert.are.equal("2 of 2", tour.count:GetText())
            assert.are.equal("Finish", tour.next:GetText())
            assert.is_false(tour.skip:IsShown())
            wow.run(tour.back, "OnClick")
            assert.are.equal("1 of 2", tour.count:GetText())
        end)

        it("each step of a what's-new run opens its own page, and no shipped step's", function()
            bootAt(B, { enabled = true, walkthrough = FINISHED })
            assert.are.same({ A }, opened)
            wow.run(tour.next, "OnClick")
            assert.are.same({ A, B }, opened)
            assert.is_nil(wow.settings.opened, "none of the shipped steps' pages")
        end)

        it("StepsSince gives every step for a version that is no number", function()
            boot()
            for _, bad in ipairs({ "x", {}, true }) do
                assert.are.equal(#ns.Walkthrough.STEPS, #ns.Walkthrough.StepsSince(bad), tostring(bad))
            end
            assert.are.equal(#ns.Walkthrough.STEPS, #ns.Walkthrough.StepsSince(nil))
            assert.are.equal(0, #ns.Walkthrough.StepsSince(V0))
        end)

        it("a player who finished version 2 sees only the one step added after it", function()
            bootAt(B, { enabled = true, walkthrough = { seen = A, firstRun = false } })
            assert.are.equal(1, ns.Walkthrough.Count())
            assert.is_true(printedHas("1 new step in the walkthrough"))
            assert.are.same({ "What's new: New " .. B }, runTitles())
        end)

        it("an up-to-date player sees nothing", function()
            bootAt(B, { enabled = true, walkthrough = { seen = B, firstRun = false } })
            assert.is_false(tour:IsShown())
            assert.is_nil(ns.Walkthrough.Step())
            assert.is_false(printedHas("Start here"))
            assert.are.same({ seen = B, firstRun = false }, ns.db.walkthrough)
        end)

        it("finishing it saves the current version and doesn't show again; it changes no setting", function()
            for _, on in ipairs({ true, false }) do
                bootAt(B, { enabled = on, walkthrough = FINISHED })
                local before = ns.Util.DeepCopy(settingsBut(ns.db))
                runTitles()
                assert.is_false(tour:IsShown())
                assert.are.same({ seen = B, firstRun = false }, ns.db.walkthrough)
                assert.are.same(before, settingsBut(ns.db), "a switch left as it was: " .. tostring(on))
                assert.are.equal(on, ns.db.enabled)
                local db = ns.db
                bootAt(B, db)
                assert.is_false(tour:IsShown(), "not at the next login")
            end
        end)

        it("skipping it, or closing its window, saves the current version too, switching nothing", function()
            for _, how in ipairs({ "skip", "CloseButton" }) do
                bootAt(A, { enabled = false, walkthrough = FINISHED })
                wow.run(tour[how], "OnClick")
                assert.is_false(tour:IsShown())
                assert.are.same({ seen = A, firstRun = false }, ns.db.walkthrough, how)
                assert.is_false(ns.db.enabled, "skipping what's new never turns the addon on")
            end
        end)

        it("can be replayed in full from Start here afterwards", function()
            bootAt(B, { enabled = true, walkthrough = FINISHED })
            runTitles()
            wow.run(ns.Options.widgets.start.tour, "OnClick")
            assert.is_false(ns.Walkthrough.WhatsNew())
            assert.are.equal(#ns.Walkthrough.STEPS, ns.Walkthrough.Count())
            assert.are.equal("Welcome to Friendly Forever", tour.title:GetText())
            assert.are.equal("1 of " .. #ns.Walkthrough.STEPS, tour.count:GetText())
        end)

        it("a version raised with no step to show is saved without showing anything", function()
            boot({ db = { enabled = true, walkthrough = FINISHED }, afterLoad = function(loaded)
                loaded.Config.WALKTHROUGH_VERSION = A
            end })
            assert.is_false(tour:IsShown())
            assert.is_false(printedHas("Start here"))
            assert.are.same({ seen = A, firstRun = false }, ns.db.walkthrough)
        end)

        it("a first-run mark on a version already seen isn't a first run, even after a release adds a step", function()
            bootAt(A, { enabled = false, walkthrough = { seen = V0, firstRun = true } })
            assert.is_true(ns.Walkthrough.WhatsNew())
            assert.is_false(ns.Walkthrough.FirstRun())
            assert.is_false(printedHas("is off until you finish"))
            wow.run(tour.skip, "OnClick")
            assert.is_false(ns.db.enabled, "finishing what's new never switches the addon on")
            assert.are.same({ seen = A, firstRun = false }, ns.db.walkthrough)
        end)

        it("closes for a fight and reopens at the same step, still only what's new", function()
            bootAt(B, { enabled = true, walkthrough = FINISHED })
            wow.run(tour.next, "OnClick")
            wow.enterCombat()
            assert.is_false(tour:IsShown())
            wow.leaveCombat()
            assert.is_true(tour:IsShown())
            assert.are.equal("What's new: New " .. B, tour.title:GetText())
            assert.are.equal("2 of 2", tour.count:GetText())
        end)

        it("asked for at login in a fight, it waits, then shows only what's new", function()
            boot({ db = { enabled = true, walkthrough = FINISHED }, afterLoad = release(B), before = function(state)
                state.inCombat = true
            end })
            assert.is_false(tour:IsShown())
            wow.leaveCombat()
            assert.is_true(tour:IsShown())
            assert.are.equal("1 of 2", tour.count:GetText())
        end)
    end)

    describe("a damaged saved version (black)", function()
        local BAD = { -1, -0.5, 1.5, V0 + 3, V0 + 98, 1e9, math.huge, -math.huge, 0 / 0, "2", "x", true, {}, false }

        it("shows every step once, never errors, and changes no setting", function()
            for _, bad in ipairs(BAD) do
                for _, on in ipairs({ true, false }) do
                    bootAt(B, { enabled = on, walkthrough = { seen = bad, firstRun = true } })
                    local where = tostring(bad)
                    assert.is_true(tour:IsShown(), where)
                    assert.is_false(ns.Walkthrough.WhatsNew(), where)
                    assert.is_false(ns.Walkthrough.FirstRun(), where)
                    assert.are.equal(#ns.Walkthrough.STEPS, ns.Walkthrough.Count(), where)
                    local before = ns.Util.DeepCopy(settingsBut(ns.db))
                    wow.run(tour.skip, "OnClick")
                    assert.are.same(before, settingsBut(ns.db), where)
                    assert.are.equal(on, ns.db.enabled, where)
                    assert.are.same({ seen = B, firstRun = false }, ns.db.walkthrough, "healed: " .. where)
                    assert.are.same({}, wow.errors, where)
                    local db = ns.db
                    bootAt(B, db)
                    assert.is_false(tour:IsShown(), "once: " .. where)
                end
            end
        end)

        it("a version damaged while playing heals when the walkthrough is next started", function()
            bootAt(B, { enabled = true, walkthrough = { seen = B, firstRun = false } })
            for _, bad in ipairs(BAD) do
                ns.db.walkthrough = { seen = bad }
                ns.Walkthrough.Start(true)
                assert.is_true(tour:IsShown(), tostring(bad))
                wow.run(tour.skip, "OnClick")
                assert.are.same({ seen = B, firstRun = false }, ns.db.walkthrough)
                assert.are.same({}, wow.errors, tostring(bad))
            end
        end)
    end)

    -- Red: storms of releases (each adds a step), logins, fights, skips,
    -- finishes and damaged saved data. What each login must show is worked
    -- out here, from the storm's own record of what the player finished and
    -- of the damage, never from the addon.
    describe("storms of releases and logins (red)", function()
        local reached = { whatsNew = 0, everything = 0, nothing = 0, fights = 0, damaged = 0, finished = 0,
            whatsNewFinishedOff = 0, switchedOff = 0 }

        for seed = 1, 40 do
            it("never shows a step twice in a run, errors, or changes a setting (seed " .. seed .. ")", function()
                random.seed(seed)
                for _ = 1, 5 do random.random() end
                local version = V0
                -- Half the storms start as a new install, half as a player who
                -- finished the shipped walkthrough.
                local existing = seed % 2 == 0
                local record = existing and V0 or 0 -- the version they finished, 0 for none or damage
                local db = existing and { enabled = true, walkthrough = { seen = V0, firstRun = false } } or nil
                local firstRun = not existing  -- a new install's first run, until finished or damaged
                for login = 1, 12 do
                    if random.random(3) == 1 then version = version + 1 end
                    if db and random.random(4) == 1 then
                        local damage = DAMAGED[random.random(#DAMAGED)]
                        db.walkthrough = damage
                        -- A table whose seen is a whole number up to the version is no
                        -- damage at all (V0 + 1 is, once a release has reached it).
                        local n = type(damage) == "table" and damage.seen
                        record = (type(n) == "number" and n == math.floor(n) and n >= 0 and n <= version) and n or 0
                        firstRun = false
                        reached.damaged = reached.damaged + 1
                    end
                    local hadFirstRun = firstRun
                    -- The player switches the addon on or off by hand now and then.
                    if db and not firstRun and random.random(4) == 1 then
                        db.enabled = not db.enabled
                        if not db.enabled then reached.switchedOff = reached.switchedOff + 1 end
                    end
                    local handedEnabled = db and db.enabled
                    bootAt(version, db)
                    local where = ("seed %d, login %d"):format(seed, login)
                    -- What the storm expects: the steps newer than its record.
                    local expected = {}
                    for _, info in ipairs(ns.Walkthrough.STEPS) do
                        if info.since > record then expected[#expected + 1] = info.title end
                    end
                    local settings = ns.Util.DeepCopy(settingsBut(ns.db))
                    settings.enabled = nil
                    assert.are.equal(#expected > 0, tour:IsShown(), where)
                    assert.are.same({}, wow.errors, where)
                    if #expected > 0 then
                        local whatsNew = record > 0
                        local seen, index = {}, 0
                        local interrupt = random.random(3) == 1
                        local finish = random.random(3) > 1
                        local count = ns.Walkthrough.Count()
                        assert.are.equal(#expected, count, where)
                        assert.are.equal(whatsNew, ns.Walkthrough.WhatsNew(), where)
                        while ns.Walkthrough.Step() do
                            local at = ns.Walkthrough.Step()
                            assert.are.equal(index + 1, at, where .. ": steps go in order, once")
                            index = at
                            local title = tour.title:GetText():gsub("^What's new: ", "")
                            assert.is_nil(seen[title], where .. ": " .. title .. " shown twice")
                            seen[title] = true
                            assert.are.equal(expected[at], title, where)
                            if interrupt and at == 2 then
                                interrupt = false
                                reached.fights = reached.fights + 1
                                wow.enterCombat()
                                assert.is_false(tour:IsShown(), where)
                                wow.leaveCombat()
                                assert.are.equal(at, ns.Walkthrough.Step(), where .. ": back at the same step")
                            end
                            if not finish and at == 2 then break end
                            wow.run(tour.next, "OnClick")
                        end
                        if ns.Walkthrough.Step() then
                            -- Left open at a later login: nothing is recorded.
                            if random.random(2) == 1 then wow.run(tour.skip, "OnClick") end
                        end
                        if not ns.Walkthrough.Step() then
                            record = version
                            firstRun = false
                            reached.finished = reached.finished + 1
                            if whatsNew and handedEnabled == false then
                                reached.whatsNewFinishedOff = reached.whatsNewFinishedOff + 1
                            end
                        end
                        reached[whatsNew and "whatsNew" or "everything"] = reached[whatsNew and "whatsNew"
                            or "everything"] + 1
                    else
                        reached.nothing = reached.nothing + 1
                    end
                    -- No setting changed, but a new install's first run switches the addon on.
                    local after = ns.Util.DeepCopy(settingsBut(ns.db))
                    after.enabled = nil
                    assert.are.same(settings, after, where)
                    if not hadFirstRun then assert.are.equal(handedEnabled, ns.db.enabled, where) end
                    assert.are.same({}, wow.errors, where)
                    db = ns.Util.DeepCopy(ns.db)
                end
            end)
        end

        it("reached every case it's for: what's new, everything, nothing, fights, damage, finishing", function()
            for case, count in pairs(reached) do assert.is_true(count > 0, case .. " never happened") end
        end)
    end)

    describe("damaged settings and fights (black)", function()
        it("the page and every step open safely with a damaged saved file", function()
            boot({ db = { walkthrough = { seen = 0, firstRun = true }, enabled = "maybe", buff = "broken", guildJoin = 7,
                buffBack = { buffModeKey = {}, autoOnJoin = "yes", autoOffMinutes = "soon", thankStyle = {} } } })
            assert.is_true(tour:IsShown())
            wow.run(ns.Options.StartPage(), "OnShow")
            goTo(#ns.Walkthrough.STEPS)
            assert.are.same({}, wow.errors)
            assert.is_truthy(ns.Options.widgets.start.buffModeKey:GetText():find("MOUSEWHEELUP", 1, true))
        end)

        it("the page and every step open safely with settings damaged mid-session", function()
            boot()
            ns.db.buff.thankStyle = "shout"
            ns.db.buffBack.buffModeKey = "ESCAPE"
            ns.db.buffBack.autoOnJoin = "yes"
            ns.db.buffBack.autoOffMinutes = "soon"
            ns.db.enabled = 1
            wow.run(ns.Options.StartPage(), "OnShow")
            local w = ns.Options.widgets.start
            assert.is_truthy(w.thanks:GetText():find(ns.Options.THANK_STYLE_TEXT.message, 1, true),
                "an unknown way to thank reads as the default")
            assert.is_truthy(w.enabled:GetText():find("Friendly Forever is off", 1, true), "a switch that isn't true")
            assert.is_truthy(w.buffModeKey:GetText():find("MOUSEWHEELUP", 1, true), "a key it can't use")
            ns.db.buff.enabled = "yes"
            ns.Options.FillStart()
            assert.is_truthy(w.thanks:GetText():find("Buff Thanks is off", 1, true), "a switch that isn't true is off")
            ns.db.buff = 7
            ns.Options.FillStart()
            assert.is_truthy(w.thanks:GetText():find("Buff Thanks is off", 1, true), "a damaged section reads as empty")
            ns.db.buff = ns.Config.DefaultsFor("buff")
            -- Damaged again just before the step: the steps before it open the
            -- Buff Back tab, which repairs the file as it fills (#330).
            goTo(stepTitled("turns on and off") - 1)
            ns.db.buffBack.autoOnJoin = "yes"
            ns.db.buffBack.autoOffMinutes = "soon"
            wow.run(tour.next, "OnClick")
            local off = ns.Options.AUTO_TEXT.autoOnJoin .. ": " .. ns.Colours.Text("bad", "off")
            assert.is_truthy(tour.stepText:GetText():find(off, 1, true),
                "a switch that isn't true reads as off")
            assert.is_falsy(tour.stepText:GetText():find("or after", 1, true), "a damaged number gives no line")
            ns.db.buffBack.autoOffMinutes = 0
            wow.run(tour.back, "OnClick")
            wow.run(tour.next, "OnClick")
            assert.is_falsy(tour.stepText:GetText():find("or after", 1, true), "0 is never: no line")
            ns.db.buffBack.autoOffMinutes = 5
            wow.run(tour.back, "OnClick")
            wow.run(tour.next, "OnClick")
            assert.is_truthy(tour.stepText:GetText():find("  or after 5 minutes", 1, true))
            goTo(stepTitled("Thanks"))
            assert.is_truthy(tour.stepText:GetText():find(ns.Options.THANK_STYLE_TEXT.message, 1, true))
            ns.db.walkthrough = { "damaged" }
            goTo(#ns.Walkthrough.STEPS)
            wow.run(tour.next, "OnClick")
            assert.are.same(SEEN, ns.db.walkthrough)
            assert.are.same({}, wow.errors)
        end)

        it("closes as a fight starts, keeping its state, and reopens at the same step when it's over", function()
            boot()
            goTo(3)
            wow.enterCombat()
            assert.is_false(tour:IsShown())
            assert.is_nil(ns.Walkthrough.Step())
            assert.are.same({ seen = 0, firstRun = true }, ns.db.walkthrough)
            assert.is_true(printedHas("walkthrough closed for the fight; it comes back when the fight is over."))
            wow.run(tour.next, "OnClick") -- a stray click on the closed window does nothing
            assert.is_nil(ns.Walkthrough.Step())
            assert.is_true(ns.Walkthrough.IsPending(), "waiting to come back")
            ns.Options.SelectType("guildLogin")
            wow.leaveCombat()
            assert.is_true(tour:IsShown())
            assert.are.equal(3, ns.Walkthrough.Step())
            assert.are.equal("buffBack", ns.Options.CurrentType(), "its page opened again")
            assert.is_false(ns.Walkthrough.IsPending())
            wow.enterCombat()
            wow.leaveCombat()
            assert.are.equal(3, ns.Walkthrough.Step(), "and again after the next fight")
            -- Closed (here, skipped), a fight says nothing about it.
            wow.run(tour.skip, "OnClick")
            local said = #wow.printed
            wow.enterCombat()
            wow.leaveCombat()
            assert.are.equal(said, #wow.printed)
            assert.are.same({}, wow.errors)
        end)

        it("asked for in a fight, it waits for the fight to end", function()
            boot()
            wow.run(tour.skip, "OnClick")
            wow.enterCombat()
            wow.run(ns.Options.widgets.start.tour, "OnClick")
            wow.run(ns.Options.widgets.start.tour, "OnClick")
            assert.is_false(tour:IsShown())
            assert.is_true(ns.Walkthrough.IsPending())
            local said = 0
            for _, line in ipairs(wow.printed) do
                if line:find("will start when this fight is over", 1, true) then said = said + 1 end
            end
            assert.are.equal(1, said, "said once")
            wow.leaveCombat()
            assert.is_true(tour:IsShown())
            assert.are.equal(1, ns.Walkthrough.Step())
            assert.is_false(ns.Walkthrough.IsPending())
        end)

        it("on a first install in a fight, it starts once the fight is over", function()
            boot({ before = function(state) state.inCombat = true end })
            assert.is_false(tour:IsShown())
            assert.is_true(ns.Walkthrough.IsPending())
            wow.leaveCombat()
            assert.is_true(tour:IsShown())
        end)

        it("replayed during a fight that closed it, it starts again from the first step", function()
            boot()
            goTo(4)
            wow.enterCombat()
            ns.Walkthrough.Start()
            wow.leaveCombat()
            assert.are.equal(1, ns.Walkthrough.Step())
        end)

        it("skipping while one waits for a fight's end cancels it", function()
            boot()
            wow.enterCombat()
            ns.Walkthrough.Start()
            ns.Walkthrough.Skip()
            wow.leaveCombat()
            assert.is_false(tour:IsShown())
            assert.are.same(SEEN, ns.db.walkthrough)
        end)

        it("the page is safe in a fight: it fills, its links open, its walkthrough button waits", function()
            boot()
            wow.run(tour.skip, "OnClick")
            local w = ns.Options.widgets.start
            wow.enterCombat()
            wow.run(ns.Options.StartPage(), "OnShow")
            wow.run(w.openGeneral, "OnClick")
            wow.run(w.tour, "OnClick")
            assert.is_false(tour:IsShown())
            assert.are.same({}, wow.errors)
        end)
    end)
end)

describe("After an update that adds Walkthrough.lua and a /reload (no restart) (black)", function()
    it("asks for a restart instead of erroring, and opens nothing", function()
        wow.reset()
        local loaded = {}
        local _, files = wow.parseToc()
        for _, file in ipairs(files) do
            if file ~= "Walkthrough.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
        end
        wow.fire("ADDON_LOADED", wow.ADDON_NAME)
        wow.fire("PLAYER_ENTERING_WORLD", true, false)
        wow.advance(60)
        assert.are.same({}, wow.errors)
        assert.is_truthy(table.concat(wow.printed, "\n"):find("Restart the game", 1, true))
    end)
end)
