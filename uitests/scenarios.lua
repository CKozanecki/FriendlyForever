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
local function Edges(region)
    local ok, left, right = pcall(function() return region:GetLeft(), region:GetRight() end)
    if ok and type(left) == "number" and type(right) == "number" then return left, right end
end

-- Whether any of the region's anchor points pins its right side.
local function AnchoredOnRight(region)
    for i = 1, region:GetNumPoints() do
        local point = region:GetPoint(i)
        if type(point) == "string" and point:find("RIGHT", 1, true) then return true end
    end
    return false
end

local function TextInside(frame, region, label)
    local fl, fr = Edges(frame)
    local tl, tr = Edges(region)
    if not (fl and tl) then
        report("LAYOUT " .. label .. ": edges can't be read here")
        return
    end
    -- A text line pinned on its left only grows to its text, so its text
    -- ends where its width says. One pinned on its right too is cut off at
    -- that edge (GetStringWidth still reports the uncut width).
    local width = region.GetStringWidth and region:GetStringWidth() or (tr - tl)
    local textRight, cut = tr, ""
    if not AnchoredOnRight(region) then
        textRight = math.max(tr, tl + width)
    elseif width > tr - tl + 1 then
        cut = (", cut short (its text is %.0f wide)"):format(width)
    end
    local line = ("LAYOUT %s: text %.0f..%.0f, frame %.0f..%.0f%s"):format(label, tl, textRight, fl, fr, cut)
    report(line)
    check(tl >= fl - 1 and textRight <= fr + 1, line .. ": spills out of its frame")
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
        TextInside(button, button.title, "button title")
        TextInside(button, button.subtitle, "button hint")
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
            TextInside(button, button.subtitle, "long favour hint")
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

-- Opens the options at the General page (#35). It doesn't scroll, so each
-- section added to it pushes the rest down towards its bottom.
local function OpenGeneralPage()
    SlashCmdList.FRIENDLYFOREVER("")
    local page = _G.FriendlyForeverOptionsPanel.generalPage
    assertNotNil(page)
    if Settings and Settings.OpenToCategory and page.category then
        Settings.OpenToCategory(page.category:GetID())
    end
    return page
end

-- Layout: a region doesn't reach below its frame's bottom edge.
local function AboveBottom(frame, region, label)
    local ok, frameBottom, bottom = pcall(function() return frame:GetBottom(), region:GetBottom() end)
    if not (ok and type(frameBottom) == "number" and type(bottom) == "number") then
        report("LAYOUT " .. label .. ": edges can't be read here")
        return
    end
    local line = ("LAYOUT %s: bottom %.0f, frame bottom %.0f"):format(label, bottom, frameBottom)
    report(line)
    check(bottom >= frameBottom - 1, line .. ": below the bottom of its frame")
end

test("the General page's chat limit row stays inside it (#35)", function()
    local page = OpenGeneralPage()
    local w = page.widgets
    TextInside(page, w.linesPerMinute.label, "chat limit label")
    TextInside(page, w.linesPerMinute.plus, "chat limit + button")
    AboveBottom(page, w.capHelp, "chat limit help")
end)

test("the General page's last line is still on the page (#35)", function()
    local page = OpenGeneralPage()
    AboveBottom(page, page.widgets.reportHelp, "bug report help")
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
