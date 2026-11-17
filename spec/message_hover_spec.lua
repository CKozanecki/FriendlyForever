-- Spec: #441
-- Hovering a message box shows what its placeholders turn into for your
-- character, from the real renderer, and changes nothing.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end

-- Listed here, not read from FlavourText, so a change to the shipped words is
-- noticed: a Human's {greeting} pool is its race lines, then the general ones.
local HUMAN_GREETINGS = { "Well met", "Good day to you", "Light be with you", "Hail", "Greetings",
    "Good to see you", "Hail and well met" }

describe("Hovering a message box (#441)", function()
    local ns, w

    local function boot(opts)
        opts = opts or {}
        opts.race, opts.faction = opts.race or "Human", opts.faction or "Alliance"
        opts.zone, opts.hour = opts.zone or "Elwynn Forest", opts.hour or 14
        ns = wow.boot({ shippedLines = true, class = opts.class, before = function(state)
            for k, v in pairs(opts) do state[k] = v end
        end })
        ns.Flavour.ResetMemory()
        ns.Options.Open()
        w = ns.Options.widgets
    end

    -- Types text into a message box as a player does, then hovers it.
    local function hover(index, text)
        local edit = w.edits[index]
        if text then
            edit:SetText(text)
            wow.run(edit, "OnTextChanged", true)
        end
        wow.run(edit, "OnEnter")
        return table.concat(_G.GameTooltip.lines, "\n"), _G.GameTooltip.lines
    end

    describe("white", function()
        it("a line with {greeting} shows 3 different examples and the whole pool for your race", function()
            boot()
            local text, lines = hover(1, "{greeting}!")
            local examples = {}
            for _, line in ipairs(lines) do
                local said = line:match("^(.+)!$")
                if said then examples[#examples + 1] = said end
            end
            assert.are.equal(3, #examples)
            local pool = {}
            for _, phrase in ipairs(HUMAN_GREETINGS) do pool[phrase] = true end
            local distinct = {}
            for _, said in ipairs(examples) do
                assert.is_true(pool[said], said .. " isn't one of a Human's greetings")
                distinct[said] = true
            end
            assert.are.equal(3, (function() local n = 0 for _ in pairs(distinct) do n = n + 1 end return n end)())
            assert.is_truthy(text:find("{greeting} can be:", 1, true))
            assert.is_truthy((text:gsub("\n", " ")):find(table.concat(HUMAN_GREETINGS, " / "), 1, true))
            assert.is_true(_G.GameTooltip:IsShown())
        end)

        it("a Horde orc's pool has the orc and Horde voices, not the human ones", function()
            boot({ race = "Orc", faction = "Horde" })
            local text = hover(1, "{greeting}, {name}!")
            assert.is_truthy(text:find("Lok'tar", 1, true))
            assert.is_nil(text:find("Light be with you", 1, true))
        end)

        it("fills {name} and {buff} with sample values and says what {zone}, {timeofday} and {myclass} read now", function()
            boot({ class = "MAGE" })
            local text = hover(1, "{thanks}, {name}, for the {buff}! In {zone} this {timeofday}, from a {myclass}.")
            assert.is_truthy(text:find("for the Power Word: Fortitude!", 1, true))
            assert.is_truthy(text:find("{zone} now reads: Elwynn Forest", 1, true))
            assert.is_truthy(text:find("{timeofday} now reads: afternoon", 1, true))
            assert.is_truthy(text:find("{myclass} now reads: mage", 1, true))
            assert.is_truthy(text:find("{thanks} can be:", 1, true))
            assert.is_nil(text:find("{greeting} can be:", 1, true))
        end)

        it("lists a placeholder's pool once, however many times the line uses it", function()
            boot()
            local text = hover(1, "{greeting}! {greeting}!")
            local _, count = text:gsub("{greeting} can be:", "")
            assert.are.equal(1, count)
        end)

        it("is the real renderer: every {greeting} example is in the pool it lists", function()
            boot()
            local _, lines = hover(1, "{greeting}, {name}! {blessing}")
            local pool, seen = ns.Flavour.Pool("greeting", ns.Flavour.Context()), 0
            for _, said in ipairs(lines) do
                local greeting = said:match("^(.-), Nikki Shifts! ")
                if greeting then
                    seen = seen + 1
                    local found = false
                    for _, phrase in ipairs(pool) do found = found or phrase == greeting end
                    assert.is_true(found, greeting)
                end
            end
            assert.are.equal(3, seen)
        end)
    end)

    describe("black", function()
        it("an empty line, and one of only spaces, say it is skipped", function()
            boot()
            assert.is_truthy((hover(1, "")):find("Empty: this line is skipped.", 1, true))
            assert.is_truthy((hover(2, "   ")):find("Empty: this line is skipped.", 1, true))
        end)

        it("a line with no placeholders shows itself once, with no pools", function()
            boot()
            local text, lines = hover(1, "Hello there!")
            assert.is_truthy(text:find("What it says for you:", 1, true))
            local n = 0
            for _, line in ipairs(lines) do if line == "Hello there!" then n = n + 1 end end
            assert.are.equal(1, n)
            assert.is_nil(text:find("can be:", 1, true))
        end)

        it("an unknown placeholder is shown as typed, in any case", function()
            boot()
            local text = hover(1, "Hi {Foo}, {GREETING}!")
            assert.is_truthy(text:find("Hi {Foo}, ", 1, true))
            assert.is_truthy(text:find("{greeting} can be:", 1, true))
        end)

        it("unreadable race, faction and zone fall back to the general words without an error", function()
            boot()
            _G.UnitRace = function() error("restricted") end
            _G.GetRealZoneText = function() return wow.secret("Elwynn") end
            _G.GetZoneText = function() return nil end
            local text = hover(1, "{greeting} in {zone}")
            assert.is_truthy(text:find("{zone} now reads: these lands", 1, true))
            assert.is_truthy(text:find("Good to see you", 1, true))
            assert.are.equal(0, #wow.errors)
        end)

        it("a box that errors while reading never breaks the options panel", function()
            boot()
            local edit = w.edits[1]
            local get = edit.GetText
            edit.GetText = function() error("boom") end
            assert.has_no.errors(function() wow.run(edit, "OnEnter") end)
            assert.is_truthy(table.concat(_G.GameTooltip.lines, "\n"):find("No preview for this line.", 1, true))
            edit.GetText = get
        end)

        it("leaving the box hides the tooltip", function()
            boot()
            hover(1, "{greeting}")
            wow.run(w.edits[1], "OnLeave")
            assert.is_false(_G.GameTooltip:IsShown())
        end)

        it("a long pool is capped, saying how many more", function()
            boot()
            local many = {}
            for i = 1, 40 do many[i] = "Phrase" .. i end
            local text = ns.FlavourText.greeting
            local saved = text.general
            text.general = many
            local out = hover(1, "{greeting}")
            text.general = saved
            -- 4 human lines, then the 40 general: 24 are listed, 20 are counted.
            assert.is_truthy(out:find("Phrase20", 1, true))
            assert.is_nil(out:find("Phrase21", 1, true))
            assert.is_truthy(out:find("... and 20 more", 1, true))
            -- ...in lines that fit the screen, however long the pool.
            for _, line in ipairs(_G.GameTooltip.lines) do
                assert.is_true(#line <= ns.Options.PREVIEW_WIDTH, line)
            end
        end)
    end)

    describe("red", function()
        it("a storm of hovers and edits never changes the saved lines, the shuffle bag or what is said next", function()
            boot()
            local rolls = 0
            local function counted() rolls = rolls + 1 return 1 end
            -- Settle the real state first: one real pick, so the bag and memory are in use.
            ns.Flavour.random, ns.Messages.random = function() return 1 end, function() return 1 end
            local ctx = ns.Flavour.Context()
            local first = ns.Flavour.Pick("greeting", ctx)
            ns.Flavour.Pick("greeting", ctx)
            ns.Flavour.Pick("greeting", ctx)
            local bagged = ns.Messages.Pick("guildLogin", ns.db.guildLogin.messages)
            local saved = deepCopy(ns.db)
            ns.Flavour.random, ns.Messages.random = counted, counted

            local lines = { "{greeting}!", "{thanks}, {name}", "", "  ", "{blessing} {cheer}", "{nope}", "{zone}{zone}",
                "{GREETING}, {Name}!", "{{greeting}}", "{greeting" }
            local printed = #wow.printed
            random.seed(1234)
            for _ = 1, 400 do
                local i = random.random(1, #w.edits)
                local box = w.edits[i]
                -- hover without typing, as a player moving over the boxes
                wow.run(box, "OnEnter")
                wow.run(box, "OnLeave")
                -- hover with the box holding a line being typed (not a saved edit)
                local typed = lines[random.random(1, #lines)]
                local kept = box:GetText()
                box:SetText(typed)
                wow.run(box, "OnEnter")
                box:SetText(kept)
            end
            assert.are.equal(0, rolls, "a hover drew from the real random generators")
            assert.are.same(saved, ns.db)
            assert.are.equal(printed, #wow.printed)
            assert.are.equal(0, #wow.errors)
            assert.is_truthy(first and bagged)
            -- The memory of recent fragments is as the real picks left it: with the
            -- roll fixed, the next pick is the same as in a run with no hovers.
            ns.Flavour.random = function() return 1 end
            local after = ns.Flavour.Pick("greeting", ctx)
            ns.Flavour.ResetMemory()
            for _ = 1, 3 do ns.Flavour.Pick("greeting", ctx) end
            assert.are.equal(ns.Flavour.Pick("greeting", ctx), after)
            assert.are_not.equal(first, after)
        end)

        it("never draws from math.random, so the game's own random sequence is not moved", function()
            boot()
            local calls, real = 0, math.random
            math.random = function(...) calls = calls + 1 return real(...) end
            local ok, err = pcall(function()
                for i = 1, #w.edits do hover(i, "{greeting}, {name}! {blessing} {cheer} {thanks}") end
            end)
            math.random = real
            assert.is_true(ok, tostring(err))
            assert.are.equal(0, calls)
        end)

        it("hovering a damaged box text (secret or wrong type) is harmless", function()
            boot()
            for _, bad in ipairs({ wow.secret("{greeting}"), 5, true }) do
                local edit = w.edits[1]
                local get = edit.GetText
                edit.GetText = function() return bad end
                assert.has_no.errors(function() wow.run(edit, "OnEnter") end)
                edit.GetText = get
            end
            assert.are.equal(0, #wow.errors)
        end)
    end)
end)
