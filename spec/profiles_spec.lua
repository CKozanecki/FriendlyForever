-- Spec: #52, #76
-- Settings as text (export/import), profiles, the bug report and the addon
-- compartment entry.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

local function printedHas(fragment)
    for _, line in ipairs(wow.printed) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

describe("Serialize", function()
    local S

    before_each(function() S = wow.boot().Serialize end)

    it("round-trips settings, including awkward text", function()
        local value = {
            enabled = true, off = false, delay = 4, half = 0.5, neg = -3,
            messages = { "Thanks, {name}!", "100% sure; really", "pipe | and\ttab", "", "Ünïcødé ✓" },
            nested = { deeper = { x = 1 } },
        }
        local text = assert(S.Encode(value))
        assert.is_nil(text:find("|", 1, true), "no escape codes in the line")
        assert.is_nil(text:find("[%c]"), "no control characters in the line")
        assert.are.same(value, S.Decode(text))
    end)

    it("accepts surrounding spaces from a paste", function()
        local text = S.Encode({ a = 1 })
        assert.are.same({ a = 1 }, S.Decode("  " .. text .. "\n"))
    end)

    it("rejects what isn't a settings line, without running anything", function()
        _G.HACKED = nil
        for _, bad in ipairs({
            "", "hello", "return os.exit()", "FF1:", "FF1:X", "FF1:{S a;", "FF1:Nabc;", "FF1:{T}",
            "FF1:S unterminated", "FF1:TT", "FF1:{Sa;N1;", 'FF1:S"); HACKED = true --;',
        }) do
            local value, why = S.Decode(bad)
            assert.is_nil(value, bad)
            assert.is_string(why, bad)
        end
        assert.is_nil(_G.HACKED)
    end)

    it("reads up to its limits and refuses just past them, saying why", function()
        local function nested(n) -- n tables, one inside the next
            return "FF1:" .. string.rep("{Sa;", n - 1) .. "{}" .. string.rep("}", n - 1)
        end
        assert.is_table(S.Decode(nested(S.MAX_DEPTH)))
        local value, why = S.Decode(nested(S.MAX_DEPTH + 1))
        assert.is_nil(value)
        assert.are.equal("it nests too deeply", why)

        -- A table of n pairs is 1 + 2n values.
        local pairs = math.floor((S.MAX_ITEMS - 1) / 2)
        assert.is_table(S.Decode("FF1:{" .. string.rep("N1;T", pairs) .. "}"))
        value, why = S.Decode("FF1:{" .. string.rep("N1;T", pairs + 1) .. "}")
        assert.is_nil(value)
        assert.are.equal("too many values", why)

        local long = "FF1:S" .. string.rep("a", S.MAX_BYTES - 6) .. ";"
        assert.are.equal(S.MAX_BYTES, #long)
        assert.is_string(S.Decode(long))
        value, why = S.Decode(long .. " " .. "x")
        assert.is_nil(value)
        assert.are.equal("that text is too long", why)
    end)

    it("never errors on random input, only returns a reason", function()
        local A = { "{", "}", "S", "N", "T", "F", ";", "%", "%4", "1", "e", "-", ".", "x", " " }
        random.seed(1)
        for _ = 1, 5000 do
            local p = { "FF1:" }
            for _ = 1, random.random(0, 30) do p[#p + 1] = A[random.random(#A)] end
            local text = table.concat(p)
            local ok, value, why = pcall(S.Decode, text)
            assert(ok, text)
            assert(value ~= nil or type(why) == "string", text)
        end
    end)

    it("won't encode functions or broken numbers", function()
        assert.is_nil(S.Encode({ f = print }))
        assert.is_nil(S.Encode({ n = 0 / 0 }))
    end)
end)

describe("Export and import", function()
    local ns

    before_each(function() ns = wow.boot() end)

    local function exported()
        return assert(ns.Profiles.Export())
    end

    it("carries message types, options and the ignore list", function()
        ns.db.guildLogin.delay = 9
        ns.db.buff.thankStyle = "both"
        ns.db.buff.messages[1] = "My own thanks, {name}!"
        ns.Ignore.Add("Bob-Stone")
        local text = exported()

        ns = wow.boot()
        ns.Ignore.Add("Ann-Vale")
        assert.is_true(ns.Profiles.Import(text))
        assert.are.equal(9, ns.db.guildLogin.delay)
        assert.are.equal("both", ns.db.buff.thankStyle)
        assert.are.equal("My own thanks, {name}!", ns.db.buff.messages[1])
        assert.is_true(ns.Ignore.Has("Bob-Stone"), "names are added")
        assert.is_true(ns.Ignore.Has("Ann-Vale"), "and none of yours are removed")
    end)

    it("never changes the addon's on/off switch, the minimap button, the ledger or snooze", function()
        local text = exported()
        ns = wow.boot()
        ns.db.enabled = false
        ns.db.minimap.angle = 10
        ns.Ledger.Received("Bob-Stone", "Thorns")
        ns.Profiles.Import(text)
        assert.is_false(ns.db.enabled)
        assert.are.equal(10, ns.db.minimap.angle)
        assert.are.equal(1, #ns.db.ledger.entries)
    end)

    it("checks what it imports like the saved file", function()
        local text = ns.Serialize.Encode({ v = 1, settings = {
            guildLogin = { delay = 99999, enabled = "yes", messages = { string.rep("x", 400) } },
            buff = { thankStyle = "dance" },
            ignore = { ["not a name!"] = true },
        } })
        assert.is_true(ns.Profiles.Import(text))
        assert.are.equal(ns.Config.LIMITS.delay.max, ns.db.guildLogin.delay)
        assert.is_true(ns.db.guildLogin.enabled)
        assert.are.equal(255, #ns.db.guildLogin.messages[1])
        assert.are.equal("message", ns.db.buff.thankStyle)
        assert.are.same({}, ns.Ignore.List())
    end)

    it("refuses a line from an unknown version, changing nothing", function()
        ns.db.guildLogin.delay = 7
        local ok, why = ns.Profiles.Import(ns.Serialize.Encode({ v = 2, settings = { guildLogin = { delay = 1 } } }))
        assert.is_nil(ok)
        assert.is_truthy(why:find("version", 1, true))
        assert.are.equal(7, ns.db.guildLogin.delay)
    end)

    it("undoes an import, ignore list included", function()
        ns.db.guildLogin.delay = 7
        local mine = exported()
        ns = wow.boot({ db = { guildLogin = { delay = 2 } } })
        ns.Ignore.Add("Ann-Vale")
        ns.Profiles.Import(mine)
        assert.are.equal(7, ns.db.guildLogin.delay)
        slash("import undo")
        assert.are.equal(2, ns.db.guildLogin.delay)
        assert.are.same({ "Ann Vale" }, ns.Ignore.List())
        slash("import undo")
        assert.is_true(printedHas("there's no import to undo"))
    end)

    it("export shows the line in a window, ready to copy", function()
        slash("export")
        local window = ns.Window.Frame()
        assert.is_true(window:IsShown())
        assert.is_truthy(window.box:GetText():find("^FF1:"))
        assert.is_false(window.accept:IsShown(), "nothing to accept when copying")
    end)

    it("import takes a pasted line from the window", function()
        ns.db.partyJoin.delay = 5
        local text = exported()
        ns = wow.boot()
        slash("import")
        local window = ns.Window.Frame()
        window.box:SetText(text)
        wow.run(window.accept, "OnClick")
        assert.are.equal(5, ns.db.partyJoin.delay)
        assert.is_false(window:IsShown())
    end)

    it("says what's wrong with a bad paste and keeps the window open", function()
        slash("import")
        local window = ns.Window.Frame()
        window.box:SetText("not a settings line")
        wow.run(window.accept, "OnClick")
        assert.is_true(printedHas("couldn't import"))
        assert.is_true(window:IsShown())
    end)
end)

describe("Profiles", function()
    local ns

    local function boot(db)
        ns = wow.boot({ db = db, before = function(state)
            state.units.player = { name = "Nikki", surname = "Shifts", id = "Nikki-Shifts", isPlayer = true }
        end })
        return ns
    end

    before_each(function() boot() end)

    it("starts on Default, storing nothing until a profile is made", function()
        assert.are.equal("Default", ns.Profiles.Active())
        assert.are.same({ "Default" }, ns.Profiles.List())
        wow.fire("PLAYER_LOGOUT")
        assert.are.same({}, ns.db.profiles)
    end)

    it("makes a new profile from your settings and switches to it", function()
        ns.db.guildLogin.delay = 8
        slash("profile new Raiding")
        assert.are.equal("Raiding", ns.Profiles.Active())
        assert.are.same({ "Default", "Raiding" }, ns.Profiles.List())
        assert.are.equal(8, ns.db.guildLogin.delay)
    end)

    it("keeps each profile's settings apart when switching", function()
        ns.db.guildLogin.delay = 8
        slash("profile new Raiding")
        ns.db.guildLogin.delay = 1
        slash("profile use Default")
        assert.are.equal(8, ns.db.guildLogin.delay)
        slash("profile use Raiding")
        assert.are.equal(1, ns.db.guildLogin.delay)
    end)

    it("leaves the ignore list and on/off switch out of profiles", function()
        slash("profile new Quiet")
        ns.Ignore.Add("Bob-Stone")
        ns.db.enabled = false
        slash("profile use Default")
        assert.is_true(ns.Ignore.Has("Bob-Stone"))
        assert.is_false(ns.db.enabled)
    end)

    it("saves edits into the active profile at logout", function()
        slash("profile new Raiding")
        ns.db.partyJoin.delay = 6
        wow.fire("PLAYER_LOGOUT")
        assert.are.equal(6, ns.db.profiles.Raiding.partyJoin.delay)
    end)

    it("switches each character to the profile it used last, at login", function()
        local function bootAs(first, surname, db)
            ns = wow.boot({ db = db, before = function(state)
                state.units.player = { name = first, surname = surname, id = first .. "-" .. surname, isPlayer = true }
            end })
        end
        bootAs("Nikki", "Shifts")
        ns.db.guildLogin.delay = 8
        slash("profile new Raiding")
        wow.fire("PLAYER_LOGOUT")
        bootAs("Ann", "Vale", _G.FriendlyForeverDB)
        slash("profile use Default")
        ns.db.guildLogin.delay = 2
        wow.fire("PLAYER_LOGOUT")
        bootAs("Nikki", "Shifts", _G.FriendlyForeverDB)
        assert.are.equal("Raiding", ns.Profiles.Active())
        assert.are.equal(8, ns.db.guildLogin.delay)
        wow.fire("PLAYER_LOGOUT")
        bootAs("Ann", "Vale", _G.FriendlyForeverDB)
        assert.are.equal("Default", ns.Profiles.Active())
        assert.are.equal(2, ns.db.guildLogin.delay)
    end)

    it("leaves a character with no saved choice on the active profile", function()
        slash("profile new Raiding")
        wow.fire("PLAYER_LOGOUT")
        local saved = _G.FriendlyForeverDB
        saved.charProfiles = {}
        boot(saved)
        assert.are.equal("Raiding", ns.Profiles.Active())
    end)

    it("refuses duplicates, unknown and blank names, and deleting the active profile", function()
        slash("profile new Raiding")
        assert.is_nil(ns.Profiles.New("Raiding"))
        assert.is_nil(ns.Profiles.Use("Nope"))
        assert.is_nil(ns.Profiles.New("   "))
        assert.is_nil(ns.Profiles.New(string.rep("x", 40)))
        assert.is_nil(ns.Profiles.Delete("Raiding"))
        assert.are.equal("Default", ns.Profiles.Delete("Default"))
        assert.are.same({ "Raiding" }, ns.Profiles.List())
    end)

    it("caps the number of profiles", function()
        -- Default is stored with the first one, so MAX - 1 new ones fill it.
        for i = 1, ns.Profiles.MAX - 1 do assert.is_truthy(ns.Profiles.New("P" .. i)) end
        assert.are.equal(ns.Profiles.MAX, #ns.Profiles.List())
        local ok, why = ns.Profiles.New("OneTooMany")
        assert.is_nil(ok)
        assert.is_truthy(why:find("most profiles", 1, true))
    end)

    it("repairs damaged profile data in the saved file", function()
        boot({
            profiles = { Good = { guildLogin = { delay = 3 } }, Bad = "x", [7] = {} },
            activeProfile = 12, charProfiles = { ["Nikki-Shifts"] = "Good", ["!!"] = "Good", ["Ann-Vale"] = 5 },
            importUndo = "x",
        })
        assert.are.same({ "Default", "Good" }, ns.Profiles.List())
        assert.is_nil(ns.db.importUndo)
        assert.are.same({ ["Nikki-Shifts"] = "Good" }, ns.db.charProfiles)
    end)

    it("a damaged profile's settings are checked when switched to", function()
        boot({ profiles = { Odd = { guildLogin = { delay = -50, messages = "nope" } } } })
        slash("profile use Odd")
        assert.are.equal(0, ns.db.guildLogin.delay)
        assert.are.equal(ns.Config.NUM_MESSAGES, #ns.db.guildLogin.messages)
    end)
end)

describe("Bug report", function()
    local ns

    before_each(function() ns = wow.boot() end)

    it("holds the status lines without colour codes, and the debug log", function()
        ns.Diag.SetEnabled(true)
        ns.Diag.Log("test", "something happened")
        local text = ns.BugReport()
        assert.is_truthy(text:find("version ", 1, true))
        assert.is_truthy(text:find("something happened", 1, true))
        assert.is_nil(text:find("|c", 1, true))
        assert.is_nil(text:find("|r", 1, true))
    end)

    it("says how to get a log when there isn't one", function()
        assert.is_truthy(ns.BugReport():find("/friendly debug", 1, true))
    end)

    it("/friendly report opens it, selected for copying", function()
        slash("report")
        assert.is_true(ns.Window.Frame():IsShown())
        assert.is_truthy(ns.Window.Frame().box:GetText():find("bug report", 1, true))
    end)
end)

describe("Addon compartment", function()
    it("adds an entry: click opens options, right-click turns the addon off", function()
        local ns = wow.boot()
        assert.are.equal(1, #wow.compartment)
        local entry = wow.compartment[1]
        assert.are.equal("Friendly Forever", entry.text)
        entry.func(nil, { buttonName = "LeftButton" })
        assert.are.equal(4242, wow.settings.opened)
        entry.func(nil, { buttonName = "RightButton" })
        assert.is_false(ns.db.enabled)
    end)

    it("is skipped on a client without the compartment", function()
        wow.reset()
        _G.AddonCompartmentFrame = nil
        wow.load()
        wow.fire("ADDON_LOADED", wow.ADDON_NAME)
        assert.are.equal(0, #wow.compartment)
    end)
end)
