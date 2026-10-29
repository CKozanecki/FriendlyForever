-- Buff exchanges (#36): one thank-you each way, sent after the last buff.
--
-- An exchange with a player starts with the first buff in either direction
-- (theirs reaching you, or yours reaching them) and ends GAP seconds after
-- its last one. Their buffs keep joining one thank-you (BuffTracker.lua),
-- and that thank-you is held, not sent, while the exchange is still going:
--   * never sooner than SETTLE seconds after the last buff either way, so a
--     chain of casts (one per global cooldown) finishes first;
--   * while the buff-back button is armed for them: up to HOLD_CAP seconds
--     after the last buff either way, or, once their copy has told us its
--     plan, until you have cast it or let it go;
--   * while their copy's plan says buffs are still to come.
-- It always goes out at most MAX_DELAY seconds after the first buff it
-- thanks for: a lost message or a player walking off never stops it. Once
-- it has gone, their later buffs in the same exchange aren't thanked again.
--
-- The plan: each copy whispers PLAN over the hidden channel (Comm.lua) with
-- the buffs it will still give that player, which is what its buff-back
-- button holds for them ("-" for none): once as the exchange starts, then
-- each time that changes. Hearing one says their copy is there, so your
-- armed button then holds the thank-you until you cast or let go. It is
-- untrusted: it can only hold your thank-you to its own sender, never past
-- MAX_DELAY. A plan buff that arrives is crossed off.
--
-- Exchanges are kept in memory only, at most MAX_EXCHANGES at once.
local _, ns = ...
local Exchange = {}
ns.Exchange = Exchange

Exchange.SETTLE = 2              -- seconds after the last buff either way before a thank-you goes
Exchange.HOLD_CAP = 5            -- seconds after the last buff either way an armed button holds it, planless
Exchange.MAX_DELAY = 30          -- seconds after the first buff it thanks for that a thank-you always goes
Exchange.GAP = 10                -- seconds without a buff either way that end an exchange
Exchange.TICK = 1                -- seconds between checks while any exchange is open
Exchange.MAX_EXCHANGES = 50      -- exchanges kept at once; the oldest goes first
Exchange.MAX_PLANS_SENT = 4      -- plans sent to one player per exchange
Exchange.NONE = "-"              -- a plan of no buffs (no buff key has a dash)

-- [full name] = {
--   lastBuff = GetTime() of the last buff either way,
--   theirPlan = { [buff key] = true } still to come, or nil before any plan,
--   sentPlan = the plan text last sent them (nil before the first), plansSent = how many,
--   thanked = true once this exchange's thank-you has gone,
--   held = { firstAt, goes = { go, ... } } for the thank-you waiting (its
--          line and its /thank each wait), or nil,
-- }
local exchanges = {}
local tickAt -- GetTime() the next tick is due, or nil

local function Count()
    local n = 0
    for _ in pairs(exchanges) do n = n + 1 end
    return n
end

-- Let a held thank-you go: it is this exchange's one.
local function Release(name, ex, why)
    local held = ex.held
    ex.held, ex.thanked = nil, true
    ns.Diag.Log("buff", "thank-you to %s goes now: %s", name, why)
    -- Each on its own, so one's error can't keep the others (or the tick) back.
    for _, go in ipairs(held.goes) do ns.Diag.Call(go) end
end

-- Room for one more: the exchange with the oldest last buff goes, and a
-- thank-you it held goes out at once.
local function MakeRoom()
    if Count() < Exchange.MAX_EXCHANGES then return end
    local oldest
    for name, ex in pairs(exchanges) do
        if not oldest or ex.lastBuff < exchanges[oldest].lastBuff then oldest = name end
    end
    local ex = exchanges[oldest]
    exchanges[oldest] = nil
    if ex.held then Release(oldest, ex, "too many exchanges at once") end
end

local Tick

-- A tick is kept due within TICK. One due later than that was scheduled
-- before the clock went backwards: another is scheduled now (the late one
-- is a harmless extra tick).
local function ScheduleTick()
    local now = GetTime()
    if tickAt and tickAt - now <= Exchange.TICK then return end
    tickAt = now + Exchange.TICK
    C_Timer.After(Exchange.TICK, ns.Diag.Wrap(Tick))
end

-- The exchange with this player, started now if there is none open.
local function Touch(name)
    local now = GetTime()
    local ex = exchanges[name]
    if not ex then
        MakeRoom()
        ex = { lastBuff = now, plansSent = 0 }
        exchanges[name] = ex
    end
    ex.lastBuff = now
    ScheduleTick()
    return ex
end

-- The buff key the buff-back button holds for this player, or nil.
local function Intent(name)
    local armed = ns.BuffButton.ArmedOffer()
    if armed and armed.name == name then return armed.buff.key end
end

local function Busy(ex, name, now)
    local quiet = now - ex.lastBuff
    if quiet < Exchange.SETTLE then return "a buff a moment ago" end
    local planned = ex.theirPlan ~= nil
    if planned and next(ex.theirPlan) then return "their copy plans more buffs" end
    if Intent(name) and (planned or quiet < Exchange.HOLD_CAP) then return "the button is armed for them" end
end

local function SendPlan(name, ex)
    local plan = Intent(name) or Exchange.NONE
    if plan == ex.sentPlan or ex.plansSent >= Exchange.MAX_PLANS_SENT then return end
    ex.sentPlan, ex.plansSent = plan, ex.plansSent + 1
    ns.Comm.SendPlan(name, plan)
end

-- Every TICK while any exchange is open: send changed plans, let thank-yous
-- go, and end exchanges that are over.
function Tick()
    tickAt = nil
    local now = GetTime()
    for name, ex in pairs(exchanges) do
        if ex.held then
            -- A clock that went back before the first buff held can't time
            -- the wait: the thank-you goes.
            if now < ex.held.firstAt or now - ex.held.firstAt >= Exchange.MAX_DELAY then
                Release(name, ex, "the longest wait is up")
            elseif not Busy(ex, name, now) then
                Release(name, ex, "the exchange is done")
            end
        end
        if not ex.held and now - ex.lastBuff >= Exchange.GAP then
            exchanges[name] = nil
        else
            SendPlan(name, ex)
        end
    end
    if next(exchanges) then ScheduleTick() end
end

-- A buff of yours reached them (Offers.MarkReturned: the button or by hand).
-- Your group is never thanked, so a buff to a member (or to someone the game
-- won't say isn't one) opens nothing: no plans go to a raid you buff.
function Exchange.NoteGiven(name)
    if ns.Greeter.IsInMyGroup(name) ~= false then return end
    Touch(name)
end

-- A buff from them reached you (spellId: a readable number, or nil).
-- Returns true when this exchange has already had its thank-you, so this
-- buff gets none.
function Exchange.NoteReceived(name, spellId)
    local ex = Touch(name)
    local buff = ns.BuffData.ForAura(spellId)
    if buff and ex.theirPlan then ex.theirPlan[buff.key] = nil end
    return ex.thanked == true
end

-- Hold the thank-you for the buffs from them since firstAt: go() queues
-- it (or its /thank), once, when the exchange is done: now, if nothing
-- holds it. With no exchange open (it ended during the delay), it goes now.
function Exchange.Hold(name, firstAt, go)
    local ex = exchanges[name]
    if not ex then return go() end
    ex.held = ex.held or { firstAt = firstAt, goes = {} }
    table.insert(ex.held.goes, go)
    if Busy(ex, name, GetTime()) then return ScheduleTick() end
    Release(name, ex, "nothing holds it")
end

-- PLAN from their copy (Comm.lua): the buff keys it will still give you,
-- as text that passed Comm.Field.KeyList. Untrusted; it can only hold your
-- thank-you to its sender, and only while an exchange with them is open.
function Exchange.OnPlan(sender, text)
    local ex = exchanges[sender]
    if not ex then return end
    local plan = {}
    for key in text:gmatch("[^,]+") do
        if ns.BuffData.ByKey(key) then plan[key] = true end
    end
    ex.theirPlan = plan
    ns.Diag.Log("buff", "%s's copy plans: %s", sender, text)
end

function Exchange.Count()
    return Count()
end
