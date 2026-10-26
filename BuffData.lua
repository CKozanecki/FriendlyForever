-- The buffs each class gives other players on WoW Forever, by spell ID.
--
-- The IDs are Classic Era's (1.15). Another addon (Manners) reports that
-- Forever drops Blessing of Sanctuary and trains Kings and Divine Spirit
-- rather than making them talents; that is unverified here, and harmless
-- either way: a buff whose spell you don't know is never offered.
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
        { key = "kings", ranks = { 20217 }, group = { 25898 } },
        { key = "wisdom", ranks = { 25290, 19854, 19853, 19852, 19850, 19742 }, group = { 25918, 25894 },
            manaOnly = true },
        { key = "might", ranks = { 25291, 19838, 19837, 19836, 19835, 19834, 19740 }, group = { 25916, 25782 } },
        { key = "light", ranks = { 19979, 19978, 19977 }, group = { 25890 } },
        { key = "salvation", ranks = { 1038 }, group = { 25895 }, groupOnly = true },
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

-- The buff one of our casts was, or nil.
function BuffData.ForCast(spellId)
    return byRankId[spellId]
end

local Ask = Util.Ask

-- The buff's name as the game spells it ("Mark of the Wild"), for /cast and
-- for showing. Every rank has the same name, so the first one the client knows.
function BuffData.SpellName(buff)
    for _, id in ipairs(buff.ranks) do
        local name = Ask(C_Spell and C_Spell.GetSpellName, id) or Ask(GetSpellInfo, id)
        if type(name) == "string" and name ~= "" then return name end
    end
end

-- The icon of the buff's lowest rank, for the button.
function BuffData.Icon(buff)
    local id = buff.ranks[#buff.ranks]
    return Ask(C_Spell and C_Spell.GetSpellTexture, id) or Ask(GetSpellTexture, id)
end

-- Whether you know spell `id`. Forever keeps IsSpellKnown and IsPlayerSpell
-- only as shims behind a setting that may be off, so the spellbook is asked
-- first (as Manners found).
local function Known(id)
    local book = C_SpellBook
    if type(book) == "table" then
        local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
        if Ask(book.IsSpellInSpellBook, id, bank, false) == true or Ask(book.IsSpellKnown, id, bank) == true then
            return true
        end
    end
    return Ask(IsSpellKnown, id) == true or Ask(IsPlayerSpell, id) == true
end

function BuffData.IsKnown(buff)
    for _, id in ipairs(buff.ranks) do
        if Known(id) then return true end
    end
    return false
end

-- Your class's buffs that you know, in order.
function BuffData.Mine()
    local _, class = UnitClass("player")
    if Util.IsSecret(class) then return {} end
    local out = {}
    for _, buff in ipairs(BuffData.CLASSES[class] or {}) do
        if BuffData.IsKnown(buff) then out[#out + 1] = buff end
    end
    return out
end

-- Whether a class wants this buff. class: their file name ("WARRIOR") or nil
-- when unknown, which wants everything.
function BuffData.Useful(buff, class)
    if buff.manaOnly and class and not BuffData.MANA_CLASSES[class] then return false end
    return true
end
