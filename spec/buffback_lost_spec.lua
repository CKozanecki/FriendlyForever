-- Spec: #387, #491
-- Buff Back's whole settings section lost mid-session (nil, a string, a
-- number: another addon or a bad /run). Every reader takes it as Buff Back
-- switched off, or heals it first through Config.Section, and none raises
-- an error (black). The red storm is phase1_chaos_spec's damage storm.
local wow = require("spec.support.wow")

local MOTW, MOTW_1 = 9885, 1126
local INTELLECT = 10157

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

-- Each way the section can be lost. A function, so nil can be one of them.
local LOST = {
    ["nil"] = function() return nil end,
    ["a string"] = function() return "x" end,
    ["a number"] = function() return 42 end,
}

describe("Buff Back's settings lost mid-session (#387, black)", function()
    local ns, button

    local function boot()
        ns = wow.boot({ before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
        end })
        ns.db.buff.messages = { "Thanks {name}" }
        button = ns.BuffButton.Frame()
    end

    -- Bob Stone, a stranger the game names (a nameplate).
    local function stranger()
        wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
    end

    local function buffedBy()
        wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
    end

    for label, lost in pairs(LOST) do
        describe("set to " .. label, function()
            before_each(boot)

            it("a stranger's buff raises no error and owes no favour, with Buff Thanks on or off", function()
                for _, thanks in ipairs({ true, false }) do
                    boot()
                    ns.db.buff.enabled = thanks
                    stranger()
                    ns.db.buffBack = lost()
                    buffedBy()
                    wow.advance(ns.Receipts.WAIT + ns.db.buff.delay + 0.01)
                    assert.are.same({}, wow.errors, "thanks " .. tostring(thanks))
                    assert.are.equal(0, ns.Offers.Count(), "thanks " .. tostring(thanks))
                end
            end)

            it("a favour returned by a hand cast raises no error and isn't marked returned", function()
                stranger()
                buffedBy()
                assert.are.equal(1, ns.Offers.Count())
                ns.db.buffBack = lost()
                -- Your action bar, on Bob: no press waits.
                ns.BuffButton.OnSpellcastSent("player", "Bob Stone", "Cast-1", MOTW)
                ns.BuffButton.OnSpellcastSucceeded("player", "Cast-1", MOTW)
                assert.are.same({}, wow.errors)
                assert.is_nil(ns.db.ledger.entries[1].returned, "Buff Back off: nothing returned")
            end)

            it("a press on the button armed before the section was lost casts nothing, and raises no error", function()
                stranger()
                buffedBy()
                assert.is_truthy(button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText), "armed")
                ns.db.buffBack = lost()
                wow.press(button)
                assert.are.same({}, wow.errors)
                assert.are.equal(0, #wow.casts, "Buff Back reads as off: the press casts nothing")
            end)

            it("/friendly buffback raises no error, says it's on, and heals the section", function()
                ns.db.buffBack = lost()
                slash("buffback")
                assert.are.same({}, wow.errors)
                assert.is_table(ns.db.buffBack)
                assert.is_truthy(table.concat(wow.printed, "\n"):find("offer my buff back: on", 1, true))
            end)

            it("/friendly move raises no error, and unlocks into a healed section", function()
                ns.db.buffBack = lost()
                slash("move")
                assert.are.same({}, wow.errors)
                assert.is_table(ns.db.buffBack)
                assert.is_true(ns.db.buffBack.unlocked)
            end)

            it("locking with the section lost while unlocked saves the position into a healed section", function()
                slash("move")
                ns.db.buffBack = lost()
                button:ClearAllPoints()
                button:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 10, -20)
                assert.is_true(ns.BuffButton.SetUnlocked(false))
                assert.are.same({}, wow.errors)
                assert.is_false(ns.db.buffBack.unlocked)
                assert.are.same({ point = "TOPLEFT", x = 10, y = -20 }, ns.db.buffBack.position)
            end)

            it("a drag started while unlocked raises no error, and doesn't move the button", function()
                slash("move")
                ns.db.buffBack = lost()
                local moved = false
                button.StartMoving = function() moved = true end
                button.scripts.OnDragStart(button)
                assert.are.same({}, wow.errors)
                assert.is_false(moved, "read as locked")
            end)

            it("the line after a returned favour raises no error, and isn't said", function()
                ns.db.buffBack.sayLine = true
                ns.db.buffBack.messages = { "For you, {name}: {buff}!" }
                stranger()
                buffedBy()
                wow.press(button)
                assert.are.equal("Mark of the Wild", ns.db.ledger.entries[1].returned)
                ns.db.buffBack = lost()
                wow.advance(0)
                wow.keyDown()
                assert.are.same({}, wow.errors)
                assert.are.same({}, wow.sentTo("SAY"), "the line is switched off")
            end)

            it("a favour returned with the section lost before the press says no line", function()
                ns.db.buffBack.sayLine = true
                stranger()
                buffedBy()
                button.scripts.PreClick(button, "LeftButton", true)
                button.scripts.PreClick(button, "LeftButton", false)
                ns.db.buffBack = lost()
                ns.BuffButton.OnSpellcastSent("player", "Bob Stone", "Cast-1", MOTW)
                ns.BuffButton.OnSpellcastSucceeded("player", "Cast-1", MOTW)
                wow.advance(0)
                wow.keyDown()
                assert.are.same({}, wow.errors)
                assert.are.same({}, wow.sentTo("SAY"))
            end)

            it("buff mode's auto triggers read as off: a buff, a fight and its end raise no error", function()
                stranger()
                ns.db.buffBack = lost()
                buffedBy()
                assert.is_false(ns.BuffMode.IsOn(), "'someone buffed you' reads as off")
                wow.enterCombat()
                wow.leaveCombat()
                wow.advance(60)
                assert.are.same({}, wow.errors)
                assert.is_false(ns.BuffMode.IsOn())
            end)
        end)
    end
end)
