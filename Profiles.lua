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
-- Each character's own settings (#508, the owner's decisions of 19 Nov 2026):
-- the buff settings in Config.CHARACTER_FIELDS (weapon buffs, buff mode's
-- key, self-buffs, the buff order and who gets each buff) are each
-- character's. A character on the Default profile uses its own; one on any
-- other profile, a shared profile, uses that profile's, as every setting did
-- before. At login a character goes back to Default unless it uses a shared
-- profile.
--
-- One record per character, db.characters["realm:First-Surname"] =
-- { settings = its own settings, profile = the profile it chose (nil or
-- Default: its own), welcomed = true once it has seen the walkthrough's step about
-- them }. A character with no record is new: nothing recorded characters
-- before 1.5.2, so at its first 1.5.2 login every character is (the
-- coordinator's call on #508, within the owner's decision). Its own
-- settings are then a copy of the Default profile's, from db.characterSeed
-- (saved by Config's migration 9, with weapon buffs reset there once for
-- everyone); with no seed (a new install), unset (Config.UnsetCharacter).
-- Its profile is the one 1.5.x remembered for it (db.charProfiles, by full
-- name, only read now). With none, and Default active, it starts on Default,
-- with its own. With none, and a shared profile active, it gets a profile of
-- its own (#519, the owner's decision of 24 Nov 2026, "B1"): named after the
-- character ("Ann", or "Ann 2" when that name is taken), a copy of the live
-- settings, and recorded as its choice. So it keeps what was live (buff back,
-- passers-by and the rest), never joins the shared profile, and Default and
-- every other profile are left as they were. At the cap of profiles
-- (Profiles.MAX) it keeps the active profile, and chat says why.
--
-- At login the live settings are the active profile's, and a stored copy is
-- put over them only when the character's record names another profile, or
-- names Default (its own) while a shared profile is active (#519). A record
-- naming a profile that is gone, while a shared profile is active, gets a
-- profile of its own the same way.
--
-- db.characterLive is the key of the character whose own settings are the
-- live ones (ns.db.buffBack), so they are kept as that character's when
-- another takes over; false when the live ones are a shared profile's, or
-- nobody's (or missing: the same).
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
Profiles.MAX_KEY = 120 -- a character's key: a realm, ":" and a full name

local Copy = Util.DeepCopy

-- This character's key, "realm:First-Surname", or nil while either part
-- can't be read (a secret reads as nil, never compared or indexed).
local function MyKey()
    local me = Util.UnitFullName("player")
    local realm = Util.ReadGameValues(GetRealmName)
    if not me or type(realm) ~= "string" or realm == "" then return nil end
    local key = realm .. ":" .. me
    if #key > Profiles.MAX_KEY then return nil end
    return key
end

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
        or type(undo.profile) ~= "string" or type(undo.ignoreAdded) ~= "table"
        or (undo.who ~= nil and type(undo.who) ~= "string")) then
        return false
    end
    return true
end

-- Whether the character data has the shape the code below relies on. A
-- record's fields need no check here: its settings are checked as they are
-- put in place, and its profile is only compared; nor does characterLive,
-- which the code only compares, or reads as a key.
local function CharactersHealthy(db)
    if type(db.characters) ~= "table" then return false end
    for key, record in pairs(db.characters) do
        -- A key that isn't a string can't be read as one (#519's
        -- SharedWithOthers reads each key's name): repaired with the rest.
        if type(key) ~= "string" or type(record) ~= "table" then return false end
    end
    local seed = db.characterSeed
    return seed == nil or (type(seed) == "table" and type(seed.settings) == "table")
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
    -- who: the character it was made on (#508): its undo would hand another
    -- character the settings this one had, its own ones included.
    ns.db.importUndo = { profile = ns.db.activeProfile, settings = before, ignoreAdded = ignoreAdded, who = MyKey() }
    return true
end

-- Undo is for the profile the import went into, until you switch profiles,
-- and for the character that made it (#508; one saved before 1.5.2 names
-- none, from when every setting was shared).
function Profiles.CanUndoImport()
    Check()
    local undo = ns.db.importUndo
    return undo ~= nil and undo.profile == ns.db.activeProfile and (undo.who == nil or undo.who == MyKey())
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
    db.charProfiles = chars -- 1.5.x's, only read now (#508)
    Profiles.ValidateCharacters(db)
    local undo = db.importUndo
    if type(undo) ~= "table" or type(undo.settings) ~= "table" or type(undo.profile) ~= "string"
        or (undo.who ~= nil and type(undo.who) ~= "string") then
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

-- Whether key could be a character's key: "realm:name", not too long.
local function IsKey(key)
    return type(key) == "string" and #key <= Profiles.MAX_KEY and key:find("^[^:]+:[^:]+$") ~= nil
end

-- The character data, checked on load (#508). Over the cap, the character
-- whose settings are live is kept first, then keys in sorted order: one
-- dropped is new again at its next login. A damaged characterLive is false:
-- the live settings are kept as nobody's. A damaged seed is dropped: new
-- characters then start unset.
function Profiles.ValidateCharacters(db)
    local live = IsKey(db.characterLive) and db.characterLive or false
    db.characterLive = live
    local kept, n = {}, 0
    local function Keep(key, record)
        if n < ns.Config.MAX_CHARACTERS and not kept[key] and type(record) == "table" then
            kept[key] = { settings = ns.Config.ValidCharacter(record.settings),
                profile = Profiles.CleanName(record.profile) or nil, welcomed = record.welcomed == true or nil }
            n = n + 1
        end
    end
    if type(db.characters) == "table" then
        if live then Keep(live, db.characters[live]) end
        local keys = {}
        for key in pairs(db.characters) do
            if IsKey(key) then keys[#keys + 1] = key end
        end
        table.sort(keys)
        for _, key in ipairs(keys) do Keep(key, db.characters[key]) end
    end
    db.characters = kept
    local seed = db.characterSeed
    if type(seed) == "table" and type(seed.settings) == "table" then
        db.characterSeed = { settings = ns.Config.ValidCharacter(seed.settings) }
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

-- A new character's own settings (see the top): never the live ones, which
-- may be another character's.
local function FirstSettings()
    if ns.db.characterSeed then
        return ns.db.characterSeed.settings, "copied Default's, weapon buffs unset"
    end
    return ns.Config.UnsetCharacter(), "unset"
end

-- This character's record, made the first time (it is then new: the second
-- answer is true).
local function Record(key)
    local db = ns.db
    local record = db.characters[key]
    if record then return record, false end
    local settings, how = FirstSettings()
    local me = Util.UnitFullName("player")
    record = { settings = ns.Config.ValidCharacter(settings), profile = me and db.charProfiles[me] or nil }
    db.characters[key] = record
    ns.Diag.Log("profiles", "%s is new here: its own buff settings %s", key, how)
    return record, true
end

-- Keep the live settings as the character's own, when they are.
local function StashOwn()
    local key = ns.db.characterLive
    if type(key) == "string" then
        local record = ns.db.characters[key]
        if type(record) ~= "table" then
            record = {}
            ns.db.characters[key] = record
        end
        record.settings = ns.Config.CharacterPart(ns.Config.Section("buffBack"))
    end
end

-- Put this character's own settings in place of the live ones (it is on
-- Default).
local function LoadOwn(key)
    StashOwn()
    local record = Record(key)
    local checked = ns.Config.ValidCharacter(record.settings)
    local section = ns.Config.Section("buffBack")
    for _, field in ipairs(ns.Config.CHARACTER_FIELDS) do section[field] = checked[field] end
    record.settings = ns.Config.CharacterPart(section)
    ns.db.characterLive = key
    ns.BuffButton.Refresh() -- buff mode lends this character's key
end

-- While this character's key can't be read, its own settings can't be found:
-- the live ones are kept as nobody's, and its weapon and food buffs are off
-- (#544), so no other character's are offered.
local function Unreadable()
    StashOwn()
    ns.db.characterLive = false
    local section = ns.Config.Section("buffBack")
    for _, fields in ipairs({ ns.Config.WEAPON_FIELDS, ns.FoodBuffs.FIELDS }) do
        for _, field in ipairs(fields) do
            section[field] = Util.DeepCopy(ns.Config.DEFAULTS.buffBack[field])
        end
    end
    ns.Diag.Log("profiles", "your name or realm can't be read yet; weapon and food buffs are off until you log "
        .. "in or /reload with it readable")
    ns.BuffButton.Refresh()
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
    local key = MyKey()
    if key then Record(key).profile = name end
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
        local key = MyKey()
        if key then LoadOwn(key) else Unreadable() end
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
    for _, record in pairs(ns.db.characters) do
        if record.profile == name then record.profile = nil end
    end
    for who, p in pairs(ns.db.charProfiles) do
        if p == name then ns.db.charProfiles[who] = nil end
    end
    return name
end

-- A free name for this character's own profile (#519): its first name, or
-- that with " 2", " 3"... when taken; nil when none is free or it can't be read.
local function OwnName()
    local me = Util.UnitFullName("player")
    local base = me and Profiles.CleanName(Util.FirstName(me))
    if not base then return nil end
    for i = 1, Profiles.MAX + 1 do
        local name = i == 1 and base or (base .. " " .. i)
        if Profiles.CleanName(name) == name and name ~= Profiles.DEFAULT and name ~= ns.db.activeProfile
            and not ns.db.profiles[name] then
            return name
        end
    end
end

-- A profile of this character's own, a copy of the live settings, recorded
-- as its choice and made the active one (#519, see the top). Nothing stored
-- is changed or applied. At the cap, it keeps the active profile, and says so.
local function OwnProfile(key, record)
    local db = ns.db
    local kept = db.activeProfile
    local name = Count() < Profiles.MAX and OwnName() or nil
    db.characterLive = false -- the live settings are the active profile's, then this one's
    if not name then
        record.profile = kept
        ns.Diag.Log("profiles", "%s keeps %s: no profile of its own could be made", key, kept)
        ns.Print(("this character uses the profile %s, shared with your other characters: you have the most "
            .. "profiles allowed (%d), so it couldn't have one of its own. Delete one, then /friendly profile new "
            .. "<name>."):format(kept, Profiles.MAX))
        return
    end
    db.profiles[name] = Profiles.Snapshot(db)
    db.activeProfile = name
    db.importUndo = nil -- it was for the profile that was active
    record.profile = name
    ns.Diag.Log("profiles", "%s gets its own profile %s, a copy of %s's live settings", key, name, kept)
end

-- At login (and after a reload): a character on a shared profile switches to
-- it, if it still exists; one whose record names Default goes back to it,
-- with its own settings (#508). A new character gets its record first, and,
-- while a shared profile is active, a profile of its own (see the top, #519).
-- A record naming a profile that is gone does too. Nothing stored is put over
-- the live settings unless a record says to.
function Profiles.OnLogin()
    Check()
    local db = ns.db
    local key = MyKey()
    if not key then
        -- Default, where nothing is anyone's: a shared profile's settings
        -- are saved first, never changed for the others on it.
        if db.activeProfile ~= Profiles.DEFAULT then return Profiles.Use(Profiles.DEFAULT) end
        return Unreadable()
    end
    local record, new = Record(key)
    local want = record.profile
    if new and want == nil and db.activeProfile ~= Profiles.DEFAULT then return OwnProfile(key, record) end
    local shared = want ~= nil and want ~= Profiles.DEFAULT
    if shared and want ~= db.activeProfile and db.profiles[want] then
        Profiles.Use(want)
        ns.Diag.Log("profiles", "switched to %s, the profile %s chose", want, key)
        -- The live settings are the active profile's, whatever a damaged
        -- file says: never keep them as a character's own.
        db.characterLive = false
        return
    end
    if shared and db.activeProfile ~= Profiles.DEFAULT then
        -- Its own choice: the live settings stay as they are, stored copy or
        -- not. One that is gone: a profile of its own, from them (#519).
        if want ~= db.activeProfile then
            ns.Diag.Log("profiles", "%s chose %s, which is gone", key, want)
            return OwnProfile(key, record)
        end
        db.characterLive = false
        return
    end
    if db.activeProfile ~= Profiles.DEFAULT then
        Profiles.Use(Profiles.DEFAULT)
        ns.Diag.Log("profiles", "switched to %s for %s, who uses no shared profile", Profiles.DEFAULT, key)
    else
        LoadOwn(key)
    end
end

-- The shared profile in use, or nil on Default, where each character uses
-- its own settings.
function Profiles.SharedProfile()
    Check()
    if ns.db.activeProfile ~= Profiles.DEFAULT then return ns.db.activeProfile end
    return nil
end

-- Whether another character uses the profile in use (#519): its record, or
-- its 1.5.x choice not yet recorded, names it. false on Default, and for a
-- profile of a character's own that no other has chosen. The walkthrough calls
-- a profile shared only then.
function Profiles.SharedWithOthers()
    Check()
    local active = ns.db.activeProfile
    if active == Profiles.DEFAULT then return false end
    local key = MyKey()
    local recorded = {} -- full names with a record: their record is their choice now
    for other, record in pairs(ns.db.characters) do
        if other ~= key and record.profile == active then return true end
        local name = other:match(":(.+)$") -- a string: Check() repairs any other key
        if name then recorded[name] = true end
    end
    local me = Util.UnitFullName("player")
    for who, name in pairs(ns.db.charProfiles) do
        if who ~= me and not recorded[who] and name == active then return true end
    end
    return false
end

-- The walkthrough's step about each character's own settings (#508): whether
-- this character hasn't seen it yet, and marking that it has. Shown once per
-- character.
function Profiles.NeedsWelcome()
    Check()
    local key = MyKey()
    local record = key and ns.db.characters[key]
    return record ~= nil and record.welcomed ~= true
end

function Profiles.Welcomed()
    Check()
    local key = MyKey()
    local record = key and ns.db.characters[key]
    if record then record.welcomed = true end
end
