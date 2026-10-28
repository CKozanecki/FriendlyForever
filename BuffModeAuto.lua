-- When buff mode turns on and off by itself. Each trigger is an option on
-- the Buff Back tab. Triggers only switch buff mode: they never cast.
--
-- Turns on (on by default; the first time a session, it says where to
-- switch these, and the "Start here" walkthrough, #47, shows them):
--   joining a group or raid;
--   a group member dying, after the group's first pull (until the next one);
--   someone outside your group buffing you (a group member's buff isn't a
--   favour, so it doesn't count).
-- Turns off (on by default), but only buff mode a trigger turned on, never
-- buff mode you turned on yourself:
--   the first pull (PLAYER_REGEN_DISABLED);
--   everyone being buffed (never assumed when someone's buffs can't be read);
--   a timeout, whichever comes first.
--
-- Nothing turns on in a fight: a trigger that fires in one waits for it to
-- end (a death is answered when the fight is over anyway).
local _, ns = ...

local Auto = {}
ns.BuffModeAuto = Auto

local frame
local ready = false      -- the login (or reload) has finished: the roster is real
local inGroup = false    -- in a group at the last roster update
local fighting = false   -- between PLAYER_REGEN_DISABLED and _ENABLED
local dead = {}          -- [name] = true for group members last seen dead
local pulled = false     -- this group has fought since you joined it
local deathSeen = false  -- a group member died during this fight
local pendingWhy         -- a trigger that fired in a fight, to act on after it
local timeoutToken = 0   -- bumps each auto start, so an old timer does nothing

local function Cfg() return ns.db.buffBack end

local function InGroup()
    return ns.Util.ReadGameValues(IsInGroup) == true
end

local function IsGroupUnit(unit)
    return type(unit) == "string" and (unit:find("^party%d") or unit:find("^raid%d")) ~= nil
end

-- Nothing left to do: no favours owed, and no group member missing your buffs
-- that you could see and reach (GroupBuffs never calls an unreadable member done).
local function Settled()
    if ns.Offers.Count() > 0 then return false end
    local offer, _, settled = ns.GroupBuffs.Next()
    return offer == nil and settled == true
end

-- The timeout in minutes (0: none); a value damaged mid-session reads as the default.
local function TimeoutMinutes()
    local minutes = Cfg().autoOffMinutes
    if type(minutes) ~= "number" then return ns.Config.DEFAULTS.buffBack.autoOffMinutes end
    return minutes
end

-- Turn buff mode off if a trigger turned it on and it's done. Called on every
-- button refresh, and by the timeout's own timer with the minutes it waited.
function Auto.Check(timedOutAfter)
    if not ns.db or not ns.BuffMode.IsAuto() then return end
    local cfg = Cfg()
    if timedOutAfter then
        return ns.BuffMode.Set(false, { why = timedOutAfter .. " minutes passed" })
    end
    if InCombatLockdown() then return end
    if cfg.autoOffDone == true and Settled() then
        ns.BuffMode.Set(false, { why = "everyone has your buffs" })
    end
end

local function StartTimeout()
    timeoutToken = timeoutToken + 1
    local token, minutes = timeoutToken, TimeoutMinutes()
    if minutes <= 0 then return end
    C_Timer.After(minutes * 60, ns.Diag.Wrap(function()
        if token == timeoutToken then Auto.Check(minutes) end
    end))
end

local function TurnOn(why)
    if fighting or InCombatLockdown() then
        pendingWhy = pendingWhy or why
        return
    end
    if ns.BuffMode.IsOn() then return end -- already on (yours, or a trigger's)
    -- Nothing to do: don't lend a key just to hand it back.
    if Settled() then return end
    ns.BuffMode.Set(true, { auto = true, why = why })
    if ns.BuffMode.IsAuto() then StartTimeout() end
end

local function GroupUnitNames()
    local out = {}
    local prefix, count = "party", 4
    if ns.Util.ReadGameValues(IsInRaid) == true then prefix, count = "raid", 40 end
    for i = 1, count do
        local unit = prefix .. i
        local name = ns.Util.UnitFullName(unit)
        if name then out[name] = unit end
    end
    return out
end

-- Who in the group is dead now, so only a death from here on counts (a
-- member who joins dead, or releases as a ghost, isn't a new death).
local function NoteWhoIsDead()
    local now = {}
    for name, unit in pairs(GroupUnitNames()) do
        if ns.Util.ReadGameValues(UnitIsDeadOrGhost, unit) == true then now[name] = true end
    end
    dead = now
end

function Auto.OnRosterUpdate()
    local nowIn = InGroup()
    NoteWhoIsDead()
    -- Before the login finishes the roster isn't loaded: being in a group
    -- then isn't joining one (buff mode is off after a login).
    if not ready then
        inGroup = nowIn
        return
    end
    if nowIn and not inGroup then
        pulled = false
        if Cfg().autoOnJoin == true then TurnOn("you joined a group") end
    elseif not nowIn then
        pulled, deathSeen = false, false
    end
    inGroup = nowIn
end

-- PLAYER_ENTERING_WORLD on a login or reload: the group as it is now is
-- where we start, not a group joined.
function Auto.OnEnteringWorld(isLogin, isReload)
    if not (isLogin or isReload) then return end
    ready = true
    inGroup = InGroup()
    pulled, deathSeen, pendingWhy = false, false, nil
    NoteWhoIsDead()
end

-- PLAYER_REGEN_DISABLED. The button empties itself for the fight in the
-- same event, so buff mode ends without refreshing it (EndForFight).
function Auto.OnCombatStart()
    fighting = true
    if inGroup then pulled = true end
    deathSeen, pendingWhy = false, nil
    if Cfg().autoOffPull == true and ns.BuffMode.IsAuto() then
        ns.BuffMode.EndForFight("the fight started")
    end
end

local function OnDeath()
    if pulled and Cfg().autoOnDeath == true then TurnOn("someone in your group died") end
end

function Auto.OnCombatEnd()
    fighting = false
    local why = pendingWhy
    pendingWhy = nil
    if deathSeen then
        deathSeen = false
        OnDeath()
    end
    if why then TurnOn(why) end
end

-- A death is a member going from alive to dead: a ghost's health changing
-- (releasing, say) isn't another one.
function Auto.OnUnitHealth(unit)
    if not IsGroupUnit(unit) then return end
    local name = ns.Util.UnitFullName(unit)
    if not name then return end
    local isDead = ns.Util.ReadGameValues(UnitIsDeadOrGhost, unit)
    if isDead == false then dead[name] = nil end
    if isDead ~= true or dead[name] then return end
    dead[name] = true
    if fighting or InCombatLockdown() then
        deathSeen = true
    else
        OnDeath()
    end
end

-- Someone outside your group buffed you (Offers.Owe).
function Auto.OnBuffed()
    if Cfg().autoOnBuffed == true then TurnOn("someone buffed you") end
end

function Auto.Create()
    if frame then return end
    inGroup = InGroup()
    frame = CreateFrame("Frame")
    local handlers = {
        GROUP_ROSTER_UPDATE = Auto.OnRosterUpdate,
        PLAYER_ENTERING_WORLD = Auto.OnEnteringWorld,
        PLAYER_REGEN_DISABLED = Auto.OnCombatStart,
        PLAYER_REGEN_ENABLED = Auto.OnCombatEnd,
        UNIT_HEALTH = Auto.OnUnitHealth,
    }
    for event in pairs(handlers) do frame:RegisterEvent(event) end
    frame:SetScript("OnEvent", function(_, event, ...) ns.Diag.Call(handlers[event], ...) end)
    ns.Offers.OnOwe(Auto.OnBuffed)
end
