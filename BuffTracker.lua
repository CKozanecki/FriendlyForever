-- Thanks players outside your group who buff you, out in the world.
--
-- No combat log is involved. New buffs come from UNIT_AURA on "player", and
-- the caster is found in this order:
--   1. aura.sourceUnit: the game names the caster when it has a unit token
--      for them (target, mouseover, focus, nameplate, party/raid member...).
--   2. A matching UNIT_SPELLCAST_SUCCEEDED we saw from a non-group unit token
--      in the last moment, aimed at us (covers tokens that vanished before the
--      aura landed). A cast we can't see was aimed at us isn't remembered, so
--      it never names the caster and the buff goes on to step 3.
--   3. Neither, and we're not in a group: the aura came from another player
--      (isFromPlayerOrPlayerPet) we have no unit for, thanked as "friend"
--      (configurable). While grouped this fallback is off, because party-wide
--      buffs such as a groupmate's totems can arrive with no caster unit.
-- All buffs from one caster that arrive before the thank-you goes out are
-- merged into that single message, and the repeat cooldown stops a second one.
-- With "whisper instead of say" on, thanks are whispered to the caster (no key
-- press needed). Casters that can't be named, and whispers the game can't
-- deliver, fall back to a "friend" thank-you in /say (if that is switched on).
-- "How to thank" can add, or swap the line for, a /thank emote.
-- Every favour goes into the ledger (Ledger.lua), thanked or not.
local _, ns = ...
local Util = ns.Util

local BuffTracker = {}
ns.BuffTracker = BuffTracker

BuffTracker.CAST_MATCH_WINDOW = 1.5  -- seconds between cast and aura to match them
BuffTracker.UNKNOWN_COOLDOWN = 30    -- seconds between "friend" thank-yous
BuffTracker.UNKNOWN_KEY = "?unknown"
BuffTracker.WHISPER_FAIL_WINDOW = 5 -- seconds a "no player named" reply counts as our whisper failing
-- A buff cast longer ago than this is one we already had, re-sent by the game
-- (logging in, reconnecting, zoning). The login grace period alone isn't
-- enough: a slow loading screen can outlast it.
BuffTracker.STALE_AFTER = 5
-- A /say thank-you waits for a key press. Past this many seconds the buffer
-- has likely moved on, so it is dropped rather than said late. Whispers keep
-- the chat queue's usual limit.
BuffTracker.SAY_MAX_AGE = 30

-- Unit tokens whose casts we remember. Group tokens are skipped because
-- group members are never thanked.
local CAST_UNIT_PREFIXES = { "target", "focus", "mouseover", "nameplate", "softfriend" }
-- Each prefix starts with a different letter, so a token's first byte picks
-- the only prefix it could have. Most tokens (party, raid, player, arena)
-- are then rejected without any string work.
local CAST_UNIT_PREFIX_BY_BYTE = {}
for _, prefix in ipairs(CAST_UNIT_PREFIXES) do
    assert(not CAST_UNIT_PREFIX_BY_BYTE[prefix:byte(1)], "cast unit prefixes must start with different letters")
    CAST_UNIT_PREFIX_BY_BYTE[prefix:byte(1)] = prefix
end

local batches = {}      -- [caster key] = { names = {}, seen = {}, count = 0, entry = ledger entry }
local recentCasts = {}  -- [spellId] = { time = t, caster = full name or false, unit = token }

local function AnySecret(...)
    for i = 1, select("#", ...) do
        if Util.IsSecret((select(i, ...))) then return true end
    end
    return false
end

-- Name if this unit is a player we should thank; false if it is a caster we
-- must not thank (us, our pet, group, NPC, hostile); nil if we can't tell.
-- The full First-Surname name, which is also the whisper target.
function BuffTracker.Classify(unit)
    if Util.IsSecret(unit) or type(unit) ~= "string" then return nil end
    local isPlayer, isMe, isPet = UnitIsPlayer(unit), UnitIsUnit(unit, "player"), UnitIsUnit(unit, "pet")
    local inParty, inRaid, hostile = UnitInParty(unit), UnitInRaid(unit), UnitCanAttack("player", unit)
    if AnySecret(isPlayer, isMe, isPet, inParty, inRaid, hostile) then return nil end
    if isPet or inParty or inRaid or hostile or not isPlayer then return false end
    return Util.UnitFullName(unit) or nil
