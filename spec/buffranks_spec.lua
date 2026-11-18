-- Spec: #459
-- The rank a player's level allows (#459, the owner's decision of 17 Nov):
-- a buff for another player is cast by name and rank, the highest rank you
-- know whose level (Forever's SpellLevels data) is at most theirs + 10. A
-- player whose level the game won't give is skipped, with the reason; one
-- too low for every rank of a buff gets your next buff. After any refusal by
-- the game, the button leaves that player for a while.
--
-- The expected ranks are worked out here from the simulated client's own
-- copy of the levels (wow.SPELL_LEVEL, read from the committed data file)
-- and its spell names, never from BuffTable.lua or BuffData.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

-- Mark of the Wild, highest rank first: rank 7 (level 60) to rank 1 (level 1).
local MOTW = { 9885, 9884, 8907, 5234, 6756, 5232, 1126 }
local THORNS = { 9910, 9756, 8914, 1075, 782, 467 }
local FORT = { 10938, 10937, 2791, 1245, 1244, 1243 }
local SPIRIT = { 27841, 14819, 14818, 14752 }
local KINGS = 20217
local INTELLECT = 10157

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Buffing a player with the rank their level allows (#459)", function()
    local ns, button

    -- A class who knows `known` (spell IDs), in buff mode unless opts.noMode.
    local function boot(known, opts)
        opts = opts or {}
        ns = wow.boot({ buffSelf = opts.buffSelf, defaultLevel = opts.defaultLevel, autoBuffMode = opts.auto,
            before = function(state)
            state.class = opts.class or "DRUID"
            state.knownSpells = {}
            for _, id in ipairs(known) do state.knownSpells[id] = true end
            if opts.before then opts.before(state) end
        end })
        button = ns.BuffButton.Frame()
        if opts.passersBy then ns.db.buffBack.passersBy = true end
        if not opts.noMode then slash("buffmode on") end
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end
    local function lastCast() return wow.casts[#wow.casts] end

    -- What the armed button casts on someone else: "Name: Spell(Rank n)".
    local function armed()
        ns.PassersBy.Fresh()
        ns.BuffButton.Refresh()
        local text = macro()
        if not text then return nil end
        local who = text:match("/targetexact ([^\n]+)")
        local spell = text:match("/cast %[help,nodead%] ([^\n]+)")
        assert(who and spell, "not a cast on someone else: " .. text)
        return who .. ": " .. spell
    end

    -- The rank of `ids` (highest first) the server allows a player of `level`,
    -- of those known: the expected cast, from the client's own data.
    local function expectedRank(ids, level)
        for i, id in ipairs(ids) do
            if wow.state.knownSpells[id] and level + wow.LEVEL_MARGIN >= wow.SPELL_LEVEL[id] then
                return id, #ids - i + 1
            end
        end
    end

    local function party(names, levels)
        wow.setGroup("party", names)
        for i, level in ipairs(levels or {}) do wow.state.units["party" .. i].level = level end
    end

    local function stranger(token, name, surname, spec)
        spec = spec or {}
        spec.name, spec.surname, spec.id = name, surname, name .. "-" .. surname
        spec.class = spec.class or "WARRIOR"
        spec.auras = spec.auras or {}
        wow.addUnit(token, spec)
        return wow.state.units[token]
    end

    describe("choosing the rank (white)", function()
        it("casts the highest rank a group member's level allows, by name and rank, and the game takes it", function()
            boot(MOTW)
            party({ "Ann-Vale" }, { 45 })
            assert.are.equal("Ann Vale: Mark of the Wild(Rank 6)", armed(), "rank 6 is level 50, within 45 + 10")
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(9884, lastCast().id)
            assert.is_nil(lastCast().failed)
        end)

        it("follows the rule at its edge: level 50 takes rank 7 (60), level 49 rank 6 (50)", function()
            for level, rank in pairs({ [50] = 7, [49] = 6, [40] = 6, [39] = 5, [10] = 3, [9] = 2, [1] = 2 }) do
                boot(MOTW)
                party({ "Ann-Vale" }, { level })
                -- Your highest rank by its plain name; a lower one named (the owner, #459).
                local want = rank == 7 and "Ann Vale: Mark of the Wild" or ("Ann Vale: Mark of the Wild(Rank " .. rank .. ")")
                assert.are.equal(want, armed(), "level " .. level)
                wow.pressKey("MOUSEWHEELUP")
                assert.is_nil(lastCast().failed, "level " .. level)
            end
        end)

        it("only ranks you know: a druid who knows ranks 1 to 3 casts rank 3 on a level-60 player", function()
            boot({ MOTW[5], MOTW[6], MOTW[7] })
            party({ "Ann-Vale" }, { 60 })
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "rank 3, your highest: its plain name casts it")
        end)

        it("a favour returned to a low-level stranger, and a passer-by, get their rank too", function()
            boot(MOTW, { passersBy = true })
            stranger("nameplate1", "Bob", "Stone", { level = 12 })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            assert.are.equal("Bob Stone: Mark of the Wild(Rank 3)", armed(), "a favour: rank 3 is level 20, within 22")
            wow.press(button)
            assert.are.same({ 6756, "Bob-Stone" }, { lastCast().id, lastCast().target })
            assert.is_nil(lastCast().failed)
            wow.wearBuff("nameplate1", 6756, { source = "player" })
            stranger("nameplate2", "Cid", "Rock", { level = 25 })
            assert.are.equal("Cid Rock: Mark of the Wild(Rank 4)", armed(), "a passer-by: rank 4 is level 30, within 35")
            wow.press(button)
            assert.are.same({ 5234, "Cid-Rock" }, { lastCast().id, lastCast().target })
        end)

        it("your own copy in buff mode is your highest rank, by name and rank", function()
            boot(MOTW, { buffSelf = true })
            party({ "Ann-Vale" }, { 60 })
            wow.state.units.player.level = 1 -- your own level is never read for your copy
            ns.BuffButton.Refresh()
            assert.are.equal("/cast [@player,nodead] Mark of the Wild", macro(), "your highest rank, by its plain name")
        end)

        it("your own copy before a group version for another subgroup is your highest rank too", function()
            local AI = { 10157, 10156, 1461, 1460, 1459 }
            local known = { 23028 }
            for _, id in ipairs(AI) do known[#known + 1] = id end
            boot(known, { class = "MAGE", buffSelf = true, before = function(state)
                state.items = { [wow.ITEM.arcanePowder] = 5 }
            end })
            wow.setGroup("raid", { "Ann-Vale", "Bo-Fern", "Cid-Rock" })
            for i = 1, 3 do wow.state.units["raid" .. i].class = "MAGE" end
            -- You're in subgroup 2, so Arcane Brilliance for subgroup 1 doesn't cover you.
            wow.state.units.player.subgroup = 2
            wow.state.units.player.level = 1 -- your own level is never read for your copy
            ns.BuffButton.Refresh()
            assert.are.equal("/cast [@player,nodead] Arcane Intellect", macro())
        end)

        it("a buff of one rank is cast by its name alone: Blessing of Kings", function()
            boot({ KINGS }, { class = "PALADIN" })
            party({ "Ann-Vale" }, { 10 })
            assert.are.equal("Ann Vale: Blessing of Kings", armed(), "level 20 is within 10 + 10")
            wow.pressKey("MOUSEWHEELUP")
            assert.are.same({ KINGS, false }, { lastCast().id, lastCast().failed or false })
        end)

        it("every buff for others, at every level from 1 to 60, is the rank the data allows, and the game takes it",
            function()
            local classes = {
                { "DRUID", { MOTW, THORNS } },
                { "PRIEST", { FORT, SPIRIT } },
            }
            for _, case in ipairs(classes) do
                local known = {}
                for _, ids in ipairs(case[2]) do for _, id in ipairs(ids) do known[#known + 1] = id end end
                for level = 1, 60 do
                    boot(known, { class = case[1] })
                    party({ "Ann-Vale" }, { level })
                    wow.state.units.party1.class = "MAGE"
                    local given = 0
                    for _ = 1, #case[2] + 1 do
                        local before = #wow.casts
                        wow.pressKey("MOUSEWHEELUP")
                        local cast = wow.casts[before + 1]
                        if not cast then break end
                        local ids
                        for _, list in ipairs(case[2]) do
                            if wow.SPELL_NAMES[list[1]] == cast.spell then ids = list end
                        end
                        local want = expectedRank(ids, level)
                        assert.are.equal(want, cast.id, case[1] .. " " .. cast.spell .. " at level " .. level)
                        assert.is_nil(cast.failed, cast.spell .. " at level " .. level)
                        wow.wearBuff("party1", cast.id, { source = "player" })
                        given = given + 1
                    end
                    for _, ids in ipairs(case[2]) do
                        if not expectedRank(ids, level) then
                            -- Too low for every rank: not cast, and said.
                            for _, c in ipairs(wow.casts) do
                                assert.are_not.equal(wow.SPELL_NAMES[ids[1]], c.spell, "level " .. level)
                            end
                        end
                    end
                    assert.is_true(given >= 1, case[1] .. " at level " .. level)
                end
            end
        end)
    end)

    describe("a player too low for every rank (white)", function()
        it("gets your next buff, and the button says why not the first", function()
            boot({ SPIRIT[4], FORT[1], FORT[2], FORT[3], FORT[4], FORT[5], FORT[6] }, { class = "PRIEST" })
            ns.db.buffBack.buffOrder = { "spirit", "fortitude" }
            party({ "Ann-Vale" }, { 19 })
            wow.state.units.party1.class = "MAGE"
            assert.are.equal("Ann Vale: Power Word: Fortitude(Rank 3)", armed(),
                "Divine Spirit rank 1 is level 30, beyond 19 + 10; Fortitude rank 3 is level 24")
            wow.pressKey("MOUSEWHEELUP")
            wow.wearBuff("party1", FORT[4], { source = "player" })
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.is_truthy(button.subtitle:GetText():find("Ann Vale: they're too low level for your Divine Spirit",
                1, true), button.subtitle:GetText())
        end)

        it("doesn't hold buff mode on: a member who can't have it yet isn't missing it (#272)", function()
            boot({ SPIRIT[4] }, { class = "PRIEST", noMode = true })
            ns.db.buffBack.autoOnMissing = true
            party({ "Ann-Vale" }, { 19 })
            wow.state.units.party1.class = "MAGE"
            local list = ns.GroupBuffs.Missing()
            assert.are.equal(0, #list, "nothing she can have is missing")
            local offer, _, settled = ns.GroupBuffs.Next()
            assert.is_nil(offer)
            assert.is_true(settled, "settled until she levels up")
            wow.state.units.party1.level = 20
            assert.are.equal(1, #ns.GroupBuffs.Missing(), "at 20, rank 1 reaches her")
        end)

        it("a favour too low for every buff of yours turns nothing on when the button can't look: in a fight, "
            .. "or unlocked for moving", function()
            for _, when in ipairs({ "fight", "unlocked" }) do
                boot({ KINGS, 19742 }, { class = "PALADIN", noMode = true, auto = true })
                for _, field in ipairs(wow.TURN_ON_TRIGGERS) do ns.db.buffBack[field] = field == "autoOnBuffed" end
                stranger("nameplate1", "Bob", "Stone", { level = 3, class = "PRIEST" })
                if when == "unlocked" then assert.is_true(ns.BuffButton.SetUnlocked(true)) end
                local turnedOn = 0
                local set = ns.BuffMode.Set
                ns.BuffMode.Set = function(on, how)
                    if on then turnedOn = turnedOn + 1 end
                    return set(on, how)
                end
                if when == "fight" then wow.enterCombat() end
                wow.gainBuff({ sourceUnit = "nameplate1", name = "Power Word: Fortitude", spellId = FORT[6] })
                if when == "fight" then wow.leaveCombat() end
                ns.BuffMode.Set = set
                assert.are.equal(0, turnedOn, when .. ": the favour was weighed as it was owed")
                assert.are.equal(0, ns.Offers.Count(), when)
            end
        end)

        it("a favour whose rank can't be named (its level readable) is still counted: not settled", function()
            boot(MOTW, { noMode = true, before = function(state) state.noSpellSubtext = true end })
            stranger("nameplate1", "Bob", "Stone", { level = 30 })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            local _, why = ns.Offers.Current()
            assert.are.equal("Bob Stone: the game won't name the rank of Mark of the Wild", why)
            assert.are.equal(1, ns.Offers.Count(), "not too low: the game only won't name the rank now")
        end)

        it("a favour too low for every buff of yours isn't counted and turns nothing on, until they level up",
            function()
            -- A paladin's Kings is level 20 and Wisdom rank 1 level 14: a level-3 player can have neither.
            boot({ KINGS, 19742 }, { class = "PALADIN", noMode = true, auto = true })
            for _, field in ipairs(wow.TURN_ON_TRIGGERS) do ns.db.buffBack[field] = field == "autoOnBuffed" end
            local bob = stranger("nameplate1", "Bob", "Stone", { level = 3, class = "PRIEST" })
            local turnedOn = 0
            local set = ns.BuffMode.Set
            ns.BuffMode.Set = function(on, how)
                if on then turnedOn = turnedOn + 1 end
                return set(on, how)
            end
            finally(function() ns.BuffMode.Set = set end)
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Power Word: Fortitude", spellId = FORT[6] })
            ns.BuffMode.Set = set
            assert.is_false(ns.BuffMode.IsOn(), "buffed by a stranger, but nothing of yours reaches him")
            assert.are.equal(0, turnedOn, "not even for a moment: the key is never lent for him")
            assert.are.equal(0, ns.Offers.Count(), "not counted (#366's lesson)")
            assert.is_nil(armed())
            local _, why = ns.Offers.Current()
            assert.are.equal("Bob Stone: they're too low level for your Blessing of Kings", why)
            -- He levels up: Kings reaches a level-10 player.
            bob.level = 10
            assert.are.equal(1, ns.Offers.Count(), "counted again")
            slash("buffmode on")
            assert.are.equal("Bob Stone: Blessing of Kings", armed())
        end)
    end)

    describe("favours, requests and passers-by", function()
        it("a request from a low-level player gets the rank their level allows (white)", function()
            boot(MOTW, { noMode = true })
            ns.Requests.SetEnabled(true)
            stranger("nameplate1", "Bob", "Stone", { level = 5 })
            wow.whisper("mark pls", "Bob-Stone")
            assert.are.equal("Bob Stone: Mark of the Wild(Rank 2)", armed(), "rank 2 is level 10, within 5 + 10")
            wow.press(button)
            assert.are.same({ 5232, "Bob-Stone" }, { lastCast().id, lastCast().target })
            assert.is_nil(lastCast().failed)
        end)

        it("a request for a buff no rank of which their level allows says so, isn't counted, and casts nothing "
            .. "(black)", function()
            boot({ SPIRIT[4] }, { class = "PRIEST", noMode = true })
            ns.Requests.SetEnabled(true)
            stranger("nameplate1", "Bob", "Stone", { level = 5, class = "MAGE" })
            wow.whisper("divine spirit pls", "Bob-Stone")
            local _, why = ns.Offers.Current()
            assert.are.equal("Bob Stone: they're too low level for your Divine Spirit", why)
            assert.are.equal(0, ns.Offers.Count(), "nothing to give him: not counted")
            assert.is_nil(armed())
            wow.press(button)
            assert.are.equal(0, #wow.casts)
        end)

        it("a favour or a passer-by whose level the game won't give is offered nothing, and says why (black)",
            function()
            boot(MOTW, { noMode = true })
            stranger("nameplate1", "Bob", "Stone", { level = 40, secrets = { level = true } })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            assert.is_nil(armed())
            assert.is_truthy(table.concat(ns.BuffButton.StatusLines(), "\n")
                :find("Bob Stone: can't see their level", 1, true))
            assert.are.equal(1, ns.Offers.Count(), "still counted: he may yet have one (not too low, unknown)")

            boot(MOTW, { passersBy = true })
            stranger("nameplate1", "Bob", "Stone", { level = -1 })
            stranger("nameplate2", "Cid", "Rock", { level = 30 })
            assert.are.equal("Cid Rock: Mark of the Wild(Rank 5)", armed(), "Bob's \"??\" passes him over")
            wow.press(button)
            wow.wearBuff("nameplate2", lastCast().id, { source = "player" })
            assert.is_nil(armed(), "Bob is never offered")
            assert.are.equal(1, #wow.casts)
        end)

        it("a passer-by too low for every rank of your first buff is offered your next (white)", function()
            boot({ SPIRIT[4], FORT[6] }, { class = "PRIEST", passersBy = true })
            ns.db.buffBack.buffOrder = { "spirit", "fortitude" }
            stranger("nameplate1", "Bob", "Stone", { level = 8, class = "MAGE" })
            assert.are.equal("Bob Stone: Power Word: Fortitude", armed(), "rank 1, the only one known")
        end)

        it("a group member whose level can't be read keeps buff mode waiting: not settled (black)", function()
            boot(MOTW, { defaultLevel = false })
            party({ "Ann-Vale" })
            local offer, why, settled = ns.GroupBuffs.Next()
            assert.is_nil(offer)
            assert.are.equal("Ann Vale: can't see their level", why)
            assert.is_false(settled, "she may still need it")
        end)
    end)

    describe("what can't be read (black)", function()
        it("a level the game won't give as a whole number from 1 to 80 offers that player nothing, "
            .. "says why, and moves on", function()
            local cases = {
                secret = function(u) u.level = 40 u.secrets = { level = true } end,
                missing = function(u) u.level = nil end,
                ["?? (-1)"] = function(u) u.level = -1 end,
                zero = function(u) u.level = 0 end,
                fraction = function(u) u.level = 40.5 end,
                huge = function(u) u.level = 81 end,
                infinite = function(u) u.level = math.huge end,
                nan = function(u) u.level = 0 / 0 end,
                text = function(u) u.level = "40" end,
                table = function(u) u.level = {} end,
            }
            for how, damage in pairs(cases) do
                boot(MOTW, { defaultLevel = false })
                party({ "Ann-Vale", "Cid-Rock" }, { 60, 60 })
                damage(wow.state.units.party1)
                assert.are.equal("Cid Rock: Mark of the Wild", armed(), how)
                wow.pressKey("MOUSEWHEELUP")
                wow.wearBuff("party2", MOTW[1], { source = "player" })
                assert.is_nil(armed(), how .. ": Ann is never offered")
                assert.is_truthy(button.subtitle:GetText():find("Ann Vale: can't see their level", 1, true),
                    how .. ": " .. tostring(button.subtitle:GetText()))
                assert.are.same({}, wow.errors, how)
            end
        end)

        it("UnitLevel raising an error offers nothing, and raises nothing", function()
            boot(MOTW)
            party({ "Ann-Vale" }, { 60 })
            local real = _G.UnitLevel
            _G.UnitLevel = function() error("boom") end
            finally(function() _G.UnitLevel = real end)
            assert.is_nil(armed())
            assert.are.same({}, wow.errors)
        end)

        it("a rank text the game won't give (none, empty, a secret) steps down for nobody, and never stops your "
            .. "highest rank (the owner, #459)", function()
            for _, how in ipairs({ "none", "empty", "secret" }) do
                boot(MOTW, { before = function(state)
                    if how == "none" then state.noSpellSubtext = true end
                    if how == "secret" then state.secretSubtext = true end
                    if how == "empty" then
                        state.spellSubtexts = {}
                        for _, id in ipairs(MOTW) do state.spellSubtexts[id] = "" end
                    end
                end })
                party({ "Ann-Vale" }, { 30 })
                assert.is_nil(armed(), how .. ": rank 5 can't be named")
                assert.is_truthy(button.subtitle:GetText():find("won't name the rank of Mark of the Wild", 1, true), how)
                wow.pressKey("MOUSEWHEELUP")
                assert.are.equal(0, #wow.casts, how)
                wow.state.units.party1.level = 60
                assert.are.equal("Ann Vale: Mark of the Wild", armed(), how .. ": your highest needs no rank text")
                wow.pressKey("MOUSEWHEELUP")
                assert.are.same({ MOTW[1], false }, { lastCast().id, lastCast().failed or false }, how)
            end
        end)

        it("only C_Spell.GetSpellSubtext missing: the older GetSpellSubtext names the rank", function()
            boot(MOTW)
            party({ "Ann-Vale" }, { 45 })
            _G.C_Spell.GetSpellSubtext = nil
            assert.are.equal("Ann Vale: Mark of the Wild(Rank 6)", armed())
        end)

        it("an offer to a player with no ranked name is never put on the button", function()
            boot(MOTW)
            local buff = ns.BuffData.ByKey("motw")
            assert.is_nil(ns.BuffButton.MacroFor({ name = "Ann-Vale", buff = buff, spell = "Mark of the Wild" }, false))
            assert.is_nil(ns.BuffButton.MacroFor({ name = "Me-Self", buff = buff, spell = "Mark of the Wild",
                group = true, self = true }, false), "nor your own group copy")
            assert.are.equal("/cleartarget\n/targetexact Ann Vale\n/cast [help,nodead] Mark of the Wild(Rank 2)\n"
                .. "/cleartarget", ns.BuffButton.MacroFor({ name = "Ann-Vale", buff = buff, spell = "Mark of the Wild",
                castSpell = "Mark of the Wild(Rank 2)" }, false))
        end)

        it("BuffData.CastFor reads nothing it shouldn't: no levels in the table, no unit, a secret unit", function()
            boot(MOTW)
            local buff = ns.BuffData.ByKey("motw")
            local copy = {}
            for k, v in pairs(buff) do copy[k] = v end
            copy.levels = nil
            party({ "Ann-Vale" }, { 60 })
            local cast, why, low = ns.BuffData.CastFor(copy, "party1")
            assert.are.same({ nil, false }, { cast, low })
            assert.is_truthy(why:find("aren't known", 1, true))
            assert.are.same({ nil, "can't see their level", false }, { ns.BuffData.CastFor(buff, nil) })
            assert.are.same({ nil, "can't see their level", false }, { ns.BuffData.CastFor(buff, "nameplate9") })
            assert.are.same({ "Mark of the Wild", MOTW[1] }, { ns.BuffData.CastFor(buff, nil, true) })
            party({ "Ann-Vale" }, { 45 })
            assert.are.same({ "Mark of the Wild(Rank 6)", MOTW[2] }, { ns.BuffData.CastFor(buff, "party1") })
            wow.state.units.party1.level = 60
            assert.are.same({ "Mark of the Wild", MOTW[1] }, { ns.BuffData.CastFor(buff, "party1") })
        end)
    end)

    describe("after a refusal (#459: any refusal)", function()
        it("a group member refused for any reason waits, the next press goes to the next member, and they "
            .. "come back after the wait (white)", function()
            for _, why in ipairs({ "Target is too low level", "Spell is not ready yet.", "Not enough mana" }) do
                boot(MOTW)
                party({ "Ann-Vale", "Cid-Rock" }, { 60, 60 })
                wow.state.castFailures["Ann-Vale"] = why
                wow.pressKey("MOUSEWHEELUP")
                assert.are.equal("Cid Rock: Mark of the Wild", armed(), why)
                wow.state.castFailures["Ann-Vale"] = nil
                wow.advance(ns.GroupBuffs.HELD_BACK_SECONDS + 1)
                assert.are.equal("Ann Vale: Mark of the Wild", armed(), why .. ": back after the wait")
            end
        end)

        it("a passer-by and a favour refused wait too (white)", function()
            boot(MOTW, { passersBy = true })
            stranger("nameplate1", "Bob", "Stone")
            stranger("nameplate2", "Cid", "Rock")
            wow.state.castFailures["Bob-Stone"] = "Spell is not ready yet."
            assert.are.equal("Bob Stone: Mark of the Wild", armed())
            wow.press(button)
            assert.are.equal("Cid Rock: Mark of the Wild", armed(), "the passer-by waits")

            boot(MOTW, { noMode = true })
            stranger("nameplate1", "Bob", "Stone")
            stranger("nameplate2", "Cid", "Rock")
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
            wow.state.castFailures["Cid-Rock"] = "Target is too low level"
            assert.are.equal("Cid Rock: Mark of the Wild", armed(), "the newest favour first")
            wow.press(button)
            assert.are.equal("Bob Stone: Mark of the Wild", armed(), "Cid's favour waits")
            assert.are.equal(2, ns.Offers.Count(), "and is still owed")
            wow.state.castFailures["Cid-Rock"] = nil
            wow.advance(ns.Offers.HELD_BACK_SECONDS + 1)
            assert.are.equal("Cid Rock: Mark of the Wild", armed(), "back after the wait")
        end)

        it("one favour, refused: the button says why it waits, and nothing is cast meanwhile (black)", function()
            boot(MOTW, { noMode = true })
            stranger("nameplate1", "Bob", "Stone")
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            wow.state.castFailures["Bob-Stone"] = "Interrupted"
            wow.press(button)
            local casts = #wow.casts
            wow.press(button)
            assert.are.equal(casts, #wow.casts)
            ns.BuffButton.Refresh()
            local status = table.concat(ns.BuffButton.StatusLines(), "\n")
            assert.is_truthy(status:find("Bob Stone: the game refused your last cast to them", 1, true), status)
        end)
    end)

    describe("chaos (red)", function()
        it("a storm of levels, known ranks, refusals and presses never casts a rank the level forbids, never casts "
            .. "on anyone else without naming the rank, and never errors", function()
            local casts, ranked, plain = 0, 0, 0
            for seed = 1, 8 do
                random.seed(seed)
                local known = {}
                for _, id in ipairs(MOTW) do
                    if random.random() < 0.6 then known[#known + 1] = id end
                end
                known[#known + 1] = THORNS[6]
                boot(known, { passersBy = true, defaultLevel = false })
                party({ "Ann-Vale", "Cid-Rock", "Dee-Moss" })
                stranger("nameplate1", "Bob", "Stone")
                -- A level, or none, -1 ("??") or a secret one.
                local function setLevel(u)
                    local roll = random.random(1, 10)
                    u.secrets = nil
                    if roll == 1 then
                        u.level = nil
                    elseif roll == 2 then
                        u.level = -1
                    else
                        u.level = random.random(1, 60)
                        if roll == 3 then u.secrets = { level = true } end
                    end
                end
                for step = 1, 80 do
                    local roll = random.random(1, 8)
                    local tokens = { "party1", "party2", "party3", "nameplate1" }
                    local u = wow.state.units[tokens[random.random(1, 4)]]
                    if roll == 1 then
                        setLevel(u)
                    elseif roll == 2 then
                        u.auras = {}
                    elseif roll == 3 then
                        wow.state.castFailures[u.id] = random.random(1, 2) == 1 and "Spell is not ready yet." or nil
                    elseif roll == 4 then
                        wow.advance(random.random(1, 20))
                    else
                        local before = #wow.casts
                        wow.pressKey("MOUSEWHEELUP")
                        local text = macro()
                        local c = wow.casts[before + 1]
                        if c and c.target ~= wow.state.units.player.id then
                            casts = casts + 1
                            -- Independently: the target's real level, and the rank's.
                            local target
                            for _, t in pairs(wow.state.units) do if t.id == c.target then target = t end end
                            local level = target.level
                            assert.is_true(type(level) == "number" and level >= 1
                                and not (target.secrets and target.secrets.level),
                                ("seed %d, step %d: cast on %s, whose level was unreadable"):format(seed, step, c.target))
                            assert.is_true(level + 10 >= wow.SPELL_LEVEL[c.id],
                                ("seed %d, step %d: rank %d on level %d"):format(seed, step, c.id, level))
                            assert.are_not.equal(wow.LOW_LEVEL_ERROR, c.failed)
                        end
                        if text and text:find("/cast %[help") then
                            -- Named only when stepping down (the owner, #459): a
                            -- named rank is never your highest; a plain name casts it.
                            local spell = text:match("/cast %[help,nodead%] ([^\n]+)")
                            local named = tonumber(spell:match("%(Rank (%d+)%)$"))
                            local highest
                            for i, id in ipairs(MOTW) do
                                if not highest and wow.state.knownSpells[id] then highest = #MOTW - i + 1 end
                            end
                            if named then
                                assert.is_true(spell:find("^Mark of the Wild") ~= nil and named < highest,
                                    ("seed %d, step %d: %s named, your highest is rank %s"):format(seed, step, spell,
                                    tostring(highest)))
                                ranked = ranked + 1
                            else
                                plain = plain + 1
                            end
                        end
                    end
                    ns.BuffButton.Refresh()
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
            assert.is_true(casts >= 20, "the storm cast " .. casts .. " times")
            assert.is_true(ranked >= 10, "named ranks: " .. ranked)
            assert.is_true(plain >= 10, "plain names: " .. plain)
        end)
    end)
end)
