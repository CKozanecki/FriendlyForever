-- Spec: #52, #112, #158, #47, #169, #208, #209, #254
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

-- The Buff Back tab's buffs by their Forever names (#158): the simulator's
-- spell data has none of Forever's buffs, so the fixture answers their
-- names, and the tab's LAYOUT lines measure what a player reads.
describe("the UI simulator's Buff Back names", function()
    local ns, Pages, original

    before_each(function()
        ns = wow.boot({ before = function(state) state.class = "PALADIN" end })
        _G.A_Print = function() end -- OpenTab's message: the simulated panel has no tab buttons
        dofile("uitests/pages.lua")
        Pages = _G.FriendlyForeverUIPages
        original = _G.C_Spell.GetSpellName
    end)

    after_each(function()
        _G.C_Spell.GetSpellName = original
        _G.FriendlyForeverUIPages = nil
        _G.A_Print = nil
    end)

    -- The row texts the Buff Back tab shows now.
    local function rows()
        ns.Options.SelectType("buffBack")
        local texts = {}
        for _, row in ipairs(ns.Options.widgets.buffRows) do
            if row.name:IsShown() then texts[#texts + 1] = row.name:GetText() end
        end
        return texts
    end

    it("names every paladin buff BuffData lists, at every one of its ranks (white)", function()
        local paladin = ns.BuffData.CLASSES.PALADIN
        assert.are.equal(#paladin, #Pages.BUFF_NAMES)
        for i, buff in ipairs(paladin) do
            assert.are.equal(buff.key, Pages.BUFF_NAMES[i].key)
            assert.are.same(buff.ranks, Pages.BUFF_NAMES[i].ranks, buff.key)
        end
    end)

    it("shows each row of the tab with its Forever name, the longest Blessing of Wisdom (white)", function()
        local seen
        Pages.WithBuffNames(function() seen = rows() end)
        assert.are.equal(3, #seen)
        for i, buff in ipairs(Pages.BUFF_NAMES) do
            assert.are.equal(i .. ". " .. buff.name, seen[i]:match("^(.-) |c") or seen[i])
        end
        assert.are.equal("2. Blessing of Wisdom", seen[2]:match("^(.-) |c") or seen[2])
    end)

    it("leaves the tab on the buff keys without it, which is what it fixes (white)", function()
        -- The simulator knows none of Forever's buffs; the test client knows
        -- Might's name, so take it away for this look.
        local saved = {}
        for _, id in ipairs(ns.BuffData.ByKey("might").ranks) do saved[id], wow.SPELL_NAMES[id] = wow.SPELL_NAMES[id], nil end
        local seen = rows()
        for id, name in pairs(saved) do wow.SPELL_NAMES[id] = name end
        assert.is_truthy(seen[3]:find("^3%. might"), seen[3])
    end)

    it("passes every other spell, and anything that isn't a spell ID, to the client's own (black)", function()
        local asked = {}
        _G.C_Spell.GetSpellName = function(...)
            asked[#asked + 1] = { ... }
            return "client's " .. tostring((...))
        end
        local undo = Pages.NameBuffs()
        assert.are.equal("Blessing of Wisdom", _G.C_Spell.GetSpellName(25290))
        assert.are.equal(0, #asked)
        for _, spell in ipairs({ 10938, 999999, "Blessing of Wisdom", 0, -1, 19742.5, true, {} }) do
            assert.are.equal("client's " .. tostring(spell), _G.C_Spell.GetSpellName(spell, "extra"))
            assert.are.same({ spell, "extra" }, asked[#asked])
        end
        assert.are.equal("client's nil", _G.C_Spell.GetSpellName(nil))
        undo()
    end)

    it("answers nothing for other spells when the client has no GetSpellName (black)", function()
        _G.C_Spell.GetSpellName = nil
        local undo = Pages.NameBuffs()
        assert.are.equal("Blessing of Kings", _G.C_Spell.GetSpellName(20217))
        assert.is_nil(_G.C_Spell.GetSpellName(10938))
        undo()
        assert.is_nil(_G.C_Spell.GetSpellName)
    end)

    it("puts the client's GetSpellName back afterwards (white)", function()
        Pages.WithBuffNames(function()
            assert.are_not.equal(original, _G.C_Spell.GetSpellName)
        end)
        assert.are.equal(original, _G.C_Spell.GetSpellName)
        assert.is_truthy(rows()[3]:find("Blessing of Might", 1, true), "the test client's own name")
    end)

    it("puts the client's GetSpellName back even when the scenario fails, and raises its error (white)", function()
        for _, failure in ipairs({ "a layout check failed", { reason = "a table" } }) do
            local ok, err = pcall(Pages.WithBuffNames, function()
                assert.are.equal("Blessing of Wisdom", _G.C_Spell.GetSpellName(19742))
                error(failure, 0)
            end)
            assert.is_false(ok)
            assert.are.equal(failure, err)
            assert.are.equal(original, _G.C_Spell.GetSpellName)
        end
    end)

    it("has the screenshot job take options-buff-back-lower at both sizes, from its own script (white, #254)", function()
        local workflow = wow.readFile(".github/workflows/ui-sim.yml")
        assert.is_truthy(workflow:find('FriendlyForeverUIPages%.ShowTabLower%("buff%-back"%)', 1))
        assert.is_truthy(workflow:find('> "$states/tab%-buff%-back%-lower%.lua"', 1))
        -- Inside shoot_all, so both passes (and their suffixes) take it.
        local all = workflow:match("shoot_all%(%) {\n(.-)\n%s*}\n%s*for size in")
        assert.is_truthy(all and all:find('shoot options%-buff%-back%-lower %-%-exec%-lua "@/shot%-lua/tab%-buff%-back%-lower%.lua"'))
    end)

    it("answers no panel to scroll with a message, not a Lua error (black, #254)", function()
        _G.FriendlyForeverOptionsPanel = nil
        local ok, undo, why = pcall(Pages.ScrollToBottom)
        assert.is_true(ok)
        assert.is_nil(undo)
        assert.is_truthy(why)
    end)

    it("leaves the names in place for the screenshot taken after ShowTab (white)", function()
        Pages.ShowTab("buff-back")
        assert.are.equal("Blessing of Wisdom", _G.C_Spell.GetSpellName(19742))
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

    it("scrolls the Buff Back tab to the bottom for its lower shot, and the undo puts the scroll back (white, #254)", function()
        -- The simulated panel has no tab buttons to click: open the tab as the walkthrough does.
        ns.Options.OpenTab("buffBack")
        local scroll = ns.Options.widgets.scroll
        scroll:SetVerticalScroll(0)
        -- The simulated client has no child lists or layout: give the panel its scroll frame, and the frame a range.
        scroll.scrollRange = 300
        scroll.GetScrollChild = function() return ns.Options.widgets.content end
        _G.FriendlyForeverOptionsPanel.GetChildren = function() return scroll end
        local undo = Pages.ScrollToBottom()
        local range = scroll:GetVerticalScrollRange()
        assert.are.equal(300, range)
        assert.are.equal(range, scroll:GetVerticalScroll())
        undo()
        assert.are.equal(0, scroll:GetVerticalScroll())
    end)

    it("shows the lower Buff Back tab from the tab's own script, with the buffs named (white, #254)", function()
        _G.A_Print = function() end -- OpenTab's message: the simulated panel has no tab buttons
        local scroll = ns.Options.widgets.scroll
        scroll.scrollRange = 300
        scroll.GetScrollChild = function() return ns.Options.widgets.content end
        _G.FriendlyForeverOptionsPanel.GetChildren = function() return scroll end
        local undo = Pages.ShowTabLower("buff-back")
        assert.is_function(undo)
        assert.are.equal(300, scroll:GetVerticalScroll())
        assert.are.equal("Blessing of Wisdom", _G.C_Spell.GetSpellName(19742))
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
        assert.are.same({ seen = ns.Config.WALKTHROUGH_VERSION, firstRun = false }, ns.db.walkthrough)
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
