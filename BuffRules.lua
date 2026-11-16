-- Who gets each of your buffs: in buff mode and, by class, in buff back.
--
-- By place (#408): four places, each with its own rule for each buff, saved
-- in buffBack as whoStrangers (Buff Back: strangers who buffed you),
-- whoParty, whoRaid and whoPvP (a battleground or an arena). A rule is a set
-- of ticks (Everyone; Tanks, Healers, Damage by role; chosen classes), any of
-- which covers a member, plus Always and Never names (not for strangers). No
-- tick is Off. No saved rule is the place's default (BuffRules.DEFAULTS).
-- Which place applies is read by BuffRules.Place; a place that can't be read
-- gives a buff only when every place it could be gives it.
--
-- Until the player chooses (buffBack.whoChoice "pending": every file saved
-- before #408), nothing changes: the rule below (1.3.3's, buffBack.whoGets)
-- applies in every group, and strangers keep the class check alone.
-- BuffRules.Choose makes the choice: "kept" copies those rules to Party and
-- Raid, "new" takes the defaults.
--
-- 1.3.3's rule, while pending: everyone who can use it, tanks only, everyone
-- but tanks, or chosen classes; plus players you name as Always or Never.
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
local Read = Util.ReadGameValues

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
-- nothing: a client without group roles can't tell a party's tank. "Outside
-- a raid" is believed only as buff mode's group look believes it (#368:
-- GroupBuffs.RaidAnswer); while the game won't say, it may be a raid.
function BuffRules.IsTank(unit)
    local role, roleRead = Answer(UnitGroupRolesAssigned, unit)
    roleRead = roleRead and type(role) == "string"
    local mainTank, mainTankRead = Answer(GetPartyAssignment, "MAINTANK", unit)
    if (roleRead and role == "TANK") or (mainTankRead and mainTank and mainTank ~= 0) then return true end
    -- Both read, and neither says tank: raid or not, nobody can hide a tank.
    -- (Asked first, as the raid answer looks through raid1..40.)
    if roleRead and mainTankRead then return false end
    if ns.GroupBuffs.RaidAnswer() == false then
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

-- 1.3.3's rule (while pending): whether buff may go to member ({ unit,
-- name, class }): true; false and why when your rules leave them out; nil
-- and why when it can't be told.
local function LegacyAllows(buff, member)
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

-- The fields holding each place's rules (#408), and 1.3.3's (nil place).
BuffRules.PLACES = { "strangers", "party", "raid", "pvp" }
BuffRules.PLACE_FIELD = { strangers = "whoStrangers", party = "whoParty", raid = "whoRaid", pvp = "whoPvP" }
-- The places with Always and Never lists: not strangers.
BuffRules.NAMED_PLACES = { party = true, raid = true, pvp = true }
-- Every map whose names count towards MAX_TOTAL_NAMES, in the order a
-- repair keeps them (the rules in force while pending first).
BuffRules.NAME_FIELDS = { "whoGets", "whoParty", "whoRaid", "whoPvP" }

