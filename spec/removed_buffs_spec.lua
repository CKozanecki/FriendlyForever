-- Spec: #208
-- Blizzard removed Blessing of Salvation, Mass Salvation and Revoke right
-- before launch. The addon never offers, tracks or mentions them, old saved
-- settings (rules, order, never-lists, profiles, imported lines) still load
-- and drop the dead keys quietly, and a stale aura with one of their spell
-- IDs is ignored. A paladin's Blessings are unchanged (the remaining
-- specs: buffrules, raidblessings, groupbuffs).
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local KINGS, WISDOM_1, MIGHT_1 = 20217, 19742, 19740
-- The spell IDs the removed buffs had, and what the old addon called Revoke.
local SALVATION, MASS_SALVATION = 1038, 25895

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

-- Everything the old addon saved about the removed features, for a paladin.
local function oldSettings()
    return {
        buffBack = {
            buffOrder = { "salvation", "kings", "might" },
            neverOffer = { salvation = true, might = true },
            whoGets = {
                salvation = { rule = "notTanks", classes = { WARRIOR = true }, always = { ["ann-vale"] = "Ann-Vale" } },
                kings = { rule = "tanks" },
            },
            revokeMode = "anyTank",
            revokeNames = { ["bo-lake"] = "Bo-Lake" },
        },
    }
end

