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
--   groupCast the group version you can cast (GroupCasts.lua, #41): scope
--             "party" (the target's party) or "class" (every member of the
--             target's class in the raid: Greater Blessings), and spells, highest rank first,
--             each { id, reagent = item ID, equals = the single-target rank
--             of the same strength }; every id is also in group
--   blockers  other buffs that do the same job (Scroll of Intellect...): ditto
--   manaOnly  only offered to classes that use mana
--   selfCast  cast on yourself, reaching your party (Battle Shout): never a return
--   family    buffs of which a player keeps only one of yours (a paladin's
--             Blessings): casting another replaces it
--   defaultRule  who gets it in buff mode until you choose (BuffRules.lua);
--             everyone when not set
--   defaultClasses  the classes a "chosen classes" default gives it to,
--             { CLASS = true }; used until you tick your own (#219)
--   water     only helps underwater: offered only near water, when the
--             setting says so (Water.lua, #136)
local _, ns = ...
local Util = ns.Util

local BuffData = {}
ns.BuffData = BuffData

BuffData.CLASSES = {
    MAGE = {
        { key = "intellect", ranks = { 10157, 10156, 1461, 1460, 1459 }, group = { 23028 },
            blockers = { 8096, 8097, 8098, 12176 }, manaOnly = true,
            groupCast = { scope = "party", spells = { { id = 23028, reagent = 17020, equals = 10157 } } } },
    },
    PRIEST = {
        { key = "fortitude", ranks = { 10938, 10937, 2791, 1245, 1244, 1243 }, group = { 21564, 21562 },
            blockers = { 8099, 8100, 8101, 12178 },
            groupCast = { scope = "party", spells = {
                { id = 21564, reagent = 17029, equals = 10938 }, { id = 21562, reagent = 17028, equals = 10937 } } } },
        { key = "spirit", ranks = { 27841, 14819, 14818, 14752 }, group = { 27681 },
            blockers = { 8112, 8113, 8114, 12177 }, manaOnly = true,
            groupCast = { scope = "party", spells = { { id = 27681, reagent = 17029, equals = 27841 } } } },
        { key = "shadow", ranks = { 10958, 10957, 976 }, group = { 27683 },
            groupCast = { scope = "party", spells = { { id = 27683, reagent = 17029, equals = 10958 } } } },
    },
    DRUID = {
        { key = "motw", ranks = { 9885, 9884, 8907, 5234, 6756, 5232, 1126 }, group = { 21850, 21849 },
            groupCast = { scope = "party", spells = {
                { id = 21850, reagent = 17026, equals = 9885 }, { id = 21849, reagent = 17021, equals = 9884 } } } },
        { key = "thorns", ranks = { 9910, 9756, 8914, 1075, 782, 467 }, defaultRule = "tanks" },
    },
    PALADIN = {
        { key = "kings", ranks = { 20217 }, group = { 25898 }, family = "blessing",
            groupCast = { scope = "class", spells = { { id = 25898, reagent = 21177, equals = 20217 } } } },
        { key = "wisdom", ranks = { 25290, 19854, 19853, 19852, 19850, 19742 }, group = { 25918, 25894 },
            groupCast = { scope = "class", spells = {
                { id = 25918, reagent = 21177, equals = 25290 }, { id = 25894, reagent = 21177, equals = 19854 } } },
            manaOnly = true, family = "blessing", defaultRule = "classes",
            defaultClasses = { PALADIN = true, HUNTER = true, PRIEST = true, SHAMAN = true, MAGE = true,
                WARLOCK = true, DRUID = true } },
        { key = "might", ranks = { 25291, 19838, 19837, 19836, 19835, 19834, 19740 }, group = { 25916, 25782 },
            groupCast = { scope = "class", spells = {
                { id = 25916, reagent = 21177, equals = 25291 }, { id = 25782, reagent = 21177, equals = 19838 } } },
            family = "blessing", defaultRule = "classes",
            defaultClasses = { WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true, SHAMAN = true,
                DRUID = true } },
        { key = "light", ranks = { 19979, 19978, 19977 }, group = { 25890 }, family = "blessing" },
    },
    SHAMAN = {
        -- Does the same job as a warlock's Unending Breath, and the other way
        -- round (#136).
        { key = "waterbreathing", ranks = { 131 }, blockers = { 5697 }, water = true },
    },
    WARLOCK = {
        -- 131 is the shaman's Water Breathing: no group version of Unending
        -- Breath, but it does the same job, so it's a blocker (#135).
        { key = "breath", ranks = { 5697 }, blockers = { 131 }, water = true },
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

-- The reagents of the group versions (#41), by item ID. The IDs and names are
-- Classic Era's; Forever's are unconfirmed (#202). The name is only a
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
for _, list in pairs(BuffData.CLASSES) do
    for _, buff in ipairs(list) do
        for _, id in ipairs(buff.ranks) do
            byAuraId[id] = buff
            byRankId[id] = buff
        end
    end
end

-- Buffs Blizzard removed before launch (#208): Blessing of Salvation and
-- Mass Salvation. Nothing offers, tracks or thanks for them; an aura with
-- one of these IDs (a stale one) is passed over quietly.
local REMOVED_SPELL_IDS = { [1038] = true, [25895] = true }

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
