-- Shared path from "something happened" to a queued chat message: checks the
-- switches and the per-player repeat cooldown, picks a random line, waits the
-- configured delay, then hands the message to the chat queue.
local _, ns = ...
local Util = ns.Util

local Announcer = {}
ns.Announcer = Announcer

-- Seconds after logging in or reloading during which nothing is sent
-- (avoids reacting to the burst of events the game fires while loading).
Announcer.LOGIN_GRACE = 10

-- Snooze: /friendly snooze [minutes]. Wall-clock time, so it holds across a
-- reload or relog.
Announcer.SNOOZE_DEFAULT = 15 -- minutes
Announcer.SNOOZE_MAX = ns.Config.SNOOZE_MAX_SECONDS / 60 -- minutes (a day)

local activeAt = math.huge

function Announcer.OnEnteringWorld()
    activeAt = GetTime() + Announcer.LOGIN_GRACE
end

-- Seconds of snooze left, or nil when not snoozed.
function Announcer.SnoozeLeft()
    local untilTime = ns.db and ns.db.snoozeUntil
    if not untilTime then return nil end
    -- Damaged mid-session: not a number means awake, as at load (so does
    -- NaN, below), and never longer than the longest snooze.
    if type(untilTime) ~= "number" then
        ns.db.snoozeUntil = nil
        return nil
    end
    local left = untilTime - time()
    if left > ns.Config.SNOOZE_MAX_SECONDS then
        left = ns.Config.SNOOZE_MAX_SECONDS
        ns.db.snoozeUntil = time() + left
    end
    if left > 0 then return left end
    ns.db.snoozeUntil = nil
    return nil
end

-- minutes > 0 snoozes for that long (capped); 0 or nil wakes it up.
function Announcer.Snooze(minutes)
    if not minutes or minutes <= 0 then
        ns.db.snoozeUntil = nil
        return nil
    end
    minutes = math.min(math.max(1, math.ceil(minutes)), Announcer.SNOOZE_MAX)
    ns.db.snoozeUntil = time() + minutes * 60
    return minutes
end

-- On and past the login grace: events are worth noticing (the ledger keeps
-- a snoozed favour), though nothing may be sent.
function Announcer.IsWatching()
    return ns.db ~= nil and ns.db.enabled and GetTime() >= activeAt
end

-- Watching, and not snoozed: messages may be sent.
function Announcer.IsActive()
    return Announcer.IsWatching() and not Announcer.SnoozeLeft()
end

-- Why the addon is or isn't reacting right now, in words (for diagnostics).
function Announcer.ActiveState()
    if ns.db == nil then return "saved settings not loaded yet" end
    if not ns.db.enabled then return "addon switched off" end
    local snoozed = Announcer.SnoozeLeft()
    if snoozed then return string.format("snoozed, %d min left", math.ceil(snoozed / 60)) end
    if activeAt == math.huge then return "waiting for the login/reload event (PLAYER_ENTERING_WORLD)" end
    local left = activeAt - GetTime()
    if left > 0 then return string.format("login grace period, %.0fs left", left) end
    return "active"
end

-- A type's section lost mid-session reads as switched off (#387).
local function TypeEnabled(msgType)
    local cfg = ns.db[msgType]
    return ns.db.enabled and type(cfg) == "table" and cfg.enabled
end

-- Re-checked just before a scheduled message is sent.
local function StillWanted(msgType)
    if not TypeEnabled(msgType) then return false, "switched off" end
    if not ns.Battleground.AllowsLine(msgType) then return false, ns.Battleground.QuietReason() end
    if Announcer.SnoozeLeft() then return false, "snoozed" end
    return true
end

