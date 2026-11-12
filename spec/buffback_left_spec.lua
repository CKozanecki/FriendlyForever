-- Spec: #270
-- Buff back when the player you owe has left: a favour whose player the game
-- doesn't show, or whom your buff can't reach, doesn't hold the button. The
-- next favour is offered, or the button hides; they're offered again once
-- back within the owed time. The reason the button shows is never cut short.
-- The checks read the simulated client's own state (spec/support/wow.lua).
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1, THORNS_1 = 9885, 1126, 467
local FORTITUDE, FORTITUDE_1 = 10938, 1243
local INTELLECT = 10157

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Buff back when the player you owe has left (#270)", function()
    local ns, button

    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ before = function(state)
            state.class = opts.class or "DRUID"
            state.knownSpells = opts.known or { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
        end })
        ns.db.buff.messages = { "Thanks {name}" }
        button = ns.BuffButton.Frame()
    end

    -- A stranger as a unit the game names: Bob Stone unless named.
    local function stranger(token, spec)
        spec = spec or {}
        spec.name, spec.surname = spec.name or "Bob", spec.surname or "Stone"
        spec.class = spec.class or "WARRIOR"
        spec.id = spec.name .. "-" .. spec.surname
        wow.addUnit(token, spec)
        return wow.state.units[token]
    end

    local function buffedBy(token)
        wow.gainBuff({ sourceUnit = token, name = "Arcane Intellect", spellId = INTELLECT })
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    -- Who the macro targets, read from the macro the game holds.
    local function macroTarget()
        local text = macro()
        return text and text:match("/targetexact ([^\n]+)")
    end

    -- Wait for the button's next re-check.
    local function recheck() wow.advance(ns.BuffButton.RECHECK_SECONDS + 0.1) end

    before_each(function() boot() end)

    describe("a favour whose player can't be seen or is out of range doesn't hold the button", function()
        it("hides the button when the only player you owe can't be seen (white)", function()
            stranger("nameplate1")
            buffedBy("nameplate1")
            assert.are.equal("Bob Stone", macroTarget())
            wow.state.units.nameplate1 = nil -- they ran off: no nameplate, not targeted
            recheck()
            assert.is_nil(macro())
            assert.is_false(button:IsShown())
            assert.are.equal(1, ns.Offers.Count(), "the favour is kept for the owed time")
        end)

        it("hides the button when the only player you owe is out of your buff's range (white)", function()
            local bob = stranger("nameplate1")
            buffedBy("nameplate1")
            assert.is_truthy(macro())
            bob.outOfSpellRange = true -- the owner's case: every press failed "Out of range"
            recheck()
            assert.is_nil(macro())
            assert.is_false(button:IsShown())
            assert.are.equal(1, ns.Offers.Count())
        end)

        it("offers the next favour while the newest one's player can't be seen (white)", function()
            stranger("nameplate1", { name = "Cid", surname = "Rock" })
            buffedBy("nameplate1")
            stranger("nameplate2")
            buffedBy("nameplate2") -- Bob, the newest
            assert.are.equal("Bob Stone", macroTarget())
            wow.state.units.nameplate2 = nil
            recheck()
            assert.are.equal("Cid Rock", macroTarget())
            assert.are.equal("Cid Rock", button.title:GetText())
        end)

        it("offers the next favour while the newest one's player is out of range (white)", function()
            stranger("nameplate1", { name = "Cid", surname = "Rock" })
            buffedBy("nameplate1")
            local bob = stranger("nameplate2")
            buffedBy("nameplate2")
            bob.outOfSpellRange = true
            recheck()
            assert.are.equal("Cid Rock", macroTarget())
        end)

        it("leaves a player who has left out of the list beside the button (white)", function()
            stranger("nameplate1", { name = "Cid", surname = "Rock" })
            buffedBy("nameplate1")
            stranger("nameplate3", { name = "Dee", surname = "Vale" })
            buffedBy("nameplate3")
            local bob = stranger("nameplate2")
            buffedBy("nameplate2") -- Bob, the newest
            bob.outOfSpellRange = true
            recheck()
            local rows = {}
            for _, row in ipairs(ns.BuffList.Rows()) do
                if row:IsShown() then rows[#rows + 1] = row.text:GetText() end
            end
            assert.are.same({ "> Dee Vale: Mark of the Wild", "Cid Rock: Mark of the Wild" }, rows)
        end)

        it("in buff mode, the button names no reason about a player who has left (white)", function()
            boot({ class = "PRIEST", known = { [FORTITUDE_1] = true, [FORTITUDE] = true } })
            slash("buffmode on")
            stranger("nameplate1")
            buffedBy("nameplate1")
            wow.state.units.nameplate1 = nil
            recheck()
            assert.is_true(button:IsShown(), "buff mode keeps the button up")
            assert.is_nil(macro())
            -- Only the group's reason: alone, nobody in it to buff.
            assert.are.equal("you're not in a group", button.subtitle:GetText())
        end)

        it("gives no reason for an out-of-range player who already wears your buffs, or is flagged (white)", function()
            local bob = stranger("nameplate1", { auras = { MOTW, 9910 } }) -- wears both of yours
            buffedBy("nameplate1")
            local _, why = ns.Offers.Current()
            assert.are.equal("Bob Stone: they already have your buffs", why)
            bob.outOfSpellRange = true
            local offer, reason, everyoneLeft = ns.Offers.Current()
            assert.is_nil(offer)
            assert.is_true(everyoneLeft, "out of range, he doesn't hold the button: " .. tostring(reason))
            bob.auras, bob.pvp = nil, true
            offer, reason, everyoneLeft = ns.Offers.Current()
            assert.is_nil(offer)
            assert.is_true(everyoneLeft, "flagged and out of range, he doesn't hold the button: " .. tostring(reason))
        end)

        it("never asks the game for range without a spell name (black)", function()
            local bob = stranger("nameplate1")
            buffedBy("nameplate1")
            bob.outOfSpellRange = true
            local asked = {}
            local real = _G.C_Spell.IsSpellInRange
            finally(function() _G.C_Spell.IsSpellInRange = real end)
            _G.C_Spell.IsSpellInRange = function(spell, unit)
                asked[#asked + 1] = tostring(spell)
                return real(spell, unit)
            end
            local realName = ns.BuffData.SpellName
            finally(function() ns.BuffData.SpellName = realName end)
            ns.BuffData.SpellName = function() return nil end -- the game names none of your buffs
            local offer, why = ns.Offers.Current()
            assert.is_nil(offer)
            assert.are.equal("Bob Stone: the spell's name isn't known", why)
            assert.are.same({}, asked)
        end)

        it("reads the game's range answers as in range, out of range or unknown (white, black)", function()
            stranger("nameplate1")
            local u = wow.state.units.nameplate1
            assert.is_true(ns.Util.InSpellRange("Mark of the Wild", "nameplate1"))
            u.outOfSpellRange = true
            assert.is_false(ns.Util.InSpellRange("Mark of the Wild", "nameplate1"))
            u.spellRangeUnknown = true
            assert.is_nil(ns.Util.InSpellRange("Mark of the Wild", "nameplate1"))
            local real = _G.C_Spell.IsSpellInRange
            finally(function() _G.C_Spell.IsSpellInRange = real end)
            for _, answer in ipairs({ "yes", 2, {}, wow.secret(true) }) do
                _G.C_Spell.IsSpellInRange = function() return answer end
                assert.is_nil(ns.Util.InSpellRange("Mark of the Wild", "nameplate1"), tostring(answer))
            end
            _G.C_Spell.IsSpellInRange = function() error("the game threw") end
            assert.is_nil(ns.Util.InSpellRange("Mark of the Wild", "nameplate1"))
        end)

        it("still offers them when the game won't say whether your buff reaches them (black)", function()
            local bob = stranger("nameplate1")
            buffedBy("nameplate1")
            bob.spellRangeUnknown = true
            recheck()
            assert.are.equal("Bob Stone", macroTarget(), "unknown is not out of range: the press decides")
        end)

        it("still offers them when the game's range answer is a secret (black)", function()
            stranger("nameplate1")
            buffedBy("nameplate1")
            local real = _G.C_Spell.IsSpellInRange
            finally(function() _G.C_Spell.IsSpellInRange = real end)
            _G.C_Spell.IsSpellInRange = function() return wow.secret(false) end
            local realOld = _G.IsSpellInRange
            finally(function() _G.IsSpellInRange = realOld end)
            _G.IsSpellInRange = function() return wow.secret(0) end
            recheck()
            assert.are.equal("Bob Stone", macroTarget(), "a secret is never compared")
        end)

        it("reads range from the old API when the new one is missing (black)", function()
            local bob = stranger("nameplate1")
            buffedBy("nameplate1")
            local real = _G.C_Spell.IsSpellInRange
            finally(function() _G.C_Spell.IsSpellInRange = real end)
            _G.C_Spell.IsSpellInRange = nil
            local realOld = _G.IsSpellInRange
            finally(function() _G.IsSpellInRange = realOld end)
            _G.IsSpellInRange = function(_, unit)
                return wow.state.units[unit] and (wow.state.units[unit].outOfSpellRange and 0 or 1) or nil
            end
            recheck()
            assert.are.equal("Bob Stone", macroTarget())
            bob.outOfSpellRange = true
            recheck()
            assert.is_nil(macro())
        end)

        it("checks the range of the buff it would give, not only your first buff (white)", function()
            local bob = stranger("nameplate1", { auras = { MOTW } }) -- wears your first buff
            buffedBy("nameplate1")
            local real = _G.C_Spell.IsSpellInRange
            finally(function() _G.C_Spell.IsSpellInRange = real end)
            _G.C_Spell.IsSpellInRange = function(spell, unit)
                if spell == "Thorns" and unit == "nameplate1" then return not bob.thornsOut end
                return true
            end
            recheck()
            assert.are.equal("Bob Stone", macroTarget())
            assert.are.equal("buffed you - give Thorns", button.subtitle:GetText())
            bob.thornsOut = true
            recheck()
            assert.is_nil(macro(), "Thorns can't reach him")
        end)
    end)

    describe("if they come back within the owed time, they're offered again", function()
        it("offers them again once they're seen again (white)", function()
            stranger("nameplate1")
            buffedBy("nameplate1")
            wow.state.units.nameplate1 = nil
            recheck()
            assert.is_nil(macro())
            wow.advance(60)
            stranger("target") -- you target them
            recheck()
            assert.are.equal("Bob Stone", macroTarget())
        end)

        it("offers them again once they're back in range (white)", function()
            local bob = stranger("nameplate1")
            buffedBy("nameplate1")
            bob.outOfSpellRange = true
            recheck()
            assert.is_nil(macro())
            bob.outOfSpellRange = nil
            recheck()
            assert.are.equal("Bob Stone", macroTarget())
        end)

        it("doesn't offer them once the owed time has run out (black)", function()
            stranger("nameplate1")
            buffedBy("nameplate1")
            wow.state.units.nameplate1 = nil
            wow.advance(ns.db.buffBack.owedMinutes * 60 + 1)
            stranger("nameplate1")
            recheck()
            assert.is_nil(macro())
            assert.are.equal(0, ns.Offers.Count())
        end)

        it("comes back on a nameplate appearing, without waiting for the re-check (white)", function()
            stranger("nameplate1")
            buffedBy("nameplate1")
            wow.state.units.nameplate1 = nil
            wow.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
            wow.advance(0)
            assert.is_nil(macro())
            stranger("nameplate5")
            wow.fire("NAME_PLATE_UNIT_ADDED", "nameplate5")
            wow.advance(0)
            assert.are.equal("Bob Stone", macroTarget())
        end)
    end)

    describe("nothing casts without a press", function()
        it("casts nothing while they come and go, and casts on them only when pressed (white)", function()
            local bob = stranger("nameplate1")
            buffedBy("nameplate1")
            for _ = 1, 5 do
                bob.outOfSpellRange = true
                recheck()
                bob.outOfSpellRange = nil
                recheck()
            end
            assert.are.equal(0, #wow.casts, "nothing cast without a press")
            wow.press(button)
            assert.are.equal(1, #wow.casts)
            assert.are.equal("Bob-Stone", wow.casts[1].target)
        end)

        it("a press while they're away casts nothing (white)", function()
            stranger("nameplate1")
            buffedBy("nameplate1")
            wow.state.units.nameplate1 = nil
            recheck()
            wow.press(button)
            assert.are.equal(0, #wow.casts)
        end)
    end)

    describe("chaos (red)", function()
        -- Players come and go, step in and out of range and buff you, at
        -- random. Whenever the button holds a macro, the player it targets is
        -- shown by some unit the game names, within your buff's range; the
        -- check reads only the simulated client's state.
        it("never arms the button for a player who has left, and never casts without a press", function()
            random.seed(270)
            local function int(m, n) return random.random(m, n) end
            local people = { { "Bob", "Stone" }, { "Cid", "Rock" }, { "Dee", "Vale" }, { "Eve", "Moss" } }
            local tokens = { "nameplate1", "nameplate2", "nameplate3", "target", "mouseover" }
            local presses = 0
            for _ = 1, 600 do
                local roll = int(1, 10)
                local token = tokens[int(1, #tokens)]
                if roll <= 3 then
                    local who = people[int(1, #people)]
                    stranger(token, { name = who[1], surname = who[2], outOfSpellRange = int(1, 3) == 1 })
                    if int(1, 2) == 1 then buffedBy(token) end
                elseif roll <= 5 then
                    wow.state.units[token] = nil
                elseif roll <= 7 then
                    local u = wow.state.units[token]
                    if u then u.outOfSpellRange = not u.outOfSpellRange end
                elseif roll == 8 then
                    wow.press(button)
                    presses = presses + 1
                end
                wow.advance(int(0, 4))
                ns.BuffButton.Refresh()
                local target = macroTarget()
                if target then
                    local reachable = false
                    for _, t in ipairs(tokens) do
                        local u = wow.state.units[t]
                        if u and u.name .. " " .. u.surname == target and not u.outOfSpellRange then
                            reachable = true
                        end
                    end
                    assert.is_true(reachable, target .. " is armed but has left")
                end
                assert.is_true(#wow.casts <= presses, "a cast without a press")
            end
        end)
    end)

    describe("the reason the button shows is never cut short", function()
        -- Whole, inside the button, on as many lines as it wraps onto: worked
        -- out from the simulated client's anchors, widths and line heights.
        local function assertWhole(fs)
            local drawn = wow.drawnText(fs, button)
            local plain = (fs:GetText() or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            assert.are.equal(plain, drawn.text, "cut short: " .. plain)
            assert.is_true(drawn.left >= 0 and drawn.right <= button:GetWidth())
            local _, _, _, _, y = fs:GetPoint(1)
            local bottom = -y + drawn.lines * wow.LINE_HEIGHT[fs.font]
            assert.is_true(bottom <= button:GetHeight(),
                ("%d lines reach %d, the button is %d tall: %s"):format(drawn.lines, bottom, button:GetHeight(), plain))
            return drawn
        end

        it("wraps the longest reason whole: a long name, an unreadable flag and a group reason (white)", function()
            boot({ class = "PRIEST", known = { [FORTITUDE_1] = true, [FORTITUDE] = true } })
            slash("buffmode on")
            -- The longest name a player can have: 12 letters, and a surname as long.
            stranger("nameplate1", { name = "Wolfgangamad", surname = "Wolfgangamad" })
            local realPVP = _G.UnitIsPVP
            finally(function() _G.UnitIsPVP = realPVP end)
            _G.UnitIsPVP = function(unit)
                if unit == "player" then return false end
                return wow.secret(false)
            end
            buffedBy("nameplate1")
            wow.setGroup("party", { "Wolfgangamax-Wolfgangamax" })
            wow.state.units.party1.secrets = { auras = true }
            wow.state.units.player.dead = true -- no offer to you either
            wow.fire("GROUP_ROSTER_UPDATE")
            recheck()
            assert.is_nil(macro())
            local reason = button.subtitle:GetText()
            assert.truthy(reason:find("can't see whether they're flagged for PvP (target them, or show friendly nameplates)",
                1, true), reason)
            assert.truthy(reason:find("; ", 1, true), "the group's reason follows: " .. reason)
            local drawn = assertWhole(button.subtitle)
            assert.is_true(drawn.lines >= 4, "the longest reason wraps: " .. drawn.lines)
            assertWhole(button.title)
        end)

        it("shrinks back when a short line follows a long one (white)", function()
            boot({ class = "PRIEST", known = { [FORTITUDE_1] = true, [FORTITUDE] = true } })
            slash("buffmode on")
            stranger("nameplate1", { name = "Wolfgangamad", surname = "Wolfgangamad" })
            local realPVP = _G.UnitIsPVP
            finally(function() _G.UnitIsPVP = realPVP end)
            _G.UnitIsPVP = function(unit)
                if unit == "player" then return false end
                return wow.secret(false)
            end
            buffedBy("nameplate1")
            recheck()
            local tall = button:GetHeight()
            assert.is_true(tall > ns.BuffButton.MIN_HEIGHT)
            _G.UnitIsPVP = realPVP
            recheck()
            assert.are.equal("buffed you - give Power Word: Fortitude", button.subtitle:GetText())
            assert.is_true(button:GetHeight() < tall, "it shrinks")
            assertWhole(button.subtitle)
            slash("move") -- a one-line hint: back to its first size
            assert.are.equal(ns.BuffButton.MIN_HEIGHT, button:GetHeight())
        end)

        it("fits any text from empty to very long, colour codes and accents included (black)", function()
            random.seed(2701)
            local function int(m, n) return random.random(m, n) end
            for _ = 1, 200 do
                local parts = {}
                for i = 1, int(0, 80) do parts[i] = ({ "Ünïcödé", "can't", "a", "Wolfgangamad", "PvP;" })[int(1, 5)] end
                local text = table.concat(parts, " ")
                if int(1, 3) == 1 then text = "|cffff0000" .. text .. "|r" end
                button.subtitle:SetText(text)
                button:SetHeight(ns.BuffButton.HeightFor(button.subtitle))
                assertWhole(button.subtitle)
            end
        end)

        it("makes room for the game's own line height when it is taller (white)", function()
            button.subtitle:SetText("short")
            local fs = button.subtitle
            fs.GetStringHeight = function() return 15 end -- one line, 15 tall
            fs.GetNumLines = function() return 1 end
            local top = ns.BuffButton.SUBTITLE_TOP + ns.BuffButton.BOTTOM_PAD
            assert.are.equal(math.max(ns.BuffButton.MIN_HEIGHT, top + 15), ns.BuffButton.HeightFor(fs))
            -- Too wide for one line: three lines here, each as tall as the game's.
            fs:SetText(string.rep("x", 60))
            assert.are.equal(top + 3 * 15, ns.BuffButton.HeightFor(fs))
        end)

        it("makes room for every line the game says it wrapped onto, if more (white)", function()
            local fs = button.subtitle
            fs:SetText(string.rep("word ", 6)) -- one line by its width
            fs.GetStringHeight = function() return 48 end -- the game wrapped it early, onto 4 lines
            fs.GetNumLines = function() return 4 end
            assert.are.equal(ns.BuffButton.SUBTITLE_TOP + 48 + ns.BuffButton.BOTTOM_PAD, ns.BuffButton.HeightFor(fs))
        end)

        it("ignores a measure the game gives as a secret or not a number (black)", function()
            local fs = button.subtitle
            fs:SetText("short")
            for _, bad in ipairs({ wow.secret(500), "500", true }) do
                fs.GetStringHeight = function() return bad end
                fs.GetNumLines = function() return bad end
                assert.are.equal(ns.BuffButton.MIN_HEIGHT, ns.BuffButton.HeightFor(fs))
            end
            fs.GetStringHeight = function() error("no layout yet") end
            assert.are.equal(ns.BuffButton.MIN_HEIGHT, ns.BuffButton.HeightFor(fs))
        end)

        it("keeps its size through a fight, and fits its text again after (black)", function()
            boot({ class = "PRIEST", known = { [FORTITUDE_1] = true, [FORTITUDE] = true } })
            slash("buffmode on")
            wow.enterCombat() -- the button empties, and its size is locked
            assert.has_no.errors(function() recheck() end)
            wow.leaveCombat()
            recheck()
            assertWhole(button.subtitle)
        end)
    end)
end)
