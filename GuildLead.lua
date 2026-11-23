-- Guild leader controls (#496), part 1: the shared memory and how copies
-- keep it in step. Each copy in a guild keeps the guild's settings in its
-- saved settings, per guild, in three versioned sections (Versioned.lua):
--
-- - ranks: the rank indexes, besides the guild master's, whose members
--   lead (decision 1). Only the guild master sets it;
-- - caps: the most greeters per guildmate login, the most welcomes per new
--   member, and guild hellos off (decision 2). A guild leader sets it;
-- - vetoes: lines no copy may say again, built-in ones by ID, custom ones
--   by a hash of their exact text (decision 4). A guild leader sets it.
--
-- The safety rule (owner, 18 Nov): another player can only make someone's
-- addon quieter or narrower, never make it say new text or cast. Every item
-- is a short token from a fixed grammar, never text a copy would say, and
-- every one only limits. A player's own lower setting always stays.
--
-- Who leads is never read from a message. The game vouches for who sent
-- it, and the sender's rank index is looked up in the guild roster as last
-- read (Greeter.MemberRank) for every message: 0 is the guild master, and a
-- rank in the ranks section leads too. An unreadable roster, rank or guild
-- means nobody leads, and nothing is taken (fail closed).
--
-- Keeping in step (decision 5): each copy sends a quiet check-in to the
-- guild (GCHECK) after logging in and every CHECKIN_EVERY seconds, with its
-- addon version and the version of each section it keeps. A leader's copy
-- that keeps a newer section sends it to the guild after a random wait,
-- unless another leader's copy sends it first, and at most once per
-- SEND_GAP. So a copy that was offline catches up from any online leader's
-- copy, the rank check repeated as each part arrives. A copy never takes a
-- section from a copy that doesn't lead: it couldn't tell a relayed list
-- from a forged one.
--
-- Versions are numbers, never times read from a message: a leader's edit
-- takes the server's clock in seconds, or one more than the version kept
-- if that is higher, so a leader who reinstalls still moves the guild on.
-- The clock is only a floor; the order never depends on it.
--
-- The check-ins also say who in the guild has the addon, its version and
-- when they were last seen (decision 3): kept per guild, at most MAX_MATES.
local _, ns = ...
local Util = ns.Util
local Comm = ns.Comm
local Versioned = ns.Versioned

local GuildLead = {}
ns.GuildLead = GuildLead

GuildLead.MAX_GUILDS = 10   -- guilds whose memory is kept: the one used longest ago goes first
GuildLead.MAX_KEY = 120     -- a guild's key: a realm, ":" and the guild's name
GuildLead.MAX_MATES = 500   -- guildmates with the addon kept per guild: the one seen longest ago goes first
GuildLead.MAX_VETOES = 40
GuildLead.CAP_MAX = 20      -- the highest cap a leader may set (Config.LIMITS.maxGreeters.max)

GuildLead.CHECKIN_WAIT_MIN = 5  -- seconds after the first roster update before checking in, at random
GuildLead.CHECKIN_WAIT_MAX = 20
GuildLead.CHECKIN_EVERY = 900   -- seconds between check-ins after that
GuildLead.CHECKIN_GAP = 60      -- the shortest time between two of our check-ins
GuildLead.SEND_WAIT_MIN = 2     -- seconds a leader's copy waits, at random, before sending a newer section
GuildLead.SEND_WAIT_MAX = 10
GuildLead.SEND_GAP = 60         -- the shortest time between two sends of one section to catch others up
GuildLead.EDIT_WAIT = 2         -- seconds an edit waits before going out, so quick edits go as one

-- Overridable so tests can make the waits deterministic: () -> [0, 1).
GuildLead.random = math.random

local SECTIONS = {}
GuildLead.ORDER = { "ranks", "caps", "vetoes" }

------------------------------------------------------------------------
-- Items
------------------------------------------------------------------------

-- A rank index that leads, besides the guild master's 0.
local function RankItem(text)
    return text:find("^[1-9]$") ~= nil
end

-- "g<n>": the most greeters per guildmate login; "w<n>": the most welcomes
-- per new member, n from 1 to CAP_MAX; "h0": no guild hellos at all.
local function CapItem(text)
    if text == "h0" then return true end
    local n = text:match("^[gw]([1-9]%d?)$")
    return n ~= nil and tonumber(n) <= GuildLead.CAP_MAX
end

-- Each cap at most once.
local function CapsTogether(items)
    local kinds = {}
    for _, item in ipairs(items) do
        local kind = item:sub(1, 1)
        if kinds[kind] then return false end
        kinds[kind] = true
    end
    return true
end

-- A built-in line, "b" + its type (l: guild login, j: guild join) + its
-- set (d: the shipped lines, c: the casual ones) + its number, 1 to 99; or
-- a custom line, "c" + eight lower-case hex digits: a hash of its exact text.
local function VetoItem(text)
    if text:find("^b[lj][dc][1-9]%d?$") then return true end
    return #text == 9 and text:find("^c[0-9a-f]+$") ~= nil
end

------------------------------------------------------------------------
-- The guild, its leaders and the clock
------------------------------------------------------------------------

-- This guild's key, "realm:Guild Name", or nil out of a guild, or while
-- the game won't say which (a secret, or not loaded yet).
local function GuildKey()
    if Util.ReadGameValues(IsInGuild) ~= true then return nil end
    local name = Util.ReadGameValues(GetGuildInfo, "player")
    local realm = Util.ReadGameValues(GetRealmName)
    if type(name) ~= "string" or name == "" or type(realm) ~= "string" or realm == "" then return nil end
    local key = realm .. ":" .. name
    if #key > GuildLead.MAX_KEY then return nil end
    return key
end
GuildLead.Key = GuildKey

-- Seconds on the server's clock (or yours, when it can't be read), as a
-- whole number, or 0 when neither can be.
local function Clock()
    local function Plain(now)
        return type(now) == "number" and now == now and now >= 1 and now <= Versioned.MAX_VERSION
    end
    local now = Util.ReadGameValues(GetServerTime)
    if not Plain(now) then now = Util.ReadGameValues(time) end
    if not Plain(now) then return 0 end
    return math.floor(now)
