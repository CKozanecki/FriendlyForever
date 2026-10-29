-- A rolling-window counter over a plain list: how many things happened in
-- the last `window` seconds, so a caller can refuse the next one once a
-- limit is reached. ChatQueue keeps one list per chat type for the
-- lines-per-minute cap (#35), with a copy in the saved variables.
--
-- Each entry is timed on two clocks that are read separately: the game's
-- GetTime() (`t`) and the wall clock, time() (`w`). Real time moves both;
-- a jump moves one. So an entry ages out only once BOTH say the window has
-- passed, and either clock can jump without letting more through:
--   * a time from "the future" (that clock went back) is moved to now, so it
--     still counts, and ages out within one window: never blocked for good;
--   * a jump forward of one clock is held by the other;
--   * an entry, or a time in one, that isn't usable counts as now.
local _, ns = ...

local RateLimit = {}
ns.RateLimit = RateLimit

local function Usable(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end
RateLimit.Usable = Usable

-- A clock reading for an entry: the reading if usable and not ahead of now.
local function Since(reading, now)
    if not Usable(reading) or reading > now then return now end
    return reading
end

-- Forget what has aged out on both clocks, and bring back anything ahead
-- of now. Entries are cleaned in place, so a damaged list repairs itself.
local function Prune(entries, window, t, w)
    local kept, n = 0, #entries
    for i = 1, n do
        local e = entries[i]
        local et, ew
        if type(e) == "table" then et, ew = Since(e.t, t), Since(e.w, w) else et, ew = t, w end
        if t - et < window or w - ew < window then
            kept = kept + 1
            entries[kept] = { t = et, w = ew }
        end
    end
    for i = n, kept + 1, -1 do entries[i] = nil end
end

-- How many happened in the window ending now (all of them, if either clock
-- can't be read).
function RateLimit.Count(entries, window, t, w)
    if Usable(t) and Usable(w) then Prune(entries, window, t, w) end
    return #entries
end

-- True when one more fits under limit. An unreadable clock or limit says no:
-- the caller tries again later.
function RateLimit.HasRoom(entries, window, limit, t, w)
    if not Usable(t) or not Usable(w) or not Usable(limit) then return false end
    return RateLimit.Count(entries, window, t, w) < limit
end

function RateLimit.Note(entries, window, t, w)
    if not Usable(t) or not Usable(w) then return end
    Prune(entries, window, t, w)
    entries[#entries + 1] = { t = t, w = w }
end
