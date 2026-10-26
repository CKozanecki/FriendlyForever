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
local _, ns = ...
local Util = ns.Util

local Profiles = {}
ns.Profiles = Profiles

Profiles.DEFAULT = "Default"
Profiles.MAX = 20
Profiles.MAX_NAME = 32

local function Copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = Copy(v) end
    return out
end

-- The portable settings of db, as a plain table.
function Profiles.Snapshot(db, withIgnore)
    local out = { skipWhileAFK = db.skipWhileAFK }
    for _, msgType in ipairs(ns.Config.TYPES) do out[msgType] = Copy(db[msgType]) end
    if withIgnore then out.ignore = Copy(db.ignore) end
    return out
end

-- Put a snapshot's settings into ns.db, checked by Config.Load first.
-- ignoreMode: nil leaves your ignore list alone, "merge" adds its names,
-- "replace" makes it exactly the snapshot's.
local function Apply(snapshot, ignoreMode)
    local candidate = Copy(ns.db)
    for _, msgType in ipairs(ns.Config.TYPES) do
        if snapshot[msgType] ~= nil then candidate[msgType] = Copy(snapshot[msgType]) end
    end
    if snapshot.skipWhileAFK ~= nil then candidate.skipWhileAFK = snapshot.skipWhileAFK end
    if ignoreMode == "replace" then
        candidate.ignore = Copy(snapshot.ignore) or {}
    elseif ignoreMode == "merge" and type(snapshot.ignore) == "table" then
        for name, on in pairs(snapshot.ignore) do candidate.ignore[name] = on end
    end
    candidate = ns.Config.Load(candidate)
    for _, msgType in ipairs(ns.Config.TYPES) do ns.db[msgType] = candidate[msgType] end
    ns.db.skipWhileAFK = candidate.skipWhileAFK
    ns.db.ignore = candidate.ignore
    ns.RefreshEvents()
end

------------------------------------------------------------------------
-- Export / import
------------------------------------------------------------------------

function Profiles.Export()
    return ns.Serialize.Encode({ v = 1, settings = Profiles.Snapshot(ns.db, true) })
end

-- Returns true, or nil and why not. The settings you had are kept for undo.
function Profiles.Import(text)
    local data, why = ns.Serialize.Decode(text)
    if not data then return nil, why end
    if type(data) ~= "table" or data.v ~= 1 or type(data.settings) ~= "table" then
        return nil, "that line is from a version of Friendly Forever this one can't read"
    end
    ns.db.importUndo = Profiles.Snapshot(ns.db, true)
    Apply(data.settings, "merge")
    return true
end

function Profiles.CanUndoImport()
    return type(ns.db.importUndo) == "table"
end

function Profiles.UndoImport()
    if not Profiles.CanUndoImport() then return nil, "there's no import to undo" end
    Apply(ns.db.importUndo, "replace")
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

-- Saved data, checked on load (Config.Load calls this).
function Profiles.Validate(db)
    local profiles = {}
    local n = 0
    if type(db.profiles) == "table" then
        for name, snapshot in pairs(db.profiles) do
            local clean = Profiles.CleanName(name)
            if clean and clean == name and type(snapshot) == "table" and n < Profiles.MAX then
                profiles[name] = snapshot
                n = n + 1
            end
        end
    end
    db.profiles = profiles
    local active = Profiles.CleanName(db.activeProfile)
    db.activeProfile = active or Profiles.DEFAULT
    local chars = {}
    if type(db.charProfiles) == "table" then
        for who, name in pairs(db.charProfiles) do
            if Util.FullName(who) == who and Profiles.CleanName(name) == name then chars[who] = name end
        end
    end
    db.charProfiles = chars
    if type(db.importUndo) ~= "table" then db.importUndo = nil end
end

function Profiles.Active()
    return ns.db.activeProfile
end

-- Profile names, sorted, with the active one included even before it is saved.
function Profiles.List()
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
    if ns.db.profiles[name] or name == ns.db.activeProfile then
        return nil, "there's already a profile called " .. name
    end
    -- The active profile is stored too, the first time.
    local after = Count() + 1 + (ns.db.profiles[ns.db.activeProfile] and 0 or 1)
    if after > Profiles.MAX then return nil, "you have the most profiles allowed (" .. Profiles.MAX .. ")" end
    ns.db.profiles[ns.db.activeProfile] = Profiles.Snapshot(ns.db)
    ns.db.profiles[name] = Profiles.Snapshot(ns.db)
    ns.db.activeProfile = name
    RememberForCharacter(name)
    return name
end

-- Switch to a saved profile: your current settings are saved into the
-- active one first.
function Profiles.Use(input)
    local name, why = Profiles.CleanName(input)
    if not name then return nil, why end
    if name == ns.db.activeProfile then
        RememberForCharacter(name)
        return name
    end
    local target = ns.db.profiles[name]
    if not target then return nil, "there's no profile called " .. name end
    Profiles.SaveActive()
    Apply(target)
    ns.db.activeProfile = name
    RememberForCharacter(name)
    return name
end

function Profiles.Delete(input)
    local name, why = Profiles.CleanName(input)
    if not name then return nil, why end
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
    local me = Util.UnitFullName("player")
    local want = me and ns.db.charProfiles[me]
    if want and want ~= ns.db.activeProfile and ns.db.profiles[want] then
        Profiles.Use(want)
        ns.Diag.Log("profiles", "switched to %s, the profile %s used last", want, me)
    end
end
