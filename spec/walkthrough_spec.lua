-- Spec: #47
-- The Start here page and the walkthrough: the page's controls change the
-- same settings as their full pages, the walkthrough reaches buff mode's key
-- and triggers, skipping or finishing it is remembered, it can be replayed,
-- and both are safe with damaged settings and in fights.
local wow = require("spec.support.wow")

local BUTTON_BINDING = "CLICK FriendlyForeverBuffButton:LeftButton"

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
    local ns, w, tabs

    local function boot(opts)
        ns = wow.boot(opts)
        w = ns.Options.widgets.start
        tabs = ns.Options.widgets
    end

    before_each(function() boot() end)

    it("is the first page listed under Friendly Forever, and fills when shown", function()
        local names = {}
        for _, sub in ipairs(wow.settings.subcategories) do names[#names + 1] = sub.name end
        assert.are.same({ "Start here", "General", "Favour Ledger" }, names)
        assert.are.equal(ns.Options.StartPage(), _G.FriendlyForeverStartPage)
        ns.db.enabled = false
        wow.run(ns.Options.StartPage(), "OnShow")
        assert.is_false(w.master:GetChecked())
    end)

    describe("every control changes the same setting as its full page (white)", function()
        -- Whether the addon's own event frame (the one with chat's system
        -- messages) watches every cast, which only buff watching needs
        -- (Core.lua's RefreshEvents).
        local function watchingCasts()
            for _, frame in ipairs(wow.frames) do
                if frame.events.CHAT_MSG_SYSTEM and frame.events.UNIT_SPELLCAST_SUCCEEDED then return true end
            end
            return false
        end

        -- What switching the addon off changes: the setting, the buff
        -- watching events, and the message said.
        local function switchedOff(box)
            assert.is_true(watchingCasts(), "watching before")
            box:SetChecked(false)
            wow.run(box, "OnClick")
            return { enabled = ns.db.enabled, watching = watchingCasts(), said = wow.printed[#wow.printed] }
        end

        it("the addon switch, as the main panel's: the setting, its events and its message", function()
            local fromPage = switchedOff(w.master)
            assert.are.same({ enabled = false, watching = false, said = fromPage.said }, fromPage)
            assert.is_truthy(fromPage.said:find("disabled", 1, true))
            boot()
            assert.are.same(fromPage, switchedOff(tabs.master))
            boot()
            w.master:SetChecked(false)
            wow.run(w.master, "OnClick")
            w.master:SetChecked(true)
            wow.run(w.master, "OnClick")
            assert.is_true(ns.db.enabled)
        end)

        it("how to thank, stepping through the same choices as the Buff Thanks tab's button", function()
            local function steps(button)
                local seen = {}
                for i = 1, #ns.Options.THANK_STYLES do
                    wow.run(button, "OnClick")
                    seen[i] = ns.db.buff.thankStyle
                end
                return seen
            end
            local fromPage = steps(w.thankStyle)
            boot()
            assert.are.same(steps(tabs.thankStyle), fromPage)
            assert.are.same({ "whisper", "emote", "both", "message" }, fromPage)
            wow.run(w.thankStyle, "OnClick")
            assert.are.equal(ns.Options.THANK_STYLE_TEXT.whisper, w.thankStyle:GetText(), "the page shows it")
        end)

        it("friendly nameplates, as the Buff Thanks tab's button turns them on", function()
            wow.state.cvars.nameplateShowFriendlyPlayers = "0"
            ns.Options.FillStart()
            assert.is_true(w.nameplateButton:IsEnabled())
            assert.is_truthy(w.nameplates:GetText():find("off", 1, true))
            wow.run(w.nameplateButton, "OnClick")
            local fromPage = {}
            for k, v in pairs(wow.state.cvars) do fromPage[k] = v end
            assert.are.equal("1", fromPage.nameplateShowFriendlyPlayers)
            ns.Options.FillStart()
            assert.is_false(w.nameplateButton:IsEnabled())
            boot()
            wow.state.cvars.nameplateShowFriendlyPlayers = "0"
            wow.run(tabs.tabs.buff, "OnClick")
            wow.run(tabs.nameplateButton, "OnClick")
            assert.are.same(fromPage, wow.state.cvars)
        end)

        it("buff mode's key, as the Buff Back tab's chooser sets it", function()
            wow.run(w.buffModeKey, "OnClick")
            assert.are.equal(ns.Options.KEY_PROMPT, w.buffModeKey:GetText())
            wow.keyDown("F")
            assert.are.equal("F", ns.db.buffBack.buffModeKey)
            assert.are.equal("Buff mode key: F", w.buffModeKey:GetText())
            assert.are.equal("Buff mode key: F", tabs.buffModeKey:GetText(), "the tab shows the new key too")
            wow.run(w.buffModeKey, "OnClick")
            wow.run(w.keyCapture, "OnMouseWheel", -1)
            assert.are.equal("MOUSEWHEELDOWN", ns.db.buffBack.buffModeKey)
            boot()
            wow.run(tabs.buffModeKey, "OnClick")
            wow.keyDown("F")
            assert.are.equal("F", ns.db.buffBack.buffModeKey)
        end)

        it("makes each chooser's capture after its button, so it lies on top and gets side mouse buttons", function()
            local order = {}
            for i, frame in ipairs(wow.frames) do order[frame] = i end
            for _, chooser in ipairs({ { w.buffModeKey, w.keyCapture }, { tabs.buffModeKey, tabs.keyCapture } }) do
                assert.is_true(order[chooser[2]] > order[chooser[1]])
                assert.are.equal(chooser[1], chooser[2].button)
            end
        end)

        it("keeps asking for a key while it waits, whatever refreshes the page", function()
            wow.run(w.buffModeKey, "OnClick")
            ns.Options.Refresh()
            assert.are.equal(ns.Options.KEY_PROMPT, w.buffModeKey:GetText())
        end)

        it("waits for a key on one chooser at a time", function()
            wow.run(tabs.buffModeKey, "OnClick")
            wow.run(w.buffModeKey, "OnClick")
            assert.is_false(tabs.keyCapture.keyboard, "starting one stops the other")
            assert.are.equal("Buff mode key: MOUSEWHEELUP", tabs.buffModeKey:GetText())
            wow.keyDown("G")
            assert.are.equal("G", ns.db.buffBack.buffModeKey)
        end)

        it("shows the buff-back button's key from Key Bindings, or that it has none", function()
            ns.Options.FillStart()
            assert.is_truthy(w.buttonKey:GetText():find("none yet", 1, true))
            wow.state.bindings.F7 = BUTTON_BINDING
            wow.state.bindings.F2 = "TOGGLEBACKPACK"
            ns.Options.FillStart()
            assert.are.equal("Buff-back button key: F7 (in Key Bindings > AddOns).", w.buttonKey:GetText())
        end)

        it("links to every other page", function()
            wow.run(w.openGeneral, "OnClick")
            assert.are.equal("General", wow.settings.opened)
            wow.run(w.openLedger, "OnClick")
            assert.are.equal("Favour Ledger", wow.settings.opened)
            wow.run(w.openMessages, "OnClick")
            assert.are.equal(4242, wow.settings.opened)
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

    describe("on a first install", function()
        before_each(function() boot() end)

        it("starts at login, and the chat message points to Start here", function()
            assert.is_true(tour:IsShown())
            assert.are.equal(1, ns.Walkthrough.Step())
            assert.are.equal("new", ns.db.walkthrough)
            assert.is_true(printedHas("Esc > Options > AddOns > Friendly Forever > Start here"))
            assert.is_false(tour.back:IsShown())
            assert.are.equal("Show me around", tour.next:GetText())
            wow.run(tour.back, "OnClick")
            assert.are.equal(1, ns.Walkthrough.Step(), "nothing before the first step")
        end)

        it("sizes its scrolling text area to each step's text, shown from the top", function()
            tour.text.GetStringHeight = function() return 90 end
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
            assert.is_truthy(tour.text:GetText():find("MOUSEWHEELUP", 1, true))

            ns.db.buffBack.autoOnDeath = false
            goTo(stepTitled("turns on and off"))
            assert.are.equal("buffBack", ns.Options.CurrentType())
            assert.is_true(ns.Options.widgets.autoHeader:IsShown())
            local text = tour.text:GetText()
            for _, field in ipairs(ns.Options.AUTO_SWITCHES) do
                local state = ns.db.buffBack[field] and "on" or "off"
                assert.is_truthy(text:find(ns.Options.AUTO_TEXT[field] .. ": |cff%x%x%x%x%x%x" .. state),
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

        it("never changes a setting, forward and back", function()
            local before = ns.Util.DeepCopy(settingsBut(ns.db))
            goTo(#ns.Walkthrough.STEPS)
            while ns.Walkthrough.Step() > 1 do wow.run(tour.back, "OnClick") end
            assert.are.same(before, settingsBut(ns.db))
            wow.run(tour.skip, "OnClick")
            assert.are.same(before, settingsBut(ns.db))
        end)

        it("finishing it is remembered, and it doesn't start at the next login", function()
            goTo(#ns.Walkthrough.STEPS)
            wow.run(tour.next, "OnClick")
            assert.is_false(tour:IsShown())
            assert.is_nil(ns.Walkthrough.Step())
            assert.are.equal("done", ns.db.walkthrough)
            local db = ns.db
            boot({ db = db })
            assert.is_false(tour:IsShown())
            assert.is_false(printedHas("Start here"))
        end)

        it("its window's close button skips it, remembered like the Skip button", function()
            goTo(2)
            wow.run(tour.CloseButton, "OnClick")
            assert.is_false(tour:IsShown())
            assert.are.equal("skipped", ns.db.walkthrough)
            assert.is_false(ns.Walkthrough.IsPending())
            local db = ns.db
            boot({ db = db })
            assert.is_false(tour:IsShown())
        end)

        it("skipping it is remembered, and it doesn't start at the next login", function()
            goTo(3)
            wow.run(tour.skip, "OnClick")
            assert.is_false(tour:IsShown())
            assert.are.equal("skipped", ns.db.walkthrough)
            local db = ns.db
            boot({ db = db })
            assert.is_false(tour:IsShown())
        end)

        it("can be replayed from Start here, after being skipped or finished", function()
            wow.run(tour.skip, "OnClick")
            for _, state in ipairs({ "skipped", "done" }) do
                ns.db.walkthrough = state
                wow.run(ns.Options.widgets.start.tour, "OnClick")
                assert.is_true(tour:IsShown())
                assert.are.equal(1, ns.Walkthrough.Step())
                goTo(stepTitled("its key"))
                assert.are.equal("buffBack", ns.Options.CurrentType())
                goTo(#ns.Walkthrough.STEPS)
                wow.run(tour.next, "OnClick")
                assert.are.equal("done", ns.db.walkthrough)
            end
        end)
    end)

    it("doesn't start for someone already using the addon, or with a damaged state", function()
        for _, saved in ipairs({ {}, { walkthrough = 42 }, { walkthrough = "NEW" }, { walkthrough = {} } }) do
            boot({ db = saved })
            assert.is_false(tour:IsShown())
            assert.are.equal("done", ns.db.walkthrough)
            assert.is_false(printedHas("Start here"))
        end
        boot({ db = { walkthrough = "new" } })
        assert.is_true(tour:IsShown(), "not yet skipped or finished: it starts")
    end)

    describe("damaged settings and fights (black)", function()
        it("the page and every step open safely with a damaged saved file", function()
            boot({ db = { walkthrough = "new", enabled = "maybe", buff = "broken", guildJoin = 7,
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
            assert.are.equal(ns.Options.THANK_STYLE_TEXT.message, w.thankStyle:GetText())
            assert.is_false(w.master:GetChecked())
            goTo(stepTitled("turns on and off"))
            assert.is_truthy(tour.text:GetText():find(ns.Options.AUTO_TEXT.autoOnJoin .. ": |cffff4040off", 1, true),
                "a switch that isn't true reads as off")
            assert.is_falsy(tour.text:GetText():find("or after", 1, true), "a damaged number gives no line")
            ns.db.buffBack.autoOffMinutes = 0
            wow.run(tour.back, "OnClick")
            wow.run(tour.next, "OnClick")
            assert.is_falsy(tour.text:GetText():find("or after", 1, true), "0 is never: no line")
            ns.db.buffBack.autoOffMinutes = 5
            wow.run(tour.back, "OnClick")
            wow.run(tour.next, "OnClick")
            assert.is_truthy(tour.text:GetText():find("  or after 5 minutes", 1, true))
            goTo(stepTitled("Thanks"))
            assert.is_truthy(tour.text:GetText():find(ns.Options.THANK_STYLE_TEXT.message, 1, true))
            ns.db.walkthrough = { "damaged" }
            goTo(#ns.Walkthrough.STEPS)
            wow.run(tour.next, "OnClick")
            assert.are.equal("done", ns.db.walkthrough)
            assert.are.same({}, wow.errors)
        end)

        it("closes as a fight starts, keeping its state, and says how to take it again", function()
            boot()
            goTo(3)
            wow.enterCombat()
            assert.is_false(tour:IsShown())
            assert.is_nil(ns.Walkthrough.Step())
            assert.are.equal("new", ns.db.walkthrough)
            assert.is_true(printedHas("walkthrough closed for the fight"))
            wow.leaveCombat()
            assert.is_false(tour:IsShown(), "it doesn't come back by itself")
            wow.run(tour.next, "OnClick") -- a stray click on the closed window does nothing
            assert.is_nil(ns.Walkthrough.Step())
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

        it("skipping while one waits for a fight's end cancels it", function()
            boot()
            wow.enterCombat()
            ns.Walkthrough.Start()
            ns.Walkthrough.Skip()
            wow.leaveCombat()
            assert.is_false(tour:IsShown())
            assert.are.equal("skipped", ns.db.walkthrough)
        end)

        it("the page's controls are safe in a fight: buff mode's key waits, nothing errors", function()
            boot()
            local w = ns.Options.widgets.start
            wow.enterCombat()
            wow.run(ns.Options.StartPage(), "OnShow")
            wow.run(w.buffModeKey, "OnClick")
            assert.are.equal("Buff mode key: MOUSEWHEELUP", w.buffModeKey:GetText())
            assert.is_true(printedHas("keys can't be changed in a fight."))
            wow.run(w.thankStyle, "OnClick")
            wow.run(w.openGeneral, "OnClick")
            w.master:SetChecked(false)
            wow.run(w.master, "OnClick")
            assert.are.same({}, wow.errors)
        end)

        it("a key wait on the page stops as a fight starts", function()
            boot()
            local w = ns.Options.widgets.start
            wow.run(w.buffModeKey, "OnClick")
            wow.enterCombat()
            assert.is_false(w.keyCapture.keyboard)
            wow.run(w.keyCapture, "OnKeyDown", "2")
            assert.are.equal("MOUSEWHEELUP", ns.db.buffBack.buffModeKey)
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
