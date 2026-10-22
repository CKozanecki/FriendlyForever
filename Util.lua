-- Pure helpers with no game state. Everything that turns untrusted text
-- (system messages, user-edited templates, player and spell names) into
-- something we send to chat goes through here.
local _, ns = ...

local Util = {}
ns.Util = Util

-- Hard limit the server enforces on a single chat message, in bytes.
Util.MAX_CHAT_BYTES = 255

-- Midnight-era clients can hand addons "secret" values in restricted
-- contexts. They must never be compared, concatenated or sent.
function Util.IsSecret(value)
    if value == nil then return false end
    if issecretvalue and issecretvalue(value) then return true end
    if type(value) == "table" and issecrettable and issecrettable(value) then return true end
    return false
end

-- value, or nil plus true when it is secret. Testing a secret in an `if`,
-- comparing it or indexing it raises an error, so read every field of
-- game data through this before using it.
function Util.Readable(value)
    if Util.IsSecret(value) then return nil, true end
    return value, false
end

-- Convert a Blizzard format string such as ERR_GUILD_JOIN_S ("%s has joined
-- the guild.") into an anchored Lua pattern with one capture per %s, so
-- system messages are recognised in every client language.
function Util.FormatToPattern(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end
    local p = fmt:gsub("%%%d*%$?s", "\001"):gsub("%%%d*%$?d", "\002")
    p = p:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    p = p:gsub("\001", "(.-)"):gsub("\002", "%%d+")
    return "^" .. p .. "$"
end

-- Remove anything the chat system could interpret: "|" starts UI escape
-- sequences (links, colours, textures) and is rejected or abused in sent
-- messages, and control characters have no business in chat.
function Util.StripChat(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("|", ""):gsub("[%z\1-\31\127]", " ")
    text = text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return text
end

-- Cut a string to at most maxBytes without splitting a UTF-8 character.
function Util.Utf8Truncate(text, maxBytes)
    if #text <= maxBytes then return text end
    local cut = maxBytes
    while cut > 0 do
        local nextByte = text:byte(cut + 1)
        -- 0x80-0xBF are continuation bytes: the character straddles the cut.
        if nextByte < 0x80 or nextByte >= 0xC0 then break end
        cut = cut - 1
    end
    return text:sub(1, cut)
end

-- {"A"} -> "A", {"A", "B"} -> "A and B", {"A", "B", "C"} -> "A, B and C"
function Util.JoinList(items, conjunction)
    local n = #items
    if n == 0 then return "" end
    if n == 1 then return items[1] end
    return table.concat(items, ", ", 1, n - 1) .. " " .. (conjunction or "and") .. " " .. items[n]
end

-- Fill {placeholders} in a template. Unknown placeholders are left as typed.
-- Values are inserted literally (no pattern or escape interpretation), and
-- the result is sanitised and cut to the chat length limit.
function Util.Render(template, vars)
    if type(template) ~= "string" then return nil end
    local out = template:gsub("{(%a+)}", function(key)
        local value = vars[key]
        if value ~= nil then return Util.StripChat(tostring(value)) end
    end)
    out = Util.StripChat(out)
    if out == "" then return nil end
    return Util.Utf8Truncate(out, Util.MAX_CHAT_BYTES)
end

-- WoW Forever characters have a first name AND a surname ("Nikki-Shifts");
-- the pair is the player's identity (there are no realms). Never shorten a
-- name to its first part except for display: the game can't find "Nikki".

-- One part of a name: letters only (may be multi-byte), 2-12 characters.
local function ValidNamePart(part)
    return type(part) == "string" and #part >= 2 and #part <= 48 and not part:find("[%s%c%p%d]")
end

-- Canonical full name, "First-Surname" (or "First" if the game gave no
-- surname), or nil if missing, secret or not a plausible player name.
-- Accepts "First-Surname", "First Surname", or the first name with the
-- surname as a separate value (UnitName's second return). A second value
-- that isn't a plausible surname is ignored rather than trusted.
function Util.FullName(name, surname)
    if Util.IsSecret(name) or type(name) ~= "string" then return nil end
    local first, last = name:match("^([^%-%s]+)[%-%s]([^%-%s]+)$")
    if not first then first = name end
    if not ValidNamePart(first) then return nil end
    if last then
        if not ValidNamePart(last) then return nil end
    elseif not Util.IsSecret(surname) and ValidNamePart(surname) then
        last = surname
    end
    return last and (first .. "-" .. last) or first
end

-- "Nikki" from "Nikki-Shifts": for addressing someone in a message only.
function Util.FirstName(fullName)
    return (fullName:match("^[^%-]+"))
end

-- "Nikki Shifts" from "Nikki-Shifts": the name as players see it.
function Util.DisplayName(fullName)
    return (fullName:gsub("%-", " "))
end

-- Placeholder values for a player: {name} is the first name, {fullname}
-- the whole name.
function Util.NameVars(fullName)
    return { name = Util.FirstName(fullName), fullname = Util.DisplayName(fullName) }
end

-- Full name of a unit token ("player", "target", ...), or nil.
function Util.UnitFullName(unit)
    return Util.FullName(UnitName(unit))
end

-- Whole number within [min, max]; anything that isn't a number gets default.
function Util.ClampNumber(value, min, max, default)
    if type(value) ~= "number" or value ~= value then return default end
    value = math.floor(value)
    if value < min then return min end
    if value > max then return max end
    return value
end
