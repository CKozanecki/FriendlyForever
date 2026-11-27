-- Food buffs (#544, experimental, off by default): in buff mode, once the
-- button has nothing left for favours, your group, your own self-buffs or
-- your weapon buffs, it offers the one food you chose (buffBack.foodItem)
-- while you have no Well Fed and carry it. On WoW Forever, cooked food that
-- gives Well Fed also gives 5% more experience (the owner, #544). One click,
-- one meal, through the same secure button. Nothing here uses anything.
--
-- The press: "/use item:<id>", built from fixed text and a whole number, the
-- item one of the listed IDs below (WeaponBuffs.lua's items are pressed the
-- same way). Nothing is used without your press, and only a click on the
-- button uses it: buff mode's key never uses an item (the owner, #544:
-- BuffButton.KeyWaits).
--
-- What it reads, and what "can't tell" does (the owner's decisions on #544):
--   your buffs (C_UnitAuras, "player"): Well Fed is up when one of your
--   helpful auras has one of the spell IDs below, every spell Forever's data
--   names "Well Fed" (the owner: one Well Fed buff, the same icon, different
--   stats). A buff that can't be read (a secret, an error, junk, more than
--   are looked through) is "can't tell", and nothing is offered, unless
--   another is Well Fed. No early renewal: only a missing Well Fed is
--   offered for, never a running one;
--   your bags: the food's count, and whether you can use it (its level);
--   resting, combat, being dead, mounted or on a flight path: as weapon
--   buffs (WeaponBuffs.Shared): nothing while you rest (only an answer of
--   exactly false is "not resting"), nothing in combat. A druid's form or
--   Ghost Wolf is no reason, as for weapon buffs: a press may drop you out
--   of the form, as eating by hand does, or the game refuses and says why.
--
-- Eating (Forever's data, docs/forever-facts.md "Food buffs"): each food's
-- spell triggers its Well Fed after 10 seconds of eating. After a press
-- lands, the button offers nothing at all for EATING_SECONDS, or until Well
-- Fed shows (FoodBuffs.Eating: no buff, shift back into your form or
-- passer-by stands you up mid-meal); a meal with no Well Fed by then was cut short (you moved, say), and counts as a refusal: the food is
-- held back HELD_BACK_SECONDS, and after REFUSALS_TO_STOP in a row, until
-- STOP_SECONDS pass, you change food, or Well Fed shows. Right-click skips
-- your food for SKIP_SECONDS.
--
-- Solo (the owner's decision 4): when Well Fed runs out, out of combat,
-- buff mode turns on to offer your food again (FoodBuffs.Missing, read by
-- BuffModeAuto.lua as your self-buffs are), only while it would be offered:
-- you carry it, and you aren't resting.
--
-- Where the IDs come from: docs/forever-facts.md ("Food buffs").
local _, ns = ...
local Util = ns.Util
-- An update that adds files, after only a /reload, may load this without
-- WeaponBuffs.lua: Core.lua then stays inert, and nothing here runs.
local Read = ns.WeaponBuffs and ns.WeaponBuffs.Shared or {}

local FoodBuffs = {}
ns.FoodBuffs = FoodBuffs

-- After a meal starts, how long nothing is offered: Well Fed comes after 10
-- seconds of eating (Forever's data), and the rest is room for the game.
FoodBuffs.EATING_SECONDS = 20
-- Right-click skips your food for this long.
FoodBuffs.SKIP_SECONDS = 300
-- A meal the game refused, or one cut short, waits this long.
FoodBuffs.HELD_BACK_SECONDS = 15
-- Refused or cut short this many times in a row for the same food, it is
-- left alone for STOP_SECONDS, or until you change food or Well Fed shows,
-- and counts as settled meanwhile.
FoodBuffs.REFUSALS_TO_STOP = 2
FoodBuffs.STOP_SECONDS = 300

-- The Buff Back settings the Weapon and food buffs page shows, besides the
-- weapon ones. The Buff Back tab's Reset leaves them as they are (Core.lua).
FoodBuffs.FIELDS = { "foodBuffs", "foodItem" }

-- The key a missing Well Fed is remembered by in buff mode's looks
-- (BuffModeAuto.lua): yours, beside your self-buffs' families and keys.
FoodBuffs.SLOT = "wellFed"

-- Every spell Forever's data names "Well Fed" (build 1.60.1.71139),
-- checked by spec/foodbuffs_data_spec.lua against scripts/data/forever-food.lua.
FoodBuffs.WELL_FED_SPELLS = {
    19705, 19706, 19708, 19709, 19710, 19711, 24799, 24870, 25694, 25941, 1225778, 1225779, 1225780, 1225782,
    1248406, 1248420, 1248421, 1248422, 1248688, 1249519, 1249520, 1249521, 1249523, 1249907, 1249926, 1249927,
    1283082, 1294007, 1302064, 1319310,
}
-- The foods that give Well Fed, by item ID: the spell its use casts, the level
-- it needs and its name (for when the client can't say it yet), lowest level
-- first. Forever's own data, checked by spec/foodbuffs_data_spec.lua. A drink
-- that gives Well Fed (its spell is a "Nutritious Drink") is marked.
FoodBuffs.FOODS = {
    [11584] = { spell = 5004, level = 0, name = "Cactus Apple Surprise" },
    [787] = { spell = 1249503, level = 1, name = "Slitherskin Mackerel" },
    [2680] = { spell = 1248378, level = 1, name = "Spiced Wolf Meat" },
    [2681] = { spell = 1248380, level = 1, name = "Roasted Boar Meat" },
    [2682] = { spell = 1248379, level = 1, name = "Cooked Crab Claw" },
    [2888] = { spell = 1248380, level = 1, name = "Beer Basted Boar Ribs" },
    [3663] = { spell = 1248381, level = 1, name = "Murloc Fin Soup" },
    [5472] = { spell = 1248377, level = 1, name = "Kaldorei Spider Kabob" },
    [5474] = { spell = 1248377, level = 1, name = "Roasted Kodo Meat" },
    [5477] = { spell = 1248379, level = 1, name = "Strider Stew" },
    [5525] = { spell = 1248377, level = 1, name = "Boiled Clams" },
    [6290] = { spell = 1249500, level = 1, name = "Brilliant Smallfish" },
    [6888] = { spell = 1248377, level = 1, name = "Herb Baked Egg" },
    [6890] = { spell = 1248380, level = 1, name = "Smoked Bear Meat" },
    [7806] = { spell = 5004, level = 1, name = "Lollipop" },
    [7807] = { spell = 5004, level = 1, name = "Candy Bar" },
    [7808] = { spell = 5004, level = 1, name = "Chocolate Square" },
    [12224] = { spell = 1248379, level = 1, name = "Crispy Bat Wing" },
    [17197] = { spell = 5004, level = 1, name = "Gingerbread Cookie" },
    [17198] = { spell = 21149, level = 1, name = "Egg Nog" },
    [206177] = { spell = 5004, level = 1, name = "Pine Nut Butter" },
    [249865] = { spell = 1249920, level = 1, name = "Peace Tea", drink = true },
    [249871] = { spell = 1249914, level = 1, name = "Venomous Smoothie", drink = true },
    [250079] = { spell = 1248379, level = 1, name = "Tasty Raptor Bites" },
    [287973] = { spell = 1248395, level = 1, name = "Tender Wolf Steak" },
    [287974] = { spell = 1249522, level = 1, name = "Grilled Squid" },
    [724] = { spell = 1248384, level = 5, name = "Goretusk Liver Pie" },
    [733] = { spell = 1248687, level = 5, name = "Westfall Stew" },
    [1082] = { spell = 1248383, level = 5, name = "Redridge Goulash" },
    [2683] = { spell = 1248383, level = 5, name = "Crab Cake" },
    [2684] = { spell = 1248382, level = 5, name = "Coyote Steak" },
    [2687] = { spell = 1248384, level = 5, name = "Dry Pork Ribs" },
    [3220] = { spell = 1248384, level = 5, name = "Blood Sausage" },
    [3662] = { spell = 1248382, level = 5, name = "Crocolisk Steak" },
    [3726] = { spell = 1248384, level = 5, name = "Big Bear Steak" },
    [4592] = { spell = 1249506, level = 5, name = "Longjaw Mud Snapper" },
    [5095] = { spell = 1249501, level = 5, name = "Rainbow Fin Albacore" },
    [5476] = { spell = 1249505, level = 5, name = "Fillet of Frenzy" },
    [5479] = { spell = 1248381, level = 5, name = "Crispy Lizard Tail" },
    [5526] = { spell = 1248381, level = 5, name = "Clam Chowder" },
    [6316] = { spell = 1249502, level = 5, name = "Loch Frenzy Delight" },
    [12213] = { spell = 1248381, level = 5, name = "Carrion Surprise" },
    [249866] = { spell = 1249921, level = 5, name = "Royal Tea", drink = true },
    [249872] = { spell = 1249915, level = 5, name = "Slimy Smoothie", drink = true },
    [250077] = { spell = 1248383, level = 5, name = "Twice-Spiced Raptor Slice" },
    [250080] = { spell = 1248381, level = 5, name = "Breakfast Omelette" },
    [263509] = { spell = 1248377, level = 5, name = "Skywall Souffle" },
    [263512] = { spell = 1248379, level = 5, name = "Pincer Bites" },
    [268912] = { spell = 1248381, level = 5, name = "Expiring Crab Cake" },
    [268913] = { spell = 1248381, level = 5, name = "Expiring Crocolisk Steak" },
    [21072] = { spell = 1249504, level = 10, name = "Smoked Sagefish" },
    [1017] = { spell = 1248387, level = 15, name = "Seasoned Wolf Kabob" },
    [2685] = { spell = 1248389, level = 15, name = "Succulent Pork Ribs" },
    [3664] = { spell = 1248387, level = 15, name = "Crocolisk Gumbo" },
    [3665] = { spell = 1248386, level = 15, name = "Curiously Tasty Omelet" },
    [3666] = { spell = 1248386, level = 15, name = "Gooey Spider Cake" },
    [3727] = { spell = 1248387, level = 15, name = "Hot Lion Chops" },
    [3729] = { spell = 1248386, level = 15, name = "Soothing Turtle Bisque" },
    [4593] = { spell = 1249508, level = 15, name = "Bristle Whisker Catfish" },
    [5480] = { spell = 1248389, level = 15, name = "Lean Venison" },
    [5527] = { spell = 1248386, level = 15, name = "Goblin Deviled Clams" },
    [12209] = { spell = 1248387, level = 15, name = "Lean Wolf Steak" },
    [12210] = { spell = 1248388, level = 15, name = "Roast Raptor" },
    [12214] = { spell = 1248386, level = 15, name = "Mystery Stew" },
    [249867] = { spell = 1249922, level = 15, name = "Root Tea", drink = true },
    [249873] = { spell = 1249916, level = 15, name = "Mrrggl Smrrthle", drink = true },
    [3728] = { spell = 1248391, level = 25, name = "Tasty Lion Steak" },
    [4457] = { spell = 1248392, level = 25, name = "Barbecued Buzzard Wing" },
    [4594] = { spell = 1249511, level = 25, name = "Rockscale Cod" },
    [6038] = { spell = 1248390, level = 25, name = "Giant Clam Scorcho" },
    [8364] = { spell = 1249509, level = 25, name = "Mithril Head Trout" },
    [10841] = { spell = 1249906, level = 25, name = "Goldthorn Tea", drink = true },
    [12215] = { spell = 1248390, level = 25, name = "Heavy Kodo Stew" },
    [12216] = { spell = 1248392, level = 25, name = "Spiced Chili Crab" },
    [13851] = { spell = 1248391, level = 25, name = "Hot Wolf Ribs" },
    [20074] = { spell = 1248391, level = 25, name = "Heavy Crocolisk Stew" },
    [249868] = { spell = 1249923, level = 25, name = "Triage Tea", drink = true },
    [249874] = { spell = 1249917, level = 25, name = "Calcified Smoothie", drink = true },
    [250073] = { spell = 1248392, level = 25, name = "Raging Raptor Ribs" },
    [250074] = { spell = 1248393, level = 25, name = "Bear Brisket" },
    [250078] = { spell = 1248390, level = 25, name = "Giant Scrambled Eggs" },
    [274971] = { spell = 1249510, level = 25, name = "Briny Seafood Stew" },
    [274976] = { spell = 1248393, level = 25, name = "Plain Ol' Paletusk" },
    [21217] = { spell = 1249507, level = 30, name = "Sagefish Delight" },
    [6887] = { spell = 1249513, level = 35, name = "Spotted Yellowtail" },
    [12212] = { spell = 1248395, level = 35, name = "Jungle Stew" },
    [12218] = { spell = 1248394, level = 35, name = "Monster Omelet" },
    [13927] = { spell = 1249512, level = 35, name = "Cooked Glossy Mightfish" },
    [13928] = { spell = 1249522, level = 35, name = "Grilled Squid" },
    [13929] = { spell = 1249522, level = 35, name = "Hot Smoked Bass" },
    [13930] = { spell = 1249514, level = 35, name = "Filet of Redgill" },
    [13931] = { spell = 1249513, level = 35, name = "Nightfin Soup" },
    [13932] = { spell = 1249515, level = 35, name = "Poached Sunscale Salmon" },
    [16766] = { spell = 1248394, level = 35, name = "Undermine Clam Chowder" },
    [17222] = { spell = 1248394, level = 35, name = "Spider Sausage" },
    [18045] = { spell = 1248395, level = 35, name = "Tender Wolf Steak" },
    [18254] = { spell = 1248396, level = 35, name = "Runn Tum Tuber Surprise" },
    [249869] = { spell = 1249924, level = 35, name = "Sunny Tea", drink = true },
    [249875] = { spell = 1249918, level = 35, name = "Spicy Smoothie", drink = true },
    [250065] = { spell = 1248397, level = 35, name = "Savory Stag Sliders" },
    [250076] = { spell = 1248396, level = 35, name = "Raptor Rouladen" },
    [286152] = { spell = 1319311, level = 35, name = "Plated Armorfish" },
    [16971] = { spell = 10256, level = 40, name = "Clamlette Surprise" },
    [8957] = { spell = 1249514, level = 45, name = "Spinefin Halibut" },
    [13933] = { spell = 1249516, level = 45, name = "Lobster Stew" },
    [13934] = { spell = 1249515, level = 45, name = "Mightfish Steak" },
    [13935] = { spell = 1249516, level = 45, name = "Baked Salmon" },
    [20452] = { spell = 1248401, level = 45, name = "Smoked Desert Dumplings" },
    [249870] = { spell = 1249925, level = 45, name = "Sage's Tea", drink = true },
    [249876] = { spell = 1249919, level = 45, name = "Wicked Smoothie", drink = true },
    [250066] = { spell = 1248400, level = 45, name = "Soaring Pamplona" },
    [250067] = { spell = 1248400, level = 45, name = "Bat Hachee" },
    [250068] = { spell = 1248398, level = 45, name = "Savory Turtle Stew" },
    [250069] = { spell = 1248399, level = 45, name = "Flank au Poivre" },
    [250070] = { spell = 1248401, level = 45, name = "Bear Bruscitti" },
    [250071] = { spell = 1248401, level = 45, name = "Steaming Stag Steak" },
    [250072] = { spell = 1248399, level = 45, name = "Swiftstrike Steak" },
    [250075] = { spell = 1248400, level = 45, name = "Prehistoric Pulled Raptor" },
    [250081] = { spell = 1248398, level = 45, name = "Clam Linguine" },
    [238637] = { spell = 1225769, level = 55, name = "Prowler Steak" },
    [238638] = { spell = 1225771, level = 55, name = "Filet o' Flank" },
    [238639] = { spell = 1225772, level = 55, name = "Sunrise Omelette" },
}
FoodBuffs.WELL_FED = {}
for _, id in ipairs(FoodBuffs.WELL_FED_SPELLS) do FoodBuffs.WELL_FED[id] = true end

local eating      -- { item, at = GetTime() } a meal started by a press
local refused     -- { item, count, at = GetTime() } the game's refusals, and meals cut short, in a row
local skippedAt   -- GetTime() you right-clicked your food
local said = {}   -- reasons said in debug, while they hold

-- The food you chose, as its item ID, while it's one of the list; nil for
-- none (or a setting that isn't one: the options and loading check it).
function FoodBuffs.Chosen()
    local item = Read.Setting("foodItem")
    if item ~= nil and FoodBuffs.FOODS[item] then return item end
    return nil
end

-- The client's name for a food, or the list's.
function FoodBuffs.Name(item)
    local food = FoodBuffs.FOODS[item]
    return Read.ItemName(item, { label = food and food.name or "your food" })
end

-- Whether Well Fed is up: true when one of your helpful auras is a Well Fed
-- spell; false when every one was read and none is; nil (can't tell) when
-- one couldn't be read, the list didn't end, or the game won't say.
function FoodBuffs.WellFed()
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if type(api) ~= "function" then return nil end
    local unsure = false
    for i = 1, ns.Offers.MAX_AURAS do
        local ok, aura = pcall(api, "player", i, "HELPFUL")
        if not ok or Util.IsSecret(aura) then return nil end
        if aura == nil then
            if unsure then return nil end
            return false
        end
        local id = type(aura) == "table" and aura.spellId or nil
        if Util.IsSecret(id) or type(id) ~= "number" or id ~= id then
            unsure = true
        elseif FoodBuffs.WELL_FED[id] then
            return true
        end
    end
    return nil
end

-- Say each reason once in debug while it holds.
local function Say(reasons)
    local now = {}
    for _, why in ipairs(reasons) do
        now[why] = true
        if not said[why] then ns.Diag.Log("buffMode", "food not offered: %s", why) end
    end
    said = now
end

-- Count a refusal, or a meal cut short, for item, at the time at (GetTime()):
-- in a row while it's the same food.
local function Refused(item, at)
    local count = 1
    if refused and refused.item == item then count = refused.count + 1 end
    refused = { item = item, count = count, at = at }
end

-- The spells a press of item may be answered by: the list's, and the one the
-- client names now, if it says.
local function CastIds(item)
    local ids = { [FoodBuffs.FOODS[item].spell] = true }
    local _, spell = Util.ReadGameValues(C_Item and C_Item.GetItemSpell, item)
    if spell == nil then _, spell = Util.ReadGameValues(GetItemSpell, item) end
    spell = Read.Id(spell)
    if spell then ids[spell] = true end
    return ids
end

-- Your food, to offer now: { name, self = true, food = true, foodItem, spell,
-- castIds, icon }, or nil, why not (nil when there's nothing to say), and
-- whether that's settled: nothing your food could fix now or soon. With a
-- list, the offer is appended, as WeaponBuffs.Next does.
function FoodBuffs.Next(out)
    if Read.Setting("foodBuffs") ~= true then return nil, nil, true end
    local item = FoodBuffs.Chosen()
    if not item then
        Say({})
        return nil, nil, true
    end
    local function Stop(why, open)
        Say({ why })
        return nil, why, not open
    end
    -- Resting first, as weapon buffs (#449): settled, so it never keeps buff
    -- mode on, even in a fight in town.
    local resting = Read.Resting()
    if resting then return Stop(resting, false) end
    if InCombatLockdown() then return nil, "in combat", false end
    local me = Util.UnitFullName("player")
    if not me then return Stop("your name can't be read", true) end
    if Read.Recently(skippedAt, FoodBuffs.SKIP_SECONDS) then
        return Stop("your food is skipped for now (you right-clicked)", false)
    end
    local cant, cantOpen = Read.YouCant()
    if cant then return Stop(cant, cantOpen) end
    local fed = FoodBuffs.WellFed()
    if fed == nil then return Stop("can't tell whether you're Well Fed", true) end
    local name = FoodBuffs.Name(item)
    if fed then
        -- Fed: the meal is over, and "in a row" ends.
        eating, refused = nil, nil
        Say({})
        return nil, nil, true
    end
    if eating then
        if Read.Recently(eating.at, FoodBuffs.EATING_SECONDS) then return Stop("you're eating", true) end
        -- No Well Fed in time: the meal was cut short, as the time ran out.
        Refused(eating.item, eating.at + FoodBuffs.EATING_SECONDS)
        eating = nil
    end
    if refused and refused.item == item then
        if refused.count >= FoodBuffs.REFUSALS_TO_STOP and Read.Recently(refused.at, FoodBuffs.STOP_SECONDS) then
            return Stop("you couldn't eat your " .. name .. " twice: trying again in a few minutes, or choose "
                .. "another food", false)
        end
        if Read.Recently(refused.at, FoodBuffs.HELD_BACK_SECONDS) then
            return Stop("you couldn't eat your last " .. name, true)
        end
    end
    local count = Read.Count(item)
    if count == nil then return Stop("can't count your " .. name, true) end
    if count < 1 then return Stop("no " .. name .. " in your bags", false) end
    local usable = Read.UsableItem(item)
    if usable == nil then return Stop("can't tell whether you can eat " .. name, true) end
    if not usable then return Stop("can't eat " .. name .. " yet", false) end
    Say({})
    local offer = { name = me, self = true, food = true, foodItem = item, spell = name, castIds = CastIds(item),
        icon = Read.ItemIcon(item) }
    if out then out[#out + 1] = offer end
    return offer
end

-- Your missing Well Fed, for buff mode's looks (BuffModeAuto.lua, solo, the
-- owner's decision 4), in SelfBuffs.Missing's shape: the list (one entry
-- while your food would be offered), what you wear ([key] = true while Well
-- Fed is up) and what runs low (never: no early renewal). nil when your name
-- can't be read.
function FoodBuffs.Missing()
    local me = Util.UnitFullName("player")
    if not me then return nil end
    local key = me .. "\1" .. FoodBuffs.SLOT
    local list, worn = {}, {}
    if FoodBuffs.Next() then list[1] = { name = me, slot = FoodBuffs.SLOT, self = true, food = true } end
    if FoodBuffs.WellFed() == true then worn[key] = true end
    return list, worn, {}
end

-- The macro for a food offer, or nil when it isn't one it may hold: an item
-- only by a listed ID (see the top).
function FoodBuffs.Macro(offer)
    if type(offer) ~= "table" or not offer.food then return nil end
    local item = Read.Id(offer.foodItem)
    if not item or not FoodBuffs.FOODS[item] then return nil end
    return string.format("/use item:%d", item)
end

-- Whether a meal a press started is under way: within EATING_SECONDS of it,
-- and no Well Fed seen yet. Meanwhile the button offers nothing at all
-- (BuffButton.lua): another press (a buff, the shift back into your form, a
-- passer-by) would stand you up and cut the meal short. Reads only.
function FoodBuffs.Eating()
    if not eating or not Read.Recently(eating.at, FoodBuffs.EATING_SECONDS) then return false end
    return FoodBuffs.WellFed() ~= true
end

-- A press of item landed: you're eating.
function FoodBuffs.NoteEating(item)
    eating = { item = item, at = GetTime() }
end

-- The game refused your food (item): hold it back, and count it.
function FoodBuffs.NoteRefused(item)
    eating = nil
    Refused(item, GetTime())
end

-- Right-click: leave your food out for a while.
function FoodBuffs.Skip()
    skippedAt = GetTime()
end
