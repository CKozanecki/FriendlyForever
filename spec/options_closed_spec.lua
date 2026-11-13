-- Spec: #267
-- The settings pages fill only when the player is looking at them. A shown
-- frame with no parent counts as visible, and the pages have no parent until
-- the Settings window adopts them, so a closed window was refilled on every
-- refresh. (The simulated client models both: see its ASSUMPTIONS.)
local wow = require("spec.support.wow")

describe("Options refreshes", function()
    local ns, filled, counts

    -- Count every fill of each page: the panel through its debug line, the
    -- others through the text each one sets.
    local function watch()
        filled, counts = 0, { start = 0, general = 0, ledger = 0 }
        local log = ns.Diag.Log
        ns.Diag.Log = function(category, fmt, ...)
            if category == "options" and tostring(fmt):find("filled", 1, true) then filled = filled + 1 end
            return log(category, fmt, ...)
        end
        local w = ns.Options.widgets
        local function count(fontString, key)
            local set = fontString.SetText
            fontString.SetText = function(self, ...)
                counts[key] = counts[key] + 1
                return set(self, ...)
            end
        end
        count(w.start.enabled, "start")
        count(w.general.snoozeState, "general")
        count(w.ledger.summary, "ledger")
    end

    local function refreshes()
        wow.fire("CVAR_UPDATE", "nameplateShowFriends", "1")
        ns.Options.Refresh()
        _G.SlashCmdList.FRIENDLYFOREVER("off")
        _G.SlashCmdList.FRIENDLYFOREVER("on")
    end

    describe("with the settings window never opened", function()
        before_each(function()
            ns = wow.boot({ settingsClosed = true })
            watch()
        end)

        it("a page has no parent and is hidden until the window shows it (white)", function()
            for _, page in ipairs({ _G.FriendlyForeverOptionsPanel, ns.Options.StartPage(), ns.Options.Pages() }) do
                assert.is_nil(page:GetParent())
                assert.is_false(page:IsVisible())
            end
        end)

        it("the game calls a shown frame with no parent visible, so only a parent check keeps a shown page quiet (black)", function()
            local page = ns.Options.StartPage()
            page:Show()
            assert.is_true(page:IsVisible())
            counts.start = 0
            refreshes()
            assert.are.equal(0, counts.start)
        end)

        it("fills no page and logs no filled line on a setting change (black)", function()
            refreshes()
            assert.are.equal(0, filled)
            assert.are.same({ start = 0, general = 0, ledger = 0 }, counts)
        end)
    end)

    describe("once the pages are opened", function()
        before_each(function()
            ns = wow.boot({ settingsClosed = true })
            watch()
        end)

        it("opening each page fills it (white)", function()
            _G.Settings.OpenToCategory(4242)
            assert.is_true(filled > 0, "the main page")
            _G.Settings.OpenToCategory("Start here")
            assert.is_true(counts.start > 0, "Start here")
            _G.Settings.OpenToCategory("General")
            assert.is_true(counts.general > 0, "General")
            _G.Settings.OpenToCategory("Favour Ledger")
            assert.is_true(counts.ledger > 0, "Favour Ledger")
        end)

        it("a change while a page is open refreshes it, and only that page (white)", function()
            _G.Settings.OpenToCategory("Start here")
            local before = counts.start
            filled, counts.general, counts.ledger = 0, 0, 0
            _G.SlashCmdList.FRIENDLYFOREVER("off")
            assert.is_true(counts.start > before, "the open page refreshed")
            assert.are.equal(0, filled)
            assert.are.equal(0, counts.general + counts.ledger)
        end)

        it("closing the window stops the refills again (white)", function()
            _G.Settings.OpenToCategory("General")
            wow.settings.window.shown = false
            counts.general = 0
            refreshes()
            assert.are.equal(0, counts.general)
        end)
    end)
end)
