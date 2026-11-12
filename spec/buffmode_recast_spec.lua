-- Spec: #256
-- What buff mode recasts (#256, part 2): your buff goes over one someone
-- outside the group put up, never over a group member's; your own earlier
-- buff goes out once more in the round that starts as you enter a dungeon or
-- raid; never over anything stronger than you know, and one Blessing each.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1 = 9885, 1126
local KINGS, MIGHT_1 = 20217, 19740
local DEADMINES = 36

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("What buff mode recasts (#256)", function()
    local ns

    -- A druid who knows Mark of the Wild (opts.known: other ranks), with
    -- buff mode on (opts.off: not), triggers off.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ before = function(state)
            state.class = opts.class or "DRUID"
            state.knownSpells = opts.known or { [MOTW_1] = true, [MOTW] = true }
        end })
        if opts.order then ns.db.buffBack.buffOrder = opts.order end
        if not opts.off then slash("buffmode on") end
    end

    local function group(kind, names)
        wow.setGroup(kind or "party", names or { "Ann-Vale", "Cid-Rock" })
        wow.fire("GROUP_ROSTER_UPDATE")
    end

    local function tokenOf(id)
        for token, u in pairs(wow.state.units) do
            if u.id == id and token ~= "target" and token ~= "player" then return token end
        end
    end

    -- Press once; the buff lands on its target as yours, replacing any of the
    -- same spell, as the game does. The cast, or nil.
    local function press()
        local before = #wow.casts
        wow.pressKey("MOUSEWHEELUP")
        local cast = wow.casts[before + 1]
        if cast and not cast.failed then
            local token = tokenOf(cast.target)
            if token then wow.wearBuff(token, cast.id, { source = "player" }) end
        end
        return cast
    end

    -- Who the next press would buff, and with what ("Ann-Vale 9885"), or nil.
    local function next()
        local offer = ns.GroupBuffs.Next()
        return offer and offer.name
    end

    describe("in a party (white)", function()
        before_each(function() boot() group() end)

        it("offers your buff over one someone outside the group put up", function()
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone" })
            wow.wearBuff("party1", MOTW, { source = "nameplate1" }) -- a stranger nearby
            wow.wearBuff("party2", MOTW, { source = "party1" })     -- Ann's: a group member's
            assert.are.equal("Ann-Vale", next())
            local cast = press()
            assert.are.equal("Ann-Vale", cast.target)
            assert.is_nil(next(), "Ann has yours now, and Cid's is a group member's")
            local _, _, settled = ns.GroupBuffs.Next()
            assert.is_true(settled)
        end)

        it("a caster the game doesn't name is someone outside the group (the owner's decision)", function()
            wow.wearBuff("party1", MOTW, { source = false })
            wow.wearBuff("party2", MOTW, { source = "player" })
            assert.are.equal("Ann-Vale", next())
        end)

        it("never casts over a buff a group member put up, whatever token names them", function()
            wow.wearBuff("party1", MOTW, { source = "party2" })
            wow.addUnit("nameplate2", { name = "Ann", surname = "Vale", id = "Ann-Vale" })
            wow.wearBuff("party2", MOTW, { source = "nameplate2" }) -- Ann, seen on a nameplate
            assert.is_nil(next())
            local _, why, settled = ns.GroupBuffs.Next()
            assert.are.equal("everyone in your group has your buffs", why)
            assert.is_true(settled)
        end)

        it("leaves your own buff be outside a dungeon or raid round", function()
            wow.wearBuff("party1", MOTW, { source = "player" })
            wow.wearBuff("party2", MOTW, { source = "player" })
            assert.is_nil(next())
        end)

        it("applies out in the world too, in any party, whenever buff mode offers group buffs", function()
            assert.is_false(wow.state.inInstance == true)
            wow.wearBuff("party1", MOTW, { source = false })
            wow.wearBuff("party2", MOTW, { source = "player" })
            assert.are.equal("Ann-Vale", press().target)
            assert.is_nil(press())
        end)

        it("never over anything stronger than a rank you know (#41)", function()
            boot({ known = { [MOTW_1] = true } }) -- rank 1 only
            group()
            wow.wearBuff("party1", MOTW, { source = false })   -- a stranger's rank 7
            wow.wearBuff("party2", MOTW_1, { source = false }) -- a stranger's rank 1: yours renews it
            assert.are.equal("Cid-Rock", next())
            press()
            assert.is_nil(next(), "the stranger's rank 7 on Ann is left to run")
        end)
    end)

    describe("on entering a dungeon or raid: whoever buffs first (white)", function()
        -- Your Marks, put up 10 minutes before you enter: out of step.
        local LONG_AGO, LATELY = 600, 120
        before_each(function()
            boot()
            group()
            wow.wearBuff("party1", MOTW, { source = "player" })
            wow.wearBuff("party2", MOTW, { source = "player" })
            wow.advance(LONG_AGO)
        end)

        it("offers each member your buff once more, so the timers line up, then not again", function()
            assert.is_nil(next())
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_true(ns.GroupBuffs.InRound())
            local given = {}
            for _ = 1, 5 do
                local cast = press()
                if not cast then break end
                given[#given + 1] = cast.target
            end
            assert.are.same({ "Ann-Vale", "Cid-Rock" }, given)
        end)

        it("in a raid as well", function()
            wow.setGroup("raid", { "Ann-Vale", "Cid-Rock" })
            wow.addUnit("raid3", wow.state.units.player) -- your own raid slot (#255)
            wow.wearBuff("raid1", MOTW, { source = "player" })
            wow.advance(LONG_AGO)
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.enterRaid(409, "Molten Core")
            assert.are.equal("Ann-Vale", press().target)
        end)

        it("starts whatever the turn-on switch says: it's about what's cast, not when", function()
            ns.db.buffBack.autoOnJoin = false
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal("Ann-Vale", next())
        end)

        it("ends at the first pull: your earlier buff is left be after it", function()
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal("Ann-Vale", press().target)
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_false(ns.GroupBuffs.InRound())
            assert.is_nil(next(), "Cid keeps your earlier buff")
        end)

        it("ends at a login or reload, even inside (buff mode starts over then)", function()
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_true(ns.GroupBuffs.InRound())
            wow.reloadInPlace()
            assert.is_false(ns.GroupBuffs.InRound())
        end)

        it("ends when you leave the instance, or the group", function()
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.leaveDungeon()
            assert.is_false(ns.GroupBuffs.InRound())
            assert.is_nil(next())
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_true(ns.GroupBuffs.InRound(), "a new entry, a new round")
            wow.setGroup(nil, {})
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(ns.GroupBuffs.InRound())
        end)

        it("a buff another member put up within 5 minutes before you entered is in step: left alone", function()
            wow.advance(ns.GroupBuffs.SYNCED_SECONDS - LATELY)
            wow.wearBuff("party2", MOTW, { source = "party1" }) -- Ann's, 2 minutes before you enter
            wow.advance(LATELY)
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_nil(press(), "first the button says it's already done (rule 2): a press does nothing")
            wow.advance(ns.BuffButton.ALREADY_DONE_SECONDS)
            assert.are.equal("Ann-Vale", press().target, "yours on Ann, 10 minutes old: recast")
            assert.is_nil(press(), "Cid wears Ann's, still in step")
        end)

        it("a buff another member put up more than 5 minutes before you entered is recast once", function()
            wow.wearBuff("party2", MOTW, { source = "party1" })
            wow.advance(LONG_AGO)
            wow.enterDungeon(DEADMINES, "The Deadmines")
            local given = {}
            for _ = 1, 4 do
                local cast = press()
                if not cast then break end
                given[#given + 1] = cast.target
            end
            assert.are.same({ "Ann-Vale", "Cid-Rock" }, given)
        end)

        it("your own buff put up within 5 minutes before you entered is in step too", function()
            wow.wearBuff("party1", MOTW, { source = "player" })
            wow.wearBuff("party2", MOTW, { source = "player" })
            wow.advance(LATELY)
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_nil(next())
        end)

        it("measures from when you entered: a buff in step then stays in step", function()
            wow.wearBuff("party1", MOTW, { source = "party2" })
            wow.wearBuff("party2", MOTW, { source = "party1" })
            wow.advance(LATELY)
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.advance(10 * 60)
            assert.is_nil(next(), "12 minutes old now, but in step with the others when you entered")
        end)

        it("never recasts over a buff whose time can't be read", function()
            wow.state.units.party1.auraDurations[1] = nil
            wow.state.units.party2.auraExpires[1] = wow.secret(wow.now + 100)
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_nil(next())
            local _, _, settled = ns.GroupBuffs.Next()
            assert.is_true(settled, "a time that can't be read counts as having it")
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("after entering: another member's buff is theirs until it runs low (white)", function()
        before_each(function() boot() group() end)

        it("is left alone with time left, then renewed by top-up when it runs low", function()
            wow.wearBuff("party1", MOTW, { source = "party2", duration = 3600 })
            wow.wearBuff("party2", MOTW, { source = "player", duration = 3600 })
            assert.is_nil(next())
            wow.state.units.party1.auraExpires[1] = wow.now + 60 -- under the 5-minute top-up time
            assert.are.equal("Ann-Vale", press().target)
        end)
    end)

    describe("Blessings (white)", function()
        -- A paladin who knows Kings and Might, giving Kings first.
        before_each(function()
            boot({ class = "PALADIN", known = { [KINGS] = true, [MIGHT_1] = true }, order = { "kings", "might" } })
            group()
        end)

        it("keeps one Blessing of yours each: a stranger's Kings on someone with your Might stays", function()
            wow.wearBuff("party1", MIGHT_1, { source = "player" })
            wow.wearBuff("party1", KINGS, { source = false })
            wow.wearBuff("party2", MIGHT_1, { source = "player" })
            assert.is_nil(next(), "Kings over the stranger's would give Ann a second Blessing of yours")
        end)

        it("recasts your own Blessing once in the round, never switching it to another", function()
            wow.wearBuff("party1", MIGHT_1, { source = "player" })
            wow.wearBuff("party2", MIGHT_1, { source = "player" })
            wow.advance(600)
            wow.enterDungeon(DEADMINES, "The Deadmines")
            local cast = press()
            assert.are.equal("Ann-Vale", cast.target)
            assert.are.equal(MIGHT_1, cast.id, "her Might renewed, not turned into Kings")
        end)
    end)

    describe("\"Already done by\" on the button (white, the owner's rule 2)", function()
        local button
        local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end
        local function listShown()
            local frame = ns.BuffList.Frame()
            return frame ~= nil and frame:IsShown()
        end

        -- Ann wears Cid's Mark, put up 2 minutes before you enter (in step);
        -- Dot wears yours from 10 minutes before (out of step: yours again).
        before_each(function()
            boot()
            button = ns.BuffButton.Frame()
            group("party", { "Ann-Vale", "Cid-Rock", "Dot-Fern" })
            wow.wearBuff("party3", MOTW, { source = "player" })
            wow.advance(480)
            wow.wearBuff("party1", MOTW, { source = "party2" })
            wow.wearBuff("party2", MOTW, { source = "party1" })
            wow.advance(120)
            wow.enterDungeon(DEADMINES, "The Deadmines")
        end)

        it("shows the skipped buff in red for 2 seconds, empty, then the next buff you need", function()
            assert.are.equal(ns.Colours.Text("bad", "Already done by Cid Rock"), button.title:GetText())
            assert.are.equal("Mark of the Wild", button.subtitle:GetText())
            assert.is_true(button:IsShown())
            assert.is_nil(macro(), "a press while it shows does nothing")
            assert.is_false(listShown(), "no row in the list for it")
            wow.advance(ns.BuffButton.ALREADY_DONE_SECONDS - 0.1)
            assert.is_nil(macro())
            wow.advance(0.1)
            assert.are.equal("Dot Fern", button.title:GetText(), "then the next buff you need")
            assert.is_truthy(macro())
        end)

        it("fades out over its last half second", function()
            assert.are.equal(1, button.title:GetAlpha())
            wow.advance(1.4)
            assert.are.equal(1, button.title:GetAlpha())
            wow.advance(0.3)
            local alpha = button.title:GetAlpha()
            assert.is_true(alpha > 0 and alpha < 1, "fading: " .. alpha)
            wow.advance(0.3)
            assert.are.equal(1, button.title:GetAlpha(), "the next buff shows at full strength")
        end)

        it("shows once per buff each time you enter", function()
            wow.advance(ns.BuffButton.ALREADY_DONE_SECONDS)
            press() -- Dot
            ns.BuffButton.Refresh()
            assert.is_falsy(button.title:GetText():find("Already done", 1, true), "not again this time")
            wow.leaveDungeon()
            wow.enterDungeon(DEADMINES, "The Deadmines")
            ns.BuffButton.Refresh()
            assert.is_truthy(button.title:GetText():find("Already done by", 1, true), "again on the next entry")
        end)

        it("names whoever cast it most recently", function()
            wow.leaveDungeon()
            wow.advance(30)
            wow.wearBuff("party2", MOTW, { source = "party1" }) -- Ann's, newer than Cid's on Ann
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal(ns.Colours.Text("bad", "Already done by Ann Vale"), button.title:GetText())
        end)

        it("says \"a group member\" when the caster's name can't be read", function()
            wow.leaveDungeon()
            -- Cid, seen on a nameplate whose name the game gives as a secret.
            wow.addUnit("nameplate5", { name = "Cid", surname = "Rock", id = "Cid-Rock", secrets = { name = true } })
            wow.state.units.party1.auraSources[1] = "nameplate5"
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.are.equal(ns.Colours.Text("bad", "Already done by a group member"), button.title:GetText())
            assert.are.same({}, wow.errors)
        end)

        it("empties a button that held a buff before you entered: a press during it casts nothing", function()
            wow.leaveDungeon()
            wow.wearBuff("party3", MOTW, { source = false }) -- a stranger's on Dot: yours goes over it
            ns.BuffButton.Refresh()
            assert.is_truthy(macro(), "Dot's buff was armed")
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_truthy(button.title:GetText():find("Already done by", 1, true))
            assert.is_nil(macro())
            assert.is_nil(press(), "nothing casts")
        end)

        it("no note for a member's old buff the round has already counted as given to them", function()
            wow.leaveDungeon()
            wow.advance(600) -- Cid's on Ann is old now: out of step
            wow.enterDungeon(DEADMINES, "The Deadmines")
            ns.BuffButton.Refresh()
            local offer = ns.GroupBuffs.Next()
            -- Your press went out but the game didn't say whom it reached (#213).
            ns.GroupBuffs.NoteRoundCast("Ann-Vale", offer.buff)
            ns.GroupBuffs.NoteRoundCast("Cid-Rock", offer.buff)
            ns.BuffButton.Refresh()
            assert.is_falsy((button.title:GetText() or ""):find("Already done", 1, true))
        end)

        it("a fight clears it", function()
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_falsy(button.title:GetText():find("Already done", 1, true))
        end)

        it("isn't shown for your own buff in step: only another member's", function()
            boot()
            button = ns.BuffButton.Frame()
            group()
            wow.wearBuff("party1", MOTW, { source = "player" })
            wow.wearBuff("party2", MOTW, { source = "player" })
            wow.advance(60)
            wow.enterDungeon(DEADMINES, "The Deadmines")
            ns.BuffButton.Refresh()
            assert.is_falsy((button.title:GetText() or ""):find("Already done", 1, true))
        end)
    end)

    describe("in a raid: the raid buff split decides (white)", function()
        it("recasts over a stranger's buff only for the Blessings that are yours in this raid", function()
            boot({ class = "PALADIN", known = { [KINGS] = true, [MIGHT_1] = true }, order = { "kings", "might" } })
            group("raid", { "Ann-Vale", "Cid-Rock" })
            assert.is_true(ns.BuffRules.SetRaidBlessings({ "might" }))
            wow.wearBuff("raid1", KINGS, { source = false })   -- not yours to give here...
            wow.wearBuff("raid1", MIGHT_1, { source = "player" }) -- ...and she has your Might
            wow.wearBuff("raid2", MIGHT_1, { source = false }) -- yours to give: recast over it
            local cast = press()
            assert.are.equal("Cid-Rock", cast.target)
            assert.are.equal(MIGHT_1, cast.id)
            assert.is_nil(press(), "Ann's stranger's Kings isn't yours to replace in this raid")
        end)
    end)

    describe("group versions (black)", function()
        local INTELLECT, BRILLIANCE = 10157, 23028

        -- A mage with Arcane Intellect, Arcane Brilliance and its powder, in a party of 4.
        local function mage()
            ns = wow.boot({ before = function(state)
                state.class = "MAGE"
                state.knownSpells = { [INTELLECT] = true, [BRILLIANCE] = true }
                state.items = { [wow.ITEM.arcanePowder] = 5 }
            end })
            slash("buffmode on")
            group("party", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
        end

        it("Arcane Brilliance goes out when the others are missing it and Ann's Intellect is a stranger's", function()
            mage()
            wow.wearBuff("party1", INTELLECT, { source = false })
            local offer = ns.GroupBuffs.Next()
            assert.is_truthy(offer.cast, "the group version, over the stranger's")
        end)

        it("isn't offered while someone it would cover wears a buff whose caster can't be read", function()
            mage()
            wow.wearBuff("party1", INTELLECT, { source = wow.secret("nameplate1") })
            local offer = ns.GroupBuffs.Next()
            assert.is_nil(offer.cast, "single buffs instead")
            assert.are_not.equal("Ann-Vale", offer.name, "and never on Ann")
            assert.are.equal("Can't tell who cast Ann Vale's buff: buffing one at a time", offer.note or offer.hint)
            assert.are.same({}, wow.errors)
        end)

        it("isn't offered while someone it would cover wears another member's buff with time left (the owner)", function()
            mage()
            wow.wearBuff("party1", INTELLECT, { source = "party2", duration = 3600 })
            local offer = ns.GroupBuffs.Next()
            assert.is_nil(offer.cast, "single buffs instead")
            assert.are_not.equal("Ann-Vale", offer.name)
            assert.are.equal("Ann Vale's buff is another group member's: buffing one at a time", offer.note or offer.hint)
            wow.state.units.party1.auraExpires[1] = wow.now + 60 -- running low
            assert.is_truthy(ns.GroupBuffs.Next().cast, "running low: the group version renews it")
        end)
    end)

    describe("the round when the game doesn't say whom a cast reached (black)", function()
        it("counts your press as given, so the next press moves on (UNIT_SPELLCAST_SENT names nobody)", function()
            ns = wow.boot({ buffSelf = true, before = function(state)
                state.class = "DRUID"
                state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
                state.sentTargetForm = "none"
            end })
            slash("buffmode on")
            group()
            wow.gainBuff({ sourceUnit = "player", name = "Mark of the Wild", spellId = MOTW,
                duration = 3600, expirationTime = wow.now + 3600 })
            wow.wearBuff("party1", MOTW, { source = "player" })
            wow.wearBuff("party2", MOTW, { source = "player" })
            wow.advance(600)
            wow.enterDungeon(DEADMINES, "The Deadmines")
            local targets = {}
            for _ = 1, 3 do
                local before = #wow.casts
                wow.pressKey("MOUSEWHEELUP")
                local cast = wow.casts[before + 1]
                targets[#targets + 1] = cast and cast.target or "-"
            end
            assert.are.equal(3, #targets)
            local mine = 0
            for _, t in ipairs(targets) do if t ~= "Ann-Vale" and t ~= "Cid-Rock" then mine = mine + 1 end end
            assert.are.equal(1, mine, "you once, then the others: " .. table.concat(targets, ", "))
        end)
    end)

    describe("what it can't read (black)", function()
        before_each(function() boot() group() end)

        it("never casts over a buff whose caster is a secret, and that member isn't done", function()
            wow.wearBuff("party1", MOTW, { source = wow.secret("nameplate1") })
            wow.wearBuff("party2", MOTW, { source = "party1" })
            assert.is_nil(press())
            local offer, why, settled = ns.GroupBuffs.Next()
            assert.is_nil(offer)
            assert.are.equal("Ann Vale: can't tell who cast their buff", why)
            assert.is_false(settled, "not counted as buffed")
            assert.are.same({}, wow.errors)
        end)

        it("never casts over a buff when the game won't say whether its caster is in the group", function()
            wow.state.units.party2.targetUnreadable = true
            wow.wearBuff("party1", MOTW, { source = "party2target" }) -- whoever Cid targets: can't be read
            wow.wearBuff("party2", MOTW, { source = "party1" })
            assert.is_nil(press())
            local _, _, settled = ns.GroupBuffs.Next()
            assert.is_false(settled)
            assert.are.same({}, wow.errors)
        end)

        it("never casts over a buff when the game says it isn't yours but won't say whether it's a member's", function()
            wow.addUnit("nameplate3", { name = "Bob", surname = "Stone", id = "Bob-Stone" })
            wow.wearBuff("party1", MOTW, { source = "nameplate3" })
            wow.wearBuff("party2", MOTW, { source = "party1" })
            local real = _G.UnitIsUnit
            _G.UnitIsUnit = function(a, b)
                if a == "nameplate3" and b ~= "player" then return nil end -- can't be compared with the group
                return real(a, b)
            end
            assert.is_nil(press())
            local _, why, settled = ns.GroupBuffs.Next()
            assert.are.equal("Ann Vale: can't tell who cast their buff", why)
            assert.is_false(settled)
            _G.UnitIsUnit = real
            assert.are.equal("Ann-Vale", next(), "once it can be told: a stranger's, so yours goes over it")
        end)

        it("in a dungeon, a member whose buff caster can't be read keeps buff mode on until the pull", function()
            ns = wow.boot({ autoBuffMode = true, before = function(state)
                state.class = "DRUID"
                state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
            end })
            group()
            slash("buffmode off")
            wow.wearBuff("party1", MOTW, { source = wow.secret("nameplate1") })
            wow.wearBuff("party2", MOTW, { source = "party1" })
            wow.enterDungeon(DEADMINES, "The Deadmines")
            assert.is_true(ns.BuffMode.IsAuto())
            wow.advance(60)
            assert.is_true(ns.BuffMode.IsAuto(), "not in and buffed")
            assert.is_nil(press())
            wow.enterCombat()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("whether you cast it: an unnamed caster is not you; a secret or junk caster can't be told", function()
            assert.is_false(ns.Util.CastByYou(nil))
            assert.is_true(ns.Util.CastByYou("player"))
            assert.is_false(ns.Util.CastByYou("party1"))
            assert.is_nil(ns.Util.CastByYou(wow.secret("player")))
            assert.is_nil(ns.Util.CastByYou(42))
            assert.are.same({}, wow.errors)
        end)

        it("nothing casts without a press", function()
            wow.wearBuff("party1", MOTW, { source = false })
            wow.enterDungeon(DEADMINES, "The Deadmines")
            wow.advance(60)
            ns.BuffButton.Refresh()
            assert.are.equal(0, #wow.casts)
        end)
    end)

    describe("chaos (red)", function()
        -- Why a cast of Mark on this unit table would break the owner's rules,
        -- or nil, worked out from the simulated client's own state and the
        -- storm's own record of the round (when you entered, whom it gave
        -- to), never from the addon's:
        --   never over a secret caster, nor a rank stronger than you know;
        --   a group member's buff, or yours, only when it's running low
        --   (top-up: an hour-long buff with under 5 minutes left), or in the
        --   round when it was put up over 5 minutes before you entered, with
        --   a time that can be read, and the round hasn't given it yet.
        local MEMBERS = { "Ann-Vale", "Cid-Rock", "Dot-Fern" }
        local TOP_UP = 5 * 60
        local function forbidden(u, known, round)
            for i, id in ipairs(u.auras or {}) do
                if (id == MOTW or id == MOTW_1) and not wow.auraExpired(u, i) then
                    local src = u.auraSources and u.auraSources[i]
                    if src == nil then src = "player" end -- the simulated client's default
                    if type(src) == "table" then return "a secret caster" end
                    if not known[id] then return "a stronger rank than you know" end
                    if src == "player" or (type(src) == "string" and src:find("^party%d")) then
                        local duration, expires = u.auraDurations[i], u.auraExpires[i]
                        local low = duration > TOP_UP and expires - wow.now < TOP_UP
                        local old = round and not round.given[u.id] and expires - duration < round.started - TOP_UP
                        if not (low or old) then return "a group member's (or your) buff in step" end
                    end
                end
            end
        end

        local function storm(seed)
            random.seed(seed)
            local known = random.random() < 0.5 and { [MOTW_1] = true } or { [MOTW_1] = true, [MOTW] = true }
            boot({ known = known })
            group("party", MEMBERS)
            local recastOver, rounds = 0, 0
            local round -- the storm's own record: { started, given = { [id] = true } }
            local sources = { "player", "party1", "party2", "party3", false, "nameplate1", "secret" }
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone" })
            local actions = {
                function()
                    local token = "party" .. random.random(1, 3)
                    if not wow.state.units[token] then return end
                    local src = sources[random.random(#sources)]
                    if src == "secret" then src = wow.secret("nameplate1") end
                    wow.wearBuff(token, random.random() < 0.5 and MOTW or MOTW_1,
                        { source = src, duration = random.random(60, 3600) })
                end,
                function()
                    local u = wow.state.units["party" .. random.random(1, 3)]
                    if u then u.auras, u.auraSources = {}, {} end
                end,
                function()
                    if wow.state.inInstance then
                        wow.leaveDungeon()
                        round = nil
                    else
                        wow.enterDungeon(DEADMINES, "x")
                        round = { started = wow.now, given = {} }
                        rounds = rounds + 1
                    end
                end,
                function() wow.enterCombat() wow.leaveCombat() round = nil end,
                function() wow.advance(random.random(1, 900)) end,
                function() -- someone joins or leaves (the same members, a new order)
                    local names = {}
                    for _, n in ipairs(MEMBERS) do if random.random() < 0.8 then names[#names + 1] = n end end
                    if #names == 0 then names = { MEMBERS[1] } end
                    wow.setGroup("party", names)
                    wow.fire("GROUP_ROSTER_UPDATE")
                end,
                "press", "press", "press",
            }
            for step = 1, 300 do
                local where = ("seed %d, step %d"):format(seed, step)
                local action = actions[random.random(#actions)]
                if action == "press" then
                    -- What the client says about the target before the press.
                    local offer = ns.GroupBuffs.Next()
                    local target = offer and tokenOf(offer.name)
                    local u = target and wow.state.units[target]
                    local why = u and forbidden(u, known, round)
                    local had = false
                    for i, id in ipairs(u and u.auras or {}) do
                        had = had or ((id == MOTW or id == MOTW_1) and not wow.auraExpired(u, i))
                    end
                    local before = #wow.casts
                    local cast = press()
                    if cast and u and cast.target == u.id then
                        assert.is_nil(why, where .. ": cast over " .. tostring(why))
                        if had then recastOver = recastOver + 1 end
                        if round then round.given[u.id] = true end
                    end
                    assert.is_true(#wow.casts <= before + 1, where .. ": more than one cast for one press")
                else
                    local before = #wow.casts
                    action()
                    assert.are.equal(before, #wow.casts, where .. ": a cast without a press")
                end
                assert.are.same({}, wow.errors, where)
            end
            return recastOver, rounds
        end

        it("buffs from members, strangers, unnamed and secret casters: never over a member's, a secret's or a stronger one",
            function()
                local over, rounds = 0, 0
                for seed = 1, 40 do
                    local a, b = storm(seed)
                    over, rounds = over + a, rounds + b
                end
                assert.is_true(over > 20, "recast over a buff " .. over .. " times")
                assert.is_true(rounds > 5, "entered with a round " .. rounds .. " times")
            end)
    end)
end)
