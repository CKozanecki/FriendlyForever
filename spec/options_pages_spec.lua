-- The options added with 1.7.0: thank style, loading a line set, and the
-- General and Favour Ledger pages.
local wow = require("spec.support.wow")

describe("Options", function()
    local ns, w

    before_each(function()
        ns = wow.boot()
        w = ns.Options.widgets
    end)

    it("lists General and Favour Ledger under Friendly Forever", function()
        local names = {}
        for _, sub in ipairs(wow.settings.subcategories) do
            names[#names + 1] = sub.name
            assert.are.equal(4242, sub.parent:GetID())
        end
        assert.are.same({ "General", "Favour Ledger" }, names)
    end)

    describe("message tabs", function()
        it("cycles how buff thanks are given, shown on the buff tab only", function()
            wow.run(w.tabs.guildLogin, "OnClick")
            assert.is_false(w.thankStyle:IsShown())
            wow.run(w.tabs.buff, "OnClick")
            assert.is_true(w.thankStyle:IsShown())
            assert.are.equal(ns.Options.THANK_STYLE_TEXT.message, w.thankStyle:GetText())
            wow.run(w.thankStyle, "OnClick")
            assert.are.equal("emote", ns.db.buff.thankStyle)
            assert.are.equal(ns.Options.THANK_STYLE_TEXT.emote, w.thankStyle:GetText())
            wow.run(w.thankStyle, "OnClick")
            assert.are.equal("both", ns.db.buff.thankStyle)
            wow.run(w.thankStyle, "OnClick")
            assert.are.equal("message", ns.db.buff.thankStyle)
        end)

        it("loads the fantasy or casual lines into this tab only, keeping its other settings", function()
            wow.run(w.tabs.partyJoin, "OnClick")
            ns.db.partyJoin.delay = 9
            ns.db.guildLogin.messages[1] = "mine"
            wow.run(w.loadFantasy, "OnClick")
            assert.are.same(ns.DefaultMessages.partyJoin, ns.db.partyJoin.messages)
            assert.are.equal(ns.DefaultMessages.partyJoin[1], w.edits[1]:GetText())
            wow.run(w.loadCasual, "OnClick")
            assert.are.same(ns.CasualMessages.partyJoin, ns.db.partyJoin.messages)
            assert.are.equal(9, ns.db.partyJoin.delay)
            assert.are.equal("mine", ns.db.guildLogin.messages[1])
            ns.db.partyJoin.messages[2] = "edited"
            assert.are.equal(ns.CasualMessages.partyJoin[2], "Hi {name}, glad to have you with us!",
                "loading gives a copy: editing it leaves the shipped set alone")
        end)
    end)

    describe("General page", function()
        local g

        before_each(function()
            g = w.general
            ns.Options.FillGeneral()
        end)

        it("snoozes and wakes", function()
            assert.is_false(g.wake:IsEnabled())
            wow.run(g.snooze60, "OnClick")
            assert.are.equal(3600, ns.Announcer.SnoozeLeft())
            assert.is_truthy(g.snoozeState:GetText():find("60 more min", 1, true))
            assert.is_true(g.wake:IsEnabled())
            wow.run(g.wake, "OnClick")
            assert.is_nil(ns.Announcer.SnoozeLeft())
        end)

        it("adds and removes ignored players from the box, or your target", function()
            g.ignoreBox:SetText("Bob Stone")
            wow.run(g.ignoreAdd, "OnClick")
            assert.is_true(ns.Ignore.Has("Bob-Stone"))
            assert.are.equal("", g.ignoreBox:GetText())
            assert.are.equal("Bob Stone", g.ignoreList:GetText())
            wow.addUnit("target", { name = "Ann", surname = "Vale" })
            wow.run(g.ignoreAdd, "OnClick")
            assert.are.equal("Ann Vale, Bob Stone", g.ignoreList:GetText())
            g.ignoreBox:SetText("Bob Stone")
            wow.run(g.ignoreRemove, "OnClick")
            assert.are.equal("Ann Vale", g.ignoreList:GetText())
        end)

        it("makes, uses and deletes profiles", function()
            g.profileBox:SetText("Raiding")
            wow.run(g.profileNew, "OnClick")
            assert.are.equal("Raiding", ns.Profiles.Active())
            assert.is_truthy(g.profileState:GetText():find("Using Raiding", 1, true))
            g.profileBox:SetText("Default")
            wow.run(g.profileUse, "OnClick")
            g.profileBox:SetText("Raiding")
            wow.run(g.profileDelete, "OnClick")
            assert.are.same({ "Default" }, ns.Profiles.List())
        end)

        it("opens export and import, and enables undo only after an import", function()
            assert.is_false(g.undoImport:IsEnabled())
            wow.run(g.export, "OnClick")
            local text = ns.Window.Frame().box:GetText()
            wow.run(g.import, "OnClick")
            ns.Window.Frame().box:SetText(text)
            wow.run(ns.Window.Frame().accept, "OnClick")
            ns.Options.FillGeneral()
            assert.is_true(g.undoImport:IsEnabled())
            wow.run(g.undoImport, "OnClick")
            assert.is_false(g.undoImport:IsEnabled())
        end)

        it("opens the bug report", function()
            wow.run(g.report, "OnClick")
            assert.is_truthy(ns.Window.Frame().box:GetText():find("bug report", 1, true))
        end)
    end)

    describe("Favour Ledger page", function()
        it("shows the counts and the newest favours, and clears", function()
            ns.Ledger.Settle(ns.Ledger.Received("Bob-Stone", "Arcane Intellect"), true)
            ns.Options.FillLedger()
            local l = w.ledger
            assert.is_truthy(l.summary:GetText():find("buffed by 1, thanked 1", 1, true))
            assert.is_truthy(l.rows[1]:GetText():find("^Bob Stone %- Arcane Intellect %- thanked"))
            assert.are.equal("", l.rows[2]:GetText())
            wow.run(l.clear, "OnClick")
            assert.are.equal("Nobody outside your group has buffed you yet.", l.rows[1]:GetText())
        end)

        it("shows names safely (no escape codes from a buff name)", function()
            ns.Ledger.Received("Bob-Stone", "Evil|cff00ff00Buff")
            ns.Options.FillLedger()
            assert.is_nil(w.ledger.rows[1]:GetText():find("|c", 1, true))
        end)
    end)
end)
