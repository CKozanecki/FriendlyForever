-- Spec: #154
-- The UI scenarios' game-event helpers (uitests/button_states.lua), run here
-- against a stand-in for the simulator's A_Admin that records each call and
-- event in order. They follow what wow-ui-sim ac893c6 does itself (its
-- admin.rs and admin_party_target_helpers.rs): SetTarget, ClearTarget and
-- SetInCombat fire their own events, after the state change, and LearnSpell
-- fills the spellbook. The scenarios themselves run only in the simulator.

-- Loads button_states.lua with a recording A_Admin; returns its States, the
-- log of calls and events, and the stand-in client tables.
local function load()
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
    }
    local env = setmetatable({
        A_Admin = admin,
        C_SpellBook = client.C_SpellBook,
        C_Spell = client.C_Spell,
        UnitClass = function() return "x", "X", client.class end,
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
