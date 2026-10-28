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
-- Keys never lent: without them you couldn't close a window, chat, type a
-- slash command, or click, turn and move with the mouse in the world.
BuffMode.BLOCKED_KEYS = {
    ESCAPE = true, ENTER = true, NUMPADENTER = true, ["/"] = true, BUTTON1 = true, BUTTON2 = true,
}
-- Punctuation keys, which the game names by the character itself ("-", and
-- with Shift "SHIFT--"; the keypad's is "NUMPADMINUS").
BuffMode.PUNCTUATION_KEYS = {
    ["-"] = true, ["`"] = true, [","] = true, ["."] = true, ["/"] = true, [";"] = true, ["'"] = true,
    ["["] = true, ["]"] = true, ["\\"] = true, ["="] = true,
}
-- Modifier keys alone aren't keys to lend.
BuffMode.MODIFIER_KEYS = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
    LMETA = true, RMETA = true,
}

_G["BINDING_NAME_" .. BuffMode.BINDING] = "Friendly Forever: buff mode on/off"

local owner              -- the frame the override binding belongs to
local wanted = false     -- what you asked for; applied out of combat
local auto = false       -- this buff mode was turned on by a trigger (BuffModeAuto.lua)
local lentKey            -- the key lent right now, or nil
local autoHintShown = false -- said where the triggers live, this session

-- Whether key is a key name the game can bind, optionally with ALT-, CTRL-
-- and SHIFT- in front ("SHIFT-MOUSEWHEELUP"), that buff mode may lend.
function BuffMode.IsValidKey(key)
    if type(key) ~= "string" or #key > BuffMode.MAX_KEY_LENGTH then return false end
    local base = key:gsub("^ALT%-", ""):gsub("^CTRL%-", ""):gsub("^SHIFT%-", "")
    -- Letters and digits ("F", "MOUSEWHEELUP", "BUTTON4"), or one punctuation key.
    if not base:find("^[%u%d]+$") and not BuffMode.PUNCTUATION_KEYS[base] then return false end
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
    if wanted and not Allowed() then
        -- Switching the addon or Buff Back off ends buff mode: it doesn't
        -- quietly take the key again when they come back on.
        wanted = false
        ns.Print("buff mode off: the addon or Buff Back is switched off.")
    end
    if not wanted or not ns.BuffButton.Frame() then return HandBack() end
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
-- how (optional): { auto = true } when a trigger does it, and why = words
-- for the message ("you joined a group"). Turning it on or off yourself
-- makes it yours: triggers then never turn it off.
function BuffMode.Set(on, how)
    on = on and true or false
    how = how or {}
    if on and not Allowed() then
        if how.auto then return end
        return ns.Print("buff mode needs the addon and Buff Back switched on.")
    end
    local changed = wanted ~= on
    wanted = on
    auto = on and how.auto == true
    if InCombatLockdown() then
        if changed then
            ns.Print(on and "buff mode will turn on when this fight ends."
                or "buff mode will turn off when this fight ends.")
        end
        return
    end
    ns.BuffButton.Refresh()
    if not changed then return end
    local because = how.why and (" (" .. how.why .. ")") or ""
    if wanted and lentKey then
        ns.Print("buff mode on" .. because .. ": " .. BuffMode.KeyText(lentKey) .. " presses the buff-back button.")
        -- The triggers are on by default, so say once a session where they live.
        if auto and not autoHintShown then
            autoHintShown = true
            ns.Print("buff mode turns itself on and off: choose when on the Buff Back tab (/friendly).")
        end
    elseif not wanted then
        ns.Print("buff mode off" .. because .. ".")
    end
end

-- A fight is starting and a trigger's buff mode ends with it. Called during
-- PLAYER_REGEN_DISABLED: it hands the key back but doesn't refresh the
-- button, which must stay empty for the fight (BuffButton.OnCombatStart).
function BuffMode.EndForFight(why)
    if not (wanted and auto) then return end
    wanted, auto = false, false
    if not InCombatLockdown() then HandBack() end
    ns.Print("buff mode off (" .. why .. ").")
end

-- Whether buff mode is on because a trigger turned it on.
function BuffMode.IsAuto() return wanted and auto end

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
    ns.db.buffBack.buffModeKey = key
    ns.BuffButton.Refresh()
    return true
end

function BuffMode.StatusLine()
    if lentKey then
        return "buff mode: on" .. (auto and " (turned on by itself)" or "") .. ", "
            .. BuffMode.KeyText(lentKey) .. " presses the button"
    end
    if wanted and InCombatLockdown() then return "buff mode: on, waiting for the fight to end" end
    if wanted then return "buff mode: on, waiting for the button" end
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
