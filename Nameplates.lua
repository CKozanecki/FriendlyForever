-- Friendly player nameplates give nearby players a unit token, which is how
-- the game names whoever buffs you. Without them most casters are unknown.
-- This module only reads those settings, and changes them only when the
-- player clicks the button for it; it never switches them on by itself.
local _, ns = ...

local Nameplates = {}
ns.Nameplates = Nameplates

Nameplates.SHOW_FRIENDLY = "nameplateShowFriendlyPlayers"
Nameplates.NAMES_ONLY = "nameplateShowOnlyNameForFriendlyPlayerUnits"

local function GetSetting(name)
    if C_CVar and C_CVar.GetCVar then return C_CVar.GetCVar(name) end
    if GetCVar then return GetCVar(name) end
end

local function SetSetting(name, value)
    if C_CVar and C_CVar.SetCVar then return C_CVar.SetCVar(name, value) end
    if SetCVar then return SetCVar(name, value) end
end

-- true / false, or nil if this client doesn't have the setting.
function Nameplates.FriendlyShown()
    local value = GetSetting(Nameplates.SHOW_FRIENDLY)
    if value == nil then return nil end
    return value == "1"
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
