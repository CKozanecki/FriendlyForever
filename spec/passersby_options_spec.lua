-- Spec: #39, #455, #491
-- Passers-by and the campfire trigger in the settings: the switch on the
-- Favours tab (#491; it was at the top of the Buffs tab, #455), with its
-- help line and the nameplates it needs; the campfire's box among the
-- turn-on triggers; the options search; the walkthrough; profiles and
-- settings lines.
local wow = require("spec.support.wow")

describe("Passers-by and the campfire in the settings (#39)", function()
    local ns, w

    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [1126] = true }
            if opts.nameplatesOff then state.cvars.nameplateShowFriendlyPlayers = "0" end
        end })
        w = ns.Options.widgets
        ns.Options.Open()
    end

    local function favours() wow.run(w.tabs.favours, "OnClick") end

    local function buffsPlace(p)
        wow.run(w.tabs.buffs, "OnClick")
        wow.run(w.placeTabs[p], "OnClick")
    end

    local function click(box, on)
        box:SetChecked(on)
        wow.run(box, "OnClick")
    end

    describe("the switch (white)", function()
        it("is on the Favours tab, under buff requests, off by default, with its help line, and saves at once", function()
            boot()
            favours()
            assert.is_true(w.passersBy:IsVisible())
            assert.are.equal(w.buffRequests, select(2, w.passersBy:GetPoint()), "under buff requests")
            assert.is_false(w.passersBy:GetChecked())
            assert.is_truthy(w.passersBy.tooltip)
            assert.is_true(w.passersByHelp:IsVisible())
            assert.is_truthy(w.passersByHelp:GetText():find("aren't in your group", 1, true))
            click(w.passersBy, true)
            assert.is_true(ns.db.buffBack.passersBy)
            click(w.passersBy, false)
            assert.is_false(ns.db.buffBack.passersBy)
        end)

        -- #491: it moved from the top of the Buffs tab (#455), with its help
        -- and its warning, which is now the one warning for thanks too.
        it("shows on the Favours tab only, not on any Buffs place, and the nameplate warning only while they're off",
            function()
                boot({ nameplatesOff = true })
                favours()
                assert.is_true(w.passersBy:IsVisible())
                assert.is_true(w.passersByHelp:IsVisible())
                assert.is_true(w.nameplateWarning:IsVisible())
                assert.is_true(w.nameplateButton:IsVisible())
                assert.is_truthy(w.nameplateWarning:GetText():find(ns.Options.NAMEPLATES_OFF, 1, true))
                -- The simulator has no vertical layout: the chain of anchors says the order.
                assert.are.equal(w.passersByHelp, select(2, w.nameplateWarning:GetPoint()), "the warning under the help")
                assert.are.equal(w.nameplateWarning, select(2, w.nameplateButton:GetPoint()), "its button under it")
                for _, p in ipairs({ "strangers", "party", "raid", "pvp" }) do
                    buffsPlace(p)
                    assert.is_false(w.passersBy:IsVisible(), p)
                    assert.is_false(w.passersByHelp:IsVisible(), p)
                    assert.is_false(w.nameplateWarning:IsVisible(), p)
                    assert.is_false(w.nameplateButton:IsVisible(), p)
                end
                assert.is_nil(w.passersByNameplates, "the Buffs tab's own warning is gone")
                assert.is_nil(w.passersByShow)
                boot()
                favours()
                assert.is_true(w.passersBy:IsVisible())
                assert.is_false(w.nameplateWarning:IsVisible(), "no warning while they're on")
            end)

        it("is the same saved setting as before, so nothing needs moving (#455)", function()
            boot({ db = { buffBack = { passersBy = true } } })
            favours()
            assert.is_true(w.passersBy:GetChecked(), "an old saved true reads as on")
            click(w.passersBy, false)
            assert.is_false(ns.db.buffBack.passersBy)
            assert.is_nil(ns.db.passersBy, "no new field, no migration")
        end)

        it("the rows below hang from the help line, or from the warning's button when it shows", function()
            for _, off in ipairs({ false, true }) do
                boot({ nameplatesOff = off })
                favours()
                local _, anchor = w.buttonHeader:GetPoint()
                assert.are.equal(off and w.nameplateButton or w.passersByHelp, anchor, "off=" .. tostring(off))
                local _, below = w.passersByHelp:GetPoint()
                assert.are.equal(w.passersBy, below, "the help sits under the switch")
                -- The Buffs tab's places hang from buff mode's top-up stepper now (#491).
                buffsPlace("party")
                local _, tabAnchor = w.placeTabs.strangers:GetPoint()
                assert.are.equal(w.steppers.topUpMinutes.label, tabAnchor, "off=" .. tostring(off))
            end
        end)

        -- #417's testing review: sized to a width and pinned on one side, the
        -- simulator read it unwrapped and spilling out of its frame.
        it("its help line wraps inside the page: pinned on both sides, as the lines' help is", function()
            boot()
            favours()
            local _, helpRight = wow.horizontalEdges(w.passersByHelp, w.content)
            local _, linesRight = wow.horizontalEdges(w.linesHelp, w.content)
            assert.are.equal(linesRight, helpRight)
            local drawn = wow.drawnText(w.passersByHelp, w.content)
            assert.is_true(drawn.right <= helpRight, "its text stays inside its frame")
        end)

        it("says when friendly nameplates are off, and its button turns them on", function()
            boot({ nameplatesOff = true })
            favours()
            assert.is_true(w.nameplateWarning:IsVisible())
            assert.is_true(w.nameplateButton:IsVisible())
            wow.run(w.nameplateButton, "OnClick")
            assert.are.equal("1", wow.state.cvars.nameplateShowFriendlyPlayers)
            assert.is_false(w.nameplateWarning:IsVisible(), "they're on now")
            assert.is_false(w.nameplateButton:IsVisible())
        end)

        it("shows nothing about nameplates while they're on", function()
            boot()
            favours()
            assert.is_false(w.nameplateWarning:IsVisible())
            assert.is_false(w.nameplateButton:IsVisible())
        end)
    end)

    describe("the campfire trigger's box (white)", function()
        it("is among the turn-on triggers on the Buffs tab, on by default, with a tooltip", function()
            boot({ db = { buffBack = { autoOnCampfire = true } } })
            buffsPlace("party")
            local box = w.auto.autoOnCampfire
            assert.is_true(box:IsVisible())
            assert.are.equal("at a campfire", box.label:GetText())
            assert.is_true(box:GetChecked())
            assert.is_truthy(box.tooltip:find("camp benefit", 1, true))
            click(box, false)
            assert.is_false(ns.db.buffBack.autoOnCampfire)
        end)

        it("the walkthrough's turn-on step lists it", function()
            boot({ db = { buffBack = { autoOnCampfire = true } } })
            local text
            for _, step in ipairs(ns.Walkthrough.STEPS) do
                if step.title == "Buff mode: when it turns on and off" then text = step.text() end
            end
            assert.is_truthy(text:find("at a campfire: " .. ns.Colours.Text("good", "on"), 1, true))
        end)
    end)

    describe("Start here and the walkthrough (white, #455, #458)", function()
        it("Start here says how to turn buff mode on by hand, and links to the switch on the Favours tab", function()
            boot()
            local start = w.start
            wow.run(ns.Options.StartPage(), "OnShow")
            local text = start.buffModeSwitch:GetText()
            assert.is_truthy(text:find("shift-click the minimap button", 1, true))
            assert.is_truthy(text:find("/friendly buffmode", 1, true))
            assert.is_truthy(start.passersByNote:GetText():find("passers-by is off until you turn it on", 1, true))
            ns.db.buffBack.passersBy = true
            ns.Options.FillStart()
            assert.is_truthy(start.passersByNote:GetText():find("passers-by is on", 1, true), "it shows the saved state")
            local saved = ns.db.buffBack
            ns.db.buffBack = 7
            ns.Options.FillStart()
            assert.is_truthy(start.passersByNote:GetText():find("is off", 1, true), "a damaged section reads as off")
            ns.db.buffBack = saved
            -- The link scrolls the tab to the switch (#455's testing review):
            -- the switch can sit below the fold of a short panel.
            assert.are.equal("Passers-by switch (Favours tab)", start.openPassersBy:GetText())
            w.content.top, w.passersBy.top, w.scroll.scrollRange = 1000, 600, 2000
            wow.run(start.openPassersBy, "OnClick")
            assert.are.equal(388, w.scroll:GetVerticalScroll(), "scrolled to the switch, a margin above it")
            assert.are.equal(ns.Options.FAVOURS_TAB, ns.Options.CurrentType())
            assert.is_true(w.passersBy:IsVisible())
            assert.are.same({}, wow.errors)
        end)

        it("the walkthrough's Favours step mentions passers-by, and the Buffs step no longer does (#491)", function()
            boot()
            local buffsText, favoursText
            for _, step in ipairs(ns.Walkthrough.STEPS) do
                if step.title:find("buff order", 1, true) then buffsText = step.text() end
                if step.title == "Favours: thanking and buffing back" then favoursText = step.text() end
            end
            assert.is_truthy(buffsText, "the Buffs step")
            assert.is_falsy(buffsText:find("passers-by switch", 1, true))
            assert.is_falsy(buffsText:find("At the top", 1, true))
            assert.is_truthy(favoursText, "the Favours step")
            assert.is_truthy(favoursText:find("passers-by", 1, true))
        end)
    end)

    describe("finding them (white)", function()
        it("the options search finds the switch under passers-by, nearby and strangers, and the campfire", function()
            boot()
            local function names(word)
                local out = {}
                for _, entry in ipairs(ns.OptionsIndex.Find(word)) do out[entry.name] = entry.page end
                return out
            end
            for _, word in ipairs({ "passers-by", "nearby", "strangers" }) do
                assert.are.equal("the Favours tab", names(word)["Also offer my buffs to passers-by"],
                    word)
            end
            assert.are.equal("the Buffs tab", names("campfire")["Buff mode turns on by itself"])
        end)
    end)

    describe("carried along (white)", function()
        it("settings lines and profiles carry both", function()
            boot()
            ns.db.buffBack.passersBy = true
            ns.db.buffBack.autoOnCampfire = false
            local text = assert(ns.Profiles.Export())
            boot()
            assert.is_false(ns.db.buffBack.passersBy)
            assert.is_true(ns.Profiles.Import(text))
            assert.is_true(ns.db.buffBack.passersBy)
            assert.is_false(ns.db.buffBack.autoOnCampfire)
            local snap = ns.Profiles.Snapshot(ns.db)
            assert.is_true(snap.buffBack.passersBy)
            assert.is_false(snap.buffBack.autoOnCampfire)
        end)

        it("the Favours tab's Reset resets the switch (it's that tab's now), and the Buffs tab keeps no copy (#491)",
            function()
                boot()
                for _, field in ipairs(ns.BuffsTab.FIELDS) do
                    assert.are_not.equal("passersBy", field, "not a Buffs tab setting a Reset leaves alone")
                end
                ns.db.buffBack.passersBy = true
                ns.ResetType("buffBack")
                assert.is_false(ns.db.buffBack.passersBy)
                ns.db.buffBack.passersBy = true
                favours()
                wow.run(w.reset, "OnClick")
                assert.is_false(ns.db.buffBack.passersBy)
                assert.is_false(w.passersBy:GetChecked())
                -- The Buffs tab has no Reset of its own.
                wow.run(w.tabs.buffs, "OnClick")
                assert.is_false(w.reset:IsVisible())
            end)
    end)

    describe("damaged (black)", function()
        it("a damaged switch shows off on the tab, and heals as the tab fills", function()
            boot()
            ns.db.buffBack.passersBy = "yes"
            favours()
            assert.is_false(w.passersBy:GetChecked())
            assert.is_false(ns.db.buffBack.passersBy, "healed (#330)")
        end)
    end)
end)
