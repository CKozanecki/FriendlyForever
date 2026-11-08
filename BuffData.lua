-- The buffs each class gives other players on WoW Forever: the one place
-- that says which buffs exist (#209). Other files ask it by buff key.
--
-- The game's spell API decides what exists (#209). The table keeps each
-- buff's English spell name and its rules; the spell IDs in it are only
-- hints, Classic Era's (1.15), which Forever may have changed. Every ID is
-- checked against the API before it's used (BuffData.Refresh): the spell
-- must exist, and its name must be the one the table expects. The ID of the
-- highest rank you know is asked of the API by name, and an aura or cast
-- whose ID isn't in the table is still recognised by its spell name. A buff
-- whose spell the API doesn't know is not available: never offered, listed
-- or errored on, with the reason in debug. Saved settings that name it keep
-- their values (KEYS lists every key, available or not).
--
-- Each buff:
--   key       our name for it (saved settings, buff order)
--   name      the spell's English name ("Mark of the Wild"), asked of the API
--   groupNames  the group versions' English names (Gift of the Wild...)
--   blockerNames  the English names of the spells that count as having it (Unending Breath)
--   ranks     hint: every rank's spell ID, highest first: "/cast <name>" casts
--             the highest you know, and any of them on a player means they have
--             it. Their order is the only rank order the API doesn't give.
--   group     hint: the group versions' IDs: they count as having it
--   blockers  hint: other buffs that do the same job (Scroll of Intellect...): ditto
--   manaOnly  only offered to classes that use mana
--   groupOnly only offered to your own group (Salvation)
--   selfCast  cast on yourself, reaching your party (Battle Shout): never a return
--   family    buffs of which a player keeps only one of yours (a paladin's
--             Blessings): casting another replaces it
--   defaultRule  who gets it in buff mode until you choose (BuffRules.lua);
--             everyone when not set
--   water     only helps underwater: offered only near water, when the
--             setting says so (Water.lua, #136)
local _, ns = ...
local Util = ns.Util
local Read = Util.ReadGameValues

local BuffData = {}
ns.BuffData = BuffData

BuffData.CLASSES = {
    MAGE = {
        { key = "intellect", name = "Arcane Intellect", groupNames = { "Arcane Brilliance" },
            blockerNames = { "Intellect" },
            ranks = { 10157, 10156, 1461, 1460, 1459 }, group = { 23028 },
            blockers = { 8096, 8097, 8098, 12176 }, manaOnly = true },
    },
    PRIEST = {
        { key = "fortitude", name = "Power Word: Fortitude", groupNames = { "Prayer of Fortitude" },
            blockerNames = { "Stamina" },
            ranks = { 10938, 10937, 2791, 1245, 1244, 1243 }, group = { 21564, 21562 },
            blockers = { 8099, 8100, 8101, 12178 } },
        { key = "spirit", name = "Divine Spirit", groupNames = { "Prayer of Spirit" }, blockerNames = { "Spirit" },
            ranks = { 27841, 14819, 14818, 14752 }, group = { 27681 },
            blockers = { 8112, 8113, 8114, 12177 }, manaOnly = true },
        { key = "shadow", name = "Shadow Protection", groupNames = { "Prayer of Shadow Protection" },
            ranks = { 10958, 10957, 976 }, group = { 27683 } },
    },
    DRUID = {
        { key = "motw", name = "Mark of the Wild", groupNames = { "Gift of the Wild" },
            ranks = { 9885, 9884, 8907, 5234, 6756, 5232, 1126 }, group = { 21850, 21849 } },
        { key = "thorns", name = "Thorns", ranks = { 9910, 9756, 8914, 1075, 782, 467 } },
    },
    PALADIN = {
        { key = "kings", name = "Blessing of Kings", groupNames = { "Greater Blessing of Kings" },
            ranks = { 20217 }, group = { 25898 }, family = "blessing" },
        { key = "wisdom", name = "Blessing of Wisdom", groupNames = { "Greater Blessing of Wisdom" },
            ranks = { 25290, 19854, 19853, 19852, 19850, 19742 }, group = { 25918, 25894 },
            manaOnly = true, family = "blessing" },
        { key = "might", name = "Blessing of Might", groupNames = { "Greater Blessing of Might" },
            ranks = { 25291, 19838, 19837, 19836, 19835, 19834, 19740 }, group = { 25916, 25782 },
            family = "blessing" },
        { key = "light", name = "Blessing of Light", groupNames = { "Greater Blessing of Light" },
            ranks = { 19979, 19978, 19977 }, group = { 25890 }, family = "blessing" },
        -- Not a Blessing on Forever: it's worn beside one (#68). Kept off
        -- tanks by default, who don't want less threat.
        { key = "salvation", name = "Blessing of Salvation", groupNames = { "Greater Blessing of Salvation" },
            ranks = { 1038 }, group = { 25895 }, groupOnly = true, defaultRule = "notTanks" },
    },
    SHAMAN = {
        -- Does the same job as a warlock's Unending Breath, and the other way
        -- round (#136).
        { key = "waterbreathing", name = "Water Breathing",
            blockerNames = { "Unending Breath" }, ranks = { 131 }, blockers = { 5697 }, water = true },
    },
    WARLOCK = {
        -- 131 is the shaman's Water Breathing: no group version of Unending
        -- Breath, but it does the same job, so it's a blocker (#135).
        { key = "breath", name = "Unending Breath",
            blockerNames = { "Water Breathing" }, ranks = { 5697 }, blockers = { 131 }, water = true },
    },
    WARRIOR = {
        { key = "battleshout", name = "Battle Shout",
            ranks = { 25289, 11551, 11550, 11549, 6192, 5242, 6673 }, selfCast = true },
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
-- Blizzard removed it right before launch (owner, Nov 8); the code is
-- #208's. Its spell ID isn't recorded, so it's found by its English name: in the spellbook (C_Spell.GetSpellInfo
-- answers a name only for a spell you know), and in cast events by the cast spell's name.
-- On a client in another language it isn't found, and isn't offered.
BuffData.REVOKE = { key = "revoke", name = "Revoke", ranks = {}, removes = "salvation" }

-- Resolving the hints against the game's spell API (#209).
--
-- Everything the API returns is untrusted: an ID must be a whole number in
-- range, a name a short string, and neither may be a secret value (never
-- compared or used as a key).
local MAX_SPELL_ID = 16777215
local MAX_NAME_BYTES = 128

local function ValidId(id)
    if Util.IsSecret(id) then return false end
    return type(id) == "number" and id == id and id >= 1 and id <= MAX_SPELL_ID and id % 1 == 0
end

-- The game's name for spell id, or nil when it has none (a spell the game
-- doesn't have), or the answer is odd.
local function NameOf(id)
    if not ValidId(id) then return nil end
    local name = Read(C_Spell and C_Spell.GetSpellName, id) or Read(GetSpellInfo, id)
    if type(name) == "string" and name ~= "" and #name <= MAX_NAME_BYTES then return name end
end

-- Names are compared only on an English client: elsewhere the game spells
-- them in its own language, so a hint is trusted when its spell exists.
local function ComparesNames()
    local locale = Read(GetLocale)
    return locale == nil or locale == "enUS" or locale == "enGB"
end

local function Log(fmt, ...)
    if ns.Diag then ns.Diag.Log("buffData", fmt, ...) end
end

-- Whether hint id is a real spell of this game that is one of names (any
-- name when names is nil).
local function Verified(id, names)
    local name = NameOf(id)
    if not name then return false end
    if names == nil or not ComparesNames() then return true end
    for _, expected in ipairs(names) do
        if name == expected then return true end
    end
    return false
end

-- The ID the API gives for the highest rank of spell `name` that you know.
local function IdByName(name)
    local info = Read(C_Spell and C_Spell.GetSpellInfo, name)
    if type(info) ~= "table" or Util.IsSecret(info) then return nil end
    local id = info.spellID
    if not ValidId(id) or not Verified(id, { name }) then return nil end
    return id
end

local function List(value)
    if type(value) ~= "table" then return {} end
    return value
end

-- What Build makes; nil whenever it's stale.
--   ranks[buff]    the verified rank IDs: the hints in order, an ID only the API gave first
--   covers[buff]   { [id] = true } for every ID that counts as having it
--   byAura[id]     the buff an ID belongs to; byRank[id] likewise, ranks only
--   byName[name]   a list of { buff, role = "rank" | "group" | "blocker" }
--   unseen[id]     the byName list for an ID no table has, or false
local resolved

local UNSEEN_CAP = 512

local function Build()
    local r = { ranks = {}, covers = {}, byAura = {}, byRank = {}, byName = {}, unseen = {}, unseenCount = 0 }
    local owner, ambiguous = {}, {}
    local buffs = {}
    for _, list in pairs(List(BuffData.CLASSES)) do
        for _, buff in ipairs(List(list)) do
            if type(buff) == "table" and type(buff.name) == "string" then buffs[#buffs + 1] = buff end
        end
    end
    for _, buff in ipairs(buffs) do
        local ranks, seen = {}, {}
        local function add(id)
            if ValidId(id) and not seen[id] then
                seen[id] = true
                ranks[#ranks + 1] = id
            end
        end
        for _, id in ipairs(List(buff.ranks)) do
            if ValidId(id) and Verified(id, { buff.name }) then add(id) end
        end
        -- The API's answer keeps its place among the hints; an ID the hints
        -- lack (Forever numbered it differently) is the best we know: first.
        local byName = IdByName(buff.name)
        if byName and not seen[byName] then
            seen[byName] = true
            table.insert(ranks, 1, byName)
        end
        r.ranks[buff] = ranks
        for _, id in ipairs(ranks) do
            if owner[id] and owner[id] ~= buff then ambiguous[id] = true end
            owner[id] = buff
        end
        local function named(name, role)
            if type(name) ~= "string" then return end
            r.byName[name] = r.byName[name] or {}
            table.insert(r.byName[name], { buff = buff, role = role })
        end
        named(buff.name, "rank")
        for _, name in ipairs(List(buff.groupNames)) do named(name, "group") end
        for _, name in ipairs(List(buff.blockerNames)) do named(name, "blocker") end
    end
    -- An ID two buffs both claim as a rank belongs to neither.
    for _, buff in ipairs(buffs) do
        local kept = {}
        for _, id in ipairs(r.ranks[buff]) do
            if ambiguous[id] then
                Log("%s: spell %s is also another buff's rank; not used", buff.key, id)
            else
                kept[#kept + 1] = id
            end
        end
        r.ranks[buff] = kept
        if #kept == 0 then Log("%s not available: the game has no spell %s", buff.key, buff.name) end
    end
    for _, buff in ipairs(buffs) do
        local covers = {}
        r.covers[buff] = covers
        for _, id in ipairs(r.ranks[buff]) do covers[id] = true end
        for _, id in ipairs(List(buff.group)) do
            if ValidId(id) and Verified(id, buff.groupNames) then
                covers[id] = true
                if r.byAura[id] == nil then r.byAura[id] = buff end
            end
        end
        for _, id in ipairs(List(buff.blockers)) do
            if ValidId(id) and Verified(id, nil) then
                covers[id] = true
                if r.byAura[id] == nil then r.byAura[id] = buff end
            end
        end
    end
    -- Ranks are filled in last: a spell that is one buff's rank and another's
    -- blocker (Water Breathing, Unending Breath) belongs to the buff it's a rank of.
    for _, buff in ipairs(buffs) do
        for _, id in ipairs(r.ranks[buff]) do
            r.byAura[id] = buff
            r.byRank[id] = buff
        end
    end
    return r
end

local function State()
    if not resolved then resolved = Build() end
    return resolved
end

-- Ask the API again for every buff. Also happens by itself the first time
-- anything is asked, and after BuffData.SpellsChanged.
function BuffData.Refresh()
    BuffData.SpellsChanged()
    State()
end

-- The byName hits (a list) for an ID no table has (the game numbered it differently),
-- or nil. Remembered, up to a limit.
local function ByNameOfId(id)
    local r = State()
    local seen = r.unseen[id]
    if seen ~= nil then return seen or nil end
    local name = NameOf(id)
    local hit = name and r.byName[name] or nil
    if r.unseenCount >= UNSEEN_CAP then r.unseen, r.unseenCount = {}, 0 end
    r.unseen[id] = hit or false
    r.unseenCount = r.unseenCount + 1
    return hit
end

-- The buff a spell ID belongs to (any rank, group version or blocker), or nil.
function BuffData.ForAura(spellId)
    if not ValidId(spellId) then return nil end
    local buff = State().byAura[spellId]
    if buff then return buff end
    local hits = ByNameOfId(spellId)
    if not hits then return nil end
    -- As with IDs, a spell that is one buff's rank and another's blocker
    -- (Water Breathing, Unending Breath) belongs to the buff it's a rank of.
    for _, hit in ipairs(hits) do
        if hit.role == "rank" then return hit.buff end
    end
    return hits[1].buff
end

-- Whether wearing spell spellId counts as having buff (any of its ranks,
-- group versions or blockers).
function BuffData.Covers(buff, spellId)
    -- A secret mustn't be used as a table key (the game raises an error).
    if not ValidId(spellId) then return false end
    local ids = State().covers[buff]
    if ids == nil then return false end
    if ids[spellId] == true then return true end
    for _, hit in ipairs(ByNameOfId(spellId) or {}) do
        if hit.buff == buff then return true end
    end
    return false
end

-- The buff one of our casts was (or Revoke), or nil.
function BuffData.ForCast(spellId)
    if Util.IsSecret(spellId) or spellId == nil then return nil end
    if ValidId(spellId) then
        local buff = State().byRank[spellId]
        if buff then return buff end
        for _, hit in ipairs(ByNameOfId(spellId) or {}) do
            if hit.role == "rank" then return hit.buff end
        end
        if Read(C_Spell and C_Spell.GetSpellName, spellId) == BuffData.REVOKE.name then
            return BuffData.REVOKE
        end
    end
end

function BuffData.RevokeKnown()
    local info = Read(C_Spell and C_Spell.GetSpellInfo, BuffData.REVOKE.name)
    return type(info) == "table"
end

-- Whether the game has this buff's spell at all (it need not be yours): the
-- API found at least one rank. A buff it doesn't know is never offered or listed.
function BuffData.Available(buff)
    local ranks = State().ranks[buff]
    return ranks ~= nil and #ranks > 0
end

-- The buff's name as the game spells it ("Mark of the Wild"), for /cast and
-- for showing. Every rank has the same name, so the first one the client knows.
function BuffData.SpellName(buff)
    for _, id in ipairs(State().ranks[buff] or {}) do
        local name = NameOf(id)
        if name then return name end
    end
end

-- The icon of the buff's lowest rank, for the button.
function BuffData.Icon(buff)
    local ranks = State().ranks[buff] or {}
    local id = ranks[#ranks] or buff.name
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
    for _, id in ipairs(State().ranks[buff] or {}) do
        if Known(id) then return true end
    end
    return false
end

-- Whether your cast of buff can replace spellId on a player, to top it up
-- (#42): spellId is one of buff's ranks, and you know that rank or a higher
-- one. A group version, a blocker, a rank above yours or an ID the API
-- didn't give is left to run out: the game may refuse a weaker cast over it.
function BuffData.CanReplace(buff, spellId)
    if not ValidId(spellId) then return false end
    local known = false
    for _, id in ipairs(State().ranks[buff] or {}) do
        known = known or Known(id)
        if id == spellId then return known end
    end
    return false
end

-- The table's list for a class (an empty one when it's missing or damaged).
local function ClassList(class)
    local classes = BuffData.CLASSES
    local list = type(classes) == "table" and class and classes[class]
    return type(list) == "table" and list or {}
end

-- Your class's buffs that you know, in order. Kept until your spells change
-- (BuffData.SpellsChanged), since it takes a spellbook call per rank.
local mine
function BuffData.Mine()
    if mine then return mine end
    local _, class = Read(UnitClass, "player")
    local out = {}
    for _, buff in ipairs(ClassList(class)) do
        if BuffData.IsKnown(buff) then out[#out + 1] = buff end
    end
    -- An unreadable class isn't remembered: the next call asks again.
    if class then mine = out end
    return out
end

-- Your class's buffs the game has, known or not, in the class's own order.
function BuffData.ClassBuffs()
    local _, class = Read(UnitClass, "player")
    local out = {}
    for _, buff in ipairs(ClassList(class)) do
        if BuffData.Available(buff) then out[#out + 1] = buff end
    end
    return out
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
    resolved = nil
end

-- Whether a class wants this buff. class: their file name ("WARRIOR") or nil
-- when unknown, which wants everything.
function BuffData.Useful(buff, class)
    if buff.manaOnly and class and not BuffData.MANA_CLASSES[class] then return false end
    return true
end
