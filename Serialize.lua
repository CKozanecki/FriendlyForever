-- Settings as one line of text, and back: for /friendly export and import.
-- Pasted text comes from anybody, so it is only ever parsed as data (never
-- run as code), with limits on size, depth and count, and whatever it holds
-- is then checked by Config.Load like the saved file.
--
-- Format: "FF1:" then one value.
--   T / F            true / false
--   N<number>;       a number
--   S<text>;         a string; "%", "|", ";" and control characters as %XX
--   {<key><value>...} a table; keys are strings or numbers
local _, ns = ...

local Serialize = {}
ns.Serialize = Serialize

Serialize.PREFIX = "FF1:"
Serialize.MAX_BYTES = 100000
Serialize.MAX_DEPTH = 5
Serialize.MAX_ITEMS = 5000

local function EncodeString(s)
    return (s:gsub("[%%|;%c]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function DecodeString(s)
    return (s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

local function SortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    return keys
end

local Encode
Encode = function(value, out, depth)
    local kind = type(value)
    if kind == "boolean" then
        out[#out + 1] = value and "T" or "F"
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then error("can't export that number") end
        out[#out + 1] = "N" .. string.format("%.17g", value) .. ";"
    elseif kind == "string" then
        out[#out + 1] = "S" .. EncodeString(value) .. ";"
    elseif kind == "table" then
        if depth >= Serialize.MAX_DEPTH then error("settings nest too deeply") end
        out[#out + 1] = "{"
        for _, k in ipairs(SortedKeys(value)) do
            if type(k) ~= "string" and type(k) ~= "number" then error("bad key") end
            Encode(k, out, depth + 1)
            Encode(value[k], out, depth + 1)
        end
        out[#out + 1] = "}"
    else
        error("can't export a " .. kind)
    end
end

-- Returns the text, or nil and why not.
function Serialize.Encode(value)
    local out = { Serialize.PREFIX }
    local ok, err = pcall(Encode, value, out, 0)
    if not ok then return nil, tostring(err) end
    return table.concat(out)
end

-- Returns the value, or nil and why it couldn't be read.
function Serialize.Decode(text)
    if type(text) ~= "string" then return nil, "nothing to read" end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if #text > Serialize.MAX_BYTES then return nil, "that text is too long" end
    if text:sub(1, #Serialize.PREFIX) ~= Serialize.PREFIX then
        return nil, "that isn't a Friendly Forever settings line"
    end

    local pos, items = #Serialize.PREFIX + 1, 0
    local Value

    local function Fail(why) error({ why = why }, 0) end

    local function Until(stop)
        local finish = text:find(stop, pos, true)
        if not finish then Fail("the text is cut short") end
        local piece = text:sub(pos, finish - 1)
        pos = finish + 1
        return piece
    end

    Value = function(depth)
        items = items + 1
        if items > Serialize.MAX_ITEMS then Fail("too many values") end
        local tag = text:sub(pos, pos)
        pos = pos + 1
        if tag == "T" then return true end
        if tag == "F" then return false end
        if tag == "N" then
            local n = tonumber(Until(";"))
            if not n or n ~= n then Fail("a number is damaged") end
            return n
        end
        if tag == "S" then return DecodeString(Until(";")) end
        if tag == "{" then
            if depth >= Serialize.MAX_DEPTH then Fail("it nests too deeply") end
            local t = {}
            while text:sub(pos, pos) ~= "}" do
                if pos > #text then Fail("the text is cut short") end
                local k = Value(depth + 1)
                if type(k) ~= "string" and type(k) ~= "number" then Fail("a key is damaged") end
                t[k] = Value(depth + 1)
            end
            pos = pos + 1
            return t
        end
        Fail(pos > #text + 1 and "the text is cut short" or "the text is damaged")
    end

    local ok, result = pcall(Value, 0)
    if not ok then
        return nil, type(result) == "table" and result.why or "the text is damaged"
    end
    if pos <= #text then return nil, "there's extra text at the end" end
    return result
end
