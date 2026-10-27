-- Spec: #31
-- Buff order and the never-offer list: which of your buffs the button offers
-- first, and which it never offers.
local wow = require("spec.support.wow")

local MOTW, MOTW_1, THORNS_1 = 9885, 1126, 467
local INTELLECT = 10157

describe("Buff order and never offer", function()
    local ns

    -- A druid who knows Mark of the Wild and Thorns.
    local function boot(db)
        ns = wow.boot({ db = db, before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
        end })
        ns.BuffButton.Frame()
    end

    -- Bob Stone, a warrior, buffs you.
    local function owed()
        wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
        wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
    end

    local function offered()
        local offer, why = ns.Offers.Current()
        return offer and offer.spell, why
    end

    before_each(function() boot() end)

    describe("choosing the buff", function()
        it("offers your class's own order by default", function()
            owed()
            assert.are.equal("Mark of the Wild", offered())
            assert.are.same({}, ns.db.buffBack.buffOrder)
        end)

        it("offers the first buff in your order", function()
            ns.db.buffBack.buffOrder = { "thorns", "motw" }
            owed()
            assert.are.equal("Thorns", offered())
        end)

        it("puts buffs your order doesn't name after the ones it does, in the class's order", function()
            local buffs = ns.BuffData.CLASSES.PALADIN
            local keys = {}
            for i, buff in ipairs(ns.BuffData.InOrder(buffs, { "light", "might" })) do keys[i] = buff.key end
            assert.are.same({ "light", "might", "kings", "wisdom", "salvation" }, keys)
        end)

        it("goes by a key's first place when an order damaged mid-session names it twice", function()
            ns.db.buffBack.buffOrder = { "thorns", "motw", "thorns" }
            owed()
            assert.are.equal("Thorns", offered())
        end)

        it("never offers a buff marked never offer", function()
            ns.db.buffBack.neverOffer = { motw = true }
            owed()
            assert.are.equal("Thorns", offered())
        end)

        it("says so when every buff you know is marked never offer", function()
            ns.db.buffBack.neverOffer = { motw = true, thorns = true }
            owed()
            local spell, why = offered()
            assert.is_nil(spell)
            assert.are.equal("Bob Stone: you've marked all your buffs never offer", why)
        end)

        it("moves on to the next buff in your order when they already wear the first", function()
            ns.db.buffBack.buffOrder = { "thorns", "motw" }
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone",
                auras = { THORNS_1 } })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            assert.are.equal("Mark of the Wild", offered())
        end)

        it("arms the button with the buff your order picks", function()
            ns.db.buffBack.buffOrder = { "thorns" }
            owed()
            local button = ns.BuffButton.Frame()
            local macro = button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
            assert.is_truthy(macro:find("/cast [help,nodead] Thorns", 1, true))
        end)
    end)

    describe("the Buff Back tab", function()
        local function rows()
            local out = {}
            for _, row in ipairs(ns.Options.widgets.buffRows) do
                if row.name:IsShown() then out[#out + 1] = row.name:GetText() end
            end
            return out
        end

        it("lists your class's buffs in your order, with Up and Down at the ends disabled", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            assert.is_true(w.buffOrderHeader:IsShown())
            assert.are.same({ "1. Mark of the Wild", "2. Thorns" }, rows())
            assert.is_false(w.buffRows[1].up:IsEnabled())
            assert.is_true(w.buffRows[1].down:IsEnabled())
            assert.is_true(w.buffRows[2].up:IsEnabled())
            assert.is_false(w.buffRows[2].down:IsEnabled())
            assert.is_false(w.buffRows[3].name:IsShown())
        end)

        it("moves a buff and marks one never offer, and the button follows", function()
            local w = ns.Options.widgets
            local button = ns.BuffButton.Frame()
            -- What the armed button casts, read from its macro.
            local function armed()
                local macro = button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
                return macro and macro:match("/cast %[help,nodead%] ([^\n]+)")
            end
            owed()
            assert.are.equal("Mark of the Wild", armed())
            wow.run(w.tabs.buffBack, "OnClick")
            wow.run(w.buffRows[1].down, "OnClick")
            assert.are.same({ "thorns", "motw" }, ns.db.buffBack.buffOrder)
            assert.are.same({ "1. Thorns", "2. Mark of the Wild" }, rows())
            assert.are.equal("Thorns", offered())
            assert.are.equal("Thorns", armed())
            w.buffRows[1].never:SetChecked(true)
            wow.run(w.buffRows[1].never, "OnClick")
            assert.are.same({ thorns = true }, ns.db.buffBack.neverOffer)
            assert.are.equal("Mark of the Wild", offered())
            assert.are.equal("Mark of the Wild", armed())
            w.buffRows[1].never:SetChecked(false)
            wow.run(w.buffRows[1].never, "OnClick")
            assert.are.same({}, ns.db.buffBack.neverOffer)
            assert.are.equal("Thorns", armed())
            wow.run(w.buffRows[2].up, "OnClick")
            assert.are.same({ "motw", "thorns" }, ns.db.buffBack.buffOrder)
            assert.are.same({ "1. Mark of the Wild", "2. Thorns" }, rows())
            assert.are.equal("Mark of the Wild", offered())
            assert.are.equal("Mark of the Wild", armed())
            assert.are.same({}, wow.errors)
        end)

        it("shows saved never-offer marks, and the mark moves with its buff", function()
            boot({ buffBack = { neverOffer = { thorns = true } } })
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            assert.is_false(w.buffRows[1].never:GetChecked())
            assert.is_true(w.buffRows[2].never:GetChecked())
            wow.run(w.buffRows[2].up, "OnClick")
            assert.are.same({ "1. Thorns", "2. Mark of the Wild" }, rows())
            assert.is_true(w.buffRows[1].never:GetChecked())
            assert.is_false(w.buffRows[2].never:GetChecked())
        end)

        it("keeps other classes' order when you move a buff (one profile, many characters)", function()
            ns.db.buffBack.buffOrder = { "fortitude", "thorns", "spirit" }
            ns.Options.MoveBuff("motw", 1)
            assert.are.same({ "thorns", "motw", "fortitude", "spirit" }, ns.db.buffBack.buffOrder)
        end)

        it("shows buffs you don't know yet, marked so", function()
            boot()
            wow.state.knownSpells = { [MOTW_1] = true }
            ns.BuffData.SpellsChanged()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            assert.are.same({ "1. Mark of the Wild", "2. Thorns |cff999999(not known yet)|r" }, rows())
        end)

        it("says so for a class without buffs", function()
            wow.state.class = "ROGUE"
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            assert.are.same({}, rows())
            assert.are.equal("Your class has no buffs to offer.", w.buffOrderHeader:GetText())
        end)

        it("other tabs open even when Buff Back's settings are lost mid-session", function()
            ns.db.buffBack = nil
            wow.run(ns.Options.widgets.tabs.buff, "OnClick")
            assert.are.same({}, wow.errors)
        end)

        it("shows the list only on the Buff Back tab, with the messages below it", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            assert.are.equal(w.buffRows[2].up, select(2, w.msgHeader:GetPoint()))
            wow.run(w.tabs.buff, "OnClick")
            assert.is_false(w.buffOrderHeader:IsShown())
            assert.are.same({}, rows())
            assert.are.equal(w.fallback, select(2, w.msgHeader:GetPoint()))
        end)
    end)

    describe("saved settings", function()
        it("repairs a damaged order: unknown keys, duplicates and wrong types are dropped", function()
            boot({ buffBack = { buffOrder = { "thorns", "thorns", 7, "bogus", {}, "motw" } } })
            assert.are.same({ "thorns", "motw" }, ns.db.buffBack.buffOrder)
        end)

        it("goes back to the class's own order when the saved order isn't a list", function()
            for _, damaged in ipairs({ "thorns", 42, true }) do
                boot({ buffBack = { buffOrder = damaged } })
                assert.are.same({}, ns.db.buffBack.buffOrder)
                owed()
                assert.are.equal("Mark of the Wild", offered())
            end
        end)

        it("repairs damaged never-offer marks", function()
            boot({ buffBack = { neverOffer = { motw = "yes", bogus = true, [1] = true, thorns = true } } })
            assert.are.same({ thorns = true }, ns.db.buffBack.neverOffer)
            boot({ buffBack = { neverOffer = "motw" } })
            assert.are.same({}, ns.db.buffBack.neverOffer)
        end)

        it("keeps working when damaged mid-session, and a reload heals it", function()
            owed()
            ns.db.buffBack.buffOrder = 42
            ns.db.buffBack.neverOffer = "all"
            assert.are.equal("Mark of the Wild", offered())
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            wow.run(w.buffRows[1].down, "OnClick")
            w.buffRows[1].never:SetChecked(true)
            wow.run(w.buffRows[1].never, "OnClick")
            assert.are.same({}, wow.errors)
            ns.db.buffBack.buffOrder = { 1, {}, "thorns" }
            boot(_G.FriendlyForeverDB)
            assert.are.equal("table", type(ns.db.buffBack.neverOffer))
            for _, key in ipairs(ns.db.buffBack.buffOrder) do assert.is_true(ns.BuffData.KEYS[key]) end
        end)

        it("travels with profiles and export, but not between unrelated settings", function()
            ns.db.buffBack.buffOrder = { "thorns", "motw" }
            ns.db.buffBack.neverOffer = { motw = true }
            local text = assert(ns.Profiles.Export())
            ns.db.buffBack.buffOrder = {}
            ns.db.buffBack.neverOffer = {}
            assert.is_true(ns.Profiles.Import(text))
            assert.are.same({ "thorns", "motw" }, ns.db.buffBack.buffOrder)
            assert.are.same({ motw = true }, ns.db.buffBack.neverOffer)
        end)
    end)

    describe("chaos (red tests)", function()
        -- The buff the button should offer a warrior who wears nothing: the
        -- first buff you know, in your order, that isn't marked never offer.
        local function expected()
            local order = type(ns.db.buffBack.buffOrder) == "table" and ns.db.buffBack.buffOrder or {}
            local never = type(ns.db.buffBack.neverOffer) == "table" and ns.db.buffBack.neverOffer or {}
            for _, buff in ipairs(ns.BuffData.InOrder(ns.BuffData.Mine(), order)) do
                if never[buff.key] ~= true then return ns.BuffData.SpellName(buff) end
            end
        end

        it("survives random moves, marks, damage, reloads and imports, and always offers the right buff", function()
            local damage = { 42, "x", true, {}, { "bogus", 3, "thorns" }, { motw = 1 }, { thorns = true } }
            for _, seed in ipairs({ 1, 9, 31, 404, 2026 }) do
                math.randomseed(seed)
                boot()
                owed()
                local saved
                local actions = {
                    function() ns.Options.MoveBuff(({ "motw", "thorns" })[math.random(2)], math.random() < 0.5 and -1 or 1) end,
                    function() ns.Options.SetNeverOffer(({ "motw", "thorns" })[math.random(2)], math.random() < 0.4) end,
                    function() ns.db.buffBack.buffOrder = damage[math.random(#damage)] end,
                    function() ns.db.buffBack.neverOffer = damage[math.random(#damage)] end,
                    function() saved = ns.Profiles.Export() end,
                    function() if saved then ns.Profiles.Import(saved) end end,
                    function()
                        boot(_G.FriendlyForeverDB)
                        owed()
                        assert.is_true(type(ns.db.buffBack.buffOrder) == "table", "seed " .. seed)
                        assert.is_true(type(ns.db.buffBack.neverOffer) == "table", "seed " .. seed)
                    end,
                    function() wow.run(ns.Options.widgets.tabs.buffBack, "OnClick") end,
                }
                for step = 1, 300 do
                    actions[math.random(#actions)]()
                    local spell, why = offered()
                    local want = expected()
                    assert.are.equal(want, spell, ("seed %d, step %d: offered %s (%s)"):format(seed, step,
                        tostring(spell), tostring(why)))
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
        end)
    end)
end)
