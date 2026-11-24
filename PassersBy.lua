-- Passers-by (#39): in buff mode, the button can also offer your buffs to
-- players nearby who aren't in your group and haven't buffed you or asked.
-- It's off by default (buffBack.passersBy). Nothing here casts: the one
-- secure button does, on your press (BuffButton.lua), and it asks Next for
-- a passer-by last, after favours, requests, your group and your self-buffs.
--
-- When: the addon, Buff Back and the switch are on, buff mode is on, you're
-- out of a fight, in the open world (IsInInstance() says false: never in a
-- dungeon, raid, battleground or arena, or where the game won't say), and
-- not in a capital city (a map that can't be read counts as one here).
--
-- Who: the players the game shows on a nameplate (nameplate1..40). Every
-- check below must read as the safe answer: an error, a secret, nil or the
-- wrong type skips that player (pessimistic). Cheap checks come first:
--   a player, not you, with a readable full name, not in your group (a
--   group the game won't describe offers nobody), not owed a favour or
--   asking for a buff (Offers.lua offers those), not on your ignore list,
--   one you can help (UnitCanAssist: not the other faction, not dueling),
--   alive and online, their fight readable, not flagged for PvP unless
--   you are, their class readable, not right-clicked away in the last
--   SKIP_SECONDS. A buff of yours that reached them from the button isn't
--   offered to them again for SKIP_SECONDS (each buff on its own, so they
--   still get your next one): someone who cancels it isn't asked again at
--   every press.
-- A player in a fight isn't skipped (the owner, #39 Q6): they go to the end
-- of the list, after everyone who isn't, so they're your last buff.
--
-- Which buff: your buffs for others in your order (BuffData.Offerable, then
-- Water.Filter), one their class can use and your Buff Back rule for
-- strangers gives them (BuffRules.AllowsStranger, #408), not a Blessing
-- while they wear another of yours (a paladin keeps one on each player, as
-- GroupBuffs does; one you gave them a moment ago counts though it may not
-- show yet), that they're missing or whose copy has less
-- than half its full time left (the owner, #39 Q4: a single rank yours can replace, with times the
-- game shows). Their auras must be readable, and the game must say your
-- spell reaches them: a doubt never costs a cast. One buff per press, at
-- the highest rank you know that their level allows (BuffData.CastFor,
-- #459): your highest by its plain name, a lower one by name and rank. A level the game won't give skips them; one too
-- low for every rank of a buff is offered your next buff instead. After a
-- refusal by the game about them (out of range, out of sight, too low
-- level: BuffButton.RefusalKind, #483) they wait HELD_BACK_SECONDS; one
-- about you (no mana, the global cooldown) holds nobody.
--
-- Saying why (#521, the owner's report of 20 Nov): while the switch and buff
-- mode are on but passers-by can't be offered, OffReason says why, from the
-- place, the fight and friendly nameplates (Nameplates.lua: one the game
-- won't read counts as off). The button's line says so when nobody else is
-- offered (BuffButton.lua), the Favours tab notes nameplates off by the
-- switch (Options.lua), debug logs "passersBy: off: <reason>" each time the
-- reason changes (Watch), and once a session chat says how to show
-- nameplates. A resting area stops nothing (they're still offered), but
-- they don't keep buff mode on there (BuffModeAuto.lua, #484): logged too.
-- The words are fixed text, never a player's name; nothing here casts.
--
-- Limits: at most MAX_CHECKED players get the costly checks (auras, range)
-- per look, at most MAX_LISTED are listed, and a look runs at most once
-- every INTERVAL seconds unless a press asks afresh (Fresh). Skips are kept
-- for at most MAX_SKIPPED players, and buffs given for at most MAX_GIVEN
-- (player, buff) pairs, in memory only.
local _, ns = ...
local Util = ns.Util
local Read = Util.ReadGameValues

local PassersBy = {}
ns.PassersBy = PassersBy

PassersBy.MAX_CHECKED = 10     -- players given the costly checks (auras, range) per look
PassersBy.MAX_LISTED = 5       -- passers-by in the button's list at most
PassersBy.INTERVAL = 1         -- seconds a look is reused for, unless a press asks afresh
PassersBy.SKIP_SECONDS = 600   -- a right-click, or your buff reaching them, skips them this long
PassersBy.MAX_SKIPPED = 50     -- players whose skip is remembered; the oldest goes first
PassersBy.MAX_GIVEN = 200      -- (player, buff) pairs given a buff, remembered; the oldest goes first
PassersBy.HELD_BACK_SECONDS = 15 -- refused for a reason about them (#459, #483), a passer-by waits this long
PassersBy.LOG_SECONDS = 60     -- debug says why a player was skipped once per reason this often
PassersBy.MAX_LOGGED = 100     -- (player, reason) pairs remembered for that
PassersBy.HALF = 0.5           -- a copy with less than this share of its time left is topped up

local skipped = {}    -- [full name] = GetTime() of the right-click
local heldBack = {}   -- [full name] = GetTime() the game refused a cast to them
local given = {}      -- [name .. "\1" .. buff key] = GetTime() your buff reached them
local logged = {}     -- [name .. "\1" .. why] = GetTime() it was said in debug
local cache           -- { at, offers = { ... }, reason }: the last look
local lastOff         -- the OffReason key last logged (Watch), or nil
local hinted = false  -- the once-a-session chat line about nameplates was said

local function Recently(at, seconds)
    return at ~= nil and GetTime() - at >= 0 and GetTime() - at < seconds
end

-- Room for one more in a [name] = time table holding at most limit.
local function MakeRoom(times, name, limit)
    if times[name] then return end
    local count, oldest = 0, nil
    for who, at in pairs(times) do
        count = count + 1
        if not oldest or at < times[oldest] then oldest = who end
    end
    if count >= limit then times[oldest] = nil end
end

-- Debug: why a player was passed over, once per player and reason a minute.
local function Skip(name, why)
    local key = name .. "\1" .. why
    if Recently(logged[key], PassersBy.LOG_SECONDS) then return end
    local count = 0
    for k, at in pairs(logged) do
        if Recently(at, PassersBy.LOG_SECONDS) then count = count + 1 else logged[k] = nil end
    end
    if count >= PassersBy.MAX_LOGGED then return end
    logged[key] = GetTime()
    ns.Diag.Log("passersBy", "not offering %s: %s", name, why)
end

-- The switch, read defensively: anything but true is off.
function PassersBy.On()
    local cfg = ns.db and ns.db.buffBack
    return ns.db ~= nil and ns.db.enabled == true and type(cfg) == "table" and cfg.enabled == true
        and cfg.passersBy == true
end

-- Why passers-by can't be offered now, or nil when they may be, and its
-- OffReason key (#521) for the reasons that aren't a switch.
local function WhyNotNow(anyMode)
    if not PassersBy.On() then return "passers-by are off" end
    if not anyMode and not ns.BuffMode.LentKey() then return "buff mode is off" end
    if Read(InCombatLockdown) ~= false then return "you're in a fight", "combat" end
    local inside = Read(IsInInstance)
    if inside == true then return "you're not in the open world", "instance" end
    if inside ~= false or ns.Cities.MapId() == nil then return "the game won't say where you are", "place" end
    if ns.Cities.Capital() ~= nil then return "you're in a capital city", "capital" end
end

-- The reasons (#521): for the debug log, and for the button's line ("button":
-- nil for one that stops nothing). Fixed text only.
PassersBy.OFF_REASONS = {
    nameplates = { log = "friendly nameplates are off", button = "need friendly nameplates" },
    nameplatesUnread = { log = "friendly nameplates can't be read, so count as off",
        button = "need friendly nameplates" },
    combat = { log = "you're in a fight", button = "not in a fight" },
    instance = { log = "you're in an instance (dungeon, raid, battleground or arena)",
        button = "not in a dungeon, raid or battleground" },
    place = { log = "the place can't be read (instance or map)", button = "the game won't say where you are" },
    capital = { log = "you're in a capital city", button = "not in a capital city" },
    resting = { log = "you're in a resting area: they don't keep buff mode on here" },
}

-- Why passers-by, switched on, aren't being offered while buff mode is on
-- (#521): a key of OFF_REASONS, or nil (they may be, or their switch or buff
-- mode is off). Buff mode counts as on while it waits out a fight, its key
-- handed back (BuffMode.IsOn). The place and the fight first (nameplates
-- wouldn't help there), then nameplates, then a resting area. fightStarting:
-- the fight's first event, which comes just before the lockdown.
function PassersBy.OffReason(fightStarting)
    if not PassersBy.On() or not (ns.BuffMode.IsOn() or ns.BuffMode.LentKey()) then return nil end
    if fightStarting then return "combat" end
    local _, key = WhyNotNow(true)
    if key then return key end
    local shown = ns.Nameplates.FriendlyShown()
    if shown == nil then return "nameplatesUnread" end
    if shown ~= true then return "nameplates" end
    if Read(IsResting) ~= false then return "resting" end
end

-- The button's words for why, or nil: "Passers-by: not in a capital city".
function PassersBy.OffText()
    local key = PassersBy.OffReason()
    local reason = key and PassersBy.OFF_REASONS[key]
    if not reason or not reason.button then return nil end
    if key == "nameplates" or key == "nameplatesUnread" then
        return "Passers-by " .. reason.button .. " (" .. ns.Nameplates.HowToShow() .. ")"
    end
    return "Passers-by: " .. reason.button
end

-- Each refresh (BuffButton.Refresh), and as a fight starts (OnCombatStart,
-- fightStarting): debug logs the reason each time it changes, and chat says
-- once a session how to show friendly nameplates when passers-by need them.
-- The reason is forgotten while it is nil, so the same one starting again is
-- logged again.
function PassersBy.Watch(fightStarting)
    local key = PassersBy.OffReason(fightStarting)
    if key ~= lastOff and key then
        ns.Diag.Log("passersBy", "off: %s", PassersBy.OFF_REASONS[key].log)
    end
    lastOff = key
    if not hinted and PassersBy.On() and ns.BuffMode.LentKey() and ns.Nameplates.FriendlyShown() ~= true then
        hinted = true
        local toggle = ns.Nameplates.ToggleKeyText()
        ns.Print("passers-by need friendly player nameplates to be seen: /friendly nameplates shows them"
            .. (toggle and (", or press " .. toggle) or "") .. ".")
    end
end

-- Everyone in your group by full name, or nil when a slot can't be read.
-- Both the party and the raid slots are read, so a raid answer the game
-- won't give or that the slots disagree with (#346) still finds everyone.
local function GroupNames()
    local names = {}
    local function Slot(unit)
        local exists = Read(UnitExists, unit)
        if exists == false then return true end
        if exists ~= true then return false end
        local ok, name = pcall(Util.UnitFullName, unit)
        if not ok or not name then return false end
        names[name] = true
        return true
    end
    for i = 1, 4 do
        if not Slot("party" .. i) then return nil end
    end
    for i = 1, 40 do
        if not Slot("raid" .. i) then return nil end
    end
    return names
end

-- A copy (readable, of buff) that is half gone: a single rank yours can
-- replace, whose times the game shows, with under half its full time left
-- (the owner, #39 Q4). It doesn't count as worn, so it's topped up.
local function HalfGone(aura, buff)
    return ns.Offers.WornOffBelow(aura, buff, PassersBy.HALF)
end

-- The cheap checks for a nameplate token: { unit, name, class, fighting }
-- or nil and why not. me: your name; meFlagged: you're flagged for PvP.
local function Cheap(unit, group, me, meFlagged)
    if Read(UnitIsPlayer, unit) ~= true then return nil end -- NPCs and empty plates: said nothing
    if Read(UnitIsUnit, unit, "player") ~= false then return nil end
    -- A name the game won't give (an error, a secret) is no name.
    local ok, name = pcall(Util.UnitFullName, unit)
    if not ok or not name or name == me then return nil end
    if group[name] then return nil, name, "in your group" end
    if ns.Offers.Has(name) then return nil, name, "owed a favour or asking for a buff" end
    if ns.Ignore.Has(name) then return nil, name, "on your ignore list" end
    if Read(UnitCanAssist, "player", unit) ~= true then return nil, name, "not someone you can help" end
    if Read(UnitIsDeadOrGhost, unit) ~= false then return nil, name, "dead, or can't tell" end
    if Read(UnitIsConnected, unit) ~= true then return nil, name, "offline, or can't tell" end
    local fighting = Read(UnitAffectingCombat, unit)
    if fighting ~= true and fighting ~= false then return nil, name, "can't tell whether they're in a fight" end
    local pvp = Read(UnitIsPVP, unit)
    if pvp ~= false and pvp ~= true then return nil, name, "can't see whether they're flagged for PvP" end
    if pvp == true and not meFlagged then return nil, name, "flagged for PvP and you aren't" end
    local readClass, _, class = pcall(Util.UnitClassIf, unit, name)
    if not readClass or not class then return nil, name, "can't see their class" end
    if Recently(skipped[name], PassersBy.SKIP_SECONDS) then return nil, name, "skipped (you right-clicked them)" end
    if Recently(heldBack[name], PassersBy.HELD_BACK_SECONDS) then
        return nil, name, "the game refused your last cast to them"
    end
    return { unit = unit, name = name, class = class, fighting = fighting }
end

-- Whether they have another buff of buff's family from you (a Blessing,
-- when you'd give another): worn and cast by you, or given by the button
-- within SKIP_SECONDS. true, false, or nil when the game won't say. A buff
-- with no family has none.
local function OtherOfFamily(candidate, buff, myBuffs)
    if not buff.family then return false end
    for _, other in ipairs(myBuffs) do
        if other.family == buff.family and other.key ~= buff.key
            and Recently(given[candidate.name .. "\1" .. other.key], PassersBy.SKIP_SECONDS) then
            return true
        end
    end
    return ns.GroupBuffs.WearsMyFamily(candidate.unit, buff.family, buff, true)
end

-- The buff to give a candidate, its name and what to cast it as (by name
-- and rank, #459), or nil and why not. myBuffs never holds a self-buff or
-- one only given when asked (BuffData.Offerable).
local function Choose(candidate, myBuffs)
    local unit, wanted, cast, notCast = candidate.unit, nil, nil, nil
    for _, buff in ipairs(myBuffs) do
        -- A buff their class can use that your Buff Back rule for strangers
        -- gives them (#408: Everyone, or their class ticked; Off never), as
        -- a favour's. Only a plain yes counts.
        local hasOther = true -- not a buff to give them, unless all below say so
        if ns.BuffData.Useful(buff, candidate.class)
            and ns.BuffRules.AllowsStranger(buff, candidate.class) == true
            and not Recently(given[candidate.name .. "\1" .. buff.key], PassersBy.SKIP_SECONDS) then
            hasOther = OtherOfFamily(candidate, buff, myBuffs)
            if hasOther == nil then return nil, "can't tell whose Blessing they have" end
        end
        if hasOther == false then
            local wears = ns.Offers.Wears(unit, buff, HalfGone)
            if wears == nil then return nil, "can't read their buffs" end
            if wears == false then
                -- The rank their level allows (#459); none (too low for
                -- every rank, or their level unreadable), your next buff.
                local why
                cast, why = ns.BuffData.CastFor(buff, unit)
                if cast then
                    wanted = buff
                    break
                end
                notCast = notCast or why
            end
        end
    end
    if not wanted then return nil, notCast or "has your buffs" end
    local spell = ns.BuffData.SpellName(wanted)
    if not spell then return nil, "the spell's name isn't known" end
    if Util.InSpellRange(spell, unit) ~= true then return nil, "out of range, or the game won't say" end
    return wanted, spell, cast
end

-- The look itself: the offers, in the order the button would reach them.
-- anyMode: as if buff mode were on (the campfire's trigger asks before it
-- turns it on).
local function Look(anyMode)
    local why = WhyNotNow(anyMode)
    if why then return {}, why end
    local group = GroupNames()
    if not group then return {}, "your group can't be read" end
    local readMe, me = pcall(Util.UnitFullName, "player")
    if not readMe or not me then return {}, "your name can't be read" end
    local meFlagged = Read(UnitIsPVP, "player") == true
    -- Cheap checks over every nameplate; those in a fight go last (#39 Q6).
    local calm, fighting, seen = {}, {}, {}
    for i = 1, ns.Offers.MAX_NAMEPLATES do
        local candidate, name, skipWhy = Cheap("nameplate" .. i, group, me, meFlagged)
        if candidate and not seen[candidate.name] then
            seen[candidate.name] = true
            local into = candidate.fighting and fighting or calm
            into[#into + 1] = candidate
        elseif name and skipWhy then
            Skip(name, skipWhy)
        end
    end
    local myBuffs = ns.Water.Filter(ns.BuffData.Offerable())
    local offers, checked = {}, 0
    for _, bucket in ipairs({ calm, fighting }) do
        for _, candidate in ipairs(bucket) do
            if checked >= PassersBy.MAX_CHECKED or #offers >= PassersBy.MAX_LISTED then break end
            checked = checked + 1
            local buff, spell, cast = Choose(candidate, myBuffs)
            if buff then
                offers[#offers + 1] = { name = candidate.name, buff = buff, spell = spell, castSpell = cast,
                    passerBy = true }
            else
                Skip(candidate.name, spell)
            end
        end
    end
    if #offers == 0 then return offers, "nobody passing by needs a buff" end
    return offers
end

-- The next passer-by to buff: { name, buff, spell, castSpell, passerBy = true }, or
-- nil and why not. With a list (#43), every passer-by the button would
-- offer to (at most MAX_LISTED) is appended to it, in order. A look is
-- reused for INTERVAL seconds, unless Fresh was called since.
function PassersBy.Next(out)
    local now = GetTime()
    if not cache or not (now - cache.at >= 0 and now - cache.at < PassersBy.INTERVAL) then
        local offers, why = Look()
        cache = { at = now, offers = offers, reason = why }
    end
    local offers = cache.offers
    if out then
        for _, offer in ipairs(offers) do out[#out + 1] = offer end
    end
    if offers[1] then return offers[1] end
    return nil, cache.reason
end

-- Whether a passer-by would be offered a buff now, buff mode on or not:
-- the campfire's trigger (BuffModeAuto.lua) turns buff mode on for them,
-- and buff mode stays on while one waits (#462). Reads afresh when buff
-- mode is off. In buff mode, a passer-by the game refused a moment ago
-- (#459: a refusal about them, #483) still waits until
-- their hold ends, as a held-back group member does, so a refusal never
-- ends buff mode; then they're looked at again.
function PassersBy.Waiting()
    if ns.BuffMode.LentKey() then
        if PassersBy.Next() ~= nil then return true end
        if WhyNotNow() then return false end
        for _, at in pairs(heldBack) do
            if Recently(at, PassersBy.HELD_BACK_SECONDS) then return true end
        end
        return false
    end
    return Look(true)[1] ~= nil
end

-- The next look reads everything again (a press, a cast that landed).
function PassersBy.Fresh()
    cache = nil
end

-- Right-click: leave them out for SKIP_SECONDS.
function PassersBy.SkipName(name)
    if type(name) ~= "string" then return end
    MakeRoom(skipped, name, PassersBy.MAX_SKIPPED)
    skipped[name] = GetTime()
    cache = nil
end

-- Your buff reached them (or the game didn't say where it went): not
-- offered to them again for SKIP_SECONDS.
function PassersBy.NoteGiven(name, buff)
    if type(name) ~= "string" or type(buff) ~= "table" or type(buff.key) ~= "string" then return end
    local key = name .. "\1" .. buff.key
    MakeRoom(given, key, PassersBy.MAX_GIVEN)
    given[key] = GetTime()
    cache = nil
end

-- The game refused a cast to them, for a reason about them (#459, #483:
-- BuffButton.RefusalKind): the next press tries someone else for a moment.
function PassersBy.NoteRefused(name)
    if type(name) ~= "string" then return end
    MakeRoom(heldBack, name, PassersBy.MAX_SKIPPED)
    heldBack[name] = GetTime()
    cache = nil
end

-- Forget what's out of date, so the tables stay small in a long session.
function PassersBy.Prune()
    for name, at in pairs(skipped) do
        if not Recently(at, PassersBy.SKIP_SECONDS) then skipped[name] = nil end
    end
    for name, at in pairs(heldBack) do
        if not Recently(at, PassersBy.HELD_BACK_SECONDS) then heldBack[name] = nil end
    end
    for key, at in pairs(given) do
        if not Recently(at, PassersBy.SKIP_SECONDS) then given[key] = nil end
    end
end

-- How many skips and buffs given are remembered now (for the tests' limits).
function PassersBy.Remembered()
    local skips, gifts = 0, 0
    for _ in pairs(skipped) do skips = skips + 1 end
    for _ in pairs(given) do gifts = gifts + 1 end
    return skips, gifts
end
