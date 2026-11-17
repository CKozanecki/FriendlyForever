-- Spec: #422
-- Buff back keeps one Blessing of yours on each player (#422), as buff mode
-- (GroupBuffs' WearsMyFamily) and passers-by (#417) do: a favour from
-- someone wearing a Blessing of yours is offered no other Blessing, which
-- would replace it. A buff of no family is still offered, and a caster that
-- can't be read offers no Blessing, saying why.
local wow = require("spec.support.wow")

local KINGS, MIGHT_1, WISDOM_1 = 20217, 19740, 19742
local THORNS_1 = 467
local MOTW = 9885

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepCopy(x) end
    return out
end

describe("Buff back keeps one Blessing of yours on each player (#422)", function()
    local ns

    -- A paladin who knows Kings and Might, offering Might first: the order
    -- that gave the bug away. opts.table: a buff table to boot with.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ buffTable = opts.table, before = function(state)
            state.class = "PALADIN"
            state.knownSpells = opts.known or { [KINGS] = true, [MIGHT_1] = true }
        end })
        ns.BuffButton.Frame()
        ns.db.buffBack.buffOrder = opts.order or { "might", "kings" }
    end

    -- Bob, a warrior outside your group, wears the given Blessings ({ id,
    -- source }) and buffs you: a favour is owed.
    local function favourFrom(wearing, class)
        wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = class or "WARRIOR" })
        for _, aura in ipairs(wearing) do wow.wearBuff("nameplate1", aura[1], { source = aura[2] }) end
        wow.gainBuff({ sourceUnit = "nameplate1", name = "Mark of the Wild", spellId = MOTW })
        assert.are.equal(1, ns.Offers.Count())
    end

    it("a favour from someone wearing your Kings is offered no other Blessing (white)", function()
        boot()
        favourFrom({ { KINGS, "player" } })
        local offer, why = ns.Offers.Current()
        assert.is_nil(offer, "Might would replace your Kings")
        assert.are.equal("Bob Stone: they already have your buffs", why)
    end)

    it("the same favour without your Kings is offered Might, your first (white)", function()
        boot()
        favourFrom({})
        assert.are.equal("Blessing of Might", ns.Offers.Current().spell)
    end)

    it("in a raid where you give only Might, a stranger wearing your Kings still isn't offered Might (white)",
        function()
        -- Every Blessing of yours counts for a favour: they aren't in the raid
        -- your choice shares out (WearsMyFamily's every).
        boot()
        wow.setGroup("raid", { "Ann-Vale", "Cid-Rock" })
        local ok, why = ns.BuffRules.SetRaidBlessings({ "might" })
        assert.is_true(ok, why)
        assert.is_false(ns.BuffRules.CoversInRaid(ns.BuffData.ByKey("kings")))
        favourFrom({ { KINGS, "player" } })
        local offer, reason = ns.Offers.Current()
        assert.is_nil(offer, "Might would replace your Kings")
        assert.are.equal("Bob Stone: they already have your buffs", reason)
    end)

    it("another paladin's Kings doesn't count: yours, Might, is offered (white)", function()
        boot()
        favourFrom({ { KINGS, "nameplate2" } })
        assert.are.equal("Blessing of Might", ns.Offers.Current().spell)
    end)

    it("a Blessing of yours they wear that's running low is renewed, not replaced by another (white)", function()
        boot()
        wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
        wow.wearBuff("nameplate1", KINGS, { source = "player", duration = 3600 })
        wow.state.units.nameplate1.auraExpires[1] = wow.now + 30 -- 30 seconds left of the hour
        wow.gainBuff({ sourceUnit = "nameplate1", name = "Mark of the Wild", spellId = MOTW })
        assert.are.equal("Blessing of Kings", ns.Offers.Current().spell)
    end)

    it("a buff of no family is still offered to someone wearing your Kings (white)", function()
        -- A paladin's table with a buff of no family added (Thorns, by its
        -- own IDs): Forever's paladins have none, so the rule is shown on one.
        boot()
        local made = deepCopy(ns.BuffTable)
        local thorns
        for _, buff in ipairs(made.classes.DRUID) do
            if buff.key == "thorns" then thorns = deepCopy(buff) end
        end
        assert.is_nil(thorns.family)
        table.insert(made.classes.PALADIN, thorns)
        boot({ table = made, known = { [KINGS] = true, [MIGHT_1] = true, [THORNS_1] = true },
            order = { "might", "thorns", "kings" } })
        favourFrom({ { KINGS, "player" } })
        assert.are.equal("Thorns", ns.Offers.Current().spell)
    end)

    it("whose Blessing it is can't be read: no Blessing is offered, and the favour says why (black)", function()
        boot()
        favourFrom({ { WISDOM_1, wow.secret("player") } })
        local offer, why = ns.Offers.Current()
        assert.is_nil(offer)
        assert.are.equal("Bob Stone: can't tell whose Blessing they have", why)
    end)

    it("wearing your Might, with another Blessing whose caster can't be read: they have yours, and that's why "
        .. "(black)", function()
        boot()
        favourFrom({ { MIGHT_1, "player" }, { WISDOM_1, wow.secret("player") } })
        local offer, why = ns.Offers.Current()
        assert.is_nil(offer)
        assert.are.equal("Bob Stone: they already have your buffs", why)
    end)

    it("whose Blessing it is can't be read because their buffs can't be: no Blessing either (black)", function()
        boot()
        favourFrom({ { WISDOM_1, "player" } })
        local real = _G.C_UnitAuras.GetAuraDataByIndex
        _G.C_UnitAuras.GetAuraDataByIndex = function(unit, ...)
            if unit == "nameplate1" then error("GetAuraDataByIndex: not now") end
            return real(unit, ...)
        end
        local offer = ns.Offers.Current()
        _G.C_UnitAuras.GetAuraDataByIndex = real
        assert.is_nil(offer)
    end)

    it("a press with your Kings on them casts nothing over it (white)", function()
        boot()
        favourFrom({ { KINGS, "player" } })
        wow.pressKey("MOUSEWHEELUP")
        assert.are.equal(0, #wow.casts)
    end)
end)
