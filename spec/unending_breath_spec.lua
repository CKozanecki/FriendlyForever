-- Spec: #135
-- The warlock's Unending Breath through buff thanks, buff back and buff mode,
-- and its data: Water Breathing (131) is the shaman's, a blocker, not a
-- group version.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local BREATH, WATER_BREATHING = 5697, 131
local INTELLECT = 10157

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Unending Breath", function()
    local ns, button

    -- A warlock who knows Unending Breath (opts.known replaces that).
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = "WARLOCK"
            state.knownSpells = opts.known or { [BREATH] = true }
        end })
        ns.db.buff.messages = { "Thank you for the {buff}, {name}!" }
        button = ns.BuffButton.Frame()
        if opts.buffMode then slash("buffmode on") end
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    -- What the armed button casts, and on whom.
    local function armed()
        local text = macro()
        if not text then return nil end
        return text:match("/targetexact ([^\n]+)") .. ": " .. text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    -- Bob Stone, a stranger, as a unit the game names (a nameplate).
    local function stranger(spec)
        spec = spec or {}
        spec.name, spec.surname = "Bob", "Stone"
        spec.class = spec.class or "WARRIOR"
        spec.id = "Bob-Stone"
        wow.addUnit("nameplate1", spec)
    end

    local function party(names)
        wow.setGroup("party", names)
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    -- The unit token showing this player id, if any.
    local function tokenOf(id)
        for token, u in pairs(wow.state.units) do
            if u.id == id and token ~= "target" then return token end
        end
    end

    -- Scroll once, and let the buff show on whoever it reached.
    local function scroll()
        local before = #wow.casts
        wow.pressKey("MOUSEWHEELUP")
        local cast = wow.casts[before + 1]
        if cast and not cast.failed then
            local u = wow.state.units[tokenOf(cast.target)]
            if u then
                u.auras = u.auras or {}
                u.auras[#u.auras + 1] = cast.id
                u.auraSources = u.auraSources or {}
                u.auraSources[#u.auras] = "player"
            end
        end
        return cast
    end

    before_each(function() boot() end)

    describe("its data", function()
        it("is the warlock's one buff: rank 5697, with the shaman's Water Breathing (131) as a blocker", function()
            local list = ns.BuffData.CLASSES.WARLOCK
            assert.are.equal(1, #list)
            local breath = list[1]
            assert.are.same({ key = "breath", ranks = { BREATH }, blockers = { WATER_BREATHING } }, breath)
            assert.are.equal(breath, ns.BuffData.ByKey("breath"))
            assert.is_true(ns.BuffData.KEYS.breath)
            assert.are.equal("Unending Breath", ns.BuffData.SpellName(breath))
        end)

        it("counts Water Breathing as having it, but never as one of our casts", function()
            assert.are.equal("breath", ns.BuffData.ForCast(BREATH).key)
            assert.are.equal("breath", ns.BuffData.ForAura(BREATH).key)
            assert.are.equal("breath", ns.BuffData.ForAura(WATER_BREATHING).key)
            assert.is_nil(ns.BuffData.ForCast(WATER_BREATHING), "the shaman's spell is no cast of ours")
            assert.is_nil(ns.BuffData.CLASSES.WARLOCK[1].group, "it has no group version to cast (#41)")
        end)

        it("is useful to every class, mana or not", function()
            local breath = ns.BuffData.ByKey("breath")
            for _, class in ipairs(ns.BuffRules.CLASSES) do
                assert.is_true(ns.BuffData.Useful(breath, class), class)
            end
        end)
    end)

    describe("buff thanks (white)", function()
        it("thanks a stranger warlock for it, and the ledger records it as Unending Breath", function()
            boot({ known = {} })
            stranger({ class = "WARLOCK" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Unending Breath", spellId = BREATH })
            wow.advance(ns.db.buff.delay + 0.01)
            wow.keyDown()
            assert.are.same({ "Thank you for the Unending Breath, Bob!" }, wow.sentTo("SAY"))
            local entry = ns.db.ledger.entries[1]
            assert.are.equal("Bob-Stone", entry.who)
            assert.are.same({ "Unending Breath" }, entry.buffs)
            assert.are.equal("thanked", entry.result)
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("buff back (white)", function()
        it("offers Unending Breath back to a stranger who buffed you, with its /cast macro", function()
            stranger()
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            local offer = ns.Offers.Current()
            assert.are.equal("Bob-Stone", offer.name)
            assert.are.equal("Unending Breath", offer.spell)
            assert.are.equal("/cleartarget\n/targetexact Bob Stone\n/cast [help,nodead] Unending Breath\n/cleartarget",
                macro())
            wow.press(button)
            assert.are.equal(1, #wow.casts)
            assert.are.same({ BREATH, "Bob-Stone" }, { wow.casts[1].id, wow.casts[1].target })
        end)

        it("offers it to a class without mana (a warrior): it isn't a mana buff", function()
            stranger({ class = "WARRIOR" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            assert.are.equal("Unending Breath", ns.Offers.Current().spell)
            stranger({ class = "ROGUE" })
            assert.are.equal("Unending Breath", ns.Offers.Current().spell)
        end)

        it("returns a warlock's own Unending Breath with one", function()
            stranger({ class = "WARLOCK" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Unending Breath", spellId = BREATH })
            assert.are.equal("Bob Stone: Unending Breath", armed())
        end)
    end)

    describe("buff mode (white)", function()
        before_each(function() boot({ buffMode = true }) end)

        it("gives each party member missing it one Unending Breath per press, in order", function()
            party({ "Ann-Vale", "Cid-Rock", "Dot-Fern" })
            assert.are.equal("Ann Vale: Unending Breath", armed())
            assert.are.equal("missing your Unending Breath", button.subtitle:GetText())
            local given = {}
            for _ = 1, 4 do
                local cast = scroll()
                if cast then given[#given + 1] = cast.target .. " " .. cast.spell end
            end
            assert.are.same({ "Ann-Vale Unending Breath", "Cid-Rock Unending Breath", "Dot-Fern Unending Breath" },
                given)
            assert.is_nil(macro())
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
        end)

        it("follows your rules for who gets it (#68)", function()
            party({ "Ann-Vale", "Cid-Rock" })
            wow.state.units.party1.class = "WARRIOR"
            wow.state.units.party2.class = "MAGE"
            ns.BuffRules.SetRule("breath", "classes")
            ns.BuffRules.SetClass("breath", "MAGE", true)
            ns.BuffButton.Refresh()
            assert.are.equal("Cid Rock: Unending Breath", armed())
            ns.BuffRules.AddName("breath", "never", "Cid-Rock")
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
        end)
    end)

    describe("when it isn't offered (black)", function()
        it("not to someone already wearing it, any warlock's or a shaman's Water Breathing", function()
            boot({ buffMode = true })
            wow.setGroup("party", { "Ann-Vale", "Cid-Rock", "Dot-Fern" })
            wow.state.units.party1.auras = { BREATH }
            wow.state.units.party1.auraSources = { "party3" }
            wow.state.units.party2.auras = { WATER_BREATHING }
            ns.BuffButton.Refresh()
            assert.are.equal("Dot Fern: Unending Breath", armed())
            wow.state.units.party3.auras = { WATER_BREATHING }
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())

            -- A stranger who buffed you, wearing it.
            boot()
            stranger({ auras = { WATER_BREATHING } })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.are.equal("Bob Stone: " .. "they already have your buffs", why)
            assert.are.same({}, wow.errors)
        end)

        it("never by a warlock who hasn't learned it (too low)", function()
            boot({ known = {}, buffMode = true })
            assert.are.same({}, ns.BuffData.Mine())
            party({ "Ann-Vale" })
            assert.is_nil(macro())
            slash("buffmode off")
            stranger()
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.are.equal("Bob Stone: " .. "you know no buffs to give", why)
            wow.press(button)
            assert.are.equal(0, #wow.casts)
            assert.are.same({}, wow.errors)
        end)

        it("not to a member whose buffs are secret or can't be read, and no Lua error", function()
            boot({ buffMode = true })
            wow.setGroup("party", { "Ann-Vale" })
            wow.state.units.party1.auras = { INTELLECT }
            wow.state.units.party1.secrets = { auras = true }
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.are.equal("Ann Vale: can't see their buffs", button.subtitle:GetText())

            wow.state.units.party1.secrets = nil
            wow.state.aurasRestricted = true -- the game refuses to say
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            wow.state.aurasRestricted = false
            ns.BuffButton.Refresh()
            assert.are.equal("Ann Vale: Unending Breath", armed(), "readable again: offered")
            assert.are.same({}, wow.errors)
        end)

        it("never when you've marked it never offer, in buff back or buff mode", function()
            boot({ buffMode = true })
            ns.db.buffBack.neverOffer = { breath = true }
            party({ "Ann-Vale" })
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            stranger()
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.are.equal("Bob Stone: " .. "you've marked all your buffs never offer", why)
            wow.press(button)
            assert.are.equal(0, #wow.casts)
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("chaos (red tests)", function()
        it("a warlock buffing a party whose members gain and lose it never offers it to someone wearing it", function()
            local everyone = { "Ann-Vale", "Cid-Rock", "Dot-Fern", "Eve-Moss" }
            local casts, offers = 0, 0
            for _, seed in ipairs({ 3, 41, 135, 909, 2026 }) do
                random.seed(seed)
                boot({ buffMode = true })
                party(everyone)
                local function someone()
                    return wow.state.units["party" .. random.random(#everyone)]
                end
                local actions = {
                    -- Someone else's Unending Breath, or a shaman's Water Breathing.
                    function()
                        local u = someone()
                        u.auras = u.auras or {}
                        u.auras[#u.auras + 1] = random.random() < 0.5 and BREATH or WATER_BREATHING
                    end,
                    -- It wears off (or is cancelled).
                    function()
                        local u = someone()
                        u.auras, u.auraSources = nil, nil
                    end,
                    function()
                        local u = someone()
                        u.secrets = random.random() < 0.3 and { auras = true } or nil
                    end,
                    function() wow.state.aurasRestricted = random.random() < 0.2 end,
                    function() scroll() end,
                    function() wow.press(button) end,
                    function() ns.BuffButton.Refresh() end,
                    function() wow.advance(random.random() * 8) end,
                }
                -- Who wears it, or can't be read, as the game stands now.
                local function wearingNow()
                    local wearing = {}
                    for i = 1, #everyone do
                        local u = wow.state.units["party" .. i]
                        -- The client hides only auras there are: with none,
                        -- they read as wearing nothing.
                        local secret = u.secrets and u.secrets.auras and u.auras and #u.auras > 0
                        local has = wow.state.aurasRestricted or secret or false
                        for _, id in ipairs(u.auras or {}) do
                            if id == BREATH or id == WATER_BREATHING then has = true end
                        end
                        wearing[u.id] = has
                    end
                    return wearing
                end
                -- The button re-checks every few seconds; a buff that lands
                -- in between leaves the last offer armed until then. So the
                -- invariants hold at each re-check, done after every step.
                -- What the re-checks saw, from the client's own state: the
                -- storm must reach every way of wearing it, or it proves
                -- nothing about them.
                local reached = { breath = 0, waterBreathing = 0, secret = 0, restricted = 0 }
                local function count()
                    if wow.state.aurasRestricted then reached.restricted = reached.restricted + 1 end
                    for i = 1, #everyone do
                        local u = wow.state.units["party" .. i]
                        local auras = u.auras or {}
                        if u.secrets and u.secrets.auras and #auras > 0 then reached.secret = reached.secret + 1 end
                        for index, id in ipairs(auras) do
                            local fromYou = u.auraSources and u.auraSources[index] == "player"
                            if id == BREATH and not fromYou then reached.breath = reached.breath + 1 end
                            if id == WATER_BREATHING then reached.waterBreathing = reached.waterBreathing + 1 end
                        end
                    end
                end
                ns.BuffButton.Refresh()
                local wearing = wearingNow()
                for step = 1, 500 do
                    local before = #wow.casts
                    actions[random.random(#actions)]()
                    for i = before + 1, #wow.casts do
                        local cast = wow.casts[i]
                        local where = ("seed %d, step %d: %s on %s"):format(seed, step, cast.spell, cast.target)
                        assert.are.equal(BREATH, cast.id, where)
                        assert.is_false(wearing[cast.target], where .. ", already wearing it or unreadable")
                        casts = casts + 1
                    end
                    ns.BuffButton.Refresh()
                    wearing = wearingNow()
                    count()
                    local text = macro()
                    if text then
                        local who = text:match("/targetexact ([^\n]+)"):gsub(" ", "-")
                        assert.is_false(wearing[who], ("seed %d, step %d: offered to %s"):format(seed, step, who))
                        offers = offers + 1
                    end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
                for what, n in pairs(reached) do
                    assert.is_true(n > 0, ("seed %d never reached %s"):format(seed, what))
                end
            end
            assert.is_true(casts > 30, "casts: " .. casts)
            assert.is_true(offers > 100, "offers: " .. offers)
        end)
    end)
end)
