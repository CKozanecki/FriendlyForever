-- Spec: #52, #64, #112, #197, #208, #41, #209, #270
-- Layout: the buff-back button's text stays inside the button, and on each
-- options tab the message list follows the last row that tab shows. The
-- checks work from the simulated client's own anchors and text widths
-- (spec/support/wow.lua), not from the addon's layout code.
local wow = require("spec.support.wow")

local MOTW, MOTW_1 = 9885, 1126
local FORTITUDE, FORTITUDE_1 = 10938, 1243
local KINGS, MIGHT_1, WISDOM_1 = 20217, 19740, 19742

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

-- Whether a text line on the button draws inside it, on one line. Returns
-- what it draws, and why not if it spills.
local function insideButton(button, fs)
    local drawn = wow.drawnText(fs, button)
    if drawn.lines ~= 1 then return false, drawn, "wraps onto " .. drawn.lines .. " lines" end
    if drawn.left < 0 or drawn.right > button:GetWidth() then
        return false, drawn, ("draws from %d to %d, outside 0 to %d"):format(drawn.left, drawn.right, button:GetWidth())
    end
    return true, drawn
end

local function assertInside(button, fs, label)
    local ok, drawn, why = insideButton(button, fs)
    assert.is_true(ok, label .. " '" .. drawn.text:sub(1, 60) .. "' " .. tostring(why))
    return drawn
end

