-- Spec: #45
-- Weapon buffs (experimental, off by default): in buff mode, after your
-- group and your self-buffs, the button offers the kind you chose for a hand
-- with no temporary enchant: the best you carry and can use. One press puts
-- it on, through the same secure button: "/use item:<id>" then "/use 16" or
-- "/use 17", or a shaman's imbue cast on yourself. Nothing goes on by itself.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local W = wow.WEAPON
local INNER_FIRE = 10952
local ROCKBITER_4, ROCKBITER_1, WINDFURY_4 = 10399, 8017, 16362

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Weapon buffs", function()
    local ns, button

    -- A mage unless said, weapon buffs on with the given kinds, in buff mode
    -- unless opts.noMode. opts.before changes the client first.
    local function boot(opts)
        opts = opts or {}
        local db = opts.db or { buffBack = { weaponBuffs = opts.off ~= true, weaponMain = opts.main or "wizardOil",
            weaponOff = opts.offHand or "none" } }
        ns = wow.boot({ db = db, buffSelf = true, autoBuffMode = opts.auto, before = function(state)
            state.class = opts.class or "MAGE"
            state.knownSpells = {}
            for _, id in ipairs(opts.known or {}) do state.knownSpells[id] = true end
            state.items = opts.items or { [W.brilliantWizardOil] = 2, [W.lesserWizardOil] = 3 }
            state.itemNames = { [W.brilliantWizardOil] = "Brilliant Wizard Oil", [W.lesserWizardOil] = "Lesser Wizard Oil",
                [W.instantPoison6] = "Instant Poison VI", [W.deadlyPoison5] = "Deadly Poison V",
                [W.roughWeightstone] = "Rough Weightstone" }
            if opts.before then opts.before(state) end
        end })
        button = ns.BuffButton.Frame()
        if not opts.noMode then slash("buffmode on") end
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end
    local function subtitle() return button.subtitle:GetText() end
    local function refresh() ns.BuffButton.Refresh() end
    local function press() wow.pressKey("MOUSEWHEELUP") end

    describe("offering and pressing (white)", function()
        it("offers the best wizard oil you carry for a bare main hand, and a press puts it on", function()
            boot()
            assert.are.equal("/use item:20749\n/use 16", macro())
            assert.are.equal("You", button.title:GetText())
            assert.are.equal("Brilliant Wizard Oil on your main hand", subtitle())
            press()
            assert.are.equal(1, #wow.applied)
            assert.are.equal(16, wow.applied[1].slot)
            assert.are.equal(W.brilliantWizardOil, wow.applied[1].item)
            assert.are.equal(2628, wow.enchantOn(16).id)
            assert.are.equal(1, wow.state.items[W.brilliantWizardOil])
            assert.matches("Applied Brilliant Wizard Oil to your main hand.", button.result:GetText(), 1, true)
            refresh()
            assert.is_nil(macro())
        end)

        it("offers the next best when you're out of the best", function()
            boot({ items = { [W.lesserWizardOil] = 1 } })
            assert.are.equal("/use item:20746\n/use 16", macro())
        end)

        it("comes after your self-buffs", function()
            boot({ class = "PRIEST", known = { INNER_FIRE } })
            assert.are.equal("/cast [@player,nodead] Inner Fire", macro())
            press()
            wow.advance(0)
            refresh()
            assert.are.equal("/use item:20749\n/use 16", macro())
        end)

        it("puts a rogue's poisons on the main hand first, then the off hand with /use 17", function()
            boot({ class = "ROGUE", main = "deadlyPoison", offHand = "instantPoison",
                items = { [W.deadlyPoison5] = 1, [W.instantPoison6] = 1 },
                before = function(s) s.equipped[17] = wow.GEAR.dagger end })
            assert.are.equal("/use item:20844\n/use 16", macro())
            press()
            refresh()
            assert.are.equal("/use item:8928\n/use 17", macro())
            press()
            assert.are.equal(2630, wow.enchantOn(16).id)
            assert.are.equal(625, wow.enchantOn(17).id)
        end)

        it("casts a shaman's imbue, the best rank known, on the main hand", function()
            boot({ class = "SHAMAN", main = "rockbiter", known = { ROCKBITER_1, ROCKBITER_4 } })
            assert.are.equal("/cast [@player,nodead] Rockbiter Weapon\n/use 16", macro())
            assert.are.equal("Rockbiter Weapon on your main hand", subtitle())
            press()
            assert.are.equal(503, wow.enchantOn(16).id, "rank 4's enchant")
            assert.matches("Applied Rockbiter Weapon to your main hand.", button.result:GetText(), 1, true)
            assert.are.equal(0, #wow.weaponUses)
        end)

        it("puts an imbue on the main hand when the game waits for a weapon to be picked, too", function()
            boot({ class = "SHAMAN", main = "windfury", known = { WINDFURY_4 },
                before = function(s)
                    s.imbuePicks = true
                    s.equipped[17] = wow.GEAR.mace
                end })
            press()
            assert.are.equal(1669, wow.enchantOn(16).id)
            assert.is_nil(wow.enchantOn(17))
            assert.matches("Applied Windfury Weapon to your main hand.", button.result:GetText(), 1, true)
        end)

        it("leaves an imbue for a weapon with its own Use to you, as an item", function()
            boot({ class = "SHAMAN", main = "rockbiter", known = { ROCKBITER_4 },
                before = function(s) s.equipped[16] = wow.GEAR.useSword end })
            refresh()
            assert.is_nil(macro())
            assert.matches("Weapons: your main hand weapon has its own Use: cast Rockbiter Weapon by hand", subtitle(), 1, true)
            -- And when whether it has one can't be read, nothing either.
            boot({ class = "SHAMAN", main = "rockbiter", known = { ROCKBITER_4 },
                before = function(s) s.weaponSecrets.itemSpell = true end })
            refresh()
            assert.is_nil(macro())
            assert.matches("Weapons: can't tell whether your main hand weapon has a Use", subtitle(), 1, true)
        end)

        it("leaves a hand that has an enchant alone, and offers the other", function()
            boot({ class = "ROGUE", main = "deadlyPoison", offHand = "instantPoison",
                items = { [W.deadlyPoison5] = 1, [W.instantPoison6] = 1 },
                before = function(s)
                    s.equipped[17] = wow.GEAR.dagger
                    s.weaponEnchants[16] = { id = 19, expires = 1e9, charges = 0 }
                end })
            assert.are.equal("/use item:8928\n/use 17", macro())
            wow.enchant(17, 625)
            refresh()
            assert.is_nil(macro())
            assert.are.equal(0, #wow.applied)
        end)

        it("offers it again once the enchant runs out", function()
            boot()
            press()
            refresh()
            assert.is_nil(macro())
            wow.advance(1801)
            refresh()
            assert.are.equal("/use item:20749\n/use 16", macro())
        end)

        it("skips your weapon buffs for 5 minutes on a right-click", function()
            boot()
            wow.press(button, "RightButton")
            assert.matches("Skipping your weapon buffs for 5 minutes.", button.result:GetText(), 1, true)
            refresh()
            assert.is_nil(macro())
            wow.advance(ns.WeaponBuffs.SKIP_SECONDS + 1)
            refresh()
            assert.are.equal("/use item:20749\n/use 16", macro())
        end)

        it("lists the hand in the list beside the button", function()
            boot({ class = "ROGUE", main = "deadlyPoison", offHand = "instantPoison",
                items = { [W.deadlyPoison5] = 1, [W.instantPoison6] = 1 },
                before = function(s) s.equipped[17] = wow.GEAR.dagger end })
            local shown = ns.BuffList.ShownOffers()
            assert.are.equal(1, #shown, "one row for you")
            assert.are.equal("main hand", shown[1].hand)
        end)

        it("does nothing outside buff mode", function()
            boot({ noMode = true })
            assert.is_nil(macro())
        end)
    end)

    describe("the list, the tooltip and the debug log (white)", function()
        local FORT, INTELLECT = 10938, 10157

        -- A priest in a party with Ann, Fortitude on Ann, nothing on you.
        local function priest()
            boot({ class = "PRIEST", known = { FORT } })
            wow.setGroup("party", { "Ann-Vale" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            wow.wearBuff("party1", FORT, { source = "player" })
            refresh()
        end
        local function strangerBuffs()
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
            wow.gainBuff({ sourceUnit = "nameplate1", spellId = INTELLECT })
            refresh()
        end
        local function clickRow(kind)
            local rows = ns.BuffList.Rows()
            for i, offer in ipairs(ns.BuffList.ShownOffers()) do
                if ns.BuffButton.OfferKind(offer) == kind then rows[i].scripts.OnClick(rows[i]) end
            end
        end

        it("a clicked row of your own group buff doesn't carry over to a weapon buff ahead of a favour", function()
            priest()
            assert.are.equal("/cast [@player,nodead] Power Word: Fortitude", macro())
            clickRow("other")
            press()
            assert.are.equal("/use item:20749\n/use 16", macro(), "your Fortitude is on: the oil is next")
            strangerBuffs()
            assert.is_truthy(macro():find("/targetexact Bob Stone", 1, true), "the favour comes first")
        end)

        it("a clicked weapon row doesn't let your own group buff ahead of a favour", function()
            boot({ class = "PRIEST", known = { FORT }, before = function(s)
                s.playerAuras = {}
            end })
            wow.gainBuff({ spellId = FORT, sourceUnit = "player", duration = 3600, expirationTime = wow.now + 3600 })
            refresh()
            assert.are.equal("/use item:20749\n/use 16", macro())
            clickRow("weapon")
            -- Your Fortitude goes: your own copy is offered, then a stranger's favour comes in.
            wow.state.playerAuras = {}
            strangerBuffs()
            assert.is_truthy(macro():find("/targetexact Bob Stone", 1, true), "the favour comes first")
        end)

        it("says on the tooltip what the press does, and what a right-click does", function()
            boot()
            wow.run(button, "OnEnter")
            local text = table.concat(_G.GameTooltip.lines or {}, "\n")
            assert.matches("Puts Brilliant Wizard Oil on your main hand.", text, 1, true)
            assert.matches("Right-click to skip your weapon buffs for 5 minutes.", text, 1, true)
            assert.is_nil(text:find("Casts", 1, true))
        end)

        it("says each reason once in debug while it holds, however often buff mode asks", function()
            boot({ class = "ROGUE", main = "instantPoison", offHand = "deadlyPoison",
                items = { [W.instantPoison6] = 2, [W.deadlyPoison5] = 1 },
                before = function(s) s.equipped[17] = wow.GEAR.dagger end })
            local said = 0
            local log = ns.Diag.Log
            ns.Diag.Log = function(category, fmt, ...)
                if string.format(fmt, ...):find("no Deadly Poison in your bags", 1, true) then said = said + 1 end
                return log(category, fmt, ...)
            end
            wow.state.items[W.deadlyPoison5] = 0
            for _ = 1, 10 do
                refresh()
                ns.WeaponBuffs.Next()
                wow.advance(5)
            end
            assert.are.equal(1, said)
        end)
    end)

    describe("an update that adds WeaponBuffs.lua (black)", function()
        it("asks for a restart, not erroring, after only a /reload", function()
            wow.reset()
            local loaded = {}
            local _, files = wow.parseToc()
            for _, file in ipairs(files) do
                if file ~= "WeaponBuffs.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
            end
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            wow.fire("PLAYER_ENTERING_WORLD", true, false)
            wow.advance(20)
            assert.are.same({}, wow.errors)
            assert.truthy(table.concat(wow.printed, "\n"):find("Restart the game (not /reload)", 1, true))
        end)
    end)

    describe("buff mode's turn-on and turn-off (white)", function()
        local FORT = 10938

        it("a missing weapon buff alone doesn't turn buff mode on, but \"everyone has your buffs\" waits for it", function()
            boot({ auto = true, noMode = true, class = "PRIEST", known = { FORT } })
            wow.gainBuff({ spellId = FORT, sourceUnit = "player", duration = 3600, expirationTime = wow.now + 3600 })
            wow.setGroup("party", { "Ann-Vale" })
            wow.wearBuff("party1", FORT, { source = "player" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(30)
            assert.is_false(ns.BuffMode.IsOn(), "nobody needs a buff: the oil alone doesn't turn it on")
            -- Ann loses Fortitude: buff mode comes on for her.
            wow.state.units.party1.auras = {}
            ns.db.buffBack.autoOnMissing = true
            wow.advance(30)
            assert.is_true(ns.BuffMode.IsAuto(), "Ann is missing Fortitude")
            press()
            wow.wearBuff("party1", FORT, { source = "player" })
            refresh()
            assert.is_true(ns.BuffMode.IsOn(), "still on: your main hand has no oil")
            assert.are.equal("/use item:20749\n/use 16", macro())
            press()
            refresh()
            assert.is_false(ns.BuffMode.IsOn())
        end)
    end)

    describe("settings (white)", function()
        it("are off by default, with nothing chosen, and offer nothing", function()
            boot({ db = {} })
            assert.is_false(ns.db.buffBack.weaponBuffs)
            assert.are.equal("none", ns.db.buffBack.weaponMain)
            assert.are.equal("none", ns.db.buffBack.weaponOff)
            assert.is_nil(macro())
        end)

        it("load from a profile saved before weapon buffs, with the defaults", function()
            boot({ db = { buffBack = { selfBuffs = true, groupVersions = false } } })
            assert.is_false(ns.db.buffBack.weaponBuffs)
            assert.are.equal("none", ns.db.buffBack.weaponMain)
            assert.is_false(ns.db.buffBack.groupVersions)
        end)

        it("are set by the Weapon buffs page's checkbox and dropdowns", function()
            boot({ db = {}, class = "ROGUE" })
            local w = ns.Options.widgets.weapon
            w.enabled:SetChecked(true)
            wow.run(w.enabled, "OnClick", "LeftButton")
            assert.is_true(ns.db.buffBack.weaponBuffs)
            w.enabled:SetChecked(false)
            wow.run(w.enabled, "OnClick", "LeftButton")
            assert.is_false(ns.db.buffBack.weaponBuffs)
            local function pick(dd, value)
                for _, row in ipairs(dd.rows) do
                    if row.value == value then wow.run(row, "OnClick", "LeftButton") end
                end
            end
            pick(w.main, "deadlyPoison")
            assert.are.equal("deadlyPoison", ns.db.buffBack.weaponMain)
            pick(w.off, "instantPoison")
            assert.are.equal("instantPoison", ns.db.buffBack.weaponOff)
        end)

        it("list only the kinds your class can use, imbues on the main hand only", function()
            local function values(dd)
                local out = {}
                for _, row in ipairs(dd.rows) do out[row.value] = true end
                return out
            end
            boot({ db = {}, class = "MAGE" })
            local mage = values(ns.Options.widgets.weapon.main)
            assert.is_true(mage.none and mage.wizardOil and mage.sharpening)
            assert.is_nil(mage.instantPoison)
            assert.is_nil(mage.rockbiter)
            boot({ db = {}, class = "SHAMAN" })
            assert.is_true(values(ns.Options.widgets.weapon.main).windfury)
            assert.is_nil(values(ns.Options.widgets.weapon.off).windfury)
            assert.is_nil(values(ns.Options.widgets.weapon.main).deadlyPoison)
        end)

        it("ignore a kind your class can't use", function()
            boot({ main = "instantPoison", items = { [W.instantPoison6] = 1 } })
            assert.is_nil(macro())
        end)
    end)

    describe("when it can't read or can't do it (black)", function()
        local function reasonShown(text)
            refresh()
            assert.is_nil(macro())
            assert.matches("Weapons: " .. text, subtitle(), 1, true)
        end

        it("offers nothing and says why when the enchants can't be read", function()
            for name, change in pairs({
                missing = function() _G.GetWeaponEnchantInfo = nil end,
                ["an error"] = function() wow.state.weaponSecrets.error = true end,
                secret = function() wow.state.weaponSecrets.enchants = true end,
                junk = function() _G.GetWeaponEnchantInfo = function() return "no" end end,
            }) do
                boot()
                change()
                refresh()
                assert.is_nil(macro(), name)
                assert.matches("can't read your", subtitle(), 1, true)
            end
        end)

        it("offers nothing when the weapon's enchant flag is a secret or not a yes or no", function()
            boot()
            _G.GetWeaponEnchantInfo = function() return nil end
            reasonShown("can't read your main hand's enchant")
        end)

        it("offers nothing when your bags can't be counted, are empty or the item can't be used yet", function()
            boot({ before = function(s) s.itemsSecret = true end })
            reasonShown("can't count your Wizard oil")
            boot({ items = {} })
            reasonShown("no Wizard oil in your bags")
            boot({ items = { [W.brilliantWizardOil] = 1 },
                before = function(s) s.unusableItems[W.brilliantWizardOil] = true end })
            reasonShown("can't use Brilliant Wizard Oil yet")
        end)

        it("offers the next one you can use when the best can't be used yet", function()
            boot({ before = function(s) s.unusableItems[W.brilliantWizardOil] = true end })
            assert.are.equal("/use item:20746\n/use 16", macro())
        end)

        it("leaves a hand with no weapon, a shield or a held item alone, silently", function()
            for _, worn in ipairs({ false, wow.GEAR.shield, wow.GEAR.heldItem }) do
                boot({ offHand = "wizardOil", before = function(s)
                    s.weaponEnchants[16] = { id = 19, expires = 1e9, charges = 0 }
                    s.equipped[17] = worn or nil
                end })
                assert.is_nil(macro())
                assert.is_nil(subtitle():find("Weapons:", 1, true))
            end
        end)

        it("can't tell what's in the hand: offers nothing", function()
            boot({ before = function(s) s.weaponSecrets.equipped = true end })
            reasonShown("can't tell what's in your main hand")
            boot({ before = function(s) s.weaponSecrets.itemInfo = true end })
            reasonShown("can't tell what's in your main hand")
        end)

        it("leaves a weapon with its own Use for you to do by hand", function()
            boot({ before = function(s) s.equipped[16] = wow.GEAR.useSword end })
            reasonShown("your main hand weapon has its own Use: apply your Wizard oil by hand")
            boot({ before = function(s) s.weaponSecrets.itemSpell = true end })
            reasonShown("can't tell whether your main hand weapon has a Use")
        end)

        it("offers nothing in combat, dead, mounted or on a flight path", function()
            for _, case in ipairs({
                { function(s) s.units.player.dead = true end, "you're dead" },
                { function(s) s.mounted = true end, "you're mounted" },
                { function(s) s.onTaxi = true end, "you're on a flight path" },
            }) do
                boot({ before = case[1] })
                reasonShown(case[2])
            end
            boot()
            wow.enterCombat()
            refresh()
            assert.is_nil(macro())
            wow.leaveCombat()
            refresh()
            assert.are.equal("/use item:20749\n/use 16", macro())
        end)

        it("in a form, offers it anyway: the game may drop the form to put it on, or refuse", function()
            local function druid(unshift)
                boot({ class = "DRUID", before = function(s)
                    s.form = 3
                    s.cvars.autoUnshift = unshift
                end })
            end
            -- The game's own unshift: out of the form, and on it goes.
            druid("1")
            assert.are.equal("/use item:20749\n/use 16", macro())
            press()
            assert.are.equal(0, wow.state.form)
            assert.are.equal(1, wow.formsCancelled, "the game did it, not the macro")
            assert.are.equal(1, #wow.applied)
            -- The game refuses instead: its reason, the form kept, that hand held back.
            druid("0")
            assert.are.equal("/use item:20749\n/use 16", macro())
            press()
            assert.are.equal(3, wow.state.form, "still in the form")
            assert.are.equal(0, #wow.applied)
            assert.matches(wow.SHAPESHIFT_ERROR, button.result:GetText(), 1, true)
            wow.advance(ns.WeaponBuffs.HELD_BACK_SECONDS + 1)
            refresh()
            assert.are.equal("/use item:20749\n/use 16", macro())
        end)

        it("a shaman in Ghost Wolf is offered the imbue too", function()
            boot({ class = "SHAMAN", main = "windfury", known = { WINDFURY_4 },
                before = function(s) s.form = 1 end })
            assert.are.equal("/cast [@player,nodead] Windfury Weapon\n/use 16", macro())
        end)

        it("reports a refusal and holds that hand back for a moment", function()
            boot({ before = function(s) s.weaponRefusal = "Item can't be enchanted." end })
            press()
            assert.matches("Item can't be enchanted.", button.result:GetText(), 1, true)
            reasonShown("the game refused your last Wizard oil on your main hand")
            wow.state.weaponRefusal = nil
            wow.advance(ns.WeaponBuffs.HELD_BACK_SECONDS + 1)
            refresh()
            assert.are.equal("/use item:20749\n/use 16", macro())
        end)

        it("can't tell whether you can use the item: offers nothing", function()
            boot({ before = function(s) s.weaponSecrets.usable = true end })
            reasonShown("can't tell whether you can use Brilliant Wizard Oil")
        end)

        it("a shaman who doesn't know the imbue, or can't cast it now, is told why", function()
            boot({ class = "SHAMAN", main = "rockbiter" })
            reasonShown("you don't know Rockbiter Weapon")
            boot({ class = "SHAMAN", main = "rockbiter", known = { ROCKBITER_4 },
                before = function(s) s.unusable["Rockbiter Weapon"] = "power" end })
            reasonShown("not enough mana for Rockbiter Weapon now")
            boot({ class = "SHAMAN", main = "rockbiter", known = { ROCKBITER_4 },
                before = function(s) s.unusable["Rockbiter Weapon"] = "other" end })
            reasonShown("can't cast Rockbiter Weapon now")
            boot({ class = "SHAMAN", main = "rockbiter", known = { ROCKBITER_4 },
                before = function(s) s.selfSecrets.usable = true end })
            reasonShown("can't tell whether Rockbiter Weapon can be cast now")
        end)

        it("counts a hand as done for a moment after it lands, while the game catches up", function()
            boot()
            press()
            -- The game doesn't show it yet.
            wow.state.weaponEnchants[16] = nil
            refresh()
            assert.is_nil(macro())
            wow.advance(ns.WeaponBuffs.JUST_GIVEN_SECONDS + 1)
            refresh()
            assert.are.equal("/use item:20749\n/use 16", macro())
        end)

        it("isn't answered by another spell cast meanwhile", function()
            boot({ before = function(s) s.castLatency = 2 end })
            press()
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-other", 10157)
            assert.is_nil((button.result:GetText() or ""):find("Applied", 1, true))
            wow.advance(2)
            assert.matches("Applied Brilliant Wizard Oil to your main hand.", button.result:GetText(), 1, true)
        end)

        it("says so when a press puts nothing on, and holds that hand back", function()
            boot({ before = function(s) s.useDoesNothing = true end })
            press()
            wow.advance(ns.BuffButton.ANSWER_WINDOW_SECONDS + 1)
            assert.matches("No answer: nothing was put on your main hand.", button.result:GetText(), 1, true)
            assert.are.equal(0, #wow.weaponUses)
            reasonShown("the game refused your last Wizard oil on your main hand")
        end)

        it("never puts an imbue on the off hand", function()
            boot({ class = "SHAMAN", main = "none", offHand = "windfury", known = { WINDFURY_4 },
                before = function(s) s.equipped[17] = wow.GEAR.dagger end })
            assert.is_nil(macro())
            assert.is_nil(ns.WeaponBuffs.Next(), "not even an offer the macro would refuse")
        end)

        it("offers nothing in combat, even when asked outside the button", function()
            boot()
            wow.enterCombat()
            local offer, why = ns.WeaponBuffs.Next()
            assert.is_nil(offer)
            assert.are.equal("in combat", why)
        end)

        it("offers nothing when whether you're dead can't be read", function()
            boot()
            _G.UnitIsDeadOrGhost = function() return wow.secret(false) end
            reasonShown("can't tell whether you're dead")
        end)

        it("offers nothing when the client can't say what you wear or whether it has a Use", function()
            boot()
            _G.GetInventoryItemID = nil
            reasonShown("can't tell what's in your main hand")
            boot()
            _G.GetItemSpell, _G.C_Item.GetItemSpell = nil, nil
            reasonShown("can't tell whether your main hand weapon has a Use")
        end)

        it("offers nothing when your bags give a count that isn't a number", function()
            for _, junk in ipairs({ "lots", 0 / 0 }) do
                boot()
                _G.C_Item.GetItemCount = function() return junk end
                _G.GetItemCount = _G.C_Item.GetItemCount
                reasonShown("can't count your Wizard oil")
            end
        end)

        it("isn't answered by another spell sent and landing while it waits unsent", function()
            boot({ before = function(s) s.useDoesNothing = true end })
            press()
            wow.fire("UNIT_SPELLCAST_SENT", "player", "Bob", "Cast-x", 10157)
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-x", 10157)
            assert.is_nil((button.result:GetText() or ""):find("Applied", 1, true))
        end)

        it("leaves a stone the game keeps refusing for that weapon alone a while, or until the weapon changes", function()
            boot({ main = "sharpening", items = { [W.denseSharpeningStone] = 5 },
                before = function(s) s.equipped[16] = wow.GEAR.mace end })
            assert.are.equal("/use item:12404\n/use 16", macro())
            press()
            assert.matches(wow.WRONG_WEAPON_ERROR, button.result:GetText(), 1, true)
            wow.advance(ns.WeaponBuffs.HELD_BACK_SECONDS + 1)
            refresh()
            press()
            wow.advance(ns.WeaponBuffs.HELD_BACK_SECONDS + 1)
            reasonShown("the game refused your Sharpening stone on your main hand weapon twice")
            local _, _, settled = ns.WeaponBuffs.Next()
            assert.is_true(settled, "nothing left to do: buff mode may end")
            wow.advance(ns.WeaponBuffs.STOP_SECONDS - 30)
            refresh()
            assert.is_nil(macro(), "still left alone")
            -- Then tried once more: refused again, and left alone again.
            wow.advance(60)
            refresh()
            assert.are.equal("/use item:12404\n/use 16", macro())
            press()
            refresh()
            assert.is_nil(macro())
            -- A blade in hand: offered again at once.
            wow.state.equipped[16] = wow.GEAR.sword
            refresh()
            assert.are.equal("/use item:12404\n/use 16", macro())
            press()
            assert.are.equal(1643, wow.enchantOn(16).id)
        end)

        it("forgets a refusal that passed: one put on by hand in between, or after a while", function()
            boot({ main = "instantPoison", class = "ROGUE", items = { [W.instantPoison6] = 5 } })
            wow.state.weaponRefusal = "You can't do that while moving."
            press()
            -- Put on by hand meanwhile; hours later it runs out, and you're moving again.
            wow.enchant(16, 625, 1800)
            refresh()
            wow.advance(7200)
            refresh()
            press()
            wow.state.weaponRefusal = nil
            wow.advance(ns.WeaponBuffs.HELD_BACK_SECONDS + 1)
            refresh()
            assert.are.equal("/use item:8928\n/use 16", macro(), "one refusal in a row, not two")
            -- Twice in a row now: left alone, but only for a while.
            wow.state.weaponRefusal = "You can't do that while moving."
            press()
            wow.state.weaponRefusal = nil
            wow.advance(ns.WeaponBuffs.HELD_BACK_SECONDS + 1)
            refresh()
            assert.is_nil(macro())
            local _, _, settled = ns.WeaponBuffs.Next()
            assert.is_true(settled)
            wow.advance(ns.WeaponBuffs.STOP_SECONDS)
            refresh()
            assert.are.equal("/use item:8928\n/use 16", macro())
        end)

        it("counts refusals in a row for one weapon and kind only", function()
            boot({ main = "sharpening", items = { [W.denseSharpeningStone] = 5, [W.brilliantWizardOil] = 5 },
                before = function(s) s.equipped[16] = wow.GEAR.mace end })
            press() -- a sharpening stone on a mace: refused once
            ns.db.buffBack.weaponMain = "wizardOil"
            wow.state.weaponRefusal = "Can't do that right now."
            wow.advance(ns.WeaponBuffs.HELD_BACK_SECONDS + 1)
            refresh()
            press() -- the oil, refused once too: not twice for the same kind
            wow.state.weaponRefusal = nil
            wow.advance(ns.WeaponBuffs.HELD_BACK_SECONDS + 1)
            refresh()
            assert.are.equal("/use item:20749\n/use 16", macro())
        end)

        it("forgets the refusals when the kind changes", function()
            boot({ main = "sharpening", items = { [W.denseSharpeningStone] = 5, [W.denseWeightstone] = 5 },
                before = function(s) s.equipped[16] = wow.GEAR.mace end })
            for _ = 1, 2 do
                press()
                wow.advance(ns.WeaponBuffs.HELD_BACK_SECONDS + 1)
                refresh()
            end
            assert.is_nil(macro())
            ns.db.buffBack.weaponMain = "weightstone"
            refresh()
            assert.are.equal("/use item:12643\n/use 16", macro())
        end)

        it("reads damaged saved settings as off and none, and heals them", function()
            boot({ db = { buffBack = { weaponBuffs = "yes", weaponMain = 42, weaponOff = "everything" } } })
            assert.is_false(ns.db.buffBack.weaponBuffs)
            assert.are.equal("none", ns.db.buffBack.weaponMain)
            assert.are.equal("none", ns.db.buffBack.weaponOff)
            boot()
            ns.db.buffBack.weaponMain = {}
            refresh()
            assert.is_nil(macro())
            boot()
            ns.db.buffBack.weaponBuffs = "yes"
            refresh()
            assert.is_nil(macro(), "only true is on")
            ns.db.buffBack = nil
            assert.has_no.errors(refresh)
        end)

        it("never builds a macro for an unlisted item, another slot or an unsafe name", function()
            boot()
            local Macro = ns.WeaponBuffs.Macro
            assert.is_nil(Macro({ weapon = true, slot = 16, item = 6948 }), "a hearthstone")
            assert.is_nil(Macro({ weapon = true, slot = 18, item = 20749 }))
            assert.is_nil(Macro({ weapon = true, slot = 16, item = 20749.5 }))
            assert.is_nil(Macro({ weapon = true, slot = 16, item = wow.secret(20749) }))
            assert.is_nil(Macro({ weapon = true, slot = 17, castName = "Rockbiter Weapon" }))
            assert.is_nil(Macro({ weapon = true, slot = 16, castName = "Rockbiter\n/cast Hearthstone" }))
            assert.is_nil(Macro({ weapon = true, slot = 16, castName = "Rock;biter" }))
            assert.are.equal("/use item:20749\n/use 17", Macro({ weapon = true, slot = 17, item = 20749 }))
            assert.is_nil(Macro({ slot = 16, item = 20749 }), "not a weapon offer")
        end)
    end)

    describe("a chaos storm (red)", function()
        local SEEDS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 }
        local ITEMS = { W.brilliantWizardOil, W.lesserWizardOil, W.roughWeightstone, W.denseWeightstone,
            W.denseSharpeningStone, W.instantPoison6, W.deadlyPoison5 }
        local KINDS = { "none", "wizardOil", "weightstone", "sharpening", "instantPoison", "deadlyPoison",
            "rockbiter", "windfury", 42, {} }
        local GEAR = { false, wow.GEAR.sword, wow.GEAR.mace, wow.GEAR.dagger, wow.GEAR.useSword,
            wow.GEAR.shield, wow.GEAR.heldItem }

        -- What the client's own state says a weapon macro may be: computed
        -- from the client, never from the addon.
        local checked, applied = 0, 0 -- across the storms, so they're known to reach weapon buffs
        local function checkMacro(text, seed, step)
            checked = checked + 1
            local where = string.format("seed %d step %d: %s", seed, step, tostring(text))
            assert.is_false(wow.state.inCombat and true or false, where)
            local item, slot = text:match("^/use item:(%d+)\n/use (%d+)$")
            local name = text:match("^/cast %[@player,nodead%] ([^\n]+)\n/use 16$")
            assert.is_true(item ~= nil or name ~= nil, where)
            -- The macro never cancels a form itself (the owner, #45): one line, or the two /use lines.
            assert.is_nil(text:lower():find("cancel", 1, true), where)
            if name then assert.is_nil(name:find("\n", 1, true), where) end
            slot = tonumber(slot) or 16
            assert.is_nil(wow.enchantOn(slot), where .. ": the hand already has an enchant")
            local worn = wow.state.equipped[slot]
            local info = worn and wow.GEAR_INFO[worn]
            assert.is_true(info ~= nil and info.class == 2, where .. ": no weapon there")
            if item then
                assert.is_true((wow.state.items[tonumber(item)] or 0) > 0, where .. ": not carried")
                assert.is_nil(info.use, where .. ": the weapon has its own Use")
                assert.is_nil(wow.state.unusableItems[tonumber(item)], where)
                assert.is_true(wow.WEAPON_ITEMS[tonumber(item)] ~= nil, where .. ": not a weapon item")
            else
                assert.is_nil(info.use, where .. ": the weapon has its own Use")
                assert.are.equal("SHAMAN", wow.state.class, where)
                assert.are.equal(16, slot, where)
            end
        end

        for _, seed in ipairs(SEEDS) do
            it("never errors, never fires a weapon's Use, and only offers what fits (seed "
                .. seed .. ")", function()
                random.seed(seed)
                local function int(m, n) return random.random(m, n) end
                local class = ({ "MAGE", "ROGUE", "SHAMAN", "DRUID" })[int(1, 4)]
                -- Mostly kinds your class can use, sometimes any, or junk.
                local FITS = { MAGE = { "wizardOil", "weightstone", "sharpening" },
                    ROGUE = { "instantPoison", "deadlyPoison", "sharpening" },
                    SHAMAN = { "rockbiter", "windfury", "weightstone" }, DRUID = { "wizardOil", "weightstone" } }
                local function kind()
                    if int(1, 5) > 1 then return FITS[class][int(1, #FITS[class])] end
                    return KINDS[int(1, #KINDS)]
                end
                local carried = {}
                for _, item in ipairs(ITEMS) do carried[item] = 2 end
                boot({ class = class, main = kind(), offHand = kind(), items = carried,
                    known = { ROCKBITER_4, ROCKBITER_1, WINDFURY_4 },
                    before = function(st) st.equipped[17] = wow.GEAR.dagger end })
                for step = 1, 150 do
                    local roll = int(1, 24)
                    local s = wow.state
                    if roll == 1 then
                        s.items[ITEMS[int(1, #ITEMS)]] = int(0, 2)
                    elseif roll == 2 then
                        local slot = int(16, 17)
                        if int(1, 2) == 1 then s.weaponEnchants[slot] = nil else wow.enchant(slot, 19, int(1, 60)) end
                    elseif roll == 3 then
                        s.equipped[int(16, 17)] = GEAR[int(1, #GEAR)] or nil
                    elseif roll == 4 then
                        local field = ({ "enchants", "equipped", "itemInfo", "itemSpell", "usable", "error" })[int(1, 6)]
                        s.weaponSecrets[field] = not s.weaponSecrets[field] or nil
                    elseif roll == 5 then
                        if s.inCombat then wow.leaveCombat() else wow.enterCombat() end
                    elseif roll == 6 then
                        s.form = int(0, 1) * int(1, 4)
                        s.cvars.autoUnshift = ({ "0", "1", nil })[int(1, 3)]
                    elseif roll == 7 then
                        ns.db.buffBack[({ "weaponMain", "weaponOff" })[int(1, 2)]] = kind()
                    elseif roll == 8 then
                        ns.db.buffBack.weaponBuffs = ({ true, true, false, "junk" })[int(1, 4)]
                    elseif roll == 9 then
                        s.unusableItems[ITEMS[int(1, #ITEMS)]] = int(1, 2) == 1 or nil
                    elseif roll == 10 then
                        s.itemsSecret = int(1, 4) == 1
                    elseif roll == 11 then
                        s.weaponRefusal = int(1, 3) == 1 and "Item can't be enchanted." or nil
                    elseif roll == 12 then
                        s.castLatency = int(0, 2)
                        s.imbuePicks = int(1, 2) == 1
                    elseif roll == 13 then
                        -- The storm calms: back to a state where a weapon buff fits.
                        s.weaponSecrets, s.itemsSecret, s.weaponRefusal = {}, false, nil
                        if s.inCombat then wow.leaveCombat() end
                        ns.db.buffBack.weaponBuffs = true
                        for _, item in ipairs(ITEMS) do s.items[item] = 2 end
                    elseif roll <= 19 then
                        wow.pressKey("MOUSEWHEELUP")
                    elseif roll == 20 then
                        wow.press(button, "RightButton")
                    else
                        wow.advance(int(1, 400))
                    end
                    refresh()
                    -- The button re-arms as a press begins: check what it holds then.
                    local text = macro()
                    if text and (text:find("^/use ") or text:find("Weapon\n/use 16$")) then checkMacro(text, seed, step) end
                    assert.are.equal(0, #wow.weaponUses, "seed " .. seed .. ": a weapon's own Use fired")
                end
                applied = applied + #wow.applied
            end)
        end

        it("the storms armed and put on weapon buffs, so they test something", function()
            assert.is_true(checked > 100, "macros checked: " .. checked)
            assert.is_true(applied > 10, "weapon buffs put on: " .. applied)
        end)
    end)
end)
