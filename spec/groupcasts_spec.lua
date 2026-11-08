-- Spec: #41
-- Group versions in buff mode: Arcane Brilliance, the Prayers and Gift of the
-- Wild are offered before the single buff when you know them, carry the
-- reagent, and enough of the party (in a raid, the subgroup) is missing the
-- buff. Never aimed at a member the safety rules skip, never flagging you for
-- PvP, never against your rules; anything unreadable gives single buffs.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local ITEM = wow.ITEM
local INTELLECT, BRILLIANCE = 10157, 23028
local FORT_6, FORT_5, PRAYER_FORT_2, PRAYER_FORT_1 = 10938, 10937, 21564, 21562
local SPIRIT_4, PRAYER_SPIRIT = 27841, 27681
local SHADOW_3, PRAYER_SHADOW = 10958, 27683
local MOTW, GIFT_2, GIFT_1, MOTW_6 = 9885, 21850, 21849, 9884

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Group versions in buff mode (#41)", function()
    local ns, button

    -- opts.class, opts.known (spell IDs), opts.items ([item ID] = count),
    -- opts.db, opts.members (party names, default Ann, Bo, Cid, Dot).
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = opts.class or "MAGE"
            state.knownSpells = {}
            for _, id in ipairs(opts.known or { INTELLECT, BRILLIANCE }) do state.knownSpells[id] = true end
            state.items = opts.items or { [ITEM.arcanePowder] = 5 }
        end })
        button = ns.BuffButton.Frame()
        slash("buffmode on")
        wow.setGroup("party", opts.members or { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    -- What the armed button casts, and on whom, after a fresh look.
    local function armed()
        ns.BuffButton.Refresh()
        local text = macro()
        if not text then return nil end
        return text:match("/targetexact ([^\n]+)") .. ": " .. text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    local function raid(names)
        wow.setGroup("raid", names)
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    -- Everyone in the party/raid slots, in token order.
    local function tokens()
        local out = {}
        for token in pairs(wow.state.units) do
            if token:find("^party%d") or token:find("^raid%d") then out[#out + 1] = token end
        end
        table.sort(out, function(a, b)
            return tonumber(a:match("%d+")) < tonumber(b:match("%d+"))
        end)
        return out
    end

    describe("offered before the single buff (white)", function()
        it("offers Arcane Brilliance when 3 or more of the party are missing Intellect, and a press casts it", function()
            boot()
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
            assert.are.equal("Arcane Brilliance on your party (4 missing)", button.title:GetText())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(1, #wow.casts)
            local cast = wow.casts[1]
            assert.are.equal(BRILLIANCE, cast.id)
            assert.are.equal("Ann-Vale", cast.target)
            assert.are.same({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" }, cast.covered)
            assert.are.equal(4, wow.state.items[ITEM.arcanePowder], "one powder used")
            assert.are.equal("Cast Arcane Brilliance on your party.", button.result:GetText())
            -- Everyone has it now: nothing more is offered, not even singly.
            assert.is_nil(armed())
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
        end)

        it("counts everyone it covered as just given, though their buffs show a moment later", function()
            boot()
            wow.state.auraDelay = 3
            armed()
            wow.pressKey("MOUSEWHEELUP")
            assert.is_nil(armed(), "no single Intellect to Bo, Cid or Dot while it shows")
            wow.advance(4)
            assert.is_nil(armed(), "and it has shown")
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
        end)

        it("a group version's answer is never taken for a waiting single-target press", function()
            boot({ members = { "Ann-Vale", "Bo-Fern" } })
            wow.state.castLatency = 5
            armed()
            wow.pressKey("MOUSEWHEELUP")
            local text = button.result:GetText()
            wow.fire("UNIT_SPELLCAST_SUCCEEDED", "player", wow.lastCastGuid, BRILLIANCE)
            assert.are.equal(text, button.result:GetText(), "not the press's answer")
            wow.advance(6)
            assert.are.equal("Gave Arcane Intellect to Ann Vale.", button.result:GetText())
        end)

        it("forgets skipped groups once their time is up", function()
            boot()
            armed()
            wow.press(button, "RightButton")
            assert.are.equal(1, ns.GroupCasts.Remembered())
            wow.advance(301)
            ns.BuffButton.Refresh()
            assert.are.equal(0, ns.GroupCasts.Remembered())
        end)

        it("offers Arcane Intellect one by one with 2 missing, and says why", function()
            boot({ members = { "Ann-Vale", "Bo-Fern" } })
            assert.are.equal("Ann Vale: Arcane Intellect", armed())
            assert.are.equal("Only 2 missing, Arcane Brilliance needs 3: buffing one at a time",
                button.subtitle:GetText())
        end)

        it("counts only members who are missing it", function()
            boot()
            for _, token in ipairs({ "party1", "party2" }) do
                wow.wearBuff(token, INTELLECT, { source = "player" })
            end
            assert.are.equal("Cid Rock: Arcane Intellect", armed(), "2 left missing")
        end)

        it("offers Arcane Intellect, and says why, with no Arcane Powder", function()
            boot({ items = {} })
            assert.are.equal("Ann Vale: Arcane Intellect", armed())
            assert.are.equal("No Arcane Powder: buffing one at a time", button.subtitle:GetText())
            wow.state.items[ITEM.arcanePowder] = 1
            assert.are.equal("Ann Vale: Arcane Brilliance", armed(), "read at each refresh")
            wow.state.items[ITEM.arcanePowder] = 0
            assert.are.equal("Ann Vale: Arcane Intellect", armed())
        end)

        it("offers Arcane Intellect, and says why, when you haven't learned Arcane Brilliance", function()
            boot({ known = { INTELLECT } })
            assert.are.equal("Ann Vale: Arcane Intellect", armed())
            -- A long-lasting reason: in the tooltip, and the face keeps its usual line.
            assert.are.equal("missing your Arcane Intellect", button.subtitle:GetText())
            button:GetScript("OnEnter")(button)
            assert.is_truthy(table.concat(_G.GameTooltip.lines, "\n"):find(
                "You haven't learned Arcane Brilliance: buffing one at a time", 1, true))
        end)

        local CASES = {
            { name = "Prayer of Fortitude", class = "PRIEST", known = { FORT_6, PRAYER_FORT_2 },
                item = ITEM.sacredCandle, id = PRAYER_FORT_2, equals = FORT_6, single = "Power Word: Fortitude" },
            { name = "Prayer of Fortitude (rank 1, Holy Candle)", class = "PRIEST",
                known = { FORT_5, PRAYER_FORT_1 }, item = ITEM.holyCandle, id = PRAYER_FORT_1, equals = FORT_5,
                single = "Power Word: Fortitude", spell = "Prayer of Fortitude" },
            { name = "Prayer of Spirit", class = "PRIEST", known = { SPIRIT_4, PRAYER_SPIRIT },
                item = ITEM.sacredCandle, id = PRAYER_SPIRIT, equals = SPIRIT_4, single = "Divine Spirit" },
            { name = "Prayer of Shadow Protection", class = "PRIEST", known = { SHADOW_3, PRAYER_SHADOW },
                item = ITEM.sacredCandle, id = PRAYER_SHADOW, equals = SHADOW_3, single = "Shadow Protection" },
            { name = "Gift of the Wild", class = "DRUID", known = { MOTW, GIFT_2 },
                item = ITEM.wildThornroot, id = GIFT_2, equals = MOTW, single = "Mark of the Wild" },
            { name = "Gift of the Wild (rank 1, Wild Berries)", class = "DRUID", known = { MOTW_6, GIFT_1 },
                item = ITEM.wildBerries, id = GIFT_1, equals = MOTW_6, single = "Mark of the Wild", spell = "Gift of the Wild" },
        }
        for _, case in ipairs(CASES) do
            it(case.name .. ": offered with its own reagent, single without it", function()
                boot({ class = case.class, known = case.known, items = { [case.item] = 2 } })
                local group = case.spell or case.name
                assert.are.equal("Ann Vale: " .. group, armed())
                wow.pressKey("MOUSEWHEELUP")
                assert.are.equal(case.id, wow.casts[1].id)
                assert.are.equal(1, wow.state.items[case.item])
                -- Only the right reagent counts.
                boot({ class = case.class, known = case.known, items = { [case.item + 1] = 9, [case.item - 1] = 9 } })
                assert.are.equal("Ann Vale: " .. case.single, armed())
                assert.is_truthy(button.subtitle:GetText():find("^No "))
                -- A member wearing the single rank of the same strength (running low) is
                -- not wearing a higher one: the group version may renew it.
                boot({ class = case.class, known = case.known, items = { [case.item] = 2 } })
                wow.wearBuff("party4", case.equals, { source = "player", duration = 3600 })
                wow.state.units.party4.auraExpires[1] = wow.now + 60
                assert.are.equal("Ann Vale: " .. group, armed(), "equal rank, running low")
            end)
        end

        it("follows 'Use group versions' and the threshold", function()
            boot({ members = { "Ann-Vale", "Bo-Fern" } })
            ns.db.buffBack.groupEnough = 2
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
            ns.db.buffBack.groupEnough = 3
            assert.are.equal("Ann Vale: Arcane Intellect", armed())
            ns.db.buffBack.groupEnough = 1
            wow.setGroup("party", { "Ann-Vale" })
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.are.equal("Ann Vale: Arcane Brilliance", armed(), "1 is enough at 1")
            ns.db.buffBack.groupVersions = false
            assert.are.equal("Ann Vale: Arcane Intellect", armed())
            assert.are_not.equal("", button.subtitle:GetText())
            assert.is_nil(button.subtitle:GetText():find("buffing one at a time"), "off is the player's choice: no note")
        end)

        it("in a raid, aims at the subgroup with the most members missing it", function()
            boot()
            raid({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed", "Gus-Lane" })
            local groups = { 1, 3, 3, 3, 3, 1, 1 }
            for i, g in ipairs(groups) do wow.state.units["raid" .. i].subgroup = g end
            assert.are.equal("Bo Fern: Arcane Brilliance", armed())
            assert.are.equal("Arcane Brilliance on Group 3 (4 missing)", button.title:GetText())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.same({ "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill" }, wow.casts[1].covered)
            -- Group 1 has 3 missing: its turn next.
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
            assert.are.equal("Arcane Brilliance on Group 1 (3 missing)", button.title:GetText())
        end)

        it("in a raid, never counts members of other subgroups together", function()
            boot()
            raid({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
            for i = 1, 4 do wow.state.units["raid" .. i].subgroup = i end
            assert.are.equal("Ann Vale: Arcane Intellect", armed())
            assert.are.equal("Not enough in one group: buffing one at a time", button.subtitle:GetText())
        end)

        it("right-click leaves that group out for 5 minutes, singles still offered", function()
            boot()
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
            wow.press(button, "RightButton")
            assert.are.equal("Ann Vale: Arcane Intellect", armed())
            assert.is_truthy(button.subtitle:GetText():find("You skipped your party", 1, true))
            wow.advance(299)
            assert.are.equal("Ann Vale: Arcane Intellect", armed())
            wow.advance(2)
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
        end)

        it("shift+right-click on a group cast adds nobody to a Never list", function()
            boot()
            armed()
            wow.state.mods = { shift = true }
            wow.press(button, "RightButton")
            wow.state.mods = {}
            assert.are.same({}, ns.db.buffBack.whoGets)
            assert.are.equal("Ann Vale: Arcane Intellect", armed())
        end)

        it("fills in a member the group cast didn't reach, one by one afterwards", function()
            boot()
            armed()
            -- Dot walks out of range as the cast goes out: the game doesn't cover them.
            wow.state.units.party4.outOfRange = true
            ns.BuffButton.Refresh() -- (Dot is no longer a candidate)
            wow.pressKey("MOUSEWHEELUP")
            assert.are.same({ "Ann-Vale", "Bo-Fern", "Cid-Rock" }, wow.casts[1].covered)
            wow.state.units.party4.outOfRange = false
            wow.advance(11)
            assert.are.equal("Dot Moss: Arcane Intellect", armed())
        end)

        it("a hand-cast group version isn't taken for the button's press, nor a favour", function()
            boot()
            armed()
            assert.are.equal(BRILLIANCE, ns.BuffData.KnownGroupCast(ns.BuffData.ByKey("intellect")).id)
            assert.is_nil(ns.BuffData.ForCast(BRILLIANCE), "the single-target lookup is unchanged")
            assert.are.equal(ns.BuffData.ByKey("intellect"), ns.BuffData.ForGroupCast(BRILLIANCE))
            assert.is_nil(ns.BuffData.ForGroupCast(INTELLECT))
        end)
    end)

    describe("falls back to single buffs when it can't tell (black)", function()
        it("an unreadable reagent count counts as missing, saying so", function()
            for label, setup in pairs({
                secret = function() wow.state.itemsSecret = true end,
                gone = function() _G.GetItemCount, _G.C_Item = nil, nil end,
                string = function() _G.GetItemCount = function() return "five" end; _G.C_Item = nil end,
                nan = function() _G.GetItemCount = function() return 0 / 0 end; _G.C_Item = nil end,
                throws = function() _G.GetItemCount = function() error("boom") end; _G.C_Item = nil end,
            }) do
                boot()
                setup()
                assert.are.equal("Ann Vale: Arcane Intellect", armed(), label)
                assert.are.equal("Can't count your Arcane Powder: buffing one at a time",
                    button.subtitle:GetText(), label)
            end
        end)

        it("an unreadable subgroup in a raid gives single buffs, saying so", function()
            local names = { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" }
            for label, setup in pairs({
                secret = function() wow.state.units.raid2.secrets = { subgroup = true } end,
                gone = function() _G.GetRaidRosterInfo = nil end,
                zero = function() wow.state.units.raid2.subgroup = 0 end,
                nine = function() wow.state.units.raid2.subgroup = 9 end,
                fraction = function() wow.state.units.raid2.subgroup = 1.5 end,
                string = function() wow.state.units.raid2.subgroup = "1" end,
                rosterSecret = function() wow.state.rosterSecret = true end,
            }) do
                boot()
                raid(names)
                setup()
                assert.are.equal("Ann Vale: Arcane Intellect", armed(), label)
                assert.are.equal("can't read the raid's subgroups: buffing one at a time",
                    button.subtitle:GetText(), label)
            end
        end)

        it("a member flagged for PvP anywhere in the covered group stops it, unless you are flagged", function()
            boot({ members = { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" } })
            -- Dot is flagged: skipped as a target, and the group cast would flag you.
            wow.state.units.party4.pvp = true
            assert.are.equal("Ann Vale: Arcane Intellect", armed())
            assert.is_truthy(button.subtitle:GetText():find("Dot Moss is flagged for PvP and you aren't", 1, true))
            wow.state.pvp = true
            assert.are.equal("Ann Vale: Arcane Brilliance", armed(), "flagged yourself: nothing to lose")
        end)

        it("a flagged member who already has the buff, or is out of range, still stops it", function()
            boot()
            wow.wearBuff("party4", INTELLECT, { source = "player" })
            wow.state.units.party4.pvp = true
            -- Only 3 are missing, and the group cast would reach the flagged Dot too.
            assert.are.equal("Ann Vale: Arcane Intellect", armed())
            wow.state.units.party4.pvp = false
            wow.state.units.party4.outOfRange = true
            wow.state.units.party4.pvp = true
            assert.are.equal("Ann Vale: Arcane Intellect", armed(), "out of range, flag unknown to the cast")
        end)

        it("a member whose flag can't be read stops it", function()
            boot()
            wow.state.units.party4.secrets = { pvp = true }
            assert.are.equal("Ann Vale: Arcane Intellect", armed())
            assert.is_truthy(button.subtitle:GetText():find("can't see whether", 1, true))
        end)

        it("never aims at the dead, the offline, or anyone out of range or sight", function()
            boot()
            wow.state.units.party1.dead = true
            wow.state.units.party2.offline = true
            wow.state.units.party3.hidden = true
            -- Only Dot is left to buff: 1 missing.
            assert.are.equal("Dot Moss: Arcane Intellect", armed())
            wow.state.units.party1.dead = false
            wow.state.units.party3.hidden = false
            wow.state.units.party2.offline = false
            wow.state.units.party1.outOfRange = true
            local target = armed():match("^(.-):")
            assert.are_not.equal("Ann Vale", target)
        end)

        it("a member the spell can't reach is not the target, though the others are", function()
            boot()
            wow.state.units.party1.outOfSpellRange = true
            assert.are.equal("Bo Fern: Arcane Brilliance", armed())
        end)

        it("a rule that leaves out a covered member stops it", function()
            boot({ class = "PRIEST", known = { FORT_6, PRAYER_FORT_2 }, items = { [ITEM.sacredCandle] = 5 } })
            assert.are.equal("Ann Vale: Prayer of Fortitude", armed())
            -- "Everyone but tanks": Dot is a tank.
            ns.db.buffBack.whoGets = { fortitude = { rule = "notTanks" } }
            wow.state.units.party4.role = "TANK"
            assert.are.equal("Ann Vale: Power Word: Fortitude", armed())
            assert.is_truthy(button.subtitle:GetText():find("your rules leave Dot Moss out", 1, true))
            wow.state.units.party4.role = "NONE"
            wow.state.units.party4.secrets = { role = true, mainTank = true }
            armed()
            assert.is_truthy(button.subtitle:GetText():find("can't tell if they're a tank", 1, true))
            wow.state.units.party4.secrets = nil
            wow.state.units.party4.role = "TANK"
            -- Tanks only: everyone else is left out.
            ns.db.buffBack.whoGets = { fortitude = { rule = "tanks" } }
            assert.are.equal("Dot Moss: Power Word: Fortitude", armed())
            -- A Never list.
            ns.db.buffBack.whoGets = {}
            assert.is_true(ns.BuffRules.SetNames("fortitude", "never", "Bo Fern"))
            assert.are.equal("Ann Vale: Power Word: Fortitude", armed())
        end)

        it("a rule that can't be applied (a role or class that can't be read) stops it", function()
            boot({ class = "PRIEST", known = { FORT_6, PRAYER_FORT_2 }, items = { [ITEM.sacredCandle] = 5 } })
            ns.db.buffBack.whoGets = { fortitude = { rule = "notTanks" } }
            wow.state.units.party4.secrets = { role = true, mainTank = true }
            assert.are.equal("Ann Vale: Power Word: Fortitude", armed())
            ns.db.buffBack.whoGets = { fortitude = { rule = "classes", classes = { MAGE = true } } }
            for _, t in ipairs(tokens()) do wow.state.units[t].class = "MAGE" end
            wow.state.units.party4.secrets = { class = true }
            assert.are.equal("Ann Vale: Power Word: Fortitude", armed())
        end)

        it("never replaces a higher rank of the buff that you gave", function()
            -- You know the group version of Fortitude rank 5 only: it matches
            -- Power Word: Fortitude rank 5, and rank 6 is higher.
            boot({ class = "PRIEST", known = { FORT_6, FORT_5, PRAYER_FORT_1 },
                items = { [ITEM.holyCandle] = 5 } })
            assert.are.equal("Ann Vale: Prayer of Fortitude", armed())
            wow.wearBuff("party4", FORT_6, { source = "player", duration = 30 })
            wow.state.units.party4.auraExpires[1] = wow.now + 20 -- running low
            ns.db.buffBack.topUpMinutes = 5
            local text = armed()
            assert.are.equal("Ann Vale: Power Word: Fortitude", text)
            assert.is_truthy(button.subtitle:GetText():find("Dot Moss wears a higher rank of yours", 1, true))
            -- Someone else's higher rank is theirs to keep: the game keeps it.
            wow.state.units.party4.auraSources[1] = "party1"
            wow.state.units.party4.auras = { FORT_6 }
            assert.are.equal("Ann Vale: Prayer of Fortitude", armed())
            -- Whose it is can't be told: single buffs.
            wow.state.units.party4.auraSources[1] = nil
            assert.are.equal("Ann Vale: Power Word: Fortitude", armed())
        end)

        it("the cast covers you too: your own rule and your own higher rank count", function()
            boot({ class = "PRIEST", known = { FORT_6, FORT_5, PRAYER_FORT_1 }, items = { [ITEM.holyCandle] = 5 } })
            assert.are.equal("Ann Vale: Prayer of Fortitude", armed())
            -- You wear a higher rank of Fortitude from yourself: the cast would replace it.
            wow.state.playerAuras = { { isHelpful = true, spellId = FORT_6, sourceUnit = "player", auraInstanceID = 1 } }
            assert.are.equal("Ann Vale: Power Word: Fortitude", armed())
            assert.is_truthy(button.subtitle:GetText():find("You wear a higher rank of yours", 1, true))
            wow.state.playerAuras = {}
            -- You are a tank, and the rule keeps tanks out.
            wow.state.units.player.role = "TANK"
            ns.db.buffBack.whoGets = { fortitude = { rule = "notTanks" } }
            assert.are.equal("Ann Vale: Power Word: Fortitude", armed())
            assert.is_truthy(button.subtitle:GetText():find("your rules leave you out", 1, true))
        end)

        it("buff back to a stranger is unchanged: the single buff", function()
            boot()
            wow.addUnit("nameplate1", { name = "Zed", surname = "Stone", class = "MAGE", id = "Zed-Stone" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            assert.are.equal("Zed Stone: Arcane Intellect", armed(), "the favour first, and singly")
            assert.are.equal("buffed you - give Arcane Intellect", button.subtitle:GetText())
        end)

        it("a group member out of your group is never covered: the party is the group", function()
            boot()
            wow.addUnit("nameplate1", { name = "Zed", surname = "Stone", id = "Zed-Stone", pvp = true })
            assert.are.equal("Ann Vale: Arcane Brilliance", armed(), "a stranger nearby is none of its business")
            wow.pressKey("MOUSEWHEELUP")
            for _, id in ipairs(wow.casts[1].covered) do assert.are_not.equal("Zed-Stone", id) end
            assert.are.same({}, wow.flaggedBy)
        end)
    end)

    describe("settings", function()
        it("have the spec's defaults and carry in profiles and export", function()
            boot()
            assert.is_true(ns.Config.DEFAULTS.buffBack.groupVersions)
            assert.are.equal(3, ns.Config.DEFAULTS.buffBack.groupEnough)
            assert.is_true(ns.db.buffBack.groupVersions)
            assert.are.equal(3, ns.db.buffBack.groupEnough)
            ns.db.buffBack.groupEnough = 7
            ns.db.buffBack.groupVersions = false
            local text = ns.Profiles.Export and ns.Profiles.Export()
            if text then
                boot()
                local ok = ns.Profiles.Import(text)
                assert.is_truthy(ok ~= false)
                assert.are.equal(7, ns.db.buffBack.groupEnough)
                assert.is_false(ns.db.buffBack.groupVersions)
            end
        end)

        it("damaged saved values are repaired to the defaults (black)", function()
            for _, bad in ipairs({ "yes", 5, {}, 0 }) do
                boot({ db = { buffBack = { groupVersions = bad } } })
                assert.is_true(ns.db.buffBack.groupVersions, tostring(bad))
            end
            for bad, want in pairs({ [0] = 1, [-5] = 1, [999] = 40, [3.9] = 3 }) do
                boot({ db = { buffBack = { groupEnough = bad } } })
                assert.are.equal(want, ns.db.buffBack.groupEnough, tostring(bad))
            end
            for _, bad in ipairs({ "three", true, {}, 0 / 0 }) do
                boot({ db = { buffBack = { groupEnough = bad } } })
                assert.are.equal(3, ns.db.buffBack.groupEnough, tostring(bad))
            end
        end)

        it("values damaged mid-session read as the defaults", function()
            boot()
            ns.db.buffBack.groupEnough = "x"
            ns.db.buffBack.groupVersions = "off"
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
            ns.db.buffBack.groupEnough = 0 / 0
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
            ns.db.buffBack.buffBack = nil
        end)
    end)

    describe("chaos (red tests)", function()
        it("a storm of roster, flag, rule, reagent and fight changes never offers a harmful group cast", function()
            local everyone = { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed", "Gus-Lane",
                "Hal-Pine", "Ivy-Cole", "Jon-Dale" }
            local group, singles = 0, 0
            for _, seed in ipairs({ 3, 19, 77, 410, 2026, 9001 }) do
                random.seed(seed)
                -- A priest who knows rank 5 of the Prayer: rank 6 of the single is higher.
                boot({ class = "PRIEST", known = { FORT_6, FORT_5, PRAYER_FORT_1 },
                    items = { [ITEM.holyCandle] = 6 } })
                local inGroup = {}
                local function roster()
                    local names = {}
                    for _, n in ipairs(everyone) do
                        if random.random() < 0.7 then names[#names + 1] = n end
                    end
                    local kind = ({ "party", "raid", "raid" })[random.random(3)]
                    if kind == "party" then while #names > 4 do table.remove(names) end end
                    wow.setGroup(kind, names)
                    inGroup = {}
                    for _, n in ipairs(names) do inGroup[n] = true end
                    if kind == "raid" then
                        for i = 1, #names do wow.state.units["raid" .. i].subgroup = random.random(3) end
                        if random.random() < 0.5 then
                            wow.addUnit("raid" .. (#names + 1), wow.state.units.player)
                        end
                    end
                    wow.fire("GROUP_ROSTER_UPDATE")
                end
                local function someone()
                    local list = tokens()
                    return wow.state.units[list[random.random(math.max(#list, 1))] or "none"]
                end
                local function member(fn)
                    return function()
                        local u = someone()
                        if u and u.id ~= "Me" then fn(u) end
                    end
                end
                local RULES = { "all", "notTanks", "tanks", "classes" }
                local actions = {
                    roster, roster,
                    member(function(u) u.dead = random.random() < 0.2 end),
                    member(function(u) u.pvp = random.random() < 0.25 end),
                    member(function(u) u.outOfRange = random.random() < 0.25 end),
                    member(function(u) u.offline = random.random() < 0.15 end),
                    member(function(u) u.hidden = random.random() < 0.15 end),
                    member(function(u) u.outOfSpellRange = random.random() < 0.2 end),
                    member(function(u) u.role = ({ "TANK", "HEALER", "DAMAGER", "NONE" })[random.random(4)] end),
                    member(function(u)
                        u.secrets = random.random() < 0.3
                            and { pvp = random.random() < 0.5, role = true, mainTank = true } or nil
                    end),
                    member(function(u) u.class = ({ "MAGE", "WARRIOR", "PRIEST", "ROGUE" })[random.random(4)] end),
                    member(function(u) u.auras, u.auraSources, u.auraDurations, u.auraExpires = nil, nil, nil, nil end),
                    function()
                        -- A higher rank, from you or from someone the game doesn't name.
                        local list = tokens()
                        local token = list[random.random(math.max(#list, 1))]
                        if token and wow.state.units[token].id ~= "Me" then
                            wow.wearBuff(token, FORT_6, { source = random.random() < 0.7 and "player" or nil })
                        end
                    end,
                    member(function(u) u.subgroup = random.random(3) end),
                    function() wow.state.pvp = random.random() < 0.2 end,
                    function() wow.state.items[ITEM.holyCandle] = random.random(0, 3) end,
                    function() wow.state.itemsSecret = random.random() < 0.15 end,
                    function() wow.state.rosterSecret = random.random() < 0.1 end,
                    function()
                        ns.db.buffBack.whoGets = { fortitude = { rule = RULES[random.random(#RULES)],
                            classes = { MAGE = true } } }
                    end,
                    function() ns.db.buffBack.groupEnough = random.random(1, 5) end,
                    function() ns.db.buffBack.groupVersions = random.random() < 0.9 end,
                    function() wow.pressKey("MOUSEWHEELUP") end,
                    function() wow.pressKey("MOUSEWHEELUP") end,
                    function() wow.pressKey("MOUSEWHEELUP") end,
                    function() wow.press(button, "RightButton") end,
                    function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                    function() slash(random.random() < 0.85 and "buffmode on" or "buffmode off") end,
                    function() wow.state.castLatency = ({ 0, 0, 0.5 })[random.random(3)] end,
                    function() wow.advance(random.random() * 12) end,
                }
                for step = 1, 500 do
                    local before = #wow.casts
                    local was = {}
                    for _, token in ipairs(tokens()) do
                        local u = wow.state.units[token]
                        was[u.id] = { pvp = u.pvp, role = u.role, mainTank = u.mainTank, dead = u.dead,
                            class = u.class, subgroup = u.subgroup }
                    end
                    local iAmFlagged = wow.state.pvp
                    local rule = ns.db.buffBack.whoGets and ns.db.buffBack.whoGets.fortitude
                        and ns.db.buffBack.whoGets.fortitude.rule or "all"
                    actions[random.random(#actions)]()
                    for i = before + 1, #wow.casts do
                        local cast = wow.casts[i]
                        local where = ("seed %d, step %d: %s on %s"):format(seed, step, cast.spell, cast.target)
                        assert.is_truthy(inGroup[cast.target], where .. ", not in the group")
                        assert.is_falsy(cast.targetDead, where .. ", dead")
                        if cast.covered then
                            group = group + 1
                            if not cast.failed then
                                for _, id in ipairs(cast.covered) do
                                    local m = was[id]
                                    assert.is_truthy(m, where .. ", covered " .. id .. " outside the group")
                                    assert.is_true(iAmFlagged or not m.pvp, where .. ", flagged " .. id)
                                    if rule == "notTanks" then
                                        assert.is_false(m.role == "TANK" or m.mainTank == true,
                                            where .. ", a tank " .. id .. " under 'everyone but tanks'")
                                    elseif rule == "tanks" then
                                        assert.is_true(m.role == "TANK" or m.mainTank == true,
                                            where .. ", a non-tank " .. id .. " under 'tanks only'")
                                    elseif rule == "classes" then
                                        assert.are.equal("MAGE", m.class, where .. ", " .. id .. "'s class not chosen")
                                    end
                                    -- Nobody's higher rank from you is replaced.
                                    for at, spell in ipairs(wow.casts[i].before[id] or {}) do
                                        local src = wow.casts[i].beforeSources[id][at]
                                        assert.is_false(spell == FORT_6 and src == "player",
                                            where .. ", replaced " .. id .. "'s higher rank")
                                    end
                                end
                            end
                        else
                            singles = singles + 1
                        end
                    end
                    assert.are.same({}, wow.flaggedBy, ("seed %d, step %d: flagged for PvP"):format(seed, step))
                    assert.is_true((wow.state.items[ITEM.holyCandle] or 0) >= 0, "reagents never go below 0")
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
            assert.is_true(group > 10, "group casts: " .. group)
            assert.is_true(singles > 10, "single casts: " .. singles)
        end)
    end)
end)
