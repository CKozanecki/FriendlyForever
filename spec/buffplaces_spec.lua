-- Spec: #408, #394, #419
-- Who gets each buff, by place (#408): Buff Back (strangers), Party, Raid and
-- PvP (battlegrounds and arenas), each with its own rule for each buff: by
-- role (Tanks, Healers, Damage), class, Everyone, or Off, plus Always and
-- Never names. Nothing changes until the player chooses: "pending" keeps
-- 1.3.3's rules (spec/buffrules_spec.lua runs on them unchanged).
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1, THORNS_1 = 9885, 1126, 467
local KINGS, GREATER_KINGS, MIGHT_1 = 20217, 25898, 19740
local INTELLECT = 10157

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

-- The owner's defaults (#408), written out here, not read from the addon.
local MANA = { PALADIN = true, HUNTER = true, PRIEST = true, SHAMAN = true, MAGE = true, WARLOCK = true,
    DRUID = true }
local MIGHT = { WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true, SHAMAN = true, DRUID = true }

describe("Who gets each buff, by place (#408)", function()
    local ns, button, printed

    -- A druid who knows Mark of the Wild and Thorns, in buff mode. choice:
    -- made at once ("kept" or "new"), or left pending (nil).
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, buffDefaults = true, buffSelf = opts.buffSelf, before = function(state)
            state.class = opts.class or "DRUID"
            state.knownSpells = opts.known or { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
            state.items = opts.items
            if opts.before then opts.before(state) end
        end })
        printed = {}
        local print = ns.Print
        ns.Print = function(text, ...)
            printed[#printed + 1] = text
            return print(text, ...)
        end
        button = ns.BuffButton.Frame()
        if opts.choice then assert.is_true(ns.BuffRules.Choose(opts.choice)) end
        if opts.buffMode ~= false then slash("buffmode on") end
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

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
                u.auras = u.auras or {}
                u.auras[#u.auras + 1] = cast.id
                u.auraSources = u.auraSources or {}
                u.auraSources[#u.auras] = "player"
            end
        end
        return cast
    end

    -- Scroll until nothing's left: "Name Spell" for each cast, in order.
    local function buffAll()
        local given = {}
        for _ = 1, 40 do
            local cast = scroll()
            if not cast then break end
            given[#given + 1] = cast.target .. " " .. cast.spell
        end
        return given
    end

    -- A group of { name, class, role, mainTank } members.
    local function group(kind, members)
        local names = {}
        for i, m in ipairs(members) do names[i] = m[1] end
        wow.setGroup(kind, names)
        local prefix = kind == "raid" and "raid" or "party"
        for i, m in ipairs(members) do
            local u = wow.state.units[prefix .. i]
            u.class, u.role, u.mainTank = m[2], m[3], m[4]
        end
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
        ns.BuffButton.Refresh()
    end

    -- In a battleground before its gates open (its group is raid-sized), or
    -- an arena (a party), with these members.
    local function pvp(kind, members)
        if kind == "arena" then
            wow.enterDungeon(nil, nil, "arena")
            return group("party", members)
        end
        local names = {}
        for i, m in ipairs(members) do names[i] = m[1] end
        wow.enterBattleground(names)
        for i, m in ipairs(members) do
            local u = wow.state.units["raid" .. i]
            u.class, u.role, u.mainTank = m[2], m[3], m[4]
        end
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
        ns.BuffButton.Refresh()
    end

    -- Who gets Mark of the Wild in a party of a tank, a healer, a damage
    -- dealer and one with no role, by the Party rule set here.
    local FOUR = {
        { "Ann-Vale", "WARRIOR", "TANK" },
        { "Eve-Moss", "PRIEST", "HEALER" },
        { "Dot-Fern", "MAGE", "DAMAGER" },
        { "Gus-Hill", "ROGUE", "NONE" },
    }
    local function motwTo()
        local out = {}
        for _, given in ipairs(buffAll()) do
            local who = given:match("^(%S+) Mark of the Wild$")
            if who then out[#out + 1] = who end
        end
        table.sort(out)
        return out
    end

    describe("the choice", function()
        it("starts pending: settings saved before #408 keep their rules, everywhere (white)", function()
            boot({ db = { schemaVersion = 7, buffBack = { whoGets = { motw = { rule = "tanks" } } } } })
            assert.are.equal("pending", ns.db.buffBack.whoChoice)
            assert.are.same({ rule = "tanks" }, ns.db.buffBack.whoGets.motw)
            group("party", FOUR)
            assert.are.same({ "Ann-Vale" }, motwTo())
            -- A battleground and an arena too: 1.3.3's rule, not PvP's Off.
            for _, kind in ipairs({ "pvp", "arena" }) do
                boot({ db = { schemaVersion = 7, buffBack = { whoGets = { motw = { rule = "tanks" } } } } })
                pvp(kind, FOUR)
                assert.are.same({ "Ann-Vale" }, motwTo(), kind)
            end
        end)

        it("Keep copies each rule in force to Party and Raid; PvP and Buff Back take the defaults (white)", function()
            boot({ db = { buffBack = { whoGets = {
                motw = { rule = "notTanks", always = { ["zed-lake"] = "Zed-Lake" } },
                thorns = { never = { ["ann-vale"] = "Ann-Vale" } },
                might = { rule = "classes", classes = { ROGUE = true } },
            } } } })
            assert.is_true(ns.BuffRules.Choose("kept"))
            local b = ns.db.buffBack
            assert.are.equal("kept", b.whoChoice)
            assert.are.same({}, b.whoGets)
            assert.are.same({ healers = true, damage = true, always = { ["zed-lake"] = "Zed-Lake" } }, b.whoParty.motw)
            assert.are.same(b.whoParty.motw, b.whoRaid.motw)
            -- No rule saved for Thorns: its rule in force (Tanks, the default) and its names.
            assert.are.same({ tanks = true, never = { ["ann-vale"] = "Ann-Vale" } }, b.whoRaid.thorns)
            assert.are.same({ classes = { ROGUE = true } }, b.whoParty.might)
            assert.are.same({}, b.whoPvP)
            assert.are.same({}, b.whoStrangers)
            -- Everyone but tanks became Healers and Damage: said so, by name.
            local said = table.concat(printed, "\n")
            assert.is_truthy(said:find("kept your buff rules", 1, true))
            assert.is_truthy(said:find("\"Everyone but tanks\" is now Healers and Damage for Mark of the Wild", 1, true))
            group("party", FOUR)
            assert.are.same({ "Dot-Fern", "Eve-Moss" }, motwTo(), "no role chosen: no longer given")
        end)

        it("Keep works with a rule saved for a buff that's gone from the game (red, #209)", function()
            boot({ db = { schemaVersion = 7, buffBack = { whoGets = { light = { rule = "notTanks" },
                motw = { rule = "tanks" } } } } })
            assert.is_true(ns.BuffRules.Choose("kept"))
            assert.are.equal("kept", ns.db.buffBack.whoChoice)
            assert.are.same({ healers = true, damage = true }, ns.db.buffBack.whoParty.light)
            assert.are.same({ tanks = true }, ns.db.buffBack.whoRaid.motw)
            assert.is_truthy(table.concat(printed, "\n"):find("Healers and Damage for light", 1, true))
        end)

        it("Use the new defaults empties every place, and a second choice changes nothing (white)", function()
            boot({ db = { buffBack = { whoGets = { motw = { rule = "tanks" } } } } })
            assert.is_true(ns.BuffRules.Choose("new"))
            assert.are.equal("new", ns.db.buffBack.whoChoice)
            assert.are.same({}, ns.db.buffBack.whoGets)
            assert.are.same({ false, "you've already chosen" }, { ns.BuffRules.Choose("kept") })
            assert.are.equal("new", ns.db.buffBack.whoChoice)
            assert.are.same({ false, "unknown choice" }, { ns.BuffRules.Choose("both") })
        end)

        it("the setters work only once the choice is made (black)", function()
            boot()
            assert.are.same({ false, "choose how to start first" }, { ns.BuffRules.SetTick("motw", "party", "tanks", true) })
            assert.are.same({}, ns.db.buffBack.whoParty)
            assert.is_true(ns.BuffRules.Choose("new"))
            assert.is_true(ns.BuffRules.SetTick("motw", "party", "tanks", true))
            assert.are.same({ false, "a stranger's role can't be seen" },
                { ns.BuffRules.SetTick("motw", "strangers", "tanks", true) })
            assert.are.same({ false, "unknown buff or place" }, { ns.BuffRules.SetTick("motw", "moon", "tanks", true) })
            assert.are.same({ false, "unknown choice" }, { ns.BuffRules.SetTick("motw", "party", "pets", true) })
            assert.are.same({ false, "unknown class" }, { ns.BuffRules.SetPlaceClass("motw", "party", "MONK", true) })
        end)

        it("the setters: Everyone clears the other ticks, any other tick clears Everyone, Off keeps the names (white)", function()
            boot({ choice = "new" })
            local b = ns.db.buffBack
            -- A change starts from what was shown: Thorns' Party default is Tanks.
            assert.is_true(ns.BuffRules.SetTick("thorns", "party", "healers", true))
            assert.are.same({ tanks = true, healers = true }, b.whoParty.thorns)
            assert.is_true(ns.BuffRules.SetPlaceClass("thorns", "party", "MAGE", true))
            assert.is_true(ns.BuffRules.SetNames("thorns", "always", "Zed-Lake", "party"))
            assert.is_true(ns.BuffRules.SetTick("thorns", "party", "everyone", true))
            assert.are.same({ everyone = true, always = { ["zed-lake"] = "Zed-Lake" } }, b.whoParty.thorns)
            assert.is_true(ns.BuffRules.SetTick("thorns", "party", "damage", true))
            assert.are.same({ damage = true, always = { ["zed-lake"] = "Zed-Lake" } }, b.whoParty.thorns)
            assert.is_true(ns.BuffRules.SetTick("thorns", "party", "everyone", true))
            assert.is_true(ns.BuffRules.SetPlaceClass("thorns", "party", "ROGUE", true))
            assert.are.same({ classes = { ROGUE = true }, always = { ["zed-lake"] = "Zed-Lake" } }, b.whoParty.thorns)
            assert.is_true(ns.BuffRules.SetPlaceClass("thorns", "party", "ROGUE", false))
            assert.is_true(ns.BuffRules.SetTick("thorns", "party", "tanks", true))
            assert.is_true(ns.BuffRules.SetTick("thorns", "party", "tanks", false))
            assert.is_true(ns.BuffRules.SetTick("thorns", "party", "damage", true))
            assert.is_true(ns.BuffRules.SetOff("thorns", "party"))
            assert.are.same({ always = { ["zed-lake"] = "Zed-Lake" } }, b.whoParty.thorns)
            assert.are.equal("Zed Lake", ns.BuffRules.NamesText("thorns", "always", "party"))
            -- Buff Back: Everyone, classes and Off; no names.
            assert.is_true(ns.BuffRules.SetPlaceClass("might", "strangers", "MAGE", true))
            assert.are.same({ classes = { WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true, SHAMAN = true,
                DRUID = true, MAGE = true } }, b.whoStrangers.might)
            assert.are.same({ false, "unknown list" }, { ns.BuffRules.SetNames("might", "always", "Zed-Lake", "strangers") })
            -- The places are apart: Raid's Thorns is still its default.
            assert.is_nil(b.whoRaid.thorns)
        end)

        it("Keep copies names to Party first, then Raid, within the 500-name cap, and says what didn't fit (red)", function()
            local always = {}
            for i = 1, 100 do
                local full = "Name" .. string.char(96 + (i - 1) % 26 + 1) .. string.rep("a", math.floor((i - 1) / 26))
                    .. "-Realm"
                always[full:lower()] = full
            end
            local whoGets = {}
            for _, key in ipairs({ "motw", "thorns", "kings", "wisdom" }) do
                whoGets[key] = { rule = "all", always = always, never = {} }
            end
            whoGets.fortitude = { rule = "all", always = always }
            boot({ db = { buffBack = { whoGets = whoGets } } })
            assert.is_true(ns.BuffRules.Choose("kept"))
            local function count(map)
                local n = 0
                for _, entry in pairs(map) do
                    for _, list in ipairs({ "always", "never" }) do
                        for _ in pairs(entry[list] or {}) do n = n + 1 end
                    end
                end
                return n
            end
            assert.are.equal(500, count(ns.db.buffBack.whoParty), "Party first")
            assert.are.equal(0, count(ns.db.buffBack.whoRaid))
            assert.is_truthy(table.concat(printed, "\n"):find("500 names weren't copied (at most 500 in all)", 1, true))
            -- And it still exports and imports: within the line's limits.
            local text = ns.Profiles.Export()
            assert.is_string(text)
            assert.is_true(ns.Profiles.Import(text))
            assert.are.equal(500, count(ns.db.buffBack.whoParty))
        end)
    end)

    describe("the role rules (white)", function()
        local function partyRule(entry)
            ns.db.buffBack.whoParty.motw = entry
            ns.BuffButton.Refresh()
        end

        it("gives the buff to the roles, classes and names its Party rule ticks", function()
            local cases = {
                { { everyone = true }, { "Ann-Vale", "Dot-Fern", "Eve-Moss", "Gus-Hill" } },
                { { tanks = true }, { "Ann-Vale" } },
                { { healers = true }, { "Eve-Moss" } },
                { { damage = true }, { "Dot-Fern" } },
                { { tanks = true, healers = true }, { "Ann-Vale", "Eve-Moss" } },
                { { classes = { ROGUE = true } }, { "Gus-Hill" } },
                { { damage = true, classes = { WARRIOR = true } }, { "Ann-Vale", "Dot-Fern" } },
                { {}, {} },
                { { always = { ["gus-hill"] = "Gus-Hill" } }, { "Gus-Hill" } },
                { { everyone = true, never = { ["ann-vale"] = "Ann-Vale" } }, { "Dot-Fern", "Eve-Moss", "Gus-Hill" } },
                { { tanks = true, never = { ["ann-vale"] = "Ann-Vale" } }, {} },
            }
            for i, case in ipairs(cases) do
                boot({ choice = "new" })
                partyRule(case[1])
                group("party", FOUR)
                assert.are.same(case[2], motwTo(), "case " .. i)
            end
        end)

        it("a Main Tank is a tank whatever role they chose; one with no role chosen has no role", function()
            boot({ choice = "new" })
            ns.db.buffBack.whoRaid.motw = { damage = true }
            group("raid", { { "Ann-Vale", "WARRIOR", "DAMAGER", true }, { "Dot-Fern", "MAGE", "DAMAGER" },
                { "Gus-Hill", "ROGUE", "NONE" } })
            assert.are.same({ "Dot-Fern" }, motwTo())
            boot({ choice = "new" })
            ns.db.buffBack.whoRaid.motw = { tanks = true }
            group("raid", { { "Ann-Vale", "WARRIOR", "DAMAGER", true }, { "Dot-Fern", "MAGE", "DAMAGER" } })
            assert.are.same({ "Ann-Vale" }, motwTo())
        end)

        it("in a raid, a Main Tank assignment that can't be read leaves even a healer's role untold", function()
            boot({ choice = "new" })
            ns.db.buffBack.whoRaid.motw = { healers = true }
            group("raid", { { "Eve-Moss", "PRIEST", "HEALER" } })
            wow.state.units.raid1.secrets = { mainTank = true }
            ns.BuffButton.Refresh()
            assert.are.same({}, motwTo())
            assert.is_truthy((button.subtitle:GetText() or ""):find("can't tell their role", 1, true))
        end)

        it("the raid buff split still leaves a member to another copy, whatever the rule says", function()
            boot({ choice = "new" })
            ns.db.buffBack.whoRaid.motw = { everyone = true, always = { ["dot-fern"] = "Dot-Fern" } }
            ns.RaidSplit.CoversMember = function(_, member)
                if member.name == "Dot-Fern" then return false, "left to another druid" end
                return true
            end
            group("raid", FOUR)
            assert.are.same({ "Ann-Vale", "Eve-Moss", "Gus-Hill" }, motwTo())
        end)

        it("Party rules apply in a party, Raid in a raid, PvP in a battleground and an arena", function()
            local function rules()
                ns.db.buffBack.whoParty.motw = { tanks = true }
                ns.db.buffBack.whoRaid.motw = { healers = true }
                ns.db.buffBack.whoPvP.motw = { damage = true }
            end
            boot({ choice = "new" })
            rules()
            group("party", FOUR)
            assert.are.same({ "Ann-Vale" }, motwTo(), "party")
            boot({ choice = "new" })
            rules()
            group("raid", FOUR)
            assert.are.same({ "Eve-Moss" }, motwTo(), "raid")
            -- A party in a raid instance is a party; a raid in the world a raid.
            boot({ choice = "new" })
            rules()
            wow.enterDungeon(409, "Molten Core", "raid")
            group("party", FOUR)
            assert.are.same({ "Ann-Vale" }, motwTo(), "a party in a raid instance")
            for _, kind in ipairs({ "pvp", "arena" }) do
                boot({ choice = "new" })
                rules()
                pvp(kind, FOUR)
                assert.are.same({ "Dot-Fern" }, motwTo(), kind)
            end
        end)

        it("solo, your own buffs follow the Party rules", function()
            boot({ choice = "new", buffSelf = true })
            ns.db.buffBack.whoParty.motw = {}
            ns.db.buffBack.whoParty.thorns = { everyone = true }
            ns.BuffButton.Refresh()
            assert.are.same({ "Me-Here Thorns" }, (function()
                local given = buffAll()
                for i, g in ipairs(given) do given[i] = g:gsub("^[^ ]+", "Me-Here") end
                return given
            end)())
        end)

        it("on the new defaults: PvP gives nothing, Thorns goes to tanks, Might to its classes", function()
            boot({ choice = "new" })
            group("party", FOUR)
            assert.are.same({ "Ann-Vale Mark of the Wild", "Eve-Moss Mark of the Wild", "Dot-Fern Mark of the Wild",
                "Gus-Hill Mark of the Wild", "Ann-Vale Thorns" }, buffAll())
            for _, kind in ipairs({ "pvp", "arena" }) do
                boot({ choice = "new" })
                pvp(kind, FOUR)
                assert.are.same({}, buffAll(), kind)
            end
            -- The defaults, written out (not read from the addon).
            local function classes(place, key)
                local out = {}
                for _, class in ipairs(ns.BuffRules.CLASSES) do
                    local member = { unit = "none", name = "X-Y", class = class }
                    if place == "strangers" then
                        out[class] = ns.BuffRules.AllowsStranger({ key = key }, class) == true or nil
                    else
                        out[class] = ns.BuffRules.Allows({ key = key }, member, { place }) == true or nil
                    end
                end
                return out
            end
            for _, place in ipairs({ "strangers", "party", "raid" }) do
                assert.are.same(MANA, classes(place, "wisdom"), place)
                assert.are.same(MIGHT, classes(place, "might"), place)
            end
            assert.are.same({}, classes("pvp", "might"))
        end)
    end)

    describe("roles and places that can't be read (black)", function()
        it("a role that can't be read gives no role-based buff, and says so; Everyone, a class or a name still decide", function()
            for _, how in ipairs({ "secret", "error", "missing", "number" }) do
                boot({ choice = "new" })
                ns.db.buffBack.whoParty.motw = { healers = true, always = { ["dot-fern"] = "Dot-Fern" } }
                group("party", FOUR)
                if how == "secret" then
                    for i = 1, 4 do wow.state.units["party" .. i].secrets = { role = true } end
                elseif how == "error" then
                    _G.UnitGroupRolesAssigned = function() error("no") end
                elseif how == "missing" then
                    _G.UnitGroupRolesAssigned = nil
                else
                    _G.UnitGroupRolesAssigned = function() return 3 end
                end
                ns.BuffButton.Refresh()
                assert.are.same({ "Dot-Fern" }, motwTo(), how)
                assert.is_truthy((button.subtitle:GetText() or ""):find("can't tell their role", 1, true), how)
            end
        end)

        it("a class rule with a class that can't be read can't tell; a stranger's gets no buff by class", function()
            boot({ choice = "new" })
            ns.db.buffBack.whoParty.motw = { classes = { MAGE = true } }
            group("party", { { "Dot-Fern", nil, "DAMAGER" } })
            assert.are.same({}, motwTo())
            assert.is_truthy((button.subtitle:GetText() or ""):find("can't see their class", 1, true))
            assert.is_nil(ns.BuffRules.AllowsStranger({ key = "might" }, nil))
            assert.is_true(ns.BuffRules.AllowsStranger({ key = "motw" }, nil))
        end)

        it("where the game won't say, a buff goes only where every possible place gives it", function()
            boot({ choice = "new" })
            ns.db.buffBack.whoParty.motw = { everyone = true }
            ns.db.buffBack.whoRaid.motw = { healers = true }
            group("party", FOUR)
            wow.state.inInstanceSecret = true
            wow.state.inInstance, wow.state.instanceType = true, "party"
            ns.BuffButton.Refresh()
            -- Party, or PvP (Off by default): nobody.
            assert.are.same({}, motwTo())
            ns.db.buffBack.whoPvP.motw = { healers = true, damage = true }
            ns.BuffButton.Refresh()
            assert.are.same({ "Dot-Fern", "Eve-Moss" }, motwTo())
            assert.are.same({ "pvp", "party", "raid" }, ns.BuffRules.Place(nil))
            assert.are.same({ "party" }, (function()
                wow.state.inInstanceSecret = nil
                return ns.BuffRules.Place(false)
            end)())
        end)
    end)

    describe("buff back to strangers", function()
        local function stranger(class)
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = class })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
        end

        it("follow the Buff Back rule: Everyone, chosen classes or Off (white)", function()
            boot({ choice = "new", class = "PALADIN", known = { [KINGS] = true, [MIGHT_1] = true }, buffMode = false })
            ns.db.buffBack.buffOrder = { "might", "kings" }
            stranger("MAGE")
            -- Might goes to its classes only: a mage gets Kings.
            assert.is_truthy(macro():find("Blessing of Kings", 1, true))
            -- Kings Off too: nothing of yours for them, so nothing is owed.
            ns.db.buffBack.whoStrangers.kings = {}
            ns.BuffButton.Refresh()
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.are.equal("nobody is owed a buff", why)
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("a stranger whose class can't be read gets no buff by class: the next in your order (black)", function()
            boot({ choice = "new", class = "PALADIN", known = { [KINGS] = true, [MIGHT_1] = true }, buffMode = false })
            ns.db.buffBack.buffOrder = { "might", "kings" }
            stranger(nil)
            assert.is_truthy(macro():find("Blessing of Kings", 1, true))
        end)

        it("a favour your rules leave nothing for isn't counted, holds no place and turns nothing on (#366's lesson)",
            function()
            ns = wow.boot({ autoBuffMode = true, buffDefaults = true, before = function(state)
                state.class = "PALADIN"
                state.knownSpells = { [MIGHT_1] = true }
            end })
            button = ns.BuffButton.Frame()
            assert.is_true(ns.BuffRules.Choose("new"))
            -- A mage: Might goes to its classes only.
            stranger("MAGE")
            assert.are.equal(0, ns.Offers.Count())
            assert.is_false(ns.BuffMode.IsOn(), "someone buffed you, but there's nothing to give them")
            assert.is_nil(ns.BuffMode.LentKey())
            assert.is_nil(ns.Offers.Current())
            -- A warrior: owed, offered, and buff mode turns on for it.
            wow.addUnit("nameplate2", { name = "Cid", surname = "Rock", id = "Cid-Rock", class = "WARRIOR" })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
            assert.are.equal(1, ns.Offers.Count())
            assert.is_true(ns.BuffMode.IsOn())
            assert.is_truthy(macro():find("Blessing of Might", 1, true))
        end)

        it("while pending, a favour counts as in 1.3.3, whatever the rules", function()
            ns = wow.boot({ autoBuffMode = true, buffDefaults = true, before = function(state)
                state.class = "PALADIN"
                state.knownSpells = { [MIGHT_1] = true }
            end })
            button = ns.BuffButton.Frame()
            stranger("MAGE")
            assert.are.equal(1, ns.Offers.Count())
            assert.is_truthy(macro():find("Blessing of Might", 1, true))
        end)

        it("a favour none of your buffs suit isn't counted, while pending (#419) or once you've chosen", function()
            for _, choice in ipairs({ false, "new" }) do
                ns = wow.boot({ autoBuffMode = true, buffDefaults = true, before = function(state)
                    state.class = "MAGE"
                    state.knownSpells = { [INTELLECT] = true }
                end })
                button = ns.BuffButton.Frame()
                if choice then assert.is_true(ns.BuffRules.Choose(choice)) end
                wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
                wow.gainBuff({ sourceUnit = "nameplate1", name = "Mark of the Wild", spellId = MOTW })
                assert.are.equal(0, ns.Offers.Count(), tostring(choice))
            end
        end)

        it("a favour your rules leave nothing for turns nothing on, even with your group missing buffs", function()
            ns = wow.boot({ autoBuffMode = true, buffDefaults = true,
                db = { buffBack = { autoOnJoin = false, autoOnBuffed = true } }, before = function(state)
                    state.class = "PALADIN"
                    state.knownSpells = { [MIGHT_1] = true }
                end })
            button = ns.BuffButton.Frame()
            assert.is_true(ns.BuffRules.Choose("new"))
            group("party", { { "Ann-Vale", "WARRIOR", "TANK" } })
            assert.is_false(ns.BuffMode.IsOn())
            stranger("MAGE")
            assert.is_false(ns.BuffMode.IsOn(), "the mage is owed nothing: no reason to turn on")
        end)

        it("a favour your rules leave nothing for gives no reason over one that's owed", function()
            boot({ choice = "new", class = "PALADIN", known = { [MIGHT_1] = true }, buffMode = false })
            -- Cid, a warrior, is owed and out of sight; then Bob, a mage, buffs you.
            wow.addUnit("nameplate2", { name = "Cid", surname = "Rock", id = "Cid-Rock", class = "WARRIOR" })
            wow.gainBuff({ sourceUnit = "nameplate2", name = "Arcane Intellect", spellId = INTELLECT })
            wow.state.units.nameplate2 = nil
            stranger("MAGE")
            assert.are.same({ nil, "everyone you owe is out of sight or out of range", true }, { ns.Offers.Current() })
        end)

        it("a stranger whose class can't be read, with a rule by class: the button says it can't see it (black)", function()
            boot({ choice = "new", class = "PALADIN", known = { [MIGHT_1] = true }, buffMode = false })
            stranger(nil)
            assert.are.equal(1, ns.Offers.Count(), "their class may yet show")
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.is_truthy(why:find("can't see their class", 1, true), why)
        end)

        it("while pending, any buff their class can use, as 1.3.3 (white)", function()
            boot({ class = "PALADIN", known = { [KINGS] = true, [MIGHT_1] = true }, buffMode = false })
            ns.db.buffBack.buffOrder = { "might", "kings" }
            stranger("MAGE")
            assert.is_truthy(macro():find("Blessing of Might", 1, true))
        end)
    end)

    describe("group versions and buff mode", function()
        it("a class-wide Greater Blessing is never offered when the rule picks by role without Everyone (white)", function()
            boot({ choice = "new", class = "PALADIN", known = { [KINGS] = true, [GREATER_KINGS] = true },
                items = { [wow.ITEM.symbolOfKings] = 10 } })
            local members = {}
            for i, n in ipairs({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed" }) do
                members[i] = { n, "WARRIOR", "HEALER" }
            end
            ns.db.buffBack.whoRaid.kings = { healers = true }
            group("raid", members)
            assert.is_truthy(macro():find("/cast %[help,nodead%] Blessing of Kings"), "single, even with every warrior a healer")
            ns.db.buffBack.whoRaid.kings = { healers = true, classes = { WARRIOR = true } }
            ns.BuffButton.Refresh()
            assert.is_falsy(macro():find("Greater", 1, true), "a role tick still picks by role")
            ns.db.buffBack.whoRaid.kings = { classes = { WARRIOR = true } }
            ns.BuffButton.Refresh()
            assert.is_truthy(macro():find("Greater Blessing of Kings", 1, true), "by class it may")
            ns.db.buffBack.whoRaid.kings = { everyone = true, healers = true }
            ns.BuffButton.Refresh()
            assert.is_truthy(macro():find("Greater Blessing of Kings", 1, true), "Everyone with a role: it may")
        end)

        it("a party-wide version covers only members the place's rules allow, after the choice (white)", function()
            boot({ choice = "new", class = "PRIEST", known = { [10938] = true, [21564] = true },
                items = { [wow.ITEM.sacredCandle] = 5 } })
            local members = {}
            for i, n in ipairs({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" }) do
                members[i] = { n, "WARRIOR", i == 4 and "NONE" or "DAMAGER" }
            end
            -- Party: by role, so Dot (no role chosen) is left out; Raid: Everyone.
            ns.db.buffBack.whoParty.fortitude = { tanks = true, healers = true, damage = true }
            group("party", members)
            assert.is_falsy(macro():find("Prayer of Fortitude", 1, true), "the Party rule leaves Dot out")
            assert.is_truthy(button.subtitle:GetText():find("your rules leave Dot Moss out", 1, true))
            ns.db.buffBack.whoParty.fortitude = { everyone = true }
            ns.BuffButton.Refresh()
            assert.is_truthy(macro():find("Prayer of Fortitude", 1, true), "Everyone in Party: the group version")
        end)

        it("shift+right-click puts the member on the Never list of the place the offer was made in (white)", function()
            boot({ choice = "new" })
            group("raid", FOUR)
            assert.is_truthy(macro():find("Ann Vale", 1, true) or macro():find("Ann-Vale", 1, true))
            wow.press(button, "RightButton", { shift = true })
            assert.are.same({ ["ann-vale"] = "Ann-Vale" }, ns.db.buffBack.whoRaid.motw.never)
            assert.is_truthy(button.result:GetText():find("(Never list, on the Buffs tab).", 1, true))
            assert.is_true(ns.db.buffBack.whoRaid.motw.everyone)
            assert.is_nil(ns.db.buffBack.whoParty.motw)
        end)

        it("no trigger turns buff mode on in a battleground or arena when every buff is off there (white)", function()
            ns = wow.boot({ autoBuffMode = true, buffDefaults = true, before = function(state)
                state.class = "DRUID"
                state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
            end })
            assert.is_true(ns.BuffRules.Choose("new"))
            wow.enterDungeon(nil, nil, "arena")
            -- A member whose name is still loading keeps the group unsettled:
            -- only the PvP rule keeps buff mode off.
            local function join()
                wow.setGroup(nil, {})
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.advance(0)
                wow.setGroup("party", { "Ann-Vale", "Dot-Fern" })
                wow.state.units.party2.nameLoading = true
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.advance(0)
            end
            join()
            assert.is_false(ns.BuffMode.IsOn())
            -- Any rule that gives someone the buff counts (#408): a tick of any
            -- kind, or an Always name.
            for _, rule in ipairs({ { everyone = true }, { healers = true }, { classes = { MAGE = true } },
                { always = { ["zed-lake"] = "Zed-Lake" } } }) do
                ns.db.buffBack.whoPvP.motw = rule
                _G.SlashCmdList.FRIENDLYFOREVER("buffmode off")
                join()
                assert.is_true(ns.BuffMode.IsOn(), "with a buff on in PvP, joining turns it on: " .. next(rule))
            end
        end)
    end)

    describe("damaged settings (red)", function()
        it("a damaged choice is kept when a place holds a rule, else pending; whoGets goes once chosen", function()
            boot({ db = { buffBack = { whoChoice = "maybe", whoParty = { motw = { tanks = true } },
                whoGets = { motw = { rule = "all" } } } } })
            assert.are.equal("kept", ns.db.buffBack.whoChoice)
            assert.are.same({}, ns.db.buffBack.whoGets)
            boot({ db = { buffBack = { whoChoice = 7, whoGets = { motw = { rule = "tanks" } } } } })
            assert.are.equal("pending", ns.db.buffBack.whoChoice)
            assert.are.same({ rule = "tanks" }, ns.db.buffBack.whoGets.motw)
            -- Junk in a place (an unknown buff, a rule that's no table) is no
            -- choice: 1.3.3's rules are kept.
            boot({ db = { buffBack = { whoChoice = "maybe", whoParty = { nope = { everyone = true }, motw = 5 },
                whoGets = { motw = { rule = "tanks" } } } } })
            assert.are.equal("pending", ns.db.buffBack.whoChoice)
            assert.are.same({ rule = "tanks" }, ns.db.buffBack.whoGets.motw)
            -- Mid-session, the panel's field check reads it the same way (#330),
            -- itself when a whole-file repair ran under a second ago.
            wow.advance(2)
            ns.Config.Repair()
            ns.db.buffBack.whoChoice = nil
            assert.are.equal("pending", ns.Config.Field("buffBack", "whoChoice"))
            ns.db.buffBack.whoParty = { motw = { tanks = true } }
            ns.db.buffBack.whoChoice = "?"
            assert.are.equal("kept", ns.Config.Field("buffBack", "whoChoice"))
        end)

        it("once chosen, a leftover 1.3.3 list is emptied on load and counts for nothing against the cap", function()
            local function list(prefix)
                local out = {}
                for i = 1, 100 do
                    local full = prefix .. string.char(96 + (i - 1) % 26 + 1)
                        .. string.rep("a", math.floor((i - 1) / 26)) .. "-Realm"
                    out[full:lower()] = full
                end
                return out
            end
            local old, party = {}, {}
            for _, key in ipairs({ "motw", "thorns", "kings" }) do
                old[key] = { rule = "all", always = list("Ol" .. key), never = list("On" .. key) }
            end
            for _, key in ipairs({ "might", "wisdom" }) do
                party[key] = { everyone = true, always = list("Pa" .. key), never = list("Pn" .. key) }
            end
            for _, choice in ipairs({ "new", "kept" }) do
                boot({ db = { buffBack = { whoChoice = choice, whoGets = old, whoParty = party } } })
                assert.are.same({}, ns.db.buffBack.whoGets, choice)
                local n = 0
                for _, entry in pairs(ns.db.buffBack.whoParty) do
                    for _ in pairs(entry.always) do n = n + 1 end
                    for _ in pairs(entry.never) do n = n + 1 end
                end
                assert.are.equal(400, n, choice .. ": every Party name kept")
            end
        end)

        it("damaged rules are cleaned: a damaged tick reads as Off, never as Everyone", function()
            boot({ db = { buffBack = { whoChoice = "new",
                whoParty = { motw = { everyone = "yes", tanks = 1, classes = { MONK = true, MAGE = "y", ROGUE = true },
                    always = { ["bad name!"] = "x", ["dot-fern"] = "Dot-Fern" } },
                    nope = { everyone = true }, thorns = "junk", [3] = {} },
                whoStrangers = { motw = { tanks = true, everyone = true, always = { ["dot-fern"] = "Dot-Fern" } } },
                whoRaid = "junk", whoPvP = { motw = { healers = true, everyone = "y", classes = { MAGE = 1 } } } } } })
            local b = ns.db.buffBack
            assert.are.same({ motw = { classes = { ROGUE = true }, always = { ["dot-fern"] = "Dot-Fern" } } }, b.whoParty)
            assert.are.same({ motw = { everyone = true } }, b.whoStrangers)
            assert.are.same({}, b.whoRaid)
            assert.are.same({ motw = { healers = true, classes = {} } }, b.whoPvP)
            boot({ db = { buffBack = { whoChoice = "new",
                whoRaid = { motw = { everyone = 1, tanks = true, never = { ["bad!"] = 3 } }, nope = {} } } } })
            assert.are.same({ motw = { tanks = true, never = {} } }, ns.db.buffBack.whoRaid)
        end)

        it("rules damaged mid-session read safely, and a repair heals them", function()
            boot({ choice = "new" })
            group("party", FOUR)
            ns.db.buffBack.whoParty = { motw = { everyone = "yes", classes = "all", always = 5 } }
            ns.BuffButton.Refresh()
            assert.are.same({}, motwTo(), "Off, never Everyone")
            boot({ choice = "new" })
            group("party", FOUR)
            ns.db.buffBack.whoParty = { motw = { healers = true, tanks = "yes", damage = 1 } }
            ns.BuffButton.Refresh()
            assert.are.same({ "Eve-Moss" }, motwTo(), "a damaged tick gives nobody")
            boot({ choice = "new" })
            group("party", FOUR)
            ns.db.buffBack.whoParty = { motw = { classes = { ROGUE = "yes", PRIEST = true } } }
            ns.BuffButton.Refresh()
            assert.are.same({ "Eve-Moss" }, motwTo(), "a damaged class tick gives nobody")
            -- A stranger's rule: a damaged Everyone is no Everyone.
            ns.db.buffBack.whoStrangers = { might = { everyone = "yes" } }
            assert.is_false(ns.BuffRules.AllowsStranger({ key = "might" }, "MAGE"))
            ns.db.buffBack.whoStrangers = { might = { everyone = 1, classes = { MAGE = "y" } } }
            assert.is_false(ns.BuffRules.AllowsStranger({ key = "might" }, "MAGE"))
            -- A class-wide cast: a damaged Everyone doesn't override a role tick.
            ns.db.buffBack.whoRaid = { kings = { everyone = "yes", healers = true } }
            assert.is_false(ns.BuffRules.ClassWideOk({ key = "kings" }, { "raid" }))
            boot({ choice = "new" })
            group("party", FOUR)
            ns.db.buffBack.whoParty = "junk"
            ns.db.buffBack.whoChoice = {}
            ns.BuffButton.Refresh()
            assert.are.same({ "Ann-Vale", "Dot-Fern", "Eve-Moss", "Gus-Hill" }, motwTo(), "back to pending: 1.3.3's")
            wow.advance(2)
            ns.Config.Repair()
            assert.are.equal("pending", ns.db.buffBack.whoChoice)
            assert.are.same({}, ns.db.buffBack.whoParty)
        end)

        it("the names in every place are held to 500 together", function()
            local function list(prefix)
                local out = {}
                for i = 1, 100 do
                    local full = prefix .. string.char(96 + (i - 1) % 26 + 1)
                        .. string.rep("a", math.floor((i - 1) / 26)) .. "-Realm"
                    out[full:lower()] = full
                end
                return out
            end
            local map = {}
            for _, key in ipairs({ "motw", "thorns", "kings" }) do
                map[key] = { always = list("Al" .. key), never = list("Ne" .. key) }
            end
            boot({ db = { buffBack = { whoChoice = "new", whoParty = map, whoRaid = map } } })
            local n = 0
            for _, field in ipairs({ "whoParty", "whoRaid", "whoPvP" }) do
                for _, entry in pairs(ns.db.buffBack[field]) do
                    for _, l in ipairs({ "always", "never" }) do
                        for _ in pairs(entry[l] or {}) do n = n + 1 end
                    end
                end
            end
            assert.are.equal(500, n)
        end)
    end)

    describe("#394: an arena keeps the raid's Blessings", function()
        it("is kept, unused, in an arena, and applies again back in the raid (black)", function()
            boot({ class = "PALADIN", known = { [KINGS] = true, [MIGHT_1] = true } })
            group("raid", { { "Ann-Vale", "WARRIOR", "TANK" }, { "Dot-Fern", "MAGE", "DAMAGER" } })
            assert.is_true(ns.BuffRules.SetRaidBlessings({ "kings" }))
            wow.enterDungeon(nil, nil, "arena")
            group("party", { { "Zed-Lake", "ROGUE", "DAMAGER" } })
            ns.BuffRules.CheckRaid()
            assert.is_false(ns.BuffRules.RaidBlessingsChosen(), "not used in the arena")
            assert.is_true(ns.BuffRules.RaidBlessingsHeld())
            wow.leaveDungeon()
            group("raid", { { "Ann-Vale", "WARRIOR", "TANK" }, { "Dot-Fern", "MAGE", "DAMAGER" } })
            ns.BuffRules.CheckRaid()
            assert.is_true(ns.BuffRules.RaidBlessingsChosen(), "back in the raid")
        end)
    end)

    -- The storm (red): roles, groups, instances, the choice and rules change
    -- at random; the addon never errors, and never offers a buff to a member
    -- the rules of every possible place leave out. What's allowed is worked
    -- out here from the simulated client's own state, never by BuffRules.
    describe("storm (red)", function()
        local ROLES = { "TANK", "HEALER", "DAMAGER", "NONE" }
        local CLASSES = { "WARRIOR", "MAGE", "PRIEST", "ROGUE" }
        local KINDS = { false, "party", "raid", "pvp", "arena", "secret" }
        local TICK_OF = { TANK = "tanks", HEALER = "healers", DAMAGER = "damage" }
        local checked = 0 -- offers checked across every seed: the storm must check some
        -- Offers checked in each case the storm guards, across every seed.
        local reach = { unreadableParty = 0, unreadableRaid = 0, pvp = 0, raid = 0, secretRole = 0 }

        -- Whether entry (as saved) gives motw to the unit u, or nil when the
        -- simulated client's state can't tell; a member's never/always first.
        local function gives(entry, u, name)
            if type(entry) ~= "table" then entry = { everyone = true } end
            local key = name:lower()
            if type(entry.never) == "table" and entry.never[key] then return false end
            if type(entry.always) == "table" and entry.always[key] then return true end
            if entry.everyone == true then return true end
            if type(entry.classes) == "table" and entry.classes[u.class] == true then return true end
            local secret = u.secrets and u.secrets.role
            local tick = TICK_OF[u.role or "NONE"]
            if secret and (entry.tanks or entry.healers or entry.damage) then return nil end
            if tick and entry[tick] == true then return true end
            return false
        end

        for _, seed in ipairs({ 7, 408, 394, 1116, 2026, 31337 }) do
            it("never offers a buff the rules leave out, seed " .. seed, function()
                random.seed(seed)
                local rng = { int = function(_, m, n) return random.random(m, n) end }
                boot()
                local inRaid = false
                for n = 1, 120 do
                    local where = ("seed %d, step %d"):format(seed, n)
                    local step = rng:int(1, 6)
                    if step == 1 and ns.BuffRules.Pending() then
                        ns.BuffRules.Choose(rng:int(1, 2) == 1 and "kept" or "new")
                    elseif step == 2 then
                        -- Unreadable more often than the rest: the case with most places.
                        local kind = rng:int(1, 3) == 1 and "secret" or KINDS[rng:int(1, #KINDS)]
                        wow.state.inInstanceSecret = kind == "secret" or nil
                        wow.state.inInstance = kind ~= false
                        wow.state.instanceType = (kind == "secret" and "party") or (kind or nil)
                    elseif step == 3 then
                        inRaid = rng:int(1, 2) == 1
                        local members = {}
                        for i = 1, rng:int(1, 5) do
                            members[i] = { ({ "Ann", "Bo", "Cid", "Dot", "Eve" })[i] .. "-Realm", CLASSES[rng:int(1, #CLASSES)], ROLES[rng:int(1, #ROLES)] }
                        end
                        group(inRaid and "raid" or "party", members)
                    elseif step == 4 then
                        for token, u in pairs(wow.state.units) do
                            if token:find("^party%d") or token:find("^raid%d") then
                                u.role = ROLES[rng:int(1, #ROLES)]
                                u.secrets = rng:int(1, 5) == 1 and { role = true } or nil
                            end
                        end
                    elseif step == 5 and not ns.BuffRules.Pending() then
                        local place = ({ "party", "raid", "pvp" })[rng:int(1, 3)]
                        local entry = {}
                        for _, t in ipairs({ "everyone", "tanks", "healers", "damage" }) do
                            if rng:int(1, 3) == 1 then entry[t] = true end
                        end
                        if rng:int(1, 3) == 1 then entry.classes = { [CLASSES[rng:int(1, #CLASSES)]] = true } end
                        if rng:int(1, 4) == 1 then entry.never = { ["ann-realm"] = "Ann-Realm" } end
                        ns.db.buffBack[ns.BuffRules.PLACE_FIELD[place]].motw = entry
                    elseif step == 6 then
                        ns.BuffButton.Refresh()
                    end
                    assert.are.same({}, wow.errors, where)
                    -- What the button would give now, checked against the rules.
                    local offers = {}
                    ns.GroupBuffs.Next(offers)
                    if not ns.BuffRules.Pending() then
                        local kind = wow.state.instanceType
                        local places
                        if wow.state.inInstanceSecret then
                            places = { "pvp", inRaid and "raid" or "party" }
                        elseif wow.state.inInstance and (kind == "pvp" or kind == "arena") then
                            places = { "pvp" }
                        else
                            places = { inRaid and "raid" or "party" }
                        end
                        for _, offer in ipairs(offers) do
                            local token = tokenOf(offer.name)
                            local u = token and wow.state.units[token]
                            if u and offer.buff.key == "motw" and token ~= "player" then
                                for _, place in ipairs(places) do
                                    local saved = ns.db.buffBack[ns.BuffRules.PLACE_FIELD[place]].motw
                                    if saved == nil then saved = place == "pvp" and {} or { everyone = true } end
                                    assert.is_true(gives(saved, u, offer.name) == true,
                                        ("%s offered Mark in %s, %s"):format(offer.name, place, where))
                                    checked = checked + 1
                                end
                                if wow.state.inInstanceSecret then
                                    local k = inRaid and "unreadableRaid" or "unreadableParty"
                                    reach[k] = reach[k] + 1
                                elseif places[1] == "pvp" then
                                    reach.pvp = reach.pvp + 1
                                elseif inRaid then
                                    reach.raid = reach.raid + 1
                                end
                                if u.secrets and u.secrets.role then reach.secretRole = reach.secretRole + 1 end
                            end
                        end
                    end
                end
            end)
        end

        it("checked offers after the choice, in every storm together, in every case it guards", function()
            assert.is_true(checked > 20, "only " .. checked .. " offers checked")
            for case, n in pairs(reach) do assert.is_true(n >= 3, case .. ": only " .. n .. " offers checked") end
        end)
    end)
end)
