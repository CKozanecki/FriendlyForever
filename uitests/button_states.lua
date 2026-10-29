-- The buff-back button's real states, set up in the UI simulator the way the
-- game would make them (#83): someone outside your group buffs you, or a
-- group member is missing your buff. The scenarios (scenarios.lua) check
-- them, and the screenshot job shows them: it runs this file, then
-- FriendlyForeverUIStates.Show("<state>"), through --exec-lua. So this file
-- only defines things, and calls no test().
--
-- The simulator loads the test files in name order, so this one comes before
-- scenarios.lua and FriendlyForeverUIStates is there when they run.
--
-- What the simulator can't model, and how this file gets around it:
--   - Its player has a fixed retail Paladin's spellbook, its spell data has
--     none of Forever's buffs, and it has no C_Spell.IsSpellInRange. While a
--     state is set up, the spellbook fixture (Learn) makes the client know
--     one buff, Power Word: Fortitude, by its spell ID and name, in range of
--     whoever the simulator says is in range. Any other spell is answered by
--     the simulator itself.
--   - A_Admin.AddBuff always names the player as the caster. The buff is
--     added with it, so the aura is real for Blizzard's frames too. Then
--     UNIT_AURA is fired again with that aura in addedAuras, naming the
--     caster's unit token as the game would.
--   - Time runs on the simulator's manual clock (A_Admin.SetManualClock),
--     moved on only by Advance, so the login grace and the result line under
--     the button pass whatever the runner's speed.
--
-- Each state's Undo puts back everything its Set did.

local States = {}
FriendlyForeverUIStates = States

-- The buff the fixture teaches: Power Word: Fortitude, its highest rank
-- (BuffData.lua). Its hints are the longest the button shows:
-- "buffed you - give Power Word: Fortitude" and "missing your Power Word:
-- Fortitude" (#64).
States.SPELL = { id = 10938, name = "Power Word: Fortitude" }
States.PRIEST, States.WARRIOR = 5, 1 -- class indexes, as A_Admin takes them
States.STRANGER = "Aria Lindqvist"  -- buffs you from outside your group
States.GROUPMATE = "Brenna Holt"    -- in your party, missing your buff
-- Announcer.LOGIN_GRACE (10 seconds after logging in, nothing is thanked or
-- owed), and a second.
States.LOGIN_GRACE_SECONDS = 11
-- BuffButton.RESULT_SHOWN_SECONDS (4: how long a line such as "Let Aria go."
-- keeps the button up), and a second.
States.RESULT_SECONDS = 5

-- The secure attribute the button's macro is written to (BuffButton.lua).
States.MACRO_ATTRIBUTE = "*macrotext1"

local function Admin(name, ...)
    local fn = A_Admin and A_Admin[name]
    if type(fn) ~= "function" then error("the simulator has no A_Admin." .. name, 2) end
    return fn(...)
end

function States.Fire(event, ...)
    Admin("FireEvent", event, ...)
end

-- The manual clock, switched on once: from then on game time moves only here.
local clockOn, graceOver = false, false
function States.Advance(seconds)
    if not clockOn then
        -- It can be switched on only once; a second try fails, harmlessly.
        pcall(A_Admin.SetManualClock, GetTime())
        clockOn = true
    end
    Admin("AdvanceTime", seconds)
end

function States.PassLoginGrace()
    if graceOver then return end
    States.Advance(States.LOGIN_GRACE_SECONDS)
    graceOver = true
end

------------------------------------------------------------------------
-- The spellbook fixture
------------------------------------------------------------------------

local learned -- what Learn replaced: { class, functions = { [table] = { [key] = original } } }

local function IsOurSpell(spell)
    return spell == States.SPELL.id or spell == States.SPELL.name
end

-- Replace namespace[key] with a function that answers for our spell and
-- passes anything else to the simulator's own (if it has one).
local function Answer(namespace, key, forOurSpell)
    local original = namespace[key]
    learned.functions[namespace] = learned.functions[namespace] or {}
    learned.functions[namespace][key] = { original = original }
    namespace[key] = function(spell, ...)
        if IsOurSpell(spell) then return forOurSpell(spell, ...) end
        if original then return original(spell, ...) end
    end
end

-- Make the player a Priest who knows Power Word: Fortitude. SPELLS_CHANGED
-- is what the game fires when your spells change.
function States.Learn()
    if learned then return end
    local _, _, classId = UnitClass("player")
    learned = { class = classId, functions = {} }
    Answer(C_SpellBook, "IsSpellInSpellBook", function() return true end)
    Answer(C_Spell, "GetSpellName", function() return States.SPELL.name end)
    Answer(C_Spell, "IsSpellInRange", function(_, unit) return UnitInRange(unit) and true or false end)
    Admin("SetPlayerClass", States.PRIEST)
    States.Fire("SPELLS_CHANGED")
end

function States.Unlearn()
    if not learned then return end
    for namespace, keys in pairs(learned.functions) do
        for key, saved in pairs(keys) do namespace[key] = saved.original end
    end
    if learned.class then Admin("SetPlayerClass", learned.class) end
    learned = nil
    States.Fire("SPELLS_CHANGED")
end

------------------------------------------------------------------------
-- Game events
------------------------------------------------------------------------

-- The player's aura for our spell, as the client reports it, or nil.
local function PlayerAura()
    for i = 1, 255 do
        local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
        if not aura then return nil end
        if aura.spellId == States.SPELL.id then return aura end
    end
end

-- Someone buffs you with our spell. sourceUnit is what the game names as
-- the caster: a unit token, or anything a damaged or unexpected event could
-- carry. The aura is added for real first (the simulator names you as its
-- caster), then UNIT_AURA names sourceUnit, as the game does for a buff
-- from your target, say.
function States.BuffedBy(sourceUnit)
    Admin("RemoveBuff", States.SPELL.id)
    Admin("AddBuff", States.SPELL.id, States.SPELL.name, "135987", 3600, 1)
    local real = PlayerAura()
    if not real then error("the simulator didn't add the buff", 2) end
    local aura = {}
    for key, value in pairs(real) do aura[key] = value end
    aura.sourceUnit = sourceUnit
    States.Fire("UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { aura } })
end

function States.Unbuff()
    Admin("RemoveBuff", States.SPELL.id)
end

-- Target a player outside your group (classIndex: a Warrior by default), or
-- no one.
function States.Target(name, classIndex)
    if name then
        Admin("SetTarget", name, 60, classIndex or States.WARRIOR, false)
    else
        Admin("ClearTarget")
    end
    States.Fire("PLAYER_TARGET_CHANGED")
end

-- A fight starts or ends, in the order the game does it: the event comes
-- just before the lockdown at the start, and just after it at the end.
function States.Combat(on)
    if on then
        States.Fire("PLAYER_REGEN_DISABLED")
        Admin("SetInCombat", true)
    else
        Admin("SetInCombat", false)
        States.Fire("PLAYER_REGEN_ENABLED")
    end
end

-- Join a party with one other member, or (size 0) leave it. The simulator
-- fires GROUP_ROSTER_UPDATE itself.
function States.Party(name, classIndex)
    if name then
        Admin("SetPartySize", 1)
        Admin("SetPartyMember", 1, name, classIndex or States.WARRIOR, 60)
    else
        Admin("SetPartySize", 0)
    end
end

local function Command(text)
    SlashCmdList.FRIENDLYFOREVER(text)
end

------------------------------------------------------------------------
-- Reading the button
------------------------------------------------------------------------

function States.Button()
    return _G.FriendlyForeverBuffButton
end

-- The macro the button would run on a press, or nil when it's empty.
function States.Macro()
    local button = States.Button()
    return button and button:GetAttribute(States.MACRO_ATTRIBUTE)
end

-- The name the button's macro targets, or nil.
function States.MacroTarget()
    local macro = States.Macro()
    return type(macro) == "string" and macro:match("/targetexact ([^\n]+)") or nil
end

-- Runs fn, catching Lua errors from the addon as well as from fn: the addon
-- hands its own to the error handler (Diagnostics.lua) and carries on.
-- Returns the errors seen, as text.
function States.Watch(fn, ...)
    local errors = {}
    local previous = geterrorhandler()
    seterrorhandler(function(err) errors[#errors + 1] = tostring(err) end)
    local ok, err = pcall(fn, ...)
    seterrorhandler(previous)
    if not ok then errors[#errors + 1] = tostring(err) end
    return errors
end

------------------------------------------------------------------------
-- The states
------------------------------------------------------------------------

-- Each state has Set, which sets it up, and Undo, which puts everything
-- back. Undo is safe to run however far Set got, or twice.

-- A favour owed: Aria, your target, buffs you from outside your group.
-- Undo ends any fight and party a scenario left, lets her favour go with a
-- right-click (the player's way), turns off buff mode (the "someone buffed
-- you" trigger turns it on), and waits out the line under the button.
States.Favour = {
    Set = function()
        States.PassLoginGrace()
        States.Learn()
        States.Target(States.STRANGER)
        States.BuffedBy("target")
    end,
    Undo = function()
        if InCombatLockdown() then States.Combat(false) end
        local button = States.Button()
        if button and States.MacroTarget() == States.STRANGER then button:Click("RightButton") end
        Command("buffmode off")
        if IsInGroup() then States.Party(nil) end
        States.Unbuff()
        States.Target(nil)
        States.Unlearn()
        States.Advance(States.RESULT_SECONDS)
    end,
}

-- Buff mode, in a party with Brenna, who is missing your buff.
States.GroupMissing = {
    Set = function()
        States.PassLoginGrace()
        States.Learn()
        States.Party(States.GROUPMATE)
        Command("buffmode on")
    end,
    Undo = function()
        Command("buffmode off")
        States.Party(nil)
        States.Unlearn()
        States.Advance(States.RESULT_SECONDS)
    end,
}

-- For the screenshot job: set a state up and leave it.
local SHOWN = { favour = States.Favour, buffmode = States.GroupMissing }
function States.Show(name)
    local state = SHOWN[name]
    if not state then error("no button state called " .. tostring(name)) end
    state.Set()
end
