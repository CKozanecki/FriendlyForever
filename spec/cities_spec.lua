-- Spec: #34, #101
-- Quiet mode in capital cities: no thank-yous and no buff-back button there,
-- unless buff mode is on; the ledger and the favours still count.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1 = 9885, 1126
local INTELLECT = 10157

-- The capitals as this spec knows them (Classic Era's uiMapIDs), kept apart
-- from the addon's own list so the checks don't use the code under test.
local CAPITAL_IDS = { [1453] = true, [1454] = true, [1455] = true, [1456] = true, [1457] = true, [1458] = true }

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Quiet mode in capital cities", function()
    local ns, button

    -- A druid who knows Mark of the Wild, so a favour can show on the button.
    local function boot(db, opts)
        opts = opts or {}
        ns = wow.boot({ db = db, autoBuffMode = opts.autoBuffMode, before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
            if opts.before then opts.before(state) end
        end })
        ns.db.buff.messages = { "Thanks {name}" }
        button = ns.BuffButton.Frame()
    end

    local function stranger(token, name)
        name = name or "Bob"
        wow.addUnit(token or "nameplate1", { name = name, surname = "Stone", class = "WARRIOR", id = name .. "-Stone" })
    end

    local function buffedBy(token)
        wow.gainBuff({ sourceUnit = token or "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
    end

    -- Past the thank-you's delay, and its hold while the button is armed for
    -- them (#36), with a key press for a waiting /say.
    local function settle()
        wow.advance(math.max(ns.db.buff.delay, ns.Exchange.HOLD_CAP) + 0.01)
        wow.keyDown()
    end

    local function ledger() return ns.db.ledger.entries end
    local function thanksSent() return #wow.sentTo("SAY") + #wow.sentTo("WHISPER") + #wow.emotes end
    -- Buff mode as the client sees it: a key lent to the button.
    local function keyLent()
        for _, o in pairs(wow.state.overrides) do
            if o.button == ns.BuffButton.FRAME_NAME then return true end
        end
        return false
    end

    before_each(function() boot() end)

    describe("in a capital (white)", function()
        it("is on by default, and the button in capitals is off by default", function()
            assert.is_true(ns.db.buff.quietInCities)
            assert.is_false(ns.db.buffBack.showInCities)
        end)

        it("sends no thank-you lines, in /say, a whisper or a /thank, in every capital", function()
            for _, style in ipairs({ "message", "whisper", "emote", "both" }) do
                for _, fallback in ipairs({ "say", "emote" }) do
                    for _, id in pairs(wow.CAPITAL) do
                        boot()
                        ns.db.buff.thankStyle, ns.db.buff.fallback = style, fallback
                        wow.setMap(id)
                        stranger()
                        buffedBy()
                        settle()
                        assert.are.equal(0, thanksSent(), style .. ", map " .. id)
                    end
                end
            end
        end)

        it("doesn't thank a caster it can't name either (the /say fallback)", function()
            wow.setMap(wow.CAPITAL.orgrimmar)
            wow.gainBuff({ name = "Arcane Intellect", spellId = INTELLECT })
            settle()
            assert.are.equal(0, thanksSent())
            assert.are.equal("?unknown", ledger()[1].who)
        end)

        it("still counts each favour in the ledger, with why it wasn't thanked", function()
            wow.setMap(wow.CAPITAL.stormwind)
            stranger()
            buffedBy()
            settle()
            assert.are.equal(1, #ledger())
            assert.are.equal("Bob-Stone", ledger()[1].who)
            assert.are.equal(ns.Ledger.NOT_THANKED, ledger()[1].result)
            assert.are.equal("quiet in a capital city", ledger()[1].note)
            assert.are.equal(1, ns.db.ledger.totals.received)
        end)

        it("adds a buff from the same caster within the thank-you's delay to the same favour", function()
            wow.setMap(wow.CAPITAL.ironforge)
            stranger()
            buffedBy()
            wow.advance(ns.db.buff.delay - 1)
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Mark of the Wild", spellId = MOTW })
            assert.are.equal(1, #ledger())
            assert.are.same({ "Arcane Intellect", "Mark of the Wild" }, ledger()[1].buffs)
        end)

        it("thanks a caster from the city as usual once you've left, with no repeat cooldown used up", function()
            wow.setMap(wow.CAPITAL.ironforge)
            stranger()
            buffedBy()
            settle()
            wow.setMap(wow.ELWYNN)
            wow.advance(10)
            buffedBy()
            settle()
            assert.are.same({ "Thanks Bob" }, wow.sentTo("SAY"))
        end)

        it("counts a wave of buffs from one caster as one favour, as a thank-you would have", function()
            wow.setMap(wow.CAPITAL.ironforge)
            stranger()
            wow.gainBuffs({
                { sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT },
                { sourceUnit = "nameplate1", name = "Mark of the Wild", spellId = MOTW },
            })
            buffedBy()
            assert.are.equal(1, #ledger())
            assert.are.same({ "Arcane Intellect", "Mark of the Wild" }, ledger()[1].buffs)
            -- Once the wave is over, the next buff is a new favour.
            settle()
            buffedBy()
            assert.are.equal(2, #ledger())
        end)

        it("drops a thank-you still waiting when you walk into a capital", function()
            stranger()
            buffedBy()
            wow.advance(1)
            wow.setMap(wow.CAPITAL.darnassus, { silent = true })
            settle()
            assert.are.equal(0, thanksSent())
            assert.are.equal("quiet in a capital city", ledger()[1].note)
        end)

        it("doesn't use up the chat's lines a minute with thank-yous it dropped in a capital", function()
            local function waveFrom(names)
                for i, name in ipairs(names) do
                    stranger("nameplate" .. i, name)
                    buffedBy("nameplate" .. i)
                end
            end
            local function pressKeys()
                for _ = 1, 8 do
                    wow.advance(ns.ChatQueue.MIN_INTERVAL + 0.01)
                    wow.keyDown()
                end
            end
            assert.are.equal(4, ns.db.linesPerMinute, "the default cap: four would fill it")
            waveFrom({ "Bob", "Gus", "Hal", "Ivy" })
            wow.advance(1)
            wow.setMap(wow.CAPITAL.stormwind)
            pressKeys()
            assert.are.equal(0, thanksSent(), "all four dropped in the city")
            wow.setMap(wow.ELWYNN)
            waveFrom({ "Jon", "Kay", "Lee", "Max" })
            pressKeys()
            assert.are.equal(4, #wow.sentTo("SAY"), "the next four, within the minute, all go out")
        end)

        it("records a thank-you dropped on walking into a capital as quiet, even with the chat's cap full", function()
            for i, name in ipairs({ "Bob", "Gus", "Hal", "Ivy" }) do
                stranger("nameplate" .. i, name)
                buffedBy("nameplate" .. i)
            end
            for _ = 1, 8 do
                wow.advance(ns.ChatQueue.MIN_INTERVAL + 0.01)
                wow.keyDown()
            end
            assert.are.equal(4, #wow.sentTo("SAY"), "the /say cap is full")
            stranger("nameplate5", "Jon")
            buffedBy("nameplate5")
            wow.advance(1)
            wow.setMap(wow.CAPITAL.stormwind)
            local printedBefore = #wow.printed
            settle()
            wow.advance(ns.ChatQueue.MIN_INTERVAL + 0.01)
            wow.keyDown()
            local entry = ledger()[#ledger()]
            assert.are.equal("Jon-Stone", entry.who)
            assert.are.equal("quiet in a capital city", entry.note, "dropped by quiet mode, not the cap")
            for i = printedBefore + 1, #wow.printed do
                assert.is_nil(wow.printed[i]:find("skipped a thank-you", 1, true), "no chat-cap hint")
            end
        end)

        it("drops the /say fallback for a failed whisper once you're in a capital", function()
            ns.db.buff.thankStyle = "whisper"
            stranger()
            buffedBy()
            wow.advance(math.max(ns.db.buff.delay, ns.Exchange.HOLD_CAP) + 0.01)
            assert.are.equal(1, #wow.sentTo("WHISPER"))
            wow.setMap(wow.CAPITAL.undercity)
            wow.systemMessage("No player named '" .. wow.sent[1].target .. "' is currently playing.")
            settle()
            assert.are.same({}, wow.sentTo("SAY"))
        end)

        it("hides the buff-back button by default, still collecting the favour", function()
            wow.setMap(wow.CAPITAL.thunderBluff)
            stranger()
            buffedBy()
            assert.is_false(button:IsShown())
            assert.is_nil(button:GetAttribute("*macrotext1"), "nothing to press")
            assert.are.equal(1, ns.Offers.Count())
        end)

        it("shows the favours once you leave, if they haven't expired", function()
            wow.setMap(wow.CAPITAL.thunderBluff)
            stranger()
            buffedBy()
            wow.setMap(wow.ELWYNN)
            wow.advance(0.01)
            assert.is_true(button:IsShown())
            assert.truthy(button:GetAttribute("*macrotext1"):find("/targetexact Bob Stone", 1, true))
        end)

        it("shows them on leaving even without a zone event (the re-check finds it)", function()
            wow.setMap(wow.CAPITAL.thunderBluff)
            stranger()
            buffedBy()
            wow.setMap(wow.ELWYNN, { silent = true })
            wow.advance(ns.BuffButton.RECHECK_SECONDS + 0.01)
            assert.is_true(button:IsShown())
        end)

        it("doesn't show favours that expired while you were in the city", function()
            wow.setMap(wow.CAPITAL.thunderBluff)
            stranger()
            buffedBy()
            wow.advance(ns.db.buffBack.owedMinutes * 60 + 1)
            wow.setMap(wow.ELWYNN)
            wow.advance(0.01)
            assert.is_false(button:IsShown())
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("hides a favour shown before you walked in", function()
            stranger()
            buffedBy()
            assert.is_true(button:IsShown())
            wow.setMap(wow.CAPITAL.stormwind)
            wow.advance(0.01)
            assert.is_false(button:IsShown())
        end)

        it("shows or hides the button as soon as the option is ticked or unticked", function()
            wow.setMap(wow.CAPITAL.stormwind)
            stranger()
            buffedBy()
            assert.is_false(button:IsShown())
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            w.showInCities:SetChecked(true)
            wow.run(w.showInCities, "OnClick")
            assert.is_true(button:IsShown(), "shown at once")
            w.showInCities:SetChecked(false)
            wow.run(w.showInCities, "OnClick")
            assert.is_false(button:IsShown(), "hidden at once")
        end)

        it("follows a move between a city and its surroundings on any of the game's zone events", function()
            for _, event in ipairs({ "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA" }) do
                boot()
                stranger()
                buffedBy()
                assert.is_true(button:IsShown(), event)
                wow.setMap(wow.CAPITAL.stormwind, { silent = true })
                wow.fire(event)
                wow.advance(0.01)
                assert.is_false(button:IsShown(), event .. ": hidden on entering")
                wow.setMap(wow.ELWYNN, { silent = true })
                wow.fire(event)
                wow.advance(0.01)
                assert.is_true(button:IsShown(), event .. ": shown on leaving")
            end
        end)

        it("shows the button in a capital when the option is on", function()
            ns.db.buffBack.showInCities = true
            wow.setMap(wow.CAPITAL.stormwind)
            stranger()
            buffedBy()
            assert.is_true(button:IsShown())
            settle()
            assert.are.equal(0, thanksSent(), "thanks stay quiet")
        end)

        it("thanks in a capital when quiet mode is off, the button still following its own option", function()
            ns.db.buff.quietInCities = false
            wow.setMap(wow.CAPITAL.stormwind)
            stranger()
            buffedBy()
            settle()
            assert.are.same({ "Thanks Bob" }, wow.sentTo("SAY"))
            assert.is_false(button:IsShown())
        end)

        it("doesn't let a stranger's buff turn buff mode on there (it would end quiet mode)", function()
            boot(nil, { autoBuffMode = true })
            wow.setMap(wow.CAPITAL.orgrimmar)
            stranger()
            buffedBy()
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_false(keyLent())
            -- Outside a capital it does, as before.
            wow.setMap(wow.ELWYNN)
            stranger("nameplate2", "Gus")
            buffedBy("nameplate2")
            assert.is_true(ns.BuffMode.IsOn())
        end)

        it("keeps that trigger off there while either quiet holds, and on once neither does", function()
            for _, case in ipairs({
                { quiet = true, show = true, on = false },
                { quiet = false, show = false, on = false },
                { quiet = false, show = true, on = true },
            }) do
                boot(nil, { autoBuffMode = true })
                ns.db.buff.quietInCities, ns.db.buffBack.showInCities = case.quiet, case.show
                wow.setMap(wow.CAPITAL.orgrimmar)
                stranger()
                buffedBy()
                assert.are.equal(case.on, ns.BuffMode.IsOn(), tostring(case.quiet) .. "/" .. tostring(case.show))
            end
        end)

        it("leaves greetings alone", function()
            boot(nil, { before = function(state) state.guildRoster = { "Thrall" } end })
            wow.fire("GUILD_ROSTER_UPDATE")
            ns.db.guildLogin.messages = { "Hi {name}" }
            wow.setMap(wow.CAPITAL.stormwind)
            wow.systemMessage("|Hplayer:Thrall|h[Thrall]|h has come online.")
            wow.advance(ns.db.guildLogin.delay + 0.01)
            assert.are.same({ "Hi Thrall" }, wow.sentTo("GUILD"))
        end)

        it("says in /friendly status which capital you're in, by map ID", function()
            wow.setMap(wow.CAPITAL.stormwind)
            slash("status")
            local found
            for _, line in ipairs(wow.printed) do
                if line:find("capital city: Stormwind City (map 1453)", 1, true) then found = line end
            end
            assert.truthy(found)
            assert.truthy(found:find("thanks quiet, buff-back button hidden", 1, true))
        end)

        it("says in /friendly status when quiet mode doesn't hold, and where you are outside capitals", function()
            wow.setMap(wow.CAPITAL.stormwind)
            slash("buffmode on")
            assert.are.equal("capital city: Stormwind City (map 1453); thanks not quiet, buff-back button not hidden",
                ns.Cities.StatusLine())
            wow.setMap(wow.ELWYNN)
            assert.are.equal("capital city: no (map 1429)", ns.Cities.StatusLine())
        end)

        it("puts each option on a row of its own, under the row before it", function()
            local w = ns.Options.widgets
            local function below(region, above)
                local point, relativeTo, relativePoint, _, y = region:GetPoint(1)
                return point == "TOPLEFT" and relativeTo == above and relativePoint == "BOTTOMLEFT" and y < 0
            end
            assert.is_true(below(w.quiet, w.fallbackLabel), "quiet mode under the fallback choice")
            assert.is_true(below(w.nameplateWarning, w.quiet), "then the nameplate warning")
            assert.is_true(below(w.showInCities, w.sayLine), "the capital-city button option under the line")
            assert.is_true(below(w.buffOrderHeader, w.showInCities), "then the buff order")
        end)

        it("has the two options on their tabs, and they change the settings", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buff, "OnClick")
            assert.is_true(w.quiet:IsShown())
            assert.is_true(w.quiet:GetChecked())
            assert.is_false(w.showInCities:IsShown())
            w.quiet:SetChecked(false)
            wow.run(w.quiet, "OnClick")
            assert.is_false(ns.db.buff.quietInCities)
            wow.run(w.tabs.buffBack, "OnClick")
            assert.is_false(w.quiet:IsShown())
            assert.is_true(w.showInCities:IsShown())
            assert.is_false(w.showInCities:GetChecked())
            w.showInCities:SetChecked(true)
            wow.run(w.showInCities, "OnClick")
            assert.is_true(ns.db.buffBack.showInCities)
        end)
    end)

    describe("outside capitals (white)", function()
        it("thanks as usual in an inn or a small town, though you're resting there", function()
            for _, place in ipairs({ { map = 1429, zone = "Goldshire" }, { map = 1411, zone = "Razor Hill" },
                { map = 1426, zone = "Kharanos" } }) do
                boot(nil, { before = function(state) state.resting, state.zone = true, place.zone end })
                wow.setMap(place.map)
                stranger()
                buffedBy()
                assert.is_true(button:IsShown(), place.zone)
                settle()
                assert.are.same({ "Thanks Bob" }, wow.sentTo("SAY"), place.zone)
            end
        end)
    end)

    describe("buff mode in a capital (white)", function()
        it("thanks and shows the button as usual", function()
            wow.setMap(wow.CAPITAL.stormwind)
            slash("buffmode on")
            stranger()
            buffedBy()
            assert.is_true(button:IsShown())
            assert.truthy(button:GetAttribute("*macrotext1"):find("/targetexact Bob Stone", 1, true))
            settle()
            assert.are.same({ "Thanks Bob" }, wow.sentTo("SAY"))
        end)

        it("when a trigger turned it on: joining a group in the city", function()
            boot(nil, { autoBuffMode = true })
            wow.setMap(wow.CAPITAL.stormwind)
            wow.setGroup("party", { "Ann-Vale" })
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.BuffMode.IsOn())
            stranger()
            buffedBy()
            settle()
            -- The party's hello went just before it.
            wow.advance(ns.ChatQueue.MIN_INTERVAL)
            wow.keyDown()
            assert.are.same({ "Thanks Bob" }, wow.sentTo("SAY"))
        end)

        it("goes quiet again when buff mode ends", function()
            wow.setMap(wow.CAPITAL.stormwind)
            slash("buffmode on")
            stranger()
            buffedBy()
            settle()
            assert.is_true(button:IsShown())
            slash("buffmode off")
            assert.is_false(button:IsShown())
            stranger("nameplate2", "Gus")
            buffedBy("nameplate2")
            settle()
            assert.are.same({ "Thanks Bob" }, wow.sentTo("SAY"), "Gus isn't thanked")
        end)
    end)

    describe("bad input (black)", function()
        it("asks for a restart, not erroring, after an update that added Cities.lua and only a /reload", function()
            wow.reset()
            local loaded = {}
            local _, files = wow.parseToc()
            for _, file in ipairs(files) do
                if file ~= "Cities.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
            end
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            wow.fire("PLAYER_ENTERING_WORLD", true, false)
            wow.advance(20)
            stranger()
            buffedBy()
            wow.fire("ZONE_CHANGED_NEW_AREA")
            wow.advance(10)
            assert.are.same({}, wow.errors)
            assert.are.equal(0, #wow.sent)
            assert.truthy(table.concat(wow.printed, "\n"):find("Restart the game (not /reload)", 1, true))
        end)

        it("counts a map it can't read as not a capital", function()
            local reads = {
                ["no map (a loading screen)"] = function() return nil end,
                ["a secret"] = function() return wow.secret(1453) end,
                ["an error"] = function() error("not now") end,
                ["not a number"] = function() return "1453" end,
                ["a table"] = function() return { 1453 } end,
                ["not a number at all (NaN)"] = function() return 0 / 0 end,
            }
            for what, read in pairs(reads) do
                boot()
                _G.C_Map.GetBestMapForUnit = read
                assert.is_nil(ns.Cities.Capital(), what)
                assert.are.equal("capital city: can't read the map, so not quiet", ns.Cities.StatusLine(), what)
                stranger()
                buffedBy()
                assert.is_true(button:IsShown(), what)
                settle()
                assert.are.same({ "Thanks Bob" }, wow.sentTo("SAY"), what)
            end
            boot()
            _G.C_Map = nil
            assert.is_nil(ns.Cities.Capital(), "no C_Map at all")
            assert.truthy(ns.Cities.StatusLine():find("can't read the map", 1, true))
        end)

        it("doesn't count maps that aren't capitals, however close their numbers", function()
            for _, id in ipairs({ 1452, 1459, 0, -1453, 1453.5, 84, math.huge }) do
                wow.setMap(id)
                assert.is_nil(ns.Cities.Capital(), tostring(id))
            end
        end)

        it("repairs damaged options to their defaults when loading", function()
            for _, bad in ipairs({ "yes", 1, {}, false }) do
                local db = { buff = { quietInCities = bad }, buffBack = { showInCities = bad } }
                boot(db)
                assert.are.equal(bad ~= false, ns.db.buff.quietInCities, tostring(bad))
                assert.is_false(ns.db.buffBack.showInCities, tostring(bad))
            end
            boot({ buffBack = { showInCities = true } })
            assert.is_true(ns.db.buffBack.showInCities, "a good value stays")
        end)

        it("reads options damaged mid-session as their defaults, and repairs them", function()
            wow.setMap(wow.CAPITAL.stormwind)
            ns.db.buff.quietInCities = "off"
            ns.db.buffBack.showInCities = "on"
            stranger()
            buffedBy()
            settle()
            assert.are.equal(0, thanksSent(), "quiet, as by default")
            assert.is_false(button:IsShown(), "hidden, as by default")
            ns.db.buff = { enabled = "broken" }
            ns.Config.Repair()
            assert.is_true(ns.db.buff.quietInCities)
            assert.is_false(ns.db.buffBack.showInCities)
        end)

        it("carries the options in profiles and settings lines", function()
            ns.db.buff.quietInCities = false
            ns.db.buffBack.showInCities = true
            local snap = ns.Profiles.Snapshot(ns.db)
            assert.is_false(snap.buff.quietInCities)
            assert.is_true(snap.buffBack.showInCities)
        end)
    end)

    describe("a storm of zone changes, buff mode and buffs (red)", function()
        -- One seeded storm. Every thank-you the client sends is checked
        -- against where the client was and whether a key was lent to the
        -- button at that moment, never against the addon's own idea of it.
        local function storm(seed, opts)
            random.seed(seed)
            boot(nil, opts)
            ns.db.buff.thankStyle = ({ "message", "whisper", "emote", "both" })[random.random(4)]
            ns.db.buff.fallback = ({ "say", "emote", "none" })[random.random(3)]
            local maps = { 1453, 1454, 1455, 1456, 1457, 1458, 1429, 1411, 1426, false }
            local names = { "Bob", "Gus", "Hal", "Ivy" }
            local thanked, quietSteps = 0, 0
            local actions = {
                function()
                    local id = maps[random.random(#maps)]
                    wow.setMap(id or nil, { silent = random.random() < 0.3 })
                end,
                function() slash(({ "buffmode", "buffmode on", "buffmode off" })[random.random(3)]) end,
                function()
                    local token = "nameplate" .. random.random(1, 3)
                    stranger(token, names[random.random(#names)])
                    buffedBy(token)
                end,
                function() wow.gainBuff({ name = "Arcane Intellect", spellId = INTELLECT }) end,
                function() wow.advance(random.random() * 8) end,
                function() wow.keyDown() end,
                function() wow.pressKey("MOUSEWHEELUP") end,
                function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                function()
                    -- Damaged mid-session, as another addon might.
                    if random.random() < 0.5 then ns.db.buff.quietInCities = "x" else ns.db.buff.quietInCities = true end
                end,
            }
            for step = 1, 400 do
                local where = ("seed %d, step %d"):format(seed, step)
                local before = thanksSent()
                -- In a fight the key is handed back whatever buff mode is,
                -- so the client can't tell: those steps aren't judged.
                local judged = not wow.state.inCombat
                local quiet = judged and CAPITAL_IDS[wow.state.mapId or -1] and not keyLent()
                actions[random.random(#actions)]()
                local sent = thanksSent() - before
                -- Moving and buff mode take effect at once; sending happens
                -- in the steps that pass time or press keys, where neither
                -- changes, so the state before the step is the state at the send.
                if sent > 0 then
                    assert.is_falsy(quiet, where .. ": a thank-you went out in a capital without buff mode")
                    thanked = thanked + sent
                end
                if quiet then quietSteps = quietSteps + 1 end
                assert.is_nil(ns.Diag.Counters().luaErrors, where .. ": " .. tostring(ns.Diag.lastError))
            end
            return thanked, quietSteps
        end

        it("never sends a thank-you while quiet mode applies, and never errors", function()
            local thanked, quiet = 0, 0
            for _, seed in ipairs({ 3, 34, 77, 1105, 2026 }) do
                for _, auto in ipairs({ false, true }) do
                    local t, q = storm(seed, { autoBuffMode = auto })
                    thanked, quiet = thanked + t, quiet + q
                end
            end
            -- The storms reach both sides: thank-yous outside quiet mode, and
            -- many steps inside it.
            assert.is_true(thanked > 20, "thank-yous sent: " .. thanked)
            assert.is_true(quiet > 200, "steps in quiet mode: " .. quiet)
        end)
    end)
end)
