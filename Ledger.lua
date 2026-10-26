-- The favour ledger: who buffed you, with what, and whether you thanked them
-- (and if not, why). Kept in the saved settings, newest last, with today's
-- counts and all-time totals. Only buffs from outside your group are favours:
-- the same ones Buff Thanks looks at.
local _, ns = ...
local Util = ns.Util

local Ledger = {}
ns.Ledger = Ledger

Ledger.MAX_ENTRIES = 200
Ledger.MAX_BUFFS = 8      -- buff names kept per entry
Ledger.MAX_TEXT = 100     -- bytes kept of a buff name or a note
Ledger.UNKNOWN = "?unknown"

-- What happened to a favour.
Ledger.PENDING = "pending"         -- the thank-you is still waiting to go out
Ledger.THANKED = "thanked"
Ledger.NOT_THANKED = "not thanked"
local RESULTS = { [Ledger.PENDING] = true, [Ledger.THANKED] = true, [Ledger.NOT_THANKED] = true }

local function Today()
    return date("%Y-%m-%d")
end

local function CleanText(text)
    if type(text) ~= "string" then return nil end
    text = Util.StripChat(text)
    if text == "" then return nil end
    return Util.Utf8Truncate(text, Ledger.MAX_TEXT)
end

local function Count(value)
    return Util.ClampNumber(value, 0, 2 ^ 31, 0)
end

-- Saved data is checked like every other setting: a hand-edited or damaged
-- file loses what can't be read and keeps the rest.
function Ledger.Validate(saved)
    local ledger = type(saved) == "table" and saved or {}
    local entries = {}
    if type(ledger.entries) == "table" then
        for _, e in ipairs(ledger.entries) do
            if type(e) == "table" and type(e.t) == "number" and e.t == e.t
                and e.t ~= math.huge and e.t ~= -math.huge then
                local who = e.who == Ledger.UNKNOWN and Ledger.UNKNOWN or Util.FullName(e.who)
                if who then
                    local buffs = {}
                    if type(e.buffs) == "table" then
                        for _, b in ipairs(e.buffs) do
                            local name = CleanText(b)
                            if name and #buffs < Ledger.MAX_BUFFS then buffs[#buffs + 1] = name end
                        end
                    end
                    local result = RESULTS[e.result] and e.result or Ledger.NOT_THANKED
                    -- A favour still pending when the game closed never got its thanks.
                    if result == Ledger.PENDING then result = Ledger.NOT_THANKED end
                    entries[#entries + 1] = {
                        t = math.floor(e.t), who = who, buffs = buffs, result = result, note = CleanText(e.note),
                    }
                end
            end
        end
    end
    while #entries > Ledger.MAX_ENTRIES do table.remove(entries, 1) end

    local totals = type(ledger.totals) == "table" and ledger.totals or {}
    local today = type(ledger.today) == "table" and ledger.today or {}
    return {
        entries = entries,
        totals = { received = Count(totals.received), thanked = Count(totals.thanked) },
        today = {
            day = type(today.day) == "string" and today.day or "",
            received = Count(today.received), thanked = Count(today.thanked),
        },
    }
end

local function Data()
    return ns.db.ledger
end

-- Today's counts, started afresh on a new day.
local function TodayCounts()
    local today = Data().today
    local day = Today()
    if today.day ~= day then
        today.day, today.received, today.thanked = day, 0, 0
    end
    return today
end

-- A new favour from who (full name, or Ledger.UNKNOWN). Returns the entry, to
-- pass to AddBuff and Settle.
function Ledger.Received(who, buffName)
    local data = Data()
    local entry = { t = time(), who = who, buffs = {}, result = Ledger.PENDING }
    Ledger.AddBuff(entry, buffName)
    data.entries[#data.entries + 1] = entry
    while #data.entries > Ledger.MAX_ENTRIES do table.remove(data.entries, 1) end
    data.totals.received = data.totals.received + 1
    local today = TodayCounts()
    today.received = today.received + 1
    return entry
end

function Ledger.AddBuff(entry, buffName)
    local name = CleanText(buffName)
    if not name or #entry.buffs >= Ledger.MAX_BUFFS then return end
    for _, b in ipairs(entry.buffs) do
        if b == name then return end
    end
    entry.buffs[#entry.buffs + 1] = name
end

-- thanked: true once a thank-you went out. A favour is thanked at most once,
-- so a second channel (emote and line) going out changes nothing.
-- note: why it wasn't thanked, in words.
function Ledger.Settle(entry, thanked, note)
    if entry.result == Ledger.THANKED then return end
    if thanked then
        entry.result, entry.note = Ledger.THANKED, nil
        -- A favour from before the ledger was cleared isn't counted again.
        if entry.cleared then return end
        local data = Data()
        data.totals.thanked = data.totals.thanked + 1
        local today = TodayCounts()
        today.thanked = today.thanked + 1
    else
        entry.result, entry.note = Ledger.NOT_THANKED, CleanText(note)
    end
end

function Ledger.Clear()
    for _, e in ipairs(Data().entries) do e.cleared = true end
    ns.db.ledger = Ledger.Validate(nil)
end

function Ledger.Summary()
    local data = Data()
    local today = TodayCounts()
    return {
        todayReceived = today.received, todayThanked = today.thanked,
        received = data.totals.received, thanked = data.totals.thanked,
        stored = #data.entries,
    }
end

-- "just now", "7 min ago", "2 hr ago", "3 days ago"
function Ledger.Ago(seconds)
    if seconds < 60 then return "just now" end
    if seconds < 3600 then return math.floor(seconds / 60) .. " min ago" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. " hr ago" end
    local days = math.floor(seconds / 86400)
    return days == 1 and "yesterday" or (days .. " days ago")
end

function Ledger.WhoText(who)
    if who == Ledger.UNKNOWN then return "Someone unnamed" end
    return Util.DisplayName(who)
end

-- One line per entry, newest first: "Nikki Shifts - Arcane Intellect - thanked - 7 min ago".
function Ledger.Lines(limit)
    local entries, out, now = Data().entries, {}, time()
    for i = #entries, math.max(1, #entries - (limit or 10) + 1), -1 do
        local e = entries[i]
        local buffs = #e.buffs > 0 and Util.JoinList(e.buffs) or "a buff"
        local result = e.result
        if e.result == Ledger.NOT_THANKED and e.note then result = result .. " (" .. e.note .. ")" end
        out[#out + 1] = string.format("%s - %s - %s - %s", Ledger.WhoText(e.who), buffs, result,
            Ledger.Ago(math.max(0, now - e.t)))
    end
    return out
end
