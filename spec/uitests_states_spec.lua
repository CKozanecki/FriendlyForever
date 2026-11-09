-- Spec: #154, #223
-- The UI scenarios' game-event helpers (uitests/button_states.lua), run here
-- against a stand-in for the simulator's A_Admin that records each call and
-- event in order. They follow what wow-ui-sim ac893c6 does itself (its
-- admin.rs and admin_party_target_helpers.rs): SetTarget, ClearTarget and
-- SetInCombat fire their own events, after the state change, and LearnSpell
-- fills the spellbook. The scenarios themselves run only in the simulator.

-- Loads button_states.lua with a recording A_Admin; returns its States, the
-- log of calls and events, and the stand-in client tables.
local function load(opts)
    opts = opts or {}
    local log = {}
    local function record(entry) log[#log + 1] = entry end
    local client = {
        inCombat = false,
        class = 2, -- the simulator's player starts as a Paladin
        C_SpellBook = {},
        C_Spell = {},
    }
    local function original(name)
        return function() return "simulator's " .. name end
    end
    client.C_SpellBook.IsSpellInSpellBook = original("IsSpellInSpellBook")
    client.C_Spell.GetSpellName = original("GetSpellName")
    client.C_Spell.IsSpellInRange = original("IsSpellInRange")
    client.originals = {
        IsSpellInSpellBook = client.C_SpellBook.IsSpellInSpellBook,
        GetSpellName = client.C_Spell.GetSpellName,
        IsSpellInRange = client.C_Spell.IsSpellInRange,
    }
    local admin = {
        FireEvent = function(event) record("event " .. event) end,
        SetTarget = function(name) record("SetTarget " .. name) end,
        ClearTarget = function() record("ClearTarget") end,
        SetInCombat = function(on)
            client.inCombat = on
            record("SetInCombat " .. tostring(on))
        end,
        LearnSpell = function(id) record("LearnSpell " .. id) end,
        UnlearnSpell = function(id) record("UnlearnSpell " .. id) end,
        SetPlayerClass = function(class)
            client.class = class
            record("SetPlayerClass " .. class)
        end,
        -- The simulator matches the exact spell ID (wow-ui-sim ac893c6's remove_buff).
        RemoveBuff = function(id)
            record("RemoveBuff " .. id)
            if client.stubborn then return end
            for i = #client.auras, 1, -1 do
                if client.auras[i].spellId == id then table.remove(client.auras, i) end
            end
        end,
    }
    client.auras = {} -- the player's helpful auras, as the simulator seeds them
    -- A state's setup makes calls no test here is about (the clock, the
    -- party): they are recorded and ignored.
    if opts.lenient then
        setmetatable(admin, { __index = function(_, name)
            return function(...) record(name .. " " .. select("#", ...)) end
        end })
    end
    local env = setmetatable({
        A_Admin = admin,
        C_SpellBook = client.C_SpellBook,
        C_Spell = client.C_Spell,
        C_UnitAuras = { GetAuraDataByIndex = function(_, i) return client.auras[i] end },
        UnitClass = function() return "x", "X", client.class end,
        GetTime = function() return 0 end,
        UnitExists = function() return false end,
        UnitName = function() return nil end,
        UnitLevel = function() return 1 end,
        SlashCmdList = { FRIENDLYFOREVER = function(text) record("slash " .. text) end },
        UnitInRange = function(unit) return unit == "party1" end,
        InCombatLockdown = function() return client.inCombat end,
    }, { __index = _G })
    local chunk = assert(loadfile("uitests/button_states.lua"))
    setfenv(chunk, env)
    chunk()
    return env.FriendlyForeverUIStates, log, client
end

describe("UI scenarios: game events on wow-ui-sim ac893c6 (#154)", function()
    it("targets and clears the target, leaving PLAYER_TARGET_CHANGED to the simulator (white)", function()
        local States, log = load()
        States.Target("Aria Lindqvist")
        States.Target(nil)
        assert.are.same({ "SetTarget Aria Lindqvist", "ClearTarget" }, log)
    end)

    it("fires PLAYER_REGEN_DISABLED before the lockdown starts, as the game does (white)", function()
        local States, log, client = load()
        States.Combat(true)
        assert.are.same({ "event PLAYER_REGEN_DISABLED", "SetInCombat true" }, log)
        assert.is_true(client.inCombat)
    end)

    it("ends a fight with SetInCombat alone, whose PLAYER_REGEN_ENABLED comes after it (white)", function()
        local States, log, client = load()
        States.Combat(true)
        States.Combat(false)
        assert.are.same({ "event PLAYER_REGEN_DISABLED", "SetInCombat true", "SetInCombat false" }, log)
        assert.is_false(client.inCombat)
    end)
end)

describe("UI scenarios: the spellbook fixture on wow-ui-sim ac893c6 (#154)", function()
    it("teaches the buff with LearnSpell, as a Priest, then says the spells changed (white)", function()
        local States, log, client = load()
        States.Learn()
        assert.are.same({ "LearnSpell 10938", "SetPlayerClass 5", "event SPELLS_CHANGED" }, log)
        assert.are.equal(client.originals.IsSpellInSpellBook, client.C_SpellBook.IsSpellInSpellBook,
            "the spellbook is the simulator's own now")
    end)

    it("answers the buff's name and range, which the simulator has no data for, and passes other spells on (white)", function()
        local States, _, client = load()
        States.Learn()
        assert.are.equal("Power Word: Fortitude", client.C_Spell.GetSpellName(10938))
        assert.is_true(client.C_Spell.IsSpellInRange("Power Word: Fortitude", "party1"))
        assert.is_false(client.C_Spell.IsSpellInRange(10938, "party2"))
        assert.are.equal("simulator's GetSpellName", client.C_Spell.GetSpellName(1243))
        assert.are.equal("simulator's IsSpellInRange", client.C_Spell.IsSpellInRange(1243, "party1"))
    end)

    it("puts everything back on Unlearn: the spell, the class and the functions (white)", function()
        local States, log, client = load()
        States.Learn()
        States.Unlearn()
        assert.are.same({ "LearnSpell 10938", "SetPlayerClass 5", "event SPELLS_CHANGED",
            "UnlearnSpell 10938", "SetPlayerClass 2", "event SPELLS_CHANGED" }, log)
        assert.are.equal(client.originals.GetSpellName, client.C_Spell.GetSpellName)
        assert.are.equal(client.originals.IsSpellInRange, client.C_Spell.IsSpellInRange)
        assert.are.equal(2, client.class)
    end)

    it("does nothing on a second Learn or an Unlearn with nothing learned (black)", function()
        local States, log = load()
        States.Unlearn()
        States.Learn()
        States.Learn()
        assert.are.same({ "LearnSpell 10938", "SetPlayerClass 5", "event SPELLS_CHANGED" }, log)
    end)
end)

describe("UI scenarios: the player's seeded buffs on wow-ui-sim ac893c6 (#223)", function()
    it("takes every Fortitude off the player, the simulator's random 21562 too, and no other buff (white)", function()
        local States, log, client = load()
        client.auras = { { spellId = 1459 }, { spellId = 21562 }, { spellId = 10938 }, { spellId = 21564 } }
        States.NoFortitude()
        assert.are.same({ { spellId = 1459 } }, client.auras)
        assert.are.same({ "RemoveBuff 10938", "RemoveBuff 10937", "RemoveBuff 2791", "RemoveBuff 1245",
            "RemoveBuff 1244", "RemoveBuff 1243", "RemoveBuff 21564", "RemoveBuff 21562" }, log)
    end)

    it("does nothing when the player wears none (white)", function()
        local States, _, client = load()
        client.auras = { { spellId = 1459 } }
        States.NoFortitude()
        assert.are.same({ { spellId = 1459 } }, client.auras)
    end)

    it("fails loudly when a Fortitude stays, so a scenario can't pass or fail by chance (black)", function()
        local States, _, client = load()
        client.auras = { { spellId = 1459 }, { spellId = 21562 } }
        client.stubborn = true
        assert.has_error(function() States.NoFortitude() end, "the player still wears Fortitude (21562)")
    end)

    it("is done by the buff mode state's setup, whatever the simulator seeded (white)", function()
        local States, log, client = load({ lenient = true })
        client.auras = { { spellId = 21562 }, { spellId = 1459 } }
        States.GroupMissing.Set()
        assert.are.same({ { spellId = 1459 } }, client.auras, "no Fortitude is left once the state is set")
        assert.is_true(table.concat(log, "\n"):find("RemoveBuff 21562", 1, true) ~= nil)
    end)

    it("removes exactly the IDs the addon counts as Priest Fortitude (BuffData.lua), so a rank change can't leave one (white)", function()
        local States = load()
        local ns = { Util = {} }
        assert(loadfile("BuffData.lua"))("FriendlyForever", ns)
        local expected = {}
        for _, buff in ipairs(ns.BuffData.CLASSES.PRIEST) do
            if buff.key == "fortitude" then
                for _, id in ipairs(buff.ranks) do expected[#expected + 1] = id end
                for _, id in ipairs(buff.group) do expected[#expected + 1] = id end
            end
        end
        local removed = {}
        for _, id in ipairs(States.FORTITUDE_IDS) do removed[#removed + 1] = id end
        table.sort(expected)
        table.sort(removed)
        assert.are.same(expected, removed)
    end)
end)
