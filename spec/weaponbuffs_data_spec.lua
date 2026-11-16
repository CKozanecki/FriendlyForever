-- Spec: #45
-- Every ID the weapon buffs use is Forever's own: WeaponBuffs.lua's items,
-- the spells they cast and a shaman's imbue ranks are checked against
-- scripts/data/forever-weapon-buffs.lua, which scripts/gen_weapon_data.py
-- generated from Forever's data (docs/forever-facts.md, "Weapon buffs"). The
-- simulated client's own weapon items are checked against it too.
local wow = require("spec.support.wow")

local DATA = assert(loadfile(wow.ROOT .. "scripts/data/forever-weapon-buffs.lua"))()

describe("Weapon buffs' IDs", function()
    local ns
    before_each(function() ns = wow.boot() end)

    it("come from Forever's data: every item casts its listed spell, and every spell enchants", function()
        for key, kind in pairs(ns.WeaponBuffs.KINDS) do
            for _, pair in ipairs(kind.items or {}) do
                local item, spell = pair[1], pair[2]
                assert.are.equal(spell, DATA.items[item], key .. ": item " .. item)
                assert.is_table(DATA.spells[spell], key .. ": spell " .. spell)
            end
            for _, rank in ipairs(kind.ranks or {}) do
                local spell = DATA.spells[rank]
                assert.is_table(spell, key .. ": rank " .. rank)
                assert.are.equal(kind.label, spell.name, key .. ": rank " .. rank)
            end
        end
    end)

    it("leave out nothing in the data, and list nothing twice", function()
        local listedItems, listedSpells = {}, {}
        for _, kind in pairs(ns.WeaponBuffs.KINDS) do
            for _, pair in ipairs(kind.items or {}) do
                assert.is_nil(listedItems[pair[1]], "item " .. pair[1])
                listedItems[pair[1]] = true
                listedSpells[pair[2]] = true
            end
            for _, rank in ipairs(kind.ranks or {}) do
                assert.is_nil(listedSpells[rank], "spell " .. rank)
                listedSpells[rank] = true
            end
        end
        for item in pairs(DATA.items) do assert.is_true(listedItems[item], "item " .. item) end
        for spell in pairs(DATA.spells) do assert.is_true(listedSpells[spell], "spell " .. spell) end
    end)

    it("name each kind's spells as the kind: poisons, oils, stones", function()
        local patterns = {
            sharpening = "^Sharpen ", weightstone = "^Enhance Blunt Weapon", wizardOil = "Wizard Oil$",
            manaOil = "Mana Oil$", instantPoison = "^Instant Poison", deadlyPoison = "^Deadly Poison",
            cripplingPoison = "^Crippling Poison", mindNumbingPoison = "^Mind%-numbing Poison",
            woundPoison = "^Wound Poison",
        }
        for key, kind in pairs(ns.WeaponBuffs.KINDS) do
            for _, pair in ipairs(kind.items or {}) do
                assert.is_truthy(DATA.spells[pair[2]].name:find(patterns[key]), key .. ": " .. DATA.spells[pair[2]].name)
            end
        end
    end)

    it("are the kinds the settings may hold, and no others", function()
        local settings = {}
        for _, key in ipairs(ns.Config.WEAPON_KINDS) do
            settings[key] = true
            if key ~= "none" then assert.is_table(ns.WeaponBuffs.KINDS[key], key) end
        end
        for key in pairs(ns.WeaponBuffs.KINDS) do assert.is_true(settings[key], key) end
    end)

    it("match the simulated client's items, spells and enchants", function()
        for item, info in pairs(wow.WEAPON_ITEMS) do
            assert.are.equal(info.spell, DATA.items[item], "item " .. item)
            assert.are.equal(info.spellName, DATA.spells[info.spell].name, "item " .. item)
            assert.are.equal(info.enchant, DATA.spells[info.spell].enchant, "item " .. item)
            assert.are.equal(wow.WEAPON_BUFF_SECONDS, DATA.spells[info.spell].seconds, "item " .. item)
        end
        for spell, enchant in pairs(wow.IMBUES) do
            assert.are.equal(enchant, DATA.spells[spell].enchant, "imbue " .. spell)
            assert.are.equal(wow.SPELL_NAMES[spell], DATA.spells[spell].name, "imbue " .. spell)
        end
    end)

    it("include the owner's Rough Weightstone: enchant 19 in game (#45, 15 Nov)", function()
        assert.are.equal(3112, DATA.items[3239])
        assert.are.equal(19, DATA.spells[3112].enchant)
    end)
end)
