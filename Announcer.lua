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

local function TypeEnabled(msgType)
    return ns.db.enabled and ns.db[msgType].enabled
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
--   emote    = optional emote token ("THANK"): perform that text emote instead
--              of sending a line. Its repeat cooldown is its own, so a line
--              and an emote for the same player don't block each other.
--   emoteTarget = optional function() -> unit token to aim the emote at, or nil,
-- }
-- Returns true if a message was scheduled, or false and the reason not.
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

    local template
    if not opts.emote then
        template = ns.Messages.Pick(msgType, cfg.messages)
        if not template then return Skip(msgType, key, "all message lines are blank") end
    end

    local delay = opts.delay or cfg.delay
    ns.Diag.Log(msgType, "scheduled for %s in %ss", key, delay)

    C_Timer.After(delay, ns.Diag.Wrap(function()
        ns.ChatQueue.Push({
            channel = opts.emote and "EMOTE" or opts.channel,
            target = opts.target,
            emote = opts.emote,
            getTarget = opts.emoteTarget,
            getText = function()
                local vars = opts.vars and opts.vars() or Util.NameVars(key)
                return Util.Render(template, ns.Flavour.Vars(vars))
            end,
            isValid = function()
                local ok, why = StillWanted(msgType)
                if not ok then return false, why end
                if opts.isValid then return opts.isValid() end
                return true
            end,
            onDone = opts.onDone,
            maxAge = opts.maxAge,
            label = msgType .. (opts.emote and " emote" or "") .. " for " .. key,
            automatic = true,
        })
    end))
    return true
end
