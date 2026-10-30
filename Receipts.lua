-- Buff receipts (#138): when your buff lands on a player outside your
-- group, your copy whispers theirs a RECEIPT over the hidden channel
-- (Comm.lua): "I just gave you this buff". Their copy uses it only to name
-- the caster of a buff whose caster the game wouldn't name (a stranger's
-- name or unit can be unreadable on Forever), so it can thank you by name
-- and offer your buff back.
--
-- A receipt is untrusted: a hint, never a trigger. It names the caster of
-- one buff that really arrived, of the same key, whose caster couldn't be
-- named: up to WINDOW seconds after the receipt, or WAIT before it (a
-- message may beat the aura or follow it). Such a buff waits WAIT seconds
-- for its receipt; with none, it goes on as it would have (thanked as
-- "friend", or not at all). Two different players' receipts for one buff
-- name nobody, and a player's receipt for a buff the game named them for
-- names nothing else. The name used is the server's sender name, which
-- Comm has already validated; a receipt's own text is a buff key and a
-- version, and never goes anywhere else. A receipt from someone on your
-- ignore list or in your group, or with no matching unnamed buff, changes
-- nothing.
--
-- Sending: one receipt per cast that the game says landed on them
-- (UNIT_SPELLCAST_SUCCEEDED for the cast UNIT_SPELLCAST_SENT named them
-- in). Never to your group (the group's own routes carry what it needs), to
-- yourself or to someone you ignore, never inside an instance (addons may
-- not message other players there under Midnight's rules: #32) or during
-- chat lockdown (Comm sends nothing then), and only while Buff Thanks and "Tell players I buff that
-- it was me" are on. Comm's limiter and queue apply.
local _, ns = ...
local Util = ns.Util
local Read = Util.ReadGameValues

local Receipts = {}
ns.Receipts = Receipts

Receipts.WAIT = 2          -- seconds a buff with no named caster waits for its receipt
Receipts.WINDOW = 5        -- seconds a receipt may come before the buff it names
Receipts.MAX_RECEIPTS = 20 -- receipts kept at once; the oldest goes first
Receipts.MAX_WAITING = 20  -- unnamed buffs waiting at once; past that, a new one doesn't wait

local receipts = {} -- oldest first: { sender, key, at, used }
-- Buffs the game named the caster of, with no receipt from them yet: their
-- receipt, when it comes, is for that buff (#138). Oldest first: { sender, key, at, used }.
local named = {}
local waiting = 0

------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------

-- Whether the game says you're outside every instance. Unreadable counts
-- as inside.
local function OutsideInstances()
    return Read(IsInInstance) == false
end

-- A buff of yours (buff: BuffData's entry) landed on them (a full name).
-- Returns true when a receipt was queued.
function Receipts.Send(name, buff)
    if not ns.db or not ns.db.enabled or ns.db.buff.enabled ~= true or ns.db.buff.receipts ~= true then
        return false
    end
    if type(buff) ~= "table" or not ns.BuffData.ByKey(buff.key) then return false end
    name = Util.FullName(name)
    if not name or name == Util.UnitFullName("player") then return false end
    -- In your group, or the game won't say: no whisper.
    if ns.Greeter.IsInMyGroup(name) ~= false or ns.Ignore.Has(name) then return false end
    -- Chat lockdown: Comm sends nothing then.
    if not OutsideInstances() then return false end
    local ok, why = ns.Comm.SendReceipt(name, buff.key)
    if ok then
        ns.Diag.Log("comm", "told %s's copy the %s was mine", name, buff.key)
    else
        ns.Diag.Log("comm", "no receipt to %s: %s", name, why)
    end
    return ok
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------

-- Who mustn't be named by a receipt: anyone you ignore, and your group
-- (never thanked), or anyone the game won't say isn't in it.
local function Unwanted(sender)
    return ns.Ignore.Has(sender) or ns.Greeter.IsInMyGroup(sender) ~= false
end

-- Receipts older than WINDOW + WAIT are forgotten: at a buff's WAIT, that
-- is any from more than WINDOW before it arrived.
local function Prune(list, now)
    for i = #list, 1, -1 do
        local r = list[i]
        if now < r.at or now - r.at > Receipts.WINDOW + Receipts.WAIT then table.remove(list, i) end
    end
end

-- Keep an entry in a list of at most MAX_RECEIPTS, the oldest going first.
local function Keep(list, entry)
    list[#list + 1] = entry
    while #list > Receipts.MAX_RECEIPTS do table.remove(list, 1) end
end

-- The oldest unused entry from sender for key, or nil.
local function Unused(list, sender, key)
    for _, r in ipairs(list) do
        if not r.used and r.sender == sender and r.key == key then return r end
    end
end

-- RECEIPT from their copy (Comm.lua): sender is the server's name for
-- them, key passed Comm.Field.Key. Kept, to name a matching buff.
function Receipts.OnReceipt(sender, key)
    if not ns.BuffData.ByKey(key) then
        return ns.Diag.Log("comm", "receipt from %s for an unknown buff: dropped", sender)
    end
    if Unwanted(sender) then
        return ns.Diag.Log("comm", "receipt from %s: ignored or in your group, dropped", sender)
    end
    local now = GetTime()
    Prune(named, now)
    local buff = Unused(named, sender, key)
    if buff then
        -- For a buff the game already named them for: it names nothing else.
        buff.used = true
        return ns.Diag.Log("comm", "receipt from %s for a buff the game named them for", sender)
    end
    Prune(receipts, now)
    Keep(receipts, { sender = sender, key = key, at = now })
end

-- The game named the caster of a buff of this key (a full name). Their
-- receipt for it, before or after, is used up by it, so it can't name the
-- caster of someone else's buff.
function Receipts.NoteNamed(sender, key)
    local now = GetTime()
    Prune(receipts, now)
    local r = Unused(receipts, sender, key)
    if r then
        r.used = true
        return
    end
    Prune(named, now)
    Keep(named, { sender = sender, key = key, at = now })
end

-- Whether receipts can arrive: the hidden channel is open.
function Receipts.Listening()
    return ns.Comm.Ready()
end

-- The one player whose receipt names a buff of this key that arrived WAIT
-- seconds ago, or nil (none, or more than one). Their receipt is used up.
local function Claim(key, now)
    Prune(receipts, now)
    local found, sender
    for _, r in ipairs(receipts) do
        if not r.used and r.key == key and not Unwanted(r.sender) then
            if sender and r.sender ~= sender then
                ns.Diag.Log("buff", "receipts from %s and %s for one %s: naming nobody", sender, r.sender, key)
                return nil
            end
            found, sender = found or r, r.sender
        end
    end
    if found then
        found.used = true
        ns.Diag.Count("receiptsUsed")
    end
    return sender
end

-- A buff of this key arrived with no caster the game would name. done(name)
-- is called after WAIT seconds with the player a receipt names, or nil.
-- Without the channel, or with too many waiting, it is called now with nil.
function Receipts.Await(key, done)
    if not Receipts.Listening() or waiting >= Receipts.MAX_WAITING then return done(nil) end
    waiting = waiting + 1
    C_Timer.After(Receipts.WAIT, ns.Diag.Wrap(function()
        waiting = waiting - 1
        done(Claim(key, GetTime()))
    end))
end

-- Whether any buff is waiting for its receipt.
function Receipts.Waiting()
    return waiting > 0
end

function Receipts.Count()
    return #receipts
end
