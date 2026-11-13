-- Buffing your group in buff mode: while buff mode is on, the buff-back
-- button also offers your buffs to group members who are missing them, one
-- per press. Favours owed to strangers come first. Nothing here casts.
--
-- The same safety rules as buff back: a member flagged for PvP is skipped
-- unless you're flagged too (read each time the button is armed, so at the
-- press), as are the dead, the offline, and anyone out of range (of the
-- spell, when the game says) or too far for the game to show. The game can't
-- say whether they're in line of sight: a cast it refuses holds that member
-- back for a moment, so the next press goes to the next member.
--
-- A paladin keeps one Blessing on each player: a member wearing one of yours
-- has theirs, and isn't offered another (it would replace it). A member whose name, flag or buffs can't be
-- read is skipped too, and the button says why. Your rules for who gets
-- each buff (tanks only, chosen classes, named players: BuffRules.lua) apply
-- here, and only here. Group buffs never say a line and are never thanked.
--
-- You are a group member too (#198): for each buff you give, that buff is
-- offered on you first, if you are missing it, and then to the group
-- (GroupBuffs.SELF_ORDER says where you come in), under the same rules: your buff order, Never lists,
-- who gets each buff, top-up timing. It is cast on you with [@player], so
-- your target stays as it is. You are left out when dead or unreadable (the
-- reason is named); range and PvP flag don't apply to your own buffs.
--
-- Top-up timing (#42): a buff you give (whoever cast it) with less than the
-- set time left (buffBack.topUpMinutes) counts as missing, so you can renew
-- it before it runs out. Only a rank you can replace, or a group version
-- (Prayers, Arcane Brilliance, Gift of the Wild, Greater Blessings) no
-- stronger than a rank you know (#206; BuffData.CanReplace), and only when
-- the game shows how long it has left: a time that can't be read (secret,
-- missing) means it isn't missing. Strangers (buff back) are never topped up.
--
-- Whose buff it is (#256). A buff someone outside your group put up doesn't
-- count: yours is offered over it, so every member's buff is yours, on your
-- timer. A buff a group member put up is left alone. The game names a group
-- member's caster, so a caster it doesn't name (sourceUnit nil) is someone
-- outside the group (the owner's decision). A caster it gives as a secret
-- can't be read: that buff is never cast over, and the member isn't done.
-- In the round that starts as you enter a dungeon or raid with your group
-- (GroupBuffs.StartRound, from BuffModeAuto.lua) and ends at the first pull
-- or when you leave, "whoever buffs first" (the owner, 2026-11-12): a buff
-- of yours or another member's put up more than SYNCED_SECONDS before you
-- entered is offered again once, so everyone's timer is fresh; one put up
-- since then is already in step and left be. When it was put up comes from
-- the aura's own times; a time that can't be read is never recast over.
-- Outside the round a member's buff is left alone until it runs low (top-up).
-- Never over anything stronger than a rank you know
-- (BuffData.CanReplace: #41's rule, and the game would refuse it), and the
-- one-Blessing rule stands. In a raid, the raid buff split (#70) still
-- decides which buffs are yours to give.
local _, ns = ...
local Util = ns.Util
local Read = Util.ReadGameValues

local GroupBuffs = {}
ns.GroupBuffs = GroupBuffs

-- After your buff lands on them, how long they count as having it even if
-- their buffs don't show it yet (the game updates them a moment later).
GroupBuffs.JUST_GIVEN_SECONDS = 10
-- Right-click skips a member for this long.
GroupBuffs.SKIP_SECONDS = 300
-- A member whose cast the game refused (out of range or sight) waits this long.
GroupBuffs.HELD_BACK_SECONDS = 15

-- Where you come in (#198): your own copy of each buff you give is offered
-- before the group's copy of that buff ("first", the default, the owner's
-- choice), or after it ("last"); your first buff still goes before anyone's
-- second. "off" leaves you out (specs that predate #198 start with it:
-- wow.boot). Only this line decides; the rest of the file follows it.
GroupBuffs.SELF_ORDER = "first"

local PARTY_UNITS, RAID_UNITS = {}, {}
for i = 1, 4 do PARTY_UNITS[i] = "party" .. i end
for i = 1, 40 do RAID_UNITS[i] = "raid" .. i end

local justGiven = {} -- [name .. "\1" .. buff key] = GetTime()
local skipped = {}   -- [name] = GetTime() you right-clicked them
local heldBack = {}  -- [name] = GetTime() the game refused a cast to them
local lastSelfWhy        -- why you were last left out of the offers (said once in debug)
-- While GroupBuffs.Missing asks (#272): any copy of a buff counts as worn
-- (running low, or anyone's), and only a member close by and known to be
-- online can be missing one. While it asks, this is the table of pairs
-- seen worn ([name .. "\1" .. buff key] = true); otherwise false.
local presentOnly = false
-- The dungeon-or-raid round (#256), or nil: { started = GetTime(), given =
-- { [name .. "\1" .. buff key] = true }, inStep = { [buff key] = { buff,
-- at, by } } (the newest member's buff it left alone as in step), order = {
-- buff keys as first noted }, shown = { [buff key] = true } }.
local round

-- In the round, a buff put up less than this long before you entered (or
-- since) is in step with everyone's and isn't recast (#256, the owner).
GroupBuffs.SYNCED_SECONDS = 300

-- The slots to look through: raid1..40 in a raid (one of them is you),
-- party1..4 in a party. Empty when you're in no group.
local function GroupUnits()
    if Read(IsInRaid) == true then return RAID_UNITS end
    if Read(IsInGroup) == true then return PARTY_UNITS end
    return {}
end

local function Recently(at, seconds)
    return at ~= nil and GetTime() - at < seconds
end

-- Whether the game says this member can't be buffed now, and why.
local function Unreachable(unit)
    if Read(UnitIsConnected, unit) == false then return "offline" end
    if Read(UnitIsDeadOrGhost, unit) == true then return "dead" end
    if Read(UnitIsVisible, unit) == false then return "out of sight" end
    local inRange, checked = Read(UnitInRange, unit)
    if checked == true and inRange == false then return "out of range" end
end

-- false when the game says the spell can't reach them; nil when it won't say.
local function InSpellRange(spell, unit)
    local inRange = Read(C_Spell and C_Spell.IsSpellInRange, spell, unit)
    if inRange == nil then inRange = Read(IsSpellInRange, spell, unit) end
    if inRange == false or inRange == 0 then return false end
    if inRange == true or inRange == 1 then return true end
end

-- Your top-up time in seconds (0: never), read defensively: settings
-- damaged mid-session mustn't stop the button.
local function TopUpSeconds()
    local limits = ns.Config.LIMITS.topUpMinutes
    return Util.ClampNumber(ns.db.buffBack.topUpMinutes, limits.min, limits.max,
        ns.Config.DEFAULTS.buffBack.topUpMinutes) * 60
end

-- Whether aura (readable, wearing buff) is yours to top up now: a rank you
-- can replace with less than the top-up time left. Its duration must be
-- longer than that time, or a fresh one would be offered again at once.
-- No, whenever its times are secret or not numbers: they're never compared.
local function RunningLow(aura, buff)
    -- 0 needs no test of its own: only a buff whose time has passed would count.
    local threshold = TopUpSeconds()
    local duration, expires = aura.duration, aura.expirationTime
    if Util.IsSecret(duration) or Util.IsSecret(expires) then return false end
    if type(duration) ~= "number" or type(expires) ~= "number" then return false end
    -- Each test says yes only for a real number, so NaN is a no. An expiry
    -- of 0 is an aura that never runs out.
    if not (duration > threshold and expires > 0 and expires - GetTime() < threshold) then return false end
    return ns.BuffData.CanReplace(buff, aura.spellId)
end

-- Who put up an aura with this caster (#256): "you", "group" (another
-- member), "outside" (not in your group, or a caster the game doesn't name),
-- or nil when it can't be read.
local function CasterOf(source, units)
    if source == nil then return "outside" end
    local me = Util.CastByYou(source)
    if me == nil then return nil end
    if me then return "you" end
    -- The game names a group member (or their pet) by a group token...
    if source:find("^party%d+$") or source:find("^raid%d+$") or source:find("^partypet%d+$")
        or source:find("^raidpet%d+$") then
        return "group"
    end
    -- ...or by another token that is one (a nameplate, your target).
    for _, unit in ipairs(units) do
        local same = Read(UnitIsUnit, source, unit)
        if same == nil then return nil end
        if same then return "group" end
    end
    return "outside"
end

-- When aura was put up (GetTime() clock), from its own times, or nil when
-- they can't be read or it never runs out. Secrets are never compared.
local function AppliedAt(aura)
    local duration, expires = aura.duration, aura.expirationTime
    if Util.IsSecret(duration) or Util.IsSecret(expires) then return nil end
    if type(duration) ~= "number" or type(expires) ~= "number" then return nil end
    -- Each test is true only for a real number, so NaN is a no.
    if not (duration > 0 and expires > 0) then return nil end
    return expires - duration
end

-- Whether the round recasts aura (yours or a group member's, covering buff)
-- on the member called name: put up more than SYNCED_SECONDS before the
-- round began, and not given to them yet this round. A time that can't be
-- read: no.
local function RoundRecasts(name, buff, aura)
    if not round or round.given[name .. "\1" .. buff.key] then return false end
    local at = AppliedAt(aura)
    return at ~= nil and at < round.started - GroupBuffs.SYNCED_SECONDS
end

-- A member's buff the round leaves alone because it's in step (#256, rule 2):
-- remember the newest per buff and who cast it, for the button's "Already
-- done by" note. Not one whose time can't be read, nor one old enough that
-- only an earlier cast this round kept it.
local function NoteInStep(buff, aura)
    if not round then return end
    local at = AppliedAt(aura)
    if at == nil or at < round.started - GroupBuffs.SYNCED_SECONDS then return end
    local seen = round.inStep[buff.key]
    if seen and seen.at >= at then return end
    if not seen then round.order[#round.order + 1] = buff.key end
    -- The caster's name, if the game gives it (a readable token here).
    round.inStep[buff.key] = { buff = buff, at = at, by = Util.UnitFullName(aura.sourceUnit) }
end

-- Whether your cast of buff would renew aura (readable, covering buff) on
-- member rather than leave it be (#256): true when someone outside the group
-- put it up, or the round recasts it (yours or a member's, old enough);
-- false otherwise, and for anything stronger than a rank you know; nil when
-- who cast it can't be read.
local function Renews(member, buff, aura, units)
    if not ns.BuffData.CanReplace(buff, aura.spellId) then return false end
    local who = CasterOf(aura.sourceUnit, units)
    if who == nil then return nil end
    if who == "outside" then return true end
    local recasts = RoundRecasts(member.name, buff, aura)
    if not recasts and who == "group" then NoteInStep(buff, aura) end
    return recasts
end

-- Whether member wears buff so that nothing is left to give: true, false
-- (missing it, running low, or wearing one your cast renews), or nil when
-- their buffs, or who cast the one that counts, can't be read; then why.
local function Wears(member, buff, units)
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not api then return nil, "can't see their buffs" end
    for i = 1, ns.Offers.MAX_AURAS do
        local ok, aura = pcall(api, member.unit, i, "HELPFUL")
        if not ok or Util.IsSecret(aura) then return nil, "can't see their buffs" end
        if aura == nil then return false end
        local id = aura.spellId
        if Util.IsSecret(id) then return nil, "can't see their buffs" end
        if ns.BuffData.Covers(buff, id) then
            -- Any copy at all is worn when only a missing buff counts (#272).
            if presentOnly then return true end
            -- Running low, it's renewed (top-up, #42), but never over a
            -- caster that can't be read (#256).
            local renews
            if RunningLow(aura, buff) then
                renews = CasterOf(aura.sourceUnit, units) ~= nil or nil
            else
                renews = Renews(member, buff, aura, units)
            end
            if renews == nil then return nil, "can't tell who cast their buff" end
            if not renews then return true end
        end
    end
    return false
end

-- Why a group version of buff mustn't cover this member (#256), or nil: it
-- would replace a buff of theirs whose caster can't be read, or another
-- member's that isn't running low (and the round doesn't recast), or they
-- wear buffs that can't be read at all. A group version covers everyone in its
-- party, subgroup or class, not only those missing the buff.
local function CoverBlocked(entry, buff, units, equals)
    -- Only a buff the cast would replace counts: one no stronger than the
    -- single rank the group version equals. The game keeps a stronger one.
    local equalsAt = ns.BuffData.RankOf(buff, equals)
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    local who = entry.isMe and "your" or ((entry.name and Util.DisplayName(entry.name) or "a group member") .. "'s")
    if not api then return "can't see " .. who .. " buffs" end
    for i = 1, ns.Offers.MAX_AURAS do
        local ok, aura = pcall(api, entry.unit, i, "HELPFUL")
        if not ok or Util.IsSecret(aura) then return "can't see " .. who .. " buffs" end
        if aura == nil then return nil end
        local id = aura.spellId
        if Util.IsSecret(id) then return "can't see " .. who .. " buffs" end
        local at = ns.BuffData.RankOf(buff, id)
        if ns.BuffData.Covers(buff, id) and not (at and equalsAt and at < equalsAt) then
            local caster = CasterOf(aura.sourceUnit, units)
            if caster == nil then return "can't tell who cast " .. who .. " buff" end
            -- Another member's buff is theirs until it runs low, or the
            -- round recasts it (#256, the owner).
            if caster == "group" and not RunningLow(aura, buff)
                and not (entry.name and RoundRecasts(entry.name, buff, aura)) then
                return who .. " buff is another group member's"
            end
        end
    end
end

-- Whether they wear another buff of this family (another Blessing) that you
-- cast: true, false, or nil when the game won't say (their buffs, or who
-- cast one, can't be read). A Blessing of yours that you've since left to
-- others in this raid doesn't count, so the one you switched to replaces it.
-- offered itself is Wears's to judge (running low, or renewed: #256).
local function WearsMyFamily(unit, family, offered)
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not api then return nil end
    for i = 1, ns.Offers.MAX_AURAS do
        local ok, aura = pcall(api, unit, i, "HELPFUL")
        if not ok or Util.IsSecret(aura) then return nil end
        if aura == nil then return false end
        local id = aura.spellId
        if Util.IsSecret(id) then return nil end
        local buff = ns.BuffData.ForAura(id)
        if buff and buff.family == family and buff.key ~= offered.key and ns.BuffRules.CoversInRaid(buff) then
            local mine = Util.CastByYou(aura.sourceUnit)
            if mine == nil then return nil end
            if mine then return true end
        end
    end
    return false
end

-- Reasons a member is left out that still leave a buff of yours to give
-- once they can have it (they're dead, out of reach for now, or can't be
-- read). Offline, out of sight, flagged when you aren't, or skipped by you
-- leave nothing to do now: "everyone has your buffs" can still be true.
local OPEN_REASONS = {
    ["dead"] = true, ["out of range"] = true,
    ["can't see whether they're flagged for PvP"] = true,
    ["the game refused your last cast to them"] = true,
}

-- Why this member can't have a buff now, or nil if they may.
local function CantBuff(unit, iAmFlagged)
    local why = Unreachable(unit)
    if why then return why end
    if not iAmFlagged then
        local flagged = Read(UnitIsPVP, unit)
        if flagged == true then return "flagged for PvP and you aren't" end
        if flagged == nil then return "can't see whether they're flagged for PvP" end
    end
end

-- The members who may be buffed now, in group order: { unit, name, class },
-- the first reason one was left out, and whether one left out may still
-- need a buff (OPEN_REASONS, or a name that can't be read).
local function Candidates(units)
    local me = Util.UnitFullName("player")
    local iAmFlagged = Read(UnitIsPVP, "player") == true
    local out, seen, firstReason, open = {}, {}, nil, false
    for _, unit in ipairs(units) do
        local name = Util.UnitFullName(unit)
        local isMe = (name ~= nil and name == me) or Read(UnitIsUnit, unit, "player") == true
        if Read(UnitExists, unit) == true and not isMe then
            if not name then
                firstReason = firstReason or "a group member's name can't be read"
                open = true
            elseif not seen[name] then
                seen[name] = true
                local why = CantBuff(unit, iAmFlagged)
                -- Missing (#272): only someone close by (the game's ~40-yard
                -- group range) and known to be online; a range or connection
                -- the game won't give isn't.
                if presentOnly and not why then
                    if Read(UnitIsConnected, unit) ~= true then
                        why = "can't tell whether they're online"
                    elseif Read(UnitInRange, unit) ~= true then
                        why = "not close by"
                    end
                end
                if Recently(skipped[name], GroupBuffs.SKIP_SECONDS) then
                    why = "skipped for now (you right-clicked them)"
                elseif Recently(heldBack[name], GroupBuffs.HELD_BACK_SECONDS) then
                    why = why or "the game refused your last cast to them"
                end
                if why then
                    firstReason = firstReason or (Util.DisplayName(name) .. ": " .. why)
                    open = open or OPEN_REASONS[why] == true
                else
                    out[#out + 1] = { unit = unit, name = name, class = select(2, Read(UnitClass, unit)) }
                end
            end
        end
    end
    return out, firstReason, open
end

-- You as a member to buff (#198): { unit = "player", name, class, self = true },
-- or nil, why not, and whether that leaves a buff to give later (dead, name
-- unreadable). Range and the PvP flag are about other people: a buff on
-- yourself can't be out of range or flag you.
local function SelfMember()
    local name = Util.UnitFullName("player")
    if not name then return nil, "your name can't be read", true end
    if Recently(skipped[name], GroupBuffs.SKIP_SECONDS) then
        return nil, "skipped for now (you right-clicked it)", false
    end
    if Recently(heldBack[name], GroupBuffs.HELD_BACK_SECONDS) then
        return nil, "the game refused your last cast on you", true
    end
    if Read(UnitIsDeadOrGhost, "player") == true then return nil, "you're dead", true end
    return { unit = "player", name = name, class = select(2, Read(UnitClass, "player")), self = true }
end

-- The next group member to buff: { name, buff, spell, group = true }, or
-- nil, why not, and whether that's settled: nothing left that a buff of
-- yours could fix now or soon (not in a group, or everyone you could buff
-- has them; nobody dead, out of reach or unreadable); when that's because
-- your water buff waits for water, that buff too. Your first buff
-- goes to everyone missing it before your second buff goes to anyone.
-- With a list (#43), each member the button would offer to is appended to
-- it once, in the order the button would reach them, with what it would
-- offer, instead of stopping at the first: the clickable list is made by
-- these same rules.
function GroupBuffs.Next(out)
    local units = GroupUnits()
    local first, listed = nil, {}
    -- One offer found: the first is returned at once, or with a list kept.
    local function Found(offer)
        if not out then return true end
        first = first or offer
        -- Missing lists each buff a member lacks; the button's list, each member once.
        local id = presentOnly and (offer.name .. "\1" .. offer.buff.key) or offer.name
        if not listed[id] then
            listed[id] = true
            out[#out + 1] = offer
        end
        return false
    end
    if #units == 0 then return nil, "you're not in a group", true end
    -- Water breathing waits for water (Water.lua): nothing to do now, and
    -- the buff held back is named (4th value) for buff mode's message.
    local myBuffs, held = ns.Water.Filter(ns.BuffData.Offerable())
    if #myBuffs == 0 then
        if held then return nil, ns.Water.HeldReason(held), true, held end
        return nil, "you have no buffs to offer", true
    end
    local members, firstReason, open = Candidates(units)
    local unreadable, outOfRange = {}, {}
    local family = {} -- [name .. buff key] = whether they wear another of yours (read once)
    -- Every reason a member is passed over here leaves a buff to give.
    local function Why(member, why)
        if member.self then
            -- The reasons are worded for someone else.
            why = why:gsub("they're", "you're"):gsub("they have", "you have"):gsub("their", "your")
        end
        firstReason = firstReason or ((member.self and "You" or Util.DisplayName(member.name)) .. ": " .. why)
        open = true
    end
    -- Whether member is missing buff and may have it (the rules allow it,
    -- nothing says they have it or just got it): true, or false. Anything
    -- that keeps a buff from them is said (Why) when it should be. Read once
    -- per member and buff: the group version asks too.
    local needs = {}
    local function Needs(buff, member)
        local nkey = member.name .. "\1" .. buff.key
        if needs[nkey] ~= nil then return needs[nkey] end
        local result = false
        -- Your rules for who gets the buff (BuffRules.lua). A member they
        -- leave out is passed over quietly: nothing is owed them.
        local allowed, ruleWhy = false, nil
        if not unreadable[member.name] and ns.BuffData.Useful(buff, member.class) then
            allowed, ruleWhy = ns.BuffRules.Allows(buff, member)
        end
        if allowed ~= false then
            local wears, wearsWhy = Wears(member, buff, units)
            local key = member.name .. "\1" .. buff.key
            if wears == nil then
                unreadable[member.name] = true
                Why(member, wearsWhy)
            elseif wears then
                -- A buff only running low is worn here: your top-up cast
                -- still counts as just given (#272).
                if presentOnly then presentOnly[key] = true else justGiven[key] = nil end
            elseif allowed == nil then
                -- The rules can't tell (an unreadable role or class):
                -- said, and not settled, only for a member missing it.
                Why(member, ruleWhy)
            elseif not Recently(justGiven[key], GroupBuffs.JUST_GIVEN_SECONDS) then
                local covered = false
                if buff.family then
                    local fkey = member.name .. "\1" .. buff.key
                    if family[fkey] == nil then
                        local mine = WearsMyFamily(member.unit, buff.family, buff)
                        if mine == nil then Why(member, "can't tell whose Blessing they have") end
                        family[fkey] = mine ~= false
                    end
                    covered = family[fkey]
                end
                result = not covered
            end
        end
        needs[nkey] = result
        return result
    end
    local groupCtx = { units = units, inRaid = Read(IsInRaid) == true, InRange = InSpellRange }
    -- The buffs for one list of members, in your buff order (the first
    -- buff goes to all of them before the second goes to any).
    local function Pass(list)
        for _, buff in ipairs(myBuffs) do
            -- A Blessing you've left to another paladin in this raid is passed
            -- over quietly ("My Blessings in this raid", BuffRules.lua).
            local spell = not buff.selfCast and ns.BuffRules.CoversInRaid(buff) and ns.BuffData.SpellName(buff)
            -- The group version comes before the single buff when enough of
            -- the group is missing it (GroupCasts.lua); if not, the single
            -- buff carries the reason. You still come first (#198) unless
            -- the group version covers you too.
            local note, quiet
            if spell then
                groupCtx.Needs = function(member) return Needs(buff, member) end
                groupCtx.Blocked = function(entry, equals) return CoverBlocked(entry, buff, units, equals) end
                local groupOffer
                groupOffer, note, quiet = ns.GroupCasts.Offer(buff, list, groupCtx)
                if groupOffer then
                    local mineFirst = list[1] and list[1].self and not groupOffer.cast.coversSelf
                        and Needs(buff, list[1])
                    if mineFirst then
                        local offer = { name = list[1].name, buff = buff, spell = spell, group = true, self = true }
                        if Found(offer) then return offer end
                    end
                    if Found(groupOffer) then return groupOffer end
                end
            end
            for _, member in ipairs(spell and list or {}) do
                if Needs(buff, member) then
                    -- Range is about other people: you are always in reach of yourself.
                    if not member.self and InSpellRange(spell, member.unit) == false then
                        if not outOfRange[member.name] then Why(member, "out of range") end
                        outOfRange[member.name] = true
                    else
                        local offer = { name = member.name, buff = buff, spell = spell, group = true,
                            self = member.self, note = not quiet and note or nil, hint = quiet and note or nil }
                        if Found(offer) then return offer end
                    end
                end
            end
        end
        return nil
    end
    -- You come first in each buff's round, before the group (SELF_ORDER,
    -- #198): your first buff still goes before anyone's second.
    local mine, mineWhy, mineOpen
    if GroupBuffs.SELF_ORDER ~= "off" then mine, mineWhy, mineOpen = SelfMember() end
    local list = members
    if mine then
        table.insert(list, GroupBuffs.SELF_ORDER == "last" and #list + 1 or 1, mine)
    elseif mineWhy then
        firstReason = firstReason or ("You: " .. mineWhy)
        open = open or mineOpen
        -- Debug says so once per reason, not at every refresh.
        if mineWhy ~= lastSelfWhy then ns.Diag.Log("buffMode", "not buffing you: %s", mineWhy) end
    end
    lastSelfWhy = mine == nil and mineWhy or nil
    local offer = Pass(list)
    if offer then return offer end
    if first then return first end
    return nil, firstReason or "everyone in your group has your buffs", not open
end

-- The members missing a buff of yours outright (#272), in the order the
-- button would reach them: { name, buff, ... } as Next lists them. Missing
-- means no copy at all, whoever cast it: never cast, or fully faded, and
-- not merely running low. Next's rules hold (your Buff Back rules, the raid
-- split, water, the one-Blessing rule), and a member counts only when close
-- by, online and readable: one whose buffs, name, connection or range can't
-- be read is never missing one. Each buff a member lacks is listed. Also
-- the pairs seen worn, { [name .. "\1" .. buff key] = true }: a member left
-- out of this look (out of range, say) is in neither. Nothing here casts.
function GroupBuffs.Missing()
    local list, worn = {}, {}
    presentOnly = worn
    local ok, err = pcall(GroupBuffs.Next, list)
    presentOnly = false
    if not ok then error(err, 0) end
    return list, worn
end

-- Your buff reached them (the game said so).
function GroupBuffs.NoteGiven(name, buff)
    justGiven[name .. "\1" .. buff.key] = GetTime()
    if round then round.given[name .. "\1" .. buff.key] = true end
end

-- Your press of a group buff went out but the game didn't say whom it
-- reached (BuffButton): the round counts it as given all the same, so the
-- same member isn't offered it on every press until the pull (#256). At
-- worst those it was for (everyone a group version covered) keep their
-- earlier buff, yours or another member's.
function GroupBuffs.NoteRoundCast(name, buff)
    if round then round.given[name .. "\1" .. buff.key] = true end
end

-- The dungeon-or-raid round (#256): from entering one with your group until
-- the first pull or leaving, "whoever buffs first" (the owner): a buff of
-- yours or another member's put up more than SYNCED_SECONDS before you
-- entered is offered once more; one put up since is in step and left alone
-- (and named once on the button, rule 2); one whose time can't be read is
-- never recast over.
function GroupBuffs.StartRound()
    round = { started = GetTime(), given = {}, inStep = {}, order = {}, shown = {} }
end

-- The next buff the round left alone as in step and hasn't shown yet (#256,
-- rule 2: once per buff each time you enter): { buff, by = the caster's
-- full name or nil }, or nil. Taking it marks it shown.
function GroupBuffs.TakeInStepNote()
    if not round then return nil end
    for _, key in ipairs(round.order) do
        if not round.shown[key] then
            round.shown[key] = true
            local seen = round.inStep[key]
            return { buff = seen.buff, by = seen.by }
        end
    end
end
function GroupBuffs.EndRound() round = nil end
function GroupBuffs.InRound() return round ~= nil end
-- The current round itself, to tell one round from the next (a note shown
-- for one ends with it), or nil.
function GroupBuffs.Round() return round end

-- The game refused a cast to them (out of range or sight): try the others
-- first for a moment.
function GroupBuffs.NoteRefused(name)
    heldBack[name] = GetTime()
end

-- The game's refusals that are about the target, not you: the client's own
-- strings where it has them, and their English text otherwise. A refusal
-- about you (the global cooldown, mana, being stunned) moves no one back.
local TARGET_REFUSAL_GLOBALS = {
    "SPELL_FAILED_LINE_OF_SIGHT", "SPELL_FAILED_OUT_OF_RANGE", "ERR_OUT_OF_RANGE",
    "SPELL_FAILED_BAD_TARGETS", "SPELL_FAILED_BAD_IMPLICIT_TARGETS", "SPELL_FAILED_TARGETS_DEAD",
}
local TARGET_REFUSAL_TEXT = {
    "target not in line of sight", "out of range", "invalid target", "no target", "target is dead",
}

local function Normalise(text)
    return (text:lower():gsub("[%.!]+$", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function GroupBuffs.IsTargetRefusal(text)
    if type(text) ~= "string" or Util.IsSecret(text) then return false end
    -- Colour codes come off first, so their letters don't stay behind.
    local said = Normalise(Util.StripChat((text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))))
    for _, name in ipairs(TARGET_REFUSAL_GLOBALS) do
        local known = rawget(_G, name)
        if type(known) == "string" and known ~= "" and Normalise(known) == said then return true end
    end
    for _, known in ipairs(TARGET_REFUSAL_TEXT) do
        if said == known then return true end
    end
    return false
end

-- Right-click: leave them out for a while.
function GroupBuffs.Skip(name)
    skipped[name] = GetTime()
end

-- Forget what's out of date, so the tables stay small in a long session.
function GroupBuffs.Prune()
    for key, at in pairs(justGiven) do
        if not Recently(at, GroupBuffs.JUST_GIVEN_SECONDS) then justGiven[key] = nil end
    end
    for name, at in pairs(skipped) do
        if not Recently(at, GroupBuffs.SKIP_SECONDS) then skipped[name] = nil end
    end
    for name, at in pairs(heldBack) do
        if not Recently(at, GroupBuffs.HELD_BACK_SECONDS) then heldBack[name] = nil end
    end
    ns.GroupCasts.Prune()
end
