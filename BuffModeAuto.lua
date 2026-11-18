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
--   city: there it would end quiet mode at the first stranger's buff (#34);
--   in any group, or solo for your own buffs (#426, below), out of combat,
--   a member missing a buff of yours (#272:
--   never cast, or fully faded; anyone's copy counts as theirs) or whose
--   buff of yours is running low (#397: as the button would top it up, so
--   a minute left for a buff of 10 minutes or less, the Top up time for a
--   longer one): as a fight ends with one, and whenever one goes missing or
--   runs low that wasn't before (looked for every WATCH_SECONDS, as the
--   game says nothing when a buff runs out). Running low and then fading is
--   one drop, not two. Only a member close by (the game's ~40-yard group
--   range), online and readable counts (GroupBuffs.Missing), and never in
--   an arena or battleground. Buff mode you turned off yourself stays off
--   until another buff, or another member, goes missing or runs low: the
--   pairs low or missing then are dismissed until they're seen recast,
--   even as a fight ends (#397, the owner), or the member leaves the group.
--   Solo (#426, the owner) it's you alone: your own copy of the buffs you
--   give while "Offer my own buffs when I'm not in a group" is on (#329),
--   and your self-buffs while "Offer my self-buffs" is on (#44), as the
--   button would offer them; a self-buff counts solo only (in a group a
--   missing self-buff alone never turns it on, #44 Q6). Leaving a group,
--   the first look only notes what you're missing;
--   a campfire aura added to you (#39, the owner): UNIT_AURA's list of
--   auras added to you holds one of CAMPFIRE_AURAS, a near-the-fire aura or
--   a camp benefit. Only that list is read, never your whole aura list, and
--   a full update (zoning, a login) adds nothing. For this trigger passers-by
--   count as something to do (PassersBy.lua, when that switch is on): a
--   passer-by waiting turns buff mode on only at the campfire. No other
--   trigger turns it on for a passer-by. A payload, list, aura or spell ID
--   that is a secret, or not what it should be, is passed over.
-- Passers-by count only out of resting areas (#484, the owner): where
-- IsResting() is true (a town with an inn, a capital), or won't say, they
-- never turn buff mode on or keep it on; the button still offers them
-- while it's on for something else. After you turn buff mode off yourself,
-- they don't turn it back on anywhere until you change zone (a new zone,
-- or a loading screen); out of resting areas they still keep on buff mode
-- something else turned on (#462).
-- Turns off (on by default), but only buff mode a trigger turned on, never
-- buff mode you turned on yourself:
--   the first pull (PLAYER_REGEN_DISABLED);
--   everyone being buffed (never assumed when someone's buffs can't be read;
--   solo, you having your own buffs, #329). With passers-by on, a passer-by
--   the button offers a buff counts as someone not yet buffed, whatever
--   turned buff mode on (#462, the owner): it stays on until they're buffed,
--   skipped or gone, or the pull or the timeout ends it. Not in a resting
--   area (#484, above);
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
local inGroup = false    -- in a group at the last roster update that could read IsInGroup()
                         -- (#373); nil after a login whose IsInGroup() couldn't be read,
                         -- until a roster update or a look reads it (#370)
local fighting = false   -- between PLAYER_REGEN_DISABLED and _ENABLED
local dead = {}          -- [name] = true for group members last seen dead
local pulled = false     -- this group has fought since you joined it
local deathSeen = false  -- a group member died during this fight
local pendingWhy         -- a trigger that fired in a fight, to act on after it
local pendingInside      -- and whether it was the dungeon-or-raid trigger
local insideWait = false -- buff mode that trigger turned on waits for everyone (#256)
local timeoutToken = 0   -- bumps each auto start, so an old timer does nothing
local quietWhy           -- a trigger refused while a battleground was quiet
local pvpOffWhy          -- the last trigger refused as every buff is off in PvP (#408), said once
local joinedAt           -- when you joined a group out in the world, while it waits for someone close by
local lastMissing = {}   -- [name .. "\1" .. buff key] = true: missing at the last look (#272),
                         -- or when the copy running low was put up (#397); nil after
                         -- a login: the first look only notes who is
local dismissed = {}     -- [name .. "\1" .. buff key] = as in lastMissing: low or missing
                         -- when you turned buff mode off yourself, until recast (#397)
local watching = false   -- the look for missing buffs is scheduled
local Watch, WatchWanted -- below: the looks, and whether they go on (#426)
local groupUnsure = false -- a roster update couldn't read IsInGroup() (#373): the
                          -- looks read it again until an answer decides
local pendingFire         -- the trigger that waits for a fight is the campfire's
local passersByOff = false -- you turned buff mode off yourself: passers-by don't turn it
                           -- back on until you change zone (#484)
-- The campfire auras you wear (#39), as the updates and reads saw them:
-- { [auraInstanceID] = spell ID }. unsure: an update couldn't be read (in a
-- fight they come restricted), so the next look reads your aura list once:
-- at once out of a fight, else as the fight ends. known: a read of your
-- aura list has worked since the login, so the remembered auras are all of
-- yours; until then, the first read only notes what's there.
local fireSeen = { auras = {}, unsure = true, known = false }
local Resync -- below: that one read of your aura list

-- Buff Back's settings, read only. A section lost mid-session reads as an
-- empty one: every trigger off, the timeout at its default (#387).
local LOST = setmetatable({}, { __newindex = function() error("Cfg() is read only") end })
local function Cfg()
    local cfg = ns.db.buffBack
    if type(cfg) == "table" then return cfg end
    return LOST
end

-- Out in the world, joining a group turns buff mode on only with someone
-- close by (#256): checked when you join, and on roster changes this long after.
Auto.NEARBY_SECONDS = 120
-- How often, in a group, members are looked at for a buff of yours gone
-- missing (#272).
Auto.WATCH_SECONDS = 5
-- The auras a campfire puts on you (#39), from Forever's spell data (build
-- 1.60.1.70685; docs/forever-facts.md). Near the fire: "Cozy Fire",
-- Forever's own (1232234) and Classic's two ranks (7353, 7358), "Campfire"
-- (1229736), "Welcoming Campfire" (1229739, 1289723), "Camp Tent"
-- (1229487) and "Campfire Nearby" (1283391), an aura on everyone within
-- about 100 yards of a fire, seen on you in game (the owner, 17 Nov: #451).
-- A camp's benefits, an hour each, added as you sit there (the
-- owner's correction): "Camp Benefits" (1229741) and the bonus of each camp
-- feature, Mana Well 1230587, Sharpening Wheel 1230172, Enchanted Lute
-- 1230653, First Aid Kit 1230124, Fish Bowl 1230098, Incense Candle
-- 1229513, Lodestone 1230164, Camp Chair 1229519 and Faction Banner
-- 1229718. Which of them the game puts on you is unconfirmed (#416); any
-- of them added means you're at a fire, and the trigger never casts.
Auto.CAMPFIRE_AURAS = {
    [1232234] = true, [7353] = true, [7358] = true, [1229736] = true, [1229739] = true, [1289723] = true,
    [1229487] = true, [1283391] = true, [1229741] = true, [1230587] = true, [1230172] = true, [1230653] = true,
    [1230124] = true, [1230098] = true, [1229513] = true, [1230164] = true, [1229519] = true, [1229718] = true,
}

local function InGroup()
    return ns.Util.ReadGameValues(IsInGroup) == true
end

-- Whether you're in a group: true or false, or nil when IsInGroup() can't
-- be read (#322).
local function GroupAnswer()
    local answer = ns.Util.ReadGameValues(IsInGroup)
    if answer == true or answer == false then return answer end
    return nil
end

-- In a dungeon or raid, and whether every other group member is in here
-- with you (#256): GroupBuffs.lua's, which its PvP rule shares (#306).
local InDungeonOrRaid = ns.GroupBuffs.InDungeonOrRaid
local EveryoneInside = ns.GroupBuffs.EveryoneInside

local function IsGroupUnit(unit)
    return type(unit) == "string" and (unit:find("^party%d") or unit:find("^raid%d")) ~= nil
end

-- Nothing left to do: no favours owed, and no group member missing your buffs
-- that you could see and reach (GroupBuffs never calls an unreadable member done).
-- inside: waiting for everyone in a dungeon or raid, so also everyone in
-- there with you (#256). withSelf: your self-buffs too (#44): "everyone has
-- your buffs" waits for them, but a missing self-buff alone never turns buff
-- mode on (the owner, #44 Q6). Also why, for the message.
-- withPassersBy: a passer-by waiting for a buff counts too: for turning on,
-- only the campfire's (#39), and not after you turned buff mode off
-- yourself until you change zone (TurnOn, #484); for turning off, every
-- trigger's (#462). Never in a resting area, or where the game won't say
-- you aren't in one (#484, the owner).
local function Settled(inside, withSelf, withPassersBy)
    if ns.Offers.Count() > 0 then return false end
    if withPassersBy and ns.Util.ReadGameValues(IsResting) == false and ns.PassersBy.Waiting() then
        return false
    end
    local offer, groupWhy, settled, held = ns.GroupBuffs.Next()
    if offer ~= nil or settled ~= true then return false end
    if withSelf then
        local mine, _, mineSettled = ns.SelfBuffs.Next()
        if mine ~= nil or mineSettled ~= true then return false end
        -- Your weapon buffs (#45) too, the same way: never a trigger.
        local weapon, _, weaponSettled = ns.WeaponBuffs.Next()
        if weapon ~= nil or weaponSettled ~= true then return false end
    end
    if inside and not EveryoneInside() then return false end
    -- Your water buff waits for water (Water.lua): nobody has it, so say so.
    if held then return true, ns.Water.HeldReason(held) end
    if inside then return true, "everyone is here and has your buffs" end
    -- Solo (#329): only you were looked at, so say so.
    if groupWhy == ns.GroupBuffs.SOLO_DONE then return true, groupWhy end
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
    -- The missing-buff trigger switched on solo (#426): the looks start again.
    if ns.db and ready and not watching and WatchWanted() then Watch() end
    if not ns.db or not ns.BuffMode.IsAuto() then return end
    local cfg = Cfg()
    if timedOutAfter then
        ns.BuffMode.Set(false, { why = timedOutAfter .. " minutes passed" })
        if not ns.BuffMode.IsAuto() then
            ns.Diag.Log("buffMode", "auto turned off: %s minutes passed", timedOutAfter)
        end
        return
    end
    if InCombatLockdown() then return end
    if cfg.autoOffDone ~= true then return end
    -- A passer-by the button offers is work left for any trigger's buff
    -- mode (#462); PassersBy.Waiting says no while that switch is off.
    local done, why = Settled(insideWait, true, true)
    if done then
        ns.BuffMode.Set(false, { why = why })
        if not ns.BuffMode.IsAuto() then ns.Diag.Log("buffMode", "auto turned off: %s", why) end
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

-- Waiting for everyone in a dungeon or raid: no timeout (#256).
local function WaitInside()
    insideWait = true
    timeoutToken = timeoutToken + 1
end

-- inside: the dungeon-or-raid trigger, so buff mode waits for everyone.
-- fire: the campfire's (#39), so passers-by count. withSelf: your
-- self-buffs count as something to do (solo, #426).
local function TurnOn(why, inside, fire, withSelf)
    -- A battle under way: nothing turns on, and nobody's buffs are read. The
    -- trigger is kept in case it was only the phase not being read yet.
    if ns.Battleground.Quiet() then
        quietWhy = quietWhy or why
        return
    end
    if fighting or InCombatLockdown() then
        -- The first trigger waits, but the dungeon-or-raid one outranks
        -- the others: after the fight it waits for everyone.
        if not pendingWhy or (inside and not pendingInside) then
            pendingWhy, pendingInside = why, inside
        end
        -- The campfire counts passers-by (#39) whichever trigger came first.
        pendingFire = pendingFire or fire
        return
    end
    if ns.BuffMode.IsOn() then
        -- A trigger's buff mode, met by the dungeon or raid: it waits for
        -- everyone now. Yours is yours: no trigger turns it off.
        if inside and ns.BuffMode.IsAuto() then WaitInside() end
        return
    end
    -- In a battleground or arena whose rules give nobody any buff (#408:
    -- every buff Off there by default), there's nothing to turn on for.
    local places = ns.BuffRules.Place()
    if #places == 1 and places[1] == "pvp" and not ns.BuffRules.GivesAnyone("pvp") then
        if pvpOffWhy ~= why then ns.Diag.Log("buffMode", "not turning on (%s): every buff is off in PvP", why) end
        pvpOffWhy = why
        return
    end
    pvpOffWhy = nil
    -- Nothing to do: don't lend a key just to hand it back. Passers-by don't
    -- turn back on buff mode you turned off, until you change zone (#484).
    if Settled(inside, withSelf, fire and not passersByOff) then return end
    -- Set first: turning on refreshes the button, which checks it at once.
    if inside then WaitInside() else insideWait = false end
    ns.BuffMode.Set(true, { auto = true, why = why })
    if ns.BuffMode.IsAuto() then ns.Diag.Log("buffMode", "auto turned on: %s", why) end
    if ns.BuffMode.IsAuto() and not inside then StartTimeout() end
end

-- In an arena or a battleground, or where the game won't say: no missing
-- buff turns buff mode on there (#272).
local function InPvP()
    local _, kind = ns.Util.ReadGameValues(IsInInstance)
    return kind ~= "none" and kind ~= "party" and kind ~= "raid"
end

-- The group's slots: "raid", 40 in a raid, "party", 4 otherwise; nil when
-- the game won't say whether you're in a raid, or its answer and the slots
-- disagree (#359: GroupBuffs.RaidAnswer, as buff mode's group look reads
-- it, #346). A raid taken for a party would have only your own subgroup.
local function GroupSlots()
    local inRaid = ns.GroupBuffs.RaidAnswer()
    if inRaid == nil then return nil end
    if inRaid then return "raid", 40 end
    return "party", 4
end

-- Every member of the group by name, you included; nil when a member's
-- name can't be read (yours too: solo, you're the only member, #417's
-- testing review), or the group's slots can't be told (GroupSlots): then
-- nobody is taken to have left.
local function RosterNames()
    local prefix, count = GroupSlots()
    if not prefix then return nil end
    local names = {}
    local me = ns.Util.UnitFullName("player")
    if not me then return nil end
    names[me] = true
    for i = 1, count do
        local unit = prefix .. i
        if ns.Util.ReadGameValues(UnitExists, unit) ~= false then
            local name = ns.Util.UnitFullName(unit)
            if not name then return nil end
            names[name] = true
        end
    end
    return names
end

-- A member missing a buff of yours outright (#272), if that trigger is on:
-- any one as a fight ends, otherwise one who wasn't missing it before.
-- Who was is remembered until they're seen wearing it or leave the group:
-- a member out of this look (out of range, skipped, unreadable) keeps
-- what they had, so coming back close isn't a new fade, and buff mode you
-- turned off stays off until someone else goes missing. After a login the
-- first look only notes who is (buff mode is off after one), unless a
-- fight has ended; while the group can't be told, it notes nothing.
-- The key a missing buff is remembered by: the member's name, and the
-- buff's key (or, for a self-buff, its slot: its family or key, #426).
local function KeyOf(offer)
    return offer.name .. "\1" .. (offer.slot or offer.buff.key)
end

-- GroupBuffs.Missing's answer and, solo (#426), your missing self-buffs
-- merged into it, in its shape: list, worn, whether the group was known,
-- and the pairs only running low; fifth, whether this look saw you solo.
-- inGroup is only the last answer read (#373): a group joined in a fight,
-- or a game that won't say now, isn't solo. Self-buffs count only when the
-- game says so at this look too, and the last answer agrees: a leave not
-- yet read hasn't started the solo looks (GroupChanged), whose first only
-- notes what you're missing.
local function MissingNow()
    local list, worn, groupKnown, low = ns.GroupBuffs.Missing()
    local solo = inGroup == false and GroupAnswer() == false
    if solo then
        local mine, mineWorn, mineLow = ns.SelfBuffs.Missing()
        if mine then
            for _, offer in ipairs(mine) do list[#list + 1] = offer end
            for key, at in pairs(mineWorn) do worn[key] = at end
            for key, at in pairs(mineLow) do low[key] = at end
        end
    end
    return list, worn, groupKnown, low, solo
end

local function CheckMissing(fightEnded)
    -- In a group, or solo (#426); not while the game won't say which.
    if not ready or inGroup == nil or fighting or InCombatLockdown() then return end
    if Cfg().autoOnMissing ~= true or InPvP() or ns.Battleground.Quiet() then
        lastMissing = {}
        return
    end
    local list, worn, groupKnown, low, solo = MissingNow()
    -- A pair dismissed is forgotten once it's recast (#397): any copy, if
    -- it was missing; one put up after the low one, if it was low. Not a
    -- copy whose times can't be read, nor one that only stopped counting as
    -- low (a Top up changed): that isn't a fresh copy.
    for key, was in pairs(dismissed) do
        local at = worn[key] or low[key]
        if at and (was == true or (type(at) == "number" and at > was + 1)) then dismissed[key] = nil end
    end
    local now, first = {}, nil
    for _, offer in ipairs(list) do
        local key = KeyOf(offer)
        now[key] = low[key] or true
        if not first and not dismissed[key] and (fightEnded or (lastMissing and not lastMissing[key])) then
            first = offer
        end
    end
    -- Carried over: missing before, not seen this time, still in the group.
    local roster = RosterNames()
    for key in pairs(lastMissing or {}) do
        local name = key:match("^(.-)\1")
        if not worn[key] and (roster == nil or roster[name]) then now[key] = now[key] or lastMissing[key] end
    end
    -- A member who left the group is forgotten, dismissed or not: back in
    -- it, they're new (#272).
    for key in pairs(roster and dismissed or {}) do
        if not roster[key:match("^(.-)\1")] then dismissed[key] = nil end
    end
    -- The first look after a login only notes who is missing; while the
    -- group can't be told it notes nothing, and the next look notes instead:
    -- a raid taken for a party would note only your subgroup (#359), and a
    -- group whose slots weren't known (IsInGroup() unreadable, #370) would
    -- note nobody, so a buff missing all along would count as new.
    if lastMissing ~= nil or (roster ~= nil and groupKnown) then lastMissing = now end
    if not first then return end
    local spell = ns.BuffData.SpellName(first.buff) or "buff"
    local why
    if low[KeyOf(first)] then
        why = (first.self and "your" or (ns.Util.DisplayName(first.name) .. "'s")) .. " " .. spell
            .. " is running low"
    else
        why = (first.self and "you're" or (ns.Util.DisplayName(first.name) .. " is")) .. " missing your " .. spell
    end
    -- Solo at this look, your self-buffs are something to do too (#426).
    TurnOn(fightEnded and ("the fight ended and " .. why) or why, nil, nil, solo)
end

-- You turned buff mode off yourself (BuffMode.Set): the members low on or
-- missing a buff of yours now don't turn it back on until they're seen with
-- a fresh copy (#397), not even as a fight ends. Now means a look taken at
-- once, in a fight too (the last one may be as old as the pull), as well as
-- the last look's (a member out of this one's reach keeps what they had).
-- The look only reads (out of a group it lists nobody); one that fails
-- dismisses no more than the last did.
local function DismissNow()
    local list, _, _, low = MissingNow()
    for _, offer in ipairs(list) do
        local key = KeyOf(offer)
        dismissed[key] = low[key] or true
    end
end

function Auto.OnTurnedOffByYou()
    -- Passers-by don't turn it back on until you change zone (#484).
    passersByOff = true
    for key, was in pairs(lastMissing or {}) do dismissed[key] = was end
    ns.Diag.Call(DismissNow)
end

local GroupChanged -- below: a join or a leave, as a roster update read it

-- Whether the looks go on: in a group, while it isn't known whether you're
-- in one (#370, #373), and solo only while the missing-buff trigger is on
-- (#426). Solo with it off, nothing ticks; turning it on starts them again
-- (Auto.Check, at the next button refresh).
function WatchWanted()
    return inGroup ~= false or groupUnsure or Cfg().autoOnMissing == true
end

-- Look again every WATCH_SECONDS while in a group, while it isn't yet known
-- after a login (#370), or while a roster update couldn't read it (#373).
-- The next look is scheduled first, so one that fails doesn't end them.
function Watch()
    if watching then return end
    watching = true
    C_Timer.After(Auto.WATCH_SECONDS, ns.Diag.Wrap(function()
        watching = false
        -- Read IsInGroup() again, so the triggers don't wait for a roster
        -- update the game may not send (#373): a group that doesn't change
        -- sends none, and neither does being alone after leaving one. Not yet
        -- known after a login (#370): the first answer is where we start, as
        -- at the login, not a group joined. After a roster update that
        -- couldn't read it: the first answer decides, as that update would
        -- have (a leave or a join). Still unreadable: try again.
        if inGroup == nil or groupUnsure then
            local answer = GroupAnswer()
            if answer == nil then
                Watch()
            elseif inGroup == nil then
                inGroup = answer
            else
                groupUnsure = false
                GroupChanged(answer)
            end
        end
        -- In a group, or solo (#426) while the trigger is on: the look goes
        -- on. (While the game won't say which, CheckMissing looks at nothing.)
        if not WatchWanted() then return end
        Watch()
        CheckMissing(false)
    end))
end

-- Being in a dungeon or raid with your group (#256), if that trigger is on.
-- Entering also starts the round (GroupBuffs.StartRound: a buff, yours or
-- another member's, put up over 5 minutes before you entered is offered
-- once more), whatever the switch says: it changes what buff mode offers,
-- not when it turns on.
local function InsideWithGroup()
    local inside, kind = InDungeonOrRaid()
    if inside then ns.GroupBuffs.StartRound() end
    if inside and Cfg().autoOnJoin == true then
        TurnOn("you're in a " .. kind .. " with your group", true)
    end
    -- The round changes what the button offers: show it now (its "Already
    -- done by" note too), not at the next recheck.
    if inside then ns.BuffButton.Refresh() end
    return inside
end

-- The other members in the slots prefix1..count by name: { [name] = unit }.
local function NamesIn(prefix, count)
    local out = {}
    for i = 1, count do
        local unit = prefix .. i
        local name = ns.Util.UnitFullName(unit)
        if name then out[name] = unit end
    end
    return out
end

-- The other members by name: { [name] = unit }; nil when the group's slots
-- can't be told (GroupSlots).
local function GroupUnitNames()
    local prefix, count = GroupSlots()
    if not prefix then return nil end
    return NamesIn(prefix, count)
end

-- Who in the group is dead now, so only a death from here on counts (a
-- member who joins dead, or releases as a ghost, isn't a new death). When
-- the group's slots can't be told (#359), anyone either set of slots shows
-- dead is added and nobody is forgotten: a raid taken for a party would
-- forget the other subgroups' dead.
local function NoteWhoIsDead()
    local units = GroupUnitNames()
    if not units then
        for _, slots in ipairs({ NamesIn("party", 4), NamesIn("raid", 40) }) do
            for name, unit in pairs(slots) do
                if ns.Util.ReadGameValues(UnitIsDeadOrGhost, unit) == true then dead[name] = true end
            end
        end
        return
    end
    local now = {}
    for name, unit in pairs(units) do
        if ns.Util.ReadGameValues(UnitIsDeadOrGhost, unit) == true then now[name] = true end
    end
    dead = now
end

-- Whether another member is within the game's group range check (UnitInRange,
-- about 40 yards). A range the game won't check or give isn't close, and
-- nobody is while the group's slots can't be told (#359): the next roster
-- change looks again.
local function SomeoneClose()
    for _, unit in pairs(GroupUnitNames() or {}) do
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
    NoteWhoIsDead()
    -- Before the login finishes the roster isn't loaded: being in a group
    -- then isn't joining one (buff mode is off after a login).
    if not ready then
        inGroup = InGroup()
        return
    end
    -- A login or reload that couldn't read IsInGroup() (#370): the first
    -- update that can is where we start, as at the login, not a group joined
    -- (a buff missing all along would count as new). The looks already try
    -- again meanwhile (Watch).
    if inGroup == nil then
        inGroup = GroupAnswer()
        if inGroup then Watch() end
        return
    end
    -- An update that can't read IsInGroup() changes nothing (#373): no join,
    -- no leave. Taken as leaving, it forgot who was missing your buffs, so a
    -- buff missing all along counted as new once it could be read again. The
    -- next answer decides: the next update that can read it, or the next
    -- look (Watch), since a leave or a join may send no other update.
    local nowIn = GroupAnswer()
    if nowIn == nil then
        groupUnsure = true
        Watch()
        return
    end
    groupUnsure = false
    GroupChanged(nowIn)
end

-- A roster update's answer, or a look's after one that couldn't read it
-- (#373): joining, leaving, or the same group.
function GroupChanged(nowIn)
    if nowIn and not inGroup then
        pulled, joinedAt = false, nil
        -- A group joined: everyone missing a buff is new (#272), and nothing
        -- is dismissed (#397; a login or reload starts with nothing either).
        lastMissing, dismissed = {}, {}
        if not InsideWithGroup() then
            joinedAt = GetTime()
            JoinedNearby()
        end
    elseif nowIn and joinedAt then
        JoinedNearby()
    elseif not nowIn then
        pulled, deathSeen, joinedAt = false, false, nil
        -- Solo now (#426): the first look only notes what you're missing.
        lastMissing = nil
        ns.GroupBuffs.EndRound()
    end
    inGroup = nowIn
    if WatchWanted() then Watch() end
end

-- PLAYER_ENTERING_WORLD. A login or reload: the group as it is now is where
-- we start, not a group joined (buff mode is off after one). Otherwise a
-- loading screen: into a dungeon or raid with your group turns it on (#256);
-- out of one, buff mode that waited for everyone gets the timeout from now.
-- A loading screen that can't read IsInGroup() goes by the group as last
-- read (#377).
function Auto.OnEnteringWorld(isLogin, isReload)
    -- A loading screen is a change of zone (#484); a login starts afresh.
    passersByOff = false
    if not (isLogin or isReload) then
        -- IsInGroup() can't be read (#377): the group as last read (#373).
        -- Not known either (a login that couldn't read it, #370): nothing
        -- for the group, no round started or ended.
        local withGroup = GroupAnswer()
        if withGroup == nil then withGroup = inGroup end
        if withGroup == nil then return end
        if withGroup and InsideWithGroup() then return end
        ns.GroupBuffs.EndRound()
        if insideWait and not InDungeonOrRaid() then
            insideWait = false
            if ns.BuffMode.IsAuto() then StartTimeout() end
        end
        return
    end
    ready = true
    inGroup = GroupAnswer()
    pulled, deathSeen, pendingWhy, pendingInside, insideWait, joinedAt = false, false, nil, nil, false, nil
    lastMissing, groupUnsure, pendingFire = nil, false, nil
    -- What you wear at a login was there already: noted, not added.
    fireSeen.auras, fireSeen.unsure, fireSeen.known = {}, true, false
    Resync(false)
    ns.GroupBuffs.EndRound()
    NoteWhoIsDead()
    -- The looks go on solo too while the trigger is on (#426), and read the
    -- group again while it isn't known (#370, #373).
    if WatchWanted() then Watch() end
end

-- ZONE_CHANGED_NEW_AREA: a new zone. Passers-by count again after you
-- turned buff mode off yourself (#484).
function Auto.OnZoneChanged()
    passersByOff = false
end

-- PLAYER_REGEN_DISABLED. The button empties itself for the fight in the
-- same event, so buff mode ends without refreshing it (EndForFight).
function Auto.OnCombatStart()
    fighting = true
    ns.GroupBuffs.EndRound() -- the round lasts up to the first pull (#256)
    if inGroup then pulled = true end
    deathSeen, pendingWhy, pendingInside, pendingFire = false, nil, nil, nil
    if Cfg().autoOffPull == true and ns.BuffMode.IsAuto() then
        ns.BuffMode.EndForFight("the fight started")
        ns.Diag.Log("buffMode", "auto turned off: the fight started")
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
    local why, inside, fire = pendingWhy, pendingInside, pendingFire
    pendingWhy, pendingInside, pendingFire = nil, nil, nil
    if deathSeen then
        deathSeen = false
        OnDeath()
    end
    if why then TurnOn(why, inside, fire) end
    -- A campfire aura added in the fight came restricted (#39): look once.
    if fireSeen.unsure then Resync(true) end
    CheckMissing(true)
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

-- The spell IDs in a { [instance] = spell ID } table, as a set.
local function SpellsOf(auras)
    local out = {}
    for _, id in pairs(auras) do out[id] = true end
    return out
end

-- A value that is plain data: not a secret, and of the type wanted.
local function Plain(value, kind)
    if ns.Util.IsSecret(value) or type(value) ~= kind then return nil end
    return value
end

-- Your campfire auras, read from your aura list: { [instance] = spell ID },
-- or nil when the list (or one of its auras, or their IDs) can't be read.
-- Only for a look the updates couldn't give (above): never on every update.
local function ReadFireAuras()
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if type(api) ~= "function" then return nil end
    local out = {}
    for i = 1, ns.Offers.MAX_AURAS do
        local ok, aura = pcall(api, "player", i, "HELPFUL")
        if not ok or ns.Util.IsSecret(aura) then return nil end
        if aura == nil then return out end
        if type(aura) ~= "table" then return nil end
        local id, instance = aura.spellId, aura.auraInstanceID
        if ns.Util.IsSecret(id) or ns.Util.IsSecret(instance) then return nil end
        if Auto.CAMPFIRE_AURAS[id] then
            out[(Plain(instance, "number") and instance == instance) and instance or -i] = id
        end
    end
    return out
end

-- Whether a campfire aura has been added: one whose spell you weren't
-- wearing just before. A refresh (the same spell put up again) isn't, nor
-- is anything seen first at a login or a full update (zoning).
local function Announce(added)
    if not added then return end
    -- Never before the login has finished: what loads then was there already.
    if not ready or Cfg().autoOnCampfire ~= true then return end
    -- Not where quiet mode holds in a capital city: there it would end
    -- quiet mode at the first fire you pass (as for a stranger's buff, #34).
    if ns.Cities.ThanksQuiet() or ns.Cities.ButtonHidden() then return end
    TurnOn("you're by a campfire", nil, true)
end

-- Read your aura list once, after updates that couldn't be read: a campfire
-- spell there that wasn't before was added meanwhile (announce). A list
-- that can't be read leaves it for the next look.
function Resync(announce)
    local now = ReadFireAuras()
    if not now then return end
    local before = SpellsOf(fireSeen.auras)
    -- A login whose read failed (a /reload in a fight): what the first read
    -- that works finds may have been there all along.
    if not fireSeen.known then announce = false end
    fireSeen.auras, fireSeen.unsure, fireSeen.known = now, false, true
    local added = false
    for _, id in pairs(now) do
        if not before[id] then added = true end
    end
    if announce then Announce(added) end
end

-- What one UNIT_AURA payload for you says (#39): its removed instances
-- forgotten, its added campfire auras noted, and true when one is a spell
-- you weren't wearing before it (a refresh, removed and added together, is
-- not). Anything in it that can't be read makes the next look read the
-- list; a full update gives no list of what's new, so it is read too, but
-- adds nothing.
function Auto.TakeAuraUpdate(updateInfo)
    if Plain(updateInfo, "table") == nil then
        fireSeen.unsure = true
        return false
    end
    local full = updateInfo.isFullUpdate
    if ns.Util.IsSecret(full) then
        fireSeen.unsure = true
        return false
    end
    if full == true then
        fireSeen.unsure = true
        return nil, true
    end
    local before = SpellsOf(fireSeen.auras)
    local removed, added = updateInfo.removedAuraInstanceIDs, updateInfo.addedAuras
    if removed ~= nil then
        if Plain(removed, "table") == nil then
            fireSeen.unsure = true
        else
            for i = 1, ns.Offers.MAX_AURAS do
                local instance = removed[i]
                if instance == nil then break end
                -- Only a plain number is a key (NaN, a secret, anything else isn't).
                if Plain(instance, "number") and instance == instance then
                    fireSeen.auras[instance] = nil
                else
                    fireSeen.unsure = true
                end
            end
        end
    end
    local new = false
    if added ~= nil then
        if Plain(added, "table") == nil then
            fireSeen.unsure = true
            return false
        end
        for i = 1, ns.Offers.MAX_AURAS do
            local aura = added[i]
            if aura == nil then break end
            local id = Plain(aura, "table") and aura.spellId
            if not Plain(aura, "table") or ns.Util.IsSecret(id) then
                fireSeen.unsure = true
            elseif Auto.CAMPFIRE_AURAS[id] then
                local instance = aura.auraInstanceID
                if not (Plain(instance, "number") and instance == instance) then instance = -1000 - i end
                fireSeen.auras[instance] = id
                if not before[id] then new = true end
            end
        end
    end
    -- Before any read has worked since the login, what you wear isn't
    -- known, so nothing counts as added: the first read notes it (Resync).
    return new and fireSeen.known
end

-- UNIT_AURA for you: a campfire aura added turns buff mode on (#39), if
-- that trigger is on. An update that couldn't be read is made up by one
-- read of your aura list, at once out of a fight, else when it ends.
function Auto.OnPlayerAura(unit, updateInfo)
    if unit ~= "player" then return end
    local new, full = Auto.TakeAuraUpdate(updateInfo)
    if full then
        if not InCombatLockdown() then Resync(false) end
        return
    end
    -- What this update added counts, and the read makes up what it hid.
    if fireSeen.unsure and not InCombatLockdown() then Resync(true) end
    Announce(new)
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
        ZONE_CHANGED_NEW_AREA = Auto.OnZoneChanged,
    }
    for event in pairs(handlers) do frame:RegisterEvent(event) end
    -- Your own auras only (#39): every unit's would be far more often.
    handlers.UNIT_AURA = Auto.OnPlayerAura
    frame:RegisterUnitEvent("UNIT_AURA", "player")
    frame:SetScript("OnEvent", function(_, event, ...) ns.Diag.Call(handlers[event], ...) end)
    ns.Offers.OnOwe(Auto.OnBuffed)
end
