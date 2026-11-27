-- Spec: #544
-- Every ID food buffs use is Forever's own: FoodBuffs.lua's Well Fed spells
-- and foods are checked against scripts/data/forever-food.lua, which
-- scripts/read_food_data.py read from Forever's data (docs/forever-facts.md,
-- "Food buffs"). The simulated client's foods are checked against it too.
local wow = require("spec.support.wow")

local DATA = assert(loadfile(wow.ROOT .. "scripts/data/forever-food.lua"))()

describe("Food buffs' IDs", function()
    local ns
    before_each(function() ns = wow.boot() end)

    it("are every spell Forever's data names Well Fed, in its order", function()
        assert.are.same(DATA.wellFed, ns.FoodBuffs.WELL_FED_SPELLS)
        for _, id in ipairs(DATA.wellFed) do assert.is_true(ns.FoodBuffs.WELL_FED[id], "spell " .. id) end
    end)

    it("list exactly the data's foods, each with its spell, level, name, and whether it's a drink", function()
        local count = 0
        for item, food in pairs(DATA.foods) do
            count = count + 1
            local ours = ns.FoodBuffs.FOODS[item]
            assert.is_table(ours, "item " .. item)
            assert.are.equal(food.spell, ours.spell, "item " .. item)
            assert.are.equal(food.level, ours.level, "item " .. item)
            assert.are.equal(food.name, ours.name, "item " .. item)
            assert.are.equal(food.drink == true, ours.drink == true, "item " .. item)
        end
        for item in pairs(ns.FoodBuffs.FOODS) do assert.is_table(DATA.foods[item], "item " .. item .. " isn't in the data") end
        assert.are.equal(122, count, "Forever build " .. DATA.build .. "'s foods")
    end)

    it("give a Well Fed of the list, after 10 seconds of eating, and leave out what can't be read", function()
        local wellFed = {}
        for _, id in ipairs(DATA.wellFed) do wellFed[id] = true end
        for item, food in pairs(DATA.foods) do
            assert.is_true(wellFed[food.wellFed], "item " .. item)
            assert.are.equal(10000, food.period, "item " .. item)
            assert.are.equal(wow.EATING_TICK * 1000, food.period, "the simulated client's 10 seconds")
        end
        for item in pairs(DATA.leftOut) do assert.is_nil(ns.FoodBuffs.FOODS[item], "item " .. item) end
    end)

    it("match the simulated client's foods, spells and Well Fed", function()
        local wellFed = {}
        for _, id in ipairs(DATA.wellFed) do wellFed[id] = true end
        for item, info in pairs(wow.FOOD_ITEMS) do
            local food = assert(DATA.foods[item], "item " .. item)
            assert.are.equal(food.spell, info.spell, "item " .. item)
            assert.are.equal(food.wellFed, info.wellFed, "item " .. item)
            assert.are.equal(food.name, info.name, "item " .. item)
            assert.are.equal(food.drink == true, info.spellName == "Nutritious Drink", "item " .. item)
        end
        for id in pairs(wow.WELL_FED) do assert.is_true(wellFed[id], "the client's Well Fed " .. id) end
        assert.is_nil(DATA.foods[wow.PLAIN_FOOD], "the client's plain food gives no Well Fed")
        assert.is_nil(wellFed[wow.EATING_AURA], "eating isn't Well Fed")
    end)

    it("include the owner's examples: Smoked Desert Dumplings, Monster Omelet and Spiced Wolf Meat", function()
        assert.are.equal(45, DATA.foods[20452].level)
        assert.are.equal("Monster Omelet", DATA.foods[12218].name)
        assert.are.equal(1248378, DATA.foods[2680].spell)
    end)
end)
