-- Spec: #206
-- Top-up timing for group versions: a group version you can cast (Arcane
-- Brilliance, the Prayers, Gift of the Wild, the Greater Blessings) counts as
-- the single rank of the same strength. When a member's has less than the
-- top-up time left, they count as missing, so the group version (if enough
-- are low) or the single buff renews it. A time that can't be read never
-- counts as low, and no cast ever replaces a higher rank of yours (#41).
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local ITEM = wow.ITEM
local INTELLECT, INTELLECT_4, BRILLIANCE = 10157, 10156, 23028
local MOTW, MOTW_6, GIFT_2, GIFT_1 = 9885, 9884, 21850, 21849
local MIGHT, GREATER_MIGHT, KINGS = 25291, 25916, 20217
local WATER_BREATHING, UNENDING_BREATH = 131, 5697
local HOUR = 3600

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Top-up timing renews group versions (#206)", function()
    local ns, button

    -- A mage who knows Arcane Intellect and Arcane Brilliance, with Arcane
    -- Powder, in buff mode, with Ann, Bo, Cid and Dot in the party.
    -- opts.class, opts.known (spell IDs), opts.items, opts.members, opts.buffSelf.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ buffSelf = opts.buffSelf, before = function(state)
            state.class = opts.class or "MAGE"
            state.knownSpells = {}
            for _, id in ipairs(opts.known or { INTELLECT, BRILLIANCE }) do state.knownSpells[id] = true end
            state.items = opts.items or { [ITEM.arcanePowder] = 5 }
        end })
        button = ns.BuffButton.Frame()
        slash("buffmode on")
        wow.setGroup("party", opts.members or { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    -- What the armed button casts, and on whom, after a fresh look.
    local function armed()
        ns.BuffButton.Refresh()
        local text = macro()
        if not text then return nil end
        local self = text:match("/cast %[@player,nodead%] ([^\n]+)")
        if self then return "me: " .. self end
        return text:match("/targetexact ([^\n]+)") .. ": " .. text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    -- token wears spell, cast by source (default you; false: nobody the game
    -- names), lasting duration (default an hour), with secondsLeft to go.
    local function wears(token, spell, secondsLeft, duration, source)
        if source == nil then source = "player" end
        wow.wearBuff(token, spell, { duration = duration or HOUR, source = source or nil })
        local u = wow.state.units[token]
        for i, id in ipairs(u.auras) do
            if id == spell then u.auraExpires[i] = wow.now + secondsLeft end
        end
    end

    local PARTY = { "party1", "party2", "party3", "party4" }

    describe("a group version running low is renewed (white)", function()
        it("offers the group version again when enough members' group version is running low", function()
            boot()
            for _, token in ipairs(PARTY) do wears(token, BRILLIANCE, 6 * 60) end
            assert.is_nil(armed(), "6 minutes left of an hour")
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
            wow.advance(2 * 60)
            assert.are.equal("Ann Vale: Arcane Brilliance", armed(), "4 minutes left")
            assert.are.equal("your party (4 missing)", button.title:GetText())
            wow.pressKey("MOUSEWHEELUP")
            local cast = wow.casts[#wow.casts]
            assert.are.equal(BRILLIANCE, cast.id)
            assert.are.equal("Ann-Vale", cast.target)
            -- It landed: everyone wears a full hour again, and nothing more is offered.
            wow.advance(ns.GroupBuffs.JUST_GIVEN_SECONDS)
            assert.is_nil(armed(), "renewed")
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
        end)

        it("renews it with the single buff when too few are low, and says why", function()
            boot()
            wears("party1", BRILLIANCE, HOUR)
            wears("party2", BRILLIANCE, HOUR)
            wears("party3", BRILLIANCE, 60)
            wears("party4", BRILLIANCE, 120)
            assert.are.equal("Cid Rock: Arcane Intellect", armed())
            assert.are.equal("Only 2 missing, Arcane Brilliance needs 3: buffing one at a time",
                button.subtitle:GetText())
        end)

        it("renews it with the single buff when you can't cast the group version", function()
            boot({ known = { INTELLECT } })
            for _, token in ipairs(PARTY) do wears(token, BRILLIANCE, 60) end
            assert.are.equal("Ann Vale: Arcane Intellect", armed(), "not learned")
            boot({ items = {} })
            for _, token in ipairs(PARTY) do wears(token, BRILLIANCE, 60) end
            assert.are.equal("Ann Vale: Arcane Intellect", armed(), "no Arcane Powder")
            assert.are.equal("No Arcane Powder: buffing one at a time", button.subtitle:GetText())
        end)

        it("renews another caster's group version too, as it does a single rank", function()
            boot()
            for _, token in ipairs(PARTY) do wears(token, BRILLIANCE, 60, HOUR, "party1") end
            assert.are.equal("Ann Vale: Arcane Brilliance", armed(), "Ann's own Brilliance")
            boot()
            for _, token in ipairs(PARTY) do wears(token, BRILLIANCE, 60, HOUR, false) end
            assert.are.equal("Ann Vale: Arcane Brilliance", armed(), "by nobody the game names")
        end)

        it("follows the top-up setting: 0 waits until it's gone", function()
            boot()
            for _, token in ipairs(PARTY) do wears(token, BRILLIANCE, 9 * 60) end
            assert.is_nil(armed())
            ns.db.buffBack.topUpMinutes = 10
            assert.are.equal("Ann Vale: Arcane Brilliance", armed(), "9 minutes left of 10")
            ns.db.buffBack.topUpMinutes = 0
            assert.is_nil(armed(), "0: never topped up")
        end)

        it("renews your own group version on you too (#198)", function()
            boot({ buffSelf = true, members = { "Ann-Vale" } })
            wears("party1", BRILLIANCE, HOUR)
            wow.state.playerAuras = { { isHelpful = true, spellId = BRILLIANCE, sourceUnit = "player",
                duration = HOUR, expirationTime = wow.now + 60, auraInstanceID = 1 } }
            assert.are.equal("me: Arcane Intellect", armed())
            wow.state.playerAuras[1].expirationTime = wow.now + HOUR
            assert.is_nil(armed(), "an hour left")
        end)

        it("lets a paladin renew their own Greater Blessing with the single one, never swapping it", function()
            boot({ class = "PALADIN", known = { KINGS, MIGHT, GREATER_MIGHT },
                items = { [ITEM.symbolOfKings] = 5 }, members = { "Ann-Vale" } })
            wow.state.units.party1.class = "WARRIOR"
            ns.db.buffBack.buffOrder = { "kings", "might" }
            wears("party1", GREATER_MIGHT, 20 * 60)
            assert.is_nil(armed(), "20 minutes of your Greater Might: Kings would replace it")
            wow.advance(20 * 60 - 120)
            assert.are.equal("Ann Vale: Blessing of Might", armed(), "your Might, not Kings, at 2 minutes left")
        end)
    end)

    describe("never over a higher rank (white, #41)", function()
        it("leaves a group version stronger than every single rank you know to run out", function()
            -- Gift of the Wild rank 2 is as strong as Mark of the Wild rank 7.
            boot({ class = "DRUID", known = { MOTW_6, GIFT_1 }, items = { [ITEM.wildBerries] = 5 } })
            for _, token in ipairs(PARTY) do wears(token, GIFT_2, 60) end
            assert.is_nil(armed(), "neither Gift rank 1 nor Mark rank 6 over Gift rank 2")
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
            -- Rank 1 of Gift is as strong as rank 6 of Mark: that one is renewed.
            for _, token in ipairs(PARTY) do
                wow.state.units[token].auras = {}
                wears(token, GIFT_1, 60)
            end
            assert.are.equal("Ann Vale: Gift of the Wild", armed())
        end)

        it("never casts a group version over a higher group version of yours", function()
            -- Only rank 1 of Gift is known now, but your rank 2 is on Dot.
            boot({ class = "DRUID", known = { MOTW, MOTW_6, GIFT_1 }, items = { [ITEM.wildBerries] = 5 } })
            assert.are.equal("Ann Vale: Gift of the Wild", armed(), "everyone missing it")
            wears("party4", GIFT_2, 30 * 60)
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
            assert.is_truthy(button.subtitle:GetText():find("Dot Moss wears a higher rank of yours", 1, true))
            -- Running low, it's the single buff that renews it: still no Gift over it.
            wears("party4", GIFT_2, 60)
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
            -- Someone else's is theirs to keep (as for a single rank, #41).
            wears("party4", GIFT_2, 30 * 60, HOUR, "party1")
            assert.are.equal("Ann Vale: Gift of the Wild", armed())
        end)

        it("renews another caster's stronger group version with the single buff, never a weaker group version", function()
            -- You know Mark rank 7 but only Gift rank 1; the party wears
            -- another druid's Gift rank 2, running low.
            boot({ class = "DRUID", known = { MOTW, MOTW_6, GIFT_1 }, items = { [ITEM.wildBerries] = 5 } })
            for _, token in ipairs(PARTY) do wears(token, GIFT_2, 60, HOUR, "party1") end
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
            assert.are.equal("Ann Vale's buff is stronger than your Gift of the Wild: buffing one at a time",
                button.subtitle:GetText())
            -- Another caster's Gift rank 1 running low is renewed by your Gift rank 1.
            for _, token in ipairs(PARTY) do
                wow.state.units[token].auras = {}
                wears(token, GIFT_1, 60, HOUR, "party1")
            end
            assert.are.equal("Ann Vale: Gift of the Wild", armed())
            -- A stronger buff with time left isn't missing: it doesn't stop the group version.
            wow.state.units.party4.auras = {}
            wears("party4", GIFT_2, 30 * 60, HOUR, "party1")
            assert.are.equal("Ann Vale: Gift of the Wild", armed(), "3 low, Dot keeps hers")
            -- The same for a single rank: another caster's Mark rank 7 running low.
            for _, token in ipairs(PARTY) do
                wow.state.units[token].auras = {}
                wears(token, MOTW, 60, 1800, "party1")
            end
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
            assert.are.same({}, wow.errors)
        end)

        it("renews your own group version on you with the single buff when a weaker group version is all you could cast",
            function()
            boot({ class = "DRUID", known = { MOTW, MOTW_6, GIFT_1 }, items = { [ITEM.wildBerries] = 5 },
                buffSelf = true })
            for _, token in ipairs(PARTY) do wears(token, GIFT_1, 60, HOUR, "party1") end
            wow.state.playerAuras = { { isHelpful = true, spellId = GIFT_2, sourceUnit = "party1",
                duration = HOUR, expirationTime = wow.now + 60, auraInstanceID = 1 } }
            assert.are.equal("me: Mark of the Wild", armed())
            assert.are.equal("Your buff is stronger than your Gift of the Wild: buffing one at a time",
                button.subtitle:GetText())
        end)
    end)

    describe("what can't be read (black)", function()
        it("never counts a group version as low when its time is secret, missing or junk", function()
            boot()
            for _, token in ipairs(PARTY) do wears(token, BRILLIANCE, 60) end
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
            for _, token in ipairs(PARTY) do wow.state.units[token].secrets = { auraTimes = true } end
            assert.is_nil(armed(), "secret")
            for _, token in ipairs(PARTY) do wow.state.units[token].secrets = nil end
            for _, case in ipairs({
                { nil, wow.now + 30 }, { HOUR, nil }, { "3600", wow.now + 30 }, { HOUR, "soon" },
                { 0 / 0, wow.now + 30 }, { HOUR, 0 / 0 }, { HOUR, math.huge }, { HOUR, 0 }, { true, wow.now + 30 },
            }) do
                for _, token in ipairs(PARTY) do
                    local u = wow.state.units[token]
                    u.auraDurations[1], u.auraExpires[1] = case[1], case[2]
                end
                assert.is_nil(armed(), tostring(case[1]) .. ", " .. tostring(case[2]))
            end
            assert.are.same({}, wow.errors)
        end)

        it("reads a group version's strength only from IDs it knows, never a secret", function()
            boot({ known = { INTELLECT } })
            local intellect = ns.BuffData.ByKey("intellect")
            local breathing = ns.BuffData.ByKey("waterbreathing")
            assert.are.equal(1, ns.BuffData.RankOf(intellect, BRILLIANCE), "as strong as rank 5")
            assert.are.equal(1, ns.BuffData.RankOf(intellect, INTELLECT))
            assert.are.equal(2, ns.BuffData.RankOf(intellect, INTELLECT_4))
            assert.is_true(ns.BuffData.CanReplace(intellect, BRILLIANCE))
            for _, bad in ipairs({ wow.secret(BRILLIANCE), "23028", 0 / 0, {}, true, MOTW }) do
                assert.is_nil(ns.BuffData.RankOf(intellect, bad), tostring(bad))
                assert.is_false(ns.BuffData.CanReplace(intellect, bad), tostring(bad))
            end
            assert.is_nil(ns.BuffData.RankOf(breathing, UNENDING_BREATH), "a blocker has no rank")
            assert.is_false(ns.BuffData.CanReplace(breathing, UNENDING_BREATH))
            assert.are.equal(1, ns.BuffData.RankOf(breathing, WATER_BREATHING))
            assert.is_nil(ns.BuffData.RankOf({ ranks = {} }, BRILLIANCE), "not a buff of the table")
            assert.are.same({}, wow.errors)
        end)

        it("gives single buffs when a group version's matching rank isn't in the table", function()
            boot()
            local spell = ns.BuffData.ByKey("intellect").groupCast.spells[1]
            local equals = spell.equals
            spell.equals = 99999 -- damaged: no rank of Arcane Intellect
            for _, token in ipairs(PARTY) do wears(token, BRILLIANCE, 60) end
            local ok, text = pcall(armed)
            spell.equals = equals
            assert.is_true(ok, tostring(text))
            assert.are.equal("Ann Vale: Arcane Intellect", text)
            assert.are.equal("can't tell whose buff Ann Vale wears: buffing one at a time", button.subtitle:GetText())
            assert.are.same({}, wow.errors)
        end)

        it("passes over a member whose aura ID is secret, without an error", function()
            boot()
            for _, token in ipairs(PARTY) do wears(token, BRILLIANCE, HOUR) end
            wow.state.units.party1.auras[1] = wow.secret(BRILLIANCE)
            for _, token in ipairs({ "party2", "party3", "party4" }) do wears(token, BRILLIANCE, 60) end
            -- Whether Ann wears a higher rank of yours can't be told, so no
            -- group version: the single buff renews the others.
            assert.are.equal("Bo Fern: Arcane Intellect", armed())
            assert.are.equal("can't tell whose buff Ann Vale wears: buffing one at a time", button.subtitle:GetText())
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("chaos (red tests)", function()
        -- Arcane Intellect rank 5 and 4, Arcane Brilliance (as strong as rank 5).
        local COVERS = { [INTELLECT] = true, [INTELLECT_4] = true, [BRILLIANCE] = true }
        local STRENGTH = { [INTELLECT] = 1, [BRILLIANCE] = 1, [INTELLECT_4] = 2 }

        -- From the client's own state: whether u may be offered Intellect now,
        -- and whether u wears a rank of yours stronger than strength.
        local function mayOffer(u, threshold, known)
            for i, id in ipairs(u.auras or {}) do
                if COVERS[id] and not wow.auraExpired(u, i) then
                    if threshold <= 0 or STRENGTH[id] < known then return false end
                    local duration, expires = u.auraDurations[i], u.auraExpires[i]
                    if u.secrets and u.secrets.auraTimes then return false end
                    if type(duration) ~= "number" or type(expires) ~= "number" then return false end
                    if duration ~= duration or expires ~= expires then return false end
                    if duration <= threshold or expires <= 0 or expires - wow.now >= threshold then return false end
                end
            end
            return true
        end
        local function wearsHigherOfMine(before, sources, strength)
            for i, id in ipairs(before or {}) do
                if STRENGTH[id] and STRENGTH[id] < strength and sources[i] == "player" then return true end
            end
            return false
        end

        it("expiring group versions, junk times and rank changes never give a cast the state forbids", function()
            local renewals, groupRenewals = 0, 0
            for _, seed in ipairs({ 5, 61, 206, 999, 4242 }) do
                random.seed(seed)
                -- known: the strongest Intellect rank you know (1: rank 5, 2: rank 4).
                local known = random.random() < 0.7 and 1 or 2
                boot({ known = known == 1 and { INTELLECT, INTELLECT_4, BRILLIANCE } or { INTELLECT_4 } })
                local function unit() return wow.state.units[PARTY[random.random(#PARTY)]] end
                local actions = {
                    function()
                        local token = PARTY[random.random(#PARTY)]
                        local spell = ({ BRILLIANCE, BRILLIANCE, INTELLECT, INTELLECT_4 })[random.random(4)]
                        wow.wearBuff(token, spell, { duration = ({ HOUR, HOUR, 1800, 240, 0 })[random.random(5)],
                            source = ({ "player", "player", "party1", nil })[random.random(4)] })
                        local u = wow.state.units[token]
                        for i, id in ipairs(u.auras) do
                            if id == spell and u.auraDurations[i] > 0 then
                                u.auraExpires[i] = wow.now + random.random(1, 900)
                            end
                        end
                        ns.BuffButton.Refresh()
                    end,
                    function()
                        local u = unit()
                        if u.auras and #u.auras > 0 then
                            local i, junk = random.random(#u.auras), { "x", {}, 0 / 0, math.huge, -1, true }
                            if random.random() < 0.5 then u.auraDurations[i] = junk[random.random(#junk)]
                            else u.auraExpires[i] = junk[random.random(#junk)] end
                        end
                        ns.BuffButton.Refresh()
                    end,
                    function()
                        local u = unit()
                        u.secrets = random.random() < 0.3 and { auraTimes = true } or nil
                        ns.BuffButton.Refresh()
                    end,
                    -- An earlier Brilliance on the whole party, near its end.
                    function()
                        local left = random.random(1, 900)
                        for _, token in ipairs(PARTY) do
                            wow.wearBuff(token, BRILLIANCE, { duration = HOUR, source = "player" })
                            local u = wow.state.units[token]
                            for i, id in ipairs(u.auras) do
                                if id == BRILLIANCE then u.auraExpires[i] = wow.now + left end
                            end
                        end
                        ns.BuffButton.Refresh()
                    end,
                    function() local u = unit(); u.auras, u.auraSources, u.auraDurations, u.auraExpires = nil, nil, nil, nil end,
                    function()
                        ns.db.buffBack.topUpMinutes = ({ 0, 5, 5, 10, 15, "x" })[random.random(6)]
                        ns.BuffButton.Refresh()
                    end,
                    function() wow.state.items[ITEM.arcanePowder] = random.random(0, 3) end,
                    function() wow.advance(random.random() * 400) end,
                    function() wow.advance(random.random() * 10) end,
                    function() wow.pressKey("MOUSEWHEELUP") end,
                    function() wow.pressKey("MOUSEWHEELUP") end,
                    function() wow.pressKey("MOUSEWHEELUP") end,
                }
                for step = 1, 400 do
                    local before = #wow.casts
                    local minutes = ns.db.buffBack.topUpMinutes
                    if type(minutes) ~= "number" or minutes ~= minutes then minutes = 5 end
                    minutes = math.max(0, math.min(15, math.floor(minutes)))
                    local allowed, wore = {}, {}
                    for _, token in ipairs(PARTY) do
                        local u = wow.state.units[token]
                        allowed[u.id] = mayOffer(u, minutes * 60, known)
                        for i, id in ipairs(u.auras or {}) do
                            if COVERS[id] and not wow.auraExpired(u, i) then wore[u.id] = true end
                        end
                    end
                    actions[random.random(#actions)]()
                    for i = before + 1, #wow.casts do
                        local cast = wow.casts[i]
                        local where = ("seed %d, step %d: %s on %s"):format(seed, step, cast.spell, cast.target)
                        if cast.id == BRILLIANCE then
                            -- It covers everyone in the party: never over a higher rank of yours.
                            for who, auras in pairs(cast.before) do
                                assert.is_false(wearsHigherOfMine(auras, cast.beforeSources[who], 1), where)
                            end
                            assert.is_true(allowed[cast.target], where)
                            if wore[cast.target] then groupRenewals = groupRenewals + 1 end
                        elseif COVERS[cast.id] then
                            assert.is_true(allowed[cast.target], where)
                            if wore[cast.target] then renewals = renewals + 1 end
                            for _, token in ipairs(PARTY) do
                                if wow.state.units[token].id == cast.target then
                                    wow.wearBuff(token, cast.id, { duration = 1800, source = "player" })
                                end
                            end
                        end
                    end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
            assert.is_true(renewals > 10, "single renewals: " .. renewals)
            assert.is_true(groupRenewals > 3, "group renewals: " .. groupRenewals)
        end)
    end)
end)
