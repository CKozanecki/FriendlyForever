-- Guild logins, guild joins and party joins.
local _, ns = ...
local Util = ns.Util

local Greeter = {}
ns.Greeter = Greeter

-- How long an "X has come online" line may wait for a roster refresh to
-- confirm X is a guild member (the same line is used for friends).
Greeter.PENDING_TIMEOUT = 30
Greeter.MAX_PENDING = 100

local members = {}
local pendingOnline = {}
local pendingCount = 0

local function GuildChannel()
    if IsInGuild() then return "GUILD" end
end

function Greeter.GroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
end

local function IsMe(name)
    return name == Util.UnitFullName("player")
end

-- Is this full name in my group right now? Walks the actual group slots
-- and compares the names the game reports for them, so it never depends on
-- which name format a by-name query happens to accept. Returns true, false,
-- or nil when it can't tell (names are restricted, e.g. in combat).
function Greeter.IsInMyGroup(name)
    local prefix, slots = "party", 4
    if IsInRaid() then prefix, slots = "raid", 40 end
    local unreadable = false
    for i = 1, slots do
        local unit = prefix .. i
        local exists, secret = Util.Readable(UnitExists(unit))
        if secret then
            unreadable = true
        elseif exists then
            local member, nameSecret = Util.Readable(UnitName(unit))
            if nameSecret then
                unreadable = true
            elseif member and Util.UnitFullName(unit) == name then
                return true
            end
        end
    end
    if unreadable then return nil end
    return false
end

function Greeter.IsGuildMember(name)
    return members[name] == true
end

function Greeter.MemberCount()
    local n = 0
    for _ in pairs(members) do n = n + 1 end
    return n
end

function Greeter.RequestRoster()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

local function Greet(name)
    ns.Announcer.Schedule("guildLogin", name, { channel = GuildChannel })
end

local function AddPending(name, now)
    if pendingCount >= Greeter.MAX_PENDING then return end
    if not pendingOnline[name] then pendingCount = pendingCount + 1 end
    pendingOnline[name] = now
end

function Greeter.OnRosterUpdate()
    members = {}
    if IsInGuild() then
        for i = 1, GetNumGuildMembers() or 0 do
            local name = Util.FullName((GetGuildRosterInfo(i)))
            if name then members[name] = true end
        end
    end

    ns.Diag.Count("rosterUpdates")
    ns.Diag.Log("guild", "roster update: %s members known", Greeter.MemberCount())

    local now = GetTime()
    for name, t in pairs(pendingOnline) do
        if not members[name] then
            ns.Diag.Log("guildLogin", "%s is not in the guild roster (a friend?)", name)
        elseif now - t > Greeter.PENDING_TIMEOUT then
            ns.Diag.Log("guildLogin", "roster confirmed %s too late", name)
        else
            Greet(name)
        end
    end
    pendingOnline, pendingCount = {}, 0
end

-- Battlegrounds put you in an instance group, but Forever may not use the
-- instance category for them, so the zone type is checked too.
function Greeter.InBattleground()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return true end
    return select(2, IsInInstance()) == "pvp"
end

-- Joining someone else's group. There is no "you joined" system message for
-- the joiner, so watch the group appear: not grouped -> grouped, with someone
-- else leading (when I lead, I invited them, and the party welcome covers it).
-- No hello in battlegrounds.
local wasInGroup = false
local helloedLeaders = {}
local groupChanges = 0 -- bumped on every join and leave, so a stale hello timer can tell

-- Party to raid conversion: the game may announce everyone already in the
-- party as joining the raid. Remember who was in the party just before.
Greeter.CONVERT_WINDOW = 10 -- seconds after a conversion that those names are ignored
local wasInRaid = false
local partyMembers = {}
local convertedMembers, convertedAt = {}, nil

local function PartyNames()
    local names = {}
    for i = 1, 4 do
        local name = Util.UnitFullName("party" .. i)
        if name then names[name] = true end
    end
    return names
end

