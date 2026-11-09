-- Who gets each of your buffs in buff mode (Buff Back tab): everyone who can
-- use it, tanks only, everyone but tanks, or chosen classes; plus players you
-- name as Always or Never. Buff back to strangers doesn't use these: a
-- stranger's role can't be known, so they keep the class check alone.
--
-- Tanks are read from the group, never kept in the addon: the group role
-- TANK, or a raid's Main Tank assignment (what raid tank frames show). A
-- member is a tank if either says so. A role that can't be read gives no
-- tanks-only buff, and no buff kept off tanks either (less threat on a tank
-- is the worse mistake).
--
-- Saved in buffBack.whoGets: [buff key] = { rule, classes = { [CLASS] = true },
-- always = { [name key] = full name }, never = { ... } }. A missing or damaged
-- rule is the buff's default (BuffData's defaultRule, else everyone). Chosen
-- classes work the same way: a saved classes table (even an empty one) is
-- yours; without one, the buff's defaultClasses apply (#219). A default is saved
-- only once you choose classes or tick one, so a player who never chose gets any
-- later change to it.
local _, ns = ...
local Util = ns.Util

local BuffRules = {}
ns.BuffRules = BuffRules

-- In the order the Buff Back tab's button steps through them.
BuffRules.RULES = { "all", "tanks", "notTanks", "classes" }
BuffRules.RULE_TEXT = {
    all = "Everyone", tanks = "Tanks only", notTanks = "Everyone but tanks", classes = "Chosen classes",
}
BuffRules.IS_RULE = {}
for _, rule in ipairs(BuffRules.RULES) do BuffRules.IS_RULE[rule] = true end

-- The classes a "chosen classes" rule can tick.
BuffRules.CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
BuffRules.IS_CLASS = {}
for _, class in ipairs(BuffRules.CLASSES) do BuffRules.IS_CLASS[class] = true end

-- Names kept in each Always or Never list, and in all of them together, at
-- most (the total keeps a settings line within what import reads).
BuffRules.MAX_NAMES = 100
BuffRules.MAX_TOTAL_NAMES = 500
BuffRules.NAME_LISTS = { always = true, never = true }
-- A list's box holds a full list of the longest names (two 48-letter parts,
-- a space, and ", " between names).
BuffRules.MAX_LIST_LETTERS = BuffRules.MAX_NAMES * (48 * 2 + 1 + 2)

local function Saved()
    local b = ns.db and ns.db.buffBack
    local all = type(b) == "table" and b.whoGets
    return type(all) == "table" and all or nil
end

local function Entry(key)
    local all = Saved()
    local entry = all and all[key]
    return type(entry) == "table" and entry or nil
end

-- The entry for key, made if missing (for the setters).
local function OwnEntry(key)
    local b = ns.db.buffBack
    if type(b.whoGets) ~= "table" then b.whoGets = {} end
    local entry = b.whoGets[key]
    if type(entry) ~= "table" then
        entry = {}
        b.whoGets[key] = entry
    end
    return entry
end

