-- Defaults, limits and validation for the saved settings. The saved file is
-- plain Lua on disk that anyone can edit, so every value is type-checked and
-- clamped on load; nothing from it is trusted as-is.
local _, ns = ...
local Util = ns.Util

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
        help    = "Welcomes players who join your group, several per line; in raids, only the leader. "
            .. "Placeholders: {name}, {fullname}",
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
        messages = {
            "{name} has logged in. Quick, everyone look busy.",
            "Welcome back, {name}. Your bags are still full, sorry.",
            "{name} is online! Hide the good loot.",
            "Oh good, {name}'s here. Now we can blame someone.",
            "Welcome back, {name}! The murlocs didn't miss you.",
            "{name} returns! Did you remember to repair?",
            "Hey {name}. We told everyone you were AFK, not gone.",
            "{name} has entered the chat. Act natural.",
            "Welcome back, {name}! Your hearthstone is right where you left it.",
            "{name}! We were just talking about you. Nothing bad. Mostly.",
            "Ah, {name}. Right on time. Probably.",
            "{name} logs in. Somewhere, a quest giver sighs with relief.",
            "Welcome back, {name}. Gold prices went up while you were gone. Not really.",
            "Look who escaped real life. Hi {name}!",
            "{name} is back! Somebody put the kettle on.",
            "Welcome back, {name}! Still no mount? Same.",
            "Hey {name}! Grab a snack, you'll need it.",
            "{name} has arrived. The raid on the vendor can begin.",
            "Hi {name}! You've been gone ten minutes. We already miss you. Weird, right?",
            "Welcome back, {name}. Please keep hands and pets inside the guild at all times.",
            "{name}! Excellent. Now we have enough people to argue about loot.",
            "Hey {name}, the boars have been asking about you.",
            "Welcome back, {name}! No, the Barrens chat hasn't improved.",
            "{name} is online. Rumours of your death were greatly exaggerated.",
            "Hi {name}! Bring snacks? No? Bold move.",
            "{name} logs in, ready to pull. Someone warn the healer.",
            "Welcome back, {name}. Try not to die in the first five minutes this time.",
            "Hey {name}! Fresh day, same bag space problems.",
            "{name}! The guild bank is exactly as empty as you left it.",
            "Welcome back, {name}. The fishing spot is free. For now.",
        },
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
        -- {buff} becomes "Arcane Intellect" or "Arcane Intellect and Mark of
        -- the Wild" (or "buff"/"buffs" when listing names is off), so every
        -- line must read naturally with one or several buffs.
        messages = {
            "Thank you for the {buff}, {name}!",
            "Thanks for the {buff}, {name}! Much appreciated.",
            "{name}, thank you kindly for the {buff}!",
            "Appreciate the {buff}, {name}! Safe travels.",
            "Thanks, {name}! The {buff} will come in handy.",
            "Thank you, {name}! You're very kind.",
            "Many thanks for the {buff}, {name}!",
            "Cheers for the {buff}, {name}! Have a great day.",
            "Thanks {name}! Good luck out there.",
            "Much obliged for the {buff}, {name}!",
            "Thanks so much for the {buff}, {name}!",
            "{name}, you're a star. Thanks for the {buff}!",
            "Thank you, {name}! Love the {buff}.",
            "Grateful for the {buff}, {name}! Thank you.",
            "The {buff} is much appreciated, {name}!",
            "Thanks for looking out for me, {name}! The {buff} helps.",
            "Woo, {buff}! Thank you, {name}!",
            "Thank you kindly, {name}! The {buff} is perfect.",
            "{name}, thanks for the {buff}! You rock.",
            "Appreciate you, {name}! Thanks for the {buff}.",
            "Thanks for the {buff}, {name}! Stay safe out there.",
            "That {buff} hits the spot. Thanks, {name}!",
            "Many thanks, {name}! Enjoying the {buff}.",
            "Thanks for the boost, {name}! The {buff} is great.",
            "{name}, thank you! The {buff} is a lovely surprise.",
            "Thank you for thinking of me, {name}! Love the {buff}.",
            "Bless you, {name}! Thanks for the {buff}.",
            "Thanks a ton for the {buff}, {name}!",
            "Kind of you, {name}! Thanks for the {buff}.",
            "Thanks, {name}! Happy hunting!",
        },
    },
    guildJoin = {
        enabled = true,
        delay = 4,
        repeatCooldown = 180,
        messages = {
            "Welcome to the guild, {name}! We're glad to have you.",
            "Hi {name}, and welcome aboard! Feel free to ask if you need anything.",
            "A warm welcome to {name}, our newest member!",
            "Welcome, {name}! Happy to have you with us.",
            "Everyone say hi to {name}! Welcome to the guild.",
            "Welcome to the family, {name}!",
            "Great to have you, {name}! Don't hesitate to ask for help.",
            "Welcome aboard, {name}! Hope you enjoy your time here.",
            "Hello and welcome, {name}! Glad you found us.",
            "Welcome, {name}! Looking forward to adventuring together.",
            "Welcome, {name}! Make yourself at home.",
            "A big welcome to {name}! Glad you're here.",
            "Welcome to the guild, {name}! Ask us anything.",
            "Hi {name}! So happy you joined us.",
            "Welcome, {name}! The more the merrier.",
            "Everyone, please welcome {name}!",
            "Welcome in, {name}! Hope you like it here.",
            "Glad to have you, {name}! Welcome to the guild.",
            "Welcome, {name}! We're a friendly bunch, promise.",
            "Hey {name}, welcome! Happy to have you aboard.",
            "Welcome to the guild, {name}! Adventure awaits.",
            "Hi {name}! Welcome, and feel free to say hello anytime.",
            "Welcome, {name}! Great to have a new face around.",
            "Cheers to {name}, our newest member! Welcome!",
            "Welcome aboard, {name}! Let us know if you need a hand.",
            "Hello {name}! Welcome to the guild. Glad you're with us.",
            "Welcome, {name}! Pull up a chair.",
            "A warm hello to {name}! Welcome to the guild.",
            "Welcome to the crew, {name}!",
            "Hi {name}, welcome! We're glad you found your way here.",
        },
    },
    partyJoin = {
        enabled = true,
        delay = 2,
        repeatCooldown = 180,
        messages = {
            "Welcome to the group, {name}!",
            "Hi {name}, glad to have you with us!",
            "Welcome, {name}! Let's have a good run.",
            "Hey {name}, welcome aboard!",
            "Glad you could join us, {name}!",
            "Welcome, {name}! Good luck and have fun.",
            "Hello {name}! Happy to have you in the party.",
            "Welcome in, {name}! Let us know if you need anything.",
            "Great to have you, {name}! Let's do this.",
            "Hi {name}! Welcome to the party.",
            "Hey {name}! Glad you're here.",
            "Welcome along, {name}!",
            "Hi {name}! Good to have you in the group.",
            "Welcome, {name}! Let's get going.",
            "Hey {name}, thanks for joining!",
            "Welcome to the team, {name}!",
            "Hi {name}! Ready when you are.",
            "{name}! Welcome, happy to have you.",
            "Welcome, {name}! Let's make it a good one.",
            "Hey {name}, welcome! Shout if you need anything.",
            "Glad to have you along, {name}!",
            "Welcome in, {name}! Let's have some fun.",
            "Hi {name}! Thanks for coming along.",
            "Hey {name}! The more the merrier.",
            "Welcome, {name}! Good to group up with you.",
            "Hello {name}! Welcome aboard.",
            "Hi {name}, welcome to the group! Have fun.",
            "Welcome, {name}! Let's go get 'em.",
            "Hey {name}! Great to have you with us.",
            "Welcome along, {name}! Safe travels with us.",
        },
    },
    -- Repeat cooldowns here are per group leader and only stop a rapid
    -- leave/rejoin from repeating; a new group always gets its hello.
    partyHello = {
        enabled = true,
        delay = 3,
        repeatCooldown = 30,
        messages = {
            "Hi all! Thanks for the invite.",
            "Hello everyone! Glad to join you.",
            "Hey all, thanks for having me!",
            "Hi everyone! Ready when you are.",
            "Hello! Thanks for the invite.",
            "Hey everyone! Let's have a good one.",
            "Hi all! Happy to be here.",
            "o/ Hi everyone, thanks for the group!",
            "Hello all! Good to be grouped with you.",
            "Hey team! Thanks for the invite.",
            "Hi everyone! Thanks for the invite.",
            "Hey all! Happy to help out.",
            "Hello! Thanks for letting me join.",
            "Hi all! Let's have some fun.",
            "Hey everyone! Glad to be here.",
            "Hello all! Thanks for the group.",
            "Hi team! Ready to go.",
            "Hey all, thanks for the invite! Let's do this.",
            "Hello everyone! Nice to meet you all.",
            "Hi all! Thanks for having me along.",
            "Hey everyone! Good to group up.",
            "Hello! Happy to be in the group.",
            "Hi everyone, thanks! Lead the way.",
            "Hey all! Thanks for picking me up.",
            "Hello team! Let's make it a good one.",
            "Hi all! Glad I could join.",
            "Hey everyone! Thanks for the invite, let's go.",
            "Hello all! Ready when you are.",
            "Hi everyone! Good luck to us all.",
            "Hey all! Nice to be grouped with you.",
        },
    },
    partyHelloAgain = {
        enabled = true,
        delay = 3,
        repeatCooldown = 30,
        messages = {
            "Nice to see you all again!",
            "Back again! Thanks for having me.",
            "Hello again, everyone!",
            "Good to be back with you all!",
            "Hi again! Thanks for the re-invite.",
            "And I'm back! Good to see you again.",
            "Hey again, team!",
            "Round two! Nice to see you all again.",
            "Hello again! Let's pick up where we left off.",
            "o/ Back with the crew. Hi again!",
            "Back for more! Hi again, everyone.",
            "Hello again! Good to be back.",
            "Hi again, all! Thanks for having me back.",
            "Hey, I'm back! Nice to see you again.",
            "Hello again, team! Missed you already.",
            "Back again! Let's keep it going.",
            "Hi all, good to see you again!",
            "Hey everyone, I'm back! Thanks for the re-invite.",
            "Hello again! Ready to pick it back up.",
            "Hi again! Couldn't stay away.",
            "Back with you all! Hello again.",
            "Hey again, everyone! Let's go.",
            "Hello again, friends!",
            "Hi again! Thanks for taking me back.",
            "Back in action! Hi again, all.",
            "Hey all, good to be back with you!",
            "Hello again! Where were we?",
            "Hi again, everyone! Glad to be back.",
            "Reunited! Hi again, team.",
            "Hey, I'm back! Thanks again for the invite.",
        },
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