-- key: who or what the cooldown is for. Without opts.vars it is also the
-- player whose name fills {name} and {fullname}. So a key that isn't the
-- player the message names (a group leader for hellos, "whisper failed:X",
-- the first name of a merged welcome) must come with vars.
-- opts = {
--   channel  = string | function() -> channel or nil,
--   target   = optional whisper target,
--   vars     = optional function() -> placeholder table (default: key's name vars),
--   isValid  = optional function() -> ok, reason; re-checked before sending,
--   cooldown = optional seconds (default: the type's repeatCooldown),
--   delay    = optional seconds (default: the type's delay),
--   onDone   = optional function(sent, reason), always called once if this returns true,
--   maxAge   = optional seconds the queued message may wait (default: ChatQueue.MAX_AGE),
--   ageFrom  = optional GetTime() its maxAge counts from, when not from the
--              moment it is queued (a held thank-you: when it was due),
--   emote    = optional emote token ("THANK"): perform that text emote instead
--              of sending a line. Its repeat cooldown is its own, so a line
--              and an emote for the same player don't block each other.
--   emoteTarget = optional function() -> unit token to aim the emote at, or nil,
--   dropOverCap = optional true for thanks: dropped, not held, over the chat cap,
--   context  = optional function() -> { zone = text or nil }: a guild message
--              (#486), read as it goes out. {zone} is that zone, and a line
--              that needs it when it's nil gives way to one that doesn't, or
--              nothing is said (Flavour.Context),
--   hold     = optional function(go, line, drop): after the delay, call go()
--              once when the message may be queued (a thank-you waits for
--              its exchange: #36), or drop(reason) once to send nothing.
--              line is the number of the line picked; go(n) says line n
--              instead, if it isn't blank (a guild hello: #38),
-- }
-- Returns true if a message was scheduled, or false and the reason not.
-- The line to say when the zone it may need is unknown (#486): template if
-- it doesn't need {zone}, else the next line in the bag that doesn't, or nil.
local function WithoutZone(msgType, saved, template)
    if not ns.Flavour.NeedsZone(template) then return template end
    local avoid = {}
    for i = 1, #saved do
        if ns.Flavour.NeedsZone(saved[i]) then avoid[i] = true end
    end
    local other = ns.Messages.Pick(msgType, saved, avoid)
    if other and not ns.Flavour.NeedsZone(other) then return other end
    ns.Diag.Log(msgType, "every line needs {zone}, and their zone can't be read")
end

local function Skip(msgType, key, reason)
    ns.Diag.Log(msgType, "not sending for %s: %s", key, reason)
    return false, reason
end

function Announcer.Schedule(msgType, key, opts)
    if not Announcer.IsActive() then return Skip(msgType, key, Announcer.ActiveState()) end
    if not TypeEnabled(msgType) then return Skip(msgType, key, "this message type is switched off") end
    if not ns.Battleground.AllowsLine(msgType) then
        return Skip(msgType, key, "in a battleground: " .. ns.Battleground.QuietReason())
    end
    local cfg = ns.db[msgType]

    local cooldown = opts.cooldown or cfg.repeatCooldown
    local claim = msgType .. ":" .. (opts.emote and "emote:" or "") .. key
    if not ns.Cooldowns.TryClaim(claim, cooldown, GetTime()) then
        return Skip(msgType, key, "repeat cooldown (" .. cooldown .. "s) still running")
    end

    local template, line
    if not opts.emote then
        template, line = ns.Messages.Pick(msgType, cfg.messages)
        if not template then return Skip(msgType, key, "all message lines are blank") end
    end

    local delay = opts.delay or cfg.delay
    ns.Diag.Log(msgType, "scheduled for %s in %ss", key, delay)

    local function Queue(other)
        local live = ns.db[msgType] -- may be lost by now (#387)
        local lines = type(live) == "table" and live.messages
        local text = other and type(lines) == "table" and lines[other]
        if type(text) == "string" and text:find("%S") then template, line = text, other end
        ns.ChatQueue.Push({
            channel = opts.emote and "EMOTE" or opts.channel,
            target = opts.target,
            emote = opts.emote,
            getTarget = opts.emoteTarget,
            getText = function()
                -- The line is read again as it goes out, so one deleted or
                -- edited while it waited (a /say thank-you waits for a key
                -- press) is not said as it was: a blank line says nothing (#407).
                local now = ns.db[msgType]
                local saved = type(now) == "table" and now.messages
                local said = type(saved) == "table" and line and saved[line]
                if line then
                    if type(said) ~= "string" or not said:find("%S") then return nil end
                    template = said
                end
                local vars = opts.vars and opts.vars() or Util.NameVars(key)
                local ctx
                if opts.context then
                    ctx = ns.Flavour.Context(opts.context())
                    -- No line that can go without their zone: nil, and nothing is said.
                    if ctx.zone == nil then template = WithoutZone(msgType, saved, template) end
                end
                return Util.Render(template, ns.Flavour.Vars(vars, ctx))
            end,
            isValid = function()
                local ok, why = StillWanted(msgType)
                if not ok then return false, why end
                if opts.isValid then return opts.isValid() end
                return true
            end,
            onDone = opts.onDone,
            maxAge = (opts.maxAge and opts.ageFrom)
                and math.max(0, opts.maxAge - (GetTime() - opts.ageFrom)) or opts.maxAge,
            label = msgType .. (opts.emote and " emote" or "") .. " for " .. key,
            automatic = true,
            dropOverCap = opts.dropOverCap,
        })
    end
    local function Drop(reason)
        ns.Diag.Log(msgType, "not sending for %s: %s", key, reason)
        if opts.onDone then opts.onDone(false, reason) end
    end
    C_Timer.After(delay, ns.Diag.Wrap(function()
        if opts.hold then opts.hold(Queue, line, Drop) else Queue() end
    end))
    return true
end
