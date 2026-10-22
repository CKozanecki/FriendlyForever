local wow = require("spec.support.wow")

describe("Util", function()
    local Util

    before_each(function()
        wow.reset()
        Util = wow.load().Util
    end)

    describe("FormatToPattern", function()
        it("captures %s and escapes magic characters", function()
            local p = Util.FormatToPattern("|Hplayer:%s|h[%s]|h has come online.")
            assert.are.equal("^|Hplayer:(.-)|h%[(.-)%]|h has come online%.$", p)
            assert.are.equal("Thrall", ("|Hplayer:Thrall|h[Thrall]|h has come online."):match(p))
        end)

        it("handles positional arguments used by some locales", function()
            local p = Util.FormatToPattern("%1$s ist der Gilde beigetreten.")
            assert.are.equal("Hans", ("Hans ist der Gilde beigetreten."):match(p))
        end)

        it("handles %d", function()
            local p = Util.FormatToPattern("%s rolls %d")
            assert.are.equal("Bob", ("Bob rolls 42"):match(p))
        end)

        it("is anchored so similar messages don't match", function()
            local p = Util.FormatToPattern("%s joins the party.")
            assert.is_nil(("Anduin has left the party."):match(p))
            assert.is_nil(("Note: Anduin joins the party. Really."):match(p))
        end)

        it("returns nil for missing format strings", function()
            assert.is_nil(Util.FormatToPattern(nil))
            assert.is_nil(Util.FormatToPattern(""))
        end)
    end)

    describe("StripChat", function()
        it("removes UI escape sequences", function()
            assert.are.equal("cffff0000redr", Util.StripChat("|cffff0000red|r"))
            assert.are.equal("Hitem:1234h[Sword]h", Util.StripChat("|Hitem:1234|h[Sword]|h"))
        end)

        it("replaces control characters and collapses whitespace", function()
            assert.are.equal("a b c", Util.StripChat("  a\n\tb\0\127c  "))
        end)

        it("returns empty string for non-strings", function()
            assert.are.equal("", Util.StripChat(nil))
            assert.are.equal("", Util.StripChat(42))
        end)
    end)

    describe("Utf8Truncate", function()
        it("leaves short strings alone", function()
            assert.are.equal("hello", Util.Utf8Truncate("hello", 10))
        end)

        it("cuts ASCII at the byte limit", function()
            assert.are.equal("hel", Util.Utf8Truncate("hello", 3))
        end)

        it("never splits a multi-byte character", function()
            local s = "ab" .. "\195\169" .. "cd" -- "abécd", é is 2 bytes
            assert.are.equal("ab", Util.Utf8Truncate(s, 3))
            assert.are.equal("ab\195\169", Util.Utf8Truncate(s, 4))
            local emoji = "a\240\159\152\128" -- 4-byte character
            for limit = 1, 4 do assert.are.equal("a", Util.Utf8Truncate(emoji, limit)) end
        end)
    end)

    describe("JoinList", function()
        it("joins naturally", function()
            assert.are.equal("", Util.JoinList({}))
            assert.are.equal("A", Util.JoinList({ "A" }))
            assert.are.equal("A and B", Util.JoinList({ "A", "B" }))
            assert.are.equal("A, B and C", Util.JoinList({ "A", "B", "C" }))
        end)
    end)

    describe("Render", function()
        it("fills placeholders", function()
            assert.are.equal("Hi Bob, thanks for the Fort!",
                Util.Render("Hi {name}, thanks for the {buff}!", { name = "Bob", buff = "Fort" }))
        end)

        it("keeps unknown placeholders as typed", function()
            assert.are.equal("Hi {nmae}", Util.Render("Hi {nmae}", { name = "Bob" }))
        end)

        it("inserts values literally, with no pattern interpretation", function()
            assert.are.equal("Hi %1 %%", Util.Render("Hi {name}", { name = "%1 %%" }))
        end)

        it("strips escape sequences from both template and values", function()
            assert.are.equal("Hi cff00ff00Bob", Util.Render("Hi {name}", { name = "|cff00ff00Bob" }))
            assert.are.equal("Hi Bob Tinterface", Util.Render("Hi {name} |Tinterface", { name = "Bob" }))
        end)

        it("cuts to the 255-byte chat limit", function()
            local out = Util.Render(string.rep("x", 300), {})
            assert.are.equal(255, #out)
        end)

        it("returns nil for blank or invalid templates", function()
            assert.is_nil(Util.Render("   ", {}))
            assert.is_nil(Util.Render(nil, {}))
        end)
    end)

    describe("FullName (Forever first name + surname)", function()
        it("keeps the surname: the pair is the player's identity", function()
            assert.are.equal("Nikki-Shifts", Util.FullName("Nikki-Shifts"))
        end)

        it("accepts a space between first name and surname", function()
            assert.are.equal("Nikki-Shifts", Util.FullName("Nikki Shifts"))
        end)

        it("accepts the surname as a separate value (UnitName's second return)", function()
            assert.are.equal("Nikki-Shifts", Util.FullName("Nikki", "Shifts"))
        end)

        it("doesn't double up a surname that is already in the name", function()
            assert.are.equal("Nikki-Shifts", Util.FullName("Nikki-Shifts", "Shifts"))
        end)

        it("ignores a second value that isn't a plausible surname", function()
            assert.are.equal("Nikki", Util.FullName("Nikki", "70"))
            assert.are.equal("Nikki", Util.FullName("Nikki", ""))
            assert.are.equal("Nikki", Util.FullName("Nikki", wow.secret("Shifts")))
        end)

        it("passes a lone first name through", function()
            assert.are.equal("Thrall", Util.FullName("Thrall"))
        end)

        it("accepts accented names", function()
            assert.are.equal("Zo\195\171-Br\195\174ght", Util.FullName("Zo\195\171-Br\195\174ght"))
        end)

        it("rejects implausible names", function()
            assert.is_nil(Util.FullName("Three Word Name"))
            assert.is_nil(Util.FullName("Nikki-"))
            assert.is_nil(Util.FullName("-Shifts"))
            assert.is_nil(Util.FullName("Nikki-S"))
            assert.is_nil(Util.FullName("|cffBob"))
            assert.is_nil(Util.FullName("A"))
            assert.is_nil(Util.FullName("Bob123"))
            assert.is_nil(Util.FullName(string.rep("a", 60)))
            assert.is_nil(Util.FullName(nil))
            assert.is_nil(Util.FullName(12))
        end)

        it("rejects secret values", function()
            assert.is_nil(Util.FullName(wow.secret("Nikki-Shifts")))
        end)
    end)

    describe("name display", function()
        it("addresses people by first name", function()
            assert.are.equal("Nikki", Util.FirstName("Nikki-Shifts"))
            assert.are.equal("Thrall", Util.FirstName("Thrall"))
        end)

        it("shows the full name with a space", function()
            assert.are.equal("Nikki Shifts", Util.DisplayName("Nikki-Shifts"))
        end)

        it("provides {name} and {fullname}", function()
            assert.are.same({ name = "Nikki", fullname = "Nikki Shifts" }, Util.NameVars("Nikki-Shifts"))
        end)
    end)

    describe("ClampNumber", function()
        it("clamps and floors", function()
            assert.are.equal(0, Util.ClampNumber(-5, 0, 60, 3))
            assert.are.equal(60, Util.ClampNumber(999, 0, 60, 3))
            assert.are.equal(7, Util.ClampNumber(7.9, 0, 60, 3))
        end)

        it("uses the default for non-numbers and NaN", function()
            assert.are.equal(3, Util.ClampNumber("10", 0, 60, 3))
            assert.are.equal(3, Util.ClampNumber(0 / 0, 0, 60, 3))
            assert.are.equal(3, Util.ClampNumber(nil, 0, 60, 3))
        end)
    end)

    describe("IsSecret", function()
        it("detects secret values", function()
            assert.is_true(Util.IsSecret(wow.secret(1)))
            assert.is_false(Util.IsSecret(1))
            assert.is_false(Util.IsSecret(nil))
        end)

        it("works when the client has no secret-value API", function()
            _G.issecretvalue = nil
            assert.is_false(Util.IsSecret("x"))
        end)
    end)
end)
