-- Spec: #64
-- Layout: the buff-back button's text stays inside the button, and on each
-- options tab the message list follows the last row that tab shows. The
-- checks work from the simulated client's own anchors and text widths
-- (spec/support/wow.lua), not from the addon's layout code.
local wow = require("spec.support.wow")

local MOTW, MOTW_1 = 9885, 1126
local FORTITUDE, FORTITUDE_1 = 10938, 1243
local KINGS, MIGHT_1, WISDOM_1, SALVATION = 20217, 19740, 19742, 1038

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
            assertInside(button, button.subtitle, "the favour")
        end)

        it("keeps a long favour inside it, cut off with …: missing your Power Word: Fortitude", function()
            boot("PRIEST", { [FORTITUDE_1] = true, [FORTITUDE] = true })
            slash("buffmode on")
            wow.setGroup("party", { "Ann-Vale" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            assert.are.equal("missing your Power Word: Fortitude", button.subtitle:GetText())
            assertInside(button, button.title, "the name")
            local favour = assertInside(button, button.subtitle, "the favour")
            -- Too long for the pessimistic font: the game cuts it off.
            assert.are.equal("…", favour.text:sub(-#"…"))
        end)

        it("keeps text damaged into a very long string inside it, on one line", function()
            boot("DRUID", { [MOTW_1] = true, [MOTW] = true })
            slash("move")
            local long = string.rep("Wolfgangamadeus", 40)
            button.title:SetText(long)
            button.subtitle:SetText("|cffff0000" .. string.rep("Ünïcödé ", 60) .. "|r")
            local title = assertInside(button, button.title, "the title")
            local hint = assertInside(button, button.subtitle, "the hint")
            assert.are.equal("…", title.text:sub(-#"…"))
            assert.are.equal("…", hint.text:sub(-#"…"))
        end)

        it("shows a reason too long for the button in full in its tooltip", function()
            boot("PRIEST", { [FORTITUDE_1] = true, [FORTITUDE] = true })
            slash("buffmode on")
            -- A member whose buffs the game won't show (a secret).
            wow.setGroup("party", { "Ann-Vale" })
            wow.state.units.party1.secrets = { auras = true }
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            local reason = button.subtitle:GetText()
            local drawn = assertInside(button, button.subtitle, "the reason")
            assert.are.equal("…", drawn.text:sub(-#"…"), "the reason is too long for the button: '" .. reason .. "'")
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
            assertInside(button, button.subtitle, "the favour")
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

        it("follows the last row each tab shows for a paladin, through each Who rule and Revoke choice", function()
            wow.SPELL_NAMES[SALVATION] = "Blessing of Salvation"
            finally(function() wow.SPELL_NAMES[SALVATION] = nil end)
            ns = wow.boot({ before = function(state)
                state.class = "PALADIN"
                state.knownSpells = { [KINGS] = true, [WISDOM_1] = true, [MIGHT_1] = true, [SALVATION] = true }
            end })
            w = ns.Options.widgets
            ns.db.buffBack.buffOrder = { "kings", "might", "wisdom", "salvation" }
            eachTab("paladin")
            wow.run(w.tabs.buffBack, "OnClick")
            for i = 1, #ns.BuffRules.REVOKE_MODES + 1 do
                for row = 1, 4 do
                    for _ = 1, 4 do
                        wow.run(w.buffRows[row].who, "OnClick")
                        checkTab(("paladin, revoke %d, row %d"):format(i, row))
                    end
                end
                ns.Options.CycleRevoke()
                checkTab("paladin, revoke cycled " .. i)
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
