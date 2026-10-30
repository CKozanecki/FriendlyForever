-- The hidden channel between copies of Friendly Forever (#32). Copies talk
-- with addon messages, which players never see, over the game's own
-- WHISPER, PARTY, RAID, INSTANCE_CHAT and GUILD routes. No chat channel is
-- ever joined, so General, Trade and LocalDefense keep their numbers.
--
-- Every incoming message is untrusted input from another player. It is
-- dropped, and counted for /friendly status, unless it passes every check:
-- readable (not a secret), our prefix, at most MAX_BYTES, within the
-- flood limits, our protocol version, a known type on a route that type
-- accepts, sent by the player it is about, and fields that each pass their
-- type's check. A message can only tell this copy a fact; handlers never
-- cast, send chat or change settings.
--
-- Sending goes through our own limiter, kept well below the game's
-- per-prefix throttle, and a short, bounded queue: messages are dropped
-- rather than queued without limit. Every send may fail (lockdown, the
-- game's throttle, an instance that blocks addon messages), and every
-- feature that uses the channel must work without it.
--
-- Wire format: version;TYPE;subject;field;... where subject is the
-- sender's own full name ("First-Surname").
local _, ns = ...
local Util = ns.Util

local Comm = {}
ns.Comm = Comm

Comm.PREFIX = "FriendlyFvr" -- the game allows 16 characters
Comm.VERSION = 1            -- protocol version: bump it when a message's layout changes
Comm.DELIM = ";"
Comm.MAX_BYTES = 255        -- the game's limit for one addon message
Comm.MAX_FIELDS = 8         -- fields after version, type and subject

-- Outgoing: a burst of SEND_BURST, then one every SEND_REFILL seconds:
-- half the game's default (10, then one a second). At most MAX_QUEUE
-- messages wait, each for at most MAX_QUEUE_AGE seconds.
Comm.SEND_BURST = 5
Comm.SEND_REFILL = 2
Comm.MAX_QUEUE = 8
Comm.MAX_QUEUE_AGE = 10

-- Incoming: per sender, a burst of PEER_BURST then one every PEER_REFILL
-- seconds; from everyone together, a burst of ALL_BURST then one every
-- ALL_REFILL seconds. At most MAX_SENDERS senders are tracked.
Comm.PEER_BURST = 6
Comm.PEER_REFILL = 1
Comm.ALL_BURST = 40
Comm.ALL_REFILL = 0.1
Comm.MAX_SENDERS = 200

-- Other copies seen: at most MAX_PEERS, forgotten after PEER_TTL seconds.
-- A whispered HELLO is answered at most once per player per REPLY_GAP.
Comm.MAX_PEERS = 200
Comm.PEER_TTL = 1800
Comm.REPLY_GAP = 300

Comm.ROUTES = { WHISPER = true, PARTY = true, RAID = true, INSTANCE_CHAT = true, GUILD = true }
local ALL_ROUTES = Comm.ROUTES

local registered = false
local types = {}

------------------------------------------------------------------------
-- Rate limiting
------------------------------------------------------------------------

-- A token bucket. A clock that goes backwards refills nothing, and one
-- that jumps forwards refills at most to the burst.
local function NewBucket(burst, now)
    return { tokens = burst, at = now }
end

local function Refill(bucket, burst, refill, now)
    local elapsed = now - bucket.at
    if elapsed > 0 then bucket.tokens = math.min(burst, bucket.tokens + elapsed / refill) end
    bucket.at = now
end

local function Take(bucket, burst, refill, now)
    Refill(bucket, burst, refill, now)
    if bucket.tokens >= 1 then
        bucket.tokens = bucket.tokens - 1
        return true
    end
    return false
end

local sendBucket = NewBucket(Comm.SEND_BURST, 0)
local allBucket = NewBucket(Comm.ALL_BURST, 0)
local senders, senderCount = {}, 0

-- Make room for new senders: forget those whose bucket has refilled (they
-- would start full anyway).
local function ForgetIdleSenders(now)
    for name, bucket in pairs(senders) do
        Refill(bucket, Comm.PEER_BURST, Comm.PEER_REFILL, now)
        if bucket.tokens >= Comm.PEER_BURST then
            senders[name] = nil
            senderCount = senderCount - 1
        end
    end
end

-- Per sender first, so one flooding player can't use up everyone's share.
-- When MAX_SENDERS are all busy, a new sender waits: forgetting a busy one
-- would hand a flooder a fresh allowance.
local function AllowIncoming(name, now)
    local bucket = senders[name]
    if not bucket then
        if senderCount >= Comm.MAX_SENDERS then ForgetIdleSenders(now) end
        if senderCount >= Comm.MAX_SENDERS then return false end
        bucket = NewBucket(Comm.PEER_BURST, now)
        senders[name] = bucket
        senderCount = senderCount + 1
    end
    if not Take(bucket, Comm.PEER_BURST, Comm.PEER_REFILL, now) then return false end
    return Take(allBucket, Comm.ALL_BURST, Comm.ALL_REFILL, now)
end

-- How many senders' limits are being kept (at most MAX_SENDERS).
function Comm.TrackedSenders()
    local n = 0
    for _ in pairs(senders) do n = n + 1 end
    return n
end

------------------------------------------------------------------------
-- Message types
------------------------------------------------------------------------

-- Field checks, for RegisterType. Each takes the field's text.
Comm.Field = {}

-- An addon version such as "0.8.0", or "?" when unknown.
function Comm.Field.Version(text)
    return text == "?" or (#text <= 16 and text:find("^%d+%.%d+%.%d+$") ~= nil)
end

function Comm.Field.Flag(text)
    return text == "0" or text == "1"
end

-- A short key such as a buff key: letters, digits and underscores.
function Comm.Field.Key(text)
    return #text >= 1 and #text <= 24 and text:find("^[%w_]+$") ~= nil
end

-- "-" (none), or one to MAX_KEYS keys joined by commas.
Comm.MAX_KEYS = 8
function Comm.Field.KeyList(text)
    if text == "-" then return true end
    local n = 0
    for key in (text .. ","):gmatch("([^,]*),") do
        n = n + 1
        if n > Comm.MAX_KEYS or not Comm.Field.Key(key) then return false end
    end
    return true
end

-- spec = {
--   fields = { check, ... }: exactly this many fields, each passing its check;
--   routes = { WHISPER = true, ... }: the routes it may arrive and be sent on;
--   handler = function(sender, fields, route): sender is the full name.
-- }
-- Handlers only record what they're told. They must never cast, send chat
-- or change saved settings.
function Comm.RegisterType(name, spec)
    assert(type(name) == "string" and name:find("^%u+$") and #name <= 12, "Comm: bad message type name")
    assert(#spec.fields <= Comm.MAX_FIELDS, "Comm: too many fields")
    assert(type(spec.handler) == "function", "Comm: a type needs a handler")
    for route in pairs(spec.routes) do assert(ALL_ROUTES[route], "Comm: unknown route " .. tostring(route)) end
    types[name] = spec
end

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

-- Register our prefix. Without it, or without the API, the channel stays
-- closed and every feature behaves as it does without other copies.
function Comm.Init()
    local info = C_ChatInfo
    if not (info and info.RegisterAddonMessagePrefix and info.SendAddonMessage) then
        ns.Diag.Log("comm", "this game client has no addon messages")
        return
    end
    local ok, result = pcall(info.RegisterAddonMessagePrefix, Comm.PREFIX)
    -- Each case is its own branch: a secret answer must never be tested.
    if not ok then return ns.Diag.Log("comm", "couldn't register the prefix: error") end
    if Util.IsSecret(result) then return ns.Diag.Log("comm", "couldn't register the prefix: unreadable answer") end
    -- Older clients answer true; newer ones Enum.RegisterAddonMessagePrefixResult,
    -- where Success (0) and DuplicatePrefix (1: already registered) both mean
    -- messages will arrive.
    local codes = Enum and Enum.RegisterAddonMessagePrefixResult
    local success = codes and codes.Success or 0
    local duplicate = codes and codes.DuplicatePrefix or 1
    if result == true or result == success or result == duplicate then
        registered = true
    else
        ns.Diag.Log("comm", "couldn't register the prefix: %s", result)
    end
end

-- Open for sending and receiving: the prefix is registered and the addon
-- is switched on.
function Comm.Ready()
    return registered and ns.db ~= nil and ns.db.enabled == true
end

function Comm.Registered()
    return registered
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------

local function Reject(counter, why, sender)
    ns.Diag.Count(counter)
    ns.Diag.Log("comm", "dropped a message from %s: %s", sender or "?", why)
end

-- Split on DELIM. MAX_BYTES bounds the work.
local function Split(text)
    local parts, start = {}, 1
    while true do
        local stop = text:find(Comm.DELIM, start, true)
        if not stop then
            parts[#parts + 1] = text:sub(start)
            return parts
        end
        parts[#parts + 1] = text:sub(start, stop - 1)
        start = stop + 1
    end
end

-- CHAT_MSG_ADDON: prefix, text, route, sender.
function Comm.OnAddonMessage(prefix, text, route, sender)
    -- A secret prefix can't be compared, so we can't tell whose message it
    -- is: most are other addons', so it isn't counted or logged.
    if Util.IsSecret(prefix) or prefix ~= Comm.PREFIX then return end
    if not Comm.Ready() then return end
    if Util.IsSecret(text) or Util.IsSecret(route) or Util.IsSecret(sender) then
        return Reject("commUnreadable", "unreadable text, route or sender")
    end
    local name = Util.FullName(sender)
    if not name then return Reject("commMalformed", "no readable sender") end
    -- Our own group and guild messages come back to us.
    if name == Util.UnitFullName("player") then return end
    if type(text) ~= "string" then return Reject("commMalformed", "no text", name) end
    if #text > Comm.MAX_BYTES then return Reject("commOversized", #text .. " bytes", name) end
    if not ALL_ROUTES[route] then return Reject("commWrongRoute", "route " .. tostring(route), name) end
    -- Before any parsing, so a flood costs as little as possible.
    if not AllowIncoming(name, GetTime()) then return Reject("commFlood", "too many messages", name) end

    local parts = Split(text)
    if #parts < 3 or not parts[1]:find("^%d%d?%d?$") then return Reject("commMalformed", "no version", name) end
    if tonumber(parts[1]) ~= Comm.VERSION then
        return Reject("commWrongVersion", "version " .. parts[1], name)
    end
    local spec = types[parts[2]]
    if not spec then return Reject("commUnknownType", "type " .. parts[2]:sub(1, 16), name) end
    if not spec.routes[route] then return Reject("commWrongRoute", parts[2] .. " on " .. route, name) end
    if parts[3] ~= name then return Reject("commSpoofed", "says it is about " .. parts[3]:sub(1, 64), name) end
    local fields = {}
    for i = 4, #parts do fields[#fields + 1] = parts[i] end
    if #fields ~= #spec.fields then
        return Reject("commMalformed", parts[2] .. " with " .. #fields .. " fields", name)
    end
    for i, check in ipairs(spec.fields) do
        if not check(fields[i]) then return Reject("commMalformed", parts[2] .. " field " .. i, name) end
    end

    ns.Diag.Count("commReceived")
    ns.Diag.Call(spec.handler, name, fields, route)
end

------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------

local queue = {}
local pumpScheduled = false

-- Whether the game would accept this route right now. Unreadable answers
-- count as closed.
local function Yes(value)
    return not Util.IsSecret(value) and value == true
end

local function RouteOpen(route)
    if route == "WHISPER" then return true end
    if route == "GUILD" then return Yes(IsInGuild()) end
    if route == "RAID" then return Yes(IsInRaid()) end
    if route == "INSTANCE_CHAT" then return Yes(IsInGroup(LE_PARTY_CATEGORY_INSTANCE)) end
    return Yes(IsInGroup(LE_PARTY_CATEGORY_HOME)) -- PARTY
end

local function Drop(item, counter, why)
    ns.Diag.Count(counter)
    ns.Diag.Log("comm", "didn't send %s on %s: %s", item.label, item.route, why)
end

local function Transmit(item)
    if not Comm.Ready() then return Drop(item, "commNotSent", "the channel is closed") end
    if ns.ChatQueue.InChatLockdown() then return Drop(item, "commNotSent", "chat lockdown") end
    if not RouteOpen(item.route) then return Drop(item, "commNotSent", "not in that group any more") end
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, Comm.PREFIX, item.text, item.route, item.target)
    -- Each case is its own branch: a secret answer must never be tested.
    if not ok then return Drop(item, "commNotSent", "error") end
    if Util.IsSecret(result) then return Drop(item, "commNotSent", "unreadable answer") end
    -- Older clients answer true; newer ones Enum.SendAddonMessageResult,
    -- where only Success (0) means sent.
    local codes = Enum and Enum.SendAddonMessageResult
    local success = codes and codes.Success or 0
    if result ~= true and result ~= success then
        return Drop(item, "commNotSent", "the game answered " .. tostring(result))
    end
    ns.Diag.Count("commSent")
end

function Comm.Pump()
    pumpScheduled = false
    local now = GetTime()
    while queue[1] do
        local item = queue[1]
        if now - item.created > Comm.MAX_QUEUE_AGE then
            table.remove(queue, 1)
            Drop(item, "commNotSent", "waited too long")
        elseif Take(sendBucket, Comm.SEND_BURST, Comm.SEND_REFILL, now) then
            table.remove(queue, 1)
            Transmit(item)
        else
            local wait = (1 - sendBucket.tokens) * Comm.SEND_REFILL
            pumpScheduled = true
            C_Timer.After(wait, ns.Diag.Wrap(Comm.Pump))
            return
        end
    end
end

-- Send a message of a registered type: fields are its fields as text;
-- route is one of ROUTES; target is the full name for WHISPER. Returns
-- true when it was queued (it may still not go out), or false and why.
function Comm.Send(msgType, fields, route, target)
    if not Comm.Ready() then return false, "the channel is closed" end
    local spec = types[msgType]
    if not spec then return false, "unknown type" end
    if not spec.routes[route] then return false, "wrong route" end
    if route == "WHISPER" then
        target = Util.FullName(target)
        if not target then return false, "no one to whisper" end
    else
        target = nil
    end
    local me = Util.UnitFullName("player")
    if not me then return false, "can't read your name" end
    -- Our own messages pass the same checks as anyone else's.
    if type(fields) ~= "table" or #fields ~= #spec.fields then return false, "wrong number of fields" end
    for i, check in ipairs(spec.fields) do
        if type(fields[i]) ~= "string" or not check(fields[i]) then return false, "bad field " .. i end
    end
    local text = table.concat({ tostring(Comm.VERSION), msgType, me, unpack(fields) }, Comm.DELIM)
    if #text > Comm.MAX_BYTES then return false, "too long" end
    local item = { text = text, route = route, target = target, created = GetTime(), label = msgType }
    if #queue >= Comm.MAX_QUEUE then
        Drop(item, "commNotSent", "too many waiting")
        return false, "too many waiting"
    end
    queue[#queue + 1] = item
    if not pumpScheduled then Comm.Pump() end
    return true
end

function Comm.QueueLength()
    return #queue
end

------------------------------------------------------------------------
-- HELLO: "I run Friendly Forever, this version"
------------------------------------------------------------------------

local peers, peerCount = {}, 0

-- A peer is forgotten after PEER_TTL, or at once if the clock went
-- backwards (we can't tell how old it is).
local function Expired(peer, now)
    return now - peer.seen > Comm.PEER_TTL or now < peer.seen
end

local function Forget(name)
    if peers[name] then
        peers[name] = nil
        peerCount = peerCount - 1
    end
end

-- Room for one more: forget expired peers, then the one seen longest ago.
local function MakeRoomForPeer(now)
    local oldest
    for name, peer in pairs(peers) do
        if Expired(peer, now) then
            Forget(name)
        elseif not oldest or peer.seen < peers[oldest].seen then
            oldest = name
        end
    end
    if peerCount >= Comm.MAX_PEERS and oldest then Forget(oldest) end
end

local function LivePeer(name)
    local peer = type(name) == "string" and peers[name]
    if not peer then return nil end
    if Expired(peer, GetTime()) then return nil end
    return peer
end

-- Whether this player (full name) has said they run the addon lately.
function Comm.IsPeer(name)
    return LivePeer(name) ~= nil
end

-- Their addon version ("0.8.0", or "?"), or nil.
function Comm.PeerVersion(name)
    local peer = LivePeer(name)
    return peer and peer.version
end

function Comm.PeerCount()
    local now = GetTime()
    for name, peer in pairs(peers) do
        if Expired(peer, now) then Forget(name) end
    end
    return peerCount
end

local function MyVersion()
    local v = ns.VERSION
    if type(v) == "string" and Comm.Field.Version(v) then return v end
    return "?"
end

-- Tell a player (WHISPER) or a group or guild that this copy is here. A
-- whispered HELLO asks for one back.
function Comm.SayHello(route, target)
    return Comm.Send("HELLO", { MyVersion(), route == "WHISPER" and "1" or "0" }, route, target)
end

local function OnHello(sender, fields, route)
    local now = GetTime()
    local peer = peers[sender]
    if not peer then
        if peerCount >= Comm.MAX_PEERS then MakeRoomForPeer(now) end
        peer = {}
        peers[sender] = peer
        peerCount = peerCount + 1
    end
    peer.version, peer.seen = fields[1], now
    ns.Diag.Log("comm", "%s runs Friendly Forever %s", sender, fields[1])
    -- Only whispers are answered, and once per player per REPLY_GAP: a
    -- guild or raid saying hello can't make everyone answer at once.
    if route == "WHISPER" and fields[2] == "1" then
        if peer.answered and now - peer.answered < Comm.REPLY_GAP and now >= peer.answered then return end
        peer.answered = now
        Comm.Send("HELLO", { MyVersion(), "0" }, "WHISPER", sender)
    end
end

Comm.RegisterType("HELLO", {
    fields = { Comm.Field.Version, Comm.Field.Flag },
    routes = ALL_ROUTES,
    handler = OnHello,
})


------------------------------------------------------------------------
-- ANSWER: "the buff I just gave you answers yours" (#37)
------------------------------------------------------------------------

-- Whispered to a player whose favour you just returned, so their copy
-- doesn't owe you one back (Offers.lua). It has no fields: the sender is
-- the subject, and it can only stop the receiver owing the sender.
function Comm.SendAnswer(name)
    return Comm.Send("ANSWER", {}, "WHISPER", name)
end

Comm.RegisterType("ANSWER", {
    fields = {},
    routes = { WHISPER = true },
    handler = function(sender) ns.Offers.OnAnswerMark(sender) end,
})


------------------------------------------------------------------------
-- PLAN: "these are the buffs I'll still give you" (#36)
------------------------------------------------------------------------

-- Whispered to a player you're exchanging buffs with whenever what your
-- buff-back button holds for them changes (Exchange.lua). One field: the
-- buff keys, or "-" for none. It can only hold the receiver's thank-you to
-- the sender, never past Exchange.MAX_DELAY.
function Comm.SendPlan(name, keys)
    return Comm.Send("PLAN", { keys }, "WHISPER", name)
end

Comm.RegisterType("PLAN", {
    fields = { Comm.Field.KeyList },
    routes = { WHISPER = true },
    handler = function(sender, fields) ns.Exchange.OnPlan(sender, fields[1]) end,
})
