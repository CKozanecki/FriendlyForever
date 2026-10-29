-- Spec: #101
-- "Thank them with" and "If that can't reach them": every combination for a
-- named caster, an unnamed one and a failed whisper; the buff-back line;
-- old settings, profiles and settings lines; and a chaos storm.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local STYLES = { "message", "whisper", "emote", "both" }
local FALLBACKS = { "say", "emote", "none" }
local FAIL = "No player named 'Bob-Stone' is currently playing."

local function boot(db)
    local ns = wow.boot({ db = db })
    -- Only the first message: deterministic text in assertions.
    ns.db.buff.messages = { "Thanks for the {buff}, {name}!" }
    return ns
end

-- Press keys a while, so every /say line and /thank waiting goes out.
local function drain()
    for _ = 1, 6 do
        wow.advance(2)
        wow.keyDown()
    end
end

-- What the client sent: /say lines, whispers as "target: text", and
-- emotes as "THANK at <unit>" or "THANK" for a plain one.
local function sent()
    local out = { say = {}, whisper = {}, emote = {} }
    for _, m in ipairs(wow.sent) do
        if m.channel == "SAY" then out.say[#out.say + 1] = m.text end
        if m.channel == "WHISPER" then out.whisper[#out.whisper + 1] = m.target .. ": " .. m.text end
    end
    for _, e in ipairs(wow.emotes) do
        out.emote[#out.emote + 1] = e.token .. (e.target and (" at " .. e.target) or "")
    end
    return out
end

local NAMED_SAY = "Thanks for the Fort, Bob!"
local FRIEND_SAY = "Thanks for the Fort, friend!"
local WHISPER = "Bob-Stone: Thanks for the Fort, Bob!"

describe("Thank them with, and if that can't reach them (#101)", function()
    local ns

    local function named()
        wow.addUnit("target", { name = "Bob", surname = "Stone" })
        wow.gainBuff({ sourceUnit = "target", name = "Fort" })
    end

    local function unnamed()
        wow.gainBuff({ name = "Fort" })
    end

    local function whisperFails()
        named()
        wow.advance(ns.db.buff.delay + 0.01)
        wow.systemMessage(FAIL)
    end

    local function run(style, fallback, case)
        ns = boot()
        ns.db.buff.thankStyle, ns.db.buff.fallback = style, fallback
        case()
        drain()
        assert.are.same({}, wow.errors)
        return sent(), ns.db.ledger.entries[1]
    end

    -- What each choice sends, written out rather than worked out.
    local NAMED = {
        message = { say = { NAMED_SAY }, whisper = {}, emote = {} },
        whisper = { say = {}, whisper = { WHISPER }, emote = {} },
        emote = { say = {}, whisper = {}, emote = { "THANK at target" } },
        both = { say = { NAMED_SAY }, whisper = {}, emote = { "THANK at target" } },
    }
    local NAMED_HOW = {
        message = "in /say", whisper = "by whisper", emote = "with /thank", both = "in /say and with /thank",
    }
    local UNNAMED = {
        say = { say = { FRIEND_SAY }, whisper = {}, emote = {} },
        emote = { say = {}, whisper = {}, emote = { "THANK" } },
        none = { say = {}, whisper = {}, emote = {} },
    }
    local FAILED = {
        say = { say = { FRIEND_SAY }, whisper = { WHISPER }, emote = {} },
        emote = { say = {}, whisper = { WHISPER }, emote = { "THANK at target" } },
        none = { say = {}, whisper = { WHISPER }, emote = {} },
    }

    describe("each combination (white)", function()
        for _, style in ipairs(STYLES) do
            for _, fallback in ipairs(FALLBACKS) do
                local combo = style .. " / " .. fallback

                it("thanks a named caster with the first choice: " .. combo, function()
                    local out, entry = run(style, fallback, named)
                    assert.are.same(NAMED[style], out)
                    assert.are.equal("thanked", entry.result)
                    assert.are.equal(NAMED_HOW[style], entry.note)
                end)

                it("thanks an unnamed caster with the fallback: " .. combo, function()
                    local out, entry = run(style, fallback, unnamed)
                    assert.are.same(UNNAMED[fallback], out)
                    if fallback == "none" then
                        assert.are.equal("not thanked", entry.result)
                        assert.are.equal("couldn't tell who it was; no fallback chosen", entry.note)
                    else
                        assert.are.equal("thanked", entry.result)
                        assert.are.equal(fallback == "say" and "in /say" or "with /thank", entry.note)
                    end
                end)
            end
        end

        for _, fallback in ipairs(FALLBACKS) do
            it("thanks a caster whose whisper fails with the fallback: " .. fallback, function()
                local out, entry = run("whisper", fallback, whisperFails)
                assert.are.same(FAILED[fallback], out)
                if fallback == "none" then
                    assert.are.equal("not thanked", entry.result)
                    assert.are.equal("the whisper didn't reach them; no fallback chosen", entry.note)
                    assert.are.equal(0, ns.Ledger.Summary().thanked, "the whisper's count is taken back")
                    assert.are.equal(0, ns.Ledger.Summary().todayThanked)
                else
                    assert.are.equal("thanked", entry.result)
                    assert.are.equal((fallback == "say" and "in /say" or "with /thank") .. ", as the whisper failed",
                        entry.note)
                    assert.are.equal(1, ns.Ledger.Summary().thanked, "thanked once, not twice")
                    assert.are.equal(1, ns.Ledger.Summary().todayThanked)
                end
            end)
        end

        it("a whisper-failed /thank is plain when they're no longer shown", function()
            local out = run("whisper", "emote", function()
                whisperFails()
                wow.state.units.target = nil
            end)
            assert.are.same({ "THANK" }, out.emote)
        end)

        it("shows how a favour was thanked in /friendly ledger", function()
            run("whisper", "say", named)
            assert.is_truthy(ns.Ledger.Lines(1)[1]:find(" - thanked (by whisper) - ", 1, true))
        end)

        it("names both choices in /friendly status", function()
            ns = boot()
            ns.db.buff.thankStyle, ns.db.buff.fallback = "emote", "none"
            _G.SlashCmdList.FRIENDLYFOREVER("status")
            local found = false
            for _, line in ipairs(wow.printed) do
                if line:find("buff thanks: emote; if that can't reach them: none;", 1, true) then found = true end
            end
            assert.is_true(found)
        end)

        it("calls an unnamed caster the name chosen for the /say fallback", function()
            local out = run("whisper", "say", function()
                ns.db.buff.unknownName = "pal"
                unnamed()
            end)
            assert.are.same({ "Thanks for the Fort, pal!" }, out.say)
        end)

        it("notes in the ledger why a failed whisper's fallback didn't go", function()
            local _, entry = run("whisper", "say", function()
                whisperFails()
                ns.Ignore.Add("Bob-Stone")
            end)
            assert.are.equal("not thanked", entry.result)
            assert.are.equal("the whisper didn't reach them; on your ignore list", entry.note)
        end)
    end)

    describe("the buff-back line (white)", function()
        local MOTW, MOTW_1, INTELLECT = 9885, 1126, 10157
        local button

        local function bootDruid()
            ns = wow.boot({ before = function(state)
                state.class = "DRUID"
                state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
            end })
            ns.db.buff.enabled = false -- only the buff-back line is sent
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "For you, {name}: {buff}!" }
            button = ns.BuffButton.Frame()
        end

        local function returnFavour(style, after)
            bootDruid()
            ns.db.buff.thankStyle = style
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            wow.press(button)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
            if after then after() end
            drain()
            assert.are.same({}, wow.errors)
            return sent()
        end

        local LINE = "For you, Bob: Mark of the Wild!"
        local EXPECTED = {
            message = { say = { LINE }, whisper = {}, emote = {} },
            whisper = { say = {}, whisper = { "Bob-Stone: " .. LINE }, emote = {} },
            emote = { say = {}, whisper = {}, emote = { "THANK at nameplate1" } },
            both = { say = { LINE }, whisper = {}, emote = {} },
        }
        for _, style in ipairs(STYLES) do
            it("follows Thank them with: " .. style, function()
                assert.are.same(EXPECTED[style], returnFavour(style))
            end)
        end

        it("is a plain /thank when the game shows them under no unit", function()
            local out = returnFavour("emote", function() wow.state.units.nameplate1 = nil end)
            assert.are.same({ "THANK" }, out.emote)
        end)

        it("a buff-back whisper held back longer than the /say limit still goes out", function()
            local out = returnFavour("whisper", function()
                wow.state.lockdown = true
                wow.advance(ns.BuffTracker.SAY_MAX_AGE + 30)
                wow.state.lockdown = false
                wow.advance(ns.ChatQueue.RETRY_DELAY)
            end)
            assert.are.same({ "Bob-Stone: " .. LINE }, out.whisper)
        end)

        it("still sends nothing when the line is switched off", function()
            local out = returnFavour("emote", function() ns.db.buffBack.sayLine = false end)
            assert.are.same({ say = {}, whisper = {}, emote = {} }, out)
        end)
    end)

    describe("the options (white)", function()
        local w

        before_each(function()
            ns = boot()
            w = ns.Options.widgets
        end)

        it("shows both choices on the buff tab only, with today's defaults", function()
            wow.run(w.tabs.guildLogin, "OnClick")
            for _, key in ipairs({ "thankStyleLabel", "thankStyle", "fallbackLabel", "fallback", "unknownName" }) do
                assert.is_false(w[key]:IsShown(), key)
            end
            wow.run(w.tabs.buff, "OnClick")
            for _, key in ipairs({ "thankStyleLabel", "thankStyle", "fallbackLabel", "fallback", "unknownName" }) do
                assert.is_true(w[key]:IsShown(), key)
            end
            assert.are.equal("Thank them with:", w.thankStyleLabel:GetText())
            assert.are.equal("If that can't reach them:", w.fallbackLabel:GetText())
            assert.are.equal("a line in /say", w.thankStyle:GetText())
            assert.are.equal("say it in /say as", w.fallback:GetText())
            assert.are.equal("friend", w.unknownName:GetText())
        end)

        it("cycles Thank them with through its four choices", function()
            wow.run(w.tabs.buff, "OnClick")
            local seen = {}
            for _ = 1, 4 do
                wow.run(w.thankStyle, "OnClick")
                seen[#seen + 1] = ns.db.buff.thankStyle .. "=" .. w.thankStyle:GetText()
            end
            assert.are.same({ "whisper=a whisper", "emote=a /thank emote", "both=a line in /say and an emote",
                "message=a line in /say" }, seen)
        end)

        it("cycles the fallback through its three choices, with the name box only for /say", function()
            wow.run(w.tabs.buff, "OnClick")
            wow.run(w.fallback, "OnClick")
            assert.are.equal("emote", ns.db.buff.fallback)
            assert.are.equal("/thank instead", w.fallback:GetText())
            assert.is_false(w.unknownName:IsShown())
            wow.run(w.fallback, "OnClick")
            assert.are.equal("none", ns.db.buff.fallback)
            assert.are.equal("do nothing", w.fallback:GetText())
            assert.is_false(w.unknownName:IsShown())
            wow.run(w.fallback, "OnClick")
            assert.are.equal("say", ns.db.buff.fallback)
            assert.is_true(w.unknownName:IsShown())
        end)

        it("the UI simulator's scenario cycles through the same texts as the options", function()
            local env = setmetatable({ test = function() end, A_Print = function() end }, { __index = _G })
            local chunk = assert(loadfile("uitests/scenarios.lua"))
            setfenv(chunk, env)
            local scenarios = chunk()
            local thankWith, cantReach = {}, {}
            for i, key in ipairs(ns.Options.THANK_STYLES) do thankWith[i] = ns.Options.THANK_STYLE_TEXT[key] end
            for i, key in ipairs(ns.Options.FALLBACKS) do cantReach[i] = ns.Options.FALLBACK_TEXT[key] end
            assert.are.same(thankWith, scenarios.THANK_WITH)
            assert.are.same(cantReach, scenarios.CANT_REACH)
        end)

        it("a damaged choice cycles back to the first", function()
            wow.run(w.tabs.buff, "OnClick")
            ns.db.buff.thankStyle, ns.db.buff.fallback = "dance", "shout"
            wow.run(w.thankStyle, "OnClick")
            wow.run(w.fallback, "OnClick")
            assert.are.equal("message", ns.db.buff.thankStyle)
            assert.are.equal("say", ns.db.buff.fallback)
        end)
    end)

    describe("old settings (black)", function()
        -- Saved before #101: thankStyle, useWhisper and fallbackToSay.
        local CASES = {
            { old = { thankStyle = "message", useWhisper = false, fallbackToSay = true }, style = "message", fb = "say" },
            { old = { thankStyle = "message", useWhisper = true, fallbackToSay = true }, style = "whisper", fb = "say" },
            { old = { thankStyle = "both", useWhisper = true, fallbackToSay = true }, style = "whisper", fb = "say" },
            { old = { thankStyle = "both", useWhisper = false, fallbackToSay = true }, style = "both", fb = "say" },
            { old = { thankStyle = "emote", useWhisper = true, fallbackToSay = true }, style = "emote", fb = "emote" },
            { old = { thankStyle = "emote", useWhisper = false, fallbackToSay = true }, style = "emote", fb = "emote" },
            { old = { thankStyle = "message", useWhisper = false, fallbackToSay = false }, style = "message", fb = "none" },
            { old = { thankStyle = "message", useWhisper = true, fallbackToSay = false }, style = "whisper", fb = "none" },
            { old = { thankStyle = "emote", useWhisper = false, fallbackToSay = false }, style = "emote", fb = "none" },
            { old = { useWhisper = true }, style = "whisper", fb = "say" },
            { old = { fallbackToSay = false }, style = "message", fb = "none" },
            { old = { thankStyle = "emote" }, style = "emote", fb = "emote" },
        }
        local function describeOld(old)
            return string.format("thankStyle %s, useWhisper %s, fallbackToSay %s", tostring(old.thankStyle),
                tostring(old.useWhisper), tostring(old.fallbackToSay))
        end
        local function copy(t)
            local out = {}
            for k, v in pairs(t) do out[k] = v end
            return out
        end

        for _, case in ipairs(CASES) do
            local label = describeOld(case.old) .. " -> " .. case.style .. " / " .. case.fb

            it("loads a saved file: " .. label, function()
                ns = boot({ schemaVersion = 6, buff = copy(case.old) })
                assert.are.equal(case.style, ns.db.buff.thankStyle)
                assert.are.equal(case.fb, ns.db.buff.fallback)
                assert.is_nil(ns.db.buff.useWhisper)
                assert.is_nil(ns.db.buff.fallbackToSay)
            end)

            it("applies a stored profile: " .. label, function()
                ns = boot()
                local snapshot = ns.Profiles.Snapshot(ns.db)
                snapshot.buff = copy(case.old)
                ns.db.profiles = { Old = snapshot }
                assert.are.equal("Old", ns.Profiles.Use("Old"))
                assert.are.equal(case.style, ns.db.buff.thankStyle)
                assert.are.equal(case.fb, ns.db.buff.fallback)
            end)

            it("imports a settings line, with or without its version: " .. label, function()
                for _, version in ipairs({ 6, false }) do
                    ns = boot()
                    local settings = { buff = copy(case.old) }
                    if version then settings.schemaVersion = version end
                    assert.is_true(ns.Profiles.Import(ns.Serialize.Encode({ v = 1, settings = settings })))
                    assert.are.equal(case.style, ns.db.buff.thankStyle, tostring(version))
                    assert.are.equal(case.fb, ns.db.buff.fallback, tostring(version))
                end
            end)
        end

        it("loads 0.2.2's blank name (don't thank) as doing nothing", function()
            ns = boot({ schemaVersion = 2, buff = { unknownName = "", fallbackToSay = true } })
            assert.are.equal("none", ns.db.buff.fallback)
        end)

        it("leaves the new choices alone once they're set", function()
            ns = boot({ schemaVersion = 6, buff = { thankStyle = "both", fallback = "emote" } })
            assert.are.equal("both", ns.db.buff.thankStyle)
            assert.are.equal("emote", ns.db.buff.fallback)
        end)

        it("carries the new choices in settings lines and profiles", function()
            ns = boot()
            ns.db.buff.thankStyle, ns.db.buff.fallback = "whisper", "none"
            local text = assert(ns.Profiles.Export())
            local data = ns.Serialize.Decode(text)
            assert.are.equal("whisper", data.settings.buff.thankStyle)
            assert.are.equal("none", data.settings.buff.fallback)
            assert.is_nil(data.settings.buff.useWhisper)
            ns = boot()
            assert.is_true(ns.Profiles.Import(text))
            assert.are.equal("whisper", ns.db.buff.thankStyle)
            assert.are.equal("none", ns.db.buff.fallback)
            assert.are.equal("Two", ns.Profiles.New("Two"))
            ns.db.buff.fallback = "emote"
            assert.are.equal("Default", ns.Profiles.Use("Default"))
            assert.are.equal("none", ns.db.buff.fallback)
            assert.are.equal("Two", ns.Profiles.Use("Two"))
            assert.are.equal("emote", ns.db.buff.fallback)
        end)

        local DAMAGED = { "dance", "", "WHISPER", " say", 7, true, {}, false }
        for _, bad in ipairs(DAMAGED) do
            it("repairs a damaged choice to the default: " .. tostring(bad), function()
                ns = boot({ buff = { thankStyle = bad, fallback = bad, useWhisper = bad, fallbackToSay = bad } })
                assert.are.equal("message", ns.db.buff.thankStyle)
                assert.are.equal("say", ns.db.buff.fallback)
                ns = boot()
                local text = ns.Serialize.Encode({ v = 1, settings = { buff = { thankStyle = bad, fallback = bad } } })
                assert.is_true(ns.Profiles.Import(text))
                assert.are.equal("message", ns.db.buff.thankStyle)
                assert.are.equal("say", ns.db.buff.fallback)
            end)
        end

        it("sends nothing for a choice damaged after loading, without an error", function()
            ns = boot()
            ns.db.buff.thankStyle, ns.db.buff.fallback = "dance", "shout"
            named()
            unnamed()
            drain()
            assert.are.same({ say = {}, whisper = {}, emote = {} }, sent())
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("a storm of buffs, failed whispers, unnamed casters and option changes (red)", function()
        local NAMES = { "Bob", "Gus", "Hal", "Ivy" }
        local TOKENS = { "target", "mouseover", "nameplate1", "nameplate2" }

        -- noSay: the options only ever change between choices without /say.
        local function storm(seed, noSay)
            random.seed(seed)
            ns = boot()
            ns.db.buffBack.sayLine = true
            local styles = noSay and { "whisper", "emote" } or STYLES
            local fallbacks = noSay and { "emote", "none" } or FALLBACKS
            local function pick(list) return list[random.random(#list)] end
            ns.db.buff.thankStyle, ns.db.buff.fallback = pick(styles), pick(fallbacks)
            local actions = {
                function()
                    local token, name = pick(TOKENS), pick(NAMES)
                    wow.addUnit(token, { name = name, surname = "Stone" })
                    wow.gainBuff({ sourceUnit = token, name = pick({ "Fort", "Int", "Mark" }) })
                end,
                function() wow.gainBuff({ name = pick({ "Fort", "Int" }) }) end,
                function() wow.systemMessage("No player named '" .. pick(NAMES) .. "-Stone' is currently playing.") end,
                function() ns.db.buff.thankStyle = pick(styles) end,
                function() ns.db.buff.fallback = pick(fallbacks) end,
                function() wow.state.units[pick(TOKENS)] = nil end,
                function() wow.advance(random.random() * 6) end,
                function() wow.keyDown() end,
                function() wow.state.lockdown = not wow.state.lockdown end,
            }
            for _ = 1, 400 do
                actions[random.random(#actions)]()
            end
            wow.state.lockdown = false
            drain()
            assert.are.same({}, wow.errors, "seed " .. seed)
        end

        for seed = 1, 6 do
            it("never sends a /say line when neither choice has /say, and never errors: seed " .. seed, function()
                storm(seed * 7919, true)
                -- Counted from what the client sent and held back, not from the addon.
                local said = 0
                for _, m in ipairs(wow.sent) do if m.channel == "SAY" then said = said + 1 end end
                for _, m in ipairs(wow.blocked) do if m.channel == "SAY" then said = said + 1 end end
                assert.are.equal(0, said, "seed " .. seed)
                assert.is_true(#wow.sent + #wow.emotes > 0, "the storm thanked someone")
            end)

            it("never errors with every choice in play: seed " .. seed, function()
                storm(seed * 104729, false)
                assert.is_true(#wow.sent + #wow.emotes > 0, "the storm thanked someone")
            end)
        end
    end)
end)
