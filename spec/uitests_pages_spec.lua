-- Spec: #52
-- The UI simulator's fill (uitests/pages.lua), loaded against the simulated
-- client. The addon checks saved settings when it uses them and repairs what
-- it can't trust, so a fill it would throw away leaves the simulator's
-- worst-case pages showing the defaults. The expected counts come from the
-- fill's own constants, not from the addon.
local wow = require("spec.support.wow")

describe("the UI simulator's page fill", function()
    local ns, Pages, undo

    before_each(function()
        ns = wow.boot()
        dofile("uitests/pages.lua")
        Pages = _G.FriendlyForeverUIPages
        undo = Pages.Fill()
    end)

    after_each(function()
        _G.FriendlyForeverUIPages = nil
    end)

    it("is kept whole by the addon: every name, profile and entry", function()
        assert.are.equal(Pages.IGNORED, #ns.Ignore.List())
        assert.are.equal(Pages.PROFILES, #ns.Profiles.List())
        assert.are.equal("Raid nights in Naxxramas, team 1", ns.Profiles.Active())
        assert.are.equal(Pages.ENTRIES, #ns.Ledger.Lines(Pages.ENTRIES + 5))
    end)

    it("fills more than the General page lists, at the longest names allowed", function()
        assert.is_true(Pages.IGNORED > ns.Options.IGNORE_SHOWN)
        assert.is_true(Pages.PROFILES > ns.Options.PROFILES_SHOWN)
        local longest = 0
        for _, name in ipairs(ns.Profiles.List()) do longest = math.max(longest, #name) end
        assert.are.equal(ns.Profiles.MAX_NAME, longest)
        ns.Options.FillGeneral()
        local text = ns.Options.widgets.general.profileState:GetText()
        assert.is_truthy(text:find("and 3 more", 1, true))
    end)

    it("puts back the settings it changed", function()
        undo()
        assert.are.equal(0, #ns.Ignore.List())
        assert.are.same({ "Default" }, ns.Profiles.List())
        assert.are.equal(0, #ns.Ledger.Lines(5))
    end)
end)
