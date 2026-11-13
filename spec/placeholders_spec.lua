-- Spec: #319
-- Placeholders in a line fill whatever their case, and a thank-you never
-- reaches chat with a known placeholder unfilled ("{Buff}"), whichever way
-- it goes out: whisper, /say, held /say, emote, the fallback, the buff-back
-- line, the options preview and /friendly test.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

-- Every placeholder the addon fills, written out here rather than read from
-- the code under test.
local KNOWN = { "name", "fullname", "buff", "class", "zone", "timeofday", "myclass", "greeting", "thanks",
    "blessing", "cheer" }

-- The known placeholders left in a sent line, found whatever their case.
local function unfilled(text)
    local left = {}
    for key in text:gmatch("{(%a+)}") do
        for _, known in ipairs(KNOWN) do
            if key:lower() == known then left[#left + 1] = "{" .. key .. "}" end
        end
    end
    return left
end

local FAIL = "No player named 'Bob-Stone' is currently playing."

-- What the client sent: /say lines, whispers as "target: text", emotes.
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

-- Press keys a while, so every /say line and /thank waiting goes out.
local function drain()
    for _ = 1, 6 do
        wow.advance(2)
        wow.keyDown()
    end
end

describe("Placeholders fill whatever their case (#319)", function()
    describe("Util.Render (white)", function()
        local ns, Util

        before_each(function()
            ns = wow.boot()
            Util = ns.Util
        end)

        local VARS = { name = "Bob", fullname = "Bob Stone", buff = "Fort" }

        it("{Buff}, {BUFF} and {buff} all render the buff name", function()
            assert.are.equal("Fort Fort Fort Fort", Util.Render("{Buff} {BUFF} {buff} {bUfF}", VARS))
        end)

        it("{Name}, {NAME} and {name} all render the name; the same for {FullName}", function()
            assert.are.equal("Bob Bob Bob", Util.Render("{Name} {NAME} {name}", VARS))
            assert.are.equal("Bob Stone Bob Stone Bob Stone", Util.Render("{FullName} {FULLNAME} {fullname}", VARS))
        end)

        it("flavour placeholders fill in any case too", function()
            local vars = ns.Flavour.Vars({ name = "Bob" }, { zone = "Elwynn Forest", partOfDay = "morning" })
            assert.are.equal("Elwynn Forest, Elwynn Forest, morning, friend",
                Util.Render("{Zone}, {ZONE}, {TimeOfDay}, {Class}", vars))
            local greeting = Util.Render("{Greeting}", ns.Flavour.Vars({}, { race = "Human", place = "wilds" }))
            assert.are.same({}, unfilled(greeting))
        end)

        it("values keep their own case", function()
            assert.are.equal("Thanks for the arcane INTELLECT, mcBob",
                Util.Render("Thanks for the {BUFF}, {Name}", { name = "mcBob", buff = "arcane INTELLECT" }))
        end)

        it("unknown placeholders, whatever their case, are still left as typed", function()
            assert.are.equal("Hi {Bfuf} {NMAE}", Util.Render("Hi {Bfuf} {NMAE}", VARS))
        end)
    end)

    describe("a known placeholder with no value (black)", function()
        local Util

        before_each(function() Util = wow.boot().Util end)

        it("{buff} with no buff given says \"buff\", in any case", function()
            assert.are.equal("Thanks for the buff, Bob! buff",
                Util.Render("Thanks for the {buff}, {name}! {BUFF}", { name = "Bob" }))
        end)

        it("{buff} whose value is blank once cleaned says \"buff\"", function()
            assert.are.equal("Thanks for the buff", Util.Render("Thanks for the {buff}", { buff = "|\1 " }))
        end)

        it("{name} and {fullname} with no name given say \"friend\"", function()
            assert.are.equal("Hi friend, friend", Util.Render("Hi {Name}, {fullname}", { buff = "Fort" }))
        end)
    end)

    describe("each way a buff thank-you goes out (white)", function()
        local ns

        local LINE = "Thanks for the {Buff}, {NAME} ({fullName})!"
        local NAMED = "Thanks for the Fort, Bob (Bob Stone)!"
        local FRIEND = "Thanks for the Fort, friend (friend)!"

        local function boot(style, fallback)
            ns = wow.boot()
            ns.db.buff.messages = { LINE }
            ns.db.buff.thankStyle, ns.db.buff.fallback = style, fallback or "say"
        end

        local function named()
            wow.addUnit("target", { name = "Bob", surname = "Stone" })
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
        end

        it("a whisper", function()
            boot("whisper")
            named()
            drain()
            assert.are.same({ say = {}, whisper = { "Bob-Stone: " .. NAMED }, emote = {} }, sent())
        end)

        it("a line in /say", function()
            boot("message")
            named()
            drain()
            assert.are.same({ say = { NAMED }, whisper = {}, emote = {} }, sent())
        end)

        it("a line and an emote", function()
            boot("both")
            named()
            drain()
            assert.are.same({ say = { NAMED }, whisper = {}, emote = { "THANK at target" } }, sent())
        end)

        it("an emote alone sends no text to fill", function()
            boot("emote")
            named()
            drain()
            assert.are.same({ say = {}, whisper = {}, emote = { "THANK at target" } }, sent())
        end)

        it("a /say held for a key press, filled when the key releases it", function()
            boot("message")
            named()
            wow.advance(ns.db.buff.delay + ns.Exchange.SETTLE + 1)
            assert.are.same({}, sent().say, "held until a key press")
            wow.keyDown()
            assert.are.same({ NAMED }, sent().say)
        end)

        it("a /say held for a key press, filled when a press of the buff button releases it", function()
            boot("message")
            local button = ns.BuffButton.Frame()
            named()
            wow.advance(ns.db.buff.delay + ns.Exchange.SETTLE + 1)
            assert.are.same({}, sent().say, "held until a press")
            wow.press(button)
            assert.are.same({ NAMED }, sent().say)
        end)

        it("a /say held for /friendly say", function()
            boot("message")
            named()
            wow.advance(ns.db.buff.delay + ns.Exchange.SETTLE + 1)
            wow.hardware = true
            _G.SlashCmdList.FRIENDLYFOREVER("say")
            wow.hardware = false
            assert.are.same({ NAMED }, sent().say)
        end)

        it("several buffs from one caster fill {buff} with every name", function()
            boot("whisper")
            ns.db.buff.listBuffNames = true
            wow.addUnit("target", { name = "Bob", surname = "Stone" })
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(1)
            wow.gainBuff({ sourceUnit = "target", name = "Spirit" })
            drain()
            assert.are.same({ "Bob-Stone: Thanks for the Fort and Spirit, Bob (Bob Stone)!" }, sent().whisper)
        end)

        it("the fallback for a caster the game won't name", function()
            boot("whisper", "say")
            wow.gainBuff({ name = "Fort" })
            drain()
            assert.are.same({ say = { FRIEND }, whisper = {}, emote = {} }, sent())
        end)

        it("the fallback when the whisper can't reach them", function()
            boot("whisper", "say")
            named()
            wow.advance(ns.db.buff.delay + ns.Exchange.SETTLE + 1)
            wow.systemMessage(FAIL)
            drain()
            assert.are.same({ say = { FRIEND }, whisper = { "Bob-Stone: " .. NAMED }, emote = {} }, sent())
        end)

        it("the buff-back line", function()
            local MOTW, MOTW_1, INTELLECT = 9885, 1126, 10157
            ns = wow.boot({ before = function(state)
                state.class = "DRUID"
                state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
            end })
            ns.db.buff.enabled = false -- only the buff-back line is sent
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "For you, {NAME}: {Buff}!" }
            local button = ns.BuffButton.Frame()
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            wow.press(button)
            drain()
            assert.are.same({ "For you, Bob: Mark of the Wild!" }, sent().say)
        end)

        it("the options preview and /friendly test show the line as it would be sent", function()
            boot("message")
            ns.db.buff.messages = { "Thanks for the {Buff}, {NAME}!" }
            local w = ns.Options.widgets
            wow.run(w.tabs.buff, "OnClick")
            wow.printed = {}
            wow.run(w.preview, "OnClick")
            _G.SlashCmdList.FRIENDLYFOREVER("test")
            local preview, test
            for _, line in ipairs(wow.printed) do
                if line:find("Thanks for the Power Word: Fortitude and Arcane Intellect, ", 1, true) then
                    if line:find("Buff Thanks: ", 1, true) then test = line else preview = line end
                end
                assert.are.same({}, unfilled(line), line)
            end
            assert.is_truthy(preview, "the preview fills {Buff}")
            assert.is_truthy(test and test:find("Thanks for the Power Word: Fortitude and Arcane Intellect, Nikki!",
                1, true), "/friendly test fills {Buff} and {NAME}")
        end)
    end)

    describe("a batch with no readable spell name (black)", function()
        local ns

        local function thank(auras)
            ns = wow.boot()
            ns.db.buff.messages = { "Thanks for the {buff}, {name}!" }
            ns.db.buff.thankStyle = "whisper"
            ns.db.buff.listBuffNames = true
            wow.addUnit("target", { name = "Bob", surname = "Stone" })
            for i, aura in ipairs(auras) do
                aura.sourceUnit = "target"
                aura.spellId = aura.spellId or (90000 + i)
                wow.gainBuff(aura)
                wow.advance(0.5)
            end
            drain()
            assert.are.same({}, wow.errors)
            return sent().whisper
        end

        it("one buff with no name says \"buff\"", function()
            assert.are.same({ "Bob-Stone: Thanks for the buff, Bob!" }, thank({ {} }))
        end)

        it("one buff whose name is secret says \"buff\"", function()
            assert.are.same({ "Bob-Stone: Thanks for the buff, Bob!" }, thank({ { name = wow.secret("Fort") } }))
        end)

        it("two buffs with no names say \"buffs\"", function()
            assert.are.same({ "Bob-Stone: Thanks for the buffs, Bob!" }, thank({ {}, {} }))
        end)

        it("a buff whose name is blank once cleaned says \"buff\", never an empty gap", function()
            assert.are.same({ "Bob-Stone: Thanks for the buff, Bob!" }, thank({ { name = "" } }))
            assert.are.same({ "Bob-Stone: Thanks for the buff, Bob!" }, thank({ { name = " |\1" } }))
        end)

        it("a blank name beside a readable one is left out of the list", function()
            assert.are.same({ "Bob-Stone: Thanks for the Fort, Bob!" },
                thank({ { name = "" }, { name = "Fort" } }))
        end)
    end)

    describe("a storm of buffs, fallbacks and held lines (red)", function()
        local STYLES = { "message", "whisper", "emote", "both" }
        local FALLBACKS = { "say", "emote", "none" }
        local CASTERS = {
            { name = "Bob", surname = "Stone" },
            { name = "Ann", surname = "Vale" },
            { name = "Cy", surname = "Moor" },
        }

        -- A placeholder in a random case: {buff}, {BUFF}, {Buff}, {bUFf}...
        local function anyCase(key)
            local pick = random.random(4)
            if pick == 1 then return key end
            if pick == 2 then return key:upper() end
            if pick == 3 then return key:sub(1, 1):upper() .. key:sub(2) end
            return (key:gsub("%a", function(c) return random.random(2) == 1 and c:upper() or c end))
        end

        local function randomLine()
            local parts = {}
            for _ = 1, random.random(1, 4) do
                parts[#parts + 1] = "{" .. anyCase(KNOWN[random.random(#KNOWN)]) .. "}"
            end
            return "Thanks " .. table.concat(parts, " ") .. "!"
        end

        local NAMES = { "Fort", "Spirit", "", " |\1", false, "secret" }

        for seed = 1, 25 do
            it("never sends a known placeholder unfilled, seed " .. seed, function()
                random.seed(seed * 7919)
                local ns = wow.boot()
                ns.db.buff.thankStyle = STYLES[random.random(#STYLES)]
                ns.db.buff.fallback = FALLBACKS[random.random(#FALLBACKS)]
                -- Emotes alone have no text: then the fallback says a line.
                if ns.db.buff.thankStyle == "emote" then ns.db.buff.fallback = "say" end
                ns.db.buff.listBuffNames = random.random(2) == 1
                ns.db.buff.quietInCities = false
                ns.db.buff.messages = { randomLine(), randomLine(), randomLine() }
                for i, c in ipairs(CASTERS) do
                    wow.addUnit("nameplate" .. i, { name = c.name, surname = c.surname,
                        id = c.name .. "-" .. c.surname })
                end
                for _ = 1, 60 do
                    local roll = random.random(10)
                    if roll <= 4 then
                        local aura = { spellId = 90000 + random.random(20) }
                        local name = NAMES[random.random(#NAMES)]
                        if name == "secret" then aura.name = wow.secret("Fort")
                        elseif name then aura.name = name end
                        if random.random(4) > 1 then aura.sourceUnit = "nameplate" .. random.random(#CASTERS) end
                        wow.gainBuff(aura)
                    elseif roll == 5 then
                        local c = CASTERS[random.random(#CASTERS)]
                        wow.systemMessage("No player named '" .. c.name .. "-" .. c.surname
                            .. "' is currently playing.")
                    elseif roll == 6 then
                        wow.keyDown()
                    elseif roll == 7 then
                        ns.db.buff.messages[random.random(3)] = randomLine()
                    else
                        wow.advance(random.random() * 6)
                    end
                end
                for _ = 1, 40 do
                    wow.advance(5)
                    wow.keyDown()
                end
                assert.are.same({}, wow.errors)
                assert.is_true(#wow.sent > 0, "the storm sent something")
                for _, m in ipairs(wow.sent) do
                    assert.are.same({}, unfilled(m.text), m.text)
                    assert.is_nil(m.text:find("[{}]"), "every placeholder in the lines is known: " .. m.text)
                end
            end)
        end
    end)
end)
