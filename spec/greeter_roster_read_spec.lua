-- Spec: #412
-- Greeter.OnRosterUpdate reads GetNumGuildMembers() and each
-- GetGuildRosterInfo(i) through Util.ReadGameValues. A count that isn't a
-- readable number, or a roster where no row can be read, keeps the
-- guildmates already known; a row that can't be read is skipped; the new
-- list is built apart and only then swapped in.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

-- The ways a count can't be read: not a finite, non-negative number.
local BAD_COUNTS = {
    ["a secret count"] = function() return wow.secret(2) end,
    nothing = function() return nil end,
    ["not a number"] = function() return 0 / 0 end,
    infinity = function() return math.huge end,
    ["minus infinity"] = function() return -math.huge end,
    ["a negative count"] = function() return -1 end,
    ["a string"] = function() return "2" end,
    ["a boolean"] = function() return true end,
    ["an error"] = function() error("blocked") end,
}

-- The ways one roster row can't be read.
local BAD_ROWS = {
    ["a secret name"] = function() return wow.secret("Thrall"), "Rogue", 1, 60, "Shaman" end,
    ["no name"] = function() return nil end,
    ["a number for a name"] = function() return 7, "Rogue", 1, 60, "Shaman" end,
    ["an error"] = function() error("blocked") end,
}

