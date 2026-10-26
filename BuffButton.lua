-- The buff-back button: shows a favour you owe (Offers.lua) and, when you
-- press it (click, or its key in Key Bindings > AddOns), casts your buff on
-- them. The game only lets an addon cast through a secure button the player
-- presses, so this module decides who and what, writes it onto the button as
-- a macro, and the game does the casting.
--
-- The macro targets them by name, casts, and gives you your own target back.
-- Its shape is built in one function (BuildCastMacro) so it can be changed
-- in one place if WoW Forever turns out to want something else.
-- /friendly buffback shows exactly what the button holds, for testing in game.
--
-- Secure buttons can't be changed in combat: whatever the button holds when
-- a fight starts stays on it until the fight ends.
local _, ns = ...
local Util = ns.Util

local BuffButton = {}
ns.BuffButton = BuffButton

BuffButton.FRAME_NAME = "FriendlyForeverBuffButton"
BuffButton.ANSWER_WINDOW_SECONDS = 3   -- after a press, a cast or a refusal this soon is its answer
BuffButton.RESULT_SHOWN_SECONDS = 4    -- how long "Returned ..." stays under the button
BuffButton.RECHECK_SECONDS = 5         -- how often favours are re-checked while any are owed
BuffButton.MACRO_MAX_LENGTH = 255      -- the game's limit for macro text
BuffButton.PLACEHOLDER_ICON = "Interface\\Icons\\Spell_Nature_Regeneration"

