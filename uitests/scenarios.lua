-- UI scenarios for the headless UI simulator (issue #49). They run inside
-- wow-ui-sim (https://github.com/Osso/wow-ui-sim), which loads the packaged
-- addon on top of Blizzard's own UI code, unlike spec/, whose simulated client
-- is our own. The workflow copies this folder in as the addon's tests/.
--
-- test(), the assert* functions and A_Print come from the simulator; A_Print
-- exists only there, never in the game.

-- Report lines go to the simulator's log through A_Print: once Blizzard's UI
-- loads, print writes to the chat frame instead.
local printLine = type(A_Print) == "function" and A_Print or print

-- Each scenario says it's starting, numbered in file order, before the
-- runner runs it. A pass the workflow stops at its time limit then names
-- the scenario it hung in, in the run's summary, and its number in the
-- run's annotations (#173).
local runTest, scenarioCount = test, 0
local function test(name, fn)
    scenarioCount = scenarioCount + 1
    printLine(("START %d %s"):format(scenarioCount, tostring(name)))
    return runTest(name, fn)
end

-- The screen the scenarios run at, as "1920x1080" (#148); nil where the
-- client can't say (the spec/ stand-in).
local function Resolution()
    local ok, width, height = pcall(GetPhysicalScreenSize)
    if ok and type(width) == "number" and type(height) == "number" then
        return ("%.0fx%.0f"):format(width, height)
    end
end

-- Each LAYOUT line names the resolution it was measured at, since the same
-- check runs at more than one (#148).
local function report(line)
    local size = Resolution()
    line = tostring(line)
    if size then line = line:gsub("^LAYOUT ", "LAYOUT [" .. size .. "] ", 1) end
    printLine(line)
end

-- Every action the client blocked or forbade an addon since pages.lua
-- loaded, as "<event> <addon> <action>", in order and counted (pages.lua's
-- watcher, #160): the last scenario reports them. Empty in spec/'s stand-in.
local blockedOrder, blockedActions = {}, {}
if type(FriendlyForeverUIPages) == "table" and type(FriendlyForeverUIPages.blocked) == "table" then
    blockedOrder, blockedActions = FriendlyForeverUIPages.blocked.order, FriendlyForeverUIPages.blocked.count
end
-- The lines that called the client's own blocked-action chat line, which
-- fires no event (pages.lua's hook, #160).
local blockedMessage = type(FriendlyForeverUIPages) == "table" and FriendlyForeverUIPages.blockedMessage or {}

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

-- What the simulator does by itself, as FACT lines in the report (#160). Each
-- is a quirk docs/ui-simulator.md records, or something the fixtures in
-- button_states.lua and pages.lua answer for it. When the simulator's pin
-- moves, these lines say which still hold, in the run itself. It comes
-- first, so it sees the simulator as it starts, and puts back what it
-- changes. Nothing here can fail the run: a probe that errors says so.
test("reports what the simulator does by itself (docs/ui-simulator.md)", function()
    local function fact(name, fn)
        local ok, value = pcall(fn)
        report(("FACT sim %s: %s"):format(name, ok and tostring(value) or ("error: " .. tostring(value))))
    end
    local States, Pages = FriendlyForeverUIStates, FriendlyForeverUIPages
    local spell = States.SPELL

    fact("client", function()
        local version, build, _, interface = GetBuildInfo()
        return ("%s (%s), interface %s"):format(tostring(version), tostring(build), tostring(interface))
    end)
    fact("screen", function()
        return ("%.0fx%.0f units, UIParent scale %.3f"):format(GetScreenWidth(), GetScreenHeight(), UIParent:GetScale())
    end)
    fact("starts in a group of", function() return GetNumGroupMembers() end)
    fact("the player", function()
        local _, class = UnitClass("player")
        return ("%s, level %s"):format(tostring(class), tostring(UnitLevel("player")))
    end)
    fact("the player's starting buffs", function()
        local ids = {}
        for i = 1, 255 do
            local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not aura then break end
            ids[#ids + 1] = tostring(aura.spellId)
        end
        table.sort(ids)
        return #ids .. " (" .. table.concat(ids, " ") .. ")"
    end)
    fact("the map the player is on", function() return C_Map.GetBestMapForUnit("player") end)

    -- Forever's buffs by name: every rank the Buffs tab can show.
    fact("names our buffs' ranks", function()
        local named, total, wrong = 0, 0, {}
        for _, buff in ipairs(Pages.BUFF_NAMES) do
            for _, id in ipairs(buff.ranks) do
                total = total + 1
                local name = C_Spell.GetSpellName(id)
                if name == buff.name then
                    named = named + 1
                elseif #wrong < 5 then
                    wrong[#wrong + 1] = id .. "=" .. tostring(name)
                end
            end
        end
        return ("%d of %d%s"):format(named, total, #wrong > 0 and (", not: " .. table.concat(wrong, " ")) or "")
    end)
    fact("names the fixture's buff", function() return C_Spell.GetSpellName(spell.id) end)
    fact("the fixture's buff, before it's learned", function()
        return ("known %s, in the spellbook %s, in range of the player %s"):format(tostring(IsSpellKnown(spell.id)),
            tostring(C_SpellBook.IsSpellInSpellBook(spell.id)), tostring(C_Spell.IsSpellInRange(spell.id, "player")))
    end)
    fact("the fixture's buff, once learned", function()
        A_Admin.LearnSpell(spell.id)
        local ok, text = pcall(function()
            local inRange = C_Spell.IsSpellInRange
            local line = "known %s, in the spellbook %s, in range of the player by ID %s and by name %s, of party1 %s"
            return line:format(
                tostring(IsSpellKnown(spell.id)), tostring(C_SpellBook.IsSpellInSpellBook(spell.id)),
                tostring(inRange(spell.id, "player")), tostring(inRange(spell.name, "player")),
                tostring(inRange(spell.id, "party1")))
        end)
        A_Admin.UnlearnSpell(spell.id)
        if not ok then error(text, 0) end
        return text
    end)

    -- A buff from someone else: does the aura name its caster?
    fact("a buff added with the caster party1 names its source as", function()
        A_Admin.AddBuff(spell.id, spell.name, "135987", 3600, 1, "party1")
        local source
        for i = 1, 255 do
            local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not aura then break end
            if aura.spellId == spell.id then source = tostring(aura.sourceUnit) end
        end
        A_Admin.RemoveBuff(spell.id)
        return source or "no such aura"
    end)

    -- A fight starting: is PLAYER_REGEN_DISABLED before the lockdown, as in the game?
    fact("PLAYER_REGEN_DISABLED arrives", function()
        local seen = {}
        local frame = CreateFrame("Frame")
        frame:RegisterEvent("PLAYER_REGEN_DISABLED")
        frame:SetScript("OnEvent", function()
            seen[#seen + 1] = InCombatLockdown() and "in the lockdown" or "before the lockdown"
        end)
        local ok, err = pcall(A_Admin.SetInCombat, true)
        pcall(A_Admin.SetInCombat, false)
        frame:UnregisterAllEvents()
        frame:SetScript("OnEvent", nil)
        if not ok then error(err, 0) end
        return #seen == 0 and "never" or table.concat(seen, ", then ")
    end)

    -- Layout: a chain of anchors longer than 16, a line pinned to two
    -- frames, and the height of small text. Scrolling isn't asked here: a
    -- scroll frame made and read in one frame has no range yet, so the
    -- answer would mean nothing. The walkthrough's row-in-view LAYOUT line
    -- says how a scrolled row reads.
    fact("a chain of 20 anchors follows a move of its first", function()
        local first = CreateFrame("Frame", nil, UIParent)
        first:SetSize(10, 10)
        first:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
        local last = first
        for _ = 2, 20 do
            local link = CreateFrame("Frame", nil, UIParent)
            link:SetSize(10, 10)
            link:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, 0)
            last = link
        end
        local before = last:GetTop()
        first:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -100)
        local moved = before - last:GetTop()
        first:Hide()
        return ("the last moved %.0f of 100"):format(moved)
    end)
    fact("a long line pinned to two frames 100 apart", function()
        local left = CreateFrame("Frame", nil, UIParent)
        left:SetSize(10, 10)
        left:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -100)
        local right = CreateFrame("Frame", nil, UIParent)
        right:SetSize(10, 10)
        right:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 200, -100)
        local line = left:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        line:SetPoint("LEFT", left, "RIGHT", 0, 0)
        line:SetPoint("RIGHT", right, "LEFT", 0, 0)
        line:SetText("one two three four five six seven eight nine ten eleven twelve")
        local lines, width = line:GetNumLines(), line:GetWidth()
        left:Hide()
        right:Hide()
        return ("is %s line(s), %.0f wide"):format(tostring(lines), width)
    end)
    fact("small text wrapped onto lines", function()
        local holder = CreateFrame("Frame", nil, UIParent)
        holder:SetSize(120, 10)
        holder:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 300, -100)
        local text = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        text:SetWidth(120)
        text:SetText("one two three four five six seven eight nine ten eleven twelve")
        local lines, height = text:GetNumLines(), text:GetStringHeight()
        holder:Hide()
        return ("%s lines, %.1f high, %.1f a line"):format(tostring(lines), height, height / math.max(lines or 1, 1))
    end)
    fact("C_VoiceChat.GetAvailableOutputDevices exists", function()
        return C_VoiceChat ~= nil and C_VoiceChat.GetAvailableOutputDevices ~= nil
    end)
    assertTrue(true)
end)

-- The simulator starts with no saved settings, a new install (#47): the
-- addon is off and its walkthrough open at its first step, and skipping it
-- turns the addon on. It is skipped even when a check fails, so the rest of
-- the run has the addon on, as a player has it after first run.
test("a new install is off, with its walkthrough open, until it's skipped (#47)", function()
    local walkthrough = _G.FriendlyForeverWalkthrough
    local ok, err = pcall(function()
        check(type(walkthrough) == "table" and walkthrough:IsShown(), "the walkthrough didn't open at login")
        check(FriendlyForeverDB.enabled == false, "the addon is on before first run is over")
        check((walkthrough.stepText:GetText() or ""):find("either turns it on", 1, true) ~= nil,
            "the first step doesn't say finishing or skipping turns the addon on")
    end)
    if type(walkthrough) == "table" and walkthrough:IsShown() then walkthrough.skip:Click() end
    if not ok then error(err, 0) end
    check(FriendlyForeverDB.enabled == true, "skipping didn't turn the addon on")
    check(not walkthrough:IsShown(), "skipping didn't close the walkthrough")
end)

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
    local before = #blockedOrder
    SlashCmdList.FRIENDLYFOREVER("")
    -- What the client blocked as /friendly opened the panel, if it says so
    -- at once (the last scenario lists the whole run's).
    report("FACT sim /friendly opening the options: " .. (#blockedOrder > before
        and table.concat(blockedOrder, "; ", before + 1) or "no action blocked at once"))
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

-- One of a region's measures (a size, a count), as region:method(), if it
-- is a number.
local function Measure(region, method)
    local ok, value = pcall(function() return region[method](region) end)
    if ok and type(value) == "number" then return value end
end

-- Whether any of the region's anchor points pins the given side ("RIGHT",
-- "TOP", "BOTTOM"), as TOPRIGHT pins both its top and its right. Anchors
-- the client can't give count as none.
local function AnchoredOn(region, side)
    local count = Measure(region, "GetNumPoints") or 0
    for i = 1, count do
        local ok, point = pcall(function() return region:GetPoint(i) end)
        if ok and type(point) == "string" and point:find(side, 1, true) then return true end
    end
    return false
end

-- How far a text line's text reaches across: left, right, and a note if
-- it is cut short. A line pinned on its left only grows to its text, so its
-- text ends where its width says, whatever width the line itself was given
-- (a left-justified label 220 wide reads as its text, so a name much
-- narrower or wider than the label shows, #177). One pinned on its right too stops at that
-- edge (GetStringWidth still reports the whole width): cut short there, or
-- wrapped onto more lines when wraps says so.
local function DrawnAcross(region, left, right, wraps)
    local width = Measure(region, "GetStringWidth")
    if not width then return left, right, "" end
    if not AnchoredOn(region, "RIGHT") then
        -- Pinned at one point, its width is the one it was given, and the
        -- text sits in it as its justification says. Left-justified text
        -- starts at the left edge; a justification the client can't give
        -- keeps the whole span.
        if Measure(region, "GetNumPoints") == 1 then
            local ok, justify = pcall(function() return region:GetJustifyH() end)
            if ok and justify == "LEFT" then return left, left + width, "" end
            if ok and justify == "RIGHT" then return right - width, right, "" end
            if ok and justify == "CENTER" then
                local middle = (left + right) / 2
                return middle - width / 2, middle + width / 2, ""
            end
        end
        return left, math.max(right, left + width), ""
    end
    if width > right - left + 1 and not wraps then
        return left, right, (", cut short (its text is %.0f wide)"):format(width)
    end
    return left, right, ""
end

-- How many lines the game wraps a text line's text onto, worked out from
-- its width rather than counted: with word wrap on, text wider than its
-- line wraps at that width, up to its max lines. This matters where the
-- client doesn't wrap a line itself: the simulator sizes a line whose two
-- sides are pinned to different frames (like the button's hint) to its
-- whole text, so it stays on one line there. Nothing when the client can't
-- say.
local function WrappedLines(region, left, right)
    -- pcall gives back the error message, never true, when it fails.
    local _, wraps = pcall(function() return region:CanWordWrap() end)
    local width = Measure(region, "GetStringWidth")
    if not (wraps == true and width) or right - left <= 0 then return end
    local lines = width > right - left + 1 and math.ceil(width / (right - left)) or 1
    local most = Measure(region, "GetMaxLines")
    if most and most > 0 then lines = math.min(lines, most) end
    return lines
end

-- How far a text line's text reaches up and down: top, bottom. A line with
-- no height set is as tall as its text, wrapped lines and all, so it grows
-- away from the side it is pinned on: down from its top, up from its
-- bottom, or both ways from its middle. One pinned on its top and bottom
-- keeps between them, and the client cuts what doesn't fit. growth is how
-- many times taller the game draws it than the client does, for a line the
-- client doesn't wrap (WrappedLines).
local function DrawnUpDown(region, top, bottom, growth)
    local height = Measure(region, "GetStringHeight")
    if not height and growth == 1 then return top, bottom end
    height = (height or (top - bottom)) * growth
    local onTop, onBottom = AnchoredOn(region, "TOP"), AnchoredOn(region, "BOTTOM")
    if onTop and onBottom then return top, bottom end
    if onTop then return top, math.min(bottom, top - height) end
    if onBottom then return math.max(top, bottom + height), bottom end
    local middle = (top + bottom) / 2
    return math.max(top, middle + height / 2), math.min(bottom, middle - height / 2)
end

-- Checks that a text line's drawn text stays inside frame, across and up
-- and down, and on at most maxLines lines when that is given. A line with
-- oneLine set, pinned on its left only (its width is the one it was given),
-- also fails if its text is wider than that width: the game wraps it onto a
-- second line, into the row below (#177). Prints a LAYOUT line, which names
-- any edges or count the client can't give, and returns it.
-- grows: frame is sized from the text's own height (the walkthrough's body,
-- Walkthrough.lua), so the game's wrapped text makes it taller too; up and
-- down, the text is then compared with it as the client lays both out, not
-- as the game would wrap the text alone (#362).
local function TextInside(frame, region, label, maxLines, oneLine, grows)
    local fl, fr = Edges(frame, "GetLeft", "GetRight")
    local tl, tr = Edges(region, "GetLeft", "GetRight")
    if not (fl and tl) then
        local line = "LAYOUT " .. label .. ": edges can't be read here"
        report(line)
        return line
    end
    -- The lines the client counts, and the lines the game would wrap onto if
    -- that is more than one and more than the client counts.
    local count = Measure(region, "GetNumLines")
    local wrapped = WrappedLines(region, tl, tr)
    if wrapped and wrapped <= 1 then wrapped = nil end
    local textLeft, textRight, cut = DrawnAcross(region, tl, tr, wrapped or (count and count > 1))
    if wrapped and wrapped <= (count or 0) then wrapped = nil end
    local inside = textLeft >= fl - 1 and textRight <= fr + 1
    local line = ("LAYOUT %s: text %.0f..%.0f, frame %.0f..%.0f%s"):format(label, textLeft, textRight, fl, fr, cut)
    -- Wider than the width the line was given, so the game wraps it.
    local setWidth, textWidth = tr - tl, Measure(region, "GetStringWidth")
    local tooWide = oneLine and textWidth and not AnchoredOn(region, "RIGHT") and textWidth > setWidth + 1
    if tooWide then line = line .. (", wider than its width of %.0f"):format(setWidth) end

    local ft, fb = Edges(frame, "GetTop", "GetBottom")
    local tt, tb = Edges(region, "GetTop", "GetBottom")
    if ft and tt then
        local growth = wrapped and wrapped / math.max(count or 1, 1) or 1
        if grows then growth = 1 end
        local textTop, textBottom = DrawnUpDown(region, tt, tb, growth)
        inside = inside and textTop <= ft + 1 and textBottom >= fb - 1
        line = line .. ("; up and down: text %.0f..%.0f, frame %.0f..%.0f"):format(textBottom, textTop, fb, ft)
    else
        line = line .. "; top and bottom can't be read here"
    end

    local lines
    if maxLines then
        if wrapped then
            lines = wrapped
            line = line .. (", %d lines once wrapped at its width"):format(wrapped)
        elseif count then
            lines = count
            line = line .. (", %d line%s"):format(count, count == 1 and "" or "s")
        else
            line = line .. ", lines can't be counted here"
        end
    end

    report(line)
    check(inside, line .. ": spills out of its frame")
    check(not tooWide, line .. ": wider than its width, so it wraps onto a second line")
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
        TextInside(button, button.subtitle, "button hint")
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

-- Opens the options at the General page (#35). Its lines are on
-- page.content, which scrolls (#52); each section added to it pushes the
-- rest down towards the content's bottom (Options.GENERAL_HEIGHT).
local function OpenGeneralPage()
    SlashCmdList.FRIENDLYFOREVER("")
    local page = _G.FriendlyForeverOptionsPanel.generalPage
    assertNotNil(page)
    if Settings and Settings.OpenToCategory and page.category then
        Settings.OpenToCategory(page.category:GetID())
    end
    return page
end

test("the General page's chat limit row stays inside it (#35)", function()
    local page = OpenGeneralPage()
    local w = page.widgets
    TextInside(page.content, w.linesPerMinute.label, "chat limit label", 1)
    TextInside(page.content, w.linesPerMinute.plus, "chat limit + button")
    TextInside(page.content, w.capHelp, "chat limit help")
end)

-- The Favours tab's thanks (#101, #491): "Thank them with" and "If that
-- can't reach them", each a label and a dropdown.

-- The options' scrolling content, opened at the tab with this label.
local function OpenTab(label)
    SlashCmdList.FRIENDLYFOREVER("")
    local panel = _G.FriendlyForeverOptionsPanel
    assertNotNil(panel)
    for _, child in ipairs({ panel:GetChildren() }) do
        local content = child.GetScrollChild and child:GetScrollChild()
        for _, tab in ipairs(content and { content:GetChildren() } or {}) do
            if tab.GetText and tab:GetText() == label then
                tab:GetScript("OnClick")(tab)
                return panel, content
            end
        end
    end
    check(false, "no options tab called " .. label)
end

-- The button or text line in content whose text is text, or nil.
local function WithText(content, text)
    for _, list in ipairs({ { content:GetChildren() }, { content:GetRegions() } }) do
        for _, region in ipairs(list) do
            if region.GetText and region:GetText() == text then return region end
        end
    end
end

-- Its right edge is inside the options panel.
local function EndsInside(panel, region, label)
    local _, right = Edges(region, "GetLeft", "GetRight")
    local _, panelRight = Edges(panel, "GetLeft", "GetRight")
    if not (right and panelRight) then
        report("LAYOUT " .. label .. ": edges can't be read here")
        return
    end
    local line = ("LAYOUT %s: ends at %.0f, options end at %.0f"):format(label, right, panelRight)
    report(line)
    check(right <= panelRight + 1, line .. ": past the edge of the options")
end

-- The texts each dropdown lists, in Options.THANK_STYLES' and
-- Options.FALLBACKS' order.
local THANK_WITH = { "a line in /say", "a whisper", "a /thank emote", "a line in /say and an emote" }
local CANT_REACH = { "say it in /say as", "/thank instead", "do nothing" }

-- The button in content showing one of texts, or nil.
local function ShowingOneOf(content, texts)
    for _, text in ipairs(texts) do
        local found = WithText(content, text)
        if found then return found end
    end
end

-- Each dropdown is opened, and every choice in its list is checked and picked
-- in turn, then the first is picked again and the list closed: nothing is left
-- changed, even when a check fails part way (#274).
test("the Favours tab's two dropdowns list every choice inside the options (#101, #274, #491)", function()
    local panel, content = OpenTab("Favours")
    local styleLabel = WithText(content, "Thank them with:")
    local fallbackLabel = WithText(content, "If that can't reach them:")
    local style, fallback = ShowingOneOf(content, THANK_WITH), ShowingOneOf(content, CANT_REACH)
    check(styleLabel and fallbackLabel and style and fallback, "the two choices aren't on the Favours tab")
    TextInside(panel, styleLabel, "Thank them with label", 1)
    TextInside(panel, fallbackLabel, "If that can't reach them label", 1)
    local failures = {}
    local function Fail(err) failures[#failures + 1] = tostring(err) end
    local function Round(dropdown, texts, name, extra)
        local ok, err = pcall(function()
            check(dropdown.list and dropdown.rows and #dropdown.rows == #texts,
                name .. " isn't a dropdown with " .. #texts .. " choices")
            dropdown:GetScript("OnClick")(dropdown)
            check(dropdown.list:IsShown(), name .. "'s list didn't open")
            -- The rows must sit above the click-away catcher, or a click on a
            -- row only closes the list (#427).
            local catcher = dropdown.list.catcher
            check(catcher, name .. " has no click-away catcher")
            for i, row in ipairs(dropdown.rows) do
                check(row:GetFrameStrata() == catcher:GetFrameStrata(), name .. " row " .. i .. " is in another strata")
                check(row:GetFrameLevel() > catcher:GetFrameLevel(), name .. " row " .. i .. " (level "
                    .. row:GetFrameLevel() .. ") isn't above its catcher (level " .. catcher:GetFrameLevel() .. ")")
            end
            report("LAYOUT " .. name .. ": rows at level " .. dropdown.rows[1]:GetFrameLevel()
                .. " above the catcher at " .. catcher:GetFrameLevel())
        end)
        if not ok then Fail(err) return end
        for i, row in ipairs(dropdown.rows) do
            local label = name .. ": " .. tostring(row:GetText())
            local rowOk, rowErr = pcall(function()
                check(row:GetText() == texts[i], label .. " isn't choice " .. i .. " (" .. texts[i] .. ")")
                TextInside(row, row:GetFontString(), label, 1)
                EndsInside(panel, row, label)
            end)
            if not rowOk then Fail(rowErr) end
        end
        for i = #dropdown.rows, 1, -1 do
            if dropdown.list:IsShown() == false then dropdown:GetScript("OnClick")(dropdown) end
            local row = dropdown.rows[i]
            row:GetScript("OnClick")(row)
            local pickedOk, pickedErr = pcall(function()
                check(dropdown:GetText() == texts[i], name .. " shows " .. tostring(dropdown:GetText())
                    .. " after picking " .. texts[i])
                check(not dropdown.list:IsShown(), name .. "'s list stayed open after a pick")
                TextInside(dropdown, dropdown:GetFontString(), name .. ": " .. texts[i], 1)
                EndsInside(panel, dropdown, name .. ": " .. texts[i])
                if extra then extra(i) end
            end)
            if not pickedOk then Fail(pickedErr) end
        end
    end
    Round(style, THANK_WITH, "Thank them with")
    Round(fallback, CANT_REACH, "If that can't reach them", function(i)
        if i ~= 1 then return end
        local box
        for _, child in ipairs({ content:GetChildren() }) do
            if child.GetObjectType and child:GetObjectType() == "EditBox" and child:IsShown()
                and child:GetText() == FriendlyForeverDB.buff.unknownName then box = child end
        end
        check(box, "the fallback's name box isn't shown")
        EndsInside(panel, box, "the fallback's name box")
    end)
    check(#failures == 0, table.concat(failures, "; "))
end)

-- The button's real states (#83), set up through game events by
-- button_states.lua, which the simulator loads before this file. Each runs
-- with Lua errors caught, and is put back even when a check fails.

-- What /friendly buffback says the button holds, for a failed check's message.
local function ButtonStatus()
    local ok, lines = pcall(CapturePrints, function() SlashCmdList.FRIENDLYFOREVER("buffback") end)
    return ok and table.concat(lines, " / ") or "(couldn't ask: " .. tostring(lines) .. ")"
end

-- Blizzard UI errors already reported, so each is printed once.
local notedErrors = {}

-- Real milliseconds since the simulator started, for the TIME lines.
local function Now()
    return type(debugprofilestop) == "function" and debugprofilestop() or 0
end

local function InState(label, state, fn)
    local States = FriendlyForeverUIStates
    check(type(States) == "table", "button_states.lua didn't load before this file")
    local started = Now()
    local failures, others = States.Watch(function()
        state.Set()
        fn(States.Button(), States)
    end)
    local undoFailures, undoOthers = States.Watch(state.Undo)
    report(("TIME %s: %.0f ms"):format(label, Now() - started))
    -- Not the addon's: reported, not failed (see States.Watch).
    for _, list in ipairs({ others, undoOthers }) do
        for _, text in ipairs(list) do
            local first = text:match("^[^\n]*")
            if not notedErrors[first] then
                notedErrors[first] = true
                report("NOTE Blizzard UI error in the simulator, not the addon's: " .. first)
            end
        end
    end
    check(#failures == 0, table.concat(failures, " | ") .. "\n  the button: " .. ButtonStatus())
    check(#undoFailures == 0, "putting it back: " .. table.concat(undoFailures, " | "))
end

local function Expect(ok, what)
    if not ok then check(false, what .. "\n  the button: " .. ButtonStatus()) end
end

-- The button is empty: it isn't up, and a press would cast nothing.
local function ExpectEmpty(States, when)
    Expect(States.Macro() == nil, when .. ": the button holds a macro")
    Expect(not States.Button():IsShown(), when .. ": the button is up")
end

-- The last argument to TextInside, 1: the name stays on one line. The line
-- below it may wrap: the button grows to hold it, never cutting it (#270).
test("with a favour owed, the button names the player and the buff, and its text stays inside it", function()
    InState("favour", FriendlyForeverUIStates.Favour, function(button, States)
        Expect(select(2, UnitClass("player")) == "PRIEST", "the player isn't a Priest")
        Expect(button:IsShown(), "the button isn't up")
        Expect(button.title:GetText() == States.STRANGER, "the title doesn't name " .. States.STRANGER)
        Expect(button.subtitle:GetText() == "buffed you - give " .. States.SPELL.name,
            "the hint doesn't name " .. States.SPELL.name)
        Expect(States.MacroTarget() == States.STRANGER, "the macro doesn't target " .. States.STRANGER)
        Expect((States.Macro() or ""):find("/cast [help,nodead] " .. States.SPELL.name, 1, true) ~= nil,
            "the macro doesn't cast " .. States.SPELL.name)
        TextInside(button, button.title, "favour title", 1)
        TextInside(button, button.subtitle, "favour hint")
        OnScreen(button, "buff-back button (favour)")
    end)
end)

-- A buff asked for in chat (#40, #362): the button names who asked, over
-- "asked for" and the longest buff name a request can ask for, inside it.
test("with a buff asked for in chat, the button names who asked and the buff, and its text stays inside it", function()
    InState("asked for", FriendlyForeverUIStates.Requested, function(button, States)
        Expect(button:IsShown(), "the button isn't up")
        Expect(button.title:GetText() == States.ASKER, "the title doesn't name " .. States.ASKER)
        Expect(button.subtitle:GetText() == "asked for " .. States.SPELL.name,
            "the hint doesn't say they asked for " .. States.SPELL.name)
        Expect(States.MacroTarget() == States.ASKER, "the macro doesn't target " .. States.ASKER)
        Expect((States.Macro() or ""):find("/cast [help,nodead] " .. States.SPELL.name, 1, true) ~= nil,
            "the macro doesn't cast " .. States.SPELL.name)
        TextInside(button, button.title, "asked-for title", 1)
        TextInside(button, button.subtitle, "asked-for hint")
        OnScreen(button, "buff-back button (asked for)")
    end)
end)

-- A weapon buff (#45, #424): picked in the list, the button reads "You"
-- over the item and the hand, its tooltip says what a press does, and the
-- list's row names the item and the hand. The longest item name a weapon
-- buff offers, so the row is the longest one a weapon buff makes.
test("with a weapon buff picked in the list, the button, its tooltip and its row name the item and hand", function()
    -- What the simulator itself answers for the reads the state gives (docs/ui-simulator.md).
    local W = FriendlyForeverUIStates.WEAPON
    local function Ask(fn, ...)
        if type(fn) ~= "function" then return "missing" end
        local got = { pcall(fn, ...) }
        if not got[1] then return "error" end
        local out = {}
        for i = 2, math.min(#got, 6) do out[#out + 1] = tostring(got[i]) end
        return #out > 0 and table.concat(out, ",") or "nothing"
    end
    local items = _G.C_Item or {}
    report(("FACT sim weapon reads: GetWeaponEnchantInfo %s; main hand item %s; %d count %s, usable %s, name %s")
        :format(Ask(_G.GetWeaponEnchantInfo), Ask(_G.GetInventoryItemID, "player", W.slot), W.item,
            Ask(items.GetItemCount or _G.GetItemCount, W.item), Ask(items.IsUsableItem or _G.IsUsableItem, W.item),
            Ask(items.GetItemNameByID, W.item)))
    InState("weapon buff", FriendlyForeverUIStates.WeaponOffer, function(button, States)
        Expect(button:IsShown(), "the button isn't up")
        Expect(button.title:GetText() == "You", "the title doesn't say You")
        Expect(button.subtitle:GetText() == W.name .. " on your " .. W.hand,
            ("the hint reads %q, not %q"):format(button.subtitle:GetText() or "", W.name .. " on your " .. W.hand))
        Expect(States.Macro() == ("/use item:%d\n/use %d"):format(W.item, W.slot),
            ("the macro reads %q, not the stone on the main hand"):format(States.Macro() or ""))
        TextInside(button, button.title, "weapon buff title", 1)
        TextInside(button, button.subtitle, "weapon buff hint")
        OnScreen(button, "buff-back button (weapon buff)")
        -- The list: the favour, then your weapon buff, marked as the one the button holds.
        local list = _G.FriendlyForeverBuffList
        Expect(list ~= nil and list:IsShown(), "the list isn't up")
        local shown = {}
        for _, row in ipairs(list and list.rows or {}) do
            if row:IsShown() then shown[#shown + 1] = row end
        end
        Expect(#shown == 2, ("the list has %d rows, not the favour and your weapon buff"):format(#shown))
        local want = ("> You: %s (%s)"):format(W.name, W.row)
        local row = shown[#shown]
        local text = row and row.text:GetText() or ""
        Expect(text == want, ("the weapon row reads %q, not %q"):format(text, want))
        Expect(shown[1] and (shown[1].text:GetText() or ""):find(States.WEAPONSTRANGER, 1, true) == 1,
            "the first row isn't the favour owed to " .. States.WEAPONSTRANGER)
        for i, each in ipairs(shown) do TextInside(each, each.text, "weapon buff list row " .. i, 1) end
        OnScreen(list, "buff list (weapon buff)")
        report("LAYOUT weapon buff row: " .. text)
        -- The tooltip, as the pointer over the button shows it.
        button:GetScript("OnEnter")(button)
        local lines = {}
        for i = 1, (GameTooltip.NumLines and GameTooltip:NumLines() or 0) do
            local region = _G["GameTooltipTextLeft" .. i]
            lines[#lines + 1] = region and region:GetText() or ""
        end
        local said = table.concat(lines, " / ")
        report("LAYOUT weapon buff tooltip: " .. said)
        Expect(said:find("Puts " .. W.name .. " on your " .. W.hand .. ".", 1, true) ~= nil,
            "the tooltip doesn't say it puts the stone on your main hand: " .. said)
        Expect(said:find("Right-click to skip your weapon buffs for 5 minutes.", 1, true) ~= nil,
            "the tooltip doesn't say what a right-click does: " .. said)
        OnScreen(GameTooltip, "buff-back button tooltip (weapon buff)")
        GameTooltip:Hide()
    end)
end)

-- In buff mode the button offers you first (#198), then the party member
-- missing your buff. The list beside the button (#43) makes the member the
-- next offer, so both states are measured.
test("in buff mode, you are offered first, then a party member missing your buff, and the text stays inside", function()
    InState("buff mode", FriendlyForeverUIStates.GroupMissing, function(button, States)
        Expect((button.mode:GetText() or ""):find("Buff mode:", 1, true) ~= nil, "buff mode isn't on")
        Expect(button:IsShown(), "the button isn't up")
        -- You come first, cast on yourself with [@player].
        Expect(button.title:GetText() == "You", "the title doesn't say You")
        Expect(button.subtitle:GetText() == "missing your " .. States.SPELL.name,
            "the hint doesn't offer " .. States.SPELL.name)
        Expect((States.Macro() or ""):find("/cast [@player,nodead] " .. States.SPELL.name, 1, true) ~= nil,
            "the macro doesn't cast " .. States.SPELL.name .. " on you")
        TextInside(button, button.title, "buff mode (you first) title", 1)
        TextInside(button, button.subtitle, "buff mode (you first) hint")
        OnScreen(button, "buff-back button (buff mode, you first)")
        -- A click on the party member's row in the list makes her the next offer.
        local list = _G.FriendlyForeverBuffList
        Expect(list ~= nil and list:IsShown(), "the list isn't up")
        local member
        for _, row in ipairs(list.rows) do
            if row:IsShown() and (row.text:GetText() or ""):find(States.GROUPMATE, 1, true) then member = row end
        end
        Expect(member ~= nil, "the list has no row for " .. States.GROUPMATE)
        member:GetScript("OnClick")(member)
        Expect(button.title:GetText() == States.GROUPMATE, "the title doesn't name " .. States.GROUPMATE)
        Expect(button.subtitle:GetText() == "missing your " .. States.SPELL.name,
            "the hint doesn't offer " .. States.SPELL.name)
        Expect(States.MacroTarget() == States.GROUPMATE, "the macro doesn't target " .. States.GROUPMATE)
        TextInside(button, button.title, "buff mode title", 1)
        TextInside(button, button.subtitle, "buff mode hint")
        OnScreen(button, "buff-back button (buff mode)")
    end)
end)

-- The list beside the button (#43): its rows list who the button would offer
-- to, a click on a row changes the next offer, and it keeps out of the way
-- in a fight. Casting stays with the button.
test("the list beside the button shows who is offered, a click picks the next, and its text stays inside", function()
    InState("buff list", FriendlyForeverUIStates.ListFilled, function(button, States)
        local list = _G.FriendlyForeverBuffList
        Expect(list ~= nil and list:IsShown(), "the list isn't up")
        local wanted = 1 + #States.LISTED -- Eira's favour, then the party
        local shown = {}
        for _, row in ipairs(list.rows) do
            if row:IsShown() then shown[#shown + 1] = row end
        end
        Expect(#shown == wanted, ("the list has %d rows, not %d"):format(#shown, wanted))
        Expect(States.MacroTarget() == States.LISTSTRANGER, "the button doesn't hold the first row's player")
        for i, row in ipairs(shown) do
            TextInside(row, row.text, "list row " .. i, 1)
        end
        OnScreen(list, "buff list")
        -- It must never cover the button, which would take the button's clicks.
        local okEdges, bl, br, ll, lr = pcall(function()
            return button:GetLeft(), button:GetRight(), list:GetLeft(), list:GetRight()
        end)
        local numbers = type(bl) == "number" and type(br) == "number" and type(ll) == "number"
            and type(lr) == "number"
        if okEdges and numbers then
            local line = ("LAYOUT buff list beside the button: list %.0f..%.0f, button %.0f..%.0f")
                :format(ll, lr, bl, br)
            report(line)
            check(lr <= bl + 1 or ll >= br - 1, line .. ": the list covers the button")
        else
            report("LAYOUT buff list beside the button: edges can't be read here")
        end
        -- Clicking the last row (the long name) makes that player the next offer.
        shown[#shown]:GetScript("OnClick")(shown[#shown])
        Expect(States.MacroTarget() == States.LONGNAME, "a click on the last row didn't make that player next")
        -- In a fight the list is gone, and the button empties as before.
        States.Combat(true)
        Expect(not list:IsShown(), "the list is up in a fight")
        States.Combat(false)
    end)
end)

-- "Already done by" (#256, the owner's rule 2): on entering, a buff another
-- member put up in step shows in red, the button empty and the list hidden,
-- inside the button, then fades and moves on to the next buff you need.
test("the button says a buff is already done, in red, then moves on", function()
    InState("already done", FriendlyForeverUIStates.AlreadyDone, function(button, States)
        local title = button and button.title:GetText() or ""
        local first = States.DONE_BY:match("^%S+")
        Expect(title:find("Already done by " .. first, 1, true) ~= nil,
            ("the button reads %q, not \"Already done by %s\""):format(title, first))
        Expect(title:find("|cffff6e86", 1, true) ~= nil, "the note isn't in the palette's red (bad)")
        -- Left-aligned like the line below it, after its smaller font (#264).
        local justify = button.title.GetJustifyH and button.title:GetJustifyH()
        Expect(justify == nil or justify == "LEFT",
            ("the note's title is aligned %s, not LEFT"):format(tostring(justify)))
        Expect(States.Macro() == nil, "the button holds a macro while the note shows")
        local list = _G.FriendlyForeverBuffList
        Expect(not (list and list:IsShown()), "the list is up while the note shows")
        -- The name is the point of the note: it must not be cut short.
        local titleLine = TextInside(button, button.title, "already-done title", 1)
        Expect(not titleLine:find("cut short", 1, true), titleLine .. ": the note's title is cut short")
        TextInside(button, button.subtitle, "already-done spell")
        OnScreen(button, "button (already done)")
        report("LAYOUT already done: " .. title .. " / " .. (button.subtitle:GetText() or ""))
        States.Advance(2)
        Expect(States.Macro() ~= nil, "after 2 seconds the button doesn't hold the next buff")
        Expect(not (button.title:GetText() or ""):find("Already done", 1, true), "the note is still up")
    end)
end)

-- A long reason the button shows (#270): whole, wrapped inside the button,
-- never cut short, at every size. The specs try every length.
test("a long reason the button shows wraps whole inside it", function()
    InState("long reason", FriendlyForeverUIStates.LongReason, function(button, States)
        Expect(button:IsShown(), "the button isn't up in buff mode")
        Expect(States.Macro() == nil, "the button holds a macro")
        local reason = button.subtitle:GetText() or ""
        Expect(reason:find("can't see whether they're flagged for PvP (target them, or show friendly nameplates)",
            1, true) ~= nil, ("the reason reads %q, not the long one"):format(reason))
        local line = TextInside(button, button.subtitle, "long reason")
        Expect(not line:find("cut short", 1, true), line .. ": the reason is cut short")
        TextInside(button, button.title, "long reason title", 1)
        OnScreen(button, "buff-back button (long reason)")
        report("LAYOUT long reason: " .. reason)
    end)
end)

-- A group cast is one row in the list (#227): who it reaches, how many are
-- missing, and the spell; the members it covers have no rows of their own.
test("the list shows a group cast as one row, and its text stays inside", function()
    InState("buff list, group cast", FriendlyForeverUIStates.ListGroupCast, function(_, States)
        local list = _G.FriendlyForeverBuffList
        Expect(list ~= nil and list:IsShown(), "the list isn't up")
        local shown = {}
        for _, row in ipairs(list.rows) do
            if row:IsShown() then shown[#shown + 1] = row end
        end
        Expect(#shown == 1, ("the list has %d rows, not the one group row"):format(#shown))
        local text = shown[1].text:GetText() or ""
        -- The party and you: the group version covers you too.
        local covered = #States.GROUP_MEMBERS + 1
        local want = ("Party (%d): %s"):format(covered, States.GROUP_SPELL.name)
        Expect(text == "> " .. want, ("the row reads %q, not %q"):format(text, "> " .. want))
        TextInside(shown[1], shown[1].text, "group row", 1)
        OnScreen(list, "buff list (group cast)")
        report("LAYOUT group row: " .. text)
        -- The longest rows a group cast can make are shown whole, not cut
        -- (#227): the longest buff names with the longest group parts. Set
        -- on the row for the check, then put back.
        local region = shown[1].text
        for _, worst in ipairs({
            "> Party (4): Prayer of Shadow Protection",
            "> Group 3 (5): Prayer of Shadow Protection",
            "> Warlocks (12): Greater Blessing of Wisdom",
            "> Warriors (40): Greater Blessing of Wisdom",
        }) do
            region:SetText(worst)
            TextInside(shown[1], region, "longest group row", 1)
            local width = region:GetStringWidth()
            local left, right = region:GetLeft(), region:GetRight()
            if type(width) == "number" and type(left) == "number" and type(right) == "number" then
                local line = ("LAYOUT longest group row %q: text %.0f wide, room for %.0f"):format(worst, width,
                    right - left + 1)
                report(line)
                check(width <= right - left + 1, line .. ": the row is cut short")
            else
                report("LAYOUT longest group row: width can't be read here")
            end
        end
        region:SetText(text)
    end)
end)

-- Units no favour can come from: empty, a token that shows no one, the
-- target when there's no target, a party slot when not in a party, you, a
-- number, and values that aren't text at all (#98).
local BAD_SOURCES = { "", "nameplate77", "target", "party3", "player", 42, true, { "target" } }

test("a buff naming an unknown or empty unit leaves the button empty, with no Lua error", function()
    local States = FriendlyForeverUIStates
    local stranger = "Cael Morrow"
    local learned = { Set = function() States.PassLoginGrace(); States.Learn() end,
        Undo = States.FavourFrom(stranger).Undo }
    InState("bad sources", learned, function()
        ExpectEmpty(States, "before any buff")
        States.BuffedBy(nil)
        ExpectEmpty(States, "a buff naming no caster")
        for _, source in ipairs(BAD_SOURCES) do
            States.BuffedBy(source)
            ExpectEmpty(States, "a buff from " .. tostring(source))
        end
        -- The same buff from a real player does fill it: the fixture works.
        States.Target(stranger)
        States.BuffedBy("target")
        Expect(States.MacroTarget() == stranger, "a buff from your target owes no favour")
    end)
end)

-- A small deterministic random sequence (Park-Miller), the same on every run.
local function Random(seed)
    local x = seed
    return function(n)
        x = (x * 16807) % 2147483647
        return x % n + 1
    end
end

test("entering combat empties the button, leaving fills it again; storms never error", function()
    local stranger = "Daria Venn"
    InState("combat and storm", FriendlyForeverUIStates.FavourFrom(stranger), function(button, States)
        Expect(States.MacroTarget() == stranger, "no favour to start with")
        States.Combat(true)
        ExpectEmpty(States, "in combat")
        States.Combat(false)
        Expect(button:IsShown() and States.MacroTarget() == stranger,
            "the button didn't fill again after combat")

        -- A storm of fights, buffs from anyone, targets and roster changes.
        -- The rules are worked out from what was done here, not by asking
        -- the addon: in a fight the button holds nothing; out of one it
        -- holds nothing, or a buff for one of the two players who could be
        -- owed or offered one, and its title names whoever the macro targets.
        local roll, fighting = Random(83), false
        local sources = { "target", "", "nameplate3", "party1", 42 }
        local steps = {
            function() if not fighting then States.Combat(true); fighting = true end end,
            function() if fighting then States.Combat(false); fighting = false end end,
            function() States.BuffedBy(sources[roll(#sources)]) end,
            function() States.Target(stranger) end,
            function() States.Target(nil) end,
            -- Party changes only out of a fight: in one, the simulator's
            -- Blizzard party and raid frames take 20-90 seconds over each
            -- (their own errors, not the addon's). spec/buffmodeauto_spec.lua
            -- covers the roster changing in a fight.
            function() if not fighting then States.Party(States.GROUPMATE) end end,
            function() if not fighting then States.Party(nil) end end,
            function() States.Advance(roll(4) - 1) end,
        }
        local allowed = { [stranger] = true, [States.GROUPMATE] = true }
        for step = 1, 60 do
            local which = roll(#steps)
            local stepStarted = Now()
            steps[which]()
            local acted = Now()
            -- A frame passes, as between the game's events: what the addon
            -- leaves for the next frame runs, and its time budget resets.
            States.Advance(0)
            if Now() - stepStarted > 250 then
                report(("TIME storm step %d (action %d, %s): %.0f ms, then a frame: %.0f ms"):format(
                    step, which, fighting and "in a fight" or "out of one", acted - stepStarted, Now() - acted))
            end
            local at = ("storm step %d (action %d)"):format(step, which)
            if fighting then
                Expect(States.Macro() == nil, at .. ": the button holds a macro in a fight")
            else
                local target = States.MacroTarget()
                Expect(States.Macro() == nil or allowed[target], at .. ": the button targets " .. tostring(target))
                if target then
                    Expect(button.title:GetText() == target, at .. ": the title doesn't name " .. target)
                end
            end
        end

        -- After the storm: out of the fight and the party, the stranger targeted.
        if fighting then States.Combat(false) end
        States.Party(nil)
        States.Target(stranger)
        Expect(button:IsShown() and States.MacroTarget() == stranger,
            "the favour didn't come back after the storm")
    end)
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

-- Not covered here: flows about waiting in game time (the login grace,
-- message delays). The simulator does have a manual clock
-- (A_Admin.SetManualClock and AdvanceTime), which button_states.lua uses
-- to get past the login grace, but those flows stay in spec/, whose
-- simulated client controls time too (wow.advance) and models Forever.
-- Once the button-state scenarios have run, game time stays frozen for the
-- rest of the run: a later test whose timers must fire calls
-- A_Admin.AdvanceTime itself.

-- The phase 1 pages (#52): the options' General and Favour Ledger pages,
-- filled by pages.lua with the longest names and most entries a player
-- could have, and the copy window. Text on a page may wrap on purpose, so
-- its lines aren't counted; a button's text stays on one line. Every line is
-- checked and printed before any failure is raised.

local function Short(text)
    text = tostring(text):gsub("\n", " ")
    return #text > 40 and text:sub(1, 37) .. "..." or text
end

-- Runs each check, collecting failures instead of stopping at the first.
local function CheckAll(checks)
    local failures = {}
    for _, fn in ipairs(checks) do
        local ok, err = pcall(fn)
        if not ok then failures[#failures + 1] = tostring(err) end
    end
    check(#failures == 0, table.concat(failures, "\n"))
end

-- Every shown text line on frame, on at most maxLines lines when given,
-- and every shown button's label on it, on one line.
local function FrameTextInside(frame, label, maxLines)
    local checks = {}
    for _, region in ipairs({ frame:GetRegions() }) do
        if region:GetObjectType() == "FontString" and region:IsShown() and (region:GetText() or "") ~= "" then
            checks[#checks + 1] = function()
                TextInside(frame, region, label .. " \"" .. Short(region:GetText()) .. "\"", maxLines)
            end
        end
    end
    for _, child in ipairs({ frame:GetChildren() }) do
        local text = child:IsShown() and child:GetObjectType() == "Button" and child.GetFontString
            and child:GetFontString()
        if text and (text:GetText() or "") ~= "" then
            checks[#checks + 1] = function()
                TextInside(child, text, label .. " button \"" .. Short(text:GetText()) .. "\"", 1)
            end
        end
    end
    check(#checks > 0, label .. ": no text to check")
    CheckAll(checks)
end

-- Whether frame is a scrolling page's content: the child of a scroll frame.
local function IsScrolled(frame)
    local scroll = frame.GetParent and frame:GetParent()
    return scroll ~= nil and scroll.GetObjectType ~= nil and scroll:GetObjectType() == "ScrollFrame"
end

-- The addon sizes a scrolling page's content to its rows each time its
-- scroll frame shows (#482: FitHeight in Options.lua). Showing it again
-- here sizes it from the rows where they are now.
local function Refit(content)
    if not IsScrolled(content) then return end
    local scroll = content:GetParent()
    local onShow = scroll:GetScript("OnShow")
    if onShow then onShow(scroll) end
end

-- The simulator re-lays out only 16 links down an anchor chain when a
-- region moves (docs/ui-simulator.md). Switching tabs moves the message
-- list's header, so message rows past the 17th, the buttons and the notes
-- below them keep the last tab's places. Setting each region's own anchors
-- again, in the order they were made, and reading its place, carries the
-- move down the chain: each one re-lays itself and 16 more. Twice, since
-- regions and child frames hang from each other. The anchors are the same
-- afterwards.
local function Settle(content)
    local function Again(region)
        local points = {}
        for i = 1, (Measure(region, "GetNumPoints") or 0) do points[i] = { region:GetPoint(i) } end
        if #points == 0 then return end
        region:ClearAllPoints()
        for _, p in ipairs(points) do region:SetPoint(unpack(p, 1, 5)) end
        -- Asking where it is lays it out now, from the regions above it,
        -- which were laid out the same way just before.
        Edges(region, "GetTop", "GetBottom")
    end
    for _ = 1, 2 do
        for _, region in ipairs({ content:GetRegions() }) do Again(region) end
        for _, child in ipairs({ content:GetChildren() }) do Again(child) end
    end
    -- The addon sized a scrolling page's content to its rows as it showed
    -- (#482), from places read before this; it sizes it again from these.
    Refit(content)
end

-- In the game a text line with no height set grows with its wrapped text,
-- and pushes down whatever is anchored below it. The simulator doesn't wrap
-- a line pinned to two frames (WrappedLines), so nothing moves there. This
-- works out where each region would end in the game: pushed down by the
-- extra lines of every text line above it, and lower still by its own extra
-- lines, at the pessimistic 17 px a line (docs/ui-simulator.md). Prints a
-- LAYOUT line for the lowest region, fails if it would leave frame, and
-- returns the line. Pages here are one column, so everything above a region
-- pushes it.
local PUSH_LINE = 17

-- A scrolling page's content ends at its last shown row plus the addon's
-- margin (#482: 16 px, Options.SCROLL_MARGIN, given here as a number), so
-- it never scrolls into an empty pane, and a page that fits has no scroll
-- bar. The game's scroll range is the content's height less the view's;
-- the simulator's own GetVerticalScrollRange can't be trusted for it
-- (docs/ui-simulator.md), so it is only printed. Frames that float over
-- the rows (an open list) don't count, as for the addon. Prints a LAYOUT
-- line, fails if it doesn't hold, and returns the line.
local SCROLL_MARGIN = 16

-- Whether a frame floats over a scrolling page's rows (Options.Floating):
-- marked so, and also floating by its look, so a row marked by mistake
-- still counts. The who-gets list is drawn above the rows (a higher
-- strata); the key capture covers the whole content (its edges are the
-- content's).
local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5,
    FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
local function Floats(content, region)
    if not region.floating then return false end
    local mine = STRATA[region.GetFrameStrata and region:GetFrameStrata() or ""]
    local theirs = STRATA[content.GetFrameStrata and content:GetFrameStrata() or ""]
    if mine and theirs and mine > theirs then return true end
    local top, bottom = Edges(region, "GetTop", "GetBottom")
    local cTop, cBottom = Edges(content, "GetTop", "GetBottom")
    return top ~= nil and cTop ~= nil and math.abs(top - cTop) <= 1 and math.abs(bottom - cBottom) <= 1
end

local function ScrollFits(content, label)
    local scroll = content:GetParent()
    local top, bottom = Edges(content, "GetTop", "GetBottom")
    local lowest
    local function Look(region)
        if not region:IsShown() or Floats(content, region) then return end
        local _, b = Edges(region, "GetTop", "GetBottom")
        if b and (not lowest or b < lowest) then lowest = b end
    end
    for _, child in ipairs({ content:GetChildren() }) do Look(child) end
    for _, region in ipairs({ content:GetRegions() }) do Look(region) end
    local view, range = Measure(scroll, "GetHeight"), Measure(scroll, "GetVerticalScrollRange")
    if not (top and lowest and view and range) then
        local line = "LAYOUT " .. label .. " scroll: edges can't be read here"
        report(line)
        check(false, line)
        return line
    end
    local height, tail = top - bottom, lowest - bottom
    local bar = scroll.ScrollBar
    local barShown = bar ~= nil and bar:IsShown() == true
    local line = ("LAYOUT %s scroll: %.0f px below its last row (most %d), content %.0f, view %.0f, "
        .. "so a range of %.0f (the simulator reads %.0f), scroll bar %s"):format(label, tail, SCROLL_MARGIN,
        height, view, math.max(0, height - view), range, bar == nil and "none" or (barShown and "shown" or "hidden"))
    report(line)
    check(tail >= -1, line .. ": its last row is cut off")
    check(tail <= SCROLL_MARGIN + 1, line .. ": it scrolls into an empty pane")
    if bar then
        check(barShown == (height > view + 1), line .. (barShown and ": a page that fits shows a scroll bar"
            or ": a page that scrolls hides its scroll bar"))
    end
    return line
end

local function PushedDownInside(frame, label)
    -- A scrolling page's content grows with its rows (#482), the game's
    -- wrapped text included, so wrapping can't push a row out of it: what
    -- matters is that it ends at its last row. The layout is settled first,
    -- which also sizes it again from where its rows are now.
    local scrolled = IsScrolled(frame)
    if scrolled then Settle(frame) end
    local _, fb = Edges(frame, "GetTop", "GetBottom")
    if not fb then
        local line = "LAYOUT " .. label .. " pushed down: edges can't be read here"
        report(line)
        return line
    end
    local items, extra = {}, {}
    for _, region in ipairs({ frame:GetRegions() }) do
        if region:GetObjectType() == "FontString" and region:IsShown() and (region:GetText() or "") ~= "" then
            items[#items + 1] = region
            local tl, tr = Edges(region, "GetLeft", "GetRight")
            local wrapped = tl and WrappedLines(region, tl, tr)
            local count = Measure(region, "GetNumLines") or 1
            if wrapped and wrapped > count then extra[region] = (wrapped - count) * PUSH_LINE end
        end
    end
    for _, child in ipairs({ frame:GetChildren() }) do
        if child:IsShown() then items[#items + 1] = child end
    end
    local lowest, lowestName
    for _, item in ipairs(items) do
        local top, bottom = Edges(item, "GetTop", "GetBottom")
        if top then
            local push = extra[item] or 0
            for _, other in ipairs(items) do
                local otherTop = extra[other] and Edges(other, "GetTop", "GetBottom")
                if otherTop and otherTop > top + 1 then push = push + extra[other] end
            end
            local drawn = bottom - push
            if not lowest or drawn < lowest then
                lowest = drawn
                lowestName = item.GetText and item:GetText() or (item.GetName and item:GetName()) or "a frame"
            end
        end
    end
    if not lowest then return scrolled and ScrollFits(frame, label) or nil end
    local line = ("LAYOUT %s pushed down by wrapped text: lowest \"%s\" ends at %.0f, frame bottom %.0f"):format(
        label, Short(lowestName), lowest, fb)
    report(line)
    if scrolled then return ScrollFits(frame, label) end
    check(lowest >= fb - 1, line .. ": would leave its frame in the game")
    return line
end

-- Whether any shown text line on frame contains fragment (plain text).
local function ShowsText(frame, fragment)
    for _, region in ipairs({ frame:GetRegions() }) do
        if region:GetObjectType() == "FontString" and region:IsShown()
            and (region:GetText() or ""):find(fragment, 1, true) then
            return true
        end
    end
    return false
end

-- Runs fn with the pages filled, and puts the saved settings back after,
-- even when fn fails.
local function WithPagesFilled(fn)
    local undo = FriendlyForeverUIPages.Fill()
    local ok, err = pcall(fn)
    undo()
    if not ok then error(err, 0) end
end

test("the General page, with a long ignore list and several profiles, keeps its text inside it", function()
    WithPagesFilled(function()
        local page = FriendlyForeverUIPages.Open("general")
        check(page:IsVisible(), "the General page didn't open")
        -- The page's lines are on its scrolling content (#52). The checks
        -- below mean nothing on a page still showing the default lists, so
        -- first make sure it shows the fill.
        local content = page.content
        check(ShowsText(content, "Aerendhiliel Stormwhisper")
            and ShowsText(content, "Using Raid nights in Naxxramas, team 1."),
            "the General page doesn't show the filled ignore list and profiles")
        OnScreen(page, "General page")
        CheckAll({
            function() FrameTextInside(content, "General page") end,
            function() PushedDownInside(content, "General page") end,
        })
    end)
end)

test("the Weapon buffs page, switched on with a kind for each hand, keeps its text inside it (#45)", function()
    WithPagesFilled(function()
        local page = FriendlyForeverUIPages.Open("weapon")
        check(page:IsVisible(), "the Weapon buffs page didn't open")
        OnScreen(page, "Weapon buffs page")
        CheckAll({
            function() FrameTextInside(page, "Weapon buffs page") end,
            function() PushedDownInside(page, "Weapon buffs page") end,
        })
    end)
end)

test("the Favour Ledger page, with a full page of long entries, keeps its text inside it", function()
    WithPagesFilled(function()
        local page = FriendlyForeverUIPages.Open("ledger")
        check(page:IsVisible(), "the Favour Ledger page didn't open")
        check(not ShowsText(page, "Nobody outside your group has buffed you yet."),
            "the Favour Ledger page doesn't show the filled ledger")
        OnScreen(page, "Favour Ledger page")
        CheckAll({
            function() FrameTextInside(page, "Favour Ledger page") end,
            function() PushedDownInside(page, "Favour Ledger page") end,
        })
    end)
end)

-- With the lists as a new player has them, the page's last line must still
-- be inside its scrolling content once every note has wrapped as it does in
-- the game (#35). The filled page above is the worst case (#52).
test("the General page's last line is still on the page (#35)", function()
    local page = OpenGeneralPage()
    check(page:IsVisible(), "the General page didn't open")
    PushedDownInside(page.content, "General page (as a new player has it)")
end)

-- The copy window as each command opens it: export (a line to copy), import
-- (a box to paste into, and an Import button) and the bug report. The
-- window's own text (its title and hint) keeps to two lines: the text box
-- starts below the hint's second line.
test("the copy window keeps its text inside it, for export, import and the bug report", function()
    for _, command in ipairs({ "export", "import", "report" }) do
        SlashCmdList.FRIENDLYFOREVER(command)
        local window = _G[FriendlyForeverUIPages.WINDOW]
        local ok, err = pcall(function()
            check(window and window:IsShown(), "/friendly " .. command .. " didn't open the copy window")
            local label = "copy window (" .. command .. ")"
            OnScreen(window, label)
            FrameTextInside(window, label, 2)
        end)
        if window then window:Hide() end
        if not ok then error(err, 0) end
    end
end)

-- The main panel's tabs (#112), each opened by clicking its button the way
-- a player would (pages.lua's OpenTab). Each tab's own rows are on the
-- panel's scrolling content, and the rows of the other tabs are hidden.

-- Every visible text line on content, checkbox label and button label, with
-- the tab's name in its LAYOUT line: each must stay inside content (the
-- panel, less its scroll bar), and a button's label inside its button, on
-- one line. Lines on content may wrap on purpose (the notes at the bottom),
-- so they aren't counted; a checkbox's label has no width set and never
-- wraps. Every line is checked and printed before any failure is raised.
local function TabTextInside(content, label)
    local checks = {}
    -- A scrolling page's content grows with its rows, the game's wrapped
    -- text included (#482), so up and down a line is compared with it as the
    -- client lays both out (TextInside's grows).
    local grows = IsScrolled(content)
    local function Add(frame, region, what, maxLines, oneLine)
        checks[#checks + 1] = function()
            TextInside(frame, region, ("%s %s\"%s\""):format(label, what, Short(region:GetText())), maxLines, oneLine,
                grows and frame == content)
        end
    end
    local function Texts(frame)
        local found = {}
        for _, region in ipairs({ frame:GetRegions() }) do
            if region:GetObjectType() == "FontString" and region:IsVisible() and (region:GetText() or "") ~= "" then
                found[#found + 1] = region
            end
        end
        return found
    end
    -- A line pinned at one point has the width it was given (the Buff Back
    -- rows' names, 220), so a name wider than that wraps into the next row
    -- (#177). Lines pinned on two sides may wrap on purpose. Since the
    -- self-buffs (#44), a buff row's name ("8. Shadow Resistance Aura (you
    -- only)") may wrap onto a second line, centred on its row, which
    -- spec/layout_spec.lua checks never reaches the next row's: two lines.
    for _, region in ipairs(Texts(content)) do
        local oneLine = Measure(region, "GetNumPoints") == 1 and not AnchoredOn(region, "RIGHT")
        if oneLine and (region:GetText() or ""):find("^%d+%. ") then
            Add(content, region, "", 2)
        else
            Add(content, region, "", nil, oneLine)
        end
    end
    for _, child in ipairs({ content:GetChildren() }) do
        if child:IsVisible() then
            local kind = child:GetObjectType()
            if kind == "CheckButton" then
                for _, region in ipairs(Texts(child)) do Add(content, region, "checkbox ", 1) end
            elseif kind == "Button" then
                local text = child.GetFontString and child:GetFontString()
                if text and (text:GetText() or "") ~= "" then
                    Add(child, text, "button ", 1)
                    Add(content, text, "button on the panel ", 1)
                end
            end
        end
    end
    check(#checks > 0, label .. ": no text to check")
    CheckAll(checks)
end

-- How many of the message rows ("1." to "30.") read at or above the row
-- before them, or can't be read: 0 when the layout is in order.
local function RowsOutOfPlace(content)
    local rows = {}
    for _, region in ipairs({ content:GetRegions() }) do
        local n = region:GetObjectType() == "FontString" and region:IsVisible()
            and tonumber((region:GetText() or ""):match("^(%d+)%.$"))
        if n then rows[n] = region end
    end
    local count, last = 0, nil
    for n = 1, #rows do
        local top = Edges(rows[n], "GetTop", "GetBottom")
        if not top or (last and top >= last) then count = count + 1 end
        last = top or last
    end
    return count
end

-- Whether the message rows ("1." to "30.", each hung below the one before)
-- are drawn in order, top to bottom, with what follows them (the first
-- visible region whose top is named by follows) below the last. A stale
-- layout (Settle) shows up as a row above the one before it, and its
-- up-and-down checks would read the old tab's places. Prints a LAYOUT line,
-- fails if they aren't, and returns the line.
local function RowsInOrder(content, label, follows)
    local rows = {}
    for _, region in ipairs({ content:GetRegions() }) do
        local n = region:GetObjectType() == "FontString" and region:IsVisible()
            and tonumber((region:GetText() or ""):match("^(%d+)%.$"))
        if n then rows[n] = region end
    end
    check(#rows > 0, label .. ": no message rows")
    -- last: the top of the last row read, lastN its number.
    local problems, last, lastN = {}, nil, nil
    for n = 1, #rows do
        local top = Edges(rows[n], "GetTop", "GetBottom")
        if not top then
            problems[#problems + 1] = ("%d. can't be read"):format(n)
        else
            if last and top >= last then
                problems[#problems + 1] = ("%d. at %.0f is not below %d. at %.0f"):format(n, top, lastN, last)
            end
            last, lastN = top, n
        end
    end
    local after
    for _, child in ipairs({ content:GetChildren() }) do
        if child:IsVisible() and child.GetText and child:GetText() == follows then after = child end
    end
    local afterTop = after and Edges(after, "GetTop", "GetBottom")
    if not afterTop then
        problems[#problems + 1] = "\"" .. follows .. "\" can't be read"
    elseif last and afterTop >= last then
        problems[#problems + 1] = ("\"%s\" at %.0f is not below %d. at %.0f"):format(follows, afterTop, lastN, last)
    end
    local line = ("LAYOUT %s message rows: 1. to %d. in order top to bottom, then \"%s\"%s"):format(
        label, #rows, follows, #problems > 0 and ": " .. table.concat(problems, "; ") or "")
    report(line)
    check(#problems == 0, line .. ": the layout is stale or out of order")
    return line
end

-- Runs fn(content, tab) with the options open at each tab in turn, then
-- goes back to the first tab, even when a check fails. The Buffs tab's
-- buffs must carry their Forever names, as the simulator's own spell data
-- gives them (pages.lua's UnnamedBuff, #158, #160): rows of buff keys
-- would pass every layout check on text far shorter than a player reads.
local function OnEachTab(fn)
    local Pages = FriendlyForeverUIPages
    local ok, err = pcall(function()
        local unnamed = Pages.UnnamedBuff()
        check(unnamed == nil, "the Buffs tab's buffs aren't named as on Forever: " .. tostring(unnamed))
        for _, tab in ipairs(Pages.TABS) do
            local content = Pages.OpenTab(tab.name)
            check(content ~= nil, "couldn't open the " .. tab.label .. " tab")
            fn(content, tab)
        end
    end)
    Pages.OpenTab(Pages.TABS[1].name)
    if not ok then error(err, 0) end
end

-- The selected tab is the one whose button is disabled (Options.lua's Fill).
local function SelectedTabs(content)
    local selected = {}
    for _, tab in ipairs(FriendlyForeverUIPages.TABS) do
        for _, child in ipairs({ content:GetChildren() }) do
            -- Shown only, should a hidden button share the text.
            if child:GetObjectType() == "Button" and child:GetText() == tab.label and not child:IsEnabled()
                and child:IsShown() then
                selected[#selected + 1] = tab.label
            end
        end
    end
    return selected
end

test("each options tab opens by its button, and keeps its checkboxes and labels inside the panel", function()
    local failures = {}
    OnEachTab(function(content, tab)
        local ok, err = pcall(function()
            local name = tab.label .. " tab"
            check(table.concat(SelectedTabs(content), ", ") == tab.label,
                name .. ": the selected tabs are " .. table.concat(SelectedTabs(content), ", "))
            check(tab.noHeader or ShowsText(content, tab.label .. "  "), name .. ": the header doesn't name the tab")
            OnScreen(_G[FriendlyForeverUIPages.PANEL], "options panel (" .. name .. ")")
            -- Every place below is read from a settled layout, or the
            -- checks fail: none passes on the last tab's places. How many
            -- rows read out of place before that is reported, so a run
            -- says whether the simulator still needs it (#160).
            report(("FACT sim %s: %d message row(s) out of place before the layout is settled"):format(
                name, RowsOutOfPlace(content)))
            Settle(content)
            RowsInOrder(content, name, "Preview random")
            CheckAll({
                function() TabTextInside(content, name) end,
                function() PushedDownInside(content, name) end,
            })
        end)
        if not ok then failures[#failures + 1] = tostring(err) end
    end)
    check(#failures == 0, table.concat(failures, "\n"))
end)

-- The Buffs tab at its tallest (#44, #363's testing review, #408): a
-- paladin lists 11 buff rows (the self-buffs included), and one who knows a
-- Blessing has the raid Blessings rows on the Raid place, where a buff's
-- Always and Never names open under its row. The simulator's paladin knows
-- no Blessing, so here the paladin learns Blessing of Kings, the choice is
-- made, and each place is laid out with the first buff's names open, and its
-- who-gets list. The saved settings and the spell are put back, even when a
-- check fails.
local KINGS = 20217

local function DeepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = DeepCopy(v) end
    return copy
end

-- The who-gets list's shade covers all it holds: every tick, its label and
-- Off lie inside the list's edges (#408's architecture review: the shade
-- stopped 70 px short). The click catcher behind it spans the screen.
local function ListHoldsAll(list, label)
    local left, right = Edges(list, "GetLeft", "GetRight")
    local top, bottom = Edges(list, "GetTop", "GetBottom")
    if not (left and top) then
        report("LAYOUT " .. label .. ": edges can't be read here")
        return
    end
    local function Inside(region, what)
        local l, r = Edges(region, "GetLeft", "GetRight")
        local t, b = Edges(region, "GetTop", "GetBottom")
        if not (l and t) then return end
        local line = ("LAYOUT %s, %s: %.0f..%.0f across, %.0f..%.0f up, list %.0f..%.0f, %.0f..%.0f")
            :format(label, what, l, r, b, t, left, right, bottom, top)
        report(line)
        check(l >= left - 1 and r <= right + 1 and b >= bottom - 1 and t <= top + 1, line .. ": outside the list")
    end
    -- Every control must sit above the click-away catcher, or a click on a
    -- tick only closes the list (#427).
    local catcher = list.catcher
    if catcher then
        report("LAYOUT " .. label .. ": controls at level " .. list:GetFrameLevel() + 2
            .. " above the catcher at " .. catcher:GetFrameLevel())
    end
    for _, child in ipairs({ list:GetChildren() }) do
        if child:IsShown() and child ~= list.catcher then
            if catcher then
                check(child:GetFrameLevel() > catcher:GetFrameLevel(), label .. ": a control (level "
                    .. child:GetFrameLevel() .. ") isn't above the catcher (level " .. catcher:GetFrameLevel() .. ")")
            end
            local text = child.GetText and child:GetText()
            local what = (type(text) == "string" and text ~= "" and text)
                or (child.label and child.label:GetText()) or child:GetObjectType()
            Inside(child, what)
            if child.label and child.label:IsShown() then Inside(child.label, what .. " (label)") end
        end
    end
    for _, region in ipairs({ list:GetRegions() }) do
        if region:IsShown() and region.GetText and region:GetText() then Inside(region, region:GetText()) end
    end
end

-- The open who-gets list on content, or nil.
local function OpenList(content)
    for _, child in ipairs({ content:GetChildren() }) do
        if child:GetObjectType() == "Frame" and child:IsShown() and child:GetFrameStrata() == "DIALOG" then
            return child
        end
    end
end

-- The first who-gets button (200 wide) shown on content, or nil. Not a
-- "Show friendly player names" button (also 200 wide), should one show.
local function FirstWho(content)
    local found
    for _, child in ipairs({ content:GetChildren() }) do
        if child:IsShown() and child:GetObjectType() == "Button" and child:GetWidth() == 200
            and child:GetText() ~= "Show friendly player names"
            and (not found or (Measure(child, "GetTop") or 0) > (Measure(found, "GetTop") or 0)) then
            found = child
        end
    end
    return found
end

-- Scrolls the panel so frame sits near the top or the bottom of its view,
-- by moving the scroll child (uitests/pages.lua's ShowFrameAt says why).
local function ShowRowAt(content, frame, at)
    return FriendlyForeverUIPages.ShowFrameAt(content, frame, at)
end

test("the Buffs tab stays inside its page at its tallest, at every place, names and list open (#408)", function()
    local Pages = FriendlyForeverUIPages
    local saved = FriendlyForeverDB and FriendlyForeverDB.buffBack
    check(type(saved) == "table", "no saved Buff Back settings")
    local had = DeepCopy(saved)
    local knewKings = IsSpellKnown(KINGS)
    local ok, err = pcall(function()
        if not knewKings then
            A_Admin.LearnSpell(KINGS)
            A_Admin.FireEvent("SPELLS_CHANGED")
        end
        saved.whoChoice = "new"
        local listsOpened = 0
        for _, place in ipairs(Pages.BUFFS_PLACES) do
            local content = Pages.OpenBuffs(place.name)
            check(content ~= nil, "couldn't open the Buffs tab at " .. place.label)
            local name = "Buffs tab, " .. place.label
            -- The first buff's names (not for strangers), then its list.
            for _, child in ipairs({ content:GetChildren() }) do
                local text = child.GetText and child:GetText() or ""
                if child:IsShown() and text:find("Names (", 1, true) == 1 then
                    child:GetScript("OnClick")(child)
                    break
                end
            end
            Settle(content)
            CheckAll({
                function() TabTextInside(content, name) end,
                function() PushedDownInside(content, name) end,
            })
            if place.name == "raid" then
                local raid
                for _, region in ipairs({ content:GetRegions() }) do
                    local text = region.GetText and region:GetText()
                    if text and region:IsShown() and text:find("Blessings I give in this raid:", 1, true) == 1 then
                        raid = region
                    end
                end
                check(raid ~= nil, "the raid Blessings rows aren't shown on the Raid place")
            end
            -- The first buff's who-gets list, opened as a player would: its
            -- row scrolled near the top of the view, then near the bottom,
            -- where the list opens above it. On screen, holding all it
            -- lists, inside the options.
            local who = FirstWho(content)
            check(who ~= nil, "no who-gets button at " .. place.label)
            for _, at in ipairs({ "top", "bottom" }) do
                local offset, putBack = ShowRowAt(content, who, at)
                local label = ("%s who-gets list (row near the %s of the view)"):format(name, at)
                if not offset then
                    report("LAYOUT " .. label .. ": edges can't be read here")
                else
                    local done, failed = pcall(function()
                        report(("LAYOUT %s: the panel scrolled by %.0f"):format(label, offset))
                        -- Asked again (the shots ask again a frame later), it
                        -- stays put: the offset is worked out from the content's
                        -- own top, not from where the row now sits.
                        local again = FriendlyForeverUIPages.ShowFrameAt(content, who, at)
                        check(again ~= nil and math.abs(again - offset) <= 1,
                            ("%s: asked again, the panel scrolled by %s, not %.0f"):format(label,
                                tostring(again), offset))
                        -- Closed and opened again: the list is placed as it opens.
                        if OpenList(content) then who:GetScript("OnClick")(who) end
                        who:GetScript("OnClick")(who)
                        local list = OpenList(content)
                        check(list ~= nil, label .. ": didn't open")
                        OnScreen(list, label)
                        ListHoldsAll(list, label)
                        EndsInside(content, list, label)
                        who:GetScript("OnClick")(who)
                        listsOpened = listsOpened + 1
                    end)
                    putBack()
                    if not done then error(failed, 0) end
                end
            end
        end
        -- Every place opened its list twice: none was skipped unread.
        report(("LAYOUT Buffs tab: %d who-gets lists opened"):format(listsOpened))
        check(listsOpened == 2 * #Pages.BUFFS_PLACES, ("only %d of %d who-gets lists opened"):format(listsOpened,
            2 * #Pages.BUFFS_PLACES))
    end)
    -- The saved settings as they were.
    for k in pairs(saved) do saved[k] = nil end
    for k, v in pairs(had) do saved[k] = v end
    if not knewKings then
        A_Admin.UnlearnSpell(KINGS)
        A_Admin.FireEvent("SPELLS_CHANGED")
    end
    OpenTab(FriendlyForeverUIPages.TABS[1].label)
    if not ok then error(err, 0) end
end)

-- The raid Blessings header and boxes on the Raid place (#444, #439): a
-- paladin who knows Kings, Wisdom and Might, out of a raid, in one with
-- Might unticked, and with the game's raid answer unreadable. The header
-- text and the boxes' state are checked, and the header stays inside the
-- panel's view (its text 55 px longer since #439). The saved settings, the
-- spells and the globals are put back, even when a check fails.
test("the Raid Blessings header and boxes read right and stay inside the page, in every raid state (#444)", function()
    local Pages = FriendlyForeverUIPages
    local saved = FriendlyForeverDB and FriendlyForeverDB.buffBack
    check(type(saved) == "table", "no saved Buff Back settings")
    local had = DeepCopy(saved)
    local ok, err = pcall(function()
        saved.whoChoice = "new"
        local wanted = {
            out = "(join a raid to choose)",
            ["in"] = "(until you leave it)",
            unreadable = "(can't tell if you're in a raid)",
        }
        for _, state in ipairs({ "out", "in", "unreadable" }) do
            local realRaid, realUnit = IsInRaid, UnitIsUnit
            local knew = {}
            for _, id in ipairs(Pages.RAID_BLESSING_SPELLS) do knew[id] = IsSpellKnown(id) end
            local content, putBack = Pages.ShowRaidBlessings(state)
            check(content ~= nil, "couldn't show the raid Blessings, " .. state .. ": " .. tostring(putBack))
            local done, failed = pcall(function()
                Settle(content)
                local name = "Raid Blessings, " .. state
                local header
                for _, region in ipairs({ content:GetRegions() }) do
                    local text = region.GetText and region:GetText()
                    if text and region:IsShown() and text:find("Blessings I give in this raid:", 1, true) == 1 then
                        header = region
                    end
                end
                check(header ~= nil, name .. ": the header isn't shown")
                check(header:GetText():find(wanted[state], 1, true) ~= nil,
                    name .. ": the header says '" .. tostring(header:GetText()) .. "', not " .. wanted[state])
                local boxes = {}
                for _, child in ipairs({ content:GetChildren() }) do
                    if child.key and child:IsShown() and child.label then boxes[child.key] = child end
                end
                for _, key in ipairs({ "kings", "wisdom", "might" }) do
                    check(boxes[key] ~= nil, name .. ": no box for " .. key)
                end
                if state ~= "out" then
                    -- Might unticked, the others kept; greyed when the answer can't be read.
                    check(boxes.might:GetChecked() == false, name .. ": Might should be unticked")
                    check(boxes.kings:GetChecked() == true and boxes.wisdom:GetChecked() == true,
                        name .. ": Kings and Wisdom should be ticked")
                    check(boxes.kings:IsEnabled() == (state == "in"), name .. ": the boxes' enabled state is wrong")
                end
                local left, right = Edges(header, "GetLeft", "GetRight")
                local viewLeft, viewRight = Edges(content:GetParent(), "GetLeft", "GetRight")
                if left and viewLeft then
                    local line = ("LAYOUT %s: header %.0f..%.0f, view %.0f..%.0f"):format(name, left, right,
                        viewLeft, viewRight)
                    report(line)
                    check(left >= viewLeft - 1 and right <= viewRight + 1, line .. ": the header leaves the view")
                else
                    report("LAYOUT " .. name .. ": edges can't be read here")
                end
                CheckAll({
                    function() TabTextInside(content, name) end,
                    function() PushedDownInside(content, name) end,
                })
            end)
            putBack()
            -- Everything it changed is back (the criterion of #444, asserted).
            check(IsInRaid == realRaid, state .. ": IsInRaid isn't put back")
            check(UnitIsUnit == realUnit, state .. ": UnitIsUnit isn't put back")
            for _, id in ipairs(Pages.RAID_BLESSING_SPELLS) do
                check(IsSpellKnown(id) == knew[id], ("%s: spell %d isn't as it was"):format(state, id))
            end
            if not done then error(failed, 0) end
        end
    end)
    for k in pairs(saved) do saved[k] = nil end
    for k, v in pairs(had) do saved[k] = v end
    OpenTab(FriendlyForeverUIPages.TABS[1].label)
    if not ok then error(err, 0) end
end)

-- The passers-by switch on the Favours tab (#491), in the tab's first view,
-- unscrolled, at every size the layout passes run (#493): the tab's rows
-- don't depend on the class, so this holds for every class. With friendly
-- nameplates on and off: the warning shows below the switch, never above it.
-- Then each of the tab's lines' sub-tabs ends at its last row (#482).
local PASSERS_LABEL = "Also offer my buffs to passers-by in buff mode"

-- The Favours tab's check box whose label is text, or nil.
local function FavoursBox(content, text)
    for _, child in ipairs({ content:GetChildren() }) do
        if child.label and child.label.GetText and child.label:GetText() == text then return child end
    end
end

test("the Favours tab's passers-by switch is in its first view, unscrolled, nameplates on, off (#491, #493)",
function()
    local Pages = FriendlyForeverUIPages
    local had = GetCVar and GetCVar("nameplateShowFriendlyPlayers")
    local ok, err = pcall(function()
        for _, nameplates in ipairs({ "1", "0" }) do
            if SetCVar then pcall(SetCVar, "nameplateShowFriendlyPlayers", nameplates) end
            local content = Pages.OpenTab("favours")
            check(content ~= nil, "couldn't open the Favours tab")
            local scroll = content:GetParent()
            scroll:SetVerticalScroll(0)
            Settle(content)
            local name = "Favours tab, passers-by switch, nameplates " .. nameplates
            local box = FavoursBox(content, PASSERS_LABEL)
            check(box ~= nil and box:IsVisible(), name .. ": the switch isn't shown")
            local offset = Measure(scroll, "GetVerticalScroll") or 0
            local top, bottom = Edges(box, "GetTop", "GetBottom")
            local viewTop, viewBottom = Edges(scroll, "GetTop", "GetBottom")
            local contentTop = Edges(content, "GetTop", "GetBottom")
            if not (top and viewTop and contentTop) then
                report("LAYOUT " .. name .. ": edges can't be read here")
                check(false, name .. ": edges can't be read here")
            end
            local line = ("LAYOUT %s: unscrolled (offset %.0f), switch %.0f..%.0f below the top, view %.0f high")
                :format(name, offset, contentTop - top, contentTop - bottom, viewTop - viewBottom)
            report(line)
            check(offset <= 1, line .. ": the tab didn't open unscrolled")
            check(top <= viewTop + 1 and bottom >= viewBottom - 1, line .. ": the switch is below the first view")
            check(ShowsText(content, "Players nearby who aren't in your group"), name .. ": its help line isn't shown")
            CheckAll({
                function() TabTextInside(content, name) end,
                function() PushedDownInside(content, name) end,
            })
        end
    end)
    if SetCVar and had then pcall(SetCVar, "nameplateShowFriendlyPlayers", had) end
    OpenTab(FriendlyForeverUIPages.TABS[1].label)
    if not ok then error(err, 0) end
end)

test("each of the Favours tab's lines ends at its last row, with its 30 lines in order (#482, #491)", function()
    local Pages = FriendlyForeverUIPages
    local failures = {}
    for _, lines in ipairs(Pages.FAVOURS_LINES) do
        local ok, e = pcall(function()
            local content, button = Pages.OpenFavoursLines(lines.name)
            check(content ~= nil, "couldn't open the Favours tab's " .. lines.label)
            check(not button:IsEnabled(), lines.label .. ": its button isn't the selected one")
            local name = "Favours tab, " .. lines.label
            Settle(content)
            RowsInOrder(content, name, "Preview random")
            CheckAll({
                function() TabTextInside(content, name) end,
                function() PushedDownInside(content, name) end,
            })
        end)
        if not ok then failures[#failures + 1] = tostring(e) end
    end
    Pages.OpenFavoursLines(Pages.FAVOURS_LINES[1].name)
    OpenTab(FriendlyForeverUIPages.TABS[1].label)
    check(#failures == 0, table.concat(failures, "\n"))
end)

-- Start here's buff mode lines and its link to the switch (#455, #458).
test("the Start here page shows how to turn buff mode on and links to the passers-by switch (#455, #458)", function()
    local page = FriendlyForeverUIPages.Open("start")
    check(page:IsVisible(), "the Start here page didn't open")
    check(ShowsText(page.content, "shift-click the minimap button"), "Start here doesn't mention shift-click")
    local link
    for _, child in ipairs({ page.content:GetChildren() }) do
        if child.GetText and child:GetText() == "Passers-by switch (Favours tab)" then link = child end
    end
    check(link ~= nil and link:IsVisible(), "Start here has no passers-by link")
    OnScreen(link, "Start here passers-by link")
    link:GetScript("OnClick")(link)
    local panel = _G.FriendlyForeverOptionsPanel
    local shown = false
    for _, child in ipairs({ panel:GetChildren() }) do
        local content = child.GetScrollChild and child:GetScrollChild()
        if content then
            for _, c in ipairs({ content:GetChildren() }) do
                if c.label and c.label.GetText and c.label:GetText() == PASSERS_LABEL and c:IsVisible() then
                    shown = true
                end
            end
        end
    end
    check(shown, "the link didn't open the Favours tab at the passers-by switch")
    OpenTab(FriendlyForeverUIPages.TABS[1].label)
end)

-- The minimap button's tooltip: the shift-click line, apart from right-click's.
test("the minimap button's tooltip has the shift-click buff mode line, apart from right-click's (#458)", function()
    local button = _G.FriendlyForeverMinimapButton
    check(button ~= nil, "no minimap button")
    button:GetScript("OnEnter")(button)
    local shift, right
    local read = pcall(function()
        for i = 1, GameTooltip:NumLines() do
            local line = _G["GameTooltipTextLeft" .. i]
            local text = line and line:GetText() or ""
            if text:find("Shift-click:", 1, true) then shift = text end
            if text:find("Right-click:", 1, true) then right = text end
        end
    end)
    GameTooltip:Hide()
    if not read then return report("LAYOUT minimap tooltip: its lines can't be read here") end
    check(shift ~= nil and shift:find("buff mode on/off", 1, true), "the tooltip has no shift-click buff mode line")
    check(right ~= nil and not right:find("buff mode", 1, true), "right-click's line should stay about the addon")
    report("LAYOUT minimap tooltip: " .. tostring(shift))
end)

-- The Buffs tab's top-up row (#42, #491): its label and stepper on one
-- line inside the options, between buff mode's minutes and the places'
-- tabs, overlapping neither.
local TOP_UP_LABEL = "Top up my buffs with under (minutes left, 0 = never):"

test("the Buffs tab's top-up row stays inside the options, between its neighbours (#42, #491)", function()
    local panel = _G.FriendlyForeverOptionsPanel
    local content = FriendlyForeverUIPages.OpenBuffs()
    local ok, err = pcall(function()
        check(content ~= nil, "couldn't open the Buffs tab")
        Settle(content)
        local above = WithText(content, "or after (minutes, 0 = never):")
        local label = WithText(content, TOP_UP_LABEL)
        local below = WithText(content, "Strangers")
        check(above and label and below, "the top-up row or its neighbours aren't on the Buffs tab")
        -- Inside the scrolling content, which runs below the panel's view
        -- (the per-tab check measures the same way).
        TextInside(content, label, "top-up label", 1)
        -- Its "+": the one on the label's line, right of it.
        local labelTop, labelBottom = Edges(label, "GetTop", "GetBottom")
        local _, labelRight = Edges(label, "GetLeft", "GetRight")
        local plus
        for _, child in ipairs({ content:GetChildren() }) do
            if child:IsVisible() and child.GetText and child:GetText() == "+" then
                local top, bottom = Edges(child, "GetTop", "GetBottom")
                local left = Edges(child, "GetLeft", "GetRight")
                if top and labelTop and left and labelRight and left > labelRight
                    and math.abs((top + bottom) / 2 - (labelTop + labelBottom) / 2) < 12 then plus = child end
            end
        end
        check(plus ~= nil, "the top-up row's + button isn't beside its label")
        EndsInside(panel, plus, "top-up + button")
        local aboveBottom = select(2, Edges(above, "GetTop", "GetBottom"))
        local belowTop = Edges(below, "GetTop", "GetBottom")
        check(aboveBottom and labelTop and labelBottom and belowTop, "the rows' edges can't be read here")
        local line = ("LAYOUT top-up row: %.0f..%.0f, below buff mode's minutes (bottom %.0f), above the"
            .. " places' tabs (top %.0f)"):format(labelBottom, labelTop, aboveBottom, belowTop)
        report(line)
        check(labelTop <= aboveBottom + 1 and belowTop <= labelBottom + 1, line .. ": out of order or overlapping")
    end)
    OpenTab("Guild Login")
    if not ok then error(err, 0) end
end)

-- The Favours tab's renew row (#269, #491): its label and stepper on one
-- line inside the options, between the capital-city option and the line
-- linking to the Buffs tab, overlapping neither.
local RENEW_LABEL = "Renew my buff when theirs has under (% left, 0 = never):"

test("the Favours tab's renew row stays inside the options, between its neighbours (#269, #491)", function()
    local panel, content = OpenTab("Favours")
    local ok, err = pcall(function()
        Settle(content)
        -- A checkbox's label is the checkbox's own region, not the content's.
        local above
        for _, child in ipairs({ content:GetChildren() }) do
            if child.label and child.label.GetText
                and child.label:GetText() == "Show the button in capital cities (buff mode always shows it)" then
                above = child.label
            end
        end
        local label = WithText(content, RENEW_LABEL)
        local below = WithText(content, "Who gets which buff, the buff order, Never offer and buff mode are on "
            .. "the Buffs tab.")
        check(above and label and below, "the renew row or its neighbours aren't on the Favours tab")
        TextInside(content, label, "renew label", 1)
        -- Its "+": the one on the label's line, right of it.
        local labelTop, labelBottom = Edges(label, "GetTop", "GetBottom")
        local _, labelRight = Edges(label, "GetLeft", "GetRight")
        local plus
        for _, child in ipairs({ content:GetChildren() }) do
            if child:IsVisible() and child.GetText and child:GetText() == "+" then
                local top, bottom = Edges(child, "GetTop", "GetBottom")
                local left = Edges(child, "GetLeft", "GetRight")
                if top and labelTop and left and labelRight and left > labelRight
                    and math.abs((top + bottom) / 2 - (labelTop + labelBottom) / 2) < 12 then plus = child end
            end
        end
        check(plus ~= nil, "the renew row's + button isn't beside its label")
        EndsInside(panel, plus, "renew + button")
        local aboveBottom = select(2, Edges(above, "GetTop", "GetBottom"))
        local belowTop = Edges(below, "GetTop", "GetBottom")
        check(aboveBottom and labelTop and labelBottom and belowTop, "the rows' edges can't be read here")
        local line = ("LAYOUT renew row: %.0f..%.0f, below the capital-city option (bottom %.0f), above the"
            .. " Buffs tab's link (top %.0f)"):format(labelBottom, labelTop, aboveBottom, belowTop)
        report(line)
        check(labelTop <= aboveBottom + 1 and belowTop <= labelBottom + 1, line .. ": out of order or overlapping")
    end)
    OpenTab("Guild Login")
    if not ok then error(err, 0) end
end)

-- Names the panel doesn't have, of every type the screenshot job or a
-- typo could give: each is answered with a message, and the tab stays put.
local BAD_TABS = { "", "Favours", "Buff Back", "buffBack", "buff", "buff-back", "general", "nope", 42, true,
    { "favours" } }

test("a tab name the panel doesn't know is answered with a message, not a Lua error", function()
    local Pages = FriendlyForeverUIPages
    local content = Pages.OpenTab("favours")
    check(content ~= nil, "couldn't open the Favours tab")
    local ok, err = pcall(function()
        for i = 0, #BAD_TABS do
            local name = BAD_TABS[i] -- BAD_TABS[0] is nil: no name at all
            local called, opened, why = pcall(Pages.OpenTab, name)
            check(called, "OpenTab(" .. tostring(name) .. ") raised a Lua error: " .. tostring(opened))
            check(opened == nil, "OpenTab(" .. tostring(name) .. ") opened something")
            check(type(why) == "string" and why:find("no options tab called", 1, true) ~= nil,
                "OpenTab(" .. tostring(name) .. ") gave no message")
            check(table.concat(SelectedTabs(content), ", ") == "Favours",
                "OpenTab(" .. tostring(name) .. ") changed the tab")
        end
    end)
    Pages.OpenTab(Pages.TABS[1].name)
    if not ok then error(err, 0) end
end)

-- Start here and the walkthrough (#47). The page's lines are on its
-- scrolling content, as the General page's are. The walkthrough is taken
-- again from the page's button, as a player would, up to each step the
-- screenshots show: its own text stays inside it, and the row a step
-- scrolls the panel to is in view, above the walkthrough's window.

test("the Start here page keeps its text inside it, its checkbox and buttons too (#47)", function()
    local page = FriendlyForeverUIPages.Open("start")
    check(page:IsVisible(), "the Start here page didn't open")
    check(ShowsText(page.content, "What it does"), "the Start here page shows nothing")
    OnScreen(page, "Start here page")
    CheckAll({
        function() TabTextInside(page.content, "Start here page") end,
        function() PushedDownInside(page.content, "Start here page") end,
    })
end)

-- Whether a frame lies across inside another, left to right (a scrolling
-- area's content is meant to run past its bottom). Prints a LAYOUT line,
-- fails if it doesn't, and returns the line.
local function AcrossInside(outer, inner, label)
    local ol, orr = Edges(outer, "GetLeft", "GetRight")
    local il, ir = Edges(inner, "GetLeft", "GetRight")
    if not (ol and il) then
        local line = "LAYOUT " .. label .. ": edges can't be read here"
        report(line)
        return line
    end
    local line = ("LAYOUT %s: %.0f..%.0f across, inside %.0f..%.0f"):format(label, il, ir, ol, orr)
    report(line)
    check(il >= ol - 1 and ir <= orr + 1, line .. ": runs out of its frame")
    return line
end

-- Whether row (a region on the main panel's scrolling content) is drawn
-- inside scroll, the panel's scroll frame, near its top (where the
-- walkthrough scrolls a step's row to, so a panel left unscrolled can't
-- pass), and above the walkthrough's window. Prints a LAYOUT line, fails if
-- it isn't, and returns the line.
-- The simulator reads a scroll child's regions where they'd be unscrolled
-- (docs/ui-simulator.md): when the scroll child's top reads as less than the
-- view's top plus the offset, as the game puts it, the difference is added
-- back. In the game it is 0.
local NEAR_TOP = 40
local function RowInView(row, scroll, walkthrough, label)
    local rt, rb = Edges(row, "GetTop", "GetBottom")
    local st, sb = Edges(scroll, "GetTop", "GetBottom")
    local wt = Edges(walkthrough, "GetTop", "GetBottom")
    if not (rt and st and wt) then
        local line = "LAYOUT " .. label .. ": edges can't be read here"
        report(line)
        return line
    end
    -- How far the panel is scrolled, of how far it can be, where the client
    -- says: a failure then shows whether the scroll or its range was missing.
    local offset, range = Measure(scroll, "GetVerticalScroll"), Measure(scroll, "GetVerticalScrollRange")
    local okChild, child = pcall(function() return scroll:GetScrollChild() end)
    local ct = okChild and child and Edges(child, "GetTop", "GetBottom")
    local left = (offset and ct) and math.max(0, st + offset - ct) or 0
    rt, rb = rt + left, rb + left
    local line = ("LAYOUT %s: row %.0f..%.0f, panel's view %.0f..%.0f, walkthrough's top %.0f"):format(
        label, rb, rt, sb, st, wt)
    if offset and range then line = line .. (", scrolled %.0f of %.0f"):format(offset, range) end
    if left > 1 then line = line .. (" (%.0f of it added back: the client read the row unscrolled)"):format(left) end
    report(line)
    check(rt <= st + 1 and rb >= sb - 1, line .. ": the row is scrolled out of view")
    check(rt >= st - NEAR_TOP, line .. ": the row isn't scrolled to the top of the view")
    check(rb >= wt - 1, line .. ": the row is under the walkthrough")
    return line
end

-- The row each step scrolls to, by the start of its text, for the steps
-- that scroll.
local STEP_ROWS = { ["buff-mode-triggers"] = "Buff mode turns on by itself" }

-- A What's new step (#169, #362) is taken as a returning player logging in,
-- which starts the login grace again (Announcer.lua): it's waited out after,
-- as the button scenarios do, so nothing after this test is held by it.
test("each walkthrough step shown keeps its text inside it, on the screen, its row in view (#47, #362)", function()
    local Pages = FriendlyForeverUIPages
    local failures = {}
    local loggedIn = false
    for _, step in ipairs(Pages.WALKTHROUGH_STEPS) do
        local ok, err = pcall(function()
            local label = "walkthrough (" .. step.name .. ")"
            loggedIn = loggedIn or step.whatsNew == true
            local walkthrough = Pages.OpenWalkthrough(step.name)
            check(walkthrough ~= nil, label .. ": didn't get there")
            if step.whatsNew then
                local title = walkthrough.title:GetText() or ""
                check(title == "What's new: " .. step.title, ("%s: titled %q, not as What's new"):format(label, title))
            end
            OnScreen(walkthrough, label)
            CheckAll({
                function() FrameTextInside(walkthrough, label, 1) end,
                function() TextInside(walkthrough.body, walkthrough.stepText, label .. " text", nil, nil, true) end,
                function() AcrossInside(walkthrough.scroll, walkthrough.body, label .. " text area") end,
            })
            if step.choice then
                -- The keep-or-reset choice (#408): both buttons shown, across
                -- inside the window, in their row between the text and the
                -- window's own buttons (measured against Next, which every
                -- step shows; Skip is hidden on a run's last step).
                check(walkthrough.keep:IsShown() and walkthrough.new:IsShown(), label .. ": the choice isn't offered")
                CheckAll({
                    function() AcrossInside(walkthrough, walkthrough.keep, label .. " Keep my settings") end,
                    function() AcrossInside(walkthrough, walkthrough.new, label .. " Use the new defaults") end,
                    function()
                        local _, sb = Edges(walkthrough.scroll, "GetTop", "GetBottom")
                        local kt, kb = Edges(walkthrough.keep, "GetTop", "GetBottom")
                        local st = Edges(walkthrough.next, "GetTop", "GetBottom")
                        if not (sb and kt and st) then
                            report("LAYOUT " .. label .. " choice row: edges can't be read here")
                            return
                        end
                        local line = ("LAYOUT %s choice row: %.0f..%.0f, text area's bottom %.0f, Next's top %.0f")
                            :format(label, kb, kt, sb, st)
                        report(line)
                        check(kt <= sb + 1 and kb >= st - 1, line .. ": overlaps the text or the buttons")
                    end,
                })
            end
            local row = STEP_ROWS[step.name]
            if row then
                -- The panel scrolls again a frame later, once laid out. A
                -- frame may not pass here (the simulator's clock can be
                -- stopped), so once it has had the chance, the step is taken
                -- again, as a player clicking Back and Next would: its
                -- scroll then runs against a panel already laid out.
                if type(A_Admin) == "table" and A_Admin.AdvanceTime then pcall(A_Admin.AdvanceTime, 0.1) end
                local scroll, content, found
                for _, child in ipairs({ _G[Pages.PANEL]:GetChildren() }) do
                    if not content and child.GetScrollChild and child:GetScrollChild() then
                        scroll, content = child, child:GetScrollChild()
                    end
                end
                check(content ~= nil, label .. ": the options panel has no scrolling content")
                -- Buff mode's rows sit about 22 links down the Buffs tab's
                -- chain (#491), past the 16 the simulator lays out again: lay
                -- it out first, so the step's scroll reads the row where it is,
                -- as the game would (docs/ui-simulator.md).
                Settle(content)
                walkthrough.back:Click()
                walkthrough.next:Click()
                -- The row hangs deep below the buff rows: lay the chain out
                -- again, or its place is the one from before the scroll
                -- (docs/ui-simulator.md).
                Settle(content)
                for _, region in ipairs({ content:GetRegions() }) do
                    if region:IsVisible() and (region:GetText() or ""):find(row, 1, true) == 1 then found = region end
                end
                check(found ~= nil, label .. ": no row \"" .. row .. "\"")
                RowInView(found, scroll, walkthrough, label .. " row \"" .. row .. "\"")
            end
        end)
        if not ok then failures[#failures + 1] = tostring(err) end
    end
    Pages.SkipWalkthrough()
    Pages.PutBackChoice()
    local States = FriendlyForeverUIStates
    if loggedIn and type(States) == "table" then States.Advance(States.LOGIN_GRACE_SECONDS) end
    check(#failures == 0, table.concat(failures, "\n"))
end)

-- The layout checks, for spec/uitests_layout_spec.lua, which runs them
-- against regions whose edges it sets itself, and the Buff Thanks tab's
-- choices, which spec/thankwith_spec.lua checks against the options. The
-- simulator ignores what a test file returns.
-- The actions the client blocked or forbade during the whole run (#160),
-- one FACT line each with how often, or one line saying none. A line naming
-- FriendlyForever is the addon's own call being refused, which a player
-- would see in game: read it.
test("reports the actions the client blocked while the scenarios ran", function()
    if #blockedOrder == 0 then report("FACT sim blocked actions: none") end
    for _, what in ipairs(blockedOrder) do
        report(("FACT sim blocked action: %s (%d time(s))"):format(what, blockedActions[what]))
    end
    -- The chat line's other source, which fires no event (pages.lua).
    if #blockedMessage == 0 then
        report("FACT sim the blocked-action chat line: not printed by the client's own function")
    end
    for i, line in ipairs(blockedMessage) do
        report(("FACT sim the blocked-action chat line, caller %d: %s"):format(i, line))
    end
    assertTrue(true)
end)

return { TextInside = TextInside, PushedDownInside = PushedDownInside, TabTextInside = TabTextInside,
    ScrollFits = ScrollFits, IsScrolled = IsScrolled, OnScreen = OnScreen, Settle = Settle,
    RowsInOrder = RowsInOrder, AcrossInside = AcrossInside,
    RowInView = RowInView, THANK_WITH = THANK_WITH, CANT_REACH = CANT_REACH }
