-- Spec: #28, #76, #46
-- Buff mode: a key of your choice lent to the buff-back button while it's
-- on, handed back when it ends and during fights.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1 = 9885, 1126
local INTELLECT = 10157

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

local function printedHas(fragment)
    for _, line in ipairs(wow.printed) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

-- The keys lent right now: { [key] = button name }.
local function lent()
    local out = {}
    for key, o in pairs(wow.state.overrides) do out[key] = o.button end
    return out
end

describe("Buff mode", function()
    local ns, button

    local function boot(db)
        ns = wow.boot({ db = db, before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true }
        end })
        button = ns.BuffButton.Frame()
    end

    -- Someone owes you a favour, so the button holds a cast.
    local function owed(name)
        name = name or "Bob"
        wow.addUnit("nameplate1", { name = name, surname = "Stone", class = "WARRIOR", id = name .. "-Stone" })
        wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
    end

    before_each(function() boot() end)

    describe("lending the key", function()
        it("lends the mouse wheel to the button while on, and gives it back when off", function()
            owed()
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(0, #wow.casts, "off: the wheel does its own job")
            assert.are.same({ key = "MOUSEWHEELUP", action = "default" }, wow.keyActions[1])
            slash("buffmode on")
            assert.are.same({ MOUSEWHEELUP = "FriendlyForeverBuffButton" }, lent())
            assert.is_true(wow.state.overrides.MOUSEWHEELUP.priority)
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(1, #wow.casts, "on: the wheel presses the button")
            assert.are.equal("Bob-Stone", wow.casts[1].target)
            slash("buffmode off")
            assert.are.same({}, lent(), "no override left")
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(1, #wow.casts)
            assert.are.equal("default", wow.keyActions[2].action)
        end)

        it("never casts by itself: only a press of the lent key does", function()
            owed()
            slash("buffmode on")
            wow.advance(60)
            assert.are.equal(0, #wow.casts)
        end)

        it("switches with no argument, and with its key binding", function()
            slash("buffmode")
            assert.is_true(ns.BuffMode.IsOn())
            _G.FriendlyForever_ToggleBuffMode()
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, lent())
            local xml = wow.readFile("Bindings.xml")
            assert.is_truthy(xml:find('<Binding name="FRIENDLYFOREVER_BUFFMODE" category="ADDONS">'
                .. "FriendlyForever_ToggleBuffMode()</Binding>", 1, true))
            assert.are.equal("Friendly Forever: buff mode on/off", _G.BINDING_NAME_FRIENDLYFOREVER_BUFFMODE)
        end)

        it("says what it did", function()
            slash("buffmode on")
            assert.is_true(printedHas("buff mode on: MOUSEWHEELUP presses the buff-back button."))
            slash("buffmode off")
            assert.is_true(printedHas("buff mode off."))
            wow.printed = {}
            slash("buffmode sideways")
            assert.is_true(printedHas("/friendly buffmode [on | off | key <key>]"))
        end)

        it("uses the game's name for the key in messages", function()
            wow.state.bindingText = { MOUSEWHEELUP = "Mouse Wheel Up" }
            slash("buffmode on")
            assert.is_true(printedHas("buff mode on: Mouse Wheel Up presses the buff-back button."))
            assert.are.equal(ns.Colours.Text("title", "Buff mode:") .. " Mouse Wheel Up", button.mode:GetText())
        end)

        it("lends the key once, not again on every re-check", function()
            owed()
            local calls = 0
            local real = _G.SetOverrideBindingClick
            _G.SetOverrideBindingClick = function(...) calls = calls + 1; return real(...) end
            slash("buffmode on")
            wow.advance(60)
            wow.fire("PLAYER_TARGET_CHANGED")
            assert.are.equal(1, calls)
        end)

        it("is off after a reload, with no key lent", function()
            slash("buffmode on")
            boot(_G.FriendlyForeverDB)
            assert.is_false(ns.BuffMode.IsOn())
            assert.are.same({}, lent())
        end)
    end)

    describe("the button", function()
        it("shows buff mode above it, and stays up saying why when there's nothing to buff", function()
            assert.is_false(button:IsShown())
            slash("buffmode on")
            assert.is_true(button:IsShown())
            assert.are.equal(ns.Colours.Text("title", "Buff mode:") .. " MOUSEWHEELUP", button.mode:GetText())
            assert.are.equal("Buff mode", button.title:GetText())
            assert.are.equal("you're not in a group", button.subtitle:GetText())
            owed()
            assert.are.equal("Bob Stone", button.title:GetText(), "a favour shows as usual")
            slash("buffmode off")
            assert.are.equal("", button.mode:GetText())
        end)

        it("hides again when buff mode ends with nothing to buff", function()
            slash("buffmode on")
            slash("buffmode off")
            assert.is_false(button:IsShown())
        end)

        it("is in /friendly buffback", function()
            slash("buffback")
            assert.is_true(printedHas("buff mode: off (key: MOUSEWHEELUP)"))
            slash("buffmode on")
            wow.printed = {}
            slash("buffback")
            assert.is_true(printedHas("buff mode: on, MOUSEWHEELUP presses the button"))
        end)
    end)

    describe("choosing the key", function()
        local function chooser() return ns.Options.widgets.buffModeKey end

        it("takes the next key you press, with modifiers, and lends that one", function()
            wow.run(ns.Options.widgets.tabs.buffBack, "OnClick")
            assert.is_true(chooser():IsShown())
            assert.are.equal("Buff mode key: MOUSEWHEELUP", chooser():GetText())
            slash("buffmode on")
            wow.run(chooser(), "OnClick")
            assert.are.equal(ns.Options.KEY_PROMPT, chooser():GetText())
            wow.state.mods = { shift = true }
            wow.keyDown("LSHIFT") -- a modifier alone isn't a key
            wow.keyDown("F")
            assert.are.equal("SHIFT-F", ns.db.buffBack.buffModeKey)
            assert.are.equal("Buff mode key: SHIFT-F", chooser():GetText())
            assert.are.same({ ["SHIFT-F"] = "FriendlyForeverBuffButton" }, lent(), "the new key, and only it")
        end)

        it("takes the mouse wheel and side mouse buttons", function()
            wow.run(chooser(), "OnClick")
            wow.wheel(-1)
            assert.are.equal("MOUSEWHEELDOWN", ns.db.buffBack.buffModeKey)
            wow.run(chooser(), "OnClick")
            wow.run(ns.Options.widgets.keyCapture, "OnMouseDown", "Button4")
            assert.are.equal("BUTTON4", ns.db.buffBack.buffModeKey)
            wow.run(chooser(), "OnClick")
            wow.run(ns.Options.widgets.keyCapture, "OnMouseDown", "LeftButton")
            assert.are.equal(ns.Options.KEY_PROMPT, chooser():GetText(), "left and right clicks are ignored")
        end)

        it("cancels with Esc, and stops listening once done", function()
            wow.run(chooser(), "OnClick")
            wow.keyDown("ESCAPE")
            assert.are.equal("MOUSEWHEELUP", ns.db.buffBack.buffModeKey)
            assert.are.equal("Buff mode key: MOUSEWHEELUP", chooser():GetText())
            assert.is_false(ns.Options.widgets.keyCapture.keyboard)
            wow.keyDown("G")
            assert.are.equal("MOUSEWHEELUP", ns.db.buffBack.buffModeKey)
        end)

        it("doesn't start in a fight", function()
            wow.enterCombat()
            wow.run(chooser(), "OnClick")
            assert.are.equal("Buff mode key: MOUSEWHEELUP", chooser():GetText())
            assert.is_true(printedHas("keys can't be changed in a fight."))
            assert.are.same({}, wow.errors)
        end)

        it("can be set with /friendly buffmode key, and refuses keys it mustn't lend", function()
            slash("buffmode key mousewheeldown")
            assert.are.equal("MOUSEWHEELDOWN", ns.db.buffBack.buffModeKey)
            for _, bad in ipairs({ "ESCAPE", "SHIFT-ENTER", "LSHIFT", "a b", "CTRL-", "F|cff", "BUTTON1",
                "CTRL-BUTTON2", "/", "--", "..", "SHIFT-", string.rep("A", 41) }) do
                local ok, why = ns.BuffMode.SetKey(bad)
                assert.is_false(ok, bad)
                assert.are.equal("that isn't a key buff mode can use", why)
            end
            for _, good in ipairs({ "-", "SHIFT--", ",", "SHIFT-.", "`", "\\", "=", "ALT-CTRL-SHIFT-F12", "BUTTON5" }) do
                assert.is_true(ns.BuffMode.SetKey(good), good)
            end
            wow.state.bindings.F9 = "FRIENDLYFOREVER_BUFFMODE"
            assert.are.same({ false, "that key turns buff mode on and off" }, { ns.BuffMode.SetKey("F9") })
            assert.are.equal("BUTTON5", ns.db.buffBack.buffModeKey)
        end)

        it("stops waiting for a key when a fight starts, so your keys reach your abilities", function()
            wow.run(chooser(), "OnClick")
            assert.is_true(ns.Options.widgets.keyCapture.mouse)
            wow.enterCombat()
            assert.is_false(ns.Options.widgets.keyCapture.keyboard)
            assert.is_false(ns.Options.widgets.keyCapture.mouse)
            assert.are.equal("Buff mode key: MOUSEWHEELUP", chooser():GetText())
            wow.keyDown("1")
            assert.are.equal("MOUSEWHEELUP", ns.db.buffBack.buffModeKey)
            -- Even a key that reached it in the fight is ignored.
            wow.run(ns.Options.widgets.keyCapture, "OnKeyDown", "2")
            assert.are.equal("MOUSEWHEELUP", ns.db.buffBack.buffModeKey)
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("fights", function()
        it("hands the key back as a fight starts, and lends it again after", function()
            owed()
            slash("buffmode on")
            wow.enterCombat()
            assert.are.same({}, lent())
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(0, #wow.casts)
            assert.are.equal("default", wow.keyActions[#wow.keyActions].action, "the wheel zooms in the fight")
            wow.leaveCombat()
            assert.are.same({ MOUSEWHEELUP = "FriendlyForeverBuffButton" }, lent())
            assert.are.same({}, wow.errors)
        end)

        it("turning it on in a fight waits for the fight to end, without an error", function()
            wow.enterCombat()
            slash("buffmode on")
            assert.are.same({}, lent())
            assert.is_true(printedHas("buff mode will turn on when this fight ends."))
            slash("buffback")
            assert.is_true(printedHas("buff mode: on, waiting for the fight to end"))
            wow.advance(30)
            assert.are.same({}, lent())
            wow.leaveCombat()
            assert.are.same({ MOUSEWHEELUP = "FriendlyForeverBuffButton" }, lent())
            assert.are.same({}, wow.errors)
        end)

        it("turning it off in a fight takes effect when it ends", function()
            slash("buffmode on")
            wow.enterCombat()
            _G.FriendlyForever_ToggleBuffMode()
            assert.is_true(printedHas("buff mode will turn off when this fight ends."))
            wow.leaveCombat()
            assert.are.same({}, lent())
            assert.are.same({}, wow.errors)
        end)

        it("after a reload mid-fight, waits for the button before lending", function()
            boot()
            wow.reset()
            ns = wow.boot({ before = function(state) state.inCombat = true end })
            slash("buffmode on")
            assert.is_nil(ns.BuffButton.Frame())
            wow.state.inCombat = false
            wow.fire("PLAYER_REGEN_ENABLED")
            assert.is_truthy(ns.BuffButton.Frame())
            assert.are.same({ MOUSEWHEELUP = "FriendlyForeverBuffButton" }, lent())
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("unusable keys and settings", function()
        it("repairs a damaged saved key to the mouse wheel", function()
            for _, damaged in ipairs({ 42, "ESCAPE", "", "not a key", {} }) do
                boot({ buffBack = { buffModeKey = damaged } })
                assert.are.equal("MOUSEWHEELUP", ns.db.buffBack.buffModeKey)
            end
            boot({ buffBack = { buffModeKey = "CTRL-BUTTON4" } })
            assert.are.equal("CTRL-BUTTON4", ns.db.buffBack.buffModeKey)
        end)

        it("falls back to the mouse wheel, with a message, for a key damaged mid-session", function()
            ns.db.buffBack.buffModeKey = "ESCAPE"
            slash("buffmode on")
            assert.are.same({ MOUSEWHEELUP = "FriendlyForeverBuffButton" }, lent())
            assert.is_true(printedHas("buff mode: the saved key isn't one that can be used; using MOUSEWHEELUP."))
            wow.printed = {}
            wow.advance(30) -- re-checks don't repeat the message
            assert.is_false(printedHas("saved key"))
        end)

        it("falls back to the mouse wheel when the game won't lend a key, and turns off if it won't lend that", function()
            ns.db.buffBack.buffModeKey = "F"
            wow.state.unbindable = { F = true }
            slash("buffmode on")
            assert.are.same({ MOUSEWHEELUP = "FriendlyForeverBuffButton" }, lent())
            assert.is_true(printedHas("buff mode: the game wouldn't lend F; using MOUSEWHEELUP."))
            slash("buffmode off")
            wow.state.unbindable.MOUSEWHEELUP = true
            slash("buffmode on")
            assert.are.same({}, lent())
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode is off: the game wouldn't lend a key to the buff-back button."))
            assert.are.same({}, wow.errors)
        end)

        it("ends when the addon or Buff Back is switched off, saying so, and won't turn on then", function()
            slash("buffmode on")
            slash("off")
            assert.are.same({}, lent())
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode off: the addon or Buff Back is switched off."))
            slash("on")
            assert.are.same({}, lent(), "it doesn't quietly take the key again")
            slash("buffmode on")
            ns.db.buffBack.enabled = false
            ns.BuffButton.Refresh()
            assert.are.same({}, lent())
            assert.is_false(ns.BuffMode.IsOn())
            slash("buffback")
            assert.is_true(printedHas("buff mode: off (key: MOUSEWHEELUP)"))
            slash("buffmode on")
            assert.is_false(ns.BuffMode.IsOn())
            assert.is_true(printedHas("buff mode needs the addon and Buff Back switched on."))
        end)

        it("keeps working when Buff Back's settings are damaged mid-session", function()
            slash("buffmode on")
            ns.db.buffBack.buffModeKey = { "x" }
            ns.BuffButton.Refresh()
            assert.are.same({ MOUSEWHEELUP = "FriendlyForeverBuffButton" }, lent())
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("chaos (red tests)", function()
        it("never leaves a stray key lent and never changes a binding in a fight", function()
            local keys = { "MOUSEWHEELUP", "MOUSEWHEELDOWN", "SHIFT-F", "BUTTON4", "ESCAPE", 42, "F" }
            for _, seed in ipairs({ 3, 28, 99, 512, 2026 }) do
                random.seed(seed)
                boot()
                local inFight = 0
                local realSet, realClear = _G.SetOverrideBindingClick, _G.ClearOverrideBindings
                local function guard()
                    if wow.state.inCombat then inFight = inFight + 1 end
                end
                local function wrap()
                    _G.SetOverrideBindingClick = function(...) guard(); return realSet(...) end
                    _G.ClearOverrideBindings = function(...) guard(); return realClear(...) end
                end
                wrap()
                local actions = {
                    function() slash(({ "buffmode", "buffmode on", "buffmode off" })[random.random(3)]) end,
                    function() _G.FriendlyForever_ToggleBuffMode() end,
                    function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                    function() ns.BuffMode.SetKey(keys[random.random(#keys)]) end,
                    function() ns.db.buffBack.buffModeKey = keys[random.random(#keys)] end,
                    function() slash(random.random() < 0.7 and "on" or "off") end,
                    function() ns.db.buffBack.enabled = random.random() < 0.8; ns.BuffButton.Refresh() end,
                    function() wow.state.unbindable = random.random() < 0.2 and { F = true } or nil end,
                    function() owed(({ "Bob", "Ann" })[random.random(2)]) end,
                    function() wow.pressKey(({ "MOUSEWHEELUP", "SHIFT-F", "F" })[random.random(3)]) end,
                    function() wow.advance(random.random() * 10) end,
                    function()
                        wow.state.inCombat = false
                        boot(_G.FriendlyForeverDB)
                        wrap()
                    end,
                }
                for step = 1, 400 do
                    actions[random.random(#actions)]()
                    local where = ("seed %d, step %d"):format(seed, step)
                    local count, owner = 0, nil
                    for _, o in pairs(wow.state.overrides) do
                        count = count + 1
                        assert.are.equal("FriendlyForeverBuffButton", o.button, where)
                        assert.is_true(owner == nil or owner == o.owner, where .. ": two owners")
                        owner = o.owner
                    end
                    assert.is_true(count <= 1, where .. ": more than one key lent")
                    if wow.state.inCombat then
                        assert.are.equal(0, count, where .. ": a key lent in a fight")
                    else
                        local allowed = ns.db.enabled and ns.db.buffBack.enabled
                        local should = ns.BuffMode.IsOn() and allowed
                        assert.are.equal(should and 1 or 0, count, where .. ": lent doesn't match buff mode")
                        if should then
                            assert.is_truthy(wow.state.overrides[ns.BuffMode.LentKey()], where)
                        end
                    end
                end
                assert.are.equal(0, inFight, "seed " .. seed .. ": a binding changed in a fight")
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
        end)
    end)
end)
