-- Spec: #68, #76
-- Who gets each buff in buff mode: everyone, tanks only, everyone but tanks,
-- or chosen classes, plus players named Always or Never. Salvation isn't a
-- Blessing on Forever, and goes to everyone but tanks by default.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1, THORNS_1 = 9885, 1126, 467
local KINGS, MIGHT_1, SALVATION = 20217, 19740, 1038
local INTELLECT = 10157

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Who gets each buff", function()
    local ns, button

    -- A druid who knows Mark of the Wild and Thorns, in buff mode.
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = opts.class or "DRUID"
            state.knownSpells = opts.known or { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
        end })
        button = ns.BuffButton.Frame()
        slash("buffmode on")
    end

    local function paladin(known)
        wow.SPELL_NAMES[SALVATION] = "Blessing of Salvation"
        boot({ class = "PALADIN", known = known or { [KINGS] = true, [MIGHT_1] = true, [SALVATION] = true } })
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
        for _ = 1, 30 do
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

    local function rule(key, value) ns.BuffRules.SetRule(key, value) end

    before_each(function() boot() end)
    after_each(function() wow.SPELL_NAMES[SALVATION] = nil end)

    describe("rules (white)", function()
        it("gives everyone Mark of the Wild and Thorns only to tanks, by group role or Main Tank", function()
            rule("thorns", "tanks")
            group("raid", {
                { "Ann-Vale", "WARRIOR", "TANK" },
                { "Cid-Rock", "WARRIOR", "DAMAGER", true }, -- the raid's Main Tank
                { "Dot-Fern", "MAGE", "DAMAGER" },
                { "Eve-Moss", "PRIEST", "HEALER" },
            })
            assert.are.same({
                "Ann-Vale Mark of the Wild", "Cid-Rock Mark of the Wild", "Dot-Fern Mark of the Wild",
                "Eve-Moss Mark of the Wild", "Ann-Vale Thorns", "Cid-Rock Thorns",
            }, buffAll())
            assert.are.equal("everyone in your group has your buffs", button.subtitle:GetText())
        end)

        it("works the same in a party", function()
            rule("thorns", "tanks")
            group("party", { { "Ann-Vale", "WARRIOR", "TANK" }, { "Dot-Fern", "MAGE", "DAMAGER" } })
            assert.are.same({ "Ann-Vale Mark of the Wild", "Dot-Fern Mark of the Wild", "Ann-Vale Thorns" }, buffAll())
        end)

        it("everyone but tanks, and chosen classes", function()
            rule("motw", "notTanks")
            rule("thorns", "classes")
            ns.BuffRules.SetClass("thorns", "ROGUE", true)
            ns.BuffRules.SetClass("thorns", "WARRIOR", true)
            group("party", {
                { "Ann-Vale", "WARRIOR", "TANK" }, { "Bo-Lake", "ROGUE", "DAMAGER" }, { "Dot-Fern", "MAGE", "NONE" },
            })
            assert.are.same({
                "Bo-Lake Mark of the Wild", "Dot-Fern Mark of the Wild", "Ann-Vale Thorns", "Bo-Lake Thorns",
            }, buffAll(), "a member with no role set isn't a tank")
        end)

        it("Always and Never names win over the rule, Never over Always", function()
            rule("thorns", "tanks")
            assert.is_true(ns.BuffRules.SetNames("thorns", "always", "dot fern, Eve Moss"))
            assert.is_true(ns.BuffRules.SetNames("thorns", "never", "Ann-Vale, Eve-Moss"))
            assert.is_true(ns.BuffRules.SetNames("motw", "never", "Cid Rock"))
            group("party", {
                { "Ann-Vale", "WARRIOR", "TANK" }, { "Cid-Rock", "WARRIOR", "DAMAGER" },
                { "Dot-Fern", "MAGE", "DAMAGER" }, { "Eve-Moss", "PRIEST", "HEALER" },
            })
            assert.are.same({
                "Ann-Vale Mark of the Wild", "Dot-Fern Mark of the Wild", "Eve-Moss Mark of the Wild",
                "Dot-Fern Thorns",
            }, buffAll())
            assert.are.equal("dot fern, Eve Moss", ns.BuffRules.NamesText("thorns", "always"), "as typed, sorted")
        end)

        it("gives each member the first Blessing your rules give them, one each", function()
            paladin()
            ns.db.buffBack.buffOrder = { "kings", "might", "salvation" }
            rule("kings", "tanks")
            group("party", { { "Ann-Vale", "WARRIOR", "TANK" }, { "Bo-Lake", "ROGUE", "DAMAGER" } })
            local given = buffAll()
            assert.are.same({
                "Ann-Vale Blessing of Kings", "Bo-Lake Blessing of Might", "Bo-Lake Blessing of Salvation",
            }, given, "Kings to the tank, Might to the rest, Salvation beside it and never on the tank")
        end)

        it("still offers your Blessing to a member wearing your Salvation: it isn't a Blessing", function()
            paladin()
            ns.db.buffBack.buffOrder = { "salvation", "might" }
            group("party", { { "Bo-Lake", "ROGUE", "DAMAGER" } })
            assert.are.same({ "Bo-Lake Blessing of Salvation", "Bo-Lake Blessing of Might" }, buffAll())
            assert.is_nil(ns.BuffData.CLASSES.PALADIN[5].family)
        end)

        it("is shown and changed on the Buff Back tab", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            local thorns = w.buffRows[2]
            assert.are.equal("Who: Everyone", thorns.who:GetText())
            wow.run(thorns.who, "OnClick")
            assert.are.equal("Who: Tanks only", thorns.who:GetText())
            assert.are.equal("tanks", ns.db.buffBack.whoGets.thorns.rule)
            assert.is_truthy(w.who.header:GetText():find("Who gets Thorns in buff mode: Tanks only", 1, true))
            wow.run(thorns.who, "OnClick")
            wow.run(thorns.who, "OnClick")
            assert.are.equal("Who: Chosen classes", thorns.who:GetText())
            assert.is_true(w.who.classes.WARRIOR:IsShown())
            w.who.classes.WARRIOR:SetChecked(true)
            wow.run(w.who.classes.WARRIOR, "OnClick")
            assert.is_true(ns.db.buffBack.whoGets.thorns.classes.WARRIOR)
            w.who.never:SetFocus()
            w.who.never:SetText("Ann Vale")
            w.who.never:ClearFocus()
            assert.are.equal("Ann-Vale", ns.db.buffBack.whoGets.thorns.never["ann-vale"])
            wow.run(thorns.who, "OnClick")
            assert.are.equal("Who: Everyone", thorns.who:GetText(), "round again")
            assert.is_false(w.who.classes.WARRIOR:IsShown())
        end)

        it("Salvation's button starts at everyone but tanks", function()
            paladin()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            for _, row in ipairs(w.buffRows) do
                if row.key == "salvation" then assert.are.equal("Who: Everyone but tanks", row.who:GetText()) end
            end
        end)

        it("doesn't change buff back to strangers", function()
            rule("motw", "tanks")
            assert.is_true(ns.BuffRules.SetNames("motw", "never", "Bob Stone"))
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            assert.is_truthy(macro():find("/targetexact Bob Stone", 1, true))
            assert.is_truthy(macro():find("/cast [help,nodead] Mark of the Wild", 1, true), "your first buff, rules aside")
        end)
    end)

    describe("what it can't see (black)", function()
        it("gives no tanks-only buff when a role can't be read, and says why", function()
            rule("thorns", "tanks")
            group("party", { { "Ann-Vale", "WARRIOR", "TANK" } })
            wow.state.units.party1.secrets = { role = true, mainTank = true }
            wow.state.units.party1.auras = { MOTW }
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.are.equal("Ann Vale: can't tell if they're a tank", button.subtitle:GetText())
            local _, _, settled = ns.GroupBuffs.Next()
            assert.is_false(settled, "can't tell isn't done")
        end)

        it("keeps Salvation off a member whose role can't be read", function()
            paladin({ [SALVATION] = true })
            group("party", { { "Ann-Vale", "WARRIOR", "DAMAGER" } })
            wow.state.units.party1.secrets = { role = true }
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
        end)

        it("reads a tank from either answer alone, and not-a-tank only when nothing is hidden", function()
            group("raid", { { "Ann-Vale" }, { "Cid-Rock" } })
            local u = wow.state.units.raid1
            u.role, u.mainTank, u.secrets = "TANK", false, { mainTank = true }
            assert.is_true(ns.BuffRules.IsTank("raid1"), "the role alone says tank")
            u.role, u.mainTank, u.secrets = "DAMAGER", true, { role = true }
            assert.is_true(ns.BuffRules.IsTank("raid1"), "Main Tank alone says tank")
            u.role, u.mainTank, u.secrets = "DAMAGER", false, { mainTank = true }
            assert.is_nil(ns.BuffRules.IsTank("raid1"), "a hidden Main Tank could be a tank")
            u.role, u.mainTank, u.secrets = "TANK", false, { role = true }
            assert.is_nil(ns.BuffRules.IsTank("raid1"), "a hidden role could be a tank, whatever Main Tank says")
            u.role, u.secrets = "DAMAGER", nil
            assert.is_false(ns.BuffRules.IsTank("raid1"))
            local real = _G.GetPartyAssignment
            _G.GetPartyAssignment = nil
            finally(function() _G.GetPartyAssignment = real end)
            assert.is_false(ns.BuffRules.IsTank("raid1"), "a client with roles only")
            u.secrets = { role = true }
            assert.is_nil(ns.BuffRules.IsTank("raid1"))
            _G.GetPartyAssignment = function() error("boom") end
            u.secrets = nil
            assert.is_nil(ns.BuffRules.IsTank("raid1"), "an API that throws doesn't count as an answer")
        end)

        it("a role answer that isn't text can't be read: no Salvation, and the button says why", function()
            paladin({ [SALVATION] = true })
            local real = _G.UnitGroupRolesAssigned
            finally(function() _G.UnitGroupRolesAssigned = real end)
            group("party", { { "Ann-Vale", "WARRIOR" } })
            for _, answer in ipairs({ false, 0, {} }) do
                _G.UnitGroupRolesAssigned = function() return answer end
                assert.is_nil(ns.BuffRules.IsTank("party1"), tostring(answer))
            end
            _G.UnitGroupRolesAssigned = function() return nil end
            assert.is_nil(ns.BuffRules.IsTank("party1"))
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.are.equal("Ann Vale: can't tell if they're a tank", button.subtitle:GetText())
        end)

        it("an excluded member doesn't stop \"everyone has your buffs\"", function()
            rule("thorns", "tanks")
            group("party", { { "Dot-Fern", "MAGE", "DAMAGER" } })
            buffAll()
            local offer, why, settled = ns.GroupBuffs.Next()
            assert.is_nil(offer)
            assert.are.equal("everyone in your group has your buffs", why)
            assert.is_true(settled)
        end)

        it("a class rule needs the class: an unreadable one is said", function()
            rule("motw", "classes")
            rule("thorns", "classes")
            ns.BuffRules.SetClass("motw", "MAGE", true)
            group("party", { { "Dot-Fern", nil, "DAMAGER" } })
            assert.is_nil(macro())
            assert.are.equal("Dot Fern: can't see their class", button.subtitle:GetText())
        end)

        it("refuses names that aren't player names, and keeps the list as it was", function()
            assert.is_true(ns.BuffRules.SetNames("thorns", "always", "Ann Vale"))
            local ok, why = ns.BuffRules.SetNames("thorns", "always", "Cid Rock, |cffff0000Bad|r, x y z")
            assert.is_false(ok)
            assert.is_string(why)
            assert.are.equal("Ann Vale", ns.BuffRules.NamesText("thorns", "always"))
            local many = {}
            local function nameFor(i) -- a different valid name for each i
                return "Na" .. string.char(97 + i % 26) .. string.char(97 + math.floor(i / 26)) .. "-Stone"
            end
            for i = 1, ns.BuffRules.MAX_NAMES do many[i] = nameFor(i) end
            assert.is_true(ns.BuffRules.SetNames("thorns", "never", table.concat(many, ",")), "up to the limit")
            many[#many + 1] = nameFor(ns.BuffRules.MAX_NAMES + 1)
            ok, why = ns.BuffRules.SetNames("thorns", "never", table.concat(many, ","))
            assert.is_false(ok, "one past it")
            assert.are.equal("at most " .. ns.BuffRules.MAX_NAMES .. " names", why)
            assert.is_false(ns.BuffRules.SetNames("bogus", "never", "Ann Vale"))
            assert.is_false(ns.BuffRules.SetNames("thorns", "sometimes", "Ann Vale"))
            assert.is_true(ns.BuffRules.SetNames("thorns", "always", " , "), "an empty list is fine")
            assert.are.equal("", ns.BuffRules.NamesText("thorns", "always"))
        end)

        it("the options box says why a list wasn't saved", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            w.who.always:SetFocus()
            w.who.always:SetText("not a name!")
            w.who.always:ClearFocus()
            local said = false
            for _, line in ipairs(wow.printed) do
                if line:find("Always list not saved", 1, true) then said = true end
            end
            assert.is_true(said)
            assert.are.equal("", w.who.always:GetText(), "shows what's kept")
        end)

        it("saves a name box to the buff it was typed for, even if another buff is chosen meanwhile", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            w.who.always:SetFocus() -- the boxes show Mark of the Wild, the first buff
            w.who.always:SetText("Ann Vale")
            wow.run(w.buffRows[2].who, "OnClick") -- Thorns' Who button, mid-edit
            assert.are.equal("Ann Vale", ns.BuffRules.NamesText("motw", "always"))
            assert.are.equal("", ns.BuffRules.NamesText("thorns", "always"))
            assert.are.equal("", w.who.always:GetText(), "now showing Thorns' list")
            -- The same when moving a buff changes which is first.
            boot()
            w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            w.who.never:SetFocus()
            w.who.never:SetText("Cid Rock")
            wow.run(w.buffRows[2].up, "OnClick") -- Thorns moves above Mark of the Wild
            assert.are.equal("Cid Rock", ns.BuffRules.NamesText("motw", "never"))
            assert.are.equal("", ns.BuffRules.NamesText("thorns", "never"))
            -- And when the order changes from outside the panel (a profile, say).
            boot()
            w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            w.who.always:SetFocus()
            w.who.always:SetText("Dot Fern")
            ns.db.buffBack.buffOrder = { "thorns", "motw" }
            ns.Options.Refresh()
            w.who.always:ClearFocus()
            assert.are.equal("Dot Fern", ns.BuffRules.NamesText("motw", "always"))
            assert.are.equal("", ns.BuffRules.NamesText("thorns", "always"))
        end)

        it("leaves a list alone when its box is only clicked in and out, and holds a full list of long names", function()
            local long = ("Abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuv"):sub(1, 48)
            local names = {}
            for i = 1, ns.BuffRules.MAX_NAMES do
                names[i] = long .. "-" .. long:sub(1, 40) .. string.char(97 + i % 26) .. string.char(97 + math.floor(i / 26))
            end
            assert.is_true(ns.BuffRules.SetNames("motw", "always", table.concat(names, ",")))
            local before = ns.BuffRules.NamesText("motw", "always")
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            assert.are.equal(before, w.who.always:GetText(), "the whole list fits the box")
            local saves = 0
            local real = ns.BuffRules.SetNames
            ns.BuffRules.SetNames = function(...) saves = saves + 1; return real(...) end
            w.who.always:SetFocus()
            w.who.always:ClearFocus()
            ns.BuffRules.SetNames = real
            assert.are.equal(0, saves, "unchanged: not saved again")
            assert.are.equal(before, ns.BuffRules.NamesText("motw", "always"))
        end)

        it("keeps every list together within a total, so a settings line can always be read back", function()
            local function names(from, count)
                local out = {}
                for i = from, from + count - 1 do
                    out[#out + 1] = "Na" .. string.char(97 + i % 26) .. string.char(97 + math.floor(i / 26) % 26)
                        .. string.char(97 + math.floor(i / 676)) .. "-Stone"
                end
                return table.concat(out, ",")
            end
            local keys = { "motw", "thorns", "kings", "might", "wisdom" }
            local start = 0
            for _, key in ipairs(keys) do
                assert.is_true(ns.BuffRules.SetNames(key, "always", names(start, 100)), key)
                start = start + 100
            end
            local ok, why = ns.BuffRules.SetNames("light", "never", names(start, 1))
            assert.is_false(ok)
            assert.are.equal("at most " .. ns.BuffRules.MAX_TOTAL_NAMES .. " names across all your buffs", why)
            assert.is_true(ns.BuffRules.SetNames("motw", "always", names(0, 99)), "replacing a list counts it once")
            -- A saved file holding more is cut to the total on load.
            local who = ns.db.buffBack.whoGets
            who.light = { never = {} }
            for i = 1, 50 do
                local full = "Zz" .. string.char(97 + i % 26) .. string.char(97 + math.floor(i / 26)) .. "-Stone"
                who.light.never[full:lower()] = full
            end
            local text = assert(ns.Profiles.Export())
            assert.is_table(ns.Serialize.Decode(text), "an export can always be read back")
            local kept = 0
            for _, entry in pairs(ns.BuffRules.Clean(who)) do
                for list in pairs(ns.BuffRules.NAME_LISTS) do
                    for _ in pairs(entry[list] or {}) do kept = kept + 1 end
                end
            end
            assert.are.equal(ns.BuffRules.MAX_TOTAL_NAMES, kept)
        end)

        it("can't tell a party's tank without group roles: Main Tank is raid-only", function()
            paladin({ [SALVATION] = true })
            local real = _G.UnitGroupRolesAssigned
            _G.UnitGroupRolesAssigned = nil
            finally(function() _G.UnitGroupRolesAssigned = real end)
            group("party", { { "Ann-Vale", "WARRIOR" } })
            assert.is_nil(ns.BuffRules.IsTank("party1"))
            assert.is_nil(macro(), "no Salvation on someone who may be the tank")
            assert.are.equal("Ann Vale: can't tell if they're a tank", button.subtitle:GetText())
            group("raid", { { "Ann-Vale", "WARRIOR" }, { "Cid-Rock", "MAGE", nil, true } })
            assert.is_false(ns.BuffRules.IsTank("raid1"), "in a raid, the Main Tank assignment says")
            assert.is_true(ns.BuffRules.IsTank("raid2"))
        end)

        it("an unreadable role doesn't hold back \"everyone has your buffs\" for members who have the buff", function()
            paladin({ [SALVATION] = true })
            group("party", { { "Ann-Vale", "WARRIOR", "TANK" }, { "Bo-Lake", "ROGUE", "DAMAGER" } })
            for _, token in ipairs({ "party1", "party2" }) do
                local u = wow.state.units[token]
                u.secrets = { role = true }
                u.auras, u.auraSources = { SALVATION }, { "raid9" } -- another paladin's Mass Salvation
            end
            local offer, why, settled = ns.GroupBuffs.Next()
            assert.is_nil(offer)
            assert.are.equal("everyone in your group has your buffs", why)
            assert.is_true(settled)
        end)

        it("repairs damaged saved rules to each buff's default", function()
            boot({ db = { buffBack = { whoGets = {
                thorns = { rule = "everybody", classes = { WARRIOR = true, OGRE = true, MAGE = "yes" },
                    always = { ["ann-vale"] = "Ann-Vale", bad = "Cid-Rock", [7] = "x", ["dot-fern"] = {} },
                    never = "Eve Moss" },
                salvation = { rule = 3 },
                bogus = { rule = "tanks" },
                motw = "tanks",
            } } } })
            local who = ns.db.buffBack.whoGets
            assert.is_nil(who.bogus)
            assert.is_nil(who.motw)
            assert.is_nil(who.thorns.rule)
            assert.are.same({ WARRIOR = true }, who.thorns.classes)
            assert.are.same({ ["ann-vale"] = "Ann-Vale" }, who.thorns.always)
            assert.is_nil(who.thorns.never)
            assert.are.equal("all", ns.BuffRules.Rule(ns.BuffData.CLASSES.DRUID[2]))
            assert.are.equal("notTanks", ns.BuffRules.Rule(ns.BuffData.CLASSES.PALADIN[5]))
            boot({ db = { buffBack = { whoGets = "tanks" } } })
            assert.are.same({}, ns.db.buffBack.whoGets)
        end)

        it("keeps working when the rules are damaged mid-session", function()
            group("party", { { "Ann-Vale", "WARRIOR", "TANK" } })
            ns.db.buffBack.whoGets = { thorns = { rule = {}, always = 5, never = { x = 1 } }, motw = 7 }
            assert.are.equal("Ann-Vale Mark of the Wild", buffAll()[1])
            ns.db.buffBack.whoGets = nil
            ns.BuffButton.Refresh()
            assert.are.same({}, wow.errors)
        end)

        it("goes with profiles and settings lines", function()
            rule("thorns", "classes")
            ns.BuffRules.SetClass("thorns", "WARRIOR", true)
            ns.BuffRules.SetNames("thorns", "always", "Ann Vale")
            ns.BuffRules.SetNames("thorns", "never", "Cid Rock")
            local text = assert(ns.Profiles.Export())
            ns.db.buffBack.whoGets = {}
            assert.is_true(ns.Profiles.Import(text))
            local thorns = ns.db.buffBack.whoGets.thorns
            assert.are.equal("classes", thorns.rule)
            assert.are.same({ WARRIOR = true }, thorns.classes)
            assert.are.same({ ["ann-vale"] = "Ann-Vale" }, thorns.always)
            assert.are.same({ ["cid-rock"] = "Cid-Rock" }, thorns.never)
        end)
    end)

    describe("chaos (red tests)", function()
        it("never gives a buff to a member its rule leaves out, nor replaces your own Blessing", function()
            local given, refused = 0, 0
            for _, seed in ipairs({ 3, 68, 404, 1999 }) do
                random.seed(seed)
                paladin()
                local everyone = { "Ann-Vale", "Bo-Lake", "Cid-Rock", "Dot-Fern", "Eve-Moss", "Fay-Dune" }
                local classes = { "WARRIOR", "ROGUE", "MAGE", "PRIEST", "PALADIN", "DRUID" }
                local roles = { "TANK", "HEALER", "DAMAGER", "NONE" }
                local keys = { "kings", "might", "salvation" }
                local function reshuffle()
                    local members = {}
                    for _, name in ipairs(everyone) do
                        if random.random() < 0.7 then
                            members[#members + 1] = { name, classes[random.random(#classes)],
                                roles[random.random(#roles)], random.random() < 0.2 }
                        end
                    end
                    if #members == 0 then members[1] = { everyone[1], "WARRIOR", "TANK" } end
                    group(random.random() < 0.5 and "raid" or "party", members)
                end
                reshuffle()
                local actions = {
                    reshuffle,
                    function() rule(keys[random.random(3)], ns.BuffRules.RULES[random.random(4)]) end,
                    function()
                        ns.BuffRules.SetClass(keys[random.random(3)], classes[random.random(#classes)], random.random() < 0.5)
                    end,
                    function()
                        local pick = {}
                        for _, name in ipairs(everyone) do if random.random() < 0.3 then pick[#pick + 1] = name end end
                        ns.BuffRules.SetNames(keys[random.random(3)], random.random() < 0.5 and "always" or "never",
                            table.concat(pick, ", "))
                    end,
                    function()
                        -- Another paladin's Blessing or Salvation lands on someone.
                        local token = (wow.state.units.raid1 and "raid" or "party") .. random.random(1, 6)
                        local u = wow.state.units[token]
                        if u then
                            u.auras = u.auras or {}
                            u.auras[#u.auras + 1] = ({ KINGS, MIGHT_1, SALVATION })[random.random(3)]
                            u.auraSources = u.auraSources or {}
                            u.auraSources[#u.auras] = "raid9"
                        end
                    end,
                    function()
                        local token = (wow.state.units.raid1 and "raid" or "party") .. random.random(1, 6)
                        local u = wow.state.units[token]
                        if u then
                            local r = random.random()
                            u.secrets = r < 0.3 and { role = true } or r < 0.5 and { mainTank = true } or nil
                        end
                    end,
                    function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                    function() ns.db.buffBack.buffOrder = { keys[random.random(3)], keys[random.random(3)] } end,
                    function() wow.advance(random.random() * 20) end,
                }
                for step = 1, 400 do
                    local where = ("seed %d, step %d"):format(seed, step)
                    actions[random.random(#actions)]()
                    local before = #wow.casts
                    -- What the rules say for the member about to be buffed,
                    -- read the way the game shows them now.
                    local offer = ns.GroupBuffs.Next()
                    scroll()
                    local cast = wow.casts[before + 1]
                    if cast and offer and cast.target == offer.name then
                        local token = tokenOf(cast.target)
                        local u = wow.state.units[token]
                        local member = { unit = token, name = cast.target, class = u.class }
                        assert.is_true(ns.BuffRules.Allows(offer.buff, member) == true, where .. ": rule broken")
                        -- And worked out from what the game shows, not from the rules' own answer.
                        local entry = (ns.db.buffBack.whoGets or {})[offer.buff.key] or {}
                        local nameKey = cast.target:lower()
                        assert.is_nil((entry.never or {})[nameKey], where .. ": given to someone named Never")
                        if not (entry.always or {})[nameKey] then
                            local ruleNow = ns.BuffRules.Rule(offer.buff)
                            local inRaid = token:find("^raid") ~= nil
                            local hidden = u.secrets or {}
                            local roleSaysTank = not hidden.role and u.role == "TANK"
                            local mainTankSays = inRaid and not hidden.mainTank and u.mainTank == true
                            if ruleNow == "tanks" then
                                assert.is_true(roleSaysTank or mainTankSays, where .. ": tanks-only to a non-tank")
                            elseif ruleNow == "notTanks" then
                                assert.is_false(roleSaysTank or mainTankSays, where .. ": kept-off buff to a tank")
                                assert.is_nil(hidden.role, where .. ": kept-off buff with the role hidden")
                                assert.is_true(not inRaid or not hidden.mainTank,
                                    where .. ": kept-off buff with Main Tank hidden")
                            elseif ruleNow == "classes" then
                                assert.is_true((entry.classes or {})[u.class] == true, where .. ": class not chosen")
                            end
                        end
                        if offer.buff.family == "blessing" then
                            -- Not over one of your own Blessings (yours are the ones with your source).
                            for i, id in ipairs(u.auras or {}) do
                                local b = ns.BuffData.ForAura(id)
                                if b and b.family == "blessing" and u.auraSources[i] == "player" then
                                    assert.is_true(id == cast.id, where .. ": replaced your Blessing")
                                end
                            end
                        end
                        given = given + 1
                    elseif not cast then
                        refused = refused + 1
                    end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
            assert.is_true(given > 50, "buffs given: " .. given)
            assert.is_true(refused > 50, "presses with nothing to give: " .. refused)
        end)
    end)
end)
