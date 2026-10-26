-- Buff back: favours owed, the buff chosen for each, and the secure button
-- that casts it when pressed.
local wow = require("spec.support.wow")

-- Mark of the Wild and Thorns, top ranks and rank 1.
local MOTW, MOTW_1, GIFT, THORNS, THORNS_1 = 9885, 1126, 21850, 9910, 467
local INTELLECT = 10157

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

local function printedHas(fragment)
    for _, line in ipairs(wow.printed) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

describe("Buff back", function()
    local ns, button

    -- A druid who knows Mark of the Wild and Thorns.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = opts.class or "DRUID"
            state.knownSpells = opts.known or { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
            if opts.before then opts.before(state) end
        end })
        ns.db.buff.messages = { "Thanks {name}" }
        button = ns.BuffButton.Frame()
    end

    -- Bob Stone, a stranger, as a unit the game names (a nameplate).
    local function stranger(token, spec)
        spec = spec or {}
        spec.name, spec.surname = spec.name or "Bob", spec.surname or "Stone"
        spec.class = spec.class or "WARRIOR"
        spec.id = spec.name .. "-" .. spec.surname
        wow.addUnit(token or "nameplate1", spec)
    end

    local function buffedBy(token)
        wow.gainBuff({ sourceUnit = token or "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    before_each(function() boot() end)

    describe("buff data", function()
        it("lists the buffs you know, in your class's order", function()
            local names = {}
            for _, buff in ipairs(ns.BuffData.Mine()) do names[#names + 1] = ns.BuffData.SpellName(buff) end
            assert.are.same({ "Mark of the Wild", "Thorns" }, names)
        end)

        it("knows none for a class without buffs, or an unreadable class", function()
            boot({ class = "ROGUE" })
            assert.are.same({}, ns.BuffData.Mine())
            _G.UnitClass = function() return wow.secret("Druid"), wow.secret("DRUID") end
            assert.are.same({}, ns.BuffData.Mine())
        end)

        it("tells our casts and other buffs apart by spell ID", function()
            assert.are.equal("motw", ns.BuffData.ForCast(MOTW).key)
            assert.is_nil(ns.BuffData.ForCast(GIFT), "a group version is never our single cast")
            assert.are.equal("motw", ns.BuffData.ForAura(GIFT).key)
            assert.are.equal("intellect", ns.BuffData.ForAura(12176).key, "a scroll counts as Intellect")
        end)

        it("doesn't offer mana buffs to classes without mana", function()
            local intellect = ns.BuffData.CLASSES.MAGE[1]
            assert.is_false(ns.BuffData.Useful(intellect, "WARRIOR"))
            assert.is_true(ns.BuffData.Useful(intellect, "PRIEST"))
            assert.is_true(ns.BuffData.Useful(intellect, nil), "unknown class: offered")
        end)
    end)

    describe("favours owed", function()
        it("someone outside your group who buffs you is owed your buff", function()
            stranger()
            buffedBy()
            local offer = ns.Offers.Current()
            assert.are.equal("Bob-Stone", offer.name)
            assert.are.equal("Mark of the Wild", offer.spell)
        end)

        it("even with Buff Thanks off", function()
            ns.db.buff.enabled = false
            stranger()
            buffedBy()
            assert.are.equal("Bob-Stone", ns.Offers.Current().name)
            wow.advance(10)
            wow.keyDown()
            assert.are.equal(0, #wow.sent)
        end)

        it("not when Buff Back's offer is off", function()
            ns.db.buffBack.enabled = false
            stranger()
            buffedBy()
            assert.is_nil(ns.Offers.Current())
            assert.is_false(button:IsShown())
        end)

        it("not to someone the game can't name, or someone on your ignore list", function()
            wow.gainBuff({ name = "Arcane Intellect", spellId = INTELLECT })
            ns.Ignore.Add("Bob-Stone")
            stranger()
            buffedBy()
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("gives Thorns to someone who already wears your Mark (or the Gift)", function()
            stranger("nameplate1", { auras = { GIFT } })
            buffedBy()
            assert.are.equal("Thorns", ns.Offers.Current().spell)
        end)

        it("offers nothing to someone who wears all your buffs", function()
            stranger("nameplate1", { auras = { MOTW, THORNS } })
            buffedBy()
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.is_truthy(why:find("already have your buffs", 1, true))
        end)

        it("a mage doesn't offer Intellect to a warrior", function()
            boot({ class = "MAGE", known = { [1459] = true } })
            stranger("nameplate1", { class = "WARRIOR" })
            buffedBy()
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.is_truthy(why:find("none of your buffs suit them", 1, true))
        end)

        it("waits while they're dead", function()
            stranger("nameplate1", { dead = true })
            buffedBy()
            assert.is_nil(ns.Offers.Current())
            wow.state.units.nameplate1.dead = false
            assert.is_table(ns.Offers.Current())
        end)

        it("won't flag you for PvP: no offer to a flagged player unless you're flagged too", function()
            stranger("nameplate1", { pvp = true })
            buffedBy()
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.is_truthy(why:find("PvP", 1, true))
            wow.state.pvp = true
            assert.is_table(ns.Offers.Current())
        end)

        it("doesn't trust a PvP reading older than a minute", function()
            stranger("nameplate1")
            buffedBy()
            wow.state.units.nameplate1 = nil
            assert.is_table(ns.Offers.Current(), "read unflagged just now")
            wow.advance(ns.Offers.PVP_READING_FRESH + 1)
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.is_truthy(why:find("can't tell", 1, true))
            stranger("target") -- you target them: a fresh reading
            assert.is_table(ns.Offers.Current())
        end)

        it("still refuses a flagged player after their nameplate is gone", function()
            stranger("nameplate1", { pvp = true })
            buffedBy()
            wow.state.units.nameplate1 = nil
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.is_truthy(why:find("flagged for PvP", 1, true))
        end)

        it("refuses when their flag was never readable, until it is", function()
            stranger("nameplate1")
            _G.UnitIsPVP = function(unit)
                if unit == "player" then return false end
                return wow.secret(false)
            end
            buffedBy()
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.is_truthy(why:find("can't tell if they're flagged", 1, true))
            _G.UnitIsPVP = function() return false end
            assert.is_table(ns.Offers.Current(), "read while their unit is known")
        end)

        it("doesn't read a unit token that now belongs to someone else", function()
            stranger("nameplate1", { auras = { MOTW, THORNS }, class = "WARRIOR" })
            buffedBy()
            wow.addUnit("nameplate1", { name = "Ann", surname = "Vale", dead = true, auras = { MOTW, THORNS } })
            local offer = ns.Offers.Current()
            assert.are.equal("Bob-Stone", offer.name, "Ann's state says nothing about Bob")
            assert.are.equal("Mark of the Wild", offer.spell)
            assert.is_nil(offer.unit)
        end)

        it("treats buffs hidden in a fight as not worn", function()
            stranger("nameplate1", { auras = { MOTW } })
            buffedBy()
            wow.state.unitsRestricted = true
            assert.are.equal("Mark of the Wild", ns.Offers.Current().spell)
        end)

        it("offers the newest favour first", function()
            stranger("nameplate1")
            buffedBy("nameplate1")
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            buffedBy("nameplate2")
            assert.are.equal("Ann-Vale", ns.Offers.Current().name)
        end)

        it("lets a favour go after the time set, noting it in the ledger", function()
            stranger()
            buffedBy()
            wow.advance(ns.db.buffBack.owedMinutes * 60 + 1)
            assert.is_nil(ns.Offers.Current())
            assert.are.equal("the time to return it ran out", ns.db.ledger.entries[1].returnNote)
        end)

        it("keeps at most MAX favours, the oldest going first", function()
            for i = 1, ns.Offers.MAX + 3 do
                wow.addUnit("nameplate" .. i, { name = "Pal" .. string.char(96 + i), surname = "Stone", class = "MAGE" })
                buffedBy("nameplate" .. i)
            end
            assert.are.equal(ns.Offers.MAX, ns.Offers.Count())
        end)
    end)

    describe("the macro", function()
        local MACRO = "/cleartarget\n/targetexact Bob Stone\n/cast [help,nodead] Mark of the Wild\n"

        it("clears your target, targets them by exact name, casts only on a friendly living target", function()
            assert.are.equal(MACRO .. "/cleartarget",
                ns.BuffButton.BuildCastMacro("Bob-Stone", "Mark of the Wild", nil, false))
        end)

        it("gives you your target back when you had one", function()
            assert.are.equal(MACRO .. "/targetlasttarget",
                ns.BuffButton.BuildCastMacro("Bob-Stone", "Mark of the Wild", nil, true))
        end)

        it("says the line after the cast", function()
            assert.are.equal(MACRO .. "/s Here you go!\n/targetlasttarget",
                ns.BuffButton.BuildCastMacro("Bob-Stone", "Mark of the Wild", "Here you go!", true))
        end)

        it("refuses any part that could end its line or start a command", function()
            local build = ns.BuffButton.BuildCastMacro
            assert.is_nil(build("Bob-Stone", "Mark\n/cast Pyroblast", nil, false))
            assert.is_nil(build("Bob-Stone", "Mark of the Wild", "hi\n/dance", false))
            assert.is_nil(build("Bob-Stone", "Mark of the Wild", "/yell boo", false))
            assert.is_nil(build("Bob-Stone", "Mark of the Wild", "a |cffff0000red|r line", false))
            assert.is_nil(build("Bob-Stone", "", nil, false))
        end)

        it("refuses macro option syntax in a name or spell, but allows it in the line", function()
            local build = ns.BuffButton.BuildCastMacro
            assert.is_nil(build("Bob-Stone", "Mark of the Wild; Pyroblast", nil, false))
            assert.is_nil(build("Bob-Stone", "[harm] Mark", nil, false))
            assert.is_truthy(build("Bob-Stone", "Mark of the Wild", "Well met; safe travels [friend]", false))
        end)

        it("refuses a macro longer than 255 characters", function()
            assert.is_nil(ns.BuffButton.BuildCastMacro("Bob-Stone", "Mark of the Wild", string.rep("x", 250), false))
        end)
    end)

    describe("the button", function()
        local A = function() return ns.BuffButton.SECURE_ATTRIBUTE end

        it("is hidden and empty while nobody is owed", function()
            assert.is_false(button:IsShown())
            assert.is_nil(macro())
        end)

        it("shows the favour and holds its macro for the left button, with any modifier keys", function()
            stranger()
            buffedBy()
            assert.is_true(button:IsShown())
            assert.are.equal("*type1", A().leftButtonActionType)
            assert.are.equal("macro", button:GetAttribute("*type1"))
            assert.is_truthy(macro():find("/targetexact Bob Stone", 1, true))
            assert.is_nil(button:GetAttribute("type"), "no action for other mouse buttons")
            assert.are.equal("Bob Stone", button.title:GetText())
        end)

        it("casts on them when pressed, gives your target back, and marks the favour returned", function()
            stranger()
            buffedBy()
            wow.addUnit("target", { name = "Wolf", isPlayer = false, hostile = true, id = "wolf" })
            wow.fire("PLAYER_TARGET_CHANGED")
            wow.press(button)
            assert.are.same({ spell = "Mark of the Wild", id = MOTW, target = "Bob-Stone" }, wow.casts[1])
            assert.are.equal("wolf", wow.state.units.target.id, "your target is back")
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
            assert.are.equal(0, ns.Offers.Count())
            assert.are.equal("Returned Mark of the Wild to Bob Stone.", button.result:GetText())
            wow.advance(ns.BuffButton.RESULT_SHOWN_SECONDS + ns.BuffButton.RECHECK_SECONDS)
            assert.is_false(button:IsShown())
        end)

        it("leaves you with no target when you had none", function()
            stranger()
            buffedBy()
            wow.press(button)
            assert.are.equal(1, #wow.casts)
            assert.is_nil(wow.state.units.target)
        end)

        it("works with a modifier held (a Shift+key binding)", function()
            stranger()
            buffedBy()
            wow.press(button, "LeftButton", { shift = true })
            assert.are.equal(1, #wow.casts)
        end)

        it("acts once per press, on key up when the game is set to cast on key up", function()
            wow.state.cvars.ActionButtonUseKeyDown = "0"
            stranger()
            buffedBy()
            wow.press(button)
            assert.are.equal(1, #wow.casts)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
        end)

        it("has the key binding for its left button", function()
            local xml = wow.readFile("Bindings.xml")
            assert.is_truthy(xml:find('name="CLICK ' .. ns.BuffButton.FRAME_NAME .. ':LeftButton"', 1, true))
            assert.are.equal("Friendly Forever: buff back",
                _G["BINDING_NAME_CLICK " .. ns.BuffButton.FRAME_NAME .. ":LeftButton"])
        end)

        it("never buffs someone whose name only starts the same", function()
            wow.addUnit("nameplate5", { name = "Bob", surname = "Stonewall", id = "Bob-Stonewall" })
            stranger("nameplate9")
            buffedBy("nameplate9")
            wow.state.units.nameplate9 = nil -- Bob Stone walks off; Bob Stonewall is still near
            wow.press(button)
            assert.are.equal(0, #wow.casts, "nothing cast")
            assert.is_nil(ns.db.ledger.entries[1].returned)
        end)

        it("casts nothing, and gives your target back, when they can't be found", function()
            wow.state.targetNameForm = "hyphen" -- if the game wanted another spelling
            stranger()
            buffedBy()
            wow.addUnit("target", { name = "Ann", surname = "Vale", id = "Ann-Vale" })
            wow.fire("PLAYER_TARGET_CHANGED")
            wow.press(button)
            assert.are.equal(0, #wow.casts, "not on Ann, not on you")
            assert.are.equal("Ann-Vale", wow.state.units.target.id)
            assert.are.equal(1, ns.Offers.Count(), "still owed")
        end)

        it("doesn't count it returned when the game says the cast went to someone else", function()
            stranger()
            buffedBy()
            -- The game reports another name for the cast (a same-named player elsewhere, say).
            wow.state.sentTargetForm = "full"
            local realCast = wow.press
            realCast(button)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned, "Bob Stone: right person")
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            buffedBy("nameplate2")
            ns.BuffButton.OnSpellcastSent("player", "Cid Moon", nil, MOTW) -- before a press: ignored
            wow.press(button)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[2].returned)
        end)

        it("says so when a cast lands but no favour was waiting any more", function()
            stranger()
            buffedBy()
            -- The favour is let go between the cast going out and landing.
            local spoiler = CreateFrame("Frame")
            spoiler:RegisterEvent("UNIT_SPELLCAST_SENT")
            spoiler:SetScript("OnEvent", function() ns.Offers.LetGo("Bob-Stone") end)
            wow.press(button)
            assert.are.equal(1, #wow.casts)
            assert.are.equal(0, ns.Ledger.Summary().returned)
            assert.are.equal("Cast Mark of the Wild on Bob Stone (no favour was waiting).", button.result:GetText())
        end)

        it("counts it returned only when the game says who the cast reached", function()
            wow.state.sentTargetForm = "none"
            stranger()
            buffedBy()
            wow.press(button)
            assert.are.equal(1, #wow.casts)
            assert.is_nil(ns.db.ledger.entries[1].returned)
            assert.are.equal("Cast Mark of the Wild, but the game didn't say it reached Bob Stone.",
                button.result:GetText())
        end)

        it("reports a press that got no answer (they couldn't be found)", function()
            stranger("nameplate1")
            buffedBy("nameplate1")
            wow.state.units.nameplate1 = nil -- gone from sight
            wow.press(button)
            assert.are.equal(0, #wow.casts)
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 0.2)
            assert.is_true(printedHas("No answer: couldn't find Bob Stone (out of sight?)."))
        end)

        it("doesn't credit a favour with a cast made some other way after a press that cast nothing", function()
            wow.state.sentTargetForm = "none"
            stranger("nameplate1")
            buffedBy("nameplate1")
            wow.state.units.nameplate1 = nil
            wow.press(button) -- finds nobody, casts nothing
            wow.fire("UNIT_SPELLCAST_SENT", "player", "", "manual", MOTW)
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "manual", MOTW) -- your own cast, from your bar
            assert.is_nil(ns.db.ledger.entries[1].returned)
        end)

        it("says why the game refused a cast, and keeps the favour", function()
            wow.state.castFailures["Bob-Stone"] = "Out of range."
            stranger()
            buffedBy()
            wow.press(button)
            assert.is_true(printedHas("Couldn't buff Bob Stone: Out of range."))
            assert.are.equal(1, ns.Offers.Count())
            assert.is_nil(ns.db.ledger.entries[1].returned)
        end)

        it("ignores casts and errors that aren't the answer to a press", function()
            stranger()
            buffedBy()
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "x", MOTW)
            wow.uiError("Out of range.")
            assert.are.equal(1, ns.Offers.Count())
            wow.press(button)
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "y", THORNS)
            assert.are.equal(1, ns.Ledger.Summary().returned, "only the press's own cast counted")
        end)

        it("right-click lets the favour go", function()
            stranger()
            buffedBy()
            wow.press(button, "RightButton")
            assert.are.equal(0, #wow.casts)
            assert.are.equal(0, ns.Offers.Count())
            assert.are.equal("you let it go", ns.db.ledger.entries[1].returnNote)
        end)

        it("empties itself as a fight starts, so nothing armed outside it is cast in it", function()
            stranger("nameplate1")
            buffedBy("nameplate1")
            wow.enterCombat()
            assert.is_nil(macro())
            assert.is_false(button:IsShown())
            wow.addUnit("target", { name = "Wolf", isPlayer = false, hostile = true, id = "wolf" })
            wow.press(button)
            assert.are.equal(0, #wow.casts)
            assert.are.equal("wolf", wow.state.units.target.id, "your fight target is left alone")
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            buffedBy("nameplate2") -- would error if it touched the button in combat
            wow.leaveCombat()
            assert.is_truthy(macro():find("/targetexact Ann Vale", 1, true))
            assert.are.same({}, wow.errors)
        end)

        it("only rewrites the button when its macro changes", function()
            stranger()
            buffedBy()
            local writes = 0
            local set = button.SetAttribute
            button.SetAttribute = function(self, k, v) writes = writes + 1; return set(self, k, v) end
            wow.advance(ns.BuffButton.RECHECK_SECONDS * 3)
            wow.fire("PLAYER_TARGET_CHANGED")
            assert.are.equal(0, writes)
        end)

        it("says a line as you cast, when switched on", function()
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "For you, {name}: {buff}!" }
            stranger()
            buffedBy()
            assert.is_truthy(macro():find("\n/s For you, Bob: Mark of the Wild!\n", 1, true))
            wow.press(button)
            assert.are.same({ "For you, Bob: Mark of the Wild!" }, wow.sentTo("SAY"))
        end)

        it("doesn't say the line while snoozed or AFK", function()
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "For you, {name}!" }
            stranger()
            buffedBy()
            ns.Announcer.Snooze(15)
            wow.press(button)
            assert.are.same({}, wow.sentTo("SAY"))
            assert.are.equal(1, #wow.casts, "the cast still goes")
            ns.Announcer.Snooze(nil)
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            buffedBy("nameplate2")
            wow.state.afk = true
            wow.press(button)
            assert.are.same({}, wow.sentTo("SAY"))
        end)

        it("keeps the same line while re-arming, so the rotation isn't used up", function()
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "One {name}", "Two {name}" }
            stranger()
            buffedBy()
            local first = macro()
            wow.fire("PLAYER_TARGET_CHANGED")
            wow.fire("PLAYER_TARGET_CHANGED")
            assert.are.equal(first, macro())
        end)

        it("skips a line that starts a command or won't fit, and casts anyway", function()
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "/yell {name}", string.rep("long ", 60) }
            stranger()
            buffedBy()
            assert.is_nil(macro():find("/s ", 1, true))
        end)

        it("empties when the addon is switched off, and when the favour's player is ignored", function()
            stranger()
            buffedBy()
            slash("off")
            assert.is_nil(macro())
            assert.is_false(button:IsShown())
            slash("on")
            assert.is_truthy(macro())
            slash("ignore Bob Stone")
            assert.is_nil(macro())
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("/friendly buffback says what is armed and why not", function()
            slash("buffback")
            assert.is_true(printedHas("not armed: nobody is owed a buff"))
            assert.is_true(printedHas("your buffs: Mark of the Wild, Thorns"))
            stranger()
            buffedBy()
            slash("buffback")
            assert.is_true(printedHas("macro: /cleartarget ; /targetexact Bob Stone ; /cast [help,nodead] Mark of the Wild ; /cleartarget"))
        end)

        it("notices newly learned buffs", function()
            boot({ known = { [MOTW_1] = true } })
            stranger("nameplate1", { auras = { MOTW } })
            buffedBy()
            assert.is_nil(ns.Offers.Current(), "only the Mark known, and they have it")
            wow.state.knownSpells[THORNS_1] = true
            wow.fire("SPELLS_CHANGED")
            assert.are.equal("Thorns", ns.Offers.Current().spell)
        end)
    end)

    describe("starting up mid-fight (a /reload in combat)", function()
        it("waits to make the button until the fight ends, and everything else still starts", function()
            ns = wow.boot({ before = function(state)
                state.class = "DRUID"
                state.knownSpells = { [MOTW] = true }
                state.inCombat = true
            end })
            assert.are.same({}, wow.errors)
            assert.is_nil(ns.BuffButton.Frame())
            ns.db.guildJoin.messages = { "Welcome {name}" }
            wow.systemMessage("Ann-Vale has joined the guild.")
            wow.advance(10)
            assert.are.same({ "Welcome Ann" }, wow.sentTo("GUILD"), "the rest of the addon started")
            stranger()
            buffedBy()
            wow.leaveCombat()
            button = ns.BuffButton.Frame()
            assert.is_truthy(button)
            assert.is_truthy(macro():find("/targetexact Bob Stone", 1, true))
        end)
    end)

    describe("chaos (red tests)", function()
        -- A seeded storm of everything that can happen around the button, in
        -- random order: it must never error, never touch the button in combat,
        -- and keep its own bookkeeping consistent.
        it("survives a random storm of events, presses, fights and settings changes", function()
            math.randomseed(20261026)
            ns.db.buffBack.sayLine = true
            local names = { "Bob", "Ann", "Cid", "Dot", "Eve", "Fay" }
            local actions = {
                function() -- someone buffs you, maybe with a stale or missing token
                    local token = "nameplate" .. math.random(1, 8)
                    local name = names[math.random(#names)]
                    wow.addUnit(token, { name = name, surname = "Stone", id = name .. "-Stone",
                        class = ({ "MAGE", "WARRIOR", "PRIEST" })[math.random(3)], pvp = math.random() < 0.2,
                        dead = math.random() < 0.1, auras = math.random() < 0.3 and { MOTW } or nil })
                    wow.gainBuff({ sourceUnit = math.random() < 0.8 and token or nil, name = "Arcane Intellect",
                        spellId = INTELLECT })
                end,
                function() wow.state.units["nameplate" .. math.random(1, 8)] = nil end,
                function() wow.press(button, math.random() < 0.8 and "LeftButton" or "RightButton",
                    math.random() < 0.3 and { shift = true } or nil) end,
                function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                function() wow.advance(math.random() * 20) end,
                function() wow.fire("PLAYER_TARGET_CHANGED") end,
                function() wow.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "x", ({ MOTW, THORNS, 12345 })[math.random(3)]) end,
                function() wow.uiError("Out of range.") end,
                function() wow.state.sentTargetForm = ({ "first", "full", "none" })[math.random(3)] end,
                function() wow.state.targetNameForm = math.random() < 0.8 and "space" or "hyphen" end,
                function() wow.state.castFailures["Bob-Stone"] = math.random() < 0.5 and "Out of range." or nil end,
                function() slash(({ "off", "on", "snooze 1", "snooze off", "buffback", "ledger" })[math.random(6)]) end,
                function() ns.db.buffBack.enabled = math.random() < 0.8 end,
                function() wow.state.pvp = math.random() < 0.2 end,
                function() wow.state.unitsRestricted = math.random() < 0.2 end,
                function() wow.fire("SPELLS_CHANGED") end,
            }
            for _ = 1, 3000 do
                actions[math.random(#actions)]()
                if wow.state.inCombat then
                    assert.is_nil(macro(), "the button holds nothing in a fight")
                end
                assert.is_true(ns.Offers.Count() <= ns.Offers.MAX)
            end
            assert.are.same({}, wow.errors)
            local s = ns.Ledger.Summary()
            assert.is_true(s.returned <= s.received, "never more returned than received")
            -- The storm really exercised the button, not just the edges.
            assert.is_true(s.received > 50, "favours received: " .. s.received)
            assert.is_true(#wow.casts > 10, "casts: " .. #wow.casts)
            assert.is_true(s.returned > 0, "favours returned: " .. s.returned)
        end)

        it("keeps working when its settings are damaged mid-session, and a reload heals them", function()
            stranger()
            buffedBy()
            ns.db.buffBack.messages = "not a list"
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.owedMinutes = "ten"
            wow.fire("PLAYER_TARGET_CHANGED")
            wow.advance(30)
            wow.press(button) -- nothing here may throw out of an event or a press
            wow.printed = {}
            slash("status")
            assert.is_true(#wow.printed > 0, "the addon still answers")
            local saved = _G.FriendlyForeverDB
            boot({ db = saved })
            assert.are.equal(ns.Config.NUM_MESSAGES, #ns.db.buffBack.messages)
            assert.are.equal(10, ns.db.buffBack.owedMinutes)
            stranger()
            buffedBy()
            wow.press(button)
            assert.are.equal("Mark of the Wild", wow.casts[#wow.casts].spell, "working again after the reload")
        end)
    end)

    describe("moving", function()
        it("unlocks to drag (casting nothing meanwhile) and saves where it's locked", function()
            stranger()
            buffedBy()
            slash("move")
            assert.is_true(ns.db.buffBack.unlocked)
            assert.is_nil(macro(), "an unlocked button casts nothing")
            assert.is_true(button:IsShown())
            button:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 100.4, -50.6)
            slash("move")
            assert.are.same({ point = "TOPLEFT", x = 100, y = -51 }, ns.db.buffBack.position)
            assert.is_truthy(macro())
        end)

        it("can't be unlocked in combat", function()
            wow.enterCombat()
            slash("move")
            assert.is_false(ns.db.buffBack.unlocked)
            assert.is_true(printedHas("can't be moved in combat"))
        end)

        it("repairs a damaged saved position", function()
            boot({ db = { buffBack = { position = { point = "NOWHERE", x = 1 } } } })
            assert.are.same({ point = "CENTER", x = 0, y = -180 }, ns.db.buffBack.position)
            boot({ db = { buffBack = { position = { point = "TOP", x = 1 / 0, y = "up" } } } })
            assert.are.same({ point = "TOP", x = ns.Config.MAX_OFFSET, y = 0 }, ns.db.buffBack.position)
        end)

        it("isn't moved by importing someone's settings, or by resetting the tab", function()
            ns.db.buffBack.position = { point = "TOP", x = 5, y = 5 }
            local line = ns.Profiles.Export()
            assert.is_nil(ns.Serialize.Decode(line).settings.buffBack.position)
            boot()
            ns.db.buffBack.position = { point = "LEFT", x = 1, y = 2 }
            ns.Profiles.Import(line)
            assert.are.same({ point = "LEFT", x = 1, y = 2 }, ns.db.buffBack.position)
            ns.ResetType("buffBack")
            assert.are.same({ point = "LEFT", x = 1, y = 2 }, ns.db.buffBack.position)
        end)
    end)

    describe("the ledger", function()
        it("counts favours returned, and gives titles for them", function()
            for _ = 1, 10 do
                ns.Ledger.Returned(ns.Ledger.Received("Bob-Stone", "Thorns"), "Mark of the Wild")
            end
            assert.are.same({ title = "Courteous", nextTitle = "Well-Mannered", returnsToNext = 15 }, ns.Ledger.Title())
            assert.is_truthy(ns.LedgerSummaryText():find("returned 10", 1, true))
            assert.is_truthy(ns.Ledger.Lines(1)[1]:find("returned Mark of the Wild", 1, true))
        end)

        it("counts a favour returned once", function()
            local entry = ns.Ledger.Received("Bob-Stone", "Thorns")
            ns.Ledger.Returned(entry, "Mark of the Wild")
            ns.Ledger.Returned(entry, "Thorns")
            assert.are.equal(1, ns.Ledger.Summary().returned)
        end)

        it("has no title before the first, and none past the last", function()
            assert.are.same({ nextTitle = "Courteous", returnsToNext = 10 }, ns.Ledger.Title())
            ns.db.ledger.totals.returned = 5000
            assert.are.same({ title = "Friend to All Azeroth" }, ns.Ledger.Title())
        end)

        it("their buff back after you returned theirs isn't a new favour (no endless trading)", function()
            ns.db.buff.enabled = false -- no thank-you waiting to merge the buffs into one favour
            stranger()
            buffedBy()
            wow.press(button)
            wow.advance(10)
            buffedBy() -- they answer your buff
            assert.are.equal(0, ns.Offers.Count())
            assert.are.equal("it answered your buff to them", ns.db.ledger.entries[2].returnNote)
            wow.advance(ns.Offers.RETURNED_RECENTLY + 1)
            buffedBy()
            assert.are.equal(1, ns.Offers.Count(), "much later, it's a favour again")
        end)
    end)

    describe("options", function()
        it("the Buff Back tab hides delay and repeat, and shows its own settings", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            assert.is_false(w.steppers.delay.box:IsShown())
            assert.is_false(w.steppers.repeatCooldown.box:IsShown())
            assert.is_true(w.sayLine:IsShown())
            assert.is_true(w.steppers.owedMinutes.box:IsShown())
            assert.are.equal("Offer to buff back players who buff me", w.enabled.label:GetText())
            w.sayLine:SetChecked(true)
            wow.run(w.sayLine, "OnClick")
            assert.is_true(ns.db.buffBack.sayLine)
            wow.run(w.tabs.guildLogin, "OnClick")
            assert.is_true(w.steppers.delay.box:IsShown())
            assert.is_false(w.sayLine:IsShown())
        end)
    end)
end)
