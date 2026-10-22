-- A small simulation of the WoW client API, enough to load the addon exactly
-- as the game does (TOC order, (addonName, ns) varargs) and drive it with
-- events. It mirrors the real restrictions that matter to us: /say outside
-- instances needs a hardware event, chat is blocked during lockdown, sent
-- text may not contain "|" or exceed 255 bytes, and secret values exist.
local M = {}

M.ADDON_NAME = "FriendlyForever"
M.ROOT = debug.getinfo(1, "S").source:sub(2):match("^(.*)spec/support/wow%.lua$") or "./"

------------------------------------------------------------------------
-- Secret values
------------------------------------------------------------------------

-- Real secrets raise an error when addon code indexes, compares, measures
-- or does arithmetic on them. (Lua 5.1 can't intercept # on a table.) (A plain `if secret then` can't be made to error
-- in plain Lua: there it just counts as true, so tests check that code never
-- acts on a secret instead.)
local function forbidden() error("attempted to use a secret value", 2) end
local SecretMT = {
    __tostring = function() return "<secret>" end,
    __index = forbidden, __newindex = forbidden, __call = forbidden,
    __eq = forbidden, __lt = forbidden, __le = forbidden,
    __add = forbidden, __sub = forbidden, __mul = forbidden, __div = forbidden, __unm = forbidden,
}

function M.secret(value)
    return setmetatable({ value = value }, SecretMT)
end

local function isSecret(v)
    return type(v) == "table" and getmetatable(v) == SecretMT
end

-- An aura as a locked event payload: secret, but its instance ID readable
-- (auraInstanceID is NeverSecret in the real API).
function M.lockedAura(id)
    return setmetatable({ auraInstanceID = id }, SecretMT)
end

------------------------------------------------------------------------
-- Frames
------------------------------------------------------------------------

local methods = {}
local function noop() end
-- Unknown widget API methods (capitalised, e.g. SetJustifyH) are accepted as
-- no-ops; unset data fields (lowercase) stay nil so tests can't be fooled.
local FrameMT = {
    __index = function(_, key)
        if methods[key] then return methods[key] end
        if type(key) == "string" and key:find("^%u") then return noop end
        return nil
    end,
}

