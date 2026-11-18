-- Spec: #453
-- The debug log folds a run of identical press and result lines (#453): a
-- wheel notch presses the button many times, and each press logged a line,
-- pushing decisions out of the log. The first line of a run is logged, the
-- repeats counted, and the count logged when the run ends, as #268 folds
-- its repeats. Only the log changes: presses and casts are as before.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1 = 9885, 1126
local NOT_READY = "Spell is not ready yet."

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("The debug log folds repeated press and result lines (#453)", function()
    local ns

    -- A druid in buff mode, in a party with Ann and Cid, who lack Mark of the
    -- Wild. opts.debug false: debug off.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
        end })
        slash("buffmode on")
        wow.setGroup("party", { "Ann-Vale", "Cid-Rock" })
        wow.fire("GROUP_ROSTER_UPDATE")
        ns.db.debug = opts.debug ~= false
        ns.db.diagLog = {}
    end

    -- Lines holding fragment; firsts: only those that aren't count lines.
    local function count(fragment, firsts)
        local n = 0
        for _, line in ipairs(ns.db.diagLog) do
            if line:find(fragment, 1, true) and not (firsts and line:find("(repeated ", 1, true)) then n = n + 1 end
        end
        return n
    end

    -- Count lines for the button's presses: "pressed: ... (repeated n more times)".
    local function pressCount(n)
        local tail = string.format("(repeated %d more time%s)", n, n == 1 and "" or "s")
        local found = 0
        for _, line in ipairs(ns.db.diagLog) do
            if line:find("buffBack: pressed: ", 1, true) and line:find(tail, 1, true) then found = found + 1 end
        end
        return found
    end

    -- Every cast at Ann is refused as the game does on a cooldown.
    local function refuseAnn() wow.state.castFailures["Ann-Vale"] = NOT_READY end

    local function presses(n)
        for _ = 1, n do wow.pressKey("MOUSEWHEELUP") end
    end

    describe("a run of presses (white)", function()
        before_each(function() boot() refuseAnn() end)

        it("twelve identical presses log one pressed line, then one count line with 11", function()
            presses(12)
            assert.are.equal(12, #wow.casts, "every press still casts")
            assert.are.equal(1, count("buffBack: pressed: "))
            assert.are.equal(0, count("repeated"), "the run hasn't ended yet")
            wow.advance(ns.Diag.FOLD_SECONDS + 1)
            assert.are.equal(1, count("buffBack: pressed: ", true))
            assert.are.equal(1, pressCount(11), "one count line, naming the line it counts")
            assert.are.equal(2, count("repeated"), "the press's and the refusal's")
        end)

        it("the refusals fold the same way, and the button still shows each one", function()
            presses(5)
            assert.matches(NOT_READY, ns.BuffButton.Frame().result:GetText(), 1, true)
            assert.are.equal(1, count("Couldn't buff Ann Vale: " .. NOT_READY))
            wow.advance(ns.Diag.FOLD_SECONDS + 1)
            assert.are.equal(1, count("Couldn't buff Ann Vale: " .. NOT_READY .. " (repeated 4 more times)"))
        end)

        it("a press within the window of the last repeat keeps the run going", function()
            for _ = 1, 6 do
                presses(1)
                wow.advance(ns.Diag.FOLD_SECONDS - 0.5)
            end
            assert.are.equal(1, count("pressed: ", true), "each press came within the window of the one before")
            assert.are.equal(0, count("repeated"))
            wow.advance(ns.Diag.FOLD_SECONDS + 1)
            assert.are.equal(1, pressCount(5))
        end)

        it("a different press ends the run, and its count comes before the new line", function()
            presses(3)
            -- Ann wears it now: the next press is Cid's.
            wow.state.castFailures["Ann-Vale"] = nil
            wow.wearBuff("party1", MOTW, { source = "player" })
            presses(1)
            local countAt, cidAt
            for i, line in ipairs(ns.db.diagLog) do
                if line:find("pressed: ", 1, true) and line:find("(repeated 2 more times)", 1, true) then countAt = i end
                if line:find("pressed: ", 1, true) and line:find("Cid Rock", 1, true) then cidAt = i end
            end
            assert.is_truthy(countAt, "Ann's run was counted")
            assert.is_truthy(cidAt, "Cid's press is logged")
            assert.is_true(countAt < cidAt)
        end)

        it("after the window, the same press starts a new run and is logged again", function()
            presses(2)
            wow.advance(ns.Diag.FOLD_SECONDS + 1)
            presses(1)
            assert.are.equal(2, count("buffBack: pressed: ", true))
            assert.are.equal(1, pressCount(1))
        end)

        it("a single press gets no count line", function()
            presses(1)
            wow.advance(ns.Diag.FOLD_SECONDS * 3)
            assert.are.equal(1, count("pressed: "))
            assert.are.equal(0, count("repeated"))
        end)
    end)

    describe("debug off, and safety (black)", function()
        it("with debug off nothing is formatted or logged, and turning it on starts afresh", function()
            boot({ debug = false })
            refuseAnn()
            local formatted = 0
            local safe = ns.Diag.Safe
            ns.Diag.Safe = function(...)
                formatted = formatted + 1
                return safe(...)
            end
            presses(4)
            ns.Diag.Safe = safe
            assert.are.equal(0, formatted, "nothing was formatted")
            assert.are.equal(0, #ns.db.diagLog)
            assert.are.equal(4, #wow.casts)
            slash("debug")
            presses(1)
            wow.advance(ns.Diag.FOLD_SECONDS + 1)
            assert.are.equal(1, count("pressed: "))
            assert.are.equal(0, count("repeated"), "presses with debug off belong to no run")
        end)

        it("a run's count isn't logged once debug is off", function()
            boot()
            refuseAnn()
            presses(3)
            ns.db.debug = false
            wow.advance(ns.Diag.FOLD_SECONDS + 1)
            assert.are.equal(0, count("repeated"))
        end)
    end)

    describe("a storm (red)", function()
        -- One storm of presses, refusals, fights and aura changes. unfolded:
        -- the same storm with folding switched off (every line logged as
        -- before #453). The casts, the button's results and the debug log
        -- lines it gives.
        local function storm(seed, unfolded)
            random.seed(seed)
            boot()
            if unfolded then
                ns.Diag.LogFolded = function(_, ...) return ns.Diag.Log(...) end
            end
            local results = {}
            local errors = ns.Diag.Counters().luaErrors or 0
            for _ = 1, 300 do
                local roll = random.random(1, 10)
                if roll <= 5 then
                    -- A wheel notch: a burst of presses.
                    if not wow.state.inCombat then presses(random.random(1, 6)) end
                elseif roll == 6 then
                    if wow.state.castFailures["Ann-Vale"] then wow.state.castFailures["Ann-Vale"] = nil
                    else refuseAnn() end
                elseif roll == 7 then
                    if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end
                elseif roll == 8 then
                    wow.state.units.party1.auras = {}
                    wow.state.units.party2.auras = {}
                    wow.fire("UNIT_AURA", "party1", { isFullUpdate = true })
                else
                    wow.advance(random.random(0, 30) / 10)
                end
                results[#results + 1] = ns.BuffButton.Frame().result:GetText() or ""
            end
            if wow.state.inCombat then wow.leaveCombat() end
            wow.advance(ns.Diag.FOLD_SECONDS + 1)
            assert.are.equal(errors, ns.Diag.Counters().luaErrors or 0, "no Lua error")
            local casts = {}
            for i, c in ipairs(wow.casts) do casts[i] = c.id .. " " .. tostring(c.target) end
            local log = {}
            for i, line in ipairs(ns.db.diagLog) do log[i] = line end
            return casts, results, log
        end

        -- Lines of the log holding fragment, each count line counted as the
        -- repeats it stands for.
        local function lines(log, fragment)
            local n = 0
            for _, line in ipairs(log) do
                if line:find(fragment, 1, true) then
                    n = n + (tonumber(line:match("%(repeated (%d+) more times?%)$")) or 1)
                end
            end
            return n
        end

        for _, seed in ipairs({ 453, 17, 2026 }) do
            it("seed " .. seed .. ": the casts and the button's results match an unfolded run, every press and "
                .. "result is accounted for, and the log is shorter", function()
                local casts, results, log = storm(seed, false)
                local plainCasts, plainResults, plainLog = storm(seed, true)
                assert.is_true(#casts > 10, "the storm cast: " .. #casts)
                assert.are.same(plainCasts, casts)
                assert.are.same(plainResults, results)
                assert.are.equal(lines(plainLog, "buffBack: pressed: "), lines(log, "buffBack: pressed: "))
                assert.are.equal(lines(plainLog, "buffBack: Couldn't buff"), lines(log, "buffBack: Couldn't buff"))
                assert.is_true(#log < #plainLog, #log .. " folded lines, " .. #plainLog .. " unfolded")
                assert.is_true(#log <= ns.Diag.MAX_LOG)
            end)
        end
    end)
end)
