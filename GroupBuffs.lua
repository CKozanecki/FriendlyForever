-- Buffing your group in buff mode: while buff mode is on, the buff-back
-- button also offers your buffs to group members who are missing them, one
-- per press. Favours owed to strangers come first. Nothing here casts.
--
-- The same safety rules as buff back: a member flagged for PvP is skipped
-- unless you're flagged too (read each time the button is armed, so at the
-- press), as are the dead, the offline, and anyone out of range or out of
-- sight as far as the game says. A member whose name, flag or buffs can't be
-- read is skipped too, and the button says why. Group buffs never say a line
-- and are never thanked.
local _, ns = ...
local Util = ns.Util
local Read = Util.ReadGameValues

local GroupBuffs = {}
ns.GroupBuffs = GroupBuffs

-- After your buff lands on them, how long they count as having it even if
-- their buffs don't show it yet (the game updates them a moment later).
GroupBuffs.JUST_GIVEN_SECONDS = 10
-- Right-click skips a member for this long.
GroupBuffs.SKIP_SECONDS = 300

local PARTY_UNITS, RAID_UNITS = {}, {}
for i = 1, 4 do PARTY_UNITS[i] = "party" .. i end
for i = 1, 40 do RAID_UNITS[i] = "raid" .. i end

local justGiven = {} -- [name .. "\1" .. buff key] = GetTime()
local skipped = {}   -- [name] = GetTime() you right-clicked them

-- The slots to look through: raid1..40 in a raid (one of them is you),
-- party1..4 in a party. Empty when you're in no group.
local function GroupUnits()
    if Read(IsInRaid) == true then return RAID_UNITS end
    if Read(IsInGroup) == true then return PARTY_UNITS end
    return {}
end

local function Recently(at, seconds)
    return at ~= nil and GetTime() - at < seconds
end

-- Whether the game says this member can't be buffed now, and why.
local function Unreachable(unit)
    if Read(UnitIsConnected, unit) == false then return "offline" end
    if Read(UnitIsDeadOrGhost, unit) == true then return "dead" end
    if Read(UnitIsVisible, unit) == false then return "out of sight" end
    local inRange, checked = Read(UnitInRange, unit)
    if checked == true and inRange == false then return "out of range" end
end

-- Why this member can't have a buff now, or nil if they may.
local function CantBuff(unit, iAmFlagged)
    local why = Unreachable(unit)
    if why then return why end
    if not iAmFlagged then
        local flagged = Read(UnitIsPVP, unit)
        if flagged == true then return "flagged for PvP and you aren't" end
        if flagged == nil then return "can't see whether they're flagged for PvP" end
    end
end

-- The members who may be buffed now, in group order: { unit, name, class },
-- and the first reason one was left out.
local function Candidates(units)
    local me = Util.UnitFullName("player")
    local iAmFlagged = Read(UnitIsPVP, "player") == true
    local out, seen, firstReason = {}, {}, nil
    for _, unit in ipairs(units) do
        local name = Util.UnitFullName(unit)
        local isMe = (name ~= nil and name == me) or Read(UnitIsUnit, unit, "player") == true
        if Read(UnitExists, unit) == true and not isMe then
            if not name then
                firstReason = firstReason or "a group member's name can't be read"
            elseif not seen[name] and not Recently(skipped[name], GroupBuffs.SKIP_SECONDS) then
                seen[name] = true
                local why = CantBuff(unit, iAmFlagged)
                if why then
                    firstReason = firstReason or (Util.DisplayName(name) .. ": " .. why)
                else
                    out[#out + 1] = { unit = unit, name = name, class = select(2, Read(UnitClass, unit)) }
                end
            end
        end
    end
    return out, firstReason
end

-- The next group member to buff: { name, buff, spell, group = true }, or
-- nil and why not. Your first buff goes to everyone missing it before your
-- second buff goes to anyone.
function GroupBuffs.Next()
    local units = GroupUnits()
    if #units == 0 then return nil, "you're not in a group" end
    local myBuffs = ns.BuffData.Offerable()
    if #myBuffs == 0 then return nil, "you have no buffs to offer" end
    local members, firstReason = Candidates(units)
    local unreadable = {}
    for _, buff in ipairs(myBuffs) do
        local spell = not buff.selfCast and ns.BuffData.SpellName(buff)
        for _, member in ipairs(spell and members or {}) do
            if not unreadable[member.name] and ns.BuffData.Useful(buff, member.class) then
                local wears = ns.Offers.Wears(member.unit, buff)
                local key = member.name .. "\1" .. buff.key
                if wears == nil then
                    unreadable[member.name] = true
                    firstReason = firstReason or (Util.DisplayName(member.name) .. ": can't see their buffs")
                elseif wears then
                    justGiven[key] = nil
                elseif not Recently(justGiven[key], GroupBuffs.JUST_GIVEN_SECONDS) then
                    return { name = member.name, buff = buff, spell = spell, group = true }
                end
            end
        end
    end
    return nil, firstReason or "everyone in your group has your buffs"
end

-- Your buff reached them (the game said so).
function GroupBuffs.NoteGiven(name, buff)
    justGiven[name .. "\1" .. buff.key] = GetTime()
end

-- Right-click: leave them out for a while.
function GroupBuffs.Skip(name)
    skipped[name] = GetTime()
end

-- Forget what's out of date, so the tables stay small in a long session.
function GroupBuffs.Prune()
    for key, at in pairs(justGiven) do
        if not Recently(at, GroupBuffs.JUST_GIVEN_SECONDS) then justGiven[key] = nil end
    end
    for name, at in pairs(skipped) do
        if not Recently(at, GroupBuffs.SKIP_SECONDS) then skipped[name] = nil end
    end
end
