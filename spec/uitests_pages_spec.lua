-- Spec: #52, #112
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

-- The main panel's tabs (#112): one screenshot and set of LAYOUT lines per
-- tab, so the fixture's list must be the panel's, in its order.
describe("the UI simulator's options tabs", function()
    local ns, Pages, printed

    before_each(function()
        ns = wow.boot()
        printed = {}
        _G.A_Print = function(text) printed[#printed + 1] = text end
        dofile("uitests/pages.lua")
        Pages = _G.FriendlyForeverUIPages
    end)

    after_each(function()
        _G.FriendlyForeverUIPages = nil
        _G.A_Print = nil
    end)

    it("names every tab the panel has, by its button's text, in the panel's order (white)", function()
        assert.are.equal(#ns.Config.TYPES, #Pages.TABS)
        local names = {}
        for i, msgType in ipairs(ns.Config.TYPES) do
            local tab = Pages.TABS[i]
            assert.are.equal(ns.Config.TYPE_INFO[msgType].label, tab.label)
            -- Plain names: they become file names the publish job accepts.
            assert.is_truthy(tab.name:find("^[a-z][a-z-]*$"), tab.name)
            assert.is_nil(names[tab.name], "two tabs called " .. tab.name)
            names[tab.name] = true
        end
    end)

    it("has the screenshot job shoot every tab, each named after it (white)", function()
        local workflow = wow.readFile(".github/workflows/ui-sim.yml")
        local names = {}
        for i, tab in ipairs(Pages.TABS) do names[i] = tab.name end
        assert.are.equal(table.concat(names, " "), workflow:match("\n%s*OPTIONS_TABS: ([^\n]-)%s*\n"))
        assert.is_truthy(workflow:find("FriendlyForeverUIPages.ShowTab(\"%s\")", 1, true))
        assert.is_truthy(workflow:find('for tab in $OPTIONS_TABS; do\n%s*shoot "options%-$tab" %-%-exec%-lua "@/shot%-lua/tab%-$tab%.lua"\n'))
    end)

    it("answers a tab name it doesn't know with a message, not a Lua error (black)", function()
        for _, name in ipairs({ "", "Buff Back", "buffBack", "general", 42, true, { "buff-back" } }) do
            local ok, opened, why = pcall(Pages.OpenTab, name)
            assert.is_true(ok, tostring(opened))
            assert.is_nil(opened)
            assert.is_truthy(why:find("no options tab called " .. tostring(name), 1, true), why)
            assert.is_truthy(why:find("guild-login, buff-thanks", 1, true), why)
            assert.are.equal(why, printed[#printed])
        end
        local ok, opened, why = pcall(Pages.OpenTab, nil)
        assert.is_true(ok, tostring(opened))
        assert.is_nil(opened)
        assert.is_truthy(why:find("no options tab called nil", 1, true), why)
        -- ShowTab, as the screenshot job calls it, answers the same way.
        assert.is_true(pcall(Pages.ShowTab, "nope"))
        assert.is_truthy(printed[#printed]:find("no options tab called nope", 1, true))
    end)
end)
