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

local function InState(state, fn)
    local States = FriendlyForeverUIStates
    check(type(States) == "table", "button_states.lua didn't load before this file")
    local failures, others = States.Watch(function()
        state.Set()
        fn(States.Button(), States)
    end)
    local undoFailures, undoOthers = States.Watch(state.Undo)
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
    check(ok, what .. "\n  the button: " .. ButtonStatus())
end

-- The button is empty: it isn't up, and a press would cast nothing.
local function ExpectEmpty(States, when)
    Expect(States.Macro() == nil, when .. ": the button holds a macro")
    Expect(not States.Button():IsShown(), when .. ": the button is up")
end

test("with a favour owed, the button names the player and the buff, and its text stays inside it", function()
    InState(FriendlyForeverUIStates.Favour, function(button, States)
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
    InState(FriendlyForeverUIStates.GroupMissing, function(button, States)
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

-- Units no favour can come from: none, empty, a token that shows no one,
-- the target when there's no target, a party slot when not in a party, and
-- values that aren't unit tokens at all.
local BAD_SOURCES = { "", "nameplate77", "target", "party3", "player", 42, true, { "target" } }

test("a buff naming an unknown or empty unit leaves the button empty, with no Lua error", function()
    local States = FriendlyForeverUIStates
    local stranger = "Cael Morrow"
    local learned = { Set = function() States.PassLoginGrace(); States.Learn() end,
        Undo = States.FavourFrom(stranger).Undo }
    InState(learned, function()
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
    InState(FriendlyForeverUIStates.FavourFrom(stranger), function(button, States)
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
            function() States.Party(States.GROUPMATE) end,
            function() States.Party(nil) end,
            function() States.Advance(roll(4) - 1) end,
        }
        local allowed = { [stranger] = true, [States.GROUPMATE] = true }
        for step = 1, 60 do
            local which = roll(#steps)
            steps[which]()
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
