-- Spec: #408, #39, #452, #491
-- The Buffs tab (#408): the buff order and options for every place, then a
-- sub-tab for each place (Strangers, Party, Raid, PvP) with a "who gets it"
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
        -- #491: the self-buff row moves only when the row above it changes, so a
        -- fill doesn't lay out every row below it again; it must still follow the
        -- buff list when that changes (the class read differently: unreadable at
        -- first, or another class).
        it("the self-buff row follows the last buff row when the class reads differently, and stays put otherwise",
            function()
                boot()
                local function anchor() return select(2, w.selfBuffs:GetPoint(1)) end
                local druid = #ns.BuffData.CLASSES.DRUID
                assert.are.equal(w.buffRows[druid].icon, anchor())
                ns.Options.Refresh()
                assert.are.equal(w.buffRows[druid].icon, anchor(), "a fill with the same rows leaves it")
                wow.state.class = "PALADIN"
                ns.Options.Refresh()
                assert.are.equal(w.buffRows[#ns.BuffData.CLASSES.PALADIN].icon, anchor(), "a paladin's longer list")
                assert.is_true(w.selfBuffs:IsVisible())
                wow.state.class = nil
                ns.Options.Refresh()
                assert.are.equal(w.buffOrderHeader, anchor(), "no class read: under the header")
                wow.state.class = "DRUID"
                ns.Options.Refresh()
                assert.are.equal(w.buffRows[druid].icon, anchor(), "and back")
            end)

        it("shows the order with icons, Up, Down and Never offer, the buff options, the intro and four places", function()
            boot()
            assert.are.equal("buffs", ns.Options.CurrentType())
            assert.is_false(w.msgHeader:IsVisible(), "no message rows")
            assert.is_false(w.enabled:IsVisible())
            assert.is_true(w.buffsHelp:IsVisible())
            assert.is_truthy(w.buffsHelp:GetText():find("strangers (who buff you, or pass by) and for buff mode", 1,
                true))
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
            for _, cb in ipairs({ w.selfBuffs, w.breathNearWater, w.fastCastInForm, w.groupVersions }) do
                assert.is_true(cb:IsVisible())
                assert.is_truthy(cb.tooltip)
            end
            -- Buff mode's rows above the places (#491).
            for _, row in ipairs({ w.buffModeHeader, w.buffModeKey, w.autoHeader, w.steppers.topUpMinutes.label }) do
                assert.is_true(row:IsVisible())
            end
            for _, p in ipairs({ "strangers", "party", "raid", "pvp" }) do assert.is_true(w.placeTabs[p]:IsVisible()) end
            assert.are.equal("Strangers", w.placeTabs.strangers:GetText())
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

        it("Strangers' list has Everyone, classes and Off only, and no names", function()
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
            assert.is_true(w.openFavours:IsVisible(), "a link to buff back's own settings")
            assert.are.equal("Open the Favours tab", w.openFavours:GetText())
            wow.run(w.openFavours, "OnClick")
            assert.are.equal(ns.Options.FAVOURS_TAB, ns.Options.CurrentType())
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

        it("the Favours tab keeps buff back's own settings, with a link to the Buffs tab", function()
            boot()
            wow.run(w.tabs.favours, "OnClick")
            assert.is_true(w.offerEnabled:IsVisible())
            assert.is_true(w.steppers.owedMinutes.box:IsVisible())
            assert.is_false(w.buffModeKey:IsVisible(), "buff mode is the Buffs tab's (#491)")
            assert.is_true(w.buffRequests:IsVisible())
            assert.is_true(w.openBuffs:IsVisible())
            assert.is_false(w.buffRows[1].name:IsVisible())
            assert.is_false(w.selfBuffs:IsVisible())
            wow.run(w.openBuffs, "OnClick")
            assert.are.equal("buffs", ns.Options.CurrentType())
        end)

        -- #408's architecture review: that tab's Reset wiped this one's.
        it("the Favours tab's Reset leaves the Buffs tab's settings as they are", function()
            boot({ choice = "new" })
            -- What the Buffs tab shows, listed here on its own: the order,
            -- Never offer, the rules (1.3.3's, the choice, each place's) and
            -- the options for every place and for each. Passers-by moved to
            -- the Favours tab, and buff mode's key, triggers and top-up to this
            -- tab (#491).
            local shown = { "buffOrder", "neverOffer", "whoGets", "whoChoice", "whoStrangers", "whoParty",
                "whoRaid", "whoPvP", "selfBuffs", "breathNearWater", "groupVersions", "groupEnough",
                "soloOwnBuffs", "raidSplit", "bgPrepBuff", "fastCastInForm", "buffModeKey", "autoOnJoin",
                "autoOnDeath", "autoOnBuffed", "autoOnMissing", "autoOnCampfire", "autoOffPull", "autoOffDone",
                "autoOffMinutes", "topUpMinutes" }
            local listed = {}
            for _, field in ipairs(ns.BuffsTab.FIELDS) do
                assert.is_not_nil(ns.Config.DEFAULTS.buffBack[field], field .. " is a Buff Back setting")
                listed[field] = true
            end
            for _, field in ipairs(shown) do assert.is_true(listed[field], field .. " is kept") end
            assert.are.equal(#shown, #ns.BuffsTab.FIELDS)
            place("party")
            wow.run(rowFor("motw").who, "OnClick")
            tick(w.whoList.tanks, true)
            ns.db.buffBack.groupVersions = false
            ns.db.buffBack.buffOrder = { "thorns", "motw" }
            ns.db.buffBack.neverOffer = { thorns = true }
            ns.db.buffBack.whoRaid = { thorns = { never = { ["ann-vale"] = "Ann-Vale" } } }
            ns.db.buffBack.sayLine = true
            ns.db.buffBack.owedMinutes = 20
            ns.db.buffBack.passersBy = true
            -- Buff mode's, changed from their defaults so keeping them shows.
            ns.db.buffBack.buffModeKey = "F"
            ns.db.buffBack.autoOnJoin = not ns.Config.DEFAULTS.buffBack.autoOnJoin
            ns.db.buffBack.autoOffDone = not ns.Config.DEFAULTS.buffBack.autoOffDone
            ns.db.buffBack.autoOffMinutes = ns.Config.DEFAULTS.buffBack.autoOffMinutes + 1
            ns.db.buffBack.topUpMinutes = ns.Config.DEFAULTS.buffBack.topUpMinutes + 1
            local before = {}
            for _, field in ipairs(ns.BuffsTab.FIELDS) do
                before[field] = ns.Serialize.Encode({ v = ns.db.buffBack[field] })
            end
            wow.run(w.tabs.favours, "OnClick")
            wow.run(w.reset, "OnClick")
            for _, field in ipairs(ns.BuffsTab.FIELDS) do
                assert.are.equal(before[field], ns.Serialize.Encode({ v = ns.db.buffBack[field] }), field)
            end
            assert.are.equal("new", ns.db.buffBack.whoChoice)
            assert.is_true(ns.db.buffBack.whoParty.motw.tanks)
            -- The Favours tab's own settings are reset, passers-by now among them.
            assert.is_false(ns.db.buffBack.sayLine)
            assert.are.equal(ns.Config.DEFAULTS.buffBack.owedMinutes, ns.db.buffBack.owedMinutes)
            assert.is_false(ns.db.buffBack.passersBy)
            assert.are.same({}, wow.errors)
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

        -- #408's architecture review: every row read "Names (0)" while pending.
        it("counts the names in force (1.3.3's), and says what each choice does with them", function()
            boot()
            assert.is_true(ns.BuffRules.AddName("motw", "never", "Bob-Stone"))
            assert.is_true(ns.BuffRules.AddName("motw", "always", "Ann-Vale"))
            ns.Options.Refresh()
            for _, p in ipairs({ "party", "raid", "pvp" }) do
                place(p)
                local row = rowFor("motw")
                assert.are.equal("Names (2)", row.names:GetText(), p)
                assert.are.equal("Names (0)", rowFor("thorns").names:GetText(), p)
                assert.are.equal(ns.BuffsTab.PENDING_NAMES, row.names.tooltip, p)
            end
            wow.run(w.choice.new, "OnClick")
            assert.is_true(said("your 2 Always and Never names weren't kept"))
            place("party")
            assert.are.equal("Names (0)", rowFor("motw").names:GetText())
            assert.are_not.equal(ns.BuffsTab.PENDING_NAMES, rowFor("motw").names.tooltip)
            -- Keep carries them, and says nothing of names left behind.
            boot()
            assert.is_true(ns.BuffRules.AddName("motw", "never", "Bob-Stone"))
            wow.printed = {}
            wow.run(w.choice.keep, "OnClick")
            assert.is_false(said("weren't kept") or said("wasn't kept"))
            place("raid")
            assert.are.equal("Names (1)", rowFor("motw").names:GetText())
            -- One name: said in the singular.
            boot()
            assert.is_true(ns.BuffRules.AddName("thorns", "never", "Bob-Stone"))
            wow.run(w.choice.new, "OnClick")
            assert.is_true(said("your 1 Always and Never name wasn't kept"))
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

    -- A new file: after an update, /reload runs without it until a restart
    -- (#142; #408's architecture review).
    it("asks for a restart when only BuffsTab.lua is new (black)", function()
        wow.reset()
        local loaded = {}
        local _, files = wow.parseToc()
        for _, file in ipairs(files) do
            if file ~= "BuffsTab.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
        end
        wow.fire("ADDON_LOADED", wow.ADDON_NAME)
        wow.fire("PLAYER_ENTERING_WORLD", true, false)
        assert.are.same({}, wow.errors)
        assert.is_truthy(table.concat(wow.printed, "\n"):find("Restart the game", 1, true))
    end)

    describe("damage and storms (red)", function()
        it("settings damaged while the tab is open heal as it fills", function()
            boot({ choice = "new" })
            place("raid")
            wow.run(rowFor("motw").names, "OnClick")
            -- The whole section: healed, and the tab shows it as healed.
            for _, damage in ipairs({ 7, "x", { whoParty = 3 } }) do
                wow.advance(2)
                ns.db.buffBack = damage
                ns.Options.Refresh()
                assert.are.equal("table", type(ns.db.buffBack))
                assert.are.equal(ns.db.buffBack.groupVersions == true, w.groupVersions:GetChecked() == true)
                assert.are.same({}, wow.errors)
            end
            -- One field at a time, on a chosen place (#408's testing review):
            -- each heals as the tab fills, and the tab shows what it healed to.
            assert.is_true(ns.BuffRules.Choose("new"))
            place("raid")
            local cases = {
                -- A damaged tick reads as Off, never as Everyone; a lost map,
                -- the place's default.
                { "whoRaid", { motw = { everyone = "y", tanks = true } }, { tanks = true } },
                { "whoRaid", { motw = { classes = { MAGE = "yes", DRUID = true } } }, { classes = { DRUID = true } } },
                { "whoRaid", 7, ns.BuffRules.DEFAULTS.raid.motw or { everyone = true } },
                { "groupEnough", { 7 } },
                { "groupVersions", "yes" },
                { "selfBuffs", 3 },
                { "breathNearWater", { true } },
                { "fastCastInForm", "yes" },
                { "raidSplit", "on" },
            }
            for _, case in ipairs(cases) do
                local field, value = case[1], case[2]
                local what = field .. " = " .. tostring(value)
                wow.advance(2)
                ns.db.buffBack[field] = value
                local expected = ns.Config.Load({ buffBack = { [field] = value, whoChoice = "new" } }).buffBack[field]
                ns.Options.Refresh()
                local b = ns.db.buffBack
                assert.are.same(expected, b[field], what .. " healed as the tab filled")
                assert.are.equal("new", b.whoChoice, what)
                assert.are.equal(tostring(b.groupEnough), w.steppers.groupEnough.box:GetText(), what)
                for _, name in ipairs({ "selfBuffs", "breathNearWater", "fastCastInForm", "groupVersions", "raidSplit" }) do
                    local want = b[name] == true
                    if name == "raidSplit" then want = ns.RaidSplit.Enabled() end
                    assert.are.equal(want, w[name]:GetChecked() == true, what .. ": " .. name)
                end
                local entry = ns.BuffRules.PlaceEntry(ns.BuffData.ByKey("motw"), "raid")
                if case[3] then assert.are.same(case[3], entry, what .. ": the rule read") end
                assert.are.equal((ns.BuffsTab.Summary(entry)), rowFor("motw").who:GetText(), what)
                assert.are.same({}, wow.errors, what)
            end
        end)

        -- Each seed must reach every kind of press (#408's testing review: the
        -- list was ticked once and Off never pressed in 240 steps).
        it("pressing the tab's controls in any order never raises an error", function()
            local PLACES = { "strangers", "party", "raid", "pvp" }
            for _, seed in ipairs({ 408, 1116, 77 }) do
                random.seed(seed)
                boot({ class = "PALADIN", known = { [KINGS] = true, [MIGHT_1] = true, [WISDOM_1] = true } })
                local reach = { ticks = {}, off = 0, names = 0, choice = 0, blessing = 0 }
                local function any(list) return list[random.random(#list)] end
                local function onTab() wow.run(w.tabs.buffs, "OnClick") end
                -- A shown row whose part (who or names) can be pressed, or nil.
                local function pressable(part)
                    local out = {}
                    for _, row in ipairs(w.whoRows) do
                        if row[part]:IsVisible() and row[part]:IsEnabled() then out[#out + 1] = row end
                    end
                    return #out > 0 and any(out) or nil
                end
                local actions = {
                    function() place(any(PLACES)) end,
                    function()
                        local was = ns.BuffRules.Pending()
                        wow.run(any({ w.choice.keep, w.choice.new }), "OnClick")
                        if was and not ns.BuffRules.Pending() then reach.choice = reach.choice + 1 end
                    end,
                    -- Open a row's list, then tick a box in it or press Off.
                    function()
                        onTab()
                        if random.random(2) == 1 then place(any(PLACES)) end
                        local row = pressable("who")
                        if not row then return end
                        if not w.whoList:IsShown() then wow.run(row.who, "OnClick") end
                        if not w.whoList:IsShown() then return end
                        if random.random(4) == 1 then
                            wow.run(w.whoList.off, "OnClick")
                            reach.off = reach.off + 1
                        else
                            local boxes = {}
                            for _, box in ipairs({ w.whoList.everyone, w.whoList.tanks, w.whoList.healers,
                                w.whoList.damage, w.whoList.classes.MAGE, w.whoList.classes.WARRIOR }) do
                                if box:IsShown() then boxes[#boxes + 1] = box end
                            end
                            tick(any(boxes), random.random(2) == 1)
                            local p = ns.BuffsTab.Place()
                            reach.ticks[p] = (reach.ticks[p] or 0) + 1
                        end
                    end,
                    -- Open a row's names, then type in a box.
                    function()
                        onTab()
                        local row = pressable("names")
                        if not row then return end
                        if not w.who.always:IsVisible() then wow.run(row.names, "OnClick") end
                        if not w.who.always:IsVisible() then return end
                        local box = any({ w.who.always, w.who.never })
                        box:SetFocus()
                        box:SetText(any({ "Ann Vale", "bad name!", "", "Cid Rock, Dot Fern" }))
                        box:ClearFocus()
                        reach.names = reach.names + 1
                    end,
                    function()
                        local row = w.buffRows[random.random(3)]
                        wow.run(any({ row.up, row.down }), "OnClick")
                    end,
                    function() wow.run(any({ w.tabs.buffs, w.tabs.buffBack, w.tabs.buff }), "OnClick") end,
                    function() ns.db.buffBack.whoChoice = any({ "pending", "kept", 9 }) end,
                    function()
                        onTab()
                        place("raid")
                        local cb = w.who.raidBlessings[1]
                        if cb:IsVisible() then
                            wow.run(cb, "OnClick")
                            reach.blessing = reach.blessing + 1
                        end
                    end,
                }
                for _ = 1, 200 do
                    any(actions)()
                    ns.Options.Refresh()
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
                for _, p in ipairs(PLACES) do
                    assert.is_true((reach.ticks[p] or 0) > 0, ("seed %d: no list ticked at %s"):format(seed, p))
                end
                for _, kind in ipairs({ "off", "names", "choice", "blessing" }) do
                    assert.is_true(reach[kind] > 0, ("seed %d: no %s reached"):format(seed, kind))
                end
            end
        end)
    end)
end)
