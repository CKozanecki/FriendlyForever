-- "Don't message the same player again for N seconds" bookkeeping.
local _, ns = ...

local Cooldowns = {}
ns.Cooldowns = Cooldowns

-- No cooldown can be longer than this, so older stamps are safe to forget.
local MAX_TRACKED_AGE = 3600
local PRUNE_EVERY = 200

local stamps = {}
local inserts = 0

local function Prune(now)
    for key, t in pairs(stamps) do
        if now - t >= MAX_TRACKED_AGE then stamps[key] = nil end
    end
end

-- Returns true (and starts the cooldown) if key is not on cooldown.
function Cooldowns.TryClaim(key, seconds, now)
    local last = stamps[key]
    if last and now - last < seconds then return false end
    stamps[key] = now
    inserts = inserts + 1
    if inserts % PRUNE_EVERY == 0 then Prune(now) end
    return true
end

function Cooldowns.Count()
    local n = 0
    for _ in pairs(stamps) do n = n + 1 end
    return n
end
