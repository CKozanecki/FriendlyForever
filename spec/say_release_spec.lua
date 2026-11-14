-- Spec: #271
-- A /say line held for a hardware event goes out on a press of the buff
-- button, on any binding (the mouse wheel too) or mouse button, as well as
-- on a key press; never without one.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

describe("A held /say goes on a buff-button press (#271)", function()
    local ns, Q, button

    before_each(function()
        ns = wow.boot()
        Q = ns.ChatQueue
        button = ns.BuffButton.Frame()
    end)

    local function holdSay(text)
        Q.Push({ channel = "SAY", label = text, getText = function() return text end })
    end

    -- The mouse wheel bound to the button, as the owner plays (#28's lent key
    -- is the same kind of binding).
    local function bindWheel()
        _G.SetOverrideBindingClick(CreateFrame("Frame"), false, "MOUSEWHEELUP", ns.BuffButton.FRAME_NAME, "LeftButton")
    end

    it("a buff-button press on the mouse wheel releases a held /say line", function()
        bindWheel()
        holdSay("thanks")
        wow.advance(10)
        assert.is_true(Q.IsWaitingForHardware())
        assert.are.equal(0, #wow.sent)
        wow.wheel(1)
        assert.are.same({ "thanks" }, wow.sentTo("SAY"))
        assert.are.equal(0, #wow.blocked, "sent inside the press")
        assert.is_false(Q.IsWaitingForHardware())
    end)

    it("a buff-button press by a left or a right click releases it too", function()
        holdSay("one")
        wow.advance(10)
        wow.press(button)
        assert.are.same({ "one" }, wow.sentTo("SAY"))
        holdSay("two")
        wow.advance(10)
        wow.press(button, "RightButton")
        assert.are.same({ "one", "two" }, wow.sentTo("SAY"))
        assert.are.equal(0, #wow.blocked)
    end)

    it("a buff-button press releases one line; the next waits for the next press", function()
        holdSay("one")
        holdSay("two")
        wow.advance(10)
        wow.press(button)
        assert.are.same({ "one" }, wow.sentTo("SAY"), "the spacing holds even within one press")
        wow.advance(Q.MIN_INTERVAL + 1)
        assert.are.same({ "one" }, wow.sentTo("SAY"), "no press, no /say")
        wow.press(button)
        assert.are.same({ "one", "two" }, wow.sentTo("SAY"))
        assert.are.equal(0, #wow.blocked)
    end)

    it("keyboard presses still release it, and a key bound to the button sends it once", function()
        holdSay("thanks")
        wow.advance(10)
        wow.keyDown("W")
        assert.are.same({ "thanks" }, wow.sentTo("SAY"))
        holdSay("again")
        wow.advance(10)
        -- A key bound to the button: OnKeyDown and the button's press, one key.
        wow.keyDown("F")
        wow.press(button)
        assert.are.same({ "thanks", "again" }, wow.sentTo("SAY"))
        assert.are.equal(0, #wow.blocked)
    end)

    it("a click from code is no hardware event: the line stays held", function()
        holdSay("thanks")
        wow.advance(10)
        -- Button:Click from code: an up half only (the game's down argument
        -- defaults to false), with its PreClick and PostClick.
        button:Click("LeftButton")
        button:Click("RightButton")
        assert.are.equal(0, #wow.casts, "a click from code casts nothing")
        assert.are.equal(0, #wow.sent)
        assert.are.equal(0, #wow.blocked, "never attempts /say without a hardware event")
        assert.is_true(Q.IsWaitingForHardware())
    end)

    it("a press with nothing held sends nothing", function()
        bindWheel()
        wow.wheel(1)
        wow.press(button)
        assert.are.equal(0, #wow.sent)
        assert.are.equal(0, #wow.blocked)
    end)

    it("a right-click on a favour both releases a held line and lets the favour go", function()
        ns = wow.boot({ before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [1126] = true, [9885] = true }
        end })
        Q, button = ns.ChatQueue, ns.BuffButton.Frame()
        wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone" })
        wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = 10157 })
        assert.is_truthy(ns.BuffButton.ArmedOffer(), "a favour is shown")
        holdSay("thanks")
        wow.advance(10)
        assert.are.equal(0, #wow.sentTo("SAY"))
        wow.press(button, "RightButton")
        assert.are.same({ "thanks" }, wow.sentTo("SAY"))
        assert.is_nil(ns.Offers.Current(), "the favour was let go")
        assert.are.equal(0, #wow.casts, "a right-click casts nothing")
        assert.are.equal(0, #wow.blocked)
    end)

    it("chaos: presses, code clicks, wheels and keys never send /say outside a hardware event", function()
        bindWheel()
        ns.db.linesPerMinute = 100
        random.seed(271)
        local function says() return #wow.sentTo("SAY") end
        -- What the storm reached, checked below so it can't quietly stop reaching it.
        local reach = { pressReleased = 0, codeClickWhileHeld = 0 }
        for _ = 1, 400 do
            local roll = random.random(1, 8)
            local outdoorsHeld = not wow.state.inInstance and Q.IsWaitingForHardware()
            local before = says()
            if roll == 1 then holdSay("line")
            elseif roll == 2 or roll == 3 then
                if roll == 2 then
                    wow.press(button, random.random(1, 2) == 1 and "LeftButton" or "RightButton")
                else
                    wow.wheel(1)
                end
                if outdoorsHeld and says() > before then reach.pressReleased = reach.pressReleased + 1 end
            elseif roll == 4 then wow.keyDown("W")
            elseif roll == 5 then
                button:Click("LeftButton")
                if outdoorsHeld then
                    reach.codeClickWhileHeld = reach.codeClickWhileHeld + 1
                    assert.are.equal(before, says(), "a click from code sent a held line")
                end
            elseif roll == 6 then wow.state.inInstance = not wow.state.inInstance
            else wow.advance(random.random(0, 30) / 10) end
        end
        -- The simulated client records any /say attempted outdoors without a
        -- hardware event as blocked: none was.
        assert.are.equal(0, #wow.blocked)
        assert.is_true(reach.pressReleased > 0, "a button press or the wheel released a held line")
        assert.is_true(reach.codeClickWhileHeld > 0, "a click from code came while a line was held")
        -- After the storm, a press still releases a fresh held line, exactly one.
        wow.state.inInstance = false
        wow.advance(Q.MAX_AGE + Q.RETRY_DELAY + 1) -- whatever the storm left has expired
        assert.are.equal(0, Q.Count())
        holdSay("after")
        holdSay("after2")
        wow.advance(Q.MIN_INTERVAL + 0.1)
        local before = says()
        wow.wheel(1)
        assert.are.equal(before + 1, says())
        assert.are.equal("after", wow.sentTo("SAY")[says()])
        assert.are.equal(0, #wow.blocked)
    end)
end)
