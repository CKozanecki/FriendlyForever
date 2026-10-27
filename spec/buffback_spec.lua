-- Spec: #27, #57
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
            assert.are.equal(0, ns.Offers.Count(), "not even collected")
            assert.is_nil(ns.Offers.Current())
            assert.is_false(button:IsShown())
        end)

        it("empties as soon as Buff Back is switched off with a favour owed", function()
            stranger()
            buffedBy()
            assert.is_truthy(macro())
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            w.enabled:SetChecked(false)
            wow.run(w.enabled, "OnClick")
            assert.is_nil(macro())
            assert.is_false(button:IsShown())
            wow.press(button)
            assert.are.equal(0, #wow.casts)
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

        it("never trusts an earlier PvP reading: offers only while the game shows them", function()
            stranger("nameplate1")
            buffedBy()
            assert.is_table(ns.Offers.Current(), "shown, and not flagged")
            wow.state.units.nameplate1 = nil
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer, "they may have flagged since")
            assert.is_truthy(why:find("can't see whether", 1, true))
            stranger("target") -- you target them: the game shows them again
            assert.is_table(ns.Offers.Current())
        end)

        it("refuses when any unit showing them says they're flagged", function()
            stranger("nameplate1")
            stranger("nameplate2", { pvp = true }) -- the same player, read differently
            buffedBy("nameplate1")
            assert.is_nil(ns.Offers.Current())
            wow.press(button)
            assert.are.equal(0, #wow.casts)
        end)

        it("re-arms when a nameplate appears", function()
            stranger("nameplate1")
            buffedBy()
            wow.state.units.nameplate1 = nil
            wow.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
            wow.advance(0) -- on the next frame
            assert.is_nil(macro())
            stranger("nameplate3")
            wow.fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
            wow.advance(0) -- on the next frame
            assert.is_truthy(macro())
        end)

        it("re-arms once for many nameplate events in a frame, and not at all while nobody is owed", function()
            local reads = 0
            local realName = _G.UnitName
            finally(function() _G.UnitName = realName end)
            _G.UnitName = function(...) reads = reads + 1 return realName(...) end
            for i = 1, 100 do wow.fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. (i % 40 + 1)) end
            wow.advance(0)
            assert.are.equal(0, reads, "nobody owed: nothing read")
            stranger()
            buffedBy()
            reads = 0
            for i = 1, 100 do wow.fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. (i % 40 + 1)) end
            wow.advance(0)
            assert.is_true(reads <= 2 * (3 + ns.Offers.MAX_NAMEPLATES), "one re-arm, not a hundred: " .. reads)
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
            assert.is_truthy(why:find("can't see whether they're flagged", 1, true))
            _G.UnitIsPVP = function() return false end
            assert.is_table(ns.Offers.Current(), "read while their unit is known")
        end)

        it("re-reads the PvP flag when they move to another nameplate, and never buffs them flagged", function()
            stranger("nameplate1")
            buffedBy("nameplate1")                                         -- read unflagged
            wow.advance(20)
            stranger("nameplate1", { name = "Ann", surname = "Vale" })     -- plates reshuffle
            stranger("nameplate4", { pvp = true })                         -- Bob, now flagged
            wow.press(button)
            assert.are.equal(0, #wow.casts)
            assert.is_truthy(select(2, ns.Offers.Current()):find("flagged for PvP", 1, true))
        end)

        it("one favour per player, however often they buff you", function()
            ns.db.buff.enabled = false
            stranger()
            buffedBy()
            wow.advance(60)
            buffedBy()
            assert.are.equal(1, ns.Offers.Count())
        end)

        it("never offers a self-cast buff (Battle Shout) or a party-only one (Salvation) to a stranger", function()
            boot({ class = "WARRIOR", known = { [6673] = true } })
            stranger()
            buffedBy()
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.is_truthy(why:find("none of your buffs suit them", 1, true))
            wow.SPELL_NAMES[1038] = "Blessing of Salvation"
            finally(function() wow.SPELL_NAMES[1038] = nil end)
            boot({ class = "PALADIN", known = { [1038] = true } })
            stranger()
            buffedBy()
            assert.is_nil(ns.Offers.Current(), "Salvation would cut a tank's threat")
        end)

        it("can't tell what someone wears when the whole aura, or its spell ID, is secret", function()
            local real = _G.C_UnitAuras.GetAuraDataByIndex
            finally(function() _G.C_UnitAuras.GetAuraDataByIndex = real end)
            local motw = ns.BuffData.CLASSES.DRUID[1]
            _G.C_UnitAuras.GetAuraDataByIndex = function() return wow.secret({ spellId = MOTW }) end
            assert.is_nil(ns.Offers.Wears("nameplate1", motw))
            _G.C_UnitAuras.GetAuraDataByIndex = function(_, i)
                if i == 1 then return { spellId = wow.secret(MOTW) } end
            end
            assert.is_nil(ns.Offers.Wears("nameplate1", motw))
        end)

        it("doesn't read a unit token that now belongs to someone else", function()
            stranger("nameplate1", { auras = { MOTW, THORNS }, class = "WARRIOR" })
            buffedBy()
            wow.addUnit("nameplate1", { name = "Ann", surname = "Vale", dead = true, auras = { MOTW, THORNS } })
            wow.state.pvp = true -- you're flagged: no need to see Bob to offer
            local offer = ns.Offers.Current()
            assert.are.equal("Bob-Stone", offer.name, "Ann's state says nothing about Bob")
            assert.are.equal("Mark of the Wild", offer.spell)
            assert.is_nil(offer.unit)
        end)

        it("treats buffs hidden in a fight as not worn", function()
            stranger("nameplate1", { auras = { MOTW } })
            buffedBy()
            local real = _G.C_UnitAuras.GetAuraDataByIndex
            finally(function() _G.C_UnitAuras.GetAuraDataByIndex = real end)
            _G.C_UnitAuras.GetAuraDataByIndex = function() return wow.secret({ spellId = MOTW }) end
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
                ns.BuffButton.BuildCastMacro("Bob-Stone", "Mark of the Wild", false))
        end)

        it("gives you your target back when you had one", function()
            assert.are.equal(MACRO .. "/targetlasttarget",
                ns.BuffButton.BuildCastMacro("Bob-Stone", "Mark of the Wild", true))
        end)

        it("refuses any part that could end its line or start a command", function()
            local build = ns.BuffButton.BuildCastMacro
            assert.is_nil(build("Bob-Stone", "Mark\n/cast Pyroblast", false))
            assert.is_nil(build("Bob\n/dance-Stone", "Mark of the Wild", false))
            assert.is_nil(build("Bob-Stone", "/yell boo", false))
            assert.is_nil(build("Bob-Stone", "a |cffff0000red|r spell", false))
            assert.is_nil(build("Bob-Stone", "", false))
        end)

        it("refuses macro option syntax in a name or spell", function()
            local build = ns.BuffButton.BuildCastMacro
            assert.is_nil(build("Bob-Stone", "Mark of the Wild; Pyroblast", false))
            assert.is_nil(build("Bob-Stone", "[harm] Mark", false))
            assert.is_nil(build("Bob[x]-Stone", "Mark of the Wild", false))
        end)

        it("refuses a macro longer than 255 characters", function()
            assert.is_nil(ns.BuffButton.BuildCastMacro("Bob-Stone", string.rep("x", 250), false))
        end)

        it("never says anything itself: the line isn't part of the macro", function()
            assert.is_nil(ns.BuffButton.BuildCastMacro("Bob-Stone", "Mark of the Wild", true):find("/s", 1, true))
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
            button.scripts.PreClick(button, "LeftButton", true)
            -- The game reports another name for the cast (a same-named player elsewhere, say).
            ns.BuffButton.OnSpellcastSent("player", "Ann Vale", "Cast-1", MOTW)
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-1", MOTW)
            assert.is_nil(ns.db.ledger.entries[1].returned)
            assert.are.equal(1, ns.Offers.Count(), "still owed")
            assert.is_true(printedHas("Mark of the Wild went to Ann Vale, not Bob Stone."))
        end)

        it("counts it returned when the game gives the full name, and ignores a cast report before any press", function()
            stranger()
            buffedBy()
            wow.state.sentTargetForm = "full"
            wow.press(button)
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

        describe("never reports 'No answer' for a press the game answered", function()
            local function noAnswerPrinted()
                return printedHas("No answer")
            end

            it("a refused cast", function()
                wow.state.castFailures["Bob-Stone"] = "Out of range."
                stranger()
                buffedBy()
                wow.press(button)
                wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
                assert.is_true(printedHas("Couldn't buff Bob Stone: Out of range."))
                assert.is_false(noAnswerPrinted())
            end)

            it("a cast the game didn't name", function()
                wow.state.sentTargetForm = "none"
                stranger()
                buffedBy()
                wow.press(button)
                wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
                assert.is_false(noAnswerPrinted())
                assert.is_truthy(ns.BuffButton.StatusLines()[#ns.BuffButton.StatusLines()]:find("didn't say", 1, true))
            end)

            it("a return with another favour waiting behind it", function()
                stranger("nameplate2", { name = "Ann", surname = "Vale" })
                buffedBy("nameplate2")
                stranger("nameplate1")
                buffedBy("nameplate1")
                wow.press(button)
                assert.are.equal(1, #wow.casts)
                wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
                assert.is_false(noAnswerPrinted())
                assert.are.equal("Ann-Vale", ns.BuffButton.ArmedOffer().name, "Ann is next")
            end)

            it("when the game acts on key up", function()
                wow.state.cvars.ActionButtonUseKeyDown = "0"
                stranger()
                buffedBy()
                wow.press(button)
                wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
                assert.are.equal(1, #wow.casts)
                assert.is_false(noAnswerPrinted())
            end)
        end)

        it("says nothing about a mouse press released off the button (nothing was attempted)", function()
            stranger("nameplate1")
            buffedBy("nameplate1")
            wow.state.targetNameForm = "hyphen" -- /targetexact can't find them
            -- Only the down half reaches the button.
            button.scripts.PreClick(button, "LeftButton", true)
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
            assert.is_false(printedHas("No answer"))
        end)

        it("reports a press that got no answer (they couldn't be found)", function()
            stranger("nameplate1")
            buffedBy("nameplate1")
            wow.state.targetNameForm = "hyphen" -- /targetexact can't find them by the name given
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

        -- The line waits in the chat queue after a confirmed return; /say
        -- goes out on the next key press (the game needs one for /say).
        local function nextKey()
            wow.advance(0)
            wow.keyDown()
        end

        it("says a line once the game confirms the buff reached them, on your next key press", function()
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "For you, {name}: {buff}!" }
            stranger()
            buffedBy()
            assert.is_nil(macro():find("/s", 1, true), "nothing said by the macro")
            wow.press(button)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
            assert.are.same({}, wow.sentTo("SAY"), "not with the press itself")
            nextKey()
            assert.are.same({ "For you, Bob: Mark of the Wild!" }, wow.sentTo("SAY"))
            nextKey()
            assert.are.equal(1, #wow.sentTo("SAY"), "said once")
        end)

        it("says one line per confirmed return, in rotation", function()
            ns.db.buff.enabled = false
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "One {name}", "Two {name}" }
            stranger()
            buffedBy()
            wow.press(button)
            nextKey()
            wow.advance(ns.Offers.RETURNED_RECENTLY + 1)
            buffedBy()
            assert.is_truthy(macro(), "offered again")
            wow.press(button)
            nextKey()
            assert.are.equal(2, ns.db.ledger.totals.returned)
            local said = wow.sentTo("SAY")
            table.sort(said)
            assert.are.same({ "One Bob", "Two Bob" }, said)
            assert.are.same({}, wow.errors)
        end)

        it("says nothing when the line is off (the default)", function()
            ns.db.buffBack.messages = { "For you, {name}!" }
            stranger()
            buffedBy()
            wow.press(button)
            nextKey()
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
            assert.are.same({}, wow.sentTo("SAY"))
        end)

        it("says nothing for a press that casts nothing", function()
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "For you, {name}!" }
            stranger("nameplate9")
            buffedBy("nameplate9")
            wow.state.units.nameplate9 = nil -- they walked off
            wow.press(button)
            nextKey()
            assert.are.equal(0, #wow.casts)
            assert.are.same({}, wow.sentTo("SAY"))
        end)

        it("says nothing when the cast went to someone else, failed, or the favour had gone", function()
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "For you, {name}!" }
            stranger()
            buffedBy()
            button.scripts.PreClick(button, "LeftButton", true)
            ns.BuffButton.OnSpellcastSent("player", "Ann Vale", "Cast-1", MOTW)
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-1", MOTW)
            nextKey()
            assert.are.same({}, wow.sentTo("SAY"), "went to someone else")

            button.scripts.PreClick(button, "LeftButton", true)
            ns.BuffButton.OnSpellcastSent("player", "Bob Stone", "Cast-2", MOTW)
            ns.BuffButton.OnSpellcastFailed("player", "Cast-2", MOTW)
            nextKey()
            assert.are.same({}, wow.sentTo("SAY"), "failed")

            button.scripts.PreClick(button, "LeftButton", true)
            ns.BuffButton.OnSpellcastSent("player", "Bob Stone", "Cast-3", MOTW)
            ns.Offers.LetGo("Bob-Stone")
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-3", MOTW)
            nextKey()
            assert.are.same({}, wow.sentTo("SAY"), "no favour was waiting")
        end)

        it("says nothing when the game didn't say who the cast reached", function()
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "For you, {name}!" }
            stranger()
            buffedBy()
            button.scripts.PreClick(button, "LeftButton", true)
            ns.BuffButton.OnSpellcastSent("player", nil, "Cast-1", MOTW)
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-1", MOTW)
            nextKey()
            assert.are.same({}, wow.sentTo("SAY"))
        end)

        it("doesn't say the line while snoozed or AFK", function()
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "For you, {name}!" }
            stranger()
            buffedBy()
            ns.Announcer.Snooze(15)
            wow.press(button)
            nextKey()
            assert.are.same({}, wow.sentTo("SAY"))
            assert.are.equal(1, #wow.casts, "the cast still goes")
            ns.Announcer.Snooze(nil)
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            buffedBy("nameplate2")
            wow.state.afk = true
            wow.press(button)
            nextKey()
            assert.are.equal(2, #wow.casts)
            assert.are.same({}, wow.sentTo("SAY"))
        end)

        it("drops the line if it's switched off, or they're ignored, before your next key press", function()
            ns.db.buffBack.messages = { "For you, {name}!" }
            ns.db.buffBack.sayLine = true
            stranger()
            buffedBy()
            wow.press(button)
            wow.advance(0)
            ns.db.buffBack.sayLine = false
            wow.keyDown()
            assert.are.same({}, wow.sentTo("SAY"), "switched off")

            ns.db.buffBack.sayLine = true
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            buffedBy("nameplate2")
            wow.press(button)
            wow.advance(0)
            ns.Ignore.Add("Ann-Vale")
            wow.keyDown()
            assert.are.same({}, wow.sentTo("SAY"), "ignored")
        end)

        it("drops the line when no key is pressed for too long", function()
            ns.db.buff.enabled = false -- no thank-you for their buff in /say meanwhile
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "For you, {name}!" }
            stranger()
            buffedBy()
            wow.press(button)
            wow.advance(ns.BuffTracker.SAY_MAX_AGE + 1)
            wow.keyDown()
            assert.are.same({}, wow.sentTo("SAY"))
        end)

        it("says the line after a slow server answer", function()
            ns.db.buff.enabled = false -- no thank-you for their buff in /say meanwhile
            wow.state.castLatency = 2
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "For you, {name}!" }
            stranger()
            buffedBy()
            wow.press(button)
            nextKey()
            assert.are.same({}, wow.sentTo("SAY"), "not before the answer")
            wow.advance(2)
            nextKey()
            assert.are.same({ "For you, Bob!" }, wow.sentTo("SAY"))
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

    describe("presses and the game's answers", function()
        local function half(isDown) button.scripts.PreClick(button, "LeftButton", isDown) end

        it("a second press while the first cast is in flight doesn't lose the first one's credit", function()
            stranger()
            buffedBy()
            half(true); half(false)                                       -- press 1
            ns.BuffButton.OnSpellcastSent("player", "Bob", "Cast-1", MOTW)
            half(true); half(false)                                       -- press 2, mashed
            ns.BuffButton.OnUIError(0, "Spell is not ready yet.")         -- the cooldown refuses press 2
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-1", MOTW)  -- press 1 lands
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("matches a late answer to its own press, with no error text in between", function()
            stranger()
            buffedBy()
            half(true); half(false)
            ns.BuffButton.OnSpellcastSent("player", "Bob", "Cast-1", MOTW)
            half(true); half(false)
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-1", MOTW)
            assert.are.equal("Returned Mark of the Wild to Bob Stone.", button.result:GetText())
        end)

        it("credits casts the server answers late, pressed twice", function()
            wow.state.castLatency = 0.3
            stranger()
            buffedBy()
            wow.press(button)
            wow.press(button) -- before the first answer: casts again (the favour is still owed)
            wow.advance(1)
            assert.are.equal(2, #wow.casts)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
            assert.are.equal(1, ns.Ledger.Summary().returned, "returned once")
            assert.is_false(printedHas("No answer"))
        end)

        it("says why the server refused a cast, however late its answer", function()
            wow.state.castLatency = 1.5
            wow.state.castFailures["Bob-Stone"] = "Target not in line of sight"
            stranger()
            buffedBy()
            wow.press(button)
            wow.advance(2)
            assert.are.equal("Couldn't buff Bob Stone: Target not in line of sight", button.result:GetText())
            assert.are.equal(1, ns.Offers.Count(), "still owed")
        end)

        it("credits the favour the game acted on when another arrives while the key is held (key up)", function()
            wow.state.cvars.ActionButtonUseKeyDown = "0"
            stranger("nameplate1")
            buffedBy("nameplate1")
            half(true)                                    -- key down: Bob armed
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            buffedBy("nameplate2")                        -- Ann's buff lands while the key is held
            wow.hardware = true
            half(false)                                   -- re-armed for Ann; the macro runs now
            wow.runMacro(macro())
            wow.hardware = false
            assert.are.equal("Ann-Vale", wow.casts[1].target)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[2].returned, "Ann's favour credited")
            assert.is_false(printedHas("went to Ann"))
        end)

        it("still records the press when the key is held past the answer window (key up)", function()
            wow.state.cvars.ActionButtonUseKeyDown = "0"
            stranger()
            buffedBy()
            half(true)
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
            assert.is_false(printedHas("No answer"), "a press not yet released isn't reported")
            wow.hardware = true
            half(false)
            wow.runMacro(macro())
            wow.hardware = false
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
        end)

        it("reports 'No answer' for a click delivered on release only", function()
            stranger("nameplate1")
            buffedBy("nameplate1")
            wow.state.targetNameForm = "hyphen" -- /targetexact can't find them
            half(false) -- no down half
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 0.2)
            assert.is_true(printedHas("No answer: couldn't find Bob Stone"))
        end)

        it("doesn't blame a later error on a press", function()
            stranger("nameplate1")
            buffedBy("nameplate1")
            half(true) -- down half only (released off the button)
            wow.advance(ns.BuffButton.ERROR_ANSWER_SECONDS + 0.1)
            wow.uiError("Not enough energy")
            assert.is_false(printedHas("Couldn't buff"))
            half(true); half(false)
            wow.advance(ns.BuffButton.ERROR_ANSWER_SECONDS + 0.1)
            wow.uiError("Not enough energy")
            assert.is_false(printedHas("Couldn't buff"), "nor on a complete press that found nobody")
        end)

        it("shows the game's error text without escape codes", function()
            wow.state.castFailures["Bob-Stone"] = "|cffff0000Out of range.|r"
            stranger()
            buffedBy()
            wow.press(button)
            assert.are.equal("Couldn't buff Bob Stone: cffff0000Out of range.r", button.result:GetText())
        end)

        it("only your own cast of the armed buff answers a press", function()
            stranger()
            buffedBy()
            half(true)
            ns.BuffButton.OnSpellcastSent("target", "Bob", "x", MOTW)   -- someone else's cast
            ns.BuffButton.OnSpellcastSucceeded("target", "x", MOTW)
            ns.BuffButton.OnSpellcastSent("player", "Bob", "y", 5185)   -- your Healing Touch on Bob
            ns.BuffButton.OnSpellcastSucceeded("player", "y", 5185)
            assert.is_nil(ns.db.ledger.entries[1].returned)
            assert.are.equal(1, ns.Offers.Count())
        end)

        it("one right-click lets one favour go", function()
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            buffedBy("nameplate2")
            stranger("nameplate1")
            buffedBy("nameplate1")
            wow.press(button, "RightButton")
            assert.are.equal(1, ns.Offers.Count())
            assert.are.equal("Ann-Vale", ns.BuffButton.ArmedOffer().name)
        end)

        it("a refusal before anything is sent is reported once, not also as 'No answer' (key down)", function()
            stranger()
            buffedBy()
            half(true)
            ns.BuffButton.OnUIError(0, "Out of range.") -- refused on the spot: no SENT, no FAILED
            half(false)
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
            assert.is_false(printedHas("No answer"))
            assert.are.equal("Couldn't buff Bob Stone: Out of range.", button.result:GetText())
        end)

        it("a cast of the same spell sent some other way doesn't answer a press it wasn't sent for", function()
            stranger()
            buffedBy()
            half(true); half(false)
            ns.BuffButton.OnSpellcastSent("player", "Bob", "Cast-1", MOTW)
            ns.BuffButton.OnSpellcastSent("player", "Ann", "Cast-2", MOTW)       -- your action bar, on Ann
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-2", MOTW)
            assert.is_nil(ns.db.ledger.entries[1].returned, "Cast-2 went to Ann")
            ns.BuffButton.OnSpellcastFailed("player", "Cast-1", MOTW)
            ns.BuffButton.OnUIError(0, "Target not in line of sight")
            assert.are.equal("Couldn't buff Bob Stone: Target not in line of sight", button.result:GetText())
            assert.are.equal(1, ns.Offers.Count())
        end)

        it("a second cast sent before the first lands doesn't take over the first press", function()
            stranger()
            buffedBy()
            half(true); half(false)
            ns.BuffButton.OnSpellcastSent("player", "Bob", "g1", MOTW)
            ns.BuffButton.OnSpellcastSent("player", "Ann", "g2", MOTW)
            ns.BuffButton.OnSpellcastSucceeded("player", "g1", MOTW)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
        end)

        it("a cast of another of your buffs doesn't answer the press", function()
            stranger()
            buffedBy()
            half(true); half(false)
            ns.BuffButton.OnSpellcastSent("player", "Bob", "g", THORNS)
            ns.BuffButton.OnSpellcastSucceeded("player", "g", THORNS)
            assert.is_nil(ns.db.ledger.entries[1].returned)
        end)

        it("a sent cast the server is slow to answer is never called 'No answer', and is still credited", function()
            wow.state.castLatency = 4
            stranger()
            buffedBy()
            wow.press(button)
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 0.5)
            assert.is_false(printedHas("No answer"))
            wow.advance(1)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
        end)

        it("says so when a sent cast is never answered at all", function()
            wow.state.castLatency = ns.BuffButton.SENT_ANSWER_SECONDS + 10
            stranger()
            buffedBy()
            wow.press(button)
            wow.advance(ns.BuffButton.SENT_ANSWER_SECONDS + 1)
            assert.are.equal("No word back on Mark of the Wild for Bob Stone. If it didn't land, press again.",
                button.result:GetText())
            assert.is_false(printedHas("No answer"))
        end)

        it("a key held before release (key up) still gets its late answer", function()
            wow.state.cvars.ActionButtonUseKeyDown = "0"
            wow.state.castLatency = 1.5
            stranger()
            buffedBy()
            half(true)
            wow.advance(2)
            wow.hardware = true; half(false); wow.runMacro(macro()); wow.hardware = false
            wow.advance(2)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
        end)

        it("a retry replaces the press that found nobody: no 'No answer' once the retry casts", function()
            stranger()
            buffedBy()
            wow.state.targetNameForm = "hyphen"
            wow.press(button)
            wow.state.targetNameForm = "space"
            wow.advance(1)
            wow.press(button)
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
            assert.is_false(printedHas("No answer"))
        end)

        it("a press already sent keeps its favour when another arrives while the key is held (key down)", function()
            wow.state.castLatency = 1
            stranger()
            buffedBy()
            wow.hardware = true; half(true); wow.runMacro(macro()); wow.hardware = false
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            buffedBy("nameplate2")
            half(false)
            wow.advance(2)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned, "Bob's favour credited")
            assert.is_false(printedHas("went to"))
            assert.is_false(printedHas("No answer"))
        end)

        it("an error just after a press was answered isn't blamed on it", function()
            stranger()
            buffedBy()
            wow.press(button)
            ns.BuffButton.OnUIError(0, "Not enough energy")
            assert.is_false(printedHas("Couldn't buff"))
        end)

        it("a refusal is reported once; a later error isn't blamed on it", function()
            wow.state.castFailures["Bob-Stone"] = "Out of range."
            stranger()
            buffedBy()
            wow.press(button)
            wow.advance(1)
            wow.uiError("Not enough energy")
            local n = 0
            for _, line in ipairs(wow.printed) do
                if line:find("Couldn't buff", 1, true) then n = n + 1 end
            end
            assert.are.equal(1, n)
        end)

        it("a quiet failure (the game's event) answers the press: no error blamed, no 'No word back'", function()
            stranger()
            buffedBy()
            half(true); half(false)
            wow.fire("UNIT_SPELLCAST_SENT", "player", "Bob", "Cast-1", MOTW)
            wow.fire("UNIT_SPELLCAST_FAILED_QUIET", "player", "Cast-1", MOTW)
            wow.advance(2)
            wow.uiError("Not enough energy")
            assert.is_false(printedHas("Couldn't buff"))
            wow.advance(ns.BuffButton.SENT_ANSWER_SECONDS)
            local status = table.concat(ns.BuffButton.StatusLines(), "\n")
            assert.is_nil(status:find("No word back", 1, true), "'No word back' is shown on the button, not in chat")
            assert.are.equal(1, ns.Offers.Count(), "still owed")
        end)

        it("a failure with no error text isn't blamed for a later error, and is reported as a failure", function()
            stranger()
            buffedBy()
            half(true); half(false)
            wow.fire("UNIT_SPELLCAST_SENT", "player", "Bob", "Cast-1", MOTW)
            wow.fire("UNIT_SPELLCAST_FAILED", "player", "Cast-1", MOTW)
            wow.advance(2)
            wow.uiError("Not enough energy")
            assert.is_false(printedHas("Not enough energy"))
            wow.advance(ns.BuffButton.SENT_ANSWER_SECONDS)
            assert.is_true(printedHas("Couldn't buff Bob Stone (the game gave no reason)."))
        end)

        it("a quiet failure is never reported later as a failure with no reason", function()
            stranger()
            buffedBy()
            half(true); half(false)
            wow.fire("UNIT_SPELLCAST_SENT", "player", "Bob", "Cast-1", MOTW)
            wow.fire("UNIT_SPELLCAST_FAILED_QUIET", "player", "Cast-1", MOTW)
            wow.advance(ns.BuffButton.SENT_ANSWER_SECONDS + 1)
            assert.is_false(printedHas("Couldn't buff"))
        end)

        it("an empty down half doesn't make a later release-only click 'unsure'", function()
            stranger()
            buffedBy()
            wow.state.targetNameForm = "hyphen" -- visible, but /targetexact won't find him
            local bob = wow.state.units.nameplate1
            wow.state.units.nameplate1 = nil
            wow.advance(6)                     -- the button empties (Bob out of view)
            half(true); half(false)            -- a press on the empty button: nothing
            wow.state.units.nameplate1 = bob
            wow.advance(1)                     -- back in view: armed
            wow.hardware = true; half(false); wow.runMacro(macro()); wow.hardware = false
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
            assert.is_true(printedHas("No answer: couldn't find Bob Stone"))
        end)

        it("gives the game's reason for a late refusal whichever comes first, the error or the failure", function()
            for _, errorFirst in ipairs({ false, true }) do
                boot()
                wow.state.errorBeforeFailed = errorFirst
                wow.state.castLatency = 1.5
                wow.state.castFailures["Bob-Stone"] = "Target not in line of sight"
                stranger()
                buffedBy()
                wow.press(button)
                wow.advance(2)
                assert.are.equal("Couldn't buff Bob Stone: Target not in line of sight", button.result:GetText(),
                    "error first: " .. tostring(errorFirst))
                wow.advance(ns.BuffButton.SENT_ANSWER_SECONDS)
                assert.is_false(printedHas("gave no reason"))
            end
        end)

        it("one error text answers one failure, and never one pressed after it", function()
            stranger()
            buffedBy()
            half(true); half(false)
            wow.fire("UNIT_SPELLCAST_SENT", "player", "Bob", "Cast-1", MOTW)
            half(true); half(false)
            wow.fire("UNIT_SPELLCAST_SENT", "player", "Bob", "Cast-2", MOTW)
            wow.advance(1) -- the server's refusals come late, error text first
            wow.uiError("Target not in line of sight")
            wow.fire("UNIT_SPELLCAST_FAILED", "player", "Cast-1", MOTW)
            wow.fire("UNIT_SPELLCAST_FAILED", "player", "Cast-2", MOTW)
            local n = 0
            for _, line in ipairs(wow.printed) do
                if line:find("Target not in line of sight", 1, true) then n = n + 1 end
            end
            assert.are.equal(1, n)
        end)

        it("an error from just before a press isn't taken as its reason", function()
            stranger()
            buffedBy()
            wow.uiError("Not enough energy") -- from your action bar
            wow.advance(0.2)
            half(true); half(false)
            wow.fire("UNIT_SPELLCAST_SENT", "player", "Bob", "Cast-1", MOTW)
            wow.fire("UNIT_SPELLCAST_FAILED", "player", "Cast-1", MOTW)
            assert.is_false(printedHas("Not enough energy"))
        end)

        it("an old unclaimed error isn't taken by a later failure", function()
            stranger()
            buffedBy()
            wow.uiError("Not enough energy")
            wow.advance(5)
            half(true); half(false)
            wow.fire("UNIT_SPELLCAST_SENT", "player", "Bob", "Cast-1", MOTW)
            wow.fire("UNIT_SPELLCAST_FAILED", "player", "Cast-1", MOTW)
            assert.is_false(printedHas("Not enough energy"))
        end)

        it("in key-up mode a refusal is matched to the half that acted, however long the key was held", function()
            wow.state.cvars.ActionButtonUseKeyDown = "0"
            stranger()
            buffedBy()
            half(true)
            wow.advance(1)
            half(false)
            ns.BuffButton.OnUIError(0, "Out of range.")
            assert.are.equal("Couldn't buff Bob Stone: Out of range.", button.result:GetText())
        end)

        it("says nothing when the button fills between the halves of a press (key down: nothing was tried)", function()
            stranger()
            buffedBy()
            wow.state.units.nameplate1 = nil
            wow.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
            wow.advance(0)
            half(true)                       -- empty: the game's action does nothing
            stranger()                       -- he comes into view while the key is held
            half(false)
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
            assert.is_false(printedHas("No answer"))
        end)

        it("credits an up half that acted after an empty down half (a mouse click on release)", function()
            stranger()
            buffedBy()
            wow.state.units.nameplate1 = nil
            wow.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
            wow.advance(0)
            half(true)
            stranger()
            half(false)
            ns.BuffButton.OnSpellcastSent("player", "Bob", "Cast-9", MOTW)
            ns.BuffButton.OnSpellcastSucceeded("player", "Cast-9", MOTW)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
        end)

        it("keeps your target when the game won't say whether you have one", function()
            wow.addUnit("wolf", { name = "Wolf", isPlayer = false, hostile = true })
            wow.state.units.target = wow.state.units.wolf
            _G.UnitExists = function() return wow.secret(true) end
            stranger()
            buffedBy()
            wow.press(button)
            assert.are.equal(1, #wow.casts)
            assert.are.equal("Wolf", wow.state.units.target.name)
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
        -- keep its own bookkeeping consistent, and never say its line for a
        -- favour that wasn't returned.
        local function storm(seed)
            boot()
            math.randomseed(seed)
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = { "BB {name}" }
            -- A line may only be queued straight after a confirmed return for
            -- the same player, within the same step; each queued line may be
            -- said at most once, by name.
            local justReturned, queued, step = nil, {}, 0
            local markReturned = ns.Offers.MarkReturned
            ns.Offers.MarkReturned = function(name, spell)
                local ok = markReturned(name, spell)
                justReturned = ok and { name = name, step = step } or nil
                return ok
            end
            local schedule = ns.Announcer.Schedule
            ns.Announcer.Schedule = function(msgType, key, opts)
                if msgType == "buffBack" then
                    assert.is_truthy(justReturned and justReturned.name == key and justReturned.step == step,
                        ("seed %d, step %d: a line queued for %s with no return just confirmed"):format(seed, step, key))
                    justReturned = nil
                    local ok = schedule(msgType, key, opts)
                    if ok then
                        local first = ns.Util.FirstName(key)
                        queued[first] = (queued[first] or 0) + 1
                    end
                    return ok
                end
                return schedule(msgType, key, opts)
            end
            -- How often the storm reached the outcomes that must stay silent.
            local wentElsewhere, nothingWaiting = 0, 0
            local log = ns.Diag.Log
            ns.Diag.Log = function(category, fmt, ...)
                if category == "buffBack" and fmt == "%s" then
                    local text = tostring((...))
                    if text:find(" went to ", 1, true) then wentElsewhere = wentElsewhere + 1 end
                    if text:find("no favour was waiting", 1, true) then nothingWaiting = nothingWaiting + 1 end
                end
                return log(category, fmt, ...)
            end
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
                function() wow.state.castLatency = ({ 0, 0, 0.2, 1.5 })[math.random(4)] end,
                function() wow.state.errorBeforeFailed = math.random() < 0.5 end,
                function() wow.keyDown() end,
                function() wow.state.afk = math.random() < 0.2 end,
                -- The cast lands on someone else, or the favour goes while it's on its way.
                function()
                    wow.state.castLandsOn = math.random() < 0.3 and ("nameplate" .. math.random(1, 8)) or nil
                end,
                function() ns.Offers.LetGo(names[math.random(#names)] .. "-Stone") end,
            }
            -- Presses the game left unanswered (no cast or error from them): only
            -- those may be reported as "No answer".
            local unanswered = 0
            local realPress = wow.press
            local function countedPress(b, mouseButton, mods)
                local casts, errors = #wow.casts, 0
                local frame = CreateFrame("Frame")
                frame:RegisterEvent("UI_ERROR_MESSAGE")
                frame:SetScript("OnEvent", function() errors = errors + 1 end)
                realPress(b, mouseButton, mods)
                frame:UnregisterEvent("UI_ERROR_MESSAGE")
                if (mouseButton or "LeftButton") == "LeftButton" and #wow.casts == casts and errors == 0 then
                    unanswered = unanswered + 1
                end
            end
            actions[3] = function()
                countedPress(button, math.random() < 0.8 and "LeftButton" or "RightButton",
                    math.random() < 0.3 and { shift = true } or nil)
            end
            for n = 1, 1500 do
                step = n
                local which = math.random(#actions)
                actions[which]()
                if wow.state.inCombat then
                    assert.is_nil(macro(), "seed " .. seed .. ", step " .. step .. ": armed in a fight")
                end
                assert.is_true(ns.Offers.Count() <= ns.Offers.MAX, "seed " .. seed)
                -- The feature's safety rules: a buff never flags you for PvP,
                -- never lands on you, a dead or a hostile unit.
                assert.are.same({}, wow.flaggedBy, "seed " .. seed .. ", step " .. step .. ": flagged for PvP")
                local last = wow.casts[#wow.casts]
                if last then
                    assert.are_not.equal("Me", last.target, "seed " .. seed .. ": cast on yourself")
                    assert.is_falsy(last.targetDead or last.targetHostile, "seed " .. seed .. ": dead or hostile target")
                end
            end
            assert.are.same({}, wow.errors, "seed " .. seed)
            local s = ns.Ledger.Summary()
            assert.is_true(s.returned <= s.received, "seed " .. seed .. ": more returned than received")
            local noAnswers = 0
            for _, line in ipairs(wow.printed) do
                if line:find("No answer", 1, true) then noAnswers = noAnswers + 1 end
            end
            assert.is_true(noAnswers <= unanswered,
                ("seed %d: %d 'No answer' lines for %d unanswered presses"):format(seed, noAnswers, unanswered))
            local said, saidTo = 0, {}
            for _, line in ipairs(wow.sentTo("SAY")) do
                local first = line:match("^BB (.+)$")
                if first then
                    said = said + 1
                    saidTo[first] = (saidTo[first] or 0) + 1
                    assert.is_true(saidTo[first] <= (queued[first] or 0),
                        ("seed %d: %d lines said to %s, %d queued"):format(seed, saidTo[first], first, queued[first] or 0))
                end
            end
            return s, said, wentElsewhere, nothingWaiting
        end

        it("survives random storms of events, presses, fights and settings changes", function()
            local received, casts, returned, said, elsewhere, gone = 0, 0, 0, 0, 0, 0
            for _, seed in ipairs({ 1, 7, 42, 99, 404, 777, 2026, 4242, 31337, 65535 }) do
                local s, lines, wentElsewhere, nothingWaiting = storm(seed)
                received, casts, returned = received + s.received, casts + #wow.casts, returned + s.returned
                said, elsewhere, gone = said + lines, elsewhere + wentElsewhere, gone + nothingWaiting
            end
            -- The storms really exercised the button, not just the edges.
            assert.is_true(received > 100, "favours received: " .. received)
            assert.is_true(casts > 20, "casts: " .. casts)
            assert.is_true(returned > 0, "favours returned: " .. returned)
            assert.is_true(said > 0, "buff back lines said: " .. said)
            assert.is_true(elsewhere > 0, "casts that went to someone else: " .. elsewhere)
            assert.is_true(gone > 0, "casts that found no favour waiting: " .. gone)
        end)

        it("a damaged sayLine doesn't switch on talking", function()
            ns.db.buffBack.messages = { "For you, {name}!" }
            ns.db.buffBack.sayLine = "yes" -- damaged mid-session; the default is false
            ns.db.buff.enabled = false
            stranger()
            buffedBy()
            wow.press(button)
            wow.advance(0)
            wow.keyDown()
            assert.are.equal(1, #wow.casts)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
            assert.are.same({}, wow.sentTo("SAY"))
        end)

        it("keeps casting when its line list is damaged into a number mid-session", function()
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.messages = 42
            stranger()
            buffedBy()
            wow.press(button)
            wow.advance(0)
            wow.keyDown()
            assert.are.equal(1, #wow.casts)
            assert.are.same({}, wow.errors)
        end)

        it("heals at once, without a reload, when its whole settings table is lost", function()
            stranger()
            buffedBy()
            ns.db.buffBack = nil
            slash("buffback") -- fails once (the error is caught), and the settings are repaired
            assert.are.equal(1, #wow.errors)
            assert.is_table(ns.db.buffBack)
            wow.errors = {}
            slash("buffback")
            assert.are.same({}, wow.errors)
            wow.fire("PLAYER_TARGET_CHANGED")
            wow.press(button)
            assert.are.equal("Mark of the Wild", wow.casts[1].spell)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
        end)

        it("an unrelated error doesn't change the ledger, and repairs run at most once a second", function()
            local entry = ns.Ledger.Received("Ann-Vale", "Arcane Intellect") -- a thank-you pending
            local loads = 0
            local realLoad = ns.Profiles.Validate
            finally(function() ns.Profiles.Validate = realLoad end)
            ns.Profiles.Validate = function(...) loads = loads + 1 return realLoad(...) end
            for _ = 1, 50 do ns.Diag.Call(function() error("not about settings") end) end
            assert.are.equal(ns.Ledger.PENDING, entry.result, "a live thank-you isn't marked missed")
            assert.are.equal(1, loads, "one repair for fifty errors in one moment")
            wow.advance(ns.Config.REPAIR_INTERVAL_SECONDS)
            ns.Diag.Call(function() error("again") end)
            assert.are.equal(2, loads)
        end)

        it("the ledger entry itself is marked returned after the ledger was damaged mid-session", function()
            stranger()
            buffedBy()
            ns.db.ledger.totals.returned = "x"
            ns.Ledger.Summary() -- something reads the ledger first: it is repaired now
            wow.press(button)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
        end)

        it("credits a return even when the ledger was damaged mid-session", function()
            for _, damage in ipairs({
                function() ns.db.ledger = nil end,
                function() ns.db.ledger.totals.returned = "x" end,
                function() ns.db.ledger.today = 7 end,
            }) do
                boot()
                stranger()
                buffedBy()
                damage()
                wow.press(button)
                assert.are.same({}, wow.errors)
                assert.are.equal(0, ns.Offers.Count(), "returned, not lost")
                assert.are.equal(1, ns.Ledger.Summary().returned, "and counted")
            end
        end)

        it("keeps working when its settings are damaged mid-session, and a reload heals them", function()
            stranger()
            buffedBy()
            ns.db.buffBack.messages = "not a list"
            ns.db.buffBack.sayLine = "yes"
            ns.db.buffBack.owedMinutes = "ten"
            wow.fire("PLAYER_TARGET_CHANGED")
            wow.advance(30)
            assert.is_truthy(macro(), "still armed, damaged values read as their defaults")
            wow.press(button)
            assert.are.equal("Mark of the Wild", wow.casts[#wow.casts].spell, "still casts before any reload")
            assert.are.same({}, wow.errors)
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

        it("a return after /friendly ledger clear isn't counted again", function()
            local entry = ns.Ledger.Received("Bob-Stone", "Arcane Intellect")
            ns.Ledger.Clear()
            ns.Ledger.Returned(entry, "Mark of the Wild")
            assert.are.equal(0, ns.Ledger.Summary().returned)
        end)

        it("a returned favour never gets a 'not returned' note", function()
            local entry = ns.Ledger.Received("Bob-Stone", "Arcane Intellect")
            ns.Ledger.Returned(entry, "Mark of the Wild")
            ns.Ledger.NoteNotReturned(entry, "you let it go")
            assert.is_nil(entry.returnNote)
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