-- The classes ticked for buff: your saved ones; none, when you saved
-- "Chosen classes" and ticked nothing (all it meant before #219); else its
-- default's (no entry, no rule, or a damaged class list).
local function ChosenClasses(buff, entry)
    if entry and type(entry.classes) == "table" then return entry.classes end
    if entry and entry.classes == nil and entry.rule == "classes" then return {} end
    return buff and buff.defaultClasses or {}
end

-- Save the classes ticked now (the default's, if you've chosen none) into
-- entry, so what you see stays as you chose it.
local function OwnClasses(key, entry)
    if type(entry.classes) ~= "table" then
        local now = ChosenClasses(ns.BuffData.ByKey(key), entry)
        entry.classes = {}
        for class, ticked in pairs(now) do
            if ticked == true then entry.classes[class] = true end
        end
    end
    return entry.classes
end

function BuffRules.DefaultRule(buff)
    return buff.defaultRule or "all"
end

-- The rule in force for buff: saved, or its default.
function BuffRules.Rule(buff)
    local entry = Entry(buff.key)
    local rule = entry and entry.rule
    if BuffRules.IS_RULE[rule] then return rule end
    return BuffRules.DefaultRule(buff)
end

-- One answer from a game function: the value, and whether it could be read
-- (false when the function is missing, throws, or answers a secret).
local function Answer(fn, ...)
    if type(fn) ~= "function" then return nil, false end
    local ok, value = pcall(fn, ...)
    if not ok or Util.IsSecret(value) then return nil, false end
    return value, true
end

-- Whether the game says unit is a tank: true, false, or nil when it can't
-- tell. Either answer saying tank is enough. "Not a tank" needs every
-- answer that applies to be readable: the group role always, and in a raid
-- the Main Tank assignment too (a secret one could hide a tank whose role
-- says damage). Outside a raid there's no Main Tank, so its "no" says
-- nothing: a client without group roles can't tell a party's tank.
function BuffRules.IsTank(unit)
    local role, roleRead = Answer(UnitGroupRolesAssigned, unit)
    roleRead = roleRead and type(role) == "string"
    local mainTank, mainTankRead = Answer(GetPartyAssignment, "MAINTANK", unit)
    if (roleRead and role == "TANK") or (mainTankRead and mainTank and mainTank ~= 0) then return true end
    if Util.ReadGameValues(IsInRaid) ~= true then
        if roleRead then return false end
        return nil
    end
    local roleSays = roleRead or UnitGroupRolesAssigned == nil
    local mainTankSays = mainTankRead or GetPartyAssignment == nil
    if roleSays and mainTankSays and (roleRead or mainTankRead) then return false end
    return nil
end

local function Named(entry, list, name)
    local names = entry and entry[list]
    return type(names) == "table" and names[ns.Config.IgnoreKey(name)] ~= nil
end

-- Whether buff may go to member ({ unit, name, class }): true; false and
-- why when your rules leave them out; nil and why when it can't be told.
function BuffRules.Allows(buff, member)
    local entry = Entry(buff.key)
    if Named(entry, "never", member.name) then return false, "you set Never for them" end
    -- The raid buff split (#70): a share of some groups leaves the others to
    -- other copies, whatever your lists say.
    local covered, splitWhy = ns.RaidSplit.CoversMember(buff, member)
    if not covered then return false, splitWhy end
    if Named(entry, "always", member.name) then return true end
    local rule = BuffRules.Rule(buff)
    if rule == "all" then return true end
    if rule == "classes" then
        if not member.class then return nil, "can't see their class" end
        local classes = ChosenClasses(buff, entry)
        if classes[member.class] == true then return true end
        return false, "not a class you chose"
    end
    local tank = BuffRules.IsTank(member.unit)
    if tank == nil then return nil, "can't tell if they're a tank" end
    if rule == "tanks" then
        if tank then return true end
        return false, "not a tank"
    end
    if tank then return false, "a tank" end
    return true
end

-- Setters, for the Buff Back tab. Each refreshes the button.

function BuffRules.SetRule(key, rule)
    if not ns.BuffData.KEYS[key] or not BuffRules.IS_RULE[rule] then return end
    local entry = OwnEntry(key)
    -- Choosing classes keeps the ones shown (the default's), as a saved list.
    if rule == "classes" then OwnClasses(key, entry) end
    entry.rule = rule
    ns.BuffButton.Refresh()
end

-- The rule after buff's current one, wrapping round.
function BuffRules.NextRule(buff)
    local now = BuffRules.Rule(buff)
    for i, rule in ipairs(BuffRules.RULES) do
        if rule == now then return BuffRules.RULES[i % #BuffRules.RULES + 1] end
    end
    return BuffRules.RULES[1]
end

function BuffRules.HasClass(buff, class)
    return ChosenClasses(buff, Entry(buff.key))[class] == true
end

function BuffRules.SetClass(key, class, on)
    if not ns.BuffData.KEYS[key] or not BuffRules.IS_CLASS[class] then return end
    local entry = OwnEntry(key)
    local classes = OwnClasses(key, entry)
    classes[class] = on and true or nil
    ns.BuffButton.Refresh()
end

-- Set an Always or Never list from text: names separated by commas
-- ("Ann Vale, Cid Rock"). Returns true, or false and why (nothing changes).
-- Names separated by commas, as a list ([name key] = full name) and its
-- size; or nil and why not.
local function ParseNames(text)
    if type(text) ~= "string" then return nil, "type names separated by commas" end
    local names, n = {}, 0
    for part in text:gmatch("[^,]+") do
        local trimmed = part:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            local full = Util.FullName(trimmed)
            if not full then return nil, "'" .. Util.StripChat(trimmed) .. "' isn't a player name" end
            local nameKey = ns.Config.IgnoreKey(full)
            if not names[nameKey] then
                n = n + 1
                if n > BuffRules.MAX_NAMES then
                    return nil, "at most " .. BuffRules.MAX_NAMES .. " names"
                end
                names[nameKey] = full
            end
        end
    end
    return names, n
end

-- A list ([name key] = full name) as text, names sorted (ignoring case).
local function ListText(names)
    local out = {}
    for _, full in pairs(type(names) == "table" and names or {}) do out[#out + 1] = Util.DisplayName(full) end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return table.concat(out, ", ")
end

function BuffRules.SetNames(key, list, text)
    if not ns.BuffData.KEYS[key] or not BuffRules.NAME_LISTS[list] then return false, "unknown list" end
    local names, n = ParseNames(text)
    if not names then return false, n end
    -- With every other list as it is, the total stays within its cap.
    local others = 0
    for otherKey, entry in pairs(Saved() or {}) do
        for otherList in pairs(BuffRules.NAME_LISTS) do
            if type(entry) == "table" and type(entry[otherList]) == "table"
                and not (otherKey == key and otherList == list) then
                for _ in pairs(entry[otherList]) do others = others + 1 end
            end
        end
    end
    if others + n > BuffRules.MAX_TOTAL_NAMES then
        return false, "at most " .. BuffRules.MAX_TOTAL_NAMES .. " names across all your buffs"
    end
    OwnEntry(key)[list] = names
    ns.BuffButton.Refresh()
    return true
end

-- Add one player (a full name) to an Always or Never list, within its caps.
-- Returns true, or false and why.
function BuffRules.AddName(key, list, fullName)
    local text = BuffRules.NamesText(key, list)
    if type(fullName) ~= "string" then return false, "no name" end
    local display = Util.DisplayName(fullName)
    return BuffRules.SetNames(key, list, text == "" and display or (text .. ", " .. display))
end

-- An Always or Never list as text for its box, names sorted (ignoring case).
function BuffRules.NamesText(key, list)
    local entry = Entry(key)
    return ListText(entry and entry[list])
end

-- A clean copy of saved whoGets (Config's validator): known buff keys only,
-- known rules (a damaged one is dropped, so the buff's default applies),
-- known classes, and names that are player names, each list and the total
-- capped.
function BuffRules.Clean(value)
    local clean = {}
    if type(value) ~= "table" then return clean end
    local total = 0 -- names kept across every list (MAX_TOTAL_NAMES)
    for key, entry in pairs(value) do
        if type(key) == "string" and ns.BuffData.KEYS[key] and type(entry) == "table" then
            local out = {}
            if BuffRules.IS_RULE[entry.rule] then out.rule = entry.rule end
            if type(entry.classes) == "table" then
                out.classes = {}
                for class, on in pairs(entry.classes) do
                    if BuffRules.IS_CLASS[class] and on == true then out.classes[class] = true end
                end
            elseif entry.classes ~= nil and out.rule == "classes" then
                -- A damaged list reads as the default's (ChosenClasses); a repair must not make it "none".
                out.classes = {}
                -- A key kept known without a buff (BuffTable.absent) has no defaults (#209).
                local buff = ns.BuffData.ByKey(key)
                for class, ticked in pairs(buff and buff.defaultClasses or {}) do
                    if ticked == true then out.classes[class] = true end
                end
            end
            for list in pairs(BuffRules.NAME_LISTS) do
                if type(entry[list]) == "table" then
                    local names, n = {}, 0
                    for nameKey, full in pairs(entry[list]) do
                        local name = ns.Config.IgnoreEntry(nameKey, full)
                        if name and n < BuffRules.MAX_NAMES and total < BuffRules.MAX_TOTAL_NAMES
                            and not names[ns.Config.IgnoreKey(name)] then
                            names[ns.Config.IgnoreKey(name)] = name
                            n, total = n + 1, total + 1
                        end
                    end
                    out[list] = names
                end
            end
            clean[key] = out
        end
    end
    return clean
end

------------------------------------------------------------------------
-- My Blessings in this raid (paladins)
------------------------------------------------------------------------

-- Which of your Blessings you cover in the raid you're in, so two paladins
-- don't both give Kings: nil when you haven't chosen (all of them), or
-- [buff key] = true. Kept for this raid only, never saved: it's forgotten
-- as soon as you're not in a raid (an unreadable answer counts as not).
local raidBlessings

local function InRaid()
    return Util.ReadGameValues(IsInRaid) == true
end

-- Forget the choice once you're out of the raid. Called before each use.
function BuffRules.CheckRaid()
    if raidBlessings and not InRaid() then raidBlessings = nil end
end

-- The Blessings you know (the "blessing" family), in your class's order.
function BuffRules.MyBlessings()
    local out = {}
    for _, buff in ipairs(ns.BuffData.Mine()) do
        if buff.family == "blessing" then out[#out + 1] = buff end
    end
    return out
end

-- Whether you cover buff in this raid: the Blessings you chose, once you
-- have; otherwise your share of the raid buff split (RaidSplit.lua, #70),
-- which is every buff when there's no split (not in a raid, or no other
-- copy of your class in it).
function BuffRules.CoversInRaid(buff)
    BuffRules.CheckRaid()
    if raidBlessings and buff.family == "blessing" then return raidBlessings[buff.key] == true end
    return ns.RaidSplit.Covers(buff)
end

-- The Blessings you chose for this raid, as a copy ([key] = true), or nil
-- when you haven't (the split then decides). Announced to the other copies
-- of your class in the raid (RaidSplit.lua).
function BuffRules.HandSetBlessings()
    BuffRules.CheckRaid()
    if not raidBlessings then return nil end
    local out = {}
    for key in pairs(raidBlessings) do out[key] = true end
    return out
end

-- Choose the Blessings you cover in this raid: keys is a list of your
-- Blessings' keys, or nil for all of them. Returns true, or false and why.
function BuffRules.SetRaidBlessings(keys)
    if not InRaid() then return false, "you're not in a raid" end
    if keys == nil then
        raidBlessings = nil
        ns.BuffButton.Refresh()
        return true
    end
    local mine, chosen, count, all = {}, {}, 0, 0
    for _, buff in ipairs(BuffRules.MyBlessings()) do
        mine[buff.key] = true
        all = all + 1
    end
    for _, key in ipairs(keys) do
        if not mine[key] then return false, "'" .. Util.StripChat(tostring(key)) .. "' isn't one of your Blessings" end
        if not chosen[key] then count = count + 1 end
        chosen[key] = true
    end
    if count == 0 then return false, "choose at least one Blessing (or all)" end
    raidBlessings = count < all and chosen or nil
    ns.BuffButton.Refresh()
    return true
end

-- Whether you've narrowed your Blessings for this raid.
function BuffRules.RaidBlessingsChosen()
    BuffRules.CheckRaid()
    return raidBlessings ~= nil
end