local function sortedNames(t)
    local out = {}
    for name in pairs(t) do out[#out + 1] = name end
    table.sort(out)
    return out
end

describe("The guild roster when the game's answers can't be read (#412)", function()
    local ns
    local real = {}
    -- badCount: a BAD_COUNTS key, or a function giving the count, or nil.
    -- badRows[i]: a BAD_ROWS key for row i. secretClass[name]: that row's
    -- class is a secret.
    local badCount, badRows, secretClass
    local rowReads

    local function install()
        real.GetNumGuildMembers, real.GetGuildRosterInfo = _G.GetNumGuildMembers, _G.GetGuildRosterInfo
        _G.GetNumGuildMembers = function(...)
            if type(badCount) == "function" then return badCount() end
            if badCount then return BAD_COUNTS[badCount]() end
            return real.GetNumGuildMembers(...)
        end
        _G.GetGuildRosterInfo = function(i, ...)
            rowReads = rowReads + 1
            if badRows[i] then return BAD_ROWS[badRows[i]]() end
            local name, rank, rankIndex, level, class = real.GetGuildRosterInfo(i, ...)
            if secretClass[name] then class = wow.secret(class) end
            return name, rank, rankIndex, level, class
        end
    end

    local function restore()
        _G.GetNumGuildMembers, _G.GetGuildRosterInfo = real.GetNumGuildMembers, real.GetGuildRosterInfo
    end

    local function boot(roster)
        badCount, badRows, secretClass, rowReads = nil, {}, {}, 0
        ns = wow.boot({ before = function(state) state.guildRoster = roster or { "Thrall", "Jaina" } end })
        install()
        wow.fire("GUILD_ROSTER_UPDATE")
    end

    -- The guildmates the addon knows, as a sorted list.
    local function known()
        local out = {}
        for _, name in ipairs({ "Thrall", "Jaina", "Varian", "Anduin", "Sylvanas" }) do
            if ns.Greeter.IsGuildMember(name) then out[#out + 1] = name end
        end
        table.sort(out)
        return out
    end

    local function update()
        assert.has_no.errors(function() wow.fire("GUILD_ROSTER_UPDATE") end)
        assert.are.same({}, wow.errors)
    end

    after_each(restore)

    describe("(white) a readable roster", function()
        before_each(function() boot() end)

        it("fills the members as before", function()
            assert.are.same({ "Jaina", "Thrall" }, known())
            assert.are.equal(2, ns.Greeter.MemberCount())
            assert.is_nil(ns.Diag.Counters().rosterUnreadable)
        end)

        it("replaces the list on the next update: who left is gone, who joined is in", function()
            wow.state.guildRoster = { "Thrall", "Varian" }
            update()
            assert.are.same({ "Thrall", "Varian" }, known())
        end)

        it("keeps each member's class for a guild greeting", function()
            ns.db.guildLogin.messages = { "Welcome back, mighty {class} {name}!" }
            wow.systemMessage("|Hplayer:Thrall|h[Thrall]|h has come online.")
            wow.advance(30)
            assert.are.same({ "Welcome back, mighty warrior Thrall!" }, wow.sentTo("GUILD"))
        end)

        it("out of a guild, knows nobody", function()
            wow.state.inGuild = false
            update()
            assert.are.same({}, known())
        end)

        it("a large guild (1000 members) is read to its last member", function()
            -- Names of letters only, as player names are: "Member" plus a
            -- three-letter tag, "Memberaaa" to "Memberbml".
            local letters = "abcdefghijklmnopqrstuvwxyz"
            local function tag(n)
                local out = ""
                for _ = 1, 3 do
                    local i = n % 26 + 1
                    out = letters:sub(i, i) .. out
                    n = math.floor(n / 26)
                end
                return "Member" .. out
            end
            local roster = {}
            for n = 0, 999 do roster[#roster + 1] = tag(n) end
            wow.state.guildRoster = roster
            update()
            assert.are.equal(1000, ns.Greeter.MemberCount())
            assert.is_true(ns.Greeter.IsGuildMember(tag(0)))
            assert.is_true(ns.Greeter.IsGuildMember(tag(999)))
        end)

        it("reads a count with a fraction as its whole rows", function()
            badCount = function() return 2.5 end
            update()
            assert.are.same({ "Jaina", "Thrall" }, known())
        end)
    end)

    describe("(black) a count that can't be read", function()
        for way in pairs(BAD_COUNTS) do
            it(way .. ": keeps the members known, counts the update as unreadable, nothing errors", function()
                boot()
                wow.state.guildRoster = { "Varian" }
                badCount = way
                update()
                assert.are.same({ "Jaina", "Thrall" }, known())
                assert.are.equal(1, ns.Diag.Counters().rosterUnreadable)
                -- No row is read on a count that can't be.
                rowReads = 0
                update()
                assert.are.equal(0, rowReads)
                -- The next readable update is taken.
                badCount = nil
                update()
                assert.are.same({ "Varian" }, known())
            end)
        end

        it("a count of nobody while in a guild (which always lists you) keeps the members known", function()
            boot()
            wow.state.guildRoster = {}
            update()
            assert.are.same({ "Jaina", "Thrall" }, known())
            assert.are.equal(1, ns.Diag.Counters().rosterUnreadable)
        end)

        it("a huge count reads no more than the bound's rows, and the roster still loads", function()
            boot()
            badCount = function() return 1e12 end
            rowReads = 0
            update()
            -- The bound as a number, not the code's own constant (#191).
            assert.are.equal(5000, rowReads)
            assert.are.same({ "Jaina", "Thrall" }, known())
        end)

        it("a guildmate logging in during an unreadable update is still greeted once the roster reads", function()
            boot()
            ns.db.guildLogin.messages = { "Hi {name}!" }
            wow.state.guildRoster = { "Thrall", "Jaina", "Varian" }
            badCount = "an error"
            wow.systemMessage("|Hplayer:Varian|h[Varian]|h has come online.")
            update()
            assert.is_false(ns.Greeter.IsGuildMember("Varian"))
            badCount = nil
            update()
            wow.advance(30)
            assert.are.same({ "Hi Varian!" }, wow.sentTo("GUILD"))
        end)
    end)

    describe("(black) a row that can't be read", function()
        for way in pairs(BAD_ROWS) do
            it(way .. ": that row is skipped and the rest are read", function()
                boot()
                wow.state.guildRoster = { "Thrall", "Jaina", "Varian" }
                badRows[1] = way
                update()
                assert.are.same({ "Jaina", "Varian" }, known())
                assert.is_nil(ns.Diag.Counters().rosterUnreadable)
            end)

            it(way .. " on every row: keeps the members known", function()
                boot()
                wow.state.guildRoster = { "Varian", "Anduin" }
                badRows[1], badRows[2] = way, way
                update()
                assert.are.same({ "Jaina", "Thrall" }, known())
                assert.are.equal(1, ns.Diag.Counters().rosterUnreadable)
            end)
        end

        it("a secret class keeps the name, with no class", function()
            boot()
            secretClass.Thrall = true
            update()
            assert.are.same({ "Jaina", "Thrall" }, known())
            ns.db.guildLogin.messages = { "Welcome back, mighty {class} {name}!" }
            wow.systemMessage("|Hplayer:Thrall|h[Thrall]|h has come online.")
            wow.advance(30)
            assert.are.same({ "Welcome back, mighty friend Thrall!" }, wow.sentTo("GUILD"))
        end)
    end)

    describe("(red) a storm of roster updates", function()
        local POOL = { "Thrall", "Jaina", "Varian", "Anduin", "Sylvanas" }
        local countWays, rowWays = {}, {}
        for way in pairs(BAD_COUNTS) do countWays[#countWays + 1] = way end
        for way in pairs(BAD_ROWS) do rowWays[#rowWays + 1] = way end
        table.sort(countWays)
        table.sort(rowWays)

        it("never errors, never empties a known list, and takes every readable roster", function()
            local seen = { readable = 0, unreadable = 0, partial = 0 }
            for _, seed in ipairs({ 12, 412, 2026, 31337 }) do
                random.seed(seed)
                boot()
                -- What the addon should know, worked out from the simulated
                -- client and the answers this storm gave: never by asking it.
                local expected = { Jaina = true, Thrall = true }
                for step = 1, 300 do
                    local at = ("seed %d, step %d"):format(seed, step)
                    local roster = {}
                    for _, name in ipairs(POOL) do
                        if random.random() < 0.6 then roster[#roster + 1] = name end
                    end
                    wow.state.guildRoster = roster
                    badCount = random.random() < 0.3 and countWays[random.random(#countWays)] or nil
                    badRows = {}
                    for i = 1, #roster do
                        if random.random() < 0.2 then badRows[i] = rowWays[random.random(#rowWays)] end
                    end
                    local readable = {}
                    for i, name in ipairs(roster) do
                        if not badRows[i] then readable[name] = true end
                    end
                    local hadMembers = next(expected) ~= nil
                    assert.has_no.errors(function() wow.fire("GUILD_ROSTER_UPDATE") end, at)
                    assert.are.same({}, wow.errors, at)
                    if badCount or next(readable) == nil then
                        seen.unreadable = seen.unreadable + 1
                    else
                        if next(badRows) then seen.partial = seen.partial + 1 end
                        seen.readable = seen.readable + 1
                        expected = readable
                    end
                    assert.are.same(sortedNames(expected), known(), at)
                    if hadMembers then assert.is_true(ns.Greeter.MemberCount() > 0, at .. ": a known list emptied") end
                end
            end
            -- The storm covered every case it checks.
            assert.is_true(seen.readable > 0 and seen.unreadable > 0 and seen.partial > 0)
        end)
    end)
end)
