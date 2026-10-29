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
    local out = { schemaVersion = ns.Config.SCHEMA_VERSION, skipWhileAFK = db.skipWhileAFK }
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

-- Put a snapshot's message settings and Skip while AFK into ns.db: brought
-- up to date, then checked by Config.Load, like the saved file.
local function Apply(snapshot)
    local snap = Copy(snapshot)
    ns.Config.Migrate(snap)
    local candidate = Copy(ns.db)
    for _, msgType in ipairs(ns.Config.TYPES) do
        if snap[msgType] ~= nil then candidate[msgType] = snap[msgType] end
    end
    if snap.skipWhileAFK ~= nil then candidate.skipWhileAFK = snap.skipWhileAFK end
    for msgType, keys in pairs(Profiles.LOCAL_ONLY) do
        if type(candidate[msgType]) == "table" then
            for _, key in ipairs(keys) do candidate[msgType][key] = Copy(ns.db[msgType][key]) end
        end
    end
    candidate = ns.Config.Load(candidate)
    for _, msgType in ipairs(ns.Config.TYPES) do ns.db[msgType] = candidate[msgType] end
    ns.db.skipWhileAFK = candidate.skipWhileAFK
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

local function Check()
    if not Healthy(ns.db) then
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
        for _, key in ipairs(keys) do settings[msgType][key] = nil end
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
    Apply(data.settings)
    ns.db.importUndo = {
        profile = ns.db.activeProfile, settings = before, ignoreAdded = MergeIgnore(data.settings.ignore),
    }
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

-- Keep the active profile's stored copy current. Nothing is stored until
-- profiles are in use (some profile has been made).
function Profiles.SaveActive()
    Check()
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
    ns.db.profiles[ns.db.activeProfile] = Profiles.Snapshot(ns.db)
    ns.db.profiles[name] = Profiles.Snapshot(ns.db)
    ns.db.activeProfile = name
    ns.db.importUndo = nil
    RememberForCharacter(name)
    return name
end

-- Switch to a saved profile: your current settings are saved into the
-- active one first.
function Profiles.Use(input)
    local name, why = Profiles.CleanName(input)
    if not name then return nil, why end
    Check()
    if name == ns.db.activeProfile then
        RememberForCharacter(name)
        return name
    end
    local target = ns.db.profiles[name]
    if not target then return nil, "there's no profile called " .. name end
    Profiles.SaveActive()
    Apply(target)
    ns.db.activeProfile = name
    ns.db.importUndo = nil
    RememberForCharacter(name)
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

-- At login: switch to the profile this character used last, if it still exists.
function Profiles.OnLogin()
    Check()
    local me = Util.UnitFullName("player")
    local want = me and ns.db.charProfiles[me]
    if want and want ~= ns.db.activeProfile and ns.db.profiles[want] then
        Profiles.Use(want)
        ns.Diag.Log("profiles", "switched to %s, the profile %s used last", want, me)
    end
end
