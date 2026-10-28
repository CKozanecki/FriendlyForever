-- Buffing your group in buff mode: while buff mode is on, the buff-back
-- button also offers your buffs to group members who are missing them, one
-- per press. Favours owed to strangers come first. Nothing here casts.
--
-- The same safety rules as buff back: a member flagged for PvP is skipped
-- unless you're flagged too (read each time the button is armed, so at the
-- press), as are the dead, the offline, and anyone out of range (of the
-- spell, when the game says) or too far for the game to show. The game can't
-- say whether they're in line of sight: a cast it refuses holds that member
-- back for a moment, so the next press goes to the next member.
--
-- A paladin keeps one Blessing on each player: a member wearing one of yours
-- has theirs, and isn't offered another (it would replace it). A member whose name, flag or buffs can't be
-- read is skipped too, and the button says why. Your rules for who gets
-- each buff (tanks only, chosen classes, named players: BuffRules.lua) apply
-- here, and only here. Group buffs never say a line and are never thanked.
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
-- A member whose cast the game refused (out of range or sight) waits this long.
GroupBuffs.HELD_BACK_SECONDS = 15

local PARTY_UNITS, RAID_UNITS = {}, {}
for i = 1, 4 do PARTY_UNITS[i] = "party" .. i end
for i = 1, 40 do RAID_UNITS[i] = "raid" .. i end

local justGiven = {} -- [name .. "\1" .. buff key] = GetTime()
local justRevoked = {} -- [name] = GetTime() your Revoke reached them
local skipped = {}   -- [name] = GetTime() you right-clicked them
local heldBack = {}  -- [name] = GetTime() the game refused a cast to them

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

-- false when the game says the spell can't reach them; nil when it won't say.
local function InSpellRange(spell, unit)
    local inRange = Read(C_Spell and C_Spell.IsSpellInRange, spell, unit)
    if inRange == nil then inRange = Read(IsSpellInRange, spell, unit) end
    if inRange == false or inRange == 0 then return false end
    if inRange == true or inRange == 1 then return true end
end

-- Whether they wear a buff of this family that you cast: true, false, or nil
-- when the game won't say (their buffs, or who cast one, can't be read).
local function WearsMyFamily(unit, family)
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not api then return nil end
    for i = 1, ns.Offers.MAX_AURAS do
        local ok, aura = pcall(api, unit, i, "HELPFUL")
        if not ok or Util.IsSecret(aura) then return nil end
        if aura == nil then return false end
        local id = aura.spellId
        if Util.IsSecret(id) then return nil end
        local buff = ns.BuffData.ForAura(id)
        if buff and buff.family == family then
            local source = aura.sourceUnit
            if source == nil or Util.IsSecret(source) then return nil end
            local mine = Read(UnitIsUnit, source, "player")
            if mine == nil then return nil end
            if mine then return true end
        end
    end
    return false
end

