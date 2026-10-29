-- Favours you owe: players outside your group who buffed you, waiting for a
-- buff of yours back. The buff-back button (BuffButton.lua) shows the newest
-- one you can return and casts on a press; nothing here casts anything.
--
-- For each favour the buff is chosen fresh: your class's buffs you know, in
-- order, skipping ones that can't go to a stranger (Battle Shout, Salvation),
-- ones their class has no use for (Intellect to a warrior), and ones they
-- already wear when the game lets us see.
--
-- Safety: buffing a player flagged for PvP flags you too. A favour is offered
-- only when you are flagged yourself, or the game shows them right now (on a
-- nameplate, as your target, focus or under your mouse) and says they aren't
-- flagged. The flag is read each time the button is armed, which includes
-- the moment you press it; an earlier reading is never trusted, since anyone
-- can flag at any time.
--
-- Favours are kept in memory only: a /reload or logout forgets them.
--
-- One round each way (#37): every buff of yours the game says went to a
-- player (UNIT_SPELLCAST_SENT names them), from the button or cast by hand,
-- is remembered. Their buff back within RETURNED_RECENTLY answers yours, so
-- it isn't owed. A hand-cast buff that reaches someone you owe returns their
-- favour, as the button would. And when you return a favour, your copy tells
-- theirs over the hidden channel (Comm.lua) that this buff answers theirs,
-- so their copy doesn't owe you one back, however long the favour waited.
local _, ns = ...
local Util = ns.Util
local Read = Util.ReadGameValues

local Offers = {}
ns.Offers = Offers

Offers.MAX = 20                 -- favours kept at once; the oldest goes first
Offers.MAX_AURAS = 40           -- buffs read per player when checking what they wear
Offers.RETURNED_RECENTLY = 600  -- seconds after you buff someone that their buff back isn't a new one
Offers.MAX_NAMEPLATES = 40      -- nameplate tokens looked through for a player
Offers.MAX_REMEMBERED = 200     -- players whose buff from you is remembered at once; the oldest goes first
Offers.CAST_WAIT = 15           -- seconds a hand-cast buff of yours may take to land after it is sent
Offers.MAX_CASTS_WAITING = 8    -- hand-cast buffs remembered as sent; the oldest goes first
-- A copy's "this answers yours" mark and the buff it marks arrive apart, in
-- either order: they belong together within this many seconds.
Offers.MARK_SECONDS = 30
Offers.MAX_MARKS = 50           -- marks waiting for their buff at once; the oldest goes first

local favours = {}          -- newest last: { name, unit, class, owedAt, ledgerEntry }
local buffedAt = {}         -- [full name] = GetTime() a buff of yours last reached them
local marks = {}            -- [full name] = GetTime() their copy said their buff answers yours
local castsWaiting = {}     -- newest last: { guid, name, spell, at }, hand-cast buffs sent
local listeners = {}
local oweListeners = {}

-- Call fn() whenever the favours change (the buff-back button re-arms).
function Offers.OnChange(fn)
    listeners[#listeners + 1] = fn
end

-- Call fn() each time someone outside your group buffs you and is owed one
-- back (buff mode may turn on: BuffModeAuto.lua).
function Offers.OnOwe(fn)
    oweListeners[#oweListeners + 1] = fn
end

local function Changed()
    for _, fn in ipairs(listeners) do fn() end
end

local function IndexOf(name)
    for i, favour in ipairs(favours) do
        if favour.name == name then return i end
    end
end

-- Tokens that may show them, in the order they're checked: you can target
-- or mouse over them, and they may show on a nameplate (whose numbers the
-- game hands out afresh all the time).
local LOOKUP_TOKENS = { "target", "mouseover", "focus" }
for i = 1, Offers.MAX_NAMEPLATES do LOOKUP_TOKENS[#LOOKUP_TOKENS + 1] = "nameplate" .. i end

-- Who the game shows right now: [full name] = the unit tokens showing them.
-- Read once per check of the favours, not once per favour.
local function VisiblePlayers()
    local visible = {}
    for _, token in ipairs(LOOKUP_TOKENS) do
        local name = Util.UnitFullName(token)
        if name then
            visible[name] = visible[name] or {}
            table.insert(visible[name], token)
        end
    end
    return visible
end

-- The unit tokens that are them now: the one they were last seen under, and
-- any other showing them (the first becomes the one they were seen under).
-- Empty if none is.
local function LiveUnits(favour, visible)
    local units = {}
    if favour.unit and Util.UnitFullName(favour.unit) == favour.name then units[1] = favour.unit end
    for _, token in ipairs((visible or VisiblePlayers())[favour.name] or {}) do
        if token ~= units[1] then units[#units + 1] = token end
    end
    if units[1] then favour.unit = units[1] end
    return units
end

-- A unit token that is them right now (your target first), or nil.
function Offers.UnitFor(name)
    local units = VisiblePlayers()[name]
    return units and units[1] or nil
end

-- Read what we can about them now. Returns a unit token that is them (or
-- nil), and whether they're flagged for PvP: true if any token showing them
-- says so, false if every one says not, nil if none can say.
local function Observe(favour, visible)
    local units = LiveUnits(favour, visible)
    local unit = units[1]
    if not unit then return nil, nil end
    if not favour.class then favour.class = select(2, Util.UnitClassIf(unit, favour.name)) end
    local flagged
    for _, token in ipairs(units) do
        local pvp = Read(UnitIsPVP, token)
        if pvp == true then return unit, true end
        if pvp == false then flagged = false end
    end
    return unit, flagged
end

-- true / false whether the unit wears this buff (any rank, group version or
-- blocker), or nil when the game won't say (no unit, or hidden in a fight).
function Offers.Wears(unit, buff)
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not unit or not api then return nil end
    for i = 1, Offers.MAX_AURAS do
        local ok, aura = pcall(api, unit, i, "HELPFUL")
        if not ok or Util.IsSecret(aura) then return nil end
        if aura == nil then return false end
        local id = aura.spellId
        if Util.IsSecret(id) then return nil end
        if ns.BuffData.ForAura(id) == buff then return true end
    end
    return false
end

-- Room for name in a [name] = time table that holds at most limit: when it
-- is full, the oldest goes. Old entries otherwise stay until pushed out;
-- Within ignores them.
local function MakeRoom(times, name, limit)
    if times[name] then return end
    local count, oldest = 0, nil
    for who, at in pairs(times) do
        count = count + 1
        if not oldest or at < times[oldest] then oldest = who end
    end
    if count >= limit then times[oldest] = nil end
end

-- Whether the time at is at most maxAge seconds before now (never after it).
local function Within(at, maxAge, now)
    return at ~= nil and now >= at and now - at <= maxAge
end

-- Someone outside your group buffed you. unit: the token they were seen
-- under, if any; ledgerEntry: their ledger entry, marked when you return it.
function Offers.Owe(name, unit, ledgerEntry)
    local now = GetTime()
    local marked = Within(marks[name], Offers.MARK_SECONDS, now)
    if marked or Within(buffedAt[name], Offers.RETURNED_RECENTLY, now) then
        -- Their buff answers yours: owing it back would trade buffs forever.
        -- A mark answers one buff.
        if marked then marks[name] = nil end
        if ledgerEntry then ns.Ledger.NoteNotReturned(ledgerEntry, "it answered your buff to them") end
        ns.Diag.Log("buffBack", "not owing %s: their buff answers yours%s", name,
            marked and " (their copy said so)" or "")
        return
    end
    local i = IndexOf(name)
    if i then table.remove(favours, i) end
    local favour = { name = name, unit = unit, owedAt = now, ledgerEntry = ledgerEntry }
    Observe(favour)
    favours[#favours + 1] = favour
    while #favours > Offers.MAX do table.remove(favours, 1) end
    ns.Diag.Log("buffBack", "you owe %s a buff", name)
    Changed()
    for _, fn in ipairs(oweListeners) do fn() end
end

-- Forget favours older than the setting. Returns true if any went.
local function Expire(now)
    -- Read defensively: settings damaged mid-session mustn't stop the button.
    local limits = ns.Config.LIMITS.owedMinutes
    local minutes = Util.ClampNumber(ns.db.buffBack.owedMinutes, limits.min, limits.max,
        ns.Config.DEFAULTS.buffBack.owedMinutes)
    local limit = minutes * 60
    local any = false
    for i = #favours, 1, -1 do
        if now - favours[i].owedAt > limit then
            local favour = table.remove(favours, i)
            if favour.ledgerEntry then
                ns.Ledger.NoteNotReturned(favour.ledgerEntry, "the time to return it ran out")
            end
            any = true
        end
    end
    return any
end

-- The buff to give this favour, or nil and why not.
local function ChooseBuff(favour, myBuffs, visible)
    local unit, flagged = Observe(favour, visible)
    if unit and Read(UnitIsDeadOrGhost, unit) == true then return nil, "they're dead" end
    if Read(UnitIsPVP, "player") ~= true then
        if flagged then return nil, "they're flagged for PvP and you aren't" end
        if flagged == nil then
            return nil, "can't see whether they're flagged for PvP (target them, or show friendly nameplates)"
        end
    end
    if #myBuffs == 0 then
        if #ns.BuffData.Mine() > 0 then return nil, "you've marked all your buffs never offer" end
        return nil, "you know no buffs to give"
    end
    local suitable = 0
    for _, buff in ipairs(myBuffs) do
        if not buff.selfCast and not buff.groupOnly and ns.BuffData.Useful(buff, favour.class) then
            suitable = suitable + 1
            -- Unknown (no unit, or hidden in a fight) counts as not wearing it.
            if Offers.Wears(unit, buff) ~= true then return buff end
        end
    end
    return nil, suitable > 0 and "they already have your buffs" or "none of your buffs suit them"
end

-- What the button should offer now: { name, buff, spell }, or nil and why
-- not. Newest favour first.
function Offers.Current()
    if not ns.db or not ns.db.enabled then return nil, "the addon is off" end
    if not ns.db.buffBack.enabled then return nil, "buff back is off" end
    -- No Changed() here: the button is the caller, and would re-enter.
    Expire(GetTime())
    if #favours == 0 then return nil, "nobody is owed a buff" end
    local myBuffs = ns.BuffData.Offerable()
    local visible = VisiblePlayers()
    local firstReason
    for i = #favours, 1, -1 do
        local favour = favours[i]
        local buff, reason = ChooseBuff(favour, myBuffs, visible)
        local spell = buff and ns.BuffData.SpellName(buff)
        if spell then return { name = favour.name, buff = buff, spell = spell } end
        firstReason = firstReason
            or (Util.DisplayName(favour.name) .. ": " .. (reason or "the spell's name isn't known"))
    end
    return nil, firstReason
end

-- A buff of yours (spell) reached them, from the button or by hand. Their
-- buff back within RETURNED_RECENTLY answers it. If you owed them, the
-- favour is returned and their copy is told this buff answers theirs.
-- false if they weren't owed (it expired or was let go before the cast landed).
function Offers.MarkReturned(name, spell)
    local now = GetTime()
    MakeRoom(buffedAt, name, Offers.MAX_REMEMBERED)
    buffedAt[name] = now
    ns.Exchange.NoteGiven(name)
    local i = IndexOf(name)
    if not i then return false end
    local favour = table.remove(favours, i)
    if favour.ledgerEntry then ns.Ledger.Returned(favour.ledgerEntry, spell) end
    ns.Comm.SendAnswer(name)
    Changed()
    return true
end

-- Their copy says the buff they just gave you answers yours (Comm.lua's
-- ANSWER). Untrusted, but it can only stop you owing the sender. A favour
-- owed for their buff a moment ago is let go; otherwise the mark waits for
-- their buff.
function Offers.OnAnswerMark(name)
    local now = GetTime()
    local i = IndexOf(name)
    if i and Within(favours[i].owedAt, Offers.MARK_SECONDS, now) then
        local favour = table.remove(favours, i)
        if favour.ledgerEntry then ns.Ledger.NoteNotReturned(favour.ledgerEntry, "it answered your buff to them") end
        ns.Diag.Log("buffBack", "not owing %s: their copy says their buff answers yours", name)
        Changed()
        return
    end
    MakeRoom(marks, name, Offers.MAX_MARKS)
    marks[name] = now
end

-- Tokens a hand cast can go to that the game may name only by first name.
local CAST_TARGET_TOKENS = { "target", "mouseover", "focus", "softfriend" }
-- Players a cast can reach without those tokens (a self-cast, an @party1
-- macro): one of them sharing the first name makes it ambiguous.
local CAST_OTHER_TOKENS = { "player" }
for i = 1, 4 do CAST_OTHER_TOKENS[#CAST_OTHER_TOKENS + 1] = "party" .. i end
for i = 1, 40 do CAST_OTHER_TOKENS[#CAST_OTHER_TOKENS + 1] = "raid" .. i end

-- The full name of the player UNIT_SPELLCAST_SENT says a cast went to, or
-- nil. The game may give "First", "First Surname" or "First-Surname". A
-- first name alone counts only when exactly one player of that name is your
-- target, mouseover, focus or soft target, and neither you nor anyone in
-- your group has it: guessing could block a real favour from someone else
-- of that name.
function Offers.CastTarget(reported)
    local full = Util.FullName(reported)
    if not full or full:find("-", 1, true) then return full end
    local found
    for _, token in ipairs(CAST_TARGET_TOKENS) do
        local name = Util.UnitFullName(token)
        if name and Util.FirstName(name) == full then
            if found and found ~= name then return nil end
            found = name
        end
    end
    for _, token in ipairs(CAST_OTHER_TOKENS) do
        local name = Util.UnitFullName(token)
        if name and name ~= found and Util.FirstName(name) == full then return nil end
    end
    return found
end

-- A text the game gave that is usable as a key: a non-empty string, not secret.
local function ReadableText(value)
    if Util.IsSecret(value) or type(value) ~= "string" or value == "" then return nil end
    return value
end

-- UNIT_SPELLCAST_SENT for a cast of yours no press of the button sent (one
-- cast by hand): a buff to a player the game names waits to land. Unreadable
-- details remember nothing.
function Offers.OnCastSent(unit, castTargetName, castGUID, spellId)
    if unit ~= "player" or Util.IsSecret(spellId) or type(spellId) ~= "number" then return end
    local buff = ns.BuffData.ForCast(spellId)
    if not buff or buff == ns.BuffData.REVOKE then return end
    local guid, name = ReadableText(castGUID), Offers.CastTarget(castTargetName)
    if not guid or not name then
        ns.Diag.Log("buffBack", "a buff cast by hand: can't tell which player it went to")
        return
    end
    local cast = { guid = guid, name = name, spell = ns.BuffData.SpellName(buff), at = GetTime() }
    castsWaiting[#castsWaiting + 1] = cast
    if #castsWaiting > Offers.MAX_CASTS_WAITING then table.remove(castsWaiting, 1) end
end

-- UNIT_SPELLCAST_SUCCEEDED for a cast no press of the button answers: a
-- hand-cast buff sent to a player has reached them, if it landed in time.
function Offers.OnCastLanded(unit, castGUID)
    local guid = ReadableText(castGUID)
    if unit ~= "player" or not guid or not ns.db or not ns.db.enabled or not ns.db.buffBack.enabled then return end
    for _, cast in ipairs(castsWaiting) do
        if cast.guid == guid and Within(cast.at, Offers.CAST_WAIT, GetTime()) then
            if Offers.MarkReturned(cast.name, cast.spell) then
                ns.Diag.Log("buffBack", "returned %s's favour by hand", cast.name)
            end
            return
        end
    end
end

-- Let a favour go (right-click on the button).
function Offers.LetGo(name)
    local i = IndexOf(name)
    if not i then return false end
    local favour = table.remove(favours, i)
    if favour.ledgerEntry then ns.Ledger.NoteNotReturned(favour.ledgerEntry, "you let it go") end
    Changed()
    return true
end

-- Drop a favour without a note (the player was ignored).
function Offers.Forget(name)
    local i = IndexOf(name)
    if not i then return false end
    table.remove(favours, i)
    Changed()
    return true
end

function Offers.Count()
    return #favours
end
