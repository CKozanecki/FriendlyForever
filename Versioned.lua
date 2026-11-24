-- Versioned sections (#496): a short list of tokens that someone with
-- authority sets for every copy around them, shared over the hidden
-- channel (Comm.lua). The guild leader controls (GuildLead.lua) keep the
-- guild's leader ranks, caps and vetoes this way; the raid leader's buff
-- assignments (#497) can too.
--
-- A section is a version and a list of items. Each item is a short token
-- its section's check accepts: never free text, so nothing in a section can
-- become a line anyone says, and never code. The section's owner decides
-- what the items mean; they can only ever make the addon quieter or
-- narrower.
--
-- Everything that arrives is untrusted. Comm has checked the message is
-- ours, small enough, within the flood limits, on the right route, from the
-- player it names, and that its fields have the right shape. Then:
-- - the sender must have authority over the section now (spec.authority,
--   asked of the game's own roster, never of the message) as each part
--   arrives, the last one included;
-- - the version must be newer than the one kept: a higher number, or the
--   same number with a greater list (so two leaders' edits in the same
--   second settle the same way everywhere). An old or repeated version
--   changes nothing;
-- - the whole list must pass: at most spec.maxItems items, no item twice,
--   and spec.whole's check of the list together.
--
-- Wire format, after Comm's version;TYPE;subject: version;part;parts;items,
-- items being "-" for none or the tokens joined by commas. A list too long
-- for one message goes in up to MAX_PARTS parts, put back together per
-- sender: at most MAX_ASSEMBLIES at once per section, each for at most
-- ASSEMBLY_TTL seconds.
local _, ns = ...
local Comm = ns.Comm

local Versioned = {}
ns.Versioned = Versioned

Versioned.MAX_VERSION = 999999999999 -- 12 digits: a version past it is refused
Versioned.MAX_PARTS = 6
Versioned.MAX_ASSEMBLIES = 4
Versioned.ASSEMBLY_TTL = 30
Versioned.MAX_ITEM_BYTES = 24
-- The longest header a part can have: Comm's version and a type, our full
-- name at its longest (two parts of 48 bytes, Util.FullName), and the three
-- numbers, each with its delimiter.
Versioned.MAX_HEADER = 4 + 12 + 1 + 97 + 1 + 12 + 1 + 1 + 1 + 1 + 1

-- A version as text: a whole number from 1 to MAX_VERSION, no leading zero.
function Versioned.VersionField(text)
    return #text <= 12 and text:find("^[1-9]%d*$") ~= nil
end

-- "0" (none kept) or a version.
function Versioned.StampField(text)
    return text == "0" or Versioned.VersionField(text)
end

local function PartField(text)
    return text:find("^[1-9]$") ~= nil and tonumber(text) <= Versioned.MAX_PARTS
end

-- Split "a,b,c" into its items; "-" is none. MAX_BYTES bounds the work.
local function SplitItems(text)
    local items = {}
    if text == "-" then return items end
    for item in (text .. ","):gmatch("([^,]*),") do items[#items + 1] = item end
    return items
end

-- The text a list is sent and compared as.
function Versioned.Encode(items)
    if #items == 0 then return "-" end
    return table.concat(items, ",")
end

-- Whether version a with list a is newer than version b with list b.
function Versioned.Newer(versionA, encodedA, versionB, encodedB)
    if versionA ~= versionB then return versionA > versionB end
    return encodedA > encodedB
end

-- Whether items is a list spec accepts: at most maxItems items, each passing
-- spec.item, none twice, and spec.whole's check of them together.
function Versioned.ValidList(spec, items)
    if type(items) ~= "table" or #items > spec.maxItems then return false end
    local seen = {}
    for i = 1, #items do
        local item = items[i]
        if type(item) ~= "string" or #item > spec.itemBytes or not spec.item(item) or seen[item] then
            return false
        end
        seen[item] = true
    end
    for key in pairs(items) do
        if type(key) ~= "number" or key < 1 or key > #items or key ~= math.floor(key) then return false end
    end
    if spec.whole and not spec.whole(items) then return false end
    return true
end

-- The parts a list goes out in: each a string of items small enough for one
-- message, or nil when it needs more than MAX_PARTS.
local function Parts(items)
    local budget = Comm.MAX_BYTES - Versioned.MAX_HEADER
    local parts, current = {}, {}
    local size = 0
    for _, item in ipairs(items) do
        local add = #item + (#current > 0 and 1 or 0)
        if size + add > budget then
            parts[#parts + 1] = table.concat(current, ",")
            current, size, add = {}, 0, #item
        end
        current[#current + 1] = item
        size = size + add
    end
    if #current > 0 or #parts == 0 then parts[#parts + 1] = Versioned.Encode(current) end
    if #parts > Versioned.MAX_PARTS then return nil end
    return parts
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------

local function Drop(spec, counter, why, sender)
    ns.Diag.Count(counter)
    ns.Diag.Log("sync", "%s from %s: %s", spec.type, sender, why)
end

-- Make room for one more assembly of spec: forget the ones past their
-- time, then the oldest.
local function MakeRoom(spec, now)
    local oldest, count = nil, 0
    for sender, a in pairs(spec.assemblies) do
        if now - a.started > Versioned.ASSEMBLY_TTL or now < a.started then
            spec.assemblies[sender] = nil
        else
            count = count + 1
            if not oldest or a.started < spec.assemblies[oldest].started then oldest = sender end
        end
    end
    if count >= Versioned.MAX_ASSEMBLIES and oldest then spec.assemblies[oldest] = nil end
end

-- A whole list from sender, whose authority OnPart has just checked (as
-- the last part arrived): checked whole, and kept if it is newer.
local function Complete(spec, sender, version, items)
    if not Versioned.ValidList(spec, items) then return Drop(spec, "syncMalformed", "a list it refuses", sender) end
    local kept = spec.get()
    if not kept then return end
    local encoded = Versioned.Encode(items)
    if spec.heard then spec.heard(version, encoded) end
    if not Versioned.Newer(version, encoded, kept.version, Versioned.Encode(kept.items)) then
        return Drop(spec, "syncOld", "version " .. version .. " is not newer", sender)
    end
    local copy = {}
    for i, item in ipairs(items) do copy[i] = item end
    spec.set(version, copy, sender)
    ns.Diag.Count("syncTaken")
    ns.Diag.Log("sync", "took %s version %s from %s", spec.type, version, sender)
end

local function OnPart(spec, sender, fields)
    -- First, before anything is kept for the sender: for every part, so a
    -- sender demoted while the parts come in is refused at the next.
    if spec.authority(sender) ~= true then return Drop(spec, "syncNoAuthority", "not entitled", sender) end
    local kept = spec.get()
    if not kept then return end
    local version, part, parts = tonumber(fields[1]), tonumber(fields[2]), tonumber(fields[3])
    if version < kept.version then return Drop(spec, "syncOld", "version " .. fields[1] .. " is older", sender) end
    if part > parts then return Drop(spec, "syncMalformed", "part " .. part .. " of " .. parts, sender) end
    local items = SplitItems(fields[4])
    if parts == 1 then return Complete(spec, sender, version, items) end

    local now = GetTime()
    local a = spec.assemblies[sender]
    if a and (a.version ~= version or a.parts ~= parts or now - a.started > Versioned.ASSEMBLY_TTL
        or now < a.started) then
        a = nil
    end
    if not a then
        spec.assemblies[sender] = nil
        MakeRoom(spec, now)
        a = { version = version, parts = parts, got = {}, count = 0, started = now }
        spec.assemblies[sender] = a
    end
    if a.got[part] then return end -- a repeat of a part already here
    a.got[part] = items
    a.count = a.count + 1
    if a.count < parts then return end
    spec.assemblies[sender] = nil
    local all = {}
    for i = 1, parts do
        for _, item in ipairs(a.got[i]) do all[#all + 1] = item end
    end
    Complete(spec, sender, version, all)
end

------------------------------------------------------------------------
-- Defining and sending
------------------------------------------------------------------------

-- spec = {
--   type = "GCAPS": its Comm message type (registered here);
--   route = "GUILD": the one route it is sent and taken on;
--   item = function(text) -> true for an item it accepts;
--   itemBytes = the longest item, in bytes (at most MAX_ITEM_BYTES);
--   whole = optional function(items) -> true for a list it accepts together;
--   maxItems = the most items a list holds;
--   authority = function(sender) -> true when that player may set it now;
--   get = function() -> { version, items } kept now (version 0: never set),
--         or nil when there's nowhere to keep it (no guild): nothing is taken;
--   set = function(version, items, sender): keep a newer list;
--   heard = optional function(version, encoded): any whole list someone
--         with authority sent, newer or not (to leave a repeat to them).
-- }
-- Returns spec, with Send added.
function Versioned.Define(spec)
    -- After an update and a /reload without a restart, Comm may be missing:
    -- the addon then stays inert (Core.lua), so nothing is registered.
    if not Comm then return spec end
    assert(type(spec.item) == "function" and type(spec.authority) == "function", "Versioned: a section needs checks")
    assert(type(spec.get) == "function" and type(spec.set) == "function", "Versioned: a section needs storage")
    assert(spec.itemBytes >= 1 and spec.itemBytes <= Versioned.MAX_ITEM_BYTES, "Versioned: items too long")
    -- The most items, at their longest, fit in MAX_PARTS parts.
    local perPart = math.floor((Comm.MAX_BYTES - Versioned.MAX_HEADER + 1) / (spec.itemBytes + 1))
    assert(spec.maxItems >= 0 and spec.maxItems <= perPart * Versioned.MAX_PARTS, "Versioned: too many items")
    spec.assemblies = {}
    local function ItemsField(text)
        if text == "-" then return true end
        local n = 0
        for item in (text .. ","):gmatch("([^,]*),") do
            n = n + 1
            if n > spec.maxItems or #item > spec.itemBytes or not spec.item(item) then return false end
        end
        return true
    end
    Comm.RegisterType(spec.type, {
        fields = { Versioned.VersionField, PartField, PartField, ItemsField },
        routes = { [spec.route] = true },
        handler = function(sender, fields) OnPart(spec, sender, fields) end,
    })

    -- Send the list kept now, in as many parts as it needs. Returns true when
    -- every part was queued, or false and why.
    function spec.Send()
        local kept = spec.get()
        if not kept or kept.version < 1 then return false, "nothing to send" end
        local parts = Parts(kept.items)
        if not parts then return false, "too long" end
        -- Not %d: the game's Lua may format it through a 32-bit integer.
        local version = string.format("%.0f", kept.version)
        for i, text in ipairs(parts) do
            local ok, why = Comm.Send(spec.type, { version, tostring(i), tostring(#parts), text }, spec.route)
            if not ok then return false, why end
        end
        return true
    end
    return spec
end

-- How many part-sent lists are being put back together for spec.
function Versioned.Assembling(spec)
    local n = 0
    for _ in pairs(spec.assemblies) do n = n + 1 end
    return n
end
