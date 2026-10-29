-- Spec: #52, #58, #80, #112
-- The options added with 0.8.0: thank style, loading a line set, and the
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

    it("names the pages' frames, so the UI simulator's scenarios can find them", function()
        local general, ledger = ns.Options.Pages()
        assert.are.equal(general, _G.FriendlyForeverGeneralPage)
        assert.are.equal(ledger, _G.FriendlyForeverLedgerPage)
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

        -- The tabs' rows are on the panel's scrolling content, which takes
        -- the scroll frame's width each time the panel is shown, and again a
        -- frame later, as the General page's does (#52). The UI simulator
        -- laid it out without a size change, leaving it 28 px wide (#112).
        it("fits its scrolling content to the panel's width when shown", function()
            assert.are.equal(w.scroll, w.content.parent)
            w.scroll.width = 640
            wow.run(w.scroll, "OnShow")
            assert.are.equal(640, w.content:GetWidth())
            w.scroll.width = 655
            wow.advance(0)
            assert.are.equal(655, w.content:GetWidth())
            w.scroll.width = 0
            wow.run(w.scroll, "OnShow")
            wow.advance(0)
            assert.are.equal(655, w.content:GetWidth(), "a scroll frame not laid out yet changes nothing")
            wow.run(w.scroll, "OnSizeChanged", 700, 400)
            assert.are.equal(700, w.content:GetWidth())
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
            assert.are.equal("Nobody.", g.ignoreList:GetText())
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

        -- White box: in the game wrapped text grows its line and pushes the
        -- rest down, so every line sits on the scrolling content, and only
        -- the heading stays on the page (#52).
        it("puts its lines in a scrolling area below the heading", function()
            local page = ns.Options.Pages()
            assert.are.equal("UIPanelScrollFrameTemplate", page.scroll.template)
            assert.are.equal(page, page.scroll.parent)
            assert.are.equal(page.scroll, page.content.parent)
            assert.are.equal(ns.Options.GENERAL_HEIGHT, page.content.height)
            assert.are.equal(page, page.heading.parent)
            local point, relativeTo, relativePoint = page.scroll:GetPoint(1)
            assert.are.same({ "TOPLEFT", page.heading, "BOTTOMLEFT" }, { point, relativeTo, relativePoint },
                "the scrolling area starts below the heading")
            local sections = 0
            for _, f in ipairs(wow.frames) do
                if f.kind == "FontString" and f.font == "GameFontNormal" and f.parent == page.content then
                    sections = sections + 1
                end
                if f.kind == "FontString" and f.text == "Snooze" then
                    assert.are.equal(page.content, f.parent, "the Snooze heading")
                end
            end
            assert.is_true(sections >= 5, "section headings on the content")
            for _, key in ipairs({ "snoozeState", "capHelp", "ignoreList", "ignoreHelp", "profileState",
                "profileHelp", "shareHelp", "reportHelp", "snooze15", "ignoreBox", "profileNew", "report" }) do
                assert.are.equal(page.content, g[key].parent, key)
            end
        end)

        -- The content takes the scroll frame's width each time the page is
        -- shown, and again a frame later, not only when a size change
        -- reaches the scroll frame (#52).
        it("fits its scrolling content to the page's width when shown", function()
            local page = ns.Options.Pages()
            page.scroll.width = 640
            wow.run(page.scroll, "OnShow")
            assert.are.equal(640, page.content:GetWidth())
            page.scroll.width = 655
            wow.advance(0)
            assert.are.equal(655, page.content:GetWidth())
            page.scroll.width = 0
            wow.run(page.scroll, "OnShow")
            wow.advance(0)
            assert.are.equal(655, page.content:GetWidth(), "a scroll frame not laid out yet changes nothing")
            -- Resized while open (UI scale, resolution): no show, just a size change.
            wow.run(page.scroll, "OnSizeChanged", 700, 400)
            assert.are.equal(700, page.content:GetWidth())
        end)

        -- Black box: a long profile list is cut the way the ignore list is,
        -- and says where to see the rest (#52).
        it("lists six profiles, then counts the rest", function()
            for i = 1, 5 do ns.Profiles.New("Team " .. i) end
            ns.Options.FillGeneral()
            local text = g.profileState:GetText()
            assert.are.equal(6, #ns.Profiles.List())
            assert.is_nil(text:find("more", 1, true))
            for _, name in ipairs(ns.Profiles.List()) do assert.is_truthy(text:find(name, 1, true), name) end
            ns.Profiles.New("Team 6")
            ns.Profiles.New("Team 7")
            ns.Options.FillGeneral()
            text = g.profileState:GetText()
            assert.is_truthy(text:find("Using Team 7.", 1, true))
            assert.is_truthy(text:find(" and 2 more (/friendly profile shows them all).", 1, true))
            local list = ns.Profiles.List()
            assert.is_truthy(text:find(list[6] .. " and 2 more", 1, true))
            assert.is_nil(text:find(list[7] .. ",", 1, true))
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

        -- The note says when buffs are recorded; it must match the rule
        -- BuffTracker.Watching applies.
        it("says buffs are recorded while Buff Thanks or Buff Back is on, as they are", function()
            assert.is_truthy(w.ledger.note:GetText():find("while Buff Thanks or Buff Back is on", 1, true))
            for _, case in ipairs({
                { thanks = true, back = false, watching = true },
                { thanks = false, back = true, watching = true },
                { thanks = true, back = true, watching = true },
                { thanks = false, back = false, watching = false },
            }) do
                ns.db.buff.enabled, ns.db.buffBack.enabled = case.thanks, case.back
                assert.are.equal(case.watching, ns.BuffTracker.Watching() and true or false,
                    ("thanks %s, back %s"):format(tostring(case.thanks), tostring(case.back)))
            end
        end)

        it("shows names safely (no escape codes from a buff name)", function()
            ns.Ledger.Received("Bob-Stone", "Evil|cff00ff00Buff")
            ns.Options.FillLedger()
            assert.is_nil(w.ledger.rows[1]:GetText():find("|c", 1, true))
        end)
    end)
end)
