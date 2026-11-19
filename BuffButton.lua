-- The buff-back button: shows a favour you owe (Offers.lua) and, when you
-- press it (click, or its key in Key Bindings > Friendly Forever), casts your buff on
-- them. The game only lets an addon cast through a secure button the player
-- presses, so this module decides who and what, writes it onto the button as
-- a macro, and the game does the casting.
--
-- The macro (BuildCastMacro) clears your target, targets them by exact name,
-- casts only if that found a friendly, living player, then gives you your
-- target back. If they can't be found, nothing is cast. /friendly buffback
-- shows exactly what the button holds, for testing in game. The optional
-- line isn't in the macro: it's queued like a thank-you, only once the game
-- says the buff reached them, and goes out on your next key press.
--
-- Secure buttons can't be changed in combat. The button empties itself as a
-- fight starts (the game still allows that then) and fills again after.
-- Once a battleground's battle has started it stays hidden, and works out
-- nothing, until you leave (Battleground.lua).
local _, ns = ...
local Util = ns.Util

local BuffButton = {}
ns.BuffButton = BuffButton

BuffButton.FRAME_NAME = "FriendlyForeverBuffButton"
BuffButton.ANSWER_WINDOW_SECONDS = 3   -- after a press, a cast going out this soon is its answer
BuffButton.SENT_ANSWER_SECONDS = 15    -- after a cast goes out, how long the server may take to answer
BuffButton.ERROR_ANSWER_SECONDS = 0.5  -- the game's error text this soon after a press acts is about it
BuffButton.MAX_PRESSES_WATCHED = 5     -- presses waiting for an answer at once (keys mashed)
BuffButton.RESULT_SHOWN_SECONDS = 4    -- how long "Returned ..." stays under the button
BuffButton.RECHECK_SECONDS = 5         -- how often favours are re-checked while any are owed
-- "Already done by Ann" (#256, the owner): a buff another member put up in
-- step as you entered shows this long, in red, with the button empty, then
-- the next buff you need. It fades out over its last ALREADY_DONE_FADE seconds.
BuffButton.ALREADY_DONE_SECONDS = 2
BuffButton.ALREADY_DONE_FADE = 0.5
BuffButton.FADE_STEP_SECONDS = 0.1
-- Macros are kept within 255 characters, the game's macro editor limit (the
-- secure attribute's own limit isn't documented, so we stay inside this one).
BuffButton.MACRO_MAX_LENGTH = 255
-- The icon the button shows with no offer of its own (empty, unlocked for
-- moving, or an offer whose icon can't be read): Friendly Forever's own, the
-- TOC's IconTexture, the same for every class, never another class's spell
-- (#507, the owner).
BuffButton.PLACEHOLDER_ICON = "Interface\\AddOns\\FriendlyForever\\Media\\Icon"
-- The button's size. Its second line (why it's empty, or what it offers)
-- wraps, never cut short (#270): the button grows to hold every line, from its saved anchor point (centred by default).
BuffButton.WIDTH = 220
BuffButton.MIN_HEIGHT = 44
BuffButton.TEXT_LEFT = 46        -- the text starts right of the icon (4 + 36 + 6)
BuffButton.TEXT_RIGHT = 6
BuffButton.SUBTITLE_TOP = 24     -- the second line starts this far below the top
BuffButton.SUBTITLE_LINE_HEIGHT = 12 -- at least as tall as a line of its font
BuffButton.BOTTOM_PAD = 6

-- Attribute names of Blizzard's SecureActionButtonTemplate
-- (https://warcraft.wiki.gg/wiki/SecureActionButtonTemplate). "*" matches any
-- modifier keys held (so Shift+key bindings work too); "1" is the left mouse
-- button, which is also what the "CLICK <button>:LeftButton" key binding
-- presses. No other button has a secure action: right-click is ours (PostClick).
local SECURE_ATTRIBUTE = {
    leftButtonActionType = "*type1",
    leftButtonMacroText = "*macrotext1",
    keyActionType = "*type-BuffModeKey",
    keyMacroText = "*macrotext-BuffModeKey",
}
-- Buff mode's key (BuffMode.lua) presses the button as a button of its own
-- (#452), so the game looks up its action under its own name: Blizzard's
-- SecureButton_GetButtonSuffix gives "-" .. name for any button but the
-- mouse's, and a press finds no action where none is written. Only these
-- four attributes are ever written: no plain "type" or "*type*" that a
-- press by any button would fall back on.
BuffButton.KEY_BUTTON = "BuffModeKey"
local MACRO_ACTION_TYPE = "macro"

-- Friendly Forever's own section in Key Bindings (#509, the owner): its
-- bindings name it as their category (Bindings.xml), and Blizzard's code for
-- Forever titles a section by the global of that name (Keybindings.lua's
-- GetBindingCategoryName). The bindings' names, by which the game keeps
-- their keys, are unchanged.
BuffButton.BINDING_CATEGORY = "BINDING_HEADER_FRIENDLYFOREVER"
_G[BuffButton.BINDING_CATEGORY] = "Friendly Forever"
-- The text shown for the binding in Key Bindings > Friendly Forever.
_G["BINDING_NAME_CLICK " .. BuffButton.FRAME_NAME .. ":LeftButton"] = "Friendly Forever: buff button"

local button, eventFrame
local armedOffer          -- what the button holds: { name, spell, buff, group, cast, self, macroText }
local appliedMacroText    -- the macro text last written to the button (to skip rewriting it)
local appliedKeyText      -- and for buff mode's key (#452): nil while the key waits
local shownResult         -- the last result under the button: { text, shownAt, name, stays (a right-click's) }
local lastResultText = "nothing pressed yet"
local notArmedReason      -- why the button is empty, for /friendly buffback
local recheckScheduled = false
local chosenName          -- the player a row of the list was clicked for: the next offer if still offered (#43)
local chosenKind          -- and the kind of that row's offer: "self" (a self-buff, #44), "weapon" (#45) or "other"
local alreadyDone         -- the "Already done by" note showing (#256): { title, spell, icon, shownAt, round, over }
local offerList = {}      -- everyone the button would offer to now, in order (BuffList.lua shows it)

------------------------------------------------------------------------
-- The macro
------------------------------------------------------------------------

-- A piece of macro text that can't end its line or start another command:
-- no control characters (so no line breaks), no "|" escape codes, and not
-- starting with "/".
function BuffButton.IsSafeMacroPart(text)
    return type(text) == "string" and text ~= "" and not text:find("[%c|]") and text:sub(1, 1) ~= "/"
end

-- A name or spell given to a command: safe as above, and also free of the
-- characters macro options use (";" between options, "[" "]" conditions).
function BuffButton.IsSafeMacroArgument(text)
    return BuffButton.IsSafeMacroPart(text) and not text:find("[;%[%]]")
end

-- The macro that casts spellName on the player playerFullName and leaves
-- you with the target you had (hadTarget) or none. Returns nil when a part isn't safe or it would be too long.
-- toggle (on yourself only): a self-buff that stays on until switched (an
-- Aspect, a paladin aura, #44), cast as "!<spell>", so a press that comes
-- after it is already on can't switch it off.
--
-- /cleartarget first makes your current target the "last target", so
-- /targetlasttarget brings it back whether or not /targetexact found them;
-- [help,nodead] casts only on a friendly, living target, so a failed
-- /targetexact casts nothing rather than on someone else.
function BuffButton.BuildCastMacro(playerFullName, spellName, hadTarget, onSelf, toggle)
    -- On yourself (#198): [@player] aims the cast without targeting anyone,
    -- so there is no name to find and your target stays as it is. The same
    -- secure macro button as for others; only its text differs.
    if onSelf then
        if not BuffButton.IsSafeMacroArgument(spellName) then return nil end
        -- "!" only in front of a name already checked safe: it can't start a command.
        local selfText = "/cast [@player,nodead] " .. (toggle == true and "!" or "") .. spellName
        if #selfText > BuffButton.MACRO_MAX_LENGTH then return nil end
        return selfText
    end
    local targetName = Util.DisplayName(playerFullName)
    if not BuffButton.IsSafeMacroArgument(targetName) or not BuffButton.IsSafeMacroArgument(spellName) then
        return nil
    end
    local macroText = table.concat({
        "/cleartarget",
        "/targetexact " .. targetName,
        "/cast [help,nodead] " .. spellName,
        hadTarget and "/targetlasttarget" or "/cleartarget",
    }, "\n")
    if #macroText > BuffButton.MACRO_MAX_LENGTH then return nil end
    return macroText
end

-- The macro that shifts you back into a form (#495): "!" so a press made
-- once you're already in it can't take you out again. nil when the form's
-- name isn't safe in a macro.
function BuffButton.BuildFormMacro(formName)
    if not BuffButton.IsSafeMacroArgument(formName) then return nil end
    local text = "/cast !" .. formName
    if #text > BuffButton.MACRO_MAX_LENGTH then return nil end
    return text
end

-- The macro for an offer: a weapon buff's own (WeaponBuffs.Macro, #45), or
-- a cast as above. nil when it can't be put in a macro safely.
-- A buff for a player, you included in buff mode, is cast as
-- offer.castSpell (#459): the rank their level allows (BuffData.CastFor),
-- "Mark of the Wild(Rank 5)" when stepping down for a low-level player, its
-- plain name when that's your highest. An offer without one is never cast:
-- a plain "/cast Mark of the Wild" casts your highest rank, which the game
-- refuses on a low-level player. A group version (GroupCasts.lua) and your
-- self-buffs (SelfBuffs.lua) go on by name: no player's level limits them.
function BuffButton.MacroFor(offer, hadTarget)
    if offer.weapon then return ns.WeaponBuffs.Macro(offer) end
    if offer.formReturn then return BuffButton.BuildFormMacro(offer.spell) end
    local spell = offer.spell
    if not offer.cast and not offer.selfBuff then
        spell = offer.castSpell
        if spell == nil then return nil end
    end
    return BuffButton.BuildCastMacro(offer.name, spell, hadTarget, offer.self, offer.toggle)
end

------------------------------------------------------------------------
-- Arming the button
------------------------------------------------------------------------

-- Write the macro (or nothing) to the button, only when it changed: for a
-- click, and for buff mode's key unless keyWaits (#452, #466: the key
-- doesn't cast a druid's buff in a form, or a shaman's in Ghost Wolf). Out of combat only, as every caller is.
local function SetSecureMacro(macroText, keyWaits)
    local keyText = (macroText and not keyWaits) and macroText or nil
    if macroText ~= appliedMacroText then
        button:SetAttribute(SECURE_ATTRIBUTE.leftButtonActionType, macroText and MACRO_ACTION_TYPE or nil)
        button:SetAttribute(SECURE_ATTRIBUTE.leftButtonMacroText, macroText)
        appliedMacroText = macroText
    end
    if keyText ~= appliedKeyText then
        button:SetAttribute(SECURE_ATTRIBUTE.keyActionType, keyText and MACRO_ACTION_TYPE or nil)
        button:SetAttribute(SECURE_ATTRIBUTE.keyMacroText, keyText)
        appliedKeyText = keyText
    end
end

-- The classes whose form holds buff mode's key, and what the button says
-- then: a druid's forms (#452) and a shaman's Ghost Wolf (#466). Every buff
-- they cast is "not while shapeshifted" in Forever's data.
local KEY_FORMS = { DRUID = "you're in a form", SHAMAN = "you're in Ghost Wolf" }

-- Ghost Wolf's spell, as the aura it puts on you (#466). It is Classic Era's
-- ID; that Forever's is the same is unconfirmed (#467), and the form read
-- below doesn't depend on it.
BuffButton.GHOST_WOLF_SPELL = 2645

-- Whether you wear Ghost Wolf's aura: true or false, or nil when your buffs
-- can't be read (a secret, an error, or more than are looked through).
local function WearsGhostWolf()
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if type(api) ~= "function" then return nil end
    for i = 1, ns.Offers.MAX_AURAS do
        local ok, aura = pcall(api, "player", i, "HELPFUL")
        if not ok or Util.IsSecret(aura) then return nil end
        if aura == nil then return false end
        if type(aura) ~= "table" then return nil end
        local id = aura.spellId
        if Util.IsSecret(id) or type(id) ~= "number" or id ~= id then return nil end
        if id == BuffButton.GHOST_WOLF_SPELL then return true end
    end
    return nil
end

-- Moonkin Form (#485), by the two ways the game names a form: the spell
-- of the form you're in (GetShapeshiftFormInfo's fourth answer, as
-- Blizzard's stance bar reads it), Classic Era's 24858, and the form's
-- number (GetShapeshiftFormID), MOONKIN_FORM = 31 in Blizzard's Classic
-- constants. That Forever's are the same is unconfirmed (#488); a
-- different one only makes the key wait.
BuffButton.MOONKIN_FORM_SPELL = 24858
BuffButton.MOONKIN_FORM_ID = 31

-- Whether form (GetShapeshiftForm's answer, not 0) is Moonkin Form: true
-- only when one of the two says so and neither says otherwise. Anything
-- unreadable (an error, a secret, not a number) says nothing; nothing said
-- is not Moonkin.
local function InMoonkin(form)
    local bySpell, byId
    local info = GetShapeshiftFormInfo
    if type(info) == "function" then
        local ok, _, _, _, spellId = pcall(info, form)
        if ok and not Util.IsSecret(spellId) and type(spellId) == "number" then
            bySpell = spellId == BuffButton.MOONKIN_FORM_SPELL
        end
    end
    local id = Util.ReadGameValues(GetShapeshiftFormID)
    if type(id) == "number" then byId = id == BuffButton.MOONKIN_FORM_ID end
    if bySpell == false or byId == false then return false end
    return bySpell == true or byId == true
end

-- Why buff mode's key waits for this offer (#452, #466), or nil when it may
-- press the button: a druid's buff while you're in a form, or a shaman's in
-- Ghost Wolf, unless "Fast-cast buffs in form" is on. A click still casts it
-- (the game takes you out of the form). Weapon buffs never wait (#45's
-- choice B). A form or class the game won't say counts as a form: the key
-- waits. Ghost Wolf counts when either the game's form or your buffs say
-- so: which of the two Forever reports it by is unconfirmed (#467).
-- Moonkin Form never holds the key (#485, the owner): a druid casts every
-- buff of ours in it without leaving it. Only a form the game says is
-- Moonkin counts (InMoonkin); any doubt, the key waits.
function BuffButton.KeyWaits(offer)
    if not offer or offer.weapon then return nil end
    -- The shift back into your form (#495) waits only once the game has
    -- refused it: then a click tries again, never the key.
    if offer.formReturn then return offer.refused end
    local buffBack = ns.db and ns.db.buffBack
    if type(buffBack) == "table" and buffBack.fastCastInForm == true then return nil end
    local _, class = Util.ReadGameValues(UnitClass, "player")
    if type(class) ~= "string" then return "can't tell whether you're in a form" end
    local why = KEY_FORMS[class]
    if not why then return nil end
    local unsure = "can't tell whether " .. why
    local form = Util.ReadGameValues(GetShapeshiftForm)
    if type(form) ~= "number" or form ~= form then return unsure end
    if form ~= 0 then
        if class == "DRUID" and InMoonkin(form) then return nil end
        return why
    end
    if class == "SHAMAN" then
        local wolf = WearsGhostWolf()
        if wolf == nil then return unsure end
        if wolf then return why end
    end
    return nil
end

------------------------------------------------------------------------
-- Back into your form (#495)
------------------------------------------------------------------------

-- With "Fast-cast buffs in form" on, in buff mode, a buff press that takes
-- you out of a form is remembered; once buff mode has nothing left for you
-- to buff, the button offers that form, and one more press (the key or a
-- click) shifts you back. Nothing casts by itself (the owner, #495).
--
-- Only these forms (the owner's choice), each by its spell, the fourth
-- answer of GetShapeshiftFormInfo (Blizzard's stance bar for Forever reads
-- it so), and the form's number, GetShapeshiftFormID, which Blizzard's code
-- for Forever never calls: a number the game gives that isn't the form's
-- means no return. Bear and Dire Bear are Forever's own (its SpellFlyout.lua);
-- the rest are Classic's, unconfirmed on Forever (docs/forever-facts.md).
BuffButton.RETURN_FORMS = {
    DRUID = { [768] = 1, [5487] = 5, [9634] = 8, [783] = 3 }, -- Cat, Bear, Dire Bear, Travel
    SHAMAN = { [2645] = 16 },                                  -- Ghost Wolf
}
BuffButton.RETURN_SECONDS = 30 -- after your last buff press, the return is dropped
-- A form left this soon after a buff press in it was left for that press.
BuffButton.LEAVE_SECONDS = BuffButton.ANSWER_WINDOW_SECONDS

local formReturn   -- the form to go back to: { spell, name, icon, lastBuffAt, refused, refusedAt (where), casting
                   -- (the press being cast) }
local leavingForm  -- the form a buff press was made in, until the game takes you out: { spell, name, icon, at }
local formSeen     -- the form last read: 0 (none), a form's spell, "other", or nil (unread)

-- The setting, in buff mode; a section lost mid-session reads as off.
local function ReturnWanted()
    local buffBack = ns.db and ns.db.buffBack
    return (ns.BuffMode.LentKey() and type(buffBack) == "table" and buffBack.fastCastInForm == true) and true or false
end

-- The form you're in, as the return reads it: 0 for none, a form to go
-- back to ({ spell, name, icon }), "other" for any other form, or nil when
-- the game won't say (an error, a secret, not a number). A shaman's Ghost
-- Wolf counts by the form's spell or by its aura on you (#466, #467).
local function ReadForm()
    local _, class = Util.ReadGameValues(UnitClass, "player")
    local forms = BuffButton.RETURN_FORMS[class] -- none for a class the game won't say
    if not forms then return "other" end
    local form = Util.ReadGameValues(GetShapeshiftForm)
    if type(form) ~= "number" or form ~= form then return nil end
    local wolf = false
    if class == "SHAMAN" then
        wolf = WearsGhostWolf()
        if wolf == nil then return nil end
    end
    if form == 0 and not wolf then return 0 end
    local spell
    if form ~= 0 then
        local ok, _, _, _, spellId = pcall(GetShapeshiftFormInfo, form)
        if ok and not Util.IsSecret(spellId) and type(spellId) == "number" then spell = spellId end
    end
    if wolf then
        if spell ~= nil and spell ~= BuffButton.GHOST_WOLF_SPELL then return "other" end
        spell = BuffButton.GHOST_WOLF_SPELL
    end
    local number = spell and forms[spell]
    if not number then return "other" end
    local id = Util.ReadGameValues(GetShapeshiftFormID)
    if id ~= nil and id ~= number then return "other" end
    local name = Util.ReadGameValues(C_Spell and C_Spell.GetSpellName, spell)
    if not BuffButton.BuildFormMacro(name) then return "other" end
    local icon = Util.ReadGameValues(C_Spell and C_Spell.GetSpellTexture, spell)
    return { spell = spell, name = name, icon = icon }
end

-- Let the return go, and any form a press was leaving (why: for the log).
local function ForgetForm(why)
    if formReturn then ns.Diag.Log("buffMode", "not going back into %s: %s", formReturn.name, why) end
    formReturn, leavingForm = nil, nil
end

-- Read your form and follow its changes: a form left for none, just after a
-- buff press in it, is the one to go back to; any other change (a shift by
-- hand into a form or out of one, or back into the remembered form) drops
-- the return, and so does a form the game won't say. The form read.
local function ObserveForm()
    local now = ReadForm()
    local key = type(now) == "table" and now.spell or now
    if key == nil then
        formSeen = nil
        ForgetForm("your form can't be read")
        return nil
    end
    if key == formSeen then return now end
    formSeen = key
    local left = leavingForm
    if key == 0 and left and GetTime() - left.at <= BuffButton.LEAVE_SECONDS then
        formReturn = { spell = left.spell, name = left.name, icon = left.icon, lastBuffAt = left.at }
        ns.Diag.Log("buffMode", "left %s for a buff: back into it once the buffs are done", left.name)
    else
        ForgetForm("you changed form")
    end
    return now
end

-- A buff press (not the shift back): in a form you can go back to, the
-- form is noted, for the moment the game takes you out of it; out of one,
-- it is your latest buff, and the return's RETURN_SECONDS start again.
-- With the setting or buff mode off, the next arming lets it go
-- (CheckReturn), as every press and change of form re-arms the button.
local function NoteBuffPress()
    local now = ObserveForm()
    if type(now) == "table" then
        leavingForm = { spell = now.spell, name = now.name, icon = now.icon, at = GetTime() }
    elseif formReturn then
        formReturn.lastBuffAt = GetTime()
    end
end

-- Where you are, for a refused shift back (#510): { indoors = true or
-- false, zone = the zone's name }, each nil when the game won't say (an
-- error, a secret, no answer; an empty zone name).
local function ReadPlace()
    local place = {}
    if type(IsIndoors) == "function" then
        local ok, indoors = pcall(IsIndoors)
        if ok and not Util.IsSecret(indoors) then place.indoors = indoors and true or false end
    end
    local zone = Util.ReadGameValues(GetRealZoneText)
    if type(zone) == "string" and zone ~= "" then place.zone = zone end
    return place
end

-- Whether you've moved indoors or outdoors, or changed zone, between two
-- places (ReadPlace): only what both read can say so; nothing read, or a
-- place missing, is no change.
function BuffButton.PlaceChanged(was, now)
    if type(was) ~= "table" or type(now) ~= "table" then return false end
    if was.indoors ~= nil and now.indoors ~= nil and was.indoors ~= now.indoors then return true end
    return was.zone ~= nil and now.zone ~= nil and was.zone ~= now.zone
end

-- Before the button is armed: the return is dropped once buff mode or the
-- setting is off, RETURN_SECONDS after your last buff, or on a form change.
-- Buff mode re-arms the button every few seconds (Refresh), so the button
-- lets it go by itself soon after; a press checks first anyway.
local function CheckReturn()
    if not ReturnWanted() then return ForgetForm("buff mode or Fast-cast buffs in form is off") end
    ObserveForm()
    if formReturn and GetTime() - formReturn.lastBuffAt >= BuffButton.RETURN_SECONDS then
        ForgetForm(BuffButton.RETURN_SECONDS .. " seconds passed")
    end
    -- A refusal's reason ("Can only use outside") clears once you move
    -- indoors or outdoors, or change zone (#510, the owner): the shift back
    -- is offered fresh, for the key too. It still waits for a press.
    if formReturn and formReturn.refused and BuffButton.PlaceChanged(formReturn.refusedAt, ReadPlace()) then
        ns.Diag.Log("buffMode", "%s offered again: you moved indoors or outdoors, or changed zone (was: %s)",
            formReturn.name, formReturn.refused)
        formReturn.refused, formReturn.refusedAt = nil, nil
    end
end

-- The shift back, once nothing is left to buff. A return stands only while
-- the last form read was none: any other read has dropped it (ObserveForm,
-- just called by CheckReturn). Not while a press of it is being cast (Ghost
-- Wolf takes a moment): another press then would be refused, or come after
-- you're back.
local function ReturnOffer()
    if not formReturn or formReturn.casting then return nil end
    return { name = Util.UnitFullName("player") or "you", self = true,
        formReturn = true, formSpell = formReturn.spell, spell = formReturn.name, icon = formReturn.icon,
        refused = formReturn.refused }
end

-- Whether the return a press of the shift back was for still stands: once
-- it's gone (you're back, or it was dropped), its answer says nothing.
local function ReturnStands(press)
    return formReturn ~= nil and formReturn.spell == press.formSpell
end

-- The game refused a press of the shift back (why: its words): the key
-- waits for it from now on, and a click tries again (the owner, #495).
local function RefuseReturn(press, why)
    formReturn.refused, formReturn.refusedAt = why, ReadPlace()
    if formReturn.casting == press then formReturn.casting = nil end
end

-- Whether the button is waiting to shift you back (#495): buff mode's
-- triggers keep it on meanwhile (BuffModeAuto.lua).
function BuffButton.ReturnWaiting() return formReturn ~= nil end

-- One of a text line's measures (GetStringWidth, GetStringHeight), if the
-- client gives it as a readable number.
local function MeasureText(fs, method)
    local fn = fs[method]
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, fs)
    if not ok or Util.IsSecret(value) or type(value) ~= "number" then return nil end
    return value
end

-- The height that holds every line of the second line's text (#270). The
-- lines are counted from the text's whole width at the room it wraps in,
-- each as tall as SUBTITLE_LINE_HEIGHT or the game's own line, if taller;
-- and the height the game says it draws, where it says: the larger wins, so
-- a line the game wraps early still fits.
function BuffButton.HeightFor(subtitle)
    local room = BuffButton.WIDTH - BuffButton.TEXT_LEFT - BuffButton.TEXT_RIGHT
    local drawn = MeasureText(subtitle, "GetStringHeight")
    local lineHeight = BuffButton.SUBTITLE_LINE_HEIGHT
    if drawn then
        local lines = MeasureText(subtitle, "GetNumLines")
        lineHeight = math.max(lineHeight, drawn / math.max(lines or 1, 1))
    end
    local height = math.ceil((MeasureText(subtitle, "GetStringWidth") or 0) / room) * lineHeight
    if drawn and drawn > height then height = drawn end
    return math.max(BuffButton.MIN_HEIGHT, math.ceil(BuffButton.SUBTITLE_TOP + height + BuffButton.BOTTOM_PAD))
end

-- Grow or shrink the button to its text. Secure buttons can't change size
-- in a fight; the next re-arm after it fits them.
local function FitHeight()
    if InCombatLockdown() then return end
    local height = BuffButton.HeightFor(button.subtitle)
    if button:GetHeight() ~= height then button:SetHeight(height) end
end

-- small: the title in the line below's smaller font (the "Already done"
-- note, #256, so a long first name fits). The font goes first: a font
-- object can bring its own colour and alignment, so the text and left
-- alignment are set after it (#264's testing review).
local function SetLabels(title, subtitle, small)
    button.title:SetFontObject(small and "GameFontNormalSmall" or "GameFontNormal")
    button.title:SetJustifyH("LEFT")
    button.title:SetText(title or "")
    button.subtitle:SetText(subtitle or "")
    FitHeight()
    -- Full strength, unless the "Already done" note is fading (#256).
    button.title:SetAlpha(1)
    button.subtitle:SetAlpha(1)
end

-- Whether a result is still being shown under the button (and show it).
local function ShowRecentResult()
    if shownResult and GetTime() - shownResult.shownAt <= BuffButton.RESULT_SHOWN_SECONDS then
        button.result:SetText(shownResult.text)
        return true
    end
    shownResult = nil
    button.result:SetText("")
    return false
end

local function Empty(reason, keepShown)
    ns.BuffList.Hide()
    armedOffer = nil
    notArmedReason = reason
    SetSecureMacro(nil)
    -- In buff mode the button stays up, saying why there's nothing to press.
    -- A press reaches here without the refresh that would end buff mode, so
    -- Buff Back's section lost mid-session reads as locked here too (#384).
    local lent, buffBack = ns.BuffMode.LentKey(), ns.db.buffBack
    if lent and not (type(buffBack) == "table" and buffBack.unlocked) then
        SetLabels("Buff mode", reason)
        button.icon:SetTexture(BuffButton.PLACEHOLDER_ICON)
    end
    -- The button is protected, so in a fight the game blocks showing or
    -- hiding it. The fight's PLAYER_REGEN_DISABLED comes just before the
    -- lockdown, so this already ran then; a late copy leaves it be (#154).
    if not InCombatLockdown() then
        button:SetShown((keepShown or lent) and true or false)
    end
end

-- "Buff mode: <key>" above the button while a key is lent to it; while the
-- key waits for the offer shown (#452), that it does, and why.
-- shiftBack: the offer is the shift back into your form (#495).
local function ShowMode(keyWaits, shiftBack)
    local lent = ns.BuffMode.LentKey()
    local text = ""
    if lent and keyWaits then
        text = ns.Colours.Text("title", "Buff mode:") .. " "
            .. (shiftBack and BuffButton.ShiftBackText(keyWaits) or BuffButton.KeyWaitText(keyWaits))
    elseif lent then
        text = ns.Colours.Text("title", "Buff mode:") .. " " .. ns.BuffMode.KeyText(lent)
    end
    button.mode:SetText(text)
end

-- What the button says while buff mode's key waits (#452).
function BuffButton.KeyWaitText(why)
    return "click to buff (" .. why .. ")"
end

-- And while it waits for the shift back into your form, which the game
-- refused (#495): why is the game's reason.
function BuffButton.ShiftBackText(why)
    return "click to shift back (" .. why .. ")"
end

-- Whether you have a target. When the game won't say, assume you do: then
-- the macro ends with /targetlasttarget, which can't drop a target you had.
local function HasTarget()
    local ok, exists = pcall(UnitExists, "target")
    if not ok or Util.IsSecret(exists) then return true end
    return exists and true or false
end

-- What to offer now: the newest favour you can return, or in buff mode a
-- group member missing your buff (GroupBuffs.lua), unless a row of the list
-- was clicked: then that player's offer, while they're still offered (#43).
-- nil and why not. Every offer is collected into offerList, by the same
-- rules, for the list; an offer that can't be put in a macro safely is left
-- out of it, as the button could not cast it.
local function NextOffer()
    -- Collected apart, then put in order: favours, your own and your
    -- group's (own), passers-by.
    local favours, own, passers = {}, {}, {}
    local reason, groupReason, everyoneLeft
    -- Nothing owed: skip the spellbook and aura reads entirely.
    if ns.Offers.Count() > 0 then
        local _
        _, reason, everyoneLeft = ns.Offers.Current(favours)
    else
        reason = "nobody is owed a buff"
    end
    if ns.BuffMode.LentKey() then
        local _, selfReason
        _, groupReason = ns.GroupBuffs.Next(own)
        -- In a raid split (#70), say what's yours ("Your share: Divine Spirit").
        local share = groupReason and ns.RaidSplit.ShareText(false)
        if share then groupReason = groupReason .. ". " .. share end
        -- Your self-buffs (#44) come after everyone else, so after the group's
        -- offers in the list: the button takes the first.
        _, selfReason = ns.SelfBuffs.Next(own)
        if selfReason then groupReason = (groupReason and (groupReason .. "; ") or "") .. "You: " .. selfReason end
        -- Your weapon buffs (#45) come last of your own.
        local _, weaponReason = ns.WeaponBuffs.Next(own)
        if weaponReason then
            groupReason = (groupReason and (groupReason .. "; ") or "") .. "Weapons: " .. weaponReason
        end
        -- Passers-by (#39) come after all of your own: only when nothing
        -- above is offered does the button reach them.
        ns.PassersBy.Next(passers)
    end
    -- While the shift back into your form waits (#510, the owner): it comes
    -- straight after your own buffs and your group's, and before favours and
    -- passers-by, so a scroll meant to shift you back never buffs a stranger.
    -- Your own come first in the list then, and the button takes the first
    -- of them, or else the shift back. While a press of it is being cast,
    -- nothing at all is offered.
    local returning = formReturn ~= nil
    local list, isOwn = {}, {}
    local order = returning and { own, favours, passers } or { favours, own, passers }
    for _, part in ipairs(order) do
        for _, offer in ipairs(part) do
            list[#list + 1] = offer
            if part == own then isOwn[offer] = true end
        end
    end
    -- One offer per player: the first, which is the one the button would
    -- make (a player owed a favour who is also in your group appears in both,
    -- one group cast aimed at a player is listed beside another, #305, and
    -- each single buff a member lacks is listed, #313). The rest of a
    -- player's entries are passed over by seen, before any macro is built.
    local castable, seen = {}, {}
    for _, offer in ipairs(list) do
        if not seen[offer.name] and BuffButton.MacroFor(offer, true) then
            seen[offer.name] = true
            castable[#castable + 1] = offer
            -- A group cast that is kept is one row for everyone it covers
            -- (#227): they are not listed again as single buffs. One that is
            -- dropped above leaves them their own rows.
            if offer.cast then
                for _, covered in ipairs(offer.cast.covers) do seen[covered] = true end
            end
        end
    end
    offerList = castable
    local pick = castable[1]
    if returning and pick and not isOwn[pick] then pick = nil end
    if chosenName then
        local chosen
        -- Your group copy and your self-buffs share your name: a clicked row
        -- stays chosen only while an offer of its own kind is there, so a
        -- self-buff never takes a clicked group buff's place ahead of a
        -- favour (#44).
        for _, offer in ipairs(castable) do
            if offer.name == chosenName and BuffButton.OfferKind(offer) == chosenKind then chosen = offer break end
        end
        if chosen then pick = chosen else chosenName = nil end
    end
    if pick then return pick end
    -- Nothing of your own left to buff: the shift back into your form, if
    -- one waits (#495, #510).
    if returning then
        local back = ReturnOffer()
        if back then return back end
        return nil, "shifting you back into " .. formReturn.name
    end
    if #list > 0 then return nil, "the name or spell can't be put in a macro safely" end
    if not ns.BuffMode.LentKey() then return nil, reason end
    -- Favours whose players have left don't hold the button (#270).
    if ns.Offers.Count() == 0 or everyoneLeft then return nil, groupReason end
    return nil, reason .. "; " .. groupReason
end

-- How strongly the "Already done" note shows: 1, then down to 0 over its
-- last ALREADY_DONE_FADE seconds.
local function AlreadyDoneAlpha(elapsed)
    local left = BuffButton.ALREADY_DONE_SECONDS - elapsed
    if left >= BuffButton.ALREADY_DONE_FADE then return 1 end
    return math.max(0, left / BuffButton.ALREADY_DONE_FADE)
end

-- Fade the note a step at a time while it shows: only its alpha changes.
local function FadeAlreadyDone()
    if not alreadyDone or not button then return end
    local alpha = AlreadyDoneAlpha(GetTime() - alreadyDone.shownAt)
    button.title:SetAlpha(alpha)
    button.subtitle:SetAlpha(alpha)
    if alpha > 0 then C_Timer.After(BuffButton.FADE_STEP_SECONDS, ns.Diag.Wrap(FadeAlreadyDone)) end
end

-- A buff another member put up in step as you entered (#256, rule 2): once
-- per buff each round, the button shows "Already done by Ann" in red for
-- ALREADY_DONE_SECONDS, empty (a press does nothing), then moves on. The
-- list beside it is hidden meanwhile. True while it shows.
local function ShowAlreadyDone()
    if not alreadyDone then
        local note = ns.BuffMode.LentKey() and ns.GroupBuffs.TakeInStepNote()
        if not note then return false end
        -- The first name, as the owner's "Already done by Ann": the whole
        -- name is cut short on the button (#264's testing review).
        local by = note.by and Util.FirstName(note.by) or "a group member"
        local shown = { title = "Already done by " .. by, spell = ns.BuffData.SpellName(note.buff) or "",
            icon = ns.BuffData.Icon(note.buff), shownAt = GetTime(), round = ns.GroupBuffs.Round() }
        alreadyDone = shown
        ns.Diag.Log("buffMode", "%s: already done by %s", shown.spell, by)
        C_Timer.After(BuffButton.FADE_STEP_SECONDS, ns.Diag.Wrap(FadeAlreadyDone))
        -- Then the next buff you need. Its own timer ends it: comparing the
        -- clock's difference with the time can fall short by a rounding error.
        C_Timer.After(BuffButton.ALREADY_DONE_SECONDS, ns.Diag.Wrap(function()
            shown.over = true
            BuffButton.Refresh()
        end))
    end
    local elapsed = GetTime() - alreadyDone.shownAt
    -- Shown long enough, buff mode over, or its round over (you left, or a pull).
    if alreadyDone.over or not ns.BuffMode.LentKey()
        or alreadyDone.round ~= ns.GroupBuffs.Round() then
        alreadyDone = nil
        -- Its words go with it, even where nothing replaces them (the
        -- button kept up only for a result line).
        SetLabels("", "")
        return ShowAlreadyDone()
    end
    Empty("already done")
    SetLabels(ns.Colours.Text("bad", alreadyDone.title), alreadyDone.spell, true)
    local alpha = AlreadyDoneAlpha(elapsed)
    button.title:SetAlpha(alpha)
    button.subtitle:SetAlpha(alpha)
    button.icon:SetTexture(alreadyDone.icon or BuffButton.PLACEHOLDER_ICON)
    button:SetShown(true)
    return true
end

-- Write the newest favour you can return onto the button, or empty it.
-- Out of combat only: the game locks secure buttons in a fight.
local function ArmButton()
    if not button or InCombatLockdown() then return end
    CheckReturn()
    ShowMode()
    local showingResult = ShowRecentResult()
    -- Buff Back's section lost mid-session reads as locked (#384).
    local buffBack = ns.db.buffBack
    if type(buffBack) == "table" and buffBack.unlocked then
        alreadyDone = nil -- its fade mustn't dim the move labels
        Empty("the button is unlocked for moving", true)
        SetLabels("Buff button", "Drag, then /friendly move")
        button.icon:SetTexture(BuffButton.PLACEHOLDER_ICON)
        return
    end
    if ns.Battleground.Quiet() then return Empty(ns.Battleground.QuietReason(), false) end
    -- Favours are still owed: they show once you leave (Cities.lua).
    if ns.Cities.ButtonHidden() then
        return Empty("you're in a capital city: favours show once you leave", false)
    end
    local offer, reason = NextOffer()
    -- NextOffer has just read the group: a buff left alone as in step shows first.
    if ShowAlreadyDone() then return end
    if not offer then return Empty(reason, showingResult) end
    -- The last result is about the player last pressed for (#461, the
    -- owner): once the button offers someone else, it goes, so a stranger's
    -- name never sits above "Gave Thorns to you."
    -- A right-click's line stays until it times out (the owner, #461).
    if showingResult and not shownResult.stays and shownResult.name ~= offer.name then
        shownResult = nil
        button.result:SetText("")
    end
    ns.BuffList.Update(button, offerList, offer.name)

    local hadTarget = HasTarget()
    local macroText = BuffButton.MacroFor(offer, hadTarget)
    if not macroText then return Empty("the name or spell can't be put in a macro safely", showingResult) end

    -- Read now, as the macro is written: a press re-arms first (OnPreClick),
    -- so the form at the moment of the press decides (#452).
    local keyWaits = BuffButton.KeyWaits(offer)
    SetSecureMacro(macroText, keyWaits ~= nil)
    ShowMode(keyWaits, offer.formReturn)
    armedOffer = { keyWaits = keyWaits, name = offer.name, spell = offer.spell, buff = offer.buff, group = offer.group,
        passerBy = offer.passerBy, cast = offer.cast, hint = offer.hint, self = offer.self, selfBuff = offer.selfBuff,
        macroText = macroText, weapon = offer.weapon, slot = offer.slot, hand = offer.hand, castIds = offer.castIds,
        weaponItem = offer.weaponItem, weaponKind = offer.weaponKind,
        formReturn = offer.formReturn, formSpell = offer.formSpell }
    notArmedReason = nil
    button.icon:SetTexture(offer.icon or (offer.buff and ns.BuffData.Icon(offer.buff)) or BuffButton.PLACEHOLDER_ICON)
    if offer.formReturn then
        -- The shift back into your form (#495).
        SetLabels("You", "shift back into " .. offer.spell)
    elseif offer.weapon then
        -- A weapon buff (#45): which, and on which hand.
        SetLabels("You", offer.spell .. " on your " .. offer.hand)
    elseif offer.cast then
        -- A group version (GroupCasts.lua): who it reaches on the first line,
        -- which spell on the second (the whole sentence, "Prayer of
        -- Fortitude on Group 3 (4 missing)", is too wide for the title); the
        -- tooltip says whom it's aimed at.
        SetLabels(string.format("%s (%d missing)", offer.cast.label, offer.cast.count), offer.spell)
    elseif offer.note then
        -- The single buff, and why not its group version.
        SetLabels(offer.self and "You" or Util.DisplayName(offer.name), offer.note)
    elseif offer.request then
        -- They asked for it in chat (Requests.lua, #40).
        SetLabels(Util.DisplayName(offer.name), "asked for " .. offer.spell)
    elseif offer.passerBy then
        -- A passer-by (#39): nobody owes them, and nothing is said to them.
        SetLabels(Util.DisplayName(offer.name), offer.spell .. " (passing by)")
    else
        SetLabels(offer.self and "You" or Util.DisplayName(offer.name),
            (offer.group and "missing your " or "buffed you - give ") .. offer.spell)
    end
    button:SetShown(true)
end

local function ScheduleRecheck()
    if recheckScheduled then return end
    recheckScheduled = true
    C_Timer.After(BuffButton.RECHECK_SECONDS, ns.Diag.Wrap(function()
        recheckScheduled = false
        BuffButton.Refresh()
    end))
end

-- Re-arm now (out of combat), and keep re-checking while favours are owed,
-- a result is showing or buff mode is on: favours expire, targets, flags,
-- range and buffs change.
function BuffButton.Refresh()
    if not button then return end
    ns.BuffMode.Apply()
    ns.GroupBuffs.Prune()
    ns.PassersBy.Prune()
    -- Your buffs or settings may have changed what you give in a raid.
    ns.RaidSplit.Check()
    ArmButton()
    ns.BuffModeAuto.Check()
    if ns.Offers.Count() > 0 or shownResult or ns.BuffMode.LentKey() then ScheduleRecheck() end
end

-- A fight is starting: empty the button while the game still allows it, so
-- nothing armed for the world outside the fight is cast in it.
function BuffButton.OnCombatStart()
    ns.BuffMode.OnCombatStart()
    chosenName = nil
    ForgetForm("a fight started") -- (#495)
    if not button then return end
    Empty("in combat: the button is empty until the fight ends", false)
end

------------------------------------------------------------------------
-- Pressing, and the game's answer
------------------------------------------------------------------------

-- name: the player it is about (you, for your own buffs), by full name.
local function ShowResult(text, alsoInChat, name)
    shownResult = { text = text, shownAt = GetTime(), name = name }
    lastResultText = text
    ns.Diag.LogFolded("result", "buffBack", "%s", text) -- repeats fold (#453)
    if alsoInChat then ns.Print(text) end
end

-- Presses waiting for the game's answer, newest last. Each is
-- { name, spell, buff, lastHalfAt, complete, sent, failed, expired, watch, castGUID, castTargetName }:
--   lastHalfAt      GetTime() of the press's latest half (when it acted)
--   complete        both halves of the press arrived (a press released off
--                   the button never completes, and was no attempt)
--   sent            the game said a cast of the buff went out for it
--                   (UNIT_SPELLCAST_SENT), naming castGUID and castTargetName
--   failed          the game said that cast failed (at failedAt); its error text follows
--   expired         its wait for an answer ran out (see Unanswered)
--   unsure          the button filled between the halves of the press, so it
--                   may have done nothing: no "No answer" is reported for it
--   watch           identifies its current wait (WatchForAnswer)
--   elsewhere       a cast of its buff that went to another player while it
--                   waited unsent: { guid, name, landed } (see OnSpellcastSent)
-- More than one is kept so a second press while the first cast is in flight
-- doesn't lose the first one's answer.
local presses = {}
local pressFromDownHalf -- the press begun by the last down half, until its up half
local downHalfFoundNothing = false -- the last down half came with the button empty

local function ForgetPress(press)
    for i, waiting in ipairs(presses) do
        if waiting == press then
            table.remove(presses, i)
            return true
        end
    end
    return false
end

-- No answer in time. A complete press the game never sent a cast for found
-- nobody to cast on. A cast sent but never answered (a long lag spike) may
-- or may not have landed. A press never completed was no attempt.
local function Unanswered(press)
    if not ForgetPress(press) then return end
    press.expired = true
    local who = press.self and "you" or Util.DisplayName(press.name)
    if press.formReturn and not ReturnStands(press) then
        -- The shift back (#495) whose return is gone: nothing to say.
        return
    elseif press.formReturn and (press.failed or (press.complete and not press.unsure and not press.sent)) then
        -- The shift back that got no answer counts as refused.
        local why = press.failed and "the game gave no reason" or "the game didn't answer"
        RefuseReturn(press, why)
        ShowResult("Couldn't shift back into " .. press.spell .. ": " .. why .. ".", true, press.name)
    elseif press.failed then
        ShowResult("Couldn't buff " .. who
            .. " (the game gave no reason).", true, press.name)
    elseif press.sent then
        -- A shift back with no word: the button offers it again (#495),
        -- unless a newer press of it is being cast.
        if press.formReturn and formReturn.casting == press then formReturn.casting = nil end
        ShowResult("No word back on " .. press.spell .. " for " .. who .. ". If it didn't land, press again.", nil,
            press.name)
    elseif press.complete and not press.unsure then
        if press.elsewhere and press.elsewhere.landed then
            -- Probably the button's cast, sent to someone else (a redirect). It was
            -- also kept as a cast by hand (#133).
            ShowResult(string.format("%s went to %s, not %s.", press.spell,
                Util.StripChat(press.elsewhere.name), who), true, press.name)
        else
            if press.weapon then
                ns.WeaponBuffs.NoteRefused(press.slot, press.weaponItem, press.weaponKind)
            elseif press.selfBuff then
                ns.SelfBuffs.NoteRefused(press.buff)
            elseif press.group then
                ns.GroupBuffs.NoteRefused(press.name)
            end
            if press.weapon then
                ShowResult("No answer: nothing was put on your " .. press.hand .. ".", true, press.name)
            else
                ShowResult("No answer: couldn't find " .. who .. " (out of sight?).", true, press.name)
            end
        end
    else
        return
    end
    BuffButton.Refresh()
end

-- (Re)start the wait for this press's answer, for seconds (by default the
-- time a press has to send a cast). A later restart supersedes an earlier one.
local function WatchForAnswer(press, seconds)
    local watch = {}
    press.watch = watch
    C_Timer.After((seconds or BuffButton.ANSWER_WINDOW_SECONDS) + 0.1, ns.Diag.Wrap(function()
        if press.watch == watch then Unanswered(press) end
    end))
end

-- Fill a press from what the button holds now.
local function TakeArmedOffer(press)
    press.name, press.spell, press.buff = armedOffer.name, armedOffer.spell, armedOffer.buff
    press.group, press.self, press.cast = armedOffer.group, armedOffer.self, armedOffer.cast
    press.selfBuff, press.passerBy = armedOffer.selfBuff, armedOffer.passerBy
    press.weapon, press.slot, press.hand, press.castIds =
        armedOffer.weapon, armedOffer.slot, armedOffer.hand, armedOffer.castIds
    press.weaponItem, press.weaponKind = armedOffer.weaponItem, armedOffer.weaponKind
    press.formReturn, press.formSpell = armedOffer.formReturn, armedOffer.formSpell
    -- A held key or a wheel notch presses many times: repeats fold (#453).
    ns.Diag.LogFolded("press", "buffBack", "pressed: %s", armedOffer.macroText)
    return press
end

-- A new press of the armed favour. A newest press the game never sent a
-- cast for is replaced: this one is the retry.
local function AddPress(complete, unsure)
    local newest = presses[#presses]
    if newest and not newest.sent then table.remove(presses) end
    local press = TakeArmedOffer({ complete = complete, unsure = unsure, lastHalfAt = GetTime() })
    -- A buff press may be taking you out of a form to go back to (#495).
    if not press.formReturn then NoteBuffPress() end
    presses[#presses + 1] = press
    while #presses > BuffButton.MAX_PRESSES_WATCHED do table.remove(presses, 1) end
    WatchForAnswer(press)
    return press
end

-- Whether two group casts (GroupCasts.lua) differ in whom they reach.
local function CastDiffers(a, b)
    if a == nil or b == nil then return a ~= b end
    return a.key ~= b.key or a.count ~= b.count
end

-- Before the secure action runs. Which half of a press (down or up) the game
-- acts on depends on the input and its settings, so this runs for both
-- halves and re-arms each time, at the last moment (your target may have
-- changed; it does nothing when nothing changed).
--
-- A press is recorded on its down half, or on its up half when no down half
-- came first (a click delivered on release only). On the up half it is
-- brought up to date: if the game hasn't cast for it yet and the button now
-- holds another favour, that favour is what the up half casts.
local function OnPreClick(_, mouseButton, isDown)
    local key = mouseButton == BuffButton.KEY_BUTTON
    if mouseButton ~= "LeftButton" and not key then return end
    -- A press reads passers-by afresh (#39): the last second's look never
    -- decides a cast.
    ns.PassersBy.Fresh()
    ArmButton()
    -- Buff mode's key finds no action while it waits (#452): ArmButton has
    -- just written none for it, so its press is no press, and says so.
    local armed = armedOffer
    if key and armed and armed.keyWaits then
        armed = nil
        -- Once a press: on its down half, or its up half when no down half
        -- came. Not on the up half of a press the down half made: the
        -- shift back refused in between (#495) keeps the game's reason shown.
        if isDown ~= false or not (downHalfFoundNothing or pressFromDownHalf) then
            -- About the offer showing, so it stays under it (#461).
            ShowResult((armedOffer.formReturn and "Click the button to shift back: " or "Click the button to buff: ")
                .. armedOffer.keyWaits .. ".", nil, armedOffer.name)
            ShowRecentResult()
        end
    end
    if isDown == true then
        pressFromDownHalf = armed and AddPress(false) or nil
        downHalfFoundNothing = not armed
        return
    end
    local press = pressFromDownHalf
    local downHalfWasEmpty = downHalfFoundNothing
    pressFromDownHalf, downHalfFoundNothing = nil, false
    if not press then
        -- No down half, or it had nothing armed: this half is the press. If
        -- the down half came with the button empty, the game may have acted
        -- on it (doing nothing), so silence isn't reported as "No answer".
        if armed then AddPress(true, downHalfWasEmpty) end
        return
    end
    if not ForgetPress(press) then
        -- Answered already (the down half acted), or given up on while the
        -- key was held: only then is this half a press of its own.
        if press.expired and not press.sent and armed then AddPress(true) end
        return
    end
    presses[#presses + 1] = press
    press.complete = true
    if press.sent then return end -- the down half acted; its wait continues
    if armed and (armed.name ~= press.name or armed.spell ~= press.spell
        or CastDiffers(armed.cast, press.cast)) then
        TakeArmedOffer(press)
    end
    press.lastHalfAt = GetTime()
    WatchForAnswer(press)
end

-- Right-click lets the shown favour go, or skips the shown group member for
-- a while (once, as the button comes up). Shift+right-click on a group
-- member's buff puts them on that buff's Never list (BuffRules.lua).
local function OnPostClick(_, mouseButton, isDown)
    -- The down half of a press of the button, by any binding (the mouse
    -- wheel too) or mouse button, is the player's hardware event: a /say
    -- held for one goes now (#271; see ChatQueue.OnHardwareEvent). Only the
    -- down half: a click from code (Button:Click) arrives as an up half, and
    -- nothing in the addon clicks this button. After the secure action, so
    -- the cast never waits on chat.
    if isDown == true then ns.ChatQueue.OnHardwareEvent() end
    if mouseButton ~= "RightButton" or isDown == true or not armedOffer then return end
    -- Kept: changing a Never list re-arms the button.
    local offer = armedOffer
    local name = offer.name
    if offer.formReturn then
        -- The shift back (#495): you stay as you are.
        ForgetForm("you right-clicked it")
        ShowResult("Staying out of " .. offer.spell .. ".", nil, name)
    elseif offer.weapon then
        -- Your weapon buffs (#45): all of them, for a while.
        ns.WeaponBuffs.Skip()
        local minutes = ns.WeaponBuffs.SKIP_SECONDS / 60
        ShowResult(string.format("Skipping your weapon buffs for %d minutes.", minutes), nil, name)
    elseif offer.selfBuff then
        -- Your self-buffs (#44): all of them, for a while. Shift too: who
        -- gets a buff doesn't apply to them.
        ns.SelfBuffs.Skip()
        ShowResult(string.format("Skipping your self-buffs for %d minutes.", ns.SelfBuffs.SKIP_SECONDS / 60), nil, name)
    elseif offer.cast then
        -- A group version: only that cast is left out; its members are
        -- still offered the single buff. Shift adds nobody to a Never list.
        ns.GroupCasts.Skip(offer.cast.key)
        ShowResult(string.format("Skipping %s on %s for %d minutes.", offer.spell, offer.cast.label,
            ns.GroupCasts.SKIP_SECONDS / 60), nil, name)
    elseif offer.group and Util.ReadGameValues(IsShiftKeyDown) == true then
        ns.Options.FinishEdits()
        -- The Never list of the place you're in (#408), where the offer was
        -- made, or of each place it could be when the game won't say;
        -- 1.3.3's while the choice waits.
        local ok, why = true, nil
        if ns.BuffRules.Pending() then
            ok, why = ns.BuffRules.AddName(offer.buff.key, "never", name)
        else
            for _, place in ipairs(ns.BuffRules.Place()) do
                if ok then ok, why = ns.BuffRules.AddName(offer.buff.key, "never", name, place) end
            end
        end
        if ok then
            -- While pending, the list isn't on the tab until you choose (#408's review).
            ShowResult(string.format(ns.BuffRules.Pending()
                and "%s won't get %s (Never list; \"Keep my settings\" keeps it)."
                or "%s won't get %s (Never list, on the Buffs tab).",
                offer.self and "You" or Util.DisplayName(name), offer.spell), nil, name)
        else
            ShowResult("Couldn't add " .. (offer.self and "you" or Util.DisplayName(name))
                .. " to the Never list: " .. why .. ".", true, name)
        end
        ns.Options.Refresh()
    elseif offer.passerBy then
        -- A passer-by (#39): Shift adds them to no list (the ignore list is
        -- the place for a name).
        ns.PassersBy.SkipName(name)
        ShowResult(string.format("Skipping %s for %d minutes.", Util.DisplayName(name),
            ns.PassersBy.SKIP_SECONDS / 60), nil, name)
    elseif offer.group then
        ns.GroupBuffs.Skip(name)
        ShowResult(string.format("Skipping %s for %d minutes.", offer.self and "yourself" or Util.DisplayName(name),
            ns.GroupBuffs.SKIP_SECONDS / 60), nil, name)
    else
        ns.Offers.LetGo(name)
        ShowResult("Let " .. Util.DisplayName(name) .. " go.", nil, name)
    end
    -- Its line stays until it times out, wherever the button moves (the owner, #461).
    if shownResult then shownResult.stays = true end
    BuffButton.Refresh()
end

-- A game value usable as a key or text: a non-empty string that isn't secret.
local function ReadableText(value)
    if Util.IsSecret(value) or type(value) ~= "string" or value == "" then return nil end
    return value
end

-- The newest waiting press that one of our casts (unit, spell ID) could
-- answer, for which wanted(press) holds.
local function NewestPressFor(unit, spellId, wanted)
    if unit ~= "player" or Util.IsSecret(spellId) or type(spellId) ~= "number" then return nil end
    local groupBuff = ns.BuffData.ForGroupCast(spellId)
    local buff = groupBuff or ns.BuffData.ForCast(spellId)
    for i = #presses, 1, -1 do
        local press = presses[i]
        if press.formReturn then
            -- The shift back (#495) is answered by its form's spell.
            if spellId == press.formSpell and wanted(press) then return press end
        elseif press.weapon then
            -- A weapon buff (#45) is answered by its item's spell or its imbue's ranks.
            if press.castIds[spellId] and wanted(press) then return press end
        -- A group version answers only a press of a group version (#41).
        elseif buff and press.buff == buff and (press.cast ~= nil) == (groupBuff ~= nil) and wanted(press) then
            return press
        end
    end
end

-- The press a cast (castGUID, unit, spell ID) answers: the one it was sent
-- for, or when the game didn't say, the newest that matches.
local function PressForCast(unit, castGUID, spellId)
    local guid = ReadableText(castGUID)
    if guid then
        local sentFor = NewestPressFor(unit, spellId, function(press) return press.castGUID == guid end)
        if sentFor then return sentFor end
    end
    -- The game gave no readable GUID: a press that was sent without one. A
    -- press still waiting to be sent isn't answered by a cast made by hand.
    return NewestPressFor(unit, spellId, function(press) return press.sent and press.castGUID == nil end)
end

-- Whether the name the game says a cast went to is the intended player.
-- The game may report "First", "First Surname" or "First-Surname".
-- nil when the name can't be read as a player's.
function BuffButton.IsIntendedPlayer(reportedName, intendedFullName)
    local reported = Util.FullName(reportedName)
    if not reported then return nil end
    return reported == intendedFullName or reported == Util.FirstName(intendedFullName)
end

-- UNIT_SPELLCAST_SENT: the game is sending a cast of the buff for the newest
-- press not yet sent, and may name who it is going to (a second check on top
-- of /targetexact). A cast the game says went to another player isn't that
-- press's: it is a cast by hand, and the press keeps waiting (#133). If no
-- cast of its own follows, the press says where that one went (Unanswered).
function BuffButton.OnSpellcastSent(unit, castTargetName, castGUID, spellId)
    local press = NewestPressFor(unit, spellId, function(waiting) return not waiting.sent end)
    -- A weapon buff (#45) goes on your own weapon, and a form (#495) on you:
    -- the game names no player for either.
    if press and not press.weapon and not press.formReturn
        and BuffButton.IsIntendedPlayer(ReadableText(castTargetName), press.name) == false then
        press.elsewhere = { guid = ReadableText(castGUID), name = ReadableText(castTargetName) }
        press = nil
    end
    -- Not the button's: a buff cast by hand is remembered too (#37).
    if not press then return ns.Offers.OnCastSent(unit, castTargetName, castGUID, spellId) end
    press.sent = true
    -- The shift back (#495) is being cast: the button offers it again only
    -- if this cast doesn't land.
    if press.formReturn and ReturnStands(press) then formReturn.casting = press end
    press.castGUID = ReadableText(castGUID)
    press.castTargetName = ReadableText(castTargetName)
    WatchForAnswer(press, BuffButton.SENT_ANSWER_SECONDS)
end

-- The setting; a section lost mid-session reads as off (#387).
local function SayLineOn()
    local cfg = ns.db.buffBack
    return type(cfg) == "table" and cfg.sayLine == true
end

-- After a favour is returned: queue the optional line, sent the way Buff
-- Thanks' "Thank them with" choice says (#101): in /say (also for "a line and an emote"),
-- whispered to them, or, for the emote, a plain /thank aimed at them (or at
-- everyone around, if the game shows them under no unit). It goes under the
-- same rules as a thank-you: ChatQueue sends a /say line on your next key
-- press (a whisper or an emote goes at once), and drops it if it waits too long, or if the setting is
-- turned off or they're ignored meanwhile.
local function SayLineFor(press)
    if not SayLineOn() then return end
    local style = ns.db.buff.thankStyle
    local whisper, emote = style == "whisper", style == "emote"
    ns.Announcer.Schedule("buffBack", press.name, {
        channel = whisper and "WHISPER" or "SAY",
        target = whisper and press.name or nil,
        emote = emote and "THANK" or nil,
        emoteTarget = emote and function() return ns.Offers.UnitFor(press.name) end or nil,
        delay = 0,
        cooldown = 0, -- a favour is only returned once, so each return says one line
        maxAge = (not whisper) and ns.BuffTracker.SAY_MAX_AGE or nil,
        dropOverCap = true, -- a thank-you of sorts: dropped over the chat cap, like thanks
        vars = function()
            local vars = Util.NameVars(press.name)
            vars.buff = press.spell
            return vars
        end,
        isValid = function()
            if not SayLineOn() then return false, "the line is switched off" end
            if ns.Ignore.Has(press.name) then return false, "on your ignore list" end
            return true
        end,
    })
end

-- The cast landed. It counts as returned only when the game says it went to
-- them (UNIT_SPELLCAST_SENT's target): a cast of the same spell made some
-- other way in the same moment mustn't be credited to the favour.
function BuffButton.OnSpellcastSucceeded(unit, castGUID, spellId)
    local press = PressForCast(unit, castGUID, spellId)
    if not press then
        local guid = ReadableText(castGUID)
        for _, waiting in ipairs(presses) do
            if guid and waiting.elsewhere and waiting.elsewhere.guid == guid then waiting.elsewhere.landed = true end
        end
        return ns.Offers.OnCastLanded(unit, castGUID)
    end
    ForgetPress(press)
    local who = press.self and "you" or Util.DisplayName(press.name)
    -- castTargetName is only ever the intended player's (OnSpellcastSent).
    local reachedThem = press.castTargetName and BuffButton.IsIntendedPlayer(press.castTargetName, press.name)
    if press.formReturn then
        -- Back in your form (#495): the return is done.
        ForgetForm("back in it")
        ShowResult("Back in " .. press.spell .. ".", nil, press.name)
    elseif press.weapon then
        -- A weapon buff (#45): on your own weapon, no favour, no line.
        ns.WeaponBuffs.NoteGiven(press.slot)
        ShowResult("Applied " .. press.spell .. " to your " .. press.hand .. ".", nil, press.name)
    elseif press.selfBuff then
        -- A self-buff (#44) can only be cast on you: no favour, no line, no
        -- thanks, and nobody else to note.
        ns.SelfBuffs.NoteGiven(press.buff)
        ShowResult("Cast " .. press.spell .. " on you.", nil, press.name)
    elseif reachedThem == nil then
        -- The dungeon-or-raid round (#256) counts it as given anyway.
        if press.cast then
            for _, covered in ipairs(press.cast.covers) do ns.GroupBuffs.NoteRoundCast(covered, press.buff) end
        elseif press.group then
            ns.GroupBuffs.NoteRoundCast(press.name, press.buff)
        elseif press.passerBy then
            -- A passer-by (#39) isn't offered it again at every press.
            ns.PassersBy.NoteGiven(press.name, press.buff)
        end
        ShowResult("Cast " .. press.spell .. ", but the game didn't say it reached " .. who .. ".", nil, press.name)
    elseif press.cast then
        -- A group version reached the target's party: everyone it covered
        -- counts as just given (the game updates their buffs a moment
        -- later); those out of range are filled in one by one afterwards.
        for _, covered in ipairs(press.cast.covers) do ns.GroupBuffs.NoteGiven(covered, press.buff) end
        ShowResult(string.format("Cast %s on %s.", press.spell, press.cast.label), nil, press.name)
    elseif press.group then
        -- A group buff: no favour, no line, no thanks.
        ns.GroupBuffs.NoteGiven(press.name, press.buff)
        ShowResult("Gave " .. press.spell .. " to " .. who .. ".", nil, press.name)
    else
        -- Their copy hears it was you, in case their game can't say (#138).
        ns.Receipts.Send(press.name, press.buff)
        local returned, asked = ns.Offers.MarkReturned(press.name, press.spell)
        -- A passer-by (#39) isn't offered that buff again for a while.
        if press.passerBy then ns.PassersBy.NoteGiven(press.name, press.buff) end
        if press.passerBy and not returned then
            -- Nothing is said to a passer-by, and nothing was owed.
            ShowResult("Gave " .. press.spell .. " to " .. who .. " (passing by).", nil, press.name)
        elseif returned and asked then
            -- A request in chat (#40): no favour, so no buff-back line.
            ShowResult("Gave " .. press.spell .. " to " .. who .. ", who asked for it.", nil, press.name)
        elseif returned then
            ShowResult("Returned " .. press.spell .. " to " .. who .. ".", nil, press.name)
            SayLineFor(press)
        else
            ShowResult("Cast " .. press.spell .. " on " .. who .. " (no favour was waiting).", nil, press.name)
        end
    end
    BuffButton.Refresh()
end

-- The last error text no press took, in case its failure comes just after
-- it (the order of the two isn't known for Forever): { text, at }.
local unclaimedError

-- What a refusal's text (#483, the owner) is about, read from the words
-- the game shows, lower case, with any end stops left off (localization
-- isn't planned: #211). "target": about the player it aimed at, who then
-- waits (#459): too low level, out of range, out of sight, not a valid
-- target, or wearing a stronger copy. "cooldown": a press in the global
-- cooldown, which is no refusal at all. Anything else, "you": about you
-- (mana, combat, a form, silence) or a text not known to be about them,
-- unreadable included: it holds nobody. The first three are the texts of
-- the owner's 1.4.3 log (docs/forever-facts.md); the others are Classic's,
-- unconfirmed on Forever (#488).
BuffButton.TARGET_REFUSALS = {
    ["target is too low level"] = true,
    ["out of range"] = true,
    ["target not in line of sight"] = true,
    ["invalid target"] = true,
    ["a more powerful spell is already active"] = true,
}
BuffButton.COOLDOWN_REFUSALS = {
    ["spell is not ready yet"] = true,
    ["ability is not ready yet"] = true,
}
function BuffButton.RefusalKind(text)
    if Util.IsSecret(text) or type(text) ~= "string" then return "you" end
    local words = Util.StripChat(text):lower():gsub("[%s%.!]+$", "")
    if BuffButton.COOLDOWN_REFUSALS[words] then return "cooldown" end
    if BuffButton.TARGET_REFUSALS[words] then return "target" end
    return "you"
end

-- The last refusal line said in chat, so a key held down on a refusal
-- about you (no mana: the button offers the same player again) says it
-- once, not at every press: { text, at }.
local lastRefusalSaid

local function ReportRefusal(press, text)
    ForgetPress(press)
    local kind = BuffButton.RefusalKind(text)
    if kind == "cooldown" then
        -- A press in the global cooldown (#483) isn't a refusal: nobody
        -- waits and nothing is said. The next press offers the same.
        ns.Diag.LogFolded("cooldown", "buffBack", "not ready yet: %s", press.spell)
        BuffButton.Refresh()
        return
    end
    -- A weapon buff (#45) keeps its own count of refusals. For a player
    -- (#459, #483, the owner), only a refusal about them holds them a
    -- moment, so the next press tries the next: a group member (a group
    -- version's aim too), a passer-by, or a favour or request. A self-buff
    -- waits too, when the refusal is about it on you (a stronger copy
    -- worn). A refusal about you holds nobody: the button stays on them
    -- and shows why.
    local line = "Couldn't buff " .. (press.self and "you" or Util.DisplayName(press.name))
        .. ": " .. Util.StripChat(text)
    if press.formReturn then
        -- The shift back (#495): the key waits from now on, with the game's
        -- reason; a click tries again. Nobody is held. Once the return is
        -- gone, its answer says nothing.
        if not ReturnStands(press) then return BuffButton.Refresh() end
        local why = Util.StripChat(text):gsub("[%s%.!]+$", "")
        RefuseReturn(press, why)
        line = "Couldn't shift back into " .. press.spell .. ": " .. Util.StripChat(text)
    elseif press.weapon then
        ns.WeaponBuffs.NoteRefused(press.slot, press.weaponItem, press.weaponKind)
    elseif kind == "target" then
        if press.selfBuff then
            ns.SelfBuffs.NoteRefused(press.buff)
        elseif press.group then
            ns.GroupBuffs.NoteRefused(press.name)
        elseif press.passerBy then
            ns.PassersBy.NoteRefused(press.name)
        else
            ns.Offers.NoteRefused(press.name)
        end
    end
    local said = lastRefusalSaid
    local repeated = said ~= nil and said.text == line and GetTime() - said.at >= 0
        and GetTime() - said.at < BuffButton.RESULT_SHOWN_SECONDS
    if not repeated then lastRefusalSaid = { text = line, at = GetTime() } end
    ShowResult(line, not repeated, press.name)
    BuffButton.Refresh()
end

-- The cast failed. The game's error text (UI_ERROR_MESSAGE) gives the
-- reason: usually it follows and answers the press then (OnUIError), but if
-- it came a moment before, after the press, it is taken now. Each error
-- text answers one failure at most.
function BuffButton.OnSpellcastFailed(unit, castGUID, spellId)
    local press = PressForCast(unit, castGUID, spellId)
    if not press then return end
    local now = GetTime()
    press.sent, press.failed, press.failedAt = true, true, now
    lastResultText = "the cast of " .. press.spell .. " failed"
    local recent = unclaimedError
    unclaimedError = nil
    if recent and recent.at >= press.lastHalfAt and now - recent.at <= BuffButton.ERROR_ANSWER_SECONDS then
        ReportRefusal(press, recent.text)
    end
end

-- A shift back whose cast stopped (#495): the button offers it again,
-- unless a newer press of it is being cast.
local function ShiftBackStopped(press)
    if not ReturnStands(press) or formReturn.casting ~= press then return end
    formReturn.casting = nil
    BuffButton.Refresh()
end

-- The cast failed with nothing to say (cancelled, say): no error text
-- follows, so the press is simply answered.
function BuffButton.OnSpellcastFailedQuiet(unit, castGUID, spellId)
    local press = PressForCast(unit, castGUID, spellId)
    if not press then return end
    ForgetPress(press)
    lastResultText = "the cast of " .. press.spell .. " stopped"
    ShiftBackStopped(press)
end

-- A cast cut off (you moved during Ghost Wolf's cast). Which of this and
-- the quiet failure Forever sends is unconfirmed (#498). Only a shift back
-- is touched; the press is kept, for an error text that may follow.
function BuffButton.OnSpellcastInterrupted(unit, castGUID, spellId)
    local press = PressForCast(unit, castGUID, spellId)
    if press then ShiftBackStopped(press) end
end

-- The press the game's red error text answers: the newest whose cast just
-- failed (the server's refusal, however late the failure came), or else the
-- newest pressed a moment ago (a refusal before anything was sent: "Out of
-- range."). Errors any later are about something else.
local function PressForError()
    local now = GetTime()
    for i = #presses, 1, -1 do
        local press = presses[i]
        if press.failed and now - press.failedAt <= BuffButton.ERROR_ANSWER_SECONDS then return press end
    end
    local newest = presses[#presses]
    if newest and now - newest.lastHalfAt <= BuffButton.ERROR_ANSWER_SECONDS then return newest end
end

function BuffButton.OnUIError(_, message)
    local text = ReadableText(message)
    if not text then return end
    local press = PressForError()
    if press then
        ReportRefusal(press, text)
    else
        unclaimedError = { text = text, at = GetTime() }
    end
end

------------------------------------------------------------------------
-- Moving
------------------------------------------------------------------------

-- Unlock to drag the button; locking saves where it is.
function BuffButton.SetUnlocked(unlock)
    if not button then return false, "the button isn't ready yet" end
    if InCombatLockdown() then return false, "it can't be moved in combat" end
    -- Through Config.Section: a section lost mid-session is healed first (#387).
    local cfg = ns.Config.Section("buffBack")
    cfg.unlocked = unlock and true or false
    if unlock then
        button:RegisterForDrag("LeftButton")
    else
        button:RegisterForDrag()
        local point, _, _, x, y = button:GetPoint()
        if point then
            cfg.position = ns.Config.CleanPosition({ point = point, x = x, y = y },
                ns.Config.DEFAULTS.buffBack.position)
        end
    end
    BuffButton.Refresh()
    return true
end

------------------------------------------------------------------------
-- Creating
------------------------------------------------------------------------

local function ShowTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(ns.TITLE .. ": buff button")
    -- The button's second line, in full (it wraps on the button too, #270).
    local subtitle = button.subtitle:GetText()
    local r, g, b = ns.Colours.RGB("title")
    if subtitle and subtitle ~= "" then GameTooltip:AddLine(subtitle, r, g, b, true) end
    -- The raid buff split (#70): yours, and who has the rest.
    local share = ns.BuffMode.LentKey() and ns.RaidSplit.ShareText(true)
    if share then GameTooltip:AddLine(share, r, g, b, true) end
    -- Why not the group version, when that isn't worth the button's face.
    if armedOffer and armedOffer.hint then GameTooltip:AddLine(armedOffer.hint, r, g, b, true) end
    if armedOffer then
        r, g, b = ns.Colours.RGB("bright")
        local reach = armedOffer.cast and string.format(" (reaches %s, %d missing)", armedOffer.cast.label,
            armedOffer.cast.count) or ""
        if armedOffer.formReturn then
            GameTooltip:AddLine("Shifts you back into " .. armedOffer.spell .. ".", r, g, b, true)
        elseif armedOffer.weapon then
            GameTooltip:AddLine("Puts " .. armedOffer.spell .. " on your " .. armedOffer.hand .. ".", r, g, b, true)
        elseif armedOffer.self then
            GameTooltip:AddLine("Casts " .. armedOffer.spell .. " on you; your target stays as it is.", r, g, b, true)
        else
            GameTooltip:AddLine("Casts " .. armedOffer.spell .. " on " .. Util.DisplayName(armedOffer.name) .. reach
                .. ", then gives you your target back.", r, g, b, true)
        end
    end
    r, g, b = ns.Colours.RGB("text")
    local rightClick = "let them go."
    if armedOffer and armedOffer.weapon then
        rightClick = string.format("skip your weapon buffs for %d minutes.", ns.WeaponBuffs.SKIP_SECONDS / 60)
    elseif armedOffer and armedOffer.formReturn then
        rightClick = "stay out of the form."
    elseif armedOffer and armedOffer.self then
        rightClick = "skip yourself for a while."
    end
    GameTooltip:AddLine("Click or press its key to cast. Right-click to " .. rightClick, r, g, b, true)
    GameTooltip:Show()
end

-- One re-arm on the next frame for any number of events now (nameplates come
-- and go by the dozen in a city).
local refreshSoonScheduled = false
local function RefreshSoon()
    if refreshSoonScheduled or (ns.Offers.Count() == 0 and not ns.BuffMode.LentKey()) then return end
    refreshSoonScheduled = true
    C_Timer.After(0, ns.Diag.Wrap(function()
        refreshSoonScheduled = false
        BuffButton.Refresh()
    end))
end

local function OnSpellsChanged()
    ns.BuffData.SpellsChanged()
    BuffButton.Refresh()
end

local function CreateEventFrame()
    eventFrame = CreateFrame("Frame")
    local handlers = {
        UNIT_SPELLCAST_SENT = BuffButton.OnSpellcastSent,
        UNIT_SPELLCAST_SUCCEEDED = BuffButton.OnSpellcastSucceeded,
        UNIT_SPELLCAST_FAILED = BuffButton.OnSpellcastFailed,
        UNIT_SPELLCAST_FAILED_QUIET = BuffButton.OnSpellcastFailedQuiet,
        UNIT_SPELLCAST_INTERRUPTED = BuffButton.OnSpellcastInterrupted,
        UI_ERROR_MESSAGE = BuffButton.OnUIError,
        PLAYER_TARGET_CHANGED = BuffButton.Refresh,
        -- Someone owed may come into view (or go): their PvP flag can be read only then.
        NAME_PLATE_UNIT_ADDED = RefreshSoon,
        -- In buff mode, who's in your group decides whom to buff.
        GROUP_ROSTER_UPDATE = RefreshSoon,
        NAME_PLATE_UNIT_REMOVED = RefreshSoon,
        -- Into or out of a capital city, where the button may stay hidden.
        ZONE_CHANGED = RefreshSoon,
        ZONE_CHANGED_INDOORS = RefreshSoon,
        ZONE_CHANGED_NEW_AREA = RefreshSoon,
        -- Into or out of a rested place, where weapon buffs aren't offered (#449).
        PLAYER_UPDATE_RESTING = RefreshSoon,
        PLAYER_REGEN_DISABLED = BuffButton.OnCombatStart,
        PLAYER_REGEN_ENABLED = BuffButton.Refresh,
        SPELLS_CHANGED = OnSpellsChanged,
        -- Into or out of a form: whether buff mode's key waits (#452). A
        -- press re-reads the form anyway; this keeps the button's words right.
        -- The form is read at once (#495): leaving one for a buff press is
        -- told apart from a shift by hand by how soon it follows the press.
        UPDATE_SHAPESHIFT_FORM = function()
            ObserveForm()
            RefreshSoon()
        end,
    }
    for event in pairs(handlers) do
        if event:find("^UNIT_") then
            eventFrame:RegisterUnitEvent(event, "player")
        else
            eventFrame:RegisterEvent(event)
        end
    end
    eventFrame:SetScript("OnEvent", function(_, event, ...) ns.Diag.Call(handlers[event], ...) end)
end

-- Made out of combat only: a secure frame can't be shown, hidden or set up in
-- a fight (a /reload mid-fight lands here), so then it waits for the end.
local waitingToCreate
function BuffButton.Create()
    if button then return end
    if InCombatLockdown() then
        if not waitingToCreate then
            waitingToCreate = CreateFrame("Frame")
            waitingToCreate:RegisterEvent("PLAYER_REGEN_ENABLED")
            waitingToCreate:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                ns.Diag.Call(BuffButton.Create)
            end)
        end
        return
    end
    button = CreateFrame("Button", BuffButton.FRAME_NAME, UIParent, "SecureActionButtonTemplate")
    button:SetSize(BuffButton.WIDTH, BuffButton.MIN_HEIGHT)
    local position = ns.db.buffBack.position
    button:SetPoint(position.point, UIParent, position.point, position.x, position.y)
    button:SetFrameStrata("MEDIUM")
    button:SetMovable(true)
    button:SetClampedToScreen(true)
    -- Both halves of a press arrive; the secure template acts on the one the
    -- game's key-down setting says (see OnPreClick).
    button:RegisterForClicks("AnyUp", "AnyDown")
    button:SetScript("PreClick", ns.Diag.Wrap(OnPreClick))
    button:SetScript("PostClick", ns.Diag.Wrap(OnPostClick))
    button:SetScript("OnDragStart", function(self)
        local cfg = ns.db.buffBack -- lost mid-session reads as locked (#387)
        if type(cfg) == "table" and cfg.unlocked and not InCombatLockdown() then self:StartMoving() end
    end)
    button:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Our saved position is the one to use, not the game's layout cache.
        self:SetUserPlaced(false)
    end)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(ns.Colours.RGBA("shade"))
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(36, 36)
    button.icon:SetPoint("TOPLEFT", 4, -4)
    -- The name and the favour span the room right of the icon. The name is
    -- one line: the game cuts a name that doesn't fit with "...". The line
    -- below wraps, and the button grows to hold it, from its saved anchor point (#270).
    button.title = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    button.title:SetPoint("TOPLEFT", button.icon, "TOPRIGHT", 6, -2)
    button.title:SetPoint("TOPRIGHT", button, "TOPRIGHT", -6, -6)
    button.title:SetJustifyH("LEFT")
    button.title:SetWordWrap(false)
    button.subtitle = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.subtitle:SetPoint("TOPLEFT", button, "TOPLEFT", BuffButton.TEXT_LEFT, -BuffButton.SUBTITLE_TOP)
    button.subtitle:SetPoint("TOPRIGHT", button, "TOPRIGHT", -BuffButton.TEXT_RIGHT, -BuffButton.SUBTITLE_TOP)
    button.subtitle:SetJustifyH("LEFT")
    button.subtitle:SetJustifyV("TOP")
    button.subtitle:SetWordWrap(true)
    button.result = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.result:SetPoint("TOP", button, "BOTTOM", 0, -2)
    button.mode = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.mode:SetPoint("BOTTOM", button, "TOP", 0, 2)
    if ns.db.buffBack.unlocked then button:RegisterForDrag("LeftButton") end
    button:Hide()

    CreateEventFrame()
    ns.Offers.OnChange(BuffButton.Refresh)
    BuffButton.Refresh()
end

------------------------------------------------------------------------
-- For /friendly buffback and the tests
------------------------------------------------------------------------

function BuffButton.Frame() return button end

-- Why buff mode's key waits now (#452, #485), for buff mode's own lines:
-- for the offer the button holds, or with none, for a buff of yours (a
-- weapon buff never waits); nil when the key presses the button.
function BuffButton.KeyWaitsNow()
    if armedOffer then return armedOffer.keyWaits end
    return BuffButton.KeyWaits({})
end

-- An offer's kind, for a clicked row: your self-buffs (#44) and your weapon
-- buffs (#45) share your name with your own copy of a group buff, so each
-- stays chosen only while an offer of its own kind is there.
function BuffButton.OfferKind(offer)
    if offer.weapon then return "weapon" end
    if offer.selfBuff then return "self" end
    return "other"
end

-- A row of the list was clicked (BuffList.lua): this player's offer of the
-- row's kind (BuffButton.OfferKind) is the next one, while it's still
-- offered. Out of combat only.
function BuffButton.Choose(name, kind)
    if InCombatLockdown() then return end
    chosenName = name
    chosenKind = (kind == "self" or kind == "weapon") and kind or "other"
    BuffButton.Refresh()
end
function BuffButton.ArmedOffer() return armedOffer end
BuffButton.SECURE_ATTRIBUTE = SECURE_ATTRIBUTE

function BuffButton.StatusLines()
    local out = {}
    out[#out + 1] = string.format("offer my buff back: %s, %d favour(s) owed",
        ns.Config.Section("buffBack").enabled and "on" or "off",
        ns.Offers.Count())
    local names = {}
    for _, buff in ipairs(ns.BuffData.Mine()) do names[#names + 1] = ns.BuffData.SpellName(buff) or buff.key end
    out[#out + 1] = "your buffs: " .. (#names > 0 and table.concat(names, ", ") or "none known")
    if armedOffer then
        out[#out + 1] = "armed: " .. armedOffer.spell .. " for " .. Util.DisplayName(armedOffer.name)
        -- Lines joined with " ; " ("|" is the game's escape character in chat).
        out[#out + 1] = "macro: " .. armedOffer.macroText:gsub("\n", " ; ")
        -- Whether buff mode's key presses it too (#452, checked in game on #454).
        out[#out + 1] = armedOffer.keyWaits and ("buff mode's key waits: " .. armedOffer.keyWaits)
            or "buff mode's key presses it too"
    else
        out[#out + 1] = "not armed: " .. tostring(notArmedReason or "nothing to offer")
    end
    out[#out + 1] = ns.BuffMode.StatusLine()
    if not button then out[#out + 1] = "the button is made when this fight ends" end
    if InCombatLockdown() then out[#out + 1] = "in combat: the button stays empty until the fight ends" end
    out[#out + 1] = "last result: " .. lastResultText
    return out
end
