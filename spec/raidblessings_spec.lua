-- Spec: #68, #76, #208, #70, #368, #376, #394, #408, #372, #442
-- My Blessings in this raid (paladins): choose which of your Blessings you
-- give in the raid you're in, so two paladins don't both give Kings. The
-- choice is never saved and is forgotten once you're out of the raid, as the
-- group look believes it (#368): an answer that can't be believed keeps it.
-- It's forgotten too when the raid's leader, or most of its members at the
-- choice, change (#376), on what the game shows plainly.
-- Quick Never: Shift+right-click on a group buff puts that member on the
-- buff's Never list.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local KINGS, MIGHT_1, WISDOM_1 = 20217, 19740, 19742
local MOTW, MOTW_1 = 9885, 1126

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("My Blessings in this raid", function()
    local ns, button

    -- A paladin who knows Kings, Wisdom and Might, in buff mode
    -- (unless opts.buffModeOff).
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ before = function(state)
            state.class = opts.class or "PALADIN"
            state.knownSpells = opts.known
                or { [KINGS] = true, [WISDOM_1] = true, [MIGHT_1] = true }
        end })
        button = ns.BuffButton.Frame()
        ns.db.buffBack.buffOrder = { "kings", "might", "wisdom" }
        if not opts.buffModeOff then slash("buffmode on") end
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    local function armed()
        local text = macro()
        if not text then return nil end
        return text:match("/targetexact ([^\n]+)") .. ": " .. text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    local function tokenOf(id)
        for token, u in pairs(wow.state.units) do
            if u.id == id and token ~= "target" then return token end
        end
    end

    -- Scroll once and let the buff show on whoever it reached.
    local function scroll()
        local before = #wow.casts
        wow.pressKey("MOUSEWHEELUP")
        local cast = wow.casts[before + 1]
        if cast and not cast.failed then
            local u = wow.state.units[tokenOf(cast.target)]
            if u then
                u.auras, u.auraSources = u.auras or {}, u.auraSources or {}
                u.auras[#u.auras + 1] = cast.id
                u.auraSources[#u.auras] = "player"
            end
        end
        return cast
    end

    -- Scroll until nothing's left: "Name Spell" for each cast, in order.
    local function buffAll()
        local given = {}
        for _ = 1, 30 do
            local cast = scroll()
            if not cast then break end
            given[#given + 1] = cast.target .. " " .. cast.spell
        end
        return given
    end

    -- A group of rogues (no Wisdom: they don't use mana) and mages.
    local function group(kind, names, classes)
        wow.setGroup(kind, names)
        local prefix = kind == "raid" and "raid" or "party"
        for i in ipairs(names) do
            local u = wow.state.units[prefix .. i]
            u.class, u.role = (classes or {})[i] or "ROGUE", "DAMAGER"
        end
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
        ns.BuffButton.Refresh()
    end

    local function solo()
        wow.setGroup(nil, {})
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    -- The last line printed, without the addon's name in front.
    local function lastPrinted() return ((wow.printed[#wow.printed] or ""):gsub("^|c%x+Friendly Forever:|r ", "")) end

    local function printedSince(n)
        local out = {}
        for i = n + 1, #wow.printed do out[#out + 1] = wow.printed[i] end
        return table.concat(out, "\n")
    end

    before_each(function() boot() end)

    describe("choosing (white)", function()
        it("gives only the Blessings you chose", function()
            group("raid", { "Ann-Vale", "Bo-Lake" })
            assert.is_true(ns.BuffRules.SetRaidBlessings({ "might" }))
            assert.is_true(ns.BuffRules.RaidBlessingsChosen())
            assert.are.equal("Ann Vale: Blessing of Might", armed(), "Kings is first in your order, but not yours here")
            assert.are.same({
                "Ann-Vale Blessing of Might", "Bo-Lake Blessing of Might",
            }, buffAll(), "Kings is not yours here, so nothing else is given")
            assert.are.same({}, wow.errors)
        end)

        it("another paladin's Kings: you offer your next Blessing; Might and Wisdom chosen: never Kings", function()
            group("raid", { "Ann-Vale", "Bo-Lake", "Cid-Rock" }, { "MAGE", "ROGUE", "MAGE" })
            wow.state.units.raid1.auras, wow.state.units.raid1.auraSources = { KINGS }, { "raid9" }
            assert.are.same({
                "Bo-Lake Blessing of Kings", "Cid-Rock Blessing of Kings", "Ann-Vale Blessing of Might",
            }, buffAll(), "Ann wears another paladin's Kings: your next Blessing")
            for i = 1, 3 do wow.state.units["raid" .. i].auras, wow.state.units["raid" .. i].auraSources = {}, {} end
            slash("blessings might wisdom")
            local given = buffAll()
            for _, cast in ipairs(given) do
                assert.is_falsy(cast:find("Kings", 1, true), cast)
            end
            assert.are.same({
                "Ann-Vale Blessing of Might", "Bo-Lake Blessing of Might", "Cid-Rock Blessing of Might",
            }, given)
        end)

        it("passes over a Blessing left to others quietly: it isn't owed", function()
            group("raid", { "Ann-Vale" })
            ns.BuffRules.SetRaidBlessings({ "might" })
            ns.db.buffBack.buffOrder = { "kings", "might" }
            wow.state.units.raid1.auras, wow.state.units.raid1.auraSources = { MIGHT_1 }, { "player" }
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            local _, _, settled = ns.GroupBuffs.Next()
            assert.is_true(settled, "everyone has your buffs: Kings is someone else's")
        end)

        it("lets the Blessing you switched to replace one you've left to others", function()
            group("raid", { "Ann-Vale" })
            wow.state.units.raid1.auras, wow.state.units.raid1.auraSources = { MIGHT_1 }, { "player" }
            ns.BuffButton.Refresh()
            assert.is_nil(macro(), "your Might: no second Blessing from you over it")
            slash("blessings kings")
            assert.are.equal("Ann Vale: Blessing of Kings", armed(), "your Might is someone else's job now")
            slash("blessings kings might")
            assert.is_nil(macro(), "and your Might counts again once you cover it")
        end)

        it("a Blessing another paladin recasts over yours is no longer yours: your next Blessing is offered (#208)",
            function()
                group("party", { "Ann-Vale" })
                wow.wearBuff("party1", KINGS, { source = "player" })
                ns.BuffButton.Refresh()
                assert.is_nil(macro(), "your Kings: no second Blessing from you over it")
                wow.wearBuff("party1", KINGS, { source = "raid9" }) -- the same spell, recast: theirs now
                ns.BuffButton.Refresh()
                assert.are.equal("Ann Vale: Blessing of Might", armed())
                wow.wearBuff("party1", KINGS, { source = "player" })
                ns.BuffButton.Refresh()
                assert.is_nil(macro(), "and yours again")
            end)

        it("can choose more than one, and choosing all of them is the same as not choosing", function()
            group("raid", { "Ann-Vale" }, { "MAGE" })
            assert.is_true(ns.BuffRules.SetRaidBlessings({ "wisdom", "might", "wisdom" }))
            assert.is_true(ns.BuffRules.RaidBlessingsChosen())
            assert.are.equal("Ann Vale: Blessing of Might", armed())
            assert.is_true(ns.BuffRules.SetRaidBlessings({ "kings", "wisdom", "might" }))
            assert.is_false(ns.BuffRules.RaidBlessingsChosen(), "every Blessing you know: nothing narrowed")
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            ns.BuffRules.SetRaidBlessings({ "might" })
            assert.is_true(ns.BuffRules.SetRaidBlessings(nil))
            assert.is_false(ns.BuffRules.RaidBlessingsChosen())
        end)

        it("is chosen with /friendly blessings, which says what you give", function()
            group("raid", { "Ann-Vale" })
            local n = #wow.printed
            slash("blessings")
            local out = printedSince(n)
            assert.is_truthy(out:find("blessings you give in this raid: Blessing of Kings, Blessing of Wisdom, "
                .. "Blessing of Might (all: you haven't chosen)", 1, true), out)
            assert.is_truthy(out:find("/friendly blessings all | kings wisdom might -", 1, true), out)
            slash("blessings Might  WISDOM")
            assert.are.equal("blessings you give in this raid: Blessing of Wisdom, Blessing of Might", lastPrinted())
            assert.are.equal("Ann Vale: Blessing of Might", armed())
            slash("blessings all")
            assert.is_truthy(lastPrinted():find("(all: you haven't chosen)", 1, true))
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
        end)

        it("is listed in /friendly help", function()
            local n = #wow.printed
            slash("help")
            assert.is_truthy(printedSince(n):find("/friendly blessings", 1, true))
        end)

        it("is forgotten when you leave the raid", function()
            group("raid", { "Ann-Vale" })
            ns.BuffRules.SetRaidBlessings({ "might" })
            group("party", { "Ann-Vale" })
            assert.is_false(ns.BuffRules.RaidBlessingsChosen())
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            group("raid", { "Ann-Vale" })
            assert.is_false(ns.BuffRules.RaidBlessingsChosen(), "a new raid starts with all of them")
        end)

        it("is forgotten when you leave the raid even out of buff mode", function()
            boot({ buffModeOff = true })
            group("raid", { "Ann-Vale" })
            ns.BuffRules.SetRaidBlessings({ "might" })
            solo()
            group("raid", { "Cid-Rock" }) -- the next raid, with nothing asking in between
            assert.is_false(ns.BuffRules.RaidBlessingsChosen())
        end)

        it("isn't saved", function()
            group("raid", { "Ann-Vale" })
            ns.BuffRules.SetRaidBlessings({ "might" })
            -- raidSplit is the raid buff split's switch (#70), and whoRaid who
            -- gets each buff in a raid (#408), not this choice.
            for key in pairs(ns.db.buffBack) do
                if key ~= "raidSplit" and key ~= "whoRaid" then
                    assert.is_falsy(key:lower():find("raid", 1, true), key)
                end
            end
        end)

        it("is shown and changed on the Raid place of the Buffs tab", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffs, "OnClick")
            wow.run(w.placeTabs.raid, "OnClick")
            local r = w.who
            assert.is_true(r.raidHeader:IsVisible())
            assert.is_truthy(r.raidHeader:GetText():find("join a raid to choose", 1, true))
            assert.are.equal("Blessing of Kings", r.raidBlessings[1].label:GetText())
            assert.is_false(r.raidBlessings[1]:IsEnabled(), "only in a raid")
            group("raid", { "Ann-Vale" })
            ns.Options.Refresh()
            assert.is_true(r.raidBlessings[1]:IsEnabled())
            assert.is_truthy(r.raidHeader:GetText():find("until you leave it", 1, true))
            local shown = {}
            for _, cb in ipairs(r.raidBlessings) do
                if cb:IsShown() then
                    shown[#shown + 1] = cb.key
                    assert.is_true(cb:GetChecked(), cb.key)
                end
            end
            assert.are.same({ "kings", "wisdom", "might" }, shown, "the Blessings you know")
            r.raidBlessings[1]:SetChecked(false)
            wow.run(r.raidBlessings[1], "OnClick")
            assert.is_true(ns.BuffRules.RaidBlessingsChosen())
            assert.is_false(ns.BuffRules.CoversInRaid(ns.BuffData.ByKey("kings")))
            assert.are.equal("Ann Vale: Blessing of Might", armed())
            slash("blessings all")
            assert.is_true(r.raidBlessings[1]:GetChecked(), "the slash command shows in the panel")
        end)

        -- The owner's decision on #372: while the game won't say whether
        -- you're in a raid, the boxes stay greyed, a kept choice still ticked,
        -- and the header says why.
        for _, case in ipairs({
            { "a secret", function() wow.state.inRaidUnreadable = true end },
            { "false in a raid", function() _G.IsInRaid = function() return false end end },
            { "an error", function() _G.IsInRaid = function() error("IsInRaid: not now") end end },
        }) do
            it("IsInRaid() " .. case[1] .. " with a choice kept: greyed, still ticked, and says it can't tell "
                .. "(black, #372)", function()
                local w = ns.Options.widgets
                wow.run(w.tabs.buffs, "OnClick")
                wow.run(w.placeTabs.raid, "OnClick")
                local r = w.who
                group("raid", { "Ann-Vale" })
                slash("blessings might")
                local real = _G.IsInRaid
                case[2]()
                ns.Options.Refresh()
                assert.is_true(ns.BuffRules.RaidBlessingsChosen(), "the choice is kept")
                assert.is_truthy(r.raidHeader:GetText():find("(can't tell if you're in a raid)", 1, true),
                    r.raidHeader:GetText())
                local ticked = {}
                for _, cb in ipairs(r.raidBlessings) do
                    if cb:IsShown() then
                        assert.is_false(cb:IsEnabled(), cb.key)
                        if cb:GetChecked() then ticked[#ticked + 1] = cb.key end
                    end
                end
                assert.are.same({ "might" }, ticked, "the kept choice still shows")
                -- Readable again: the boxes work.
                _G.IsInRaid, wow.state.inRaidUnreadable = real, nil
                ns.Options.Refresh()
                assert.is_true(r.raidBlessings[1]:IsEnabled())
                assert.is_truthy(r.raidHeader:GetText():find("until you leave it", 1, true))
                assert.are.same({}, wow.errors)
            end)
        end

        it("IsInRaid() true in a party: the boxes stay greyed, and say they can't tell (black, #372)", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffs, "OnClick")
            wow.run(w.placeTabs.raid, "OnClick")
            group("party", { "Ann-Vale" })
            local real = _G.IsInRaid
            _G.IsInRaid = function() return true end
            ns.Options.Refresh()
            _G.IsInRaid = real
            assert.is_false(w.who.raidBlessings[1]:IsEnabled())
            assert.is_truthy(w.who.raidHeader:GetText():find("(can't tell if you're in a raid)", 1, true))
        end)

        it("the boxes follow your group while the tab is open", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffs, "OnClick")
            wow.run(w.placeTabs.raid, "OnClick")
            assert.is_false(w.who.raidBlessings[1]:IsEnabled())
            group("raid", { "Ann-Vale" })
            assert.is_true(w.who.raidBlessings[1]:IsEnabled(), "a raid: the boxes work")
            slash("blessings might")
            assert.is_false(w.who.raidBlessings[1]:GetChecked())
            group("party", { "Ann-Vale" })
            assert.is_false(w.who.raidBlessings[1]:IsEnabled(), "out of the raid")
            assert.is_true(w.who.raidBlessings[1]:GetChecked(), "and back to all")
        end)

        it("sit below the Raid place's option, and only on the Raid place of the Buffs tab", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffs, "OnClick")
            wow.run(w.placeTabs.raid, "OnClick")
            assert.are.equal(w.raidSplit, select(2, w.who.raidHeader:GetPoint()))
            assert.are.equal(w.who.raidHeader, select(2, w.who.raidBlessings[1]:GetPoint()))
            wow.run(w.placeTabs.party, "OnClick")
            assert.is_false(w.who.raidHeader:IsVisible())
            for _, cb in ipairs(w.who.raidBlessings) do assert.is_false(cb:IsVisible()) end
            wow.run(w.placeTabs.raid, "OnClick")
            wow.run(w.tabs.buff, "OnClick")
            assert.is_false(w.who.raidHeader:IsVisible())
            for _, cb in ipairs(w.who.raidBlessings) do assert.is_false(cb:IsVisible()) end
        end)

        it("isn't on the Buffs tab for classes without Blessings", function()
            boot({ class = "DRUID", known = { [MOTW_1] = true, [MOTW] = true } })
            local w = ns.Options.widgets
            wow.run(w.tabs.buffs, "OnClick")
            wow.run(w.placeTabs.raid, "OnClick")
            assert.is_false(w.who.raidHeader:IsVisible())
            for _, cb in ipairs(w.who.raidBlessings) do assert.is_false(cb:IsVisible()) end
        end)
    end)

    describe("what it won't do (black)", function()
        it("can't be chosen outside a raid", function()
            group("party", { "Ann-Vale" })
            assert.are.same({ false, "you're not in a raid" }, { ns.BuffRules.SetRaidBlessings({ "might" }) })
            slash("blessings might")
            assert.is_truthy(printedSince(0):find("blessings: you're not in a raid.", 1, true))
            assert.is_false(ns.BuffRules.RaidBlessingsChosen())
        end)

        it("an unreadable raid answer can't choose, but keeps a choice already made (#368)", function()
            group("raid", { "Ann-Vale" })
            ns.BuffRules.SetRaidBlessings({ "might" })
            local real = _G.IsInRaid
            _G.IsInRaid = function() return wow.secret(true) end
            assert.is_true(ns.BuffRules.RaidBlessingsChosen())
            assert.are.same({ false, "can't tell if you're in a raid" }, { ns.BuffRules.SetRaidBlessings({ "kings" }) })
            _G.IsInRaid = function() error("no") end
            assert.is_false(ns.BuffRules.SetRaidBlessings({ "kings" }))
            _G.IsInRaid = real
            assert.is_true(ns.BuffRules.RaidBlessingsChosen(), "still chosen when it reads again")
            assert.is_false(ns.BuffRules.CoversInRaid(ns.BuffData.ByKey("kings")), "Might only, as chosen")
            assert.is_true(ns.BuffRules.CoversInRaid(ns.BuffData.ByKey("might")))
        end)

        -- #442: a new choice reads the raid as InForce() does (GroupBuffs.RaidAnswer),
        -- so the player is never told a choice was made that never applies.
        it("an IsInRaid() that can't be believed takes no new choice, says it can't tell, keeps a choice made, and \"all\" still stops it (black, #442)", function()
            local CASES = {
                { "true in a party", "party", function() _G.IsInRaid = function() return true end end },
                { "a secret in a raid", "raid", function() wow.state.inRaidUnreadable = true end },
                { "false in a raid", "raid", function() _G.IsInRaid = function() return false end end },
            }
            for _, case in ipairs(CASES) do
                local what = case[1]
                boot()
                local real = _G.IsInRaid
                group("raid", { "Ann-Vale" })
                assert.is_true(ns.BuffRules.SetRaidBlessings({ "might" }), what)
                case[3]()
                group(case[2], { "Ann-Vale" })
                local n = #wow.printed
                assert.are.same({ false, "can't tell if you're in a raid" },
                    { ns.BuffRules.SetRaidBlessings({ "kings" }) }, what)
                slash("blessings wisdom")
                assert.is_truthy(printedSince(n):find("blessings: can't tell if you're in a raid.", 1, true), what .. ": " .. printedSince(n))
                assert.is_falsy(printedSince(n):find("you're not in a raid", 1, true), what)
                assert.is_true(ns.BuffRules.RaidBlessingsChosen(), what .. ": the kept choice is untouched")
                slash("blessings all")
                assert.is_false(ns.BuffRules.RaidBlessingsChosen(), what .. ": /friendly blessings all still stops it")
                _G.IsInRaid, wow.state.inRaidUnreadable = real, nil
                assert.are.same({}, wow.errors, what)
            end
        end)

        it("in a raid whose answer reads true, a choice is taken as before (white, #442)", function()
            group("raid", { "Ann-Vale" })
            assert.are.same({ true }, { ns.BuffRules.SetRaidBlessings({ "might" }) })
            assert.is_true(ns.BuffRules.RaidBlessingsChosen())
            assert.is_false(ns.BuffRules.CoversInRaid(ns.BuffData.ByKey("kings")))
        end)

        it("refuses names that aren't your Blessings, and leaves the choice as it was", function()
            group("raid", { "Ann-Vale" })
            ns.BuffRules.SetRaidBlessings({ "might" })
            assert.are.same({ false, "'bogus' isn't one of your Blessings" },
                { ns.BuffRules.SetRaidBlessings({ "kings", "bogus" }) })
            assert.are.same({ false, "'motw' isn't one of your Blessings" }, { ns.BuffRules.SetRaidBlessings({ "motw" }) })
            assert.are.same({ false, "choose at least one Blessing (or all)" }, { ns.BuffRules.SetRaidBlessings({}) })
            assert.is_false(ns.BuffRules.CoversInRaid(ns.BuffData.ByKey("kings")), "unchanged")
            assert.is_true(ns.BuffRules.CoversInRaid(ns.BuffData.ByKey("might")))
        end)

        it("keeps chat codes out of what it prints back", function()
            group("raid", { "Ann-Vale" })
            slash("blessings |cffff0000kings|r")
            for _, line in ipairs(wow.printed) do
                assert.is_falsy(line:find("|cffff0000", 1, true), line)
            end
        end)

        it("an empty tick box set is refused, and the boxes show the choice again", function()
            group("raid", { "Ann-Vale" })
            local w = ns.Options.widgets
            wow.run(w.tabs.buffs, "OnClick")
            wow.run(w.placeTabs.raid, "OnClick")
            for _, cb in ipairs(w.who.raidBlessings) do cb:SetChecked(false) end
            wow.run(w.who.raidBlessings[1], "OnClick")
            assert.is_truthy(lastPrinted():find("choose at least one Blessing", 1, true))
            assert.is_true(w.who.raidBlessings[1]:GetChecked(), "back to all")
        end)

        it("says when you know no Blessings", function()
            boot({ class = "DRUID", known = { [MOTW_1] = true, [MOTW] = true } })
            group("raid", { "Ann-Vale" })
            slash("blessings might")
            assert.are.equal("blessings: you don't know any Blessings.", lastPrinted():match("blessings:.*"))
        end)

        it("doesn't touch buff back to strangers", function()
            group("raid", { "Ann-Vale" })
            ns.BuffRules.SetRaidBlessings({ "might" })
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Battle Shout", spellId = 6673 })
            assert.is_truthy((macro() or ""):find("/targetexact Bob Stone", 1, true))
            assert.is_truthy(macro():find("Blessing of Kings", 1, true), "a favour is your first buff, as before")
        end)
    end)

    describe("Shift+right-click (quick Never)", function()
        it("puts the shown member on that buff's Never list", function()
            group("party", { "Ann-Vale", "Bo-Lake" })
            wow.press(button, "RightButton", { shift = true })
            -- While pending (#408's review): Keep carries the list over.
            assert.are.equal("Ann Vale won't get Blessing of Kings (Never list; \"Keep my settings\" keeps it).",
                button.result:GetText())
            assert.are.equal("Ann-Vale", ns.db.buffBack.whoGets.kings.never["ann-vale"])
            assert.are.equal("Bo Lake: Blessing of Kings", armed())
            assert.are.same({
                "Bo-Lake Blessing of Kings", "Ann-Vale Blessing of Might",
            }, buffAll(), "only that buff: Ann still gets the next Blessing")
        end)

        it("names the buff it was, though the button moves on to another", function()
            group("party", { "Ann-Vale" })
            wow.press(button, "RightButton", { shift = true })
            -- While pending (#408's review): Keep carries the list over.
            assert.are.equal("Ann Vale won't get Blessing of Kings (Never list; \"Keep my settings\" keeps it).",
                button.result:GetText())
            assert.are.equal("Ann Vale: Blessing of Might", armed())
            wow.state.units.party1.auras = { MIGHT_1 }
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            ns.BuffRules.SetNames("kings", "never", "")
            ns.BuffButton.Refresh()
            assert.is_nil(macro(), "they wear your Might: Kings would replace it")
            wow.state.units.party1.auras = {}
            ns.BuffRules.SetNames("kings", "never", "Ann Vale")
            ns.BuffButton.Refresh()
            wow.press(button, "RightButton", { shift = true }) -- Might, the last thing shown
            assert.are.same({}, wow.errors, "nothing left to show afterwards")
            assert.is_nil(macro())
        end)

        it("keeps the names already on the list, and shows the new one in the panel", function()
            assert.is_true(ns.BuffRules.SetNames("kings", "never", "Cid Rock"))
            group("party", { "Ann-Vale" })
            wow.press(button, "RightButton", { shift = true })
            assert.are.equal("Ann Vale, Cid Rock", ns.BuffRules.NamesText("kings", "never"))
        end)

        it("isn't undone by a Never box left open in the panel", function()
            group("party", { "Ann-Vale" })
            local w = ns.Options.widgets
            assert.is_true(ns.BuffRules.Choose("new"))
            wow.run(w.tabs.buffs, "OnClick")
            assert.are.equal("kings", w.whoRows[1].key, "the box shown is Kings's")
            wow.run(w.whoRows[1].names, "OnClick")
            assert.is_true(w.who.never:IsVisible())
            w.who.never:SetFocus()
            wow.press(button, "RightButton", { shift = true })
            w.who.never:ClearFocus()
            assert.are.equal("Ann Vale", ns.BuffRules.NamesText("kings", "never", "party"))
            assert.are.equal("Ann Vale", w.who.never:GetText(), "and the box shows it")
        end)

        it("an unreadable Shift key is a plain right-click", function()
            group("party", { "Ann-Vale", "Bo-Lake" })
            local real = _G.IsShiftKeyDown
            _G.IsShiftKeyDown = function() error("no") end
            wow.press(button, "RightButton")
            assert.are.equal("Skipping Ann Vale for 5 minutes.", button.result:GetText())
            _G.IsShiftKeyDown = function() return wow.secret(true) end
            wow.press(button, "RightButton")
            assert.are.equal("Skipping Bo Lake for 5 minutes.", button.result:GetText())
            _G.IsShiftKeyDown = real
            assert.are.equal("", ns.BuffRules.NamesText("kings", "never"))
            assert.are.same({}, wow.errors)
        end)

        it("a plain right-click after a Shift one is plain again", function()
            group("party", { "Ann-Vale", "Bo-Lake" })
            wow.press(button, "RightButton", { shift = true })
            wow.press(button, "RightButton")
            assert.are.equal("Skipping Bo Lake for 5 minutes.", button.result:GetText())
            assert.are.equal("Ann Vale", ns.BuffRules.NamesText("kings", "never"))
        end)

        it("AddName refuses what isn't a name, and leaves the list alone", function()
            assert.are.same({ false, "no name" }, { ns.BuffRules.AddName("kings", "never", nil) })
            assert.are.same({ false, "no name" }, { ns.BuffRules.AddName("kings", "never", {}) })
            assert.are.equal("", ns.BuffRules.NamesText("kings", "never"))
        end)

        it("plain right-click still skips for 5 minutes, and adds no one", function()
            group("party", { "Ann-Vale", "Bo-Lake" })
            wow.press(button, "RightButton")
            assert.are.equal("Skipping Ann Vale for 5 minutes.", button.result:GetText())
            assert.are.equal("", ns.BuffRules.NamesText("kings", "never"))
        end)

        it("says why when the name can't be added", function()
            local names = {}
            for i = 1, ns.BuffRules.MAX_NAMES do names[i] = "Pal" .. string.char(96 + (i - 1) % 26 + 1)
                .. string.rep("a", math.floor((i - 1) / 26) + 1) end
            assert.is_true(ns.BuffRules.SetNames("kings", "never", table.concat(names, ", ")))
            group("party", { "Ann-Vale" })
            wow.press(button, "RightButton", { shift = true })
            assert.are.equal("Couldn't add Ann Vale to the Never list: at most " .. ns.BuffRules.MAX_NAMES
                .. " names.", button.result:GetText())
            assert.is_nil(ns.db.buffBack.whoGets.kings.never["ann-vale"])
            assert.are.same({}, wow.errors)
        end)

        it("on a favour (buff back) just lets it go, as right-click does", function()
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Battle Shout", spellId = 6673 })
            assert.is_truthy((macro() or ""):find("Bob Stone", 1, true))
            wow.press(button, "RightButton", { shift = true })
            assert.are.equal("", ns.BuffRules.NamesText("kings", "never"))
            assert.is_falsy((macro() or ""):find("Bob Stone", 1, true), "let go")
        end)
    end)

    -- #368: the choice is forgotten only when the game says you're not in a
    -- raid and the slots agree (GroupBuffs.RaidAnswer); one look that can't
    -- be read or believed keeps it.
    describe("an IsInRaid() answer that can't be believed (#368)", function()
        -- Each way one look can go wrong in a raid.
        local WRONG = {
            ["a secret"] = function() wow.state.inRaidUnreadable = true end,
            ["false in a raid"] = function() _G.IsInRaid = function() return false end end,
            ["no answer"] = function() _G.IsInRaid = function() return nil end end,
        }
        local function look()
            wow.fire("GROUP_ROSTER_UPDATE") -- Core asks CheckRaid
            ns.BuffButton.Refresh()
        end

        it("leaving a raid still forgets the choice, and a choice in a real raid is kept look after look (white)", function()
            group("raid", { "Ann-Vale", "Cid-Rock" })
            ns.BuffRules.SetRaidBlessings({ "might" })
            for _ = 1, 5 do
                look()
                wow.advance(10)
            end
            assert.is_true(ns.BuffRules.RaidBlessingsChosen())
            assert.are.equal("Ann Vale: Blessing of Might", armed())
            group("party", { "Ann-Vale", "Cid-Rock" })
            assert.is_false(ns.BuffRules.RaidBlessingsChosen(), "left the raid")
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            group("raid", { "Ann-Vale", "Cid-Rock" })
            ns.BuffRules.SetRaidBlessings({ "might" })
            solo()
            assert.is_false(ns.BuffRules.RaidBlessingsChosen(), "left the raid for no group")
            assert.are.same({}, wow.errors)
        end)

        it("one look with IsInRaid() unreadable, false in a raid, or a secret keeps the choice, and the next true look still uses it (black)", function()
            for what, wrong in pairs(WRONG) do
                boot()
                local real = _G.IsInRaid
                group("raid", { "Ann-Vale", "Cid-Rock" })
                ns.BuffRules.SetRaidBlessings({ "might" })
                wrong()
                look()
                assert.is_true(ns.BuffRules.RaidBlessingsChosen(), what .. ": kept through the wrong look")
                assert.is_false(ns.BuffRules.CoversInRaid(ns.BuffData.ByKey("kings")), what .. ": Kings is still left to others")
                _G.IsInRaid, wow.state.inRaidUnreadable = real, nil
                look()
                assert.are.equal("Ann Vale: Blessing of Might", armed(), what .. ": the next true look")
                assert.are.same({ "Ann-Vale Blessing of Might", "Cid-Rock Blessing of Might" }, buffAll(), what)
                assert.are.same({}, wow.errors, what)
            end
        end)

        it("a party that IsInRaid() calls a raid keeps it too: only a believable \"not a raid\" forgets it (black)", function()
            group("raid", { "Ann-Vale" })
            ns.BuffRules.SetRaidBlessings({ "might" })
            local real = _G.IsInRaid
            _G.IsInRaid = function() return true end
            group("party", { "Ann-Vale" })
            assert.is_true(ns.BuffRules.RaidBlessingsChosen(), "IsInRaid() says raid, but no raid slot is you")
            _G.IsInRaid = real
            look()
            assert.is_false(ns.BuffRules.RaidBlessingsChosen(), "the believable answer: not a raid")
            assert.are.same({}, wow.errors)
        end)

        it("stopping the choice works while the answer can't be read: never stuck (black)", function()
            group("raid", { "Ann-Vale" })
            ns.BuffRules.SetRaidBlessings({ "might" })
            wow.state.inRaidUnreadable = true
            local n = #wow.printed
            slash("blessings all")
            assert.is_false(ns.BuffRules.RaidBlessingsChosen())
            assert.is_falsy(printedSince(n):find("you're not in a raid", 1, true), printedSince(n))
            assert.is_truthy(printedSince(n):find("(all: you haven't chosen)", 1, true), printedSince(n))
            assert.are.same({ true }, { ns.BuffRules.SetRaidBlessings(nil) })
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("chaos (red tests)", function()
        it("never gives a Blessing you left to others, nor any buff to someone on its Never list", function()
            local blessed, skippedByChoice = 0, 0
            for _, seed in ipairs({ 3, 68, 451, 2026 }) do
                random.seed(seed)
                boot()
                local everyone = { "Ann-Vale", "Bo-Lake", "Cid-Rock", "Dot-Fern", "Eve-Moss" }
                local keys = { "kings", "wisdom", "might", "light", "motw" }
                -- What we expect the choice to be: nil (all) or [key] = true;
                -- and the members when it was made (#376), from the client's
                -- own state.
                local model, chosenWith
                local members = {}
                local function inRaid() return wow.state.groupType == "raid" end
                local function noteChoice()
                    chosenWith = {}
                    for _, name in ipairs(members) do chosenWith[name] = true end
                end
                local function regroup()
                    local r = random.random()
                    members = {}
                    for _, name in ipairs(everyone) do if random.random() < 0.7 then members[#members + 1] = name end end
                    if #members == 0 then members[1] = everyone[1] end
                    if r < 0.15 then
                        members = {}
                        solo()
                    else
                        group(r < 0.65 and "raid" or "party", members,
                            { "MAGE", "ROGUE", "MAGE", "WARRIOR", "PRIEST" })
                    end
                    if not inRaid() then model = nil end
                    -- Another raid: most of the members at the choice are gone (#376).
                    if model then
                        local now, before, gone = {}, 0, 0
                        for _, name in ipairs(members) do now[name] = true end
                        for name in pairs(chosenWith) do
                            before = before + 1
                            if not now[name] then gone = gone + 1 end
                        end
                        if gone * 2 > before then model = nil end
                    end
                end
                regroup()
                local actions = {
                    regroup,
                    function()
                        local pick = {}
                        for _, key in ipairs(keys) do if random.random() < 0.4 then pick[#pick + 1] = key end end
                        local ok = ns.BuffRules.SetRaidBlessings(pick)
                        if ok then
                            local set, n = {}, 0
                            for _, k in ipairs(pick) do if not set[k] then n = n + 1 end set[k] = true end
                            model = n < 3 and set or nil -- you know three
                            noteChoice()
                        end
                    end,
                    function()
                        slash(random.random() < 0.5 and "blessings all" or "blessings might")
                        if inRaid() then
                            local all = lastPrinted():find("all: you haven't chosen", 1, true)
                            if all then model = nil else model = { might = true } end
                            noteChoice()
                        end
                    end,
                    function()
                        local name = everyone[random.random(#everyone)]
                        ns.BuffRules.SetNames(keys[random.random(5)], "never",
                            random.random() < 0.3 and "" or name:gsub("%-", " "))
                    end,
                    function() wow.press(button, "RightButton", { shift = random.random() < 0.6 }) end,
                    function() wow.advance(random.random() * 400) end,
                    function()
                        -- A buff wears off someone.
                        for token, u in pairs(wow.state.units) do
                            if (token:find("^raid") or token:find("^party")) and u.auras and #u.auras > 0
                                and random.random() < 0.3 then
                                table.remove(u.auras, 1)
                                if u.auraSources then table.remove(u.auraSources, 1) end
                            end
                        end
                        ns.BuffButton.Refresh()
                    end,
                }
                for step = 1, 400 do
                    local where = ("seed %d, step %d"):format(seed, step)
                    local pick = random.random(#actions)
                    actions[pick]()
                    local nevers = {}
                    for key, entry in pairs(ns.db.buffBack.whoGets or {}) do
                        nevers[key] = {}
                        for name in pairs(entry.never or {}) do nevers[key][name] = true end
                    end
                    local chosen, raid = model, inRaid()
                    local cast = scroll()
                    if cast then
                        local buff
                        for _, b in ipairs(ns.BuffData.ClassBuffs()) do
                            for _, id in ipairs(b.ranks) do if id == cast.id then buff = b end end
                        end
                        assert.is_truthy(buff, where .. ": cast " .. tostring(cast.spell))
                        assert.is_falsy((nevers[buff.key] or {})[cast.target:lower()],
                            where .. ": " .. cast.target .. " is on the Never list for " .. buff.key)
                        if buff.family == "blessing" then
                            if raid and chosen then
                                assert.is_true(chosen[buff.key] == true, where .. ": left " .. buff.key .. " to others")
                            end
                            blessed = blessed + 1
                        end
                    elseif raid and chosen then
                        skippedByChoice = skippedByChoice + 1
                    end
                    if not raid then
                        assert.is_false(ns.BuffRules.RaidBlessingsChosen(), where .. ": remembered outside a raid")
                    end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
            assert.is_true(blessed > 30, "blessed: " .. blessed)
            assert.is_true(skippedByChoice > 5, "presses with a choice and nothing to give: " .. skippedByChoice)
        end)

        -- #368: regroups, choices, buffs fading and presses, with an IsInRaid()
        -- that tells the truth, flips half its answers, always says false,
        -- answers nothing, or can't be read. While the client's state shows
        -- you still in the raid you chose in, no press gives a Blessing you
        -- left to another paladin. The model is the client's state and what
        -- was chosen, never the rules' own answer.
        it("a storm with an IsInRaid() that sometimes lies or can't be read never gives a Blessing left to another paladin in the same raid (red)", function()
            local MODES = { "truth", "flips", "false", "none", "secret" }
            local total = { steps = 0, keptThroughLie = 0, blessingsInRaid = 0, chosen = 0 }
            for _, seed in ipairs({ 7, 368, 999, 2026, 31337 }) do
                random.seed(seed)
                boot()
                local everyone = { "Ann-Vale", "Bo-Lake", "Cid-Rock", "Dot-Fern", "Eve-Moss" }
                local mode, lieState = "truth", seed
                local real = _G.IsInRaid
                _G.IsInRaid = function()
                    local answer = real()
                    if mode == "false" then return false end
                    if mode == "none" then return nil end
                    if mode == "flips" then
                        lieState = (lieState * 48271) % 2147483647
                        if lieState % 2 == 0 then return not answer end
                    end
                    return answer
                end
                -- The Blessings chosen in the raid you're still in, or nil;
                -- and whether a look that lied or couldn't read came since.
                local chosen, lied = nil, false
                local function inRaid() return wow.state.groupType == "raid" end
                local function regroup()
                    local members = {}
                    for _, name in ipairs(everyone) do if random.random() < 0.7 then members[#members + 1] = name end end
                    if #members == 0 then members[1] = everyone[1] end
                    local r = random.random()
                    if r < 0.15 then
                        solo()
                    else
                        group(r < 0.7 and "raid" or "party", members, { "MAGE", "ROGUE", "MAGE", "WARRIOR", "PRIEST" })
                    end
                    -- Out of the raid, or into another: the choice was for that one.
                    chosen, lied = nil, false
                end
                regroup()
                local function choose()
                    -- Choose, where the game says raid truly.
                    if not inRaid() or mode ~= "truth" then return end
                    local pick, set, n = {}, {}, 0
                    for _, key in ipairs({ "kings", "wisdom", "might" }) do
                        if random.random() < 0.5 then
                            pick[#pick + 1] = key
                            set[key], n = true, n + 1
                        end
                    end
                    if ns.BuffRules.SetRaidBlessings(pick) then
                        chosen, lied = n < 3 and set or nil, false
                        if chosen then total.chosen = total.chosen + 1 end
                    end
                end
                local function lie()
                    mode = MODES[random.random(#MODES)]
                    wow.state.inRaidUnreadable = mode == "secret" or nil
                end
                local function fade()
                    -- Buffs wear off people (any of them, not only the first).
                    for token, u in pairs(wow.state.units) do
                        if (token:find("^raid") or token:find("^party")) and u.auras and #u.auras > 0
                            and random.random() < 0.5 then
                            local i = random.random(#u.auras)
                            table.remove(u.auras, i)
                            if u.auraSources then table.remove(u.auraSources, i) end
                        end
                    end
                end
                local actions = {
                    regroup, choose, choose, choose, lie, lie, fade, fade, fade,
                    function()
                        mode = "truth"
                        wow.state.inRaidUnreadable = nil
                    end,
                    function() wow.fire("GROUP_ROSTER_UPDATE") end,
                    function() wow.advance(random.random() * 60) end,
                }
                for step = 1, 300 do
                    local where = ("seed %d, step %d (IsInRaid %s)"):format(seed, step, mode)
                    actions[random.random(#actions)]()
                    if mode ~= "truth" then lied = true end
                    ns.BuffButton.Refresh()
                    local cast = scroll()
                    total.steps = total.steps + 1
                    if cast and inRaid() then
                        local buff
                        for _, b in ipairs(ns.BuffData.ClassBuffs()) do
                            for _, id in ipairs(b.ranks) do if id == cast.id then buff = b end end
                        end
                        assert.is_truthy(buff, where .. ": cast " .. tostring(cast.spell))
                        if buff.family == "blessing" then
                            total.blessingsInRaid = total.blessingsInRaid + 1
                            if chosen then
                                assert.is_true(chosen[buff.key] == true,
                                    where .. ": gave " .. buff.key .. ", left to another paladin in this raid")
                                if lied then total.keptThroughLie = total.keptThroughLie + 1 end
                            end
                        end
                    end
                    assert.are.same({}, wow.errors, where)
                end
            end
            assert.is_true(total.chosen > 5, "choices made: " .. total.chosen)
            assert.is_true(total.blessingsInRaid > 30, "Blessings given in a raid: " .. total.blessingsInRaid)
            assert.is_true(total.keptThroughLie > 5, "a chosen Blessing given after a look that lied: "
                .. total.keptThroughLie)
        end)
    end)

    describe("another raid: its leader or most of its members changed (#376)", function()
        local TEN = { "Ann-Vale", "Bo-Lake", "Cid-Rock", "Dot-Fern", "Eve-Moss",
            "Fay-Dale", "Gus-Hill", "Hal-Moor", "Ivy-Glen", "Jo-Reed" }
        local OTHERS = { "Kit-Ash", "Lu-Bay", "Max-Cove", "Ned-Dune", "Oz-Elm",
            "Pip-Ford", "Quin-Gate", "Rex-Holt", "Sam-Isle", "Tam-Jade" }

        -- A raid of these names, led by leader (a name, or nil), as the
        -- game's roster update shows it.
        local function raid(names, leader)
            wow.state.leader = leader
            group("raid", names)
        end

        -- names with the first n replaced by OTHERS.
        local function replaced(names, n)
            local out = {}
            for i, name in ipairs(names) do out[i] = i <= n and OTHERS[i] or name end
            return out
        end

        local function chosen() return ns.BuffRules.RaidBlessingsChosen() end

        it("kept through the same raid: filling up, a few leaving, regroups and roster updates (white)", function()
            raid({ "Ann-Vale", "Bo-Lake" }, "Ann-Vale")
            assert.is_true(ns.BuffRules.SetRaidBlessings({ "might" }))
            raid(TEN, "Ann-Vale") -- fills up: newcomers count for nothing
            assert.is_true(chosen(), "filled up")
            raid({ "Ann-Vale", "Cid-Rock", "Dot-Fern" }, "Ann-Vale") -- Bo left: one of two
            assert.is_true(chosen(), "half of the members at the choice gone isn't most")
            for i = 1, 3 do wow.state.units["raid" .. i].subgroup = 2 end
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(chosen(), "a regroup")
            assert.are.equal("Ann Vale: Blessing of Might", armed())
            assert.are.same({}, wow.errors)
        end)

        it("leaving through no group forgets it, as before (white)", function()
            raid(TEN, "Ann-Vale")
            ns.BuffRules.SetRaidBlessings({ "might" })
            solo()
            raid(TEN, "Ann-Vale")
            assert.is_false(chosen())
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
        end)

        it("a straight raid-to-raid change with a new leader forgets it, the same members or not (black)", function()
            raid(TEN, "Ann-Vale")
            ns.BuffRules.SetRaidBlessings({ "might" })
            raid(TEN, "Bo-Lake")
            assert.is_false(chosen(), "a new leader")
            assert.are.equal("Ann Vale: Blessing of Kings", armed(), "Kings is yours again")
            -- You led it, and someone else leads now.
            wow.state.isLeader = true
            raid(TEN, nil)
            ns.BuffRules.SetRaidBlessings({ "might" })
            wow.state.isLeader = false
            raid(TEN, "Cid-Rock")
            assert.is_false(chosen(), "you led it; Cid leads now")
            assert.are.same({}, wow.errors)
        end)

        it("a straight raid-to-raid change with most members new forgets it, with no leader to read (black)", function()
            raid(TEN, nil)
            ns.BuffRules.SetRaidBlessings({ "might" })
            raid(OTHERS, nil)
            assert.is_false(chosen(), "all new")
            raid(TEN, nil)
            ns.BuffRules.SetRaidBlessings({ "might" })
            raid(replaced(TEN, 5), nil)
            assert.is_true(chosen(), "five of ten gone: half isn't most")
            raid(replaced(TEN, 6), nil)
            assert.is_false(chosen(), "six of ten gone")
            -- A smaller raid with a few of the old one.
            raid(TEN, nil)
            ns.BuffRules.SetRaidBlessings({ "might" })
            raid({ "Ann-Vale", "Bo-Lake", "Kit-Ash" }, nil)
            assert.is_false(chosen(), "eight of ten gone")
            assert.are.same({}, wow.errors)
        end)

        it("a raid that turns over one member at a time counts against the members at the choice (black)", function()
            raid(TEN, "Ann-Vale")
            ns.BuffRules.SetRaidBlessings({ "might" })
            for n = 1, 6 do
                -- Ann stays and leads: only the members change.
                local names = replaced(TEN, n + 1)
                names[1] = "Ann-Vale"
                raid(names, "Ann-Vale")
                assert.are.equal(n <= 5, chosen(), n .. " of the ten gone")
            end
        end)

        it("choosing again counts from the raid then (black)", function()
            raid(TEN, nil)
            ns.BuffRules.SetRaidBlessings({ "might" })
            raid(replaced(TEN, 5), nil)
            ns.BuffRules.SetRaidBlessings({ "might", "wisdom" })
            raid(replaced(TEN, 8), nil) -- three more of the new choice's ten gone
            assert.is_true(chosen())
        end)

        it("what can't be read never counts as a change, and a later plain look still does (black)", function()
            -- The leader can't be read at the change.
            raid(TEN, "Ann-Vale")
            ns.BuffRules.SetRaidBlessings({ "might" })
            wow.state.leaderUnreadable = true
            raid(TEN, "Bo-Lake")
            assert.is_true(chosen(), "a leader that can't be read")
            wow.state.leaderUnreadable = nil
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(chosen(), "read: Bo leads")
            -- Names still loading at the change: they may be the old members.
            raid(TEN, nil)
            ns.BuffRules.SetRaidBlessings({ "might" })
            raid(OTHERS, nil)
            -- (the change already forgot it: choose again in a fresh raid)
            raid(TEN, nil)
            ns.BuffRules.SetRaidBlessings({ "might" })
            wow.setGroup("raid", OTHERS)
            wow.state.units.raid1.nameLoading = true
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(chosen(), "one name loading")
            wow.state.units.raid1.nameLoading = nil
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(chosen(), "loaded: all new")
            -- Slots that can't be read at all, and an IsInRaid() that can't.
            raid(TEN, nil)
            ns.BuffRules.SetRaidBlessings({ "might" })
            wow.state.unitsRestricted = true
            raid(OTHERS, nil)
            assert.is_true(chosen(), "slots that can't be read")
            wow.state.unitsRestricted = nil
            wow.state.inRaidUnreadable = true
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(chosen(), "IsInRaid() a secret")
            wow.state.inRaidUnreadable = nil
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(chosen(), "all plain: all new")
            assert.are.same({}, wow.errors)
        end)

        it("nothing that couldn't be read at the choice is taken from a later look, which may be another raid's (black)", function()
            -- The leader couldn't be read when chosen: the members decide.
            wow.state.leaderUnreadable = true
            raid(TEN, "Ann-Vale")
            ns.BuffRules.SetRaidBlessings({ "might" })
            wow.state.leaderUnreadable = nil
            raid(TEN, "Bo-Lake") -- the next raid already: the same ten, Bo leading
            assert.is_true(chosen(), "no leader at the choice to compare with")
            raid(TEN, "Cid-Rock")
            assert.is_true(chosen(), "Bo was never taken for the choice's leader")
            raid(OTHERS, "Kit-Ash")
            assert.is_false(chosen(), "all new")
            -- Names loading when chosen: they count, never as gone.
            wow.setGroup("raid", TEN)
            for i = 1, 2 do wow.state.units["raid" .. i].nameLoading = true end
            wow.fire("GROUP_ROSTER_UPDATE")
            ns.BuffRules.SetRaidBlessings({ "might" })
            raid(TEN, nil)
            assert.is_true(chosen(), "loaded: the same ten")
            raid(OTHERS, nil)
            assert.is_false(chosen(), "then all new: the eight read are gone, of ten")
            assert.are.same({}, wow.errors)
        end)

        it("a new leader read plainly forgets it, though a slot can't be read (black)", function()
            -- A name still loading in raid B.
            raid(TEN, "Ann-Vale")
            ns.BuffRules.SetRaidBlessings({ "might" })
            wow.state.leader = "Kit-Ash"
            wow.setGroup("raid", OTHERS)
            wow.state.units.raid2.nameLoading = true
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(chosen(), "Kit leads now")
            -- One slot whose UnitExists() can't be read.
            raid(TEN, "Ann-Vale")
            ns.BuffRules.SetRaidBlessings({ "might" })
            local real = _G.UnitExists
            _G.UnitExists = function(unit)
                if unit == "raid3" then return wow.secret(true) end
                return real(unit)
            end
            raid(OTHERS, "Kit-Ash")
            _G.UnitExists = real
            assert.is_false(chosen(), "Kit leads now, raid3 unreadable")
            assert.are.same({}, wow.errors)
        end)

        it("your own leadership that can't be read never makes you the leader (black)", function()
            -- Nobody's leadership can be read.
            raid(TEN, "Ann-Vale")
            ns.BuffRules.SetRaidBlessings({ "might" })
            wow.state.isLeaderUnreadable, wow.state.leaderUnreadable = true, true
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(chosen(), "no leader read: no change")
            wow.state.isLeaderUnreadable, wow.state.leaderUnreadable = nil, nil
            -- Yours can't be read, and Ann's name is loading.
            wow.state.isLeaderUnreadable = true
            wow.state.units.raid1.nameLoading = true
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(chosen(), "Ann not read, you not read: no change")
            wow.state.isLeaderUnreadable, wow.state.units.raid1.nameLoading = nil, nil
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(chosen(), "Ann still leads")
            assert.are.same({}, wow.errors)
        end)

        it("your own name still loading hides no change (black)", function()
            raid(TEN, nil)
            ns.BuffRules.SetRaidBlessings({ "might" })
            wow.state.units.player.nameLoading = true
            raid(OTHERS, nil)
            assert.is_false(chosen(), "all new, though your own name can't be read")
            wow.state.units.player.nameLoading = nil
        end)

        it("a choice made while most names were loading isn't judged on the few it could read (black)", function()
            -- Chosen with eight of ten names loading: only Ivy and Jo read.
            wow.setGroup("raid", TEN)
            for i = 1, 8 do wow.state.units["raid" .. i].nameLoading = true end
            wow.fire("GROUP_ROSTER_UPDATE")
            ns.BuffRules.SetRaidBlessings({ "might" })
            -- Ivy and Jo leave; the eight others stay, read now.
            raid({ "Ann-Vale", "Bo-Lake", "Cid-Rock", "Dot-Fern", "Eve-Moss", "Fay-Dale", "Gus-Hill", "Hal-Moor" }, nil)
            assert.is_true(chosen(), "two of ten gone")
            -- The eight that couldn't be read count among the ten, never as
            -- gone: a later look doesn't fill them in, since by then it may
            -- be another raid's members it reads.
            raid({ "Ann-Vale", "Bo-Lake", "Kit-Ash" }, nil)
            assert.is_true(chosen(), "only Ivy and Jo were read: two of ten gone")
        end)

        it("a choice with one name loading still sees the raid re-formed around you, with the same leader (black)", function()
            -- Raid A: the ten, Ann leading; Jo's name still loading at the choice.
            wow.state.leader = "Ann-Vale"
            wow.setGroup("raid", TEN)
            wow.state.units.raid10.nameLoading = true
            wow.fire("GROUP_ROSTER_UPDATE")
            ns.BuffRules.SetRaidBlessings({ "might" })
            -- Straight into raid B: Ann and nine new, Ann leading.
            local b = { "Ann-Vale" }
            for i = 1, 9 do b[#b + 1] = OTHERS[i] end
            raid(b, "Ann-Vale")
            assert.is_false(chosen(), "eight of the nine read are gone, of ten")
            assert.are.same({}, wow.errors)
        end)

        it("a slot that can't be read as you or someone else isn't taken for a member (black)", function()
            local real = _G.UnitIsUnit
            -- Chosen while UnitIsUnit() can't be read: your own slot too. Its
            -- reads up to your slot, the raid answer's (#442: a choice needs a
            -- believable raid), find you; every read after, the raid's look, can't.
            raid({ "Ann-Vale", "Bo-Lake", "Cid-Rock", "Dot-Fern" }, "Ann-Vale")
            local found = false
            _G.UnitIsUnit = function(a, b)
                local answer = real(a, b)
                if found then return wow.secret(answer) end
                found = answer == true
                return answer
            end
            assert.is_true(ns.BuffRules.SetRaidBlessings({ "might" }))
            _G.UnitIsUnit = real
            -- Half replaced, readable now: you aren't counted as gone.
            raid({ "Ann-Vale", "Bo-Lake", "Kit-Ash", "Lu-Bay" }, "Ann-Vale")
            assert.is_true(chosen(), "two of four gone, not three of five")
            raid({ "Ann-Vale", "Kit-Ash", "Lu-Bay" }, "Ann-Vale")
            assert.is_false(chosen(), "three of four gone")
            assert.are.same({}, wow.errors)
        end)

        it("a later look that can't read every slot judges nothing (black)", function()
            -- Chosen with eight of ten names loading: only Ivy and Jo read.
            wow.setGroup("raid", TEN)
            for i = 1, 8 do wow.state.units["raid" .. i].nameLoading = true end
            wow.fire("GROUP_ROSTER_UPDATE")
            ns.BuffRules.SetRaidBlessings({ "might" })
            -- Ann and Bo read now; six still loading.
            for i = 1, 2 do wow.state.units["raid" .. i].nameLoading = nil end
            wow.fire("GROUP_ROSTER_UPDATE")
            -- Ann, Bo, Ivy and Jo leave; the six others stay, read now.
            raid({ "Cid-Rock", "Dot-Fern", "Eve-Moss", "Fay-Dale", "Gus-Hill", "Hal-Moor" }, nil)
            assert.is_true(chosen(), "Ivy and Jo of ten gone, not four of the four first read")
        end)

        it("a slot that can't be read as holding someone may hold a member who stayed (black)", function()
            raid(TEN, nil)
            ns.BuffRules.SetRaidBlessings({ "might" })
            local real = _G.UnitExists
            _G.UnitExists = function(unit)
                if unit == "raid1" or unit == "raid2" or unit == "raid3" or unit == "raid4" then return wow.secret(true) end
                return real(unit)
            end
            raid(OTHERS, nil)
            assert.is_true(chosen(), "four slots that can't be read")
            _G.UnitExists = real
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_false(chosen(), "read: all new")
            assert.are.same({}, wow.errors)
        end)

        it("each use sees you've left the raid, before any roster update says so (#368, black)", function()
            local kings = ns.BuffData.ByKey("kings")
            for _, use in ipairs({ "chosen", "covers", "handSet" }) do
                raid(TEN, nil)
                ns.BuffRules.SetRaidBlessings({ "might" })
                wow.setGroup(nil, {}) -- no GROUP_ROSTER_UPDATE yet
                if use == "chosen" then
                    assert.is_false(ns.BuffRules.RaidBlessingsChosen(), use)
                elseif use == "covers" then
                    assert.is_true(ns.BuffRules.CoversInRaid(kings), use)
                else
                    assert.is_nil(ns.BuffRules.HandSetBlessings(), use)
                end
            end
        end)

        -- #376, the owner's answer (b): in a battleground the choice is kept
        -- but not used, and nothing there forgets it.
        local BG = { "Kit-Ash", "Lu-Bay", "Max-Cove", "Ned-Dune", "Oz-Elm" }
        local function enterBattleground()
            wow.state.leader = "Kit-Ash"
            wow.enterBattleground(BG)
        end
        -- Back from the battleground to your raid, as it was.
        local function backToRaid()
            wow.state.inInstance, wow.state.instanceType = false, nil
            wow.loseBuff(wow.PREPARATION_ID)
            wow.fire("PLAYER_ENTERING_WORLD", false, false)
            raid(TEN, "Ann-Vale")
        end

        it("in a battleground the choice isn't used, and applies again back in your raid (white)", function()
            local kings = ns.BuffData.ByKey("kings")
            raid(TEN, "Ann-Vale")
            ns.BuffRules.SetRaidBlessings({ "might" })
            wow.enterRaid(409, "Molten Core")
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(chosen(), "in a raid instance it's used")
            assert.is_false(ns.BuffRules.RaidBlessingsHeld(), "in force, not held")
            enterBattleground()
            assert.is_false(chosen(), "not in force here")
            assert.is_true(ns.BuffRules.RaidBlessingsHeld(), "held for your raid")
            assert.is_true(ns.BuffRules.CoversInRaid(kings), "Kings is yours here")
            assert.is_nil(ns.BuffRules.HandSetBlessings(), "nothing chosen to announce here")
            for _ = 1, 3 do wow.fire("GROUP_ROSTER_UPDATE") end
            backToRaid()
            assert.is_true(chosen(), "back: the same raid")
            assert.is_false(ns.BuffRules.CoversInRaid(kings))
            assert.are.equal("Ann Vale: Blessing of Might", armed())
            assert.are.same({}, wow.errors)
        end)

        it("in a battleground choosing is refused, and stopping still works (black)", function()
            raid(TEN, "Ann-Vale")
            ns.BuffRules.SetRaidBlessings({ "might" })
            enterBattleground()
            assert.are.same({ false, "you're in a battleground or arena (your raid's choice applies again when you're back)" },
                { ns.BuffRules.SetRaidBlessings({ "wisdom" }) })
            local n = #wow.printed
            slash("blessings")
            assert.is_truthy(printedSince(n):find("(in a battleground: your raid's choice applies again when you're back)", 1, true),
                printedSince(n))
            assert.is_falsy(printedSince(n):find("you haven't chosen", 1, true), printedSince(n))
            backToRaid()
            assert.is_true(ns.BuffRules.CoversInRaid(ns.BuffData.ByKey("might")), "the raid's choice, not Wisdom")
            assert.is_false(ns.BuffRules.CoversInRaid(ns.BuffData.ByKey("wisdom")))
            enterBattleground()
            assert.is_true(ns.BuffRules.SetRaidBlessings(nil))
            assert.is_false(ns.BuffRules.RaidBlessingsHeld())
            assert.are.same({ false, "you're in a battleground or arena" }, { ns.BuffRules.SetRaidBlessings({ "wisdom" }) })
            backToRaid()
            assert.is_false(chosen(), "stopped in the battleground: stays stopped")
            assert.are.same({}, wow.errors)
        end)

        it("where you are can't be read: the choice is used, and a look there forgets nothing (black)", function()
            raid(TEN, "Ann-Vale")
            ns.BuffRules.SetRaidBlessings({ "might" })
            wow.state.inInstanceSecret = true
            assert.is_true(ns.BuffRules.SetRaidBlessings({ "might" }), "can choose")
            assert.is_true(chosen(), "used")
            assert.are.equal("Ann Vale: Blessing of Might", armed())
            -- Maybe a battleground: its other leader and members change nothing.
            enterBattleground()
            assert.is_true(chosen(), "kept: it may be a battleground")
            backToRaid()
            wow.state.inInstanceSecret = nil
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(chosen(), "back in the same raid")
            raid(OTHERS, "Kit-Ash")
            assert.is_false(chosen(), "readable: another raid")
            assert.are.same({}, wow.errors)
        end)

        -- Regroups within one raid (one leader, at most half of the members
        -- at the choice gone, subgroups moving) and changes to another raid,
        -- with a leader, names, slots and IsInRaid() that sometimes can't be
        -- read. The model is the client's state: the raid's leader and the
        -- members at the choice, and whether every look since was plain.
        -- Within one raid the choice is never forgotten, and no press gives a
        -- Blessing left to another paladin; another raid, seen plainly,
        -- forgets it.
        it("a regroup storm never forgets the choice within one raid, nor gives a Blessing left to another paladin (red)", function()
            local total = { kept = 0, forgot = 0, keptUnreadable = 0, chosen = 0, keptThroughArena = 0 }
            -- Looks with the choice kept while each hazard was on (#302: one counter each).
            local keptWith = { leader = 0, myLeader = 0, restricted = 0, inRaid = 0, unitIsUnit = 0,
                oneSlot = 0, nameLoading = 0 }
            local everyone = {}
            for _, n in ipairs(TEN) do everyone[#everyone + 1] = n end
            for _, n in ipairs(OTHERS) do everyone[#everyone + 1] = n end
            for _, seed in ipairs({ 5, 376, 1234, 4242 }) do
                random.seed(seed)
                boot()
                local hiddenSlot -- a raid slot whose UnitExists() can't be read
                local realUnitExists = _G.UnitExists
                _G.UnitExists = function(unit)
                    if unit == hiddenSlot then return wow.secret(realUnitExists(unit)) end
                    return realUnitExists(unit)
                end
                local realUnitIsUnit = _G.UnitIsUnit
                local selfUnreadable = false -- UnitIsUnit() can't be read
                _G.UnitIsUnit = function(a, b)
                    if selfUnreadable then return wow.secret(realUnitIsUnit(a, b)) end
                    return realUnitIsUnit(a, b)
                end
                local choicePlain -- the choice read every slot
                local leader, members = "Ann-Vale", {}
                local atChoice -- the members at the choice: [name] = true
                local model -- the chosen Blessings, or nil
                local unclear = false -- a look since the choice couldn't read something
                local function obscured()
                    return wow.state.leaderUnreadable or wow.state.isLeaderUnreadable or wow.state.unitsRestricted
                        or wow.state.inRaidUnreadable or hiddenSlot ~= nil
                end
                -- The hazards on now, by name.
                local function hazards()
                    local on = { leader = wow.state.leaderUnreadable, myLeader = wow.state.isLeaderUnreadable,
                        restricted = wow.state.unitsRestricted, inRaid = wow.state.inRaidUnreadable,
                        unitIsUnit = selfUnreadable, oneSlot = hiddenSlot ~= nil }
                    for i = 1, 40 do
                        local u = wow.state.units["raid" .. i]
                        if u and u.nameLoading then on.nameLoading = true end
                    end
                    return on
                end
                -- The roster update; whether it could read everything.
                local function show()
                    wow.state.leader = leader
                    wow.setGroup("raid", members)
                    local plain = not obscured() and not selfUnreadable
                    for i in ipairs(members) do
                        local u = wow.state.units["raid" .. i]
                        u.class, u.role = i % 2 == 0 and "MAGE" or "ROGUE", "DAMAGER"
                        u.subgroup = random.random(8)
                    end
                    if random.random() < 0.15 then
                        wow.state.units["raid" .. random.random(#members)].nameLoading = true
                        plain = false
                    end
                    if not plain then unclear = true end
                    wow.fire("GROUP_ROSTER_UPDATE")
                    ns.BuffButton.Refresh()
                    return plain
                end
                local function goneOfChoice()
                    local now, before, gone = {}, 0, 0
                    for _, n in ipairs(members) do now[n] = true end
                    for n in pairs(atChoice or {}) do
                        before = before + 1
                        if not now[n] then gone = gone + 1 end
                    end
                    return gone, before
                end
                -- The same raid: someone joins or leaves, never taking the
                -- members at the choice below half, and never the leader.
                local function regroup()
                    if random.random() < 0.5 and #members < 20 then
                        local pick = everyone[random.random(#everyone)]
                        for _, n in ipairs(members) do if n == pick then pick = nil break end end
                        if pick then members[#members + 1] = pick end
                    elseif #members > 1 then
                        local i = random.random(#members)
                        local name = members[i]
                        if name ~= leader then
                            table.remove(members, i)
                            local gone, before = goneOfChoice()
                            if gone * 2 > before then table.insert(members, i, name) end
                        end
                    end
                    show()
                end
                -- Another raid: a new leader, all new members, or both.
                local function another()
                    local pool = random.random() < 0.5 and OTHERS or TEN
                    members = {}
                    for _, n in ipairs(pool) do if random.random() < 0.8 then members[#members + 1] = n end end
                    if #members == 0 then members[1] = pool[1] end
                    -- A raid's leader is one of its members.
                    local stays = false
                    for _, n in ipairs(members) do if n == leader then stays = true end end
                    if random.random() < 0.5 or not stays then leader = members[random.random(#members)] end
                    local plain = show()
                    local gone, before = goneOfChoice()
                    local leaderChanged = model and leader ~= model.leader
                    if model and plain and choicePlain and (leaderChanged or gone * 2 > before) then
                        assert.is_false(ns.BuffRules.RaidBlessingsChosen(), "another raid, seen plainly")
                        total.forgot = total.forgot + 1
                    end
                    -- Whatever was kept, it isn't this raid's now in the model.
                    model, atChoice = nil, nil
                end
                -- A choice can be made while names load or UnitIsUnit()
                -- can't be read (SetRaidBlessings asks IsInRaid() only).
                local function choose()
                    if obscured() then return end
                    local plainNow = not selfUnreadable
                    for i in ipairs(members) do
                        if wow.state.units["raid" .. i].nameLoading then plainNow = false end
                    end
                    local pick, set, n = {}, {}, 0
                    for _, key in ipairs({ "kings", "wisdom", "might" }) do
                        if random.random() < 0.5 then
                            pick[#pick + 1] = key
                            set[key], n = true, n + 1
                        end
                    end
                    if ns.BuffRules.SetRaidBlessings(pick) and n < 3 then
                        model = { keys = set, leader = leader }
                        atChoice, unclear, choicePlain = {}, not plainNow, plainNow
                        for _, name in ipairs(members) do atChoice[name] = true end
                        total.chosen = total.chosen + 1
                    elseif n == 3 then
                        model, atChoice = nil, nil
                    end
                end
                -- One hazard at a time, each alone (#259, #306), or none.
                local function obscure()
                    local r = random.random()
                    wow.state.leaderUnreadable = r < 0.12 or nil
                    wow.state.isLeaderUnreadable = (r >= 0.12 and r < 0.24) or nil
                    wow.state.unitsRestricted = (r >= 0.24 and r < 0.32) or nil
                    wow.state.inRaidUnreadable = (r >= 0.32 and r < 0.4) or nil
                    selfUnreadable = r >= 0.4 and r < 0.5
                    hiddenSlot = (r >= 0.5 and r < 0.6) and ("raid" .. random.random(#members)) or nil
                    if r < 0.6 then unclear = true end
                end
                members = { "Ann-Vale", "Bo-Lake", "Cid-Rock", "Dot-Fern", "Eve-Moss" }
                show()
                -- A battleground and back: the same raid after it.
                local function battleground()
                    wow.state.leader = "Kit-Ash"
                    wow.enterBattleground({ "Kit-Ash", "Lu-Bay", "Max-Cove" })
                    for _ = 1, random.random(3) do wow.fire("GROUP_ROSTER_UPDATE") end
                    wow.state.inInstance, wow.state.instanceType = false, nil
                    wow.loseBuff(wow.PREPARATION_ID)
                    wow.fire("PLAYER_ENTERING_WORLD", false, false)
                    show()
                end
                -- An arena and back (#394): its group is a party of others, which
                -- a raid answer reads believably as "not a raid".
                local function arena()
                    local had = model ~= nil
                    wow.state.leader = "Kit-Ash"
                    wow.state.inInstance, wow.state.instanceType = true, "arena"
                    wow.setGroup("party", { "Kit-Ash", "Lu-Bay" })
                    for _ = 1, random.random(3) do wow.fire("GROUP_ROSTER_UPDATE") end
                    ns.BuffRules.CheckRaid()
                    if had then
                        assert.is_true(ns.BuffRules.RaidBlessingsHeld(), "held, unused, in the arena")
                        assert.is_false(ns.BuffRules.RaidBlessingsChosen(), "not used in the arena")
                    end
                    wow.state.inInstance, wow.state.instanceType = false, nil
                    wow.fire("PLAYER_ENTERING_WORLD", false, false)
                    show()
                    if had and model then total.keptThroughArena = total.keptThroughArena + 1 end
                end
                local actions = { regroup, regroup, regroup, regroup, another, choose, choose, obscure, obscure,
                    battleground, arena,
                    function() wow.fire("GROUP_ROSTER_UPDATE") end,
                    function() for i = 1, 40 do local u = wow.state.units["raid" .. i]
                        if u then u.auras, u.auraSources = {}, {} end end end }
                for step = 1, 300 do
                    local where = ("seed %d, step %d"):format(seed, step)
                    actions[random.random(#actions)]()
                    if model then
                        assert.is_true(ns.BuffRules.RaidBlessingsChosen(), where .. ": forgotten within one raid")
                        total.kept = total.kept + 1
                        if unclear then total.keptUnreadable = total.keptUnreadable + 1 end
                        for hazard, on in pairs(hazards()) do
                            if on then keptWith[hazard] = keptWith[hazard] + 1 end
                        end
                        local cast = scroll()
                        if cast then
                            for _, b in ipairs(ns.BuffData.ClassBuffs()) do
                                for _, id in ipairs(b.ranks) do
                                    if id == cast.id and b.family == "blessing" then
                                        assert.is_true(model.keys[b.key] == true,
                                            where .. ": gave " .. b.key .. ", left to another paladin in this raid")
                                    end
                                end
                            end
                        end
                    end
                    assert.are.same({}, wow.errors, where)
                end
            end
            assert.is_true(total.chosen > 10, "choices: " .. total.chosen)
            assert.is_true(total.kept > 100, "looks with the choice kept: " .. total.kept)
            assert.is_true(total.keptThroughArena > 3, "choices kept through an arena: " .. total.keptThroughArena)
            assert.is_true(total.keptUnreadable > 10, "kept through looks that couldn't read: " .. total.keptUnreadable)
            for hazard, n in pairs(keptWith) do
                assert.is_true(n > 3, "kept with " .. hazard .. " unreadable: " .. n)
            end
            assert.is_true(total.forgot > 5, "other raids seen plainly: " .. total.forgot)
        end)
    end)
end)
