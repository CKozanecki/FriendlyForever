-- Spec: #39, #451, #459, #462, #484, #521
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
            if opts.before then opts.before(state) end
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

        it("comes after your self-buffs on the button too", function()
            local INNER_FIRE, FORT = 10952, 10938
            boot({ class = "PRIEST", known = { [INNER_FIRE] = true, [FORT] = true } })
            stranger()
            wow.press(button)
            assert.are.same({ "Inner Fire", "Me" }, { lastCast().spell, lastCast().target }, "yours first")
            wow.press(button)
            assert.are.same({ "Power Word: Fortitude", "Bob-Stone" }, { lastCast().spell, lastCast().target })
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

        -- The merge of #45 (weapon buffs): they're your own, so they come
        -- first, and the list names each one's hand.
        it("comes after your weapon buffs; the list says which hand, and who's passing by", function()
            local W = wow.WEAPON
            boot({ class = "MAGE", known = { [INTELLECT] = true },
                db = { buffBack = { weaponBuffs = true, weaponMain = "wizardOil", weaponOff = "none",
                    soloOwnBuffs = false } },
                before = function(state)
                    state.items = { [W.brilliantWizardOil] = 2 }
                    state.itemNames = { [W.brilliantWizardOil] = "Brilliant Wizard Oil" }
                end })
            stranger("nameplate1", { class = "MAGE" })
            wow.advance(30)
            ns.BuffButton.Refresh()
            assert.are.equal("Brilliant Wizard Oil on your main hand", button.subtitle:GetText())
            local rows = {}
            for _, row in ipairs(ns.BuffList.Rows()) do
                if row:IsShown() then rows[#rows + 1] = row.text:GetText() end
            end
            assert.are.same({ "> You: Brilliant Wizard Oil (main)", "Bob Stone: Arcane Intellect (passing by)" },
                rows)
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
            wow.advance(599)
            assert.are.equal(0, #offered(), "still skipped after 9 minutes 59 seconds")
            wow.advance(1)
            assert.are.equal("Bob-Stone", offer().name, "offered again after 10 minutes")
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

        it("offers nobody with the addon or Buff Back off", function()
            stranger()
            ns.db.enabled = false
            assert.is_nil(offer(), "the addon off")
            ns.db.enabled = true
            ns.db.buffBack.enabled = false
            assert.is_nil(offer(), "Buff Back off")
            ns.db.buffBack.enabled = true
            assert.is_truthy(offer())
        end)

        it("offers nobody when the game won't say whether you're in a fight, or who you are", function()
            stranger()
            local realLockdown, realName = _G.InCombatLockdown, _G.UnitName
            _G.InCombatLockdown = function() return wow.secret(false) end
            assert.is_nil(offer(), "the fight answer is a secret")
            _G.InCombatLockdown = realLockdown
            _G.UnitName = function(unit)
                if unit == "player" then return wow.secret("Me") end
                return realName(unit)
            end
            assert.is_nil(offer(), "your name is a secret")
            _G.UnitName = realName
            assert.is_truthy(offer())
        end)

        it("never offers someone on a nameplate with your own name", function()
            wow.state.units.player.surname = wow.state.units.player.surname or "Self"
            local me = wow.state.units.player
            stranger("nameplate1", { name = me.name, surname = me.surname, id = "Another-Unit" })
            wow.state.units.nameplate1.id = "Another-Unit"
            assert.is_nil(offer())
        end)

        it("never offers a member of your raid, and offers nobody when a group slot can't be read", function()
            stranger("nameplate1")
            wow.setGroup("raid", { "Bob-Stone" })
            wow.state.units.raid1.subgroup = 2 -- not in your party1..4
            assert.is_nil(offer(), "Bob is in your raid")
            wow.setGroup(nil, {})
            assert.is_truthy(offer())
            wow.setGroup("party", { "Dee-Moss" })
            local real = _G.UnitExists
            _G.UnitExists = function(unit)
                if unit == "party1" then return wow.secret(true) end
                return real(unit)
            end
            assert.is_nil(offer(), "party1 can't be read")
        end)

        it("lists a player shown on two nameplates once", function()
            stranger("nameplate1")
            stranger("nameplate2")
            assert.are.same({ "Bob-Stone:Mark of the Wild" }, offered())
        end)

        it("keeps one Blessing of yours on each passer-by, as for your group", function()
            local KINGS, MIGHT = 20217, 19740
            boot({ class = "PALADIN", known = { [KINGS] = true, [MIGHT] = true } })
            stranger()
            wow.press(button)
            assert.are.same({ "Blessing of Kings", "Bob-Stone" }, { lastCast().spell, lastCast().target })
            local casts = #wow.casts
            wow.press(button)
            assert.are.equal(casts, #wow.casts, "Might would replace the Kings you just gave")
            -- Wearing your Kings (it shows now): still no Might, whatever the raid split says.
            boot({ class = "PALADIN", known = { [KINGS] = true, [MIGHT] = true } })
            stranger()
            wow.wearBuff("nameplate1", KINGS, { duration = 3600, source = "player" })
            local realCovers = ns.BuffRules.CoversInRaid
            ns.BuffRules.CoversInRaid = function() return false end
            assert.is_nil(offer(), "your Kings is on them")
            ns.BuffRules.CoversInRaid = realCovers
            -- Someone else's Kings: your Might is welcome.
            wow.state.units.nameplate1.auraSources[1] = false
            assert.are.equal("Blessing of Might", offer().spell)
            -- Who cast it can't be read: skipped.
            wow.state.units.nameplate1.auraSources[1] = wow.secret("player")
            assert.is_nil(offer())
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
            -- #524's testing review: an answer that isn't a boolean (#521 split the check).
            for _, odd in ipairs({ 1, "yes", 0 }) do
                _G.IsInInstance = function() return odd, "party" end
                assert.is_nil(offer(), "the instance answer is " .. tostring(odd))
            end
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

        it("follows your Buff Back rule for strangers (#408): Off, chosen classes, the new defaults", function()
            ns.BuffRules.Choose("new")
            stranger("nameplate1", { class = "WARRIOR" })
            assert.are.equal("Mark of the Wild", offer().spell, "Everyone, by default")
            ns.BuffRules.SetOff("motw", "strangers")
            assert.are.equal("Thorns", offer().spell, "Mark of the Wild is Off for strangers")
            ns.BuffRules.SetPlaceClass("motw", "strangers", "WARRIOR", true)
            assert.are.equal("Mark of the Wild", offer().spell, "warriors ticked")
            stranger("nameplate1", { class = "ROGUE" })
            assert.are.equal("Thorns", offer().spell, "a rogue isn't ticked")
            ns.BuffRules.SetOff("thorns", "strangers")
            assert.is_nil(offer(), "nothing left your rules give a rogue")
            -- Might goes only to its classes on the new defaults.
            local MIGHT = 19740
            boot({ class = "PALADIN", known = { [MIGHT] = true } })
            ns.BuffRules.Choose("new")
            stranger("nameplate1", { class = "MAGE" })
            assert.is_nil(offer(), "a mage gets no Might")
            stranger("nameplate1", { class = "WARRIOR" })
            assert.are.equal("Blessing of Might", offer().spell)
        end)

        it("while your choice is pending, offers any buff their class can use, as 1.3.3's strangers got", function()
            assert.is_true(ns.BuffRules.Pending())
            local MIGHT = 19740
            boot({ class = "PALADIN", known = { [MIGHT] = true } })
            stranger("nameplate1", { class = "MAGE" })
            assert.are.equal("Blessing of Might", offer().spell)
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

        it("doesn't renew a group version you could match, nearly gone", function()
            boot({ known = { [MOTW_1] = true, [MOTW] = true } })
            ns.db.buffBack.neverOffer = { thorns = true }
            local bob = stranger()
            wow.wearBuff("nameplate1", GIFT, { duration = 3600 })
            bob.auraExpires[1] = wow.now + 60
            assert.is_nil(offer(), "Gift of the Wild lasts longer than your single cast")
        end)

        it("a cast the game didn't say reached them isn't offered to them again at every press", function()
            wow.state.sentTargetForm = "none"
            ns.db.buffBack.neverOffer = { thorns = true }
            stranger()
            wow.press(button)
            assert.are.same({ "Mark of the Wild", "Bob-Stone" }, { lastCast().spell, lastCast().target })
            assert.is_nil(offer())
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

        -- Buff mode off by hand, then a new zone: only after one may passers-by
        -- turn it back on (#484), and these specs are about the fire.
        local function offByHandNewZone()
            slash("buffmode off")
            wow.fire("ZONE_CHANGED_NEW_AREA")
        end

        it("is on by default, and every campfire aura and camp benefit the data gives turns it on for a passer-by", function()
            boot({ autoBuffMode = true, noBuffMode = true, keepDefault = true })
            assert.is_true(ns.db.buffBack.autoOnCampfire)
            assert.is_false(ns.db.buffBack.passersBy, "passers-by stay off by default")
            for _, id in ipairs({ 1232234, 7353, 7358, 1229736, 1229739, 1289723, 1229487, 1283391, 1229741, 1230587,
                1230172, 1230653, 1230124, 1230098, 1229513, 1230164, 1229519, 1229718 }) do
                bootAuto()
                stranger()
                sitByFire(id)
                assert.is_true(ns.BuffMode.IsAuto(), "spell " .. id)
            end
        end)

        it("\"Campfire Nearby\" (1283391), gained out of combat, turns it on with the campfire's reason (#451)", function()
            bootAuto()
            stranger()
            wow.gainBuff({ spellId = 1283391, name = "Campfire Nearby" })
            assert.is_true(ns.BuffMode.IsAuto())
            local said = false
            for _, line in ipairs(wow.printed) do
                if line:find("you're by a campfire", 1, true) then said = true end
            end
            assert.is_true(said, "the campfire's reason is printed")
        end)

        it("every campfire aura is backed by Forever's data: named by ID above the set and in the facts file (#451)", function()
            bootAuto()
            local function read(path)
                local f = assert(io.open(path, "r"))
                local text = f:read("*a")
                f:close()
                return text
            end
            -- The comment block right above the set, in BuffModeAuto.lua.
            local code = read("BuffModeAuto.lua")
            local before = assert(code:find("\nAuto%.CAMPFIRE_AURAS = {"), "the set is where the spec looks")
            local comment = {}
            for line in code:sub(1, before):gmatch("[^\n]*\n") do
                if line:find("^%-%-") then comment[#comment + 1] = line else comment = {} end
            end
            comment = table.concat(comment):gsub("\n%-%-%s*", " ")
            assert.matches("Forever's spell data %(build 1%.60%.1%.%d+", comment)
            -- The facts file's campfire entry: each ID on a line that isn't the "not an aura you get" one.
            local facts = read("docs/forever-facts.md")
            local entry = assert(facts:match("%- %*%*The campfire buff%*%*.-\n%- %*%*Passers%-by"))
            local count = 0
            for id in pairs(ns.BuffModeAuto.CAMPFIRE_AURAS) do
                count = count + 1
                local pattern = "%f[%d]" .. id .. "%f[%D]"
                assert.is_truthy(comment:find(pattern), "spell " .. id .. " has no data-backed comment above the set")
                local backed = false
                for line in entry:gmatch("[^\n]+") do
                    if line:find(pattern) and not line:find("not an aura you get", 1, true) then backed = true end
                end
                assert.is_true(backed, "spell " .. id .. " isn't in the facts file as an aura you get")
            end
            assert.matches("any of these " .. count .. " auras", entry, 1, true)
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
            offByHandNewZone()
            wow.gainBuff({ spellId = 1126, name = "Mark of the Wild" })
            assert.is_false(ns.BuffMode.IsOn(), "still by the fire: no new gain")
            wow.loseBuff(COZY)
            sitByFire()
            assert.is_true(ns.BuffMode.IsAuto(), "back by the fire")
        end)

        it("a camp benefit added while you're already by the fire turns it on again (the owner's correction)", function()
            bootAuto()
            stranger()
            sitByFire()
            offByHandNewZone()
            wow.gainBuff({ spellId = 1229741, name = "Camp Benefits", duration = 3600 })
            assert.is_true(ns.BuffMode.IsAuto(), "Camp Benefits was added")
            offByHandNewZone()
            wow.gainBuff({ spellId = 1229718, name = "Boosted Spirit", duration = 3600 })
            assert.is_true(ns.BuffMode.IsAuto(), "a feature's bonus was added")
            offByHandNewZone()
            wow.loseBuff(COZY)
            assert.is_false(ns.BuffMode.IsOn(), "losing one adds nothing")
        end)

        it("a benefit that stays on after you leave isn't added again", function()
            bootAuto()
            stranger()
            wow.gainBuff({ spellId = 1229741, name = "Camp Benefits", duration = 3600 })
            assert.is_true(ns.BuffMode.IsAuto())
            offByHandNewZone()
            wow.gainBuff({ spellId = 1126, name = "Mark of the Wild" })
            wow.advance(60)
            wow.fire("UNIT_AURA", "player", {})
            assert.is_false(ns.BuffMode.IsOn(), "still wearing it, an hour long")
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

        it("a later trigger's buff mode counts passers-by too, after the campfire's (#462)", function()
            bootAuto({ autoOnBuffed = true })
            stranger("nameplate1")
            sitByFire()
            assert.is_true(ns.BuffMode.IsAuto())
            slash("buffmode off")
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
            assert.is_true(ns.BuffMode.IsAuto(), "the favour turned it on")
            wow.press(button)
            assert.are.equal("Ann-Vale", lastCast().target)
            ns.BuffButton.Refresh()
            assert.is_true(ns.BuffMode.IsOn(), "Bob passing by keeps the favour's buff mode on (#462)")
        end)

        it("in a fight, the campfire counts passers-by whichever trigger fired first", function()
            for _, fireFirst in ipairs({ false, true }) do
                bootAuto({ autoOnBuffed = true })
                stranger("nameplate1")
                wow.enterCombat()
                stranger("nameplate2", { name = "Ann", surname = "Vale" })
                if fireFirst then sitByFire() end
                wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
                if not fireFirst then sitByFire() end
                wow.leaveCombat()
                assert.is_true(ns.BuffMode.IsAuto())
                wow.press(button)
                assert.are.equal("Ann-Vale", lastCast().target)
                ns.BuffButton.Refresh()
                assert.is_true(ns.BuffMode.IsOn(), "Bob still waits: the campfire's buff mode")
            end
        end)

        it("its buff mode ends at the timeout, a passer-by or not", function()
            bootAuto()
            stranger()
            sitByFire()
            wow.advance(ns.db.buffBack.autoOffMinutes * 60 + 1)
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("every trigger counts a passer-by waiting (#462): a favour's buff mode stays on for one", function()
            bootAuto({ autoOnBuffed = true })
            stranger("nameplate1")
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
            assert.is_true(ns.BuffMode.IsAuto())
            wow.press(button)
            assert.are.equal("Ann-Vale", lastCast().target)
            ns.BuffButton.Refresh()
            assert.is_true(ns.BuffMode.IsOn(), "Bob passing by keeps it on (#462, the owner)")
            -- Ann's Mark shows on her; then everyone passing by gets your buffs.
            wow.wearBuff("nameplate2", lastCast().id, { source = "player" })
            local tokenOf = { ["Bob-Stone"] = "nameplate1", ["Ann-Vale"] = "nameplate2" }
            for _ = 1, 4 do
                ns.PassersBy.Fresh()
                if not ns.BuffMode.IsOn() then break end
                wow.press(button)
                wow.wearBuff(tokenOf[lastCast().target], lastCast().id, { source = "player" })
            end
            ns.PassersBy.Fresh()
            ns.BuffButton.Refresh()
            assert.is_false(ns.BuffMode.IsOn(), "everyone passing by has your buffs: it ends")
        end)

        it("an update it can't read (a secret payload, list, aura or spell ID, or the wrong type) adds nothing "
            .. "the aura list doesn't show, and never errors", function()
            local cases = {
                ["secret payload"] = function() return wow.secret({ addedAuras = { { spellId = COZY } } }) end,
                ["secret list"] = function() return { addedAuras = wow.secret({ { spellId = COZY } }) } end,
                ["locked aura"] = function() return { addedAuras = { wow.lockedAura(7) } } end,
                ["secret spell ID"] = function() return { addedAuras = { { spellId = wow.secret(COZY) } } } end,
                ["list not a table"] = function() return { addedAuras = "Cozy Fire" } end,
                ["aura not a table"] = function() return { addedAuras = { "Cozy Fire" } } end,
                ["spell ID a string"] = function() return { addedAuras = { { spellId = tostring(COZY) } } } end,
                ["payload not a table"] = function() return "Cozy Fire" end,
                ["payload a number"] = function() return 5 end,
                ["list a number"] = function() return { addedAuras = 5 } end,
                ["aura a number"] = function() return { addedAuras = { 5 } } end,
            }
            for how, payload in pairs(cases) do
                bootAuto()
                stranger()
                wow.fire("UNIT_AURA", "player", payload())
                assert.is_false(ns.BuffMode.IsOn(), how)
                assert.are.same({}, wow.errors, how)
            end
        end)

        it("a readable campfire aura after an unreadable one in the same list still counts", function()
            bootAuto()
            stranger()
            table.insert(wow.state.playerAuras, { isHelpful = true, spellId = COZY, auraInstanceID = 8 })
            wow.fire("UNIT_AURA", "player", { addedAuras = { wow.lockedAura(7), { spellId = COZY, auraInstanceID = 8 } } })
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        -- Put the campfire aura on you without an update, as a restricted one hides it.
        local function wearFire(instance)
            local aura = { isHelpful = true, spellId = COZY, auraInstanceID = instance or 8 }
            table.insert(wow.state.playerAuras, aura)
            return aura
        end
        local function takeOff(aura)
            for i = #wow.state.playerAuras, 1, -1 do
                if wow.state.playerAuras[i] == aura then table.remove(wow.state.playerAuras, i) end
            end
        end

        it("an update it can't read out of a fight is made up by one read of your auras", function()
            local hidden = {
                ["secret payload"] = function() return wow.secret({ addedAuras = { { spellId = COZY } } }) end,
                ["secret list"] = function() return { addedAuras = wow.secret({ { spellId = COZY } }) } end,
                ["locked aura"] = function() return { addedAuras = { wow.lockedAura(8) } } end,
                ["secret spell ID"] = function() return { addedAuras = { { spellId = wow.secret(COZY) } } } end,
                ["secret full-update flag"] = function() return { isFullUpdate = wow.secret(false) } end,
            }
            for how, payload in pairs(hidden) do
                bootAuto()
                stranger()
                wearFire()
                wow.fire("UNIT_AURA", "player", payload())
                assert.is_true(ns.BuffMode.IsAuto(), how .. ": the list shows the fire")
            end
        end)

        it("the read doesn't take an aura that isn't a campfire's for one", function()
            bootAuto()
            stranger()
            table.insert(wow.state.playerAuras, { isHelpful = true, spellId = 1126, auraInstanceID = 9 })
            wow.fire("UNIT_AURA", "player", wow.secret({}))
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("an update it can't read while you stay by the fire isn't gaining it again", function()
            bootAuto()
            stranger()
            sitByFire()
            offByHandNewZone()
            wow.fire("UNIT_AURA", "player", wow.secret({}))
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("a list it can't read for the look keeps what it saw, and the look waits", function()
            for _, how in ipairs({ "error", "secret aura", "secret spell ID" }) do
                bootAuto()
                stranger()
                local first = sitByFire()
                offByHandNewZone()
                local real = _G.C_UnitAuras.GetAuraDataByIndex
                _G.C_UnitAuras.GetAuraDataByIndex = function(unit, i, filter)
                    if unit ~= "player" then return real(unit, i, filter) end
                    if how == "error" then error("restricted") end
                    if i > 1 then return nil end
                    if how == "secret aura" then return wow.secret({ spellId = COZY }) end
                    return { spellId = wow.secret(COZY), auraInstanceID = first.auraInstanceID }
                end
                wow.fire("UNIT_AURA", "player", wow.secret({}))
                _G.C_UnitAuras.GetAuraDataByIndex = real
                -- Still by the same fire: its refresh isn't new.
                wow.fire("UNIT_AURA", "player", { addedAuras = { { spellId = COZY, auraInstanceID = 600 } } })
                assert.is_false(ns.BuffMode.IsOn(), how)
                assert.are.same({}, wow.errors, how)
            end
        end)

        it("leaving the fire while its removal can't be read, then coming back, is gaining it", function()
            for _, how in ipairs({ "secret list", "secret instance" }) do
                bootAuto()
                stranger()
                local first = sitByFire()
                offByHandNewZone()
                takeOff(first)
                wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = how == "secret list"
                    and wow.secret({ first.auraInstanceID }) or { wow.secret(first.auraInstanceID) } })
                sitByFire()
                assert.is_true(ns.BuffMode.IsAuto(), how)
            end
        end)

        it("a /reload in a fight beside a fire doesn't take that fire as gained when the fight ends", function()
            bootAuto()
            stranger()
            wearFire()
            wow.enterCombat()
            wow.state.aurasRestricted = true
            wow.reloadInPlace(true)
            wow.state.aurasRestricted = false
            wow.fire("UNIT_AURA", "player", wow.secret({}))
            -- The read at the fight's end fails too, and the next update is that fire's refresh.
            wow.state.aurasRestricted = true
            wow.leaveCombat()
            wow.state.aurasRestricted = false
            wow.fire("UNIT_AURA", "player", { addedAuras = { { spellId = COZY, auraInstanceID = 90 } } })
            assert.is_false(ns.BuffMode.IsOn(), "it may have been there all along")
            -- Once a read has worked, a fire added later counts.
            wow.enterCombat()
            wearFire(81)
            local cozy = wow.state.playerAuras[#wow.state.playerAuras]
            cozy.spellId = 7353
            wow.fire("UNIT_AURA", "player", wow.secret({}))
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto(), "a second fire, added in the next fight")
        end)

        it("after a login whose read failed, the first read that works only notes the fire", function()
            bootAuto()
            stranger()
            wearFire()
            wow.state.aurasRestricted = true
            wow.reloadInPlace(true)
            wow.state.aurasRestricted = false
            wow.fire("UNIT_AURA", "player", wow.secret({}))
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("a campfire aura whose instance ID is NaN raises no error, and still counts (#108)", function()
            local nan = 0 / 0
            bootAuto()
            stranger()
            wow.fire("UNIT_AURA", "player", { addedAuras = { { spellId = COZY, auraInstanceID = nan } } })
            assert.are.same({}, wow.errors, "in an update")
            assert.is_true(ns.BuffMode.IsAuto(), "in an update")
            -- In the list read after an update that couldn't be read.
            bootAuto()
            stranger()
            wearFire(nan)
            wow.fire("UNIT_AURA", "player", wow.secret({}))
            assert.are.same({}, wow.errors, "in the list")
            assert.is_true(ns.BuffMode.IsAuto(), "in the list")
        end)

        it("a fire you zone in beside is noted by the full update, so its refresh isn't new", function()
            bootAuto()
            stranger()
            wearFire(70)
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            assert.is_false(ns.BuffMode.IsOn(), "a full update adds nothing")
            wow.fire("UNIT_AURA", "player", { addedAuras = { { spellId = COZY, auraInstanceID = 71 } } })
            assert.is_false(ns.BuffMode.IsOn(), "the same fire, refreshed")
        end)

        it("a campfire aura added in a fight, its update restricted as the game sends it, turns it on as the fight ends",
            function()
            bootAuto()
            stranger()
            local reads = 0
            local api = _G.C_UnitAuras.GetAuraDataByIndex
            _G.C_UnitAuras.GetAuraDataByIndex = function(unit, ...)
                if unit == "player" then reads = reads + 1 end
                return api(unit, ...)
            end
            wow.enterCombat()
            table.insert(wow.state.playerAuras, { isHelpful = true, spellId = COZY, auraInstanceID = 8 })
            wow.fire("UNIT_AURA", "player", wow.secret({ addedAuras = { { spellId = COZY } } }))
            wow.fire("UNIT_AURA", "player", { addedAuras = wow.secret({ { spellId = COZY } }) })
            assert.are.equal(0, reads, "nothing read in the fight")
            assert.is_false(ns.BuffMode.IsOn())
            _G.C_UnitAuras.GetAuraDataByIndex = api
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("a fire you were already by, refreshed (removed and added again) or added again, isn't new", function()
            bootAuto()
            stranger()
            local first = sitByFire()
            offByHandNewZone()
            -- Refreshed: the old instance goes and a new one comes, in one update.
            for i = #wow.state.playerAuras, 1, -1 do
                if wow.state.playerAuras[i] == first then table.remove(wow.state.playerAuras, i) end
            end
            table.insert(wow.state.playerAuras, { isHelpful = true, spellId = COZY, auraInstanceID = 501 })
            wow.fire("UNIT_AURA", "player", { removedAuraInstanceIDs = { first.auraInstanceID },
                addedAuras = { { spellId = COZY, auraInstanceID = 501 } } })
            assert.is_false(ns.BuffMode.IsOn(), "refreshed")
            -- Added again while it's on you.
            wow.fire("UNIT_AURA", "player", { addedAuras = { { spellId = COZY, auraInstanceID = 502 } } })
            assert.is_false(ns.BuffMode.IsOn(), "added again")
        end)

        it("does nothing before the login has finished", function()
            wow.reset()
            local loaded = {}
            local _, files = wow.parseToc()
            for _, file in ipairs(files) do assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
            _G.FriendlyForeverDB = { enabled = true, buffBack = { autoOnCampfire = true, passersBy = true } }
            -- Everything else a campfire would need: a passer-by, and a full name.
            wow.state.units.player.surname = wow.state.units.player.surname or "Self"
            wow.state.class, wow.state.knownSpells = "DRUID", { [MOTW_1] = true }
            stranger()
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            loaded.BuffModeAuto.OnPlayerAura("player", { addedAuras = { { spellId = COZY } } })
            assert.is_false(loaded.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end)

        it("another unit's campfire aura isn't yours", function()
            bootAuto()
            stranger()
            ns.BuffModeAuto.OnPlayerAura("target", { addedAuras = { { spellId = COZY } } })
            assert.is_false(ns.BuffMode.IsOn())
            ns.BuffModeAuto.OnPlayerAura("player", { addedAuras = { { spellId = COZY } } })
            assert.is_true(ns.BuffMode.IsAuto(), "yours is")
        end)

        it("auras that load before the login has finished never turn it on, even after a full update", function()
            wow.reset()
            local loaded = {}
            local _, files = wow.parseToc()
            for _, file in ipairs(files) do assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
            _G.FriendlyForeverDB = { enabled = true, buffBack = { autoOnCampfire = true, passersBy = true } }
            wow.state.units.player.surname = wow.state.units.player.surname or "Self"
            wow.state.class, wow.state.knownSpells = "DRUID", { [MOTW_1] = true }
            stranger()
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            table.insert(wow.state.playerAuras, { isHelpful = true, spellId = COZY, auraInstanceID = 8 })
            wow.fire("UNIT_AURA", "player", { addedAuras = { { spellId = COZY, auraInstanceID = 8 } } })
            assert.is_false(loaded.BuffMode.IsOn(), "before the login")
            wow.fire("PLAYER_ENTERING_WORLD", true, false)
            assert.is_false(loaded.BuffMode.IsOn(), "after it: you were by the fire all along")
            assert.are.same({}, wow.errors)
        end)

        it("a full update (zoning, a login) adds nothing", function()
            bootAuto()
            stranger()
            table.insert(wow.state.playerAuras, { isHelpful = true, spellId = COZY, auraInstanceID = 999 })
            wow.fire("UNIT_AURA", "player", { isFullUpdate = true })
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("no other trigger turns buff mode on for a passer-by", function()
            bootAuto({ autoOnJoin = true })
            stranger("nameplate1")
            wow.setGroup("party", { "Dee-Moss" })
            wow.wearBuff("party1", MOTW, { duration = 1800, source = "player" })
            wow.wearBuff("party1", THORNS_1, { duration = 600, source = "player" })
            local turnedOn = 0
            local set = ns.BuffMode.Set
            ns.BuffMode.Set = function(on, how)
                if on then turnedOn = turnedOn + 1 end
                return set(on, how)
            end
            wow.fire("GROUP_ROSTER_UPDATE")
            ns.BuffMode.Set = set
            assert.is_false(ns.BuffMode.IsOn(), "Dee has your buffs; Bob passing by doesn't count")
            assert.are.equal(0, turnedOn, "not even for a moment")
        end)

        it("doesn't end quiet mode in a capital city, and leaving it wearing a camp benefit isn't gaining one", function()
            bootAuto()
            wow.setMap(wow.CAPITAL.stormwind)
            stranger("nameplate2", { name = "Ann", surname = "Vale" })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
            assert.are.equal(1, ns.Offers.Count(), "a favour, held by quiet mode")
            assert.is_true(ns.Cities.ButtonHidden())
            wow.gainBuff({ spellId = 7353, name = "Cozy Fire" })
            wow.gainBuff({ spellId = 1229741, name = "Camp Benefits", duration = 3600 })
            assert.is_false(ns.BuffMode.IsOn(), "someone's cooking fire in Stormwind")
            assert.is_true(ns.Cities.ButtonHidden(), "quiet mode holds")
            wow.loseBuff(7353)
            wow.setMap(1429)
            wow.fire("UNIT_AURA", "player", {})
            assert.is_false(ns.BuffMode.IsOn(), "Camp Benefits was added in the city, not now")
        end)

        it("in a capital, either half of quiet mode holding keeps it off", function()
            for _, case in ipairs({ { thanks = true, button = false }, { thanks = false, button = true } }) do
                bootAuto()
                ns.db.buff.quietInCities = case.thanks
                ns.db.buffBack.showInCities = not case.button
                wow.setMap(wow.CAPITAL.stormwind)
                stranger("nameplate2", { name = "Ann", surname = "Vale" })
                wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
                assert.are.equal(case.thanks, ns.Cities.ThanksQuiet())
                assert.are.equal(case.button, ns.Cities.ButtonHidden())
                wow.gainBuff({ spellId = 7353, name = "Cozy Fire" })
                assert.is_false(ns.BuffMode.IsOn(), case.thanks and "thanks quiet" or "button hidden")
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

    describe("an update that adds PassersBy.lua (black)", function()
        it("asks for a restart, not erroring, after only a /reload", function()
            wow.reset()
            local loaded = {}
            local _, files = wow.parseToc()
            for _, file in ipairs(files) do
                if file ~= "PassersBy.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
            end
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            wow.fire("PLAYER_ENTERING_WORLD", true, false)
            wow.advance(20)
            assert.are.same({}, wow.errors)
            assert.are.equal(0, #wow.casts)
            assert.truthy(table.concat(wow.printed, "\n"):find("Restart the game (not /reload)", 1, true))
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
            local castCount, fighterCount, armedCount = 0, 0, 0
            local present = { dead = 0, hostile = 0, erroring = 0 }
            for seed = 1, 6 do
                random.seed(seed)
                boot()
                -- Some players' answers raise an error (unit.erroring names the call).
                for _, api in ipairs({ "UnitCanAssist", "UnitIsPVP", "UnitAffectingCombat" }) do
                    local real = _G[api]
                    _G[api] = function(a, b)
                        local u = wow.state.units[api == "UnitCanAssist" and b or a]
                        if u and u.erroring == api then error(api .. " failed") end
                        return real(a, b)
                    end
                end
                -- The player the armed button would target, by the macro's
                -- /targetexact name, from the client's own units.
                local function armedTarget()
                    local text = button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
                    local name = text and text:match("/targetexact ([^\n]+)")
                    if not name then return nil end
                    for token, u in pairs(wow.state.units) do
                        if token:find("^nameplate") and u.surname and (u.name .. " " .. u.surname) == name then
                            return u
                        end
                    end
                    return false
                end
                -- The storm's own record of what reached whom, kept apart from PassersBy.
                local gave = {}
                -- Whether the simulated client's own state says this nameplate is a
                -- passer-by who may be buffed now and is missing a buff of yours.
                local function eligible(u, me)
                    if not u or u == me or not u.isPlayer or not u.surname or u.hostile or u.cantAssist
                        or u.dead or u.offline or u.secrets or u.erroring or u.outOfSpellRange then return false end
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
                                    inCombat = chance(0.3), erroring = chance(0.05)
                                        and pick({ "UnitCanAssist", "UnitIsPVP", "UnitAffectingCombat" }) or nil })
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
                        if open and u and u ~= me and u.isPlayer and not u.secrets then
                            -- Reached: such a player was there to be wrongly offered.
                            if u.dead then present.dead = present.dead + 1 end
                            if u.hostile or u.cantAssist then present.hostile = present.hostile + 1 end
                            if u.erroring then present.erroring = present.erroring + 1 end
                        end
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
                    -- What the button holds now, armed by the same rules at the
                    -- press's state: never someone who may not be buffed.
                    local armed = armedTarget()
                    assert.are_not.equal(false, armed, "armed for someone not on a nameplate")
                    if armed then
                        armedCount = armedCount + 1
                        assert.are_not.equal(me, armed, "armed for yourself")
                        assert.is_falsy(armed.dead, "armed for the dead: " .. armed.id)
                        assert.is_falsy(armed.hostile or armed.cantAssist, "armed for the hostile: " .. armed.id)
                        assert.is_falsy(armed.erroring, "armed for an unreadable player: " .. armed.id)
                        assert.is_falsy(armed.pvp and not wow.state.pvp, "armed for the flagged: " .. armed.id)
                        assert.is_falsy(wow.state.groupMembers[armed.id], "armed for your group: " .. armed.id)
                    end
                    assert.are.same({}, wow.errors, "never an error, caught or not")
                    wow.advance(random.random(0, 3))
                end
            end
            -- The storm did reach passers-by, fighters among them.
            assert.is_true(castCount > 50, castCount .. " casts")
            assert.is_true(fighterCount > 5, fighterCount .. " casts on fighters")
            assert.is_true(armedCount > 50, armedCount .. " presses left the button armed")
            for what, n in pairs(present) do assert.is_true(n > 20, what .. " passers-by present " .. n) end
        end)
    end)
end)
