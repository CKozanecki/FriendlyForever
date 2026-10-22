-- Wiring: saved variables, game events -> modules, slash commands.
local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME
ns.TITLE = "Friendly Forever"
ns.VERSION = "?"
if C_AddOns and C_AddOns.GetAddOnMetadata then
    local ok, version = pcall(C_AddOns.GetAddOnMetadata, ADDON_NAME, "Version")
    if ok and type(version) == "string" then ns.VERSION = version end
end

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff7fd4ff" .. ns.TITLE .. ":|r " .. tostring(msg))
end

function ns.SetEnabled(on)
    ns.db.enabled = on and true or false
    ns.Print(ns.db.enabled and "|cff00ff00enabled|r" or "|cffff4040disabled|r")
    ns.Minimap.Refresh()
    ns.Options.Refresh()
end

function ns.ResetType(msgType)
    ns.db[msgType] = ns.Config.DefaultsFor(msgType)
end

local frame = CreateFrame("Frame")
local handlers = {}

local function Register(event, handler, unit)
    handlers[event] = handler
    if unit then
        frame:RegisterUnitEvent(event, unit)
    else
        frame:RegisterEvent(event)
    end
end

function handlers.ADDON_LOADED(name)
    if name ~= ADDON_NAME then return end
    frame:UnregisterEvent("ADDON_LOADED")

    FriendlyForeverDB = ns.Config.Load(FriendlyForeverDB)
    ns.db = FriendlyForeverDB

    ns.ChatQueue.Init()
    ns.Options.Create()
    ns.Minimap.Create()

    Register("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
        if isLogin or isReload then
            ns.Announcer.OnEnteringWorld()
            ns.Greeter.OnEnteringWorld()
            ns.Greeter.RequestRoster()
        end
    end)
    Register("CHAT_MSG_SYSTEM", ns.Greeter.OnSystemMessage)
    Register("GROUP_ROSTER_UPDATE", ns.Greeter.OnGroupRosterUpdate)
    Register("GUILD_ROSTER_UPDATE", ns.Greeter.OnRosterUpdate)
    Register("PLAYER_GUILD_UPDATE", ns.Greeter.RequestRoster)
    Register("UNIT_AURA", function(_, updateInfo) ns.BuffTracker.OnPlayerAura(updateInfo) end, "player")
    Register("UNIT_SPELLCAST_SUCCEEDED", ns.BuffTracker.OnSpellcastSucceeded)
    Register("CVAR_UPDATE", function() ns.Options.Refresh() end)
    Register("ADDON_ACTION_BLOCKED", function(addon, func) ns.OnActionBlocked("blocked", addon, func) end)
    Register("ADDON_ACTION_FORBIDDEN", function(addon, func) ns.OnActionBlocked("forbidden", addon, func) end)

    ns.Diag.Log("load", "loaded %s; %s", ns.VERSION, ns.Announcer.ActiveState())
end

-- The game raises these when it stops an addon from calling a protected
-- function. They are the clearest sign the game itself is refusing a send.
local blockedReports = 0
function ns.OnActionBlocked(kind, addon, func)
    if addon ~= ADDON_NAME then return end
    ns.Diag.Count("actionsBlocked")
    ns.Diag.Log("game", "the game %s our call to %s", kind, func)
    if blockedReports < 3 then
        blockedReports = blockedReports + 1
        ns.Print("|cffff4040the game " .. kind .. " a call to " .. ns.Diag.Safe(func) .. "|r (see /friendly status)")
    end
end

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, ...)
    local handler = handlers[event]
    if handler then ns.Diag.Call(handler, ...) end
end)

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

local SAMPLE_VARS = { name = "Nikki", fullname = "Nikki Shifts", buff = "Power Word: Fortitude and Arcane Intellect" }

local function OnOff(value) return value and "|cff00ff00on|r" or "|cffff4040off|r" end

local function PrintStatus()
    local db, n, Q = ns.db, ns.Diag.Counters(), ns.ChatQueue
    local function c(key) return n[key] or 0 end
    ns.Print("version " .. ns.VERSION .. ", debug " .. OnOff(db.debug))
    ns.Print("state: " .. ns.Announcer.ActiveState())
    for _, msgType in ipairs(ns.Config.TYPES) do
        local cfg = db[msgType]
        ns.Print(string.format("  %s: %s, delay %ss, repeat %ss", ns.Config.TYPE_INFO[msgType].label,
            OnOff(cfg.enabled), cfg.delay, cfg.repeatCooldown))
    end
    ns.Print(string.format("guild: %s, %d members known, %d roster updates",
        IsInGuild() and "yes" or "no", ns.Greeter.MemberCount(), c("rosterUpdates")))
    local shown = ns.Nameplates.FriendlyShown()
    ns.Print("friendly player nameplates: " .. (shown == nil and "not available"
        or shown and "|cff00ff00on|r (casters can be named)"
        or "|cffff4040off|r (most casters can't be named; /friendly nameplates turns them on)"))
    ns.Print("group chat channel: " .. (ns.Greeter.GroupChannel() or "none (not grouped)"))
    ns.Print(string.format("chat: lockdown %s, %d waiting, waiting for key press %s, key listener %s",
        OnOff(Q.InChatLockdown()), Q.Count(), OnOff(Q.IsWaitingForHardware()), OnOff(Q.IsKeyboardReady())))
    ns.Print(string.format("seen: %d system messages (%d recognised), %d buffs, %d restricted buff updates skipped",
        c("systemMessages"), c("systemMatched"), c("buffsSeen"), c("restrictedAuraUpdates")))
    ns.Print(string.format("sending: %d queued, %d sent, %d dropped, %d send errors, %d blocked by the game",
        c("queued"), c("sent"), c("dropped"), c("sendErrors"), c("actionsBlocked")))
    ns.Print(string.format("Lua errors in this addon: %d%s", c("luaErrors"),
        ns.Diag.lastError and (" (last: " .. ns.Diag.lastError .. ")") or ""))
    ns.Print(string.format("APIs: SendChatMessage %s, chat lockdown check %s, aura query %s, secret check %s",
        OnOff(C_ChatInfo and C_ChatInfo.SendChatMessage or SendChatMessage),
        OnOff(C_ChatInfo and C_ChatInfo.InChatMessagingLockdown),
        OnOff(C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID),
        OnOff(issecretvalue)))
