-- Profiles, and settings export/import.
--
-- The settings a profile or an exported line carries are the "portable" ones:
-- each message type's switch, timings, options and lines, and Skip while AFK.
-- Never carried: the addon's on/off switch, the minimap button, debug, the
-- ledger, snooze and the message rotation. The ignore list travels in an
-- export (merged into yours on import, never shrinking it) but not in a
-- profile, since it is about people, not about how you talk.
--
-- A profile holds those settings under a name. Each character remembers the
-- profile it last used and switches to it at login. Changes are saved into
-- the active profile when you switch and when you log out.
--
-- Each character's own settings (#508, the owner's decision of 19 Nov 2026):
-- the buff settings in Config.CHARACTER_FIELDS (weapon buffs, buff mode's
-- key, self-buffs, the buff order and who gets each buff) are each
-- character's, kept in db.characters[full name]. A character on the Default
-- profile uses its own; one on any other profile, a shared profile, uses
-- that profile's, as every setting did before. At login a character goes
-- back to Default unless it uses a shared profile. db.characterLive names
-- the character whose own settings are the live ones (ns.db.buffBack), so
-- they are kept as that character's when another takes over; false when
-- the live ones are a shared profile's, or nobody's yet; nil only before the
-- first login since #508. A character's first login since then (none in
-- db.characters yet) copies the account's settings, once, from
-- db.characterSeed (saved by Config's migration 9, with the profile the
-- account was on); a character made since starts unset (Config.UnsetCharacter).
--
-- Snapshots and exported lines carry the settings version they were made
-- with, and are brought up to date (Config.Migrate) before they are used.
local _, ns = ...
local Util = ns.Util

local Profiles = {}
ns.Profiles = Profiles

Profiles.DEFAULT = "Default"
Profiles.MAX = 20
Profiles.MAX_NAME = 32

local Copy = Util.DeepCopy

-- Settings about this screen, not about how you talk: an export leaves them
-- out, and applying a profile or an import keeps yours.
Profiles.LOCAL_ONLY = { buffBack = { "position", "unlocked" } }

-- The portable settings of db, as a plain table.
function Profiles.Snapshot(db, withIgnore)
    local out = { schemaVersion = ns.Config.SCHEMA_VERSION, skipWhileAFK = db.skipWhileAFK,
        linesPerMinute = db.linesPerMinute }
    for _, msgType in ipairs(ns.Config.TYPES) do out[msgType] = Copy(db[msgType]) end
    if withIgnore then out.ignore = Copy(db.ignore) end
    return out
end

