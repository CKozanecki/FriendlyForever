-- Spec: #491, #330
-- Favours and the Buffs tab with settings damaged mid-session (#491's
-- architecture review): each number box bound to a section reads its value
-- checked, so + and - on a field another addon or a /run damaged never raise
-- an error and step from the default; and a stranger's buff that arrives
-- while the thanks section is lost is owed and thanked from a healed section.
local wow = require("spec.support.wow")

local MOTW_1, MOTW, THORNS_1, INTELLECT = 1126, 9885, 467, 10157
local JUNK = { "x", {}, true, 0 / 0, { 5 } }

-- Each number box: its tab, its section and field, and its step.
local BOXES = {
    { tab = "favours", stepper = "thankDelay", section = "buff", field = "delay", step = 1 },
    { tab = "favours", stepper = "thankRepeat", section = "buff", field = "repeatCooldown", step = 1 },
    { tab = "favours", stepper = "owedMinutes", section = "buffBack", field = "owedMinutes", step = 1 },
    { tab = "favours", stepper = "renewPercent", section = "buffBack", field = "renewPercent", step = 5 },
    { tab = "buffs", stepper = "autoOffMinutes", section = "buffBack", field = "autoOffMinutes", step = 1 },
    { tab = "buffs", stepper = "topUpMinutes", section = "buffBack", field = "topUpMinutes", step = 1 },
    { tab = "buffs", stepper = "groupEnough", section = "buffBack", field = "groupEnough", step = 1 },
}

describe("Favours with settings damaged mid-session (#491, black)", function()
    local ns, w

    local function boot()
        ns = wow.boot({ before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
        end })
        w = ns.Options.widgets
        ns.Options.Open()
    end

    it("+ and - on a number box whose field was damaged raise no error, and step from the default", function()
        for _, b in ipairs(BOXES) do
            for _, junk in ipairs(JUNK) do
                for _, button in ipairs({ "plus", "minus" }) do
                    boot()
                    wow.run(w.tabs[b.tab], "OnClick")
                    local default = ns.Config.DEFAULTS[b.section][b.field]
                    local limits = ns.Config.LIMITS[b.field]
                    local where = ("%s.%s = %s, %s"):format(b.section, b.field, tostring(junk), button)
                    wow.advance(2) -- past the repair's once-a-second limit, as a later click would be
                    ns.db[b.section][b.field] = junk
                    local ok, err = pcall(wow.run, w.steppers[b.stepper][button], "OnClick")
                    assert.is_true(ok, where .. ": " .. tostring(err))
                    local by = button == "plus" and b.step or -b.step
                    local want = math.max(limits.min, math.min(limits.max, default + by))
                    assert.are.equal(want, ns.db[b.section][b.field], where)
                    assert.are.equal(tostring(want), w.steppers[b.stepper].box:GetText(), where)
                end
            end
        end
    end)

    it("+ on a number box whose whole section was lost raises no error, and heals the section", function()
        for _, b in ipairs(BOXES) do
            for _, junk in ipairs({ "x", 42, true }) do
                boot()
                wow.run(w.tabs[b.tab], "OnClick")
                wow.advance(2)
                ns.db[b.section] = junk
                local ok, err = pcall(wow.run, w.steppers[b.stepper].plus, "OnClick")
                local where = ("%s = %s, %s"):format(b.section, tostring(junk), b.stepper)
                assert.is_true(ok, where .. ": " .. tostring(err))
                assert.is_table(ns.db[b.section], where)
                assert.is_number(ns.db[b.section][b.field], where)
            end
        end
    end)

    it("a stranger's buff while the thanks section is lost is owed, and the section heals", function()
        for _, junk in ipairs({ 7, "x", true }) do
            boot()
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", id = "Bob-Stone", class = "WARRIOR" })
            wow.advance(2)
            ns.db.buff = junk
            local ok, err = pcall(wow.gainBuff, { sourceUnit = "nameplate1", name = "Arcane Intellect",
                spellId = INTELLECT })
            assert.is_true(ok, tostring(junk) .. ": " .. tostring(err))
            assert.are.same({}, wow.errors, tostring(junk))
            assert.are.equal(1, ns.Offers.Count(), tostring(junk) .. ": the favour is owed")
            assert.is_table(ns.db.buff, tostring(junk) .. ": the thanks section healed")
        end
    end)
end)
