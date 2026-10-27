-- Buff mode: while it's on, a key of your choice (the mouse wheel, say, to
-- buff a raid quickly) also presses the buff-back button. The key is lent
-- with an override binding, so when buff mode ends it does what it did
-- before. Buff mode never casts by itself: it only changes which key
-- presses the button, and the button still casts only on your press.
--
-- Override bindings can't be changed in a fight. Turning buff mode on or off
-- in one waits for the fight to end. The lent key is handed back as a fight
-- starts (PLAYER_REGEN_DISABLED, when the game still allows it), so it does
-- its own job in the fight while the button is empty, and lent again after.
-- The button's refresh (BuffButton.Refresh) keeps the binding in step with
-- what's wanted, so switching the addon or Buff Back off hands the key back.
--
-- Buff mode is off after a login or reload: the game drops override
-- bindings then anyway.
local _, ns = ...
local Util = ns.Util

local BuffMode = {}
ns.BuffMode = BuffMode

BuffMode.DEFAULT_KEY = "MOUSEWHEELUP"
BuffMode.MAX_KEY_LENGTH = 40
BuffMode.BINDING = "FRIENDLYFOREVER_BUFFMODE"
-- Keys never lent: without them you couldn't close a window or chat.
BuffMode.BLOCKED_KEYS = { ESCAPE = true, ENTER = true, NUMPADENTER = true }
-- Modifier keys alone aren't keys to lend.
BuffMode.MODIFIER_KEYS = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
    LMETA = true, RMETA = true,
}

_G["BINDING_NAME_" .. BuffMode.BINDING] = "Friendly Forever: buff mode on/off"

local owner              -- the frame the override binding belongs to
local wanted = false     -- what you asked for; applied out of combat
local lentKey            -- the key lent right now, or nil

-- Whether key is a key name the game can bind, optionally with ALT-, CTRL-
-- and SHIFT- in front ("SHIFT-MOUSEWHEELUP"), that buff mode may lend.
function BuffMode.IsValidKey(key)
    if type(key) ~= "string" or #key > BuffMode.MAX_KEY_LENGTH then return false end
    local base = key:gsub("^ALT%-", ""):gsub("^CTRL%-", ""):gsub("^SHIFT%-", "")
    -- The game writes the "-" key itself as "MINUS", so the rest is letters and digits.
    if not base:find("^[%u%d]+$") then return false end
    return not BuffMode.BLOCKED_KEYS[base] and not BuffMode.MODIFIER_KEYS[base]
end

-- The key to lend: the saved one, or the default (and why) if it isn't usable.
function BuffMode.Key()
    local key = ns.db and type(ns.db.buffBack) == "table" and ns.db.buffBack.buffModeKey
    if BuffMode.IsValidKey(key) then return key end
    return BuffMode.DEFAULT_KEY, "the saved key isn't one that can be used"
end

-- The key as the game shows it ("Mouse Wheel Up"), for messages.
function BuffMode.KeyText(key)
    local text = Util.ReadGameValues(GetBindingText, key)
    if type(text) == "string" and text ~= "" then return Util.StripChat(text) end
    return key
end

function BuffMode.IsOn() return wanted end
function BuffMode.LentKey() return lentKey end

local function HandBack()
    if lentKey then ClearOverrideBindings(owner) end
    lentKey = nil
end

local function Lend(key)
    local ok, err = pcall(SetOverrideBindingClick, owner, true, key, ns.BuffButton.FRAME_NAME, "LeftButton")
    if ok then
        lentKey = key
        return true
    end
    return false, tostring(err)
end

local function Allowed()
    return ns.db.enabled and ns.db.buffBack.enabled
end

-- Make the binding match what's wanted: called by BuffButton.Refresh, so
-- out of combat whenever anything changes. Cheap when nothing has.
function BuffMode.Apply()
    if not owner or InCombatLockdown() then return end
    if not wanted or not Allowed() or not ns.BuffButton.Frame() then return HandBack() end
    local key, why = BuffMode.Key()
    if lentKey ~= key then
        if why then ns.Print("buff mode: " .. why .. "; using " .. BuffMode.KeyText(key) .. ".") end
        HandBack()
        local ok, err = Lend(key)
        if not ok and key ~= BuffMode.DEFAULT_KEY then
            ns.Diag.Log("buffMode", "couldn't lend %s: %s", key, err)
            ns.Print("buff mode: the game wouldn't lend " .. BuffMode.KeyText(key) .. "; using "
                .. BuffMode.KeyText(BuffMode.DEFAULT_KEY) .. ".")
            ok, err = Lend(BuffMode.DEFAULT_KEY)
        end
        if not ok then
            ns.Diag.Log("buffMode", "couldn't lend the default key: %s", err)
            wanted = false
            ns.Print("buff mode is off: the game wouldn't lend a key to the buff-back button.")
        end
    end
end

-- Turn buff mode on or off. In a fight, it happens when the fight ends.
function BuffMode.Set(on)
    on = on and true or false
    if on and not Allowed() then
        return ns.Print("buff mode needs the addon and Buff Back switched on.")
    end
    local changed = wanted ~= on
    wanted = on
    if InCombatLockdown() then
        if changed then
            ns.Print(on and "buff mode will turn on when this fight ends."
                or "buff mode will turn off when this fight ends.")
        end
        return
    end
    ns.BuffButton.Refresh()
    if not changed then return end
    if wanted and lentKey then
        ns.Print("buff mode on: " .. BuffMode.KeyText(lentKey) .. " presses the buff-back button.")
    elseif not wanted then
        ns.Print("buff mode off.")
    end
end

function BuffMode.Toggle()
    BuffMode.Set(not wanted)
end

-- A fight is starting: hand the key back while the game still allows it.
function BuffMode.OnCombatStart()
    if InCombatLockdown() then return end
    HandBack()
end

-- Choose the key to lend. Returns true, or false and why not.
function BuffMode.SetKey(key)
    if type(key) == "string" then key = key:upper() end
    if not BuffMode.IsValidKey(key) then return false, "that isn't a key buff mode can use" end
    if Util.ReadGameValues(GetBindingAction, key) == BuffMode.BINDING then
        return false, "that key turns buff mode on and off"
    end
    if InCombatLockdown() and lentKey then return false, "keys can't change in a fight" end
    ns.db.buffBack.buffModeKey = key
    ns.BuffButton.Refresh()
    return true
end

function BuffMode.StatusLine()
    if lentKey then return "buff mode: on, " .. BuffMode.KeyText(lentKey) .. " presses the button" end
    if wanted then return "buff mode: on, waiting for the fight to end" end
    return "buff mode: off (key: " .. BuffMode.KeyText((BuffMode.Key())) .. ")"
end

-- The frame the override binding belongs to. BuffButton calls
-- OnCombatStart and (through Refresh) Apply on the fight's events.
function BuffMode.Create()
    if owner then return end
    owner = CreateFrame("Frame")
end

-- The key binding in Key Bindings > AddOns (Bindings.xml) calls this.
function FriendlyForever_ToggleBuffMode()
    if not ns.db then return end
    ns.Diag.Call(BuffMode.Toggle)
end
