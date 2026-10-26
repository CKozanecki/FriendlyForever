-- Flavour placeholders: words in a message line that change with the moment.
-- A line such as "{greeting}, {name}! {blessing}" becomes "Throm-ka, Nikki!
-- Strength and honor." for an orc, "Ishnu-alah, Nikki! Elune light your
-- path." for a night elf, or "Well met, Nikki! Safe travels through Elwynn
-- Forest." on the road. The words come from FlavourText.lua.
--
--   {greeting} {thanks} {blessing} {cheer}  chosen by your race, faction,
--                                          where you are and the hour
--   {zone}       where you are ("Elwynn Forest"; "these lands" if unknown)
--   {timeofday}  "morning", "afternoon" or "evening", by the game's clock
--   {myclass}    your class ("mage"; "traveler" if unknown)
--   {class}      their class when the game says ("warrior"), else "friend"
--
-- A value is worked out only when a line uses it, and the same placeholder
-- twice in one line gives the same words. Lines are your own voice: your race
-- and class are always known, other players' often aren't.
local _, ns = ...
local Util = ns.Util
local Text = ns.FlavourText

local Flavour = {}
ns.Flavour = Flavour

-- Overridable so tests can make the choice deterministic.
Flavour.random = math.random

-- How often each pool is chosen, when it has lines for this moment.
Flavour.WEIGHTS = { race = 4, faction = 2, place = 2, time = 1, general = 2 }
-- A fragment isn't used again until this many others from its slot have been.
Flavour.MEMORY = 4

Flavour.FALLBACK = { zone = "these lands", class = "friend", myclass = "traveler" }

local SLOT = {}
for _, slot in ipairs(Text.SLOTS) do SLOT[slot] = true end

local recent = {} -- [slot] = list of fragments used lately, newest last

local Ask = Util.Ask

local function Text1(value)
    if type(value) == "string" and value ~= "" then return value end
end

-- "night" (21:00-4:59), "morning" (5:00-11:59), "afternoon", "evening".
function Flavour.PartOfDay(hour)
    if type(hour) ~= "number" then return nil end
    if hour >= 21 or hour < 5 then return "night" end
    if hour < 12 then return "morning" end
    if hour < 17 then return "afternoon" end
    return "evening"
end

-- WoW Forever's Skyborne: one race file name, two peoples (ChrRaces 95 and 96).
Flavour.SKYBORNE = { [95] = "HighOrder", [96] = "Windshaper" }
local SKYBORNE_BY_FACTION = { Alliance = "HighOrder", Horde = "Windshaper" }

-- Whose lines you speak with: the race file name, or for the Skyborne which
-- of the two peoples (by race ID, else by faction). nil if unknown.
function Flavour.Voice(race, raceId, faction)
    if type(race) ~= "string" or race == "" then return nil end
    local plain = race:lower():gsub("[^%a]", "")
    if plain:find("skyborne", 1, true) or plain:find("highorder", 1, true) or plain:find("windshaper", 1, true) then
        if plain:find("highorder", 1, true) then return "HighOrder" end
        if plain:find("windshaper", 1, true) then return "Windshaper" end
        return Flavour.SKYBORNE[raceId] or SKYBORNE_BY_FACTION[faction]
    end
    return race
end

-- What the moment is, read once per message.
function Flavour.Context()
    local _, race, raceId = Ask(UnitRace, "player")
    local className, class = Ask(UnitClass, "player")
    local faction = Ask(UnitFactionGroup, "player")
    local zone = Text1(Ask(GetRealZoneText)) or Text1(Ask(GetZoneText))
    local inInstance, instanceType = Ask(IsInInstance)
    local place = "wilds"
    if inInstance == true and (instanceType == "party" or instanceType == "raid") then
        place = "instance"
    elseif Ask(IsResting) == true then
        place = "city"
    end
    faction = Text1(faction)
    return {
        race = Flavour.Voice(race, raceId, faction), class = Text1(class), className = Text1(className),
        faction = faction, zone = zone, place = place,
        partOfDay = Flavour.PartOfDay((Ask(GetGameTime))),
    }
end

-- The pools that have lines for this moment, with their weights.
local function Pools(slot, ctx)
    local text, out = Text[slot], {}
    local function Add(kind, pool)
        if type(pool) == "table" and #pool > 0 then out[#out + 1] = { weight = Flavour.WEIGHTS[kind], lines = pool } end
    end
    Add("race", text.race and ctx.race and text.race[ctx.race])
    Add("faction", text.faction and ctx.faction and text.faction[ctx.faction])
    Add("place", text.place and text.place[ctx.place])
    Add("time", text.time and text.time[ctx.partOfDay])
    Add("general", text.general)
    return out
end

local function Remember(slot, fragment)
    local list = recent[slot] or {}
    recent[slot] = list
    list[#list + 1] = fragment
    while #list > Flavour.MEMORY do table.remove(list, 1) end
end

local function Recent(slot, fragment)
    for _, f in ipairs(recent[slot] or {}) do
        if f == fragment then return true end
    end
    return false
end

-- A fragment for slot: a pool chosen by weight, then a line from it that
-- wasn't used lately (if the pool has one).
function Flavour.Pick(slot, ctx)
    local pools = Pools(slot, ctx)
    local total = 0
    for _, p in ipairs(pools) do total = total + p.weight end
    if total == 0 then return nil end
    local roll = Flavour.random(total)
    local pool
    for _, p in ipairs(pools) do
        roll = roll - p.weight
        if roll <= 0 then pool = p.lines break end
    end
    pool = pool or pools[#pools].lines
    local fresh = {}
    for _, line in ipairs(pool) do
        if not Recent(slot, line) then fresh[#fresh + 1] = line end
    end
    if #fresh == 0 then fresh = pool end
    local fragment = fresh[Flavour.random(#fresh)]
    Remember(slot, fragment)
    return fragment
end

-- The value of one plain (non-slot) flavour placeholder.
local function Plain(key, ctx)
    if key == "zone" then return ctx.zone or Flavour.FALLBACK.zone end
    if key == "timeofday" then
        local part = ctx.partOfDay
        if part == "night" or part == nil then return "evening" end
        return part
    end
    if key == "myclass" then return ctx.className and ctx.className:lower() or Flavour.FALLBACK.myclass end
    if key == "class" then return Flavour.FALLBACK.class end
end

-- Fill a fragment's own placeholders ({zone} and the like, never a slot).
function Flavour.RenderFragment(fragment, ctx)
    return (fragment:gsub("{(%a+)}", function(key)
        if SLOT[key] then return nil end
        return Plain(key, ctx)
    end))
end

function Flavour.Resolve(key, ctx)
    if SLOT[key] then
        local fragment = Flavour.Pick(key, ctx)
        return fragment and Flavour.RenderFragment(fragment, ctx)
    end
    return Plain(key, ctx)
end

-- vars with flavour placeholders filled on demand: values already in vars
-- (name, buff, class when known...) win. ctx is read on first use.
function Flavour.Vars(vars, ctx)
    vars = vars or {}
    return setmetatable(vars, {
        __index = function(t, key)
            ctx = ctx or Flavour.Context()
            local value = Flavour.Resolve(key, ctx)
            if value ~= nil then rawset(t, key, value) end
            return value
        end,
    })
end

-- Every placeholder name Flavour understands (for help text and tests).
Flavour.KEYS = { "greeting", "thanks", "blessing", "cheer", "zone", "timeofday", "myclass", "class" }

function Flavour.ResetMemory()
    recent = {}
end
