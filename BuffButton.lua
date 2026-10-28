-- The buff-back button: shows a favour you owe (Offers.lua) and, when you
-- press it (click, or its key in Key Bindings > AddOns), casts your buff on
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
-- Macros are kept within 255 characters, the game's macro editor limit (the
-- secure attribute's own limit isn't documented, so we stay inside this one).
BuffButton.MACRO_MAX_LENGTH = 255
BuffButton.PLACEHOLDER_ICON = "Interface\\Icons\\Spell_Nature_Regeneration"

-- Attribute names of Blizzard's SecureActionButtonTemplate
-- (https://warcraft.wiki.gg/wiki/SecureActionButtonTemplate). "*" matches any
-- modifier keys held (so Shift+key bindings work too); "1" is the left mouse
-- button, which is also what the "CLICK <button>:LeftButton" key binding
-- presses. No other button has a secure action: right-click is ours (PostClick).
local SECURE_ATTRIBUTE = {
    leftButtonActionType = "*type1",
    leftButtonMacroText = "*macrotext1",
}
local MACRO_ACTION_TYPE = "macro"

-- The text shown for the binding in Key Bindings > AddOns (Bindings.xml).
_G["BINDING_NAME_CLICK " .. BuffButton.FRAME_NAME .. ":LeftButton"] = "Friendly Forever: buff back"

local button, eventFrame
local armedOffer          -- what the button holds: { name, spell, buff, group, revoke, macroText }
local appliedMacroText    -- the macro text last written to the button (to skip rewriting it)
local shownResult         -- the last result under the button: { text, shownAt }
local lastResultText = "nothing pressed yet"
local notArmedReason      -- why the button is empty, for /friendly buffback
local recheckScheduled = false

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
--
-- /cleartarget first makes your current target the "last target", so
-- /targetlasttarget brings it back whether or not /targetexact found them;
-- [help,nodead] casts only on a friendly, living target, so a failed
-- /targetexact casts nothing rather than on someone else.
function BuffButton.BuildCastMacro(playerFullName, spellName, hadTarget)
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

------------------------------------------------------------------------
-- Arming the button
------------------------------------------------------------------------

-- Write the macro (or nothing) to the button, only when it changed.
local function SetSecureMacro(macroText)
    if macroText == appliedMacroText then return end
    button:SetAttribute(SECURE_ATTRIBUTE.leftButtonActionType, macroText and MACRO_ACTION_TYPE or nil)
    button:SetAttribute(SECURE_ATTRIBUTE.leftButtonMacroText, macroText)
    appliedMacroText = macroText
end

local function SetLabels(title, subtitle)
    button.title:SetText(title or "")
    button.subtitle:SetText(subtitle or "")
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
    armedOffer = nil
    notArmedReason = reason
    SetSecureMacro(nil)
    -- In buff mode the button stays up, saying why there's nothing to press.
    local lent = ns.BuffMode.LentKey()
    if lent and not ns.db.buffBack.unlocked then
        SetLabels("Buff mode", reason)
        button.icon:SetTexture(BuffButton.PLACEHOLDER_ICON)
    end
    button:SetShown((keepShown or lent) and true or false)
end

-- "Buff mode: <key>" above the button while a key is lent to it.
local function ShowMode()
    local lent = ns.BuffMode.LentKey()
    button.mode:SetText(lent and ("|cff40ff40Buff mode:|r " .. ns.BuffMode.KeyText(lent)) or "")
end

-- Whether you have a target. When the game won't say, assume you do: then
-- the macro ends with /targetlasttarget, which can't drop a target you had.
local function HasTarget()
    local ok, exists = pcall(UnitExists, "target")
    if not ok or Util.IsSecret(exists) then return true end
    return exists and true or false
end

-- What to offer now: the newest favour you can return, or in buff mode a
-- group member missing your buff (GroupBuffs.lua). nil and why not.
local function NextOffer()
    local offer, reason
    -- Nothing owed: skip the spellbook and aura reads entirely.
    if ns.Offers.Count() > 0 then
        offer, reason = ns.Offers.Current()
    else
        reason = "nobody is owed a buff"
    end
    if offer or not ns.BuffMode.LentKey() then return offer, reason end
    local groupOffer, groupReason = ns.GroupBuffs.Next()
    if groupOffer then return groupOffer end
    if ns.Offers.Count() == 0 then return nil, groupReason end
    return nil, reason .. "; " .. groupReason
end

-- Write the newest favour you can return onto the button, or empty it.
-- Out of combat only: the game locks secure buttons in a fight.
local function ArmButton()
    if not button or InCombatLockdown() then return end
    ShowMode()
    local showingResult = ShowRecentResult()
    if ns.db.buffBack.unlocked then
        Empty("the button is unlocked for moving", true)
        SetLabels("Buff back", "Drag, then /friendly move")
        button.icon:SetTexture(BuffButton.PLACEHOLDER_ICON)
        return
    end
    if ns.Battleground.Quiet() then return Empty(ns.Battleground.QuietReason(), false) end
    local offer, reason = NextOffer()
    if not offer then return Empty(reason, showingResult) end

    local hadTarget = HasTarget()
    local macroText = BuffButton.BuildCastMacro(offer.name, offer.spell, hadTarget)
    if not macroText then return Empty("the name or spell can't be put in a macro safely", showingResult) end

    SetSecureMacro(macroText)
    armedOffer = { name = offer.name, spell = offer.spell, buff = offer.buff, group = offer.group,
        revoke = offer.revoke, macroText = macroText }
    notArmedReason = nil
    button.icon:SetTexture(ns.BuffData.Icon(offer.buff) or BuffButton.PLACEHOLDER_ICON)
    if offer.revoke then
        SetLabels(Util.DisplayName(offer.name), "Revoke their Salvation (" .. offer.why .. ")")
    else
        SetLabels(Util.DisplayName(offer.name),
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
    ArmButton()
    ns.BuffModeAuto.Check()
    if ns.Offers.Count() > 0 or shownResult or ns.BuffMode.LentKey() then ScheduleRecheck() end
end

-- A fight is starting: empty the button while the game still allows it, so
-- nothing armed for the world outside the fight is cast in it.
function BuffButton.OnCombatStart()
    ns.BuffMode.OnCombatStart()
    if not button then return end
    Empty("in combat: the button is empty until the fight ends", false)
end

------------------------------------------------------------------------
-- Pressing, and the game's answer
------------------------------------------------------------------------

local function ShowResult(text, alsoInChat)
    shownResult = { text = text, shownAt = GetTime() }
    lastResultText = text
    ns.Diag.Log("buffBack", "%s", text)
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
    local who = Util.DisplayName(press.name)
    if press.failed then
        ShowResult((press.revoke and "Couldn't revoke Salvation from " or "Couldn't buff ") .. who
            .. " (the game gave no reason).", true)
    elseif press.sent then
        ShowResult("No word back on " .. press.spell .. " for " .. who .. ". If it didn't land, press again.")
    elseif press.complete and not press.unsure then
        if press.group then ns.GroupBuffs.NoteRefused(press.name) end
        ShowResult("No answer: couldn't find " .. who .. " (out of sight?).", true)
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
    press.group, press.revoke = armedOffer.group, armedOffer.revoke
    ns.Diag.Log("buffBack", "pressed: %s", armedOffer.macroText)
    return press
end

-- A new press of the armed favour. A newest press the game never sent a
-- cast for is replaced: this one is the retry.
local function AddPress(complete, unsure)
    local newest = presses[#presses]
    if newest and not newest.sent then table.remove(presses) end
    local press = TakeArmedOffer({ complete = complete, unsure = unsure, lastHalfAt = GetTime() })
    presses[#presses + 1] = press
    while #presses > BuffButton.MAX_PRESSES_WATCHED do table.remove(presses, 1) end
    WatchForAnswer(press)
    return press
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
    if mouseButton ~= "LeftButton" then return end
    ArmButton()
    if isDown == true then
        pressFromDownHalf = armedOffer and AddPress(false) or nil
        downHalfFoundNothing = not armedOffer
        return
    end
    local press = pressFromDownHalf
    local downHalfWasEmpty = downHalfFoundNothing
    pressFromDownHalf, downHalfFoundNothing = nil, false
    if not press then
        -- No down half, or it had nothing armed: this half is the press. If
        -- the down half came with the button empty, the game may have acted
        -- on it (doing nothing), so silence isn't reported as "No answer".
        if armedOffer then AddPress(true, downHalfWasEmpty) end
        return
    end
    if not ForgetPress(press) then
        -- Answered already (the down half acted), or given up on while the
        -- key was held: only then is this half a press of its own.
        if press.expired and not press.sent and armedOffer then AddPress(true) end
        return
    end
    presses[#presses + 1] = press
    press.complete = true
    if press.sent then return end -- the down half acted; its wait continues
    if armedOffer and (armedOffer.name ~= press.name or armedOffer.spell ~= press.spell) then
        TakeArmedOffer(press)
    end
    press.lastHalfAt = GetTime()
    WatchForAnswer(press)
end

-- Right-click lets the shown favour go, or skips the shown group member for
-- a while (once, as the button comes up). Shift+right-click on a group
-- member's buff puts them on that buff's Never list (BuffRules.lua).
local function OnPostClick(_, mouseButton, isDown)
    if mouseButton ~= "RightButton" or isDown == true or not armedOffer then return end
    -- Kept: changing a Never list re-arms the button.
    local offer = armedOffer
    local name = offer.name
    if offer.group and not offer.revoke and Util.ReadGameValues(IsShiftKeyDown) == true then
        ns.Options.FinishEdits()
        local ok, why = ns.BuffRules.AddName(offer.buff.key, "never", name)
        if ok then
            ShowResult(string.format("%s won't get %s (Never list, on the Buff Back tab).",
                Util.DisplayName(name), offer.spell))
        else
            ShowResult("Couldn't add " .. Util.DisplayName(name) .. " to the Never list: " .. why .. ".", true)
        end
        ns.Options.Refresh()
    elseif offer.group then
        ns.GroupBuffs.Skip(name)
        ShowResult(string.format("Skipping %s for %d minutes.", Util.DisplayName(name),
            ns.GroupBuffs.SKIP_SECONDS / 60))
    else
        ns.Offers.LetGo(name)
        ShowResult("Let " .. Util.DisplayName(name) .. " go.")
    end
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
    if unit ~= "player" or Util.IsSecret(spellId) then return nil end
    local buff = ns.BuffData.ForCast(spellId)
    if not buff then return nil end
    for i = #presses, 1, -1 do
        local press = presses[i]
        if press.buff == buff and wanted(press) then return press end
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
    return NewestPressFor(unit, spellId, function(press) return press.castGUID == nil end)
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
-- of /targetexact).
function BuffButton.OnSpellcastSent(unit, castTargetName, castGUID, spellId)
    local press = NewestPressFor(unit, spellId, function(waiting) return not waiting.sent end)
    if not press then return end
    press.sent = true
    press.castGUID = ReadableText(castGUID)
    press.castTargetName = ReadableText(castTargetName)
    WatchForAnswer(press, BuffButton.SENT_ANSWER_SECONDS)
end

-- After a favour is returned: queue the optional line in /say, the same way
-- (and under the same rules) as a thank-you. ChatQueue sends it on your next
-- key press; it's dropped if it waits too long, or if the setting is turned
-- off or they're ignored meanwhile.
local function SayLineFor(press)
    if ns.db.buffBack.sayLine ~= true then return end
    ns.Announcer.Schedule("buffBack", press.name, {
        channel = "SAY",
        delay = 0,
        cooldown = 0, -- a favour is only returned once, so each return says one line
        maxAge = ns.BuffTracker.SAY_MAX_AGE,
        vars = function()
            local vars = Util.NameVars(press.name)
            vars.buff = press.spell
            return vars
        end,
        isValid = function()
            if ns.db.buffBack.sayLine ~= true then return false, "the line is switched off" end
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
    if not press then return end
    ForgetPress(press)
    local who = Util.DisplayName(press.name)
    local reachedThem = press.castTargetName and BuffButton.IsIntendedPlayer(press.castTargetName, press.name)
    if reachedThem == false then
        local actual = Util.StripChat(press.castTargetName)
        ShowResult(string.format("%s went to %s, not %s.", press.spell, actual, who), true)
    elseif reachedThem == nil then
        ShowResult("Cast " .. press.spell .. ", but the game didn't say it reached " .. who .. ".")
    elseif press.revoke then
        ns.GroupBuffs.NoteRevoked(press.name)
        ShowResult("Revoked Salvation from " .. who .. ".")
    elseif press.group then
        -- A group buff: no favour, no line, no thanks.
        ns.GroupBuffs.NoteGiven(press.name, press.buff)
        ShowResult("Gave " .. press.spell .. " to " .. who .. ".")
    elseif ns.Offers.MarkReturned(press.name, press.spell) then
        ShowResult("Returned " .. press.spell .. " to " .. who .. ".")
        SayLineFor(press)
    else
        ShowResult("Cast " .. press.spell .. " on " .. who .. " (no favour was waiting).")
    end
    BuffButton.Refresh()
end

-- The last error text no press took, in case its failure comes just after
-- it (the order of the two isn't known for Forever): { text, at }.
local unclaimedError

local function ReportRefusal(press, text)
    ForgetPress(press)
    if press.group and ns.GroupBuffs.IsTargetRefusal(text) then ns.GroupBuffs.NoteRefused(press.name) end
    ShowResult((press.revoke and "Couldn't revoke Salvation from " or "Couldn't buff ")
        .. Util.DisplayName(press.name) .. ": " .. Util.StripChat(text), true)
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

-- The cast failed with nothing to say (cancelled, say): no error text
-- follows, so the press is simply answered.
function BuffButton.OnSpellcastFailedQuiet(unit, castGUID, spellId)
    local press = PressForCast(unit, castGUID, spellId)
    if not press then return end
    ForgetPress(press)
    lastResultText = "the cast of " .. press.spell .. " stopped"
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
    ns.db.buffBack.unlocked = unlock and true or false
    if unlock then
        button:RegisterForDrag("LeftButton")
    else
        button:RegisterForDrag()
        local point, _, _, x, y = button:GetPoint()
        if point then
            ns.db.buffBack.position = ns.Config.CleanPosition({ point = point, x = x, y = y },
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
    GameTooltip:AddLine(ns.TITLE .. ": buff back")
    -- The button cuts a long line short (a reason it's empty, why to Revoke):
    -- here it is in full.
    local subtitle = button.subtitle:GetText()
    if subtitle and subtitle ~= "" then GameTooltip:AddLine(subtitle, 1, 0.82, 0, true) end
    if armedOffer then
        GameTooltip:AddLine("Casts " .. armedOffer.spell .. " on " .. Util.DisplayName(armedOffer.name)
            .. ", then gives you your target back.", 1, 1, 1, true)
    end
    GameTooltip:AddLine("Click or press its key to cast. Right-click to let them go.", 0.8, 0.8, 0.8, true)
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
        UI_ERROR_MESSAGE = BuffButton.OnUIError,
        PLAYER_TARGET_CHANGED = BuffButton.Refresh,
        -- Someone owed may come into view (or go): their PvP flag can be read only then.
        NAME_PLATE_UNIT_ADDED = RefreshSoon,
        -- In buff mode, who's in your group decides whom to buff.
        GROUP_ROSTER_UPDATE = RefreshSoon,
        NAME_PLATE_UNIT_REMOVED = RefreshSoon,
        PLAYER_REGEN_DISABLED = BuffButton.OnCombatStart,
        PLAYER_REGEN_ENABLED = BuffButton.Refresh,
        SPELLS_CHANGED = OnSpellsChanged,
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
    button:SetSize(220, 44)
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
        if ns.db.buffBack.unlocked and not InCombatLockdown() then self:StartMoving() end
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
    background:SetColorTexture(0, 0, 0, 0.6)
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(36, 36)
    button.icon:SetPoint("LEFT", 4, 0)
    -- The name and the favour span the room right of the icon, one line each:
    -- the game cuts text that doesn't fit with "...", whatever the font.
    button.title = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    button.title:SetPoint("TOPLEFT", button.icon, "TOPRIGHT", 6, -2)
    button.title:SetPoint("TOPRIGHT", button, "TOPRIGHT", -6, -6)
    button.title:SetJustifyH("LEFT")
    button.title:SetWordWrap(false)
    button.subtitle = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.subtitle:SetPoint("BOTTOMLEFT", button.icon, "BOTTOMRIGHT", 6, 2)
    button.subtitle:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -6, 6)
    button.subtitle:SetJustifyH("LEFT")
    button.subtitle:SetWordWrap(false)
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
function BuffButton.ArmedOffer() return armedOffer end
BuffButton.SECURE_ATTRIBUTE = SECURE_ATTRIBUTE

function BuffButton.StatusLines()
    local out = {}
    out[#out + 1] = string.format("buff back: %s, %d favour(s) owed", ns.db.buffBack.enabled and "on" or "off",
        ns.Offers.Count())
    local names = {}
    for _, buff in ipairs(ns.BuffData.Mine()) do names[#names + 1] = ns.BuffData.SpellName(buff) or buff.key end
    out[#out + 1] = "your buffs: " .. (#names > 0 and table.concat(names, ", ") or "none known")
    if armedOffer then
        out[#out + 1] = "armed: " .. armedOffer.spell .. " for " .. Util.DisplayName(armedOffer.name)
        -- Lines joined with " ; " ("|" is the game's escape character in chat).
        out[#out + 1] = "macro: " .. armedOffer.macroText:gsub("\n", " ; ")
    else
        out[#out + 1] = "not armed: " .. tostring(notArmedReason or "nothing to offer")
    end
    out[#out + 1] = ns.BuffMode.StatusLine()
    if not button then out[#out + 1] = "the button is made when this fight ends" end
    if InCombatLockdown() then out[#out + 1] = "in combat: the button stays empty until the fight ends" end
    out[#out + 1] = "last result: " .. lastResultText
    return out
end
