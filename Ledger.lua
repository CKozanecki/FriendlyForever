-- The favour ledger: who buffed you, with what, whether you thanked them
-- (and if not, why), and whether you buffed them back. Kept in the saved settings, newest last, with today's
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

-- Titles your manners earn, by favours returned. Highest reached is yours.
Ledger.TITLES = {
    { at = 10, title = "Courteous" },
    { at = 25, title = "Well-Mannered" },
    { at = 50, title = "Gracious" },
    { at = 100, title = "Gallant" },
    { at = 250, title = "Benevolent" },
    { at = 500, title = "Paragon of Courtesy" },
    { at = 1000, title = "Friend to All Azeroth" },
}

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
                    local clean = {
                        t = math.floor(e.t), who = who, buffs = buffs, result = result, note = CleanText(e.note),
                        returned = CleanText(e.returned), returnNote = CleanText(e.returnNote),
                        cleared = e.cleared == true or nil,
                    }
                    -- The same table, cleaned: a favour still owed holds it,
                    -- and must still find it after a repair mid-session.
                    for key in pairs(e) do e[key] = nil end
                    for key, value in pairs(clean) do e[key] = value end
                    entries[#entries + 1] = e
                end
            end
        end
    end
    while #entries > Ledger.MAX_ENTRIES do table.remove(entries, 1) end

    local totals = type(ledger.totals) == "table" and ledger.totals or {}
    local today = type(ledger.today) == "table" and ledger.today or {}
    return {
        entries = entries,
        totals = { received = Count(totals.received), thanked = Count(totals.thanked),
            returned = Count(totals.returned) },
        today = {
            day = type(today.day) == "string" and today.day or "",
            received = Count(today.received), thanked = Count(today.thanked), returned = Count(today.returned),
        },
    }
end

-- Whether the ledger has the shape the counting code relies on. Checked on
-- every use (it's a few type checks), so damage done mid-session is
-- repaired before it can break a count.
local function Healthy(ledger)
    if type(ledger) ~= "table" or type(ledger.entries) ~= "table" then return false end
    local totals, today = ledger.totals, ledger.today
    if type(totals) ~= "table" or type(today) ~= "table" or type(today.day) ~= "string" then return false end
    for _, key in ipairs({ "received", "thanked", "returned" }) do
        if type(totals[key]) ~= "number" or type(today[key]) ~= "number" then return false end
    end
    return true
end

local function Data()
    if not Healthy(ns.db.ledger) then
        ns.Diag.Log("ledger", "the ledger was damaged; repaired")
        ns.db.ledger = Ledger.Validate(ns.db.ledger)
    end
    return ns.db.ledger
end

-- Today's counts, started afresh on a new day.
local function TodayCounts()
    local today = Data().today
    local day = Today()
    if today.day ~= day then
        today.day, today.received, today.thanked, today.returned = day, 0, 0, 0
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

-- You buffed them back with spell (its name).
function Ledger.Returned(entry, spell)
    if entry.returned then return end
    entry.returned, entry.returnNote = CleanText(spell) or "a buff", nil
    if entry.cleared then return end
    local data = Data()
    data.totals.returned = data.totals.returned + 1
    local today = TodayCounts()
    today.returned = today.returned + 1
end

-- Why a favour wasn't returned ("you let it go", "the time to return it ran out").
function Ledger.NoteNotReturned(entry, note)
    if entry.returned then return end
    entry.returnNote = CleanText(note)
end

-- Your standing: { title (nil before the first), nextTitle (nil at the top),
-- returnsToNext (favours still to return for it) }.
function Ledger.Title()
    local returned = Data().totals.returned
    local title, nextTitle
    for _, t in ipairs(Ledger.TITLES) do
        if returned >= t.at then
            title = t.title
        elseif not nextTitle then
            nextTitle = t
        end
    end
    return {
        title = title,
        nextTitle = nextTitle and nextTitle.title,
        returnsToNext = nextTitle and (nextTitle.at - returned),
    }
end

function Ledger.Clear()
    for _, e in ipairs(Data().entries) do e.cleared = true end
    ns.db.ledger = Ledger.Validate(nil)
end

function Ledger.Summary()
    local data = Data()
    local today = TodayCounts()
    return {
        todayReceived = today.received, todayThanked = today.thanked, todayReturned = today.returned,
        received = data.totals.received, thanked = data.totals.thanked, returned = data.totals.returned,
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
        if e.returned then
            result = result .. ", returned " .. e.returned
        elseif e.returnNote then
            result = result .. ", not returned (" .. e.returnNote .. ")"
        end
        out[#out + 1] = string.format("%s - %s - %s - %s", Ledger.WhoText(e.who), buffs, result,
            Ledger.Ago(math.max(0, now - e.t)))
    end
    return out
end
