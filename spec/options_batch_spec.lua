-- Spec: #425, #429
-- Each page's Reset touches only its own settings (#425), and the buff mode
-- key capture takes a click over every widget beneath it (#429).
local wow = require("spec.support.wow")

-- Listed here, not read from the addon, so a field added to the Weapon buffs
-- page and left off the kept list fails below (#425).
local KIND -- a kind the rogue can use, found below
local WEAPON_PAGE = { weaponBuffs = true, weaponMain = true, weaponOff = true }
-- The Buff Back tab's own settings, which its Reset does put back (the other
-- Buff Back settings belong to the Buffs tab, the Weapon buffs page, or are
-- the button's place). Every Buff Back setting must be in exactly one of
-- these lists, so a new one has to be placed (#425).
local BUFF_BACK_TAB = { "autoOffDone", "autoOffMinutes", "autoOffPull", "autoOnBuffed", "autoOnCampfire",
    "autoOnDeath", "autoOnJoin", "autoOnMissing", "buffModeKey", "enabled", "messages", "owedMinutes",
    "renewPercent", "requests", "sayLine", "showInCities", "topUpMinutes" }

describe("Reset on the Buff Back tab (#425)", function()
    local ns

    before_each(function()
        ns = wow.boot({ db = {}, class = "ROGUE" })
        KIND = ns.WeaponBuffs.KindsFor("ROGUE", 16)[1]
    end)

    it("leaves the Weapon buffs page's settings as they are (white)", function()
        ns.db.buffBack.weaponBuffs = true
        ns.db.buffBack.weaponMain = KIND
        ns.db.buffBack.weaponOff = KIND
        ns.ResetType("buffBack")
        assert.is_true(ns.db.buffBack.weaponBuffs)
        assert.are.equal(KIND, ns.db.buffBack.weaponMain)
        assert.are.equal(KIND, ns.db.buffBack.weaponOff)
    end)

    it("the Reset button does the same, and the page shows what it kept (white)", function()
        local w = ns.Options.widgets
        ns.db.buffBack.weaponBuffs = true
        ns.db.buffBack.weaponMain = KIND
        ns.Options.Open()
        wow.run(w.tabs.buffBack, "OnClick")
        wow.run(w.reset, "OnClick")
        assert.is_true(ns.db.buffBack.weaponBuffs)
        assert.are.equal(KIND, ns.db.buffBack.weaponMain)
        local _, _, weaponPage = ns.Options.Pages()
        wow.run(weaponPage, "OnShow")
        assert.is_true(w.weapon.enabled:GetChecked(), "the page shows weapon buffs still on")
        assert.are.equal(ns.WeaponBuffs.KINDS[KIND].label, w.weapon.main:GetText(), "and the kind it kept")
    end)

    it("every Buff Back setting belongs to exactly one page, so a new one must be placed (white)", function()
        local owner = {}
        local function claim(list, who)
            for _, key in ipairs(list) do
                assert.is_nil(owner[key], key .. " is on two lists: " .. who .. " and " .. tostring(owner[key]))
                owner[key] = who
            end
        end
        claim(BUFF_BACK_TAB, "the Buff Back tab")
        claim(ns.BuffsTab.FIELDS, "the Buffs tab")
        claim(ns.Profiles.LOCAL_ONLY.buffBack, "the button's place")
        local weapon = {}
        for key in pairs(WEAPON_PAGE) do weapon[#weapon + 1] = key end
        claim(weapon, "the Weapon buffs page")
        for key in pairs(ns.Config.DefaultsFor("buffBack")) do
            assert.is_not_nil(owner[key], key .. " is a Buff Back setting no page owns: place it in this list")
        end
        for key in pairs(owner) do
            assert.is_not_nil(ns.Config.DefaultsFor("buffBack")[key], key .. " is listed but isn't a setting")
        end
    end)

    it("the Buff Back tab's own settings go back to their defaults (white)", function()
        local defaults = ns.Config.DefaultsFor("buffBack")
        for _, key in ipairs(BUFF_BACK_TAB) do
            if type(defaults[key]) == "boolean" then ns.db.buffBack[key] = not defaults[key] end
        end
        ns.ResetType("buffBack")
        for _, key in ipairs(BUFF_BACK_TAB) do
            if type(defaults[key]) == "boolean" then
                assert.are.equal(defaults[key], ns.db.buffBack[key], key)
            end
        end
    end)

    it("the list of kept Weapon fields is exactly the page's (white)", function()
        local listed = {}
        for _, key in ipairs(ns.WeaponBuffs.FIELDS) do listed[key] = true end
        assert.are.same(WEAPON_PAGE, listed)
    end)
end)

describe("the key capture's frame level (#429)", function()
    local ns, w

    local function under(frame, ancestor)
        local p = frame.parent
        while type(p) == "table" do
            if p == ancestor then return true end
            p = p.parent
        end
        return false
    end

    before_each(function()
        ns = wow.boot({ db = {}, class = "ROGUE" })
        w = ns.Options.widgets
        ns.Options.Open()
        wow.run(w.tabs.buffBack, "OnClick")
    end)

    it("takes a click over every widget on the tab beneath it (white)", function()
        local capture = w.keyCapture
        local content = capture.parent
        ns.Options.StartKeyCapture()
        assert.is_true(capture.active)
        local checked = 0
        for _, f in ipairs(wow.frames) do
            if f ~= capture and under(f, content) then
                local winner = wow.hitTest({ capture, f })
                assert.are.equal(capture, winner, "a click reached " .. tostring(f:GetName() or f.kind) .. " " .. tostring(f.strata) .. " " .. tostring(f.level) .. " cap " .. tostring(capture.level) .. " " .. tostring(f.text))
                checked = checked + 1
            end
        end
        assert.is_true(checked > 10, "the tab's shown widgets were found")
    end)

    it("takes the level again when shown, whatever changed it meanwhile (white)", function()
        local capture = w.keyCapture
        ns.Options.StartKeyCapture()
        capture:SetFrameLevel(0)
        wow.run(capture, "OnShow")
        assert.is_true(capture:GetFrameLevel() >= capture.parent:GetFrameLevel() + ns.Options.KEY_CAPTURE_LEVEL)
    end)

    it("still ends and restores the tab as before (white)", function()
        ns.Options.StartKeyCapture()
        wow.run(w.keyCapture, "OnKeyDown", "ESCAPE")
        assert.is_false(w.keyCapture.active)
        assert.is_false(w.keyCapture:IsShown())
        assert.is_false(w.keyCapture.mouse)
    end)
end)
