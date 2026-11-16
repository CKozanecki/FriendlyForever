-- Spec: #39
-- Passers-by: in buff mode, the button also offers your buffs to players on a
-- nameplate who aren't in your group, haven't buffed you and haven't asked.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

-- Mark of the Wild (rank 1 and the top rank), Gift of the Wild, Thorns.
local MOTW_1, MOTW, GIFT, THORNS_1, THORNS = 1126, 9885, 21850, 467, 9910
local INTELLECT = 10157

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Passers-by (#39)", function()
    local ns, button

    -- A druid who knows Mark of the Wild (rank 1 and the top) and Thorns,
    -- in buff mode, with passers-by on, out in Elwynn Forest.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, buffSelf = opts.buffSelf, autoBuffMode = opts.autoBuffMode, before = function(state)
            state.class = opts.class or "DRUID"
            state.knownSpells = opts.known or { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
        end })
        button = ns.BuffButton.Frame()
        -- opts.keepDefault: the switch as loading left it.
        if not opts.keepDefault then ns.db.buffBack.passersBy = opts.off ~= true end
        if not opts.noBuffMode then slash("buffmode on") end
    end

    -- A stranger on a nameplate: Bob Stone, a warrior, unless spec says.
    local function stranger(token, spec)
        spec = spec or {}
        spec.name, spec.surname = spec.name or "Bob", spec.surname or "Stone"
        spec.class = spec.class or "WARRIOR"
        spec.id = spec.name .. "-" .. spec.surname
        spec.auras = spec.auras or {}
        wow.addUnit(token or "nameplate1", spec)
        return wow.state.units[token or "nameplate1"]
    end

    local function offer()
        ns.PassersBy.Fresh()
        return ns.PassersBy.Next()
    end

    local function offered()
        ns.PassersBy.Fresh()
        local list = {}
        ns.PassersBy.Next(list)
        local out = {}
        for i, o in ipairs(list) do out[i] = o.name .. ":" .. o.spell end
        return out
    end

    local function lastCast() return wow.casts[#wow.casts] end

    -- A player's first name for a number (player names are letters only).
    local function nameFor(i)
        return "P" .. string.char(97 + math.floor((i - 1) / 26)) .. string.char(97 + (i - 1) % 26)
    end

    before_each(function() boot() end)

    describe("offering (white)", function()
        it("each press buffs the next passer-by missing a buff, one buff per press, in your order", function()
            stranger("nameplate1")
            stranger("nameplate2", { name = "Cid", surname = "Rock" })
            wow.press(button)
            assert.are.same({ "Mark of the Wild", "Bob-Stone" }, { lastCast().spell, lastCast().target })
            wow.press(button)
            assert.are.same({ "Thorns", "Bob-Stone" }, { lastCast().spell, lastCast().target },
                "the same passer-by, their next buff")
            wow.press(button)
            assert.are.same({ "Mark of the Wild", "Cid-Rock" }, { lastCast().spell, lastCast().target })
            wow.press(button)
            assert.are.same({ "Thorns", "Cid-Rock" }, { lastCast().spell, lastCast().target })
            local casts = #wow.casts
            wow.press(button)
            assert.are.equal(casts, #wow.casts, "everyone nearby has your buffs now")
        end)

        it("is off by default: nobody nearby is ever offered", function()
            boot({ keepDefault = true })
            assert.is_false(ns.db.buffBack.passersBy)
            stranger()
            assert.is_nil(offer())
            ns.db.buffBack.passersBy = nil
            assert.is_nil(offer())
            wow.press(button)
            assert.are.equal(0, #wow.casts)
            ns.db.buffBack.passersBy = false
            assert.is_nil(offer())
        end)

        it("follows your buff order and Never offer", function()
            ns.db.buffBack.buffOrder = { "thorns", "motw" }
            stranger()
            assert.are.equal("Thorns", offer().spell)
            ns.db.buffBack.neverOffer = { thorns = true }
            assert.are.equal("Mark of the Wild", offer().spell)
        end)

        it("tops up a copy with less than half its full time left, anyone's, not one with half or more", function()
            local bob = stranger()
            wow.wearBuff("nameplate1", MOTW_1, { duration = 1800 })
            ns.db.buffBack.neverOffer = { thorns = true }
            assert.is_nil(offer(), "a fresh copy")
            bob.auraExpires[1] = wow.now + 900
            assert.is_nil(offer(), "exactly half left is not less than half")
            bob.auraExpires[1] = wow.now + 899
            assert.are.equal("Mark of the Wild", offer().spell, "under half")
            wow.press(button)
            assert.are.same({ "Mark of the Wild", "Bob-Stone" }, { lastCast().spell, lastCast().target })
        end)

        it("comes after favours, your group and your self-buffs, and never turns buff mode on", function()
            boot({ noBuffMode = true })
            stranger("nameplate1")
            wow.advance(60)
            assert.is_false(ns.BuffMode.IsOn(), "a passer-by never turns buff mode on")
            slash("buffmode on")
            -- A favour: someone who buffed you.
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
            wow.setGroup("party", { "Dee-Moss" })
            wow.state.units.party1.class = "PRIEST"
            local list = {}
            ns.Offers.Current(list)
            ns.GroupBuffs.Next(list)
            ns.SelfBuffs.Next(list)
            ns.PassersBy.Fresh()
            ns.PassersBy.Next(list)
            local who = {}
            for _, o in ipairs(list) do who[#who + 1] = o.name end
            assert.are.same({ "Ann-Vale", "Dee-Moss", "Dee-Moss", "Bob-Stone" }, who,
                "the favour, the group member's two buffs, then the passer-by's first")
            wow.press(button)
            assert.are.equal("Ann-Vale", lastCast().target)
            wow.press(button)
            assert.are.equal("Dee-Moss", lastCast().target)
            wow.press(button)
            assert.are.equal("Dee-Moss", lastCast().target)
            wow.press(button)
            assert.are.equal("Bob-Stone", lastCast().target, "the passer-by last")
        end)

        it("puts a passer-by in a fight after everyone who isn't", function()
            stranger("nameplate1", { inCombat = true })
            stranger("nameplate2", { name = "Cid", surname = "Rock" })
            assert.are.same({ "Cid-Rock:Mark of the Wild", "Bob-Stone:Mark of the Wild" }, offered())
            wow.press(button)
            wow.press(button)
            assert.are.equal("Cid-Rock", lastCast().target, "Cid's Thorns before Bob")
            wow.press(button)
            assert.are.equal("Bob-Stone", lastCast().target)
        end)

        it("offers nobody inside an instance, in a capital (buff mode on), in a fight, or with buff mode off", function()
            stranger()
            assert.is_truthy(offer())
            wow.enterDungeon(36, "The Deadmines")
            assert.is_nil(offer(), "a dungeon")
            wow.leaveDungeon()
            assert.is_truthy(offer())
            wow.state.inInstance, wow.state.instanceType = true, "pvp"
            assert.is_nil(offer(), "a battleground")
            wow.state.instanceType = "arena"
            assert.is_nil(offer(), "an arena")
            wow.state.inInstance, wow.state.instanceType = false, nil
            wow.setMap(wow.CAPITAL.stormwind)
            assert.is_true(ns.BuffMode.IsOn())
            assert.is_nil(offer(), "a capital, even in buff mode")
            wow.setMap(nil)
            assert.is_nil(offer(), "a map that can't be read counts as a capital")
            wow.setMap(1429)
            assert.is_truthy(offer())
            wow.state.inCombat = true
            assert.is_nil(offer(), "in a fight")
            wow.state.inCombat = false
            slash("buffmode off")
            assert.is_nil(offer(), "buff mode off")
        end)

        it("says nothing in chat, and doesn't offer a buff that reached them again for 10 minutes", function()
            ns.db.buffBack.sayLine = true
            stranger()
            wow.press(button)
            assert.are.same({ "Mark of the Wild", "Bob-Stone" }, { lastCast().spell, lastCast().target })
            wow.advance(5)
            assert.are.equal(0, #wow.sent, "no line, whisper or emote")
            assert.are.equal("Thorns", offer().spell, "their next buff")
            ns.db.buffBack.neverOffer = { thorns = true }
            assert.is_nil(offer(), "Mark of the Wild isn't offered again (they could have cancelled it)")
            wow.advance(ns.PassersBy.SKIP_SECONDS - 10)
            assert.is_nil(offer())
            wow.advance(10)
            assert.are.equal("Mark of the Wild", offer().spell, "after 10 minutes, still missing it")
        end)

        it("remembers the buff for buff back: their buff back answers yours", function()
            stranger()
            wow.press(button)
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            assert.are.equal(0, ns.Offers.Count(), "their buff answers yours: nothing is owed")
        end)

        it("shows them as passing by on the button and in the list", function()
            stranger()
            wow.advance(30) -- past "buff mode on"'s result line
            ns.BuffButton.Refresh()
            assert.are.equal("Bob Stone", button.title:GetText())
            assert.are.equal("Mark of the Wild (passing by)", button.subtitle:GetText())
            local row = ns.BuffList.Rows()[1]
            assert.are.equal("> Bob Stone: Mark of the Wild (passing by)", row.text:GetText())
        end)

        it("right-click skips a passer-by for 10 minutes, and says so", function()
            stranger()
            stranger("nameplate2", { name = "Cid", surname = "Rock" })
            wow.advance(30)
            ns.BuffButton.Refresh()
            wow.press(button, "RightButton")
            assert.is_truthy(table.concat(ns.BuffButton.StatusLines(), "\n")
                :find("last result: Skipping Bob Stone for 10 minutes.", 1, true))
            wow.press(button)
            assert.are.equal("Cid-Rock", lastCast().target)
            wow.press(button, "RightButton", { shift = true })
            assert.are.same({}, ns.Ignore.List(), "shift adds nobody to a list")
            assert.are.equal(0, #offered())
            wow.advance(ns.PassersBy.SKIP_SECONDS)
            assert.are.equal("Bob-Stone", offer().name)
        end)

        it("a passer-by the game refuses waits a moment, and the next is tried", function()
            stranger("nameplate1", { outOfRange = true })
            stranger("nameplate2", { name = "Cid", surname = "Rock" })
            -- In range by the spell check, but the game refuses: line of sight.
            wow.state.units.nameplate1.outOfRange = nil
            wow.state.units.nameplate1.hidden = true
            wow.state.units.nameplate1.spellRangeUnknown = nil
            _G.C_Spell.IsSpellInRange = function() return true end
            wow.press(button)
            assert.are.equal("Bob-Stone", lastCast().target)
            assert.is_truthy(lastCast().failed)
            wow.press(button)
            assert.are.equal("Cid-Rock", lastCast().target)
        end)
    end)

    describe("who counts (black)", function()
        local APIS = { "UnitIsPlayer", "UnitIsUnit", "UnitName", "UnitCanAssist", "UnitIsDeadOrGhost",
            "UnitIsConnected", "UnitAffectingCombat", "UnitIsPVP", "UnitClass" }
        local BAD = {
            error = function() error("the game raised an error") end,
            secret = function(real) return wow.secret(real) end,
            ["nil"] = function() return nil end,
            ["wrong type"] = function() return 1 end,
        }

        -- Make api answer badly for the unit token, only.
        local function breakFor(api, token, how)
            local real = _G[api]
            _G[api] = function(...)
                local args = { ... }
                local unit = api == "UnitCanAssist" and args[2] or args[1]
                if unit == token then
                    local ok, value = pcall(real, ...)
                    return BAD[how](ok and value or nil)
                end
                return real(...)
            end
        end

        for _, api in ipairs(APIS) do
            for how in pairs(BAD) do
                it(api .. " giving " .. how .. " skips that player, never errors, and the next is tried", function()
                    stranger("nameplate1")
                    stranger("nameplate2", { name = "Cid", surname = "Rock" })
                    breakFor(api, "nameplate1", how)
                    assert.are.same({ "Cid-Rock:Mark of the Wild" }, offered())
                    wow.press(button)
                    assert.are.equal("Cid-Rock", lastCast().target)
                end)
            end
        end

        it("your own PvP flag unreadable counts as not flagged: a flagged passer-by is skipped", function()
            stranger("nameplate1", { pvp = true })
            stranger("nameplate2", { name = "Cid", surname = "Rock" })
            local real = _G.UnitIsPVP
            _G.UnitIsPVP = function(unit)
                if unit == "player" then return wow.secret(true) end
                return real(unit)
            end
            assert.are.same({ "Cid-Rock:Mark of the Wild" }, offered())
        end)

        it("an aura list that errors, is secret or has a secret spell ID skips that player", function()
            stranger("nameplate1")
            stranger("nameplate2", { name = "Cid", surname = "Rock" })
            local real = _G.C_UnitAuras.GetAuraDataByIndex
            for _, how in ipairs({ "error", "secret", "secret id" }) do
                _G.C_UnitAuras.GetAuraDataByIndex = function(unit, i, filter)
                    if unit ~= "nameplate1" then return real(unit, i, filter) end
                    if how == "error" then error("restricted") end
                    if how == "secret" then return wow.secret({ spellId = 1 }) end
                    return { spellId = wow.secret(1) }
                end
                assert.are.same({ "Cid-Rock:Mark of the Wild" }, offered(), how)
            end
        end)

        it("a range check that says no, or won't say, skips that player", function()
            stranger("nameplate1", { outOfSpellRange = true })
            stranger("nameplate2", { name = "Cid", surname = "Rock", spellRangeUnknown = true })
            stranger("nameplate3", { name = "Dee", surname = "Moss" })
            assert.are.same({ "Dee-Moss:Mark of the Wild" }, offered())
        end)

        it("never offers a group member, a favour, a request, an ignored player, an NPC or you", function()
            stranger("nameplate1", { name = "Gus", surname = "Mate" })
            wow.setGroup("party", { "Gus-Mate" })
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
            stranger("nameplate3", { name = "Eve", surname = "Ask" })
            ns.Offers.Request("Eve-Ask", ns.BuffData.ByKey("motw"))
            stranger("nameplate4", { name = "Ivy", surname = "Gone" })
            ns.Ignore.Add("Ivy Gone")
            stranger("nameplate5", { name = "Wolf", surname = nil, isPlayer = false })
            wow.state.units.nameplate6 = wow.state.units.player
            local list = {}
            ns.PassersBy.Fresh()
            ns.PassersBy.Next(list)
            assert.are.same({}, list)
        end)

        it("never offers the other faction, the dead, the offline, or a flagged player while you aren't", function()
            stranger("nameplate1", { name = "Orc", surname = "Grunt", cantAssist = true })
            stranger("nameplate2", { name = "Hos", surname = "Tile", hostile = true })
            stranger("nameplate3", { name = "Ded", surname = "Man", dead = true })
            stranger("nameplate4", { name = "Off", surname = "Line", offline = true })
            stranger("nameplate5", { name = "Pvp", surname = "Flag", pvp = true })
            assert.are.same({}, offered())
            wow.state.pvp = true
            assert.are.same({ "Pvp-Flag:Mark of the Wild" }, offered(), "you're flagged too")
        end)

        it("offers nobody when your group or the instance answer can't be read", function()
            stranger()
            wow.setGroup("party", { "Gus-Mate" })
            wow.state.units.party1.secrets = { name = true }
            assert.is_nil(offer(), "a group member's name is a secret")
            wow.state.units.party1.secrets = nil
            assert.is_truthy(offer())
            wow.state.inInstanceSecret = true
            assert.is_nil(offer(), "the instance answer is a secret")
            wow.state.inInstanceSecret = nil
            _G.IsInInstance = function() error("no answer") end
            assert.is_nil(offer(), "the instance answer errors")
        end)

        it("never offers a buff their class can't use, a self-buff, Water Walking, or a Never offer buff", function()
            boot({ class = "MAGE", known = { [INTELLECT] = true } })
            stranger("nameplate1", { class = "WARRIOR" })
            assert.is_nil(offer(), "Arcane Intellect is no use to a warrior")
            stranger("nameplate1", { class = "PRIEST" })
            assert.are.equal("Arcane Intellect", offer().spell)
            ns.db.buffBack.neverOffer = { intellect = true }
            assert.is_nil(offer(), "Never offer")
            for _, buff in ipairs(ns.BuffData.ClassBuffs()) do
                assert.is_false(buff.selfCast == true and offer() ~= nil)
            end
        end)

        it("never offers a self-buff or a buff only given when asked", function()
            -- A shaman knows Water Walking (asked only, #350) and Lightning Shield (a self-buff).
            local seen = {}
            for _, class in ipairs({ "SHAMAN", "PRIEST", "MAGE", "WARLOCK", "PALADIN", "HUNTER", "WARRIOR" }) do
                local known = {}
                for _, buff in ipairs(ns.BuffData.CLASSES[class] or {}) do
                    for _, id in ipairs(buff.ranks) do known[id] = true end
                end
                boot({ class = class, known = known })
                stranger("nameplate1", { class = "PRIEST" })
                ns.PassersBy.Fresh()
                local list = {}
                ns.PassersBy.Next(list)
                for _, o in ipairs(list) do
                    assert.is_falsy(o.buff.selfCast, class .. " " .. o.spell)
                    assert.is_falsy(o.buff.requestOnly, class .. " " .. o.spell)
                    seen[class] = true
                end
            end
            assert.is_true(seen.PRIEST and seen.MAGE and true or false)
        end)

        it("casts the single buff, never a group version", function()
            boot({ known = { [MOTW_1] = true, [MOTW] = true, [GIFT] = true } })
            wow.state.items[17026] = 5
            stranger()
            wow.press(button)
            assert.are.equal(MOTW, lastCast().id)
        end)

        it("doesn't renew a copy with times it can't read, a group version, or a stronger rank", function()
            boot({ known = { [MOTW_1] = true } })
            local bob = stranger()
            wow.wearBuff("nameplate1", MOTW, { duration = 1800 })
            bob.auraExpires[1] = wow.now + 60
            assert.is_nil(offer(), "a stronger rank than any you know, nearly gone")
            bob.auras[1] = GIFT
            assert.is_nil(offer(), "a group version, nearly gone")
            bob.auras[1] = MOTW_1
            assert.are.equal("Mark of the Wild", offer().spell, "your rank, nearly gone")
            bob.secrets = { auraTimes = true }
            assert.is_nil(offer(), "times that are secrets")
            bob.secrets = nil
            bob.auraDurations[1] = 0
            bob.auraExpires[1] = 0
            assert.is_nil(offer(), "a copy that never runs out")
            bob.auraDurations[1] = "1800"
            bob.auraExpires[1] = wow.now + 60
            assert.is_nil(offer(), "times that aren't numbers")
        end)

        it("a blocker counts as having the buff", function()
            boot({ class = "WARLOCK", known = { [5697] = true } })
            stranger("nameplate1", { class = "PRIEST" })
            ns.db.buffBack.breathNearWater = false
            local before = offer()
            wow.wearBuff("nameplate1", 131, { duration = 600 })
            if before then assert.is_nil(offer(), "Water Breathing blocks Unending Breath") end
        end)
    end)

    describe("the campfire turns buff mode on (#39, the owner)", function()
        local COZY = 1232234

        local function bootAuto(extra)
            extra = extra or {}
            boot({ autoBuffMode = true, noBuffMode = true, off = extra.off, db = extra.db })
            -- Only the campfire's trigger is looked at here.
            for _, field in ipairs({ "autoOnJoin", "autoOnDeath", "autoOnBuffed", "autoOnMissing" }) do
                ns.db.buffBack[field] = extra[field] == true
            end
        end

        local function sitByFire(id) return wow.gainBuff({ spellId = id or COZY, name = "Cozy Fire" }) end

        it("is on by default, and every campfire aura the data gives turns it on for a passer-by", function()
            boot({ autoBuffMode = true, noBuffMode = true, keepDefault = true })
            assert.is_true(ns.db.buffBack.autoOnCampfire)
            assert.is_false(ns.db.buffBack.passersBy, "passers-by stay off by default")
            for _, id in ipairs({ 1232234, 7353, 7358, 1229736, 1229739, 1289723 }) do
                bootAuto()
                stranger()
                sitByFire(id)
                assert.is_true(ns.BuffMode.IsAuto(), "spell " .. id)
            end
        end)

        it("does nothing with nothing to do, or for an aura that isn't a campfire's", function()
            bootAuto()
            sitByFire()
            assert.is_false(ns.BuffMode.IsOn(), "nobody to buff")
            wow.loseBuff(COZY)
            stranger()
            sitByFire(818) -- Basic Campfire, the spell that makes the fire: not an aura you wear
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("with passers-by off, turns on only for a favour or the group, as any trigger", function()
            bootAuto({ off = true })
            stranger()
            sitByFire()
            assert.is_false(ns.BuffMode.IsOn(), "a passer-by doesn't count with the switch off")
            wow.loseBuff(COZY)
            wow.setGroup("party", { "Dee-Moss" })
            sitByFire()
            assert.is_true(ns.BuffMode.IsAuto(), "Dee is missing your buffs")
        end)

        it("is off when you turn it off", function()
            bootAuto()
            ns.db.buffBack.autoOnCampfire = false
            stranger()
            sitByFire()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("fires on gaining the buff: not again while you stay, again after you leave and come back", function()
            bootAuto()
            stranger()
            sitByFire()
            assert.is_true(ns.BuffMode.IsAuto())
            slash("buffmode off")
            wow.gainBuff({ spellId = 1126, name = "Mark of the Wild" })
            assert.is_false(ns.BuffMode.IsOn(), "still by the fire: no new gain")
            wow.loseBuff(COZY)
            sitByFire()
            assert.is_true(ns.BuffMode.IsAuto(), "back by the fire")
        end)

        it("already by a fire at a login isn't gaining it", function()
            bootAuto()
            sitByFire()
            wow.reloadInPlace(true, { before = function() end })
            stranger()
            wow.fire("UNIT_AURA", "player", {})
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("in a fight, waits for the fight to end", function()
            bootAuto()
            stranger()
            wow.enterCombat()
            sitByFire()
            assert.is_false(ns.BuffMode.IsOn())
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("its buff mode stays on while a passer-by waits, and ends when nobody does", function()
            bootAuto()
            stranger()
            sitByFire()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.advance(30)
            ns.BuffButton.Refresh()
            assert.is_true(ns.BuffMode.IsOn(), "Bob still waits")
            wow.press(button)
            wow.press(button)
            ns.BuffButton.Refresh()
            assert.is_false(ns.BuffMode.IsOn(), "Bob has both your buffs: everyone has your buffs")
        end)

        it("its buff mode ends at the timeout, a passer-by or not", function()
            bootAuto()
            stranger()
            sitByFire()
            wow.advance(ns.db.buffBack.autoOffMinutes * 60 + 1)
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("no other trigger counts a passer-by: a favour's buff mode ends once it's returned", function()
            bootAuto({ autoOnBuffed = true })
            stranger("nameplate1")
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
            assert.is_true(ns.BuffMode.IsAuto())
            wow.press(button)
            assert.are.equal("Ann-Vale", lastCast().target)
            ns.BuffButton.Refresh()
            assert.is_false(ns.BuffMode.IsOn(), "Bob passing by doesn't keep it on")
        end)

        it("a campfire aura that can't be read (an error, a secret list, aura or spell ID) turns nothing on", function()
            for _, how in ipairs({ "error", "secret aura", "secret id", "not a table" }) do
                bootAuto()
                stranger()
                local real = _G.C_UnitAuras.GetAuraDataByIndex
                _G.C_UnitAuras.GetAuraDataByIndex = function(unit, i, filter)
                    if unit ~= "player" then return real(unit, i, filter) end
                    if how == "error" then error("restricted") end
                    if how == "secret aura" then return wow.secret({ spellId = COZY }) end
                    if how == "not a table" then return "Cozy Fire" end
                    return { spellId = wow.secret(COZY) }
                end
                sitByFire()
                assert.is_false(ns.BuffMode.IsOn(), how)
                -- Readable again, still by the fire: the last read that could tell
                -- said no fire, so this is gaining it.
                _G.C_UnitAuras.GetAuraDataByIndex = real
                wow.fire("UNIT_AURA", "player", {})
                assert.is_true(ns.BuffMode.IsAuto(), how)
            end
        end)

        it("a damaged switch reads as off mid-session, and heals on load", function()
            bootAuto()
            stranger()
            ns.db.buffBack.autoOnCampfire = "yes"
            sitByFire()
            assert.is_false(ns.BuffMode.IsOn())
            boot({ db = { buffBack = { autoOnCampfire = "yes", passersBy = 7 } }, autoBuffMode = true,
                noBuffMode = true, keepDefault = true })
            assert.is_true(ns.db.buffBack.autoOnCampfire)
            assert.is_false(ns.db.buffBack.passersBy)
        end)
    end)

    describe("limits and storms (red)", function()
        it("a crowd of 40 never gets more than 10 costly checks a look, or more than 5 in the list", function()
            for i = 1, 40 do stranger("nameplate" .. i, { name = nameFor(i), surname = "Crowd" }) end
            local auraReads, rangeReads = {}, 0
            local realAuras, realRange = _G.C_UnitAuras.GetAuraDataByIndex, _G.C_Spell.IsSpellInRange
            _G.C_UnitAuras.GetAuraDataByIndex = function(unit, ...)
                auraReads[unit] = true
                return realAuras(unit, ...)
            end
            _G.C_Spell.IsSpellInRange = function(...)
                rangeReads = rangeReads + 1
                return realRange(...)
            end
            local list = {}
            ns.PassersBy.Fresh()
            ns.PassersBy.Next(list)
            local players = 0
            for unit in pairs(auraReads) do
                if unit:find("^nameplate") then players = players + 1 end
            end
            assert.is_true(players <= ns.PassersBy.MAX_CHECKED, players .. " players' auras read")
            assert.is_true(rangeReads <= ns.PassersBy.MAX_CHECKED, rangeReads .. " range checks")
            assert.are.equal(ns.PassersBy.MAX_LISTED, #list)
            -- Everyone already has your buffs: still at most 10 looked at closely.
            for i = 1, 40 do
                wow.wearBuff("nameplate" .. i, MOTW, { duration = 1800 })
                wow.wearBuff("nameplate" .. i, THORNS, { duration = 600 })
            end
            auraReads = {}
            assert.is_nil(offer())
            players = 0
            for unit in pairs(auraReads) do
                if unit:find("^nameplate") then players = players + 1 end
            end
            assert.is_true(players <= ns.PassersBy.MAX_CHECKED, players .. " players' auras read")
        end)

        it("reuses a look for a second unless a press asks afresh", function()
            stranger()
            local reads = 0
            local real = _G.UnitIsPlayer
            _G.UnitIsPlayer = function(...)
                reads = reads + 1
                return real(...)
            end
            ns.PassersBy.Fresh()
            ns.PassersBy.Next()
            local after = reads
            ns.PassersBy.Next()
            assert.are.equal(after, reads, "within the second: the look is reused")
            wow.advance(ns.PassersBy.INTERVAL)
            ns.PassersBy.Next()
            assert.is_true(reads > after, "a second later: read again")
            -- A press always reads afresh: Bob turned flagged a moment ago.
            ns.PassersBy.Next()
            wow.state.units.nameplate1.pvp = true
            wow.press(button)
            assert.are.equal(0, #wow.casts, "the press read his flag again")
        end)

        it("remembers at most 50 skips and 200 buffs given, the oldest going first", function()
            for i = 1, 60 do ns.PassersBy.SkipName(nameFor(i) .. "-Crowd") end
            for i = 1, 210 do ns.PassersBy.NoteGiven(nameFor(i) .. "-Crowd", ns.BuffData.ByKey("motw")) end
            local skips, gifts = ns.PassersBy.Remembered()
            assert.are.equal(ns.PassersBy.MAX_SKIPPED, skips)
            assert.are.equal(ns.PassersBy.MAX_GIVEN, gifts)
        end)

        it("a chaos storm never casts on anyone flagged while you aren't, dead, hostile, in your group, "
            .. "or on yourself, never puts a fighter first, and never errors", function()
            local function chance(p) return random.random() < p end
            local function pick(list) return list[random.random(#list)] end
            local castCount, fighterCount, calmSkipped = 0, 0, 0
            for seed = 1, 6 do
                random.seed(seed)
                boot()
                -- The storm's own record of what reached whom, kept apart from PassersBy.
                local gave = {}
                -- Whether the simulated client's own state says this nameplate is a
                -- passer-by who may be buffed now and is missing a buff of yours.
                local function eligible(u, me)
                    if not u or u == me or not u.isPlayer or not u.surname or u.hostile or u.cantAssist
                        or u.dead or u.offline or u.secrets or u.outOfSpellRange then return false end
                    if u.pvp and not wow.state.pvp then return false end
                    if wow.state.groupMembers[u.id] then return false end
                    local wears = {}
                    for i, id in ipairs(u.auras or {}) do
                        if not wow.auraExpired(u, i) then wears[id] = i end
                    end
                    local motwLeft = wears[MOTW_1] and (u.auraExpires[wears[MOTW_1]] - wow.now) or nil
                    local needsMotw = (not wears[MOTW_1] and not wears[MOTW] and not wears[GIFT])
                        or (motwLeft and not wears[MOTW] and not wears[GIFT]
                            and motwLeft < u.auraDurations[wears[MOTW_1]] / 2)
                    local needsThorns = not wears[THORNS_1] and not wears[THORNS]
                    local recent = function(spell)
                        local at = gave[u.id .. "\1" .. spell]
                        return at and wow.now - at < ns.PassersBy.SKIP_SECONDS
                    end
                    return (needsMotw and not recent("Mark of the Wild")) or (needsThorns and not recent("Thorns"))
                end
                for _ = 1, 150 do
                    -- Nameplates come and go, with any state.
                    for i = 1, 12 do
                        local token = "nameplate" .. i
                        if chance(0.3) then
                            if chance(0.2) then
                                wow.state.units[token] = nil
                            else
                                -- Each token's player is their own (the game never shows
                                -- one player on two nameplates), in any state.
                                local u = stranger(token, { name = nameFor(i), surname = "Storm",
                                    class = pick({ "WARRIOR", "PRIEST", "MAGE", "ROGUE" }),
                                    isPlayer = chance(0.9), hostile = chance(0.1),
                                    cantAssist = chance(0.1), dead = chance(0.1),
                                    offline = chance(0.05), pvp = chance(0.2),
                                    inCombat = chance(0.3) })
                                if chance(0.1) then
                                    u.secrets = { [pick({ "pvp", "name", "canAssist", "combat", "auras",
                                        "isPlayer", "offline" })] = true }
                                end
                                if chance(0.3) then
                                    wow.wearBuff(token, MOTW_1, { duration = 1800 })
                                    u.auraExpires[#u.auras] = wow.now + random.random(1, 1800)
                                end
                            end
                        end
                    end
                    wow.state.units.nameplate13 = chance(0.1) and wow.state.units.player or nil
                    if chance(0.1) then
                        -- A group you can't buff (offline), so any cast on its
                        -- members would be a passer-by's.
                        wow.setGroup(chance(0.5) and "party" or nil, chance(0.5) and { nameFor(1) .. "-Storm", nameFor(2) .. "-Storm" } or {})
                        for i = 1, 4 do
                            if wow.state.units["party" .. i] then wow.state.units["party" .. i].offline = true end
                        end
                    end
                    if chance(0.05) then wow.state.pvp = not wow.state.pvp end
                    if chance(0.05) then wow.state.inInstance = not wow.state.inInstance end
                    if chance(0.05) then wow.setMap(pick({ 1429, wow.CAPITAL.stormwind, 1429 }), { silent = true }) end
                    if chance(0.05) then wow.state.unitsRestricted = chance(0.3) end
                    -- Before the press, from the client's own state: is a calm
                    -- passer-by waiting for a buff?
                    local me = wow.state.units.player
                    local open = not wow.state.inInstance and wow.state.mapId == 1429 and not wow.state.unitsRestricted
                    local calmWaiting = false
                    for i = 1, 13 do
                        local u = wow.state.units["nameplate" .. i]
                        if open and u and not u.inCombat and eligible(u, me) then calmWaiting = true end
                    end
                    local before, flaggedBefore = #wow.casts, #wow.flaggedBy
                    local ok, err = pcall(wow.press, button)
                    assert.are.equal(flaggedBefore, #wow.flaggedBy, "a buff of yours never flags you")
                    assert.is_true(ok, err)
                    for c = before + 1, #wow.casts do
                        local cast = wow.casts[c]
                        assert.are_not.equal(me.id, cast.target, "never on yourself")
                        local target
                        for token, u in pairs(wow.state.units) do
                            if token:find("^nameplate") and u.id == cast.target then target = u end
                        end
                        assert.is_truthy(target, "only passers-by are offered here: " .. tostring(cast.target))
                        assert.is_falsy(target.pvp and not wow.state.pvp, "flagged: " .. cast.target)
                        assert.is_falsy(target.dead or cast.targetDead, "dead: " .. cast.target)
                        assert.is_falsy(target.hostile or target.cantAssist or cast.targetHostile,
                            "hostile: " .. cast.target)
                        assert.is_falsy(wow.state.groupMembers[cast.target], "in your group: " .. cast.target)
                        assert.is_falsy(wow.state.inInstance, "in an instance")
                        assert.are.equal(1429, wow.state.mapId, "in the open world, not a capital")
                        castCount = castCount + 1
                        if target.inCombat then
                            fighterCount = fighterCount + 1
                            assert.is_false(calmWaiting, "a fighter first: " .. cast.target)
                        end
                        gave[cast.target .. "\1" .. cast.spell] = wow.now
                    end
                    if calmWaiting and #wow.casts == before then calmSkipped = calmSkipped + 1 end
                    wow.advance(random.random(0, 3))
                end
            end
            -- The storm did reach passers-by, fighters among them.
            assert.is_true(castCount > 50, castCount .. " casts")
            assert.is_true(fighterCount > 5, fighterCount .. " casts on fighters")
        end)
    end)
end)