describe("Salvation, Mass Salvation and Revoke are gone", function()
    local ns, button

    local function boot(opts)
        opts = opts or {}
        -- The game's spell data may still name them: the addon must not
        -- offer them for that (pessimistic).
        wow.SPELL_NAMES[SALVATION] = "Blessing of Salvation"
        wow.SPELL_NAMES[MASS_SALVATION] = "Greater Blessing of Salvation"
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = opts.class or "PALADIN"
            state.knownSpells = opts.known
                or { [KINGS] = true, [WISDOM_1] = true, [MIGHT_1] = true, [SALVATION] = true,
                    [MASS_SALVATION] = true }
        end })
        button = ns.BuffButton.Frame()
        slash("buffmode on")
    end

    after_each(function()
        wow.SPELL_NAMES[SALVATION], wow.SPELL_NAMES[MASS_SALVATION] = nil, nil
    end)

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
                u.auras, u.auraSources = u.auras or {}, u.auraSources or {}
                u.auras[#u.auras + 1] = cast.id
                u.auraSources[#u.auras] = "player"
            end
        end
        return cast
    end

    -- "Name Spell" for every cast until nothing is left.
    local function buffAll()
        local given = {}
        for _ = 1, 40 do
            local cast = scroll()
            if not cast then break end
            given[#given + 1] = cast.target .. " " .. cast.spell
        end
        return given
    end

    local function group(kind, members)
        local names = {}
        for i, m in ipairs(members) do names[i] = m[1] end
        wow.setGroup(kind, names)
        local prefix = kind == "raid" and "raid" or "party"
        for i, m in ipairs(members) do
            local u = wow.state.units[prefix .. i]
            u.class, u.role = m[2], m[3]
        end
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
        ns.BuffButton.Refresh()
    end

    local function noRemovedBuff(casts)
        for _, text in ipairs(casts) do
            assert.is_falsy(text:find("Salvation", 1, true), text)
            assert.is_falsy(text:find("Revoke", 1, true), text)
        end
    end

    describe("nothing offers them (white)", function()
        it("has no Salvation, Mass Salvation or Revoke in the buff data", function()
            boot()
            for class, buffs in pairs(ns.BuffData.CLASSES) do
                for _, buff in ipairs(buffs) do
                    assert.are_not.equal("salvation", buff.key, class)
                    for _, id in ipairs(buff.ranks) do assert.are_not.equal(SALVATION, id) end
                    for _, id in ipairs(buff.group or {}) do assert.are_not.equal(MASS_SALVATION, id) end
                end
            end
            assert.is_nil(ns.BuffData.KEYS.salvation)
            assert.is_nil(ns.BuffData.ByKey("salvation"))
            assert.is_nil(ns.BuffData.REVOKE)
            assert.is_nil(ns.BuffData.ForAura(SALVATION))
            assert.is_nil(ns.BuffData.ForAura(MASS_SALVATION))
            assert.is_nil(ns.BuffData.ForCast(SALVATION))
            assert.is_true(ns.BuffData.IsRemoved(SALVATION))
            assert.is_true(ns.BuffData.IsRemoved(MASS_SALVATION))
            assert.is_false(ns.BuffData.IsRemoved(wow.secret(SALVATION)), "a secret value is never used as a key")
            for _, other in ipairs({ KINGS, WISDOM_1, 0, -1, 1038.5, "1038", true, {}, nil }) do
                assert.is_false(ns.BuffData.IsRemoved(other), tostring(other))
            end
        end)

        it("gives a party or raid only Blessings, even for a paladin who knows spell 1038, tanks included", function()
            boot()
            for _, kind in ipairs({ "party", "raid" }) do
                group(kind, { { "Ann-Vale", "WARRIOR", "TANK" }, { "Bo-Lake", "ROGUE", "DAMAGER" } })
                local given = buffAll()
                assert.is_true(#given > 0, kind)
                noRemovedBuff(given)
                assert.is_nil(macro(), kind .. ": nothing left, and no Revoke")
            end
        end)

        it("offers no Revoke on a tank wearing a Salvation from anyone, and says nothing about it", function()
            boot()
            group("party", { { "Ann-Vale", "WARRIOR", "TANK" } })
            local u = wow.state.units.party1
            u.auras, u.auraSources = { SALVATION, MASS_SALVATION }, { "player", "raid9" }
            ns.BuffButton.Refresh()
            local text = macro() or ""
            assert.is_falsy(text:find("Revoke", 1, true))
            assert.is_falsy((button.subtitle:GetText() or ""):find("Salvation", 1, true))
            noRemovedBuff(buffAll())
        end)

        it("shows no Salvation or Revoke setting on the options pages, and the search finds none", function()
            boot()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            assert.is_nil(w.who.revoke)
            assert.is_nil(w.who.revokeNames)
            assert.is_nil(ns.Options.CycleRevoke)
            for _, row in ipairs(w.buffRows) do assert.are_not.equal("salvation", row.key) end
            for _, frame in ipairs(wow.frames) do
                local text = frame.text
                if type(text) == "string" then
                    assert.is_falsy(text:lower():find("salvation", 1, true), text)
                    assert.is_falsy(text:lower():find("revoke", 1, true), text)
                end
            end
            for _, word in ipairs({ "salvation", "revoke", "mass" }) do
                for _, entry in ipairs(ns.OptionsIndex.Find(word)) do
                    assert.is_falsy(entry.name:lower():find("salvation", 1, true), entry.name)
                    assert.is_falsy(entry.name:lower():find("revoke", 1, true), entry.name)
                end
            end
        end)

        it("leaves the paladin's other buffs as they were, to everyone", function()
            boot()
            local keys = {}
            for i, buff in ipairs(ns.BuffData.CLASSES.PALADIN) do keys[i] = buff.key end
            assert.are.same({ "kings", "wisdom", "might" }, { keys[1], keys[2], keys[3] }, "in their order")
            for _, buff in ipairs(ns.BuffData.CLASSES.PALADIN) do
                assert.are.equal("all", ns.BuffRules.Rule(buff), buff.key)
            end
            group("party", { { "Ann-Vale", "WARRIOR", "TANK" } })
            assert.are.same({ "Ann-Vale Blessing of Kings" }, buffAll())
        end)
    end)

    describe("old saved data (black)", function()
        it("loads settings that mention them, drops the dead keys, and keeps the rest", function()
            boot({ db = oldSettings() })
            local b = ns.db.buffBack
            assert.are.same({}, wow.errors)
            assert.is_nil(b.revokeMode)
            assert.is_nil(b.revokeNames)
            assert.is_nil(b.whoGets.salvation)
            assert.is_nil(b.neverOffer.salvation)
            assert.are.same({ "kings", "might" }, (function()
                local keep = {}
                for _, key in ipairs(b.buffOrder) do keep[#keep + 1] = key end
                return keep
            end)(), "the order keeps its other buffs")
            assert.is_true(b.neverOffer.might, "and the other buffs' never-offer marks")
            assert.are.equal("tanks", b.whoGets.kings.rule, "and the other buffs' rules")
            assert.are.equal("Blessing of Kings", ns.BuffData.SpellName(ns.BuffData.ByKey("kings")))
        end)

        it("never offers a removed buff to a member whose old rule or lists named it", function()
            boot({ db = oldSettings() })
            group("party", { { "Ann-Vale", "WARRIOR", "TANK" }, { "Bo-Lake", "ROGUE", "DAMAGER" } })
            local given = buffAll()
            noRemovedBuff(given)
            assert.are.same({}, wow.errors)
            assert.are.same({ "Ann-Vale Blessing of Kings" }, given,
                "Kings stays tanks only; Might stays never-offered")
        end)

        it("never errors on a damaged value where a removed key used to be", function()
            local damaged = { 7, true, "x", {}, { rule = {} }, function() end, 0 / 0 }
            for i, bad in ipairs(damaged) do
                boot({ db = { buffBack = {
                    revokeMode = bad, revokeNames = bad,
                    whoGets = { salvation = bad, kings = { rule = "tanks" } },
                    buffOrder = { "salvation", bad, "might" }, neverOffer = { salvation = bad, might = true },
                } } })
                assert.are.same({}, wow.errors, "damage " .. i)
                local b = ns.db.buffBack
                assert.is_nil(b.revokeMode)
                assert.is_nil(b.whoGets.salvation)
                assert.are.equal("tanks", b.whoGets.kings.rule, "damage " .. i)
                assert.is_true(b.neverOffer.might, "damage " .. i)
            end
        end)

        it("heals the same damage done mid-session", function()
            boot()
            ns.db.buffBack.revokeMode, ns.db.buffBack.revokeNames = "everyone", 5
            ns.db.buffBack.whoGets = { salvation = { rule = "notTanks" }, kings = { rule = "tanks" } }
            ns.db.buffBack.buffOrder = { "salvation", "kings" }
            ns.db.buffBack.neverOffer = { salvation = true }
            group("party", { { "Ann-Vale", "WARRIOR", "TANK" } })
            assert.are.same({ "Ann-Vale Blessing of Kings" }, buffAll(), "still working before any repair")
            noRemovedBuff(buffAll())
            ns.Config.Repair()
            assert.is_nil(ns.db.buffBack.revokeMode)
            assert.is_nil(ns.db.buffBack.whoGets.salvation)
            assert.are.same({}, wow.errors)
        end)

        it("imports a settings line from the old addon, keeping every other setting", function()
            boot()
            local settings = oldSettings()
            settings.schemaVersion = ns.Config.SCHEMA_VERSION
            settings.buffBack.topUpMinutes = 7
            local text = assert(ns.Serialize.Encode({ v = 1, settings = settings }))
            assert.is_true(ns.Profiles.Import(text))
            local b = ns.db.buffBack
            assert.is_nil(b.revokeMode)
            assert.is_nil(b.revokeNames)
            assert.is_nil(b.whoGets.salvation)
            assert.are.equal("tanks", b.whoGets.kings.rule)
            assert.are.equal(7, b.topUpMinutes)
            assert.are.same({}, wow.errors)
            -- And what we export now can't carry them.
            local again = assert(ns.Serialize.Decode(assert(ns.Profiles.Export())))
            assert.is_nil(again.settings.buffBack.revokeMode)
            assert.is_nil(again.settings.buffBack.whoGets.salvation)
        end)

        it("loads a saved profile from the old addon when it is used", function()
            boot()
            local old = oldSettings()
            old.schemaVersion = 6
            ns.db.profiles.Old = old
            local ok = ns.Profiles.Use("Old")
            assert.is_truthy(ok)
            assert.are.same({}, wow.errors)
            local b = ns.db.buffBack
            assert.is_nil(b.revokeMode)
            assert.is_nil(b.whoGets.salvation)
            assert.are.equal("tanks", b.whoGets.kings.rule)
        end)

        it("loads a saved ledger whose favours name Salvation or Revoke, and keeps them as plain text", function()
            boot({ db = { ledger = { entries = {
                { t = 100, who = "Bo-Lake", buffs = { "Blessing of Salvation" }, result = "thanked",
                    returned = "Blessing of Salvation" },
                { t = 200, who = "Cid-Rock", buffs = { "Greater Blessing of Salvation", "Blessing of Kings" },
                    result = "thanked", returned = "Revoke", note = "Revoke" },
            }, totals = { received = 2, thanked = 2, returned = 2 } } } })
            assert.are.same({}, wow.errors)
            assert.are.equal(2, #ns.Ledger.Lines())
            local lines = table.concat(ns.Ledger.Lines(), "\n")
            assert.is_truthy(lines:find("Blessing of Salvation", 1, true), "history is kept as it was")
            assert.is_truthy(lines:find("Revoke", 1, true))
            assert.are.same({}, wow.errors)
        end)

        it("ignores a thank-you receipt or a plan naming Salvation from another copy", function()
            boot()
            assert.is_false(ns.Receipts.Send("Bo-Lake", { key = "salvation" }))
            ns.Receipts.OnReceipt("Bo-Lake-Realm", "salvation")
            ns.Exchange.OnPlan("Bo-Lake-Realm", "salvation,kings")
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("stale auras (black)", function()
        it("ignores a Salvation or Mass Salvation aura on a member: Kings is still offered, nothing breaks", function()
            boot()
            group("party", { { "Ann-Vale", "WARRIOR", "TANK" } })
            wow.state.units.party1.auras = { SALVATION, MASS_SALVATION }
            wow.state.units.party1.auraSources = { "player", "raid9" }
            ns.BuffButton.Refresh()
            assert.is_truthy((macro() or ""):find("Blessing of Kings", 1, true))
            assert.are.same({}, wow.errors)
        end)

        it("a stranger's Salvation buffing you starts no favour", function()
            boot()
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "PALADIN", id = "Bob-Stone" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Blessing of Salvation", spellId = SALVATION })
            assert.are.equal(0, ns.Offers.Count())
            assert.is_nil(ns.Offers.Current())
            assert.are.same({}, wow.errors)
        end)

        it("a cast of the old spell IDs by hand is no buff of ours", function()
            boot()
            ns.Offers.OnCastSent("player", "Bo-Lake", "Cast-9", SALVATION)
            ns.Offers.OnCastSent("player", "Bo-Lake", "Cast-9", MASS_SALVATION)
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("chaos (red tests)", function()
        it("loads old and damaged saved data, changes groups and auras with the stale IDs, and never offers a removed buff",
            function()
                local offered = 0
                local reached = { revokeMode = 0, revokeNames = 0, whoGets = 0, whoGetsAll = 0, buffOrder = 0, neverOffer = 0 }
                for _, seed in ipairs({ 5, 208, 977, 2026 }) do
                    random.seed(seed)
                    local junk = { 7, true, "x", {}, { rule = {} }, "salvation", { "salvation" } }
                    local function pickJunk() return junk[random.random(#junk)] end
                    local function damagedDb()
                        local db = oldSettings()
                        local b = db.buffBack
                        -- Salvation is not marked never-offer here: only its removal keeps it away.
                        b.neverOffer = { revoke = true }
                        local function hit(name) reached[name] = reached[name] + 1 end
                        if random.random() < 0.5 then b.revokeMode = pickJunk() hit("revokeMode") end
                        if random.random() < 0.5 then b.revokeNames = pickJunk() hit("revokeNames") end
                        if random.random() < 0.5 then b.whoGets.salvation = pickJunk() hit("whoGets") end
                        if random.random() < 0.3 then b.whoGets = pickJunk() hit("whoGetsAll") end
                        if random.random() < 0.5 then
                            b.buffOrder = { "salvation", pickJunk(), "revoke", "kings" }
                            hit("buffOrder")
                        end
                        if random.random() < 0.5 then b.neverOffer = { salvation = pickJunk(), revoke = true } hit("neverOffer") end
                        return db
                    end
                    for load = 1, 6 do
                    boot({ db = damagedDb() })
                    local names = { "Ann-Vale", "Bo-Lake", "Cid-Rock", "Dot-Fern", "Eve-Moss" }
                    local classes = { "WARRIOR", "ROGUE", "MAGE", "PRIEST", "PALADIN" }
                    local roles = { "TANK", "HEALER", "DAMAGER", "NONE" }
                    local actions = {
                        function()
                            local members = {}
                            for _, name in ipairs(names) do
                                if random.random() < 0.7 then
                                    members[#members + 1] = { name, classes[random.random(#classes)],
                                        roles[random.random(#roles)] }
                                end
                            end
                            if #members == 0 then members[1] = { names[1], "WARRIOR", "TANK" } end
                            group(random.random() < 0.5 and "raid" or "party", members)
                        end,
                        function()
                            for token, u in pairs(wow.state.units) do
                                if token:find("^party%d") or token:find("^raid%d") then
                                    if random.random() < 0.4 then
                                        u.auras = u.auras or {}
                                        u.auras[#u.auras + 1] = random.random() < 0.5 and SALVATION or MASS_SALVATION
                                        u.auraSources = u.auraSources or {}
                                        u.auraSources[#u.auras] = random.random() < 0.5 and "player" or "raid9"
                                    end
                                end
                            end
                        end,
                        function()
                            local b = ns.db.buffBack
                            b.revokeMode, b.whoGets.salvation, b.neverOffer = pickJunk(), pickJunk(), b.neverOffer
                            ns.BuffButton.Refresh()
                        end,
                        function() ns.Config.Repair() end,
                        function() wow.advance(random.random() * 20) end,
                    }
                    for step = 1, 80 do
                        actions[random.random(#actions)]()
                        local before = #wow.casts
                        local text = macro() or ""
                        assert.is_falsy(text:find("Revoke", 1, true), ("seed %d, step %d"):format(seed, step))
                        assert.is_falsy(text:find("Salvation", 1, true), ("seed %d, step %d"):format(seed, step))
                        scroll()
                        local cast = wow.casts[before + 1]
                        if cast then
                            offered = offered + 1
                            assert.is_falsy(cast.spell:find("Salvation", 1, true), cast.spell)
                            assert.is_falsy(cast.spell:find("Revoke", 1, true), cast.spell)
                            assert.are_not.equal(SALVATION, cast.id)
                            assert.are_not.equal(MASS_SALVATION, cast.id)
                        end
                    end
                    assert.are.same({}, wow.errors, "seed " .. seed .. ", load " .. load)
                    end
                end
                for name, count in pairs(reached) do assert.is_true(count > 0, "never damaged: " .. name) end
                assert.is_true(offered > 50, "buffs offered: " .. offered)
            end)
    end)
end)
