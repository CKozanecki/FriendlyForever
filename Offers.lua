-- Favours you owe: players outside your group who buffed you, waiting for a
-- buff of yours back. The buff-back button (BuffButton.lua) shows the newest
-- one you can return and casts on a press; nothing here casts anything.
--
-- For each favour the buff is chosen fresh: your class's buffs you know, in
-- order, skipping ones that can't go to a stranger (Battle Shout, Salvation),
-- ones their class has no use for (Intellect to a warrior), and ones they
-- already wear when the game lets us see. While the game still has them on a
-- unit token (target, nameplate...) we also skip the dead, and anyone flagged
-- for PvP while you aren't: buffing them would flag you.
local _, ns = ...
local Util = ns.Util

local Offers = {}
ns.Offers = Offers

Offers.MAX = 20         -- favours kept at once; the oldest goes first
Offers.MAX_AURAS = 40   -- buffs read per player when checking what they wear

local owed = {} -- newest last: { name, unit, class, at, entry }

local Ask = Util.Ask

local function Remove(index)
    table.remove(owed, index)
end

local function Find(name)
    for i, f in ipairs(owed) do
        if f.name == name then return i, f end
    end
end

-- The unit token, only while it is still them.
local function LiveUnit(favour)
    if favour.unit and Util.UnitFullName(favour.unit) == favour.name then return favour.unit end
    return nil
end

-- true / false whether they wear this buff (any rank, group version or
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

-- Someone outside your group buffed you. unit: the token they were seen
-- under, if any; entry: their ledger entry, marked returned when you do.
function Offers.Owe(name, unit, entry)
    local i = Find(name)
    if i then Remove(i) end
    -- Their class (file name, "WARRIOR"), read now while the token is theirs.
    local class
    if unit and Util.UnitFullName(unit) == name then
        local _, file = Ask(UnitClass, unit)
        if type(file) == "string" then class = file end
    end
    owed[#owed + 1] = { name = name, unit = unit, class = class, at = GetTime(), entry = entry }
    while #owed > Offers.MAX do Remove(1) end
    ns.Diag.Log("buffBack", "you owe %s a buff", name)
end

-- Forget favours older than the setting.
local function Expire(now)
    local limit = ns.db.buffBack.owedMinutes * 60
    for i = #owed, 1, -1 do
        if now - owed[i].at > limit then
            local f = owed[i]
            if f.entry then ns.Ledger.NoteNotReturned(f.entry, "the time to return it ran out") end
            Remove(i)
        end
    end
end

-- The buff to give this favour, or nil and why not.
local function Choose(favour, mine)
    local unit = LiveUnit(favour)
    if unit then
        if Ask(UnitIsDeadOrGhost, unit) == true then return nil, "they're dead" end
        if Ask(UnitIsPVP, unit) == true and Ask(UnitIsPVP, "player") ~= true then
            return nil, "they're flagged for PvP and you aren't"
        end
    end
    if #mine == 0 then return nil, "you know no buffs to give" end
    local suitable = 0
    for _, buff in ipairs(mine) do
        if not buff.selfCast and not buff.groupOnly and ns.BuffData.Useful(buff, favour.class) then
            suitable = suitable + 1
            -- Unknown (no unit, or hidden in a fight) counts as not wearing it.
            if Offers.Wears(unit, buff) ~= true then return buff end
        end
    end
    return nil, suitable > 0 and "they already have your buffs" or "none of your buffs suit them"
end

-- What the button should offer now: { name, unit, buff, spell, favour }, or
-- nil and why not. Newest favour first.
function Offers.Current()
    if not ns.db or not ns.db.buffBack.offer then return nil, "buff back is off" end
    Expire(GetTime())
    local mine = ns.BuffData.Mine()
    local why = #owed == 0 and "nobody is owed a buff" or nil
    for i = #owed, 1, -1 do
        local favour = owed[i]
        local buff, reason = Choose(favour, mine)
        local spell = buff and ns.BuffData.SpellName(buff)
        if spell then
            return { name = favour.name, unit = LiveUnit(favour), buff = buff, spell = spell, favour = favour }
        end
        why = why or (Util.DisplayName(favour.name) .. ": " .. (reason or "the spell's name isn't known"))
    end
    return nil, why
end

-- You buffed them: the favour is returned.
function Offers.Returned(name, spell)
    local i, favour = Find(name)
    if not i then return false end
    if favour.entry then ns.Ledger.Returned(favour.entry, spell) end
    Remove(i)
    return true
end

-- Let a favour go (right-click on the button).
function Offers.Skip(name)
    local i, favour = Find(name)
    if not i then return false end
    if favour.entry then ns.Ledger.NoteNotReturned(favour.entry, "you let it go") end
    Remove(i)
    return true
end

function Offers.Count()
    return #owed
end

function Offers.Forget(name)
    local i = Find(name)
    if i then Remove(i) end
end
