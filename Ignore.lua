-- Players the addon never greets, welcomes or thanks. Kept by full name
-- ("Nikki-Shifts"): a first name alone could be anybody.
local _, ns = ...
local Util = ns.Util

local Ignore = {}
ns.Ignore = Ignore

function Ignore.Has(fullName)
    return ns.db ~= nil and fullName ~= nil and ns.db.ignore[fullName] == true
end

-- Accepts "Nikki Shifts", "Nikki-Shifts" or a unit token's player.
-- Returns the full name, or nil and why not.
local function Resolve(input)
    if type(input) ~= "string" or not input:find("%S") then
        local target = Util.UnitFullName("target")
        local isPlayer = Util.Readable(UnitIsPlayer("target"))
        if target and isPlayer then return target end
        return nil, "type a name, or target a player first"
    end
    local name = Util.FullName((input:gsub("^%s+", ""):gsub("%s+$", "")))
    if not name then return nil, "'" .. Util.StripChat(input) .. "' isn't a player name" end
    return name
end

-- Returns the full name added (or already there), or nil and why not.
function Ignore.Add(input)
    local name, why = Resolve(input)
    if not name then return nil, why end
    if not ns.db.ignore[name] then
        local n = 0
        for _ in pairs(ns.db.ignore) do n = n + 1 end
        if n >= ns.Config.MAX_IGNORED then return nil, "the list is full (" .. n .. " names)" end
    end
    ns.db.ignore[name] = true
    return name
end

-- Returns the full name removed, or nil and why not.
function Ignore.Remove(input)
    local name, why = Resolve(input)
    if not name then return nil, why end
    if not ns.db.ignore[name] then return nil, Util.DisplayName(name) .. " isn't on the list" end
    ns.db.ignore[name] = nil
    return name
end

-- Display names, sorted.
function Ignore.List()
    local out = {}
    for name in pairs(ns.db.ignore) do out[#out + 1] = Util.DisplayName(name) end
    table.sort(out)
    return out
end

-- A name with no surname matches nobody on WoW Forever, where every
-- character has one. Worth a warning when someone types just "Nikki".
function Ignore.LacksSurname(fullName)
    return not fullName:find("-", 1, true)
end
