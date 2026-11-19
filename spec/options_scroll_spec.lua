-- Spec: #482
-- Each options page and sub-tab scrolls only as far as its last shown
-- control, plus a small margin; a page that fits has no scroll range and no
-- scroll bar. The simulated client lays nothing out, so these specs give the
-- edges themselves (region.top and region.bottom) and leave every other row
-- unplaced (nil), which the fit must pass over. The UI simulator's layout
-- checks measure the real layout.
local wow = require("spec.support.wow")

local TOP, VIEW = 1000, 500

describe("Options pages scroll only to their last control (#482)", function()
    local ns, w

    local function boot()
        ns = wow.boot({})
        ns.Options.Open()
        w = ns.Options.widgets
        w.content.top = TOP
        w.scroll.height = VIEW
    end

    -- Every shown frame and text line on content, unplaced.
    local function unplace(content)
        for _, f in ipairs({ content:GetChildren() }) do f.bottom = nil end
        for _, r in ipairs({ content:GetRegions() }) do r.bottom = nil end
    end

    -- What the game would give as the range for this content and view.
    local function range(scroll, content)
        return math.max(0, content:GetHeight() - scroll:GetHeight())
    end

    describe("white: the range is the content's real height less the pane's", function()
        it("a tab whose last control ends 800 px down is 816 px tall and scrolls 316", function()
            boot()
            ns.Options.SelectType("guildLogin")
            unplace(w.content)
            w.edits[30].bottom = TOP - 800
            ns.Options.Refresh()
            assert.are.equal(800 + ns.Options.SCROLL_MARGIN, w.content:GetHeight())
            assert.are.equal(316, range(w.scroll, w.content))
            assert.is_true(w.scroll.ScrollBar:IsShown())
        end)

        it("counts the lowest shown row, text lines included, wherever it is in the list", function()
            boot()
            unplace(w.content)
            w.edits[30].bottom = TOP - 600
            w.header.bottom = TOP - 900 -- a text line, made before the boxes
            ns.Options.Refresh()
            assert.are.equal(900 + ns.Options.SCROLL_MARGIN, w.content:GetHeight())
        end)

        it("leaves out hidden rows and the lists that float over the tab", function()
            boot()
            ns.Options.SelectType(ns.Options.BUFFS_TAB)
            unplace(w.content)
            w.buffsHeader.bottom = TOP - 700
            w.edits[30].bottom = TOP - 3000 -- a message tab's row, hidden on the Buffs tab
            w.whoList:Show()
            w.whoList.bottom = TOP - 2500 -- open over the rows
            ns.Options.FitHeight(w.scroll, w.content)
            assert.are.equal(700 + ns.Options.SCROLL_MARGIN, w.content:GetHeight())
        end)

        it("the Start here and General pages follow their own last lines", function()
            boot()
            local general = ns.Options.Pages()
            local start = ns.Options.StartPage()
            for _, page in ipairs({ general, start }) do
                page.content.top, page.scroll.height = TOP, VIEW
                unplace(page.content)
            end
            general.widgets.undoImport.bottom = TOP - 640
            start.widgets.buffModeKey.bottom = TOP - 300
            ns.Options.Refresh()
            assert.are.equal(640 + ns.Options.SCROLL_MARGIN, general.content:GetHeight())
            assert.is_true(general.scroll.ScrollBar:IsShown())
            assert.are.equal(300 + ns.Options.SCROLL_MARGIN, start.content:GetHeight())
            assert.is_false(start.scroll.ScrollBar:IsShown())
        end)

        it("asks Blizzard's scroll frame code to hide the bar of a page that fits", function()
            boot()
            local general = ns.Options.Pages()
            assert.is_true(w.scroll.scrollBarHideable)
            assert.is_true(general.scroll.scrollBarHideable)
            assert.is_true(ns.Options.StartPage().scroll.scrollBarHideable)
        end)

        it("fits again on the next frame after a show, once the settings window has laid it out", function()
            boot()
            unplace(w.content)
            ns.Options.SelectType("partyJoin")
            local before = w.content:GetHeight()
            wow.run(w.scroll, "OnShow")
            assert.are.equal(before, w.content:GetHeight())
            w.edits[30].bottom = TOP - 450
            wow.advance(0)
            assert.are.equal(450 + ns.Options.SCROLL_MARGIN, w.content:GetHeight())
        end)

        it("fits again when the pane changes size", function()
            boot()
            unplace(w.content)
            w.edits[30].bottom = TOP - 450
            ns.Options.Refresh()
            assert.is_false(w.scroll.ScrollBar:IsShown())
            w.scroll.height = 300
            wow.run(w.scroll, "OnSizeChanged", 600, 300)
            assert.is_true(w.scroll.ScrollBar:IsShown())
        end)
    end)

    describe("white: a page shorter than the pane", function()
        it("has no scroll range, no offset and no scroll bar", function()
            boot()
            unplace(w.content)
            w.edits[30].bottom = TOP - 1500
            ns.Options.Refresh()
            w.scroll:SetVerticalScroll(900)
            w.edits[30].bottom = TOP - 300
            ns.Options.Refresh()
            assert.are.equal(0, range(w.scroll, w.content))
            assert.are.equal(0, w.scroll:GetVerticalScroll())
            assert.is_false(w.scroll.ScrollBar:IsShown())
        end)
    end)

    describe("black: switching to a sub-tab or tab with less on it", function()
        it("a place with less content brings the offset back inside its smaller range", function()
            boot()
            ns.Options.SelectType(ns.Options.BUFFS_TAB)
            unplace(w.content)
            w.raidSplit.bottom = TOP - 1500 -- shown only for raids
            w.soloOwnBuffs.bottom = TOP - 700 -- shown only for parties
            ns.BuffsTab.SelectPlace("raid")
            assert.are.equal(1500 + ns.Options.SCROLL_MARGIN, w.content:GetHeight())
            local deepest = range(w.scroll, w.content)
            w.scroll:SetVerticalScroll(deepest)
            ns.BuffsTab.SelectPlace("party")
            assert.are.equal(700 + ns.Options.SCROLL_MARGIN, w.content:GetHeight())
            assert.are.equal(range(w.scroll, w.content), w.scroll:GetVerticalScroll())
            assert.is_true(w.scroll:GetVerticalScroll() < deepest)
        end)

        it("a message tab after the long Buffs tab doesn't scroll into empty space", function()
            boot()
            unplace(w.content)
            w.edits[30].bottom = TOP - 520
            w.buffsHeader.bottom = TOP - 2000
            ns.Options.SelectType(ns.Options.BUFFS_TAB)
            w.scroll:SetVerticalScroll(range(w.scroll, w.content))
            ns.Options.SelectType("guildJoin")
            assert.are.equal(36, range(w.scroll, w.content))
            assert.are.equal(36, w.scroll:GetVerticalScroll())
        end)

        it("edges the game can't give yet, or that aren't numbers, change nothing", function()
            boot()
            local before = w.content:GetHeight()
            unplace(w.content)
            ns.Options.Refresh()
            assert.are.equal(before, w.content:GetHeight())
            w.edits[30].bottom = 0 / 0
            ns.Options.Refresh()
            assert.are.equal(before, w.content:GetHeight())
            w.edits[30].bottom = TOP - 700
            w.content.top = nil
            ns.Options.Refresh()
            assert.are.equal(before, w.content:GetHeight())
        end)
    end)
end)
