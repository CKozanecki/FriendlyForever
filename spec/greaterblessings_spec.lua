-- Spec: #41, #233, #256
-- Greater Blessings in buff mode (Kings, Wisdom, Might): in a raid, a
-- paladin is offered the Greater Blessing for a class when enough of that
-- class are missing the Blessing, they all can have it under your rules, and
-- none of them wears a different Blessing of yours (it would replace it).
-- Never aimed at someone the safety rules skip, never flagging you for PvP.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local ITEM = wow.ITEM
local KINGS, GREATER_KINGS = 20217, 25898
local WISDOM_6, WISDOM_5, GREATER_WISDOM_2, GREATER_WISDOM_1 = 25290, 19854, 25918, 25894
local MIGHT_7, MIGHT_6, GREATER_MIGHT_2, GREATER_MIGHT_1 = 25291, 19838, 25916, 25782
local MIGHT_1 = 19740

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Greater Blessings in buff mode (#41)", function()
    local ns, button

    -- A paladin who knows Kings and Greater Blessing of Kings (more with
    -- opts.known), with Symbols of Kings, in buff mode. opts.defaults: keep
    -- the shipped who-gets-it rules for Wisdom and Might (#219).
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, buffDefaults = opts.defaults, before = function(state)
            state.class = "PALADIN"
            state.knownSpells = {}
            for _, id in ipairs(opts.known or { KINGS, GREATER_KINGS }) do state.knownSpells[id] = true end
            state.items = opts.items or { [ITEM.symbolOfKings] = 10 }
        end })
        button = ns.BuffButton.Frame()
        slash("buffmode on")
    end

    -- A raid of { name, class } pairs, in raid slots 1..n, all in one subgroup.
    local function raid(members)
        local names = {}
        for i, m in ipairs(members) do names[i] = m[1] end
        wow.setGroup("raid", names)
        for i, m in ipairs(members) do wow.state.units["raid" .. i].class = m[2] end
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    local function armed()
        ns.BuffButton.Refresh()
        local text = macro()
        if not text then return nil end
        local self = text:match("/cast %[@player,nodead%] ([^\n]+)")
        if self then return "me: " .. self end
        return text:match("/targetexact ([^\n]+)") .. ": " .. text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    local WARRIORS = {
        { "Ann-Vale", "WARRIOR" }, { "Bo-Fern", "WARRIOR" }, { "Cid-Rock", "WARRIOR" },
        { "Dot-Moss", "WARRIOR" }, { "Eve-Hill", "WARRIOR" }, { "Fay-Reed", "WARRIOR" },
    }

    -- Tokens of a class's members, in raid order.
    local function tokensOf(class)
        local out = {}
        for i = 1, 40 do
            local u = wow.state.units["raid" .. i]
            if u and u.class == class then out[#out + 1] = "raid" .. i end
        end
        return out
    end

    describe("offered for a class in a raid (white)", function()
        it("offers Greater Blessing of Kings on the class with enough missing, and a press casts it", function()
            boot()
            raid(WARRIORS)
            assert.are.equal("Ann Vale: Greater Blessing of Kings", armed())
            assert.are.equal("Warriors (6 missing)", button.title:GetText())
            assert.are.equal("Greater Blessing of Kings", button.subtitle:GetText())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(1, #wow.casts)
            assert.are.equal(GREATER_KINGS, wow.casts[1].id)
            assert.are.same({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed" },
                wow.casts[1].covered)
            assert.are.equal(9, wow.state.items[ITEM.symbolOfKings], "one Symbol used")
            assert.is_nil(armed(), "every warrior has Kings now")
        end)

        it("covers only the target's class, and aims at the class with the most missing", function()
            boot()
            raid({ { "Ann-Vale", "MAGE" }, { "Bo-Fern", "WARRIOR" }, { "Cid-Rock", "WARRIOR" },
                { "Dot-Moss", "WARRIOR" }, { "Eve-Hill", "MAGE" }, { "Fay-Reed", "MAGE" },
                { "Gus-Lane", "WARRIOR" }, { "Hal-Pine", "ROGUE" } })
            assert.are.equal("Bo Fern: Greater Blessing of Kings", armed())
            assert.are.equal("Warriors (4 missing)", button.title:GetText())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.same({ "Bo-Fern", "Cid-Rock", "Dot-Moss", "Gus-Lane" }, wow.casts[1].covered)
            assert.are.equal("Mages (3 missing)", button.title:GetText(), "the mages next")
        end)

        it("offers the single Blessing when too few of a class are missing it, saying so", function()
            boot()
            raid({ { "Ann-Vale", "WARRIOR" }, { "Bo-Fern", "WARRIOR" } })
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            assert.are.equal("Only 2 missing, Greater Blessing of Kings needs 3: buffing one at a time",
                button.subtitle:GetText())
            -- Enough missing in all, but not enough of any one class.
            raid({ { "Ann-Vale", "WARRIOR" }, { "Bo-Fern", "WARRIOR" }, { "Cid-Rock", "MAGE" } })
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            assert.are.equal("Not enough in one group: buffing one at a time", button.subtitle:GetText())
        end)

        it("is for raids only: in a party the single Blessing is offered, with no note", function()
            boot()
            wow.setGroup("party", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
            for i = 1, 4 do wow.state.units["party" .. i].class = "WARRIOR" end
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            assert.are.equal("missing your Blessing of Kings", button.subtitle:GetText())
        end)

        it("offers Greater Blessing of Wisdom on mages and of Might on warriors, with the highest rank known", function()
            boot({ known = { WISDOM_6, WISDOM_5, GREATER_WISDOM_2, GREATER_WISDOM_1, MIGHT_7, MIGHT_6,
                GREATER_MIGHT_2, GREATER_MIGHT_1 } })
            raid({ { "Ann-Vale", "MAGE" }, { "Bo-Fern", "MAGE" }, { "Cid-Rock", "MAGE" },
                { "Dot-Moss", "WARRIOR" }, { "Eve-Hill", "WARRIOR" }, { "Fay-Reed", "WARRIOR" } })
            -- Your first buff goes to everyone before your second goes to anyone:
            -- Wisdom (the mages), then Might (the warriors).
            assert.are.equal("Ann Vale: Greater Blessing of Wisdom", armed())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(GREATER_WISDOM_2, wow.casts[1].id)
            assert.are.equal("Dot Moss: Greater Blessing of Might", armed())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(GREATER_MIGHT_2, wow.casts[2].id)
        end)

        -- #233: a paladin who knows both Greater ranks casts the higher one, and
        -- the data lists them highest first (BuffData takes the first known).
        local RANK_CASES = {
            { key = "kings", name = "Kings", class = "WARRIOR", highest = { 25898 },
                known = { KINGS, GREATER_KINGS } },
            { key = "wisdom", name = "Wisdom", class = "MAGE", highest = { GREATER_WISDOM_2, GREATER_WISDOM_1 },
                known = { WISDOM_6, WISDOM_5, GREATER_WISDOM_1, GREATER_WISDOM_2 } },
            { key = "might", name = "Might", class = "WARRIOR", highest = { GREATER_MIGHT_2, GREATER_MIGHT_1 },
                known = { MIGHT_7, MIGHT_6, GREATER_MIGHT_1, GREATER_MIGHT_2 } },
        }
        for _, case in ipairs(RANK_CASES) do
            it("Greater Blessing of " .. case.name .. ": the data lists the ranks highest first, and the highest known is cast", function()
                boot({ known = case.known })
                local buff = ns.BuffData.ByKey(case.key)
                assert.are.equal(#case.highest, #buff.groupCast.spells)
                for i, id in ipairs(case.highest) do
                    assert.are.equal(id, buff.groupCast.spells[i].id, "groupCast rank " .. i)
                    assert.are.equal(id, buff.group[i], "group rank " .. i)
                end
                raid({ { "Ann-Vale", case.class }, { "Bo-Fern", case.class }, { "Cid-Rock", case.class } })
                assert.are.equal("Ann Vale: Greater Blessing of " .. case.name, armed())
                wow.pressKey("MOUSEWHEELUP")
                assert.are.equal(case.highest[1], wow.casts[1].id)
            end)
        end

        it("follows 'Use group versions' and a Blessing of yours that is the same one is renewed", function()
            boot()
            raid(WARRIORS)
            for _, token in ipairs(tokensOf("WARRIOR")) do
                wow.wearBuff(token, KINGS, { source = "player" })
                wow.state.units[token].auraExpires[1] = wow.now + 60
            end
            -- Kings running low on all six: the Greater Blessing renews them.
            assert.are.equal("Ann Vale: Greater Blessing of Kings", armed())
            ns.db.buffBack.groupVersions = false
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
        end)

        it("right-click leaves that class out of the Greater Blessing for 5 minutes", function()
            boot()
            raid(WARRIORS)
            armed()
            wow.press(button, "RightButton")
            assert.are.equal("Skipping Greater Blessing of Kings on Warriors for 5 minutes.",
                button.result:GetText())
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            wow.advance(301)
            assert.are.equal("Ann Vale: Greater Blessing of Kings", armed())
        end)

        it("counts you in the class you belong to, and never aims at you", function()
            boot()
            raid({ { "Ann-Vale", "PALADIN" }, { "Bo-Fern", "PALADIN" }, { "Cid-Rock", "PALADIN" } })
            wow.addUnit("raid4", wow.state.units.player)
            wow.state.units.player.class = "PALADIN"
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.are.equal("Ann Vale: Greater Blessing of Kings", armed())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.same({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Me" }, wow.casts[1].covered)
        end)
    end)

    describe("never makes things worse (black)", function()
        it("is not offered when a class member wears a different Blessing of yours", function()
            boot()
            raid(WARRIORS)
            wow.wearBuff("raid3", MIGHT_1, { source = "player" })
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            assert.are.equal("Cid Rock wears your Blessing of Might, which it would replace: buffing one at a time",
                button.subtitle:GetText())
        end)

        it("is still offered when the different Blessing is another paladin's", function()
            boot()
            raid(WARRIORS)
            wow.wearBuff("raid3", MIGHT_1, { source = "raid1" })
            assert.are.equal("Ann Vale: Greater Blessing of Kings", armed())
        end)

        it("is not offered when whose Blessing it is can't be told", function()
            boot()
            raid(WARRIORS)
            wow.wearBuff("raid3", MIGHT_1, { source = wow.secret("raid1") }) -- a caster given as a secret
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            assert.is_truthy(button.subtitle:GetText():find("can't tell whose Blessing", 1, true))
        end)

        it("a Blessing whose caster the game doesn't name is someone else's, not yours (#256)", function()
            boot()
            raid(WARRIORS)
            wow.wearBuff("raid3", MIGHT_1, { source = false })
            assert.are.equal("Ann Vale: Greater Blessing of Kings", armed())
        end)

        it("is not offered when whose Blessing it is can't be told (the game won't say if the caster is you)", function()
            boot()
            raid(WARRIORS)
            wow.wearBuff("raid3", MIGHT_1, { source = "player" })
            _G.UnitIsUnit = function() return nil end
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            assert.is_truthy(button.subtitle:GetText():find("can't tell whose Blessing", 1, true))
        end)

        it("Greater Wisdom rank 1 matches Wisdom rank 5: rank 6 of yours is higher, rank 5 is not; rank 2 matches rank 6", function()
            boot({ known = { WISDOM_6, WISDOM_5, GREATER_WISDOM_2, GREATER_WISDOM_1 } })
            raid({ { "Ann-Vale", "MAGE" }, { "Bo-Fern", "MAGE" }, { "Cid-Rock", "MAGE" }, { "Dot-Moss", "MAGE" } })
            -- Rank 2 matches rank 6: a Wisdom rank 6 of yours running low is renewed by it.
            wow.wearBuff("raid4", WISDOM_6, { source = "player" })
            wow.state.units.raid4.auraExpires[1] = wow.now + 60
            assert.are.equal("Ann Vale: Greater Blessing of Wisdom", armed())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(GREATER_WISDOM_2, wow.casts[1].id)
            -- Knowing rank 1 only: rank 6 of yours is higher, rank 5 is not.
            boot({ known = { WISDOM_6, WISDOM_5, GREATER_WISDOM_1 } })
            raid({ { "Ann-Vale", "MAGE" }, { "Bo-Fern", "MAGE" }, { "Cid-Rock", "MAGE" }, { "Dot-Moss", "MAGE" } })
            wow.wearBuff("raid4", WISDOM_5, { source = "player" })
            wow.state.units.raid4.auraExpires[1] = wow.now + 60
            assert.are.equal("Ann Vale: Greater Blessing of Wisdom", armed(), "an equal rank may be renewed")
            wow.wearBuff("raid4", WISDOM_6, { source = "player" })
            wow.state.units.raid4.auraExpires[1] = wow.now + 60
            wow.state.units.raid4.auras = { WISDOM_6 }
            assert.are.equal("Ann Vale: Blessing of Wisdom", armed())
        end)

        it("is not offered when a class member's buffs can't be read", function()
            boot()
            raid(WARRIORS)
            wow.wearBuff("raid4", MIGHT_1, { source = "raid1" })
            wow.state.units.raid4.secrets = { auras = true }
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            assert.is_truthy(button.subtitle:GetText():find("can't tell whose Blessing", 1, true))
        end)

        it("is not offered when your rules leave one of the class out (Never)", function()
            boot()
            raid(WARRIORS)
            assert.is_true(ns.BuffRules.SetNames("kings", "never", "Fay Reed"))
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            assert.is_truthy(button.subtitle:GetText():find("your rules leave Fay Reed out", 1, true))
        end)

        it("never puts Might on a class your default rule excludes, even with one of them named Always", function()
            boot({ defaults = true, known = { MIGHT_7, MIGHT_6, GREATER_MIGHT_2, GREATER_MIGHT_1 } })
            raid({ { "Ann-Vale", "MAGE" }, { "Bo-Fern", "MAGE" }, { "Cid-Rock", "MAGE" } })
            ns.db.buffBack.groupEnough = 1
            assert.is_true(ns.BuffRules.SetNames("might", "always", "Ann Vale"))
            -- Ann is allowed, so she is offered Might alone; the Greater Blessing
            -- would reach the other mages, whom the default rule leaves out.
            assert.are.equal("Ann Vale: Blessing of Might", armed())
            assert.is_truthy(button.subtitle:GetText():find("your rules leave", 1, true))
        end)

        it("is never offered with 'tanks only': the single Blessing goes to each tank", function()
            boot()
            raid(WARRIORS)
            ns.db.buffBack.whoGets = { kings = { rule = "tanks" } }
            for _, token in ipairs(tokensOf("WARRIOR")) do wow.state.units[token].role = "TANK" end
            assert.are.equal("Ann Vale: Blessing of Kings", armed(), "even when every warrior is a tank")
            assert.are.equal("missing your Blessing of Kings", button.subtitle:GetText(), "and no note")
            ns.db.buffBack.whoGets = { kings = { rule = "notTanks" } }
            for _, token in ipairs(tokensOf("WARRIOR")) do wow.state.units[token].role = "DAMAGER" end
            assert.are.equal("Ann Vale: Greater Blessing of Kings", armed(), "other rules still allow it")
        end)

        it("is not offered with no Symbol of Kings, or when the count can't be read", function()
            boot({ items = {} })
            raid(WARRIORS)
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            assert.are.equal("No Symbol of Kings: buffing one at a time", button.subtitle:GetText())
            boot({ items = { [ITEM.symbolOfKings] = 3 } })
            raid(WARRIORS)
            wow.state.itemsSecret = true
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            assert.are.equal("Can't count your Symbol of Kings: buffing one at a time", button.subtitle:GetText())
        end)

        it("is not offered when a class member is flagged for PvP and you aren't, or their flag can't be read", function()
            boot()
            raid(WARRIORS)
            wow.state.units.raid6.pvp = true
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            assert.is_truthy(button.subtitle:GetText():find("is flagged for PvP", 1, true))
            wow.state.units.raid6.pvp = false
            wow.state.units.raid6.secrets = { pvp = true }
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            wow.state.units.raid6.secrets = nil
            wow.state.pvp = true
            wow.state.units.raid6.pvp = true
            assert.are.equal("Ann Vale: Greater Blessing of Kings", armed(), "flagged yourself: nothing to lose")
        end)

        it("is not offered when a raid member's class can't be read", function()
            boot()
            raid(WARRIORS)
            wow.state.units.raid2.secrets = { class = true }
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            assert.are.equal("can't read a group member's class: buffing one at a time", button.subtitle:GetText())
            wow.state.units.raid2.secrets = nil
            wow.state.units.raid2.class = "GNOME"
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
        end)

        it("never replaces a higher rank of the Blessing that you gave", function()
            -- You know rank 1 of Greater Wisdom only: it matches Wisdom rank 5.
            boot({ known = { WISDOM_6, WISDOM_5, GREATER_WISDOM_1 } })
            raid({ { "Ann-Vale", "MAGE" }, { "Bo-Fern", "MAGE" }, { "Cid-Rock", "MAGE" }, { "Dot-Moss", "MAGE" } })
            assert.are.equal("Ann Vale: Greater Blessing of Wisdom", armed())
            wow.wearBuff("raid4", WISDOM_6, { source = "player" })
            assert.are.equal("Ann Vale: Blessing of Wisdom", armed())
            assert.is_truthy(button.subtitle:GetText():find("a higher rank of yours", 1, true), button.subtitle:GetText())
        end)

        it("Greater Might rank 1 matches Might rank 6: rank 7 of yours is higher, rank 6 is not", function()
            boot({ known = { MIGHT_7, MIGHT_6, GREATER_MIGHT_1 } })
            raid({ { "Ann-Vale", "WARRIOR" }, { "Bo-Fern", "WARRIOR" }, { "Cid-Rock", "WARRIOR" },
                { "Dot-Moss", "WARRIOR" } })
            wow.wearBuff("raid4", MIGHT_6, { source = "player" })
            wow.state.units.raid4.auraExpires[1] = wow.now + 60 -- running low
            assert.are.equal("Ann Vale: Greater Blessing of Might", armed(), "an equal rank may be renewed")
            wow.wearBuff("raid4", MIGHT_7, { source = "player" })
            wow.state.units.raid4.auraExpires[1] = wow.now + 60
            wow.state.units.raid4.auras = { MIGHT_7 }
            assert.are.equal("Ann Vale: Blessing of Might", armed())
            assert.is_truthy(button.subtitle:GetText():find("a higher rank of yours", 1, true))
        end)

        it("a paladin who hasn't learned the Greater Blessing is offered the single one, with the reason in the tooltip only", function()
            boot({ known = { KINGS } })
            raid(WARRIORS)
            assert.are.equal("Ann Vale: Blessing of Kings", armed())
            assert.are.equal("missing your Blessing of Kings", button.subtitle:GetText(), "nothing on the face")
            wow.run(button, "OnEnter")
            assert.is_truthy(table.concat(_G.GameTooltip.lines, "\n"):find(
                "You haven't learned Greater Blessing of Kings: buffing one at a time", 1, true))
        end)
    end)

    describe("chaos (red tests)", function()
        it("a storm never offers a Greater Blessing that replaces a Blessing, reaches a class a rule excludes, or flags you", function()
            local CLASSES = { "WARRIOR", "MAGE", "ROGUE", "PRIEST", "WARLOCK", "DRUID" }
            -- Every rank of every Blessing, by the Blessing's name, from the game's own tables:
            -- written out here, not read from the addon.
            local KEY_OF = {}
            for _, id in ipairs({ 20217, 25898 }) do KEY_OF[id] = "kings" end
            for _, id in ipairs({ 25290, 19854, 19853, 19852, 19850, 19742, 25918, 25894 }) do KEY_OF[id] = "wisdom" end
            for _, id in ipairs({ 25291, 19838, 19837, 19836, 19835, 19834, 19740, 25916, 25782 }) do
                KEY_OF[id] = "might"
            end
            local CAST_KEY = { [25898] = "kings", [25918] = "wisdom", [25894] = "wisdom", [25916] = "might",
                [25782] = "might" }
            -- The shipped rules (#219), written out here: classes that don't get the Blessing.
            local EXCLUDED = {
                wisdom = { ROGUE = true, WARRIOR = true },
                might = { WARLOCK = true, MAGE = true, PRIEST = true },
            }
            local EVERY = { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed", "Gus-Lane",
                "Hal-Pine", "Ivy-Cole", "Jon-Dale", "Kay-Wood", "Lee-Frost" }
            local group, singles = 0, 0
            local reached = { blessing = 0, never = 0, flag = 0 }
            for _, seed in ipairs({ 5, 41, 311, 2026, 8888 }) do
                random.seed(seed)
                boot({ defaults = true, known = { KINGS, GREATER_KINGS, WISDOM_6, GREATER_WISDOM_2, MIGHT_7,
                    GREATER_MIGHT_2 }, items = { [ITEM.symbolOfKings] = 6 } })
                wow.state.groupBuffSeconds = 30
                local inGroup, neverNames = {}, {}
                local function setup(count)
                    local names = {}
                    for i = 1, count do names[i] = EVERY[i] end
                    wow.setGroup("raid", names)
                    inGroup = {}
                    for i, n in ipairs(names) do
                        inGroup[n] = true
                        wow.state.units["raid" .. i].class = CLASSES[random.random(3)]
                    end
                    wow.fire("GROUP_ROSTER_UPDATE")
                end
                local function tokens()
                    local out = {}
                    for i = 1, 40 do if wow.state.units["raid" .. i] then out[#out + 1] = "raid" .. i end end
                    return out
                end
                local function someone()
                    local list = tokens()
                    return list[random.random(math.max(#list, 1))]
                end
                local function clear()
                    for _, token in ipairs(tokens()) do
                        local u = wow.state.units[token]
                        u.auras, u.auraSources, u.auraDurations, u.auraExpires = nil, nil, nil, nil
                        u.pvp, u.dead, u.offline, u.outOfRange, u.hidden, u.secrets = nil, nil, nil, nil, nil, nil
                    end
                    wow.state.pvp = false
                    ns.BuffRules.SetNames("kings", "never", "")
                    neverNames = {}
                end
                -- A raid of 9 in three classes with the Blessing missing on all of them, then one thing in the way.
                local function scenario(kind)
                    setup(9)
                    clear()
                    wow.state.items[ITEM.symbolOfKings] = 6
                    wow.state.itemsSecret = false
                    ns.db.buffBack.groupVersions = true
                    ns.db.buffBack.groupEnough = 2
                    local t = someone()
                    if kind == "blessing" then
                        wow.wearBuff(t, ({ 19740, 19742, 20217 })[random.random(3)],
                            { source = "player", duration = 3000 })
                    elseif kind == "never" then
                        local u = wow.state.units[t]
                        assert(ns.BuffRules.SetNames("kings", "never", u.name .. " " .. u.surname))
                        neverNames[u.id] = true
                    else
                        wow.state.units[t].pvp = true
                    end
                end
                local actions = {
                    function() setup(random.random(4, 12)) end,
                    function() local u = wow.state.units[someone()]; if u then u.pvp = random.random() < 0.25 end end,
                    function() local u = wow.state.units[someone()]; if u then u.dead = random.random() < 0.15 end end,
                    function() local u = wow.state.units[someone()]; if u then u.outOfRange = random.random() < 0.15 end end,
                    function()
                        local token = someone()
                        if token then
                            wow.wearBuff(token, ({ 20217, 19740, 19742, 25291, 25290 })[random.random(5)],
                                { source = random.random() < 0.7 and "player" or nil, duration = random.random(20, 90) })
                        end
                    end,
                    function() local u = wow.state.units[someone()]; if u then u.auras = nil end end,
                    function() local u = wow.state.units[someone()]; if u then u.class = CLASSES[random.random(#CLASSES)] end end,
                    function() wow.state.pvp = random.random() < 0.15 end,
                    function() wow.state.items[ITEM.symbolOfKings] = random.random(0, 3) end,
                    function() wow.state.itemsSecret = random.random() < 0.1 end,
                    function() ns.db.buffBack.groupEnough = random.random(1, 4) end,
                    function() wow.pressKey("MOUSEWHEELUP") end,
                    function() wow.pressKey("MOUSEWHEELUP") end,
                    function() wow.press(button, "RightButton") end,
                    function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                    function() wow.advance(random.random() * 15) end,
                }
                local function snapshot()
                    local now = {}
                    for _, token in ipairs(tokens()) do
                        local u = wow.state.units[token]
                        now[u.id] = { pvp = u.pvp, class = u.class }
                    end
                    return now
                end
                local function check(step, from, was, iAmFlagged)
                    for i = from + 1, #wow.casts do
                        local cast = wow.casts[i]
                        local where = ("seed %d, step %d: %s on %s"):format(seed, step, cast.spell, cast.target)
                        assert.is_truthy(inGroup[cast.target], where .. ", not in the group")
                        local key = CAST_KEY[cast.id]
                        if key and not cast.failed then
                            group = group + 1
                            for _, id in ipairs(cast.covered) do
                                local m = was[id]
                                assert.is_truthy(m, where .. ", covered " .. id .. " outside the group")
                                assert.is_true(iAmFlagged or not m.pvp, where .. ", flagged " .. id)
                                assert.is_falsy(key == "kings" and neverNames[id],
                                    where .. ", " .. id .. " is on the Never list")
                                assert.is_falsy(EXCLUDED[key] and EXCLUDED[key][m.class],
                                    where .. ", " .. id .. " (" .. tostring(m.class) .. ") is a class the rule excludes")
                                for at, spellId in ipairs(cast.before[id] or {}) do
                                    local other = KEY_OF[spellId]
                                    assert.is_false(other ~= nil and other ~= key
                                        and cast.beforeSources[id][at] == "player",
                                        where .. ", replaced " .. id .. "'s " .. tostring(other))
                                end
                            end
                        elseif not key then
                            singles = singles + 1
                        end
                    end
                    assert.are.same({}, wow.flaggedBy, ("seed %d, step %d: flagged for PvP"):format(seed, step))
                end
                setup(8)
                for step = 1, 500 do
                    local before = #wow.casts
                    local was = snapshot()
                    local iAmFlagged = wow.state.pvp
                    if step % 12 == 0 then
                        local kind = ({ "blessing", "never", "flag" })[step / 12 % 3 + 1]
                        scenario(kind)
                        reached[kind] = reached[kind] + 1
                        ns.BuffButton.Refresh()
                        local from = #wow.casts
                        wow.pressKey("MOUSEWHEELUP")
                        check(step, from, snapshot(), wow.state.pvp)
                        before = #wow.casts
                    else
                        actions[random.random(#actions)]()
                    end
                    check(step, before, was, iAmFlagged)
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
            assert.is_true(group > 5, "Greater Blessings cast: " .. group)
            assert.is_true(singles > 5, "single Blessings cast: " .. singles)
            for kind, n in pairs(reached) do assert.is_true(n >= 10, kind .. " scenarios: " .. n) end
        end)
    end)
end)