end

local function IsCastUnit(unit)
    local prefix = CAST_UNIT_PREFIX_BY_BYTE[unit:byte(1)]
    return prefix ~= nil and unit:find(prefix, 1, true) == 1
end

-- Readable and true only when the unit's target is us. Casters in cities buff
-- in batches, so a same-spell cast aimed at someone else must not name the
-- caster of a buff we got from someone we can't see. Such a cast is simply
-- not remembered: it doesn't block the "friend" fallback either.
local function AimedAtMe(unit)
    local aimed = UnitIsUnit(unit .. "target", "player")
    -- Check for a secret first: comparing one is an error in the real client.
    return not Util.IsSecret(aimed) and aimed == true
end

-- Lookups check the time themselves, so old casts only need clearing out
-- now and then, not on every event.
local lastPrune = 0
local function PruneCasts(now)
    if now - lastPrune <= BuffTracker.CAST_MATCH_WINDOW then return end
    lastPrune = now
    for spellId, cast in pairs(recentCasts) do
        if now - cast.time > BuffTracker.CAST_MATCH_WINDOW then recentCasts[spellId] = nil end
    end
end

-- This fires for every cast the client sees (nameplates in a city or a
-- raid), so the cheap checks come first. Core only registers it while buff
-- thanks are on; the enabled checks here cover the moment in between.
-- Buffs are watched while either Buff Thanks or Buff Back is on.
function BuffTracker.Watching()
    return ns.db ~= nil and ns.db.enabled and (ns.db.buff.enabled or ns.db.buffBack.enabled)
end

function BuffTracker.OnSpellcastSucceeded(unit, _, spellId)
    if not BuffTracker.Watching() then return end
    if Util.IsSecret(unit) or type(unit) ~= "string" or not IsCastUnit(unit) then return end
    if Util.IsSecret(spellId) or type(spellId) ~= "number" then return end
    local caster = BuffTracker.Classify(unit)
    if caster == nil then return end
    -- caster == false (us, pet, group, NPC, hostile) is kept: a real "don't thank".
    if caster and not AimedAtMe(unit) then return end
    local now = GetTime()
    PruneCasts(now)
    local cast = recentCasts[spellId]
    if cast then
        cast.time, cast.caster, cast.unit = now, caster, unit
    else
        recentCasts[spellId] = { time = now, caster = caster, unit = unit }
    end
end

-- The caster's class as players read it ("mage"), or nil.
local function ClassText(unit, caster)
    local name = Util.UnitClassIf(unit, caster)
    return name and name:lower() or nil
end

-- Why a favour wasn't thanked, in the ledger's words.
local NOTES = {
    { "repeat cooldown", "thanked them a moment ago" },
    { "snoozed", "snoozed" },
    { "switched off", "Buff Thanks is off" },
    { "login grace", "just logged in" },
    { "AFK", "you were AFK" },
    { "waited too long", "no key press in time" },
    { "blank", "no message lines" },
    { "queue full", "too many messages waiting" },
    { "ignore list", "on your ignore list" },
}
function BuffTracker.NoteFor(reason)
    if type(reason) ~= "string" then return "not sent" end
    for _, n in ipairs(NOTES) do
        if reason:find(n[1], 1, true) then return n[2] end
    end
    return reason
end

local function DescribeBuffs(batch)
    if ns.db.buff.listBuffNames and #batch.names > 0 then
        return Util.JoinList(batch.names)
    end
    return batch.count > 1 and "buffs" or "buff"
end