-- Attribute names of Blizzard's SecureActionButtonTemplate
-- (https://warcraft.wiki.gg/wiki/SecureActionButtonTemplate). The "1" suffix
-- means the left mouse button, which is also what a key binding to
-- "CLICK <button>:LeftButton" presses. Right-click has no secure action, so it
-- does nothing secure; we use it (in PostClick) to let a favour go.
local SECURE_ATTRIBUTE = {
    leftButtonActionType = "type1",
    leftButtonMacroText = "macrotext1",
}
local MACRO_ACTION_TYPE = "macro"

-- The text shown for the binding in Key Bindings > AddOns (Bindings.xml).
_G["BINDING_NAME_CLICK " .. BuffButton.FRAME_NAME .. ":LeftButton"] = "Friendly Forever: buff back"

local button, eventFrame
local armedOffer          -- what the button holds: { name, spell, buff, spokenLine, macroText }
local pressAwaitingAnswer -- a press not yet answered by the game: { name, spell, buff, pressedAt, castTargetName }
local chosenLine          -- the line picked for one favour and spell: { key, text }
local shownResult         -- the last result under the button: { text, shownAt }
local lastResultText = "nothing pressed yet"
local notArmedReason      -- why the button is empty, for /friendly buffback
local recheckScheduled = false

------------------------------------------------------------------------
-- The macro
------------------------------------------------------------------------

-- A piece of macro text is safe when it can't end its line or start another
-- command: no line breaks or control characters, no "|" escape codes, and not
-- starting with "/". Names, spell names and spoken lines are all checked.
function BuffButton.IsSafeMacroPart(text)
    return type(text) == "string" and text ~= "" and not text:find("[%c|]") and text:sub(1, 1) ~= "/"
end

-- The macro that casts spellName on the player playerFullName, says
-- spokenLine (or nothing), and restores your target afterwards. Returns nil
-- when any part isn't safe to put in a macro.
--   alreadyTargeted: they are your target now, so there's nothing to restore.
--   hadTarget: you have a target now; without one, the target is cleared after.
function BuffButton.BuildCastMacro(playerFullName, spellName, spokenLine, alreadyTargeted, hadTarget)
    local targetName = Util.DisplayName(playerFullName)
    if not BuffButton.IsSafeMacroPart(targetName) or not BuffButton.IsSafeMacroPart(spellName) then return nil end
    if spokenLine ~= nil and not BuffButton.IsSafeMacroPart(spokenLine) then return nil end
    local lines = {}
    if not alreadyTargeted then lines[#lines + 1] = "/target " .. targetName end
    lines[#lines + 1] = "/cast " .. spellName
    if spokenLine then lines[#lines + 1] = "/s " .. spokenLine end
    if not alreadyTargeted then lines[#lines + 1] = hadTarget and "/targetlasttarget" or "/cleartarget" end
    local macroText = table.concat(lines, "\n")
    if #macroText > BuffButton.MACRO_MAX_LENGTH then return nil end
    return macroText
end

-- The line to say, no longer than maxLength, or nil. Picked once per favour
-- and spell, so re-arming (your target changing) doesn't use up the rotation.
local function SpokenLineFor(offer, maxLength)
    local settings = ns.db.buffBack
    if not settings.enabled or maxLength <= 0 then return nil end
    local key = offer.name .. "\1" .. offer.spell
    if chosenLine and chosenLine.key == key then
        if chosenLine.text and #chosenLine.text <= maxLength then return chosenLine.text end
        return nil
    end
    local text
    for _ = 1, 5 do -- a few tries for a line short enough
        local template = ns.Messages.Pick("buffBack", settings.messages)
        if not template then break end
        local vars = Util.NameVars(offer.name)
        vars.buff = offer.spell
        local rendered = Util.Render(template, ns.Flavour.Vars(vars))
        if rendered and #rendered <= maxLength and BuffButton.IsSafeMacroPart(rendered) then
            text = rendered
            break
        end
    end
    chosenLine = { key = key, text = text }
    return text
end

------------------------------------------------------------------------
-- Arming the button
------------------------------------------------------------------------

local function SetSecureMacro(macroText)
    button:SetAttribute(SECURE_ATTRIBUTE.leftButtonActionType, macroText and MACRO_ACTION_TYPE or nil)
    button:SetAttribute(SECURE_ATTRIBUTE.leftButtonMacroText, macroText)
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

-- Write the newest favour you can return onto the button, or empty it.
-- Out of combat only: the game locks secure buttons in a fight.
local function ArmButton()
    if not button or InCombatLockdown() then return end
    local unlocked = ns.db.buffBack.unlocked
    local offer, reason
    if unlocked then
        reason = "the button is unlocked for moving"
    else
        offer, reason = ns.Offers.Current()
    end
    local showingResult = ShowRecentResult()

    local macroText
    if offer then
        local alreadyTargeted = Util.UnitFullName("target") == offer.name
        local hadTarget = Util.Readable(UnitExists("target")) == true
        local withoutLine = BuffButton.BuildCastMacro(offer.name, offer.spell, nil, alreadyTargeted, hadTarget)
        if withoutLine then
            local room = BuffButton.MACRO_MAX_LENGTH - #withoutLine - #"\n/s "
            local spokenLine = SpokenLineFor(offer, room)
            macroText = BuffButton.BuildCastMacro(offer.name, offer.spell, spokenLine, alreadyTargeted, hadTarget)
            armedOffer = { name = offer.name, spell = offer.spell, buff = offer.buff, spokenLine = spokenLine,
                macroText = macroText }
        else
            reason = "the name or spell can't be put in a macro safely"
        end
    end

    if not macroText then
        armedOffer = nil
        SetSecureMacro(nil)
        notArmedReason = reason
        if unlocked then
            SetLabels("Buff back", "Drag to move, then /friendly move to lock")
            button.icon:SetTexture(BuffButton.PLACEHOLDER_ICON)
        end
        button:SetShown(unlocked or showingResult)
        return
    end

    SetSecureMacro(macroText)
    notArmedReason = nil
    button.icon:SetTexture(ns.BuffData.Icon(offer.buff) or BuffButton.PLACEHOLDER_ICON)
    SetLabels(Util.DisplayName(offer.name), "buffed you - give " .. offer.spell)
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

-- Re-arm now (out of combat), and keep re-checking while favours are owed
-- or a result is showing: favours expire, targets and ranges change.
function BuffButton.Refresh()
    if not button then return end
    ArmButton()
    if ns.Offers.Count() > 0 or shownResult then ScheduleRecheck() end
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

-- Before the secure action runs: re-arm at the last moment (a nameplate or
-- your target may have changed) and remember the press to match its answer.
local function OnPreClick(_, mouseButton, isDown)
    if isDown == false or mouseButton ~= "LeftButton" then return end
    ArmButton()
    if armedOffer then
        pressAwaitingAnswer = { name = armedOffer.name, spell = armedOffer.spell, buff = armedOffer.buff,
            pressedAt = GetTime() }
        ns.Diag.Log("buffBack", "pressed: %s", armedOffer.macroText)
    end
end

-- Right-click lets the shown favour go.
local function OnPostClick(_, mouseButton, isDown)
    if isDown == false or mouseButton ~= "RightButton" or not armedOffer then return end
    local name = armedOffer.name
    ns.Offers.Skip(name)
    ShowResult("Let " .. Util.DisplayName(name) .. " go.")
    BuffButton.Refresh()
end

-- The press still waiting for its answer, if it was recent enough.
local function RecentPress()
    if pressAwaitingAnswer and GetTime() - pressAwaitingAnswer.pressedAt <= BuffButton.ANSWER_WINDOW_SECONDS then
        return pressAwaitingAnswer
    end
    pressAwaitingAnswer = nil
end

-- Whether one of our casts (a spell ID) answers this press.
local function AnswersPress(press, unit, spellId)
    return press ~= nil and unit == "player" and not Util.IsSecret(spellId)
        and ns.BuffData.ForCast(spellId) == press.buff
end

-- Whether the name the game says a cast went to is the intended player.
-- The game may report "First", "First Surname" or "First-Surname".
-- nil when the name can't be read as a player's.
function BuffButton.IsIntendedPlayer(reportedName, intendedFullName)
    local reported = Util.FullName(reportedName)
    if not reported then return nil end
    if reported == intendedFullName then return true end
    return not reported:find("-", 1, true) and reported == Util.FirstName(intendedFullName)
end

-- UNIT_SPELLCAST_SENT can name who the cast is going to. If it does, it
-- tells us whether /target found the right person.
function BuffButton.OnSpellcastSent(unit, castTargetName, _, spellId)
    local press = RecentPress()
    if not AnswersPress(press, unit, spellId) then return end
    if not Util.IsSecret(castTargetName) and type(castTargetName) == "string" and castTargetName ~= "" then
        press.castTargetName = castTargetName
    end
end

function BuffButton.OnSpellcastSucceeded(unit, _, spellId)
    local press = RecentPress()
    if not AnswersPress(press, unit, spellId) then return end
    pressAwaitingAnswer = nil
    if press.castTargetName and BuffButton.IsIntendedPlayer(press.castTargetName, press.name) == false then
        ShowResult(string.format("%s went to %s, not %s.", press.spell, Util.StripChat(press.castTargetName),
            Util.DisplayName(press.name)), true)
    else
        ns.Offers.Returned(press.name, press.spell)
        ShowResult("Returned " .. press.spell .. " to " .. Util.DisplayName(press.name) .. ".")
    end
    BuffButton.Refresh()
end

function BuffButton.OnSpellcastFailed(unit, _, spellId)
    local press = RecentPress()
    if not AnswersPress(press, unit, spellId) then return end
    -- The game's error text (UI_ERROR_MESSAGE) usually follows with the reason.
    lastResultText = "the cast of " .. press.spell .. " failed"
end

-- The game's red error text ("Out of range.") just after a press answers it.
function BuffButton.OnUIError(_, message)
    local press = RecentPress()
    if not press or Util.IsSecret(message) or type(message) ~= "string" then return end
    pressAwaitingAnswer = nil
    ShowResult("Couldn't buff " .. Util.DisplayName(press.name) .. ": " .. Util.StripChat(message), true)
    BuffButton.Refresh()
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
            ns.db.buffBack.position = ns.Config.CleanPosition({ point = point, x = x, y = y })
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
    if armedOffer then
        GameTooltip:AddLine("Casts " .. armedOffer.spell .. " on " .. Util.DisplayName(armedOffer.name)
            .. ", then gives you your target back.", 1, 1, 1, true)
        if armedOffer.spokenLine then GameTooltip:AddLine("Says: " .. armedOffer.spokenLine, 0.8, 0.8, 0.8, true) end
    end
    GameTooltip:AddLine("Click or press its key to cast. Right-click to let them go.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end

local function CreateEventFrame()
    eventFrame = CreateFrame("Frame")
    local handlers = {
        UNIT_SPELLCAST_SENT = BuffButton.OnSpellcastSent,
        UNIT_SPELLCAST_SUCCEEDED = BuffButton.OnSpellcastSucceeded,
        UNIT_SPELLCAST_FAILED = BuffButton.OnSpellcastFailed,
        UNIT_SPELLCAST_FAILED_QUIET = BuffButton.OnSpellcastFailed,
        UI_ERROR_MESSAGE = BuffButton.OnUIError,
        PLAYER_TARGET_CHANGED = BuffButton.Refresh,
        PLAYER_REGEN_ENABLED = BuffButton.Refresh,
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

function BuffButton.Create()
    if button then return end
    button = CreateFrame("Button", BuffButton.FRAME_NAME, UIParent, "SecureActionButtonTemplate")
    button:SetSize(220, 44)
    local position = ns.db.buffBack.position
    button:SetPoint(position.point, UIParent, position.point, position.x, position.y)
    button:SetFrameStrata("MEDIUM")
    button:SetMovable(true)
    button:SetClampedToScreen(true)
    -- Like the game's own action buttons: the action runs as the key or mouse
    -- button goes down.
    button:RegisterForClicks("AnyDown")
    button:SetAttribute("pressAndHoldAction", true)
    button:SetScript("PreClick", ns.Diag.Wrap(OnPreClick))
    button:SetScript("PostClick", ns.Diag.Wrap(OnPostClick))
    button:SetScript("OnDragStart", function(self)
        if ns.db.buffBack.unlocked and not InCombatLockdown() then self:StartMoving() end
    end)
    button:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0, 0, 0, 0.6)
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(36, 36)
    button.icon:SetPoint("LEFT", 4, 0)
    button.title = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    button.title:SetPoint("TOPLEFT", button.icon, "TOPRIGHT", 6, -2)
    button.title:SetJustifyH("LEFT")
    button.subtitle = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.subtitle:SetPoint("BOTTOMLEFT", button.icon, "BOTTOMRIGHT", 6, 2)
    button.subtitle:SetJustifyH("LEFT")
    button.result = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.result:SetPoint("TOP", button, "BOTTOM", 0, -2)
    if ns.db.buffBack.unlocked then button:RegisterForDrag("LeftButton") end
    button:Hide()

    CreateEventFrame()
    BuffButton.Refresh()
end

------------------------------------------------------------------------
-- For /friendly buffback and the tests
------------------------------------------------------------------------

function BuffButton.Frame() return button end
function BuffButton.ArmedOffer() return armedOffer end

function BuffButton.StatusLines()
    local out = {}
    out[#out + 1] = string.format("buff back: %s, %d favour(s) owed", ns.db.buffBack.offer and "on" or "off",
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
    if InCombatLockdown() then out[#out + 1] = "in combat: the button keeps what it had until the fight ends" end
    out[#out + 1] = "last result: " .. lastResultText
    return out
end
