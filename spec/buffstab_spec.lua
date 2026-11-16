-- Spec: #408
-- The Buffs tab (#408): the buff order and options for every place, then a
-- sub-tab for each place (Buff Back, Party, Raid, PvP) with a "who gets it"
-- row per buff, its list of ticks, its Always and Never names, and the
-- place's own options. Before the choice, the rules in force show greyed
-- behind "Keep my settings" and "Use the new defaults".
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1, THORNS_1 = 9885, 1126, 467
local KINGS, MIGHT_1, WISDOM_1 = 20217, 19740, 19742

describe("The Buffs tab (#408)", function()
    local ns, w

    -- A druid who knows Mark of the Wild and Thorns, the panel open on the
    -- Buffs tab. choice: made at once, or left pending.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, buffDefaults = true, newInstall = opts.newInstall,
            before = function(state)
                state.class = opts.class or "DRUID"
                state.knownSpells = opts.known or { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
            end })
        w = ns.Options.widgets
        if opts.choice then assert.is_true(ns.BuffRules.Choose(opts.choice)) end
        ns.Options.Open()
        wow.run(w.tabs.buffs, "OnClick")
    end

    local function place(p) wow.run(w.placeTabs[p], "OnClick") end

    local function said(fragment)
        for _, line in ipairs(wow.printed) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end

    -- The who-gets rows shown: { name, button text }.
    local function whoRows()
        local out = {}
        for _, row in ipairs(w.whoRows) do
            if row.who:IsVisible() then out[#out + 1] = { row.name:GetText(), row.who:GetText() } end
        end
        return out
    end

    local function rowFor(key)
        for _, row in ipairs(w.whoRows) do
            if row.key == key and row.who:IsVisible() then return row end
        end
    end

    local function tick(box, on)
        box:SetChecked(on)
        wow.run(box, "OnClick")
    end

    describe("the tab (white)", function()
        it("shows the order with icons, Up, Down and Never offer, the buff options, the intro and four places", function()
            boot()
            assert.are.equal("buffs", ns.Options.CurrentType())
            assert.is_false(w.msgHeader:IsVisible(), "no message rows")
            assert.is_false(w.enabled:IsVisible())
            assert.is_true(w.buffsHelp:IsVisible())
            assert.is_truthy(w.buffsHelp:GetText():find("buff back (strangers who buff you) and for buff mode", 1, true))
            local rows = {}
            for _, row in ipairs(w.buffRows) do
                if row.name:IsVisible() then
                    rows[#rows + 1] = row.name:GetText()
                    assert.is_truthy(row.icon.texture, "an icon by " .. row.name:GetText())
                    assert.is_true(row.up:IsVisible() and row.down:IsVisible() and row.never:IsVisible())
                    assert.is_truthy(row.never.tooltip, "Never offer has a tooltip")
                end
            end
            assert.are.same({ "1. Mark of the Wild", "2. Thorns" }, rows)
            for _, cb in ipairs({ w.selfBuffs, w.breathNearWater, w.groupVersions }) do
                assert.is_true(cb:IsVisible())
                assert.is_truthy(cb.tooltip)
            end
            for _, p in ipairs({ "strangers", "party", "raid", "pvp" }) do assert.is_true(w.placeTabs[p]:IsVisible()) end
            assert.are.equal("Buff Back", w.placeTabs.strangers:GetText())
            assert.is_false(w.placeTabs.party:IsEnabled(), "Party is shown first")
        end)

        it("a change saves at once and changes the next offer", function()
            boot({ choice = "new" })
            wow.run(w.buffRows[1].down, "OnClick")
            assert.are.same({ "thorns", "motw" }, ns.db.buffBack.buffOrder)
            tick(w.buffRows[1].never, true)
            assert.is_true(ns.db.buffBack.neverOffer.thorns)
            tick(w.groupVersions, false)
            assert.is_false(ns.db.buffBack.groupVersions)
            -- Who gets it: Mark of the Wild to healers only in a party.
            wow.setGroup("party", { "Ann-Vale", "Eve-Moss" })
            wow.state.units.party1.class, wow.state.units.party1.role = "WARRIOR", "TANK"
            wow.state.units.party2.class, wow.state.units.party2.role = "PRIEST", "HEALER"
            wow.fire("GROUP_ROSTER_UPDATE")
            _G.SlashCmdList.FRIENDLYFOREVER("buffmode on")
            local row = rowFor("motw")
            wow.run(row.who, "OnClick")
            assert.is_true(w.whoList:IsShown())
            tick(w.whoList.healers, true)
            assert.are.same({ healers = true }, ns.db.buffBack.whoParty.motw)
            assert.are.equal("Healers", row.who:GetText())
            local macro = ns.BuffButton.Frame():GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
            assert.is_truthy(macro and macro:find("/targetexact Eve Moss", 1, true), macro)
        end)

        it("the list's ticks: Everyone clears the others, a role or class clears Everyone, Off clears all", function()
            boot({ choice = "new" })
            local row = rowFor("thorns")
            assert.are.equal("Tanks", row.who:GetText(), "Thorns starts at its Party default")
            wow.run(row.who, "OnClick")
            assert.is_true(w.whoList.tanks:GetChecked())
            tick(w.whoList.classes.MAGE, true)
            assert.are.equal("Tanks, Mage", row.who:GetText())
            assert.is_truthy(row.who.tooltip:find("Tanks, Mage", 1, true))
            tick(w.whoList.everyone, true)
            assert.are.equal("Everyone", row.who:GetText())
            assert.is_false(w.whoList.tanks:GetChecked())
            assert.is_false(w.whoList.classes.MAGE:GetChecked())
            tick(w.whoList.damage, true)
            assert.are.equal("Damage", row.who:GetText())
            assert.is_false(w.whoList.everyone:GetChecked())
            for _, class in ipairs({ "WARRIOR", "ROGUE", "HUNTER", "PALADIN" }) do tick(w.whoList.classes[class], true) end
            assert.are.equal("1 role, 4 classes", row.who:GetText(), "a summary too long to show is counted")
            assert.is_truthy(row.who.tooltip:find("Damage, Warrior, Paladin, Hunter, Rogue", 1, true))
            wow.run(w.whoList.off, "OnClick")
            assert.are.equal("Off", row.who:GetText())
            assert.are.same({}, ns.db.buffBack.whoParty.thorns)
            -- A click anywhere else closes the list.
            wow.run(w.whoList.catcher, "OnClick")
            assert.is_false(w.whoList:IsShown())
        end)

        it("Buff Back's list has Everyone, classes and Off only, and no names", function()
            boot({ choice = "new" })
            place("strangers")
            local row = rowFor("motw")
            assert.is_false(row.names:IsVisible())
            wow.run(row.who, "OnClick")
            assert.is_true(w.whoList.everyone:IsVisible())
            assert.is_true(w.whoList.classes.MAGE:IsVisible())
            assert.is_false(w.whoList.tanks:IsVisible())
            assert.is_false(w.whoList.healers:IsVisible())
            tick(w.whoList.classes.MAGE, true)
            assert.are.same({ classes = { MAGE = true } }, ns.db.buffBack.whoStrangers.motw)
            assert.is_true(w.openBuffBack:IsVisible(), "a link to buff back's own settings")
            wow.run(w.openBuffBack, "OnClick")
            assert.are.equal("buffBack", ns.Options.CurrentType())
        end)

        it("Names opens a buff's Always and Never boxes under its row, and they save to that buff and place", function()
            boot({ choice = "new" })
            place("raid")
            local row = rowFor("thorns")
            assert.are.equal("Names (0)", row.names:GetText())
            assert.is_false(w.who.always:IsVisible())
            wow.run(row.names, "OnClick")
            assert.is_true(w.who.always:IsVisible())
            assert.are.equal(row.icon, select(2, w.who.alwaysLabel:GetPoint()), "under its row")
            w.who.never:SetFocus()
            w.who.never:SetText("Ann Vale, Cid Rock")
            w.who.never:ClearFocus()
            assert.are.same({ ["ann-vale"] = "Ann-Vale", ["cid-rock"] = "Cid-Rock" }, ns.db.buffBack.whoRaid.thorns.never)
            assert.are.equal("Names (2)", row.names:GetText())
            assert.is_nil(ns.db.buffBack.whoParty.thorns, "Party's rule is its own")
            wow.run(row.names, "OnClick")
            assert.is_false(w.who.always:IsVisible(), "Names again closes them")
        end)

        it("a box saves to the buff and place it was typed for, even if another is chosen meanwhile", function()
            boot({ choice = "new" })
            wow.run(rowFor("motw").names, "OnClick")
            w.who.always:SetFocus()
            w.who.always:SetText("Ann Vale")
            wow.run(rowFor("thorns").names, "OnClick") -- Thorns' boxes, mid-edit
            assert.are.equal("Ann Vale", ns.BuffRules.NamesText("motw", "always", "party"))
            assert.are.equal("", ns.BuffRules.NamesText("thorns", "always", "party"))
            assert.are.equal("", w.who.always:GetText(), "now showing Thorns' list")
            -- And when the place changes mid-edit.
            w.who.never:SetFocus()
            w.who.never:SetText("Cid Rock")
            place("pvp")
            assert.are.equal("Cid Rock", ns.BuffRules.NamesText("thorns", "never", "party"))
            assert.are.equal("", ns.BuffRules.NamesText("thorns", "never", "pvp"))
        end)

        it("each place has its own options: solo in Party, the split and Blessings in Raid, the gates in PvP", function()
            boot({ class = "PALADIN", known = { [KINGS] = true, [MIGHT_1] = true, [WISDOM_1] = true } })
            assert.is_true(w.soloOwnBuffs:IsVisible())
            assert.is_false(w.raidSplit:IsVisible())
            place("raid")
            assert.is_true(w.raidSplit:IsVisible())
            assert.is_true(w.who.raidBlessings[1]:IsVisible())
            assert.is_false(w.soloOwnBuffs:IsVisible())
            place("pvp")
            assert.is_true(w.bgPrepBuff:IsVisible())
            assert.is_truthy(w.placeHelp:GetText():find("Every buff is off here unless you turn it on", 1, true))
            tick(w.bgPrepBuff, false)
            assert.is_false(ns.db.buffBack.bgPrepBuff)
            place("strangers")
            assert.is_false(w.bgPrepBuff:IsVisible())
        end)

        it("the Buff Back tab keeps its own settings, with a link to the Buffs tab", function()
            boot()
            wow.run(w.tabs.buffBack, "OnClick")
            assert.is_true(w.buffModeKey:IsVisible())
            assert.is_true(w.buffRequests:IsVisible())
            assert.is_true(w.openBuffs:IsVisible())
            assert.is_false(w.buffRows[1].name:IsVisible())
            assert.is_false(w.selfBuffs:IsVisible())
            wow.run(w.openBuffs, "OnClick")
            assert.are.equal("buffs", ns.Options.CurrentType())
        end)
    end)

    describe("before the choice (white)", function()
        it("each place shows the choice and the rules in force, greyed", function()
            boot({ db = { buffBack = { whoGets = { thorns = { rule = "notTanks" } } } } })
            for _, p in ipairs({ "party", "raid", "pvp", "strangers" }) do
                place(p)
                assert.is_true(w.choice.keep:IsVisible(), p)
                assert.is_true(w.choice.new:IsVisible(), p)
                assert.is_truthy(w.choice.newNote:GetText():find("recommended", 1, true))
                local row = rowFor("thorns")
                assert.is_false(row.who:IsEnabled(), p .. ": greyed")
                assert.are.equal(p == "strangers" and "Anyone who can use it" or "Everyone but tanks", row.who:GetText(), p)
                if p ~= "strangers" then assert.is_false(row.names:IsEnabled()) end
            end
            -- The list can't open: nothing changes the player didn't press.
            wow.run(rowFor("thorns").who, "OnClick")
            assert.is_false(w.whoList:IsShown())
        end)

        it("a choice applies at once, says so in chat, and the rows come alive", function()
            boot({ db = { buffBack = { whoGets = { thorns = { rule = "notTanks" } } } } })
            wow.run(w.choice.keep, "OnClick")
            assert.are.equal("kept", ns.db.buffBack.whoChoice)
            assert.is_true(said("kept your buff rules"))
            assert.is_false(w.choice.keep:IsVisible())
            local row = rowFor("thorns")
            assert.is_true(row.who:IsEnabled())
            assert.are.equal("Healers, Damage", row.who:GetText())
            boot()
            wow.run(w.choice.new, "OnClick")
            assert.are.equal("new", ns.db.buffBack.whoChoice)
            assert.is_true(said("using the new buff defaults"))
        end)

        it("a new install starts on the new defaults and never sees the choice", function()
            boot({ newInstall = true })
            assert.are.equal("new", ns.db.buffBack.whoChoice)
            assert.is_false(w.choice.keep:IsVisible())
            assert.is_true(rowFor("motw").who:IsEnabled())
        end)
    end)

    describe("rows that have no rule, and bad input (black)", function()
        it("a self-buff and Water Walking have no who-gets row; a buff not known yet is marked", function()
            boot({ class = "SHAMAN", known = {} })
            local order = {}
            for _, row in ipairs(w.buffRows) do
                if row.name:IsVisible() then order[row.key] = row.name:GetText() end
            end
            assert.is_truthy(order.waterwalking:find("(when asked)", 1, true))
            assert.is_truthy(order.lightningshield:find("(you only)", 1, true))
            assert.is_truthy(order.waterbreathing:find("(not known yet)", 1, true))
            local keys = {}
            for _, row in ipairs(w.whoRows) do
                if row.who:IsVisible() then keys[#keys + 1] = row.key end
            end
            assert.are.same({ "waterbreathing" }, keys)
        end)

        it("a class with no buffs says so, and has no rows", function()
            boot({ class = "ROGUE", known = {} })
            assert.are.equal("Your class has no buffs to offer.", w.buffOrderHeader:GetText())
            assert.are.same({}, whoRows())
        end)

        it("a bad name is refused with the reason, and the box shows what's kept", function()
            boot({ choice = "new" })
            wow.run(rowFor("motw").names, "OnClick")
            w.who.always:SetFocus()
            w.who.always:SetText("not a name!")
            w.who.always:ClearFocus()
            assert.is_true(said("Always list not saved"))
            assert.are.equal("", w.who.always:GetText())
        end)

        it("a box only clicked in and out saves nothing, and holds a full list of long names", function()
            boot({ choice = "new" })
            local long = ("Abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuv"):sub(1, 48)
            local names = {}
            for i = 1, ns.BuffRules.MAX_NAMES do
                names[i] = long .. "-" .. long:sub(1, 40) .. string.char(97 + i % 26) .. string.char(97 + math.floor(i / 26))
            end
            assert.is_true(ns.BuffRules.SetNames("motw", "always", table.concat(names, ","), "party"))
            local before = ns.BuffRules.NamesText("motw", "always", "party")
            wow.run(rowFor("motw").names, "OnClick")
            assert.are.equal(before, w.who.always:GetText(), "the whole list fits the box")
            local saves = 0
            local real = ns.BuffRules.SetNames
            ns.BuffRules.SetNames = function(...) saves = saves + 1; return real(...) end
            w.who.always:SetFocus()
            w.who.always:ClearFocus()
            ns.BuffRules.SetNames = real
            assert.are.equal(0, saves, "unchanged: not saved again")
        end)
    end)

    describe("damage and storms (red)", function()
        it("settings damaged while the tab is open heal as it fills", function()
            boot({ choice = "new" })
            place("raid")
            wow.run(rowFor("motw").names, "OnClick")
            for _, damage in ipairs({ 7, "x", { whoParty = 3 } }) do
                wow.advance(2)
                ns.db.buffBack = damage
                ns.Options.Refresh()
                assert.are.equal("table", type(ns.db.buffBack))
                assert.are.same({}, wow.errors)
            end
            ns.db.buffBack.whoRaid = { motw = { everyone = "y", tanks = true } }
            ns.Options.Refresh()
            assert.are.same({}, wow.errors)
        end)

        it("pressing the tab's controls in any order never raises an error", function()
            for _, seed in ipairs({ 408, 1116, 77 }) do
                random.seed(seed)
                boot({ class = "PALADIN", known = { [KINGS] = true, [MIGHT_1] = true, [WISDOM_1] = true } })
                local function any(list) return list[random.random(#list)] end
                local actions = {
                    function() place(any({ "strangers", "party", "raid", "pvp" })) end,
                    function() wow.run(any({ w.choice.keep, w.choice.new }), "OnClick") end,
                    function()
                        local row = w.whoRows[random.random(#w.whoRows)]
                        wow.run(any({ row.who, row.names }), "OnClick")
                    end,
                    function()
                        if w.whoList:IsShown() then
                            local boxes = { w.whoList.everyone, w.whoList.tanks, w.whoList.healers, w.whoList.damage,
                                w.whoList.classes.MAGE, w.whoList.classes.WARRIOR }
                            tick(any(boxes), random.random(2) == 1)
                        end
                    end,
                    function() if w.whoList:IsShown() then wow.run(w.whoList.off, "OnClick") end end,
                    function()
                        local box = any({ w.who.always, w.who.never })
                        box:SetFocus()
                        box:SetText(any({ "Ann Vale", "bad name!", "", "Cid Rock, Dot Fern" }))
                        box:ClearFocus()
                    end,
                    function()
                        local row = w.buffRows[random.random(3)]
                        wow.run(any({ row.up, row.down }), "OnClick")
                    end,
                    function() wow.run(any({ w.tabs.buffs, w.tabs.buffBack, w.tabs.buff }), "OnClick") end,
                    function() ns.db.buffBack.whoChoice = any({ "pending", "kept", 9 }) end,
                    function() wow.run(w.who.raidBlessings[1], "OnClick") end,
                }
                for _ = 1, 80 do
                    any(actions)()
                    ns.Options.Refresh()
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
        end)
    end)
end)
