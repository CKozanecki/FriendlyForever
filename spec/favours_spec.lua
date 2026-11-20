-- Spec: #491, #508
-- Favours: one tab for thanking people who buff you and buffing them back.
-- It replaces the Buff Thanks and Buff Back tabs, holds every control they
-- had (passers-by and buff requests too) but buff mode's, which is
-- deliberately on the Buffs tab, each writing the section it always did,
-- with the two sets of lines as sub-tabs. The line when your buff lands
-- is off for a new install and kept for a player who had it on; the What's
-- new step says where things moved; /friendly find finds each of them there.
local wow = require("spec.support.wow")

local MOTW_1, MOTW, THORNS_1 = 1126, 9885, 467

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

-- The settings in a file, less the walkthrough's own state and the ledger.
local function settingsBut(db)
    local copy = {}
    for key, value in pairs(db) do
        if key ~= "walkthrough" and key ~= "ledger" then copy[key] = value end
    end
    -- Each character's record notes whether it has seen the walkthrough's
    -- step about its own settings (#508): walkthrough state, not a setting.
    if type(db.characters) == "table" then
        local records = {}
        for who, record in pairs(db.characters) do
            local kept = {}
            for field, value in pairs(type(record) == "table" and record or {}) do
                if field ~= "welcomed" then kept[field] = value end
            end
            records[who] = kept
        end
        copy.characters = records
    end
    return copy
end

-- The tab buttons' texts, in the panel's order (they're laid out in it).
local function tabTexts(ns)
    local out = {}
    for _, tab in ipairs(ns.Options.TABS) do out[#out + 1] = ns.Options.widgets.tabs[tab]:GetText() end
    return out
end

-- Every control the Buff Thanks and Buff Back tabs had of their own, as
-- Options.widgets paths, with the section and field it shows (1.4.4's
-- tabs: their Enabled, delay and repeat were the shared rows, now the
-- Favours tab's own). Passers-by came from the Buffs tab (#455). Buff
-- mode's key, triggers and top-up are BUFF_MODE's, below.
local CONTROLS = {
    { "thankEnabled", "buff", "enabled" },
    { "steppers.thankDelay", "buff", "delay" },
    { "steppers.thankRepeat", "buff", "repeatCooldown" },
    { "listNames", "buff", "listBuffNames" },
    { "receipts", "buff", "receipts" },
    { "thankStyle", "buff", "thankStyle" },
    { "fallback", "buff", "fallback" },
    { "unknownName", "buff", "unknownName" },
    { "quiet", "buff", "quietInCities" },
    { "offerEnabled", "buffBack", "enabled" },
    { "sayLine", "buffBack", "sayLine" },
    { "steppers.owedMinutes", "buffBack", "owedMinutes" },
    { "buffRequests", "buffBack", "requests" },
    { "passersBy", "buffBack", "passersBy" },
    { "showInCities", "buffBack", "showInCities" },
    { "steppers.renewPercent", "buffBack", "renewPercent" },
    { "openBuffs" },
    { "linesTabs.buff", "buff", "messages" },
    { "linesTabs.buffBack", "buffBack", "messages" },
}

-- The Buff Back tab's buff mode controls, deliberately on the Buffs tab
-- (buff mode serves your party, raid and solo buffing, not only favours),
-- at every place, writing buffBack as before.
local BUFF_MODE = {
    { "buffModeKey", "buffBack", "buffModeKey" },
    { "auto.autoOnJoin", "buffBack", "autoOnJoin" },
    { "auto.autoOnDeath", "buffBack", "autoOnDeath" },
    { "auto.autoOnBuffed", "buffBack", "autoOnBuffed" },
    { "auto.autoOnMissing", "buffBack", "autoOnMissing" },
    { "auto.autoOnCampfire", "buffBack", "autoOnCampfire" },
    { "auto.autoOffPull", "buffBack", "autoOffPull" },
    { "auto.autoOffDone", "buffBack", "autoOffDone" },
    { "steppers.autoOffMinutes", "buffBack", "autoOffMinutes" },
    { "steppers.topUpMinutes", "buffBack", "topUpMinutes" },
}

local function widgetAt(w, path)
    local node = w
    for part in path:gmatch("[^.]+") do node = node and node[part] end
    -- A stepper is a table of parts: its box stands for it.
    if type(node) == "table" and node.box then node = node.box end
    return node
end

describe("Favours (#491)", function()
    local ns, w

    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, walkthrough = opts.walkthrough, newInstall = opts.newInstall,
            before = function(state)
                state.class = opts.class or "DRUID"
                state.knownSpells = opts.known or { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
                if opts.nameplatesOff then state.cvars.nameplateShowFriendlyPlayers = "0" end
                if opts.before then opts.before(state) end
            end })
        w = ns.Options.widgets
        ns.Options.Open()
    end

    local function favours() wow.run(w.tabs.favours, "OnClick") end
    local function lines(msgType) wow.run(w.linesTabs[msgType], "OnClick") end
    local function click(box, on)
        box:SetChecked(on)
        wow.run(box, "OnClick")
    end
    local function typeLine(i, text)
        w.edits[i]:SetText(text)
        wow.run(w.edits[i], "OnTextChanged", true)
    end
    local function stepTo(stepper, value)
        stepper.box:SetText(tostring(value))
        wow.run(stepper.box, "OnEditFocusLost")
    end

    describe("one tab in place of two (white)", function()
        it("the tabs are the greetings', Favours and Buffs, in two rows, and none is Buff Thanks or Buff Back", function()
            boot()
            assert.are.same({ "Guild Login", "Guild Join", "Party Join", "Party Hello", "Hello Again", "Level Up",
                "Favours", "Buffs" }, tabTexts(ns))
            assert.are.equal(2, math.ceil(#ns.Options.TABS / ns.Options.TABS_PER_ROW), "two rows of tabs")
            for _, tab in pairs(w.tabs) do
                assert.is_falsy(tab:GetText():find("Buff Back", 1, true))
                assert.is_falsy(tab:GetText():find("Buff Thanks", 1, true))
            end
            assert.is_nil(w.tabs.buff)
            assert.is_nil(w.tabs.buffBack)
        end)

        it("every control the two tabs had is shown on Favours, or deliberately on the Buffs tab, and on no other tab",
            function()
                boot()
                favours()
                for _, c in ipairs(CONTROLS) do
                    local widget = widgetAt(w, c[1])
                    assert.is_truthy(widget, c[1] .. " exists")
                    assert.is_true(widget:IsVisible(), c[1] .. " shows on Favours")
                end
                -- Buff mode's: on the Buffs tab, at every place.
                wow.run(w.tabs.buffs, "OnClick")
                for _, place in ipairs(ns.BuffRules.PLACES) do
                    wow.run(w.placeTabs[place], "OnClick")
                    for _, c in ipairs(BUFF_MODE) do
                        local widget = widgetAt(w, c[1])
                        assert.is_truthy(widget, c[1] .. " exists")
                        assert.is_true(widget:IsVisible(), c[1] .. " shows on the Buffs tab's " .. place .. " place")
                    end
                end
                for _, tab in ipairs(ns.Options.TABS) do
                    wow.run(w.tabs[tab], "OnClick")
                    if tab ~= ns.Options.FAVOURS_TAB then
                        for _, c in ipairs(CONTROLS) do
                            assert.is_false(widgetAt(w, c[1]):IsVisible(), c[1] .. " is hidden on " .. tab)
                        end
                    end
                    if tab ~= ns.Options.BUFFS_TAB then
                        for _, c in ipairs(BUFF_MODE) do
                            assert.is_false(widgetAt(w, c[1]):IsVisible(), c[1] .. " is hidden on " .. tab)
                        end
                    end
                end
            end)

        it("each control shows its own saved setting, as the old tabs did", function()
            boot({ db = { buff = { enabled = false, delay = 9, repeatCooldown = 77, listBuffNames = false,
                receipts = false, thankStyle = "whisper", fallback = "say", unknownName = "pal", quietInCities = false },
                buffBack = { enabled = false, sayLine = true, owedMinutes = 12, requests = true, passersBy = true,
                    showInCities = true, renewPercent = 35, autoOnJoin = false, autoOnDeath = true,
                    autoOffMinutes = 7, topUpMinutes = 3, buffModeKey = "MOUSEWHEELDOWN" } } })
            favours()
            assert.is_false(w.thankEnabled:GetChecked())
            assert.are.equal("9", w.steppers.thankDelay.box:GetText())
            assert.are.equal("77", w.steppers.thankRepeat.box:GetText())
            assert.is_false(w.listNames:GetChecked())
            assert.is_false(w.receipts:GetChecked())
            assert.are.equal("a whisper", w.thankStyle:GetText())
            assert.are.equal("say it in /say as", w.fallback:GetText())
            assert.are.equal("pal", w.unknownName:GetText())
            assert.is_false(w.quiet:GetChecked())
            assert.is_false(w.offerEnabled:GetChecked())
            assert.is_true(w.sayLine:GetChecked())
            assert.are.equal("12", w.steppers.owedMinutes.box:GetText())
            assert.is_true(w.buffRequests:GetChecked())
            assert.is_true(w.passersBy:GetChecked())
            assert.is_true(w.showInCities:GetChecked())
            assert.are.equal("35", w.steppers.renewPercent.box:GetText())
            -- Buff mode's, on the Buffs tab (#491).
            wow.run(w.tabs.buffs, "OnClick")
            assert.is_false(w.auto.autoOnJoin:GetChecked())
            assert.is_true(w.auto.autoOnDeath:GetChecked())
            assert.are.equal("7", w.steppers.autoOffMinutes.box:GetText())
            assert.are.equal("3", w.steppers.topUpMinutes.box:GetText())
            assert.is_truthy(w.buffModeKey:GetText():find("MOUSEWHEELDOWN", 1, true))
        end)

        it("each switch and number writes the section it always did, not the other", function()
            boot()
            favours()
            local switches = {
                { w.thankEnabled, "buff", "enabled" }, { w.listNames, "buff", "listBuffNames" },
                { w.receipts, "buff", "receipts" }, { w.quiet, "buff", "quietInCities" },
                { w.offerEnabled, "buffBack", "enabled" }, { w.sayLine, "buffBack", "sayLine" },
                { w.buffRequests, "buffBack", "requests" }, { w.passersBy, "buffBack", "passersBy" },
                { w.showInCities, "buffBack", "showInCities" },
            }
            -- Buff mode's switches, clicked on the Buffs tab where they are (#491).
            for _, field in ipairs(ns.Options.AUTO_SWITCHES) do
                switches[#switches + 1] = { w.auto[field], "buffBack", field, ns.Options.BUFFS_TAB }
            end
            for _, s in ipairs(switches) do
                wow.run(w.tabs[s[4] or ns.Options.FAVOURS_TAB], "OnClick")
                assert.is_true(s[1]:IsVisible(), s[2] .. "." .. s[3] .. " is shown where it's clicked")
                for _, on in ipairs({ true, false }) do
                    local other = s[2] == "buff" and "buffBack" or "buff"
                    local before = ns.Util.DeepCopy(ns.db[other])
                    click(s[1], on)
                    assert.are.equal(on, ns.db[s[2]][s[3]], s[2] .. "." .. s[3])
                    assert.are.same(before, ns.db[other], s[2] .. "." .. s[3] .. " left " .. other .. " alone")
                end
            end
            local numbers = {
                { w.steppers.thankDelay, "buff", "delay", 8 },
                { w.steppers.thankRepeat, "buff", "repeatCooldown", 300 },
                { w.steppers.owedMinutes, "buffBack", "owedMinutes", 20 },
                { w.steppers.renewPercent, "buffBack", "renewPercent", 40 },
                { w.steppers.autoOffMinutes, "buffBack", "autoOffMinutes", 9, ns.Options.BUFFS_TAB },
                { w.steppers.topUpMinutes, "buffBack", "topUpMinutes", 2, ns.Options.BUFFS_TAB },
            }
            for _, n in ipairs(numbers) do
                wow.run(w.tabs[n[5] or ns.Options.FAVOURS_TAB], "OnClick")
                assert.is_true(n[1].box:IsVisible(), n[2] .. "." .. n[3] .. " is shown where it's typed in")
                stepTo(n[1], n[4])
                assert.are.equal(n[4], ns.db[n[2]][n[3]], n[2] .. "." .. n[3])
                assert.are.equal(tostring(n[4]), n[1].box:GetText())
            end
            favours()
            wow.run(w.thankStyle.rows[2], "OnClick")
            assert.are.equal("whisper", ns.db.buff.thankStyle)
            wow.run(w.fallback.rows[3], "OnClick")
            assert.are.equal("none", ns.db.buff.fallback)
            assert.is_false(w.unknownName:IsShown(), "the name box is only for the /say fallback")
        end)

        it("Offer my buff back and Thank them turn their features on and off as the old tabs' Enabled did", function()
            boot()
            favours()
            click(w.thankEnabled, false)
            click(w.offerEnabled, false)
            assert.is_false(ns.BuffTracker.Watching(), "neither on: buffs aren't watched")
            click(w.offerEnabled, true)
            assert.is_true(ns.BuffTracker.Watching())
            click(w.offerEnabled, false)
            click(w.thankEnabled, true)
            assert.is_true(ns.BuffTracker.Watching())
        end)

        it("the Buffs tab keeps the buff order and who gets each buff, but no passers-by switch", function()
            boot()
            wow.run(w.tabs.buffs, "OnClick")
            assert.is_true(w.buffRows[1].up:IsVisible())
            assert.is_true(w.placeTabs.party:IsVisible())
            assert.is_false(w.passersBy:IsVisible())
            assert.are.equal("Strangers", w.placeTabs.strangers:GetText())
            wow.run(w.placeTabs.strangers, "OnClick")
            assert.is_true(w.openFavours:IsVisible())
            wow.run(w.openFavours, "OnClick")
            assert.are.equal(ns.Options.FAVOURS_TAB, ns.Options.CurrentType())
        end)
    end)

    describe("the lines' sub-tabs (white, black)", function()
        it("Thank-you lines shows and edits buff's lines; When my buff lands buffBack's", function()
            boot({ db = { buff = { messages = { "thanks one" } }, buffBack = { messages = { "landed one" } } } })
            favours()
            assert.are.equal("buff", ns.Options.LinesType())
            assert.is_false(w.linesTabs.buff:IsEnabled(), "the sub-tab shown is the one pressed in")
            assert.are.equal("thanks one", w.edits[1]:GetText())
            typeLine(2, "thanks two")
            assert.are.equal("thanks two", ns.db.buff.messages[2])
            lines("buffBack")
            assert.are.equal("buffBack", ns.Options.LinesType())
            assert.is_false(w.linesTabs.buffBack:IsEnabled())
            assert.are.equal("landed one", w.edits[1]:GetText())
            typeLine(2, "landed two")
            assert.are.equal("landed two", ns.db.buffBack.messages[2])
            assert.are.equal("thanks two", ns.db.buff.messages[2], "the other set is untouched")
        end)

        it("an edit in progress is saved to the lines it was typed in, whichever sub-tab is pressed", function()
            -- The box then shows the other sub-tab's line, so the next letter
            -- typed is saved there, not over it (#502's testing review).
            boot({ db = { buff = { messages = { "t1", "t2", "t3" } }, buffBack = { messages = { "b1", "b2", "b3" } } } })
            favours()
            local edit = w.edits[3]
            edit:SetFocus()
            edit:SetText("typed into the thanks")
            wow.run(edit, "OnTextChanged", true)
            lines("buffBack")
            assert.are.equal("typed into the thanks", ns.db.buff.messages[3])
            assert.are.equal("b3", ns.db.buffBack.messages[3])
            assert.are.equal("b3", edit:GetText(), "the box shows the sub-tab pressed")
            edit:SetText(edit:GetText() .. "!")
            wow.run(edit, "OnTextChanged", true)
            assert.are.equal("b3!", ns.db.buffBack.messages[3])
            assert.are.equal("typed into the thanks", ns.db.buff.messages[3], "the thanks line is untouched")
        end)

        it("loading a set of lines loads only the sub-tab shown", function()
            boot()
            favours()
            lines("buffBack")
            ns.db.buff.messages[1] = "mine"
            ns.db.buffBack.messages[1] = "mine too"
            wow.run(w.loadFantasy, "OnClick")
            assert.are.same(ns.DefaultMessages.buffBack, ns.db.buffBack.messages)
            assert.are.equal("mine", ns.db.buff.messages[1])
            lines("buff")
            wow.run(w.loadCasual, "OnClick")
            assert.are.same(ns.CasualMessages.buff, ns.db.buff.messages)
        end)

        it("Reset resets both sections, as the two old tabs' Resets did, keeping the Buffs tab's and screen settings", function()
            boot()
            favours()
            ns.db.buff.enabled, ns.db.buff.delay, ns.db.buff.messages[1] = false, 30, "mine"
            ns.db.buffBack.sayLine, ns.db.buffBack.requests, ns.db.buffBack.passersBy = true, true, true
            ns.db.buffBack.messages[1] = "mine too"
            ns.db.buffBack.selfBuffs, ns.db.buffBack.buffOrder = false, { "thorns" }
            ns.db.buffBack.weaponBuffs, ns.db.buffBack.unlocked = true, true
            ns.db.buffBack.position = { point = "TOP", x = 5, y = 6 }
            wow.run(w.reset, "OnClick")
            local fresh = ns.Config.DefaultsFor("buff")
            assert.are.same(fresh, ns.db.buff)
            assert.is_false(ns.db.buffBack.sayLine)
            assert.is_false(ns.db.buffBack.requests)
            assert.is_false(ns.db.buffBack.passersBy, "passers-by is Favours' now, so its Reset resets it")
            assert.are.same(ns.DefaultMessages.buffBack, ns.db.buffBack.messages)
            assert.is_false(ns.db.buffBack.selfBuffs, "the Buffs tab's settings are its own")
            assert.are.same({ "thorns" }, ns.db.buffBack.buffOrder)
            assert.is_true(ns.db.buffBack.weaponBuffs, "the Weapon buffs page's are its own")
            assert.is_true(ns.db.buffBack.unlocked, "the button's place stays")
            assert.are.same({ point = "TOP", x = 5, y = 6 }, ns.db.buffBack.position)
        end)

        it("a greeting tab's Reset still resets only its own section", function()
            boot()
            ns.db.buff.delay = 30
            wow.run(w.tabs.guildJoin, "OnClick")
            ns.db.guildJoin.delay = 40
            wow.run(w.reset, "OnClick")
            assert.are.equal(ns.Config.DEFAULTS.guildJoin.delay, ns.db.guildJoin.delay)
            assert.are.equal(30, ns.db.buff.delay)
        end)

        it("a favour's type opens Favours at its lines, and an unknown tab changes nothing", function()
            boot()
            ns.Options.SelectType("buffBack")
            assert.are.equal(ns.Options.FAVOURS_TAB, ns.Options.CurrentType())
            assert.are.equal("buffBack", ns.Options.LinesType())
            ns.Options.SelectType("buff")
            assert.are.equal("buff", ns.Options.LinesType())
            for _, bad in ipairs({ "Buff Back", "nope", "", 42, true, {}, "general" }) do
                ns.Options.SelectType(bad)
                assert.are.equal(ns.Options.FAVOURS_TAB, ns.Options.CurrentType(), tostring(bad))
                ns.Options.SelectLines(bad)
                assert.are.equal("buff", ns.Options.LinesType(), tostring(bad))
            end
            ns.Options.SelectLines("guildJoin")
            assert.are.equal("buff", ns.Options.LinesType(), "a greeting's lines aren't a Favours sub-tab")
        end)

        it("on the Buffs tab nothing the lines' boxes do can write a setting or raise an error", function()
            boot()
            wow.run(w.tabs.buffs, "OnClick")
            local before = ns.Util.DeepCopy(settingsBut(ns.db))
            typeLine(1, "nowhere to go")
            wow.run(w.preview, "OnClick")
            wow.run(w.loadFantasy, "OnClick")
            stepTo(w.steppers.delay, 9)
            assert.are.same(before, settingsBut(ns.db))
        end)
    end)

    describe("the line when your buff lands (white)", function()
        it("is off for a new install", function()
            boot({ newInstall = true })
            favours()
            assert.is_false(ns.db.buffBack.sayLine)
            assert.is_false(w.sayLine:GetChecked())
        end)

        it("stays on for a player who had it on, and off for one who had it off", function()
            for _, had in ipairs({ true, false }) do
                boot({ db = { buffBack = { sayLine = had, enabled = true } } })
                favours()
                assert.are.equal(had, ns.db.buffBack.sayLine)
                assert.are.equal(had, w.sayLine:GetChecked())
            end
        end)
    end)

    describe("passers-by and buff requests from their new place (white)", function()
        it("buff requests ticked on Favours queue a player who asks, and unticked let them go", function()
            boot()
            favours()
            click(w.buffRequests, true)
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "PRIEST" })
            wow.whisper("mark pls", "Bob-Stone")
            local offer = ns.Offers.Current()
            assert.are.equal("Bob-Stone", offer and offer.name)
            click(w.buffRequests, false)
            assert.is_nil(ns.Offers.Current(), "turning it off lets the waiting request go")
        end)

        it("passers-by ticked on Favours are offered in buff mode, and unticked aren't", function()
            boot()
            favours()
            click(w.passersBy, true)
            slash("buffmode on")
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR",
                auras = {} })
            ns.PassersBy.Fresh()
            local offer = ns.PassersBy.Next()
            assert.are.equal("Bob-Stone", offer and offer.name)
            click(w.passersBy, false)
            ns.PassersBy.Fresh()
            assert.is_nil(ns.PassersBy.Next())
        end)

        it("passers-by is in the tab's first rows, above the buff button's and the lines", function()
            boot()
            favours()
            -- The client has no vertical layout here: the chain of anchors says the order
            -- (the UI simulator measures it: #493).
            local chain, frame = {}, w.passersBy
            while frame do
                chain[#chain + 1] = frame
                local _, anchor = frame:GetPoint()
                frame = anchor ~= w.content and anchor or nil
            end
            local function has(x) for _, f in ipairs(chain) do if f == x then return true end end return false end
            for _, above in ipairs({ w.buffRequests, w.askedHeader, w.sayLine, w.offerEnabled, w.returnHeader,
                w.quiet, w.thankEnabled, w.thanksHeader }) do
                assert.is_true(has(above), "passers-by hangs below it")
            end
            for _, below in ipairs({ w.buttonHeader, w.showInCities, w.steppers.renewPercent.label, w.buffsLink,
                w.linesHeader }) do
                assert.is_false(has(below), "nothing below passers-by is above it")
            end
        end)

        it("the nameplate warning shows under passers-by only while friendly nameplates are off", function()
            for _, off in ipairs({ false, true }) do
                boot({ nameplatesOff = off })
                favours()
                assert.are.equal(off, w.nameplateWarning:IsVisible())
                assert.are.equal(off, w.nameplateButton:IsVisible())
                local _, anchor = w.buttonHeader:GetPoint()
                assert.are.equal(off and w.nameplateButton or w.passersByHelp, anchor)
            end
        end)
    end)

    describe("What's new (white)", function()
        local tour
        local function whatsNewTitles()
            local out = {}
            while ns.Walkthrough.Step() do
                out[#out + 1] = tour.title:GetText()
                wow.run(tour.next, "OnClick")
            end
            return out
        end

        it("a player who finished the last walkthrough sees one step, opening Favours, saying where things went", function()
            boot({ walkthrough = true, db = { enabled = true, buffBack = { sayLine = true },
                walkthrough = { seen = 3, firstRun = false } } })
            tour = ns.Walkthrough.Frame()
            assert.are.equal(2, ns.Walkthrough.Count(), "then #508's step")
            assert.is_true(tour:IsShown())
            assert.are.equal("What's new: Favours: thanking and buffing back", tour.title:GetText())
            assert.are.equal(ns.Options.FAVOURS_TAB, ns.Options.CurrentType(), "it opens the Favours tab")
            local text = tour.stepText:GetText()
            for _, where in ipairs({ "Buff Thanks and Buff Back tabs are now one tab, Favours",
                "When someone buffs you", "Return the favour", "Asked and passing by", "passers-by switch",
                "\"The buff button\"", "Thank-you lines", "When my buff lands", "on, as you had it",
                "Buff mode's key, when it turns on and off, and top-up moved to the Buffs tab", "\"Buff mode\"",
                "\"Strangers\"" }) do
                assert.is_truthy(text:find(where, 1, true), where)
            end
            assert.are.same({ "What's new: Favours: thanking and buffing back",
                "What's new: Each character's own buffs" }, whatsNewTitles())
            assert.are.same({ seen = ns.Config.WALKTHROUGH_VERSION, firstRun = false }, ns.db.walkthrough)
        end)

        it("skipping it changes no setting, and it doesn't show again", function()
            boot({ walkthrough = true, db = { enabled = true, walkthrough = { seen = 3, firstRun = false } } })
            tour = ns.Walkthrough.Frame()
            local before = ns.Util.DeepCopy(settingsBut(ns.db))
            wow.run(tour.skip, "OnClick")
            assert.is_false(tour:IsShown())
            assert.are.same(before, settingsBut(ns.db))
            assert.are.same({ seen = ns.Config.WALKTHROUGH_VERSION, firstRun = false }, ns.db.walkthrough)
            local db = ns.db
            boot({ walkthrough = true, db = db })
            assert.is_false(ns.Walkthrough.Frame():IsShown(), "not at the next login")
        end)

        it("a new player's full run describes Favours without the old tabs' names", function()
            boot({ walkthrough = true, db = { enabled = true, walkthrough = { seen = 0, firstRun = false } } })
            tour = ns.Walkthrough.Frame()
            local text
            while ns.Walkthrough.Step() do
                if tour.title:GetText() == "Favours: thanking and buffing back" then text = tour.stepText:GetText() end
                wow.run(tour.next, "OnClick")
            end
            assert.is_truthy(text)
            assert.is_falsy(text:find("Buff Back", 1, true))
            assert.is_falsy(text:find("Buff Thanks", 1, true))
            assert.is_truthy(text:find("off unless you turn it on", 1, true))
        end)

        -- Buff mode's two steps open the Buffs tab, where its rows are now.
        it("every step that opened the Buff Thanks or Buff Back tab opens Favours, or for buff mode the Buffs tab",
            function()
                boot()
                local expected = { ["Buff mode: its key"] = ns.Options.BUFFS_TAB,
                    ["Buff mode: when it turns on and off"] = ns.Options.BUFFS_TAB,
                    ["Thanks"] = ns.Options.FAVOURS_TAB, ["Buff requests in chat"] = ns.Options.FAVOURS_TAB,
                    ["Favours: thanking and buffing back"] = ns.Options.FAVOURS_TAB }
                local checked = 0
                for _, info in ipairs(ns.Walkthrough.STEPS) do
                    if info.open then
                        info.open()
                        local current = ns.Options.CurrentType()
                        assert.are_not.equal("buff", current, info.title)
                        assert.are_not.equal("buffBack", current, info.title)
                        if expected[info.title] then
                            assert.are.equal(expected[info.title], current, info.title)
                            checked = checked + 1
                        end
                    end
                end
                assert.are.equal(5, checked, "every such step was found")
            end)
    end)

    describe("finding a setting (white)", function()
        -- Every setting that moved, with a word a player would search for it by.
        local MOVED = {
            { "Thank them", "thank" }, { "Delay before thanking", "delay" },
            { "Don't thank the same player again for", "repeat" }, { "Name the buffs in the message", "names" },
            { "Tell players I buff that it was me", "receipts" }, { "Thank them with", "whisper" },
            { "If that can't reach them", "fallback" }, { "Stay quiet in capital cities", "quiet" },
            { "Show friendly player names", "nameplates" }, { "Offer my buff back", "favour" },
            { "Say a line when my buff lands", "lands" }, { "Thank-you lines or When my buff lands", "lines" },
            { "Offer for (minutes)", "owed" },
            { "Renew my buff when theirs has under", "renew" }, { "Show the button in capital cities", "button" },
            { "Offer my buffs to players who ask in chat", "request" },
            { "Also offer my buffs to passers-by", "passers-by" },
        }
        -- Buff mode's, deliberately on the Buffs tab.
        local BUFF_MODE_MOVED = {
            { "Buff mode key", "key" }, { "Buff mode turns on by itself", "campfire" },
            { "Buff mode turns off again", "pull" }, { "Top up my buffs with under", "top" },
        }

        it("finds each moved setting on the Favours tab, or buff mode's on the Buffs tab, by its own words "
            .. "and by the old tabs' names", function()
            boot()
            local function check(list, page, word)
                for _, m in ipairs(list) do
                    for _, query in ipairs({ m[2], word .. " " .. m[2] }) do
                        local found, where = {}, nil
                        for _, entry in ipairs(ns.OptionsIndex.Find(query)) do
                            found[#found + 1] = entry.name
                            if entry.name == m[1] then where = entry.page end
                        end
                        assert.are.equal(page, where, ("%q finds %s: %s"):format(query, m[1],
                            table.concat(found, "; ")))
                    end
                end
            end
            check(MOVED, "the Favours tab", "favours")
            check(BUFF_MODE_MOVED, "the Buffs tab", "buffs")
            wow.printed = {}
            slash("find buff mode key")
            assert.is_truthy(table.concat(wow.printed, "\n"):find("Buff mode key: on the Buffs tab", 1, true))
            for _, old in ipairs({ "buff back", "buff thanks" }) do
                local found = ns.OptionsIndex.Find(old)
                assert.is_true(#found > 0, old)
                for _, entry in ipairs(found) do
                    assert.is_falsy(entry.page:find("Buff Back", 1, true), old .. ": " .. entry.name)
                    assert.is_falsy(entry.page:find("Buff Thanks", 1, true), old .. ": " .. entry.name)
                end
            end
            wow.printed = {}
            slash("find passers-by")
            local said = table.concat(wow.printed, "\n")
            assert.is_truthy(said:find("Also offer my buffs to passers-by: on the Favours tab", 1, true), said)
        end)

        it("no setting is listed on the Buff Thanks or Buff Back tab any more", function()
            boot()
            for _, entry in ipairs(ns.OptionsIndex.SETTINGS) do
                assert.is_falsy(entry.page:find("Buff Back tab", 1, true), entry.name)
                assert.is_falsy(entry.page:find("Buff Thanks", 1, true), entry.name)
            end
        end)
    end)

    describe("wording (white)", function()
        it("no options text, tooltip or chat line of the panel names Buff Thanks or Buff Back", function()
            boot()
            local seen = {}
            local function look(frame, where)
                if seen[frame] then return end
                seen[frame] = true
                for _, region in ipairs({ frame:GetRegions() }) do
                    local text = region.GetText and region:GetText()
                    if type(text) == "string" then
                        assert.is_falsy(text:find("Buff Back", 1, true), where .. ": " .. text)
                        assert.is_falsy(text:find("Buff Thanks", 1, true), where .. ": " .. text)
                        assert.is_falsy(text:find("buff%-back"), where .. ": " .. text)
                    end
                end
                for _, key in ipairs({ "tooltip" }) do
                    local t = frame[key]
                    if type(t) == "string" then
                        assert.is_falsy(t:find("Buff Back", 1, true), where .. " tooltip: " .. t)
                        assert.is_falsy(t:find("buff%-back"), where .. " tooltip: " .. t)
                    end
                end
                for _, child in ipairs({ frame:GetChildren() }) do look(child, where) end
            end
            for _, tab in ipairs(ns.Options.TABS) do
                wow.run(w.tabs[tab], "OnClick")
                if tab == ns.Options.FAVOURS_TAB then
                    for _, msgType in ipairs(ns.Options.FAVOUR_LINES) do
                        lines(msgType)
                        look(w.content, tab .. "/" .. msgType)
                        seen = {}
                    end
                end
                look(w.content, tab)
                seen = {}
            end
            ns.Options.FillStart()
            look(ns.Options.StartPage(), "Start here")
        end)
    end)
end)
