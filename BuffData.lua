-- The buffs each class gives other players on WoW Forever, by spell ID.
--
-- The IDs come from BuffTable.lua, generated from Forever's spell data by
-- scripts/gen_spell_table.py once per game version (#209). A buff whose
-- spell you don't know is never offered.
--
-- Each buff:
--   key       our name for it (saved settings, buff order)
--   ranks     every rank's spell ID, highest first: "/cast <name>" casts the
--             highest you know, and any of them on a player means they have it
--   group     the group versions' IDs (Arcane Brilliance...): they count as having it
--   groupCast the group version you can cast (GroupCasts.lua, #41): scope
--             "party" (the target's party) or "class" (every member of the
--             target's class in the raid: Greater Blessings), and spells, highest rank first,
--             each { id, reagent = item ID, equals = the single-target rank
--             of the same strength }; every id is also in group
--   blockers  other buffs that do the same job (Unending Breath for Water Breathing): ditto
--   manaOnly  only offered to classes that use mana
--   selfCast  a self-buff (#44): cast on yourself only (some reach others
--             from you: Battle Shout, Trueshot Aura, paladin auras). Never a
--             return, never given to the group: SelfBuffs.lua offers them
--   toggle    a self-buff that stays on until switched (an Aspect, a paladin
--             aura): never topped up, and cast with "!" so a press can't
--             switch it off
--   defaultNever  "Never offer" until you tick or untick it (Righteous Fury)
--   family    buffs of which a player keeps only one of yours (a paladin's
--             Blessings; a mage's armors, a hunter's Aspects, a paladin's
--             auras): casting another replaces it
--   ranks of a self-buff may be two spells' (Ice Armor's, then Frost
--             Armor's): "/cast" names the one you know best (CastName)
--   defaultRule  who gets it in buff mode until you choose (BuffRules.lua);
--             everyone when not set
--   defaultClasses  the classes a "chosen classes" default gives it to,
--             { CLASS = true }; used until you tick your own (#219)
--   water     only helps underwater: offered only near water, when the
--             setting says so (Water.lua, #136)
local _, ns = ...
-- BuffTable.lua is a file added in #209: after an update that added it, /reload
-- runs this file without it. Define nothing, so Core's check asks for a restart.
if type(ns.BuffTable) ~= "table" then return end

local Util = ns.Util

local BuffData = {}
ns.BuffData = BuffData

-- The table is generated from Forever's own spell data (BuffTable.lua, #209):
-- the addon never looks IDs up while you play. A buff whose spell the data
-- doesn't have, or that Blizzard removed (Blessing of Light, #237), is not in it.
local Table = ns.BuffTable
BuffData.CLASSES = Table.classes

-- Classes that use mana (unit power is a secret for strangers on Forever,
-- so the class decides). Druids count: they do in caster form.
BuffData.MANA_CLASSES = {
    MAGE = true, PRIEST = true, DRUID = true, PALADIN = true, WARLOCK = true, SHAMAN = true, HUNTER = true,
}

-- [key] = true for every buff of every class: what a saved buff order or
-- never-offer mark may name.
BuffData.KEYS = {}
local byKey = {}
-- Buffs left out of the table keep their keys, so saved settings that name
-- them still load and keep their values.
for _, key in ipairs(Table.absent) do BuffData.KEYS[key] = true end
for _, list in pairs(BuffData.CLASSES) do
    for _, buff in ipairs(list) do
        BuffData.KEYS[buff.key] = true
        byKey[buff.key] = buff
    end
end

function BuffData.ByKey(key)
    return byKey[key]
end

-- The reagents of the group versions (#41), by item ID. The IDs and names are
-- Classic Era's; Forever's are unconfirmed (#202, #225). They are hand-listed,
-- not generated: the spell data has no items (scripts/spell-buffs.json holds
-- the reagent of each group cast, checked only for range). The name is only a
-- fallback for messages: the client's own is used when it has it.
BuffData.REAGENTS = {
    [17020] = "Arcane Powder", [17028] = "Holy Candle", [17029] = "Sacred Candle",
    [17021] = "Wild Berries", [17026] = "Wild Thornroot", [21177] = "Symbol of Kings",
}

-- [spell ID] = buff, for every rank, group version and blocker. A spell
-- that is one buff's rank and another's blocker (Water Breathing, Unending
-- Breath) belongs to the buff it's a rank of: ranks are filled in last.
local byAuraId = {}
-- [spell ID] = buff, for the ranks only (what our own casts can be).
local byRankId = {}
-- [spell ID] = buff, for the group versions you can cast (#41).
local byGroupCastId = {}
-- [buff] = { [spell ID] = true }: every spell that counts as having it.
local covers = {}
for _, list in pairs(BuffData.CLASSES) do
    for _, buff in ipairs(list) do
        covers[buff] = {}
        for _, field in ipairs({ "ranks", "group", "blockers" }) do
            for _, id in ipairs(buff[field] or {}) do covers[buff][id] = true end
        end
        for _, field in ipairs({ "group", "blockers" }) do
            for _, id in ipairs(buff[field] or {}) do byAuraId[id] = buff end
        end
        for _, spell in ipairs(buff.groupCast and buff.groupCast.spells or {}) do byGroupCastId[spell.id] = buff end
    end
end
-- [buff] = { [spell ID] = place in buff.ranks, 1 the highest }: each rank at
-- its own place, and each group version you can cast at the place of the
-- single rank of the same strength (#206).
local rankAt = {}
for _, list in pairs(BuffData.CLASSES) do
    for _, buff in ipairs(list) do
        local at = {}
        for i, id in ipairs(buff.ranks) do at[id] = i end
        for _, spell in ipairs(buff.groupCast and buff.groupCast.spells or {}) do
            at[spell.id] = at[spell.equals]
        end
        rankAt[buff] = at
    end
end
for _, list in pairs(BuffData.CLASSES) do
    for _, buff in ipairs(list) do
        for _, id in ipairs(buff.ranks) do
            byAuraId[id] = buff
            byRankId[id] = buff
        end
    end
end

-- [spell ID] = family, for the spells that count as wearing a family of
-- self-buffs but are never offered (Aspect of the Cheetah, of the Pack and
-- of the Beast, #44).
local familyAuraOf = {}
for family, ids in pairs(type(Table.familyAuras) == "table" and Table.familyAuras or {}) do
    for _, id in ipairs(ids) do familyAuraOf[id] = family end
end

-- The family of self-buffs a spell ID counts for: a rank of a self-buff in
-- a family, or one of its other spells (familyAuras); nil otherwise, and
-- for a secret.
function BuffData.SelfFamilyOf(spellId)
    if Util.IsSecret(spellId) then return nil end
    local buff = byRankId[spellId]
    if buff and buff.selfCast then return buff.family end
    return familyAuraOf[spellId]
end

-- Spells of buffs left out of the game's buffs: Blessing of Salvation and
-- Mass Salvation, which Blizzard removed before launch (#208), and Blessing of
-- Light, which Blizzard removed too (owner, with Blizzard's beta development
-- notes of November 2; #237), and Omen of Clarity, a passive talent on
-- Forever rather than a buff to cast (its spell data; owner, #44). The data
-- still has rows for all of them. Nothing offers, tracks or thanks for them; an aura with one of these IDs
-- (a stale one) is passed over quietly.
local REMOVED_SPELL_IDS = {}
for _, id in ipairs(Table.removedSpells) do REMOVED_SPELL_IDS[id] = true end

-- Whether spellId is one of a buff the game no longer has. A secret, or
-- anything that isn't a number, is not.
function BuffData.IsRemoved(spellId)
    if type(spellId) ~= "number" or Util.IsSecret(spellId) then return false end
    return REMOVED_SPELL_IDS[spellId] == true
end

-- The buff a spell ID belongs to (any rank, group version or blocker), or nil.
function BuffData.ForAura(spellId)
    return byAuraId[spellId]
end

-- Whether wearing spell spellId counts as having buff (any of its ranks,
-- group versions or blockers).
function BuffData.Covers(buff, spellId)
    local ids = covers[buff]
    -- A secret mustn't be used as a table key (the game raises an error).
    if ids == nil or Util.IsSecret(spellId) then return false end
    return ids[spellId] == true
end

local Read = Util.ReadGameValues

-- The buff one of our casts was, or nil.
function BuffData.ForCast(spellId)
    return byRankId[spellId]
end

-- The buff's name as the game spells it ("Mark of the Wild"), for /cast and
-- for showing. Every rank has the same name, so the first one the client
-- knows. (A self-buff of two spells has two: CastName.)
function BuffData.SpellName(buff)
    for _, id in ipairs(buff.ranks) do
        local name = Read(C_Spell and C_Spell.GetSpellName, id) or Read(GetSpellInfo, id)
        if type(name) == "string" and name ~= "" then return name end
    end
end

-- The icon of the buff's lowest rank, for the button.
function BuffData.Icon(buff)
    local id = buff.ranks[#buff.ranks]
    if id == nil then return nil end
    return Read(C_Spell and C_Spell.GetSpellTexture, id) or Read(GetSpellTexture, id)
end

-- Whether you know spell `id`: any of the client's answers that says yes.
-- C_SpellBook is the current API; IsSpellKnown and IsPlayerSpell are the
-- older ones, kept for clients that still have them.
local function Known(id)
    local book = C_SpellBook
    if type(book) == "table" then
        local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
        if Read(book.IsSpellInSpellBook, id, bank, false) == true or Read(book.IsSpellKnown, id, bank) == true then
            return true
        end
    end
    return Read(IsSpellKnown, id) == true or Read(IsPlayerSpell, id) == true
end

function BuffData.IsKnown(buff)
    return BuffData.KnownRank(buff) ~= nil
end

-- The highest rank of buff you know (its spell ID), or nil.
function BuffData.KnownRank(buff)
    for _, id in ipairs(buff.ranks) do
        if Known(id) then return id end
    end
    return nil
end

-- The name to cast buff by: the name of the highest rank you know, which is
-- what "/cast <name>" casts. For a self-buff of two spells (Ice Armor and
-- Frost Armor, #44) that is the one you know best. nil when you know none,
-- or the client won't name it.
function BuffData.CastName(buff)
    local id = BuffData.KnownRank(buff)
    if id == nil then return nil end
    local name = Read(C_Spell and C_Spell.GetSpellName, id) or Read(GetSpellInfo, id)
    if type(name) == "string" and name ~= "" then return name end
end

-- The group version of buff you can cast, or nil: { id, reagent, equals,
-- name, scope }, the highest rank you know, which is the one "/cast <name>"
-- casts (#41). A group version you haven't learned is never offered, so no
-- level table is needed here, the same test as the single-target ranks.
function BuffData.KnownGroupCast(buff)
    local cast = buff.groupCast
    if not cast then return nil end
    for _, spell in ipairs(cast.spells) do
        if Known(spell.id) then
            local name = Read(C_Spell and C_Spell.GetSpellName, spell.id) or Read(GetSpellInfo, spell.id)
            if type(name) ~= "string" or name == "" then return nil end
            return { id = spell.id, reagent = spell.reagent, equals = spell.equals, name = name, scope = cast.scope }
        end
    end
    return nil
end

-- The name of buff's group version as the game spells it, learned or not.
function BuffData.GroupCastName(buff)
    local spell = buff.groupCast and buff.groupCast.spells[1]
    local name = spell and Read(C_Spell and C_Spell.GetSpellName, spell.id)
    if type(name) == "string" and name ~= "" then return name end
end

-- The buff a group version's spell ID belongs to, or nil (one of our group
-- casts, as ForCast is for the single-target ones).
function BuffData.ForGroupCast(spellId)
    if Util.IsSecret(spellId) then return nil end
    return byGroupCastId[spellId]
end

-- How strong spellId is as buff: its place in buff.ranks (1 the highest),
-- a group version you can cast counting as the single rank it equals (#206),
-- or nil for anything else (a blocker, a group version with no single rank
-- of its strength, another buff, a secret).
function BuffData.RankOf(buff, spellId)
    local at = rankAt[buff]
    -- A secret mustn't be used as a table key (the game raises an error).
    if at == nil or Util.IsSecret(spellId) then return nil end
    return at[spellId]
end

-- Whether your cast of buff can replace spellId on a player, to top it up
-- (#42): spellId is one of buff's ranks, or a group version you can cast
-- (#206), and you know a single rank at least as strong. A blocker or
-- anything stronger than every rank you know is left to run out: the game
-- may refuse a weaker cast over it.
function BuffData.CanReplace(buff, spellId)
    local at = BuffData.RankOf(buff, spellId)
    if at == nil then return false end
    for i = 1, at do
        if Known(buff.ranks[i]) then return true end
    end
    return false
end

-- Your class's buffs for others that you know, in order: not your
-- self-buffs (MySelfBuffs, #44). Kept until your spells change
-- (BuffData.SpellsChanged), since it takes a spellbook call per rank.
local mine, mineSelf
local function KnownOfKind(wantSelf)
    local _, class = Read(UnitClass, "player")
    local out = {}
    for _, buff in ipairs(class and BuffData.CLASSES[class] or {}) do
        if (buff.selfCast == true) == wantSelf and BuffData.IsKnown(buff) then out[#out + 1] = buff end
    end
    -- An unreadable class isn't remembered: the next call asks again.
    return out, class ~= nil
end
function BuffData.Mine()
    if mine then return mine end
    local out, keep = KnownOfKind(false)
    if keep then mine = out end
    return out
end

-- Your self-buffs that you know, in your class's order (#44).
function BuffData.MySelfBuffs()
    if mineSelf then return mineSelf end
    local out, keep = KnownOfKind(true)
    if keep then mineSelf = out end
    return out
end

-- Your class's buffs, known or not, in the class's own order.
function BuffData.ClassBuffs()
    local _, class = Read(UnitClass, "player")
    return class and BuffData.CLASSES[class] or {}
end

-- buffs reordered by order (a list of buff keys, from the Buff Back tab):
-- the buffs it names come first, in its order; the rest follow in the order
-- they came. A copy; anything in order that isn't a key is passed over.
function BuffData.InOrder(buffs, order)
    local rank = {}
    if type(order) == "table" then
        for i, key in ipairs(order) do
            if type(key) == "string" and rank[key] == nil then rank[key] = i end
        end
    end
    local out = {}
    for i, buff in ipairs(buffs) do out[i] = { buff = buff, at = i } end
    local unranked = math.huge
    table.sort(out, function(a, b)
        local ra, rb = rank[a.buff.key] or unranked, rank[b.buff.key] or unranked
        if ra ~= rb then return ra < rb end
        return a.at < b.at
    end)
    for i, entry in ipairs(out) do out[i] = entry.buff end
    return out
end

-- Whether buff is marked "never offer" on the Buff Back tab: as you
-- ticked or unticked it, or until you have, its default (Righteous Fury's
-- is on, #44). Only true and false are a choice.
function BuffData.NeverOffered(buff)
    local never = ns.db and type(ns.db.buffBack) == "table" and ns.db.buffBack.neverOffer
    local chosen
    if type(never) == "table" then chosen = never[buff.key] end
    if chosen == true or chosen == false then return chosen end
    return buff.defaultNever == true
end

local function OfferableOf(buffs)
    local order = ns.db and type(ns.db.buffBack) == "table" and ns.db.buffBack.buffOrder
    local out = {}
    for _, buff in ipairs(BuffData.InOrder(buffs, order)) do
        if not BuffData.NeverOffered(buff) then out[#out + 1] = buff end
    end
    return out
end

-- The buffs the button may offer others: yours that you know, in your
-- order, less any marked "never offer". Never a self-buff.
function BuffData.Offerable()
    return OfferableOf(BuffData.Mine())
end

-- The self-buffs the button may offer you (#44): those you know, in your
-- buff order, less any marked "never offer".
function BuffData.SelfOfferable()
    return OfferableOf(BuffData.MySelfBuffs())
end

-- Call when the spellbook changes (SPELLS_CHANGED, a spell learned).
function BuffData.SpellsChanged()
    mine, mineSelf = nil, nil
end

-- Whether a class wants this buff. class: their file name ("WARRIOR") or nil
-- when unknown, which wants everything.
function BuffData.Useful(buff, class)
    if buff.manaOnly and class and not BuffData.MANA_CLASSES[class] then return false end
    return true
end
