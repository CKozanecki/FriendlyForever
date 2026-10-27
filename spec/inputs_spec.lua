-- Black tests for the buff-back work: bad, damaged and hostile inputs to
-- each helper and saved field, handled without errors and without trusting
-- what can't be read.
local wow = require("spec.support.wow")

describe("Bad inputs", function()
    local ns

    before_each(function() ns = wow.boot() end)

    describe("Util.ReadGameValues", function()
        local Read

        before_each(function() Read = ns.Util.ReadGameValues end)

        it("gives nothing for a missing function, or a function that throws", function()
            assert.is_nil(Read(nil))
            assert.is_nil(Read("not a function"))
            assert.is_nil(Read(function() error("restricted") end))
        end)

        it("drops each secret value but keeps the readable ones", function()
            local a, b, c = Read(function() return wow.secret(1), "two", wow.secret(3) end)
            assert.is_nil(a)
            assert.are.equal("two", b)
            assert.is_nil(c)
        end)

        it("passes arguments through", function()
            assert.are.equal(5, Read(function(x, y) return x + y end, 2, 3))
        end)
    end)

    describe("Util.UnitClassIf", function()
        it("gives nothing for no unit, a token that is now someone else, or an unreadable class", function()
            local If = ns.Util.UnitClassIf
            assert.is_nil(If(nil, "Bob-Stone"))
            wow.addUnit("nameplate1", { name = "Ann", surname = "Vale", class = "MAGE" })
            assert.is_nil(If("nameplate1", "Bob-Stone"))
            local name, file = If("nameplate1", "Ann-Vale")
            assert.are.same({ "Mage", "MAGE" }, { name, file })
            wow.addUnit("nameplate2", { name = "Cid", surname = "Moon", class = "" })
            assert.is_nil(If("nameplate2", "Cid-Moon"))
            wow.state.unitsRestricted = true
            assert.is_nil(If("nameplate1", "Ann-Vale"), "names are secret: can't tell it's still them")
        end)
    end)

    describe("BuffButton.IsIntendedPlayer", function()
        it("can't tell from a secret, a non-string, an empty or a junk name", function()
            local Is = ns.BuffButton.IsIntendedPlayer
            assert.is_nil(Is(wow.secret("Bob"), "Bob-Stone"))
            assert.is_nil(Is(42, "Bob-Stone"))
            assert.is_nil(Is("", "Bob-Stone"))
            assert.is_nil(Is("Bob!!", "Bob-Stone"))
        end)

        it("matches the full name or the first name, and nothing else", function()
            local Is = ns.BuffButton.IsIntendedPlayer
            assert.is_true(Is("Bob Stone", "Bob-Stone"))
            assert.is_true(Is("Bob-Stone", "Bob-Stone"))
            assert.is_true(Is("Bob", "Bob-Stone"))
            assert.is_false(Is("Bob-Other", "Bob-Stone"), "same first name, another surname")
            assert.is_false(Is("Ann", "Bob-Stone"))
        end)
    end)

    describe("BuffData", function()
        it("knows nothing when the spellbook functions are missing or throw", function()
            _G.C_SpellBook = nil
            _G.IsSpellKnown = function() error("not loaded") end
            _G.IsPlayerSpell = nil
            ns.BuffData.SpellsChanged()
            assert.are.same({}, ns.BuffData.Mine())
            assert.are.same({}, wow.errors)
        end)

        it("doesn't cache a class it couldn't read", function()
            wow.state.class = "DRUID"
            wow.state.knownSpells = { [1126] = true }
            _G.UnitClass = function() return wow.secret("Druid"), wow.secret("DRUID") end
            ns.BuffData.SpellsChanged()
            assert.are.same({}, ns.BuffData.Mine())
            _G.UnitClass = function() return "Druid", "DRUID" end
            assert.are.equal(1, #ns.BuffData.Mine(), "read again once readable")
        end)

        it("has no name or icon for a spell the client doesn't have", function()
            local fake = { ranks = { 999999 } }
            assert.is_nil(ns.BuffData.SpellName(fake))
            assert.is_nil(ns.BuffData.Icon(fake))
            assert.is_nil(ns.BuffData.ForAura("not an id"))
        end)
    end)

    describe("saved Buff Back settings", function()
        it("repairs every damaged field", function()
            ns = wow.boot({ db = { buffBack = {
                enabled = "yes", sayLine = 1, unlocked = {}, owedMinutes = 9999,
                messages = { 7, "ok {name}", string.rep("x", 400) },
                position = "middle", junk = "drop me",
            } } })
            local b = ns.db.buffBack
            assert.is_true(b.enabled)
            assert.is_false(b.sayLine)
            assert.is_false(b.unlocked)
            assert.are.equal(ns.Config.LIMITS.owedMinutes.max, b.owedMinutes)
            assert.are.equal("", b.messages[1])
            assert.are.equal("ok {name}", b.messages[2])
            assert.are.equal(255, #b.messages[3])
            assert.are.same({ point = "CENTER", x = 0, y = -180 }, b.position)
            assert.is_nil(b.junk)
        end)

        it("treats a string or negative favour time as the default or the minimum", function()
            ns = wow.boot({ db = { buffBack = { owedMinutes = "ten" } } })
            assert.are.equal(10, ns.db.buffBack.owedMinutes)
            ns = wow.boot({ db = { buffBack = { owedMinutes = -5 } } })
            assert.are.equal(1, ns.db.buffBack.owedMinutes)
        end)
    end)

    describe("saved ledger returns", function()
        it("drops damaged returned and return-note values, and repairs the counts", function()
            ns = wow.boot({ db = { ledger = {
                entries = {
                    { t = 5, who = "Bob-Stone", returned = 7, returnNote = {} },
                    { t = 6, who = "Ann-Vale", returned = "Thorns|cff", returnNote = string.rep("n", 400) },
                },
                totals = { returned = -3 },
                today = { day = "2026-10-26", returned = "many" },
            } } })
            local e = ns.db.ledger.entries
            assert.is_nil(e[1].returned)
            assert.is_nil(e[1].returnNote)
            assert.are.equal("Thornscff", e[2].returned, "escape codes stripped")
            assert.are.equal(ns.Ledger.MAX_TEXT, #e[2].returnNote)
            assert.are.equal(0, ns.db.ledger.totals.returned)
            assert.are.equal(0, ns.Ledger.Summary().todayReturned)
        end)
    end)
end)
