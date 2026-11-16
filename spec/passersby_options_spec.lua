-- Spec: #39
-- Passers-by and the campfire trigger in the settings: the switch on the
-- Buffs tab's Buff Back place, with its help line and the nameplates it
-- needs; the campfire's box among the turn-on triggers; the options search;
-- the walkthrough; profiles and settings lines.
local wow = require("spec.support.wow")

describe("Passers-by and the campfire in the settings (#39)", function()
    local ns, w

    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [1126] = true }
            if opts.nameplatesOff then state.cvars.nameplateShowFriendlyPlayers = "0" end
        end })
        w = ns.Options.widgets
        ns.Options.Open()
    end

    local function buffsPlace(p)
        wow.run(w.tabs.buffs, "OnClick")
        wow.run(w.placeTabs[p], "OnClick")
    end

    local function click(box, on)
        box:SetChecked(on)
        wow.run(box, "OnClick")
    end

    describe("the switch (white)", function()
        it("is on the Buffs tab's Buff Back place, off by default, with its help line, and saves at once", function()
            boot()
            buffsPlace("strangers")
            assert.is_true(w.passersBy:IsVisible())
            assert.is_false(w.passersBy:GetChecked())
            assert.is_truthy(w.passersBy.tooltip)
            assert.is_true(w.passersByHelp:IsVisible())
            assert.is_truthy(w.passersByHelp:GetText():find("aren't in your group", 1, true))
            click(w.passersBy, true)
            assert.is_true(ns.db.buffBack.passersBy)
            click(w.passersBy, false)
            assert.is_false(ns.db.buffBack.passersBy)
        end)

        it("isn't on the other places", function()
            boot()
            for _, p in ipairs({ "party", "raid", "pvp" }) do
                buffsPlace(p)
                assert.is_false(w.passersBy:IsVisible(), p)
                assert.is_false(w.passersByHelp:IsVisible(), p)
            end
        end)

        it("says when friendly nameplates are off, and its button turns them on", function()
            boot({ nameplatesOff = true })
            buffsPlace("strangers")
            assert.is_true(w.passersByNameplates:IsVisible())
            assert.is_true(w.passersByShow:IsVisible())
            wow.run(w.passersByShow, "OnClick")
            assert.are.equal("1", wow.state.cvars.nameplateShowFriendlyPlayers)
            assert.is_false(w.passersByNameplates:IsVisible(), "they're on now")
            assert.is_false(w.passersByShow:IsVisible())
        end)

        it("shows nothing about nameplates while they're on", function()
            boot()
            buffsPlace("strangers")
            assert.is_false(w.passersByNameplates:IsVisible())
            assert.is_false(w.passersByShow:IsVisible())
        end)
    end)

    describe("the campfire trigger's box (white)", function()
        it("is among the turn-on triggers on the Buff Back tab, on by default, with a tooltip", function()
            boot({ db = { buffBack = { autoOnCampfire = true } } })
            wow.run(w.tabs.buffBack, "OnClick")
            local box = w.auto.autoOnCampfire
            assert.is_true(box:IsVisible())
            assert.are.equal("at a campfire", box.label:GetText())
            assert.is_true(box:GetChecked())
            assert.is_truthy(box.tooltip:find("camp benefit", 1, true))
            click(box, false)
            assert.is_false(ns.db.buffBack.autoOnCampfire)
        end)

        it("the walkthrough's turn-on step lists it", function()
            boot({ db = { buffBack = { autoOnCampfire = true } } })
            local text
            for _, step in ipairs(ns.Walkthrough.STEPS) do
                if step.title == "Buff mode: when it turns on and off" then text = step.text() end
            end
            assert.is_truthy(text:find("at a campfire: " .. ns.Colours.Text("good", "on"), 1, true))
        end)
    end)

    describe("finding them (white)", function()
        it("the options search finds the switch under passers-by, nearby and strangers, and the campfire", function()
            boot()
            local function names(word)
                local out = {}
                for _, entry in ipairs(ns.OptionsIndex.Find(word)) do out[entry.name] = entry.page end
                return out
            end
            for _, word in ipairs({ "passers-by", "nearby", "strangers" }) do
                assert.are.equal("the Buffs tab's Buff Back place", names(word)["Also offer my buffs to passers-by"],
                    word)
            end
            assert.are.equal("the Buff Back tab", names("campfire")["Buff mode turns on by itself"])
        end)
    end)

    describe("carried along (white)", function()
        it("settings lines and profiles carry both", function()
            boot()
            ns.db.buffBack.passersBy = true
            ns.db.buffBack.autoOnCampfire = false
            local text = assert(ns.Profiles.Export())
            boot()
            assert.is_false(ns.db.buffBack.passersBy)
            assert.is_true(ns.Profiles.Import(text))
            assert.is_true(ns.db.buffBack.passersBy)
            assert.is_false(ns.db.buffBack.autoOnCampfire)
            local snap = ns.Profiles.Snapshot(ns.db)
            assert.is_true(snap.buffBack.passersBy)
            assert.is_false(snap.buffBack.autoOnCampfire)
        end)

        it("the Buff Back tab's Reset leaves the switch as it is (it's the Buffs tab's)", function()
            boot()
            ns.db.buffBack.passersBy = true
            ns.ResetType("buffBack")
            assert.is_true(ns.db.buffBack.passersBy)
        end)
    end)

    describe("damaged (black)", function()
        it("a damaged switch shows off on the tab, and heals as the tab fills", function()
            boot()
            ns.db.buffBack.passersBy = "yes"
            buffsPlace("strangers")
            assert.is_false(w.passersBy:GetChecked())
            assert.is_false(ns.db.buffBack.passersBy, "healed (#330)")
        end)
    end)
end)
