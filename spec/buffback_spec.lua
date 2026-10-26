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

    local function macro() return button:GetAttribute("macrotext1") end

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
            ns.db.buffBack.offer = false
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
        it("targets by name, casts, and clears the target when you had none", function()
            assert.are.equal("/target Bob Stone\n/cast Mark of the Wild\n/cleartarget",
                ns.BuffButton.BuildCastMacro("Bob-Stone", "Mark of the Wild", nil, false, false))
        end)

        it("gives you your target back when you had one", function()
            assert.are.equal("/target Bob Stone\n/cast Mark of the Wild\n/targetlasttarget",
                ns.BuffButton.BuildCastMacro("Bob-Stone", "Mark of the Wild", nil, false, true))
        end)

        it("just casts when they're already your target", function()
            assert.are.equal("/cast Mark of the Wild\n/s Here you go!",
                ns.BuffButton.BuildCastMacro("Bob-Stone", "Mark of the Wild", "Here you go!", true, true))
        end)

        it("refuses any part that could end its line or start a command", function()
            local build = ns.BuffButton.BuildCastMacro
            assert.is_nil(build("Bob-Stone", "Mark\n/cast Pyroblast", nil, false, false))
            assert.is_nil(build("Bob-Stone", "Mark of the Wild", "hi\n/dance", false, false))
            assert.is_nil(build("Bob-Stone", "Mark of the Wild", "/yell boo", false, false))
            assert.is_nil(build("Bob-Stone", "Mark of the Wild", "a |cffff0000red|r line", false, false))
            assert.is_nil(build("Bob-Stone", "", nil, false, false))
        end)

        it("refuses a macro longer than the game allows", function()
            assert.is_nil(ns.BuffButton.BuildCastMacro("Bob-Stone", "Mark of the Wild", string.rep("x", 250),
                false, false))
        end)
    end)

    describe("the button", function()
        it("is hidden and empty while nobody is owed", function()
            assert.is_false(button:IsShown())
            assert.is_nil(macro())
        end)

        it("shows the favour and holds its macro, on the left button only", function()
            stranger()
            buffedBy()
            assert.is_true(button:IsShown())
            assert.are.equal("macro", button:GetAttribute("type1"))
            assert.are.equal("/target Bob Stone\n/cast Mark of the Wild\n/cleartarget", macro())
            assert.is_nil(button:GetAttribute("type"), "no action for every mouse button")
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

        it("can be pressed by its key binding: the binding presses the left button", function()
            local xml = wow.readFile("Bindings.xml")
            assert.is_truthy(xml:find('name="CLICK FriendlyForeverBuffButton:LeftButton"', 1, true))
            assert.are.equal("Friendly Forever: buff back", _G["BINDING_NAME_CLICK FriendlyForeverBuffButton:LeftButton"])
        end)

        it("doesn't mark it returned when the cast went to someone else", function()
            -- If the game's /target wants another spelling, it finds nobody and
            -- the buff lands on you instead.
            wow.state.targetNameForm = "hyphen"
            stranger()
            buffedBy()
            wow.press(button)
            assert.are.equal("Me", wow.casts[1].target)
            assert.is_nil(ns.db.ledger.entries[1].returned)
            assert.are.equal(1, ns.Offers.Count(), "still owed")
            assert.is_true(printedHas("Mark of the Wild went to Me, not Bob Stone."))
        end)

        it("trusts the cast when the game doesn't say who it went to", function()
            wow.state.sentTargetForm = "none"
            stranger()
            buffedBy()
            wow.press(button)
            assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
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

        it("keeps what it holds through a fight, and catches up after", function()
            stranger("nameplate1")
            buffedBy("nameplate1")
            local before = macro()
            wow.state.inCombat = true
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            buffedBy("nameplate2") -- would error if it touched the button now
            assert.are.equal(before, macro())
            wow.press(button)
            assert.are.equal("Bob-Stone", wow.casts[1].target, "the frozen macro still casts")
            wow.state.inCombat = false
            wow.fire("PLAYER_REGEN_ENABLED")
            assert.is_truthy(macro():find("/target Ann Vale", 1, true))
            assert.are.same({}, wow.errors)
        end)

        it("says a line as you cast, when switched on", function()
            ns.db.buffBack.enabled = true
            ns.db.buffBack.messages = { "For you, {name}: {buff}!" }
            stranger()
            buffedBy()
            assert.are.equal("/target Bob Stone\n/cast Mark of the Wild\n/s For you, Bob: Mark of the Wild!\n/cleartarget",
                macro())
            wow.press(button)
            assert.are.same({ "For you, Bob: Mark of the Wild!" }, wow.sentTo("SAY"))
        end)

        it("keeps the same line while re-arming, so the rotation isn't used up", function()
            ns.db.buffBack.enabled = true
            ns.db.buffBack.messages = { "One {name}", "Two {name}" }
            stranger()
            buffedBy()
            local first = macro()
            wow.fire("PLAYER_TARGET_CHANGED")
            wow.fire("PLAYER_TARGET_CHANGED")
            assert.are.equal(first, macro())
        end)

        it("skips a line that starts a command or won't fit, and casts anyway", function()
            ns.db.buffBack.enabled = true
            ns.db.buffBack.messages = { "/yell {name}", string.rep("long ", 60) }
            stranger()
            buffedBy()
            assert.are.equal("/target Bob Stone\n/cast Mark of the Wild\n/cleartarget", macro())
        end)

        it("/friendly buffback says what is armed and why not", function()
            slash("buffback")
            assert.is_true(printedHas("not armed: nobody is owed a buff"))
            assert.is_true(printedHas("your buffs: Mark of the Wild, Thorns"))
            stranger()
            buffedBy()
            slash("buffback")
            assert.is_true(printedHas("macro: /target Bob Stone ; /cast Mark of the Wild ; /cleartarget"))
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
            wow.state.inCombat = true
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

        it("isn't moved by importing someone's settings", function()
            ns.db.buffBack.position = { point = "TOP", x = 5, y = 5 }
            local line = ns.Profiles.Export()
            assert.is_nil(ns.Serialize.Decode(line).settings.buffBack.position)
            boot()
            ns.db.buffBack.position = { point = "LEFT", x = 1, y = 2 }
            ns.Profiles.Import(line)
            assert.are.same({ point = "LEFT", x = 1, y = 2 }, ns.db.buffBack.position)
        end)
    end)

    describe("the ledger", function()
        it("counts favours returned, and gives titles for them", function()
            for _ = 1, 10 do
                ns.Ledger.Returned(ns.Ledger.Received("Bob-Stone", "Thorns"), "Mark of the Wild")
            end
            local title, nextTitle, more = ns.Ledger.Title()
            assert.are.equal("Courteous", title)
            assert.are.equal("Well-Mannered", nextTitle)
            assert.are.equal(15, more)
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
            local title, nextTitle = ns.Ledger.Title()
            assert.is_nil(title)
            assert.are.equal("Courteous", nextTitle)
            ns.db.ledger.totals.returned = 5000
            title, nextTitle = ns.Ledger.Title()
            assert.are.equal("Friend to All Azeroth", title)
            assert.is_nil(nextTitle)
        end)
    end)

    describe("options", function()
        it("the Buff Back tab hides delay and repeat, and shows its own settings", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            assert.is_false(w.steppers.delay.box:IsShown())
            assert.is_false(w.steppers.repeatCooldown.box:IsShown())
            assert.is_true(w.offer:IsShown())
            assert.is_true(w.steppers.owedMinutes.box:IsShown())
            assert.are.equal("Say a line as I buff them back", w.enabled.label:GetText())
            wow.run(w.tabs.guildLogin, "OnClick")
            assert.is_true(w.steppers.delay.box:IsShown())
            assert.is_false(w.offer:IsShown())
        end)
    end)
end)
