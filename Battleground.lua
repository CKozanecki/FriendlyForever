-- Battlegrounds (#71): buffing in the preparation phase, then quiet.
--
-- In a battleground (IsInInstance() says "pvp"), before the gates open, buff
-- mode, its triggers and the buff-back button work as in any raid. Once the
-- battle has started the addon goes quiet for the rest of it:
--   buff mode ends, and nothing (a trigger or you) turns it on again;
--   the buff-back button is hidden, and no favours or group buffs are worked out;
--   buffs you get aren't tracked or thanked;
--   no lines are sent, except guild hellos, which go to guild chat.
-- Everything is back to normal once you leave, or the battleground ends.
-- With "Buff in the preparation phase" off, the preparation phase is quiet too.
--
-- The phase is read from the Preparation aura on you and from the
-- start-of-battle timer (START_TIMER). Which of these Forever gives is
-- checked at launch (#50). When neither says "preparation", the battle
-- counts as started: the quiet side is the safe side. Once it has surely
-- started (the timer ran out, the aura went away, or you died) it stays
-- started until you leave, so a Preparation aura given later can't open
-- the gates again. That memory doesn't survive a reload or relog, so after
-- one in a battleground the aura alone isn't trusted (a resurrection may
-- have given it): only the timer can say the gates are still closed.
--
-- A trigger refused because it's quiet (the group can be joined before the
-- phase can be read) is answered if the preparation phase opens
-- (BuffModeAuto.OnQuietEnded).
local _, ns = ...
local Util = ns.Util
local Read = Util.ReadGameValues

local Battleground = {}
ns.Battleground = Battleground