-- The button's second line (#270): its whole text, never cut short, on as
-- many lines as it wraps onto, all inside the button. Worked out from the
-- simulated client's own anchors, text widths and line heights.
local function assertWhole(button, fs, label)
    local drawn = wow.drawnText(fs, button)
    local plain = (fs:GetText() or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local shown = label .. " '" .. plain:sub(1, 60) .. "'"
    assert.are.equal(plain, drawn.text, shown .. " is cut short")
    assert.is_true(drawn.left >= 0 and drawn.right <= button:GetWidth(), shown .. " spills across")
    local point, relativeTo, relativePoint, _, y = fs:GetPoint(1)
    assert.are.equal(button, relativeTo, "the line hangs from the button")
    assert.truthy(point:find("TOP", 1, true) and relativePoint:find("TOP", 1, true), "the line hangs from the top")
    local bottom = -y + drawn.lines * wow.LINE_HEIGHT[fs.font]
    assert.is_true(bottom <= button:GetHeight(), ("%s: %d lines reach %d below the top, the button is %d tall")
        :format(shown, drawn.lines, bottom, button:GetHeight()))
    return drawn
end

describe("Layout", function()
    describe("the buff-back button", function()
        local ns, button

        local function boot(class, known)
            ns = wow.boot({ before = function(state)
                state.class = class
                state.knownSpells = known
            end })
            button = ns.BuffButton.Frame()
        end

        it("keeps the /friendly move hint inside it, whole, while unlocked", function()
            boot("DRUID", { [MOTW_1] = true, [MOTW] = true })
            slash("move")
            assert.is_true(button:IsShown())
            assertInside(button, button.title, "the title")
            local hint = assertInside(button, button.subtitle, "the hint")
            assert.are.equal(button.subtitle:GetText(), hint.text, "the shortened hint fits without being cut")
            assert.truthy(hint.text:find("/friendly move", 1, true), "it still names the command")
        end)

        it("keeps a favour inside it: buffed you - give Mark of the Wild", function()
            boot("DRUID", { [MOTW_1] = true, [MOTW] = true })
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = 10157 })
            assert.are.equal("buffed you - give Mark of the Wild", button.subtitle:GetText())
            assertInside(button, button.title, "the name")
            assertWhole(button, button.subtitle, "the favour")
        end)

        it("wraps a long favour whole inside it, never cut short: missing your Power Word: Fortitude", function()
            boot("PRIEST", { [FORTITUDE_1] = true, [FORTITUDE] = true })
            slash("buffmode on")
            wow.setGroup("party", { "Ann-Vale" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            assert.are.equal("missing your Power Word: Fortitude", button.subtitle:GetText())
            assertInside(button, button.title, "the name")
            local favour = assertWhole(button, button.subtitle, "the favour")
            -- Too long for one line in the pessimistic font: it wraps (#270).
            assert.is_true(favour.lines > 1, "it wraps")
        end)

        it("shows a group cast whole: who it reaches on the title, the spell on the subtitle (#41)", function()
            local PRAYER_SHADOW, SHADOW_3 = 27683, 10958
            boot("PRIEST", { [SHADOW_3] = true, [PRAYER_SHADOW] = true })
            wow.state.items[wow.ITEM.sacredCandle] = 5
            slash("buffmode on")
            local names = {}
            for i = 1, 40 do names[i] = "Nam" .. string.char(96 + i % 20 + 1) .. string.char(96 + math.floor(i / 20) + 1) .. "-Surname" end
            wow.setGroup("raid", names)
            for i = 1, 40 do wow.state.units["raid" .. i].subgroup = 8 end
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            assert.are.equal("Group 8 (40 missing)", button.title:GetText(), button.subtitle:GetText())
            assert.are.equal("Prayer of Shadow Protection", button.subtitle:GetText())
            for _, fs in ipairs({ button.title, button.subtitle }) do
                local drawn = assertInside(button, fs, "the group cast")
                assert.are.equal(fs:GetText(), drawn.text, "not cut short")
            end
        end)

        it("keeps text damaged into a very long string inside it: the name cut on one line, the rest wrapped", function()
            boot("DRUID", { [MOTW_1] = true, [MOTW] = true })
            slash("move")
            local long = string.rep("Wolfgangamadeus", 40)
            button.title:SetText(long)
            button.subtitle:SetText("|cffff0000" .. string.rep("Ünïcödé ", 60) .. "|r")
            local title = assertInside(button, button.title, "the title")
            assert.are.equal("…", title.text:sub(-#"…"))
            -- The button fits its text whenever it re-arms.
            ns.BuffButton.Refresh()
            button.subtitle:SetText("|cffff0000" .. string.rep("Ünïcödé ", 60) .. "|r")
            button:SetHeight(ns.BuffButton.HeightFor(button.subtitle))
            assertWhole(button, button.subtitle, "the hint")
        end)

        it("shows a reason too long for one line wrapped on the button, and in full in its tooltip", function()
            boot("PRIEST", { [FORTITUDE_1] = true, [FORTITUDE] = true })
            slash("buffmode on")
            -- A member whose buffs the game won't show (a secret).
            wow.setGroup("party", { "Ann-Vale" })
            wow.state.units.party1.secrets = { auras = true }
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            local reason = button.subtitle:GetText()
            local drawn = assertWhole(button, button.subtitle, "the reason")
            assert.is_true(drawn.lines > 1, "the reason is too long for one line: '" .. reason .. "'")
            wow.run(button, "OnEnter")
            assert.truthy(_G.GameTooltip.lines, "the tooltip has lines")
            local found = false
            for _, line in ipairs(_G.GameTooltip.lines) do found = found or line == reason end
            assert.is_true(found, "the tooltip shows '" .. reason .. "' whole")
            -- An empty line on the button adds no blank line to the tooltip.
            button.subtitle:SetText("")
            wow.run(button, "OnEnter")
            for _, line in ipairs(_G.GameTooltip.lines) do assert.are_not.equal("", line) end
        end)

        it("keeps a favour from a player with the longest name a player can have inside it", function()
            boot("DRUID", { [MOTW_1] = true, [MOTW] = true })
            -- 12 letters, and a realm name as long.
            wow.addUnit("nameplate1", { name = "Wolfgangamad", surname = "Wolfgangamad", class = "WARRIOR",
                id = "Wolfgangamad-Wolfgangamad" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = 10157 })
            assert.are.equal("Wolfgangamad Wolfgangamad", button.title:GetText())
            assertInside(button, button.title, "the name")
            assertWhole(button, button.subtitle, "the favour")
        end)
    end)

    describe("the Favour Ledger page", function()
        it("keeps each row on one line, cut with …, so a long one can't push the rows below it off the page", function()
            local ns = wow.boot()
            local entry = ns.Ledger.Received("Aerendhiliel-Stormwhisper", "Power Word: Fortitude")
            ns.Ledger.AddBuff(entry, "Divine Spirit")
            ns.Ledger.AddBuff(entry, "Shadow Protection")
            ns.Ledger.Settle(entry, false, "too many messages waiting")
            ns.Ledger.NoteNotReturned(entry, "the time to return it ran out")
            ns.Options.FillLedger()
            local _, page = ns.Options.Pages()
            page:SetWidth(665) -- as the Settings panel sizes it in the UI simulator (LAYOUT 573..1238)
            local row = ns.Options.widgets.ledger.rows[1]
            local drawn = wow.drawnText(row, page)
            assert.are.equal(1, drawn.lines)
            assert.truthy(drawn.text:find("…", 1, true), "a row longer than the page is cut, not wrapped")
            assert.truthy(row:GetText():find("Shadow Protection", 1, true), "the row still holds the whole line")
        end)
    end)

    describe("the copy window", function()
        -- A line of the small font the hint uses, in pixels: the UI simulator
        -- draws two of them 33 px tall (docs/ui-simulator.md), so 17 is the
        -- pessimistic choice. The game's real height was confirmed in game at launch.
        local SMALL_LINE = 17

        it("keeps its hint to two lines, above the text box, for export, import and the bug report", function()
            local ns = wow.boot()
            for _, command in ipairs({ "export", "import", "report" }) do
                slash(command)
                local window = ns.Window.Frame()
                local drawn = wow.drawnText(window.hint, window)
                assert.is_true(drawn.lines <= 2, command .. ": the hint wraps onto " .. drawn.lines .. " lines")
                local _, _, _, _, hintTop = window.hint:GetPoint(1)
                local _, _, _, _, boxTop = window.scroll:GetPoint(1)
                assert.is_true(boxTop <= hintTop - 2 * SMALL_LINE - 4,
                    ("%s: the text box starts at %d, inside the hint's two lines from %d"):format(command, boxTop, hintTop))
            end
        end)

        it("cuts a hint too long for two lines, rather than running into the text box", function()
            local ns = wow.boot()
            ns.Window.Show({ title = "Test", hint = string.rep("a very long hint ", 40) })
            assert.are.equal(2, wow.drawnText(ns.Window.Frame().hint, ns.Window.Frame()).lines)
        end)
    end)

    -- Each tab's help line, as wide as the game draws it, stays inside the
    -- panel's content: a long one wraps at its right edge rather than
    -- running past it (#112, found by the UI simulator's tab checks).
    describe("the help line on each options tab", function()
        it("stays inside the panel, wrapping when it's long", function()
            local ns = wow.boot()
            local w = ns.Options.widgets
            local width = w.content:GetWidth()
            local wrapped = 0
            for _, msgType in ipairs(ns.Config.TYPES) do
                wow.run(w.tabs[msgType], "OnClick")
                local drawn = wow.drawnText(w.help, w.content)
                assert.is_true(drawn.left >= 0 and drawn.right <= width, ("%s: help draws from %d to %d, outside 0 to %d")
                    :format(msgType, drawn.left, drawn.right, width))
                assert.are.equal(ns.Config.TYPE_INFO[msgType].help, drawn.text, msgType .. ": help is cut")
                if drawn.lines > 1 then wrapped = wrapped + 1 end
            end
            assert.is_true(wrapped > 0, "no tab's help is long enough to wrap: the test checks nothing")
            -- The rows below hang from it, so a wrapped help pushes them down.
            local _, below = w.enabled:GetPoint(1)
            assert.are.equal(w.help, below)
        end)
    end)

    describe("the message list on each options tab", function()
        local ns, w

        -- Whether a region and every parent up to the scrolling content are shown.
        local function shownIn(region, content)
            local f = region
            while f and f ~= content do
                if type(f) ~= "table" or not f.shown then return false end
                f = f.parent
            end
            return f == content
        end

        -- The first hidden region a region hangs from, through any of its
        -- anchors, if any. A hidden region still takes its space, so a row
        -- below one leaves an empty gap.
        local function hiddenAbove(region, content)
            for i = 1, region:GetNumPoints() do
                local _, relativeTo = region:GetPoint(i)
                if type(relativeTo) == "table" and relativeTo ~= content then
                    if not shownIn(relativeTo, content) then return relativeTo end
                    local hidden = hiddenAbove(relativeTo, content)
                    if hidden then return hidden end
                end
            end
        end

        -- Which row a region is on, counted from the top of the content:
        -- a region whose top hangs from another's bottom is one row below
        -- it; one pinned beside another (left, right, top to top) is on its
        -- row; one pinned to the content itself is on row 0.
        local function rowOf(region, content)
            local row = 0
            for i = 1, region:GetNumPoints() do
                local point, relativeTo, relativePoint = region:GetPoint(i)
                if type(relativeTo) == "table" and relativeTo ~= content then
                    local below = point:find("^TOP") and relativePoint:find("^BOTTOM") and 1 or 0
                    row = math.max(row, rowOf(relativeTo, content) + below)
                end
            end
            return row
        end

        -- Whether a region hangs, through any of its anchors, from target.
        local function hangsFrom(region, target)
            for i = 1, region:GetNumPoints() do
                local _, relativeTo = region:GetPoint(i)
                if relativeTo == target then return true end
                if type(relativeTo) == "table" and hangsFrom(relativeTo, target) then return true end
            end
            return false
        end

        local function describeRegion(region)
            return tostring(region.text ~= "" and region.text or (region.label and region.label.text) or region.kind)
        end

        -- Checked on the tab as it is now.
        local function checkTab(label)
            local content = w.content
            local header = w.msgHeader
            assert.is_true(shownIn(header, content), label .. ": the message list is shown")
            for _, f in ipairs(wow.frames) do
                if shownIn(f, content) then
                    local hidden = hiddenAbove(f, content)
                    assert.is_nil(hidden, label .. ": '" .. describeRegion(f) .. "' sits below hidden '"
                        .. describeRegion(hidden or {}) .. "', leaving a gap")
                end
            end
            -- Every other shown row is above the message list: no row but
            -- the list itself (and what hangs from it) is lower than its anchor.
            local _, above = header:GetPoint(1)
            local lastRow = rowOf(above, content)
            assert.are.equal(lastRow + 1, rowOf(header, content), label .. ": the list hangs below its anchor")
            for _, f in ipairs(wow.frames) do
                if f ~= header and shownIn(f, content) and f:GetNumPoints() > 0 and not hangsFrom(f, header) then
                    assert.is_true(rowOf(f, content) <= lastRow, label .. ": '" .. describeRegion(f)
                        .. "' is below the row the message list follows")
                end
            end
        end

        local function eachTab(label)
            for _, msgType in ipairs(ns.Config.TYPES) do
                wow.run(w.tabs[msgType], "OnClick")
                checkTab(label .. ", " .. msgType)
            end
        end

        it("follows the last row each tab shows, with friendly nameplates on or off", function()
            ns = wow.boot()
            w = ns.Options.widgets
            eachTab("nameplates on")
            wow.state.cvars.nameplateShowFriendlyPlayers = "0"
            eachTab("nameplates off")
            wow.run(w.tabs.buff, "OnClick")
            assert.is_true(w.nameplateWarning:IsShown(), "the warning row is shown")
            assert.are.equal(w.nameplateWarning, select(2, w.msgHeader:GetPoint()))
        end)

        it("follows the last row each tab shows for a paladin, through each Who rule", function()
            ns = wow.boot({ before = function(state)
                state.class = "PALADIN"
                state.knownSpells = { [KINGS] = true, [WISDOM_1] = true, [MIGHT_1] = true }
            end })
            w = ns.Options.widgets
            ns.db.buffBack.buffOrder = { "kings", "might", "wisdom" }
            eachTab("paladin")
            wow.run(w.tabs.buffBack, "OnClick")
            for row = 1, 3 do
                for _ = 1, 4 do
                    wow.run(w.buffRows[row].who, "OnClick")
                    checkTab(("paladin, row %d"):format(row))
                end
            end
        end)

        it("follows the last row each tab shows for a class with no buffs to offer", function()
            ns = wow.boot({ before = function(state)
                state.class = "ROGUE"
                state.knownSpells = {}
            end })
            w = ns.Options.widgets
            eachTab("rogue")
        end)
    end)
end)
