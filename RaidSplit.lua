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

local RAID_UNITS = {}
for i = 1, 40 do RAID_UNITS[i] = "raid" .. i end

-- [full name] = { keys = { key, ... } in their order, fixed = { [key] = true } or nil }:
-- what each other copy of your class in this raid last announced.
local peers = {}
local lastSent        -- the text of our last SHARE ("keys;fixed"), or nil
local lastSentAt      -- GetTime() it went
local sendPending = false

------------------------------------------------------------------------
-- The split itself
------------------------------------------------------------------------

-- The deterministic split. players: a list of { name, keys = { key, ... }
-- in that player's buff order, fixed = { [key] = true } or nil }. Returns
-- [name] = { [key] = true }, every player's share.
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
-- not in a raid, your class or name can't be read, or nobody else of your
-- class has said they run the addon.
local function Players()
    if not InRaid() then return nil, "not in a raid" end
    local class = MyClass()
    if not class then return nil, "can't read your class" end
    local me = Util.UnitFullName("player")
    if not me then return nil, "can't read your name" end
    if next(ClassKeys(class)) == nil then return nil, "your class has no buffs to share" end
    local mine = MyEntry(class)
    local list = { { name = me, keys = mine.keys, fixed = mine.fixed, me = true } }
    local roster = Roster()
    for name, entry in pairs(peers) do
        if name ~= me and Eligible(roster, name, class) then
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
    return mine[buff.key] == true
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
    if not InRaid() or not ns.Comm.Ready() then return nil end
    local class = MyClass()
    -- A class with nothing to share (warriors) has nothing to say.
    if not class or next(ClassKeys(class)) == nil then return nil end
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
    if text == lastSent and not force then return end
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
    if not Eligible(Roster(), sender, class) then
        ns.Diag.Count("splitIgnored")
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
    peers[sender] = { keys = keys, fixed = fixed }
    Changed()
    ns.Diag.Log("split", "%s gives %s (by hand: %s)", sender, KeyText(keys), fixedText)
    -- Rate-limited (Announce): a sender asking again and again costs one
    -- message per MIN_GAP.
    if asks then RaidSplit.Announce(true) end
end

-- The roster changed (GROUP_ROSTER_UPDATE): forget everyone who left the
-- raid, and say what you give once it settles (a new member needs to hear).
function RaidSplit.OnRosterUpdate()
    Changed()
    if not InRaid() then
        peers, lastSent, lastSentAt = {}, nil, nil
        return
    end
    local roster, unreadable = Roster()
    if not unreadable then
        for name in pairs(peers) do
            if not roster[name] then peers[name] = nil end
        end
    end
    RaidSplit.Announce(true)
end

function RaidSplit.PeerCount()
    local n = 0
    for _ in pairs(peers) do n = n + 1 end
    return n
end

-- For /friendly status.
function RaidSplit.StatusLine()
    local mine, shares = RaidSplit.Current()
    if not mine then return "raid split: none (" .. tostring(shares) .. ")" end
    local names = {}
    for name in pairs(shares) do names[#names + 1] = name end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
        local keys = {}
        for key in pairs(shares[name]) do keys[#keys + 1] = key end
        table.sort(keys)
        parts[#parts + 1] = Util.DisplayName(name) .. ": " .. (#keys > 0 and table.concat(keys, ", ") or "nothing")
    end
    return "raid split: " .. table.concat(parts, "; ")
end
