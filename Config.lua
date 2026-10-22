-- Defaults, limits and validation for the saved settings. The saved file is
-- plain Lua on disk that anyone can edit, so every value is type-checked and
-- clamped on load; nothing from it is trusted as-is. The default message
-- lines live in Defaults.lua.
local _, ns = ...
local Util = ns.Util
local DefaultMessages = ns.DefaultMessages

local Config = {}
ns.Config = Config

Config.SCHEMA_VERSION = 5
Config.NUM_MESSAGES = 30
Config.MAX_LOG = 400 -- diagnostic log lines kept in saved variables

Config.LIMITS = {
    delay          = { min = 0, max = 60 },    -- seconds
    repeatCooldown = { min = 0, max = 3600 },  -- seconds
    unknownName    = { maxBytes = 24 },
}

-- Order of message types (also the order of the options tabs).
Config.TYPES = { "guildLogin", "buff", "guildJoin", "partyJoin", "partyHello", "partyHelloAgain" }

Config.TYPE_INFO = {
    guildLogin = {
        label   = "Guild Login",
        channel = "Guild chat",
        help    = "Greets guild members when they come online. Placeholders: {name} (first name), {fullname}",
    },
    buff = {
        label   = "Buff Thanks",
        channel = "Say or whisper",
        help    = "Thanks players outside your group who buff you. Placeholders: {name}, {fullname}, {buff}",
    },
    guildJoin = {
        label   = "Guild Join",
        channel = "Guild chat",
        help    = "Welcomes new members who join the guild. Placeholders: {name} (first name), {fullname}",
    },
    partyJoin = {
        label   = "Party Join",
        channel = "Party chat",
        help    = "Welcomes players who join your group. Placeholders: {name} (first name), {fullname}",
    },
    partyHello = {
        label   = "Party Hello",
        channel = "Party chat",
        help    = "Says hello when you join someone else's group (not battlegrounds). Repeat is per group leader.",
    },
    partyHelloAgain = {
        label   = "Hello Again",
        channel = "Party chat",
        help    = "Said instead of Party Hello when you rejoin a group (same leader) this session.",
    },
}

Config.DEFAULTS = {
    guildLogin = {
        enabled = true,
        delay = 3,
        repeatCooldown = 180,
        messages = DefaultMessages.guildLogin,
    },
    buff = {
        enabled = true,
        delay = 4,
        repeatCooldown = 180,
        listBuffNames = true,
        useWhisper = false,
        -- Thank casters that can't be named (or whose whisper fails) in /say,
        -- calling them unknownName.
        fallbackToSay = true,
        unknownName = "friend",
        messages = DefaultMessages.buff,
    },
    guildJoin = {
        enabled = true,
        delay = 4,
        repeatCooldown = 180,
        messages = DefaultMessages.guildJoin,
    },
    partyJoin = {
        enabled = true,
        delay = 2,
        repeatCooldown = 180,
        messages = DefaultMessages.partyJoin,
    },
    -- Repeat cooldowns here are per group leader and only stop a rapid
    -- leave/rejoin from repeating; a new group always gets its hello.
    partyHello = {
        enabled = true,
        delay = 3,
        repeatCooldown = 30,
        messages = DefaultMessages.partyHello,
    },
    partyHelloAgain = {
        enabled = true,
        delay = 3,
        repeatCooldown = 30,
        messages = DefaultMessages.partyHelloAgain,
    },
}

local function CopyList(list)
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    return out
end

function Config.CleanMessage(text)
    if type(text) ~= "string" then return "" end
    return Util.Utf8Truncate(text, Util.MAX_CHAT_BYTES)
end

function Config.CleanUnknownName(text)
    if type(text) ~= "string" then return Config.DEFAULTS.buff.unknownName end
    return Util.Utf8Truncate(Util.StripChat(text), Config.LIMITS.unknownName.maxBytes)
end

local function ValidateType(saved, defaults)
    local cfg = type(saved) == "table" and saved or {}
    local limits = Config.LIMITS

    if type(cfg.enabled) ~= "boolean" then cfg.enabled = defaults.enabled end
    cfg.delay = Util.ClampNumber(cfg.delay, limits.delay.min, limits.delay.max, defaults.delay)
    cfg.repeatCooldown = Util.ClampNumber(cfg.repeatCooldown,
        limits.repeatCooldown.min, limits.repeatCooldown.max, defaults.repeatCooldown)

    for _, flag in ipairs({ "listBuffNames", "useWhisper", "fallbackToSay" }) do
        if defaults[flag] ~= nil and type(cfg[flag]) ~= "boolean" then cfg[flag] = defaults[flag] end
    end
    if defaults.unknownName ~= nil then
        cfg.unknownName = cfg.unknownName == nil and defaults.unknownName or Config.CleanUnknownName(cfg.unknownName)
    end

    if type(cfg.messages) ~= "table" then
        cfg.messages = CopyList(defaults.messages)
    else
        local clean = {}
        for i = 1, Config.NUM_MESSAGES do clean[i] = Config.CleanMessage(cfg.messages[i]) end
        cfg.messages = clean
    end
    return cfg