-- The Preparation aura before the gates open (Classic's ID; Forever's is
-- checked at launch, #50).
Battleground.PREPARATION_SPELL_IDS = { [44521] = true }
-- Auras looked through for it (the same bound as the rest of the addon).
Battleground.MAX_AURAS = 40
-- Message types still sent once the battle has started: they go to guild
-- chat, and aren't about the battleground.
Battleground.GUILD_TYPES = { guildLogin = true, guildJoin = true }

local frame
local started = false   -- the battle has surely started (latched until you leave)
local preparation       -- the Preparation aura on you: true, false, or nil (unread)
local seenPreparation = false -- it has been on you in this battleground
local distrustAura = false -- reloaded or logged in here: the aura alone proves nothing
local timerEndsAt       -- GetTime() the start-of-battle timer runs out, or nil
local wasQuiet = false  -- Quiet() as last seen by Update

function Battleground.InBattleground()
    local _, instanceType = Read(IsInInstance)
    return instanceType == "pvp"
end

local function Ended()
    return Read(GetBattlefieldWinner) ~= nil
end

local function Forget()
    started, preparation, seenPreparation, timerEndsAt = false, nil, false, nil
end

-- Whether the Preparation aura is on you: true, false, or nil when your
-- buffs can't be read.
local function ReadPreparation()
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not api then return nil end
    for i = 1, Battleground.MAX_AURAS do
        local ok, aura = pcall(api, "player", i, "HELPFUL")
        if not ok or Util.IsSecret(aura) then return nil end
        if aura == nil then return false end
        local id = aura.spellId
        if Util.IsSecret(id) then return nil end
        if Battleground.PREPARATION_SPELL_IDS[id] then return true end
    end
    return false
end

-- "none" (not in a battleground), "ended", "preparation" or "battle".
function Battleground.Phase()
    if not Battleground.InBattleground() then
        Forget()
        return "none"
    end
    if Ended() then return "ended" end
    if timerEndsAt and GetTime() >= timerEndsAt then started = true end
    if started then return "battle" end
    local timing = timerEndsAt ~= nil
    if (preparation == true and not distrustAura) or timing then return "preparation" end
    return "battle"
end

-- Whether the addon is quiet now: no buff work and no lines (but guild ones).
-- A setting damaged mid-session reads as off: the quiet side.
function Battleground.Quiet()
    if not ns.db then return false end
    local phase = Battleground.Phase()
    if phase == "battle" then return true end
    local cfg = ns.db.buffBack
    return phase == "preparation" and not (type(cfg) == "table" and cfg.bgPrepBuff == true)
end

-- Why the addon is quiet, in words for messages.
function Battleground.QuietReason()
    if Battleground.Phase() == "preparation" then return "buffing in a battleground's preparation phase is off" end
    return "the battle has started"
end

-- Whether a line of this type may be sent now.
function Battleground.AllowsLine(msgType)
    return Battleground.GUILD_TYPES[msgType] == true or not Battleground.Quiet()
end

-- Act on a change: as the battle starts, buff mode ends and the button
-- empties; after it, the button comes back. Whenever it isn't quiet, a
-- trigger refused while it was (or seemed) quiet is answered or forgotten:
-- the refusal may have come before this module first read the phase.
function Battleground.Update()
    if not ns.db then return end
    local quiet = Battleground.Quiet()
    if quiet ~= wasQuiet then
        wasQuiet = quiet
        if quiet then
            local why = Battleground.QuietReason()
            ns.Diag.Log("battleground", "quiet: %s", why)
            if ns.BuffMode.IsOn() then ns.BuffMode.Set(false, { why = why }) end
        else
            ns.Diag.Log("battleground", "buffing and lines as normal")
        end
        ns.BuffButton.Refresh()
    end
    if not quiet then ns.BuffModeAuto.OnQuietEnded(Battleground.Phase() == "preparation") end
end

-- Your buffs changed (UNIT_AURA on you; Core calls this before buff thanks
-- look at them). Only read in a battleground before it has surely started.
function Battleground.OnPlayerAura()
    if started or not Battleground.InBattleground() then return Battleground.Update() end
    local now = ReadPreparation()
    -- Seen, then readably gone (even with unreadable moments between): the
    -- gates have opened.
    if now == true then seenPreparation = true end
    if seenPreparation and now == false then started = true end
    preparation = now
    Battleground.Update()
end

-- START_TIMER: the countdown to the gates opening (other countdowns, such as
-- a player's /countdown, aren't the battle's).
local function PvPTimerType()
    local types = Enum and Enum.StartTimerType
    local value = types and types.PvPBeginTimer
    if value == nil then value = rawget(_G, "TIMER_TYPE_PVP") end
    return value
end

function Battleground.OnStartTimer(timerType, timeRemaining)
    if Util.IsSecret(timerType) or Util.IsSecret(timeRemaining) then return end
    local pvp = PvPTimerType()
    if pvp == nil or timerType ~= pvp or type(timeRemaining) ~= "number" then return end
    if started then return end
    if timeRemaining <= 0 then
        started = true
    else
        timerEndsAt = GetTime() + math.min(timeRemaining, 300)
        C_Timer.After(timerEndsAt - GetTime(), ns.Diag.Wrap(Battleground.Update))
    end
    Battleground.Update()
end

-- No one dies before the gates open.
function Battleground.OnPlayerDead()
    if Battleground.InBattleground() then started = true end
    Battleground.Update()
end

-- Every loading screen: a new battleground starts unread. A login or
-- reload inside one can't know whether its gates have opened.
function Battleground.OnEnteringWorld(isLogin, isReload)
    Forget()
    distrustAura = (isLogin or isReload) and true or false
    Battleground.OnPlayerAura()
end

function Battleground.Create()
    if frame then return end
    frame = CreateFrame("Frame")
    local handlers = {
        START_TIMER = Battleground.OnStartTimer,
        PLAYER_DEAD = Battleground.OnPlayerDead,
        PLAYER_ENTERING_WORLD = Battleground.OnEnteringWorld,
        ZONE_CHANGED_NEW_AREA = Battleground.Update,
        UPDATE_BATTLEFIELD_STATUS = Battleground.Update,
    }
    for event in pairs(handlers) do frame:RegisterEvent(event) end
    frame:SetScript("OnEvent", function(_, event, ...) ns.Diag.Call(handlers[event], ...) end)
end
