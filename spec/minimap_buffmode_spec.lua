-- Spec: #458
-- Shift-click on the minimap button turns buff mode on and off, by the same
-- path as /friendly buffmode, and its tooltip says so with the current state,
-- apart from right-click's whole-addon on/off.
local wow = require("spec.support.wow")

local MOTW, MOTW_1 = 9885, 1126

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

local function printedHas(fragment)
    for _, line in ipairs(wow.printed) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

local function lent()
    local n = 0
    for _ in pairs(wow.state.overrides) do n = n + 1 end
    return n
end

describe("Minimap button's shift-click (#458)", function()
    local ns, button

    local function boot()
        ns = wow.boot({ before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
        end })
        button = _G.FriendlyForeverMinimapButton
    end

    local function click(mouseButton, shift)
        wow.state.mods = { shift = shift or false }
        wow.run(button, "OnClick", mouseButton)
        wow.state.mods = {}
    end

    local function tooltip()
        wow.run(button, "OnEnter")
        return table.concat(_G.GameTooltip.lines, "\n")
    end

    before_each(boot)

    describe("white", function()
        it("a shift-click turns buff mode on, and the next turns it off", function()
            click("LeftButton", true)
            assert.is_true(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode on"))
            click("LeftButton", true)
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end)

        it("does what /friendly buffmode does: the same state, the same lent key", function()
            slash("buffmode")
            local viaSlash, lentSlash = ns.BuffMode.IsOn(), lent()
            slash("buffmode")
            click("LeftButton", true)
            assert.are.equal(viaSlash, ns.BuffMode.IsOn())
            assert.are.equal(lentSlash, lent())
            click("LeftButton", true)
            assert.are.equal(0, lent(), "the key is handed back")
        end)

        it("shift with the right button is buff mode too, never the addon's switch", function()
            click("RightButton", true)
            assert.is_true(ns.BuffMode.IsOn())
            assert.is_true(ns.db.enabled)
        end)

        it("a shift-click doesn't open the options", function()
            click("LeftButton", true)
            assert.is_nil(wow.settings.opened)
        end)

        it("left-click still opens the options and right-click still turns the addon off, buff mode untouched", function()
            click("LeftButton")
            assert.are.equal(4242, wow.settings.opened)
            click("RightButton")
            assert.is_false(ns.db.enabled)
            assert.is_false(ns.BuffMode.IsOn())
        end)

        it("the tooltip has its own Shift-click line, apart from Right-click's, with the state now", function()
            local off = tooltip()
            assert.is_truthy(off:find("Shift-click:", 1, true))
            assert.is_truthy(off:find("buff mode on/off", 1, true))
            assert.is_truthy(off:find("now", 1, true) and off:find("off", 1, true))
            assert.is_truthy(off:find("Right-click:", 1, true))
            assert.is_falsy(off:find("Right-click:[^\n]*buff mode"), "right-click's line isn't about buff mode")
            click("LeftButton", true)
            local on = tooltip()
            assert.is_truthy(on:find("now |c%x%x%x%x%x%x%x%xon"), on)
        end)

        it("the addon compartment's tooltip has the line too, and its click does the same", function()
            local line = ns.Minimap.BuffModeLine()
            assert.is_truthy(line:find("Shift-click:", 1, true))
            wow.state.mods = { shift = true }
            ns.Minimap.OnClick(nil, "LeftButton")
            wow.state.mods = {}
            assert.is_true(ns.BuffMode.IsOn())
        end)
    end)

    describe("the same rules as the command (black)", function()
        it("in a fight it waits for the fight to end, as /friendly buffmode does", function()
            wow.enterCombat()
            click("LeftButton", true)
            assert.is_true(printedHas("buff mode will turn on when this fight ends."))
            assert.are.equal(0, lent(), "no key is lent in a fight")
            wow.leaveCombat()
            assert.is_true(ns.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end)

        it("with the addon off it says buff mode needs it, and stays off", function()
            ns.SetEnabled(false)
            click("LeftButton", true)
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode needs the addon"))
        end)

        it("a modifier the game won't read (a secret value) isn't a shift: it opens the options", function()
            _G.IsShiftKeyDown = function() return wow.secret(true) end
            click("LeftButton")
            assert.are.equal(4242, wow.settings.opened)
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, wow.errors)
        end)
    end)
end)
