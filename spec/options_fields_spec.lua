-- Spec: #330
-- The options panel with a field inside a settings section damaged
-- mid-session, and the Buff Thanks and Buff Back tabs' controls clicked with
-- their whole section damaged after the panel filled (#330). A whole section
-- damaged before the panel fills is spec/options_repair_spec.lua's (#166).
local wow = require("spec.support.wow")

local KINGS, MIGHT_1, WISDOM_1, RIGHTEOUS_FURY = 20217, 19740, 19742, 25780

describe("Options panel", function()
    local ns, w

    -- Opens the panel from closed, as the player does (its OnShow fills it).
    local function open()
        local panel = _G.FriendlyForeverOptionsPanel
        panel:Hide()
        ns.Options.Open()
        assert.is_true(panel:IsVisible())
    end

    local function deepCopy(value)
        if type(value) ~= "table" then return value end
        local out = {}
        for k, v in pairs(value) do out[k] = deepCopy(v) end
        return out
    end

    -- What the next reload would make of a field: the saved file loaded again.
    local function reloaded(msgType, field)
        return ns.Config.Load(deepCopy(ns.db))[msgType][field]
    end

    -- What a field can be damaged into mid-session (another addon, a bad
    -- /run): removed (NIL stands for nil, which a list can't hold), the wrong
    -- type, or a table holding junk.
    local NIL = {}
    local DAMAGE = { NIL, 7, "broken", true, false, function() end, { 7 }, { {} }, { broken = {} } }
    -- A table field with its own shape but a wrong value inside: only a
    -- check of each value, not just of the keys, finds it.
    local SHAPED = {
        { "buffBack", "position", { point = "TOP", x = "far", y = 0 } },
        { "buffBack", "whoGets", { intellect = { rule = 7 } } },
        { "buffBack", "neverOffer", { intellect = "yes", arcanebrilliance = true } },
        { "buffBack", "buffOrder", { "intellect", 7 } },
        { "guildLogin", "messages", { "Hi", 7 } },
    }

    -- Every way every field is damaged: { msgType, field, value }.
    local function damages()
        local out = {}
        for _, msgType in ipairs(ns.Config.TYPES) do
            for field in pairs(ns.Config.DEFAULTS[msgType]) do
                for _, value in ipairs(DAMAGE) do out[#out + 1] = { msgType, field, value } end
            end
        end
        for _, case in ipairs(SHAPED) do out[#out + 1] = case end
        return out
    end

    describe("a field inside a section damaged mid-session (black, #330)", function()
        -- recent: a repair ran under a second ago, so Config.Repair does
        -- nothing and the panel has to check the field itself.
        for _, recent in ipairs({ false, true }) do
            local when = recent and " (a repair ran just before)" or ""

            it("opening the panel and switching tabs raise no Lua error, show the field as a reload would, "
                .. "and repair it" .. when, function()
                ns = wow.boot()
                w = ns.Options.widgets
                local checked = 0
                for _, case in ipairs(damages()) do
                    local msgType, field, value = case[1], case[2], case[3]
                    if value == NIL then value = nil end
                    -- A repair runs at most once a second: a second on, it runs.
                    wow.advance(2)
                    if recent then ns.Config.Repair() end
                    ns.db[msgType][field] = value
                    local expected = reloaded(msgType, field)
                    -- A value a reload keeps isn't damage (true for a switch).
                    if type(value) == "table" or value ~= expected then
                        local what = msgType .. "." .. field .. " = " .. tostring(value)
                            .. (case[3] == NIL and " (removed)" or "")
                        ns.db.skipWhileAFK = "maybe"
                        open()
                        assert.are.same(expected, ns.db[msgType][field], what .. " healed as the panel opened")
                        if not recent then
                            assert.are.equal(ns.Config.DEFAULTS.skipWhileAFK, ns.db.skipWhileAFK,
                                what .. ": it asked for the whole-file repair, so the rest heals too")
                        end
                        ns.db.skipWhileAFK = ns.Config.DEFAULTS.skipWhileAFK
                        for _, tab in ipairs(ns.Config.TYPES) do
                            ns.db[msgType][field] = value
                            wow.run(w.tabs[tab], "OnClick")
                            assert.are.same(expected, ns.db[msgType][field], what .. " healed on the " .. tab
                                .. " tab")
                        end
                        -- Its own tab shows it as it now is.
                        ns.db[msgType][field] = value
                        wow.run(w.tabs[msgType], "OnClick")
                        local live = ns.db[msgType]
                        for i, edit in ipairs(w.edits) do
                            assert.are.equal(live.messages[i], edit:GetText(), what .. ": line " .. i)
                        end
                        for name, stepper in pairs(w.steppers) do
                            if stepper.box:IsShown() and live[name] ~= nil then
                                assert.are.equal(tostring(live[name]), stepper.box:GetText(), what .. ": " .. name)
                            end
                        end
                        if msgType == "buff" then
                            assert.are.equal(live.unknownName, w.unknownName:GetText(), what)
                            assert.are.equal(ns.Options.THANK_STYLE_TEXT[live.thankStyle],
                                w.thankStyle:GetText(), what)
                            assert.are.equal(ns.Options.FALLBACK_TEXT[live.fallback], w.fallback:GetText(), what)
                        end
                        assert.are.same({}, wow.errors)
                        checked = checked + 1
                    end
                end
                assert.is_true(checked > 350, "every field was damaged every way")
            end)
        end

        it("a number typed in a box whose field is then damaged is saved, as the box finishes its edit", function()
            ns = wow.boot()
            w = ns.Options.widgets
            open()
            wow.run(w.tabs.buffBack, "OnClick")
            -- A second on: the repair runs, and puts a new section in place.
            wow.advance(2)
            local box = w.steppers.owedMinutes.box
            box:SetFocus()
            box:SetText("20")
            ns.db.buffBack.owedMinutes = "broken"
            wow.run(w.tabs.guildLogin, "OnClick")
            assert.is_false(box:HasFocus())
            assert.are.equal(20, ns.db.buffBack.owedMinutes)
            wow.run(w.tabs.buffBack, "OnClick")
            assert.are.equal("20", box:GetText())
            assert.are.same({}, wow.errors)
        end)

        it("a message line damaged inside its list is healed too, and typing in it saves", function()
            ns = wow.boot()
            w = ns.Options.widgets
            open()
            wow.run(w.tabs.guildJoin, "OnClick")
            ns.db.guildJoin.messages[3] = {}
            ns.db.guildJoin.messages[31] = "a line too many"
            wow.run(w.tabs.guildJoin, "OnClick")
            assert.are.equal("", ns.db.guildJoin.messages[3])
            assert.is_nil(ns.db.guildJoin.messages[31])
            assert.are.equal("", w.edits[3]:GetText())
            -- Damaged after the panel filled: typing a line still saves it,
            -- to the section the whole-file repair puts in place (a second
            -- on, so the repair runs).
            wow.advance(2)
            ns.db.guildJoin.messages = 7
            w.edits[2]:SetText("Welcome, {name}!")
            wow.run(w.edits[2], "OnTextChanged", true)
            assert.are.equal("Welcome, {name}!", ns.db.guildJoin.messages[2])
            ns.db.guildJoin.messages = "broken"
            wow.run(w.preview, "OnClick")
            assert.is_falsy(wow.printed[#wow.printed]:find("(no messages)", 1, true), "previews a healed line")
            ns.db.guildJoin.delay = "broken"
            wow.run(w.steppers.delay.plus, "OnClick")
            assert.are.equal(ns.Config.DEFAULTS.guildJoin.delay + 1, ns.db.guildJoin.delay)
            -- The same for a list a click adds to.
            wow.run(w.tabs.buffBack, "OnClick")
            wow.advance(2)
            local key = w.buffRows[1].key
            ns.db.buffBack.neverOffer = 7
            w.buffRows[1].never:SetChecked(true)
            wow.run(w.buffRows[1].never, "OnClick")
            assert.are.same({ [key] = true }, ns.db.buffBack.neverOffer)
            assert.are.same({}, wow.errors)
        end)

        it("a number box on a tab without its field saves nothing, and raises no Lua error", function()
            ns = wow.boot()
            w = ns.Options.widgets
            open()
            wow.run(w.tabs.buffBack, "OnClick")
            for _, button in ipairs({ "plus", "minus" }) do
                wow.run(w.steppers.delay[button], "OnClick")
                wow.run(w.steppers.maxGreeters[button], "OnClick")
            end
            wow.run(w.steppers.delay.box, "OnEditFocusLost")
            assert.is_nil(ns.db.buffBack.delay)
            assert.is_nil(ns.db.buffBack.maxGreeters)
            assert.are.equal("", w.steppers.delay.box:GetText())
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("a healthy file (white, #330)", function()
        it("filling every tab asks for no repair and changes no setting", function()
            ns = wow.boot()
            w = ns.Options.widgets
            -- Settings changed from their defaults, tables included.
            ns.db.buff.thankStyle = "both"
            ns.db.buff.unknownName = "stranger"
            ns.db.guildJoin.messages[2] = "Hi {name}!"
            ns.db.buffBack.buffOrder = { "intellect" }
            ns.db.buffBack.neverOffer = { intellect = true }
            ns.db.buffBack.whoGets = { intellect = { rule = "classes", classes = { MAGE = true },
                always = { ["ann-vale"] = "Ann-Vale" } } }
            ns.db.buffBack.position = { point = "TOP", x = 10, y = -20 }
            local before = deepCopy(ns.db)
            local repairs = 0
            local repair = ns.Config.Repair
            ns.Config.Repair = function(...)
                repairs = repairs + 1
                return repair(...)
            end
            open()
            for _, tab in ipairs(ns.Config.TYPES) do wow.run(w.tabs[tab], "OnClick") end
            ns.Config.Repair = repair
            assert.are.equal(0, repairs)
            for _, msgType in ipairs(ns.Config.TYPES) do
                assert.are.same(before[msgType], ns.db[msgType], msgType)
            end
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("the Buff Thanks and Buff Back tabs' controls with their section damaged after the panel filled "
        .. "(black, #330)", function()
        -- What a whole section can be damaged into.
        local SECTION_DAMAGE = { 7, "broken", true, false, function() end }

        -- A paladin in a raid, so every Buff Back row shows: the buff list
        -- with a self-buff (#44), who gets each (chosen classes), and the
        -- raid's Blessings.
        local function boot()
            ns = wow.boot({ buffTable = wow.selfBuffTable(), before = function(state)
                state.class = "PALADIN"
                state.knownSpells = { [KINGS] = true, [WISDOM_1] = true, [MIGHT_1] = true, [RIGHTEOUS_FURY] = true }
            end })
            w = ns.Options.widgets
            wow.setGroup("raid", { "Ann-Vale" })
            open()
        end

        -- Each control: prepare (optional) sets the tab up before the damage,
        -- click clicks it, and check says whether the click saved (nil: it
        -- saves nothing). click's result is passed to check. noSection: it
        -- doesn't use the section, so leaves it to the next fill.
        local function toggle(cb, msgType, field)
            return {
                click = function()
                    cb:SetChecked(not cb:GetChecked())
                    wow.run(cb, "OnClick")
                    return cb:GetChecked() == true
                end,
                check = function(want) return ns.db[msgType][field] == want end,
            }
        end
        local function stepper(name, msgType)
            local s = w.steppers[name]
            return {
                click = function() wow.run(s.plus, "OnClick") end,
                check = function()
                    local limits = ns.Config.LIMITS[name]
                    local want = math.min(ns.Config.DEFAULTS[msgType][name] + (name == "renewPercent" and 5 or 1),
                        limits.max)
                    return ns.db[msgType][name] == want and s.box:GetText() == tostring(want)
                end,
            }
        end
        local function dropdownRow(dd, msgType, field, i)
            return {
                click = function()
                    wow.run(dd, "OnClick")
                    wow.run(dd.rows[i], "OnClick")
                end,
                check = function() return ns.db[msgType][field] == dd.rows[i].value end,
            }
        end

        local function controls(msgType)
            local list = {}
            local function add(name, control) list[#list + 1] = { name = name, control = control } end
            add("enabled", toggle(w.enabled, msgType, "enabled"))
            -- On every tab: the master switch, the AFK box and the tabs.
            add("addon enabled", {
                click = function()
                    w.master:SetChecked(not w.master:GetChecked())
                    wow.run(w.master, "OnClick")
                    return w.master:GetChecked() == true
                end,
                check = function(want) return ns.db.enabled == want end,
            })
            -- A setting of the whole file: it leaves the section as it is.
            add("skip while AFK", {
                noSection = true,
                click = function()
                    w.skipAFK:SetChecked(not w.skipAFK:GetChecked())
                    wow.run(w.skipAFK, "OnClick")
                    return w.skipAFK:GetChecked() == true
                end,
                check = function(want) return ns.db.skipWhileAFK == want end,
            })
            for _, tab in ipairs(ns.Config.TYPES) do
                add("the " .. tab .. " tab", { click = function() wow.run(w.tabs[tab], "OnClick") end })
            end
            add("a message line", {
                click = function()
                    w.edits[1]:SetText("Thanks, {name}!")
                    wow.run(w.edits[1], "OnTextChanged", true)
                end,
                check = function() return ns.db[msgType].messages[1] == "Thanks, {name}!" end,
            })
            add("preview", { click = function() wow.run(w.preview, "OnClick") end })
            add("load casual lines", {
                click = function() wow.run(w.loadCasual, "OnClick") end,
                check = function() return ns.db[msgType].messages[1] == ns.CasualMessages[msgType][1] end,
            })
            add("reset", {
                click = function() wow.run(w.reset, "OnClick") end,
                check = function()
                    return ns.db[msgType].messages[1] == ns.Config.DEFAULTS[msgType].messages[1]
                end,
            })
            if msgType == "buff" then
                add("delay", stepper("delay", "buff"))
                add("repeat cooldown", stepper("repeatCooldown", "buff"))
                add("name the buffs", toggle(w.listNames, "buff", "listBuffNames"))
                add("receipts", toggle(w.receipts, "buff", "receipts"))
                add("quiet in cities", toggle(w.quiet, "buff", "quietInCities"))
                for i in ipairs(w.thankStyle.rows) do
                    add("thank style " .. i, dropdownRow(w.thankStyle, "buff", "thankStyle", i))
                end
                for i in ipairs(w.fallback.rows) do
                    add("fallback " .. i, dropdownRow(w.fallback, "buff", "fallback", i))
                end
                add("show friendly player names", {
                    click = function() wow.run(w.nameplateButton, "OnClick") end,
                })
                add("the unknown caster's name", {
                    click = function()
                        w.unknownName:SetText("stranger")
                        wow.run(w.unknownName, "OnTextChanged", true)
                    end,
                    check = function() return ns.db.buff.unknownName == "stranger" end,
                })
                return list
            end
            add("say a line", toggle(w.sayLine, "buffBack", "sayLine"))
            add("show in cities", toggle(w.showInCities, "buffBack", "showInCities"))
            add("group versions", toggle(w.groupVersions, "buffBack", "groupVersions"))
            add("raid split", toggle(w.raidSplit, "buffBack", "raidSplit"))
            add("battleground preparation", toggle(w.bgPrepBuff, "buffBack", "bgPrepBuff"))
            add("water breathing", toggle(w.breathNearWater, "buffBack", "breathNearWater"))
            add("self-buffs", toggle(w.selfBuffs, "buffBack", "selfBuffs"))
            for _, field in ipairs(ns.Options.AUTO_SWITCHES) do add(field, toggle(w.auto[field], "buffBack", field)) end
            for _, name in ipairs({ "owedMinutes", "renewPercent", "autoOffMinutes", "topUpMinutes", "groupEnough" }) do
                add(name, stepper(name, "buffBack"))
            end
            add("buff mode's key", {
                click = function()
                    wow.run(w.buffModeKey, "OnClick")
                    wow.run(w.keyCapture, "OnKeyDown", "F")
                end,
                check = function() return ns.db.buffBack.buffModeKey == "F" end,
            })
            -- The rows in your class's own order, which a healed section has.
            local function defaultOrder()
                ns.db.buffBack.buffOrder = {}
                ns.Options.Refresh()
            end
            add("a buff's Down button", {
                prepare = defaultOrder,
                click = function()
                    local key = w.buffRows[1].key
                    wow.run(w.buffRows[1].down, "OnClick")
                    return key
                end,
                check = function(key) return ns.db.buffBack.buffOrder[2] == key end,
            })
            add("a buff's Up button", {
                prepare = defaultOrder,
                click = function()
                    local key = w.buffRows[2].key
                    wow.run(w.buffRows[2].up, "OnClick")
                    return key
                end,
                check = function(key) return ns.db.buffBack.buffOrder[1] == key end,
            })
            add("a buff's Never offer box", {
                click = function()
                    local key = w.buffRows[1].key
                    w.buffRows[1].never:SetChecked(true)
                    wow.run(w.buffRows[1].never, "OnClick")
                    return key
                end,
                check = function(key) return ns.db.buffBack.neverOffer[key] == true end,
            })
            -- Righteous Fury is never offered by default: unticking it saves false (#44).
            add("Righteous Fury's Never offer box, unticked", {
                click = function()
                    for _, row in ipairs(w.buffRows) do
                        if row.key == "righteousfury" then
                            row.never:SetChecked(false)
                            wow.run(row.never, "OnClick")
                            return true
                        end
                    end
                end,
                check = function(found) return found and ns.db.buffBack.neverOffer.righteousfury == false end,
            })
            add("a buff's Who button", {
                click = function()
                    local key = w.buffRows[1].key
                    wow.run(w.buffRows[1].who, "OnClick")
                    return key
                end,
                check = function(key) return type(ns.db.buffBack.whoGets[key]) == "table" end,
            })
            add("a class box", {
                prepare = function()
                    ns.BuffRules.SetRule(ns.Options.WhoBuffKey(), "classes")
                    ns.Options.Refresh()
                    assert.is_true(w.who.classes.WARRIOR:IsShown())
                end,
                click = function()
                    w.who.classes.WARRIOR:SetChecked(true)
                    wow.run(w.who.classes.WARRIOR, "OnClick")
                    return ns.Options.WhoBuffKey()
                end,
                check = function(key) return ns.db.buffBack.whoGets[key].classes.WARRIOR == true end,
            })
            for _, names in ipairs({ "always", "never" }) do
                add("the " .. names .. " box", {
                    -- Typing in it when the damage comes.
                    prepare = function() w.who[names]:SetFocus() end,
                    click = function()
                        local box = w.who[names]
                        box:SetText("Ann Vale")
                        box:ClearFocus()
                        return ns.Options.WhoBuffKey()
                    end,
                    check = function(key) return ns.db.buffBack.whoGets[key][names]["ann-vale"] == "Ann-Vale" end,
                })
            end
            add("a raid Blessing box", {
                click = function()
                    assert.is_true(w.who.raidBlessings[1]:IsEnabled(), "in a raid")
                    w.who.raidBlessings[1]:SetChecked(not w.who.raidBlessings[1]:GetChecked())
                    wow.run(w.who.raidBlessings[1], "OnClick")
                end,
            })
            return list
        end

        for _, msgType in ipairs({ "buff", "buffBack" }) do
            it("clicking any " .. msgType .. " control raises no Lua error and saves to a repaired section", function()
                boot()
                local count = 0
                for i, entry in ipairs(controls(msgType)) do
                    for _, value in ipairs(SECTION_DAMAGE) do
                        local what = entry.name .. " with " .. msgType .. " = " .. tostring(value)
                        -- A repair ran under a second ago half the time: the
                        -- panel has to put the section back itself.
                        wow.advance(2)
                        if (i + count) % 2 == 0 then ns.Config.Repair() end
                        wow.run(w.tabs[msgType], "OnClick")
                        if entry.control.prepare then entry.control.prepare() end
                        ns.db[msgType] = value
                        local clicked = entry.control.click()
                        if not entry.control.noSection then
                            assert.are.equal("table", type(ns.db[msgType]), what .. ": repaired")
                        end
                        if entry.control.check then
                            assert.is_true(entry.control.check(clicked), what .. ": the click was saved")
                        end
                        assert.are.same({}, wow.errors, what)
                        count = count + 1
                    end
                end
                assert.is_true(count >= (msgType == "buff" and 80 or 150), "every control was clicked")
            end)
        end

        it("a damaged field heals alone: the fields beside it keep their settings, the button's place included",
            function()
                boot()
                wow.run(w.tabs.buffBack, "OnClick")
                ns.db.buffBack.position = { point = "TOP", x = 10, y = -20 }
                ns.db.buffBack.unlocked = "broken"
                wow.run(w.tabs.buffBack, "OnClick")
                assert.is_false(ns.db.buffBack.unlocked)
                assert.are.same({ point = "TOP", x = 10, y = -20 }, ns.db.buffBack.position)
                assert.are.same({}, wow.errors)
            end)
    end)
end)
