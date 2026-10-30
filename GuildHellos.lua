-- Guild hellos (#38): every copy of Friendly Forever in a guild greets a
-- guildmate who logs in, but not all at once, not with the same words, and
-- at most K of them (Guild Login's "most copies that greet", maxGreeters).
--
-- Each copy waits the Guild Login delay plus a random STAGGER_MIN to
-- STAGGER_MAX seconds. Then it announces a GREET over the guild route of
-- the hidden channel (Comm.lua): the login and the line it picked, one no
-- other copy has announced. The game sends our guild messages back to us,
-- in the order it sends them to everyone, so a copy greets only once its
-- own GREET is back with fewer than K other copies' GREETs for that login
-- before it. It then says its line or, if a copy before it took that, the
-- lowest line none before it announced (see Taken). A copy that already heard K GREETs announces nothing and stays quiet.
-- Every guild member sees the same order (a launch check, #50), so even
-- copies that announce at the same moment can't go past K.
--
-- When in doubt, it doesn't greet, so the cap holds (fail closed): its
-- GREET doesn't come back within ECHO_WAIT (lost, or never sent), it lost
-- track of the login, the channel's limits on everyone together dropped
-- messages since the login (some may have been GREETs it never counted).
-- A line the chat cap holds back (#35) still goes, late.
--
-- Without the channel (it's closed, you aren't in a guild as the game
-- sees it, chat lockdown, or inside an instance, where addons may not
-- message other players: #32) the random stagger is all there is: the copy
-- greets after it, with a line no GREET it heard has taken.
--
-- A GREET is untrusted. Comm has checked its sender is who it says, on the
-- guild route, with a full name and a line number. It counts only for a
-- login this copy saw, while that login is tracked (LOGIN_TTL), once per
-- sender, and never from the player who logged in. A GREET can only make
-- this copy pick another line or leave the hello to copies that announced
-- first, so a forged, early or late one can never stop every hello: the
-- first copy to announce counts nothing before itself.
local _, ns = ...
local Util = ns.Util

local GuildHellos = {}
ns.GuildHellos = GuildHellos

GuildHellos.STAGGER_MIN = 1  -- seconds added to the Guild Login delay, at random
GuildHellos.STAGGER_MAX = 8
GuildHellos.ECHO_WAIT = 15 -- seconds our GREET may take to come back: past Comm's longest queue wait (10)
GuildHellos.LOGIN_TTL = 120  -- seconds a login is tracked: past the roster wait, the longest delay and ECHO_WAIT
GuildHellos.MAX_LOGINS = 100 -- logins tracked at once; the oldest goes first
GuildHellos.MAX_GREETS = 40  -- other copies' GREETs kept for one login

-- Overridable so tests can make the stagger deterministic: () -> [0, 1).
GuildHellos.random = math.random

-- [full name] = { at, greets = { [sender] = line }, order = { { line } } as they came, count,
--   lines = { [line] = true }, crowd = Comm.CrowdDrops() at the login, mine = { line, go, drop } }
local logins, loginCount = {}, 0

local function Forget(name)
    if logins[name] then
        logins[name] = nil
        loginCount = loginCount - 1
    end
end

-- Tracked, and not past LOGIN_TTL (or from a clock that went backwards).
local function Live(name)
    local login = logins[name]
    if not login then return nil end
    local age = GetTime() - login.at
    if age > GuildHellos.LOGIN_TTL or age < 0 then
        Forget(name)
        return nil
    end
    return login
end

-- Room for one more: forget expired logins, then the oldest.
local function MakeRoom()
    local oldest
    for name in pairs(logins) do
        local login = Live(name)
        if login and (not oldest or login.at < logins[oldest].at) then oldest = name end
    end
    if loginCount >= GuildHellos.MAX_LOGINS and oldest then Forget(oldest) end
end

-- A guildmate came online (Greeter, before it knows whether to greet). A
-- relog starts afresh: GREETs for the last login don't count for this one.
function GuildHellos.OnLogin(name)
    if not logins[name] and loginCount >= GuildHellos.MAX_LOGINS then MakeRoom() end
    if not logins[name] then loginCount = loginCount + 1 end
    logins[name] = { at = GetTime(), greets = {}, order = {}, count = 0, lines = {}, crowd = ns.Comm.CrowdDrops() }
end

-- How many other copies' GREETs were counted for a login being tracked, or nil.
function GuildHellos.Heard(name)
    local login = Live(name)
    return login and login.count
end

function GuildHellos.Tracked()
    for name in pairs(logins) do Live(name) end
    return loginCount
end

-- Seconds a greeting waits on top of the Guild Login delay.
function GuildHellos.Stagger()
    local span = GuildHellos.STAGGER_MAX - GuildHellos.STAGGER_MIN
    return GuildHellos.STAGGER_MIN + span * GuildHellos.random()
end

-- The cap K: the most copies that greet one login. Read through its limits:
-- settings damaged since loading can't turn the cap off.
local function Cap()
    local limits = ns.Config.LIMITS.maxGreeters
    return Util.ClampNumber(ns.db.guildLogin.maxGreeters, limits.min, limits.max,
        ns.Config.DEFAULTS.guildLogin.maxGreeters)
end

local function Log(fmt, ...)
    ns.Diag.Log("guildLogin", fmt, ...)
end

-- Whether a GREET can go out and come back: otherwise the stagger is all
-- there is. Inside an instance (or unreadable) addons may not message
-- other players (#32).
local function ChannelOpen()
    if not ns.Comm.Ready() then return false, "the hidden channel is closed" end
    -- Without our own name, a GREET can't be sent, nor told apart when it's back.
    if not Util.UnitFullName("player") then return false, "can't read your name" end
    local inGuild, secret = Util.Readable(IsInGuild())
    if secret or not inGuild then return false, "the game doesn't say you're in a guild" end
    if ns.ChatQueue.InChatLockdown() then return false, "chat lockdown" end
    if Util.ReadGameValues(IsInInstance) ~= false then return false, "inside an instance" end
    return true
end

-- Our line, or another if some other copy announced it.
local function FreeLine(login, line)
    if line and not login.lines[line] then return line end
    local _, other = ns.Messages.Pick("guildLogin", ns.db.guildLogin.messages, login.lines)
    return other or line
end

-- After the delay and stagger, with the line Announcer picked: claim a
-- place, or greet at once without the channel, or drop it.
function GuildHellos.Hold(name, line, go, drop)
    local login = Live(name)
    if not login then return drop("lost track of this login") end
    if login.mine then return drop("already greeting this login") end
    if login.count >= Cap() then
        return drop(string.format("%d other copies already greet them (most: %d)", login.count, Cap()))
    end
    local open, why = ChannelOpen()
    if not open then
        Log("greeting %s with the random wait only: %s", name, why)
        return go(FreeLine(login, line))
    end
    if ns.Comm.CrowdDrops() ~= login.crowd then
        return drop("addon messages were dropped in a crowd; can't count the other copies")
    end
    line = FreeLine(login, line)
    local sent, sendWhy = ns.Comm.SendGreet(name, line)
    if not sent then return drop("couldn't announce it: " .. tostring(sendWhy)) end
    local mine = { line = line, go = go, drop = drop }
    login.mine = mine
    Log("announced greeting %s with line %d", name, line)
    C_Timer.After(GuildHellos.ECHO_WAIT, ns.Diag.Wrap(function()
        if mine.done then return end
        mine.done = true
        drop("my announcement never came back")
    end))
end

-- The lowest line number in neither set, or nil.
local function Lowest(a, b)
    for n = 1, ns.Config.NUM_MESSAGES do
        if not a[n] and not b[n] then return n end
    end
end

-- The lines copies that announced before us will say: its own line, or if
-- a copy before it took that, the lowest number none up to it announced or
-- took. Every copy sees the same order, so all work these out the same,
-- even for copies that announced the same line at the same moment.
local function Taken(login)
    local taken, announced = {}, {}
    for _, greet in ipairs(login.order) do
        announced[greet.line] = true
        local line = greet.line
        if taken[line] then line = Lowest(taken, announced) end
        if line then taken[line] = true end
    end
    return taken, announced
end

-- Our line by the same rule, if it isn't blank here; else any line no copy
-- before us took.
local function OurLine(login, line)
    local taken, announced = Taken(login)
    if not taken[line] then return line end
    announced[line] = true
    local lowest = Lowest(taken, announced)
    local text = lowest and ns.db.guildLogin.messages[lowest]
    if type(text) == "string" and text:find("%S") then return lowest end
    local _, other = ns.Messages.Pick("guildLogin", ns.db.guildLogin.messages, taken)
    return other or line
end

-- Our own GREET is back: every GREET counted so far came first.
local function Decide(name, login)
    local mine = login.mine
    mine.done = true
    if ns.Comm.CrowdDrops() ~= login.crowd then
        return mine.drop("addon messages were dropped in a crowd; can't count the other copies")
    end
    if login.count >= Cap() then
        return mine.drop(string.format("%d other copies announced first (most: %d)", login.count, Cap()))
    end
    Log("greeting %s: %d other copies announced first", name, login.count)
    mine.go(OurLine(login, mine.line))
end

-- Comm's GREET handler. sender: a full name Comm checked (ours for our own
-- GREET back); name: the login, a full name; line: 1 to NUM_MESSAGES.
function GuildHellos.OnGreet(sender, name, line)
    local login = Live(name)
    if not login then return Log("ignored %s's greeting of %s: not a login I'm tracking", sender, name) end
    if sender == Util.UnitFullName("player") then
        local mine = login.mine
        if mine and not mine.done and mine.line == line then Decide(name, login) end
        return
    end
    if sender == name then return Log("ignored %s's greeting of themselves", sender) end
    if login.greets[sender] or login.count >= GuildHellos.MAX_GREETS then return end
    login.greets[sender] = line
    login.order[#login.order + 1] = { line = line }
    login.count = login.count + 1
    login.lines[line] = true
end
