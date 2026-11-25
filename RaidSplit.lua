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
-- switched on (the Buffs tab's Raid place, on by default), while buff mode is on and for
-- GRACE seconds after it goes off; a copy that isn't says so once ("-").
-- Copies re-announce every HEARTBEAT seconds; one not heard for SILENT
-- seconds, or that leaves the raid or goes offline, drops out, and its
-- share goes back into the split. When there are more players than buffs,
-- priests, mages and druids holding the same buff split the raid's groups
-- 1-8; an extra paladin is a backup.
--
-- The raid leader and assistants can assign buffs by hand (#497,
-- RaidLead.lua): an assignment that can be met decides who offers that buff
-- to the groups it covers, over the split and over Blessings set by hand;
-- the split shares out the rest.
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

-- Whether you're in a raid, as far as the game's answer can be believed:
-- true or false, or nil when it can't be read or the raid's slots disagree
-- with it (GroupBuffs.RaidAnswer, #372). Only false ends the split or
-- forgets its peers; nil leaves them as they were, and offers every buff
-- while it lasts, as without the split.
local function InRaid()
    return ns.GroupBuffs.RaidAnswer()
end

-- Your class's file name ("PRIEST"), or nil when it can't be read.
local function MyClass()
    local _, class = Read(UnitClass, "player")
    if type(class) == "string" and ns.BuffData.CLASSES[class] then return class end
end

-- Whether buff is one the split shares: your class's, not cast on
-- yourself (Battle Shout reaches only your party: never shared), and not
-- one offered only when asked for (Water Walking, #350).
local function Shared(buff)
    return buff ~= nil and not buff.selfCast and not buff.requestOnly
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

-- Whether the split is switched on (the Buffs tab); damaged reads as on.
function RaidSplit.Enabled()
    local value = ns.db and type(ns.db.buffBack) == "table" and ns.db.buffBack.raidSplit
    if type(value) == "boolean" then return value end
    return ns.Config.DEFAULTS.buffBack.raidSplit
end

-- Whether you take part now: buff mode is on, or went off less than GRACE
-- seconds ago, in this raid (leaving a raid forgets it: OnRosterUpdate). A
-- copy whose buff mode hasn't been on in this raid doesn't take part. The
-- grace runs from the first time buff mode is seen off
-- (turning it off refreshes the button, which looks at once; a fight's end
-- of a trigger's buff mode is seen at the next heartbeat at the latest).
local offAt         -- GetTime() buff mode was first seen off, or nil
local everOn = false
local function TakingPart()
    local now = GetTime()
    if ns.BuffMode.IsOn() then
        everOn, offAt = true, nil
        return true
    end
    if not everOn then return false end
    offAt = offAt or now
    return now >= offAt and now - offAt < RaidSplit.GRACE
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
    local inRaid = InRaid()
    if inRaid == false then return nil, "not in a raid" end
    if inRaid == nil then return nil, "can't tell if you're in a raid" end
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

-- Whether keys (a list) has key.
local function Has(keys, key)
    for _, k in ipairs(keys) do
        if k == key then return true end
    end
    return false
end

-- The raid leader's assignments (#497, RaidLead.lua) for your class's buffs
-- that can be met now: [key] = { covered = { [g] = true }, count = how many
-- groups, by = { [name] = { [g] = true } } }. One is met when its player is
-- the one raid member with that hash, online and of your class, and gives
-- that buff: you, if it's among the buffs you offer, or a copy whose last
-- share, heard lately, names it. A player who set Blessings by hand gives
-- only those: the leader can't widen their choice. Anything else (offline,
-- gone, without the addon or the spell, or unreadable) can't be met, and
-- that buff stays with the automatic split.
local function Met(class, me, myKeys, myFixed, roster)
    local out = {}
    local items = ns.RaidLead and ns.RaidLead.Assignments() or {}
    if #items == 0 then return out end
    -- You, whether or not your own raid slot can be read: the others count
    -- you from your share, so you never read yourself as unmet when they don't.
    local names = { [me] = true }
    for name in pairs(roster) do names[name] = true end
    local byHash, clash = {}, {}
    for name in pairs(names) do
        local hash = ns.RaidLead.Hash(name)
        if byHash[hash] then clash[hash] = true end
        byHash[hash] = name
    end
    local now = GetTime()
    for _, a in ipairs(items) do
        local name = not clash[a.hash] and byHash[a.hash]
        -- (Another class's buff is never among yours, nor in a share of your class.)
        local gives = false
        if name == me then
            gives = myKeys[a.key] == true and (myFixed == nil or myFixed[a.key] == true)
        elseif name and Eligible(roster, name, class) then
            local peer = peers[name]
            gives = peer ~= nil and Fresh(peer, now) and Has(peer.keys, a.key)
                and (peer.fixed == nil or peer.fixed[a.key] == true)
        end
        if gives then
            local m = out[a.key] or { covered = {}, count = 0, by = {} }
            out[a.key] = m
            m.by[name] = m.by[name] or {}
            for g in pairs(a.groups) do
                if not m.covered[g] then m.count = m.count + 1 end
                m.covered[g] = true
                m.by[name][g] = true
            end
        end
    end
    return out
end

-- A player's list without the buffs assigned for every group: those aren't
-- drafted, so the rest share out among the others (a new list: peers'
-- entries stay as they were heard). A player who set Blessings by hand
-- still holds exactly those (Final then takes away the ones assigned to
-- others): with all of them assigned away, none. Their own copy offers
-- only what they chose (BuffRules.CoversInRaid), and the leader's choice
-- only narrows it, never widens it.
local function Strip(p, met)
    local keys = {}
    for _, key in ipairs(p.keys) do
        if not (met[key] and met[key].count == RaidSplit.GROUPS) then keys[#keys + 1] = key end
    end
    return { name = p.name, keys = keys, fixed = p.fixed, me = p.me }
end

-- A player's share of an assigned buff: the groups assigned to them, and
-- of their automatic share (auto: true for the whole raid, or groups), the
-- groups no assignment covers. Nil when that's none, true when it's all.
local function Final(auto, assigned, covered)
    local out, n = {}, 0
    local function Add(g)
        if not out[g] then
            out[g] = true
            n = n + 1
        end
    end
    for g in pairs(assigned or {}) do Add(g) end
    for g = 1, RaidSplit.GROUPS do
        if not covered[g] and (auto == true or (type(auto) == "table" and auto[g])) then Add(g) end
    end
    if n == 0 then return nil end
    if n == RaidSplit.GROUPS then return true end
    return out
end

-- The split and the assignments now: { mine, shares, split = whether the
-- automatic split runs, met = Met's, why }.
local function Compute()
    local players, why = Players()
    local c = { why = why, met = {} }
    local class, me = MyClass(), Util.UnitFullName("player")
    local myKeys = {}
    -- (Out of a raid, or while the answer can't be read, there are no assignments.)
    if class and me then
        local mine = MyEntry(class)
        for _, key in ipairs(mine.keys) do myKeys[key] = true end
        c.met = Met(class, me, myKeys, mine.fixed, Roster())
    end
    local shares
    if players then
        local list = {}
        for i, p in ipairs(players) do list[i] = Strip(p, c.met) end
        shares = RaidSplit.Split(list)
        c.split = true
    elseif next(c.met) then
        -- No split: you'd give every buff, less what's assigned to others.
        shares = { [me] = {} }
        for key in pairs(myKeys) do shares[me][key] = true end
    end
    if shares then
        for key, m in pairs(c.met) do
            for name in pairs(m.by) do shares[name] = shares[name] or {} end
            -- Without the split only your own automatic share is known: the
            -- others' shares are only their assignments.
            for name, share in pairs(shares) do share[key] = Final(share[key], m.by[name], m.covered) end
        end
        c.shares, c.mine = shares, shares[me]
    end
    return c
end

-- Your share now: { [key] = true or { [group] = true } }, and the whole
-- split ([name] = share), or nil and why there's none (you're offered
-- everything). The raid leader's assignments (#497) decide the buffs they
-- cover; the automatic split the rest. Worked out once per moment
-- (GetTime()): buff mode asks for every buff and member at each refresh.
-- Anything that changes it (a share heard, the roster, your settings, an
-- assignment) clears it.
local cache
local function Now()
    local now = GetTime()
    if not (cache and cache.at == now) then
        cache = Compute()
        cache.at = now
    end
    return cache
end

function RaidSplit.Current()
    local c = Now()
    if not c.mine then return nil, c.why end
    return c.mine, c.shares
end

local function Changed()
    cache = nil
end
RaidSplit.Changed = Changed

-- Whether a met assignment of the raid leader's (#497) decides buff.
function RaidSplit.Assigned(buff)
    return Now().met[buff.key] ~= nil
end

-- Whether buff mode may offer buff (it's yours to give in this raid): every
-- buff when there's no split, else your share (a buff the split doesn't
-- share, such as Battle Shout, is never in it; buff mode never offers those
-- to the group). Without the split, the assignments decide only the buffs
-- they cover.
function RaidSplit.Covers(buff)
    local c = Now()
    if not c.mine then return true end
    if not c.split and not c.met[buff.key] then return true end
    return c.mine[buff.key] ~= nil
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
-- and theirs isn't one, or the raid leader gave the whole buff to someone
-- else (#497). A group that can't be read is offered (the split only
-- narrows what it can tell).
function RaidSplit.CoversMember(buff, member)
    local c = Now()
    local assigned = c.met[buff.key] ~= nil
    local groups = c.mine and c.mine[buff.key]
    if assigned and groups == nil then return false, "the raid leader gave it to someone else" end
    if type(groups) ~= "table" then return true end
    local group = GroupOf(member.unit)
    if group == nil or groups[group] then return true end
    if assigned and c.met[buff.key].covered[group] then
        return false, "the raid leader gave their group to someone else"
    end
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
    if not RaidSplit.Enabled() or InRaid() ~= true or not ns.Comm.Ready() then return nil end
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

-- You're out of the raid, as far as the game's answer can be believed:
-- forget it, its peers and what you last said there, and stop the
-- heartbeat. Buff mode's grace is for this raid: the next starts afresh.
-- Run by whichever look sees it first: a leave whose one roster update
-- couldn't be read is seen by the next heartbeat (#372).
local function LeftRaid()
    peers, lastSent, lastSentAt = {}, nil, nil
    everOn, offAt = false, nil
    beatToken, beating = beatToken + 1, false
end

-- Every HEARTBEAT seconds while in a raid: say it again (so a silent copy
-- can be told from a quiet one), or say once that you no longer take part.
local function Beat(token)
    if token ~= beatToken then return end
    if InRaid() == false then
        LeftRaid()
        return
    end
    -- Can't tell (#372): the beat goes on, so the others hear you again once
    -- the answer can be read; nothing is said meanwhile (MyFields).
    Changed()
    RaidSplit.Announce(true)
    C_Timer.After(RaidSplit.HEARTBEAT, ns.Diag.Wrap(function() Beat(token) end))
end

-- Start the heartbeat unless it's running.
local function StartBeat()
    if beating then return end
    beating = true
    local token = beatToken
    C_Timer.After(RaidSplit.HEARTBEAT, ns.Diag.Wrap(function() Beat(token) end))
end

function RaidSplit.OnRosterUpdate()
    Changed()
    local inRaid = InRaid()
    if inRaid == false then
        LeftRaid()
        return
    end
    -- One update whose answer can't be read or believed (#372) ends
    -- nothing: the peers and the grace stay as they were. It may be the one
    -- update for joining a raid (#443), so the heartbeat starts if it isn't
    -- running, and its first readable answer decides: false stops it, true
    -- speaks (Beat).
    if inRaid == nil then
        StartBeat()
        return
    end
    StartBeat()
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
-- An answer that can't be read yet (#372) still asks: the message waits
-- SETTLE seconds, and goes only if you're in a raid by then (MyFields).
function RaidSplit.OnCombatEnd()
    if InRaid() ~= false then RaidSplit.Announce(true) end
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
    -- Runs of groups: an assignment can leave a gap (#497), "groups 1, 3-8".
    local runs, count, g = {}, 0, 1
    while g <= RaidSplit.GROUPS do
        if value[g] then
            local from = g
            while g < RaidSplit.GROUPS and value[g + 1] do g = g + 1 end
            runs[#runs + 1] = from == g and tostring(from) or (from .. "-" .. g)
            count = count + g - from + 1
        end
        g = g + 1
    end
    if #runs == 0 then return name end
    return name .. " (" .. (count == 1 and "group " or "groups ") .. table.concat(runs, ", ") .. ")"
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
