-- Spec: #166, #171, #408, #491
-- The options panel with a settings section damaged mid-session (#166), and
-- number boxes finishing their edit before a reset or tab switch (#171).
local wow = require("spec.support.wow")

describe("Options panel", function()
    local ns, w

    before_each(function()
        ns = wow.boot()
        w = ns.Options.widgets
    end)

    -- What a section can be damaged into mid-session (another addon, a bad /run).
    local DAMAGE = { 7, "broken", true, false, function() end }

    local function damaged(msgType)
        return type(ns.db[msgType]) ~= "table"
    end

    -- Opens a message type's lines as a player does: its tab, or for a
    -- favour the Favours tab at its lines' sub-tab (#491).
    local function openLines(msgType)
        if ns.Config.TYPE_INFO[msgType].favours then
            wow.run(w.tabs[ns.Options.FAVOURS_TAB], "OnClick")
            wow.run(w.linesTabs[msgType], "OnClick")
        else
            wow.run(w.tabs[msgType], "OnClick")
        end
    end

    -- Opens the panel from closed, as the player does (its OnShow fills it).
    local function open()
        local panel = _G.FriendlyForeverOptionsPanel
        panel:Hide()
        ns.Options.Open()
        assert.is_true(panel:IsVisible())
    end

    describe("a whole settings section damaged mid-session (black, #166)", function()
        -- recent: a repair ran under a second ago, so Config.Repair does
        -- nothing and the panel has to put the defaults back itself.
        for _, recent in ipairs({ false, true }) do
            local when = recent and " (a repair ran just before)" or ""

            it("opening the panel and switching tabs raise no Lua error, show the defaults, and repair it"
                .. when, function()
                for _, msgType in ipairs(ns.Config.TYPES) do
                    for _, value in ipairs(DAMAGE) do
                        ns = wow.boot()
                        w = ns.Options.widgets
                        if recent then ns.Config.Repair() end
                        ns.db[msgType] = value
                        ns.db.skipWhileAFK = "maybe"
                        open()
                        assert.is_false(damaged(msgType), msgType .. " healed as the panel opened")
                        assert.are.same(ns.Config.DefaultsFor(msgType), ns.db[msgType])
                        if not recent then
                            assert.is_true(ns.db.skipWhileAFK, "the whole-file repair ran: the rest heals too")
                        end
                        for _, tab in ipairs(ns.Options.TABS) do
                            ns.db[msgType] = value
                            wow.run(w.tabs[tab], "OnClick")
                            assert.is_false(damaged(msgType), msgType .. " healed on the " .. tab .. " tab")
                        end
                        wow.run(w.tabs[ns.Options.FAVOURS_TAB], "OnClick")
                        for _, lines in ipairs(ns.Options.FAVOUR_LINES) do
                            ns.db[msgType] = value
                            wow.run(w.linesTabs[lines], "OnClick")
                            assert.is_false(damaged(msgType), msgType .. " healed on Favours' " .. lines .. " lines")
                        end
                        ns.db[msgType] = value
                        openLines(msgType)
                        local defaults = ns.Config.DefaultsFor(msgType)
                        -- The switch and timing that show it: a message tab's rows, or
                        -- the Favours tab's own (#491). Buff back has no delay: its
                        -- minutes to offer stand in.
                        local switch, timing = w.enabled, w.steppers.delay.box
                        local timingText = defaults.delay and tostring(defaults.delay) or ""
                        if msgType == "buff" then
                            switch, timing = w.thankEnabled, w.steppers.thankDelay.box
                        elseif msgType == "buffBack" then
                            switch, timing = w.offerEnabled, w.steppers.owedMinutes.box
                            timingText = tostring(defaults.owedMinutes)
                        end
                        assert.are.equal(defaults.enabled == true, switch:GetChecked() == true,
                            msgType .. " shows its default switch")
                        assert.are.equal(timingText, timing:GetText(), msgType .. " shows its default delay")
                        assert.are.equal(defaults.messages[1] or "", w.edits[1]:GetText(),
                            msgType .. " shows its default lines")
                        assert.are.same({}, wow.errors)
                    end
                end
            end)

            it("the walkthrough's steps raise no Lua error, and it's repaired by the end" .. when, function()
                for _, msgType in ipairs(ns.Config.TYPES) do
                    -- Damaged once, before the first step.
                    ns = wow.boot()
                    if recent then ns.Config.Repair() end
                    ns.db[msgType] = 7
                    ns.Walkthrough.Start()
                    for _ = 2, #ns.Walkthrough.STEPS do ns.Walkthrough.Next() end
                    assert.is_false(damaged(msgType), msgType .. " repaired by the last step")
                    -- Damaged again before every step.
                    ns.Walkthrough.Start()
                    for _ = 2, #ns.Walkthrough.STEPS do
                        ns.db[msgType] = "broken"
                        ns.Walkthrough.Next()
                    end
                    assert.are.same({}, wow.errors)
                end
            end)
        end

        it("the panel's own controls work on a section damaged after it filled", function()
            open()
            wow.run(w.tabs.guildJoin, "OnClick")
            ns.db.guildJoin = 7
            wow.run(w.enabled, "OnClick")
            assert.are.equal(w.enabled:GetChecked() == true, ns.db.guildJoin.enabled)
            ns.db.guildJoin = "broken"
            wow.run(w.steppers.delay.plus, "OnClick")
            assert.are.equal(ns.Config.DefaultsFor("guildJoin").delay + 1, ns.db.guildJoin.delay)
            ns.db.guildJoin = true
            w.edits[1]:SetText("Welcome!")
            wow.run(w.edits[1], "OnTextChanged", true)
            assert.are.equal("Welcome!", ns.db.guildJoin.messages[1])
            ns.db.guildJoin = false
            wow.run(w.preview, "OnClick")
            ns.db.guildJoin = 7
            wow.run(w.loadCasual, "OnClick")
            assert.are.same(ns.CasualMessages.guildJoin, ns.db.guildJoin.messages)
            ns.db.guildJoin = 7
            wow.run(w.reset, "OnClick")
            assert.are.same(ns.Config.DefaultsFor("guildJoin"), ns.db.guildJoin)
            -- The Favours tab's reset keeps the button's place, read from the
            -- section, and resets both its sections (#491).
            wow.run(w.tabs.favours, "OnClick")
            ns.db.buffBack = "broken"
            ns.db.buff = 7
            wow.run(w.reset, "OnClick")
            assert.are.same(ns.Config.DefaultsFor("buffBack"), ns.db.buffBack)
            assert.are.same(ns.Config.DefaultsFor("buff"), ns.db.buff)
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("buff mode's minutes box (#171)", function()
        local function typeInto(box, text)
            box:SetFocus()
            box:SetText(text)
        end

        -- Buff mode's minutes are on the Buffs tab, which has no Reset (#491):
        -- the Favours tab's minutes to offer a favour stand in for a box a
        -- Reset puts back, and buff mode's are kept by that Reset.
        it("typing in a minutes box, then pressing Reset this tab to defaults: the default stays saved and shown "
            .. "(white)", function()
                open()
                wow.run(w.tabs.favours, "OnClick")
                local box = w.steppers.owedMinutes.box
                typeInto(box, "9")
                wow.run(w.reset, "OnClick")
                assert.is_false(box:HasFocus())
                local default = ns.Config.DEFAULTS.buffBack.owedMinutes
                assert.are_not.equal(9, default)
                assert.are.equal(default, ns.db.buffBack.owedMinutes, "the reset wins")
                assert.are.equal(tostring(default), box:GetText())
                -- Buff mode's: typed on the Buffs tab, saved as the tab changes, and kept.
                wow.run(w.tabs.buffs, "OnClick")
                local autoOff = w.steppers.autoOffMinutes.box
                typeInto(autoOff, "9")
                wow.run(w.tabs.favours, "OnClick")
                wow.run(w.reset, "OnClick")
                assert.is_false(autoOff:HasFocus())
                assert.are.equal(9, ns.db.buffBack.autoOffMinutes, "the Favours tab's Reset leaves buff mode's")
            end)

        it("typing in it, then switching tabs: the typed number is saved to buff back's settings, no Lua error (black)",
            function()
                open()
                wow.run(w.tabs.buffs, "OnClick")
                local box = w.steppers.autoOffMinutes.box
                typeInto(box, "9")
                wow.run(w.tabs.guildLogin, "OnClick")
                assert.is_false(box:HasFocus())
                assert.are.equal(9, ns.db.buffBack.autoOffMinutes)
                assert.is_nil(ns.db.guildLogin.autoOffMinutes, "nothing saved to the tab switched to")
                assert.are.same({}, wow.errors)
            end)

        it("every number box on the panel finishes its edit before a tab switch, so none can be missed (black)",
            function()
                open()
                local count = 0
                -- The Favours tab's thanks timing, named apart from the message tabs'
                -- (#491): the buff section's delay and repeat.
                local FAVOURS_THANKS = { thankDelay = "delay", thankRepeat = "repeatCooldown" }
                for name, stepper in pairs(w.steppers) do
                    -- The tab it shows on: a message type's, Favours (#491), whose
                    -- settings are buff's and buffBack's, or the Buffs tab (#408),
                    -- whose settings are buffBack's.
                    local home
                    for _, tab in ipairs(ns.Options.TABS) do
                        wow.run(w.tabs[tab], "OnClick")
                        if not home and stepper.box:IsVisible() then home = tab end
                    end
                    assert.is_truthy(home, name .. " shows on a tab")
                    local section, field = home, name
                    if home == ns.Options.BUFFS_TAB then
                        section = "buffBack"
                    elseif home == ns.Options.FAVOURS_TAB then
                        section, field = FAVOURS_THANKS[name] and "buff" or "buffBack", FAVOURS_THANKS[name] or name
                    end
                    wow.run(w.tabs[home], "OnClick")
                    local limits = ns.Config.LIMITS[field]
                    local typed = ns.db[section][field] == limits.min and limits.min + 1 or limits.min
                    typeInto(stepper.box, tostring(typed))
                    local other = home == ns.Options.FAVOURS_TAB and "guildLogin" or ns.Options.FAVOURS_TAB
                    wow.run(w.tabs[other], "OnClick")
                    assert.is_false(stepper.box:HasFocus(), name)
                    assert.are.equal(typed, ns.db[section][field], name .. " saved to its own tab")
                    count = count + 1
                end
                assert.is_true(count >= 8, "every stepper was checked")
                assert.are.same({}, wow.errors)
            end)
    end)
end)
