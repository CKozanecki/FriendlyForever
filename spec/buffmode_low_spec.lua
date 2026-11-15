-- Spec: #397
-- A buff running low counts by the buff's length: one whose full time is 10
-- minutes or less (Thorns) runs low at 1 minute left, a longer one at the
-- Top up time. The same rule decides what the button tops up and what turns
-- buff mode back on (BuffModeAuto.lua's missing-buff trigger, #272). Buff
-- mode you turn off yourself isn't turned back on by the same member's same
-- buff until it has been recast. Nothing here casts.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, THORNS = 9885, 9910
local FORTITUDE = 10938
local INTELLECT = 10157
local TEN_MINUTES, HALF_HOUR = 600, 1800

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

local function printedHas(fragment)
    for _, line in ipairs(wow.printed) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

describe("Buff mode and top-up for a buff running low (#397)", function()
    local ns

    -- A caster of class (default a druid knowing Mark of the Wild and Thorns),
    -- with only the missing-buff trigger on, and the buffs' own rules (Thorns:
    -- Tanks only).
    local function boot(opts)
        opts = opts or {}
        local buffBack = { autoOnJoin = false, autoOnDeath = false, autoOnBuffed = false }
        for k, v in pairs(opts.buffBack or {}) do buffBack[k] = v end
        ns = wow.boot({ db = { buffBack = buffBack }, autoBuffMode = true, buffDefaults = true, before = function(state)
            state.class = opts.class or "DRUID"
            state.knownSpells = opts.known or { [MOTW] = true, [THORNS] = true }
        end })
    end

    -- Tank Tom (party1, a warrior with the tank role) and Ann (party2, a
    -- mage), both wearing your Mark for half an hour; Tom wears your Thorns
    -- for its 10 minutes.
    local function joinTankAndAnn()
        wow.setGroup("party", { "Tom-Tank", "Ann-Vale" })
        wow.state.units.party1.class, wow.state.units.party1.role = "WARRIOR", "TANK"
        wow.state.units.party2.class = "MAGE"
        wow.wearBuff("party1", MOTW, { source = "player", duration = HALF_HOUR })
        wow.wearBuff("party2", MOTW, { source = "player", duration = HALF_HOUR })
        wow.wearBuff("party1", THORNS, { source = "player", duration = TEN_MINUTES })
        wow.fire("GROUP_ROSTER_UPDATE")
    end

    -- Set token's spell to secondsLeft from now (its full time kept).
    local function leave(token, spell, secondsLeft)
        local u = wow.state.units[token]
        for i, id in ipairs(u.auras) do
            if id == spell then u.auraExpires[i] = wow.now + secondsLeft end
        end
    end

    local function look() wow.advance(ns.BuffModeAuto.WATCH_SECONDS + 0.1) end

    -- Whether buff mode's button would offer spell to the member called name.
    local function offers(name, spellName)
        local list = {}
        ns.GroupBuffs.Next(list)
        for _, offer in ipairs(list) do
            if offer.name == name and offer.spell == spellName then return true end
        end
        return false
    end

    before_each(function() boot() end)

    describe("what the button tops up (white)", function()
        it("Thorns (10 minutes) on the tank isn't offered at 2 minutes left, and is at 59 seconds", function()
            joinTankAndAnn()
            assert.are.equal(5, ns.db.buffBack.topUpMinutes)
            leave("party1", THORNS, 120)
            assert.is_false(offers("Tom-Tank", "Thorns"), "2 minutes left: under Top up, but a short buff")
            leave("party1", THORNS, 60)
            assert.is_false(offers("Tom-Tank", "Thorns"), "exactly a minute isn't under a minute")
            leave("party1", THORNS, 59)
            assert.is_true(offers("Tom-Tank", "Thorns"))
        end)

        it("a short buff runs low at a minute whatever the Top up time; 0 still means never", function()
            joinTankAndAnn()
            ns.db.buffBack.topUpMinutes = 15
            leave("party1", THORNS, 300)
            assert.is_false(offers("Tom-Tank", "Thorns"), "15 minutes would offer it at once")
            leave("party1", THORNS, 30)
            assert.is_true(offers("Tom-Tank", "Thorns"))
            ns.db.buffBack.topUpMinutes = 0
            assert.is_false(offers("Tom-Tank", "Thorns"), "0: worn until it's gone")
        end)

        it("Fortitude (30 minutes) is offered under the Top up time, as before", function()
            boot({ class = "PRIEST", known = { [FORTITUDE] = true } })
            wow.setGroup("party", { "Ann-Vale" })
            wow.state.units.party1.class = "MAGE"
            wow.wearBuff("party1", FORTITUDE, { source = "player", duration = HALF_HOUR })
            wow.fire("GROUP_ROSTER_UPDATE")
            local name = "Power Word: Fortitude"
            leave("party1", FORTITUDE, 301)
            assert.is_false(offers("Ann-Vale", name))
            leave("party1", FORTITUDE, 299)
            assert.is_true(offers("Ann-Vale", name), "under 5 minutes")
            ns.db.buffBack.topUpMinutes = 10
            leave("party1", FORTITUDE, 599)
            assert.is_true(offers("Ann-Vale", name), "under 10 minutes")
        end)

        it("a buff exactly 10 minutes long is short; one a second longer isn't", function()
            joinTankAndAnn()
            wow.wearBuff("party1", THORNS, { source = "player", duration = TEN_MINUTES + 1 })
            leave("party1", THORNS, 120)
            assert.is_true(offers("Tom-Tank", "Thorns"), "over 10 minutes: the Top up time")
        end)
    end)

    describe("turning buff mode on (white)", function()
        it("out of combat, the tank's Thorns dropping under a minute turns it on", function()
            joinTankAndAnn()
            look()
            assert.is_false(ns.BuffMode.IsOn(), "everyone is covered")
            leave("party1", THORNS, 120)
            look()
            assert.is_false(ns.BuffMode.IsOn(), "2 minutes left isn't low for a short buff")
            leave("party1", THORNS, 59)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("(Tom Tank's Thorns is running low)"))
            assert.are.same({}, wow.casts, "turning on never casts")
        end)

        it("a 30-minute buff dropping under the Top up time turns it on", function()
            joinTankAndAnn()
            look()
            leave("party2", MOTW, 320) -- a look later, still over 5 minutes
            look()
            assert.is_false(ns.BuffMode.IsOn())
            leave("party2", MOTW, 299)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("(Ann Vale's Mark of the Wild is running low)"))
        end)

        it("your own buff running low counts too (#198)", function()
            boot()
            wow.state.units.player.role = "TANK"
            ns.GroupBuffs.SELF_ORDER = "first"
            joinTankAndAnn()
            wow.gainBuff({ spellId = MOTW, sourceUnit = "player", duration = HALF_HOUR,
                expirationTime = wow.now + HALF_HOUR })
            wow.gainBuff({ spellId = THORNS, sourceUnit = "player", duration = TEN_MINUTES,
                expirationTime = wow.now + TEN_MINUTES })
            look()
            assert.is_false(ns.BuffMode.IsOn())
            for _, aura in ipairs(wow.state.playerAuras) do
                if aura.spellId == THORNS then aura.expirationTime = wow.now + 30 end
            end
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("(your Thorns is running low)"))
        end)
    end)

    describe("after you turn buff mode off (white)", function()
        -- The tank's Thorns runs low and turns buff mode on; you turn it off.
        local function dismissTankThorns(how)
            joinTankAndAnn()
            look()
            leave("party1", THORNS, 50)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            if how == "key" then _G.FriendlyForever_ToggleBuffMode() else slash("buffmode off") end
            assert.is_false(ns.BuffMode.IsOn())
        end

        it("stays off for that Thorns, through its fading and a fight; another member's buff running low brings it back", function()
            dismissTankThorns()
            look()
            assert.is_false(ns.BuffMode.IsOn(), "the same Thorns, still low")
            leave("party1", THORNS, -1) -- gone now
            look()
            assert.is_false(ns.BuffMode.IsOn(), "the same Thorns, faded")
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn(), "not even as a fight ends")
            leave("party2", MOTW, 200) -- Ann's Mark runs low
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("(Ann Vale's Mark of the Wild is running low)"))
        end)

        it("the key binding is turning it off yourself too", function()
            dismissTankThorns("key")
            look()
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("the same Thorns, recast, brings it back when it runs low again", function()
            dismissTankThorns()
            wow.wearBuff("party1", THORNS, { source = "player", duration = TEN_MINUTES }) -- a fresh copy
            look()
            assert.is_false(ns.BuffMode.IsOn())
            leave("party1", THORNS, 40)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("a recast fight-end still counts: a fresh copy that faded in a fight turns it on as it ends", function()
            dismissTankThorns()
            wow.wearBuff("party1", THORNS, { source = "player", duration = TEN_MINUTES })
            look()
            wow.enterCombat()
            wow.state.units.party1.auras = {} -- dispelled
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("turned off in a fight, what ran low in it doesn't bring it back as the fight ends", function()
            joinTankAndAnn()
            look()
            slash("buffmode on") -- yours: the pull leaves it on
            wow.enterCombat()
            leave("party1", THORNS, 40) -- low mid-fight: no look in a fight
            slash("buffmode off")
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn(), "off, as you asked")
            leave("party2", MOTW, 200) -- another buff running low still does
            look()
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("what ran low since the last look, out of combat, is dismissed too", function()
            joinTankAndAnn()
            look()
            slash("buffmode on")
            leave("party1", THORNS, 40)
            slash("buffmode off") -- before the next look
            look()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("a member out of range when you turn it off: the same Thorns still doesn't bring it back", function()
            joinTankAndAnn()
            look()
            leave("party1", THORNS, 50)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.state.units.party1.outOfRange = true
            look() -- not looked at: kept as low
            slash("buffmode off")
            wow.state.units.party1.outOfRange = nil
            look()
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("leaving the group and joining one again forgets what you dismissed", function()
            dismissTankThorns()
            wow.setGroup(nil, {})
            wow.fire("GROUP_ROSTER_UPDATE")
            look()
            joinTankAndAnn()
            wow.state.units.party1.auras = { MOTW } -- no Thorns, and not recast: still Tom's dismissed pair
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("(Tom Tank is missing your Thorns)"))
        end)

        it("a copy whose time can't be read isn't a recast, and breaks nothing", function()
            dismissTankThorns()
            wow.state.units.party1.secrets = { auraTimes = true }
            look()
            wow.state.units.party1.secrets = nil
            look()
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end)

        it("turning it on yourself dismisses nothing", function()
            ns.db.buffBack.autoOffMinutes = 1
            joinTankAndAnn()
            look()
            leave("party2", MOTW, 290)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.advance(61) -- timed out, Ann's Mark still low
            assert.is_false(ns.BuffMode.IsOn())
            slash("buffmode on")
            ns.db.buffBack.topUpMinutes = 0 -- her Mark isn't low now: seen worn
            look()
            slash("buffmode off")
            ns.db.buffBack.topUpMinutes = 5 -- and low again, the same copy
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "a new drop under the threshold")
        end)

        it("a newer copy that's already low counts as a recast", function()
            ns.db.buffBack.topUpMinutes = 15
            joinTankAndAnn()
            look()
            leave("party2", MOTW, 200)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            slash("buffmode off")
            -- A lower rank, put up just now, with only a few minutes of it.
            wow.wearBuff("party2", 1126, { source = "player", duration = 1000 })
            leave("party2", 1126, 800)
            look()
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto(), "the fresh copy ended the dismissal")
        end)

        it("only you dismiss: buff mode that timed out comes back on as a fight ends with Thorns low", function()
            joinTankAndAnn()
            look()
            leave("party1", THORNS, 55)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.advance(ns.db.buffBack.autoOffMinutes * 60 + 1)
            assert.is_false(ns.BuffMode.IsOn(), "the timeout turned it off")
            wow.enterCombat()
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("saying off when it's already off dismisses nothing", function()
            joinTankAndAnn()
            look()
            leave("party1", THORNS, 50)
            look()
            wow.enterCombat() -- the pull turns it off
            slash("buffmode off")
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
        end)

        it("only you dismiss: buff mode a pull turned off comes back on as the fight ends with Thorns low", function()
            joinTankAndAnn()
            look()
            leave("party1", THORNS, 50)
            look()
            assert.is_true(ns.BuffMode.IsAuto())
            wow.enterCombat()
            assert.is_false(ns.BuffMode.IsOn(), "the first pull turned it off")
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto())
            assert.is_true(printedHas("(the fight ended and Tom Tank's Thorns is running low)"))
        end)
    end)

    describe("what never turns it on (black)", function()
        -- Tom's Thorns runs low with field set on him (or his secrets).
        local function lowWith(set)
            joinTankAndAnn()
            look()
            set(wow.state.units.party1)
            leave("party1", THORNS, 30)
            look()
            wow.enterCombat()
            wow.leaveCombat()
            look()
            return ns.BuffMode.IsOn()
        end

        for _, field in ipairs({ "outOfRange", "rangeUnknown", "dead", "offline", "hidden" }) do
            it("a member " .. field, function()
                assert.is_false(lowWith(function(u) u[field] = true end))
            end)
        end

        for _, secret in ipairs({ "auras", "name", "offline", "range" }) do
            it("a member whose " .. secret .. " can't be read", function()
                assert.is_false(lowWith(function(u) u.secrets = { [secret] = true } end))
            end)
        end

        it("a buff whose time the game won't show (secret, or no times)", function()
            assert.is_false(lowWith(function(u) u.secrets = { auraTimes = true } end))
            boot()
            assert.is_false(lowWith(function(u)
                for i, id in ipairs(u.auras) do
                    if id == THORNS then u.auraDurations[i], u.auraExpires[i] = nil, nil end
                end
            end))
        end)

        it("a buff whose caster can't be read, running low (as the button won't top it up)", function()
            assert.is_false(lowWith(function(u)
                for i, id in ipairs(u.auras) do
                    if id == THORNS then u.auraSources[i] = wow.secret("nameplate1") end
                end
            end))
            assert.is_false(offers("Tom-Tank", "Thorns"))
        end)

        it("in a fight, until it ends", function()
            joinTankAndAnn()
            look()
            wow.enterCombat()
            leave("party1", THORNS, 30)
            look()
            assert.is_false(ns.BuffMode.IsOn(), "in a fight")
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsAuto(), "as it ends")
        end)

        it("a buff you mark Never offer", function()
            boot({ buffBack = { neverOffer = { thorns = true } } })
            assert.is_false(lowWith(function() end))
        end)

        it("Thorns on a member who isn't the tank (Tanks only, by default)", function()
            assert.is_false(lowWith(function(u) u.role = "DAMAGER" end))
        end)

        it("a buff the member's class can't use", function()
            boot({ class = "MAGE", known = { [INTELLECT] = true } })
            wow.setGroup("party", { "Tom-Tank" })
            wow.state.units.party1.class = "WARRIOR"
            wow.wearBuff("party1", INTELLECT, { source = "player", duration = HALF_HOUR })
            wow.fire("GROUP_ROSTER_UPDATE")
            look()
            leave("party1", INTELLECT, 10)
            look()
            assert.is_false(ns.BuffMode.IsOn(), "a warrior has no mana")
            wow.state.units.party1.class = "MAGE"
            look()
            assert.is_true(ns.BuffMode.IsAuto(), "a mage does")
        end)
    end)

    describe("the help says so (white)", function()
        it("the Top up mouse-over, the trigger's mouse-over and the README explain the 1-minute rule", function()
            local stepper = ns.Options.widgets.steppers.topUpMinutes
            assert.are.equal(ns.Options.TOP_UP_TIP, stepper.box.tooltip)
            for _, tip in ipairs({ ns.Options.TOP_UP_TIP, ns.Options.AUTO_MISSING_TIP }) do
                assert.is_truthy(tip:find("10 minutes or less (Thorns)", 1, true), tip)
                assert.is_truthy(tip:find("minute left", 1, true), tip)
            end
            assert.is_truthy(ns.Options.AUTO_MISSING_TIP:find("running low", 1, true))
            local readme = wow.readFile("README.md")
            assert.is_truthy(readme:find("counts only with under 1 minute left", 1, true))
            assert.is_truthy(readme:find("has it running low: under 1 minute left for a buff of 10 minutes or less",
                1, true))
        end)
    end)

    describe("chaos (red)", function()
        local SPELLS = { [THORNS] = "Thorns", [MOTW] = "Mark of the Wild" }
        local NAMES = { "Tom-Tank", "Ann-Vale", "Cid-Rock", "Dot-Fern" }

        -- The client's own answer, never the addon's: the threshold for a
        -- buff of this full time under topUp minutes.
        local function threshold(duration, topUp)
            if topUp == 0 then return 0 end
            if duration <= TEN_MINUTES then return 60 end
            return topUp * 60
        end

        -- Whether u has no copy of spell with time to spare: every copy gone,
        -- or running low as the button would top it up.
        local function lowOrMissing(u, spell, topUp)
            for i in ipairs(u.auras or {}) do
                -- Hidden buffs: only a member wearing none at all is plain.
                if u.secrets and u.secrets.auras and not wow.auraExpired(u, i) then return false end
            end
            for i, id in ipairs(u.auras or {}) do
                if id == spell and not wow.auraExpired(u, i) then
                    -- A copy whose time is hidden is never low.
                    if u.secrets and u.secrets.auraTimes then return false end
                    local duration, expires = u.auraDurations[i], u.auraExpires[i]
                    local limit = threshold(duration, topUp)
                    if not (duration > limit and expires - wow.now < limit) then return false end
                end
            end
            return true
        end

        local function unitNamed(display)
            for i = 1, 4 do
                local u = wow.state.units["party" .. i]
                if u and u.id == display:gsub(" ", "-") then return u end
            end
        end

        local function storm(seed)
            random.seed(seed)
            boot()
            local count = { low = 0, missing = 0, guarded = 0, offs = 0 }
            local topUp = 5
            -- The model of what you dismissed: [id .. "\1" .. spell] = true,
            -- the pair buff mode last turned on for, when you turned it off,
            -- until that member wears a fresh copy or leaves the group. It
            -- forgets the pair (lastOn) on anything that could change what
            -- the addon last saw of it before you turn buff mode off: a
            -- fresh copy, the Top up time, or a secret about the member.
            local dismissed, lastOn = {}, nil
            local function recast(id, spell)
                local key = id .. "\1" .. spell
                dismissed[key] = nil
                if lastOn == key then lastOn = nil end
            end
            local function inGroup(id)
                for i = 1, 4 do
                    local u = wow.state.units["party" .. i]
                    if u and u.id == id then return true end
                end
                return false
            end
            local function off(action)
                local wasOn = ns.BuffMode.IsOn()
                action()
                if wasOn and not ns.BuffMode.IsOn() then
                    count.offs = count.offs + 1
                    if lastOn then dismissed[lastOn] = true end
                end
            end
            -- Time passes on one buff: low, nearly gone, or gone.
            local function timePasses()
                local token = "party" .. random.random(1, 4)
                local u = wow.state.units[token]
                if not u or not u.auras or #u.auras == 0 then return end
                local i = random.random(#u.auras)
                local expires = wow.now + ({ -1, 5, 30, 59, 61, 200, 299, 400 })[random.random(8)]
                -- A later end is a fresh copy (a recast).
                if expires > u.auraExpires[i] then recast(u.id, u.auras[i]) end
                u.auraExpires[i] = expires
            end
            local actions = {
                function()
                    local names = {}
                    for _, n in ipairs(NAMES) do if random.random() < 0.8 then names[#names + 1] = n end end
                    wow.setGroup(#names > 0 and "party" or nil, names)
                    for i = 1, 4 do
                        local u = wow.state.units["party" .. i]
                        if u then
                            u.class, u.role = "WARRIOR", u.id == "Tom-Tank" and "TANK" or "DAMAGER"
                            -- Mostly covered, so a buff running low stands out.
                            if random.random() < 0.8 then
                                wow.wearBuff("party" .. i, MOTW, { source = "player", duration = HALF_HOUR })
                                wow.wearBuff("party" .. i, THORNS, { source = "player", duration = TEN_MINUTES })
                                recast(u.id, MOTW)
                                recast(u.id, THORNS)
                            end
                        end
                    end
                    for key in pairs(dismissed) do
                        if #names == 0 or not inGroup(key:match("^(.-)\1")) then dismissed[key] = nil end
                    end
                    if lastOn and (#names == 0 or not inGroup(lastOn:match("^(.-)\1"))) then lastOn = nil end
                    wow.fire("GROUP_ROSTER_UPDATE")
                end,
                -- A fresh copy: yours, a member's, or an outsider's.
                function()
                    local token = "party" .. random.random(1, 4)
                    local u = wow.state.units[token]
                    if not u then return end
                    local spell = random.random() < 0.5 and THORNS or MOTW
                    local full = spell == THORNS and TEN_MINUTES or HALF_HOUR
                    wow.wearBuff(token, spell, { source = ({ "player", "party2", false })[random.random(3)],
                        duration = full })
                    recast(u.id, spell)
                end,
                -- Three times over, so a buff running low is common.
                timePasses, timePasses, timePasses,
                function()
                    local u = wow.state.units["party" .. random.random(1, 4)]
                    if u then u.auras, u.auraExpires, u.auraDurations, u.auraSources = {}, {}, {}, {} end
                end,
                function()
                    local u = wow.state.units["party" .. random.random(1, 4)]
                    if not u then return end
                    local field = ({ "offline", "dead", "outOfRange", "rangeUnknown", "hidden" })[random.random(5)]
                    u[field] = not u[field] or nil
                end,
                function()
                    local u = wow.state.units["party" .. random.random(1, 4)]
                    if not u then return end
                    local field = ({ "auras", "auraTimes", "name", "range" })[random.random(4)]
                    if lastOn and lastOn:match("^(.-)\1") == u.id then lastOn = nil end
                    u.secrets = u.secrets or {}
                    u.secrets[field] = not u.secrets[field] or nil
                    if next(u.secrets) == nil then u.secrets = nil end
                end,
                function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                function() wow.advance(random.random() * 12) end,
                function() wow.advance(random.random() * 12) end,
                function() off(function() slash("buffmode off") end) end,
                function() off(function() _G.FriendlyForever_ToggleBuffMode() end) end,
                function()
                    topUp = ({ 0, 1, 5, 15 })[random.random(4)]
                    ns.db.buffBack.topUpMinutes = topUp
                    lastOn = nil
                end,
                function() ns.db.buffBack.neverOffer = random.random() < 0.3 and { thorns = true } or {} end,
            }
            for step = 1, 700 do
                local where = ("seed %d, step %d"):format(seed, step)
                local wasOn = ns.BuffMode.IsOn()
                local printed = #wow.printed
                actions[random.random(#actions)]()
                local why
                for i = printed + 1, #wow.printed do
                    why = why or wow.printed[i]:match("buff mode on %((.-)%)")
                end
                if not wasOn and ns.BuffMode.IsAuto() then
                    assert.is_false(wow.state.inCombat == true, where .. ": turned on in a fight")
                    assert.is_not_nil(why, where)
                    local rest = why:gsub("^the fight ended and ", "")
                    local who, spellName = rest:match("^(.-)'s (.-) is running low$")
                    if who then
                        count.low = count.low + 1
                    else
                        who, spellName = rest:match("^(.-) is missing your (.-)$")
                        count.missing = count.missing + 1
                    end
                    assert.is_not_nil(who, where .. ": " .. why)
                    local u = unitNamed(who)
                    assert.is_not_nil(u, where .. ": " .. who .. " isn't in the group")
                    local spell
                    for id, name in pairs(SPELLS) do if name == spellName then spell = id end end
                    assert.is_not_nil(spell, where .. ": " .. why)
                    assert.is_true(lowOrMissing(u, spell, topUp), where .. ": " .. why .. ", but it isn't")
                    for _, field in ipairs({ "offline", "dead", "outOfRange", "rangeUnknown", "hidden" }) do
                        assert.is_nil(u[field], where .. ": turned on for a member " .. field)
                    end
                    -- Hidden buff times only hide how long a copy has left, and
                    -- hidden buffs show a member wearing none plainly
                    -- (lowOrMissing checks both).
                    for field in pairs(u.secrets or {}) do
                        assert.is_true(field == "auraTimes" or field == "auras",
                            where .. ": turned on for a member whose " .. field .. " can't be read")
                    end
                    if spell == THORNS then
                        assert.are.equal("TANK", u.role, where .. ": Thorns is for the tank")
                        assert.is_nil(ns.db.buffBack.neverOffer.thorns, where .. ": Thorns is Never offer")
                    end
                    local key = u.id .. "\1" .. spell
                    assert.is_nil(dismissed[key], where .. ": turned on for " .. why .. ", dismissed before a recast")
                    lastOn = key
                end
                assert.are.same({}, wow.casts, where .. ": something cast without a press")
                -- Steps where a dismissed pair, still low or gone, was kept from
                -- turning buff mode on: the check above had something to bite on.
                if not ns.BuffMode.IsOn() and not wow.state.inCombat then
                    for key in pairs(dismissed) do
                        local id, spell = key:match("^(.-)\1(.*)$")
                        for i = 1, 4 do
                            local u = wow.state.units["party" .. i]
                            if u and u.id == id and lowOrMissing(u, tonumber(spell), topUp) then
                                count.guarded = count.guarded + 1
                            end
                        end
                    end
                end
            end
            assert.are.same({}, wow.errors, "seed " .. seed)
            return count
        end

        it("never turns on in a fight, for a member who isn't plainly low or missing, unreadable or out of reach, "
            .. "or for a pair you dismissed before a recast; never casts", function()
            local total = { low = 0, missing = 0, guarded = 0, offs = 0 }
            for _, seed in ipairs({ 397, 11, 2026, 4242, 90210 }) do
                for key, n in pairs(storm(seed)) do total[key] = total[key] + n end
            end
            assert.is_true(total.low > 10, "turned on for a buff running low: " .. total.low)
            assert.is_true(total.missing > 10, "turned on for a buff gone: " .. total.missing)
            assert.is_true(total.offs > 20, "turned off yourself: " .. total.offs)
            assert.is_true(total.guarded > 100, "a dismissed pair still low or gone: " .. total.guarded)
        end)
    end)
end)
