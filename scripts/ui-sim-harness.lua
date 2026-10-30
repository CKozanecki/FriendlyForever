-- A stand-in for wow-ui-sim's test runner (issue #148), so the UI scenarios
-- in uitests/ can run at any screen size. The simulator's `run-tests`
-- command has no size option and always uses 1600 x 1200, but its
-- `dump-tree --width W --height H --exec-lua` does. The workflow joins this
-- file, uitests/button_states.lua, pages.lua and scenarios.lua into one
-- script and runs it that way, once per resolution.
--
-- It defines what the scenarios use: test() and the assert* functions. A
-- test runs as soon as it is defined, in file order, as the real runner does.
-- Results go through A_Print: "✓ name" or "✗ name: reason", then a count,
-- which the workflow's digest reads like run-tests' own. Report only: it
-- never throws. Lives in scripts/, not uitests/, which run-tests loads (and
-- which would replace the simulator's own test()).

local report = type(A_Print) == "function" and A_Print or print
local passed, failed = 0, 0

function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        report("✓ " .. tostring(name))
    else
        failed = failed + 1
        report("✗ " .. tostring(name) .. ": " .. tostring(err))
    end
end

function assertTrue(value, message)
    if not value then error(message or "expected true", 0) end
end

function assertEquals(expected, actual, message)
    if expected ~= actual then
        error(message or ("expected " .. tostring(expected) .. ", got " .. tostring(actual)), 0)
    end
end

function assertNotNil(value, message)
    if value == nil then error(message or "expected a value, got nil", 0) end
end

function assertType(expected, value, message)
    if type(value) ~= expected then
        error(message or ("expected a " .. expected .. ", got " .. type(value)), 0)
    end
end

-- Called after the last scenario file.
function FriendlyForeverHarnessFinish()
    report(("%d tests, %d passed, %d failed"):format(passed + failed, passed, failed))
end
