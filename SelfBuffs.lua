-- Self-buffs (#44): in buff mode, once the button has nothing left for the
-- favours you owe or for your group (GroupBuffs.lua, your own copy of the
-- group buffs included), it offers the self-buffs you're missing: Inner Fire,
-- a mage's or warlock's armor, Lightning Shield, Righteous Fury, Omen of
-- Clarity, Battle Shout, a hunter's Aspect and Trueshot Aura, a paladin's
-- aura (BuffData's selfCast buffs). One press, one cast, on yourself, through
-- the same secure button. Nothing here casts.
--
-- Offered in buff mode only, solo too (the owner, #44), out of combat (the
-- button is empty in a fight), when "Offer my self-buffs" is on
-- (buffBack.selfBuffs), in your buff order, less any marked "Never offer"
-- (Righteous Fury is, until you untick it). Never a favour, never thanked,
-- never said in chat, never shared in a raid split, never in the dungeon
-- round's re-sync (#256).
--
-- Which are missing, from your own buffs (C_UnitAuras, "player"):
--   timed (Inner Fire, the armors, Lightning Shield, Righteous Fury, Omen,
--   Battle Shout): missing, or yours and running low: under the top-up time
--   (buffBack.topUpMinutes) and under half its full time (#44 Q5). Charges
--   aren't counted (Q7). Anyone's copy counts as having it: another
--   warrior's Battle Shout is never cast over;
--   toggles (Aspects, paladin auras, Trueshot Aura): never on a timer.
--   Missing only when no toggle of that family of yours is on (any Aspect of
--   yours, Cheetah's included; any aura of yours). Another player's copy
--   (their Devotion Aura, their Aspect of the Wild) isn't yours;
--   families (armor, aspect, aura): wearing one of yours covers the family,
--   and the one offered is the first of it in your buff order.
--
-- Not offered while you're dead, mounted, on a flight path, a druid in a
-- form or a shaman in Ghost Wolf, or while the game says the spell can't be
-- cast now (not enough rage or mana, Shadowform...). The reason shows on the
-- button and goes to debug once per reason. Anything that can't be read (a
-- secret, a missing API, junk) means "can't tell": nothing is offered then.
local _, ns = ...
local Util = ns.Util
local Read = Util.ReadGameValues

local SelfBuffs = {}
ns.SelfBuffs = SelfBuffs

-- After your self-buff lands, how long it counts as worn even if your buffs
-- don't show it yet.
SelfBuffs.JUST_GIVEN_SECONDS = 10
-- Right-click skips your self-buffs for this long.
SelfBuffs.SKIP_SECONDS = 300
-- A self-buff the game refused waits this long, so the next press tries the next one.
SelfBuffs.HELD_BACK_SECONDS = 15

local justGiven = {} -- [buff key or family] = GetTime() it landed
local heldBack = {}  -- [buff key] = GetTime() the game refused it
local skippedAt      -- GetTime() you right-clicked a self-buff
local said = {}      -- reasons said in debug, while they hold

local function Recently(at, seconds)
    return at ~= nil and GetTime() - at < seconds
end

-- Classes whose shapeshift form stops their self-buffs: a druid's forms,
-- a shaman's Ghost Wolf. (A warrior's stances, a priest's Shadowform and a
-- rogue's Stealth are forms too, and don't: the game's usable check speaks
-- for Shadowform.)
local FORM_CLASSES = { DRUID = "you're in a form", SHAMAN = "you're in Ghost Wolf" }

-- The game's power names, for "not enough rage for Battle Shout".
local POWER_WORDS = { RAGE = "rage", MANA = "mana", ENERGY = "energy", FOCUS = "focus" }

-- Why you can't have a self-buff now (dead, mounted, on a flight path, in a
-- form), or nil; and whether that leaves one to give once it passes (true:
-- not settled). Anything the game won't say is "can't tell", and not settled.
local function YouCant()
    local dead = Read(UnitIsDeadOrGhost, "player")
    if dead == true then return "you're dead", true end
    if dead ~= false then return "can't tell whether you're dead", true end
    local mounted = Read(IsMounted)
    if mounted == true then return "you're mounted", false end
    if mounted ~= false then return "can't tell whether you're mounted", true end
    local taxi = Read(UnitOnTaxi, "player")
    if taxi == true then return "you're on a flight path", false end
    if taxi ~= false then return "can't tell whether you're on a flight path", true end
    local _, class = Read(UnitClass, "player")
    local formWhy = type(class) == "string" and FORM_CLASSES[class]
    if formWhy then
        local form = Read(GetShapeshiftForm)
        if type(form) ~= "number" or form ~= form then return "can't tell whether " .. formWhy, true end
        if form ~= 0 then return formWhy, false end
    end
end

-- Your top-up time in seconds for buff, whose full time is duration: the
-- top-up minutes, capped at half its full time (#44 Q5), so a 2-minute
-- Battle Shout isn't "running low" the moment it lands. Read defensively.
local function TopUpSeconds(duration)
    local limits = ns.Config.LIMITS.topUpMinutes
    local minutes = Util.ClampNumber(ns.db.buffBack.topUpMinutes, limits.min, limits.max,
        ns.Config.DEFAULTS.buffBack.topUpMinutes)
    return math.min(minutes * 60, duration / 2)
end

-- Whether a timed self-buff of yours (aura, readable) is running low. No,
-- whenever its times are secret or not real numbers: they're never compared.
local function RunningLow(aura, buff)
    local duration, expires = aura.duration, aura.expirationTime
    if Util.IsSecret(duration) or Util.IsSecret(expires) then return false end
    if type(duration) ~= "number" or type(expires) ~= "number" then return false end
    -- Each test says yes only for a real number, so NaN is a no. 0 never runs out.
    if not (duration > 0 and expires > 0) then return false end
    if expires - GetTime() < TopUpSeconds(duration) then return ns.BuffData.CanReplace(buff, aura.spellId) end
    return false
end

-- Your own buffs, as far as self-buffs go: { [buff key or family] = true }
-- for each that needs nothing now, and { [buff key or family] = buff } for a
-- timed one of yours running low (it is topped up, not swapped for another
-- of its family); or nil and why when they can't be read. A toggle or a
-- family counts only when yours; a timed buff, whoever's it is (never cast
-- over another's).
local function Worn()
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if type(api) ~= "function" then return nil, "can't see your buffs" end
    local worn, low = {}, {}
    for i = 1, ns.Offers.MAX_AURAS do
        local ok, aura = pcall(api, "player", i, "HELPFUL")
        if not ok or Util.IsSecret(aura) then return nil, "can't see your buffs" end
        if aura == nil then return worn, nil, low end
        if type(aura) ~= "table" then return nil, "can't see your buffs" end
        local id = aura.spellId
        if Util.IsSecret(id) or type(id) ~= "number" then return nil, "can't see your buffs" end
        local buff = ns.BuffData.ForCast(id)
        if buff and not buff.selfCast then buff = nil end
        local family = ns.BuffData.SelfFamilyOf(id)
        if buff or family then
            local yours = Util.CastByYou(aura.sourceUnit)
            if buff and not buff.toggle then
                -- Timed: anyone's counts; only yours is topped up.
                if yours == true and RunningLow(aura, buff) then
                    low[family or buff.key] = buff
                else
                    worn[family or buff.key] = true
                end
            elseif yours == nil then
                return nil, "can't tell who cast your " .. (buff and ns.BuffData.SpellName(buff) or "Aspect")
            elseif yours then
                worn[family or buff.key] = true
            end
        end
    end
    -- More buffs than the addon looks through: what it saw is what counts
    -- (a self-buff past them is cast again, which only renews it).
    return worn, nil, low
end

-- Whether the game says you can cast buff now: true; false, and why, and
-- whether that passes by itself (power: not settled); or nil when it won't
-- say. C_Spell.IsSpellUsable, or IsUsableSpell on an older client, asked
-- about the rank you know best.
local function Usable(buff, spell)
    local id = ns.BuffData.KnownRank(buff)
    if id == nil then return false, "you don't know " .. spell, false end
    local fn = C_Spell and C_Spell.IsSpellUsable
    if type(fn) ~= "function" then fn = IsUsableSpell end
    local usable, noPower = Read(fn, id)
    if usable == true then return true end
    if usable ~= false then return nil, "can't tell whether " .. spell .. " can be cast now", false end
    if noPower == true then
        local _, token = Read(UnitPowerType, "player")
        local word = type(token) == "string" and POWER_WORDS[token] or "power"
        return false, "not enough " .. word .. " for " .. spell, true
    end
    return false, spell .. " can't be cast now", false
end

-- Say each reason once in debug while it holds.
local function Say(reasons)
    local now = {}
    for _, why in ipairs(reasons) do
        now[why] = true
        if not said[why] then ns.Diag.Log("buffMode", "self-buff not offered: %s", why) end
    end
    said = now
end

-- The next self-buff to offer: { name, buff, spell, group = true, self = true,
-- selfBuff = true, toggle }, or nil, why not (nil when there's nothing to
-- say), and whether that's settled: nothing left that a self-buff could fix
-- now or soon. Power running short, death, and anything that can't be read
-- are not settled; a mount, a flight path, a form or your own settings are.
-- With a list (as GroupBuffs.Next), every offer is appended in order.
function SelfBuffs.Next(out)
    if not ns.db or type(ns.db.buffBack) ~= "table" or ns.db.buffBack.selfBuffs ~= true then
        return nil, nil, true
    end
    local buffs = ns.BuffData.SelfOfferable()
    if #buffs == 0 then
        Say({})
        return nil, nil, true
    end
    local function Stop(why, open)
        Say({ why })
        return nil, why, not open
    end
    if InCombatLockdown() then return nil, "in combat", false end
    local me = Util.UnitFullName("player")
    if not me then return Stop("your name can't be read", true) end
    if Recently(skippedAt, SelfBuffs.SKIP_SECONDS) then
        return Stop("your self-buffs are skipped for now (you right-clicked)", false)
    end
    local cant, cantOpen = YouCant()
    if cant then return Stop(cant, cantOpen) end
    local worn, unread, low = Worn()
    if not worn then return Stop(unread, true) end
    -- A family member of yours running low is topped up itself, if you may
    -- be offered it; otherwise the family's first in your order is.
    local offerable = {}
    for _, buff in ipairs(buffs) do offerable[buff.key] = true end
    local first, firstWhy, open, reasons = nil, nil, false, {}
    local handled = {}
    for _, buff in ipairs(buffs) do
        local slot = buff.family or buff.key
        if low[slot] and offerable[low[slot].key] then buff = low[slot] end
        if not handled[slot] then
            -- One per family: the first of it in your order, or nothing.
            handled[slot] = true
            if not worn[slot] and not Recently(justGiven[slot], SelfBuffs.JUST_GIVEN_SECONDS) then
                local spell = ns.BuffData.CastName(buff)
                local why, waits
                if not spell then
                    why, waits = "the name of a self-buff can't be read", false
                elseif Recently(heldBack[buff.key], SelfBuffs.HELD_BACK_SECONDS) then
                    why, waits = "the game refused your last " .. spell, true
                else
                    local usable, usableWhy, power = Usable(buff, spell)
                    if usable == true then
                        local offer = { name = me, buff = buff, spell = spell, group = true, self = true,
                            selfBuff = true, toggle = buff.toggle == true }
                        -- A look that stops at the first offer saw only some
                        -- of the reasons: only a full look says them (#44).
                        if not out then return offer end
                        first = first or offer
                        out[#out + 1] = offer
                    else
                        -- Power comes back by itself; can't tell isn't done either.
                        why, waits = usableWhy, power or usable == nil
                    end
                end
                if why then
                    reasons[#reasons + 1] = why
                    firstWhy = firstWhy or why
                    open = open or waits
                end
            end
        end
    end
    Say(reasons)
    if first then return first end
    return nil, firstWhy, not open
end

-- Your self-buff landed (the game said so).
function SelfBuffs.NoteGiven(buff)
    justGiven[buff.family or buff.key] = GetTime()
    heldBack[buff.key] = nil
end

-- The game refused your self-buff: try the next one first for a moment.
function SelfBuffs.NoteRefused(buff)
    heldBack[buff.key] = GetTime()
end

-- Right-click: leave your self-buffs out for a while.
function SelfBuffs.Skip()
    skippedAt = GetTime()
end
