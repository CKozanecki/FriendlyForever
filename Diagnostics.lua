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

-- The text of a log line after its time ("buff: skipped Ann: ..."), with
-- the arguments made display-safe.
local function Format(category, fmt, ...)
    local args = { ... }
    for i = 1, select("#", ...) do args[i] = Diag.Safe(args[i]) end
    return string.format("%s: " .. fmt, category, unpack(args, 1, select("#", ...)))
end

local function Write(text)
    local line = date("%H:%M:%S") .. " " .. text
    local log = ns.db.diagLog
    log[#log + 1] = line
    while #log > Diag.MAX_LOG do table.remove(log, 1) end

    DEFAULT_CHAT_FRAME:AddMessage(ns.Colours.Text("muted", "[FF debug]") .. " " .. line)
end

-- Diag.Log("buff", "skipped %s: %s", name, reason). Arguments are made
-- display-safe; nothing is formatted unless debug is on.
function Diag.Log(category, fmt, ...)
    if not Diag.Enabled() then return end
    Write(Format(category, fmt, ...))
end

-- Folded lines (#453): a line that repeats exactly, within FOLD_SECONDS
-- of its last repeat, is logged once; the repeats are counted, and the
-- count is logged when the run ends (a different line of the same kind,
-- or FOLD_SECONDS with no repeat), as #268 folds its repeats. A run of one
-- gets no count line. Only the log changes: callers act as before.
Diag.FOLD_SECONDS = 2
local folds = {} -- [kind] = { text, repeats, lastAt, timer }

local function EndRun(kind)
    local run = folds[kind]
    folds[kind] = nil
    if run and run.repeats > 0 and Diag.Enabled() then
        Write(string.format("%s (repeated %d more time%s)", run.text, run.repeats, run.repeats == 1 and "" or "s"))
    end
end

-- End kind's run once FOLD_SECONDS pass with no repeat. One timer per run:
-- a repeat moves lastAt, and the timer waits on from there.
local function WatchRun(kind, run)
    if run.timer then return end
    run.timer = true
    local wait = run.lastAt + Diag.FOLD_SECONDS - GetTime()
    C_Timer.After(math.max(wait, 0) + 0.05, Diag.Wrap(function()
        run.timer = false
        if folds[kind] ~= run then return end
        if GetTime() - run.lastAt >= Diag.FOLD_SECONDS then return EndRun(kind) end
        WatchRun(kind, run)
    end))
end

-- Diag.LogFolded("press", "buffBack", "pressed: %s", macroText): as
-- Diag.Log, folding exact repeats of kind's line.
function Diag.LogFolded(kind, category, fmt, ...)
    if not Diag.Enabled() then return end
    local text = Format(category, fmt, ...)
    local now, run = GetTime(), folds[kind]
    if run and run.text == text and now - run.lastAt <= Diag.FOLD_SECONDS then
        run.repeats, run.lastAt = run.repeats + 1, now
        return WatchRun(kind, run)
    end
    EndRun(kind)
    folds[kind] = { text = text, repeats = 0, lastAt = now }
    Write(text)
end

-- Run fn(...) and, if it raises a Lua error, count and log it, then hand it
-- to the game's normal error display (so nothing is hidden).
-- Lua 5.1's xpcall passes no arguments, so they go through these upvalues.
-- That keeps the hot events (auras, spellcasts, roster updates) from making a
-- table and a closure every time. The trampoline copies them out before
-- calling fn, so a Diag.Call made inside fn can't overwrite them.
local callFn, callN, arg1, arg2, arg3, arg4
local function Trampoline()
    local fn, n, a1, a2, a3, a4 = callFn, callN, arg1, arg2, arg3, arg4
    callFn, arg1, arg2, arg3, arg4 = nil, nil, nil, nil, nil
    -- Exactly as many arguments as were given, as select("#", ...) sees them.
    if n == 0 then return fn() end
    if n == 1 then return fn(a1) end
    if n == 2 then return fn(a1, a2) end
    if n == 3 then return fn(a1, a2, a3) end
    return fn(a1, a2, a3, a4)
end

function Diag.Call(fn, ...)
    local n = select("#", ...)
    if n <= 4 then
        callFn, callN, arg1, arg2, arg3, arg4 = fn, n, ...
        return xpcall(Trampoline, Diag.OnError)
    end
    local args = { ... }
    return xpcall(function() return fn(unpack(args, 1, n)) end, Diag.OnError)
end

function Diag.OnError(err)
    Diag.Count("luaErrors")
    Diag.lastError = Diag.Safe(err)
    -- Damaged settings can cause errors: repair them now, before logging
    -- (the log lives in them). A repair that fails itself is left for the
    -- next error or reload.
    if ns.Config and ns.Config.Repair then pcall(ns.Config.Repair) end
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
    folds = {} -- a run from before belongs to no log now
    if ns.db.debug then
        ns.db.diagLog = {}
        ns.Print("debug " .. ns.Colours.Text("good", "on") .. ": decisions are shown here and saved to the "
            .. "FriendlyForever saved-variables file (written on /reload or logout).")
        Diag.Log("debug", "started; version %s", ns.VERSION)
    else
        ns.Print("debug " .. ns.Colours.Text("bad", "off"))
    end
end
