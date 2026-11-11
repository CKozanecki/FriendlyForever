-- When buff mode turns on and off by itself. Each trigger is an option on
-- the Buff Back tab. Triggers only switch buff mode: they never cast.
--
-- Turns on (on by default; the first time a session, BuffMode.Set says where
-- to switch these; the walkthrough, Walkthrough.lua (#47), shows them):
--   being in a dungeon or raid with your group (#256): entering one while in
--   a group, or joining a group while inside one. It then waits for everyone
--   (below). Joining a group anywhere else turns it on only with another
--   member close by (UnitInRange), checked when you join and on roster
--   changes for NEARBY_SECONDS after;
--   a group member dying, after the group's first pull (until the next one);
--   someone outside your group buffing you (a group member's buff isn't a
--   favour, so it doesn't count), except where quiet mode holds in a capital
--   city: there it would end quiet mode at the first stranger's buff (#34).
-- Turns off (on by default), but only buff mode a trigger turned on, never
-- buff mode you turned on yourself:
--   the first pull (PLAYER_REGEN_DISABLED);
--   everyone being buffed (never assumed when someone's buffs can't be read);
--   a timeout, whichever comes first.
-- Turned on in a dungeon or raid, it waits for everyone (#256): it stays on
-- until every member is in there with you and has your buffs, or until the
-- first pull, whichever comes first. The timeout doesn't apply inside until
-- then; it starts at the first pull or when you leave. A member who is offline, out of sight, or whose
-- name or whereabouts can't be read isn't in.
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
local pendingInside      -- and whether it was the dungeon-or-raid trigger
local insideWait = false -- buff mode that trigger turned on waits for everyone (#256)
local timeoutToken = 0   -- bumps each auto start, so an old timer does nothing
local quietWhy           -- a trigger refused while a battleground was quiet
local joinedAt           -- when you joined a group out in the world, while it waits for someone close by

local function Cfg() return ns.db.buffBack end

-- Out in the world, joining a group turns buff mode on only with someone
-- close by (#256): checked when you join, and on roster changes this long after.
Auto.NEARBY_SECONDS = 120

local function InGroup()
    return ns.Util.ReadGameValues(IsInGroup) == true
end

-- In a dungeon or raid (#256): not in a battleground or arena, and never
-- when the game won't say.
local function InDungeonOrRaid()
    local _, kind = ns.Util.ReadGameValues(IsInInstance)
    if kind == "party" then return true, "dungeon" end
    if kind == "raid" then return true, "raid" end
    return false
end

-- Whether every other group member is in here with you: connected and shown
-- by the game. A member whose connection or visibility can't be read isn't
-- (#256); one whose name can't be read leaves GroupBuffs unsettled anyway.
local function EveryoneInside()
    local prefix, count = "party", 4
    if ns.Util.ReadGameValues(IsInRaid) == true then prefix, count = "raid", 40 end
    for i = 1, count do
        local unit = prefix .. i
        -- A slot that can't be read is checked like a member.
        if ns.Util.ReadGameValues(UnitExists, unit) ~= false
            and ns.Util.ReadGameValues(UnitIsUnit, unit, "player") ~= true then
            if ns.Util.ReadGameValues(UnitIsConnected, unit) ~= true then return false end
            if ns.Util.ReadGameValues(UnitIsVisible, unit) ~= true then return false end
        end
    end
    return true
end

local function IsGroupUnit(unit)
    return type(unit) == "string" and (unit:find("^party%d") or unit:find("^raid%d")) ~= nil
end

-- Nothing left to do: no favours owed, and no group member missing your buffs
-- that you could see and reach (GroupBuffs never calls an unreadable member done).
-- inside: waiting for everyone in a dungeon or raid, so also everyone in
-- there with you (#256). Also why, for the message.
local function Settled(inside)
    if ns.Offers.Count() > 0 then return false end
    local offer, _, settled, held = ns.GroupBuffs.Next()
    if offer ~= nil or settled ~= true then return false end
    if inside and not EveryoneInside() then return false end
    -- Your water buff waits for water (Water.lua): nobody has it, so say so.
    if held then return true, ns.Water.HeldReason(held) end
    if inside then return true, "everyone is here and has your buffs" end
    return true, "everyone has your buffs"
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
    if cfg.autoOffDone ~= true then return end
    local done, why = Settled(insideWait)
    if done then ns.BuffMode.Set(false, { why = why }) end
end

local function StartTimeout()
    timeoutToken = timeoutToken + 1
    local token, minutes = timeoutToken, TimeoutMinutes()
    if minutes <= 0 then return end
    C_Timer.After(minutes * 60, ns.Diag.Wrap(function()
        if token == timeoutToken then Auto.Check(minutes) end
    end))
end

-- Waiting for everyone in a dungeon or raid: no timeout (#256).
local function WaitInside()
    insideWait = true
    timeoutToken = timeoutToken + 1
end

-- inside: the dungeon-or-raid trigger, so buff mode waits for everyone.
local function TurnOn(why, inside)
    -- A battle under way: nothing turns on, and nobody's buffs are read. The
    -- trigger is kept in case it was only the phase not being read yet.
    if ns.Battleground.Quiet() then
        quietWhy = quietWhy or why
        return
    end
    if fighting or InCombatLockdown() then
        -- The first trigger waits, but the dungeon-or-raid one outranks
        -- the others: after the fight it waits for everyone.
        if not pendingWhy or (inside and not pendingInside) then pendingWhy, pendingInside = why, inside end
        return
    end
    if ns.BuffMode.IsOn() then
        -- A trigger's buff mode, met by the dungeon or raid: it waits for
        -- everyone now. Yours is yours: no trigger turns it off.
        if inside and ns.BuffMode.IsAuto() then WaitInside() end
        return
    end
    -- Nothing to do: don't lend a key just to hand it back.
    if Settled(inside) then return end
    -- Set first: turning on refreshes the button, which checks it at once.
    if inside then WaitInside() else insideWait = false end
    ns.BuffMode.Set(true, { auto = true, why = why })
    if ns.BuffMode.IsAuto() and not inside then StartTimeout() end
end

-- Being in a dungeon or raid with your group (#256), if that trigger is on.
local function InsideWithGroup()
    local inside, kind = InDungeonOrRaid()
    if inside and Cfg().autoOnJoin == true then
        TurnOn("you're in a " .. kind .. " with your group", true)
    end
    return inside
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

-- Whether another member is within the game's group range check (UnitInRange,
-- about 40 yards). A range the game won't check or give isn't close.
local function SomeoneClose()
    for _, unit in pairs(GroupUnitNames()) do
        if ns.Util.ReadGameValues(UnitIsUnit, unit, "player") ~= true then
            -- The game answers false when it can't check (false, false).
            if ns.Util.ReadGameValues(UnitInRange, unit) == true then return true end
        end
    end
    return false
end

-- A group joined out in the world: turn on once someone is close by, within
-- NEARBY_SECONDS of joining (#256). Once it has turned on, it stops looking.
local function JoinedNearby()
    if GetTime() - joinedAt > Auto.NEARBY_SECONDS or InDungeonOrRaid() then
        joinedAt = nil
        return
    end
    if Cfg().autoOnJoin ~= true or not SomeoneClose() then return end
    TurnOn("you joined a group")
    if ns.BuffMode.IsOn() or pendingWhy then joinedAt = nil end
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
        pulled, joinedAt = false, nil
        if not InsideWithGroup() then
            joinedAt = GetTime()
            JoinedNearby()
        end
    elseif nowIn and joinedAt then
        JoinedNearby()
    elseif not nowIn then
        pulled, deathSeen, joinedAt = false, false, nil
    end
    inGroup = nowIn
end

-- PLAYER_ENTERING_WORLD. A login or reload: the group as it is now is where
-- we start, not a group joined (buff mode is off after one). Otherwise a
-- loading screen: into a dungeon or raid with your group turns it on (#256);
-- out of one, buff mode that waited for everyone gets the timeout from now.
function Auto.OnEnteringWorld(isLogin, isReload)
    if not (isLogin or isReload) then
        if InGroup() then
            if InsideWithGroup() then return end
        end
        if insideWait and not InDungeonOrRaid() then
            insideWait = false
            if ns.BuffMode.IsAuto() then StartTimeout() end
        end
        return
    end
    ready = true
    inGroup = InGroup()
    pulled, deathSeen, pendingWhy, pendingInside, insideWait, joinedAt = false, false, nil, nil, false, nil
    NoteWhoIsDead()
end

-- PLAYER_REGEN_DISABLED. The button empties itself for the fight in the
-- same event, so buff mode ends without refreshing it (EndForFight).
function Auto.OnCombatStart()
    fighting = true
    if inGroup then pulled = true end
    deathSeen, pendingWhy, pendingInside = false, nil, nil
    if Cfg().autoOffPull == true and ns.BuffMode.IsAuto() then
        ns.BuffMode.EndForFight("the fight started")
    end
    -- Waiting for everyone lasts up to the first pull (#256). Buff mode
    -- the pull didn't end ("at the first pull" unticked) follows the usual
    -- rules from here, timeout included.
    if insideWait then
        insideWait = false
        if ns.BuffMode.IsAuto() then StartTimeout() end
    end
end

local function OnDeath()
    if pulled and Cfg().autoOnDeath == true then TurnOn("someone in your group died") end
end

function Auto.OnCombatEnd()
    fighting = false
    local why, inside = pendingWhy, pendingInside
    pendingWhy, pendingInside = nil, nil
    if deathSeen then
        deathSeen = false
        OnDeath()
    end
    if why then TurnOn(why, inside) end
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

-- A battleground stopped being quiet (Battleground.Update): a trigger it
-- refused is answered now if that's because the preparation phase opened
-- (joining the battleground's group can come before its phase can be
-- read). Leaving or the end of a battleground forgets it.
function Auto.OnQuietEnded(preparation)
    local why = quietWhy
    quietWhy = nil
    if preparation and why then TurnOn(why) end
end

-- Someone outside your group buffed you (Offers.Owe).
function Auto.OnBuffed()
    if ns.Cities.ThanksQuiet() or ns.Cities.ButtonHidden() then return end
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
