-- Weapon buffs (#45, experimental, off by default): in buff mode, once the
-- button has nothing left for favours, your group or your own self-buffs,
-- it offers to put a weapon buff on a hand of yours that has no temporary
-- enchant: a sharpening stone, a weightstone, a wizard or mana oil, a
-- rogue's poison, or a shaman's weapon imbue. You choose one kind per hand
-- (buffBack.weaponMain, buffBack.weaponOff); the best rank of it you carry
-- and can use is offered. One press, one application, through the same
-- secure button. Nothing here uses or casts anything.
--
-- The press: "/use item:<id>" then "/use 16" (main hand) or "/use 17" (off
-- hand), built from fixed text and two whole numbers, the item one of the
-- listed IDs below; or a shaman's "/cast [@player,nodead] <imbue>" then
-- "/use 16", by the name the client gives the rank you know. Forever's data
-- gives the imbues (and poisons) another enchant effect than Classic's
-- (#409), so whether the game then waits for a weapon to be picked is
-- unknown: "/use 16" picks the main hand if it does, and does nothing if it
-- doesn't, as that weapon has no Use of its own (Q6 holds for imbues too).
--
-- What it reads, and what "can't tell" does (the owner's decisions on #45):
--   your weapons' enchants: GetWeaponEnchantInfo(), positions 1 (main hand)
--   and 5 (off hand) are "has a temporary enchant". Only a flag that reads
--   exactly false is a bare hand; true is covered; anything else (a secret,
--   no such function, an error, junk) means can't tell, and nothing is
--   offered for that hand. A running enchant is never topped up: replacing
--   one makes the game ask "Replace?" (Q4);
--   the weapon in the hand: GetInventoryItemID, and the client must say it
--   is a weapon (item class 2). A shield, a held item or an empty hand gets
--   nothing, silently;
--   its own Use effect (Q6): a weapon with one, or one that can't be read,
--   gets no item, as a "/use 16" the item didn't prepare would fire it;
--   your bags: the item's count (as group versions' reagents, #41), and
--   whether you can use it (an oil's level);
--   forms (Q3, the owner's choice B): offered in a form too, a druid's or
--   Ghost Wolf. A press may drop you out of the form to apply it, as using it
--   by hand does (the game's own unshift); the macro never cancels a form
--   itself. If the game refuses instead, the press shows its reason.
--
-- Where the IDs come from: docs/forever-facts.md ("Weapon buffs").
local _, ns = ...
local Util = ns.Util

local WeaponBuffs = {}
ns.WeaponBuffs = WeaponBuffs

-- After a weapon buff lands, how long its hand counts as done even if the
-- game doesn't show it yet.
WeaponBuffs.JUST_GIVEN_SECONDS = 10
-- Right-click skips your weapon buffs for this long.
WeaponBuffs.SKIP_SECONDS = 300
-- A hand the game refused waits this long, so the next press tries the other.
WeaponBuffs.HELD_BACK_SECONDS = 15
-- Refused this many times in a row for the same weapon and kind (a stone
-- that doesn't suit the weapon, say: which suits which is #409), the hand is
-- left alone for STOP_SECONDS, or until its weapon or its kind changes, and
-- counts as settled meanwhile. A refusal that passes by itself (pressed while
-- moving) costs minutes, not the session: "in a row" ends whenever the hand
-- reads as covered (put on by hand, say), and the stop runs out.
WeaponBuffs.REFUSALS_TO_STOP = 2
WeaponBuffs.STOP_SECONDS = 300

-- The hands: inventory slot, the position of its "has an enchant" flag in
-- GetWeaponEnchantInfo's answer, the words for it, and its setting.
WeaponBuffs.HANDS = {
    { slot = 16, flag = 1, words = "main hand", field = "weaponMain" },
    { slot = 17, flag = 5, words = "off hand", field = "weaponOff" },
}

-- What each kind is: its items as { item ID, the spell the item casts },
-- best first; or a shaman's imbue, its spell's ranks, best first. class:
-- only that class may choose it; mainHand: the main hand only. Every ID is
-- Forever's own (see the facts file), checked by spec/weaponbuffs_data_spec.lua.
WeaponBuffs.KINDS = {
    sharpening = { label = "Sharpening stone", items = {
        { 18262, 22756 }, { 12404, 16138 }, { 7964, 9900 }, { 2871, 2830 }, { 2863, 2829 }, { 2862, 2828 } } },
    weightstone = { label = "Weightstone", items = {
        { 12643, 16622 }, { 7965, 9903 }, { 3241, 3114 }, { 3240, 3113 }, { 3239, 3112 } } },
    wizardOil = { label = "Wizard oil", items = {
        { 20749, 25122 }, { 20750, 25121 }, { 20746, 25119 }, { 20744, 25117 } } },
    manaOil = { label = "Mana oil", items = { { 20748, 25123 }, { 20747, 25120 }, { 20745, 25118 } } },
    instantPoison = { label = "Instant Poison", class = "ROGUE", items = {
        { 8928, 11340 }, { 8927, 11339 }, { 8926, 11338 }, { 6950, 8688 }, { 6949, 8686 }, { 6947, 8679 } } },
    deadlyPoison = { label = "Deadly Poison", class = "ROGUE", items = {
        { 20844, 25351 }, { 8985, 11356 }, { 8984, 11355 }, { 2893, 2824 }, { 2892, 2823 } } },
    cripplingPoison = { label = "Crippling Poison", class = "ROGUE", items = { { 3776, 11202 }, { 3775, 3408 } } },
    mindNumbingPoison = { label = "Mind-numbing Poison", class = "ROGUE", items = {
        { 9186, 11399 }, { 6951, 8693 }, { 5237, 5761 } } },
    woundPoison = { label = "Wound Poison", class = "ROGUE", items = {
        { 10922, 13227 }, { 10921, 13226 }, { 10920, 13225 }, { 10918, 13219 } } },
    rockbiter = { label = "Rockbiter Weapon", class = "SHAMAN", mainHand = true,
        ranks = { 16316, 16315, 16314, 10399, 8019, 8018, 8017 } },
    flametongue = { label = "Flametongue Weapon", class = "SHAMAN", mainHand = true,
        ranks = { 16342, 16341, 16339, 8030, 8027, 8024 } },
    frostbrand = { label = "Frostbrand Weapon", class = "SHAMAN", mainHand = true,
        ranks = { 16356, 16355, 10456, 8038, 8033 } },
    windfury = { label = "Windfury Weapon", class = "SHAMAN", mainHand = true,
        ranks = { 16362, 10486, 8235, 8232 } },
}
for key, kind in pairs(WeaponBuffs.KINDS) do kind.key = key end

-- The listed items, [item ID] = the spell it casts: the only items a macro is built for.
local ITEM_SPELL = {}
for _, kind in pairs(WeaponBuffs.KINDS) do
    for _, pair in ipairs(kind.items or {}) do ITEM_SPELL[pair[1]] = pair[2] end
end

-- The game's item class for weapons (Enum.ItemClass.Weapon).
local WEAPON_CLASS = 2

local justGiven = {} -- [slot] = GetTime() a weapon buff landed on it
local refused = {}   -- [slot] = { weapon = item ID, kind = kind key, count, at = GetTime() } the game's refusals
local skippedAt      -- GetTime() you right-clicked a weapon buff
local said = {}      -- reasons said in debug, while they hold

local function Recently(at, seconds)
    return at ~= nil and GetTime() - at < seconds
end

-- All of fn's answers, as { n = count, ... }, or nil when it can't be asked
-- (no such function, or an error). A secret answer is kept as it is: each
-- use below checks for one before it compares anything.
local function Pack(ok, ...)
    if not ok then return nil end
    return { n = select("#", ...), ... }
end
local function Answers(fn, ...)
    if type(fn) ~= "function" then return nil end
    return Pack(pcall(fn, ...))
end

-- A readable whole number above 0, or nil.
local function Id(value)
    if Util.IsSecret(value) or type(value) ~= "number" then return nil end
    if value ~= value or value < 1 or value ~= math.floor(value) then return nil end
    return value
end

-- A setting of the Buff Back section; one lost mid-session reads as off (#387).
local function Setting(field)
    local cfg = ns.db and ns.db.buffBack
    if type(cfg) ~= "table" then return nil end
    return cfg[field]
end

-- The kind chosen for a hand, if your class may use it there.
local function ChosenKind(hand, class)
    local key = Setting(hand.field)
    local kind = type(key) == "string" and WeaponBuffs.KINDS[key] or nil
    if not kind then return nil end
    if kind.class and kind.class ~= class then return nil end
    if kind.mainHand and hand.slot ~= 16 then return nil end
    return kind
end

-- The kinds your class may choose for a hand, in the options' order; with
-- no class (it can't be read), every class's.
function WeaponBuffs.KindsFor(class, slot)
    local out = {}
    for _, key in ipairs(ns.Config.WEAPON_KINDS) do
        local kind = WeaponBuffs.KINDS[key]
        if kind and (class == nil or not kind.class or kind.class == class) and not (kind.mainHand and slot ~= 16) then
            out[#out + 1] = key
        end
    end
    return out
end

-- Why you can't have a weapon buff now (dead, mounted, on a flight path),
-- or nil; and whether that passes by itself (true: not settled). Anything
-- the game won't say is "can't tell". A form is no reason (Q3).
local function YouCant()
    local dead = Util.ReadGameValues(UnitIsDeadOrGhost, "player")
    if dead == true then return "you're dead", true end
    if dead ~= false then return "can't tell whether you're dead", true end
    local mounted = Util.ReadGameValues(IsMounted)
    if mounted == true then return "you're mounted", false end
    if mounted ~= false then return "can't tell whether you're mounted", true end
    local taxi = Util.ReadGameValues(UnitOnTaxi, "player")
    if taxi == true then return "you're on a flight path", false end
    if taxi ~= false then return "can't tell whether you're on a flight path", true end
end

-- The has-an-enchant flags of your weapons, as GetWeaponEnchantInfo gives
-- them, or nil when it can't be asked.
local function Enchants()
    return Answers(GetWeaponEnchantInfo)
end

-- Whether a hand has a temporary enchant: true, false, or nil (can't tell).
local function HasEnchant(enchants, hand)
    local flag = enchants[hand.flag]
    if Util.IsSecret(flag) or type(flag) ~= "boolean" then return nil end
    return flag
end

-- The weapon in a hand: its item ID; false when the hand holds no weapon;
-- nil when that can't be told.
local function WeaponIn(hand)
    local got = Answers(GetInventoryItemID, "player", hand.slot)
    if not got then return nil end
    local item = got[1]
    if item == nil then return false end
    item = Id(item)
    if not item then return nil end
    local info = Answers(C_Item and C_Item.GetItemInfoInstant, item) or Answers(GetItemInfoInstant, item)
    local class = info and info[6]
    if Util.IsSecret(class) or type(class) ~= "number" then return nil end
    if class ~= WEAPON_CLASS then return false end
    return item
end

-- Whether a weapon has its own Use effect: true, false, or nil (can't tell).
local function HasUse(item)
    local got = Answers(C_Item and C_Item.GetItemSpell, item) or Answers(GetItemSpell, item)
    if not got then return nil end
    local name = got[1]
    if name == nil then return false end
    if Util.IsSecret(name) then return nil end
    return true
end

-- How many of an item you carry, or nil when it can't be read.
local function Count(item)
    local count = Util.ReadGameValues(C_Item and C_Item.GetItemCount, item)
    if count == nil then count = Util.ReadGameValues(GetItemCount, item) end
    if type(count) ~= "number" or count ~= count then return nil end
    return count
end

-- Whether you can use an item: true, false, or nil (can't tell).
local function UsableItem(item)
    local usable = Util.ReadGameValues(C_Item and C_Item.IsUsableItem, item)
    if usable == nil then usable = Util.ReadGameValues(IsUsableItem, item) end
    if usable == true or usable == false then return usable end
    return nil
end

-- The client's name for an item, or the kind's own words.
local function ItemName(item, kind)
    local name = Util.ReadGameValues(C_Item and C_Item.GetItemNameByID, item)
    if type(name) == "string" and name ~= "" then return Util.StripChat(name) end
    return kind.label
end

local function ItemIcon(item)
    local icon = Util.ReadGameValues(C_Item and C_Item.GetItemIconByID, item)
    if icon == nil then icon = Util.ReadGameValues(GetItemIcon, item) end
    if type(icon) == "number" or (type(icon) == "string" and icon ~= "") then return icon end
end

-- The offer for an item kind on a hand, or nil, why not, and whether that
-- passes by itself (true: not settled).
local function ItemOffer(me, hand, kind, weapon)
    local hasUse = HasUse(weapon)
    if hasUse == nil then return nil, "can't tell whether your " .. hand.words .. " weapon has a Use", true end
    if hasUse then
        return nil, "your " .. hand.words .. " weapon has its own Use: apply your " .. kind.label .. " by hand", false
    end
    local unread, unreadUse, tooLow = false, nil, nil
    for _, pair in ipairs(kind.items) do
        local item = pair[1]
        local count = Count(item)
        if count == nil then
            unread = true
        elseif count > 0 then
            local usable = UsableItem(item)
            if usable == true then
                return { name = me, self = true, weapon = true, slot = hand.slot, hand = hand.words,
                    item = item, castIds = { [pair[2]] = true }, spell = ItemName(item, kind),
                    icon = ItemIcon(item) }
            elseif usable == nil then
                unreadUse = unreadUse or ItemName(item, kind)
            else
                tooLow = tooLow or ItemName(item, kind)
            end
        end
    end
    if unread then return nil, "can't count your " .. kind.label, true end
    if unreadUse then return nil, "can't tell whether you can use " .. unreadUse, true end
    if tooLow then return nil, "can't use " .. tooLow .. " yet", false end
    return nil, "no " .. kind.label .. " in your bags", false
end

-- The offer for a shaman's imbue (on the main hand), or nil, why, open.
local function ImbueOffer(me, hand, kind, weapon)
    local hasUse = HasUse(weapon)
    if hasUse == nil then return nil, "can't tell whether your " .. hand.words .. " weapon has a Use", true end
    if hasUse then
        return nil, "your " .. hand.words .. " weapon has its own Use: cast " .. kind.label .. " by hand", false
    end
    local id = ns.BuffData.KnownRank(kind)
    if id == nil then return nil, "you don't know " .. kind.label, false end
    local name = ns.BuffData.CastName(kind)
    if not name then return nil, "the name of " .. kind.label .. " can't be read", false end
    local fn = C_Spell and C_Spell.IsSpellUsable
    if type(fn) ~= "function" then fn = IsUsableSpell end
    local usable, noPower = Util.ReadGameValues(fn, id)
    if usable == false then
        return nil, (noPower == true and "not enough mana for " or "can't cast ") .. name .. " now", noPower == true
    end
    if usable ~= true then return nil, "can't tell whether " .. name .. " can be cast now", true end
    local ids = {}
    for _, rank in ipairs(kind.ranks) do ids[rank] = true end
    return { name = me, self = true, weapon = true, slot = hand.slot, hand = hand.words,
        castName = name, castIds = ids, spell = name, icon = ns.BuffData.Icon(kind) }
end

-- Say each reason once in debug while it holds.
local function Say(reasons)
    local now = {}
    for _, why in ipairs(reasons) do
        now[why] = true
        if not said[why] then ns.Diag.Log("buffMode", "weapon buff not offered: %s", why) end
    end
    said = now
end

-- The next weapon buff to offer: { name, self = true, weapon = true, slot,
-- hand, spell, item or castName, castIds, icon }, or nil, why not (nil when
-- there's nothing to say), and whether that's settled: nothing a weapon
-- buff could fix now or soon. With a list, every offer is appended in order
-- (main hand first), as SelfBuffs.Next does.
function WeaponBuffs.Next(out)
    if Setting("weaponBuffs") ~= true then return nil, nil, true end
    local _, class = Util.ReadGameValues(UnitClass, "player")
    if type(class) ~= "string" then class = nil end
    local hands = {}
    for _, hand in ipairs(WeaponBuffs.HANDS) do
        local kind = ChosenKind(hand, class)
        if kind then hands[#hands + 1] = { hand = hand, kind = kind } end
    end
    if #hands == 0 then
        Say({})
        return nil, nil, true
    end
    local function Stop(why, open)
        Say({ why })
        return nil, why, not open
    end
    if InCombatLockdown() then return nil, "in combat", false end
    local me = Util.UnitFullName("player")
    if not me then return Stop("your name can't be read", true) end
    if Recently(skippedAt, WeaponBuffs.SKIP_SECONDS) then
        return Stop("your weapon buffs are skipped for now (you right-clicked)", false)
    end
    local cant, cantOpen = YouCant()
    if cant then return Stop(cant, cantOpen) end
    local enchants = Enchants()
    if not enchants then return Stop("can't read your weapon enchants", true) end
    local first, firstWhy, open, reasons = nil, nil, false, {}
    for _, chosen in ipairs(hands) do
        local hand, kind = chosen.hand, chosen.kind
        local has = HasEnchant(enchants, hand)
        local offer, why, waits, weapon
        if has == true then refused[hand.slot] = nil end
        if has == nil then
            why, waits = "can't read your " .. hand.words .. "'s enchant", true
        elseif has == false and not Recently(justGiven[hand.slot], WeaponBuffs.JUST_GIVEN_SECONDS) then
            weapon = WeaponIn(hand)
            if weapon == nil then
                why, waits = "can't tell what's in your " .. hand.words, true
            elseif weapon then
                local refusal = refused[hand.slot]
                if refusal and (refusal.weapon ~= weapon or refusal.kind ~= kind.key) then refusal = nil end
                if refusal and refusal.count >= WeaponBuffs.REFUSALS_TO_STOP
                    and Recently(refusal.at, WeaponBuffs.STOP_SECONDS) then
                    why, waits = "the game refused your " .. kind.label .. " on your " .. hand.words
                        .. " weapon twice: trying again in a few minutes, or change the weapon or the kind", false
                elseif refusal and Recently(refusal.at, WeaponBuffs.HELD_BACK_SECONDS) then
                    why, waits = "the game refused your last " .. kind.label .. " on your " .. hand.words, true
                elseif kind.items then
                    offer, why, waits = ItemOffer(me, hand, kind, weapon)
                else
                    offer, why, waits = ImbueOffer(me, hand, kind, weapon)
                end
            end
        end
        if offer then
            offer.weaponItem, offer.weaponKind = weapon, kind.key
            -- A look that stops at the first offer saw only some of the
            -- reasons: only a full look says them (as SelfBuffs.Next, #44).
            if not out then return offer end
            first = first or offer
            out[#out + 1] = offer
        elseif why then
            reasons[#reasons + 1] = why
            firstWhy = firstWhy or why
            open = open or waits
        end
    end
    Say(reasons)
    if first then return first end
    return nil, firstWhy, not open
end

-- The macro for a weapon offer, or nil when a part isn't one it may hold:
-- an item only by a listed ID, on slot 16 or 17; an imbue only on the main
-- hand, by a name safe in a macro, then "/use 16" (see the top).
function WeaponBuffs.Macro(offer)
    if type(offer) ~= "table" or not offer.weapon then return nil end
    local slot = offer.slot
    if slot ~= 16 and slot ~= 17 then return nil end
    if offer.item ~= nil then
        local item = Id(offer.item)
        if not item or not ITEM_SPELL[item] then return nil end
        return string.format("/use item:%d\n/use %d", item, slot)
    end
    local name = offer.castName
    if slot ~= 16 or not ns.BuffButton.IsSafeMacroArgument(name) then return nil end
    return "/cast [@player,nodead] " .. name .. "\n/use 16"
end

-- A weapon buff landed on a hand (the game said so).
function WeaponBuffs.NoteGiven(slot)
    justGiven[slot] = GetTime()
    refused[slot] = nil
end

-- The game refused a weapon buff of kind (its key) on the weapon (item ID)
-- in slot: try the other hand first for a moment, and count it, in a row
-- for that weapon and kind.
function WeaponBuffs.NoteRefused(slot, weapon, kind)
    local last = refused[slot]
    local count = 1
    if last and last.weapon == weapon and last.kind == kind then count = last.count + 1 end
    refused[slot] = { weapon = weapon, kind = kind, count = count, at = GetTime() }
end

-- Right-click: leave your weapon buffs out for a while.
function WeaponBuffs.Skip()
    skippedAt = GetTime()
end
