-- Message selection: a shuffle bag per message type. Every non-blank line is
-- used once, in random order, before any line repeats, and a new round never
-- starts with the line that ended the last one. The bags live in the saved
-- settings, so the rotation carries on across reloads and logins.
local _, ns = ...

local Messages = {}
ns.Messages = Messages

-- Overridable so tests can make the choice deterministic.
Messages.random = math.random

local fallbackBags = {} -- used until the saved settings are loaded

local function Bags()
    if ns.db and type(ns.db.messageBags) == "table" then return ns.db.messageBags end
    return fallbackBags
end

local function Shuffled(list)
    for i = #list, 2, -1 do
        local j = Messages.random(i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

-- The non-blank lines: a set of their indexes, and the indexes in order.
-- (A list that isn't a table, from damaged settings, has no usable lines.)
local function Usable(messages)
    local usable = {}
    local candidates = {}
    if type(messages) ~= "table" then return usable, candidates end
    for i = 1, #messages do
        local text = messages[i]
        if type(text) == "string" and text:find("%S") then
            usable[i] = true
            candidates[#candidates + 1] = i
        end
    end
    return usable, candidates
end

-- A random non-blank line for previews (/friendly test, "Preview random").
-- Leaves the saved bag alone, so previews don't use up the real rotation.
function Messages.Preview(messages)
    local _, candidates = Usable(messages)
    if #candidates == 0 then return nil end
    local index = candidates[Messages.random(#candidates)]
    return messages[index], index
end

-- avoid: an optional set of line numbers to pass over (lines other copies
-- of the addon have said they'll use: #38). The bag's next line that isn't
-- avoided; if the bag holds only avoided ones, a random line that isn't
-- (the bag is left as it was); if every line is avoided, the bag's next.
function Messages.Pick(msgType, messages, avoid)
    local usable, candidates = Usable(messages)
    if #candidates == 0 then return nil end

    local bags = Bags()
    local bag = bags[msgType]
    if type(bag) ~= "table" then bag = { left = {} } end

    -- Drop lines that were blanked (or removed) since the bag was filled.
    local left = {}
    for _, i in ipairs(bag.left or {}) do
        if usable[i] then left[#left + 1] = i end
    end

    if #left == 0 then
        left = Shuffled(candidates)
        -- Picks come off the end; don't open a round with the last line used.
        if #left > 1 and left[#left] == bag.last then
            left[#left], left[1] = left[1], left[#left]
        end
    end

    local at = #left
    if avoid then
        while at > 0 and avoid[left[at]] do at = at - 1 end
        if at == 0 then
            local free = {}
            for _, i in ipairs(candidates) do
                if not avoid[i] then free[#free + 1] = i end
            end
            if #free > 0 then
                local index = free[Messages.random(#free)]
                return messages[index], index
            end
            at = #left
        end
    end
    local index = table.remove(left, at)
    bag.left, bag.last = left, index
    bags[msgType] = bag
    return messages[index], index
end