end

-- A guildmate's rank index from the roster as last read: 0 is the guild
-- master. Nil out of a guild, or when it can't be told.
function GuildLead.Rank(name)
    if type(name) ~= "string" or not GuildKey() then return nil end
    return ns.Greeter.MemberRank(name)
end

function GuildLead.IsGuildMaster(name)
    return GuildLead.Rank(name) == 0
end

------------------------------------------------------------------------
-- The memory
------------------------------------------------------------------------

local function Fresh()
    return { version = 0, items = {} }
end

-- A section as kept, or a fresh one in its place when it isn't one the
-- section's checks accept (a damaged file, or a bad /run mid-session).
local function CheckedSection(g, name)
    local section = g[name]
    local version = type(section) == "table" and section.version
    if type(version) ~= "number" or version ~= math.floor(version) or version < 0 or version > Versioned.MAX_VERSION
        or not Versioned.ValidList(SECTIONS[name], section.items) or (version == 0 and #section.items > 0) then
        section = Fresh()
        g[name] = section
    end
    return section
end

-- A guildmate seen with the addon: { version = its version or "?", seen = the clock then }.
local function ValidMate(name, mate)
    if type(name) ~= "string" or Util.FullName(name) ~= name or type(mate) ~= "table" then return false end
    if type(mate.version) ~= "string" or not Comm.Field.Version(mate.version) then return false end
    local seen = mate.seen
    return type(seen) == "number" and seen == math.floor(seen) and seen >= 0 and seen <= Versioned.MAX_VERSION
end

-- The MAX_MATES seen most recently, each checked.
local function CheckedMates(mates)
    local list = {}
    if type(mates) == "table" then
        for name, mate in pairs(mates) do
            if ValidMate(name, mate) then
                list[#list + 1] = { name = name, version = mate.version, seen = mate.seen }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.seen ~= b.seen then return a.seen > b.seen end
        return a.name < b.name
    end)
    local out = {}
    for i = 1, math.min(#list, GuildLead.MAX_MATES) do
        out[list[i].name] = { version = list[i].version, seen = list[i].seen }
    end
    return out
end

local function CheckedGuild(g)
    local out = { mates = CheckedMates(g.mates) }
    out.used = Util.ClampNumber(g.used, 0, Versioned.MAX_VERSION, 0)
    for _, name in ipairs(GuildLead.ORDER) do
        out[name] = g[name]
        CheckedSection(out, name)
    end
    return out
end

-- Check the saved memory (Config.ValidateSettings): every guild's sections
-- and guildmates, at most MAX_GUILDS guilds, the ones used most recently.
-- Anything damaged starts afresh, at version 0, and catches up again.
function GuildLead.Validate(db)
    local list = {}
    if type(db.guilds) == "table" then
        for key, g in pairs(db.guilds) do
            if type(key) == "string" and key ~= "" and #key <= GuildLead.MAX_KEY and type(g) == "table" then
                list[#list + 1] = { key = key, g = CheckedGuild(g) }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.g.used ~= b.g.used then return a.g.used > b.g.used end
        return a.key < b.key
    end)
    local out = {}
    for i = 1, math.min(#list, GuildLead.MAX_GUILDS) do out[list[i].key] = list[i].g end
    db.guilds = out
end

-- The memory of the guild you're in now, made when it's new, or nil out of
-- a guild or while the game won't say which.
function GuildLead.Memory()
    local key = GuildKey()
    if not key or type(ns.db) ~= "table" then return nil end
    if type(ns.db.guilds) ~= "table" then ns.db.guilds = {} end
    local guilds = ns.db.guilds
    local g = guilds[key]
    if type(g) ~= "table" then
        -- Room for it: forget the guild used longest ago.
        local count, oldest = 0, nil
        for other, og in pairs(guilds) do
            count = count + 1
            local used = type(og) == "table" and type(og.used) == "number" and og.used or 0
            if not oldest or used < oldest.used or (used == oldest.used and other < oldest.key) then
                oldest = { key = other, used = used }
            end
        end
        if count >= GuildLead.MAX_GUILDS and oldest then guilds[oldest.key] = nil end
        g = { mates = {}, used = Clock() }
        guilds[key] = g
    end
    if type(g.mates) ~= "table" then g.mates = {} end
    for _, name in ipairs(GuildLead.ORDER) do CheckedSection(g, name) end
    return g
end

-- A copy of one section's items in the guild you're in now ({} out of one).
function GuildLead.Items(name)
    local g = SECTIONS[name] and GuildLead.Memory()
    local out = {}
    if g then
        for i, item in ipairs(g[name].items) do out[i] = item end
    end
    return out
end

function GuildLead.Version(name)
    local g = SECTIONS[name] and GuildLead.Memory()
    return g and g[name].version or 0
end

-- Whether this player leads the guild you're in now: its guild master, or
-- of a rank the guild master picked. False whenever it can't be told.
function GuildLead.IsLeader(name)
    local rank = GuildLead.Rank(name)
    if rank == nil then return false end
    if rank == 0 then return true end
    local g = GuildLead.Memory()
    if not g then return false end
    for _, item in ipairs(g.ranks.items) do
        if tonumber(item) == rank then return true end
    end
    return false
end

-- The guild's caps now: { greeters = n or nil, welcomes = n or nil,
-- hellos = false when guild hellos are off }. Nil fields don't limit.
function GuildLead.Caps()
    local caps = { hellos = true }
    for _, item in ipairs(GuildLead.Items("caps")) do
        local kind, n = item:sub(1, 1), tonumber(item:sub(2))
        if kind == "g" then caps.greeters = n elseif kind == "w" then caps.welcomes = n else caps.hellos = false end
    end
    return caps
end

function GuildLead.IsVetoed(token)
    for _, item in ipairs(GuildLead.Items("vetoes")) do
        if item == token then return true end
    end
    return false
end

-- A copy of the guildmates seen with the addon: [full name] = { version, seen }.
function GuildLead.Mates()
    local g = GuildLead.Memory()
    return g and Util.DeepCopy(g.mates) or {}
end

-- Whether this player may set the section now.
local function Entitled(name, who)
    if name == "ranks" then return GuildLead.IsGuildMaster(who) end
    return GuildLead.IsLeader(who)
end

------------------------------------------------------------------------
-- Sending sections
------------------------------------------------------------------------

local pending = {}  -- [section] = { key, version, encoded }: a send waiting
local lastSent = {} -- [section] = GetTime() of our last send

local function Wait(min, max)
    return min + GuildLead.random() * (max - min)
end

local function SendNow(name, p)
    if pending[name] ~= p then return end -- cancelled, or replaced
    pending[name] = nil
    -- The guild, or who leads it, may have changed while it waited.
    local me = Util.UnitFullName("player")
    if GuildKey() ~= p.key or not me or not Entitled(name, me) then return end
    lastSent[name] = GetTime()
    local ok, why = SECTIONS[name].Send()
    ns.Diag.Log("sync", "sent %s: %s", name, ok and "queued" or why)
end

-- Send this section to the guild after wait seconds, unless one is already
-- waiting; a catch-up send (not an edit) waits out SEND_GAP since the last.
local function ScheduleSend(name, wait, edit)
    if pending[name] then return end
    local key = GuildKey()
    local g = GuildLead.Memory()
    if not key or not g or g[name].version < 1 then return end
    local now = GetTime()
    local last = lastSent[name]
    if not edit and last and now >= last then wait = math.max(wait, last + GuildLead.SEND_GAP - now) end
    local p = { key = key, version = g[name].version, encoded = Versioned.Encode(g[name].items) }
    pending[name] = p
    C_Timer.After(wait, ns.Diag.Wrap(function() SendNow(name, p) end))
end

-- A whole section another leader's copy sent: if it is at least what ours
-- would send, ours isn't needed.
local function Heard(name, version, encoded)
    local p = pending[name]
    if p and not Versioned.Newer(p.version, p.encoded, version, encoded) then
        pending[name] = nil
        ns.Diag.Log("sync", "leaving %s to another leader's copy", name)
    end
end

-- Set a section of the guild you lead (the leader's panel, #496 part 2).
-- items: a list of tokens. Returns true, or false and why.
function GuildLead.Set(name, items)
    local spec = SECTIONS[name]
    if not spec then return false, "no such setting" end
    local me = Util.UnitFullName("player")
    if not me or not Entitled(name, me) then return false, "only a guild leader can" end
    local g = GuildLead.Memory()
    if not g then return false, "not in a guild" end
    if type(items) ~= "table" then return false, "not a list" end
    local list = {}
    for i, item in ipairs(items) do list[i] = item end
    if not Versioned.ValidList(spec, list) then return false, "not a setting a leader can make" end
    table.sort(list)
    local kept = g[name]
    if Versioned.Encode(list) == Versioned.Encode(kept.items) then return true end
    local version = math.max(Clock(), kept.version + 1)
    if version > Versioned.MAX_VERSION then return false, "can't be changed any more" end
    g[name] = { version = version, items = list }
    pending[name] = nil
    ScheduleSend(name, GuildLead.EDIT_WAIT, true)
    ns.Diag.Log("sync", "set %s to version %s", name, version)
    return true
end

local ScheduleCheckIn -- below

local function Define(name, spec)
    spec.route = "GUILD"
    spec.authority = function(sender) return Entitled(name, sender) end
    spec.get = function()
        local g = GuildLead.Memory()
        return g and g[name]
    end
    spec.set = function(version, items)
        local g = GuildLead.Memory()
        if not g then return end
        g[name] = { version = version, items = items }
        -- Who leads may have changed, so lists refused a moment ago (from a
        -- leader not known as one yet) may be taken now: check in again.
        if name == "ranks" then ScheduleCheckIn(Wait(GuildLead.SEND_WAIT_MIN, GuildLead.SEND_WAIT_MAX)) end
    end
    spec.heard = function(version, encoded) Heard(name, version, encoded) end
    SECTIONS[name] = Versioned.Define(spec)
end

-- After an update and a /reload without a restart, Comm or Versioned may be
-- missing: the addon then stays inert (Core.lua), so nothing is registered.
local loaded = Comm ~= nil and Versioned ~= nil
if loaded then
    Define("ranks", { type = "GRANKS", item = RankItem, itemBytes = 1, maxItems = 9 })
    Define("caps", { type = "GCAPS", item = CapItem, itemBytes = 3, whole = CapsTogether, maxItems = 3 })
    Define("vetoes", { type = "GVETO", item = VetoItem, itemBytes = 9, maxItems = GuildLead.MAX_VETOES })
end
GuildLead.SECTIONS = SECTIONS

------------------------------------------------------------------------
-- Check-ins
------------------------------------------------------------------------

local checkInPending -- a check-in waiting to go
local lastCheckIn    -- GetTime() of our last one
local checkedKey     -- the guild we last started checking in to
local periodic = false

local function MyVersion()
    local v = ns.VERSION
    if type(v) == "string" and Comm.Field.Version(v) then return v end
    return "?"
end

local function Stamp(version)
    return string.format("%.0f", version)
end

-- Send a check-in to the guild now. Returns true when it was queued.
function GuildLead.CheckIn()
    local g = GuildLead.Memory()
    if not g then return false end
    g.used = Clock()
    lastCheckIn = GetTime()
    local fields = { MyVersion() }
    for i, name in ipairs(GuildLead.ORDER) do fields[i + 1] = Stamp(g[name].version) end
    return Comm.Send("GCHECK", fields, "GUILD")
end

function ScheduleCheckIn(wait)
    if checkInPending then return end
    local now = GetTime()
    if lastCheckIn and now >= lastCheckIn then wait = math.max(wait, lastCheckIn + GuildLead.CHECKIN_GAP - now) end
    local token = {}
    checkInPending = token
    C_Timer.After(wait, ns.Diag.Wrap(function()
        if checkInPending ~= token then return end
        checkInPending = nil
        GuildLead.CheckIn()
    end))
end

local function Periodic()
    ScheduleCheckIn(0)
    C_Timer.After(GuildLead.CHECKIN_EVERY, ns.Diag.Wrap(Periodic))
end

-- After each roster update (Core.lua): in a guild we haven't checked in to
-- since logging in, check in after a random wait.
function GuildLead.OnRosterUpdate()
    local key = GuildKey()
    if not key or key == checkedKey then return end
    checkedKey = key
    ScheduleCheckIn(Wait(GuildLead.CHECKIN_WAIT_MIN, GuildLead.CHECKIN_WAIT_MAX))
    if not periodic then
        periodic = true
        C_Timer.After(GuildLead.CHECKIN_EVERY, ns.Diag.Wrap(Periodic))
    end
end

local function RecordMate(g, sender, version)
    local mates = g.mates
    if not mates[sender] then
        local count, oldest = 0, nil
        for name, mate in pairs(mates) do
            count = count + 1
            local seen = type(mate) == "table" and type(mate.seen) == "number" and mate.seen or 0
            if not oldest or seen < oldest.seen or (seen == oldest.seen and name < oldest.name) then
                oldest = { name = name, seen = seen }
            end
        end
        if count >= GuildLead.MAX_MATES and oldest then mates[oldest.name] = nil end
    end
    mates[sender] = { version = version, seen = Clock() }
end

local function OnCheckIn(sender, fields)
    local g = GuildLead.Memory()
    if not g then return end
    if not ns.Greeter.IsGuildMember(sender) then
        ns.Diag.Count("syncNotMember")
        return ns.Diag.Log("sync", "a check-in from %s, who isn't in the roster", sender)
    end
    RecordMate(g, sender, fields[1])
    for i, name in ipairs(GuildLead.ORDER) do
        local theirs, mine = tonumber(fields[i + 1]), g[name].version
        -- Theirs is older: catch them up, if we may send ours (SendNow checks).
        if mine > theirs then
            ScheduleSend(name, Wait(GuildLead.SEND_WAIT_MIN, GuildLead.SEND_WAIT_MAX))
        end
        -- Theirs is newer, and they may send it: our check-in asks for it.
        if theirs > mine and Entitled(name, sender) then
            ScheduleCheckIn(Wait(GuildLead.SEND_WAIT_MIN, GuildLead.SEND_WAIT_MAX))
        end
    end
end

-- GCHECK: our addon version and the version of each section we keep ("0":
-- none). It can only record the sender as having the addon, ask a
-- leader's copy to send what it keeps, or prompt our own check-in.
if loaded then
    Comm.RegisterType("GCHECK", {
        fields = { Comm.Field.Version, Versioned.StampField, Versioned.StampField, Versioned.StampField },
        routes = { GUILD = true },
        handler = OnCheckIn,
    })
end