function M.newFrame(kind, name, parent)
    local f = setmetatable({
        kind = kind, name = name, parent = parent,
        events = {}, scripts = {}, shown = true, enabled = true, text = "",
    }, FrameMT)
    M.frames[#M.frames + 1] = f
    if name then _G[name] = f end
    return f
end

function methods:RegisterEvent(event) self.events[event] = true end
function methods:RegisterUnitEvent(event, ...) self.events[event] = { ... } end
function methods:UnregisterEvent(event) self.events[event] = nil end
function methods:IsEventRegistered(event) return self.events[event] ~= nil end
function methods:SetScript(name, fn) self.scripts[name] = fn end
function methods:GetScript(name) return self.scripts[name] end
function methods:Show() self.shown = true end
function methods:Hide() self.shown = false end
function methods:SetShown(on) self.shown = on and true or false end
function methods:IsShown() return self.shown end
-- Visible = shown, and every parent shown too.
function methods:IsVisible()
    local f = self
    while f do
        if not f.shown then return false end
        f = f.parent
    end
    return true
end
function methods:SetText(text)
    self.text = tostring(text)
    self.cursor = #self.text -- the game moves an edit box's cursor to the end
end
function methods:SetCursorPosition(pos) self.cursor = pos end
-- Keyboard focus: losing it runs OnEditFocusLost, as in the game.
function methods:SetFocus() self.focused = true end
function methods:HasFocus() return self.focused == true end
function methods:ClearFocus()
    if not self.focused then return end
    self.focused = false
    if self.scripts.OnEditFocusLost then self.scripts.OnEditFocusLost(self) end
end
function methods:GetText() return self.text end
function methods:SetChecked(on) self.checked = on and true or false end
function methods:GetChecked() return self.checked end
function methods:SetEnabled(on) self.enabled = on and true or false end
function methods:IsEnabled() return self.enabled end
function methods:SetSize(w, h) self.width, self.height = w, h end
function methods:SetWidth(w) self.width = w end
function methods:GetWidth() return self.width or 0 end
function methods:GetCenter() return self.centerX or 0, self.centerY or 0 end
function methods:GetEffectiveScale() return self.scale or 1 end
function methods:SetDesaturated(on) self.desaturated = on and true or false end
function methods:SetTexture(path) self.texture = path end
function methods:SetPoint(...) self.point = { ... } end
function methods:EnableKeyboard(on) self.keyboard = on and true or false end
function methods:SetPropagateKeyboardInput(on)
    if M.state.inCombat then error("SetPropagateKeyboardInput is protected in combat") end
    self.propagate = on and true or false
end
function methods:CreateFontString() return M.newFrame("FontString", nil, self) end
function methods:CreateTexture() return M.newFrame("Texture", nil, self) end
function methods:AddLine(text) self.lines = self.lines or {}; self.lines[#self.lines + 1] = text end

-- Run a frame script as the game would.
function M.run(frame, script, ...)
    local fn = frame.scripts[script]
    assert(fn, "no " .. script .. " script on frame")
    return fn(frame, ...)
end

function M.fire(event, ...)
    local snapshot = {}
    for i, f in ipairs(M.frames) do snapshot[i] = f end
    for _, f in ipairs(snapshot) do
        local reg = f.events[event]
        local matches = reg == true
        if type(reg) == "table" then
            for _, unit in ipairs(reg) do if unit == (...) then matches = true end end
        end
        if matches and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end

-- A real key press: the only thing that counts as a hardware event here.
function M.keyDown(key)
    M.hardware = true
    for _, f in ipairs(M.frames) do
        if f.keyboard and f.shown and f.scripts.OnKeyDown then f.scripts.OnKeyDown(f, key or "W") end
    end
    M.hardware = false
end

------------------------------------------------------------------------
-- Time
------------------------------------------------------------------------

function M.advance(seconds)
    local target = M.now + seconds
    while true do
        local nextIndex
        for i, t in ipairs(M.timers) do
            if t.at <= target and (not nextIndex or t.at < M.timers[nextIndex].at) then nextIndex = i end
        end
        if not nextIndex then break end
        local timer = table.remove(M.timers, nextIndex)
        if timer.at > M.now then M.now = timer.at end
        timer.fn()
    end
    M.now = target
end

------------------------------------------------------------------------
-- Chat
------------------------------------------------------------------------

local function SendChat(text, channel, _, target)
    if type(text) ~= "string" then error("SendChatMessage: text must be a string") end
    if channel == "WHISPER" and (type(target) ~= "string" or target == "") then
        error("SendChatMessage: whisper needs a target")
    end
    if #text > 255 then error("SendChatMessage: message too long") end
    if text:find("|") then error("SendChatMessage: invalid escape code in chat message") end
    local record = { text = text, channel = channel, target = target, time = M.now }
    if M.state.lockdown then
        M.blocked[#M.blocked + 1] = record
        return
    end
    if (channel == "SAY" or channel == "YELL") and not M.state.inInstance and not M.hardware then
        M.blocked[#M.blocked + 1] = record
        return
    end
    M.sent[#M.sent + 1] = record
end

------------------------------------------------------------------------
-- Units
------------------------------------------------------------------------

-- spec = { name, surname (UnitName's 2nd return), isPlayer (default true), hostile, inParty, inRaid, id }
function M.addUnit(token, spec)
    spec.id = spec.id or spec.name
    if spec.isPlayer == nil then spec.isPlayer = true end
    M.state.units[token] = spec
end

local function unitField(unit, field)
    local u = M.state.units[unit]
    if not u then return nil end
    local value = u[field]
    if M.state.unitsRestricted and value ~= nil then return M.secret(value) end
    return value
end

-- Wrap a unit query so it answers with a secret while units are restricted.
local function restricted(fn)
    return function(...)
        local result = fn(...)
        if M.state.unitsRestricted and result ~= nil then return M.secret(result) end
        return result
    end
end


------------------------------------------------------------------------
-- Reset / install
------------------------------------------------------------------------

local ADDON_GLOBALS = {
    "FriendlyForeverDB", "SLASH_FRIENDLYFOREVER1", "SLASH_FRIENDLYFOREVER2",
    "FriendlyForeverMinimapButton", "FriendlyForeverOptionsPanel",
}

function M.reset()
    M.now = 1000
    M.timers, M.frames, M.sent, M.blocked, M.printed = {}, {}, {}, {}, {}
    M.hardware = false
    M.rosterRequests = 0
    M.settings = { categories = {} }
    M.state = {
        inGuild = true, guildRoster = {},
        groupType = nil, groupMembers = {},
        inInstance = false, lockdown = false, inCombat = false,
        units = {}, cursorX = 0, cursorY = 0,
        playerAuras = {}, aurasRestricted = false,
        cvars = { nameplateShowFriendlyPlayers = "1", nameplateShowOnlyNameForFriendlyPlayerUnits = "0" },
    }
    M.addUnit("player", { name = "Me" })
    for _, g in ipairs(ADDON_GLOBALS) do _G[g] = nil end

    _G.GetTime = function() return M.now end
    _G.C_Timer = {
        After = function(delay, fn)
            assert(type(delay) == "number" and delay >= 0, "C_Timer.After: bad delay")
            M.timers[#M.timers + 1] = { at = M.now + delay, fn = fn }
        end,
    }
    _G.issecretvalue = isSecret
    _G.issecrettable = nil
    _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

    _G.UIParent = M.newFrame("Frame", "UIParent")
    _G.Minimap = M.newFrame("Frame", "Minimap")
    _G.Minimap.width = 140
    _G.GameTooltip = M.newFrame("GameTooltip", "GameTooltip")
    _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) M.printed[#M.printed + 1] = msg end }
    _G.CreateFrame = function(kind, name, parent) return M.newFrame(kind, name, parent) end
    _G.SlashCmdList = {}

    _G.C_ChatInfo = {
        SendChatMessage = SendChat,
        InChatMessagingLockdown = function() return M.state.lockdown end,
    }
    _G.SendChatMessage = SendChat

    _G.ERR_FRIEND_ONLINE_SS = "|Hplayer:%s|h[%s]|h has come online."
    _G.ERR_GUILD_JOIN_S = "%s has joined the guild."
    _G.ERR_JOINED_GROUP_S = "%s joins the party."
    _G.ERR_RAID_MEMBER_ADDED_S = "%s has joined the raid group."
    _G.ERR_INSTANCE_GROUP_ADDED_S = "%s has joined the instance group."
    _G.ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
    _G.LE_PARTY_CATEGORY_HOME = 1
    _G.LE_PARTY_CATEGORY_INSTANCE = 2

    _G.UnitName = function(unit) return unitField(unit, "name"), unitField(unit, "surname") end
    _G.UnitFullName = function(unit) return unitField(unit, "name"), unitField(unit, "surname") end
    _G.GetUnitName = function(unit) return unitField(unit, "name") end
    _G.UnitIsPlayer = function(unit) return unitField(unit, "isPlayer") end
    _G.UnitIsUnit = restricted(function(a, b)
        local ua, ub = M.state.units[a], M.state.units[b]
        return ua ~= nil and ub ~= nil and ua.id == ub.id
    end)
    _G.UnitCanAttack = restricted(function(_, unit)
        local u = M.state.units[unit]
        return u and u.hostile or false
    end)
    -- Like the real client: these answer for unit tokens only. Passing a name
    -- in the addon's "First-Surname" form gets "not in group" (seen in-game).
    _G.UnitInParty = restricted(function(unit)
        local u = M.state.units[unit]
        if not u then return false end
        if u.inParty ~= nil then return u.inParty end
        return M.state.groupType ~= nil and M.state.groupMembers[u.id] == true
    end)
    _G.UnitInRaid = restricted(function(unit)
        local u = M.state.units[unit]
        if not u then return nil end
        if u.inRaid ~= nil then return u.inRaid end
        if M.state.groupType == "raid" and M.state.groupMembers[u.id] then return 1 end
        return nil
    end)
    _G.UnitExists = restricted(function(unit) return M.state.units[unit] ~= nil end)
    _G.IsInGroup = function(category)
        if category == _G.LE_PARTY_CATEGORY_INSTANCE then return M.state.groupType == "instance" end
        return M.state.groupType ~= nil
    end
    _G.IsInRaid = function() return M.state.groupType == "raid" end
    -- state.isLeader: I lead. state.leader: full name of the group member who does.
    _G.UnitIsGroupLeader = restricted(function(unit)
        if M.state.groupType == nil then return false end
        if unit == "player" then return M.state.isLeader == true end
        local u = M.state.units[unit]
        return u ~= nil and M.state.leader ~= nil and u.id == M.state.leader
    end)
    _G.IsInInstance = function() return M.state.inInstance, M.state.inInstance and "party" or "none" end
    _G.InCombatLockdown = function() return M.state.inCombat end

    _G.IsInGuild = function() return M.state.inGuild end
    _G.GetNumGuildMembers = function() return #M.state.guildRoster end
    _G.GetGuildRosterInfo = function(i) return M.state.guildRoster[i] end
    _G.C_GuildInfo = { GuildRoster = function() M.rosterRequests = M.rosterRequests + 1 end }

    _G.GetCursorPosition = function() return M.state.cursorX, M.state.cursorY end
    _G.date = function() return "12:00:00" end
    -- Game settings. Unknown names return nil; nameplate settings are locked in combat.
    _G.C_CVar = {
        GetCVar = function(name) return M.state.cvars[name] end,
        SetCVar = function(name, value)
            if M.state.inCombat and name:find("^nameplate") then error("can't change nameplates in combat") end
            if M.state.cvars[name] == nil then return false end
            M.state.cvars[name] = tostring(value)
            M.cvarWrites[#M.cvarWrites + 1] = name .. "=" .. tostring(value)
            return true
        end,
    }
    M.cvarWrites = {}
    M.errors = {}
    _G.geterrorhandler = function() return function(err) M.errors[#M.errors + 1] = err end end
    _G.C_AddOns = {
        GetAddOnMetadata = function(name, field)
            if name ~= M.ADDON_NAME then return nil end
            return (M.parseToc())[field]
        end,
    }
    -- Aura queries raise an error while auras are restricted, as on 12.1+.
    _G.C_UnitAuras = {
        GetAuraDataByIndex = function(unit, index)
            if M.state.aurasRestricted then error("aura data is restricted") end
            if unit ~= "player" then return nil end
            local helpful = {}
            for _, a in ipairs(M.state.playerAuras) do
                if a.isHelpful == true then helpful[#helpful + 1] = a end
            end
            return helpful[index]
        end,
        GetAuraDataByAuraInstanceID = function(unit, id)
            if M.state.aurasRestricted then error("aura data is restricted") end
            if unit ~= "player" then return nil end
            local override = M.state.queryOverride and M.state.queryOverride[id]
            if override then return override end
            for _, a in ipairs(M.state.playerAuras) do
                if a.auraInstanceID == id then return a end
            end
        end,
    }

    _G.Settings = {
        RegisterCanvasLayoutCategory = function(panel, name)
            return { panel = panel, name = name, GetID = function() return 4242 end }
        end,
        RegisterAddOnCategory = function(category)
            M.settings.categories[#M.settings.categories + 1] = category
        end,
        OpenToCategory = function(id) M.settings.opened = id end,
    }
end

------------------------------------------------------------------------
-- Loading the addon
------------------------------------------------------------------------

function M.readFile(path)
    local f = assert(io.open(M.ROOT .. path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

-- Parses the TOC: returns metadata table and the ordered file list.
function M.parseToc()
    local meta, files = {}, {}
    for line in M.readFile(M.ADDON_NAME .. ".toc"):gmatch("[^\r\n]+") do
        local key, value = line:match("^##%s*([%w%-_]+)%s*:%s*(.-)%s*$")
        if key then
            meta[key] = value
        elseif not line:match("^#") and line:match("%S") then
            files[#files + 1] = (line:gsub("\\", "/"):gsub("^%s+", ""):gsub("%s+$", ""))
        end
    end
    return meta, files
end

function M.load()
    local ns = {}
    local _, files = M.parseToc()
    for _, file in ipairs(files) do
        local chunk = assert(loadfile(M.ROOT .. file))
        chunk(M.ADDON_NAME, ns)
    end
    return ns
end

-- Fresh client, addon loaded, logged in and past the login grace period.
-- opts.db: saved variables to start with. opts.noGrace: stop after login.
function M.boot(opts)
    opts = opts or {}
    M.reset()
    if opts.before then opts.before(M.state) end
    _G.FriendlyForeverDB = opts.db
    local ns = M.load()
    ns.Messages.random = function() return 1 end
    M.fire("ADDON_LOADED", M.ADDON_NAME)
    M.fire("PLAYER_ENTERING_WORLD", true, false)
    if not opts.noGrace then M.advance(ns.Announcer.LOGIN_GRACE) end
    return ns
end

------------------------------------------------------------------------
-- Event helpers
------------------------------------------------------------------------

-- Put players in your group the way the game does: in party1..4 (or
-- raid1..40) slots, with UnitName returning first name and surname apart.
-- names are full names ("Sorum-Md"). groupType: "party", "raid", "instance".
function M.setGroup(groupType, names)
    for token in pairs(M.state.units) do
        if token:find("^party%d") or token:find("^raid%d") then M.state.units[token] = nil end
    end
    M.state.groupType = groupType
    M.state.groupMembers = {}
    local prefix = groupType == "raid" and "raid" or "party"
    for i, full in ipairs(names or {}) do
        local first, last = full:match("^([^%-]+)%-(.+)$")
        M.state.groupMembers[full] = true
        M.addUnit(prefix .. i, { name = first or full, surname = last, id = full })
    end
end

function M.systemMessage(text)
    M.fire("CHAT_MSG_SYSTEM", text)
end

local nextAuraId = 1
-- aura fields override the defaults of a helpful buff cast by a player.
function M.gainBuff(aura)
    aura = aura or {}
    local full = { isHelpful = true, isFromPlayerOrPlayerPet = true, auraInstanceID = nextAuraId }
    nextAuraId = nextAuraId + 1
    for k, v in pairs(aura) do full[k] = v end
    M.state.playerAuras[#M.state.playerAuras + 1] = full
    M.fire("UNIT_AURA", "player", { addedAuras = { full } })
    return full
end

function M.gainBuffs(auras)
    local list = {}
    for i, aura in ipairs(auras) do
        local full = { isHelpful = true, isFromPlayerOrPlayerPet = true, auraInstanceID = nextAuraId }
        nextAuraId = nextAuraId + 1
        for k, v in pairs(aura) do full[k] = v end
        list[i] = full
        M.state.playerAuras[#M.state.playerAuras + 1] = full
    end
    M.fire("UNIT_AURA", "player", { addedAuras = list })
end

function M.sentTo(channel)
    local out = {}
    for _, s in ipairs(M.sent) do
        if s.channel == channel then out[#out + 1] = s.text end
    end
    return out
end

M.reset()
return M
