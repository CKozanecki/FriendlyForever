-- Spec: #40
-- Buff requests in chat: a whisper or /say asking for one of your buffs
-- queues that player on the buff-back button, for that buff. It never casts,
-- says nothing in chat, and is off by default. Chat text is untrusted:
-- fixed patterns only, your own class's buffs only, one request per player,
-- a limit on how many wait, and the ignore list, snooze and quiet apply.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

-- Each class's buffs on Forever, top rank (BuffTable.lua): the spells the
-- specs' characters know.
local SPELLS = {
    DRUID = { motw = 9885, thorns = 9910 },
    MAGE = { intellect = 10157 },
    PALADIN = { kings = 20217, wisdom = 25290, might = 25291 },
    PRIEST = { fortitude = 10938, spirit = 27841, shadow = 10958 },
    SHAMAN = { waterbreathing = 131 },
    WARLOCK = { breath = 5697 },
    WARRIOR = { battleshout = 25289 },
}

-- Common phrasings players use for each buff, written here from how players
-- ask, not copied from the addon's list: [class] = { [buff key] = { names } }.
local ASKED = {
    DRUID = { motw = { "mark", "motw", "mark of the wild", "gotw", "gift", "gift of the wild", "Mark of the Wild" },
        thorns = { "thorns", "Thorns" } },
    MAGE = { intellect = { "int", "intellect", "ai", "ab", "brilliance", "arcane intellect", "arcane brilliance",
        "Arcane Intellect" } },
    PALADIN = { kings = { "kings", "bok", "blessing of kings", "Blessing of Kings" },
        wisdom = { "wisdom", "wis", "bow", "blessing of wisdom" },
        might = { "might", "bom", "blessing of might", "Blessing of Might" } },
    PRIEST = { fortitude = { "fort", "fortitude", "pwf", "stam", "stamina", "power word fortitude",
        "Power Word: Fortitude" },
        spirit = { "spirit", "ds", "divine spirit", "Divine Spirit" },
        shadow = { "shadow prot", "shadow protection", "sprot", "Shadow Protection" } },
    -- Either breathing buff by either name (the owner, on #40).
    SHAMAN = { waterbreathing = { "water breathing", "wb", "unending breath", "ub", "breath", "Water Breathing" } },
    WARLOCK = { breath = { "unending breath", "ub", "breath", "water breathing", "wb", "Unending Breath" } },
}

-- Ways around a buff's name: %s is the name.
local FRAMINGS = { "%s", "%s pls", "%s please", "%s plz", "%s?", "%s pls?", "%s!", "can i get %s?",
    "Can I get %s please", "could i get %s", "can i have %s", "may i have %s?", "any %s?", "need %s", "got %s?",
    "%s pls ty", "  %s   pls  ", "%s plox", "can i haz %s" }

-- The storm's seeds: each reaches the limit of requests, and a favour owed
-- while the button is full with requests among it (the storm checks both).
local STORM_SEEDS = { 24, 30, 64, 87, 106 }

local ME = { name = "Nikki", surname = "Shifts", id = "Nikki-Shifts", isPlayer = true }

describe("Buff requests in chat", function()
    local ns, button

    local function boot(opts)
        opts = opts or {}
        local class = opts.class or "DRUID"
        ns = wow.boot({ db = opts.db, noGrace = opts.noGrace, before = function(state)
            state.class = class
            state.knownSpells = {}
            for _, id in pairs(opts.known or SPELLS[class]) do state.knownSpells[id] = true end
            state.units.player = { name = ME.name, surname = ME.surname, id = ME.id, isPlayer = true }
            if opts.before then opts.before(state) end
        end })
        if opts.on ~= false then ns.Requests.SetEnabled(true) end
        ns.db.debug = true -- the debug log says why a request wasn't queued
        button = ns.BuffButton.Frame()
    end

    -- A stranger the game shows (a nameplate), not flagged for PvP.
    local function stranger(token, spec)
        spec = spec or {}
        spec.name, spec.surname = spec.name or "Bob", spec.surname or "Stone"
        spec.class = spec.class or "PRIEST"
        spec.id = spec.name .. "-" .. spec.surname
        wow.addUnit(token or "nameplate1", spec)
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    -- What the button offers now: the player's name and spell, or nil.
    local function offered()
        local offer = ns.Offers.Current()
        return offer and offer.name, offer and offer.spell
    end

    local function printedLog(fragment)
        for _, line in ipairs(ns.db.diagLog) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end

    before_each(function() boot() end)

    describe("asking", function()
        it("common phrasings for each class's buffs queue the right buff, by whisper, /say and party chat", function()
            for class, buffs in pairs(ASKED) do
                for key, names in pairs(buffs) do
                    local spell = wow.SPELL_NAMES[SPELLS[class][key]]
                    for _, asked in ipairs(names) do
                        for i, framing in ipairs(FRAMINGS) do
                            local text = framing:format(asked)
                            if #text <= 64 then
                                boot({ class = class })
                                stranger()
                                local channel = i % 4
                                if channel == 0 then
                                    wow.whisper(text, "Bob-Stone")
                                elseif channel == 1 then
                                    wow.say(text, "Bob-Stone")
                                else
                                    wow.party(text, "Bob-Stone", channel == 3)
                                end
                                local name, given = offered()
                                local where = ("%s asked %s %q"):format(class, key, text)
                                assert.are.equal("Bob-Stone", name, where)
                                assert.are.equal(spell, given, where)
                            end
                        end
                    end
                end
            end
        end)

        it("shows them on the button, asking for that buff, and the press casts it on them", function()
            stranger()
            wow.whisper("thorns pls", "Bob-Stone")
            assert.is_true(button:IsShown())
            assert.are.equal("Bob Stone", button.title:GetText())
            assert.are.equal("asked for Thorns", button.subtitle:GetText())
            assert.is_truthy(macro():find("/targetexact Bob Stone", 1, true))
            assert.is_truthy(macro():find("/cast [help,nodead] Thorns", 1, true))
            assert.are.equal(0, #wow.casts, "a request never casts by itself")
            wow.press(button)
            assert.are.same({ spell = "Thorns", id = SPELLS.DRUID.thorns, target = "Bob-Stone" }, wow.casts[1])
            assert.are.equal("Gave Thorns to Bob Stone, who asked for it.", button.result:GetText())
            assert.are.equal(0, ns.Offers.Count(), "answered")
        end)

        it("says nothing in chat: no reply, no buff-back line, and no 'answers yours' to their copy", function()
            ns.db.buffBack.sayLine = true
            ns.db.buff.thankStyle = "whisper"
            stranger()
            wow.whisper("mark pls", "Bob-Stone")
            wow.press(button)
            wow.advance(30)
            assert.are.same({}, wow.sent)
            for _, s in ipairs(wow.addonSent) do
                assert.is_falsy(s.text:find(";ANSWER;", 1, true), "their copy isn't told it answers theirs")
            end
            assert.is_truthy(wow.addonSent[1].text:find(";RECEIPT;", 1, true), "only that it was you (#138)")
        end)

        it("their copy's 'this answers yours' can't let a request go", function()
            stranger()
            wow.whisper("mark pls", "Bob-Stone")
            ns.Offers.OnAnswerMark("Bob-Stone")
            assert.are.equal("Bob-Stone", (offered()))
        end)

        it("a member of your group asking in party chat is offered, found in their party slot", function()
            wow.setGroup("party", { "Ann-Vale" })
            wow.party("thorns pls", "Ann-Vale")
            assert.are.same({ "Ann-Vale", "Thorns" }, { offered() })
            assert.is_truthy(macro():find("/targetexact Ann Vale\n", 1, true))
            wow.press(button)
            assert.are.same({ spell = "Thorns", id = SPELLS.DRUID.thorns, target = "Ann-Vale" }, wow.casts[1])
        end)

        it("from the party's leader too", function()
            wow.setGroup("party", { "Ann-Vale" })
            wow.party("mark pls", "Ann-Vale", true)
            assert.are.same({ "Ann-Vale", "Mark of the Wild" }, { offered() })
        end)

        it("a group member the game doesn't show (another zone, out of sight) isn't offered", function()
            wow.setGroup("raid", { "Ann-Vale", "Cid-Moss" })
            wow.party("mark pls", "Ann-Vale")
            wow.zoneOut("raid1")
            assert.is_nil(offered())
            wow.zoneIn("raid1")
            assert.are.equal("Ann-Vale", (offered()))
            wow.state.units.raid1.secrets = { hidden = true }
            assert.is_nil(offered(), "whether they're shown can't be read")
        end)

        it("not raid, guild, officer, yell or channel chat", function()
            wow.setGroup("raid", { "Ann-Vale" })
            for _, event in ipairs({ "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
                "CHAT_MSG_YELL", "CHAT_MSG_CHANNEL", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_EMOTE" }) do
                wow.fire(event, "mark pls", "Ann-Vale", "Common", "", "Ann-Vale", "", 0, 0, "", 7, 1, "g", 0,
                    false, false, false, false)
            end
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("is the buff they asked for, not the one a favour would pick first", function()
            stranger()
            wow.say("thorns?", "Bob-Stone")
            assert.are.equal("Thorns", select(2, offered()))
        end)

        it("water breathing asked for is offered away from water, as they asked for it", function()
            boot({ class = "SHAMAN" })
            stranger()
            wow.whisper("wb pls", "Bob-Stone")
            assert.are.equal("Water Breathing", select(2, offered()))
        end)

        it("nothing for a buff they already wear; once it's gone, it's offered", function()
            stranger("nameplate1", { auras = { SPELLS.DRUID.motw } })
            wow.whisper("mark pls", "Bob-Stone")
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.is_truthy(why:find("they already have Mark of the Wild", 1, true))
            wow.state.units.nameplate1.auras = {}
            assert.are.equal("Mark of the Wild", select(2, offered()))
        end)

        it("the game's own spelling of the spell's name counts, in any language", function()
            boot({ class = "PRIEST" })
            local saved = {}
            for id in pairs({ [10938] = true, [10937] = true, [2791] = true, [1245] = true, [1244] = true,
                [1243] = true }) do
                saved[id] = wow.SPELL_NAMES[id]
                wow.SPELL_NAMES[id] = "Mot de pouvoir : Robustesse"
            end
            stranger()
            wow.whisper("Mot de pouvoir : Robustesse ?", "Bob-Stone")
            for id, name in pairs(saved) do wow.SPELL_NAMES[id] = name end
            assert.are.equal("Bob-Stone", (offered()))
        end)

        it("offers the buff they asked for when what they wear can't be read (hidden in a fight)", function()
            stranger("nameplate1", { auras = { SPELLS.DRUID.motw }, secrets = { auras = true } })
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal("Mark of the Wild", select(2, offered()))
        end)

        it("renews the buff they asked for when theirs is partly worn off", function()
            stranger("nameplate1", { auras = { SPELLS.DRUID.motw }, auraDurations = { 1800 },
                auraExpires = { wow.now + 60 } })
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal("Mark of the Wild", select(2, offered()))
        end)

        it("a water buff asked for isn't offered while the game says it can't reach them", function()
            boot({ class = "SHAMAN" })
            stranger("nameplate1", { outOfSpellRange = true })
            wow.whisper("wb pls", "Bob-Stone")
            local offer, why, everyoneLeft = ns.Offers.Current()
            assert.is_nil(offer)
            assert.is_true(everyoneLeft, "out of reach: it doesn't hold the button (#270)")
            wow.state.units.nameplate1.outOfSpellRange = nil
            assert.are.equal("everyone you owe is out of sight or out of range", why)
            assert.are.equal("Water Breathing", select(2, offered()))
        end)

        it("keeps the PvP rule: no offer to a flagged player unless you're flagged too", function()
            stranger("nameplate1", { pvp = true })
            wow.whisper("mark pls", "Bob-Stone")
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.is_truthy(why:find("PvP", 1, true))
            wow.state.pvp = true
            assert.is_table(ns.Offers.Current())
        end)

        it("doesn't hold the button while they're out of sight, and offers them once they're back", function()
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(1, ns.Offers.Count())
            assert.is_nil(ns.Offers.Current())
            stranger()
            assert.are.equal("Bob-Stone", (offered()))
        end)

        it("a request from someone owed a favour notes the buff they asked for, keeping its place", function()
            stranger()
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = 10157 })
            assert.are.equal("Mark of the Wild", select(2, offered()), "the favour's own choice")
            wow.whisper("thorns pls", "Bob-Stone")
            assert.are.equal(1, ns.Offers.Count())
            assert.are.equal(0, ns.Offers.RequestCount())
            assert.are.equal("Thorns", select(2, offered()))
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal("Thorns", select(2, offered()), "one request per player: the second doesn't replace it")
            assert.is_true(printedLog("they already have a request waiting"))
            ns.Requests.SetEnabled(false)
            assert.are.equal("Mark of the Wild", select(2, offered()), "turned off: the favour's own choice again")
            ns.Requests.SetEnabled(true)
            wow.whisper("thorns pls", "Bob-Stone")
            wow.press(button)
            assert.are.equal("Returned Thorns to Bob Stone.", button.result:GetText(), "a favour, returned")
            assert.are.equal("Thorns", ns.db.ledger.entries[1].returned)
        end)

        it("a request then a buff from them becomes a favour, still for the buff they asked for", function()
            stranger()
            wow.whisper("thorns pls", "Bob-Stone")
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = 10157 })
            assert.are.equal(1, ns.Offers.Count())
            assert.are.equal(0, ns.Offers.RequestCount())
            assert.are.equal("Thorns", select(2, offered()))
        end)

        it("a request answered by a cast by hand is answered too", function()
            stranger()
            wow.whisper("mark pls", "Bob-Stone")
            wow.addUnit("target", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "PRIEST" })
            wow.runMacro("/cast Mark of the Wild")
            assert.are.equal(1, #wow.casts)
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("right-click lets a request go", function()
            stranger()
            wow.whisper("mark pls", "Bob-Stone")
            wow.press(button, "RightButton")
            assert.are.equal(0, ns.Offers.Count())
            assert.are.equal(0, #wow.casts)
        end)
    end)

    describe("limits", function()
        it("one request per player: asking again never moves them up", function()
            stranger("nameplate1")
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            wow.whisper("mark pls", "Bob-Stone")
            wow.whisper("thorns pls", "Ann-Vale")
            wow.whisper("thorns pls", "Bob-Stone")
            assert.are.equal(2, ns.Offers.Count())
            assert.are.equal("Ann-Vale", (offered()), "the newest request first, as with favours")
            ns.Offers.LetGo("Ann-Vale")
            assert.are.equal("Mark of the Wild", select(2, offered()), "Bob's first request stands")
        end)

        it("expires like a favour: after the 'Offer for' minutes", function()
            ns.db.buffBack.owedMinutes = 2
            stranger()
            wow.whisper("mark pls", "Bob-Stone")
            wow.advance(119)
            assert.are.equal("Bob-Stone", (offered()))
            wow.advance(2)
            assert.is_nil(offered())
            assert.are.equal(0, ns.Offers.Count())
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal("Bob-Stone", (offered()), "and they may ask again")
        end)

        it("one that ran out while nothing looked (in a fight) doesn't block a fresh one", function()
            ns.db.buffBack.owedMinutes = 2
            stranger()
            wow.whisper("mark pls", "Bob-Stone")
            wow.enterCombat()
            wow.advance(150)
            wow.whisper("thorns pls", "Bob-Stone")
            wow.leaveCombat()
            assert.are.equal("Thorns", select(2, offered()), "the fresh request, not the old one")
        end)

        it("keeps at most MAX_REQUESTS waiting, the oldest going first", function()
            local max = ns.Offers.MAX_REQUESTS
            assert.are.equal(5, max)
            local names = { "Ann", "Bea", "Cal", "Dov", "Eda", "Fyn", "Gil" }
            for i, first in ipairs(names) do
                stranger("nameplate" .. i, { name = first, surname = "Moss" })
                wow.whisper("mark pls", first .. "-Moss")
            end
            assert.are.equal(max, ns.Offers.Count())
            local list = {}
            ns.Offers.Current(list)
            local who = {}
            for _, offer in ipairs(list) do who[#who + 1] = offer.name end
            assert.are.same({ "Gil-Moss", "Fyn-Moss", "Eda-Moss", "Dov-Moss", "Cal-Moss" }, who)
        end)

        it("favours, then requests, then more favours up to the button's limit: every favour stays", function()
            local function owe(i)
                local first = "Fav" .. string.char(96 + i)
                stranger("nameplate" .. i, { name = first, surname = "Owed" })
                wow.gainBuff({ sourceUnit = "nameplate" .. i, name = "Arcane Intellect", spellId = 10157 })
            end
            for i = 1, ns.Offers.MAX - ns.Offers.MAX_REQUESTS do owe(i) end
            for i = 1, ns.Offers.MAX_REQUESTS do
                local first = "Ask" .. string.char(96 + i)
                stranger("nameplate" .. (20 + i), { name = first, surname = "Late" })
                wow.whisper("mark pls", first .. "-Late")
            end
            assert.are.equal(ns.Offers.MAX_REQUESTS, ns.Offers.RequestCount())
            assert.are.equal(ns.Offers.MAX, ns.Offers.Count(), "full")
            for i = ns.Offers.MAX - ns.Offers.MAX_REQUESTS + 1, ns.Offers.MAX do owe(i) end
            assert.are.equal(ns.Offers.MAX, ns.Offers.Count())
            assert.are.equal(0, ns.Offers.RequestCount(), "each favour pushed out a request, oldest first")
            local list, owed = {}, {}
            ns.Offers.Current(list)
            for _, offer in ipairs(list) do owed[offer.name] = true end
            for i = 1, ns.Offers.MAX do
                assert.is_true(owed["Fav" .. string.char(96 + i) .. "-Owed"], "favour " .. i .. " stays")
            end
        end)

        it("with room for some, a new favour pushes out the oldest request first", function()
            for i = 1, 3 do
                local first = "Ask" .. string.char(96 + i)
                stranger("nameplate" .. (30 + i), { name = first, surname = "Early" })
                wow.whisper("mark pls", first .. "-Early")
            end
            for i = 1, ns.Offers.MAX - 2 do
                local first = "Fav" .. string.char(96 + i)
                stranger("nameplate" .. i, { name = first, surname = "Owed" })
                wow.gainBuff({ sourceUnit = "nameplate" .. i, name = "Arcane Intellect", spellId = 10157 })
            end
            assert.are.equal(ns.Offers.MAX, ns.Offers.Count())
            assert.are.equal(2, ns.Offers.RequestCount())
            local list, who = {}, {}
            ns.Offers.Current(list)
            for _, offer in ipairs(list) do who[offer.name] = true end
            assert.is_nil(who["Aska-Early"], "the oldest request went")
            assert.is_true(who["Askb-Early"] and who["Askc-Early"])
        end)

        it("never pushes a favour out, however many ask", function()
            for i = 1, ns.Offers.MAX do
                local first = "Fav" .. string.char(96 + i)
                stranger("nameplate" .. i, { name = first, surname = "Owed" })
                wow.gainBuff({ sourceUnit = "nameplate" .. i, name = "Arcane Intellect", spellId = 10157 })
            end
            assert.are.equal(ns.Offers.MAX, ns.Offers.Count())
            for i = 1, 30 do
                wow.whisper("mark pls", "Ask" .. string.char(96 + (i % 26) + 1) .. "-Many" .. string.char(97 + i % 3))
            end
            assert.are.equal(ns.Offers.MAX, ns.Offers.Count())
            assert.are.equal(0, ns.Offers.RequestCount())
            assert.is_true(printedLog("the button already holds as many as it keeps"))
        end)
    end)

    describe("exclusions", function()
        it("is off by default: no request is read, and the chat events aren't even registered", function()
            boot({ on = false })
            assert.is_false(ns.db.buffBack.requests)
            local registered = false
            for _, frame in ipairs(wow.frames) do
                if frame.events.CHAT_MSG_WHISPER or frame.events.CHAT_MSG_SAY then registered = true end
            end
            assert.is_false(registered)
            stranger()
            wow.whisper("mark pls", "Bob-Stone")
            ns.Requests.OnWhisper("mark pls", "Bob-Stone")
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("turning it off lets the waiting requests go, and stops listening", function()
            stranger()
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(1, ns.Offers.Count())
            ns.Options.OpenTab("buffBack", "buffRequests")
            local box = ns.Options.widgets.buffRequests
            assert.is_true(box:GetChecked())
            box:SetChecked(false)
            wow.run(box, "OnClick")
            assert.is_false(ns.db.buffBack.requests)
            assert.are.equal(0, ns.Offers.Count())
            assert.is_false(button:IsShown())
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(0, ns.Offers.Count())
            box:SetChecked(true)
            wow.run(box, "OnClick")
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(1, ns.Offers.Count())
        end)

        it("turned off by any other path, waiting requests go and don't come back when it's on again", function()
            local paths = {
                reset = function() ns.ResetType("buffBack") end,
                ["profile switch"] = function() ns.Profiles.Use("Quiet") end,
                ["master switch"] = function() ns.SetEnabled(false) end,
                ["Buff Back's switch"] = function()
                    ns.db.buffBack.enabled = false
                    ns.RefreshEvents()
                end,
            }
            for what, turnOff in pairs(paths) do
                boot()
                if what == "profile switch" then
                    ns.Profiles.New("Quiet")
                    ns.db.buffBack.requests = false
                    ns.Profiles.Use("Default")
                    assert.is_true(ns.db.buffBack.requests, what)
                end
                stranger()
                wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = 10157 })
                stranger("nameplate2", { name = "Ann", surname = "Vale" })
                wow.whisper("thorns pls", "Bob-Stone")
                wow.whisper("mark pls", "Ann-Vale")
                assert.are.equal(1, ns.Offers.RequestCount(), what)
                turnOff()
                assert.are.equal(0, ns.Offers.RequestCount(), what)
                assert.are.equal(1, ns.Offers.Count(), what .. ": the favour stays")
                if what == "master switch" then ns.SetEnabled(true) end
                if what == "Buff Back's switch" then ns.db.buffBack.enabled = true end
                ns.Requests.SetEnabled(true)
                assert.are.equal(0, ns.Offers.RequestCount(), what .. ": nothing comes back")
                assert.are.equal("Mark of the Wild", select(2, offered()),
                    what .. ": the favour's own choice, not the buff Bob asked for")
            end
        end)

        it("a setting turned off some other way (a profile, damage) holds nothing on the button", function()
            stranger()
            wow.whisper("mark pls", "Bob-Stone")
            ns.db.buffBack.requests = "yes"
            assert.is_nil(offered())
            wow.whisper("thorns pls", "Ann-Vale")
            assert.are.equal(1, ns.Offers.Count())
            ns.db.buffBack.requests = true
            assert.are.equal("Bob-Stone", (offered()))
        end)

        it("other settings changing (Buff Thanks, a profile that keeps requests on) keep waiting requests", function()
            stranger()
            wow.whisper("mark pls", "Bob-Stone")
            ns.db.buff.enabled = false
            ns.RefreshEvents()
            ns.db.buff.enabled = true
            ns.RefreshEvents()
            ns.Profiles.New("Raiding")
            ns.Profiles.Use("Default")
            ns.ResetType("buff")
            assert.are.equal(1, ns.Offers.RequestCount())
            assert.are.equal("Bob-Stone", (offered()))
        end)

        it("its checkbox saves to a repaired section when Buff Back's settings are damaged (#330)", function()
            ns.Options.OpenTab("buffBack", "buffRequests")
            local box = ns.Options.widgets.buffRequests
            for _, bad in ipairs({ 7, "x", true }) do
                ns.db.buffBack = bad
                box:SetChecked(false)
                wow.run(box, "OnClick")
                assert.are.same({}, wow.errors, tostring(bad))
                assert.are.equal("table", type(ns.db.buffBack))
                assert.is_false(ns.db.buffBack.requests)
                box:SetChecked(true)
                wow.run(box, "OnClick")
                assert.is_true(ns.db.buffBack.requests)
                wow.advance(2) -- past the repair's once-a-second limit
            end
        end)

        it("a favour's noted request is passed over while the setting is damaged", function()
            stranger()
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = 10157 })
            wow.whisper("thorns pls", "Bob-Stone")
            assert.are.equal("Thorns", select(2, offered()))
            ns.db.buffBack.requests = "yes"
            assert.are.equal("Mark of the Wild", select(2, offered()))
            ns.db.buffBack.requests = true
            assert.are.equal("Thorns", select(2, offered()))
        end)

        it("not with Buff Back's offer off, or the addon off", function()
            stranger()
            ns.db.buffBack.enabled = false
            ns.RefreshEvents()
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(0, ns.Offers.Count())
            ns.db.buffBack.enabled = true
            ns.SetEnabled(false)
            for _, frame in ipairs(wow.frames) do
                assert.is_nil(frame.events.CHAT_MSG_WHISPER, "the addon off: no chat is even read")
            end
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(0, ns.Offers.Count())
            ns.SetEnabled(true)
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(1, ns.Offers.Count())
        end)

        it("not from someone on your ignore list, and ignoring them drops theirs", function()
            stranger()
            ns.Ignore.Add("Bob-Stone")
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(0, ns.Offers.Count())
            assert.is_true(printedLog("on your ignore list"))
            ns.Ignore.Remove("Bob-Stone")
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(1, ns.Offers.Count())
            ns.Ignore.Add("Bob Stone")
            assert.are.equal(0, ns.Offers.Count())
            ns.Ignore.Remove("Bob Stone")
            wow.whisper("mark pls", "Bob-Stone")
            ns.Ignore.Add("bob stone")
            assert.is_nil(offered(), "ignored as typed in any case: nothing held")
        end)

        it("not while snoozed", function()
            stranger()
            ns.Announcer.Snooze(15)
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(0, ns.Offers.Count())
            ns.Announcer.Snooze(0)
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(1, ns.Offers.Count())
        end)

        it("not in a capital city while the button is hidden there; with it shown, or in buff mode, yes", function()
            stranger()
            wow.setMap(wow.CAPITAL.stormwind)
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(0, ns.Offers.Count())
            ns.db.buffBack.showInCities = true
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(1, ns.Offers.Count())
        end)

        it("not once a battleground's battle has started", function()
            stranger()
            wow.enterBattleground({}, { preparation = false })
            assert.is_true(ns.Battleground.Quiet())
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("not from yourself, and not in the moments after logging in", function()
            wow.say("mark pls", "Nikki-Shifts")
            assert.are.equal(0, ns.Offers.Count())
            boot({ noGrace = true })
            stranger()
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(0, ns.Offers.Count())
            wow.advance(ns.Announcer.LOGIN_GRACE)
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(1, ns.Offers.Count())
        end)
    end)

    describe("untrusted text", function()
        it("ignores junk, chat that merely mentions a buff, and text with more around the request", function()
            stranger()
            for _, text in ipairs({ "", " ", "pls", "?", "please please", "I'll mark the boss", "mark the skull pls",
                "mark pls and thorns", "lol mark", "marks pls", "mark mark", "can i get", "thorns pls :)",
                "mark pls 123", "m a r k", "mark_pls", "mark\tpls\0", "ma rk", "MARKPLS", "can you mark pls",
                "gimme mark", "mark pls pls pls", "any any mark", "any need mark", "need any mark", "buff pls", "buffs?", "wtb mark", "ty" }) do
                wow.whisper(text, "Bob-Stone")
                wow.say(text, "Bob-Stone")
                assert.are.equal(0, ns.Offers.Count(), ("%q"):format(text))
            end
        end)

        it("ignores very long text, even when it ends in a request", function()
            stranger()
            local long = string.rep(" ", 60) .. "mark pls"
            assert.is_true(#long > ns.Requests.MAX_TEXT_BYTES)
            wow.whisper(long, "Bob-Stone")
            wow.whisper(string.rep("mark ", 400) .. "pls", "Bob-Stone")
            wow.whisper(string.rep("a", 100000), "Bob-Stone")
            assert.are.equal(0, ns.Offers.Count())
            assert.are.same({}, wow.errors)
        end)

        it("ignores escape codes: links, colours, textures and raw pipes", function()
            stranger()
            for _, text in ipairs({ "|cffff0000mark|r pls", "|Hspell:9885|h[Mark of the Wild]|h pls",
                "|Tinterface\\icons\\spell_nature_regeneration:0|t pls", "mark pls|", "||mark pls",
                "|Hplayer:Bob-Stone|h[Bob]|h mark pls", "mark|npls" }) do
                wow.whisper(text, "Bob-Stone")
                assert.are.equal(0, ns.Offers.Count(), text)
            end
        end)

        it("ignores characters outside plain letters, whatever they spell", function()
            stranger()
            for _, text in ipairs({ "mårk pls", "mark pls \226\128\139", "\239\188\173ark pls", "mark\194\160pls",
                "mark%s pls", "mark.* pls", "(mark) pls", "[mark] pls", "%a+ pls", "^mark$" }) do
                wow.whisper(text, "Bob-Stone")
                assert.are.equal(0, ns.Offers.Count(), text)
            end
        end)

        it("ignores requests for buffs you don't have: another class's, unlearned, never offered", function()
            boot({ class = "MAGE" })
            stranger()
            for _, text in ipairs({ "mark pls", "fort pls", "kings pls", "thorns pls", "wb pls", "battle shout pls" }) do
                wow.whisper(text, "Bob-Stone")
            end
            assert.are.equal(0, ns.Offers.Count(), "a mage gives only Intellect")
            boot({ known = { motw = SPELLS.DRUID.motw } })
            stranger()
            wow.whisper("thorns pls", "Bob-Stone")
            assert.are.equal(0, ns.Offers.Count(), "Thorns not learned")
            ns.db.buffBack.neverOffer = { motw = true }
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal(0, ns.Offers.Count(), "Mark marked never offer")
        end)

        it("a buff marked never offer after the request isn't offered", function()
            stranger()
            wow.whisper("mark pls", "Bob-Stone")
            ns.db.buffBack.neverOffer = { motw = true }
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.is_truthy(why:find("which you don't offer", 1, true))
        end)

        it("a warrior's Battle Shout is never asked for: it reaches only your party", function()
            boot({ class = "WARRIOR" })
            stranger()
            for _, text in ipairs({ "battle shout pls", "Battle Shout", "shout pls", "bs pls" }) do
                wow.whisper(text, "Bob-Stone")
            end
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("ignores secret text and senders, and senders that aren't a whole player name", function()
            stranger()
            wow.whisper(wow.secret("mark pls"), "Bob-Stone")
            wow.whisper("mark pls", wow.secret("Bob-Stone"))
            for _, sender in ipairs({ "Bob", "", "Bob-", "-Stone", "Bob-Stone-Moss", "B-Stone", "Bob Stone Moss",
                "|cffBob|r-Stone", "Bob1-Stone", 42, {}, true }) do
                wow.whisper("mark pls", sender)
            end
            ns.Requests.OnWhisper(nil, nil)
            ns.Requests.OnSay(12, "Bob-Stone")
            assert.are.equal(0, ns.Offers.Count())
            assert.are.same({}, wow.errors)
            wow.whisper("mark pls", "Bob Stone")
            assert.are.equal("Bob-Stone", (offered()), "the space form is the same player")
        end)

        it("puts a name in the macro only through the usual checks", function()
            stranger("nameplate1", { name = "Bob", surname = "Stone" })
            wow.whisper("mark pls", "Bob-Stone")
            assert.is_truthy(macro():find("/targetexact Bob Stone\n", 1, true))
            for line in macro():gmatch("[^\n]+") do assert.is_falsy(line:find("pls", 1, true)) end
        end)
    end)

    describe("chaos", function()
        -- Word pools for the storm: pieces of real requests, and junk.
        local GOOD = { "mark", "thorns", "motw", "mark of the wild", "gotw", "Thorns" }
        local OTHER = { "int", "fort", "kings", "wb", "ub", "battle shout", "sprot", "might", "buff" }
        local LEADS = { "", "can i get ", "any ", "need ", "could i have ", "got " }
        local TAILS = { "", " pls", "?", " please ty", "!" }
        local JUNK = { "|cff", "|r", "|H", "|h", "\0", "\255", "%", "[", "(", ".*", "  ", "lol", "the", "boss", "123",
            "\226\128\139", "mark", "pls" }
        -- Ten who ask, ten who send junk, and twenty strangers who buff you
        -- (nameplates 1 to 40): with requests waiting, the favours fill the
        -- rest of the button's 20 entries, so a request taking a favour's room
        -- shows.
        local ASKERS, JUNKERS, BUFFERS = {}, {}, {}
        for _, first in ipairs({ "Ann", "Bea", "Cal", "Dov", "Eda", "Fyn", "Gil", "Hob", "Ira", "Jax" }) do
            ASKERS[#ASKERS + 1] = first .. "-Ask"
            JUNKERS[#JUNKERS + 1] = first .. "-Junk"
        end
        for _, first in ipairs({ "Kai", "Lea", "Mo", "Ned", "Oda", "Pip", "Quin", "Rue", "Sol", "Tam", "Uma", "Vic",
            "Wes", "Xan", "Yew", "Zed", "Ash", "Bly", "Cy", "Dun" }) do
            BUFFERS[#BUFFERS + 1] = first .. "-Buff"
        end

        -- A message, and whether it is a request for one of a druid's buffs.
        local function message()
            local roll = random.random(10)
            if roll <= 4 then
                return LEADS[random.random(#LEADS)] .. GOOD[random.random(#GOOD)] .. TAILS[random.random(#TAILS)], true
            elseif roll <= 6 then
                return LEADS[random.random(#LEADS)] .. OTHER[random.random(#OTHER)] .. TAILS[random.random(#TAILS)], false
            end
            -- "lol" first: no request starts so, whatever follows.
            local parts = { "lol" }
            for i = 2, random.random(1, 12) do parts[i] = JUNK[random.random(#JUNK)] end
            if random.random(4) == 1 then parts[#parts + 1] = string.rep("x", random.random(40, 300)) end
            return table.concat(parts, random.random(2) == 1 and " " or ""), false
        end

        -- On a whisper, /say, party chat or the party leader's line.
        local function send(text, sender)
            local channel = random.random(4)
            if channel == 1 then
                wow.whisper(text, sender)
            elseif channel == 2 then
                wow.say(text, sender)
            else
                wow.party(text, sender, channel == 4)
            end
        end

        -- The rows the player sees, read from the list's frames.
        local function shownRows()
            ns.BuffButton.Refresh()
            local shown = {}
            local list = ns.BuffList.Frame()
            for _, row in ipairs(list and list:IsShown() and ns.BuffList.Rows() or {}) do
                if row:IsShown() then shown[#shown + 1] = row.text:GetText() end
            end
            return shown
        end

        -- How many rows are askers', and which.
        local function asking(shown)
            local n, names = 0, {}
            for _, text in ipairs(shown) do
                local who = text:match("(%a+ Ask):")
                if who then
                    n = n + 1
                    names[who] = true
                end
            end
            return n, names
        end

        it("a storm of chat never errors, never casts, never queues a junk sender, never more than the limit, "
            .. "and never pushes out a favour", function()
            for _, seed in ipairs(STORM_SEEDS) do
                random.seed(seed)
                boot()
                ns.db.buff.enabled = false -- no thank-yous: the storm checks that requests say nothing
                -- Favours and requests last 20 minutes: long enough for the
                -- button to fill to its 20 entries, short enough that new
                -- strangers buff you while it's full.
                ns.db.buffBack.owedMinutes = 20
                local function place(list, from)
                    for i, name in ipairs(list) do
                        local first, surname = name:match("^(%a+)-(%a+)$")
                        stranger("nameplate" .. (from + i), { name = first, surname = surname })
                    end
                end
                place(ASKERS, 0)
                place(JUNKERS, 10)
                place(BUFFERS, 20)
                -- The storm's own record: when each stranger last buffed you.
                local buffedAt = {}
                local atLimit = 0 -- requests sent with five already listed
                local crowded = 0 -- buffs from someone new while 20 rows are listed, some of them requests
                for step = 1, 300 do
                    local where = ("seed %d, step %d"):format(seed, step)
                    local roll = random.random(40)
                    if roll <= 2 then
                        wow.advance(random.random(1, 400))
                    elseif roll == 3 then
                        ns.db.buffBack.requests = not ns.db.buffBack.requests
                        ns.RefreshEvents()
                    elseif roll == 4 then
                        ns.db.buffBack.requests = ({ "on", 1, {}, false, true })[random.random(5)]
                    elseif roll <= 6 then
                        local n = random.random(#ASKERS)
                        wow.whisper(wow.secret("mark pls"), ASKERS[n])
                    elseif roll <= 18 then
                        local n = random.random(#BUFFERS)
                        local shown = shownRows()
                        local listed = false
                        for _, text in ipairs(shown) do
                            if text:find((BUFFERS[n]:gsub("-", " ")) .. ":", 1, true) then listed = true end
                        end
                        if #shown == 20 and asking(shown) > 0 and not listed then crowded = crowded + 1 end
                        wow.gainBuff({ sourceUnit = "nameplate" .. (20 + n), name = "Arcane Intellect", spellId = 10157 })
                        buffedAt[BUFFERS[n]] = wow.now
                    else
                        local text, good = message()
                        local junker = not good or random.random(3) == 1
                        local sender = junker and JUNKERS[random.random(#JUNKERS)] or ASKERS[random.random(#ASKERS)]
                        if junker and good then text = text .. " " .. JUNK[random.random(#JUNK)] .. "x" end
                        if not junker and ns.db.buffBack.requests == true then
                            local n, names = asking(shownRows())
                            if n == 5 and not names[(sender:gsub("-", " "))] then atLimit = atLimit + 1 end
                        end
                        send(text, sender)
                    end
                    local shown = shownRows()
                    for _, text in ipairs(shown) do
                        assert.is_falsy(text:find("Junk", 1, true), where .. ": a junk sender is listed")
                    end
                    local requests = asking(shown)
                    assert.is_true(requests <= 5, where .. ": " .. requests .. " requests listed")
                    -- Every stranger who buffed you within the "Offer for" time
                    -- (less a second's margin) is still listed.
                    local limit = ns.db.buffBack.owedMinutes * 60 - 1
                    for name, at in pairs(buffedAt) do
                        if wow.now - at <= limit then
                            local listed = false
                            for _, text in ipairs(shown) do
                                if text:find((name:gsub("-", " ")) .. ":", 1, true) then listed = true end
                            end
                            assert.is_true(listed, where .. ": " .. name .. "'s favour is gone")
                        end
                    end
                    local armed = macro()
                    if armed then
                        assert.is_truthy(armed:find("/targetexact %a+ Ask\n") or armed:find("/targetexact %a+ Buff\n"),
                            where .. ": armed for " .. armed)
                    end
                    assert.are.equal(0, #wow.casts, where .. ": nothing casts without a press")
                    assert.are.same({}, wow.sent, where .. ": nothing is said")
                    assert.are.same({}, wow.errors, where)
                end
                assert.is_true(atLimit > 0, "seed " .. seed .. " never reached the limit of requests")
                assert.is_true(crowded > 0, "seed " .. seed .. " never had a stranger buff you while the button was full")
            end
        end)
    end)

    describe("the walkthrough's what's new", function()
        it("a returning player sees the step for buff requests, opening the switch, saying it's off", function()
            ns = wow.boot({ walkthrough = true, db = { enabled = true, walkthrough = { seen = 1, firstRun = false } } })
            local tour = ns.Walkthrough.Frame()
            assert.is_true(tour:IsShown())
            assert.is_true(ns.Walkthrough.WhatsNew())
            assert.are.equal("What's new: Buff requests in chat", tour.title:GetText())
            assert.are.equal("1 of 1", tour.count:GetText())
            assert.are.equal("buffBack", ns.Options.CurrentType())
            local text = tour.stepText:GetText()
            assert.is_truthy(text:find("never casts by itself", 1, true))
            assert.is_truthy(text:find(ns.Options.widgets.buffRequests.label:GetText(), 1, true),
                "names the switch as its checkbox does")
            assert.is_truthy(text:find("It's " .. ns.Colours.Text("bad", "off") .. " now", 1, true))
            assert.is_false(ns.db.buffBack.requests, "it only shows: it changes no setting")
            wow.run(tour.next, "OnClick")
            assert.are.equal(ns.Config.WALKTHROUGH_VERSION, ns.db.walkthrough.seen)
        end)

        it("its title fits the window's title line", function()
            for _, step in ipairs(ns.Walkthrough.STEPS) do
                if step.title == "Buff requests in chat" then
                    assert.is_true(#step.title <= 35)
                    return
                end
            end
            error("no step for buff requests")
        end)
    end)

    describe("saved settings", function()
        it("is off by default, and a damaged value loads as off", function()
            boot({ on = false })
            assert.is_false(ns.db.buffBack.requests)
            for _, bad in ipairs({ "yes", 1, {}, 0 / 0 }) do
                boot({ on = false, db = { buffBack = { requests = bad } } })
                assert.is_false(ns.db.buffBack.requests, tostring(bad))
            end
            boot({ on = false, db = { buffBack = { requests = true } } })
            assert.is_true(ns.db.buffBack.requests)
        end)

        it("is in the settings search", function()
            local found = false
            for _, entry in ipairs(ns.OptionsIndex.SETTINGS) do
                for _, control in ipairs(entry.controls) do
                    if control == "buffRequests" then found = true end
                end
            end
            assert.is_true(found)
        end)
    end)
end)
