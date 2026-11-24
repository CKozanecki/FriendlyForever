-- Friendly player nameplates give nearby players a unit token, which is how
-- the game names whoever buffs you. Without them most casters are unknown.
-- This module only reads those settings, and changes them only when the
-- player clicks the button for it; it never switches them on by itself.
local _, ns = ...

local Nameplates = {}
ns.Nameplates = Nameplates

-- Forever's UI code reads and toggles these (Blizzard_SettingsDefinitions_Frame
-- Nameplates.lua; the FRIENDNAMEPLATES binding, #521: docs/forever-facts.md).
Nameplates.SHOW_FRIENDLY = "nameplateShowFriendlyPlayers"
Nameplates.NAMES_ONLY = "nameplateShowOnlyNameForFriendlyPlayerUnits"
-- The key binding that toggles them (Key Bindings, Targeting).
Nameplates.TOGGLE_BINDING = "FRIENDNAMEPLATES"
Nameplates.MAX_KEY_TEXT = 24 -- a key's name, as shown, at most this long

local function GetSetting(name)
    if C_CVar and C_CVar.GetCVar then return C_CVar.GetCVar(name) end
    if GetCVar then return GetCVar(name) end
end

local function SetSetting(name, value)
    if C_CVar and C_CVar.SetCVar then return C_CVar.SetCVar(name, value) end
    if SetCVar then return SetCVar(name, value) end
end

-- true / false, or nil if this client doesn't have the setting, or won't
-- say (an error, a secret, not a string: #521, which counts that as off).
function Nameplates.FriendlyShown()
    local value = ns.Util.ReadGameValues(GetSetting, Nameplates.SHOW_FRIENDLY)
    if type(value) ~= "string" then return nil end
    return value == "1"
end

-- The key that shows them, as the game names it ("Shift-V"), or nil when
-- none is bound or the game won't say. Only a short plain name is used.
function Nameplates.ToggleKeyText()
    local key = ns.Util.ReadGameValues(GetBindingKey, Nameplates.TOGGLE_BINDING)
    if type(key) ~= "string" or key == "" then return nil end
    local text = ns.Util.ReadGameValues(GetBindingText, key)
    if type(text) ~= "string" or text == "" then text = key end
    -- Plain letters, digits, spaces, "-" and "+" only: never an escape code.
    if #text > Nameplates.MAX_KEY_TEXT or not text:find("^[%w%-%+ ]+$") then return nil end
    return text
end

-- How to show them, for a note: the key, or the slash command.
function Nameplates.HowToShow()
    return Nameplates.ToggleKeyText() or "/friendly nameplates"
end

-- Turn on friendly player nameplates, as names only (no health bars).
-- Returns true on success, or false and a reason.
function Nameplates.EnableFriendlyNames()
    if Nameplates.FriendlyShown() == nil then
        return false, "this game client has no friendly nameplate setting"
    end
    if InCombatLockdown() then
        return false, "nameplate settings can't be changed in combat; try again afterwards"
    end
    local ok = pcall(SetSetting, Nameplates.SHOW_FRIENDLY, "1")
    if not ok or not Nameplates.FriendlyShown() then
        return false, "the game didn't accept the change"
    end
    if GetSetting(Nameplates.NAMES_ONLY) ~= nil then pcall(SetSetting, Nameplates.NAMES_ONLY, "1") end
    ns.Diag.Log("nameplates", "friendly player names turned on")
    return true
end
