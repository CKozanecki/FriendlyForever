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

        -- No buff path today sends without its vars (BuffTracker and BuffButton
        -- all set opts.vars), but the issue names this path as a cause: if one
        -- ever does, the name-only vars still never leave {buff} in chat.
        it("a buff thank-you queued without its vars still fills {buff}", function()
            boot("whisper")
            ns.Announcer.Schedule("buff", "Bob-Stone", { channel = "WHISPER", target = "Bob-Stone" })
            drain()
            assert.are.same({ "Bob-Stone: Thanks for the buff, Bob (Bob Stone)!" }, sent().whisper)
        end)

        it("a held thank-you that swaps in another line, queued without its vars, still fills {buff}", function()
            boot("whisper")
            ns.db.buff.messages = { "First {buff}", "Second: {BUFF} for {Name}" }
            ns.Announcer.Schedule("buff", "Bob-Stone", { channel = "WHISPER", target = "Bob-Stone",
                hold = function(go) go(2) end })
            drain()
            assert.are.same({ "Bob-Stone: Second: buff for Bob" }, sent().whisper)
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

        -- Every line names them and the buff in some case, so a fallback
        -- ("Stranger") and a buff with no readable name ("buff") show.
        local function randomLine()
            local parts = { "{" .. anyCase("name") .. "}", "{" .. anyCase("buff") .. "}" }
            for _ = 1, random.random(0, 3) do
                parts[#parts + 1] = "{" .. anyCase(KNOWN[random.random(#KNOWN)]) .. "}"
            end
            return "Thanks " .. table.concat(parts, " ") .. "!"
        end

        -- Readable names, unreadable ones (blank, blank once cleaned, none,
        -- secret), and more of the unreadable, so whole batches have none.
        local NAMES = { "Fort", "Spirit", "", " |\1", false, "secret", false, "" }
        local FAIL_WINDOW = 5 -- seconds a "no player named" reply counts as our whisper failing
        local STRANGER = "Stranger"
        -- Each style, fallback and with-or-without unnamed casters, twice.
        local SEEDS = 48

        -- How often the storms reached each path the criterion names, worked
        -- out from the simulated client's own records (what it sent, and when),
        -- never from the addon's state.
        local reached

        local function lastWhisperTo(name)
            for i = #wow.sent, 1, -1 do
                local m = wow.sent[i]
                if m.channel == "WHISPER" and m.target == name then return m.time end
            end
        end

        local function storm(seed)
            random.seed(seed * 7919)
            local ns = wow.boot()
            -- Every style with every fallback, each with and without unnamed casters.
            local style = STYLES[(seed - 1) % #STYLES + 1]
            ns.db.buff.thankStyle = style
            ns.db.buff.fallback = FALLBACKS[math.floor((seed - 1) / #STYLES) % #FALLBACKS + 1]
            -- Emotes alone have no text: then the fallback says a line.
            if style == "emote" then ns.db.buff.fallback = "say" end
            local listed = random.random(2) == 1
            ns.db.buff.listBuffNames = listed
            ns.db.buff.quietInCities = false
            ns.db.buff.unknownName = STRANGER
            ns.db.buff.messages = { randomLine(), randomLine(), randomLine() }
            -- Some storms have no caster the game won't name, so a "Stranger"
            -- line in them can only be a failed whisper's fallback.
            local unnamed = math.floor((seed - 1) / 12) % 2 == 1
            -- With /thank alone, only an unnamed caster's fallback says a line.
            if style == "emote" then unnamed = true end
            for i, c in ipairs(CASTERS) do
                wow.addUnit("nameplate" .. i, { name = c.name, surname = c.surname, id = c.name .. "-" .. c.surname })
            end
            local fails = {} -- when a "no player named" reply followed our whisper to them

            -- A key press; a /say it lets out was a line held for one.
            local function press()
                local before = #wow.sent
                wow.keyDown()
                for i = before + 1, #wow.sent do
                    if wow.sent[i].channel == "SAY" then reached.held = reached.held + 1 end
                end
            end

            for _ = 1, 60 do
                local roll = random.random(10)
                if roll <= 4 then
                    local aura = { spellId = 90000 + random.random(20) }
                    local name = NAMES[random.random(#NAMES)]
                    if name == "secret" then aura.name = wow.secret("Fort")
                    elseif name then aura.name = name end
                    if not unnamed or random.random(4) > 1 then
                        aura.sourceUnit = "nameplate" .. random.random(#CASTERS)
                    end
                    wow.gainBuff(aura)
                elseif roll == 5 then
                    -- Mostly the one just whispered, so the fallback is reached.
                    local c = CASTERS[random.random(#CASTERS)]
                    local full = c.name .. "-" .. c.surname
                    if random.random(4) > 1 then
                        for i = #wow.sent, 1, -1 do
                            if wow.sent[i].channel == "WHISPER" then full = wow.sent[i].target break end
                        end
                    end
                    local whispered = lastWhisperTo(full)
                    if whispered and wow.now - whispered <= FAIL_WINDOW then fails[#fails + 1] = wow.now end
                    wow.systemMessage("No player named '" .. full .. "' is currently playing.")
                elseif roll == 6 then
                    press()
                elseif roll == 7 then
                    ns.db.buff.messages[random.random(3)] = randomLine()
                else
                    wow.advance(random.random() * 6)
                end
            end
            for _ = 1, 40 do
                wow.advance(5)
                press()
            end
            assert.are.same({}, wow.errors)
            assert.is_true(#wow.sent > 0, "the storm sent something")
            for _, m in ipairs(wow.sent) do
                assert.are.same({}, unfilled(m.text), m.text)
                assert.is_nil(m.text:find("[{}]"), "every placeholder in the lines is known: " .. m.text)
            end

            -- What this storm reached, from what was sent and when.
            for _, m in ipairs(wow.sent) do
                local stranger = m.channel == "SAY" and m.text:find(STRANGER, 1, true)
                -- No whispers: a "Stranger" line is the unnamed caster's fallback.
                if stranger and style ~= "whisper" then reached.unknown = reached.unknown + 1 end
                -- No unnamed casters: a "Stranger" line after a whisper failed
                -- is that whisper's fallback.
                if stranger and style == "whisper" and not unnamed and fails[1] and m.time >= fails[1] then
                    reached.failedWhisper = reached.failedWhisper + 1
                end
                -- Names listed, yet "buff" or "buffs": a batch with no readable name.
                if listed and (m.text:find("%f[%a]buffs?%f[%A]")) then
                    reached.unreadable = reached.unreadable + 1
                end
            end
        end

        for seed = 1, SEEDS do
            it("never sends a known placeholder unfilled, seed " .. seed, function()
                reached = { held = 0, unknown = 0, failedWhisper = 0, unreadable = 0 }
                storm(seed)
            end)
        end

        it("the storms reach every path the criterion names", function()
            -- Its own storms: no test depends on another's order.
            reached = { held = 0, unknown = 0, failedWhisper = 0, unreadable = 0 }
            for seed = 1, SEEDS do storm(seed) end
            assert.is_true(reached.held > 0, "a /say held for a key press")
            assert.is_true(reached.unknown > 0, "the fallback for a caster the game won't name")
            assert.is_true(reached.failedWhisper > 0, "the fallback when a whisper can't reach them")
            assert.is_true(reached.unreadable > 0, "a thank-you for a batch with no readable buff name")
        end)
    end)
end)