end

-- Exactly what the game returns for names, so the format is never guessed.
local function PrintNames()
    local function raw(...)
        local out = {}
        for i = 1, select("#", ...) do out[i] = "'" .. ns.Diag.Safe((select(i, ...))) .. "'" end
        return #out > 0 and table.concat(out, ", ") or "(nothing)"
    end
    ns.Print("UnitName(player): " .. raw(UnitName("player")))
    if UnitFullName then ns.Print("UnitFullName(player): " .. raw(UnitFullName("player"))) end
    if GetUnitName then ns.Print("GetUnitName(player, true): " .. raw(GetUnitName("player", true))) end
    ns.Print("Friendly Forever uses: '" .. ns.Diag.Safe(ns.Util.UnitFullName("player")) .. "'")
    if UnitName("target") then
        ns.Print("UnitName(target): " .. raw(UnitName("target")) .. " -> '"
            .. ns.Diag.Safe(ns.Util.UnitFullName("target")) .. "'")
    end
    if IsInGuild() and GetNumGuildMembers() > 0 then
        ns.Print("guild roster #1: " .. raw((GetGuildRosterInfo(1))))
    end
    ns.Diag.Log("names", "UnitName(player)=%s; we use %s", raw(UnitName("player")), ns.Util.UnitFullName("player"))
end

-- Whisper yourself through the real send path: proves sending works without
-- bothering anyone else.
local function SelfTest()
    local me = ns.Util.UnitFullName("player")
    if not me then
        ns.Print("self-test: couldn't read your character name")
        return
    end
    ns.Print("self-test: whispering yourself (" .. me .. ")...")
    ns.ChatQueue.Push({
        channel = "WHISPER",
        target = me,
        label = "self-test",
        getText = function() return "Friendly Forever self-test: sending works." end,
        onDone = function(sent)
            ns.Print(sent and "self-test: |cff00ff00sent|r. If no whisper arrived, the game blocked it."
                or "self-test: |cffff4040not sent|r (see /friendly status, or /friendly debug for details)")
        end,
    })
end

local commands = {
    on = function() ns.SetEnabled(true) end,
    off = function() ns.SetEnabled(false) end,
    toggle = function() ns.SetEnabled(not ns.db.enabled) end,
    say = function() ns.ChatQueue.OnHardwareEvent() end,
    minimap = function()
        ns.db.minimap.hide = not ns.db.minimap.hide
        ns.Minimap.Refresh()
    end,
    test = function()
        for _, msgType in ipairs(ns.Config.TYPES) do
            local template = ns.Messages.Pick(msgType, ns.db[msgType].messages)
            local text = template and ns.Util.Render(template, SAMPLE_VARS) or "(no messages)"
            ns.Print(ns.Config.TYPE_INFO[msgType].label .. ": " .. text)
        end
    end,
    status = PrintStatus,
    selftest = SelfTest,
    names = PrintNames,
    nameplates = function()
        local ok, reason = ns.Nameplates.EnableFriendlyNames()
        ns.Print(ok and "friendly player names are now shown (names only)." or ("couldn't turn them on: " .. reason))
        ns.Options.Refresh()
    end,
    debug = function() ns.Diag.SetEnabled(not ns.db.debug) end,
    help = function()
        ns.Print("/friendly - open options")
        ns.Print("/friendly status - what the addon has seen and sent this session")
        ns.Print("/friendly selftest - whisper yourself to check sending works")
        ns.Print("/friendly names - show how the game reports names")
        ns.Print("/friendly nameplates - show friendly player names, so casters can be named")
        ns.Print("/friendly debug - log every decision (shown here and saved to disk)")
        ns.Print("/friendly on | off | toggle - turn everything on or off")
        ns.Print("/friendly test - preview one message of each type (only you see it)")
        ns.Print("/friendly say - send a waiting buff thank-you now")
        ns.Print("/friendly minimap - show or hide the minimap button")
    end,
}

SLASH_FRIENDLYFOREVER1 = "/friendly"
SLASH_FRIENDLYFOREVER2 = "/ffr"
SlashCmdList.FRIENDLYFOREVER = function(input)
    local cmd = (input or ""):lower():match("^%s*(%S*)")
    local command = commands[cmd]
    if command then
        command()
    elseif cmd == "" then
        ns.Options.Open()
    else
        ns.Print("unknown command '" .. ns.Util.StripChat(cmd) .. "'. Type /friendly help")
    end
end