local function TrackConversion(inGroup, wasGrouped)
    local inRaid = IsInRaid() and true or false
    if inRaid and not wasInRaid and inGroup and wasGrouped then
        convertedMembers, convertedAt = partyMembers, GetTime()
        ns.Diag.Log("partyJoin", "party became a raid; not welcoming its members again")
    end
    wasInRaid = inRaid
    partyMembers = (inGroup and not inRaid) and PartyNames() or {}
end

function Greeter.OnEnteringWorld()
    wasInGroup = IsInGroup() and true or false
    wasInRaid = IsInRaid() and true or false
    partyMembers = (wasInGroup and not wasInRaid) and PartyNames() or {}
end

local function HelloOpts(delay)
    return {
        cooldown = 0,
        delay = delay,
        channel = Greeter.GroupChannel,
        vars = function() return {} end,
        isValid = function()
            if not IsInGroup() then return false, "you left the group" end
            return true
        end,
    }
end

-- Runs once the Party Hello delay is over, when the leader is more likely to
-- be readable than on the roster update that showed the group.
local function SayHello()
    local key = Greeter.GroupLeaderName()
    if not key then
        -- Without a leader this group can't be told from any other: a plain
        -- hello, and nothing remembered for "hello again".
        ns.Announcer.Schedule("partyHello", "unknown leader", HelloOpts(0))
        return
    end
    -- A group is told apart by its leader. Rejoining a leader's group this
    -- session gets a "hello again" line instead (if that type is on).
    -- One repeat timer per leader covers both types, so a rapid leave and
    -- rejoin can't follow a hello with a hello again.
    local last = helloedLeaders[key]
    local msgType = "partyHello"
    if last and ns.db.partyHelloAgain.enabled then msgType = "partyHelloAgain" end
    local cooldown = ns.db[msgType].repeatCooldown
    if last and GetTime() - last < cooldown then
        ns.Diag.Log(msgType, "not sending for %s: rejoined within %ss", key, cooldown)
        return
    end
    -- Party Hello's delay has passed already; Hello Again waits out the rest of its own.
    local delay = 0
    if msgType == "partyHelloAgain" then
        delay = math.max(0, ns.db.partyHelloAgain.delay - ns.db.partyHello.delay)
    end
    if ns.Announcer.Schedule(msgType, key, HelloOpts(delay)) then helloedLeaders[key] = GetTime() end
end

function Greeter.OnGroupRosterUpdate()
    local inGroup = IsInGroup() and true or false
    local wasGrouped = wasInGroup
    local joined = inGroup and not wasGrouped
    if inGroup ~= wasGrouped then groupChanges = groupChanges + 1 end
    wasInGroup = inGroup
    TrackConversion(inGroup, wasGrouped)
    if not joined then return end

    if Greeter.InBattleground() then
        ns.Diag.Log("partyHello", "joined a battleground group; no hello")
        return
    end
    local leader, secret = Util.Readable(UnitIsGroupLeader("player"))
    if secret then
        ns.Diag.Log("partyHello", "joined a group but can't tell who leads it; no hello")
        return
    end
    if leader then
        ns.Diag.Log("partyHello", "formed a group I lead (someone accepted my invite); no hello")
        return
    end
    if not ns.Announcer.IsActive() then
        ns.Diag.Log("partyHello", "joined a group; no hello: %s", ns.Announcer.ActiveState())
        return
    end
    -- Hello or hello again is decided after the delay (see SayHello).
    local change = groupChanges
    C_Timer.After(ns.db.partyHello.delay, ns.Diag.Wrap(function()
        if change ~= groupChanges then
            ns.Diag.Log("partyHello", "no hello: you left or changed group before the delay ran out")
            return
        end
        SayHello()
    end))
end

-- Full name of whoever leads my group, or nil if no slot can be read.
function Greeter.GroupLeaderName()
    local prefix, slots = "party", 4
    if IsInRaid() then prefix, slots = "raid", 40 end
    for i = 1, slots do
        local unit = prefix .. i
        local leads = Util.Readable(UnitIsGroupLeader(unit))
        if leads then
            local name = Util.UnitFullName(unit)
            if name then return name end
        end
    end
end

