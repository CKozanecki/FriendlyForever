-- Spec: #544
-- Food buffs (experimental, off by default): in buff mode, after everyone
-- else and after your weapon buffs, the button offers the one food you chose
-- while you have no Well Fed, carry it, aren't in combat and aren't resting.
-- One press eats it ("/use item:<id>"), through the same secure button; Well
-- Fed comes after 10 seconds of eating. Solo, Well Fed running out turns buff
-- mode on to offer it again. Nothing is eaten without a press.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local F = wow.FOOD
local W = wow.WEAPON
local INTELLECT, FORT, INNER_FIRE = 10157, 10938, 10952
local WOLF_MACRO = "/use item:2680"

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Food buffs", function()
    local ns, button

    -- A mage unless said, food buffs on with Spiced Wolf Meat chosen, two in
    -- your bags, in buff mode unless opts.noMode. opts.before changes the
    -- client first.
    local function boot(opts)
        opts = opts or {}
        local db = opts.db or { buffBack = { foodBuffs = opts.off ~= true, foodItem = opts.food or F.spicedWolfMeat,
            weaponBuffs = opts.weapon == true, weaponMain = opts.weapon and "wizardOil" or "none", weaponOff = "none" } }
        ns = wow.boot({ db = db, buffSelf = true, autoBuffMode = opts.auto, before = function(state)
            state.class = opts.class or "MAGE"
            state.knownSpells = {}
            for _, id in ipairs(opts.known or {}) do state.knownSpells[id] = true end
            state.items = opts.items or { [F.spicedWolfMeat] = 2 }
            state.itemNames = { [F.spicedWolfMeat] = "Spiced Wolf Meat", [W.brilliantWizardOil] = "Brilliant Wizard Oil" }
            if opts.before then opts.before(state) end
        end })
        button = ns.BuffButton.Frame()
        if not opts.noMode then slash("buffmode on") end
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end
    local function subtitle() return button.subtitle:GetText() end
    local function refresh() ns.BuffButton.Refresh() end
    -- A click: anything that uses an item needs one (#544, the owner).
    local function press() wow.press(button, "LeftButton") end
    local function pressKey() wow.pressKey("MOUSEWHEELUP") end
    local function fed(spell) return wow.gainBuff({ spellId = spell or 1248420, name = "Well Fed", duration = 900,
        expirationTime = wow.now + 900 }) end
    local function nothingOffered(why)
        refresh()
        assert.is_nil(macro())
        if why then assert.matches("Food: " .. why, subtitle(), 1, true) end
    end

    describe("offering and pressing (white)", function()
        it("offers your food when you have no Well Fed, and a press eats it: Well Fed after 10 seconds", function()
            boot()
            assert.are.equal(WOLF_MACRO, macro())
            assert.are.equal("You", button.title:GetText())
            assert.are.equal("eat Spiced Wolf Meat (no Well Fed)", subtitle())
            press()
            assert.are.equal(1, #wow.meals)
            assert.are.equal(F.spicedWolfMeat, wow.meals[1].item)
            assert.are.equal(1, wow.state.items[F.spicedWolfMeat])
            assert.matches("Eating Spiced Wolf Meat: Well Fed after 10 seconds.", button.result:GetText(), 1, true)
            -- While you eat, nothing: another press would start the meal again.
            nothingOffered("you're eating")
            wow.advance(9)
            nothingOffered("you're eating")
            wow.advance(1)
            assert.are.equal(1248420, wow.wellFedAura().spellId)
            refresh()
            assert.is_nil(macro(), "Well Fed: nothing")
            wow.advance(30)
            refresh()
            assert.is_nil(macro(), "still Well Fed once the eating window is over")
            assert.are.equal(1, #wow.meals, "one press, one meal")
        end)

        it("comes after everyone else: a favour, your group, your self-buffs and your weapon buffs first", function()
            boot({ class = "PRIEST", known = { FORT, INNER_FIRE }, weapon = true,
                items = { [F.spicedWolfMeat] = 2, [W.brilliantWizardOil] = 1 } })
            wow.setGroup("party", { "Ann-Vale" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
            wow.gainBuff({ sourceUnit = "nameplate1", spellId = INTELLECT })
            local seen = {}
            for _ = 1, 8 do
                refresh()
                local text = macro()
                if not text then break end
                seen[#seen + 1] = text
                press()
                wow.advance(0)
            end
            assert.is_truthy(seen[1]:find("/targetexact Bob Stone", 1, true), "the favour first: " .. seen[1])
            assert.are.equal(WOLF_MACRO, seen[#seen], "your food last")
            local at = {}
            for i, text in ipairs(seen) do at[text] = at[text] or i end
            assert.is_truthy(at["/cast [@player,nodead] Inner Fire"], "your self-buff")
            assert.is_truthy(at["/use item:20749\n/use 16"], "your weapon buff")
            assert.is_true(at["/cast [@player,nodead] Inner Fire"] < at["/use item:20749\n/use 16"])
            assert.is_true(at["/use item:20749\n/use 16"] < at[WOLF_MACRO])
            local ann
            for i, text in ipairs(seen) do if text:find("Ann", 1, true) then ann = i end end
            assert.is_truthy(ann, "Ann's Fortitude")
            assert.is_true(ann < at[WOLF_MACRO])
            assert.are.equal(1, #wow.meals)
        end)

        it("offers the food you chose, not another you carry", function()
            boot({ food = F.monsterOmelet, items = { [F.spicedWolfMeat] = 3, [F.monsterOmelet] = 1 } })
            assert.are.equal("/use item:12218", macro())
            assert.are.equal("eat Monster Omelet (no Well Fed)", subtitle())
        end)

        it("offers a drink that gives Well Fed too, by the list's name when the client has none yet", function()
            boot({ food = F.goldthornTea, items = { [F.goldthornTea] = 1 } })
            assert.are.equal("/use item:10841", macro())
            assert.are.equal("eat Goldthorn Tea (no Well Fed)", subtitle())
            press()
            wow.advance(10)
            assert.are.equal(1249907, wow.wellFedAura().spellId)
        end)

        it("a click eats it in a druid's form too: the game drops the form, as eating by hand", function()
            boot({ class = "DRUID", before = function(s) s.form = 1 end })
            assert.are.equal(WOLF_MACRO, macro())
            press()
            assert.are.equal(1, #wow.meals)
            assert.are.equal(1, wow.formsCancelled)
            assert.are.equal("LeftButton", wow.itemUses[1].by)
        end)

        it("no answer from the game: says so, and holds the food back a while", function()
            boot({ before = function(s) s.useDoesNothing = true end })
            press()
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
            assert.matches("No answer: you didn't start eating your Spiced Wolf Meat.", button.result:GetText(), 1, true)
            nothingOffered("you couldn't eat your last Spiced Wolf Meat")
            wow.advance(ns.FoodBuffs.HELD_BACK_SECONDS)
            refresh()
            assert.are.equal(WOLF_MACRO, macro())
        end)

        it("a clicked food row is its own kind, so it never takes another row's place", function()
            boot()
            assert.are.equal("food", ns.BuffButton.OfferKind({ food = true, name = "Me" }))
            local rows = ns.BuffList.Rows()
            for i, offer in ipairs(ns.BuffList.ShownOffers()) do
                if offer.food then rows[i].scripts.OnClick(rows[i]) end
            end
            refresh()
            assert.are.equal(WOLF_MACRO, macro(), "chosen and still offered")
        end)

        it("right-click skips your food for 5 minutes", function()
            boot()
            wow.press(button, "RightButton")
            assert.matches("Skipping your food for 5 minutes.", button.result:GetText(), 1, true)
            nothingOffered("your food is skipped for now (you right-clicked)")
            wow.advance(ns.FoodBuffs.SKIP_SECONDS)
            refresh()
            assert.are.equal(WOLF_MACRO, macro())
            assert.are.equal(0, #wow.meals)
        end)
    end)

    describe("Well Fed (white)", function()
        it("with Well Fed up, nothing is offered: any Well Fed, not only your food's", function()
            for _, spell in ipairs({ 1248420, 1248406, 1249907, 24799, 19705 }) do
                boot()
                fed(spell)
                refresh()
                assert.is_nil(macro(), "Well Fed " .. spell)
                assert.is_nil(subtitle():find("Food:", 1, true), "nothing to say while Well Fed " .. spell)
            end
        end)

        it("never renews a running Well Fed early, even in its last seconds", function()
            boot({ before = function(s) s.expirePlayerAuras = true end })
            fed()
            wow.advance(899)
            refresh()
            assert.is_nil(macro(), "one second left")
            wow.advance(1)
            refresh()
            assert.are.equal(WOLF_MACRO, macro(), "gone: offered")
        end)

        it("a meal cut short holds the food back a while, and twice in a row stops it for 5 minutes", function()
            boot({ items = { [F.spicedWolfMeat] = 5 } })
            press()
            wow.interruptMeal() -- you moved
            wow.advance(ns.FoodBuffs.EATING_SECONDS)
            nothingOffered("you couldn't eat your last Spiced Wolf Meat")
            wow.advance(ns.FoodBuffs.HELD_BACK_SECONDS)
            refresh()
            assert.are.equal(WOLF_MACRO, macro())
            press()
            wow.interruptMeal()
            wow.advance(ns.FoodBuffs.EATING_SECONDS + ns.FoodBuffs.HELD_BACK_SECONDS)
            nothingOffered("you couldn't eat your Spiced Wolf Meat twice")
            wow.advance(ns.FoodBuffs.STOP_SECONDS)
            refresh()
            assert.are.equal(WOLF_MACRO, macro(), "the stop runs out")
            press()
            wow.advance(10)
            refresh()
            assert.is_not_nil(wow.wellFedAura(), "eaten this time")
            assert.is_nil(macro())
        end)

        it("Well Fed ends the count in a row: one cut short after it is held back only a moment", function()
            boot({ items = { [F.spicedWolfMeat] = 5 }, before = function(s) s.expirePlayerAuras = true end })
            press()
            wow.interruptMeal()
            wow.advance(ns.FoodBuffs.EATING_SECONDS + ns.FoodBuffs.HELD_BACK_SECONDS)
            refresh()
            press()
            wow.advance(10)
            refresh()
            assert.is_not_nil(wow.wellFedAura())
            wow.advance(wow.WELL_FED_SECONDS)
            refresh()
            assert.are.equal(WOLF_MACRO, macro())
            press()
            wow.interruptMeal()
            wow.advance(ns.FoodBuffs.EATING_SECONDS)
            nothingOffered("you couldn't eat your last Spiced Wolf Meat")
            wow.advance(ns.FoodBuffs.HELD_BACK_SECONDS)
            refresh()
            assert.are.equal(WOLF_MACRO, macro(), "a first time again, not a second")
        end)

        it("a refusal by the game holds the food back a while, as for weapon buffs", function()
            boot({ before = function(s) s.foodRefusal = "You can't do that yet." end })
            press()
            assert.matches("Couldn't buff you: You can't do that yet.", button.result:GetText(), 1, true)
            assert.are.equal(0, #wow.meals)
            nothingOffered("you couldn't eat your last Spiced Wolf Meat")
            wow.state.foodRefusal = nil
            wow.advance(ns.FoodBuffs.HELD_BACK_SECONDS)
            refresh()
            assert.are.equal(WOLF_MACRO, macro())
        end)

        it("when Well Fed runs out solo, out of combat, buff mode turns on and offers your food", function()
            boot({ auto = true, noMode = true, before = function(s) s.expirePlayerAuras = true end })
            for _, field in ipairs({ "autoOnJoin", "autoOnDeath", "autoOnBuffed", "autoOnCampfire" }) do
                ns.db.buffBack[field] = false
            end
            fed()
            wow.advance(ns.BuffModeAuto.WATCH_SECONDS)
            wow.advance(ns.BuffModeAuto.WATCH_SECONDS)
            assert.is_false(ns.BuffMode.IsOn(), "Well Fed: off")
            wow.advance(900)
            wow.advance(ns.BuffModeAuto.WATCH_SECONDS)
            assert.is_true(ns.BuffMode.IsAuto(), "Well Fed ran out: on")
            refresh()
            assert.are.equal(WOLF_MACRO, macro())
            press()
            wow.advance(10)
            refresh()
            assert.is_false(ns.BuffMode.IsOn(), "eaten: done, off again")
        end)
    end)

    describe("buff mode's key (black)", function()
        local function keyMacro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.keyMacroText) end

        it("never uses your food, in a form or not, whatever Fast-cast buffs in form says; the button says to click",
            function()
            for _, case in ipairs({
                { class = "MAGE", form = 0, fast = false }, { class = "MAGE", form = 0, fast = true },
                { class = "DRUID", form = 1, fast = false }, { class = "DRUID", form = 1, fast = true },
                { class = "DRUID", form = 0, fast = true }, { class = "SHAMAN", form = 0, fast = true },
            }) do
                local what = case.class .. " form " .. case.form .. " fast " .. tostring(case.fast)
                boot({ class = case.class, before = function(s) s.form = case.form end })
                ns.db.buffBack.fastCastInForm = case.fast
                refresh()
                assert.are.equal(WOLF_MACRO, macro(), what)
                assert.is_nil(keyMacro(), what .. ": the key holds nothing")
                assert.are.equal(ns.BuffButton.ITEM_WAITS, ns.BuffButton.KeyWaitsNow(), what)
                assert.matches("click to buff (it uses an item)", button.mode:GetText(), 1, true)
                pressKey()
                wow.advance(1)
                assert.are.equal(0, #wow.meals, what .. ": the key ate it")
                assert.are.equal(0, #wow.itemUses, what)
                press()
                assert.are.equal(1, #wow.meals, what .. ": a click eats it")
            end
        end)

        it("buff mode's line says to click while your food is on the button", function()
            boot({ noMode = true })
            wow.printed = {}
            slash("buffmode on")
            assert.truthy(table.concat(wow.printed, "\n"):find("click the buff button to buff (it uses an item)", 1,
                true))
        end)
    end)

    describe("when nothing may be offered (black)", function()
        -- Solo, out of combat, buff mode's triggers at their defaults: Well
        -- Fed runs out, and a look follows. True when buff mode came on.
        local function soloRunsOut(opts)
            opts.auto, opts.noMode = true, true
            local before = opts.before
            opts.before = function(s)
                s.expirePlayerAuras = true
                if before then before(s) end
            end
            boot(opts)
            fed()
            wow.advance(ns.BuffModeAuto.WATCH_SECONDS)
            wow.advance(ns.BuffModeAuto.WATCH_SECONDS)
            if opts.after then opts.after() end
            wow.advance(900)
            wow.advance(ns.BuffModeAuto.WATCH_SECONDS)
            wow.advance(ns.BuffModeAuto.WATCH_SECONDS)
            return ns.BuffMode.IsOn()
        end

        it("out of your food: nothing, and buff mode isn't turned on for it", function()
            boot({ items = {} })
            nothingOffered("no Spiced Wolf Meat in your bags")
            assert.is_false(soloRunsOut({ items = {} }))
        end)

        it("carrying only another food: nothing", function()
            boot({ items = { [F.monsterOmelet] = 4 } })
            nothingOffered("no Spiced Wolf Meat in your bags")
        end)

        it("in combat: nothing, and Well Fed running out in a fight doesn't turn buff mode on", function()
            boot()
            wow.enterCombat()
            refresh()
            assert.is_nil(macro())
            local offer, why, settled = ns.FoodBuffs.Next()
            assert.is_nil(offer)
            assert.are.equal("in combat", why)
            assert.is_false(settled, "a fight passes: not settled")
            assert.is_false(soloRunsOut({ after = function() wow.enterCombat() end }))
            refresh()
            assert.is_nil(macro())
        end)

        it("resting: nothing, and buff mode isn't turned on for it", function()
            boot({ before = function(s) s.resting = true end })
            nothingOffered("you're resting")
            assert.is_false(soloRunsOut({ before = function(s) s.resting = true end }))
        end)

        it("a switch damaged mid-session reads as off", function()
            for _, bad in ipairs({ "junk", 1, {}, false }) do
                boot()
                ns.db.buffBack.foodBuffs = bad
                refresh()
                assert.is_nil(macro(), tostring(bad))
                assert.is_nil(ns.FoodBuffs.Next(), tostring(bad))
            end
        end)

        it("with food buffs off, or no food chosen: nothing, and no buff mode for it", function()
            boot({ off = true })
            refresh()
            assert.is_nil(macro())
            assert.is_nil(subtitle():find("Food:", 1, true))
            assert.is_false(soloRunsOut({ off = true }))
            boot({ food = 0 })
            refresh()
            assert.is_nil(macro())
            assert.is_false(soloRunsOut({ food = 0 }))
        end)

        it("a chosen food that isn't one of the list, or isn't a whole number, is none, and loads as none", function()
            for _, bad in ipairs({ 117, 2680.5, -2680, "2680", {}, true, 1e300, 0 / 0 }) do
                boot({ food = bad, items = { [F.spicedWolfMeat] = 2, [117] = 2 } })
                refresh()
                assert.is_nil(macro(), tostring(bad))
                assert.are.equal(0, ns.db.buffBack.foodItem, "loading heals " .. tostring(bad))
                -- Damaged mid-session, too.
                ns.db.buffBack.foodItem = F.spicedWolfMeat
                refresh()
                assert.are.equal(WOLF_MACRO, macro())
                ns.db.buffBack.foodItem = bad
                refresh()
                assert.is_nil(macro(), "mid-session " .. tostring(bad))
                assert.is_nil(ns.FoodBuffs.Next(), "not even offered " .. tostring(bad))
                assert.is_nil(ns.FoodBuffs.Chosen(), tostring(bad))
            end
        end)

        it("dead, mounted or on a flight path: nothing", function()
            boot()
            wow.state.units.player.dead = true
            nothingOffered("you're dead")
            wow.state.units.player.dead = false
            wow.state.mounted = true
            nothingOffered("you're mounted")
            wow.state.mounted, wow.state.onTaxi = false, true
            nothingOffered("you're on a flight path")
        end)

        it("a food you can't eat yet: nothing", function()
            boot({ before = function(s) s.unusableItems[F.spicedWolfMeat] = true end })
            nothingOffered("can't eat Spiced Wolf Meat yet")
        end)
    end)

    describe("a read that can't be trusted (black)", function()
        it("your buffs restricted (an error), or no aura API: can't tell, nothing", function()
            boot({ before = function(s) s.aurasRestricted = true end })
            nothingOffered("can't tell whether you're Well Fed")
            boot()
            _G.C_UnitAuras.GetAuraDataByIndex = nil
            nothingOffered("can't tell whether you're Well Fed")
        end)

        it("a secret aura, a secret or junk spell ID: can't tell, nothing", function()
            for _, aura in ipairs({
                wow.secret({ spellId = 1248420 }),
                { spellId = wow.secret(1248420), isHelpful = true },
                { spellId = "1248420", isHelpful = true },
                { spellId = 0 / 0, isHelpful = true },
                { isHelpful = true },
            }) do
                boot()
                table.insert(wow.state.playerAuras, aura)
                nothingOffered("can't tell whether you're Well Fed")
            end
            -- A junk aura (not a table) too.
            boot()
            _G.C_UnitAuras.GetAuraDataByIndex = function(_, i) if i == 1 then return "Well Fed" end end
            nothingOffered("can't tell whether you're Well Fed")
        end)

        it("an unreadable aura beside a Well Fed: Well Fed, nothing, and nothing to say", function()
            boot()
            table.insert(wow.state.playerAuras, { spellId = wow.secret(1), isHelpful = true })
            fed()
            refresh()
            assert.is_nil(macro())
            assert.is_nil(subtitle():find("Food:", 1, true))
        end)

        it("more buffs than are looked through, none of them Well Fed: can't tell", function()
            boot()
            for i = 1, ns.Offers.MAX_AURAS do wow.gainBuff({ spellId = 100 + i }) end
            nothingOffered("can't tell whether you're Well Fed")
        end)

        it("a count that is a secret, an error, or no API: can't count, nothing", function()
            boot({ before = function(s) s.itemsSecret = true end })
            nothingOffered("can't count your Spiced Wolf Meat")
            boot()
            _G.C_Item.GetItemCount = function() error("no") end
            _G.GetItemCount = nil
            nothingOffered("can't count your Spiced Wolf Meat")
        end)

        it("whether you can eat it, unreadable: nothing", function()
            boot()
            _G.C_Item.IsUsableItem = function() return wow.secret(true) end
            _G.IsUsableItem = nil
            nothingOffered("can't tell whether you can eat Spiced Wolf Meat")
        end)

        it("resting that can't be read counts as resting: nothing", function()
            boot({ before = function(s) s.restingSecret = true end })
            nothingOffered("can't tell whether you're resting")
        end)

        it("the macro holds only a listed food, by a whole number", function()
            boot()
            local M = ns.FoodBuffs.Macro
            assert.are.equal(WOLF_MACRO, M({ food = true, foodItem = 2680 }))
            for _, bad in ipairs({ 117, 2680.5, "2680", "2680\n/cast Pyroblast", wow.secret(2680), -2680, {} }) do
                assert.is_nil(M({ food = true, foodItem = bad }), tostring(bad))
            end
            assert.is_nil(M({ foodItem = 2680 }), "not a food offer")
            assert.is_nil(M("2680"))
        end)

        it("the spell the client names for the food is read safely: a secret one adds nothing", function()
            boot({ before = function(s) s.foodSecrets = { itemSpell = true } end })
            assert.are.equal(WOLF_MACRO, macro())
            press()
            assert.are.equal(1, #wow.meals, "answered by the list's spell")
            assert.matches("Eating Spiced Wolf Meat", button.result:GetText(), 1, true)
        end)
    end)

    describe("the Weapon and food buffs page (white)", function()
        local function shown(dd)
            local out = {}
            for _, row in ipairs(dd.rows) do if row:IsShown() and row.value ~= nil then out[#out + 1] = row.value end end
            return out
        end

        it("is the Weapon buffs page renamed, and its switch and food are each character's settings", function()
            boot({ off = true, food = 0, items = { [F.spicedWolfMeat] = 1, [F.monsterOmelet] = 2, [117] = 5 } })
            local _, _, page = ns.Options.Pages()
            assert.are.equal("Weapon and food buffs", page.name)
            assert.matches("Weapon and food buffs %(experimental%)", page.heading:GetText())
            wow.run(page, "OnShow")
            local w = ns.Options.widgets.weapon
            assert.is_false(w.foodEnabled:GetChecked())
            assert.are.equal("nothing", w.food:GetText())
            -- The foods you carry that give Well Fed, highest level first; not a plain food.
            assert.are.same({ 0, F.monsterOmelet, F.spicedWolfMeat }, shown(w.food))
            w.foodEnabled:SetChecked(true)
            wow.run(w.foodEnabled, "OnClick")
            assert.is_true(ns.db.buffBack.foodBuffs)
            for _, row in ipairs(w.food.rows) do
                if row.value == F.spicedWolfMeat then wow.run(row, "OnClick", "LeftButton") end
            end
            assert.are.equal(F.spicedWolfMeat, ns.db.buffBack.foodItem)
            assert.are.equal("Spiced Wolf Meat", w.food:GetText())
            assert.are.equal(WOLF_MACRO, macro(), "offered at once")
            local own = {}
            for _, field in ipairs(ns.Config.CHARACTER_FIELDS) do own[field] = true end
            assert.is_true(own.foodBuffs and own.foodItem, "each character's own (spec/percharacter_spec.lua)")
        end)

        it("keeps your choice in the list when you carry none, and lists what you carry each time it opens", function()
            boot({ items = {} })
            local _, _, page = ns.Options.Pages()
            wow.run(page, "OnShow")
            local w = ns.Options.widgets.weapon
            assert.are.same({ 0, F.spicedWolfMeat }, shown(w.food))
            assert.are.equal("Spiced Wolf Meat (none carried)", w.food:GetText())
            wow.state.items[F.goldthornTea] = 1
            wow.run(w.food, "OnClick")
            assert.are.same({ 0, F.goldthornTea, F.spicedWolfMeat }, shown(w.food))
        end)

        it("lists at most FOOD_ROWS foods, so the list fits", function()
            boot({ food = 0, before = function(s)
                for item in pairs(wow.FOOD_ITEMS) do s.items[item] = 1 end
                for item = 250065, 250081 do s.items[item] = 1 end
            end })
            local _, _, page = ns.Options.Pages()
            wow.run(page, "OnShow")
            assert.are.equal(ns.Options.FOOD_ROWS + 1, #shown(ns.Options.widgets.weapon.food))
        end)

        it("/friendly find food finds it", function()
            boot()
            wow.printed = {}
            slash("find food")
            local text = table.concat(wow.printed, "\n")
            assert.truthy(text:find("Offer my food in buff mode, after my weapon buffs", 1, true), text)
            assert.truthy(text:find("the Weapon and food buffs page", 1, true), text)
            wow.printed = {}
            slash("find well fed")
            assert.truthy(table.concat(wow.printed, "\n"):find("Weapon and food buffs page", 1, true))
        end)
    end)

    describe("an update that adds FoodBuffs.lua (black)", function()
        it("asks for a restart, not erroring, after only a /reload", function()
            wow.reset()
            local loaded = {}
            local _, files = wow.parseToc()
            for _, file in ipairs(files) do
                if file ~= "FoodBuffs.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
            end
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            wow.fire("PLAYER_ENTERING_WORLD", true, false)
            wow.advance(20)
            assert.are.same({}, wow.errors)
            assert.truthy(table.concat(wow.printed, "\n"):find("Restart the game (not /reload)", 1, true))
        end)
    end)

    describe("a chaos storm (red)", function()
        local SEEDS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 }
        local FOODS = { F.spicedWolfMeat, F.monsterOmelet, F.goldthornTea, F.candyBar }
        local CHOICES = { F.spicedWolfMeat, F.monsterOmelet, F.goldthornTea, F.candyBar, 0, 117, "junk", 2680.5 }
        -- Across the storms, so they're known to reach food, and its hazards:
        -- presses with food armed, meals, and presses while Well Fed was up.
        local checked, eaten, whileFed = 0, 0, 0

        for _, seed in ipairs(SEEDS) do
            it("never offers food while Well Fed is up, in combat or resting, and never eats without a press (seed "
                .. seed .. ")", function()
                random.seed(seed)
                local function int(m, n) return random.random(m, n) end
                local carried = {}
                for _, item in ipairs(FOODS) do carried[item] = 2 end
                boot({ food = FOODS[int(1, #FOODS)], items = carried,
                    before = function(s) s.expirePlayerAuras = true end })
                local presses = 0
                for step = 1, 150 do
                    local roll = int(1, 24)
                    local s = wow.state
                    local where = string.format("seed %d step %d", seed, step)
                    local sends = #wow.foodSends
                    local pressed = false
                    if roll == 1 then
                        s.items[FOODS[int(1, #FOODS)]] = int(0, 2)
                    elseif roll == 2 then
                        if int(1, 3) == 1 then fed(({ 1248420, 24799, 1249907 })[int(1, 3)])
                        else for id in pairs(wow.WELL_FED) do wow.loseBuff(id) end end
                    elseif roll == 3 then
                        if s.inCombat then wow.leaveCombat() else wow.enterCombat() end
                    elseif roll == 4 then
                        wow.rest(not s.resting)
                    elseif roll == 5 then
                        wow.interruptMeal()
                    elseif roll == 6 then
                        ns.db.buffBack.foodItem = CHOICES[int(1, #CHOICES)]
                    elseif roll == 7 then
                        ns.db.buffBack.foodBuffs = ({ true, true, false, "junk" })[int(1, 4)]
                    elseif roll == 8 then
                        -- Unreadable buffs, now and then, and readable again.
                        s.aurasRestricted = int(1, 4) == 1
                        s.itemsSecret = int(1, 5) == 1
                    elseif roll == 9 then
                        s.foodRefusal = int(1, 3) == 1 and "You can't do that yet." or nil
                        s.castLatency = int(0, 2)
                    elseif roll == 10 then
                        -- A buff that isn't Well Fed, or one that can't be read.
                        if int(1, 2) == 1 then wow.gainBuff({ spellId = 100 + int(1, 50) })
                        else table.insert(s.playerAuras, { spellId = wow.secret(1), isHelpful = true }) end
                    elseif roll == 11 then
                        for i = #s.playerAuras, 1, -1 do
                            if type(s.playerAuras[i].spellId) ~= "number" then table.remove(s.playerAuras, i) end
                        end
                    elseif roll <= 14 then
                        -- The storm calms: a state where your food fits (Well Fed
                        -- or not: the next press decides).
                        s.aurasRestricted, s.itemsSecret, s.foodRefusal = false, false, nil
                        for i = #s.playerAuras, 1, -1 do
                            if type(s.playerAuras[i].spellId) ~= "number" then table.remove(s.playerAuras, i) end
                        end
                        if s.inCombat then wow.leaveCombat() end
                        if s.resting then wow.rest(false) end
                        ns.db.buffBack.foodBuffs = true
                        ns.db.buffBack.foodItem = FOODS[int(1, #FOODS)]
                        for _, item in ipairs(FOODS) do s.items[item] = 2 end
                    elseif roll <= 20 then
                        -- What the client says now, at the press (the button re-arms as it begins).
                        refresh()
                        local text = macro()
                        local item = text and tonumber(text:match("^/use item:(%d+)$"))
                        if wow.wellFedAura() then whileFed = whileFed + 1 end
                        if item then
                            checked = checked + 1
                            local why = where .. ": " .. text
                            assert.is_nil(wow.wellFedAura(), why .. " while Well Fed")
                            assert.is_false(s.inCombat and true or false, why .. " in combat")
                            assert.is_false(s.resting and true or false, why .. " resting")
                            assert.is_true((s.items[item] or 0) > 0, why .. " not carried")
                            assert.is_truthy(wow.FOOD_ITEMS[item], why .. " not a food that gives Well Fed")
                            assert.are.equal(item, ns.db.buffBack.foodItem, why .. " not the food chosen")
                        end
                        -- A click, or buff mode's key, which never uses food (#544).
                        if int(1, 2) == 1 then press() else pressKey() end
                        presses, pressed = presses + 1, true
                    elseif roll == 21 then
                        wow.press(button, "RightButton")
                    else
                        wow.advance(int(1, 300))
                    end
                    refresh()
                    -- Never eaten without a press: food is sent only on one, one at a
                    -- time, and every meal (landed now or after the latency) was sent.
                    if not pressed then assert.are.equal(sends, #wow.foodSends, where .. ": food sent without a press") end
                    assert.is_true(#wow.foodSends - sends <= 1, where .. ": two foods sent by one press")
                    assert.is_true(#wow.meals <= #wow.foodSends, where .. ": a meal nobody sent")
                    for _, use in ipairs(wow.itemUses) do
                        assert.are.equal("LeftButton", use.by, where .. ": food used by " .. tostring(use.by))
                    end
                    assert.are.same({}, wow.errors, where)
                end
                assert.is_true(#wow.foodSends <= presses, "seed " .. seed .. ": more food sent than presses")
                eaten = eaten + #wow.meals
            end)
        end

        it("the storms armed and ate food, so they test something", function()
            assert.is_true(checked > 60, "food macros checked: " .. checked)
            assert.is_true(eaten > 40, "meals eaten: " .. eaten)
            assert.is_true(whileFed > 200, "presses while Well Fed: " .. whileFed)
        end)
    end)
end)
