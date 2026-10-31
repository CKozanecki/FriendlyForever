-- Spec: #148, #173
-- The stand-in test runner (scripts/ui-sim-harness.lua) that lets the UI
-- scenarios run at other screen sizes, and the script the workflow joins it
-- into. The scenarios themselves run only in the simulator.

local wow = require("spec.support.wow")

-- Loads the harness into a fresh environment with A_Print recording.
local function loadHarness()
    local printed = {}
    local env = setmetatable({ A_Print = function(text) printed[#printed + 1] = text end }, { __index = _G })
    local chunk = assert(loadfile("scripts/ui-sim-harness.lua"))
    setfenv(chunk, env)
    chunk()
    return env, printed
end

describe("UI simulator stand-in test runner (#148)", function()
    it("runs each test as it is defined and reports passes and failures with a count (white)", function()
        local env, printed = loadHarness()
        env.test("fine", function() env.assertTrue(true) end)
        env.test("broken", function() env.assertEquals(1, 2) end)
        env.FriendlyForeverHarnessFinish()
        assert.are.same({ "✓ fine", "✗ broken: expected 1, got 2", "2 tests, 1 passed, 1 failed" }, printed)
    end)

    it("fails assertTrue, assertNotNil and assertType on the wrong value, and passes the right one (black)", function()
        local env = loadHarness()
        assert.is_false(pcall(env.assertTrue, false))
        assert.is_false(pcall(env.assertTrue, nil))
        assert.is_false(pcall(env.assertNotNil, nil))
        assert.is_false(pcall(env.assertType, "table", "text"))
        assert.is_false(pcall(env.assertEquals, "a", "b"))
        assert.is_true(pcall(env.assertTrue, true))
        assert.is_true(pcall(env.assertNotNil, false))
        assert.is_true(pcall(env.assertType, "table", {}))
        assert.is_true(pcall(env.assertEquals, "a", "a"))
    end)

    it("keeps a failing message, which assertTrue of the real runner drops (white)", function()
        local env, printed = loadHarness()
        env.test("says why", function() env.assertTrue(false, "the reason") end)
        assert.are.same({ "✗ says why: the reason" }, printed)
    end)

    it("never throws, whatever a test does (black)", function()
        local env, printed = loadHarness()
        env.test("errors", function() error({ "not a string" }) end)
        env.test("nil error", function() error() end)
        assert.are.equal(2, #printed)
    end)
end)

describe("UI simulator sized-pass script (#148)", function()
    -- The workflow's staging step, run as it runs it (comments dropped), into
    -- a scratch folder; returns the joined script's text.
    local function stage()
        local workflow = wow.readFile(".github/workflows/ui-sim.yml")
        local block = workflow:match("name: Stage the scenarios for the sized layout passes\n%s*run: |\n(.-)\n\n")
        assert.is_truthy(block, "the staging step is missing")
        local dir = os.tmpname()
        os.remove(dir)
        assert.is_true(os.execute("mkdir -p '" .. dir .. "'") == 0)
        local script = dir .. "/run.sh"
        local f = assert(io.open(script, "w"))
        f:write("set -eu\nRUNNER_TEMP='" .. dir .. "'\n" .. block .. "\n")
        f:close()
        local ok = os.execute("bash '" .. script .. "'")
        local file = io.open(dir .. "/layout-lua/layout.lua")
        local text = file and file:read("*a")
        if file then file:close() end
        os.execute("chmod -R u+w '" .. dir .. "'; rm -rf '" .. dir .. "'")
        assert.are.equal(0, ok)
        return assert(text, "no script written")
    end

    it("holds the runner, then each scenario file in the order the simulator loads them, then the count (white)", function()
        local text = stage()
        local last = 0
        for _, part in ipairs({ wow.readFile("scripts/ui-sim-harness.lua"), wow.readFile("uitests/button_states.lua"),
            wow.readFile("uitests/pages.lua"), wow.readFile("uitests/scenarios.lua"), "FriendlyForeverHarnessFinish()" }) do
            local at = text:find(part, last + 1, true)
            assert.is_truthy(at and at > last, "a part is missing or out of order")
            last = at
        end
    end)

    it("compiles as one chunk, with no file's locals leaking into the next (white)", function()
        local text = stage()
        assert.is_truthy(loadstring(text, "layout.lua"))
        -- scenarios.lua's own `report` must not be visible to pages.lua, which
        -- has its own: each file sits in its own function.
        assert.are.equal(3, select(2, text:gsub("local function scenarios%(%.%.%.%)", "")))
    end)
end)

-- #173: a pass stopped at its time limit loses its later lines, so each
-- scenario says it's starting first, and the summary can name the one it
-- hung in.
describe("UI scenarios' start lines (#173)", function()
    -- Loads the scenarios with a runner that logs each test it's given, into
    -- the same list as A_Print.
    local function load()
        local printed = {}
        local env = setmetatable({
            test = function(name) printed[#printed + 1] = "RUN " .. name end,
            A_Print = function(text) printed[#printed + 1] = text end,
        }, { __index = _G })
        local chunk = assert(loadfile("uitests/scenarios.lua"))
        setfenv(chunk, env)
        chunk()
        return printed
    end

    it("prints each scenario's number and name just before the runner gets it, numbered in file order (white)", function()
        local printed = load()
        -- The scenarios, counted from the file's text, not from the code under test.
        local names = {}
        for name in wow.readFile("uitests/scenarios.lua"):gmatch('\ntest%("([^"]+)"') do names[#names + 1] = name end
        assert.is_true(#names >= 20, "expected the file's scenarios, found " .. #names)
        local expected = {}
        for i, name in ipairs(names) do
            expected[#expected + 1] = "START " .. i .. " " .. name
            expected[#expected + 1] = "RUN " .. name
        end
        assert.are.same(expected, printed)
    end)

    it("puts the start line in the sized passes' script, before the stand-in runner's own result (white)", function()
        local printed = {}
        local env = setmetatable({ A_Print = function(text) printed[#printed + 1] = text end }, { __index = _G })
        local harness = assert(loadfile("scripts/ui-sim-harness.lua"))
        setfenv(harness, env)
        harness()
        -- One scenario, run by the stand-in runner the way scenarios.lua's test() hands it on.
        local chunk = assert(loadstring(wow.readFile("uitests/scenarios.lua"):match("^(.-\nlocal function test%(.-\nend\n)")
            .. 'test("one", function() end)\n'))
        setfenv(chunk, env)
        chunk()
        assert.are.same({ "START 1 one", "✓ one" }, printed)
    end)
end)
