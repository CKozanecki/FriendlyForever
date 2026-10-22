local wow = require("spec.support.wow")

describe("Friendly nameplates", function()
    local ns, w

    local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

    local function printedHas(fragment)
        for _, line in ipairs(wow.printed) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end

    local function bootWith(cvars)
        ns = wow.boot({ before = function(state)
            for k, v in pairs(cvars) do state.cvars[k] = v end
        end })
        w = ns.Options.widgets
    end

    describe("never changes your settings by itself", function()
        it("on load, or while playing", function()
            bootWith({ nameplateShowFriendlyPlayers = "0" })
            wow.addUnit("target", { name = "Bob" })
            wow.gainBuff({ sourceUnit = "target", name = "Fort" })
            wow.gainBuff({ name = "Int" })
            wow.advance(30)
            wow.keyDown()
            wow.run(w.tabs.buff, "OnClick")
            slash("status")
            assert.are.same({}, wow.cvarWrites)
            assert.are.equal("0", wow.state.cvars.nameplateShowFriendlyPlayers)
        end)
    end)

    describe("when they're off", function()
        before_each(function() bootWith({ nameplateShowFriendlyPlayers = "0" }) end)

        it("the buff tab warns and offers the fix", function()
            wow.run(w.tabs.buff, "OnClick")
            assert.is_true(w.nameplateWarning:IsShown())
            assert.is_true(w.nameplateButton:IsShown())
        end)

        it("other tabs don't show the warning", function()
            wow.run(w.tabs.guildLogin, "OnClick")
            assert.is_false(w.nameplateWarning:IsShown())
            assert.is_false(w.nameplateButton:IsShown())
        end)

        it("/friendly status says so", function()
            slash("status")
            assert.is_true(printedHas("friendly player nameplates: |cffff4040off|r"))
        end)

        it("the button turns on friendly player names only, then hides the warning", function()
            wow.run(w.tabs.buff, "OnClick")
            wow.run(w.nameplateButton, "OnClick")
            assert.are.same({ "nameplateShowFriendlyPlayers=1", "nameplateShowOnlyNameForFriendlyPlayerUnits=1" },
                wow.cvarWrites)
            assert.is_false(w.nameplateWarning:IsShown())
            assert.is_true(printedHas("friendly player names are now shown"))
        end)

        it("/friendly nameplates does the same", function()
            slash("nameplates")
            assert.are.equal("1", wow.state.cvars.nameplateShowFriendlyPlayers)
            assert.are.equal("1", wow.state.cvars.nameplateShowOnlyNameForFriendlyPlayerUnits)
        end)

        it("refuses in combat instead of erroring", function()
            wow.state.inCombat = true
            wow.run(w.tabs.buff, "OnClick")
            wow.run(w.nameplateButton, "OnClick")
            assert.are.same({}, wow.cvarWrites)
            assert.is_true(printedHas("can't be changed in combat"))
            assert.is_true(w.nameplateWarning:IsShown())
        end)

        it("turns them on even if the client has no names-only setting", function()
            wow.state.cvars.nameplateShowOnlyNameForFriendlyPlayerUnits = nil
            slash("nameplates")
            assert.are.same({ "nameplateShowFriendlyPlayers=1" }, wow.cvarWrites)
        end)

        it("the panel updates when you change the setting in the game's options", function()
            wow.run(w.tabs.buff, "OnClick")
            wow.state.cvars.nameplateShowFriendlyPlayers = "1"
            wow.fire("CVAR_UPDATE", "nameplateShowFriendlyPlayers", "1")
            assert.is_false(w.nameplateWarning:IsShown())
        end)
    end)

    describe("when they're on", function()
        before_each(function() bootWith({ nameplateShowFriendlyPlayers = "1" }) end)

        it("shows no warning", function()
            wow.run(w.tabs.buff, "OnClick")
            assert.is_false(w.nameplateWarning:IsShown())
        end)

        it("/friendly status says casters can be named", function()
            slash("status")
            assert.is_true(printedHas("friendly player nameplates: |cff00ff00on|r"))
        end)
    end)

    describe("on a client without the setting", function()
        before_each(function() bootWith({}); wow.state.cvars.nameplateShowFriendlyPlayers = nil end)

        it("shows no warning and reports it as not available", function()
            wow.run(w.tabs.buff, "OnClick")
            assert.is_false(w.nameplateWarning:IsShown())
            slash("status")
            assert.is_true(printedHas("friendly player nameplates: not available"))
        end)

        it("/friendly nameplates explains instead of erroring", function()
            slash("nameplates")
            assert.is_true(printedHas("no friendly nameplate setting"))
        end)
    end)
end)

describe("/say fallback setting", function()
    it("is on by default", function()
        local ns = wow.boot()
        assert.is_true(ns.db.buff.fallbackToSay)
    end)

    it("migrates the old 'blank name means don't thank' to the switch being off", function()
        local ns = wow.boot({ db = { schemaVersion = 2, buff = { unknownName = "" } } })
        assert.is_false(ns.db.buff.fallbackToSay)
        assert.are.equal("friend", ns.db.buff.unknownName)
    end)

    it("keeps a custom name through the migration", function()
        local ns = wow.boot({ db = { schemaVersion = 2, buff = { unknownName = "pal" } } })
        assert.is_true(ns.db.buff.fallbackToSay)
        assert.are.equal("pal", ns.db.buff.unknownName)
    end)

    it("is a checkbox on the buff tab", function()
        local ns = wow.boot()
        local w = ns.Options.widgets
        wow.run(w.tabs.buff, "OnClick")
        assert.is_true(w.fallback:IsShown())
        assert.is_true(w.fallback:GetChecked())
        w.fallback:SetChecked(false)
        wow.run(w.fallback, "OnClick")
        assert.is_false(ns.db.buff.fallbackToSay)
        wow.run(w.tabs.partyJoin, "OnClick")
        assert.is_false(w.fallback:IsShown())
    end)

    it("is recognised: 'no player named' system messages", function()
        local ns = wow.boot()
        assert.are.same({ "whisperFailed", "Bob-Brightwood" },
            { ns.Parser.Parse("No player named 'Bob-Brightwood' is currently playing.") })
    end)
end)
