-- UI scenarios for the headless UI simulator (issue #49). They run inside
-- wow-ui-sim (https://github.com/Osso/wow-ui-sim), which loads the packaged
-- addon on top of Blizzard's own UI code, unlike spec/, whose simulated client
-- is our own. The workflow copies this folder in as the addon's tests/.
--
-- test(), the assert* functions and A_Print come from the simulator; A_Print
-- exists only there, never in the game.

-- Report lines go to the simulator's log through A_Print: once Blizzard's UI
-- loads, print writes to the chat frame instead.
local report = type(A_Print) == "function" and A_Print or print

-- Fails the test with message, unlike assertTrue, which drops its message.
local function check(ok, message)
    if not ok then error(message, 3) end
end

-- Messages the addon printed to chat while fn ran.
local function CapturePrints(fn)
    local printed = {}
    local chat = DEFAULT_CHAT_FRAME
    local original = chat.AddMessage
    chat.AddMessage = function(_, text) printed[#printed + 1] = tostring(text) end
    local ok, err = pcall(fn)
    chat.AddMessage = original
    if not ok then error(err, 2) end
    return printed
end

local function AnyContains(lines, fragment)
    for _, line in ipairs(lines) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

test("loads and creates its saved settings", function()
    assertType("table", FriendlyForeverDB)
    assertTrue(FriendlyForeverDB.enabled)
    assertType("table", FriendlyForeverDB.buff)
    assertType("table", FriendlyForeverDB.partyJoin)
end)

test("registers its slash commands", function()
    assertEquals("/friendly", SLASH_FRIENDLYFOREVER1)
    assertType("function", SlashCmdList.FRIENDLYFOREVER)
end)

test("/friendly status answers in chat", function()
    local printed = CapturePrints(function() SlashCmdList.FRIENDLYFOREVER("status") end)
    assertTrue(#printed > 0)
    assertTrue(AnyContains(printed, "Friendly Forever"))
end)

test("/friendly selftest runs against the real UI", function()
    local printed = CapturePrints(function() SlashCmdList.FRIENDLYFOREVER("selftest") end)
    assertTrue(#printed > 0)
end)

test("the options panel is made and opens without errors", function()
    SlashCmdList.FRIENDLYFOREVER("")
    local panel = _G.FriendlyForeverOptionsPanel
    assertNotNil(panel)
    assertTrue(panel:GetWidth() > 0)
end)

test("an unknown command is answered, not an error", function()
    local printed = CapturePrints(function() SlashCmdList.FRIENDLYFOREVER("no-such-command") end)
    assertTrue(AnyContains(printed, "unknown command"))
end)

-- Layout: every piece of text on the buff-back button stays inside it. The
-- simulator draws with stand-in fonts, so widths are close to the game's,
-- not exact: the button must keep its text inside whatever the font.

-- Two of a region's edges, as region:first() and region:second(), but only
-- if both are numbers: a missing method, an error or anything else gives
-- nothing.
local function Edges(region, first, second)
    local ok, a, b = pcall(function() return region[first](region), region[second](region) end)
    if ok and type(a) == "number" and type(b) == "number" then return a, b end
end

-- A text line's measure, as region:method(), if it is a number.
local function Measure(region, method)
    local ok, value = pcall(function() return region[method](region) end)
    if ok and type(value) == "number" then return value end
end

-- Whether any of the region's anchor points pins the given side ("RIGHT",
-- "TOP", "BOTTOM"), as TOPRIGHT pins both its top and its right.
local function AnchoredOn(region, side)
    for i = 1, region:GetNumPoints() do
        local point = region:GetPoint(i)
        if type(point) == "string" and point:find(side, 1, true) then return true end
    end
    return false
end

-- How far a text line's text reaches across: left, right, and a note if
-- it is cut short. A line pinned on its left only grows to its text, so its
-- text ends where its width says. One pinned on its right too is cut off at
-- that edge (GetStringWidth still reports the uncut width).
local function DrawnAcross(region, left, right)
    local width = Measure(region, "GetStringWidth")
    if not width then return left, right, "" end
    if not AnchoredOn(region, "RIGHT") then return left, math.max(right, left + width), "" end
    if width > right - left + 1 then return left, right, (", cut short (its text is %.0f wide)"):format(width) end
    return left, right, ""
end

-- How far a text line's text reaches up and down: top, bottom. A line with
-- no height set is as tall as its text, wrapped lines and all, so it grows
-- away from the side it is pinned on: down from its top, up from its
-- bottom, or both ways from its middle. One pinned on its top and bottom
-- keeps between them, and the client cuts what doesn't fit.
local function DrawnUpDown(region, top, bottom)
    local height = Measure(region, "GetStringHeight")
    if not height then return top, bottom end
    local onTop, onBottom = AnchoredOn(region, "TOP"), AnchoredOn(region, "BOTTOM")
    if onTop and onBottom then return top, bottom end
    if onTop then return top, math.min(bottom, top - height) end
    if onBottom then return math.max(top, bottom + height), bottom end
    local middle = (top + bottom) / 2
    return math.max(top, middle + height / 2), math.min(bottom, middle - height / 2)
end

-- Checks that a text line's drawn text stays inside frame, across and up
-- and down, and on at most maxLines lines when that is given. Prints a
-- LAYOUT line, which names any edges or count the client can't give, and
-- returns it.
local function TextInside(frame, region, label, maxLines)
    local fl, fr = Edges(frame, "GetLeft", "GetRight")
    local tl, tr = Edges(region, "GetLeft", "GetRight")
    if not (fl and tl) then
        local line = "LAYOUT " .. label .. ": edges can't be read here"
        report(line)
        return line
    end
    local textLeft, textRight, cut = DrawnAcross(region, tl, tr)
    local inside = textLeft >= fl - 1 and textRight <= fr + 1
    local line = ("LAYOUT %s: text %.0f..%.0f, frame %.0f..%.0f%s"):format(label, textLeft, textRight, fl, fr, cut)

    local ft, fb = Edges(frame, "GetTop", "GetBottom")
    local tt, tb = Edges(region, "GetTop", "GetBottom")
    if ft and tt then
        local textTop, textBottom = DrawnUpDown(region, tt, tb)
        inside = inside and textTop <= ft + 1 and textBottom >= fb - 1
        line = line .. (" x %.0f..%.0f, frame %.0f..%.0f"):format(textBottom, textTop, fb, ft)
    else
        line = line .. ", top and bottom can't be read here"
    end

    local lines
    if maxLines then
        local count = Measure(region, "GetNumLines")
        if count then
            lines = count
            line = line .. (", %d line%s"):format(count, count == 1 and "" or "s")
        else
            line = line .. ", lines can't be counted here"
        end
    end

    report(line)
    check(inside, line .. ": spills out of its frame")
    check(not lines or lines <= maxLines, line .. ": wraps onto more lines than " .. tostring(maxLines))
    return line
end

-- Layout: a frame lies wholly on the screen. Compared in screen pixels, so
-- a frame's own scale can't hide it.
local function OnScreen(frame, label)
    local ok, left, right, top, bottom = pcall(function()
        return frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
    end)
    if not (ok and type(left) == "number" and type(right) == "number"
        and type(top) == "number" and type(bottom) == "number") then
        report("LAYOUT " .. label .. ": edges can't be read here")
        return
    end
    local scale, screen = frame:GetEffectiveScale(), UIParent:GetEffectiveScale()
    local width, height = UIParent:GetWidth() * screen, UIParent:GetHeight() * screen
    left, right, top, bottom = left * scale, right * scale, top * scale, bottom * scale
    local line = ("LAYOUT %s: %.0f..%.0f x %.0f..%.0f, screen %.0f x %.0f"):format(
        label, left, right, bottom, top, width, height)
    report(line)
    check(left >= -1 and bottom >= -1 and right <= width + 1 and top <= height + 1, line .. ": off the screen")
end

-- Runs fn with the buff-back button unlocked (it shows, with its longest
-- hint), then locks it again if it was locked, even when fn fails, so one
-- failed check can't leave the next test the wrong state.
local function WithButtonUnlocked(fn)
    local wasUnlocked = FriendlyForeverDB.buffBack.unlocked
    if not wasUnlocked then SlashCmdList.FRIENDLYFOREVER("move") end
    local button = _G.FriendlyForeverBuffButton
    local ok, err = pcall(fn, button)
    if FriendlyForeverDB.buffBack.unlocked ~= wasUnlocked then SlashCmdList.FRIENDLYFOREVER("move") end
    if not ok then error(err, 0) end
end

test("the buff-back button's text stays inside it (unlocked, the longest hint)", function()
    WithButtonUnlocked(function(button)
        assertNotNil(button)
        assertTrue(FriendlyForeverDB.buffBack.unlocked)
        TextInside(button, button.title, "button title", 1)
        TextInside(button, button.subtitle, "button hint", 1)
    end)
end)

-- From #64: the longest favour text a button can show. Set directly, since
-- these scenarios can't yet make a favour (#83), and put back afterwards.
test("the buff-back button's text stays inside it (a long favour)", function()
    WithButtonUnlocked(function(button)
        assertNotNil(button)
        local hint = button.subtitle:GetText()
        local ok, err = pcall(function()
            button.subtitle:SetText("missing your Power Word: Fortitude")
            TextInside(button, button.subtitle, "long favour hint", 1)
        end)
        button.subtitle:SetText(hint)
        if not ok then error(err, 0) end
    end)
end)

test("the buff-back button is on the screen where it starts (unlocked)", function()
    WithButtonUnlocked(function(button)
        assertNotNil(button)
        assertTrue(FriendlyForeverDB.buffBack.unlocked)
        OnScreen(button, "buff-back button")
    end)
end)

test("the options panel is on the screen once open", function()
    SlashCmdList.FRIENDLYFOREVER("")
    local panel = _G.FriendlyForeverOptionsPanel
    assertNotNil(panel)
    OnScreen(panel, "options panel")
end)

-- Facts about the simulated client, printed in the report: they are
-- compared with the ASSUMPTIONS block in spec/support/wow.lua.
test("reports the client facts our own simulated client assumes", function()
    local facts = {
        ("issecretvalue exists: %s"):format(tostring(type(issecretvalue) == "function")),
        ("C_ChatInfo.SendChatMessage exists: %s"):format(tostring(C_ChatInfo and C_ChatInfo.SendChatMessage ~= nil)),
        ("C_ChatInfo.PerformEmote exists: %s"):format(tostring(C_ChatInfo and C_ChatInfo.PerformEmote ~= nil)),
        ("ActionButtonUseKeyDown: %s"):format(tostring(GetCVar and GetCVar("ActionButtonUseKeyDown"))),
        ("UnitName(player): %s"):format(tostring((UnitName("player")))),
        ("AddonCompartmentFrame exists: %s"):format(tostring(AddonCompartmentFrame ~= nil)),
        ("Settings.RegisterCanvasLayoutCategory exists: %s"):format(
            tostring(Settings and Settings.RegisterCanvasLayoutCategory ~= nil)),
        ("C_SpellBook.IsSpellInSpellBook exists: %s"):format(
            tostring(C_SpellBook and C_SpellBook.IsSpellInSpellBook ~= nil)),
        ("C_UnitAuras.GetAuraDataByIndex exists: %s"):format(
            tostring(C_UnitAuras and C_UnitAuras.GetAuraDataByIndex ~= nil)),
    }
    for _, line in ipairs(facts) do report("FACT " .. line) end
    assertTrue(true)
end)

-- Not covered here: anything that waits in game time (the login grace,
-- message delays). The simulator runs timers as fast as it can, at most 500
-- updates per async test, with no way to move the clock forward, so a
-- 10-second wait can't pass. Those flows stay in spec/, whose simulated
-- client controls time (wow.advance).

-- The layout checks, for spec/uitests_layout_spec.lua, which runs them
-- against regions whose edges it sets itself. The simulator ignores what a
-- test file returns.
return { TextInside = TextInside }