end

-- The guild login defaults before 1.5.0 (only the first 10 ever shipped).
local OLD_GUILD_LOGIN = {
    "Welcome back, {name}!",
    "Hey {name}, good to see you online!",
    "Hi {name}! Hope you're having a great day.",
    "{name} is here! Welcome back.",
    "Welcome back, {name}. The guild missed you!",
    "Good to see you, {name}! Have fun out there.",
    "Hello {name}! Ready for some adventure?",
    "Greetings, {name}! Welcome back to Azeroth.",
    "Hey {name}, welcome back! Let us know if you need anything.",
    "o/ {name}! Glad you could join us.",
}

-- Each entry upgrades a saved file from version (key - 1) to key.
local MIGRATIONS = {
    [5] = function(db)
        -- Guild login lines were rewritten: a saved line still exactly the old
        -- default becomes the new one in its slot; lines you edited stay.
        if type(db.guildLogin) == "table" and type(db.guildLogin.messages) == "table" then
            local msgs = db.guildLogin.messages
            for i, old in ipairs(OLD_GUILD_LOGIN) do
                if msgs[i] == old then msgs[i] = Config.DEFAULTS.guildLogin.messages[i] end
            end
        end
        -- Up to 1.4.2 each type had 10 lines; now 30. Keep the saved 10 (edits
        -- included) and fill the new slots with the new default lines.
        for msgType, defaults in pairs(Config.DEFAULTS) do
            local cfg = db[msgType]
            if type(cfg) == "table" and type(cfg.messages) == "table" then
                for i = 11, #defaults.messages do
                    if cfg.messages[i] == nil then cfg.messages[i] = defaults.messages[i] end
                end
            end
        end
    end,
    [4] = function(db)
        -- 1.4.0 shipped Party Hello with one 180s cooldown for every group,
        -- which skipped the hello for a second group. It is now per leader
        -- and only guards against a rapid rejoin.
        if type(db.partyHello) == "table" and db.partyHello.repeatCooldown == 180 then
            db.partyHello.repeatCooldown = 30
        end
    end,
    [3] = function(db)
        -- Up to 1.2.2 a blank unknown-caster name meant "don't thank them";
        -- that is now the fallbackToSay switch, and the name is just wording.
        if type(db.buff) == "table" and db.buff.unknownName == "" then
            db.buff.fallbackToSay = false
            db.buff.unknownName = nil
        end
    end,
    [2] = function(db)
        -- 1.0.0 had a buff-only "cooldown" (seconds); every type now has repeatCooldown.
        if type(db.buff) == "table" and db.buff.cooldown ~= nil then
            if db.buff.repeatCooldown == nil then db.buff.repeatCooldown = db.buff.cooldown end
            db.buff.cooldown = nil
        end
    end,
}

function Config.Load(saved)
    local db = type(saved) == "table" and saved or {}

    local version = Util.ClampNumber(db.schemaVersion, 1, Config.SCHEMA_VERSION, 1)
    for v = version + 1, Config.SCHEMA_VERSION do
        if MIGRATIONS[v] then MIGRATIONS[v](db) end
    end
    db.schemaVersion = Config.SCHEMA_VERSION

    if type(db.enabled) ~= "boolean" then db.enabled = true end

    if type(db.minimap) ~= "table" then db.minimap = {} end
    db.minimap.angle = Util.ClampNumber(db.minimap.angle, 0, 360, 220)
    if type(db.minimap.hide) ~= "boolean" then db.minimap.hide = false end

    -- Diagnostics: a debug flag and the most recent log lines (strings only).
    if type(db.debug) ~= "boolean" then db.debug = false end
    local log = {}
    if type(db.diagLog) == "table" then
        for _, line in ipairs(db.diagLog) do
            if type(line) == "string" then log[#log + 1] = Util.Utf8Truncate(line, 500) end
        end
    end
    while #log > Config.MAX_LOG do table.remove(log, 1) end
    db.diagLog = log

    for _, msgType in ipairs(Config.TYPES) do
        db[msgType] = ValidateType(db[msgType], Config.DEFAULTS[msgType])
    end

    -- Message rotation (see Messages.lua): line numbers still to use, and the
    -- last one used, per type. Anything malformed just starts a fresh round.
    local bags = {}
    if type(db.messageBags) == "table" then
        for _, msgType in ipairs(Config.TYPES) do
            local bag = db.messageBags[msgType]
            if type(bag) == "table" then
                local left = {}
                if type(bag.left) == "table" then
                    for _, i in ipairs(bag.left) do
                        if type(i) == "number" and i == math.floor(i) and i >= 1 and i <= Config.NUM_MESSAGES then
                            left[#left + 1] = i
                        end
                    end
                end
                local last = bag.last
                if type(last) ~= "number" or last < 1 or last > Config.NUM_MESSAGES then last = nil end
                bags[msgType] = { left = left, last = last }
            end
        end
    end
    db.messageBags = bags
    return db
end

-- Fresh copy of one type's defaults.
function Config.DefaultsFor(msgType)
    return ValidateType(nil, Config.DEFAULTS[msgType])
end
