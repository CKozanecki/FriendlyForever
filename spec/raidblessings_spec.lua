-- Spec: #68
-- My Blessings in this raid (paladins): choose which of your Blessings you
-- give in the raid you're in, so two paladins don't both give Kings. The
-- choice is never saved and is forgotten once you're out of the raid.
-- Quick Never: Shift+right-click on a group buff puts that member on the
-- buff's Never list.
local wow = require("spec.support.wow")

local KINGS, MIGHT_1, WISDOM_1, SALVATION = 20217, 19740, 19742, 1038
local MOTW, MOTW_1 = 9885, 1126

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("My Blessings in this raid", function()
    local ns, button

    -- A paladin who knows Kings, Wisdom, Might and Salvation, in buff mode
    -- (unless opts.buffModeOff).
    local function boot(opts)
        opts = opts or {}
        wow.SPELL_NAMES[SALVATION] = "Blessing of Salvation"
        ns = wow.boot({ before = function(state)
            state.class = opts.class or "PALADIN"
            state.knownSpells = opts.known
                or { [KINGS] = true, [WISDOM_1] = true, [MIGHT_1] = true, [SALVATION] = true }
        end })
        button = ns.BuffButton.Frame()
        ns.db.buffBack.buffOrder = { "kings", "might", "wisdom", "salvation" }
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
    after_each(function() wow.SPELL_NAMES[SALVATION] = nil end)

    describe("choosing (white)", function()
        it("gives only the Blessings you chose, and Salvation as usual", function()
            group("raid", { "Ann-Vale", "Bo-Lake" })
            assert.is_true(ns.BuffRules.SetRaidBlessings({ "might" }))
            assert.is_true(ns.BuffRules.RaidBlessingsChosen())
            assert.are.equal("Ann Vale: Blessing of Might", armed(), "Kings is first in your order, but not yours here")
            assert.are.same({
                "Ann-Vale Blessing of Might", "Bo-Lake Blessing of Might",
                "Ann-Vale Blessing of Salvation", "Bo-Lake Blessing of Salvation",
            }, buffAll(), "Salvation isn't a Blessing")
            assert.are.same({}, wow.errors)
        end)

        it("passes over a Blessing left to others quietly: it isn't owed", function()
            group("raid", { "Ann-Vale" })
            ns.BuffRules.SetRaidBlessings({ "might" })
            ns.db.buffBack.buffOrder = { "kings", "might" }
            wow.state.units.raid1.auras, wow.state.units.raid1.auraSources = { MIGHT_1, SALVATION }, { "player", "player" }
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            local _, _, settled = ns.GroupBuffs.Next()
            assert.is_true(settled, "everyone has your buffs: Kings is someone else's")
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
            for key in pairs(ns.db.buffBack) do assert.is_falsy(key:lower():find("raid", 1, true), key) end
        end)

        it("is shown and changed on the Buff Back tab", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            local r = w.who
            assert.is_true(r.raidHeader:IsShown())
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
            assert.are.same({ "kings", "wisdom", "might" }, shown, "the Blessings you know, not Salvation")
            r.raidBlessings[1]:SetChecked(false)
            wow.run(r.raidBlessings[1], "OnClick")
            assert.is_true(ns.BuffRules.RaidBlessingsChosen())
            assert.is_false(ns.BuffRules.CoversInRaid(ns.BuffData.ByKey("kings")))
            assert.are.equal("Ann Vale: Blessing of Might", armed())
            slash("blessings all")
            assert.is_true(r.raidBlessings[1]:GetChecked(), "the slash command shows in the panel")
        end)

        it("isn't on the Buff Back tab for classes without Blessings", function()
            boot({ class = "DRUID", known = { [MOTW_1] = true, [MOTW] = true } })
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            assert.is_false(w.who.raidHeader:IsShown())
            for _, cb in ipairs(w.who.raidBlessings) do assert.is_false(cb:IsShown()) end
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

        it("counts an unreadable raid answer as not in a raid", function()
            group("raid", { "Ann-Vale" })
            ns.BuffRules.SetRaidBlessings({ "might" })
            local real = _G.IsInRaid
            _G.IsInRaid = function() return wow.secret(true) end
            assert.is_false(ns.BuffRules.RaidBlessingsChosen())
            assert.are.same({ false, "you're not in a raid" }, { ns.BuffRules.SetRaidBlessings({ "might" }) })
            _G.IsInRaid = function() error("no") end
            assert.is_false(ns.BuffRules.SetRaidBlessings({ "might" }))
            _G.IsInRaid = real
            assert.is_false(ns.BuffRules.RaidBlessingsChosen(), "still forgotten when it reads again")
        end)

        it("refuses names that aren't your Blessings, and leaves the choice as it was", function()
            group("raid", { "Ann-Vale" })
            ns.BuffRules.SetRaidBlessings({ "might" })
            assert.are.same({ false, "'salvation' isn't one of your Blessings" },
                { ns.BuffRules.SetRaidBlessings({ "kings", "salvation" }) })
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
            wow.run(w.tabs.buffBack, "OnClick")
            for _, cb in ipairs(w.who.raidBlessings) do cb:SetChecked(false) end
            wow.run(w.who.raidBlessings[1], "OnClick")
            assert.is_truthy(lastPrinted():find("choose at least one Blessing", 1, true))
            assert.is_true(w.who.raidBlessings[1]:GetChecked(), "back to all")
        end)

        it("says your class has no Blessings", function()
            boot({ class = "DRUID", known = { [MOTW_1] = true, [MOTW] = true } })
            group("raid", { "Ann-Vale" })
            slash("blessings might")
            assert.are.equal("blessings: your class has no Blessings.", lastPrinted():match("blessings:.*"))
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
            assert.are.equal("Ann Vale won't get Blessing of Kings (Never list, on the Buff Back tab).",
                button.result:GetText())
            assert.are.equal("Ann-Vale", ns.db.buffBack.whoGets.kings.never["ann-vale"])
            assert.are.equal("Bo Lake: Blessing of Kings", armed())
            assert.are.same({
                "Bo-Lake Blessing of Kings", "Ann-Vale Blessing of Might",
                "Ann-Vale Blessing of Salvation", "Bo-Lake Blessing of Salvation",
            }, buffAll(), "only that buff: Ann still gets the next Blessing")
        end)

        it("names the buff it was, though the button moves on to another", function()
            group("party", { "Ann-Vale" })
            wow.press(button, "RightButton", { shift = true })
            assert.are.equal("Ann Vale won't get Blessing of Kings (Never list, on the Buff Back tab).",
                button.result:GetText())
            assert.are.equal("Ann Vale: Blessing of Might", armed())
            wow.state.units.party1.auras = { MIGHT_1, SALVATION }
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            ns.BuffRules.SetNames("kings", "never", "")
            ns.BuffButton.Refresh()
            assert.is_nil(macro(), "they wear your Might: Kings would replace it")
            wow.state.units.party1.auras = { SALVATION }
            ns.BuffRules.SetNames("kings", "never", "Ann Vale")
            ns.BuffButton.Refresh()
            wow.press(button, "RightButton", { shift = true }) -- Might, the last thing shown
            assert.are.same({}, wow.errors, "nothing left to show afterwards")
            assert.is_nil(macro())
        end)

        it("keeps the names already on the list, and shows the new one in the panel", function()
            assert.is_true(ns.BuffRules.SetNames("kings", "never", "Cid Rock"))
            group("party", { "Ann-Vale" })
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            wow.press(button, "RightButton", { shift = true })
            assert.are.equal("Ann Vale, Cid Rock", ns.BuffRules.NamesText("kings", "never"))
            assert.are.equal("Ann Vale, Cid Rock", w.who.never:GetText(), "the panel shows it")
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

        it("on Revoke skips the member instead: Never wouldn't take Salvation off", function()
            boot({ known = { [KINGS] = true, [SALVATION] = true, [wow.REVOKE_ID] = true } })
            group("party", { "Ann-Vale" })
            wow.state.units.party1.role = "TANK"
            wow.state.units.party1.auras, wow.state.units.party1.auraSources = { SALVATION }, { "player" }
            ns.BuffButton.Refresh()
            assert.are.equal("Ann Vale: Revoke", armed())
            wow.press(button, "RightButton", { shift = true })
            assert.are.equal("", ns.BuffRules.NamesText("salvation", "never"))
            assert.are.equal("Skipping Ann Vale for 5 minutes.", button.result:GetText())
        end)
    end)

    describe("chaos (red tests)", function()
        it("never gives a Blessing you left to others, nor any buff to someone on its Never list", function()
            local blessed, skippedByChoice = 0, 0
            for _, seed in ipairs({ 3, 68, 451, 2026 }) do
                math.randomseed(seed)
                boot()
                local everyone = { "Ann-Vale", "Bo-Lake", "Cid-Rock", "Dot-Fern", "Eve-Moss" }
                local keys = { "kings", "wisdom", "might", "light", "salvation", "motw" }
                -- What we expect the choice to be: nil (all) or [key] = true.
                local model
                local function inRaid() return wow.state.groupType == "raid" end
                local function regroup()
                    local r = math.random()
                    local members = {}
                    for _, name in ipairs(everyone) do if math.random() < 0.7 then members[#members + 1] = name end end
                    if #members == 0 then members[1] = everyone[1] end
                    if r < 0.15 then
                        solo()
                    else
                        group(r < 0.65 and "raid" or "party", members,
                            { "MAGE", "ROGUE", "MAGE", "WARRIOR", "PRIEST" })
                    end
                    if not inRaid() then model = nil end
                end
                regroup()
                local actions = {
                    regroup,
                    function()
                        local pick = {}
                        for _, key in ipairs(keys) do if math.random() < 0.4 then pick[#pick + 1] = key end end
                        local ok = ns.BuffRules.SetRaidBlessings(pick)
                        if ok then
                            local set, n = {}, 0
                            for _, k in ipairs(pick) do if not set[k] then n = n + 1 end set[k] = true end
                            model = n < 3 and set or nil -- you know three
                        end
                    end,
                    function()
                        slash(math.random() < 0.5 and "blessings all" or "blessings might")
                        if inRaid() then
                            local all = lastPrinted():find("all: you haven't chosen", 1, true)
                            if all then model = nil else model = { might = true } end
                        end
                    end,
                    function()
                        local name = everyone[math.random(#everyone)]
                        ns.BuffRules.SetNames(keys[math.random(5)], "never",
                            math.random() < 0.3 and "" or name:gsub("%-", " "))
                    end,
                    function() wow.press(button, "RightButton", { shift = math.random() < 0.6 }) end,
                    function() wow.advance(math.random() * 400) end,
                    function()
                        -- A buff wears off someone.
                        for token, u in pairs(wow.state.units) do
                            if (token:find("^raid") or token:find("^party")) and u.auras and #u.auras > 0
                                and math.random() < 0.3 then
                                table.remove(u.auras, 1)
                                if u.auraSources then table.remove(u.auraSources, 1) end
                            end
                        end
                        ns.BuffButton.Refresh()
                    end,
                }
                for step = 1, 400 do
                    local where = ("seed %d, step %d"):format(seed, step)
                    local pick = math.random(#actions)
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
    end)
end)
