-- The buffs each class gives other players on WoW Forever, by spell ID.
--
-- The IDs are Classic Era's (1.15). Forever may differ (a buff removed, a
-- talent made trainable); that can only mean a buff isn't offered, because a
-- buff whose spell you don't know never is.
--
-- Each buff:
--   key       our name for it (saved settings, buff order)
--   ranks     every rank's spell ID, highest first: "/cast <name>" casts the
--             highest you know, and any of them on a player means they have it
--   group     the group versions' IDs (Arcane Brilliance...): they count as having it
--   blockers  other buffs that do the same job (Scroll of Intellect...): ditto
--   manaOnly  only offered to classes that use mana
--   groupOnly only offered to your own group (Salvation)
--   selfCast  cast on yourself, reaching your party (Battle Shout): never a return
--   family    buffs of which a player keeps only one of yours (a paladin's
--             Blessings): casting another replaces it
--   defaultRule  who gets it in buff mode until you choose (BuffRules.lua);
--             everyone when not set
local _, ns = ...
local Util = ns.Util

local BuffData = {}
ns.BuffData = BuffData

BuffData.CLASSES = {
    MAGE = {
        { key = "intellect", ranks = { 10157, 10156, 1461, 1460, 1459 }, group = { 23028 },
            blockers = { 8096, 8097, 8098, 12176 }, manaOnly = true },
    },
    PRIEST = {
        { key = "fortitude", ranks = { 10938, 10937, 2791, 1245, 1244, 1243 }, group = { 21564, 21562 },
            blockers = { 8099, 8100, 8101, 12178 } },
        { key = "spirit", ranks = { 27841, 14819, 14818, 14752 }, group = { 27681 },
            blockers = { 8112, 8113, 8114, 12177 }, manaOnly = true },
        { key = "shadow", ranks = { 10958, 10957, 976 }, group = { 27683 } },
    },
    DRUID = {
        { key = "motw", ranks = { 9885, 9884, 8907, 5234, 6756, 5232, 1126 }, group = { 21850, 21849 } },
        { key = "thorns", ranks = { 9910, 9756, 8914, 1075, 782, 467 } },
    },
    PALADIN = {
        { key = "kings", ranks = { 20217 }, group = { 25898 }, family = "blessing" },
        { key = "wisdom", ranks = { 25290, 19854, 19853, 19852, 19850, 19742 }, group = { 25918, 25894 },
            manaOnly = true, family = "blessing" },
        { key = "might", ranks = { 25291, 19838, 19837, 19836, 19835, 19834, 19740 }, group = { 25916, 25782 },
            family = "blessing" },
        { key = "light", ranks = { 19979, 19978, 19977 }, group = { 25890 }, family = "blessing" },
        -- Not a Blessing on Forever: it's worn beside one (#68). Kept off
        -- tanks by default, who don't want less threat.
        { key = "salvation", ranks = { 1038 }, group = { 25895 }, groupOnly = true, defaultRule = "notTanks" },
    },
    WARLOCK = {
        { key = "breath", ranks = { 5697 }, group = { 131 } },
    },
    WARRIOR = {
        { key = "battleshout", ranks = { 25289, 11551, 11550, 11549, 6192, 5242, 6673 }, selfCast = true },
    },
}

-- Classes that use mana (unit power is a secret for strangers on Forever,
-- so the class decides). Druids count: they do in caster form.
BuffData.MANA_CLASSES = {
    MAGE = true, PRIEST = true, DRUID = true, PALADIN = true, WARLOCK = true, SHAMAN = true, HUNTER = true,
}

-- [key] = true for every buff of every class: what a saved buff order or
-- never-offer mark may name.
BuffData.KEYS = {}
local byKey = {}
for _, list in pairs(BuffData.CLASSES) do
    for _, buff in ipairs(list) do
        BuffData.KEYS[buff.key] = true
        byKey[buff.key] = buff
    end
end

function BuffData.ByKey(key)
    return byKey[key]
end

-- Revoke (Forever, paladins): takes Salvation off a party or raid member.
-- Its spell ID isn't known yet (checked at launch, #50), so it's found by
-- its English name: in the spellbook (C_Spell.GetSpellInfo answers a name
-- only for a spell you know), and in cast events by the cast spell's name.
-- On a client in another language it isn't found, and isn't offered.
BuffData.REVOKE = { key = "revoke", name = "Revoke", ranks = {}, removes = "salvation" }

-- [spell ID] = buff, for every rank, group version and blocker.
local byAuraId = {}
-- [spell ID] = buff, for the ranks only (what our own casts can be).
local byRankId = {}
for _, list in pairs(BuffData.CLASSES) do
    for _, buff in ipairs(list) do
        for _, field in ipairs({ "ranks", "group", "blockers" }) do
            for _, id in ipairs(buff[field] or {}) do byAuraId[id] = buff end
        end
        for _, id in ipairs(buff.ranks) do byRankId[id] = buff end
    end
end

-- The buff a spell ID belongs to (any rank, group version or blocker), or nil.
function BuffData.ForAura(spellId)
    return byAuraId[spellId]
end

local Read = Util.ReadGameValues

-- The buff one of our casts was (or Revoke), or nil.
function BuffData.ForCast(spellId)
    local buff = byRankId[spellId]
    if buff then return buff end
    if spellId ~= nil and Read(C_Spell and C_Spell.GetSpellName, spellId) == BuffData.REVOKE.name then
        return BuffData.REVOKE
    end
end

function BuffData.RevokeKnown()
    local info = Read(C_Spell and C_Spell.GetSpellInfo, BuffData.REVOKE.name)
    return type(info) == "table"
end

-- The buff's name as the game spells it ("Mark of the Wild"), for /cast and
-- for showing. Every rank has the same name, so the first one the client knows.
function BuffData.SpellName(buff)
    for _, id in ipairs(buff.ranks) do
        local name = Read(C_Spell and C_Spell.GetSpellName, id) or Read(GetSpellInfo, id)
        if type(name) == "string" and name ~= "" then return name end
    end
end

-- The icon of the buff's lowest rank (or, for Revoke, of its name), for the button.
function BuffData.Icon(buff)
    local id = buff.ranks[#buff.ranks] or buff.name
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
