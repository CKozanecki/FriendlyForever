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

-- Joining someone else's group. There is no "you joined" system message for
-- the joiner, so watch the group appear: not grouped -> grouped, with someone
-- else leading (when I lead, I invited them, and the party welcome covers it).
-- Battlegrounds put you in an instance group; no hello there.
local wasInGroup = false
local helloedLeaders = {}

function Greeter.OnEnteringWorld()
    wasInGroup = IsInGroup() and true or false
end

function Greeter.OnGroupRosterUpdate()
    local inGroup = IsInGroup() and true or false
    local joined = inGroup and not wasInGroup
    wasInGroup = inGroup
    if not joined then return end

    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        ns.Diag.Log("partyHello", "joined an instance group (battleground?); no hello")
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
    -- A group is told apart by its leader. Rejoining a leader's group this
    -- session gets a "hello again" line instead (if that type is on).
    -- One repeat timer per leader covers both types, so a rapid leave and
    -- rejoin can't follow a hello with a hello again.
    local key = Greeter.GroupLeaderName() or "unknown leader"
    local last = helloedLeaders[key]
    local msgType = "partyHello"
    if last and ns.db.partyHelloAgain.enabled then msgType = "partyHelloAgain" end
    local cooldown = ns.db[msgType].repeatCooldown
    if last and GetTime() - last < cooldown then
        ns.Diag.Log(msgType, "not sending for %s: rejoined within %ss", key, cooldown)
        return
    end
    local scheduled = ns.Announcer.Schedule(msgType, key, {
        cooldown = 0,
        channel = Greeter.GroupChannel,
        vars = function() return {} end,
        isValid = function()
            if not IsInGroup() then return false, "you left the group" end
            return true
        end,
    })
    if scheduled then helloedLeaders[key] = GetTime() end
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
        ns.Announcer.Schedule("partyJoin", name, {
            channel = Greeter.GroupChannel,
            -- Don't welcome someone who already left. If we can't tell (names
            -- restricted in combat), keep the welcome.
            isValid = function()
                if Greeter.IsInMyGroup(name) == false then
                    return false, name .. " is no longer in your group"
                end
                return true
            end,
        })
    end
end
