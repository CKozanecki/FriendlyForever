-- Congratulates a party member who levels up (#273). UNIT_LEVEL fires for
-- party1..4 on a level-up, but also on joining, zoning and refreshes with no
-- change, so a congratulation goes out only when the level read is higher
-- than the one last seen for that player. Parties only: quiet in raids,
-- battlegrounds and arenas, and never for your own level-up (only party
-- units are watched). Every copy of the addon congratulates; there is no
-- coordination (owner's decision). The lines never name the level (owner).
-- Chat goes through Announcer.Schedule, so AFK, snooze, lockdown, the chat
-- cap and the per-player repeat cooldown apply; a second level-up inside the
-- cooldown is skipped.
local _, ns = ...
local Util = ns.Util

local LevelUps = {}
ns.LevelUps = LevelUps

-- The highest level a read is believed (a damaged read is dropped).
LevelUps.MAX_LEVEL = 100

local PARTY_UNITS = { party1 = true, party2 = true, party3 = true, party4 = true }
local SLOTS = { "party1", "party2", "party3", "party4" }

local levels = {} -- [full name] = last level seen, for the current party only

-- A level the game gave, or nil when it is secret, missing or not a sane integer.
local function ReadLevel(unit)
    local level = Util.ReadGameValues(UnitLevel, unit)
    if type(level) ~= "number" or level ~= level or level < 1 or level > LevelUps.MAX_LEVEL
        or level ~= math.floor(level) then
        return nil
    end
    return level
end

-- Whether a congratulation may go out now, and why not. Unreadable counts as
-- quiet: the safe side.
function LevelUps.Allowed()
    if not IsInGroup() then return false, "you're not in a group" end
    if IsInRaid() then return false, "in a raid" end
    -- Not Greeter.InBattleground(): it counts every instance group, and a
    -- dungeon-finder group is a party here (owner's decision on #273).
    local inside, kind = Util.ReadGameValues(IsInInstance)
    if inside == nil or kind == nil then return false, "can't tell if you're in an arena" end
    if kind == "arena" or kind == "pvp" then return false, "in an arena or battleground" end
    return true
end

-- Remember each party member's level, forgetting those who left. Run on
-- group changes and at login, so the first level-up after joining has a
-- level to be higher than.
function LevelUps.OnGroupRosterUpdate()
    local seen = {}
    for _, unit in ipairs(SLOTS) do
        local name = Util.UnitFullName(unit)
        if name then
            seen[name] = levels[name] or ReadLevel(unit)
        end
    end
    levels = seen
end

function LevelUps.OnUnitLevel(unit)
    if type(unit) ~= "string" or not PARTY_UNITS[unit] then return end
    local name = Util.UnitFullName(unit)
    local level = ReadLevel(unit)
    if not name or not level then return end
    local before = levels[name]
    levels[name] = level
    if not before or level <= before then
        ns.Diag.Log("levelUp", "%s: level read, no rise (%s -> %s)", name, tostring(before), level)
        return
    end
    local ok, why = LevelUps.Allowed()
    if not ok then
        ns.Diag.Log("levelUp", "not sending for %s: %s", name, why)
        return
    end
    if ns.Ignore.Has(name) then
        ns.Diag.Log("levelUp", "not sending for %s: on your ignore list", name)
        return
    end
    ns.Announcer.Schedule("levelUp", name, {
        channel = ns.Greeter.GroupChannel,
        isValid = function()
            local still, reason = LevelUps.Allowed()
            if not still then return false, reason end
            if ns.Ignore.Has(name) then return false, "on your ignore list" end
            if ns.Greeter.IsInMyGroup(name) == false then return false, "they left your group" end
            return true
        end,
    })
end
