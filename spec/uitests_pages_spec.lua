-- Spec: #52, #112, #47
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
        -- The loop that writes each tab's script, whole: every tab, its own name, its own file.
        assert.is_truthy(workflow:find('\n%s*for tab in $OPTIONS_TABS; do\n'
            .. '%s*{ cat uitests/pages%.lua; printf \'\\nFriendlyForeverUIPages%.ShowTab%("%%s"%)\\n\' "$tab"; } \\\n'
            .. '%s*> "$states/tab%-$tab%.lua"\n%s*done\n'), "the loop writing each tab's script")
        assert.is_truthy(workflow:find('for tab in $OPTIONS_TABS; do\n%s*shoot "options%-$tab" %-%-exec%-lua "@/shot%-lua/tab%-$tab%.lua"\n'))
    end)

    -- The step's own loop, run as the workflow runs it (with comments
    -- dropped), into a scratch folder: one script per tab, each this file
    -- then ShowTab for that tab, and nothing else.
    it("writes each tab's screenshot script, named after the tab, ending with that tab (white)", function()
        local workflow = wow.readFile(".github/workflows/ui-sim.yml")
        local tabs = workflow:match("\n%s*OPTIONS_TABS: ([^\n]-)%s*\n")
        local loop = workflow:match("\n(%s*for tab in %$OPTIONS_TABS; do\n.-\n%s*done)\n")
        assert.is_truthy(tabs and loop, "the tab list or the loop writing the scripts is missing")
        assert.is_falsy(loop:find("shoot", 1, true), "found the shoot loop, not the one writing the scripts")
        local dir = os.tmpname()
        os.remove(dir)
        assert.is_true(os.execute("mkdir -p '" .. dir .. "'") == 0)
        local script = dir .. "/run.sh"
        local f = assert(io.open(script, "w"))
        f:write("set -eu\nstates='" .. dir .. "/out'\nmkdir -p \"$states\"\nOPTIONS_TABS='" .. tabs .. "'\n"
            .. loop .. "\n")
        f:close()
        local ok = os.execute("bash '" .. script .. "'")
        local pages = wow.readFile("uitests/pages.lua")
        local listed = io.popen("ls '" .. dir .. "/out'"):read("*a")
        local files = {}
        for name in listed:gmatch("[^\n]+") do files[#files + 1] = name end
        local written = {}
        for _, tab in ipairs(Pages.TABS) do
            local path = dir .. "/out/tab-" .. tab.name .. ".lua"
            local file = io.open(path)
            written[tab.name] = file and file:read("*a")
            if file then file:close() end
        end
        os.execute("rm -rf '" .. dir .. "'")
        assert.are.equal(0, ok)
        assert.are.equal(#Pages.TABS, #files, "scripts written: " .. listed)
        for _, tab in ipairs(Pages.TABS) do
            assert.are.equal(pages .. '\nFriendlyForeverUIPages.ShowTab("' .. tab.name .. '")\n', written[tab.name],
                tab.name)
        end
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

-- The walkthrough's steps the screenshots show (#47), taken again from the
-- Start here page as a player would.
describe("the UI simulator's walkthrough steps", function()
    local ns, Pages, printed

    before_each(function()
        ns = wow.boot({ walkthrough = true })
        printed = {}
        _G.A_Print = function(text) printed[#printed + 1] = text end
        dofile("uitests/pages.lua")
        Pages = _G.FriendlyForeverUIPages
    end)

    after_each(function()
        _G.FriendlyForeverUIPages = nil
        _G.A_Print = nil
    end)

    it("reaches each step by its title, from the Start here page's button (white)", function()
        for _, step in ipairs(Pages.WALKTHROUGH_STEPS) do
            local walkthrough = Pages.OpenWalkthrough(step.name)
            assert.are.equal(ns.Walkthrough.Frame(), walkthrough, step.name)
            assert.is_true(walkthrough:IsShown())
            assert.is_truthy(walkthrough.title:GetText():find(step.title, 1, true), step.name)
            assert.is_truthy(step.name:find("^[a-z][a-z-]*$"), step.name)
        end
        assert.are.equal("buffBack", ns.Options.CurrentType(), "the last step shot is on the Buff Back tab")
    end)

    it("skips the walkthrough a new install opened, by its button, before showing a page or tab", function()
        assert.is_true(ns.Walkthrough.Frame():IsShown())
        assert.is_false(ns.db.enabled)
        Pages.Open("general")
        assert.is_false(ns.Walkthrough.Frame():IsShown())
        assert.is_true(ns.db.enabled, "skipping a first run turns the addon on, as for a player")
        ns.Walkthrough.Start()
        Pages.OpenTab("buff-back")
        assert.is_false(ns.Walkthrough.Frame():IsShown())
        assert.are.same({ seen = 1, firstRun = false }, ns.db.walkthrough)
        assert.are.equal(ns.Options.StartPage(), Pages.Open("start"))
    end)

    it("answers a step name it doesn't know with a message, not a Lua error (black)", function()
        for _, name in ipairs({ "", "Welcome", "welcome ", 3, true, { "welcome" } }) do
            local ok, opened, why = pcall(Pages.OpenWalkthrough, name)
            assert.is_true(ok, tostring(opened))
            assert.is_nil(opened)
            assert.are.equal("no walkthrough step called " .. tostring(name), why)
            assert.are.equal(why, printed[#printed])
        end
        assert.is_true(pcall(Pages.ShowWalkthrough, nil))
        assert.are.equal("no walkthrough step called nil", printed[#printed])
    end)

    it("has the screenshot job shoot every step, each named after it, from its own script (white)", function()
        local workflow = wow.readFile(".github/workflows/ui-sim.yml")
        local names = {}
        for i, step in ipairs(Pages.WALKTHROUGH_STEPS) do names[i] = step.name end
        local steps = workflow:match("\n%s*WALKTHROUGH_STEPS: ([^\n]-)%s*\n")
        assert.are.equal(table.concat(names, " "), steps)
        assert.is_truthy(workflow:find('for step in $WALKTHROUGH_STEPS; do\n%s*shoot "walkthrough%-$step" '
            .. '%-%-exec%-lua "@/shot%-lua/walkthrough%-$step%.lua"\n'))
        assert.is_truthy(workflow:find("\n%s*for page in general ledger start; do\n"), "Start here's script")
        assert.is_truthy(workflow:find("\n%s*shoot options%-start %-%-exec%-lua @/shot%-lua/page%-start%.lua\n"))
        -- The loop writing each step's script, run as the workflow runs it.
        local loop = workflow:match("\n(%s*for step in %$WALKTHROUGH_STEPS; do\n.-\n%s*done)\n")
        assert.is_falsy(loop:find("shoot", 1, true), "found the shoot loop, not the one writing the scripts")
        local dir = os.tmpname()
        os.remove(dir)
        assert.is_true(os.execute("mkdir -p '" .. dir .. "'") == 0)
        local script = dir .. "/run.sh"
        local f = assert(io.open(script, "w"))
        f:write("set -eu\nstates='" .. dir .. "/out'\nmkdir -p \"$states\"\nWALKTHROUGH_STEPS='" .. steps .. "'\n"
            .. loop .. "\n")
        f:close()
        local ok = os.execute("bash '" .. script .. "'")
        local pages = wow.readFile("uitests/pages.lua")
        local written = {}
        for _, name in ipairs(names) do
            local file = io.open(dir .. "/out/walkthrough-" .. name .. ".lua")
            written[name] = file and file:read("*a")
            if file then file:close() end
        end
        local listed = io.popen("ls '" .. dir .. "/out'"):read("*a")
        os.execute("rm -rf '" .. dir .. "'")
        assert.are.equal(0, ok)
        assert.are.equal(#names, select(2, listed:gsub("\n", "")), "scripts written: " .. listed)
        for _, name in ipairs(names) do
            assert.are.equal(pages .. '\nFriendlyForeverUIPages.ShowWalkthrough("' .. name .. '")\n', written[name])
        end
    end)
end)
