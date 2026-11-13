-- Group versions in buff mode (#41): Arcane Brilliance, the Prayers and Gift
-- of the Wild cover a whole party (in a raid, a subgroup) in one cast. When
-- you know the group version, carry its reagent, and enough of the members
-- it would cover are missing the buff, buff mode offers it before the single
-- buff. Otherwise the single buff is offered as before, with the reason.
--
-- Nothing here casts: this only chooses what the buff-back button holds, and
-- the button casts only on your press, through its secure macro, aimed at a
-- member who passed the same checks as for a single buff.
--
-- Never worse than single buffs. A group version is offered only if every
-- member it would cover (the target's whole party or subgroup, you
-- included) passes the checks below. Anything that can't be read fails them,
-- and the single buff is offered instead:
--   - not flagged for PvP, unless you are (the cast would flag you);
--   - allowed the buff by your rules (BuffRules.lua);
--   - not wearing a higher rank of the buff from you than the group
--     version's (it would replace it);
--   - among those it would renew, none missing it only because a stronger
--     buff, from anyone, is running low (#206): the game keeps the stronger
--     one, so the single buff renews them.
-- Members out of range for the cast are filled in one by one afterwards.
local _, ns = ...
local Util = ns.Util
local Read = Util.ReadGameValues

local GroupCasts = {}
ns.GroupCasts = GroupCasts

-- Right-click skips a group for this long (as a member is skipped).
GroupCasts.SKIP_SECONDS = 300
GroupCasts.MAX_SUBGROUP = 8

-- What a class is called in "Warriors (6 missing)", by class file name. A
-- class that isn't here is a class we can't name: unreadable.
local CLASS_PLURAL = {
    WARRIOR = "Warriors", PALADIN = "Paladins", HUNTER = "Hunters", ROGUE = "Rogues", PRIEST = "Priests",
    SHAMAN = "Shamans", MAGE = "Mages", WARLOCK = "Warlocks", DRUID = "Druids",
}

local skipped = {} -- [buff key .. "\1" .. group key] = GetTime() you right-clicked it

local function Recently(at, seconds)
    return at ~= nil and GetTime() - at < seconds
end

-- Whether group versions are on: a damaged value reads as the default (on).
function GroupCasts.Enabled()
    local value = ns.db and type(ns.db.buffBack) == "table" and ns.db.buffBack.groupVersions
    if type(value) == "boolean" then return value end
    return ns.Config.DEFAULTS.buffBack.groupVersions
end

-- How many members must be missing a buff before its group version is
-- offered, read defensively.
function GroupCasts.Enough()
    local limits = ns.Config.LIMITS.groupEnough
    return Util.ClampNumber(ns.db and type(ns.db.buffBack) == "table" and ns.db.buffBack.groupEnough,
        limits.min, limits.max, ns.Config.DEFAULTS.buffBack.groupEnough)
end

-- How many of a reagent you carry, or nil when it can't be read.
local function ReagentCount(item)
    local count = Read(C_Item and C_Item.GetItemCount, item)
    if count == nil then count = Read(GetItemCount, item) end
    if type(count) ~= "number" or count ~= count then return nil end
    return count
end

local function ReagentName(item)
    local name = Read(C_Item and C_Item.GetItemNameByID, item)
    if type(name) == "string" and name ~= "" then return Util.StripChat(name) end
    return ns.BuffData.REAGENTS[item] or "reagent"
end

-- Everyone in your group with the group a cast would cover them in: { unit,
-- name, class, group = key, label }, you included (a group version covers
-- you too), or nil and why when it can't be told: a slot that can't be read
-- as holding someone or empty leaves everyone unknown. A party-wide version
-- (scope "party"): in a party everyone is one group; in a raid a member's
-- subgroup is GetRaidRosterInfo's, and one that can't be read for anyone
-- leaves every subgroup unknown. A class-wide one (scope "class"): a
-- member's class.
local function Roster(units, inRaid, scope)
    local out = {}
    local me = Util.UnitFullName("player")
    local sawMe = false
    for i, unit in ipairs(units) do
        -- Only a slot the game says is empty is left out (#302). One whose
        -- existence can't be read (a secret, or no answer) may hold a member
        -- the cast would cover with nothing here having checked them: their
        -- PvP flag, your rules, the buffs they wear. Nobody can be told to
        -- be covered safely, so every group is unknown.
        local exists = Read(UnitExists, unit)
        if exists ~= true and exists ~= false then return nil, "can't read a group member" end
        if exists then
            local name = Util.UnitFullName(unit)
            local isMe = (name ~= nil and name == me) or Read(UnitIsUnit, unit, "player") == true
            sawMe = sawMe or isMe
            local entry = { unit = unit, name = name, isMe = isMe,
                class = select(2, Read(UnitClass, unit)) }
            if scope == "class" then
                -- Every member of the target's class (Greater Blessings): a
                -- class that can't be read or named leaves every class unknown.
                local plural = type(entry.class) == "string" and CLASS_PLURAL[entry.class]
                if not plural then return nil, "can't read a group member's class" end
                entry.group, entry.label = entry.class, plural
            elseif inRaid then
                local _, _, subgroup = Read(GetRaidRosterInfo, i)
                if type(subgroup) ~= "number" or subgroup ~= math.floor(subgroup)
                    or subgroup < 1 or subgroup > GroupCasts.MAX_SUBGROUP then
                    return nil, "can't read the raid's subgroups"
                end
                entry.group, entry.label = "group" .. subgroup, "Group " .. subgroup
            else
                entry.group, entry.label = "party", "your party"
            end
            out[#out + 1] = entry
        end
    end
    -- In a party you aren't one of its slots, but a group version covers
    -- you too: your rules and your own buffs count like anyone's. (In a raid
    -- the game gives you a slot.)
    if not inRaid and not sawMe then
        out[#out + 1] = { unit = "player", name = me, isMe = true, group = "party", label = "your party",
            class = select(2, Read(UnitClass, "player")) }
    end
    return out
end

-- Whether unit wears, from you (from anyone, with anyone), a higher rank of
-- buff than `equals` (the single-target rank the group version matches), a
-- group version counting as the rank it equals (#206): true, false, or nil
-- when their buffs, or who cast one, can't be read.
local function WearsHigherRank(unit, buff, equals, anyone)
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not api then return nil end
    local equalsAt = ns.BuffData.RankOf(buff, equals)
    if not equalsAt then return nil end
    for i = 1, ns.Offers.MAX_AURAS do
        local ok, aura = pcall(api, unit, i, "HELPFUL")
        if not ok or Util.IsSecret(aura) then return nil end
        if aura == nil then return false end
        local id = aura.spellId
        if Util.IsSecret(id) then return nil end
        local at = ns.BuffData.RankOf(buff, id)
        if at and at < equalsAt then
            if anyone then return true end
            local mine = Util.CastByYou(aura.sourceUnit)
            if mine == nil then return nil end
            if mine then return true end
        end
    end
    return false
end

-- The other Blessing of yours (a buff of buff's family, but not buff) unit
-- wears: that buff, false when none, or nil when their buffs, or who cast
-- one, can't be read. A Greater Blessing replaces the Blessing of yours on
-- everyone it covers, so nobody's Might may be turned into Kings.
local function WearsOtherBlessing(unit, buff)
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not api then return nil end
    for i = 1, ns.Offers.MAX_AURAS do
        local ok, aura = pcall(api, unit, i, "HELPFUL")
        if not ok or Util.IsSecret(aura) then return nil end
        if aura == nil then return false end
        local id = aura.spellId
        if Util.IsSecret(id) then return nil end
        local other = ns.BuffData.ForAura(id)
        if other and other.family == buff.family and other.key ~= buff.key then
            local mine = Util.CastByYou(aura.sourceUnit)
            if mine == nil then return nil end
            if mine then return other end
        end
    end
    return false
end

-- Why the group version can't renew these missing members, or nil: one of
-- them is missing it only because a stronger buff (from anyone) is running
-- low (#206), which the weaker cast can't replace. The single buff, at least
-- as strong (BuffData.CanReplace), renews them instead.
local function Weaker(buff, spell, missing)
    for _, m in ipairs(missing) do
        local stronger = WearsHigherRank(m.unit, buff, spell.equals, true)
        local who = m.self and "you" or Util.DisplayName(m.name)
        if stronger == nil then return "can't tell whose buff " .. who .. " wears" end
        if stronger then
            return (m.self and "Your" or (who .. "'s")) .. " buff is stronger than your " .. spell.name
        end
    end
end

local function Cap(text)
    return (text:gsub("^%l", string.upper))
end

-- Why the group version can't go to this group, or nil if it can: every
-- member it would cover has to pass.
local function WhyNot(buff, spell, members, iAmFlagged, ctx)
    for _, m in ipairs(members) do
        local who = m.isMe and "you" or m.name and Util.DisplayName(m.name) or "a group member"
        if Read(UnitIsConnected, m.unit) ~= false then
            -- Reading it for the dead too: a flagged player who is down
            -- may be back up by the time the cast goes out.
            if not iAmFlagged then
                local flagged = Read(UnitIsPVP, m.unit)
                if flagged == true then return Cap(who) .. " is flagged for PvP and you aren't" end
                if flagged == nil then return "can't see whether " .. who .. " is flagged for PvP" end
            end
        end
        if not m.name and not m.isMe then return "a group member's name can't be read" end
        -- (Your own name is only for the Always and Never lists.)
        local allowed, ruleWhy = ns.BuffRules.Allows(buff, { unit = m.unit, name = m.name or "", class = m.class })
        if allowed == nil then return ruleWhy and (Cap(who) .. ": " .. ruleWhy) or "a rule can't be applied" end
        if allowed ~= true then return "your rules leave " .. who .. " out" end
        if buff.family then
            local other = WearsOtherBlessing(m.unit, buff)
            if other == nil then return "can't tell whose Blessing " .. who .. " wears" end
            if other then
                return Cap(who) .. (m.isMe and " wear" or " wears") .. " your "
                    .. (ns.BuffData.SpellName(other) or "other Blessing") .. ", which it would replace"
            end
        end
        local higher = WearsHigherRank(m.unit, buff, spell.equals)
        if higher == nil then return "can't tell whose buff " .. who .. " wears" end
        if higher then return Cap(who) .. (m.isMe and " wear" or " wears") .. " a higher rank of yours" end
        -- A buff of theirs it would replace that isn't for buff mode to
        -- cast over (#256: GroupBuffs says whose).
        local kept = ctx and ctx.Blocked and ctx.Blocked(m, spell.equals)
        if kept then return Cap(kept) end
    end
end

-- The group version to offer for buff now, or nil and why not (said on the
-- button when the single buff is offered instead; nil, nil when group
-- versions don't apply: off, or the buff has none).
--   members  the group members who may be buffed now (GroupBuffs.Candidates),
--            and you first when you're offered the buff too (#198)
--   ctx      { units = the group's unit tokens, inRaid, Needs = function(member)
--            true if they're missing the buff and may have it, InRange =
--            function(spell, unit) false if the spell can't reach them,
--            Blocked = function(entry, equals) why the cast (as strong as
--            the single rank `equals`) mustn't cover that member (#256), or nil }
-- The reason comes with a third value, true for one worth only a line in the
-- button's tooltip, not its face (a group version you haven't learned, which
-- stays true for a long time).
-- Returns { name = the member to aim at, buff, spell = the group version's
-- name, group = true, cast = { key, label, count, covers = { names } } }.
function GroupCasts.Offer(buff, members, ctx)
    if not buff.groupCast or not GroupCasts.Enabled() then return nil end
    local spell = ns.BuffData.KnownGroupCast(buff)
    local groupName = spell and spell.name or ns.BuffData.GroupCastName(buff) or "the group version"
    local function Single(why) return nil, why .. ": buffing one at a time" end
    if not spell then
        local _, why = Single("You haven't learned " .. groupName)
        return nil, why, true
    end

    -- Class-wide versions (Greater Blessings) are for a raid: in a party the
    -- single Blessing is just as fast, so nothing is said about them.
    if spell.scope == "class" and not ctx.inRaid then return nil end
    -- "Tanks only" never gets a class-wide cast (#41: Greater Blessing of
    -- Kings is never offered with "Kings: tanks only"): the single Blessing
    -- goes to each tank.
    if spell.scope == "class" and ns.BuffRules.Rule(buff) == "tanks" then return nil end

    local missing = {}
    for _, member in ipairs(members) do
        if ctx.Needs(member) then missing[#missing + 1] = member end
    end
    if #missing == 0 then return nil end
    local enough = GroupCasts.Enough()
    if #missing < enough then
        return Single(string.format("Only %d missing, %s needs %d", #missing, groupName, enough))
    end

    local count = ReagentCount(spell.reagent)
    if count == nil then return Single("Can't count your " .. ReagentName(spell.reagent)) end
    if count < 1 then return Single("No " .. ReagentName(spell.reagent)) end

    local roster, why = Roster(ctx.units, ctx.inRaid, spell.scope)
    if not roster then return Single(why) end
    local groups, order = {}, {}
    for _, entry in ipairs(roster) do
        local g = groups[entry.group]
        if not g then
            g = { key = entry.group, label = entry.label, members = {}, missing = {} }
            groups[entry.group] = g
            order[#order + 1] = g
        end
        g.members[#g.members + 1] = entry
    end
    local byName = {}
    for _, entry in ipairs(roster) do
        if entry.name then byName[entry.name] = entry end
    end
    for _, member in ipairs(missing) do
        local entry = byName[member.name]
        if entry then
            local g = groups[entry.group]
            g.missing[#g.missing + 1] = member
        end
    end
    -- The group with the most members missing the buff first; ties keep
    -- group order.
    local ranked = {}
    for i, g in ipairs(order) do
        if #g.missing > 0 then ranked[#ranked + 1] = { g = g, at = i } end
    end
    table.sort(ranked, function(a, b)
        if #a.g.missing ~= #b.g.missing then return #a.g.missing > #b.g.missing end
        return a.at < b.at
    end)

    local iAmFlagged = Read(UnitIsPVP, "player") == true
    local firstWhy
    for _, r in ipairs(ranked) do
        local g = r.g
        if #g.missing < enough then break end
        if Recently(skipped[buff.key .. "\1" .. g.key], GroupCasts.SKIP_SECONDS) then
            firstWhy = firstWhy or ("You skipped " .. g.label)
        else
            local blocked = WhyNot(buff, spell, g.members, iAmFlagged, ctx) or Weaker(buff, spell, g.missing)
            if blocked then
                firstWhy = firstWhy or blocked
            else
                -- Aimed at the first missing member the spell can reach: never
                -- at you (a cast aimed at yourself is the single buff's job),
                -- though the group version covers you too.
                for _, member in ipairs(g.missing) do
                    if not member.self and ctx.InRange(spell.name, member.unit) ~= false then
                        local names, coversSelf = {}, false
                        for i, m in ipairs(g.missing) do
                            names[i] = m.name
                            coversSelf = coversSelf or m.self == true
                        end
                        return { name = member.name, buff = buff, spell = spell.name, group = true,
                            cast = { key = buff.key .. "\1" .. g.key, label = g.label, count = #g.missing,
                                covers = names, coversSelf = coversSelf } }
                    end
                end
                firstWhy = firstWhy or "nobody it covers is in range"
            end
        end
    end
    return Single(firstWhy or "Not enough in one group")
end

-- Right-click on a group cast: leave that group out of the group version
-- for a while. The members are still offered the single buff.
function GroupCasts.Skip(castKey)
    skipped[castKey] = GetTime()
end

-- How many skipped groups are remembered (for the specs).
function GroupCasts.Remembered()
    local n = 0
    for _ in pairs(skipped) do n = n + 1 end
    return n
end

function GroupCasts.Prune()
    for key, at in pairs(skipped) do
        if not Recently(at, GroupCasts.SKIP_SECONDS) then skipped[key] = nil end
    end
end
