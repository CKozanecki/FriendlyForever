-- Flavour placeholders: words in a message line that change with the moment.
-- A line such as "{greeting}, {name}! {blessing}" becomes "Throm-ka, Nikki!
-- Strength and honor." for an orc, "Ishnu-alah, Nikki! Elune light your
-- path." for a night elf, or "Well met, Nikki! Safe travels through Elwynn
-- Forest." on the road. The words come from FlavourText.lua.
--
--   {greeting} {thanks} {blessing} {cheer}  chosen by your race, faction,
--                                          where you are and the hour
--   {zone}       where you are ("Elwynn Forest"; "these lands" if unknown).
--                In a guild message, where the guildmate is, from the guild
--                roster, or nothing at all: a line or phrase that needs it
--                isn't used when it's unknown (#486)
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

local Read = Util.ReadGameValues

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

-- What the moment is, read once per message. guild: a guild message's own
-- (#486), { zone = the guildmate's zone or nil }: {zone} reads theirs, never
-- yours and never "these lands", and the place-based phrases are the guild's
-- neutral ones, since the roster says where they are, not whether it's a city.
function Flavour.Context(guild)
    local _, race, raceId = Read(UnitRace, "player")
    local className, class = Read(UnitClass, "player")
    local faction = Read(UnitFactionGroup, "player")
    local zone = Text1(Read(GetRealZoneText)) or Text1(Read(GetZoneText))
    local inInstance, instanceType = Read(IsInInstance)
    local place = "wilds"
    if inInstance == true and (instanceType == "party" or instanceType == "raid") then
        place = "instance"
    elseif Read(IsResting) == true then
        place = "city"
    end
    faction = Text1(faction)
    local guildOnly = type(guild) == "table"
    if guildOnly then zone, place = Text1(guild.zone), "guild" end
    return {
        race = Flavour.Voice(race, raceId, faction), class = Text1(class), className = Text1(className),
        faction = faction, zone = zone, place = place, guild = guildOnly,
        partOfDay = Flavour.PartOfDay((Read(GetGameTime))),
    }
end

-- Whether a line or fragment needs {zone}, in any case ({Zone}, {ZONE}).
function Flavour.NeedsZone(text)
    return type(text) == "string" and text:lower():find("{zone}", 1, true) ~= nil
end

-- A guild message whose guildmate's zone is unknown can't say one (#486).
local function ZoneMissing(ctx)
    return ctx.guild and ctx.zone == nil
end

-- pool without the fragments that need a zone the moment hasn't got.
local function Sayable(pool, ctx)
    if not ZoneMissing(ctx) then return pool end
    local out = {}
    for _, fragment in ipairs(pool) do
        if not Flavour.NeedsZone(fragment) then out[#out + 1] = fragment end
    end
    return out
end

-- The pools that have lines for this moment, with their weights.
local function Pools(slot, ctx)
    local text, out = Text[slot], {}
    local function Add(kind, pool)
        if type(pool) ~= "table" then return end
        pool = Sayable(pool, ctx)
        if #pool > 0 then out[#out + 1] = { weight = Flavour.WEIGHTS[kind], lines = pool } end
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
    if key == "zone" then
        if ctx.guild then return ctx.zone end
        return ctx.zone or Flavour.FALLBACK.zone
    end
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

-- Every phrase a slot can turn into for this moment, as said (the fragment's
-- own {zone} and the like filled in), each once, in pool order: race, faction,
-- place, hour, general. Chooses nothing, so it leaves the random state and the
-- memory of recent fragments alone (#441).
function Flavour.Pool(slot, ctx)
    local out, seen = {}, {}
    if not SLOT[slot] then return out end
    for _, pool in ipairs(Pools(slot, ctx)) do
        for _, fragment in ipairs(pool.lines) do
            local said = Flavour.RenderFragment(fragment, ctx)
            if said and not seen[said] then
                seen[said] = true
                out[#out + 1] = said
            end
        end
    end
    return out
end

-- A small generator of our own for previews (Park-Miller, whose products stay
-- exact in a double), so a preview never draws from math.random or from
-- Flavour.random, which the next real message does. Its seed is the line, so
-- a line shows the same examples every time it is hovered.
local function Generator(seed)
    local state = seed % 2147483646 + 1
    return function(n)
        state = (state * 16807) % 2147483647
        return state % n + 1
    end
end

local function Seed(text)
    local seed = #text
    for i = 1, #text do seed = (seed * 31 + text:byte(i)) % 2147483629 end
    return seed
end

-- What a message line can turn into, for the options hover (#441). template
-- is the line as typed, vars its sample values ({name}, {buff}), ctx the moment
-- (read now if not given). Returns a table:
--   empty     true for a line with nothing in it;
--   examples  up to count different renderings with the real renderer;
--   pools     { key = "greeting", phrases = { ... } } for each slot the line
--             uses, once, in order of first use;
--   now       { key = "zone", value = "Elwynn Forest" } for each of {zone},
--             {timeofday} and {myclass} the line uses; for a guild message's
--             {zone} (#486), theirs = true, and none when it's unknown.
-- It changes nothing: not vars, nor the settings, nor the memory of recent
-- fragments, nor the real random state.
function Flavour.Preview(template, vars, ctx, count)
    local out = { examples = {}, pools = {}, now = {} }
    if type(template) ~= "string" or not template:find("%S") then
        out.empty = true
        return out
    end
    ctx = ctx or Flavour.Context()
    local used, order = {}, {}
    for key in template:gmatch("{(%a+)}") do
        key = key:lower()
        if not used[key] then
            used[key] = true
            order[#order + 1] = key
        end
    end
    for _, key in ipairs(order) do
        if SLOT[key] then
            out.pools[#out.pools + 1] = { key = key, phrases = Flavour.Pool(key, ctx) }
        elseif key == "zone" or key == "timeofday" or key == "myclass" then
            -- A guild message's {zone} is the guildmate's (#486): theirs is true.
            local value = Plain(key, ctx)
            if value ~= nil then
                out.now[#out.now + 1] = { key = key, value = value, theirs = key == "zone" and ctx.guild or nil }
            end
        end
    end

    local savedRandom, savedRecent = Flavour.random, recent
    Flavour.random, recent = Generator(Seed(template)), {}
    local ok = pcall(function()
        local seen = {}
        for _ = 1, (count or 3) * 6 do
            if #out.examples >= (count or 3) then break end
            local own = {}
            for k, v in pairs(vars or {}) do own[k] = v end
            local said = Util.Render(template, Flavour.Vars(own, ctx))
            if said and not seen[said] then
                seen[said] = true
                out.examples[#out.examples + 1] = said
            end
        end
    end)
    Flavour.random, recent = savedRandom, savedRecent
    if not ok then out.examples = {} end
    return out
end

function Flavour.ResetMemory()
    recent = {}
end
