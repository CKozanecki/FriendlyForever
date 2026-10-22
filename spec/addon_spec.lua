-- End-to-end: the addon as the game loads it, plus its UI and commands.
local wow = require("spec.support.wow")

describe("Addon", function()
    describe("TOC", function()
        local meta, files

        before_each(function() meta, files = wow.parseToc() end)

        it("targets the WoW Forever interface version", function()
            assert.are.equal("16001", meta.Interface)
        end)

        it("declares the saved variable the code uses", function()
            assert.are.equal("FriendlyForeverDB", meta.SavedVariables)
        end)

        it("lists files that all exist, and every runtime Lua file", function()
            local listed = {}
            for _, file in ipairs(files) do
                assert.is_truthy(io.open(wow.ROOT .. file), file .. " is listed but missing")
                listed[file] = true
            end
            local handle = io.popen('ls "' .. wow.ROOT .. '"')
            for name in handle:read("*a"):gmatch("[^\n]+") do
                if name:match("%.lua$") then assert.is_true(listed[name], name .. " is not in the TOC") end
            end
            handle:close()
        end)

        it("loads Core last so every module exists when events arrive", function()
            assert.are.equal("Core.lua", files[#files])
        end)
    end)

    describe("loading", function()
        it("creates its saved variables on first run", function()
            local ns = wow.boot()
            assert.are.equal(ns.db, _G.FriendlyForeverDB)
            assert.are.equal(ns.Config.SCHEMA_VERSION, _G.FriendlyForeverDB.schemaVersion)
        end)

        it("keeps existing saved settings", function()
            local ns = wow.boot({ db = { enabled = false, guildJoin = { delay = 9 } } })
            assert.is_false(ns.db.enabled)
            assert.are.equal(9, ns.db.guildJoin.delay)
        end)

        it("ignores other addons' ADDON_LOADED", function()
            wow.reset()
            local ns = wow.load()
            wow.fire("ADDON_LOADED", "SomeOtherAddon")
            assert.is_nil(ns.db)
        end)

        it("does nothing before its saved variables are loaded", function()
            wow.reset()
            wow.load()
            wow.addUnit("target", { name = "Bob" })
            wow.fire("UNIT_AURA", "player", { addedAuras = { { isHelpful = true, sourceUnit = "target" } } })
            wow.fire("CHAT_MSG_SYSTEM", "Bob joins the party.")
            assert.are.equal(0, #wow.sent)
        end)

        it("creates no globals beyond the ones it declares", function()
            local before = {}
            wow.reset()
            for k in pairs(_G) do before[k] = true end
            wow.load()
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            local allowed = {
                FriendlyForeverDB = true, SLASH_FRIENDLYFOREVER1 = true, SLASH_FRIENDLYFOREVER2 = true,
                FriendlyForeverMinimapButton = true, FriendlyForeverOptionsPanel = true,
            }
            for k in pairs(_G) do
                if not before[k] then assert.is_true(allowed[k], "unexpected global: " .. tostring(k)) end
            end
        end)
    end)

    describe("options panel", function()
        local ns, w

        before_each(function()
            ns = wow.boot()
            w = ns.Options.widgets
        end)

        it("fills the number boxes as soon as the panel exists", function()
            assert.are.equal(tostring(ns.db.guildLogin.delay), w.steppers.delay.box:GetText())
            assert.are.equal(tostring(ns.db.guildLogin.repeatCooldown), w.steppers.repeatCooldown.box:GetText())
        end)

        it("fills them again whenever the panel is shown", function()
            ns.db.guildLogin.delay = 42
            wow.run(_G.FriendlyForeverOptionsPanel, "OnShow")
            assert.are.equal("42", w.steppers.delay.box:GetText())
        end)

        it("fills them once more on the next frame, after the settings window has laid out", function()
            wow.run(_G.FriendlyForeverOptionsPanel, "OnShow")
            w.steppers.delay.box:SetText("")           -- what the in-game bug looked like
            w.steppers.repeatCooldown.box:SetText("")
            wow.advance(0)
            assert.are.equal(tostring(ns.db.guildLogin.delay), w.steppers.delay.box:GetText())
            assert.are.equal("180", w.steppers.repeatCooldown.box:GetText())
        end)

        it("skips the next-frame fill if the panel was closed straight away", function()
            local panel = _G.FriendlyForeverOptionsPanel
            wow.run(panel, "OnShow")
            panel:Hide()
            w.steppers.delay.box:SetText("")
            wow.advance(0)
            assert.are.equal("", w.steppers.delay.box:GetText())
            assert.is_nil(ns.Diag.Counters().luaErrors)
        end)

        -- In-game, the delay/repeat boxes held their values but showed blank
        -- until clicked: the text was scrolled out of view behind the cursor.
        it("shows every text box from the start, on every tab and after edits", function()
            local function allEditBoxesAtStart(context)
                for _, f in ipairs(wow.frames) do
                    if f.kind == "EditBox" and f.text ~= "" then
                        assert.are.equal(0, f.cursor, context .. ": an edit box shows its text scrolled away")
                    end
                end
            end
            for _, msgType in ipairs(ns.Config.TYPES) do
                wow.run(w.tabs[msgType], "OnClick")
                allEditBoxesAtStart(msgType .. " tab")
            end
            wow.run(_G.FriendlyForeverOptionsPanel, "OnShow")
            wow.advance(0)
            allEditBoxesAtStart("panel shown")
            wow.run(w.steppers.delay.plus, "OnClick")
            w.steppers.repeatCooldown.box:SetText("300")
            wow.run(w.steppers.repeatCooldown.box, "OnEditFocusLost")
            allEditBoxesAtStart("after stepping and typing")
        end)

        it("logs each fill, with what the boxes show, when debug is on", function()
            ns.db.debug = true
            wow.run(w.tabs.partyJoin, "OnClick")
            local found
            for _, line in ipairs(ns.db.diagLog) do
                if line:find("options: filled partyJoin tab: delay 2 (box shows '2'), repeat 180 (box shows '180')", 1, true) then
                    found = true
                end
            end
            assert.is_true(found)
        end)

        it("registers under Options > AddOns", function()
            assert.are.equal(1, #wow.settings.categories)
            assert.are.equal("Friendly Forever", wow.settings.categories[1].name)
        end)

        it("has a tab per message type showing that type's settings", function()
            for _, msgType in ipairs(ns.Config.TYPES) do
                wow.run(w.tabs[msgType], "OnClick")
                assert.are.equal(msgType, ns.Options.CurrentType())
                assert.is_false(w.tabs[msgType]:IsEnabled(), "current tab is highlighted")
                assert.are.equal(tostring(ns.db[msgType].delay), w.steppers.delay.box:GetText())
                assert.are.equal(tostring(ns.db[msgType].repeatCooldown), w.steppers.repeatCooldown.box:GetText())
                for i = 1, ns.Config.NUM_MESSAGES do
                    assert.are.equal(ns.db[msgType].messages[i], w.edits[i]:GetText())
                end
            end
        end)

        it("shows buff-only options only on the buff tab", function()
            wow.run(w.tabs.guildLogin, "OnClick")
            assert.is_false(w.whisper:IsShown())
            assert.is_false(w.unknownName:IsShown())
            wow.run(w.tabs.buff, "OnClick")
            assert.is_true(w.whisper:IsShown())
            assert.is_true(w.listNames:IsShown())
            assert.are.equal("friend", w.unknownName:GetText())
        end)

        it("turns a message type on and off", function()
            wow.run(w.tabs.partyJoin, "OnClick")
            w.enabled:SetChecked(false)
            wow.run(w.enabled, "OnClick")
            assert.is_false(ns.db.partyJoin.enabled)
        end)

        it("edits messages", function()
            wow.run(w.tabs.guildJoin, "OnClick")
            w.edits[3]:SetText("Welcome, {name}!")
            wow.run(w.edits[3], "OnTextChanged", true)
            assert.are.equal("Welcome, {name}!", ns.db.guildJoin.messages[3])
        end)

        it("ignores text changes the user didn't make", function()
            wow.run(w.tabs.guildJoin, "OnClick")
            w.edits[3]:SetText("programmatic")
            wow.run(w.edits[3], "OnTextChanged", false)
            assert.are_not.equal("programmatic", ns.db.guildJoin.messages[3])
        end)

        it("steps and clamps the delay", function()
            wow.run(w.tabs.guildLogin, "OnClick")
            ns.db.guildLogin.delay = 59
            wow.run(w.steppers.delay.plus, "OnClick")
            wow.run(w.steppers.delay.plus, "OnClick")
            assert.are.equal(60, ns.db.guildLogin.delay)
            ns.db.guildLogin.delay = 0
            wow.run(w.steppers.delay.minus, "OnClick")
            assert.are.equal(0, ns.db.guildLogin.delay)
        end)

        it("sets the repeat cooldown from typed text, clamped", function()
            wow.run(w.tabs.guildLogin, "OnClick")
            w.steppers.repeatCooldown.box:SetText("300")
            wow.run(w.steppers.repeatCooldown.box, "OnEditFocusLost")
            assert.are.equal(300, ns.db.guildLogin.repeatCooldown)
            w.steppers.repeatCooldown.box:SetText("999999")
            wow.run(w.steppers.repeatCooldown.box, "OnEditFocusLost")
            assert.are.equal(3600, ns.db.guildLogin.repeatCooldown)
            w.steppers.repeatCooldown.box:SetText("")
            wow.run(w.steppers.repeatCooldown.box, "OnEditFocusLost")
            assert.are.equal(3600, ns.db.guildLogin.repeatCooldown, "blank keeps the old value")
        end)

        it("toggles whisper mode and buff name listing", function()
            wow.run(w.tabs.buff, "OnClick")
            w.whisper:SetChecked(true)
            wow.run(w.whisper, "OnClick")
            assert.is_true(ns.db.buff.useWhisper)
            w.listNames:SetChecked(false)
            wow.run(w.listNames, "OnClick")
            assert.is_false(ns.db.buff.listBuffNames)
        end)

        it("cleans the unknown-caster name", function()
            wow.run(w.tabs.buff, "OnClick")
            w.unknownName:SetText("|cffpal")
            wow.run(w.unknownName, "OnTextChanged", true)
            assert.are.equal("cffpal", ns.db.buff.unknownName)
        end)

        it("resets one tab to defaults without touching others", function()
            ns.db.guildLogin.messages[1] = "custom"
            ns.db.partyJoin.messages[1] = "also custom"
            ns.db.guildLogin.delay = 30
            wow.run(w.tabs.guildLogin, "OnClick")
            wow.run(w.reset, "OnClick")
            assert.are.same(ns.Config.DEFAULTS.guildLogin.messages, ns.db.guildLogin.messages)
            assert.are.equal(ns.Config.DEFAULTS.guildLogin.delay, ns.db.guildLogin.delay)
            assert.are.equal("also custom", ns.db.partyJoin.messages[1])
            assert.are.equal(ns.Config.DEFAULTS.guildLogin.messages[1], w.edits[1]:GetText())
        end)

        it("previews locally without sending anything", function()
            wow.run(w.preview, "OnClick")
            assert.are.equal(1, #wow.printed)
            assert.are.equal(0, #wow.sent)
        end)

        it("master checkbox turns the addon off", function()
            w.master:SetChecked(false)
            wow.run(w.master, "OnClick")
            assert.is_false(ns.db.enabled)
        end)
    end)

    describe("minimap button", function()
        local ns, button

        before_each(function()
            ns = wow.boot()
            button = _G.FriendlyForeverMinimapButton
        end)

        it("uses the handshake icon", function()
            assert.are.equal("Interface\\Icons\\Achievement_Reputation_01", button.icon.texture)
        end)

        it("left-click opens the options", function()
            wow.run(button, "OnClick", "LeftButton")
            assert.are.equal(4242, wow.settings.opened)
        end)

        it("right-click turns the addon off and greys the icon", function()
            wow.run(button, "OnClick", "RightButton")
            assert.is_false(ns.db.enabled)
            assert.is_true(button.icon.desaturated)
            wow.run(button, "OnClick", "RightButton")
            assert.is_true(ns.db.enabled)
            assert.is_false(button.icon.desaturated)
        end)

        it("dragging saves the angle around the minimap", function()
            wow.run(button, "OnDragStart")
            wow.state.cursorX, wow.state.cursorY = 0, 50 -- straight up from the centre
            wow.run(button, "OnUpdate")
            wow.run(button, "OnDragStop")
            assert.are.equal(90, ns.db.minimap.angle)
            assert.is_nil(button.scripts.OnUpdate)
        end)

        it("computes positions on the minimap edge", function()
            local x, y = ns.Minimap.OffsetForAngle(0, 140)
            assert.are.equal(75, x)
            assert.is_true(math.abs(y) < 1e-9)
            assert.are.equal(180, ns.Minimap.AngleFromCursor(100, 100, 50, 100, 1))
            assert.are.equal(270, ns.Minimap.AngleFromCursor(100, 100, 200, 0, 2))
        end)

        it("can be hidden with /friendly minimap", function()
            _G.SlashCmdList.FRIENDLYFOREVER("minimap")
            assert.is_false(button:IsShown())
            assert.is_true(ns.db.minimap.hide)
        end)

        it("shows a tooltip", function()
            wow.run(button, "OnEnter")
            assert.are.equal("Friendly Forever", _G.GameTooltip.lines[1])
        end)
    end)

    describe("slash commands", function()
        local ns
        before_each(function() ns = wow.boot() end)

        local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

        it("are registered as /friendly and /ffr", function()
            assert.are.equal("/friendly", _G.SLASH_FRIENDLYFOREVER1)
            assert.are.equal("/ffr", _G.SLASH_FRIENDLYFOREVER2)
        end)

        it("on, off and toggle", function()
            slash("off")
            assert.is_false(ns.db.enabled)
            slash("ON")
            assert.is_true(ns.db.enabled)
            slash("toggle")
            assert.is_false(ns.db.enabled)
        end)

        it("no argument opens the options", function()
            slash("")
            assert.are.equal(4242, wow.settings.opened)
        end)

        it("test previews every type locally", function()
            slash("test")
            assert.are.equal(#ns.Config.TYPES, #wow.printed)
            assert.are.equal(0, #wow.sent)
        end)

        it("say sends a waiting thank-you (typing it is a key press)", function()
            wow.addUnit("target", { name = "Bob" })
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.advance(ns.db.buff.delay + 0.1)
            wow.hardware = true
            slash("say")
            wow.hardware = false
            assert.are.equal(1, #wow.sentTo("SAY"))
        end)

        it("unknown commands print help hint, sanitised", function()
            slash("|cffhack")
            assert.is_truthy(wow.printed[1]:find("unknown command 'cffhack'", 1, true))
        end)
    end)
end)
