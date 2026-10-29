-- Players the addon never greets, welcomes or thanks. Kept by full name
-- ("Nikki-Shifts"): a first name alone could be anybody. Matching ignores
-- case, so "nikki shifts" typed in chat still matches the game's "Nikki-Shifts".
local _, ns = ...
local Util = ns.Util

local Ignore = {}
ns.Ignore = Ignore

local Key = function(fullName) return ns.Config.IgnoreKey(fullName) end

-- The list. Its type is checked on every use, so a list damaged mid-session
-- (by another addon or a bad /run) is repaired before it can raise an error.
-- A damaged entry is skipped where it's read, and dropped at the next load.
function Ignore.Data()
    if type(ns.db.ignore) ~= "table" then
        ns.Diag.Log("ignore", "the ignore list was damaged; repaired")
        ns.db.ignore = ns.Config.ValidIgnore(ns.db.ignore)
    end
    return ns.db.ignore
end

function Ignore.Has(fullName)
    return ns.db ~= nil and fullName ~= nil and Ignore.Data()[Key(fullName)] ~= nil
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
    local list = Ignore.Data()
    if not list[Key(name)] then
        local n = 0
        for _ in pairs(list) do n = n + 1 end
        if n >= ns.Config.MAX_IGNORED then return nil, "the list is full (" .. n .. " names)" end
    end
    list[Key(name)] = name
    ns.Offers.Forget(name)
    return name
end

-- Returns the full name removed, or nil and why not.
function Ignore.Remove(input)
    local name, why = Resolve(input)
    if not name then return nil, why end
    local list, key = Ignore.Data(), Key(name)
    if list[key] == nil then return nil, Util.DisplayName(name) .. " isn't on the list" end
    -- The name as it was listed; as typed, if the entry was damaged.
    local listed = ns.Config.IgnoreEntry(key, list[key]) or name
    list[key] = nil
    return listed
end

-- Display names, sorted.
function Ignore.List()
    local out = {}
    for key, value in pairs(Ignore.Data()) do
        local name = ns.Config.IgnoreEntry(key, value)
        if name then out[#out + 1] = Util.DisplayName(name) end
    end
    table.sort(out)
    return out
end

-- A name with no surname matches nobody on WoW Forever, where every
-- character has one. Worth a warning when someone types just "Nikki".
function Ignore.LacksSurname(fullName)
    return not fullName:find("-", 1, true)
end
