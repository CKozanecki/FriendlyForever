-- Spec: #486
-- Guild greetings and the guild welcome say the guildmate's zone, from the
-- guild roster, never yours; party, raid and thanks lines keep yours.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MINE, THEIRS = "Elwynn Forest", "Durotar"

describe("Guild messages use the guildmate's zone (#486)", function()
    local ns

    local function online(name)
        wow.systemMessage("|Hplayer:" .. name .. "|h[" .. name .. "]|h has come online.")
    end

    local function joined(name)
        wow.systemMessage(name .. " has joined the guild.")
    end

    -- A guild hello waits its delay, the longest random extra and its
    -- announcement's round trip (#38).
    local function helloWait()
        return ns.db.guildLogin.delay + ns.GuildHellos.STAGGER_MAX + wow.ADDON_ECHO_DELAY + 0.1
    end

    local function boot(opts)
        opts = opts or {}
        ns = wow.boot({ before = function(state)
            state.guildRoster = { "Thrall", "Jaina" }
            state.zone = opts.zone or MINE
            state.resting = opts.resting
            state.guildZones = { Thrall = THEIRS, Jaina = "Ashenvale" }
        end })
        wow.fire("GUILD_ROSTER_UPDATE")
        ns.Flavour.ResetMemory()
    end

    local function lines(msgType, list)
        ns.db[msgType].messages = list
        ns.db.messageBags = {}
    end

    -- Every line sent to channel, joined, for searching.
    local function said(channel)
        return table.concat(wow.sentTo(channel), "\n")
    end

    describe("white: their zone, from the roster", function()
        it("greets a guildmate logging in from another zone with their zone", function()
            boot()
            lines("guildLogin", { "Welcome back, {name}! How is {zone}?" })
            online("Thrall")
            wow.advance(helloWait())
            assert.are.same({ "Welcome back, Thrall! How is Durotar?" }, wow.sentTo("GUILD"))
        end)

        it("reads the zone as the line goes out, from the latest roster", function()
            boot()
            wow.state.guildZones.Thrall = ""
            wow.fire("GUILD_ROSTER_UPDATE")
            lines("guildLogin", { "Hi {name}, enjoy {zone}!" })
            online("Thrall")
            -- The fresh roster the login asked for, with their zone filled in.
            wow.state.guildZones.Thrall = "Tanaris"
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.advance(helloWait())
            assert.are.same({ "Hi Thrall, enjoy Tanaris!" }, wow.sentTo("GUILD"))
        end)

        it("asks for a fresh roster on a guild login and a guild join", function()
            boot()
            local before = wow.rosterRequests
            online("Thrall")
            assert.are.equal(before + 1, wow.rosterRequests)
            joined("Garrosh")
            assert.are.equal(before + 2, wow.rosterRequests)
        end)

        it("welcomes a new member with their zone once the roster has them", function()
            boot()
            lines("guildJoin", { "Welcome, {name}! Greetings to {zone}." })
            joined("Garrosh")
            wow.state.guildRoster[#wow.state.guildRoster + 1] = "Garrosh"
            wow.state.guildZones.Garrosh = "Mulgore"
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.advance(ns.db.guildJoin.delay + 0.1)
            assert.are.same({ "Welcome, Garrosh! Greetings to Mulgore." }, wow.sentTo("GUILD"))
        end)

        it("blesses with the guild's phrases, naming their zone", function()
            boot()
            lines("guildLogin", { "Welcome back, {name}. {blessing}" })
            ns.Flavour.WEIGHTS = { race = 0, faction = 0, place = 1, time = 0, general = 0 }
            ns.Flavour.random = function() return 1 end
            online("Thrall")
            wow.advance(helloWait())
            assert.are.same({ "Welcome back, Thrall. " .. ns.FlavourText.blessing.place.guild[1]:gsub("{zone}", THEIRS) },
                wow.sentTo("GUILD"))
        end)
    end)

    describe("black: a zone that can't be read", function()
        local cases = {
            { "a secret", function() wow.state.guildZoneSecret = { Thrall = true } end },
            { "nil", function()
                local real = _G.GetGuildRosterInfo
                _G.GetGuildRosterInfo = function(i)
                    local a, b, c, d, e, _, g, h, isOnline = real(i)
                    return a, b, c, d, e, nil, g, h, isOnline
                end
            end },
            { "empty", function() wow.state.guildZones.Thrall = "" end },
            { "missing from the roster", function() wow.state.guildRoster = { "Jaina" } end },
            { "on a row that isn't online", function() wow.state.guildOffline = { Thrall = true } end },
            { "on a row whose online flag can't be read", function()
                local real = _G.GetGuildRosterInfo
                _G.GetGuildRosterInfo = function(i)
                    local a, b, c, d, e, f, g, h = real(i)
                    return a, b, c, d, e, f, g, h, a == "Thrall" and wow.secret(true) or true
                end
            end },
            { "on a row with no online flag", function()
                local real = _G.GetGuildRosterInfo
                _G.GetGuildRosterInfo = function(i)
                    local a, b, c, d, e, f, g, h, isOnline = real(i)
                    return a, b, c, d, e, f, g, h, a ~= "Thrall" and isOnline or nil
                end
            end },
            { "too long", function() wow.state.guildZones.Thrall = string.rep("a", ns.Greeter.MAX_ZONE_BYTES + 1) end },
            { "a whole roster that can't be read", function() _G.GetNumGuildMembers = function() return nil end end },
        }
        local real
        before_each(function() real = { _G.GetGuildRosterInfo, _G.GetNumGuildMembers } end)
        after_each(function() _G.GetGuildRosterInfo, _G.GetNumGuildMembers = real[1], real[2] end)

        for _, case in ipairs(cases) do
            it("a zone that is " .. case[1] .. " gives a line with no zone and no 'these lands'", function()
                boot()
                -- Every phrase pool open, the zone lines first in the bag.
                lines("guildLogin", { "Hi {name}, how is {ZONE}?", "Welcome back, {name}. {blessing}" })
                online("Thrall")
                case[2]()
                wow.fire("GUILD_ROSTER_UPDATE")
                assert.is_nil(ns.Greeter.MemberZone("Thrall"))
                wow.advance(helloWait())
                local sent = said("GUILD")
                assert.are_not.equal("", sent)
                assert.is_nil(sent:find("these lands", 1, true), sent)
                assert.is_nil(sent:find(MINE, 1, true), sent)
                assert.is_nil(sent:lower():find("{zone}", 1, true), sent)
                assert.is_nil(sent:find("how is", 1, true), sent)
            end)
        end

        it("a line given way to avoids the lines other copies announced, while one is left (#38)", function()
            boot()
            wow.state.guildZoneSecret = true
            wow.fire("GUILD_ROSTER_UPDATE")
            lines("guildLogin", { "Hi {name}, how is {zone}?", "Two, {name}.", "Three, {name}." })
            -- The bag opens on line 1, the zone line; the line it would give way to next is 3.
            ns.Messages.random = function() return 1 end
            online("Thrall")
            ns.GuildHellos.OnGreet("Varian", "Thrall", 3) -- another copy will say line 3
            wow.advance(helloWait())
            assert.are.same({ "Two, Thrall." }, wow.sentTo("GUILD"))
        end)

        it("says another copy's line rather than nothing when it is the only one left (#38)", function()
            boot()
            wow.state.guildZoneSecret = true
            wow.fire("GUILD_ROSTER_UPDATE")
            lines("guildLogin", { "Hi {name}, how is {zone}?", "Two, {name}." })
            ns.Messages.random = function() return 1 end
            online("Thrall")
            ns.GuildHellos.OnGreet("Varian", "Thrall", 2)
            wow.advance(helloWait())
            assert.are.same({ "Two, Thrall." }, wow.sentTo("GUILD"))
        end)

        it("says nothing when every line needs their zone", function()
            boot()
            wow.state.guildZoneSecret = true
            wow.fire("GUILD_ROSTER_UPDATE")
            lines("guildLogin", { "Hi {name}, how is {zone}?" })
            online("Thrall")
            wow.advance(helloWait())
            assert.are.same({}, wow.sentTo("GUILD"))
        end)

        it("cleans a zone of anything the chat could read as an escape", function()
            boot()
            wow.state.guildZones.Thrall = "Dur|cffff0000otar"
            wow.fire("GUILD_ROSTER_UPDATE")
            assert.are.equal("Durcffff0000otar", ns.Greeter.MemberZone("Thrall"))
        end)
    end)

    describe("black: no phrase that needs a zone the guild message hasn't got", function()
        it("the guild pool and every pick leave out the phrases with {zone}", function()
            boot()
            local ctx = ns.Flavour.Context({ zone = nil })
            ns.Flavour.WEIGHTS = { race = 0, faction = 0, place = 1, time = 0, general = 0 }
            local pool = ns.Flavour.Pool("blessing", ctx)
            assert.is_true(#pool > 0)
            for _, phrase in ipairs(pool) do assert.is_nil(phrase:find("{", 1, true), phrase) end
            for _ = 1, 200 do
                local phrase = ns.Flavour.Resolve("blessing", ctx)
                assert.is_nil(phrase:find("{", 1, true), phrase)
                assert.is_nil(phrase:find("these lands", 1, true), phrase)
            end
        end)
    end)

    describe("white: no city or wilds phrases chosen by your own place", function()
        for _, place in ipairs({ { "a city", { resting = true, zone = "Stormwind City" } }, { "the wilds", {} } }) do
            it("in " .. place[1] .. ", a guild blessing is always from the guild pool or a placeless one", function()
                boot(place[2])
                local own = {}
                for _, where in ipairs({ "city", "wilds", "instance" }) do
                    for _, f in ipairs(ns.FlavourText.blessing.place[where]) do own[f] = true end
                end
                for _, zone in ipairs({ THEIRS, false }) do
                    local ctx = ns.Flavour.Context({ zone = zone or nil })
                    assert.is_true(ctx.guild)
                    for _ = 1, 200 do
                        local phrase = ns.Flavour.Pick("blessing", ctx)
                        assert.is_nil(own[phrase], phrase)
                    end
                    for _, phrase in ipairs(ns.Flavour.Pool("blessing", ctx)) do
                        assert.is_nil(phrase:find("these lands", 1, true), phrase)
                        assert.is_nil(phrase:find(place[2].zone or MINE, 1, true), phrase)
                    end
                end
            end)
        end
    end)

    describe("white: party, raid and thanks keep your zone", function()
        it("party, raid and thanks lines read your zone, and a party welcome says it", function()
            boot({ zone = "Westfall" })
            local ctx = ns.Flavour.Context()
            assert.is_false(ctx.guild)
            assert.are.equal("Westfall", ns.Util.Render("{zone}", ns.Flavour.Vars({}, ctx)))
            for _, msgType in ipairs({ "partyJoin", "partyHello", "partyHelloAgain", "buff", "levelUp", "buffBack" }) do
                assert.is_nil(ns.Config.TYPE_INFO[msgType].guild, msgType)
            end
            -- A real party welcome, sent.
            lines("partyJoin", { "Welcome, {name}, to {zone}!" })
            ns.db.partyHello.enabled = false
            wow.setGroup("party", { "Anduin" })
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.systemMessage("Anduin joins the party.")
            wow.advance(10)
            assert.are.same({ "Welcome, Anduin, to Westfall!" }, wow.sentTo("PARTY"))
        end)
    end)

    describe("white: the hover preview on the guild tabs", function()
        local function hover(msgType, text)
            ns.Options.Open()
            ns.Options.SelectType(msgType)
            local edit = ns.Options.widgets.edits[1]
            edit:SetText(text)
            wow.run(edit, "OnTextChanged", true)
            wow.run(edit, "OnEnter")
            return table.concat(_G.GameTooltip.lines, "\n")
        end

        for _, msgType in ipairs({ "guildLogin", "guildJoin" }) do
            it("on " .. msgType .. ", {zone} is shown as the guildmate's, with a sample zone, never yours", function()
                boot()
                local text = hover(msgType, "Hi {name}, how is {zone}? {blessing}")
                local note = ns.Options.GUILD_ZONE_NOTE:format(ns.Options.SAMPLE_ZONE)
                assert.is_truthy(text:find(note, 1, true), text)
                assert.is_truthy(text:find("how is " .. ns.Options.SAMPLE_ZONE .. "?", 1, true), text)
                assert.is_nil(text:find(MINE, 1, true), text)
                assert.is_nil(text:find("{zone} now reads", 1, true), text)
                -- The blessings offered are the guild's, with the sample zone.
                assert.is_truthy(text:find((ns.FlavourText.blessing.place.guild[1]:gsub("{zone}",
                    ns.Options.SAMPLE_ZONE)), 1, true), text)
            end)
        end

        it("on the party tab, {zone} still reads your own", function()
            boot()
            local text = hover("partyJoin", "Welcome to {zone}!")
            assert.is_truthy(text:find("{zone} now reads: " .. MINE, 1, true), text)
            assert.is_nil(text:find(ns.Options.SAMPLE_ZONE, 1, true), text)
        end)

        it("Preview random and /friendly test render a guild line with the sample zone", function()
            boot()
            lines("guildLogin", { "Hi {name}, how is {zone}?" })
            ns.Options.Open()
            ns.Options.SelectType("guildLogin")
            wow.run(ns.Options.widgets.preview, "OnClick")
            _G.SlashCmdList.FRIENDLYFOREVER("test")
            local printed = table.concat(wow.printed, "\n")
            assert.is_truthy(printed:find("how is " .. ns.Options.SAMPLE_ZONE .. "?", 1, true), printed)
            assert.is_nil(printed:find("how is " .. MINE, 1, true), printed)
        end)
    end)

    describe("white: an empty zone given to a guild message is no zone", function()
        it("Flavour.Context takes an empty or non-text zone as unknown", function()
            boot()
            for _, zone in ipairs({ "", 42, false }) do
                local ctx = ns.Flavour.Context({ zone = zone })
                assert.is_nil(ctx.zone)
                assert.is_true(ctx.guild)
                assert.is_nil(ns.Flavour.Resolve("zone", ctx))
            end
        end)
    end)

    describe("red: a storm of roster updates and logins", function()
        for _, seed in ipairs({ 486, 2026, 31337, 4860 }) do
            it("never sends an unfilled {zone} or your own zone (seed " .. seed .. ")", function()
                random.seed(seed)
                local rng = random.random
                boot()
                local names = { "Thrall", "Jaina", "Varian", "Sylvanas", "Rexxar", "Tyrande" }
                wow.state.guildRoster = { unpack(names) }
                lines("guildLogin", { "Hi {name}, how is {zone}?", "Welcome back, {name}. {blessing}",
                    "{greeting}, {name}! {zone} awaits.", "Hello {name}." })
                lines("guildJoin", { "Welcome {name}, from {Zone}!", "Welcome, {name}! {blessing}" })
                ns.db.guildLogin.repeatCooldown, ns.db.guildJoin.repeatCooldown = 0, 0
                local zones = { "Durotar", "Tanaris", "Feralas", "", "Moonglade" }
                for _ = 1, 300 do
                    local roll, name = rng(6), names[rng(#names)]
                    if roll == 1 then
                        wow.state.guildZones[name] = zones[rng(#zones)]
                    elseif roll == 2 then
                        wow.state.guildZoneSecret = rng(2) == 1 and { [name] = true } or (rng(3) == 1)
                    elseif roll == 3 then
                        wow.fire("GUILD_ROSTER_UPDATE")
                    elseif roll == 4 then
                        online(name)
                    elseif roll == 5 then
                        joined(name .. "lad")
                    else
                        wow.advance(rng(4))
                    end
                end
                wow.advance(60)
                local sent = wow.sentTo("GUILD")
                assert.is_true(#sent > 0, "the storm sent nothing")
                for _, line in ipairs(sent) do
                    assert.is_nil(line:find("{", 1, true), line)
                    assert.is_nil(line:find(MINE, 1, true), line)
                    assert.is_nil(line:find("these lands", 1, true), line)
                end
            end)
        end
    end)
end)
