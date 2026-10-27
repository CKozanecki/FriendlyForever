-- Flavour placeholders and the shipped message lines that use them.
local wow = require("spec.support.wow")

-- The longest values a line can realistically get, so the length check is
-- a worst case: Forever names are two parts of up to 12 letters.
local LONG = {
    name = "Abcdefghijkl", fullname = "Abcdefghijkl Mnopqrstuvwx",
    buff = "Power Word: Fortitude, Shadow Protection and Divine Spirit",
    zone = "The Temple of Atal'Hakkar", class = "warlock", myclass = "paladin",
}

-- Joins that read wrongly: a placeholder left as typed, doubled or clashing
-- punctuation, stray spaces.
local function Problems(text)
    local out = {}
    if text:find("{", 1, true) or text:find("}", 1, true) then out[#out + 1] = "leftover placeholder" end
    if text:find("  ", 1, true) then out[#out + 1] = "double space" end
    if text:find(" [,%.!%?]") then out[#out + 1] = "space before punctuation" end
    if text:find("[%.!%?,][%.!,]") and not text:find("%.%.%.") then out[#out + 1] = "doubled punctuation" end
    if text:find("^%s") or text:find("%s$") then out[#out + 1] = "space at an end" end
    if #text > 255 then out[#out + 1] = "over 255 bytes (" .. #text .. ")" end
    return out
end

-- Every fragment of a slot, from every pool.
local function AllFragments(text, slot)
    local out = {}
    local function Add(list) for _, f in ipairs(list or {}) do out[#out + 1] = f end end
    local t = text[slot]
    Add(t.general)
    for _, key in ipairs({ "race", "faction", "place", "time" }) do
        for _, pool in pairs(t[key] or {}) do Add(pool) end
    end
    return out
end

describe("Flavour", function()
    local ns

    local function boot(state)
        ns = wow.boot({ shippedLines = true, before = function(s)
            for k, v in pairs(state or {}) do s[k] = v end
        end })
        ns.Flavour.ResetMemory()
        return ns
    end

    local function render(template, vars)
        return ns.Util.Render(template, ns.Flavour.Vars(vars or ns.Util.NameVars("Nikki-Shifts")))
    end

    -- Random choices: the first call picks the pool, the second the line.
    local function choose(...)
        local picks, i = { ... }, 0
        ns.Flavour.random = function(n)
            i = i + 1
            return math.min(picks[i] or 1, n)
        end
    end

    describe("speaks in your own voice", function()
        it("a dwarf greets like a dwarf", function()
            boot({ race = "Dwarf", faction = "Alliance" })
            choose(1, 3) -- race pool (weight 4 comes first), third line
            assert.are.equal("Good to see ye, Nikki!", render("{greeting}, {name}!"))
        end)

        it("an orc's cheer is the Horde's", function()
            boot({ race = "Orc", faction = "Horde" })
            choose(1, 2)
            assert.are.equal("Lok'tar ogar!", render("{cheer}"))
        end)

        it("a race with no lines of its own uses its faction's and the general ones", function()
            boot({ race = "Vulpera", faction = "Horde" })
            choose(1, 1) -- the first pool is now the faction's
            assert.are.equal("For the Horde!", render("{cheer}"))
        end)

        it("a High Order Skyborne (race 95) speaks as the High Order", function()
            boot({ race = "Skyborne", raceId = 95, faction = "Alliance" })
            choose(1, 1)
            assert.are.equal("For the High Order!", render("{cheer}"))
        end)

        it("a Windshaper Skyborne (race 96) speaks as a Windshaper", function()
            boot({ race = "Skyborne", raceId = 96, faction = "Horde" })
            choose(1, 1)
            assert.are.equal("Winds guide you, Nikki!", render("{greeting}, {name}!"))
        end)

        it("tells the Skyborne apart by faction when the race ID isn't given", function()
            boot()
            assert.are.equal("HighOrder", ns.Flavour.Voice("Skyborne", nil, "Alliance"))
            assert.are.equal("Windshaper", ns.Flavour.Voice("Skyborne", nil, "Horde"))
            assert.is_nil(ns.Flavour.Voice("Skyborne", nil, nil), "neither: general lines, never a guess")
            assert.are.equal("Windshaper", ns.Flavour.Voice("Skyborne", 96, "Alliance"), "the race ID wins")
        end)

        it("also knows the Skyborne by other spellings of the race name", function()
            assert.are.equal("HighOrder", ns.Flavour.Voice("HighOrderSkyborne"))
            assert.are.equal("Windshaper", ns.Flavour.Voice("Windshaper Skyborne"))
            assert.are.equal("Orc", ns.Flavour.Voice("Orc", 2, "Horde"))
        end)

        it("has lines of its own for every Forever race, in every slot", function()
            local races = { "Human", "Dwarf", "NightElf", "Gnome", "Orc", "Scourge", "Tauren", "Troll",
                "HighOrder", "Windshaper" }
            for _, slot in ipairs(ns.FlavourText.SLOTS) do
                for _, race in ipairs(races) do
                    local pool = ns.FlavourText[slot].race[race]
                    assert.is_true(pool ~= nil and #pool >= 2, slot .. " has no lines for " .. race)
                end
            end
        end)

        it("/friendly status says how the game reports your race and whose voice you use", function()
            boot({ race = "Skyborne", raceId = 96, faction = "Horde" })
            _G.SlashCmdList.FRIENDLYFOREVER("status")
            local all = table.concat(wow.printed, "\n")
            assert.is_truthy(all:find("your race: Skyborne (id 96, Horde), speaking as Windshaper", 1, true))
        end)

        it("an unreadable race, class and faction fall back to general lines without errors", function()
            boot()
            _G.UnitRace = function() return wow.secret("Dwarf"), wow.secret("Dwarf") end
            _G.UnitClass = function() error("restricted") end
            _G.UnitFactionGroup = function() return nil end
            choose(1, 1)
            local text = render("{greeting}, {name}! I'm a {myclass}.")
            assert.are.equal("Well met, Nikki! I'm a traveler.", text)
            assert.are.equal(0, #wow.errors)
        end)

        it("blesses by place: out in the wilds it names the zone", function()
            boot({ race = "Human", faction = "Alliance", zone = "Westfall", hour = 14 })
            -- pools: race 4, faction 2, place 2, general 2 -> a roll of 7 is the place pool
            choose(7, 1)
            assert.are.equal("Safe travels through Westfall.", render("{blessing}"))
        end)

        it("blesses by place: in a dungeon", function()
            boot({ race = "Human", faction = "Alliance", inInstance = true, hour = 14 })
            choose(7, 1)
            assert.are.equal("Stay close and stay alive in here.", render("{blessing}"))
        end)

        it("blesses by place: resting in a city or inn", function()
            boot({ race = "Human", faction = "Alliance", resting = true, zone = "Stormwind City", hour = 14 })
            choose(7, 1)
            assert.are.equal("Enjoy the comforts of Stormwind City.", render("{blessing}"))
        end)

        it("blesses by the hour at night", function()
            boot({ race = "Human", faction = "Alliance", hour = 23 })
            -- race 4, faction 2, place 2, time 1, general 2 -> 9 is the time pool
            choose(9, 1)
            assert.are.equal("Rest well tonight.", render("{blessing}"))
        end)
    end)

    describe("plain placeholders", function()
        it("{zone} is where you are, or 'these lands'", function()
            boot({ zone = "Duskwood" })
            assert.are.equal("Duskwood", render("{zone}"))
            boot({ zone = "" })
            assert.are.equal("these lands", render("{zone}"))
        end)

        it("{timeofday} follows the game's clock", function()
            for hour, expected in pairs({ [6] = "morning", [13] = "afternoon", [19] = "evening", [2] = "evening" }) do
                boot({ hour = hour })
                assert.are.equal("Good " .. expected, render("Good {timeofday}"), "hour " .. hour)
            end
        end)

        it("{myclass} is your class, as players read it", function()
            boot({ class = "PRIEST" })
            assert.are.equal("priest", render("{myclass}"))
        end)

        it("{class} is 'friend' unless the caller knows it", function()
            boot()
            assert.are.equal("friend", render("{class}"))
            local vars = ns.Util.NameVars("Nikki-Shifts")
            vars.class = "druid"
            assert.are.equal("druid", render("{class}", vars))
        end)

        it("leaves an unknown placeholder as typed", function()
            boot()
            assert.are.equal("Hi {nickname}", render("Hi {nickname}"))
        end)

        it("uses the same words for a placeholder that appears twice", function()
            boot({ race = "Dwarf" })
            ns.Flavour.random = math.random
            for _ = 1, 20 do
                local text = render("{greeting}|{greeting}")
                local a, b = text:match("^(.-)|(.-)$")
                if a == nil then a, b = text, text end -- "|" is stripped: compare halves
                assert.are.equal(a, b)
            end
        end)

        it("doesn't work anything out for a line without flavour", function()
            boot()
            local asked = 0
            _G.UnitRace = function() asked = asked + 1 end
            render("Hello {name}!")
            assert.are.equal(0, asked)
        end)
    end)

    it("doesn't reuse a fragment until a few others have been used", function()
        boot({ race = "Dwarf", faction = "Alliance" })
        ns.Flavour.WEIGHTS = { race = 1, faction = 0, place = 0, time = 0, general = 0 }
        ns.Flavour.random = function() return 1 end
        local seen = {}
        for i = 1, ns.Flavour.MEMORY do
            local text = render("{greeting}")
            assert.is_nil(seen[text], "repeated '" .. text .. "' on pick " .. i)
            seen[text] = true
        end
    end)

    describe("shipped lines", function()
        before_each(function() boot() end)

        it("(the checker below catches broken joins)", function()
            assert.are.same({ "leftover placeholder" }, Problems("Hi {name}!"))
            assert.are.same({ "double space" }, Problems("Hi  Bob"))
            assert.are.same({ "space before punctuation" }, Problems("Hi Bob !"))
            assert.are.same({ "doubled punctuation" }, Problems("Safe travels.."))
            assert.are.same({ "doubled punctuation" }, Problems("For the Horde!."))
            assert.are.same({}, Problems("Wait... for it."))
            assert.are.same({ "over 255 bytes (256)" }, Problems(string.rep("a", 256)))
        end)

        it("fragments follow their slot's rules", function()
            local text = ns.FlavourText
            local allowed = { zone = true, timeofday = true, myclass = true }
            for _, slot in ipairs(text.SLOTS) do
                for _, f in ipairs(AllFragments(text, slot)) do
                    for key in f:gmatch("{(%a+)}") do
                        assert.is_true(allowed[key], slot .. " fragment uses {" .. key .. "}: " .. f)
                    end
                    if slot == "greeting" or slot == "thanks" then
                        assert.is_nil(f:find("[%.!%?,;:]$"), slot .. " fragment ends in punctuation: " .. f)
                        assert.is_nil(f:find(" for "), slot .. " fragment can't take 'for the': " .. f)
                    elseif slot == "blessing" then
                        assert.is_truthy(f:find("[%.!]$"), "blessing must end a sentence: " .. f)
                    elseif slot == "cheer" then
                        assert.is_truthy(f:find("!$"), "cheer must end in '!': " .. f)
                    end
                    assert.is_nil(f:find("|", 1, true), "no escape codes: " .. f)
                end
            end
        end)

        it("every line reads cleanly with every fragment it can get, at the longest", function()
            local text = ns.FlavourText
            local lineSets = { ns.DefaultMessages, ns.CasualMessages }
            local checked = 0
            for _, set in ipairs(lineSets) do
                for _, msgType in ipairs(ns.Config.TYPES) do
                    for _, line in ipairs(set[msgType]) do
                        local slots = {}
                        for key in line:gmatch("{(%a+)}") do
                            if text[key] then slots[#slots + 1] = key end
                        end
                        -- Each slot's fragments in turn, the others at their longest.
                        local longest = {}
                        for _, slot in ipairs(text.SLOTS) do
                            local best = ""
                            for _, f in ipairs(AllFragments(text, slot)) do
                                local r = f:gsub("{zone}", LONG.zone)
                                if #r > #best then best = r end
                            end
                            longest[slot] = best
                        end
                        local function try(vars)
                            local out = ns.Util.Render(line, vars)
                            local problems = Problems(out or "")
                            assert.are.same({}, problems, msgType .. ": '" .. line .. "' -> '" .. tostring(out) .. "'")
                            checked = checked + 1
                        end
                        local function vars(extra)
                            local v = {}
                            for k, val in pairs(LONG) do v[k] = val end
                            for k, val in pairs(longest) do v[k] = val end
                            v.timeofday = "afternoon"
                            for k, val in pairs(extra or {}) do v[k] = val end
                            return v
                        end
                        try(vars())
                        for _, slot in ipairs(slots) do
                            for _, f in ipairs(AllFragments(text, slot)) do
                                try(vars({ [slot] = (f:gsub("{zone}", LONG.zone)) }))
                            end
                        end
                    end
                end
            end
            assert.is_true(checked > 1000, "checked " .. checked .. " combinations")
        end)

        it("every Buff Back line fits one /say message, at the longest name, spell and words", function()
            local text = ns.FlavourText
            local longest = {}
            for _, slot in ipairs(text.SLOTS) do
                local best = ""
                for _, f in ipairs(AllFragments(text, slot)) do
                    local r = f:gsub("{zone}", LONG.zone)
                    if #r > #best then best = r end
                end
                longest[slot] = best
            end
            local spell = "Power Word: Fortitude" -- the longest buff name a class gives
            for _, set in ipairs({ ns.DefaultMessages, ns.CasualMessages }) do
                for _, line in ipairs(set.buffBack) do
                    local vars = { name = LONG.name, fullname = LONG.fullname, buff = spell, zone = LONG.zone,
                        timeofday = "afternoon", class = LONG.class, myclass = LONG.myclass }
                    for k, v in pairs(longest) do vars[k] = v end
                    local out = ns.Util.Render(line, vars)
                    assert.is_true(#out <= ns.Util.MAX_CHAT_BYTES,
                        ("%q is %d long; a message holds %d"):format(out, #out, ns.Util.MAX_CHAT_BYTES))
                end
            end
        end)

        it("fantasy buff lines never say '{buff} is' (it may be several buffs)", function()
            for _, line in ipairs(ns.DefaultMessages.buff) do
                assert.is_nil(line:find("{buff} is", 1, true), line)
                assert.is_nil(line:find("{buff} was", 1, true), line)
            end
        end)
    end)

    describe("in messages sent", function()
        it("a guild greeting comes out in your voice", function()
            boot({ race = "Orc", faction = "Horde", guildRoster = { "Thrall-Hellscream" } })
            wow.fire("GUILD_ROSTER_UPDATE")
            ns.db.guildLogin.messages = { "{greeting}, {name}! {cheer}" }
            choose(1, 1, 1, 1)
            wow.systemMessage("|Hplayer:Thrall-Hellscream|h[Thrall-Hellscream]|h has come online.")
            wow.advance(10)
            assert.are.same({ "Throm-ka, Thrall! For the Horde!" }, wow.sentTo("GUILD"))
        end)

        it("a guild greeting can name their class, from the roster", function()
            boot({ guildRoster = { "Thrall-Hellscream" } })
            wow.fire("GUILD_ROSTER_UPDATE")
            ns.db.guildLogin.messages = { "Welcome back, mighty {class} {name}!" }
            wow.systemMessage("|Hplayer:Thrall-Hellscream|h[Thrall-Hellscream]|h has come online.")
            wow.advance(10)
            assert.are.same({ "Welcome back, mighty warrior Thrall!" }, wow.sentTo("GUILD"))
        end)

        it("a buff thank-you can name the caster's class", function()
            boot()
            ns.db.buff.messages = { "{thanks}, {class} {name}!" }
            wow.addUnit("target", { name = "Bob", surname = "Stone", class = "DRUID" })
            choose(1, 1)
            wow.gainBuff({ sourceUnit = "target", name = "Mark of the Wild" })
            wow.advance(10)
            wow.keyDown()
            assert.are.same({ "Thank you kindly, druid Bob!" }, wow.sentTo("SAY"))
        end)

        it("/friendly test shows the lines with flavour filled in", function()
            boot()
            _G.SlashCmdList.FRIENDLYFOREVER("test")
            for _, line in ipairs(wow.printed) do
                assert.is_nil(line:find("{", 1, true), line)
            end
        end)
    end)
end)
