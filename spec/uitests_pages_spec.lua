-- Spec: #52, #112, #158, #47, #169, #208, #209, #254, #160, #44
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

-- The Buff Back tab's buffs by their Forever names (#158), so the tab's
-- LAYOUT lines measure what a player reads. The simulator has Forever's
-- spell data since #160 and names them itself; pages.lua lists the names
-- the tab must show and checks the client gives them.
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

    -- Its buffs for others: the simulator has no spell data for the
    -- self-buffs (#44) until #343, so it can't name them.
    local function forOthers()
        local list = {}
        for _, buff in ipairs(ns.BuffData.CLASSES.PALADIN) do
            if not buff.selfCast then list[#list + 1] = buff end
        end
        return list
    end

    it("names every paladin buff for others BuffData lists, at every one of its ranks (white)", function()
        local paladin = forOthers()
        assert.are.equal(3, #paladin)
        assert.are.equal(#paladin, #Pages.BUFF_NAMES)
        for i, buff in ipairs(paladin) do
            assert.are.equal(buff.key, Pages.BUFF_NAMES[i].key)
            assert.are.same(buff.ranks, Pages.BUFF_NAMES[i].ranks, buff.key)
        end
    end)

    -- #160: the simulator names Forever's buffs itself now, so nothing here
    -- answers for it. UnnamedBuff says whether the client does, and the tab
    -- scenarios fail on its message: rows of buff keys would pass every
    -- layout check on text far shorter than a player reads (#158).
    it("says nothing is unnamed when the client names every rank as on Forever (white)", function()
        _G.C_Spell.GetSpellName = function(id)
            for _, buff in ipairs(Pages.BUFF_NAMES) do
                for _, rank in ipairs(buff.ranks) do
                    if rank == id then return buff.name end
                end
            end
        end
        assert.is_nil(Pages.UnnamedBuff())
    end)

    it("shows each row of the tab with the name the client gives, the longest Blessing of Wisdom (white)", function()
        local names = {}
        for _, buff in ipairs(Pages.BUFF_NAMES) do
            for _, rank in ipairs(buff.ranks) do names[rank] = buff.name end
        end
        _G.C_Spell.GetSpellName = function(id) return names[id] end
        assert.is_nil(Pages.UnnamedBuff())
        local seen = rows()
        assert.are.equal(#ns.BuffData.CLASSES.PALADIN, #seen)
        for i, buff in ipairs(Pages.BUFF_NAMES) do
            assert.are.equal(i .. ". " .. buff.name, seen[i]:match("^(.-) |c") or seen[i])
        end
        assert.are.equal("2. Blessing of Wisdom", seen[2]:match("^(.-) |c") or seen[2])
        -- The self-buffs follow, by their keys while the client has no name
        -- for them (the simulator until #343).
        for i = #Pages.BUFF_NAMES + 1, #seen do
            local buff = ns.BuffData.CLASSES.PALADIN[i]
            assert.is_true(buff.selfCast, buff.key)
            assert.are.equal(i .. ". " .. buff.key, seen[i]:match("^(.-) |c"))
        end
    end)

    it("names the first rank the client has no name for, or another name, with what it should be (black)", function()
        local names = {}
        for _, buff in ipairs(Pages.BUFF_NAMES) do
            for _, rank in ipairs(buff.ranks) do names[rank] = buff.name end
        end
        _G.C_Spell.GetSpellName = function(id) return names[id] end
        -- Each rank in turn: nothing, the buff key (what the tab showed
        -- before #158), a number, and the name of another buff.
        for _, buff in ipairs(Pages.BUFF_NAMES) do
            for _, rank in ipairs(buff.ranks) do
                local right = names[rank]
                for _, wrong in ipairs({ false, buff.key, 7, "Blessing of Sanctuary" }) do
                    names[rank] = wrong or nil
                    local said = Pages.UnnamedBuff()
                    assert.is_truthy(said, "rank " .. rank .. " named " .. tostring(wrong) .. " passes")
                    assert.is_truthy(said:find("spell " .. rank .. " ", 1, true), said)
                    assert.is_truthy(said:find('not "' .. buff.name .. '"', 1, true), said)
                    if type(wrong) == "string" then
                        assert.is_truthy(said:find('"' .. wrong .. '"', 1, true), said)
                    else
                        assert.is_truthy(said:find("nothing", 1, true), said)
                    end
                end
                names[rank] = right
            end
        end
        assert.is_nil(Pages.UnnamedBuff())
    end)

    it("says a buff is unnamed when the client has no GetSpellName, or it errors, and changes nothing (black)", function()
        _G.C_Spell.GetSpellName = nil
        assert.is_truthy(Pages.UnnamedBuff():find("spell 20217 nothing", 1, true))
        assert.is_nil(_G.C_Spell.GetSpellName)
        local erroring = function() error("no spell data") end
        _G.C_Spell.GetSpellName = erroring
        assert.is_truthy(Pages.UnnamedBuff():find("spell 20217 nothing", 1, true))
        assert.are.equal(erroring, _G.C_Spell.GetSpellName)
    end)

    it("no longer answers for the client: showing a tab leaves its GetSpellName alone (white)", function()
        assert.is_nil(Pages.NameBuffs)
        assert.is_nil(Pages.WithBuffNames)
        Pages.ShowTab("buff-back")
        assert.are.equal(original, _G.C_Spell.GetSpellName)
    end)

    -- The workflow's staging commands, run as it runs them (comments dropped)
    -- in a scratch folder, and its shoot line read without comments: the
    -- lower script is written next to the tab scripts, each of which is
    -- left as it was, and the lower shot is taken in shoot_all, so at
    -- both sizes.
    it("stages the lower script beside the tab scripts, leaving each of theirs as it was, and shoots it at both sizes (white and black, #254)", function()
        local workflow = wow.readFile(".github/workflows/ui-sim.yml"):gsub("\n%s*#[^\n]*", "")
        local tabs = workflow:match("\n%s*OPTIONS_TABS: ([^\n]-)%s*\n")
        local loop = workflow:match("\n(%s*for tab in %$OPTIONS_TABS; do\n.-\n%s*done)\n")
        local lower = workflow:match("\n(%s*{ cat uitests/pages%.lua; printf '\\nFriendlyForeverUIPages%.ShowTabLower%(\"buff%-back\"%)\\n'; } \\\n%s*> \"%$states/tab%-buff%-back%-lower%.lua\")\n")
        assert.is_truthy(tabs and loop and lower, "the tab list, the tab loop or the lower script's command is missing")
        local dir = os.tmpname()
        os.remove(dir)
        assert.is_true(os.execute("mkdir -p '" .. dir .. "'") == 0)
        local f = assert(io.open(dir .. "/run.sh", "w"))
        f:write("set -eu\nstates='" .. dir .. "/out'\nmkdir -p \"$states\"\nOPTIONS_TABS='" .. tabs .. "'\n"
            .. loop .. "\n" .. lower .. "\n")
        f:close()
        local ok = os.execute("bash '" .. dir .. "/run.sh'")
        local pages = wow.readFile("uitests/pages.lua")
        local listed = io.popen("ls '" .. dir .. "/out'"):read("*a")
        local function written(name)
            local file = io.open(dir .. "/out/" .. name)
            local text = file and file:read("*a")
            if file then file:close() end
            return text
        end
        local lowerText = written("tab-buff-back-lower.lua")
        local backText = written("tab-buff-back.lua")
        os.execute("rm -rf '" .. dir .. "'")
        assert.are.equal(0, ok)
        assert.are.equal(#Pages.TABS + 1, select(2, listed:gsub("[^\n]+", "")), "files written: " .. listed)
        assert.are.equal(pages .. '\nFriendlyForeverUIPages.ShowTabLower("buff-back")\n', lowerText)
        assert.are.equal(pages .. '\nFriendlyForeverUIPages.ShowTab("buff-back")\n', backText)
        -- Inside shoot_all, so both passes (and their suffixes) take it.
        local all = workflow:match("shoot_all%(%) {\n(.-)\n%s*}\n%s*for size in")
        assert.is_truthy(all and all:find('\n%s*shoot options%-buff%-back%-lower %-%-exec%-lua "@/shot%-lua/tab%-buff%-back%-lower%.lua"\n'))
    end)

    it("answers no panel to scroll with a message, not a Lua error (black, #254)", function()
        _G.FriendlyForeverOptionsPanel = nil
        local ok, undo, why = pcall(Pages.ScrollToRow, Pages.LOWER_ROW)
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

    -- The simulated client has no child lists, layout or ranges: this gives
    -- the options panel a scroll frame holding the real group versions check
    -- box, 700 px down a 2000 px child, in a 600 px view.
    local function Layout()
        local scroll = ns.Options.widgets.scroll
        local content = ns.Options.widgets.content
        local row = ns.Options.widgets.groupVersions
        scroll.scrollRange = 1500
        scroll.GetHeight = function() return 600 end
        scroll.GetScrollChild = function() return content end
        content.GetHeight = function() return 2000 end
        content.GetTop = function() return 1000 end
        content.GetChildren = function() return row end
        content.GetRegions = function() return end
        row.GetTop = function() return 1000 - 700 end
        _G.FriendlyForeverOptionsPanel.GetChildren = function() return scroll end
        return scroll, row
    end

    it("scrolls the Buff Back tab to its group versions row for the lower shot, and the undo puts the scroll back (white, #254)", function()
        ns.Options.OpenTab("buffBack")
        local scroll = Layout()
        scroll:SetVerticalScroll(40)
        local undo = Pages.ScrollToRow(Pages.LOWER_ROW)
        assert.are.equal(700 - 12, scroll:GetVerticalScroll())
        undo()
        assert.are.equal(40, scroll:GetVerticalScroll())
    end)

    it("doesn't scroll again on the next frame once the scroll was put back (white, #254)", function()
        ns.Options.OpenTab("buffBack")
        local scroll = Layout()
        local later = {}
        _G.C_Timer = { After = function(_, fn) later[#later + 1] = fn end }
        scroll:SetVerticalScroll(40)
        local undo = Pages.ScrollToRow(Pages.LOWER_ROW)
        undo()
        for _, fn in ipairs(later) do fn() end
        assert.are.equal(#later > 0, true, "the frame-later scroll was queued")
        assert.are.equal(40, scroll:GetVerticalScroll())
    end)

    it("keeps the offset inside the child less the view, and inside the range (black, #254)", function()
        ns.Options.OpenTab("buffBack")
        local scroll, row = Layout()
        row.GetTop = function() return 1000 - 1900 end
        Pages.ScrollToRow(Pages.LOWER_ROW)
        assert.are.equal(1400, scroll:GetVerticalScroll(), "the child's 2000 less the view's 600")
        scroll.scrollRange = 900
        Pages.ScrollToRow(Pages.LOWER_ROW)
        assert.are.equal(900, scroll:GetVerticalScroll(), "the range, where it is smaller")
    end)

    it("names no row it can't find, with a message and no Lua error (black, #254)", function()
        ns.Options.OpenTab("buffBack")
        Layout()
        local ok, undo, why = pcall(Pages.ScrollToRow, "No such row")
        assert.is_true(ok)
        assert.is_nil(undo)
        assert.is_truthy(why)
        assert.are.equal(why, printed[#printed])
    end)

    it("shows the lower Buff Back tab from the tab's own script, with the buffs named (white, #254)", function()
        ns.Options.OpenTab("buffBack")
        local scroll = Layout()
        local undo = Pages.ShowTabLower("buff-back")
        assert.is_function(undo)
        assert.are.equal(700 - 12, scroll:GetVerticalScroll())
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

-- #160: the simulator's Forever profile prints the game's "Interface action
-- failed because of an AddOn" line in the shots that open the main panel.
-- pages.lua says who was blamed: the two events the client fires, and the
-- callers of Blizzard's own function for the line, which fires neither.
describe("the UI simulator's blocked-action report (#160)", function()
    local Pages, printed, shown

    before_each(function()
        wow.boot()
        printed, shown = {}, {}
        _G.A_Print = function(text) printed[#printed + 1] = text end
        _G.DisplayInterfaceActionBlockedMessage = function(...) shown[#shown + 1] = select("#", ...) end
        _G.debugstack = function(start, top, bottom)
            return ("first caller %d %d %d\nsecond caller\r\n\n"):format(start, top, bottom)
        end
    end)

    after_each(function()
        _G.FriendlyForeverUIPages = nil
        _G.A_Print = nil
        _G.DisplayInterfaceActionBlockedMessage = nil
        _G.debugstack = nil
    end)

    local function load()
        dofile("uitests/pages.lua")
        Pages = _G.FriendlyForeverUIPages
    end

    it("records each blocked or forbidden action in order, counts repeats and prints a new one once (white)", function()
        load()
        wow.fire("ADDON_ACTION_BLOCKED", "FriendlyForever", "Button:Show()")
        wow.fire("ADDON_ACTION_FORBIDDEN", "OtherAddon", "CastSpellByName()")
        wow.fire("ADDON_ACTION_BLOCKED", "FriendlyForever", "Button:Show()")
        assert.are.same({ "ADDON_ACTION_BLOCKED FriendlyForever Button:Show()",
            "ADDON_ACTION_FORBIDDEN OtherAddon CastSpellByName()" }, Pages.blocked.order)
        assert.are.equal(2, Pages.blocked.count["ADDON_ACTION_BLOCKED FriendlyForever Button:Show()"])
        assert.are.equal(1, Pages.blocked.count["ADDON_ACTION_FORBIDDEN OtherAddon CastSpellByName()"])
        assert.are.same({ "FACT sim blocked action, as it happens: ADDON_ACTION_BLOCKED FriendlyForever Button:Show()",
            "FACT sim blocked action, as it happens: ADDON_ACTION_FORBIDDEN OtherAddon CastSpellByName()" }, printed)
    end)

    it("records nothing while nothing is blocked (black)", function()
        load()
        wow.fire("PLAYER_REGEN_DISABLED")
        assert.are.same({}, Pages.blocked.order)
        assert.are.same({}, Pages.blockedMessage)
        assert.are.same({}, printed)
    end)

    it("prints who called the client's chat line, from the caller up, and still shows the line (white)", function()
        local original = _G.DisplayInterfaceActionBlockedMessage
        load()
        assert.are_not.equal(original, _G.DisplayInterfaceActionBlockedMessage)
        _G.DisplayInterfaceActionBlockedMessage("one", "two")
        assert.are.same({ 2 }, shown, "the client's function ran once, with what it was given")
        assert.are.same({ "first caller 2 12 0", "second caller" }, Pages.blockedMessage)
        assert.are.same({ "FACT sim the blocked-action chat line, called from: first caller 2 12 0",
            "FACT sim the blocked-action chat line, called from: second caller" }, printed)
    end)

    it("puts the client's function back before running it, so only the first call is reported (white)", function()
        local original = _G.DisplayInterfaceActionBlockedMessage
        load()
        _G.DisplayInterfaceActionBlockedMessage()
        assert.are.equal(original, _G.DisplayInterfaceActionBlockedMessage)
        _G.DisplayInterfaceActionBlockedMessage()
        assert.are.same({ 0, 0 }, shown)
        assert.are.equal(2, #Pages.blockedMessage)
    end)

    it("keeps a replacement the client's function makes of itself, as Blizzard's does (white)", function()
        local quiet = function() end
        _G.DisplayInterfaceActionBlockedMessage = function()
            shown[#shown + 1] = 0
            _G.DisplayInterfaceActionBlockedMessage = quiet
        end
        load()
        _G.DisplayInterfaceActionBlockedMessage()
        assert.are.equal(quiet, _G.DisplayInterfaceActionBlockedMessage)
        assert.are.same({ 0 }, shown)
    end)

    it("says so when the client gives no call stack, and still shows the line (black)", function()
        for _, broken in ipairs({ false, function() error("no stack") end, function() return "" end, function() return 7 end }) do
            printed, shown = {}, {}
            _G.DisplayInterfaceActionBlockedMessage = function() shown[#shown + 1] = 0 end
            _G.debugstack = broken or nil
            load()
            _G.DisplayInterfaceActionBlockedMessage()
            assert.are.same({ "(the client gave no call stack)" }, Pages.blockedMessage)
            assert.are.same({ 0 }, shown)
        end
    end)

    it("loads where the client has no such function, and reports no caller (black)", function()
        _G.DisplayInterfaceActionBlockedMessage = nil
        load()
        assert.is_nil(_G.DisplayInterfaceActionBlockedMessage)
        assert.are.same({}, Pages.blockedMessage)
    end)
end)
