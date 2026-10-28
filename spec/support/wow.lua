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
-- Secure (protected) frames can't be shown, hidden or changed in combat.
local function guardProtected(frame, what)
    if frame.protected and M.state.inCombat then error(what .. " on a protected frame in combat") end
end
function methods:Show() guardProtected(self, "Show"); self.shown = true end
function methods:Hide() guardProtected(self, "Hide"); self.shown = false end
function methods:SetShown(on) guardProtected(self, "SetShown"); self.shown = on and true or false end
function methods:SetAttribute(key, value)
    guardProtected(self, "SetAttribute")
    self.attributes = self.attributes or {}
    self.attributes[key] = value
end
function methods:GetAttribute(key) return self.attributes and self.attributes[key] end
function methods:RegisterForClicks(...) self.clicks = { ... } end
function methods:SetAlpha(a) self.alpha = a end
function methods:GetAlpha() return self.alpha or 1 end
function methods:IsShown() return self.shown end
-- Visible = shown, and every parent shown too. (A string in .parent is the
-- old options API's parent category name, not a frame.)
function methods:IsVisible()
    local f = self
    while type(f) == "table" do
        if not f.shown then return false end
        f = f.parent
    end
    return true
end
-- An edit box keeps at most its max letters (SetMaxLetters; 0 or unset:
-- no limit), cutting longer text as the game does. Counted in bytes here,
-- which for the ASCII the specs use is the same.
function methods:SetMaxLetters(n) self.maxLetters = n end
function methods:GetMaxLetters() return self.maxLetters or 0 end
function methods:SetText(text)
    self.text = tostring(text)
    if self.maxLetters and self.maxLetters > 0 then self.text = self.text:sub(1, self.maxLetters) end
    self.cursor = #self.text -- the game moves an edit box's cursor to the end
end
function methods:SetCursorPosition(pos) self.cursor = pos end
-- Keyboard focus: one edit box at a time, as in the game. Focusing a box
-- takes focus from the last one; gaining focus runs OnEditFocusGained and
-- losing it OnEditFocusLost.
function methods:SetFocus()
    if M.focusedBox == self then return end
    if M.focusedBox then M.focusedBox:ClearFocus() end
    M.focusedBox = self
    if self.scripts.OnEditFocusGained then self.scripts.OnEditFocusGained(self) end
end
function methods:HasFocus() return M.focusedBox == self end
function methods:ClearFocus()
    if M.focusedBox ~= self then return end
    M.focusedBox = nil
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
-- point, relativeTo, relativePoint, x, y (as SetPoint was given them).
function methods:GetPoint()
    local p = self.point
    if not p then return nil end
    return p[1], p[2], p[3], p[4], p[5]
end
function methods:EnableKeyboard(on) self.keyboard = on and true or false end
function methods:EnableMouseWheel(on) self.mouseWheel = on and true or false end
function methods:EnableMouse(on) self.mouse = on and true or false end
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
    -- state.keyClearsAFK: the press brings me back from AFK before any addon sees it.
    if M.state.keyClearsAFK then M.state.afk = false end
    for _, f in ipairs(M.frames) do
        if f.keyboard and f.shown and f.scripts.OnKeyDown then f.scripts.OnKeyDown(f, key or "W") end
    end
    M.hardware = false
end

-- The mouse wheel over the game: frames listening for it (EnableMouseWheel)
-- get OnMouseWheel(delta), 1 up and -1 down; otherwise the key it is bound to
-- acts (pressKey). A hardware event, like a key press.
function M.wheel(delta)
    for _, f in ipairs(M.frames) do
        if f.mouseWheel and f.shown and f.scripts.OnMouseWheel then
            M.hardware = true
            f.scripts.OnMouseWheel(f, delta)
            M.hardware = false
            return
        end
    end
    M.pressKey(delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN")
end

-- A key (or wheel) bound in the game: an override binding (SetOverrideBindingClick)
-- presses its button; otherwise the key's own action happens, recorded in
-- M.keyActions as { key, action } (state.bindings[key], or "default").
function M.pressKey(key)
    local override = M.state.overrides[key]
    if override then
        local target = _G[override.button]
        if target then M.press(target, override.mouseButton) end
        return
    end
    M.keyActions[#M.keyActions + 1] = { key = key, action = M.state.bindings[key] or "default" }
end

------------------------------------------------------------------------
-- Spells and secure buttons
------------------------------------------------------------------------

-- Names of the buff spells the specs use, by ID. Kept apart from the addon's
-- own table (BuffData.lua) so the specs check it rather than echo it.
M.SPELL_NAMES = {}
local function nameSpell(name, ids) for _, id in ipairs(ids) do M.SPELL_NAMES[id] = name end end
nameSpell("Mark of the Wild", { 9885, 9884, 8907, 5234, 6756, 5232, 1126 })
nameSpell("Gift of the Wild", { 21850, 21849 })
nameSpell("Thorns", { 9910, 9756, 8914, 1075, 782, 467 })
nameSpell("Arcane Intellect", { 10157, 10156, 1461, 1460, 1459 })
nameSpell("Arcane Brilliance", { 23028 })
nameSpell("Power Word: Fortitude", { 10938, 10937, 2791, 1245, 1244, 1243 })
nameSpell("Divine Spirit", { 27841, 14819, 14818, 14752 })
nameSpell("Shadow Protection", { 10958, 10957, 976 })
nameSpell("Blessing of Kings", { 20217 })
nameSpell("Blessing of Might", { 25291, 19838, 19837, 19836, 19835, 19834, 19740 })
nameSpell("Blessing of Wisdom", { 25290, 19854, 19853, 19852, 19850, 19742 })
nameSpell("Battle Shout", { 25289, 11551, 11550, 11549, 6192, 5242, 6673 })
-- Forever's Revoke (paladins). Its real ID isn't known yet (#50): this one
-- is the simulation's own, and the addon finds Revoke by name.
M.REVOKE_ID = 990001
nameSpell("Revoke", { M.REVOKE_ID })

------------------------------------------------------------------------
-- ASSUMPTIONS ABOUT WOW FOREVER, to check in game. Each is a state setting
-- so specs can try the alternatives; the defaults are guesses, not facts.
--   state.targetNameForm  how /target and /targetexact spell a two-part
--                         name: "space" ("Nikki Shifts", default) or "hyphen"
--   state.sentTargetForm  what UNIT_SPELLCAST_SENT gives as the target:
--                         "first" (default), "full" or "none"
--   state.cvars.ActionButtonUseKeyDown  "1" (default): secure buttons act
--                         on key down; "0": on key up
--   /cleartarget then /targetexact X leaves your old target as the "last
--                         target", so /targetlasttarget brings it back (setTarget)
--   Mouse clicks, like key presses, act on the half the key-down setting
--                         picks (Blizzard's 10.x template may act on the up half
--                         for mouse clicks; the addon re-arms on both halves)
--   Text emotes need a key press outdoors, like /say (see PerformEmote).
--   state.errorBeforeFailed  a refused cast's error text (UI_ERROR_MESSAGE)
--                         comes before UNIT_SPELLCAST_FAILED instead of after
--                         (default false); the addon accepts either order
--   state.castLandsOn     a unit token: casts go to that unit instead of your
--                         target (a test hook for "the cast went to someone
--                         else"; nil by default)
--   Override bindings (SetOverrideBindingClick, ClearOverrideBindings) are
--                         blocked in combat, and allowed in PLAYER_REGEN_DISABLED's
--                         handlers (as secure frames are). state.unbindable[key]:
--                         the game rejects that key (an error here).
--   unit.secrets = { name = true, pvp = true, auras = true }: that one unit's
--                         name, PvP flag or buffs read as secrets (as for a
--                         stranger in a restricted moment); role and mainTank
--                         likewise for its group role and Main Tank assignment.
--   C_Spell.GetSpellInfo(name) and GetSpellTexture(name) answer only for a
--                         spell you know (likewise GetSpellInfo(name)), as the
--                         game's name lookup goes through your spellbook; by
--                         ID it answers for any spell. Revoke has a made-up
--                         ID here (M.REVOKE_ID): Forever's is checked at launch.
--   UnitGroupRolesAssigned and GetPartyAssignment("MAINTANK") both exist and
--                         answer for group units (unit.role, unit.mainTank;
--                         Main Tank answers false outside a raid);
--                         which of them Forever has is checked at launch (#50).
--   UnitInRange(unit) answers inRange, checkedRange for group units (unit
--                         fields outOfRange, rangeUnknown); in a raid, setGroup
--                         leaves your own raid slot out (the game puts you in
--                         one), so specs add it when they need it.
--   state.castLatency     seconds before the server answers a cast
--                         (SUCCEEDED or FAILED and its error text); 0 (default)
--                         answers inside the press. SENT is always at once.
--   /targetexact skips the "target" token: a player known only as your
--                         target can't be found by name after /cleartarget
--                         (the pessimistic choice; the real client may find them).
--   A secret value used as a table key reads as missing (byAuraId[secret]
--                         is nil); the real client may raise an error instead,
--                         which the addon's callers also survive.
------------------------------------------------------------------------

local function targetableName(u)
    if not u.surname then return u.name end
    return u.name .. (M.state.targetNameForm == "hyphen" and "-" or " ") .. u.surname
end

-- /target matches the start of a name, /targetexact the whole name (both
-- ignoring case), over every unit the client knows, players or not. The
-- first match in token order wins.
local function targetByName(text, exact)
    text = text:lower()
    local tokens = {}
    for token in pairs(M.state.units) do tokens[#tokens + 1] = token end
    table.sort(tokens)
    for _, token in ipairs(tokens) do
        local u = M.state.units[token]
        local name = targetableName(u):lower()
        if token ~= "target" and token ~= "player" and (exact and name == text or not exact and name:sub(1, #text) == text) then
            return u
        end
    end
end

-- Targeting as the game does it: the old target becomes the "last target"
-- (if there was one).
local function setTarget(u)
    if M.state.units.target then M.state.lastTarget = M.state.units.target end
    M.state.units.target = u
end

-- The highest known rank of a spell name, or nil.
local function knownRank(name)
    local best
    for id, n in pairs(M.SPELL_NAMES) do
        if n == name and M.state.knownSpells[id] and (not best or id > best) then best = id end
    end
    return best
end

-- Macro conditions on the current target: help (friendly), nodead.
local CONDITIONS = {
    help = function(t) return t ~= nil and not t.hostile end,
    nodead = function(t) return t ~= nil and not t.dead end,
}
local function conditionsHold(list)
    for cond in list:gmatch("[^,%s]+") do
        local check = CONDITIONS[cond]
        if not check then error("the simulated client doesn't know the macro condition " .. cond) end
        if not check(M.state.units.target) then return false end
    end
    return true
end

local castCount = 0
local function cast(args)
    local conds, name = args:match("^%[(.-)%]%s*(.+)$")
    if conds then
        if not conditionsHold(conds) then return end
    else
        name = args
    end
    local id = knownRank(name)
    if not id then
        M.uiError("Unknown spell")
        return
    end
    -- A helpful spell with no friendly target lands on yourself.
    local target = M.state.units.target
    if not (target and not target.hostile) then target = M.state.units.player end
    local elsewhere = M.state.castLandsOn and M.state.units[M.state.castLandsOn]
    if elsewhere then target = elsewhere end
    local failure = M.state.castFailures[target.id]
    castCount = castCount + 1
    local guid = "Cast-" .. castCount
    local form = M.state.sentTargetForm
    local sentTo = ""
    if form == "first" then
        sentTo = target.name
    elseif form == "full" then
        sentTo = target.surname and (target.name .. " " .. target.surname) or target.name
    end
    M.fire("UNIT_SPELLCAST_SENT", "player", sentTo, guid, id)
    local record = { spell = name, id = id, target = target.id, failed = failure,
        targetDead = target.dead or nil, targetHostile = target.hostile or nil }
    M.casts[#M.casts + 1] = record
    -- Helping a player flagged for PvP flags you too (as things stand when
    -- the cast goes out).
    local flags = not failure and target.pvp and target ~= M.state.units.player and not M.state.pvp
    -- The server's answer: at once, or after state.castLatency seconds.
    local function answer()
        if failure then
            if M.state.errorBeforeFailed then M.uiError(failure) end
            M.fire("UNIT_SPELLCAST_FAILED", "player", guid, id)
            if not M.state.errorBeforeFailed then M.uiError(failure) end
            return
        end
        if flags then
            M.state.pvp = true
            M.flaggedBy[#M.flaggedBy + 1] = target.id
        end
        M.fire("UNIT_SPELLCAST_SUCCEEDED", "player", guid, id)
    end
    local latency = M.state.castLatency or 0
    if latency > 0 then
        _G.C_Timer.After(latency, answer)
    else
        answer()
    end
end

function M.uiError(message)
    M.fire("UI_ERROR_MESSAGE", 0, message)
end

-- Run a macro's lines as the game would, inside one key press. (255 is the
-- addon's own limit for its macros, checked here too.)
function M.runMacro(text)
    assert(#text <= 255, "macro longer than 255 characters: " .. #text)
    for line in text:gmatch("[^\n]+") do
        local cmd, rest = line:match("^(/%S+)%s*(.-)%s*$")
        if cmd == "/target" or cmd == "/tar" or cmd == "/targetexact" then
            local u = targetByName(rest, cmd == "/targetexact")
            if u then setTarget(u) end
        elseif cmd == "/targetlasttarget" then
            local last = M.state.lastTarget
            if last then setTarget(last) end
        elseif cmd == "/cleartarget" then
            if M.state.units.target then M.state.lastTarget = M.state.units.target end
            M.state.units.target = nil
        elseif cmd == "/cast" then
            cast(rest)
        elseif cmd == "/s" or cmd == "/say" then
            _G.SendChatMessage(rest, "SAY")
        else
            error("the simulated client doesn't know " .. tostring(cmd))
        end
    end
end

-- The modifier prefix for an attribute lookup ("shift-", "ctrl-shift-"...).
local function modifierPrefix(mods)
    local out = ""
    for _, m in ipairs({ "alt", "ctrl", "shift" }) do
        if mods and mods[m] then out = out .. m .. "-" end
    end
    return out
end

-- Blizzard's secure attribute lookup (SecureButton_GetModifiedAttribute):
-- prefix..name..suffix, "*"..name..suffix, prefix..name.."*",
-- "*"..name.."*", then name alone.
function M.modifiedAttribute(button, name, mouseButton, mods)
    local a = button.attributes or {}
    local suffix = ({ LeftButton = "1", RightButton = "2", MiddleButton = "3" })[mouseButton] or mouseButton
    local prefix = modifierPrefix(mods)
    for _, key in ipairs({ prefix .. name .. suffix, "*" .. name .. suffix, prefix .. name .. "*",
        "*" .. name .. "*", name }) do
        if a[key] ~= nil then return a[key] end
    end
end

local function registeredFor(button, mouseButton, isDown)
    local half = isDown and "Down" or "Up"
    for _, kind in ipairs(button.clicks or {}) do
        if kind == "Any" .. half or kind == mouseButton .. half then return true end
    end
    return false
end

-- One half of a press: the scripts run if the button is registered for it,
-- and the secure action runs on the half the key-down setting chooses.
local function pressHalf(button, mouseButton, isDown, mods)
    if not registeredFor(button, mouseButton, isDown) then return end
    if button.scripts.PreClick then button.scripts.PreClick(button, mouseButton, isDown) end
    local actsOnDown = M.state.cvars.ActionButtonUseKeyDown ~= "0"
    if button.protected and isDown == actsOnDown then
        if M.modifiedAttribute(button, "type", mouseButton, mods) == "macro" then
            local text = M.modifiedAttribute(button, "macrotext", mouseButton, mods)
            if text then M.runMacro(text) end
        end
    end
    if button.scripts.OnClick then button.scripts.OnClick(button, mouseButton, isDown) end
    if button.scripts.PostClick then button.scripts.PostClick(button, mouseButton, isDown) end
end

-- A press of a button by a key binding or the mouse: the down half, then the
-- up half. mouseButton defaults to "LeftButton"; mods = { shift = true, ... }.
function M.press(button, mouseButton, mods)
    mouseButton = mouseButton or "LeftButton"
    M.hardware = true
    pressHalf(button, mouseButton, true, mods)
    pressHalf(button, mouseButton, false, mods)
    M.hardware = false
end

-- Combat as the game starts and ends it: PLAYER_REGEN_DISABLED fires just
-- before lockdown begins, so its handlers may still change secure frames.
function M.enterCombat()
    M.fire("PLAYER_REGEN_DISABLED")
    M.state.inCombat = true
end

function M.leaveCombat()
    M.state.inCombat = false
    M.fire("PLAYER_REGEN_ENABLED")
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
    if value ~= nil and (M.state.unitsRestricted or (u.secrets and u.secrets[field])) then return M.secret(value) end
    return value
end

-- "<unit>target" resolves to the unit that unit targets: spec.target holds
-- its token ("player"). spec.targetUnreadable makes the answer a secret.
local function resolveUnit(token)
    local u = M.state.units[token]
    if u or type(token) ~= "string" then return u end
    local base = token:match("^(.+)target$")
    local owner = base and M.state.units[base]
    return owner and owner.target and M.state.units[owner.target] or nil
end

local function targetUnreadable(token)
    local base = type(token) == "string" and not M.state.units[token] and token:match("^(.+)target$")
    local owner = base and M.state.units[base]
    return owner and owner.targetUnreadable == true or false
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
-- Guild roster
------------------------------------------------------------------------

-- state.guildRoster is the roster the client has cached. With "Show Offline
-- Members" off (state.showOffline == false) it lists only members not in
-- state.guildOffline, as the guild frame does.
function M.visibleRoster()
    local out = {}
    for _, name in ipairs(M.state.guildRoster) do
        if M.state.showOffline ~= false or not M.state.guildOffline[name] then out[#out + 1] = name end
    end
    return out
end

-- A roster update carrying this snapshot. Updates can be stale or arrive out
-- of order (other addons and the guild frame request them too), so the
-- snapshot may be older than what the client last showed.
function M.rosterUpdate(names)
    local copy = {}
    for i, name in ipairs(names) do copy[i] = name end
    M.state.guildRoster = copy
    M.fire("GUILD_ROSTER_UPDATE")
end

-- A roster update that arrives after `delay` seconds. Queue several with
-- different delays to deliver them out of order.
function M.queueRosterUpdate(names, delay)
    _G.C_Timer.After(delay, function() M.rosterUpdate(names) end)
end

------------------------------------------------------------------------
-- Reset / install
------------------------------------------------------------------------

local ADDON_GLOBALS = {
    "FriendlyForeverDB", "SLASH_FRIENDLYFOREVER1", "SLASH_FRIENDLYFOREVER2",
    "FriendlyForeverMinimapButton", "FriendlyForeverOptionsPanel", "FriendlyForeverTextWindow",
    "FriendlyForeverBuffButton", "BINDING_NAME_CLICK FriendlyForeverBuffButton:LeftButton",
    "BINDING_NAME_FRIENDLYFOREVER_BUFFMODE", "FriendlyForever_ToggleBuffMode",
}

function M.reset()
    M.now = 1000
    M.timers, M.frames, M.sent, M.blocked, M.printed = {}, {}, {}, {}, {}
    M.casts = {}
    M.keyActions = {}
    M.flaggedBy = {} -- players whose PvP flag a buff of yours caught (see cast)
    M.hardware = false
    M.focusedBox = nil
    M.rosterRequests = 0
    M.settings = { categories = {}, subcategories = {} }
    M.state = {
        inGuild = true, guildRoster = {},
        groupType = nil, groupMembers = {},
        inInstance = false, lockdown = false, inCombat = false,
        units = {}, cursorX = 0, cursorY = 0,
        playerAuras = {}, aurasRestricted = false,
        today = "2026-10-26", clock = 1793000000,
        knownSpells = {}, castFailures = {}, targetNameForm = "space", sentTargetForm = "first",
        -- overrides: [key] = { owner, button, mouseButton, priority } (SetOverrideBindingClick).
        -- bindings: [key] = the key's own binding action. mods: modifier keys held now.
        overrides = {}, bindings = {}, mods = {},
        race = "Human", class = "MAGE", faction = "Alliance", zone = "Elwynn Forest", hour = 14,
        cvars = { nameplateShowFriendlyPlayers = "1", nameplateShowOnlyNameForFriendlyPlayerUnits = "0",
            ActionButtonUseKeyDown = "1" },
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
    _G.UISpecialFrames = {}
    _G.Minimap = M.newFrame("Frame", "Minimap")
    _G.Minimap.width = 140
    _G.GameTooltip = M.newFrame("GameTooltip", "GameTooltip")
    _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) M.printed[#M.printed + 1] = msg end }
    _G.CreateFrame = function(kind, name, parent, template)
        local f = M.newFrame(kind, name, parent)
        f.template = template
        if type(template) == "string" and template:find("Secure") then f.protected = true end
        return f
    end
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
        local ua, ub = resolveUnit(a), resolveUnit(b)
        local same = ua ~= nil and ub ~= nil and ua.id == ub.id
        if targetUnreadable(a) or targetUnreadable(b) then return M.secret(same) end
        return same
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
        -- IsInGroup(nil) is any group, as in the game.
        if category ~= nil and category == _G.LE_PARTY_CATEGORY_INSTANCE then return M.state.groupType == "instance" end
        if category ~= nil and category == _G.LE_PARTY_CATEGORY_HOME then
            return M.state.groupType ~= nil and M.state.groupType ~= "instance"
        end
        return M.state.groupType ~= nil
    end
    _G.IsInRaid = function() return M.state.groupType == "raid" or (M.state.groupType == "instance" and M.state.raidSized == true) end
    -- state.isLeader: I lead. state.leader: full name of the group member who does.
    -- state.leaderUnreadable: other members' leadership reads as a secret.
    -- state.isLeaderUnreadable: so does mine.
    _G.UnitIsGroupLeader = restricted(function(unit)
        if M.state.groupType == nil then return false end
        if unit == "player" then
            if M.state.isLeaderUnreadable then return M.secret(M.state.isLeader == true) end
            return M.state.isLeader == true
        end
        if M.state.leaderUnreadable then return M.secret(false) end
        local u = M.state.units[unit]
        return u ~= nil and M.state.leader ~= nil and u.id == M.state.leader
    end)
    -- state.instanceType: "pvp" for a battleground (default "party").
    _G.IsInInstance = function() return M.state.inInstance, M.state.inInstance and (M.state.instanceType or "party") or "none" end
    _G.InCombatLockdown = function() return M.state.inCombat end
    -- Override bindings are protected: changing them in combat is blocked,
    -- here an error (the game blocks the call and blames the addon).
    _G.SetOverrideBindingClick = function(owner, isPriority, key, buttonName, mouseButton)
        if M.state.inCombat then error("SetOverrideBindingClick is protected in combat") end
        assert(type(owner) == "table" and type(key) == "string" and type(buttonName) == "string")
        if M.state.unbindable and M.state.unbindable[key] then error("invalid key: " .. key) end
        M.state.overrides[key] = { owner = owner, button = buttonName, mouseButton = mouseButton or "LeftButton",
            priority = isPriority and true or false }
    end
    _G.ClearOverrideBindings = function(owner)
        if M.state.inCombat then error("ClearOverrideBindings is protected in combat") end
        for key, o in pairs(M.state.overrides) do
            if o.owner == owner then M.state.overrides[key] = nil end
        end
    end
    _G.GetBindingAction = function(key) return M.state.bindings[key] or "" end
    _G.GetBindingText = function(key) return M.state.bindingText and M.state.bindingText[key] or key end
    _G.IsShiftKeyDown = function() return M.state.mods.shift == true end
    _G.IsControlKeyDown = function() return M.state.mods.ctrl == true end
    _G.IsAltKeyDown = function() return M.state.mods.alt == true end

    _G.IsInGuild = function() return M.state.inGuild end
    M.state.guildOffline = {}
    _G.GetNumGuildMembers = function() return #M.visibleRoster() end
    -- name, rank, rankIndex, level, class, zone, note, officerNote, online
    _G.GetGuildRosterInfo = function(i)
        local name = M.visibleRoster()[i]
        if name == nil then return nil end
        return name, "Member", 1, 60, "Warrior", "Elwynn Forest", "", "", not M.state.guildOffline[name]
    end
    -- state.rosterReplyDelay: answer a roster request with a roster update
    -- after that many seconds, as the server does.
    _G.C_GuildInfo = {
        GuildRoster = function()
            M.rosterRequests = M.rosterRequests + 1
            local delay = M.state.rosterReplyDelay
            if delay then _G.C_Timer.After(delay, function() M.fire("GUILD_ROSTER_UPDATE") end) end
        end,
    }
    -- state.afk: whether I'm AFK. Secret while units are restricted.
    _G.UnitIsAFK = restricted(function(unit) return unit == "player" and M.state.afk == true end)

    _G.GetCursorPosition = function() return M.state.cursorX, M.state.cursorY end
    -- state.today: what date("%Y-%m-%d") says; anything else is a clock time.
    _G.date = function(fmt)
        if fmt == "%Y-%m-%d" then return M.state.today end
        return "12:00:00"
    end
    -- Wall-clock seconds (time()), which moves with advance() like GetTime().
    _G.time = function() return M.state.clock + (M.now - 1000) end

    -- Who I am and where: state.race / state.class are the untranslated file
    -- names (UnitRace's and UnitClass's second returns); state.zone, state.hour,
    -- state.resting describe the moment. Other units read spec.race / spec.class.
    local CLASS_NAMES = {
        WARRIOR = "Warrior", MAGE = "Mage", PRIEST = "Priest", DRUID = "Druid", PALADIN = "Paladin",
        WARLOCK = "Warlock", ROGUE = "Rogue", HUNTER = "Hunter", SHAMAN = "Shaman",
    }
    -- state.raceId: UnitRace's third return (95 and 96 are Forever's Skyborne).
    _G.UnitRace = function(unit)
        local race = unit == "player" and M.state.race or unitField(unit, "race")
        if race == nil then return nil end
        return race, race, unit == "player" and M.state.raceId or nil
    end
    _G.UnitClass = function(unit)
        local class = unit == "player" and M.state.class or unitField(unit, "class")
        if class == nil then return nil end
        if M.state.unitsRestricted and unit ~= "player" then return class, class end
        return CLASS_NAMES[class] or class, class
    end
    _G.UnitFactionGroup = function(unit)
        if unit ~= "player" then return nil end
        return M.state.faction, M.state.faction
    end
    _G.GetRealZoneText = function() return M.state.zone end
    _G.GetZoneText = function() return M.state.zone end
    _G.GetGameTime = function() return M.state.hour, 0 end
    _G.IsResting = function() return M.state.resting == true end
    -- Text emotes: recorded in M.emotes. Like /say, they need a key press
    -- outdoors (an assumption the addon also makes, to be safe).
    M.emotes = {}
    local function PerformEmote(token, target)
        local record = { token = token, target = target, time = M.now }
        if not M.state.inInstance and not M.hardware then
            M.blockedEmotes[#M.blockedEmotes + 1] = record
            return true
        end
        M.emotes[#M.emotes + 1] = record
        return false
    end
    M.blockedEmotes = {}
    _G.C_ChatInfo.PerformEmote = PerformEmote

    -- Spells: state.knownSpells[id] = true for spells in my spellbook.
    _G.C_Spell = {
        GetSpellName = function(id) return M.SPELL_NAMES[id] end,
        -- By ID: any spell the client has. By name: only a spell you know
        -- (the game looks names up in your spellbook).
        GetSpellInfo = function(spell)
            local id = spell
            if type(spell) == "string" then id = knownRank(spell) end
            local name = id and M.SPELL_NAMES[id]
            if not name then return nil end
            return { name = name, spellID = id }
        end,
        -- By ID, or by name for a spell you know (as GetSpellInfo).
        GetSpellTexture = function(spell)
            local id = spell
            if type(spell) == "string" then id = knownRank(spell) end
            return id and M.SPELL_NAMES[id] and ("icon:" .. id) or nil
        end,
        -- Unit fields outOfSpellRange (the spell can't reach them) and
        -- spellRangeUnknown (the game won't say: nil).
        IsSpellInRange = function(_, unit)
            local u = M.state.units[unit]
            if not u or u.spellRangeUnknown then return nil end
            return not u.outOfSpellRange
        end,
    }
    _G.C_SpellBook = {
        IsSpellInSpellBook = function(id) return M.state.knownSpells[id] == true end,
    }
    _G.UnitIsDeadOrGhost = restricted(function(unit)
        local u = M.state.units[unit]
        return u ~= nil and u.dead == true
    end)
    -- Group members: unit fields outOfRange (true: out of range), rangeUnknown
    -- (the game can't tell), offline and hidden (not in sight / not visible).
    _G.UnitInRange = function(unit)
        local u = M.state.units[unit]
        if not u then return false, false end
        if u.rangeUnknown then return false, false end
        if M.state.unitsRestricted then return M.secret(not u.outOfRange), M.secret(true) end
        return not u.outOfRange, true
    end
    -- Group roles: unit.role ("TANK", "HEALER", "DAMAGER"; "NONE" when
    -- unset) and, in a raid, unit.mainTank (the Main Tank assignment).
    -- secrets.role / secrets.mainTank make that answer a secret.
    _G.UnitGroupRolesAssigned = function(unit)
        local u = M.state.units[unit]
        if not u then return "NONE" end
        local role = u.role or "NONE"
        if M.state.unitsRestricted or (u.secrets and u.secrets.role) then return M.secret(role) end
        return role
    end
    _G.GetPartyAssignment = function(assignment, unit)
        local u = M.state.units[unit]
        if not u then return false end
        -- A raid assignment: outside a raid nobody has it.
        local inRaid = M.state.groupType == "raid" or M.state.raidSized
        local is = assignment == "MAINTANK" and inRaid and u.mainTank == true
        if M.state.unitsRestricted or (u.secrets and u.secrets.mainTank) then return M.secret(is) end
        return is
    end
    _G.UnitIsConnected = restricted(function(unit)
        local u = M.state.units[unit]
        return u ~= nil and not u.offline
    end)
    _G.UnitIsVisible = restricted(function(unit)
        local u = M.state.units[unit]
        return u ~= nil and not u.hidden
    end)
    -- Everyone in your group, you included (0 when you're in none).
    _G.GetNumGroupMembers = function()
        if M.state.groupType == nil then return 0 end
        local n = 1
        for _ in pairs(M.state.groupMembers) do n = n + 1 end
        return n
    end
    _G.UnitIsPVP = restricted(function(unit)
        if unit == "player" then return M.state.pvp == true end
        local u = M.state.units[unit]
        if u and u.secrets and u.secrets.pvp then return M.secret(u.pvp == true) end
        return u ~= nil and u.pvp == true
    end)
    -- Game settings. Unknown names return nil; nameplate settings are locked in combat.
    _G.C_CVar = {
        GetCVar = function(name) return M.state.cvars[name] end,
        GetCVarBool = function(name)
            local v = M.state.cvars[name]
            if v == nil then return nil end
            return v == "1"
        end,
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
            if unit ~= "player" then
                -- Other players: spec.auras = { spellId, ... } (secret while units are restricted).
                local u = M.state.units[unit]
                local id = u and u.auras and u.auras[index]
                if id == nil then return nil end
                if M.state.unitsRestricted or (u.secrets and u.secrets.auras) then return M.secret({ spellId = id }) end
                -- spec.auraSources[index]: the unit token of who cast it, if the game says.
                return { spellId = id, isHelpful = true, sourceUnit = u.auraSources and u.auraSources[index] }
            end
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
        RegisterCanvasLayoutSubcategory = function(parent, panel, name)
            local sub = { panel = panel, name = name, parent = parent, GetID = function() return name end }
            M.settings.subcategories[#M.settings.subcategories + 1] = sub
            return sub
        end,
        OpenToCategory = function(id) M.settings.opened = id end,
    }
    -- The addon drop-down under the minimap. state.noCompartment: this client has none.
    M.compartment = {}
    _G.AddonCompartmentFrame = {
        RegisterAddon = function(_, info) M.compartment[#M.compartment + 1] = info end,
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

-- Buff mode's turn-on triggers, which boot switches off for most specs.
M.TURN_ON_TRIGGERS = { "autoOnJoin", "autoOnDeath", "autoOnBuffed" }

-- Fresh client, addon loaded, logged in and past the login grace period.
-- opts.db: saved variables to start with. opts.noGrace: stop after login.
-- opts.autoBuffMode: keep buff mode's turn-on triggers at their defaults (see below).
function M.boot(opts)
    opts = opts or {}
    M.reset()
    if opts.before then opts.before(M.state) end
    -- Which turn-on triggers the given settings set, read before loading
    -- fills in every default (see below).
    local triggersGiven = {}
    local givenBuffBack = type(opts.db) == "table" and type(opts.db.buffBack) == "table" and opts.db.buffBack
    if givenBuffBack then
        for _, field in ipairs(M.TURN_ON_TRIGGERS) do triggersGiven[field] = givenBuffBack[field] end
    end
    _G.FriendlyForeverDB = opts.db
    local ns = M.load()
    ns.Messages.random = function() return 1 end
    ns.Flavour.random = function() return 1 end
    M.fire("ADDON_LOADED", M.ADDON_NAME)
    -- Buff mode's turn-on triggers are on by default (#29), and would lend
    -- a key whenever a spec joins a group or a stranger buffs you. Most specs
    -- check buff back and buffing with buff mode as you leave it, so they
    -- start with the triggers off unless opts.db sets them. spec/
    -- buffmodeauto_spec.lua covers the triggers (opts.autoBuffMode keeps them).
    if not opts.autoBuffMode then
        for _, field in ipairs(M.TURN_ON_TRIGGERS) do
            if triggersGiven[field] == nil then ns.db.buffBack[field] = false end
        end
    end
    -- Most specs check behaviour, not wording, and were written against the
    -- casual lines: types still on the shipped defaults use those (fixed
    -- text). spec/flavour_spec.lua covers the shipped lines. opts.shippedLines
    -- keeps them.
    if not opts.shippedLines then
        for _, msgType in ipairs(ns.Config.TYPES) do
            local msgs, shipped = ns.db[msgType].messages, ns.DefaultMessages[msgType]
            local untouched = #msgs == #shipped
            for i = 1, #shipped do untouched = untouched and msgs[i] == shipped[i] end
            if untouched then
                local casual = {}
                for i, line in ipairs(ns.CasualMessages[msgType]) do casual[i] = line end
                ns.db[msgType].messages = casual
            end
        end
    end
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
-- raidSized: an instance group in raid slots, as battlegrounds are.
function M.setGroup(groupType, names, raidSized)
    for token in pairs(M.state.units) do
        if token:find("^party%d") or token:find("^raid%d") then M.state.units[token] = nil end
    end
    M.state.groupType = groupType
    M.state.raidSized = raidSized == true
    M.state.groupMembers = {}
    local prefix = (groupType == "raid" or M.state.raidSized) and "raid" or "party"
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
-- Default aura length, like a real buff just cast. Pass duration = 0 and
-- expirationTime = 0 for an aura with no duration.
M.AURA_DURATION = 1800
-- aura fields override the defaults of a helpful buff cast by a player.
function M.gainBuff(aura)
    aura = aura or {}
    local full = { isHelpful = true, isFromPlayerOrPlayerPet = true, auraInstanceID = nextAuraId }
    nextAuraId = nextAuraId + 1
    full.duration, full.expirationTime = M.AURA_DURATION, M.now + M.AURA_DURATION
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
        full.duration, full.expirationTime = M.AURA_DURATION, M.now + M.AURA_DURATION
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
