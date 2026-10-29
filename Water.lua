-- Near water (#136): Unending Breath (warlocks) and Water Breathing
-- (shamans) only help underwater, so buff back and buff mode offer them only
-- while you're near water, unless the setting "Water breathing: only near
-- water" is off. Buff thanks don't ask: a player who gives you one is still
-- thanked.
--
-- You're near water while the game says you're swimming (IsSwimming) or
-- underwater (IsSubmerged), while your breath bar (the BREATH mirror timer)
-- is showing, in an underwater dungeon, and for GRACE_SECONDS after the
-- last time any of these said so, so a quick hop out doesn't drop it.
--
-- The grace period counts from the last reading the addon took: it looks
-- every SAMPLE_SECONDS while you know a water buff (no event says you're
-- swimming), each time the button re-checks, and when your breath bar shows
-- or goes.
--
-- Only you are read: the game has no call that says whether another player
-- is swimming. When none of the readings can be read (missing, or secret),
-- you count as not near water, grace or not: the pessimistic choice.
-- Forever's APIs and the dungeons' IDs are launch checks (#50).
local _, ns = ...
local Util = ns.Util

local Water = {}
ns.Water = Water

Water.GRACE_SECONDS = 120   -- still near water this long after leaving it
Water.SAMPLE_SECONDS = 5    -- how often it looks while you know a water buff
Water.MIRROR_TIMERS = 3     -- the game's mirror timers (MIRRORTIMER_NUMTIMERS): breath, fatigue, feign death
Water.BREATH_TIMER = "BREATH"
-- The names a mirror timer can have; anything else is a reading that can't
-- be trusted ("UNKNOWN" is an unused timer).
Water.TIMER_NAMES = { BREATH = true, EXHAUSTION = true, FEIGNDEATH = true, UNKNOWN = true }

-- Underwater dungeons, by instance ID (GetInstanceInfo's 8th value).
-- Blackfathom Deeps is Classic Era's 48: Forever's is a launch check (#50).
Water.UNDERWATER_INSTANCES = { [48] = "Blackfathom Deeps" }
-- By their English name, while the ID isn't known: The Drowned City is new
-- on Forever (off Stranglethorn Vale), so its ID is a launch check (#50).
-- On a client in another language it isn't matched by name.
Water.UNDERWATER_INSTANCE_NAMES = { ["The Drowned City"] = true }

local lastWetAt -- GetTime() of the last reading that said you were in the water
local frame

-- A game call's first result, or nil when it's missing, raises an error or
-- gives a secret.
local function ReadOne(fn, ...)
    return (Util.ReadGameValues(fn, ...))
end

-- A yes/no reading: true or false, or nil for anything else. Older clients
-- said 1 for yes.
local function YesNo(value)
    if value == true or value == 1 then return true end
    if value == false then return false end
end

-- Whether your breath bar is showing: true, false, or nil when no timer can
-- be read.
local function BreathShowing()
    local any = false
    for i = 1, Water.MIRROR_TIMERS do
        local name = ReadOne(GetMirrorTimerInfo, i)
        if Water.TIMER_NAMES[name] then
            any = true
            if name == Water.BREATH_TIMER then return true end
        end
    end
    if any then return false end
end

-- Whether you're in the water now: true, false, or nil when nothing can be
-- read. Any reading that says yes is enough.
local function InWater()
    local readings = { YesNo(ReadOne(IsSwimming)), YesNo(ReadOne(IsSubmerged)), BreathShowing() }
    local readable = false
    -- Any may be nil, so not ipairs.
    for i = 1, 3 do
        if readings[i] == true then return true end
        if readings[i] == false then readable = true end
    end
    if readable then return false end
end

-- The underwater dungeon you're in, or nil (none, or it can't be read).
function Water.Dungeon()
    local ok, name, instanceType, _, _, _, _, _, id = pcall(GetInstanceInfo)
    if not ok or Util.IsSecret(instanceType) or instanceType ~= "party" and instanceType ~= "raid" then return nil end
    -- A secret mustn't be used as a table key (the game raises an error).
    if not Util.IsSecret(id) and Water.UNDERWATER_INSTANCES[id] then
        return Water.UNDERWATER_INSTANCES[id]
    end
    if not Util.IsSecret(name) and Water.UNDERWATER_INSTANCE_NAMES[name] then
        return name
    end
end

-- Whether you're near water now (see the top of this file), and why: "in
-- the water", "in <dungeon>", "out of the water <n>s ago", or why not.
function Water.Near()
    local now = GetTime()
    local wet = InWater()
    if wet then
        lastWetAt = now
        return true, "in the water"
    end
    local dungeon = Water.Dungeon()
    if dungeon then return true, "in " .. dungeon end
    if wet == nil then return false, "can't tell whether you're in the water" end
    if lastWetAt and now - lastWetAt <= Water.GRACE_SECONDS then
        return true, string.format("out of the water %ds ago", math.floor(now - lastWetAt))
    end
    return false, "not near water"
end

-- Whether the setting holds water breathing back away from water. Read
-- defensively: settings damaged mid-session read as the default.
function Water.OnlyNear()
    local cfg = ns.db and ns.db.buffBack
    if type(cfg) == "table" and type(cfg.breathNearWater) == "boolean" then return cfg.breathNearWater end
    return ns.Config.DEFAULTS.buffBack.breathNearWater
end

-- buffs less the ones held back now (water buffs away from water), as a new
-- list; and the first one held back, if any.
function Water.Filter(buffs)
    local out, held = {}, nil
    local near -- read once, and only when a water buff asks
    for _, buff in ipairs(buffs) do
        local keep = true
        if buff.water and Water.OnlyNear() then
            if near == nil then near = Water.Near() and true or false end
            keep = near
        end
        if keep then out[#out + 1] = buff else held = held or buff end
    end
    return out, held
end

-- Why a held-back buff isn't offered, for the button and /friendly buffback.
function Water.HeldReason(buff)
    return (ns.BuffData.SpellName(buff) or buff.key) .. " waits until you're near water"
end

-- For /friendly status.
function Water.StatusLine()
    local near, why = Water.Near()
    return string.format("near water: %s (%s); water breathing %s", near and "yes" or "no", why,
        Water.OnlyNear() and "only near water" or "offered anywhere")
end

-- Your breath bar appearing or going: note it, and re-arm the button so a
-- dive offers water breathing at once.
local function OnMirrorTimer(name)
    if Util.IsSecret(name) or name ~= Water.BREATH_TIMER then return end
    lastWetAt = GetTime()
    ns.BuffButton.Refresh()
end

-- Whether it's worth looking: the addon is on, the setting holds water
-- buffs back, and you know one.
local function Wanted()
    if not (ns.db and ns.db.enabled and Water.OnlyNear()) then return false end
    for _, buff in ipairs(ns.BuffData.Mine()) do
        if buff.water then return true end
    end
    return false
end

local function Sample()
    C_Timer.After(Water.SAMPLE_SECONDS, ns.Diag.Wrap(Sample))
    if Wanted() then Water.Near() end
end

function Water.Create()
    if frame then return end
    -- Only a class with a water buff ever needs to look.
    for _, buff in ipairs(ns.BuffData.ClassBuffs()) do
        if buff.water then
            Sample()
            break
        end
    end
    frame = CreateFrame("Frame")
    frame:RegisterEvent("MIRROR_TIMER_START")
    frame:RegisterEvent("MIRROR_TIMER_STOP")
    frame:SetScript("OnEvent", function(_, _, name) ns.Diag.Call(OnMirrorTimer, name) end)
end
