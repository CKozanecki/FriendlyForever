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

function Messages.Pick(msgType, messages)
    local usable = {}
    local candidates = {}
    for i = 1, #messages do
        local text = messages[i]
        if type(text) == "string" and text:find("%S") then
            usable[i] = true
            candidates[#candidates + 1] = i
        end
    end
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

    local index = table.remove(left)
    bag.left, bag.last = left, index
    bags[msgType] = bag
    return messages[index], index
end
