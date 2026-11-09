-- The raid buff split (#70): copies of the addon in the same raid share out
-- the buffs their class has in common, so three priests give Fortitude,
-- Spirit and Shadow Protection between them instead of all racing to give
-- Fortitude, and two paladins give different Blessings.
--
-- Each copy announces over the hidden channel (Comm.lua, SHARE on the RAID
-- route) the buffs it can give, in its buff order, and the Blessings set by
-- hand for this raid ("My Blessings in this raid", BuffRules.lua, #68).
-- Every copy then runs the same deterministic split on the same list, with
-- no leader and no voting (Split, below), and buff mode offers you only
-- your share (BuffRules.CoversInRaid).
--
-- Safety: the split only narrows what buff mode offers. It never casts,
-- sends chat or changes saved settings. Every SHARE is untrusted: Comm has
-- already checked its form and that its sender is its subject; here a
-- sender who isn't in your raid now, isn't your class (read from the game,
-- never from the message) or is offline is ignored, and keys that aren't
-- your class's buffs are dropped. A message can only put its own sender
-- into the split, or change their own list; there is one entry per raid
-- member at most. Anything that can't be read leaves you offered every
-- buff, as without the split.
--
-- Who takes part (the owner's decisions on #70): copies with the split
-- switched on (Buff Back tab, on by default), while buff mode is on and for
-- GRACE seconds after it goes off; a copy that isn't says so once ("-").
-- Copies re-announce every HEARTBEAT seconds; one not heard for SILENT
-- seconds, or that leaves the raid or goes offline, drops out, and its
-- share goes back into the split. When there are more players than buffs,
-- priests, mages and druids holding the same buff split the raid's groups
-- 1-8; an extra paladin is a backup.
--
-- Raids only: in a party, or alone, nothing changes.
local _, ns = ...
local Util = ns.Util
local Read = Util.ReadGameValues

local RaidSplit = {}
ns.RaidSplit = RaidSplit

-- After the roster changes, wait this long for it to settle before saying
-- what you give, and say it at most once per MIN_GAP seconds.
RaidSplit.SETTLE = 2
RaidSplit.MIN_GAP = 10
-- The owner's choices (#70, 2026-11-09): say it again every HEARTBEAT
-- seconds in a raid; a copy not heard for SILENT seconds drops out; you take
-- part for GRACE seconds after buff mode goes off.
RaidSplit.HEARTBEAT = 60
RaidSplit.SILENT = 180
RaidSplit.GRACE = 300
-- The raid's groups, split between players holding the same buff.
RaidSplit.GROUPS = 8

local RAID_UNITS = {}
for i = 1, 40 do RAID_UNITS[i] = "raid" .. i end

-- [full name] = { keys = { key, ... } in their order, fixed = { [key] = true }
-- or nil, heardAt = GetTime() }: what each other copy of your class in this
-- raid last announced, and when.
local peers = {}
local lastSent        -- the text of our last SHARE ("keys;fixed"), or nil
local lastSentAt      -- GetTime() it went
local sendPending = false

------------------------------------------------------------------------
-- The split itself
------------------------------------------------------------------------

-- The deterministic split. players: a list of { name, keys = { key, ... }
-- in that player's buff order, fixed = { [key] = true } or nil }. Returns
-- [name] = { [key] = true or { [group] = true } }, every player's share: a
-- buff for the whole raid, or for those groups of it.
--
-- 1. A player who set their Blessings by hand holds exactly those, and
--    takes nothing else.
-- 2. The others draft the buffs nobody holds yet, in rounds: in name order
--    in the first round, the reverse in the second, and so on (so the
--    player who picks last in one round picks first in the next). On their
--    turn a player takes the first buff in their own order nobody holds.
--    Two paladins with Kings > Wisdom > Might: the first gives Kings, the
--    second Wisdom and Might, which reach different classes.
-- Names are compared as bytes, so every copy sorts them the same way.
function RaidSplit.Split(players)
    local list = {}
    for _, p in ipairs(players) do list[#list + 1] = p end
    table.sort(list, function(a, b) return a.name < b.name end)
    local shares, held, drafting = {}, {}, {}
    for _, p in ipairs(list) do
        shares[p.name] = {}
        if p.fixed then
            for key in pairs(p.fixed) do
                shares[p.name][key] = true
                held[key] = true
            end
        else
            drafting[#drafting + 1] = p
        end
    end
    local function FirstFree(p)
        for _, key in ipairs(p.keys) do
            if not held[key] then return key end
        end
    end
    local forward = true
    while true do
        local took = false
        local from, to, step = 1, #drafting, 1
        if not forward then from, to, step = #drafting, 1, -1 end
        for i = from, to, step do
            local p = drafting[i]
            local key = FirstFree(p)
            if key then
                shares[p.name][key] = true
                held[key] = true
                took = true
            end
        end
        if not took then break end
        forward = not forward
    end
    -- 3. More players than buffs: a player still holding nothing takes, in
    --    name order, the buff in their order that the fewest hold, Blessings
    --    left out (a player keeps one Blessing per paladin: a spare paladin
    --    is a backup). Then the holders of each such buff split the raid's
    --    groups in name order: two mages get groups 1-4 and 5-8.
    local holders = {}
    for _, p in ipairs(list) do
        for key in pairs(shares[p.name]) do holders[key] = (holders[key] or 0) + 1 end
    end
    local spread = {}
    for _, p in ipairs(drafting) do
        if next(shares[p.name]) == nil then
            local best
            for _, key in ipairs(p.keys) do
                local buff = ns.BuffData.ByKey(key)
                if buff and buff.family ~= "blessing" and (not best or (holders[key] or 0) < (holders[best] or 0)) then
                    best = key
                end
            end
            if best then
                shares[p.name][best] = true
                holders[best] = (holders[best] or 0) + 1
                spread[best] = true
            end
        end
    end
    for key in pairs(spread) do
        local names = {}
        for _, p in ipairs(list) do
            if shares[p.name][key] then names[#names + 1] = p.name end
        end
        local n = #names
        for i, name in ipairs(names) do
            local from, to = math.floor((i - 1) * RaidSplit.GROUPS / n) + 1, math.floor(i * RaidSplit.GROUPS / n)
            if from > to then
                shares[name][key] = nil -- more holders than groups: a backup
            else
                local groups = {}
                for g = from, to do groups[g] = true end
                shares[name][key] = groups
            end
        end
    end
    return shares
end

------------------------------------------------------------------------
-- Who's in it
------------------------------------------------------------------------

local function InRaid()
    return Read(IsInRaid) == true
end

-- Your class's file name ("PRIEST"), or nil when it can't be read.
local function MyClass()
    local _, class = Read(UnitClass, "player")
    if type(class) == "string" and ns.BuffData.CLASSES[class] then return class end
end

-- Whether buff is one the split shares: your class's, and not cast on
-- yourself (Battle Shout reaches only your party: never shared).
local function Shared(buff)
    return buff ~= nil and not buff.selfCast
end

-- [key] = buff for your class's shared buffs.
local function ClassKeys(class)
    local out = {}
    for _, buff in ipairs(ns.BuffData.CLASSES[class] or {}) do
        if Shared(buff) then out[buff.key] = buff end
    end
    return out
end

-- The raid as the game sees it now: [full name] = { unit, class, online },
-- and whether any slot couldn't be read (someone might be missing).
local function Roster()
    local out, unreadable = {}, false
    for _, unit in ipairs(RAID_UNITS) do
        local exists = Read(UnitExists, unit)
        if exists == nil then
            unreadable = true
        elseif exists then
            local full = Util.UnitFullName(unit)
            if full == nil then
                unreadable = true
            elseif not out[full] then
                local _, class = Read(UnitClass, unit)
                out[full] = { unit = unit, class = type(class) == "string" and class or nil,
                    online = Read(UnitIsConnected, unit) == true }
            end
        end
    end
    return out, unreadable
end

-- Whether a peer's last share is recent enough to count: heard within
-- SILENT seconds (a clock that went back can't tell: it isn't).
local function Fresh(entry, now)
    return now >= entry.heardAt and now - entry.heardAt <= RaidSplit.SILENT
end

-- Whether the split is switched on (Buff Back tab); damaged reads as on.
function RaidSplit.Enabled()
    local value = ns.db and type(ns.db.buffBack) == "table" and ns.db.buffBack.raidSplit
    if type(value) == "boolean" then return value end
    return ns.Config.DEFAULTS.buffBack.raidSplit
end

-- Whether you take part now: buff mode is on, or went off less than GRACE
-- seconds ago.
local lastOnAt
local function TakingPart()
    local now = GetTime()
    if ns.BuffMode.IsOn() then
        lastOnAt = now
        return true
    end
    return lastOnAt ~= nil and now >= lastOnAt and now - lastOnAt < RaidSplit.GRACE
end

-- Whether name is someone the split may count: in your raid now, of your
-- class, and online, as the game says. Anything unreadable is a no.
local function Eligible(roster, name, class)
    local member = roster[name]
    return member ~= nil and member.class == class and member.online
end

-- My own entry: the buffs I can give, in my order, less those I never
-- offer; and my Blessings set by hand for this raid, or nil.
local function MyEntry(class)
    local allowed = ClassKeys(class)
    local keys = {}
    for _, buff in ipairs(ns.BuffData.Offerable()) do
        if allowed[buff.key] then keys[#keys + 1] = buff.key end
    end
    local fixed = ns.BuffRules.HandSetBlessings()
    return { keys = keys, fixed = fixed }
end

-- Everyone in the split now (you first), or nil and why there's no split:
-- switched off, not in a raid, not taking part, your class or name can't be
-- read, or nobody else of your class has said lately that they take part.
local function Players()
    if not RaidSplit.Enabled() then return nil, "switched off" end
    if not InRaid() then return nil, "not in a raid" end
    local class = MyClass()
    if not class then return nil, "can't read your class" end
    local me = Util.UnitFullName("player")
    if not me then return nil, "can't read your name" end
    if next(ClassKeys(class)) == nil then return nil, "your class has no buffs to share" end
    if not TakingPart() then return nil, "you take part while buff mode is on" end
    local mine = MyEntry(class)
    local list = { { name = me, keys = mine.keys, fixed = mine.fixed, me = true } }
    local roster = Roster()
    local now = GetTime()
    for name, entry in pairs(peers) do
        if name ~= me and (#entry.keys > 0 or entry.fixed) and Fresh(entry, now) and Eligible(roster, name, class) then
            list[#list + 1] = { name = name, keys = entry.keys, fixed = entry.fixed }
        end
    end
    if #list < 2 then return nil, "no other copy of your class in this raid" end
    return list
end

-- Your share now: { [key] = true }, and the whole split ([name] = share),
-- or nil and why there's none (you're offered everything). Worked out once
-- per moment (GetTime()): buff mode asks for every buff and member at each
-- refresh. Anything that changes it (a share heard, the roster, your
-- settings) clears it.
local cache
function RaidSplit.Current()
    local now = GetTime()
    if not (cache and cache.at == now) then
        local players, why = Players()
        cache = { at = now, why = why }
        if players then
            cache.shares = RaidSplit.Split(players)
            cache.mine = cache.shares[players[1].name]
        end
    end
    if not cache.mine then return nil, cache.why end
    return cache.mine, cache.shares
end

local function Changed()
    cache = nil
end

-- Whether buff mode may offer buff (it's yours to give in this raid): every
-- buff when there's no split, else your share (a buff the split doesn't
-- share, such as Battle Shout, is never in it; buff mode never offers those
-- to the group).
function RaidSplit.Covers(buff)
    local mine = RaidSplit.Current()
    if not mine then return true end
    return mine[buff.key] ~= nil
end

-- The raid group (1-8) unit is in, or nil when it can't be read.
local function GroupOf(unit)
    local index = type(unit) == "string" and tonumber(unit:match("^raid(%d+)$"))
    if not index and unit == "player" then
        for i, raidUnit in ipairs(RAID_UNITS) do
            if Read(UnitIsUnit, raidUnit, "player") == true then
                index = i
                break
            end
        end
    end
    if not index then return nil end
    local _, _, group = Read(GetRaidRosterInfo, index)
    if type(group) == "number" and group == math.floor(group) and group >= 1 and group <= RaidSplit.GROUPS then
        return group
    end
end

-- Whether buff may go to member ({ unit, ... }) under the split (BuffRules.Allows):
-- true; or false and why, when your share of it is some of the raid's groups
-- and theirs isn't one. A group that can't be read is offered (the split
-- only narrows what it can tell).
function RaidSplit.CoversMember(buff, member)
    local mine = RaidSplit.Current()
    local groups = mine and mine[buff.key]
    if type(groups) ~= "table" then return true end
    local group = GroupOf(member.unit)
    if group == nil or groups[group] then return true end
    return false, "another copy has their group"
end

------------------------------------------------------------------------
-- Announcing
------------------------------------------------------------------------

local function KeyText(keys)
    if #keys == 0 then return "-" end
    return table.concat(keys, ",")
end

local function FixedText(fixed, order)
    if not fixed then return "-" end
    local out = {}
    for _, key in ipairs(order) do
        if fixed[key] then out[#out + 1] = key end
    end
    return KeyText(out)
end

-- What you'd announce now, as the message's first two fields, or nil when you
-- announce nothing (not in a raid, the channel is closed, your class
-- can't be read or has nothing to share).
local function MyFields()
    if not RaidSplit.Enabled() or not InRaid() or not ns.Comm.Ready() then return nil end
    local class = MyClass()
    -- A class with nothing to share (warriors) has nothing to say.
    if not class or next(ClassKeys(class)) == nil then return nil end
    -- Not taking part: say so ("-"), so your share goes back at once.
    if not TakingPart() then return "-", "-" end
    local mine = MyEntry(class)
    return KeyText(mine.keys), FixedText(mine.fixed, mine.keys)
end

local forcePending = false

-- Say what you give, if it changed since you last did (or forcePending).
local function SendNow()
    sendPending = false
    local force = forcePending
    forcePending = false
    local keys, fixed = MyFields()
    if not keys then return end
    local text = keys .. ";" .. fixed
    -- "Not taking part" is said once, however often anyone asks.
    if text == lastSent and (not force or keys == "-") then return end
    -- The first since you joined (or since a reload) asks the others to
    -- say theirs: they may not have changed, so wouldn't say it otherwise.
    if ns.Comm.SendShare(keys, fixed, lastSent == nil) then
        lastSent, lastSentAt = text, GetTime()
    end
end

-- Say what you give soon: after SETTLE, and no sooner than MIN_GAP after
-- the last time, so a roster that changes many times in a row costs one
-- message. force: say it even if it hasn't changed (a new member needs to
-- hear it).
function RaidSplit.Announce(force)
    forcePending = forcePending or force == true
    if sendPending then return end
    sendPending = true
    local wait = RaidSplit.SETTLE
    if lastSentAt then
        local now = GetTime()
        -- A clock that went back can't time the gap: wait the whole gap.
        local since = now >= lastSentAt and now - lastSentAt or 0
        wait = math.max(wait, RaidSplit.MIN_GAP - since)
    end
    C_Timer.After(wait, ns.Diag.Wrap(SendNow))
end

-- Called at each refresh of the button (BuffButton.Refresh): your buff
-- order, never-offer marks, spells or hand-set Blessings may have changed.
-- Cheap when nothing has; announces when something did.
function RaidSplit.Check()
    Changed()
    local keys, fixed = MyFields()
    if keys and keys .. ";" .. fixed ~= lastSent then RaidSplit.Announce(false) end
end

------------------------------------------------------------------------
-- Hearing
------------------------------------------------------------------------

-- The keys in text (passed Comm.Field.KeyList) that are allowed, in order,
-- each once.
local function ParseKeys(text, allowed)
    local out, seen = {}, {}
    if text == "-" then return out end
    for key in text:gmatch("[^,]+") do
        if allowed[key] and not seen[key] then
            seen[key] = true
            out[#out + 1] = key
        end
    end
    return out
end

-- SHARE from another copy (Comm.lua): the buff keys it gives, in its order,
-- its Blessings set by hand ("-": none), and whether it asks to hear ours
-- (it just arrived). Untrusted.
function RaidSplit.OnShare(sender, keysText, fixedText, asks)
    local class = MyClass()
    if not class then return end
    local roster = Roster()
    if not Eligible(roster, sender, class) then
        -- Another class's shares are everyday raid traffic, and an offline
        -- sender a race with the roster: only a sender not in your raid at
        -- all is counted, for /friendly status.
        if not roster[sender] then ns.Diag.Count("splitIgnored") end
        ns.Diag.Log("split", "ignored a share from %s: not an online %s in your raid", sender, class)
        return
    end
    local allowed = ClassKeys(class)
    local keys = ParseKeys(keysText, allowed)
    local given = {}
    for _, key in ipairs(keys) do given[key] = true end
    -- Blessings set by hand: only Blessings they said they give.
    local fixed
    for _, key in ipairs(ParseKeys(fixedText, allowed)) do
        if given[key] and allowed[key].family == "blessing" then
            fixed = fixed or {}
            fixed[key] = true
        end
    end
    peers[sender] = { keys = keys, fixed = fixed, heardAt = GetTime() }
    Changed()
    ns.Diag.Log("split", "%s gives %s (by hand: %s)", sender, KeyText(keys), fixedText)
    -- Rate-limited (Announce): a sender asking again and again costs one
    -- message per MIN_GAP.
    if asks then RaidSplit.Announce(true) end
end

-- The roster changed (GROUP_ROSTER_UPDATE): forget everyone who left the
-- raid, and say what you give once it settles (a new member needs to hear).
local beatToken, beating = 0, false

-- Every HEARTBEAT seconds while in a raid: say it again (so a silent copy
-- can be told from a quiet one), or say once that you no longer take part.
local function Beat(token)
    if token ~= beatToken then return end
    if not InRaid() then
        beating = false
        return
    end
    Changed()
    RaidSplit.Announce(true)
    C_Timer.After(RaidSplit.HEARTBEAT, ns.Diag.Wrap(function() Beat(token) end))
end

function RaidSplit.OnRosterUpdate()
    Changed()
    if not InRaid() then
        peers, lastSent, lastSentAt = {}, nil, nil
        beatToken, beating = beatToken + 1, false
        return
    end
    if not beating then
        beating = true
        local token = beatToken
        C_Timer.After(RaidSplit.HEARTBEAT, ns.Diag.Wrap(function() Beat(token) end))
    end
    local roster, unreadable = Roster()
    if not unreadable then
        for name in pairs(peers) do
            if not roster[name] then peers[name] = nil end
        end
    end
    RaidSplit.Announce(true)
end

-- A fight ended (PLAYER_REGEN_ENABLED). Heartbeats sent in it may have been
-- blocked, so the others may have stopped counting you: say it again now.
function RaidSplit.OnCombatEnd()
    if InRaid() then RaidSplit.Announce(true) end
end

function RaidSplit.PeerCount()
    local n = 0
    for _ in pairs(peers) do n = n + 1 end
    return n
end

-- A buff's name, and the groups when the share is only some of them.
local function ShareItem(key, value)
    local buff = ns.BuffData.ByKey(key)
    local name = buff and ns.BuffData.SpellName(buff) or key
    if type(value) ~= "table" then return name end
    local from, to
    for g = 1, RaidSplit.GROUPS do
        if value[g] then
            from = from or g
            to = g
        end
    end
    if not from then return name end
    if from == to then return name .. " (group " .. from .. ")" end
    return name .. " (groups " .. from .. "-" .. to .. ")"
end

-- A share as text, in the class's own order of buffs.
local function ShareList(share)
    local class = MyClass()
    local out = {}
    for _, buff in ipairs(class and ns.BuffData.CLASSES[class] or {}) do
        if share[buff.key] then out[#out + 1] = ShareItem(buff.key, share[buff.key]) end
    end
    return table.concat(out, ", ")
end

-- "Your share: Divine Spirit", and with others, "; Ann Vale has Fortitude,
-- Cid Rock has Shadow Protection"; nil when there's no split. An empty
-- share is a backup's.
function RaidSplit.ShareText(withOthers)
    local mine, shares = RaidSplit.Current()
    if not mine then return nil end
    local text = "Your share: " .. (next(mine) and ShareList(mine) or "none, you're a backup")
    if not withOthers then return text end
    local me = Util.UnitFullName("player")
    local names = {}
    for name in pairs(shares) do
        if name ~= me then names[#names + 1] = name end
    end
    table.sort(names)
    local others = {}
    for _, name in ipairs(names) do
        others[#others + 1] = Util.DisplayName(name) .. " has "
            .. (next(shares[name]) and ShareList(shares[name]) or "nothing (a backup)")
    end
    return text .. "; " .. table.concat(others, ", ")
end

-- For /friendly status.
function RaidSplit.StatusLine()
    local text = RaidSplit.ShareText(true)
    if not text then
        local _, why = RaidSplit.Current()
        return "raid split: none (" .. tostring(why) .. ")"
    end
    return "raid split: " .. text
end