-- The saved map for place (nil: 1.3.3's whoGets), or nil.
local function MapOf(place)
    local b = ns.db and ns.db.buffBack
    if type(b) ~= "table" then return nil end
    local all = b[place and BuffRules.PLACE_FIELD[place] or "whoGets"]
    return type(all) == "table" and all or nil
end

-- Names in every Always and Never list, but one (field, key, list).
local function OtherNames(skipField, skipKey, skipList)
    local b = ns.db and ns.db.buffBack
    local n = 0
    for _, field in ipairs(BuffRules.NAME_FIELDS) do
        local all = type(b) == "table" and b[field]
        for key, entry in pairs(type(all) == "table" and all or {}) do
            for list in pairs(BuffRules.NAME_LISTS) do
                if type(entry) == "table" and type(entry[list]) == "table"
                    and not (field == skipField and key == skipKey and list == skipList) then
                    for _ in pairs(entry[list]) do n = n + 1 end
                end
            end
        end
    end
    return n
end

-- Set an Always or Never list from text: names separated by commas ("Ann
-- Vale, Cid Rock"), for place (nil: 1.3.3's rules, while pending). Returns
-- true, or false and why (nothing changes).
function BuffRules.SetNames(key, list, text, place)
    if not ns.BuffData.KEYS[key] or not BuffRules.NAME_LISTS[list] then return false, "unknown list" end
    if place ~= nil and not BuffRules.NAMED_PLACES[place] then return false, "unknown list" end
    local names, n = ParseNames(text)
    if not names then return false, n end
    -- With every other list as it is, the total stays within its cap.
    local field = place and BuffRules.PLACE_FIELD[place] or "whoGets"
    if OtherNames(field, key, list) + n > BuffRules.MAX_TOTAL_NAMES then
        return false, "at most " .. BuffRules.MAX_TOTAL_NAMES .. " names across all your buffs"
    end
    if place then
        BuffRules.OwnPlaceEntry(key, place)[list] = names
    else
        OwnEntry(key)[list] = names
    end
    ns.BuffButton.Refresh()
    return true
end

-- Add one player (a full name) to an Always or Never list, within its caps.
-- Returns true, or false and why.
function BuffRules.AddName(key, list, fullName, place)
    local text = BuffRules.NamesText(key, list, place)
    if type(fullName) ~= "string" then return false, "no name" end
    local display = Util.DisplayName(fullName)
    return BuffRules.SetNames(key, list, text == "" and display or (text .. ", " .. display), place)
end

-- An Always or Never list as text for its box, names sorted (ignoring case).
function BuffRules.NamesText(key, list, place)
    local all = MapOf(place)
    local entry = all and all[key]
    return ListText(type(entry) == "table" and entry[list] or nil)
end

-- entry's Always and Never lists, cleaned into out: names that are player
-- names, each list capped, and the names kept so far (total) within
-- MAX_TOTAL_NAMES. Returns the new total.
local function CleanLists(entry, out, total)
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
    return total
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
            total = CleanLists(entry, out, total)
            clean[key] = out
        end
    end
    return clean
end

------------------------------------------------------------------------
-- Who gets each buff, by place (#408)
------------------------------------------------------------------------

-- The choice (buffBack.whoChoice): "pending" until the player chooses (the
-- 1.3.3 rules above apply), "kept" or "new".
BuffRules.CHOICES = { pending = true, kept = true, new = true }
-- The role ticks, and the tick each role answers to.
BuffRules.ROLE_TICKS = { "tanks", "healers", "damage" }
BuffRules.ROLE_TICK = { tank = "tanks", healer = "healers", damage = "damage" }
BuffRules.IS_ROLE_TICK = { tanks = true, healers = true, damage = true }

local MANA_CLASSES = { PALADIN = true, HUNTER = true, PRIEST = true, SHAMAN = true, MAGE = true, WARLOCK = true,
    DRUID = true }
local MIGHT_CLASSES = { WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true, SHAMAN = true, DRUID = true }

-- Each place's defaults (the owner's, #408): a buff not named here gets
-- Everyone, or Off in PvP (BuffRules.DEFAULT_OFF). Read only: never saved
-- or changed (OwnPlaceEntry saves a copy).
BuffRules.DEFAULTS = {
    strangers = { wisdom = { classes = MANA_CLASSES }, might = { classes = MIGHT_CLASSES } },
    party = { thorns = { tanks = true }, wisdom = { classes = MANA_CLASSES }, might = { classes = MIGHT_CLASSES } },
    raid = { thorns = { tanks = true }, wisdom = { classes = MANA_CLASSES }, might = { classes = MIGHT_CLASSES } },
    pvp = {},
}
BuffRules.DEFAULT_OFF = { pvp = true }
local EVERYONE, OFF = { everyone = true }, {}

-- Whether any place holds a rule that a check would keep (junk alone,
-- an unknown buff's say, isn't a rule: it mustn't empty 1.3.3's).
local function AnyEntry(cfg)
    for _, place in ipairs(BuffRules.PLACES) do
        local map = cfg[BuffRules.PLACE_FIELD[place]]
        if type(map) == "table" and next(BuffRules.CleanPlace(map, place == "strangers")) ~= nil then return true end
    end
    return false
end

-- The choice value says, in section (buffBack, as saved): the saved one,
-- or for one damaged, "kept" when any place holds a rule (a choice was made
-- and used), else "pending" (Keep then copies 1.3.3's rules again: nothing
-- is lost). Config's validator for whoChoice.
function BuffRules.ChoiceFor(value, section)
    if BuffRules.CHOICES[value] then return value end
    if type(section) ~= "table" then return "pending" end
    return AnyEntry(section) and "kept" or "pending"
end

local function ChoiceOf(cfg)
    return BuffRules.ChoiceFor(type(cfg) == "table" and cfg.whoChoice or nil, cfg)
end

-- The choice in force: "pending", "kept" or "new".
function BuffRules.Choice()
    return ChoiceOf(ns.db and ns.db.buffBack)
end

function BuffRules.Pending()
    return BuffRules.Choice() == "pending"
end

-- buff's rule in place: the saved one, or the place's default. Read only.
local function PlaceEntry(buff, place)
    local all = MapOf(place)
    local entry = all and all[buff.key]
    if type(entry) == "table" then return entry end
    local default = BuffRules.DEFAULTS[place] and BuffRules.DEFAULTS[place][buff.key]
    if default then return default end
    return BuffRules.DEFAULT_OFF[place] and OFF or EVERYONE
end
BuffRules.PlaceEntry = PlaceEntry

-- Whether rule has a class ticked, and whether class is one of them.
local function ClassTicked(rule, class)
    local classes = rule.classes
    if type(classes) ~= "table" then return false, false end
    local any = false
    for c, on in pairs(classes) do
        if on == true and BuffRules.IS_CLASS[c] then
            any = true
            if c == class then return true, true end
        end
    end
    return any, false
end

local function RoleTicked(rule)
    for _, tick in ipairs(BuffRules.ROLE_TICKS) do
        if rule[tick] == true then return true end
    end
    return false
end

-- A member's role (#408): "tank" (the group role TANK, or the raid's Main
-- Tank: BuffRules.IsTank, so a Main Tank is a tank whatever role they
-- chose), "healer" (HEALER), "damage" (DAMAGER), "none" (no role chosen),
-- or nil when it can't be told: the role can't be read (missing, an error,
-- a secret, not a string), or whether they're a tank can't.
function BuffRules.Role(unit)
    local tank = BuffRules.IsTank(unit)
    if tank == true then return "tank" end
    if tank ~= false then return nil end
    local role, read = Answer(UnitGroupRolesAssigned, unit)
    if not read or type(role) ~= "string" then return nil end
    if role == "HEALER" then return "healer" end
    if role == "DAMAGER" then return "damage" end
    return "none"
end

-- Which place's rules apply now (#408), as a list: one place, or every
-- place it could be when the game won't say. A battleground ("pvp") or an
-- arena is PvP; otherwise a raid group is Raid, and a party (or no group:
-- your own buffs, solo) Party. inRaid: the group look's own raid answer
-- (true, false, or nil when it couldn't be read or believed), so one look
-- reads the group once (#346); left out, it's read here.
function BuffRules.Place(...)
    local inRaid
    if select("#", ...) > 0 then inRaid = ... else inRaid = ns.GroupBuffs.RaidAnswer() end
    local _, kind = Read(IsInInstance)
    if kind == "pvp" or kind == "arena" then return { "pvp" } end
    local out = {}
    if type(kind) ~= "string" then out[#out + 1] = "pvp" end
    if inRaid ~= true then out[#out + 1] = "party" end
    if inRaid ~= false then out[#out + 1] = "raid" end
    return out
end

-- Whether buff may go to member ({ unit, name, class }) by place's rule:
-- true; false and why; nil and why when it can't be told.
local function AllowsIn(buff, member, place)
    local rule = PlaceEntry(buff, place)
    local entry = type(rule) == "table" and rule or OFF
    if Named(entry, "never", member.name) then return false, "you set Never for them" end
    -- The raid buff split (#70) leaves some groups to other copies.
    local covered, splitWhy = ns.RaidSplit.CoversMember(buff, member)
    if not covered then return false, splitWhy end
    if Named(entry, "always", member.name) then return true end
    if entry.everyone == true then return true end
    local unsure
    local anyClass, hasClass = ClassTicked(entry, member.class)
    if hasClass then return true end
    if anyClass and not member.class then unsure = "can't see their class" end
    local anyRole = RoleTicked(entry)
    if anyRole then
        local role = BuffRules.Role(member.unit)
        if role == nil then
            unsure = unsure or "can't tell their role"
        elseif entry[BuffRules.ROLE_TICK[role] or ""] == true then
            return true
        end
    end
    if unsure then return nil, unsure end
    if anyClass or anyRole then return false, "not a role or class you chose" end
    return false, "off for them here"
end

-- Whether buff may go to member ({ unit, name, class }): true; false and
-- why when your rules leave them out; nil and why when it can't be told.
-- places: BuffRules.Place's list (read now when left out). While pending,
-- 1.3.3's rule, wherever you are. Otherwise every place in the list must
-- give it: one that leaves them out says no, one that can't tell, unsure.
function BuffRules.Allows(buff, member, places)
    if BuffRules.Pending() then return LegacyAllows(buff, member) end
    places = places or BuffRules.Place()
    local result, why = true, nil
    for _, place in ipairs(places) do
        local ok, placeWhy = AllowsIn(buff, member, place)
        if ok == false then return false, placeWhy end
        if ok == nil and result then result, why = nil, placeWhy end
    end
    return result, why
end

-- Whether buff may go back to a stranger of class (nil: can't be read) who
-- buffed you, by the Buff Back rule: true; false; nil when their class
-- can't be read and the rule is by class. While pending: always (1.3.3
-- gave strangers the class check alone, BuffData.Useful).
function BuffRules.AllowsStranger(buff, class)
    if BuffRules.Pending() then return true end
    local entry = PlaceEntry(buff, "strangers")
    if entry.everyone == true then return true end
    local anyClass, hasClass = ClassTicked(entry, class)
    if hasClass then return true end
    if anyClass and not class then return nil end
    return false
end

-- Whether a class-wide cast (Greater Blessings) may be offered for buff:
-- not when a place's rule picks by role without Everyone (a class-wide cast
-- can't pick roles; #41's "never with Tanks only", widened by #408).
function BuffRules.ClassWideOk(buff, places)
    if BuffRules.Pending() then return BuffRules.Rule(buff) ~= "tanks" end
    for _, place in ipairs(places or BuffRules.Place()) do
        local entry = PlaceEntry(buff, place)
        if entry.everyone ~= true and RoleTicked(entry) then return false end
    end
    return true
end

-- Whether place's rules give any of your buffs to anyone: a tick, or an
-- Always name. While pending, yes (1.3.3's rules have no Off).
function BuffRules.GivesAnyone(place)
    if BuffRules.Pending() then return true end
    for _, buff in ipairs(ns.BuffData.Offerable()) do
        local entry = PlaceEntry(buff, place)
        if entry.everyone == true or RoleTicked(entry) or (ClassTicked(entry)) then return true end
        if type(entry.always) == "table" and next(entry.always) ~= nil then return true end
    end
    return false
end

-- The saved rule for key in place, made from the place's default when
-- missing (for the setters), so a change keeps what was shown.
function BuffRules.OwnPlaceEntry(key, place)
    local b = ns.Config.Section("buffBack")
    local field = BuffRules.PLACE_FIELD[place]
    if type(b[field]) ~= "table" then b[field] = {} end
    local entry = b[field][key]
    if type(entry) ~= "table" then
        entry = Util.DeepCopy(PlaceEntry({ key = key }, place))
        b[field][key] = entry
    end
    return entry
end

-- Setters for the Buffs tab (#408). Each returns true, or false and why;
-- none works before the choice (the tab shows 1.3.3's rules greyed then).
local function CanSet(key, place)
    if not ns.BuffData.KEYS[key] or not BuffRules.PLACE_FIELD[place] then return false, "unknown buff or place" end
    if BuffRules.Pending() then return false, "choose how to start first" end
    return true
end

-- Tick or untick Everyone or a role. Everyone clears the other ticks; any
-- other tick clears Everyone. Strangers have no roles.
function BuffRules.SetTick(key, place, tick, on)
    local ok, why = CanSet(key, place)
    if not ok then return false, why end
    local isRole = BuffRules.IS_ROLE_TICK[tick] == true
    if tick ~= "everyone" and not isRole then return false, "unknown choice" end
    if isRole and place == "strangers" then return false, "a stranger's role can't be seen" end
    local entry = BuffRules.OwnPlaceEntry(key, place)
    if on and tick == "everyone" then
        for _, t in ipairs(BuffRules.ROLE_TICKS) do entry[t] = nil end
        entry.classes = nil
    elseif on then
        entry.everyone = nil
    end
    entry[tick] = on and true or nil
    ns.BuffButton.Refresh()
    return true
end

-- Tick or untick a class; it clears Everyone.
function BuffRules.SetPlaceClass(key, place, class, on)
    local ok, why = CanSet(key, place)
    if not ok then return false, why end
    if not BuffRules.IS_CLASS[class] then return false, "unknown class" end
    local entry = BuffRules.OwnPlaceEntry(key, place)
    if type(entry.classes) ~= "table" then entry.classes = {} end
    entry.classes[class] = on and true or nil
    if on then entry.everyone = nil end
    ns.BuffButton.Refresh()
    return true
end

-- Off: every tick cleared; the names stay (the owner, #408).
function BuffRules.SetOff(key, place)
    local ok, why = CanSet(key, place)
    if not ok then return false, why end
    local entry = BuffRules.OwnPlaceEntry(key, place)
    entry.everyone, entry.classes = nil, nil
    for _, t in ipairs(BuffRules.ROLE_TICKS) do entry[t] = nil end
    ns.BuffButton.Refresh()
    return true
end

-- 1.3.3's rules as ticks: Everyone but tanks is Healers and Damage (the
-- owner, #408), so a member with no role chosen no longer gets it.
local LEGACY_TICKS = { all = { "everyone" }, tanks = { "tanks" }, notTanks = { "healers", "damage" } }

local function SortedKeys(map)
    local keys = {}
    for key in pairs(map) do
        if type(key) == "string" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    return keys
end

-- Make the choice (#408): "kept" copies each buff's 1.3.3 rule in force,
-- names and classes included, to Party and Raid (names to Party first, then
-- Raid, within MAX_TOTAL_NAMES), and leaves Buff Back and PvP on their
-- defaults; "new" takes every place's defaults. Either empties 1.3.3's
-- rules, says in chat what changed, and works once: returns true, or false
-- and why.
function BuffRules.Choose(choice)
    if choice ~= "kept" and choice ~= "new" then return false, "unknown choice" end
    if not BuffRules.Pending() then return false, "you've already chosen" end
    local b = ns.Config.Section("buffBack")
    local old = type(b.whoGets) == "table" and b.whoGets or {}
    local party, raid, narrowed, dropped, droppedFrom = {}, {}, {}, 0, {}
    if choice == "kept" then
        local keys = {}
        for _, key in ipairs(SortedKeys(old)) do
            if ns.BuffData.KEYS[key] and type(old[key]) == "table" then keys[#keys + 1] = key end
        end
        for _, key in ipairs(keys) do
            local buff = ns.BuffData.ByKey(key) or { key = key }
            local rule = BuffRules.Rule(buff)
            local ticks = {}
            if rule == "classes" then
                ticks.classes = {}
                for class, on in pairs(ChosenClasses(buff, old[key])) do
                    if on == true and BuffRules.IS_CLASS[class] then ticks.classes[class] = true end
                end
            else
                for _, tick in ipairs(LEGACY_TICKS[rule]) do ticks[tick] = true end
            end
            -- A key kept known without a buff (BuffTable.absent, #209) has no spell to name.
            local real = ns.BuffData.ByKey(key)
            if rule == "notTanks" then narrowed[#narrowed + 1] = real and ns.BuffData.SpellName(real) or key end
            party[key], raid[key] = ticks, Util.DeepCopy(ticks)
        end
        local total = 0
        for _, map in ipairs({ party, raid }) do
            for _, key in ipairs(keys) do
                for _, list in ipairs({ "always", "never" }) do
                    local names = old[key][list]
                    if type(names) == "table" then
                        local out = {}
                        for _, nameKey in ipairs(SortedKeys(names)) do
                            local full = ns.Config.IgnoreEntry(nameKey, names[nameKey])
                            if full and total < BuffRules.MAX_TOTAL_NAMES then
                                out[ns.Config.IgnoreKey(full)] = full
                                total = total + 1
                            elseif full then
                                dropped = dropped + 1
                                droppedFrom[key] = true
                            end
                        end
                        map[key][list] = out
                    end
                end
            end
        end
    end
    b.whoParty, b.whoRaid, b.whoPvP, b.whoStrangers, b.whoGets = party, raid, {}, {}, {}
    b.whoChoice = choice
    if choice == "kept" then
        ns.Print("kept your buff rules: they now apply in parties and raids. In battlegrounds and arenas "
            .. "every buff starts off. Change them on the Buffs tab.")
        if #narrowed > 0 then
            ns.Print("\"Everyone but tanks\" is now Healers and Damage for " .. table.concat(narrowed, ", ")
                .. ": a member with no role chosen no longer gets it.")
        end
        if dropped > 0 then
            local names = {}
            for _, key in ipairs(SortedKeys(droppedFrom)) do
                local buff = ns.BuffData.ByKey(key)
                names[#names + 1] = buff and ns.BuffData.SpellName(buff) or key
            end
            ns.Print(("%d names weren't copied (at most %d in all): %s."):format(dropped,
                BuffRules.MAX_TOTAL_NAMES, table.concat(names, ", ")))
        end
    else
        ns.Print("using the new buff defaults. In battlegrounds and arenas every buff starts off. "
            .. "Change them on the Buffs tab.")
    end
    ns.BuffButton.Refresh()
    return true
end

-- A clean copy of one place's saved rules (Config's validator): known buff
-- keys only, ticks that are true, known classes, and (not for strangers)
-- names that are player names, capped. A tick that's damaged is dropped, so
-- a damaged rule reads as Off, never as Everyone; a rule that isn't a table
-- is dropped, so the default applies.
function BuffRules.CleanPlace(value, strangers)
    local clean = {}
    if type(value) ~= "table" then return clean end
    local total = 0
    for key, entry in pairs(value) do
        if type(key) == "string" and ns.BuffData.KEYS[key] and type(entry) == "table" then
            local out = {}
            if entry.everyone == true then out.everyone = true end
            if type(entry.classes) == "table" then
                out.classes = {}
                for class, on in pairs(entry.classes) do
                    if BuffRules.IS_CLASS[class] and on == true then out.classes[class] = true end
                end
            end
            if not strangers then
                for _, tick in ipairs(BuffRules.ROLE_TICKS) do
                    if entry[tick] == true then out[tick] = true end
                end
                total = CleanLists(entry, out, total)
            end
            clean[key] = out
        end
    end
    return clean
end

-- After each field of buffBack is checked (Config.lua): the choice repaired
-- (ChoiceOf), 1.3.3's rules emptied once a choice is made, and the names in
-- every place held to MAX_TOTAL_NAMES together, the rules in force while
-- pending first.
function BuffRules.Repair(cfg)
    if type(cfg) ~= "table" then return end
    cfg.whoChoice = ChoiceOf(cfg)
    if cfg.whoChoice ~= "pending" then cfg.whoGets = {} end
    local total = 0
    for _, field in ipairs(BuffRules.NAME_FIELDS) do
        local map = type(cfg[field]) == "table" and cfg[field] or {}
        for _, key in ipairs(SortedKeys(map)) do
            local entry = map[key]
            for _, list in ipairs({ "always", "never" }) do
                local names = type(entry) == "table" and entry[list]
                if type(names) == "table" then
                    for _, nameKey in ipairs(SortedKeys(names)) do
                        if total < BuffRules.MAX_TOTAL_NAMES then
                            total = total + 1
                        else
                            names[nameKey] = nil
                        end
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- My Blessings in this raid (paladins)
------------------------------------------------------------------------

-- Which of your Blessings you cover in the raid you're in, so two paladins
-- don't both give Kings: nil when you haven't chosen (all of them), or
-- [buff key] = true. Kept for this raid only, never saved: it's forgotten
-- as soon as the game says you're not in a raid, and the group's slots agree
-- (#368: GroupBuffs.RaidAnswer), and when the raid's leader, or most of its
-- members, change (#376: the owner). An answer that can't be read or
-- believed keeps it: one wrong look mustn't hand Kings back to both paladins.
local raidBlessings
-- The raid the last choice was made in (#376), read only while there is a
-- choice: { leader = full name or nil while it can't be read, members =
-- { [full name] = true } for the other members read then, unread = how
-- many slots couldn't be read then }. A slot that couldn't be read still
-- counts among the members at the choice, but never as gone. Nothing is
-- filled in by later looks: by then it may be another raid's (#376), so a
-- leader that couldn't be read leaves the members to decide.
local raidOf

local RAID_UNITS = {}
for i = 1, 40 do RAID_UNITS[i] = "raid" .. i end

local function InRaid()
    return Read(IsInRaid) == true
end

-- In a battleground or an arena, whose group isn't your raid (#376, #394:
-- the owner): true or false, or nil when IsInInstance() can't be read. The
-- same answer as the PvP place (BuffRules.Place, #408).
local function InBattleground()
    local _, kind = Read(IsInInstance)
    if type(kind) ~= "string" then return nil end
    return kind == "pvp" or kind == "arena"
end

-- The raid as the game shows it now: its leader's full name (nil when it
-- can't be read), the other members by full name, and how many slots
-- couldn't be read: whether they hold someone, or who.
local function RaidNow()
    local me = Util.UnitFullName("player")
    local leader = Read(UnitIsGroupLeader, "player") == true and me or nil
    local members, unread = {}, 0
    for _, unit in ipairs(RAID_UNITS) do
        local exists = Read(UnitExists, unit)
        if exists == nil then
            unread = unread + 1
        elseif exists then
            -- UnitIsUnit() unreadable: told by name. Your own slot is the
            -- same unit as "player", so its name loads with yours.
            local name = Util.UnitFullName(unit)
            local you = Read(UnitIsUnit, unit, "player") == true or (name ~= nil and name == me)
            if not you and name == nil then
                unread = unread + 1
            elseif not you then
                members[name] = true
                if Read(UnitIsGroupLeader, unit) == true then leader = name end
            end
        end
    end
    return leader, members, unread
end

-- Whether the raid now is another one than the choice's (#376), on positive
-- evidence only: a leader read now and when chosen, and different; or most
-- of the members at the choice gone, by a look that read every slot. A
-- member in a slot that couldn't be read, then or now, may still be there:
-- it counts among the members at the choice, never as gone. A raid filling
-- up isn't one changing: newcomers count for nothing.
local function RaidChanged(leader, members, unread)
    if raidOf.leader and leader and leader ~= raidOf.leader then return true end
    if unread > 0 then return false end
    local before, gone = raidOf.unread, 0
    for name in pairs(raidOf.members) do
        before = before + 1
        if not members[name] then gone = gone + 1 end
    end
    return gone * 2 > before
end

-- The choice while it's in force, or nil. Called before each use. In a
-- battleground it's kept but not used, and nothing there forgets it: it
-- applies again back in your raid (#376: the owner). Otherwise it's
-- forgotten once you're out of the raid (#368).
local function InForce()
    if not raidBlessings or InBattleground() == true then return nil end
    if ns.GroupBuffs.RaidAnswer() == false then raidBlessings = nil end
    return raidBlessings
end

-- On each roster update (Core.lua): forget the choice once you're out of the
-- raid, or in another one (#376). Only while the game says, believably,
-- that you're in a raid and not in a battleground: an answer that can't be
-- read keeps the choice.
function BuffRules.CheckRaid()
    if not InForce() or ns.GroupBuffs.RaidAnswer() ~= true or InBattleground() ~= false then return end
    local leader, members, unread = RaidNow()
    if RaidChanged(leader, members, unread) then raidBlessings = nil end
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
    local chosen = InForce()
    if chosen and buff.family == "blessing" then return chosen[buff.key] == true end
    return ns.RaidSplit.Covers(buff)
end

-- The Blessings you chose for this raid, as a copy ([key] = true), or nil
-- when you haven't (the split then decides). Announced to the other copies
-- of your class in the raid (RaidSplit.lua).
function BuffRules.HandSetBlessings()
    local chosen = InForce()
    if not chosen then return nil end
    local out = {}
    for key in pairs(chosen) do out[key] = true end
    return out
end

-- Choose the Blessings you cover in this raid: keys is a list of your
-- Blessings' keys, or nil to stop choosing (all of them, or your share of the
-- raid buff split when there is one, #70). Returns true, or false and why.
-- Stopping always works, wherever the game says you are: a choice is kept
-- while the raid answer can't be read (#368), and must never be stuck.
function BuffRules.SetRaidBlessings(keys)
    if keys == nil then
        raidBlessings = nil
        ns.BuffButton.Refresh()
        return true
    end
    if not InRaid() then return false, "you're not in a raid" end
    -- A choice can't be used here (#376); one made in your raid waits.
    if InBattleground() == true then
        return false, raidBlessings
            and "you're in a battleground or arena (your raid's choice applies again when you're back)"
            or "you're in a battleground or arena"
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
    -- Every Blessing you know narrows nothing, unless the raid buff split
    -- (#70) would narrow it: then it's your choice over the split's.
    raidBlessings = (count < all or ns.RaidSplit.Current() ~= nil) and chosen or nil
    -- The raid it's for (#376), as it is now: a change counts from here.
    local leader, members, unread = RaidNow()
    raidOf = { leader = leader, members = members, unread = unread }
    ns.BuffButton.Refresh()
    return true
end

-- Whether you've narrowed your Blessings for this raid.
function BuffRules.RaidBlessingsChosen()
    return InForce() ~= nil
end

-- Whether a choice is held for your raid while you're in a battleground,
-- where it isn't used (#376).
function BuffRules.RaidBlessingsHeld()
    return raidBlessings ~= nil and InBattleground() == true
end
