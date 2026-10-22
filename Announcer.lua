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

local activeAt = math.huge

function Announcer.OnEnteringWorld()
    activeAt = GetTime() + Announcer.LOGIN_GRACE
end

function Announcer.IsActive()
    return ns.db ~= nil and ns.db.enabled and GetTime() >= activeAt
end

-- Why the addon is or isn't reacting right now, in words (for diagnostics).
function Announcer.ActiveState()
    if ns.db == nil then return "saved settings not loaded yet" end
    if not ns.db.enabled then return "addon switched off" end
    if activeAt == math.huge then return "waiting for the login/reload event (PLAYER_ENTERING_WORLD)" end
    local left = activeAt - GetTime()
    if left > 0 then return string.format("login grace period, %.0fs left", left) end
    return "active"
end

local function TypeEnabled(msgType)
    return ns.db.enabled and ns.db[msgType].enabled
end

-- opts = {
--   channel  = string | function() -> channel or nil,
--   target   = optional whisper target,
--   vars     = optional function() -> placeholder table (default: key's name vars),
--   isValid  = optional function() -> ok, reason; re-checked before sending,
--   cooldown = optional seconds (default: the type's repeatCooldown),
--   delay    = optional seconds (default: the type's delay),
--   onDone   = optional function(sent), always called once if this returns true,
-- }
-- Returns true if a message was scheduled.
local function Skip(msgType, key, reason)
    ns.Diag.Log(msgType, "not sending for %s: %s", key, reason)
    return false
end

function Announcer.Schedule(msgType, key, opts)
    if not Announcer.IsActive() then return Skip(msgType, key, Announcer.ActiveState()) end
    if not TypeEnabled(msgType) then return Skip(msgType, key, "this message type is switched off") end
    local cfg = ns.db[msgType]

    local cooldown = opts.cooldown or cfg.repeatCooldown
    if not ns.Cooldowns.TryClaim(msgType .. ":" .. key, cooldown, GetTime()) then
        return Skip(msgType, key, "repeat cooldown (" .. cooldown .. "s) still running")
    end

    local template = ns.Messages.Pick(msgType, cfg.messages)
    if not template then return Skip(msgType, key, "all message lines are blank") end

    local delay = opts.delay or cfg.delay
    ns.Diag.Log(msgType, "scheduled for %s in %ss", key, delay)

    C_Timer.After(delay, ns.Diag.Wrap(function()
        ns.ChatQueue.Push({
            channel = opts.channel,
            target = opts.target,
            getText = function()
                return Util.Render(template, opts.vars and opts.vars() or Util.NameVars(key))
            end,
            isValid = function()
                if not TypeEnabled(msgType) then return false, "switched off" end
                if opts.isValid then return opts.isValid() end
                return true
            end,
            onDone = opts.onDone,
            label = msgType .. " for " .. key,
        })
    end))
    return true
end
