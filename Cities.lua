-- Quiet mode in capital cities. Capitals are crowded and buffs come in
-- waves, so there buff thanks aren't sent (the ledger still records every
-- favour) and the buff-back button stays hidden unless you ask for it
-- (favours are still collected, and show once you leave). Buff mode
-- overrides both: on in a capital, thanks and the button work as usual.
-- Greetings aren't affected.
--
-- A capital is told by the map the game says you're on
-- (C_Map.GetBestMapForUnit), from a fixed list, not by IsResting(): inns and
-- small towns are rested too, and aren't crowded. A map that can't be read
-- (a loading screen, a secret, no such API) counts as not a capital.
local _, ns = ...
local Util = ns.Util

local Cities = {}
ns.Cities = Cities

-- [uiMapID] = the city's name. These are Classic Era's numbers; Forever's
-- are checked on launch day (#50). Valanaar (the Skyborne hub, which High
-- Order and Windshaper share) and Dalaran (Alliance) count too (decided on
-- #34), and go here once their numbers are known.
Cities.CAPITALS = {
    [1453] = "Stormwind City",
    [1454] = "Orgrimmar",
    [1455] = "Ironforge",
    [1456] = "Thunder Bluff",
    [1457] = "Darnassus",
    [1458] = "Undercity",
}

-- The map the game says you're on now, or nil when it can't be read.
function Cities.MapId()
    local id = Util.ReadGameValues(C_Map and C_Map.GetBestMapForUnit, "player")
    if type(id) ~= "number" or id ~= id then return nil end -- id ~= id: not a number (NaN)
    return id
end

-- The capital you're in (its name), or nil.
function Cities.Capital()
    local id = Cities.MapId()
    return id and Cities.CAPITALS[id] or nil
end

-- A switch read defensively: settings damaged mid-session read as the
-- default until Config.Repair or the next load puts it back.
local function Switch(section, field)
    local cfg = ns.db and ns.db[section]
    local value = type(cfg) == "table" and cfg[field]
    if type(value) == "boolean" then return value end
    return ns.Config.DEFAULTS[section][field]
end

-- Whether buff thanks stay quiet right now.
function Cities.ThanksQuiet()
    return Switch("buff", "quietInCities") and not ns.BuffMode.IsOn() and Cities.Capital() ~= nil
end

-- Whether the buff-back button stays hidden right now.
function Cities.ButtonHidden()
    return not Switch("buffBack", "showInCities") and not ns.BuffMode.IsOn() and Cities.Capital() ~= nil
end

-- For /friendly status: where the addon thinks you are.
function Cities.StatusLine()
    local id = Cities.MapId()
    if not id then return "capital city: can't read the map, so not quiet" end
    local capital = Cities.CAPITALS[id]
    if not capital then return "capital city: no (map " .. id .. ")" end
    return string.format("capital city: %s (map %d); thanks %s, buff-back button %s", capital, id,
        Cities.ThanksQuiet() and "quiet" or "not quiet", Cities.ButtonHidden() and "hidden" or "not hidden")
end
