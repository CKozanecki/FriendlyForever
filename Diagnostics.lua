-- In-game diagnostics. With debug on (/friendly debug), every decision the
-- addon makes is logged with its reason, echoed to your chat window, and kept
-- in the saved-variables file (WTF/Account/<account>/SavedVariables/
-- FriendlyForever.lua) so it can be read after logging out. Counters are
-- always kept (in memory only) for /friendly status.
local _, ns = ...
local Util = ns.Util

local Diag = {}
ns.Diag = Diag

Diag.MAX_LOG = ns.Config.MAX_LOG

local counters = {}

-- Display-safe text for any value: secrets are never touched, and "|" is
-- doubled so chat shows raw escape codes instead of interpreting them.
function Diag.Safe(value)
    if Util.IsSecret(value) then return "<secret>" end
    if value == nil then return "nil" end
    return (tostring(value):gsub("|", "||"))
end

function Diag.Count(key)
    counters[key] = (counters[key] or 0) + 1
end

function Diag.Counters()
    return counters
end

function Diag.Enabled()
    return ns.db ~= nil and ns.db.debug == true
end

-- Diag.Log("buff", "skipped %s: %s", name, reason). Arguments are made
-- display-safe; nothing is formatted unless debug is on.
function Diag.Log(category, fmt, ...)
    if not Diag.Enabled() then return end
    local args = { ... }
    for i = 1, select("#", ...) do args[i] = Diag.Safe(args[i]) end
    local line = string.format("%s %s: " .. fmt, date("%H:%M:%S"), category, unpack(args, 1, select("#", ...)))

    local log = ns.db.diagLog
    log[#log + 1] = line
    while #log > Diag.MAX_LOG do table.remove(log, 1) end

    DEFAULT_CHAT_FRAME:AddMessage("|cff999999[FF debug]|r " .. line)
end

-- Run fn(...) and, if it raises a Lua error, count and log it, then hand it
-- to the game's normal error display (so nothing is hidden).
function Diag.Call(fn, ...)
    local n, args = select("#", ...), { ... }
    return xpcall(function() return fn(unpack(args, 1, n)) end, Diag.OnError)
end

function Diag.OnError(err)
    Diag.Count("luaErrors")
    Diag.lastError = Diag.Safe(err)
    Diag.Log("error", "%s", err)
    local handler = geterrorhandler and geterrorhandler()
    if handler then handler(err) end
end

-- Wrap a callback (timers, scripts) so its errors are captured the same way.
function Diag.Wrap(fn)
    return function(...) return Diag.Call(fn, ...) end
end

function Diag.SetEnabled(on)
    ns.db.debug = on and true or false
    if ns.db.debug then
        ns.db.diagLog = {}
        ns.Print("debug |cff00ff00on|r: decisions are shown here and saved to the "
            .. "FriendlyForever saved-variables file (written on /reload or logout).")
        Diag.Log("debug", "started; version %s", ns.VERSION)
    else
        ns.Print("debug |cffff4040off|r")
    end
end
