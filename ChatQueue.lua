-- The only place the addon sends chat. Every message goes through this
-- queue, which:
--   * rate-limits output (a guild-wide login wave can't flood chat),
--   * caps the lines each chat type gets a minute (#35): thanks over the cap
--     are dropped, everything else waits for room,
--   * bounds how much can be waiting and how long it may wait,
--   * holds messages while the game's chat lockdown is active,
--   * holds /say outside instances until a hardware event (key press),
--     which the game requires for that channel (text emotes such as /thank
--     wait the same way, to be safe),
--   * re-checks each message is still wanted right before sending,
--   * drops automatic messages that come due while you're AFK (an option).
local _, ns = ...
local Util = ns.Util

local ChatQueue = {}
ns.ChatQueue = ChatQueue

ChatQueue.MIN_INTERVAL = 1.5  -- seconds between any two sends
ChatQueue.MAX_PENDING = 25
ChatQueue.MAX_AGE = 120       -- seconds a message may wait before it is dropped (unless item.maxAge)
ChatQueue.RETRY_DELAY = 2
ChatQueue.CAP_WINDOW = 60     -- seconds the lines-per-minute cap counts over

-- Chat types the cap counts together, and their names in words. Any other
-- channel is counted on its own.
ChatQueue.CAP_GROUPS = {
    SAY = "say", WHISPER = "whisper", EMOTE = "emote", GUILD = "guild",
    PARTY = "group", RAID = "group", INSTANCE_CHAT = "group",
}
local CAP_NAMES = { say = "/say", whisper = "whispers", emote = "emotes", guild = "guild chat", group = "group chat" }

local pending = {}
-- [cap group] = when lines went there lately. This session's record is the
-- one the cap trusts; the saved variables hold a copy so a /reload doesn't
-- forget it, read back when they load (Init).
local capStamps = {}
local lastSendTime = -math.huge
local pumpScheduled = false
local waitingForHardware = false
local keyFrame
local keyboardReady = false

function ChatQueue.InChatLockdown()
    local info = C_ChatInfo
    return info ~= nil and info.InChatMessagingLockdown ~= nil and info.InChatMessagingLockdown() == true
end

-- "EMOTE" is a text emote (/thank). Whether the game holds those back like
-- /say is untested, so they wait for a key press outdoors too.
function ChatQueue.NeedsHardwareEvent(channel)
    if channel ~= "SAY" and channel ~= "YELL" and channel ~= "EMOTE" then return false end
    return not IsInInstance()
end

-- true or false, or nil when the game won't say (a secret value). A client
-- without UnitIsAFK counts as not AFK.
function ChatQueue.ReadPlayerAFK()
    if not UnitIsAFK then return false end
    local afk, secret = Util.Readable(UnitIsAFK("player"))
    if secret then return nil end
    return afk and true or false
end

-- True only when the game readably says I'm AFK. Unreadable (secret) or
-- missing counts as not AFK, so messages still go out.
function ChatQueue.IsPlayerAFK()
    return ChatQueue.ReadPlayerAFK() == true
end

-- Checked at the moment of sending, after the holds, so a /say waiting for
-- a key press is judged by the press: if it cleared AFK, the message goes.
local function SkipForAFK(item)
    return item.automatic and ns.db ~= nil and ns.db.skipWhileAFK and ChatQueue.IsPlayerAFK()
end

-- The cap in force: the saved setting, clamped on every use so a value
-- damaged mid-session can't lift it.
function ChatQueue.LinesPerMinute()
    local limits = ns.Config.LIMITS.linesPerMinute
    return Util.ClampNumber(ns.db.linesPerMinute, limits.min, limits.max, ns.Config.DEFAULTS.linesPerMinute)
end

local function CapKey(channel)
    return ChatQueue.CAP_GROUPS[channel] or channel
end

-- This session's record starts as a copy of what the saved variables
-- remember, as Config.Load left it: [group] = list of entries. Their
-- GetTime() readings may be from before a restart: the cap counts any that
-- look like the future as now, and the wall clock still ages them.
local function RestoreCap()
    for key, list in pairs(ns.db.chatCap) do
        local mine = {}
        for _, e in ipairs(list) do mine[#mine + 1] = e end
        capStamps[key] = mine
    end
end

-- When lines went to channel's chat type lately. The saved copy is pointed
-- at this session's list on every use, so damage to it is undone at once.
local function CapStamps(channel)
    local key = CapKey(channel)
    local list = capStamps[key]
    if not list then
        list = {}
        capStamps[key] = list
    end
    if type(ns.db.chatCap) ~= "table" then ns.db.chatCap = {} end
    ns.db.chatCap[key] = list
    return list
end

-- now: GetTime(); wall: time(). The cap times every line on both clocks
-- (see RateLimit.lua), so a jump of either can't let a burst through.
local function CapHasRoom(channel, now, wall)
    return ns.RateLimit.HasRoom(CapStamps(channel), ChatQueue.CAP_WINDOW, ChatQueue.LinesPerMinute(), now, wall)
end

-- Write this session's record into the saved variables (on logout and
-- /reload, just before the game saves them), whatever became of the copy.
function ChatQueue.SaveCap()
    local now, wall, saved = GetTime(), time(), {}
    for key, list in pairs(capStamps) do
        ns.RateLimit.Count(list, ChatQueue.CAP_WINDOW, now, wall) -- forgets what has aged out
        saved[key] = list
    end
    ns.db.chatCap = saved
end

local function CapReason(channel)
    local key = CapKey(channel)
    return string.format("chat rate limit reached (%d lines a minute in %s)", ChatQueue.LinesPerMinute(),
        CAP_NAMES[key] or key)
end

-- The game's chat functions are named only in this file (a spec checks), so
-- nothing can send around the queue and its cap.
local function SendFunction()
    return (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
end

-- Blizzard's chat box calls C_ChatInfo.PerformEmote; DoEmote is the older name.
local function EmoteFunction()
    return (C_ChatInfo and C_ChatInfo.PerformEmote) or DoEmote
end

-- Whether this game client has them (for /friendly status).
function ChatQueue.CanSend() return SendFunction() ~= nil end
function ChatQueue.CanEmote() return EmoteFunction() ~= nil end

local function RawSend(text, channel, target)
    return pcall(SendFunction(), text, channel, nil, target)
end

-- Returns ok, err. The call answers true when the game held the emote back,
-- so that counts as not sent.
local function RawEmote(token, target)
    local emote = EmoteFunction()
    if not emote then return false, "this game client has no emote function" end
    local ok, restricted = pcall(emote, token, target)
    if not ok then return false, restricted end
    if not Util.IsSecret(restricted) and restricted == true then return false, "the game held the emote back" end
    return true
end

local function Finish(item, sent, reason)
    if item.onDone then item.onDone(sent, reason) end
end

local function Drop(item, reason)
    ns.Diag.Count("dropped")
    ns.Diag.Log("send", "dropped %s: %s", item.label, reason)
    Finish(item, false, reason)
end

-- Log why a message is waiting, once per reason change (not every pump).
local function Hold(item, reason)
    if item.heldReason == reason then return end
    item.heldReason = reason
    ns.Diag.Log("send", "holding %s: %s", item.label, reason)
end

local function ResolveChannel(item)
    if type(item.channel) == "function" then return item.channel() end
    return item.channel
end

local SchedulePump

-- Send at most one message. `hardware` is true when called from a key press.
function ChatQueue.Pump(hardware)
    local now, wall = GetTime(), time()
    -- A last send "in the future" (the clock went back) counts as now, so
    -- the spacing can't hold messages back for good.
    if lastSendTime > now then lastSendTime = now end
    local sent = false
    local needsHardware = false
    local i = 1

    while i <= #pending do
        local item = pending[i]
        local channel = ResolveChannel(item)

        local dropReason
        local maxAge = item.maxAge or ChatQueue.MAX_AGE
        if now - item.created > maxAge then
            dropReason = "waited too long (" .. maxAge .. "s)"
        elseif not channel then
            dropReason = "no channel (not in a guild/group any more?)"
        elseif channel == "EMOTE" and type(item.emote) ~= "string" then
            dropReason = "emote without a name"
        elseif channel == "WHISPER" and type(item.target) ~= "string" then
            dropReason = "whisper without a target"
        else
            local valid, why = true, nil
            if item.isValid then valid, why = item.isValid() end
            if not valid then dropReason = "no longer wanted: " .. (why or "no reason given") end
        end

        if dropReason then
            table.remove(pending, i)
            Drop(item, dropReason)
        elseif not CapHasRoom(channel, now, wall) then
            if item.dropOverCap then
                table.remove(pending, i)
                ns.Diag.Count("capDropped")
                Drop(item, CapReason(channel))
            else
                if not item.capHeld then
                    item.capHeld = true
                    ns.Diag.Count("capHeld")
                end
                Hold(item, CapReason(channel))
                i = i + 1
            end
        elseif sent or now - lastSendTime < ChatQueue.MIN_INTERVAL then
            if ChatQueue.NeedsHardwareEvent(channel) then needsHardware = true end
            i = i + 1
        elseif ChatQueue.InChatLockdown() then
            Hold(item, "game chat lockdown is active")
            if ChatQueue.NeedsHardwareEvent(channel) then needsHardware = true end
            i = i + 1
        elseif ChatQueue.NeedsHardwareEvent(channel) and not hardware then
            Hold(item, channel .. " outdoors needs a key press")
            needsHardware = true
            i = i + 1
        else
            table.remove(pending, i)
            local text, skip
            if SkipForAFK(item) then
                skip = "you are AFK (\"Don't send messages while I'm AFK\" is on)"
            elseif channel == "EMOTE" then
                text = "/" .. item.emote:lower()
            else
                text = item.getText()
                if text == nil then skip = "message rendered empty" end
            end
            if skip then
                Drop(item, skip)
            else
                -- Every attempt counts, even one the game refuses: the cap
                -- never counts fewer lines than went out.
                ns.RateLimit.Note(CapStamps(channel), ChatQueue.CAP_WINDOW, now, wall)
                local ok, err
                if channel == "EMOTE" then
                    -- target: a unit token, or nil for "You thank everyone around you."
                    local target = item.getTarget and item.getTarget() or nil
                    ok, err = RawEmote(item.emote, target)
                    if target then text = text .. " " .. target end
                else
                    ok, err = RawSend(text, channel, item.target)
                end
                if ok then
                    lastSendTime = now
                    sent = true
                    ns.Diag.Count("sent")
                    ns.Diag.Log("send", "sent %s to %s%s: %s", item.label, channel,
                        item.target and (" " .. item.target) or "", text)
                    Finish(item, true)
                else
                    ns.Diag.Count("sendErrors")
                    ns.Diag.Log("send", "ERROR sending %s to %s: %s", item.label, channel, err)
                    Finish(item, false, "the game refused it")
                end
            end
        end
    end

    waitingForHardware = needsHardware
    if #pending > 0 then SchedulePump() end
end

SchedulePump = function()
    if pumpScheduled then return end
    pumpScheduled = true
    local wait = ChatQueue.MIN_INTERVAL - (GetTime() - lastSendTime)
    if wait < 0.1 or wait > ChatQueue.RETRY_DELAY then wait = ChatQueue.RETRY_DELAY end
    C_Timer.After(wait, ns.Diag.Wrap(function()
        pumpScheduled = false
        ChatQueue.Pump(false)
    end))
end

-- item = {
--   channel  = "GUILD" | function() -> channel or nil; "EMOTE" for a text emote,
--   target   = player name to whisper when channel is WHISPER,
--   getText  = function() -> text or nil (called right before sending; not for emotes),
--   emote    = emote token ("THANK") when channel is EMOTE,
--   getTarget = optional function() -> unit token the emote is aimed at, or nil,
--   isValid  = optional function() -> ok, reason (reason is logged when not ok),
--   onDone   = optional function(sent, reason), reason saying why it wasn't sent,
--   maxAge   = optional seconds it may wait before it is dropped (default MAX_AGE),
--   label    = optional text naming the message in diagnostics,
--   automatic = optional true for messages the addon sends by itself (skipped
--               while AFK if that option is on; /friendly selftest is not),
-- }
function ChatQueue.Push(item)
    item.label = item.label or "message"
    if #pending >= ChatQueue.MAX_PENDING then
        Drop(item, "queue full")
        return false
    end
    ns.Diag.Count("queued")
    ns.Diag.Log("send", "queued %s", item.label)
    item.created = GetTime()
    pending[#pending + 1] = item
    ChatQueue.Pump(false)
    return true
end

function ChatQueue.Count()
    return #pending
end

function ChatQueue.IsWaitingForHardware()
    return waitingForHardware
end

function ChatQueue.IsKeyboardReady()
    return keyboardReady
end

function ChatQueue.OnHardwareEvent()
    if waitingForHardware then ChatQueue.Pump(true) end
end

-- Listen for key presses (they still reach the game: input propagates) so a
-- press can serve as the hardware event /say needs. SetPropagateKeyboardInput
-- is not allowed in combat, so set it up afterwards if we load mid-fight.
function ChatQueue.Init()
    if keyFrame then return end
    -- Straight after the saved settings load, before anything can change them.
    RestoreCap()
    keyFrame = CreateFrame("Frame", nil, UIParent)
    -- Give it a size and position so it counts as visible; it takes no mouse input.
    keyFrame:SetSize(1, 1)
    keyFrame:SetPoint("TOPLEFT")
    keyFrame:SetScript("OnKeyDown", ns.Diag.Wrap(ChatQueue.OnHardwareEvent))

    local function EnableKeys()
        keyFrame:EnableKeyboard(true)
        keyFrame:SetPropagateKeyboardInput(true)
        keyboardReady = true
    end
    if InCombatLockdown() then
        keyFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        keyFrame:SetScript("OnEvent", function(self)
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
            EnableKeys()
        end)
    else
        EnableKeys()
    end
end
