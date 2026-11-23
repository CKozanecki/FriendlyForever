-- Spec: #521
-- Passers-by switched on but stopped say why (#521, the owner's report of 20
-- Nov: friendly nameplates were off, and nothing said so): the buff button's
-- line, the debug log once each time the reason changes, a chat line once a
-- session, and a live note on the Favours tab. Nothing here casts.
local wow = require("spec.support.wow")

local MOTW_1, MOTW, THORNS_1 = 1126, 9885, 467
local CVAR = "nameplateShowFriendlyPlayers" -- Forever's, written out here (docs/forever-facts.md)

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Passers-by say why they're stopped (#521)", function()
    local ns, button

    -- A druid with passers-by on, debug on and friendly nameplates as given
    -- ("1" unless opts.plates), in buff mode unless opts.noBuffMode.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
            state.cvars[CVAR] = opts.plates or "1"
            if opts.plates == "nil" then state.cvars[CVAR] = nil end
            if opts.before then opts.before(state) end
        end })
        button = ns.BuffButton.Frame()
        ns.db.debug = true
        ns.db.buffBack.passersBy = opts.off ~= true
        if not opts.noBuffMode then slash("buffmode on") end
        ns.BuffButton.Refresh()
    end

    local function stranger()
        wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR", auras = {} })
    end

    -- The debug log's "passersBy: off:" lines, in order.
    local function offLines()
        local out = {}
        for _, line in ipairs(ns.db.diagLog) do
            local reason = line:match("passersBy: off: (.*)$")
            if reason then out[#out + 1] = reason end
        end
        return out
    end

    local function hints()
        local n = 0
        for _, line in ipairs(wow.printed) do
            if line:find("passers-by need friendly player nameplates", 1, true) then n = n + 1 end
        end
        return n
    end

    local function line() return button.subtitle:GetText() or "" end
    local function has(text, part) return text:find(part, 1, true) ~= nil end

    local function setPlates(value)
        wow.state.cvars[CVAR] = value
        wow.fire("CVAR_UPDATE", CVAR, value)
        ns.BuffButton.Refresh()
    end

    local OFF = "friendly nameplates are off"
    local UNREAD = "friendly nameplates can't be read, so count as off"

    describe("white", function()
        it("nameplates off, passers-by and buff mode on: the button and debug say why, and chat once a session",
            function()
            boot({ plates = "0" })
            assert.is_true(has(line(), "Passers-by need friendly nameplates (/friendly nameplates)"), line())
            wow.advance(30) -- the button re-checks every few seconds
            assert.are.same({ OFF }, offLines(), "once, not once a refresh")
            assert.are.equal(1, hints())
            slash("buffmode off")
            slash("buffmode on")
            wow.advance(10)
            assert.are.equal(1, hints(), "once a session")
            assert.are.same({}, wow.errors)
        end)

        it("names the key that shows them when one is bound, as the game names it", function()
            boot({ plates = "0", before = function(state)
                state.bindings["SHIFT-V"] = "FRIENDNAMEPLATES"
                state.bindingText = { ["SHIFT-V"] = "Shift-V" }
            end })
            assert.is_true(has(line(), "Passers-by need friendly nameplates (Shift-V)"), line())
            local said
            for _, text in ipairs(wow.printed) do
                if text:find("passers-by need", 1, true) then said = text end
            end
            assert.is_truthy(said and said:find("/friendly nameplates shows them, or press Shift-V.", 1, true), said)
        end)

        it("turning nameplates on clears the note, and passers-by work without a reload", function()
            boot({ plates = "0" })
            ns.Options.Open()
            ns.Options.OpenTab(ns.Options.FAVOURS_TAB)
            local note = ns.Options.widgets.passersByNote
            assert.is_true(note:IsShown())
            assert.is_true(has(note:GetText(), "Not working now: friendly nameplates are off."))
            setPlates("1")
            assert.is_false(note:IsShown(), "the note goes as the setting changes")
            assert.is_false(has(line(), "Passers-by"), line())
            stranger()
            ns.PassersBy.Fresh()
            ns.BuffButton.Refresh()
            assert.are.equal("Bob Stone", button.title:GetText(), "a passer-by is offered at once")
            wow.press(button)
            assert.are.equal("Bob-Stone", wow.casts[#wow.casts].target)
            assert.are.same({ OFF }, offLines(), "nothing more logged")
        end)

        it("each other reason logs once when it starts, and again when it starts again", function()
            local cases = {
                { "capital", function() wow.setMap(1454) end, function() wow.setMap(1429) end,
                    "you're in a capital city", "Passers-by: not in a capital city" },
                { "instance", function() wow.enterDungeon(36, "The Deadmines") end, function() wow.leaveDungeon() end,
                    "you're in an instance (dungeon, raid, battleground or arena)" },
                { "resting", function() wow.rest(true) end, function() wow.rest(false) end,
                    "you're in a resting area: they don't keep buff mode on here" },
                { "combat", function() wow.enterCombat() end, function() wow.leaveCombat() end, "you're in a fight" },
                { "place", function() wow.setMap(nil) end, function() wow.setMap(1429) end,
                    "the place can't be read (instance or map)", "Passers-by: the game won't say where you are" },
            }
            for _, case in ipairs(cases) do
                boot()
                local name, start, stop, logged, shown = case[1], case[2], case[3], case[4], case[5]
                start()
                if name == "combat" then
                    assert.are.same({ logged }, offLines(), "logged as the fight starts, before any re-check")
                end
                wow.advance(30)
                assert.are.same({ logged }, offLines(), name)
                if shown then assert.is_true(has(line(), shown), name .. ": " .. line()) end
                stop()
                ns.BuffButton.Refresh()
                wow.advance(10)
                start()
                wow.advance(10)
                assert.are.same({ logged, logged }, offLines(), name .. ": again")
                assert.are.equal(0, hints(), name .. ": nameplates are on")
                assert.are.same({}, wow.errors, name)
            end
        end)

        it("a resting area stops nothing: a passer-by is still offered, and the line says nothing of it", function()
            boot()
            wow.rest(true)
            stranger()
            ns.PassersBy.Fresh()
            ns.BuffButton.Refresh()
            assert.are.equal("Bob Stone", button.title:GetText())
        end)

        it("the reason changing is logged each time: capital, then nameplates off, then out", function()
            boot()
            wow.setMap(1454)
            ns.BuffButton.Refresh()
            setPlates("0")
            wow.setMap(1429)
            ns.BuffButton.Refresh()
            setPlates("1")
            wow.advance(10)
            assert.are.same({ "you're in a capital city", OFF }, offLines())
        end)
    end)

    describe("black", function()
        for _, case in ipairs({
            { "missing", function() wow.state.cvars[CVAR] = nil end },
            { "an error", function() _G.C_CVar.GetCVar = function() error("no") end end },
            { "a secret", function() _G.C_CVar.GetCVar = function() return wow.secret("1") end end },
            { "a number", function() _G.C_CVar.GetCVar = function() return 1 end end },
        }) do
            it("a CVar that can't be read (" .. case[1] .. ") counts as off, and says so", function()
                boot({ noBuffMode = true })
                case[2]()
                slash("buffmode on")
                ns.BuffButton.Refresh()
                wow.advance(10)
                assert.is_true(has(line(), "Passers-by need friendly nameplates"), line())
                assert.are.same({ UNREAD }, offLines())
                assert.are.equal(1, hints())
                ns.Options.Open()
                ns.Options.OpenTab(ns.Options.FAVOURS_TAB)
                local note = ns.Options.widgets.passersByNote
                assert.is_true(note:IsShown())
                assert.is_true(has(note:GetText(), "the game won't say whether friendly nameplates are on"))
                assert.are.same({}, wow.errors)
            end)
        end

        it("says nothing while passers-by or buff mode is off, and nothing casts", function()
            boot({ plates = "0", off = true })
            wow.advance(10)
            assert.is_false(has(line(), "Passers-by"))
            assert.are.same({}, offLines())
            assert.are.equal(0, hints())
            ns.Options.Open()
            ns.Options.OpenTab(ns.Options.FAVOURS_TAB)
            assert.is_false(ns.Options.widgets.passersByNote:IsShown(), "the switch is off")
            boot({ plates = "0", noBuffMode = true })
            wow.advance(10)
            assert.are.same({}, offLines())
            assert.are.equal(0, hints())
            assert.are.equal(0, #wow.casts)
            assert.are.equal(0, #wow.sent, "the chat line is yours alone: nothing is sent")
        end)

        it("a key name the game gives that isn't plain is never shown: the slash command instead", function()
            for _, text in ipairs({ "|cffff0000Shift-V|r|Hx", "Shift-V and then a lot of other words", "" }) do
                boot({ plates = "0", before = function(state)
                    state.bindings["SHIFT-V"] = "FRIENDNAMEPLATES"
                    state.bindingText = { ["SHIFT-V"] = text }
                end })
                local shown = line()
                assert.is_true(has(shown, "(/friendly nameplates)") or has(shown, "(SHIFT-V)"), shown)
                assert.is_false(has(shown, "|"), shown)
            end
        end)
    end)
end)
