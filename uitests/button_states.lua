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
-- What the simulator (wow-ui-sim ac893c6, #154) can't model, and how this
-- file gets around it:
--   - Its spell data is retail's, with none of Forever's buffs: it has no
--     name for Power Word: Fortitude (10938), and its C_Spell.IsSpellInRange
--     answers nil for a spell it has no data for. While a state is set up,
--     the spellbook fixture (Learn) teaches the player that one buff with
--     A_Admin.LearnSpell, which the spellbook queries read, and answers its
--     name and range (in range of whoever the simulator says is in range).
--     Any other spell is answered by the simulator itself.
--   - A_Admin.AddBuff takes a caster, but the player's aura data still names
--     the player as its source (its docs/admin-api/buffs.md). The buff is
--     added with it, so the aura is real for Blizzard's frames too. Then
--     UNIT_AURA is fired again with that aura in addedAuras, naming the
--     caster's unit token as the game would, or a bad value (#98).
--   - A_Admin.SetInCombat fires PLAYER_REGEN_DISABLED after the lockdown
--     starts; the game fires it just before. See Combat.
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

local learned -- what Learn changed: { class, functions = { [table] = { [key] = original } } }

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

-- Make the player a Priest who knows Power Word: Fortitude. LearnSpell
-- (#100 item 2, fixed in wow-ui-sim d907b88) puts it in the spellbook the
-- simulator's C_SpellBook.IsSpellInSpellBook and IsSpellKnown read, and
-- fires nothing, so SPELLS_CHANGED is fired here, as the game does when your
-- spells change.
function States.Learn()
    if learned then return end
    local _, _, classId = UnitClass("player")
    learned = { class = classId, functions = {} }
    Admin("LearnSpell", States.SPELL.id)
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
    Admin("UnlearnSpell", States.SPELL.id)
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
-- no one. SetTarget and ClearTarget fire PLAYER_TARGET_CHANGED themselves
-- (#100 item 4, fixed in wow-ui-sim d907b88).
function States.Target(name, classIndex)
    if name then
        Admin("SetTarget", name, 60, classIndex or States.WARRIOR, false)
    else
        Admin("ClearTarget")
    end
end

-- A fight starts or ends. The game fires PLAYER_REGEN_DISABLED just before
-- the lockdown starts, the addon's last chance to change its secure button,
-- and PLAYER_REGEN_ENABLED just after it ends. SetInCombat fires each after
-- it changes the state (#100 item 3, fixed in wow-ui-sim d907b88): right for
-- the end, too late for the start. So the start's event is fired here first,
-- and the simulator's own copy then comes a second time, in the lockdown.
-- That's kept rather than hidden: an extra event in a fight is the
-- pessimistic case, and the addon must take it in its stride (BuffButton's
-- Empty leaves the protected button's visibility alone in a lockdown).
function States.Combat(on)
    if on then
        States.Fire("PLAYER_REGEN_DISABLED")
    end
    Admin("SetInCombat", on)
end

-- The party as it was before the first change here, to put back: nil
-- until then. The screenshot build starts in a party of four whose members
-- wear buffs; the scenario run starts in none (#100 item 6, still so at
-- wow-ui-sim ac893c6).
local savedParty

local function SaveParty()
    if savedParty then return end
    savedParty = {}
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            local _, _, classId = UnitClass(unit)
            savedParty[#savedParty + 1] = { name = UnitName(unit), class = classId, level = UnitLevel(unit) }
        end
    end
end

-- Join a party with one other member, newly made (so wearing no buffs), or
-- (no name) leave it. The simulator fires GROUP_ROSTER_UPDATE itself.
function States.Party(name, classIndex)
    SaveParty()
    Admin("SetPartySize", 0)
    if name then
        Admin("SetPartySize", 1)
        Admin("SetPartyMember", 1, name, classIndex or States.WARRIOR, 60)
    end
end

-- Put the party back as it was (its members' names, classes and levels;
-- not their buffs: SetPartyMember now clears a member's auras, #100 item 5,
-- fixed in wow-ui-sim d907b88), if anything here changed it.
function States.RestoreParty()
    if not savedParty then return end
    Admin("SetPartySize", 0)
    if #savedParty > 0 then
        Admin("SetPartySize", #savedParty)
        for i, member in ipairs(savedParty) do
            Admin("SetPartyMember", i, member.name, member.class, member.level)
        end
    end
    savedParty = nil
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

-- How many Lua errors the addon has caught in itself, as /friendly status
-- reports it: every one of its event handlers and timers runs through
-- Diag.Call (Diagnostics.lua), which counts them. nil if it can't be read.
function States.AddonErrorCount()
    local chat = DEFAULT_CHAT_FRAME
    local original, count = chat.AddMessage, nil
    chat.AddMessage = function(_, text)
        count = count or tonumber(tostring(text):match("Lua errors in this addon: (%d+)"))
    end
    local ok = pcall(Command, "status")
    chat.AddMessage = original
    return ok and count or nil
end

-- Runs fn and sorts the Lua errors seen meanwhile. Returns two lists of
-- error text:
--   failures  fn's own error; errors the addon caught in itself (its error
--             count went up: the messages handed to the error handler are
--             listed with them); and the simulator stopping the addon for
--             running too long in one frame
--   others    errors the error handler saw while the addon's count stayed
--             put: Blizzard's own UI tripping over what the simulator
--             doesn't model (its TargetFrame, raid frames and voice chat
--             answer some events with errors there)
function States.Watch(fn, ...)
    local seen = {}
    local before = States.AddonErrorCount()
    local previous = geterrorhandler()
    seterrorhandler(function(err) seen[#seen + 1] = tostring(err) end)
    local ok, err = pcall(fn, ...)
    seterrorhandler(previous)
    local after = States.AddonErrorCount()
    local failures, others = {}, {}
    for _, text in ipairs(seen) do
        -- The simulator stops an addon whose code runs too long in one frame,
        -- as the game does: that counts against the addon, whatever its count.
        local list = text:find("budget exhausted for owner 'FriendlyForever'", 1, true) and failures or others
        list[#list + 1] = text
    end
    if not (before and after) then
        table.insert(failures, 1, "the addon's error count can't be read (/friendly status)")
    elseif after > before then
        table.insert(failures, 1, ("the addon caught %d Lua error(s) in itself"):format(after - before))
        for _, text in ipairs(others) do failures[#failures + 1] = text end
        others = {}
    end
    if not ok then failures[#failures + 1] = tostring(err) end
    return failures, others
end

------------------------------------------------------------------------
-- The states
------------------------------------------------------------------------

-- Each state has Set, which sets it up, and Undo, which puts everything
-- back. Undo is safe to run however far Set got, or twice.

-- A favour owed: name (Aria by default), your target, buffs you from
-- outside your group. Each scenario uses its own stranger: a second buff
-- from someone whose thank-you is still waiting joins that thank-you and
-- owes nothing new (BuffTracker.lua), and on this clock their thank-you
-- waits until the scenario moves time on. Undo ends any fight and party a
-- scenario left, lets the favour go with a right-click (the player's way),
-- turns off buff mode (the "someone buffed you" trigger turns it on), and
-- waits out the line under the button.
function States.FavourFrom(name)
    return {
        Set = function()
            States.PassLoginGrace()
            States.Learn()
            States.Target(name)
            States.BuffedBy("target")
        end,
        Undo = function()
            if InCombatLockdown() then States.Combat(false) end
            local button = States.Button()
            if button and States.MacroTarget() == name then button:Click("RightButton") end
            Command("buffmode off")
            States.RestoreParty()
            States.Unbuff()
            States.Target(nil)
            States.Unlearn()
            States.Advance(States.RESULT_SECONDS)
        end,
    }
end
States.Favour = States.FavourFrom(States.STRANGER)

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
        States.RestoreParty()
        States.Unlearn()
        States.Advance(States.RESULT_SECONDS)
    end,
}

-- For the screenshot job: set a state up and leave it.
local SHOWN = { favour = States.Favour, buffmode = States.GroupMissing }
function States.Show(name)
    local state = SHOWN[name]
    if not state then error("no button state called " .. tostring(name)) end
    -- The simulator starts as a first install, so the walkthrough opened at
    -- login (#47): hidden, as a player who skipped it would see the button.
    local walkthrough = _G.FriendlyForeverWalkthrough
    if type(walkthrough) == "table" and walkthrough:IsShown() then walkthrough:Hide() end
    state.Set()
end
