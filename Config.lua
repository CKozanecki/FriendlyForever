-- Defaults, limits and validation for the saved settings. The saved file is
-- plain Lua on disk that anyone can edit, so every value is type-checked and
-- clamped on load; nothing from it is trusted as-is. The default message
-- lines live in Defaults.lua.
local _, ns = ...
local Util = ns.Util
-- Missing only when the game was /reloaded after an update that added the
-- file: the client reads the file list at start-up, so it needs a restart.
local DefaultMessages = ns.DefaultMessages
    or error("FriendlyForever: Defaults.lua isn't loaded. Restart the game after updating the addon.")
local CasualMessages = ns.CasualMessages
    or error("FriendlyForever: Defaults.lua is out of date. Restart the game after updating the addon.")

local Config = {}
ns.Config = Config


Config.SCHEMA_VERSION = 6
Config.NUM_MESSAGES = 30
Config.MAX_LOG = 400 -- diagnostic log lines kept in saved variables
Config.MAX_IGNORED = 500
Config.REPAIR_INTERVAL_SECONDS = 1 -- the shortest time between mid-session repairs (Config.Repair)
Config.SNOOZE_MAX_SECONDS = 24 * 60 * 60
-- How to thank someone who buffs you (#101): "message" (a line in /say),
-- "whisper", "emote" (/thank them) or "both" (a line in /say and /thank).
Config.THANK_STYLES = { message = true, whisper = true, emote = true, both = true }
-- What to do when that can't reach them (no name, or the whisper fails):
-- "say" (a line in /say, calling them unknownName), "emote" (/thank instead)
-- or "none".
Config.FALLBACKS = { say = true, emote = true, none = true }

Config.LIMITS = {
    delay          = { min = 0, max = 60 },    -- seconds
    repeatCooldown = { min = 0, max = 3600 },  -- seconds
    unknownName    = { maxBytes = 24 },
    owedMinutes    = { min = 1, max = 60 },  -- how long a favour stays on the buff-back button
    autoOffMinutes = { min = 0, max = 30 },  -- buff mode a trigger turned on ends after this (0: never)
    linesPerMinute = { min = 1, max = 10 },  -- the most lines each chat type gets a minute (ChatQueue)
}

-- Order of message types (also the order of the options tabs).
Config.TYPES = { "guildLogin", "buff", "guildJoin", "partyJoin", "partyHello", "partyHelloAgain", "buffBack" }

Config.TYPE_INFO = {
    guildLogin = {
        label   = "Guild Login",
        channel = "Guild chat",
        help    = "Greets guild members when they come online. Placeholders: {name} (first name), {fullname}",
    },
    buff = {
        label   = "Buff Thanks",
        channel = "/say, a whisper or /thank",
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
        help    = "Welcomes joiners, several per line; in raids, only the leader. "
            .. "Placeholders: {name} (first name), {fullname}",
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
    -- Queued only once a buff-back is confirmed (each favour is returned once),
    -- so it has no delay or repeat cooldown of its own.
    buffBack = {
        label   = "Buff Back",
        channel = "/say, a whisper or /thank, once your buff lands",
        help    = "Said once your buff from the buff-back button reaches them (if switched on), "
            .. "the way Buff Thanks thanks them: in /say, as a whisper, or a /thank for the emote. "
            .. "Placeholders: {name}, {fullname}, {buff} (the spell you cast)",
        noTiming = true,
        enabledLabel = "Offer to buff back players who buff me",
    },
}

-- Not every entry is a message type (skipWhileAFK isn't), so loop over
-- Config.TYPES for the types, never pairs(Config.DEFAULTS).
Config.DEFAULTS = {
    -- General switch (not a message type): drop automatic messages that
    -- come due while you're AFK, instead of greeting people for hours.
    skipWhileAFK = true,
    -- General: the most lines the addon sends to each chat type (/say,
    -- whispers, emotes, guild, group) in any minute (#35).
    linesPerMinute = 4,
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
        -- Thank them with (Config.THANK_STYLES), and if that can't reach
        -- them (Config.FALLBACKS). The "say" fallback calls them unknownName.
        thankStyle = "message",
        fallback = "say",
        unknownName = "friend",
        -- No thank-yous in capital cities (Cities.lua), unless buff mode is on.
        quietInCities = true,
        -- Tell players outside your group you buff that it was you (#138):
        -- a hidden addon whisper only their copy of the addon hears.
        receipts = true,
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
    -- enabled: offer to buff back (show the button). sayLine: say a line once
    -- the buff lands. No delay or repeat cooldown: one line per favour returned.
    buffBack = {
        enabled = true,
        sayLine = false,
        owedMinutes = 10,
        unlocked = false,
        -- Show the button in capital cities (Cities.lua); buff mode always does.
        showInCities = false,
        position = { point = "CENTER", x = 0, y = -180 },
        -- The key buff mode lends to the button (BuffMode.lua).
        buffModeKey = "MOUSEWHEELUP",
        -- When buff mode turns on and off by itself (BuffModeAuto.lua). All
        -- on by default: each turn-on says why in chat, and the first one a
        -- session says where to switch them (BuffMode.Set). The "Start here"
        -- walkthrough (#47, planned) will show them too. The ones that turn
        -- it off end only buff mode a trigger turned on.
        autoOnJoin = true,
        autoOnDeath = true,
        autoOnBuffed = true,
        autoOffPull = true,
        autoOffDone = true,
        autoOffMinutes = 5,
        -- Battlegrounds (Battleground.lua): buff before the gates open. Off,
        -- the preparation phase is as quiet as the battle.
        bgPrepBuff = true,
        -- Unending Breath and Water Breathing only near water (Water.lua, #136).
        -- Off: offered anywhere, as before.
        breathNearWater = true,
        -- buffOrder: buff keys, offered first in this order (empty: each
        -- class's own order). neverOffer: [buff key] = true. They hold keys
        -- of any class, so one profile serves all your characters.
        buffOrder = {},
        neverOffer = {},
        -- Who gets each buff in buff mode (BuffRules.lua): [buff key] =
        -- { rule, classes, always, never }. Empty: every buff's default.
        whoGets = {},
        -- Whose Salvation buff mode offers to Revoke (paladins), and the
        -- names its "chosen" modes cover (BuffRules.lua).
        revokeMode = "mine",
        revokeNames = {},
        messages = DefaultMessages.buffBack,
    },
}

-- Screen anchors a saved frame position may use.
Config.ANCHORS = {
    CENTER = true, TOP = true, BOTTOM = true, LEFT = true, RIGHT = true,
    TOPLEFT = true, TOPRIGHT = true, BOTTOMLEFT = true, BOTTOMRIGHT = true,
}
Config.MAX_OFFSET = 4000 -- pixels from the anchor, either way

-- A saved frame position { point, x, y }, checked; a copy of default if unusable.
function Config.CleanPosition(position, default)
    if type(position) ~= "table" or not Config.ANCHORS[position.point] then
        return { point = default.point, x = default.x, y = default.y }
    end
    local limit = Config.MAX_OFFSET
    return {
        point = position.point,
        x = Util.ClampNumber(type(position.x) == "number" and math.floor(position.x + 0.5) or nil, -limit, limit, 0),
        y = Util.ClampNumber(type(position.y) == "number" and math.floor(position.y + 0.5) or nil, -limit, limit, 0),
    }
end

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

-- How each field of a message type's settings is checked: function(value,
-- default) -> the value to keep. Every field in Config.DEFAULTS must have one
-- (spec/config_spec.lua checks), so a new field can't slip in unchecked.
local function Bool(value, default)
    if type(value) == "boolean" then return value end
    return default
end
local function Limited(field)
    return function(value, default)
        local limits = Config.LIMITS[field]
        return Util.ClampNumber(value, limits.min, limits.max, default)
    end
end
Config.FIELD_VALIDATORS = {
    enabled = Bool,
    sayLine = Bool,
    autoOnJoin = Bool,
    autoOnDeath = Bool,
    autoOnBuffed = Bool,
    autoOffPull = Bool,
    autoOffDone = Bool,
    autoOffMinutes = Limited("autoOffMinutes"),
    bgPrepBuff = Bool,
    breathNearWater = Bool,
    unlocked = Bool,
    listBuffNames = Bool,
    quietInCities = Bool,
    receipts = Bool,
    showInCities = Bool,
    delay = Limited("delay"),
    repeatCooldown = Limited("repeatCooldown"),
    owedMinutes = Limited("owedMinutes"),
    thankStyle = function(value, default) return Config.THANK_STYLES[value] and value or default end,
    fallback = function(value, default) return Config.FALLBACKS[value] and value or default end,
    unknownName = function(value, default)
        if value == nil then return default end
        return Config.CleanUnknownName(value)
    end,
    position = function(value, default) return Config.CleanPosition(value, default) end,
    buffModeKey = function(value, default) return ns.BuffMode.IsValidKey(value) and value or default end,
    -- Known buff keys, each once; anything else is dropped. Not a list at
    -- all: the default (every class's own order).
    buffOrder = function(value, default)
        if type(value) ~= "table" then return CopyList(default) end
        local clean, seen = {}, {}
        for _, key in ipairs(value) do
            if type(key) == "string" and ns.BuffData.KEYS[key] and not seen[key] then
                seen[key] = true
                clean[#clean + 1] = key
            end
        end
        return clean
    end,
    neverOffer = function(value)
        local clean = {}
        if type(value) ~= "table" then return clean end
        for key, on in pairs(value) do
            if type(key) == "string" and ns.BuffData.KEYS[key] and on == true then clean[key] = true end
        end
        return clean
    end,
    whoGets = function(value) return ns.BuffRules.Clean(value) end,
    revokeMode = function(value, default) return ns.BuffRules.IS_REVOKE_MODE[value] and value or default end,
    revokeNames = function(value) return ns.BuffRules.CleanRevokeNames(value) end,
    messages = function(value, default)
        if type(value) ~= "table" then return CopyList(default) end
        local clean = {}
        for i = 1, Config.NUM_MESSAGES do clean[i] = Config.CleanMessage(value[i]) end
        return clean
    end,
}

-- A clean copy of one type's settings: exactly the fields its defaults have,
-- each through its validator. Unknown keys (a hand-edited file, a pasted
-- settings line) are dropped, so nothing else can grow the saved file.
local function ValidateType(saved, defaults)
    local src = type(saved) == "table" and saved or {}
    local cfg = {}
    for key, default in pairs(defaults) do
        local validate = Config.FIELD_VALIDATORS[key]
        if validate then
            cfg[key] = validate(src[key], default)
        else
            cfg[key] = Util.DeepCopy(default) -- unreachable while the spec holds
        end
    end
    return cfg
end

-- The guild login defaults before 0.5.0 (only the first 10 ever shipped).
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

-- Up to 0.8.0, a whisper was a switch beside "how to thank", and the /say
-- fallback another (#101). A whisper replaces the line (an emote alone had
-- no line to whisper), and the fallback switched off is "do nothing". Run on
-- every load, not by version: a settings line written by hand carries no
-- version, and is taken as current. It changes nothing in settings already
-- in the new form, which always have a fallback once loaded.
local function UpgradeThankFields(buff)
    if type(buff) ~= "table" then return end
    if buff.useWhisper == true and (buff.thankStyle == nil or buff.thankStyle == "message"
        or buff.thankStyle == "both") then
        buff.thankStyle = "whisper"
    end
    if buff.fallback == nil and buff.fallbackToSay == false then buff.fallback = "none" end
    -- An emote-only thank-you used to /thank a caster it couldn't name, never
    -- a line in /say: that stays so, rather than starting /say lines (the
    -- owner's decision on #101). Loading drops the old fields afterwards.
    if buff.fallback == nil and buff.thankStyle == "emote" then buff.fallback = "emote" end
end

-- Each entry upgrades a saved file from version (key - 1) to key.
local MIGRATIONS = {
    [6] = function(db)
        -- 0.8.0 replaced every type's default lines with fantasy ones. A saved
        -- line still exactly the old (casual) default becomes the new one in
        -- its slot; lines you edited stay. The casual set can be loaded again.
        for _, msgType in ipairs(Config.TYPES) do
            local cfg = db[msgType]
            if type(cfg) == "table" and type(cfg.messages) == "table" then
                local old, new = CasualMessages[msgType], DefaultMessages[msgType]
                for i = 1, old and Config.NUM_MESSAGES or 0 do
                    if cfg.messages[i] ~= nil and cfg.messages[i] == old[i] then cfg.messages[i] = new[i] end
                end
            end
        end
    end,
    [5] = function(db)
        -- Guild login lines were rewritten: a saved line still exactly the old
        -- default becomes the 0.5.0 one in its slot; lines you edited stay.
        -- 0.5.0's lines are the casual set, so migration 6 takes it from there.
        if type(db.guildLogin) == "table" and type(db.guildLogin.messages) == "table" then
            local msgs = db.guildLogin.messages
            for i, old in ipairs(OLD_GUILD_LOGIN) do
                if msgs[i] == old then msgs[i] = CasualMessages.guildLogin[i] end
            end
        end
        -- Up to 0.4.2 each type had 10 lines; now 30. Keep the saved 10 (edits
        -- included) and fill the new slots with the 0.5.0 default lines.
        for _, msgType in ipairs(Config.TYPES) do
            local defaults, cfg = CasualMessages[msgType], db[msgType]
            if defaults and type(cfg) == "table" and type(cfg.messages) == "table" then
                for i = 11, #defaults do
                    if cfg.messages[i] == nil then cfg.messages[i] = defaults[i] end
                end
            end
        end
    end,
    [4] = function(db)
        -- 0.4.0 shipped Party Hello with one 180s cooldown for every group,
        -- which skipped the hello for a second group. It is now per leader
        -- and only guards against a rapid rejoin.
        if type(db.partyHello) == "table" and db.partyHello.repeatCooldown == 180 then
            db.partyHello.repeatCooldown = 30
        end
    end,
    [3] = function(db)
        -- Up to 0.2.2 a blank unknown-caster name meant "don't thank them";
        -- that is now the fallbackToSay switch, and the name is just wording.
        if type(db.buff) == "table" and db.buff.unknownName == "" then
            db.buff.fallbackToSay = false
            db.buff.unknownName = nil
        end
    end,
    [2] = function(db)
        -- 0.0.0 had a buff-only "cooldown" (seconds); every type now has repeatCooldown.
        if type(db.buff) == "table" and db.buff.cooldown ~= nil then
            if db.buff.repeatCooldown == nil then db.buff.repeatCooldown = db.buff.cooldown end
            db.buff.cooldown = nil
        end
    end,
}

-- Bring settings saved by an older version up to date. Also used on profile
-- snapshots and pasted settings lines, which carry the version they came from.
function Config.Migrate(db)
    local version = Util.ClampNumber(db.schemaVersion, 1, Config.SCHEMA_VERSION, 1)
    for v = version + 1, Config.SCHEMA_VERSION do
        if MIGRATIONS[v] then MIGRATIONS[v](db) end
    end
    UpgradeThankFields(db.buff)
    db.schemaVersion = Config.SCHEMA_VERSION
end

-- The ignore list's key for a full name: names match whatever their case.
-- (Lua's lower() folds only A-Z: "élodie" and "Élodie" stay different.)
function Config.IgnoreKey(fullName)
    return fullName:lower()
end

-- The full name an ignore-list entry holds, or nil if it is damaged. Entries
-- are [key] = full name, the key being the name's IgnoreKey; [full name] = true
-- (how this list was first saved) is read too.
function Config.IgnoreEntry(key, value)
    if type(key) ~= "string" then return nil end
    if value == true then return Util.FullName(key) end
    local full = type(value) == "string" and Util.FullName(value)
    if full and Config.IgnoreKey(full) == key then return full end
end

-- When lines went to each chat type lately (ChatQueue's cap, #35): [group]
-- = list of { t = GetTime(), w = time() }. Only the newest the cap could
-- ever need are kept. A reading that isn't a usable time becomes now, as the
-- cap reads it, so damage can only hold lines back for a minute, never let
-- more through.
Config.MAX_CAP_GROUPS = 16
local function Reading(value, now)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return now end
    return value
end
function Config.CleanChatCap(saved)
    local clean, groups = {}, 0
    if type(saved) ~= "table" then return clean end
    for key, list in pairs(saved) do
        if groups >= Config.MAX_CAP_GROUPS then break end
        if type(key) == "string" and #key <= 32 and type(list) == "table" then
            local stamps = {}
            for _, e in ipairs(list) do
                local t, w
                if type(e) == "table" then t, w = e.t, e.w end
                stamps[#stamps + 1] = { t = Reading(t, GetTime()), w = Reading(w, time()) }
            end
            local keep = {}
            for i = math.max(1, #stamps - Config.LIMITS.linesPerMinute.max + 1), #stamps do
                keep[#keep + 1] = stamps[i]
            end
            clean[key] = keep
            groups = groups + 1
        end
    end
    return clean
end

-- Players never greeted or thanked: [lowercased full name] = the full name
-- as typed (shown in lists). Returns a checked copy of list. Keys are rebuilt
-- from the names, so a damaged key can't hide an entry.
function Config.ValidIgnore(list)
    local ignore = {}
    if type(list) == "table" then
        local n = 0
        for key, value in pairs(list) do
            local full = Config.IgnoreEntry(key, value)
            if full and n < Config.MAX_IGNORED and not ignore[Config.IgnoreKey(full)] then
                ignore[Config.IgnoreKey(full)] = full
                n = n + 1
            end
        end
    end
    return ignore
end

-- What db.walkthrough can be: not yet skipped or finished (a first
-- install), skipped, or finished.
Config.WALKTHROUGH_STATES = { new = true, skipped = true, done = true }

-- Everything in the saved file but the ledger (which checks itself as it's
-- used, and whose live entries a full check would change: see Ledger.Data).
local function ValidateSettings(db)
    if type(db.enabled) ~= "boolean" then db.enabled = true end
    if type(db.skipWhileAFK) ~= "boolean" then db.skipWhileAFK = Config.DEFAULTS.skipWhileAFK end
    local lines = Config.LIMITS.linesPerMinute
    db.linesPerMinute = Util.ClampNumber(db.linesPerMinute, lines.min, lines.max, Config.DEFAULTS.linesPerMinute)
    db.chatCap = Config.CleanChatCap(db.chatCap)

    if type(db.minimap) ~= "table" then db.minimap = {} end
    db.minimap.angle = Util.ClampNumber(db.minimap.angle, 0, 360, 220)
    if type(db.minimap.hide) ~= "boolean" then db.minimap.hide = false end

    -- Diagnostics: a debug flag and the most recent log lines (strings only).
    if type(db.debug) ~= "boolean" then db.debug = false end
    -- The walkthrough (#47): "new" until it's skipped or finished. Anything
    -- else (a file from before it, or a damaged one) counts as seen, so it
    -- never starts by itself for someone who already uses the addon.
    if not Config.WALKTHROUGH_STATES[db.walkthrough] then db.walkthrough = "done" end
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

    db.ignore = Config.ValidIgnore(db.ignore)

    ns.Profiles.Validate(db)

    -- Snooze: wall-clock time (time()) it ends, or nil.
    -- Never further off than the longest snooze (a damaged file, or a clock
    -- that was wrong when you snoozed, mustn't mute the addon for good).
    if type(db.snoozeUntil) ~= "number" or db.snoozeUntil ~= db.snoozeUntil then
        db.snoozeUntil = nil
    else
        db.snoozeUntil = math.min(db.snoozeUntil, time() + Config.SNOOZE_MAX_SECONDS)
    end
end

-- The saved file as loaded: migrated, every value checked. Returns it.
-- No saved file at all is a first install, which starts the walkthrough.
function Config.Load(saved)
    local db = type(saved) == "table" and saved or { walkthrough = "new" }
    Config.Migrate(db)
    ValidateSettings(db)
    db.ledger = ns.Ledger.Validate(db.ledger)
    return db
end

-- Check the live settings again: after an error (Diag.OnError), since damage
-- done mid-session (another addon, a bad /run) can cause one, so it heals at
-- once instead of at the next reload. At most once a second, so an error
-- repeating every frame doesn't re-check the whole file every frame.
local lastRepairAt
function Config.Repair()
    if type(ns.db) ~= "table" then return end
    local now = GetTime()
    if lastRepairAt and now - lastRepairAt < Config.REPAIR_INTERVAL_SECONDS then return end
    lastRepairAt = now
    ValidateSettings(ns.db)
end

-- Fresh copy of one type's defaults.
function Config.DefaultsFor(msgType)
    return ValidateType(nil, Config.DEFAULTS[msgType])
end
