-- Spec: #209
-- Spell IDs come from the game's spell API: the buff table keeps names and
-- rules, the API says which buffs exist and what their IDs are. A buff the
-- API doesn't know is not offered or listed; odd answers never error.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1, GIFT, THORNS_1 = 9885, 1126, 21850, 467
local LIGHT_1, LIGHT = 19977, 19979
local OFFSET = 500000

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Spell IDs from the game's spell API (#209)", function()
    local ns, BuffData, button

    -- A player of class who knows the spells known (default: the druid's).
    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = opts.class or "DRUID"
            state.knownSpells = opts.known or { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
            if opts.before then opts.before(state) end
        end })
        BuffData = ns.BuffData
        button = ns.BuffButton.Frame()
    end

    local function keys(buffs)
        local out = {}
        for i, buff in ipairs(buffs) do out[i] = buff.key end
        return out
    end

    local function armed()
        ns.BuffButton.Refresh()
        local text = button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
        return text and text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    local function party()
        slash("buffmode on")
        wow.setGroup("party", { "Ann-Vale" })
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    local function renumbered(known)
        local ids = {}
        for id in pairs(known) do ids[id + OFFSET] = true end
        return {
            known = ids,
            before = function() wow.renumberSpells(OFFSET) end,
        }
    end

    describe("what the API answers (white)", function()
        it("recognises, offers and casts by name every buff of a client whose IDs differ from Classic's", function()
            local opts = renumbered({ [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true })
            boot(opts)
            party()
            assert.are.same({ "motw", "thorns" }, keys(BuffData.Offerable()))
            local motw = BuffData.ByKey("motw")
            assert.are.equal("Mark of the Wild", BuffData.SpellName(motw))
            assert.is_true(BuffData.Covers(motw, MOTW + OFFSET))
            assert.is_true(BuffData.Covers(motw, GIFT + OFFSET), "the group version, by its name")
            assert.are.equal(motw, BuffData.ForAura(MOTW_1 + OFFSET))
            assert.are.equal(motw, BuffData.ForCast(MOTW + OFFSET))
            assert.is_nil(BuffData.ForAura(MOTW), "Classic's ID is no spell here")
            assert.is_nil(BuffData.ForCast(GIFT + OFFSET), "a group version isn't one of our casts")
            assert.are.equal("Mark of the Wild", armed())
            wow.wearBuff("party1", MOTW + OFFSET, { source = "player" })
            wow.wearBuff("party1", THORNS_1 + OFFSET, { source = "player" })
            assert.is_nil(armed(), "they wear both, recognised by the new IDs")
        end)

        it("a spell the API doesn't know isn't offered or listed, and nothing else changes: Blessing of Light", function()
            boot({ class = "PALADIN", known = { [20217] = true, [LIGHT_1] = true, [LIGHT] = true },
                before = function() wow.removeSpell("Blessing of Light") end })
            assert.are.same({ "kings" }, keys(BuffData.Offerable()))
            assert.are.same({ "kings", "wisdom", "might" }, keys(BuffData.ClassBuffs()),
                "Salvation is not a spell of the simulated client by default")
            assert.is_false(BuffData.Available(BuffData.ByKey("light")))
            assert.is_nil(BuffData.ForAura(LIGHT))
            assert.is_true(BuffData.KEYS.light, "its key is still valid in saved settings")
            ns.Options.SelectType("buffBack")
            for _, row in ipairs(ns.Options.widgets.buffRows) do
                if row.name:IsShown() then assert.is_nil(row.name:GetText():find("light", 1, true)) end
            end
            wow.state.spellNames = {}
            wow.fire("SPELLS_CHANGED")
            assert.are.same({ "kings", "light" }, keys(BuffData.Offerable()), "it returns with the spell, no reload")
        end)

        it("learning a rank updates what is offered and recognised without a reload", function()
            boot({ known = { [MOTW_1] = true } })
            local motw = BuffData.ByKey("motw")
            assert.is_false(BuffData.CanReplace(motw, MOTW), "a rank above yours")
            wow.state.knownSpells[MOTW] = true
            wow.fire("SPELLS_CHANGED")
            assert.is_true(BuffData.CanReplace(motw, MOTW))
            -- A rank the table has never heard of, learned from a trainer.
            wow.state.spellNames[900001] = "Mark of the Wild"
            wow.state.knownSpells[900001] = true
            wow.fire("SPELLS_CHANGED")
            assert.is_true(BuffData.CanReplace(motw, 900001), "the API's answer for the highest rank you know")
            assert.are.equal(motw, BuffData.ForAura(900001))
            assert.are.equal(motw, BuffData.ForCast(900001))
        end)

        it("puts a rank only the API knows first, so it counts as the highest you can replace with", function()
            boot({ known = { [900001] = true }, before = function(state) state.spellNames[900001] = "Mark of the Wild" end })
            local motw = BuffData.ByKey("motw")
            assert.is_true(BuffData.CanReplace(motw, MOTW), "a lower rank than the one you know")
            assert.is_true(BuffData.CanReplace(motw, 900001))
            assert.are.same({ "motw" }, keys(BuffData.Offerable()))
        end)

        it("a group hint whose spell has another name isn't trusted as a group version", function()
            boot({ before = function(state) state.spellNames[GIFT] = "Thorns" end })
            assert.are_not.equal(BuffData.ByKey("motw"), BuffData.ForAura(GIFT))
            assert.is_false(BuffData.Covers(BuffData.ByKey("motw"), GIFT))
        end)

        it("remembers names only up to a limit, then asks again", function()
            boot()
            local thorns = BuffData.ByKey("thorns")
            wow.state.spellNames[900100] = "Nothing"
            assert.is_nil(BuffData.ForAura(900100))
            wow.state.spellNames[900100] = "Thorns"
            assert.is_nil(BuffData.ForAura(900100), "remembered")
            for id = 910000, 910600 do BuffData.ForAura(id) end
            assert.are.equal(thorns, BuffData.ForAura(900100), "forgotten once the limit was passed")
        end)

        it("compares names only on an English client; elsewhere a spell that exists is trusted", function()
            boot({ before = function(state)
                state.spellNames[MOTW_1] = "Mal des Wilden"
                _G.GetLocale = function() return "deDE" end
            end })
            finally(function() _G.GetLocale = nil end)
            assert.is_true(BuffData.Available(BuffData.ByKey("motw")))
            _G.GetLocale = function() return "enUS" end
            BuffData.SpellsChanged()
            assert.is_true(BuffData.Available(BuffData.ByKey("motw")), "the other ranks still have the English name")
            for _, id in ipairs({ MOTW, 9884, 8907, 5234, 6756, 5232 }) do wow.state.spellNames[id] = false end
            BuffData.SpellsChanged()
            assert.is_false(BuffData.Available(BuffData.ByKey("motw")), "the only rank left has another name")
        end)
    end)

    describe("odd answers (black)", function()
        local ODD_NAMES = {
            function() return nil end, function() return 42 end, function() return true end,
            function() return {} end, function() return "" end, function() return ("x"):rep(500) end,
            function() return wow.secret("Mark of the Wild") end, function() error("boom") end,
        }

        it("a missing, secret, non-string, huge or failing name means no buff, and never an error", function()
            for i, answer in ipairs(ODD_NAMES) do
                boot()
                _G.C_Spell.GetSpellName = answer
                _G.GetSpellInfo = nil
                BuffData.SpellsChanged()
                assert.has_no.errors(function()
                    BuffData.Offerable(); BuffData.ClassBuffs(); BuffData.ForAura(MOTW); BuffData.ForCast(MOTW)
                    BuffData.Covers(BuffData.ByKey("motw"), GIFT); BuffData.SpellName(BuffData.ByKey("motw"))
                end, "answer " .. i)
                assert.are.same({}, BuffData.Offerable(), "answer " .. i)
                assert.is_nil(BuffData.ForAura(MOTW), "answer " .. i)
            end
        end)

        it("a negative, huge, fractional, NaN, string, secret or missing ID from the name lookup is ignored", function()
            local nan = 0 / 0
            for _, odd in ipairs({ -1, 0, 1.5, 1e12, 1e20, math.huge, nan, "9885", true, {}, wow.secret(MOTW), false }) do
                boot()
                local real = _G.C_Spell.GetSpellInfo
                _G.C_Spell.GetSpellInfo = function(spell)
                    local info = real(spell)
                    if type(spell) == "string" then return { name = spell, spellID = odd } end
                    return info
                end
                BuffData.SpellsChanged()
                assert.has_no.errors(function() BuffData.Offerable() end)
                local ranks = 0
                for _, buff in ipairs(BuffData.Mine()) do ranks = ranks + 1 end
                assert.are.equal(2, ranks, "the verified hints still serve: " .. tostring(odd))
            end
            boot()
            _G.C_Spell.GetSpellInfo = function() return wow.secret({ spellID = MOTW_1 }) end
            BuffData.SpellsChanged()
            assert.has_no.errors(function() BuffData.Offerable() end)
        end)

        it("a spell two buffs both name as a rank belongs to neither", function()
            boot()
            table.insert(BuffData.CLASSES.DRUID, { key = "dup", name = "Thorns", ranks = { THORNS_1 } })
            finally(function() table.remove(BuffData.CLASSES.DRUID); BuffData.SpellsChanged() end)
            BuffData.SpellsChanged()
            local thorns = BuffData.ByKey("thorns")
            assert.is_true(BuffData.Available(thorns), "its other ranks are its own")
            assert.is_false(BuffData.CanReplace(thorns, THORNS_1), "the shared one is neither's")
            assert.is_false(BuffData.IsKnown(thorns), "the only rank you know is the shared one")
            assert.is_true(BuffData.Available(BuffData.ByKey("motw")))
        end)

        it("a name over the size limit is no name, even where names aren't compared", function()
            boot({ before = function(state)
                state.spellNames[MOTW_1] = ("x"):rep(500)
                for _, id in ipairs({ MOTW, 9884, 8907, 5234, 6756, 5232 }) do state.spellNames[id] = false end
                _G.GetLocale = function() return "deDE" end
            end })
            finally(function() _G.GetLocale = nil end)
            assert.is_false(BuffData.Available(BuffData.ByKey("motw")))
        end)

        it("an ID out of range is never used, even when the game names it", function()
            boot()
            local real = _G.C_Spell.GetSpellName
            _G.C_Spell.GetSpellName = function(id)
                if type(id) == "number" and (id > 1e9 or id < 1) then return "Mark of the Wild" end
                return real(id)
            end
            BuffData.SpellsChanged()
            local motw = BuffData.ByKey("motw")
            for _, id in ipairs({ 1e20, math.huge, -7, 0 }) do
                assert.is_nil(BuffData.ForAura(id))
                assert.is_false(BuffData.Covers(motw, id))
                assert.is_nil(BuffData.ForCast(id))
            end
        end)

        it("an ID the API gives for two buffs belongs to neither as a rank", function()
            boot()
            local real = _G.C_Spell.GetSpellInfo
            _G.C_Spell.GetSpellInfo = function(spell)
                if spell == "Thorns" then return { name = "Thorns", spellID = MOTW_1 } end
                return real(spell)
            end
            BuffData.SpellsChanged()
            local thorns = BuffData.ByKey("thorns")
            -- Rejected: its name isn't Thorns', and the ID is Mark of the Wild's.
            assert.is_false(BuffData.CanReplace(thorns, MOTW_1))
            assert.are.equal(BuffData.ByKey("motw"), BuffData.ForAura(MOTW_1))
            local ids = {}
            for _, id in ipairs({ MOTW_1, THORNS_1 }) do ids[#ids + 1] = BuffData.ForAura(id).key end
            assert.are.same({ "motw", "thorns" }, ids)
        end)

        it("a secret or odd spell ID in an aura or cast is never compared or used as a key", function()
            boot()
            local motw = BuffData.ByKey("motw")
            for _, odd in ipairs({ wow.secret(MOTW), -5, 1e12, 0 / 0, "x", {}, true }) do
                assert.has_no.errors(function()
                    assert.is_nil(BuffData.ForAura(odd))
                    assert.is_false(BuffData.Covers(motw, odd))
                    assert.is_false(BuffData.CanReplace(motw, odd))
                    BuffData.ForCast(odd)
                end)
            end
        end)

        it("saved settings that name an unavailable buff load and keep their values", function()
            local db = { buffBack = { buffOrder = { "light", "kings" }, neverOffer = { light = true } } }
            boot({ class = "PALADIN", db = db, known = { [20217] = true, [LIGHT] = true },
                before = function() wow.removeSpell("Blessing of Light") end })
            assert.are.same({ "light", "kings" }, ns.db.buffBack.buffOrder)
            assert.is_true(ns.db.buffBack.neverOffer.light)
            assert.are.same({ "kings" }, keys(BuffData.Offerable()))
            ns.Options.SelectType("buffBack")
            ns.Options.MoveBuff("kings", 1)
            assert.is_true(ns.db.buffBack.neverOffer.light)
            local saved = {}
            for _, key in ipairs(ns.db.buffBack.buffOrder) do saved[key] = true end
            assert.is_true(saved.light, "reordering the buffs there are keeps the one that's gone")
        end)

        it("damaged buff tables from another addon never error", function()
            boot({ class = "PALADIN", known = { [20217] = true } })
            local paladin = BuffData.CLASSES.PALADIN
            local kings = paladin[1]
            local saved = { kings.ranks, kings.group, kings.groupNames, kings.blockers, kings.name }
            finally(function()
                kings.ranks, kings.group, kings.groupNames, kings.blockers, kings.name = unpack(saved, 1, 5)
                BuffData.SpellsChanged()
            end)
            for _, junk in ipairs({ 5, "x", true, { "a", {}, -1, 1e99 }, wow.secret(1) }) do
                kings.ranks, kings.group, kings.groupNames, kings.blockers = junk, junk, junk, junk
                BuffData.SpellsChanged()
                assert.has_no.errors(function()
                    BuffData.Offerable(); BuffData.ClassBuffs(); BuffData.ForAura(20217); BuffData.Refresh()
                end)
            end
            kings.name = 5
            assert.has_no.errors(function() BuffData.SpellsChanged(); BuffData.Offerable() end)
            local list = BuffData.CLASSES.PALADIN
            BuffData.CLASSES.PALADIN = 5
            assert.has_no.errors(function() BuffData.SpellsChanged(); BuffData.Offerable() end)
            BuffData.CLASSES.PALADIN = list
            local classes = BuffData.CLASSES
            BuffData.CLASSES = { PALADIN = { 5, "x", { name = 5 }, list[1] } }
            assert.has_no.errors(function() BuffData.SpellsChanged(); BuffData.Offerable() end)
            BuffData.CLASSES = 7
            assert.has_no.errors(function() BuffData.SpellsChanged(); BuffData.Offerable() end)
            BuffData.CLASSES = classes
            BuffData.SpellsChanged()
        end)
    end)

    describe("storms (red)", function()
        local NAMES = { "Mark of the Wild", "Thorns", "Gift of the Wild" }

        -- Whether the simulated game has a spell of that name you know,
        -- worked out from the client's own state.
        local function knowsByName(name)
            local all = {}
            for id, n in pairs(wow.SPELL_NAMES) do all[id] = n end
            for id, n in pairs(wow.state.spellNames) do all[id] = n or nil end
            for id, n in pairs(all) do
                if n == name and wow.state.knownSpells[id] then return true end
            end
            return false
        end

        for seed = 1, 40 do
            it("spellbook changes, odd answers and group changes never error or offer a missing spell, seed " .. seed,
                function()
                    boot()
                    party()
                    random.seed(seed)
                    local real = {
                        name = _G.C_Spell.GetSpellName, info = _G.C_Spell.GetSpellInfo,
                    }
                    local odd = { function() return nil end, function() return -3 end,
                        function() return wow.secret("x") end, function() error("boom") end }
                    for _ = 1, 60 do
                        local step = random.random(7)
                        if step == 1 then
                            local name = NAMES[random.random(#NAMES)]
                            wow.state.spellNames = {}
                            wow.removeSpell(name)
                        elseif step == 2 then
                            wow.state.spellNames = {}
                        elseif step == 3 then
                            local id = ({ MOTW_1, MOTW, THORNS_1, 467, 9884 })[random.random(5)]
                            wow.state.knownSpells[id] = random.random() < 0.5 or nil
                        elseif step == 4 then
                            _G.C_Spell.GetSpellName = random.random() < 0.5 and odd[random.random(#odd)] or real.name
                        elseif step == 5 then
                            _G.C_Spell.GetSpellInfo = random.random() < 0.5 and odd[random.random(#odd)] or real.info
                        elseif step == 6 then
                            wow.setGroup("party", random.random() < 0.5 and { "Ann-Vale" } or {})
                            wow.fire("GROUP_ROSTER_UPDATE")
                        elseif wow.state.units.party1 then
                            wow.wearBuff("party1", ({ MOTW, GIFT, THORNS_1 })[random.random(3)], { source = "player" })
                        end
                        wow.fire("SPELLS_CHANGED")
                        local casts = #wow.casts
                        local spell
                        assert.has_no.errors(function() spell = armed() end)
                        assert.are.equal(casts, #wow.casts, "nothing casts without a press")
                        -- The client says what exists: with its names intact an armed spell
                        -- is one the player knows, by name.
                        if spell and _G.C_Spell.GetSpellName == real.name then
                            assert.is_true(knowsByName(spell), "armed " .. spell)
                        end
                    end
                    _G.C_Spell.GetSpellName, _G.C_Spell.GetSpellInfo = real.name, real.info
                end)
        end
    end)
end)