local function AddToBatch(batch, buffKey, spellName)
    if batch.seen[buffKey] then return end
    batch.seen[buffKey] = true
    batch.count = batch.count + 1
    if spellName then batch.names[#batch.names + 1] = spellName end
end

local function FallbackName()
    local name = ns.db.buff.unknownName
    if name == nil or name == "" then name = ns.Config.DEFAULTS.buff.unknownName end
    return name
end

local function FallbackVars(batch)
    local name = FallbackName()
    return { name = name, fullname = name, buff = DescribeBuffs(batch) }
end

local recentWhispers = {} -- [full name] = { time, batch } for whispers just sent

local function RememberWhisper(caster, batch)
    local now = GetTime()
    for name, w in pairs(recentWhispers) do
        if now - w.time > BuffTracker.WHISPER_FAIL_WINDOW then recentWhispers[name] = nil end
    end
    recentWhispers[caster] = { time = now, batch = batch }
end

-- The /thank goes to the caster's unit token while it is still them;
-- otherwise it is a plain /thank ("You thank everyone around you.").
local function EmoteTarget(caster, unit)
    return function()
        if unit and Util.UnitFullName(unit) == caster then return unit end
        return nil
    end
end

-- caster: full player name (also the whisper target), or BuffTracker.UNKNOWN_KEY.
-- unit: the token the caster was seen under, if any (for the /thank emote).
function BuffTracker.AddBuff(caster, buffKey, spellName, unit)
    local existing = batches[caster]
    if existing then
        AddToBatch(existing, buffKey, spellName)
        ns.Ledger.AddBuff(existing.entry, spellName)
        ns.Diag.Log("buff", "added to the thank-you already waiting for %s", caster)
        return
    end

    local unknown = caster == BuffTracker.UNKNOWN_KEY
    local entry = ns.Ledger.Received(unknown and ns.Ledger.UNKNOWN or caster, spellName)

    if not unknown and ns.Ignore.Has(caster) then
        ns.Diag.Log("buff", "not thanking %s: on your ignore list", caster)
        ns.Ledger.Settle(entry, false, "on your ignore list")
        return
    end
    -- A favour to return, whether or not a thank-you goes out.
    if not unknown and ns.db.buffBack.enabled then ns.Offers.Owe(caster, unit, entry) end
    local cfg = ns.db.buff
    if unknown and not cfg.fallbackToSay then
        ns.Diag.Log("buff", "not thanking: caster can't be named and the /say fallback is off")
        ns.Ledger.Settle(entry, false, "couldn't tell who it was")
        return
    end

    local batch = { names = {}, seen = {}, count = 0, entry = entry, class = ClassText(unit, caster) }
    AddToBatch(batch, buffKey, spellName)
    batches[caster] = batch

    local style = cfg.thankStyle
    local withLine = style ~= "emote"
    local withEmote = style ~= "message"
    -- Done once every thank-you scheduled for this favour has gone or been dropped.
    local waiting, firstReason = 0, nil
    local function Done(sent, reason)
        waiting = waiting - 1
        if sent then ns.Ledger.Settle(entry, true) end
        firstReason = firstReason or reason
        if waiting == 0 then
            if batches[caster] == batch then batches[caster] = nil end
            ns.Ledger.Settle(entry, false, BuffTracker.NoteFor(firstReason))
        end
    end

    -- Checked again just before sending: they may have been ignored meanwhile.
    local function NotIgnored()
        if not unknown and ns.Ignore.Has(caster) then return false, "on your ignore list" end
        return true
    end

    -- Someone we can't name can't be whispered: they get the /say fallback.
    local whisper = cfg.useWhisper and not unknown
    local scheduled, why = false, nil
    if withLine then
        local ok, reason = ns.Announcer.Schedule("buff", caster, {
            channel = whisper and "WHISPER" or "SAY",
            target = whisper and caster or nil,
            cooldown = unknown and BuffTracker.UNKNOWN_COOLDOWN or nil,
            maxAge = (not whisper) and BuffTracker.SAY_MAX_AGE or nil,
            isValid = NotIgnored,
            vars = function()
                if unknown then return FallbackVars(batch) end
                local vars = Util.NameVars(caster)
                vars.buff = DescribeBuffs(batch)
                vars.class = batch.class
                return vars
            end,
            onDone = function(sent, reason2)
                if sent and whisper then RememberWhisper(caster, batch) end
                -- The line is said: later buffs start a favour of their own,
                -- even while a /thank for this one still waits.
                if batches[caster] == batch then batches[caster] = nil end
                Done(sent, reason2)
            end,
        })
        if ok then waiting, scheduled = waiting + 1, true else why = reason end
    end
    if withEmote then
        local ok, reason = ns.Announcer.Schedule("buff", caster, {
            emote = "THANK",
            emoteTarget = EmoteTarget(caster, unit),
            cooldown = unknown and BuffTracker.UNKNOWN_COOLDOWN or nil,
            maxAge = BuffTracker.SAY_MAX_AGE,
            isValid = NotIgnored,
            onDone = Done,
        })
        if ok then waiting, scheduled = waiting + 1, true else why = why or reason end
    end
    if not scheduled then
        batches[caster] = nil
        ns.Ledger.Settle(entry, false, BuffTracker.NoteFor(why))
    end
end

-- The game answers a whisper to someone it can't find with a system message
-- ("No player named 'X' is currently playing."). If that follows one of our
-- thank-you whispers, thank them in /say instead, as the fallback name.
function BuffTracker.OnWhisperFailed(name)
    local w = recentWhispers[name]
    if not w or GetTime() - w.time > BuffTracker.WHISPER_FAIL_WINDOW then return end
    recentWhispers[name] = nil
    if not ns.db.buff.fallbackToSay then
        ns.Diag.Log("buff", "whisper to %s failed; the /say fallback is off", name)
        return
    end
    ns.Diag.Log("buff", "whisper to %s failed; thanking in /say instead", name)
    ns.Announcer.Schedule("buff", "whisper failed:" .. name, {
        channel = "SAY",
        cooldown = 0, -- the caster's own cooldown already stops repeats
        maxAge = BuffTracker.SAY_MAX_AGE,
        vars = function() return FallbackVars(w.batch) end,
    })
end

-- Returns caster (name or UNKNOWN_KEY) or nil, the reason in words, and the
-- unit token the caster was seen under (if any).
local function FindCaster(aura, spellId, now)
    local src = aura.sourceUnit
    if Util.IsSecret(src) then return nil, "caster unit is secret (restricted)" end
    if src ~= nil then
        local caster = BuffTracker.Classify(src)
        if caster then return caster, "caster unit " .. src, src end
        if caster == false then return nil, "caster " .. src .. " is you, your pet, your group, an NPC or hostile" end
        return nil, "caster " .. src .. " can't be identified"
    end

    local cast = spellId and recentCasts[spellId]
    if cast and now - cast.time <= BuffTracker.CAST_MATCH_WINDOW then
        if cast.caster then return cast.caster, "matched a cast at you just before", cast.unit end
        return nil, "matched a cast by someone we don't thank"
    end

    -- Party-wide buffs (totems, auras, shouts) can arrive with no caster unit
    -- at all, so in a group an unnamed buff may well be from a groupmate.
    -- Those buffs can't reach us when ungrouped, so only fall back then.
    if IsInGroup() then return nil, "no caster unit, and you're in a group (could be a groupmate's totem)" end

    local fromPlayer = aura.isFromPlayerOrPlayerPet
    if not Util.IsSecret(fromPlayer) and fromPlayer == true then
        return BuffTracker.UNKNOWN_KEY, "no caster unit; from a player outside your group"
    end
    return nil, "no caster unit, and not from a player"
end

local function IsReadable(aura)
    return type(aura) == "table" and not Util.IsSecret(aura)
end

-- The event's copy of an aura can be locked while the game's own query is
-- readable; the instance ID is never secret. Errors (when restricted) are
-- caught and treated as "can't read it".
local function ReadAuraId(aura)
    local ok, id = pcall(function() return aura.auraInstanceID end)
    if ok and not Util.IsSecret(id) and type(id) == "number" then return id end
end

local function QueryAura(id)
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID
    if not api or not id then return nil end
    local ok, data = pcall(api, "player", id)
    if ok and IsReadable(data) then return data end
end

local knownAuraIds = {} -- auras we have already seen on the player

-- Seconds since the aura was cast, from its full duration and expiry time.
-- nil when that can't be told (no duration, or values are secret).
function BuffTracker.AuraAge(aura, now)
    local duration, expires = aura.duration, aura.expirationTime
    if AnySecret(duration, expires) then return nil end
    if type(duration) ~= "number" or type(expires) ~= "number" then return nil end
    if duration <= 0 or expires <= 0 then return nil end
    return math.floor(now - (expires - duration))
end

local function HandleAddedAura(aura, now)
    if not IsReadable(aura) then
        local id = ReadAuraId(aura)
        aura = QueryAura(id)
        if not aura then
            ns.Diag.Log("buff", "skipped aura %s: its data is locked (restricted)", id)
            return
        end
    end

    local helpful, spellId, spellName = aura.isHelpful, aura.spellId, aura.name
    if Util.IsSecret(spellId) or type(spellId) ~= "number" then spellId = nil end
    if Util.IsSecret(spellName) or type(spellName) ~= "string" then spellName = nil end
    if Util.IsSecret(helpful) or helpful ~= true then return end -- debuffs are never thanked

    ns.Diag.Count("buffsSeen")
    local age = BuffTracker.AuraAge(aura, now)
    if age and age > BuffTracker.STALE_AFTER then
        ns.Diag.Log("buff", "%s (spell %s): cast %ds ago, so I already had it -> skip", spellName or "?", spellId, age)
        return
    end
    local caster, reason, unit = FindCaster(aura, spellId, now)
    ns.Diag.Log("buff", "%s (spell %s): %s -> %s", spellName or "?", spellId, reason,
        caster and ("thank " .. caster) or "skip")
    if caster then
        BuffTracker.AddBuff(caster, spellName or spellId or aura.auraInstanceID or "?", spellName, unit)
    end
end

-- Instance IDs of the player's current buffs; calls onNew(aura) for each one
-- not in knownAuraIds. Unreadable entries are skipped.
local function ScanBuffs(onNew)
    local current = {}
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not api then return current end
    for i = 1, 255 do
        local ok, aura = pcall(api, "player", i, "HELPFUL")
        if not ok or aura == nil then break end
        local id = IsReadable(aura) and ReadAuraId(aura)
        if id then
            current[id] = true
            if onNew and not knownAuraIds[id] then onNew(aura) end
        end
    end
    return current
end

function BuffTracker.OnPlayerAura(updateInfo)
    if not ns.db then return end
    if Util.IsSecret(updateInfo) or type(updateInfo) ~= "table" then
        ns.Diag.Log("buff", "aura update payload is locked (restricted); skipped")
        return
    end

    -- In combat (and other restricted moments) the fields themselves can be
    -- secret even though the table isn't; touching them would be an error.
    local fullUpdate, s1 = Util.Readable(updateInfo.isFullUpdate)
    local added, s2 = Util.Readable(updateInfo.addedAuras)
    local removed, s3 = Util.Readable(updateInfo.removedAuraInstanceIDs)
    if s1 or s2 or s3 then
        ns.Diag.Count("restrictedAuraUpdates")
        ns.Diag.Log("buff", "aura update is restricted (combat?); skipped")
        return
    end

    local active = BuffTracker.Watching() and ns.Announcer.IsWatching()
    local now = GetTime()

    -- A full update gives no list of what is new, so compare against the
    -- buffs we already knew about (zoning re-sends everything you have).
    if fullUpdate then
        knownAuraIds = ScanBuffs(active and function(aura) HandleAddedAura(aura, now) end or nil)
        return
    end

    if type(removed) == "table" then
        for _, id in ipairs(removed) do
            if not Util.IsSecret(id) then knownAuraIds[id] = nil end
        end
    end

    if type(added) ~= "table" then return end
    for _, aura in ipairs(added) do
        local id = ReadAuraId(aura)
        if id then knownAuraIds[id] = true end
        if active then HandleAddedAura(aura, now) end
    end
end
