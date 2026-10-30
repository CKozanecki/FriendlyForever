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
    ns.RefreshEvents()
    ns.BuffButton.Refresh()
    ns.Print(ns.db.enabled and "|cff00ff00enabled|r" or "|cffff4040disabled|r")
    ns.Minimap.Refresh()
    ns.Options.Refresh()
end

-- Back to defaults, keeping settings about this screen (the button's place).
function ns.ResetType(msgType)
    local fresh = ns.Config.DefaultsFor(msgType)
    for _, key in ipairs(ns.Profiles.LOCAL_ONLY[msgType] or {}) do fresh[key] = ns.db[msgType][key] end
    ns.db[msgType] = fresh
    ns.RefreshEvents()
    ns.BuffButton.Refresh()
end

local frame = CreateFrame("Frame")
local handlers = {}

-- UNIT_SPELLCAST_SUCCEEDED fires for every cast the client sees, and only
-- buff watching uses it (to name casters), so it is registered only while
-- Buff Thanks or Buff Back is on. Call this whenever one of those switches
-- or the master switch changes.
function ns.RefreshEvents()
    if not ns.db then return end
    if ns.BuffTracker.Watching() then
        frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    else
        frame:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    end
end

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

    -- The game reads the file list only at start-up: after an update that
    -- added files, /reload runs the new code without them. Stay inert and
    -- say so, rather than erroring on every event.
    for _, module in ipairs({ "Flavour", "Ignore", "Ledger", "Serialize", "Profiles", "Window",
        "BuffData", "Water", "Offers", "BuffButton", "Battleground", "Cities",
        "Comm", "RateLimit", "Exchange", "Receipts", "GuildHellos", "OptionsIndex" }) do
        if ns[module] == nil then
            ns.Print("|cffff4040this update added files. Restart the game (not /reload) to finish updating.|r")
            return
        end
    end

    FriendlyForeverDB = ns.Config.Load(FriendlyForeverDB)
    ns.db = FriendlyForeverDB

    ns.ChatQueue.Init()
    ns.Comm.Init()
    ns.Options.Create()
    ns.Minimap.Create()
    ns.BuffMode.Create()
    ns.BuffButton.Create()
    ns.BuffModeAuto.Create()
    ns.Battleground.Create()
    ns.Water.Create()

    Register("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
        if isLogin or isReload then
            ns.Profiles.OnLogin()
            ns.Announcer.OnEnteringWorld()
            ns.Greeter.OnEnteringWorld()
            ns.Greeter.RequestRoster()
        end
    end)
    Register("CHAT_MSG_SYSTEM", ns.Greeter.OnSystemMessage)
    Register("CHAT_MSG_ADDON", ns.Comm.OnAddonMessage)
    Register("GROUP_ROSTER_UPDATE", function(...)
        -- Forget this raid's Blessings as you leave it, so they can't carry
        -- into the next raid (BuffRules.lua).
        ns.BuffRules.CheckRaid()
        ns.Options.Refresh() -- the raid Blessing boxes work only in a raid
        ns.Greeter.OnGroupRosterUpdate(...)
    end)
    Register("GUILD_ROSTER_UPDATE", ns.Greeter.OnRosterUpdate)
    Register("PLAYER_GUILD_UPDATE", ns.Greeter.RequestRoster)
    -- The battleground phase first: buffs that arrive as the battle starts
    -- aren't tracked (Battleground.lua).
    Register("UNIT_AURA", function(_, updateInfo)
        ns.Battleground.OnPlayerAura()
        ns.BuffTracker.OnPlayerAura(updateInfo)
    end, "player")
    handlers.UNIT_SPELLCAST_SUCCEEDED = ns.BuffTracker.OnSpellcastSucceeded
    ns.RefreshEvents()
    Register("CVAR_UPDATE", function() ns.Options.Refresh() end)
    -- Edits made since the last switch go into the active profile.
    Register("PLAYER_LOGOUT", function()
        ns.Profiles.SaveActive()
        ns.ChatQueue.SaveCap()
    end)
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
-- Events whose handler only reads the first argument. CHAT_MSG_SYSTEM
-- brings about 17, which would miss Diag.Call's fast path (four or fewer).
local FIRST_ARG_ONLY = { CHAT_MSG_SYSTEM = true }
-- CHAT_MSG_ADDON brings about 9, for every addon's messages; ours reads 4.
local FIRST_FOUR_ARGS = { CHAT_MSG_ADDON = true }

frame:SetScript("OnEvent", function(_, event, ...)
    local handler = handlers[event]
    if not handler then return end
    if FIRST_ARG_ONLY[event] then
        ns.Diag.Call(handler, (...))
    elseif FIRST_FOUR_ARGS[event] then
        local a1, a2, a3, a4 = ...
        ns.Diag.Call(handler, a1, a2, a3, a4)
    else
        ns.Diag.Call(handler, ...)
    end
end)

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

local SAMPLE_VARS = { name = "Nikki", fullname = "Nikki Shifts", buff = "Power Word: Fortitude and Arcane Intellect" }

local function OnOff(value) return value and "|cff00ff00on|r" or "|cffff4040off|r" end

-- What the addon has seen and done, one line each (for /friendly status
-- and the bug report).
local function StatusLines()
    local db, n, Q = ns.db, ns.Diag.Counters(), ns.ChatQueue
    local out = {}
    local function add(line) out[#out + 1] = line end
    local function c(key) return n[key] or 0 end
    add("version " .. ns.VERSION .. ", debug " .. OnOff(db.debug))
    add("state: " .. ns.Announcer.ActiveState())
    -- "Why didn't it greet?" is often this, since the option is on by default.
    local afk, afkText = Q.ReadPlayerAFK(), "you're not AFK"
    if afk == nil then
        afkText = "can't tell if you're AFK right now, so messages are sent"
    elseif afk then
        afkText = db.skipWhileAFK and "you're AFK: automatic messages are being dropped" or "you're AFK"
    end
    add("skip while AFK: " .. OnOff(db.skipWhileAFK) .. " (" .. afkText .. ")")
    for _, msgType in ipairs(ns.Config.TYPES) do
        local cfg = db[msgType]
        local info = ns.Config.TYPE_INFO[msgType]
        if info.noTiming then
            add(string.format("  %s: %s", info.label, OnOff(cfg.enabled)))
        else
            add(string.format("  %s: %s, delay %ss, repeat %ss", info.label, OnOff(cfg.enabled), cfg.delay,
                cfg.repeatCooldown))
        end
    end
    local _, race, raceId = UnitRace("player")
    local faction = UnitFactionGroup("player")
    add(string.format("your race: %s (id %s, %s), speaking as %s", ns.Diag.Safe(race), ns.Diag.Safe(raceId),
        ns.Diag.Safe(faction), ns.Diag.Safe(ns.Flavour.Context().race or "general lines")))
    add(string.format("buff thanks: %s; if that can't reach them: %s; profile %s; %d ignored",
        db.buff.thankStyle, db.buff.fallback, ns.Diag.Safe(ns.Profiles.Active()), #ns.Ignore.List()))
    add(ns.Cities.StatusLine())
    add(ns.Water.StatusLine())
    add(string.format("guild: %s, %d members known, %d roster updates",
        IsInGuild() and "yes" or "no", ns.Greeter.MemberCount(), c("rosterUpdates")))
    local shown = ns.Nameplates.FriendlyShown()
    add("friendly player nameplates: " .. (shown == nil and "not available"
        or shown and "|cff00ff00on|r (casters can be named)"
        or "|cffff4040off|r (most casters can't be named; /friendly nameplates turns them on)"))
    add("group chat channel: " .. (ns.Greeter.GroupChannel() or "none (not grouped)"))
    add(string.format("chat: lockdown %s, %d waiting, waiting for key press %s, key listener %s",
        OnOff(Q.InChatLockdown()), Q.Count(), OnOff(Q.IsWaitingForHardware()), OnOff(Q.IsKeyboardReady())))
    add(string.format("seen: %d system messages (%d recognised), %d buffs, %d restricted buff updates skipped",
        c("systemMessages"), c("systemMatched"), c("buffsSeen"), c("restrictedAuraUpdates")))
    add(string.format("sending: %d queued, %d sent, %d dropped, %d send errors, %d blocked by the game",
        c("queued"), c("sent"), c("dropped"), c("sendErrors"), c("actionsBlocked")))
    add(string.format("chat cap: %d lines a minute in each chat; %d held back by it, %d dropped by it",
        Q.LinesPerMinute(), c("capHeld"), c("capDropped")))
    local commState = ns.Comm.Ready() and "|cff00ff00open|r"
        or ns.Comm.Registered() and "closed (addon off)" or "|cffff4040closed|r"
    add(string.format("addon messages: %s; %d sent, %d not sent, %d received; %d other copies seen", commState,
        c("commSent"), c("commNotSent"), c("commReceived"), ns.Comm.PeerCount()))
    add(string.format("addon messages dropped: %d unreadable, %d oversized, %d malformed, %d wrong version, "
        .. "%d unknown type, %d wrong route, %d spoofed, %d flooding", c("commUnreadable"), c("commOversized"),
        c("commMalformed"), c("commWrongVersion"), c("commUnknownType"), c("commWrongRoute"), c("commSpoofed"),
        c("commFlood")))
    add(string.format("Lua errors in this addon: %d%s", c("luaErrors"),
        ns.Diag.lastError and (" (last: " .. ns.Diag.lastError .. ")") or ""))
    add(string.format("APIs: SendChatMessage %s, chat lockdown check %s, aura query %s, secret check %s, emote %s",
        OnOff(Q.CanSend()),
        OnOff(C_ChatInfo and C_ChatInfo.InChatMessagingLockdown),
        OnOff(C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID),
        OnOff(issecretvalue), OnOff(Q.CanEmote())))
    return out
end

local function PrintStatus()
    for _, line in ipairs(StatusLines()) do ns.Print(line) end
end

ns.REPORT_LOG_LINES = 60

-- Plain text for a bug report: status, then the latest debug log lines.
function ns.BugReport()
    local lines = { ns.TITLE .. " bug report", "" }
    for _, line in ipairs(StatusLines()) do
        lines[#lines + 1] = (line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
    end
    for _, line in ipairs(ns.BuffButton.StatusLines()) do lines[#lines + 1] = line end
    local log = ns.db.diagLog
    lines[#lines + 1] = ""
    if #log == 0 then
        lines[#lines + 1] = "debug log: empty. Turn on /friendly debug, make the problem happen, then copy this again."
    else
        lines[#lines + 1] = "debug log (latest " .. math.min(#log, ns.REPORT_LOG_LINES) .. " lines):"
        for i = math.max(1, #log - ns.REPORT_LOG_LINES + 1), #log do lines[#lines + 1] = log[i] end
    end
    return table.concat(lines, "\n")
end

function ns.ShowBugReport()
    ns.Window.Show({
        title = "Friendly Forever: copy for a bug report",
        hint = "Press Ctrl+C to copy, then paste it into your bug report.",
        text = ns.BugReport(),
    })
end

function ns.ShowExport()
    local text, why = ns.Profiles.Export()
    if not text then return ns.Print("couldn't export: " .. why) end
    ns.Window.Show({
        title = "Friendly Forever: export settings",
        hint = "Press Ctrl+C to copy. Paste it into /friendly import on another character or account.",
        text = text,
    })
end

function ns.ShowImport()
    ns.Window.Show({
        title = "Friendly Forever: import settings",
        hint = "Paste a settings line (Ctrl+V), then Import. Your on/off switch stays as it is; "
            .. "/friendly import undo puts your settings back.",
        acceptText = "Import",
        onAccept = function(text)
            local ok, why = ns.Profiles.Import(text)
            if not ok then return ns.Print("couldn't import: " .. why) end
            ns.Window.Hide()
            ns.Print("settings imported. /friendly import undo puts yours back.")
            ns.Options.Refresh()
        end,
    })
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

local function PrintIgnoreList()
    local names = ns.Ignore.List()
    if #names == 0 then
        ns.Print("nobody is on your ignore list. /friendly ignore <name> adds someone (or your target).")
    else
        ns.Print("never greeted or thanked (" .. #names .. "): " .. table.concat(names, ", "))
    end
end

local function IgnoreCommand(args)
    if args == "" and not ns.Util.UnitFullName("target") then return PrintIgnoreList() end
    if args:lower() == "list" then return PrintIgnoreList() end
    local name, why = ns.Ignore.Add(args)
    if not name then return ns.Print("couldn't add: " .. why) end
    ns.Print(ns.Util.DisplayName(name) .. " won't be greeted or thanked. /friendly unignore "
        .. ns.Util.DisplayName(name) .. " undoes it.")
    if ns.Ignore.LacksSurname(name) then
        ns.Print("|cffff8040Note:|r WoW Forever names have a surname. Add it (\"" .. name
            .. " Surname\"), or nobody will match.")
    end
    ns.Options.Refresh()
end

local function UnignoreCommand(args)
    local name, why = ns.Ignore.Remove(args)
    if not name then return ns.Print("couldn't remove: " .. why) end
    ns.Print(ns.Util.DisplayName(name) .. " is off your ignore list.")
    ns.Options.Refresh()
end

function ns.SnoozeFor(minutes)
    local set = ns.Announcer.Snooze(minutes)
    if set then
        ns.Print(string.format("snoozed for %d min: nothing is sent until then. /friendly snooze off wakes it.", set))
    else
        ns.Print("awake: messages are sent again.")
    end
    ns.Minimap.Refresh()
    ns.Options.Refresh()
    ns.BuffButton.Refresh()
end

local function SnoozeCommand(args)
    args = args:lower()
    if args == "off" or args == "0" then return ns.SnoozeFor(nil) end
    local minutes = args == "" and ns.Announcer.SNOOZE_DEFAULT or tonumber(args)
    if not minutes or minutes <= 0 then
        return ns.Print("usage: /friendly snooze [minutes, up to " .. ns.Announcer.SNOOZE_MAX .. "] | off")
    end
    ns.SnoozeFor(minutes)
end

function ns.LedgerSummaryText()
    local s = ns.Ledger.Summary()
    local text = string.format("today: buffed by %d, thanked %d, returned %d. "
        .. "All time: buffed by %d, thanked %d, returned %d.",
        s.todayReceived, s.todayThanked, s.todayReturned, s.received, s.thanked, s.returned)
    local standing = ns.Ledger.Title()
    if standing.title then text = text .. " Title: " .. standing.title .. "." end
    if standing.nextTitle then
        text = text .. string.format(" %d more to %s.", standing.returnsToNext, standing.nextTitle)
    end
    return text
end

local function LedgerCommand(args)
    if args:lower() == "clear" then
        ns.Ledger.Clear()
        ns.Options.Refresh()
        return ns.Print("favour ledger cleared.")
    end
    local limit = ns.Util.ClampNumber(tonumber(args), 1, ns.Ledger.MAX_ENTRIES, 10)
    ns.Print("favour ledger: " .. ns.LedgerSummaryText())
    local lines = ns.Ledger.Lines(limit)
    if #lines == 0 then ns.Print("  nobody outside your group has buffed you yet.") end
    for _, line in ipairs(lines) do ns.Print("  " .. ns.Diag.Safe(line)) end
end

local function ProfileCommand(args)
    local verb, name = args:match("^(%S*)%s*(.-)$")
    verb = (verb or ""):lower()
    local P = ns.Profiles
    local done, why
    if verb == "" or verb == "list" then
        ns.Print("profiles: " .. table.concat(P.List(), ", ") .. " (using " .. P.Active() .. ")")
        ns.Print("/friendly profile new <name> | use <name> | delete <name>")
        return
    elseif verb == "new" then
        done, why = P.New(name)
        if done then ns.Print("now using the new profile " .. done .. ", a copy of your settings.") end
    elseif verb == "use" then
        done, why = P.Use(name)
        if done then ns.Print("now using profile " .. done .. " (this character will use it at login).") end
    elseif verb == "delete" then
        done, why = P.Delete(name)
        if done then ns.Print("deleted profile " .. done .. ".") end
    else
        why = "unknown profile command '" .. ns.Util.StripChat(verb) .. "'"
    end
    if not done then ns.Print("profile: " .. why) end
    ns.Options.Refresh()
end

local function BuffBackCommand()
    for _, line in ipairs(ns.BuffButton.StatusLines()) do ns.Print(ns.Diag.Safe(line)) end
end

-- /friendly buffmode [on | off | key <key>]: no argument switches it.
local function BuffModeCommand(args)
    local verb, rest = args:match("^(%S*)%s*(.-)$")
    verb = (verb or ""):lower()
    if verb == "on" or verb == "off" then
        ns.BuffMode.Set(verb == "on")
    elseif verb == "" then
        ns.BuffMode.Toggle()
    elseif verb == "key" then
        if rest == "" then return ns.Print(ns.BuffMode.StatusLine()) end
        local ok, why = ns.BuffMode.SetKey(rest)
        ns.Print(ok and ("buff mode key: " .. ns.BuffMode.KeyText(ns.db.buffBack.buffModeKey) .. ".")
            or ("couldn't set the buff mode key: " .. why .. "."))
        ns.Options.Refresh()
    else
        ns.Print("/friendly buffmode [on | off | key <key>]")
    end
end

-- /friendly blessings [all | <keys>]: which of your Blessings you cover in
-- this raid (paladins; forgotten when you leave it).
local function BlessingsCommand(args)
    local R = ns.BuffRules
    local mine = R.MyBlessings()
    if #mine == 0 then return ns.Print("blessings: you don't know any Blessings.") end
    local words = {}
    for word in args:lower():gmatch("%S+") do words[#words + 1] = word end
    if #words > 0 then
        local ok, why
        if words[1] == "all" then ok, why = R.SetRaidBlessings(nil) else ok, why = R.SetRaidBlessings(words) end
        if not ok then ns.Print("blessings: " .. why .. ".") end
        ns.Options.Refresh()
    end
    local covered, keys = {}, {}
    for _, buff in ipairs(mine) do
        keys[#keys + 1] = buff.key
        if R.CoversInRaid(buff) then covered[#covered + 1] = ns.BuffData.SpellName(buff) or buff.key end
    end
    ns.Print("blessings you give in this raid: " .. (#covered > 0 and table.concat(covered, ", ") or "none")
        .. (R.RaidBlessingsChosen() and "" or " (all: you haven't chosen)"))
    if #words == 0 then
        ns.Print("/friendly blessings all | " .. table.concat(keys, " ") .. " - in a raid, until you leave it")
    end
end

local function MoveCommand()
    local unlock = not ns.db.buffBack.unlocked
    local ok, why = ns.BuffButton.SetUnlocked(unlock)
    if not ok then return ns.Print("can't move the buff-back button: " .. why) end
    ns.Print(unlock and "buff-back button unlocked: drag it, then /friendly move again to lock it."
        or "buff-back button locked where it is.")
end

local function ImportCommand(args)
    if args:lower() == "undo" then
        local ok, why = ns.Profiles.UndoImport()
        ns.Print(ok and "your settings from before the import are back." or ("couldn't undo: " .. why))
        ns.Options.Refresh()
        return
    end
    ns.ShowImport()
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
            local template = ns.Messages.Preview(ns.db[msgType].messages)
            local vars = {}
            for k, v in pairs(SAMPLE_VARS) do vars[k] = v end
            local text = template and ns.Util.Render(template, ns.Flavour.Vars(vars)) or "(no messages)"
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
        ns.Print("/friendly find <word> - which settings match, and the page each is on")
        ns.Print("/friendly status - what the addon has seen and sent this session")
        ns.Print("/friendly selftest - whisper yourself to check sending works")
        ns.Print("/friendly names - show how the game reports names")
        ns.Print("/friendly nameplates - show friendly player names, so casters can be named")
        ns.Print("/friendly debug - log every decision (shown here and saved to disk)")
        ns.Print("/friendly on | off | toggle - turn everything on or off")
        ns.Print("/friendly test - preview one message of each type (only you see it)")
        ns.Print("/friendly say - send a waiting buff thank-you now")
        ns.Print("/friendly minimap - show or hide the minimap button")
        ns.Print("/friendly snooze [minutes] | off - send nothing for a while (default 15 minutes)")
        ns.Print("/friendly ignore [name] - never greet or thank this player (or your target); no name lists them")
        ns.Print("/friendly unignore <name> - take a player off that list")
        ns.Print("/friendly ledger [count] | clear - who buffed you and whether you thanked them")
        ns.Print("/friendly profile [new | use | delete] <name> - switch between sets of settings")
        ns.Print("/friendly export | import [undo] - your settings as one line of text, to keep or share")
        ns.Print("/friendly report - status and debug log as text to copy into a bug report")
        ns.Print("/friendly buffback - what the buff-back button holds and why")
        ns.Print("/friendly move - unlock or lock the buff-back button to drag it")
        ns.Print("/friendly buffmode [on | off | key <key>] - lend a key (the mouse wheel) to the buff-back button")
        ns.Print("/friendly blessings [all | might wisdom ...] - paladins: the Blessings you give in this raid")
    end,
    profile = ProfileCommand,
    export = function() ns.ShowExport() end,
    import = ImportCommand,
    report = function() ns.ShowBugReport() end,
    buffback = BuffBackCommand,
    move = MoveCommand,
    buffmode = BuffModeCommand,
    blessings = BlessingsCommand,
    snooze = SnoozeCommand,
    ignore = IgnoreCommand,
    unignore = UnignoreCommand,
    ledger = LedgerCommand,
    find = function(args) ns.OptionsIndex.Command(args) end,
}

-- The command names, sorted (the README test checks each is documented).
function ns.SlashCommandNames()
    local names = {}
    for name in pairs(commands) do names[#names + 1] = name end
    table.sort(names)
    return names
end

SLASH_FRIENDLYFOREVER1 = "/friendly"
SLASH_FRIENDLYFOREVER2 = "/ffr"
SlashCmdList.FRIENDLYFOREVER = function(input)
    if not ns.db then
        ns.Print("not loaded. If you just updated the addon, restart the game (not /reload).")
        return
    end
    local cmd, args = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    local command = commands[cmd]
    if command then
        ns.Diag.Call(command, args or "")
    elseif cmd == "" then
        ns.Options.Open()
    else
        ns.Print("unknown command '" .. ns.Util.StripChat(cmd) .. "'. Type /friendly help")
    end
end