-- Ignored names in a snapshot's list that aren't on yours, up to the cap:
-- yours always stay. Returns the names added (their list keys).
local function MergeIgnore(list)
    local added = {}
    if type(list) ~= "table" then return added end
    local mine = ns.Ignore.Data()
    local n = 0
    for _ in pairs(mine) do n = n + 1 end
    for key, value in pairs(list) do
        local full = ns.Config.IgnoreEntry(key, value)
        local k = full and ns.Config.IgnoreKey(full)
        if k and not mine[k] and n < ns.Config.MAX_IGNORED then
            mine[k] = full
            added[#added + 1] = k
            n = n + 1
        end
    end
    return added
end

-- Put a snapshot's message settings, Skip while AFK and the chat cap into ns.db: brought
-- up to date, then checked by Config.Load, like the saved file.
local function Apply(snapshot)
    local snap = Copy(snapshot)
    ns.Config.Migrate(snap)
    local candidate = Copy(ns.db)
    for _, msgType in ipairs(ns.Config.TYPES) do
        if snap[msgType] ~= nil then candidate[msgType] = snap[msgType] end
    end
    if snap.skipWhileAFK ~= nil then candidate.skipWhileAFK = snap.skipWhileAFK end
    if snap.linesPerMinute ~= nil then candidate.linesPerMinute = snap.linesPerMinute end
    for msgType, keys in pairs(Profiles.LOCAL_ONLY) do
        if type(candidate[msgType]) == "table" then
            -- Your own section may be lost mid-session: then its defaults (#387).
            local live = ns.db[msgType]
            for _, key in ipairs(keys) do
                candidate[msgType][key] = type(live) == "table" and Copy(live[key]) or nil
            end
        end
    end
    candidate = ns.Config.Load(candidate)
    for _, msgType in ipairs(ns.Config.TYPES) do ns.db[msgType] = candidate[msgType] end
    ns.db.skipWhileAFK = candidate.skipWhileAFK
    ns.db.linesPerMinute = candidate.linesPerMinute
    ns.RefreshEvents()
    ns.BuffButton.Refresh()
end

-- Whether the profile data has the shape the code below relies on. Checked
-- at the start of every public function (a few type checks, and one per
-- profile), so data damaged mid-session (by another addon or a bad /run) is
-- repaired before it can raise an error, as the ledger does.
local function Healthy(db)
    if type(db.activeProfile) ~= "string" or Profiles.CleanName(db.activeProfile) ~= db.activeProfile then
        return false
    end
    if type(db.profiles) ~= "table" or type(db.charProfiles) ~= "table" then return false end
    for name, snapshot in pairs(db.profiles) do
        if type(name) ~= "string" or type(snapshot) ~= "table" then return false end
    end
    local undo = db.importUndo
    if undo ~= nil and (type(undo) ~= "table" or type(undo.settings) ~= "table"
        or type(undo.profile) ~= "string" or type(undo.ignoreAdded) ~= "table") then
        return false
    end
    return true
end

-- Whether the character data has the shape the code below relies on (each
-- entry's fields are checked as they are put in place). characterLive needs
-- no check here: the code reads it only as a name it compares or a string.
local function CharactersHealthy(db)
    if type(db.characters) ~= "table" then return false end
    for who, settings in pairs(db.characters) do
        if type(who) ~= "string" or type(settings) ~= "table" then return false end
    end
    local seed = db.characterSeed
    if seed ~= nil and (type(seed) ~= "table" or type(seed.settings) ~= "table"
        or type(seed.profile) ~= "string") then
        return false
    end
    return true
end

local function Check()
    if not Healthy(ns.db) or not CharactersHealthy(ns.db) then
        ns.Diag.Log("profiles", "the profile data was damaged; repaired")
        Profiles.Validate(ns.db)
    end
end

------------------------------------------------------------------------
-- Export / import
------------------------------------------------------------------------

-- The settings line, or nil and why not: never a line import would refuse.
function Profiles.Export()
    local settings = Profiles.Snapshot(ns.db, true)
    for msgType, keys in pairs(Profiles.LOCAL_ONLY) do
        local section = settings[msgType] -- not a table if lost mid-session (#387)
        if type(section) == "table" then
            for _, key in ipairs(keys) do section[key] = nil end
        end
    end
    local text, why = ns.Serialize.Encode({ v = 1, settings = settings })
    if text and #text > ns.Serialize.MAX_BYTES then
        return nil, "your settings are too long to share as one line (mostly symbols such as % and ;)"
    end
    return text, why
end

-- Returns true, or nil and why not. The settings you had are kept for undo,
-- along with the profile they belong to and the ignored names it added.
function Profiles.Import(text)
    local data, why = ns.Serialize.Decode(text)
    if not data then return nil, why end
    if type(data) ~= "table" or data.v ~= 1 or type(data.settings) ~= "table" then
        return nil, "that line is from a version of Friendly Forever this one can't read"
    end
    Check()
    local before = Profiles.Snapshot(ns.db)
    -- A line without a version was written by hand or before versions were
    -- stored: take it as current rather than running every old migration.
    if data.settings.schemaVersion == nil then data.settings.schemaVersion = ns.Config.SCHEMA_VERSION end
    -- Merge the ignore list first: Apply re-arms the buff-back button, which
    -- must already know who the line ignores (#369).
    local ignoreAdded = MergeIgnore(data.settings.ignore)
    Apply(data.settings)
    ns.db.importUndo = { profile = ns.db.activeProfile, settings = before, ignoreAdded = ignoreAdded }
    return true
end

-- Undo is for the profile the import went into, until you switch profiles.
function Profiles.CanUndoImport()
    Check()
    local undo = ns.db.importUndo
    return undo ~= nil and undo.profile == ns.db.activeProfile
end

function Profiles.UndoImport()
    if not Profiles.CanUndoImport() then return nil, "there's no import to undo" end
    local undo = ns.db.importUndo
    Apply(undo.settings)
    -- Only the names the import added come off; ones you added since stay.
    local mine = ns.Ignore.Data()
    for _, key in ipairs(undo.ignoreAdded) do mine[key] = nil end
    ns.db.importUndo = nil
    return true
end

------------------------------------------------------------------------
-- Profiles
------------------------------------------------------------------------

-- A profile name as typed, cleaned, or nil and why not.
function Profiles.CleanName(name)
    if type(name) ~= "string" then return nil, "type a profile name" end
    name = Util.StripChat(name)
    if name == "" then return nil, "type a profile name" end
    if #name > Profiles.MAX_NAME then return nil, "profile names are at most " .. Profiles.MAX_NAME .. " letters" end
    return name
end

-- Saved data, checked on load (Config.Load calls this). Over the cap, the
-- active profile is kept first, then names in sorted order.
function Profiles.Validate(db)
    local active = Profiles.CleanName(db.activeProfile)
    db.activeProfile = active or Profiles.DEFAULT
    local profiles, n = {}, 0
    local function Keep(name, snapshot)
        if n < Profiles.MAX and not profiles[name] and type(snapshot) == "table"
            and Profiles.CleanName(name) == name then
            profiles[name] = snapshot
            n = n + 1
        end
    end
    if type(db.profiles) == "table" then
        Keep(db.activeProfile, db.profiles[db.activeProfile])
        local names = {}
        for name in pairs(db.profiles) do
            if type(name) == "string" then names[#names + 1] = name end
        end
        table.sort(names)
        for _, name in ipairs(names) do Keep(name, db.profiles[name]) end
    end
    db.profiles = profiles
    local chars = {}
    if type(db.charProfiles) == "table" then
        for who, name in pairs(db.charProfiles) do
            if Util.FullName(who) == who and Profiles.CleanName(name) == name then chars[who] = name end
        end
    end
    db.charProfiles = chars
    Profiles.ValidateCharacters(db)
    local undo = db.importUndo
    if type(undo) ~= "table" or type(undo.settings) ~= "table" or type(undo.profile) ~= "string" then
        db.importUndo = nil
    else
        local added = {}
        if type(undo.ignoreAdded) == "table" then
            for _, key in ipairs(undo.ignoreAdded) do
                if type(key) == "string" then added[#added + 1] = key end
            end
        end
        undo.ignoreAdded = added
    end
end

-- The character data, checked on load (#508). Over the cap, the character
-- whose settings are live is kept first, then names in sorted order. A
-- damaged characterLive is false: the live settings are kept as nobody's,
-- and each character's own are read again from db.characters. A damaged
-- seed is dropped: characters not seen since #508 then start unset.
function Profiles.ValidateCharacters(db)
    local live = db.characterLive
    if live ~= nil and live ~= false and (type(live) ~= "string" or Util.FullName(live) ~= live) then
        live = false
    end
    db.characterLive = live
    local kept, n = {}, 0
    local function Keep(who, settings)
        if n < ns.Config.MAX_CHARACTERS and not kept[who] and type(settings) == "table" then
            kept[who] = ns.Config.ValidCharacter(settings)
            n = n + 1
        end
    end
    if type(db.characters) == "table" then
        if type(live) == "string" then Keep(live, db.characters[live]) end
        local names = {}
        for who in pairs(db.characters) do
            if type(who) == "string" and Util.FullName(who) == who then names[#names + 1] = who end
        end
        table.sort(names)
        for _, who in ipairs(names) do Keep(who, db.characters[who]) end
    end
    db.characters = kept
    local seed = db.characterSeed
    if type(seed) == "table" and type(seed.settings) == "table" then
        db.characterSeed = { settings = ns.Config.ValidCharacter(seed.settings),
            profile = Profiles.CleanName(seed.profile) or Profiles.DEFAULT }
    else
        db.characterSeed = nil
    end
end

function Profiles.Active()
    Check()
    return ns.db.activeProfile
end

-- Profile names, sorted, with the active one included even before it is saved.
function Profiles.List()
    Check()
    local seen, out = {}, {}
    for name in pairs(ns.db.profiles) do seen[name] = true end
    seen[ns.db.activeProfile] = true
    for name in pairs(seen) do out[#out + 1] = name end
    table.sort(out)
    return out
end

local function Count()
    local n = 0
    for _ in pairs(ns.db.profiles) do n = n + 1 end
    return n
end

------------------------------------------------------------------------
-- Each character's own settings (#508)
------------------------------------------------------------------------

local function Me()
    return Util.UnitFullName("player")
end

-- Whether the character was just made: level 1 with no experience. The game
-- has no "first login ever" (#508's research), and a new character is level
-- 1 with none at its first login. Anything unread counts as played before:
-- it then gets the copy, which is what it had before #508.
local function IsNewCharacter()
    local level = Util.ReadGameValues(UnitLevel, "player")
    local xp = Util.ReadGameValues(UnitXP, "player")
    return level == 1 and xp == 0
end

-- Keep the live settings as the character's own, when they are.
local function StashOwn()
    local who = ns.db.characterLive
    if type(who) == "string" then
        ns.db.characters[who] = ns.Config.CharacterPart(ns.Config.Section("buffBack"))
    end
end

-- Put this character's own settings in place of the live ones (it is on
-- Default). The first time, they are the copy or unset (see the top).
local function LoadOwn(me)
    local db = ns.db
    StashOwn()
    local settings, how = db.characters[me], nil
    if settings == nil then
        local isNew = IsNewCharacter()
        if db.characterLive == nil and not (isNew and db.characterSeed) then
            -- The first character since #508: the live settings are the
            -- account's (a new install's are unset), so it keeps them.
            settings, how = ns.Config.CharacterPart(ns.Config.Section("buffBack")), "kept the account's"
        elseif isNew or not db.characterSeed then
            settings, how = ns.Config.UnsetCharacter(), "a new character, unset"
        else
            settings, how = db.characterSeed.settings, "copied the account's"
        end
    end
    local checked = ns.Config.ValidCharacter(settings)
    local section = ns.Config.Section("buffBack")
    for _, field in ipairs(ns.Config.CHARACTER_FIELDS) do section[field] = checked[field] end
    db.characters[me] = ns.Config.CharacterPart(section)
    db.characterLive = me
    if how then ns.Diag.Log("profiles", "%s's first login since its own buff settings: %s", me, how) end
    ns.BuffButton.Refresh() -- buff mode lends this character's key
end

-- Keep the active profile's stored copy current, and the character's own
-- settings. No profile is stored until profiles are in use (some profile
-- has been made).
function Profiles.SaveActive()
    Check()
    StashOwn()
    if next(ns.db.profiles) == nil then return end
    ns.db.profiles[ns.db.activeProfile] = Profiles.Snapshot(ns.db)
end

local function RememberForCharacter(name)
    local me = Util.UnitFullName("player")
    if me then ns.db.charProfiles[me] = name end
end

-- A new profile with your current settings, which becomes the active one.
function Profiles.New(input)
    local name, why = Profiles.CleanName(input)
    if not name then return nil, why end
    Check()
    if ns.db.profiles[name] or name == ns.db.activeProfile then
        return nil, "there's already a profile called " .. name
    end
    -- The active profile is stored too, the first time.
    local after = Count() + 1 + (ns.db.profiles[ns.db.activeProfile] and 0 or 1)
    if after > Profiles.MAX then return nil, "you have the most profiles allowed (" .. Profiles.MAX .. ")" end
    StashOwn()
    ns.db.profiles[ns.db.activeProfile] = Profiles.Snapshot(ns.db)
    ns.db.profiles[name] = Profiles.Snapshot(ns.db)
    ns.db.characterLive = false -- the live settings are now the new profile's
    ns.db.activeProfile = name
    ns.db.importUndo = nil
    RememberForCharacter(name)
    return name
end

-- Switch to a saved profile: your current settings are saved into the
-- active one first. Default is always there to go back to: it holds each
-- character's own settings, and if it isn't stored the others stay as they are.
function Profiles.Use(input)
    local name, why = Profiles.CleanName(input)
    if not name then return nil, why end
    Check()
    if name == ns.db.activeProfile then
        RememberForCharacter(name)
        return name
    end
    local target = ns.db.profiles[name]
    if not target and name ~= Profiles.DEFAULT then return nil, "there's no profile called " .. name end
    Profiles.SaveActive()
    ns.db.characterLive = false -- the live settings are about to be the target's
    if target then Apply(target) end
    ns.db.activeProfile = name
    ns.db.importUndo = nil
    RememberForCharacter(name)
    if name == Profiles.DEFAULT then
        local me = Me()
        if me then LoadOwn(me) end
    end
    return name
end

function Profiles.Delete(input)
    local name, why = Profiles.CleanName(input)
    if not name then return nil, why end
    Check()
    if name == ns.db.activeProfile then return nil, "you can't delete the profile you're using" end
    if not ns.db.profiles[name] then return nil, "there's no profile called " .. name end
    ns.db.profiles[name] = nil
    for who, p in pairs(ns.db.charProfiles) do
        if p == name then ns.db.charProfiles[who] = nil end
    end
    return name
end

-- At login (and after a reload): a character on a shared profile switches to
-- it, if it still exists; any other goes back to Default, with its own
-- settings (#508). A character seen for the first time since #508 that
-- played before keeps the profile the account was on.
function Profiles.OnLogin()
    Check()
    local db = ns.db
    local me = Me()
    if not me then
        ns.Diag.Log("profiles", "your name can't be read yet; the settings stay as they are")
        return
    end
    if db.characters[me] == nil and db.charProfiles[me] == nil and db.characterSeed and not IsNewCharacter() then
        db.charProfiles[me] = db.characterSeed.profile
    end
    local want = db.charProfiles[me]
    if want and want ~= Profiles.DEFAULT and db.profiles[want] then
        if want ~= db.activeProfile then
            Profiles.Use(want)
            ns.Diag.Log("profiles", "switched to %s, the profile %s used last", want, me)
        end
        -- The live settings are the active profile's, whatever a damaged
        -- file says: never keep them as a character's own.
        db.characterLive = false
        return
    end
    if db.activeProfile ~= Profiles.DEFAULT then
        Profiles.Use(Profiles.DEFAULT)
        ns.Diag.Log("profiles", "switched to %s for %s, who uses no shared profile", Profiles.DEFAULT, me)
    end
    LoadOwn(me)
end