-- Joins that arrive close together share one welcome ("Welcome, A, B and
-- C!") instead of a line each. The welcome goes out this long after the
-- first joiner (or after the Party Join delay, if that is longer), and
-- everyone who joins before it is sent is added to it. {name} and {fullname}
-- then list all of them, so every template still reads.
-- A party fills with a few quick invites: 3s is one second more than the
-- default 2s delay. A forming raid takes invites in longer waves.
Greeter.PARTY_MERGE_WINDOW = 3
Greeter.RAID_MERGE_WINDOW = 5

local joinBatch -- { names = {} } for the merged welcome waiting to go out

-- Don't welcome someone who already left. If we can't tell (names
-- restricted in combat), keep the welcome.
local function StillInGroup(name)
    return Greeter.IsInMyGroup(name) ~= false
end

local function WelcomeJoin(name)
    local cfg = ns.db.partyJoin
    if convertedAt and GetTime() - convertedAt <= Greeter.CONVERT_WINDOW and convertedMembers[name] then
        ns.Diag.Log("partyJoin", "not welcoming %s: was already in the party before it became a raid", name)
        return
    end
    local batch = joinBatch
    if batch then
        for _, n in ipairs(batch.names) do
            if n == name then return end
        end
        -- The same per-player repeat cooldown as a welcome of their own.
        if not ns.Cooldowns.TryClaim("partyJoin:" .. name, cfg.repeatCooldown, GetTime()) then
            ns.Diag.Log("partyJoin", "not sending for %s: repeat cooldown (%ss) still running",
                name, cfg.repeatCooldown)
            return
        end
        batch.names[#batch.names + 1] = name
        ns.Diag.Log("partyJoin", "added %s to the welcome already waiting", name)
        return
    end

    batch = { names = { name } }
    joinBatch = batch
    local function Present()
        local present = {}
        for _, n in ipairs(batch.names) do
            if StillInGroup(n) then present[#present + 1] = n end
        end
        return present
    end
    local scheduled = ns.Announcer.Schedule("partyJoin", name, {
        delay = math.max(cfg.delay, IsInRaid() and Greeter.RAID_MERGE_WINDOW or Greeter.PARTY_MERGE_WINDOW),
        channel = Greeter.GroupChannel,
        vars = function()
            local first, full = {}, {}
            for i, n in ipairs(Present()) do
                first[i], full[i] = Util.FirstName(n), Util.DisplayName(n)
            end
            return { name = Util.JoinList(first), fullname = Util.JoinList(full) }
        end,
        isValid = function()
            if #Present() == 0 then
                local verb = #batch.names > 1 and " are" or " is"
                return false, Util.JoinList(batch.names) .. verb .. " no longer in your group"
            end
            return true
        end,
        onDone = function()
            if joinBatch == batch then joinBatch = nil end
        end,
    })
    if not scheduled then joinBatch = nil end
end

function Greeter.OnSystemMessage(msg)
    ns.Diag.Count("systemMessages")
    local kind, name = ns.Parser.Parse(msg)
    if kind then ns.Diag.Count("systemMatched") end
    ns.Diag.Log("system", "%s -> %s %s", msg, kind or "not recognised", name or "")

    if not ns.Announcer.IsActive() then
        if kind then ns.Diag.Log(kind, "ignored: %s", ns.Announcer.ActiveState()) end
        return
    end
    if not kind then return end
    if kind == "whisperFailed" then
        ns.BuffTracker.OnWhisperFailed(name)
        return
    end
    if IsMe(name) then return end

    if kind == "guildOnline" then
        if not IsInGuild() then
            ns.Diag.Log("guildLogin", "ignored %s: you are not in a guild", name)
            return
        end
        if members[name] then
            Greet(name)
        else
            ns.Diag.Log("guildLogin", "%s not in cached roster yet; asking the game for a fresh roster", name)
            AddPending(name, GetTime())
            Greeter.RequestRoster()
        end
    elseif kind == "guildJoin" then
        members[name] = true
        ns.Announcer.Schedule("guildJoin", name, { channel = GuildChannel })
    elseif kind == "partyJoin" then
        -- Every joiner would be welcomed, by every addon user, in /bg.
        if Greeter.InBattleground() then
            ns.Diag.Log("partyJoin", "not welcoming %s: you're in a battleground", name)
            return
        end
        WelcomeJoin(name)
    end
end
