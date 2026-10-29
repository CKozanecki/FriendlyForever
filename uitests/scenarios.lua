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
-- text ends where its width says. One pinned on its right too stops at that
-- edge (GetStringWidth still reports the whole width): cut short there, or
-- wrapped onto more lines when wraps says so.
local function DrawnAcross(region, left, right, wraps)
    local width = Measure(region, "GetStringWidth")
    if not width then return left, right, "" end
    if not AnchoredOn(region, "RIGHT") then return left, math.max(right, left + width), "" end
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
    -- The lines the client counts, and the lines the game would wrap onto if
    -- that is more than one and more than the client counts.
    local count = Measure(region, "GetNumLines")
    local wrapped = WrappedLines(region, tl, tr)
    if wrapped and wrapped <= 1 then wrapped = nil end
    local textLeft, textRight, cut = DrawnAcross(region, tl, tr, wrapped or (count and count > 1))
    if wrapped and wrapped <= (count or 0) then wrapped = nil end
    local inside = textLeft >= fl - 1 and textRight <= fr + 1
    local line = ("LAYOUT %s: text %.0f..%.0f, frame %.0f..%.0f%s"):format(label, textLeft, textRight, fl, fr, cut)

    local ft, fb = Edges(frame, "GetTop", "GetBottom")
    local tt, tb = Edges(region, "GetTop", "GetBottom")
    if ft and tt then
        local textTop, textBottom = DrawnUpDown(region, tt, tb, wrapped and wrapped / math.max(count or 1, 1) or 1)
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

test("the General page's chat limit row stays inside it (#35)", function()
    local page = OpenGeneralPage()
    local w = page.widgets
    TextInside(page, w.linesPerMinute.label, "chat limit label", 1)
    TextInside(page, w.linesPerMinute.plus, "chat limit + button")
    TextInside(page, w.capHelp, "chat limit help")
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

-- The last argument to TextInside, 1: each button line stays on one line.
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
        TextInside(button, button.subtitle, "favour hint", 1)
        OnScreen(button, "buff-back button (favour)")
    end)
end)

test("in buff mode, a party member missing your buff is offered it, and the text stays inside", function()
    InState("buff mode", FriendlyForeverUIStates.GroupMissing, function(button, States)
        Expect((button.mode:GetText() or ""):find("Buff mode:", 1, true) ~= nil, "buff mode isn't on")
        Expect(button:IsShown(), "the button isn't up")
        Expect(button.title:GetText() == States.GROUPMATE, "the title doesn't name " .. States.GROUPMATE)
        Expect(button.subtitle:GetText() == "missing your " .. States.SPELL.name,
            "the hint doesn't offer " .. States.SPELL.name)
        Expect(States.MacroTarget() == States.GROUPMATE, "the macro doesn't target " .. States.GROUPMATE)
        TextInside(button, button.title, "buff mode title", 1)
        TextInside(button, button.subtitle, "buff mode hint", 1)
        OnScreen(button, "buff-back button (buff mode)")
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
local function PushedDownInside(frame, label)
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
    if not lowest then return end
    local line = ("LAYOUT %s pushed down by wrapped text: lowest \"%s\" ends at %.0f, frame bottom %.0f"):format(
        label, Short(lowestName), lowest, fb)
    report(line)
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
        -- The checks below mean nothing on a page still showing the default
        -- lists, so first make sure it shows the fill.
        check(ShowsText(page, "Aerendhiliel Stormwhisper") and ShowsText(page, "Raid nights in Naxxramas"),
            "the General page doesn't show the filled ignore list and profiles")
        OnScreen(page, "General page")
        CheckAll({
            function() FrameTextInside(page, "General page") end,
            function() PushedDownInside(page, "General page") end,
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

-- The page doesn't scroll, so with the lists as a new player has them its
-- last line must still be on it once every note has wrapped as it does in
-- the game (#35). The filled page above is the worst case (#52).
test("the General page's last line is still on the page (#35)", function()
    local page = OpenGeneralPage()
    check(page:IsVisible(), "the General page didn't open")
    PushedDownInside(page, "General page (as a new player has it)")
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

-- The layout checks, for spec/uitests_layout_spec.lua, which runs them
-- against regions whose edges it sets itself. The simulator ignores what a
-- test file returns.
return { TextInside = TextInside, PushedDownInside = PushedDownInside }
