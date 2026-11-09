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
--   blockers  other buffs that do the same job (Unending Breath for Water Breathing): ditto
--   manaOnly  only offered to classes that use mana
--   selfCast  cast on yourself, reaching your party (Battle Shout): never a return
--   family    buffs of which a player keeps only one of yours (a paladin's
--             Blessings): casting another replaces it
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
-- doesn't have, or that the owner excluded (Blessing of Light, #225), is not in it.
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

-- [spell ID] = buff, for every rank, group version and blocker. A spell
-- that is one buff's rank and another's blocker (Water Breathing, Unending
-- Breath) belongs to the buff it's a rank of: ranks are filled in last.
local byAuraId = {}
-- [spell ID] = buff, for the ranks only (what our own casts can be).
local byRankId = {}
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

-- Spells of buffs left out of the game's buffs: Blessing of Salvation and
-- Mass Salvation, which Blizzard removed before launch (#208), and Blessing of
-- Light, which the owner believes it removed (#225; the data still has it).
-- Nothing offers, tracks or thanks for them; an aura with one of these IDs
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
-- for showing. Every rank has the same name, so the first one the client knows.
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
    for _, id in ipairs(buff.ranks) do
        if Known(id) then return true end
    end
    return false
end

-- Whether your cast of buff can replace spellId on a player, to top it up
-- (#42): spellId is one of buff's ranks, and you know that rank or a higher
-- one. A group version, a blocker or a rank above yours is left to run out:
-- the game may refuse a weaker cast over it.
function BuffData.CanReplace(buff, spellId)
    if Util.IsSecret(spellId) then return false end
    local known = false
    for _, id in ipairs(buff.ranks) do
        known = known or Known(id)
        if id == spellId then return known end
    end
    return false
end

-- Your class's buffs that you know, in order. Kept until your spells change
-- (BuffData.SpellsChanged), since it takes a spellbook call per rank.
local mine
function BuffData.Mine()
    if mine then return mine end
    local _, class = Read(UnitClass, "player")
    local out = {}
    for _, buff in ipairs(class and BuffData.CLASSES[class] or {}) do
        if BuffData.IsKnown(buff) then out[#out + 1] = buff end
    end
    -- An unreadable class isn't remembered: the next call asks again.
    if class then mine = out end
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

-- Whether you've marked buff "never offer" on the Buff Back tab.
function BuffData.NeverOffered(buff)
    local never = ns.db and type(ns.db.buffBack) == "table" and ns.db.buffBack.neverOffer
    return type(never) == "table" and never[buff.key] == true
end

-- The buffs the button may offer: yours that you know, in your order, less
-- any marked "never offer".
function BuffData.Offerable()
    local order = ns.db and type(ns.db.buffBack) == "table" and ns.db.buffBack.buffOrder
    local out = {}
    for _, buff in ipairs(BuffData.InOrder(BuffData.Mine(), order)) do
        if not BuffData.NeverOffered(buff) then out[#out + 1] = buff end
    end
    return out
end

-- Call when the spellbook changes (SPELLS_CHANGED, a spell learned).
function BuffData.SpellsChanged()
    mine = nil
end

-- Whether a class wants this buff. class: their file name ("WARRIOR") or nil
-- when unknown, which wants everything.
function BuffData.Useful(buff, class)
    if buff.manaOnly and class and not BuffData.MANA_CLASSES[class] then return false end
    return true
end