-- Whether they wear Salvation (a rank, or Mass Salvation): true, false, or nil
-- when their buffs can't be read; and when they do, whether it's yours
-- (nil when who cast it can't be read).
local function WearsSalvation(unit)
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not api then return nil end
    for i = 1, ns.Offers.MAX_AURAS do
        local ok, aura = pcall(api, unit, i, "HELPFUL")
        if not ok or Util.IsSecret(aura) then return nil end
        if aura == nil then return false end
        local id = aura.spellId
        if Util.IsSecret(id) then return nil end
        local buff = ns.BuffData.ForAura(id)
        if buff and buff.key == ns.BuffData.REVOKE.removes then
            local source = aura.sourceUnit
            if source == nil or Util.IsSecret(source) then return true, nil end
            return true, Read(UnitIsUnit, source, "player")
        end
    end
    return false
end

-- Reasons a member is left out that still leave a buff of yours to give
-- once they can have it (they're dead, out of reach for now, or can't be
-- read). Offline, out of sight, flagged when you aren't, or skipped by you
-- leave nothing to do now: "everyone has your buffs" can still be true.
local OPEN_REASONS = {
    ["dead"] = true, ["out of range"] = true,
    ["can't see whether they're flagged for PvP"] = true,
    ["the game refused your last cast to them"] = true,
}

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
-- the first reason one was left out, and whether one left out may still
-- need a buff (OPEN_REASONS, or a name that can't be read).
local function Candidates(units)
    local me = Util.UnitFullName("player")
    local iAmFlagged = Read(UnitIsPVP, "player") == true
    local out, seen, firstReason, open = {}, {}, nil, false
    for _, unit in ipairs(units) do
        local name = Util.UnitFullName(unit)
        local isMe = (name ~= nil and name == me) or Read(UnitIsUnit, unit, "player") == true
        if Read(UnitExists, unit) == true and not isMe then
            if not name then
                firstReason = firstReason or "a group member's name can't be read"
                open = true
            elseif not seen[name] then
                seen[name] = true
                local why = CantBuff(unit, iAmFlagged)
                if Recently(skipped[name], GroupBuffs.SKIP_SECONDS) then
                    why = "skipped for now (you right-clicked them)"
                elseif Recently(heldBack[name], GroupBuffs.HELD_BACK_SECONDS) then
                    why = why or "the game refused your last cast to them"
                end
                if why then
                    firstReason = firstReason or (Util.DisplayName(name) .. ": " .. why)
                    open = open or OPEN_REASONS[why] == true
                else
                    out[#out + 1] = { unit = unit, name = name, class = select(2, Read(UnitClass, unit)) }
                end
            end
        end
    end
    return out, firstReason, open
end

-- The next group member to buff: { name, buff, spell, group = true }, or
-- (a paladin) Salvation to take off: { ..., revoke = true, why }; or
-- nil, why not, and whether that's settled: nothing left that a buff of
-- yours could fix now or soon (not in a group, or everyone you could buff
-- has them; nobody dead, out of reach or unreadable). Your first buff
-- goes to everyone missing it before your second buff goes to anyone.
function GroupBuffs.Next()
    local units = GroupUnits()
    if #units == 0 then return nil, "you're not in a group", true end
    local myBuffs = ns.BuffData.Offerable()
    if #myBuffs == 0 then return nil, "you have no buffs to offer", true end
    local members, firstReason, open = Candidates(units)
    local unreadable, outOfRange = {}, {}
    local family = {} -- [name .. family] = whether they wear one of yours (read once)
    -- Every reason a member is passed over here leaves a buff to give.
    local function Why(member, why)
        firstReason = firstReason or (Util.DisplayName(member.name) .. ": " .. why)
        open = true
    end
    -- A paladin's Revoke comes before new buffs: Salvation on someone who
    -- shouldn't have it (a tank, say) costs threat now.
    if ns.BuffData.RevokeKnown() then
        local revoke = ns.BuffData.REVOKE
        for _, member in ipairs(members) do
            local wears, mine = false, nil
            if not Recently(justRevoked[member.name], GroupBuffs.JUST_GIVEN_SECONDS) then
                wears, mine = WearsSalvation(member.unit)
            end
            -- Unreadable buffs are said by the buff pass below.
            if wears then
                local covered, label = ns.BuffRules.RevokeCovers(member)
                if covered == nil then
                    Why(member, label)
                elseif covered and ns.BuffRules.RevokeMode() == "mine" and mine ~= true then
                    if mine == nil then Why(member, "can't tell whose Salvation they have") end
                elseif covered then
                    if InSpellRange(revoke.name, member.unit) == false then
                        Why(member, "out of range to revoke their Salvation")
                    else
                        return { name = member.name, buff = revoke, spell = revoke.name, group = true,
                            revoke = true, why = label }
                    end
                end
            end
        end
    end
    for _, buff in ipairs(myBuffs) do
        local spell = not buff.selfCast and ns.BuffData.SpellName(buff)
        for _, member in ipairs(spell and members or {}) do
            -- Your rules for who gets the buff (BuffRules.lua). A member they
            -- leave out is passed over quietly: nothing is owed them.
            local allowed, ruleWhy = false, nil
            if not unreadable[member.name] and ns.BuffData.Useful(buff, member.class) then
                allowed, ruleWhy = ns.BuffRules.Allows(buff, member)
            end
            if allowed ~= false then
                local wears = ns.Offers.Wears(member.unit, buff)
                local key = member.name .. "\1" .. buff.key
                if wears == nil then
                    unreadable[member.name] = true
                    Why(member, "can't see their buffs")
                elseif wears then
                    justGiven[key] = nil
                elseif allowed == nil then
                    -- The rules can't tell (an unreadable role or class):
                    -- said, and not settled, only for a member missing it.
                    Why(member, ruleWhy)
                elseif not Recently(justGiven[key], GroupBuffs.JUST_GIVEN_SECONDS) then
                    local covered = false
                    if buff.family then
                        local fkey = member.name .. "\1" .. buff.family
                        if family[fkey] == nil then
                            local mine = WearsMyFamily(member.unit, buff.family)
                            if mine == nil then Why(member, "can't tell whose Blessing they have") end
                            family[fkey] = mine ~= false
                        end
                        covered = family[fkey]
                    end
                    if not covered then
                        if InSpellRange(spell, member.unit) == false then
                            if not outOfRange[member.name] then Why(member, "out of range") end
                            outOfRange[member.name] = true
                        else
                            return { name = member.name, buff = buff, spell = spell, group = true }
                        end
                    end
                end
            end
        end
    end
    return nil, firstReason or "everyone in your group has your buffs", not open
end

-- Your Revoke reached them: don't offer it again while their Salvation
-- still shows.
function GroupBuffs.NoteRevoked(name)
    justRevoked[name] = GetTime()
end

-- Your buff reached them (the game said so).
function GroupBuffs.NoteGiven(name, buff)
    justGiven[name .. "\1" .. buff.key] = GetTime()
end

-- The game refused a cast to them (out of range or sight): try the others
-- first for a moment.
function GroupBuffs.NoteRefused(name)
    heldBack[name] = GetTime()
end

-- The game's refusals that are about the target, not you: the client's own
-- strings where it has them, and their English text otherwise. A refusal
-- about you (the global cooldown, mana, being stunned) moves no one back.
local TARGET_REFUSAL_GLOBALS = {
    "SPELL_FAILED_LINE_OF_SIGHT", "SPELL_FAILED_OUT_OF_RANGE", "ERR_OUT_OF_RANGE",
    "SPELL_FAILED_BAD_TARGETS", "SPELL_FAILED_BAD_IMPLICIT_TARGETS", "SPELL_FAILED_TARGETS_DEAD",
}
local TARGET_REFUSAL_TEXT = {
    "target not in line of sight", "out of range", "invalid target", "no target", "target is dead",
}

local function Normalise(text)
    return (text:lower():gsub("[%.!]+$", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function GroupBuffs.IsTargetRefusal(text)
    if type(text) ~= "string" or Util.IsSecret(text) then return false end
    -- Colour codes come off first, so their letters don't stay behind.
    local said = Normalise(Util.StripChat((text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))))
    for _, name in ipairs(TARGET_REFUSAL_GLOBALS) do
        local known = rawget(_G, name)
        if type(known) == "string" and known ~= "" and Normalise(known) == said then return true end
    end
    for _, known in ipairs(TARGET_REFUSAL_TEXT) do
        if said == known then return true end
    end
    return false
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
    for name, at in pairs(justRevoked) do
        if not Recently(at, GroupBuffs.JUST_GIVEN_SECONDS) then justRevoked[name] = nil end
    end
    for name, at in pairs(skipped) do
        if not Recently(at, GroupBuffs.SKIP_SECONDS) then skipped[name] = nil end
    end
    for name, at in pairs(heldBack) do
        if not Recently(at, GroupBuffs.HELD_BACK_SECONDS) then heldBack[name] = nil end
    end
end
